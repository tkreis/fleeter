# shellcheck shell=bash
# devtools: mise (language runtimes), optional pnpm via corepack, optional global
# npm packages, uv, gh, glab, docker, optional registry logins. Runtimes come
# from mise so macOS and Linux behave the same; the pins live in fleet.conf:
#   FLEET_MISE_TOOLS     space-separated mise specs, e.g. "node@24 java@temurin-25" (default node@lts)
#   FLEET_PNPM           pnpm version activated through corepack; empty = skip
#   FLEET_NPM_GLOBALS    space-separated npm packages installed with `npm -g` (mise's node)
#   FLEET_DOCKER_LOGINS  space-separated `host=USER_VAR:TOKEN_VAR`; values come
#                        from the node's environment (fleet secrets), never argv
#
# docker-ce on Linux needs root: `fleet join` installs it (and the docker group)
# and records ~/.config/fleet/privileged_done; here it is only installed when
# FLEET_INTERACTIVE=1 and that marker is absent, otherwise a warn points at join.
# Functions declare their variables local (bash scoping is dynamic).

_dev_bin() {
  if have "$1"; then command -v "$1"; return; fi
  [ -x "$FLEET_BIN/$1" ] && { echo "$FLEET_BIN/$1"; return; }
  return 1
}

_dev_brew() {
  local b
  if have brew; then command -v brew; return; fi
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && { echo "$b"; return; }; done
  return 1
}

# Run a command with the mise-managed runtimes on PATH (global config).
_dev_mx() { local _m; _m=$(_dev_bin mise) || return 1; (cd "$HOME" && "$_m" x -- "$@"); }

# _dev_var NAME — value of the variable NAME (validated name), on stdout.
_dev_var() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || return 1
  eval "printf '%s' \"\${$1:-}\""
}

# ---------- mise + runtimes ----------

_dev_install_mise() {
  _dev_bin mise >/dev/null && return 0
  log "installing mise"
  mkdir -p "$FLEET_BIN"
  curl -fsSL https://mise.run | MISE_INSTALL_PATH="$FLEET_BIN/mise" MISE_QUIET=1 sh \
    || die "mise install failed" "https://mise.run"
}

# Every FLEET_MISE_TOOLS spec installed and active in the global config.
_dev_runtimes_ok() {
  local m spec
  m=$(_dev_bin mise) || return 1
  for spec in ${FLEET_MISE_TOOLS:-}; do
    "$m" where "$spec" >/dev/null 2>&1 || return 1
    [ -n "$(cd "$HOME" && "$m" current "${spec%%@*}" 2>/dev/null)" ] || return 1
  done
  return 0
}

_dev_install_runtimes() {
  local m
  [ -n "${FLEET_MISE_TOOLS:-}" ] || return 0
  _dev_runtimes_ok && return 0
  m=$(_dev_bin mise)
  log "mise use -g $FLEET_MISE_TOOLS"
  # shellcheck disable=SC2086  # intentional word split over mise specs
  (cd "$HOME" && MISE_YES=1 "$m" use -g $FLEET_MISE_TOOLS) || die "mise use failed"
}

_dev_install_pnpm() {
  [ -n "${FLEET_PNPM:-}" ] || return 0
  [ "$(_dev_mx pnpm --version 2>/dev/null)" = "$FLEET_PNPM" ] && return 0
  log "pnpm $FLEET_PNPM via corepack"
  _dev_mx corepack enable || die "corepack enable failed"
  COREPACK_ENABLE_DOWNLOAD_PROMPT=0 _dev_mx corepack prepare "pnpm@$FLEET_PNPM" --activate \
    || die "corepack prepare pnpm@$FLEET_PNPM failed"
}

# Global npm packages, installed where mise's node lives. Checked by binary
# name (last path segment of the package, without a version suffix).
_dev_npm_bin() { local p=${1##*/}; printf '%s\n' "${p%%@*}"; }

_dev_install_npm_globals() {
  local pkg want=""
  [ -n "${FLEET_NPM_GLOBALS:-}" ] || return 0
  for pkg in $FLEET_NPM_GLOBALS; do
    _dev_mx sh -c "command -v '$(_dev_npm_bin "$pkg")'" >/dev/null 2>&1 || want="$want $pkg"
  done
  [ -n "$want" ] || return 0
  log "npm install -g$want"
  # shellcheck disable=SC2086  # intentional word split over package names
  _dev_mx npm install -g --no-fund --no-audit $want >/dev/null || die "npm install -g$want failed"
}

# ---------- uv, gh, glab ----------

_dev_install_uv() {
  _dev_bin uv >/dev/null && return 0
  log "installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR="$FLEET_BIN" INSTALLER_NO_MODIFY_PATH=1 sh \
    || die "uv install failed" "https://docs.astral.sh/uv/"
}

_dev_gh_latest()   { curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))'; }
_dev_glab_latest() { curl -fsSL 'https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/permalink/latest' | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))'; }

# _dev_fetch_bin NAME VERSION URL PATH_IN_TAR — release tarball into $FLEET_BIN, no root.
_dev_fetch_bin() {
  local tmp
  tmp=$(mktemp -d) || die "mktemp failed"
  if curl -fsSL "$3" | tar -xz -C "$tmp" && [ -f "$tmp/$4" ]; then
    mkdir -p "$FLEET_BIN"
    install -m 0755 "$tmp/$4" "$FLEET_BIN/$1"
    rm -rf "$tmp"
  else
    rm -rf "$tmp"; die "$1 $2 download failed" "$3"
  fi
}

_dev_install_gh_linux() {
  local ver arch
  ver=$(_dev_gh_latest) || die "cannot resolve gh release"
  arch=$(fleet_arch)
  log "installing gh $ver"
  _dev_fetch_bin gh "$ver" "https://github.com/cli/cli/releases/download/v${ver}/gh_${ver}_linux_${arch}.tar.gz" "gh_${ver}_linux_${arch}/bin/gh"
}

_dev_install_glab_linux() {
  local ver arch
  ver=$(_dev_glab_latest) || die "cannot resolve glab release"
  arch=$(fleet_arch)
  log "installing glab $ver"
  _dev_fetch_bin glab "$ver" "https://gitlab.com/gitlab-org/cli/-/releases/v${ver}/downloads/glab_${ver}_linux_${arch}.tar.gz" "bin/glab"
}

_dev_install_cli() {
  local brew missing
  if [ "$(fleet_os)" = macos ]; then
    brew=$(_dev_brew) || { warn "brew missing; gh/glab not installed"; return 0; }
    missing=""
    have gh   || missing="$missing gh"
    have glab || missing="$missing glab"
    if [ -n "$missing" ]; then
      log "brew install$missing"
      # shellcheck disable=SC2086
      HOMEBREW_NO_AUTO_UPDATE=1 "$brew" install $missing || die "brew install failed"
    fi
    return 0
  fi
  _dev_bin gh   >/dev/null || _dev_install_gh_linux
  _dev_bin glab >/dev/null || _dev_install_glab_linux
}

# ---------- docker ----------

_dev_install_docker() {
  local brew missing f tmp
  if fleet_in_container; then log "docker: skipped inside container"; return 0; fi
  case "$(fleet_os)" in
    macos)
      if [ -d /Applications/Docker.app ]; then
        ok "Docker Desktop present"
      else
        brew=$(_dev_brew) || { warn "brew missing; docker not installed"; return 0; }
        missing=""
        for f in colima docker docker-compose; do have "$f" || missing="$missing $f"; done
        if [ -n "$missing" ]; then
          log "brew install$missing"
          # shellcheck disable=SC2086
          HOMEBREW_NO_AUTO_UPDATE=1 "$brew" install $missing || die "brew install failed"
        fi
        # brew's docker-compose is a standalone binary; `docker compose` needs the plug-in link.
        mkdir -p "$HOME/.docker/cli-plugins"
        ln -sfn "$("$brew" --prefix)/opt/docker-compose/bin/docker-compose" "$HOME/.docker/cli-plugins/docker-compose"
        if ! colima status >/dev/null 2>&1; then log "colima start"; colima start || warn "colima start failed"; fi
      fi ;;
    linux)
      if ! have docker; then
        if [ -f "$FLEET_HOME/privileged_done" ]; then
          # join ran the privileged steps (docker-ce, docker group) but docker is gone
          warn "docker missing although 'fleet join' installed it; rerun 'fleet join' (interactive, needs root)"
          return 0
        elif [ "${FLEET_INTERACTIVE:-0}" = 1 ]; then
          log "installing docker-ce (get.docker.com)"
          tmp=$(mktemp) || die "mktemp failed"
          if ! curl -fsSL https://get.docker.com -o "$tmp" || ! as_root sh "$tmp"; then
            rm -f "$tmp"; die "docker install failed" "https://get.docker.com"
          fi
          rm -f "$tmp"
          if [ "$(id -u)" -ne 0 ]; then
            as_root usermod -aG docker "$(id -un)" && warn "added to the docker group; log out and in again"
          fi
        else
          warn "docker missing; run 'fleet join' (interactive, needs root)"
          return 0
        fi
      elif [ "${FLEET_INTERACTIVE:-0}" = 1 ] && [ "$(id -u)" -ne 0 ] && [ ! -f "$FLEET_HOME/privileged_done" ] \
           && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        as_root usermod -aG docker "$(id -un)" && warn "added to the docker group; log out and in again"
      fi ;;
  esac
  _dev_docker_logins
}

# docker login for every FLEET_DOCKER_LOGINS entry (`host=USER_VAR:TOKEN_VAR`).
# Re-run every apply: idempotent and picks up a rotated token. The token goes
# to `docker login --password-stdin`, never into argv.
_dev_docker_logins() {
  local entry host vars uvar tvar user
  [ -n "${FLEET_DOCKER_LOGINS:-}" ] || return 0
  have docker || return 0
  for entry in $FLEET_DOCKER_LOGINS; do
    host=${entry%%=*}; vars=${entry#*=}; uvar=${vars%%:*}; tvar=${vars#*:}
    if [ "$vars" = "$entry" ] || [ "$tvar" = "$vars" ] || [ -z "$host" ] || [ -z "$uvar" ] || [ -z "$tvar" ]; then
      warn "FLEET_DOCKER_LOGINS: bad entry '$entry' (want host=USER_VAR:TOKEN_VAR)"; continue
    fi
    if [ -z "$(_dev_var "$tvar")" ]; then log "docker login $host: $tvar not set, skipped"; continue; fi
    user=$(_dev_var "$uvar") || { warn "FLEET_DOCKER_LOGINS: bad variable name '$uvar'"; continue; }
    [ -n "$user" ] || { warn "$uvar unset; skipping docker login $host"; continue; }
    docker info >/dev/null 2>&1 || { warn "docker daemon not reachable; registry login deferred"; return 0; }
    if _dev_var "$tvar" | docker login "$host" -u "$user" --password-stdin >/dev/null 2>&1; then
      ok "docker login $host"
    else
      warn "docker login $host failed"
    fi
  done
}

# ---------- interface ----------

tool_devtools_install() {
  _dev_install_mise
  _dev_install_runtimes
  _dev_install_pnpm
  _dev_install_npm_globals
  _dev_install_uv
  _dev_install_cli
  _dev_install_docker
  ok "devtools converged"
}

tool_devtools_update() {
  local m u brew gh gl cur latest
  if m=$(_dev_bin mise); then "$m" self-update -y >/dev/null 2>&1 || true; fi
  if u=$(_dev_bin uv); then "$u" self update >/dev/null 2>&1 || true; fi
  # shellcheck disable=SC2086  # intentional word split over package names
  [ -z "${FLEET_NPM_GLOBALS:-}" ] || _dev_mx npm update -g --no-fund --no-audit $FLEET_NPM_GLOBALS >/dev/null 2>&1 || true
  if [ "$(fleet_os)" = macos ]; then
    if brew=$(_dev_brew); then
      HOMEBREW_NO_AUTO_UPDATE=1 "$brew" upgrade gh glab colima docker docker-compose >/dev/null 2>&1 || true
    fi
    return 0
  fi
  # Linux: refresh the release tarballs when a newer tag exists.
  if gh=$(_dev_bin gh); then
    cur=$("$gh" --version 2>/dev/null | awk 'NR==1{print $3}'); latest=$(_dev_gh_latest 2>/dev/null)
    [ -n "$latest" ] && [ "$cur" != "$latest" ] && _dev_install_gh_linux
  fi
  if gl=$(_dev_bin glab); then
    cur=$("$gl" --version 2>/dev/null | awk 'NR==1{print $2}'); latest=$(_dev_glab_latest 2>/dev/null)
    [ -n "$latest" ] && [ "$cur" != "$latest" ] && _dev_install_glab_linux
  fi
  return 0
}

tool_devtools_status() {
  local miss="" det="" m spec tool v p pkg c
  if m=$(_dev_bin mise); then
    for spec in ${FLEET_MISE_TOOLS:-}; do
      tool=${spec%%@*}
      v=$(cd "$HOME" && "$m" current "$tool" 2>/dev/null | head -n 1)
      if [ -n "$v" ]; then det="$det $tool=$v"; else miss="$miss $spec"; fi
    done
    if [ -n "${FLEET_PNPM:-}" ]; then
      p=$(_dev_mx pnpm --version 2>/dev/null)
      if [ "$p" = "$FLEET_PNPM" ]; then det="$det pnpm=$p"; else miss="$miss pnpm@$FLEET_PNPM"; fi
    fi
    for pkg in ${FLEET_NPM_GLOBALS:-}; do
      if _dev_mx sh -c "command -v '$(_dev_npm_bin "$pkg")'" >/dev/null 2>&1; then det="$det $(_dev_npm_bin "$pkg")"; else miss="$miss $pkg"; fi
    done
  else
    miss="$miss mise"
  fi
  for c in uv gh glab; do
    if _dev_bin "$c" >/dev/null; then det="$det $c"; else miss="$miss $c"; fi
  done
  if fleet_in_container; then det="$det docker=skipped"
  elif have docker; then
    if docker info >/dev/null 2>&1; then det="$det docker"; else det="$det docker=daemon-down"; fi
  else miss="$miss docker"; fi
  if [ -n "$miss" ]; then echo "missing${miss} (have:${det})"; else echo "ok${det}"; fi
}
