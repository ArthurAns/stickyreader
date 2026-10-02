#!/usr/bin/env python3
"""StickyReader relay: a tiny mailbox server (stdlib only).

Kindles sleep most of the time, so they can't talk to each other directly.
Each device polls this relay for notes addressed to it.

  python3 relay.py [--port 8787] [--data relay.json]
"""
import argparse, json, os, secrets, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

CODE_TTL = 600
MAX_TEXT = 2000
LOCK = threading.Lock()
STATE = {"devices": {}, "pending": {}, "messages": [], "next_id": 1}
DATA_PATH = "relay.json"


def save():
    tmp = DATA_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(STATE, f)
    os.replace(tmp, DATA_PATH)


def new_device():
    dev = "d_" + secrets.token_hex(6)
    token = secrets.token_urlsafe(24)
    STATE["devices"][dev] = {"token": token, "peer": None}
    return dev, token


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 16384:
            return {}
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return {}

    def auth(self):
        h = self.headers.get("Authorization", "")
        tok = h[7:] if h.startswith("Bearer ") else ""
        for dev, d in STATE["devices"].items():
            if secrets.compare_digest(d["token"], tok):
                return dev
        return None

    def do_POST(self):
        path = urlparse(self.path).path
        data = self.body()
        with LOCK:
            now = time.time()
            if path == "/pair/create":
                for c in [c for c, p in STATE["pending"].items() if p["exp"] < now]:
                    del STATE["pending"][c]
                dev, token = new_device()
                code = "%06d" % secrets.randbelow(10**6)
                while code in STATE["pending"]:
                    code = "%06d" % secrets.randbelow(10**6)
                STATE["pending"][code] = {"dev": dev, "exp": now + CODE_TTL}
                save()
                return self.reply(200, {"device_id": dev, "token": token, "code": code})
            if path == "/pair/join":
                p = STATE["pending"].pop(str(data.get("code", "")), None)
                if not p or p["exp"] < now:
                    return self.reply(404, {"error": "invalid or expired code"})
                dev, token = new_device()
                STATE["devices"][dev]["peer"] = p["dev"]
                STATE["devices"][p["dev"]]["peer"] = dev
                save()
                return self.reply(200, {"device_id": dev, "token": token})
            if path == "/messages":
                me = self.auth()
                if not me:
                    return self.reply(401, {"error": "unauthorized"})
                peer = STATE["devices"][me]["peer"]
                text = str(data.get("text", "")).strip()[:MAX_TEXT]
                if not peer:
                    return self.reply(409, {"error": "not paired yet"})
                if not text:
                    return self.reply(400, {"error": "empty message"})
                msg = {"id": STATE["next_id"], "to": peer, "text": text, "ts": int(now)}
                STATE["next_id"] += 1
                STATE["messages"].append(msg)
                save()
                return self.reply(200, {"id": msg["id"]})
            if path == "/unpair":
                me = self.auth()
                if not me:
                    return self.reply(401, {"error": "unauthorized"})
                peer = STATE["devices"][me]["peer"]
                STATE["devices"].pop(me, None)
                if peer in STATE["devices"]:
                    STATE["devices"][peer]["peer"] = None
                save()
                return self.reply(200, {})
        self.reply(404, {"error": "not found"})

    def do_GET(self):
        u = urlparse(self.path)
        if u.path != "/messages":
            return self.reply(404, {"error": "not found"})
        with LOCK:
            me = self.auth()
            if not me:
                return self.reply(401, {"error": "unauthorized"})
            after = int(parse_qs(u.query).get("after", ["0"])[0] or 0)
            msgs = [m for m in STATE["messages"] if m["to"] == me and m["id"] > after]
            paired = STATE["devices"][me]["peer"] is not None
            self.reply(200, {"messages": msgs, "paired": paired})


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--data", default="relay.json")
    a = ap.parse_args()
    DATA_PATH = a.data
    if os.path.exists(DATA_PATH):
        STATE.update(json.load(open(DATA_PATH)))
    print("StickyReader relay on %s:%d" % (a.host, a.port))
    ThreadingHTTPServer((a.host, a.port), Handler).serve_forever()
