# Changelog

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
