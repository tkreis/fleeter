# shellcheck shell=bash
# Codex CLI: standalone installer, device-code or API-key login, `codex update`.

_codex_bin() {
  if have codex; then command -v codex; return; fi
  [ -x "$HOME/.local/bin/codex" ] && { echo "$HOME/.local/bin/codex"; return; }
  return 1
}

_codex_logged_in() { "$1" login status >/dev/null 2>&1; }

# Non-interactive login is only possible with an API key; the key travels on stdin.
_codex_login_api_key() { printenv OPENAI_API_KEY | "$1" login --with-api-key >/dev/null 2>&1; }

tool_codex_install() {
  local bin
  if bin=$(_codex_bin); then ok "codex present"
  else
    log "installing Codex CLI"
    curl -fsSL https://chatgpt.com/codex/install.sh | sh || die "Codex install failed" "https://chatgpt.com/codex/install.sh"
    bin=$(_codex_bin) || die "codex not found after install" "ensure $HOME/.local/bin is on PATH"
    ok "codex installed"
  fi
  if [ -n "${OPENAI_API_KEY:-}" ] && ! _codex_logged_in "$bin"; then
    if _codex_login_api_key "$bin"; then ok "codex logged in with API key"; else warn "codex API-key login failed"; fi
  fi
  return 0
}

tool_codex_update() {
  local bin
  bin=$(_codex_bin) || return 0
  "$bin" update || warn "codex update failed"
}

tool_codex_status() {
  local bin ver
  bin=$(_codex_bin) || { echo "missing run: fleet apply"; return 0; }
  ver=$("$bin" --version 2>/dev/null | awk '{print $2}')
  if _codex_logged_in "$bin"; then
    # A short sentence on stderr ("Logged in using ChatGPT"); never a token.
    echo "ok ${ver:-?} $("$bin" login status 2>&1 | head -1 | tr -d '\r')"
  elif [ -n "${OPENAI_API_KEY:-}" ]; then
    echo "login ${ver:-?} OPENAI_API_KEY set; run: fleet login codex"
  else
    echo "login ${ver:-?} run: fleet login codex"
  fi
}

tool_codex_login() {
  local bin
  bin=$(_codex_bin) || die "codex missing" "run: fleet apply"
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    _codex_login_api_key "$bin" && { ok "codex logged in with API key"; return 0; }
    warn "API-key login failed, falling back to device code"
  fi
  "$bin" login --device-auth
}
