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
 │ fleet sync       (timer, 30 min)│◀──────▶├─ fleet-config  your layer (RO)
 │ ~/.config/fleet/vault  0700     │        └─ fleet-memory  shared vault (RW, nodes/<name>/ only; optional)
 │   secrets/ files/ (age) nodes/  │                 ▲  pull every 15 min / sync every 5 min
 │   ssh/; key in the keychain     │                 │
 └──────────┬──────────────────────┘                 │
            │ OpenSSH, master → node only            │
   ┌────────┼─────────┬──────────────┐               │
   ▼        ▼         ▼              ▼               │
 mac node  linux node docker node  docker node ──────┘
 tag:fleet-node: nodes cannot reach the master or each other
```

## Install

One line, on macOS or Linux, as your normal user (no sudo):

```sh
curl -fsSL https://tkreis.github.io/fleeter/install.sh | bash
```

It clones fleeter into `~/.local/share/fleeter` and links `fleet` and
`fleeter` (same command, two names) into `~/.local/bin`. Nothing else on the
system changes. If `~/.local/bin` is not on your `PATH`, it prints the line to
add. Then continue with [Quickstart](#quickstart) (`fleet init master`).

- **Update:** run the same line again. It fast-forwards the checkout; on a
  master, `fleet sync` also does this on its schedule.
- **Read it first:** the script is [`install.sh`](install.sh) in this repo; the
  same file is served at the URL above. Mirror without GitHub Pages:
  `curl -fsSL https://raw.githubusercontent.com/tkreis/fleeter/main/install.sh | bash`
- **Options** (environment variables before `bash`):
  `FLEETER_DIR` (install dir, default `~/.local/share/fleeter`),
  `FLEETER_BIN` (link dir, default `~/.local/bin`),
  `FLEETER_REPO` (git URL, e.g. your fork),
  `FLEETER_REF` (branch or tag, default `main`, e.g. `v0.3.2`).
  Example: `curl -fsSL https://tkreis.github.io/fleeter/install.sh | FLEETER_REF=v0.3.2 bash`
- **Requires:** `git`, `python3`, `curl`, `ssh`. It refuses to run as root, does
  not touch a checkout with local changes, and never overwrites a `fleet` that
  is not its own link.
- **Remove:** see [Uninstall / teardown](#uninstall--teardown).

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
# 1. install (clones into ~/.local/share/fleeter, links ~/.local/bin/fleet and fleeter; no sudo; rerun to update)
curl -fsSL https://tkreis.github.io/fleeter/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"          # for this shell; put the same line in ~/.zshrc or ~/.bashrc
#   (fork first if you want nodes to pull your own copy: FLEETER_REPO=<your fork> before bash)

# 2. your private config repo, started from the example
cp -R ~/.local/share/fleeter/examples/fleet-config ~/fleet-config && cd ~/fleet-config
$EDITOR fleet.conf          # replace YOU in the repo URLs; FLEET_MEMORY_REPO="" skips shared memory for now
git -c init.defaultBranch=main init && git add -A && git commit -m "start fleet config"
gh repo create YOU/fleet-config --private --source . --push

# 3. the master
fleet init master --config-dir ~/fleet-config
#   checks Tailscale login, git identity, GitHub access; then asks for one short-lived
#   Tailscale API access token (opens the keys page; revoked at the end), the typed word
#   `apply` to merge the fleet rules into your tailnet policy, and one `gh auth login --web`
#   approval if gh is not logged in. Installs the reconcile (2 min) and sync (30 min) timers,
#   the `fleeter` command alias and the `fleet` agent skill for your coding agents. The vault
#   is encrypted with age from the start (installed if missing); its key goes into the login
#   keychain (macOS) / secret-tool (Linux), see "Encrypt, inspect and back up the vault".
claude setup-token                                      # prints a 1-year token
fleet secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal
fleet config publish --no-capture                       # push the example config as it is (see "Push new skills")
fleet doctor

# 4. one Docker node
cd ~/.local/share/fleeter && docker build -f docker/Dockerfile -t fleet-node:local .
docker/spawn.sh 1                                       # mints an invite, starts fleet-dock-<rand>
fleet reconcile                                         # or wait for the timer; first provision takes a few minutes
fleet list                                              # STATE provisioned, SYNCED yes when done

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
| **fleet-memory** (yours, private, optional) | every machine (master included), own folder | Obsidian-compatible Markdown vault: every machine's agent memories under `nodes/<name>/`, `projects/<slug>.md` merged per project, `INDEX.md` | `fleet memory sync` (RW deploy key `~/.ssh/fleet_memory` on nodes; the master's own git credentials) |

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
missing, enables Remote Login (key-only, verified with `sshd -T`), switches
system sleep off on the charger (`pmset -c`, see "Keep nodes awake"), adds the
master's key, generates the deploy keys and writes `~/.config/fleet/enrol.json`.
Then it waits. Within two minutes the master's `reconcile` timer enrols the
node, registers its deploy keys, pushes code, config, secrets and files, and
runs `fleet apply` remotely. Check with `fleet list`. Rerunning the one-liner
is safe.

### Add a Linux box

Same as the Mac, with `--user` if the login name on the box differs from yours:

```sh
fleet invite --name buildbox --user ubuntu
```

`fleet join` uses `sudo` once for apt/dnf/apk/pacman packages, Tailscale,
`openssh-server`, docker-ce and the browser (both only when the fleet's tools
need them), `loginctl enable-linger`, and masking the systemd sleep targets
(see "Keep nodes awake"). After that nothing on the node runs as root; timers
are systemd user units (or cron).

### Keep nodes awake

A node that sleeps is gone: Tailscale cannot wake it, the master's provision
times out and its memory stops syncing. With `FLEET_KEEP_AWAKE=1` (the
default) nodes never enter system sleep; the **master is never touched** (it
may sleep) and containers have nothing to do.

| | `fleet join` (once, with `sudo`) | `fleet apply` (every run, no root) |
|---|---|---|
| macOS | `pmset -c sleep 0 disksleep 0 womp 1 autorestart 1` — the charger profile only, so a MacBook on battery still sleeps; `displaysleep` is never changed, the screen may turn off. `womp` = wake for network access, `autorestart` = power back on after an outage. | LaunchAgent `dev.fleet.awake` running `/usr/bin/caffeinate -i -m -s` (`KeepAlive`, `RunAtLoad`): no idle, disk or system sleep while you are logged in. Removed by `fleet leave` and by the next apply after `FLEET_KEEP_AWAKE=0`. |
| Linux | `systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target` (systemd only) | nothing privileged; apply only points back to join when the targets are not masked |

Both record `~/.config/fleet/power_done`; `fleet status` shows `awake on`
(macOS: the agent is loaded or `pmset -g custom` says `sleep 0` on AC; Linux:
`sleep.target` is masked), `off`, or `n/a` on the master and in containers.
`fleet list --json` carries the same value per node.

Worth knowing on a Mac: a laptop with the lid closed and no external display
still sleeps (macOS clamshell rule — keep the lid open or plug a display in).
The agent needs a logged-in user; after a reboot of a FileVault Mac someone has
to log in once before anything runs (`autorestart` brings the Mac back up, and
whether it logs in automatically is your choice in System Settings → Users &
Groups; fleet never changes login settings).

Switching off: set `FLEET_KEEP_AWAKE=0` in `fleet.conf` (the config repo for
the whole fleet, or `~/.config/fleet/fleet.conf` on one node) and let the next
apply remove the agent. The one-off root settings stay until you undo them —
macOS `sudo pmset -c sleep 1 disksleep 10 womp 0 autorestart 0` (or any values
you like; `pmset -g custom` shows the current ones), Linux `sudo systemctl
unmask sleep.target suspend.target hibernate.target hybrid-sleep.target`; then
`rm ~/.config/fleet/power_done` if you want a later join to redo them. The
join step honours the fleet's setting through the invite code, and
`FLEET_KEEP_AWAKE=0` in the environment of the one-liner skips it for just that
machine.

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

### See the whole fleet

```sh
fleet list                  # one line per node, the command to run first
fleet list --json           # the same as a stable JSON array (schema: docs/CONTRACT.md)
fleet list --offline        # registry + tailnet only, no SSH (fast; works with every node asleep)
```

```
NAME    HOST          ONLINE  STATE        SYNCED  LAST PROVISION  TOOLS                   MEMORY   PROXY  FLEET
mac     Mac           yes     master       -       -               -                       ok (3m)  -      0.3.2
mac2    fleet-mac2    yes     provisioned  yes     3h              9 ok, 1 login: cursor   ok       ok     0.3.0
build   fleet-build   yes     provisioned  behind  2d              unreachable             -       -      -
dock-7  fleet-dock-7  no      provisioned  ?       -               -                       -       -      -
fleet-x fleet-x       yes     unknown      -       -               -                       -       -      -
```

`fleet list` joins the registry, the tailnet peer list and, for every online
node, its `fleet status --json` (fetched in parallel, 10 s cap each,
`FLEET_LIST_SECS`). The first row is the master itself (STATE `master`): its
MEMORY column says whether this machine's own agent memories reach the vault
(`ok (3m)` = last sync 3 minutes ago; `missing` = run `fleet schedule install`).
SYNCED compares what the node applied (code and config revisions, digest) with
what this master wants: `behind` means the next
`reconcile`/`sync` will provision it. A node on the tailnet that did not answer
shows `unreachable`; a tagged device the master never enrolled shows `unknown`.
The exit code is 0 either way. `fleet nodes [--live]` is the older compact
registry table and still works; `fleet ssh NODE fleet status` is the detailed
view of one node (versions, logins, revs, memory, timers, token ages).

### Let agents drive fleet

fleeter ships an [Agent Skill](skills/fleet/SKILL.md) that tells Claude Code,
Codex and Cursor when and how to use `fleet`: the read-only commands to start
with, the exact command for each job, what needs the user's confirmation
(`kick`, `leave`, `policy apply`, `config publish`, overwriting a secret), that
secret values never go into argv or a transcript, and how to read the `list`
columns. `fleet init master` installs it into `~/.claude/skills/fleet`,
`~/.agents/skills/fleet` (Codex) and `~/.cursor/skills/fleet` for every harness
present on the master or listed in `FLEET_TOOLS`; `fleet skill install` repeats
that any time; `fleet apply` does the same on every node (a `skills/fleet/`
directory in your config repo replaces it). Then, in any agent:

```
> which of my machines are behind, and why?
> run the test suite of ~/projects/app on build and summarise the failures
> cursor on mac2 needs a login — what do I do?
```

The agent runs `fleet list --json`, `fleet ssh NODE …` and the rest for you.

### Automatic updates

Nothing has to be pushed by hand. Every `FLEET_SYNC_EVERY` (30) minutes the
master runs `fleet sync`:

1. fast-forwards its own fleeter checkout and the config checkout from their
   upstream branch, **only** when the working tree is clean and the branch is
   strictly behind (never a stash, reset or merge; a dirty or diverged checkout
   is reported and left alone; after a code update sync re-executes itself
   from the new code);
2. publishes skills installed in the master's skill dirs that the config repo
   lacks or has in another version (`FLEET_SYNC_PUBLISH_SKILLS`, default on;
   see "Install a skill on every machine");
3. runs `reconcile`: enrols waiting nodes and provisions every node whose
   desired state (code, config, secrets, files) changed, which is what carries a
   `git push` to your config repo, a `fleet secrets set` or a new fleeter
   release to the nodes;
4. every `FLEET_PUSH_TOOLS_EVERY` (1440) minutes runs `fleet update` on the
   online provisioned nodes in parallel (`0` = never; the nodes keep their own
   daily update timer either way).

`fleet sync` by hand runs the same once; it is quiet when nothing happened and
logs to `~/.config/fleet/sync.log` when run from the timer. The 2-minute
`reconcile` timer stays for fast enrolment; the two share a master-wide lock
(`vault/locks/.sync`), so they never overlap. `fleet schedule install` (re)writes
the master timers (plus `memory` when a memory repo is configured), e.g. after
changing the intervals in `fleet.conf`. Nodes still
pull the repos themselves every `FLEET_PULL_EVERY` minutes, so a master that is
asleep only delays secrets and tool pushes, not code or config.

### Run something on a node

```sh
fleet ssh studio                         # interactive shell as the node's login, fleet environment loaded
fleet ssh studio claude -p 'summarise ~/projects/app/README.md'
fleet ssh studio fleet login codex       # device-code login for one tool (see below)
```

`fleet ssh` resolves the name through the registry (user, DNS name, pinned host
key, master key); the remote command runs after `~/.config/fleet/env.sh` is
sourced, so PATH, secrets and proxy variables are what the agents see.

### Install a skill on every machine

```sh
fleet skill add ~/my-skills/review                                  # a directory with a SKILL.md
fleet skill add https://github.com/you/skills.git#review@v1         # a git repo: #subdir and @ref (tag, branch, commit) optional
fleet skill add git@github.com:you/skills.git#skills/review --name pr-review   # under another name
```

One command does the whole round trip: the skill is validated (a `SKILL.md`
with YAML frontmatter and a `name`, which becomes the directory name unless
`--name` says otherwise), secret-scanned, copied into `skills/<name>/` of your
config repo, installed into this machine's own skill dirs, committed (`add
skill review`), pushed, and pushed to the online nodes right away:

```
 ok added review to your fleet config
 ok published (secret scan clean)
 ok pushed to 2 nodes
```

A git source is cloned shallowly into a private temp dir that is removed
afterwards. A skill that already exists in the fleet with different content is
only replaced with `--yes` (identical content is a no-op); a skill with a token
or a home path in it is refused before anything is copied. `fleet skill add`
asks once before it commits (`--yes` skips the question); with no node online
it says `nodes pick it up on their next pull`. `FLEET_SKILL_ADD_NO_SYNC=1`
skips the push to the nodes.

```sh
fleet skill list            # NAME  SOURCE (config | fleet | local-only)  ON NODES?  DESCRIPTION; --json for scripts
fleet skill remove review   # out of the config repo, this machine and (next apply, or right away) every node; asks first
```

`local-only` in `fleet skill list` means a skill that is installed in one of this
machine's skill dirs (`~/.claude/skills`, `~/.agents/skills`, `~/.codex/skills`,
`~/.cursor/skills`) but not yet in the config repo. You do not have to add
those by hand: every `fleet sync` (the 30-minute timer) publishes them —
copied in, secret-scanned, committed as `publish skills: a, b`, pushed — and
republishes a skill you changed locally. A skill with a scan hit is skipped with
a warning until you fix it or list it in `FLEET_SKILL_EXCLUDE`; nothing is ever
removed from the repo automatically (that is what `fleet skill remove` is for).
Set `FLEET_SYNC_PUBLISH_SKILLS=0` in `fleet.conf` to turn the auto-publish off.
On a node, `fleet skill list` shows what `fleet apply` installed there.

### Push new skills or instructions

Install the skill on the master as you normally would (`~/.claude/skills`,
`~/.agents/skills`, …) or with `fleet skill add`, edit `AGENTS.md` in your
config repo if needed, then:

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
`FLEET_PULL_EVERY` (15) minutes and re-apply; the master's `fleet sync` timer
(30 min) provisions them with it too; `fleet reconcile` or `fleet provision
NODE` does it right away. Skills alone do not need a publish: `fleet skill add`
and the sync auto-publish commit and push them on their own.

### Add or rotate a secret

```sh
fleet secrets set OPENAI_API_KEY                     # hidden prompt (or stdin); profile full by default
fleet secrets set CURSOR_API_KEY --profile minimal   # minimal = what throwaway containers also get
fleet secrets list                                   # names + profiles, never values
fleet reconcile                                      # the digest changed → every online node is re-provisioned
```

On the master the value is stored encrypted (`vault/secrets/<profile>.env.age`,
age, see below); it is decrypted only into the SSH stream to a node. Secrets
land in `~/.config/fleet/secrets.env` (0600) on nodes and are exported by
`~/.config/fleet/env.sh` into every shell and timer. Rotation = `secrets set`
again + `reconcile`. Nodes a secret was sent to are listed in the registry
(`secrets_sent`), so `fleet kick` can tell you what to rotate.

### Encrypt, inspect and back up the vault

Every secret-bearing file in the vault — the env files, mirrored files, the
proxy logins, the Tailscale OAuth client, the GitHub fallback token — is an
[age](https://age-encryption.org) ciphertext (`<name>.age`). The private key
never sits in the vault: it is in the **login keychain** on macOS (service
`fleet-vault`), in **secret-tool** (libsecret) on Linux when installed, or in
`~/.config/fleet/vault.key` (0600) as a fallback; `FLEET_VAULT_KEY_BACKEND`
chooses (`keychain` | `secret-tool` | `file`). Writers only need the public
recipient (`vault/recipient.txt`); readers get the key from the backend and
hand it to `age` on a pipe, never through a file or an argument. The SSH keys
(`vault/ssh/`) stay plain files because ssh needs them.

```sh
fleet vault status          # backend, recipient, key reachable?, encrypted vs plaintext files
fleet vault encrypt         # existing master (before 0.3.0): encrypt the plaintext vault in place, idempotent
fleet vault rotate-key      # new key, every file re-encrypted, old key removed from the backend
fleet vault export ~/fleet-vault-$(date +%F).age   # whole vault (decrypted) in one age -p archive; type a passphrase
age -d ~/fleet-vault-2026-10-04.age | tar -tf -    # list a backup
```

**Existing masters: run `fleet vault encrypt` once after updating.** Until
then everything keeps working on the plaintext files (`fleet doctor` warns),
and the first run after the update re-provisions every node once because the
desired-state digest is now computed over the ciphertexts (so `fleet list` and
`reconcile` can tell `behind` without the key; a re-encrypted value changes the
digest once more, which is harmless).

A locked login keychain (nobody logged in on the Mac) makes the key
unreachable: scheduled `sync`/`reconcile` then skip provisioning with a clear
warning and retry on their own; `fleet secrets set` and friends ask you to
unlock. Nothing decrypted is ever written to the master's disk: secrets go
from memory into the node's ssh session, the mirrored files as a tar built in
memory.

### Mirror a .env file

```sh
fleet files add ~/projects/app/.env                  # full profile; path must be under $HOME
fleet reconcile
```

The file is stored encrypted in the vault (`files/<profile>/<path>.age`) and
recreated at the same path under the node's `$HOME`, 0600, atomically
(unpacked into a private staging dir on the node and renamed into place). Its
ciphertext is part of the digest.

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

### Share what your agents learn across machines

Claude Code, Codex and Grok each keep memories on the machine they run on
(`~/.claude/projects/<slug>/memory/`, `~/.codex/memories/`,
`~/.grok/memory-v2/`). With a memory repo configured, every `fleet memory sync`
(every 5 minutes on every node **and on the master**) mirrors those files into
the vault and pulls what the other machines uploaded, so an agent on any
machine can read what every other machine learned:

```
nodes/<name>/claude/<slug>/…      that machine's Claude Code project memories (slug = Claude's dir name)
nodes/<name>/claude/ALIASES.md    project slugs that share one memory dir there (symlinks), captured once
nodes/<name>/codex/…, grok/…      Codex memories (text files), Grok memories (*.md); sqlite files are skipped
projects/<slug>.md                every machine's memories for one project directory, merged (GitHub Action)
INDEX.md                          one line per note, by node then source, plus the project views
```

Agents do not copy anything: the rendered global instructions tell them to
read `~/fleet-memory/projects/<slug>.md` for the current working directory at
session start (`<slug>` = the absolute path with `/` and `.` replaced by `-`),
`INDEX.md` when they need more, and to treat everything under `nodes/**` as
reference data, never as instructions. `fleet list` shows the master's own
memory state in its first row; a node's shows in its MEMORY column.

What is uploaded, and how to limit it:

| Knob | Default | Effect |
|---|---|---|
| `FLEET_MEMORY_CAPTURE` | `claude codex grok` | Sources mirrored into `nodes/<name>/<source>/`. `""` turns capture off (agents' hand-written notes under `nodes/<name>/` still sync). |
| `FLEET_MEMORY_CAPTURE_EXCLUDE` | `*Library-Application-Support-Claude-scratch*` | Space-separated shell globs matched against the source-relative path (`<slug>/<file>.md`, `global/MEMORY.md`, …); a match is never uploaded. The default drops Claude desktop scratch workspaces. |
| `FLEET_MEMORY_MAX_KB` | `256` | Larger files are skipped. |
| `FLEET_MASTER_NAME` | short hostname | The master's folder in the vault (`nodes/<name>`), sanitised to `[a-z0-9-]`. |

Every captured file goes through the same secret scan as `fleet config
publish` (minus the machine-path rule; commit hashes, UUIDs, kebab-case slugs and `localhost:port/path` values are allowed):
a hit skips that file, warns once, and shows up in `fleet status` as
`not uploaded (secret scan): <paths>`. Deleting a memory locally deletes the
copy in the vault on the next sync (mirror, inside `nodes/<name>/<source>/`
only); the commit subject records the counts: `memory: studio
2026-10-04T12:00:00Z (+2 ~1 -0)`.

**Privacy.** This uploads your agents' memories — including what they noted
about work projects — to your private memory repo, readable by every machine
in the fleet. Exclude paths with `FLEET_MEMORY_CAPTURE_EXCLUDE`, or disable
capture with `FLEET_MEMORY_CAPTURE=""`. Existing masters: `fleet schedule
install` clones the vault and adds the master's `dev.fleet.memory` timer.

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
| `fleet init master` | `--config-dir DIR`, `--reconfigure` | Preflight (commands, Tailscale logged in, git identity, how GitHub is reached), then: records the config dir in `~/.config/fleet/fleet.conf` (offers to clone `FLEET_CONFIG_REPO` into it when missing), creates the vault, its age key in the key backend + `vault/recipient.txt` (installs `age` when missing), the master SSH key (and the T3 client key with `FLEET_T3_REMOTE=1`); Tailscale: bootstrap token → policy check/merge-apply → scoped OAuth client (token revoked; init stops if the policy step is skipped); GitHub: `gh auth login --web` or token; installs the reconcile and sync timers, the `~/.local/bin/fleeter` alias and the `fleet` agent skill. `--reconfigure` redoes the Tailscale/GitHub steps. Idempotent. |
| `fleet secrets set NAME` | `--profile minimal\|full` (default full) | Stores one secret from a hidden prompt or stdin into `vault/secrets/<profile>.env.age` (the current file is decrypted into memory, updated, re-encrypted; needs the vault key). |
| `fleet secrets list` | | Names and profiles only (decrypts into memory; needs the vault key). |
| `fleet files add PATH` | `--profile minimal\|full` | Mirrors a file under `$HOME` into the vault, encrypted straight from the source (`files/<profile>/<path>.age`); recreated at the same relative path on nodes. |
| `fleet proxy import [DIR]` | | Copies CLIProxyAPI `conf/config.yaml` and `auth/*.json` from DIR (default `FLEET_CLIPROXY_DIR`) into the full profile, encrypted. |
| `fleet vault status` | | Key backend (and the one the key was created with), recipient, whether the key is reachable now, how many files are encrypted, which are still plaintext. Read-only. |
| `fleet vault encrypt` | | Migration for a vault from before 0.3.0: creates the key if there is none, encrypts every plaintext secret, env, JSON and mirrored file (each one decrypted again and compared before the plaintext is removed), drops the legacy `digest.key`. Idempotent; refuses when the key backend is unreachable. |
| `fleet vault rotate-key` | | Generates a new key, stores it as the incoming key, re-encrypts every file (verified), swaps files + recipient, then replaces the old key in the backend. Takes the master lock. A crash leaves a vault that still decrypts; rerun to finish. |
| `fleet vault export FILE` | | Tar of the whole vault with everything decrypted, piped into `age -p` (you type the passphrase; interactive). The offline backup; it holds every secret and key once opened. |
| `fleet invite` | `--ephemeral`, `--profile P`, `--name N`, `--user U`, `--code-only` | Mints a single-use, pre-authorized, tagged Tailscale key (1 h), records a pending invite (nonce), prints the join one-liner and the invite code (which also carries `FLEET_TOOLS`). `--ephemeral` = ephemeral device + minimal profile. `--user` = login the master will SSH to. `--code-only` prints just the code. |
| `fleet list` | `--json`, `--offline` | The fleet overview: registry + tailnet peers + each online node's `fleet status --json` (parallel, `FLEET_LIST_SECS` = 10 s each). Columns NAME, HOST, ONLINE, STATE, SYNCED, LAST PROVISION, TOOLS, MEMORY, PROXY, FLEET; `--json` a stable array (`docs/CONTRACT.md`); `--offline` skips SSH. Unknown tagged peers listed as `unknown`, nodes that did not answer as `unreachable`; exit 0 regardless. Never writes the vault. |
| `fleet nodes` | `--live` | Compact registry table (name, id, online, state, profile, age); `--live` adds each node's tool states over SSH. Kept for scripts; `fleet list` supersedes it. |
| `fleet ssh NODE [COMMAND...]` | | Shell on NODE, or run COMMAND there with the node's fleet environment (`env.sh`) loaded; name resolved through the registry, master key, pinned host key. `fleet ssh NODE --help` is help; anything longer after NODE is the remote command. |
| `fleet provision NODE` | `--refresh-proxy-auth` | Takes the node lock, ships code and config (when the node has no git checkout of them, or no repo URL is set), secrets, files (via a staging dir), the T3 key line (only when the T3 key exists), runs `fleet pull --no-apply` on the node, then `fleet apply --from-master <digest>`; records the `<code>+<config>` the node reports it applied. NODE = registered name or Tailscale id, never a guessed hostname. |
| `fleet reconcile` | | Expires old invites, enrols new tagged peers (nonce check, claims the invite atomically, registers the deploy keys), provisions nodes whose digest differs, retries pending cleanups, tracks missing devices and revokes them after the grace period. Convergent; quiet when nothing to do. Runs every `FLEET_RECONCILE_EVERY` minutes; skips (exit 0) while a `fleet sync` holds the master lock. |
| `fleet sync` | | The periodic push (timer: `FLEET_SYNC_EVERY`): fast-forward the fleeter and config checkouts from their upstream when clean and behind, publish local-only skills (`FLEET_SYNC_PUBLISH_SKILLS`), `reconcile`, and every `FLEET_PUSH_TOOLS_EVERY` minutes `fleet update` on the online provisioned nodes (parallel, `FLEET_SYNC_UPDATE_SECS` cap each; last run in `vault/sync.json`). Quiet when nothing happened; see "Automatic updates". |
| `fleet schedule install` | | (Re)install the master timers `reconcile`, `sync` and, with a memory repo, `memory` (`fleet memory sync` every `FLEET_MEMORY_EVERY` min; LaunchAgents `dev.fleet.<job>`, or systemd user timers `fleet-<job>`) with the intervals from `fleet.conf`, and clone the master's memory vault when it is missing. Idempotent; `FLEET_NO_SCHEDULER=1` writes without loading. |
| `fleet skill add SOURCE` | `--name N`, `--yes` | SOURCE = a directory with a `SKILL.md`, or a git URL (https/ssh) with optional `#subdir` and `@ref`, cloned shallowly into a private temp dir. Validates the frontmatter (`name` → directory name unless `--name`; `[a-z0-9][a-z0-9-]{0,63}`), secret-scans, copies into `$FLEET_CONFIG_DIR/skills/N` (an existing different skill only with `--yes`; identical = no-op), installs it into this machine's skill dirs, asks once, commits (`add skill N` / `update skill N`), pushes, then `reconcile` (`pushed to K nodes`; `FLEET_SKILL_ADD_NO_SYNC=1` skips it). |
| `fleet skill list` | `--json` | Master: NAME, SOURCE (`config` = in the config repo, `fleet` = fleeter's bundled skill, `local-only` = installed here but not in the repo yet; the next sync publishes it), ON NODES? (`yes` / `not pushed` / `no`), DESCRIPTION. Node: the skills `fleet apply` installed (from `harness.manifest`). |
| `fleet skill remove NAME` | `--yes` | Removes `skills/NAME` from the config repo (commit `remove skill NAME`, push), deletes this machine's copies (else the next sync would publish it again), then `reconcile`; nodes drop it on their next apply through the manifest cleanup. Asks first. |
| `fleet skill install` | | Copy fleeter's `fleet` agent skill (`skills/fleet`) into `~/.claude/skills`, `~/.agents/skills` and `~/.cursor/skills`, each only when that harness exists here or its tool is in `FLEET_TOOLS`. Idempotent; a foreign `fleet` skill dir is kept once as `.pre-fleet`. `fleet init master` runs it; nodes get the skill from `fleet apply`. |
| `fleet kick NODE` | `--yes` | Revoke: see "Kick a node". |
| `fleet t3 setup [NODE]` | | Creates `vault/ssh/t3_client` if missing, pins the node's host key, puts the restricted key line into the node's `authorized_keys`, regenerates `~/.ssh/config.d/fleet` and the `Include` at the top of `~/.ssh/config`, prints what to click in T3 Code. Without NODE: every registered node. Re-enables a node after `t3 revoke`. |
| `fleet t3 status [NODE]` | | Per node: pinned host key, the alias as `ssh -G` resolves it, a BatchMode connection with the client key running T3's discovery, and the node's T3 sessions and pairing tokens (metadata only). |
| `fleet t3 revoke NODE` | | On the node: revokes every pairing-token session and live pairing token, stops the servers T3 started, removes the `fleet-t3-client` line; records `t3_access: false`; drops the `Host fleet-<name>` block. Unreachable node → `t3:<id>` in `pending_cleanup`. |
| `fleet config publish` | `--yes`, `--no-capture` | Git identity check, `harness_capture` into the config dir (authoritative; skipped with `--no-capture`), secret scan over `harness/` and `skills/` (always), staged diff, confirm, commit (`publish fleet config`), push to the checkout's `origin`. Never touches the fleeter checkout. |
| `fleet policy check` | | Fetches the live policy with the OAuth client and checks it against the template. Exit 1 on findings. |
| `fleet policy apply` | | Merges the fleet rules into the **live** policy (adds the `tagOwners` entry and the template grants; turns `*`/`autogroup:tagged` sources into `autogroup:member`; keeps every other rule), shows a unified diff, requires the typed word `apply`, backs up the previous policy to `vault/policy-backups/`, POSTs with `If-Match`. Asks for a one-off API access token (revoked afterwards). |
| `fleet doctor` | | See "Check isolation"; also warns when the vault still holds plaintext secrets or its key is unreachable. Exit 1 on any problem. |
| `fleet join` | env `FLEET_INVITE_CODE` or `FLEET_INVITE_FILE` | Node bootstrap (also embedded in the invite one-liner). Interactive, uses sudo once; skips browser/docker installs the fleet's tools do not need. |
| `fleet apply` | `--from-master DIGEST` | Converges tools, instructions, harness templates, skills, `env.sh`, shell rc block, memory clone (when configured), timers. Records the digest and `applied_commit` only on success. Takes `~/.config/fleet/locks/apply`. |
| `fleet pull` | `--no-apply` | Fetches the code and config repos (converting the shipped tar copies into checkouts the first time, cloning a missing config dir, re-pointing `origin` when the configured URL changed), and runs `apply` when `<code>+<config>` differs from the last successful apply. Timer: `FLEET_PULL_EVERY`. |
| `fleet update` | | Vendor updaters for every tool (`claude update`, `codex update`, `mise self-update`, brew/apt where allowed). Timer: `FLEET_UPDATE_EVERY`. |
| `fleet memory sync` | `--reset` | Mirrors this machine's agent memories (`FLEET_MEMORY_CAPTURE`) into `nodes/<name>/<source>/`, then `git add nodes/<name>` → commit (`memory: <name> <UTC> (+A ~M -D)`) → `pull --rebase` → push, 3 bounded retries. Runs on nodes and on the master (clones the vault itself when missing). Conflict → abort, state `conflict`, stop. `--reset` clears the state. No-op without a memory repo. Timer: `FLEET_MEMORY_EVERY`. |
| `fleet login [TOOL]` | | Interactive login for TOOL, or for every tool whose status is `login`; opens GUI apps on macOS. |
| `fleet status` | `--json` | Writes and prints `~/.config/fleet/status.json`. |
| `fleet leave` | | Stops the daemon/timers, harness processes and the proxy, `tailscale logout`. Files stay (see "Uninstall"). |
| `fleet daemon` | | Foreground scheduler for containers (PID 1 safe): runs pull/memory/update on their intervals through `~/.local/bin/fleet`, re-executes itself after a code update, handles TERM with `leave`. |
| `fleet --version`, `fleet --help` | | `fleeter` is the same command under the project's name (`~/.local/bin/fleeter`, written by `init master` and node `apply`). |
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
| `FLEET_MEMORY_DIR` | `$HOME/fleet-memory` | Where nodes and the master clone the memory vault. |
| `FLEET_MASTER_NAME` | `""` (short hostname) | The master's folder in the memory vault (`nodes/<name>`), lower-cased, `[a-z0-9-]`. |
| `FLEET_MEMORY_CAPTURE` | `claude codex grok` | Native agent memories `fleet memory sync` mirrors into `nodes/<name>/<source>/` on every machine; `""` = off. |
| `FLEET_MEMORY_CAPTURE_EXCLUDE` | `*Library-Application-Support-Claude-scratch*` | Shell globs (source-relative paths) never uploaded. |
| `FLEET_MEMORY_MAX_KB` | `256` | Memory files larger than this are not uploaded. |
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
| `FLEET_KEEP_AWAKE` | `1` | Nodes never system-sleep: macOS gets the `dev.fleet.awake` LaunchAgent (`caffeinate -i -m -s`) from apply and `pmset -c sleep 0 disksleep 0 womp 1 autorestart 1` from join; Linux join masks the systemd sleep targets. Never the master, never containers. `0` removes the agent on the next apply (root settings stay; see "Keep nodes awake"). Travels in the invite code. |
| `FLEET_PULL_EVERY` / `FLEET_MEMORY_EVERY` / `FLEET_UPDATE_EVERY` / `FLEET_RECONCILE_EVERY` | `15` / `5` / `1440` / `2` | Timer intervals in minutes (nodes: pull, memory, update; master: memory, reconcile). |
| `FLEET_SYNC_EVERY` | `30` | Minutes between `fleet sync` runs on the master (fast-forward checkouts, reconcile, tool push). `fleet schedule install` applies a change. |
| `FLEET_PUSH_TOOLS_EVERY` | `1440` | Minutes between `fleet update` pushes to the online nodes from `fleet sync`; `0` = never push tool updates from the master. |
| `FLEET_SYNC_PUBLISH_SKILLS` | `1` | `fleet sync` publishes skills installed in the master's skill dirs that the config repo lacks or has in another version (secret-scanned, commit `publish skills: a, b`, pushed; `FLEET_SKILL_EXCLUDE` and the bundled `fleet` skill excepted; never removes). `0` = off. |
| `FLEET_MISSING_GRACE_HOURS` | `24` | Hours a non-ephemeral node may be gone from the device list before its keys are revoked (ephemeral: 1 h fixed). |
| `FLEET_DEFAULT_PROFILE` / `FLEET_EPHEMERAL_PROFILE` | `full` / `minimal` | Secret profile for normal / `--ephemeral` invites. |
| `FLEET_VAULT_KEY_BACKEND` | unset = by platform | Where the vault's private age key lives: `keychain` (macOS login keychain, default on macOS), `secret-tool` (libsecret; default on Linux when installed), `file` (`~/.config/fleet/vault.key`, 0600; fallback, CI). Per machine: set it in `~/.config/fleet/fleet.conf` or the environment, and keep it constant once the key exists (`fleet vault status` shows the backend the key was created with). |

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
| `FLEET_LIST_SECS`, `FLEET_SYNC_UPDATE_SECS` | `fleet list`: seconds to wait for each node's status (10); `fleet sync`: seconds for each node's `fleet update` (900). |
| `FLEET_INVITE_CODE`, `FLEET_INVITE_FILE` | `fleet join` without the prompt (containers); the file form never shows in `docker inspect`. |
| `FLEET_LOCAL_CONF`, `FLEET_TOOLS`, `FLEET_FAKE_TAILSCALE` | Container entrypoint: content for the node's local `fleet.conf`; a tool-list shortcut; test mode without tailscaled. |
| `FLEET_NODE_IMAGE` | Image used by `docker/spawn.sh` (default `fleet-node:local`). |
| `FLEET_CODE_REMOTE`, `FLEET_CONFIG_REMOTE`, `FLEET_MEMORY_REMOTE` | Replace the derived `github-fleet-*` URLs on a node (local bare repos, tests). |
| `FLEET_TS_API`, `FLEET_GH_API`, `FLEET_TS_STATUS_JSON`, `FLEET_MASTER_TS_IP` | Test/offline mode: base URLs for `lib/api.py` (see `tests/e2e/fake_api.py`); a file in place of `tailscale status --json`; the master's tailnet IP. `FLEET_GH_API` also forces the token path instead of `gh`. |
| `FLEET_SKILL_ADD_NO_SYNC=1` | `fleet skill add` / `remove`: commit and push, but do not run `reconcile` afterwards (nodes get the change on their next pull). |
| `FLEET_MEMORY_SEED=0`, `FLEET_NOW_EPOCH` | Never clone or seed the memory repo from the master (neither the scaffold seed nor the master's own `~/fleet-memory`); fake clock for the grace-period logic (tests). |
| `FLEET_SSHD_CONFIG`, `FLEET_SSHD_CONFIG_DIR` | Paths `fleet join` hardens (tests redirect them). |

## Files on disk

Master, `~/.config/fleet/vault` (0700 dirs, 0600 files; `*.age` = encrypted to `recipient.txt`):

```
recipient.txt                           the vault's public age recipient (0644) and which key backend holds the private key
secrets/minimal.env.age, full.env.age   KEY='value' lines, encrypted; full = minimal + full
files/<profile>/<path under $HOME>.age  mirrored files, encrypted; files/full/.cli-proxy-api/{config.yaml,auth/*}.age
ssh/fleet_master(.pub)                  the key nodes authorize for provisioning (plain: ssh needs it)
ssh/t3_client(.pub)                     the key T3 Code uses towards nodes (only with FLEET_T3_REMOTE=1 or after fleet t3 setup)
ssh/known_hosts                         pinned node host keys (read over the fleet session); every ssh is strict once pinned
tailscale.json.age                      OAuth client (auth_keys, devices:core, policy_file:read; tag-scoped), encrypted
github.json.age                         fallback token (only without gh), encrypted
digest.key                              legacy (vault before `fleet vault encrypt`): HMAC key for plaintext fingerprints; removed by the migration
nodes/<ts-id>.json                      registry; nodes/pending/, nodes/claimed/, rollback-* tombstones
policy-backups/<timestamp>.hujson       the live policy as it was before each `policy apply`
sync.json                               last `fleet update` push to the nodes (fleet sync)
locks/<ts-id>/{pid,token}, locks/.registry, locks/.sync (sync and reconcile never overlap)
audit.log                               one line per action
~/.config/fleet/fleet.conf              FLEET_CONFIG_DIR + local overrides; reconcile.log, sync.log; logs/update-<node>.log (failed pushes)
~/.config/fleet/vault.key               the private age key, only with FLEET_VAULT_KEY_BACKEND=file (0600); otherwise it is a
                                        keychain item (service fleet-vault, account $USER) or a secret-tool entry, never a file
~/Library/LaunchAgents/dev.fleet.{reconcile,sync,memory}.plist   or ~/.config/systemd/user/fleet-{reconcile,sync,memory}.{service,timer}
~/fleet-memory/                         the master's clone of the memory vault (nodes/<FLEET_MASTER_NAME>); ~/.config/fleet/memory.state, memory.log
~/.local/bin/fleeter                    alias of ~/.local/bin/fleet (same target)
~/.claude/skills/fleet, ~/.agents/skills/fleet, ~/.cursor/skills/fleet   fleeter's agent skill (for the harnesses present here)
~/.claude/skills/<name>, ~/.agents/skills/<name>, ~/.cursor/skills/<name>   skills added with `fleet skill add` (same dirs; recorded in ~/.config/fleet/manifest)
~/.ssh/config.d/fleet                   `Host fleet-<name>` blocks for T3 Code, regenerated from the registry (0600).
~/.ssh/config                           gets `Include ~/.ssh/config.d/fleet` as its first line (original: config.pre-fleet) — written
                                        only when the T3 client key exists AND at least one node has T3 access; never otherwise
```

Node:

```
~/.local/share/fleet/            fleeter code (tar copy, then a checkout of FLEET_CODE_REPO)
~/.local/share/fleet-config/     your config repo (tar copy, then a checkout)
~/.local/bin/fleet, fleeter      symlinks; ~/.local/bin/fleet-chrome-mcp, fleet-playwright-mcp wrappers (chrome plug-in)
~/.claude/skills/fleet, ~/.agents/skills/fleet, ~/.cursor/skills/fleet   fleeter's agent skill (unless your config repo ships its own skills/fleet)
~/.claude/skills/<name>, ~/.agents/skills/<name>, ~/.cursor/skills/<name>   every skills/<name> of the config repo (fleet skill list shows them)
~/.config/fleet/enrol.json       nonce, name, user, os, arch (written by join, 0600)
~/.config/fleet/secrets.env      from the master (0600); env.sh sources it, exports PATH, FLEET_NODE, ANTHROPIC_* (proxy enabled only)
~/.config/fleet/applied, applied_at, applied_commit (<code>+<config>), status.json, memory.state (ok|conflict|missing|off)
~/.config/fleet/manifest, harness.manifest, harness.claude-mcp   what fleet owns, for cleanup
~/.config/fleet/privileged_done  join finished the root steps; locks/apply; logs/<job>.log; daemon.pid
~/.config/fleet/power_done       join switched system sleep off (`<UTC> macos:pmset` or `linux:mask`; FLEET_KEEP_AWAKE)
~/.ssh/fleet_code, fleet_config, fleet_memory (+ .pub); ~/.ssh/config block `# >>> fleet >>>` (github-fleet-* aliases)
~/.ssh/authorized_keys           the master key (join) and, with T3 access, the restricted `fleet-t3-client` line
~/.t3/runtime/versions/<v>/t3    T3's own CLI archive, installed by T3's SSH flow on first connect; ~/.t3/ssh-launch/<key>/
~/fleet-memory/                  memory vault (when configured); $FLEET_CLIPROXY_DIR (cliproxy plug-in, default ~/cli-proxy-api)
~/.zshrc, ~/.zshenv, ~/.bashrc, ~/.bash_profile, ~/.profile   one marker block each (whichever exist) that sources env.sh
~/Library/LaunchAgents/dev.fleet.{pull,memory,update}.plist   or ~/.config/systemd/user/fleet-*.timer, or crontab lines `# fleet:<job>`
~/Library/LaunchAgents/dev.fleet.awake.plist                  macOS only: caffeinate -i -m -s while FLEET_KEEP_AWAKE=1 (in the manifest)
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
rm -f ~/.local/bin/fleet ~/.local/bin/fleeter ~/.local/bin/fleet-chrome-mcp ~/.local/bin/fleet-playwright-mcp
rm -f ~/.ssh/fleet_code ~/.ssh/fleet_code.pub ~/.ssh/fleet_config ~/.ssh/fleet_config.pub ~/.ssh/fleet_memory ~/.ssh/fleet_memory.pub
# ~/.ssh/config, ~/.zshrc, ~/.bashrc, ~/.profile, …: delete the `# >>> fleet >>> … # <<< fleet <<<` block, or restore <file>.pre-fleet
# ~/.ssh/authorized_keys: delete the master's `fleet-master@…` line and any `fleet-t3-client` line
# harness files: the paths in ~/.config/fleet/manifest (restore the <file>.pre-fleet copies if you want the old ones back)
rm -rf ~/fleet-memory ~/cli-proxy-api            # if you used them
```

Timers are already gone after `fleet leave` (`dev.fleet.*` LaunchAgents, `fleet-*`
systemd user units or the `# fleet:` crontab lines). Installed tools (mise, the
agent CLIs, Chrome, Docker) are left alone.

**The master.** Kick every node first (`fleet list`, `fleet kick NODE`), then:

```sh
# the reconcile and sync timers
for j in reconcile sync; do launchctl bootout "gui/$(id -u)/dev.fleet.$j"; rm -f ~/Library/LaunchAgents/dev.fleet.$j.plist; done      # macOS
for j in reconcile sync; do systemctl --user disable --now fleet-$j.timer; rm -f ~/.config/systemd/user/fleet-$j.{service,timer}; done  # Linux
# keep a copy of the vault if you may come back (secrets, keys, the OAuth client, the registry, audit log, policy backups):
# decrypted into one passphrase-protected archive, so it is readable without this machine's keychain
fleet vault export ~/fleet-vault-backup.age        # restore (plaintext, then a fresh key): mkdir -p ~/.config/fleet/vault && age -d ~/fleet-vault-backup.age | tar -C ~/.config/fleet/vault -xf - && fleet vault encrypt
# the vault key: keychain item (macOS) / secret-tool entry (Linux) / ~/.config/fleet/vault.key
security delete-generic-password -s fleet-vault -a "$USER"      # macOS;  Linux: secret-tool clear service fleet-vault account "$USER"
# the T3 ssh include (only if fleet t3 setup was used)
sed -i.bak '/^Include ~\/.ssh\/config.d\/fleet$/d' ~/.ssh/config; rm -rf ~/.ssh/config.d/fleet   # or restore ~/.ssh/config.pre-fleet
# Tailscale: delete the OAuth client "fleet master" (admin console → Settings → OAuth clients) and, if you want the
# fleet rules out of your policy, paste the newest vault/policy-backups/*.hujson back into the policy editor
rm -rf ~/.config/fleet ~/.local/bin/fleet ~/.local/bin/fleeter ~/.local/share/fleeter
rm -rf ~/.claude/skills/fleet ~/.agents/skills/fleet ~/.cursor/skills/fleet    # the agent skill
```

Deploy keys of kicked nodes are already deleted; `fleet list` showing
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
vault, encrypted: `~/.config/fleet/vault/secrets/{minimal,full}.env.age` (age,
key in the login keychain / secret-tool / a 0600 file; see "Encrypt, inspect
and back up the vault"). The seam is small: `cmd_secrets_set` writes a value,
`secrets_env PROFILE` streams what a node of that profile gets, `secret_names`
lists names, and `desired_digest` fingerprints the stored items. A backend
that renders the same `KEY='value'` lines into those functions would slot in
without touching provision or the nodes.

**Do I need the memory repo?** No. Leave `FLEET_MEMORY_REPO` empty and nothing
memory-related exists on master or nodes (no deploy key, clone, timer or seed;
`fleet status` says `memory off`). Add it later: nodes get the key on their
next re-enrolment (`fleet kick` + a fresh invite), new nodes right away.

**Does the master have to be a Mac?** No. A Linux master uses a systemd user
timer for `reconcile`; everything else is the same. The master must stay
logged in to Tailscale and reachable by you; nodes never need the master to
be awake except for enrolment, secrets and kick.

**Does anything run as root?** Only `fleet join`, once, through `sudo`
(packages, Tailscale, sshd, docker-ce, linger, the sleep settings). Timers and
`fleet apply` run as your user; the Docker image has no sudo at all.

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
- **`fleet list` shows a node as `behind`** — the node's applied code/config
  revisions or digest differ from this master's: `fleet provision NODE`, or
  wait for `fleet sync`. If it stays behind, the master's own checkout is
  ahead of what is pushed (nodes only pull what is on the remote): `git push`
  / `fleet config publish`. **…`unreachable`** — on the tailnet but SSH did
  not answer within 10 s: `fleet ssh NODE true`; `FLEET_LIST_SECS=30 fleet list`
  for a slow node.
- **`fleet sync` warns `uncommitted changes` or `diverged`** — it never
  touches such a checkout; commit/push or `git pull --rebase` by hand in
  `$FLEET_ROOT` or the config dir and the next run fast-forwards again.
- **`fleet list` shows a peer as `unknown`** — tagged device the master has not
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
- **`the vault key is unreachable` / `provision skipped`** — the login keychain
  is locked (nobody logged in on the Mac) or the secret service is not
  reachable from the timer's session: log in / unlock, and the next `sync`
  picks it up; `fleet vault status` shows the backend and the key state. On a
  headless Linux master set `FLEET_VAULT_KEY_BACKEND=file` in
  `~/.config/fleet/fleet.conf` before `fleet init master` (or move the key:
  `fleet vault export`, delete the entry, set the knob, `fleet vault encrypt`
  after restoring the export).
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
  still setting it up. `fleet list` shows `provisioning`; follow it with
  `tail -f ~/.config/fleet/reconcile.log` (or `sync.log`) on the master.
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
- **A node keeps going offline / `unreachable` after a while** — it sleeps;
  an asleep Mac cannot be woken over Tailscale. On the node `fleet status`
  should say `awake on`; `off` means `FLEET_KEEP_AWAKE=0`, the join step was
  skipped or failed (`~/.config/fleet/power_done` missing: rerun the
  one-liner, or run the `pmset -c` / `systemctl mask` line from "Keep nodes
  awake" by hand), or on a Mac nobody is logged in (the agent runs per user)
  or the lid is closed without an external display.

## What fleeter does not do

- **No credential wiping.** A kicked or vanished node keeps every secret and
  file it had. Kick cuts access (tailnet, repos) and lists what to rotate; you
  rotate.
- **No GUI logins.** Claude desktop, ChatGPT desktop, Cursor IDE, the Chrome
  extension: fleeter opens them (macOS) and reports the manual step.
- **No control panel.** Use `fleet list`, `fleet kick`, and the Tailscale
  admin console from the phone (or let an agent run them: "Let agents drive fleet").
- **No protection from processes already running as your user on the master**:
  the vault is encrypted at rest, but a process running as you can read the
  key the same way `fleet` does (unlocked keychain, your secret service, or
  `vault.key`). Keep the disk encrypted too (FileVault/LUKS).
- **`launchctl setenv` argv note (macOS):** with a local CLIProxyAPI,
  publishing `ANTHROPIC_AUTH_TOKEN` into the launchd session for GUI apps puts
  the token in one process's argv for milliseconds (local user only, never
  logged); `launchctl` has no stdin form. Without `cliproxy`, or with
  `FLEET_PROXY_MODE=remote`, no token is published.

## Security

Short version: nodes can reach the internet but not the master or each other
(tailnet policy, verified by `fleet doctor` from the nodes themselves); the
master pushes over OpenSSH with its own key and pinned host keys; secrets are
age-encrypted at rest on the master (key in the keychain) and never enter a
repo, argv or a log; every node has its own revocable deploy keys and
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
