#!/usr/bin/env bash
# fleet node container entrypoint (PID 1). docs/ARCHITECTURE.md "Docker nodes".
#
#   no args      node flow: tailscaled -> sshd -> `fleet join` (as FLEET_USER)
#                -> supervisor running `fleet daemon` (as FLEET_USER)
#   supervise    internal: the supervisor stage (exec'd by the node flow)
#   CMD...       run CMD instead (e.g. `sleep infinity` for the e2e master)
#
# Environment:
#   FLEET_USER            node user (baked by the image, default fleet)
#   FLEET_INVITE_FILE     path of a file holding the invite code (bind mount or
#                         compose secret; docker/spawn.sh uses /run/fleet-invite).
#                         Preferred: the code never appears in `docker inspect`.
#   FLEET_INVITE_CODE     the code itself (compose/.env convenience; visible in
#                         `docker inspect` of this container — single use, 1h key)
#   TS_STATE_DIR          tailscaled state dir (default /var/lib/tailscale)
#   TS_SOCKET             tailscaled socket (default /var/run/tailscale/tailscaled.sock;
#                         keep the default so the user's `tailscale` CLI finds it)
#   FLEET_LOCAL_CONF      optional content for ~/.config/fleet/fleet.conf (local
#                         overrides, e.g. FLEET_TOOLS or FLEET_MEMORY_REMOTE)
#   FLEET_TOOLS           optional shortcut: appended to that file as FLEET_TOOLS="..."
#   FLEET_FAKE_TAILSCALE  1 = do not start tailscaled; a fake `tailscale` on PATH
#                         (tests/e2e) answers instead
#
# The invite code is consumed by `fleet join` and removed from the environment
# before the supervisor starts, so neither the daemon nor its children see it.
# A FLEET_INVITE_FILE (root-owned 0600 mount) is copied to a user-readable
# 0600 tmpfs file for the duration of `fleet join` only, and the mounted file
# itself is truncated when it is writable: a bind-mounted inode stays readable
# in the container even after the host unlinks its name (spawn.sh truncates on
# the host side for read-only mounts).
set -eu

FLEET_USER=${FLEET_USER:-fleet}
TS_STATE_DIR=${TS_STATE_DIR:-/var/lib/tailscale}
TS_SOCKET=${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}
FLEET_ROOT=${FLEET_ROOT:-/opt/fleet}

log()  { printf '==> entrypoint: %s\n' "$*" >&2; }
die()  { printf 'error entrypoint: %s\n' "$*" >&2; exit 1; }
fake() { [ "${FLEET_FAKE_TAILSCALE:-0}" = 1 ]; }

user_home() { getent passwd "$FLEET_USER" | cut -d: -f6; }
user_uid()  { id -u "$FLEET_USER"; }
user_gid()  { id -g "$FLEET_USER"; }

# as_user CMD... — drop privileges (no sudo in the image; setpriv is util-linux).
# as_user_exec: same, replacing the current process (for `cmd &`, so the PID
# bash reports is the daemon itself, not a wrapper subshell).
as_user() {
  local h; h=$(user_home)
  setpriv --reuid="$(user_uid)" --regid="$(user_gid)" --init-groups \
    env HOME="$h" USER="$FLEET_USER" LOGNAME="$FLEET_USER" SHELL=/bin/bash \
        PATH="$h/.local/bin:/usr/local/bin:/usr/bin:/bin" FLEET_CONTAINER=1 "$@"
}
as_user_exec() {
  local h; h=$(user_home)
  exec setpriv --reuid="$(user_uid)" --regid="$(user_gid)" --init-groups \
    env HOME="$h" USER="$FLEET_USER" LOGNAME="$FLEET_USER" SHELL=/bin/bash \
        PATH="$h/.local/bin:/usr/local/bin:/usr/bin:/bin" FLEET_CONTAINER=1 "$@"
}

# ---------- node flow (root) ----------

write_local_conf() {
  local h f tmp
  h=$(user_home); f="$h/.config/fleet/fleet.conf"
  [ -n "${FLEET_LOCAL_CONF:-}" ] || [ -n "${FLEET_TOOLS+x}" ] || return 0
  install -d -m 0700 -o "$FLEET_USER" -g "$FLEET_USER" "$h/.config" "$h/.config/fleet"
  tmp=$(mktemp "$h/.config/fleet/.conf.XXXXXX")
  {
    echo '# written by the container entrypoint from FLEET_LOCAL_CONF / FLEET_TOOLS'
    [ -n "${FLEET_LOCAL_CONF:-}" ] && printf '%s\n' "$FLEET_LOCAL_CONF"
    [ -n "${FLEET_TOOLS+x}" ] && printf 'FLEET_TOOLS="%s"\n' "$FLEET_TOOLS"
  } >"$tmp"
  chown "$FLEET_USER:$FLEET_USER" "$tmp"; chmod 0600 "$tmp"; mv -f "$tmp" "$f"
  log "wrote $f"
}

start_tailscaled() {
  if fake; then log "FLEET_FAKE_TAILSCALE=1: not starting tailscaled ($(command -v tailscale) answers)"; return 0; fi
  command -v tailscaled >/dev/null || die "tailscaled missing in the image"
  mkdir -p "$TS_STATE_DIR" "$(dirname "$TS_SOCKET")"; chmod 0700 "$TS_STATE_DIR"
  tailscaled --tun=userspace-networking --state="$TS_STATE_DIR/tailscaled.state" \
             --statedir="$TS_STATE_DIR" --socket="$TS_SOCKET" >/var/log/tailscaled.log 2>&1 &
  echo $! >/run/tailscaled.pid
  local i=0
  while [ ! -S "$TS_SOCKET" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -S "$TS_SOCKET" ] || { cat /var/log/tailscaled.log >&2; die "tailscaled did not create $TS_SOCKET"; }
  # Let FLEET_USER drive tailscaled without sudo (`tailscale up/status/logout`).
  tailscale --socket="$TS_SOCKET" set --operator="$FLEET_USER" \
    || die "tailscale set --operator=$FLEET_USER failed"
  log "tailscaled up (userspace networking, state $TS_STATE_DIR, operator $FLEET_USER)"
}

start_sshd() {
  command -v sshd >/dev/null || die "sshd missing in the image"
  ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || { ssh-keygen -A >/dev/null; log "generated sshd host keys"; }
  mkdir -p /run/sshd
  /usr/sbin/sshd -t || die "sshd config test failed"
  /usr/sbin/sshd -D -e &
  echo $! >/run/sshd.pid
  log "sshd listening on 22 (key auth only, user $FLEET_USER)"
}

# invite_scrub FILE — empty the mounted invite once it has been copied. Only
# possible when the mount is writable (`-w` is false on a :ro bind mount even
# for root); a failure is not fatal, the host side truncates too.
invite_scrub() {
  if [ -w "$1" ] && : >"$1" 2>/dev/null; then
    log "invite file $1 truncated"
  else
    log "invite file $1 not writable (read-only mount); the host truncates it"
  fi
}

run_join() {
  [ -n "${FLEET_INVITE_CODE:-}" ] || [ -n "${FLEET_INVITE_FILE:-}" ] \
    || die "set FLEET_INVITE_FILE (bind-mounted 0600 file) or FLEET_INVITE_CODE (from 'fleet invite' on the master)"
  log "fleet join as $FLEET_USER"
  local -a inv=()
  local tmpf="" rc=0
  if [ -n "${FLEET_INVITE_FILE:-}" ]; then
    [ -r "$FLEET_INVITE_FILE" ] || die "cannot read FLEET_INVITE_FILE=$FLEET_INVITE_FILE"
    [ -s "$FLEET_INVITE_FILE" ] || die "FLEET_INVITE_FILE=$FLEET_INVITE_FILE is empty (host file removed before join?)"
    # the mount is root:root 0600; hand the user a private copy on tmpfs, gone after join
    mkdir -p /run/fleet; chmod 0700 /run/fleet
    tmpf=$(mktemp /run/fleet/invite.XXXXXX)
    cat "$FLEET_INVITE_FILE" >"$tmpf"
    chown "$FLEET_USER:$FLEET_USER" "$tmpf"; chmod 0600 "$tmpf"; chmod 0711 /run/fleet
    invite_scrub "$FLEET_INVITE_FILE"
    inv+=(FLEET_INVITE_FILE="$tmpf")
  else
    inv+=(FLEET_INVITE_CODE="$FLEET_INVITE_CODE")
  fi
  as_user env "${inv[@]}" "$FLEET_ROOT/fleet" join </dev/null || rc=$?
  [ -n "$tmpf" ] && rm -f "$tmpf"
  [ "$rc" -eq 0 ] || die "fleet join failed"
}

node_flow() {
  getent passwd "$FLEET_USER" >/dev/null || die "user $FLEET_USER does not exist in the image"
  write_local_conf
  start_tailscaled
  start_sshd
  run_join
  unset FLEET_INVITE_CODE FLEET_INVITE_FILE
  exec "$0" supervise
}

# ---------- supervisor (PID 1) ----------
# Runs `fleet daemon` as FLEET_USER, forwards TERM/INT, reaps children, and on
# exit logs the device out of the tailnet (ephemeral nodes vanish) and stops
# sshd/tailscaled. `fleet leave` (run remotely by `fleet kick`) stops the daemon
# itself (TERM via daemon.pid); as belt and braces the supervisor also treats a
# vanished ~/.config/fleet/daemon.pid while the daemon still runs as "stop".
# Before sshd goes down it waits for a still-running `fleet leave` session, so
# the master sees that command finish with exit 0.

DAEMON_PID=""
SUPERVISE_STOP=0

on_signal() {
  SUPERVISE_STOP=1
  [ -n "$DAEMON_PID" ] && kill -TERM "$DAEMON_PID" 2>/dev/null
  return 0
}

supervise() {
  set +e
  local h pidfile rc=0 seen=0 waited=0
  h=$(user_home); pidfile="$h/.config/fleet/daemon.pid"
  trap on_signal TERM INT
  trap '' HUP
  as_user_exec "$FLEET_ROOT/fleet" daemon </dev/null &
  DAEMON_PID=$!
  log "supervising fleet daemon (pid $DAEMON_PID) as $FLEET_USER"

  while kill -0 "$DAEMON_PID" 2>/dev/null; do
    # `wait` returns on SIGCHLD (reaps any child, PID 1 duty) or on a trapped signal.
    sleep 1 &
    wait $! 2>/dev/null
    if [ "$SUPERVISE_STOP" -eq 0 ]; then
      if [ -f "$pidfile" ]; then seen=1; waited=0
      elif [ "$seen" -eq 1 ]; then
        waited=$((waited + 1))
        if [ "$waited" -ge 3 ]; then
          log "daemon.pid removed (fleet leave): stopping the daemon"
          SUPERVISE_STOP=1; kill -TERM "$DAEMON_PID" 2>/dev/null
        fi
      fi
    fi
  done
  wait "$DAEMON_PID" 2>/dev/null; rc=$?
  trap - TERM INT
  log "fleet daemon exited ($rc); logging out of the tailnet"
  # let a remote `fleet leave` (ssh session) finish cleanly before sshd goes
  local i=0
  while [ "$i" -lt 15 ] && pgrep -f 'fleet leave' >/dev/null 2>&1; do sleep 1; i=$((i + 1)); done
  sleep 1
  if fake; then tailscale logout >/dev/null 2>&1 || true
  else tailscale --socket="$TS_SOCKET" logout >/dev/null 2>&1 || log "tailscale logout failed (already logged out?)"
  fi
  for p in /run/sshd.pid /run/tailscaled.pid; do
    [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null
  done
  wait 2>/dev/null
  exit "$rc"
}

# Sourced (tests): define the functions only.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

case "${1:-}" in
  "")        node_flow ;;
  supervise) supervise ;;
  *)         exec "$@" ;;
esac
