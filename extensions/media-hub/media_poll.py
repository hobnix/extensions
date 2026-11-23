"""The poller of the media hub (hobnix/core#928): asks the media apps who is playing, notices when a playback ends, counts it through the existing
`record-session` command, keeps the paths of what was watched for the storage suggestion, and builds the poster command of an `imported` event.

Python stdlib only. The shapes of the apps' answers live in adapter_<app>.py (all UNVERIFIED); this file knows only {id, user, title, path}.
Every outside thing (the key, the HTTP call, the commands) is a function that is passed in, so the tests run it with fakes.
"""
import importlib
import os
import posixpath
import re
import subprocess
import urllib.request
import zlib

ADAPTERS = ("jellyfin", "plex")
USER_RE = re.compile(r"[^A-Za-z0-9_.@-]")
WATCHED_MAX = 200               # lines kept in watched.tsv
MIN_SECONDS = 60                # a playback shorter than this is not counted (a skipped item, a test start)
MAX_BODY = 1 << 20


def load_adapter(package):
    """The adapter module of a package, or None when the hub knows none for it."""
    if package not in ADAPTERS:
        return None
    return importlib.import_module("adapter_" + package)


def clean(text, n):
    """A free text without control characters and tabs, cut to n characters."""
    return "".join(c if c >= " " and c != "\x7f" else " " for c in str(text))[:n].strip()


def user_name(raw):
    """The name record-session accepts (letters, digits and _.@-, at most 64); an empty one is `unknown`."""
    return USER_RE.sub("_", clean(raw, 64))[:64] or "unknown"


def parse_apps(text):
    """(apps, note) from the rows of `hs sys pkg integrations media`: apps = [(package, api_url, extras)] that can be polled, note = why not.
    Platform gap (see NOTES.md): integration_key <name> <caller> returns the key of the FIRST package of the integration that has a key_file, not
    of a package of our choice. So the one app that can be polled is the first row with a key state; with Radarr before Jellyfin nothing is polled."""
    for line in text.splitlines():
        f = line.split("	")
        if len(f) < 5 or f[4] == "-":
            continue
        if load_adapter(f[0]) is None:
            return [], "the first media app with a key is %s, which the hub has no adapter for (the key helper returns only that key)" % f[0]
        if f[4] != "ok":
            return [], "the key of %s is %s" % (f[0], f[4])
        if not f[3].startswith("http"):
            return [], "%s has no address" % f[0]
        return [(f[0], f[3], f[5] if len(f) > 5 else "-")], ""
    return [], "no media app with a key found"


def track(prev, sessions, now):
    """One poll of one app. prev = {session id: {user, title, path, start, last}} of the poll before.
    Returns (new prev, finished) where finished = [{user, title, path, minutes}] of the sessions that are gone now."""
    new, finished = {}, []
    for s in sessions:
        old = prev.get(s["id"])
        new[s["id"]] = dict(s, start=old["start"] if old else now, last=now)
    for sid, old in prev.items():
        if sid in new:
            continue
        seconds = old["last"] - old["start"]
        if seconds >= MIN_SECONDS:
            finished.append({"user": old["user"], "title": old["title"], "path": old["path"], "minutes": max(1, min(1440, round(seconds / 60)))})
    return new, finished


def split_path(path):
    """(name, folder) of a path an app reports; the app may be on another system, so both slashes count."""
    p = clean(path, 500).replace("\\", "/")
    return posixpath.basename(p), posixpath.dirname(p)


def remember_watched(state_dir, finished, now):
    """Keep what was watched: watched.tsv = epoch TAB name TAB folder, the newest WATCHED_MAX, one line per name and folder (the newest)."""
    path = os.path.join(state_dir, "watched.tsv")
    rows = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                t = line.rstrip("\n").split("\t")
                if len(t) == 3 and t[0].isdigit():
                    rows[(t[1], t[2])] = int(t[0])
    except OSError:
        pass
    for s in finished:
        name, folder = split_path(s["path"])
        if name and folder.startswith("/"):
            rows[(name, folder)] = int(now)
    keep = sorted(rows.items(), key=lambda kv: kv[1], reverse=True)[:WATCHED_MAX]
    os.makedirs(state_dir, exist_ok=True)
    tmp = path + ".new"
    with open(tmp, "w", encoding="utf-8") as f:
        for (name, folder), t in keep:
            f.write("%d\t%s\t%s\n" % (t, name, folder))
    os.replace(tmp, path)


class Poller:
    """fetch(package, api_url, extras) -> the answer text or None; record(user, minutes, title) -> bool; both are passed in."""

    def __init__(self, fetch, record, state_dir, clock):
        self.fetch, self.record, self.state_dir, self.clock = fetch, record, state_dir, clock
        self.prev = {}          # package -> {session id: ...}

    def poll(self, apps):
        """One round over the apps. Returns the sessions playing now, [{app, user, title}], for the live document."""
        now = self.clock()
        playing = []
        for package, url, extras in apps:
            ad = load_adapter(package)
            text = self.fetch(package, url, extras)
            if text is None:        # the app did not answer: keep what we know, do not end its sessions
                playing += [{"app": package, "user": s["user"], "title": s["title"]} for s in self.prev.get(package, {}).values()]
                continue
            sessions = ad.parse(text)
            self.prev[package], finished = track(self.prev.get(package, {}), sessions, now)
            for s in finished:
                self.record(user_name(s["user"]), s["minutes"], clean(s["title"], 120))
            if finished:
                remember_watched(self.state_dir, finished, now)
            playing += [{"app": package, "user": s["user"], "title": clean(s["title"], 120)} for s in sessions]
        return playing


def http_fetch_factory(get_key, timeout=10):
    """fetch(package, url, extras) for the Poller: GET with the key of the app in the header of its adapter. The key is read on every call
    through get_key(package) (core's integration_key) and is never logged; an error is None."""
    def fetch(package, url, extras):
        ad = load_adapter(package)
        key = get_key(package)
        if not key:
            return None
        req = urllib.request.Request(url.rstrip("/") + ad.ENDPOINT, headers={ad.HEADER: key, "Accept": ad.ACCEPT})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:     # noqa: S310 (the address is the app's own, from the integration listing)
                return r.read(MAX_BODY).decode("utf-8", "replace")
        except (OSError, ValueError):
            return None
    return fetch


def key_from_core(scripts, caller="media-hub"):
    """get_key(package): the key through integration_key (scripts/lib/integration.sh) on a pipe; never in argv or the environment."""
    def get_key(package):
        code = '. "$1/lib/ui.sh"; here=$1; . "$1/lib/integration.sh"; integration_key "$2" "$3"'
        try:
            r = subprocess.run(["bash", "-c", code, "_", scripts, "media", caller], capture_output=True, timeout=20, check=False)
        except (OSError, subprocess.SubprocessError):
            return ""
        return r.stdout.decode("utf-8", "replace").strip() if r.returncode == 0 else ""
    return get_key


def poster_command(event, base):
    """The command that draws the poster of an `imported` event, or None when the event has no title. base = the words of the hs call.
    The seed comes from the title, so a delivered-twice event draws the same file again (--force overwrites)."""
    payload = event.get("payload") or {}
    title = clean(payload.get("title") or "", 80)
    if not title:
        return None
    seed = zlib.crc32(title.encode("utf-8")) % 1000000000
    return list(base) + ["--eyebrow", "New in the library", "--title", title, "--seed", str(seed)]
