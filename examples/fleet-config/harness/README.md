# harness/ — harness configuration templates

Templates for every agent harness fleet knows about. They are **captured from
the master's live configuration** by `fleet config publish` (`harness_capture`
in fleeter's `lib/harness.sh`) and **rendered onto nodes** by `fleet apply`
(`harness_apply`). You normally do not write these files by hand.

```
../AGENTS.md           global agent instructions, shared by every harness (hand-written)
claude/   settings.json  CLAUDE.md (addendum)  agents/  commands/  rules/  hooks/
          plugins.txt  mcp.json  statusline-command.sh
codex/    config.toml  AGENTS.md (addendum)  agents/  rules/
cursor/   mcp.json  cli-config.json  rules/
grok/     config.toml
t3code/   settings.json  client-settings.json  keybindings.json
SECRETS.md   every ${VAR} placeholder, where it is used, where to get it, profile
```

Hand-maintained (capture never touches them): `../AGENTS.md`, `claude/CLAUDE.md`,
`codex/AGENTS.md`, `README.md` (this file), `SECRETS.md`. Everything else is
regenerated on every capture. A harness that is not installed on the master is
skipped, and its directory here stays as it is.

## How capture works

On the master, `fleet config publish` reads the live config of each harness
(`~/.claude/settings.json` and `~/.claude.json`, `~/.codex/config.toml`,
`~/.cursor/mcp.json`, `~/.grok/config.toml`, `~/.t3/userdata/*.json`, and the
skill directories `~/.claude/skills`, `~/.agents/skills`, `~/.codex/skills`,
`~/.cursor/skills`) and writes sanitized templates here:

- secret header/env values become `${PLACEHOLDER}` (the name is derived from the
  server and key; list each one in `SECRETS.md`),
- the master's home directory becomes `${HOME}`, binaries from per-user
  toolchain directories become bare command names,
- MCP servers, hooks and TOML tables that reference local apps, loopback URLs
  or anything in `FLEET_CAPTURE_MACHINE_ONLY` are dropped,
- per-machine state is dropped: Codex `projects.*` trust entries,
  `hooks.state.*`, desktop/TUI tables, local marketplaces; Grok `[privacy]`;
  T3 per-project overrides,
- skills named in `FLEET_SKILL_EXCLUDE` are not copied.

Then it runs a secret scan over `harness/` and `skills/`; any hit aborts the
publish. Tune the capture with the `FLEET_CAPTURE_*` and `FLEET_SKILL_EXCLUDE`
keys in `fleet.conf`.

## Template variables

Only `${UPPER_CASE}` in braces is a placeholder; `$NAME`, `$$` and `${lower}`
pass through unchanged (so shell snippets in Markdown survive).

| Variable | Value on the node |
|---|---|
| `${HOME}` | the node user's home |
| `${FLEET_NODE}` | the node name (from `~/.config/fleet/env.sh`, else `enrol.json`, else `hostname -s`) |
| `${FLEET_MEMORY_DIR}` | `FLEET_MEMORY_DIR` from `fleet.conf` (default `~/fleet-memory`) |
| secrets | from `~/.config/fleet/secrets.env`; see `SECRETS.md` |

A missing secret drops the MCP server (JSON) or the `[mcp_servers.<x>…]`
section group (TOML) that uses it, with a `warn`. A missing variable anywhere
else aborts the apply.

## Where things land on a node, and who owns the file

| Template | Node path | Ownership |
|---|---|---|
| `../AGENTS.md` + `claude/CLAUDE.md` | `~/.claude/CLAUDE.md` | fleet-owned, overwritten |
| `../AGENTS.md` + `codex/AGENTS.md` | `~/.codex/AGENTS.md` | fleet-owned, overwritten |
| `../AGENTS.md` | `~/.cursor/rules/fleet-global.mdc` (frontmatter `alwaysApply: true`) | fleet-owned, overwritten |
| — | Grok | no file; with `[compat.claude]` (default on) it loads `~/.claude/CLAUDE.md`, `~/.claude/rules/` and `~/.claude/skills/` itself |
| `claude/settings.json` | `~/.claude/settings.json` (0600) | fleet-owned, overwritten after a one-time backup |
| `claude/agents,commands,rules,hooks/*`, `statusline-command.sh` | `~/.claude/<same>` | fleet-owned per file; other files in those dirs are left alone |
| `claude/mcp.json` | `mcpServers` in `~/.claude.json` | fleet-owned per server name; user-added servers stay. Edited in place (atomic, 0600), never through `claude mcp add-json`, because the rendered JSON contains secrets and secrets never go into argv |
| `claude/plugins.txt` | `claude plugin marketplace add` / `claude plugin install -s user -y` | only when `claude` is installed and `FLEET_HARNESS_NO_CLI` is unset |
| `codex/config.toml` | `~/.codex/config.toml` (0600) | fleet-owned top-level tables are replaced; node-local tables the template does not define (`projects.*`, `hooks.state.*`, `tui`, …) are kept |
| `codex/agents/*.toml`, `codex/rules/*.rules` | `~/.codex/agents/`, `~/.codex/rules/` | fleet-owned per file |
| `cursor/mcp.json`, `cursor/cli-config.json` | `~/.cursor/` (0600 / 0644) | fleet-owned, overwritten |
| `cursor/rules/*.mdc` | `~/.cursor/rules/` | fleet-owned per file |
| `grok/config.toml` | `~/.grok/config.toml` | fleet-owned tables `[cli]`, `[marketplace]`, `[ui]` replaced; Grok's own tables kept |
| `t3code/settings.json`, `client-settings.json` | `~/.t3/userdata/` | shallow-merged: template keys win, keys T3 adds on the node survive. Skipped in containers |
| `t3code/keybindings.json` | `~/.t3/userdata/keybindings.json` | fleet-owned, overwritten |
| `../skills/*` | `~/.claude/skills/<name>`, `~/.agents/skills/<name>`, `~/.cursor/skills/<name>` | fleet-owned directories; a pre-existing unowned dir is moved to `<name>.pre-fleet` once. `~/.codex/skills` becomes a symlink to `~/.agents/skills` unless it already exists as a real directory |

"Overwritten" means: the first time fleet touches a pre-existing file it is
copied to `<file>.pre-fleet`, after that the node's copy is replaced whenever
the rendered template differs. Local edits on nodes do not survive; put them in
this repo.

Every path fleet writes is listed in `~/.config/fleet/harness.manifest` (and
appended to the shared `~/.config/fleet/manifest`). A path that disappears from
the template set is deleted on the next apply.

## Testing a change without touching your machine

```bash
HOME=$(mktemp -d) FLEET_HARNESS_NO_CLI=1 FLEET_CONFIG_DIR=$PWD FLEET_ROOT=/path/to/fleeter \
  bash -c '. "$FLEET_ROOT/lib/common.sh"; fleet_load_config; . "$FLEET_ROOT/lib/harness.sh"; harness_apply; harness_status'
```
