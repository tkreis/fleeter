"""Secret scan shared by lib/harness.sh (config capture, skills) and
lib/memory_capture.py (agent memories). python3 stdlib only.

scan_text(text, machine_paths=True, allow_ids=False) -> [(line_no, label)]
scan_file(path, ...)                                 -> [(path, line_no, label)]

machine_paths: also flag /Users/<x>/ and /home/<x>/ (config templates must use
${HOME}); off for memories, where machine paths are legitimate content.
allow_ids: let identifier shapes through the generic "long token-like value"
heuristic: git sha1/sha256 hex runs, UUIDs, kebab-case slugs
(project-pro-2065-task-design) and port+path values (8080/api/v1/...).
Memories cite commits, ids, slugs and local URLs, never keys; the named token
patterns above still apply.
"""
import re

SECRET_PATTERNS = [
    ('openai/anthropic key', r'\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}'),
    ('github token', r'\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}'),
    ('github pat', r'\bgithub_pat_[A-Za-z0-9_]{20,}'),
    ('gitlab token', r'\bglpat-[A-Za-z0-9_-]{16,}'),
    ('xai key', r'\bxai-[A-Za-z0-9]{16,}'),
    ('tailscale key', r'\btskey-[A-Za-z0-9-]{10,}'),
    ('aws key id', r'\bAKIA[0-9A-Z]{16}\b'),
    ('jwt', r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'),
    ('context7 key', r'\bctx7sk-[0-9a-fA-F-]{20,}'),
    ('datadog app key', r'\bddapp_[A-Za-z0-9]{20,}'),
    ('langfuse key', r'\b[ps]k-lf-[0-9a-fA-F-]{20,}'),
    ('supabase key', r'\bsb_(?:publishable|secret)_[A-Za-z0-9_-]{16,}'),
    ('slack token', r'\bxox[abpr]-[A-Za-z0-9-]{10,}'),
    ('private key', r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
]
# 32+ char hex/base64 run in a value position (after : or =), with at least 2 digits.
VALUE_RUN = re.compile(r'[:=]\s*["\']?([A-Za-z0-9+/=_-]{32,})')
MACHINE_PATH = re.compile(r'/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/')
HASH_LIKE = re.compile(r'^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$')
SLUG_LIKE = re.compile(r'^[a-z0-9]+(?:-[a-z0-9]+){2,}$')   # lower-case words joined by dashes: a slug, not a key
PORT_PATH = re.compile(r'^\d{2,5}/')                      # "localhost:8080/api/..." after the host's colon
SKIP_DIRS = {'.git', 'node_modules', '__pycache__'}


def scan_text(text, machine_paths=True, allow_ids=False):
    hits = []
    for ln, line in enumerate(text.splitlines(), 1):
        for label, pat in SECRET_PATTERNS:
            if re.search(pat, line):
                hits.append((ln, label))
        for m in VALUE_RUN.finditer(line):
            v = m.group(1)
            if '${' in line[max(0, m.start() - 2):m.end() + 2]:
                continue
            if sum(c.isdigit() for c in v) < 2:
                continue
            if '/' in v and not re.fullmatch(r'[A-Za-z0-9+/=]+', v):
                continue  # path-like
            if allow_ids and (HASH_LIKE.match(v) or SLUG_LIKE.match(v) or PORT_PATH.match(v)):
                continue
            hits.append((ln, 'long token-like value'))
        if machine_paths and MACHINE_PATH.search(line):
            hits.append((ln, 'machine home path'))
    return hits


def scan_file(path, machine_paths=True, allow_ids=False):
    try:
        data = open(path, 'rb').read()
    except Exception:
        return []
    if b'\x00' in data[:4096]:
        return []
    text = data.decode('utf-8', 'replace')
    return [(path, ln, label) for ln, label in scan_text(text, machine_paths, allow_ids)]
