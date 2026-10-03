# skills/

Skills pushed to every node by `fleet apply` into `~/.claude/skills`,
`~/.agents/skills` (Codex; `~/.codex/skills` becomes a symlink to it) and
`~/.cursor/skills`. Grok reads `~/.claude/skills` and `~/.cursor/skills` itself.

One directory per skill, each with a `SKILL.md` (directories without one are
ignored). Two ways to fill this directory:

- **Capture** (default): `fleet config publish` on the master copies the union
  of `~/.claude/skills`, `~/.agents/skills`, `~/.codex/skills`, `~/.cursor/skills`
  here (symlinks dereferenced; on a name collision the first source in that
  order wins), removes skills that are gone from the master, and rewrites this
  README with the resulting table. Skills named in `FLEET_SKILL_EXCLUDE`
  (`fleet.conf`) are never copied, nor are vendor caches (`synced`, `.system`).
- **By hand**: drop a directory here and commit. The next capture keeps it only
  if the master has it too, so prefer installing skills on the master.

Plugin-provided skills (Claude plugins) come from the marketplaces and plugins
listed in `harness/claude/plugins.txt`, not from this directory.

`fleet-notes/` is a small example skill; delete it once you have your own.
