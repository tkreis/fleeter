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

tool_t3code_install() {
  if fleet_in_container; then log "t3code: skipped inside container"; return 0; fi
  case "$(fleet_os)" in
    macos) _t3_converge ;;
    linux)
      if ! _t3_has_display; then log "t3code: no display, skipped"; return 0; fi
      _t3_converge ;;
  esac
}

tool_t3code_update() { tool_t3code_install; }

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
