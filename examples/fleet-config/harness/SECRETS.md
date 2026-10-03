# Secret placeholders used by harness templates

Every `${VAR}` below is filled on the node at `fleet apply` time from
`~/.config/fleet/secrets.env` (pushed by the master; `fleet secrets set NAME
--profile P`). A placeholder with no value makes `harness_apply` **skip the MCP
server / TOML section that uses it** (with a warning); it never writes an empty
secret. Values are never committed to this repo; `harness_capture` replaces them
with these names, and the secret scan fails the publish if any slips through.

`harness_capture` warns when a template uses a placeholder that is not listed
here, so keep this table complete. Rows must start with `` | `NAME` `` (the
check greps for that).

| Name | Used by | Where to get it | Profile |
|---|---|---|---|
| `CONTEXT7_API_KEY` | Claude/Codex/Cursor `context7` MCP server header | context7.com dashboard | minimal |

Not placeholders, but required in the same `secrets.env` for the harnesses to
log in (handled by `lib/tools/*`; listed so one file answers "what must I rotate
if node X is lost"): `CLAUDE_CODE_OAUTH_TOKEN` (minimal), `OPENAI_API_KEY` or
device-code login (minimal), `CURSOR_API_KEY` (minimal), `XAI_API_KEY` or
device-code login (full), `GH_TOKEN` (full), the CLIProxyAPI client key
(minimal, inside the proxy config shipped by `fleet proxy import`).
