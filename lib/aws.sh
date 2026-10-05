# shellcheck shell=bash
# shellcheck disable=SC2154
# fleet aws: the master's AWS SSO login, forwarded to the nodes as short-lived
# role credentials. Sourced by ./fleet after lib/common.sh and
# fleet_load_config (SC2154 off: FLEET_* come from the conf files).
#
# Master: `fleet aws push` runs `aws configure export-credentials --profile P
# --format process` for every profile in FLEET_AWS_PROFILES (the allowlist;
# empty = nothing is ever pushed; keep production out of it), skips profiles
# whose IAM Identity Center session is not logged in right now, and pipes one
# JSON bundle (kept in memory, never on the master's disk) into `fleet aws
# receive` on every online provisioned node. `fleet sync` does the same on
# its cadence (FLEET_AWS_SYNC, FLEET_AWS_REFRESH_MINUTES) and never logs in.
# Node: `fleet aws receive` stores ~/.config/fleet/aws/<profile>.json (0600)
# and keeps a `# >>> fleet aws >>>` block in ~/.aws/config whose profiles use
# `credential_process = <abs path>/fleet aws creds P`; `fleet aws creds P`
# prints the stored JSON while it is valid (2 min skew) and exits 1 with a
# pointer at `aws sso login` on the master otherwise.
# The parsing, validation and file logic is lib/aws_creds.py (stdlib python,
# the AWS facts and their sources are cited at its top). The session token in
# ~/.aws/sso/cache never leaves the master.
#
# Portability: bash 3.2, no GNU-only flags, no sed -i, no timeout, no flock.
# Secrets never in argv or logs: the bundle travels stdout -> variable -> stdin.

aws_py() { python3 "$FLEET_ROOT/lib/aws_creds.py" "$@"; }

# aws_bin — the AWS CLI; FLEET_AWS_BIN overrides it (tests: a fake, or a path
# that does not exist to mean "not installed").
aws_bin() { echo "${FLEET_AWS_BIN:-aws}"; }

# aws_config_path — the CLI's own config file, honouring its AWS_CONFIG_FILE override.
aws_config_path() { echo "${AWS_CONFIG_FILE:-$HOME/.aws/config}"; }

aws_node_dir() { echo "$FLEET_HOME/aws"; }
aws_state_file() { echo "$FLEET_VAULT/aws.json"; }

# aws_select NAME... — one line per NAME: NAME<TAB>ok|refused<TAB>reason;
# without names, every profile of the allowlist.
aws_select() {
  aws_py select "$(aws_config_path)" "${FLEET_AWS_PROFILES:-}" "$@"
}

# aws_refuse MESSAGE — a refused request: nothing ran, exit 2 like a usage error.
aws_refuse() { printf 'error %s\n' "$1" >&2; exit 2; }

aws_allowlist_hint() { echo 'no AWS profiles allowed; set FLEET_AWS_PROFILES="dev" in fleet.conf (keep production out of that list)'; }

# aws_online_nodes PEERS — ids of the provisioned, non-revoked nodes that are online.
aws_online_nodes() {
  local peers=$1 id
  for id in $(registry_ids); do
    [ "$(registry_get "$id" state)" = provisioned ] || continue
    peer_online "$peers" "$id" && echo "$id"
  done
  return 0
}

# aws_state_set KEY VALUE... — vault/aws.json (0600): pushed, expires, nodes, allowed, warned.
aws_state_set() {
  [ -d "$FLEET_VAULT" ] || return 0
  json_set "$(aws_state_file)" "$@"
}

# aws_sync_warn KEY MESSAGE — from the scheduled run: at most one warning per
# hour per KEY (refused, expired, failed), remembered in vault/aws.json.
aws_sync_warn() {
  local key=$1 last=0
  [ -f "$(aws_state_file)" ] && last=$(iso_epoch "$(json_get "$(aws_state_file)" "warned_$key")")
  [ $(( $(now_epoch) - last )) -ge 3600 ] || return 0
  warn "$2"
  aws_state_set "warned_$key" "$(now_iso)"
}

# aws_push_run MODE PROFILES NODES — the push. MODE manual (fleet aws push:
# every refusal and skip is reported, an explicitly requested profile that is
# refused exits 2 before anything runs) or sync (quiet on success, no login
# ever, warnings rate-limited). PROFILES/NODES: space-separated requests, empty
# = the whole allowlist / every online provisioned node.
aws_push_run() {
  local mode=$1 want=$2 want_nodes=$3 bundle="" rep tmpd line name st why ok_profiles="" allowed="" refused="" expired="" failed=""
  local ids="" id peers n=0 okn=0 earliest="" exp names="" q kind first
  if ! have "$(aws_bin)"; then
    [ "$mode" = manual ] && die "aws CLI not found on this machine" "install it (brew install awscli, https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)"
    return 0
  fi
  if [ -z "${FLEET_AWS_PROFILES:-}" ] && [ -z "$want" ]; then
    [ "$mode" = manual ] && die "$(aws_allowlist_hint)"
    return 0
  fi
  # 1. the allowlist (lib/aws_creds.py select). `allowed` is what the nodes
  #    may hold at all (the allowlist minus names the config does not have):
  #    a node drops everything else. A --profile request only narrows what
  #    this run sends.
  rep=$(aws_select) || die "cannot read $(aws_config_path)"
  while IFS="$(printf '\t')" read -r name st why; do
    [ -n "$name" ] || continue
    if [ "$st" = ok ]; then allowed="$allowed $name"; else refused="$refused $name ($why)"; fi
  done <<EOF
$rep
EOF
  if [ -n "$want" ]; then
    # shellcheck disable=SC2086  # the request is a space-separated list by construction
    rep=$(aws_select $want) || die "cannot read $(aws_config_path)"
    refused=""
    while IFS="$(printf '\t')" read -r name st why; do
      [ -n "$name" ] || continue
      if [ "$st" = ok ]; then ok_profiles="$ok_profiles $name"; else aws_refuse "AWS profile $name refused: $why"; fi
    done <<EOF
$rep
EOF
  else
    ok_profiles=$allowed
  fi
  if [ -n "$refused" ]; then
    if [ "$mode" = manual ]; then warn "AWS profiles refused:$refused"; else aws_sync_warn refused "aws: profiles refused:$refused"; fi
  fi
  if [ -z "$ok_profiles" ]; then
    [ "$mode" = manual ] && die "no AWS profile left to push" "FLEET_AWS_PROFILES in fleet.conf must name profiles of $(aws_config_path); fleet aws push --help"
    return 0
  fi
  # 2. export: the bundle stays in this variable; the report (names, expiry,
  #    the CLI's error line) goes to a 0600 temp file and holds no secret
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fleet-aws.XXXXXX"); chmod 0700 "$tmpd"
  # shellcheck disable=SC2086
  bundle=$(aws_py export "$(aws_bin)" "$(aws_config_path)" "$allowed" $ok_profiles 2>"$tmpd/report") || true
  names=""
  while IFS="$(printf '\t')" read -r name st kind why; do
    [ -n "$name" ] || continue
    case "$st" in
      ok)   names="$names $name"; exp=$(iso_epoch "$why"); if [ -z "$earliest" ] || [ "$exp" -lt "$earliest" ]; then earliest=$exp; fi ;;
      *)    case "$kind" in login) expired="$expired $name" ;; *) failed="$failed $name ($why)" ;; esac ;;
    esac
  done <"$tmpd/report"
  names=${names# }
  if [ "$mode" = manual ]; then
    [ -z "$failed" ] || warn "AWS profiles not exported:$failed"
    [ -z "$expired" ] || warn "AWS SSO session expired for$expired: run aws sso login (or fleet aws login)"
    if [ -z "$names" ]; then rm -rf "$tmpd"; bundle=""; die "nothing to push: no allowed AWS profile is logged in" "aws sso login (or fleet aws login), then fleet aws push"; fi
  elif [ -z "$names" ]; then
    rm -rf "$tmpd"; bundle=""
    [ -z "$failed" ] || aws_sync_warn failed "aws: profiles not exported:$failed"
    [ -z "$expired" ] || aws_sync_warn expired "AWS SSO session expired for$expired: run aws sso login (or fleet aws login); nodes keep what they have until it expires"
    return 0
  fi
  # 3. the nodes
  peers=$(ts_peers)
  if [ -n "$want_nodes" ]; then
    for q in $want_nodes; do
      id=$(registry_find "$q")
      node_revoked "$id" && die "node $q is revoked"
      if peer_online "$peers" "$id"; then ids="$ids $id"; else warn "$(registry_get "$id" name): not online, skipped"; fi
    done
  else
    ids=$(aws_online_nodes "$peers" | tr '\n' ' ')
  fi
  if [ -z "${ids// /}" ]; then
    rm -rf "$tmpd"; bundle=""
    [ "$mode" = manual ] && log "no online provisioned node to push to"
    return 0
  fi
  # 4. one ssh per node, in parallel, the bundle on stdin (no with_timeout: it
  #    closes stdin; ssh's own ConnectTimeout and keepalives bound the wait)
  for id in $ids; do
    # shellcheck disable=SC2088  # the ~ is expanded by the node's shell, not ours
    ( printf '%s\n' "$bundle" | node_ssh "$id" '~/.local/bin/fleet aws receive' >"$tmpd/$id.out" 2>"$tmpd/$id.err" && : >"$tmpd/$id.ok" ) &
  done
  wait
  bundle=""
  for id in $ids; do
    n=$((n + 1)); name=$(registry_get "$id" name)
    if [ -f "$tmpd/$id.ok" ]; then
      okn=$((okn + 1)); first=$(head -n 1 "$tmpd/$id.out" 2>/dev/null)
      [ "$mode" = manual ] && ok "$name: ${first:-received}"
      grep '^warn ' "$tmpd/$id.err" 2>/dev/null | while IFS= read -r line; do warn "$name: ${line#warn }"; done
      audit aws.push "$name" "ok profiles:$(printf '%s' "$names" | tr ' ' ',') expires:$(epoch_iso "${earliest:-0}")"
    else
      first=$(grep -v '^$' "$tmpd/$id.err" 2>/dev/null | head -n 1)
      warn "$name: aws push failed${first:+: $first}"
      audit aws.push "$name" "fail"
    fi
  done
  rm -rf "$tmpd"
  # shellcheck disable=SC2086  # the id list is space-separated by construction
  aws_state_set pushed "$(now_iso)" expires "$(epoch_iso "${earliest:-0}")" allowed "${FLEET_AWS_PROFILES:-}" \
    nodes "json:$(words_json $ids)" warned_expired "" warned_failed ""
  [ "$mode" = manual ] && [ "$okn" -lt "$n" ] && return 1
  return 0
}

# fleet aws push [--profile P]... [--node NODE]... — forward the allowed
# profiles' role credentials to the online provisioned nodes now.
cmd_aws_push() {
  local profiles="" nodes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) [ -n "${2:-}" ] || die "--profile needs a value"; profiles="$profiles $2"; shift ;;
      --node)    [ -n "${2:-}" ] || die "--node needs a value"; nodes="$nodes $2"; shift ;;
      *) die "usage: fleet aws push [--profile P]... [--node NODE]..." ;;
    esac; shift
  done
  vault_require
  aws_push_run manual "$profiles" "$nodes"
}

# fleet aws login [--profile P]... [-- AWS_ARGS...] — `aws sso login` on the
# master (interactive: the browser or device code is yours), for the given
# profiles or else the first allowed one, then `fleet aws push`. Anything after
# `--` goes to aws sso login (e.g. --use-device-code, --sso-session NAME).
cmd_aws_login() {
  local profiles="" p sel name st why given=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) [ -n "${2:-}" ] || die "--profile needs a value"; profiles="$profiles $2"; given=1; shift ;;
      --) shift; break ;;
      *) die "usage: fleet aws login [--profile P]... [-- AWS_ARGS...]" ;;
    esac; shift
  done
  vault_require
  have "$(aws_bin)" || die "aws CLI not found on this machine" "brew install awscli, or https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  [ -n "${FLEET_AWS_PROFILES:-}" ] || die "$(aws_allowlist_hint)"
  # shellcheck disable=SC2086
  sel=$(aws_select $profiles) || die "cannot read $(aws_config_path)"
  if [ -n "$profiles" ]; then
    while IFS="$(printf '\t')" read -r name st why; do
      [ -n "$name" ] || continue
      [ "$st" = ok ] || aws_refuse "AWS profile $name refused: $why"
    done <<EOF
$sel
EOF
  else
    # the first allowed profile that is not refused; its session covers every profile sharing it
    name=$(printf '%s\n' "$sel" | awk -F'\t' '$2=="ok"{print $1; exit}')
    [ -n "$name" ] || die "no AWS profile in FLEET_AWS_PROFILES is usable" "$(printf '%s\n' "$sel" | tr '\t' ' ' | tr '\n' ';')"
    profiles=$name
  fi
  for p in $profiles; do
    log "aws sso login --profile $p"
    "$(aws_bin)" sso login --profile "$p" "$@" || die "aws sso login --profile $p failed"
  done
  audit aws.login - "ok ${profiles# }"
  # explicit --profile flags narrow the push too; a login for the first allowed
  # profile is followed by a push of the whole allowlist
  if [ -n "$given" ]; then aws_push_run manual "$profiles" ""; else aws_push_run manual "" ""; fi
}

# aws_push_due PEERS — true when the scheduled run should push: nothing pushed
# yet, the last push is FLEET_AWS_REFRESH_MINUTES old, the credentials pushed
# then expire within that window, the allowlist changed, or an online
# provisioned node never got a push (freshly provisioned).
aws_push_due() {
  local peers=$1 f every=${FLEET_AWS_REFRESH_MINUTES:-60} pushed exp id seen
  case "$every" in ''|*[!0-9]*) warn "FLEET_AWS_REFRESH_MINUTES must be a number of minutes; got '$every'"; every=60 ;; esac
  f=$(aws_state_file)
  [ -f "$f" ] || return 0
  pushed=$(iso_epoch "$(json_get "$f" pushed)"); [ "$pushed" -gt 0 ] || return 0
  [ $(( $(now_epoch) - pushed )) -lt $(( every * 60 )) ] || return 0
  exp=$(iso_epoch "$(json_get "$f" expires)")
  [ $(( exp - $(now_epoch) )) -ge $(( every * 60 )) ] || return 0
  [ "$(json_get "$f" allowed)" = "${FLEET_AWS_PROFILES:-}" ] || return 0
  seen=$(json_list "$f" nodes | tr '\n' ' ')
  for id in $(aws_online_nodes "$peers"); do
    case " $seen " in *" $id "*) ;; *) return 0 ;; esac
  done
  return 1
}

# sync_aws_push PEERS — the fleet sync step: with FLEET_AWS_SYNC=1, an
# allowlist and the aws CLI present, push on the cadence above. Never logs in.
sync_aws_push() {
  local peers=$1
  [ "${FLEET_AWS_SYNC:-1}" = 1 ] || return 0
  [ -n "${FLEET_AWS_PROFILES:-}" ] || return 0
  have "$(aws_bin)" || return 0
  aws_push_due "$peers" || return 0
  aws_push_run sync "" "" || true
}

# ---------- node side ----------

# aws_fleet_bin — the absolute `fleet` the credential_process line runs
# (the AWS CLI expands no ~ and no variables there).
aws_fleet_bin() {
  if [ -x "$FLEET_BIN/fleet" ]; then echo "$FLEET_BIN/fleet"; else echo "$FLEET_ROOT/fleet"; fi
}

# fleet aws receive — (run by the master over ssh) the bundle on stdin.
cmd_aws_receive() {
  local cfg
  cfg=$(aws_config_path)
  backup_once "$cfg"
  umask 077
  aws_py receive "$(aws_node_dir)" "$cfg" "$(aws_fleet_bin)"
}

# fleet aws creds PROFILE — the credential_process of the fleet block.
cmd_aws_creds() {
  exec python3 "$FLEET_ROOT/lib/aws_creds.py" creds "$(aws_node_dir)" "$1"
}

# node_aws_status_json — {"profiles": n, "expires": iso|null, "state": ok|expired|none} (status.json "aws").
node_aws_status_json() { aws_py status "$(aws_node_dir)"; }

# node_aws_remove — leave/kick: the credential files and the config block go.
node_aws_remove() {
  local cfg
  cfg=$(aws_config_path)
  if [ ! -d "$(aws_node_dir)" ] && ! grep -qF '# >>> fleet aws >>>' "$cfg" 2>/dev/null; then return 0; fi
  aws_py clear "$(aws_node_dir)" "$cfg" || { warn "could not remove the AWS credentials ($(aws_node_dir), the fleet block in $cfg)"; return 1; }
  ok "aws credentials removed"
}
