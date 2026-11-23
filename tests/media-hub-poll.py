"""Unit checks of the media hub poller (called by tests/media-hub-poll.sh): argv = extension folder, fixtures folder, a scratch folder.
Prints `ok <what>` or `FAIL <what>` per check."""
import json
import os
import sys

ext, fix, work = sys.argv[1:4]
sys.path.insert(0, ext)
import adapter_jellyfin, adapter_plex, media_poll  # noqa: E402

bad = 0


def check(what, got, want):
    global bad
    if got == want:
        print("ok", what)
    else:
        bad += 1
        print("FAIL", what, "got", repr(got), "want", repr(want))


def read(n):
    return open(os.path.join(fix, n), encoding="utf-8").read()


check("both adapters are marked unverified", (adapter_jellyfin.UNVERIFIED, adapter_plex.UNVERIFIED), (True, True))
jf = adapter_jellyfin.parse(read("jellyfin-sessions.json"))
check("jellyfin: only sessions that play something", [s["id"] for s in jf], ["s1", "s3"])
check("jellyfin: user, title and path", (jf[0]["user"], jf[0]["title"], jf[0]["path"]), ("anna", "Dune", "/media/movies/Dune (2021)/Dune.mkv"))
check("jellyfin: a broken answer is an empty list", adapter_jellyfin.parse("<html>"), [])
px = adapter_plex.parse(read("plex-sessions.json"))
check("plex: one session", px, [{"id": "abc123", "user": "dora", "title": "Arrival", "path": "/data/movies/Arrival (2016)/Arrival.mkv"}])
check("plex: a broken answer is an empty list", (adapter_plex.parse("{}"), adapter_plex.parse("nope")), ([], []))
check("an app without an adapter is unknown", media_poll.load_adapter("radarr"), None)

# the providers: every row with a key and an adapter is polled, with the header of its row
J = "jellyfin\tmedia\trecipe\thttp://10.0.0.6:8096\tok\t-\tX-Emby-Token\n"
R = "radarr\tmedia\trecipe\thttp://10.0.0.5:7878\tok\tkind=movies\tX-Api-Key\n"
check("jellyfin and radarr: only jellyfin has an adapter, radarr is named", media_poll.parse_apps(J + R), ([("jellyfin", "http://10.0.0.6:8096", "-", "X-Emby-Token")], "radarr has no adapter"))
apps, why = media_poll.parse_apps(R + J)
check("radarr first: jellyfin is still polled", [a[0] for a in apps], ["jellyfin"])
check("a row without key_header gets the header of the adapter", media_poll.parse_apps("jellyfin\tmedia\trecipe\thttp://x\tok\t-\t-\n")[0][0][3], "X-Emby-Token")
check("a bad key_header is not used", media_poll.parse_apps("jellyfin\tmedia\trecipe\thttp://x\tok\t-\tbad header\n")[0][0][3], "X-Emby-Token")
check("a row of an older core without the column still works", media_poll.parse_apps("jellyfin\tmedia\trecipe\thttp://x\tok\t-\n")[0][0][3], "X-Emby-Token")
check("a locked key: nothing polled", media_poll.parse_apps("jellyfin\tmedia\trecipe\thttp://x\tlocked\t-\t-\n")[0], [])
check("no keyed app", media_poll.parse_apps("jellyfin\tmedia\trecipe\thttp://x\t-\t-\t-\n"), ([], "no media app with a key found"))
check("the credential belongs to the first row with a key", (media_poll.credential_owner(R + J), media_poll.credential_owner("x\tmedia\trecipe\t-\t-\t-\t-\n" + J), media_poll.credential_owner("")), ("radarr", "jellyfin", None))

# no key crosses: the platform credential only for its owner, the other provider's key only through its own ask
asked = []
def ask(pkg):
    asked.append(pkg)
    return {"radarr": "RADARR-KEY"}.get(pkg, "")
gk = media_poll.key_by_provider(lambda: "jellyfin", lambda: "JELLYFIN-KEY", ask)
check("jellyfin gets the credential, radarr never does", (gk("jellyfin"), gk("radarr"), asked), ("JELLYFIN-KEY", "RADARR-KEY", ["radarr"]))
gk = media_poll.key_by_provider(lambda: "radarr", lambda: "RADARR-CRED", ask)
check("the credential of radarr is not given to jellyfin", (gk("radarr"), gk("jellyfin")), ("RADARR-CRED", ""))
gk = media_poll.key_by_provider(lambda: "jellyfin", lambda: None, lambda p: "")
check("no credential and no helper: no key", gk("jellyfin"), "")

# the HTTP call: each key goes to its own address in its own header (urlopen is faked)
sent = []
class Resp:
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def read(self, n): return b"[]"
real = media_poll.urllib.request.urlopen
media_poll.urllib.request.urlopen = lambda req, timeout=0: sent.append((req.full_url, dict((k.lower(), v) for k, v in req.header_items()))) or Resp()
keys = {"jellyfin": "JK", "plex": "PK"}
fetch = media_poll.http_fetch_factory(lambda pkg: keys.get(pkg, ""))
fetch("jellyfin", "http://10.0.0.6:8096", "-", "X-Emby-Token")
fetch("plex", "http://10.0.0.7:32400", "-", "X-Plex-Token")
check("jellyfin key to the jellyfin address in the row's header", sent[0], ("http://10.0.0.6:8096/Sessions", {"x-emby-token": "JK", "accept": "application/json"}))
check("plex key to the plex address in its header, no other key in it", sent[1], ("http://10.0.0.7:32400/status/sessions", {"x-plex-token": "PK", "accept": "application/json"}))
keys.clear()
check("no key: no call", (fetch("jellyfin", "http://x", "-", "X-Emby-Token"), len(sent)), (None, 2))
media_poll.urllib.request.urlopen = real

# track: a playback counts when it is gone, at least a minute
a = {"id": "1", "user": "anna", "title": "Dune", "path": "/m/Dune.mkv"}
p, fin = media_poll.track({}, [a], 1000)
check("first sight: nothing finished", fin, [])
p, fin = media_poll.track(p, [a], 1000 + 1800)
check("still playing: nothing finished", fin, [])
p, fin = media_poll.track(p, [], 1000 + 1830)
check("gone: 30 minutes (last seen 1800 s after start)", [f["minutes"] for f in fin], [30])
p, fin = media_poll.track({"1": dict(a, start=0, last=40)}, [], 100)
check("under a minute is not counted", fin, [])
p, fin = media_poll.track({"1": dict(a, start=0, last=10 ** 6)}, [], 10 ** 6 + 30)
check("a day at most", [f["minutes"] for f in fin], [1440])

check("user names are made safe", (media_poll.user_name("carl smith"), media_poll.user_name(""), media_poll.user_name("a" * 99) == "a" * 64), ("carl_smith", "unknown", True))

# the poller with a fake app and a fake recorder
state = os.path.join(work, "state")
calls, clock, answers = [], [10000], {}
poller = media_poll.Poller(lambda pkg, url, ex, h: answers.get(pkg), lambda u, m, t: calls.append((u, m, t)) or True, state, lambda: clock[0])
apps = [("jellyfin", "http://x", "-", "X-Emby-Token")]
answers["jellyfin"] = read("jellyfin-sessions.json")
now = poller.poll(apps)
check("poll 1: two playing, nothing counted", (len(now), calls), (2, []))
clock[0] += 600
answers["jellyfin"] = None
now = poller.poll(apps)
check("the app does not answer: sessions stay, nothing counted", (len(now), calls), (2, []))
clock[0] += 600
answers["jellyfin"] = "[]"
now = poller.poll(apps)
check("both are gone, but were seen at one poll only (0 s): nothing counted", (now, calls), ([], []))
answers["jellyfin"] = read("jellyfin-sessions.json"); clock[0] += 60
poller.poll(apps)
clock[0] += 1500
poller.poll(apps)
answers["jellyfin"] = "[]"; clock[0] += 30
poller.poll(apps)
check("a 25 minute playback is counted for both users", sorted(calls), [("anna", 25, "Dune"), ("carl_smith", 25, "Pilot")])
w = open(os.path.join(state, "watched.tsv"), encoding="utf-8").read().splitlines()
check("watched.tsv has name and folder, newest first", sorted(l.split("\t", 1)[1] for l in w), ["Dune.mkv\t/media/movies/Dune (2021)", "S01E01.mkv\t/media/tv/Show"])

# the poster command
ev = {"id": 5, "kind": "pkg.media-hub.imported", "payload": {"title": "A Film", "app": "radarr"}}
c = media_poll.poster_command(ev, ["hs", "sys", "ext", "posters", "start", "generate"])
check("poster command", c[:10], ["hs", "sys", "ext", "posters", "start", "generate", "--eyebrow", "New in the library", "--title", "A Film"])
check("poster command ends in a numeric seed", c[10] == "--seed" and c[11].isdigit(), True)
check("the same title gives the same seed", media_poll.poster_command(ev, ["x"]) == media_poll.poster_command(dict(ev, id=6), ["x"]), True)
check("an event without a title draws nothing", media_poll.poster_command({"payload": {}}, ["x"]), None)
check("a title with control characters is cleaned", media_poll.poster_command({"payload": {"title": "a\tb\nc"}}, ["x"])[4], "a b c")

sys.exit(1 if bad else 0)
