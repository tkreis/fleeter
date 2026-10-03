# shellcheck shell=bash
# T3 Code desktop app from GitHub releases (pingdotgg/t3code). The app updates
# itself (electron-updater), so install only converges presence.
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

_t3_install_macos() {
  local rel ver url tmp app dest
  rel=$(_t3_release); ver=${rel%% *}; url=${rel#* }
  [ -n "$rel" ] || die "no T3 Code dmg for $(fleet_arch) in the latest release"
  log "installing T3 Code $ver"
  tmp=$(mktemp -d) || die "mktemp failed"
  curl -fsSL -o "$tmp/t3.dmg" "$url" || { rm -rf "$tmp"; die "download failed" "$url"; }
  mkdir -p "$tmp/mnt"
  hdiutil attach -nobrowse -readonly -quiet -mountpoint "$tmp/mnt" "$tmp/t3.dmg" || { rm -rf "$tmp"; die "hdiutil attach failed"; }
  app=$(find "$tmp/mnt" -maxdepth 1 -name '*.app' | head -1)
  dest=/Applications; [ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
  if [ -n "$app" ]; then ditto "$app" "$dest/$(basename "$app")"; fi
  hdiutil detach -quiet "$tmp/mnt" || true
  rm -rf "$tmp"
  [ -n "$app" ] || die "no .app inside the dmg"
  ok "T3 Code installed in $dest"
}

_t3_install_linux() {
  local rel ver url tmp
  rel=$(_t3_release); ver=${rel%% *}; url=${rel#* }
  [ -n "$rel" ] || die "no T3 Code AppImage for $(fleet_arch) in the latest release"
  log "installing T3 Code $ver (AppImage)"
  mkdir -p "$FLEET_BIN"
  tmp=$(mktemp "$FLEET_BIN/.t3code.XXXXXX") || die "mktemp failed"
  curl -fsSL -o "$tmp" "$url" || { rm -f "$tmp"; die "download failed" "$url"; }
  chmod 0755 "$tmp" && mv -f "$tmp" "$FLEET_BIN/t3code"
  printf '%s\n' "$ver" | atomic_write "$(_t3_version_file)"
  ok "T3 Code installed as $FLEET_BIN/t3code"
}

tool_t3code_install() {
  if fleet_in_container; then log "t3code: skipped inside container"; return 0; fi
  case "$(fleet_os)" in
    macos)
      if _t3_app >/dev/null; then ok "T3 Code present"; else _t3_install_macos; fi ;;
    linux)
      if ! _t3_has_display; then log "t3code: no display, skipped"; return 0; fi
      if [ -x "$FLEET_BIN/t3code" ]; then ok "T3 Code present"; else _t3_install_linux; fi ;;
  esac
}

# Self-updating app; nothing to do.
tool_t3code_update() { :; }

tool_t3code_status() {
  local app ver rt
  if fleet_in_container; then echo "skipped container"; return 0; fi
  rt=$(_t3_runtimes); rt=${rt:+ runtime:$(printf '%s' "$rt" | tr ' ' ',')}
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
