# shellcheck shell=bash
# base: git, git-lfs, curl, jq, ripgrep, tmux, python3, unzip, ca-certificates.
# Linux: apt needs root, so `fleet join` (join_linux_base_packages) installs
# them and records ~/.config/fleet/privileged_done; here they are only
# installed as root or with FLEET_INTERACTIVE=1, otherwise a warn points back
# at join and status says `missing` (never `ok`) until they are there.
# macOS additionally needs Homebrew: `fleet join` installs it (official installer,
# asks for the password); here it is only installed when FLEET_INTERACTIVE=1 and
# that marker is absent.
# Functions declare their variables local (bash scoping is dynamic).

# "<command> <package>" pairs for the current package manager.
_base_items() {
  case "$(fleet_pkg_mgr)" in
    brew)   printf '%s\n' "git git" "git-lfs git-lfs" "curl curl" "jq jq" "rg ripgrep" "tmux tmux" "python3 python" ;;
    pacman) printf '%s\n' "git git" "git-lfs git-lfs" "curl curl" "jq jq" "rg ripgrep" "tmux tmux" "python3 python" "unzip unzip" ;;
    *)      printf '%s\n' "git git" "git-lfs git-lfs" "curl curl" "jq jq" "rg ripgrep" "tmux tmux" "python3 python3" "unzip unzip" ;;
  esac
}

_base_brew() {
  local b
  if have brew; then command -v brew; return; fi
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && { echo "$b"; return; }; done
  return 1
}

# Packages whose command is absent (plus ca-certificates on Linux), space separated.
_base_missing() {
  local cmd pkg m=""
  while read -r cmd pkg; do have "$cmd" || m="$m $pkg"; done <<EOF
$(_base_items)
EOF
  if [ "$(fleet_os)" = linux ] && [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then m="$m ca-certificates"; fi
  printf '%s\n' "${m# }"
}

# Root can install directly; a user needs sudo, which only join may use.
_base_may_root() { [ "$(id -u)" -eq 0 ] || [ "${FLEET_INTERACTIVE:-0}" = 1 ]; }

tool_base_install() {
  local brew missing mgr
  if [ "$(fleet_os)" = macos ]; then
    brew=$(_base_brew) || {
      if [ -f "$FLEET_HOME/privileged_done" ]; then
        warn "Homebrew missing although 'fleet join' installed it; rerun 'fleet join' or install from https://brew.sh"
        return 0
      elif [ "${FLEET_INTERACTIVE:-0}" = 1 ]; then
        log "installing Homebrew"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
          || die "Homebrew install failed" "https://brew.sh"
        brew=$(_base_brew) || die "brew not found after install"
      else
        warn "Homebrew missing; run 'fleet join' (interactive) or install from https://brew.sh"
        return 0
      fi
    }
    missing=$(_base_missing)
    if [ -n "$missing" ]; then
      log "brew install $missing"
      # shellcheck disable=SC2086  # intentional word split
      HOMEBREW_NO_AUTO_UPDATE=1 "$brew" install $missing || die "brew install failed"
    fi
    ok "base packages present"
    return 0
  fi

  missing=$(_base_missing)
  if [ -z "$missing" ]; then ok "base packages present"; return 0; fi
  if ! _base_may_root; then
    if [ -f "$FLEET_HOME/privileged_done" ]; then
      warn "missing packages ($missing) although 'fleet join' installed them; rerun 'fleet join' (interactive, needs root)"
    else
      warn "missing packages ($missing); needs root: run 'fleet join' (interactive) or install them"
    fi
    return 0
  fi
  mgr=$(fleet_pkg_mgr)
  log "installing $missing via $mgr"
  # shellcheck disable=SC2086  # intentional word split
  case "$mgr" in
    apt-get) as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
             as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $missing ;;
    dnf)     as_root dnf install -y -q $missing ;;
    apk)     as_root apk add --no-cache $missing ;;
    pacman)  as_root pacman -Sy --noconfirm --needed $missing ;;
    *)       die "no supported package manager" "install: $missing" ;;
  esac || die "package install failed"
  have git-lfs && git lfs install --skip-repo >/dev/null 2>&1
  ok "base packages installed"
}

tool_base_update() {
  local brew pkgs
  if [ "$(fleet_os)" = macos ]; then
    brew=$(_base_brew) || return 0
    pkgs=$(_base_items | while read -r _ pkg; do printf '%s ' "$pkg"; done)
    # shellcheck disable=SC2086
    HOMEBREW_NO_AUTO_UPDATE=1 "$brew" upgrade $pkgs >/dev/null 2>&1 || true
    return 0
  fi
  _base_may_root || return 0
  case "$(fleet_pkg_mgr)" in
    apt-get) as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
             as_root env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq ;;
    *) ;;  # only Debian/Docker nodes are updated unattended
  esac
}

# `missing <packages>` whenever anything is absent; `ok` only when all are there.
tool_base_status() {
  local missing
  missing=$(_base_missing)
  if [ "$(fleet_os)" = macos ] && ! _base_brew >/dev/null; then missing="${missing:+$missing }brew"; fi
  if [ -n "$missing" ]; then echo "missing $missing"; return 0; fi
  echo "ok git $(git --version 2>/dev/null | awk '{print $3}') python3 $(python3 --version 2>/dev/null | awk '{print $2}')"
}
