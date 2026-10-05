# shellcheck shell=bash
# lib/setup.sh — `fleet setup`: the guided first-time setup of a master.
# Sourced by ./fleet; functions only.
#
# One command instead of the hand steps of the old Quickstart. It asks a few
# questions (every answer is also a flag; --yes takes the defaults), then:
#   1 preflight            same checks as init master, plus a gh login when needed
#   2 GitHub owner         gh api user, confirmed
#   3 config repo          clone <owner>/<name> when it exists, else start it from
#                          examples/fleet-config, render fleet.conf, commit, create + push
#   4 memory repo          create <owner>/fleet-memory (private, empty) when wanted
#   5 fleet init master    its own prompts: the Tailscale token and the typed `apply`
#   6 Claude login         claude setup-token | … | fleet secrets set (a pipe, never shown)
#   7 proxy                fleet proxy import when CLIProxyAPI is used here
#   8 publish + doctor     fleet config publish --yes, fleet doctor
#   9 next steps           invite, spawn.sh, list
# Idempotent and resumable: a finished step is reported as `skip`. Nothing is
# created on GitHub without a confirmation, or --yes.
#
# Portability: bash 3.2, no GNU-only flags, no sed -i, every function declares
# its locals. Secrets never touch argv, files or output: the Claude token goes
# from `claude setup-token` through a pipe into cmd_secrets_set.

SETUP_STEPS=9
SETUP_YES=0

# ---------- prompts ----------

setup_step() { log "[$1/$SETUP_STEPS] $2"; }

# setup_skip MESSAGE — a step that is already done.
setup_skip() { if _fleet_tty; then printf '\033[1;36mskip\033[0m %s\n' "$*" >&2; else printf 'skip %s\n' "$*" >&2; fi; }

# setup_ask VAR PROMPT DEFAULT — the default with --yes, on an empty answer or
# on EOF; otherwise what the user typed.
setup_ask() {
  local _var=$1 _prompt=$2 _def=$3 _ans=""
  if [ "$SETUP_YES" = 1 ]; then eval "$_var=\$_def"; return 0; fi
  printf '%s [%s]: ' "$_prompt" "$_def" >&2
  IFS= read -r _ans || _ans=""
  [ -n "$_ans" ] || _ans=$_def
  eval "$_var=\$_ans"
}

# setup_yn PROMPT DEFAULT(y|n) — true for yes; the default with --yes, an empty
# answer or EOF.
setup_yn() {
  local def=$2 ans="" hint="y/N"
  if [ "$SETUP_YES" = 1 ]; then [ "$def" = y ]; return; fi
  [ "$def" = y ] && hint="Y/n"
  printf '%s [%s]: ' "$1" "$hint" >&2
  IFS= read -r ans || ans=""
  [ -n "$ans" ] || ans=$def
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# setup_confirm WHAT — before anything that creates something on GitHub: true
# with --yes or an explicit yes (Enter counts as yes); EOF counts as no.
setup_confirm() {
  local ans=""
  [ "$SETUP_YES" = 1 ] && return 0
  printf '%s [Y/n] ' "$1" >&2
  IFS= read -r ans || { printf '\n' >&2; return 1; }
  case "${ans:-y}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------- answers -> values ----------

# setup_tools_resolve PRESET|LIST — the FLEET_TOOLS value; dies on an unknown tool.
setup_tools_resolve() {
  local spec=$1 t known
  case "$spec" in
    minimal) echo "base devtools claude" ;;
    agents)  echo "base devtools claude codex cursor chrome" ;;
    full)    echo "base devtools claude codex cursor chrome grok cliproxy t3code" ;;
    "")      die "--tools needs a value" "minimal | agents | full | \"a space separated list\"" ;;
    *)
      known=""
      for t in "$(fleet_tools_dir)"/*.sh; do t=${t##*/}; known="$known ${t%.sh}"; done
      for t in $spec; do
        [ -f "$(fleet_tools_dir)/$t.sh" ] || die "unknown tool: $t" "--tools minimal|agents|full, or a list of: $known"
      done
      echo "$spec" ;;
  esac
}

# setup_tools_with_proxy TOOLS 1|0 — `cliproxy` in the list exactly when the
# proxy was chosen (the proxy is on for a node iff cliproxy is in FLEET_TOOLS).
setup_tools_with_proxy() {
  local tools=$1 want=$2 out="" t has=0
  for t in $tools; do
    if [ "$t" = cliproxy ]; then has=1; [ "$want" = 1 ] || continue; fi
    out="$out $t"
  done
  [ "$want" = 1 ] && [ "$has" = 0 ] && out="$out cliproxy"
  printf '%s\n' "${out# }"
}

# setup_conf_render FILE KEY VALUE — set KEY="VALUE" in a fleet.conf copied from
# the example, keeping the trailing comment of the line; appended when missing.
setup_conf_render() {
  local f=$1
  awk -v k="$2" -v v="$3" '
    index($0, k "=") == 1 { c = ""; i = index($0, "  #"); if (i > 0) c = substr($0, i); print k "=\"" v "\"" c; done = 1; next }
    { print }
    END { if (!done) print k "=\"" v "\"" }' "$f" | atomic_write "$f" 0644
}

# setup_code_repo OWNER — the FLEET_CODE_REPO for the nodes: the origin of this
# checkout (the installer's clone, or your fork). An ssh URL of a repo OWNER
# does not own becomes https (public, no deploy key to register there).
setup_code_repo() {
  local url slug
  url=$(git -C "$FLEET_ROOT" remote get-url origin 2>/dev/null || true)
  [ -n "$url" ] || url="https://github.com/tkreis/fleeter.git"
  slug=$(repo_slug "$url")
  case "$url" in
    git@github.com:*|ssh://git@github.com/*) case "$slug" in "$1"/*) ;; *) url="https://github.com/$slug.git" ;; esac ;;
  esac
  printf '%s\n' "$url"
}

# setup_dir_abs DIR — ~ expanded, the parent created and resolved physically
# (the form init master records).
setup_dir_abs() {
  local d=$1
  # shellcheck disable=SC2088  # a literal ~ typed at the prompt is expanded here
  case "$d" in "~") d=$HOME ;; "~/"*) d="$HOME/${d#\~/}" ;; esac
  mkdir -p "$(dirname "$d")" || die "cannot create the parent directory of $d" "pass another --config-dir DIR"
  (cd "$(dirname "$d")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$d")")
}

# ---------- steps ----------

# setup_gh_login — the GitHub CLI logged in (setup creates repos through it).
setup_gh_login() {
  if gh_cli; then ok "github: gh logged in as $(gh_login)"; return 0; fi
  [ -z "${FLEET_GH_API:-}" ] || die "fleet setup needs the GitHub CLI, not a token (FLEET_GH_API is set)" "unset FLEET_GH_API, or set the master up by hand: fleet init master --config-dir DIR"
  gh_try_install || die "fleet setup needs the GitHub CLI (gh)" "install it (https://github.com/cli/cli#installation), run: gh auth login -h github.com --web, then rerun: fleet setup"
  log "GitHub: gh is installed but not logged in"
  setup_yn "Log in now (gh auth login --web: one browser approval)?" y \
    || die "GitHub login needed" "run: gh auth login -h github.com --web, then rerun: fleet setup"
  gh auth login -h github.com --web --git-protocol ssh || die "gh auth login failed" "retry: gh auth login -h github.com --web"
  _GH_CLI=""
  gh_cli || die "gh is still not logged in" "run: gh auth login -h github.com --web, then rerun: fleet setup"
  ok "github: gh logged in as $(gh_login)"
}

# setup_config_repo OWNER NAME DIR TOOLS MEMORY_URL KEEP_AWAKE PROXY — the
# config repo checkout in DIR: reused, cloned, or started from the example.
setup_config_repo() {
  local owner=$1 name=$2 dir=$3 tools=$4 mem=$5 awake=$6 proxy=$7 slug origin
  slug="$owner/$name"
  if [ -d "$dir/.git" ]; then
    origin=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
    case "$origin" in
      *"/$slug"|*"/$slug.git"|*":$slug"|*":$slug.git") setup_skip "config repo: $dir is a checkout of $slug"; return 0 ;;
      "") die "$dir is a git checkout without an origin remote" "git -C $dir remote add origin git@github.com:$slug.git, or pass another --config-dir DIR" ;;
      *)  die "$dir is a checkout of $origin, not of $slug" "pass --config-dir DIR (another directory) or --config-repo NAME (the repo it belongs to)" ;;
    esac
  fi
  [ -e "$dir" ] && die "$dir exists but is not a git checkout" "move it away, or pass --config-dir DIR"
  mkdir -p "$(dirname "$dir")"
  if gh repo view "$slug" >/dev/null 2>&1; then
    log "config repo: $slug exists on GitHub; cloning it into $dir"
    GIT_TERMINAL_PROMPT=0 gh repo clone "$slug" "$dir" -- --quiet \
      || die "could not clone $slug" "check your access (gh repo view $slug) and your ssh key for GitHub, then rerun: fleet setup"
    ok "config repo: cloned $slug into $dir"
    [ -f "$dir/fleet.conf" ] || warn "$dir has no fleet.conf; start from $FLEET_ROOT/examples/fleet-config/fleet.conf"
    return 0
  fi
  log "config repo: $slug does not exist on GitHub; starting it from examples/fleet-config"
  cp -R "$FLEET_ROOT/examples/fleet-config" "$dir"
  setup_conf_render "$dir/fleet.conf" FLEET_CODE_REPO "$(setup_code_repo "$owner")"
  setup_conf_render "$dir/fleet.conf" FLEET_CONFIG_REPO "git@github.com:$slug.git"
  setup_conf_render "$dir/fleet.conf" FLEET_MEMORY_REPO "$mem"
  setup_conf_render "$dir/fleet.conf" FLEET_TOOLS "$tools"
  setup_conf_render "$dir/fleet.conf" FLEET_KEEP_AWAKE "$awake"
  [ "$proxy" = 1 ] && setup_conf_render "$dir/fleet.conf" FLEET_PROXY_MODE local
  git -C "$dir" -c init.defaultBranch=main init -q
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "start fleet config"
  ok "config repo: $dir (fleet.conf rendered: tools \"$tools\", memory ${mem:-off}, keep awake $awake; committed)"
  setup_confirm "Create the private GitHub repo $slug and push $dir there?" \
    || die "stopped: $slug not created ($dir is kept)" "rerun fleet setup, or create it yourself: gh repo create $slug --private --source $dir --push"
  gh repo create "$slug" --private --source "$dir" --push >/dev/null \
    || die "gh repo create $slug failed" "create it by hand: gh repo create $slug --private --source $dir --push; then rerun: fleet setup"
  ok "config repo: created private $slug and pushed"
  audit "setup.config-repo" "-" "created $slug"
}

# setup_memory_repo SLUG — the shared memory repo: private, may stay empty
# (the master seeds it on its first reconcile).
setup_memory_repo() {
  if gh repo view "$1" >/dev/null 2>&1; then setup_skip "memory repo: $1 exists"; return 0; fi
  if setup_confirm "Create the private GitHub repo $1 for the shared memory vault (empty; the master seeds it)?"; then
    gh repo create "$1" --private >/dev/null || die "gh repo create $1 failed" "create it by hand (gh repo create $1 --private), then rerun: fleet setup"
    ok "memory repo: created private $1"
    audit "setup.memory-repo" "-" "created $1"
  else
    warn "memory repo $1 not created; fleet.conf points at it, so create it before adding nodes (or set FLEET_MEMORY_REPO=\"\")"
  fi
}

# setup_init_done DIR — init master already ran for this config dir.
setup_init_done() {
  [ -d "$FLEET_VAULT/nodes" ] && vault_has "$FLEET_VAULT/tailscale.json" && [ -f "$(master_key)" ] \
    && [ -f "$(master_schedule_file reconcile)" ] && [ "$FLEET_CONFIG_DIR" = "$1" ]
}

# setup_token_filter — stdin: what `claude setup-token` printed; stdout: the
# token alone (colour codes stripped; the last sk-ant-oat word, else the last
# word of the last non-empty line). Prints nothing when there was nothing.
setup_token_filter() {
  awk '{ gsub(/\033\[[0-9;]*[A-Za-z]/, ""); gsub(/\r/, "") }
       NF { last = $NF }
       /sk-ant-oat/ { tok = $NF }
       END { if (tok == "") tok = last; if (tok != "") print tok }'
}

# setup_claude_token WANT — 1: run `claude setup-token` and pipe the token
# into the vault; 0: skip; "": ask (default yes on a terminal).
setup_claude_token() {
  local want=$1 names
  if names=$(secret_names minimal 2>/dev/null) && printf '%s\n' "$names" | grep -qx CLAUDE_CODE_OAUTH_TOKEN; then
    setup_skip "Claude login: CLAUDE_CODE_OAUTH_TOKEN is in the vault (profile minimal)"; return 0
  fi
  if ! have claude; then
    log "Claude Code is not installed here, so there is no token to hand to the nodes yet"
    log "later: claude setup-token | fleet secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal"
    return 0
  fi
  if [ -z "$want" ]; then
    if [ -t 0 ] || [ "$SETUP_YES" != 1 ]; then
      if setup_yn "Run 'claude setup-token' now (browser login) and store the token for the nodes? It goes through a pipe into the vault and is never shown" y; then want=1; else want=0; fi
    else
      log "claude setup-token needs your terminal; not run (stdin is not a terminal). later: claude setup-token | fleet secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal"
      return 0
    fi
  fi
  if [ "$want" != 1 ]; then
    log "Claude login skipped; later: claude setup-token | fleet secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal"; return 0
  fi
  log "claude setup-token: finish the login in your browser; the token is read from the pipe"
  if claude setup-token | setup_token_filter | cmd_secrets_set CLAUDE_CODE_OAUTH_TOKEN --profile minimal; then
    ok "Claude login: CLAUDE_CODE_OAUTH_TOKEN stored for the nodes (profile minimal)"
  else
    warn "no token stored; later: claude setup-token | fleet secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal"
  fi
}

# setup_more_secrets — interactive only: more secrets for the nodes, each
# typed into the hidden prompt of cmd_secrets_set.
setup_more_secrets() {
  local name="" profile=""
  [ "$SETUP_YES" = 1 ] && return 0
  while :; do
    printf 'Add another secret for the nodes (e.g. OPENAI_API_KEY)? NAME, empty to finish: ' >&2
    IFS= read -r name || name=""
    [ -n "$name" ] || break
    setup_ask profile "profile for $name (minimal = every node, full = trusted nodes only)" full
    ( cmd_secrets_set "$name" --profile "$profile" ) || warn "not stored: $name"
  done
}

# setup_proxy — the CLIProxyAPI config.yaml of this machine into the vault.
setup_proxy() {
  local src=${FLEET_CLIPROXY_DIR:-$HOME/cli-proxy-api}
  if vault_has "$FLEET_VAULT/files/full/.cli-proxy-api/config.yaml"; then setup_skip "proxy: CLIProxyAPI config.yaml is in the vault"; return 0; fi
  if [ -f "$src/conf/config.yaml" ]; then
    cmd_proxy_import "$src"
  else
    warn "proxy: no $src/conf/config.yaml here; once CLIProxyAPI runs on this machine: fleet proxy import [DIR]; each node then: fleet proxy login NODE"
  fi
}

# ---------- the command ----------

cmd_setup() {
  local owner="" cname="" cdir="" memory="" mrepo="" tools="" proxy="" awake="" claude_tok="" slug login memurl toolsl def
  SETUP_YES=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y)         SETUP_YES=1 ;;
      --github-owner)   owner=${2:-}; shift ;;
      --config-repo)    cname=${2:-}; shift ;;
      --config-dir)     cdir=${2:-}; shift ;;
      --memory)         memory=1 ;;
      --no-memory)      memory=0 ;;
      --memory-repo)    mrepo=${2:-}; shift ;;
      --tools)          tools=${2:-}; shift ;;
      --proxy)          proxy=1 ;;
      --no-proxy)       proxy=0 ;;
      --keep-awake)     awake=1 ;;
      --no-keep-awake)  awake=0 ;;
      --claude-token)   claude_tok=1 ;;
      --no-claude-token) claude_tok=0 ;;
      *) die "unknown flag: $1" "$(usage_for setup)" ;;
    esac; shift
  done
  [ -f "$FLEET_HOME/enrol.json" ] && die "this machine is a fleet node (enrol.json present)" "run fleet setup on the machine that is to be the master"

  # a rerun: the recorded config repo supplies the defaults, so --yes repeats the same setup
  if [ -z "$cdir" ] && [ -f "$FLEET_CONFIG_DIR/fleet.conf" ] && [ -n "${FLEET_CONFIG_REPO:-}" ]; then
    cdir=$FLEET_CONFIG_DIR
    slug=$(repo_slug "$FLEET_CONFIG_REPO")
    [ -n "$owner" ] || owner=${slug%%/*}
    [ -n "$cname" ] || cname=${slug#*/}
    if [ -z "$memory" ]; then if [ -n "${FLEET_MEMORY_REPO:-}" ]; then memory=1; mrepo=${mrepo:-$(basename "$(repo_slug "$FLEET_MEMORY_REPO")")}; else memory=0; fi; fi
    [ -n "$tools" ] || tools=${FLEET_TOOLS:-agents}
    [ -n "$awake" ] || awake=${FLEET_KEEP_AWAKE:-1}
    if [ -z "$proxy" ]; then case " $tools " in *" cliproxy "*) proxy=1 ;; *) proxy=0 ;; esac; fi
  fi

  setup_step 1 "preflight: commands, Tailscale logged in, git identity, GitHub CLI"
  init_preflight
  setup_gh_login

  setup_step 2 "GitHub owner"
  login=$(gh_login 2>/dev/null || true)
  [ -n "$owner" ] || setup_ask owner "GitHub user or organisation that owns the fleet repos" "$login"
  [ -n "$owner" ] || die "no GitHub owner" "pass --github-owner OWNER"
  if [ -n "$login" ] && [ "$owner" != "$login" ]; then ok "GitHub owner: $owner (logged in as $login)"; else ok "GitHub owner: $owner"; fi

  # the remaining questions, so the steps can run unattended afterwards
  [ -n "$cname" ] || setup_ask cname "name of your private config repo ($owner/<name>)" fleet-config
  [ -n "$cdir" ] || setup_ask cdir "local checkout of the config repo" "$HOME/fleet-config"
  cdir=$(setup_dir_abs "$cdir")
  if [ -z "$memory" ]; then
    log "Shared memory: every machine (this one included) uploads its agents' memories (Claude Code, Codex, Grok;"
    log "work projects included) into a private repo of yours, and every machine reads all of it. Secret-scanned, but not private per machine."
    if setup_yn "Enable shared memory?" y; then memory=1; else memory=0; fi
  fi
  if [ "$memory" = 1 ] && [ -z "$mrepo" ]; then setup_ask mrepo "memory repo ($owner/<name>)" fleet-memory; fi
  if [ -z "$tools" ]; then
    log "Tools on every node: minimal = base devtools claude; agents = minimal + codex cursor chrome;"
    log "full = agents + grok cliproxy t3code; or a space separated list (lib/tools)"
    setup_ask tools "tools preset" agents
  fi
  toolsl=$(setup_tools_resolve "$tools")
  if [ -z "$proxy" ]; then
    def=n; [ -f "${FLEET_CLIPROXY_DIR:-$HOME/cli-proxy-api}/conf/config.yaml" ] && def=y
    if setup_yn "Run CLIProxyAPI on every node (only if you use it here; its config.yaml is copied from ${FLEET_CLIPROXY_DIR:-$HOME/cli-proxy-api})?" "$def"; then proxy=1; else proxy=0; fi
  fi
  toolsl=$(setup_tools_with_proxy "$toolsl" "$proxy")
  if [ -z "$awake" ]; then
    if setup_yn "Keep nodes awake (they never system-sleep; for always-on machines, never the master)?" y; then awake=1; else awake=0; fi
  fi
  memurl=""; [ "$memory" = 1 ] && memurl="git@github.com:$owner/$mrepo.git"

  setup_step 3 "config repo $owner/$cname in $cdir"
  setup_config_repo "$owner" "$cname" "$cdir" "$toolsl" "$memurl" "$awake" "$proxy"

  setup_step 4 "memory repo"
  if [ "$memory" = 1 ]; then setup_memory_repo "$owner/$mrepo"; else setup_skip "memory repo: shared memory is off"; fi

  setup_step 5 "fleet init master --config-dir $cdir"
  if setup_init_done "$cdir"; then
    setup_skip "init master: vault, Tailscale OAuth client and schedules are in place (fleet init master --reconfigure redoes Tailscale/GitHub)"
  else
    cmd_init_master --config-dir "$cdir"
  fi

  setup_step 6 "Claude login for the nodes"
  setup_claude_token "$claude_tok"
  setup_more_secrets

  setup_step 7 "proxy"
  if [ "$proxy" = 1 ]; then setup_proxy; else setup_skip "proxy: not chosen (cliproxy is not in FLEET_TOOLS)"; fi

  setup_step 8 "publish the config repo, then fleet doctor"
  cmd_config_publish --yes
  cmd_doctor || warn "doctor found problems (above); fix them, then: fleet doctor"

  setup_step 9 "done. Next:"
  printf '  fleet invite --name NAME          # add a Mac or Linux box: paste the printed one-liner there\n' >&2
  printf '  %s/docker/spawn.sh 1   # a throwaway Docker node (first: docker build -f docker/Dockerfile -t fleet-node:local %s)\n' "$FLEET_ROOT" "$FLEET_ROOT" >&2
  printf '  fleet list                        # the fleet overview\n' >&2
  audit "setup" "-" ok
  ok "setup complete"
}
