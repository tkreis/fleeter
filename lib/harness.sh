# shellcheck shell=bash
# lib/harness.sh — harness configuration sync for Claude Code, Codex CLI,
# Cursor CLI, Grok Build and T3 Code. Sourced by `fleet`; functions only.
#
#   harness_capture       master: refresh $FLEET_CONFIG_DIR/harness/ and /skills/
#                         from this machine's live config, sanitized (secrets ->
#                         ${VAR}, machine paths -> ${HOME}, machine-only
#                         hooks/servers dropped). Run by `fleet config publish`.
#   harness_apply         node: render $FLEET_CONFIG_DIR/{AGENTS.md,harness/,skills/} into $HOME.
#   harness_status        node: one line per harness: <name> <ok|drift> <detail>
#   harness_secret_scan   DIR: python regex scan for secret-looking values
#                         (patterns in lib/secretscan.py, shared with the memory
#                         capture); prints hits, exit 1 if any.
#
# Template placeholders are ONLY the brace form with an upper-case name:
#   ${HOME}, ${FLEET_NODE} (the node name, see harness_node_name),
#   ${FLEET_MEMORY_DIR}, and secrets listed in $FLEET_CONFIG_DIR/harness/SECRETS.md.
#   A missing secret drops the MCP server / TOML section that uses it (warned),
#   never writes an empty value.
#
# Ownership on nodes (see examples/fleet-config/harness/README.md): settings.json, config.toml,
# mcp.json, cli-config.json are fleet-owned (backup_once, then overwritten).
# Codex/Grok config.toml keep node-local top-level tables that the template does
# not define (projects.*, hooks.state.*, privacy, hints). T3 settings are
# shallow-merged. Everything written is listed in $FLEET_HOME/harness.manifest
# and appended to $FLEET_HOME/manifest; paths that drop out of the template set
# are removed on the next apply.
#
# Portability: bash 3.2, python3 stdlib only, no sed -i, no GNU flags.

harness_tpl_dir() { echo "${FLEET_CONFIG_DIR}/harness"; }
harness_skills_dir() { echo "${FLEET_CONFIG_DIR}/skills"; }
harness_agents_md() { echo "${FLEET_CONFIG_DIR}/AGENTS.md"; }

# Node name for ${FLEET_NODE}: FLEET_NODE / FLEET_NODE_NAME env (exported by env.sh),
# then enrol.json, then hostname.
harness_node_name() {
  if [ -n "${FLEET_NODE:-}" ]; then echo "$FLEET_NODE"; return; fi
  if [ -n "${FLEET_NODE_NAME:-}" ]; then echo "$FLEET_NODE_NAME"; return; fi
  # shellcheck disable=SC2153  # FLEET_HOME comes from lib/common.sh
  n=$(json_get "$FLEET_HOME/enrol.json" name 2>/dev/null || true)
  if [ -n "$n" ]; then echo "$n"; return; fi
  hostname -s 2>/dev/null || hostname
}

# ---------- python helper (one script, subcommands) ----------

harness_py() {
  python3 - "$@" <<'PY'
import hashlib, json, os, re, shutil, string, sys

# ----- placeholders -----

class Tpl(string.Template):
    # Only ${UPPER_NAME} is a placeholder. Bare $NAME, $$ and ${lower} are left alone.
    pattern = r'\$(?:(?P<escaped>(?!))|\{(?P<braced>[A-Z][A-Z0-9_]*)\}|(?P<named>(?!))|(?P<invalid>(?!)))'

UNRES = re.compile(r'\$\{([A-Z][A-Z0-9_]*)\}')

def parse_vars(argv):
    pos, vars_ = [], dict(os.environ)
    i = 0
    while i < len(argv):
        if argv[i] == '--var':
            k, _, v = argv[i + 1].partition('='); vars_[k] = v; i += 2
        elif argv[i] == '--vars-file':
            for line in open(argv[i + 1], encoding='utf-8'):
                if '=' in line:
                    k, _, v = line.rstrip('\n').partition('='); vars_[k] = v
            i += 2
        elif argv[i] == '--keep':
            vars_.setdefault('__keep__', []); vars_['__keep__'].append(argv[i + 1]); i += 2
        else:
            pos.append(argv[i]); i += 1
    return pos, vars_

def render_text(text, vars_):
    out = Tpl(text).safe_substitute(vars_)
    return out, sorted(set(UNRES.findall(out)))

def warn(msg): sys.stderr.write('warn %s\n' % msg)

def write(path, text, mode=0o644):
    d = os.path.dirname(path)
    if d: os.makedirs(d, exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f: f.write(text)
    os.chmod(path, mode)

# ----- TOML as text blocks (no toml lib: templates are text) -----

HEADER = re.compile(r'^\s*(\[\[?)\s*(.+?)\s*\]\]?\s*(#.*)?$')

def toml_path(s):
    parts, buf, q = [], '', None
    for ch in s:
        if q:
            if ch == q: q = None
            else: buf += ch
        elif ch in '"\'': q = ch
        elif ch == '.': parts.append(buf.strip()); buf = ''
        else: buf += ch
    parts.append(buf.strip())
    return parts

def toml_blocks(text):
    blocks, cur = [], ([], [])
    for line in text.splitlines():
        m = HEADER.match(line)
        if m and not line.lstrip().startswith('#'):
            blocks.append(cur); cur = (toml_path(m.group(2)), [line])
        else:
            cur[1].append(line)
    blocks.append(cur)
    return blocks  # blocks[0] is the root block (path [])

def strip_blank(lines):
    while lines and not lines[-1].strip(): lines.pop()
    while lines and not lines[0].strip(): lines.pop(0)
    return lines

def toml_join(blocks):
    parts = []
    for p, lines in blocks:
        lines = strip_blank(list(lines))
        if lines: parts.append('\n'.join(lines))
    return '\n\n'.join(parts) + '\n'

def toml_group(p):
    if p[:1] == ['mcp_servers'] and len(p) >= 2: return 'mcp_servers.' + p[1]
    return '.'.join(p)

def render_toml(tpl_text, existing_text, vars_, keep):
    blocks = toml_blocks(tpl_text)
    rendered, dropped, bad_groups = [], [], set()
    for p, lines in blocks:
        text, unres = render_text('\n'.join(lines), vars_)
        if unres:
            if not p: sys.exit('error unresolved placeholder(s) in root block: %s' % ', '.join(unres))
            bad_groups.add(toml_group(p)); dropped.append((toml_group(p), unres))
        rendered.append((p, text.split('\n')))
    out = [(p, l) for p, l in rendered if not p or toml_group(p) not in bad_groups]
    for g, unres in sorted(set((g, tuple(u)) for g, u in dropped)):
        warn('skipping [%s]: missing %s' % (g, ', '.join(unres)))
    tops = set(p[0] for p, _ in out if p)
    if existing_text is not None:
        for p, lines in toml_blocks(existing_text)[1:]:
            path = '.'.join(p)
            if p[0] not in tops or any(path == k or path.startswith(k + '.') for k in keep):
                out.append((p, lines))
    return toml_join(out)

# ----- commands -----

def cmd_render(argv):
    (src, dst), vars_ = parse_vars(argv)
    text, unres = render_text(open(src, encoding='utf-8').read(), vars_)
    if unres: sys.exit('error unresolved placeholder(s) in %s: %s' % (src, ', '.join(unres)))
    write(dst, text)

def cmd_render_mcp(argv):
    # TEMPLATE OUTDIR: renders each mcpServers entry; entries with an unresolved
    # placeholder are skipped. Writes OUTDIR/<name>.json and OUTDIR/all.json.
    (src, outdir), vars_ = parse_vars(argv)
    data = json.load(open(src, encoding='utf-8'))
    kept = {}
    for name, server in data.get('mcpServers', {}).items():
        text, unres = render_text(json.dumps(server, indent=2, sort_keys=True), vars_)
        if unres: warn('skipping MCP server %s: missing %s' % (name, ', '.join(unres))); continue
        kept[name] = json.loads(text)
        write(os.path.join(outdir, name + '.json'), json.dumps(kept[name], indent=2, sort_keys=True) + '\n', 0o600)
    write(os.path.join(outdir, 'all.json'), json.dumps({'mcpServers': kept}, indent=2, sort_keys=True) + '\n', 0o600)
    for name in kept: print(name)

def cmd_render_toml(argv):
    (src, existing, dst), vars_ = parse_vars(argv)
    ex = open(existing, encoding='utf-8').read() if os.path.isfile(existing) else None
    write(dst, render_toml(open(src, encoding='utf-8').read(), ex, vars_, vars_.get('__keep__', [])))

def cmd_merge_json(argv):
    # TEMPLATE EXISTING OUT: render template, shallow-merge over existing object (template wins).
    (src, existing, dst), vars_ = parse_vars(argv)
    text, unres = render_text(open(src, encoding='utf-8').read(), vars_)
    if unres: sys.exit('error unresolved placeholder(s) in %s: %s' % (src, ', '.join(unres)))
    new = json.loads(text)
    base = {}
    if os.path.isfile(existing):
        try:
            base = json.load(open(existing, encoding='utf-8'))
            if not isinstance(base, dict): base = {}
        except Exception: base = {}
    if isinstance(new, dict): base.update(new); new = base
    write(dst, json.dumps(new, indent=2) + '\n')

def cmd_claude_json(argv):
    # CLAUDE_JSON ALL_JSON OWNED_FILE: set fleet-owned mcpServers in ~/.claude.json
    # (read-modify-write; only servers named in OWNED_FILE from the previous run are
    # replaced/removed, user-added servers stay). Prints "changed" or "same".
    (path, allj, ownedf), _ = parse_vars(argv)
    new = json.load(open(allj, encoding='utf-8'))['mcpServers']
    prev = set(open(ownedf, encoding='utf-8').read().split()) if os.path.isfile(ownedf) else set()
    data = {}
    if os.path.isfile(path):
        try: data = json.load(open(path, encoding='utf-8'))
        except Exception as e: sys.exit('error %s is not valid JSON (%s); not touching it' % (path, e))
    servers = dict(data.get('mcpServers', {}))
    before = json.dumps(servers, sort_keys=True)
    for n in prev - set(new): servers.pop(n, None)
    servers.update(new)
    data['mcpServers'] = servers
    if json.dumps(servers, sort_keys=True) == before: print('same'); return
    tmp = path + '.fleet-tmp'
    write(tmp, json.dumps(data, indent=2) + '\n', 0o600)
    os.replace(tmp, path)
    print('changed')

# ----- secret scan (patterns and file scanner live in lib/secretscan.py, shared with lib/memory_capture.py) -----

sys.path.insert(0, os.path.join(os.environ['FLEET_ROOT'], 'lib'))
from secretscan import SECRET_PATTERNS, SKIP_DIRS, scan_file  # noqa: E402

def cmd_scan(argv):
    (root,), _ = parse_vars(argv)
    hits = []
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
        for f in sorted(files):
            if f == '.DS_Store': continue
            hits.extend(scan_file(os.path.join(d, f)))
    for p, ln, label in hits: print('%s:%d: %s' % (os.path.relpath(p, root), ln, label))
    print('secret scan: %d hit(s) in %s' % (len(hits), root))
    sys.exit(1 if hits else 0)

def cmd_placeholders(argv):
    (root,), _ = parse_vars(argv)
    names = set()
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
        for f in files:
            if f in ('README.md', 'SECRETS.md'): continue   # docs mention example placeholders
            try: names.update(UNRES.findall(open(os.path.join(d, f), encoding='utf-8', errors='replace').read()))
            except Exception: pass
    for n in sorted(names - {'HOME', 'FLEET_NODE', 'FLEET_NODE_NAME', 'FLEET_MEMORY_DIR'}): print(n)

# ----- capture (master) -----

SECRET_KEY = re.compile(r'(KEY|TOKEN|SECRET|AUTH|PASSWORD|CREDENTIAL|^DD-)', re.I)
TOKEN_VALUE = re.compile('|'.join(p for _, p in SECRET_PATTERNS) + r'|^[A-Za-z0-9+/=_-]{32,}$')
PLACEHOLDER_MAP = {
    ('context7', 'CONTEXT7_API_KEY'): 'CONTEXT7_API_KEY',
    ('*', 'DD-API-KEY'): 'DD_API_KEY',
    ('*', 'DD-APPLICATION-KEY'): 'DD_APPLICATION_KEY',
    ('langfuse', 'Authorization'): 'LANGFUSE_MCP_AUTH',
    ('plan', 'Authorization'): 'PLAN_MCP_TOKEN',
    ('motion', 'TOKEN'): 'MOTION_MCP_TOKEN',
}
# Anything referencing these is machine-only and dropped: local apps, loopback
# URLs, plus whatever FLEET_CAPTURE_MACHINE_ONLY names (space separated).
def _words(var): return [w for w in os.environ.get(var, '').split() if w]
MACHINE_ONLY = tuple(['/Library/Application Support/', '/Applications/', '127.0.0.1', 'localhost'] + _words('FLEET_CAPTURE_MACHINE_ONLY'))
# Tools installed from a per-user toolchain dir on the master but on PATH on nodes.
COMMAND_REWRITE = {'jbcontext_binary': 'jbcontext', 'jbcontext': 'jbcontext', 'mcpvault': 'mcpvault'}
AGENT_EXCLUDE = set(_words('FLEET_CAPTURE_AGENT_EXCLUDE'))   # Claude agent files not shipped (basename without .md)
AGENT_EXCLUDE_MARKERS = tuple(m.strip() for m in os.environ.get('FLEET_CAPTURE_AGENT_MARKERS', '').split(';') if m.strip())
SKILL_EXCLUDE = {
    'synced': 'Claude plugin sync cache (vendor-managed, UUID dirs)',
    '.system': 'Codex vendor-shipped system skills',
    'fleet': "fleeter's bundled skill (shipped with the code; a copy in the config repo would go stale)",
}
for _n in _words('FLEET_SKILL_EXCLUDE'): SKILL_EXCLUDE[_n] = 'excluded by FLEET_SKILL_EXCLUDE'
RULE_DROP = tuple(['${HOME}', '/Users/', '/home/', '"-e"', '/bin/zsh', 'curl', 'xcodebuild', 'xcrun'] + _words('FLEET_CAPTURE_RULE_DROP'))
HAND_MAINTAINED = ('README.md', 'SECRETS.md', 'claude/CLAUDE.md', 'codex/AGENTS.md')

def placeholder_for(server, key, value):
    if '${' in value: return value                        # already templated at the source
    name = PLACEHOLDER_MAP.get((server, key)) or PLACEHOLDER_MAP.get(('*', key))
    if not name:
        name = re.sub(r'[^A-Z0-9]+', '_', ('%s_%s' % (server, key)).upper()).strip('_')
    m = re.match(r'^(Bearer|Basic|Token)\s+', value)
    return '%s${%s}' % (m.group(0) if m else '', name)

class Capture:
    def __init__(self, home, out):
        self.home, self.out = home.rstrip('/'), out
        self.placeholders, self.dropped, self.notes = set(), [], []

    def p(self, *parts): return os.path.join(self.home, *parts)
    def o(self, *parts): return os.path.join(self.out, 'harness', *parts)
    def drop(self, what): self.dropped.append(what)

    def portable(self, s):
        return s.replace(self.home, '${HOME}')

    def machine_only(self, s):
        s = s.lower()
        return any(m.lower() in s for m in MACHINE_ONLY)

    def rewrite_command(self, cmd):
        base = os.path.basename(cmd)
        if base in COMMAND_REWRITE: return COMMAND_REWRITE[base]
        if cmd.startswith(self.home + '/.nvm/'): return base   # nvm path -> global binary name
        return self.portable(cmd)

    def sanitize_server(self, name, server, kind):
        s = json.loads(json.dumps(server))
        blob = json.dumps(s)
        if self.machine_only(blob):
            self.drop('%s MCP server "%s" (machine-only: local app or loopback URL)' % (kind, name)); return None
        if 'command' in s: s['command'] = self.rewrite_command(s['command'])
        if 'args' in s:
            s['args'] = ['${FLEET_MEMORY_DIR}' if (name == 'memory-vault' and a.startswith('/')) else self.portable(a) for a in s['args']]
        if 'url' in s: s['url'] = s['url'].replace('/api/unstable/mcp-server/mcp', '/v1/mcp')
        for sect in ('headers', 'env'):
            for k, v in list(s.get(sect, {}).items()):
                if not isinstance(v, str): continue
                if SECRET_KEY.search(k) or TOKEN_VALUE.search(v):
                    s[sect][k] = placeholder_for(name, k, v)
                    self.placeholders.update(UNRES.findall(s[sect][k]))
                else:
                    s[sect][k] = self.portable(v)
        return s

    def copy_tree(self, src, dst, exclude=()):
        if os.path.isdir(dst): shutil.rmtree(dst)
        def ignore(d, names): return set(n for n in names if n in ('.DS_Store', '__pycache__', 'node_modules') or n in exclude)
        shutil.copytree(src, dst, symlinks=False, ignore=ignore)

    def copy_files(self, src, dst, keep=lambda n, text: True):
        if not os.path.isdir(src): return
        os.makedirs(dst, exist_ok=True)
        for n in sorted(os.listdir(dst)):
            if os.path.isfile(os.path.join(dst, n)): os.remove(os.path.join(dst, n))
        for n in sorted(os.listdir(src)):
            sp = os.path.join(src, n)
            if not os.path.isfile(sp) or n.startswith('.'): continue
            text = open(sp, encoding='utf-8', errors='replace').read()
            if not keep(n, text): continue
            write(os.path.join(dst, n), self.portable(text), 0o755 if os.access(sp, os.X_OK) else 0o644)

    # --- claude ---
    def claude(self):
        st = json.load(open(self.p('.claude', 'settings.json')))
        hooks_out = {}
        shipped_hooks = set()
        for event, groups in st.get('hooks', {}).items():
            kept_groups = []
            for g in groups:
                kept = []
                for h in g.get('hooks', []):
                    cmd = h.get('command', '')
                    for k, v in COMMAND_REWRITE.items():
                        cmd = re.sub(re.escape(self.home) + r'/\.jbcontext/bin/' + re.escape(k) + r'\b', v, cmd)
                    if self.machine_only(cmd):
                        self.drop('claude hook %s: %s' % (event, cmd.split('/')[-1].strip("'"))); continue
                    m = re.search(re.escape(self.home) + r'/\.claude/hooks/([A-Za-z0-9._-]+)', cmd)
                    if m: shipped_hooks.add(m.group(1))
                    elif self.home in cmd:
                        self.drop('claude hook %s: %s (absolute path outside ~/.claude/hooks)' % (event, cmd)); continue
                    h = dict(h); h['command'] = self.portable(cmd); kept.append(h)
                if kept: kept_groups.append(dict(g, hooks=kept))
            if kept_groups: hooks_out[event] = kept_groups
        st['hooks'] = hooks_out
        sl = st.get('statusLine', {})
        if sl and self.machine_only(json.dumps(sl)):
            alt = self.p('.claude', 'statusline-command.sh')
            if os.path.isfile(alt) and not self.machine_only(open(alt).read()):
                st['statusLine'] = {'type': 'command', 'command': '${HOME}/.claude/statusline-command.sh'}
                write(self.o('claude', 'statusline-command.sh'), open(alt).read(), 0o755)
                self.drop('claude statusLine wrapper (machine-only) -> replaced by ~/.claude/statusline-command.sh')
            else:
                st.pop('statusLine'); self.drop('claude statusLine (machine-only)')
        text = self.portable(json.dumps(st, indent=2) + '\n')
        write(self.o('claude', 'settings.json'), text)
        hooks_dir = self.o('claude', 'hooks')
        if os.path.isdir(hooks_dir): shutil.rmtree(hooks_dir)
        for n in sorted(shipped_hooks):
            src = self.p('.claude', 'hooks', n)
            if os.path.isfile(src): write(os.path.join(hooks_dir, n), self.portable(open(src).read()), 0o755)
        def keep_agent(n, text):
            if n.rsplit('.', 1)[0] in AGENT_EXCLUDE or any(m in text for m in AGENT_EXCLUDE_MARKERS):
                self.drop('claude agent %s (tool-managed / needs a non-fleet tool)' % n); return False
            return True
        self.copy_files(self.p('.claude', 'agents'), self.o('claude', 'agents'), keep_agent)
        self.copy_files(self.p('.claude', 'commands'), self.o('claude', 'commands'))
        self.copy_files(self.p('.claude', 'rules'), self.o('claude', 'rules'))
        # plugins.txt
        lines = ['# marketplace <name> <source>   |   plugin <name@marketplace> <enabled|disabled>',
                 '# harness_apply adds marketplaces and installs enabled plugins (user scope) when `claude` is present.']
        mkts = {}
        try: mkts.update(json.load(open(self.p('.claude', 'plugins', 'known_marketplaces.json'))))
        except Exception: pass
        mkts.update(st.get('extraKnownMarketplaces', {}))
        for name, m in sorted(mkts.items()):
            src = m.get('source', {})
            spec = src.get('repo') if src.get('source') == 'github' else src.get('url') or src.get('path', '')
            if not spec or self.home in spec: self.drop('claude marketplace %s (local path)' % name); continue
            lines.append('marketplace %s %s' % (name, spec))
        for plugin, enabled in sorted(st.get('enabledPlugins', {}).items()):
            lines.append('plugin %s %s' % (plugin, 'enabled' if enabled else 'disabled'))
        write(self.o('claude', 'plugins.txt'), '\n'.join(lines) + '\n')
        # mcp.json from ~/.claude.json (top-level mcpServers only)
        servers = {}
        try: servers = json.load(open(self.p('.claude.json'))).get('mcpServers', {})
        except Exception as e: self.notes.append('could not read ~/.claude.json: %s' % e)
        out = {}
        for name, server in sorted(servers.items()):
            s = self.sanitize_server(name, server, 'claude')
            if s is not None: out[name] = s
        out = self.keep_fleet_json(self.o('claude', 'mcp.json'), out)
        write(self.o('claude', 'mcp.json'), json.dumps({'mcpServers': out}, indent=2) + '\n')
        return len(out)

    # Fleet-managed MCP servers (command = ~/.local/bin/fleet-*, e.g. the Chrome
    # wrappers) do not exist on the master, so capture would drop them. Keep
    # them from the current template; they win over a captured server of the
    # same name.
    def keep_fleet_json(self, path, out):
        try: old = json.load(open(path)).get('mcpServers', {})
        except Exception: return out
        for name, server in old.items():
            if '/.local/bin/fleet-' in str(server.get('command', '')):
                out[name] = server
        return dict(sorted(out.items()))

    # A kept server is every block of its group: [mcp_servers.X] plus nested
    # subtables such as [mcp_servers.X.env] / [mcp_servers.X.http_headers],
    # which do not contain the fleet- marker themselves.
    def keep_fleet_toml(self, path, out_blocks):
        try: old = toml_blocks(open(path, encoding='utf-8').read())
        except Exception: return out_blocks
        names = set(toml_group(pp) for pp, ll in old[1:]
                    if toml_group(pp).startswith('mcp_servers.') and any('/.local/bin/fleet-' in l for l in ll))
        keep = [(pp, ll) for pp, ll in old[1:] if toml_group(pp) in names]
        out = [b for b in out_blocks if not (b[0] and toml_group(b[0]) in names)]
        return out + keep

    # --- codex ---
    def codex(self):
        text = open(self.p('.codex', 'config.toml'), encoding='utf-8').read()
        blocks = toml_blocks(text)
        root = [l for l in blocks[0][1] if not re.match(r'^\s*notify\s*=', l)]
        if len(root) != len(blocks[0][1]): self.drop('codex root key notify (desktop app binary)')
        groups, order = {}, []
        for p, lines in blocks[1:]:
            g = toml_group(p)
            if g not in groups: groups[g] = []; order.append(g)
            groups[g].append((p, lines))
        kept, dropped_mkts = [], set()
        for g in order:
            blob = '\n'.join('\n'.join(l) for _, l in groups[g])
            top = g.split('.')[0]
            reason = None
            if top in ('projects',): reason = 'per-machine trust entries'
            elif g.startswith('hooks.state'): reason = 'per-machine hook trust hashes'
            elif top in ('desktop', 'tui', 'shell_environment_policy'): reason = 'desktop app / machine state'
            elif top == 'marketplaces' and 'source_type = "local"' in blob: reason = 'local marketplace path'; dropped_mkts.add(g.split('.', 1)[1])
            elif self.machine_only(blob) or 'cwd = "."' in blob: reason = 'machine-only (local app or loopback URL)'
            if reason:
                self.drop('codex [%s] (%s)' % (g, reason)); continue
            kept.append(g)
        out_blocks = [([], root)]
        for g in kept:
            if g.startswith('plugins.'):
                mkt = g.split('@')[-1]
                if mkt in dropped_mkts or mkt == 'openai-bundled' or mkt == 'openai-primary-runtime':
                    self.drop('codex [%s] (plugin of a vendor-local marketplace)' % g); continue
            for p, lines in groups[g]:
                new = []
                for line in lines:
                    if g.startswith('mcp_servers.'):
                        line = self.sanitize_toml_line(g.split('.', 1)[1], line)
                    new.append(self.portable(line))
                out_blocks.append((p, new))
        out_blocks = self.keep_fleet_toml(self.o('codex', 'config.toml'), out_blocks)
        write(self.o('codex', 'config.toml'), toml_join(out_blocks))
        self.copy_files(self.p('.codex', 'agents'), self.o('codex', 'agents'))
        def keep_rule(n, text): return True
        self.copy_files(self.p('.codex', 'rules'), self.o('codex', 'rules'), keep_rule)
        # default.rules: keep only portable prefix rules
        rf = self.o('codex', 'rules', 'default.rules')
        if os.path.isfile(rf):
            keep, n_drop = [], 0
            for line in open(rf, encoding='utf-8').read().splitlines():
                if line.startswith('prefix_rule(') and any(x in line for x in RULE_DROP):
                    n_drop += 1; continue
                keep.append(line)
            write(rf, '\n'.join(keep) + '\n')
            if n_drop: self.drop('codex rules/default.rules: %d machine/project-specific prefix rules' % n_drop)
        return len([g for g in kept if g.startswith('mcp_servers.')])

    def sanitize_toml_line(self, server, line):
        def sub(m):
            key, val = m.group(2), m.group(3)
            if key == 'command': return '%s%s%s = "%s"' % (m.group(1), key, m.group(1), self.rewrite_command(val))
            if key in ('url', 'cwd') or key.endswith('_sec'): return m.group(0)
            if SECRET_KEY.search(key) or TOKEN_VALUE.search(val):
                nv = placeholder_for(server, key, val)
                self.placeholders.update(UNRES.findall(nv))
                return '%s%s%s = "%s"' % (m.group(1), key, m.group(1), nv)
            return m.group(0)
        if re.match(r'^\s*env_http_headers\s*=', line): return line   # names of env vars, not secrets
        return re.sub(r'(["\']?)([A-Za-z0-9_-]+)\1\s*=\s*"([^"]*)"', sub, line)

    # --- cursor ---
    def cursor(self):
        data = json.load(open(self.p('.cursor', 'mcp.json')))
        out = {}
        for name, server in sorted(data.get('mcpServers', {}).items()):
            s = self.sanitize_server(name, server, 'cursor')
            if s is not None: out[name] = s
        out = self.keep_fleet_json(self.o('cursor', 'mcp.json'), out)
        write(self.o('cursor', 'mcp.json'), json.dumps({'mcpServers': out}, indent=2) + '\n')
        self.copy_files(self.p('.cursor', 'rules'), self.o('cursor', 'rules'))
        cc = json.load(open(self.p('.cursor', 'cli-config.json')))
        write(self.o('cursor', 'cli-config.json'), self.portable(json.dumps(cc, indent=2) + '\n'))
        if os.path.isfile(self.p('.cursor', 'hooks.json')): self.drop('cursor hooks.json (machine-only)')
        return len(out)

    # --- grok ---
    def grok(self):
        text = open(self.p('.grok', 'config.toml'), encoding='utf-8').read()
        out = [([], [])]
        for p, lines in toml_blocks(text)[1:]:
            if p[0] in ('cli', 'marketplace', 'ui'): out.append((p, [self.portable(l) for l in lines]))
            else: self.drop('grok [%s] (machine state)' % '.'.join(p))
        write(self.o('grok', 'config.toml'), toml_join(out))

    # --- t3code ---
    def t3code(self):
        base = self.p('.t3', 'userdata')
        st = json.load(open(os.path.join(base, 'settings.json')))
        for k in ('projectScriptOverrides', 'projectSettingsOverrides'):
            if st.pop(k, None) is not None: self.drop('t3code settings.%s (per-project IDs, may embed license keys)' % k)
        write(self.o('t3code', 'settings.json'), self.portable(json.dumps(st, indent=2) + '\n'))
        for n in ('client-settings.json', 'keybindings.json'):
            write(self.o('t3code', n), self.portable(json.dumps(json.load(open(os.path.join(base, n))), indent=2) + '\n'))

    # --- skills ---
    def skills(self):
        sources = [('~/.claude/skills', self.p('.claude', 'skills')), ('~/.agents/skills', self.p('.agents', 'skills')),
                   ('~/.codex/skills', self.p('.codex', 'skills')), ('~/.cursor/skills', self.p('.cursor', 'skills'))]
        dst_root = os.path.join(self.out, 'skills')
        os.makedirs(dst_root, exist_ok=True)
        chosen, excluded, rows = {}, [], []
        for label, d in sources:
            if not os.path.isdir(d): continue
            for n in sorted(os.listdir(d)):
                sp = os.path.join(d, n)
                real = os.path.realpath(sp)
                if not os.path.isdir(real): continue
                if n in SKILL_EXCLUDE:
                    if n not in [e[0] for e in excluded]: excluded.append((n, label, SKILL_EXCLUDE[n]))
                    continue
                if not os.path.isfile(os.path.join(real, 'SKILL.md')):
                    if not n.startswith('.'): excluded.append((n, label, 'no SKILL.md'))
                    continue
                src_label = label
                if os.path.islink(sp): src_label = '%s -> %s' % (label, real.replace(self.home, '~'))
                if n in chosen:
                    if tree_digest(real) != chosen[n][1]: chosen[n][2].append('%s differs (not used)' % label)
                    else: chosen[n][2].append(label)
                    continue
                chosen[n] = (real, tree_digest(real), [], src_label)
        for n in sorted(os.listdir(dst_root)):
            if os.path.isdir(os.path.join(dst_root, n)) and n not in chosen: shutil.rmtree(os.path.join(dst_root, n))
        for n, (real, _, also, src_label) in sorted(chosen.items()):
            self.copy_tree(real, os.path.join(dst_root, n))
            rows.append((n, src_label, ', '.join(also)))
        lines = ['# skills/', '',
                 'Default skill set pushed to every node by `harness_apply` into `~/.claude/skills`,',
                 '`~/.agents/skills` (Codex; `~/.codex/skills` becomes a symlink to it) and',
                 '`~/.cursor/skills`. Grok reads `~/.claude/skills` and `~/.cursor/skills` itself.', '',
                 'Generated by `harness_capture` on the master: union of `~/.claude/skills`,',
                 '`~/.agents/skills`, `~/.codex/skills`, `~/.cursor/skills` (symlinks dereferenced;',
                 'on a name collision the first source in that order wins).', '',
                 '| Skill | Source on master | Also present in |', '|---|---|---|']
        for n, s, also in rows: lines.append('| %s | `%s` | %s |' % (n, s, also or '–'))
        lines += ['', '## Excluded', '', '| Name | Seen in | Why |', '|---|---|---|']
        for n, s, why in excluded: lines.append('| %s | `%s` | %s |' % (n, s, why))
        lines += ['', 'Plugin-provided skills (Claude plugins) come from the marketplaces and plugins',
                  'listed in `harness/claude/plugins.txt`, not from this directory. fleeter\'s own',
                  '`fleet` skill (skills/fleet in the fleeter repo) is installed by `fleet apply` as',
                  'well; a `fleet/` directory here replaces it.', '']
        write(os.path.join(dst_root, 'README.md'), '\n'.join(lines))
        return len(rows), len(excluded)

def tree_digest(root):
    h = hashlib.sha256()
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
        for f in sorted(files):
            if f == '.DS_Store': continue
            p = os.path.join(d, f)
            h.update(os.path.relpath(p, root).encode()); h.update(b'\0')
            try: h.update(open(p, 'rb').read())
            except Exception: pass
            h.update(b'\0')
    return h.hexdigest()

def cmd_capture(argv):
    # HOME OUT: OUT is the config repo checkout; harnesses whose config is not
    # present on this machine are skipped (their templates are left as they are).
    (home, out), _ = parse_vars(argv)
    c = Capture(home, out)
    n_claude = n_codex = n_cursor = 0
    if os.path.isfile(c.p('.claude', 'settings.json')): n_claude = c.claude()
    else: c.notes.append('no ~/.claude/settings.json: claude templates not captured')
    if os.path.isfile(c.p('.codex', 'config.toml')): n_codex = c.codex()
    else: c.notes.append('no ~/.codex/config.toml: codex templates not captured')
    if os.path.isfile(c.p('.cursor', 'mcp.json')) and os.path.isfile(c.p('.cursor', 'cli-config.json')): n_cursor = c.cursor()
    else: c.notes.append('no ~/.cursor/{mcp.json,cli-config.json}: cursor templates not captured')
    if os.path.isfile(c.p('.grok', 'config.toml')): c.grok()
    if all(os.path.isfile(os.path.join(c.p('.t3', 'userdata'), n)) for n in ('settings.json', 'client-settings.json', 'keybindings.json')): c.t3code()
    n_sk, n_ex = c.skills()
    print('mcp servers kept: claude=%d codex=%d cursor=%d' % (n_claude, n_codex, n_cursor))
    print('skills imported: %d, excluded: %d' % (n_sk, n_ex))
    print('placeholders: %s' % ' '.join(sorted(c.placeholders)))
    for d in c.dropped: print('dropped: %s' % d)
    for n in c.notes: print('note: %s' % n)
    print('hand-maintained (not touched): %s' % ', '.join(HAND_MAINTAINED))

def cmd_tree_digest(argv):
    (root,), _ = parse_vars(argv); print(tree_digest(root))

CMDS = {'render': cmd_render, 'render-mcp': cmd_render_mcp, 'render-toml': cmd_render_toml,
        'merge-json': cmd_merge_json, 'claude-json': cmd_claude_json, 'scan': cmd_scan,
        'placeholders': cmd_placeholders, 'capture': cmd_capture, 'tree-digest': cmd_tree_digest}
CMDS[sys.argv[1]](sys.argv[2:])
PY
}

# ---------- secret scan ----------

# harness_secret_scan DIR — prints hits (file:line: kind) and a summary; exit 1 on hits.
harness_secret_scan() { harness_py scan "${1:-$(harness_tpl_dir)}"; }

# ---------- capture (master) ----------

harness_capture() (   # subshell: helpers use plain globals (name, s, …); keep them out of the caller
  need python3
  config_dir_require
  log "capturing harness config from $HOME into $FLEET_CONFIG_DIR"
  FLEET_SKILL_EXCLUDE="${FLEET_SKILL_EXCLUDE:-}" FLEET_CAPTURE_MACHINE_ONLY="${FLEET_CAPTURE_MACHINE_ONLY:-}" \
  FLEET_CAPTURE_AGENT_EXCLUDE="${FLEET_CAPTURE_AGENT_EXCLUDE:-}" FLEET_CAPTURE_AGENT_MARKERS="${FLEET_CAPTURE_AGENT_MARKERS:-}" \
  FLEET_CAPTURE_RULE_DROP="${FLEET_CAPTURE_RULE_DROP:-}" \
    harness_py capture "$HOME" "$FLEET_CONFIG_DIR" || die "harness capture failed"
  log "secret scan"
  harness_secret_scan "$(harness_tpl_dir)" || die "secrets or machine paths found in $(harness_tpl_dir)" "fix the capture rules (FLEET_CAPTURE_* in fleet.conf, or lib/harness.sh); never commit"
  harness_secret_scan "$(harness_skills_dir)" || die "secrets or machine paths found in $(harness_skills_dir)" "add the skill to FLEET_SKILL_EXCLUDE in fleet.conf"
  missing=""
  for v in $(harness_py placeholders "$(harness_tpl_dir)"); do
    grep -q "^| \`$v\`" "$(harness_tpl_dir)/SECRETS.md" 2>/dev/null || missing="$missing $v"
  done
  [ -z "$missing" ] || warn "placeholders not documented in $(harness_tpl_dir)/SECRETS.md:$missing"
  ok "harness capture done"
)

# ---------- apply (node) ----------

# _harness_vars_file FILE — template variables (KEY=VALUE lines) for harness_py.
_harness_vars_file() {
  node=$(harness_node_name)
  printf 'HOME=%s\nFLEET_NODE=%s\nFLEET_NODE_NAME=%s\nFLEET_MEMORY_DIR=%s\n' \
    "$HOME" "$node" "$node" "${FLEET_MEMORY_DIR:-$HOME/fleet-memory}" >"$1"
}

# _harness_stage STAGE — render everything into STAGE (mirrors $HOME) and write
# STAGE/.index with lines: <kind> <harness> <relpath> <mode>. kind = file|dir.
# SC2094: `put … <"$f"` reads a template and writes into $stage, never the same file.
# shellcheck disable=SC2094
_harness_stage() {
  stage=$1; tpl=$(harness_tpl_dir); idx="$stage/.index"; : >"$idx"
  _harness_vars_file "$stage/.vars"
  set -- --vars-file "$stage/.vars"
  tmp=$(mktemp "$stage/.tmp.XXXXXX")

  add() { printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >>"$idx"; }
  put() { # put HARNESS RELPATH MODE < content  (reads stdin, writes under $stage: never the same file)
    mkdir -p "$stage/$(dirname "$2")"; cat >"$stage/$2"; chmod "$3" "$stage/$2"; add file "$1" "$2" "$3"
  }

  # --- global instructions: $FLEET_CONFIG_DIR/AGENTS.md (+ per-harness addendum) ---
  if [ -f "$(harness_agents_md)" ]; then
    harness_py render "$(harness_agents_md)" "$tmp" "$@" || die "render $(harness_agents_md)"
    { cat "$tmp"; if [ -f "$tpl/claude/CLAUDE.md" ]; then printf '\n'; harness_py render "$tpl/claude/CLAUDE.md" "$tmp.a" "$@" && cat "$tmp.a"; fi; } | put instructions .claude/CLAUDE.md 0644
    { cat "$tmp"; if [ -f "$tpl/codex/AGENTS.md" ]; then printf '\n'; harness_py render "$tpl/codex/AGENTS.md" "$tmp.a" "$@" && cat "$tmp.a"; fi; } | put instructions .codex/AGENTS.md 0644
    { printf -- '---\ndescription: Fleet global agent instructions (managed by fleet, do not edit)\nalwaysApply: true\n---\n\n'; cat "$tmp"; } | put instructions .cursor/rules/fleet-global.mdc 0644
    # Grok: no global AGENTS.md path in ~/.grok/docs; it reads ~/.claude/CLAUDE.md via [compat.claude] (default on).
  fi

  # --- claude ---
  if [ -d "$tpl/claude" ]; then
    [ -f "$tpl/claude/settings.json" ] && { harness_py render "$tpl/claude/settings.json" "$tmp" "$@" || die "render claude/settings.json"; put claude .claude/settings.json 0600 <"$tmp"; }
    [ -f "$tpl/claude/statusline-command.sh" ] && put claude .claude/statusline-command.sh 0755 <"$tpl/claude/statusline-command.sh"
    for sub in agents commands rules hooks; do
      [ -d "$tpl/claude/$sub" ] || continue
      for f in "$tpl/claude/$sub"/*; do
        [ -f "$f" ] || continue
        m=0644; [ "$sub" = hooks ] && m=0755
        put claude ".claude/$sub/$(basename "$f")" "$m" <"$f"
      done
    done
  fi

  # --- codex ---
  if [ -d "$tpl/codex" ]; then
    if [ -f "$tpl/codex/config.toml" ]; then
      harness_py render-toml "$tpl/codex/config.toml" "$HOME/.codex/config.toml" "$tmp" --keep hooks.state "$@" || die "render codex/config.toml"
      put codex .codex/config.toml 0600 <"$tmp"
    fi
    for sub in agents rules; do
      [ -d "$tpl/codex/$sub" ] || continue
      for f in "$tpl/codex/$sub"/*; do [ -f "$f" ] && put codex ".codex/$sub/$(basename "$f")" 0644 <"$f"; done
    done
  fi

  # --- cursor ---
  if [ -d "$tpl/cursor" ]; then
    if [ -f "$tpl/cursor/mcp.json" ]; then
      d=$(mktemp -d "$stage/.mcp.XXXXXX")
      harness_py render-mcp "$tpl/cursor/mcp.json" "$d" "$@" >/dev/null || die "render cursor/mcp.json"
      put cursor .cursor/mcp.json 0600 <"$d/all.json"; rm -rf "$d"
    fi
    [ -f "$tpl/cursor/cli-config.json" ] && { harness_py render "$tpl/cursor/cli-config.json" "$tmp" "$@" || die "render cursor/cli-config.json"; put cursor .cursor/cli-config.json 0644 <"$tmp"; }
    [ -d "$tpl/cursor/rules" ] && for f in "$tpl/cursor/rules"/*; do [ -f "$f" ] && put cursor ".cursor/rules/$(basename "$f")" 0644 <"$f"; done
  fi

  # --- grok ---
  if [ -f "$tpl/grok/config.toml" ]; then
    harness_py render-toml "$tpl/grok/config.toml" "$HOME/.grok/config.toml" "$tmp" "$@" || die "render grok/config.toml"
    put grok .grok/config.toml 0644 <"$tmp"
  fi

  # --- t3code (GUI app; skipped in containers) ---
  skip_t3=""
  if fleet_in_container; then case " ${FLEET_TOOLS_SKIP_IN_CONTAINER:-} " in *" t3code "*) skip_t3=1 ;; esac; fi
  if [ -d "$tpl/t3code" ] && [ -z "$skip_t3" ]; then
    for n in settings.json client-settings.json; do
      [ -f "$tpl/t3code/$n" ] || continue
      harness_py merge-json "$tpl/t3code/$n" "$HOME/.t3/userdata/$n" "$tmp" "$@" || die "render t3code/$n"
      put t3code ".t3/userdata/$n" 0644 <"$tmp"
    done
    [ -f "$tpl/t3code/keybindings.json" ] && { harness_py render "$tpl/t3code/keybindings.json" "$tmp" "$@" || die "render t3code/keybindings.json"; put t3code .t3/userdata/keybindings.json 0644 <"$tmp"; }
  fi

  # --- skills: the config repo's, then fleeter's own `fleet` skill unless the
  #     config repo ships a skill of that name (yours wins) ---
  if [ -d "$(harness_skills_dir)" ]; then
    for s in "$(harness_skills_dir)"/*/; do
      [ -f "$s/SKILL.md" ] || continue
      name=$(basename "$s")
      for target in .claude/skills .agents/skills .cursor/skills; do
        mkdir -p "$stage/$target"
        cp -R "$s" "$stage/$target/$name"
        add dir skills "$target/$name" 0755
      done
    done
  fi
  if [ -f "$(harness_builtin_skill)/SKILL.md" ] && [ ! -f "$(harness_skills_dir)/fleet/SKILL.md" ]; then
    for target in $(harness_skill_targets "$stage"); do
      mkdir -p "$stage/$target"
      cp -R "$(harness_builtin_skill)" "$stage/$target/fleet"
      add dir skills "$target/fleet" 0755
    done
  fi
  rm -f "$tmp" "$tmp.a"
  unset -f add put
}

# ---------- fleeter's own agent skill (skills/fleet) ----------

harness_builtin_skill() { echo "$FLEET_ROOT/skills/fleet"; }

# harness_skill_targets [STAGE] — the skill dirs (relative to $HOME) the `fleet`
# skill goes into: one per harness that is present on this machine (its config
# dir exists in $HOME, or STAGE is about to create it) or listed in FLEET_TOOLS.
# Codex reads ~/.agents/skills (~/.codex/skills is a link to it); Grok reads
# the Claude and Cursor dirs itself.
harness_skill_targets() {
  local stage=${1:-} tools=" ${FLEET_TOOLS:-} " claude=0 codex=0 cursor=0 d
  case "$tools" in *" claude "*) claude=1 ;; esac
  case "$tools" in *" codex "*)  codex=1 ;; esac
  case "$tools" in *" cursor "*) cursor=1 ;; esac
  for d in "$HOME" ${stage:+"$stage"}; do
    [ -d "$d/.claude" ] && claude=1
    [ -d "$d/.codex" ] || [ -d "$d/.agents" ] && codex=1
    [ -d "$d/.cursor" ] && cursor=1
  done
  [ "$claude" = 1 ] && echo .claude/skills
  [ "$codex" = 1 ] && echo .agents/skills
  [ "$cursor" = 1 ] && echo .cursor/skills
  return 0
}

# _harness_manifest_add PATH [FILE] — remember a path fleet wrote, once
# (FILE defaults to $FLEET_HOME/manifest, the cleanup list).
_harness_manifest_add() {
  local m=${2:-$FLEET_HOME/manifest}
  if [ -f "$m" ] && grep -qxF "$1" "$m"; then return 0; fi
  mkdir -p "$(dirname "$m")"
  { [ -f "$m" ] && cat "$m" || true; printf '%s\n' "$1"; } | atomic_write "$m" 0600
}

# harness_skill_install — copy skills/fleet into every enabled skill dir of
# this machine (master: `fleet init master`, `fleet skill install`). Idempotent:
# a dir with the same content is left alone; a foreign dir of that name is kept
# once as <dir>.pre-fleet. The paths go into $FLEET_HOME/manifest (cleanup) and
# harness.manifest (ownership). Nodes get the same skill through harness_apply.
harness_skill_install() {
  local src tgt dest r n=0 changed=0
  src=$(harness_builtin_skill)
  [ -f "$src/SKILL.md" ] || { warn "no skill at $src"; return 0; }
  need python3
  for tgt in $(harness_skill_targets); do
    dest="$HOME/$tgt/fleet"
    r=$(_harness_install_dir "$src" "$dest")
    _harness_manifest_add "$dest"
    _harness_manifest_add "$dest" "$FLEET_HOME/harness.manifest"
    n=$((n + 1)); [ -n "$r" ] && changed=$((changed + 1))
  done
  if [ "$n" = 0 ]; then
    log "skill fleet: no harness found here (no ~/.claude, ~/.codex, ~/.agents or ~/.cursor; nothing in FLEET_TOOLS); nothing installed"
  else
    ok "skill fleet: $n dir(s) ($(harness_skill_targets | tr '\n' ' ' | sed 's/ $//'); $changed changed)"
  fi
}

# _harness_install_file SRC DEST MODE — backup_once + atomic_write when content differs. Prints 1 if changed.
_harness_install_file() {
  if [ -f "$2" ] && cmp -s "$1" "$2"; then
    [ "$(_harness_mode "$2")" = "$3" ] || chmod "$3" "$2"
    return 0
  fi
  if [ -e "$2" ] && ! grep -qx "$2" "$FLEET_HOME/harness.manifest" 2>/dev/null; then backup_once "$2"; fi
  atomic_write "$2" "$3" <"$1"
  echo 1
}

# Octal mode of a file as 4 digits (0644), BSD and GNU stat.
_harness_mode() {
  if [ "$(fleet_os)" = macos ]; then m=$(stat -f '%Lp' "$1"); else m=$(stat -c '%a' "$1"); fi
  printf '%04d\n' "$m"
}

# _harness_install_dir SRC DEST — replace DEST with a copy of SRC when the trees differ.
_harness_install_dir() {
  if [ -L "$2" ]; then rm -f "$2"; fi
  if [ -d "$2" ]; then
    if [ "$(harness_py tree-digest "$1")" = "$(harness_py tree-digest "$2")" ]; then return 0; fi
    if ! grep -qx "$2" "$FLEET_HOME/harness.manifest" 2>/dev/null && [ ! -e "$2.pre-fleet" ]; then mv "$2" "$2.pre-fleet"; fi
  fi
  mkdir -p "$(dirname "$2")"
  t=$(mktemp -d "$(dirname "$2")/.fleet.XXXXXX")
  cp -R "$1/." "$t/" && rm -rf "$2" && mv "$t" "$2"
  echo 1
}

harness_apply() (   # subshell: helpers use plain globals (name, s, …); keep them out of the caller
  need python3
  config_dir_require
  tpl=$(harness_tpl_dir)
  [ -d "$tpl" ] || log "no harness/ in $FLEET_CONFIG_DIR: only AGENTS.md and skills/ are rendered"
  mkdir -p "$FLEET_HOME"; chmod 700 "$FLEET_HOME" 2>/dev/null || true
  # shellcheck source=/dev/null
  if [ -f "$FLEET_HOME/secrets.env" ]; then set -a; . "$FLEET_HOME/secrets.env"; set +a; fi
  umask 077
  stage=$(mktemp -d "${TMPDIR:-/tmp}/fleet-harness.XXXXXX")
  log "harness: rendering templates for node $(harness_node_name)"
  _harness_stage "$stage"

  changed=0; count=0
  newman="$stage/.manifest"; : >"$newman"
  while read -r kind _ rel mode; do
    dest="$HOME/$rel"; count=$((count + 1)); echo "$dest" >>"$newman"
    case "$kind" in
      file) r=$(_harness_install_file "$stage/$rel" "$dest" "$mode") ;;
      dir)  r=$(_harness_install_dir "$stage/$rel" "$dest") ;;
    esac
    [ -n "$r" ] && { changed=$((changed + 1)); [ -n "${FLEET_VERBOSE:-}" ] && ok "$rel"; }
  done <"$stage/.index"

  # cleanup: paths harness owned last time that are gone from the template set
  if [ -f "$FLEET_HOME/harness.manifest" ]; then
    while read -r old; do
      [ -n "$old" ] || continue
      grep -qx "$old" "$newman" && continue
      if [ -d "$old" ] && [ ! -L "$old" ]; then rm -rf "$old"; else rm -f "$old"; fi
      warn "removed $old (no longer in the config repo)"
    done <"$FLEET_HOME/harness.manifest"
  fi
  atomic_write "$FLEET_HOME/harness.manifest" 0600 <"$newman"
  { [ -f "$FLEET_HOME/manifest" ] && cat "$FLEET_HOME/manifest"; cat "$newman"; } | awk '!seen[$0]++' | atomic_write "$FLEET_HOME/manifest" 0600
  ok "harness: $count paths, $changed changed"

  # ~/.codex/skills -> ~/.agents/skills (legacy path) unless a real dir exists
  if [ ! -e "$HOME/.codex/skills" ]; then
    mkdir -p "$HOME/.codex" "$HOME/.agents/skills"; ln -s ../.agents/skills "$HOME/.codex/skills"; ok "linked ~/.codex/skills -> ~/.agents/skills"
  elif [ -d "$HOME/.codex/skills" ] && [ ! -L "$HOME/.codex/skills" ]; then
    warn "$HOME/.codex/skills is a real directory; left alone (Codex reads $HOME/.agents/skills)"
  fi

  _harness_claude_mcp "$stage"
  _harness_claude_plugins
  rm -rf "$stage"
)

# Claude user-scope MCP servers live in ~/.claude.json "mcpServers". We edit that
# key in place (atomic, 0600) instead of `claude mcp add-json`, so rendered secrets
# never appear in argv or process listings (docs/SECURITY.md: never in argv).
_harness_claude_mcp() {
  tpl=$(harness_tpl_dir)/claude/mcp.json
  [ -f "$tpl" ] || return 0
  d=$(mktemp -d "$1/.mcp.XXXXXX")
  _harness_vars_file "$d/.vars"
  names=$(harness_py render-mcp "$tpl" "$d" --vars-file "$d/.vars") || die "render claude/mcp.json"
  owned="$FLEET_HOME/harness.claude-mcp"
  r=$(harness_py claude-json "$HOME/.claude.json" "$d/all.json" "$owned") || die "update ~/.claude.json"
  printf '%s\n' "$names" | atomic_write "$owned" 0600
  n=$(printf '%s\n' "$names" | grep -c . || true)
  ok "claude mcp: $n servers ($r)"
  rm -rf "$d"
}

# plugins.txt: `marketplace <name> <source>` and `plugin <name@marketplace> enabled|disabled`.
_harness_claude_plugins() {
  f=$(harness_tpl_dir)/claude/plugins.txt
  [ -f "$f" ] || return 0
  if [ -n "${FLEET_HARNESS_NO_CLI:-}" ]; then warn "FLEET_HARNESS_NO_CLI set; claude plugins not installed"; return 0; fi
  if ! have claude; then warn "claude not installed; plugins not installed"; return 0; fi
  mk=$(claude plugin marketplace list --json 2>/dev/null || true)
  pl=$(claude plugin list --json 2>/dev/null || true)
  while read -r kind name spec; do
    case "$kind" in
      marketplace)
        printf '%s' "$mk" | grep -Fq "\"name\": \"$name\"" && continue
        log "claude plugin marketplace add $spec"
        claude plugin marketplace add "$spec" </dev/null >/dev/null 2>&1 || warn "marketplace add failed: $name"
        ;;
      plugin)
        [ "$spec" = enabled ] || continue
        printf '%s' "$pl" | grep -Fq "\"id\": \"$name\"" && continue
        log "claude plugin install $name"
        claude plugin install "$name" -s user -y </dev/null >/dev/null 2>&1 || warn "plugin install failed: $name"
        ;;
    esac
  done <"$f"
}

# ---------- status ----------

# One line per harness: <name> <ok|drift> <detail>.
harness_status() (   # subshell: helpers use plain globals (name, s, …); keep them out of the caller
  [ -d "$FLEET_CONFIG_DIR" ] || { echo "harness missing no config dir $FLEET_CONFIG_DIR"; return 0; }
  # shellcheck source=/dev/null
  if [ -f "$FLEET_HOME/secrets.env" ]; then set -a; . "$FLEET_HOME/secrets.env"; set +a; fi
  umask 077
  stage=$(mktemp -d "${TMPDIR:-/tmp}/fleet-harness.XXXXXX")
  _harness_stage "$stage" 2>/dev/null
  for h in instructions claude codex cursor grok t3code skills; do
    total=0; bad=""
    while read -r kind name rel _; do
      [ "$name" = "$h" ] || continue
      total=$((total + 1))
      case "$kind" in
        file) [ -f "$HOME/$rel" ] && cmp -s "$stage/$rel" "$HOME/$rel" || bad="$bad $rel" ;;
        dir)  [ -d "$HOME/$rel" ] && [ "$(harness_py tree-digest "$stage/$rel")" = "$(harness_py tree-digest "$HOME/$rel")" ] || bad="$bad $rel" ;;
      esac
    done <"$stage/.index"
    [ "$total" -eq 0 ] && continue
    if [ -z "$bad" ]; then echo "$h ok $total paths"; else echo "$h drift$(echo "$bad" | head -c 200)"; fi
  done
  if [ -f "$FLEET_HOME/harness.claude-mcp" ]; then
    want=$(grep -c . "$FLEET_HOME/harness.claude-mcp" || true)
    have_n=$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1])).get("mcpServers",{})
except Exception: d={}
print(sum(1 for n in open(sys.argv[2]).read().split() if n in d))' "$HOME/.claude.json" "$FLEET_HOME/harness.claude-mcp" 2>/dev/null || echo 0)
    if [ "$want" = "$have_n" ]; then echo "claude-mcp ok $want servers"; else echo "claude-mcp drift $have_n/$want servers in ~/.claude.json"; fi
  fi
  rm -rf "$stage"
)
