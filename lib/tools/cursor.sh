# shellcheck shell=bash
# Cursor CLI (cursor-agent): installer, CURSOR_API_KEY or browser login, self-updater.

# The installer links both `cursor-agent` and `agent`. `agent` is ambiguous
# (Grok Build ships one too), so it only counts when it points at cursor-agent.
_cursor_bin() {
  local a
  if have cursor-agent; then command -v cursor-agent; return; fi
  [ -x "$HOME/.local/bin/cursor-agent" ] && { echo "$HOME/.local/bin/cursor-agent"; return; }
  a="$HOME/.local/bin/agent"
  if [ -L "$a" ]; then
    case "$(readlink "$a")" in *cursor-agent*) echo "$a"; return ;; esac
  fi
  return 1
}

tool_cursor_install() {
  if _cursor_bin >/dev/null; then ok "cursor-agent present"; return 0; fi
  log "installing Cursor CLI"
  curl https://cursor.com/install -fsS | bash || die "Cursor CLI install failed" "https://cursor.com/install"
  _cursor_bin >/dev/null || die "cursor-agent not found after install" "ensure $HOME/.local/bin is on PATH"
  ok "cursor-agent installed"
}

tool_cursor_update() {
  local bin
  bin=$(_cursor_bin) || return 0
  "$bin" update || warn "cursor-agent update failed"
}

tool_cursor_status() {
  local bin ver st
  bin=$(_cursor_bin) || { echo "missing run: fleet apply"; return 0; }
  ver=$("$bin" --version 2>/dev/null | head -1)
  if [ -n "${CURSOR_API_KEY:-}" ]; then echo "ok ${ver:-?} env-token"; return 0; fi
  st=$("$bin" status 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^[[:space:]]*$' | head -1 | tr -d '\r')
  case "$st" in
    "Logged in"*) echo "ok ${ver:-?} $st" ;;
    *keychain*)   echo "login ${ver:-?} macOS keychain is locked in this session (ssh/launchd); on the master: fleet secrets set CURSOR_API_KEY --profile minimal" ;;
    "")           echo "error ${ver:-?} status unavailable" ;;
    *)            echo "login ${ver:-?} run: fleet login cursor" ;;
  esac
}

tool_cursor_login() {
  local bin
  bin=$(_cursor_bin) || die "cursor-agent missing" "run: fleet apply"
  log "preferred: set CURSOR_API_KEY via 'fleet secrets set CURSOR_API_KEY'"
  NO_OPEN_BROWSER=1 "$bin" login
}
