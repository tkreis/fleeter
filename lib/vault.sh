# shellcheck shell=bash
# Vault encryption at rest (master side). Sourced by ./fleet after lib/common.sh
# and fleet_load_config; nodes source it too and never call it. Functions only.
#
# Every secret-bearing file in the vault is an age ciphertext (`<name>.age`)
# encrypted to one X25519 recipient (vault/recipient.txt, public). The private
# identity never lives in the vault: it sits in a key backend
#   FLEET_VAULT_KEY_BACKEND = keychain     macOS login keychain (default on macOS)
#                           | secret-tool  libsecret (default on Linux when installed)
#                           | file         $FLEET_HOME/vault.key, 0600 (fallback, CI)
# and reaches `age` through a pipe (`age -d -i -`): never argv, never a file.
# Writers need only the recipient (`age -R recipient.txt`); readers decrypt to
# stdout / memory. Plain SSH keys (ssh/) and known_hosts stay plain: ssh needs them.
#
# A vault from before encryption keeps working: readers fall back to the
# plaintext file when there is no `.age`; `fleet vault encrypt` migrates.
#
# Portability: bash 3.2, no GNU-only flags, no sed -i; every function declares its locals.

VAULT_KEY_SERVICE="fleet-vault"        # backend entry holding the current identity
VAULT_KEY_NEXT="fleet-vault-next"      # the incoming identity while `vault rotate-key` runs

AGE_INSTALL_HINT="install age, then rerun (macOS: brew install age; Debian/Ubuntu: sudo apt-get install -y age; other: https://age-encryption.org)"

vault_recipient_file() { echo "$FLEET_VAULT/recipient.txt"; }

# vault_account — the backend account: the login name (launchd/systemd may not set USER).
vault_account() { echo "${USER:-$(id -un)}"; }

# vault_backend — keychain | secret-tool | file: FLEET_VAULT_KEY_BACKEND, or the platform default.
vault_backend() {
  local b=${FLEET_VAULT_KEY_BACKEND:-}
  if [ -z "$b" ]; then
    case "$(fleet_os)" in
      macos) b=keychain ;;
      *)     if have secret-tool; then b="secret-tool"; else b="file"; fi ;;
    esac
  fi
  case "$b" in
    keychain|secret-tool|file) echo "$b" ;;
    *) die "FLEET_VAULT_KEY_BACKEND must be keychain, secret-tool or file (got '$b')" ;;
  esac
}

# vault_key_file NAME — the file backend's path for a backend entry.
vault_key_file() {
  case "$1" in
    "$VAULT_KEY_SERVICE") echo "$FLEET_HOME/vault.key" ;;
    *)                    echo "$FLEET_HOME/vault.key.next" ;;
  esac
}

# vault_backend_describe — where the private key is, for messages.
vault_backend_describe() {
  case "$(vault_backend)" in
    keychain)    echo "login keychain, service $VAULT_KEY_SERVICE, account $(vault_account)" ;;
    secret-tool) echo "secret-tool, service $VAULT_KEY_SERVICE, account $(vault_account)" ;;
    file)        echo "file $(vault_key_file "$VAULT_KEY_SERVICE")" ;;
  esac
}

# vault_locked_hint — the next step when the identity cannot be read.
vault_locked_hint() {
  case "$(vault_backend)" in
    keychain)    echo "unlock the login keychain (log in on this Mac, or: security unlock-keychain), then retry; fleet vault status shows the key state" ;;
    secret-tool) echo "the secret service is not reachable from this session (no D-Bus/keyring?); unlock it, or set FLEET_VAULT_KEY_BACKEND=file in $FLEET_HOME/fleet.conf; fleet vault status" ;;
    file)        echo "$(vault_key_file "$VAULT_KEY_SERVICE") is missing or unreadable; restore it from your backup (fleet vault export), or re-create the vault" ;;
  esac
}

# vault_backend_get NAME — the identity stored under NAME on stdout; 1 when
# absent or unreachable (locked keychain, no secret service). Quiet.
vault_backend_get() {
  case "$(vault_backend)" in
    keychain)    security find-generic-password -s "$1" -a "$(vault_account)" -w 2>/dev/null ;;
    secret-tool) secret-tool lookup service "$1" account "$(vault_account)" 2>/dev/null ;;
    file)        cat "$(vault_key_file "$1")" 2>/dev/null ;;
  esac
}

# vault_backend_set NAME < identity — store one identity line under NAME and
# read it back to be sure it landed. The identity goes to the backend's stdin
# (`security -i` takes its command there), never into an argument.
vault_backend_set() {
  local name=$1 id acct back
  IFS= read -r id || true
  [ -n "$id" ] || return 1
  acct=$(vault_account)
  case "$(vault_backend)" in
    keychain)
      printf 'add-generic-password -U -s %s -a %s -w %s\n' "$name" "$acct" "$id" | security -i >/dev/null 2>&1 || true ;;
    secret-tool)
      printf '%s' "$id" | secret-tool store --label="$name" service "$name" account "$acct" >/dev/null 2>&1 || true ;;
    file)
      mkdir -p "$FLEET_HOME"; chmod 0700 "$FLEET_HOME"
      printf '%s\n' "$id" | atomic_write "$(vault_key_file "$name")" 0600 ;;
  esac
  back=$(vault_backend_get "$name") || back=""
  [ "$back" = "$id" ]
}

# vault_backend_del NAME — remove an entry (quiet when absent).
vault_backend_del() {
  case "$(vault_backend)" in
    keychain)    security delete-generic-password -s "$1" -a "$(vault_account)" >/dev/null 2>&1 || true ;;
    secret-tool) secret-tool clear service "$1" account "$(vault_account)" >/dev/null 2>&1 || true ;;
    file)        rm -f "$(vault_key_file "$1")" ;;
  esac
}

# vault_encrypted — the vault has a recipient, i.e. writers encrypt and the
# secrets are (or are being migrated to) .age files.
vault_encrypted() { [ -f "$(vault_recipient_file)" ]; }

# vault_recipient_backend — the backend recorded in recipient.txt when it was written.
vault_recipient_backend() {
  [ -f "$(vault_recipient_file)" ] || return 0
  sed -n 's/^# fleet vault: backend=\([a-z-]*\).*/\1/p' "$(vault_recipient_file)" | head -1
}

# vault_identity — the identity line(s) on stdout: the current one, plus the
# incoming one while a rotation is in flight (so a half-rotated vault still
# decrypts). Fetched from the backend once per process, then kept in memory
# (never exported). Returns 1, quietly, when the backend cannot deliver it.
_VAULT_ID=""
vault_identity() {
  local p n
  if [ -z "$_VAULT_ID" ]; then
    p=$(vault_backend_get "$VAULT_KEY_SERVICE") || return 1
    [ -n "$p" ] || return 1
    n=$(vault_backend_get "$VAULT_KEY_NEXT") || n=""
    _VAULT_ID=$p
    [ -n "$n" ] && _VAULT_ID="$p
$n"
  fi
  printf '%s\n' "$_VAULT_ID"
}

# vault_identity_require — like vault_identity, but dies with the next step.
vault_identity_require() {
  vault_identity && return 0
  die "the vault key is unreachable ($(vault_backend_describe))" "$(vault_locked_hint)"
}

# vault_unlocked — true when the identity can be read right now.
vault_unlocked() { vault_identity >/dev/null 2>&1; }

# vault_cat FILE.age — plaintext on stdout. The identity enters age on stdin
# (`-i -`), the ciphertext is the file argument; nothing decrypted touches disk.
vault_cat() {
  local f=$1 id
  id=$(vault_identity) || return 1
  printf '%s\n' "$id" | age -d -i - "$f"
}

# vault_has PATH — the item exists, encrypted (PATH.age) or legacy plaintext (PATH).
vault_has() { [ -f "$1.age" ] || [ -f "$1" ]; }

# vault_read PATH — plaintext of the item on stdout: PATH.age decrypted when it
# exists (it wins over a stale plaintext), else PATH as is. 1 when neither
# exists or decryption fails; never prints a partial result as success.
vault_read() {
  if [ -f "$1.age" ]; then vault_cat "$1.age"
  elif [ -f "$1" ]; then cat "$1"
  else return 1; fi
}

# vault_recipient_require — writers need the recipient; without one the vault
# predates encryption and `fleet vault encrypt` is the way in.
vault_recipient_require() {
  vault_encrypted && return 0
  die "the vault is not encrypted yet (no $(vault_recipient_file))" \
    "run: fleet vault encrypt (existing master: encrypts the current secrets in place) or fleet init master (new master)"
}

# vault_write DEST.age < plaintext — encrypt stdin to the vault recipient,
# tmp + mv in the same directory, 0600. The plaintext only ever flows through
# the pipe into age. A legacy plaintext counterpart is left for the caller to
# remove once it is sure (migration verifies the round-trip first).
vault_write() {
  local dest=$1 tmp
  vault_recipient_require
  need age "$AGE_INSTALL_HINT"
  mkdir -p "$(dirname "$dest")"
  tmp=$(mktemp "$(dirname "$dest")/.fleet.XXXXXX") || die "mktemp failed for $dest"
  if ! age -R "$(vault_recipient_file)" >"$tmp"; then rm -f "$tmp"; die "age encryption failed for $dest"; fi
  chmod 0600 "$tmp"
  mv -f "$tmp" "$dest"
}

# age_ensure — age + age-keygen on this master: install where that is
# unattended enough (brew; apt only at a terminal), otherwise name the step.
age_ensure() {
  have age && have age-keygen && return 0
  case "$(fleet_os)" in
    macos) if have brew; then log "installing age (brew install age)"; brew install age >/dev/null 2>&1 || warn "brew install age failed"; fi ;;
    linux) if [ "$(fleet_pkg_mgr)" = apt-get ] && [ -t 0 ]; then
             log "installing age (apt-get install -y age; may ask for your sudo password)"
             as_root apt-get install -y age >/dev/null 2>&1 || warn "apt-get install age failed"
           fi ;;
  esac
  have age && have age-keygen && { ok "age installed ($(age --version 2>/dev/null))"; return 0; }
  die "age is not installed (the vault is encrypted with it)" "$AGE_INSTALL_HINT"
}

# vault_key_ensure — make sure this vault has a key: an identity in the
# backend and vault/recipient.txt (0644: the public half, so every writer can
# encrypt without touching the private key). Idempotent. A backend that still
# holds an identity from a vault whose recipient.txt is gone is reused.
vault_key_ensure() {
  local id rcpt b
  vault_encrypted && return 0
  need age "$AGE_INSTALL_HINT"; need age-keygen "$AGE_INSTALL_HINT"
  b=$(vault_backend)
  mkdir -p "$FLEET_VAULT"; chmod 0700 "$FLEET_VAULT"
  if id=$(vault_backend_get "$VAULT_KEY_SERVICE") && [ -n "$id" ]; then
    warn "vault: reusing the key already stored in the $b backend ($(vault_backend_describe)); $(vault_recipient_file) was missing"
  else
    id=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-') || die "age-keygen failed"
    printf '%s\n' "$id" | vault_backend_set "$VAULT_KEY_SERVICE" \
      || die "could not store the vault key in the $b backend ($(vault_backend_describe))" "$(vault_locked_hint)"
  fi
  rcpt=$(printf '%s\n' "$id" | age-keygen -y 2>/dev/null) || die "age-keygen -y failed"
  id=""; _VAULT_ID=""
  { printf '# fleet vault: backend=%s account=%s\n# the private key is in that backend (%s); this file is the public recipient\n' \
      "$b" "$(vault_account)" "$(vault_backend_describe)"; printf '%s\n' "$rcpt"; } | atomic_write "$(vault_recipient_file)" 0644
  ok "vault key: $b ($(vault_backend_describe)); recipient $rcpt"
  [ "$b" = file ] && warn "vault key backend 'file': the private key is a plain 0600 file next to the vault, so anything that can read your home directory can decrypt it. Use keychain (macOS) or secret-tool (Linux) where you can; keep the disk encrypted."
  return 0
}

# vault_plain_items — secret-bearing files that are still plaintext, relative
# to the vault, sorted: the env files, the API credentials, every mirrored file.
vault_plain_items() {
  local f
  [ -d "$FLEET_VAULT" ] || return 0
  (cd "$FLEET_VAULT" && {
    for f in secrets/minimal.env secrets/full.env tailscale.json github.json; do [ -f "$f" ] && printf '%s\n' "$f"; done
    [ -d files ] && find files -type f ! -name '.DS_Store' ! -name '*.age'
    :
  } | LC_ALL=C sort)
}

# vault_age_items — every ciphertext in the vault, relative to it, sorted.
vault_age_items() {
  [ -d "$FLEET_VAULT" ] || return 0
  (cd "$FLEET_VAULT" && find . -type f -name '*.age' ! -path './locks/*' | sed 's|^\./||' | LC_ALL=C sort)
}

# vault_encrypt_item REL — encrypt one plaintext item in place: write REL.age,
# decrypt it again and compare byte for byte, only then remove REL. A
# plaintext next to an identical REL.age (a writer interrupted before its
# rm) is just dropped; one that differs is never guessed about.
vault_encrypt_item() {
  local rel=$1 f
  f="$FLEET_VAULT/$rel"
  if [ -f "$f.age" ]; then
    if vault_cat "$f.age" | cmp -s - "$f"; then rm -f "$f"; return 0; fi
    die "$rel and $rel.age both exist and differ" \
      "keep one: rm \"$f\" (keep the encrypted version) or rm \"$f.age\" (encrypt the plaintext), then rerun: fleet vault encrypt"
  fi
  vault_write "$f.age" <"$f"
  if ! vault_cat "$f.age" | cmp -s - "$f"; then
    rm -f "$f.age"
    die "round-trip check failed for $rel; the plaintext was left in place" "fleet vault status; then retry fleet vault encrypt"
  fi
  rm -f "$f"
}

# ---------- the python side: an in-memory tar of decrypted items ----------
#
# VAULT_TAR_PY MODE DIR — identity line(s) on stdin (may be empty for a vault
# without .age files), a tar stream on stdout; every member 0600, no owner.
#   files DIR     every file under DIR (a profile's mirrored files), `.age` stripped
#   export VAULT  the whole vault except locks/, `.age` members as their plaintext
# Each ciphertext is decrypted by `age -d -i -` with the identity on its stdin;
# the plaintext exists only in this process and the pipe to the consumer.
# shellcheck disable=SC2016  # a python program, not shell
VAULT_TAR_PY='import io, os, subprocess, sys, tarfile, time
mode, root = sys.argv[1], sys.argv[2]
skip_prefix = sys.argv[3] if len(sys.argv) > 3 else ""
ident = sys.stdin.buffer.read()
now = int(time.time())

def decrypt(path):
    if not ident.strip():
        sys.stderr.write("vault: %s is encrypted and no identity was given\n" % path)
        sys.exit(1)
    r = subprocess.run(["age", "-d", "-i", "-", path], input=ident, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        sys.stderr.write("vault: cannot decrypt %s: %s\n" % (path, r.stderr.decode(errors="replace").strip()))
        sys.exit(1)
    return r.stdout

skip = {".DS_Store"}
members = []
for d, dirs, fs in os.walk(root):
    rel_d = os.path.relpath(d, root)
    if mode == "export" and (rel_d == "locks" or rel_d.startswith("locks" + os.sep)):
        dirs[:] = []
        continue
    for n in fs:
        if n in skip or n.startswith(".fleet.") or n.endswith(".rotating"):
            continue
        if mode == "export" and rel_d == "." and n in ("recipient.txt", "digest.key"):
            continue        # bound to the key of this machine; a restore gets a fresh one from fleet vault encrypt
        p = os.path.join(d, n)
        rel = os.path.relpath(p, root)
        if mode == "files" and skip_prefix and rel.startswith(skip_prefix):
            continue        # left in the vault, not shipped
        if n.endswith(".age"):
            members.append((rel[:-4], p, True))
        elif not os.path.isfile(p + ".age"):      # a plaintext shadowed by its .age is stale
            members.append((rel, p, False))
members.sort()
out = tarfile.open(fileobj=sys.stdout.buffer, mode="w|")
for name, p, enc in members:
    data = decrypt(p) if enc else open(p, "rb").read()
    ti = tarfile.TarInfo(name=name)
    ti.size = len(data); ti.mode = 0o600; ti.mtime = now
    ti.uid = ti.gid = 0; ti.uname = ti.gname = ""
    out.addfile(ti, io.BytesIO(data))
out.close()
sys.stdout.buffer.flush()
'

# vault_tar MODE DIR [SKIP_PREFIX] — see VAULT_TAR_PY; the identity is piped in
# by the caller. SKIP_PREFIX (files mode): members under it are left out.
vault_tar() { python3 -c "$VAULT_TAR_PY" "$1" "$2" "${3:-}"; }

# ---------- commands ----------

# fleet vault status — backend, recipient, whether the key is reachable, what
# is encrypted and what is still plaintext. Read-only, exit 0.
cmd_vault_status() {
  local b rb plain nenc nplain
  vault_require
  b=$(vault_backend); rb=$(vault_recipient_backend)
  printf 'age:        %s\n' "$(have age && age --version 2>/dev/null || echo 'not installed')"
  printf 'backend:    %s (%s)%s\n' "$b" "$(vault_backend_describe)" "$([ -n "$rb" ] && [ "$rb" != "$b" ] && printf ' WARNING: the key was created with backend %s; set FLEET_VAULT_KEY_BACKEND=%s' "$rb" "$rb")"
  if vault_encrypted; then
    printf 'recipient:  %s (%s)\n' "$(grep -v '^#' "$(vault_recipient_file)" | head -1)" "$(vault_recipient_file)"
    if vault_unlocked; then printf 'key:        reachable\n'; else printf 'key:        UNREACHABLE: %s\n' "$(vault_locked_hint)"; fi
  else
    printf 'recipient:  none (vault not encrypted yet)\nkey:        none\n'
  fi
  nenc=$(vault_age_items | grep -c . || true)
  plain=$(vault_plain_items); nplain=$(printf '%s' "$plain" | grep -c . || true)
  printf 'encrypted:  %s file(s)\n' "$nenc"
  if [ "$nplain" = 0 ]; then printf 'plaintext:  none\n'
  else printf 'plaintext:  %s file(s): %s\n            next: fleet vault encrypt\n' "$nplain" "$(printf '%s' "$plain" | tr '\n' ' ')"; fi
  [ -f "$FLEET_VAULT/digest.key" ] && printf 'digest.key: present (legacy; removed by fleet vault encrypt once nothing is plaintext)\n'
  return 0
}

# fleet vault encrypt — migrate: create the key if there is none, encrypt
# every plaintext item (verified round-trip), remove the plaintext copies and
# the legacy digest key. Idempotent; refuses when the key cannot be reached.
cmd_vault_encrypt() {
  local items n=0 rel
  vault_require
  age_ensure
  vault_key_ensure
  vault_identity_require >/dev/null
  items=$(vault_plain_items)
  if [ -z "$items" ]; then
    ok "vault: nothing to encrypt; $(vault_age_items | grep -c . || true) encrypted file(s)"
  else
    n=$(printf '%s\n' "$items" | grep -c .)
    log "encrypting $n plaintext file(s) to the vault recipient (round-trip checked, then the plaintext is removed)"
    printf '%s\n' "$items" | while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      vault_encrypt_item "$rel"
      log "  $rel -> $rel.age"
    done || exit 1
    ok "vault: $n file(s) encrypted"
  fi
  if [ -f "$FLEET_VAULT/digest.key" ] && [ -z "$(vault_plain_items)" ]; then
    rm -f "$FLEET_VAULT/digest.key"
    log "legacy digest.key removed: the desired-state digest is now computed over the ciphertexts, so every node is re-provisioned once"
  fi
  audit "vault.encrypt" "-" "ok $n"
}

# fleet vault rotate-key — a new identity: stored as the incoming key first,
# every ciphertext re-encrypted into a temp file next to it (verified against
# the old plaintext), then swapped in together with the recipient; only then
# the new identity replaces the old one and the incoming entry is dropped. A
# crash anywhere leaves a vault that still decrypts (both keys are offered
# while the incoming entry exists); rerunning finishes with a fresh key.
cmd_vault_rotate_key() {
  local old new rcpt f n lock
  vault_require
  vault_encrypted || die "the vault is not encrypted yet" "run: fleet vault encrypt"
  need age "$AGE_INSTALL_HINT"; need age-keygen "$AGE_INSTALL_HINT"
  [ -z "$(vault_plain_items)" ] || die "plaintext secrets are still in the vault" "run: fleet vault encrypt first"
  old=$(vault_identity) || die "the vault key is unreachable ($(vault_backend_describe))" "$(vault_locked_hint)"
  lock=$(master_lock_path)
  lock_acquire "$lock" 30 || die "a fleet sync or reconcile is running (lock $lock)" "retry in a minute"
  # shellcheck disable=SC2064  # expand now: the lock path is fixed
  trap "lock_release '$lock' $$" EXIT
  vault_rotating_clean
  new=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-') || die "age-keygen failed"
  rcpt=$(printf '%s\n' "$new" | age-keygen -y 2>/dev/null) || die "age-keygen -y failed"
  printf '%s\n' "$new" | vault_backend_set "$VAULT_KEY_NEXT" || die "could not store the new key in the $(vault_backend) backend ($(vault_backend_describe))"
  _VAULT_ID=""
  n=$(vault_age_items | grep -c . || true)
  if ! vault_age_items | while IFS= read -r f; do
       [ -n "$f" ] || continue
       vault_rotate_one "$f" "$old" "$new" "$rcpt" || { warn "re-encryption of $f failed"; exit 1; }
     done; then
    vault_rotating_clean
    vault_backend_del "$VAULT_KEY_NEXT"
    die "key rotation aborted; nothing was changed" "fleet vault status; check that the current key decrypts: fleet secrets list"
  fi
  # swap: the files first (both keys decrypt meanwhile), then the recipient, then the backend
  vault_age_items | while IFS= read -r f; do
    [ -n "$f" ] || continue
    mv -f "$FLEET_VAULT/$f.rotating" "$FLEET_VAULT/$f"
  done
  { printf '# fleet vault: backend=%s account=%s\n# the private key is in that backend (%s); this file is the public recipient\n' \
      "$(vault_backend)" "$(vault_account)" "$(vault_backend_describe)"; printf '%s\n' "$rcpt"; } | atomic_write "$(vault_recipient_file)" 0644
  printf '%s\n' "$new" | vault_backend_set "$VAULT_KEY_SERVICE" \
    || die "could not store the new key as the current one; the incoming entry still decrypts the vault" "rerun: fleet vault rotate-key"
  vault_backend_del "$VAULT_KEY_NEXT"
  old=""; new=""; _VAULT_ID=""
  lock_release "$lock" $$; trap - EXIT
  ok "vault key rotated: $n file(s) re-encrypted to $rcpt; the old key is gone from the $(vault_backend) backend"
  audit "vault.rotate" "-" "ok $n"
}

# vault_rotate_one REL OLD NEW RCPT — REL decrypted with OLD and re-encrypted
# to RCPT as REL.rotating (0600, same directory), then both decryptions
# compared byte for byte. Plaintext flows through pipes only.
vault_rotate_one() {
  local f="$FLEET_VAULT/$1" old=$2 new=$3 rcpt=$4
  ( umask 077; printf '%s\n' "$old" | age -d -i - "$f" | age -r "$rcpt" >"$f.rotating" ) || return 1
  cmp -s <(printf '%s\n' "$old" | age -d -i - "$f") <(printf '%s\n' "$new" | age -d -i - "$f.rotating")
}

# vault_rotating_clean — drop the temp files of an interrupted rotation.
vault_rotating_clean() {
  find "$FLEET_VAULT" -type f -name '*.rotating' ! -path "$FLEET_VAULT/locks/*" -exec rm -f {} + 2>/dev/null || true
}

# fleet vault export FILE — the whole vault, decrypted, as a tar inside one
# age file protected by a passphrase you type (age -p). For an offline backup:
# the archive holds every secret and key in plaintext once opened.
cmd_vault_export() {
  local file=${1:-}
  [ -n "$file" ] || die "usage: fleet vault export FILE"
  vault_require
  need age "$AGE_INSTALL_HINT"
  [ -t 2 ] || die "fleet vault export needs a terminal: age asks for the passphrase there" "run it interactively"
  if vault_encrypted; then vault_identity_require >/dev/null; fi
  log "export: the archive contains the vault in plaintext (secrets, SSH keys, API credentials, registry); keep it offline"
  if ! { vault_identity 2>/dev/null || true; } | vault_tar export "$FLEET_VAULT" | age -p -o "$file"; then
    rm -f "$file"; die "export failed" "fleet vault status"
  fi
  chmod 0600 "$file"
  ok "exported to $file (open with: age -d $file | tar -tf -)"
  audit "vault.export" "-" ok
}
