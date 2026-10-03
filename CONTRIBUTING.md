# Contributing

fleeter is a small bash + python3-stdlib tool with an unusually strict
portability contract, because the same files run on macOS (bash 3.2), Debian
containers and whatever Linux a node happens to be. Read this before sending a
change.

## Running the tests

Three suites, all offline (no real Tailscale, GitHub or ssh):

```sh
bash tests/master_test.sh                  # master logic with a fake ssh, fake Tailscale/GitHub API; ~2 min, no Docker needed
docker run --rm -v "$PWD:/src:ro" debian:bookworm-slim bash /src/tests/node_test.sh   # node side in a clean container
bash tests/e2e.sh                          # one master + two Docker nodes through the whole flow; ~2 min after the image build
```

Each prints `PASS`/`FAIL` per check and exits non-zero on any failure. Run
`master_test.sh` on macOS **and** in a clean Debian container before a PR:

```sh
docker run --rm -v "$PWD:/src:ro" debian:bookworm-slim bash -c \
  'apt-get update -qq && apt-get install -y -qq --no-install-recommends git python3 openssh-client procps netcat-openbsd ca-certificates && cd /tmp && bash /src/tests/master_test.sh'
```

Lint:

```sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -s bash -x $(git ls-files '*.sh') fleet
```

CI (`.github/workflows/ci.yml`) runs exactly these on every push and pull
request: shellcheck, `master_test` on Ubuntu and macOS, `node_test` in
`debian:bookworm-slim`, and `e2e` on Ubuntu.

Tests must stay offline and must never touch the host's `~/.config/fleet`,
`~/.ssh` or git config: everything goes under a `mktemp -d`, `HOME` is
redirected, `GIT_CONFIG_GLOBAL` points at a file of the test's own, and every
`git init` pins `-c init.defaultBranch=main`. Fake values are obviously fake
(`…-FAKE`, `example`, `tester@example.invalid`).

## Shell rules (bash 3.2 and friends)

The contract is spelled out in `docs/ARCHITECTURE.md` ("Portability contract");
the short list:

- bash 3.2 syntax only: no associative arrays, no `mapfile`/`readarray`, no
  `${var,,}` / `${var^^}`, no `|&`, no `declare -n`, no `;;&`.
- No GNU-only flags: no `sed -i`, `readlink -f`, `date -d`, `stat -c` without a
  BSD fallback, `grep -P`, `sort -V`, `timeout`, `flock`. Use the helpers in
  `lib/common.sh` (`atomic_write`, `abspath`, `sha256`, `with_timeout`,
  `lock_acquire`, `mode_of`) instead of reinventing them.
- Every function declares its variables `local` (bash scoping is dynamic; a bare
  assignment overwrites the caller's variable of the same name).
- `set -eu` is on: guard anything that may legitimately fail (`|| true`,
  `${var:-}`), and never rely on a failing command substitution to stop a script.
- Secrets never appear in argv, in the environment of a child that does not
  need them, or in output: hidden prompt or stdin in, files with `umask 077` +
  `atomic_write … 0600` out, HTTP through `lib/api.py` (reads the vault itself)
  or `gh api`. `log/ok/warn/die` get names and counts, never values.
- python3 stdlib only; one `python3 - <<'PY'` heredoc per job, arguments via
  `sys.argv`, secrets via stdin or files.
- Output goes through `log`, `ok`, `warn`, `die MESSAGE [NEXT STEP]` so every
  failure tells the user what to do next.

Run shellcheck; the few `# shellcheck disable=` lines in the tree each carry
the reason.

## Adding a tool plug-in

A tool is one file, `lib/tools/<name>.sh`, sourced by `tool_call`
(`lib/common.sh`) and run by `node_tool_run` (`lib/node.sh`) in a fresh
`bash -e`. The contract (`docs/CONTRACT.md`, "Tool plug-in interface"):

| Function | Must |
|---|---|
| `tool_<name>_install` | converge: install if missing, configure; idempotent; no `sudo` unless `FLEET_INTERACTIVE=1` (only `fleet join` sets it), otherwise `warn` and `return 0` |
| `tool_<name>_update` | run the vendor updater; no-op if the tool self-updates |
| `tool_<name>_status` | print exactly one line `<state> <detail>`, state in `ok missing login error skipped` |
| `tool_<name>_login` | optional; interactive device-code / URL flow |

Steps:

1. Create `lib/tools/<name>.sh`; private helpers are `_<name>_*`; only
   `lib/common.sh` helpers and `fleet.conf` settings may be used. Need a new
   setting? Add it to `config/defaults.conf` **and** `examples/fleet-config/fleet.conf`
   with the same default, and to the README's config reference.
2. If the tool needs root on Linux (apt packages, a system service), the
   privileged step belongs in `lib/join.sh` (`join_privileged`), gated with
   `join_wants <name>`; the plug-in then checks `~/.config/fleet/privileged_done`
   and points back to `fleet join` instead of calling `sudo`.
3. If it needs a GUI or nested Docker, add it to `FLEET_TOOLS_SKIP_IN_CONTAINER`
   in the defaults and return `skipped` from status where it does not apply.
4. Document it in the README's "Choosing tools" table (what it installs, which
   secret or login it needs, which OSes) and in `lib/tools/README.md`.
5. Test it: a status/wrapper test in `tests/node_test.sh` with fake binaries on
   PATH (see `case_chrome_wrapper`, `case_base_status`), and a smoke test in a
   throwaway container:
   `docker run --rm -v "$PWD:/src:ro" debian:bookworm-slim bash -c 'export FLEET_ROOT=/src; . /src/lib/common.sh; fleet_load_config; . /src/lib/tools/<name>.sh; tool_<name>_status'`.

## Changes to the master ↔ node contract

`docs/CONTRACT.md` fixes the registry schema, the node files, the invite code,
what the master runs on a node and the `status --json` shape. Change it only
together with every side that uses it, keep old entries readable (see the
legacy `github_keys` handling), and extend `tests/master_test.sh` and
`tests/e2e.sh` in the same commit.

## Commits and pull requests

Small, logical commits with a lowercase imperative subject line and no
conventional-commit prefix (`make the memory repo optional`, not
`feat: Memory`). Say in the body what changed for a user and why. Update
`CHANGELOG.md` under an "Unreleased" heading for anything user-visible.
