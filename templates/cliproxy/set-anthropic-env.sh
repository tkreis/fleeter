#!/usr/bin/env bash
# macOS only. Publish ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN into the user's
# launchd session, so GUI apps (T3 Code, etc.) inherit them without a wrapper.
#
# Scope: processes launched by launchd AFTER this runs. Already-running apps
# keep their old env; new Terminal windows also inherit these.
# Undo: ./set-anthropic-env.sh off
#
# The key is read from conf/config.yaml so it exists in exactly one place on disk.
set -euo pipefail

BASE_URL="${FLEET_PROXY_URL:-http://127.0.0.1:8317}"

cd "$(dirname "$0")"

if [ "${1:-on}" = off ]; then
  launchctl unsetenv ANTHROPIC_BASE_URL
  launchctl unsetenv ANTHROPIC_AUTH_TOKEN
  echo "unset. Relaunch any app that should go back to native auth."
  exit 0
fi

# Legacy layout: top-level api-keys list. v8 layout (written by the panel on
# any config save): access.api-keys, while top-level api-keys holds upstream
# provider groups — so only take plain list items, never "- key: value" maps.
KEY="$(awk '/^[^[:space:]#]/{f=0} /^api-keys:/{f=1;next} /^access:/{a=1;next} /^[^[:space:]#]/{a=0} a&&/^[[:space:]]+api-keys:/{f=1;next} f&&/^[[:space:]]*-[[:space:]]*"?[^:[:space:]]+"?[[:space:]]*$/{gsub(/^[[:space:]]*-[[:space:]]*"?|"?[[:space:]]*$/,"");print;exit}' conf/config.yaml)"
[ -n "$KEY" ] || { echo "no api-keys entry found in conf/config.yaml" >&2; exit 1; }

launchctl setenv ANTHROPIC_BASE_URL "$BASE_URL"
# launchctl setenv has no stdin form: the key is briefly visible in this process's argv
# (local user only, milliseconds); it is never logged — below prints only configured/missing.
launchctl setenv ANTHROPIC_AUTH_TOKEN "$KEY"

echo "ANTHROPIC_BASE_URL   = $(launchctl getenv ANTHROPIC_BASE_URL)"
if [ -n "$(launchctl getenv ANTHROPIC_AUTH_TOKEN)" ]; then
  echo "ANTHROPIC_AUTH_TOKEN   configured"
else
  echo "ANTHROPIC_AUTH_TOKEN   missing"
fi
