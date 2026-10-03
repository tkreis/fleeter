#!/usr/bin/env bash
# Login-time bringup for CLIProxyAPI on a fleet node. Run by the
# dev.fleet.cliproxy LaunchAgent (macOS) or fleet-cliproxy.service (Linux).
#
#   1. make sure a Docker daemon is up (Docker Desktop, colima, or system dockerd)
#   2. bring the container up
#   3. macOS: publish ANTHROPIC_* into the launchd session for GUI apps
#
# launchd/systemd give a near-empty PATH, so it is set explicitly.
set -uo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR" || exit 1

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

log "bringup starting"

if ! docker info >/dev/null 2>&1; then
  if [ "$(uname -s)" = Darwin ]; then
    if [ -d /Applications/Docker.app ]; then
      log "starting Docker Desktop"
      open -gj -a /Applications/Docker.app   # -g: no focus, -j: no window
    elif command -v colima >/dev/null 2>&1; then
      log "starting colima"
      colima start >/dev/null 2>&1
    fi
  fi
fi

# A VM-backed daemon can take a while on a cold boot.
for i in $(seq 1 90); do
  if docker info >/dev/null 2>&1; then
    log "daemon ready after ${i}s"
    break
  fi
  sleep 1
done

if ! docker info >/dev/null 2>&1; then
  log "ERROR: daemon still unreachable after 90s, giving up"
  exit 1
fi

if [ ! -f conf/config.yaml ]; then
  log "ERROR: conf/config.yaml missing (shipped by the master with the full profile)"
  exit 1
fi

# restart:unless-stopped usually revives the container by itself; this is the
# fallback for a fresh boot, an image change, or a manual `compose down`.
log "compose up"
docker compose up -d 2>&1

for i in $(seq 1 30); do
  if curl -sf -m 2 -o /dev/null "http://127.0.0.1:@FLEET_PROXY_PORT@/management.html"; then
    log "proxy answering on @FLEET_PROXY_PORT@ after ${i}s"
    break
  fi
  sleep 1
done

if [ "$(uname -s)" = Darwin ] && [ -x ./set-anthropic-env.sh ]; then
  log "publishing launchd env"
  ./set-anthropic-env.sh on 2>&1
fi

log "bringup done"
