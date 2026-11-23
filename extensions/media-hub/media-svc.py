#!/usr/bin/env python3
"""The service of the media hub (hobnix/core#928; docs/extensions-sdk.md "Events and snapshots", ADR 0011). One process that stays:
  - the poller: every HS_MEDIA_POLL_SECONDS (default 30; 0 = off) it asks the media apps who plays what (media_poll.py, one adapter per app), counts a
    finished playback with `media-hub.sh record-session`, and publishes who plays now as the snapshot topic now-playing (one document, overwritten);
  - the poster trigger: an event pkg.media-hub.imported draws a poster with `hs sys ext posters start generate` (the posters extension must be on; if it is
    not, the failure is logged and the event is still acknowledged: the poster is a nicety, it must never block the cursor).
The extension protocol has no timer, so the service is the timer. It starts no change on storage: that is a suggestion the person confirms (media-suggest.sh).
Test knobs: HS_SCRIPTS, HS_MEDIA_INTEGRATIONS (a file with the rows of the integration listing), HS_MEDIA_STATE_DIR, HS_MEDIA_POSTER_CMD (a program
called with the poster arguments instead of `hs sys ext posters start generate`), HS_MEDIA_POLL_SECONDS.
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import media_poll  # noqa: E402

scripts = os.environ.get("HS_SCRIPTS") or os.path.join(here, "..", "..", "scripts")
state_dir = os.environ.get("HS_MEDIA_STATE_DIR", "/var/lib/hs/media-hub")


def media_credential():
    """The platform's key of the integration media (a systemd credential, ext_sdk.credential); None outside a confined service."""
    try:
        sys.path.insert(0, os.path.join(scripts, "lib"))
        import ext_sdk
        return ext_sdk.credential("media")
    except Exception:
        return None


def say(**m):
    m.setdefault("v", 1)
    sys.stdout.write(json.dumps(m) + "\n")
    sys.stdout.flush()


def log(level, text):
    say(type="log", level=level, text=text[:1000])


def integrations_text():
    f = os.environ.get("HS_MEDIA_INTEGRATIONS")
    if f:
        with open(f, encoding="utf-8") as fh:
            return fh.read()
    r = subprocess.run(["bash", os.path.join(scripts, "pkg.sh"), "--integrations", "media"], capture_output=True, timeout=60, check=False)
    return r.stdout.decode("utf-8", "replace")


def record(user, minutes, title):
    args = ["bash", os.path.join(here, "media-hub.sh"), "record-session", user, str(minutes)] + ([title] if title else [])
    r = subprocess.run(args, capture_output=True, timeout=60, check=False)
    if r.returncode != 0:
        log("warn", "record-session failed for %s: %s" % (user, r.stderr.decode("utf-8", "replace").strip()[:200]))
    return r.returncode == 0


def draw_poster(event):
    cmd = os.environ.get("HS_MEDIA_POSTER_CMD")
    base = [cmd] if cmd else ["hs", "sys", "ext", "posters", "start", "generate"]
    args = media_poll.poster_command(event, base)
    if args is None:
        log("warn", "imported event %s has no title: no poster" % event.get("id"))
        return
    try:
        r = subprocess.run(args, capture_output=True, timeout=120, check=False)
        out = r.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError) as e:
        log("warn", "poster not drawn: %s" % e)
        return
    if r.returncode == 0:
        log("info", "poster drawn for %s" % media_poll.clean((event.get("payload") or {}).get("title"), 80))
    else:
        why = next((l.split("\t", 1)[1] for l in out.splitlines() if l.startswith("reason\t")), "exit %d" % r.returncode)
        log("warn", "poster not drawn: %s (is the extension posters on?)" % why[:200])


def main():
    init = json.loads(sys.stdin.readline())
    interval = float(os.environ.get("HS_MEDIA_POLL_SECONDS", "30"))
    beat = max(0.5, min(5.0, float(init.get("health_interval", 30)) / 3))
    owner = [None]           # the package the platform credential belongs to, set from the listing of every round
    get_key = media_poll.key_by_provider(lambda: owner[0], media_credential, media_poll.key_from_core(scripts))
    poller = media_poll.Poller(media_poll.http_fetch_factory(get_key), record, state_dir, time.time)
    inbox = queue.Queue()
    threading.Thread(target=lambda: [inbox.put(l) for l in sys.stdin] + [inbox.put(None)], daemon=True).start()
    say(type="ready")
    last_beat = last_poll = 0.0
    note = ""
    last_playing = None
    health = (True, "")
    while True:
        try:
            line = inbox.get(timeout=0.5)
        except queue.Empty:
            line = ""
        if line is None:
            return 0                # stdin closed: the core is gone
        if line:
            m = json.loads(line)
            if m.get("type") == "shutdown":
                return 0
            if m.get("type") == "event":
                # a log row is source + kind: pkg + media-hub.imported for the event pkg.media-hub.imported (the supervisor matches the globs the same way)
                if "%s.%s" % (m.get("source"), m.get("kind")) == "pkg.media-hub.imported":
                    draw_poster(m)
                say(type="ack", id=m["id"])
        now = time.time()
        if interval > 0 and now - last_poll >= interval:
            last_poll = now
            try:
                text = integrations_text()
                owner[0] = media_poll.credential_owner(text)
                apps, why = media_poll.parse_apps(text)
                if why != note:
                    note = why
                    log("info" if not why else "warn", "poller: " + ("polling %s" % ", ".join(a[0] for a in apps) if apps else "") + (" (not polled: %s)" % why if apps and why else why))
                playing = poller.poll(apps)
                if playing != last_playing:
                    last_playing = playing
                    say(type="snapshot", topic="now-playing", data={"sessions": playing})
                health = (True, "")
            except Exception as e:    # a bad answer or a broken helper must not end the service
                health = (False, ("poll failed: %s" % e)[:200])
        if now - last_beat >= beat:
            last_beat = now
            say(type="health", ok=health[0], **({"text": health[1]} if health[1] else {}))


if __name__ == "__main__":
    sys.exit(main())
