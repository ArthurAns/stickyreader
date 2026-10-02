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
MAX_DEVICES = 2         # a private relay for one couple: at most 2 devices at a time
KEEP_MESSAGES = 500     # oldest notes are dropped beyond this
RATE = {}               # (client ip, kind) -> [timestamps]
LOCK = threading.Lock()
STATE = {"devices": {}, "pending": {}, "messages": [], "next_id": 1}
DATA_PATH = "relay.json"


def save():
    tmp = DATA_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(STATE, f)
    os.replace(tmp, DATA_PATH)


def too_many(ip, kind, limit, window):
    now = time.time()
    hits = [t for t in RATE.get((ip, kind), []) if now - t < window]
    RATE[(ip, kind)] = hits
    return len(hits) >= limit


def record(ip, kind):
    RATE.setdefault((ip, kind), []).append(time.time())


def expire_pending(now):
    """Drop expired pairing codes and the half-created devices that owned them."""
    for code in [c for c, p in STATE["pending"].items() if p["exp"] < now]:
        dev = STATE["pending"].pop(code)["dev"]
        if dev in STATE["devices"] and STATE["devices"][dev]["peer"] is None:
            del STATE["devices"][dev]


def release(dev):
    """Remove a device and detach its peer. Call with LOCK held."""
    d = STATE["devices"].pop(dev, None)
    if d and d["peer"] in STATE["devices"]:
        STATE["devices"][d["peer"]]["peer"] = None


def new_device():
    dev = "d_" + secrets.token_hex(6)
    token = secrets.token_urlsafe(24)
    STATE["devices"][dev] = {"token": token, "peer": None}
    return dev, token


PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>StickyReader</title><style>
body{font-family:-apple-system,system-ui,sans-serif;margin:0;padding:16px;background:#fafafa;color:#111}
textarea{width:100%;box-sizing:border-box;height:40vh;font-size:20px;padding:12px;border:2px solid #111;border-radius:12px}
button{width:100%;margin-top:12px;padding:16px;font-size:20px;border:0;border-radius:12px;background:#111;color:#fff}
#s{margin-top:12px;min-height:1.4em}
@media(prefers-color-scheme:dark){body{background:#111;color:#eee}textarea{background:#222;color:#eee;border-color:#eee}button{background:#eee;color:#111}}
</style></head><body><h2>Note for your partner's e-reader</h2>
<textarea id="t" maxlength="2000" placeholder="Write something sweet..." autofocus></textarea>
<button id="b">Send</button><div id="s"></div>
<script>
const b=document.getElementById('b'),t=document.getElementById('t'),s=document.getElementById('s');
b.onclick=async()=>{const text=t.value.trim();if(!text)return;b.disabled=true;s.textContent='Sending...';
try{const r=await fetch('send',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({text})});
const j=await r.json();if(r.ok){s.textContent='Sent \u2713';t.value=''}else s.textContent=j.error||'Error'}
catch(e){s.textContent='Network error'}b.disabled=false};
</script></body></html>"""


def queue_message(me, text):
    """Store a note from device `me` for its peer. Returns (code, obj). Call with LOCK held."""
    peer = STATE["devices"][me]["peer"]
    text = str(text).strip()[:MAX_TEXT]
    if not peer:
        return 409, {"error": "not paired yet"}
    if not text:
        return 400, {"error": "empty message"}
    msg = {"id": STATE["next_id"], "to": peer, "text": text, "ts": int(time.time())}
    STATE["next_id"] += 1
    STATE["messages"].append(msg)
    del STATE["messages"][:-KEEP_MESSAGES]
    save()
    return 200, {"id": msg["id"]}


def device_for_phone(token):
    for dev, d in STATE["devices"].items():
        if d.get("phone") and secrets.compare_digest(d["phone"], token):
            return dev
    return None


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

    def ip(self):
        # Behind the Cloudflare tunnel the real client is in CF-Connecting-IP.
        return self.headers.get("CF-Connecting-IP") or self.client_address[0]

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
                ip = self.ip()
                expire_pending(now)
                if too_many(ip, "create", 10, 3600):
                    return self.reply(429, {"error": "too many attempts, try later"})
                old = self.auth()
                if old:
                    release(old)
                if len(STATE["devices"]) >= MAX_DEVICES:
                    return self.reply(403, {"error": "relay is full (max %d devices)" % MAX_DEVICES})
                record(ip, "create")
                dev, token = new_device()
                code = "%06d" % secrets.randbelow(10**6)
                while code in STATE["pending"]:
                    code = "%06d" % secrets.randbelow(10**6)
                STATE["pending"][code] = {"dev": dev, "exp": now + CODE_TTL}
                save()
                return self.reply(200, {"device_id": dev, "token": token, "code": code})
            if path == "/pair/join":
                ip = self.ip()
                expire_pending(now)
                if too_many(ip, "join_fail", 10, 600):
                    return self.reply(429, {"error": "too many wrong codes, try later"})
                p = STATE["pending"].pop(str(data.get("code", "")), None)
                if not p:
                    record(ip, "join_fail")
                    return self.reply(404, {"error": "invalid or expired code"})
                old = self.auth()
                if old and old != p["dev"]:
                    release(old)
                if len(STATE["devices"]) >= MAX_DEVICES:
                    STATE["pending"][str(data.get("code", ""))] = p
                    return self.reply(403, {"error": "relay is full (max %d devices)" % MAX_DEVICES})
                dev, token = new_device()
                STATE["devices"][dev]["peer"] = p["dev"]
                STATE["devices"][p["dev"]]["peer"] = dev
                save()
                return self.reply(200, {"device_id": dev, "token": token})
            if path == "/messages":
                me = self.auth()
                if not me:
                    return self.reply(401, {"error": "unauthorized"})
                return self.reply(*queue_message(me, data.get("text", "")))
            if path == "/phone/link":
                me = self.auth()
                if not me:
                    return self.reply(401, {"error": "unauthorized"})
                tok = secrets.token_urlsafe(16)
                STATE["devices"][me]["phone"] = tok
                save()
                return self.reply(200, {"path": "/p/" + tok + "/"})
            if path.startswith("/p/") and path.endswith("/send"):
                me = device_for_phone(path.split("/")[2])
                if not me:
                    return self.reply(404, {"error": "link expired, re-link from the e-reader"})
                return self.reply(*queue_message(me, data.get("text", "")))
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
        if u.path.startswith("/p/") and u.path.endswith("/"):
            with LOCK:
                ok = device_for_phone(u.path.split("/")[2]) is not None
            body = PAGE.encode() if ok else b"Link expired. Re-link from the e-reader."
            self.send_response(200 if ok else 404)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
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
    ap.add_argument("--max-devices", type=int, default=MAX_DEVICES)
    ap.add_argument("--reset", action="store_true",
                    help="forget all devices, codes and notes (use if a device was lost)")
    a = ap.parse_args()
    DATA_PATH = a.data
    MAX_DEVICES = a.max_devices
    if os.path.exists(DATA_PATH) and not a.reset:
        STATE.update(json.load(open(DATA_PATH)))
    elif a.reset:
        save()
        print("State reset.")
    print("StickyReader relay on %s:%d" % (a.host, a.port))
    ThreadingHTTPServer((a.host, a.port), Handler).serve_forever()
