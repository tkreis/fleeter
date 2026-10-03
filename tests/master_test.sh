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
export FLEET_HOME="$HOME/.config/fleet"
export FLEET_VAULT="$FLEET_HOME/vault"
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
#   $T/slow-secrets  → sleep 30 before the secrets step (kick race)
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
[ -d "$nh" ] || exit 255                      # unreachable host
[ "${SSH_FAIL:-}" = "$host" ] && exit 255
case "$cmd" in *secrets.env.tmp*) [ -f "$T/slow-secrets" ] && sleep 30 ;; esac
case "$cmd" in *enrol.json*) [ -f "$T/slow-enrol" ] && sleep 2 ;; esac
case "$cmd" in
  "nc -z "*)                      [ -f "$T/nc-missing" ] && exit 127; [ -f "$T/nc-open" ] && exit 0; exit 1 ;;
  *"fleet pull --no-apply"*)      touch "$nh/.fleet-pulled"; exit 0 ;;
  *"fleet apply --from-master "*) mkdir -p "$nh/.config/fleet"; printf '%s' "${cmd##* }" >"$nh/.config/fleet/applied"; printf 'c0ffee+cafe\n' >"$nh/.config/fleet/applied_commit"; exit 0 ;;
  *"fleet leave"*)                [ -f "$T/leave-fail" ] && exit 1; touch "$nh/.fleet-left"; exit 0 ;;
  *"fleet status --json"*)        echo '{"fleet":"0.1.0","tools":{"claude":{"state":"ok","detail":"x"},"codex":{"state":"login","detail":"y"}}}'; exit 0 ;;
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
i=0; while [ ! -s "$T/api.port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
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
{"Self":{"ID":"nSELF","HostName":"mac","TailscaleIPs":["100.64.0.1"]},"Peer":{
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
}
# digest_of PROFILE — desired_digest as the master computes it.
digest_of() { FLEET_ROOT=$ROOT bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/master.sh"; desired_digest "$1"' _ "$1" 2>/dev/null; }

# the master's config repo: the shipped example with example repo URLs, committed
CFG="$T/fleet-config"
cp -R "$ROOT/examples/fleet-config" "$CFG"
sed 's/YOU/example/g' "$ROOT/examples/fleet-config/fleet.conf" >"$CFG/fleet.conf"
( cd "$CFG" && git init -q -b main && git config user.email t@example.invalid && git config user.name t && git add -A && git commit -q -m "config v1" )

# ======================================================================
echo "== init master (config dir, bootstrap token -> policy apply -> OAuth client -> revoke; gh fallback token)"
assert "init master without a config dir dies with a hint" bash -c "printf 'tskey-api-kboot-FAKE\n' | bash '$FLEET' init master 2>&1 | grep -q 'next: master: fleet init master --config-dir'"
out=$(printf 'tskey-api-kboot-FAKE\napply\nghtok\n' | bash "$FLEET" init master --config-dir "$CFG" 2>&1); rc=$?
assert "init master exits 0" [ "$rc" = 0 ]
assert "config dir recorded in the local fleet.conf (0600)" bash -c "grep -qx \"FLEET_CONFIG_DIR='$CFG'\" '$FLEET_HOME/fleet.conf' && [ \"\$(mode_of '$FLEET_HOME/fleet.conf')\" = 600 ]"
assert "init reports the config dir" printf '%s' "$out" | grep -q "config dir: $CFG"
assert "vault dir 0700" [ "$(mode_of "$FLEET_VAULT")" = 700 ]
assert "nodes/pending + nodes/claimed dirs 0700" bash -c "[ \"\$(mode_of '$FLEET_VAULT/nodes/pending')\" = 700 ] && [ \"\$(mode_of '$FLEET_VAULT/nodes/claimed')\" = 700 ]"
assert "master ssh key generated" [ -f "$FLEET_VAULT/ssh/fleet_master.pub" ]
assert "master ssh key 0600" [ "$(mode_of "$FLEET_VAULT/ssh/fleet_master")" = 600 ]
assert "digest.key created, 0600, 32 bytes hex" bash -c "[ \"\$(mode_of '$FLEET_VAULT/digest.key')\" = 600 ] && grep -Eqx '[0-9a-f]{64}' '$FLEET_VAULT/digest.key'"
assert "init asked for an API access token (keys page URL shown)" printf '%s' "$out" | grep -q 'login.tailscale.com/admin/settings/keys'
assert "live policy fetched with the bootstrap token" grep -q '^GET /api/v2/tailnet/-/acl' "$API_LOG"
assert "init reported the allow-all finding" printf '%s' "$out" | grep -q 'policy: grants rule lets \* reach the tailnet'
assert "init showed a unified diff mentioning tag:fleet-node" bash -c "printf '%s' \"\$0\" | grep -q '^+++ new policy' && printf '%s' \"\$0\" | grep -q 'tag:fleet-node'" "$out"
assert "policy POSTed with If-Match ETag" grep -Eq '^POST /api/v2/tailnet/-/acl .* If-Match="[0-9a-f]{12}"$' "$API_LOG"
assert "live policy now isolates the fleet tag (merged, not replaced)" python3 "$ROOT/lib/api.py" policy check "$ROOT/templates/tailscale-policy.hujson" "$ACL" tag:fleet-node
assert "merge kept the owner's allow-all as autogroup:member -> *" python3 -c 'import json,sys; g=json.load(open(sys.argv[1]))["grants"]; assert {"src":["autogroup:member"],"dst":["*"],"ip":["*"]} in g' "$ACL"
assert "previous policy backed up into the vault (0600)" bash -c "ls '$FLEET_VAULT'/policy-backups/*.hujson >/dev/null 2>&1 && [ \"\$(mode_of \$(ls '$FLEET_VAULT'/policy-backups/*.hujson | head -1))\" = 600 ]"
assert "OAuth client created: keyType client, scopes, tag" grep -q '^POST /api/v2/tailnet/-/keys {"keyType": "client", "description": "fleet master", "scopes": \["auth_keys", "devices:core", "policy_file:read"\], "tags": \["tag:fleet-node"\]}' "$API_LOG"
assert "tailscale.json 0600 with client id + secret" bash -c "[ \"\$(mode_of '$FLEET_VAULT/tailscale.json')\" = 600 ] && grep -q '\"oauth_client_id\": \"kclientCNTRL\"' '$FLEET_VAULT/tailscale.json' && grep -q '\"oauth_client_secret\": \"tskey-client-kclientCNTRL-FAKE\"' '$FLEET_VAULT/tailscale.json'"
assert "bootstrap token revoked by its embedded id" grep -q '^DELETE /api/v2/tailnet/-/keys/kboot$' "$API_LOG"
refute "bootstrap token never stored in the vault" grep -rq 'tskey-api' "$FLEET_VAULT"
refute "no bootstrap temp file left" bash -c "ls '$FLEET_VAULT'/.bootstrap.* 2>/dev/null | grep -q ."
assert "github.json has token (gh unavailable → fallback)" grep -q '"token": "ghtok"' "$FLEET_VAULT/github.json"
refute "init output never echoes secrets" printf '%s' "$out" | grep -Eq 'kboot-FAKE|tskey-client|ghtok'
case "$(uname -s)" in
  Darwin) assert "LaunchAgent written" [ -f "$HOME/Library/LaunchAgents/dev.fleet.reconcile.plist" ]
          assert "LaunchAgent interval 120" grep -q '<integer>120</integer>' "$HOME/Library/LaunchAgents/dev.fleet.reconcile.plist" ;;
  *)      assert "systemd timer written" [ -f "$HOME/.config/systemd/user/fleet-reconcile.timer" ] ;;
esac
key1=$(cat "$FLEET_VAULT/ssh/fleet_master.pub"); ts1=$(cat "$FLEET_VAULT/tailscale.json"); dk1=$(cat "$FLEET_VAULT/digest.key")
out=$(bash "$FLEET" init master </dev/null 2>&1); rc=$?
assert "init master idempotent (no prompts second time)" [ "$rc" = 0 ]
assert "init master keeps existing key, client and digest key" bash -c "[ \"\$(cat '$FLEET_VAULT/ssh/fleet_master.pub')\" = '$key1' ] && [ \"\$(cat '$FLEET_VAULT/tailscale.json')\" = '$ts1' ] && [ \"\$(cat '$FLEET_VAULT/digest.key')\" = '$dk1' ]"
assert "rerun checks policy with the OAuth client, quietly ok" printf '%s' "$out" | grep -q 'policy: live tailnet policy isolates tag:fleet-node'
# a missing config dir with a known FLEET_CONFIG_REPO is cloned after confirmation
git init -q --bare "$T/cfg-remote.git"; git -C "$CFG" push -q "$T/cfg-remote.git" HEAD:main
printf "FLEET_CONFIG_REPO='%s'\n" "$T/cfg-remote.git" >>"$FLEET_HOME/fleet.conf"
out=$(printf 'n\n' | bash "$FLEET" init master --config-dir "$T/cfg-clone" 2>&1); rc=$?
assert "declined clone: init dies, nothing cloned" bash -c "[ $rc != 0 ] && [ ! -d '$T/cfg-clone' ] && printf '%s' \"\$0\" | grep -q 'Clone $T/cfg-remote.git there'" "$out"
out=$(printf 'y\n' | bash "$FLEET" init master --config-dir "$T/cfg-clone" 2>&1); rc=$?
assert "accepted clone: init exits 0 and the config dir is a checkout of the repo" bash -c "[ $rc = 0 ] && [ -f '$T/cfg-clone/AGENTS.md' ] && [ \"\$(git -C '$T/cfg-clone' remote get-url origin)\" = '$T/cfg-remote.git' ]"
grep -v '^FLEET_CONFIG_REPO=' "$FLEET_HOME/fleet.conf" >"$T/lc"; cat "$T/lc" >"$FLEET_HOME/fleet.conf"
bash "$FLEET" init master --config-dir "$CFG" </dev/null >/dev/null 2>&1
assert "config dir switched back" grep -qx "FLEET_CONFIG_DIR='$CFG'" "$FLEET_HOME/fleet.conf"

# ======================================================================
echo "== secrets"
out=$(printf "s3cr3t'one\n" | bash "$FLEET" secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal 2>&1); rc=$?
assert "secrets set exits 0" [ "$rc" = 0 ]
refute "secrets set never prints value" printf '%s' "$out" | grep -q 's3cr3t'
assert "minimal.env 0600" [ "$(mode_of "$FLEET_VAULT/secrets/minimal.env")" = 600 ]
assert "value single-quoted with quote escaped" grep -Fxq "CLAUDE_CODE_OAUTH_TOKEN='s3cr3t'\\''one'" "$FLEET_VAULT/secrets/minimal.env"
assert "stored value round-trips through the shell" bash -c ". '$FLEET_VAULT/secrets/minimal.env'; [ \"\$CLAUDE_CODE_OAUTH_TOKEN\" = \"s3cr3t'one\" ]"
printf 'v2\n' | bash "$FLEET" secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal >/dev/null 2>&1
assert "secrets set replaces existing" [ "$(grep -c '^CLAUDE_CODE_OAUTH_TOKEN=' "$FLEET_VAULT/secrets/minimal.env")" = 1 ]
assert "replaced value is the new one" grep -Fxq "CLAUDE_CODE_OAUTH_TOKEN='v2'" "$FLEET_VAULT/secrets/minimal.env"
printf 'fullsecret\n' | bash "$FLEET" secrets set OPENAI_API_KEY >/dev/null 2>&1
assert "default profile is full" grep -q '^OPENAI_API_KEY=' "$FLEET_VAULT/secrets/full.env"
refute "invalid name rejected" bash -c "printf 'x\n' | bash '$FLEET' secrets set 'bad name'"
out=$(bash "$FLEET" secrets list 2>&1)
assert "secrets list shows name + profile" printf '%s' "$out" | grep -Eq '^CLAUDE_CODE_OAUTH_TOKEN +minimal$'
assert "secrets list shows full entry" printf '%s' "$out" | grep -Eq '^OPENAI_API_KEY +full$'
refute "secrets list never prints values" printf '%s' "$out" | grep -Eq 'v2|fullsecret'

# ======================================================================
echo "== files add"
mkdir -p "$HOME/repositories/x"; printf 'DB=1\n' >"$HOME/repositories/x/.env"
assert "files add exits 0" bash "$FLEET" files add "$HOME/repositories/x/.env"
assert "file mirrored under files/full" [ -f "$FLEET_VAULT/files/full/repositories/x/.env" ]
assert "mirrored file 0600" [ "$(mode_of "$FLEET_VAULT/files/full/repositories/x/.env")" = 600 ]
printf 'x\n' >"$T/outside.txt"
refute "files add refuses paths outside HOME" bash "$FLEET" files add "$T/outside.txt"

# ======================================================================
echo "== digest (HMAC over secret values + file contents, key never printed)"
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
assert "secret names unchanged" [ "$(grep -c '=' "$FLEET_VAULT/secrets/minimal.env")" = 1 ]
printf 'DB=2\n' >"$HOME/repositories/x/.env"; bash "$FLEET" files add "$HOME/repositories/x/.env" >/dev/null 2>&1
d3=$(digest_of full)
assert "digest changes when a mirrored file's content changes (path unchanged)" [ "$d3" != "$d2" ]
assert "minimal and full digests differ" [ "$(digest_of minimal)" != "$d3" ]
refute "digest does not leak the key" printf '%s' "$d3" | grep -q "$(cut -c1-16 "$FLEET_VAULT/digest.key")"

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
refute "digest.key never shipped" bash -c "find '$NH' -name digest.key | grep -q ."
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
chmod 0644 "$FLEET_VAULT/secrets/full.env"
refute "doctor fails on loose file mode" bash "$FLEET" doctor
chmod 0600 "$FLEET_VAULT/secrets/full.env"

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
assert "revoke + forget audited, secrets to rotate named" bash -c "grep -q ' revoke eph gone' '$FLEET_VAULT/audit.log' && grep -q ' forget eph gone' '$FLEET_VAULT/audit.log' && printf '%s' \"\$0\" | grep -q 'rotate the secrets it held: CLAUDE_CODE_OAUTH_TOKEN'" "$out"
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
assert "legacy int github_keys: deletes went to the configured repos; only the unreachable node's stop stays pending" bash -c "grep -q '^DELETE /repos/example/fleet-config/keys/501' '$API_LOG' && grep -q '^DELETE /repos/example/fleet-memory/keys/502' '$API_LOG' && [ \"\$(jget '$FLEET_VAULT/nodes/nM1CNTRL.json' pending_cleanup)\" = '[\"stop:nM1CNTRL\"]' ]"
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
echo "== GitHub CLI path (gh on PATH, no FLEET_GH_API): login, repo check, deploy keys via gh api; https code repo -> no code key"
HOME2="$T/master2"; mkdir -p "$HOME2/.config/fleet"
printf "FLEET_CODE_REPO='https://github.com/example/fleeter.git'\n" >"$HOME2/.config/fleet/fleet.conf"
gh_fleet() { env PATH="$T/ghbin:$PATH" FLEET_GH_API= HOME="$HOME2" FLEET_HOME="$HOME2/.config/fleet" FLEET_VAULT="$HOME2/.config/fleet/vault" FLEET_TS_STATUS_JSON="$T/status2.json" bash "$FLEET" "$@"; }
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
echo "== config publish (commits + pushes the config repo, never the code checkout)"
git -C "$CFG" remote add origin "$T/cfg-remote.git"; git -C "$CFG" push -q -u origin main 2>/dev/null
code_head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo none)
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
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
