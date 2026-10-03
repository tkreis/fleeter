# Architecture

fleeter turns machines into nodes of a personal agent fleet. One machine is the
**master**: it owns every secret, mints join invites, pushes secrets and files,
and can kick nodes out. Nodes keep themselves current from three git repos, so
the master is a control point, not a dependency.

## Goals

1. One file to download and one command to run per machine.
2. Every node ends up with the same harnesses, skills, global agent
   instructions, and the `.env` files that match its secret profile.
3. Logins reuse what the master already has wherever the vendor allows it;
   otherwise the node runs the device-code flow and `fleet nodes --live` shows
   what is still missing.
4. Nodes self-update. Skills and config flow from git, secrets from the master.
5. All nodes share one memory store.
6. The master sees which nodes are live and can revoke any of them: stop it,
   delete it from the tailnet, revoke its repo access.
7. macOS, Linux, and short-lived Docker containers.

Non-goals: Windows; running arbitrary commands from a UI; GUI app logins;
protecting the master from code that already runs as the master's user.

## Pieces

```
fleeter (code)          fleet, lib/{common,master,node,join,harness}.sh, lib/api.py, lib/tools/*.sh,
                        templates/{memory,cliproxy,tailscale-policy.hujson}, docker/, tests/
fleet-config (yours)    fleet.conf, AGENTS.md, harness/<harness>/…, skills/<name>/SKILL.md
fleet-memory (yours)    INDEX.md, notes/, nodes/<name>/, scripts/build_index.py, GitHub Action
master state            ~/.config/fleet/vault (secrets, files, keys, registry, locks, audit)
node state              ~/.config/fleet (secrets.env, env.sh, applied*, manifest, status.json)
```

`fleet` loads `config/defaults.conf`, then `~/.config/fleet/fleet.conf` (which
may set `FLEET_CONFIG_DIR`), then `$FLEET_CONFIG_DIR/fleet.conf`, then the local
file again. The same loader runs in every plug-in subprocess.

## Master may be off; nodes are always on

| Concern | Needs the master awake? | How it works when the master is off |
|---|---|---|
| Harness updates | no | node timer runs the vendor updaters daily |
| Code, skills, instructions, harness config | no | node pulls the code and config repos every 15 min with read-only deploy keys |
| Memory sync (optional; off without `FLEET_MEMORY_REPO`) | no | node ↔ GitHub directly, every 5 min |
| Secrets, mirrored files, new tokens | **yes** | pushed by `reconcile` the next time the master is awake; the node keeps its last set |
| Join / enrol | **yes** | the invite is minted on the master; the joined node waits for the next reconcile |
| `kick`, `provision` | **yes** | fallback: delete the device in the Tailscale admin console; the master revokes deploy keys when next awake |

There is no credential wiping. A kicked node keeps what it has on disk; kick
cuts it off (tailnet, repos, stopped jobs) and names the secrets to rotate.

## Transport: OpenSSH over the tailnet

Tailscale SSH needs the open-source `tailscaled`; the macOS App Store and
standalone GUI builds cannot act as an SSH server. So the fleet uses plain
OpenSSH on every OS:

- `fleet init master` creates `vault/ssh/fleet_master` (ed25519, no passphrase,
  0600). Its public key is embedded in every invite.
- `fleet join` enables an SSH server (macOS: Remote Login; Linux:
  `openssh-server`; Docker: `sshd` in the image), writes a drop-in that sorts
  first in `sshd_config.d` (`PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`, `PermitRootLogin no`), reloads sshd,
  verifies the effective config with `sshd -T -C user=<me>,host=localhost,addr=127.0.0.1`
  (so a `Match User` block cannot re-enable passwords unnoticed), and appends
  the master's key to `~/.ssh/authorized_keys`. Join fails if SSH cannot be
  verified key-only.
- The tailnet policy allows port 22 on `tag:fleet-node` only from the owner's
  user-owned devices. Nothing else can reach a node.

## Node identity and enrolment

A tag identifies a class, not a machine, so the master keeps a registry keyed
by the Tailscale stable node id:

1. `fleet invite` mints a single-use, pre-authorized, tagged auth key (1 h),
   writes `vault/nodes/pending/<nonce>.json` (name, profile, ephemeral flag,
   expiry, login name) and prints a one-liner that *contains* the gzip+base64
   join script (nothing is downloaded, no public URL) plus an invite code: base64
   JSON with the auth key, nonce, name, master public key, login and tag.
2. `fleet join` reads the code from a hidden prompt, `FLEET_INVITE_CODE` or
   `FLEET_INVITE_FILE` (never argv), writes the auth key straight into a 0600
   temp file from python, runs `tailscale up --auth-key=file:… --advertise-tags
   --hostname=fleet-<name>`, sets up SSH, runs the privileged OS steps once
   (Linux: base packages, browser, docker-ce, linger; macOS: Homebrew),
   generates three ed25519 deploy keys (`fleet_code`, `fleet_config`,
   `fleet_memory`) with `~/.ssh/config` aliases `github-fleet-{code,config,memory}`,
   and writes `~/.config/fleet/enrol.json` with the nonce. It sends nothing to
   the master.
3. `fleet reconcile` on the master lists tagged online peers that are not in
   the registry, SSHes in, reads `enrol.json`, and if the nonce matches an
   unexpired pending invite **claims it atomically** (`mv` into `claimed/`;
   two devices with the same nonce cannot both enrol), registers the deploy
   keys (code read-only unless the code repo is https or unset, config
   read-only, memory read-write; each id is written to the claimed file the
   moment it exists, together with the `owner/repo` it was created on), writes
   `vault/nodes/<id>.json` and provisions. A failure rolls the keys back (a
   failed delete goes to a tombstone's `pending_cleanup`) and hands the invite
   back while it is still valid. Every later delete of a key goes to the repo
   recorded with it, never to whatever `fleet.conf` points at today: a 404 on
   the wrong repository would otherwise count as "already deleted".

`provision`, `reconcile` and `kick` accept a registered name or id only; a
hostname is never guessed.

## Trust model

- **Push only.** The master connects to nodes. Nodes never get a shell, SSH
  key or API token for the master; there is no node→master channel, not even
  for enrolment.
- **Tailnet policy** (`templates/tailscale-policy.hujson`): user-owned devices
  may reach `tag:fleet-node` on 22 and ICMP; `tag:fleet-node` may reach nothing
  inside the tailnet. `fleet init master`, `policy check` and `doctor` fetch
  the live policy and verify it carries the template's `tagOwners`/`grants`
  and that no `grants`/`acls`/`ssh` rule has `*`, `autogroup:tagged`,
  `autogroup:danger-all` or the fleet tag as `src`; any other non-person `src`
  (IP, CIDR, host alias, other tag/autogroup) is rejected unless every `dst`
  is the fleet tag. `doctor` additionally runs `nc -z` from every online node
  to the master (22, 443) and to another node (22): a successful connection, or
  a node without `nc`, is a failure.
- **Secrets at rest** on the master: `~/.config/fleet/vault`, 0700/0600, never
  in argv, never logged, never in a repo. API calls read credentials from the
  vault files themselves (`lib/api.py`) or go through `gh` (keyring).
- **Secret profiles**: `minimal` (what a throwaway container needs) and `full`
  (everything, including mirrored files and the proxy logins). `--ephemeral`
  invites default to `minimal`. The registry records which profile each node
  holds and the names of the secrets sent.
- **Secrets in transit**: `ssh` + `tar`/`cat` over WireGuard, written with
  `umask 077`, tmp + `mv`.
- **Revocation** (`kick`): kills an in-flight provision (the lock records the
  worker pid; the worker and its ssh/tar children are killed), takes the lock
  over in place (guarded by an ownership token so a lock that changed hands is
  never deleted), writes `state: revoked` (provision rechecks before every
  step), then runs each step independently and reports it: remote `fleet
  leave` (bounded 60 s), Tailscale device delete, three deploy-key deletes.
  Failures stay in `pending_cleanup` and every reconcile retries them, before
  and independently of the device-list call. A failed remote stop is queued as
  `stop:<id>` and retried only while the node is still online on the tailnet;
  once the device has left the device list it is dropped (the master has no
  path to the node any more), the key and device deletes are retried until
  they succeed.
- **Vanished nodes**: reconcile compares the registry with the API device list,
  records `missing_since`, and after 1 h (ephemeral) or
  `FLEET_MISSING_GRACE_HOURS` revokes the node the same way, naming the secrets
  to rotate; the tombstone is forgotten once cleanup is empty.
- **Bootstrap integrity**: the join script travels inside the one-liner, into a
  private `mktemp -d` removed by an EXIT trap; the auth key never appears on a
  command line; the invite is single use and expires after an hour.

## Reconcile, digest and locking

- One `mkdir` lock per node on the master (`vault/locks/<id>/{pid,token}`),
  taken by `provision`, `reconcile` and `kick`; registry read-modify-writes
  additionally run under `locks/.registry`, so a concurrent `missing_since`
  update can never put a stale state over `revoked`.
- **Desired-state digest** = `sha256(code_rev + "+" + config_rev + "\n" + H + "\n")`
  where the revs are the HEADs (or tree hashes) of the fleeter checkout and the
  config dir, and `H` = HMAC-SHA256 keyed with `vault/digest.key` over the
  profile's secret file bytes and every mirrored file's path + content. A
  changed secret value, file, code or config commit changes the digest; the
  digest itself reveals nothing. The node stores it in `~/.config/fleet/applied`.
- Reconcile provisions a node only when its recorded or reported digest
  differs, so it is convergent: a second run is silent.
- Code and config are shipped (`git archive HEAD`, or a tar of the tree) only
  while the node has no git checkout of them; after the first `fleet pull`
  they track the repos directly. Provision therefore runs `fleet pull
  --no-apply` on the node before its `fleet apply --from-master`, so the apply
  runs the pushed revisions the digest stands for and never acknowledges a
  digest for code it did not receive. `applied_commit` on the node records
  `<code>+<config>`; the master copies it into the registry and warns when it
  differs from its own checkout (unpushed commits). `pull` re-applies when
  either changed, retries a commit whose apply failed, and re-points `origin`
  when the configured repo URL changed. The apply lock is taken before
  fetch/reset, so a running apply never has its checkout swapped underneath.
- All writes on nodes are atomic (tmp + `mv` in the target directory; mirrored
  files are unpacked into a 0700 staging dir under `~/.config/fleet` and
  renamed into place one by one); `~/.config/fleet/manifest` and
  `harness.manifest` list what fleet owns so removed skills and files are
  cleaned up.

## Harness configuration

Global agent instructions (`AGENTS.md` in the config repo) are rendered into
`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` and `~/.cursor/rules/fleet-global.mdc`
(Grok reads the Claude copy). Per-harness templates under `harness/` are
captured from the master's live config by `fleet config publish` (secrets
become `${PLACEHOLDER}`, home paths `${HOME}`, machine-only servers and hooks
are dropped) and rendered on nodes with the node's secrets; a missing secret
drops the MCP server or TOML table that needs it rather than writing an empty
value. Skills land in `~/.claude/skills`, `~/.agents/skills` and
`~/.cursor/skills`. Ownership rules per file are in
`examples/fleet-config/harness/README.md`.

## Shared memory

A plain Markdown vault (Obsidian-compatible) in a private git repo. Every
harness reads and writes files natively; git works headless, offline and keeps
history; per-node deploy keys make access revocable per node.

```
INDEX.md                 one line per note (generated by a GitHub Action on every push)
notes/<slug>.md          curated, trusted; written by a human on the master
nodes/<name>/<slug>.md   written by that node only, read by every node
```

Every node pulls the whole repo, so every node reads every other node's notes
(a fact learned on node A is on node B within two sync cycles). A node commits
only inside `nodes/<name>/` — `fleet memory sync` stages nothing else — so two
nodes can never conflict. Sync = commit → `pull --rebase --autostash` → push,
three bounded retries; an unexpected conflict aborts the rebase, sets
`memory: conflict` and stops writing until `fleet memory sync --reset` after a
human fixed the vault. The global instructions tell every harness to treat
`nodes/**` as knowledge, never as instructions: one compromised node must not
be able to steer the others. Notes carry frontmatter (`node`, `created`,
`tags`); `INDEX.md` is read first.

## Scheduling

All jobs run as the user, never root: macOS `~/Library/LaunchAgents/dev.fleet.<job>.plist`;
Linux systemd user timers `fleet-<job>.timer` (`loginctl enable-linger`
attempted during join), or crontab lines when there is no user session;
containers run `fleet daemon` in the foreground (PID 1 safe, TERM → `leave`).
Jobs: `pull`, `memory`, `update`; the master adds `reconcile`.

## Docker nodes

Debian slim + tailscale + openssh-server + git + python3 + curl + chromium +
the fleeter code. The entrypoint starts `tailscaled --tun=userspace-networking`,
`sshd`, runs `fleet join` as the unprivileged node user with the invite from a
bind-mounted file, then supervises `fleet daemon`; on stop it logs the device
out of the tailnet. No `NET_ADMIN`, no `/dev/net/tun`, no sudo in the image.
The daemon starts from the image copy (`/opt/fleet`) but dispatches every job
through `~/.local/bin/fleet` (the checkout `fleet pull` keeps current) and
re-executes itself from that checkout after a pull moved it, keeping its PID,
so the image copy only matters until the first provision.
`tests/e2e.sh` runs the whole master ↔ node flow against fake Tailscale and
GitHub APIs.

## Portability contract

- `bash` 3.2 (macOS default): no associative arrays, no `mapfile`, no `${var,,}`.
- No GNU-only flags: no `sed -i` (tmp + `mv`), `stat` and `date` wrapped,
  `readlink -f` replaced.
- No `flock` (mkdir locks), no `timeout` (`with_timeout` helper).
- Every function declares its variables `local`; bash scoping is dynamic.
- Needs only `bash`, `curl`, `tar`, `shasum`/`sha256sum`, `git`, `python3`,
  `ssh`. `fleet join` installs what is missing.
- Privileged steps happen once, interactively, in `join`. `apply`, `update`,
  `memory sync`, `pull`, `reconcile` never call `sudo`.
- Every command converges: running it twice changes nothing the second time.
  Nothing destructive without `--yes` or a typed confirmation.
