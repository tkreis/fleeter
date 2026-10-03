#!/usr/bin/env bash
# fleet join — standalone node bootstrap (docs/CONTRACT.md "Enrolment", step 2).
#
# This file is embedded gzip+base64 in every `fleet invite` one-liner and runs
# before any other fleet code exists on the machine, so it sources NOTHING and
# re-implements the few helpers it needs. It is also sourced by the `fleet`
# dispatcher (lib/[a-z]*.sh) — therefore every function is prefixed `join_`/`j_`
# and the main routine only runs when executed standalone (guard at the bottom).
# Every function declares its variables `local`: bash scoping is dynamic, so a
# plain assignment would overwrite a caller's variable of the same name.
#
# What it does, idempotently:
#   preflight → invite code → deps → (macOS: Homebrew) → tailscale up (tagged)
#   → ssh server (key-only, verified with `sshd -T -C …`) → privileged
#   prerequisites (Linux: base packages, browser, docker; macOS: Homebrew;
#   marker ~/.config/fleet/privileged_done) → master key in authorized_keys →
#   three deploy keys (code, config, memory) → ~/.ssh/config aliases →
#   ~/.config/fleet/enrol.json.
#   Then it prints "waiting for master" and exits 0. It exits non-zero (no
#   "joined") when SSH could not be verified usable.
#
# Portability: bash 3.2, no GNU-only flags, no sed -i, no flock, no timeout.
set -eu

# ---------- output ----------

j_tty() { [ -t 2 ]; }
j_log()  { if j_tty; then printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; else printf '==> %s\n' "$*" >&2; fi; }
j_ok()   { if j_tty; then printf '\033[1;32m ok\033[0m %s\n' "$*" >&2; else printf ' ok %s\n' "$*" >&2; fi; }
j_warn() { if j_tty; then printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; else printf 'warn %s\n' "$*" >&2; fi; }
# j_die MESSAGE [HINT]
j_die() {
  if j_tty; then printf '\033[1;31merror\033[0m %s\n' "$1" >&2; else printf 'error %s\n' "$1" >&2; fi
  [ -n "${2:-}" ] && printf '  next: %s\n' "$2" >&2
  exit 1
}
j_have() { command -v "$1" >/dev/null 2>&1; }

# ---------- platform ----------

join_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *)      echo unsupported ;;
  esac
}

join_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo arm64 ;;
    x86_64|amd64)  echo amd64 ;;
    *)             uname -m ;;
  esac
}

join_in_container() {
  [ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ -n "${FLEET_CONTAINER:-}" ]
}

# join_wants TOOL — true when the fleet converges TOOL on its nodes (the
# master's FLEET_TOOLS travels in the invite code, JOIN_TOOLS below); an invite
# from an older master carries no list, and then every privileged step runs.
join_wants() {
  [ -n "$JOIN_TOOLS" ] || return 0
  case " $JOIN_TOOLS " in *" $1 "*) return 0 ;; esac
  return 1
}

# Run as root: directly when root, via sudo otherwise (join is interactive).
j_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else
    j_have sudo || j_die "sudo is required for: $*" "install sudo or run this step as root"
    sudo "$@"
  fi
}

# join_write_atomic DEST MODE < content
join_write_atomic() {
  local _dest=$1 _mode=$2 _tmp
  mkdir -p "$(dirname "$_dest")"
  _tmp=$(mktemp "$(dirname "$_dest")/.fleet.XXXXXX") || j_die "mktemp failed for $_dest"
  if ! cat >"$_tmp"; then rm -f "$_tmp"; j_die "write failed: $_dest"; fi
  chmod "$_mode" "$_tmp"
  mv -f "$_tmp" "$_dest"
}

# ---------- globals set by the steps ----------

JOIN_OS=""; JOIN_ARCH=""; JOIN_CONTAINER=0
JOIN_KEYFILE=""                     # tmp file holding the tailscale auth key (0600)
JOIN_NONCE=""; JOIN_NAME=""; JOIN_MASTER_PUBKEY=""; JOIN_MASTER_USER=""; JOIN_TAG=""
JOIN_PREFIX="fleet-"                # tailscale hostname = prefix + name (FLEET_HOSTNAME_PREFIX on the master)
JOIN_TOOLS=""                       # the master's FLEET_TOOLS (optional in the code; empty = install everything)
JOIN_TS=""; JOIN_TS_SUDO=0          # tailscale CLI path and whether it needs root

join_cleanup() {
  if [ -n "$JOIN_KEYFILE" ] && [ -f "$JOIN_KEYFILE" ]; then
    rm -f "$JOIN_KEYFILE"
  fi
}

# ---------- 1. preflight ----------

join_preflight() {
  local _free_kb=""
  JOIN_OS=$(join_os); JOIN_ARCH=$(join_arch)
  [ "$JOIN_OS" != unsupported ] || j_die "unsupported OS: $(uname -s)" "fleet supports macOS and Linux"
  [ "${BASH_VERSINFO[0]:-0}" -ge 3 ] || j_die "bash 3.2 or newer is required"
  if join_in_container; then JOIN_CONTAINER=1; fi
  if [ "$(id -u)" -eq 0 ] && [ "$JOIN_CONTAINER" -eq 0 ]; then
    j_die "do not run fleet join as root" "run it as the user the master will log in as; it asks for sudo where needed"
  fi
  case "$JOIN_ARCH" in arm64|amd64) ;; *) j_warn "untested architecture: $JOIN_ARCH" ;; esac
  _free_kb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -n "$_free_kb" ] && [ "$_free_kb" -lt 5242880 ] 2>/dev/null; then
    j_warn "less than 5 GB free in $HOME ($((_free_kb / 1024)) MB); harness installs may fail"
  fi
  j_ok "preflight: $JOIN_OS/$JOIN_ARCH, user $(id -un), container=$JOIN_CONTAINER"
}

# ---------- 2. invite code ----------

# Reads the invite code into JOIN_CODE. Never from argv. The hidden prompt reads
# /dev/tty so the one-liner works even when the script itself arrives on stdin.
join_get_code() {
  JOIN_CODE=""
  if [ -n "${FLEET_INVITE_CODE:-}" ]; then
    JOIN_CODE=$FLEET_INVITE_CODE
  elif [ -n "${FLEET_INVITE_FILE:-}" ]; then
    [ -r "$FLEET_INVITE_FILE" ] || j_die "cannot read FLEET_INVITE_FILE=$FLEET_INVITE_FILE"
    JOIN_CODE=$(cat "$FLEET_INVITE_FILE")
  elif [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf 'invite code (hidden): ' >/dev/tty
    stty -echo </dev/tty 2>/dev/null || true
    IFS= read -r JOIN_CODE </dev/tty || true
    stty echo </dev/tty 2>/dev/null || true
    printf '\n' >/dev/tty
  else
    IFS= read -r JOIN_CODE || true
  fi
  JOIN_CODE=$(printf '%s' "$JOIN_CODE" | tr -d '[:space:]')
  [ -n "$JOIN_CODE" ] || j_die "no invite code given" "set FLEET_INVITE_CODE, FLEET_INVITE_FILE, or paste it at the prompt"
}

# ---------- 3. dependencies ----------

join_install_deps() {
  local _missing="" _c
  for _c in python3 ssh-keygen git; do j_have "$_c" || _missing="$_missing $_c"; done
  if [ "$JOIN_CONTAINER" -eq 0 ]; then j_have curl || _missing="$_missing curl"; fi
  if [ "$JOIN_OS" = macos ]; then
    if ! xcode-select -p >/dev/null 2>&1; then
      j_die "Xcode Command Line Tools are missing (needed for git and python3)" \
        "run: xcode-select --install   — accept the dialog, wait for it to finish, then rerun this command"
    fi
    if ! python3 -c 'import json' >/dev/null 2>&1; then
      j_die "python3 does not run yet" "finish the Command Line Tools install (xcode-select --install), then rerun"
    fi
    [ -z "$_missing" ] || j_die "missing commands:$_missing" "install them (brew install ...) and rerun"
    return 0
  fi
  [ -n "$_missing" ] || return 0
  j_log "installing missing packages:$_missing"
  if j_have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    j_root apt-get update -qq
    j_root apt-get install -y -qq --no-install-recommends python3 curl openssh-client git ca-certificates >/dev/null
  elif j_have dnf; then
    j_root dnf install -y -q python3 curl openssh-clients git ca-certificates
  elif j_have apk; then
    j_root apk add --no-cache -q python3 curl openssh-client git ca-certificates bash
  elif j_have pacman; then
    j_root pacman -Sy --noconfirm --needed python curl openssh git ca-certificates
  else
    j_die "no supported package manager found; install:$_missing" "then rerun"
  fi
  for _c in python3 ssh-keygen git; do j_have "$_c" || j_die "still missing after install: $_c"; done
}

# ---------- 3b. Homebrew (macOS) ----------

# Puts an existing brew on PATH for the rest of join, or installs Homebrew with
# the official installer: as this (non-root) user, NONINTERACTIVE unset so it
# asks for the password itself, terminal on /dev/tty. Returns 1 when it fails.
join_brew_ensure() {
  local _b
  for _b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$_b" ]; then PATH="$(dirname "$_b"):$PATH"; export PATH; return 0; fi
  done
  j_have brew && return 0
  [ "$(id -u)" -ne 0 ] || { j_warn "Homebrew must be installed as a normal user, not root"; return 1; }
  [ -r /dev/tty ] || { j_warn "Homebrew install needs a terminal (it asks for your password)"; return 1; }
  j_log "installing Homebrew (official installer; it asks for your password)"
  if ! (unset NONINTERACTIVE; /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)") </dev/tty; then
    j_warn "Homebrew install failed; install it from https://brew.sh and rerun this command"
    return 1
  fi
  for _b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$_b" ]; then PATH="$(dirname "$_b"):$PATH"; export PATH; j_ok "Homebrew installed ($_b)"; return 0; fi
  done
  j_warn "brew not found after the Homebrew install"
  return 1
}

# ---------- 5. tailscale ----------

# Resolves JOIN_TS / JOIN_TS_SUDO; installs Tailscale when missing. On a fresh
# Mac that means Homebrew first (join_brew_ensure), then `brew install tailscale`.
join_tailscale_install() {
  if [ "$JOIN_CONTAINER" -eq 1 ]; then
    j_have tailscale || j_die "tailscale is not in the image" "the Docker image must start tailscaled in its entrypoint"
    JOIN_TS=tailscale; JOIN_TS_SUDO=0
    [ "$(id -u)" -eq 0 ] || JOIN_TS_SUDO=1
    # Sudo-less image (docker/Dockerfile): the entrypoint made this user the
    # tailscaled operator, so the CLI works without root.
    [ "$JOIN_TS_SUDO" -eq 1 ] && ! j_have sudo && JOIN_TS_SUDO=0
    return 0
  fi
  if [ "$JOIN_OS" = macos ]; then
    if [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
      JOIN_TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale; JOIN_TS_SUDO=0
      j_ok "tailscale: using the GUI app CLI"
      if j_have tailscale && [ "$(command -v tailscale)" != "$JOIN_TS" ]; then
        j_warn "a second tailscale ($(command -v tailscale)) is on PATH; GUI app and brew tailscaled must not both run"
      fi
      return 0
    fi
    if j_have tailscale; then
      JOIN_TS=$(command -v tailscale); JOIN_TS_SUDO=1
      return 0
    fi
    join_brew_ensure || j_die "Tailscale is not installed and Homebrew could not be installed" \
      "install Homebrew (https://brew.sh) or the Tailscale app (https://tailscale.com/download/mac), start it once, then rerun"
    j_log "installing tailscale via Homebrew (tailscaled as a system service)"
    brew install tailscale
    j_root brew services start tailscale
    JOIN_TS=$(command -v tailscale) || j_die "tailscale not on PATH after brew install" "open a new shell and rerun"
    JOIN_TS_SUDO=1
    sleep 2
    return 0
  fi
  # linux host
  if ! j_have tailscale; then
    j_log "installing tailscale (tailscale.com/install.sh)"
    curl -fsSL https://tailscale.com/install.sh | sh   # the script escalates with sudo itself
    j_have tailscale || j_die "tailscale install failed" "install it manually, then rerun"
  fi
  if j_have systemctl && ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    j_root systemctl enable --now tailscaled >/dev/null 2>&1 || j_warn "could not start tailscaled via systemctl"
  fi
  JOIN_TS=$(command -v tailscale); JOIN_TS_SUDO=0
  [ "$(id -u)" -eq 0 ] || JOIN_TS_SUDO=1
}

join_ts() {
  if [ "$JOIN_TS_SUDO" -eq 1 ]; then j_root "$JOIN_TS" "$@"; else "$JOIN_TS" "$@"; fi
}

# Prints "<BackendState> <HostName> <tag,tag>" from `tailscale status --json`.
join_ts_state() {
  join_ts status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
s = d.get("Self") or {}
print(d.get("BackendState", ""), s.get("HostName", ""), ",".join(s.get("Tags") or []))
' 2>/dev/null || true
}

join_tailscale_up() {
  local _host _state _backend _out=""
  _host="$JOIN_PREFIX$JOIN_NAME"
  _state=$(join_ts_state)
  _backend=${_state%% *}
  case "$_state " in
    "Running $_host $JOIN_TAG "*|"Running $_host $JOIN_TAG,"*|"Running $_host "*",$JOIN_TAG "*|"Running $_host "*",$JOIN_TAG,"*)
      j_ok "tailscale already up as $_host with $JOIN_TAG"
      return 0 ;;
  esac
  j_log "tailscale up --advertise-tags=$JOIN_TAG --hostname=$_host (state: ${_backend:-unknown})"
  if ! _out=$(join_ts up --auth-key="file:$JOIN_KEYFILE" --advertise-tags="$JOIN_TAG" --hostname="$_host" 2>&1); then
    case "$_out" in
      *--reset*|*"non-default flags"*)
        j_warn "existing tailscale prefs differ; retrying with --reset"
        _out=$(join_ts up --reset --auth-key="file:$JOIN_KEYFILE" --advertise-tags="$JOIN_TAG" --hostname="$_host" 2>&1) \
          || j_die "tailscale up failed: $_out" "fix the issue above and rerun"
        ;;
      *) j_die "tailscale up failed: $_out" "fix the issue above and rerun (an expired invite needs a new 'fleet invite')" ;;
    esac
  fi
  rm -f "$JOIN_KEYFILE"
  # Let the user's own tailscale calls (status, logout) work without sudo later.
  if [ "$JOIN_TS_SUDO" -eq 1 ] && [ "$JOIN_OS" = linux ]; then
    j_root "$JOIN_TS" set --operator="$(id -un)" >/dev/null 2>&1 || true
  fi
  j_ok "tailscale up as $_host"
}

# ---------- 4. decode + validate the invite ----------

# Decodes the base64 JSON. The auth key is written straight from python into
# JOIN_KEYFILE (0600) and never passes through a shell variable or argv.
join_decode() {
  local _fields
  JOIN_KEYFILE=$(mktemp "${TMPDIR:-/tmp}/fleet-join.XXXXXX") || j_die "mktemp failed"
  chmod 600 "$JOIN_KEYFILE"
  _fields=$(FLEET_JOIN_CODE_RAW="$JOIN_CODE" python3 - "$JOIN_KEYFILE" <<'PY'
import base64, json, os, re, sys

code = os.environ.get("FLEET_JOIN_CODE_RAW", "")
try:
    pad = "=" * (-len(code) % 4)
    raw = base64.b64decode(code + pad)
    d = json.loads(raw.decode("utf-8"))
except Exception as e:  # noqa: BLE001
    sys.stderr.write("invalid invite code (%s)\n" % e.__class__.__name__)
    sys.exit(2)
if not isinstance(d, dict) or d.get("v") != 1:
    sys.stderr.write("invite code version mismatch (expected v=1)\n")
    sys.exit(2)
for k in ("ts_auth_key", "nonce", "name", "master_pubkey", "master_user", "tag"):
    v = d.get(k)
    if not isinstance(v, str) or not v.strip() or "\n" in v:
        sys.stderr.write("invite code: missing or invalid field %r\n" % k)
        sys.exit(2)
if not re.match(r"^[a-z0-9][a-z0-9-]{0,40}$", d["name"]):
    sys.stderr.write("invite code: name must match [a-z0-9-]\n")
    sys.exit(2)
if not d["tag"].startswith("tag:"):
    sys.stderr.write("invite code: tag must start with 'tag:'\n")
    sys.exit(2)
# optional (older masters omit it): the hostname prefix, FLEET_HOSTNAME_PREFIX on the master
prefix = d.get("hostname_prefix", "fleet-")
if not isinstance(prefix, str) or not re.match(r"^[a-z0-9-]{0,24}$", prefix):
    sys.stderr.write("invite code: invalid hostname_prefix\n")
    sys.exit(2)
# optional (older masters omit it): the master's FLEET_TOOLS, so join can skip
# privileged installs the fleet does not use; anything odd is ignored, not fatal
tools = d.get("tools", "")
if not isinstance(tools, str) or not re.match(r"^[a-z0-9 _-]{0,200}$", tools):
    tools = ""
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_TRUNC | os.O_CREAT, 0o600)
os.write(fd, d["ts_auth_key"].strip().encode("utf-8"))
os.close(fd)
for k in ("nonce", "name", "master_pubkey", "master_user", "tag"):
    print(d[k].strip())
print(prefix)
print(" ".join(tools.split()))
PY
  ) || j_die "could not decode the invite code" "ask the master for a fresh 'fleet invite'"
  {
    IFS= read -r JOIN_NONCE
    IFS= read -r JOIN_NAME
    IFS= read -r JOIN_MASTER_PUBKEY
    IFS= read -r JOIN_MASTER_USER
    IFS= read -r JOIN_TAG
    IFS= read -r JOIN_PREFIX || JOIN_PREFIX=""     # the heredoc strips trailing empty lines:
    IFS= read -r JOIN_TOOLS || JOIN_TOOLS=""       # an empty prefix or tool list reads as end of input
  } <<EOF
$_fields
EOF
  unset JOIN_CODE
  [ -n "$JOIN_NAME" ] && [ -n "$JOIN_TAG" ] || j_die "invite code is incomplete"
  j_ok "invite for node '$JOIN_NAME' ($JOIN_TAG, hostname $JOIN_PREFIX$JOIN_NAME${JOIN_TOOLS:+, tools: $JOIN_TOOLS})"
}

# ---------- 6. ssh server (key-only, verified) ----------

# The master only ever logs in with its key, so password and keyboard-interactive
# auth are switched off through a drop-in that sorts FIRST in sshd_config.d:
# sshd keeps the first value it sees for an option, so 00-/000- beats e.g.
# Ubuntu's 50-cloud-init.conf (PasswordAuthentication yes) and macOS's
# 100-macos.conf. The effective config is then read back with `sshd -T -C
# user=<me>,host=localhost,addr=127.0.0.1`, which applies the Match blocks that
# would hit the master's login (a `Match User` can re-enable passwords after
# the drop-in); join fails (no "joined") when SSH is not verified usable.
JOIN_SSHD_DIR=${FLEET_SSHD_CONFIG_DIR:-/etc/ssh/sshd_config.d}
JOIN_SSHD_CONFIG=${FLEET_SSHD_CONFIG:-/etc/ssh/sshd_config}
JOIN_SSHD_DROPIN='# managed by fleet join: key-only SSH for the fleet master.
# Sorted first on purpose: sshd keeps the first value it sees for an option.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes'

join_sshd_bin() {
  if j_have sshd; then command -v sshd; return 0; fi
  [ -x /usr/sbin/sshd ] && { echo /usr/sbin/sshd; return 0; }
  return 1
}

# True when sshd_config includes the drop-in directory (Debian/Ubuntu/Fedora/Arch, macOS 13+).
join_sshd_has_include() {
  grep -qs "^[[:space:]]*Include[[:space:]]\{1,\}$JOIN_SSHD_DIR" "$JOIN_SSHD_CONFIG"
}

# join_sshd_dropin NAME — write $JOIN_SSHD_DIR/NAME (idempotent), drop the old fleet.conf.
join_sshd_dropin() {
  local _dest="$JOIN_SSHD_DIR/$1"
  j_root mkdir -p "$JOIN_SSHD_DIR"
  if [ -f "$_dest" ] && [ "$(cat "$_dest" 2>/dev/null)" = "$JOIN_SSHD_DROPIN" ]; then
    j_ok "sshd drop-in $_dest present"
  else
    printf '%s\n' "$JOIN_SSHD_DROPIN" | j_root tee "$_dest" >/dev/null || j_die "could not write $_dest"
    j_root chmod 0644 "$_dest"
    j_ok "sshd drop-in $_dest written"
  fi
  # earlier fleet versions wrote fleet.conf (no ordering prefix); one file is enough
  if [ -f "$JOIN_SSHD_DIR/fleet.conf" ] && head -n 1 "$JOIN_SSHD_DIR/fleet.conf" 2>/dev/null | grep -q '^# managed by fleet join'; then
    j_root rm -f "$JOIN_SSHD_DIR/fleet.conf"
  fi
}

# Effective sshd config for the master's login via `sshd -T -C …` (root: it
# reads the host keys). Prints the offending options and returns 1 when
# passwords/root login are still allowed.
join_sshd_verify() {
  local _sshd _spec _eff _bad=""
  _sshd=$(join_sshd_bin) || { j_warn "sshd binary not found"; return 1; }
  _spec="user=$(id -un),host=localhost,addr=127.0.0.1"
  _eff=$(j_root "$_sshd" -T -C "$_spec" 2>/dev/null) || { j_warn "'sshd -T -C $_spec' failed (config error? run: sudo $_sshd -t)"; return 1; }
  printf '%s\n' "$_eff" | grep -qi '^passwordauthentication no'       || _bad="$_bad PasswordAuthentication"
  printf '%s\n' "$_eff" | grep -qi '^kbdinteractiveauthentication no' || _bad="$_bad KbdInteractiveAuthentication"
  printf '%s\n' "$_eff" | grep -qi '^permitrootlogin no'              || _bad="$_bad PermitRootLogin"
  printf '%s\n' "$_eff" | grep -qi '^pubkeyauthentication yes'        || _bad="$_bad PubkeyAuthentication"
  if [ -n "$_bad" ]; then j_warn "sshd effective config for $(id -un) is not key-only:$_bad (check Match blocks too)"; return 1; fi
  j_ok "sshd verified: key-only, no root login (for $(id -un))"
}

join_sshd_manual_hint() {
  printf '%s\n' "add these lines at the TOP of $JOIN_SSHD_CONFIG (before any Match) and remove Match blocks that re-enable them, restart sshd, rerun:" \
    "    PasswordAuthentication no" "    KbdInteractiveAuthentication no" "    PermitRootLogin no" | tr '\n' ' '
}

join_ssh_enable_macos() {
  local _on=0
  if j_root systemsetup -setremotelogin on >/dev/null 2>&1 \
     && j_root systemsetup -getremotelogin 2>/dev/null | grep -qi 'on'; then
    j_ok "Remote Login enabled"; _on=1
  elif j_root launchctl load -w /System/Library/LaunchDaemons/ssh.plist >/dev/null 2>&1; then
    j_ok "sshd loaded via launchctl"; _on=1
  fi
  [ "$_on" -eq 1 ] || j_die "could not enable Remote Login automatically (newer macOS needs Full Disk Access for the terminal app)" \
    "System Settings -> General -> Sharing -> Remote Login: on, allow user '$(id -un)', then rerun this command"
  # macOS 13+ ships `Include /etc/ssh/sshd_config.d/*`; sshd is launched on demand, so new connections see the drop-in.
  if join_sshd_has_include; then
    join_sshd_dropin 000-fleet.conf
  else
    j_die "$JOIN_SSHD_CONFIG has no 'Include $JOIN_SSHD_DIR' (macOS 12 or older?)" "$(join_sshd_manual_hint)"
  fi
  join_sshd_verify || j_die "SSH is not verified key-only; the master will not use this node" "$(join_sshd_manual_hint)"
}

# join_sshd_reload SVC — the drop-in only counts once sshd re-read its config:
# reload (restart as fallback) must succeed, a failure fails the join.
join_sshd_reload() {
  if j_have systemctl; then
    j_root systemctl reload "$1" >/dev/null 2>&1 || j_root systemctl restart "$1" >/dev/null 2>&1 \
      || j_die "sshd ($1) did not reload the new config" "run: sudo $(join_sshd_bin) -t   — fix the config error, then rerun this command"
  else
    j_root service "$1" reload >/dev/null 2>&1 || j_root service "$1" restart >/dev/null 2>&1 \
      || j_die "sshd ($1) did not reload the new config" "run: sudo $(join_sshd_bin) -t   — fix the config error, then rerun this command"
  fi
  j_ok "sshd reloaded ($1)"
}

join_ssh_enable_linux() {
  local _svc="" _s
  if ! join_sshd_bin >/dev/null; then
    j_log "installing openssh-server"
    if j_have apt-get; then
      export DEBIAN_FRONTEND=noninteractive
      j_root apt-get install -y -qq --no-install-recommends openssh-server >/dev/null
    elif j_have dnf; then j_root dnf install -y -q openssh-server
    elif j_have apk; then j_root apk add --no-cache -q openssh-server
    elif j_have pacman; then j_root pacman -S --noconfirm --needed openssh
    else j_die "cannot install openssh-server" "install it, then rerun"
    fi
    join_sshd_bin >/dev/null || j_die "sshd still missing after install"
  fi
  if join_sshd_has_include; then
    join_sshd_dropin 00-fleet.conf
  else
    j_die "$JOIN_SSHD_CONFIG has no 'Include $JOIN_SSHD_DIR' (OpenSSH older than 8.2?)" "$(join_sshd_manual_hint)"
  fi
  if j_have systemctl; then
    for _s in ssh sshd; do
      if j_root systemctl enable --now "$_s" >/dev/null 2>&1; then _svc=$_s; break; fi
    done
  elif j_have service; then
    for _s in ssh sshd; do
      if j_root service "$_s" start >/dev/null 2>&1; then _svc=$_s; break; fi
    done
  fi
  if [ -n "$_svc" ]; then
    join_sshd_reload "$_svc"
    j_ok "sshd running ($_svc)"
  elif pgrep -x sshd >/dev/null 2>&1; then
    # not managed by systemd/service: HUP the listener so it re-reads the drop-in
    j_root kill -HUP "$(pgrep -o -x sshd)" >/dev/null 2>&1 \
      || j_die "sshd runs unmanaged and did not accept HUP; the drop-in is not active" "restart sshd, then rerun this command"
    j_ok "sshd running (unmanaged; sent HUP to re-read the config)"
  else
    j_die "sshd is not running" "start it (systemctl enable --now ssh) and rerun this command"
  fi
  join_sshd_verify || j_die "SSH is not verified key-only; the master will not use this node" "$(join_sshd_manual_hint)"
}

join_ssh_enable() {
  if [ "$JOIN_CONTAINER" -eq 1 ]; then j_ok "container: sshd is the entrypoint's job (key-only in the image)"; return 0; fi
  if [ "$JOIN_OS" = macos ]; then join_ssh_enable_macos; else join_ssh_enable_linux; fi
}

# ---------- 6b. privileged prerequisites ----------

# Base packages lib/tools/base.sh expects, as "<command> <package>" pairs for
# the given package manager (kept in sync with _base_items there). nc is what
# `fleet doctor` probes isolation with.
join_base_items() {
  case "$1" in
    pacman) printf '%s\n' "git git" "git-lfs git-lfs" "curl curl" "jq jq" "rg ripgrep" "tmux tmux" "python3 python" "unzip unzip" "nc openbsd-netcat" ;;
    dnf)    printf '%s\n' "git git" "git-lfs git-lfs" "curl curl" "jq jq" "rg ripgrep" "tmux tmux" "python3 python3" "unzip unzip" "nc nmap-ncat" ;;
    *)      printf '%s\n' "git git" "git-lfs git-lfs" "curl curl" "jq jq" "rg ripgrep" "tmux tmux" "python3 python3" "unzip unzip" "nc netcat-openbsd" ;;
  esac
}

# Linux: the apt/dnf/apk/pacman packages the base plug-in needs. Root only
# happens here (join), so an unattended `fleet apply` later finds them present
# instead of "succeeding" without them. Returns 1 on failure.
join_linux_base_packages() {
  local _mgr="" _m _missing="" _cmd _pkg
  for _m in apt-get dnf apk pacman; do j_have "$_m" && { _mgr=$_m; break; }; done
  [ -n "$_mgr" ] || { j_warn "no supported package manager; install git git-lfs curl jq ripgrep tmux python3 unzip yourself"; return 1; }
  while read -r _cmd _pkg; do j_have "$_cmd" || _missing="$_missing $_pkg"; done <<EOF
$(join_base_items "$_mgr")
EOF
  [ -f /etc/ssl/certs/ca-certificates.crt ] || _missing="$_missing ca-certificates"
  [ -n "$_missing" ] || { j_ok "base packages present"; return 0; }
  j_log "installing base packages:$_missing ($_mgr)"
  # shellcheck disable=SC2086  # intentional word split over package names
  case "$_mgr" in
    apt-get) export DEBIAN_FRONTEND=noninteractive
             j_root apt-get update -qq && j_root apt-get install -y -qq --no-install-recommends $_missing >/dev/null ;;
    dnf)     j_root dnf install -y -q $_missing ;;
    apk)     j_root apk add --no-cache -q $_missing ;;
    pacman)  j_root pacman -Sy --noconfirm --needed $_missing ;;
  esac || { j_warn "base package install failed:$_missing"; return 1; }
  j_have git-lfs && git lfs install --skip-repo >/dev/null 2>&1
  j_ok "base packages installed:$_missing"
}

# Linux browser for the agents (lib/tools/chrome.sh needs it, apt needs root):
# Debian/Ubuntu amd64 -> google-chrome-stable from Google's apt repo with a
# signed-by keyring; arm64 (no Linux Chrome build) -> chromium. Other package
# managers: a warning, not a failure. Returns 1 on failure.
join_linux_browser() {
  local _c _tmp _key=/usr/share/keyrings/google-chrome.gpg
  for _c in google-chrome-stable google-chrome chromium chromium-browser; do
    j_have "$_c" && { j_ok "browser present ($_c)"; return 0; }
  done
  if ! j_have apt-get; then j_warn "browser: only apt-based Linux is automated; install google-chrome-stable or chromium yourself"; return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  if [ "$JOIN_ARCH" = amd64 ]; then
    j_log "installing google-chrome-stable from Google's apt repo"
    j_root apt-get update -qq
    j_root apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg >/dev/null || { j_warn "apt-get install gnupg failed"; return 1; }
    _tmp=$(mktemp "${TMPDIR:-/tmp}/fleet-chrome-key.XXXXXX") || j_die "mktemp failed"
    if ! curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor >"$_tmp" 2>/dev/null; then
      rm -f "$_tmp"; j_warn "could not fetch Google's apt signing key (https://www.google.com/linuxrepositories/)"; return 1
    fi
    j_root install -m 0644 "$_tmp" "$_key"; rm -f "$_tmp"
    printf 'deb [arch=amd64 signed-by=%s] https://dl.google.com/linux/chrome/deb/ stable main\n' "$_key" \
      | j_root tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
    j_root apt-get update -qq
    j_root apt-get install -y -qq --no-install-recommends google-chrome-stable >/dev/null || { j_warn "google-chrome-stable install failed"; return 1; }
  else
    j_log "installing chromium (apt, $JOIN_ARCH)"
    j_root apt-get update -qq
    j_root apt-get install -y -qq --no-install-recommends chromium >/dev/null || { j_warn "chromium install failed"; return 1; }
  fi
  for _c in google-chrome-stable google-chrome chromium chromium-browser; do
    j_have "$_c" && { j_ok "browser installed ($_c)"; return 0; }
  done
  j_warn "no chrome/chromium binary after install"
  return 1
}

# join is the only interactive, sudo-capable step (CONTRACT "Tool plug-in
# interface"), but it runs standalone before the plug-ins arrive with the
# provision. So it installs just the OS pieces that need root or a password —
# Linux: base packages, the browser, docker-ce (get.docker.com), docker group,
# systemd linger; macOS: Homebrew (official installer, asks for the password)
# — and records ~/.config/fleet/privileged_done. The plug-ins (base, chrome,
# devtools) skip those steps when that marker exists and the tool is present,
# and point back here when it is missing. Containers: nothing to do (the image
# provides it).
join_privileged() {
  local _marker="$HOME/.config/fleet/privileged_done" _done="" _fail="" _tmp
  if [ "$JOIN_CONTAINER" -eq 1 ]; then j_ok "container: privileged prerequisites come from the image"; return 0; fi
  if [ "$JOIN_OS" = macos ]; then
    if join_brew_ensure; then _done="$_done brew"; else _fail="$_fail brew"; fi
  else
    if join_linux_base_packages; then _done="$_done base"; else _fail="$_fail base"; fi
    if ! join_wants chrome; then
      j_ok "browser: skipped (chrome is not in the fleet's FLEET_TOOLS)"
    elif join_linux_browser; then _done="$_done browser"; else _fail="$_fail browser"; fi
    if ! join_wants devtools && ! join_wants cliproxy; then
      j_ok "docker: skipped (neither devtools nor cliproxy is in the fleet's FLEET_TOOLS)"
    elif j_have docker; then
      _done="$_done docker"
    else
      j_log "installing docker-ce (get.docker.com)"
      _tmp=$(mktemp "${TMPDIR:-/tmp}/fleet-docker.XXXXXX") || j_die "mktemp failed"
      if curl -fsSL https://get.docker.com -o "$_tmp" && j_root sh "$_tmp"; then
        _done="$_done docker"
      else
        _fail="$_fail docker"; j_warn "docker install failed; see https://docs.docker.com/engine/install/ and rerun this command"
      fi
      rm -f "$_tmp"
    fi
    if j_have docker && [ "$(id -u)" -ne 0 ]; then
      if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        _done="$_done docker-group"
      elif j_root usermod -aG docker "$(id -un)" >/dev/null 2>&1; then
        _done="$_done docker-group"; j_warn "added $(id -un) to the docker group; the master's ssh sessions get it, your current shell does not"
      else
        _fail="$_fail docker-group"; j_warn "could not add $(id -un) to the docker group (sudo usermod -aG docker $(id -un))"
      fi
      if j_have systemctl && ! j_root systemctl is-active --quiet docker 2>/dev/null; then
        j_root systemctl enable --now docker >/dev/null 2>&1 || j_warn "could not start the docker service"
      fi
    fi
    # Keep user timers alive without an interactive login (CONTRACT: attempted during join only).
    if j_have loginctl; then
      if j_root loginctl enable-linger "$(id -un)" >/dev/null 2>&1; then _done="$_done linger"; else j_warn "loginctl enable-linger failed; user timers stop at logout"; fi
    fi
  fi
  if [ -z "$_fail" ]; then
    mkdir -p "$HOME/.config/fleet"; chmod 700 "$HOME/.config/fleet"
    printf '%s %s:%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$JOIN_OS" "${_done# }" | join_write_atomic "$_marker" 0600
    j_ok "privileged prerequisites done:${_done}"
  else
    rm -f "$_marker"
    j_warn "privileged prerequisites incomplete:${_fail} (fleet apply will warn until this command is rerun)"
  fi
}

# ---------- 7. keys and ssh config ----------

join_authorized_keys() {
  local _ak="$HOME/.ssh/authorized_keys"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if [ -f "$_ak" ] && grep -qxF "$JOIN_MASTER_PUBKEY" "$_ak"; then
    j_ok "master key already in authorized_keys"
  else
    { [ -f "$_ak" ] && cat "$_ak"; [ -s "$_ak" ] && [ -n "$(tail -c1 "$_ak")" ] && echo; printf '%s\n' "$JOIN_MASTER_PUBKEY"; } \
      | join_write_atomic "$_ak" 0600
    j_ok "master key added to authorized_keys"
  fi
  chmod 600 "$_ak"
  if [ "$(id -un)" != "$JOIN_MASTER_USER" ]; then
    j_warn "the master will log in as '$JOIN_MASTER_USER' but you are '$(id -un)'; the master cannot reach this node unless that user exists with this key"
  fi
}

# One ed25519 key per repo: GitHub deploy keys are unique per repository. The
# master registers fleet_code (read-only; skipped for a public https code repo),
# fleet_config (read-only) and fleet_memory (read-write) during enrolment.
join_deploy_keys() {
  local _k
  for _k in fleet_code fleet_config fleet_memory; do
    if [ -f "$HOME/.ssh/$_k" ] && [ -f "$HOME/.ssh/$_k.pub" ]; then
      j_ok "deploy key $_k exists"
    else
      rm -f "$HOME/.ssh/$_k" "$HOME/.ssh/$_k.pub"
      ssh-keygen -q -t ed25519 -N '' -C "fleet-$JOIN_NAME-${_k#fleet_}" -f "$HOME/.ssh/$_k" </dev/null
      chmod 600 "$HOME/.ssh/$_k"
      j_ok "deploy key $_k generated"
    fi
  done
}

join_ssh_config() {
  local _cfg="$HOME/.ssh/config" _block _current
  _block='# >>> fleet >>>
Host github-fleet-code
  HostName github.com
  User git
  IdentityFile ~/.ssh/fleet_code
  IdentitiesOnly yes
Host github-fleet-config
  HostName github.com
  User git
  IdentityFile ~/.ssh/fleet_config
  IdentitiesOnly yes
Host github-fleet-memory
  HostName github.com
  User git
  IdentityFile ~/.ssh/fleet_memory
  IdentitiesOnly yes
# <<< fleet <<<'
  if [ -f "$_cfg" ] && grep -qF '# >>> fleet >>>' "$_cfg"; then
    _current=$(awk '/^# >>> fleet >>>$/{p=1} p{print} /^# <<< fleet <<<$/{p=0}' "$_cfg")
    if [ "$_current" = "$_block" ]; then j_ok "ssh config aliases present"; return 0; fi
    [ -e "$_cfg.pre-fleet" ] || cp -p "$_cfg" "$_cfg.pre-fleet"
    { awk '/^# >>> fleet >>>$/{skip=1} !skip{print} /^# <<< fleet <<<$/{skip=0}' "$_cfg"; printf '%s\n' "$_block"; } \
      | join_write_atomic "$_cfg" 0600
  else
    if [ -f "$_cfg" ]; then [ -e "$_cfg.pre-fleet" ] || cp -p "$_cfg" "$_cfg.pre-fleet"; fi
    { [ -f "$_cfg" ] && cat "$_cfg"; [ -s "$_cfg" ] && [ -n "$(tail -c1 "$_cfg")" ] && echo; printf '%s\n' "$_block"; } \
      | join_write_atomic "$_cfg" 0600
  fi
  j_ok "ssh config aliases written"
}

# ---------- 8. enrol.json ----------

join_write_enrol() {
  local _dir="$HOME/.config/fleet"
  mkdir -p "$_dir"; chmod 700 "$_dir"
  JOIN_NONCE="$JOIN_NONCE" JOIN_NAME="$JOIN_NAME" JOIN_OS="$JOIN_OS" JOIN_ARCH="$JOIN_ARCH" JOIN_CONTAINER="$JOIN_CONTAINER" \
  python3 - <<'PY' | join_write_atomic "$_dir/enrol.json" 0600
import json, os, time
print(json.dumps({
    "nonce": os.environ["JOIN_NONCE"],
    "name": os.environ["JOIN_NAME"],
    "user": os.popen("id -un").read().strip(),
    "os": os.environ["JOIN_OS"],
    "arch": os.environ["JOIN_ARCH"],
    "container": os.environ["JOIN_CONTAINER"] == "1",
    "joined": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}, indent=2))
PY
  j_ok "wrote $_dir/enrol.json"
}

# ---------- main ----------

join_main() {
  local _dns
  trap join_cleanup EXIT
  export FLEET_INTERACTIVE=1
  j_log "fleet join"
  join_preflight
  join_get_code
  join_install_deps
  join_decode
  join_tailscale_install
  join_tailscale_up
  join_ssh_enable
  join_privileged
  join_authorized_keys
  join_deploy_keys
  join_ssh_config
  join_write_enrol
  _dns=$(join_ts status --json 2>/dev/null | python3 -c '
import json, sys
try:
    print(((json.load(sys.stdin).get("Self") or {}).get("DNSName") or "").rstrip("."))
except Exception:
    print("")
' 2>/dev/null || true)
  [ -n "$_dns" ] || _dns="$JOIN_PREFIX$JOIN_NAME (DNS name appears once tailscale is up)"
  printf '\n' >&2
  j_ok "node '$JOIN_NAME' joined the tailnet as $_dns"
  j_log "waiting for master: it starts setup on its next reconcile (about 2 minutes while it is on)"
  j_log "first setup installs every tool in the fleet's FLEET_TOOLS (runtimes, agents, browser, ...) and can take 10-20 minutes."
  j_log "watch it on the master: fleet nodes (state 'provisioning') and tail -f ~/.config/fleet/reconcile.log"
  j_log "done when this machine has ~/.local/bin/fleet and 'fleet nodes' on the master says 'provisioned'."
  printf '%s\n' "  nothing else to do here; rerunning this command is safe." >&2
}

cmd_join() { join_main "$@"; }

# Run only when executed (file, pipe, or bash -c), not when sourced by `fleet`.
if [ -z "${FLEET_ROOT:-}" ] || [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  join_main "$@"
fi
