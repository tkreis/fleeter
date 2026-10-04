#!/usr/bin/env bash
# Offline tests for lib/master.sh. No real Tailscale, GitHub, ssh or ~/.config/fleet.
export FLEET_MEMORY_SEED=0   # memory_seed clones the real memory repo; never in tests
#
#   bash tests/master_test.sh            prints PASS/FAIL per check, exits 1 on any FAIL
#
# Fakes: tests/e2e/fake_api.py for the Tailscale + GitHub APIs (FLEET_TS_API,
# FLEET_GH_API), a `tailscale status --json` file (FLEET_TS_STATUS_JSON), an
# `ssh` script on PATH that runs the command locally against a fake node HOME,
# and a `gh` script for the GitHub CLI path.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")
chmod 0700 "$T"
T=$(cd "$T" && pwd -P)      # physical path: config_dir_setup records resolved paths
API_PID=""; PROV_PID=""
cleanup() {
  [ -n "$API_PID" ] && { kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null; }
  [ -n "$PROV_PID" ] && kill "$PROV_PID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
# assert DESC CMD... — PASS when CMD succeeds.
assert() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
refute() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }
mode_of() { if stat -f %Lp "$1" >/dev/null 2>&1; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
export -f sha256
jget() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v=v[k]
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2"; }
# wait_for SECONDS CMD... — poll until CMD succeeds.
wait_for() { local n=$1 i=0; shift; while [ "$i" -lt "$((n * 5))" ]; do "$@" >/dev/null 2>&1 && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }
export -f mode_of jget          # compound assertions run through `bash -c`

# ---------- placeholder join.sh (only if the real one is not there yet) ----------
if [ ! -f "$ROOT/lib/join.sh" ]; then
  printf '#!/usr/bin/env bash\n# placeholder: real lib/join.sh is written separately (comments only, safe to source)\n' >"$ROOT/lib/join.sh"
fi

# ---------- environment: everything under $T ----------
export T
export HOME="$T/master-home"
# git: an identity of our own (init master and config publish require one) and
# no dependence on the host's ~/.gitconfig; every `git init` below also pins the
# default branch, so a clean Debian without init.defaultBranch behaves like macOS.
export GIT_CONFIG_GLOBAL="$T/gitconfig"
printf '[user]\n\tname = fleet tester\n\temail = tester@example.invalid\n' >"$GIT_CONFIG_GLOBAL"
export FLEET_HOME="$HOME/.config/fleet"
export FLEET_VAULT="$FLEET_HOME/vault"
export FLEET_VAULT_KEY_BACKEND=file   # never the real keychain / secret service; fakes on PATH test those paths below
export FLEET_NO_SCHEDULER=1
export FLEET_NO_OPEN=1
export FLEET_NODE_USER=fleetuser
export FLEET_MASTER_TS_IP=100.64.0.1
export FLEET_TS_STATUS_JSON="$T/status.json"
export NODES="$T/nodes"            # fake node homes: $NODES/<dnsname>
export SSH_LOG="$T/ssh.log"
export API_LOG="$T/api.log"
export GH_LOG="$T/gh.log"
export GH_STATE="$T/ghstate"
export DEVICES_JSON="$T/devices.json"
ACL="$T/acl.hujson"
mkdir -p "$HOME" "$NODES" "$T/bin" "$T/ghbin" "$GH_STATE"
FLEET="$ROOT/fleet"            # invoked via bash: the checkout may not be chmod +x yet

# fake ssh: ssh -i key -o ... user@host CMD...  → run CMD with HOME=<fake node>
#   $T/slow-secrets  → sleep before the secrets step (kick race): the file's content is the
#                      number of seconds, default 30
#   $T/slow-files    → same before unpacking the mirrored files (plaintext snapshot)
#   $T/slow-enrol    → sleep 2 before serving enrol.json (double-claim race)
#   $T/nc-open       → `nc -z` probes "succeed" (isolation negative test)
#   $T/nc-missing    → `nc` is not installed on the node (exit 127)
#   $T/leave-fail    → `fleet leave` on the node fails (kick stop retry)
cat >"$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -i|-o|-p) shift 2 ;; -*) shift ;; *) break ;; esac
done
target=$1; shift
host=${target#*@}
cmd="$*"
printf '%s %s\n' "$target" "$cmd" >>"$SSH_LOG"
nh="$NODES/$host"
# `fleet-<name>` is the alias fleet writes into ~/.ssh/config.d/fleet (t3); the fake node home is named by dnsname
[ -d "$nh" ] || nh=$(ls -d "$NODES/$host".* 2>/dev/null | head -1)
[ -n "$nh" ] && [ -d "$nh" ] || exit 255      # unreachable host
host=$(basename "$nh")
[ "${SSH_FAIL:-}" = "$host" ] && exit 255
case "$cmd" in *secrets.env.tmp*) [ -f "$T/slow-secrets" ] && { s=$(cat "$T/slow-secrets"); sleep "${s:-30}"; } ;; esac
case "$cmd" in *stage.XXXXXX*) [ -f "$T/slow-files" ] && { s=$(cat "$T/slow-files"); sleep "${s:-3}"; } ;; esac
case "$cmd" in *enrol.json*) [ -f "$T/slow-enrol" ] && sleep 2 ;; esac
case "$cmd" in
  "cat /etc/ssh/ssh_host_ed25519_key.pub") cat "$nh/.hostkey.pub"; exit $? ;;   # the node's host key (pinning)
  "nc -z "*)                      [ -f "$T/nc-missing" ] && exit 127; [ -f "$T/nc-open" ] && exit 0; exit 1 ;;
  *"fleet pull --no-apply"*)      touch "$nh/.fleet-pulled"; exit 0 ;;
  *"fleet apply --from-master "*) mkdir -p "$nh/.config/fleet"; printf '%s' "${cmd##* }" >"$nh/.config/fleet/applied"; printf 'c0ffee+cafe\n' >"$nh/.config/fleet/applied_commit"; exit 0 ;;
  *"fleet leave"*)                [ -f "$T/leave-fail" ] && exit 1; touch "$nh/.fleet-left"; exit 0 ;;
  *"fleet update"*)               touch "$nh/.fleet-updated"; exit 0 ;;
  *"fleet status --json"*)        if [ -f "$T/status-reply.json" ]; then cat "$T/status-reply.json"; else echo '{"fleet":"0.1.0","tools":{"claude":{"state":"ok","detail":"x"},"codex":{"state":"login","detail":"y"}}}'; fi; exit 0 ;;
esac
HOME="$nh" exec bash -c "$cmd"
EOF
chmod +x "$T/bin/ssh"
export PATH="$T/bin:$PATH"

# fake gh (GitHub CLI): logs argv, keyring state in $GH_STATE
cat >"$T/ghbin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "auth status") [ -f "$GH_STATE/logged-in" ] ;;
  "auth login")  touch "$GH_STATE/logged-in" ;;
  "repo view")   [ ! -f "$GH_STATE/missing-$(printf '%s' "$3" | tr / _)" ] ;;
  "repo create") rm -f "$GH_STATE/missing-$(printf '%s' "$3" | tr / _)" ;;
  "api user")    echo example ;;
  "api -X")
    case "$3" in
      POST)   cat >/dev/null; n=$(cat "$GH_STATE/counter" 2>/dev/null || echo 100); n=$((n + 1)); echo "$n" >"$GH_STATE/counter"; echo "$n" ;;
      DELETE) if [ -f "$GH_STATE/fail-delete" ]; then echo "gh: HTTP 500 boom" >&2; exit 1; fi ;;
      *) exit 2 ;;
    esac ;;
  *) echo "fake gh: unsupported: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$T/ghbin/gh"

# fake Tailscale + GitHub API (shared with tests/e2e.sh); port 0 → printed on stdout
python3 "$ROOT/tests/e2e/fake_api.py" 0 "$API_LOG" "$DEVICES_JSON" "$ACL" >"$T/api.port" &
API_PID=$!
# up to 30s: a cold python start on a CI runner can take several seconds
i=0; while [ ! -s "$T/api.port" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$T/api.port" ] || { echo "fake api did not start"; exit 1; }
API_PORT=$(cat "$T/api.port")
export FLEET_TS_API="http://127.0.0.1:$API_PORT"
export FLEET_GH_API="$FLEET_TS_API"
echo '[{"nodeId":"nAAAACNTRL","hostname":"fleet-alpha"},{"nodeId":"nEEEECNTRL","hostname":"fleet-eph"}]' >"$DEVICES_JSON"
ALLOW_ALL='// default
{"grants": [{"src": ["*"], "dst": ["*"], "ip": ["*"]}]}'

# fake tailnet: alpha + beta online + tagged, gamma untagged
write_status() {   # write_status EXTRA_PEERS [FILE]
  cat >"${2:-$FLEET_TS_STATUS_JSON}" <<EOF
{"BackendState":"Running","Self":{"ID":"nSELF","HostName":"mac","TailscaleIPs":["100.64.0.1"]},"Peer":{
 "k1":{"ID":"nAAAACNTRL","HostName":"fleet-alpha","DNSName":"fleet-alpha.tail1.ts.net.","TailscaleIPs":["100.64.0.11"],"Online":true,"Tags":["tag:fleet-node"]},
 "k2":{"ID":"nBBBBCNTRL","HostName":"fleet-beta","DNSName":"fleet-beta.tail1.ts.net.","TailscaleIPs":["100.64.0.12"],"Online":true,"Tags":["tag:fleet-node"]},
 "k3":{"ID":"nCCCCCNTRL","HostName":"laptop","DNSName":"laptop.tail1.ts.net.","Online":true}
 $1
}}
EOF
}
write_status ""

# fake node homes
mk_node() {  # mk_node DNSNAME NONCE
  local nh="$NODES/$1"
  mkdir -p "$nh/.config/fleet" "$nh/.ssh"
  printf '{"nonce":"%s","name":"%s","user":"fleetuser","os":"linux","arch":"amd64","container":true,"joined":"2026-10-03T09:00:00Z"}' "$2" "${1%%.*}" >"$nh/.config/fleet/enrol.json"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEcode$1 fleet_code" >"$nh/.ssh/fleet_code.pub"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEconfig$1 fleet_config" >"$nh/.ssh/fleet_config.pub"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEmemory$1 fleet_memory" >"$nh/.ssh/fleet_memory.pub"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEhost$(printf '%s' "$1" | tr -cd 'a-z0-9') root@$1" >"$nh/.hostkey.pub"
}
# digest_of PROFILE — desired_digest as the master computes it.
digest_of() { FLEET_ROOT=$ROOT bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/vault.sh"; . "$FLEET_ROOT/lib/master.sh"; desired_digest "$1"' _ "$1" 2>/dev/null; }
# vcat FILE.age — decrypt a vault file the way fleet does (key from the backend, through a pipe).
# Exported for the `bash -c` assertions, hence its own exported root variable.
VCAT_ROOT=$ROOT; export VCAT_ROOT
vcat() { FLEET_ROOT=$VCAT_ROOT bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/vault.sh"; vault_cat "$1"' _ "$1"; }
export -f vcat
# mk_plain_vault VAULT — a vault as fleet wrote it before encryption at rest (plaintext files, digest.key).
mk_plain_vault() {
  local v=$1
  mkdir -p "$v/secrets" "$v/files/full/projects/app" "$v/files/minimal" "$v/ssh" "$v/nodes/pending" "$v/nodes/claimed" "$v/locks"
  chmod -R go-rwx "$v"
  printf "CLAUDE_CODE_OAUTH_TOKEN='plain-oauth-FAKE'\n" >"$v/secrets/minimal.env"
  printf "OPENAI_API_KEY='plain-openai-FAKE'\nQUOTED='it'\\\\''s'\n" >"$v/secrets/full.env"
  printf 'DB_URL=postgres://plain-db-FAKE\n' >"$v/files/full/projects/app/.env"
  printf '{"oauth_client_id": "kclientCNTRL", "oauth_client_secret": "tskey-client-kclientCNTRL-FAKE", "tailnet": "-"}\n' >"$v/tailscale.json"
  printf '{"token": "ghtok"}\n' >"$v/github.json"
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n' >"$v/digest.key"
  chmod 0600 "$v"/secrets/* "$v"/files/full/projects/app/.env "$v/tailscale.json" "$v/github.json" "$v/digest.key"
}

# the master's config repo: the shipped example with example repo URLs, committed.
# This fleet opts in to T3 Code remote access (the default is off; tested below).
CFG="$T/fleet-config"
cp -R "$ROOT/examples/fleet-config" "$CFG"
sed 's/YOU/example/g' "$ROOT/examples/fleet-config/fleet.conf" >"$CFG/fleet.conf"
printf 'FLEET_T3_REMOTE=1\n' >>"$CFG/fleet.conf"
( cd "$CFG" && git -c init.defaultBranch=main init -q && git config user.email t@example.invalid && git config user.name t && git add -A && git commit -q -m "config v1" )

# ======================================================================
echo "== init master preflight: nothing is written while Tailscale or git are not ready"
PRE="$T/preflight-home"; mkdir -p "$PRE"
pre_fleet() { HOME="$PRE" FLEET_HOME="$PRE/.config/fleet" FLEET_VAULT="$PRE/.config/fleet/vault" bash "$FLEET" "$@"; }
echo '{"BackendState":"NeedsLogin","Self":{}}' >"$T/status-needslogin.json"
# a token of its own on stdin: it must never be read (a read would revoke it at the fake API)
out=$(printf 'tskey-api-kbootpre-FAKE\n' | FLEET_TS_STATUS_JSON="$T/status-needslogin.json" pre_fleet init master --config-dir "$CFG" 2>&1); rc=$?
assert "tailscale not logged in: init dies before writing anything, names the next step" bash -c "[ $rc != 0 ] && [ ! -e '$PRE/.config' ] && printf '%s' \"\$0\" | grep -q 'Tailscale is not logged in' && printf '%s' \"\$0\" | grep -q 'next: log in'" "$out"
: >"$T/gitconfig-empty"
# run from inside a git checkout that has an identity: only the machine's own config counts
out=$(cd "$CFG" && printf 'tskey-api-kbootpre-FAKE\n' | GIT_CONFIG_GLOBAL="$T/gitconfig-empty" pre_fleet init master --config-dir "$CFG" 2>&1); rc=$?
assert "no git identity: init dies before writing anything, shows the git config commands" bash -c "[ $rc != 0 ] && [ ! -e '$PRE/.config' ] && printf '%s' \"\$0\" | grep -q 'git has no identity' && printf '%s' \"\$0\" | grep -q 'git config --global user.name'" "$out"
refute "preflight never asked for the Tailscale token" printf '%s' "$out" | grep -q 'login.tailscale.com'
refute "preflight never used the token" grep -q 'kbootpre' "$API_LOG"
rm -rf "$PRE"

# ======================================================================
echo "== init master (config dir, bootstrap token -> policy apply -> OAuth client -> revoke; gh fallback token)"
assert "init master without a config dir dies with a hint" bash -c "printf 'tskey-api-kboot-FAKE\n' | bash '$FLEET' init master 2>&1 | grep -q 'next: master: fleet init master --config-dir'"
out=$(printf 'tskey-api-kboot-FAKE\napply\nghtok\n' | bash "$FLEET" init master --config-dir "$CFG" 2>&1); rc=$?
assert "init master exits 0" [ "$rc" = 0 ]
assert "init reported the preflight (tailscale, git identity)" printf '%s' "$out" | grep -q 'preflight: commands present, Tailscale logged in, git identity fleet tester'
assert "config dir recorded in the local fleet.conf (0600)" bash -c "grep -qx \"FLEET_CONFIG_DIR='$CFG'\" '$FLEET_HOME/fleet.conf' && [ \"\$(mode_of '$FLEET_HOME/fleet.conf')\" = 600 ]"
assert "init reports the config dir" printf '%s' "$out" | grep -q "config dir: $CFG"
assert "vault dir 0700" [ "$(mode_of "$FLEET_VAULT")" = 700 ]
assert "nodes/pending + nodes/claimed dirs 0700" bash -c "[ \"\$(mode_of '$FLEET_VAULT/nodes/pending')\" = 700 ] && [ \"\$(mode_of '$FLEET_VAULT/nodes/claimed')\" = 700 ]"
assert "master ssh key generated" [ -f "$FLEET_VAULT/ssh/fleet_master.pub" ]
assert "master ssh key 0600" [ "$(mode_of "$FLEET_VAULT/ssh/fleet_master")" = 600 ]
assert "vault key created in the file backend (0600, outside vault/), public recipient 0644 in the vault, no digest.key" bash -c "[ \"\$(mode_of '$FLEET_HOME/vault.key')\" = 600 ] && grep -q '^AGE-SECRET-KEY-1' '$FLEET_HOME/vault.key' && [ \"\$(mode_of '$FLEET_VAULT/recipient.txt')\" = 644 ] && grep -Eq '^age1[0-9a-z]+$' '$FLEET_VAULT/recipient.txt' && grep -q '^# fleet vault: backend=file' '$FLEET_VAULT/recipient.txt' && [ ! -e '$FLEET_VAULT/digest.key' ]"
assert "init reported the vault key and warned about the file backend" bash -c "printf '%s' \"\$0\" | grep -q 'vault key: file' && printf '%s' \"\$0\" | grep -q \"vault key backend 'file'\"" "$out"
refute "the private key never enters the vault directory" grep -rq 'AGE-SECRET-KEY' "$FLEET_VAULT"
assert "init asked for an API access token (keys page URL shown)" printf '%s' "$out" | grep -q 'login.tailscale.com/admin/settings/keys'
assert "live policy fetched with the bootstrap token" grep -q '^GET /api/v2/tailnet/-/acl' "$API_LOG"
assert "init reported the allow-all finding" printf '%s' "$out" | grep -q 'policy: grants rule lets \* reach the tailnet'
assert "init showed a unified diff mentioning tag:fleet-node" bash -c "printf '%s' \"\$0\" | grep -q '^+++ new policy' && printf '%s' \"\$0\" | grep -q 'tag:fleet-node'" "$out"
assert "policy POSTed with If-Match ETag" grep -Eq '^POST /api/v2/tailnet/-/acl .* If-Match="[0-9a-f]{12}"$' "$API_LOG"
assert "live policy now isolates the fleet tag (merged, not replaced)" python3 "$ROOT/lib/api.py" policy check "$ROOT/templates/tailscale-policy.hujson" "$ACL" tag:fleet-node
assert "merge kept the owner's allow-all as autogroup:member -> *" python3 -c 'import json,sys; g=json.load(open(sys.argv[1]))["grants"]; assert {"src":["autogroup:member"],"dst":["*"],"ip":["*"]} in g' "$ACL"
assert "previous policy backed up into the vault (0600)" bash -c "ls '$FLEET_VAULT'/policy-backups/*.hujson >/dev/null 2>&1 && [ \"\$(mode_of \$(ls '$FLEET_VAULT'/policy-backups/*.hujson | head -1))\" = 600 ]"
assert "OAuth client created: keyType client, scopes, tag" grep -q '^POST /api/v2/tailnet/-/keys {"keyType": "client", "description": "fleet master", "scopes": \["auth_keys", "devices:core", "policy_file:read"\], "tags": \["tag:fleet-node"\]}' "$API_LOG"
assert "tailscale.json.age 0600, no plaintext copy, decrypts to client id + secret" bash -c "[ \"\$(mode_of '$FLEET_VAULT/tailscale.json.age')\" = 600 ] && [ ! -e '$FLEET_VAULT/tailscale.json' ] && vcat '$FLEET_VAULT/tailscale.json.age' | grep -q '\"oauth_client_id\": \"kclientCNTRL\"' && vcat '$FLEET_VAULT/tailscale.json.age' | grep -q '\"oauth_client_secret\": \"tskey-client-kclientCNTRL-FAKE\"'"
refute "the OAuth client secret is not readable anywhere under FLEET_HOME without the key" grep -rq 'tskey-client' "$FLEET_HOME"
assert "bootstrap token revoked by its embedded id" grep -q '^DELETE /api/v2/tailnet/-/keys/kboot$' "$API_LOG"
refute "bootstrap token never stored in the vault" grep -rq 'tskey-api' "$FLEET_VAULT"
refute "no bootstrap temp file left" bash -c "ls '$FLEET_VAULT'/.bootstrap.* 2>/dev/null | grep -q ."
assert "github.json.age has the token (gh unavailable → fallback), no plaintext copy" bash -c "vcat '$FLEET_VAULT/github.json.age' | grep -q '\"token\": \"ghtok\"' && [ ! -e '$FLEET_VAULT/github.json' ] && ! grep -rq ghtok '$FLEET_HOME'"
refute "init output never echoes secrets" printf '%s' "$out" | grep -Eq 'kboot-FAKE|tskey-client|ghtok'
case "$(uname -s)" in
  Darwin) assert "LaunchAgent written" [ -f "$HOME/Library/LaunchAgents/dev.fleet.reconcile.plist" ]
          assert "LaunchAgent interval 120" grep -q '<integer>120</integer>' "$HOME/Library/LaunchAgents/dev.fleet.reconcile.plist" ;;
  *)      assert "systemd timer written" [ -f "$HOME/.config/systemd/user/fleet-reconcile.timer" ] ;;
esac
assert "init master installed the fleeter alias next to fleet (no fleet link here: points at this checkout)" [ "$(readlink "$HOME/.local/bin/fleeter")" = "$ROOT/fleet" ]
assert "init master installed the fleet skill for the harnesses in FLEET_TOOLS (claude): ~/.claude/skills/fleet only" bash -c "printf '%s' \"\$0\" | grep -q 'skill fleet: 1 dir(s) (.claude/skills; 1 changed)' && cmp -s '$HOME/.claude/skills/fleet/SKILL.md' '$ROOT/skills/fleet/SKILL.md' && [ ! -e '$HOME/.agents' ] && [ ! -e '$HOME/.cursor' ]" "$out"
case "$(uname -s)" in
  Darwin) assert "init master wrote the sync LaunchAgent too" [ -f "$HOME/Library/LaunchAgents/dev.fleet.sync.plist" ] ;;
  *)      assert "init master wrote the sync systemd timer too" [ -f "$HOME/.config/systemd/user/fleet-sync.timer" ] ;;
esac
key1=$(cat "$FLEET_VAULT/ssh/fleet_master.pub"); ts1=$(cat "$FLEET_VAULT/tailscale.json.age" | sha256); rc1=$(cat "$FLEET_VAULT/recipient.txt"); vk1=$(cat "$FLEET_HOME/vault.key")
out=$(bash "$FLEET" init master </dev/null 2>&1); rc=$?
assert "init master idempotent (no prompts second time)" [ "$rc" = 0 ]
assert "init master keeps existing key, client, recipient and vault key" bash -c "[ \"\$(cat '$FLEET_VAULT/ssh/fleet_master.pub')\" = '$key1' ] && [ \"\$(cat '$FLEET_VAULT/tailscale.json.age' | sha256)\" = '$ts1' ] && [ \"\$(cat '$FLEET_VAULT/recipient.txt')\" = \"\$0\" ] && [ \"\$(cat '$FLEET_HOME/vault.key')\" = '$vk1' ]" "$rc1"
assert "rerun checks policy with the OAuth client, quietly ok" printf '%s' "$out" | grep -q 'policy: live tailnet policy isolates tag:fleet-node'
# a missing config dir with a known FLEET_CONFIG_REPO is cloned after confirmation
git -c init.defaultBranch=main init -q --bare "$T/cfg-remote.git"; git -C "$CFG" push -q "$T/cfg-remote.git" HEAD:main
printf "FLEET_CONFIG_REPO='%s'\n" "$T/cfg-remote.git" >>"$FLEET_HOME/fleet.conf"
out=$(printf 'n\n' | bash "$FLEET" init master --config-dir "$T/cfg-clone" 2>&1); rc=$?
assert "declined clone: init dies, nothing cloned" bash -c "[ $rc != 0 ] && [ ! -d '$T/cfg-clone' ] && printf '%s' \"\$0\" | grep -q 'Clone $T/cfg-remote.git there'" "$out"
out=$(printf 'y\n' | bash "$FLEET" init master --config-dir "$T/cfg-clone" 2>&1); rc=$?
assert "accepted clone: init exits 0 and the config dir is a checkout of the repo" bash -c "[ $rc = 0 ] && [ -f '$T/cfg-clone/AGENTS.md' ] && [ \"\$(git -C '$T/cfg-clone' remote get-url origin)\" = '$T/cfg-remote.git' ]"
grep -v '^FLEET_CONFIG_REPO=' "$FLEET_HOME/fleet.conf" >"$T/lc"; cat "$T/lc" >"$FLEET_HOME/fleet.conf"
bash "$FLEET" init master --config-dir "$CFG" </dev/null >/dev/null 2>&1
assert "config dir switched back" grep -qx "FLEET_CONFIG_DIR='$CFG'" "$FLEET_HOME/fleet.conf"
# reconcile with the T3 key but no registered node leaves ~/.ssh alone
bash "$FLEET" reconcile >/dev/null 2>&1
refute "reconcile without nodes does not create ~/.ssh/config" [ -e "$HOME/.ssh/config" ]
refute "reconcile without nodes does not create ~/.ssh/config.d/fleet" [ -e "$HOME/.ssh/config.d/fleet" ]

# ======================================================================
echo "== -h/--help prints the synopsis and runs nothing; unknown flags and extra arguments exit 2"
# a fake tailscale that logs every call: `leave` would log out through it
mkdir -p "$T/tsbin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexit 0\n' "$T/ts.log" >"$T/tsbin/tailscale"; chmod +x "$T/tsbin/tailscale"
: >"$T/ts.log"; : >"$SSH_LOG"
vault_snap() { (cd "$FLEET_VAULT" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cat "$f" | sha256)"; done); }
export -f vault_snap
snap0=$(vault_snap); api0=$(grep -c '' "$API_LOG")
HELP_OK=1; HELP_BAD=""
for c in "init master" "secrets set X" "secrets list" "files add $HOME/x" "proxy import" invite list nodes "ssh alpha" "provision alpha" reconcile sync "kick alpha" \
         "t3 setup" "t3 status" "t3 revoke alpha" "config publish" "policy check" "policy apply" "skill install" "skill add $HOME/x" "skill list" "skill remove x" "schedule install" doctor join apply pull update "memory sync" login status leave daemon \
         "vault status" "vault encrypt" "vault rotate-key" "vault export $T/never.age" \
         init secrets files proxy t3 config policy memory skill schedule vault; do
  for h in --help -h; do
    # shellcheck disable=SC2086  # $c is meant to split into words
    out=$(printf 'tskey-api-FAKE\n' | PATH="$T/tsbin:$PATH" bash "$FLEET" $c $h 2>&1); rc=$?
    if [ "$rc" != 0 ] || ! printf '%s' "$out" | grep -q '^fleet '; then HELP_OK=0; HELP_BAD="$HELP_BAD [$c $h -> rc $rc]"; fi
  done
done
assert "every command with -h/--help exits 0 and prints its synopsis${HELP_BAD}" [ "$HELP_OK" = 1 ]
assert "--help ran nothing: vault unchanged, no API call, no ssh, no tailscale logout, no daemon.pid" bash -c "[ \"\$(vault_snap)\" = \"\$0\" ] && [ \"\$(grep -c '' '$API_LOG')\" = $api0 ] && [ ! -s '$SSH_LOG' ] && [ ! -s '$T/ts.log' ] && [ ! -f '$FLEET_HOME/daemon.pid' ]" "$snap0"
assert "fleet secrets set --help did not consume stdin into the vault; vault export --help wrote nothing" bash -c "[ -z \"\$(ls '$FLEET_VAULT/secrets')\" ] && [ ! -e '$T/never.age' ]"
BAD_OK=1; BAD_BAD=""
for c in "leave --bogus" "leave extra" "update --bogus" "daemon --bogus" "reconcile --bogus" "reconcile extra" "doctor --bogus" "status --bogus" \
         "memory sync --bogus" "memory sync extra" "secrets list --bogus" "nodes --bogus" "list --bogus" "list extra" "pull --bogus" "join --bogus" "policy check --bogus" "policy apply extra" \
         "t3 status --bogus" "t3 frobnicate" "config publish --bogus" "config frob" "init" "init bogus" "apply --from-master" "invite --nope" "kick --bogus alpha" \
         "sync --bogus" "sync extra" "skill frob" "skill install --bogus" "skill add --bogus x" "skill add a b" "skill add --name" "skill list --bogus" "skill list extra" \
         "skill remove --bogus x" "skill remove a b" "schedule frob" "schedule install extra" \
         "vault frob" "vault status --bogus" "vault status extra" "vault encrypt --bogus" "vault rotate-key extra" "vault export a b" nosuch; do
  # shellcheck disable=SC2086
  out=$(PATH="$T/tsbin:$PATH" bash "$FLEET" $c </dev/null 2>&1); rc=$?
  if [ "$rc" != 2 ] || ! printf '%s' "$out" | grep -qi 'usage'; then BAD_OK=0; BAD_BAD="$BAD_BAD [$c -> rc $rc]"; fi
done
assert "unknown flags, extra arguments, bad subcommands and unknown commands exit 2 with the usage${BAD_BAD}" [ "$BAD_OK" = 1 ]
assert "rejected invocations ran nothing: vault unchanged, no API call, no ssh, no tailscale call, no daemon.pid" bash -c "[ \"\$(vault_snap)\" = \"\$0\" ] && [ \"\$(grep -c '' '$API_LOG')\" = $api0 ] && [ ! -s '$SSH_LOG' ] && [ ! -s '$T/ts.log' ] && [ ! -f '$FLEET_HOME/daemon.pid' ]" "$snap0"
assert "fleet ssh NODE CMD --help is a remote command, not help" bash -c "out=\$(bash '$FLEET' ssh alpha fleet status --help 2>&1); ! printf '%s' \"\$out\" | grep -q '^fleet ssh NODE'"
assert "fleet --version prints the version" bash -c "bash '$FLEET' --version | grep -qx 'fleet [0-9][0-9.]*'"

# ======================================================================
echo "== secrets"
out=$(printf "s3cr3t'one\n" | bash "$FLEET" secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal 2>&1); rc=$?
assert "secrets set exits 0" [ "$rc" = 0 ]
refute "secrets set never prints value" printf '%s' "$out" | grep -q 's3cr3t'
assert "minimal.env.age 0600, no plaintext env file" bash -c "[ \"\$(mode_of '$FLEET_VAULT/secrets/minimal.env.age')\" = 600 ] && [ ! -e '$FLEET_VAULT/secrets/minimal.env' ]"
assert "the ciphertext is an age file and the value is nowhere under FLEET_HOME in plaintext" bash -c "head -c 20 '$FLEET_VAULT/secrets/minimal.env.age' | grep -q '^age-encryption.org/' && ! grep -rq s3cr3t '$FLEET_HOME'"
assert "value single-quoted with quote escaped (decrypted)" bash -c "vcat '$FLEET_VAULT/secrets/minimal.env.age' | grep -Fxq \"CLAUDE_CODE_OAUTH_TOKEN='s3cr3t'\\\\''one'\""
assert "stored value round-trips through the shell" bash -c "eval \"\$(vcat '$FLEET_VAULT/secrets/minimal.env.age')\"; [ \"\$CLAUDE_CODE_OAUTH_TOKEN\" = \"s3cr3t'one\" ]"
printf 'v2\n' | bash "$FLEET" secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal >/dev/null 2>&1
assert "secrets set replaces existing" [ "$(vcat "$FLEET_VAULT/secrets/minimal.env.age" | grep -c '^CLAUDE_CODE_OAUTH_TOKEN=')" = 1 ]
assert "replaced value is the new one" bash -c "vcat '$FLEET_VAULT/secrets/minimal.env.age' | grep -Fxq \"CLAUDE_CODE_OAUTH_TOKEN='v2'\""
printf 'fullsecret\n' | bash "$FLEET" secrets set OPENAI_API_KEY >/dev/null 2>&1
assert "default profile is full" bash -c "vcat '$FLEET_VAULT/secrets/full.env.age' | grep -q '^OPENAI_API_KEY='"
refute "no decrypted temp file is left in the vault" bash -c "ls '$FLEET_VAULT'/secrets/.fleet.* 2>/dev/null | grep -q ."
refute "invalid name rejected" bash -c "printf 'x\n' | bash '$FLEET' secrets set 'bad name'"
out=$(bash "$FLEET" secrets list 2>&1)
assert "secrets list shows name + profile" printf '%s' "$out" | grep -Eq '^CLAUDE_CODE_OAUTH_TOKEN +minimal$'
assert "secrets list shows full entry" printf '%s' "$out" | grep -Eq '^OPENAI_API_KEY +full$'
refute "secrets list never prints values" printf '%s' "$out" | grep -Eq 'v2|fullsecret'

# ======================================================================
echo "== files add"
mkdir -p "$HOME/repositories/x"; printf 'DB=1\n' >"$HOME/repositories/x/.env"
assert "files add exits 0" bash "$FLEET" files add "$HOME/repositories/x/.env"
assert "file mirrored under files/full as a ciphertext only" bash -c "[ -f '$FLEET_VAULT/files/full/repositories/x/.env.age' ] && [ ! -e '$FLEET_VAULT/files/full/repositories/x/.env' ]"
assert "mirrored file 0600 and decrypts to the source" bash -c "[ \"\$(mode_of '$FLEET_VAULT/files/full/repositories/x/.env.age')\" = 600 ] && vcat '$FLEET_VAULT/files/full/repositories/x/.env.age' | cmp -s - '$HOME/repositories/x/.env'"
printf 'x\n' >"$T/outside.txt"
refute "files add refuses paths outside HOME" bash "$FLEET" files add "$T/outside.txt"

# ======================================================================
echo "== digest (sha256 over the ciphertexts: changes with values and files, needs no key)"
d1=$(digest_of full)
assert "digest is a sha256" printf '%s' "$d1" | grep -Eqx '[0-9a-f]{64}'
assert "digest is stable" [ "$(digest_of full)" = "$d1" ]
echo "# note" >>"$CFG/AGENTS.md"; git -C "$CFG" commit -qam "config v2"
d1b=$(digest_of full)
assert "digest changes when the config repo commit changes" [ "$d1b" != "$d1" ]
d1=$d1b
printf 'v3\n' | bash "$FLEET" secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal >/dev/null 2>&1
d2=$(digest_of full)
assert "digest changes when a secret VALUE changes (names unchanged)" [ "$d2" != "$d1" ]
assert "secret names unchanged" [ "$(vcat "$FLEET_VAULT/secrets/minimal.env.age" | grep -c '=')" = 1 ]
printf 'DB=2\n' >"$HOME/repositories/x/.env"; bash "$FLEET" files add "$HOME/repositories/x/.env" >/dev/null 2>&1
d3=$(digest_of full)
assert "digest changes when a mirrored file's content changes (path unchanged)" [ "$d3" != "$d2" ]
assert "minimal and full digests differ" [ "$(digest_of minimal)" != "$d3" ]
mv "$FLEET_HOME/vault.key" "$T/vault.key.away"
assert "digest needs no key: identical with the vault key unreachable" [ "$(digest_of full)" = "$d3" ]
mv "$T/vault.key.away" "$FLEET_HOME/vault.key"
printf 'v3\n' | bash "$FLEET" secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal >/dev/null 2>&1
assert "re-encrypting an unchanged value changes the digest once (fresh age file key)" [ "$(digest_of full)" != "$d3" ]

# ======================================================================
echo "== invite"
out=$(bash "$FLEET" invite --name alpha 2>"$T/invite.err"); rc=$?
assert "invite exits 0" [ "$rc" = 0 ]
pending=$(find "$FLEET_VAULT/nodes/pending" -name '*.json' | head -1)
assert "pending file written" [ -f "$pending" ]
assert "pending file 0600" [ "$(mode_of "$pending")" = 600 ]
assert "pending has name" grep -q '"name": "alpha"' "$pending"
assert "pending has profile full" grep -q '"profile": "full"' "$pending"
assert "pending has ts_key_id" grep -q '"ts_key_id": "k1"' "$pending"
refute "pending does not store the ts key" grep -q 'tskey-auth' "$pending"
refute "vault never contains the ts key" grep -rq 'tskey-auth' "$FLEET_VAULT"
assert "oauth token exchange uses the minted client" grep -q '^POST /api/v2/oauth/token client_id=kclientCNTRL&client_secret=tskey-client-kclientCNTRL-FAKE' "$API_LOG"
assert "key create called with tag + preauthorized" grep -q '^POST /api/v2/tailnet/-/keys .*"preauthorized": true.*"tag:fleet-node"' "$API_LOG"
assert "key create is not ephemeral by default" grep -q '^POST /api/v2/tailnet/-/keys .*"ephemeral": false' "$API_LOG"
nonce=$(jget "$pending" nonce)
code=$(printf '%s\n' "$out" | grep -E '^[A-Za-z0-9+/=]{40,}$' | tail -1)
assert "invite prints a code" [ -n "$code" ]
decoded=$(printf '%s' "$code" | python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode())')
assert "code decodes to v1 JSON" printf '%s' "$decoded" | grep -q '"v":1'
assert "code carries the ts key" printf '%s' "$decoded" | grep -q '"ts_auth_key":"tskey-auth-k1-FAKE"'
assert "code carries the nonce" printf '%s' "$decoded" | grep -q "\"nonce\":\"$nonce\""
assert "code carries master pubkey + user + tag" printf '%s' "$decoded" | grep -q '"master_pubkey":"ssh-ed25519 .*"master_user":"fleetuser","tag":"tag:fleet-node"'
assert "code carries the hostname prefix (FLEET_HOSTNAME_PREFIX)" printf '%s' "$decoded" | grep -q '"hostname_prefix":"fleet-"'
assert "code carries the fleet's tool list (join skips privileged installs it does not need)" printf '%s' "$decoded" | grep -q '"tools":"base devtools claude"'
assert "invite says single-use + expiry" printf '%s' "$out" | grep -q 'single use, expires'
# shellcheck disable=SC2016  # literal match of the one-liner's prefix
line=$(printf '%s\n' "$out" | grep -F '( d=$(mktemp -d)' | head -1)
assert "invite prints the join one-liner (one line, mktemp -d, EXIT trap)" bash -c "[ -n \"\$0\" ] && [ \"\$(printf '%s\n' \"\$0\" | wc -l | tr -d ' ')\" = 1 ] && printf '%s' \"\$0\" | grep -q \"trap 'rm -rf \\\"\\\$d\\\"' EXIT\"" "$line"
refute "one-liner has no predictable /tmp path" printf '%s' "$line" | grep -q '/tmp/fleet-join'
# run it, but copy the decoded script out and record the temp dir instead of executing join.sh
printf '%s\n' "$line" | sed 's| \&\& bash "\$d/join.sh" )$| \&\& cp "$d/join.sh" '"$T"'/fleet-join.sh \&\& printf %s "$d" > '"$T"'/join.dir )|' >"$T/oneliner.sh"
assert "one-liner decodes on this OS (bash)" bash "$T/oneliner.sh"
assert "decoded join script equals lib/join.sh" cmp -s "$T/fleet-join.sh" "$ROOT/lib/join.sh"
jd=$(cat "$T/join.dir" 2>/dev/null)
assert "one-liner worked under a mktemp dir" bash -c "[ -n '$jd' ] && case '$jd' in '${TMPDIR:-/tmp}'*|/tmp/*|/var/*|/private/*) exit 0 ;; *) exit 1 ;; esac"
assert "one-liner's temp dir removed by the EXIT trap" [ ! -e "$jd" ]
rm -f "$T/fleet-join.sh" "$T/join.dir"
assert "one-liner decodes under sh (POSIX)" bash -c "sh '$T/oneliner.sh' && cmp -s '$T/fleet-join.sh' '$ROOT/lib/join.sh' && [ ! -e \"\$(cat '$T/join.dir')\" ]"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  printf '%s\n' "$line" | sed 's| \&\& bash "\$d/join.sh" )$| \&\& cat "$d/join.sh" \&\& printf %s "$d" >\&2 )|' >"$T/oneliner-linux.sh"
  for shell in bash sh; do
    if docker run --rm -v "$T/oneliner-linux.sh:/x.sh:ro" debian:bookworm-slim "$shell" /x.sh >"$T/join-linux.out" 2>"$T/join-linux.dir" \
       && cmp -s "$T/join-linux.out" "$ROOT/lib/join.sh" && grep -q '^/tmp/tmp\.' "$T/join-linux.dir"; then
      pass "one-liner decodes in debian:bookworm-slim ($shell) under mktemp dir"
    else
      fail "one-liner decodes in debian:bookworm-slim ($shell) under mktemp dir"
    fi
  done
else
  echo "SKIP one-liner decode in debian (docker unavailable)"
fi
refute "invalid --name rejected" bash "$FLEET" invite --name 'Bad_Name'
# M6: --user records the node's login name in the pending file and the code
out=$(bash "$FLEET" invite --name dock --user fleet 2>/dev/null)
dock_pending=$(grep -l '"name": "dock"' "$FLEET_VAULT"/nodes/pending/*.json)
assert "invite --user fleet: pending file records user fleet" [ "$(jget "$dock_pending" user)" = fleet ]
dock_code=$(printf '%s\n' "$out" | grep -E '^[A-Za-z0-9+/=]{40,}$' | tail -1)
assert "invite --user fleet: code carries master_user fleet" bash -c "printf '%s' '$dock_code' | python3 -c 'import base64,json,sys; d=json.loads(base64.b64decode(sys.stdin.read())); assert d[\"master_user\"]==\"fleet\"'"
assert "invite without --user defaults to the master's login" [ "$(jget "$pending" user)" = fleetuser ]
refute "invalid --user rejected" bash "$FLEET" invite --name dock2 --user 'bad user'
rm -f "$dock_pending"
bash "$FLEET" invite --ephemeral --name eph >/dev/null 2>&1
eph_pending=$(grep -l '"name": "eph"' "$FLEET_VAULT"/nodes/pending/*.json)
assert "ephemeral invite defaults to minimal profile" grep -q '"profile": "minimal"' "$eph_pending"
assert "ephemeral invite flag stored" grep -q '"ephemeral": true' "$eph_pending"
assert "ephemeral key requested" grep -q '^POST /api/v2/tailnet/-/keys .*"ephemeral": true' "$API_LOG"
assert "audit log records invite" grep -q ' invite alpha ok' "$FLEET_VAULT/audit.log"

# ======================================================================
echo "== reconcile enrols"
mk_node fleet-alpha.tail1.ts.net "$nonce"
mk_node fleet-beta.tail1.ts.net "bogus-nonce-0000000000"
out=$(bash "$FLEET" reconcile 2>&1); rc=$?
assert "reconcile exits 0" [ "$rc" = 0 ]
assert "alpha registered by tailscale id" [ -f "$FLEET_VAULT/nodes/nAAAACNTRL.json" ]
assert "registry entry 0600" [ "$(mode_of "$FLEET_VAULT/nodes/nAAAACNTRL.json")" = 600 ]
assert "registry has name/dnsname/user" grep -q '"dnsname": "fleet-alpha.tail1.ts.net"' "$FLEET_VAULT/nodes/nAAAACNTRL.json"
assert "registry copies os/arch/container from enrol.json" grep -q '"container": true' "$FLEET_VAULT/nodes/nAAAACNTRL.json"
assert "registry has github key ids (code, config, memory)" bash -c "[ \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' github_keys.code.id)\" = 1 ] && [ \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' github_keys.config.id)\" = 2 ] && [ \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' github_keys.memory.id)\" = 3 ]"
assert "registry records the repo slug next to each key id" bash -c "[ \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' github_keys.code.repo)\" = example/fleeter ] && [ \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' github_keys.config.repo)\" = example/fleet-config ] && [ \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' github_keys.memory.repo)\" = example/fleet-memory ]"
assert "code deploy key read-only on the code repo" grep -q '^POST /repos/example/fleeter/keys .*"read_only": true' "$API_LOG"
assert "registry starts with empty pending_cleanup + missing_since" bash -c "[ \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' pending_cleanup)\" = '[]' ] && [ -z \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' missing_since)\" ]"
assert "pending invite consumed" [ ! -f "$pending" ]
assert "claimed dir empty after enrolment" [ -z "$(ls "$FLEET_VAULT/nodes/claimed")" ]
refute "beta (wrong nonce) not registered" [ -f "$FLEET_VAULT/nodes/nBBBBCNTRL.json" ]
assert "ssh used master_user@dnsname" grep -q '^fleetuser@fleet-alpha.tail1.ts.net cat ~/.config/fleet/enrol.json' "$SSH_LOG"
assert "config deploy key read-only" grep -q '^POST /repos/example/fleet-config/keys .*"read_only": true' "$API_LOG"
assert "memory deploy key read-write" grep -q '^POST /repos/example/fleet-memory/keys .*"read_only": false' "$API_LOG"
assert "deploy key title fleet-<name>-<id>" grep -q '"title": "fleet-alpha-nAAAACNTRL"' "$API_LOG"
refute "no deploy keys for beta" grep -q 'fleet-beta' "$API_LOG"
NH="$NODES/fleet-alpha.tail1.ts.net"
assert "enrol goes straight to provisioned" grep -q '"state": "provisioned"' "$FLEET_VAULT/nodes/nAAAACNTRL.json"
assert "node got secrets.env" [ -f "$NH/.config/fleet/secrets.env" ]
assert "secrets.env 0600 on node" [ "$(mode_of "$NH/.config/fleet/secrets.env")" = 600 ]
assert "secrets.env holds minimal + full (profile full)" bash -c "grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' '$NH/.config/fleet/secrets.env' && grep -q '^OPENAI_API_KEY=' '$NH/.config/fleet/secrets.env'"
assert "code shipped to node" bash -c "[ -f '$NH/.local/share/fleet/fleet' ] && [ -f '$NH/.local/share/fleet/lib/master.sh' ]"
refute "shipped code excludes .git" [ -e "$NH/.local/share/fleet/.git" ]
assert "config repo shipped to node (git archive HEAD)" bash -c "[ -f '$NH/.local/share/fleet-config/AGENTS.md' ] && [ -f '$NH/.local/share/fleet-config/fleet.conf' ] && [ ! -e '$NH/.local/share/fleet-config/.git' ]"
refute "vault never shipped with the code" bash -c "find '$NH/.local/share' -name vault -o -name 'tailscale.json' | grep -q ."
refute "digest.key, vault.key, recipient.txt and no ciphertext ever shipped" bash -c "find '$NH' -name digest.key -o -name vault.key -o -name recipient.txt -o -name '*.age' | grep -q ."
assert "mirrored file landed on node" [ -f "$NH/repositories/x/.env" ]
assert "mirrored file 0600 on node" [ "$(mode_of "$NH/repositories/x/.env")" = 600 ]
assert "mirrored files went through a private staging dir under ~/.config/fleet, removed afterwards" bash -c "grep -q 'stage.XXXXXX' '$SSH_LOG' && ! ls -d '$NH'/.config/fleet/stage.* 2>/dev/null | grep -q ."
assert "provision ran fleet pull --no-apply on the node before apply" bash -c "[ -f '$NH/.fleet-pulled' ] && [ \"\$(grep -n 'fleet pull --no-apply' '$SSH_LOG' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'fleet apply --from-master' '$SSH_LOG' | head -1 | cut -d: -f1)\" ]"
assert "registry records the revs the node reports it applied" [ "$(jget "$FLEET_VAULT/nodes/nAAAACNTRL.json" applied_commit)" = "c0ffee+cafe" ]
assert "revs that differ from the master's checkout are audited, not fatal" grep -q ' provision alpha ok revs-differ' "$FLEET_VAULT/audit.log"
digest=$(jget "$FLEET_VAULT/nodes/nAAAACNTRL.json" provisioned_digest)
assert "apply ran with the desired digest" [ "$(cat "$NH/.config/fleet/applied")" = "$digest" ]
assert "provisioned digest equals desired_digest full" [ "$digest" = "$(digest_of full)" ]
assert "registry secrets_sent names" grep -q '"CLAUDE_CODE_OAUTH_TOKEN"' "$FLEET_VAULT/nodes/nAAAACNTRL.json"
assert "registry files_sent" grep -q '"repositories/x/.env"' "$FLEET_VAULT/nodes/nAAAACNTRL.json"
assert "audit log records enrol + provision" bash -c "grep -q ' enrol alpha ok' '$FLEET_VAULT/audit.log' && grep -q ' provision alpha ok' '$FLEET_VAULT/audit.log'"
refute "lock released after provision" [ -e "$FLEET_VAULT/locks/nAAAACNTRL" ]
: >"$SSH_LOG"
out=$(bash "$FLEET" reconcile 2>&1)
assert "second reconcile is quiet" [ -z "$out" ]
refute "second reconcile does not re-provision" grep -q 'fleet apply' "$SSH_LOG"

# ======================================================================
echo "== t3: client key, pinned host key, ssh config include, restricted authorized_keys line, status, revoke, setup"
T3KEY="$FLEET_VAULT/ssh/t3_client"; KH="$FLEET_VAULT/ssh/known_hosts"; INC="$HOME/.ssh/config.d/fleet"
T3OPTS='restrict,port-forwarding,permitopen="127.0.0.1:*",from="100.64.0.0/10,fd7a:115c:a1e0::/48"'
t3pub=$(cut -d' ' -f1,2 "$T3KEY.pub")
assert "init master created a dedicated T3 client key (ed25519, 0600, comment fleet-t3-client)" bash -c "[ \"\$(mode_of '$T3KEY')\" = 600 ] && grep -q '^ssh-ed25519 .* fleet-t3-client$' '$T3KEY.pub'"
assert "the T3 client key is not the master key" [ "$t3pub" != "$(cut -d' ' -f1,2 "$FLEET_VAULT/ssh/fleet_master.pub")" ]
assert "enrol pinned alpha's host key into vault/ssh/known_hosts (0600, plain entry by dnsname)" bash -c "[ \"\$(mode_of '$KH')\" = 600 ] && grep -qx 'fleet-alpha.tail1.ts.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEhostfleetalphatail1tsnet' '$KH'"
assert "provision put the T3 client key in the node's authorized_keys with the exact options" grep -qxF "$T3OPTS $t3pub fleet-t3-client" "$NH/.ssh/authorized_keys"
assert "node authorized_keys 0600" [ "$(mode_of "$NH/.ssh/authorized_keys")" = 600 ]
assert "reconcile wrote the ssh include (0600) with alpha's block: alias, user, dedicated key only, pinned hosts, strict, no agent" bash -c "[ \"\$(mode_of '$INC')\" = 600 ] && grep -qx 'Host fleet-alpha' '$INC' && grep -qx '  HostName fleet-alpha.tail1.ts.net' '$INC' && grep -qx '  User fleetuser' '$INC' && grep -qxF '  IdentityFile \"$T3KEY\"' '$INC' && grep -qx '  IdentitiesOnly yes' '$INC' && grep -qxF '  UserKnownHostsFile \"$KH\"' '$INC' && grep -qx '  StrictHostKeyChecking yes' '$INC' && grep -qx '  ForwardAgent no' '$INC'"
assert "exactly one block per node" [ "$(grep -c '^Host ' "$INC")" = 1 ]
# shellcheck disable=SC2088  # the literal Include line ssh reads (ssh expands the ~ itself)
assert "~/.ssh/config was created 0600 with the Include as its first line" bash -c "[ \"\$(head -1 '$HOME/.ssh/config')\" = 'Include ~/.ssh/config.d/fleet' ] && [ \"\$(mode_of '$HOME/.ssh/config')\" = 600 ]"
# an existing config of the user's: Include goes to the top once, the original is kept as config.pre-fleet
printf 'Host example\n  User me\n' >"$HOME/.ssh/config"; rm -f "$HOME/.ssh/config.pre-fleet"
bash "$FLEET" reconcile >/dev/null 2>&1
assert "Include inserted at the top of an existing config, once, original backed up" bash -c "[ \"\$(head -1 '$HOME/.ssh/config')\" = 'Include ~/.ssh/config.d/fleet' ] && [ \"\$(grep -c 'Include ~/.ssh/config.d/fleet' '$HOME/.ssh/config')\" = 1 ] && grep -qx 'Host example' '$HOME/.ssh/config' && [ \"\$(cat '$HOME/.ssh/config.pre-fleet')\" = \"\$(printf 'Host example\n  User me')\" ]"
inc1=$(cat "$INC"); cfg1=$(cat "$HOME/.ssh/config"); : >"$SSH_LOG"
out=$(bash "$FLEET" reconcile 2>&1)
assert "reconcile is idempotent and quiet: include, config and known_hosts unchanged, no re-pin" bash -c "[ -z \"\$2\" ] && [ \"\$(cat '$INC')\" = \"\$0\" ] && [ \"\$(cat '$HOME/.ssh/config')\" = \"\$1\" ] && ! grep -q 'ssh_host_ed25519_key.pub' '$SSH_LOG'" "$inc1" "$cfg1" "$out"
# a fake t3 CLI on the node, where T3's SSH flow installs it; it logs argv and answers the list commands
mkdir -p "$NH/.t3/runtime/versions/0.0.45"; echo 0.0.45 >"$NH/.t3/runtime/versions/0.0.45/.install-complete"
cat >"$NH/.t3/runtime/versions/0.0.45/t3" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HOME/.t3/t3.log"
case "$*" in
  *"auth session list"*) echo '[{"sessionId":"sess-ott","subject":"one-time-token","method":"bearer-access-token","client":{"label":"T3 Code","os":"macOS","deviceType":"desktop"},"issuedAt":"2026-10-03T10:00:00Z","expiresAt":"2026-11-02T10:00:00Z","connected":true},{"sessionId":"sess-desk","subject":"desktop-bootstrap","method":"bearer-access-token","client":{"deviceType":"desktop"},"issuedAt":"2026-10-01T10:00:00Z","expiresAt":"2026-10-31T10:00:00Z","connected":true}]' ;;
  *"auth pairing list"*) echo '[{"id":"pair-1","scopes":["orchestration:read"],"subject":"one-time-token","createdAt":"2026-10-03T10:00:00Z","expiresAt":"2026-10-03T10:05:00Z"}]' ;;
esac
EOF
chmod +x "$NH/.t3/runtime/versions/0.0.45/t3"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEmaster000000000000000000000000000000000 fleet-master@mac\n' >>"$NH/.ssh/authorized_keys"
: >"$SSH_LOG"
out=$(bash "$FLEET" t3 status alpha 2>&1); rc=$?
assert "t3 status exits 0, probes over the alias with the client key as T3 does (sh -l -s, no pty)" bash -c "[ $rc = 0 ] && grep -q '^fleet-alpha sh -l -s$' '$SSH_LOG' && printf '%s' \"\$0\" | grep -q 'client key: ok' && printf '%s' \"\$0\" | grep -q 'host key: pinned' && printf '%s' \"\$0\" | grep -q 'runtime 0.0.45'" "$out"
assert "t3 status lists sessions by subject and label, never a token" bash -c "printf '%s' \"\$0\" | grep -q 'sessions: 2 (1 from pairing tokens), pairing tokens: 1' && printf '%s' \"\$0\" | grep -q 'one-time-token .*T3 Code' && ! printf '%s' \"\$0\" | grep -qiE 'credential|access_token|AAAAC3'" "$out"
: >"$SSH_LOG"; : >"$NH/.t3/t3.log"
out=$(bash "$FLEET" t3 revoke alpha 2>&1); rc=$?
assert "t3 revoke exits 0 and goes through the master key" bash -c "[ $rc = 0 ] && grep -q '^fleetuser@fleet-alpha.tail1.ts.net sh -s$' '$SSH_LOG'"
assert "t3 revoke revokes the pairing-token session and the pairing token, not the node's own desktop session" bash -c "grep -q '^auth session revoke --base-dir .* sess-ott$' '$NH/.t3/t3.log' && ! grep -q 'sess-desk' '$NH/.t3/t3.log' && grep -q '^auth pairing revoke --base-dir .* pair-1$' '$NH/.t3/t3.log'"
assert "t3 revoke removed the client key line and kept the master key" bash -c "! grep -q ' fleet-t3-client$' '$NH/.ssh/authorized_keys' && grep -q 'FAKEmaster' '$NH/.ssh/authorized_keys'"
assert "t3 revoke removed the ssh config block and recorded t3_access=false" bash -c "! grep -q 'Host fleet-alpha' '$INC' && [ \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' t3_access)\" = false ]"
assert "audit log records the revoke" grep -q ' t3.revoke alpha ok' "$FLEET_VAULT/audit.log"
bash "$FLEET" provision alpha >/dev/null 2>&1
refute "provision after revoke does not re-add the client key" grep -q ' fleet-t3-client$' "$NH/.ssh/authorized_keys"
: >"$SSH_LOG"
out=$(bash "$FLEET" t3 setup alpha 2>&1); rc=$?
assert "t3 setup exits 0, re-pins over the authenticated session (no keyscan), key line back once, block back" bash -c "[ $rc = 0 ] && grep -q '^fleetuser@fleet-alpha.tail1.ts.net cat /etc/ssh/ssh_host_ed25519_key.pub$' '$SSH_LOG' && [ \"\$(grep -c ' fleet-t3-client$' '$NH/.ssh/authorized_keys')\" = 1 ] && grep -qxF '$T3OPTS $t3pub fleet-t3-client' '$NH/.ssh/authorized_keys' && grep -qx 'Host fleet-alpha' '$INC'"
assert "t3 setup prints the click path and the alias" bash -c "printf '%s' \"\$0\" | grep -q 'Settings -> Connections -> Add environment -> SSH -> host: fleet-alpha'" "$out"
refute "t3 setup output contains no key material" printf '%s' "$out" | grep -q 'AAAAC3'
cp "$NH/.hostkey.pub" "$T/hostkey.bak"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEhostEVIL000000000000000 root@evil" >"$NH/.hostkey.pub"
out=$(bash "$FLEET" t3 setup alpha 2>&1); rc=$?
assert "a host key that changed is refused: known_hosts untouched, setup fails loudly" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'HOST KEY MISMATCH' && grep -qx 'fleet-alpha.tail1.ts.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEhostfleetalphatail1tsnet' '$KH' && ! grep -q 'EVIL' '$KH'" "$out"
cp "$T/hostkey.bak" "$NH/.hostkey.pub"
refute "t3 revoke of an unknown node dies" bash "$FLEET" t3 revoke nosuch
refute "t3 with a bad subcommand dies" bash "$FLEET" t3 frobnicate
# back to the state the following checks expect: the ssh log of a quiet reconcile
: >"$SSH_LOG"
out=$(bash "$FLEET" reconcile 2>&1)
assert "reconcile after t3 setup is quiet again" [ -z "$out" ]
assert "second reconcile checks node applied digest" grep -q 'cat ~/.config/fleet/applied' "$SSH_LOG"
printf 'stale' >"$NH/.config/fleet/applied"
bash "$FLEET" reconcile >/dev/null 2>&1
assert "reconcile re-provisions when node applied differs" [ "$(cat "$NH/.config/fleet/applied")" = "$digest" ]
printf 'v4\n' | bash "$FLEET" secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal >/dev/null 2>&1
: >"$SSH_LOG"; bash "$FLEET" reconcile >/dev/null 2>&1
assert "a changed secret value re-provisions (digest covers values)" bash -c "grep -q 'fleet apply' '$SSH_LOG' && grep -q \"^CLAUDE_CODE_OAUTH_TOKEN='v4'\" '$NH/.config/fleet/secrets.env'"

# ======================================================================
echo "== nonce double-claim (two devices, same nonce, two concurrent reconciles)"
bash "$FLEET" invite --name dup >/dev/null 2>&1
dup_pending=$(grep -l '"name": "dup"' "$FLEET_VAULT"/nodes/pending/*.json)
dup_nonce=$(jget "$dup_pending" nonce)
mk_node fleet-gamma.tail1.ts.net "$dup_nonce"
mk_node fleet-delta.tail1.ts.net "$dup_nonce"
write_status ',"k5":{"ID":"nGAMMACNTRL","HostName":"fleet-gamma","DNSName":"fleet-gamma.tail1.ts.net.","TailscaleIPs":["100.64.0.15"],"Online":true,"Tags":["tag:fleet-node"]},
 "k6":{"ID":"nDELTACNTRL","HostName":"fleet-delta","DNSName":"fleet-delta.tail1.ts.net.","TailscaleIPs":["100.64.0.16"],"Online":true,"Tags":["tag:fleet-node"]}'
touch "$T/slow-enrol"
bash "$FLEET" reconcile >"$T/rec-a.log" 2>&1 &
ra=$!
bash "$FLEET" reconcile >"$T/rec-b.log" 2>&1 &
rb=$!
wait "$ra"; wait "$rb"
rm -f "$T/slow-enrol"
regs=$(find "$FLEET_VAULT/nodes" -name 'nGAMMACNTRL.json' -o -name 'nDELTACNTRL.json' | wc -l | tr -d ' ')
assert "exactly one device enrolled with the shared nonce" [ "$regs" = 1 ]
assert "exactly one set of three deploy keys created for dup" [ "$(grep -c '"title": "fleet-dup-' "$API_LOG")" = 3 ]
assert "dup invite consumed, nothing left in claimed/" bash -c "[ ! -f '$dup_pending' ] && [ -z \"\$(ls '$FLEET_VAULT/nodes/claimed')\" ]"
DUP_ID=$(basename "$(find "$FLEET_VAULT/nodes" -name 'nGAMMACNTRL.json' -o -name 'nDELTACNTRL.json' | head -1)" .json)
assert "the winner is provisioned" [ "$(jget "$FLEET_VAULT/nodes/$DUP_ID.json" state)" = provisioned ]
write_status ""
# a failed enrolment hands the invite back: unreachable pubkey step
bash "$FLEET" invite --name back >/dev/null 2>&1
back_pending=$(grep -l '"name": "back"' "$FLEET_VAULT"/nodes/pending/*.json)
mk_node fleet-back.tail1.ts.net "$(jget "$back_pending" nonce)"
printf 'garbage not a key\n' >"$NODES/fleet-back.tail1.ts.net/.ssh/fleet_memory.pub"   # GitHub rejects it (422) after the config key exists
write_status ',"k7":{"ID":"nBACKCNTRL","HostName":"fleet-back","DNSName":"fleet-back.tail1.ts.net.","TailscaleIPs":["100.64.0.17"],"Online":true,"Tags":["tag:fleet-node"]}'
n_cfg_del=$(grep -c '^DELETE /repos/example/fleet-config/keys/' "$API_LOG"); n_code_del=$(grep -c '^DELETE /repos/example/fleeter/keys/' "$API_LOG")
bash "$FLEET" reconcile >/dev/null 2>&1
assert "failed enrolment moves the claimed invite back to pending" bash -c "[ -f '$back_pending' ] && [ -z \"\$(ls '$FLEET_VAULT/nodes/claimed')\" ] && [ ! -f '$FLEET_VAULT/nodes/nBACKCNTRL.json' ]"
assert "failed enrolment deletes the code and config keys it had created" bash -c "[ \"\$(grep -c '^DELETE /repos/example/fleet-config/keys/' '$API_LOG')\" = $((n_cfg_del + 1)) ] && [ \"\$(grep -c '^DELETE /repos/example/fleeter/keys/' '$API_LOG')\" = $((n_code_del + 1)) ]"
write_status ""; rm -rf "$NODES/fleet-back.tail1.ts.net"; rm -f "$back_pending"

# ======================================================================
echo "== M3: enrolment rollback whose key delete fails -> tombstone, retried by reconcile"
bash "$FLEET" invite --name back2 >/dev/null 2>&1
b2_pending=$(grep -l '"name": "back2"' "$FLEET_VAULT"/nodes/pending/*.json)
b2_nonce=$(jget "$b2_pending" nonce)
mk_node fleet-back2.tail1.ts.net "$b2_nonce"
printf 'garbage not a key\n' >"$NODES/fleet-back2.tail1.ts.net/.ssh/fleet_memory.pub"
write_status ',"k7":{"ID":"nBACK2CNTRL","HostName":"fleet-back2","DNSName":"fleet-back2.tail1.ts.net.","TailscaleIPs":["100.64.0.17"],"Online":true,"Tags":["tag:fleet-node"]}'
touch "$DEVICES_JSON.fail-gh-delete"
bash "$FLEET" reconcile >"$T/rec-b2.log" 2>&1
write_status ""; rm -rf "$NODES/fleet-back2.tail1.ts.net"   # not reachable any more: no re-enrolment
TOMB="$FLEET_VAULT/nodes/rollback-nBACK2CNTRL-$b2_nonce.json"
assert "invite handed back to pending, key fields blanked, no registry entry for the peer" bash -c "[ -f '$b2_pending' ] && [ -z \"\$(jget '$b2_pending' gh_config_key)\" ] && [ ! -f '$FLEET_VAULT/nodes/nBACK2CNTRL.json' ]"
assert "tombstone written: revoked, reason enrol, 0600" bash -c "[ \"\$(jget '$TOMB' state)\" = revoked ] && [ \"\$(jget '$TOMB' revoked_reason)\" = enrol ] && [ \"\$(mode_of '$TOMB')\" = 600 ]"
b2_key=$(jget "$TOMB" pending_cleanup | python3 -c 'import json,sys; l=json.load(sys.stdin); assert len(l)==2 and l[0].startswith("gh:code:") and l[0].endswith(":example/fleeter") and l[1].startswith("gh:config:") and l[1].endswith(":example/fleet-config"); print(l[1].split(":")[2])')
assert "tombstone pending_cleanup holds exactly the code and config keys, each with its repo slug" [ -n "$b2_key" ]
assert "rollback delete was attempted and audited as failed" bash -c "grep -q '^DELETE /repos/example/fleet-config/keys/$b2_key' '$API_LOG' && grep -q ' enrol back2 rollback gh:config:$b2_key:example/fleet-config fail' '$FLEET_VAULT/audit.log'"
assert "nodes lists the tombstone as revoked cleanup-pending" bash -c "bash '$FLEET' nodes | grep -Eq '^back2 +rollback-nBACK2CNTRL-.* revoked .*cleanup-pending'"
rm -f "$b2_pending"
n_b2=$(grep -c "^DELETE /repos/example/fleet-config/keys/$b2_key" "$API_LOG")
bash "$FLEET" reconcile >/dev/null 2>&1
assert "still failing: tombstone kept, delete retried" bash -c "[ -f '$TOMB' ] && [ \"\$(grep -c '^DELETE /repos/example/fleet-config/keys/$b2_key' '$API_LOG')\" -gt $n_b2 ]"
rm -f "$DEVICES_JSON.fail-gh-delete"
bash "$FLEET" reconcile >/dev/null 2>&1
refute "delete succeeds: tombstone forgotten" [ -f "$TOMB" ]
assert "rollback cleanup + forget audited" bash -c "grep -q ' cleanup back2 gh:config:$b2_key:example/fleet-config ok' '$FLEET_VAULT/audit.log' && grep -q ' forget back2 enrol rollback done' '$FLEET_VAULT/audit.log'"
# a crashed enrolment leaves a claimed file with key ids: the expiry sweep rolls them back
cat >"$FLEET_VAULT/nodes/claimed/crash0000000000000000000000.nCRASHCNTRL.json" <<'EOF'
{"nonce":"crash0000000000000000000000","name":"crash","profile":"full","ephemeral":false,"created":"2026-01-01T00:00:00Z","expires":"2026-01-01T01:00:00Z","ts_key_id":"k77","user":"fleetuser","id":"nCRASHCNTRL","gh_code_key":"776","gh_config_key":"777","gh_memory_key":"778"}
EOF
bash "$FLEET" reconcile >/dev/null 2>&1
assert "expired claimed file from a crash: all three recorded keys deleted, file dropped" bash -c "grep -q '^DELETE /repos/example/fleeter/keys/776' '$API_LOG' && grep -q '^DELETE /repos/example/fleet-config/keys/777' '$API_LOG' && grep -q '^DELETE /repos/example/fleet-memory/keys/778' '$API_LOG' && [ ! -f '$FLEET_VAULT/nodes/claimed/crash0000000000000000000000.nCRASHCNTRL.json' ]"

# ======================================================================
echo "== provision / nodes"
assert "provision by name" bash "$FLEET" provision alpha
assert "provision by id" bash "$FLEET" provision nAAAACNTRL
refute "provision unknown name dies" bash "$FLEET" provision nope
refute "provision never guesses a hostname" bash "$FLEET" provision fleet-beta
out=$(bash "$FLEET" nodes 2>&1)
assert "nodes lists alpha online provisioned" printf '%s\n' "$out" | grep -Eq '^alpha +nAAAACNTRL +yes +provisioned +full'
assert "nodes lists unregistered tagged peer as unknown" printf '%s\n' "$out" | grep -Eq '^fleet-beta +nBBBBCNTRL +yes +unknown'
refute "nodes ignores untagged peers" printf '%s\n' "$out" | grep -q laptop
out=$(bash "$FLEET" nodes --live 2>&1)
assert "nodes --live shows tool states" printf '%s\n' "$out" | grep -q 'claude:ok codex:login'

# ======================================================================
echo "== vault: nothing decrypted touches disk during a provision; status; rotate-key; unreachable key; export"
CANARY=canary-7f3a9c-value; FCANARY=canary-file-5d2e
printf '%s\n' "$CANARY" | bash "$FLEET" secrets set CANARY_SECRET --profile minimal >/dev/null 2>&1
mkdir -p "$HOME/repositories/c" "$T/tmp"; printf 'FILE_CANARY=%s\n' "$FCANARY" >"$HOME/repositories/c/.env"
bash "$FLEET" files add "$HOME/repositories/c/.env" >/dev/null 2>&1
# canary_hits — files under FLEET_HOME or this run's TMPDIR that hold a canary value (the fake node homes are elsewhere)
canary_hits() { grep -rlF -e "$CANARY" -e "$FCANARY" "$FLEET_HOME" "$T/tmp" 2>/dev/null || true; }
assert "after secrets set + files add: the canaries exist only as ciphertext" bash -c "[ -z \"\$0\" ] && [ -f '$FLEET_VAULT/files/full/repositories/c/.env.age' ]" "$(canary_hits)"
echo 3 >"$T/slow-secrets"; echo 3 >"$T/slow-files"
: >"$SSH_LOG"
TMPDIR="$T/tmp" bash "$FLEET" provision alpha >"$T/prov-canary.log" 2>&1 &
PROV_PID=$!
assert "provision reached the secrets step (env decrypted into memory, piped into ssh)" wait_for 20 grep -q 'secrets.env.tmp' "$SSH_LOG"
snap1=$(canary_hits)
assert "while the secrets stream is open: no plaintext canary under FLEET_HOME or TMPDIR" [ -z "$snap1" ]
assert "provision reached the files step (tar built in memory)" wait_for 20 grep -q 'stage.XXXXXX' "$SSH_LOG"
snap2=$(canary_hits)
assert "while the files stream is open: no plaintext canary under FLEET_HOME or TMPDIR" [ -z "$snap2" ]
wait "$PROV_PID" 2>/dev/null; prc=$?; PROV_PID=""
rm -f "$T/slow-secrets" "$T/slow-files"
assert "provision exits 0" [ "$prc" = 0 ] || cat "$T/prov-canary.log"
assert "node received the canary secret and the mirrored canary file (0600, plain name)" bash -c "grep -q \"^CANARY_SECRET='$CANARY'\" '$NH/.config/fleet/secrets.env' && grep -qx 'FILE_CANARY=$FCANARY' '$NH/repositories/c/.env' && [ \"\$(mode_of '$NH/repositories/c/.env')\" = 600 ] && [ ! -e '$NH/repositories/c/.env.age' ]"
assert "the earlier mirrored file arrives through the same in-memory tar" grep -qx 'DB=2' "$NH/repositories/x/.env"
assert "afterwards: nothing decrypted under FLEET_HOME or TMPDIR, no temp files in the vault" bash -c "[ -z \"\$0\" ] && ! find '$FLEET_VAULT' -name '.fleet.*' | grep -q ." "$(canary_hits)"
assert "registry files_sent lists node paths, never .age" bash -c "jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' files_sent | grep -q '\"repositories/c/.env\"' && ! jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' files_sent | grep -q '\\.age'"
out=$(bash "$FLEET" vault status 2>&1); rc=$?
assert "vault status: exit 0; backend file, recipient, key reachable, encrypted count, no plaintext" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q '^backend:    file ' && printf '%s' \"\$0\" | grep -Eq '^recipient:  age1[0-9a-z]+ ' && printf '%s' \"\$0\" | grep -q '^key:        reachable' && printf '%s' \"\$0\" | grep -Eq '^encrypted:  [1-9][0-9]* file' && printf '%s' \"\$0\" | grep -q '^plaintext:  none'" "$out"
refute "vault status prints no private key and no value" printf '%s' "$out" | grep -Eq "AGE-SECRET-KEY|$CANARY"
# rotate-key: new recipient + key, every value identical, old key useless, digest changed once
rcpt_old=$(grep -v '^#' "$FLEET_VAULT/recipient.txt"); key_old=$(cat "$FLEET_HOME/vault.key"); d_before=$(digest_of full)
vals_before=$(vcat "$FLEET_VAULT/secrets/minimal.env.age"; vcat "$FLEET_VAULT/secrets/full.env.age"; vcat "$FLEET_VAULT/files/full/repositories/c/.env.age"; vcat "$FLEET_VAULT/tailscale.json.age")
out=$(bash "$FLEET" vault rotate-key 2>&1); rc=$?
assert "vault rotate-key exits 0 and reports the count" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -Eq 'vault key rotated: [1-9][0-9]* file'" "$out"
assert "recipient and key changed, no incoming key and no .rotating file left, backend still recorded" bash -c "[ \"\$(grep -v '^#' '$FLEET_VAULT/recipient.txt')\" != '$rcpt_old' ] && [ \"\$(cat '$FLEET_HOME/vault.key')\" != '$key_old' ] && [ ! -e '$FLEET_HOME/vault.key.next' ] && ! find '$FLEET_VAULT' -name '*.rotating' | grep -q . && grep -q '^# fleet vault: backend=file' '$FLEET_VAULT/recipient.txt'"
assert "every value decrypts to the same bytes with the new key" [ "$(vcat "$FLEET_VAULT/secrets/minimal.env.age"; vcat "$FLEET_VAULT/secrets/full.env.age"; vcat "$FLEET_VAULT/files/full/repositories/c/.env.age"; vcat "$FLEET_VAULT/tailscale.json.age")" = "$vals_before" ]
refute "the old key no longer decrypts" bash -c "printf '%s\n' '$key_old' | age -d -i - '$FLEET_VAULT/secrets/minimal.env.age' >/dev/null 2>&1"
d_after=$(digest_of full)
assert "rotation changed the digest (fresh ciphertexts)" [ "$d_after" != "$d_before" ]
: >"$SSH_LOG"; bash "$FLEET" reconcile >/dev/null 2>&1
assert "the next reconcile re-provisions alpha once; the node keeps the canary" bash -c "grep -q 'fleet apply' '$SSH_LOG' && [ \"\$(cat '$NH/.config/fleet/applied')\" = '$d_after' ] && grep -q \"^CANARY_SECRET='$CANARY'\" '$NH/.config/fleet/secrets.env'"
assert "audit records the rotation" grep -q ' vault.rotate - ok' "$FLEET_VAULT/audit.log"
assert "the master lock is free after the rotation" [ ! -d "$FLEET_VAULT/locks/.sync" ]
# the key becomes unreachable (file backend: the key file is gone; keychain: locked)
mv "$FLEET_HOME/vault.key" "$T/vault.key.away"
full_sum=$(sha256 <"$FLEET_VAULT/secrets/full.env.age")
out=$(bash "$FLEET" secrets list 2>&1); rc=$?
assert "key unreachable: secrets list dies with the next step and prints no name" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'cannot decrypt' && printf '%s' \"\$0\" | grep -q 'vault.key is missing' && ! printf '%s' \"\$0\" | grep -q CANARY_SECRET" "$out"
out=$(printf 'x\n' | bash "$FLEET" secrets set FOO 2>&1); rc=$?
assert "key unreachable: secrets set dies before touching the file" bash -c "[ $rc != 0 ] && [ \"\$(sha256 <'$FLEET_VAULT/secrets/full.env.age')\" = '$full_sum' ]"
assert "vault status reports the key UNREACHABLE (exit 0)" bash -c "bash '$FLEET' vault status 2>&1 | grep -q '^key:        UNREACHABLE'"
printf 'stale' >"$NH/.config/fleet/applied"; : >"$SSH_LOG"
out=$(bash "$FLEET" reconcile 2>&1); rc=$?
assert "reconcile with the key unreachable: exit 0, skips alpha with a clear warning before shipping anything" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'alpha: provision skipped, the vault key is unreachable' && ! grep -q 'secrets.env.tmp' '$SSH_LOG' && ! grep -q 'fleet apply' '$SSH_LOG' && ! grep -q 'tar -x' '$SSH_LOG' && [ \"\$(cat '$NH/.config/fleet/applied')\" = stale ]" "$out"
assert "the skip is audited; registry state untouched" bash -c "grep -q ' provision alpha skip vault-locked' '$FLEET_VAULT/audit.log' && [ \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' state)\" = provisioned ]"
assert "fleet list works without the key: the desired digest comes from the ciphertexts" bash -c "bash '$FLEET' list --offline --json 2>/dev/null | python3 -c 'import json,sys; d={x[\"name\"]: x for x in json.load(sys.stdin)}; assert d[\"alpha\"][\"desired\"][\"digest\"] == \"$d_after\"'"
out=$(bash "$FLEET" doctor 2>&1); rc=$?
assert "doctor fails and names the unreachable key" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'vault key: UNREACHABLE'" "$out"
refute "vault encrypt refuses while the key is unreachable" bash "$FLEET" vault encrypt
refute "vault rotate-key refuses while the key is unreachable" bash "$FLEET" vault rotate-key
assert "nothing changed while the key was away" [ "$(sha256 <"$FLEET_VAULT/secrets/full.env.age")" = "$full_sum" ]
mv "$T/vault.key.away" "$FLEET_HOME/vault.key"
: >"$SSH_LOG"; bash "$FLEET" reconcile >/dev/null 2>&1
assert "key back: the next reconcile provisions alpha again" bash -c "grep -q 'fleet apply' '$SSH_LOG' && [ \"\$(cat '$NH/.config/fleet/applied')\" = '$d_after' ]"
# export: age -p needs a terminal; the tar itself is checked without the passphrase step
out=$(bash "$FLEET" vault export "$T/export.age" </dev/null 2>&1); rc=$?
assert "vault export without a terminal dies with the hint and writes nothing" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'needs a terminal' && [ ! -e '$T/export.age' ]" "$out"
export_list() { FLEET_ROOT=$ROOT bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/vault.sh"; vault_identity | vault_tar export "$FLEET_VAULT"' | tar -tf - 2>/dev/null; }
assert "the export tar: decrypted members under their plain names, ssh keys and registry included, no .age, no locks/, no recipient" bash -c "printf '%s\n' \"\$0\" | grep -qx 'secrets/minimal.env' && printf '%s\n' \"\$0\" | grep -qx 'files/full/repositories/c/.env' && printf '%s\n' \"\$0\" | grep -qx 'ssh/fleet_master' && printf '%s\n' \"\$0\" | grep -qx 'nodes/nAAAACNTRL.json' && ! printf '%s\n' \"\$0\" | grep -q '\\.age\$' && ! printf '%s\n' \"\$0\" | grep -q '^locks/' && ! printf '%s\n' \"\$0\" | grep -qx 'recipient.txt'" "$(export_list)"
assert "the export tar carries the decrypted value" bash -c "FLEET_ROOT='$ROOT' bash -c '. \"\$FLEET_ROOT/lib/common.sh\"; fleet_load_config; . \"\$FLEET_ROOT/lib/vault.sh\"; vault_identity | vault_tar export \"\$FLEET_VAULT\"' | tar -xOf - secrets/minimal.env | grep -q \"^CANARY_SECRET='$CANARY'\""

# ======================================================================
echo "== list (registry + tailnet + fleet status --json per node; unreachable, offline and unknown peers; --json; --offline)"
# two extra registry entries: unr is online on the tailnet but has no fake home (ssh exits 255);
# off is registered but absent from the tailnet
for n in unr off; do
  cat >"$FLEET_VAULT/nodes/n$(echo "$n" | tr '[:lower:]' '[:upper:]')CNTRL.json" <<EOF
{"id":"n$(echo "$n" | tr '[:lower:]' '[:upper:]')CNTRL","name":"$n","hostname":"fleet-$n","dnsname":"fleet-$n.tail1.ts.net","user":"fleetuser","os":"linux","arch":"amd64","container":true,"profile":"minimal","ephemeral":false,"state":"provisioned","enrolled":"2026-10-03T09:00:00Z","provisioned":"2026-10-03T09:01:00Z","provisioned_digest":"stale","applied_commit":"old+old","missing_since":"","pending_cleanup":[],"github_keys":{},"secrets_sent":[],"files_sent":[]}
EOF
  chmod 0600 "$FLEET_VAULT/nodes/n$(echo "$n" | tr '[:lower:]' '[:upper:]')CNTRL.json"
done
write_status ',"k10":{"ID":"nUNRCNTRL","HostName":"fleet-unr","DNSName":"fleet-unr.tail1.ts.net.","TailscaleIPs":["100.64.0.30"],"Online":true,"Tags":["tag:fleet-node"]}'
want_code=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || FLEET_ROOT=$ROOT bash -c '. "$FLEET_ROOT/lib/common.sh"; sha256_tree "$FLEET_ROOT"')
want_cfg=$(git -C "$CFG" rev-parse HEAD)
# alpha answers with a full status: applied revs + digest equal to the master's desired state
python3 - "$T/status-reply.json" "$want_code+$want_cfg" "$(digest_of full)" <<'EOF'
import json, sys
tools = {n: {"state": "ok", "detail": "1.0"} for n in ("base", "devtools", "claude", "codex", "chrome", "grok", "t3code", "cliproxy", "mise")}
tools["cursor"] = {"state": "login", "detail": "run: fleet login cursor"}
json.dump({"fleet": "0.3.0", "name": "alpha", "os": "linux", "container": True, "applied": sys.argv[3], "applied_at": "2026-10-03T10:00:00Z",
           "applied_commit": sys.argv[2], "tools": tools, "memory": {"state": "ok", "last_sync": "2026-10-03T10:00:00Z"},
           "timers": {"pull": True}, "token_age_days": {}, "updated": "2026-10-03T10:00:00Z"}, open(sys.argv[1], "w"))
EOF
: >"$SSH_LOG"
out=$(bash "$FLEET" list 2>"$T/list.err"); rc=$?
assert "list exits 0 with an unreachable node in the fleet" [ "$rc" = 0 ]
assert "list header: NAME HOST ONLINE STATE SYNCED LAST PROVISION TOOLS MEMORY PROXY FLEET" bash -c "printf '%s\n' \"\$0\" | head -1 | grep -Eq '^NAME +HOST +ONLINE +STATE +SYNCED +LAST PROVISION +TOOLS +MEMORY +PROXY +FLEET$'" "$out"
assert "list: alpha online, provisioned, synced yes, tools summarised (9 ok, 1 login: cursor), memory ok, proxy ok, fleet 0.3.0" \
  bash -c "printf '%s\n' \"\$0\" | grep -Eq '^alpha +fleet-alpha +yes +provisioned +yes +[0-9]+[mhd] +9 ok, 1 login: cursor +ok +ok +0\.3\.0$'" "$out"
assert "list: unr online but not answering -> unreachable, synced from the registry (behind), no live columns" \
  bash -c "printf '%s\n' \"\$0\" | grep -Eq '^unr +fleet-unr +yes +provisioned +behind +[0-9]+[mhd] +unreachable +- +- +-$'" "$out"
assert "list: off is registered but not on the tailnet -> online no, no ssh attempted" \
  bash -c "printf '%s\n' \"\$0\" | grep -Eq '^off +fleet-off +no +provisioned +behind ' && ! grep -q 'fleet-off' '$SSH_LOG'" "$out"
assert "list: unregistered tagged peer shown as unknown" bash -c "printf '%s\n' \"\$0\" | grep -Eq '^fleet-beta +fleet-beta +yes +unknown +- +- +- +- +- +-$'" "$out"
refute "list ignores untagged peers" printf '%s' "$out" | grep -q laptop
assert "list asked every online registered node once (alpha, unr), with the status command" bash -c "[ \"\$(grep -c 'fleet-alpha.tail1.ts.net ~/.local/bin/fleet status --json' '$SSH_LOG')\" = 1 ] && [ \"\$(grep -c 'fleet-unr.tail1.ts.net' '$SSH_LOG')\" = 1 ]"
out=$(bash "$FLEET" list --json 2>/dev/null); rc=$?
assert "list --json exits 0 and is a JSON array with every registered node and the unknown peer" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, list) and {\"alpha\",\"unr\",\"off\",\"fleet-beta\",\"dup\"} <= set(x[\"name\"] for x in d)'" "$out"
assert "list --json: alpha record (schema fields, synced yes, reachable, desired == applied, tools, memory, proxy, fleet)" bash -c "printf '%s' \"\$0\" | python3 -c '
import json,sys
d={x[\"name\"]: x for x in json.load(sys.stdin)}; a=d[\"alpha\"]
assert a[\"id\"]==\"nAAAACNTRL\" and a[\"host\"]==\"fleet-alpha\" and a[\"online\"] is True and a[\"reachable\"] is True
assert a[\"state\"]==\"provisioned\" and a[\"provisioning\"] is False and a[\"synced\"]==\"yes\" and a[\"profile\"]==\"full\"
assert a[\"desired\"][\"code\"]==a[\"applied\"][\"code\"]==\"$want_code\" and a[\"desired\"][\"config\"]==a[\"applied\"][\"config\"]==\"$want_cfg\"
assert a[\"desired\"][\"digest\"]==a[\"applied\"][\"digest\"] and a[\"applied\"][\"source\"]==\"node\"
assert a[\"tools\"][\"cursor\"][\"state\"]==\"login\" and a[\"memory\"]==\"ok\" and a[\"proxy\"]==\"ok\" and a[\"fleet\"]==\"0.3.0\"
assert a[\"provisioned\"] and a[\"provisioned_age\"] and a[\"cleanup_pending\"]==[] and a[\"missing_since\"]==\"\"
'" "$out"
assert "list --json: unreachable and offline nodes (reachable false / null, synced behind from the registry, empty tools), unknown peer" bash -c "printf '%s' \"\$0\" | python3 -c '
import json,sys
d={x[\"name\"]: x for x in json.load(sys.stdin)}
u=d[\"unr\"]; assert u[\"online\"] is True and u[\"reachable\"] is False and u[\"synced\"]==\"behind\" and u[\"tools\"]=={} and u[\"applied\"][\"source\"]==\"registry\" and u[\"memory\"] is None and u[\"fleet\"] is None
o=d[\"off\"]; assert o[\"online\"] is False and o[\"reachable\"] is None and o[\"synced\"]==\"behind\" and o[\"tools\"]=={}
b=d[\"fleet-beta\"]; assert b[\"state\"]==\"unknown\" and b[\"id\"]==\"nBBBBCNTRL\" and b[\"online\"] is True and b[\"synced\"] is None and b[\"profile\"] is None
'" "$out"
# the node reports older revs than the master's checkout: behind
python3 - "$T/status-reply.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); d["applied_commit"] = "old+old"; json.dump(d, open(sys.argv[1], "w"))
EOF
out=$(bash "$FLEET" list 2>/dev/null)
assert "list: a node whose applied revs differ from the master's is behind" bash -c "printf '%s\n' \"\$0\" | grep -Eq '^alpha +fleet-alpha +yes +provisioned +behind '" "$out"
: >"$SSH_LOG"
out=$(bash "$FLEET" list --offline 2>/dev/null); rc=$?
assert "list --offline exits 0, no ssh at all, registry + tailnet columns only" bash -c "[ $rc = 0 ] && [ ! -s '$SSH_LOG' ] && printf '%s\n' \"\$0\" | grep -Eq '^alpha +fleet-alpha +yes +provisioned +behind +[0-9]+[mhd] +- +- +- +-$'" "$out"
assert "list --offline --json: reachable null, synced from the registry" bash -c "bash '$FLEET' list --offline --json 2>/dev/null | python3 -c '
import json,sys
d={x[\"name\"]: x for x in json.load(sys.stdin)}; a=d[\"alpha\"]
assert a[\"reachable\"] is None and a[\"synced\"]==\"behind\" and a[\"applied\"][\"source\"]==\"registry\" and a[\"tools\"]=={}'"
rm -f "$T/status-reply.json" "$FLEET_VAULT/nodes/nUNRCNTRL.json" "$FLEET_VAULT/nodes/nOFFCNTRL.json"
write_status ""

# ======================================================================
echo "== policy check / apply"
cp "$ROOT/templates/tailscale-policy.hujson" "$T/acl.template.bak"
printf '%s\n' "$ALLOW_ALL" >"$ACL"
out=$(bash "$FLEET" policy check 2>&1); rc=$?
assert "policy check FAILs on the default allow-all policy" [ "$rc" != 0 ]
assert "policy check names the wildcard rule and missing grants" bash -c "printf '%s' \"\$0\" | grep -q 'grants rule lets \* reach the tailnet' && printf '%s' \"\$0\" | grep -q 'grant missing' && printf '%s' \"\$0\" | grep -q 'tagOwners\[tag:fleet-node\] missing'" "$out"
cp "$T/acl.template.bak" "$ACL"
out=$(bash "$FLEET" policy check 2>&1); rc=$?
assert "policy check passes on the template" [ "$rc" = 0 ]
assert "policy check quiet on success (exactly one line)" [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ]
# a policy that keeps the template grants but adds a tag:fleet-node src rule must fail
python3 - "$ACL" "$T/acl.bad.hujson" <<'EOF'
import sys
t = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(t.replace('"grants": [', '"grants": [\n    {"src": ["tag:fleet-node"], "dst": ["autogroup:member"], "ip": ["tcp:22"]},', 1))
EOF
cp "$T/acl.bad.hujson" "$ACL"
out=$(bash "$FLEET" policy check 2>&1); rc=$?
assert "policy check FAILs when a rule has src tag:fleet-node" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'lets tag:fleet-node reach'" "$out"
# M4: a src that is not a person (CIDR, IP, host alias, other tag/autogroup)
# is rejected unless the rule's dst is only tag:fleet-node. Offline through api.py.
policy_with() {   # policy_with SECTION RULE_JSON — template + one extra rule; runs the offline check
  python3 - "$T/acl.template.bak" "$T/acl.m4.hujson" "$1" "$2" <<'EOF'
import sys
t = open(sys.argv[1]).read()
if sys.argv[3] == "grants":
    t = t.replace('"grants": [', '"grants": [\n    ' + sys.argv[4] + ',', 1)
else:
    t = t.rstrip().rstrip("}") + '\n  "%s": [%s],\n}\n' % (sys.argv[3], sys.argv[4])   # grants already ends with "],"
open(sys.argv[2], "w").write(t)
EOF
  python3 "$ROOT/lib/api.py" policy check "$ROOT/templates/tailscale-policy.hujson" "$T/acl.m4.hujson" tag:fleet-node
}
refute "policy check rejects a CIDR src" policy_with grants '{"src": ["100.64.0.0/10"], "dst": ["*"], "ip": ["*"]}'
refute "policy check rejects an IP src" policy_with grants '{"src": ["100.64.0.5"], "dst": ["autogroup:member"], "ip": ["tcp:22"]}'
refute "policy check rejects a host-alias src" policy_with grants '{"src": ["my-laptop"], "dst": ["autogroup:member"], "ip": ["*"]}'
refute "policy check rejects another tag as src" policy_with grants '{"src": ["tag:other"], "dst": ["autogroup:member"], "ip": ["*"]}'
refute "policy check rejects a CIDR src in a legacy acl with dst *:*" policy_with acls '{"action": "accept", "src": ["100.64.0.0/10"], "dst": ["*:*"]}'
refute "policy check rejects a host src in an ssh rule to autogroup:self" policy_with ssh '{"action": "accept", "src": ["my-laptop"], "dst": ["autogroup:self"], "users": ["root"]}'
out=$(policy_with grants '{"src": ["100.64.0.0/10"], "dst": ["*"], "ip": ["*"]}' 2>&1)
assert "policy check names the vague src and the rule" printf '%s' "$out" | grep -q 'src that is not a user, group or user autogroup (100.64.0.0/10)'
assert "policy check allows a CIDR src whose dst is only tag:fleet-node" policy_with grants '{"src": ["100.64.0.0/10"], "dst": ["tag:fleet-node"], "ip": ["tcp:22"]}'
assert "policy check allows a legacy acl with dst tag:fleet-node:22 only" policy_with acls '{"action": "accept", "src": ["100.64.0.0/10"], "dst": ["tag:fleet-node:22"]}'
assert "policy check allows a group src" policy_with grants '{"src": ["group:eng"], "dst": ["autogroup:member"], "ip": ["*"]}'
assert "policy check allows a user login src" policy_with grants '{"src": ["alice@example.com"], "dst": ["*"], "ip": ["*"]}'
assert "policy check allows autogroup:admin and autogroup:owner src" policy_with grants '{"src": ["autogroup:admin", "autogroup:owner"], "dst": ["*"], "ip": ["*"]}'
python3 - "$T/acl.template.bak" "$ACL" <<'EOF'
import sys
t = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(t.replace('"grants": [', '"grants": [\n    {"src": ["100.64.0.0/10"], "dst": ["*"], "ip": ["*"]},', 1))
EOF
refute "fleet policy check FAILs on a live policy with a CIDR src" bash "$FLEET" policy check
printf '%s\n' "$ALLOW_ALL" >"$ACL"
n_before=$(grep -c '^POST /api/v2/tailnet/-/acl' "$API_LOG")
out=$(printf 'tskey-api-kboot2-FAKE\nnope\n' | bash "$FLEET" policy apply 2>&1); rc=$?
assert "policy apply without the typed word does not POST" bash -c "[ $rc != 0 ] && [ \"\$(grep -c '^POST /api/v2/tailnet/-/acl' '$API_LOG')\" = $n_before ]"
assert "policy apply revokes its bootstrap token even when skipped" grep -q '^DELETE /api/v2/tailnet/-/keys/kboot2$' "$API_LOG"
out=$(printf 'tskey-api-kboot3-FAKE\napply\n' | bash "$FLEET" policy apply 2>&1); rc=$?
assert "policy apply exits 0" [ "$rc" = 0 ]
assert "policy apply showed the diff and POSTed with If-Match" bash -c "printf '%s' \"\$0\" | grep -q '^--- live policy' && [ \"\$(grep -c '^POST /api/v2/tailnet/-/acl .* If-Match=\"' '$API_LOG')\" = $((n_before + 1)) ]" "$out"
assert "live policy isolates the fleet tag after apply" python3 "$ROOT/lib/api.py" policy check "$ROOT/templates/tailscale-policy.hujson" "$ACL" tag:fleet-node
assert "policy apply revoked bootstrap token kboot3" grep -q '^DELETE /api/v2/tailnet/-/keys/kboot3$' "$API_LOG"
refute "policy apply never echoes the token" printf '%s' "$out" | grep -q 'kboot3-FAKE'
assert "policy apply on an already-matching policy is a no-op" bash -c "printf 'tskey-api-kboot4-FAKE\n' | bash '$FLEET' policy apply 2>&1 | grep -q 'already isolates'"

# ======================================================================
echo "== doctor (isolation negative test from the online provisioned node)"
: >"$SSH_LOG"
out=$(bash "$FLEET" doctor 2>&1); rc=$?
assert "doctor passes" [ "$rc" = 0 ]
assert "doctor probed master:22 and master:443 from alpha, once each" bash -c "[ \"\$(grep -c '^fleetuser@fleet-alpha.tail1.ts.net nc -z -w 3 100.64.0.1 22$' '$SSH_LOG')\" = 1 ] && [ \"\$(grep -c 'nc -z -w 3 100.64.0.1 443$' '$SSH_LOG')\" = 1 ]"
assert "doctor isolation summary (quiet, one line)" [ "$(printf '%s\n' "$out" | grep -c 'isolation: 2 probe(s) from 1 node(s); none reached')" = 1 ]
refute "doctor did not probe from offline nodes" grep -q "fleet-gamma\|fleet-delta" "$SSH_LOG"
assert "doctor checks the live policy" printf '%s' "$out" | grep -q 'policy: live tailnet policy isolates tag:fleet-node'
touch "$T/nc-open"
out=$(bash "$FLEET" doctor 2>&1); rc=$?
assert "doctor FAILs when a node can reach the master" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'ISOLATION FAIL: alpha reached the master'" "$out"
rm -f "$T/nc-open"
# M4: a node without nc cannot be tested, which is a failure, not a pass
touch "$T/nc-missing"
out=$(bash "$FLEET" doctor 2>&1); rc=$?
assert "doctor FAILs when nc is missing on the node (untestable != isolated)" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'ISOLATION FAIL: alpha has no nc'" "$out"
refute "missing nc never yields the all-clear summary" printf '%s' "$out" | grep -q 'none reached'
rm -f "$T/nc-missing"
# second online node → one extra probe to the other node's ssh
write_status ',"k8":{"ID":"'"$DUP_ID"'","HostName":"fleet-dup","DNSName":"fleet-gamma.tail1.ts.net.","TailscaleIPs":["100.64.0.15"],"Online":true,"Tags":["tag:fleet-node"]}'
: >"$SSH_LOG"
out=$(bash "$FLEET" doctor 2>&1)
assert "with two online nodes doctor also probes the other node on 22 (exactly once per node)" bash -c "[ \"\$(grep -c 'nc -z -w 3 100.64.0.15 22$' '$SSH_LOG')\" = 1 ] && [ \"\$(grep -c 'nc -z -w 3 100.64.0.11 22$' '$SSH_LOG')\" = 1 ] && printf '%s' \"\$0\" | grep -q 'isolation: 6 probe(s) from 2 node(s)'" "$out"
write_status ""
chmod 0644 "$FLEET_VAULT/secrets/full.env.age"
refute "doctor fails on loose file mode" bash "$FLEET" doctor
chmod 0600 "$FLEET_VAULT/secrets/full.env.age"
out=$(bash "$FLEET" doctor 2>&1)
assert "doctor reports the vault key reachable and every secret encrypted" bash -c "printf '%s' \"\$0\" | grep -q 'vault key: reachable' && printf '%s' \"\$0\" | grep -q 'vault: every secret is encrypted'" "$out"

# ======================================================================
echo "== expired invite + ephemeral cleanup (tombstone → forget)"
cat >"$FLEET_VAULT/nodes/pending/expired000000000000000000.json" <<'EOF'
{"nonce":"expired000000000000000000","name":"old","profile":"full","ephemeral":false,"created":"2026-01-01T00:00:00Z","expires":"2026-01-01T01:00:00Z","ts_key_id":"k9","user":"fleetuser"}
EOF
cat >"$FLEET_VAULT/nodes/claimed/stale00000000000000000000.nXCNTRL.json" <<'EOF'
{"nonce":"stale00000000000000000000","name":"stale","profile":"full","ephemeral":false,"created":"2026-01-01T00:00:00Z","expires":"2026-01-01T01:00:00Z","ts_key_id":"k8","user":"fleetuser"}
EOF
bash "$FLEET" reconcile >/dev/null 2>&1
refute "expired pending invite removed" [ -f "$FLEET_VAULT/nodes/pending/expired000000000000000000.json" ]
assert "expired invite key revoked" grep -q '^DELETE /api/v2/tailnet/-/keys/k9' "$API_LOG"
assert "stale claimed invite removed + key revoked" bash -c "[ ! -f '$FLEET_VAULT/nodes/claimed/stale00000000000000000000.nXCNTRL.json' ] && grep -q '^DELETE /api/v2/tailnet/-/keys/k8' '$API_LOG'"
assert "unexpired eph invite kept" [ -f "$eph_pending" ]
# enrol the ephemeral node, then make it vanish
eph_nonce=$(jget "$eph_pending" nonce)
mk_node fleet-eph.tail1.ts.net "$eph_nonce"
write_status ',"k4":{"ID":"nEEEECNTRL","HostName":"fleet-eph","DNSName":"fleet-eph.tail1.ts.net.","TailscaleIPs":["100.64.0.14"],"Online":true,"Tags":["tag:fleet-node"]}'
bash "$FLEET" reconcile >/dev/null 2>&1
assert "ephemeral node enrolled" grep -q '"ephemeral": true' "$FLEET_VAULT/nodes/nEEEECNTRL.json"
assert "ephemeral node got minimal profile only" bash -c "grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' '$NODES/fleet-eph.tail1.ts.net/.config/fleet/secrets.env' && ! grep -q '^OPENAI_API_KEY=' '$NODES/fleet-eph.tail1.ts.net/.config/fleet/secrets.env'"
EKD=$(jget "$FLEET_VAULT/nodes/nEEEECNTRL.json" github_keys.code.id); EKC=$(jget "$FLEET_VAULT/nodes/nEEEECNTRL.json" github_keys.config.id); EKM=$(jget "$FLEET_VAULT/nodes/nEEEECNTRL.json" github_keys.memory.id)
write_status ""
echo '[{"nodeId":"nAAAACNTRL"}]' >"$DEVICES_JSON"
bash "$FLEET" reconcile >/dev/null 2>&1
assert "absent ephemeral node gets missing_since, is kept" bash -c "grep -q '\"missing_since\": \"20' '$FLEET_VAULT/nodes/nEEEECNTRL.json' && [ \"\$(jget '$FLEET_VAULT/nodes/nEEEECNTRL.json' state)\" = provisioned ]"
assert "absent non-ephemeral dup node gets missing_since too" grep -q '"missing_since": "20' "$FLEET_VAULT/nodes/$DUP_ID.json"
out=$(FLEET_NOW_EPOCH=$(( $(date +%s) + 1800 )) bash "$FLEET" reconcile 2>&1)
assert "ephemeral node absent 30m: still kept (grace 1h)" [ -f "$FLEET_VAULT/nodes/nEEEECNTRL.json" ]
echo '[{"nodeId":"nAAAACNTRL"},{"nodeId":"nEEEECNTRL"}]' >"$DEVICES_JSON"
bash "$FLEET" reconcile >/dev/null 2>&1
assert "node that reappears gets missing_since cleared" [ -z "$(jget "$FLEET_VAULT/nodes/nEEEECNTRL.json" missing_since)" ]
echo '[{"nodeId":"nAAAACNTRL"}]' >"$DEVICES_JSON"
bash "$FLEET" reconcile >/dev/null 2>&1
out=$(FLEET_NOW_EPOCH=$(( $(date +%s) + 7200 )) bash "$FLEET" reconcile 2>&1)
refute "ephemeral node absent >1h: revoked, cleaned, forgotten" [ -f "$FLEET_VAULT/nodes/nEEEECNTRL.json" ]
assert "forgotten node's deploy keys deleted (code, config, memory)" bash -c "grep -q '^DELETE /repos/example/fleeter/keys/$EKD' '$API_LOG' && grep -q '^DELETE /repos/example/fleet-config/keys/$EKC' '$API_LOG' && grep -q '^DELETE /repos/example/fleet-memory/keys/$EKM' '$API_LOG'"
assert "revoke + forget audited, secrets to rotate named" bash -c "grep -q ' revoke eph gone' '$FLEET_VAULT/audit.log' && grep -q ' forget eph gone' '$FLEET_VAULT/audit.log' && printf '%s' \"\$0\" | grep -q 'rotate the secrets it held: .*CLAUDE_CODE_OAUTH_TOKEN'" "$out"
assert "non-ephemeral dup node (gone 2h < 24h) untouched" [ "$(jget "$FLEET_VAULT/nodes/$DUP_ID.json" state)" = provisioned ]
assert "non-ephemeral alpha untouched" [ "$(jget "$FLEET_VAULT/nodes/nAAAACNTRL.json" state)" = provisioned ]

# ======================================================================
echo "== missing non-ephemeral node: revoked after FLEET_MISSING_GRACE_HOURS, cleanup retried"
DKD=$(jget "$FLEET_VAULT/nodes/$DUP_ID.json" github_keys.code.id); DKC=$(jget "$FLEET_VAULT/nodes/$DUP_ID.json" github_keys.config.id); DKM=$(jget "$FLEET_VAULT/nodes/$DUP_ID.json" github_keys.memory.id)
touch "$DEVICES_JSON.fail-gh-delete"
LATER=$(( $(date +%s) + 25 * 3600 ))
out=$(FLEET_NOW_EPOCH=$LATER bash "$FLEET" reconcile 2>&1); rc=$?
assert "reconcile exits 0 despite failed deletes" [ "$rc" = 0 ]
assert "dup revoked after 24h missing" [ "$(jget "$FLEET_VAULT/nodes/$DUP_ID.json" state)" = revoked ]
assert "registry kept as tombstone with pending_cleanup for all three keys (id + repo slug each)" bash -c "[ \"\$(jget '$FLEET_VAULT/nodes/$DUP_ID.json' pending_cleanup)\" = '[\"gh:code:$DKD:example/fleeter\", \"gh:config:$DKC:example/fleet-config\", \"gh:memory:$DKM:example/fleet-memory\"]' ]"
assert "failed deletes were attempted" grep -q "^DELETE /repos/example/fleet-config/keys/$DKC" "$API_LOG"
assert "cleanup failure audited" grep -q " cleanup dup gh:config:$DKC:example/fleet-config fail" "$FLEET_VAULT/audit.log"
assert "doctor reports pending cleanup" bash -c "bash '$FLEET' doctor 2>&1 | grep -q 'still has cleanup pending: gh:code:$DKD:example/fleeter gh:config:$DKC:example/fleet-config gh:memory:$DKM:example/fleet-memory'"
out=$(bash "$FLEET" nodes 2>&1)
assert "nodes shows the tombstone as revoked cleanup-pending" printf '%s\n' "$out" | grep -Eq "^dup +$DUP_ID +no +revoked .*cleanup-pending"
n_del=$(grep -c "^DELETE /repos/example/fleet-memory/keys/$DKM" "$API_LOG")
FLEET_NOW_EPOCH=$LATER bash "$FLEET" reconcile >/dev/null 2>&1
assert "still failing: retried again, tombstone kept" bash -c "[ \"\$(grep -c '^DELETE /repos/example/fleet-memory/keys/$DKM' '$API_LOG')\" = $((n_del + 1)) ] && [ -f '$FLEET_VAULT/nodes/$DUP_ID.json' ]"
rm -f "$DEVICES_JSON.fail-gh-delete"
FLEET_NOW_EPOCH=$LATER bash "$FLEET" reconcile >/dev/null 2>&1
refute "deletes succeed: cleanup done, tombstone forgotten" [ -f "$FLEET_VAULT/nodes/$DUP_ID.json" ]
assert "cleanup success + forget audited" bash -c "grep -q ' cleanup dup gh:memory:$DKM:example/fleet-memory ok' '$FLEET_VAULT/audit.log' && grep -q ' forget dup gone' '$FLEET_VAULT/audit.log'"

# ======================================================================
echo "== kick during a running provision (slow ssh on the secrets step); repo URL changed since enrolment; remote stop fails"
rm -f "$NH/.config/fleet/secrets.env"
touch "$T/slow-secrets"
# the config repo moved after alpha enrolled: its key must be deleted on the repo it was created on
printf "FLEET_CONFIG_REPO='git@github.com:moved/fleet-config.git'\n" >>"$FLEET_HOME/fleet.conf"
touch "$T/leave-fail"
: >"$SSH_LOG"
bash "$FLEET" provision alpha >"$T/prov.log" 2>&1 &
PROV_PID=$!
assert "provision reached the secrets step and holds the lock" wait_for 20 bash -c "grep -q 'secrets.env.tmp' '$SSH_LOG' && [ -s '$FLEET_VAULT/locks/nAAAACNTRL/pid' ]"
wpid=$(cat "$FLEET_VAULT/locks/nAAAACNTRL/pid" 2>/dev/null)
assert "lock records the worker, not the cli process" bash -c "[ -n '$wpid' ] && [ '$wpid' != '$PROV_PID' ] && kill -0 '$wpid'"
out=$(bash "$FLEET" kick alpha --yes </dev/null 2>&1); rc=$?
assert "kick exits 0" [ "$rc" = 0 ]
wait "$PROV_PID" 2>/dev/null; prc=$?; PROV_PID=""
rm -f "$T/slow-secrets"
assert "in-flight provision was killed (non-zero exit)" [ "$prc" != 0 ]
refute "worker and its ssh child are gone" kill -0 "$wpid"
refute "no secrets.env written after kick" [ -f "$NH/.config/fleet/secrets.env" ]
refute "provision never reached apply" grep -q 'fleet apply' "$SSH_LOG"
assert "registry marked revoked" [ "$(jget "$FLEET_VAULT/nodes/nAAAACNTRL.json" state)" = revoked ]
refute "kick released the lock" [ -d "$FLEET_VAULT/locks/nAAAACNTRL" ]
assert "kick ran remote fleet leave" grep -q 'fleetuser@fleet-alpha.tail1.ts.net ~/.local/bin/fleet leave' "$SSH_LOG"
refute "node did not stop (leave failed)" [ -f "$NH/.fleet-left" ]
assert "kick deleted tailscale device" grep -q '^DELETE /api/v2/device/nAAAACNTRL' "$API_LOG"
assert "kick deleted code deploy key" grep -q '^DELETE /repos/example/fleeter/keys/1$' "$API_LOG"
assert "kick deleted the config deploy key on the repo recorded at enrolment, not the current URL" bash -c "grep -q '^DELETE /repos/example/fleet-config/keys/2$' '$API_LOG' && ! grep -q '/repos/moved/' '$API_LOG'"
assert "kick deleted memory deploy key" grep -q '^DELETE /repos/example/fleet-memory/keys/3$' "$API_LOG"
assert "failed remote stop is queued as stop:<id> in pending_cleanup" [ "$(jget "$FLEET_VAULT/nodes/nAAAACNTRL.json" pending_cleanup)" = '["stop:nAAAACNTRL"]' ]
assert "kick lists secrets to rotate" printf '%s' "$out" | grep -q 'Rotate these secrets.*CLAUDE_CODE_OAUTH_TOKEN'
assert "kick reports each step" bash -c "printf '%s' \"\$0\" | grep -q 'tailscale device delete: ok' && printf '%s' \"\$0\" | grep -q 'remote stop: FAILED' && printf '%s' \"\$0\" | grep -q 'pending cleanup (retried by every reconcile): stop:nAAAACNTRL'" "$out"
assert "audit log records kick with stop=fail" grep -q ' kick alpha done stop=fail ts=ok gh=ok' "$FLEET_VAULT/audit.log"
grep -v '^FLEET_CONFIG_REPO=' "$FLEET_HOME/fleet.conf" >"$T/lc"; cat "$T/lc" >"$FLEET_HOME/fleet.conf"
refute "provision refuses revoked node" bash "$FLEET" provision alpha
refute "kick without matching confirmation aborts" bash -c "printf 'wrong\n' | bash '$FLEET' kick alpha"
# the node is still online and now answers: reconcile retries the stop
: >"$SSH_LOG"
bash "$FLEET" reconcile >/dev/null 2>&1
assert "stop still failing: retried, kept" bash -c "grep -q 'fleet leave' '$SSH_LOG' && [ \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' pending_cleanup)\" = '[\"stop:nAAAACNTRL\"]' ]"
rm -f "$T/leave-fail"
bash "$FLEET" reconcile >/dev/null 2>&1
assert "reconcile retried the remote stop: node received leave, cleanup empty, audited" bash -c "[ -f '$NH/.fleet-left' ] && [ \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' pending_cleanup)\" = '[]' ] && grep -q ' cleanup alpha stop:nAAAACNTRL ok' '$FLEET_VAULT/audit.log'"
: >"$SSH_LOG"
bash "$FLEET" reconcile >/dev/null 2>&1
refute "reconcile skips revoked node" grep -q 'fleet-alpha' "$SSH_LOG"
assert "registry stays revoked after reconcile" [ "$(jget "$FLEET_VAULT/nodes/nAAAACNTRL.json" state)" = revoked ]
refute "still no secrets.env on the node" [ -f "$NH/.config/fleet/secrets.env" ]
# kick with a failing GitHub: items stay in pending_cleanup, reconcile retries them
touch "$DEVICES_JSON.fail-gh-delete"
out=$(bash "$FLEET" kick nAAAACNTRL --yes </dev/null 2>&1); rc=$?
assert "kick --yes needs no confirmation and exits 0 even when a delete fails" [ "$rc" = 0 ]
assert "kick records failed deletes as pending cleanup" bash -c "[ \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' pending_cleanup)\" = '[\"gh:code:1:example/fleeter\", \"gh:config:2:example/fleet-config\", \"gh:memory:3:example/fleet-memory\"]' ] && grep -q ' kick alpha done stop=ok ts=ok gh=fail' '$FLEET_VAULT/audit.log'"
assert "kick says what is pending" printf '%s' "$out" | grep -q 'pending cleanup (retried by every reconcile): gh:code:1:example/fleeter gh:config:2:example/fleet-config gh:memory:3:example/fleet-memory'
rm -f "$DEVICES_JSON.fail-gh-delete"
# M5: the cleanup retry must not depend on the device list API
touch "$DEVICES_JSON.fail-devices"
n_dev=$(grep -c '^GET /api/v2/tailnet/-/devices' "$API_LOG")
out=$(bash "$FLEET" reconcile 2>&1); rc=$?
assert "reconcile exits 0 when the device list API answers 500" bash -c "[ $rc = 0 ] && [ \"\$(grep -c '^GET /api/v2/tailnet/-/devices' '$API_LOG')\" -gt $n_dev ] && printf '%s' \"\$0\" | grep -q 'could not list tailnet devices'" "$out"
assert "device list API 500: pending cleanup still retried and cleared" [ "$(jget "$FLEET_VAULT/nodes/nAAAACNTRL.json" pending_cleanup)" = '[]' ]
rm -f "$DEVICES_JSON.fail-devices"
bash "$FLEET" reconcile >/dev/null 2>&1
assert "kicked tombstone kept while the device is still listed" [ -f "$FLEET_VAULT/nodes/nAAAACNTRL.json" ]
# a pending stop is dropped (not retried forever) once the device has left the tailnet
touch "$T/leave-fail"
bash "$FLEET" kick nAAAACNTRL --yes </dev/null >/dev/null 2>&1
assert "stop queued again" [ "$(jget "$FLEET_VAULT/nodes/nAAAACNTRL.json" pending_cleanup)" = '["stop:nAAAACNTRL"]' ]
echo '[{"nodeId":"nEEEECNTRL"}]' >"$DEVICES_JSON"
bash "$FLEET" reconcile >/dev/null 2>&1
assert "device gone from the API list: stop dropped and audited" bash -c "[ \"\$(jget '$FLEET_VAULT/nodes/nAAAACNTRL.json' pending_cleanup)\" = '[]' ] && grep -q ' cleanup alpha stop:nAAAACNTRL dropped (device gone)' '$FLEET_VAULT/audit.log'"
rm -f "$T/leave-fail"
echo '[{"nodeId":"nAAAACNTRL"}]' >"$DEVICES_JSON"
bash "$FLEET" reconcile >/dev/null 2>&1

# ======================================================================
echo "== FLEET_CONFIG_DIR from the environment beats the recorded value"
mkdir -p "$T/env-cfg"
assert "env FLEET_CONFIG_DIR wins over ~/.config/fleet/fleet.conf" bash -c "[ \"\$(FLEET_CONFIG_DIR='$T/env-cfg' FLEET_ROOT='$ROOT' bash -c '. \"\$FLEET_ROOT/lib/common.sh\"; fleet_load_config; printf %s \"\$FLEET_CONFIG_DIR\"')\" = '$T/env-cfg' ]"
assert "without the env var the recorded dir is used" bash -c "[ \"\$(FLEET_ROOT='$ROOT' bash -c 'unset FLEET_CONFIG_DIR; . \"\$FLEET_ROOT/lib/common.sh\"; fleet_load_config; printf %s \"\$FLEET_CONFIG_DIR\"')\" = '$CFG' ]"

# ======================================================================
echo "== M1: registry read-modify-write is serialised by the registry lock (missing_since vs kick)"
cat >"$FLEET_VAULT/nodes/nM1CNTRL.json" <<'EOF'
{"id":"nM1CNTRL","name":"m1","hostname":"fleet-m1","dnsname":"fleet-m1.tail1.ts.net","user":"fleetuser","os":"linux","arch":"amd64","container":true,"profile":"minimal","ephemeral":false,"state":"provisioned","enrolled":"2026-10-03T09:00:00Z","provisioned":"2026-10-03T09:01:00Z","provisioned_digest":"x","missing_since":"","pending_cleanup":[],"github_keys":{"config":501,"memory":502},"secrets_sent":["CLAUDE_CODE_OAUTH_TOKEN"],"files_sent":[]}
EOF
chmod 0600 "$FLEET_VAULT/nodes/nM1CNTRL.json"
RL="$FLEET_VAULT/locks/.registry"
mkdir -p "$RL"; echo $$ >"$RL/pid"; echo testheld >"$RL/token"     # this script holds the registry lock
FLEET_ROOT=$ROOT bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/master.sh"; registry_set "$1" missing_since "$2"' _ nM1CNTRL 2026-10-03T12:00:00Z 2>/dev/null &
W1=$!
bash "$FLEET" kick m1 --yes </dev/null >"$T/kick-m1.log" 2>&1 &
W2=$!
sleep 3
assert "registry write waits while the registry lock is held" [ -z "$(jget "$FLEET_VAULT/nodes/nM1CNTRL.json" missing_since)" ]
assert "kick (holding the node lock) waits for the registry lock too" [ "$(jget "$FLEET_VAULT/nodes/nM1CNTRL.json" state)" = provisioned ]
rm -rf "$RL"
wait "$W1" 2>/dev/null; wait "$W2" 2>/dev/null
assert "after release: revoked survives the concurrent missing_since write" bash -c "[ \"\$(jget '$FLEET_VAULT/nodes/nM1CNTRL.json' state)\" = revoked ] && [ \"\$(jget '$FLEET_VAULT/nodes/nM1CNTRL.json' missing_since)\" = 2026-10-03T12:00:00Z ]"
refute "registry lock released afterwards" [ -d "$RL" ]
# legacy registry entry (plain int key ids, no repo slug): still revoked and deleted against the current repo URLs
assert "legacy int github_keys: deletes went to the configured repos; only the unreachable node's stop and t3 revoke stay pending" bash -c "grep -q '^DELETE /repos/example/fleet-config/keys/501' '$API_LOG' && grep -q '^DELETE /repos/example/fleet-memory/keys/502' '$API_LOG' && [ \"\$(jget '$FLEET_VAULT/nodes/nM1CNTRL.json' pending_cleanup)\" = '[\"stop:nM1CNTRL\", \"t3:nM1CNTRL\"]' ]"
assert "legacy entry: audit shows the slug-less items" grep -q ' cleanup m1 gh:config:501 ok' "$FLEET_VAULT/audit.log"
rm -f "$FLEET_VAULT/nodes/nM1CNTRL.json"

# ======================================================================
echo "== M2: lock_break takes a lock over in place and never deletes a re-taken one"
L2="$T/lock-m2"
cat >"$T/holder.sh" <<'EOF'
# holder that, when killed, is replaced by another owner (new pid + token) before lock_break looks again
L=$1
trap 'rm -rf "$L"; mkdir "$L"; echo 99999 >"$L/pid"; echo replacement >"$L/token"; exit 0' TERM
while :; do sleep 1; done
EOF
mkdir -p "$L2"
bash "$T/holder.sh" "$L2" &
HPID=$!
echo "$HPID" >"$L2/pid"; echo original >"$L2/token"
rc2=0; bash -c ". '$ROOT/lib/common.sh'; lock_break '$L2'" >/dev/null 2>&1 || rc2=$?
assert "lock_break returns 1 when the token changed under it" [ "$rc2" = 1 ]
assert "the replacement owner's lock is untouched" bash -c "[ -d '$L2' ] && [ \"\$(cat '$L2/token')\" = replacement ] && [ \"\$(cat '$L2/pid')\" = 99999 ]"
refute "the original holder was killed" kill -0 "$HPID"
rm -rf "$L2"; mkdir -p "$L2"
sleep 60 &
HPID=$!
echo "$HPID" >"$L2/pid"; echo original >"$L2/token"
out=$(bash -c ". '$ROOT/lib/common.sh'; lock_break '$L2' && echo \"owned \$\$\"" 2>/dev/null)
assert "lock_break kills the holder and takes the lock over in place (own pid, new token)" bash -c "[ \"\$0\" = \"owned \$(cat '$L2/pid')\" ] && [ \"\$(cat '$L2/token')\" != original ] && [ -d '$L2' ]" "$out"
refute "plain holder was killed" kill -0 "$HPID"
rm -rf "$L2"
refute "lock_break on a missing lock returns 1 (caller acquires instead)" bash -c ". '$ROOT/lib/common.sh'; lock_break '$L2'"

# ======================================================================
echo "== vault encrypt: migration of a plaintext vault (values identical, plaintext gone, digest.key removed, idempotent); api.py on both"
HOMEM="$T/master-plain"; VM="$HOMEM/.config/fleet/vault"
mkdir -p "$HOMEM/.config/fleet"; chmod 0700 "$HOMEM/.config/fleet"
mk_plain_vault "$VM"
mfleet() { HOME="$HOMEM" FLEET_HOME="$HOMEM/.config/fleet" FLEET_VAULT="$VM" bash "$FLEET" "$@"; }
mvcat() { HOME="$HOMEM" FLEET_HOME="$HOMEM/.config/fleet" FLEET_VAULT="$VM" vcat "$1"; }
mdigest() { HOME="$HOMEM" FLEET_HOME="$HOMEM/.config/fleet" FLEET_VAULT="$VM" digest_of "$1"; }
mapi() { FLEET_HOME="$HOMEM/.config/fleet" FLEET_VAULT="$VM" python3 "$ROOT/lib/api.py" "$@"; }
plain_sum=$( (cd "$VM" && cat secrets/minimal.env secrets/full.env files/full/projects/app/.env tailscale.json github.json) | sha256)
out=$(mfleet vault status 2>&1); rc=$?
assert "status on a plaintext vault: exit 0, no recipient, the 5 plaintext files listed, legacy digest.key" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q '^recipient:  none' && printf '%s' \"\$0\" | grep -q '^plaintext:  5 file(s): files/full/projects/app/.env github.json secrets/full.env secrets/minimal.env tailscale.json' && printf '%s' \"\$0\" | grep -q '^digest.key: present'" "$out"
out=$(mfleet secrets list 2>&1)
assert "a plaintext vault is still read (secrets list)" printf '%s' "$out" | grep -Eq '^OPENAI_API_KEY +full'
dm0=$(mdigest full)
assert "the digest of a plaintext vault is computed (legacy HMAC with digest.key)" printf '%s' "$dm0" | grep -Eqx '[0-9a-f]{64}'
out=$(printf 'x\n' | mfleet secrets set NEW_ONE 2>&1); rc=$?
assert "writers refuse on a vault that is not encrypted yet and point at fleet vault encrypt" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'not encrypted yet' && printf '%s' \"\$0\" | grep -q 'fleet vault encrypt' && ! grep -q NEW_ONE '$VM/secrets/full.env'" "$out"
assert "api.py reads the plaintext tailscale.json (legacy vault)" [ "$(mapi ts check)" = ok ]
out=$(mfleet doctor 2>&1)
assert "doctor on a plaintext vault warns: not encrypted at rest, run fleet vault encrypt" printf '%s' "$out" | grep -q 'vault: not encrypted at rest.*fleet vault encrypt'
out=$(mfleet vault encrypt 2>&1); rc=$?
assert "vault encrypt exits 0: creates the key, encrypts 5 files, removes digest.key" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'vault key: file' && printf '%s' \"\$0\" | grep -q 'vault: 5 file(s) encrypted' && printf '%s' \"\$0\" | grep -q 'digest.key removed' && [ ! -e '$VM/digest.key' ]" "$out"
assert "plaintext gone, ciphertexts present (0600), recipient 0644" bash -c "cd '$VM' && [ ! -e secrets/minimal.env ] && [ ! -e secrets/full.env ] && [ ! -e files/full/projects/app/.env ] && [ ! -e tailscale.json ] && [ ! -e github.json ] && [ -f secrets/minimal.env.age ] && [ -f secrets/full.env.age ] && [ -f files/full/projects/app/.env.age ] && [ -f tailscale.json.age ] && [ -f github.json.age ] && [ \"\$(mode_of secrets/full.env.age)\" = 600 ] && [ \"\$(mode_of recipient.txt)\" = 644 ]"
assert "values identical byte for byte after the migration" [ "$( (mvcat "$VM/secrets/minimal.env.age"; mvcat "$VM/secrets/full.env.age"; mvcat "$VM/files/full/projects/app/.env.age"; mvcat "$VM/tailscale.json.age"; mvcat "$VM/github.json.age") | sha256)" = "$plain_sum" ]
refute "no plaintext value remains anywhere under the migrated master's home" grep -rq -e plain-oauth-FAKE -e plain-openai-FAKE -e plain-db-FAKE -e tskey-client -e ghtok "$HOMEM"
out=$(mfleet secrets list 2>&1)
assert "secrets list on the migrated vault (quoted value survived)" printf '%s' "$out" | grep -Eq '^QUOTED +full'
assert "api.py reads the encrypted tailscale.json and github.json through vault_cat (token exchange, gh user)" bash -c "[ \"\$(FLEET_HOME='$HOMEM/.config/fleet' FLEET_VAULT='$VM' python3 '$ROOT/lib/api.py' ts check)\" = ok ] && [ \"\$(FLEET_HOME='$HOMEM/.config/fleet' FLEET_VAULT='$VM' python3 '$ROOT/lib/api.py' gh user)\" = example ]"
dm1=$(mdigest full)
mv "$HOMEM/.config/fleet/vault.key" "$T/vk.away"
assert "the migrated digest differs from the legacy one and needs no key" bash -c "[ '$dm1' != '$dm0' ] && [ \"\$0\" = '$dm1' ]" "$(mdigest full)"
out=$(mfleet vault encrypt 2>&1); rc=$?
assert "vault encrypt refuses when the key backend is unreachable" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'unreachable'" "$out"
out=$(mapi ts check 2>&1); rc=$?
assert "api.py fails loudly (no silent fallback) when the key is unreachable" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'cannot decrypt'" "$out"
mv "$T/vk.away" "$HOMEM/.config/fleet/vault.key"
out=$(mfleet vault encrypt 2>&1); rc=$?
assert "vault encrypt is idempotent" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'nothing to encrypt'" "$out"
assert "audit records the migration" grep -q ' vault.encrypt - ok 5' "$VM/audit.log"
# a plaintext left next to its ciphertext: identical -> dropped; different -> refused, nothing changed
mvcat "$VM/secrets/minimal.env.age" >"$VM/secrets/minimal.env"
out=$(mfleet vault encrypt 2>&1); rc=$?
assert "an identical plaintext copy next to the ciphertext is removed" bash -c "[ $rc = 0 ] && [ ! -e '$VM/secrets/minimal.env' ]"
printf "CLAUDE_CODE_OAUTH_TOKEN='other-FAKE'\n" >"$VM/secrets/minimal.env"; chmod 0600 "$VM/secrets/minimal.env"; msum=$(sha256 <"$VM/secrets/minimal.env.age")
out=$(mfleet vault encrypt 2>&1); rc=$?
assert "a differing plaintext next to the ciphertext is refused with both options named; neither file touched" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'both exist and differ' && [ -f '$VM/secrets/minimal.env' ] && [ \"\$(sha256 <'$VM/secrets/minimal.env.age')\" = '$msum' ]" "$out"
rm -f "$VM/secrets/minimal.env"

# ======================================================================
echo "== key backend keychain (fake security): identity on stdin only, never argv; -w reads; locked keychain"
SEC="$T/secbin"; mkdir -p "$SEC" "$T/secstate" "$T/ststate"
export SEC_ARGV="$T/security.argv" SEC_STDIN="$T/security.stdin" SEC_STATE="$T/secstate" SEC_LOCKED="$T/keychain-locked"
export ST_ARGV="$T/secret-tool.argv" ST_STDIN="$T/secret-tool.stdin" ST_STATE="$T/ststate"
ACC=${USER:-$(id -un)}
# fake macOS `security`: argv and stdin recorded separately; items in $SEC_STATE/<service>.<account>
cat >"$SEC/security" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SEC_ARGV"
svc=""; acc=""; pw=""; w=0
parse() { while [ $# -gt 0 ]; do case "$1" in -s) svc=$2; shift ;; -a) acc=$2; shift ;; -w) if [ $# -gt 1 ]; then pw=$2; shift; else w=1; fi ;; esac; shift; done; }
case "$1" in
  -i)
    while IFS= read -r line; do
      printf '%s\n' "$line" >>"$SEC_STDIN"
      # shellcheck disable=SC2086
      set -- $line
      [ "$1" = add-generic-password ] || { echo "fake security: unsupported: $line" >&2; exit 1; }
      shift; parse "$@"
      printf '%s' "$pw" >"$SEC_STATE/$svc.$acc"
    done ;;
  find-generic-password)
    shift; parse "$@"
    [ -f "$SEC_LOCKED" ] && { echo "security: SecKeychainSearchCopyNext: User interaction is not allowed." >&2; exit 36; }
    [ -f "$SEC_STATE/$svc.$acc" ] || { echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44; }
    [ "$w" = 1 ] && { cat "$SEC_STATE/$svc.$acc"; echo; } ;;
  delete-generic-password)
    shift; parse "$@"; rm -f "$SEC_STATE/$svc.$acc" ;;
  *) echo "fake security: unsupported: $*" >&2; exit 2 ;;
esac
EOF
# fake `secret-tool`: store reads the secret from stdin; lookup prints it without a newline
cat >"$SEC/secret-tool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ST_ARGV"
cmd=$1; shift; attrs=""
case "$cmd" in
  store)  while [ $# -gt 0 ]; do case "$1" in --label=*) ;; *) attrs="$attrs.$1" ;; esac; shift; done
          IFS= read -r pw || true; printf '%s\n' "$pw" >>"$ST_STDIN"; printf '%s' "$pw" >"$ST_STATE/$attrs" ;;
  lookup) while [ $# -gt 0 ]; do attrs="$attrs.$1"; shift; done; [ -f "$ST_STATE/$attrs" ] || exit 1; cat "$ST_STATE/$attrs" ;;
  clear)  while [ $# -gt 0 ]; do attrs="$attrs.$1"; shift; done; rm -f "$ST_STATE/$attrs" ;;
  *) echo "fake secret-tool: unsupported: $cmd $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$SEC/security" "$SEC/secret-tool"
HOMEK="$T/master-keychain"; VK="$HOMEK/.config/fleet/vault"; mkdir -p "$HOMEK/.config/fleet"
mk_plain_vault "$VK"
kfleet() { PATH="$SEC:$PATH" FLEET_VAULT_KEY_BACKEND=keychain HOME="$HOMEK" FLEET_HOME="$HOMEK/.config/fleet" FLEET_VAULT="$VK" bash "$FLEET" "$@"; }
out=$(kfleet vault encrypt 2>&1); rc=$?
assert "keychain backend: vault encrypt exits 0; key stored under service fleet-vault for this user; no key file; recipient records the backend" bash -c "[ $rc = 0 ] && grep -q '^AGE-SECRET-KEY-1' '$SEC_STATE/fleet-vault.$ACC' && [ ! -e '$HOMEK/.config/fleet/vault.key' ] && grep -q '^# fleet vault: backend=keychain account=$ACC' '$VK/recipient.txt' && printf '%s' \"\$0\" | grep -q 'vault key: keychain (login keychain, service fleet-vault, account $ACC)'" "$out"
assert "the identity reached security on stdin (-i add-generic-password -U -s fleet-vault -a USER -w ...), never in argv" bash -c "grep -q '^add-generic-password -U -s fleet-vault -a $ACC -w AGE-SECRET-KEY-1' '$SEC_STDIN' && grep -qx -- '-i' '$SEC_ARGV' && ! grep -q 'AGE-SECRET-KEY' '$SEC_ARGV'"
assert "reads use find-generic-password -s fleet-vault -a USER -w (stdout)" grep -qx -- "find-generic-password -s fleet-vault -a $ACC -w" "$SEC_ARGV"
printf 'kc-value-FAKE\n' | kfleet secrets set KC_SECRET --profile minimal >/dev/null 2>&1
out=$(kfleet secrets list 2>&1)
assert "secrets set + list work through the keychain" printf '%s' "$out" | grep -Eq '^KC_SECRET +minimal'
refute "the value is nowhere on disk under that home" grep -rq 'kc-value-FAKE' "$HOMEK"
out=$(kfleet vault rotate-key 2>&1); rc=$?
assert "rotate-key through the keychain: exit 0; incoming key went in as fleet-vault-next (stdin) and was deleted afterwards; argv still clean" bash -c "[ $rc = 0 ] && [ ! -e '$SEC_STATE/fleet-vault-next.$ACC' ] && grep -q '^add-generic-password -U -s fleet-vault-next -a $ACC -w AGE-SECRET-KEY-1' '$SEC_STDIN' && grep -qx -- 'delete-generic-password -s fleet-vault-next -a $ACC' '$SEC_ARGV' && ! grep -q 'AGE-SECRET-KEY' '$SEC_ARGV'"
out=$(kfleet secrets list 2>&1)
assert "secrets readable after the keychain rotation" printf '%s' "$out" | grep -Eq '^KC_SECRET +minimal'
touch "$SEC_LOCKED"
out=$(kfleet secrets list 2>&1); rc=$?
assert "locked keychain: secrets list dies with the unlock hint" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'unlock the login keychain'" "$out"
out=$(kfleet vault status 2>&1)
assert "locked keychain: vault status names the keychain and says UNREACHABLE" bash -c "printf '%s' \"\$0\" | grep -q '^backend:    keychain (login keychain, service fleet-vault, account $ACC)' && printf '%s' \"\$0\" | grep -q '^key:        UNREACHABLE'" "$out"
rm -f "$SEC_LOCKED"
out=$(kfleet vault status 2>&1)
assert "unlocked again: key reachable" printf '%s' "$out" | grep -q '^key:        reachable'
assert "a recipient created under another backend is flagged by vault status" bash -c "HOME='$HOMEK' FLEET_HOME='$HOMEK/.config/fleet' FLEET_VAULT='$VK' bash '$FLEET' vault status 2>&1 | grep -q 'WARNING: the key was created with backend keychain'"

# ======================================================================
echo "== key backend secret-tool (fake): identity on stdin only; backend auto-detection"
HOMES="$T/master-secret-tool"; VS="$HOMES/.config/fleet/vault"; mkdir -p "$HOMES/.config/fleet"
mk_plain_vault "$VS"
sfleet() { PATH="$SEC:$PATH" FLEET_VAULT_KEY_BACKEND=secret-tool HOME="$HOMES" FLEET_HOME="$HOMES/.config/fleet" FLEET_VAULT="$VS" bash "$FLEET" "$@"; }
out=$(sfleet vault encrypt 2>&1); rc=$?
assert "secret-tool backend: vault encrypt exits 0; store with label + attributes, identity on stdin only; lookup by attributes; no key file" bash -c "[ $rc = 0 ] && grep -qx -- 'store --label=fleet-vault service fleet-vault account $ACC' '$ST_ARGV' && grep -q '^AGE-SECRET-KEY-1' '$ST_STDIN' && ! grep -q 'AGE-SECRET-KEY' '$ST_ARGV' && grep -qx -- 'lookup service fleet-vault account $ACC' '$ST_ARGV' && [ ! -e '$HOMES/.config/fleet/vault.key' ]"
out=$(sfleet secrets list 2>&1)
assert "secrets list works through secret-tool" printf '%s' "$out" | grep -Eq '^OPENAI_API_KEY +full'
# shellcheck disable=SC2016  # the sourcing happens in the child shell
backend_of() { env -u FLEET_VAULT_KEY_BACKEND PATH="$1" FLEET_ROOT="$ROOT" bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/vault.sh"; vault_backend'; }
plain_want="file"; PATH=/usr/bin:/bin command -v secret-tool >/dev/null 2>&1 && plain_want="secret-tool"
case "$(uname -s)" in
  Darwin) assert "unset backend on macOS: keychain" bash -c "[ \"\$0\" = keychain ] && [ \"\$1\" = keychain ]" "$(backend_of "$SEC:/usr/bin:/bin")" "$(backend_of /usr/bin:/bin)" ;;
  *)      assert "unset backend on Linux: secret-tool when installed, else file" bash -c "[ \"\$0\" = secret-tool ] && [ \"\$1\" = $plain_want ]" "$(backend_of "$SEC:/usr/bin:/bin")" "$(backend_of /usr/bin:/bin)" ;;
esac
refute "an unknown backend name is rejected" bash -c "FLEET_VAULT_KEY_BACKEND=vaultx FLEET_ROOT='$ROOT' bash -c '. \"\$FLEET_ROOT/lib/common.sh\"; fleet_load_config; . \"\$FLEET_ROOT/lib/vault.sh\"; vault_backend'"

# ======================================================================
echo "== GitHub CLI path (gh on PATH, no FLEET_GH_API): login, repo check, deploy keys via gh api; https code repo -> no code key"
HOME2="$T/master2"; mkdir -p "$HOME2/.config/fleet"
printf "FLEET_CODE_REPO='https://github.com/example/fleeter.git'\n" >"$HOME2/.config/fleet/fleet.conf"
gh_fleet() { env PATH="$T/ghbin:$PATH" FLEET_GH_API= HOME="$HOME2" FLEET_HOME="$HOME2/.config/fleet" FLEET_VAULT="$HOME2/.config/fleet/vault" FLEET_TS_STATUS_JSON="$T/status2.json" bash "$FLEET" "$@"; }
write_status '' "$T/status2.json"          # this master's tailscale view (the preflight wants it logged in)
touch "$GH_STATE/missing-example_fleet-memory"
out=$(printf 'tskey-api-kboot5-FAKE\ny\n' | gh_fleet init master --config-dir "$CFG" 2>&1); rc=$?
assert "init master (gh path) exits 0" [ "$rc" = 0 ]
assert "gh auth status checked, then web login (one browser approval)" bash -c "grep -q '^auth status -h github.com$' '$GH_LOG' && grep -q '^auth login -h github.com --web --git-protocol ssh$' '$GH_LOG'"
assert "config + memory repos checked with gh repo view, public https code repo not" bash -c "grep -q '^repo view example/fleet-config$' '$GH_LOG' && grep -q '^repo view example/fleet-memory$' '$GH_LOG' && ! grep -q 'repo view example/fleeter' '$GH_LOG'"
assert "missing repo created private after confirmation" grep -q '^repo create example/fleet-memory --private$' "$GH_LOG"
refute "no vault/github.json on the gh path" [ -f "$HOME2/.config/fleet/vault/github.json" ]
assert "init reports gh login" printf '%s' "$out" | grep -q 'github: gh logged in as example'
: >"$GH_LOG"
out=$(printf 'tskey-api-kboot6-FAKE\n' | gh_fleet init master --reconfigure 2>&1); rc=$?
assert "reconfigure with gh logged in: no login, no repo create" bash -c "[ $rc = 0 ] && ! grep -q '^auth login' '$GH_LOG' && ! grep -q '^repo create' '$GH_LOG'"
gh_fleet invite --name ghnode >/dev/null 2>&1
gh_pending=$(grep -l '"name": "ghnode"' "$HOME2"/.config/fleet/vault/nodes/pending/*.json)
mk_node fleet-ghnode.tail1.ts.net "$(jget "$gh_pending" nonce)"
write_status ',"k9":{"ID":"nGHCNTRL","HostName":"fleet-ghnode","DNSName":"fleet-ghnode.tail1.ts.net.","TailscaleIPs":["100.64.0.19"],"Online":true,"Tags":["tag:fleet-node"]}' "$T/status2.json"
: >"$GH_LOG"
gh_fleet reconcile >/dev/null 2>&1
assert "deploy keys created through gh api (stdin key, typed read_only)" bash -c "grep -q '^api -X POST repos/example/fleet-config/keys -f title=fleet-ghnode-nGHCNTRL -F read_only=true -F key=@- --jq .id$' '$GH_LOG' && grep -q '^api -X POST repos/example/fleet-memory/keys -f title=fleet-ghnode-nGHCNTRL -F read_only=false -F key=@- --jq .id$' '$GH_LOG'"
assert "registry stores the ids gh returned; no code key for the https repo" bash -c "[ \"\$(jget '$HOME2/.config/fleet/vault/nodes/nGHCNTRL.json' github_keys.config.id)\" = 101 ] && [ \"\$(jget '$HOME2/.config/fleet/vault/nodes/nGHCNTRL.json' github_keys.memory.id)\" = 102 ] && [ \"\$(jget '$HOME2/.config/fleet/vault/nodes/nGHCNTRL.json' github_keys.code)\" = null ]"
refute "https code repo: no deploy key registered on it" grep -q 'repos/example/fleeter/keys' "$GH_LOG"
refute "no token-based GitHub call on the gh path" grep -q '^POST /repos/example/fleet-config/keys .*fleet-ghnode' "$API_LOG"
touch "$GH_STATE/fail-delete"
gh_fleet kick ghnode --yes </dev/null >/dev/null 2>&1
assert "kick deletes via gh api; failure kept for retry" bash -c "grep -q '^api -X DELETE repos/example/fleet-config/keys/101$' '$GH_LOG' && [ \"\$(jget '$HOME2/.config/fleet/vault/nodes/nGHCNTRL.json' pending_cleanup)\" = '[\"gh:config:101:example/fleet-config\", \"gh:memory:102:example/fleet-memory\"]' ]"
rm -f "$GH_STATE/fail-delete"
gh_fleet reconcile >/dev/null 2>&1
assert "reconcile retries gh deletes until clean" [ "$(jget "$HOME2/.config/fleet/vault/nodes/nGHCNTRL.json" pending_cleanup)" = '[]' ]

# ======================================================================
echo "== optional memory repo + T3 remote access off (defaults): init, enrol, provision, kick, doctor without either"
HOME3="$T/master3"; mkdir -p "$HOME3/.config/fleet"
printf "FLEET_MEMORY_REPO=''\nFLEET_T3_REMOTE=0\n" >"$HOME3/.config/fleet/fleet.conf"
m3() { HOME="$HOME3" FLEET_HOME="$HOME3/.config/fleet" FLEET_VAULT="$HOME3/.config/fleet/vault" FLEET_TS_STATUS_JSON="$T/status3.json" bash "$FLEET" "$@"; }
V3="$HOME3/.config/fleet/vault"
write_status '' "$T/status3.json"
cp "$T/acl.template.bak" "$ACL"          # live policy already isolates the tag: init asks for no `apply`
out=$(printf 'tskey-api-kboot7-FAKE\nghtok\n' | m3 init master --config-dir "$CFG" 2>&1); rc=$?
assert "init master without a memory repo exits 0 and says shared memory is off" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'FLEET_MEMORY_REPO is empty: shared memory is off'" "$out"
refute "FLEET_T3_REMOTE=0 (default): init creates no T3 client key" [ -f "$V3/ssh/t3_client" ]
m3 reconcile >/dev/null 2>&1
refute "reconcile without the T3 key never touches ~/.ssh" [ -e "$HOME3/.ssh" ]
m3 invite --name nomem >/dev/null 2>&1
nm_pending=$(grep -l '"name": "nomem"' "$V3"/nodes/pending/*.json)
mk_node fleet-nomem.tail1.ts.net "$(jget "$nm_pending" nonce)"
rm -f "$NODES/fleet-nomem.tail1.ts.net/.ssh/fleet_memory.pub"      # never read without a memory repo
write_status ',"k9":{"ID":"nNOMEMCNTRL","HostName":"fleet-nomem","DNSName":"fleet-nomem.tail1.ts.net.","TailscaleIPs":["100.64.0.21"],"Online":true,"Tags":["tag:fleet-node"]}' "$T/status3.json"
n_mem_post=$(grep -c '^POST /repos/example/fleet-memory/keys' "$API_LOG")
: >"$SSH_LOG"
out=$(m3 reconcile 2>&1); rc=$?
assert "enrol + provision without a memory repo: exits 0, node provisioned" bash -c "[ $rc = 0 ] && [ \"\$(jget '$V3/nodes/nNOMEMCNTRL.json' state)\" = provisioned ]"
assert "registry: config key registered, memory key null" bash -c "[ -n \"\$(jget '$V3/nodes/nNOMEMCNTRL.json' github_keys.config.id)\" ] && [ \"\$(jget '$V3/nodes/nNOMEMCNTRL.json' github_keys.memory)\" = null ]"
assert "no memory deploy key requested, fleet_memory.pub never read" bash -c "[ \"\$(grep -c '^POST /repos/example/fleet-memory/keys' '$API_LOG')\" = $n_mem_post ] && ! grep -q 'fleet_memory.pub' '$SSH_LOG'"
refute "provision without the T3 key adds no fleet-t3-client line" grep -q 'fleet-t3-client' "$NODES/fleet-nomem.tail1.ts.net/.ssh/authorized_keys"
refute "still nothing under ~/.ssh on the master" [ -e "$HOME3/.ssh" ]
out=$(m3 doctor 2>&1)
assert "doctor: no memory repo and no T3 key are reported, not failures" bash -c "printf '%s' \"\$0\" | grep -q 'FLEET_MEMORY_REPO is empty: shared memory is off' && printf '%s' \"\$0\" | grep -q 't3 remote access: off' && ! printf '%s' \"\$0\" | grep -q 'warn.*FLEET_MEMORY_REPO'" "$out"
n_mem_del=$(grep -c '^DELETE /repos/example/fleet-memory/keys/' "$API_LOG"); n_cfg_del=$(grep -c '^DELETE /repos/example/fleet-config/keys/' "$API_LOG")
out=$(m3 kick nomem --yes </dev/null 2>&1); rc=$?
assert "kick without a memory repo: exits 0, deletes device + config key only, nothing pending, no t3 step" bash -c "[ $rc = 0 ] && grep -q '^DELETE /api/v2/device/nNOMEMCNTRL' '$API_LOG' && [ \"\$(jget '$V3/nodes/nNOMEMCNTRL.json' pending_cleanup)\" = '[]' ] && ! grep -q ' kick nomem .*t3=' '$V3/audit.log'"
assert "kick deleted one config key and no memory key" bash -c "[ \"\$(grep -c '^DELETE /repos/example/fleet-config/keys/' '$API_LOG')\" = $((n_cfg_del + 1)) ] && [ \"\$(grep -c '^DELETE /repos/example/fleet-memory/keys/' '$API_LOG')\" = $n_mem_del ]"
rm -rf "$NODES/fleet-nomem.tail1.ts.net"

# ======================================================================
echo "== config publish (commits + pushes the config repo, never the code checkout)"
git -C "$CFG" remote add origin "$T/cfg-remote.git"; git -C "$CFG" push -q -u origin main 2>/dev/null
code_head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo none)
out=$(GIT_CONFIG_GLOBAL="$T/gitconfig-empty" bash "$FLEET" config publish --no-capture --yes 2>&1); rc=$?
# the config checkout carries its own identity (set above), so this run must succeed either way
assert "publish works with an identity on the repo alone" [ "$rc" = 0 ]
git -C "$CFG" config --unset user.name; git -C "$CFG" config --unset user.email
out=$(GIT_CONFIG_GLOBAL="$T/gitconfig-empty" bash "$FLEET" config publish --no-capture --yes 2>&1); rc=$?
assert "publish without any git identity dies first, with the git config commands" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'git has no identity' && printf '%s' \"\$0\" | grep -q 'git config --global user.name'" "$out"
git -C "$CFG" config user.email t@example.invalid; git -C "$CFG" config user.name t
out=$(bash "$FLEET" config publish --no-capture --yes 2>&1); rc=$?
assert "nothing to publish: exits 0, says so" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'nothing to commit'" "$out"
echo "x" >"$CFG/skills/extra.md"
n_before=$(git -C "$CFG" rev-list --count HEAD)
# a hand-edited file with a token: the scan runs even with --no-capture
printf 'token: %s%s\n' 'ghp_' 'abcdefghijklmnopqrstuvwxyz0123456789' >"$CFG/skills/leak.md"   # split: no token-shaped literal in the repo
out=$(bash "$FLEET" config publish --no-capture --yes 2>&1); rc=$?
assert "publish --no-capture still runs the secret scan and refuses to commit a token" bash -c "[ $rc != 0 ] && [ \"\$(git -C '$CFG' rev-list --count HEAD)\" = $n_before ] && printf '%s' \"\$0\" | grep -q 'secrets or machine paths found' && printf '%s' \"\$0\" | grep -q 'leak.md:1: github token'" "$out"
rm -f "$CFG/skills/leak.md"
out=$(printf 'n\n' | bash "$FLEET" config publish --no-capture 2>&1); rc=$?
assert "declined confirmation: nothing committed, non-zero" bash -c "[ $rc != 0 ] && [ \"\$(git -C '$CFG' rev-list --count HEAD)\" = $n_before ] && printf '%s' \"\$0\" | grep -q 'Commit 1 changed file(s)'" "$out"
assert "publish shows the staged diff (stat and content) before asking" bash -c "printf '%s' \"\$0\" | grep -q 'skills/extra.md | 1 +' && printf '%s' \"\$0\" | grep -qx '+x'" "$out"
out=$(bash "$FLEET" config publish --no-capture --yes 2>&1); rc=$?
assert "config publish --yes exits 0" [ "$rc" = 0 ]
assert "config publish commits with the fixed message" bash -c "[ \"\$(git -C '$CFG' rev-list --count HEAD)\" = $((n_before + 1)) ] && [ \"\$(git -C '$CFG' log -1 --format=%s)\" = 'publish fleet config' ]"
assert "config publish pushed to origin" [ "$(git --git-dir="$T/cfg-remote.git" rev-parse main)" = "$(git -C "$CFG" rev-parse HEAD)" ]
assert "config publish reports the push" printf '%s' "$out" | grep -q 'pushed to'
assert "the code checkout was not touched" [ "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo none)" = "$code_head" ]
assert "audit log records the publish" grep -q ' config.publish - pushed' "$FLEET_VAULT/audit.log"
git -C "$CFG" remote remove origin
out=$(bash "$FLEET" config publish --no-capture --yes 2>&1)
assert "publish without a remote warns and keeps the commit" printf '%s' "$out" | grep -q 'no origin remote'

# ======================================================================
echo "== sync: fast-forward only clean + behind checkouts, re-exec after a code update, reconcile, tool push cadence, lock, schedules"
# The master's code checkout for this test is a clone of a bare repo seeded from
# this tree (the checkout the tests run from is never touched); the config
# checkout is $CFG with its origin back. Both get a commit on the remote side.
SYNC_SRC="$T/sync-src"; mkdir -p "$SYNC_SRC"
(cd "$ROOT" && tar -cf - fleet lib config skills templates examples) | tar -xf - -C "$SYNC_SRC"
(cd "$SYNC_SRC" && git -c init.defaultBranch=main init -q && git add -A && git commit -q -m "code v1")
git -c init.defaultBranch=main init -q --bare "$T/sync-code.git"
git -C "$SYNC_SRC" push -q "$T/sync-code.git" HEAD:main
git clone -q "$T/sync-code.git" "$T/sync-wt"
SFLEET="$T/sync-wt/fleet"
sync_digest_of() { FLEET_ROOT="$T/sync-wt" bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/vault.sh"; . "$FLEET_ROOT/lib/master.sh"; desired_digest "$1"' _ "$1" 2>/dev/null; }
git -C "$CFG" remote add origin "$T/cfg-remote.git"; git -C "$CFG" push -q -u origin main 2>/dev/null
git clone -q "$T/cfg-remote.git" "$T/cfg-other"
printf '\nsync marker\n' >>"$T/cfg-other/AGENTS.md"; git -C "$T/cfg-other" commit -qam "config via sync"; git -C "$T/cfg-other" push -q origin main
echo "code marker" >"$SYNC_SRC/SYNC-MARKER"; git -C "$SYNC_SRC" add -A; git -C "$SYNC_SRC" commit -q -m "code v2"; git -C "$SYNC_SRC" push -q "$T/sync-code.git" HEAD:main
# a fresh node waiting to be enrolled: sync's reconcile step must pick it up
bash "$FLEET" invite --name syncnode >/dev/null 2>&1
sn_pending=$(grep -l '"name": "syncnode"' "$FLEET_VAULT"/nodes/pending/*.json)
mk_node fleet-syncnode.tail1.ts.net "$(jget "$sn_pending" nonce)"
write_status ',"k11":{"ID":"nSYNCCNTRL","HostName":"fleet-syncnode","DNSName":"fleet-syncnode.tail1.ts.net.","TailscaleIPs":["100.64.0.40"],"Online":true,"Tags":["tag:fleet-node"]}'
echo '[{"nodeId":"nAAAACNTRL"},{"nodeId":"nSYNCCNTRL"}]' >"$DEVICES_JSON"
NOW0=$(date +%s)
: >"$SSH_LOG"
out=$(FLEET_NOW_EPOCH=$NOW0 bash "$SFLEET" sync 2>&1); rc=$?
assert "sync exits 0" [ "$rc" = 0 ]
assert "sync fast-forwarded the clean, behind code checkout and re-executed itself from the new code" bash -c "[ -f '$T/sync-wt/SYNC-MARKER' ] && [ \"\$(git -C '$T/sync-wt' rev-parse HEAD)\" = \"\$(git --git-dir='$T/sync-code.git' rev-parse main)\" ] && printf '%s' \"\$0\" | grep -q 'code: .* -> .* (origin/main)' && printf '%s' \"\$0\" | grep -q 're-executing fleet sync'" "$out"
assert "sync fast-forwarded the clean, behind config checkout" bash -c "[ \"\$(git -C '$CFG' rev-parse HEAD)\" = \"\$(git --git-dir='$T/cfg-remote.git' rev-parse main)\" ] && grep -q 'sync marker' '$CFG/AGENTS.md' && printf '%s' \"\$0\" | grep -q 'config: .* -> .* (origin/main)'" "$out"
assert "both checkouts are clean afterwards (no stash, no merge commit)" bash -c "[ -z \"\$(git -C '$T/sync-wt' status --porcelain)\" ] && [ -z \"\$(git -C '$CFG' status --porcelain)\" ] && [ \"\$(git -C '$T/sync-wt' rev-list --count HEAD)\" = 2 ]"
sync_want=$(sync_digest_of full)
assert "sync ran reconcile: the waiting node was enrolled and provisioned with the new revs' digest" bash -c "[ \"\$(jget '$FLEET_VAULT/nodes/nSYNCCNTRL.json' state)\" = provisioned ] && [ -n '$sync_want' ] && [ \"\$(cat '$NODES/fleet-syncnode.tail1.ts.net/.config/fleet/applied')\" = '$sync_want' ]"
assert "first sync pushed tool updates (never pushed before): fleet update on the online provisioned node, summarised, recorded in vault/sync.json" bash -c "grep -q 'fleetuser@fleet-syncnode.tail1.ts.net ~/.local/bin/fleet update' '$SSH_LOG' && [ -f '$NODES/fleet-syncnode.tail1.ts.net/.fleet-updated' ] && printf '%s' \"\$0\" | grep -q 'tools: fleet update on 1 node(s): 1 ok' && [ -n \"\$(jget '$FLEET_VAULT/sync.json' tools_pushed)\" ] && [ \"\$(mode_of '$FLEET_VAULT/sync.json')\" = 600 ]" "$out"
assert "audit log records the fast-forwards and the tool push" bash -c "grep -q ' sync.ff code ' '$FLEET_VAULT/audit.log' && grep -q ' sync.ff config ' '$FLEET_VAULT/audit.log' && grep -q ' sync.tools - 1/1 ok' '$FLEET_VAULT/audit.log'"
refute "sync released the master lock" [ -d "$FLEET_VAULT/locks/.sync" ]
: >"$SSH_LOG"
out=$(FLEET_NOW_EPOCH=$((NOW0 + 60)) bash "$SFLEET" sync 2>&1); rc=$?
assert "second sync a minute later: exit 0, quiet, no tool push (cadence 1440 min)" bash -c "[ $rc = 0 ] && [ -z \"\$0\" ] && ! grep -q 'fleet update' '$SSH_LOG' && grep -q 'cat ~/.config/fleet/applied' '$SSH_LOG'" "$out"
# A node provisioned while the master had unpushed commits applied older revs.
# Once the revs are pushed, reconcile tries again exactly once.
python3 - "$FLEET_VAULT/nodes/nSYNCCNTRL.json" <<'PY'
import json, sys
f = sys.argv[1]; d = json.load(open(f)); d["applied_commit"] = "old+old"; d["retried_for"] = ""
json.dump(d, open(f, "w"))
PY
out=$(FLEET_NOW_EPOCH=$((NOW0 + 120)) bash "$SFLEET" sync 2>&1); rc=$?
assert "node behind pushed revs: sync provisions it again" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'provision syncnode'" "$out"
out=$(FLEET_NOW_EPOCH=$((NOW0 + 180)) bash "$SFLEET" sync 2>&1); rc=$?
assert "...and only once for the same revs (node still reports old revs, sync stays quiet)" bash -c "[ $rc = 0 ] && [ -z \"\$0\" ]" "$out"
# tool push cadence from fleet.conf, and 0 = off
printf 'FLEET_PUSH_TOOLS_EVERY=60\n' >>"$FLEET_HOME/fleet.conf"
: >"$SSH_LOG"; FLEET_NOW_EPOCH=$((NOW0 + 30 * 60)) bash "$SFLEET" sync >/dev/null 2>&1
refute "30 min after the push with FLEET_PUSH_TOOLS_EVERY=60: no tool push" grep -q 'fleet update' "$SSH_LOG"
: >"$SSH_LOG"; out=$(FLEET_NOW_EPOCH=$((NOW0 + 61 * 60)) bash "$SFLEET" sync 2>&1)
assert "61 min after the push: tools pushed again, last run moved" bash -c "grep -q 'fleet update' '$SSH_LOG' && printf '%s' \"\$0\" | grep -q 'tools: fleet update on 1 node(s): 1 ok' && [ \"\$(jget '$FLEET_VAULT/sync.json' tools_pushed)\" = \"\$(FLEET_ROOT='$ROOT' bash -c '. \"\$FLEET_ROOT/lib/common.sh\"; . \"\$FLEET_ROOT/lib/master.sh\"; epoch_iso $((NOW0 + 61 * 60))')\" ]" "$out"
printf 'FLEET_PUSH_TOOLS_EVERY=0\n' >>"$FLEET_HOME/fleet.conf"
: >"$SSH_LOG"; FLEET_NOW_EPOCH=$((NOW0 + 10 * 86400)) bash "$SFLEET" sync >/dev/null 2>&1
refute "FLEET_PUSH_TOOLS_EVERY=0 never pushes tools" grep -q 'fleet update' "$SSH_LOG"
grep -v '^FLEET_PUSH_TOOLS_EVERY=' "$FLEET_HOME/fleet.conf" >"$T/lc"; cat "$T/lc" >"$FLEET_HOME/fleet.conf"
# dirty tree: a tracked file modified -> warned, not updated, the change kept
echo "code v3" >"$SYNC_SRC/SYNC-MARKER"; git -C "$SYNC_SRC" commit -qam "code v3"; git -C "$SYNC_SRC" push -q "$T/sync-code.git" HEAD:main
code_v2=$(git -C "$T/sync-wt" rev-parse HEAD)
printf '# dirty\n' >>"$T/sync-wt/config/defaults.conf"
out=$(bash "$SFLEET" sync 2>&1); rc=$?
assert "dirty code checkout: sync exits 0, warns, leaves HEAD and the local change alone" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'code: .* uncommitted changes; not updated' && [ \"\$(git -C '$T/sync-wt' rev-parse HEAD)\" = '$code_v2' ] && grep -q '^# dirty' '$T/sync-wt/config/defaults.conf'" "$out"
git -C "$T/sync-wt" checkout -q -- config/defaults.conf
# untracked files do not count as dirty
echo scratch >"$T/sync-wt/SCRATCH"
out=$(bash "$SFLEET" sync 2>&1); rc=$?
assert "an untracked file does not block the fast-forward" bash -c "[ $rc = 0 ] && [ \"\$(git -C '$T/sync-wt' rev-parse HEAD)\" = \"\$(git --git-dir='$T/sync-code.git' rev-parse main)\" ] && [ -f '$T/sync-wt/SCRATCH' ] && printf '%s' \"\$0\" | grep -q 'code: .* -> '" "$out"
rm -f "$T/sync-wt/SCRATCH"
# diverged: a local commit and a new remote commit -> warned, nothing merged
echo local >"$T/sync-wt/LOCAL"; git -C "$T/sync-wt" add LOCAL; git -C "$T/sync-wt" commit -q -m "local only"
code_local=$(git -C "$T/sync-wt" rev-parse HEAD)
echo "code v4" >"$SYNC_SRC/SYNC-MARKER"; git -C "$SYNC_SRC" commit -qam "code v4"; git -C "$SYNC_SRC" push -q "$T/sync-code.git" HEAD:main
out=$(bash "$SFLEET" sync 2>&1); rc=$?
assert "diverged code checkout: sync exits 0, warns, HEAD unchanged, no merge" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'code: main and origin/main have diverged' && [ \"\$(git -C '$T/sync-wt' rev-parse HEAD)\" = '$code_local' ] && [ \"\$(git -C '$T/sync-wt' rev-list --count HEAD)\" = 4 ]" "$out"
# ahead only (unpushed commit, remote caught up): quiet
git -C "$T/sync-wt" reset -q --hard origin/main; echo ahead >"$T/sync-wt/AHEAD"; git -C "$T/sync-wt" add AHEAD; git -C "$T/sync-wt" commit -q -m "ahead"
code_ahead=$(git -C "$T/sync-wt" rev-parse HEAD)
out=$(bash "$SFLEET" sync 2>&1); rc=$?
# (the new local commit changes the desired digest, so this run re-provisions the node: that part is not quiet)
assert "a checkout that is only ahead is left alone without a warning" bash -c "[ $rc = 0 ] && ! printf '%s' \"\$0\" | grep -q 'code:' && [ \"\$(git -C '$T/sync-wt' rev-parse HEAD)\" = '$code_ahead' ] && [ -f '$T/sync-wt/AHEAD' ]" "$out"
git -C "$T/sync-wt" reset -q --hard origin/main
# unreachable remote: warned, exit 0
git -C "$T/sync-wt" remote set-url origin "$T/does-not-exist.git"
out=$(bash "$SFLEET" sync 2>&1); rc=$?
assert "unreachable remote: sync exits 0 and warns" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'code: fetch from origin failed'" "$out"
git -C "$T/sync-wt" remote set-url origin "$T/sync-code.git"
# the master lock: a running sync makes another sync and a reconcile skip
mkdir -p "$FLEET_VAULT/locks/.sync"; sleep 60 & LP=$!; echo "$LP" >"$FLEET_VAULT/locks/.sync/pid"; echo tok >"$FLEET_VAULT/locks/.sync/token"
: >"$SSH_LOG"
out=$(bash "$SFLEET" sync 2>&1); rc=$?
assert "sync while the lock is held: exit 0, says it skipped, touched no node" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'another fleet sync or reconcile is running' && [ ! -s '$SSH_LOG' ]" "$out"
out=$(bash "$FLEET" reconcile 2>&1); rc=$?
assert "reconcile while the lock is held: exit 0, skipped, touched no node, lock kept" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'skipping this run' && [ ! -s '$SSH_LOG' ] && [ -d '$FLEET_VAULT/locks/.sync' ] && [ \"\$(cat '$FLEET_VAULT/locks/.sync/pid')\" = $LP ]" "$out"
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
out=$(bash "$FLEET" reconcile 2>&1); rc=$?
assert "lock holder gone: reconcile removes the stale lock, runs, releases" bash -c "[ $rc = 0 ] && grep -q 'cat ~/.config/fleet/applied' '$SSH_LOG' && [ ! -d '$FLEET_VAULT/locks/.sync' ]"
# schedules: init master wrote both; schedule install is idempotent
case "$(uname -s)" in
  Darwin)
    SP="$HOME/Library/LaunchAgents/dev.fleet.sync.plist"
    assert "init master wrote the sync LaunchAgent: label, fleet sync, every 1800 s, logs to sync.log" bash -c "grep -q '<string>dev.fleet.sync</string>' '$SP' && grep -q '<string>$ROOT/fleet</string><string>sync</string>' '$SP' && grep -q '<integer>1800</integer>' '$SP' && grep -q '$FLEET_HOME/sync.log' '$SP'"
    RP="$HOME/Library/LaunchAgents/dev.fleet.reconcile.plist" ;;
  *)
    SP="$HOME/.config/systemd/user/fleet-sync.timer"
    assert "init master wrote the sync systemd timer + service: every 30 min, fleet sync, logs to sync.log" bash -c "grep -q '^OnUnitActiveSec=30min' '$SP' && grep -q '^ExecStart=$ROOT/fleet sync$' '$HOME/.config/systemd/user/fleet-sync.service' && grep -q 'sync.log' '$HOME/.config/systemd/user/fleet-sync.service'"
    RP="$HOME/.config/systemd/user/fleet-reconcile.timer" ;;
esac
sp1=$(cat "$SP"); rp1=$(cat "$RP")
out=$(bash "$FLEET" schedule install 2>&1); rc=$?
assert "schedule install exits 0 and reports both timers" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'reconcile schedule:' && printf '%s' \"\$0\" | grep -q 'sync schedule:'" "$out"
assert "schedule install is idempotent: both files unchanged, no temp files left" bash -c "[ \"\$(cat '$SP')\" = \"\$0\" ] && [ \"\$(cat '$RP')\" = \"\$1\" ] && ! ls \"\$(dirname '$SP')\"/.fleet.* 2>/dev/null | grep -q ." "$sp1" "$rp1"
printf 'FLEET_SYNC_EVERY=7\n' >>"$FLEET_HOME/fleet.conf"
bash "$FLEET" schedule install >/dev/null 2>&1
case "$(uname -s)" in
  Darwin) assert "FLEET_SYNC_EVERY changes the interval (420 s)" grep -q '<integer>420</integer>' "$SP" ;;
  *)      assert "FLEET_SYNC_EVERY changes the interval (7min)" grep -q '^OnUnitActiveSec=7min' "$SP" ;;
esac
grep -v '^FLEET_SYNC_EVERY=' "$FLEET_HOME/fleet.conf" >"$T/lc"; cat "$T/lc" >"$FLEET_HOME/fleet.conf"
bash "$FLEET" schedule install >/dev/null 2>&1
assert "doctor sees both schedules" bash -c "bash '$FLEET' doctor 2>&1 | grep -q 'sync schedule installed'"
rm -f "$FLEET_VAULT/nodes/nSYNCCNTRL.json"; rm -rf "$NODES/fleet-syncnode.tail1.ts.net"; write_status ""
echo '[{"nodeId":"nAAAACNTRL"}]' >"$DEVICES_JSON"

# ======================================================================
echo "== skill add / list / remove: config repo + this machine + the nodes; sync auto-publishes local skills"
# a provisioned node that is online: the add's reconcile re-provisions it
bash "$FLEET" invite --name skillnode >/dev/null 2>&1
sk_pending=$(grep -l '"name": "skillnode"' "$FLEET_VAULT"/nodes/pending/*.json)
mk_node fleet-skillnode.tail1.ts.net "$(jget "$sk_pending" nonce)"
write_status ',"k12":{"ID":"nSKILLCNTRL","HostName":"fleet-skillnode","DNSName":"fleet-skillnode.tail1.ts.net.","TailscaleIPs":["100.64.0.41"],"Online":true,"Tags":["tag:fleet-node"]}'
echo '[{"nodeId":"nAAAACNTRL"},{"nodeId":"nSKILLCNTRL"}]' >"$DEVICES_JSON"
bash "$FLEET" reconcile >/dev/null 2>&1
assert "skillnode enrolled and provisioned before the skill tests" [ "$(jget "$FLEET_VAULT/nodes/nSKILLCNTRL.json" state)" = provisioned ]
echo '{"BackendState":"Running","Self":{"ID":"nSELF","HostName":"mac","TailscaleIPs":["100.64.0.1"]},"Peer":{}}' >"$T/status-nopeers.json"
# a local skill dir with a script, a vendor cache and a .DS_Store that must not travel
SK="$T/my-skills/review"; mkdir -p "$SK/scripts" "$SK/node_modules/x"
printf -- '---\nname: review\ndescription: Review a pull request the way this team does it, with the checklist in checklist.md.\n---\n# review\n\nRead checklist.md first.\n' >"$SK/SKILL.md"
printf -- '- tests\n- docs\n' >"$SK/checklist.md"; printf '#!/bin/sh\necho hi\n' >"$SK/scripts/run.sh"; chmod +x "$SK/scripts/run.sh"
echo junk >"$SK/node_modules/x/i.js"; echo x >"$SK/.DS_Store"
n_before=$(git -C "$CFG" rev-list --count HEAD)
: >"$SSH_LOG"
out=$(bash "$FLEET" skill add "$SK" --yes 2>&1); rc=$?
assert "skill add DIR --yes: exit 0, says added / published (secret scan clean) / pushed to N nodes" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'added review to your fleet config' && printf '%s' \"\$0\" | grep -q 'published (secret scan clean)' && printf '%s' \"\$0\" | grep -Eq 'pushed to [0-9]+ node'" "$out"
assert "copied into the config repo without node_modules/.DS_Store, mode kept, committed 'add skill review', pushed to origin, tree clean" bash -c "[ -f '$CFG/skills/review/SKILL.md' ] && [ -x '$CFG/skills/review/scripts/run.sh' ] && [ ! -e '$CFG/skills/review/node_modules' ] && [ ! -e '$CFG/skills/review/.DS_Store' ] && [ \"\$(git -C '$CFG' rev-list --count HEAD)\" = $((n_before + 1)) ] && [ \"\$(git -C '$CFG' log -1 --format=%s)\" = 'add skill review' ] && [ \"\$(git --git-dir='$T/cfg-remote.git' rev-parse main)\" = \"\$(git -C '$CFG' rev-parse HEAD)\" ] && [ -z \"\$(git -C '$CFG' status --porcelain)\" ]"
assert "installed on the master too (~/.claude/skills only: FLEET_TOOLS has claude, no other harness dir), both manifests updated" bash -c "cmp -s '$HOME/.claude/skills/review/SKILL.md' '$SK/SKILL.md' && [ ! -e '$HOME/.claude/skills/review/node_modules' ] && [ ! -e '$HOME/.agents/skills/review' ] && grep -qx '$HOME/.claude/skills/review' '$FLEET_HOME/manifest' && grep -qx '$HOME/.claude/skills/review' '$FLEET_HOME/harness.manifest'"
sk_want=$(digest_of full)
assert "the add ran reconcile: skillnode re-provisioned with the digest of the new config revision" bash -c "grep -q 'fleet-skillnode.tail1.ts.net ~/.local/share/fleet/fleet apply --from-master' '$SSH_LOG' && [ -n '$sk_want' ] && [ \"\$(cat '$NODES/fleet-skillnode.tail1.ts.net/.config/fleet/applied')\" = '$sk_want' ]"
assert "audit log records the add" grep -q ' skill.add review pushed' "$FLEET_VAULT/audit.log"
refute "skill add never echoes the node's secrets or the vault" printf '%s' "$out" | grep -Eq 'fullsecret|s3cr3t|vault/secrets'
out=$(bash "$FLEET" skill add "$SK" --yes 2>&1); rc=$?
assert "adding the identical skill again is a no-op (no commit, no reconcile)" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'review is already in your fleet config (unchanged' && [ \"\$(git -C '$CFG' rev-list --count HEAD)\" = $((n_before + 1)) ]" "$out"
# a git source: file:// bare repo with two skills, tag v1 and a later main
SKREPO="$T/skill-src"; mkdir -p "$SKREPO/skills/review" "$SKREPO/skills/other"
printf -- '---\nname: review\ndescription: v1 of the review skill from git.\n---\n# review v1\n' >"$SKREPO/skills/review/SKILL.md"
printf -- '---\nname: other\ndescription: another one from git\n---\n# other\n' >"$SKREPO/skills/other/SKILL.md"
(cd "$SKREPO" && git -c init.defaultBranch=main init -q && git add -A && git commit -q -m v1 && git tag v1)
printf -- '---\nname: review\ndescription: v2 of the review skill from git.\n---\n# review v2\n' >"$SKREPO/skills/review/SKILL.md"
git -C "$SKREPO" commit -qam v2
git -c init.defaultBranch=main init -q --bare "$T/skill-src.git"; git -C "$SKREPO" push -q --tags "$T/skill-src.git" main
out=$(bash "$FLEET" skill add "file://$T/skill-src.git#skills/review@v1" --yes 2>&1); rc=$?
assert "skill add URL#subdir@ref --yes replaces the different existing skill: 'updated', commit 'update skill review', content is the tagged v1" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'updated review in your fleet config' && printf '%s' \"\$0\" | grep -q 'published (secret scan clean)' && grep -qx '# review v1' '$CFG/skills/review/SKILL.md' && [ ! -e '$CFG/skills/review/checklist.md' ] && [ \"\$(git -C '$CFG' log -1 --format=%s)\" = 'update skill review' ] && [ \"\$(git --git-dir='$T/cfg-remote.git' rev-parse main)\" = \"\$(git -C '$CFG' rev-parse HEAD)\" ]" "$out"
assert "the master's own copy follows the update; no clone temp dir left behind" bash -c "grep -qx '# review v1' '$HOME/.claude/skills/review/SKILL.md' && ! ls -d \"\${TMPDIR:-/tmp}\"/fleet-skill.* 2>/dev/null | grep -q ."
out=$(bash "$FLEET" skill add "file://$T/skill-src.git#skills/other" --name other-two --yes 2>&1); rc=$?
assert "skill add URL#subdir --name N: installed under N" bash -c "[ $rc = 0 ] && [ -f '$CFG/skills/other-two/SKILL.md' ] && [ \"\$(git -C '$CFG' log -1 --format=%s)\" = 'add skill other-two' ] && [ -f '$HOME/.claude/skills/other-two/SKILL.md' ]"
n_head=$(git -C "$CFG" rev-parse HEAD)
out=$(bash "$FLEET" skill add "file://$T/skill-src.git@v1" --yes 2>&1); rc=$?
assert "URL@ref without a subdir (repo root has no SKILL.md): refused, nothing committed" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'no SKILL.md' && [ \"\$(git -C '$CFG' rev-parse HEAD)\" = '$n_head' ]" "$out"
out=$(bash "$FLEET" skill add "file://$T/skill-src.git#skills/review@nosuchref" --yes 2>&1); rc=$?
assert "unknown ref: refused with the ref named" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'nosuchref'" "$out"
# refusals: no frontmatter, no name, bad name, not a source, existing different skill without --yes, a secret
BAD="$T/my-skills/bad"; mkdir -p "$BAD"; printf '# no frontmatter here\n' >"$BAD/SKILL.md"
out=$(bash "$FLEET" skill add "$BAD" --yes 2>&1); rc=$?
assert "SKILL.md without frontmatter: refused, nothing in the repo" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'no YAML frontmatter' && [ ! -e '$CFG/skills/bad' ] && [ \"\$(git -C '$CFG' rev-parse HEAD)\" = '$n_head' ]" "$out"
NONAME="$T/my-skills/noname"; mkdir -p "$NONAME"; printf -- '---\ndescription: nameless\n---\n' >"$NONAME/SKILL.md"
out=$(bash "$FLEET" skill add "$NONAME" --yes 2>&1); rc=$?
assert "frontmatter without name: refused, suggests --name" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'no name:' && printf '%s' \"\$0\" | grep -q -- '--name'" "$out"
out=$(bash "$FLEET" skill add "$SK" --name 'Bad_Name' --yes 2>&1); rc=$?
assert "invalid --name: refused with the pattern" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'invalid skill name: Bad_Name' && [ ! -e '$CFG/skills/Bad_Name' ]" "$out"
out=$(bash "$FLEET" skill add "$T/does-not-exist" --yes 2>&1); rc=$?
assert "neither a directory nor a git URL: refused" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'not a directory and not a git URL'" "$out"
out=$(bash "$FLEET" skill add "$SK" </dev/null 2>&1); rc=$?
assert "existing skill with different content, no --yes: refused, repo untouched and clean" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'already exists in your fleet config with different content' && grep -qx '# review v1' '$CFG/skills/review/SKILL.md' && [ \"\$(git -C '$CFG' rev-parse HEAD)\" = '$n_head' ] && [ -z \"\$(git -C '$CFG' status --porcelain)\" ]" "$out"
out=$(printf 'n\n' | bash "$FLEET" skill add "file://$T/skill-src.git#skills/other" --name other-three 2>&1); rc=$?
assert "declined confirmation (a new skill, no --yes): staged diff shown, aborted, nothing committed, working tree clean" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'skills/other-three/SKILL.md' && printf '%s' \"\$0\" | grep -q 'Add skill other-three in' && printf '%s' \"\$0\" | grep -q 'aborted; nothing added' && [ ! -e '$CFG/skills/other-three' ] && [ ! -e '$HOME/.claude/skills/other-three' ] && [ \"\$(git -C '$CFG' rev-parse HEAD)\" = '$n_head' ] && [ -z \"\$(git -C '$CFG' status --porcelain)\" ]" "$out"
LEAK="$T/my-skills/leaky"; mkdir -p "$LEAK"
printf -- '---\nname: leaky\ndescription: leaks a token\n---\ntoken: %s%s\n' 'ghp_' 'abcdefghijklmnopqrstuvwxyz0123456789' >"$LEAK/SKILL.md"   # split: no token-shaped literal in the repo
out=$(bash "$FLEET" skill add "$LEAK" --yes 2>&1); rc=$?
assert "a secret in the skill: aborted before anything is copied (repo, master skill dir), hit named" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'SKILL.md:5: github token' && printf '%s' \"\$0\" | grep -q 'nothing added' && [ ! -e '$CFG/skills/leaky' ] && [ ! -e '$HOME/.claude/skills/leaky' ] && [ \"\$(git -C '$CFG' rev-parse HEAD)\" = '$n_head' ] && [ -z \"\$(git -C '$CFG' status --porcelain)\" ]" "$out"
# list: config skills, the bundled fleet skill, skills only in this machine's skill dirs; vendor caches hidden
mkdir -p "$HOME/.claude/skills/localonly" "$HOME/.claude/skills/synced/some-uuid"
printf -- '---\nname: localonly\ndescription: only on this machine so far\n---\n' >"$HOME/.claude/skills/localonly/SKILL.md"
printf -- '---\nname: synced\ndescription: plugin cache\n---\n' >"$HOME/.claude/skills/synced/SKILL.md"
out=$(bash "$FLEET" skill list 2>&1); rc=$?
assert "skill list: header NAME SOURCE ON NODES? DESCRIPTION" bash -c "[ $rc = 0 ] && printf '%s\n' \"\$0\" | head -1 | grep -Eq '^NAME +SOURCE +ON NODES\? +DESCRIPTION$'" "$out"
assert "skill list: config skills (review from git v1, other-two, the example fleet-notes) pushed = yes" bash -c "printf '%s\n' \"\$0\" | grep -Eq '^review +config +yes +v1 of the review skill from git\.$' && printf '%s\n' \"\$0\" | grep -Eq '^other-two +config +yes +another one from git' && printf '%s\n' \"\$0\" | grep -Eq '^fleet-notes +config +yes +Record a reusable'" "$out"
assert "skill list: the bundled fleet skill and the local-only one; the synced cache is hidden" bash -c "printf '%s\n' \"\$0\" | grep -Eq '^fleet +fleet +yes +Operate the user' && printf '%s\n' \"\$0\" | grep -Eq '^localonly +local-only +no +only on this machine so far$' && ! printf '%s\n' \"\$0\" | grep -q '^synced'" "$out"
assert "skill list truncates long descriptions to the width (COLUMNS=60)" bash -c "COLUMNS=60 bash '$FLEET' skill list | grep -Eq '^fleet-notes +config +yes +Record .*\.\.\.$' && ! COLUMNS=60 bash '$FLEET' skill list | grep -Eq '.{61,}'"
assert "skill list --json: names, sources, on_nodes, descriptions" bash -c "bash '$FLEET' skill list --json | python3 -c 'import json,sys; d={x[\"name\"]: x for x in json.load(sys.stdin)}; assert d[\"review\"][\"source\"]==\"config\" and d[\"review\"][\"on_nodes\"]==\"yes\" and d[\"fleet\"][\"source\"]==\"fleet\" and d[\"localonly\"][\"source\"]==\"local-only\" and d[\"localonly\"][\"on_nodes\"]==\"no\" and \"synced\" not in d and d[\"review\"][\"description\"].startswith(\"v1 of\")'"
echo "local edit" >>"$CFG/skills/review/SKILL.md"
assert "skill list: an uncommitted edit in the config repo shows as not pushed" bash -c "bash '$FLEET' skill list | grep -Eq '^review +config +not pushed '"
git -C "$CFG" checkout -q -- skills/review
# remove: confirmation, then config repo + this machine + reconcile
n_head=$(git -C "$CFG" rev-parse HEAD)
out=$(printf 'n\n' | bash "$FLEET" skill remove review 2>&1); rc=$?
assert "skill remove without confirmation: aborted, nothing removed" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'Remove skill review from' && printf '%s' \"\$0\" | grep -q 'aborted; nothing removed' && [ -f '$CFG/skills/review/SKILL.md' ] && [ -f '$HOME/.claude/skills/review/SKILL.md' ] && [ \"\$(git -C '$CFG' rev-parse HEAD)\" = '$n_head' ]" "$out"
: >"$SSH_LOG"
out=$(bash "$FLEET" skill remove review --yes 2>&1); rc=$?
assert "skill remove --yes: exit 0, removed / published / pushed to N nodes" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'removed review from your fleet config' && printf '%s' \"\$0\" | grep -q 'published' && printf '%s' \"\$0\" | grep -Eq 'pushed to [0-9]+ node'" "$out"
assert "gone from the config repo (commit 'remove skill review', pushed), from the master's skill dir and the manifests; node re-provisioned" bash -c "[ ! -e '$CFG/skills/review' ] && [ \"\$(git -C '$CFG' log -1 --format=%s)\" = 'remove skill review' ] && [ \"\$(git --git-dir='$T/cfg-remote.git' rev-parse main)\" = \"\$(git -C '$CFG' rev-parse HEAD)\" ] && [ ! -e '$HOME/.claude/skills/review' ] && ! grep -q 'skills/review$' '$FLEET_HOME/manifest' && ! grep -q 'skills/review$' '$FLEET_HOME/harness.manifest' && grep -q 'fleet-skillnode.tail1.ts.net ~/.local/share/fleet/fleet apply --from-master' '$SSH_LOG'"
out=$(bash "$FLEET" skill remove review --yes 2>&1); rc=$?
assert "removing an unknown skill: refused, points at skill list" bash -c "[ $rc != 0 ] && printf '%s' \"\$0\" | grep -q 'no skill review in your fleet config'" "$out"
out=$(FLEET_TS_STATUS_JSON="$T/status-nopeers.json" bash "$FLEET" skill remove other-two --yes 2>&1); rc=$?
assert "remove with no node online: committed + pushed, 'nodes drop it on their next pull'" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'nodes drop it on their next pull' && [ ! -e '$CFG/skills/other-two' ] && [ \"\$(git --git-dir='$T/cfg-remote.git' rev-parse main)\" = \"\$(git -C '$CFG' rev-parse HEAD)\" ]" "$out"
out=$(FLEET_TS_STATUS_JSON="$T/status-nopeers.json" FLEET_SKILL_ADD_NO_SYNC=1 bash "$FLEET" skill add "$SK" --yes 2>&1); rc=$?
assert "FLEET_SKILL_ADD_NO_SYNC=1: added + published, no reconcile" bash -c "[ $rc = 0 ] && printf '%s' \"\$0\" | grep -q 'added review to your fleet config' && printf '%s' \"\$0\" | grep -q 'not pushing to the nodes now' && ! printf '%s' \"\$0\" | grep -q 'pushed to'" "$out"
out=$(FLEET_TS_STATUS_JSON="$T/status-nopeers.json" bash "$FLEET" skill remove review --yes 2>&1)
# sync auto-publish: the sync checkout ($SFLEET) runs this code against the same vault and config repo
git -C "$T/sync-wt" reset -q --hard origin/main
mkdir -p "$HOME/.claude/skills/autopub" "$HOME/.claude/skills/leaky2"
printf -- '---\nname: autopub\ndescription: published by sync\n---\n# autopub\n' >"$HOME/.claude/skills/autopub/SKILL.md"
printf -- '---\nname: leaky2\ndescription: leaks\n---\ntoken: %s%s\n' 'ghp_' 'abcdefghijklmnopqrstuvwxyz0123456789' >"$HOME/.claude/skills/leaky2/SKILL.md"
n_head=$(git -C "$CFG" rev-parse HEAD)
out=$(bash "$SFLEET" sync 2>&1); rc=$?
assert "sync publishes the local-only skills: commit 'publish skills: autopub, localonly', pushed, logged" bash -c "[ $rc = 0 ] && [ \"\$(git -C '$CFG' log -1 --format=%s)\" = 'publish skills: autopub, localonly' ] && [ -f '$CFG/skills/autopub/SKILL.md' ] && [ -f '$CFG/skills/localonly/SKILL.md' ] && [ \"\$(git --git-dir='$T/cfg-remote.git' rev-parse main)\" = \"\$(git -C '$CFG' rev-parse HEAD)\" ] && printf '%s' \"\$0\" | grep -q 'skills: publish skills: autopub, localonly'" "$out"
assert "the leaking skill is skipped with a warning, never committed; the fleet skill and the synced cache are not published" bash -c "printf '%s' \"\$0\" | grep -Eq 'skill leaky2: not published, the secret scan found [0-9]+ hit' && [ ! -e '$CFG/skills/leaky2' ] && [ ! -e '$CFG/skills/fleet' ] && [ ! -e '$CFG/skills/synced' ] && ! git -C '$CFG' log --format=%s | grep -q leaky2" "$out"
assert "audit log records the auto-publish" grep -q ' sync.skills - pushed: autopub localonly' "$FLEET_VAULT/audit.log"
rm -rf "$HOME/.claude/skills/leaky2"
n_head=$(git -C "$CFG" rev-parse HEAD)
out=$(bash "$SFLEET" sync 2>&1); rc=$?
assert "nothing changed: sync is quiet about skills and commits nothing" bash -c "[ $rc = 0 ] && ! printf '%s' \"\$0\" | grep -q 'skills' && [ \"\$(git -C '$CFG' rev-parse HEAD)\" = '$n_head' ]" "$out"
printf '\nedited locally\n' >>"$HOME/.claude/skills/autopub/SKILL.md"
rm -rf "$HOME/.claude/skills/localonly"
out=$(bash "$SFLEET" sync 2>&1); rc=$?
assert "a locally changed skill is re-published; a skill deleted locally stays in the repo (never removed automatically)" bash -c "[ $rc = 0 ] && [ \"\$(git -C '$CFG' log -1 --format=%s)\" = 'publish skills: autopub' ] && grep -q 'edited locally' '$CFG/skills/autopub/SKILL.md' && [ -f '$CFG/skills/localonly/SKILL.md' ]" "$out"
printf 'FLEET_SYNC_PUBLISH_SKILLS=0\n' >>"$FLEET_HOME/fleet.conf"
mkdir -p "$HOME/.claude/skills/offskill"; printf -- '---\nname: offskill\ndescription: not published while off\n---\n' >"$HOME/.claude/skills/offskill/SKILL.md"
n_head=$(git -C "$CFG" rev-parse HEAD)
out=$(bash "$SFLEET" sync 2>&1); rc=$?
assert "FLEET_SYNC_PUBLISH_SKILLS=0: sync publishes nothing" bash -c "[ $rc = 0 ] && [ ! -e '$CFG/skills/offskill' ] && [ \"\$(git -C '$CFG' rev-parse HEAD)\" = '$n_head' ]" "$out"
grep -v '^FLEET_SYNC_PUBLISH_SKILLS=' "$FLEET_HOME/fleet.conf" >"$T/lc"; cat "$T/lc" >"$FLEET_HOME/fleet.conf"
assert "skill list after the auto-publish: autopub config yes, offskill local-only no" bash -c "o=\$(bash '$FLEET' skill list); printf '%s\n' \"\$o\" | grep -Eq '^autopub +config +yes ' && printf '%s\n' \"\$o\" | grep -Eq '^offskill +local-only +no '"
rm -rf "$HOME/.claude/skills/autopub" "$HOME/.claude/skills/offskill" "$HOME/.claude/skills/synced" "$HOME/.claude/skills/other-two"
rm -f "$FLEET_VAULT/nodes/nSKILLCNTRL.json"; rm -rf "$NODES/fleet-skillnode.tail1.ts.net"; write_status ""
echo '[{"nodeId":"nAAAACNTRL"}]' >"$DEVICES_JSON"

# ======================================================================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
