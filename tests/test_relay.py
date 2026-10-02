import http.client, json, os, subprocess, sys, tempfile, time, unittest

PORT = 8791
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def call(method, path, body=None, token=None):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    h = {"Authorization": "Bearer " + token} if token else {}
    c.request(method, path, json.dumps(body) if body is not None else None, h)
    r = c.getresponse()
    raw = r.read()
    try:
        return r.status, json.loads(raw)
    except ValueError:
        return r.status, raw.decode()


class RelayTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.proc = subprocess.Popen([sys.executable, os.path.join(ROOT, "server", "relay.py"),
                                      "--port", str(PORT), "--host", "127.0.0.1",
                                      "--data", os.path.join(self.tmp, "r.json")])
        for _ in range(50):
            try:
                call("GET", "/nothing")
                break
            except OSError:
                time.sleep(0.1)

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait()

    def pair(self):
        _, a = call("POST", "/pair/create", {})
        s, b = call("POST", "/pair/join", {"code": a["code"]})
        self.assertEqual(s, 200)
        return a["token"], b["token"]

    def test_send_receive_and_phone(self):
        ta, tb = self.pair()
        self.assertEqual(call("POST", "/messages", {"text": "hi"}, ta)[0], 200)
        _, r = call("GET", "/messages?after=0", token=tb)
        self.assertEqual([m["text"] for m in r["messages"]], ["hi"])
        _, link = call("POST", "/phone/link", {}, ta)
        self.assertEqual(call("POST", link["path"] + "send", {"text": "yo"})[0], 200)
        _, r = call("GET", "/messages?after=1", token=tb)
        self.assertEqual([m["text"] for m in r["messages"]], ["yo"])

    def test_device_limit_and_unpair(self):
        ta, tb = self.pair()
        s, r = call("POST", "/pair/create", {})
        self.assertEqual(s, 403)
        call("POST", "/unpair", {}, ta)
        self.assertEqual(call("POST", "/pair/create", {})[0], 200)

    def test_repair_after_one_side_unpairs(self):
        ta, tb = self.pair()
        call("POST", "/unpair", {}, ta)                      # A unpairs, B keeps its old record
        _, a = call("POST", "/pair/create", {})              # A starts again
        s, b2 = call("POST", "/pair/join", {"code": a["code"]}, tb)  # B re-pairs using its old token
        self.assertEqual(s, 200)
        self.assertEqual(call("POST", "/messages", {"text": "x"}, a["token"])[0], 200)
        _, r = call("GET", "/messages?after=0", token=b2["token"])
        self.assertEqual(len(r["messages"]), 1)

    def test_wrong_code_rate_limit(self):
        for _ in range(10):
            self.assertEqual(call("POST", "/pair/join", {"code": "000000"})[0], 404)
        self.assertEqual(call("POST", "/pair/join", {"code": "000000"})[0], 429)

    def test_auth_required(self):
        self.assertEqual(call("GET", "/messages")[0], 401)


if __name__ == "__main__":
    unittest.main()
