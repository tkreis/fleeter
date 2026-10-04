# shellcheck shell=bash
# shellcheck disable=SC2154
# Node-side commands: apply, pull, update, memory sync, login, status, leave,
# daemon, plus scheduling. Sourced by `fleet` after lib/common.sh and
# fleet_load_config (hence SC2154 off: FLEET_* come from the conf files).
#
# Portability contract (docs/ARCHITECTURE.md): bash 3.2, no GNU-only flags, no sed -i, no
# flock, no timeout. Nothing here calls sudo.

NODE_REQUIRED_TOOLS="base devtools claude"
NODE_JOBS="pull memory update"          # every job fleet knows (removal covers all of them)
NODE_HARNESS_PROCS="claude codex cursor-agent grok"

# node_job_enabled JOB — the memory job only exists while a memory remote is
# configured (FLEET_MEMORY_REPO or FLEET_MEMORY_REMOTE); the others always.
node_job_enabled() {
  case "$1" in
    memory) [ -n "$(node_memory_remote)" ] ;;
    *) return 0 ;;
  esac
}

# node_jobs — the jobs this node schedules, one per line.
node_jobs() {
  local j
  for j in $NODE_JOBS; do node_job_enabled "$j" && printf '%s\n' "$j"; done
  return 0
}

# ---------- small helpers ----------

node_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# node_name — this machine's folder in the vault and its name in status: the
# enrolled name on a node, fleet_master_name on the master, else the hostname.
node_name() {
  local n=""
  [ -f "$FLEET_HOME/enrol.json" ] && n=$(json_get "$FLEET_HOME/enrol.json" name)
  if [ -z "$n" ] && fleet_is_master; then n=$(fleet_master_name); fi
  [ -n "$n" ] || n=$(hostname -s 2>/dev/null || hostname)
  printf '%s\n' "$n"
}

# node_kv_get FILE KEY / node_kv_set FILE KEY VALUE — tiny key=value state files.
node_kv_get() {
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -n 1 | cut -d= -f2-
}
node_kv_set() {
  local f=$1 k=$2 v=$3
  { [ -f "$f" ] && grep -v "^$k=" "$f" || true; printf '%s=%s\n' "$k" "$v"; } | atomic_write "$f" 0600
}

# Single-quote a value for a shell file.
node_sq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

node_load_secrets() {
  if [ -f "$FLEET_HOME/secrets.env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$FLEET_HOME/secrets.env"
    set +a
  fi
}

# git with non-interactive ssh (deploy keys only; never a password prompt).
node_git() {
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new}" \
  GIT_TERMINAL_PROMPT=0 git "$@"
}

# github-fleet-<alias>:owner/repo.git from a git@github.com:owner/repo.git URL,
# so git uses that repo's deploy key (~/.ssh/config aliases written by join).
# https URLs (public repo, no key) and non-GitHub URLs pass through unchanged.
node_repo_alias_url() {
  local alias=$1 url=$2 path
  case "$url" in
    git@github.com:*) path=${url#git@github.com:} ;;
    ssh://git@github.com/*) path=${url#ssh://git@github.com/} ;;
    *) printf '%s\n' "$url"; return 0 ;;
  esac
  printf '%s:%s\n' "$alias" "$path"
}
# FLEET_*_REMOTE override the derived URL (tests, local bare repos). The master
# has no deploy keys: it reaches the memory repo with its own git credentials.
node_code_remote()   { printf '%s\n' "${FLEET_CODE_REMOTE:-$(node_repo_alias_url github-fleet-code "$FLEET_CODE_REPO")}"; }
node_config_remote() { printf '%s\n' "${FLEET_CONFIG_REMOTE:-$(node_repo_alias_url github-fleet-config "$FLEET_CONFIG_REPO")}"; }
node_memory_remote() {
  if fleet_is_master; then printf '%s\n' "${FLEET_MEMORY_REMOTE:-$FLEET_MEMORY_REPO}"
  else printf '%s\n' "${FLEET_MEMORY_REMOTE:-$(node_repo_alias_url github-fleet-memory "$FLEET_MEMORY_REPO")}"; fi
}

# memory_git — git for the memory vault: the deploy-key ssh wrapper on a node,
# the user's own credentials on the master (no prompt either way).
memory_git() {
  if fleet_is_master; then GIT_TERMINAL_PROMPT=0 git "$@"; else node_git "$@"; fi
}

node_ts_cli() {
  if have tailscale; then command -v tailscale
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  fi
}

# ---------- tool plug-ins ----------

# Tools for this node: FLEET_TOOLS minus FLEET_TOOLS_SKIP_IN_CONTAINER when containerised.
node_tools() {
  local t s skip
  for t in $FLEET_TOOLS; do
    skip=0
    if fleet_in_container; then
      for s in $FLEET_TOOLS_SKIP_IN_CONTAINER; do [ "$s" = "$t" ] && skip=1; done
    fi
    [ "$skip" -eq 1 ] || printf '%s\n' "$t"
  done
}

node_tool_required() {
  local r
  for r in $NODE_REQUIRED_TOOLS; do [ "$r" = "$1" ] && return 0; done
  return 1
}

# node_tool_run NAME FN — run tool_<name>_<fn> in a fresh `bash -e` so a failing
# step inside the plug-in fails the call (a subshell under `if` would silently
# lose errexit) and so one tool cannot leak functions into another.
node_tool_run() {
  export FLEET_ROOT FLEET_HOME FLEET_SHARE FLEET_BIN FLEET_CONFIG_DIR
  bash -ec '
    . "$FLEET_ROOT/lib/common.sh"
    fleet_load_config
    f="$FLEET_ROOT/lib/tools/$1.sh"
    [ -f "$f" ] || die "unknown tool: $1" "see lib/tools/"
    . "$f"
    fn="tool_${1//-/_}_$2"
    if ! declare -F "$fn" >/dev/null 2>&1; then
      case $2 in
        status) echo "error no status function" ;;
        login)  echo "no login flow for $1 (tool_${1//-/_}_login not defined)" >&2; exit 3 ;;
        *)      warn "tool $1: no $2 function, skipping" ;;
      esac
      exit 0
    fi
    "$fn"
  ' bash "$1" "$2"
}

# node_tool_status NAME → "<state> <detail>" (never fails).
# Capped: a vendor status command can block (keychain over ssh, network), and
# status/login/write_status call this once per tool.
node_tool_status() {
  local line secs=${FLEET_STATUS_SECS:-20}
  line=$(with_timeout "$secs" node_tool_run "$1" status 2>/dev/null | head -n 1) || line=""
  [ -n "$line" ] || line="error status check failed or took longer than ${secs}s"
  printf '%s\n' "$line"
}

# ---------- apply ----------

# shellcheck disable=SC2120  # args come from the dispatcher; cmd_pull calls it bare on purpose
cmd_apply() {
  local digest="" name t failed_required="" failed_optional="" cc=""
  while [ $# -gt 0 ]; do
    case $1 in
      --from-master) [ $# -ge 2 ] || die "--from-master needs a digest"; digest=$2; shift 2 ;;
      *) die "usage: fleet apply [--from-master DIGEST]" ;;
    esac
  done
  mkdir -p "$FLEET_HOME/locks" "$FLEET_HOME/logs"
  chmod 700 "$FLEET_HOME"
  node_apply_lock
  node_load_secrets
  name=$(node_name)
  # The commits this apply runs from (code+config) are read now, under the
  # lock, and recorded at the end: never a commit that a concurrent pull
  # checked out meanwhile.
  cc=$(node_commits)
  log "apply on node $name ($(fleet_os), container=$(fleet_in_container && echo true || echo false), revs ${cc})"

  for t in $(node_tools); do
    log "tool $t"
    if node_tool_run "$t" install; then
      ok "tool $t"
    elif node_tool_required "$t"; then
      failed_required="$failed_required $t"; warn "tool $t: install failed (required)"
    else
      failed_optional="$failed_optional $t"; warn "tool $t: install failed (optional)"
    fi
  done

  if declare -F harness_apply >/dev/null 2>&1; then
    log "harness config"
    if harness_apply; then ok "harness config"; else failed_optional="$failed_optional harness"; warn "harness apply failed"; fi
  fi

  node_write_env "$name"
  node_shell_rc
  node_memory_setup "$name"
  node_bin_link
  if fleet_in_container; then
    log "container: no schedules (fleet daemon runs the jobs)"
  else
    node_schedule_install
    node_awake_apply
  fi

  [ -n "$failed_optional" ] && warn "optional steps failed:$failed_optional"
  # Success markers only after every required tool converged: a failed apply
  # leaves applied/applied_commit untouched, so the master re-provisions and
  # `fleet pull` retries the same fleet-config commit on its next run.
  [ -z "$failed_required" ] || die "required tools failed:$failed_required" "fix the errors above and rerun fleet apply (fleet pull retries it)"
  [ -n "$digest" ] || digest=$(node_compute_digest)
  printf '%s\n' "$digest" | atomic_write "$FLEET_HOME/applied" 0600
  node_utc | atomic_write "$FLEET_HOME/applied_at" 0600
  if [ "$cc" != "+" ]; then printf '%s\n' "$cc" | atomic_write "$FLEET_HOME/applied_commit" 0600; fi
  node_write_status
  ok "apply done (digest ${digest}, revs ${cc})"
}

# The apply lock (~/.config/fleet/locks/apply) serialises apply and pull. A
# lock whose recorded pid is this very process is already ours: `fleet pull`
# takes it before fetch/reset and then `exec`s the freshly checked-out
# `fleet apply` (same PID, EXIT trap not run on exec), so apply must not block
# on itself. Timeout exits non-zero on purpose: a scheduled `fleet pull` then
# retries next run.
node_apply_lock() {
  local l="$FLEET_HOME/locks/apply"
  if [ -d "$l" ] && [ "$(lock_pid "$l")" = "$$" ]; then
    trap 'lock_release "$FLEET_HOME/locks/apply"' EXIT
    return 0
  fi
  lock_acquire "$l" "${FLEET_APPLY_LOCK_WAIT:-600}" \
    || die "another fleet apply is running (lock $l)" "wait for it or remove the lock directory"
  trap 'lock_release "$FLEET_HOME/locks/apply"' EXIT
}

node_compute_digest() {
  {
    if [ -d "$FLEET_SHARE" ]; then sha256_tree "$FLEET_SHARE"; else sha256_tree "$FLEET_ROOT"; fi
    if [ -d "$FLEET_CONFIG_DIR" ]; then sha256_tree "$FLEET_CONFIG_DIR"; fi
  } | sha256
}

# node_repo_commit DIR — HEAD of a checkout, empty for a tar copy or a missing dir.
node_repo_commit() {
  [ -d "$1/.git" ] || return 0
  git -C "$1" rev-parse HEAD 2>/dev/null || true
}
node_code_commit()   { node_repo_commit "$FLEET_SHARE"; }
node_config_commit() { node_repo_commit "$FLEET_CONFIG_DIR"; }
# "<code>+<config>" — what applied_commit records (CONTRACT "Node files").
node_commits() { printf '%s+%s\n' "$(node_code_commit)" "$(node_config_commit)"; }

# Last "<code>+<config>" pair that was applied successfully.
node_applied_commit() { cat "$FLEET_HOME/applied_commit" 2>/dev/null || true; }

# Client key for CLIProxyAPI, if the cliproxy plug-in provides it. Subshell so
# sourcing the plug-in does not leak into this process.
node_proxy_token() {
  (
    if ! declare -F cliproxy_client_key >/dev/null 2>&1 && [ -f "$FLEET_ROOT/lib/tools/cliproxy.sh" ]; then
      # shellcheck source=/dev/null
      . "$FLEET_ROOT/lib/tools/cliproxy.sh" 2>/dev/null || exit 0
    fi
    declare -F cliproxy_client_key >/dev/null 2>&1 || exit 0
    cliproxy_client_key 2>/dev/null
  )
}

# node_proxy_mode — how this node should point the harnesses at CLIProxyAPI:
#   local   cliproxy is in FLEET_TOOLS, FLEET_PROXY_MODE=local, not a container,
#           and the client key from conf/config.yaml is readable
#   remote  cliproxy is in FLEET_TOOLS and either FLEET_PROXY_MODE=remote or
#           this is a container, with FLEET_PROXY_URL set
#   off     anything else: nothing is exported, stale values are cleared
node_proxy_mode() {
  local t enabled=0
  for t in $(node_tools); do [ "$t" = cliproxy ] && enabled=1; done
  [ "$enabled" = 1 ] || { echo off; return 0; }
  [ -n "${FLEET_PROXY_URL:-}" ] || { echo off; return 0; }
  if fleet_in_container || [ "${FLEET_PROXY_MODE:-local}" = remote ]; then echo remote; return 0; fi
  if [ -n "$(node_proxy_token)" ]; then echo local; else echo off; fi
}

# ~/.config/fleet/env.sh — sourced by shells (rc block) and by units/plists.
# The proxy variables are exported only while cliproxy is enabled for this
# node (node_proxy_mode); otherwise env.sh unsets them before secrets.env is
# sourced, so a value a previous apply exported disappears while a secret
# named ANTHROPIC_* still wins.
node_write_env() {
  local name=$1 token="" mode
  mode=$(node_proxy_mode)
  if [ "$mode" = local ]; then token=$(node_proxy_token) || token=""; fi
  {
    echo '# generated by fleet apply; fleet owns this file — do not edit'
    if [ "$mode" = off ]; then echo 'unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN'; fi
    printf '[ -f %s ] && { set -a; . %s; set +a; }\n' "'$(node_sq "$FLEET_HOME/secrets.env")'" "'$(node_sq "$FLEET_HOME/secrets.env")'"
    # shellcheck disable=SC2016  # generated shell: must expand on the reader's side
    echo 'case ":$PATH:" in *":$HOME/.local/share/mise/shims:"*) ;; *) PATH="$HOME/.local/share/mise/shims:$PATH" ;; esac'
    # shellcheck disable=SC2016
    echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac'
    echo 'export PATH'
    printf "export FLEET_NODE_NAME='%s'\n" "$(node_sq "$name")"
    printf "export FLEET_NODE='%s'\n" "$(node_sq "$name")"
    if [ "$mode" != off ]; then
      printf "export ANTHROPIC_BASE_URL='%s'\n" "$(node_sq "$FLEET_PROXY_URL")"
    fi
    if [ -n "$token" ]; then
      printf "export ANTHROPIC_AUTH_TOKEN='%s'\n" "$(node_sq "$token")"
    fi
  } | atomic_write "$FLEET_HOME/env.sh" 0600
  node_manifest_add "$FLEET_HOME/env.sh"
  case "$mode" in
    local)  ok "env.sh written (proxy $FLEET_PROXY_URL, token set)" ;;
    remote) ok "env.sh written (remote proxy $FLEET_PROXY_URL)" ;;
    *)      ok "env.sh written (no proxy: cliproxy not enabled on this node)" ;;
  esac
  if [ "$(fleet_os)" = macos ] && have launchctl; then
    if [ "$mode" = off ]; then
      launchctl unsetenv ANTHROPIC_BASE_URL 2>/dev/null || true
      launchctl unsetenv ANTHROPIC_AUTH_TOKEN 2>/dev/null || true
    else
      launchctl setenv ANTHROPIC_BASE_URL "$FLEET_PROXY_URL" 2>/dev/null || warn "launchctl setenv ANTHROPIC_BASE_URL failed"
      # launchctl setenv has no stdin form: the token is in this one argv for milliseconds (local user only); never logged.
      if [ -n "$token" ]; then launchctl setenv ANTHROPIC_AUTH_TOKEN "$token" 2>/dev/null || warn "launchctl setenv ANTHROPIC_AUTH_TOKEN failed"; fi
    fi
  fi
}

node_manifest_add() {
  local m="$FLEET_HOME/manifest"
  if [ -f "$m" ] && grep -qxF "$1" "$m"; then return 0; fi
  { [ -f "$m" ] && cat "$m" || true; printf '%s\n' "$1"; } | atomic_write "$m" 0600
}

# Exactly one marker block per rc file (CONTRACT "Shell integration").
# shellcheck disable=SC2016  # literal line for the user's rc file
NODE_RC_BLOCK='# >>> fleet >>>
[ -f "$HOME/.config/fleet/env.sh" ] && . "$HOME/.config/fleet/env.sh"
# <<< fleet <<<'

node_rc_ensure() {
  local f=$1 current
  if [ -f "$f" ] && grep -qF '# >>> fleet >>>' "$f"; then
    current=$(awk '/^# >>> fleet >>>$/{p=1} p{print} /^# <<< fleet <<<$/{p=0}' "$f")
    [ "$current" = "$NODE_RC_BLOCK" ] && return 0
    backup_once "$f"
    { awk '/^# >>> fleet >>>$/{skip=1} !skip{print} /^# <<< fleet <<<$/{skip=0}' "$f"; printf '%s\n' "$NODE_RC_BLOCK"; } \
      | atomic_write "$f" 0644
  else
    backup_once "$f"
    { [ -f "$f" ] && cat "$f" || true; [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && echo || true; printf '%s\n' "$NODE_RC_BLOCK"; } \
      | atomic_write "$f" 0644
  fi
  node_manifest_add "$f"
  ok "shell rc block: $f"
}

# Every shell that might start an agent must see env.sh, not only interactive
# zsh: T3 Code's SSH mode starts its server through `sh -l -s` (reads
# ~/.profile), `ssh host cmd` runs a non-interactive zsh (reads ~/.zshenv),
# bash login shells read ~/.bash_profile instead of ~/.profile when it exists.
# env.sh is POSIX sh and idempotent, so loading it twice is harmless.
node_shell_rc() {
  local files="$HOME/.profile" f
  case "$(fleet_os)" in
    macos) files="$files $HOME/.zshrc $HOME/.zshenv" ;;
    *)     files="$files $HOME/.bashrc"; [ -f "$HOME/.zshrc" ] && files="$files $HOME/.zshrc $HOME/.zshenv" ;;
  esac
  [ "$(fleet_os)" = macos ] && [ -f "$HOME/.bashrc" ] && files="$files $HOME/.bashrc"
  [ -f "$HOME/.bash_profile" ] && files="$files $HOME/.bash_profile"
  for f in $files; do node_rc_ensure "$f"; done
}

# ~/.local/bin/fleet and its alias ~/.local/bin/fleeter both point at the
# installed checkout. Idempotent.
node_bin_link() {
  local n
  if [ -x "$FLEET_SHARE/fleet" ]; then
    mkdir -p "$FLEET_BIN"
    for n in fleet fleeter; do
      [ "$(readlink "$FLEET_BIN/$n" 2>/dev/null)" = "$FLEET_SHARE/fleet" ] || ln -sfn "$FLEET_SHARE/fleet" "$FLEET_BIN/$n"
    done
  fi
}

# ---------- memory vault ----------

# node_memory_setup NAME — clone the vault when missing, point origin at the
# configured remote, set the commit identity (nodes; the master commits as the
# user) and create nodes/NAME. On the master FLEET_MEMORY_SEED=0 (tests) skips
# the clone, like memory_seed.
node_memory_setup() {
  local name=$1 remote
  remote=$(node_memory_remote)
  if [ -z "$remote" ]; then
    node_kv_set "$FLEET_HOME/memory.state" state off
    log "memory: no FLEET_MEMORY_REPO configured; shared memory is off on this $(fleet_is_master && echo master || echo node)"
    return 0
  fi
  if [ ! -d "$FLEET_MEMORY_DIR/.git" ]; then
    if fleet_is_master && [ "${FLEET_MEMORY_SEED:-1}" = 0 ]; then return 0; fi
    mkdir -p "$FLEET_HOME/logs"
    log "cloning fleet-memory into $FLEET_MEMORY_DIR"
    if memory_git clone --quiet "$remote" "$FLEET_MEMORY_DIR" 2>"$FLEET_HOME/logs/memory-clone.err"; then
      ok "memory vault cloned"
    else
      if fleet_is_master; then warn "memory clone failed (can this user reach $remote with git?); see $FLEET_HOME/logs/memory-clone.err"
      else warn "memory clone failed (deploy key not registered yet?); see $FLEET_HOME/logs/memory-clone.err"; fi
      node_kv_set "$FLEET_HOME/memory.state" state missing
      return 0
    fi
  fi
  node_remote_sync memory "$FLEET_MEMORY_DIR" "$remote"
  if ! fleet_is_master; then
    memory_git -C "$FLEET_MEMORY_DIR" config user.name "fleet-$name"
    memory_git -C "$FLEET_MEMORY_DIR" config user.email "fleet-$name@users.noreply.github.com"
  fi
  memory_git -C "$FLEET_MEMORY_DIR" config pull.rebase true
  mkdir -p "$FLEET_MEMORY_DIR/nodes/$name"
  case "$(node_kv_get "$FLEET_HOME/memory.state" state)" in
    ""|missing|off) node_kv_set "$FLEET_HOME/memory.state" state ok ;;
  esac
  ok "memory vault ready (nodes/$name)"
}

node_rebase_in_progress() {
  local gd
  gd=$(git -C "$FLEET_MEMORY_DIR" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]
}

# node_memory_capture NAME DIR — mirror this machine's native agent memories
# (FLEET_MEMORY_CAPTURE sources) into DIR/nodes/NAME/<source>/ through
# lib/memory_capture.py. A file the secret scan hits is skipped, warned about
# once (again only when the set of hits changes) and recorded in memory.state
# (capture_skipped, shown as detail); it never reaches the vault. Quiet when
# nothing changed. Never fails the sync.
node_memory_capture() {
  local name=$1 dir=$2 out hits summary n=0 prev
  [ -n "${FLEET_MEMORY_CAPTURE:-}" ] || return 0
  [ -f "$FLEET_ROOT/lib/memory_capture.py" ] || { warn "memory: lib/memory_capture.py missing in $FLEET_ROOT; capture skipped"; return 0; }
  # shellcheck disable=SC2086  # ${FLEET_VERBOSE:+--verbose} is one optional word
  out=$(python3 "$FLEET_ROOT/lib/memory_capture.py" --home "$HOME" --dest "$dir/nodes/$name" \
          --sources "$FLEET_MEMORY_CAPTURE" --exclude "${FLEET_MEMORY_CAPTURE_EXCLUDE:-}" \
          --max-kb "${FLEET_MEMORY_MAX_KB:-256}" ${FLEET_VERBOSE:+--verbose} 2>&1) || warn "memory: capture failed: $(printf '%s' "$out" | tail -n 1)"
  hits=$(printf '%s\n' "$out" | awk '$1 == "secret" { print $2 }')
  summary=$(printf '%s\n' "$out" | awk '$1 == "summary" { printf "%s %s", $2, $3; for (i = 4; i <= NF; i++) if ($i !~ /=0$/) printf " %s", $i; printf "; " }')
  prev=$(node_kv_get "$FLEET_HOME/memory.state" capture_skipped)
  hits=$(printf '%s' "$hits" | tr '\n' ' ')
  if [ -n "$hits" ] && [ "$hits" != "$prev" ]; then
    n=$(printf '%s\n' "$hits" | wc -w | tr -d ' ')
    warn "memory: $n file(s) not uploaded, the secret scan hit: $hits"
  fi
  [ "$hits" = "$prev" ] || node_kv_set "$FLEET_HOME/memory.state" capture_skipped "$hits"
  printf '%s\n' "$out" | awk '$1 == "copied" || $1 == "removed"' | while IFS= read -r n; do log "memory: capture $n"; done
  if [ -n "${FLEET_VERBOSE:-}" ] || printf '%s' "$out" | grep -q 'copied=[1-9]\|removed=[1-9]'; then
    log "memory: captured ${summary%; }"
  fi
  return 0
}

# node_memory_commit_counts DIR NAME — "+A ~M -D" of what is staged under nodes/NAME.
node_memory_commit_counts() {
  memory_git -C "$1" diff --cached --no-renames --name-status -- "nodes/$2" \
    | awk '{ c[substr($1, 1, 1)]++ } END { printf "+%d ~%d -%d\n", c["A"], c["M"], c["D"] }'
}

# memory sync [--reset]: capture agent memories → commit nodes/<name> only →
# pull --rebase → push, 3 tries. Runs on nodes and on the master (which clones
# the vault itself when it is missing). --reset clears a recorded conflict
# after a human repaired the vault.
# One memory sync at a time: the timer and a manual run would otherwise write
# the same capture folders concurrently. A second caller returns quietly.
cmd_memory_sync() {
  local lock="$FLEET_HOME/locks/memory" rc=0
  mkdir -p "$FLEET_HOME/locks"
  if ! lock_acquire "$lock" 0; then
    [ -z "${FLEET_VERBOSE:-}" ] || log "memory: another sync is running; skipping"
    return 0
  fi
  node_memory_sync_run "$@" || rc=$?
  lock_release "$lock"
  return "$rc"
}

node_memory_sync_run() {
  local reset=0 name dir sf branch attempt delay others ahead counts
  [ "${1:-}" = --reset ] && reset=1
  name=$(node_name); dir=$FLEET_MEMORY_DIR; sf="$FLEET_HOME/memory.state"
  if [ -z "$(node_memory_remote)" ]; then
    node_kv_set "$sf" state off
    [ -z "${FLEET_VERBOSE:-}" ] || log "memory: no FLEET_MEMORY_REPO configured; nothing to sync"
    return 0
  fi
  if [ ! -d "$dir/.git" ] && fleet_is_master; then node_memory_setup "$name"; fi
  if [ ! -d "$dir/.git" ]; then
    node_kv_set "$sf" state missing
    if fleet_is_master; then [ "${FLEET_MEMORY_SEED:-1}" = 0 ] || warn "memory vault not cloned at $dir"
    else warn "memory vault not cloned at $dir (run fleet apply)"; fi
    return 0
  fi
  if node_rebase_in_progress; then
    if [ "$reset" -eq 1 ]; then memory_git -C "$dir" rebase --abort >/dev/null 2>&1 || true
    else node_kv_set "$sf" state conflict; warn "memory: a rebase is in progress; run 'fleet memory sync --reset' after fixing $dir"; return 0
    fi
  fi
  if [ "$reset" -eq 0 ] && [ "$(node_kv_get "$sf" state)" = conflict ]; then
    warn "memory: in conflict state, not syncing; fix $dir on the master, then run 'fleet memory sync --reset'"
    return 0
  fi
  [ "$reset" -eq 1 ] && node_kv_set "$sf" state ok

  mkdir -p "$dir/nodes/$name"
  if ! fleet_is_master; then
    memory_git -C "$dir" config user.name "fleet-$name" >/dev/null 2>&1 || true
    memory_git -C "$dir" config user.email "fleet-$name@users.noreply.github.com" >/dev/null 2>&1 || true
  fi
  node_memory_capture "$name" "$dir"
  # Never commit outside nodes/<name>: drop anything staged, then stage only our path.
  memory_git -C "$dir" reset --quiet 2>/dev/null || true
  memory_git -C "$dir" add -A -- "nodes/$name"
  if ! memory_git -C "$dir" diff --cached --quiet; then
    counts=$(node_memory_commit_counts "$dir" "$name")
    memory_git -C "$dir" commit --quiet -m "memory: $name $(node_utc) ($counts)"
    ok "memory: committed nodes/$name ($counts)"
  fi
  others=$(memory_git -C "$dir" status --porcelain | awk -v p="nodes/$name/" 'index(substr($0, 4), p) != 1 { print substr($0, 4) }')
  if [ -n "$others" ]; then
    warn "memory: changes outside nodes/$name left unstaged: $(printf '%s' "$others" | tr '\n' ' ')"
    node_kv_set "$sf" detail "unstaged changes outside nodes/$name"
  elif [ -n "$(node_kv_get "$sf" capture_skipped)" ]; then
    node_kv_set "$sf" detail "not uploaded (secret scan): $(node_kv_get "$sf" capture_skipped)"
  else
    node_kv_set "$sf" detail ""
  fi

  branch=$(memory_git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo main)
  # Nothing committed yet and the remote branch does not exist: an empty vault.
  # Not an error; the master adds the scaffolding, the first note creates main.
  if ! memory_git -C "$dir" rev-parse --verify --quiet HEAD >/dev/null 2>&1 \
     && ! memory_git -C "$dir" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    node_kv_set "$sf" state ok
    node_kv_set "$sf" detail "vault empty (the master adds the scaffolding on its next reconcile)"
    return 0
  fi
  [ "$branch" != HEAD ] || { node_kv_set "$sf" state conflict; warn "memory: detached HEAD in $dir"; return 0; }
  attempt=0; delay=2
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    if memory_git -C "$dir" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      if ! memory_git -C "$dir" pull --rebase --autostash --quiet origin "$branch" >/dev/null 2>&1; then
        if node_rebase_in_progress; then
          memory_git -C "$dir" rebase --abort >/dev/null 2>&1 || true
          node_kv_set "$sf" state conflict
          node_kv_set "$sf" detail "rebase conflict on nodes/$name; aborted"
          warn "memory: rebase conflict; aborted and stopped syncing (fix on the master, then 'fleet memory sync --reset')"
          return 0
        fi
        warn "memory: pull failed (attempt $attempt/3)"
        sleep "$delay"; delay=$((delay * 2)); continue
      fi
    fi
    ahead=1
    if memory_git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
      ahead=$(memory_git -C "$dir" rev-list --count "refs/remotes/origin/$branch..HEAD" 2>/dev/null || echo 1)
    fi
    if [ "$ahead" -eq 0 ] || memory_git -C "$dir" push --quiet origin "$branch" >/dev/null 2>&1; then
      node_kv_set "$sf" state ok
      node_kv_set "$sf" last_sync "$(node_utc)"
      [ "$ahead" -eq 0 ] || ok "memory: pushed"
      return 0
    fi
    warn "memory: push failed (attempt $attempt/3)"
    sleep "$delay"; delay=$((delay * 2))
  done
  node_kv_set "$sf" detail "sync failed after 3 attempts (remote unreachable?)"
  warn "memory: sync failed after 3 attempts; will retry on the next run"
  return 0
}

# ---------- pull (code + config repos) ----------

# node_remote_sync LABEL DIR REMOTE — point DIR's origin at REMOTE when the
# configured URL changed (a repo move or rename in fleet.conf), so the next
# fetch/push talks to the new location instead of the one recorded at clone time.
node_remote_sync() {
  local label=$1 dir=$2 remote=$3 cur
  [ -n "$remote" ] && [ -d "$dir/.git" ] || return 0
  cur=$(node_git -C "$dir" remote get-url origin 2>/dev/null || true)
  [ "$cur" = "$remote" ] && return 0
  if [ -z "$cur" ]; then
    node_git -C "$dir" remote add origin "$remote"
  else
    node_git -C "$dir" remote set-url origin "$remote"
  fi
  log "$label: origin ${cur:-<none>} -> $remote"
}

# node_pull_repo LABEL DIR REMOTE — bring DIR to origin/main of REMOTE. A tar
# copy left by the first provision is converted into a git checkout in place
# (the master sends no .git); a missing DIR is cloned. Fetch failures only warn
# (offline, deploy key not registered yet): the current copy stays in use.
node_pull_repo() {
  local label=$1 dir=$2 remote=$3 after
  if [ -z "$remote" ]; then
    [ -n "${FLEET_VERBOSE:-}" ] && log "$label: no repo configured, keeping the current copy"
    return 0
  fi
  if [ ! -d "$dir" ]; then
    log "$label: cloning $remote into $dir"
    node_git clone --quiet --branch main "$remote" "$dir" 2>/dev/null || { warn "$label: clone of $remote failed (deploy key pending or offline)"; return 0; }
    return 0
  fi
  if [ ! -d "$dir/.git" ]; then
    if ! node_git ls-remote --heads "$remote" >/dev/null 2>&1; then
      warn "$label repo not reachable (deploy key pending or offline); keeping the current copy"
      return 0
    fi
    log "$label: converting $dir into a git checkout of $remote"
    node_git -C "$dir" init --quiet
    node_git -C "$dir" remote add origin "$remote"
    node_git -C "$dir" fetch --quiet origin main || { warn "$label: fetch failed"; return 0; }
    node_git -C "$dir" symbolic-ref HEAD refs/heads/main
    node_git -C "$dir" reset --hard --quiet origin/main
    node_git -C "$dir" branch --quiet --set-upstream-to=origin/main main 2>/dev/null || true
    log "$label at $(node_git -C "$dir" rev-parse --short HEAD)"
    return 0
  fi
  node_remote_sync "$label" "$dir" "$remote"
  node_git -C "$dir" fetch --quiet origin main 2>/dev/null || { warn "$label: fetch failed (offline?)"; return 0; }
  after=$(node_git -C "$dir" rev-parse origin/main 2>/dev/null || echo none)
  [ "$after" != none ] || return 0
  if [ "$(node_git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$after" ]; then
    log "$label: $(node_git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo none) -> $(node_git -C "$dir" rev-parse --short "$after")"
    node_git -C "$dir" reset --hard --quiet origin/main
  fi
}

# Fetches both repos, then compares "<code>+<config>" with the last
# SUCCESSFULLY applied pair (~/.config/fleet/applied_commit), not with HEAD: a
# commit whose apply failed is retried on the next run. A non-zero exit from
# apply propagates. The apply lock is taken BEFORE fetch/reset: a running
# apply must never have a checkout swapped under it (and then record commits
# it did not apply). `--no-apply` only updates the checkouts (the master runs
# it during provision, right before its own `fleet apply --from-master`).
cmd_pull() {
  local applied before after no_apply=0
  while [ $# -gt 0 ]; do
    case $1 in
      --no-apply) no_apply=1 ;;
      *) die "usage: fleet pull [--no-apply]" ;;
    esac; shift
  done
  [ -d "$FLEET_SHARE" ] || { warn "no fleet checkout at $FLEET_SHARE (not provisioned yet)"; return 0; }
  mkdir -p "$FLEET_HOME/locks"
  node_apply_lock
  before=$(node_commits)
  node_pull_repo code "$FLEET_SHARE" "$(node_code_remote)"
  node_pull_repo config "$FLEET_CONFIG_DIR" "$(node_config_remote)"
  after=$(node_commits)
  [ "$no_apply" = 0 ] || return 0
  applied=$(node_applied_commit)
  [ "$after" != "+" ] || return 0           # neither repo is a git checkout yet
  [ "$applied" != "$after" ] || return 0
  if [ "$before" = "$after" ] && [ -n "$applied" ]; then
    log "revs ${after}: previous apply did not succeed, retrying"
  else
    log "revs ${applied:-none} -> ${after}"
  fi
  if [ -x "$FLEET_SHARE/fleet" ]; then
    exec "$FLEET_SHARE/fleet" apply
  fi
  # shellcheck disable=SC2119
  cmd_apply
}

# ---------- update / login / status ----------

cmd_update() {
  local t failed=""
  node_load_secrets
  for t in $(node_tools); do
    log "update $t"
    if node_tool_run "$t" update; then ok "update $t"; else failed="$failed $t"; warn "update $t failed"; fi
  done
  [ -z "$failed" ] || warn "updates failed:$failed"
  return 0
}

cmd_login() {
  local t line state any=0 app
  export FLEET_INTERACTIVE=1
  node_load_secrets
  if [ $# -gt 0 ]; then
    node_tool_run "$1" login
    node_write_status
    return 0
  fi
  # Only tools with a login flow; each check is announced and capped, because a
  # vendor status command can block (keychain over ssh, network).
  for t in $(node_tools); do
    grep -q "^tool_${t//-/_}_login()" "$FLEET_ROOT/lib/tools/$t.sh" 2>/dev/null || continue
    log "checking $t login..."
    line=$(node_tool_status "$t")
    state=${line%% *}
    case "$state" in
      ok) ok "$t: ${line#* }" ;;
      login)
        any=1; log "login: $t (follow the prompts below; device codes can be approved on your phone)"
        node_tool_run "$t" login || warn "$t login failed; retry: fleet login $t" ;;
      *) warn "$t: $line; try: fleet login $t" ;;
    esac
  done
  if [ "$(fleet_os)" = macos ]; then
    for app in Claude ChatGPT Cursor; do
      if [ -d "/Applications/$app.app" ]; then
        log "opening $app.app — sign in there if it asks (fleet cannot tell whether a GUI app is signed in)"
        open -a "$app" 2>/dev/null || true
      fi
    done
  fi
  [ "$any" -eq 1 ] || ok "no CLI tool needs a login"
  log "updating node status..."
  node_write_status
}

# node_proc_cmd PID — the command line of PID ("" when gone). `ps -o command=`
# on macOS and procps; /proc on slim images without ps.
node_proc_cmd() {
  local c=""
  if have ps; then c=$(ps -o command= -p "$1" 2>/dev/null || true); fi
  if [ -z "$c" ] && [ -r "/proc/$1/cmdline" ]; then c=$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null || true); fi
  printf '%s\n' "$c"
}

# node_proc_uid PID — numeric owner of PID ("" when gone).
node_proc_uid() {
  local u=""
  if have ps; then u=$(ps -o uid= -p "$1" 2>/dev/null | tr -d ' ' || true); fi
  if [ -z "$u" ] && [ -f "/proc/$1/status" ]; then u=$(awk '/^Uid:/ {print $2; exit}' "/proc/$1/status" 2>/dev/null || true); fi
  printf '%s\n' "$u"
}

# node_daemon_is PID — PID is alive, ours, and really runs `fleet daemon`.
# daemon.pid is only trusted after this check: a reused PID (reboot, container
# restart) must never get our TERM/KILL.
node_daemon_is() {
  local pid=$1
  [ -n "$pid" ] || return 1
  case "$pid" in *[!0-9]*|"") return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$(node_proc_uid "$pid")" = "$(id -u)" ] || return 1
  case "$(node_proc_cmd "$pid")" in *"fleet daemon"*) return 0 ;; esac
  return 1
}

node_daemon_alive() {
  local pid
  pid=$(cat "$FLEET_HOME/daemon.pid" 2>/dev/null || true)
  node_daemon_is "$pid"
}

node_timer_active() {
  local job=$1
  if fleet_in_container; then node_daemon_alive; return; fi
  case "$(fleet_os)" in
    macos) launchctl print "gui/$(id -u)/dev.fleet.$job" >/dev/null 2>&1 ;;
    linux)
      if node_systemd_user_ok; then systemctl --user is-active --quiet "fleet-$job.timer" 2>/dev/null
      elif have crontab; then crontab -l 2>/dev/null | grep -q "# fleet:$job\$"
      else node_daemon_alive
      fi ;;
    *) return 1 ;;
  esac
}

# Collects everything in CONTRACT "fleet status --json" and writes status.json.
node_write_status() {
  local name t line tmp cc="" job
  name=$(node_name)
  mkdir -p "$FLEET_HOME"
  tmp=$(mktemp "$FLEET_HOME/.status.XXXXXX")
  for t in $(node_tools); do
    line=$(node_tool_status "$t")
    printf 'tool\t%s\t%s\t%s\n' "$t" "${line%% *}" "${line#* }" >>"$tmp"
  done
  for job in $(node_jobs); do
    if node_timer_active "$job"; then printf 'timer\t%s\ttrue\n' "$job" >>"$tmp"; else printf 'timer\t%s\tfalse\n' "$job" >>"$tmp"; fi
  done
  cc=$(node_config_commit)
  FLEET_ST_VERSION="$FLEET_VERSION" FLEET_ST_NAME="$name" FLEET_ST_OS="$(fleet_os)" \
  FLEET_ST_MEM_REMOTE="$(node_memory_remote)" \
  FLEET_ST_CONTAINER="$(fleet_in_container && echo true || echo false)" \
  FLEET_ST_APPLIED="$(cat "$FLEET_HOME/applied" 2>/dev/null || true)" \
  FLEET_ST_APPLIED_AT="$(cat "$FLEET_HOME/applied_at" 2>/dev/null || true)" \
  FLEET_ST_CODE_COMMIT="$(node_code_commit)" \
  FLEET_ST_COMMIT="$cc" FLEET_ST_APPLIED_COMMIT="$(node_applied_commit)" \
  FLEET_ST_MEM_STATE="$(node_kv_get "$FLEET_HOME/memory.state" state)" \
  FLEET_ST_MEM_SYNC="$(node_kv_get "$FLEET_HOME/memory.state" last_sync)" \
  FLEET_ST_MEM_DETAIL="$(node_kv_get "$FLEET_HOME/memory.state" detail)" \
  FLEET_ST_MEM_DIR="$FLEET_MEMORY_DIR" \
  FLEET_ST_SECRETS="$FLEET_HOME/secrets.env" \
  FLEET_ST_AWAKE="$(node_awake_state)" \
  FLEET_ST_AWAKE_LID="$(node_awake_lid_state)" \
  FLEET_ST_POWER_DONE="$(cat "$FLEET_HOME/power_done" 2>/dev/null || true)" \
  FLEET_ST_LAN="$(node_lan_info)" \
  python3 - "$tmp" <<'PY' | atomic_write "$FLEET_HOME/status.json" 0600
import json, os, re, sys, time
e = os.environ.get
tools, timers = {}, {}
with open(sys.argv[1]) as fh:
    for raw in fh:
        parts = raw.rstrip("\n").split("\t")
        if parts[0] == "tool" and len(parts) >= 4:
            tools[parts[1]] = {"state": parts[2], "detail": parts[3]}
        elif parts[0] == "timer" and len(parts) >= 3:
            timers[parts[1]] = parts[2] == "true"
if not e("FLEET_ST_MEM_REMOTE"):
    mem_state = "off"       # no memory repo configured: nothing is cloned or synced
else:
    mem_state = e("FLEET_ST_MEM_STATE") or ("missing" if not os.path.isdir(os.path.join(e("FLEET_ST_MEM_DIR", ""), ".git")) else "ok")
memory = {"state": mem_state, "last_sync": e("FLEET_ST_MEM_SYNC") or None}
if e("FLEET_ST_MEM_DETAIL"):
    memory["detail"] = e("FLEET_ST_MEM_DETAIL")
ages = {}
sp = e("FLEET_ST_SECRETS", "")
if os.path.isfile(sp):
    days = int((time.time() - os.path.getmtime(sp)) // 86400)
    with open(sp) as fh:
        for ln in fh:
            m = re.match(r"^(?:export\s+)?([A-Z][A-Z0-9_]*(?:TOKEN|KEY|SECRET)[A-Z0-9_]*)=", ln)
            if m:
                ages[m.group(1)] = days
lan = (e("FLEET_ST_LAN") or "").split("\t")
print(json.dumps({
    "fleet": e("FLEET_ST_VERSION"), "name": e("FLEET_ST_NAME"), "os": e("FLEET_ST_OS"),
    "container": e("FLEET_ST_CONTAINER") == "true",
    "applied": e("FLEET_ST_APPLIED") or None, "applied_at": e("FLEET_ST_APPLIED_AT") or None,
    "code_commit": e("FLEET_ST_CODE_COMMIT") or None, "config_commit": e("FLEET_ST_COMMIT") or None,
    "applied_commit": e("FLEET_ST_APPLIED_COMMIT") or None,
    "tools": tools, "memory": memory, "timers": timers, "awake": e("FLEET_ST_AWAKE") or "n/a",
    "awake_lid": e("FLEET_ST_AWAKE_LID") or "n/a",
    "lid_set_at_join": "+lid" in (e("FLEET_ST_POWER_DONE") or ""),
    "lan_ips": [ip for ip in lan[0].split(",") if ip],
    "ethernet": lan[1] if len(lan) > 1 and lan[1] else "no",
    "token_age_days": ages,
    "updated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}, indent=2))
PY
  rm -f "$tmp"
}

cmd_status() {
  node_load_secrets
  node_write_status
  if [ "${1:-}" = --json ]; then cat "$FLEET_HOME/status.json"; return 0; fi
  python3 - "$FLEET_HOME/status.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("node      %s  (%s%s, fleet %s)" % (d["name"], d["os"], ", container" if d["container"] else "", d["fleet"]))
print("applied   %s  at %s" % ((d.get("applied") or "-")[:12], d.get("applied_at") or "-"))
ac = (d.get("applied_commit") or "+").split("+", 1)
for label, key, applied in (("code", "code_commit", ac[0]), ("config", "config_commit", ac[1] if len(ac) > 1 else "")):
    cur = d.get(key) or "-"
    print("%-9s %s%s" % (label, cur[:12], "" if cur == (applied or "-") else "  (applied %s)" % ((applied or "-")[:12])))
m = d["memory"]
print("memory    %s  last sync %s%s" % (m["state"], m.get("last_sync") or "-", ("  (" + m["detail"] + ")") if m.get("detail") else ""))
print("timers    " + "  ".join("%s=%s" % (k, "on" if v else "off") for k, v in sorted(d["timers"].items())))
lid_note = ""
if d.get("awake_lid") == "on":
    lid_note = "  (lid: on%s; undo: sudo pmset -a disablesleep 0)" % (", set at join" if d.get("lid_set_at_join") else "")
print("awake     %s%s" % (d.get("awake", "n/a"), lid_note))
if d.get("lan_ips"):
    print("lan       %s  ethernet %s" % (" ".join(d["lan_ips"]), d.get("ethernet", "no")))
for k, v in sorted(d["tools"].items()):
    print("tool      %-12s %-8s %s" % (k, v["state"], v["detail"]))
for k, v in sorted(d["token_age_days"].items()):
    print("token     %-28s %s days%s" % (k, v, "  (renew soon)" if v > 330 else ""))
PY
}

# ---------- leave ----------

# Stops the `fleet daemon` recorded in ~/.config/fleet/daemon.pid and its whole
# process tree: TERM the daemon, wait up to 10 s for its own leave path, then
# kill_tree (common.sh) for a daemon that ignores TERM, and finally every
# descendant captured up front that outlived it (job grandchildren such as a
# tool's `bash -ec` + `sleep` are orphaned to init once the job dies, so a
# fresh pgrep -P would miss them). A pid that is alive but not our `fleet
# daemon` is a reused PID: the file is dropped, nothing is signalled. Skipped
# when called from the daemon's own exit path (FLEET_LEAVE_FROM_DAEMON=1, or
# the pid is this process).
node_daemon_stop() {
  local pidf="$FLEET_HOME/daemon.pid" pid tree i c left=""
  pid=$(cat "$pidf" 2>/dev/null || true)
  [ -n "$pid" ] || return 0
  if [ "${FLEET_LEAVE_FROM_DAEMON:-0}" = 1 ] || [ "$pid" = "$$" ]; then return 0; fi
  if ! node_daemon_is "$pid"; then
    if kill -0 "$pid" 2>/dev/null; then warn "daemon.pid $pid belongs to another process; ignoring the stale file"; fi
    rm -f "$pidf"; return 0
  fi
  tree=$(proc_tree "$pid")
  kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    warn "daemon (pid $pid) ignored TERM for 10s; killing it and its children"
    kill_tree "$pid"
  fi
  for c in $tree; do
    [ "$c" != "$pid" ] && kill -0 "$c" 2>/dev/null && left="$left $c"
  done
  if [ -n "$left" ]; then
    # shellcheck disable=SC2086  # intentional word splitting over PIDs
    kill -TERM $left 2>/dev/null || true; sleep 1
    # shellcheck disable=SC2086
    kill -KILL $left 2>/dev/null || true
  fi
  rm -f "$pidf"
  ok "daemon stopped (pid $pid)"
}

# Stops CLIProxyAPI when fleet runs it locally (lib/tools/cliproxy.sh), and its
# login-time bringup unit, so nothing restarts the proxy after leave.
node_cliproxy_stop() {
  local dir="${FLEET_CLIPROXY_DIR:-$HOME/cli-proxy-api}" uid
  [ -f "$dir/compose.yaml" ] || return 0
  if have docker && docker info >/dev/null 2>&1; then
    if (cd "$dir" && docker compose down >/dev/null 2>&1) || docker stop "${FLEET_PROXY_CONTAINER:-cli-proxy-api}" >/dev/null 2>&1; then
      ok "cliproxy stopped"
    else
      warn "could not stop cliproxy; run: docker compose -f $dir/compose.yaml down"
    fi
  elif have docker; then
    warn "docker daemon not reachable; cliproxy container left as is"
  fi
  case "$(fleet_os)" in
    macos)
      uid=$(id -u)
      launchctl bootout "gui/$uid/dev.fleet.cliproxy" >/dev/null 2>&1 || true
      rm -f "$HOME/Library/LaunchAgents/dev.fleet.cliproxy.plist" ;;
    linux)
      if node_systemd_user_ok; then
        systemctl --user disable --now fleet-cliproxy.service >/dev/null 2>&1 || true
        rm -f "$HOME/.config/systemd/user/fleet-cliproxy.service"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
      fi ;;
  esac
}

cmd_leave() {
  local p ts
  log "leaving the fleet (files stay on disk)"
  node_daemon_stop
  node_schedule_remove || true
  node_awake_remove || true
  if have pkill; then
    for p in $NODE_HARNESS_PROCS; do pkill -u "$(id -u)" -x "$p" 2>/dev/null || true; done
    ok "harness processes stopped"
  else
    warn "pkill not available; stop harness processes yourself"
  fi
  node_cliproxy_stop
  ts=$(node_ts_cli)
  if [ -n "$ts" ]; then
    if "$ts" logout >/dev/null 2>&1; then ok "tailscale logged out"; else warn "tailscale logout failed; run it manually"; fi
  else
    warn "tailscale not found; log the device out from the admin console"
  fi
  rm -f "$FLEET_HOME/daemon.pid"
  ok "left"
}

# ---------- daemon (containers, PID 1 safe) ----------

NODE_DAEMON_STOP=0
NODE_DAEMON_CHILD=""

node_job_args() {
  case $1 in
    pull) echo "pull" ;;
    memory) echo "memory sync" ;;
    update) echo "update" ;;
    *) die "unknown job: $1" ;;
  esac
}

node_job_minutes() {
  case $1 in
    pull) echo "${FLEET_PULL_EVERY:-15}" ;;
    memory) echo "${FLEET_MEMORY_EVERY:-5}" ;;
    update) echo "${FLEET_UPDATE_EVERY:-1440}" ;;
    *) echo 60 ;;
  esac
}

node_daemon_term() {
  NODE_DAEMON_STOP=1
  [ -n "$NODE_DAEMON_CHILD" ] && kill "$NODE_DAEMON_CHILD" 2>/dev/null
  return 0
}

# node_daemon_fleet — the `fleet` the daemon dispatches jobs to: the installed
# checkout through ~/.local/bin/fleet (what `fleet pull` keeps current), and
# the daemon's own copy (/opt/fleet in the image) only until that link exists.
node_daemon_fleet() {
  if [ -x "$FLEET_BIN/fleet" ]; then echo "$FLEET_BIN/fleet"; else echo "$FLEET_ROOT/fleet"; fi
}

# Runs a job as a child in the background and waits, so a signal interrupts the
# wait, the trap runs, and the child is killed promptly.
node_daemon_run() {
  local job=$1 rc=0
  # shellcheck disable=SC2046
  "$(node_daemon_fleet)" $(node_job_args "$job") >>"$FLEET_HOME/logs/$job.log" 2>&1 &
  NODE_DAEMON_CHILD=$!
  wait "$NODE_DAEMON_CHILD" || rc=$?
  NODE_DAEMON_CHILD=""
  [ "$rc" -eq 0 ] || warn "daemon: job $job exited $rc (see $FLEET_HOME/logs/$job.log)"
  return 0
}

# node_daemon_code_rev — identifies the code the daemon should be running:
# the checkout's HEAD once ~/.local/bin/fleet points at one, else empty.
node_daemon_code_rev() {
  [ -x "$FLEET_BIN/fleet" ] && node_code_commit
  return 0
}

cmd_daemon() {
  local now last every job i rev0 rev
  mkdir -p "$FLEET_HOME/logs"
  echo $$ | atomic_write "$FLEET_HOME/daemon.pid" 0600
  trap node_daemon_term TERM INT
  rev0=$(node_daemon_code_rev)
  log "fleet daemon started (pid $$, $FLEET_ROOT${rev0:+ at ${rev0}}); jobs: $(node_jobs | tr '\n' ' ')"
  while [ "$NODE_DAEMON_STOP" -eq 0 ]; do
    now=$(date +%s)
    for job in $(node_jobs); do
      [ "$NODE_DAEMON_STOP" -eq 0 ] || break
      last=$(node_kv_get "$FLEET_HOME/daemon.state" "$job"); : "${last:=0}"
      every=$(node_job_minutes "$job")
      if [ $((now - last)) -ge $((every * 60)) ]; then
        node_daemon_run "$job"
        node_kv_set "$FLEET_HOME/daemon.state" "$job" "$(date +%s)"
        # A pull that moved the code checkout (or created it): replace this
        # process with the new code. exec keeps the PID, so daemon.pid and the
        # container supervisor stay valid; daemon.state keeps the schedule.
        if [ "$job" = pull ] && [ "$NODE_DAEMON_STOP" -eq 0 ]; then
          rev=$(node_daemon_code_rev)
          if [ -n "$rev" ] && [ "$rev" != "$rev0" ]; then
            log "fleet daemon: code updated (${rev0:-none} -> $rev); re-executing $FLEET_BIN/fleet daemon"
            trap - TERM INT
            exec "$FLEET_BIN/fleet" daemon
          fi
        fi
      fi
    done
    i=0
    while [ "$i" -lt 60 ] && [ "$NODE_DAEMON_STOP" -eq 0 ]; do
      sleep 1 &
      NODE_DAEMON_CHILD=$!
      wait "$NODE_DAEMON_CHILD" 2>/dev/null || true
      NODE_DAEMON_CHILD=""
      i=$((i + 1))
    done
  done
  log "fleet daemon stopping"
  # Reap anything still attached (PID 1 duty) before leaving.
  wait 2>/dev/null || true
  trap - TERM INT
  # Our own exit path: leave must not signal this very process (env guard).
  FLEET_LEAVE_FROM_DAEMON=1 cmd_leave || true
  exit 0
}

# ---------- schedules ----------

node_systemd_user_ok() {
  have systemctl && systemctl --user show-environment >/dev/null 2>&1
}

node_cron_expr() {
  local m=$1 h
  if [ "$m" -lt 60 ]; then printf '*/%s * * * *\n' "$m"
  else
    h=$((m / 60))
    if [ "$h" -lt 24 ]; then printf '0 */%s * * *\n' "$h"; else printf '0 3 * * *\n'; fi
  fi
}

node_launchagent_plist() {
  local job=$1 secs=$2 args a
  args=$(node_job_args "$job")
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.fleet.$job</string>
  <key>ProgramArguments</key>
  <array>
    <string>$FLEET_BIN/fleet</string>
EOF
  for a in $args; do printf '    <string>%s</string>\n' "$a"; done
  cat <<EOF
  </array>
  <key>StartInterval</key><integer>$secs</integer>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$HOME/.local/bin:$HOME/.local/share/mise/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>StandardOutPath</key><string>$FLEET_HOME/logs/$job.log</string>
  <key>StandardErrorPath</key><string>$FLEET_HOME/logs/$job.log</string>
</dict>
</plist>
EOF
}

node_schedule_install_macos() {
  local job secs plist tmp uid label
  uid=$(id -u)
  mkdir -p "$HOME/Library/LaunchAgents" "$FLEET_HOME/logs"
  for job in $NODE_JOBS; do
    label="dev.fleet.$job"; plist="$HOME/Library/LaunchAgents/$label.plist"
    if ! node_job_enabled "$job"; then      # a job switched off since the last apply loses its agent
      [ -f "$plist" ] || continue
      launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
      rm -f "$plist"; ok "schedule $label removed (job disabled)"
      continue
    fi
    secs=$(( $(node_job_minutes "$job") * 60 ))
    tmp=$(mktemp "$HOME/Library/LaunchAgents/.fleet.XXXXXX")
    node_launchagent_plist "$job" "$secs" >"$tmp"
    if [ -f "$plist" ] && cmp -s "$tmp" "$plist" && launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
      rm -f "$tmp"; continue
    fi
    [ -n "${FLEET_NO_SCHEDULER:-}" ] || launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
    chmod 0644 "$tmp"; mv -f "$tmp" "$plist"
    if [ -n "${FLEET_NO_SCHEDULER:-}" ]; then
      ok "schedule $label written, not loaded (FLEET_NO_SCHEDULER)"
    elif launchctl bootstrap "gui/$uid" "$plist" >/dev/null 2>&1 || launchctl load -w "$plist" >/dev/null 2>&1; then
      ok "schedule $label every ${secs}s"
    else
      warn "could not load $plist (launchctl); it will load at next login"
    fi
    node_manifest_add "$plist"
  done
}

node_schedule_remove_macos() {
  local job uid plist
  uid=$(id -u)
  for job in $NODE_JOBS; do
    plist="$HOME/Library/LaunchAgents/dev.fleet.$job.plist"
    launchctl bootout "gui/$uid/dev.fleet.$job" >/dev/null 2>&1 || launchctl unload "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
  done
}

node_schedule_install_systemd() {
  local job mins udir args
  udir="$HOME/.config/systemd/user"
  mkdir -p "$udir" "$FLEET_HOME/logs"
  for job in $NODE_JOBS; do
    if ! node_job_enabled "$job"; then      # a job switched off since the last apply loses its timer
      [ -f "$udir/fleet-$job.timer" ] || continue
      [ -n "${FLEET_NO_SCHEDULER:-}" ] || systemctl --user disable --now "fleet-$job.timer" >/dev/null 2>&1 || true
      rm -f "$udir/fleet-$job.service" "$udir/fleet-$job.timer"; ok "schedule fleet-$job.timer removed (job disabled)"
      continue
    fi
    mins=$(node_job_minutes "$job"); args=$(node_job_args "$job")
    printf '%s\n' "[Unit]" "Description=fleet $job" "" "[Service]" "Type=oneshot" \
      "Environment=PATH=%h/.local/bin:%h/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin" \
      "ExecStart=$FLEET_BIN/fleet $args" | atomic_write "$udir/fleet-$job.service" 0644
    printf '%s\n' "[Unit]" "Description=fleet $job timer" "" "[Timer]" "OnBootSec=2min" "OnUnitActiveSec=${mins}min" \
      "Persistent=true" "" "[Install]" "WantedBy=timers.target" | atomic_write "$udir/fleet-$job.timer" 0644
    node_manifest_add "$udir/fleet-$job.service"; node_manifest_add "$udir/fleet-$job.timer"
  done
  if [ -n "${FLEET_NO_SCHEDULER:-}" ]; then ok "schedules written to $udir, not enabled (FLEET_NO_SCHEDULER)"; return 0; fi
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  for job in $(node_jobs); do
    if systemctl --user enable --now "fleet-$job.timer" >/dev/null 2>&1; then ok "schedule fleet-$job.timer"; else warn "could not enable fleet-$job.timer"; fi
  done
}

node_schedule_remove_systemd() {
  local job udir
  udir="$HOME/.config/systemd/user"
  for job in $NODE_JOBS; do
    systemctl --user disable --now "fleet-$job.timer" >/dev/null 2>&1 || true
    rm -f "$udir/fleet-$job.service" "$udir/fleet-$job.timer"
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

node_schedule_install_cron() {
  local job expr args lines=""
  for job in $(node_jobs); do
    expr=$(node_cron_expr "$(node_job_minutes "$job")"); args=$(node_job_args "$job")
    lines="$lines$expr $FLEET_BIN/fleet $args >>$FLEET_HOME/logs/$job.log 2>&1 # fleet:$job
"
  done
  if [ -n "${FLEET_NO_SCHEDULER:-}" ]; then
    printf '%s' "$lines" | atomic_write "$FLEET_HOME/crontab.fleet" 0600
    ok "crontab lines written to $FLEET_HOME/crontab.fleet, not installed (FLEET_NO_SCHEDULER)"
    return 0
  fi
  if { crontab -l 2>/dev/null | grep -v '# fleet:' || true; printf '%s' "$lines"; } | crontab -; then
    ok "schedules installed in crontab"
  else
    warn "could not write crontab"
  fi
}

node_schedule_remove_cron() {
  { crontab -l 2>/dev/null | grep -v '# fleet:' || true; } | crontab - 2>/dev/null || true
}

node_schedule_install() {
  case "$(fleet_os)" in
    macos) node_schedule_install_macos ;;
    linux)
      if node_systemd_user_ok; then node_schedule_install_systemd
      elif have crontab; then node_schedule_install_cron
      else warn "no systemd user session and no crontab; run 'fleet daemon' to schedule jobs"
      fi ;;
    *) warn "schedules: unsupported OS" ;;
  esac
}

node_schedule_remove() {
  case "$(fleet_os)" in
    macos) node_schedule_remove_macos ;;
    linux)
      if node_systemd_user_ok; then node_schedule_remove_systemd; fi
      if have crontab; then node_schedule_remove_cron; fi ;;
  esac
  return 0
}

# ---------- keep awake ----------

# A node is only useful while it is reachable and syncing, so FLEET_KEEP_AWAKE
# (default 1) keeps it out of system sleep. Never on the master (it may sleep)
# and never in a container (no power management). macOS: the LaunchAgent
# dev.fleet.awake runs `caffeinate -i -m -s` (no idle, disk or system sleep on
# AC power; the display may still sleep) for as long as the user is logged in;
# `fleet join` adds the pmset settings that cover logout and reboots
# (join_power). Linux: the sleep targets are masked by `fleet join` (root);
# apply only reports. Status: node_awake_state → on | off | n/a.

NODE_AWAKE_LABEL="dev.fleet.awake"

node_keep_awake() {
  [ "${FLEET_KEEP_AWAKE:-1}" != 0 ] && ! fleet_is_master && ! fleet_in_container
}

node_awake_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$NODE_AWAKE_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-i</string>
    <string>-m</string>
    <string>-s</string>
  </array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
}

# Same bootstrap logic as the job agents: rewritten and reloaded only when the
# content changed or the agent is not loaded; FLEET_NO_SCHEDULER writes only.
node_awake_install_macos() {
  local plist tmp uid label=$NODE_AWAKE_LABEL
  uid=$(id -u); plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  tmp=$(mktemp "$HOME/Library/LaunchAgents/.fleet.XXXXXX")
  node_awake_plist >"$tmp"
  if [ -f "$plist" ] && cmp -s "$tmp" "$plist" && launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    rm -f "$tmp"; return 0
  fi
  [ -n "${FLEET_NO_SCHEDULER:-}" ] || launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
  chmod 0644 "$tmp"; mv -f "$tmp" "$plist"
  if [ -n "${FLEET_NO_SCHEDULER:-}" ]; then
    ok "keep awake: $label written, not loaded (FLEET_NO_SCHEDULER)"
  elif launchctl bootstrap "gui/$uid" "$plist" >/dev/null 2>&1 || launchctl load -w "$plist" >/dev/null 2>&1; then
    ok "keep awake: $label loaded (caffeinate -i -m -s; the display may still sleep)"
  else
    warn "could not load $plist (launchctl); it will load at next login"
  fi
  node_manifest_add "$plist"
}

# Only acts when the plist is there (we always write it before loading), so a
# machine that never had the agent sees no launchctl call.
node_awake_remove_macos() {
  local uid plist="$HOME/Library/LaunchAgents/$NODE_AWAKE_LABEL.plist"
  [ -f "$plist" ] || return 0
  uid=$(id -u)
  launchctl bootout "gui/$uid/$NODE_AWAKE_LABEL" >/dev/null 2>&1 || launchctl unload "$plist" >/dev/null 2>&1 || true
  rm -f "$plist"
  ok "keep awake: $NODE_AWAKE_LABEL removed"
}

# node_awake_apply — converge: the agent is installed while node_keep_awake and
# removed otherwise (FLEET_KEEP_AWAKE=0 on a later apply). Nothing privileged.
node_awake_apply() {
  if fleet_is_master || fleet_in_container; then return 0; fi
  case "$(fleet_os)" in
    macos)
      if node_keep_awake; then node_awake_install_macos; else node_awake_remove_macos; fi
      node_awake_lid_report ;;
    linux)
      if node_keep_awake && have systemctl && [ "$(node_awake_state)" = off ]; then
        log "keep awake: sleep targets not masked; rerun the join one-liner or: sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target"
      fi ;;
  esac
  return 0
}

node_awake_remove() {
  if fleet_is_master || fleet_in_container; then return 0; fi
  [ "$(fleet_os)" = macos ] && node_awake_remove_macos
  return 0
}

# node_pmset_ac_sleep — the `sleep` value of the charger (AC) profile, "" when unknown.
node_pmset_ac_sleep() {
  pmset -g custom 2>/dev/null | awk '/^AC Power:/ {ac=1; next} /^Battery Power:/ {ac=0} ac && $1 == "sleep" {print $2; exit}'
}

# node_awake_state — on | off | n/a (CONTRACT "fleet status --json"). macOS: the
# agent is loaded, or pmset says no system sleep on AC; Linux: sleep.target masked.
node_awake_state() {
  if fleet_is_master || fleet_in_container; then echo n/a; return 0; fi
  case "$(fleet_os)" in
    macos)
      if have launchctl && launchctl print "gui/$(id -u)/$NODE_AWAKE_LABEL" >/dev/null 2>&1; then echo on; return 0; fi
      if have pmset && [ "$(node_pmset_ac_sleep)" = 0 ]; then echo on; return 0; fi
      echo off ;;
    linux)
      if have systemctl && [ "$(systemctl is-enabled sleep.target 2>/dev/null)" = masked ]; then echo on; else echo off; fi ;;
    *) echo n/a ;;
  esac
}

# ---------- lid closed (FLEET_KEEP_AWAKE_LID) ----------

# The pmset -c settings from join and the caffeinate agent do not stop a
# MacBook from sleeping when its lid is closed without an external display
# (macOS clamshell rule). `pmset -a disablesleep 1` does, and is root-only, so
# `fleet join` sets it when FLEET_KEEP_AWAKE_LID=1 on a laptop (join_power_lid
# in lib/join.sh) and records `+lid` in ~/.config/fleet/power_done. Apply
# cannot sudo: it only reports, and status shows the undo command.

# node_awake_lid_state — on | off | n/a: `pmset -g` lists `SleepDisabled 1`
# while system sleep is disabled outright. macOS nodes only.
node_awake_lid_state() {
  if fleet_is_master || fleet_in_container; then echo n/a; return 0; fi
  case "$(fleet_os)" in
    macos)
      have pmset || { echo n/a; return 0; }
      if pmset -g 2>/dev/null | awk '$1 == "SleepDisabled" { f = ($2 == "1") } END { exit !f }'; then echo on; else echo off; fi ;;
    *) echo n/a ;;
  esac
}

# node_awake_lid_report — apply's pointer when the knob and the Mac disagree:
# the setting is root-only, so apply never changes it.
node_awake_lid_report() {
  local state marker="$FLEET_HOME/power_done"
  have pmset || return 0
  state=$(node_awake_lid_state)
  if [ "${FLEET_KEEP_AWAKE_LID:-0}" = 1 ] && [ "$state" = off ]; then
    log "keep awake: FLEET_KEEP_AWAKE_LID=1 but sleep with the lid closed is still allowed; rerun the join one-liner or: sudo pmset -a disablesleep 1"
  elif [ "${FLEET_KEEP_AWAKE_LID:-0}" != 1 ] && [ "$state" = on ] && grep -q '+lid' "$marker" 2>/dev/null; then
    log "keep awake: lid-closed sleep is still disabled (set at join; FLEET_KEEP_AWAKE_LID is now 0); undo: sudo pmset -a disablesleep 0"
  fi
  return 0
}

# ---------- LAN addresses (fleet unlock) ----------

# A FileVault Mac that restarted waits at its pre-boot prompt with no
# Tailscale, so the master can only reach it over the LAN (`fleet unlock`,
# apple_ssh_and_filevault(7)). Status therefore reports this node's LAN IPv4
# addresses and whether one of them is on an Ethernet port (Wi-Fi is often
# not up in pre-boot); the master records both in the registry.

# node_lan_ifaces — "<device><TAB><hardware port>" per physical interface.
# macOS: `networksetup -listallhardwareports` (ports such as "Ethernet",
# "Thunderbolt Ethernet", "USB 10/100/1000 LAN", "Wi-Fi"; no utun/tailscale).
# Linux: /sys/class/net, "Wi-Fi" when the interface has a wireless dir;
# virtual interfaces (tailscale, docker, bridges, veth) skipped.
node_lan_ifaces() {
  local d
  case "$(fleet_os)" in
    macos)
      have networksetup || return 0
      networksetup -listallhardwareports 2>/dev/null | awk -F': ' '/^Hardware Port: / { p = $2 } /^Device: / { print $2 "\t" p }' ;;
    linux)
      for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        d=$(basename "$d")
        case "$d" in lo|tailscale*|docker*|br-*|veth*|virbr*|utun*) continue ;; esac
        if [ -d "/sys/class/net/$d/wireless" ]; then printf '%s\tWi-Fi\n' "$d"; else printf '%s\tEthernet\n' "$d"; fi
      done ;;
  esac
  return 0
}

# node_iface_ip DEVICE — its IPv4 address, or nothing.
node_iface_ip() {
  case "$(fleet_os)" in
    macos) ipconfig getifaddr "$1" 2>/dev/null || true ;;
    linux)
      if have ip; then ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{ print $4; exit }' | cut -d/ -f1
      elif have ifconfig; then ifconfig "$1" 2>/dev/null | awk '$1 == "inet" { sub(/^addr:/, "", $2); print $2; exit }'
      fi ;;
  esac
  return 0
}

# node_lan_info — "<ip>[,<ip>...]<TAB>yes|no": every LAN IPv4 address and
# whether one of them is on a port that is not Wi-Fi. Loopback, link-local and
# the tailnet's CGNAT range (100.64/10) are never LAN addresses. Containers:
# none (the master cannot unlock a container).
node_lan_info() {
  local dev port ip ips="" eth=no
  if fleet_in_container; then printf '\tno\n'; return 0; fi
  while IFS="$(printf '\t')" read -r dev port; do
    [ -n "$dev" ] || continue
    ip=$(node_iface_ip "$dev")
    [ -n "$ip" ] || continue
    case "$ip" in 127.*|169.254.*) continue ;; esac
    case "$ip" in 100.*) if [ "$(printf '%s' "$ip" | cut -d. -f2)" -ge 64 ] && [ "$(printf '%s' "$ip" | cut -d. -f2)" -le 127 ]; then continue; fi ;; esac
    ips="$ips${ips:+,}$ip"
    case "$port" in *Wi-Fi*|*WLAN*|*Wireless*|*AirPort*) ;; *) eth=yes ;; esac
  done <<EOF
$(node_lan_ifaces)
EOF
  printf '%s\t%s\n' "$ips" "$eth"
}
