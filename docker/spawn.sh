#!/usr/bin/env bash
# docker/spawn.sh — run on the MASTER: start N ephemeral Docker nodes, each with
# its own single-use invite (`fleet invite --ephemeral --name fleet-dock-<rand>`).
#
#   docker/spawn.sh N [--image IMG] [--profile minimal|full] [--dry-run] [-- DOCKER_RUN_ARGS...]
#
#   N            number of containers (one invite each; keys are single use)
#   --image      node image (default fleet-node:local; build it with
#                docker build -f docker/Dockerfile -t fleet-node:local .)
#   --profile    secret profile for the invites (default: FLEET_EPHEMERAL_PROFILE = minimal)
#   --dry-run    print what would run, mint nothing, start nothing
#   -- ...       extra `docker run` arguments (e.g. -e FLEET_TOOLS="base devtools claude")
#
# The invite code reaches the container as a bind-mounted 0600 file
# (-v <tmp>:/run/fleet-invite:ro, FLEET_INVITE_FILE=/run/fleet-invite): never in
# argv, never in the container's environment, so `docker inspect` does not show
# it. The host file is deleted as soon as the container reports it has joined
# (enrol.json present), or after 60 s at the latest.
# Containers are named like the node (fleet-dock-<rand>) so `fleet nodes` and
# `docker ps` line up. Remove one with `fleet kick fleet-dock-<rand>` (the
# container exits by itself) and then `docker rm`.
# bash 3.2 safe (macOS master).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
FLEET="$ROOT/fleet"
IMAGE=${FLEET_NODE_IMAGE:-fleet-node:local}
PROFILE=""
DRY=0
N=""

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --image)   IMAGE=${2:-}; shift ;;
    --profile) PROFILE=${2:-}; shift ;;
    --dry-run) DRY=1 ;;
    --)        shift; break ;;
    -h|--help) usage ;;
    -*)        echo "unknown flag: $1" >&2; usage ;;
    *)         [ -z "$N" ] || usage; N=$1 ;;
  esac
  shift
done
case "$N" in ''|*[!0-9]*|0) usage ;; esac
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
[ -x "$FLEET" ] || { echo "fleet not found at $FLEET" >&2; exit 1; }
if [ "$DRY" = 0 ] && ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "image $IMAGE not found; build it: docker build -f $ROOT/docker/Dockerfile -t $IMAGE $ROOT" >&2
  exit 1
fi

INVITE_DIR=""
PENDING=""   # "name:file" pairs of host invite files still to delete
cleanup() { [ -n "$INVITE_DIR" ] && rm -rf "$INVITE_DIR"; }
trap cleanup EXIT

# joined CONTAINER — true once `fleet join` in the container wrote enrol.json.
joined() { docker exec "$1" sh -c 'test -s "$(getent passwd "${FLEET_USER:-fleet}" | cut -d: -f6)/.config/fleet/enrol.json"' >/dev/null 2>&1; }

[ "$DRY" = 1 ] || { INVITE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fleet-spawn.XXXXXX"); chmod 0700 "$INVITE_DIR"; }
i=0
while [ "$i" -lt "$N" ]; do
  i=$((i + 1))
  rand=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
  name="fleet-dock-$rand"
  # --user fleet: the image's login is `fleet`, not the master's user name
  if [ "$DRY" = 1 ]; then
    printf '%s: fleet invite --ephemeral --name %s --user fleet%s --code-only; docker run -d --name %s --hostname %s -v <tmp>:/run/fleet-invite:ro -e FLEET_INVITE_FILE=/run/fleet-invite --stop-timeout 20 %s %s\n' \
      "$i" "$name" "${PROFILE:+ --profile $PROFILE}" "$name" "$name" "$*" "$IMAGE"
    continue
  fi
  if [ -n "$PROFILE" ]; then
    code=$("$FLEET" invite --ephemeral --name "$name" --user fleet --profile "$PROFILE" --code-only)
  else
    code=$("$FLEET" invite --ephemeral --name "$name" --user fleet --code-only)
  fi
  [ -n "$code" ] || { echo "fleet invite returned no code" >&2; exit 1; }
  invf="$INVITE_DIR/$name"
  (umask 077; printf '%s\n' "$code" >"$invf")
  code=""
  if cid=$(docker run -d --name "$name" --hostname "$name" -v "$invf:/run/fleet-invite:ro" -e FLEET_INVITE_FILE=/run/fleet-invite \
             --stop-timeout 20 "$@" "$IMAGE"); then
    PENDING="$PENDING $name"
    printf '%s %s\n' "$name" "${cid%"${cid#????????????}"}"
  else
    rm -f "$invf"
    echo "docker run failed for $name (its invite stays pending until it expires; 'fleet reconcile' cleans it up)" >&2
    exit 1
  fi
done
[ "$DRY" = 1 ] && exit 0

# Delete each host invite file once its container has joined, or after 60 s.
# Truncate before unlink: the bind-mounted inode stays readable inside the
# container after the host name is gone, an empty file does not.
scrub() { : >"$1" 2>/dev/null || true; rm -f "$1"; }
t=0
while [ -n "$PENDING" ] && [ "$t" -lt 60 ]; do
  left=""
  for name in $PENDING; do
    if joined "$name"; then scrub "$INVITE_DIR/$name"; else left="$left $name"; fi
  done
  PENDING=$left
  [ -z "$PENDING" ] || { sleep 2; t=$((t + 2)); }
done
for name in $PENDING; do
  echo "$name did not report joined within 60s; its invite file is removed anyway (docker logs $name)" >&2
  scrub "$INVITE_DIR/$name"
done
rm -rf "$INVITE_DIR"; INVITE_DIR=""
echo "started $N node(s); 'fleet reconcile' (or the 2-min timer) enrols and provisions them" >&2
