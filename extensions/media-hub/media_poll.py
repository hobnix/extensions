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
HEADER_RE = re.compile(r"^[A-Za-z][A-Za-z0-9-]{0,39}$")
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


def credential_owner(text):
    """The package whose key the platform hands over as the credential integration-media: the first row of the listing with a key state (the
    same rule as core's integration-grant: sorted, first key_file). None when no row has a key. A locked key still counts: the platform
    picks that provider and then hands over nothing."""
    for line in text.splitlines():
        f = line.split("	")
        if len(f) >= 5 and f[4] != "-":
            return f[0]
    return None


def parse_apps(text):
    """(apps, note) from the rows of `hs sys pkg integrations media` (package, integration, kind, api_url, key state, extras, key_header):
    apps = [(package, api_url, extras, header)] of every provider that can be polled, note = why the others cannot. The header is the row's
    key_header; a row without one gets the header of the adapter (the listing's default X-Api-Key is not what Jellyfin or Plex read)."""
    apps, notes = [], []
    for line in text.splitlines():
        f = line.split("	")
        if len(f) < 5 or f[4] == "-":
            continue
        ad = load_adapter(f[0])
        if ad is None:
            notes.append("%s has no adapter" % f[0])
        elif f[4] != "ok":
            notes.append("the key of %s is %s" % (f[0], f[4]))
        elif not f[3].startswith("http"):
            notes.append("%s has no address" % f[0])
        else:
            h = f[6] if len(f) > 6 and HEADER_RE.match(f[6]) else ad.HEADER
            apps.append((f[0], f[3], f[5] if len(f) > 5 else "-", h))
    if not apps and not notes:
        notes.append("no media app with a key found")
    return apps, "; ".join(notes)


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
    """fetch(package, api_url, extras, header) -> the answer text or None; record(user, minutes, title) -> bool; both are passed in."""

    def __init__(self, fetch, record, state_dir, clock):
        self.fetch, self.record, self.state_dir, self.clock = fetch, record, state_dir, clock
        self.prev = {}          # package -> {session id: ...}

    def poll(self, apps):
        """One round over the apps. Returns the sessions playing now, [{app, user, title}], for the live document."""
        now = self.clock()
        playing = []
        for package, url, extras, header in apps:
            ad = load_adapter(package)
            text = self.fetch(package, url, extras, header)
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
    """fetch(package, url, extras, header) for the Poller: GET with the key of THAT app in the header the listing names. The key is read on every
    call through get_key(package) and is never logged; an error is None. A key is only ever sent to the address of the package it belongs to."""
    def fetch(package, url, extras, header):
        ad = load_adapter(package)
        key = get_key(package)
        if not key or not HEADER_RE.match(header or ""):
            return None
        req = urllib.request.Request(url.rstrip("/") + ad.ENDPOINT, headers={header: key, "Accept": ad.ACCEPT})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:     # noqa: S310 (the address is the app's own, from the integration listing)
                return r.read(MAX_BODY).decode("utf-8", "replace")
        except (OSError, ValueError):
            return None
    return fetch


def key_by_provider(owner, credential, ask):
    """get_key(package): the key of that package and no other. owner() = the package the platform's credential belongs to (credential_owner of the
    current listing), credential() = $CREDENTIALS_DIRECTORY/integration-media or None, ask(package) = key through core's integration_key (a
    confined service cannot reach it, then it is ''). The credential is used only for its owner: it is never tried for another app."""
    def get_key(package):
        if package == owner():
            k = credential()
            if k:
                return k
        return ask(package)
    return get_key


def key_from_core(scripts, caller="media-hub"):
    """ask(package): the key through `integration_key media <package> <caller>` (scripts/lib/integration.sh) on a pipe; never in argv or the
    environment. Needs the vault and the key files, so it works only outside the sandbox; inside, it returns ''."""
    def ask(package):
        code = '. "$1/lib/ui.sh"; here=$1; . "$1/lib/integration.sh"; integration_key media "$2" "$3"'
        try:
            r = subprocess.run(["bash", "-c", code, "_", scripts, package, caller], capture_output=True, timeout=20, check=False)
        except (OSError, subprocess.SubprocessError):
            return ""
        return r.stdout.decode("utf-8", "replace").strip() if r.returncode == 0 else ""
    return ask


def poster_command(event, base):
    """The command that draws the poster of an `imported` event, or None when the event has no title. base = the words of the hs call.
    The seed comes from the title, so a delivered-twice event draws the same file again (--force overwrites)."""
    payload = event.get("payload") or {}
    title = clean(payload.get("title") or "", 80)
    if not title:
        return None
    seed = zlib.crc32(title.encode("utf-8")) % 1000000000
    return list(base) + ["--eyebrow", "New in the library", "--title", title, "--seed", str(seed)]
