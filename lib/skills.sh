# shellcheck shell=bash
# lib/skills.sh — fleet-wide skill management. Sourced by ./fleet; functions only.
#
#   fleet skill add SOURCE [--name N] [--yes]   master: a local dir or a git URL
#                         (https/ssh, optional #subdir and @ref) into
#                         $FLEET_CONFIG_DIR/skills/N, installed here too,
#                         secret-scanned, committed, pushed, pushed to the nodes.
#   fleet skill list [--json]                   master and node.
#   fleet skill remove N [--yes]                master: out of the config repo and
#                         this machine; nodes drop it on their next apply
#                         (harness.manifest cleanup in lib/harness.sh).
#   sync_publish_skills   run by `fleet sync` (FLEET_SYNC_PUBLISH_SKILLS=1):
#                         skills installed here but missing from / differing in
#                         the config repo are copied in, scanned, committed and
#                         pushed without a prompt. Never deletes from the repo.
#
# Portability: bash 3.2, python3 stdlib only, no sed -i, no GNU flags. The
# helpers from lib/harness.sh (skill targets, install dir, manifests, secret
# scan, tree digest) are reused so the master and the nodes agree on paths.

# ---------- python helper ----------

skill_py() {
  python3 - "$@" <<'PY'
import json, os, re, shutil, sys

def frontmatter(path):
    # YAML frontmatter as plain key: value lines (folded/literal blocks joined); None when absent.
    try:
        lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
    except Exception:
        return None
    if not lines or lines[0].strip() != '---':
        return None
    fm, key = {}, None
    for line in lines[1:]:
        if line.strip() == '---':
            return fm
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$', line)
        if m:
            key, v = m.group(1), m.group(2).strip()
            if v in ('>', '|', '>-', '|-'):
                v = ''
            elif len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
                v = v[1:-1]
            fm[key] = v
        elif key and line.startswith((' ', '\t')):
            fm[key] = (fm[key] + ' ' + line.strip()).strip()
    return None   # unterminated

def cmd_frontmatter(argv):
    # FILE KEY: prints the value; exit 1 when there is no frontmatter, 2 when the key is missing.
    fm = frontmatter(argv[0])
    if fm is None: sys.exit(1)
    if argv[1] not in fm or not fm[argv[1]]: sys.exit(2)
    print(fm[argv[1]])

def cmd_copy(argv):
    # SRC DST: replace DST with a copy of SRC without .git, .DS_Store, node_modules, __pycache__.
    src, dst = argv
    if os.path.islink(dst) or os.path.isfile(dst): os.remove(dst)
    elif os.path.isdir(dst): shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=False,
                    ignore=lambda d, names: set(n for n in names if n in ('.git', '.DS_Store', 'node_modules', '__pycache__')))

def cmd_render(argv):
    # MODE(table|json) ROLE(master|node) WIDTH ROWFILE — rows "name\tsource\tpath\ton_nodes"
    # (a file: stdin carries this script)
    mode, role, width = argv[0], argv[1], int(argv[2])
    rows = []
    for line in open(argv[3], encoding='utf-8', errors='replace'):
        parts = line.rstrip('\n').split('\t')
        if len(parts) < 4 or not parts[0]: continue
        name, source, path, on_nodes = parts[:4]
        fm = frontmatter(os.path.join(path, 'SKILL.md')) or {}
        rows.append({'name': name, 'source': source, 'description': fm.get('description', ''),
                     'on_nodes': on_nodes if role == 'master' else None, 'path': path})
    rows.sort(key=lambda r: (r['source'] != 'config', r['source'] != 'fleet', r['name']))
    if mode == 'json':
        if role != 'master':
            for r in rows: r.pop('on_nodes')
        print(json.dumps(rows, indent=2, sort_keys=True)); return
    head = ['NAME', 'SOURCE'] + (['ON NODES?'] if role == 'master' else []) + ['DESCRIPTION']
    table = [[r['name'], r['source']] + ([r['on_nodes']] if role == 'master' else []) + [r['description'] or '-'] for r in rows]
    widths = [len(h) for h in head]
    for row in table:
        for i, c in enumerate(row[:-1]): widths[i] = max(widths[i], len(c))
    room = max(20, width - sum(widths[:-1]) - 2 * (len(head) - 1))
    def fmt(row):
        cells = [c.ljust(widths[i]) for i, c in enumerate(row[:-1])]
        last = row[-1] if len(row[-1]) <= room else row[-1][:room - 3].rstrip() + '...'
        return '  '.join(cells + [last]).rstrip()
    print(fmt(head))
    for row in table: print(fmt(row))

{'frontmatter': cmd_frontmatter, 'copy': cmd_copy, 'render': cmd_render}[sys.argv[1]](sys.argv[2:])
PY
}

# ---------- small helpers ----------

# skill_name_valid NAME — the directory name a skill may have.
skill_name_valid() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,63}$'; }

# skill_frontmatter DIR KEY — the frontmatter value of DIR/SKILL.md, or nothing.
skill_frontmatter() { skill_py frontmatter "$1/SKILL.md" "$2" 2>/dev/null || true; }

# skill_validate DIR — DIR/SKILL.md exists and has frontmatter with a name; prints the name.
skill_validate() {
  local dir=$1 name rc=0
  [ -f "$dir/SKILL.md" ] || die "no SKILL.md in $dir" "a skill is a directory with a SKILL.md (YAML frontmatter: name, description)"
  name=$(skill_py frontmatter "$dir/SKILL.md" name 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    1) die "$dir/SKILL.md has no YAML frontmatter" "start the file with --- / name: NAME / description: ... / ---" ;;
    *) die "$dir/SKILL.md has no name: in its frontmatter" "add name: NAME, or pass --name N" ;;
  esac
  printf '%s\n' "$name"
}

# skill_tree_digest DIR — content hash of a skill dir (.git, caches and .DS_Store ignored).
skill_tree_digest() { harness_py tree-digest "$1"; }

# skill_excluded NAME — never auto-published or listed as local-only: vendor
# caches, hidden dirs, the bundled `fleet` skill and FLEET_SKILL_EXCLUDE.
skill_excluded() {
  local n
  case "$1" in synced|.system|fleet|.*) return 0 ;; esac
  for n in ${FLEET_SKILL_EXCLUDE:-}; do [ "$n" = "$1" ] && return 0; done
  return 1
}

# skill_local_dirs — the harness skill dirs that exist in $HOME (capture reads the same four).
skill_local_dirs() {
  local d
  for d in .claude/skills .agents/skills .codex/skills .cursor/skills; do
    [ -d "$HOME/$d" ] && echo "$HOME/$d"
  done
  return 0
}

# skill_manifest_drop PATH FILE — forget a path fleet wrote (manifest cleanup lists).
skill_manifest_drop() {
  [ -f "$2" ] || return 0
  grep -qxF "$1" "$2" || return 0
  { grep -vxF "$1" "$2" || true; } | atomic_write "$2" 0600
}

# skill_local_install NAME SRC — SRC into every enabled skill dir of this machine
# (same targets and manifests as `fleet skill install`). Prints "<dirs> <changed>".
skill_local_install() {
  local name=$1 src=$2 tgt dest r n=0 changed=0
  for tgt in $(harness_skill_targets); do
    dest="$HOME/$tgt/$name"
    r=$(_harness_install_dir "$src" "$dest")
    _harness_manifest_add "$dest"
    _harness_manifest_add "$dest" "$FLEET_HOME/harness.manifest"
    n=$((n + 1)); [ -n "$r" ] && changed=$((changed + 1))
  done
  echo "$n $changed"
}

# skill_local_remove NAME — delete the copies in this machine's skill dirs (a
# symlink is unlinked, never followed) and drop them from the manifests. Prints the count.
skill_local_remove() {
  local name=$1 tgt dest n=0
  for tgt in .claude/skills .agents/skills .cursor/skills; do
    dest="$HOME/$tgt/$name"
    if [ -L "$dest" ]; then rm -f "$dest"
    elif [ -d "$dest" ]; then rm -rf "$dest"
    else continue; fi
    skill_manifest_drop "$dest" "$FLEET_HOME/manifest"
    skill_manifest_drop "$dest" "$FLEET_HOME/harness.manifest"
    n=$((n + 1))
  done
  echo "$n"
}

# ---------- sources ----------

# skill_source_is_git SOURCE — a URL or a bare-repo path rather than a skill directory.
skill_source_is_git() {
  case "$1" in
    *://*|git@*:*|*.git|*.git[#@]*) return 0 ;;
    *) return 1 ;;
  esac
}

# skill_source_parse SOURCE — sets _SKILL_URL, _SKILL_SUBDIR, _SKILL_REF from
# URL#subdir@ref, URL#subdir or URL@ref. The @ of an ssh URL (git@host:...) is
# never taken for a ref.
_SKILL_URL=""; _SKILL_SUBDIR=""; _SKILL_REF=""
skill_source_parse() {
  local url=$1 rest="" subdir="" ref="" tail
  case "$url" in *'#'*) rest=${url#*#}; url=${url%%#*} ;; esac
  if [ -n "$rest" ]; then
    case "$rest" in *@*) ref=${rest##*@}; subdir=${rest%@*} ;; *) subdir=$rest ;; esac
  else
    tail=${url##*/}; tail=${tail##*:}
    case "$tail" in *@*) ref=${tail##*@}; url=${url%@*} ;; esac
  fi
  _SKILL_URL=$url; _SKILL_SUBDIR=$subdir; _SKILL_REF=$ref
}

_SKILL_TMP=""; _SKILL_SRC=""
skill_tmp_cleanup() { [ -n "$_SKILL_TMP" ] && rm -rf "$_SKILL_TMP"; _SKILL_TMP=""; return 0; }

# skill_fetch SOURCE — sets _SKILL_SRC to the skill directory: SOURCE itself
# for a local dir, otherwise a shallow clone (optional @ref, #subdir) in a 0700
# temp dir that skill_tmp_cleanup removes (also from the EXIT trap). Not a
# command substitution on purpose: a subshell's exit would run that trap.
skill_fetch() {
  local src=$1 url subdir ref dir
  if [ -d "$src" ]; then _SKILL_SRC=$(abspath "$src"); return 0; fi
  skill_source_is_git "$src" || die "not a directory and not a git URL: $src" "fleet skill add DIR | fleet skill add https://host/owner/repo.git[#subdir][@ref]"
  need git
  skill_source_parse "$src"
  url=$_SKILL_URL; subdir=$_SKILL_SUBDIR; ref=$_SKILL_REF
  case "$subdir" in /*|*..*) die "invalid subdir in $src: $subdir" ;; esac
  _SKILL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fleet-skill.XXXXXX"); chmod 0700 "$_SKILL_TMP"
  trap skill_tmp_cleanup EXIT
  log "cloning $url${ref:+ @$ref}${subdir:+ ($subdir)}"
  if [ -n "$ref" ]; then
    if ! GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch "$ref" "$url" "$_SKILL_TMP/repo" 2>/dev/null; then
      # a commit id is not a branch/tag: full clone, then check it out
      GIT_TERMINAL_PROMPT=0 git clone --quiet "$url" "$_SKILL_TMP/repo" 2>/dev/null || die "git clone $url failed" "check the URL and your access to the repo"
      git -C "$_SKILL_TMP/repo" checkout --quiet "$ref" 2>/dev/null || die "no branch, tag or commit $ref in $url"
    fi
  else
    GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 "$url" "$_SKILL_TMP/repo" 2>/dev/null || die "git clone $url failed" "check the URL and your access to the repo"
  fi
  dir="$_SKILL_TMP/repo${subdir:+/$subdir}"
  [ -d "$dir" ] || die "no directory $subdir in $url" "name the skill's directory after #, e.g. $url#skills/NAME"
  _SKILL_SRC=$dir
}

# ---------- config repo ----------

# skill_repo_check — the config checkout is a git repo with an identity (like config publish).
skill_repo_check() {
  local dir=$FLEET_CONFIG_DIR
  need git; need python3
  config_dir_require
  [ -d "$dir/.git" ] || die "$dir is not a git checkout" "git -C $dir init && git -C $dir remote add origin \$FLEET_CONFIG_REPO"
  [ -n "$(git -C "$dir" config --get user.name 2>/dev/null)" ] && [ -n "$(git -C "$dir" config --get user.email 2>/dev/null)" ] \
    || die "git has no identity for $dir (user.name / user.email)" \
      "git config --global user.name 'Your Name' && git config --global user.email you@example.com   (or set them in that repo), then rerun"
}

# skill_repo_push — push the config checkout to its origin (BatchMode, no prompt).
# Prints pushed | no-remote | failed; a missing remote only warns.
skill_repo_push() {
  local dir=$FLEET_CONFIG_DIR remote ahead
  remote=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  if [ -z "$remote" ]; then
    warn "no origin remote in $dir; nodes cannot pull it until you add one: git -C $dir remote add origin ${FLEET_CONFIG_REPO:-<FLEET_CONFIG_REPO>}"
    echo no-remote; return 0
  fi
  ahead=$(git -C "$dir" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 1)
  [ "$ahead" = 0 ] && { echo pushed; return 0; }
  if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" git -C "$dir" push -q -u origin HEAD; then
    echo pushed
  else
    echo failed
  fi
}

# skill_push_nodes VERB — provision the nodes now (fleet reconcile; skipped
# with FLEET_SKILL_ADD_NO_SYNC=1 or while another sync holds the master lock)
# and report how many got it: "pushed to K nodes" or the next-pull line.
skill_push_nodes() {
  local verb=$1 n0=0 n1=0 k
  if [ "${FLEET_SKILL_ADD_NO_SYNC:-0}" = 1 ]; then log "FLEET_SKILL_ADD_NO_SYNC=1: not pushing to the nodes now"; return 0; fi
  [ -f "$FLEET_VAULT/audit.log" ] && n0=$(grep -c ' provision [^ ]* ok' "$FLEET_VAULT/audit.log" || true)
  cmd_reconcile || true
  [ -f "$FLEET_VAULT/audit.log" ] && n1=$(grep -c ' provision [^ ]* ok' "$FLEET_VAULT/audit.log" || true)
  k=$((n1 - n0))
  if [ "$k" -gt 0 ]; then ok "pushed to $k node$([ "$k" = 1 ] || echo s)"
  else ok "nodes $verb it on their next pull"; fi
}

# ---------- fleet skill add ----------

# fleet skill add SOURCE [--name N] [--yes] — see the header. The secret scan
# runs on the source before anything is copied; an existing skill of the same
# name with different content is only replaced with --yes; identical = no-op.
cmd_skill_add() {
  local source="" name="" yes=0 src fmname dir dest existed=0 action scan n_staged remote r
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name=${2:-}; [ -n "$name" ] || die "--name needs a value"; shift ;;
      --yes|-y) yes=1 ;;
      -*) die "unknown flag: $1" "usage: fleet skill add SOURCE [--name N] [--yes]" ;;
      *) source=$1 ;;
    esac; shift
  done
  [ -n "$source" ] || die "usage: fleet skill add SOURCE [--name N] [--yes]" "SOURCE = a directory with a SKILL.md, or a git URL (https/ssh) with optional #subdir and @ref"
  vault_require
  skill_repo_check
  dir=$FLEET_CONFIG_DIR
  skill_fetch "$source"; src=$_SKILL_SRC
  fmname=$(skill_validate "$src")
  [ -n "$name" ] || name=$fmname
  skill_name_valid "$name" || die "invalid skill name: $name" "use [a-z0-9][a-z0-9-]{0,63}; pass --name N to override the SKILL.md name"
  [ "$name" = "$fmname" ] || log "installing $fmname as $name (--name)"
  # the scan first: nothing of a leaking skill reaches the repo or this machine's skill dirs
  if ! scan=$(harness_secret_scan "$src" 2>&1); then
    printf '%s\n' "$scan" >&2
    die "secrets or machine paths found in $source; nothing added" "remove them from the skill (or template them as \${VAR}), then rerun"
  fi
  dest="$dir/skills/$name"
  if [ -d "$dest" ]; then
    existed=1
    if [ "$(skill_tree_digest "$src")" = "$(skill_tree_digest "$dest")" ]; then
      r=$(skill_local_install "$name" "$dest")
      ok "$name is already in your fleet config (unchanged; installed here in ${r%% *} dir(s))"
      skill_tmp_cleanup
      return 0
    fi
    [ "$yes" = 1 ] || die "skill $name already exists in your fleet config with different content" "rerun with --yes to replace it, or --name OTHER to add it under another name"
  fi
  skill_py copy "$src" "$dest" || die "could not copy $src into $dest"
  git -C "$dir" add -A -- "skills/$name"
  n_staged=$(git -C "$dir" diff --cached --name-only | grep -c . || true)
  if [ "$n_staged" = 0 ]; then
    ok "$name is already in your fleet config (unchanged)"; skill_tmp_cleanup; return 0
  fi
  if [ "$existed" = 1 ]; then action=update; else action=add; fi
  remote=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  if [ "$yes" != 1 ]; then
    git -C "$dir" --no-pager diff --cached --stat >&2
    printf '%s skill %s in %s and push to %s? [y/N] ' "$([ "$action" = add ] && echo Add || echo Update)" "$name" "$dir" "${remote:-<no remote>}" >&2
    IFS= read -r r || true
    case "$r" in y|Y|yes) ;; *)
      git -C "$dir" reset -q -- "skills/$name"
      if [ "$existed" = 1 ]; then git -C "$dir" checkout -q -- "skills/$name"; git -C "$dir" clean -qfd -- "skills/$name"; else rm -rf "$dest"; fi
      skill_tmp_cleanup
      die "aborted; nothing added" "rerun with --yes to skip the question" ;;
    esac
  fi
  git -C "$dir" commit -q -m "$action skill $name"
  r=$(skill_local_install "$name" "$dest")
  if [ "$action" = add ]; then ok "added $name to your fleet config"; else ok "updated $name in your fleet config"; fi
  [ "${r%% *}" = 0 ] && log "no harness skill dir on this machine (no ~/.claude, ~/.agents, ~/.cursor; nothing in FLEET_TOOLS): not installed here"
  skill_tmp_cleanup
  case "$(skill_repo_push)" in
    pushed) ok "published (secret scan clean)"; audit "skill.$action" "$name" pushed ;;
    no-remote) ok "committed $(git -C "$dir" rev-parse --short HEAD) (secret scan clean); nothing to push to"; audit "skill.$action" "$name" committed-no-remote ;;
    failed) audit "skill.$action" "$name" push-failed; die "git push failed" "fix the remote/branch and rerun: git -C $dir push" ;;
  esac
  skill_push_nodes "pick up"
}

# ---------- fleet skill list ----------

# skill_on_nodes NAME — for a config skill: yes when committed and pushed,
# otherwise "not pushed" (uncommitted edits, or commits the upstream lacks).
skill_on_nodes() {
  local dir=$FLEET_CONFIG_DIR
  [ -d "$dir/.git" ] || { echo "?"; return 0; }
  if git -C "$dir" status --porcelain --untracked-files=all -- "skills/$1" 2>/dev/null | grep -q .; then echo "not pushed"; return 0; fi
  if git -C "$dir" rev-parse --verify -q '@{upstream}' >/dev/null 2>&1; then
    if git -C "$dir" log --format=%h '@{upstream}..HEAD' -- "skills/$1" 2>/dev/null | grep -q .; then echo "not pushed"; return 0; fi
  elif git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    echo "not pushed"; return 0
  fi
  echo yes
}

# skill_rows_master — "name<TAB>source<TAB>path<TAB>on_nodes": the config repo's
# skills, the bundled `fleet` skill, then skills found only in this machine's
# harness skill dirs (local-only: the next sync publishes them).
skill_rows_master() {
  local s n d names="" p
  if [ -d "$FLEET_CONFIG_DIR/skills" ]; then
    for s in "$FLEET_CONFIG_DIR"/skills/*/; do
      [ -f "$s/SKILL.md" ] || continue
      n=$(basename "$s"); names="$names $n"
      printf '%s\t%s\t%s\t%s\n' "$n" config "${s%/}" "$(skill_on_nodes "$n")"
    done
  fi
  if [ -f "$(harness_builtin_skill)/SKILL.md" ] && [ ! -f "$FLEET_CONFIG_DIR/skills/fleet/SKILL.md" ]; then
    names="$names fleet"
    printf '%s\t%s\t%s\t%s\n' fleet fleet "$(harness_builtin_skill)" yes
  fi
  for d in $(skill_local_dirs); do
    for p in "$d"/*/; do
      [ -f "$p/SKILL.md" ] || continue
      n=$(basename "$p")
      case " $names " in *" $n "*) continue ;; esac
      skill_excluded "$n" && continue
      names="$names $n"
      printf '%s\t%s\t%s\t%s\n' "$n" local-only "${p%/}" no
    done
  done
}

# skill_rows_node — installed skills from harness.manifest: config repo skills
# and the bundled `fleet` skill, one row per name.
skill_rows_node() {
  local m="$FLEET_HOME/harness.manifest" p n names="" src
  [ -f "$m" ] || return 0
  while IFS= read -r p; do
    case "$p" in */skills/*) ;; *) continue ;; esac
    [ -f "$p/SKILL.md" ] || continue
    n=$(basename "$p")
    case " $names " in *" $n "*) continue ;; esac
    names="$names $n"
    if [ -f "$FLEET_CONFIG_DIR/skills/$n/SKILL.md" ]; then src=config; elif [ "$n" = fleet ]; then src=fleet; else src=local-only; fi
    printf '%s\t%s\t%s\t%s\n' "$n" "$src" "$p" -
  done <"$m"
}

# fleet skill list [--json] — master: NAME, SOURCE (config | fleet | local-only),
# ON NODES?, DESCRIPTION; node: what fleet apply installed here.
cmd_skill_list() {
  local json=0 role width rows
  while [ $# -gt 0 ]; do
    case "$1" in --json) json=1 ;; *) die "usage: fleet skill list [--json]" ;; esac; shift
  done
  need python3
  if [ -d "$FLEET_VAULT/nodes" ]; then role=master; else role=node; fi
  width=${COLUMNS:-}
  [ -n "$width" ] || { if [ -t 1 ]; then width=$(tput cols 2>/dev/null || echo 120); else width=120; fi; }
  rows=$(mktemp "${TMPDIR:-/tmp}/fleet-skills.XXXXXX"); chmod 0600 "$rows"
  if [ "$role" = master ]; then skill_rows_master >"$rows"; else skill_rows_node >"$rows"; fi
  skill_py render "$([ "$json" = 1 ] && echo json || echo table)" "$role" "$width" "$rows"
  rm -f "$rows"
}

# ---------- fleet skill remove ----------

# fleet skill remove N [--yes] — out of the config repo (commit + push), out of
# this machine's skill dirs (otherwise the next sync would publish it again);
# nodes drop it on their next apply (manifest cleanup), or right away via reconcile.
cmd_skill_remove() {
  local name="" yes=0 dir remote r n
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) yes=1 ;;
      -*) die "unknown flag: $1" "usage: fleet skill remove NAME [--yes]" ;;
      *) name=$1 ;;
    esac; shift
  done
  [ -n "$name" ] || die "usage: fleet skill remove NAME [--yes]" "names: fleet skill list"
  skill_name_valid "$name" || die "invalid skill name: $name"
  vault_require
  skill_repo_check
  dir=$FLEET_CONFIG_DIR
  [ -d "$dir/skills/$name" ] || die "no skill $name in your fleet config ($dir/skills)" "fleet skill list"
  remote=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  if [ "$yes" != 1 ]; then
    printf 'Remove skill %s from %s, from this machine'"'"'s skill dirs and from every node (push to %s)? [y/N] ' "$name" "$dir" "${remote:-<no remote>}" >&2
    IFS= read -r r || true
    case "$r" in y|Y|yes) ;; *) die "aborted; nothing removed" "rerun with --yes to skip the question" ;; esac
  fi
  git -C "$dir" rm -r -q --cached -- "skills/$name" 2>/dev/null || true
  rm -rf "${dir:?}/skills/$name"
  if git -C "$dir" diff --cached --quiet -- "skills/$name" 2>/dev/null; then
    log "skills/$name was not committed; nothing to commit"
  else
    git -C "$dir" commit -q -m "remove skill $name"
  fi
  n=$(skill_local_remove "$name")
  ok "removed $name from your fleet config ($n local dir(s) removed)"
  [ "$name" = fleet ] && log "the bundled fleet skill (skills/fleet in fleeter) is back on the nodes and here: fleet skill install"
  case "$(skill_repo_push)" in
    pushed) ok "published"; audit "skill.remove" "$name" pushed ;;
    no-remote) ok "committed $(git -C "$dir" rev-parse --short HEAD); nothing to push to"; audit "skill.remove" "$name" committed-no-remote ;;
    failed) audit "skill.remove" "$name" push-failed; die "git push failed" "fix the remote/branch and rerun: git -C $dir push" ;;
  esac
  skill_push_nodes drop
}

# ---------- auto-publish (fleet sync) ----------

# sync_publish_skills — skills installed in this machine's harness skill dirs
# that the config repo lacks, or has in a different version, are copied in,
# secret-scanned (a hit skips that skill with a warning), committed as
# `publish skills: a, b` and pushed. Non-interactive (sync runs from a timer),
# quiet when nothing changed, never deletes a skill from the repo. Off with
# FLEET_SYNC_PUBLISH_SKILLS=0. Excludes FLEET_SKILL_EXCLUDE and the bundled `fleet`.
sync_publish_skills() {
  local dir=$FLEET_CONFIG_DIR d p n real names="" cands="" scan list="" msg
  case "${FLEET_SYNC_PUBLISH_SKILLS:-1}" in 0|no|false|off) return 0 ;; esac
  [ -d "$dir/.git" ] || return 0
  have python3 && have git || return 0
  for d in $(skill_local_dirs); do
    for p in "$d"/*/; do
      [ -f "$p/SKILL.md" ] || continue
      n=$(basename "$p")
      case " $names " in *" $n "*) continue ;; esac     # first source wins (capture order)
      skill_excluded "$n" && continue
      skill_name_valid "$n" || continue
      names="$names $n"
      real=$(cd "$p" && pwd -P)
      [ -d "$dir/skills/$n" ] && [ "$(skill_tree_digest "$real")" = "$(skill_tree_digest "$dir/skills/$n")" ] && continue
      if ! scan=$(harness_secret_scan "$real" 2>&1); then
        warn "skill $n: not published, the secret scan found $(printf '%s\n' "$scan" | grep -c '^[^:]*:[0-9]*: ' || true) hit(s) in $real (fix it, or add $n to FLEET_SKILL_EXCLUDE in fleet.conf)"
        continue
      fi
      skill_py copy "$real" "$dir/skills/$n" || { warn "skill $n: copy into $dir failed"; continue; }
      git -C "$dir" add -A -- "skills/$n"
      cands="$cands $n"
    done
  done
  [ -n "$cands" ] || return 0
  if git -C "$dir" diff --cached --quiet; then return 0; fi
  if [ -z "$(git -C "$dir" config --get user.name 2>/dev/null)" ] || [ -z "$(git -C "$dir" config --get user.email 2>/dev/null)" ]; then
    warn "skills: cannot publish$cands, git has no identity for $dir (git config --global user.name / user.email)"
    git -C "$dir" reset -q
    return 0
  fi
  for n in $cands; do list="$list${list:+, }$n"; done
  msg="publish skills: $list"
  git -C "$dir" commit -q -m "$msg" || { warn "skills: commit failed in $dir"; return 0; }
  log "skills: $msg ($(git -C "$dir" rev-parse --short HEAD))"
  case "$(skill_repo_push)" in
    pushed) audit "sync.skills" "-" "pushed:$cands" ;;
    no-remote) audit "sync.skills" "-" "committed-no-remote:$cands" ;;
    failed) warn "skills: committed but git push failed (offline? fix the remote); the next sync retries"; audit "sync.skills" "-" "push-failed:$cands" ;;
  esac
  return 0
}
