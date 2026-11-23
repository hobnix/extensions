"""Plex adapter of the media hub poller (hobnix/core#928). UNVERIFIED: written from the public Plex API description, never run against a real Plex;
the fixture in tests/fixtures/media-hub/plex-sessions.json is a hand-made sample of that shape. Plex is not a recipe of the core: the adapter is used
only when a package named plex declares [integrations.media]. Hardware test step 2 checks it.
"""
import json

UNVERIFIED = True
PACKAGE = "plex"
ENDPOINT = "/status/sessions"   # GET <api_url>/status/sessions with Accept: application/json: {"MediaContainer": {"Metadata": [...]}}
HEADER = "X-Plex-Token"
ACCEPT = "application/json"


def parse(text):
    """The sessions that play something now: a list of {id, user, title, path}. A broken answer is an empty list."""
    try:
        meta = json.loads(text)["MediaContainer"].get("Metadata") or []
    except (ValueError, KeyError, AttributeError, TypeError):
        return []
    out = []
    for m in meta if isinstance(meta, list) else []:
        if not isinstance(m, dict):
            continue
        sess = m.get("Session") if isinstance(m.get("Session"), dict) else {}
        sid = sess.get("id") or m.get("sessionKey")
        if not sid:
            continue
        try:
            path = m["Media"][0]["Part"][0]["file"]
        except (KeyError, IndexError, TypeError):
            path = ""
        user = m["User"].get("title") if isinstance(m.get("User"), dict) else ""
        out.append({"id": str(sid), "user": str(user or ""), "title": str(m.get("title") or ""), "path": str(path or "")})
    return out
