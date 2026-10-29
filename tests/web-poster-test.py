#!/usr/bin/env python3
"""scripts/web-serve.py: GET /api/poster/<file> (a picture of the poster folder) and the poster change allowlist."""
import http.client
import importlib.util
import json
import os
import tempfile
import threading
import unittest

CORE = os.environ.get("HS_CORE") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "core")
if not os.path.isfile(os.path.join(CORE, "scripts", "web-serve.py")):
    raise SystemExit("no core checkout: set HS_CORE=<folder of hobnix/server>")
EXT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "extensions")
os.environ["HS_PACKAGES_DIR"] = EXT
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(CORE, "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
os.environ["HS_WEB_QUIET"] = "1"
# the poster calls belong to the extension package "posters": switch it on for the allowlist (declared in extensions/posters/capability.toml)
_caps = tempfile.NamedTemporaryFile("w", suffix=".caps", delete=False)
_caps.write("posters\n")
_caps.close()
os.environ["HS_CAPABILITIES_FILE"] = _caps.name
os.environ["HS_STATE_DIR"] = tempfile.mkdtemp()
ws.ext_refresh(force=True)


class FakeAuth:
    def __init__(self, cfg):
        self.cfg = cfg

    def storage_locked(self):
        return False

    def domain_password_ok(self, user, password):
        return False

    def domain_is_admin(self, user):
        return False

    def local_password_ok(self, user, password):
        return user == "adminuser" and password == "pw"


class Poster(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.dir = os.path.join(self.tmp, "posters")
        os.makedirs(self.dir)
        with open(os.path.join(self.dir, "poster-dune-42.png"), "wb") as f:
            f.write(b"\x89PNG-stand-in")
        with open(os.path.join(self.tmp, "secret.png"), "wb") as f:
            f.write(b"secret")
        os.environ["HS_POSTER_DIR"] = self.dir
        cfg = ws.Config()
        cfg.fail_delay, cfg.hs, cfg.root = 0, "/nonexistent/hs", self.tmp
        self.app = ws.App(cfg, FakeAuth(cfg))
        self.srv = ws.Server(("127.0.0.1", 0), ws.make_handler(self.app))
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("POST", "/api/login", json.dumps({"realm": "local", "user": "adminuser", "password": "pw"}),
                  {"Content-Type": "application/json", "Origin": "http://127.0.0.1:%d" % self.port})
        self.cookie = c.getresponse().getheader("Set-Cookie").split(";")[0]
        c.close()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        os.environ.pop("HS_POSTER_DIR", None)

    def get(self, path, cookie=True):
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request("GET", path, headers={"Cookie": self.cookie} if cookie else {})
        r = c.getresponse()
        body = r.read()
        ctype = r.getheader("Content-Type", "")
        c.close()
        return r.status, ctype, body

    def test_the_picture(self):
        s, ctype, body = self.get("/api/poster/poster-dune-42.png")
        self.assertEqual((s, ctype), (200, "image/png"))
        self.assertTrue(body.startswith(b"\x89PNG"))

    def test_needs_a_session(self):
        self.assertEqual(self.get("/api/poster/poster-dune-42.png", cookie=False)[0], 401)

    def test_names_are_checked(self):
        for p in ("/api/poster/secret.png", "/api/poster/poster-x.txt", "/api/poster/poster-..%2fsecret.png", "/api/poster/%2e%2e/secret.png",
                  "/api/poster/poster-nothere.png", "/api/poster/"):
            self.assertEqual(self.get(p)[0], 404, p)

    def test_a_link_cannot_leave_the_folder(self):
        try:
            os.symlink(os.path.join(self.tmp, "secret.png"), os.path.join(self.dir, "poster-leak.png"))
        except (OSError, NotImplementedError):
            self.skipTest("no symlinks here")
        self.assertEqual(self.get("/api/poster/poster-leak.png")[0], 404)

    def test_allowlist(self):
        ok = [["generate", "--eyebrow", "Movie night", "--title", "Dune"],
              ["generate", "--eyebrow", "a", "--title", "b", "--color", "#12ab9f", "--seed", "42", "--case", "keep"],
              ["delete", "poster-dune-42.png"]]
        bad = [["generate", "--eyebrow", "a\nb", "--title", "b"], ["generate", "--eyebrow", "a", "--title", "b", "--color", "red;x"],
               ["generate", "--out", "/etc"], ["generate", "--eyebrow", "a", "--title", "b", "--seed", "x"], ["delete", "../x.png"],
               ["delete", "secret.png"], ["generate", "--eyebrow", "x" * 81, "--title", "b"]]
        for a in ok:
            self.assertIsNotNone(ws.validate_change({"area": "ext/posters", "args": a}), a)
        for a in bad:
            self.assertIsNone(ws.validate_change({"area": "ext/posters", "args": a}), a)

    def test_the_drawing_is_reported(self):
        d = ws.parse_change("status\tdone\nfile\tposter-dune-42.png\ncolor\tteal\nseed\t42\nsize\t1600x900\n", 0)
        self.assertEqual((d["status"], d["file"], d["seed"], d["color"]), ("done", "poster-dune-42.png", "42", "teal"))


if __name__ == "__main__":
    unittest.main()
