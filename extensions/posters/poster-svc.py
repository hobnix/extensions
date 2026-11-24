#!/usr/bin/env python3
"""The service of the posters package (docs/extensions-sdk.md "Events and snapshots", ADR 0011): it draws the poster of a new film.

It subscribes to pkg.media-hub.imported (the event of media-hub, hobnix/core#1129). The service of media-hub never runs a host command, so
this package reacts to the event itself and calls its own drawing script, poster-change.sh, directly: no `hs`. The same title gives the same seed and
the same file, and --force overwrites, so an event delivered twice does no harm (the core delivers at least once). A failure is logged and the event
is acknowledged anyway: the poster is a nicety and must never block the cursor.
Test knob: HS_POSTER_CHANGE = another script than poster-change.sh (run with bash) (called with: start generate --eyebrow .. --title .. --seed ..).
Standard library only; the messages are JSON lines on stdin and stdout.
"""
import json
import os
import re
import subprocess
import sys
import threading
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
LIMIT = 60  # seconds for one drawing


def say(**m):
    m.setdefault("v", 1)
    sys.stdout.write(json.dumps(m) + "\n")
    sys.stdout.flush()


def log(level, text):
    say(type="log", level=level, text=text)


def clean(text, n):
    """One line of at most n characters, control characters turned into spaces."""
    return re.sub(r"[\x00-\x1f\x7f]", " ", text if isinstance(text, str) else "").strip()[:n].strip()


def poster_args(payload):
    """The arguments that draw the poster of an imported event, or None when it has no title."""
    title = clean((payload or {}).get("title", ""), 80)
    if not title:
        return None
    seed = zlib.crc32(title.encode()) % 1_000_000_000
    return ["--eyebrow", "New in the library", "--title", title, "--seed", str(seed)]


def draw(ev):
    args = poster_args(ev.get("payload"))
    if args is None:
        log("warn", "imported event %s has no title: no poster" % ev.get("id"))
        return
    cmd = ["bash", os.environ.get("HS_POSTER_CHANGE") or os.path.join(HERE, "poster-change.sh")]
    title = args[3]
    try:
        r = subprocess.run(cmd + ["start", "generate"] + args, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=LIMIT)
    except (OSError, subprocess.TimeoutExpired) as e:
        log("warn", "poster not drawn: %s" % clean(str(e), 200))
        return
    if r.returncode == 0:
        log("info", "poster drawn for %s" % title)
        return
    why = next((l.split("\t", 1)[1] for l in r.stdout.splitlines() if l.startswith("reason\t")), "exit %d" % r.returncode)
    log("warn", "poster not drawn: %s" % clean(why, 200))


def main():
    init = json.loads(sys.stdin.readline())
    interval = float(init.get("health_interval") or 30)
    say(type="ready")

    def beat():
        while True:
            say(type="health", ok=True, text="")
            time.sleep(max(interval / 2, 1))

    threading.Thread(target=beat, daemon=True).start()
    for line in sys.stdin:
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if m.get("type") == "shutdown":
            break
        if m.get("type") != "event":
            continue
        if "%s.%s" % (m.get("source"), m.get("kind")) == "pkg.media-hub.imported":
            draw(m)
        say(type="ack", id=m["id"])


if __name__ == "__main__":
    main()
