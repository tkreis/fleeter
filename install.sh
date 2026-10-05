#!/usr/bin/env bash
# fleeter installer.
#
#   curl -fsSL https://tkreis.github.io/fleeter/install.sh | bash
#
# Clones (or updates) fleeter into ~/.local/share/fleeter and links
# ~/.local/bin/fleet and ~/.local/bin/fleeter to it. No sudo, nothing else on
# the system changes. Safe to run again: it updates an existing install.
#
# Settings (environment variables):
#   FLEETER_DIR   install directory   (default ~/.local/share/fleeter)
#   FLEETER_BIN   link directory      (default ~/.local/bin)
#   FLEETER_REPO  git URL             (default https://github.com/tkreis/fleeter.git)
#   FLEETER_REF   branch or tag       (default main)
#   FLEETER_SETUP=1  run `fleet setup` right after installing. The script's stdin
#                 is the curl pipe, so setup reads from the terminal (/dev/tty);
#                 without one it prints the command to run instead.
#                 (FLEETER_TTY names the terminal device; tests point it elsewhere.)
#
# Everything runs inside main(), so a download cut off halfway executes nothing.
set -eu

main() {
  local dir=${FLEETER_DIR:-$HOME/.local/share/fleeter}
  local bin=${FLEETER_BIN:-$HOME/.local/bin}
  local repo=${FLEETER_REPO:-https://github.com/tkreis/fleeter.git}
  local ref=${FLEETER_REF:-main}
  local tty=${FLEETER_TTY:-/dev/tty}
  local c

  say() { printf '==> %s\n' "$*"; }
  die() { printf 'error: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '  next: %s\n' "$2" >&2; exit 1; }

  case "$(uname -s)" in Darwin|Linux) ;; *) die "fleeter runs on macOS and Linux" ;; esac
  [ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root" "fleeter installs into your home directory"
  for c in git python3 curl ssh; do
    command -v "$c" >/dev/null 2>&1 || die "missing command: $c" \
      "macOS: xcode-select --install   Debian/Ubuntu: sudo apt-get install -y git python3 curl openssh-client"
  done

  if [ -d "$dir/.git" ]; then
    say "updating $dir"
    git -C "$dir" fetch --quiet --tags origin "$ref" || die "git fetch failed" "check your network, then rerun"
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
      die "$dir has local changes; not touching it" "commit or discard them, then rerun"
    fi
    git -C "$dir" checkout --quiet "$ref"
    if git -C "$dir" symbolic-ref -q HEAD >/dev/null 2>&1; then
      git -C "$dir" merge --quiet --ff-only "origin/$ref" || die "cannot fast-forward $dir to origin/$ref" "resolve it by hand"
    fi
  elif [ -e "$dir" ]; then
    die "$dir exists but is not a fleeter checkout" "move it away or set FLEETER_DIR"
  else
    say "installing fleeter into $dir"
    mkdir -p "$(dirname "$dir")"
    git clone --quiet --branch "$ref" "$repo" "$dir" || die "git clone failed: $repo ($ref)"
  fi

  mkdir -p "$bin"
  for c in fleet fleeter; do
    if [ -e "$bin/$c" ] && [ ! -L "$bin/$c" ]; then
      die "$bin/$c exists and is not a link; not overwriting it" "remove it or set FLEETER_BIN"
    fi
    ln -sfn "$dir/fleet" "$bin/$c"
  done
  say "linked $bin/fleet and $bin/fleeter -> $dir/fleet ($(git -C "$dir" rev-parse --short HEAD))"

  case ":$PATH:" in
    *":$bin:"*) ;;
    *)
      printf '\n%s is not on your PATH. Add it (zsh shown; use ~/.bashrc for bash):\n' "$bin"
      # shellcheck disable=SC2016  # the user's shell must expand $PATH, not ours
      printf '  echo '\''export PATH="%s:$PATH"'\'' >> ~/.zshrc && export PATH="%s:$PATH"\n' "$bin" "$bin"
      ;;
  esac

  if [ "${FLEETER_SETUP:-0}" = 1 ]; then
    if { : <"$tty"; } 2>/dev/null; then
      say "running fleet setup (reading from your terminal)"
      "$dir/fleet" setup <"$tty"
      return 0
    fi
    say "no terminal to ask you questions on (FLEETER_SETUP=1 needs one); run it yourself: fleet setup"
  fi

  printf '\nNext: run fleet setup (makes this machine the master: config repo, Tailscale, GitHub, the first secret),\n'
  printf '      or paste https://tkreis.github.io/fleeter/SETUP.md into your coding agent and let it drive.\n'
  printf '  fleet setup\n'
  printf '  fleet --help\n'
}

main "$@"
