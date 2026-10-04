#!/usr/bin/env bash
# End-to-end test of fleet with Docker nodes, no real Tailscale or GitHub.
#
#   bash tests/e2e.sh              build image, run everything (< 10 min), PASS/FAIL per step
#   E2E_FULL=1 bash tests/e2e.sh   image with FLEET_PREINSTALL=1 and real tool installs (slow, needs internet)
#   E2E_KEEP=1 bash tests/e2e.sh   keep containers/network/volume for inspection
#
# Topology (all Docker objects are prefixed fleet-e2e-, nothing else is touched):
#   fleet-e2e-net        user-defined bridge; container names resolve as DNS names
#   fleet-e2e-master     same image, `sleep infinity`; fleet runs as user `fleet` with
#                        FLEET_HOME in the container, a fake Tailscale+GitHub API
#                        (tests/e2e/fake_api.py) on 127.0.0.1:8899, and a generated
#                        `tailscale status --json` (FLEET_TS_STATUS_JSON)
#   fleet-e2e-node-a/b   node image in FAKE mode (FLEET_FAKE_TAILSCALE=1, fake
#                        `tailscale` from tests/e2e/ on PATH), real sshd, real `fleet join`
#                        and `fleet daemon` under the entrypoint supervisor
#   fleet-e2e-repos      volume with bare git repos: code (this checkout), config (the
#                        shipped example) and memory (templates/memory) remotes
#                        (FLEET_CODE_REMOTE / FLEET_CONFIG_REMOTE / FLEET_MEMORY_REMOTE overrides)
#
# Host side: bash 3.2 safe, nothing written outside this repo (tests/.e2e-work).
# shellcheck disable=SC2329  # helpers are invoked indirectly (assert/refute/bash -c)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
P=fleet-e2e
NET=$P-net; VOL=$P-repos; MASTER=$P-master; NA=$P-node-a; NB=$P-node-b
E2E_FULL=${E2E_FULL:-0}; E2E_KEEP=${E2E_KEEP:-0}
if [ "$E2E_FULL" = 1 ]; then IMG=${E2E_IMAGE:-$P-node:pre}; else IMG=${E2E_IMAGE:-$P-node:local}; fi
WORK="$ROOT/tests/.e2e-work"
API=http://127.0.0.1:8899
IDA=nALPHA0CNTRL; IDB=nBETA00CNTRL
MHOME=/home/fleet
VAULT=$MHOME/.config/fleet/vault
UPATH="$MHOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
T0=$(date +%s)

PASS=0; FAIL=0; PROV_PID=""
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
assert() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
refute() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }
step() { printf '\n== %s\n' "$*"; }
die() { printf 'error %s\n' "$*" >&2; exit 1; }

# ---------- docker helpers ----------

mexec()   { docker exec -u fleet -e HOME=$MHOME -e PATH="$UPATH" -e FLEET_TS_API=$API -e FLEET_GH_API=$API \
              -e FLEET_TS_STATUS_JSON=$MHOME/ts-status.json -e FLEET_NO_SCHEDULER=1 "$MASTER" "$@"; }
mexec_i() { docker exec -i -u fleet -e HOME=$MHOME -e PATH="$UPATH" -e FLEET_TS_API=$API -e FLEET_GH_API=$API \
              -e FLEET_TS_STATUS_JSON=$MHOME/ts-status.json -e FLEET_NO_SCHEDULER=1 "$MASTER" "$@"; }
mroot()   { docker exec "$MASTER" "$@"; }
nexec()   { local c=$1; shift; docker exec -u fleet -e HOME=$MHOME -e PATH="$UPATH" "$c" "$@"; }
nexec_i() { local c=$1; shift; docker exec -i -u fleet -e HOME=$MHOME -e PATH="$UPATH" "$c" "$@"; }
nroot()   { local c=$1; shift; docker exec "$c" "$@"; }
mfile()   { mexec cat "$1"; }                       # print a file from the master
nfile()   { nexec "$1" cat "$2"; }                  # print a file from a node
nmode()   { nexec "$1" stat -c %a "$2"; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
# wait_for SECONDS CMD... — poll until CMD succeeds.
wait_for() { local n=$1 i=0; shift; while [ "$i" -lt "$n" ]; do "$@" >/dev/null 2>&1 && return 0; sleep 1; i=$((i + 1)); done; return 1; }
jget() { python3 -c 'import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v[k]
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1"; }
b64json() { python3 -c 'import base64,json,sys; d=json.loads(base64.b64decode(sys.stdin.read().strip())); print(d.get(sys.argv[1],""))' "$1"; }
# Compound assertions run through `bash -c`, which only sees exported functions/vars.
export MASTER NA NB MHOME UPATH API VAULT IDA IDB WORK
export -f mexec mexec_i mroot nexec nexec_i nroot mfile nfile nmode running wait_for jget b64json

dump_logs() {
  local c
  for c in "$MASTER" "$NA" "$NB"; do
    docker inspect "$c" >/dev/null 2>&1 || continue
    printf '\n----- docker logs %s (tail) -----\n' "$c"; docker logs --tail 40 "$c" 2>&1
  done
  for f in reconcile1.log provision-slow.log kick.log; do
    [ -s "$WORK/$f" ] && { printf '\n----- %s -----\n' "$f"; tail -40 "$WORK/$f"; }
  done
}

cleanup() {
  local rc=$?
  [ -n "$PROV_PID" ] && kill "$PROV_PID" 2>/dev/null
  if [ "$FAIL" -gt 0 ] || [ "$rc" -ne 0 ]; then dump_logs; fi
  if [ "$E2E_KEEP" = 1 ]; then
    printf '\nE2E_KEEP=1: leaving %s %s %s, network %s, volume %s\n' "$MASTER" "$NA" "$NB" "$NET" "$VOL"
  else
    docker rm -f "$MASTER" "$NA" "$NB" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    docker volume rm "$VOL" >/dev/null 2>&1
    rm -rf "$WORK"
  fi
  printf '\n%d passed, %d failed in %ds\n' "$PASS" "$FAIL" "$(( $(date +%s) - T0 ))"
  # `exit` inside an EXIT trap sets the script's status; a bare test would not
  if [ "$FAIL" = 0 ] && [ "$rc" = 0 ]; then exit 0; else exit 1; fi
}
trap cleanup EXIT

# ======================================================================
command -v docker >/dev/null || die "docker is required"
docker info >/dev/null 2>&1 || die "docker daemon not reachable"
command -v python3 >/dev/null || die "python3 is required on the host"
mkdir -p "$WORK"
# leftovers from an aborted run (ours only, by name)
docker rm -f "$MASTER" "$NA" "$NB" >/dev/null 2>&1
docker network rm "$NET" >/dev/null 2>&1
docker volume rm "$VOL" >/dev/null 2>&1

step "build image $IMG (FLEET_PREINSTALL=$E2E_FULL)"
if docker build -q -f "$ROOT/docker/Dockerfile" --build-arg "FLEET_PREINSTALL=$E2E_FULL" -t "$IMG" "$ROOT" >"$WORK/build.log" 2>&1; then
  pass "image built"
else
  tail -30 "$WORK/build.log"; fail "image built"; exit 1
fi
refute "image has no sudo" docker run --rm "$IMG" sh -c 'command -v sudo'
refute "image has no ssh host keys" docker run --rm "$IMG" sh -c 'ls /etc/ssh/ssh_host_*_key'
refute "image has no tailscale state" docker run --rm "$IMG" sh -c 'ls /var/lib/tailscale/* 2>/dev/null | grep .'
# shellcheck disable=SC2016  # runs inside the container
assert "image user fleet uid 1000, bash, no password" docker run --rm "$IMG" sh -c '[ "$(id -u fleet)" = 1000 ] && grep -q "^fleet:x:1000:1000:.*:/bin/bash$" /etc/passwd && grep -q "^fleet:\*:" /etc/shadow'
assert "image: ~fleet/.config and ~fleet/.local owned by fleet" docker run --rm "$IMG" sh -c "[ \"\$(stat -c %U $MHOME/.config $MHOME/.local $MHOME/.ssh | sort -u)\" = fleet ]"
assert "image: fleet code present, templates + examples + the fleet skill, no tests, no .git, no config repo" docker run --rm "$IMG" sh -c '[ -x /opt/fleet/fleet ] && [ -f /opt/fleet/lib/master.sh ] && [ -d /opt/fleet/templates/memory ] && [ -f /opt/fleet/examples/fleet-config/AGENTS.md ] && [ -f /opt/fleet/skills/fleet/SKILL.md ] && [ ! -e /opt/fleet/tests ] && [ ! -e /opt/fleet/.git ] && [ ! -e /opt/fleet/examples/fleet-config/.git ]'
assert "image: chromium (agents' browser) baked in by default" docker run --rm "$IMG" sh -c 'command -v chromium >/dev/null && chromium --version | grep -q Chromium'
assert "image: chrome status sees the browser as the node user" docker run --rm -u fleet -e HOME=$MHOME "$IMG" sh -c 'cd /opt/fleet && FLEET_ROOT=/opt/fleet bash -c ". lib/common.sh; fleet_load_config; . lib/tools/chrome.sh; tool_chrome_status" | grep -q "chrome=1"'

step "network, volume, master container"
docker network create "$NET" >/dev/null || die "network create failed"
docker volume create "$VOL" >/dev/null || die "volume create failed"
docker run -d --name "$MASTER" --network "$NET" -v "$VOL:/srv/repos" -v "$ROOT/tests/e2e:/e2e:ro" "$IMG" sleep infinity >/dev/null \
  || die "master container failed to start"
mroot chown 1000:1000 /srv/repos
docker exec -d -u fleet -e HOME=$MHOME "$MASTER" python3 /e2e/fake_api.py 8899 $MHOME/api.log $MHOME/devices.json
assert "fake API up" wait_for 20 mexec python3 -c 'import socket; socket.create_connection(("127.0.0.1",8899),1)'
printf '[{"nodeId":"%s"},{"nodeId":"%s"}]\n' "$IDA" "$IDB" | mexec_i sh -c "cat > $MHOME/devices.json"
# bare remotes on the shared volume: memory (from templates/memory), code (the
# fleeter tree in the image) and config (the shipped example with example URLs);
# the master's config dir is a clone of config.git
# shellcheck disable=SC2016  # runs inside the container
mexec bash -ec '
  git config --global init.defaultBranch main; git config --global user.name e2e; git config --global user.email e2e@example.invalid
  git init -q --bare /srv/repos/memory.git
  t=$(mktemp -d); cp -R /opt/fleet/templates/memory/. "$t/"
  git -C "$t" init -q; git -C "$t" add -A; git -C "$t" commit -q -m "init vault"; git -C "$t" push -q /srv/repos/memory.git HEAD:main
  git init -q --bare /srv/repos/code.git
  t=$(mktemp -d); cp -R /opt/fleet/. "$t/"
  git -C "$t" init -q; git -C "$t" add -A; git -C "$t" commit -q -m "code v1"; git -C "$t" push -q /srv/repos/code.git HEAD:main
  git init -q --bare /srv/repos/config.git
  t=$(mktemp -d); cp -R /opt/fleet/examples/fleet-config/. "$t/"
  sed "s/YOU/example/g" /opt/fleet/examples/fleet-config/fleet.conf >"$t/fleet.conf"
  git -C "$t" init -q; git -C "$t" add -A; git -C "$t" commit -q -m "config v1"; git -C "$t" push -q /srv/repos/config.git HEAD:main
  git clone -q /srv/repos/config.git "$HOME/fleet-config"
  # the master runs fleet from a checkout of the code repo (like a real master), not from the image copy:
  # its code revision is then the one the nodes pull, and `fleet sync` can fast-forward it
  git clone -q /srv/repos/code.git "$HOME/fleeter"
  mkdir -p "$HOME/.local/bin"; ln -sfn "$HOME/fleeter/fleet" "$HOME/.local/bin/fleet"' \
  >"$WORK/seed.log" 2>&1
assert "memory + code + config bare repos seeded, master config dir cloned" bash -c "mexec git --git-dir=/srv/repos/memory.git cat-file -e main:INDEX.md && mexec git --git-dir=/srv/repos/code.git cat-file -e main:fleet && mexec test -f $MHOME/fleet-config/AGENTS.md"
assert "master runs fleet from its clone of the code repo" bash -c "[ \"\$(mexec sh -c 'command -v fleet')\" = $MHOME/.local/bin/fleet ] && mexec test -d $MHOME/fleeter/.git && mexec fleet --version | grep -q '^fleet '"

# ======================================================================
step "master init (non-interactive), secrets"
# the preflight wants a logged-in tailscale: the status file says Running before any peer exists
printf '{"BackendState":"Running","Self":{"ID":"nMASTERCNTRL","HostName":"master"},"Peer":{}}\n' | mexec_i sh -c "cat > $MHOME/ts-status.json"
# bootstrap API token (fake: tskey-api-kboot-FAKE), "apply" the policy template, GitHub token fallback (no gh in the image)
printf 'tskey-api-kboot-FAKE\napply\nghtok\n' | mexec_i fleet init master --config-dir $MHOME/fleet-config >"$WORK/init.log" 2>&1; rc=$?
assert "fleet init master exits 0" [ "$rc" = 0 ] || tail -5 "$WORK/init.log"
assert "init ran the preflight (tailscale, git identity)" grep -q 'preflight: commands present, Tailscale logged in, git identity e2e' "$WORK/init.log"
assert "config dir recorded in the master's local fleet.conf" bash -c "mfile $MHOME/.config/fleet/fleet.conf | grep -q \"^FLEET_CONFIG_DIR='$MHOME/fleet-config'\""
assert "vault 0700" [ "$(mexec stat -c %a $VAULT)" = 700 ]
assert "master ssh key generated" mexec test -f $VAULT/ssh/fleet_master.pub
assert "init minted the OAuth client and revoked the bootstrap token" bash -c "mfile $MHOME/api.log | grep -q '\"keyType\": \"client\"' && mfile $MHOME/api.log | grep -q '^DELETE /api/v2/tailnet/-/keys/kboot'"
refute "init never echoes secrets" grep -Eq 'kboot-FAKE|tskey-client|ghtok' "$WORK/init.log"
printf 'fake-oauth-token-e2e\n' | mexec_i fleet secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal >/dev/null 2>&1
printf 'fake-openai-key-e2e\n' | mexec_i fleet secrets set OPENAI_API_KEY --profile full >/dev/null 2>&1
assert "secrets stored (names only listed)" bash -c "mexec fleet secrets list | grep -Eq '^CLAUDE_CODE_OAUTH_TOKEN +minimal' && ! mexec fleet secrets list | grep -q fake-"
assert "minimal.env 0600" [ "$(mexec stat -c %a $VAULT/secrets/minimal.env)" = 600 ]

# ======================================================================
step "invite x2 (alpha: full, beta: ephemeral/minimal)"
CODE_A=$(mexec fleet invite --name alpha --code-only 2>"$WORK/invite-a.err"); rc=$?
assert "invite alpha --code-only exits 0" [ "$rc" = 0 ]
assert "--code-only prints exactly one line" [ "$(printf '%s\n' "$CODE_A" | wc -l | tr -d ' ')" = 1 ]
assert "code decodes: v1, name alpha, master_user fleet" bash -c "printf '%s' '$CODE_A' | python3 -c 'import base64,json,sys; d=json.loads(base64.b64decode(sys.stdin.read())); assert d[\"v\"]==1 and d[\"name\"]==\"alpha\" and d[\"master_user\"]==\"fleet\" and d[\"ts_auth_key\"].startswith(\"tskey-auth-\")'"
CODE_B=$(mexec fleet invite --ephemeral --name beta --code-only 2>/dev/null)
assert "invite beta --ephemeral --code-only" [ -n "$CODE_B" ]
assert "two pending invites" [ "$(mexec sh -c "ls $VAULT/nodes/pending/*.json | wc -l" | tr -d ' ')" = 2 ]
refute "vault never contains an auth key" mexec grep -rq tskey-auth $VAULT
MPUB=$(mfile $VAULT/ssh/fleet_master.pub)

# ======================================================================
step "nodes join (FAKE tailscale, real sshd, fleet join as user fleet)"
LOCAL_CONF='FLEET_MEMORY_REMOTE=/srv/repos/memory.git
FLEET_CODE_REMOTE=/srv/repos/code.git
FLEET_CONFIG_REMOTE=/srv/repos/config.git'
[ "$E2E_FULL" = 1 ] || LOCAL_CONF="$LOCAL_CONF
FLEET_TOOLS=\"\""
# The invite reaches the container the way docker/spawn.sh does it: a 0600 host
# file bind-mounted read-only + FLEET_INVITE_FILE, never an environment variable.
run_node() {   # run_node CONTAINER CODE
  (umask 077; printf '%s\n' "$2" >"$WORK/invite-$1")
  # fake tailscale state on a host dir: readable after the container exits
  # (docker cp on a stopped container fails once the invite file is deleted)
  mkdir -p "$WORK/ts-$1"; chmod 0777 "$WORK/ts-$1"
  docker run -d --name "$1" --network "$NET" --hostname "$1" -v "$VOL:/srv/repos" \
    -v "$ROOT/tests/e2e/fake-tailscale.sh:/usr/local/bin/tailscale:ro" \
    -v "$WORK/ts-$1:/tmp/fake-tailscale" \
    -v "$WORK/invite-$1:/run/fleet-invite:ro" -e FLEET_INVITE_FILE=/run/fleet-invite \
    -e FLEET_FAKE_TAILSCALE=1 -e FLEET_LOCAL_CONF="$LOCAL_CONF" "$IMG" >/dev/null
}
run_node "$NA" "$CODE_A" || die "node a failed to start"
run_node "$NB" "$CODE_B" || die "node b failed to start"
assert "node a: fleet daemon running" wait_for 60 nexec "$NA" test -f $MHOME/.config/fleet/daemon.pid
assert "node b: fleet daemon running" wait_for 60 nexec "$NB" test -f $MHOME/.config/fleet/daemon.pid
# joined: the host copies are no longer needed. Truncate before unlink, like
# spawn.sh: the bind-mounted inode stays readable in the container otherwise.
assert "node a: before scrub the (read-only) mount still holds the code" nroot "$NA" sh -c 'test -s /run/fleet-invite'
assert "node a: entrypoint could not truncate the read-only mount itself" bash -c "docker logs $NA 2>&1 | grep -q 'invite file /run/fleet-invite not writable'"
for c in "$NA" "$NB"; do : >"$WORK/invite-$c"; rm -f "$WORK/invite-$c"; done
assert "node a: mounted invite holds nothing readable after the host scrub" wait_for 10 nroot "$NA" sh -c '! cat /run/fleet-invite 2>/dev/null | grep -q .'
refute "node a: invite code not in docker inspect (env, args, mounts)" bash -c "docker inspect $NA | grep -qF '$CODE_A'"
refute "node a: no invite copy left in the container (/run/fleet)" nroot "$NA" sh -c 'ls /run/fleet/ 2>/dev/null | grep -q .'
assert "node a: /run/fleet-invite mount is root-only (0600)" bash -c "[ \"\$(nroot $NA stat -c %a /run/fleet-invite)\" = 600 ]"
assert "node a: join wrote enrol.json 0600" bash -c "[ \"\$(nmode $NA $MHOME/.config/fleet/enrol.json)\" = 600 ]"
assert "node a: enrol.json name=alpha container=true" bash -c "nfile $NA $MHOME/.config/fleet/enrol.json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"name\"]==\"alpha\" and d[\"container\"] is True and d[\"user\"]==\"fleet\"'"
assert "node a: nonce matches the invite" [ "$(nfile $NA $MHOME/.config/fleet/enrol.json | jget nonce)" = "$(printf '%s' "$CODE_A" | b64json nonce)" ]
assert "node a: master pubkey in authorized_keys (once)" [ "$(nfile $NA $MHOME/.ssh/authorized_keys | grep -cF "$MPUB")" = 1 ]
assert "node a: three deploy keys generated" nexec "$NA" sh -c "test -f $MHOME/.ssh/fleet_code.pub && test -f $MHOME/.ssh/fleet_config.pub && test -f $MHOME/.ssh/fleet_memory.pub"
assert "node a: ssh config has the three host aliases" bash -c "c=\$(nfile $NA $MHOME/.ssh/config); for h in code config memory; do printf '%s' \"\$c\" | grep -q \"Host github-fleet-\$h\" || exit 1; done"
assert "node a: fake tailscale up with tag+hostname" nroot "$NA" grep -q -- '^up --auth-key=file:.* --advertise-tags=tag:fleet-node --hostname=fleet-alpha$' /tmp/fake-tailscale/log
assert "node a: no auth-key temp file left" nroot "$NA" sh -c '! ls /tmp/fleet-join.* 2>/dev/null | grep -q .'
assert "node a: sshd running as root, key-only" nroot "$NA" sh -c 'pgrep -x sshd >/dev/null && grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config.d/fleet.conf'
assert "node a: tailscaled not started (fake mode)" nroot "$NA" sh -c '! pgrep -x tailscaled'
assert "node a: daemon runs as fleet, not root" nroot "$NA" sh -c "[ \"\$(ps -o user= -p \$(cat $MHOME/.config/fleet/daemon.pid))\" = fleet ]"
assert "node a: invite not in the daemon's environment (FLEET_INVITE_*)" nroot "$NA" sh -c "! tr '\\0' '\\n' < /proc/\$(cat $MHOME/.config/fleet/daemon.pid)/environ | grep -q FLEET_INVITE"
assert "node a: local fleet.conf written by entrypoint" nexec "$NA" grep -q '^FLEET_MEMORY_REMOTE=/srv/repos/memory.git' $MHOME/.config/fleet/fleet.conf
assert "node a: join log says waiting for master" bash -c "docker logs $NA 2>&1 | grep -q 'waiting for master'"

# fake tailnet view for the master: IDs are ours, DNS names are the container names
ipa=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NA")
ipb=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NB")
write_status() {   # write_status ONLINE_A ONLINE_B
  printf '{"BackendState":"Running","Self":{"ID":"nMASTERCNTRL","HostName":"master"},"Peer":{
 "p1":{"ID":"%s","HostName":"fleet-alpha","DNSName":"%s.","TailscaleIPs":["%s"],"Online":%s,"Tags":["tag:fleet-node"]},
 "p2":{"ID":"%s","HostName":"fleet-beta","DNSName":"%s.","TailscaleIPs":["%s"],"Online":%s,"Tags":["tag:fleet-node"]},
 "p3":{"ID":"nLAPTOPCNTRL","HostName":"laptop","DNSName":"laptop.","Online":true}}}\n' \
    "$IDA" "$NA" "$ipa" "$1" "$IDB" "$NB" "$ipb" "$2" | mexec_i sh -c "cat > $MHOME/ts-status.json"
}
write_status true true
assert "fleet nodes lists both as unknown before reconcile" bash -c "mexec fleet nodes | grep -Eq '^fleet-alpha +$IDA +yes +unknown' && mexec fleet nodes | grep -Eq '^fleet-beta +$IDB +yes +unknown'"

# ======================================================================
step "master reconcile enrols + provisions both nodes"
mexec fleet reconcile >"$WORK/reconcile1.log" 2>&1; rc=$?
assert "reconcile exits 0" [ "$rc" = 0 ]
assert "alpha registered by tailscale id, state provisioned" [ "$(mfile $VAULT/nodes/$IDA.json | jget state)" = provisioned ]
assert "beta registered, state provisioned, ephemeral, minimal" bash -c "[ \"\$(mfile $VAULT/nodes/$IDB.json | jget state)\" = provisioned ] && [ \"\$(mfile $VAULT/nodes/$IDB.json | jget ephemeral)\" = true ] && [ \"\$(mfile $VAULT/nodes/$IDB.json | jget profile)\" = minimal ]"
assert "registry copies os/arch/container from enrol.json" bash -c "[ \"\$(mfile $VAULT/nodes/$IDA.json | jget container)\" = true ] && [ \"\$(mfile $VAULT/nodes/$IDA.json | jget os)\" = linux ]"
assert "pending invites consumed" [ "$(mexec sh -c "ls $VAULT/nodes/pending/ | wc -l" | tr -d ' ')" = 0 ]
assert "fake GitHub: code + config keys read-only, memory key read-write, titled fleet-alpha-<id>" bash -c "mfile $MHOME/api.log | grep -q '^POST /repos/example/fleeter/keys .*\"title\": \"fleet-alpha-$IDA\".*\"read_only\": true' && mfile $MHOME/api.log | grep -q '^POST /repos/example/fleet-config/keys .*\"title\": \"fleet-alpha-$IDA\".*\"read_only\": true' && mfile $MHOME/api.log | grep -q '^POST /repos/example/fleet-memory/keys .*\"read_only\": false'"
assert "registry holds three key ids, each with the repo it was created on" bash -c "[ -n \"\$(mfile $VAULT/nodes/$IDA.json | jget github_keys.code.id)\" ] && [ \"\$(mfile $VAULT/nodes/$IDA.json | jget github_keys.config.repo)\" = example/fleet-config ] && [ \"\$(mfile $VAULT/nodes/$IDA.json | jget github_keys.memory.repo)\" = example/fleet-memory ]"
assert "provision pulled both repos on the node first (checkouts, not tar copies) and recorded the revs it applied" bash -c "nexec $NA test -d $MHOME/.local/share/fleet/.git && nexec $NA test -d $MHOME/.local/share/fleet-config/.git && [ -n \"\$(nfile $NA $MHOME/.config/fleet/applied_commit)\" ] && [ \"\$(mfile $VAULT/nodes/$IDA.json | jget applied_commit)\" = \"\$(nfile $NA $MHOME/.config/fleet/applied_commit)\" ]"
assert "deploy keys sent are the nodes' real pubkeys" bash -c "mfile $MHOME/api.log | grep -qF \"\$(nfile $NA $MHOME/.ssh/fleet_memory.pub | cut -d' ' -f2)\""
assert "audit log: enrol + provision for both" bash -c "a=\$(mfile $VAULT/audit.log); printf '%s' \"\$a\" | grep -q ' enrol alpha ok' && printf '%s' \"\$a\" | grep -q ' provision alpha ok' && printf '%s' \"\$a\" | grep -q ' provision beta ok'"
assert "fleet nodes shows alpha/beta provisioned, laptop ignored" bash -c "o=\$(mexec fleet nodes); printf '%s\n' \"\$o\" | grep -Eq '^alpha +$IDA +yes +provisioned +full' && printf '%s\n' \"\$o\" | grep -Eq '^beta +$IDB +yes +provisioned +minimal' && ! printf '%s' \"\$o\" | grep -q laptop"
assert "fleet nodes --live reaches both nodes" bash -c "o=\$(mexec fleet nodes --live); ! printf '%s' \"\$o\" | grep -q unreachable"
: >"$WORK/empty"
mexec fleet reconcile >"$WORK/reconcile2.log" 2>&1
assert "second reconcile is quiet (convergent)" [ ! -s "$WORK/reconcile2.log" ]
assert "init master installed the fleeter alias and the fleet skill on the master" bash -c "[ \"\$(mexec readlink $MHOME/.local/bin/fleeter)\" = $MHOME/fleeter/fleet ] && mexec fleeter --version | grep -q '^fleet ' && mexec test -f $MHOME/.claude/skills/fleet/SKILL.md"

# ======================================================================
step "fleet list: the one-shot overview, table and JSON"
mexec fleet list --json >"$WORK/list1.json" 2>"$WORK/list1.err"; rc=$?
assert "fleet list --json exits 0" [ "$rc" = 0 ] || cat "$WORK/list1.err"
assert "list --json: alpha and beta online, reachable, provisioned, synced yes (applied revs + digest = desired), memory ok, fleet version; laptop absent" python3 - "$WORK/list1.json" <<'EOF'
import json, sys
d = {x["name"]: x for x in json.load(open(sys.argv[1]))}
assert "laptop" not in d and not any(x["name"].startswith("laptop") for x in d.values())
for n in ("alpha", "beta"):
    x = d[n]
    assert x["online"] is True and x["reachable"] is True and x["state"] == "provisioned" and x["synced"] == "yes", (n, x["synced"], x["desired"], x["applied"])
    assert x["desired"]["code"] == x["applied"]["code"] and x["desired"]["config"] == x["applied"]["config"] and x["desired"]["digest"] == x["applied"]["digest"]
    assert x["applied"]["source"] == "node" and x["memory"] == "ok" and x["fleet"] and x["proxy"] == "off" and x["provisioned_age"]
assert d["alpha"]["profile"] == "full" and d["beta"]["profile"] == "minimal" and d["beta"]["ephemeral"] is True
EOF
assert "fleet list table: header and both rows (provisioned, synced yes)" bash -c "o=\$(mexec fleet list); printf '%s\n' \"\$o\" | head -1 | grep -Eq '^NAME +HOST +ONLINE +STATE +SYNCED +LAST PROVISION +TOOLS +MEMORY +PROXY +FLEET$' && printf '%s\n' \"\$o\" | grep -Eq '^alpha +fleet-alpha +yes +provisioned +yes +[0-9]+[mhd] ' && printf '%s\n' \"\$o\" | grep -Eq '^beta +fleet-beta +yes +provisioned +yes +[0-9]+[mhd] .* ok +off +[0-9.]+$'"
assert "fleet list --offline: no ssh, reachable null, synced from the registry" bash -c "mexec fleet list --offline --json | python3 -c 'import json,sys; d={x[\"name\"]: x for x in json.load(sys.stdin)}; assert d[\"alpha\"][\"reachable\"] is None and d[\"alpha\"][\"synced\"]==\"yes\" and d[\"alpha\"][\"applied\"][\"source\"]==\"registry\"'"

# ======================================================================
step "fleet sync: a config commit pushed from elsewhere is fast-forwarded on the master and provisioned to both nodes"
# shellcheck disable=SC2016  # runs inside the container
mexec bash -ec 'git clone -q /srv/repos/config.git "$HOME/cfg-other"
  printf "\n## sync\n\nconfig sync marker\n" >> "$HOME/cfg-other/AGENTS.md"
  git -C "$HOME/cfg-other" commit -qam "config via sync"; git -C "$HOME/cfg-other" push -q origin main' >"$WORK/cfg-other.log" 2>&1
CFG_SYNC=$(mexec git --git-dir=/srv/repos/config.git rev-parse main)
assert "the master's config checkout is behind the remote before sync" [ "$(mexec git -C $MHOME/fleet-config rev-parse HEAD)" != "$CFG_SYNC" ]
mexec fleet sync >"$WORK/sync1.log" 2>&1; rc=$?
assert "fleet sync exits 0" [ "$rc" = 0 ] || tail -20 "$WORK/sync1.log"
assert "sync fast-forwarded the master's config checkout (clean, behind) and left the code checkout alone (already current)" bash -c "grep -q 'config: .* -> .* (origin/main)' '$WORK/sync1.log' && ! grep -q 'code: .* -> ' '$WORK/sync1.log' && [ \"\$(mexec git -C $MHOME/fleet-config rev-parse HEAD)\" = '$CFG_SYNC' ] && [ -z \"\$(mexec git -C $MHOME/fleet-config status --porcelain)\" ]"
assert "sync provisioned both nodes with the new config: rendered CLAUDE.md carries the marker, registry applied_commit ends in the new config commit" bash -c "nfile $NA $MHOME/.claude/CLAUDE.md | grep -q 'config sync marker' && nfile $NB $MHOME/.claude/CLAUDE.md | grep -q 'config sync marker' && [ \"\${0#*+}\" = '$CFG_SYNC' ] && [ \"\${1#*+}\" = '$CFG_SYNC' ]" "$(mfile $VAULT/nodes/$IDA.json | jget applied_commit)" "$(mfile $VAULT/nodes/$IDB.json | jget applied_commit)"
assert "first sync pushed tool updates to both online nodes and recorded the run" bash -c "grep -q 'tools: fleet update on 2 node(s): 2 ok' '$WORK/sync1.log' && mexec python3 -c 'import json,sys; json.load(open(sys.argv[1]))[\"tools_pushed\"]' $VAULT/sync.json"
assert "audit: sync.ff config, sync.tools, provision alpha + beta ok" bash -c "a=\$(mfile $VAULT/audit.log); printf '%s' \"\$a\" | grep -q ' sync.ff config ' && printf '%s' \"\$a\" | grep -q ' sync.tools - 2/2 ok' && [ \"\$(printf '%s' \"\$a\" | grep -c ' provision alpha ok')\" -ge 2 ]"
assert "fleet list after sync: both synced yes again" bash -c "mexec fleet list --json | python3 -c 'import json,sys; d={x[\"name\"]: x for x in json.load(sys.stdin)}; assert d[\"alpha\"][\"synced\"]==\"yes\" and d[\"beta\"][\"synced\"]==\"yes\"'"
mexec fleet sync >"$WORK/sync2.log" 2>&1; rc=$?
assert "second sync: exit 0 and quiet (nothing to pull, nothing to provision, tools pushed recently)" bash -c "[ $rc = 0 ] && [ ! -s '$WORK/sync2.log' ]" || cat "$WORK/sync2.log"
assert "master lock released after sync" mexec sh -c "! test -e $VAULT/locks/.sync"

# ======================================================================
step "node state after provision"
for n in "$NA:alpha" "$NB:beta"; do
  c=${n%%:*}; name=${n#*:}
  assert "$name: secrets.env 0600 with the fake token" bash -c "[ \"\$(nmode $c $MHOME/.config/fleet/secrets.env)\" = 600 ] && nfile $c $MHOME/.config/fleet/secrets.env | grep -qx \"CLAUDE_CODE_OAUTH_TOKEN='fake-oauth-token-e2e'\""
  assert "$name: env.sh present, 0600, sources" bash -c "[ \"\$(nmode $c $MHOME/.config/fleet/env.sh)\" = 600 ] && nexec $c bash -c '. ~/.config/fleet/env.sh && [ \"\$FLEET_NODE\" = $name ] && [ \"\$CLAUDE_CODE_OAUTH_TOKEN\" = fake-oauth-token-e2e ]'"
  assert "$name: ~/.claude/CLAUDE.md rendered from the config repo's AGENTS.md (node name filled in)" bash -c "nfile $c $MHOME/.claude/CLAUDE.md | grep -q 'fleet node .$name.' && ! nfile $c $MHOME/.claude/CLAUDE.md | grep -q '\${FLEET_NODE}'"
  assert "$name: ~/.agents/skills non-empty, ~/.claude/skills too" nexec "$c" sh -c "[ \"\$(ls $MHOME/.agents/skills | wc -l)\" -gt 0 ] && [ \"\$(ls $MHOME/.claude/skills | wc -l)\" -gt 0 ] && [ -f $MHOME/.agents/skills/fleet-notes/SKILL.md ]"
  assert "$name: fleeter's fleet skill installed into the claude, agents and cursor skill dirs, recorded in the manifest" nexec "$c" sh -c "grep -q '^name: fleet$' $MHOME/.claude/skills/fleet/SKILL.md && [ -f $MHOME/.agents/skills/fleet/SKILL.md ] && [ -f $MHOME/.cursor/skills/fleet/SKILL.md ] && grep -qx $MHOME/.claude/skills/fleet $MHOME/.config/fleet/harness.manifest"
  assert "$name: ~/.local/bin/fleeter alias points at the installed checkout" [ "$(nexec "$c" readlink $MHOME/.local/bin/fleeter)" = "$MHOME/.local/share/fleet/fleet" ]
  assert "$name: ~/.codex/AGENTS.md + ~/.cursor/rules/fleet-global.mdc" nexec "$c" sh -c "test -s $MHOME/.codex/AGENTS.md && test -s $MHOME/.cursor/rules/fleet-global.mdc"
  assert "$name: code + config shipped, ~/.local/bin/fleet linked" nexec "$c" sh -c "test -x $MHOME/.local/share/fleet/fleet && test -f $MHOME/.local/share/fleet-config/AGENTS.md && [ \"\$(readlink $MHOME/.local/bin/fleet)\" = $MHOME/.local/share/fleet/fleet ]"
  assert "$name: rc block in .bashrc once" [ "$(nfile "$c" $MHOME/.bashrc | grep -c '# >>> fleet >>>')" = 1 ]
  assert "$name: memory vault cloned with nodes/$name" nexec "$c" sh -c "test -d $MHOME/fleet-memory/.git && test -d $MHOME/fleet-memory/nodes/$name"
  assert "$name: no master-side material on the node" nexec "$c" sh -c "! test -e $MHOME/.config/fleet/vault && ! test -e $MHOME/.ssh/fleet_master"
done
id_digest() { mfile "$VAULT/nodes/$1.json" | jget provisioned_digest; }
assert "alpha: applied digest equals registry digest" [ "$(nfile $NA $MHOME/.config/fleet/applied)" = "$(id_digest $IDA)" ]
assert "alpha (full) got OPENAI_API_KEY, beta (minimal) did not" bash -c "nfile $NA $MHOME/.config/fleet/secrets.env | grep -q '^OPENAI_API_KEY=' && ! nfile $NB $MHOME/.config/fleet/secrets.env | grep -q '^OPENAI_API_KEY='"
nexec "$NA" fleet status --json >"$WORK/status-a.json" 2>/dev/null
assert "alpha: fleet status --json: name, memory ok, daemon timers on" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["name"]=="alpha" and d["container"] and d["memory"]["state"]=="ok" and d["timers"]["pull"] and d["applied"]' "$WORK/status-a.json"
assert "alpha: token age reported for CLAUDE_CODE_OAUTH_TOKEN" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "CLAUDE_CODE_OAUTH_TOKEN" in d["token_age_days"]' "$WORK/status-a.json"

# ======================================================================
step "shared memory: alpha writes, beta reads (and back)"
nexec_i "$NA" sh -c "cat > $MHOME/fleet-memory/nodes/alpha/e2e-note.md" <<'EOF'
---
node: alpha
created: 2026-10-03
tags: [e2e]
---
# e2e note from alpha

alpha-secret-handshake-42
EOF
nexec "$NA" fleet memory sync >"$WORK/sync-a1.log" 2>&1; rc=$?
assert "alpha: memory sync exits 0" [ "$rc" = 0 ]
assert "remote has nodes/alpha/e2e-note.md" mexec git --git-dir=/srv/repos/memory.git cat-file -e main:nodes/alpha/e2e-note.md
assert "remote commit touches only nodes/alpha" bash -c "mexec git --git-dir=/srv/repos/memory.git show --name-only --format= main | grep -v '^nodes/alpha/' | grep -q . && exit 1; exit 0"
refute "beta does not have alpha's note yet" nexec "$NB" test -f $MHOME/fleet-memory/nodes/alpha/e2e-note.md
nexec "$NB" fleet memory sync >"$WORK/sync-b1.log" 2>&1; rc=$?
assert "beta: memory sync exits 0" [ "$rc" = 0 ]
assert "beta sees alpha's note (cross-node sharing)" bash -c "nfile $NB $MHOME/fleet-memory/nodes/alpha/e2e-note.md | grep -q alpha-secret-handshake-42"
nexec "$NB" sh -c "printf '# beta\n\nbeta-reply-7\n' > $MHOME/fleet-memory/nodes/beta/reply.md"
nexec "$NB" fleet memory sync >/dev/null 2>&1
nexec "$NA" fleet memory sync >/dev/null 2>&1
assert "alpha sees beta's reply" bash -c "nfile $NA $MHOME/fleet-memory/nodes/beta/reply.md | grep -q beta-reply-7"
assert "beta: memory.state ok with last_sync" bash -c "nfile $NB $MHOME/.config/fleet/memory.state | grep -q '^state=ok' && nfile $NB $MHOME/.config/fleet/memory.state | grep -q '^last_sync='"

# ======================================================================
step "trust model: nodes cannot reach the master"
assert "master: no sshd running" mroot sh -c '! pgrep -x sshd'
assert "master: nothing listening on 22" mroot python3 -c 'import socket; s=socket.socket(); s.settimeout(1); r=s.connect_ex(("127.0.0.1",22)); s.close(); raise SystemExit(0 if r else 1)'
assert "master: no authorized_keys for nodes" mroot sh -c "! test -s $MHOME/.ssh/authorized_keys && ! test -s /root/.ssh/authorized_keys"
refute "beta cannot ssh into the master" nexec "$NB" ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no "fleet@$MASTER" true
refute "beta cannot curl the master on 22" nexec "$NB" curl -s -m 3 "http://$MASTER:22/"
refute "beta cannot ssh into alpha either" nexec "$NB" ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no "fleet@$NA" true
assert "master can ssh into beta (push only)" mexec ssh -i $VAULT/ssh/fleet_master -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "fleet@$NB" true
refute "root login on nodes is refused" mexec ssh -i $VAULT/ssh/fleet_master -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$NB" true

# ======================================================================
step "kick alpha during a running provision"
# a slow tool on the node makes `fleet apply` (hence the master's provision) hang
nexec_i "$NA" sh -c "cat > $MHOME/.local/share/fleet/lib/tools/e2eslow.sh" <<'EOF'
# shellcheck shell=bash
tool_e2eslow_install() { sleep 120; }
tool_e2eslow_update() { :; }
tool_e2eslow_status() { echo "ok slow"; }
EOF
nexec "$NA" sh -c "printf 'FLEET_TOOLS=\"e2eslow\"\n' >> $MHOME/.config/fleet/fleet.conf"
mexec fleet provision alpha >"$WORK/provision-slow.log" 2>&1 &
PROV_PID=$!
assert "provision holds the master lock and the node apply lock" wait_for 40 sh -c "docker exec $MASTER test -f $VAULT/locks/$IDA/pid && docker exec $NA test -d $MHOME/.config/fleet/locks/apply"
KD=$(mfile $VAULT/nodes/$IDA.json | jget github_keys.code.id); KC=$(mfile $VAULT/nodes/$IDA.json | jget github_keys.config.id); KM=$(mfile $VAULT/nodes/$IDA.json | jget github_keys.memory.id)
mexec fleet kick alpha --yes >"$WORK/kick.log" 2>&1; rc=$?
assert "kick exits 0" [ "$rc" = 0 ]
wait "$PROV_PID" 2>/dev/null; prc=$?; PROV_PID=""
assert "in-flight provision was killed (non-zero exit)" [ "$prc" != 0 ]
assert "master lock released" mexec sh -c "! test -e $VAULT/locks/$IDA"
assert "registry: alpha revoked" [ "$(mfile $VAULT/nodes/$IDA.json | jget state)" = revoked ]
assert "fake API saw device DELETE" bash -c "mfile $MHOME/api.log | grep -q '^DELETE /api/v2/device/$IDA'"
assert "fake API saw all three deploy-key DELETEs" bash -c "mfile $MHOME/api.log | grep -q '^DELETE /repos/example/fleeter/keys/$KD' && mfile $MHOME/api.log | grep -q '^DELETE /repos/example/fleet-config/keys/$KC' && mfile $MHOME/api.log | grep -q '^DELETE /repos/example/fleet-memory/keys/$KM'"
assert "kick reports remote stop ok and lists secrets to rotate" bash -c "grep -q 'remote stop: ok' '$WORK/kick.log' && grep -q 'Rotate these secrets.*CLAUDE_CODE_OAUTH_TOKEN' '$WORK/kick.log'"
assert "audit: kick alpha done stop=ok ts=ok gh=ok" bash -c "mfile $VAULT/audit.log | grep -q ' kick alpha done stop=ok ts=ok gh=ok'"
assert "alpha: daemon stopped, container exited cleanly" bash -c "i=0; while [ \$i -lt 30 ] && [ \"\$(docker inspect -f '{{.State.Running}}' $NA)\" = true ]; do sleep 1; i=\$((i+1)); done; [ \"\$(docker inspect -f '{{.State.Running}}' $NA)\" = false ] && [ \"\$(docker inspect -f '{{.State.ExitCode}}' $NA)\" = 0 ]"
assert "alpha: tailscale logout ran (fleet leave + supervisor)" grep -q '^logout' "$WORK/ts-$NA/log"
assert "alpha: supervisor logged the shutdown" bash -c "docker logs $NA 2>&1 | grep -q 'logging out of the tailnet'"
refute "alpha: leave stopped the daemon itself (supervisor pidfile workaround not needed)" bash -c "docker logs $NA 2>&1 | grep -q 'daemon.pid removed'"
assert "alpha: daemon ran its own guarded leave once" bash -c "docker logs $NA 2>&1 | grep -c 'fleet daemon stopping' | grep -qx 1"
refute "provision refuses the revoked node" mexec fleet provision alpha
write_status false true
: >"$WORK/reconcile3.log"; mexec fleet reconcile >"$WORK/reconcile3.log" 2>&1; rc=$?
assert "reconcile after kick: exits 0, skips alpha, beta untouched" bash -c "[ $rc = 0 ] && ! grep -q alpha '$WORK/reconcile3.log' && [ \"\$(mfile $VAULT/nodes/$IDB.json | jget state)\" = provisioned ]"

# ======================================================================
step "beta: fleet pull converts the shipped copies into checkouts of the code and config repos"
nexec "$NB" fleet pull >"$WORK/pull-b.log" 2>&1; rc=$?
assert "fleet pull exits 0" [ "$rc" = 0 ]
assert "FLEET_SHARE is now a git checkout of /srv/repos/code.git" bash -c "nexec $NB git -C $MHOME/.local/share/fleet remote get-url origin | grep -q '^/srv/repos/code.git$'"
assert "config dir is now a git checkout of /srv/repos/config.git" bash -c "nexec $NB git -C $MHOME/.local/share/fleet-config remote get-url origin | grep -q '^/srv/repos/config.git$'"
assert "status reports code_commit, config_commit and applied_commit = code+config" bash -c "nexec $NB fleet status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"code_commit\"] and d[\"config_commit\"] and d[\"applied_commit\"] == d[\"code_commit\"] + \"+\" + d[\"config_commit\"]'"
# a config push is applied by the master's next provision (the node has a
# checkout now, so nothing is shipped: provision runs `fleet pull --no-apply`
# on the node first), and picked up by the node's own pull without the master
mexec bash -ec "printf '\n## e2e\n\nconfig v2 marker\n' >> $MHOME/fleet-config/AGENTS.md"
mexec fleet config publish --no-capture --yes >"$WORK/config-publish.log" 2>&1; rc=$?
assert "fleet config publish --yes commits and pushes the config repo (secret scan ran)" bash -c "[ $rc = 0 ] && grep -q 'secret scan' '$WORK/config-publish.log' && grep -q 'pushed to' '$WORK/config-publish.log' && mexec git --git-dir=/srv/repos/config.git log -1 --format=%s main | grep -q 'publish fleet config'"
assert "publish printed the diff of the change" grep -q '^+config v2 marker' "$WORK/config-publish.log"
mexec fleet provision beta >"$WORK/provision-b.log" 2>&1; rc=$?
assert "provision after a config push exits 0" [ "$rc" = 0 ] || tail -20 "$WORK/provision-b.log"
assert "provision pulled the config checkout on the node (no tar re-ship) and rendered the new CLAUDE.md" bash -c "grep -q 'config: .* -> ' '$WORK/provision-b.log' && nfile $NB $MHOME/.claude/CLAUDE.md | grep -q 'config v2 marker'"
assert "registry applied_commit = what the node applied = the pushed config commit" bash -c "ac=\$(mfile $VAULT/nodes/$IDB.json | jget applied_commit); [ \"\$ac\" = \"\$(nfile $NB $MHOME/.config/fleet/applied_commit)\" ] && [ \"\${ac#*+}\" = \"\$(mexec git --git-dir=/srv/repos/config.git rev-parse main)\" ]"
assert "the node's digest matches the registry (reconcile is convergent after provision)" [ "$(nfile $NB $MHOME/.config/fleet/applied)" = "$(id_digest $IDB)" ]
assert "pull is quiet when nothing changed" [ -z "$(nexec "$NB" fleet pull 2>&1)" ]
mexec bash -ec "printf '\nconfig v3 marker\n' >> $MHOME/fleet-config/AGENTS.md"
mexec fleet config publish --no-capture --yes >/dev/null 2>&1
nexec "$NB" fleet pull >"$WORK/pull-b2.log" 2>&1; rc=$?
assert "pull after a config push exits 0 and re-renders CLAUDE.md" bash -c "[ $rc = 0 ] && nfile $NB $MHOME/.claude/CLAUDE.md | grep -q 'config v3 marker'"

# ======================================================================
step "beta: docker stop -> TERM handled, leave + logout, clean exit"
docker stop -t 15 "$NB" >/dev/null 2>&1
assert "beta exited 0 within the grace period" [ "$(docker inspect -f '{{.State.ExitCode}}' "$NB")" = 0 ]
assert "beta: tailscale logout on stop" grep -q '^logout' "$WORK/ts-$NB/log"
assert "beta: daemon.pid removed by leave" bash -c "! docker cp $NB:$MHOME/.config/fleet/daemon.pid - >/dev/null 2>&1"

exit 0
