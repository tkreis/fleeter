# shellcheck shell=bash
# T3 Code desktop app from GitHub releases (pingdotgg/t3code). The app updates
# itself (electron-updater), but only while it runs: a node where nobody opens
# it keeps whatever was installed first. install and update therefore replace
# an app that is older than the latest stable release; a running app is left to
# its own updater.
#   macOS: <tag>/T3-Code-<ver>-{arm64,x64}.dmg → /Applications (or ~/Applications)
#   Linux: <tag>/T3-Code-<ver>-{arm64,x86_64}.AppImage → ~/.local/bin/t3code, GUI only
#
# Remote use from the master (fleet t3 setup, lib/t3.sh) needs none of this:
# T3's SSH flow installs its own `t3` CLI archive under ~/.t3/runtime/versions/
# with curl|wget + tar (darwin-arm64, linux-arm64, linux-x64; there is no
# darwin-x64 archive) and reuses the desktop app's server when it is running.
# The status line reports which runtimes are present.

# _t3_runtimes — versions of the t3 CLI archive T3 installed, oldest first.
_t3_runtimes() {
  local d r=""
  for d in "$HOME"/.t3/runtime/versions/*/; do
    [ -x "$d/t3" ] && [ -s "$d/.install-complete" ] && r="$r $(basename "$d")"
  done
  printf '%s' "${r# }"
}

_t3_app() {
  local a
  for a in "/Applications/T3 Code"*.app "$HOME/Applications/T3 Code"*.app; do
    [ -d "$a" ] && { echo "$a"; return; }
  done
  return 1
}

_t3_has_display() { [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; }
_t3_version_file() { echo "$FLEET_HOME/t3code.version"; }

# _t3_installed_version — version of the installed app, empty when unknown.
_t3_installed_version() {
  local app
  case "$(fleet_os)" in
    macos) app=$(_t3_app) && defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null ;;
    linux) cat "$(_t3_version_file)" 2>/dev/null ;;
  esac
  return 0
}

# _t3_older A B — true when version A is before B (numeric x.y.z; a
# -nightly/-preview suffix is ignored, the release feed only has stable tags).
_t3_older() {
  python3 -c '
import re, sys
v = lambda s: [int(x) for x in re.findall(r"\d+", s.split("-")[0])]
sys.exit(0 if v(sys.argv[1]) < v(sys.argv[2]) else 1)' "$1" "$2"
}

# Prints "<version> <download url>" for this OS/arch from the latest release.
_t3_release() {
  curl -fsSL -H 'Accept: application/vnd.github+json' https://api.github.com/repos/pingdotgg/t3code/releases/latest \
    | python3 -c '
import json, sys
suffix = {"macos": {"arm64": "-arm64.dmg", "amd64": "-x64.dmg"},
          "linux": {"arm64": "-arm64.AppImage", "amd64": "-x86_64.AppImage"}}[sys.argv[1]][sys.argv[2]]
d = json.load(sys.stdin)
for a in d.get("assets", []):
    if a["name"].endswith(suffix):
        print(d["tag_name"].lstrip("v"), a["browser_download_url"]); break
' "$(fleet_os)" "$(fleet_arch)"
}

# _t3_install_macos "<version> <url>" — copy the dmg's app next to the old one
# (or into /Applications) and swap it in, so a failed copy keeps the old app.
_t3_install_macos() {
  local rel=$1 ver url tmp app old dest name
  ver=${rel%% *}; url=${rel#* }
  log "installing T3 Code $ver"
  tmp=$(mktemp -d) || die "mktemp failed"
  curl -fsSL -o "$tmp/t3.dmg" "$url" || { rm -rf "$tmp"; die "download failed" "$url"; }
  mkdir -p "$tmp/mnt"
  hdiutil attach -nobrowse -readonly -quiet -mountpoint "$tmp/mnt" "$tmp/t3.dmg" || { rm -rf "$tmp"; die "hdiutil attach failed"; }
  app=$(find "$tmp/mnt" -maxdepth 1 -name '*.app' | head -1)
  if old=$(_t3_app); then dest=$(dirname "$old")
  else dest=/Applications; [ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }; fi
  name=$(basename "${app:-x.app}")
  if [ -n "$app" ]; then
    rm -rf "$dest/.$name.new"
    ditto "$app" "$dest/.$name.new" || { hdiutil detach -quiet "$tmp/mnt" || true; rm -rf "$tmp" "$dest/.$name.new"; die "copy into $dest failed"; }
  fi
  hdiutil detach -quiet "$tmp/mnt" || true
  rm -rf "$tmp"
  [ -n "$app" ] || die "no .app inside the dmg"
  [ -z "$old" ] || rm -rf "$old"
  rm -rf "${dest:?}/$name"
  mv "$dest/.$name.new" "$dest/$name" || die "could not move T3 Code into $dest"
  ok "T3 Code $ver installed in $dest"
}

# _t3_install_linux "<version> <url>"
_t3_install_linux() {
  local rel=$1 ver url tmp
  ver=${rel%% *}; url=${rel#* }
  log "installing T3 Code $ver (AppImage)"
  mkdir -p "$FLEET_BIN"
  tmp=$(mktemp "$FLEET_BIN/.t3code.XXXXXX") || die "mktemp failed"
  curl -fsSL -o "$tmp" "$url" || { rm -f "$tmp"; die "download failed" "$url"; }
  chmod 0755 "$tmp" && mv -f "$tmp" "$FLEET_BIN/t3code"
  printf '%s\n' "$ver" | atomic_write "$(_t3_version_file)"
  ok "T3 Code $ver installed as $FLEET_BIN/t3code"
}

_t3_install() {
  if [ "$(fleet_os)" = macos ]; then _t3_install_macos "$1"; else _t3_install_linux "$1"; fi
}

_t3_running() {
  local app
  if [ "$(fleet_os)" = macos ]; then app=$(_t3_app) && pgrep -f "$app/Contents/MacOS/" >/dev/null 2>&1
  else pgrep -f "$FLEET_BIN/t3code" >/dev/null 2>&1; fi
}

# _t3_converge — install when missing, replace when older than the latest
# release. A failed release lookup only warns when an app is already there.
_t3_converge() {
  local cur rel
  cur=$(_t3_installed_version)
  rel=$(_t3_release) || rel=""
  if [ -z "$rel" ]; then
    if [ -n "$cur" ] || { [ "$(fleet_os)" = linux ] && [ -x "$FLEET_BIN/t3code" ]; } || _t3_app >/dev/null 2>&1; then
      warn "t3code: could not read the latest release; keeping ${cur:-the installed version}"; return 0
    fi
    die "no T3 Code download for $(fleet_os)/$(fleet_arch) in the latest release"
  fi
  if [ -n "$cur" ] && ! _t3_older "$cur" "${rel%% *}"; then ok "T3 Code $cur present"; return 0; fi
  if [ -n "$cur" ] && _t3_running; then
    warn "T3 Code $cur is running and older than ${rel%% *}; it updates itself, or quit it and run: fleet update"
    return 0
  fi
  _t3_install "$rel"
}

# ---------- phone access (FLEET_T3_MOBILE=1) ----------
# The T3 phone app has no SSH route ("SSH environments are only available in
# the desktop app"). A node it should reach runs T3's own background service
# (`t3 service install`: launchd gui/<uid>, or systemd --user) on loopback, and
# Tailscale Serve publishes it as https://<node>.<tailnet>.ts.net (443, tailnet
# only). T3 Connect stays publish-only (push notifications through the relay,
# no tunnel); linking it needs a browser approval, see `fleet t3 pair`.
# The unit is T3's. fleet only pins T3CODE_HOST=127.0.0.1 in it, because
# `t3 serve` outside desktop mode binds every interface and `t3 update`
# re-renders the unit without the pin (a systemd drop-in survives that, the
# launchd plist does not). Restarting the server ends the agent sessions it
# runs, so apply restarts it only while none is open and retries otherwise.
T3_MOBILE_PORT=3773
T3_MOBILE_SERVE_PORT=443
T3_SERVICE_LABEL=com.t3tools.t3code.service
T3_AGENT_RE='claude|codex|cursor-agent|grok|opencode'

# _t3_cli — the newest t3 CLI runtime T3 installed, or nothing.
_t3_cli() {
  local v
  v=$(_t3_runtimes | tr ' ' '\n' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  [ -n "$v" ] && echo "$HOME/.t3/runtime/versions/$v/t3"
}

_t3_unit() {
  if [ "$(fleet_os)" = macos ]; then echo "$HOME/Library/LaunchAgents/$T3_SERVICE_LABEL.plist"
  else echo "$HOME/.config/systemd/user/t3code.service"; fi
}
_t3_dropin() { echo "$HOME/.config/systemd/user/t3code.service.d/fleet.conf"; }

_t3_host_pinned() {
  if [ "$(fleet_os)" = macos ]; then
    [ "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:T3CODE_HOST' "$(_t3_unit)" 2>/dev/null)" = 127.0.0.1 ]
  else
    grep -qx 'Environment=T3CODE_HOST=127.0.0.1' "$(_t3_dropin)" 2>/dev/null
  fi
}

_t3_pin_host() {
  if [ "$(fleet_os)" = macos ]; then
    /usr/libexec/PlistBuddy -c 'Set :EnvironmentVariables:T3CODE_HOST 127.0.0.1' "$(_t3_unit)" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables:T3CODE_HOST string 127.0.0.1' "$(_t3_unit)"
  else
    mkdir -p "$(dirname "$(_t3_dropin)")"
    printf '# managed by fleet: keep the T3 server on loopback (Tailscale Serve publishes it)\n[Service]\nEnvironment=T3CODE_HOST=127.0.0.1\n' \
      | atomic_write "$(_t3_dropin)"
    systemctl --user daemon-reload
  fi
}

# _t3_servers — pids of running T3 servers (the service's, or one T3's SSH flow started).
_t3_servers() { pgrep -f '\.t3/runtime/versions/[^/]*/t3 serve' 2>/dev/null || true; }

# _t3_foreign_servers — servers the service did not start (desktop SSH launches).
_t3_foreign_servers() {
  local p pp
  for p in $(_t3_servers); do
    pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    ps -o command= -p "${pp:-0}" 2>/dev/null | grep -q -- '__service-launcher' || echo "$p"
  done
}

# _t3_sessions — agent processes the running servers own.
_t3_sessions() {
  local s
  s=$(_t3_servers | tr '\n' ' ')
  [ -n "$s" ] || { echo 0; return; }
  ps -axo ppid=,command= 2>/dev/null | awk -v s=" $s" -v re="$T3_AGENT_RE" \
    'index(s, " " $1 " ") { $1 = ""; if ($0 ~ re) n++ } END { print n + 0 }'
}

# _t3_exposed — true when something listens on the T3 port beyond loopback.
_t3_exposed() {
  local l
  if [ "$(fleet_os)" = macos ]; then
    l=$(lsof -nP -iTCP:"$T3_MOBILE_PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }')
  else
    l=$(ss -ltnH "sport = :$T3_MOBILE_PORT" 2>/dev/null | awk '{ print $4 }')
  fi
  printf '%s\n' "$l" | grep -vE '^(127\.0\.0\.1|\[::1\]|::1):|^$' | grep -q .
}

_t3_service_restart() {
  local p n=0
  for p in $(_t3_foreign_servers); do kill -TERM "$p" 2>/dev/null || true; done
  while [ -n "$(_t3_foreign_servers)" ] && [ "$n" -lt 60 ]; do sleep 1; n=$((n + 1)); done
  if [ "$(fleet_os)" = macos ]; then
    if launchctl print "gui/$(id -u)/$T3_SERVICE_LABEL" >/dev/null 2>&1; then
      launchctl kickstart -k "gui/$(id -u)/$T3_SERVICE_LABEL"
    else
      launchctl bootstrap "gui/$(id -u)" "$(_t3_unit)"
    fi
  else
    systemctl --user enable t3code.service >/dev/null 2>&1 || true
    systemctl --user restart t3code.service
  fi
}

_t3_ts() { if type join_ts_bin >/dev/null 2>&1; then join_ts_bin; else command -v tailscale; fi; }

# _t3_serve_ok TS — Tailscale Serve maps https 443 to the local T3 server.
_t3_serve_ok() {
  "$1" serve status --json 2>/dev/null | python3 -c '
import json, sys
port, target = sys.argv[1], sys.argv[2]
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
if not d.get("TCP", {}).get(port, {}).get("HTTPS"): sys.exit(1)
ok = any(k.endswith(":" + port) and v.get("Handlers", {}).get("/", {}).get("Proxy") == target
         for k, v in (d.get("Web") or {}).items())
sys.exit(0 if ok else 1)' "$T3_MOBILE_SERVE_PORT" "http://127.0.0.1:$T3_MOBILE_PORT"
}

# _t3_mobile_converge — service installed, host pinned, server restarted onto
# it when needed and idle, Tailscale Serve mapping present. Only warns.
_t3_mobile_converge() {
  local cli ts n cmd restart=0
  cli=$(_t3_cli)
  if [ -z "$cli" ]; then
    log "t3 mobile: no t3 runtime yet; connect once from the master's T3 app (fleet t3 setup)"; return 0
  fi
  if [ ! -f "$(_t3_unit)" ]; then
    "$cli" service install </dev/null >/dev/null 2>&1 || { warn "t3 mobile: t3 service install failed"; return 0; }
    ok "T3 background service installed"
    restart=1
  fi
  if ! _t3_host_pinned; then
    _t3_pin_host || { warn "t3 mobile: could not pin T3CODE_HOST in $(_t3_unit)"; return 0; }
    restart=1
  fi
  if [ -n "$(_t3_foreign_servers)" ] || [ -z "$(_t3_servers)" ] || _t3_exposed; then restart=1; fi
  if [ "$restart" = 1 ]; then
    n=$(_t3_sessions)
    if [ "$n" -gt 0 ]; then
      if [ "$(fleet_os)" = macos ]; then cmd="launchctl kickstart -k gui/\$(id -u)/$T3_SERVICE_LABEL"
      else cmd="systemctl --user restart t3code.service"; fi
      warn "t3 mobile: T3 server restart deferred, $n agent session(s) open; next apply retries (now, ending them: $cmd)"
    elif _t3_service_restart; then
      ok "T3 server restarted on the background service (127.0.0.1:$T3_MOBILE_PORT)"
    else
      warn "t3 mobile: could not restart the T3 service"
    fi
  fi
  ts=$(_t3_ts) || ts=""
  if [ -z "$ts" ]; then warn "t3 mobile: tailscale CLI not found; no Tailscale Serve mapping"
  elif ! _t3_serve_ok "$ts"; then
    if "$ts" serve --bg --https="$T3_MOBILE_SERVE_PORT" "http://127.0.0.1:$T3_MOBILE_PORT" >/dev/null 2>&1; then
      ok "Tailscale Serve: https port $T3_MOBILE_SERVE_PORT -> T3 (tailnet only)"
    else
      warn "t3 mobile: tailscale serve failed (linux: sudo tailscale set --operator=\$USER, then fleet apply)"
    fi
  fi
  if pgrep -f '\.t3/tools/cloudflared' >/dev/null 2>&1; then
    warn "t3 mobile: a T3 Connect relay tunnel is running; switch to publish-only with fleet t3 pair NODE on the master"
  fi
  return 0
}

# _t3_mobile_state — one word for the status line.
_t3_mobile_state() {
  local ts
  [ -n "$(_t3_cli)" ] || { echo no-runtime; return; }
  [ -f "$(_t3_unit)" ] || { echo no-service; return; }
  _t3_host_pinned || { echo unpinned; return; }
  if [ -n "$(_t3_foreign_servers)" ] || [ -z "$(_t3_servers)" ] || _t3_exposed; then echo restart-pending; return; fi
  if ! ts=$(_t3_ts) || ! _t3_serve_ok "$ts"; then echo no-serve; return; fi
  echo ok
}

tool_t3code_install() {
  if fleet_in_container; then log "t3code: skipped inside container"; return 0; fi
  case "$(fleet_os)" in
    macos) _t3_converge ;;
    linux)
      if _t3_has_display; then _t3_converge; else log "t3code: no display, app skipped"; fi ;;
  esac
  [ "${FLEET_T3_MOBILE:-0}" != 1 ] || _t3_mobile_converge
}

tool_t3code_update() { tool_t3code_install; }

tool_t3code_status() {
  local app ver rt
  if fleet_in_container; then echo "skipped container"; return 0; fi
  rt=$(_t3_runtimes); rt=${rt:+ runtime:$(printf '%s' "$rt" | tr ' ' ',')}
  [ "${FLEET_T3_MOBILE:-0}" != 1 ] || rt="$rt mobile:$(_t3_mobile_state)"
  case "$(fleet_os)" in
    macos)
      app=$(_t3_app) || { echo "missing run: fleet apply"; return 0; }
      ver=$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
      echo "ok ${ver:-?} self-updates$rt" ;;
    linux)
      _t3_has_display || { echo "skipped no display$rt"; return 0; }
      [ -x "$FLEET_BIN/t3code" ] || { echo "missing run: fleet apply"; return 0; }
      echo "ok $(cat "$(_t3_version_file)" 2>/dev/null || echo '?') self-updates$rt" ;;
    *) echo "skipped unsupported os" ;;
  esac
}
