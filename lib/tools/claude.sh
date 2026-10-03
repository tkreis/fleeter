# shellcheck shell=bash
# Claude Code: native installer, env-token login, self-update via `claude update`.

_claude_bin() {
  if have claude; then command -v claude; return; fi
  [ -x "$HOME/.local/bin/claude" ] && { echo "$HOME/.local/bin/claude"; return; }
  return 1
}

_claude_has_token() {
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ]
}

tool_claude_install() {
  if _claude_bin >/dev/null; then ok "claude present"; return 0; fi
  log "installing Claude Code"
  curl -fsSL https://claude.ai/install.sh | bash || die "Claude Code install failed" "https://claude.ai/install.sh"
  _claude_bin >/dev/null || die "claude not found after install" "ensure $HOME/.local/bin is on PATH"
  ok "claude installed"
}

tool_claude_update() {
  local bin
  bin=$(_claude_bin) || return 0
  "$bin" update || warn "claude update failed"
}

tool_claude_status() {
  local bin ver
  bin=$(_claude_bin) || { echo "missing run: fleet apply"; return 0; }
  ver=$("$bin" --version 2>/dev/null | awk '{print $1}')
  if _claude_has_token; then echo "ok ${ver:-?} env-token"
  else echo "login ${ver:-?} no CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_* in env; run: fleet login claude"; fi
}

# Nodes are meant to get CLAUDE_CODE_OAUTH_TOKEN from the master; this is the
# fallback for a one-off interactive login.
tool_claude_login() {
  local bin
  bin=$(_claude_bin) || die "claude missing" "run: fleet apply"
  log "preferred: on the master run 'claude setup-token' then 'fleet secrets set CLAUDE_CODE_OAUTH_TOKEN'"
  "$bin" auth login
}
