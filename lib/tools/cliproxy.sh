# shellcheck shell=bash
# CLIProxyAPI: the same compose setup as the master's Mac, in ~/cli-proxy-api.
#
#   conf/config.yaml + auth/   secrets, shipped by the master (full profile) to
#                              ~/.cli-proxy-api/ and adopted from there
#   compose.yaml, boot.sh,     rendered from templates/cliproxy/ (set-anthropic-env.sh
#   set-anthropic-env.sh       on macOS only)
#   dev.fleet.cliproxy         LaunchAgent (macOS) / systemd user unit (Linux)
#
# Containers and FLEET_PROXY_MODE=remote install nothing and only probe
# FLEET_PROXY_URL. Nothing here ever prints a key.

_cliproxy_dir()   { echo "${FLEET_CLIPROXY_DIR:-$HOME/cli-proxy-api}"; }
_cliproxy_stage() { echo "$HOME/.cli-proxy-api"; }   # where the master drops the secrets
_cliproxy_remote() { fleet_in_container || [ "${FLEET_PROXY_MODE:-local}" = remote ]; }

# HTTP status of the proxy's /v1/models; 401 means up but wants a key.
_cliproxy_http() { curl -s -m 3 -o /dev/null -w '%{http_code}' "${FLEET_PROXY_URL:-http://127.0.0.1:8317}/v1/models" 2>/dev/null; }
_cliproxy_up() { case "$(_cliproxy_http)" in 200|401|403) return 0 ;; *) return 1 ;; esac; }

# cliproxy_client_key — first client API key from conf/config.yaml, for
# ANTHROPIC_AUTH_TOKEN in env.sh. Supports the legacy top-level `api-keys` list
# and the v8 `access.api-keys` list; skips `- key: value` provider maps. Caller
# captures stdout; never log the result.
cliproxy_client_key() {
  local f
  f="${1:-$(_cliproxy_dir)/conf/config.yaml}"
  [ -r "$f" ] || return 1
  python3 - "$f" <<'PY'
import sys

def scalar(v):
    v = v.strip()
    if v[:1] in "\"'" and v[-1:] == v[:1]:
        v = v[1:-1]
    return v if v and ":" not in v and not v.startswith(("[", "{", "#")) else None

def inline(rest):
    rest = rest.strip()
    if rest.startswith("[") and rest.endswith("]"):
        for item in rest[1:-1].split(","):
            s = scalar(item)
            if s:
                return s
    return None

top = sub = None
in_list = False
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.rstrip("\n")
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    indent = len(line) - len(line.lstrip(" "))
    if indent == 0:
        top, _, rest = s.partition(":")
        sub = None
        in_list = top == "api-keys"
        if in_list and inline(rest):
            print(inline(rest)); sys.exit(0)
        continue
    if s.startswith("-"):
        if in_list:
            v = scalar(s[1:])
            if v:
                print(v); sys.exit(0)
        continue
    # a nested mapping line
    key, _, rest = s.partition(":")
    if top == "access":
        sub = key
        in_list = sub == "api-keys"
        if in_list and inline(rest):
            print(inline(rest)); sys.exit(0)
    else:
        in_list = False
sys.exit(1)
PY
}

# _cliproxy_render SRC DEST MODE — copy a template, substituting the knobs from
# fleet.conf (image, timezone, container name, port), only when the content changed.
_cliproxy_render() {
  local tmp
  tmp=$(mktemp) || die "mktemp failed"
  sed -e "s|@FLEET_PROXY_IMAGE@|${FLEET_PROXY_IMAGE:-eceasy/cli-proxy-api:latest}|g" \
      -e "s|@FLEET_PROXY_TZ@|${FLEET_PROXY_TZ:-UTC}|g" \
      -e "s|@FLEET_PROXY_CONTAINER@|${FLEET_PROXY_CONTAINER:-cli-proxy-api}|g" \
      -e "s|@FLEET_PROXY_PORT@|${FLEET_PROXY_PORT:-8317}|g" "$1" >"$tmp"
  if [ -f "$2" ] && cmp -s "$tmp" "$2"; then rm -f "$tmp"; return 0; fi
  atomic_write "$2" "$3" <"$tmp"
  rm -f "$tmp"
}

# Move freshly shipped files from ~/.cli-proxy-api into the compose tree.
# config.yaml (client key, routing) comes from the master on every provision
# and replaces the local copy. Auth files arrive only with
# FLEET_PROXY_SHARE_AUTH=1 on the master; normally each node holds its own
# logins (fleet proxy login NODE) and nothing is staged under auth/.
_cliproxy_adopt() {
  local dir stage force f
  dir=$(_cliproxy_dir); stage=$(_cliproxy_stage)
  [ -d "$stage" ] || return 0
  if [ -f "$stage/config.yaml" ]; then
    mv -f "$stage/config.yaml" "$dir/conf/config.yaml"
    chmod 0600 "$dir/conf/config.yaml"
    log "adopted config.yaml from the master"
  fi
  # Auth files: a running proxy refreshes its OAuth tokens, so the node's copy
  # is newer than the master's. Adopt only files the node lacks, unless the
  # master sent .force (fleet provision NODE --refresh-proxy-auth).
  if [ -d "$stage/auth" ]; then
    force=0; [ -f "$stage/.force" ] && force=1
    for f in "$stage"/auth/*; do
      [ -e "$f" ] || continue
      if [ "$force" = 1 ] || [ ! -e "$dir/auth/$(basename "$f")" ]; then
        mv -f "$f" "$dir/auth/"
        log "adopted auth/$(basename "$f") from the master"
      else
        rm -f "$f"
      fi
    done
    chmod 0600 "$dir"/auth/* 2>/dev/null || true
    rmdir "$stage/auth" 2>/dev/null || true
  fi
  rm -f "$stage/.force"
  rmdir "$stage" 2>/dev/null || true
}

_cliproxy_install_launchd() {
  local dir=$1 label plist
  label=dev.fleet.cliproxy
  plist="$HOME/Library/LaunchAgents/$label.plist"
  if [ -f "$HOME/Library/LaunchAgents/local.cliproxy.boot.plist" ]; then
    log "legacy local.cliproxy.boot LaunchAgent present; not adding $label"
    return 0
  fi
  atomic_write "$plist" 0644 <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$dir/boot.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>StandardOutPath</key>
	<string>$dir/boot.log</string>
	<key>StandardErrorPath</key>
	<string>$dir/boot.log</string>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
EOF
  if ! launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || warn "launchctl bootstrap $label failed (no GUI session?)"
  fi
}

_cliproxy_install_systemd() {
  local dir=$1 unit
  have systemctl || { log "no systemd; boot.sh not scheduled"; return 0; }
  unit="$HOME/.config/systemd/user/fleet-cliproxy.service"
  atomic_write "$unit" 0644 <<EOF
[Unit]
Description=fleet: bring up CLIProxyAPI
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$dir/boot.sh
StandardOutput=append:$dir/boot.log
StandardError=append:$dir/boot.log

[Install]
WantedBy=default.target
EOF
  if systemctl --user daemon-reload >/dev/null 2>&1; then
    systemctl --user enable fleet-cliproxy.service >/dev/null 2>&1 || warn "systemctl --user enable failed"
  else
    warn "systemd user session unavailable; fleet-cliproxy.service written but not enabled"
  fi
}

tool_cliproxy_install() {
  local dir tpl
  if _cliproxy_remote; then
    log "cliproxy: remote mode, using ${FLEET_PROXY_URL:-http://127.0.0.1:8317}"
    return 0
  fi
  have docker || { warn "docker CLI not found (PATH: $PATH); cliproxy not installed (see devtools)"; return 0; }
  dir=$(_cliproxy_dir)
  mkdir -p "$dir/conf" "$dir/auth" "$dir/plugins"
  chmod 0700 "$dir/conf" "$dir/auth"

  tpl="$FLEET_ROOT/templates/cliproxy"
  _cliproxy_render "$tpl/compose.yaml" "$dir/compose.yaml" 0644
  _cliproxy_render "$tpl/boot.sh" "$dir/boot.sh" 0755
  [ "$(fleet_os)" = macos ] && _cliproxy_render "$tpl/set-anthropic-env.sh" "$dir/set-anthropic-env.sh" 0755

  _cliproxy_adopt
  if [ ! -f "$dir/conf/config.yaml" ]; then
    warn "no $dir/conf/config.yaml yet; the master ships it with the full profile"
    return 0
  fi

  if docker_ready; then
    (cd "$dir" && docker compose up -d >/dev/null 2>&1) || warn "docker compose up failed in $dir"
  else
    warn "docker daemon not reachable; boot.sh will start the proxy at next login"
  fi

  case "$(fleet_os)" in
    macos) _cliproxy_install_launchd "$dir" ;;
    linux) _cliproxy_install_systemd "$dir" ;;
  esac
  if _cliproxy_up; then ok "cliproxy answering"; else warn "cliproxy not answering yet"; fi
  return 0
}

tool_cliproxy_update() {
  local dir
  _cliproxy_remote && return 0
  dir=$(_cliproxy_dir)
  [ -f "$dir/compose.yaml" ] && [ -f "$dir/conf/config.yaml" ] || return 0
  docker info >/dev/null 2>&1 || return 0
  (cd "$dir" && docker compose pull -q >/dev/null 2>&1 && docker compose up -d >/dev/null 2>&1) || warn "cliproxy update failed"
}

# _cliproxy_node_name — this node's name for the hint, when lib/node.sh is loaded.
_cliproxy_node_name() {
  if declare -F node_name >/dev/null 2>&1; then node_name; else hostname -s 2>/dev/null || hostname; fi
}

# _cliproxy_login_expired — true when the container logged an upstream refresh
# failure (invalid_grant, "Refresh token not found or invalid") in the last
# 24 h that is newer than the newest auth file: the vendor rotated the refresh
# token elsewhere (another machine using a copy of the same login), the file
# on disk is dead, and only a new login on this node brings it back. A
# failure older than the newest file is from before that file was written.
_cliproxy_login_expired() {
  local dir container
  dir=$(_cliproxy_dir); container=${FLEET_PROXY_CONTAINER:-cli-proxy-api}
  docker logs --timestamps --since 24h "$container" 2>&1 | grep -E 'invalid_grant|Refresh token not found or invalid' \
    | python3 -c "$CLIPROXY_EXPIRED_PY" "$dir/auth"
}
# The matching log lines on stdin, the auth dir as argv[1]; exit 0 when the
# latest failure is newer than the newest auth file.
CLIPROXY_EXPIRED_PY=$(cat <<'PY'
import glob, os, sys
from datetime import datetime, timezone
newest = 0.0
for f in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        newest = max(newest, os.path.getmtime(f))
    except OSError:
        pass
last = None
for line in sys.stdin:
    ts = line.split(" ", 1)[0][:19]          # 2026-10-05T07:12:33.123456789Z -> seconds
    try:
        t = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        continue
    if last is None or t > last:
        last = t
sys.exit(0 if last is not None and last > newest else 1)
PY
)

tool_cliproxy_status() {
  local url code dir
  url=${FLEET_PROXY_URL:-http://127.0.0.1:8317}
  code=$(_cliproxy_http)
  if _cliproxy_remote; then
    case "$code" in 200|401|403) echo "ok remote $url ($code)" ;; *) echo "error remote $url unreachable" ;; esac
    return 0
  fi
  dir=$(_cliproxy_dir)
  have docker || { echo "missing docker"; return 0; }
  [ -f "$dir/conf/config.yaml" ] || { echo "missing conf/config.yaml (full profile)"; return 0; }
  case "$code" in
    200|401|403)
      if _cliproxy_login_expired; then echo "login upstream login expired: run on the master: fleet proxy login $(_cliproxy_node_name)"
      else echo "ok $url ($code)"; fi ;;
    *) if docker info >/dev/null 2>&1; then echo "error container down; run: docker compose -f $dir/compose.yaml up -d"
       else echo "error docker daemon down"; fi ;;
  esac
}
