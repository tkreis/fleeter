# fleeter

Overview site: <https://tkreis.github.io/fleeter/>

fleeter turns your Macs, Linux boxes and throwaway Docker containers into a
small, private fleet of machines that run coding agents (Claude Code, Codex,
Cursor, Grok) with the same instructions, skills, tools and secrets as your own
workstation. One machine is the **master**: it keeps the secrets in a local
vault, mints single-use join invites, pushes secrets and files over SSH inside
your tailnet, and can kick a node out. Everything else a node needs it installs
and keeps current on its own from git, so the master may be asleep most of the
day. It is bash (3.2-compatible) plus python3 stdlib: no agent, no server, no
database.

```
            you (laptop / phone)
                   │ tailscale
                   ▼
 ┌──────────── master ─────────────┐        GitHub (private repos, per-node deploy keys)
 │ fleet reconcile  (timer, 2 min) │        ┌─ fleeter       code       (RO, or public https)
 │ ~/.config/fleet/vault  0700     │        ├─ fleet-config  your layer (RO)
 │   secrets/ files/ nodes/ ssh/   │        └─ fleet-memory  shared vault (RW, nodes/<name>/ only; optional)
 └──────────┬──────────────────────┘                 ▲  pull every 15 min / sync every 5 min
            │ OpenSSH, master → node only            │
   ┌────────┼─────────┬──────────────┐               │
   ▼        ▼         ▼              ▼               │
 mac node  linux node docker node  docker node ──────┘
 tag:fleet-node: may reach the internet, may NOT reach the master or each other
```

## Is this for you?

fleeter is built for exactly one situation:

- **One operator.** You, your accounts, your machines. There is no multi-user
  model, no RBAC, no shared master.
- **Tailscale.** Master and nodes are on your tailnet; fleeter manages the
  policy rules that isolate the nodes and uses the Tailscale API to mint join
  keys and delete devices. No other VPN or plain-internet mode.
- **macOS, Linux, Docker.** Nodes are Macs (13+), Debian/Ubuntu/Fedora/Arch
  boxes, or containers from the shipped image. The master is a Mac or a Linux
  machine. No Windows.
- **GitHub for the config repo** (and the optional memory repo). Nodes pull
  them with per-node deploy keys that the master registers through the GitHub
  API; see the FAQ for GitLab/Gitea.
- **Agents that take their login from the environment.** Claude Code via
  `CLAUDE_CODE_OAUTH_TOKEN`, Cursor via `CURSOR_API_KEY`, Codex/Grok via API
  keys or a device-code login per node. GUI app logins are not scripted.

If that matches, the Quickstart below gets you from nothing to one master and
one Docker node that runs Claude Code in about twenty minutes. If you only want
to see it move, "Try it without Tailscale or GitHub" needs Docker and nothing else.

## Quickstart

What you need on the master before you start: the Tailscale client logged in
to your tailnet, `git` with `user.name`/`user.email` set, the GitHub CLI
(`gh auth login`) or a fine-grained token with *Administration: read/write* on
your repos, Claude Code installed (for `claude setup-token`), Docker (for the
container node). `fleet init master` checks the first three before it writes
anything and tells you what is missing.

```sh
# 1. the code (fork first if you want nodes to pull your own copy; the URL goes into fleet.conf)
git clone https://github.com/tkreis/fleeter.git ~/fleeter
mkdir -p ~/.local/bin && ln -s ~/fleeter/fleet ~/.local/bin/fleet
export PATH="$HOME/.local/bin:$PATH"          # for this shell; put the same line in ~/.zshrc or ~/.bashrc

# 2. your private config repo, started from the example
cp -R ~/fleeter/examples/fleet-config ~/fleet-config && cd ~/fleet-config
$EDITOR fleet.conf          # replace YOU in the repo URLs; FLEET_MEMORY_REPO="" skips shared memory for now
git -c init.defaultBranch=main init && git add -A && git commit -m "start fleet config"
gh repo create YOU/fleet-config --private --source . --push

# 3. the master
fleet init master --config-dir ~/fleet-config
#   checks Tailscale login, git identity, GitHub access; then asks for one short-lived
#   Tailscale API access token (opens the keys page; revoked at the end), the typed word
#   `apply` to merge the fleet rules into your tailnet policy, and one `gh auth login --web`
#   approval if gh is not logged in. Installs the reconcile timer (every 2 min).
claude setup-token                                      # prints a 1-year token
fleet secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal
fleet config publish --no-capture                       # push the example config as it is (see "Push new skills")
fleet doctor

# 4. one Docker node
cd ~/fleeter && docker build -f docker/Dockerfile -t fleet-node:local .
docker/spawn.sh 1                                       # mints an invite, starts fleet-dock-<rand>
fleet reconcile                                         # or wait for the timer; first provision takes a few minutes
fleet nodes                                             # STATE provisioned when done

# 5. the first agent command on the node
fleet ssh fleet-dock-ab12cd claude -p 'say hello and tell me which machine you are on'
fleet ssh fleet-dock-ab12cd                             # or a shell, with the node's fleet environment loaded
```

A Mac or Linux box joins the same way with `fleet invite --name studio` and the
one-liner it prints (see "Use cases"). `fleet kick fleet-dock-ab12cd` revokes
the node again.

## Try it without Tailscale or GitHub

The whole master-to-node flow runs offline against fakes, which is also how the
test suite works. You need Docker and python3 on the host, nothing else; nothing
is written outside the repo (`tests/.e2e-work`) and no Docker object outside the
`fleet-e2e-*` names is touched.

```sh
bash tests/e2e.sh              # builds the node image, runs one master + two Docker nodes through
                               # init, invite, join, enrol, provision, memory sync, kick, pull, stop;
                               # PASS/FAIL per step, exit 0 when all pass (about 2 min after the first build)
E2E_KEEP=1 bash tests/e2e.sh   # keep the containers, network and volume afterwards
```

With `E2E_KEEP=1` the master container stays up for a look around (the nodes
have left by then: the last steps kick one and stop the other, so their side is
in `docker logs fleet-e2e-node-a` / `-b`):

```sh
docker exec -it -u fleet -e HOME=/home/fleet -e FLEET_TS_API=http://127.0.0.1:8899 -e FLEET_GH_API=http://127.0.0.1:8899 \
  -e FLEET_TS_STATUS_JSON=/home/fleet/ts-status.json fleet-e2e-master bash
fleet nodes; fleet doctor; cat ~/.config/fleet/vault/audit.log; cat ~/api.log     # every fake API call
# clean up
docker rm -f fleet-e2e-master fleet-e2e-node-a fleet-e2e-node-b; docker network rm fleet-e2e-net; docker volume rm fleet-e2e-repos
```

How the fakes plug in (all plain environment variables, usable outside the
tests too): `FLEET_TS_API` and `FLEET_GH_API` point `lib/api.py` at
`tests/e2e/fake_api.py` instead of api.tailscale.com / api.github.com;
`FLEET_TS_STATUS_JSON` replaces `tailscale status --json` with a file;
`FLEET_FAKE_TAILSCALE=1` makes the container entrypoint skip `tailscaled` so
`tests/e2e/fake-tailscale.sh` on PATH answers; `FLEET_MEMORY_SEED=0` stops the
master from cloning a memory repo; `FLEET_CODE_REMOTE` / `FLEET_CONFIG_REMOTE` /
`FLEET_MEMORY_REMOTE` replace the GitHub URLs with local bare repos. Without
Docker, `bash tests/master_test.sh` exercises the master logic alone with a fake
`ssh` and the same fake API.

## Choosing tools

`FLEET_TOOLS` in your `fleet.conf` lists the plug-ins (`lib/tools/<name>.sh`)
every node converges, in install order. Three presets, documented in
`examples/fleet-config/fleet.conf`:

| Preset | `FLEET_TOOLS` |
|---|---|
| minimal (default) | `base devtools claude` |
| agents | `base devtools claude codex cursor chrome` |
| full | `base devtools claude codex cursor chrome grok cliproxy t3code` |

| Plug-in | What it installs | Secret / login it needs | Where |
|---|---|---|---|
| `base` | git, git-lfs, curl, jq, ripgrep, tmux, python3, unzip, nc (`fleet doctor` probes with it), ca-certificates | none | macOS (Homebrew), Linux (apt/dnf/apk/pacman, installed by `fleet join` with sudo), containers (in the image) |
| `devtools` | mise runtimes (`FLEET_MISE_TOOLS`), pnpm via corepack (`FLEET_PNPM`), npm globals (`FLEET_NPM_GLOBALS`), uv, gh, glab, Docker (docker-ce via `fleet join` on Linux; Docker Desktop or colima on macOS), registry logins (`FLEET_DOCKER_LOGINS`) | none; registry logins read the named secrets | macOS, Linux, containers (Docker skipped) |
| `claude` | Claude Code (claude.ai installer), `claude update` | `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token` on the master) or `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN`; else `fleet login claude` | all |
| `codex` | Codex CLI, `codex update` | `OPENAI_API_KEY` (logs in non-interactively) or a device code: `fleet login codex` | all |
| `cursor` | Cursor CLI (`cursor-agent`) | `CURSOR_API_KEY` or a browser login: `fleet login cursor`; the macOS keychain is locked over ssh, so use the secret there | all |
| `grok` | Grok Build (`grok`) | `XAI_API_KEY` or a device code: `fleet login grok` | all |
| `chrome` | a browser (Google Chrome on macOS and Debian/Ubuntu amd64, chromium on arm64 and in containers) plus `chrome-devtools-mcp` and `@playwright/mcp` pinned (`FLEET_CHROME_DEVTOOLS_MCP`, `FLEET_PLAYWRIGHT_MCP`) behind `~/.local/bin/fleet-chrome-mcp` / `fleet-playwright-mcp` wrappers (headless without a display, fleet-owned profile) | none | macOS, apt-based Linux (browser via `fleet join`), containers (chromium baked into the image; `--build-arg FLEET_BROWSER=0` for a slim image without it) |
| `cliproxy` | CLIProxyAPI in Docker from `templates/cliproxy/` (`FLEET_PROXY_MODE=local`) or just the harness variables for one you run elsewhere (`remote`) | `fleet proxy import` on the master (config.yaml + OAuth files, full profile) | macOS and Linux with Docker; containers always remote |
| `t3code` | the T3 Code desktop app from GitHub releases (self-updating) | none | macOS, Linux with a display; skipped in containers. Remote use of a node from the master's T3 Code is `fleet t3 …` (opt-in, `FLEET_T3_REMOTE`), independent of this plug-in |

`fleet join` reads the fleet's tool list from the invite and skips the
privileged installs the fleet does not use (no browser without `chrome`, no
docker-ce without `devtools` or `cliproxy`). Tools that need a GUI or nested
Docker go into `FLEET_TOOLS_SKIP_IN_CONTAINER` (default `t3code`). Changes to
`fleet.conf` roll out with `fleet config publish`.

## The three repos

| Repo | Who writes it | What is in it | Nodes get it via |
|---|---|---|---|
| **fleeter** (this one, or your fork) | upstream / you | `fleet`, `lib/`, tool plug-ins, Docker image, templates | shipped once by the master, then `fleet pull` (deploy key `~/.ssh/fleet_code`, skipped for https) |
| **fleet-config** (yours, private) | you, on the master | `fleet.conf`, `AGENTS.md`, `harness/` templates, `skills/` | shipped once, then `fleet pull` (RO deploy key `~/.ssh/fleet_config`) |
| **fleet-memory** (yours, private, optional) | every node, own folder | Obsidian-compatible Markdown vault, `INDEX.md` | `fleet memory sync` (RW deploy key `~/.ssh/fleet_memory`) |

Secrets are in none of them. They live in the master's vault and travel to
nodes over SSH (`fleet secrets set`, `fleet files add`, `fleet proxy import`).
Start your config repo from `examples/fleet-config/` and your memory repo, if
you want one, from `templates/memory/` (the master seeds a missing scaffold
itself). With `FLEET_MEMORY_REPO=""` nothing memory-related exists: no deploy
key, no clone, no timer, `fleet status` says `memory off`.

## Use cases

### Set up the master

The Quickstart covers it. Details worth knowing: `fleet init master` is
idempotent and `--reconfigure` redoes the Tailscale and GitHub steps; the config
dir is recorded in `~/.config/fleet/fleet.conf` and a missing one is cloned from
`FLEET_CONFIG_REPO` after a confirmation; the policy step merges the fleet rules
into your **live** tailnet policy (your other rules stay) and backs the previous
policy up into the vault.

### Add a Mac

```sh
fleet invite --name studio            # prints a one-line command and an invite code (single use, 1 h)
```

On the Mac: paste the one-liner in a terminal, paste the code when asked (it is
read hidden, never from argv). `fleet join` installs Homebrew and Tailscale if
missing, enables Remote Login (key-only, verified with `sshd -T`), adds the
master's key, generates the deploy keys and writes `~/.config/fleet/enrol.json`.
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
`openssh-server`, docker-ce and the browser (both only when the fleet's tools
need them), and `loginctl enable-linger`. After that nothing on the node runs
as root; timers are systemd user units (or cron).

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
fleet ssh studio fleet status   # on a node: versions, logins, revs, memory state, timers, token ages
```

### Run something on a node

```sh
fleet ssh studio                         # interactive shell as the node's login, fleet environment loaded
fleet ssh studio claude -p 'summarise ~/projects/app/README.md'
fleet ssh studio fleet login codex       # device-code login for one tool (see below)
```

`fleet ssh` resolves the name through the registry (user, DNS name, pinned host
key, master key); the remote command runs after `~/.config/fleet/env.sh` is
sourced, so PATH, secrets and proxy variables are what the agents see.

### Push new skills or instructions

Install the skill on the master as you normally would (`~/.claude/skills`,
`~/.agents/skills`, …), edit `AGENTS.md` in your config repo if needed, then:

```sh
fleet config publish        # harness_capture → secret scan → shows the staged diff → commit → push (asks once; --yes skips)
fleet config publish --no-capture   # commit + push hand-made edits; the secret scan still runs
```

**Capture is authoritative:** `harness/` and `skills/` in the config repo are
rewritten from this machine's live configuration. A skill that is not installed
on the master is removed from the repo, the starter `skills/fleet-notes`
included, so install it on the master if you want to keep it (or publish with
`--no-capture`). `publish` checks for a git identity first, commits in the
config checkout (`FLEET_CONFIG_DIR`) and pushes to **that checkout's `origin`**;
the diff it shows is `git diff --cached` (stat plus the first 200 lines,
`FLEET_PUBLISH_DIFF_LINES`). Nodes pull the config repo every
`FLEET_PULL_EVERY` (15) minutes and re-apply; `fleet reconcile` or
`fleet provision NODE` does it right away.

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
node's `$HOME`, 0600, atomically (unpacked into a private staging dir on the
node and renamed into place). Its content is part of the digest.

### Share the CLIProxyAPI setup

```sh
fleet proxy import                                   # copies conf/config.yaml + auth/*.json from $FLEET_CLIPROXY_DIR into the vault (full profile)
fleet reconcile
fleet provision studio --refresh-proxy-auth          # later: overwrite a node's rotated OAuth files from the master
```

With `cliproxy` in `FLEET_TOOLS`, every `full`-profile node runs its own proxy
from `templates/cliproxy/` (`FLEET_PROXY_MODE=local`; image, timezone,
container name, port and directory come from `FLEET_PROXY_IMAGE`,
`FLEET_PROXY_TZ`, `FLEET_PROXY_CONTAINER`, `FLEET_PROXY_PORT`,
`FLEET_CLIPROXY_DIR`) and exports `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`
for the harnesses (also via `launchctl setenv` on macOS). The variables are
exported **only** while the proxy is enabled for that node; otherwise `env.sh`
unsets them. Containers never run the proxy themselves: give them
`FLEET_PROXY_MODE=remote` and a reachable `FLEET_PROXY_URL`, or leave
`cliproxy` out of their tools. Node-side auth files win on later provisions
because a running proxy refreshes them; `--refresh-proxy-auth` forces the
master's copies.

### Log a node into Codex, Grok or Cursor

```sh
fleet ssh studio fleet login codex        # one tool
fleet ssh studio fleet login              # every tool whose status is `login`
docker exec -it -u fleet fleet-dock-ab12cd fleet login grok   # container
```

Claude Code and Cursor are logged in through secrets (`CLAUDE_CODE_OAUTH_TOKEN`,
`CURSOR_API_KEY`); Codex and Grok through `OPENAI_API_KEY`/`XAI_API_KEY` or a
device code per node. GUI apps are opened for you but cannot be scripted.

### Use a node from T3 Code on the master (opt-in)

T3 Code's desktop app has an **SSH environment** type: you give it an ssh host
alias once; it then runs `ssh <alias>` itself to find or start the T3 server on
that machine, pairs with a one-time token it creates over the same connection,
and tunnels the server to a local port. fleet prepares exactly what that flow
needs, with a key that can do nothing else. Off by default: nothing happens
until you run `fleet t3 setup`, or set `FLEET_T3_REMOTE=1` so `fleet init
master` prepares the key for every node from the start.

```sh
fleet t3 setup studio        # once per node (or `fleet t3 setup` for all); prints the alias and copies it (macOS)
# then in T3 Code on the master: Settings -> Connections -> Add environment -> SSH -> host: fleet-studio
fleet t3 status studio       # the alias as ssh resolves it, pinned host key, a BatchMode probe with the
                             # restricted key running T3's discovery, the node's T3 sessions (no tokens)
fleet t3 revoke studio       # revoke the node's pairing-token sessions and pairing tokens, stop the servers
                             # T3 started over ssh, drop the key from the node and the block from ~/.ssh/config.d/fleet
```

What `setup` does: generates `vault/ssh/t3_client` (ed25519; never the fleet
master key), reads the node's host key over the already-authenticated fleet
session and pins it in `vault/ssh/known_hosts`, authorises the key on the node
as `restrict,port-forwarding,permitopen="127.0.0.1:*",from="<tailnet ranges>"`
(no pty, no agent or X11 forwarding, forwards only to the node's loopback, only
from the tailnet; comment `fleet-t3-client`), and writes one `Host fleet-<name>`
block per node into `~/.ssh/config.d/fleet`, included from the first line of
`~/.ssh/config` (your original is kept as `config.pre-fleet`). That include is
written only once there is at least one node to list; a fleet without nodes
never touches `~/.ssh`. Provision and reconcile keep the key line and the
include file in step with the registry; `fleet kick` runs the revoke part.
Adding the environment in the app stays a click: its connection catalogue is
encrypted (Electron safeStorage) and has no CLI or deep link.

On the node nothing is pre-installed for this: T3 downloads its own `t3` CLI
archive into `~/.t3/runtime/versions/<app version>/` on first connect (needs
`curl` or `wget` and `tar`; darwin-arm64, linux-arm64 and linux-x64 only, so an
Intel Mac cannot be a T3 node) and reuses the node's running desktop-app server
when `~/.t3/userdata/server-runtime.json` points at one, else starts
`t3 serve --host 127.0.0.1` itself. `fleet t3 status` shows all of that.

### Kick a node

```sh
fleet kick studio                      # type the node name to confirm (or --yes)
```

Kick kills a running provision, marks the node revoked (nothing can
re-provision it), revokes its T3 access if any, runs `fleet leave` on it (stops
timers, harness processes, the proxy; `tailscale logout`), deletes the device
via the Tailscale API, deletes its deploy keys (each on the repository it was
registered on, even if `fleet.conf` points elsewhere by now), and prints the
secrets it held. Steps that fail stay in `pending_cleanup` and every reconcile
retries them: the device and key deletes until they succeed, the remote stop
(`stop:<id>`) and the T3 revoke (`t3:<id>`) while the node is still online on
the tailnet.

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
affected node** (its clone holds the unpushed commit), e.g. keep the remote
version of the conflicting file:

```sh
fleet ssh studio
cd ~/fleet-memory
git fetch origin && git rebase origin/main       # stops on the conflict
$EDITOR nodes/<name>/<file>.md                   # resolve by hand, or: git checkout --theirs -- nodes/<name>/<file>.md
git add nodes/<name>/<file>.md && GIT_EDITOR=true git rebase --continue
fleet memory sync --reset                        # clears the conflict state and pushes
```

To discard the node's version instead: `git rebase --abort; git reset --hard
origin/main`, then `fleet memory sync --reset`. A node whose `memory.state` says
`missing` (the clone failed, e.g. the deploy key was not registered yet) just
needs `fleet apply` (or the next `fleet pull`) to clone it.

## Command reference

Every command accepts `-h`/`--help`, prints its synopsis and does nothing else
(exit 0); an unknown flag, an extra argument or an unknown subcommand exits 2
before anything runs. Master commands need the vault (`fleet init master`);
node commands run on a node (the master runs them remotely during provision
and kick).

| Command | Flags | What it does |
|---|---|---|
| `fleet init master` | `--config-dir DIR`, `--reconfigure` | Preflight (commands, Tailscale logged in, git identity, how GitHub is reached), then: records the config dir in `~/.config/fleet/fleet.conf` (offers to clone `FLEET_CONFIG_REPO` into it when missing), creates the vault, master SSH key, digest key (and the T3 client key with `FLEET_T3_REMOTE=1`); Tailscale: bootstrap token → policy check/merge-apply → scoped OAuth client (token revoked; init stops if the policy step is skipped); GitHub: `gh auth login --web` or token; installs the reconcile timer. `--reconfigure` redoes the Tailscale/GitHub steps. Idempotent. |
| `fleet secrets set NAME` | `--profile minimal\|full` (default full) | Stores one secret from a hidden prompt or stdin into `vault/secrets/<profile>.env`. |
| `fleet secrets list` | | Names and profiles only. |
| `fleet files add PATH` | `--profile minimal\|full` | Mirrors a file under `$HOME` into the vault; recreated at the same relative path on nodes. |
| `fleet proxy import [DIR]` | | Copies CLIProxyAPI `conf/config.yaml` and `auth/*.json` from DIR (default `FLEET_CLIPROXY_DIR`) into the full profile. |
| `fleet invite` | `--ephemeral`, `--profile P`, `--name N`, `--user U`, `--code-only` | Mints a single-use, pre-authorized, tagged Tailscale key (1 h), records a pending invite (nonce), prints the join one-liner and the invite code (which also carries `FLEET_TOOLS`). `--ephemeral` = ephemeral device + minimal profile. `--user` = login the master will SSH to. `--code-only` prints just the code. |
| `fleet nodes` | `--live` | Registry table; `--live` adds each node's tool states over SSH (10 s timeout each). Unregistered tagged peers show as `unknown`. |
| `fleet ssh NODE [COMMAND...]` | | Shell on NODE, or run COMMAND there with the node's fleet environment (`env.sh`) loaded; name resolved through the registry, master key, pinned host key. `fleet ssh NODE --help` is help; anything longer after NODE is the remote command. |
| `fleet provision NODE` | `--refresh-proxy-auth` | Takes the node lock, ships code and config (when the node has no git checkout of them, or no repo URL is set), secrets, files (via a staging dir), the T3 key line (only when the T3 key exists), runs `fleet pull --no-apply` on the node, then `fleet apply --from-master <digest>`; records the `<code>+<config>` the node reports it applied. NODE = registered name or Tailscale id, never a guessed hostname. |
| `fleet reconcile` | | Expires old invites, enrols new tagged peers (nonce check, claims the invite atomically, registers the deploy keys), provisions nodes whose digest differs, retries pending cleanups, tracks missing devices and revokes them after the grace period. Convergent; quiet when nothing to do. Runs every `FLEET_RECONCILE_EVERY` minutes. |
| `fleet kick NODE` | `--yes` | Revoke: see "Kick a node". |
| `fleet t3 setup [NODE]` | | Creates `vault/ssh/t3_client` if missing, pins the node's host key, puts the restricted key line into the node's `authorized_keys`, regenerates `~/.ssh/config.d/fleet` and the `Include` at the top of `~/.ssh/config`, prints what to click in T3 Code. Without NODE: every registered node. Re-enables a node after `t3 revoke`. |
| `fleet t3 status [NODE]` | | Per node: pinned host key, the alias as `ssh -G` resolves it, a BatchMode connection with the client key running T3's discovery, and the node's T3 sessions and pairing tokens (metadata only). |
| `fleet t3 revoke NODE` | | On the node: revokes every pairing-token session and live pairing token, stops the servers T3 started, removes the `fleet-t3-client` line; records `t3_access: false`; drops the `Host fleet-<name>` block. Unreachable node → `t3:<id>` in `pending_cleanup`. |
| `fleet config publish` | `--yes`, `--no-capture` | Git identity check, `harness_capture` into the config dir (authoritative; skipped with `--no-capture`), secret scan over `harness/` and `skills/` (always), staged diff, confirm, commit (`publish fleet config`), push to the checkout's `origin`. Never touches the fleeter checkout. |
| `fleet policy check` | | Fetches the live policy with the OAuth client and checks it against the template. Exit 1 on findings. |
| `fleet policy apply` | | Merges the fleet rules into the **live** policy (adds the `tagOwners` entry and the template grants; turns `*`/`autogroup:tagged` sources into `autogroup:member`; keeps every other rule), shows a unified diff, requires the typed word `apply`, backs up the previous policy to `vault/policy-backups/`, POSTs with `If-Match`. Asks for a one-off API access token (revoked afterwards). |
| `fleet doctor` | | See "Check isolation". Exit 1 on any problem. |
| `fleet join` | env `FLEET_INVITE_CODE` or `FLEET_INVITE_FILE` | Node bootstrap (also embedded in the invite one-liner). Interactive, uses sudo once; skips browser/docker installs the fleet's tools do not need. |
| `fleet apply` | `--from-master DIGEST` | Converges tools, instructions, harness templates, skills, `env.sh`, shell rc block, memory clone (when configured), timers. Records the digest and `applied_commit` only on success. Takes `~/.config/fleet/locks/apply`. |
| `fleet pull` | `--no-apply` | Fetches the code and config repos (converting the shipped tar copies into checkouts the first time, cloning a missing config dir, re-pointing `origin` when the configured URL changed), and runs `apply` when `<code>+<config>` differs from the last successful apply. Timer: `FLEET_PULL_EVERY`. |
| `fleet update` | | Vendor updaters for every tool (`claude update`, `codex update`, `mise self-update`, brew/apt where allowed). Timer: `FLEET_UPDATE_EVERY`. |
| `fleet memory sync` | `--reset` | `git add nodes/<name>` → commit → `pull --rebase` → push, 3 bounded retries. Conflict → abort, state `conflict`, stop. `--reset` clears the state. No-op without a memory repo. Timer: `FLEET_MEMORY_EVERY`. |
| `fleet login [TOOL]` | | Interactive login for TOOL, or for every tool whose status is `login`; opens GUI apps on macOS. |
| `fleet status` | `--json` | Writes and prints `~/.config/fleet/status.json`. |
| `fleet leave` | | Stops the daemon/timers, harness processes and the proxy, `tailscale logout`. Files stay (see "Uninstall"). |
| `fleet daemon` | | Foreground scheduler for containers (PID 1 safe): runs pull/memory/update on their intervals through `~/.local/bin/fleet`, re-executes itself after a code update, handles TERM with `leave`. |
| `fleet --version`, `fleet --help` | | |
| `docker/spawn.sh N` | `--image IMG`, `--profile P`, `--dry-run`, `-- DOCKER_ARGS` | On the master: N ephemeral containers, one invite each (`--user fleet`), invite via bind-mounted file. No arguments → usage, exit 2. |

## Config reference

Load order: `config/defaults.conf` (shipped, do not edit) → `~/.config/fleet/fleet.conf`
(per machine; may set `FLEET_CONFIG_DIR`) → `$FLEET_CONFIG_DIR/fleet.conf`
(your config repo) → `~/.config/fleet/fleet.conf` again, so a local override
always wins. Plain shell assignments; a key you leave out keeps its default.

| Key | Default | Meaning |
|---|---|---|
| `FLEET_CODE_REPO` | `""` | fleeter repo URL. SSH → nodes get a read-only deploy key; `https://` → public, no key; empty → nodes cannot pull code, provision re-ships it each time. |
| `FLEET_CONFIG_REPO` | `""` | Your config repo (SSH). Required by `init master`, enrolment, publish. |
| `FLEET_MEMORY_REPO` | `""` | Your memory repo (SSH). Empty = shared memory off: no memory deploy key, clone, timer or seed. |
| `FLEET_MEMORY_DIR` | `$HOME/fleet-memory` | Where nodes clone the memory vault. |
| `FLEET_NODE_TAG` | `tag:fleet-node` | Tailscale tag for nodes; must match the policy template. |
| `FLEET_HOSTNAME_PREFIX` | `fleet-` | Tailscale hostname = prefix + node name; travels in the invite code. |
| `FLEET_TOOLS` | `base devtools claude` | Plug-ins converged on every node, in order; see "Choosing tools". Travels in the invite code so `fleet join` can skip unneeded privileged installs. |
| `FLEET_TOOLS_SKIP_IN_CONTAINER` | `t3code` | Plug-ins skipped inside containers. |
| `FLEET_MISE_TOOLS` | `node@lts` | Space-separated mise specs installed globally (`mise use -g`). |
| `FLEET_PNPM` | `""` | pnpm version activated through corepack; empty = skip. |
| `FLEET_NPM_GLOBALS` | `""` | npm packages installed with `npm -g` through mise's node. |
| `FLEET_DOCKER_LOGINS` | `""` | `host=USER_VAR:TOKEN_VAR` entries; the named variables come from secrets; `docker login --password-stdin`. |
| `FLEET_CHROME_DEVTOOLS_MCP` / `FLEET_PLAYWRIGHT_MCP` | `1.10.1` / `0.0.83` | Pinned versions of the two browser MCP servers. |
| `FLEET_PROXY_MODE` | `local` | `local`: every node runs CLIProxyAPI from `templates/cliproxy`; `remote`: only use `FLEET_PROXY_URL` (containers are always remote). Only matters with `cliproxy` in `FLEET_TOOLS`. |
| `FLEET_PROXY_URL` | `http://127.0.0.1:8317` | Exported as `ANTHROPIC_BASE_URL` while the proxy is enabled for the node. Keep the port in step with `FLEET_PROXY_PORT`. |
| `FLEET_PROXY_IMAGE` | `eceasy/cli-proxy-api:latest` | Image in the rendered compose file. |
| `FLEET_PROXY_TZ` | `UTC` | `TZ` inside the proxy container (log timestamps). |
| `FLEET_PROXY_CONTAINER` | `cli-proxy-api` | Container name in the rendered compose file (also what `fleet leave` stops). |
| `FLEET_PROXY_PORT` | `8317` | Host port on 127.0.0.1 the proxy is published on. |
| `FLEET_CLIPROXY_DIR` | `$HOME/cli-proxy-api` | Compose directory on nodes; default source for `fleet proxy import`. |
| `FLEET_T3_REMOTE` | `0` | `1`: `fleet init master` creates the T3 client key, so every node gets the restricted `authorized_keys` line and `~/.ssh/config.d/fleet` is maintained. `0`: only after `fleet t3 setup`. |
| `FLEET_SKILL_EXCLUDE` | `""` | Skills on the master never captured. |
| `FLEET_CAPTURE_MACHINE_ONLY` | `""` | Extra words marking MCP servers/hooks as machine-only (dropped on capture). |
| `FLEET_CAPTURE_AGENT_EXCLUDE` | `""` | Claude agent files (basename without `.md`) not captured. |
| `FLEET_CAPTURE_AGENT_MARKERS` | `""` | `;`-separated text markers; an agent file containing one is not captured. |
| `FLEET_CAPTURE_RULE_DROP` | `""` | Extra words that drop a Codex `prefix_rule` on capture. |
| `FLEET_PULL_EVERY` / `FLEET_MEMORY_EVERY` / `FLEET_UPDATE_EVERY` / `FLEET_RECONCILE_EVERY` | `15` / `5` / `1440` / `2` | Timer intervals in minutes. |
| `FLEET_MISSING_GRACE_HOURS` | `24` | Hours a non-ephemeral node may be gone from the device list before its keys are revoked (ephemeral: 1 h fixed). |
| `FLEET_DEFAULT_PROFILE` / `FLEET_EPHEMERAL_PROFILE` | `full` / `minimal` | Secret profile for normal / `--ephemeral` invites. |

Environment knobs (not config keys; all optional):

| Variable | Meaning |
|---|---|
| `FLEET_HOME`, `FLEET_VAULT`, `FLEET_SHARE`, `FLEET_BIN` | State dir (`~/.config/fleet`), vault (`$FLEET_HOME/vault`), node code dir (`~/.local/share/fleet`), bin dir (`~/.local/bin`). |
| `FLEET_CONFIG_DIR` | Overrides the config dir recorded in `~/.config/fleet/fleet.conf` (the environment wins). |
| `FLEET_NODE_USER` | Default login for invites (default: your own). |
| `FLEET_VERBOSE=1`, `FLEET_NO_OPEN=1`, `FLEET_NO_SCHEDULER=1` | More output; never open a browser; write timers/plists but do not load them (master and nodes). |
| `FLEET_HEADLESS=0\|1`, `FLEET_CHROME_PROFILE` | Browser MCP wrappers: force headed/headless; profile dir (default `~/.cache/fleet/chrome-profile`). |
| `FLEET_HARNESS_NO_CLI=1` | Skip `claude plugin` calls during apply. |
| `FLEET_APPLY_LOCK_WAIT`, `FLEET_STATUS_SECS`, `FLEET_PUBLISH_DIFF_LINES` | Seconds to wait for the apply lock (600); cap per tool status check (20); diff lines shown by publish (200). |
| `FLEET_INVITE_CODE`, `FLEET_INVITE_FILE` | `fleet join` without the prompt (containers); the file form never shows in `docker inspect`. |
| `FLEET_LOCAL_CONF`, `FLEET_TOOLS`, `FLEET_FAKE_TAILSCALE` | Container entrypoint: content for the node's local `fleet.conf`; a tool-list shortcut; test mode without tailscaled. |
| `FLEET_NODE_IMAGE` | Image used by `docker/spawn.sh` (default `fleet-node:local`). |
| `FLEET_CODE_REMOTE`, `FLEET_CONFIG_REMOTE`, `FLEET_MEMORY_REMOTE` | Replace the derived `github-fleet-*` URLs on a node (local bare repos, tests). |
| `FLEET_TS_API`, `FLEET_GH_API`, `FLEET_TS_STATUS_JSON`, `FLEET_MASTER_TS_IP` | Test/offline mode: base URLs for `lib/api.py` (see `tests/e2e/fake_api.py`); a file in place of `tailscale status --json`; the master's tailnet IP. `FLEET_GH_API` also forces the token path instead of `gh`. |
| `FLEET_MEMORY_SEED=0`, `FLEET_NOW_EPOCH` | Never clone/seed the memory repo from the master; fake clock for the grace-period logic (tests). |
| `FLEET_SSHD_CONFIG`, `FLEET_SSHD_CONFIG_DIR` | Paths `fleet join` hardens (tests redirect them). |

## Files on disk

Master, `~/.config/fleet/vault` (0700 dirs, 0600 files):

```
secrets/minimal.env, secrets/full.env   KEY='value' lines; full = minimal + full
files/<profile>/<path under $HOME>      mirrored files; files/full/.cli-proxy-api/{config.yaml,auth/}
ssh/fleet_master(.pub)                  the key nodes authorize for provisioning
ssh/t3_client(.pub)                     the key T3 Code uses towards nodes (only with FLEET_T3_REMOTE=1 or after fleet t3 setup)
ssh/known_hosts                         pinned node host keys (read over the fleet session); every ssh is strict once pinned
digest.key                              HMAC key for the desired-state digest; never shipped
tailscale.json                          OAuth client (auth_keys, devices:core, policy_file:read; tag-scoped)
github.json                             fallback token (only without gh)
nodes/<ts-id>.json                      registry; nodes/pending/, nodes/claimed/, rollback-* tombstones
policy-backups/<timestamp>.hujson       the live policy as it was before each `policy apply`
locks/<ts-id>/{pid,token}, locks/.registry
audit.log                               one line per action
~/.config/fleet/fleet.conf              FLEET_CONFIG_DIR + local overrides; reconcile.log
~/Library/LaunchAgents/dev.fleet.reconcile.plist   or ~/.config/systemd/user/fleet-reconcile.{service,timer}
~/.ssh/config.d/fleet                   `Host fleet-<name>` blocks for T3 Code, regenerated from the registry (0600).
~/.ssh/config                           gets `Include ~/.ssh/config.d/fleet` as its first line (original: config.pre-fleet) — written
                                        only when the T3 client key exists AND at least one node has T3 access; never otherwise
```

Node:

```
~/.local/share/fleet/            fleeter code (tar copy, then a checkout of FLEET_CODE_REPO)
~/.local/share/fleet-config/     your config repo (tar copy, then a checkout)
~/.local/bin/fleet               symlink; ~/.local/bin/fleet-chrome-mcp, fleet-playwright-mcp wrappers (chrome plug-in)
~/.config/fleet/enrol.json       nonce, name, user, os, arch (written by join, 0600)
~/.config/fleet/secrets.env      from the master (0600); env.sh sources it, exports PATH, FLEET_NODE, ANTHROPIC_* (proxy enabled only)
~/.config/fleet/applied, applied_at, applied_commit (<code>+<config>), status.json, memory.state (ok|conflict|missing|off)
~/.config/fleet/manifest, harness.manifest, harness.claude-mcp   what fleet owns, for cleanup
~/.config/fleet/privileged_done  join finished the root steps; locks/apply; logs/<job>.log; daemon.pid
~/.ssh/fleet_code, fleet_config, fleet_memory (+ .pub); ~/.ssh/config block `# >>> fleet >>>` (github-fleet-* aliases)
~/.ssh/authorized_keys           the master key (join) and, with T3 access, the restricted `fleet-t3-client` line
~/.t3/runtime/versions/<v>/t3    T3's own CLI archive, installed by T3's SSH flow on first connect; ~/.t3/ssh-launch/<key>/
~/fleet-memory/                  memory vault (when configured); $FLEET_CLIPROXY_DIR (cliproxy plug-in, default ~/cli-proxy-api)
~/.zshrc, ~/.zshenv, ~/.bashrc, ~/.bash_profile, ~/.profile   one marker block each (whichever exist) that sources env.sh
~/Library/LaunchAgents/dev.fleet.{pull,memory,update}.plist   or ~/.config/systemd/user/fleet-*.timer, or crontab lines `# fleet:<job>`
```

Harness files fleet writes (and the ownership rules) are listed in
`examples/fleet-config/harness/README.md`. Pre-existing files are copied to
`<file>.pre-fleet` once before the first overwrite.

## Uninstall / teardown

**A node.** On the master, `fleet kick NODE` revokes it (device, deploy keys,
remote `fleet leave`). On the node itself, `fleet leave` stops the timers, the
harness processes and the proxy and logs the device out of the tailnet; files
stay so a later re-join is cheap. To remove them too:

```sh
rm -rf ~/.local/share/fleet ~/.local/share/fleet-config ~/.config/fleet
rm -f ~/.local/bin/fleet ~/.local/bin/fleet-chrome-mcp ~/.local/bin/fleet-playwright-mcp
rm -f ~/.ssh/fleet_code ~/.ssh/fleet_code.pub ~/.ssh/fleet_config ~/.ssh/fleet_config.pub ~/.ssh/fleet_memory ~/.ssh/fleet_memory.pub
# ~/.ssh/config, ~/.zshrc, ~/.bashrc, ~/.profile, …: delete the `# >>> fleet >>> … # <<< fleet <<<` block, or restore <file>.pre-fleet
# ~/.ssh/authorized_keys: delete the master's `fleet-master@…` line and any `fleet-t3-client` line
# harness files: the paths in ~/.config/fleet/manifest (restore the <file>.pre-fleet copies if you want the old ones back)
rm -rf ~/fleet-memory ~/cli-proxy-api            # if you used them
```

Timers are already gone after `fleet leave` (`dev.fleet.*` LaunchAgents, `fleet-*`
systemd user units or the `# fleet:` crontab lines). Installed tools (mise, the
agent CLIs, Chrome, Docker) are left alone.

**The master.** Kick every node first (`fleet nodes`, `fleet kick NODE`), then:

```sh
# the reconcile timer
launchctl bootout "gui/$(id -u)/dev.fleet.reconcile"; rm -f ~/Library/LaunchAgents/dev.fleet.reconcile.plist     # macOS
systemctl --user disable --now fleet-reconcile.timer; rm -f ~/.config/systemd/user/fleet-reconcile.{service,timer}  # Linux
# keep a copy of the vault if you may come back (secrets, keys, the OAuth client, the registry, audit log, policy backups)
(umask 077; tar -C ~/.config/fleet -czf ~/fleet-vault-backup.tgz vault)        # restore: tar -C ~/.config/fleet -xzf ~/fleet-vault-backup.tgz
# the T3 ssh include (only if fleet t3 setup was used)
sed -i.bak '/^Include ~\/.ssh\/config.d\/fleet$/d' ~/.ssh/config; rm -rf ~/.ssh/config.d/fleet   # or restore ~/.ssh/config.pre-fleet
# Tailscale: delete the OAuth client "fleet master" (admin console → Settings → OAuth clients) and, if you want the
# fleet rules out of your policy, paste the newest vault/policy-backups/*.hujson back into the policy editor
rm -rf ~/.config/fleet ~/.local/bin/fleet ~/fleeter
```

Deploy keys of kicked nodes are already deleted; `fleet nodes` showing
`cleanup-pending` means a delete is still being retried (`fleet reconcile`).

## FAQ

**Can I use GitLab or Gitea instead of GitHub?** Not yet. Two places assume
GitHub: the master registers per-node deploy keys through the GitHub API
(`gh api repos/…/keys`, or `lib/api.py gh key-create|key-delete` with a token),
and `fleet join` writes `github-fleet-{code,config,memory}` ssh aliases that
`node_repo_alias_url` (lib/node.sh) substitutes only for `git@github.com:` and
`ssh://git@github.com/` URLs. Those two seams, `gh_key_create`/`gh_key_delete`
in `lib/master.sh` and `join_ssh_config` + `node_repo_alias_url`, are where a
GitLab/Gitea key API would go. A public **code** repo on any host works today
(https URL, no key); the config repo needs GitHub.

**Where do secrets live, and can I plug in a secrets manager?** In the file
vault: `~/.config/fleet/vault/secrets/{minimal,full}.env` (0600, under a 0700
dir, on a disk you should encrypt). The seam is small: `cmd_secrets_set` writes
a value, `secrets_env PROFILE` streams what a node of that profile gets,
`secret_names` lists names, and `desired_digest` hashes the same bytes. A
backend that renders the same `KEY='value'` lines into those three functions
would slot in without touching provision or the nodes.

**Do I need the memory repo?** No. Leave `FLEET_MEMORY_REPO` empty and nothing
memory-related exists on master or nodes (no deploy key, clone, timer or seed;
`fleet status` says `memory off`). Add it later: nodes get the key on their
next re-enrolment (`fleet kick` + a fresh invite), new nodes right away.

**Does the master have to be a Mac?** No. A Linux master uses a systemd user
timer for `reconcile`; everything else is the same. The master must stay
logged in to Tailscale and reachable by you; nodes never need the master to
be awake except for enrolment, secrets and kick.

**Does anything run as root?** Only `fleet join`, once, through `sudo`
(packages, Tailscale, sshd, docker-ce, linger). Timers and `fleet apply` run as
your user; the Docker image has no sudo at all.

**What about Windows, or WSL?** No. macOS and Linux (incl. containers) only.

**Can several people share a master?** No; one operator, one vault, your
accounts. Each person runs their own master.

**Why do I need a one-off Tailscale API token at init?** Creating the scoped
OAuth client and writing the policy need rights the client itself does not get
(`policy_file` write, `oauth_keys`). The token is used for those two steps and
revoked at the end; afterwards the master only holds the tag-scoped client.

## Troubleshooting

- **`fleet init master` says Tailscale is not logged in** — `tailscale status`
  must list your tailnet (macOS: the Tailscale app; Linux: `sudo tailscale up`).
  **…git has no identity** — `git config --global user.name …` / `user.email …`.
- **`fleet nodes` shows a peer as `unknown`** — tagged device the master has not
  enrolled: the nonce did not match a pending invite (expired? reused?), or SSH
  failed. Check `ssh -i ~/.config/fleet/vault/ssh/fleet_master <user>@<dnsname>`;
  mint a new invite and rerun the one-liner (`FLEET_VERBOSE=1 fleet reconcile`
  explains why a peer is skipped).
- **Node joined but nothing happens** — the master is off or its timer is not
  loaded: `fleet reconcile` by hand; `fleet doctor` checks the schedule.
- **`memory clone failed (deploy key not registered yet?)`** during the first
  apply, `memory: missing` in `fleet status` — normal if enrolment and provision
  raced; `fleet apply` on the node (or its next `fleet pull`) clones it.
  Persisting: `fleet doctor` on the master (GitHub access), and
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
- **`fleet config publish` removed `skills/fleet-notes`** — capture mirrors the
  master; install the skill there or publish with `--no-capture`.
- **Node joined, but `~/.local/bin/fleet` is missing on it** — the master is
  still setting it up. `fleet nodes` shows `provisioning`; follow it with
  `tail -f ~/.config/fleet/reconcile.log` on the master.
- **Hostname got a `-1` suffix (`fleet-mac2-1`)** — Tailscale already had a
  device with that name. Fleet uses the real name from the registry, so nothing
  breaks; delete the stale device in the admin console for the plain name.
- **`fleet doctor`: ISOLATION FAIL** — a node reached the master. `fleet policy
  check` names the rule; `fleet policy apply` merges the fleet rules into your
  policy (wildcard sources become `autogroup:member`; IP/host/tag sources it
  reports for you to fix by hand). **…has no nc** — the node predates the `nc`
  base package; `fleet ssh NODE fleet apply` (or `fleet join` again on a Linux
  box, apt needs root) installs it.
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
  extension: fleeter opens them (macOS) and reports the manual step.
- **No control panel.** Use `fleet nodes --live`, `fleet kick`, and the
  Tailscale admin console from the phone.
- **No protection from processes already running as your user on the master**;
  the vault is 0700 on a disk you should encrypt.
- **`launchctl setenv` argv note (macOS):** with a local CLIProxyAPI,
  publishing `ANTHROPIC_AUTH_TOKEN` into the launchd session for GUI apps puts
  the token in one process's argv for milliseconds (local user only, never
  logged); `launchctl` has no stdin form. Without `cliproxy`, or with
  `FLEET_PROXY_MODE=remote`, no token is published.

## Security

Short version: nodes can reach the internet but not the master or each other
(tailnet policy, verified by `fleet doctor` from the nodes themselves); the
master pushes over OpenSSH with its own key and pinned host keys; secrets never
enter a repo, argv or a log; every node has its own revocable deploy keys and
Tailscale device; a kicked node loses access but keeps what it had, so you
rotate. Threat model, mechanisms, known limits and the rotation checklist:
[`docs/SECURITY.md`](docs/SECURITY.md).

Further reading: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (trust model,
enrolment, reconcile, shared memory), [`docs/CONTRACT.md`](docs/CONTRACT.md)
(registry schema, node files, plug-in interface), [`docker/README.md`](docker/README.md),
[`examples/fleet-config/README.md`](examples/fleet-config/README.md),
[`CONTRIBUTING.md`](CONTRIBUTING.md) (tests, shell rules, adding a plug-in),
[`CHANGELOG.md`](CHANGELOG.md).

MIT licensed, see `LICENSE`.
