# shellcheck shell=bash
# Master side of fleet: vault, invites, registry, reconcile, provision, kick, policy.
# Sourced by ./fleet after lib/common.sh and fleet_load_config. Functions only.
#
# Portability: bash 3.2, no assoc arrays/mapfile, no GNU-only flags, no
# `timeout`, no flock, no sed -i. Secrets never in argv: HTTP goes through
# lib/api.py (reads the vault files itself) or `gh api` (keyring-backed).

# ---------- small helpers ----------

# now_epoch — seconds since epoch; FLEET_NOW_EPOCH overrides it (tests).
now_epoch() { echo "${FLEET_NOW_EPOCH:-$(date +%s)}"; }

# epoch_iso EPOCH — UTC ISO timestamp.
epoch_iso() {
  python3 -c 'import sys,time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(int(sys.argv[1]))))' "$1"
}

now_iso() { epoch_iso "$(now_epoch)"; }

# iso_plus SECONDS — UTC ISO timestamp SECONDS from now.
iso_plus() { epoch_iso "$(( $(now_epoch) + $1 ))"; }

# iso_epoch ISO — seconds since epoch, or 0 when unparsable.
iso_epoch() {
  python3 -c 'import sys,calendar,time
try: print(calendar.timegm(time.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ")))
except Exception: print(0)' "$1"
}

# age_human ISO — "3m", "2h", "5d" or "-".
age_human() {
  [ -n "$1" ] || { echo "-"; return; }
  local t0 s
  t0=$(iso_epoch "$1"); [ "$t0" -gt 0 ] || { echo "-"; return; }
  s=$(( $(now_epoch) - t0 ))
  if [ "$s" -lt 3600 ]; then echo "$((s / 60))m"
  elif [ "$s" -lt 86400 ]; then echo "$((s / 3600))h"
  else echo "$((s / 86400))d"; fi
}

master_user() { echo "${FLEET_NODE_USER:-$(id -un)}"; }

api() { FLEET_VAULT="$FLEET_VAULT" python3 "$FLEET_ROOT/lib/api.py" "$@"; }

# audit ACTION NODE RESULT — append one line to vault/audit.log.
audit() {
  [ -d "$FLEET_VAULT" ] || return 0
  [ -f "$FLEET_VAULT/audit.log" ] || { : >"$FLEET_VAULT/audit.log"; chmod 0600 "$FLEET_VAULT/audit.log"; }
  printf '%s %s %s %s %s\n' "$(now_iso)" "$(id -un)" "$1" "${2:--}" "${3:-ok}" >>"$FLEET_VAULT/audit.log"
}


# json_set FILE KEY VALUE [KEY VALUE...] — update (or create) a JSON object, 0600.
# A VALUE starting with "json:" is parsed as JSON; everything else is a string.
json_set() {
  local f=$1; shift
  python3 - "$f" "$@" <<'PY' | atomic_write "$f" 0600
import json, os, sys
f = sys.argv[1]
try:
    d = json.load(open(f))
except Exception:
    d = {}
args = sys.argv[2:]
for i in range(0, len(args) - 1, 2):
    k, v = args[i], args[i + 1]
    d[k] = json.loads(v[5:]) if v.startswith("json:") else v
print(json.dumps(d, indent=2, sort_keys=True))
PY
}

# json_list FILE KEY — print array elements, one per line.
json_list() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], [])
except Exception:
    v = []
for x in v if isinstance(v, list) else []:
    print(x)
PY
}

# words_json WORD... — JSON array of the arguments.
words_json() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@"; }

# typed_confirm PROMPT WORD — read a line; true when it equals WORD.
typed_confirm() {
  local typed
  printf '%s' "$1" >&2
  IFS= read -r typed || true
  [ "$typed" = "$2" ]
}

# open_url URL — open in the browser on macOS; print it elsewhere.
open_url() {
  log "open: $1"
  if [ -z "${FLEET_NO_OPEN:-}" ] && [ -t 0 ] && [ "$(fleet_os)" = macos ] && have open; then open "$1" 2>/dev/null || true; fi
}

# ---------- vault ----------

vault_init() {
  local d
  for d in "$FLEET_HOME" "$FLEET_VAULT" "$FLEET_VAULT/secrets" "$FLEET_VAULT/files" "$FLEET_VAULT/files/full" \
           "$FLEET_VAULT/files/minimal" "$FLEET_VAULT/ssh" "$FLEET_VAULT/nodes" \
           "$FLEET_VAULT/nodes/pending" "$FLEET_VAULT/nodes/claimed" "$FLEET_VAULT/locks"; do
    mkdir -p "$d"; chmod 0700 "$d"
  done
}

vault_require() { [ -d "$FLEET_VAULT/nodes" ] || die "vault not initialised" "run: fleet init master"; }

master_key() { echo "$FLEET_VAULT/ssh/fleet_master"; }

# digest_key_ensure — vault/digest.key: 32 random bytes (hex), 0600, never shipped.
digest_key_ensure() {
  [ -f "$FLEET_VAULT/digest.key" ] && return 0
  mkdir -p "$FLEET_VAULT"
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n' | atomic_write "$FLEET_VAULT/digest.key" 0600
}

# read_secret_opt VAR PROMPT — like read_secret but an empty value is allowed.
read_secret_opt() {
  local _var=$1 _prompt=$2 _val=""
  if [ -t 0 ]; then
    printf '%s: ' "$_prompt" >&2
    stty -echo 2>/dev/null || true
    IFS= read -r _val || true
    stty echo 2>/dev/null || true
    printf '\n' >&2
  else
    IFS= read -r _val || true
  fi
  eval "$_var=\$_val"
}

# ---------- secrets ----------

profile_valid() { case "$1" in minimal|full) return 0 ;; *) return 1 ;; esac; }

# secrets_env PROFILE — concatenated env for the profile (minimal, + full).
secrets_env() {
  [ -f "$FLEET_VAULT/secrets/minimal.env" ] && cat "$FLEET_VAULT/secrets/minimal.env"
  [ "$1" = full ] && [ -f "$FLEET_VAULT/secrets/full.env" ] && cat "$FLEET_VAULT/secrets/full.env"
  return 0
}

# secret_names PROFILE — sorted names only.
secret_names() { secrets_env "$1" | grep -o '^[A-Za-z_][A-Za-z0-9_]*=' | tr -d '=' | LC_ALL=C sort -u; }

# files_list PROFILE — sorted relative paths under vault/files/<profile>.
files_list() {
  [ -d "$FLEET_VAULT/files/$1" ] || return 0
  (cd "$FLEET_VAULT/files/$1" && find . -type f ! -name '.DS_Store' | sed 's|^\./||' | LC_ALL=C sort)
}

# repo_rev DIR — git HEAD of a checkout, or a tree hash when there is no commit yet.
repo_rev() {
  git -C "$1" rev-parse HEAD 2>/dev/null || sha256_tree "$1"
}
code_rev()   { repo_rev "$FLEET_ROOT"; }
config_rev() { if [ -d "$FLEET_CONFIG_DIR" ]; then repo_rev "$FLEET_CONFIG_DIR"; else echo none; fi; }

# desired_digest PROFILE — sha256 over (code rev + config rev, HMAC-SHA256
# keyed with vault/digest.key over the profile's secret file bytes and every
# mirrored file's path + content). A changed secret value or file content
# changes the digest; the key never leaves the vault, so the digest reveals nothing.
desired_digest() {
  digest_key_ensure
  python3 - "$FLEET_VAULT" "$1" "$(code_rev)+$(config_rev)" <<'PY'
import hashlib, hmac, os, sys
vault, profile, rev = sys.argv[1:4]
key = bytes.fromhex(open(os.path.join(vault, "digest.key")).read().strip())
h = hmac.new(key, digestmod=hashlib.sha256)
h.update(b"secrets\0")
for p in ["minimal"] + (["full"] if profile == "full" else []):
    f = os.path.join(vault, "secrets", p + ".env")
    if os.path.isfile(f):
        h.update(open(f, "rb").read())
    h.update(b"\0")
h.update(b"files\0")
root = os.path.join(vault, "files", profile)
rels = []
for d, _, fs in os.walk(root):
    for n in fs:
        if n != ".DS_Store":
            rels.append(os.path.relpath(os.path.join(d, n), root))
for rel in sorted(rels):
    h.update(rel.encode() + b"\0")
    h.update(open(os.path.join(root, rel), "rb").read())
    h.update(b"\0")
print(hashlib.sha256((rev + "\n" + h.hexdigest() + "\n").encode()).hexdigest())
PY
}

cmd_secrets_set() {
  local name="" profile=full val q esc f
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile=${2:-}; shift ;;
      -*) die "unknown flag: $1" ;;
      *) name=$1 ;;
    esac; shift
  done
  [ -n "$name" ] || die "usage: fleet secrets set NAME [--profile minimal|full]"
  printf '%s' "$name" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || die "invalid secret name: $name"
  profile_valid "$profile" || die "profile must be minimal or full"
  vault_init
  read_secret val "value for $name"
  q="'"; esc=${val//$q/$q\\$q$q}
  f="$FLEET_VAULT/secrets/$profile.env"
  { if [ -f "$f" ]; then grep -v "^$name=" "$f" || true; fi; printf "%s='%s'\n" "$name" "$esc"; } | atomic_write "$f" 0600
  val=""; esc=""
  ok "stored $name in profile $profile"
  audit "secrets.set" "$name" ok
}

cmd_secrets_list() {
  vault_require
  local p n
  for p in minimal full; do
    [ -f "$FLEET_VAULT/secrets/$p.env" ] || continue
    grep -o '^[A-Za-z_][A-Za-z0-9_]*=' "$FLEET_VAULT/secrets/$p.env" | tr -d '=' | LC_ALL=C sort | while IFS= read -r n; do
      printf '%-40s %s\n' "$n" "$p"
    done
  done
}

cmd_files_add() {
  local path="" profile=full abs home rel dest
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) profile=${2:-}; shift ;;
      -*) die "unknown flag: $1" ;;
      *) path=$1 ;;
    esac; shift
  done
  [ -n "$path" ] || die "usage: fleet files add PATH [--profile minimal|full]"
  profile_valid "$profile" || die "profile must be minimal or full"
  [ -f "$path" ] || die "not a file: $path"
  abs=$(abspath "$path"); home=$(cd "$HOME" && pwd -P)   # both physical: /var vs /private/var on macOS
  case "$abs" in "$home"/*) ;; *) die "path must be under \$HOME: $abs" ;; esac
  rel=${abs#"$home"/}
  vault_init
  dest="$FLEET_VAULT/files/$profile/$rel"
  mkdir -p "$(dirname "$dest")"
  atomic_write "$dest" 0600 <"$abs"
  ok "mirrored ~/$rel into profile $profile"
  audit "files.add" "$rel" ok
}

# proxy import — copy the master's CLIProxyAPI config + OAuth files into the
# vault (full profile). Nodes stage them in ~/.cli-proxy-api and adopt them
# (lib/tools/cliproxy.sh), so a node's refreshed tokens are not overwritten.
cmd_proxy_import() {
  local src=${1:-${FLEET_CLIPROXY_DIR:-$HOME/cli-proxy-api}} dest f b n=0
  [ -f "$src/conf/config.yaml" ] || die "no $src/conf/config.yaml" "pass the CLIProxyAPI dir: fleet proxy import DIR"
  vault_init
  dest="$FLEET_VAULT/files/full/.cli-proxy-api"
  mkdir -p "$dest/auth"; chmod 0700 "$dest" "$dest/auth"
  atomic_write "$dest/config.yaml" 0600 <"$src/conf/config.yaml"
  for f in "$src"/auth/*.json; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    atomic_write "$dest/auth/$b" 0600 <"$f"
    n=$((n + 1))
  done
  ok "imported CLIProxyAPI config.yaml + $n auth file(s) into profile full"
  audit "proxy.import" "-" "ok $n"
}

# ---------- registry ----------

registry_path() { echo "$FLEET_VAULT/nodes/$1.json"; }

registry_ids() {
  local f
  for f in "$FLEET_VAULT"/nodes/*.json; do
    [ -f "$f" ] || continue
    basename "$f" .json
  done
}

registry_get() { json_get "$(registry_path "$1")" "$2"; }

# registry_lock — the registry-wide lock: every read-modify-write of a
# registry entry (json_set = load, update keys, write) runs under it, so a
# write that raced a concurrent `kick` can never put a stale state back.
# Takes it in addition to the node lock (always node lock first; never the
# other way round). A lock held longer than 30 s is pathological (one write
# takes milliseconds) and gets broken.
registry_lock() {
  local l="$FLEET_VAULT/locks/.registry"
  lock_acquire "$l" 30 && return 0
  warn "registry lock stuck (pid $(lock_pid "$l")); breaking it"
  rm -rf "$l"
  lock_acquire "$l" 5 || die "cannot take the registry lock $l"
}

registry_unlock() { lock_release "$FLEET_VAULT/locks/.registry" $$; }

# registry_set ID KEY VALUE... — update an entry under the registry lock.
registry_set() {
  local id=$1; shift
  registry_lock
  json_set "$(registry_path "$id")" "$@"
  registry_unlock
}

# registry_find NAME_OR_ID — print the id; dies when unknown (never guesses).
registry_find() {
  local q=$1 id
  [ -n "$q" ] || die "node name or id required"
  if [ -f "$(registry_path "$q")" ]; then echo "$q"; return; fi
  for id in $(registry_ids); do
    if [ "$(registry_get "$id" name)" = "$q" ]; then echo "$id"; return; fi
  done
  die "unknown node: $q" "run: fleet nodes"
}

node_revoked() { [ "$(registry_get "$1" state)" = revoked ]; }

# ---------- tailscale peers (local status, no API) ----------

tailscale_bin() {
  if have tailscale; then echo tailscale
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  else return 1; fi
}

# ts_status_json — `tailscale status --json`, or the FLEET_TS_STATUS_JSON file (tests).
ts_status_json() {
  if [ -n "${FLEET_TS_STATUS_JSON:-}" ]; then cat "$FLEET_TS_STATUS_JSON"
  else "$(tailscale_bin)" status --json 2>/dev/null || { warn "tailscale status failed"; return 0; }; fi
}

# ts_backend_state — BackendState from `tailscale status` (Running = logged in), or empty.
ts_backend_state() {
  ts_status_json 2>/dev/null | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("BackendState", ""))
except Exception:
    print("")'
}

# ts_peers — one line per peer tagged FLEET_NODE_TAG:
#   ID<TAB>HostName<TAB>DNSName<TAB>online(true|false)<TAB>first TailscaleIP
ts_peers() {
  ts_status_json | python3 -c 'import json, sys
tag = sys.argv[1]
try:
    st = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for p in (st.get("Peer") or {}).values():
    if tag not in (p.get("Tags") or []):
        continue
    print("%s\t%s\t%s\t%s\t%s" % (p.get("ID", ""), p.get("HostName", ""),
          (p.get("DNSName") or "").rstrip("."), "true" if p.get("Online") else "false",
          (p.get("TailscaleIPs") or [""])[0]))' "$FLEET_NODE_TAG"
}

# peer_online PEERS ID — true when ID is listed online in the ts_peers output.
peer_online() { printf '%s\n' "$1" | awk -F'\t' -v id="$2" '$1==id && $4=="true"{f=1} END{exit !f}'; }

# peer_ip PEERS ID — the peer's first tailnet IP, or empty.
peer_ip() { printf '%s\n' "$1" | awk -F'\t' -v id="$2" '$1==id{print $5; exit}'; }

# master_ts_ip — this machine's IPv4 on the tailnet (FLEET_MASTER_TS_IP overrides).
master_ts_ip() {
  local ip=${FLEET_MASTER_TS_IP:-}
  [ -n "$ip" ] || ip=$("$(tailscale_bin)" ip -4 2>/dev/null | head -1) || ip=""
  [ -n "$ip" ] || ip=$(ts_status_json | python3 -c 'import json,sys
try: print((json.load(sys.stdin).get("Self") or {}).get("TailscaleIPs",[""])[0])
except Exception: pass')
  echo "$ip"
}

# ---------- ssh ----------

# ssh_to USER HOST CMD — raw ssh with the master key. stdin passes through.
# Host keys live in vault/ssh/known_hosts (lib/t3.sh): strict once the node is
# pinned, accept-new only for the very first contact with a node.
ssh_to() {
  local user=$1 host=$2; shift 2
  ssh -i "$(master_key)" -o BatchMode=yes -o "StrictHostKeyChecking=$(ssh_strict_mode "$host")" \
      -o "UserKnownHostsFile=$(known_hosts_file)" -o HashKnownHosts=no -o HostKeyAlgorithms=ssh-ed25519 \
      -o ConnectTimeout=10 -o LogLevel=ERROR "$user@$host" "$@"
}

# node_ssh ID CMD — ssh to a registered node.
node_ssh() {
  local id=$1; shift
  ssh_to "$(registry_get "$id" user)" "$(registry_get "$id" dnsname)" "$@"
}

# fleet ssh NODE [COMMAND...] — open a shell on NODE, or run COMMAND there,
# with the node's fleet environment (PATH, proxy, secrets) loaded. Resolves the
# name through the registry, so nobody has to remember hostnames, users or keys.
cmd_ssh() {
  local q=${1:-} id user host remote a
  [ -n "$q" ] || die "usage: fleet ssh NODE [COMMAND...]" "names: fleet nodes"
  shift
  vault_require
  id=$(registry_find "$q")
  [ "$(registry_get "$id" state)" != revoked ] || die "node $q is revoked"
  user=$(registry_get "$id" user); host=$(registry_get "$id" dnsname)
  [ -n "$user" ] && [ -n "$host" ] || die "registry entry for $q has no user/host" "fleet reconcile"
  if [ $# -eq 0 ]; then
    exec ssh -t -i "$(master_key)" -o "StrictHostKeyChecking=$(ssh_strict_mode "$host")" -o "UserKnownHostsFile=$(known_hosts_file)" \
      -o HashKnownHosts=no -o HostKeyAlgorithms=ssh-ed25519 -o LogLevel=ERROR "$user@$host"
  fi
  # quote every argument for the remote shell, then load env.sh before running
  remote=""
  for a in "$@"; do remote="$remote $(printf '%q' "$a")"; done
  # shellcheck disable=SC2016  # expanded by the node's shell
  exec ssh -t -i "$(master_key)" -o "StrictHostKeyChecking=$(ssh_strict_mode "$host")" -o "UserKnownHostsFile=$(known_hosts_file)" \
    -o HashKnownHosts=no -o HostKeyAlgorithms=ssh-ed25519 -o LogLevel=ERROR "$user@$host" \
    'PATH="$HOME/.local/bin:$PATH"; [ -f "$HOME/.config/fleet/env.sh" ] && . "$HOME/.config/fleet/env.sh";'"$remote"
}

# ---------- GitHub (gh CLI first, vault token as fallback) ----------

_GH_CLI=""
# gh_cli — true when the GitHub CLI is installed and logged in (keyring token,
# never in argv or the vault). FLEET_GH_API (tests) forces the token fallback.
gh_cli() {
  if [ -z "$_GH_CLI" ]; then
    if [ -z "${FLEET_GH_API:-}" ] && have gh && gh auth status -h github.com >/dev/null 2>&1; then _GH_CLI=yes; else _GH_CLI=no; fi
  fi
  [ "$_GH_CLI" = yes ]
}

# gh_key_create OWNER/REPO TITLE READONLY < pubkey — prints the deploy key id.
gh_key_create() {
  if gh_cli; then
    gh api -X POST "repos/$1/keys" -f "title=$2" -F "read_only=$3" -F key=@- --jq .id
  else
    api gh key-create "$1" "$2" "$3"
  fi
}

# gh_key_delete OWNER/REPO KEY_ID — 404 (already gone) counts as success.
# Callers pass the slug recorded when the key was created (registry_gh_key),
# never the current repo URL: a 404 on a different repository would otherwise
# count as deleted while the real key survives.
gh_key_delete() {
  local err
  if gh_cli; then
    err=$(gh api -X DELETE "repos/$1/keys/$2" 2>&1 >/dev/null) && return 0
    printf '%s' "$err" | grep -q 'HTTP 404'
  else
    api gh key-delete "$1" "$2"
  fi
}

gh_login() { if gh_cli; then gh api user --jq .login; else api gh user; fi; }

# registry_gh_key FILE KIND — "<id> <owner/repo>" for github_keys.<kind>, or
# "<id>" alone for an entry written before the repo slug was recorded (plain
# int), or nothing. Works on registry entries and claimed files alike
# (claimed: gh_<kind>_key / gh_<kind>_repo).
registry_gh_key() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
k = sys.argv[2]
v = (d.get("github_keys") or {}).get(k) if isinstance(d.get("github_keys"), dict) else None
if v is None and ("gh_%s_key" % k) in d:
    kid = d.get("gh_%s_key" % k)
    v = {"id": kid, "repo": d.get("gh_%s_repo" % k, "")} if kid not in (None, "") else None
if v is None:
    sys.exit(0)
if isinstance(v, dict):
    if v.get("id") in (None, ""):
        sys.exit(0)
    print("%s %s" % (v["id"], v.get("repo") or ""))
else:
    print(v)
PY
}

# gh_key_item KIND "<id> [slug]" — the pending_cleanup entry for one deploy
# key: gh:<kind>:<id>:<owner/repo> (slug omitted only for legacy int entries).
gh_key_item() {
  local kind=$1 kid slug
  kid=${2%% *}; slug=""
  case "$2" in *" "*) slug=${2#* } ;; esac
  [ -n "$kid" ] || return 0
  if [ -n "$slug" ]; then printf 'gh:%s:%s:%s\n' "$kind" "$kid" "$slug"; else printf 'gh:%s:%s\n' "$kind" "$kid"; fi
}

# gh_try_install — install the GitHub CLI where that is non-interactive enough.
gh_try_install() {
  have gh && return 0
  if [ "$(fleet_os)" = macos ] && have brew; then
    log "installing the GitHub CLI (brew install gh)"
    brew install gh >/dev/null 2>&1 || warn "brew install gh failed"
  else
    log "GitHub CLI not found; install it: https://github.com/cli/cli#installation (Debian: apt install gh)"
  fi
  have gh
}

# key_repos — the repos that get a per-node deploy key: config always, memory
# when a memory repo is configured, code only when it is a non-https URL.
key_repos() {
  repo_needs_key "$FLEET_CODE_REPO" && printf '%s\n' "$FLEET_CODE_REPO"
  printf '%s\n' "$FLEET_CONFIG_REPO"
  [ -n "$FLEET_MEMORY_REPO" ] && printf '%s\n' "$FLEET_MEMORY_REPO"
  return 0
}

# github_setup — logged-in gh (one browser approval) or, as a fallback, a token
# in vault/github.json. Checks access to the repos; offers to create them.
github_setup() {
  local reconfigure=$1 tok slug repo ans
  repo_require FLEET_CONFIG_REPO
  [ -n "$FLEET_CODE_REPO" ] || warn "FLEET_CODE_REPO is empty: nodes cannot pull code updates; provision re-ships the code each time"
  [ -n "$FLEET_MEMORY_REPO" ] || log "FLEET_MEMORY_REPO is empty: shared memory is off (no memory deploy keys, no memory timer on nodes)"
  if [ -z "${FLEET_GH_API:-}" ] && gh_try_install; then
    if ! gh auth status -h github.com >/dev/null 2>&1; then
      log "GitHub: one browser approval (gh auth login --web)"
      gh auth login -h github.com --web --git-protocol ssh || die "gh auth login failed" "retry: gh auth login -h github.com --web"
      _GH_CLI=""
    fi
    gh_cli || die "gh is installed but not logged in" "run: gh auth login -h github.com --web"
    ok "github: gh logged in as $(gh_login)"
    for repo in $(key_repos); do
      slug=$(repo_slug "$repo")
      if gh repo view "$slug" >/dev/null 2>&1; then ok "github: $slug reachable"; continue; fi
      printf 'GitHub repo %s not found or no access. Create it as a private repo? [y/N] ' "$slug" >&2
      IFS= read -r ans || true
      case "$ans" in
        y|Y|yes) if gh repo create "$slug" --private >/dev/null; then ok "github: created private repo $slug"; else warn "github: could not create $slug"; fi ;;
        *) warn "github: $slug missing; deploy keys for it will fail until it exists" ;;
      esac
    done
    [ -f "$FLEET_VAULT/github.json" ] && log "vault/github.json is no longer needed (gh is used); delete it when convenient"
    return 0
  fi
  if [ ! -f "$FLEET_VAULT/github.json" ] || [ "$reconfigure" = 1 ]; then
    log "GitHub fine-grained token: Administration read/write on $(for repo in $(key_repos); do printf '%s ' "$(repo_slug "$repo")"; done)"
    read_secret_opt tok "GitHub token (empty to skip for now)"
    if [ -n "$tok" ]; then
      printf '%s\n' "$tok" | python3 -c 'import json,sys; print(json.dumps({"token":sys.stdin.readline().rstrip("\n")}))' \
        | atomic_write "$FLEET_VAULT/github.json" 0600
      ok "wrote vault/github.json"
    else
      warn "no GitHub token: enrolment cannot register deploy keys until you rerun 'fleet init master --reconfigure'"
    fi
    tok=""
  fi
}

# ---------- Tailscale bootstrap (one short-lived API token, then an OAuth client) ----------

_BOOT_FILE=""
bootstrap_cleanup() {
  [ -n "$_BOOT_FILE" ] || return 0
  if FLEET_TS_BOOTSTRAP_FILE=$_BOOT_FILE api ts bootstrap-revoke >/dev/null 2>&1; then
    ok "bootstrap API token revoked"
  else
    warn "could not revoke the bootstrap API token; delete it at https://login.tailscale.com/admin/settings/keys"
  fi
  rm -f "$_BOOT_FILE"; _BOOT_FILE=""
}

# with_bootstrap_token CMD... — prompt (hidden) for a tskey-api token, keep it in
# a 0600 file inside the vault for the duration of CMD, then revoke and delete
# it. The token is never stored, logged or passed as an argument.
with_bootstrap_token() {
  local tok rc=0
  vault_init
  open_url "https://login.tailscale.com/admin/settings/keys"
  log "Tailscale: generate an API access token there (1-day expiry is enough; it is revoked when this finishes)"
  read_secret tok "Tailscale API access token (tskey-api-...)"
  _BOOT_FILE=$(mktemp "$FLEET_VAULT/.bootstrap.XXXXXX"); chmod 0600 "$_BOOT_FILE"
  printf '%s\n' "$tok" >"$_BOOT_FILE"; tok=""
  trap bootstrap_cleanup EXIT
  export FLEET_TS_BOOTSTRAP_FILE=$_BOOT_FILE
  "$@" || rc=$?
  unset FLEET_TS_BOOTSTRAP_FILE
  bootstrap_cleanup
  trap - EXIT
  return "$rc"
}

# ts_bootstrap — runs under with_bootstrap_token: policy, then the OAuth client.
ts_bootstrap() {
  # The OAuth client must carry the fleet tag, which only exists once the
  # policy owns it; without the policy step there is nothing useful to create.
  policy_ensure || die "stopped: the tailnet policy is not set up, so the fleet OAuth client cannot be created" \
    "rerun: fleet init master --reconfigure (create a new 1-day API token; the old one was revoked)"
  api ts client-create "fleet master" "$FLEET_NODE_TAG" auth_keys devices:core policy_file:read >/dev/null \
    || die "could not create the Tailscale OAuth client" "tagOwners must contain $FLEET_NODE_TAG first: fleet policy apply"
  ok "wrote vault/tailscale.json: OAuth client 'fleet master' (scopes auth_keys, devices:core, policy_file:read; tag $FLEET_NODE_TAG)"
  audit "ts.client" "-" created
}

# ---------- policy ----------

policy_template() { echo "$FLEET_ROOT/templates/tailscale-policy.hujson"; }

# policy_fetch OUTFILE — live HuJSON policy into OUTFILE (0600); prints the ETag.
policy_fetch() { api ts acl-get "$1"; }

# policy_check_live — fetch the live policy and verify it isolates the nodes.
# Quiet on success; findings go to stderr. Returns 1 on findings, 2 when the
# policy could not be fetched.
policy_check_live() {
  local tmpd rc=0
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fleet-policy.XXXXXX"); chmod 0700 "$tmpd"
  if ! policy_fetch "$tmpd/live.hujson" >/dev/null; then rm -rf "$tmpd"; return 2; fi
  api policy check "$(policy_template)" "$tmpd/live.hujson" "$FLEET_NODE_TAG" || rc=1
  rm -rf "$tmpd"
  return "$rc"
}

# policy_apply_interactive — merge the fleet rules into the LIVE policy (your
# other rules stay), show the diff, require the word "apply", back up the live
# policy into the vault, POST with If-Match. Needs policy_file write scope
# (bootstrap token).
policy_apply_interactive() {
  local tmpd etag rc=0 bak
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fleet-policy.XXXXXX"); chmod 0700 "$tmpd"
  etag=$(policy_fetch "$tmpd/live.hujson") || { rm -rf "$tmpd"; return 2; }
  if api policy check "$(policy_template)" "$tmpd/live.hujson" "$FLEET_NODE_TAG" 2>/dev/null; then
    ok "policy: live tailnet policy already isolates $FLEET_NODE_TAG"; rm -rf "$tmpd"; return 0
  fi
  api policy merge "$(policy_template)" "$tmpd/live.hujson" "$FLEET_NODE_TAG" "$tmpd/merged.json" \
    || { warn "policy: could not merge the live policy"; rm -rf "$tmpd"; return 1; }
  if ! api policy check "$(policy_template)" "$tmpd/merged.json" "$FLEET_NODE_TAG"; then
    warn "policy: the rules above still let other sources reach the tailnet; fleet will not guess."
    warn "edit them at https://login.tailscale.com/admin/acls/file, then rerun: fleet policy apply"
    rm -rf "$tmpd"; return 1
  fi
  api policy diff "$tmpd/merged.json" "$tmpd/live.hujson" >&2
  printf '\nThis updates your live tailnet policy as shown above (your other rules stay; comments are\n' >&2
  printf 'not kept). The current policy is backed up into the vault first. ETag %s.\n' "${etag:-none}" >&2
  if typed_confirm 'Type the word apply and press Enter (anything else skips): ' apply; then
    bak="$FLEET_VAULT/policy-backups/$(date -u +%Y%m%dT%H%M%SZ).hujson"
    mkdir -p "$(dirname "$bak")"; chmod 0700 "$(dirname "$bak")"
    atomic_write "$bak" 0600 <"$tmpd/live.hujson"
    if api ts acl-set "$etag" <"$tmpd/merged.json" >/dev/null; then
      ok "policy: applied (backup of the previous policy: $bak)"; audit "policy.apply" "-" ok
    else
      warn "policy: apply FAILED (ETag changed, validation error, or missing policy_file scope)"; audit "policy.apply" "-" fail; rc=1
    fi
  else
    warn "policy: not applied. Rerun later with: fleet policy apply"; rc=1
  fi
  rm -rf "$tmpd"
  return "$rc"
}

# policy_ensure — check; on findings show them and offer to apply the template.
policy_ensure() {
  local rc=0
  policy_check_live || rc=$?
  case "$rc" in
    0) ok "policy: live tailnet policy isolates $FLEET_NODE_TAG"; return 0 ;;
    2) warn "policy: could not read the live policy (scope policy_file:read?)"; return 2 ;;
  esac
  warn "policy: the live tailnet policy does not isolate $FLEET_NODE_TAG (findings above)"
  policy_apply_interactive
}

cmd_policy() {
  local sub=${1:-}
  vault_require
  case "$sub" in
    check)
      [ -f "$FLEET_VAULT/tailscale.json" ] || die "no Tailscale OAuth client in vault" "run: fleet init master"
      case "$(policy_check_live; echo $?)" in
        0) ok "policy: live tailnet policy isolates $FLEET_NODE_TAG" ;;
        2) die "policy: could not read the live policy" "the OAuth client needs the policy_file:read scope; rerun: fleet init master --reconfigure" ;;
        *) die "policy: live tailnet policy does not isolate $FLEET_NODE_TAG (see findings)" "fleet policy apply" ;;
      esac ;;
    apply)
      log "policy apply writes the tailnet policy; the fleet OAuth client only has policy_file:read, so this needs a one-off API access token"
      with_bootstrap_token policy_apply_interactive ;;
    *) die "usage: fleet policy check|apply" ;;
  esac
}

# ---------- init master ----------

# config_dir_setup [DIR] — record the config dir in the local fleet.conf and
# make sure it exists: clone FLEET_CONFIG_REPO into it (after a confirmation)
# when it is missing and the repo is known, otherwise die with the next step.
config_dir_setup() {
  local dir=$1 ans
  if [ -n "$dir" ]; then
    dir=$(cd "$(dirname "$dir")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$dir")") || dir=$1
    mkdir -p "$FLEET_HOME"; chmod 0700 "$FLEET_HOME"
    conf_set "$FLEET_HOME/fleet.conf" FLEET_CONFIG_DIR "$dir"
    FLEET_CONFIG_DIR=$dir
    fleet_load_config          # pick up the repo's fleet.conf (local still wins)
    ok "config dir: $FLEET_CONFIG_DIR (recorded in $FLEET_HOME/fleet.conf)"
  fi
  [ -d "$FLEET_CONFIG_DIR" ] && return 0
  if [ -n "${FLEET_CONFIG_REPO:-}" ]; then
    printf 'Config dir %s does not exist. Clone %s there? [y/N] ' "$FLEET_CONFIG_DIR" "$FLEET_CONFIG_REPO" >&2
    IFS= read -r ans || true
    case "$ans" in
      y|Y|yes)
        mkdir -p "$(dirname "$FLEET_CONFIG_DIR")"
        GIT_TERMINAL_PROMPT=0 git clone --quiet "$FLEET_CONFIG_REPO" "$FLEET_CONFIG_DIR" || die "git clone $FLEET_CONFIG_REPO failed" "check your SSH access to the repo, then rerun"
        fleet_load_config
        ok "cloned $FLEET_CONFIG_REPO into $FLEET_CONFIG_DIR"
        return 0 ;;
    esac
  fi
  config_dir_require
}

# init_preflight — everything init needs from the machine, checked before a
# single file is written: the commands, a logged-in Tailscale client, a git
# identity (publish and the memory seed commit as you), and how GitHub will be
# reached. Each failure names the next step.
init_preflight() {
  local c missing="" state name email
  for c in ssh ssh-keygen python3 git tar gzip base64; do have "$c" || missing="$missing $c"; done
  [ -z "$missing" ] || die "missing commands:$missing" \
    "install them (macOS: xcode-select --install; Debian/Ubuntu: sudo apt install git python3 openssh-client), then rerun: fleet init master"
  if [ -z "${FLEET_TS_STATUS_JSON:-}" ] && ! tailscale_bin >/dev/null; then
    die "the Tailscale CLI is not installed on this machine" \
      "install Tailscale (https://tailscale.com/download), log in to your tailnet, then rerun: fleet init master"
  fi
  state=$(ts_backend_state)
  [ "$state" = Running ] || die "Tailscale is not logged in on this machine (state: ${state:-unknown})" \
    "log in (tailscale up, or the Tailscale app), check that 'tailscale status' lists your devices, then rerun: fleet init master"
  # from a neutral directory: the identity of a repo we happen to be in does not count
  name=$(cd / && git config --get user.name 2>/dev/null || true); email=$(cd / && git config --get user.email 2>/dev/null || true)
  [ -n "$name" ] && [ -n "$email" ] || die "git has no identity on this machine (user.name / user.email)" \
    "git config --global user.name 'Your Name' && git config --global user.email you@example.com   (fleet config publish and the memory seed commit as you)"
  if [ -n "${FLEET_GH_API:-}" ] || [ -f "$FLEET_VAULT/github.json" ] || gh_cli; then
    :
  elif have gh; then
    log "GitHub: gh is installed but not logged in; init asks for one browser approval (gh auth login --web)"
  elif [ "$(fleet_os)" = macos ] && have brew; then
    log "GitHub: gh is not installed; init installs it (brew install gh) and asks for one browser approval"
  else
    log "GitHub: no gh CLI (https://github.com/cli/cli#installation); init asks for a fine-grained token with Administration read/write on your repos instead"
  fi
  ok "preflight: commands present, Tailscale logged in, git identity $name <$email>"
}

cmd_init_master() {
  local reconfigure=0 cdir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reconfigure) reconfigure=1 ;;
      --config-dir) cdir=${2:-}; [ -n "$cdir" ] || die "--config-dir needs a directory"; shift ;;
      *) die "unknown flag: $1" "usage: fleet init master [--config-dir DIR] [--reconfigure]" ;;
    esac; shift
  done
  init_preflight
  config_dir_setup "$cdir"
  [ -f "$FLEET_CONFIG_DIR/fleet.conf" ] || warn "no fleet.conf in $FLEET_CONFIG_DIR (see examples/fleet-config/fleet.conf)"
  vault_init
  digest_key_ensure
  ok "vault $FLEET_VAULT (0700)"

  if [ ! -f "$(master_key)" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "fleet-master@$(hostname -s 2>/dev/null || hostname)" -f "$(master_key)" </dev/null
    ok "generated master ssh key $(master_key)"
  fi
  chmod 0600 "$(master_key)"; chmod 0644 "$(master_key).pub"
  # The key T3 Code uses towards nodes (never the master key; lib/t3.sh): only
  # with FLEET_T3_REMOTE=1, or later through `fleet t3 setup`. Without it no
  # node gets the extra authorized_keys line and ~/.ssh/config is never touched.
  if [ "${FLEET_T3_REMOTE:-0}" = 1 ]; then t3_client_key_ensure; fi

  if [ ! -f "$FLEET_VAULT/tailscale.json" ] || [ "$reconfigure" = 1 ]; then
    with_bootstrap_token ts_bootstrap
  else
    policy_ensure_readonly
  fi

  github_setup "$reconfigure"
  install_reconcile_schedule
  audit "init.master" "-" ok
  ok "master ready. next: fleet secrets set CLAUDE_CODE_OAUTH_TOKEN; fleet config publish; fleet invite"
}

# policy_ensure_readonly — re-run check with the OAuth client (no write scope).
policy_ensure_readonly() {
  case "$(policy_check_live; echo $?)" in
    0) ok "policy: live tailnet policy isolates $FLEET_NODE_TAG" ;;
    2) warn "policy: could not read the live policy (OAuth client lacks policy_file:read? rerun with --reconfigure)" ;;
    *) warn "policy: live tailnet policy does not isolate $FLEET_NODE_TAG; run: fleet policy apply" ;;
  esac
}

# repo_slug URL — owner/repo from git@github.com:owner/repo.git or https URL.
repo_slug() {
  local s=$1
  s=${s%.git}
  case "$s" in
    git@*:*) s=${s#*:} ;;
    *://*)   s=${s#*://}; s=${s#*/} ;;
  esac
  echo "$s"
}

install_reconcile_schedule() {
  local every=$((FLEET_RECONCILE_EVERY * 60)) plist unit
  case "$(fleet_os)" in
    macos)
      plist="$HOME/Library/LaunchAgents/dev.fleet.reconcile.plist"
      mkdir -p "$(dirname "$plist")"
      atomic_write "$plist" 0644 <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.fleet.reconcile</string>
  <key>ProgramArguments</key>
  <array><string>$FLEET_ROOT/fleet</string><string>reconcile</string></array>
  <key>StartInterval</key><integer>$every</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>FLEET_HOME</key><string>$FLEET_HOME</string>
  </dict>
  <key>StandardOutPath</key><string>$FLEET_HOME/reconcile.log</string>
  <key>StandardErrorPath</key><string>$FLEET_HOME/reconcile.log</string>
</dict>
</plist>
EOF
      if [ -z "${FLEET_NO_SCHEDULER:-}" ] && have launchctl; then
        launchctl bootout "gui/$(id -u)/dev.fleet.reconcile" >/dev/null 2>&1 || true
        launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || warn "launchctl bootstrap failed; load manually: launchctl load $plist"
      fi
      ok "reconcile schedule: $plist (every $FLEET_RECONCILE_EVERY min)"
      ;;
    linux)
      unit="$HOME/.config/systemd/user"
      mkdir -p "$unit"
      atomic_write "$unit/fleet-reconcile.service" 0644 <<EOF
[Unit]
Description=fleet reconcile
[Service]
Type=oneshot
Environment=FLEET_HOME=$FLEET_HOME
ExecStart=$FLEET_ROOT/fleet reconcile
EOF
      atomic_write "$unit/fleet-reconcile.timer" 0644 <<EOF
[Unit]
Description=fleet reconcile every $FLEET_RECONCILE_EVERY min
[Timer]
OnBootSec=1min
OnUnitActiveSec=${FLEET_RECONCILE_EVERY}min
[Install]
WantedBy=timers.target
EOF
      if [ -z "${FLEET_NO_SCHEDULER:-}" ] && have systemctl; then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        systemctl --user enable --now fleet-reconcile.timer >/dev/null 2>&1 || warn "systemctl --user enable failed (no user session?)"
      fi
      ok "reconcile schedule: $unit/fleet-reconcile.timer (every $FLEET_RECONCILE_EVERY min)"
      ;;
    *) warn "unsupported OS: no reconcile schedule installed" ;;
  esac
}

# ---------- invite ----------

random_name() {
  local a b
  a="amber basalt cedar delta ember flint garnet harbor indigo juniper kestrel lumen maple nickel ochre pearl"
  b="fox owl elk lynx wren hare seal crow bear kite pike mole newt swan ibis vole"
  a=$(echo "$a" | tr ' ' '\n' | awk -v n="$(( $(od -An -N1 -tu1 /dev/urandom) % 16 + 1 ))" 'NR==n')
  b=$(echo "$b" | tr ' ' '\n' | awk -v n="$(( $(od -An -N1 -tu1 /dev/urandom) % 16 + 1 ))" 'NR==n')
  echo "$a-$b"
}

# join_oneliner — the pinned, self-contained command the user pastes on a node.
# Everything lands in a private mktemp dir that a subshell EXIT trap removes
# (works in bash, zsh and dash); nothing predictable under /tmp.
join_oneliner() {
  local b64
  [ -f "$FLEET_ROOT/lib/join.sh" ] || die "missing lib/join.sh"
  b64=$(gzip -9 -n -c "$FLEET_ROOT/lib/join.sh" | base64 | tr -d '\n')
  # base64 -d works on GNU coreutils and macOS >= 13; -D is the pre-13 macOS
  # spelling. Input goes via a file because macOS base64 takes no positional
  # argument and the fallback must re-read it. Needs only mktemp, base64,
  # gunzip and bash (debian:*-slim has no python3/openssl).
  # shellcheck disable=SC2016  # $d is meant for the node's shell, not ours
  printf '( d=$(mktemp -d) && trap '\''rm -rf "$d"'\'' EXIT && printf %%s '\''%s'\'' > "$d/join.b64" && (base64 -d < "$d/join.b64" 2>/dev/null || base64 -D < "$d/join.b64") | gunzip > "$d/join.sh" && bash "$d/join.sh" )\n' "$b64"
}

cmd_invite() {
  local ephemeral=false profile="" name="" nonce created expires key_id key ts_out user="" pub code code_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --ephemeral) ephemeral=true ;;
      --profile) profile=${2:-}; shift ;;
      --name) name=${2:-}; shift ;;
      --user) user=${2:-}; shift ;;   # login name the master sshes to on the node (default: this user)
      --code-only) code_only=1 ;;     # print just the invite code (docker/spawn.sh)
      *) die "usage: fleet invite [--ephemeral] [--profile P] [--name N] [--user U] [--code-only]" ;;
    esac; shift
  done
  vault_require
  [ -f "$FLEET_VAULT/tailscale.json" ] || die "no Tailscale OAuth client in vault" "run: fleet init master"
  if [ -z "$profile" ]; then
    if [ "$ephemeral" = true ]; then profile=$FLEET_EPHEMERAL_PROFILE; else profile=$FLEET_DEFAULT_PROFILE; fi
  fi
  profile_valid "$profile" || die "profile must be minimal or full"
  [ -n "$name" ] || name=$(random_name)
  printf '%s' "$name" | grep -Eq '^[a-z0-9-]{1,40}$' || die "invalid name: $name" "use [a-z0-9-], max 40 chars"
  [ -n "$user" ] || user=$(master_user)
  printf '%s' "$user" | grep -Eq '^[A-Za-z_][A-Za-z0-9_.-]{0,31}$' || die "invalid --user: $user" "use a POSIX login name"

  nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  created=$(now_iso); expires=$(iso_plus 3600)
  pub=$(cat "$(master_key).pub")

  ts_out=$(api ts key-create "fleet $name" "$ephemeral" "$FLEET_NODE_TAG" 3600) || die "tailscale key creation failed"
  key_id=${ts_out%% *}; key=${ts_out#* }
  [ -n "$key" ] || die "tailscale returned no key"

  json_set "$FLEET_VAULT/nodes/pending/$nonce.json" \
    nonce "$nonce" name "$name" profile "$profile" ephemeral "json:$ephemeral" \
    created "$created" expires "$expires" ts_key_id "$key_id" user "$user"

  # The auth key goes to python on stdin, never argv. `tools` lets join skip
  # privileged installs (browser, docker) the fleet does not use.
  code=$(printf '%s' "$key" | python3 -c 'import base64,json,sys
d={"v":1,"ts_auth_key":sys.stdin.read(),"nonce":sys.argv[1],"name":sys.argv[2],
   "master_pubkey":sys.argv[3],"master_user":sys.argv[4],"tag":sys.argv[5],
   "hostname_prefix":sys.argv[6],"tools":" ".join(sys.argv[7].split())}
print(base64.b64encode(json.dumps(d,separators=(",",":")).encode()).decode())' \
    "$nonce" "$name" "$pub" "$user" "$FLEET_NODE_TAG" "$FLEET_HOSTNAME_PREFIX" "${FLEET_TOOLS:-}")
  key=""

  audit "invite" "$name" "ok profile=$profile ephemeral=$ephemeral"
  if [ "$code_only" = 1 ]; then printf '%s\n' "$code"; return 0; fi
  printf '\n1) Run this on the new machine (one line):\n\n'
  join_oneliner
  printf '\n2) When it asks, paste this invite code (single use, expires %s):\n\n%s\n\n' "$expires" "$code"
  printf 'Docker: FLEET_INVITE_CODE=<code> or FLEET_INVITE_FILE=<path>. Node name: %s, profile: %s, login: %s.\n' "$name" "$profile" "$user" >&2
}

# ---------- nodes ----------

cmd_nodes() {
  local live=0 id name online state profile prov peers tmpd pid f
  while [ $# -gt 0 ]; do
    case "$1" in --live) live=1 ;; *) die "usage: fleet nodes [--live]" ;; esac; shift
  done
  vault_require
  peers=$(ts_peers)
  tmpd=""
  if [ "$live" = 1 ]; then
    tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fleet-nodes.XXXXXX"); chmod 0700 "$tmpd"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpd'" EXIT
    for id in $(registry_ids); do
      node_revoked "$id" && continue
      # shellcheck disable=SC2088  # the ~ is expanded by the node's shell, not ours
      ( with_timeout 10 node_ssh "$id" '~/.local/bin/fleet status --json' >"$tmpd/$id" 2>/dev/null || : ) &
    done
    wait
  fi
  printf '%-18s %-14s %-7s %-12s %-8s %-6s %s\n' NAME ID ONLINE STATE PROFILE AGE LIVE
  for id in $(registry_ids); do
    name=$(registry_get "$id" name); state=$(registry_get "$id" state); profile=$(registry_get "$id" profile)
    prov=$(age_human "$(registry_get "$id" provisioned)")
    online=no
    peer_online "$peers" "$id" && online=yes
    f=""
    if [ -n "$tmpd" ] && [ -s "$tmpd/$id" ]; then
      f=$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print("?"); sys.exit()
print(" ".join("%s:%s"%(k,v.get("state","?")) for k,v in sorted((d.get("tools") or {}).items())) or "-")' "$tmpd/$id")
    elif [ -n "$tmpd" ]; then f="unreachable"; fi
    [ "$state" = revoked ] && [ -n "$(json_list "$(registry_path "$id")" pending_cleanup)" ] && f="${f:+$f }cleanup-pending"
    # a live lock holder means a provision is running right now
    pid=$(lock_pid "$FLEET_VAULT/locks/$id")
    if [ "$state" != revoked ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      state=provisioning
      f="${f:+$f }log: tail -f $FLEET_HOME/reconcile.log"
    fi
    printf '%-18s %-14s %-7s %-12s %-8s %-6s %s\n' "$name" "$id" "$online" "$state" "$profile" "$prov" "$f"
  done
  # Tagged peers that are not registered: shown as unknown, never provisioned.
  printf '%s\n' "$peers" | while IFS="$(printf '\t')" read -r pid host _ online _; do
    [ -n "$pid" ] || continue
    [ -f "$(registry_path "$pid")" ] && continue
    [ "$online" = true ] && online=yes || online=no
    printf '%-18s %-14s %-7s %-12s %-8s %-6s %s\n' "$host" "$pid" "$online" unknown - - -
  done
}

# ---------- provision ----------

# provision_abort_if_revoked ID STEP — true (and audited) when the node was revoked meanwhile.
provision_abort_if_revoked() {
  node_revoked "$1" || return 1
  audit provision "$(registry_get "$1" name)" "abort revoked before $2"
  warn "provision of $(registry_get "$1" name) aborted: node revoked"
  return 0
}

# ship_tree ID SRC_DIR REMOTE_DIR REPO_URL — `git archive HEAD` of SRC_DIR (or a
# tar of the tree when it has no commit) unpacked into REMOTE_DIR on the node
# (the ~ is expanded by the node's shell). Skipped when the node already has a
# git checkout there and REPO_URL is set, i.e. `fleet pull` keeps it current.
ship_tree() {
  local id=$1 src=$2 dest=$3 repo=$4
  if [ -n "$repo" ] && node_ssh "$id" "test -d $dest/.git" </dev/null; then return 0; fi
  if git -C "$src" rev-parse HEAD >/dev/null 2>&1; then
    git -C "$src" archive --format=tar HEAD
  else
    tar -C "$src" --exclude ./.git --exclude './.git/*' -cf - .
  fi | node_ssh "$id" "mkdir -p $dest && tar -x -C $dest"
}

# provision_node ID — contract steps 1-4. Runs inside the lock as a background
# worker (see provision_locked); rechecks the registry before every step so a
# concurrent kick stops it before anything else is shipped.
provision_node() {
  local id=$1 name profile digest fdir names files applied_cc want_cc
  name=$(registry_get "$id" name); profile=$(registry_get "$id" profile)
  digest=$(desired_digest "$profile")
  log "provision $name ($id, profile $profile)"
  # 0. a node enrolled before host keys were pinned gets pinned on its next provision
  known_hosts_has "$(registry_get "$id" dnsname)" || host_key_pin "$(registry_get "$id" user)" "$(registry_get "$id" dnsname)" || true

  # 1. code and config: shipped when the node has no git checkout of them yet
  #    (afterwards `fleet pull` on the node tracks the repos), and on every
  #    provision when there is no repo to pull from.
  provision_abort_if_revoked "$id" code && return 3
  # shellcheck disable=SC2088  # the ~ is expanded by the node's shell, not ours
  ship_tree "$id" "$FLEET_ROOT" '~/.local/share/fleet' "$FLEET_CODE_REPO" \
    || { audit provision "$name" "fail code"; return 1; }
  provision_abort_if_revoked "$id" config && return 3
  config_dir_require
  # shellcheck disable=SC2088
  ship_tree "$id" "$FLEET_CONFIG_DIR" '~/.local/share/fleet-config' "$FLEET_CONFIG_REPO" \
    || { audit provision "$name" "fail config"; return 1; }

  # 2. secrets
  provision_abort_if_revoked "$id" secrets && return 3
  secrets_env "$profile" | node_ssh "$id" 'umask 077; mkdir -p ~/.config/fleet; cat > ~/.config/fleet/secrets.env.tmp && mv ~/.config/fleet/secrets.env.tmp ~/.config/fleet/secrets.env' \
    || { audit provision "$name" "fail secrets"; return 1; }

  # 3. mirrored files: unpacked into a private staging dir on the node and
  #    moved into place one by one (same filesystem: an atomic rename each)
  provision_abort_if_revoked "$id" files && return 3
  fdir="$FLEET_VAULT/files/$profile"
  if [ -d "$fdir" ] && [ -n "$(files_list "$profile")" ]; then
    tar -C "$fdir" -cf - . | node_ssh "$id" "$PROVISION_FILES_SCRIPT" \
      || { audit provision "$name" "fail files"; return 1; }
  fi

  # 3b. replace the node's proxy OAuth files only when asked (they rotate on the node)
  if [ "${FLEET_REFRESH_PROXY_AUTH:-0}" = 1 ]; then
    node_ssh "$id" 'umask 077; mkdir -p ~/.cli-proxy-api && touch ~/.cli-proxy-api/.force' </dev/null \
      || warn "could not request proxy auth refresh on $name"
  fi

  # 3c. the T3 Code client key in the node's authorized_keys (restricted line,
  #     lib/common.sh), present unless `fleet t3 revoke` switched it off
  provision_abort_if_revoked "$id" t3 && return 3
  if [ -f "$(t3_client_key)" ]; then
    if [ "$(registry_get "$id" t3_access)" != false ]; then
      t3_authorize_node "$id" </dev/null || warn "$name: could not authorise the T3 client key"
    else
      t3_deauthorize_node "$id" </dev/null || warn "$name: could not remove the T3 client key"
    fi
  fi

  # 4. bring the node's code and config checkouts to origin/main first (the
  #    tar copies above are only shipped once; afterwards the node tracks the
  #    repos), so the apply below runs the revisions the digest stands for.
  #    A fetch failure only warns on the node: the current copy stays in use.
  provision_abort_if_revoked "$id" pull && return 3
  # shellcheck disable=SC2088  # the ~ is expanded by the node's shell, not ours
  node_ssh "$id" '~/.local/share/fleet/fleet pull --no-apply' </dev/null \
    || warn "$name: fleet pull --no-apply failed; applying the copies it has"

  # 5. apply (CONTRACT: the ~ is expanded by the node's shell)
  provision_abort_if_revoked "$id" apply && return 3
  # shellcheck disable=SC2088
  node_ssh "$id" "~/.local/share/fleet/fleet apply --from-master $digest" </dev/null \
    || { audit provision "$name" "fail apply"; return 1; }

  provision_abort_if_revoked "$id" finalize && return 3
  # what the node really applied (<code>+<config>), compared with this checkout
  applied_cc=$(node_ssh "$id" 'cat ~/.config/fleet/applied_commit 2>/dev/null' </dev/null 2>/dev/null || true)
  want_cc="$(code_rev)+$(config_rev)"
  names=$(secret_names "$profile" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
  files=$(files_list "$profile" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
  registry_set "$id" state provisioned provisioned "$(now_iso)" provisioned_digest "$digest" \
    applied_commit "$applied_cc" secrets_sent "json:$names" files_sent "json:$files"
  if [ -n "$applied_cc" ] && [ "$applied_cc" != "$want_cc" ]; then
    warn "$name applied revs $applied_cc; this checkout is at $want_cc (unpushed commits? nodes only pull what is pushed)"
    audit provision "$name" "ok revs-differ"
  else
    audit provision "$name" ok
  fi
  ok "provisioned $name ($digest)"
}

# The node side of step 3: unpack the mirrored files into a fresh 0700
# staging dir under ~/.config/fleet and rename each one into place, so a
# reader never sees a half-written file. POSIX sh (the node's login shell).
# shellcheck disable=SC2016  # expanded by the node's shell, not ours
PROVISION_FILES_SCRIPT='umask 077; mkdir -p "$HOME/.config/fleet" && s=$(mktemp -d "$HOME/.config/fleet/stage.XXXXXX") && tar -xf - -C "$s" && (cd "$s" && find . -type f | while IFS= read -r f; do f=${f#./}; d=$(dirname "$f"); mkdir -p "$HOME/$d" && mv -f "$f" "$HOME/$f" || exit 1; done); rc=$?; rm -rf "$s"; exit $rc'

# provision_locked ID — caller holds vault/locks/ID. Runs provision_node as a
# background worker whose PID goes into the lock, so `kick` can kill it and
# every ssh/tar it spawned. Returns the worker's exit status.
provision_locked() {
  local id=$1 lock wpid rc=0 tok
  lock="$FLEET_VAULT/locks/$id"
  node_revoked "$id" && return 3
  tok=$(lock_token "$lock")
  ( provision_node "$id" ) &
  wpid=$!
  lock_set_pid "$lock" "$wpid"
  wait "$wpid" || rc=$?
  # take the lock back, unless kick broke it (new token) and holds it now
  [ "$(lock_token "$lock")" = "$tok" ] && [ "$(lock_pid "$lock")" = "$wpid" ] && lock_set_pid "$lock" $$
  return "$rc"
}

cmd_provision() {
  local id lock rc=0 q=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --refresh-proxy-auth) FLEET_REFRESH_PROXY_AUTH=1 ;;
      -*) die "unknown flag: $1" ;;
      *) q=$1 ;;
    esac
    shift
  done
  [ -n "$q" ] || die "usage: fleet provision NODE [--refresh-proxy-auth]"
  set -- "$q"
  vault_require
  id=$(registry_find "$1")
  node_revoked "$id" && die "node $1 is revoked"
  lock="$FLEET_VAULT/locks/$id"
  lock_acquire "$lock" 5 || die "node $1 is locked by another fleet process" "wait, or: fleet kick $1"
  provision_locked "$id" || rc=$?
  lock_release "$lock" $$
  return "$rc"
}

# ---------- reconcile ----------

# pending_for_nonce NONCE — path of a valid, unexpired pending invite, or nothing.
pending_for_nonce() {
  local f
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-]{8,64}$' || return 1
  f="$FLEET_VAULT/nodes/pending/$1.json"
  [ -f "$f" ] || return 1
  [ "$(iso_epoch "$(json_get "$f" expires)")" -gt "$(now_epoch)" ] || return 1
  echo "$f"
}

# claim_rollback CLAIMED_FILE — delete the deploy keys an enrolment recorded
# in its claimed file (gh_code_key / gh_config_key / gh_memory_key, written the
# moment each key is created). A delete that fails goes into pending_cleanup on
# a tombstone registry entry (`rollback-<ts-id>-<nonce>`, state revoked, reason
# enrol), so every reconcile retries it and no key is ever lost. The key
# fields are blanked so a re-pended invite starts clean.
claim_rollback() {
  local cf=$1 id nonce name kd kc km item left="" eph
  [ -f "$cf" ] || return 0
  kd=$(registry_gh_key "$cf" code); kc=$(registry_gh_key "$cf" config); km=$(registry_gh_key "$cf" memory)
  [ -n "$kd$kc$km" ] || return 0
  id=$(json_get "$cf" id); nonce=$(json_get "$cf" nonce); name=$(json_get "$cf" name)
  eph=$(json_get "$cf" ephemeral); [ "$eph" = true ] || eph=false
  for item in $(gh_key_item code "$kd") $(gh_key_item config "$kc") $(gh_key_item memory "$km"); do
    if cleanup_item "$item" >/dev/null 2>&1; then
      audit enrol "$name" "rollback $item ok"
    else
      warn "$name: rollback of $(cleanup_label "$item") FAILED; kept in pending_cleanup, reconcile retries"
      audit enrol "$name" "rollback $item fail"
      left="$left $item"
    fi
  done
  if [ -n "$left" ]; then
    # shellcheck disable=SC2086  # left is a space-separated list by construction
    registry_set "rollback-$id-$nonce" id "rollback-$id-$nonce" name "$name" state revoked \
      revoked "$(now_iso)" revoked_reason enrol missing_since "" \
      ephemeral "json:$eph" profile "$(json_get "$cf" profile)" \
      secrets_sent "json:[]" files_sent "json:[]" pending_cleanup "json:$(words_json $left)"
  fi
  json_set "$cf" gh_code_key "" gh_config_key "" gh_memory_key "" gh_code_repo "" gh_config_repo "" gh_memory_repo ""
}

# claim_release CLAIMED_FILE — enrolment failed: roll back any key it created,
# put the invite back if it is still valid, otherwise revoke its auth key and
# drop it.
claim_release() {
  local cf=$1 nonce key_id
  [ -f "$cf" ] || return 0
  claim_rollback "$cf"
  nonce=$(json_get "$cf" nonce)
  if [ "$(iso_epoch "$(json_get "$cf" expires)")" -gt "$(now_epoch)" ]; then
    mv "$cf" "$FLEET_VAULT/nodes/pending/$nonce.json"
  else
    key_id=$(json_get "$cf" ts_key_id)
    [ -n "$key_id" ] && { api ts key-delete "$key_id" 2>/dev/null || warn "could not revoke expired key $key_id"; }
    rm -f "$cf"
  fi
}

# enrol_peer ID HOST DNS — contract enrolment step 3 for one unknown tagged peer.
# The invite is claimed atomically (mv pending -> claimed) before any key is
# created, so two devices presenting the same nonce cannot both enrol.
enrol_peer() {
  local id=$1 host=$2 dns=$3 user enrol nonce pf cf name profile ephemeral pub_d pub_c pub_m kd="" kc km f sd="" sc sm
  user=$(master_user)
  # If a pending invite carries this hostname, prefer the user recorded with it.
  for f in "$FLEET_VAULT"/nodes/pending/*.json; do
    [ -f "$f" ] || continue
    if [ "$FLEET_HOSTNAME_PREFIX$(json_get "$f" name)" = "$host" ]; then user=$(json_get "$f" user); break; fi
  done
  [ -n "$user" ] || user=$(master_user)
  enrol=$(ssh_to "$user" "$dns" 'cat ~/.config/fleet/enrol.json' </dev/null 2>/dev/null) || return 0   # unreachable: wait
  nonce=$(printf '%s' "$enrol" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("nonce",""))
except Exception: pass')
  pf=$(pending_for_nonce "$nonce") || { [ -n "${FLEET_VERBOSE:-}" ] && warn "peer $host: nonce does not match a pending invite"; return 0; }
  cf="$FLEET_VAULT/nodes/claimed/$nonce.$id.json"
  mv "$pf" "$cf" 2>/dev/null || { [ -n "${FLEET_VERBOSE:-}" ] && warn "peer $host: invite already claimed"; return 0; }
  name=$(json_get "$cf" name); profile=$(json_get "$cf" profile); ephemeral=$(json_get "$cf" ephemeral)
  log "enrol $name ($id, $dns)"
  # The first contact above ran with accept-new; from here on every ssh to this
  # node is strict against the key read from inside that session.
  host_key_pin "$user" "$dns" || true

  pub_c=$(ssh_to "$user" "$dns" 'cat ~/.ssh/fleet_config.pub' </dev/null) || { warn "$name: no ~/.ssh/fleet_config.pub"; claim_release "$cf"; return 0; }
  pub_m=""
  if [ -n "$FLEET_MEMORY_REPO" ]; then
    pub_m=$(ssh_to "$user" "$dns" 'cat ~/.ssh/fleet_memory.pub' </dev/null) || { warn "$name: no ~/.ssh/fleet_memory.pub"; claim_release "$cf"; return 0; }
  fi
  # Each key id lands in the claimed file the moment it exists, together with
  # the repo it was created on: claim_release (failure) and the expiry sweep
  # (crash) roll back from there, against that repo even if the URL changed.
  json_set "$cf" id "$id"
  if repo_needs_key "$FLEET_CODE_REPO"; then
    sd=$(repo_slug "$FLEET_CODE_REPO")
    pub_d=$(ssh_to "$user" "$dns" 'cat ~/.ssh/fleet_code.pub' </dev/null) || { warn "$name: no ~/.ssh/fleet_code.pub"; claim_release "$cf"; return 0; }
    kd=$(printf '%s\n' "$pub_d" | gh_key_create "$sd" "fleet-$name-$id" true) \
      || { warn "$name: GitHub deploy key (code) failed"; audit enrol "$name" "fail gh-code"; claim_release "$cf"; return 0; }
    json_set "$cf" gh_code_key "$kd" gh_code_repo "$sd"
  fi
  sc=$(repo_slug "$FLEET_CONFIG_REPO"); sm=""; km=""
  kc=$(printf '%s\n' "$pub_c" | gh_key_create "$sc" "fleet-$name-$id" true) \
    || { warn "$name: GitHub deploy key (config) failed"; audit enrol "$name" "fail gh-config"; claim_release "$cf"; return 0; }
  json_set "$cf" gh_config_key "$kc" gh_config_repo "$sc"
  if [ -n "$FLEET_MEMORY_REPO" ]; then
    sm=$(repo_slug "$FLEET_MEMORY_REPO")
    km=$(printf '%s\n' "$pub_m" | gh_key_create "$sm" "fleet-$name-$id" false) \
      || { warn "$name: GitHub deploy key (memory) failed"; audit enrol "$name" "fail gh-memory"; claim_release "$cf"; return 0; }
    json_set "$cf" gh_memory_key "$km" gh_memory_repo "$sm"
  fi

  printf '%s' "$enrol" | python3 -c 'import json, sys
try: e = json.load(sys.stdin)
except Exception: e = {}
a = sys.argv
def key(i, repo):
    return {"id": int(i) if i.isdigit() else i, "repo": repo} if i else None
d = {"id": a[1], "name": a[2], "hostname": a[3], "dnsname": a[4], "user": a[5],
     "os": e.get("os", ""), "arch": e.get("arch", ""), "container": bool(e.get("container", False)),
     "profile": a[6], "ephemeral": a[7] == "true", "state": "enrolled", "enrolled": a[10],
     "provisioned": "", "provisioned_digest": "", "applied_commit": "", "missing_since": "", "pending_cleanup": [],
     "github_keys": {"code": key(a[11], a[12]), "config": key(a[8], a[13]), "memory": key(a[9], a[14])},
     "secrets_sent": [], "files_sent": []}
print(json.dumps(d, indent=2, sort_keys=True))' \
    "$id" "$name" "$host" "$dns" "$user" "$profile" "$ephemeral" "$kc" "$km" "$(now_iso)" "$kd" "$sd" "$sc" "$sm" \
    | atomic_write "$(registry_path "$id")" 0600
  rm -f "$cf"
  audit enrol "$name" ok
  ok "enrolled $name"
  provision_locked "$id" || true
}

# device_listed DEVICES_JSON ID — true when the API device list contains ID.
device_listed() {
  printf '%s' "$1" | python3 -c 'import json,sys; sys.exit(0 if any(d.get("nodeId")==sys.argv[1] or d.get("id")==sys.argv[1] for d in json.load(sys.stdin)) else 1)' "$2"
}

# missing_grace ID — seconds a node may be absent from the device list.
missing_grace() {
  if [ "$(registry_get "$1" ephemeral)" = true ]; then echo 3600
  else echo $(( ${FLEET_MISSING_GRACE_HOURS:-24} * 3600 )); fi
}

# memory_seed — make sure the memory repo has the vault scaffolding from
# templates/memory (README, INDEX.md, index workflow, notes/, nodes/). Adds only
# missing files, so it is safe on a repo nodes already write to. Uses the
# master's own git credentials. At most once an hour (vault/memory.checked).
memory_seed() {
  local mark="$FLEET_VAULT/memory.checked" tmpd f n=0
  [ -n "${FLEET_MEMORY_REPO:-}" ] && [ "${FLEET_MEMORY_SEED:-1}" != 0 ] || return 0
  if [ -f "$mark" ] && [ $(( $(now_epoch) - $(cat "$mark" 2>/dev/null || echo 0) )) -lt 3600 ]; then return 0; fi
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fleet-memory.XXXXXX")
  if ! GIT_TERMINAL_PROMPT=0 git clone --quiet "$FLEET_MEMORY_REPO" "$tmpd/m" >/dev/null 2>&1; then
    warn "memory seed: cannot clone $FLEET_MEMORY_REPO with the master's git credentials; retrying in an hour"
    now_epoch >"$mark"; rm -rf "$tmpd"; return 0
  fi
  (cd "$FLEET_ROOT/templates/memory" && find . -type f ! -name '.DS_Store' ! -path '*/__pycache__/*') | while IFS= read -r f; do
    f=${f#./}
    [ -e "$tmpd/m/$f" ] && continue
    mkdir -p "$(dirname "$tmpd/m/$f")"
    cp -p "$FLEET_ROOT/templates/memory/$f" "$tmpd/m/$f"
  done
  git -C "$tmpd/m" add -A
  if ! git -C "$tmpd/m" diff --cached --quiet; then
    n=$(git -C "$tmpd/m" diff --cached --name-only | wc -l | tr -d ' ')
    if git -C "$tmpd/m" -c user.name="fleet master" -c user.email="fleet-master@localhost" \
         commit --quiet -m "add memory vault scaffolding" \
       && git -C "$tmpd/m" push --quiet origin HEAD:main >/dev/null 2>&1; then
      ok "memory seed: added $n template file(s) to the memory repo"; audit "memory.seed" "-" "ok $n"
    else
      warn "memory seed: push failed; retrying on a later reconcile"
    fi
  fi
  now_epoch >"$mark"
  rm -rf "$tmpd"
}

cmd_reconcile() {
  vault_require
  [ -n "${1:-}" ] && die "usage: fleet reconcile"
  local peers pid host dns online lock id state f key_id applied digest profile devices missing_since rk stops
  peers=$(ts_peers)
  memory_seed

  # 1. expired invites (pending or half-claimed): drop the file, revoke the
  #    unused key. A claimed file left by a crashed enrolment carries the deploy
  #    key ids it created: roll them back, unless the registry entry exists
  #    (the crash came after the registry write, the keys are in use).
  for f in "$FLEET_VAULT"/nodes/pending/*.json "$FLEET_VAULT"/nodes/claimed/*.json; do
    [ -f "$f" ] || continue
    if [ "$(iso_epoch "$(json_get "$f" expires)")" -le "$(now_epoch)" ]; then
      id=$(json_get "$f" id); rk=""
      [ -n "$id" ] && [ -f "$(registry_path "$id")" ] && rk=$(registry_gh_key "$(registry_path "$id")" config)
      if [ -n "$rk" ] && [ "${rk%% *}" = "$(json_get "$f" gh_config_key)" ]; then
        rm -f "$f"; continue
      fi
      claim_rollback "$f"
      key_id=$(json_get "$f" ts_key_id)
      if [ -n "$key_id" ]; then api ts key-delete "$key_id" 2>/dev/null || warn "could not revoke expired key $key_id"; fi
      audit "invite.expire" "$(json_get "$f" name)" ok
      rm -f "$f"
    fi
  done

  # 2. online tagged peers: enrol unknown ones, converge known ones
  printf '%s\n' "$peers" | while IFS="$(printf '\t')" read -r pid host dns online _; do
    [ -n "$pid" ] && [ "$online" = true ] || continue
    lock="$FLEET_VAULT/locks/$pid"
    if [ ! -f "$(registry_path "$pid")" ]; then
      lock_acquire "$lock" || continue
      enrol_peer "$pid" "$host" "$dns" || true
      lock_release "$lock" $$
      continue
    fi
    state=$(registry_get "$pid" state)
    [ "$state" = revoked ] && continue
    known_hosts_has "$dns" || host_key_pin "$(registry_get "$pid" user)" "$dns" || true
    profile=$(registry_get "$pid" profile)
    digest=$(desired_digest "$profile")
    if [ "$state" = provisioned ] && [ "$(registry_get "$pid" provisioned_digest)" = "$digest" ]; then
      applied=$(node_ssh "$pid" 'cat ~/.config/fleet/applied 2>/dev/null' </dev/null 2>/dev/null || true)
      [ "$applied" = "$digest" ] && continue
    fi
    lock_acquire "$lock" || continue
    provision_locked "$pid" || true
    lock_release "$lock" $$
  done
  # the master's ssh config follows the registry (lib/t3.sh; no-op without the T3 key)
  t3_ssh_config_write

  # 3. revoked nodes: retry pending cleanup. Runs before, and regardless of,
  #    the device list call below: a failing API must not postpone deletes.
  #    An enrolment-rollback tombstone is forgotten as soon as it is clean.
  for id in $(registry_ids); do
    node_revoked "$id" || continue
    [ -n "$(json_list "$(registry_path "$id")" pending_cleanup)" ] || continue
    lock="$FLEET_VAULT/locks/$id"
    lock_acquire "$lock" || continue
    cleanup_pending "$id" >/dev/null 2>&1 || true
    if [ -z "$(json_list "$(registry_path "$id")" pending_cleanup)" ] && [ "$(registry_get "$id" revoked_reason)" = enrol ]; then
      audit forget "$(registry_get "$id" name)" "enrol rollback done"
      rm -f "$(registry_path "$id")"
    fi
    lock_release "$lock" $$
  done

  # 4. every registered node against the API device list: track absence, revoke after the grace period
  [ -n "$(registry_ids)" ] || return 0
  devices=$(api ts devices 2>/dev/null) || devices=""
  [ -n "$devices" ] || { warn "could not list tailnet devices; absence tracking skipped this run"; return 0; }
  for id in $(registry_ids); do
    if device_listed "$devices" "$id"; then
      [ -n "$(registry_get "$id" missing_since)" ] && registry_set "$id" missing_since ""
      continue
    fi
    # a pending remote stop or T3 revoke needs the node on the tailnet; the device is gone, drop it
    stops=$(json_list "$(registry_path "$id")" pending_cleanup | grep '^stop:\|^t3:' || true)
    if [ -n "$stops" ]; then
      lock="$FLEET_VAULT/locks/$id"
      if lock_acquire "$lock"; then
        # shellcheck disable=SC2046  # the list is space-separated by construction
        registry_set "$id" pending_cleanup "json:$(words_json $(json_list "$(registry_path "$id")" pending_cleanup | grep -v '^stop:\|^t3:' || true))"
        audit cleanup "$(registry_get "$id" name)" "$(echo "$stops" | tr '\n' ' ')dropped (device gone)"
        lock_release "$lock" $$
      fi
    fi
    missing_since=$(registry_get "$id" missing_since)
    if [ -z "$missing_since" ]; then registry_set "$id" missing_since "$(now_iso)"; continue; fi
    [ $(( $(now_epoch) - $(iso_epoch "$missing_since") )) -ge "$(missing_grace "$id")" ] || continue
    lock="$FLEET_VAULT/locks/$id"
    lock_acquire "$lock" || continue
    if ! node_revoked "$id"; then
      warn "$(registry_get "$id" name) ($id) has been gone from the tailnet since $missing_since: revoking its deploy keys"
      revoke_node "$id" gone
      cleanup_pending "$id" >/dev/null 2>&1 || true     # first attempt now; step 3 retries what failed
      warn "rotate the secrets it held: $(json_list "$(registry_path "$id")" secrets_sent | tr '\n' ' ')"
    fi
    lock_release "$lock" $$
  done

  # 5. forget a revoked tombstone once it is clean and the device has been
  #    gone for the grace period (the device list above is current)
  for id in $(registry_ids); do
    node_revoked "$id" || continue
    [ -z "$(json_list "$(registry_path "$id")" pending_cleanup)" ] || continue
    missing_since=$(registry_get "$id" missing_since)
    [ -n "$missing_since" ] && [ $(( $(now_epoch) - $(iso_epoch "$missing_since") )) -ge "$(missing_grace "$id")" ] || continue
    lock="$FLEET_VAULT/locks/$id"
    lock_acquire "$lock" || continue
    if [ -z "$(json_list "$(registry_path "$id")" pending_cleanup)" ]; then
      log "forget $(registry_get "$id" name) ($id): revoked, cleanup done, gone from the tailnet"
      audit forget "$(registry_get "$id" name)" gone
      rm -f "$(registry_path "$id")"
    fi
    lock_release "$lock" $$
  done
}

# ---------- revoke / cleanup (shared by kick and reconcile) ----------

# revoke_node ID REASON — caller holds the lock. Marks the entry revoked and
# records what still has to be deleted; the entry stays as a tombstone until
# cleanup_pending has emptied the list.
revoke_node() {
  local id=$1 reason=$2 rp items=""
  rp=$(registry_path "$id")
  [ "$reason" = kick ] && items="ts:device:$id"
  items="$items $(gh_key_item code "$(registry_gh_key "$rp" code)") $(gh_key_item config "$(registry_gh_key "$rp" config)") $(gh_key_item memory "$(registry_gh_key "$rp" memory)")"
  # shellcheck disable=SC2086  # items is a space-separated list by construction
  registry_set "$id" state revoked revoked "$(now_iso)" revoked_reason "$reason" pending_cleanup "json:$(words_json $items)"
  audit revoke "$(registry_get "$id" name)" "$reason"
}

# cleanup_label ITEM — human name for a pending_cleanup entry.
cleanup_label() {
  case "$1" in
    ts:device:*) echo "tailscale device delete" ;;
    gh:code:*)   echo "github deploy key (code) delete" ;;
    gh:config:*) echo "github deploy key (config) delete" ;;
    gh:memory:*) echo "github deploy key (memory) delete" ;;
    stop:*)      echo "remote stop (fleet leave)" ;;
    t3:*)        echo "T3 access revoke on the node" ;;
    *) echo "$1" ;;
  esac
}

# cleanup_gh_delete KIND REST — REST is "<key id>:<owner/repo>" (the repo the
# key was created on) or, for an entry recorded before slugs were kept, just
# "<key id>": only then the current URL is used, as the best information left.
cleanup_gh_delete() {
  local kind=$1 rest=$2 kid slug="" url
  kid=${rest%%:*}
  case "$rest" in *:*) slug=${rest#*:} ;; esac
  if [ -z "$slug" ]; then
    case "$kind" in code) url=$FLEET_CODE_REPO ;; config) url=$FLEET_CONFIG_REPO ;; *) url=$FLEET_MEMORY_REPO ;; esac
    [ -n "$url" ] || { warn "no repo recorded for the $kind deploy key $kid and FLEET_$(echo "$kind" | tr '[:lower:]' '[:upper:]')_REPO is unset; cannot delete it"; return 1; }
    slug=$(repo_slug "$url")
  fi
  gh_key_delete "$slug" "$kid"
}

# cleanup_item ITEM — run one entry: ts:device:<id> | gh:<code|config|memory>:<key id>:<owner/repo>
# | stop:<id> (rerun `fleet leave` on a node whose stop failed during kick;
# only attempted while the node is online, dropped by reconcile once the
# device has left the tailnet).
cleanup_item() {
  local val
  case "$1" in
    ts:device:*) api ts device-delete "${1#ts:device:}" ;;
    gh:code:*)   cleanup_gh_delete code "${1#gh:code:}" ;;
    gh:config:*) cleanup_gh_delete config "${1#gh:config:}" ;;
    gh:memory:*) cleanup_gh_delete memory "${1#gh:memory:}" ;;
    stop:*)      val=${1#stop:}
                 peer_online "$(ts_peers)" "$val" || return 1
                 # shellcheck disable=SC2088  # remote shell expands ~
                 with_timeout 60 node_ssh "$val" '~/.local/bin/fleet leave' ;;
    t3:*)        val=${1#t3:}
                 peer_online "$(ts_peers)" "$val" || return 1
                 with_timeout 300 t3_node_revoke "$val" ;;
    *) warn "unknown cleanup item $1 (dropped)"; return 0 ;;
  esac
}

# cleanup_pending ID — retry every pending_cleanup entry, keep the ones that
# still fail. Reports each. Returns 0 when the list is empty afterwards.
cleanup_pending() {
  local id=$1 item left="" name
  name=$(registry_get "$id" name)
  for item in $(json_list "$(registry_path "$id")" pending_cleanup); do
    if cleanup_item "$item" >/dev/null 2>&1; then
      ok "$(cleanup_label "$item"): ok"; audit cleanup "$name" "$item ok"
    else
      warn "$(cleanup_label "$item"): FAILED (kept in pending_cleanup, reconcile retries)"; audit cleanup "$name" "$item fail"
      left="$left $item"
    fi
  done
  # shellcheck disable=SC2086
  registry_set "$id" pending_cleanup "json:$(words_json $left)"
  [ -z "$left" ]
}

# ---------- kick ----------

cmd_kick() {
  local yes=0 q="" id name lock i=0 results="" n left stop_failed=0 t3_failed=0
  while [ $# -gt 0 ]; do
    case "$1" in --yes|-y) yes=1 ;; -*) die "unknown flag: $1" ;; *) q=$1 ;; esac; shift
  done
  [ -n "$q" ] || die "usage: fleet kick NODE [--yes]"
  vault_require
  id=$(registry_find "$q"); name=$(registry_get "$id" name)
  if [ "$yes" != 1 ]; then
    printf 'Revoke %s (%s): stops it, deletes it from the tailnet, revokes its repo keys.\n' "$name" "$id" >&2
    typed_confirm 'Type the node name to confirm: ' "$name" || die "aborted"
  fi

  # 1. take the node lock: kill an in-flight provision (worker + its ssh/tar)
  #    and take its lock over in place (lock_break), or acquire a free one;
  #    then hold it so no reconcile can start another provision. A lock that
  #    changed hands while its holder was being killed is never deleted; the
  #    loop just breaks the new holder too.
  lock="$FLEET_VAULT/locks/$id"
  while :; do
    lock_break "$lock" && break
    lock_acquire "$lock" && break
    i=$((i + 1)); [ "$i" -ge 5 ] && die "could not take the lock for $name" "retry: fleet kick $q"
  done
  # 2. state under the lock: nothing can re-provision from here on
  revoke_node "$id" kick
  audit kick "$name" "revoked"
  ok "registry: $name marked revoked"

  # 3. each step independent, each reported. A failed remote stop is queued
  #    as stop:<id>, a failed T3 revoke as t3:<id>: reconcile retries them
  #    while the node is still on the tailnet and drops them once the device
  #    is gone.
  if [ -f "$(t3_client_key)" ]; then
    # one `t3 auth session revoke` per session: a node with many stale sessions takes a while
    if with_timeout 300 t3_node_revoke "$id" >/dev/null 2>&1; then
      ok "t3 access: revoked (sessions, pairing tokens, client key)"
    else
      warn "t3 access: FAILED (node offline or already gone); kept in pending_cleanup"; t3_failed=1
    fi
  fi
  # shellcheck disable=SC2088  # remote shell expands ~
  if with_timeout 60 node_ssh "$id" '~/.local/bin/fleet leave' >/dev/null 2>&1; then
    ok "remote stop: ok"; results="$results stop=ok"
  else
    warn "remote stop: FAILED (node offline or already gone); kept in pending_cleanup"; results="$results stop=fail"; stop_failed=1
  fi
  cleanup_pending "$id" || true
  if [ "$t3_failed" = 1 ]; then
    # shellcheck disable=SC2046  # the list is space-separated by construction
    registry_set "$id" pending_cleanup "json:$(words_json t3:"$id" $(json_list "$(registry_path "$id")" pending_cleanup))"
  fi
  if [ "$stop_failed" = 1 ]; then
    # shellcheck disable=SC2046
    registry_set "$id" pending_cleanup "json:$(words_json stop:"$id" $(json_list "$(registry_path "$id")" pending_cleanup))"
  fi
  t3_ssh_config_write
  left=$(json_list "$(registry_path "$id")" pending_cleanup | tr '\n' ' ')
  case "$left" in *ts:device:*) results="$results ts=fail" ;; *) results="$results ts=ok" ;; esac
  case "$left" in *gh:*) results="$results gh=fail" ;; *) results="$results gh=ok" ;; esac
  if [ -f "$(t3_client_key)" ]; then case "$left" in *t3:*) results="$results t3=fail" ;; *) results="$results t3=ok" ;; esac; fi
  [ -n "$left" ] && warn "pending cleanup (retried by every reconcile): $left"
  lock_release "$lock" $$

  n=$(json_list "$(registry_path "$id")" secrets_sent | tr '\n' ' ')
  if [ -n "$n" ]; then
    printf 'Rotate these secrets (the node still holds them): %s\n' "$n"
  else
    printf 'No secrets were sent to %s.\n' "$name"
  fi
  audit kick "$name" "done$results"
}

# ---------- config publish ----------

# fleet config publish [--yes] [--no-capture] — capture this machine's harness
# config and skills into the config repo ($FLEET_CONFIG_DIR), show what changed,
# commit and push it. Never touches the fleeter checkout.
cmd_config_publish() {
  local capture=1 yes=0 dir n ans remote="" ahead d
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-capture) capture=0 ;;
      --yes|-y) yes=1 ;;
      *) die "usage: fleet config publish [--yes] [--no-capture]" ;;
    esac; shift
  done
  need git
  config_dir_require
  dir=$FLEET_CONFIG_DIR
  [ -d "$dir/.git" ] || die "$dir is not a git checkout" "git -C $dir init && git -C $dir remote add origin \$FLEET_CONFIG_REPO"
  # the commit below needs an identity; find out now, before capture rewrites anything
  [ -n "$(git -C "$dir" config --get user.name 2>/dev/null)" ] && [ -n "$(git -C "$dir" config --get user.email 2>/dev/null)" ] \
    || die "git has no identity for $dir (user.name / user.email)" \
      "git config --global user.name 'Your Name' && git config --global user.email you@example.com   (or set them in that repo), then rerun"
  if [ "$capture" = 1 ] && type harness_capture >/dev/null 2>&1; then
    log "capture is authoritative: harness/ and skills/ are rewritten from this machine's live config;"
    log "a skill that is not installed here (e.g. the starter skills/fleet-notes) is removed — install it here to keep it, or use --no-capture"
    harness_capture
  fi
  # The scan runs on every publish, captured or not: hand-edited files are
  # committed through the same path and must not carry a secret either.
  if type harness_secret_scan >/dev/null 2>&1; then
    log "secret scan"
    for d in harness skills; do
      [ -d "$dir/$d" ] || continue
      harness_secret_scan "$dir/$d" || die "secrets or machine paths found in $dir/$d" "remove them (or add the skill to FLEET_SKILL_EXCLUDE / the server marker to FLEET_CAPTURE_MACHINE_ONLY); never commit the hit"
    done
  fi
  git -C "$dir" add -A
  n=$(git -C "$dir" diff --cached --name-only | grep -c . || true)
  remote=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  if [ "$n" = 0 ]; then
    ok "nothing to commit in $dir"
  else
    git -C "$dir" --no-pager diff --cached --stat >&2
    git -C "$dir" --no-pager diff --cached | head -n "${FLEET_PUBLISH_DIFF_LINES:-200}" >&2
    if [ "$yes" != 1 ]; then
      printf 'Commit %s changed file(s) in %s and push to %s? [y/N] ' "$n" "$dir" "${remote:-<no remote>}" >&2
      IFS= read -r ans || true
      case "$ans" in y|Y|yes) ;; *) git -C "$dir" reset -q; die "aborted; nothing committed" "rerun with --yes to skip the question" ;; esac
    fi
    git -C "$dir" commit -q -m 'publish fleet config'
    ok "committed $(git -C "$dir" rev-parse --short HEAD)"
  fi
  if [ -z "$remote" ]; then
    warn "no origin remote in $dir; nodes cannot pull it until you add one: git -C $dir remote add origin ${FLEET_CONFIG_REPO:-<FLEET_CONFIG_REPO>}"
    audit "config.publish" "-" "committed-no-remote"
    return 0
  fi
  ahead=$(git -C "$dir" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 1)
  if [ "$ahead" = 0 ]; then ok "already pushed"; return 0; fi
  if GIT_TERMINAL_PROMPT=0 git -C "$dir" push -q -u origin HEAD; then
    ok "pushed to $remote (nodes pick it up within $FLEET_PULL_EVERY min; or: fleet reconcile)"
    audit "config.publish" "-" "pushed"
  else
    audit "config.publish" "-" "push-failed"
    die "git push failed" "fix the remote/branch and rerun: git -C $dir push"
  fi
}

# ---------- doctor ----------

# mode_of FILE — octal permission bits, portable.
mode_of() {
  if stat -f %Lp "$1" >/dev/null 2>&1; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

# isolation_probe ID IP PORT LABEL — from node ID, try `nc -z` to IP:PORT.
# Prints "fail" when the connection succeeded or the probe could not run on
# the node (no nc: an untestable node is not a passed test), "ok" when
# refused, "skip" when ssh itself failed.
isolation_probe() {
  local rc=0
  node_ssh "$1" "nc -z -w 3 $2 $3" </dev/null >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) warn "ISOLATION FAIL: $(registry_get "$1" name) reached $4 ($2:$3); nodes must not reach the tailnet. Fix the policy: fleet policy check"; echo fail ;;
    255) warn "$(registry_get "$1" name): ssh failed, isolation not tested"; echo skip ;;
    127|126) warn "ISOLATION FAIL: $(registry_get "$1" name) has no nc, probe to $4 ($2:$3) could not run; install netcat on the node"; echo fail ;;
    *) echo ok ;;
  esac
}

# doctor_isolation — negative test from every online provisioned node: the
# master on 22 and 443, and one other node on 22. Prints one line on success.
doctor_isolation() {
  local peers master_ip ids="" id other other_ip fails=0 probes=0 r
  master_ip=$(master_ts_ip)
  [ -n "$master_ip" ] || { warn "isolation: cannot determine the master's tailnet IP (tailscale ip -4)"; return 1; }
  peers=$(ts_peers)
  for id in $(registry_ids); do
    [ "$(registry_get "$id" state)" = provisioned ] && peer_online "$peers" "$id" && ids="$ids $id"
  done
  [ -n "$ids" ] || { log "isolation: no online provisioned node to test from"; return 0; }
  for id in $ids; do
    other_ip=""
    for other in $ids; do
      [ "$other" = "$id" ] && continue
      other_ip=$(peer_ip "$peers" "$other"); [ -n "$other_ip" ] && break
    done
    for r in "$(isolation_probe "$id" "$master_ip" 22 "the master's ssh")" \
             "$(isolation_probe "$id" "$master_ip" 443 "the master on 443")"; do
      case "$r" in fail) fails=$((fails + 1)); probes=$((probes + 1)) ;; ok) probes=$((probes + 1)) ;; esac
    done
    if [ -n "$other_ip" ]; then
      r=$(isolation_probe "$id" "$other_ip" 22 "another node's ssh")
      case "$r" in fail) fails=$((fails + 1)); probes=$((probes + 1)) ;; ok) probes=$((probes + 1)) ;; esac
    fi
  done
  [ "$fails" = 0 ] && ok "isolation: $probes probe(s) from $(echo "$ids" | wc -w | tr -d ' ') node(s); none reached the master or another node"
  return "$fails"
}

cmd_doctor() {
  local fails=0 f id m rc
  vault_require
  for f in "$FLEET_VAULT" "$FLEET_VAULT/secrets" "$FLEET_VAULT/ssh" "$FLEET_VAULT/nodes" "$FLEET_VAULT/files"; do
    [ -d "$f" ] || continue
    m=$(mode_of "$f")
    if [ "$m" = 700 ]; then ok "dir $f $m"; else warn "dir $f is $m, want 700"; fails=$((fails + 1)); fi
  done
  for f in "$FLEET_VAULT"/secrets/*.env "$FLEET_VAULT/tailscale.json" "$FLEET_VAULT/github.json" "$FLEET_VAULT/digest.key" \
           "$FLEET_VAULT/ssh/fleet_master" "$FLEET_VAULT/ssh/t3_client" "$FLEET_VAULT/ssh/known_hosts" "$(t3_ssh_include)" "$FLEET_VAULT"/nodes/*.json; do
    [ -f "$f" ] || continue
    m=$(mode_of "$f")
    if [ "$m" = 600 ]; then :; else warn "file $f is $m, want 600"; fails=$((fails + 1)); fi
  done
  ok "file modes checked"
  [ -f "$FLEET_VAULT/digest.key" ] || { warn "digest.key missing (run: fleet init master)"; fails=$((fails + 1)); }
  if [ -d "$FLEET_CONFIG_DIR" ]; then
    if [ -d "$FLEET_CONFIG_DIR/.git" ] && [ -n "$(git -C "$FLEET_CONFIG_DIR" status --porcelain 2>/dev/null)" ]; then
      warn "config dir $FLEET_CONFIG_DIR has uncommitted changes; nodes only get what is pushed (fleet config publish)"
    else ok "config dir $FLEET_CONFIG_DIR"; fi
  else warn "config dir missing: $FLEET_CONFIG_DIR (fleet init master --config-dir DIR)"; fails=$((fails + 1)); fi
  for f in FLEET_CODE_REPO FLEET_CONFIG_REPO; do
    eval "m=\${$f:-}"; [ -n "$m" ] || { warn "$f is empty (set it in $FLEET_CONFIG_DIR/fleet.conf)"; fails=$((fails + 1)); }
  done
  [ -n "${FLEET_MEMORY_REPO:-}" ] || log "FLEET_MEMORY_REPO is empty: shared memory is off"
  if [ -f "$(t3_client_key)" ]; then ok "t3 remote access: client key present (fleet t3 status)"; else log "t3 remote access: off (FLEET_T3_REMOTE=1 or fleet t3 setup enables it)"; fi

  if [ -f "$FLEET_VAULT/tailscale.json" ]; then
    if api ts check >/dev/null 2>&1; then ok "tailscale oauth: token exchange works"; else warn "tailscale oauth: token exchange FAILED"; fails=$((fails + 1)); fi
    rc=0; policy_check_live || rc=$?
    case "$rc" in
      0) ok "policy: live tailnet policy isolates $FLEET_NODE_TAG" ;;
      2) warn "policy: cannot read the live policy (OAuth client needs policy_file:read)"; fails=$((fails + 1)) ;;
      *) warn "policy: live tailnet policy does not isolate $FLEET_NODE_TAG; run: fleet policy apply"; fails=$((fails + 1)) ;;
    esac
  else warn "tailscale oauth: not configured"; fails=$((fails + 1)); fi
  if gh_cli; then ok "github: gh logged in as $(gh_login)"
  elif [ -f "$FLEET_VAULT/github.json" ]; then
    if m=$(api gh user 2>/dev/null) && [ -n "$m" ]; then ok "github token: ok ($m)"; else warn "github token: FAILED"; fails=$((fails + 1)); fi
  else warn "github: neither gh login nor a token (deploy keys cannot be registered)"; fi

  case "$(fleet_os)" in
    macos) f="$HOME/Library/LaunchAgents/dev.fleet.reconcile.plist" ;;
    *)     f="$HOME/.config/systemd/user/fleet-reconcile.timer" ;;
  esac
  if [ -f "$f" ]; then ok "reconcile schedule installed: $f"; else warn "reconcile schedule missing (run: fleet init master)"; fails=$((fails + 1)); fi

  rc=0; doctor_isolation || rc=$?
  fails=$((fails + rc))

  for id in $(registry_ids); do
    [ -n "$(registry_get "$id" missing_since)" ] && log "missing from tailnet: $(registry_get "$id" name) ($id) since $(registry_get "$id" missing_since), state=$(registry_get "$id" state)"
    if node_revoked "$id" && [ -n "$(json_list "$(registry_path "$id")" pending_cleanup)" ]; then
      warn "revoked $(registry_get "$id" name) ($id) still has cleanup pending: $(json_list "$(registry_path "$id")" pending_cleanup | tr '\n' ' ')"; fails=$((fails + 1))
    fi
  done
  for f in "$FLEET_VAULT"/nodes/pending/*.json "$FLEET_VAULT"/nodes/claimed/*.json; do
    [ -f "$f" ] || continue
    log "pending invite: $(json_get "$f" name) expires $(json_get "$f" expires)"
  done
  if [ "$fails" = 0 ]; then ok "doctor: all checks passed"; else warn "doctor: $fails problem(s)"; return 1; fi
}
