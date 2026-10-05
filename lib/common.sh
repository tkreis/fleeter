# shellcheck shell=bash
# Shared helpers for fleet. Sourced, never executed.
#
# Portability contract (see docs/ARCHITECTURE.md): bash 3.2, no associative arrays, no
# mapfile, no ${var,,}, no GNU-only flags, no flock, no sed -i.
# Helpers declare their variables local: bash scoping is dynamic, so a plain
# assignment here would overwrite a caller's local of the same name.

export FLEET_VERSION="0.6.1"

: "${FLEET_HOME:=$HOME/.config/fleet}"          # node + master state
: "${FLEET_VAULT:=$FLEET_HOME/vault}"           # master only
: "${FLEET_SHARE:=$HOME/.local/share/fleet}"    # installed copy of the fleeter code on nodes
: "${FLEET_BIN:=$HOME/.local/bin}"
FLEET_CONFIG_DIR_DEFAULT="$HOME/.local/share/fleet-config"   # where provision drops the config repo on nodes

# ---------- configuration ----------

# fleet_load_config — defaults.conf, then the local override (which may set
# FLEET_CONFIG_DIR), then the config repo's fleet.conf, then the local override
# again so it always wins. A FLEET_CONFIG_DIR that is already set when this
# runs (environment, or `--config-dir` in the same process) is kept: it beats
# the value recorded in the local file. Safe to call more than once.
# fleet_path_setup — put the user-level tool dirs on PATH. ssh sessions,
# launchd and systemd start with a bare PATH, so without this a tool installed
# into ~/.local/bin (claude, mise, cursor-agent) or Docker Desktop's CLI looks
# "missing" to the next step. Idempotent; only adds dirs that exist.
fleet_path_setup() {
  local d
  for d in /usr/local/bin /opt/homebrew/bin "$HOME/.docker/bin" \
           /Applications/Docker.app/Contents/Resources/bin \
           "$HOME/.local/share/mise/shims" "${FLEET_BIN:-$HOME/.local/bin}"; do
    [ -d "$d" ] || continue
    case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
  done
  export PATH
}

# docker_ready [WAIT_SECONDS] — true when the docker daemon answers. On macOS
# with Docker Desktop installed but not running, start it (no window) and wait.
docker_ready() {
  local wait=${1:-120} i=0
  have docker || return 1
  docker info >/dev/null 2>&1 && return 0
  if [ "$(fleet_os)" = macos ] && [ -d /Applications/Docker.app ]; then
    log "starting Docker Desktop (waiting up to ${wait}s for the daemon)"
    open -g -a Docker >/dev/null 2>&1 || return 1
    while [ "$i" -lt "$wait" ]; do
      docker info >/dev/null 2>&1 && return 0
      sleep 3; i=$((i + 3))
    done
  fi
  return 1
}

fleet_load_config() {
  local env_cfg=${FLEET_CONFIG_DIR:-}
  # shellcheck source=config/defaults.conf
  . "$FLEET_ROOT/config/defaults.conf"
  # shellcheck source=/dev/null
  [ -f "$FLEET_HOME/fleet.conf" ] && . "$FLEET_HOME/fleet.conf"
  [ -n "$env_cfg" ] && FLEET_CONFIG_DIR=$env_cfg
  : "${FLEET_CONFIG_DIR:=$FLEET_CONFIG_DIR_DEFAULT}"
  # shellcheck source=/dev/null
  [ -f "$FLEET_CONFIG_DIR/fleet.conf" ] && . "$FLEET_CONFIG_DIR/fleet.conf"
  # shellcheck source=/dev/null
  [ -f "$FLEET_HOME/fleet.conf" ] && . "$FLEET_HOME/fleet.conf"
  [ -n "$env_cfg" ] && FLEET_CONFIG_DIR=$env_cfg
  export FLEET_CONFIG_DIR
  fleet_path_setup
  return 0
}

# config_dir_require — the config repo checkout must exist for anything that
# renders instructions, harness templates or skills.
config_dir_require() {
  [ -d "$FLEET_CONFIG_DIR" ] && return 0
  die "fleet config dir not found: $FLEET_CONFIG_DIR" \
    "master: fleet init master --config-dir DIR (a checkout of your fleet-config repo; start from examples/fleet-config). node: wait for the master's provision, or fleet pull"
}

# repo_require VAR — die when a repo URL is not configured.
repo_require() {
  local v
  eval "v=\${$1:-}"
  [ -n "$v" ] && return 0
  die "$1 is not set" "set it in $FLEET_CONFIG_DIR/fleet.conf (or $FLEET_HOME/fleet.conf); see examples/fleet-config/fleet.conf"
}

# repo_is_https URL — true for an https:// URL (a public repo: no deploy key).
repo_is_https() { case "$1" in https://*|http://*) return 0 ;; *) return 1 ;; esac; }

# repo_needs_key URL — a deploy key is registered only for non-empty, non-https URLs.
repo_needs_key() { [ -n "$1" ] && ! repo_is_https "$1"; }

# conf_set FILE KEY VALUE — set KEY='VALUE' (shell-safe) in a KEY=VALUE conf file, 0600.
conf_set() {
  local f=$1 k=$2 v=$3 q="'" esc
  esc=${v//$q/$q\\$q$q}
  { if [ -f "$f" ]; then grep -v "^$k=" "$f" || true; fi; printf "%s='%s'\n" "$k" "$esc"; } | atomic_write "$f" 0600
}

# ---------- output ----------

_fleet_tty() { [ -t 2 ]; }

log()  { if _fleet_tty; then printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; else printf '==> %s\n' "$*" >&2; fi; }
ok()   { if _fleet_tty; then printf '\033[1;32m ok\033[0m %s\n' "$*" >&2; else printf ' ok %s\n' "$*" >&2; fi; }
warn() { if _fleet_tty; then printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; else printf 'warn %s\n' "$*" >&2; fi; }
# die MESSAGE [HINT] — one line saying what failed, one saying what to do next.
die() {
  if _fleet_tty; then printf '\033[1;31merror\033[0m %s\n' "$1" >&2; else printf 'error %s\n' "$1" >&2; fi
  [ -n "${2:-}" ] && printf '  next: %s\n' "$2" >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || die "missing command: $1" "${2:-run 'fleet join' or install $1}"; }

# typed_confirm PROMPT WORD — read a line; true when it equals WORD.
typed_confirm() {
  local typed
  printf '%s' "$1" >&2
  IFS= read -r typed || true
  [ "$typed" = "$2" ]
}

# ---------- platform ----------

fleet_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *)      echo unsupported ;;
  esac
}

fleet_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo arm64 ;;
    x86_64|amd64)  echo amd64 ;;
    *)             uname -m ;;
  esac
}

# True inside a container (Docker, Podman, k8s).
fleet_in_container() {
  [ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ -n "${FLEET_CONTAINER:-}" ]
}

# fleet_is_master — this machine runs the master (an initialised vault and no
# node enrolment). The master takes part in shared memory under its own name.
fleet_is_master() {
  [ -d "$FLEET_VAULT/nodes" ] && [ ! -f "$FLEET_HOME/enrol.json" ]
}

# fleet_master_name — the master's name in the memory vault (nodes/<name>):
# FLEET_MASTER_NAME, else the short hostname; lower-case, [a-z0-9-] only.
fleet_master_name() {
  local n=${FLEET_MASTER_NAME:-}
  [ -n "$n" ] || n=$(hostname -s 2>/dev/null || hostname)
  n=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/^-*//; s/-*$//')
  printf '%s\n' "${n:-master}"
}

# Linux package manager name, or empty.
fleet_pkg_mgr() {
  local m
  if [ "$(fleet_os)" = macos ]; then echo brew; return; fi
  for m in apt-get dnf apk pacman; do have "$m" && { echo "$m"; return; }; done
  echo ""
}

# Run as root: directly if root, via sudo otherwise. Interactive steps only.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else need sudo; sudo "$@"; fi
}

# ---------- files ----------

# atomic_write DEST [MODE] < content — write via tmp + mv in the same directory.
atomic_write() {
  local dest=$1 mode=${2:-0644} tmp
  mkdir -p "$(dirname "$dest")"
  tmp=$(mktemp "$(dirname "$dest")/.fleet.XXXXXX") || die "mktemp failed for $dest"
  if ! cat >"$tmp"; then rm -f "$tmp"; die "write failed: $dest"; fi
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dest"
}

# backup_once FILE — keep the pre-fleet original as FILE.pre-fleet, once.
backup_once() {
  [ -e "$1" ] || return 0
  [ -e "$1.pre-fleet" ] && return 0
  cp -p "$1" "$1.pre-fleet"
}

# Portable sha256 of stdin.
sha256() {
  if have sha256sum; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# sha256 of a directory tree (paths + contents), stable across OSes.
sha256_tree() {
  (cd "$1" && find . -type f ! -name '.DS_Store' ! -path './.git/*' | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s\n' "$f"; cat "$f"
  done) | sha256
}

# realpath without GNU readlink -f.
abspath() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }

# ---------- locks (mkdir-based, portable) ----------
#
# DIR/pid   the process to signal (the acquirer, or a worker via lock_set_pid)
# DIR/token random ownership token written by lock_acquire/lock_break; it
#           changes whenever the lock changes hands, so a breaker can tell a
#           replacement owner from the holder it just killed.

# lock_token_new — 16 random hex chars.
lock_token_new() { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }

# lock_acquire DIR [WAIT_SECONDS] — writes holder PID into DIR/pid and a fresh
# token into DIR/token.
lock_acquire() {
  local ldir=$1 wait=${2:-0} i=0 holder
  mkdir -p "$(dirname "$ldir")"
  while ! mkdir "$ldir" 2>/dev/null; do
    holder=$(cat "$ldir/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      warn "removing stale lock $ldir (pid $holder gone)"
      rm -rf "$ldir"; continue
    fi
    [ "$i" -ge "$wait" ] && return 1
    sleep 1; i=$((i + 1))
  done
  lock_token_new >"$ldir/token"
  echo $$ >"$ldir/pid"
}

# lock_set_pid DIR PID — record the process that actually does the work (a
# background worker), so lock_break reaches it and lock_release can verify.
lock_set_pid() { echo "$2" >"$1/pid"; }

# lock_pid DIR — the recorded holder PID, or empty.
lock_pid() { cat "$1/pid" 2>/dev/null || true; }

# lock_token DIR — the recorded ownership token, or empty.
lock_token() { cat "$1/token" 2>/dev/null || true; }

# lock_release DIR [PID] — remove the lock. With PID, only when DIR/pid still
# holds that PID (someone who broke and re-took the lock keeps it).
lock_release() {
  if [ -n "${2:-}" ] && [ "$(lock_pid "$1")" != "$2" ]; then return 0; fi
  rm -rf "$1"
}

# proc_tree PID — PID and all its descendants, one per line. `ps -eo pid=,ppid=`
# works on macOS and procps; no pkill -P dependency (that misses grandchildren
# such as the `bash -c`/`cat` behind an ssh in a pipeline).
proc_tree() {
  { ps -eo pid=,ppid= 2>/dev/null || proc_tree_procfs; } | awk -v root="$1" '
    { pp[$1] = $2 }
    END {
      n = 0; q[n++] = root; print root
      for (i = 0; i < n; i++) for (p in pp) if (pp[p] == q[i] && p != root) { q[n++] = p; print p }
    }'
}

# proc_tree_procfs — "pid ppid" lines from /proc when there is no ps (slim images).
proc_tree_procfs() {
  local d s
  for d in /proc/[0-9]*; do
    s=$(cat "$d/stat" 2>/dev/null) || continue
    s=${s##*) }                     # drop "pid (comm) "; comm may contain spaces
    # shellcheck disable=SC2086
    set -- $s                       # $1 state, $2 ppid
    echo "${d#/proc/} ${2:-0}"
  done
}

# kill_tree PID — TERM the process and every descendant, then KILL leftovers.
kill_tree() {
  local tree
  tree=$(proc_tree "$1")
  [ -n "$tree" ] || tree=$1
  # shellcheck disable=SC2086  # intentional word splitting over PIDs
  kill $tree 2>/dev/null || true
  sleep 1
  # shellcheck disable=SC2086
  kill -9 $tree 2>/dev/null || true
}

# lock_break DIR — kill the holder and its children (kick uses this) and take
# the lock over in place: DIR/pid becomes $$ and DIR/token a fresh token.
# Returns 0 when this process now owns the lock. Returns 1 without touching
# the lock when there is none, or when the token changed while the holder was
# being killed (a replacement owner acquired it in between): the caller
# retries, never deleting a lock it did not break.
lock_break() {
  local ldir=$1 holder tok
  [ -d "$ldir" ] || return 1
  holder=$(lock_pid "$ldir"); tok=$(lock_token "$ldir")
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then kill_tree "$holder"; fi
  [ -d "$ldir" ] && [ "$(lock_token "$ldir")" = "$tok" ] || return 1
  lock_token_new >"$ldir/token"
  echo $$ >"$ldir/pid"
}

# with_timeout SECONDS CMD... — run CMD, kill it after SECONDS. No GNU timeout.
with_timeout() {
  local secs=$1 pid wpid rc=0 sp; shift
  "$@" </dev/null &
  pid=$!
  # kill_tree, not kill: grandchildren holding stdout would keep a $(...) open
  ( sleep "$secs" & sp=$!; trap 'kill $sp 2>/dev/null; exit 0' TERM; wait $sp; kill_tree "$pid" >/dev/null 2>&1 ) &
  wpid=$!
  wait "$pid" || rc=$?
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  return "$rc"
}

# ---------- json (python3 stdlib, so no jq dependency) ----------

# json_get FILE KEY[.KEY...] — print a scalar, empty if missing.
json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k in sys.argv[2].split("."):
    if isinstance(v, dict) and k in v:
        v = v[k]
    else:
        sys.exit(0)
if isinstance(v, bool):
    print("true" if v else "false")
elif v is not None and not isinstance(v, (dict, list)):
    print(v)
PY
}

# ---------- secrets hygiene ----------

# read_secret VAR PROMPT — hidden prompt, or stdin when not a tty. Never argv.
read_secret() {
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
  [ -n "$_val" ] || die "empty value for $_prompt"
  eval "$_var=\$_val"
}

# ---------- T3 Code client key (shared by master and node side) ----------
#
# T3 Code's SSH environment type (pingdotgg/t3code packages/ssh/src/tunnel.ts)
# needs exactly three things from the node's sshd: non-pty remote commands
# (`sh -l -s` / `sh -s` with a script on stdin), a local forward to the T3
# server on 127.0.0.1 (`ssh -N -L <local>:127.0.0.1:<port>`), and nothing
# else. The key the master's desktop app uses is therefore authorised with
# `restrict` (no pty, no agent/X11 forwarding, no user rc) plus only what the
# flow needs back: port forwarding, limited to loopback destinations, and only
# from the tailnet. The comment is the handle every add/remove matches on.
T3_CLIENT_KEY_COMMENT="fleet-t3-client"
T3_CLIENT_KEY_OPTIONS='restrict,port-forwarding,permitopen="127.0.0.1:*",from="100.64.0.0/10,fd7a:115c:a1e0::/48"'

# t3_authorized_line PUBKEY_FILE — the authorized_keys line for the T3 client
# key: options, key type, key, fixed comment.
t3_authorized_line() {
  local type key
  read -r type key _ <"$1" || return 1
  [ -n "$type" ] && [ -n "$key" ] || return 1
  printf '%s %s %s %s\n' "$T3_CLIENT_KEY_OPTIONS" "$type" "$key" "$T3_CLIENT_KEY_COMMENT"
}

# T3_AUTHKEY_SCRIPT — POSIX sh, run on the node as `sh -c '<script>'` with the
# desired line on stdin (an empty line removes the key). Every line whose
# comment is fleet-t3-client is dropped, the new line appended once, the file
# rewritten (0600, tmp + mv) only when it changes. No single quotes inside: the
# master passes it through the node's login shell in single quotes.
# shellcheck disable=SC2016,SC2034  # expanded by the node's shell; used by lib/t3.sh and the tests
T3_AUTHKEY_SCRIPT='umask 077; mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" || exit 1
ak="$HOME/.ssh/authorized_keys"; IFS= read -r line || line=""
[ -f "$ak" ] || [ -n "$line" ] || exit 0
tmp=$(mktemp "$HOME/.ssh/.fleet.XXXXXX") || exit 1
{ [ -f "$ak" ] && grep -v " fleet-t3-client\$" "$ak"; [ -n "$line" ] && printf "%s\n" "$line"; } >"$tmp"
if [ -f "$ak" ] && cmp -s "$tmp" "$ak"; then rm -f "$tmp"; exit 0; fi
chmod 600 "$tmp" && mv -f "$tmp" "$ak"'

# ---------- tool plug-ins ----------

# Every lib/tools/<name>.sh defines tool_<name>_{install,update,status}.
# status prints one line: "<state> <detail>" where state is ok|missing|login|error.
fleet_tools_dir() { echo "${FLEET_ROOT}/lib/tools"; }

tool_call() {
  local name=$1 fn=$2 f
  shift 2
  f="$(fleet_tools_dir)/$name.sh"
  [ -f "$f" ] || die "unknown tool: $name" "see lib/tools/"
  # shellcheck source=/dev/null
  . "$f"
  "tool_${name//-/_}_$fn" "$@"
}
