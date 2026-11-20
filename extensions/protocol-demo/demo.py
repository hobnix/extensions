#!/usr/bin/env python3
"""A command of the extension protocol v1 in 20 lines (stdlib only): one request line on stdin, JSON lines on stdout, the last one is the result."""
import json
import sys
import time


def say(**m):
    sys.stdout.write(json.dumps({"v": 1, **m}) + "\n")
    sys.stdout.flush()


req = json.loads(sys.stdin.readline())
cmd = req["command"][0] if req["command"] else ""
if cmd == "hello":
    who = req["argv"][0] if req["argv"] else "world"
    greeting = "Hallo" if req["lang"] == "de" else "Hello"
    say(type="progress", text="thinking")
    say(type="result", ok=True, data={"greeting": greeting, "who": who}, text=f"{greeting}, {who}!")
elif cmd == "list":
    say(type="result", ok=True, data=[["alpha", 1, "first"], ["beta", 22, ""], ["gamma", 333, None]])
elif cmd == "slow":
    time.sleep(60)
else:
    say(type="result", ok=False, error={"code": "not_found", "message": "no such command: " + cmd})
    sys.exit(1)
