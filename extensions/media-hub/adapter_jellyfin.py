"""Jellyfin adapter of the media hub poller (hobnix/core#928). UNVERIFIED: written from the public Jellyfin API description, never run against a real
Jellyfin; the fixture in tests/fixtures/media-hub/jellyfin-sessions.json is a hand-made sample of that shape. Hardware test step 2 checks it.

An adapter is two things: where to ask (ENDPOINT, HEADER) and how to read the answer (parse). Nothing else of the poller knows these shapes.
"""
import json

UNVERIFIED = True
PACKAGE = "jellyfin"            # the package name `hs pkg integrations media` lists
ENDPOINT = "/Sessions"          # GET <api_url>/Sessions: the sessions that are connected, a JSON list
HEADER = "X-Emby-Token"         # the API key goes here (the recipe's own key_header is not in the listing)
ACCEPT = "application/json"


def parse(text):
    """The sessions that play something now: a list of {id, user, title, path}. A broken answer is an empty list."""
    try:
        data = json.loads(text)
    except ValueError:
        return []
    out = []
    for s in data if isinstance(data, list) else []:
        item = s.get("NowPlayingItem") if isinstance(s, dict) else None
        if not isinstance(item, dict) or not s.get("Id"):
            continue
        out.append({"id": str(s["Id"]), "user": str(s.get("UserName") or ""),
                    "title": str(item.get("Name") or ""), "path": str(item.get("Path") or "")})
    return out
