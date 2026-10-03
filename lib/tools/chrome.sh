# shellcheck shell=bash
# chrome: a real browser for agents plus the two browser MCP servers
# (chrome-devtools-mcp, @playwright/mcp) pinned in fleet.conf
# (FLEET_CHROME_DEVTOOLS_MCP, FLEET_PLAYWRIGHT_MCP), installed with `npm -g`
# through the mise-managed node (devtools) — never `npx @latest` at launch.
#
# Browser per platform:
#   macOS          brew install --cask google-chrome, unless /Applications/Google Chrome.app exists
#   Debian amd64   Google's apt repo (signed-by keyring) -> google-chrome-stable; root or FLEET_INTERACTIVE=1
#   Debian arm64   chromium (no Linux Chrome build for arm64); root or FLEET_INTERACTIVE=1
#   containers     chromium from the image (docker/Dockerfile installs it as root at build)
#
# The harness templates (harness/{claude,cursor}/mcp.json, codex/config.toml in
# the config repo) should not call the npm binaries directly but the wrappers written here:
#   ~/.local/bin/fleet-chrome-mcp        -> chrome-devtools-mcp
#   ~/.local/bin/fleet-playwright-mcp    -> playwright-mcp
# Each wrapper decides at launch time: headless when there is no display on
# Linux (no $DISPLAY/$WAYLAND_DISPLAY) or FLEET_HEADLESS=1 anywhere; the browser
# binary for this machine; a fleet-owned profile under ~/.cache/fleet/chrome-profile
# (never the owner's Chrome profile); --no-sandbox inside containers.
# Functions declare their variables local (bash scoping is dynamic).

CHROME_MAC_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
CHROME_LINUX_BINS="google-chrome-stable google-chrome chromium chromium-browser"

_chrome_brew() {
  local b
  if have brew; then command -v brew; return; fi
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && { echo "$b"; return; }; done
  return 1
}

# Path of the browser binary on this machine, or non-zero.
_chrome_browser() {
  local c
  if [ "$(fleet_os)" = macos ]; then
    [ -x "$CHROME_MAC_BIN" ] && { echo "$CHROME_MAC_BIN"; return 0; }
    return 1
  fi
  for c in $CHROME_LINUX_BINS; do
    if have "$c"; then command -v "$c"; return 0; fi
  done
  return 1
}

# "Google Chrome 1xx.0.x.y" / "Chromium 1xx.0.x.y built on Debian ..." -> first dotted number.
_chrome_browser_version() {
  local b
  b=$(_chrome_browser) || return 1
  "$b" --version 2>/dev/null | awk 'NR==1 { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+/) { print $i; exit } }'
}

# Root can apt-get directly; a user needs sudo, which only join (interactive) may use.
_chrome_may_root() { [ "$(id -u)" -eq 0 ] || [ "${FLEET_INTERACTIVE:-0}" = 1 ]; }

# ---------- browser ----------

_chrome_install_macos() {
  local brew
  [ -x "$CHROME_MAC_BIN" ] && return 0
  brew=$(_chrome_brew) || { warn "Homebrew missing; Google Chrome not installed (run 'fleet join' or install from https://brew.sh)"; return 0; }
  log "brew install --cask google-chrome"
  HOMEBREW_NO_AUTO_UPDATE=1 "$brew" install --cask google-chrome || die "brew install --cask google-chrome failed"
  [ -x "$CHROME_MAC_BIN" ] || die "Google Chrome.app not found after install"
}

_chrome_install_linux() {
  local tmp
  _chrome_browser >/dev/null && return 0
  if ! _chrome_may_root; then
    if fleet_in_container; then warn "chromium missing; apt needs root: the image installs it (docker/Dockerfile), rebuild it"
    elif [ -f "$FLEET_HOME/privileged_done" ]; then warn "chrome missing although 'fleet join' installed it; rerun 'fleet join' (interactive, needs root)"
    else warn "chrome missing; apt needs root: rerun 'fleet join' (interactive)"; fi
    return 0
  fi
  [ "$(fleet_pkg_mgr)" = apt-get ] || { warn "chrome: only apt-based Linux is automated; install google-chrome-stable or chromium yourself"; return 0; }
  export DEBIAN_FRONTEND=noninteractive
  if [ "$(fleet_arch)" = amd64 ] && ! fleet_in_container; then
    log "installing google-chrome-stable from Google's apt repo"
    as_root apt-get update -qq
    as_root apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg >/dev/null || die "apt-get install gnupg failed"
    tmp=$(mktemp) || die "mktemp failed"
    if ! curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor >"$tmp" 2>/dev/null; then
      rm -f "$tmp"; die "could not fetch Google's apt signing key" "https://www.google.com/linuxrepositories/"
    fi
    as_root install -m 0644 "$tmp" /usr/share/keyrings/google-chrome.gpg; rm -f "$tmp"
    printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main\n' \
      | as_root tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
    as_root apt-get update -qq
    as_root apt-get install -y -qq --no-install-recommends google-chrome-stable >/dev/null || die "google-chrome-stable install failed"
  else
    log "installing chromium (apt; $(fleet_arch)$(fleet_in_container && echo ', container'))"
    as_root apt-get update -qq
    as_root apt-get install -y -qq --no-install-recommends chromium >/dev/null || die "chromium install failed"
  fi
  _chrome_browser >/dev/null || die "no chrome/chromium binary after install"
}

# ---------- MCP servers (npm -g, pinned) ----------

_chrome_mise() {
  if have mise; then command -v mise; return; fi
  [ -x "$FLEET_BIN/mise" ] && { echo "$FLEET_BIN/mise"; return; }
  return 1
}

# _chrome_run CMD... — with mise's global node on PATH when mise is installed
# (devtools), otherwise whatever node/npm is on PATH.
_chrome_run() {
  local m
  if m=$(_chrome_mise); then (cd "$HOME" && "$m" x -- "$@"); else "$@"; fi
}

# Installed version of a global npm package, or non-zero.
_chrome_pkg_ver() {
  local root
  root=$(_chrome_run npm root -g 2>/dev/null) || return 1
  [ -f "$root/$1/package.json" ] || return 1
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$root/$1/package.json" | head -n 1
}

_chrome_install_mcp() {
  local want m
  if ! _chrome_run npm --version >/dev/null 2>&1; then
    warn "npm not available (devtools installs node via mise); browser MCP servers not installed"
    return 0
  fi
  want=""
  [ "$(_chrome_pkg_ver chrome-devtools-mcp)" = "$FLEET_CHROME_DEVTOOLS_MCP" ] || want="$want chrome-devtools-mcp@$FLEET_CHROME_DEVTOOLS_MCP"
  [ "$(_chrome_pkg_ver @playwright/mcp)" = "$FLEET_PLAYWRIGHT_MCP" ] || want="$want @playwright/mcp@$FLEET_PLAYWRIGHT_MCP"
  [ -n "$want" ] || return 0
  log "npm install -g$want"
  # shellcheck disable=SC2086  # intentional word split
  _chrome_run npm install -g --no-fund --no-audit $want >/dev/null || die "npm install -g$want failed"
  if m=$(_chrome_mise); then "$m" reshim >/dev/null 2>&1 || true; fi
}

# ---------- launch wrappers ----------

# _chrome_wrapper devtools|playwright — prints the wrapper script.
_chrome_wrapper() {
  printf '%s\n' '#!/usr/bin/env bash' \
    '# generated by fleet apply (lib/tools/chrome.sh); fleet owns this file — do not edit.' \
    '# Starts the browser MCP server with a fleet-owned Chrome profile, the browser' \
    '# binary of this machine, and headless when there is no display.' \
    '#   FLEET_HEADLESS=1 forces headless, FLEET_HEADLESS=0 forces headed;' \
    '#   otherwise Linux is headless without DISPLAY/WAYLAND_DISPLAY, macOS is headed.' \
    'set -eu' \
    "KIND=$1"
  cat <<'EOF'
PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH
profile="${FLEET_CHROME_PROFILE:-$HOME/.cache/fleet/chrome-profile}/$KIND"
mkdir -p "$profile"
os=$(uname -s)
headless=0
case "${FLEET_HEADLESS:-}" in
  1) headless=1 ;;
  0) headless=0 ;;
  *) if [ "$os" != Darwin ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then headless=1; fi ;;
esac
browser=""
if [ "$os" = Darwin ]; then
  [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ] && browser="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
else
  for c in google-chrome-stable google-chrome chromium chromium-browser; do
    if command -v "$c" >/dev/null 2>&1; then browser=$(command -v "$c"); break; fi
  done
fi
container=0
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ -n "${FLEET_CONTAINER:-}" ]; then container=1; fi
case "$KIND" in
  devtools)
    bin=chrome-devtools-mcp
    set -- --user-data-dir="$profile" "$@"
    [ "$headless" -eq 1 ] && set -- --headless "$@"
    [ -n "$browser" ] && set -- --executable-path="$browser" "$@"
    [ "$container" -eq 1 ] && set -- --chrome-arg=--no-sandbox --chrome-arg=--disable-setuid-sandbox "$@"
    ;;
  playwright)
    bin=playwright-mcp
    set -- --user-data-dir "$profile" "$@"
    [ "$headless" -eq 1 ] && set -- --headless "$@"
    [ -n "$browser" ] && set -- --executable-path "$browser" "$@"
    [ "$container" -eq 1 ] && set -- --no-sandbox "$@"
    ;;
esac
if command -v "$bin" >/dev/null 2>&1; then exec "$bin" "$@"; fi
if command -v mise >/dev/null 2>&1; then
  real=$(cd "$HOME" && mise which "$bin" 2>/dev/null || true)
  [ -n "$real" ] && exec "$real" "$@"
fi
echo "fleet: $bin is not installed (run: fleet apply)" >&2
exit 127
EOF
}

_chrome_write_wrapper() {   # _chrome_write_wrapper KIND DEST
  local tmp
  tmp=$(mktemp) || die "mktemp failed"
  _chrome_wrapper "$1" >"$tmp"
  if [ -f "$2" ] && cmp -s "$tmp" "$2"; then rm -f "$tmp"; return 0; fi
  atomic_write "$2" 0755 <"$tmp"
  rm -f "$tmp"
  ok "wrote $2"
}

_chrome_write_wrappers() {
  mkdir -p "$FLEET_BIN"
  _chrome_write_wrapper devtools "$FLEET_BIN/fleet-chrome-mcp"
  _chrome_write_wrapper playwright "$FLEET_BIN/fleet-playwright-mcp"
}

# ---------- interface ----------

tool_chrome_install() {
  if [ "$(fleet_os)" = macos ]; then _chrome_install_macos; else _chrome_install_linux; fi
  _chrome_install_mcp
  _chrome_write_wrappers
  ok "chrome converged"
}

tool_chrome_update() {
  local brew
  if [ "$(fleet_os)" = macos ] && [ -x "$CHROME_MAC_BIN" ]; then
    if brew=$(_chrome_brew); then HOMEBREW_NO_AUTO_UPDATE=1 "$brew" upgrade --cask google-chrome >/dev/null 2>&1 || true; fi
  fi
  # Linux: the browser follows apt (base update, root). MCP servers: bump to the pins.
  _chrome_install_mcp
  _chrome_write_wrappers
  return 0
}

tool_chrome_status() {
  local miss="" det="" v
  if v=$(_chrome_browser_version) && [ -n "$v" ]; then
    det="$det chrome=$v"
  elif fleet_in_container; then miss="$miss chromium(image)"
  else miss="$miss chrome"; fi
  v=$(_chrome_pkg_ver chrome-devtools-mcp 2>/dev/null || true)
  if [ "$v" = "$FLEET_CHROME_DEVTOOLS_MCP" ]; then det="$det devtools-mcp=$v"
  elif [ -n "$v" ]; then det="$det devtools-mcp=$v(pin:$FLEET_CHROME_DEVTOOLS_MCP)"
  else miss="$miss chrome-devtools-mcp"; fi
  v=$(_chrome_pkg_ver @playwright/mcp 2>/dev/null || true)
  if [ "$v" = "$FLEET_PLAYWRIGHT_MCP" ]; then det="$det playwright-mcp=$v"
  elif [ -n "$v" ]; then det="$det playwright-mcp=$v(pin:$FLEET_PLAYWRIGHT_MCP)"
  else miss="$miss playwright-mcp"; fi
  [ -x "$FLEET_BIN/fleet-chrome-mcp" ] && [ -x "$FLEET_BIN/fleet-playwright-mcp" ] || miss="$miss wrappers"
  if [ -n "$miss" ]; then echo "missing${miss}${det:+ (have:$det)}"; else echo "ok${det}"; fi
}
