#!/usr/bin/env python3
"""Tailscale + GitHub REST helper for lib/master.sh. Python 3 stdlib only.

Credentials are read from the vault files directly so that no secret ever
appears in argv or in a process listing:

  $FLEET_VAULT/tailscale.json   {"oauth_client_id","oauth_client_secret","tailnet":"-"}
  $FLEET_VAULT/github.json      {"token"}            (fallback when `gh` is absent)
  $FLEET_TS_BOOTSTRAP_FILE      one line: a tskey-api-... access token; when set it
                                is used as the Bearer token instead of the OAuth
                                client (fleet init master / fleet policy apply)

Base URLs are overridable for tests: FLEET_TS_API, FLEET_GH_API.

Verified API facts (2026-10-03, Tailscale API v2 OpenAPI https://api.tailscale.com/api/v2
via Context7 /openapi/api_tailscale_api_v2 unless noted):
- Auth: "Authorization: Bearer <tskey-api-...>" or an access token minted from an
  OAuth client. Personal access tokens come from the admin console Keys page
  (https://login.tailscale.com/admin/settings/keys), expiry 1-90 days.
- OAuth token exchange: POST /api/v2/oauth/token, form client_id/client_secret ->
  {"access_token","token_type":"Bearer","expires_in"}. https://tailscale.com/kb/1215
- Create key: POST /api/v2/tailnet/{tailnet}/keys. keyType "auth" (body
  {"description","expirySeconds","capabilities":{"devices":{"create":{"reusable",
  "ephemeral","preauthorized","tags"}}}}) or keyType "client" = OAuth client (body
  {"description","scopes":[...],"tags":[...]}; "tags" mandatory when scopes include
  auth_keys or devices:core). Response {"id","key",...}; "key" (tskey-client-... for
  clients) is only returned at creation. "The identity of the key is embedded in
  the key itself" -> tskey-<type>-<id>-<secret>. Scopes: auth_keys / oauth_keys.
  Delete key: DELETE /api/v2/tailnet/{tailnet}/keys/{keyId} -> 200.
  List devices: GET /api/v2/tailnet/{tailnet}/devices -> {"devices":[...]}.
  Delete device: DELETE /api/v2/device/{deviceId} -> 200. Scope: devices:core.
- Policy file: GET /api/v2/tailnet/{tailnet}/acl returns JSON or HuJSON per the
  Accept header plus an ETag header (scope policy_file:read).
  POST /api/v2/tailnet/{tailnet}/acl accepts HuJSON or JSON, optional If-Match
  set to that ETag (412 on mismatch, 400 on validation/test errors), returns the
  updated policy (scope policy_file).
- GitHub deploy keys: POST /repos/{owner}/{repo}/keys {"title","key","read_only"}
  -> 201 {"id",...}; DELETE /repos/{owner}/{repo}/keys/{key_id} -> 204.
  Headers: Authorization: Bearer, Accept: application/vnd.github+json,
  X-GitHub-Api-Version. Source: https://docs.github.com/en/rest/deploy-keys/deploy-keys

Usage:
  api.py ts check                       token exchange only; prints "ok"
  api.py ts key-create DESC EPHEMERAL TAG [EXPIRY_SECONDS]
                                        prints "<id> <key>" on one line
  api.py ts key-delete KEY_ID           404 counts as deleted
  api.py ts devices                     prints the devices JSON array
  api.py ts device-delete NODE_ID       404 counts as deleted
  api.py ts acl-get OUTFILE             writes the live HuJSON policy (0600), prints the ETag
  api.py ts acl-set ETAG                policy on stdin; POST with If-Match: ETAG
  api.py ts client-create DESC TAG SCOPE...   (bootstrap token) creates an OAuth
                                        client and writes vault/tailscale.json
  api.py ts bootstrap-revoke            deletes the token in FLEET_TS_BOOTSTRAP_FILE
  api.py policy check TEMPLATE LIVE TAG offline; exit 1 with findings on stderr
  api.py policy diff TEMPLATE LIVE      offline unified diff (live -> template)
  api.py gh user                        prints the token owner's login
  api.py gh key-create OWNER/REPO TITLE READONLY   (public key on stdin) prints id
  api.py gh key-delete OWNER/REPO KEY_ID   404 counts as deleted
"""
import difflib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 30
GH_API_VERSION = "2022-11-28"


def vault():
    v = os.environ.get("FLEET_VAULT")
    if not v:
        home = os.environ.get("FLEET_HOME") or os.path.join(os.path.expanduser("~"), ".config", "fleet")
        v = os.path.join(home, "vault")
    return v


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        fail("missing %s (run: fleet init master)" % path)
    except ValueError as e:
        fail("invalid JSON in %s: %s" % (path, e))


def fail(msg, code=1):
    sys.stderr.write("api: %s\n" % msg)
    sys.exit(code)


def write_private(path, text):
    """0600 file via tmp + rename in the same directory."""
    tmp = path + ".tmp.%d" % os.getpid()
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def request_raw(method, url, headers=None, data=None, form=None, raw_body=None, expect=(200, 201, 204)):
    """Returns (status, headers, bytes). Exits on HTTP/URL errors."""
    hdrs = {"User-Agent": "fleet/0.1"}
    if headers:
        hdrs.update(headers)
    body = None
    if form is not None:
        body = urllib.parse.urlencode(form).encode()
        hdrs["Content-Type"] = "application/x-www-form-urlencoded"
    elif raw_body is not None:
        body = raw_body if isinstance(raw_body, bytes) else raw_body.encode()
    elif data is not None:
        body = json.dumps(data).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            status = resp.status
            rhdrs = dict(resp.headers.items())
            raw = resp.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        if e.code in expect:
            return e.code, dict(e.headers.items()), raw
        try:
            msg = json.loads(raw.decode()).get("message", "")
        except Exception:
            msg = raw.decode(errors="replace")[:200]
        fail("%s %s -> HTTP %d %s" % (method, redact(url), e.code, msg))
    except urllib.error.URLError as e:
        fail("%s %s -> %s" % (method, redact(url), e.reason))
    if status not in expect:
        fail("%s %s -> unexpected HTTP %d" % (method, redact(url), status))
    return status, rhdrs, raw


def request(method, url, headers=None, data=None, form=None, expect=(200, 201, 204)):
    _, _, raw = request_raw(method, url, headers, data, form, expect=expect)
    if not raw:
        return None
    try:
        return json.loads(raw.decode())
    except ValueError:
        return None


def redact(url):
    return url.split("?", 1)[0]


# ---------- HuJSON (comments + trailing commas), enough for policy files ----------

def hujson_loads(text):
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j; continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2; continue
        out.append(c); i += 1
    s = re.sub(r",(\s*[\]}])", r"\1", "".join(out))
    return json.loads(s)


# ---------- Tailscale ----------

def ts_base():
    return os.environ.get("FLEET_TS_API", "https://api.tailscale.com").rstrip("/")


def ts_token(creds):
    cid = creds.get("oauth_client_id", "")
    sec = creds.get("oauth_client_secret", "")
    if not cid or not sec:
        fail("tailscale.json lacks oauth_client_id/oauth_client_secret")
    tok = request("POST", ts_base() + "/api/v2/oauth/token",
                  form={"client_id": cid, "client_secret": sec})
    if not tok or "access_token" not in tok:
        fail("oauth token exchange returned no access_token")
    return tok["access_token"]


def bootstrap_token():
    """The one-off tskey-api token from FLEET_TS_BOOTSTRAP_FILE, or None."""
    p = os.environ.get("FLEET_TS_BOOTSTRAP_FILE")
    if not p:
        return None
    try:
        with open(p) as f:
            t = f.readline().strip()
    except OSError:
        fail("cannot read FLEET_TS_BOOTSTRAP_FILE")
    if not t.startswith("tskey-api-"):
        fail("bootstrap token does not look like a Tailscale API access token (tskey-api-...)")
    return t


def ts_auth():
    """(bearer token, tailnet) from the bootstrap token or the vault's OAuth client."""
    boot = bootstrap_token()
    if boot:
        return boot, "-"
    creds = load_json(os.path.join(vault(), "tailscale.json"))
    return ts_token(creds), (creds.get("tailnet") or "-")


def ts_cmd(args):
    sub = args[0] if args else ""
    base = ts_base() + "/api/v2"
    if sub == "bootstrap-revoke":
        tok = bootstrap_token() or fail("FLEET_TS_BOOTSTRAP_FILE not set")
        parts = tok.split("-")           # tskey-api-<id>-<secret>
        kid = parts[2] if len(parts) >= 4 else ""
        if not kid:
            fail("cannot derive the key id from the token; revoke it at https://login.tailscale.com/admin/settings/keys")
        request("DELETE", "%s/tailnet/-/keys/%s" % (base, urllib.parse.quote(kid)),
                {"Authorization": "Bearer " + tok}, expect=(200, 204, 404))
        print("ok")
        return
    token, tailnet = ts_auth()
    h = {"Authorization": "Bearer " + token}
    if sub == "check":
        print("ok")
    elif sub == "key-create":
        if len(args) < 4:
            fail("usage: ts key-create DESC EPHEMERAL TAG [EXPIRY]")
        desc, ephemeral, tag = args[1], args[2] == "true", args[3]
        expiry = int(args[4]) if len(args) > 4 else 3600
        body = {
            "keyType": "auth",
            "description": desc[:50],
            "expirySeconds": expiry,
            "capabilities": {"devices": {"create": {
                "reusable": False, "ephemeral": ephemeral,
                "preauthorized": True, "tags": [tag]}}},
        }
        r = request("POST", "%s/tailnet/%s/keys" % (base, tailnet), h, data=body)
        if not r or "key" not in r:
            fail("key create returned no key")
        print("%s %s" % (r.get("id", ""), r["key"]))
    elif sub == "client-create":
        if len(args) < 4:
            fail("usage: ts client-create DESC TAG SCOPE...")
        desc, tag, scopes = args[1], args[2], args[3:]
        body = {"keyType": "client", "description": desc[:50], "scopes": scopes, "tags": [tag]}
        r = request("POST", "%s/tailnet/%s/keys" % (base, tailnet), h, data=body)
        if not r or "key" not in r or not r.get("id"):
            fail("client create returned no id/key")
        write_private(os.path.join(vault(), "tailscale.json"),
                      json.dumps({"oauth_client_id": r["id"], "oauth_client_secret": r["key"],
                                  "tailnet": tailnet}) + "\n")
        print(r["id"])
    elif sub == "key-delete":
        request("DELETE", "%s/tailnet/%s/keys/%s" % (base, tailnet, urllib.parse.quote(args[1])), h,
                expect=(200, 204, 404))
    elif sub == "devices":
        r = request("GET", "%s/tailnet/%s/devices" % (base, tailnet), h) or {}
        print(json.dumps(r.get("devices", [])))
    elif sub == "device-delete":
        request("DELETE", "%s/device/%s" % (base, urllib.parse.quote(args[1])), h, expect=(200, 204, 404))
    elif sub == "acl-get":
        if len(args) < 2:
            fail("usage: ts acl-get OUTFILE")
        hh = dict(h); hh["Accept"] = "application/hujson"
        _, rh, raw = request_raw("GET", "%s/tailnet/%s/acl" % (base, tailnet), hh)
        write_private(args[1], raw.decode())
        print(rh.get("ETag") or rh.get("Etag") or "")
    elif sub == "acl-set":
        etag = args[1] if len(args) > 1 else ""
        body = sys.stdin.read()
        if not body.strip():
            fail("empty policy on stdin")
        hh = dict(h); hh["Accept"] = "application/hujson"; hh["Content-Type"] = "application/hujson"
        if etag:
            hh["If-Match"] = etag
        request_raw("POST", "%s/tailnet/%s/acl" % (base, tailnet), hh, raw_body=body)
        print("ok")
    else:
        fail("unknown ts subcommand: %s" % sub)


# ---------- policy (offline) ----------

# Sources that cover tagged devices (so a fleet node) when used as src.
# autogroup:member is NOT in this list: it means user-owned devices only and
# the template relies on it for the owner -> node SSH grant.
WILDCARD_SRC = ("*", "autogroup:tagged", "autogroup:danger-all")
# The only src forms a rule may use (besides the hard-rejected ones above) are
# explicit people: a user login, a group, or these user-only autogroups. An IP,
# a CIDR, a host alias from "hosts", another tag or any other autogroup might
# cover a fleet node's address, so such a rule is rejected unless every dst is
# tag:fleet-node itself (reaching the nodes is allowed, reaching out is not).
USER_AUTOGROUPS = ("autogroup:member", "autogroup:admin", "autogroup:owner")


def norm_rule(r):
    return json.dumps({k: sorted(v) if isinstance(v, list) else v for k, v in r.items()}, sort_keys=True)


def src_is_person(s):
    """True for a user login (contains @), a group:..., or a user-only autogroup."""
    return "@" in s or s.startswith("group:") or s in USER_AUTOGROUPS


def dst_only_tag(dsts, tag):
    """True when every dst is the fleet tag (grants: tag; acls: tag:port)."""
    return bool(dsts) and all(d == tag or d.startswith(tag + ":") for d in dsts)


def policy_check(template_path, live_path, tag):
    tpl = hujson_loads(open(template_path).read())
    try:
        live = hujson_loads(open(live_path).read())
    except ValueError as e:
        return ["live policy is not valid HuJSON: %s" % e]
    problems = []
    live_owners = live.get("tagOwners") or {}
    for t, owners in (tpl.get("tagOwners") or {}).items():
        if sorted(live_owners.get(t) or []) != sorted(owners):
            problems.append("tagOwners[%s] missing or differs (want %s)" % (t, json.dumps(owners)))
    live_grants = [norm_rule(g) for g in (live.get("grants") or [])]
    for g in tpl.get("grants") or []:
        if norm_rule(g) not in live_grants:
            problems.append("grant missing: %s" % json.dumps(g, sort_keys=True))
    bad = set(WILDCARD_SRC) | {tag}
    rules = [("grants", g) for g in (live.get("grants") or [])]
    rules += [("acls", a) for a in (live.get("acls") or []) if (a.get("action") or "accept") == "accept"]
    rules += [("ssh", s) for s in (live.get("ssh") or [])]
    for where, r in rules:
        srcs = [s for s in (r.get("src") or []) if isinstance(s, str)]
        hit = [s for s in srcs if s in bad]
        if hit:
            problems.append("%s rule lets %s reach the tailnet: %s" % (where, "/".join(hit), json.dumps(r, sort_keys=True)))
            continue
        vague = [s for s in srcs if not src_is_person(s)]
        if vague and not dst_only_tag([d for d in (r.get("dst") or []) if isinstance(d, str)], tag):
            problems.append("%s rule has a src that is not a user, group or user autogroup (%s) and a dst other than %s: %s"
                            % (where, "/".join(vague), tag, json.dumps(r, sort_keys=True)))
    return problems


def policy_cmd(args):
    sub = args[0] if args else ""
    if sub == "check":
        if len(args) < 4:
            fail("usage: policy check TEMPLATE LIVE TAG")
        problems = policy_check(args[1], args[2], args[3])
        for p in problems:
            sys.stderr.write("policy: %s\n" % p)
        sys.exit(1 if problems else 0)
    elif sub == "diff":
        if len(args) < 3:
            fail("usage: policy diff TEMPLATE LIVE")
        a = open(args[2]).read().splitlines(True)
        b = open(args[1]).read().splitlines(True)
        sys.stdout.writelines(difflib.unified_diff(a, b, "live policy", "templates/tailscale-policy.hujson"))
    else:
        fail("unknown policy subcommand: %s" % sub)


# ---------- GitHub (token fallback; lib/master.sh prefers `gh api`) ----------

def gh_cmd(args):
    creds = load_json(os.path.join(vault(), "github.json"))
    token = creds.get("token", "")
    if not token:
        fail("github.json lacks token")
    h = {"Authorization": "Bearer " + token,
         "Accept": "application/vnd.github+json",
         "X-GitHub-Api-Version": GH_API_VERSION}
    base = os.environ.get("FLEET_GH_API", "https://api.github.com").rstrip("/")
    sub = args[0] if args else ""
    if sub == "user":
        r = request("GET", base + "/user", h) or {}
        print(r.get("login", ""))
    elif sub == "key-create":
        if len(args) < 4:
            fail("usage: gh key-create OWNER/REPO TITLE READONLY < pubkey")
        repo, title, ro = args[1], args[2], args[3] == "true"
        pub = sys.stdin.read().strip()
        if not pub.startswith("ssh-"):
            fail("stdin does not look like an SSH public key")
        r = request("POST", "%s/repos/%s/keys" % (base, repo), h,
                    data={"title": title, "key": pub, "read_only": ro})
        if not r or "id" not in r:
            fail("deploy key create returned no id")
        print(r["id"])
    elif sub == "key-delete":
        request("DELETE", "%s/repos/%s/keys/%s" % (base, args[1], args[2]), h, expect=(200, 204, 404))
    else:
        fail("unknown gh subcommand: %s" % sub)


def main(argv):
    if len(argv) < 2:
        fail(__doc__.strip())
    if argv[0] == "ts":
        ts_cmd(argv[1:])
    elif argv[0] == "gh":
        gh_cmd(argv[1:])
    elif argv[0] == "policy":
        policy_cmd(argv[1:])
    else:
        fail("unknown api: %s" % argv[0])


if __name__ == "__main__":
    main(sys.argv[1:])
