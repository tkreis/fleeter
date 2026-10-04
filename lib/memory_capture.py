#!/usr/bin/env python3
"""Mirror this machine's native agent memories into the shared memory vault.

Run by `fleet memory sync` (lib/node.sh) on nodes and on the master, right
before the vault is committed. python3 stdlib only.

  python3 memory_capture.py --home HOME --dest VAULT/nodes/NAME \
      --sources "claude codex grok" --exclude "GLOB GLOB" --max-kb 256 [--verbose]

Sources (source-relative path -> copy under DEST/<source>/):
  claude  HOME/.claude/projects/<slug>/memory/**/*.md   -> claude/<slug>/...
          A memory dir that is a symlink shared by several project slugs is
          captured once, under the first slug (sorted); the others are listed
          in claude/ALIASES.md as `- `<alias>` -> `<canonical>``.
  codex   HOME/.codex/memories/** (text files)           -> codex/...
  grok    HOME/.grok/memory-v2/**/*.md                   -> grok/...

Every candidate is dropped when it matches an exclude glob (fnmatch against
the source-relative path), is not plain text, is larger than --max-kb, or the
secret scan (lib/secretscan.py) hits; a hit is reported on stdout as
`secret <source>/<relpath>` and the file is never copied. Each DEST/<source>/
is a mirror: files that no longer exist (or are no longer allowed) are deleted
there, nothing outside DEST/<source>/ is touched. Idempotent and quiet when
nothing changed; one `summary <source> files=N copied=N removed=N
skipped_secret=N skipped_size=N skipped_excluded=N` line per source.
"""
import fnmatch
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from secretscan import scan_text  # noqa: E402

BINARY_EXT = ('.sqlite', '.sqlite-wal', '.sqlite-shm', '.db', '.db-wal', '.db-shm', '.lock',
              '.png', '.jpg', '.jpeg', '.gif', '.pdf', '.zip', '.gz', '.tar', '.bin', '.pyc')
ALIASES_NAME = 'ALIASES.md'


def parse_args(argv):
    opts = {'home': os.path.expanduser('~'), 'dest': '', 'sources': 'claude codex grok',
            'exclude': '', 'max_kb': '256', 'verbose': False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--verbose':
            opts['verbose'] = True; i += 1; continue
        key = a[2:].replace('-', '_')
        if key not in opts or i + 1 >= len(argv):
            sys.exit('usage: memory_capture.py --home H --dest D [--sources S] [--exclude G] [--max-kb N] [--verbose]')
        opts[key] = argv[i + 1]; i += 2
    if not opts['dest']:
        sys.exit('memory_capture.py: --dest is required')
    return opts


def is_text(data):
    return b'\x00' not in data[:8192]


def walk_files(root, suffixes):
    """(abs path, rel path) of regular files under root, sorted; dot entries skipped."""
    out = []
    if not os.path.isdir(root):
        return out
    for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith('.'))
        for fn in sorted(filenames):
            if fn.startswith('.'):
                continue
            if suffixes and not fn.lower().endswith(suffixes):
                continue
            p = os.path.join(dirpath, fn)
            if not os.path.isfile(p):
                continue
            out.append((p, os.path.relpath(p, root)))
    return out


def claude_candidates(home):
    """(abs path, source-relative path) for every Claude project memory file,
    plus [(alias slug, canonical slug)] for memory dirs shared through symlinks."""
    base = os.path.join(home, '.claude', 'projects')
    files, aliases, seen_dirs = [], [], {}
    if not os.path.isdir(base):
        return files, aliases
    for slug in sorted(os.listdir(base)):
        mem = os.path.join(base, slug, 'memory')
        if slug.startswith('.') or not os.path.isdir(mem):
            continue
        real = os.path.realpath(mem)
        if real in seen_dirs:
            aliases.append((slug, seen_dirs[real]))
            continue
        seen_dirs[real] = slug
        for p, rel in walk_files(mem, ('.md',)):
            files.append((p, os.path.join(slug, rel)))
    return files, aliases


def collect(source, home):
    if source == 'claude':
        return claude_candidates(home)
    if source == 'codex':
        return walk_files(os.path.join(home, '.codex', 'memories'), ()), []
    if source == 'grok':
        return walk_files(os.path.join(home, '.grok', 'memory-v2'), ('.md',)), []
    return None, []


def desired_tree(source, files, aliases, excludes, max_bytes, counts, hits):
    """rel path -> bytes of what DEST/<source>/ should contain."""
    want, seen_real = {}, set()
    for p, rel in files:
        sp = source + '/' + rel.replace(os.sep, '/')
        if any(fnmatch.fnmatch(rel, g) or fnmatch.fnmatch(sp, g) for g in excludes):
            counts['skipped_excluded'] += 1; continue
        if rel.lower().endswith(BINARY_EXT):
            counts['skipped_excluded'] += 1; continue
        real = os.path.realpath(p)
        if real in seen_real:
            continue
        seen_real.add(real)
        try:
            if os.path.getsize(p) > max_bytes:
                counts['skipped_size'] += 1; continue
            data = open(p, 'rb').read()
        except OSError:
            continue
        if not is_text(data):
            counts['skipped_excluded'] += 1; continue
        if scan_text(data.decode('utf-8', 'replace'), machine_paths=False, allow_ids=True):
            counts['skipped_secret'] += 1; hits.append(sp); continue
        want[rel] = data
    if source == 'claude' and aliases:
        lines = ['# Claude project aliases', '',
                 'These project slugs share one memory directory (a symlink on this machine).',
                 'Their memories are captured once, under the first slug; look there.', '']
        lines += ['- `%s` -> `%s`' % (a, c) for a, c in aliases]
        want[ALIASES_NAME] = ('\n'.join(lines) + '\n').encode('utf-8')
    return want


def mirror(dest_src, want, verbose):
    """Make dest_src hold exactly `want`. Returns (copied, removed)."""
    copied = removed = 0
    existing = {}
    if os.path.isdir(dest_src):
        for dirpath, dirnames, filenames in os.walk(dest_src):
            dirnames[:] = [d for d in dirnames if not d.startswith('.')]
            for fn in filenames:
                p = os.path.join(dirpath, fn)
                if os.path.islink(p) or not os.path.isfile(p):
                    continue
                existing[os.path.relpath(p, dest_src)] = p
    for rel, data in sorted(want.items()):
        p = os.path.join(dest_src, rel)
        try:
            if rel in existing and open(p, 'rb').read() == data:
                continue
        except OSError:
            pass
        os.makedirs(os.path.dirname(p), exist_ok=True)
        tmp = p + '.fleet-tmp'
        with open(tmp, 'wb') as fh:
            fh.write(data)
        os.replace(tmp, p)
        copied += 1
        if verbose:
            print('copied %s' % rel)
    for rel, p in sorted(existing.items()):
        if rel in want:
            continue
        os.remove(p)
        removed += 1
        if verbose:
            print('removed %s' % rel)
    # prune empty dirs bottom-up, dest_src itself included
    if os.path.isdir(dest_src):
        for dirpath, dirnames, filenames in os.walk(dest_src, topdown=False):
            if not os.listdir(dirpath):
                os.rmdir(dirpath)
    return copied, removed


def main(argv):
    o = parse_args(argv)
    home = os.path.abspath(o['home'])
    dest = os.path.abspath(o['dest'])
    excludes = [g for g in o['exclude'].split() if g]
    max_bytes = int(o['max_kb']) * 1024
    rc = 0
    for source in [s for s in o['sources'].split() if s]:
        files, aliases = collect(source, home)
        if files is None:
            print('error unknown source: %s' % source)
            rc = 1
            continue
        counts = {'skipped_secret': 0, 'skipped_size': 0, 'skipped_excluded': 0}
        hits = []
        want = desired_tree(source, files, aliases, excludes, max_bytes, counts, hits)
        copied, removed = mirror(os.path.join(dest, source), want, o['verbose'])
        for sp in hits:
            print('secret %s' % sp)
        print('summary %s files=%d copied=%d removed=%d skipped_secret=%d skipped_size=%d skipped_excluded=%d'
              % (source, len(want), copied, removed, counts['skipped_secret'], counts['skipped_size'], counts['skipped_excluded']))
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
