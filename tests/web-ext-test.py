#!/usr/bin/env python3
"""The web interface (scripts/web-serve.py of the core) as it sees the packages of this repository while they are on: the reads, changes and
pages games, posters and passthrough declare, and what the changes refuse."""
import importlib.util
import os
import re
import shutil
import tempfile
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


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


class RealPackages(unittest.TestCase):
    """games, posters and passthrough, as the web interface sees them while they are on"""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["HS_PACKAGES_DIR"] = EXT
        self.caps = os.path.join(self.tmp, "caps")
        os.environ["HS_CAPABILITIES_FILE"] = self.caps
        os.environ["HS_STATE_DIR"] = os.path.join(self.tmp, "state")
        write(self.caps, "games\nposters\ngateway\npassthrough\n")
        ws.ext_refresh(force=True)

    def tearDown(self):
        write(self.caps, "")
        ws.ext_refresh(force=True)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def ok(self, area, args, stdin=None):
        return ws.validate_change({"area": area, "args": args, "stdin": stdin}) is not None

    def test_games(self):
        for words, ttl in ((("ext", "games", "list"), 30), (("ext", "games", "state"), 15)):
            self.assertEqual(ws.READS[words], {"kind": "tsv", "ttl": ttl})
        self.assertTrue(self.ok("ext/games", ["gaming-pc", "wake"]))
        self.assertTrue(self.ok("ext/games", ["gaming", "remove"]))
        self.assertTrue(self.ok("ext/games", ["gaming", "add", "--ip", "10.10.10.50", "--mac", "aa:bb:cc:dd:ee:ff"]))
        for bad in (["gaming", "sleep"], ["-x", "wake"], ["gaming", "add", "--mac", "nonsense"], ["gaming", "add", "--ip", "10.10.10.500"]):
            self.assertFalse(self.ok("ext/games", bad), bad)

    def test_passthrough(self):
        for words, ttl in ((("ext", "passthrough", "list"), 30), (("ext", "passthrough", "state"), 15), (("ext", "passthrough", "status"), 30)):
            self.assertEqual(ws.READS[words], {"kind": "tsv", "ttl": ttl})
        a = "ext/passthrough"
        self.assertTrue(self.ok(a, ["example.com", "add", "--address", "192.168.1.20", "--proxy-protocol"]))
        self.assertTrue(self.ok(a, ["example.com", "add", "--address", "fd00::5", "--https-port", "8443", "--no-http"]))
        self.assertTrue(self.ok(a, ["example.com", "remove"]))
        # a container target: the switch sends --container-ok, the typed domain travels as `confirm` (appended as --confirm at start)
        self.assertTrue(self.ok(a, ["example.com", "add", "--address", "10.10.95.5", "--container-ok"]))
        got = ws.validate_change({"area": a, "args": ["example.com", "add", "--address", "10.10.95.5", "--container-ok"], "confirm": "example.com"})
        self.assertIsNotNone(got)
        self.assertEqual(got[2], "example.com")
        self.assertFalse(self.ok(a, ["example.com", "add", "--address", "10.10.95.5", "--container-ok", "yes"]))
        for bad in (["Example.com", "add"], ["a b", "remove"], ["example.com", "add", "--address", "1.2.3.4;x"],
                    ["example.com", "add", "--https-port", "x"], ["example.com", "wipe"]):
            self.assertFalse(self.ok(a, bad), bad)

    def test_posters(self):
        self.assertEqual(ws.READS[("ext", "posters", "list")], {"kind": "tsv", "ttl": 5})
        self.assertTrue(self.ok("ext/posters", ["generate", "--eyebrow", "a", "--title", "b", "--color", "#12ab9f", "--seed", "42", "--case", "keep"]))
        self.assertTrue(self.ok("ext/posters", ["delete", "poster-dune-42.png"]))
        for bad in (["generate", "--out", "/etc"], ["delete", "../x.png"], ["generate", "--eyebrow", "a\nb", "--title", "b"]):
            self.assertFalse(self.ok("ext/posters", bad), bad)

    def test_the_old_static_areas_are_gone(self):
        self.assertFalse(self.ok("pc", ["gaming", "wake"]))
        self.assertFalse(self.ok("poster", ["delete", "poster-dune-42.png"]))
        self.assertNotIn(("pc", "list"), ws.READS)
        self.assertNotIn(("poster", "list"), ws.READS)

    def test_the_pages_are_declared_by_the_packages_that_are_on(self):
        pages = {p["name"]: p for p in ws.ext_pages()}
        self.assertEqual(sorted(pages), ["games", "passthrough", "posters"])
        self.assertEqual(pages["games"]["title"], "Game streaming")
        self.assertEqual(pages["games"]["blocks"][0]["read"], "list")
        self.assertEqual(pages["posters"]["blocks"][0]["type"], "gallery")
        self.assertEqual(ws.features(ws.Config())["extensions"], ws.ext_pages())
        write(self.caps, "games\n")
        ws.ext_refresh(force=True)
        self.assertEqual([p["name"] for p in ws.ext_pages()], ["games"])

    def test_every_plan_a_page_declares_is_allowed_by_the_changes(self):
        # the plans of the actions, with a sample value in every {placeholder}, must pass validate_change
        sample = {"name": "gaming-pc", "file": "poster-dune-42.png", "domain": "example.com"}
        for p in ws.ext_pages():
            for b in p["blocks"]:
                for a in b.get("rowActions", []) + p.get("actions", []):
                    if "plan" in a:
                        args = [re.sub(r"\{(\w+)\}", lambda m: sample[m.group(1)], x) for x in a["plan"][1:]]
                        self.assertTrue(self.ok(a["plan"][0], args), a)

    def test_a_passthrough_domain_can_be_edited(self):
        # the Edit row action opens the same form as Add with the row; saving is `add` on a forwarded domain, which the changes already allow
        page = {p["name"]: p for p in ws.ext_pages()}["passthrough"]
        table = next(b for b in page["blocks"] if b.get("type") == "table")
        edit = next(a for a in table["rowActions"] if a.get("edit"))
        self.assertEqual(edit["form"], next(a for a in page["actions"] if a.get("primary"))["form"])
        cols = {c["key"] for c in table["columns"]}
        self.assertTrue({"domain", "address", "https", "http", "proxy"} <= cols)   # the form reads these keys of the row

    def test_off_the_pages_have_nothing(self):
        write(self.caps, "")
        ws.ext_refresh(force=True)
        self.assertEqual(ws.ext_pages(), [])
        self.assertFalse(any(k[0] == "ext" for k in ws.READS))
        self.assertFalse(any(k.startswith("ext/") for k in ws.CHANGES))


class GamesChanges(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.caps = os.path.join(self.tmp, "caps")
        os.environ["HS_CAPABILITIES_FILE"] = self.caps
        os.environ["HS_STATE_DIR"] = os.path.join(self.tmp, "state")
        os.environ["HS_PACKAGES_DIR"] = EXT
        write(self.caps, "games\n")
        ws.ext_refresh(force=True)

    def tearDown(self):
        write(self.caps, "")
        ws.ext_refresh(force=True)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_pc_wake(self):
        self.assertTrue(ok("ext/games", ["gaming-pc", "wake"]))
        self.assertTrue(ok("ext/games", ["PC.1", "wake"]))
        for bad in (["gaming", "sleep"], ["gaming", "wake", "--wait"], ["-x", "wake"], ["a b", "wake"], ["wake"], ["../x", "wake"], ["x" * 42, "wake"]):
            self.assertFalse(ok("ext/games", bad), bad)


    def test_pc_add_remove(self):
        self.assertTrue(ok("ext/games", ["gaming", "remove"]))
        self.assertTrue(ok("ext/games", ["gaming", "add"]))                                    # the plan answers "needs mac"
        self.assertTrue(ok("ext/games", ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff"]))
        self.assertTrue(ok("ext/games", ["gaming", "add", "--mac", "AA-BB-CC-DD-EE-FF", "--ip", "10.10.10.50"]))
        self.assertTrue(ok("ext/games", ["gaming", "add", "--ip", "10.10.10.50", "--mac", "aa:bb:cc:dd:ee:ff"]))
        bad = [
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff:00"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:gg"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff\n"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "--mac", "aa:bb:cc:dd:ee:00"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "--ip", "10.10.10.256"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "--ip", "10.10.10"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "--ip", "host.lan"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "--ip", "10.0.0.1;id"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "--wait"],
            ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff", "extra"],
            ["gaming", "remove", "--yes"],
            ["gaming", "remove", "x"],
            ["../x", "add", "--mac", "aa:bb:cc:dd:ee:ff"],
            ["a b", "add", "--mac", "aa:bb:cc:dd:ee:ff"],
            ["-x", "remove"],
            ["add", "--mac", "aa:bb:cc:dd:ee:ff"],
        ]
        for b in bad:
            self.assertFalse(ok("ext/games", b), b)
        self.assertFalse(ok("ext/games", ["gaming", "add", "--mac", "aa:bb:cc:dd:ee:ff"], stdin="x"))      # nothing here takes a password


def ok(area, args, confirm=None, stdin=None):
    return ws.validate_change({"area": area, "args": args, "confirm": confirm, "stdin": stdin}) is not None


if __name__ == "__main__":
    unittest.main()
