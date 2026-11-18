#!/usr/bin/env python3
"""The [service] of the extension ad-selfservice (hobnix/server docs/adr/0011, docs/extensions-sdk.md): the core runs this file as
hs-ext-svc@ad-selfservice.service and talks JSON lines with it on stdin and stdout; standard library only.

  core -> service   init (name, lang, subscribe, health_interval), shutdown (grace_ms)
  service -> core   ready, health (ok, text), log (the audit lines: audit TAB time TAB ip TAB user TAB result, never a password)

The service is up whenever the package is on and was not stopped by hand. It serves the form (selfservice.py, on 127.0.0.1:<port>) only when
`hs ext ad-selfservice start` wrote config.json and the service has a public name; until then it answers health ok=false with the reason, so
`hs ext status` shows "degraded" and why. It reads config.json again when it changes (start with a new domain controller address). It
subscribes to no event and emits none.

Test knobs: HS_STATE_DIR (default /var/lib/hs), HS_SERVICES_DIR (default <HS_STATE_DIR>/services.d), HS_ADSS_POLL (seconds between looks, default 2).
"""
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import selfservice  # noqa: E402

STATE = os.path.join(os.environ.get('HS_STATE_DIR') or '/var/lib/hs', 'ad-selfservice')
DESCRIPTOR = os.path.join(os.environ.get('HS_SERVICES_DIR') or os.path.join(os.environ.get('HS_STATE_DIR') or '/var/lib/hs', 'services.d'),
                          'ad-selfservice.toml')
CONFIG = os.path.join(STATE, 'config.json')
POLL = float(os.environ.get('HS_ADSS_POLL') or 2)
out_lock = threading.Lock()


def say(**m):
    m['v'] = 1
    with out_lock:
        sys.stdout.write(json.dumps(m, separators=(',', ':')) + '\n')
        sys.stdout.flush()


def read_config():
    """(config bytes, config dict, None) or (None, None, the reason the form is not served)."""
    try:
        with open(CONFIG, 'rb') as f:
            raw = f.read()
        cfg = json.loads(raw.decode('utf-8'))
        int(cfg['port'])
    except FileNotFoundError:
        return None, None, 'not started: run hs ext ad-selfservice start'
    except (OSError, ValueError, KeyError, TypeError):
        return None, None, 'config.json is not valid: run hs ext ad-selfservice start'
    try:
        with open(DESCRIPTOR, encoding='utf-8') as f:
            text = f.read()
    except OSError:
        text = ''
    # the same test as `start`: the form is only for a public name behind the TLS proxy (the daemon also refuses a request without HTTPS)
    if not re.search(r'^exposure = "public-ok"', text, re.M) or not re.search(r'^fqdn = \["[^"]+"', text, re.M):
        return None, None, 'no public name: run hs ext ad-selfservice expose public <full name>'
    return raw, cfg, None


class Form:
    """The HTTP server for one config, run on a thread."""

    def __init__(self, raw, cfg):
        self.raw = raw
        self.rt = tempfile.mkdtemp(prefix='adss-')   # the private /tmp of the unit: smb.conf and the directories smbpasswd wants
        try:
            self.svc, self.srv = selfservice.build_server(cfg, self.rt, audit_sink=lambda line: say(type='log', level='info', text=line))
        except BaseException:
            shutil.rmtree(self.rt, ignore_errors=True)
            raise
        self.port = int(cfg['port'])
        self.thread = threading.Thread(target=self.srv.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()
        shutil.rmtree(self.rt, ignore_errors=True)


def main():
    try:
        init = json.loads(sys.stdin.readline())
        interval = max(1.0, float(init.get('health_interval', 30)))
        if init.get('type') != 'init':
            raise ValueError('no init')
    except (ValueError, TypeError):
        print('service.py: the first message must be init', file=sys.stderr)
        return 1
    stop = threading.Event()

    def listen():   # shutdown or a closed stdin (the core is gone) ends the service
        for line in sys.stdin:
            try:
                if json.loads(line).get('type') == 'shutdown':
                    break
            except ValueError:
                pass
        stop.set()
    threading.Thread(target=listen, daemon=True).start()
    say(type='ready')
    form = None
    last = None          # (ok, text) of the last health message
    sent = 0.0
    while not stop.is_set():
        raw, cfg, why = read_config()
        if form is not None and (why or raw != form.raw):   # stopped by hand elsewhere, or start wrote a new config
            form.close()
            form = None
        if form is None and not why:
            try:
                form = Form(raw, cfg)
                print('listening on 127.0.0.1:%s' % form.port, file=sys.stderr, flush=True)
            except OSError as e:
                why = 'could not listen on 127.0.0.1:%s (%s)' % (cfg.get('port'), e.strerror or e)
        state = (True, 'serving the form on 127.0.0.1:%s' % form.port) if form else (False, why)
        if state != last or time.time() - sent >= interval / 2:
            say(type='health', ok=state[0], text=state[1])
            last, sent = state, time.time()
        stop.wait(POLL)
    if form is not None:
        form.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
