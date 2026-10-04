# Internal contract between master and node code

This file fixes the interfaces so `lib/master.sh`, `lib/node.sh`,
`lib/join.sh`, `lib/harness.sh` and `lib/tools/*.sh` can change independently.
Change it only together with every side that uses it.

## Repos and directories

Three repos, configured in `fleet.conf` (`FLEET_CODE_REPO`, `FLEET_CONFIG_REPO`,
`FLEET_MEMORY_REPO`; defaults empty). Only the config repo is required: an
empty code repo means provision re-ships the code each time, an empty memory
repo switches shared memory off everywhere (no key, clone, timer, seed):

| | On the master | On a node | Deploy key | Remote alias on nodes |
|---|---|---|---|---|
| code (fleeter) | `$FLEET_ROOT` = the checkout `fleet` runs from | `~/.local/share/fleet` (`FLEET_SHARE`) | `~/.ssh/fleet_code`, read-only; **none** when the URL is `https://` or empty | `github-fleet-code` |
| config (yours) | `$FLEET_CONFIG_DIR`, recorded in `~/.config/fleet/fleet.conf` by `fleet init master --config-dir` | `~/.local/share/fleet-config` (`FLEET_CONFIG_DIR` default) | `~/.ssh/fleet_config`, read-only | `github-fleet-config` |
| memory (yours) | any clone | `$FLEET_MEMORY_DIR` (default `~/fleet-memory`) | `~/.ssh/fleet_memory`, read-write | `github-fleet-memory` |

GitHub deploy keys are unique per repository, so a node has one key per repo.
`lib/join.sh` writes the three aliases into `~/.ssh/config`:

```
Host github-fleet-code     HostName github.com  User git  IdentityFile ~/.ssh/fleet_code     IdentitiesOnly yes
Host github-fleet-config   HostName github.com  User git  IdentityFile ~/.ssh/fleet_config   IdentitiesOnly yes
Host github-fleet-memory   HostName github.com  User git  IdentityFile ~/.ssh/fleet_memory   IdentitiesOnly yes
```

`git@github.com:owner/repo.git` and `ssh://git@github.com/owner/repo.git` URLs
are rewritten to `github-fleet-<x>:owner/repo.git` on nodes
(`node_repo_alias_url`); any other URL (https, non-GitHub, a local path) is
used unchanged. `FLEET_CODE_REMOTE`, `FLEET_CONFIG_REMOTE`, `FLEET_MEMORY_REMOTE`
override the derived URL (tests, local bare repos).

Config loading (`fleet_load_config` in `lib/common.sh`, also run by every
plug-in subprocess): `config/defaults.conf` → `$FLEET_HOME/fleet.conf` →
`$FLEET_CONFIG_DIR/fleet.conf` → `$FLEET_HOME/fleet.conf`. `FLEET_CONFIG_DIR`
comes from the environment (which wins over the local file) or the local file,
default `~/.local/share/fleet-config`. `config_dir_require` dies with the next
step when the directory is missing.

## Enrolment (no node→master traffic at all)

1. `fleet invite` (master) creates `vault/nodes/pending/<nonce>.json`:
   `{"nonce","name","profile","ephemeral","created","expires","ts_key_id","user"}`
   (`user` = the login the master will ssh to, `--user NAME`, default the
   master's own login; `docker/spawn.sh` passes `--user fleet`) and prints one
   command line that contains the gzip+base64 of `lib/join.sh`. The join script
   then asks for the **invite code**: base64 of JSON
   `{"v":1,"ts_auth_key","nonce","name","master_pubkey","master_user","tag","hostname_prefix","tools"}`
   (`hostname_prefix` = `FLEET_HOSTNAME_PREFIX`, a code without it means `fleet-`;
   `tools` = the master's `FLEET_TOOLS`, so `join_privileged` can skip the
   browser without `chrome` and docker-ce without `devtools`/`cliproxy`; a code
   without it, or with an unparsable value, means "install everything").
   `FLEET_INVITE_CODE` env or `FLEET_INVITE_FILE` path skip the prompt (Docker).
2. `lib/join.sh` (node, standalone — sources nothing) installs Tailscale if
   missing, runs `tailscale up --auth-key=file:<tmp> --advertise-tags=<tag>
   --hostname=<prefix><name>`, enables a key-only SSH server (verified with
   `sshd -T -C`), runs the privileged OS steps once (marker
   `~/.config/fleet/privileged_done`), appends `master_pubkey` to
   `~/.ssh/authorized_keys`, generates `~/.ssh/fleet_code`, `fleet_config`,
   `fleet_memory` (ed25519, no passphrase), writes the ssh aliases and
   `~/.config/fleet/enrol.json` (0600):
   `{"nonce","name","user","os","arch","container":bool,"joined"}`.
   Then it prints "waiting for master" and exits 0.
3. `fleet reconcile` (master) lists tailnet peers with the fleet tag that are
   online and whose Tailscale `ID` is not in `vault/nodes/`. For each it runs
   `ssh <user>@<dnsname> cat ~/.config/fleet/enrol.json` with the master key.
   If the nonce matches an unexpired pending invite, the master:
   - **claims** it atomically: `mv nodes/pending/<nonce>.json
     nodes/claimed/<nonce>.<ts-id>.json` before any key is created;
   - registers the deploy keys — `code` (read-only; only when
     `repo_needs_key "$FLEET_CODE_REPO"`), `config` (read-only), `memory`
     (read-write; only when `FLEET_MEMORY_REPO` is set, otherwise the node's
     `fleet_memory.pub` is never read and `github_keys.memory` is `null`) —
     via `gh api` when the GitHub CLI is logged in, else with the
     token in `vault/github.json`. Each key id is written into the claimed file
     (`gh_code_key`, `gh_config_key`, `gh_memory_key`) the moment it exists,
     with the `owner/repo` it was created on (`gh_code_repo`, `gh_config_repo`,
     `gh_memory_repo`);
   - writes `vault/nodes/<ts-id>.json`, removes the claimed file, provisions.
   If a later step fails, the recorded keys are deleted (rollback) and the file
   goes back to `pending/` while unexpired; otherwise its auth key is revoked
   and the file dropped. A rollback delete that fails lands in
   `pending_cleanup` on a tombstone `vault/nodes/rollback-<ts-id>-<nonce>.json`
   (`revoked_reason: enrol`), retried by every reconcile and forgotten once
   clean. The expiry sweep rolls back a claimed file left by a crash the same way.

## Registry: `vault/nodes/<ts-id>.json`

```json
{
  "id": "nXXXXCNTRL",            // tailscale stable node ID
  "name": "studio", "hostname": "fleet-studio", "dnsname": "fleet-studio.tail1234.ts.net",
  "user": "me", "os": "macos", "arch": "arm64", "container": false,
  "profile": "full", "ephemeral": false,
  "state": "enrolled",           // enrolled | provisioned | revoked
  "enrolled": "2026-01-31T10:00:00Z",
  "provisioned": "…", "provisioned_digest": "…",
  "applied_commit": "<sha>+<sha>",                              // what the node reported after the last provision
  "github_keys": {                                              // each: the key id and the repo it was created on
    "code":   {"id": 123, "repo": "owner/fleeter"},             // null without a code key
    "config": {"id": 124, "repo": "owner/fleet-config"},
    "memory": {"id": 125, "repo": "owner/fleet-memory"}
  },
  "secrets_sent": ["CLAUDE_CODE_OAUTH_TOKEN"],                  // names only
  "files_sent": ["projects/app/.env"],
  "missing_since": "",           // set when the device is absent from the API device list
  "t3_access": true,             // absent/true: T3 client key authorised by provision, `Host fleet-<name>` rendered;
                                 // false after `fleet t3 revoke` until `fleet t3 setup NODE`
  "revoked": "…", "revoked_reason": "kick|gone|enrol",          // only on revoked entries
  "pending_cleanup": []          // "ts:device:<ts-id>" | "gh:<code|config|memory>:<id>:<owner/repo>" | "stop:<ts-id>" | "t3:<ts-id>"
}
```

Entries written before the repo was recorded hold a plain integer per key
(`"config": 124`) and produce `gh:config:124` items without a slug; those, and
only those, are deleted against the current `FLEET_*_REPO` URL (`registry_gh_key`
reads both forms). A `gh:…:<id>:<owner/repo>` item is always deleted on that
repo, so a 404 means the key is really gone.

A revoked entry is a **tombstone**: never deleted while `pending_cleanup` is
non-empty. Reconcile retries every tombstone's list first, before and
independently of the device-list API call; a `stop:<ts-id>` item (remote
`fleet leave` that failed during kick) and a `t3:<ts-id>` item (T3 revoke on
the node that failed, `t3_node_revoke` in `lib/t3.sh`) are attempted only while
the peer is online and dropped as soon as the device is absent from the device list. It
then revokes a node that has been `missing_since` longer than the grace period
(1 h ephemeral, `FLEET_MISSING_GRACE_HOURS` otherwise) and forgets the
tombstone once cleanup is empty and the device stayed gone for that period.
Every read-modify-write (`registry_set`) runs under `vault/locks/.registry` in
addition to any node lock (node lock first, never the other way round).

**Desired-state digest** = `sha256(code_rev + "+" + config_rev + "\n" +
"secrets/minimal.env\0" + fp + "\0" [+ "secrets/full.env\0" + fp + "\0" for
profile full] + "files/<rel>\0" + fp + "\0" per mirrored file, sorted by rel)`
where `code_rev` / `config_rev` are the HEADs of `$FLEET_ROOT` and
`$FLEET_CONFIG_DIR` (or tree hashes without a commit; `none` for a missing
config dir), `rel` is the path as it lands on the node (`.age` stripped) and
`fp` is the item's fingerprint: the sha256 of its ciphertext (`<item>.age`),
empty for a missing item, or — only for an item still in plaintext on a vault
that has not run `fleet vault encrypt` — HMAC-SHA256 keyed with
`vault/digest.key` over the plaintext. No key is needed for an encrypted
vault, and a re-encryption (same value, or `vault rotate-key`) changes the
digest once.

## Vault layout (master, 0700 dirs / 0600 files)

Secret-bearing items are age ciphertexts (`lib/vault.sh`): `<name>.age`,
encrypted to the recipient in `recipient.txt`; the private identity is in the
key backend (`FLEET_VAULT_KEY_BACKEND`: keychain item / secret-tool entry
`fleet-vault` for `$USER`, or `$FLEET_HOME/vault.key`), never in the vault.
Readers (`vault_read PATH`) prefer `PATH.age` and fall back to a plaintext
`PATH` left from before the migration; writers (`vault_write PATH.age`) always
encrypt and remove the plaintext counterpart.

```
vault/
  recipient.txt            `# fleet vault: backend=<b> account=<u>` + the age1… recipient (0644, public)
  secrets/minimal.env.age  KEY='value' lines, shell-safe single-quoted, encrypted
  secrets/full.env.age     full = minimal.env + full.env
  files/<profile>/<path under $HOME>.age      mirrored files, encrypted
  files/full/.cli-proxy-api/{config.yaml,auth/…}.age   CLIProxyAPI state (full only)
  ssh/fleet_master, ssh/fleet_master.pub      plain (ssh reads them)
  ssh/t3_client, ssh/t3_client.pub        the key T3 Code uses towards nodes (lib/t3.sh); created by init master / t3 setup
  ssh/known_hosts          pinned node host keys, one plain `<dnsname> ssh-ed25519 <key>` line per node (host_key_pin)
  digest.key               legacy: only while plaintext items exist; `fleet vault encrypt` removes it
  tailscale.json.age       {"oauth_client_id","oauth_client_secret","tailnet":"-"}, minted by init master
                           (keyType client, scopes auth_keys devices:core policy_file:read, tag-scoped)
  github.json.age          {"token"}   fallback only
  sync.json                {"tools_pushed": "<ISO>"}  last time `fleet sync` ran `fleet update` on the nodes
  nodes/<ts-id>.json, nodes/pending/<nonce>.json, nodes/claimed/<nonce>.<ts-id>.json, nodes/rollback-*.json
  locks/<ts-id>/pid        pid of the provision worker (background subshell)
  locks/<ts-id>/token      ownership token, renewed whenever the lock changes hands (lock_break)
  locks/.registry/
  locks/.sync/             master-wide lock: held by `fleet sync` for its whole run and by `fleet reconcile`
                           for its run; a second sync or a reconcile skips (exit 0) while it is held
  audit.log
```

Policy: `fleet init master`, `policy check` and `doctor` fetch the live policy
(`GET /api/v2/tailnet/-/acl`) and require the template's `tagOwners` and
`grants` and no `grants`/`acls`/`ssh` rule with `*`, `autogroup:tagged`,
`autogroup:danger-all` or the fleet tag as `src`; any other `src` that is not a
user login, `group:…`, `autogroup:member`, `autogroup:admin` or
`autogroup:owner` is rejected unless every `dst` is the fleet tag.
`policy apply` shows a unified diff, requires the typed word `apply`, POSTs
with `If-Match: <ETag>` using a one-off API access token. `doctor` runs
`nc -z -w 3 <master ip> 22|443` and `nc -z -w 3 <other node ip> 22` from every
online provisioned node and fails on any success or missing `nc`.

## What the master runs on a node during provision

All via `ssh -i vault/ssh/fleet_master -o BatchMode=yes -o UserKnownHostsFile=vault/ssh/known_hosts
-o HostKeyAlgorithms=ssh-ed25519 -o StrictHostKeyChecking=<yes|accept-new> <user>@<dnsname>` (`ssh_to`):
`yes` once the node's host key is pinned, `accept-new` only for the first contact
with a node (enrolment, step 3 above), after which `host_key_pin` reads
`/etc/ssh/ssh_host_ed25519_key.pub` over that session, requires it to equal the
key the connection saw, and writes the pin (0600). Provision and reconcile pin a
node that predates pinning on their next contact.

1. Ship code: `git archive HEAD` of `$FLEET_ROOT` (tar of the tree without a
   commit) `| ssh … 'mkdir -p ~/.local/share/fleet && tar -x -C ~/.local/share/fleet'`
   — unless the node already has `~/.local/share/fleet/.git` and
   `FLEET_CODE_REPO` is set (then `fleet pull` tracks the repo).
2. Ship config: same for `$FLEET_CONFIG_DIR` into `~/.local/share/fleet-config`,
   governed by `FLEET_CONFIG_REPO`.
0. The vault key must be readable (`vault_unlocked`) when the vault is
   encrypted; otherwise the provision is skipped with a warning (exit 4,
   audit `skip vault-locked`) before anything is shipped, and the next
   reconcile/sync retries.
3. Ship secrets: the profile's env decrypted into memory (`secrets_env`; a
   decryption failure aborts, never ships an empty file), then
   `printf '%s\n' "$env" | ssh … 'umask 077; mkdir -p ~/.config/fleet; cat > ~/.config/fleet/secrets.env.tmp && mv … secrets.env'`.
4. Ship files: `vault_identity | vault_tar files vault/files/<profile> | ssh … '<PROVISION_FILES_SCRIPT>'`
   — the tar is built in memory from the decrypted items (members 0600, paths
   without `.age`); on the node:
   `umask 077`, `mktemp -d ~/.config/fleet/stage.XXXXXX`, `tar -xf -` into it,
   `mkdir -p` + `mv -f` each file to its path under `$HOME` (same filesystem:
   an atomic rename), `rm -rf` the staging dir. With `--refresh-proxy-auth`
   also `touch ~/.cli-proxy-api/.force`.
4b. T3 client key (only when `vault/ssh/t3_client` exists, i.e. after
   `fleet init master` with `FLEET_T3_REMOTE=1` or after `fleet t3 setup`): the desired
   `authorized_keys` line — `T3_CLIENT_KEY_OPTIONS <type> <key> fleet-t3-client`
   (`lib/common.sh`), or an empty line when the registry says `t3_access: false`
   — is piped into `ssh … "sh -c '<T3_AUTHKEY_SCRIPT>'"`, which drops every line
   whose comment is `fleet-t3-client`, appends the new one, and rewrites the
   file (0600, tmp + mv) only when it changed.
5. Update the node's checkouts: `ssh … '~/.local/share/fleet/fleet pull --no-apply'`
   (fetch + reset to `origin/main` for code and config, converting the tar
   copies from step 1/2 into checkouts; a failure only warns).
6. Run: `ssh … '~/.local/share/fleet/fleet apply --from-master <digest>'`.
   Exit 0 = success; the node writes the digest to `~/.config/fleet/applied`
   and `<code>+<config>` to `applied_commit`.
7. Read `~/.config/fleet/applied_commit` back into the registry
   (`applied_commit`); when it differs from the master's `code_rev+config_rev`
   the provision is audited `ok revs-differ` and a warning names both.
The registry state is rechecked before every step; a concurrent kick aborts.

## T3 Code remote access (`lib/t3.sh`)

Master files: `vault/ssh/t3_client(.pub)`, `vault/ssh/known_hosts`,
`~/.ssh/config.d/fleet` (0600, regenerated by `t3 setup`, `reconcile`, `kick`,
`t3 revoke`; one block per registered node that is not revoked, has
`t3_access` ≠ false and a pinned host key):

```
Host fleet-<name>
  HostName <dnsname>
  User <user>
  IdentityFile "<vault>/ssh/t3_client"
  IdentitiesOnly yes
  UserKnownHostsFile "<vault>/ssh/known_hosts"
  StrictHostKeyChecking yes
  HostKeyAlgorithms ssh-ed25519
  HashKnownHosts no
  ForwardAgent no
  ForwardX11 no
```

`Include ~/.ssh/config.d/fleet` is inserted once as the first line of
`~/.ssh/config` (`backup_once` → `config.pre-fleet`; created 0600 when missing;
an existing file keeps its mode). Neither file is created while there is no
block to write (no node with T3 access yet): a fleet that never uses T3 leaves
`~/.ssh` on the master untouched.

Node side, over the master key, as POSIX scripts on stdin to `sh -s`
(`T3_NODE_LIST_SH`, `T3_NODE_REVOKE_SH`) or over the T3 client key exactly as
T3 does it (`ssh fleet-<name> sh -l -s`, `T3_NODE_PROBE_SH`): the node's `t3`
CLI is the newest complete `~/.t3/runtime/versions/<v>/t3` (T3's archive
install, `.install-complete` present), else `t3` on PATH. Revoke runs `t3 auth
session revoke <id>` for every session with subject `one-time-token`, `t3 auth
pairing revoke <id>` for every pairing token, kills the pid recorded in each
`~/.t3/ssh-launch/<key>/` whose `managed` file says `managed` and whose command
line is a `t3 … serve`, and removes those state files. `fleet kick` runs the
same, then `fleet leave`.

## Node files

```
~/.local/share/fleet/            fleeter code (git checkout after the first pull, remote github-fleet-code)
~/.local/share/fleet-config/     config repo (git checkout after the first pull, remote github-fleet-config)
~/.local/bin/fleet, fleeter      symlinks to ~/.local/share/fleet/fleet (the master gets ~/.local/bin/fleeter too)
~/.claude/skills/fleet, ~/.agents/skills/fleet, ~/.cursor/skills/fleet
                                 fleeter's own agent skill (skills/fleet), written by harness_apply into the
                                 skill dir of every harness present (dir in $HOME or rendered, or its tool in
                                 FLEET_TOOLS); a skills/fleet/ in the config repo replaces it; listed in
                                 harness.manifest + manifest
~/.config/fleet/enrol.json       written by join
~/.config/fleet/secrets.env      from master, 0600
~/.config/fleet/env.sh           generated by apply: sources secrets.env, exports PATH (mise shims,
                                 ~/.local/bin), FLEET_NODE, FLEET_NODE_NAME; ANTHROPIC_BASE_URL (+ AUTH_TOKEN
                                 in local mode) only while cliproxy is enabled for the node (node_proxy_mode:
                                 cliproxy in FLEET_TOOLS and a local proxy with a client key, or remote mode /
                                 container with FLEET_PROXY_URL), otherwise `unset` before secrets.env is sourced
~/.config/fleet/stage.XXXXXX     transient 0700 staging dir for mirrored files (provision step 4)
~/.config/fleet/applied          last applied digest; applied_at
~/.config/fleet/applied_commit   "<code HEAD>+<config HEAD>" last applied successfully (pull compares against it)
~/.config/fleet/privileged_done  join finished the privileged OS steps; plug-ins skip them
~/.config/fleet/manifest         files fleet owns (one path per line), for cleanup; harness.manifest, harness.claude-mcp
~/.config/fleet/status.json      written by apply/status
~/.config/fleet/memory.state     state=ok|conflict|missing|off (off: no memory remote configured), last_sync, detail
~/.config/fleet/fleet.conf       local overrides (optional)
~/.config/fleet/locks/apply      apply/pull lock; logs/<job>.log; daemon.pid, daemon.state
~/.ssh/authorized_keys           master key line (join) + one `… fleet-t3-client` line (provision step 4b; absent after t3 revoke/kick)
```

Shell integration: apply adds exactly one block, between markers, to
`~/.zshrc`, `~/.bashrc` (whichever exist, plus `~/.profile` on Linux):

```
# >>> fleet >>>
[ -f "$HOME/.config/fleet/env.sh" ] && . "$HOME/.config/fleet/env.sh"
# <<< fleet <<<
```

On macOS apply also runs `launchctl setenv` for the proxy variables so GUI apps
see them, and `launchctl unsetenv` for both when the proxy is not enabled.

`fleet pull [--no-apply]`: takes the apply lock, brings `~/.local/share/fleet`
and `~/.local/share/fleet-config` to `origin/main` (clone, convert a tar copy,
or fetch + reset; `origin` is re-pointed when the configured URL differs), then
runs `apply` when `<code>+<config>` differs from `applied_commit` — unless
`--no-apply`. `fleet daemon` dispatches jobs through `$FLEET_BIN/fleet` once it
exists and `exec`s itself from there after a pull changed the code checkout.

## `fleet sync` (master)

One run, under `vault/locks/.sync`:

1. `sync_ff_repo code $FLEET_ROOT`, then `sync_ff_repo config $FLEET_CONFIG_DIR`:
   fast-forward the checked-out branch from its upstream (`branch.<b>.remote` /
   `branch.<b>.merge`, default `origin/<b>`) **only** when the tree has no
   uncommitted tracked changes and `HEAD` is an ancestor of the fetched tip.
   Detached HEAD, no remote, failed fetch (`GIT_SSH_COMMAND` BatchMode, no
   terminal prompt), dirty tree or diverged history: one `warn`, checkout left
   alone. A fast-forward is logged and audited (`sync.ff <code|config>`); a
   code fast-forward re-executes `fleet sync` once from the new checkout
   (`FLEET_SYNC_REEXEC=1`, same PID, lock kept).
2. `sync_publish_skills` (`lib/skills.sh`, `FLEET_SYNC_PUBLISH_SKILLS=1`):
   every `<dir>/<name>/SKILL.md` under `~/.claude/skills`, `~/.agents/skills`,
   `~/.codex/skills`, `~/.cursor/skills` (first source wins on a name
   collision; `synced`, `.system`, hidden names, `fleet` and `FLEET_SKILL_EXCLUDE`
   skipped; the name must match `[a-z0-9][a-z0-9-]{0,63}`) whose tree digest
   differs from `$FLEET_CONFIG_DIR/skills/<name>` (or which is missing there)
   is secret-scanned — a hit warns and skips that skill — then copied in
   (without `.git`, `.DS_Store`, `node_modules`, `__pycache__`), staged,
   committed as `publish skills: a, b` and pushed (`GIT_TERMINAL_PROMPT=0`,
   BatchMode; a failed push warns and is retried by the next sync). Never
   removes a skill from the repo; quiet when nothing changed; audited
   `sync.skills`.
3. `reconcile_run` (the body of `fleet reconcile`): enrol, provision every node
   whose desired digest changed, cleanups, absence tracking.
4. Every `FLEET_PUSH_TOOLS_EVERY` minutes (0 = never), when at least one
   provisioned node is online: `~/.local/bin/fleet update` on each of them in
   parallel, each under `with_timeout FLEET_SYNC_UPDATE_SECS` (900), one summary
   line, failures' output in `$FLEET_HOME/logs/update-<name>.log`, the run
   recorded in `vault/sync.json` (`tools_pushed`) and audited (`sync.tools`).

Quiet when nothing happened. `fleet reconcile` takes the same lock for its run
and skips with one line when it is held; `fleet sync` skips the same way.

## `fleet skill` (master; `list` also on nodes) — `lib/skills.sh`

A skill is `skills/<name>/` in the config repo with a `SKILL.md` whose YAML
frontmatter has `name` (and usually `description`). Nodes get every such
directory from `harness_apply` into `~/.claude/skills`, `~/.agents/skills` and
`~/.cursor/skills` (recorded in `harness.manifest`); a directory that drops out
of the repo is removed on the next apply by the manifest cleanup.

- `fleet skill add SOURCE [--name N] [--yes]`: SOURCE is a local directory, or a
  git URL `URL[#subdir][@ref]` (also `URL@ref`; the `@` of `git@host:` is not a
  ref) cloned with `git clone --depth 1 [--branch REF]` into a 0700
  `mktemp -d fleet-skill.XXXXXX` (a commit id falls back to a full clone +
  checkout), removed on exit. Order: validate (`SKILL.md`, frontmatter, `name`
  or `--name`, pattern `[a-z0-9][a-z0-9-]{0,63}`) → `harness_secret_scan` on the
  source (a hit aborts before anything is copied) → refuse an existing
  `skills/N` with a different tree digest unless `--yes` (identical: no-op,
  exit 0) → copy → `git add` → confirm unless `--yes` (declined: working tree
  restored, exit 1) → commit `add skill N` / `update skill N` → install into
  this machine's `harness_skill_targets` dirs (`_harness_install_dir`, both
  manifests) → push to `origin` (BatchMode) → `cmd_reconcile` unless
  `FLEET_SKILL_ADD_NO_SYNC=1`. Output lines: `added N to your fleet config` (or
  `updated …`), `published (secret scan clean)`, `pushed to K nodes` where K =
  `provision … ok` audit lines added by that reconcile, else `nodes pick it up
  on their next pull`. Audit: `skill.add|skill.update N pushed`.
- `fleet skill list [--json]`: master = `[ -d vault/nodes ]`. Rows: every
  `skills/*/SKILL.md` of the config repo (`config`; ON NODES? `yes` when
  committed and the upstream has it, `not pushed` when the path is dirty or in
  `@{upstream}..HEAD`), the bundled `skills/fleet` (`fleet`, unless the repo
  ships one), then skills present only in this machine's skill dirs
  (`local-only`, `no`; same exclusions as the auto-publish). Node: the
  `*/skills/*` paths of `harness.manifest`, one row per name, `config` when the
  config checkout has it, `fleet` for the bundled skill. JSON: array of
  `{name, source, description, path}` plus `on_nodes` on the master.
- `fleet skill remove N [--yes]`: confirm → `git rm --cached` + delete
  `skills/N` → commit `remove skill N` → delete `~/.claude/skills/N`,
  `~/.agents/skills/N`, `~/.cursor/skills/N` here (a symlink is unlinked, not
  followed) and drop them from both manifests → push → `cmd_reconcile` (same
  knob and output as add, `nodes drop it on their next pull`). Audit
  `skill.remove N pushed`.

## `fleet list --json` (master)

A JSON array, one object per registry entry (sorted by name) followed by one
per tagged tailnet peer the master has not enrolled (`state: "unknown"`).
`--offline` asks no node: `reachable` is `null` and `applied` comes from the
registry. Keys are stable; new ones may be added.

```json
{
  "name": "studio", "id": "nXXXXCNTRL", "host": "fleet-studio", "dnsname": "fleet-studio.tail1234.ts.net",
  "user": "me", "os": "macos", "arch": "arm64", "container": false, "profile": "full", "ephemeral": false,
  "online": true,                 // tagged peer listed Online by tailscale status
  "reachable": true,              // `fleet status --json` answered within FLEET_LIST_SECS (10 s); false = did not; null = not asked
  "state": "provisioned",         // enrolled | provisioning | provisioned | revoked | unknown
  "provisioning": false,          // a provision worker holds vault/locks/<id> right now
  "synced": "yes",                // yes | behind | "?" (nothing applied yet) | null (revoked, unknown)
  "provisioned": "…", "provisioned_age": "3h",
  "desired": {"code": "<sha>", "config": "<sha>", "digest": "<desired digest for the profile>"},
  "applied": {"code": "<sha>", "config": "<sha>", "digest": "<sha>", "at": "…",
              "source": "node"},  // node = from the node's status; registry = last provision; null = none
  "tools": {"claude": {"state": "ok", "detail": "…"}},   // the node's tools map; {} when not reached
  "memory": "ok",                 // ok | conflict | missing | off | null
  "proxy": "off",                 // ok | off (cliproxy not in the node's tools) | down | null
  "fleet": "0.3.0",               // the node's fleet version, null when not reached
  "missing_since": "", "cleanup_pending": []
}
```

`synced` is `behind` when the applied code or config revision differs from the
master's, or the applied digest differs from the desired one; `yes` otherwise.
The table (`fleet list`) prints NAME, HOST, ONLINE, STATE, SYNCED, LAST
PROVISION, TOOLS (`9 ok, 1 login: cursor`; `unreachable`; `cleanup-pending` on
a revoked tombstone), MEMORY, PROXY, FLEET; `-` where the JSON has `null`.

## `fleet status --json` (node) — consumed by `fleet nodes --live` and `fleet list`

```json
{
  "fleet": "0.3.0", "name": "studio", "os": "macos", "container": false,
  "applied": "<digest>", "applied_at": "…",
  "code_commit": "<sha>", "config_commit": "<sha>", "applied_commit": "<sha>+<sha>",
  "tools": {"claude": {"state": "ok", "detail": "2.1.0 env-token"}, "codex": {"state": "login", "detail": "run: fleet login codex"}},
  "memory": {"state": "ok|conflict|missing|off", "last_sync": "…", "detail": "…"},
  "timers": {"pull": true, "memory": true, "update": true},   // no "memory" key while the memory job is off
  "token_age_days": {"CLAUDE_CODE_OAUTH_TOKEN": 12},
  "updated": "…"
}
```

## Tool plug-in interface: `lib/tools/<name>.sh`

Each file defines three functions; `<name>` with `-` replaced by `_`:

- `tool_<name>_install` — converge: install if missing, configure. Idempotent.
  Must not call `sudo` unless `FLEET_INTERACTIVE=1` (only `join` sets it); if a
  privileged step is needed non-interactively, `warn` and return 0.
- `tool_<name>_update` — vendor updater; no-op if the tool self-updates.
- `tool_<name>_status` — print exactly one line `<state> <detail>`;
  state ∈ `ok | missing | login | error | skipped`.
- Optional `tool_<name>_login` — interactive login (device code / open URL).

Plug-ins run in a fresh `bash -e` (`node_tool_run`) with `lib/common.sh` and
`fleet_load_config` sourced; they may use helpers from `lib/common.sh` only and
read settings from `fleet.conf` (`FLEET_MISE_TOOLS`, `FLEET_PNPM`,
`FLEET_NPM_GLOBALS`, `FLEET_DOCKER_LOGINS`, `FLEET_PROXY_*`,
`FLEET_CHROME_DEVTOOLS_MCP`, `FLEET_PLAYWRIGHT_MCP`). Templates they render come
from `$FLEET_ROOT/templates/`.

## Harness rendering (`lib/harness.sh`)

Inputs from `$FLEET_CONFIG_DIR`: `AGENTS.md`, `harness/<harness>/…`, `skills/<name>/`
(filled by `fleet skill add`, the sync auto-publish, or capture).
Placeholders: `${HOME}`, `${FLEET_NODE}`, `${FLEET_NODE_NAME}`, `${FLEET_MEMORY_DIR}`
and the secrets of `secrets.env`; only `${UPPER_CASE}` is substituted. Capture
(`harness_capture`, master) writes back into `$FLEET_CONFIG_DIR/harness` and
`/skills` and never touches `README.md`, `SECRETS.md`, `claude/CLAUDE.md`,
`codex/AGENTS.md`. Ownership on nodes: `examples/fleet-config/harness/README.md`.

## Scheduling

`lib/node.sh` installs per-OS jobs, all running as the user, never root:
macOS `~/Library/LaunchAgents/dev.fleet.<job>.plist` (`StartInterval`); Linux
with a systemd user session `~/.config/systemd/user/fleet-<job>.{service,timer}`,
otherwise crontab lines tagged `# fleet:<job>`; containers none (`fleet daemon`).
Jobs: `pull` (FLEET_PULL_EVERY), `memory` (FLEET_MEMORY_EVERY; only while a
memory remote is configured — `node_job_enabled`, and a job switched off since
the last apply loses its unit/plist), `update` (FLEET_UPDATE_EVERY). Master
(`install_master_schedule`, written by `fleet init master` and `fleet schedule
install`, rewritten and reloaded only when the content changed): `reconcile`
(FLEET_RECONCILE_EVERY, log `$FLEET_HOME/reconcile.log`) and `sync`
(FLEET_SYNC_EVERY, log `$FLEET_HOME/sync.log`); both honour `FLEET_NO_SCHEDULER`
(files written, nothing loaded).
