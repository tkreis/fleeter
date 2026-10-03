# docker/ — fleet nodes in containers

Throwaway fleet nodes: one image, one invite per container, PID 1 supervisor
that runs `fleet daemon` and logs the device out of the tailnet when the
container stops (ephemeral nodes vanish). Also the integration test bed for
the whole master ↔ node flow (`tests/e2e.sh`, no real Tailscale or GitHub).

```
Dockerfile      debian:bookworm-slim + tailscale (official apt repo) + openssh-server
                + git + python3 + curl + chromium (+ fonts) + /opt/fleet (the fleeter code; your config repo arrives with the first provision).
                User `fleet` (uid 1000), no sudo, no password. Nothing secret, no host
                keys, no tailscale state.
entrypoint.sh   PID 1: tailscaled (userspace) → sshd (key auth only) → `fleet join` as
                `fleet` → supervisor running `fleet daemon` as `fleet`
compose.yml     real mode, one container (see "one invite = one container")
spawn.sh        master-side: N ephemeral containers, one `fleet invite` each
```

## Master setup (once)

`fleet init master` on the master needs exactly two approvals from you: one
short-lived Tailscale API access token (the Keys page opens; 1-day expiry is
enough; fleet uses it to apply the policy and create its own scoped OAuth
client, then revokes it) and one `gh auth login --web` browser approval.

## Build

```sh
docker build -f docker/Dockerfile -t fleet-node:local .                        # ~1 min
docker build -f docker/Dockerfile --build-arg FLEET_PREINSTALL=1 -t fleet-node:pre .   # + base, devtools, chrome MCP servers, claude, codex, cursor, grok
```

The image contains `chromium` and fonts by default (apt needs root, and the
node user has none); a fleet without `chrome` in `FLEET_TOOLS` builds a slimmer
image with `--build-arg FLEET_BROWSER=0`. `netcat-openbsd` is always included:
`fleet doctor` probes isolation with `nc`. `FLEET_PREINSTALL=1` additionally
runs the `lib/tools/*.sh` installers at build time so a container is useful
seconds after it joins. Default off: `fleet apply` installs the harness CLIs on
first provision instead. Build args: `FLEET_USER` (default `fleet`), `FLEET_UID`
(1000), `FLEET_BROWSER` (1), `FLEET_PREINSTALL` (0).

## Real mode

On the master (after `fleet init master`, `fleet secrets set …`):

```sh
docker/spawn.sh 3                              # 3 ephemeral nodes fleet-dock-<rand>, minimal profile
docker/spawn.sh 1 --profile full -- -e FLEET_TOOLS="base devtools claude"
fleet reconcile                                # or wait for the 2-min timer
fleet nodes --live
fleet kick fleet-dock-ab12cd                   # container exits by itself; then docker rm it
```

`spawn.sh` mints `fleet invite --ephemeral --name fleet-dock-<rand> --code-only`
per container and hands the code over as a **bind-mounted 0600 file**
(`-v <tmp>:/run/fleet-invite:ro -e FLEET_INVITE_FILE=/run/fleet-invite`): never
in argv, never in the container environment, so `docker inspect` does not show
it. The host file is truncated and deleted as soon as the container has joined
(`enrol.json` present) or after 60 s — truncated first because the bind-mounted
inode would otherwise stay readable inside the container after the host name
is gone. Inside, the entrypoint copies the root-owned mount to a user-readable
0600 tmpfs file for the duration of `fleet join` only (and truncates the mount
itself when it is writable). Container name = node name.

Single container with compose: `(umask 077; fleet invite --ephemeral --code-only
> docker/invite)`, then `docker compose -f docker/compose.yml up -d --build` and
delete `docker/invite` (git-ignored) once the node has joined. The file is a
compose *secret* mounted at `/run/secrets/fleet-invite`, not an environment
variable.
**One invite = one container**: the key is single use and the nonce is consumed
by the first node the master enrols, so `--scale node=N` cannot work; use
`spawn.sh`. A reusable key is deliberately not supported (no per-node
revocation).

Container environment:

| Variable | Meaning |
|---|---|
| `FLEET_INVITE_FILE` | path of a file with the invite code (bind mount / compose secret); preferred, not visible in `docker inspect` |
| `FLEET_INVITE_CODE` | the code itself (convenience; **is** visible in `docker inspect` until the container is removed). One of the two is required; both are removed from the environment before the daemon starts |
| `TS_STATE_DIR` | tailscaled state (default `/var/lib/tailscale`, inside the container) |
| `FLEET_LOCAL_CONF` | content for `~/.config/fleet/fleet.conf` (local overrides) |
| `FLEET_TOOLS` | shortcut: appended to that file as `FLEET_TOOLS="…"` |
| `FLEET_FAKE_TAILSCALE=1` | test mode: no tailscaled; a fake `tailscale` on PATH answers |

What the entrypoint does, in order: write the local conf → `tailscaled
--tun=userspace-networking --state=$TS_STATE_DIR/tailscaled.state` and
`tailscale set --operator=fleet` (so the sudo-less user can run `tailscale
up/logout`) → `ssh-keygen -A` if host keys are missing, `sshd` on 22
(`PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers fleet`) →
`fleet join` as `fleet` (reads the key from the invite, `tailscale up
--advertise-tags=tag:fleet-node --hostname=fleet-<name>`, installs the master's
pubkey, generates the deploy keys, writes `enrol.json`) → `exec` into the
supervisor. The supervisor forwards TERM/INT to `fleet daemon`, reaps children,
and on exit waits for a still-running remote `fleet leave` session, then runs
`tailscale logout` and stops sshd/tailscaled. `fleet leave` (what `fleet kick`
runs over ssh) stops the daemon itself through `~/.config/fleet/daemon.pid`
(TERM, wait, KILL); the supervisor additionally treats a vanished `daemon.pid`
while the daemon still runs as "stop" (belt and braces). `docker stop`
therefore = `fleet leave` + logout; exit code 0.

Browser MCP servers (`lib/tools/chrome.sh`): in containers the browser is the
Debian `chromium` package, which apt can only install as root, so it is always
baked into the image; the wrappers `~/.local/bin/fleet-chrome-mcp` and
`fleet-playwright-mcp` run it headless with `--no-sandbox` there. The npm MCP
servers themselves are installed by `fleet apply` (or `FLEET_PREINSTALL=1`).

Nothing here needs `NET_ADMIN` or `/dev/net/tun`. Harness logins work as on any
node: the master pushes `CLAUDE_CODE_OAUTH_TOKEN` etc. with the secret profile;
Codex/Grok device-code logins need `docker exec -it -u fleet <c> fleet login codex`.
Containers never run CLIProxyAPI themselves: with `cliproxy` in `FLEET_TOOLS`
they behave as `FLEET_PROXY_MODE=remote` and export `FLEET_PROXY_URL` (set it
to a proxy they can reach, e.g. through `FLEET_LOCAL_CONF`); without `cliproxy`
no `ANTHROPIC_*` variables are exported and Claude Code uses the token natively.

Code updates inside a container: the daemon starts from `/opt/fleet` (the
image), dispatches every job through `~/.local/bin/fleet` (the checkout that
`fleet pull` keeps at `origin/main`) and re-executes itself from there after a
pull moved the checkout, keeping its PID. Rebuild the image for base-system
changes only.

## End-to-end test (fake network)

```sh
bash tests/e2e.sh              # ~1 min after the first image build; PASS/FAIL per step, exit 1 on any FAIL
E2E_FULL=1 bash tests/e2e.sh   # FLEET_PREINSTALL=1 image + real tool installs (slow, needs internet)
E2E_KEEP=1 bash tests/e2e.sh   # keep fleet-e2e-* containers/network/volume for inspection
```

Needs Docker and python3 on the host. Everything it creates is prefixed
`fleet-e2e-` (containers `fleet-e2e-master`, `fleet-e2e-node-a/b`, network
`fleet-e2e-net`, volume `fleet-e2e-repos`, image `fleet-e2e-node:local`) and is
removed by a trap; nothing is written on the host outside `tests/.e2e-work`.
No real Tailscale or GitHub call is made:

- `fleet-e2e-master`: same image, `sleep infinity`; fleet runs as `fleet` with
  `FLEET_TS_API`/`FLEET_GH_API` pointed at `tests/e2e/fake_api.py` (inside the
  container, 127.0.0.1:8899) and `FLEET_TS_STATUS_JSON` generated from the node
  containers' names/IPs (container names double as tailnet DNS names).
- nodes: `FLEET_FAKE_TAILSCALE=1`, `tests/e2e/fake-tailscale.sh` mounted at
  `/usr/local/bin/tailscale`, real sshd, real `fleet join`/`daemon`, `FLEET_TOOLS=""`
  (no harness installs) via `FLEET_LOCAL_CONF`; the invite arrives as a
  bind-mounted file (`FLEET_INVITE_FILE`) like `spawn.sh` does, and the test
  asserts it is absent from `docker inspect`.
- `fleet-e2e-repos`: bare `memory.git` (seeded from `templates/memory`), `code.git`
  (the fleeter tree in the image) and `config.git` (seeded from
  `examples/fleet-config`), used through `FLEET_MEMORY_REMOTE`/`FLEET_CODE_REMOTE`/
  `FLEET_CONFIG_REMOTE`; the master's config dir is a clone of `config.git`.

Flow asserted: image hygiene (no sudo, no host keys, no state) → `fleet init
master` non-interactive → secrets (minimal + full) → `invite --code-only` ×2
(alpha full, beta ephemeral/minimal) → both nodes join → `reconcile` enrols +
provisions both (registry `provisioned`, deploy keys read-only/read-write at the
fake GitHub, second reconcile silent) → node files (`secrets.env` 0600 with the
token, profile split, `env.sh`, `~/.claude/CLAUDE.md`, `~/.agents/skills`,
`~/.codex/*`, `~/.local/bin/fleet`, rc block, `status --json`) → memory: alpha
writes + syncs, beta syncs and reads it, and back → trust model: master has no
sshd/no authorized_keys, beta cannot ssh/curl the master or alpha, master can
ssh beta, root login refused → `kick alpha --yes` while a provision is running
(lock released, provision killed, registry revoked, fake API saw device DELETE +
2 key DELETEs, daemon stopped, container exited 0, tailscale logout) → reconcile
skips alpha → beta `fleet pull` converts code and config into git checkouts,
`fleet config publish` on the master is picked up by the next pull → `docker
stop` beta exits 0 with logout.
