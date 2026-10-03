# fleeter

fleeter turns any Mac, Linux box or Docker container into a node of a personal
fleet of agent machines. One machine is the **master**: it keeps every secret in
a local vault, mints single-use join invites, pushes secrets and files over SSH
inside your tailnet, and can kick a node out. Everything else a node needs —
the harness CLIs (Claude Code, Codex, Cursor, Grok, …), your global agent
instructions, your skills, a shared Markdown memory vault — it installs and
keeps current on its own from git, so the master may be asleep most of the day.
It is a single bash script (bash 3.2 compatible) plus python3 stdlib; no agent,
no server, no database.

```
            you (laptop / phone)
                   │ tailscale
                   ▼
 ┌──────────── master ─────────────┐        GitHub (private repos, per-node deploy keys)
 │ fleet reconcile  (timer, 2 min) │        ┌─ fleeter       code       (RO, or public https)
 │ ~/.config/fleet/vault  0700     │        ├─ fleet-config  your layer (RO)
 │   secrets/ files/ nodes/ ssh/   │        └─ fleet-memory  shared vault (RW, nodes/<name>/ only)
 └──────────┬──────────────────────┘                 ▲  pull every 15 min / sync every 5 min
            │ OpenSSH, master → node only            │
   ┌────────┼─────────┬──────────────┐               │
   ▼        ▼         ▼              ▼               │
 mac node  linux node docker node  docker node ──────┘
 tag:fleet-node: may reach the internet, may NOT reach the master or each other
```

## The three repos

| Repo | Who writes it | What is in it | Nodes get it via |
|---|---|---|---|
| **fleeter** (this one, public or your fork) | upstream / you | `fleet`, `lib/`, tool plug-ins, Docker image, templates | shipped once by the master, then `fleet pull` (deploy key `~/.ssh/fleet_code`, skipped for https) |
| **fleet-config** (yours, private) | you, on the master | `fleet.conf`, `AGENTS.md`, `harness/` templates, `skills/` | shipped once, then `fleet pull` (RO deploy key `~/.ssh/fleet_config`) |
| **fleet-memory** (yours, private) | every node, own folder | Obsidian-compatible Markdown vault, `INDEX.md` | `fleet memory sync` (RW deploy key `~/.ssh/fleet_memory`) |

Secrets are in none of them. They live in the master's vault and travel to
nodes over SSH (`fleet secrets set`, `fleet files add`, `fleet proxy import`).
Start your config repo from `examples/fleet-config/` and your memory repo from
`templates/memory/`.

## Requirements

- Master: macOS or Linux, `bash`, `git`, `python3`, `ssh`, `curl`, `tar`; the
  Tailscale client installed and logged in to your tailnet (the master reads
  `tailscale status` locally); a Tailscale account you can mint one short-lived
  API access token in; GitHub access to the three repos (`gh auth login` in
  the browser, or a fine-grained token with *Administration: read/write* on
  them for deploy keys); Claude Code installed if you want `claude setup-token`
  to mint the shared token; Docker if you want container nodes.
- Node: macOS 13+ or a Debian/Ubuntu/Fedora/Arch Linux with `sudo` for the
  one-time `fleet join` (it installs Tailscale, enables an SSH server, installs
  base packages); or Docker for throwaway nodes.
- Your tailnet policy must isolate `tag:fleet-node`. `fleet init master` offers
  to apply `templates/tailscale-policy.hujson`; `fleet policy check` verifies it.

## Use cases

### Set up the master

Before the first command: install and log in the Tailscale client on this
machine (`tailscale status` must list your tailnet), log in `gh` or have a
GitHub token ready, install Claude Code if you plan to run `claude setup-token`,
and make sure `~/.local/bin` exists and is on your `PATH`:

```sh
mkdir -p ~/.local/bin
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc ;; esac   # or ~/.bashrc
```

Then:

```sh
git clone https://github.com/YOU/fleeter.git ~/fleeter && cd ~/fleeter
cp -R examples/fleet-config ~/fleet-config && (cd ~/fleet-config && git init -b main && git add -A && git commit -m "start fleet config")
$EDITOR ~/fleet-config/fleet.conf        # repo URLs (replace YOU), FLEET_TOOLS, FLEET_MISE_TOOLS, FLEET_PNPM
cp -R templates/memory ~/fleet-memory && (cd ~/fleet-memory && git init -b main && git add -A && git commit -m "start vault")
# create YOU/fleet-config and YOU/fleet-memory as private repos and push both (gh repo create … --private --source . --push)

./fleet init master --config-dir ~/fleet-config
#   asks for: a Tailscale API access token (opens the keys page; 1-day expiry is enough — it is
#   revoked at the end), the typed word `apply` to merge the fleet rules into your tailnet policy,
#   one `gh auth login --web` approval (or a GitHub token as fallback). Mints a scoped OAuth client
#   for later, generates the master SSH key and the digest key, installs the reconcile timer.
ln -s ~/fleeter/fleet ~/.local/bin/fleet
claude setup-token                                   # Claude Code must be installed; prints a 1-year token
fleet secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal
fleet config publish                                 # captures this machine's harness config + skills into fleet-config, pushes
fleet doctor
```

Optional tools are switched on per fleet in `fleet.conf` through `FLEET_TOOLS`
(install order; `lib/tools/<name>.sh` each). The default is `base devtools
claude`; add `codex`, `cursor`, `grok`, `chrome`, `cliproxy`, `t3code` as you
need them, e.g.

```sh
FLEET_TOOLS="base devtools chrome claude codex grok cliproxy"
```

`cliproxy` runs CLIProxyAPI on every `full` node (`FLEET_PROXY_MODE=local`,
needs Docker on the node and `fleet proxy import` on the master) or just points
the harnesses at one you run elsewhere (`FLEET_PROXY_MODE=remote` with
`FLEET_PROXY_URL`). Containers never run the proxy themselves: give them
`FLEET_PROXY_MODE=remote` and a reachable `FLEET_PROXY_URL`, or leave `cliproxy`
out of their `FLEET_TOOLS` (e.g. via `FLEET_LOCAL_CONF`) and they use Claude
Code's native auth through `CLAUDE_CODE_OAUTH_TOKEN`. Changes to `fleet.conf`
roll out with `fleet config publish`.

### Add a Mac

```sh
fleet invite --name studio            # prints a one-line command and an invite code (single use, 1 h)
```

On the Mac: paste the one-liner in a terminal, paste the code when asked (it is
read hidden, never from argv). `fleet join` installs Homebrew and Tailscale if
missing, enables Remote Login (key-only, verified with `sshd -T`), adds the
master's key, generates three deploy keys and writes `~/.config/fleet/enrol.json`.
Then it waits. Within two minutes the master's `reconcile` timer enrols the
node, registers its deploy keys, pushes code, config, secrets and files, and
runs `fleet apply` remotely. Check with `fleet nodes`. Rerunning the one-liner
is safe.

### Add a Linux box

Same as the Mac, with `--user` if the login name on the box differs from yours:

```sh
fleet invite --name buildbox --user ubuntu
```

`fleet join` uses `sudo` once for apt/dnf/apk/pacman packages, Tailscale,
`openssh-server`, docker-ce, the browser, and `loginctl enable-linger`. After
that nothing on the node runs as root; timers are systemd user units (or cron).

### Spin up throwaway Docker nodes

```sh
docker build -f docker/Dockerfile -t fleet-node:local .
docker/spawn.sh 3                                   # 3 ephemeral containers, minimal profile, one invite each
docker/spawn.sh 1 --profile full -- -e FLEET_TOOLS="base devtools claude"
fleet reconcile                                     # or wait for the timer
fleet kick fleet-dock-ab12cd && docker rm fleet-dock-ab12cd
```

The invite reaches the container as a bind-mounted 0600 file, never as an
environment variable. Ephemeral nodes vanish from the tailnet when the
container stops; a node absent for an hour has its deploy keys revoked by the
next reconcile. See `docker/README.md`.

### See what is running

```sh
fleet nodes                 # registry: name, id, online, state, profile, age
fleet nodes --live          # plus each node's tool states (claude:ok codex:login …), fetched over SSH
fleet status                # on a node: versions, logins, revs, memory state, timers, token ages
```

### Push new skills or instructions

Install the skill on the master as you normally would (`~/.claude/skills`,
`~/.agents/skills`, …), edit `AGENTS.md` in your config repo if needed, then:

```sh
fleet config publish        # harness_capture → secret scan → shows the staged diff → commit → push (asks once; --yes skips)
fleet config publish --no-capture   # commit + push hand-made edits; the secret scan still runs
```

`publish` commits in the config checkout (`FLEET_CONFIG_DIR`) and pushes to
**that checkout's `origin`**, not to `FLEET_CONFIG_REPO`; without an `origin` it
commits and tells you how to add one. The diff it shows is `git diff --cached`
(stat plus the first 200 lines; `FLEET_PUBLISH_DIFF_LINES` changes the cut).
Nodes pull the config repo every `FLEET_PULL_EVERY` (15) minutes and re-apply.
`fleet reconcile` or `fleet provision NODE` does it right away (provision runs
`fleet pull --no-apply` on the node before its `apply`). Plain `git commit &&
git push` in the config repo works too; `publish` only adds the capture and
the scan.

### Add or rotate a secret

```sh
fleet secrets set OPENAI_API_KEY                     # hidden prompt (or stdin); profile full by default
fleet secrets set CURSOR_API_KEY --profile minimal   # minimal = what throwaway containers also get
fleet secrets list                                   # names + profiles, never values
fleet reconcile                                      # the digest changed → every online node is re-provisioned
```

Secrets land in `~/.config/fleet/secrets.env` (0600) on nodes and are exported
by `~/.config/fleet/env.sh` into every shell and timer. Rotation = `secrets
set` again + `reconcile`. Nodes a secret was sent to are listed in the
registry (`secrets_sent`), so `fleet kick` can tell you what to rotate.

### Mirror a .env file

```sh
fleet files add ~/projects/app/.env                  # full profile; path must be under $HOME
fleet reconcile
```

The file is stored in the vault and recreated at the same path under the
node's `$HOME`, 0600, atomically: provision unpacks the set into a private
`~/.config/fleet/stage.XXXXXX` (0700) on the node and renames each file into
place, so a reader never sees a half-written file. Its content is part of the
digest.

### Share the CLIProxyAPI setup

```sh
fleet proxy import ~/cli-proxy-api                   # copies conf/config.yaml + auth/*.json into the vault (full profile)
fleet reconcile
fleet provision studio --refresh-proxy-auth          # later: overwrite a node's rotated OAuth files from the master
```

With `cliproxy` in `FLEET_TOOLS`, every `full`-profile node runs its own proxy
from `templates/cliproxy/` (`FLEET_PROXY_MODE=local`) and exports
`ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` for the harnesses (also via
`launchctl setenv` on macOS). The variables are exported **only** while the
proxy is enabled for that node: `cliproxy` in its tools and either a local
proxy with a readable client key, or `FLEET_PROXY_MODE=remote` (containers
always count as remote) with `FLEET_PROXY_URL` set. Otherwise `env.sh` unsets
them (and `launchctl unsetenv` on macOS), so Claude Code never points at a
proxy that is not there. Node-side auth files win on later provisions because a
running proxy refreshes them; `--refresh-proxy-auth` forces the master's copies.

### Log a node into Codex, Grok or Cursor

From the master, with its key, as the node's login user (`USER` = the `--user`
of the invite, default your own login; `<prefix>` = `FLEET_HOSTNAME_PREFIX`,
`fleet-` by default), interactive (`-t`):

```sh
ssh -t -i ~/.config/fleet/vault/ssh/fleet_master USER@<prefix><name> ~/.local/bin/fleet login codex   # one tool
ssh -t -i ~/.config/fleet/vault/ssh/fleet_master USER@<prefix><name> ~/.local/bin/fleet login         # every tool whose status is `login`
docker exec -it -u fleet fleet-dock-ab12cd fleet login grok                                           # container
```

Claude Code and Cursor are logged in through secrets (`CLAUDE_CODE_OAUTH_TOKEN`,
`CURSOR_API_KEY`); Codex and Grok through `OPENAI_API_KEY`/`XAI_API_KEY` or a
device code per node. GUI apps are opened for you but cannot be scripted.

### Kick a node

```sh
fleet kick studio                      # type the node name to confirm (or --yes)
```

Kick kills a running provision, marks the node revoked (nothing can
re-provision it), runs `fleet leave` on it (stops timers, harness processes,
the proxy; `tailscale logout`), deletes the device via the Tailscale API,
deletes its three deploy keys (each on the repository it was registered on,
even if `fleet.conf` points elsewhere by now), and prints the secrets it held.
Steps that fail stay in `pending_cleanup` and every reconcile retries them: the
device and key deletes until they succeed, the remote stop (`stop:<id>`) while
the node is still online on the tailnet — it is dropped once the device is
gone, because the master cannot reach the node any more.

**Master off?** Delete the device in the Tailscale admin console from your
phone. The node loses the tailnet immediately; the next time the master runs
`reconcile` it sees the device gone and, after the grace period (1 h ephemeral,
`FLEET_MISSING_GRACE_HOURS` otherwise), revokes the deploy keys and names the
secrets to rotate. Rotate them; fleeter does not wipe a node.

### Check isolation

```sh
fleet policy check          # live tailnet policy has the template's tagOwners/grants and no rule that lets a node reach the tailnet
fleet policy apply          # merge fleet rules into the live policy, diff, typed `apply`, backup, POST with If-Match (needs a one-off API token)
fleet doctor                # vault modes, OAuth token, policy, GitHub access, schedules, config dir, and an
                            # `nc -z` from every online node to the master (22, 443) and another node (22): any success fails
```

### Recover a memory conflict

`fleet status` on a node shows `memory: conflict` when a `pull --rebase` could
not be resolved (someone edited the node's own folder elsewhere). The node has
aborted the rebase, kept its local commit, and stopped syncing. Fix it **on the
affected node** (its clone holds the unpushed commit), reached from the master
as above; e.g. keep the remote version of the conflicting file:

```sh
ssh -t -i ~/.config/fleet/vault/ssh/fleet_master USER@<prefix><name>
cd ~/fleet-memory
git fetch origin && git rebase origin/main       # stops on the conflict
$EDITOR nodes/<name>/<file>.md                   # resolve by hand, or: git checkout --theirs -- nodes/<name>/<file>.md
git add nodes/<name>/<file>.md && GIT_EDITOR=true git rebase --continue
~/.local/bin/fleet memory sync --reset           # clears the conflict state and pushes
```

To discard the node's version instead: `cd ~/fleet-memory && git rebase --abort;
git reset --hard origin/main`, then `fleet memory sync --reset`. A node whose
`memory.state` says `missing` (the clone failed, e.g. the deploy key was not
registered yet) just needs `~/.local/bin/fleet apply` (or the next `fleet pull`)
to clone it.

## Command reference

Master commands need the vault (`fleet init master`); node commands run on a
node (the master runs them remotely during provision and kick).

| Command | Flags | What it does |
|---|---|---|
| `fleet init master` | `--config-dir DIR`, `--reconfigure` | Records the config dir in `~/.config/fleet/fleet.conf` (offers to clone `FLEET_CONFIG_REPO` into it when missing), creates the vault, master SSH key, digest key; Tailscale: bootstrap token → policy check/merge-apply → scoped OAuth client (token revoked; init stops if the policy step is skipped, because the client needs the fleet tag); GitHub: `gh auth login --web` or token; installs the reconcile timer. `--reconfigure` redoes the Tailscale/GitHub steps. Idempotent. |
| `fleet secrets set NAME` | `--profile minimal\|full` (default full) | Stores one secret from a hidden prompt or stdin into `vault/secrets/<profile>.env`. |
| `fleet secrets list` | | Names and profiles only. |
| `fleet files add PATH` | `--profile minimal\|full` | Mirrors a file under `$HOME` into the vault; recreated at the same relative path on nodes. |
| `fleet proxy import [DIR]` | | Copies CLIProxyAPI `conf/config.yaml` and `auth/*.json` from DIR (default `~/cli-proxy-api`) into the full profile. |
| `fleet invite` | `--ephemeral`, `--profile P`, `--name N`, `--user U`, `--code-only` | Mints a single-use, pre-authorized, tagged Tailscale key (1 h), records a pending invite (nonce), prints the join one-liner and the invite code. `--ephemeral` = ephemeral device + minimal profile. `--user` = login the master will SSH to. `--code-only` prints just the code. |
| `fleet nodes` | `--live` | Registry table; `--live` adds each node's tool states over SSH (10 s timeout each). Unregistered tagged peers show as `unknown`. |
| `fleet provision NODE` | `--refresh-proxy-auth` | Takes the node lock, ships code and config (when the node has no git checkout of them, or no repo URL is set), secrets, files (via a staging dir), runs `fleet pull --no-apply` on the node (brings its checkouts to `origin/main`), then `fleet apply --from-master <digest>`; records the `<code>+<config>` the node reports it applied and warns when that differs from this checkout (unpushed commits). NODE = registered name or Tailscale id, never a guessed hostname. |
| `fleet reconcile` | | Expires old invites, enrols new tagged peers (nonce check, claims the invite atomically, registers three deploy keys), provisions nodes whose digest differs, retries pending cleanups, tracks missing devices and revokes them after the grace period. Convergent; quiet when nothing to do. Runs every `FLEET_RECONCILE_EVERY` minutes. |
| `fleet kick NODE` | `--yes` | Revoke: see "Kick a node". |
| `fleet config publish` | `--yes`, `--no-capture` | `harness_capture` into the config dir (skipped with `--no-capture`), secret scan over `harness/` and `skills/` (always), staged diff (stat + content), confirm, commit (`publish fleet config`), push to the checkout's `origin`. Never touches the fleeter checkout. |
| `fleet policy check` | | Fetches the live policy with the OAuth client and checks it against the template. Exit 1 on findings. |
| `fleet policy apply` | | Merges the fleet rules into the **live** policy (adds the `tagOwners` entry and the template grants; turns `*`/`autogroup:tagged` sources into `autogroup:member`; keeps every other rule), shows a unified diff, requires the typed word `apply`, backs up the previous policy to `vault/policy-backups/`, POSTs with `If-Match`. Comments in the policy are not kept. Rules with IP/host/other-tag sources are reported, not rewritten. Asks for a one-off API access token (revoked afterwards). |
| `fleet doctor` | | See "Check isolation". Exit 1 on any problem. |
| `fleet join` | env `FLEET_INVITE_CODE` or `FLEET_INVITE_FILE` | Node bootstrap (also embedded in the invite one-liner). Interactive, uses sudo once. |
| `fleet apply` | `--from-master DIGEST` | Converges tools, instructions, harness templates, skills, `env.sh`, shell rc block, memory clone, timers. Records the digest and `applied_commit` only on success. Takes `~/.config/fleet/locks/apply`. |
| `fleet pull` | `--no-apply` | Fetches the code and config repos (converting the shipped tar copies into checkouts the first time, cloning a missing config dir, re-pointing `origin` when the configured URL changed), and runs `apply` when `<code>+<config>` differs from the last successful apply. `--no-apply` only updates the checkouts (used by provision). Timer: `FLEET_PULL_EVERY`. |
| `fleet update` | | Vendor updaters for every tool (`claude update`, `codex update`, `mise self-update`, brew/apt where allowed). Timer: `FLEET_UPDATE_EVERY`. |
| `fleet memory sync` | `--reset` | `git add nodes/<name>` → commit → `pull --rebase` → push, 3 bounded retries. Conflict → abort, state `conflict`, stop. `--reset` clears the state. Timer: `FLEET_MEMORY_EVERY`. |
| `fleet login [TOOL]` | | Interactive login for TOOL, or for every tool whose status is `login`; opens GUI apps on macOS. |
| `fleet status` | `--json` | Writes and prints `~/.config/fleet/status.json`. |
| `fleet leave` | | Stops the daemon/timers, harness processes and the proxy, `tailscale logout`. Files stay. |
| `fleet daemon` | | Foreground scheduler for containers (PID 1 safe): runs pull/memory/update on their intervals through `~/.local/bin/fleet` (the checkout `pull` keeps current), re-executes itself from that checkout after a code update (same PID), handles TERM with `leave`. |
| `fleet --version`, `fleet --help` | | |
| `docker/spawn.sh N` | `--image IMG`, `--profile P`, `--dry-run`, `-- DOCKER_ARGS` | On the master: N ephemeral containers, one invite each, invite via bind-mounted file. |

Environment knobs (all optional): `FLEET_HOME` (state dir, default
`~/.config/fleet`), `FLEET_CONFIG_DIR` (overrides the config dir recorded in
`~/.config/fleet/fleet.conf`; the environment wins),
`FLEET_VAULT`, `FLEET_SHARE` (node code dir), `FLEET_BIN` (`~/.local/bin`),
`FLEET_NODE_USER` (default login for invites), `FLEET_CODE_REMOTE` /
`FLEET_CONFIG_REMOTE` / `FLEET_MEMORY_REMOTE` (replace the derived
`github-fleet-*` URLs, e.g. for local bare repos), `FLEET_VERBOSE=1`,
`FLEET_NO_OPEN=1` (never open a browser), `FLEET_NO_SCHEDULER=1` (write but do
not load timers, on the master and on nodes), `FLEET_HEADLESS=0|1` (browser MCP
wrappers), `FLEET_HARNESS_NO_CLI=1` (skip `claude plugin` calls),
`FLEET_APPLY_LOCK_WAIT` (seconds, default 600), `FLEET_PUBLISH_DIFF_LINES`
(default 200).

## Configuration

Load order: `config/defaults.conf` (shipped, do not edit) → `~/.config/fleet/fleet.conf`
(per machine; may set `FLEET_CONFIG_DIR`) → `$FLEET_CONFIG_DIR/fleet.conf`
(your config repo) → `~/.config/fleet/fleet.conf` again, so a local override
always wins. Plain shell assignments.

| Key | Default | Meaning |
|---|---|---|
| `FLEET_CODE_REPO` | `""` | fleeter repo URL. SSH → nodes get a read-only deploy key; `https://` → public, no key; empty → nodes cannot pull code, provision re-ships it each time. |
| `FLEET_CONFIG_REPO` | `""` | Your config repo (SSH). Required by `init master`, enrolment, publish. |
| `FLEET_MEMORY_REPO` | `""` | Your memory repo (SSH). Required. |
| `FLEET_MEMORY_DIR` | `$HOME/fleet-memory` | Where nodes clone the memory vault. |
| `FLEET_NODE_TAG` | `tag:fleet-node` | Tailscale tag for nodes; must match the policy template. |
| `FLEET_HOSTNAME_PREFIX` | `fleet-` | Tailscale hostname = prefix + node name; travels in the invite code, so `fleet join` uses the master's value. |
| `FLEET_TOOLS` | `base devtools claude` | Plug-ins converged on every node, in order (`lib/tools/`). Full set: `base devtools chrome claude codex cursor grok cliproxy t3code`. |
| `FLEET_TOOLS_SKIP_IN_CONTAINER` | `t3code` | Plug-ins skipped inside containers. |
| `FLEET_MISE_TOOLS` | `node@lts` | Space-separated mise specs installed globally (`mise use -g`). |
| `FLEET_PNPM` | `""` | pnpm version activated through corepack; empty = skip. |
| `FLEET_NPM_GLOBALS` | `""` | npm packages installed with `npm -g` through mise's node. |
| `FLEET_DOCKER_LOGINS` | `""` | `host=USER_VAR:TOKEN_VAR` entries; the named variables come from secrets; `docker login --password-stdin`. |
| `FLEET_CHROME_DEVTOOLS_MCP` / `FLEET_PLAYWRIGHT_MCP` | `1.10.1` / `0.0.83` | Pinned versions of the two browser MCP servers. |
| `FLEET_PROXY_MODE` | `local` | `local`: every node runs CLIProxyAPI from `templates/cliproxy`; `remote`: only use `FLEET_PROXY_URL` (containers are always remote). Only matters with `cliproxy` in `FLEET_TOOLS`. |
| `FLEET_PROXY_URL` | `http://127.0.0.1:8317` | Exported as `ANTHROPIC_BASE_URL` while the proxy is enabled for the node (see "Share the CLIProxyAPI setup"). |
| `FLEET_PROXY_IMAGE` | `eceasy/cli-proxy-api:latest` | Image in the rendered compose file. |
| `FLEET_SKILL_EXCLUDE` | `""` | Skills on the master never captured. |
| `FLEET_CAPTURE_MACHINE_ONLY` | `""` | Extra words marking MCP servers/hooks as machine-only (dropped on capture). |
| `FLEET_CAPTURE_AGENT_EXCLUDE` | `""` | Claude agent files (basename without `.md`) not captured. |
| `FLEET_CAPTURE_AGENT_MARKERS` | `""` | `;`-separated text markers; an agent file containing one is not captured. |
| `FLEET_CAPTURE_RULE_DROP` | `""` | Extra words that drop a Codex `prefix_rule` on capture. |
| `FLEET_PULL_EVERY` / `FLEET_MEMORY_EVERY` / `FLEET_UPDATE_EVERY` / `FLEET_RECONCILE_EVERY` | `15` / `5` / `1440` / `2` | Timer intervals in minutes. |
| `FLEET_MISSING_GRACE_HOURS` | `24` | Hours a non-ephemeral node may be gone from the device list before its keys are revoked (ephemeral: 1 h fixed). |
| `FLEET_DEFAULT_PROFILE` / `FLEET_EPHEMERAL_PROFILE` | `full` / `minimal` | Secret profile for normal / `--ephemeral` invites. |

## Files on disk

Master, `~/.config/fleet/vault` (0700 dirs, 0600 files):

```
secrets/minimal.env, secrets/full.env   KEY='value' lines; full = minimal + full
files/<profile>/<path under $HOME>      mirrored files; files/full/.cli-proxy-api/{config.yaml,auth/}
ssh/fleet_master(.pub)                  the key nodes authorize
digest.key                              HMAC key for the desired-state digest; never shipped
tailscale.json                          OAuth client (auth_keys, devices:core, policy_file:read; tag-scoped)
github.json                             fallback token (only without gh)
nodes/<ts-id>.json                      registry; nodes/pending/, nodes/claimed/, rollback-* tombstones
locks/<ts-id>/{pid,token}, locks/.registry
audit.log                               one line per action
~/.config/fleet/fleet.conf              FLEET_CONFIG_DIR + local overrides; reconcile.log
```

Node:

```
~/.local/share/fleet/            fleeter code (tar copy, then a checkout of FLEET_CODE_REPO)
~/.local/share/fleet-config/     your config repo (tar copy, then a checkout)
~/.local/bin/fleet               symlink; ~/.local/bin/fleet-chrome-mcp, fleet-playwright-mcp wrappers
~/.config/fleet/enrol.json       nonce, name, user, os, arch (written by join, 0600)
~/.config/fleet/secrets.env      from the master (0600); env.sh sources it, exports PATH, FLEET_NODE, ANTHROPIC_* (proxy enabled only)
~/.config/fleet/applied, applied_at, applied_commit (<code>+<config>), status.json, memory.state
~/.config/fleet/manifest, harness.manifest, harness.claude-mcp   what fleet owns, for cleanup
~/.config/fleet/privileged_done  join finished the root steps; locks/apply; logs/<job>.log; daemon.pid
~/.config/fleet/stage.XXXXXX     transient: mirrored files are unpacked here and renamed into place
~/.ssh/fleet_code, fleet_config, fleet_memory (+ .pub); ~/.ssh/config block `# >>> fleet >>>`
~/fleet-memory/                  memory vault; ~/cli-proxy-api/ (cliproxy plug-in)
~/.zshrc / ~/.bashrc / ~/.profile   one marker block that sources env.sh
~/Library/LaunchAgents/dev.fleet.{pull,memory,update}.plist   or ~/.config/systemd/user/fleet-*.timer, or crontab lines
```

Harness files fleet writes (and the ownership rules) are listed in
`examples/fleet-config/harness/README.md`. Pre-existing files are copied to
`<file>.pre-fleet` once before the first overwrite.

## Troubleshooting

- **`fleet nodes` shows a peer as `unknown`** — tagged device the master has not
  enrolled: the nonce did not match a pending invite (expired? reused?), or SSH
  failed. Check `ssh -i ~/.config/fleet/vault/ssh/fleet_master <user>@<dnsname>`;
  mint a new invite and rerun the one-liner (`FLEET_VERBOSE=1 fleet reconcile`
  explains why a peer is skipped).
- **Node joined but nothing happens** — the master is off or its timer is not
  loaded: `fleet reconcile` by hand; `fleet doctor` checks the schedule.
- **`memory clone failed (deploy key not registered yet?)`** during the first
  apply, `memory: missing` in `fleet status` — normal if enrolment and provision
  raced; `~/.local/bin/fleet apply` on the node (or its next `fleet pull`)
  clones it. Persisting: `fleet doctor` on the master (GitHub access), and
  `ssh -T github-fleet-memory` on the node.
- **Repo moved** (new URL in `fleet.conf`) — publish the change; `fleet pull`
  and `fleet apply` re-point the `origin` of the code, config and memory
  checkouts. Deploy keys stay on the old repository: register the nodes anew
  (`fleet kick` + a fresh invite) when the key must move too.
- **`another fleet apply is running`** — a previous apply hung; find the pid in
  `~/.config/fleet/locks/apply/pid`, kill it or remove the directory.
- **Harness template renders nothing for a server** — a `${PLACEHOLDER}` has no
  value in `secrets.env`; `fleet secrets set NAME` on the master, reconcile. The
  placeholder list is `harness/SECRETS.md` in your config repo.
- **`fleet config publish` aborts with secret-scan hits** — a captured file
  contains a token or a home path. Add the offending skill to
  `FLEET_SKILL_EXCLUDE` or the server marker to `FLEET_CAPTURE_MACHINE_ONLY`;
  never commit the hit.
- **`fleet doctor`: ISOLATION FAIL** — a node reached the master. Your policy
  has a grant whose `src` covers tagged devices (`*`, `autogroup:tagged`, a
  CIDR, a host alias). `fleet policy check` names the rule; `fleet policy apply`
  merges the fleet rules into your policy (wildcard sources become
  `autogroup:member`; IP/host/tag sources it reports for you to fix by hand).
- **Docker node exits right away** — `docker logs <name>`: usually the invite
  file was already consumed or expired (one invite = one container), or the
  image lacks `tailscale` (`FLEET_FAKE_TAILSCALE` is for tests only).
- **Mac: `could not enable Remote Login automatically`** — newer macOS needs
  Full Disk Access for the terminal app, or enable Remote Login in System
  Settings → General → Sharing and rerun the one-liner.

## What fleeter does not do

- **No credential wiping.** A kicked or vanished node keeps every secret and
  file it had. Kick cuts access (tailnet, repos) and lists what to rotate; you
  rotate.
- **No GUI logins.** Claude desktop, ChatGPT desktop, Cursor IDE, the Chrome
  extension: fleeter opens them (macOS) and reports the manual step; no vendor
  offers a scriptable login.
- **No control panel in this version.** Use `fleet nodes --live`, `fleet kick`,
  and the Tailscale admin console from the phone.
- **No Windows.** macOS and Linux (incl. containers) only.
- **No protection from processes already running as your user on the master**;
  the vault is 0700 on a disk you should encrypt (see `docs/SECURITY.md`).
- **`launchctl setenv` argv note (macOS):** with a local CLIProxyAPI
  (`cliproxy` in `FLEET_TOOLS`, `FLEET_PROXY_MODE=local`), publishing
  `ANTHROPIC_AUTH_TOKEN` into the launchd session for GUI apps puts the token in
  one process's argv for milliseconds (local user only, never logged);
  `launchctl` has no stdin form. Without `cliproxy`, or with
  `FLEET_PROXY_MODE=remote`, no token is published (remote mode exports only
  the URL; put a token in a secret if the remote proxy needs one).

Further reading: `docs/ARCHITECTURE.md` (trust model, enrolment, reconcile,
shared memory), `docs/SECURITY.md` (threat model, limits, rotation),
`docs/CONTRACT.md` (registry schema, node files, plug-in interface),
`docker/README.md`, `examples/fleet-config/README.md`.

Tests: `bash tests/master_test.sh` (offline master logic, fake APIs),
`docker run --rm -v "$PWD:/src:ro" debian:bookworm-slim bash /src/tests/node_test.sh`
(node side in a container), `bash tests/e2e.sh` (master + two Docker nodes, no
real Tailscale or GitHub). Lint: `docker run --rm -v "$PWD:/mnt" -w /mnt
koalaman/shellcheck:stable -s bash -x fleet lib/*.sh lib/tools/*.sh docker/*.sh tests/*.sh`.
