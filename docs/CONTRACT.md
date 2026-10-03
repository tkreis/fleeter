# Internal contract between master and node code

This file fixes the interfaces so `lib/master.sh`, `lib/node.sh`,
`lib/join.sh`, `lib/harness.sh` and `lib/tools/*.sh` can change independently.
Change it only together with every side that uses it.

## Repos and directories

Three repos, configured in `fleet.conf` (`FLEET_CODE_REPO`, `FLEET_CONFIG_REPO`,
`FLEET_MEMORY_REPO`; defaults empty, commands that need them die with a hint):

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
   `{"v":1,"ts_auth_key","nonce","name","master_pubkey","master_user","tag","hostname_prefix"}`
   (`hostname_prefix` = `FLEET_HOSTNAME_PREFIX`; a code without it means `fleet-`).
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
     (read-write) — via `gh api` when the GitHub CLI is logged in, else with the
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
  "revoked": "…", "revoked_reason": "kick|gone|enrol",          // only on revoked entries
  "pending_cleanup": []          // "ts:device:<ts-id>" | "gh:<code|config|memory>:<id>:<owner/repo>" | "stop:<ts-id>"
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
`fleet leave` that failed during kick) is attempted only while the peer is
online and dropped as soon as the device is absent from the device list. It
then revokes a node that has been `missing_since` longer than the grace period
(1 h ephemeral, `FLEET_MISSING_GRACE_HOURS` otherwise) and forgets the
tombstone once cleanup is empty and the device stayed gone for that period.
Every read-modify-write (`registry_set`) runs under `vault/locks/.registry` in
addition to any node lock (node lock first, never the other way round).

**Desired-state digest** = `sha256(code_rev + "+" + config_rev + "\n" + H + "\n")`
where `code_rev` / `config_rev` are the HEADs of `$FLEET_ROOT` and
`$FLEET_CONFIG_DIR` (or tree hashes without a commit; `none` for a missing
config dir) and `H` = HMAC-SHA256 keyed with `vault/digest.key` (32 random
bytes, 0600, never shipped) over the profile's secret file bytes (`minimal.env`,
then `full.env` for profile full) and each mirrored file's path + content,
sorted.

## Vault layout (master, 0700 dirs / 0600 files)

```
vault/
  secrets/minimal.env      KEY='value' lines, shell-safe single-quoted
  secrets/full.env         full = minimal.env + full.env
  files/<profile>/<path under $HOME>          mirrored files
  files/full/.cli-proxy-api/{config.yaml,auth/…}   CLIProxyAPI state (full only)
  ssh/fleet_master, ssh/fleet_master.pub
  digest.key
  tailscale.json           {"oauth_client_id","oauth_client_secret","tailnet":"-"}, minted by init master
                           (keyType client, scopes auth_keys devices:core policy_file:read, tag-scoped)
  github.json              {"token"}   fallback only
  nodes/<ts-id>.json, nodes/pending/<nonce>.json, nodes/claimed/<nonce>.<ts-id>.json, nodes/rollback-*.json
  locks/<ts-id>/pid        pid of the provision worker (background subshell)
  locks/<ts-id>/token      ownership token, renewed whenever the lock changes hands (lock_break)
  locks/.registry/
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

All via `ssh -i vault/ssh/fleet_master -o BatchMode=yes -o StrictHostKeyChecking=accept-new <user>@<dnsname>`.

1. Ship code: `git archive HEAD` of `$FLEET_ROOT` (tar of the tree without a
   commit) `| ssh … 'mkdir -p ~/.local/share/fleet && tar -x -C ~/.local/share/fleet'`
   — unless the node already has `~/.local/share/fleet/.git` and
   `FLEET_CODE_REPO` is set (then `fleet pull` tracks the repo).
2. Ship config: same for `$FLEET_CONFIG_DIR` into `~/.local/share/fleet-config`,
   governed by `FLEET_CONFIG_REPO`.
3. Ship secrets: `ssh … 'umask 077; mkdir -p ~/.config/fleet; cat > ~/.config/fleet/secrets.env.tmp && mv … secrets.env'`.
4. Ship files: `tar -C vault/files/<profile> -cf - . | ssh … '<PROVISION_FILES_SCRIPT>'`:
   `umask 077`, `mktemp -d ~/.config/fleet/stage.XXXXXX`, `tar -xf -` into it,
   `mkdir -p` + `mv -f` each file to its path under `$HOME` (same filesystem:
   an atomic rename), `rm -rf` the staging dir. With `--refresh-proxy-auth`
   also `touch ~/.cli-proxy-api/.force`.
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

## Node files

```
~/.local/share/fleet/            fleeter code (git checkout after the first pull, remote github-fleet-code)
~/.local/share/fleet-config/     config repo (git checkout after the first pull, remote github-fleet-config)
~/.local/bin/fleet               symlink to ~/.local/share/fleet/fleet
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
~/.config/fleet/memory.state     state=ok|conflict|missing, last_sync, detail
~/.config/fleet/fleet.conf       local overrides (optional)
~/.config/fleet/locks/apply      apply/pull lock; logs/<job>.log; daemon.pid, daemon.state
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

## `fleet status --json` (node) — consumed by `fleet nodes --live`

```json
{
  "fleet": "0.2.0", "name": "studio", "os": "macos", "container": false,
  "applied": "<digest>", "applied_at": "…",
  "code_commit": "<sha>", "config_commit": "<sha>", "applied_commit": "<sha>+<sha>",
  "tools": {"claude": {"state": "ok", "detail": "2.1.0 env-token"}, "codex": {"state": "login", "detail": "run: fleet login codex"}},
  "memory": {"state": "ok|conflict|missing", "last_sync": "…", "detail": "…"},
  "timers": {"pull": true, "memory": true, "update": true},
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

Inputs from `$FLEET_CONFIG_DIR`: `AGENTS.md`, `harness/<harness>/…`, `skills/<name>/`.
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
Jobs: `pull` (FLEET_PULL_EVERY), `memory` (FLEET_MEMORY_EVERY), `update`
(FLEET_UPDATE_EVERY). Master additionally: `reconcile` (FLEET_RECONCILE_EVERY).
