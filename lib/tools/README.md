# Tool plug-ins

One file per tool, `lib/tools/<name>.sh`, sourced by `tool_call` in
`lib/common.sh` (and by `node_tool_run` in `lib/node.sh`, which runs each one
in a fresh `bash -e`). The full contract is in `docs/CONTRACT.md` ("Tool plug-in
interface"); the short version:

| Function | Must |
|----------|------|
| `tool_<name>_install` | converge: install if missing, configure; idempotent; no `sudo` unless `FLEET_INTERACTIVE=1` (then via `as_root`), otherwise `warn` and `return 0` |
| `tool_<name>_update` | run the vendor updater; no-op if the tool self-updates |
| `tool_<name>_status` | print exactly one line `<state> <detail>`, state in `ok missing login error skipped` |
| `tool_<name>_login` | optional; interactive device-code / URL flow |

`<name>` with `-` becomes `_` in function names. Private helpers are prefixed
`_<name>_`. Only helpers from `lib/common.sh` (`log ok warn die have as_root
atomic_write fleet_os fleet_arch fleet_in_container fleet_pkg_mgr`) and settings
from `fleet.conf` (`FLEET_MISE_TOOLS`, `FLEET_PNPM`, `FLEET_NPM_GLOBALS`,
`FLEET_DOCKER_LOGINS`, `FLEET_PROXY_*`, `FLEET_CLIPROXY_DIR`,
`FLEET_CHROME_DEVTOOLS_MCP`, `FLEET_PLAYWRIGHT_MCP`) may be used. A new setting
goes into `config/defaults.conf` and `examples/fleet-config/fleet.conf` with the
same default.

Shipped plug-ins: `base` (git, git-lfs, curl, jq, ripgrep, tmux, python3, unzip,
nc), `devtools`
(mise runtimes, pnpm, uv, gh, glab, docker, registry logins), `chrome` (browser
plus the two browser MCP servers behind `~/.local/bin/fleet-*-mcp` wrappers),
`claude`, `codex`, `cursor`, `grok` (the harness CLIs), `cliproxy` (CLIProxyAPI
in Docker), `t3code` (desktop app, GUI only).

Privileged steps (docker-ce on Linux, Homebrew on macOS) are done by `fleet
join`, which records `~/.config/fleet/privileged_done`; a plug-in that finds the
marker but not the tool must `warn` and point back to `fleet join`, never `sudo`.

Rules: bash 3.2 (no associative arrays, `mapfile`, `${v,,}`), no GNU-only
flags, no `sed -i`; secrets come from env and never appear in argv or output;
every function declares its variables `local`; return `skipped` from status
where a tool does not apply (container, no GUI).

## Adding a tool

1. Create `lib/tools/<name>.sh` with the three functions above.
2. Add `<name>` to `FLEET_TOOLS` in your config repo's `fleet.conf` (order =
   install order); add it to `FLEET_TOOLS_SKIP_IN_CONTAINER` if it needs a GUI
   or nested Docker.
3. Check: `bash -n lib/tools/<name>.sh` and
   `docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -s bash -x lib/tools/<name>.sh`.
4. Smoke-test status/install in a throwaway container:
   `docker run --rm -v "$PWD:/src:ro" debian:bookworm-slim bash -c 'export FLEET_ROOT=/src; . /src/lib/common.sh; fleet_load_config; . /src/lib/tools/<name>.sh; tool_<name>_status'`.
