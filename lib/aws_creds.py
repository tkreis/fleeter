#!/usr/bin/env python3
"""fleet aws: forward AWS SSO role credentials from the master to the nodes.

Python 3 stdlib only. Called by lib/aws.sh on both sides; never run by hand.
The master side keeps everything in memory (stdout to a shell variable, a
pipe into ssh); only the node side writes credentials, to 0600 files.

Facts this rests on (AWS CLI User Guide, 2026-10-05):

* `aws configure export-credentials --profile P --format process` "will
  retrieve AWS credentials using the AWS CLI's credential resolution process"
  and, with `process`, "Display credentials as JSON output, in the schema
  expected by the credential_process config value" (AWS CLI Command
  Reference, configure/export-credentials). A profile whose IAM Identity
  Center session is not logged in fails with a non-zero exit and botocore's
  UnauthorizedSSOTokenError on stderr: "The SSO session associated with this
  profile has expired or is otherwise invalid. To refresh this SSO session
  run aws sso login with the corresponding profile."
  (awscli/botocore/exceptions.py).
* credential_process contract ("Sourcing credentials with an external
  process"): the command "must generate JSON output on STDOUT" of the form
  {"Version": 1, "AccessKeyId": ..., "SecretAccessKey": ..., "SessionToken":
  ..., "Expiration": "<ISO8601>"}; "the Version key must be set to 1"; with
  an Expiration "the credentials are considered temporary credentials and are
  refreshed automatically by rerunning the credential_process command before
  they expire", without one "the CLI assumes that the credentials are
  long-term credentials"; "The external process can return a non-zero return
  code to indicate that an error occurred"; "Do not specify the home folder
  as ~. You must specify the full path", a path with a space goes in double
  quotes; "Ensure that your custom credential tool does not write any secret
  information to StdErr".
* ~/.aws/config layout ("Configuring IAM Identity Center authentication"):
  `[profile X]` with sso_session, sso_account_id, sso_role_name, region,
  output, and `[sso-session X]` with sso_region, sso_start_url,
  sso_registration_scopes; the legacy form keeps sso_start_url/sso_region in
  the profile itself. The session token is cached under ~/.aws/sso/cache and
  never leaves the master: nodes only get the role credentials.

Subcommands:
  select CONFIG ALLOW [NAME...]                 NAME<TAB>ok|refused<TAB>reason per line
  export AWS CONFIG ALLOWED NAME...             bundle JSON on stdout; NAME<TAB>ok|skip<TAB>kind<TAB>detail on stderr
  receive AWS_DIR CONFIG FLEET_BIN              bundle on stdin -> AWS_DIR/<name>.json + the fleet block in CONFIG
  creds AWS_DIR NAME                            credential_process: the stored JSON while valid, else exit 1
  status AWS_DIR                                {"profiles": n, "expires": iso|null, "state": "ok|expired|none"}
  clear AWS_DIR CONFIG                          remove the credentials and the block
"""
import calendar
import configparser
import json
import os
import re
import subprocess
import sys
import time

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@+=,-]{0,127}$")   # a file name and a config section, nothing else
BEGIN = "# >>> fleet aws >>>"
END = "# <<< fleet aws <<<"
SKEW = 120            # seconds before Expiration at which credentials count as expired
MAX_BUNDLE = 1 << 20  # bytes a node reads from the master at most


def now():
    v = os.environ.get("FLEET_NOW_EPOCH")
    return int(v) if v else int(time.time())


def iso_epoch(s):
    """ISO 8601 -> epoch seconds, None when unparsable. Accepts Z, +hh:mm, +hhmm, fractions."""
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(Z|z|[+-]\d{2}:?\d{2})?$",
                 (s or "").strip())
    if not m:
        return None
    y, mo, d, h, mi = (int(x) for x in m.groups()[:5])
    sec = int(m.group(6) or 0)
    try:
        t = calendar.timegm((y, mo, d, h, mi, sec, 0, 0, 0))
    except (ValueError, OverflowError):
        return None
    tz = m.group(7)
    if tz and tz not in ("Z", "z"):
        sign = 1 if tz[0] == "+" else -1
        t -= sign * (int(tz[1:3]) * 3600 + int(tz[-2:]) * 60)
    return t


def epoch_iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def hhmm(t):
    return time.strftime("%H:%M", time.localtime(t))


def err(msg):
    sys.stderr.write(msg + "\n")


# ---------- ~/.aws/config ----------

def read_config(path):
    """{name: {region, output}} for every [profile X] / [default] section (only what
    the nodes' block copies). RawConfigParser: no % interpolation, keys lower-cased."""
    cp = configparser.RawConfigParser(strict=False, allow_no_value=True)
    try:
        with open(path) as fh:
            cp.read_file(fh)
    except (OSError, configparser.Error):
        return {}
    out = {}
    for sec in cp.sections():
        if sec == "default":
            name = "default"
        elif sec.startswith("profile "):
            name = sec[8:].strip()
        else:
            continue
        d = {k: (v or "").strip() for k, v in cp.items(sec)}
        out[name] = {"region": d.get("region") or None, "output": d.get("output") or None}
    return out


def select(cfg_path, allow, want):
    """[(name, 'ok'|'refused', reason)] for the requested names (default: the whole
    allowlist). The allowlist FLEET_AWS_PROFILES is the only way in."""
    cfg = read_config(cfg_path)
    allow_l = allow.split()
    res = []
    for n in (want or allow_l):
        if not NAME_RE.match(n):
            res.append((n, "refused", "invalid profile name"))
        elif n not in allow_l:
            res.append((n, "refused", "not in FLEET_AWS_PROFILES"))
        elif n not in cfg:
            res.append((n, "refused", "no [profile %s] in %s" % (n, cfg_path)))
        else:
            res.append((n, "ok", ""))
    return res


# ---------- master: export ----------

def export(aws, cfg_path, allowed, names):
    """Run export-credentials for every NAME; the bundle goes to stdout only."""
    cfg = read_config(cfg_path)
    bundle = {"v": 1, "allowed": [a for a in allowed.split() if NAME_RE.match(a)], "profiles": {}}
    for n in names:
        if not NAME_RE.match(n):
            err("%s\tskip\terror\tinvalid profile name" % n)
            continue
        try:
            r = subprocess.run([aws, "configure", "export-credentials", "--profile", n, "--format", "process"],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               universal_newlines=True)
        except OSError as e:
            err("%s\tskip\terror\tcannot run %s: %s" % (n, aws, e))
            continue
        if r.returncode != 0:
            lines = [ln.strip() for ln in r.stderr.splitlines() if ln.strip()]
            msg = (lines[-1] if lines else "exit %d" % r.returncode)[:200]
            kind = "login" if re.search(r"sso|token|log ?in", msg, re.I) else "error"
            err("%s\tskip\t%s\t%s" % (n, kind, msg))
            continue
        try:
            creds = json.loads(r.stdout)
        except ValueError:
            err("%s\tskip\terror\tunparsable export-credentials output" % n)
            continue
        if not isinstance(creds, dict) or creds.get("Version") != 1 or not creds.get("AccessKeyId") \
                or not creds.get("SecretAccessKey"):
            err("%s\tskip\terror\tunexpected credential format" % n)
            continue
        exp = iso_epoch(creds.get("Expiration"))
        if exp is None:
            err("%s\tskip\terror\tno Expiration: long-term keys are never forwarded" % n)
            continue
        if exp <= now() + SKEW:
            err("%s\tskip\tlogin\tcredentials expired at %s" % (n, epoch_iso(exp)))
            continue
        meta = cfg.get(n, {})
        bundle["profiles"][n] = {
            "region": meta.get("region"), "output": meta.get("output"),
            "creds": {k: creds[k] for k in ("Version", "AccessKeyId", "SecretAccessKey", "SessionToken", "Expiration")
                      if k in creds},
        }
        err("%s\tok\t-\t%s" % (n, epoch_iso(exp)))
    sys.stdout.write(json.dumps(bundle) + "\n")
    return 0 if bundle["profiles"] else 1


# ---------- node: files and the config block ----------

def write_atomic(path, text, mode):
    d = os.path.dirname(path) or "."
    tmp = os.path.join(d, ".fleet.%d.tmp" % os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def split_block(text):
    """(before, block_lines, after): the text around the fleet block; block_lines is
    None when there is no block. A begin marker without an end counts as the block
    running to the end of the file (never leaves a half marker behind)."""
    lines = text.split("\n")
    try:
        b = lines.index(BEGIN)
    except ValueError:
        return text, None, ""
    try:
        e = lines.index(END, b + 1)
    except ValueError:
        e = len(lines) - 1
    before = "\n".join(lines[:b])
    after = "\n".join(lines[e + 1:])
    return before, lines[b + 1:e], after


SECTION_RE = re.compile(r"^\s*\[\s*(?:profile\s+)?([^\]]+?)\s*\]\s*$")


def section_names(text):
    out = set()
    for ln in text.split("\n"):
        m = SECTION_RE.match(ln)
        if m:
            out.add(m.group(1))
    return out


def block_meta(block_lines):
    """{name: {region, output}} as the current block has them."""
    out, cur = {}, None
    for ln in block_lines or []:
        m = SECTION_RE.match(ln)
        if m:
            cur = m.group(1)
            out[cur] = {}
        elif cur and "=" in ln and not ln.lstrip().startswith("#"):
            k, _, v = ln.partition("=")
            if k.strip() in ("region", "output"):
                out[cur][k.strip()] = v.strip()
    return out


def render_block(entries, fleet_bin):
    proc = '"%s"' % fleet_bin if " " in fleet_bin else fleet_bin
    out = [BEGIN, "# written by `fleet aws receive` (pushed from the master); the credentials live in",
           "# ~/.config/fleet/aws/<profile>.json and expire on their own. Do not edit this block."]
    for name in sorted(entries):
        out.append("[profile %s]" % name)
        out.append("credential_process = %s aws creds %s" % (proc, name))
        for k in ("region", "output"):
            if entries[name].get(k):
                out.append("%s = %s" % (k, entries[name][k]))
    out.append(END)
    return "\n".join(out)


def rewrite_config(cfg_path, entries, fleet_bin):
    """Put the block for ENTRIES into cfg_path (or remove it when empty), leaving
    every other line as it is. Returns True when the file changed."""
    try:
        with open(cfg_path) as fh:
            old = fh.read()
        mode = os.stat(cfg_path).st_mode & 0o777
    except OSError:
        old, mode = "", 0o600
    before, block, after = split_block(old)
    if entries:
        new_block = render_block(entries, fleet_bin)
        if block is None:
            before = old.rstrip("\n")
            after = ""
        parts = [p for p in (before.rstrip("\n"), new_block, after.strip("\n")) if p]
        new = "\n\n".join(parts) + "\n"
    else:
        if block is None:
            return False
        parts = [p for p in (before.rstrip("\n"), after.strip("\n")) if p]
        new = ("\n".join(parts) + "\n") if parts else ""
    if new == old:
        return False
    if not new:
        os.unlink(cfg_path)
        return True
    d = os.path.dirname(cfg_path)
    if d and not os.path.isdir(d):
        os.makedirs(d, mode=0o700)
    write_atomic(cfg_path, new, mode)
    return True


def stored(aws_dir):
    """{name: expiry epoch} of the credential files on this node (unparsable ones excluded)."""
    out = {}
    try:
        names = os.listdir(aws_dir)
    except OSError:
        return out
    for fn in names:
        if not fn.endswith(".json"):
            continue
        n = fn[:-5]
        if not NAME_RE.match(n):
            continue
        try:
            with open(os.path.join(aws_dir, fn)) as fh:
                exp = iso_epoch(json.load(fh).get("Expiration"))
        except (OSError, ValueError, AttributeError):
            continue
        if exp is not None:
            out[n] = exp
    return out


def receive(aws_dir, cfg_path, fleet_bin):
    raw = sys.stdin.read(MAX_BUNDLE + 1)
    if len(raw) > MAX_BUNDLE:
        err("fleet aws receive: bundle too large")
        return 1
    try:
        b = json.loads(raw)
    except ValueError:
        err("fleet aws receive: not a JSON bundle")
        return 1
    if not isinstance(b, dict) or b.get("v") != 1:
        err("fleet aws receive: unknown bundle version")
        return 1
    allowed = [n for n in (b.get("allowed") or []) if isinstance(n, str) and NAME_RE.match(n)]
    profiles = b.get("profiles") or {}
    try:
        with open(cfg_path) as fh:
            cfg_text = fh.read()
    except OSError:
        cfg_text = ""
    before, block, after = split_block(cfg_text)
    own = section_names(before) | section_names(after)      # the user's own profiles: never touched
    os.makedirs(aws_dir, mode=0o700, exist_ok=True)
    os.chmod(aws_dir, 0o700)
    meta = block_meta(block)
    warnings = []
    for name in sorted(profiles):
        p = profiles[name] if isinstance(profiles[name], dict) else {}
        creds = p.get("creds") or {}
        if not isinstance(name, str) or not NAME_RE.match(name):
            warnings.append("profile with an invalid name skipped")
            continue
        if name not in allowed:
            warnings.append("%s: not in the master's allowlist, skipped" % name)
            continue
        if name in own:
            warnings.append("%s: this machine has its own [profile %s] in %s; left alone" % (name, name, cfg_path))
            continue
        if iso_epoch(creds.get("Expiration")) is None or creds.get("Version") != 1:
            warnings.append("%s: no usable Expiration, skipped" % name)
            continue
        write_atomic(os.path.join(aws_dir, name + ".json"), json.dumps(creds, indent=2) + "\n", 0o600)
        meta[name] = {k: p.get(k) for k in ("region", "output") if p.get(k)}
    # what the master no longer allows (or the user now owns) goes, files and block entries alike
    for n in list(stored(aws_dir)) + [fn[:-5] for fn in os.listdir(aws_dir) if fn.endswith(".json")]:
        if n not in allowed or n in own:
            try:
                os.unlink(os.path.join(aws_dir, n + ".json"))
            except OSError:
                pass
    have = stored(aws_dir)
    entries = {n: meta.get(n, {}) for n in have}
    rewrite_config(cfg_path, entries, fleet_bin)
    for w in warnings:
        err("warn " + w)
    if have:
        print("%d profile%s (expire %s)" % (len(have), "" if len(have) == 1 else "s", hhmm(min(have.values()))))
    else:
        print("0 profiles")
    return 0


def creds(aws_dir, name):
    if not NAME_RE.match(name):
        err("fleet: invalid AWS profile name")
        return 1
    try:
        with open(os.path.join(aws_dir, name + ".json")) as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        err("fleet: no AWS credentials for %s on this node; on the master run: fleet aws push (fleet sync pushes them too)" % name)
        return 1
    exp = iso_epoch(d.get("Expiration")) if isinstance(d, dict) else None
    if exp is None or exp <= now() + SKEW:
        err("fleet: AWS credentials for %s expired at %s; on the master run: aws sso login (fleet sync pushes fresh ones)"
            % (name, epoch_iso(exp) if exp is not None else "?"))
        return 1
    sys.stdout.write(json.dumps(d) + "\n")
    return 0


def status(aws_dir):
    have = stored(aws_dir)
    if not have:
        d = {"profiles": 0, "expires": None, "state": "none"}
    else:
        earliest = min(have.values())
        d = {"profiles": len(have), "expires": epoch_iso(earliest),
             "state": "expired" if earliest <= now() + SKEW else "ok"}
    print(json.dumps(d))
    return 0


def clear(aws_dir, cfg_path):
    try:
        for fn in os.listdir(aws_dir):
            os.unlink(os.path.join(aws_dir, fn))
        os.rmdir(aws_dir)
    except OSError:
        pass
    rewrite_config(cfg_path, {}, "")
    return 0


def main(argv):
    if len(argv) < 2:
        err(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "select" and len(args) >= 2:
        for n, st, why in select(args[0], args[1], args[2:]):
            print("%s\t%s\t%s" % (n, st, why))
        return 0
    if cmd == "export" and len(args) >= 4:
        return export(args[0], args[1], args[2], args[3:])
    if cmd == "receive" and len(args) == 3:
        return receive(args[0], args[1], args[2])
    if cmd == "creds" and len(args) == 2:
        return creds(args[0], args[1])
    if cmd == "status" and len(args) == 1:
        return status(args[0])
    if cmd == "clear" and len(args) == 2:
        return clear(args[0], args[1])
    err(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
