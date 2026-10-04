# shellcheck shell=bash
# shellcheck disable=SC2016  # the T3_NODE_*_SH scripts are expanded by the node's shell, not ours
# T3 Code remote access (master side): let the master's T3 Code desktop app use
# a node's T3 server through T3's own "SSH environment" type. Sourced by
# ./fleet after lib/master.sh. Functions only.
#
# What T3 does once an SSH environment exists (pingdotgg/t3code 0.0.45,
# packages/ssh/src/tunnel.ts and command.ts): `ssh -G <alias>` to resolve the
# target, `ssh <alias> sh -l -s -- <key>` with a launch script on stdin that
# reuses the server recorded in ~/.t3/userdata/server-runtime.json or starts
# `t3 serve --host 127.0.0.1` from a release archive it installs under
# ~/.t3/runtime/versions/<app version>/ (curl|wget + tar, no Node), then
# `ssh <alias> sh -s` with `t3 auth pairing create --json`, and finally
# `ssh -N -L <local>:127.0.0.1:<remote> <alias>`; the pairing token is
# exchanged over the tunnel at POST /oauth/token for a 30-day session.
#
# fleet provides what that flow needs and nothing more:
#   vault/ssh/t3_client        dedicated ed25519 key (never the fleet master key)
#   node authorized_keys       that key with T3_CLIENT_KEY_OPTIONS (lib/common.sh)
#   vault/ssh/known_hosts      the node's host key, read from inside the fleet
#                              session, so every later ssh is strict
#   ~/.ssh/config.d/fleet      one `Host fleet-<name>` block per node, included
#                              from the top of ~/.ssh/config
# Adding the environment in the desktop app stays manual: its connection
# catalogue is encrypted with Electron safeStorage and has no CLI or deep link.
#
# Portability: bash 3.2, no GNU-only flags, no sed -i, no timeout. The only
# T3 secrets involved (pairing tokens) are created and consumed by T3 itself;
# fleet never prints, stores or passes one in argv.

t3_client_key()   { echo "$FLEET_VAULT/ssh/t3_client"; }
known_hosts_file() { echo "$FLEET_VAULT/ssh/known_hosts"; }
t3_ssh_include()  { echo "$HOME/.ssh/config.d/fleet"; }
t3_include_line() { echo "Include ~/.ssh/config.d/fleet"; }

# t3_client_key_ensure — vault/ssh/t3_client (ed25519, no passphrase, 0600).
t3_client_key_ensure() {
  local k
  k=$(t3_client_key)
  mkdir -p "$FLEET_VAULT/ssh"; chmod 0700 "$FLEET_VAULT/ssh"
  if [ ! -f "$k" ]; then
    need ssh-keygen
    ssh-keygen -q -t ed25519 -N '' -C "$T3_CLIENT_KEY_COMMENT" -f "$k" </dev/null || die "ssh-keygen failed for $k"
    ok "generated T3 client key $k"
    audit "t3.key" "-" created
  fi
  chmod 0600 "$k"; chmod 0644 "$k.pub"
}

# ---------- pinned host keys ----------

# known_hosts_key HOST — "<type> <key>" pinned for HOST, or nothing. Only plain
# entries count (no hashed `|1|` lines, no @cert-authority/@revoked markers).
known_hosts_key() {
  [ -f "$(known_hosts_file)" ] || return 0
  awk -v h="$1" '$1 !~ /^[#|@]/ { n = split($1, a, ","); for (i = 1; i <= n; i++) if (a[i] == h) { print $2, $3; exit } }' "$(known_hosts_file)"
}

# known_hosts_has HOST — true once HOST is pinned.
known_hosts_has() { [ -n "$(known_hosts_key "$1")" ]; }

# known_hosts_set HOST "<type> <key>" — pin HOST (its old entries dropped, every
# other host kept), 0600.
known_hosts_set() {
  local f host=$1 keyline=$2
  f=$(known_hosts_file)
  { [ -f "$f" ] && awk -v h="$host" '{ keep = 1; n = split($1, a, ","); for (i = 1; i <= n; i++) { if (a[i] == h) keep = 0 }; if (keep) print }' "$f"
    printf '%s %s\n' "$host" "$keyline"; } | atomic_write "$f" 0600
}

# ssh_strict_mode HOST — StrictHostKeyChecking for HOST: `yes` once pinned,
# `accept-new` for the very first contact (TOFU over WireGuard, see
# docs/SECURITY.md); host_key_pin then confirms what that contact stored.
ssh_strict_mode() { if known_hosts_has "$1"; then echo yes; else echo accept-new; fi; }

# host_key_pin USER HOST — read HOST's ed25519 host key from inside the
# already-authenticated fleet session (no ssh-keyscan) and pin it in
# vault/ssh/known_hosts. When the first contact already recorded the key the
# wire presented, the two must agree: a mismatch is left alone and reported.
host_key_pin() {
  local user=$1 host=$2 pub type key seen was
  was=$(known_hosts_key "$host")
  pub=$(ssh_to "$user" "$host" 'cat /etc/ssh/ssh_host_ed25519_key.pub' </dev/null 2>/dev/null) || { warn "$host: could not read its ssh host key; not pinned"; return 1; }
  [ -f "$(known_hosts_file)" ] && chmod 0600 "$(known_hosts_file)"    # ssh's own accept-new write is 0644
  type=${pub%% *}; key=${pub#* }; key=${key%% *}
  if [ "$type" != ssh-ed25519 ] || ! printf '%s' "$key" | grep -Eq '^AAAA[A-Za-z0-9+/=]{20,}$'; then
    warn "$host: unexpected host key line; not pinned"; return 1
  fi
  # what the wire presented: the pin from before, or what accept-new just stored
  seen=$(known_hosts_key "$host")
  if [ -n "$seen" ] && [ "$seen" != "ssh-ed25519 $key" ]; then
    warn "HOST KEY MISMATCH for $host: the key this session saw differs from the key on the node; $(known_hosts_file) left unchanged"
    audit hostkey "$host" mismatch
    return 1
  fi
  [ "$was" = "ssh-ed25519 $key" ] && return 0
  known_hosts_set "$host" "ssh-ed25519 $key"      # rewrites 0600 (ssh's own accept-new write is 0644)
  audit hostkey "$host" pinned
  ok "pinned host key of $host (read from the node over the authenticated session)"
}

# ---------- the master's ssh config include ----------

# t3_ssh_config_render — the include file: one block per registered node that
# is not revoked, has T3 access, and whose host key is pinned (a block for an
# unpinned node could only fail with StrictHostKeyChecking yes).
t3_ssh_config_render() {
  local id name user host
  printf '# managed by fleet (fleet t3 setup, fleet reconcile): regenerated from the node registry, edits are lost\n'
  for id in $(registry_ids); do
    node_revoked "$id" && continue
    [ "$(registry_get "$id" t3_access)" = false ] && continue
    name=$(registry_get "$id" name); user=$(registry_get "$id" user); host=$(registry_get "$id" dnsname)
    [ -n "$name" ] && [ -n "$user" ] && [ -n "$host" ] || continue
    known_hosts_has "$host" || continue
    printf '\nHost fleet-%s\n  HostName %s\n  User %s\n  IdentityFile "%s"\n  IdentitiesOnly yes\n  UserKnownHostsFile "%s"\n  StrictHostKeyChecking yes\n  HostKeyAlgorithms ssh-ed25519\n  HashKnownHosts no\n  ForwardAgent no\n  ForwardX11 no\n' \
      "$name" "$host" "$user" "$(t3_client_key)" "$(known_hosts_file)"
  done
}

# t3_ssh_config_write — regenerate ~/.ssh/config.d/fleet (0600) when it differs,
# and put `Include ~/.ssh/config.d/fleet` at the top of ~/.ssh/config once
# (original backed up as config.pre-fleet; created 0600 when missing). A no-op
# until the T3 client key exists, and ~/.ssh is left alone entirely while
# there is no node to write a block for and no include file from before.
t3_ssh_config_write() {
  local inc cfg want cur mode=0600 n
  [ -f "$(t3_client_key)" ] || return 0
  inc=$(t3_ssh_include); cfg="$HOME/.ssh/config"
  want=$(t3_ssh_config_render)
  n=$(printf '%s\n' "$want" | grep -c '^Host ' || true)
  [ "$n" -gt 0 ] || [ -f "$inc" ] || return 0
  mkdir -p "$HOME/.ssh" "$(dirname "$inc")"; chmod 700 "$HOME/.ssh" "$(dirname "$inc")"
  cur=$(cat "$inc" 2>/dev/null || true)
  if [ "$want" != "$cur" ]; then
    printf '%s\n' "$want" | atomic_write "$inc" 0600
    ok "wrote $inc ($(grep -c '^Host ' "$inc") node(s))"
  fi
  if [ -f "$cfg" ] && grep -qxF "$(t3_include_line)" "$cfg"; then return 0; fi
  if [ -f "$cfg" ]; then backup_once "$cfg"; mode=$(mode_of "$cfg"); fi
  { t3_include_line; [ -f "$cfg" ] && cat "$cfg"; } | atomic_write "$cfg" "$mode"
  ok "added '$(t3_include_line)' at the top of $cfg"
}

# ---------- node side, over the fleet master key ----------

# t3_authorize_node ID / t3_deauthorize_node ID — converge the T3 client key
# line in the node's ~/.ssh/authorized_keys (T3_AUTHKEY_SCRIPT, lib/common.sh).
t3_authorize_node() {
  t3_authorized_line "$(t3_client_key).pub" | node_ssh "$1" "sh -c '$T3_AUTHKEY_SCRIPT'"
}
t3_deauthorize_node() {
  printf '\n' | node_ssh "$1" "sh -c '$T3_AUTHKEY_SCRIPT'"
}

# The node's t3 CLI: the newest release archive T3 installed for its SSH flow
# (~/.t3/runtime/versions/<v>/t3, complete installs only), else a `t3` on PATH.
# POSIX sh, sent on stdin to `sh -s`.
T3_NODE_CLI_SH='t3=""
for f in "$HOME"/.t3/runtime/versions/*/t3; do
  [ -x "$f" ] && [ -s "$(dirname "$f")/.install-complete" ] && t3=$f
done
if [ -z "$t3" ] && command -v t3 >/dev/null 2>&1; then t3=$(command -v t3); fi'

# Prints the node's T3 auth sessions and pairing tokens as JSON (metadata only:
# T3's list commands never include a token), or {"error":...}.
T3_NODE_LIST_SH="$T3_NODE_CLI_SH"'
[ -n "$t3" ] || { printf "%s\n" "{\"error\":\"no t3 cli on the node (T3 installs it on first connect)\"}"; exit 0; }
printf "{\"sessions\":"
"$t3" auth session list --base-dir "$HOME/.t3" --json 2>/dev/null || printf "[]"
printf ",\"pairings\":"
"$t3" auth pairing list --base-dir "$HOME/.t3" --json 2>/dev/null || printf "[]"
printf "}\n"'

# Revokes every session that came from a pairing token (subject one-time-token:
# what T3 desktop clients and `t3 auth pairing create` produce; the node's own
# desktop app session, subject desktop-bootstrap, stays), every live pairing
# token, and stops the managed servers T3 started over ssh (state under
# ~/.t3/ssh-launch; a server the node's desktop app owns is "external" and
# never touched). Prints one line per action; never a token.
T3_NODE_REVOKE_SH="$T3_NODE_CLI_SH"'
if [ -n "$t3" ] && command -v python3 >/dev/null 2>&1; then
  "$t3" auth session list --base-dir "$HOME/.t3" --json 2>/dev/null | python3 -c "
import json, sys
try: items = json.load(sys.stdin)
except Exception: items = []
for s in items:
    if s.get(\"subject\") == \"one-time-token\": print(s.get(\"sessionId\", \"\"))" | while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    "$t3" auth session revoke --base-dir "$HOME/.t3" "$sid" >/dev/null 2>&1 && echo "revoked session $sid"
  done
  "$t3" auth pairing list --base-dir "$HOME/.t3" --json 2>/dev/null | python3 -c "
import json, sys
try: items = json.load(sys.stdin)
except Exception: items = []
for p in items: print(p.get(\"id\", \"\"))" | while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    "$t3" auth pairing revoke --base-dir "$HOME/.t3" "$pid" >/dev/null 2>&1 && echo "revoked pairing $pid"
  done
elif [ -n "$t3" ]; then
  echo "no python3 on the node: sessions not revoked"
else
  echo "no t3 cli on the node: nothing to revoke"
fi
for d in "$HOME"/.t3/ssh-launch/*/; do
  [ -f "$d/pid" ] || continue
  [ "$(cat "$d/managed" 2>/dev/null)" = managed ] || continue
  pid=$(cat "$d/pid")
  case "$(ps -o command= -p "$pid" 2>/dev/null)" in
    *t3*serve*) kill "$pid" 2>/dev/null && echo "stopped managed t3 server pid $pid port $(cat "$d/port" 2>/dev/null)" ;;
  esac
  rm -f "$d/pid" "$d/port" "$d/managed"
done'

# Discovery over the T3 client key, exactly as T3 would run it (`sh -l -s`,
# script on stdin, no pty): what the SSH flow will find on the node.
T3_NODE_PROBE_SH='missing=""
command -v tar >/dev/null 2>&1 || missing="$missing tar"
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || missing="$missing curl/wget"
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || missing="$missing sha256sum/shasum"
printf "arch %s-%s\n" "$(uname -s | tr "[:upper:]" "[:lower:]")" "$(uname -m)"
printf "prereq %s\n" "${missing:-ok}"
r=""
for d in "$HOME"/.t3/runtime/versions/*/; do [ -x "$d/t3" ] && [ -s "$d/.install-complete" ] && r="$r $(basename "$d")"; done
printf "runtime%s\n" "${r:- none}"
f="$HOME/.t3/userdata/server-runtime.json"
if [ -f "$f" ] && command -v python3 >/dev/null 2>&1; then
  python3 -c "
import json, os, sys
try:
    d = json.load(open(sys.argv[1])); pid = int(d[\"pid\"]); port = int(d[\"port\"]); os.kill(pid, 0)
    print(\"server external pid %d port %d\" % (pid, port))
except Exception:
    print(\"server none\")" "$f"
else
  echo "server none"
fi
for d in "$HOME"/.t3/ssh-launch/*/; do
  [ -f "$d/pid" ] || continue
  pid=$(cat "$d/pid"); kill -0 "$pid" 2>/dev/null && printf "managed pid %s port %s\n" "$pid" "$(cat "$d/port" 2>/dev/null)"
done
exit 0'

# t3_node_revoke ID — the node side of `fleet t3 revoke` and `fleet kick`:
# sessions, pairings, managed servers, then the authorized_keys line.
t3_node_revoke() {
  local id=$1 out
  out=$(printf '%s\n' "$T3_NODE_REVOKE_SH" | node_ssh "$id" sh -s 2>/dev/null) || return 1
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/  /' >&2
  t3_deauthorize_node "$id"
}

# t3_print_sessions JSON — one line per session and pairing token, no secrets.
t3_print_sessions() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("  sessions: unreadable"); sys.exit(0)
if d.get("error"):
    print("  sessions: %s" % d["error"]); sys.exit(0)
ss, ps = d.get("sessions") or [], d.get("pairings") or []
print("  sessions: %d (%d from pairing tokens), pairing tokens: %d" % (len(ss), sum(1 for s in ss if s.get("subject") == "one-time-token"), len(ps)))
ss = sorted(ss, key=lambda s: str(s.get("issuedAt", "")), reverse=True)
for s in ss[:12]:
    c = s.get("client") or {}
    who = " ".join(x for x in (c.get("label"), c.get("os"), c.get("ipAddress")) if x) or "unlabeled client"
    print("    %-17s %-20s %-10s issued %s  expires %s%s" % (s.get("subject", "?"), who[:20], s.get("method", "?")[:10],
          str(s.get("issuedAt", ""))[:10], str(s.get("expiresAt", ""))[:10], "  connected" if s.get("connected") else ""))
if len(ss) > 12:
    print("    ... %d more (fleet t3 revoke revokes every pairing-token session)" % (len(ss) - 12))
for p in ps:
    print("    pairing %-12s %s  expires %s" % (p.get("id", "?")[:12], p.get("label") or "", str(p.get("expiresAt", ""))[:19]))
'
}

# ---------- commands ----------

t3_usage() { die "usage: fleet t3 setup [NODE] | status [NODE] | revoke NODE"; }

# t3_node_ids [NODE] — the node, or every registered non-revoked node.
t3_node_ids() {
  local id
  if [ -n "${1:-}" ]; then
    id=$(registry_find "$1")
    node_revoked "$id" && die "node $1 is revoked"
    echo "$id"; return 0
  fi
  for id in $(registry_ids); do node_revoked "$id" || echo "$id"; done
}

# fleet t3 setup [NODE] — key, pinned host key, authorized_keys line on the
# node, ssh config include; then what to click in T3 Code.
cmd_t3_setup() {
  local q=${1:-} id name user host n=0 last=""
  [ $# -le 1 ] || t3_usage
  vault_require
  t3_client_key_ensure
  for id in $(t3_node_ids "$q"); do
    name=$(registry_get "$id" name); user=$(registry_get "$id" user); host=$(registry_get "$id" dnsname)
    [ -n "$user" ] && [ -n "$host" ] || { warn "$name: registry entry has no user/host; skipped"; continue; }
    [ "$(registry_get "$id" t3_access)" = false ] && registry_set "$id" t3_access true
    if ! host_key_pin "$user" "$host"; then
      warn "$name: not reachable right now; rerun 'fleet t3 setup $name' when it is online"; audit "t3.setup" "$name" unreachable; continue
    fi
    if t3_authorize_node "$id" </dev/null; then
      ok "$name: T3 client key authorised (restricted: $T3_CLIENT_KEY_OPTIONS)"
    else
      warn "$name: could not update ~/.ssh/authorized_keys on the node"; audit "t3.setup" "$name" "fail authorized_keys"; continue
    fi
    audit "t3.setup" "$name" ok
    n=$((n + 1)); last=$name
  done
  t3_ssh_config_write
  [ "$n" -gt 0 ] || { warn "no node set up"; return 1; }
  if [ -n "$q" ]; then
    printf '\nIn T3 Code on this machine: Settings -> Connections -> Add environment -> SSH -> host: fleet-%s\n' "$last"
    printf 'T3 then runs ssh fleet-%s itself: it finds or starts the T3 server on the node, pairs and tunnels.\n' "$last"
    if [ "$(fleet_os)" = macos ] && have pbcopy; then
      printf 'fleet-%s' "$last" | pbcopy 2>/dev/null && printf '(fleet-%s is on the clipboard)\n' "$last"
    fi
  else
    printf '\n%d node(s) ready. In T3 Code: Settings -> Connections -> Add environment -> SSH -> host: fleet-<name>\n' "$n"
  fi
  printf 'Check or revoke: fleet t3 status [NODE], fleet t3 revoke NODE\n'
}

# fleet t3 status [NODE] — what T3 would see: the alias as ssh resolves it, the
# pinned host key, a BatchMode connection with the restricted key running T3's
# discovery (no pty), and the node's T3 sessions (metadata only).
cmd_t3_status() {
  local q=${1:-} id name host user alias resolved probe rc out
  [ $# -le 1 ] || t3_usage
  vault_require
  [ -f "$(t3_client_key)" ] || die "no T3 client key yet" "run: fleet t3 setup [NODE]"
  for id in $(t3_node_ids "$q"); do
    name=$(registry_get "$id" name); host=$(registry_get "$id" dnsname); user=$(registry_get "$id" user); alias="fleet-$name"
    printf '%s (%s)\n' "$name" "$id"
    if [ "$(registry_get "$id" t3_access)" = false ]; then printf '  t3 access: revoked (fleet t3 setup %s to re-enable)\n' "$name"; continue; fi
    if known_hosts_has "$host"; then printf '  host key: pinned (%s)\n' "$(known_hosts_file)"; else printf '  host key: NOT pinned -> fleet t3 setup %s\n' "$name"; fi
    if [ -f "$(t3_ssh_include)" ] && grep -qx "Host $alias" "$(t3_ssh_include)"; then
      resolved=$(ssh -G "$alias" 2>/dev/null | awk '$1=="user"{u=$2} $1=="hostname"{h=$2} END{if (h) print u "@" h}')
      printf '  ssh config: Host %s -> %s\n' "$alias" "${resolved:-unresolved}"
    else
      printf '  ssh config: no block for %s -> fleet t3 setup %s\n' "$alias" "$name"; continue
    fi
    rc=0; probe=$(printf '%s\n' "$T3_NODE_PROBE_SH" | ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR "$alias" sh -l -s 2>&1) || rc=$?
    if [ "$rc" = 0 ]; then
      printf '  client key: ok (BatchMode ssh %s, no pty, as T3 does)\n' "$alias"
      printf '%s\n' "$probe" | sed 's/^/    /'
      case "$probe" in *"arch darwin-x86_64"*) warn "$name: T3 ships no darwin-x64 CLI archive; the SSH flow cannot start a server on an Intel Mac" ;; esac
      case "$probe" in *"prereq ok"*) ;; *) warn "$name: missing on the node: $(printf '%s\n' "$probe" | awk '$1=="prereq"{$1=""; print}')" ;; esac
    else
      printf '  client key: FAILED (ssh %s exit %s)\n' "$alias" "$rc"
      printf '%s\n' "$probe" | tail -3 | sed 's/^/    /'
    fi
    out=$(printf '%s\n' "$T3_NODE_LIST_SH" | node_ssh "$id" sh -s 2>/dev/null) || out='{"error":"node unreachable with the fleet master key"}'
    t3_print_sessions "$out"
  done
}

# fleet t3 revoke NODE — the node's pairing-token sessions and pairing tokens,
# T3's managed servers, the client key line, the ssh config block.
cmd_t3_revoke() {
  local q=${1:-} id name
  [ $# -eq 1 ] || t3_usage
  vault_require
  id=$(registry_find "$q"); name=$(registry_get "$id" name)
  registry_set "$id" t3_access false
  if t3_node_revoke "$id" </dev/null; then
    ok "$name: T3 sessions, pairing tokens and the client key revoked on the node"; audit "t3.revoke" "$name" ok
  else
    warn "$name: unreachable; the node side is retried by reconcile (pending_cleanup t3:$id)"
    audit "t3.revoke" "$name" "fail pending"
    # shellcheck disable=SC2046  # the list is space-separated by construction
    registry_set "$id" pending_cleanup "json:$(words_json t3:"$id" $(json_list "$(registry_path "$id")" pending_cleanup | grep -v "^t3:$id\$" || true))"
  fi
  t3_ssh_config_write
  ok "$name: ssh config block removed; T3 Code's environment entry 'fleet-$name' can be deleted in the app (Settings -> Connections)"
}

cmd_t3() {
  local sub=${1:-}
  [ $# -gt 0 ] && shift
  case "$sub" in
    setup)  cmd_t3_setup "$@" ;;
    status) cmd_t3_status "$@" ;;
    revoke) cmd_t3_revoke "$@" ;;
    *) t3_usage ;;
  esac
}
