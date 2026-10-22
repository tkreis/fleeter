# shellcheck shell=bash
# fleet harden: a node answers only the tailnet, and Tailscale stays current.
# The rules and installers live in lib/join.sh (section 7b) because `fleet
# join` applies them while it has sudo; this file is the command for nodes
# that joined before 0.7.0, the undo, and the status. Sourced by ./fleet.
#
# On a node `fleet harden on` asks for the sudo password at its own prompt.
# From the master `fleet harden on NODE` runs that over an interactive fleet
# session (as `fleet power lid`), with a rollback armed on the node: unless a
# fresh tailnet ssh connection from the master confirms within
# FLEET_HARDEN_CONFIRM_SECS, the node removes the firewall again. The master
# then probes the node's LAN addresses on port 22 to show the result.

FLEET_HARDEN_CONFIRM_SECS=${FLEET_HARDEN_CONFIRM_SECS:-90}

# harden_fw_state — on | off | n/a, without root: the boot-time unit exists.
harden_fw_state() {
  if fleet_in_container; then echo n/a; return 0; fi
  case "$(fleet_os)" in
    macos) if [ -f "$JOIN_FW_PF_PLIST" ]; then echo on; else echo off; fi ;;
    linux) if [ -f "$JOIN_FW_NFT_UNIT" ]; then echo on; else echo off; fi ;;
    *) echo n/a ;;
  esac
}

# harden_ts_info — "<version> <updates>", updates: auto | nightly | off | n/a.
harden_ts_info() {
  local ts ver upd=off
  if fleet_in_container; then echo "- n/a"; return 0; fi
  ts=$(join_ts_bin 2>/dev/null) || { echo "- n/a"; return 0; }
  ver=$("$ts" version 2>/dev/null | head -n 1)
  if join_ts_brew; then
    [ ! -f "$JOIN_TSU_PLIST" ] || upd=nightly
  elif "$ts" debug prefs 2>/dev/null | python3 -c 'import json, sys; sys.exit(0 if (json.load(sys.stdin).get("AutoUpdate") or {}).get("Apply") else 1)' 2>/dev/null; then
    upd=auto
  fi
  echo "${ver:--} $upd"
}

harden_status_here() {
  local ts
  ts=$(harden_ts_info)
  printf 'firewall   %s  (new inbound connections only from the tailnet)\n' "$(harden_fw_state)"
  printf 'tailscale  %s  (updates %s)\n' "${ts%% *}" "${ts#* }"
}

# harden_here on|off YES [CONFIRM_FILE]
harden_here() {
  local mode=$1 yes=$2 confirm=${3:-}
  if fleet_in_container; then log "harden: a container has no firewall of its own (the host decides what reaches it); nothing to change"; return 0; fi
  if [ "$mode" = on ]; then
    log "only the tailnet may open connections to this machine (ssh, Screen Sharing, everything); Tailscale keeps itself current"
    log "this needs sudo: you type your password at sudo's prompt, fleet never sees it. Undo: fleet harden off"
  else
    log "remove the tailnet-only firewall and fleet's Tailscale updater (sudo)"
  fi
  if [ "$yes" != 1 ]; then
    typed_confirm 'Type yes to continue (anything else aborts): ' yes || { warn "aborted; nothing changed"; return 1; }
  fi
  if [ "$mode" = off ]; then
    join_fw_off
    join_ts_autoupdate_off
    return 0
  fi
  join_fw_on || return 1
  if [ -n "$confirm" ]; then
    join_fw_watchdog "$confirm" "$FLEET_HARDEN_CONFIRM_SECS"
    log "rollback armed: without a confirmation over the tailnet within ${FLEET_HARDEN_CONFIRM_SECS}s the firewall is removed again"
  fi
  join_ts_autoupdate_on || warn "Tailscale updates not configured; see above"
  return 0
}

# fleet harden on|off|status [NODE] [--yes] [--confirm FILE]
cmd_harden() {
  local mode="" node="" yes=0 confirm=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) yes=1 ;;
      --confirm) confirm=${2:-}; shift ;;
      -*) die "unknown flag: $1" ;;
      *) if [ -z "$mode" ]; then mode=$1; else node=$1; fi ;;
    esac; shift
  done
  case "$mode" in on|off|status) ;; *) die "usage: fleet harden on|off|status [NODE] [--yes]" ;; esac
  if [ -n "$node" ]; then
    fleet_is_master || die "fleet harden $mode $node: a node name only works on the master" "on this machine: fleet harden $mode"
    harden_remote "$mode" "$node" "$yes"; return
  fi
  if [ "$mode" = status ]; then harden_status_here; return 0; fi
  harden_here "$mode" "$yes" "$confirm"
}

# ---------- master side ----------

# harden_lan_probe ID — try port 22 on each LAN address the node reports. With
# the firewall on, the connection times out; "open" means the LAN still gets in.
harden_lan_probe() {
  local id=$1 name ips
  name=$(registry_get "$id" name)
  # shellcheck disable=SC2016,SC2088  # expanded by the node's shell
  ips=$(node_ssh "$id" '~/.local/bin/fleet status --json' </dev/null 2>/dev/null \
    | python3 -c 'import json, sys
try: print(" ".join(i for i in json.load(sys.stdin).get("lan_ips") or [] if ":" not in i))
except Exception: pass' 2>/dev/null || true)
  [ -n "$ips" ] || { log "$name reports no LAN address; nothing to probe"; return 0; }
  # shellcheck disable=SC2086  # one argument per address
  python3 - "$name" $ips <<'PY'
import socket, sys
name, ips = sys.argv[1], sys.argv[2:]
for ip in ips:
    s = socket.socket(); s.settimeout(3)
    try:
        s.connect((ip, 22)); state = "OPEN: the LAN still reaches ssh"
    except ConnectionRefusedError:
        state = "refused: no firewall answers for it (nothing listens, or the firewall is off)"
    except OSError:
        state = "no answer (closed to the LAN, or this machine is on another network)"
    finally:
        s.close()
    print("lan probe  %s %s:22  %s" % (name, ip, state))
PY
}

# harden_remote on|off|status NODE YES
harden_remote() {
  local mode=$1 q=$2 yes=$3 id name user host nonce rc=0
  vault_require
  id=$(registry_find "$q"); name=$(registry_get "$id" name)
  node_revoked "$id" && die "node $name is revoked"
  if [ "$(registry_get "$id" container)" = true ]; then log "$name is a container: its host decides what reaches it; nothing to change"; return 0; fi
  peer_online "$(ts_peers)" "$id" || die "$name is not online on the tailnet" "fleet list"
  user=$(registry_get "$id" user); host=$(registry_get "$id" dnsname)
  case "$mode" in
    status)
      # shellcheck disable=SC2088  # the ~ is expanded by the node's shell
      node_ssh "$id" '~/.local/bin/fleet harden status' </dev/null \
        || die "$name has no 'fleet harden' (older than 0.7.0)" "fleet provision $name"
      harden_lan_probe "$id"
      return 0 ;;
    off)
      log "$name: fleet harden off (type your sudo password at the node's prompt)"
      # shellcheck disable=SC2088
      ssh_tty_to "$user" "$host" "~/.local/bin/fleet harden off --yes" || rc=$?
      [ "$rc" = 0 ] || { audit harden "$name" "fail off rc=$rc"; die "fleet harden off failed on $name (exit $rc)"; }
      audit harden "$name" off
      ok "$name: firewall off"
      return 0 ;;
  esac
  if [ "$yes" != 1 ]; then
    printf 'Close %s (%s) to everything but the tailnet: a firewall on the node (you type its sudo password there) and nightly Tailscale updates.\nThe node removes the firewall again by itself unless a fresh tailnet ssh connection from here confirms within %ss.\n' "$name" "$id" "$FLEET_HARDEN_CONFIRM_SECS" >&2
    typed_confirm 'Type yes to continue (anything else aborts): ' yes || die "aborted"
  fi
  nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  log "$name: fleet harden on (type your sudo password at the node's prompt)"
  # shellcheck disable=SC2088,SC2016  # ~ and $HOME are expanded by the node's shell
  ssh_tty_to "$user" "$host" "~/.local/bin/fleet harden on --yes --confirm \"\$HOME/.config/fleet/harden-confirm.$nonce\"" || rc=$?
  if [ "$rc" != 0 ]; then
    audit harden "$name" "fail on rc=$rc"
    [ "$rc" != 2 ] || die "$name runs a fleet without 'harden' (older than 0.7.0)" "fleet provision $name, then rerun: fleet harden on $name"
    die "fleet harden on failed on $name (exit $rc: wrong password or the firewall was refused; see above)" "rerun: fleet harden on $name"
  fi
  sleep 2
  # shellcheck disable=SC2016  # $HOME is expanded by the node's shell
  if ! node_ssh "$id" "touch \"\$HOME/.config/fleet/harden-confirm.$nonce\"" </dev/null; then
    audit harden "$name" "fail on unconfirmed"
    die "a fresh tailnet ssh connection to $name failed after the firewall went up; the node removes it within ${FLEET_HARDEN_CONFIRM_SECS}s" "fleet harden status $name"
  fi
  audit harden "$name" on
  ok "$name: only the tailnet reaches it now (confirmed over a fresh tailnet connection)"
  harden_lan_probe "$id"
}
