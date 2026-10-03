#!/usr/bin/env bash
# Fake `tailscale` CLI for tests/e2e.sh (mounted at /usr/local/bin/tailscale in
# FLEET_FAKE_TAILSCALE=1 containers). Writes nothing real: state lives in
# /tmp/fake-tailscale so that `fleet join` (container env) and `fleet leave`
# (ssh session, no container env) see the same thing.
#   up --auth-key=file:F --advertise-tags=T --hostname=H   -> Running as H
#   status --json                                           -> Self with H
#   logout                                                  -> NeedsLogin
set -u
D=/tmp/fake-tailscale
mkdir -p "$D" 2>/dev/null; chmod 1777 "$D" 2>/dev/null || true
printf '%s\n' "$*" >>"$D/log" 2>/dev/null || true
chmod 666 "$D/log" 2>/dev/null || true
# the root-side supervisor passes --socket=…; the user does not
while [ $# -gt 0 ]; do case "$1" in --socket=*) shift ;; *) break ;; esac; done
case "${1:-}" in
  status)
    if [ -s "$D/hostname" ]; then
      h=$(cat "$D/hostname")
      printf '{"BackendState":"Running","Self":{"ID":"nFAKE%sCNTRL","HostName":"%s","DNSName":"%s.fake.ts.net.","Tags":["tag:fleet-node"],"Online":true},"Peer":{}}\n' "$h" "$h" "$h"
    else
      echo '{"BackendState":"NeedsLogin","Self":{},"Peer":{}}'
    fi ;;
  up)
    for a in "$@"; do
      case "$a" in
        --auth-key=file:*) f=${a#--auth-key=file:}; [ -s "$f" ] || { echo "fake tailscale: empty key file" >&2; exit 1; } ;;
        --hostname=*) printf '%s\n' "${a#--hostname=}" >"$D/hostname"; chmod 666 "$D/hostname" 2>/dev/null || true ;;
      esac
    done ;;
  logout) rm -f "$D/hostname" ;;
  set|version|ping) : ;;
  *) echo "fake tailscale: unsupported: $*" >&2; exit 2 ;;
esac
