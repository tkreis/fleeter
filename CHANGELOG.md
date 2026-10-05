# Changelog

## 0.6.1 — 2026-10-05

### Fixed

- `fleet ssh NODE aws …` (and timers, T3's `sh -l`) could not find Homebrew tools such as the AWS CLI on macOS nodes: the node's `env.sh` now puts `/opt/homebrew/bin`, `/usr/local/bin` and Docker Desktop's CLI dir on `PATH` when they exist.

## 0.6.0 — 2026-10-05

Your AWS SSO login, on every node: fleet pushes only the profiles you list in
`FLEET_AWS_PROFILES`; keep production out of that list.

### Added

- `fleet aws push [--profile P]... [--node NODE]...` (master; `lib/aws.sh`,
  `lib/aws_creds.py`): for every profile in `FLEET_AWS_PROFILES` (default
  empty = nothing is pushed; `--profile` narrows the list and a name outside
  it exits 2) whose IAM Identity Center session is logged in right now, runs
  `aws configure export-credentials --profile P --format process` on the
  master, keeps the result in memory and pipes one JSON bundle over ssh into
  `fleet aws receive` on every online provisioned node in parallel. Reports
  `mac2: 3 profiles (expire 18:42)`; an expired session is one line (`AWS
  SSO session expired for dev: run aws sso login (or fleet aws login)`);
  long-term keys are never forwarded. Audit and `vault/aws.json` hold profile
  names and expiry only; the SSO session token never leaves the master.
- `fleet aws login [--profile P]... [-- AWS_ARGS...]`: `aws sso login
  --profile P` on the master (first allowed profile by default; extra flags
  such as `--use-device-code` pass through), then the push.
- Node: `fleet aws receive` stores `~/.config/fleet/aws/<profile>.json`
  (0600, dir 0700, atomic) and keeps a `# >>> fleet aws >>>` block in
  `~/.aws/config` whose `[profile P]` sections use `credential_process =
  <absolute ~/.local/bin/fleet> aws creds P` plus the master profile's
  `region`/`output` (never `sso_*` keys). A profile the node defines itself is
  left alone; a profile that left the master's allowlist is dropped (file and
  block entry) at the next push. `fleet aws creds P` serves the stored JSON
  while its `Expiration` is more than two minutes away, else exits 1 with
  "on the master run: aws sso login". Only python3 is needed on the node.
- `fleet sync` step: with `FLEET_AWS_PROFILES` set and `aws` installed on the
  master, pushes again every `FLEET_AWS_REFRESH_MINUTES` (60), earlier when
  what it pushed expires within that window, when the allowlist changed or
  when a node was provisioned since; quiet on success, never logs in, one
  warning per hour per kind while the session is expired. `FLEET_AWS_SYNC=0`
  switches it off.
- `fleet status --json` field `aws` (`{"profiles": n, "expires": <earliest
  ISO>, "state": "ok|expired|none"}`, plus an `aws` line in the table);
  `fleet list` column AWS (`ok 3h`, `expired`, `-`) and json field `aws`.
- `fleet leave` (and so `fleet kick`'s remote stop) removes the credential
  files and the `~/.aws/config` block; a kicked node that was unreachable
  keeps credentials that expire on their own and gets no new ones.
- `devtools` installs the AWS CLI on the nodes with `FLEET_AWS_CLI=1`
  (default): `brew install awscli` on macOS, the official installer into
  `~/.local/aws-cli` + `~/.local/bin/aws` on Linux (no root); `aws update` on
  `fleet update`; `aws` in the devtools status.
- `fleet setup --aws-profiles "LIST"` and a question (only when
  `~/.aws/config` exists) that renders `FLEET_AWS_PROFILES`; SETUP.md and the
  `fleet` agent skill cover the flow (agents never print credentials).
- Config keys `FLEET_AWS_PROFILES`, `FLEET_AWS_SYNC`,
  `FLEET_AWS_REFRESH_MINUTES`, `FLEET_AWS_CLI`; environment `FLEET_AWS_BIN`
  (tests). Documented in README ("Use your AWS SSO login on every node"),
  docs/SECURITY.md and docs/CONTRACT.md ("fleet aws").
- Dispatcher: a `--` in a command's flag list ends argument checking (`fleet
  aws login -- --use-device-code`).

### Changed

- `fleet list` has a new AWS column between PROXY and FLEET; scripts that
  parse the table by position need to know.

## 0.5.1 — 2026-10-05

### Fixed

- `fleet list` showed a busy Mac node as `unreachable`: its `fleet status` takes about 10 s (one check per tool), exactly the old per-node cap. `FLEET_LIST_SECS` now defaults to 30.

## 0.5.0 — 2026-10-05

First-time setup is one command, or one sentence to your coding agent.

### Added

- `fleet setup` (master; `lib/setup.sh`): the guided setup. Asks for the
  GitHub owner, the config repo name and checkout, shared memory (with the
  privacy note), the tools preset (`minimal|agents|full` or a list), the
  proxy and keep-awake, each with a default in brackets and each also a flag
  (`--github-owner`, `--config-repo`, `--config-dir`, `--memory`/`--no-memory`,
  `--memory-repo`, `--tools`, `--proxy`/`--no-proxy`,
  `--keep-awake`/`--no-keep-awake`, `--claude-token`/`--no-claude-token`;
  `--yes` takes the defaults). Then, as `[n/9]` steps: preflight (the init
  master checks, plus `gh auth login --web` when needed), the owner from
  `gh api user`, the config repo (an existing `OWNER/NAME` is cloned,
  otherwise `examples/fleet-config` is copied, `fleet.conf` rendered from the
  answers, committed and created private with `gh repo create --source
  --push`), the memory repo (created private, empty), `fleet init master`
  (its own prompts: the Tailscale token, the typed `apply`), the Claude login
  (`claude setup-token | … | fleet secrets set CLAUDE_CODE_OAUTH_TOKEN
  --profile minimal`: the token stays in the pipe; then an optional loop of
  more secrets at hidden prompts), `fleet proxy import` when chosen, `fleet
  config publish --yes` and `fleet doctor`, and the next commands. Idempotent
  and resumable: finished steps print `skip`; on a rerun the recorded config
  repo supplies the defaults. Nothing is created on GitHub without a
  confirmation or `--yes`; refuses on a node.
- `SETUP.md` (also at https://tkreis.github.io/fleeter/SETUP.md): the same
  setup written for a coding agent — the rules (no secrets in the chat,
  confirm repo creation and the policy, hand interactive prompts to the
  user), the questions in order with defaults, the flags, what each step
  asks, verification, the first node, a troubleshooting table. Shipped as
  the `fleet-setup` agent skill too (`skills/fleet-setup`, same body).
- `install.sh`: ends with the `fleet setup` / SETUP.md hint;
  `FLEETER_SETUP=1 curl … | bash` runs `fleet setup` from the terminal
  (`/dev/tty`) right after installing, or prints the command when there is
  no terminal.

### Changed

- README: a short "Get started" with the two options at the top; the old
  Quickstart is now "Manual setup (what fleet setup does)". Site hero shows
  the install line, `fleet setup` and the agent sentence.
- `fleet config publish` no longer captures fleeter's bundled `fleet` skill
  into the config repo (a copy there replaced the shipped one on every node
  and went stale); `fleet sync` and `fleet skill list` already excluded it.

## 0.4.3 — 2026-10-05

Each node logs into its own CLIProxyAPI accounts; the master no longer copies
its OAuth files around.

### Fixed

- Copied proxy logins died as soon as any copy refreshed: Anthropic (and the
  other vendors) rotate refresh tokens, so the master's `claude-*.json` shipped
  to every full node logged the others out — the node's proxy logged
  `invalid_grant` / "Refresh token not found or invalid" and Claude Code there
  could not authenticate. Re-copying only moved the breakage. `fleet proxy
  import` now ships `config.yaml` only (client key, routing); the OAuth files
  are neither stored nor shipped unless `FLEET_PROXY_SHARE_AUTH=1` (new knob,
  default 0; documented as breaking when tokens rotate, only for a single node
  that never runs at the same time as the master). Files imported before stay
  in the vault but leave the digest and the provision tar while the knob is 0;
  `fleet provision NODE --refresh-proxy-auth` is refused without it.

### Added

- `fleet proxy login NODE [claude|codex|codex-device|antigravity] [--yes]`
  (master): the vendor's login container on the node (`FLEET_PROXY_IMAGE`,
  `-no-browser`) over `ssh -t -L <port>:127.0.0.1:<port>` with the pinned host
  key, so the OAuth URL it prints is opened in the browser on the master and
  the callback reaches the node through the tunnel (ports: claude 54545,
  codex 1455, antigravity 51121; codex-device needs no tunnel). Backs up the
  node's `auth/*.json` into `.auth-backup/<UTC>/` first, recreates the proxy
  container afterwards and checks `/v1/models` with the node's client key
  (read on the node, handed to curl on stdin, never printed). Refuses a busy
  callback port on the master, containers, and runs nothing without
  confirmation. Audited as `proxy.login <node> ok|fail <provider>`.
- `cliproxy` status reports `login` when the container logged a refresh
  failure (`invalid_grant`, "Refresh token not found or invalid") in the last
  24 h that is newer than the newest auth file, with the fix in the detail
  (`run on the master: fleet proxy login <name>`); `fleet list` shows
  `1 login: cliproxy` and PROXY `login`.

### Upgrade

- Nodes that received copied proxy logins from a master on 0.4.2 or earlier:
  run `fleet proxy login NODE` once per node (per account) on the master;
  the copied files are backed up on the node and replaced by the node's own
  login. Keep using the master's own proxy as before.

## 0.4.2 — 2026-10-05

### Fixed

- A node that cloned the memory repo while it was still empty never synced afterwards (`Updating an unborn branch with changes added to the index`). `fleet memory sync` now adopts the remote history first and commits the node's captures on top.

## 0.4.1 — 2026-10-05

### Fixed

- A node that went to sleep or offline in the middle of a provision left the master's ssh session hanging, holding the node lock and the sync lock, so every later sync and reconcile skipped. Master-side ssh now sends keepalives (`ServerAliveInterval` `FLEET_SSH_ALIVE_SECS`, default 15, ×4) and drops a dead connection after about a minute.

## 0.4.0 — 2026-10-04

Nodes come back on their own after a restart, a stuck FileVault Mac can be
unlocked from the master, and a MacBook can stay awake with the lid closed.

### Added
- `fleet reboot NODE [--yes]` (master): a planned restart with the typed
  node name as confirmation. macOS with FileVault on and `fdesetup
  supportsauthrestart` true: `sudo fdesetup authrestart -delayminutes 0` over
  an interactive fleet session — the user types the sudo password and the
  FileVault password at `fdesetup`'s own prompt on the node, so the Mac boots
  past the pre-boot prompt (`fdesetup(8)`); otherwise `sudo shutdown -r now`,
  Linux `sudo systemctl reboot`; containers refused. Records the node's LAN
  addresses first, then waits (`FLEET_REBOOT_WAIT_SECS`, 600) for tailnet
  online + `ssh NODE true` and prints `back online after Ns`, or names the
  next step (`fleet unlock NODE` for a FileVault Mac). Audited.
- `fleet unlock NODE [--host IP]` (master): answers the macOS 26 pre-boot
  password prompt of a FileVault Mac over the LAN
  (`apple_ssh_and_filevault(7)`: Remote Login's pre-boot sshd, password only,
  no Tailscale yet). Probes the registry's `lan_ips` (or `--host`) with
  `nc -z -w 3 IP 22`, opens `ssh -t -o PubkeyAuthentication=no -o
  PreferredAuthentications=keyboard-interactive,password` with the separate
  `vault/ssh/known_hosts_preboot` (TOFU; the pre-boot host key may differ),
  the user types the password at the Mac's prompt, then waits
  (`FLEET_UNLOCK_WAIT_SECS`, 300) for the node on the tailnet. Refuses with
  an explanation when no address answers (same LAN? Ethernet?), lists the
  requirements on a timeout; Linux nodes: nothing to unlock. No password is
  ever in argv, the environment or a file.
- Registry `lan_ips`, `ethernet`, `lan_seen`: provision reads them from the
  node's `status.json`, `fleet reboot` from a live status.
- `fleet status --json`: `lan_ips` (macOS `networksetup` + `ipconfig
  getifaddr`, Linux `/sys/class/net` + `ip`/`ifconfig`; no loopback,
  link-local or 100.64/10; `[]` in containers), `ethernet` yes|no,
  `awake_lid` on|off|n/a (`pmset -g` `SleepDisabled`), `lid_set_at_join`;
  the table shows `lan …` and `awake on  (lid: on, set at join; undo: sudo
  pmset -a disablesleep 0)`.
- `FLEET_KEEP_AWAKE_LID` (default 0; travels in the invite code as
  `keep_awake_lid`): `fleet join` on a laptop (`pmset -g batt` battery or a
  MacBook model) runs `sudo pmset -a disablesleep 1` after the `pmset -c`
  line and records `macos:pmset+lid` in `power_done`; a rerun on a MacBook
  that joined without it adds just the lid step. Desktops skipped, Linux
  never. Apply cannot sudo: it reports the undo (knob back to 0) or the manual
  command (knob 1, setting off). README covers heat, battery and models that
  ignore the setting.
- Docs: README "Restart a node", "Unlock a node after a power cut" (the
  requirements, LAN only, Ethernet, the password-only pre-boot surface),
  "Keep a MacBook awake with the lid closed"; SECURITY (no passwords through
  fleet, separate pre-boot pins, the pre-boot LAN surface); CONTRACT (registry
  and status fields, `power_done` content, the two commands); the `fleet`
  agent skill (reboot/unlock need the user at the keyboard; agents never
  handle the password).

## 0.3.3 — 2026-10-04

Nodes stay awake, so they stay reachable and keep syncing.

### Added
- `FLEET_KEEP_AWAKE` (default `1`; never the master, never containers).
  macOS nodes: `fleet apply` installs the LaunchAgent `dev.fleet.awake`
  (`/usr/bin/caffeinate -i -m -s`, `KeepAlive`, `RunAtLoad`; the display may
  still sleep), removed by `fleet leave` and by the next apply after
  `FLEET_KEEP_AWAKE=0`; `fleet join` additionally runs `sudo pmset -c sleep 0
  disksleep 0 womp 1 autorestart 1` (charger profile only, `displaysleep`
  untouched) so the node survives logout, reboots to the login window and
  power loss. Linux nodes: `fleet join` masks `sleep.target suspend.target
  hibernate.target hybrid-sleep.target` (systemd). Join records
  `~/.config/fleet/power_done`, skips when `FLEET_KEEP_AWAKE=0` (the fleet's
  value travels in the invite code as `keep_awake`; the environment of the
  one-liner wins) and only warns when sudo is refused.
- `fleet status` shows `awake on|off|n/a` (also in `--json`); `fleet list
  --json` carries `awake` per node. README "Keep nodes awake" covers the
  clamshell and FileVault caveats and how to undo the root settings.

## 0.3.2 — 2026-10-04

The shared memory vault fills itself: every machine uploads its agents' own
memories, the master takes part, and one file per project merges what every
machine learned.

### Added
- `fleet memory sync` takes a lock: the 5-minute timer and a manual run no longer capture into the same folders at once (one returns quietly).
- The memory vault's index workflow no longer fails before the first project view exists (`projects/` is added only when present).

- `fleet memory sync` mirrors this machine's native agent memories into the
  vault before committing (`lib/memory_capture.py`): Claude Code
  `~/.claude/projects/<slug>/memory/**/*.md` → `nodes/<name>/claude/<slug>/`,
  Codex `~/.codex/memories/**` text files → `nodes/<name>/codex/`, Grok
  `~/.grok/memory-v2/**/*.md` → `nodes/<name>/grok/` (sqlite/wal/shm skipped).
  Per source a mirror: deleted locally = deleted in the vault, inside
  `nodes/<name>/<source>/` only. Memory dirs shared through symlinks are
  captured once, under the first slug, the others listed in
  `nodes/<name>/claude/ALIASES.md`. Knobs: `FLEET_MEMORY_CAPTURE` (default
  `claude codex grok`; `""` = off), `FLEET_MEMORY_CAPTURE_EXCLUDE` (globs on
  the source-relative path; default drops Claude desktop scratch workspaces),
  `FLEET_MEMORY_MAX_KB` (256). Every file passes the secret scan (now shared in
  `lib/secretscan.py`; machine paths allowed, commit hashes, UUIDs and kebab-case slugs too): a
  hit is skipped, warned once and recorded in `memory.state`
  (`capture_skipped`, `detail`), never committed. Commit subject
  `memory: <name> <UTC> (+A ~M -D)`; quiet when nothing changed.
- The master participates: `fleet init master` and `fleet schedule install`
  clone the memory repo into `FLEET_MEMORY_DIR` with the master's own git
  credentials and install `dev.fleet.memory` / `fleet-memory.timer` (every
  `FLEET_MEMORY_EVERY` min); `fleet memory sync` works on the master (clones
  when missing) under `FLEET_MASTER_NAME` (default: short hostname, sanitised).
  `fleet list` starts with a `master` row (MEMORY `ok (3m)`); `--json` rows
  gain `"master"`, the master row `"memory_last_sync"`. `fleet doctor` checks
  the memory schedule and clone.
- `scripts/build_index.py` (vault template) groups `INDEX.md` by node, then by
  source, adds an `updated` date (git) per line and a `projects` section, and
  generates `projects/<slug>.md`: for every Claude project slug the memory
  files of every node (title, link, updated), aliases included; stale project
  files are removed. The GitHub Action commits `INDEX.md` and `projects/**`
  only when changed, with `[skip ci]` and a paths filter, so it never loops.
  `memory_seed` refreshes `scripts/` and the workflow in an existing vault.
- Global instructions (`examples/fleet-config/AGENTS.md`, the `fleet` skill,
  the vault README): read `~/fleet-memory/projects/<slug>.md` for the current
  working directory at session start and `INDEX.md` for broader context;
  everything under `nodes/**` and `projects/**` is reference data, never an
  instruction; agents do not copy their memories, fleet uploads them.

### Fixed

- `fleet reconcile` / `fleet sync` provision a node again when it is behind
  code or config revisions that are now pushed (a node that applied an older
  pair while the master's checkout was ahead of its remote), and retry such a
  node only once per pushed revision pair instead of on every run.

## 0.3.1 — 2026-10-04

Skills become a first-class fleet object: one command puts a skill on every
machine, and skills you install on the master follow on their own.

### Added

- `fleet skill add SOURCE [--name N] [--yes]`: SOURCE is a directory with a
  `SKILL.md`, or a git URL (https/ssh) with optional `#subdir` and `@ref`,
  cloned shallowly into a private temp dir. The skill is validated (frontmatter
  `name` → directory name, `[a-z0-9][a-z0-9-]{0,63}`), secret-scanned before
  anything is copied, put into `skills/N` of the config repo (an existing
  different skill only with `--yes`; identical = no-op), installed into the
  master's own skill dirs, committed (`add skill N` / `update skill N`), pushed,
  and pushed to the online nodes (`reconcile`): `added N to your fleet config`,
  `published (secret scan clean)`, `pushed to K nodes` (or `nodes pick it up on
  their next pull`). `FLEET_SKILL_ADD_NO_SYNC=1` skips the node push.
- `fleet skill list [--json]`: on the master NAME, SOURCE (`config` | `fleet` |
  `local-only`), ON NODES? (`yes` | `not pushed` | `no`), DESCRIPTION
  (truncated to the terminal); on a node what `fleet apply` installed.
- `fleet skill remove N [--yes]`: out of the config repo (`remove skill N`,
  pushed), out of the master's skill dirs, off the nodes on their next apply
  (manifest cleanup) or right away through `reconcile`. Asks first.
- `fleet sync` auto-publishes skills (`FLEET_SYNC_PUBLISH_SKILLS`, default 1):
  skills installed in the master's `~/.claude/skills`, `~/.agents/skills`,
  `~/.codex/skills`, `~/.cursor/skills` that the config repo lacks or has in
  another version are copied in, secret-scanned (a hit skips that skill with a
  warning), committed as `publish skills: a, b` and pushed, non-interactively.
  `FLEET_SKILL_EXCLUDE`, the bundled `fleet` skill and vendor caches are left
  alone; nothing is ever removed from the repo by sync; quiet when nothing
  changed.
- The `fleet` agent skill knows how to add, list and remove skills (remove
  needs the user's confirmation).

### Security

- **The vault is encrypted at rest.** Every secret-bearing file
  (`secrets/*.env`, mirrored files, the CLIProxyAPI logins, `tailscale.json`,
  `github.json`) is an [age](https://age-encryption.org) ciphertext (`*.age`)
  encrypted to `vault/recipient.txt`; the private key lives in the macOS login
  keychain (`fleet-vault`), in `secret-tool` on Linux, or in
  `~/.config/fleet/vault.key` (`FLEET_VAULT_KEY_BACKEND` = `keychain` |
  `secret-tool` | `file`). The key reaches `age` only on a pipe (`-i -`):
  never argv, never a file. `secrets set` decrypts into memory and
  re-encrypts; `files add` / `proxy import` encrypt straight from the source;
  provision decrypts into the ssh stream (the mirrored files as a tar built in
  memory); `lib/api.py` reads the credentials through the same helper. New
  commands: `fleet vault status`, `fleet vault encrypt` (migrates a plaintext
  vault in place, verified round-trip, idempotent), `fleet vault rotate-key`,
  `fleet vault export FILE` (decrypted tar inside an `age -p` archive).
  `fleet init master` installs `age` if missing and creates the key; `fleet
  doctor` warns about plaintext secrets or an unreachable key. A locked login
  keychain makes scheduled sync/reconcile skip provisioning with a warning and
  retry later. **Existing masters: run `fleet vault encrypt` once.**
- The desired-state digest is a sha256 over the ciphertexts (plus code and
  config revs) instead of an HMAC over the plaintext: `fleet list` and
  `reconcile` decide `behind` without the key, `digest.key` goes away with the
  migration. Updating re-provisions every node once; so does re-encrypting an
  unchanged value or rotating the key.

## 0.3.0 — 2026-10-04

The fleet becomes visible in one command, drivable by agents, and keeps itself
current from the master.

### Added

- One-line installer: `curl -fsSL https://tkreis.github.io/fleeter/install.sh | bash` (clones into `~/.local/share/fleeter`, links `fleet` and `fleeter`, no sudo, rerun to update).
- `fleet list [--json] [--offline]`: the one-shot overview. Registry + tailnet
  peers + each online node's `fleet status --json` (parallel, 10 s cap each,
  `FLEET_LIST_SECS`). Columns NAME, HOST, ONLINE, STATE, SYNCED (applied revs
  and digest against the master's), LAST PROVISION, TOOLS (`9 ok, 1 login:
  cursor`), MEMORY, PROXY, FLEET. Nodes that do not answer show `unreachable`,
  tagged peers never enrolled `unknown`; exit 0 regardless. `--json` is a
  stable array documented in `docs/CONTRACT.md`; `--offline` skips SSH.
  `fleet nodes [--live]` stays as the compact registry table.
- `fleeter` as a second name for the command: `fleet init master` and node
  `apply` write `~/.local/bin/fleeter` next to `~/.local/bin/fleet`.
- `skills/fleet/SKILL.md`: an Agent Skill that tells Claude Code, Codex and
  Cursor when and how to use `fleet` (read-only first, exact commands, what
  needs the user's confirmation, secrets never in argv or transcripts, shared
  memory rules, a troubleshooting table). Installed by `fleet init master` and
  the new `fleet skill install` into `~/.claude/skills`, `~/.agents/skills`,
  `~/.cursor/skills` (each only for a harness present here or in
  `FLEET_TOOLS`), and on nodes by `fleet apply` (a `skills/fleet/` in the config
  repo wins). Paths are recorded in the manifests for cleanup.
- `fleet sync`: the periodic master push, every `FLEET_SYNC_EVERY` (30) minutes
  from a new `dev.fleet.sync` LaunchAgent / `fleet-sync` systemd user timer.
  One run fast-forwards the master's fleeter and config checkouts from their
  upstream (only when clean and strictly behind; dirty, diverged, detached or
  offline checkouts are reported and left alone; a code update re-executes
  sync from the new code), runs `reconcile`, and every `FLEET_PUSH_TOOLS_EVERY`
  (1440) minutes runs `fleet update` on the online provisioned nodes (parallel,
  `FLEET_SYNC_UPDATE_SECS` cap, last run in `vault/sync.json`; `0` = off).
  Quiet when nothing happened; logs to `~/.config/fleet/sync.log`.
- `fleet schedule install`: (re)installs the reconcile and sync timers,
  idempotently (files rewritten and reloaded only when their content changed).
  `fleet doctor` checks both.
### Changed
- `fleet sync` and `fleet reconcile` share a master-wide lock
  (`vault/locks/.sync`); the one that finds it held skips with one line.
- The Docker node image carries `skills/`; `fleet doctor` points at
  `fleet schedule install` for a missing timer; the Linux `reconcile` unit logs
  to `~/.config/fleet/reconcile.log` like the macOS agent.
- README: "See the whole fleet", "Let agents drive fleet", "Automatic updates";
  command and config references, files on disk and uninstall updated.

## 0.2.0 — 2026-10-03

The first release meant for other people. Everything author-specific is now
opt-in or configurable, the docs start from zero, and the CLI cannot run a
command by accident.

### Changed / fixed
- `fleet COMMAND --help` (and `-h`) prints that command's synopsis and runs
  nothing, for every command and subcommand; unknown flags, extra arguments and
  unknown subcommands exit 2 before anything executes. Handled once, in the
  dispatcher.
- `fleet init master` runs a preflight before it writes a single file: the
  commands it needs, a logged-in Tailscale client, a git identity, and how
  GitHub will be reached; each failure names the next step.
- The memory repo is optional: with `FLEET_MEMORY_REPO=""` there is no memory
  deploy key, clone, timer or seed, and `fleet status` reports `memory off`.
- T3 Code remote access is opt-in: `FLEET_T3_REMOTE=1` (default 0) or
  `fleet t3 setup`. Without it no node gets the extra `authorized_keys` line and
  `~/.ssh/config` is never touched; with it, the `Include` is written only once
  there is a node to list.
- CLIProxyAPI knobs: `FLEET_PROXY_TZ` (default UTC, was hardwired to one
  timezone), `FLEET_PROXY_CONTAINER`, `FLEET_PROXY_PORT`, `FLEET_CLIPROXY_DIR`
  (also the default for `fleet proxy import`).
- The invite code carries `FLEET_TOOLS`; `fleet join` skips the browser install
  without `chrome` and docker-ce without `devtools`/`cliproxy`. The Docker
  image takes `--build-arg FLEET_BROWSER=0` for a build without chromium.
- `nc` (netcat-openbsd / nmap-ncat / openbsd-netcat) is part of the base
  packages and the node image: `fleet doctor` probes isolation with it.
- `fleet config publish` checks the git identity first and says that capture is
  authoritative (skills not installed on the master, such as the starter
  `fleet-notes`, are removed from the repo).
- Example `fleet.conf` aligned with `config/defaults.conf`; documented tool
  presets `minimal` (default), `agents`, `full`.
- `fleet policy` help wording: the fleet rules are merged into the live policy,
  not replacing it.
- Tests pass on a clean Debian without `init.defaultBranch` and without a git
  identity (`git -c init.defaultBranch=main init`, `GIT_CONFIG_GLOBAL`).
- README rewritten for a first-time reader: pitch, "Is this for you?",
  Quickstart to a provisioned Docker node, offline try-out, tool table, command
  and config references, files on disk, uninstall, FAQ. CHANGELOG,
  CONTRIBUTING, CI workflow and a bug-report template added.

### Since 0.1.0 (same day, before this release was cut)
- `fleet policy apply` merges the fleet rules into the live tailnet policy
  instead of replacing it (your other rules stay; wildcard sources become
  `autogroup:member`).
- `fleet login` shows progress and caps each tool check; `fleet nodes` shows
  `provisioning` while a provision runs.
- User tool dirs and the Docker Desktop CLI are put on PATH; Docker Desktop is
  started when needed.
- `fleet ssh NODE [COMMAND]`; the master seeds a missing memory-vault
  scaffold; Cursor's locked-keychain state is explained.
- T3 Code remote access (`fleet t3 setup|status|revoke`) with a restricted
  client key and pinned node host keys.
- The fleet environment is loaded in login and non-interactive shells too
  (`~/.zshenv`, `~/.profile`, `~/.bash_profile`).
- MIT license.

## 0.1.0 — 2026-10-03

Initial version: `fleet` (bash 3.2 + python3 stdlib) with master side (vault,
invites, enrolment by nonce, provision over OpenSSH, reconcile timer, kick,
tailnet policy check/apply, doctor), node side (join, apply, pull, update,
memory sync, login, status, leave, daemon), tool plug-ins (base, devtools,
chrome, claude, codex, cursor, grok, cliproxy, t3code), harness capture and
render for Claude Code, Codex, Cursor, Grok and T3 Code, the shared memory
vault template, the Docker node image with `spawn.sh`, and the offline test
suites (`tests/master_test.sh`, `tests/node_test.sh`, `tests/e2e.sh`).
