---
name: fleet-setup
description: Install fleeter and set up this machine as the fleet master for the first time. Use when the user wants to install or set up fleeter, create a fleet master, or asks to "set up fleeter for me"; it asks the right questions, runs `fleet setup` with the matching flags, and never asks for a secret in the chat.
---
# Set up fleeter — instructions for a coding agent

You are setting up [fleeter](https://github.com/tkreis/fleeter) for the user on
this machine. This machine becomes the **master**: it keeps the secrets in a
local encrypted vault, mints invites, and pushes config and secrets to the
user's other machines (nodes) over their tailnet. `fleet setup` does the work;
your job is to ask the right questions, run it with the matching flags, and
hand the user the two or three prompts only they can answer.

## Hard rules

- **Never ask the user to paste a secret, token or password into the chat.**
  Secrets are typed by the user into hidden prompts in *their* terminal
  (`fleet secrets set NAME`, the Tailscale token prompt of `fleet setup`), or
  read by a command from a pipe (`claude setup-token | fleet secrets set …`)
  without being displayed. Never `echo`, `cat` or log a token; never put one
  on a command line.
- **Confirm before** creating GitHub repos, applying the Tailscale policy, or
  anything destructive (`fleet kick`, `fleet policy apply`, overwriting a
  secret, `--yes`). Say what will be created and where.
- When a command needs an interactive prompt you cannot drive (a browser
  login, a hidden token prompt, the typed word `apply`), stop and tell the
  user exactly what to run and what to type in their own terminal, then
  continue when they say it is done.
- Start read-only (`fleet --version`, `fleet doctor`, `fleet list`); every
  `fleet` command accepts `--help` and then runs nothing.

## Questions to ask, in order

Ask only what the defaults do not settle. Each answer maps to a flag below.

| # | Question | Default | Why it matters |
|---|---|---|---|
| 1 | Which machines will join: Macs, Linux boxes, Docker containers? | – | Decides the tools preset, keep-awake, and the first invite. |
| 2 | Which agents should every node run: Claude Code only (`minimal`), plus Codex, Cursor and a browser (`agents`), or everything incl. Grok, CLIProxyAPI, T3 Code (`full`)? A custom space-separated list is also fine (`lib/tools`). | `agents` | `--tools` |
| 3 | Shared memory on? **Privacy note:** every machine (this one included) uploads its agents' memories — Claude Code, Codex, Grok, work projects included — into a private GitHub repo of the user's, and every machine reads all of it. Secret-scanned, but not private per machine. | yes, repo `fleet-memory` | `--memory` / `--no-memory`, `--memory-repo NAME` |
| 4 | GitHub user or organisation for the repos, and the config repo name? | the `gh` login, `fleet-config`, checkout `~/fleet-config` | `--github-owner`, `--config-repo`, `--config-dir` |
| 5 | Do they use CLIProxyAPI here (`~/cli-proxy-api/conf/config.yaml` exists) and want it on every node? | no (yes only if that file exists) | `--proxy` / `--no-proxy` |
| 6 | Should nodes never sleep (always-on machines)? For a MacBook node with the lid closed they can later set `FLEET_KEEP_AWAKE_LID=1` in `fleet.conf` (heat and battery caveats). | yes | `--keep-awake` / `--no-keep-awake` |
| 7 | Do they use AWS SSO (`aws sso login`) here and want the nodes to use it? Which profiles, e.g. `dev`? fleet pushes only the profiles listed in `FLEET_AWS_PROFILES`; keep production out of that list. The SSO login stays on the master; nodes get short-lived role credentials. | none | `--aws-profiles "dev"` |

## Commands

1. Install `fleet` if `command -v fleet` finds nothing (no sudo; it clones
   into `~/.local/share/fleeter` and links `~/.local/bin/fleet`):

   ```sh
   curl -fsSL https://tkreis.github.io/fleeter/install.sh | bash
   export PATH="$HOME/.local/bin:$PATH"
   fleet --version
   ```

2. Preflight you can check yourself: `tailscale status` (logged in),
   `git config --get user.email` (an identity), `gh auth status` (logged in; if
   not, the user runs `gh auth login -h github.com --web`), `claude --version`
   (optional: without Claude Code here, the token step is skipped).

3. Run setup with the answers as flags. Run it **in the user's terminal**
   (tell them the exact line) when your shell has no terminal: it needs their
   keyboard for the Tailscale token, the typed `apply`, and the Claude login.

   ```sh
   fleet setup --github-owner OWNER --tools agents --memory --no-proxy --keep-awake
   ```

   `--yes` accepts the defaults for every remaining question *and* confirms
   the repo creations: pass it only after the user agreed to the answers
   above. Flags: `--github-owner OWNER`, `--config-repo NAME`,
   `--config-dir DIR`, `--memory`/`--no-memory`, `--memory-repo NAME`,
   `--tools minimal|agents|full|"LIST"`, `--proxy`/`--no-proxy`,
   `--keep-awake`/`--no-keep-awake`, `--claude-token`/`--no-claude-token`,
   `--aws-profiles "LIST"`. Rerunning is safe: finished steps print `skip`.

4. What happens, step by step (`[n/9]` lines; `ok` or `skip`):

   | Step | What it does | The user may be asked |
   |---|---|---|
   | 1 preflight | commands, Tailscale logged in, git identity, `gh` login | `gh auth login --web`: one browser approval |
   | 2 GitHub owner | `gh api user`, confirmed | the owner, if not given |
   | 3 config repo | clones `OWNER/fleet-config` if it exists; else copies the example, renders `fleet.conf` from the answers, commits, `gh repo create … --private --source DIR --push` | "Create the private GitHub repo …?" |
   | 4 memory repo | `gh repo create OWNER/fleet-memory --private` (empty; the master seeds it) | "Create …?" |
   | 5 init master | vault + key, master ssh key, Tailscale OAuth client, policy merge, timers, the `fleet` agent skill | the keys page opens: they create a 1-day **API access token** and type it at the hidden prompt (revoked at the end); then a diff and the typed word **`apply`** |
   | 6 Claude login | `claude setup-token \| … \| fleet secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal` (the token never leaves the pipe); then optional extra secrets | a browser login, the code pasted into *their* terminal; more secret names/values, hidden |
   | 7 proxy | `fleet proxy import` when chosen | – |
   | 8 publish, doctor | `fleet config publish --yes` (captures this machine's harness config into the repo), `fleet doctor` | – |
   | 9 next | prints the invite / spawn / list commands | – |

5. Verify, then add the first node:

   ```sh
   fleet doctor
   fleet list
   fleet invite --name NAME        # a Mac or Linux box: the user pastes the printed one-liner there, then the code
   docker build -f ~/.local/share/fleeter/docker/Dockerfile -t fleet-node:local ~/.local/share/fleeter && ~/.local/share/fleeter/docker/spawn.sh 1   # or a throwaway container
   fleet list                      # STATE provisioned, SYNCED yes within a few minutes
   fleet aws push                  # with FLEET_AWS_PROFILES set and the user logged in (aws sso login): the AWS column says ok
   ```

   Later changes: edit `~/fleet-config/fleet.conf` and run
   `fleet config publish --no-capture`; more secrets with
   `fleet secrets set NAME --profile minimal` (typed hidden by the user).
   AWS: `fleet aws login` runs `aws sso login` for the first allowed profile
   (a browser step for the user) and pushes; `fleet sync` keeps the nodes'
   credentials fresh afterwards and never logs in by itself.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Tailscale is not logged in` | macOS: open the Tailscale app and log in; Linux: `sudo tailscale up`. Then rerun `fleet setup`. |
| `git has no identity` | `git config --global user.name "Name"` and `git config --global user.email you@example.com`. |
| `gh is installed but not logged in` / `fleet setup needs the GitHub CLI` | user runs `gh auth login -h github.com --web` (macOS: `brew install gh` first). |
| `vault key: UNREACHABLE` / keychain locked (`fleet doctor`, `fleet vault status`) | the user unlocks the login keychain (`security unlock-keychain`) or logs in on the Mac; Linux: `secret-tool` needs an unlocked keyring. |
| `policy: live tailnet policy does not isolate tag:fleet-node` | the user runs `fleet policy apply` (new 1-day API token, types `apply`); `fleet policy check` afterwards. |
| `fleet list`: node `behind` | `fleet provision NODE`, or wait for `fleet sync`; is the config pushed? `fleet config publish`. |
| node ONLINE `no` / `unreachable` / keeps dropping | it is off or asleep: wake it; `fleet ssh NODE fleet status` must say `awake on`; a MacBook: `FLEET_KEEP_AWAKE_LID=1`. |
| PROXY `login` / TOOLS `1 login: cliproxy` | user runs `fleet proxy login NODE` on the master (browser needed). |
| TOOLS `1 login: codex` (or cursor, grok) | user runs `fleet ssh NODE fleet login codex`, or sets the API key secret and runs `fleet reconcile`. |
| `claude setup-token` not run (no terminal) | user runs `claude setup-token \| fleet secrets set CLAUDE_CODE_OAUTH_TOKEN --profile minimal` themselves, then `fleet reconcile`. |
| `AWS SSO session expired` / `fleet list` AWS `expired` | user runs `aws sso login` (or `fleet aws login`) on the master in their own terminal, then `fleet aws push`. |

Full reference: `fleet --help`, the README (Command reference, Config
reference) and `fleet COMMAND --help`.
