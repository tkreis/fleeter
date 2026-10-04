# Security

## Threat model

Assets: the API tokens and `.env` files in the master's vault, the shared
memory vault, access to your tailnet and GitHub repos, and the master itself
(your laptop, with your real accounts).

Adversaries considered:

- **A compromised or stolen node.** An agent on a node runs untrusted code
  and reads untrusted content all day; assume a node can be fully compromised.
- **Someone who finds an invite or a leftover container.**
- **A network observer** between master, nodes and GitHub.
- **A prompt-injection return path** through the shared memory vault.

Not considered: a process already running as your user on the master (it can
run `fleet` itself, and read the vault key the way `fleet` does), a
compromised GitHub account, or a compromised Tailscale account. A copy of the
master's disk (backup, stolen machine without FileVault, a synced
`~/.config`) is considered: the vault is encrypted at rest and the key is not
on it (keychain / secret service), see "Vault encryption at rest".

## What is protected, and how

| Property | Mechanism |
|---|---|
| A node cannot reach the master or another node | Tailnet policy: no grant with `tag:fleet-node` (or anything covering it) as `src`; checked by `fleet init master`, `policy check`, `doctor`; `doctor` probes with `nc` from the nodes themselves. The master runs no sshd for nodes and no listener on the tailnet. |
| A node cannot impersonate the master or enrol by itself | Push only over OpenSSH with the master's key; enrolment needs a nonce from a single-use invite, matched by the master, claimed atomically. Tagged peers without a matching nonce are listed as `unknown` and never provisioned. |
| A node cannot read other secrets than its profile's | Profiles `minimal`/`full`; the master pushes only the profile's env file and files; the registry records what each node got. |
| A node cannot write to code or config | Read-only deploy keys per repo per node; `fleet pull` only fetches. |
| A node cannot rewrite the shared memory | Read-write key, but `fleet memory sync` stages only `nodes/<name>/`; git history keeps everything; instructions tell harnesses to treat `nodes/**` as data. A node that writes elsewhere by hand is caught in review, and its key can be revoked alone. |
| Secrets never appear in argv or logs | Hidden prompts / stdin for input; API credentials read from vault files by `lib/api.py`; `docker login --password-stdin`; MCP configs edited in place; audit log records names and outcomes only. Exception: `launchctl setenv` on macOS (see limits). |
| Secrets at rest | Master: every secret-bearing vault file is an age ciphertext (`*.age`) to one X25519 recipient; the private key lives in the login keychain / secret-tool / a 0600 file outside the vault and reaches `age` only through a pipe ("Vault encryption at rest"). The desired-state digest is a sha256 over the ciphertexts, so it reveals nothing and needs no key. Nodes: `secrets.env` and mirrored files 0600, plaintext (the harnesses need them; see "Node side" below). |
| Secrets in transit | SSH over WireGuard; written with `umask 077`, tmp + `mv` (mirrored files via a 0700 staging dir under `~/.config/fleet`, renamed into place one by one). |
| Invite material | The auth key is inside the invite code, read from a hidden prompt or a 0600 file, written to a 0600 temp file and deleted after `tailscale up`; single use, 1 h expiry, revoked when expired. Docker: bind-mounted file, truncated on both sides after join; never in `docker inspect`. |
| Revocation is complete and retried | `kick` and the vanished-node path delete the Tailscale device and all three deploy keys, each on the repository recorded when it was created (a changed `FLEET_*_REPO` cannot turn a 404 on the wrong repo into "deleted"); failures live in `pending_cleanup` and every reconcile retries them, independent of other API calls. A failed remote stop is retried while the node is still on the tailnet and dropped once the device is gone. Enrolment rollbacks use the same mechanism, so no key is ever lost. |
| A kicked node cannot be re-provisioned by a race | `revoked` is written under the node lock before any cleanup; provision rechecks it before every step; registry writes are serialised by a registry-wide lock; a running provision worker and its ssh/tar children are killed. |
| Published config contains no secrets | `harness_capture` replaces secret values with placeholders; `fleet config publish` runs a regex secret scan (tokens, keys, JWTs, private keys, long token-like values, home paths) over `harness/` and `skills/` on every run, with or without `--no-capture`; any hit aborts before anything is committed. |
| Node SSH accepts keys only | Drop-in sorted first in `sshd_config.d`, reload required, effective config verified with `sshd -T -C` for the master's login; join fails otherwise. |
| Node host keys are pinned | `vault/ssh/known_hosts` (0600) holds each node's ed25519 host key, read with `cat /etc/ssh/ssh_host_ed25519_key.pub` over the authenticated fleet session at enrolment (never `ssh-keyscan`); every later ssh — fleet's own and T3 Code's — runs with `StrictHostKeyChecking yes`, `HostKeyAlgorithms ssh-ed25519` and that file. A key that differs from the pin is refused and reported (`HOST KEY MISMATCH`), never replaced automatically. |
| T3 Code reaches a node with a key that can do nothing else | See "T3 Code remote access" below. |

## Vault encryption at rest

What is encrypted, where (`lib/vault.sh`):

| Item | At rest |
|---|---|
| `vault/secrets/minimal.env`, `full.env` | `secrets/<profile>.env.age` |
| every mirrored file (`fleet files add`), the CLIProxyAPI config + logins (`fleet proxy import`) | `files/<profile>/<path>.age` |
| the Tailscale OAuth client, the GitHub fallback token | `tailscale.json.age`, `github.json.age` |
| `vault/recipient.txt` | plain, 0644: the public recipient and the name of the key backend. Writers (`secrets set`, `files add`, `proxy import`, `lib/api.py` minting the OAuth client) need only this. |
| `vault/ssh/fleet_master`, `ssh/t3_client`, `ssh/known_hosts` | plain, 0600: OpenSSH reads them itself. The master key is the credential for every node; it is protected by the 0700 vault and the disk encryption you run, not by age. |
| registry (`nodes/*.json`), `audit.log`, `sync.json`, policy backups | plain: names, ids, dates, key ids; no credentials. |

The private identity (one `AGE-SECRET-KEY-1…` line) lives in a **key backend**
chosen by `FLEET_VAULT_KEY_BACKEND`:

- `keychain` (default on macOS): a generic password in the login keychain,
  service `fleet-vault`, account `$USER`. Stored by feeding
  `add-generic-password -U -s fleet-vault -a $USER -w <identity>` to
  `security -i` on **stdin** (the identity is never an argument), read with
  `security find-generic-password -s fleet-vault -a $USER -w` (stdout). The
  `security` binary is the ACL's trusted application, so no dialog appears.
- `secret-tool` (default on Linux when installed): `secret-tool store
  --label=fleet-vault service fleet-vault account $USER` with the identity on
  stdin; `secret-tool lookup …` to read.
- `file` (fallback, CI, containers): `~/.config/fleet/vault.key`, 0600,
  outside `vault/`. Loudly warned about at creation: anything that can read
  your home directory can decrypt the vault; it still protects against a copy
  of `vault/` alone and keeps the code path identical.

How the identity reaches `age`: `vault_identity` fetches it from the backend
into a shell variable once per process (never exported), and every decryption
is `printf '%s\n' "$id" | age -d -i - FILE.age` — the identity on age's
stdin, the ciphertext as the file, the plaintext on stdout. No temp file, no
FIFO, no argv (verified by `tests/master_test.sh` with a fake `security` that
records argv and stdin separately). `lib/api.py` reads `tailscale.json` and
`github.json` through the same `vault_cat` in a subprocess and keeps the bytes
in memory. Provision decrypts the env into a variable and pipes it into the
node's ssh session; the mirrored files become a tar built in memory (python
`tarfile` over `BytesIO`, each item decrypted by `age` with the identity on a
pipe) that goes straight into ssh. Nothing decrypted is written under
`$FLEET_HOME` or `$TMPDIR` (the test snapshots both for a canary during a
provision, and the e2e greps the master container's whole filesystem).

Locked keychain: on macOS the login keychain is unlocked while you are logged
in; a scheduled `fleet sync`/`reconcile` running from launchd with nobody
logged in cannot read the key. Then `provision_node` skips the node with one
clear warning (`audit: provision <name> skip vault-locked`) before anything is
shipped, and the next run retries; `fleet secrets set`, `secrets list`,
`vault rotate-key` die with the unlock hint; `fleet vault status` and
`doctor` report `key: UNREACHABLE`. A decryption failure can never ship an
empty `secrets.env`: the env is decrypted into memory first and the ssh runs
only on success.

Digest: `sha256(code_rev+config_rev, then path + sha256(ciphertext) per item)`.
Reconcile and `fleet list` can therefore tell `behind` with the key
unreachable. age uses a fresh file key per encryption, so `secrets set` with
an unchanged value, or a key rotation, changes the digest once and
re-provisions the nodes once; harmless. A vault that still holds plaintext
items (before `fleet vault encrypt`) fingerprints those with the legacy HMAC
keyed by `digest.key`, so the digest never covers plaintext bytes directly.

Rotation (`fleet vault rotate-key`): new identity → stored as `fleet-vault-next`
→ every `.age` re-encrypted into `<file>.rotating` and compared against the old
plaintext → files swapped, recipient rewritten → new identity stored as
`fleet-vault`, `-next` removed. While `-next` exists `vault_identity` offers
both keys, so a crash at any step leaves a decryptable vault and a rerun
finishes.

Node side: a node keeps `~/.config/fleet/secrets.env` and the mirrored files
in plaintext (0600) because the harnesses source them; encrypt the node's disk
(FileVault on Macs, LUKS on Linux) and treat a lost node as "rotate
everything" (see below). The master's own disk should stay FileVault/LUKS
encrypted as well: age protects the vault copy, not the SSH keys or the
registry.

`fleet vault export FILE` writes the whole vault **decrypted** into one
`age -p` archive (passphrase typed at the terminal), without `recipient.txt`,
so a restore on another machine gets a fresh key from `fleet vault encrypt`.
Store it offline.

## T3 Code remote access

`fleet t3 setup` lets the T3 Code desktop app on the master use a node's T3
server through T3's own SSH environment type (verified against pingdotgg/t3code
0.0.45, `packages/ssh/src/tunnel.ts` and `command.ts`). It is opt-in: nothing
below exists until `fleet t3 setup` runs, or `FLEET_T3_REMOTE=1` makes
`fleet init master` prepare the key up front. What T3 needs from the
node's sshd is small and fixed: remote commands without a pty (`ssh <alias>
sh -l -s -- <key>` and `sh -s`, each with a script on stdin), and one local
forward to the server on the node's loopback (`ssh -n -N -L
<local>:127.0.0.1:<port> <alias>`). fleet grants exactly that:

- **Dedicated key.** `vault/ssh/t3_client` (ed25519, 0600) is generated by
  `fleet init master` / `fleet t3 setup`; the fleet master key is never handed
  to the app. The node's `authorized_keys` line is
  `restrict,port-forwarding,permitopen="127.0.0.1:*",from="100.64.0.0/10,fd7a:115c:a1e0::/48" ssh-ed25519 … fleet-t3-client`:
  `restrict` switches off pty allocation, agent and X11 forwarding and
  `~/.ssh/rc`; `port-forwarding` re-enables forwarding; `permitopen` limits
  `-L` destinations to the node's own loopback; `from` accepts the key only
  from Tailscale's address ranges. Verified live: a pty request fails
  (`PTY allocation request failed`), `-A`/`-X` leave no `SSH_AUTH_SOCK`/`DISPLAY`,
  `-L …:example.com:80` is `administratively prohibited`, `-L …:127.0.0.1:<port>`
  and `sh -l -s` work.
- **What the key still allows, by necessity.** T3 pipes an arbitrary shell
  script into `sh -s`, so the key runs commands as the node user (without a
  terminal). A `command=` wrapper could not add anything: the script arrives on
  stdin. Treat the key like the master key in one respect — it is a credential
  for the node — but it cannot reach the master, the tailnet, or other nodes
  (the tailnet policy still governs the node), it cannot open an interactive
  session, and it is useless from outside the tailnet.
- **What the node exposes.** Only to the master, only through that tunnel: the
  T3 server on `127.0.0.1` (the desktop app's own server when it is running, or
  one T3 starts with `T3CODE_NO_BROWSER=1 t3 serve --host 127.0.0.1`). No
  port is opened on the tailnet and no tailnet policy change is needed. The
  server's own auth stays in force over the tunnel: API routes answer 401 until
  a pairing token (created by `t3 auth pairing create --json` over the same
  ssh, single use, short TTL) is exchanged at `POST /oauth/token` for a scoped
  30-day bearer session; the static web app is served without auth.
- **Trust on first use, once, over WireGuard.** The very first ssh to a new node
  (reading `enrol.json`) runs with `StrictHostKeyChecking accept-new` inside
  the tailnet; fleet immediately reads the host key from inside that session
  and pins it, refusing to pin if the two disagree. From then on every
  connection, including T3's, is strict. The window is the WireGuard-encrypted
  first contact with a device that just joined with your single-use invite.
- **Revocation.** `fleet t3 revoke NODE` (and `fleet kick`) revokes on the node
  every session whose subject is `one-time-token` (what the SSH flow and `t3
  auth pairing create` produce; the node's own desktop app session, subject
  `desktop-bootstrap`, stays), every live pairing token, stops the managed
  servers recorded under `~/.t3/ssh-launch/`, removes the `fleet-t3-client`
  line and the `Host fleet-<name>` block, and records `t3_access: false` so
  provision keeps the key off until `fleet t3 setup NODE`. Verified live: the
  bearer token that read `/api/orchestration/shell` with 200 gets 401 after the
  revoke; the key gets `Permission denied (publickey)`. A node that is offline
  gets `t3:<id>` in `pending_cleanup`, retried while it is on the tailnet.
- **Secrets.** fleet never prints, stores or passes a T3 token: pairing tokens
  are created and consumed by T3 itself; `t3 auth session list --json` and
  `pairing list --json` contain no credentials by design, and `status` prints
  labels, subjects and dates only. The one T3 secret that touches argv is a
  session or pairing *id* (`t3 auth session revoke <id>`), which is not a
  credential. The master's own T3 Code data is never read or written; the
  environment entry in the app is added and removed by hand.

## Known limits

- **No credential wiping.** A kicked or vanished node keeps its secrets, files
  and clones. Treat everything it held as exposed and rotate (see below).
- **LAN and Docker-bridge traffic is not governed by the tailnet policy.** The
  master listens on loopback only, so this matters only if you add services.
- **The master is not protected from local processes** running as your user:
  they can read the vault key the way `fleet` does (unlocked keychain, your
  secret service, or `vault.key`). Optional hardening: run `fleet` under a
  separate OS user; keep the disk encrypted (FileVault/LUKS) so the SSH keys
  and the registry are covered too.
- **The `file` key backend** keeps the age key next to the vault (different
  directory, same home). It defends a copy of `vault/` alone, not a copy of the
  home directory. Use it where there is no keychain or secret service.
- **Shared memory is a prompt-injection return path.** Instructions mitigate;
  they do not prevent a model from following a planted note. Review
  `nodes/**` before promoting anything to `notes/`.
- **CLIProxyAPI logins are shared.** With `FLEET_PROXY_MODE=local` every
  `full` node holds copies of the master's OAuth files; a vendor refresh-token
  rotation on one node can log the others out, and all nodes share the
  account's rate limits. Node copies win on later provisions;
  `--refresh-proxy-auth` restores the master's.
- **`launchctl setenv` (macOS)** puts `ANTHROPIC_AUTH_TOKEN` in one process's
  argv for milliseconds (local user only). It only happens with a local
  CLIProxyAPI (`cliproxy` in `FLEET_TOOLS` and `FLEET_PROXY_MODE=local`);
  without `cliproxy`, or in remote mode, no token is published and the
  variables are unset again. If even that is unacceptable, leave `cliproxy` out
  on macOS nodes (Claude Code then uses `CLAUDE_CODE_OAUTH_TOKEN` natively).
- **Codex `auth.json` is not copied** (refresh-token rotation would log other
  copies out); device-code login per node instead. `CLAUDE_CODE_OAUTH_TOKEN`
  is a one-year token shared by every node; `fleet status` reports its age.
- **The GitHub fallback token** (`vault/github.json`, used only without `gh`)
  must have *Administration: read/write* on the repos, which is more than
  deploy-key management strictly needs.
- **Public code repo over https** means no per-node revocation for code
  access, which is fine for a public repo and the reason the key is skipped.
- **T3 Code sessions outlive a disconnect.** Every connect that has to pair
  again leaves a 30-day bearer session in the node's T3 store (one real node
  had 136 of them). They only work through the tunnel, i.e. with the ssh key,
  but `fleet t3 status` counts them and `fleet t3 revoke` is the way to clear
  them. T3 also stores one `t3 serve` state per alias under `~/.t3/ssh-launch/`
  and every `t3 serve --base-dir ~/.t3` clears the shared
  `userdata/server-runtime.json` when it stops (`apps/server/src/server.ts`), so
  after a revoke the node's desktop app is rediscovered only once it restarts.
- **The invite one-liner is only as private as the channel you send it over.**
  It expires in an hour and is single use; a stolen one still lets someone
  enrol one node with the invited profile until then — `fleet nodes` shows it,
  `fleet kick` removes it.

Review history: the independent reviews of the plan and of the code (round 1
and 2) raised the registry/lock races, the lost-key rollback, the policy
`src` loophole (CIDR/IP/host alias), the cleanup retry being skipped on an API
error, the reused-PID kill, the `Match User` sshd bypass and the readable
bind-mounted invite; all are fixed and covered by tests (`tests/master_test.sh`
M1–M6, `tests/node_test.sh` N1–N8, `tests/e2e.sh`).

## Secret handling rules (for contributors)

1. Secrets enter through `read_secret` (hidden prompt or stdin) or a 0600
   file, never through a positional argument or an environment variable that a
   child could inherit unnecessarily.
2. Nothing prints a secret: `log/ok/warn/die` get names and counts.
   `fleet secrets list` prints names. `status.json` reports token *ages*.
3. HTTP with credentials goes through `lib/api.py`, which reads the vault
   files itself, or through `gh api` (keyring). Never `curl -H "Authorization: …"`.
4. Files that may hold secrets are written with `atomic_write … 0600` under
   `umask 077`; in the vault, through `vault_write` (encrypted) and read with
   `vault_read`/`vault_cat` into a pipe or a variable, never into a temp file.
   The identity reaches `age` on stdin (`-i -`), never as an argument.
5. Templates reference secrets as `${UPPER_CASE}` placeholders documented in
   `harness/SECRETS.md`; `harness_secret_scan` must stay at zero hits.
6. Tests use obviously fake values (`…-FAKE`, `ghtok`, `example`) and never a
   real path under a user's home.

## After a lost or kicked node

1. `fleet kick NODE` (or wait for the vanished-node path). Both print the
   names in the node's `secrets_sent`; `fleet nodes` shows `cleanup-pending`
   until every delete succeeded, and `fleet doctor` reports leftovers.
2. Rotate every secret in that list at its vendor: `CLAUDE_CODE_OAUTH_TOKEN`
   (`claude setup-token` again), `OPENAI_API_KEY`, `CURSOR_API_KEY`,
   `XAI_API_KEY`, `GH_TOKEN`, registry tokens named in `FLEET_DOCKER_LOGINS`,
   the MCP keys from `harness/SECRETS.md`, and — for a `full` node — the
   CLIProxyAPI client key and the OAuth logins it held (`fleet proxy import`
   again after re-authenticating the proxy on the master), plus anything in the
   mirrored files (`files_sent`).
3. `fleet secrets set NAME` for each, `fleet proxy import`, then `fleet
   reconcile` so the remaining nodes receive the new values.
4. If the node had the memory key: it was deleted by kick; confirm in the
   repo's deploy-key list. Review the node's folder in the vault for planted
   content.
5. If the node is physically back under your control, reinstall it or at
   least remove `~/.config/fleet`, `~/.local/share/fleet*`, `~/.ssh/fleet_*`,
   the harness directories and the proxy directory before inviting it again.
6. If the node was used from T3 Code: kick already revoked its sessions,
   pairing tokens and the client key (or left `t3:<id>` pending while the node
   was offline); delete the `fleet-<name>` environment in the app. A kicked
   node cannot use the T3 client key against another node — the key is only
   ever authorised *on* nodes, never present on them.
