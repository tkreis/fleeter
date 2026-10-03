#!/usr/bin/env python3
"""Fake Tailscale + GitHub API for tests/e2e.sh and tests/master_test.sh.

  fake_api.py PORT LOGFILE DEVICES_JSON [ACL_FILE]

PORT 0 binds a free port and prints it on stdout (master_test.sh captures it).
Every request is appended to LOGFILE as "<METHOD> <path> <body>". Devices for
GET /api/v2/tailnet/-/devices come from DEVICES_JSON (a JSON array) so the test
can make nodes appear and vanish. The policy file served/accepted on
/api/v2/tailnet/-/acl is ACL_FILE when given (starts as the Tailscale default
allow-all if the file does not exist; POST rewrites it), else in memory.

Credentials: bootstrap API access token "tskey-api-kboot-FAKE" (as a user would
paste from the admin console); POST keys with keyType client mints the OAuth
client id "kclientCNTRL" / secret "tskey-client-kclientCNTRL-FAKE", whose token
exchange yields bearer "ts-token". GitHub token "ghtok". A file named
"<DEVICES_JSON>.fail-gh-delete" makes GitHub key DELETEs answer 500 (cleanup
retry tests); "<DEVICES_JSON>.fail-devices" makes the device list answer 500.
Stdlib only, binds 127.0.0.1.
"""
import hashlib
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

port, logfile, devfile = int(sys.argv[1]), sys.argv[2], sys.argv[3]
aclfile = sys.argv[4] if len(sys.argv) > 4 else None
counter = {"gh": 0, "ts": 0}
DEFAULT_ACL = ('// Tailscale default policy (allow-all)\n'
               '{\n  "grants": [{"src": ["*"], "dst": ["*"], "ip": ["*"]},],\n'
               '  "ssh": [{"action": "check", "src": ["autogroup:member"], "dst": ["autogroup:self"],'
               ' "users": ["autogroup:nonroot", "root"]}],\n}\n')
state = {"acl": DEFAULT_ACL, "revoked": set()}
BOOT_RE = re.compile(r"^Bearer tskey-api-(k[A-Za-z0-9]+)-FAKE$")


def acl_text():
    if aclfile and os.path.exists(aclfile):
        return open(aclfile).read()
    return state["acl"]


def acl_store(text):
    if aclfile:
        open(aclfile, "w").write(text)
    state["acl"] = text


def etag_of(text):
    return '"' + hashlib.sha256(text.encode()).hexdigest()[:12] + '"'


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n).decode() if n else ""

    def _send(self, code, obj=None, raw=None, ctype="application/json", extra=None):
        data = raw.encode() if raw is not None else (json.dumps(obj).encode() if obj is not None else b"")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _log(self, body):
        with open(logfile, "a") as f:
            f.write(("%s %s %s" % (self.command, self.path, body.replace("\n", " "))).rstrip() + "\n")

    def _auth(self, want):
        return self.headers.get("Authorization") == "Bearer " + want

    def _boot_id(self):
        m = BOOT_RE.match(self.headers.get("Authorization") or "")
        return m.group(1) if m else None

    def _ts_auth(self):
        if self._auth("ts-token"):
            return True
        kid = self._boot_id()
        return bool(kid) and kid not in state["revoked"]

    def do_POST(self):
        body = self._body()
        p = self.path
        self._log(body + (" If-Match=%s" % self.headers.get("If-Match") if p == "/api/v2/tailnet/-/acl" else ""))
        if p == "/api/v2/oauth/token":
            q = parse_qs(body)
            if q.get("client_id") == ["kclientCNTRL"] and q.get("client_secret") == ["tskey-client-kclientCNTRL-FAKE"]:
                return self._send(200, {"access_token": "ts-token", "token_type": "Bearer", "expires_in": 3600})
            return self._send(401, {"message": "bad client"})
        if p == "/api/v2/tailnet/-/keys":
            if not self._ts_auth():
                return self._send(401, {"message": "unauthorized"})
            d = json.loads(body)
            if d.get("keyType") == "client":
                if not self._boot_id():
                    return self._send(403, {"message": "oauth_keys scope required"})
                if not d.get("scopes") or not d.get("tags"):
                    return self._send(400, {"message": "scopes and tags required"})
                return self._send(200, {"id": "kclientCNTRL", "key": "tskey-client-kclientCNTRL-FAKE",
                                        "keyType": "client", "scopes": d["scopes"], "tags": d["tags"]})
            counter["ts"] += 1
            kid = "k%d" % counter["ts"]
            return self._send(200, {"id": kid, "key": "tskey-auth-%s-FAKE" % kid, "keyType": "auth"})
        if p == "/api/v2/tailnet/-/acl":
            if not self._ts_auth():
                return self._send(401, {"message": "unauthorized"})
            cur = acl_text()
            im = self.headers.get("If-Match")
            if im and im != etag_of(cur):
                return self._send(412, {"message": "If-Match hash mismatch"})
            if not body.strip():
                return self._send(400, {"message": "empty policy"})
            acl_store(body)
            return self._send(200, raw=body, ctype="application/hujson", extra={"ETag": etag_of(body)})
        if p.startswith("/repos/") and p.endswith("/keys"):
            if not self._auth("ghtok"):
                return self._send(401, {"message": "bad credentials"})
            d = json.loads(body)
            if not d.get("key", "").startswith("ssh-"):
                return self._send(422, {"message": "key is invalid"})
            counter["gh"] += 1
            return self._send(201, {"id": counter["gh"], "title": d.get("title"), "read_only": d.get("read_only")})
        self._send(404, {"message": "not found"})

    def do_GET(self):
        self._log("")
        p = self.path
        if p == "/api/v2/tailnet/-/devices":
            if not self._ts_auth():
                return self._send(401, {"message": "unauthorized"})
            if os.path.exists(devfile + ".fail-devices"):
                return self._send(500, {"message": "simulated outage"})
            devs = json.load(open(devfile)) if os.path.exists(devfile) else []
            return self._send(200, {"devices": devs})
        if p == "/api/v2/tailnet/-/acl":
            if not self._ts_auth():
                return self._send(401, {"message": "unauthorized"})
            cur = acl_text()
            return self._send(200, raw=cur, ctype="application/hujson", extra={"ETag": etag_of(cur)})
        if p == "/user":
            if not self._auth("ghtok"):
                return self._send(401, {"message": "bad credentials"})
            return self._send(200, {"login": "example"})
        self._send(404, {"message": "not found"})

    def do_DELETE(self):
        self._log("")
        p = self.path
        if p.startswith("/api/v2/device/") or p.startswith("/api/v2/tailnet/-/keys/"):
            if not self._ts_auth():
                return self._send(401, {"message": "unauthorized"})
            if p.startswith("/api/v2/tailnet/-/keys/"):
                state["revoked"].add(p.rsplit("/", 1)[1])
            return self._send(200)
        if p.startswith("/repos/") and "/keys/" in p:
            if not self._auth("ghtok"):
                return self._send(401, {"message": "bad credentials"})
            if os.path.exists(devfile + ".fail-gh-delete"):
                return self._send(500, {"message": "simulated outage"})
            return self._send(204)
        self._send(404, {"message": "not found"})


srv = HTTPServer(("127.0.0.1", port), H)
if port == 0:
    print(srv.server_address[1], flush=True)
srv.serve_forever()
