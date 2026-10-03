#!/usr/bin/env bash
# Node-side tests for fleet (lib/join.sh, lib/node.sh, templates/memory).
#
# Run inside a throwaway Debian container so nothing on the host changes:
#   docker run --rm -v "$PWD:/src:ro" debian:bookworm-slim bash /src/tests/node_test.sh
#
# The tests never touch the real network: tailscale is a fake on PATH, the
# memory, code and config remotes are local bare repos (FLEET_MEMORY_REMOTE /
# FLEET_CODE_REMOTE / FLEET_CONFIG_REMOTE override the github-fleet-* host
# aliases; all three are honoured by lib/node.sh for exactly this purpose), and
# tool plug-ins are stubs in an isolated FLEET_ROOT that contains only the
# node-side files.
set -u

SRC=${FLEET_TEST_SRC:-/src}
WORK=$(mktemp -d /tmp/fleet-test.XXXXXX)
ROOT="$WORK/fleet"
export FLEET_CONTAINER=1          # behave as a container even outside docker
export FLEET_TEST_LOG="$WORK/tools.log"
export FLEET_MEMORY_REMOTE="$WORK/memory.git"
export FLEET_CODE_REMOTE="$WORK/code.git"
export FLEET_CONFIG_REMOTE="$WORK/config.git"
export TS_LOG="$WORK/tailscale.log"
export TS_STATE="$WORK/tailscale.up"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
PASS=0; FAIL=0; CASE=""; CASE_FAIL=0

# ---------- harness ----------

begin() { CASE=$1; CASE_FAIL=0; }
assert() {
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then return 0; fi
  CASE_FAIL=1; echo "   - failed: $desc"; return 1
}
refute() {   # passes when the command fails
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then CASE_FAIL=1; echo "   - failed: $desc"; return 1; fi
  return 0
}
end() {
  if [ "$CASE_FAIL" -eq 0 ]; then PASS=$((PASS + 1)); echo "PASS $CASE"; else FAIL=$((FAIL + 1)); echo "FAIL $CASE"; fi
}
file_mode() { stat -c %a "$1" 2>/dev/null; }
count_in() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }   # occurrences of literal $1 in file $2
jget() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v=v[k]
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2" 2>/dev/null; }

# ---------- environment ----------

setup_deps() {
  local missing=""
  for c in git python3 ssh-keygen pkill; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
  if [ -n "$missing" ] && command -v apt-get >/dev/null 2>&1; then
    echo "==> installing:$missing"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq --no-install-recommends git python3 openssh-client procps >/dev/null 2>&1
  fi
  for c in git python3 ssh-keygen; do command -v "$c" >/dev/null 2>&1 || { echo "missing: $c"; exit 2; }; done
  git config --global init.defaultBranch main
  git config --global user.name tester
  git config --global user.email tester@example.invalid
}

setup_root() {
  mkdir -p "$ROOT/lib/tools" "$ROOT/config" "$WORK/bin" "$WORK/tmp" "$WORK/homes"
  cp "$SRC/fleet" "$ROOT/fleet"; chmod +x "$ROOT/fleet"
  cp "$SRC/lib/common.sh" "$SRC/lib/node.sh" "$SRC/lib/join.sh" "$ROOT/lib/"
  cp "$SRC/config/defaults.conf" "$ROOT/config/defaults.conf"
  cp "$SRC/lib/tools/chrome.sh" "$ROOT/lib/tools/chrome.sh"   # real plug-in: wrapper + status tests
  cp "$SRC/lib/tools/cliproxy.sh" "$ROOT/lib/tools/cliproxy.sh" # real plug-in: remote mode in containers (env.sh proxy vars)
  # Stub plug-ins: they log calls; failures are switched on with env vars.
  local t
  for t in base devtools claude fake; do
    cat >"$ROOT/lib/tools/$t.sh" <<EOF
# shellcheck shell=bash
tool_${t}_install() {
  [ -z "\${FLEET_FAKE_FAIL_$(echo "$t" | tr '[:lower:]' '[:upper:]'):-}" ] || { echo "stub $t: forced failure"; false; }
  echo "install $t" >>"\$FLEET_TEST_LOG"
}
tool_${t}_update() { echo "update $t" >>"\$FLEET_TEST_LOG"; }
tool_${t}_status() { echo "ok 1.0 stub"; }
EOF
  done
  cat >>"$ROOT/lib/tools/fake.sh" <<'EOF'
tool_fake_status() { if [ -f "$HOME/.fake-logged-in" ]; then echo "ok logged-in"; else echo "login run: fleet login fake"; fi; }
tool_fake_login() { echo "login fake" >>"$FLEET_TEST_LOG"; touch "$HOME/.fake-logged-in"; }
EOF
  # slow: install sleeps FLEET_SLOW_INSTALL seconds (apply lock tests); update
  # sleeps "forever" when FLEET_SLOW_UPDATE=1 (a job grandchild for leave tests).
  cat >"$ROOT/lib/tools/slow.sh" <<'EOF'
# shellcheck shell=bash
tool_slow_install() { sleep "${FLEET_SLOW_INSTALL:-0}"; echo "install slow" >>"$FLEET_TEST_LOG"; }
tool_slow_update() { [ -z "${FLEET_SLOW_UPDATE:-}" ] || sleep 12345; }
tool_slow_status() { echo "ok slow"; }
EOF
  # Fake tailscale: logs argv; `up` flips state to Running with the given hostname.
  cat >"$WORK/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$TS_LOG"
case "${1:-}" in
  status)
    if [ -f "$TS_STATE" ]; then
      h=$(cat "$TS_STATE")
      printf '{"BackendState":"Running","Self":{"HostName":"%s","DNSName":"%s.tail1234.ts.net.","Tags":["tag:fleet-node"]}}\n' "$h" "$h"
    else
      echo '{"BackendState":"NeedsLogin","Self":{}}'
    fi ;;
  up)
    for a in "$@"; do
      case "$a" in
        --auth-key=file:*) f=${a#--auth-key=file:}; [ -s "$f" ] || { echo "empty key file" >&2; exit 1; } ;;
        --hostname=*) echo "${a#--hostname=}" >"$TS_STATE" ;;
      esac
    done ;;
  logout) rm -f "$TS_STATE" ;;
  set) : ;;
esac
EOF
  chmod +x "$WORK/bin/tailscale"
  export PATH="$WORK/bin:$PATH"
}

setup_memory_remote() {
  local tmp
  git init -q --bare "$WORK/memory.git"
  tmp=$(mktemp -d "$WORK/memseed.XXXXXX")
  cp -R "$SRC/templates/memory/." "$tmp/"
  git -C "$tmp" init -q
  git -C "$tmp" add -A
  git -C "$tmp" commit -q -m "init vault"
  git -C "$tmp" push -q "$WORK/memory.git" HEAD:main
}

# code.git = the isolated root (seed kept at $WORK/code-seed for later commits),
# config.git = the shipped example config (seed at $WORK/config-seed).
setup_code_config_remotes() {
  git init -q --bare "$WORK/code.git"
  rm -rf "$WORK/code-seed"; cp -R "$ROOT" "$WORK/code-seed"
  git -C "$WORK/code-seed" init -q; git -C "$WORK/code-seed" add -A; git -C "$WORK/code-seed" commit -q -m "code v1"
  git -C "$WORK/code-seed" push -q "$WORK/code.git" HEAD:main
  git init -q --bare "$WORK/config.git"
  rm -rf "$WORK/config-seed"; cp -R "$SRC/examples/fleet-config" "$WORK/config-seed"
  git -C "$WORK/config-seed" init -q; git -C "$WORK/config-seed" add -A; git -C "$WORK/config-seed" commit -q -m "config v1"
  git -C "$WORK/config-seed" push -q "$WORK/config.git" HEAD:main
}
code_head()   { git --git-dir="$WORK/code.git" rev-parse main; }
config_head() { git --git-dir="$WORK/config.git" rev-parse main; }
pair() { printf '%s+%s\n' "$(code_head)" "$(config_head)"; }
# commit_code MSG / commit_config MSG — add a marker file to the seed and push it
commit_code()   { echo "$1" >"$WORK/code-seed/MARKER";   git -C "$WORK/code-seed"   add -A; git -C "$WORK/code-seed"   commit -q -m "$1"; git -C "$WORK/code-seed"   push -q "$WORK/code.git" HEAD:main; }
commit_config() { echo "$1" >"$WORK/config-seed/MARKER"; git -C "$WORK/config-seed" add -A; git -C "$WORK/config-seed" commit -q -m "$1"; git -C "$WORK/config-seed" push -q "$WORK/config.git" HEAD:main; }
# seed_node_copies HOME — tar copies (no .git) of code and config, like the first provision
seed_node_copies() {
  mkdir -p "$1/.local/share/fleet" "$1/.local/share/fleet-config"
  (cd "$ROOT" && tar -cf - .) | tar -xf - -C "$1/.local/share/fleet"
  (cd "$SRC/examples/fleet-config" && tar -cf - .) | tar -xf - -C "$1/.local/share/fleet-config"
}

# mk_home NAME [TOOLS] → prints $HOME for a node with enrol.json and local conf.
mk_home() {
  local name=$1 tools=${2:-"base devtools claude fake"} h
  h="$WORK/homes/$name"
  mkdir -p "$h/.config/fleet"
  printf '{"nonce":"n-%s","name":"%s","user":"root","os":"linux","arch":"amd64","container":true,"joined":"2026-10-03T00:00:00Z"}\n' "$name" "$name" >"$h/.config/fleet/enrol.json"
  printf 'FLEET_TOOLS="%s"\n' "$tools" >"$h/.config/fleet/fleet.conf"
  printf '%s\n' "$h"
}

fleet_as() {   # fleet_as HOME args...
  local h=$1; shift
  HOME="$h" "$ROOT/fleet" "$@"
}

# ---------- cases ----------

case_join() {
  begin "join: enrol.json, authorized_keys, ssh config, idempotent rerun"
  local h="$WORK/homes/alpha" code pub rc
  mkdir -p "$h"
  pub="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeMasterKeyForTests0000000000000000000000 fleet-master"
  code=$(MPUB="$pub" python3 -c 'import base64,json,os
print(base64.b64encode(json.dumps({"v":1,"ts_auth_key":"tskey-auth-test-FAKE","nonce":"nonce-alpha","name":"alpha",
  "master_pubkey":os.environ["MPUB"],"master_user":"root","tag":"tag:fleet-node"}).encode()).decode())')
  : >"$TS_LOG"
  HOME="$h" TMPDIR="$WORK/tmp" FLEET_INVITE_CODE="$code" bash "$ROOT/lib/join.sh" >"$WORK/join1.log" 2>&1; rc=$?
  assert "join exits 0 (see $WORK/join1.log)" [ "$rc" -eq 0 ] || sed 's/^/     | /' "$WORK/join1.log"
  assert "enrol.json written" [ -f "$h/.config/fleet/enrol.json" ]
  assert "enrol.json is 0600" [ "$(file_mode "$h/.config/fleet/enrol.json")" = 600 ]
  assert "enrol.json name=alpha" [ "$(jget "$h/.config/fleet/enrol.json" name)" = alpha ]
  assert "enrol.json nonce" [ "$(jget "$h/.config/fleet/enrol.json" nonce)" = nonce-alpha ]
  assert "enrol.json container=true" [ "$(jget "$h/.config/fleet/enrol.json" container)" = true ]
  assert "authorized_keys has master key once" [ "$(count_in "$pub" "$h/.ssh/authorized_keys")" = 1 ]
  assert "authorized_keys is 0600" [ "$(file_mode "$h/.ssh/authorized_keys")" = 600 ]
  assert ".ssh is 0700" [ "$(file_mode "$h/.ssh")" = 700 ]
  assert "three deploy keys generated" bash -c "[ -f '$h/.ssh/fleet_code' ] && [ -f '$h/.ssh/fleet_code.pub' ] && [ -f '$h/.ssh/fleet_config' ] && [ -f '$h/.ssh/fleet_memory.pub' ] && [ -f '$h/.ssh/fleet_config.pub' ]"
  assert "deploy keys are 0600" bash -c "[ \"\$(stat -c %a '$h/.ssh/fleet_code')\" = 600 ] && [ \"\$(stat -c %a '$h/.ssh/fleet_memory')\" = 600 ]"
  assert "ssh config block once" [ "$(count_in '# >>> fleet >>>' "$h/.ssh/config")" = 1 ]
  assert "ssh config has code, config and memory aliases" bash -c "grep -q 'Host github-fleet-code' '$h/.ssh/config' && grep -q 'Host github-fleet-config' '$h/.ssh/config' && grep -q 'Host github-fleet-memory' '$h/.ssh/config'"
  assert "tailscale up called with tag+hostname+file key" grep -q -- '^up --auth-key=file:.* --advertise-tags=tag:fleet-node --hostname=fleet-alpha$' "$TS_LOG"
  assert "auth key temp file removed" [ -z "$(find "$WORK/tmp" -name 'fleet-join.*' 2>/dev/null)" ]
  assert "final message mentions master" grep -q 'waiting for master' "$WORK/join1.log"
  # second run: nothing duplicated, tailscale up not repeated
  HOME="$h" TMPDIR="$WORK/tmp" FLEET_INVITE_CODE="$code" bash "$ROOT/lib/join.sh" >"$WORK/join2.log" 2>&1; rc=$?
  assert "rerun exits 0" [ "$rc" -eq 0 ]
  assert "rerun: master key still once" [ "$(count_in "$pub" "$h/.ssh/authorized_keys")" = 1 ]
  assert "rerun: ssh config block still once" [ "$(count_in '# >>> fleet >>>' "$h/.ssh/config")" = 1 ]
  assert "rerun: tailscale up called once overall" [ "$(grep -c '^up ' "$TS_LOG")" = 1 ]
  assert "rerun: deploy key unchanged" cmp -s "$h/.ssh/fleet_config.pub" "$h/.ssh/fleet_config.pub"
  # bad code
  HOME="$h" FLEET_INVITE_CODE="bm90anNvbg==" bash "$ROOT/lib/join.sh" >"$WORK/join3.log" 2>&1; rc=$?
  assert "invalid invite code is rejected" [ "$rc" -ne 0 ]
  # the master's FLEET_HOSTNAME_PREFIX travels in the code; a code without it (older master) keeps fleet-
  h="$WORK/homes/alpha2"; mkdir -p "$h"
  code=$(MPUB="$pub" python3 -c 'import base64,json,os
print(base64.b64encode(json.dumps({"v":1,"ts_auth_key":"tskey-auth-test-FAKE","nonce":"nonce-alpha2","name":"alpha2",
  "master_pubkey":os.environ["MPUB"],"master_user":"root","tag":"tag:fleet-node","hostname_prefix":"node-"}).encode()).decode())')
  : >"$TS_LOG"
  HOME="$h" TMPDIR="$WORK/tmp" FLEET_INVITE_CODE="$code" bash "$ROOT/lib/join.sh" >"$WORK/join4.log" 2>&1; rc=$?
  assert "join with hostname_prefix exits 0 (see $WORK/join4.log)" [ "$rc" -eq 0 ] || sed 's/^/     | /' "$WORK/join4.log"
  assert "tailscale hostname uses the prefix from the invite" grep -q -- '--hostname=node-alpha2$' "$TS_LOG"
  assert "join log names the prefixed hostname" grep -q 'hostname node-alpha2' "$WORK/join4.log"
  code=$(MPUB="$pub" python3 -c 'import base64,json,os
print(base64.b64encode(json.dumps({"v":1,"ts_auth_key":"tskey-auth-test-FAKE","nonce":"nonce-alpha3","name":"alpha3",
  "master_pubkey":os.environ["MPUB"],"master_user":"root","tag":"tag:fleet-node","hostname_prefix":"Bad Prefix"}).encode()).decode())')
  HOME="$h" TMPDIR="$WORK/tmp" FLEET_INVITE_CODE="$code" bash "$ROOT/lib/join.sh" >"$WORK/join5.log" 2>&1; rc=$?
  assert "an invalid hostname_prefix is rejected" bash -c "[ '$rc' -ne 0 ] && grep -q 'invalid hostname_prefix' '$WORK/join5.log'"
  end
}

# The T3 client key line (lib/common.sh T3_AUTHKEY_SCRIPT): the master pipes
# the desired line into `sh -c '<script>'` on the node; an empty line removes it.
case_t3_authkey() {
  begin "t3 client key: authorized_keys line added once, removed on an empty line, master key kept, 0600"
  local h="$WORK/homes/t3" master line script i
  mkdir -p "$h/.ssh"; chmod 700 "$h/.ssh"
  master="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeMasterKeyForTests0000000000000000000000 fleet-master"
  printf '%s\n' "$master" >"$h/.ssh/authorized_keys"; chmod 600 "$h/.ssh/authorized_keys"
  ssh-keygen -q -t ed25519 -N '' -C fleet-t3-client -f "$WORK/t3_client" </dev/null
  line=$(bash -c '. "$0/lib/common.sh"; t3_authorized_line "$1"' "$ROOT" "$WORK/t3_client.pub")
  script=$(bash -c '. "$0/lib/common.sh"; printf "%s" "$T3_AUTHKEY_SCRIPT"' "$ROOT")
  # shellcheck disable=SC2016  # $0 is the line, passed as the argument of bash -c
  assert "line = exact restricted options + key + comment" bash -c 'case "$0" in "restrict,port-forwarding,permitopen=\"127.0.0.1:*\",from=\"100.64.0.0/10,fd7a:115c:a1e0::/48\" ssh-ed25519 AAAA"*" fleet-t3-client") exit 0 ;; esac; exit 1' "$line"
  for i in 1 2; do printf '%s\n' "$line" | HOME="$h" sh -c "$script" || { CASE_FAIL=1; echo "   - failed: script run $i"; }; done
  assert "t3 line present exactly once after two runs" [ "$(count_in ' fleet-t3-client' "$h/.ssh/authorized_keys")" = 1 ]
  assert "the stored line is exactly the one produced" grep -qxF "$line" "$h/.ssh/authorized_keys"
  assert "master key kept" [ "$(count_in "$master" "$h/.ssh/authorized_keys")" = 1 ]
  assert "authorized_keys 0600" [ "$(file_mode "$h/.ssh/authorized_keys")" = 600 ]
  refute "no temp file left" bash -c "ls '$h'/.ssh/.fleet.* 2>/dev/null | grep -q ."
  printf '\n' | HOME="$h" sh -c "$script" || { CASE_FAIL=1; echo "   - failed: removal run"; }
  assert "an empty line removes the t3 line" [ "$(count_in ' fleet-t3-client' "$h/.ssh/authorized_keys")" = 0 ]
  assert "master key still there after removal" [ "$(count_in "$master" "$h/.ssh/authorized_keys")" = 1 ]
  printf '\n' | HOME="$h" sh -c "$script"
  assert "removal is idempotent" [ "$(count_in "$master" "$h/.ssh/authorized_keys")" = 1 ]
  mkdir -p "$WORK/homes/t3empty"
  printf '\n' | HOME="$WORK/homes/t3empty" sh -c "$script"
  refute "nothing to add and no file: none created" [ -e "$WORK/homes/t3empty/.ssh/authorized_keys" ]
  printf '%s\n' "$line" | HOME="$WORK/homes/t3empty" sh -c "$script"
  assert "created from scratch: 0700 dir, 0600 file, the line" bash -c "[ \"\$(stat -c %a '$WORK/homes/t3empty/.ssh')\" = 700 ] && [ \"\$(stat -c %a '$WORK/homes/t3empty/.ssh/authorized_keys')\" = 600 ] && grep -qxF \"\$0\" '$WORK/homes/t3empty/.ssh/authorized_keys'" "$line"
  end
}

# The dispatcher: -h/--help prints a synopsis and runs nothing; unknown flags
# exit 2 before anything happens (a `fleet leave --help` must not log out).
case_help() {
  begin "dispatcher: --help runs nothing, unknown flags exit 2"
  local h out rc
  h=$(mk_home help "")
  echo "fleet-help" >"$TS_STATE"; : >"$TS_LOG"
  out=$(fleet_as "$h" leave --help 2>&1); rc=$?
  assert "fleet leave --help: exit 0, synopsis, no tailscale logout" bash -c "[ '$rc' -eq 0 ] && [ '$out' = 'fleet leave' ] && [ ! -s '$TS_LOG' ] && [ -f '$TS_STATE' ]"
  out=$(fleet_as "$h" daemon -h 2>&1); rc=$?
  assert "fleet daemon -h: exit 0, no daemon.pid" bash -c "[ '$rc' -eq 0 ] && [ ! -f '$h/.config/fleet/daemon.pid' ]"
  out=$(fleet_as "$h" apply --help 2>&1); rc=$?
  assert "fleet apply --help: exit 0, nothing applied" bash -c "[ '$rc' -eq 0 ] && [ ! -f '$h/.config/fleet/env.sh' ]"
  for c in "leave --bogus" "daemon --bogus" "status --bogus" "memory sync --bogus" "update extra" "pull --bogus" "join --bogus" "apply --from-master"; do
    # shellcheck disable=SC2086
    out=$(fleet_as "$h" $c 2>&1); rc=$?
    assert "fleet $c: exit 2 with usage" bash -c "[ '$rc' -eq 2 ] && printf '%s' '$out' | grep -q 'usage:'"
  done
  assert "no daemon.pid, no env.sh, no logout after the rejected runs" bash -c "[ ! -f '$h/.config/fleet/daemon.pid' ] && [ ! -f '$h/.config/fleet/env.sh' ] && [ ! -s '$TS_LOG' ]"
  end
}

case_apply() {
  begin "apply: env.sh 0600, rc block once after two runs, status.json, memory clone"
  local h rc
  h=$(mk_home beta)
  touch "$h/.bashrc" "$h/.profile"
  : >"$FLEET_TEST_LOG"
  fleet_as "$h" apply >"$WORK/apply1.log" 2>&1; rc=$?
  assert "apply exits 0 (see $WORK/apply1.log)" [ "$rc" -eq 0 ] || sed 's/^/     | /' "$WORK/apply1.log"
  assert "env.sh exists" [ -f "$h/.config/fleet/env.sh" ]
  assert "env.sh is 0600" [ "$(file_mode "$h/.config/fleet/env.sh")" = 600 ]
  refute "env.sh does not export ANTHROPIC_BASE_URL without the cliproxy tool" grep -q "ANTHROPIC_BASE_URL=" "$h/.config/fleet/env.sh"
  assert "env.sh clears stale proxy variables before sourcing secrets" bash -c "grep -qx 'unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN' '$h/.config/fleet/env.sh' && [ \"\$(grep -n 'unset ANTHROPIC' '$h/.config/fleet/env.sh' | cut -d: -f1)\" -lt \"\$(grep -n 'secrets.env' '$h/.config/fleet/env.sh' | head -1 | cut -d: -f1)\" ]"
  assert "a stale ANTHROPIC_BASE_URL from the environment is gone after sourcing env.sh, a secret-provided one survives" bash -c "printf \"ANTHROPIC_BASE_URL='http://secret.invalid'\n\" >'$h/.config/fleet/secrets.env'; ANTHROPIC_BASE_URL=stale bash -c '. \"$h/.config/fleet/env.sh\"; [ \"\$ANTHROPIC_BASE_URL\" = http://secret.invalid ]'; r=\$?; rm -f '$h/.config/fleet/secrets.env'; exit \$r"
  assert "apply reports why no proxy is exported" grep -q 'no proxy: cliproxy not enabled' "$WORK/apply1.log"
  assert "env.sh exports FLEET_NODE" grep -q "FLEET_NODE='beta'" "$h/.config/fleet/env.sh"
  assert "env.sh sources cleanly" bash -c ". '$h/.config/fleet/env.sh' && [ \"\$FLEET_NODE_NAME\" = beta ] && case \$PATH in *.local/bin*) ;; *) exit 1;; esac"
  assert "rc block in .bashrc" [ "$(count_in '# >>> fleet >>>' "$h/.bashrc")" = 1 ]
  assert "rc block in .profile" [ "$(count_in '# >>> fleet >>>' "$h/.profile")" = 1 ]
  # shellcheck disable=SC2016  # literal CONTRACT line
  assert "rc line matches CONTRACT" grep -qF '[ -f "$HOME/.config/fleet/env.sh" ] && . "$HOME/.config/fleet/env.sh"' "$h/.bashrc"
  assert "all stub tools installed" [ "$(grep -c '^install ' "$FLEET_TEST_LOG")" = 4 ]
  assert "applied digest written" [ -s "$h/.config/fleet/applied" ]
  assert "status.json written" [ -f "$h/.config/fleet/status.json" ]
  assert "status: tools.base ok" [ "$(jget "$h/.config/fleet/status.json" tools.base.state)" = ok ]
  assert "status: tools.fake needs login" [ "$(jget "$h/.config/fleet/status.json" tools.fake.state)" = login ]
  assert "status: memory ok" [ "$(jget "$h/.config/fleet/status.json" memory.state)" = ok ]
  assert "status: container true" [ "$(jget "$h/.config/fleet/status.json" container)" = true ]
  assert "memory vault cloned" [ -d "$h/fleet-memory/.git" ]
  assert "memory git user.name" [ "$(git -C "$h/fleet-memory" config user.name)" = fleet-beta ]
  assert "memory nodes/beta exists" [ -d "$h/fleet-memory/nodes/beta" ]
  # second run: converges, no duplicate rc blocks, backup made once; a moved
  # memory remote (FLEET_MEMORY_REPO changed) is re-pointed on the existing clone
  git -C "$h/fleet-memory" remote set-url origin "$WORK/old-memory-location.git"
  fleet_as "$h" apply >"$WORK/apply2.log" 2>&1; rc=$?
  assert "second apply exits 0" [ "$rc" -eq 0 ]
  assert "memory origin follows the configured remote" bash -c "[ \"\$(git -C '$h/fleet-memory' remote get-url origin)\" = '$WORK/memory.git' ] && grep -q 'memory: origin .*old-memory-location.git -> ' '$WORK/apply2.log'"
  assert "rc block still once in .bashrc" [ "$(count_in '# >>> fleet >>>' "$h/.bashrc")" = 1 ]
  assert "rc block still once in .profile" [ "$(count_in '# >>> fleet >>>' "$h/.profile")" = 1 ]
  assert ".bashrc backed up once" [ -f "$h/.bashrc.pre-fleet" ]
  assert "lock released" [ ! -d "$h/.config/fleet/locks/apply" ]
  # --from-master digest is recorded verbatim
  fleet_as "$h" apply --from-master deadbeef >/dev/null 2>&1
  assert "--from-master digest stored" [ "$(cat "$h/.config/fleet/applied")" = deadbeef ]
  # required vs optional tool failure; a failed apply must not refresh the success markers
  HOME="$h" FLEET_FAKE_FAIL_CLAUDE=1 "$ROOT/fleet" apply --from-master cafef00d >"$WORK/apply3.log" 2>&1; rc=$?
  assert "required tool failure -> non-zero" [ "$rc" -ne 0 ]
  assert "failed apply leaves the applied digest alone" [ "$(cat "$h/.config/fleet/applied")" = deadbeef ]
  assert "failed apply releases the lock" [ ! -d "$h/.config/fleet/locks/apply" ]
  HOME="$h" FLEET_FAKE_FAIL_FAKE=1 "$ROOT/fleet" apply >"$WORK/apply4.log" 2>&1; rc=$?
  assert "optional tool failure -> zero with warning" bash -c "[ '$rc' -eq 0 ] && grep -q 'warn.*fake' '$WORK/apply4.log'"
  # status --json is valid and human status prints
  fleet_as "$h" status --json >"$WORK/status.json" 2>/dev/null
  assert "status --json valid" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["name"]=="beta" and "timers" in d and "pull" in d["timers"]' "$WORK/status.json"
  assert "status table prints" bash -c "HOME='$h' '$ROOT/fleet' status 2>/dev/null | grep -q '^node .*beta'"
  # update and login
  : >"$FLEET_TEST_LOG"
  fleet_as "$h" update >/dev/null 2>&1; rc=$?
  assert "update runs every tool" bash -c "[ '$rc' -eq 0 ] && [ \"\$(grep -c '^update ' '$FLEET_TEST_LOG')\" = 4 ]"
  fleet_as "$h" login >/dev/null 2>&1; rc=$?
  assert "login runs the tool that needs it" bash -c "[ '$rc' -eq 0 ] && grep -q '^login fake' '$FLEET_TEST_LOG'"
  assert "status after login: fake ok" [ "$(jget "$h/.config/fleet/status.json" tools.fake.state)" = ok ]
  end
}

# The proxy variables are exported only while cliproxy is enabled for the node:
# in a container that means remote mode against FLEET_PROXY_URL (no local
# CLIProxyAPI, no client key); without a URL nothing is exported at all.
case_apply_proxy() {
  begin "apply: ANTHROPIC_* exported only with cliproxy enabled (remote URL in containers), never without"
  local h rc
  h=$(mk_home proxy "base cliproxy")
  printf 'FLEET_PROXY_URL="http://proxy.invalid:8317"\n' >>"$h/.config/fleet/fleet.conf"
  fleet_as "$h" apply >"$WORK/apply-proxy.log" 2>&1; rc=$?
  assert "apply exits 0 (see $WORK/apply-proxy.log)" [ "$rc" -eq 0 ] || sed 's/^/     | /' "$WORK/apply-proxy.log"
  assert "env.sh exports the remote proxy URL" grep -q "ANTHROPIC_BASE_URL='http://proxy.invalid:8317'" "$h/.config/fleet/env.sh"
  refute "no client token in remote mode" grep -q 'ANTHROPIC_AUTH_TOKEN' "$h/.config/fleet/env.sh"
  refute "no unset line while the proxy is enabled" grep -q 'unset ANTHROPIC' "$h/.config/fleet/env.sh"
  assert "apply says remote proxy" grep -q 'remote proxy http://proxy.invalid:8317' "$WORK/apply-proxy.log"
  # cliproxy dropped from FLEET_TOOLS: the next apply withdraws the variables
  printf 'FLEET_TOOLS="base"\n' >"$h/.config/fleet/fleet.conf"
  fleet_as "$h" apply >"$WORK/apply-proxy2.log" 2>&1
  assert "cliproxy removed: env.sh unsets the proxy variables" bash -c "grep -qx 'unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN' '$h/.config/fleet/env.sh' && ! grep -q 'ANTHROPIC_BASE_URL=' '$h/.config/fleet/env.sh'"
  # cliproxy enabled but no URL: nothing to point at
  printf 'FLEET_TOOLS="base cliproxy"\nFLEET_PROXY_URL=""\n' >"$h/.config/fleet/fleet.conf"
  fleet_as "$h" apply >"$WORK/apply-proxy3.log" 2>&1
  refute "cliproxy without FLEET_PROXY_URL exports nothing" grep -q 'ANTHROPIC_BASE_URL=' "$h/.config/fleet/env.sh"
  end
}

# No memory repo at all (FLEET_MEMORY_REPO empty, no FLEET_MEMORY_REMOTE): apply
# and sync succeed, nothing is cloned, no memory timer exists, status says off.
case_memory_off() {
  begin "memory off: apply/sync/status/daemon without a memory repo"
  local h rc out
  h=$(mk_home nomem "base")
  env -u FLEET_MEMORY_REMOTE HOME="$h" "$ROOT/fleet" apply >"$WORK/apply-nomem.log" 2>&1; rc=$?
  assert "apply exits 0 without a memory repo (see $WORK/apply-nomem.log)" [ "$rc" -eq 0 ] || sed 's/^/     | /' "$WORK/apply-nomem.log"
  assert "apply says shared memory is off" grep -q 'shared memory is off' "$WORK/apply-nomem.log"
  refute "nothing cloned" [ -e "$h/fleet-memory" ]
  assert "memory.state off" [ "$(grep '^state=' "$h/.config/fleet/memory.state")" = state=off ]
  out=$(env -u FLEET_MEMORY_REMOTE HOME="$h" "$ROOT/fleet" memory sync 2>&1); rc=$?
  assert "memory sync exits 0 and is quiet" bash -c "[ '$rc' -eq 0 ] && [ -z '$out' ]"
  env -u FLEET_MEMORY_REMOTE HOME="$h" "$ROOT/fleet" status --json >"$WORK/status-nomem.json" 2>/dev/null
  assert "status: memory.state off, no memory timer listed, pull timer still there" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["memory"]["state"]=="off" and "memory" not in d["timers"] and "pull" in d["timers"]' "$WORK/status-nomem.json"
  assert "status table prints memory off" bash -c "env -u FLEET_MEMORY_REMOTE HOME='$h' '$ROOT/fleet' status 2>/dev/null | grep -q '^memory *off'"
  # the daemon schedules only pull and update
  echo "fleet-nomem" >"$TS_STATE"
  env -u FLEET_MEMORY_REMOTE HOME="$h" "$ROOT/fleet" daemon >"$WORK/daemon-nomem.log" 2>&1 & local pid=$!
  sleep 2
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert "daemon job list has no memory job" bash -c "grep -q 'jobs: pull update' '$WORK/daemon-nomem.log' && ! grep -q '^memory=' '$h/.config/fleet/daemon.state'"
  # the same node with a memory remote again: the job comes back
  fleet_as "$h" apply >"$WORK/apply-nomem2.log" 2>&1; rc=$?
  assert "apply with a memory remote again clones and reports ok" bash -c "[ '$rc' -eq 0 ] && [ -d '$h/fleet-memory/.git' ] && [ \"\$(grep '^state=' '$h/.config/fleet/memory.state')\" = state=ok ]"
  end
}

case_memory_sync() {
  begin "memory sync: commits only nodes/<name>, leaves other paths unstaged"
  local h="$WORK/homes/beta" m rc
  m="$h/fleet-memory"
  printf -- '---\nnode: beta\ncreated: 2026-10-03\ntags: [test]\n---\n# Beta note\n\nhello\n' >"$m/nodes/beta/first.md"
  printf '# evil\n' >"$m/notes/evil.md"
  echo "tampered" >>"$m/README.md"
  git -C "$m" add notes/evil.md      # even pre-staged foreign paths must not be committed
  fleet_as "$h" memory sync >"$WORK/sync1.log" 2>&1; rc=$?
  assert "sync exits 0 (see $WORK/sync1.log)" [ "$rc" -eq 0 ] || sed 's/^/     | /' "$WORK/sync1.log"
  assert "remote has nodes/beta/first.md" git --git-dir="$WORK/memory.git" cat-file -e main:nodes/beta/first.md
  assert "remote has no notes/evil.md" bash -c "! git --git-dir='$WORK/memory.git' cat-file -e main:notes/evil.md"
  assert "remote README untouched" bash -c "! git --git-dir='$WORK/memory.git' show main:README.md | grep -q tampered"
  assert "commit touches only nodes/beta" bash -c "git --git-dir='$WORK/memory.git' show --name-only --format= main | grep -v '^nodes/beta/' | grep -q . && exit 1; exit 0"
  assert "commit subject" bash -c "git --git-dir='$WORK/memory.git' log -1 --format=%s main | grep -q '^memory: beta '"
  assert "local foreign changes still present" bash -c "[ -f '$m/notes/evil.md' ] && grep -q tampered '$m/README.md'"
  assert "memory state ok" [ "$(grep '^state=' "$h/.config/fleet/memory.state")" = state=ok ]
  fleet_as "$h" status --json >"$WORK/status2.json" 2>/dev/null
  assert "status reports unstaged foreign changes" bash -c "grep -q 'unstaged changes outside nodes/beta' '$WORK/status2.json'"
  assert "status has last_sync" [ "$(jget "$WORK/status2.json" memory.last_sync)" != null ]
  # nothing to do → still exit 0, no new commit
  local tip; tip=$(git --git-dir="$WORK/memory.git" rev-parse main)
  fleet_as "$h" memory sync >/dev/null 2>&1; rc=$?
  assert "idle sync exits 0" [ "$rc" -eq 0 ]
  assert "idle sync pushes nothing" [ "$(git --git-dir="$WORK/memory.git" rev-parse main)" = "$tip" ]
  end
}

case_memory_concurrent() {
  begin "memory sync: two nodes syncing concurrently both succeed"
  local hg hd rc1 rc2
  hg=$(mk_home gamma ""); hd=$(mk_home delta "")
  fleet_as "$hg" apply >/dev/null 2>&1; fleet_as "$hd" apply >/dev/null 2>&1
  assert "gamma cloned" [ -d "$hg/fleet-memory/.git" ]
  assert "delta cloned" [ -d "$hd/fleet-memory/.git" ]
  echo "# gamma" >"$hg/fleet-memory/nodes/gamma/g.md"
  echo "# delta" >"$hd/fleet-memory/nodes/delta/d.md"
  fleet_as "$hg" memory sync >"$WORK/sync-gamma.log" 2>&1 & local p1=$!
  fleet_as "$hd" memory sync >"$WORK/sync-delta.log" 2>&1 & local p2=$!
  wait "$p1"; rc1=$?; wait "$p2"; rc2=$?
  assert "gamma sync exits 0" [ "$rc1" -eq 0 ]
  assert "delta sync exits 0" [ "$rc2" -eq 0 ]
  assert "remote has gamma note" git --git-dir="$WORK/memory.git" cat-file -e main:nodes/gamma/g.md
  assert "remote has delta note" git --git-dir="$WORK/memory.git" cat-file -e main:nodes/delta/d.md
  assert "gamma state ok" [ "$(grep '^state=' "$hg/.config/fleet/memory.state")" = state=ok ]
  assert "delta state ok" [ "$(grep '^state=' "$hd/.config/fleet/memory.state")" = state=ok ]
  end
}

case_memory_conflict() {
  begin "memory sync: forced rebase conflict -> state conflict, clean repo, --reset recovers"
  local h m other rc tip
  h=$(mk_home epsilon ""); m="$h/fleet-memory"
  fleet_as "$h" apply >/dev/null 2>&1
  echo "A" >"$m/nodes/epsilon/c.md"
  fleet_as "$h" memory sync >/dev/null 2>&1
  assert "initial push" git --git-dir="$WORK/memory.git" cat-file -e main:nodes/epsilon/c.md
  # someone else rewrites our file on the remote
  other="$WORK/other-clone"; rm -rf "$other"
  git clone -q "$WORK/memory.git" "$other"
  echo "B" >"$other/nodes/epsilon/c.md"
  git -C "$other" commit -qam "foreign edit"; git -C "$other" push -q origin main
  # we change the same line locally
  echo "C" >"$m/nodes/epsilon/c.md"
  fleet_as "$h" memory sync >"$WORK/sync-conflict.log" 2>&1; rc=$?
  assert "conflicting sync exits 0" [ "$rc" -eq 0 ]
  assert "warned about conflict" grep -qi 'conflict' "$WORK/sync-conflict.log"
  assert "state=conflict" [ "$(grep '^state=' "$h/.config/fleet/memory.state")" = state=conflict ]
  assert "no rebase in progress" bash -c "[ ! -d '$m/.git/rebase-merge' ] && [ ! -d '$m/.git/rebase-apply' ]"
  assert "working tree clean" [ -z "$(git -C "$m" status --porcelain)" ]
  assert "local commit kept" [ "$(cat "$m/nodes/epsilon/c.md")" = C ]
  fleet_as "$h" status --json >"$WORK/status-conflict.json" 2>/dev/null
  assert "status.json memory.state=conflict" [ "$(jget "$WORK/status-conflict.json" memory.state)" = conflict ]
  # while in conflict, sync is a no-op
  tip=$(git --git-dir="$WORK/memory.git" rev-parse main)
  echo "D" >"$m/nodes/epsilon/d.md"
  fleet_as "$h" memory sync >/dev/null 2>&1
  assert "conflict state stops pushing" [ "$(git --git-dir="$WORK/memory.git" rev-parse main)" = "$tip" ]
  # master repairs: take the remote version, then --reset
  git -C "$m" fetch -q origin && git -C "$m" reset -q --hard origin/main
  echo "D" >"$m/nodes/epsilon/d.md"
  fleet_as "$h" memory sync --reset >"$WORK/sync-reset.log" 2>&1; rc=$?
  assert "--reset sync exits 0" [ "$rc" -eq 0 ]
  assert "state back to ok" [ "$(grep '^state=' "$h/.config/fleet/memory.state")" = state=ok ]
  assert "remote has d.md after reset" git --git-dir="$WORK/memory.git" cat-file -e main:nodes/epsilon/d.md
  end
}

case_pull() {
  begin "pull: tar copies of code + config convert to git checkouts, either repo's change re-applies, quiet when unchanged"
  local h share cfg rc before after out
  h=$(mk_home zeta "base")
  share="$h/.local/share/fleet"; cfg="$h/.local/share/fleet-config"
  seed_node_copies "$h"            # first provision = tar copies without .git
  fleet_as "$h" pull >"$WORK/pull1.log" 2>&1; rc=$?
  assert "pull exits 0 (see $WORK/pull1.log)" [ "$rc" -eq 0 ] || sed 's/^/     | /' "$WORK/pull1.log"
  assert "code converted to a git checkout of code.git" bash -c "[ -d '$share/.git' ] && [ \"\$(git -C '$share' remote get-url origin)\" = '$WORK/code.git' ]"
  assert "config converted to a git checkout of config.git" bash -c "[ -d '$cfg/.git' ] && [ \"\$(git -C '$cfg' remote get-url origin)\" = '$WORK/config.git' ]"
  assert "both HEADs match their remote main" bash -c "[ \"\$(git -C '$share' rev-parse HEAD)\" = '$(code_head)' ] && [ \"\$(git -C '$cfg' rev-parse HEAD)\" = '$(config_head)' ]"
  assert "apply ran after convert" [ -s "$h/.config/fleet/applied" ]
  assert "applied_commit = <code>+<config>" [ "$(cat "$h/.config/fleet/applied_commit")" = "$(pair)" ]
  assert "local bin fleet symlink" [ "$(readlink "$h/.local/bin/fleet")" = "$share/fleet" ]
  before=$(cat "$h/.config/fleet/applied")
  # code remote changes → pull resets and re-applies with the new code
  commit_code "code v2"
  fleet_as "$h" pull >"$WORK/pull2.log" 2>&1; rc=$?
  assert "pull after a code change exits 0" [ "$rc" -eq 0 ]
  assert "new code file present" [ -f "$share/MARKER" ]
  after=$(cat "$h/.config/fleet/applied")
  assert "applied digest changed" [ "$before" != "$after" ]
  assert "status: code_commit" [ "$(jget "$h/.config/fleet/status.json" code_commit)" = "$(code_head)" ]
  assert "status: config_commit" [ "$(jget "$h/.config/fleet/status.json" config_commit)" = "$(config_head)" ]
  assert "applied_commit follows" [ "$(cat "$h/.config/fleet/applied_commit")" = "$(pair)" ]
  # config remote changes alone → pull applies too
  before=$after
  commit_config "config v2"
  fleet_as "$h" pull >"$WORK/pull3.log" 2>&1; rc=$?
  assert "pull after a config-only change exits 0 and applies" bash -c "[ '$rc' -eq 0 ] && [ -f '$cfg/MARKER' ] && grep -q 'apply done' '$WORK/pull3.log'"
  assert "applied_commit records the new config commit" [ "$(cat "$h/.config/fleet/applied_commit")" = "$(pair)" ]
  # nothing changed → silent
  out=$(fleet_as "$h" pull 2>&1); rc=$?
  assert "unchanged pull exits 0" [ "$rc" -eq 0 ]
  assert "unchanged pull is quiet" [ -z "$out" ]
  # --no-apply: both checkouts move, nothing is applied (the master runs this before its own apply)
  before=$(cat "$h/.config/fleet/applied_commit")
  commit_code "code v2b"; commit_config "config v2b"
  out=$(fleet_as "$h" pull --no-apply 2>&1); rc=$?
  assert "pull --no-apply exits 0 and moves both checkouts" bash -c "[ '$rc' -eq 0 ] && [ \"\$(git -C '$share' rev-parse HEAD)\" = '$(code_head)' ] && [ \"\$(git -C '$cfg' rev-parse HEAD)\" = '$(config_head)' ]"
  assert "pull --no-apply does not apply" bash -c "[ \"\$(cat '$h/.config/fleet/applied_commit')\" = '$before' ] && ! printf '%s' '$out' | grep -q 'apply done'"
  assert "pull --no-apply released the lock" [ ! -d "$h/.config/fleet/locks/apply" ]
  fleet_as "$h" pull >"$WORK/pull-after-noapply.log" 2>&1; rc=$?
  assert "the next plain pull applies the pending commits" bash -c "[ '$rc' -eq 0 ] && [ \"\$(cat '$h/.config/fleet/applied_commit')\" = '$(pair)' ]"
  refute "pull rejects unknown flags" fleet_as "$h" pull --bogus
  # a changed remote URL (repo moved) is applied to the existing checkout; an
  # unreachable one warns, exits 0, applies nothing, and is corrected by the
  # next pull with the right URL
  out=$(HOME="$h" FLEET_CODE_REMOTE="$WORK/does-not-exist.git" "$ROOT/fleet" pull 2>&1); rc=$?
  assert "changed code remote: origin re-pointed, fetch failure exits 0 with a warning, no apply" bash -c "[ '$rc' -eq 0 ] && [ \"\$(git -C '$share' remote get-url origin)\" = '$WORK/does-not-exist.git' ] && printf '%s' '$out' | grep -q 'code: origin .*code.git -> .*does-not-exist.git' && printf '%s' '$out' | grep -q 'fetch failed' && ! printf '%s' '$out' | grep -q 'apply done'"
  out=$(fleet_as "$h" pull 2>&1); rc=$?
  assert "remote back to the configured URL on the next pull" bash -c "[ '$rc' -eq 0 ] && [ \"\$(git -C '$share' remote get-url origin)\" = '$WORK/code.git' ] && printf '%s' '$out' | grep -q 'code: origin .*does-not-exist.git -> .*code.git'"
  git -C "$cfg" remote set-url origin "$WORK/elsewhere-config.git"
  out=$(fleet_as "$h" pull 2>&1)
  assert "config checkout origin follows FLEET_CONFIG_REMOTE too" bash -c "[ \"\$(git -C '$cfg' remote get-url origin)\" = '$WORK/config.git' ] && printf '%s' '$out' | grep -q 'config: origin .*elsewhere-config.git -> '"
  # missing config dir with a reachable remote → cloned
  rm -rf "$cfg"
  fleet_as "$h" pull >"$WORK/pull-clone.log" 2>&1; rc=$?
  assert "missing config dir is cloned by pull" bash -c "[ '$rc' -eq 0 ] && [ -d '$cfg/.git' ] && [ -f '$cfg/AGENTS.md' ]"
  end
}

case_pull_retry() {
  begin "pull: failed apply keeps applied_commit, next pull retries the same commits"
  local h="$WORK/homes/zeta" share rc v3 before before_digest out lp
  share="$h/.local/share/fleet"
  printf 'FLEET_TOOLS="base claude"\n' >"$h/.config/fleet/fleet.conf"   # claude is required
  assert "applied_commit recorded by the last good apply" [ "$(cat "$h/.config/fleet/applied_commit")" = "$(pair)" ]
  before=$(cat "$h/.config/fleet/applied_commit"); before_digest=$(cat "$h/.config/fleet/applied")
  commit_code "code v3"
  v3=$(code_head)
  HOME="$h" FLEET_FAKE_FAIL_CLAUDE=1 "$ROOT/fleet" pull >"$WORK/pull-fail.log" 2>&1; rc=$?
  assert "pull with a failing required tool exits non-zero" [ "$rc" -ne 0 ]
  assert "checkout moved to v3" [ "$(git -C "$share" rev-parse HEAD)" = "$v3" ]
  assert "applied_commit unchanged after the failed apply" [ "$(cat "$h/.config/fleet/applied_commit")" = "$before" ]
  assert "applied digest unchanged after the failed apply" [ "$(cat "$h/.config/fleet/applied")" = "$before_digest" ]
  # the next run finds HEAD == origin/main but applied_commit behind: retries without fetching anything new
  fleet_as "$h" pull >"$WORK/pull-retry.log" 2>&1; rc=$?
  assert "retry pull exits 0 (see $WORK/pull-retry.log)" [ "$rc" -eq 0 ] || sed 's/^/     | /' "$WORK/pull-retry.log"
  assert "retry announced" grep -q 'retrying' "$WORK/pull-retry.log"
  assert "applied_commit now v3+config" [ "$(cat "$h/.config/fleet/applied_commit")" = "$(pair)" ]
  assert "status.json applied_commit = code_commit+config_commit" [ "$(jget "$h/.config/fleet/status.json" applied_commit)" = "$(jget "$h/.config/fleet/status.json" code_commit)+$(jget "$h/.config/fleet/status.json" config_commit)" ]
  out=$(fleet_as "$h" pull 2>&1); rc=$?
  assert "pull after the retry is quiet" bash -c "[ '$rc' -eq 0 ] && [ -z '$out' ]"
  # apply lock held by a live process -> apply (hence pull) times out non-zero and leaves applied_commit alone
  mkdir -p "$h/.config/fleet/locks/apply"; sleep 60 & lp=$!; echo "$lp" >"$h/.config/fleet/locks/apply/pid"
  commit_code "code v4"
  HOME="$h" FLEET_APPLY_LOCK_WAIT=2 "$ROOT/fleet" pull >"$WORK/pull-locked.log" 2>&1; rc=$?
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null; rm -rf "$h/.config/fleet/locks/apply"
  assert "pull while apply is locked exits non-zero (lock timeout)" [ "$rc" -ne 0 ]
  assert "lock timeout says so" grep -q 'another fleet apply is running' "$WORK/pull-locked.log"
  assert "applied_commit still v3 (v4 retried next time)" [ "$(cat "$h/.config/fleet/applied_commit")" = "$v3+$(config_head)" ]
  fleet_as "$h" pull >"$WORK/pull-v4.log" 2>&1; rc=$?
  assert "next pull applies v4" bash -c "[ '$rc' -eq 0 ] && [ \"\$(cat '$h/.config/fleet/applied_commit')\" = '$(pair)' ]"
  end
}

# N3: pull takes the apply lock before fetch/reset, so a running apply keeps
# its checkout and records the commits it started from; pull applies the new
# ones afterwards.
case_pull_concurrent() {
  begin "pull: waits for a running apply before resetting the checkout; apply records its start commits"
  local h share c1 c2 k apid i rc prc
  h=$(mk_home theta "base slow")
  share="$h/.local/share/fleet"
  git clone -q "$WORK/code.git" "$share"
  git clone -q "$WORK/config.git" "$h/.local/share/fleet-config"
  fleet_as "$h" apply >"$WORK/apply-theta0.log" 2>&1; rc=$?
  assert "baseline apply exits 0" [ "$rc" -eq 0 ]
  c1=$(code_head); k=$(config_head)
  assert "baseline applied_commit = c1+k" [ "$(cat "$h/.config/fleet/applied_commit")" = "$c1+$k" ]
  HOME="$h" FLEET_SLOW_INSTALL=6 "$ROOT/fleet" apply >"$WORK/apply-slow.log" 2>&1 & apid=$!
  i=0; while [ "$i" -lt 50 ] && [ ! -f "$h/.config/fleet/locks/apply/pid" ]; do sleep 0.1; i=$((i + 1)); done
  assert "slow apply holds the lock" [ "$(cat "$h/.config/fleet/locks/apply/pid" 2>/dev/null)" = "$apid" ]
  echo "concurrent" >"$WORK/code-seed/MARKER-CONC"; git -C "$WORK/code-seed" add -A; git -C "$WORK/code-seed" commit -q -m "code conc"; git -C "$WORK/code-seed" push -q "$WORK/code.git" HEAD:main
  c2=$(code_head)
  fleet_as "$h" pull >"$WORK/pull-conc.log" 2>&1 & prc=$!
  sleep 2
  assert "pull is blocked on the lock: checkout still at c1" [ "$(git -C "$share" rev-parse HEAD)" = "$c1" ]
  assert "pull did not steal the lock" [ "$(cat "$h/.config/fleet/locks/apply/pid" 2>/dev/null)" = "$apid" ]
  assert "slow apply still running" kill -0 "$apid"
  wait "$apid"; rc=$?
  assert "slow apply exits 0 (see $WORK/apply-slow.log)" [ "$rc" -eq 0 ] || sed 's/^/     | /' "$WORK/apply-slow.log"
  assert "slow apply recorded the commits it started from (c1+k)" grep -q "apply done .*revs $c1+$k" "$WORK/apply-slow.log"
  wait "$prc"; rc=$?
  assert "pull exits 0 (see $WORK/pull-conc.log)" [ "$rc" -eq 0 ] || sed 's/^/     | /' "$WORK/pull-conc.log"
  assert "pull announced c1 -> c2" grep -q "revs $c1+$k -> $c2+$k" "$WORK/pull-conc.log"
  assert "pull's apply ran from c2" grep -q "apply done .*revs $c2+$k" "$WORK/pull-conc.log"
  assert "checkout at c2 with the new file" bash -c "[ \"\$(git -C '$share' rev-parse HEAD)\" = '$c2' ] && [ -f '$share/MARKER-CONC' ]"
  assert "applied_commit = c2+k" [ "$(cat "$h/.config/fleet/applied_commit")" = "$c2+$k" ]
  assert "lock released" [ ! -d "$h/.config/fleet/locks/apply" ]
  end
}

case_leave() {
  begin "leave: stops the daemon (TERM, wait) and its children, logs out, removes daemon.pid"
  local h pid rc i alive=1
  h=$(mk_home iota "")
  echo "fleet-iota" >"$TS_STATE"
  : >"$TS_LOG"
  HOME="$h" "$ROOT/fleet" daemon >"$WORK/daemon-leave.log" 2>&1 &
  pid=$!
  sleep 2
  assert "daemon running" kill -0 "$pid"
  assert "daemon.pid written" [ "$(cat "$h/.config/fleet/daemon.pid" 2>/dev/null)" = "$pid" ]
  fleet_as "$h" leave >"$WORK/leave.log" 2>&1; rc=$?
  assert "leave exits 0 (see $WORK/leave.log)" [ "$rc" -eq 0 ] || sed 's/^/     | /' "$WORK/leave.log"
  i=0
  while [ "$i" -lt 30 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then alive=0; break; fi
    sleep 0.1; i=$((i + 1))
  done
  wait "$pid" 2>/dev/null
  assert "daemon gone after leave" [ "$alive" -eq 0 ]
  assert "leave reported the daemon stop" grep -q "daemon stopped (pid $pid)" "$WORK/leave.log"
  assert "daemon's own exit path ran leave once (guarded, no self-signal)" grep -q 'fleet daemon stopping' "$WORK/daemon-leave.log"
  assert "tailscale logout ran" grep -q '^logout' "$TS_LOG"
  assert "daemon.pid removed" [ ! -f "$h/.config/fleet/daemon.pid" ]
  assert "no leftover children of the daemon" bash -c "! pgrep -P $pid >/dev/null 2>&1"
  # second leave: nothing to stop, still exit 0
  fleet_as "$h" leave >"$WORK/leave2.log" 2>&1; rc=$?
  assert "leave with no daemon exits 0" [ "$rc" -eq 0 ]
  # a stale pid file (process gone) is just removed
  echo 999999 >"$h/.config/fleet/daemon.pid"
  fleet_as "$h" leave >/dev/null 2>&1; rc=$?
  assert "stale daemon.pid: leave exits 0 and removes it" bash -c "[ '$rc' -eq 0 ] && [ ! -f '$h/.config/fleet/daemon.pid' ]"
  # N1: a reused PID (alive, but not `fleet daemon`) must never be signalled
  sleep 7777 & local spid=$!
  echo "$spid" >"$h/.config/fleet/daemon.pid"
  fleet_as "$h" leave >"$WORK/leave-reused.log" 2>&1; rc=$?
  assert "reused pid: leave exits 0" [ "$rc" -eq 0 ]
  assert "reused pid: the unrelated process is NOT killed" kill -0 "$spid"
  assert "reused pid: daemon.pid dropped as stale" [ ! -f "$h/.config/fleet/daemon.pid" ]
  assert "reused pid: leave says why" grep -q 'belongs to another process' "$WORK/leave-reused.log"
  refute "reused pid: no 'daemon stopped' claim" grep -q 'daemon stopped' "$WORK/leave-reused.log"
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  end
}

# N2: a job's grandchildren (tool `bash -ec` + `sleep`) are orphaned when the
# daemon kills the job; leave must still reap them.
case_leave_tree() {
  begin "leave: kills the daemon's grandchildren (tool subprocess of a running job)"
  local h pid i rc found=0
  h=$(mk_home kappa "slow")
  echo "fleet-kappa" >"$TS_STATE"
  HOME="$h" FLEET_SLOW_UPDATE=1 "$ROOT/fleet" daemon >"$WORK/daemon-tree.log" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    if pgrep -f '^sleep 12345$' >/dev/null 2>&1; then found=1; break; fi
    sleep 0.2; i=$((i + 1))
  done
  assert "update job running with a sleeping grandchild" [ "$found" -eq 1 ]
  assert "the sleep is a descendant of the daemon" bash -c ". '$ROOT/lib/common.sh'; proc_tree $pid | grep -qx \"\$(pgrep -f '^sleep 12345\$' | head -n 1)\""
  fleet_as "$h" leave >"$WORK/leave-tree.log" 2>&1; rc=$?
  assert "leave exits 0 (see $WORK/leave-tree.log)" [ "$rc" -eq 0 ] || sed 's/^/     | /' "$WORK/leave-tree.log"
  wait "$pid" 2>/dev/null
  refute "daemon gone" kill -0 "$pid"
  refute "grandchild sleep killed" pgrep -f '^sleep 12345$'
  assert "leave reported the daemon stop" grep -q "daemon stopped (pid $pid)" "$WORK/leave-tree.log"
  end
}

# join's sshd hardening, exercised with a fake `sshd -T` / `systemctl` on PATH and
# the config paths redirected into $WORK (FLEET_SSHD_CONFIG_DIR / FLEET_SSHD_CONFIG).
case_sshd() {
  begin "join: sshd drop-in 00-fleet.conf, verification via sshd -T -C (Match aware), reload must succeed"
  local d="$WORK/sshd" rc out
  mkdir -p "$d/bin" "$d/sshd_config.d"
  export FAKE_SSHD_T="$d/sshd-T.out" FAKE_SSHD_LOG="$d/sshd.log"
  # fake sshd: `-T` prints FAKE_SSHD_T; `-T -C <spec>` prints FAKE_SSHD_T_C when
  # set (the Match-applied view), else FAKE_SSHD_T. Logs its argv.
  cat >"$d/bin/sshd" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_SSHD_LOG"
case " $* " in *" -T "*) ;; *) echo "fake sshd: unsupported $*" >&2; exit 2 ;; esac
case " $* " in
  *" -C "*) cat "${FAKE_SSHD_T_C:-$FAKE_SSHD_T}" ;;
  *) cat "$FAKE_SSHD_T" ;;
esac
EOF
  cat >"$d/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_SYSTEMCTL_LOG:-/dev/null}"
case "$1" in reload|restart) [ -z "${FAKE_SYSTEMCTL_FAIL_RELOAD:-}" ] || exit 1 ;; esac
exit 0
EOF
  chmod +x "$d/bin/sshd" "$d/bin/systemctl"
  export FAKE_SYSTEMCTL_LOG="$d/systemctl.log"
  printf 'passwordauthentication no\nkbdinteractiveauthentication no\npermitrootlogin no\npubkeyauthentication yes\n' >"$d/good"
  printf 'passwordauthentication yes\nkbdinteractiveauthentication no\npermitrootlogin yes\npubkeyauthentication yes\n' >"$d/bad"
  # what `sshd -T -C user=<me>,...` shows when a `Match User` block re-enables passwords
  printf 'passwordauthentication yes\nkbdinteractiveauthentication no\npermitrootlogin no\npubkeyauthentication yes\n' >"$d/match"
  # no Include line -> has_include false; with it -> true
  printf '# test sshd_config\nPort 22\n' >"$d/sshd_config"
  j() {   # j FUNC... — run a join.sh function with the test paths (sourced, not executed: FLEET_ROOT set)
    PATH="$d/bin:$PATH" FLEET_SSHD_CONFIG_DIR="$d/sshd_config.d" FLEET_SSHD_CONFIG="$d/sshd_config" FLEET_ROOT="$ROOT" \
      bash -c '. "$FLEET_ROOT/lib/join.sh"; "$@"' bash "$@"
  }
  refute "has_include false without Include" j join_sshd_has_include
  printf 'Include %s/*.conf\n# test sshd_config\nPort 22\n' "$d/sshd_config.d" >"$d/sshd_config"
  assert "has_include true with Include" j join_sshd_has_include
  printf '# managed by fleet join\nPasswordAuthentication no\n' >"$d/sshd_config.d/fleet.conf"   # legacy drop-in
  printf 'PasswordAuthentication yes\n' >"$d/sshd_config.d/50-cloud-init.conf"               # foreign one stays
  j join_sshd_dropin 00-fleet.conf >"$WORK/dropin1.log" 2>&1; rc=$?
  assert "dropin written (rc 0)" [ "$rc" -eq 0 ]
  assert "00-fleet.conf: PasswordAuthentication no" grep -qx 'PasswordAuthentication no' "$d/sshd_config.d/00-fleet.conf"
  assert "00-fleet.conf: KbdInteractiveAuthentication no" grep -qx 'KbdInteractiveAuthentication no' "$d/sshd_config.d/00-fleet.conf"
  assert "00-fleet.conf: PermitRootLogin no" grep -qx 'PermitRootLogin no' "$d/sshd_config.d/00-fleet.conf"
  assert "00-fleet.conf is 0644" [ "$(file_mode "$d/sshd_config.d/00-fleet.conf")" = 644 ]
  assert "00- sorts before the foreign 50- drop-in" [ "$(find "$d/sshd_config.d" -name '*.conf' | LC_ALL=C sort | head -n 1)" = "$d/sshd_config.d/00-fleet.conf" ]
  assert "legacy fleet.conf removed" [ ! -e "$d/sshd_config.d/fleet.conf" ]
  assert "foreign drop-in untouched" [ -f "$d/sshd_config.d/50-cloud-init.conf" ]
  j join_sshd_dropin 00-fleet.conf >"$WORK/dropin2.log" 2>&1
  assert "second run idempotent (present)" grep -q 'present' "$WORK/dropin2.log"
  cp "$d/good" "$FAKE_SSHD_T"
  : >"$FAKE_SSHD_LOG"
  assert "verify passes on a key-only effective config" j join_sshd_verify
  assert "verify asks sshd -T -C user=<me>,host=localhost,addr=127.0.0.1" grep -qx -- "-T -C user=$(id -un),host=localhost,addr=127.0.0.1" "$FAKE_SSHD_LOG"
  cp "$d/bad" "$FAKE_SSHD_T"
  out=$(j join_sshd_verify 2>&1); rc=$?
  assert "verify fails when passwords / root login are on" [ "$rc" -ne 0 ]
  assert "verify names the offending options" bash -c "printf '%s' '$out' | grep -q 'PasswordAuthentication' && printf '%s' '$out' | grep -q 'PermitRootLogin'"
  # N4: global config key-only, but a Match block for this user re-enables passwords
  cp "$d/good" "$FAKE_SSHD_T"; export FAKE_SSHD_T_C="$d/match"
  out=$(j join_sshd_verify 2>&1); rc=$?
  assert "verify fails when a Match block re-enables passwords (-C view)" [ "$rc" -ne 0 ]
  assert "verify names PasswordAuthentication from the Match view" bash -c "printf '%s' '$out' | grep -q 'PasswordAuthentication'"
  out=$(j join_ssh_enable_linux 2>&1); rc=$?
  assert "join_ssh_enable_linux fails on a Match block enabling passwords" [ "$rc" -ne 0 ]
  assert "Match failure mentions Match blocks in the next step" bash -c "printf '%s' '$out' | grep -q 'next:.*Match'"
  unset FAKE_SSHD_T_C
  # N4: a failed reload (and restart) fails the join
  : >"$FAKE_SYSTEMCTL_LOG"
  out=$(FAKE_SYSTEMCTL_FAIL_RELOAD=1 j join_ssh_enable_linux 2>&1); rc=$?
  assert "join_ssh_enable_linux fails when sshd does not reload" [ "$rc" -ne 0 ]
  assert "reload failure says so, with sshd -t as the next step" bash -c "printf '%s' '$out' | grep -q 'did not reload' && printf '%s' '$out' | grep -q 'next:.*-t'"
  assert "restart was attempted after reload failed" bash -c "grep -q '^reload ssh' '$FAKE_SYSTEMCTL_LOG' && grep -q '^restart ssh' '$FAKE_SYSTEMCTL_LOG'"
  : >"$FAKE_SYSTEMCTL_LOG"
  # whole step: good -> ok; bad -> join dies with a next step (never prints joined)
  cp "$d/good" "$FAKE_SSHD_T"
  out=$(j join_ssh_enable_linux 2>&1); rc=$?
  assert "join_ssh_enable_linux ok with key-only sshd" bash -c "[ '$rc' -eq 0 ] && printf '%s' '$out' | grep -q 'sshd verified'"
  assert "sshd service enabled + reloaded" bash -c "grep -q '^enable --now ssh' '$FAKE_SYSTEMCTL_LOG' && grep -q '^reload ssh' '$FAKE_SYSTEMCTL_LOG'"
  cp "$d/bad" "$FAKE_SSHD_T"
  out=$(j join_ssh_enable_linux 2>&1); rc=$?
  assert "join_ssh_enable_linux fails when sshd still allows passwords" [ "$rc" -ne 0 ]
  assert "failure message says what to do next" bash -c "printf '%s' '$out' | grep -q 'next:.*PasswordAuthentication no'"
  # no Include -> fail with manual steps
  printf 'Port 22\n' >"$d/sshd_config"; cp "$d/good" "$FAKE_SSHD_T"
  out=$(j join_ssh_enable_linux 2>&1); rc=$?
  assert "no Include in sshd_config -> non-zero with manual hint" bash -c "[ '$rc' -ne 0 ] && printf '%s' '$out' | grep -q 'Include'"
  unset -f j
  end
}

# The browser MCP launch wrappers written by lib/tools/chrome.sh, with fake MCP
# binaries and a fake chromium on PATH (nothing is installed).
case_chrome_wrapper() {
  begin "chrome: wrappers pick headless without DISPLAY, fleet profile, browser path, --no-sandbox in containers"
  local h="$WORK/homes/chrome" d="$WORK/chrome-bin" out rc
  mkdir -p "$h" "$d"
  for b in chrome-devtools-mcp playwright-mcp; do printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' >"$d/$b"; chmod +x "$d/$b"; done
  printf '#!/usr/bin/env bash\necho "Chromium 142.0.7444.59"\n' >"$d/chromium"; chmod +x "$d/chromium"
  c() {   # c FUNC... — run a chrome.sh function in the plug-in's environment
    HOME="$h" FLEET_BIN="$h/.local/bin" FLEET_HOME="$h/.config/fleet" FLEET_ROOT="$ROOT" PATH="$d:$PATH" \
      bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/tools/chrome.sh"; "$@"' bash "$@"
  }
  c _chrome_write_wrappers >"$WORK/chrome-wrap.log" 2>&1; rc=$?
  assert "wrappers written (rc 0)" [ "$rc" -eq 0 ]
  assert "fleet-chrome-mcp is 0755" [ "$(file_mode "$h/.local/bin/fleet-chrome-mcp")" = 755 ]
  assert "fleet-playwright-mcp is 0755" [ "$(file_mode "$h/.local/bin/fleet-playwright-mcp")" = 755 ]
  assert "bash -n fleet-chrome-mcp" bash -n "$h/.local/bin/fleet-chrome-mcp"
  c _chrome_write_wrappers >"$WORK/chrome-wrap2.log" 2>&1
  assert "rewrite is a no-op when unchanged" bash -c "! grep -q wrote '$WORK/chrome-wrap2.log'"
  # Linux, no display -> headless; FLEET_CONTAINER=1 (test env) -> no-sandbox; fake chromium found
  out=$(env -u DISPLAY -u WAYLAND_DISPLAY HOME="$h" PATH="$d:$PATH" "$h/.local/bin/fleet-chrome-mcp" --extra 2>&1)
  assert "devtools: --headless without DISPLAY" bash -c "printf '%s\n' '$out' | grep -qx -- '--headless'"
  assert "devtools: fleet profile dir, not the owner's" bash -c "printf '%s\n' '$out' | grep -qx -- '--user-data-dir=$h/.cache/fleet/chrome-profile/devtools'"
  assert "devtools: profile dir created" [ -d "$h/.cache/fleet/chrome-profile/devtools" ]
  assert "devtools: executable path = chromium" bash -c "printf '%s\n' '$out' | grep -qx -- '--executable-path=$d/chromium'"
  assert "devtools: --no-sandbox chrome args in a container" bash -c "printf '%s\n' '$out' | grep -qx -- '--chrome-arg=--no-sandbox'"
  assert "devtools: extra args passed through (last)" [ "$(printf '%s\n' "$out" | tail -n 1)" = "--extra" ]
  out=$(env -u WAYLAND_DISPLAY DISPLAY=:0 HOME="$h" PATH="$d:$PATH" "$h/.local/bin/fleet-chrome-mcp" 2>&1)
  assert "devtools: headed with DISPLAY" bash -c "! printf '%s\n' '$out' | grep -qx -- '--headless'"
  out=$(DISPLAY=:0 FLEET_HEADLESS=1 HOME="$h" PATH="$d:$PATH" "$h/.local/bin/fleet-chrome-mcp" 2>&1)
  assert "devtools: FLEET_HEADLESS=1 forces headless" bash -c "printf '%s\n' '$out' | grep -qx -- '--headless'"
  out=$(env -u DISPLAY -u WAYLAND_DISPLAY FLEET_HEADLESS=0 HOME="$h" PATH="$d:$PATH" "$h/.local/bin/fleet-chrome-mcp" 2>&1)
  assert "devtools: FLEET_HEADLESS=0 forces headed" bash -c "! printf '%s\n' '$out' | grep -qx -- '--headless'"
  out=$(env -u DISPLAY -u WAYLAND_DISPLAY HOME="$h" PATH="$d:$PATH" "$h/.local/bin/fleet-playwright-mcp" 2>&1)
  assert "playwright: --headless without DISPLAY" bash -c "printf '%s\n' '$out' | grep -qx -- '--headless'"
  assert "playwright: --user-data-dir <fleet profile>" bash -c "printf '%s\n' '$out' | grep -A1 -x -- '--user-data-dir' | grep -qx '$h/.cache/fleet/chrome-profile/playwright'"
  assert "playwright: --executable-path chromium" bash -c "printf '%s\n' '$out' | grep -A1 -x -- '--executable-path' | grep -qx '$d/chromium'"
  assert "playwright: --no-sandbox in a container" bash -c "printf '%s\n' '$out' | grep -qx -- '--no-sandbox'"
  assert "playwright: separate profile from devtools" [ "$h/.cache/fleet/chrome-profile/playwright" != "$h/.cache/fleet/chrome-profile/devtools" ]
  # binary missing -> clear error, exit 127
  out=$(HOME="$h" PATH="/usr/bin:/bin" "$h/.local/bin/fleet-chrome-mcp" 2>&1); rc=$?
  assert "missing MCP binary -> exit 127 with hint" bash -c "[ '$rc' -eq 127 ] && printf '%s' '$out' | grep -q 'fleet apply'"
  # status: no npm here -> missing MCP packages, chromium version reported, wrappers present
  out=$(c tool_chrome_status 2>/dev/null)
  assert "status line starts with missing (no npm)" bash -c "printf '%s' '$out' | grep -q '^missing .*chrome-devtools-mcp'"
  assert "status reports the browser version" bash -c "printf '%s' '$out' | grep -q 'chrome=142.0.7444.59'"
  assert "status does not list wrappers as missing" bash -c "! printf '%s' '$out' | grep -q ' wrappers'"
  # N6: no browser on PATH -> `missing`, naming the browser (never `ok`)
  out=$(HOME="$h" FLEET_BIN="$h/.local/bin" FLEET_HOME="$h/.config/fleet" FLEET_ROOT="$ROOT" PATH="/usr/bin:/bin" \
      bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/tools/chrome.sh"; tool_chrome_status' 2>/dev/null)
  assert "status without a browser: missing chromium" bash -c "printf '%s' '$out' | grep -q '^missing .*chromium'"
  unset -f c
  end
}

# N6: the real base plug-in must say `missing` while packages are absent.
case_base_status() {
  begin "base: status is missing while packages are absent, ok once the commands exist"
  local out d="$WORK/base-bin" c
  out=$(FLEET_ROOT="$SRC" bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/tools/base.sh"; tool_base_status' 2>/dev/null)
  assert "status starts with missing (jq etc. not installed here)" bash -c "printf '%s' '$out' | grep -q '^missing .*jq'"
  assert "status names ripgrep and tmux" bash -c "printf '%s' '$out' | grep -q 'ripgrep' && printf '%s' '$out' | grep -q 'tmux'"
  refute "status is not ok" bash -c "printf '%s' '$out' | grep -q '^ok'"
  # non-root, non-interactive install: warns and returns 0 without touching apt
  FLEET_ROOT="$SRC" FLEET_HOME="$WORK/base-home" bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/tools/base.sh"; _base_may_root() { return 1; }; tool_base_install' >"$WORK/base-install.log" 2>&1; rc=$?
  assert "unprivileged install returns 0 and points at fleet join" bash -c "[ '$rc' -eq 0 ] && grep -q \"warn.*fleet join\" '$WORK/base-install.log'"
  refute "unprivileged install never claims the packages are present" grep -q 'base packages present' "$WORK/base-install.log"
  # all commands present (stubs) -> none of them reported
  mkdir -p "$d"
  assert "status names netcat (fleet doctor probes with nc)" bash -c "printf '%s' '$out' | grep -q 'netcat'"
  for c in git git-lfs curl jq rg tmux python3 unzip nc; do printf '#!/bin/sh\nexit 0\n' >"$d/$c"; chmod +x "$d/$c"; done
  out=$(FLEET_ROOT="$SRC" PATH="$d:$PATH" bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/tools/base.sh"; tool_base_status' 2>/dev/null)
  refute "with every command present nothing but ca-certificates can be missing" bash -c "printf '%s' '$out' | grep -Eq 'jq|ripgrep|tmux|git-lfs|unzip|netcat'"
  end
}

# N7: harness_capture keeps fleet-managed Codex MCP servers from the template
# including their nested subtables ([mcp_servers.X.env]).
case_harness_toml() {
  begin "harness capture: keeps [mcp_servers.chrome-devtools] AND its [.env] subtable"
  local fh="$WORK/homes/capture" repo="$WORK/capture-repo" out rc tpl
  rm -rf "$fh" "$repo"
  mkdir -p "$fh/.claude" "$fh/.codex" "$fh/.cursor" "$fh/.grok" "$fh/.t3/userdata" "$repo/harness/codex" "$repo/skills"
  cp "$SRC/lib/common.sh" "$SRC/lib/harness.sh" "$repo/"
  echo '{}' >"$fh/.claude/settings.json"; echo '{"mcpServers":{}}' >"$fh/.claude.json"
  printf 'model = "gpt"\n\n[mcp_servers.foo]\nurl = "https://example.invalid/mcp"\n' >"$fh/.codex/config.toml"
  echo '{"mcpServers":{}}' >"$fh/.cursor/mcp.json"; echo '{}' >"$fh/.cursor/cli-config.json"
  printf '[cli]\nx = 1\n' >"$fh/.grok/config.toml"
  for f in settings.json client-settings.json keybindings.json; do echo '{}' >"$fh/.t3/userdata/$f"; done
  tpl="$repo/harness/codex/config.toml"
  cat >"$tpl" <<'EOF'
model = "old"

[mcp_servers.chrome-devtools]
command = "${HOME}/.local/bin/fleet-chrome-mcp"
args = []

[mcp_servers.chrome-devtools.env]
FLEET_HEADLESS = "1"

[mcp_servers.playwright]
command = "${HOME}/.local/bin/fleet-playwright-mcp"
args = []
EOF
  out=$(HOME="$fh" FLEET_ROOT="$repo" FLEET_CONFIG_DIR="$repo" FLEET_HOME="$fh/.config/fleet" bash -c '. "$FLEET_ROOT/common.sh"; . "$FLEET_ROOT/harness.sh"; harness_capture' 2>&1); rc=$?
  assert "harness_capture exits 0" [ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/     | /'
  assert "capture writes into the config dir, not next to the code" bash -c "[ -f '$repo/harness/claude/settings.json' ] && [ ! -e '$repo/config' ]"
  assert "captured server from the master kept" grep -qx '\[mcp_servers.foo\]' "$tpl"
  assert "fleet server block kept" grep -qx '\[mcp_servers.chrome-devtools\]' "$tpl"
  assert "nested env subtable kept" grep -qx '\[mcp_servers.chrome-devtools.env\]' "$tpl"
  assert "env value kept" grep -qx 'FLEET_HEADLESS = "1"' "$tpl"
  assert "second fleet server kept" grep -qx '\[mcp_servers.playwright\]' "$tpl"
  assert "fleet wrapper paths kept" [ "$(grep -c '/.local/bin/fleet-' "$tpl")" = 2 ]
  assert "root block comes from the master" bash -c "grep -qx 'model = \"gpt\"' '$tpl' && ! grep -q 'model = \"old\"' '$tpl'"
  assert "subtable follows its server block" bash -c "awk '/^\[mcp_servers.chrome-devtools\]/{a=NR} /^\[mcp_servers.chrome-devtools.env\]/{b=NR} END{exit !(a && b && b>a)}' '$tpl'"
  # second capture: idempotent (the kept blocks are not duplicated)
  HOME="$fh" FLEET_ROOT="$repo" FLEET_CONFIG_DIR="$repo" FLEET_HOME="$fh/.config/fleet" bash -c '. "$FLEET_ROOT/common.sh"; . "$FLEET_ROOT/harness.sh"; harness_capture' >/dev/null 2>&1
  assert "second capture: env subtable still exactly once" [ "$(grep -c '^\[mcp_servers.chrome-devtools.env\]' "$tpl")" = 1 ]
  end
}

# N8: the entrypoint truncates a writable mounted invite after copying it, and
# the user-readable copy is gone once join finished.
case_entrypoint_invite() {
  begin "entrypoint: mounted invite truncated after the copy, tmpfs copy removed, join saw the code"
  local ep="/tmp/fleet-ep.$$" u=fleettest uh out rc
  rm -rf "$ep"; mkdir -p "$ep"; chmod 755 "$ep"
  if ! command -v setpriv >/dev/null 2>&1 || ! command -v useradd >/dev/null 2>&1 || [ "$(id -u)" -ne 0 ]; then
    echo "   - skipped: needs root, setpriv and useradd"; end; return 0
  fi
  id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u" >/dev/null 2>&1
  uh=$(getent passwd "$u" | cut -d: -f6)
  # fake /opt/fleet: `fleet join` records what it read from FLEET_INVITE_FILE
  # shellcheck disable=SC2016  # the script body expands at its own run time
  printf '#!/usr/bin/env bash\nset -eu\n[ "$1" = join ]\ncat "$FLEET_INVITE_FILE" >"$HOME/seen-invite"\n' >"$ep/fleet"; chmod 755 "$ep/fleet"
  (umask 077; printf 'the-invite-code\n' >"$ep/invite")   # root:root 0600, like the bind mount
  rm -f "$uh/seen-invite"
  out=$(FLEET_USER="$u" FLEET_ROOT="$ep" FLEET_INVITE_FILE="$ep/invite" bash -c '. "$SRC_EP"; run_join' 2>&1); rc=$?
  assert "run_join exits 0" [ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/     | /'
  assert "join (as $u) read the code from the private copy" [ "$(cat "$uh/seen-invite" 2>/dev/null)" = "the-invite-code" ]
  assert "mounted invite file truncated" bash -c "[ -f '$ep/invite' ] && [ ! -s '$ep/invite' ]"
  assert "entrypoint logged the truncation" bash -c "printf '%s' '$out' | grep -q 'truncated'"
  refute "no private copy left in /run/fleet" bash -c "ls /run/fleet/invite.* 2>/dev/null | grep -q ."
  # an already emptied mount (host removed it before join) is refused
  out=$(FLEET_USER="$u" FLEET_ROOT="$ep" FLEET_INVITE_FILE="$ep/invite" bash -c '. "$SRC_EP"; run_join' 2>&1); rc=$?
  assert "empty invite file -> join refused" bash -c "[ '$rc' -ne 0 ] && printf '%s' '$out' | grep -q 'is empty'"
  rm -rf "$ep"
  end
}

case_daemon() {
  begin "daemon: handles TERM within 3s and runs leave"
  local h pid i alive=1
  h=$(mk_home eta "")
  echo "fleet-eta" >"$TS_STATE"
  : >"$TS_LOG"
  HOME="$h" "$ROOT/fleet" daemon >"$WORK/daemon.log" 2>&1 &
  pid=$!
  sleep 2
  assert "daemon running" kill -0 "$pid"
  assert "daemon.pid written" [ "$(cat "$h/.config/fleet/daemon.pid" 2>/dev/null)" = "$pid" ]
  assert "first cycle ran the jobs" grep -q '^pull=' "$h/.config/fleet/daemon.state"
  kill -TERM "$pid"
  i=0
  while [ "$i" -lt 30 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then alive=0; break; fi
    sleep 0.1; i=$((i + 1))
  done
  wait "$pid" 2>/dev/null
  assert "exited within 3s of TERM" [ "$alive" -eq 0 ]
  assert "leave ran: tailscale logout" grep -q '^logout' "$TS_LOG"
  assert "daemon.pid removed" [ ! -f "$h/.config/fleet/daemon.pid" ]
  assert "no leftover sleep children" bash -c "! pgrep -P $pid >/dev/null 2>&1"
  end
}

# The container daemon starts from the image copy (/opt/fleet here: $ROOT) but
# must dispatch jobs through ~/.local/bin/fleet (the checkout `fleet pull`
# updates) and replace itself with that code once a pull moved the checkout.
case_daemon_reexec() {
  begin "daemon: dispatches jobs through ~/.local/bin/fleet and re-execs itself after a code update"
  local h share pid i rc c_old c_new cmdline=""
  h=$(mk_home lambda "")
  share="$h/.local/share/fleet"
  git clone -q "$WORK/code.git" "$share"
  git clone -q "$WORK/config.git" "$h/.local/share/fleet-config"
  fleet_as "$h" apply >"$WORK/apply-lambda.log" 2>&1; rc=$?
  assert "baseline apply exits 0" [ "$rc" -eq 0 ]
  c_old=$(git -C "$share" rev-parse HEAD)
  # a logging wrapper in place of the symlink: records which binary the daemon called
  rm -f "$h/.local/bin/fleet"
  printf '#!/usr/bin/env bash\necho "$*" >>"%s"\nexec "%s/fleet" "$@"\n' "$WORK/dispatch-lambda.log" "$share" >"$h/.local/bin/fleet"
  chmod 755 "$h/.local/bin/fleet"
  : >"$WORK/dispatch-lambda.log"
  commit_code "code for reexec"
  c_new=$(code_head)
  echo "fleet-lambda" >"$TS_STATE"
  HOME="$h" "$ROOT/fleet" daemon >"$WORK/daemon-reexec.log" 2>&1 &
  pid=$!
  # the pull job's apply puts the ~/.local/bin/fleet symlink back (so the wrapper
  # only sees the first job); the re-exec then goes through that symlink
  i=0
  while [ "$i" -lt 150 ] && ! grep -q 're-executing' "$WORK/daemon-reexec.log"; do sleep 0.2; i=$((i + 1)); done
  sleep 1
  cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
  assert "first job went through ~/.local/bin/fleet, not the image copy" grep -qx 'pull' "$WORK/dispatch-lambda.log"
  assert "pull moved the checkout" [ "$(git -C "$share" rev-parse HEAD)" = "$c_new" ]
  assert "re-exec announced with old and new rev, target ~/.local/bin/fleet" grep -q "code updated ($c_old -> $c_new); re-executing $h/.local/bin/fleet daemon" "$WORK/daemon-reexec.log"
  assert "apply restored the ~/.local/bin/fleet symlink to the checkout" [ "$(readlink "$h/.local/bin/fleet")" = "$share/fleet" ]
  assert "same pid now runs ~/.local/bin/fleet daemon, not the image copy" bash -c "printf '%s' '$cmdline' | grep -q '$h/.local/bin/fleet daemon' && ! printf '%s' '$cmdline' | grep -q '$ROOT/fleet'"
  assert "daemon.pid still names the (same) daemon" [ "$(cat "$h/.config/fleet/daemon.pid" 2>/dev/null)" = "$pid" ]
  assert "no stale copy of the daemon: exactly one fleet daemon for this home" [ "$(pgrep -f "$h/.local/bin/fleet daemon" | wc -l | tr -d ' ')" = 1 ]
  kill -TERM "$pid" 2>/dev/null
  i=0; while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
  wait "$pid" 2>/dev/null
  refute "daemon stopped on TERM after the re-exec" kill -0 "$pid"
  end
}

# FLEET_NO_SCHEDULER=1 is honoured on nodes too: units/plists/crontab lines are
# written but nothing is loaded. Fake systemctl/crontab on PATH record calls.
case_schedules_noload() {
  begin "schedules: FLEET_NO_SCHEDULER writes units and crontab lines without enabling them"
  local h d="$WORK/sched-bin" out
  h=$(mk_home mu "")
  mkdir -p "$d"
  # shellcheck disable=SC2016  # the fakes expand $* / $1 at their own run time
  printf '#!/usr/bin/env bash\necho "$*" >>"%s"\nexit 0\n' "$WORK/sched-systemctl.log" >"$d/systemctl"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\necho "$*" >>"%s"\n[ "$1" = -l ] && exit 1\ncat >/dev/null\nexit 0\n' "$WORK/sched-crontab.log" >"$d/crontab"
  chmod 755 "$d/systemctl" "$d/crontab"
  : >"$WORK/sched-systemctl.log"; : >"$WORK/sched-crontab.log"
  s() {   # s FUNC — run a node.sh schedule function with the fakes on PATH
    HOME="$h" FLEET_HOME="$h/.config/fleet" FLEET_ROOT="$ROOT" FLEET_BIN="$h/.local/bin" PATH="$d:$PATH" FLEET_NO_SCHEDULER=1 \
      bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/node.sh"; "$@"' bash "$@"
  }
  out=$(s node_schedule_install_systemd 2>&1)
  assert "systemd: units written" bash -c "[ -f '$h/.config/systemd/user/fleet-pull.timer' ] && [ -f '$h/.config/systemd/user/fleet-memory.service' ]"
  refute "systemd: nothing enabled or reloaded" grep -Eq 'enable|daemon-reload' "$WORK/sched-systemctl.log"
  assert "systemd: says so" bash -c "printf '%s' '$out' | grep -q 'not enabled (FLEET_NO_SCHEDULER)'"
  out=$(s node_schedule_install_cron 2>&1)
  assert "cron: lines written to crontab.fleet, crontab not called" bash -c "grep -q '# fleet:pull' '$h/.config/fleet/crontab.fleet' && [ ! -s '$WORK/sched-crontab.log' ] && printf '%s' '$out' | grep -q 'not installed (FLEET_NO_SCHEDULER)'"
  : >"$WORK/sched-systemctl.log"
  out=$(HOME="$h" FLEET_HOME="$h/.config/fleet" FLEET_ROOT="$ROOT" FLEET_BIN="$h/.local/bin" PATH="$d:$PATH" \
      bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/node.sh"; node_schedule_install_systemd' 2>&1)
  assert "without FLEET_NO_SCHEDULER the timers are enabled" grep -q 'enable --now fleet-pull.timer' "$WORK/sched-systemctl.log"
  unset -f s
  end
}

case_build_index() {
  begin "templates/memory: build_index.py lists notes grouped by node"
  local v="$WORK/vault" out
  rm -rf "$v"; cp -R "$SRC/templates/memory/." "$v/"
  out=$(python3 "$v/scripts/build_index.py")
  assert "fresh template index unchanged" [ "$out" = "INDEX.md unchanged" ]
  mkdir -p "$v/nodes/alpha"
  printf -- '---\nnode: alpha\ncreated: 2026-10-03\ntags: [backend, db]\n---\n# SurrealDB quirk\n\nbody\n' >"$v/nodes/alpha/surreal.md"
  printf '# Curated\n' >"$v/notes/curated.md"
  out=$(python3 "$v/scripts/build_index.py")
  assert "index updated" [ "$out" = "INDEX.md updated" ]
  assert "notes line" grep -q '^- \[Curated\](notes/curated.md)$' "$v/INDEX.md"
  assert "node section" grep -q '^## nodes/alpha$' "$v/INDEX.md"
  assert "node line with meta" grep -q '^- \[SurrealDB quirk\](nodes/alpha/surreal.md) — node alpha · created 2026-10-03 · tags: backend, db$' "$v/INDEX.md"
  assert "--check passes when current" python3 "$v/scripts/build_index.py" --check
  end
}

case_syntax() {
  begin "syntax: bash -n on node files"
  assert "lib/join.sh" bash -n "$SRC/lib/join.sh"
  assert "lib/node.sh" bash -n "$SRC/lib/node.sh"
  assert "lib/tools/*.sh" bash -c "for f in '$SRC'/lib/tools/*.sh; do bash -n \"\$f\" || exit 1; done"
  assert "docker/*.sh" bash -c "for f in '$SRC'/docker/*.sh; do bash -n \"\$f\" || exit 1; done"
  assert "tests/node_test.sh" bash -n "$SRC/tests/node_test.sh"
  assert "fleet --version" bash -c "'$ROOT/fleet' --version | grep -q '^fleet '"
  assert "entrypoint.sh can be sourced (functions only)" bash -c ". '$SRC/docker/entrypoint.sh'; declare -F run_join >/dev/null"
  end
}

# ---------- run ----------

setup_deps
setup_root
setup_memory_remote
setup_code_config_remotes
export SRC_EP="$SRC/docker/entrypoint.sh"
echo "==> work dir: $WORK"
case_syntax
case_help
case_join
case_t3_authkey
case_apply
case_apply_proxy
case_memory_off
case_memory_sync
case_memory_concurrent
case_memory_conflict
case_pull
case_pull_retry
case_pull_concurrent
case_daemon
case_daemon_reexec
case_schedules_noload
case_leave
case_leave_tree
case_sshd
case_chrome_wrapper
case_base_status
case_harness_toml
case_entrypoint_invite
case_build_index
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
