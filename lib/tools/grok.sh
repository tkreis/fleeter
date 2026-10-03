# shellcheck shell=bash
# Grok Build (`grok`): vendor installer into ~/.grok/bin, device-code or XAI_API_KEY.

_grok_bin() {
  if have grok; then command -v grok; return; fi
  [ -x "$HOME/.grok/bin/grok" ] && { echo "$HOME/.grok/bin/grok"; return; }
  return 1
}

tool_grok_install() {
  if _grok_bin >/dev/null; then ok "grok present"; return 0; fi
  log "installing Grok Build"
  curl -fsSL https://x.ai/cli/install.sh | bash || die "Grok Build install failed" "https://x.ai/cli/install.sh"
  _grok_bin >/dev/null || die "grok not found after install" "ensure $HOME/.grok/bin is on PATH"
  ok "grok installed"
}

tool_grok_update() {
  local bin
  bin=$(_grok_bin) || return 0
  "$bin" update || warn "grok update failed"
}

tool_grok_status() {
  local bin ver
  bin=$(_grok_bin) || { echo "missing run: fleet apply"; return 0; }
  ver=$("$bin" --version 2>/dev/null | awk '{print $2}')
  if [ -n "${XAI_API_KEY:-}" ]; then echo "ok ${ver:-?} env-token"
  elif [ -s "$HOME/.grok/auth.json" ]; then echo "ok ${ver:-?} auth.json"
  else echo "login ${ver:-?} run: fleet login grok"; fi
}

tool_grok_login() {
  local bin
  bin=$(_grok_bin) || die "grok missing" "run: fleet apply"
  "$bin" login --device-auth
}
