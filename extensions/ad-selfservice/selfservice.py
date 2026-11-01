#!/usr/bin/env python3
"""The self-service password form of the extension ad-selfservice (standard library only).

  selfservice.py serve --config <config.json>   the web form on 127.0.0.1:<port> (a transient systemd unit)
  selfservice.py map <rc>                       smbpasswd output on stdin -> category TAB message (pure, for the tests)
  selfservice.py limit-test                     lines "<time> check|attempt|fail|success|size [key...]" on stdin -> the limiter with a fake clock
  selfservice.py check-input                    {"user","old","new","repeat"} as JSON on stdin -> ok|input|bad TAB text (pure)
  selfservice.py make-config <file> key=value.. the config of the daemon (written by start); conf <file> <key> reads one value

Rules (extensions/ad-selfservice/NOTES.md): a request that did not arrive over HTTPS through a trusted proxy is refused; no admin
credential and no stored secret (the CSRF key is random per process); the old password is checked by the DC itself (smbpasswd with the
user's own credentials, passwords only on its stdin); a password is never logged. The daemon audit line is
audit TAB time TAB ip TAB user TAB result, and nothing else the daemon prints starts with "audit"."""
import base64
import collections
import hashlib
import hmac
import html
import ipaddress
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import unicodedata
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PACKAGE = 'ad-selfservice'
USER_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}')   # used with fullmatch: $ would also accept a trailing newline
DENY = ('administrator', 'krbtgt', 'guest')
MAX_BODY = 4096
MAX_PASSWORD = 256
TABLE_MAX = 10000
TOKEN_TTL = 900

# The English text is the key of the German catalog (i18n/de.tsv).
MSG_OK = 'Your password was changed.'
MSG_BAD = 'The user name or the current password is wrong.'
MSG_POLICY = 'The new password does not meet the password rules of the domain.'
MSG_LIMITED = 'Too many tries. Wait a few minutes and try again.'
MSG_UNAVAILABLE = 'The password could not be changed right now. Try again later.'
MSG_PLAIN = 'Use the https address.'
MSG_EXPIRED = 'The form has expired. Reload the page and try again.'
MSG_BAD_REQUEST = 'The request was not understood.'
MSG_BUSY = 'The service is busy. Try again in a moment.'
MSG_NOT_FOUND = 'Not found.'
MSG_NO_USER = 'Enter your user name.'
MSG_BAD_USER = 'The user name is not valid.'
MSG_NO_PASSWORD = 'Enter the current and the new password.'
MSG_PW_FORMAT = 'A password has 1 to 256 characters and no line breaks.'
MSG_MISMATCH = 'The new password and the repeat are not the same.'
MSG_SAME = 'The new password must differ from the current one.'

# smbpasswd words -> category. Order matters: the first group that matches wins; the rule shown comes ONLY from the fixed list below.
BAD_RE = re.compile(r'NT_STATUS_(LOGON_FAILURE|WRONG_PASSWORD|NO_SUCH_USER|ACCOUNT_LOCKED_OUT|ACCOUNT_DISABLED|ACCOUNT_RESTRICTION)')
POLICY_RE = re.compile(r'NT_STATUS_PASSWORD_RESTRICTION|rejected the password change', re.I)
FAILED_RE = re.compile(r'NT_STATUS_|Failed to|failed|rejected|error', re.I)
RULES = (   # (pattern, text): the only rule lines a person ever sees
    (re.compile(r'too short|min(imum)?[ _-]*(pwd[ _-]*)?length|PASSWORD_TOO_SHORT', re.I), 'The new password is too short.'),
    (re.compile(r'complex', re.I), 'The new password must be more complex: upper and lower case letters, digits or symbols.'),
    (re.compile(r'histor|recently used|used before|PASSWORD_HISTORY', re.I), 'The new password was used before.'),
    (re.compile(r'min(imum)?[ _-]*(pwd[ _-]*)?age|too recent|PASSWORD_TOO_RECENT', re.I), 'The password was changed too recently.'),
)


def map_result(rc, out):
    """rc and the output of smbpasswd -> (category, message, rule). Anything not understood is "unavailable", never "ok"."""
    if rc == 0 and not FAILED_RE.search(out or ''):
        return 'ok', MSG_OK, None
    if BAD_RE.search(out or ''):
        return 'bad', MSG_BAD, None
    if POLICY_RE.search(out or ''):
        for rx, text in RULES:
            if rx.search(out):
                return 'policy', MSG_POLICY, text
        if 'NT_STATUS_PASSWORD_RESTRICTION' in out:
            return 'policy', MSG_POLICY, None
    return 'unavailable', MSG_UNAVAILABLE, None


def clean_user(raw):
    """The user name as the form gave it -> the plain account name, or None."""
    u = (raw or '').strip()
    if '\\' in u:
        u = u.rsplit('\\', 1)[1]
    if '@' in u:
        u = u.split('@', 1)[0]
    return u if USER_RE.fullmatch(u) else None


def norm_user(u):
    """One form of a name for the denylist and the limiter keys: NFKC, stripped, case-folded."""
    return unicodedata.normalize('NFKC', u or '').strip().casefold()


def check_input(user, old, new, repeat, deny=DENY):
    """-> ('ok', user) | ('input', message) | ('bad', None) for a denied account. Passwords are only looked at, never kept."""
    if not (user or '').strip():
        return 'input', MSG_NO_USER
    u = clean_user(user)
    if u is None:
        return 'input', MSG_BAD_USER
    for p in (old, new, repeat):
        if not 1 <= len(p or '') <= MAX_PASSWORD:
            return 'input', MSG_NO_PASSWORD if not p else MSG_PW_FORMAT
        if any(c in p for c in '\r\n\0'):
            return 'input', MSG_PW_FORMAT
    if new != repeat:
        return 'input', MSG_MISMATCH
    if new == old:
        return 'input', MSG_SAME
    if norm_user(u) in deny:
        return 'bad', None
    return 'ok', u


class Limiter:
    """Failure counters in memory. keys: acct:<name>, ip:<addr>; one global bucket counts the attempts that reached the DC."""

    def __init__(self, clock=time.monotonic, limits=None):
        l = limits or {}
        self.clock = clock
        self.acct = tuple(l.get('account', (3, 900)))
        self.ip = tuple(l.get('ip', (5, 900)))
        self.glob = tuple(l.get('global', (30, 60)))
        self.keys = collections.OrderedDict()   # key -> [failure times, delay until]
        self.attempts = collections.deque()
        self.lock = threading.Lock()

    def _limit(self, key):
        return self.ip if key.startswith('ip:') else self.acct

    def _entry(self, key, now):
        e = self.keys.get(key)
        if e is None:
            e = self.keys[key] = [[], 0.0]
            while len(self.keys) > TABLE_MAX:
                self.keys.popitem(last=False)
        else:
            self.keys.move_to_end(key)
        window = self._limit(key)[1]
        e[0] = [t for t in e[0] if now - t < window]
        return e

    def _wait(self, keys, now):
        wait = 0.0
        for k in keys:
            e = self._entry(k, now)
            n, window = self._limit(k)
            if e[1] > now:
                wait = max(wait, e[1] - now)
            if len(e[0]) >= n:
                wait = max(wait, e[0][0] + window - now)
        n, window = self.glob
        while self.attempts and now - self.attempts[0] >= window:
            self.attempts.popleft()
        if len(self.attempts) >= n:
            wait = max(wait, self.attempts[0] + window - now)
        return wait

    def _count(self, keys, now):
        for k in keys:
            e = self._entry(k, now)
            e[0].append(now)
            e[1] = now + min(2 ** (len(e[0]) - 1), 300)

    def check(self, keys):
        """Seconds to wait (0 = go ahead; the attempt is then counted in the global bucket)."""
        with self.lock:
            now = self.clock()
            wait = self._wait(keys, now)
            if wait <= 0:
                self.attempts.append(now)
                return 0
            return int(wait) + (0 if wait == int(wait) else 1)

    def attempt(self, keys):
        """check and count in ONE step under the lock: the try is a failure from the start (success() clears it), so parallel tries
        cannot all pass before the first failure is recorded. Seconds to wait, 0 = go ahead."""
        with self.lock:
            now = self.clock()
            wait = self._wait(keys, now)
            if wait > 0:
                return int(wait) + (0 if wait == int(wait) else 1)
            self.attempts.append(now)
            self._count(keys, now)
            return 0

    def fail(self, keys):
        with self.lock:
            now = self.clock()
            self._count(keys, now)

    def success(self, keys):
        with self.lock:
            for k in keys:
                self.keys.pop(k, None)

    def size(self):
        with self.lock:
            return len(self.keys)


def load_catalog(path, lang):
    cat = {}
    if lang == 'de' and path:
        try:
            with open(path, encoding='utf-8') as f:
                for line in f:
                    line = line.rstrip('\n')
                    if line and not line.startswith('#') and '\t' in line:
                        k, v = line.split('\t', 1)
                        cat[k] = v
        except OSError:
            pass
    return cat


def write_smb_conf(cfg, rt):
    dirs = {d: os.path.join(rt, d) for d in ('lock', 'state', 'cache', 'private', 'ncalrpc')}
    for d in dirs.values():
        os.makedirs(d, mode=0o700, exist_ok=True)
    path = os.path.join(rt, 'smb.conf')
    lines = ['[global]', '  workgroup = %s' % cfg.get('workgroup', 'WORKGROUP'), '  realm = %s' % cfg.get('realm', ''),
             '  client min protocol = SMB2_02', '  client signing = required', '  client smb encrypt = required',
             '  lock directory = %s' % dirs['lock'], '  state directory = %s' % dirs['state'], '  cache directory = %s' % dirs['cache'],
             '  private dir = %s' % dirs['private'], '  ncalrpc dir = %s' % dirs['ncalrpc'], '  unix charset = UTF-8']
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    return path


def package_on(files):
    """The rules of capability_on for a package: capabilities-off wins; on = in the capabilities file or in capabilities-on.
    None when none of the files can be read (then the daemon stays up)."""
    def names(p):
        try:
            with open(p, encoding='utf-8') as f:
                return {l.strip() for l in f}
        except OSError:
            return None
    off = names(files.get('off', '')) or set()
    on = [names(files.get('list', '')), names(files.get('on', ''))]
    if PACKAGE in off:
        return False
    if all(x is None for x in on):
        return None
    return any(x and PACKAGE in x for x in on)


class Service:
    def __init__(self, cfg, rt):
        self.cfg = cfg
        self.lang = cfg.get('language', 'en')
        self.cat = load_catalog(cfg.get('i18n'), self.lang)
        here = os.path.dirname(os.path.abspath(__file__))
        with open(cfg.get('form') or os.path.join(here, 'form.html'), encoding='utf-8') as f:
            self.template = f.read()
        css = re.search(r'<style>(.*?)</style>', self.template, re.S)
        digest = base64.b64encode(hashlib.sha256((css.group(1) if css else '').encode('utf-8')).digest()).decode()
        self.csp = ("default-src 'none'; style-src 'sha256-%s'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'" % digest)
        self.key = secrets.token_bytes(32)   # memory only: a restart makes the open forms expire
        self.used = collections.OrderedDict()
        self.used_lock = threading.Lock()
        self.limiter = Limiter(limits=cfg.get('limits'))
        self.trusted = [ipaddress.ip_network(x, strict=False) for x in cfg.get('trusted_proxies', ['127.0.0.1', '::1'])]
        self.deny = tuple(cfg.get('denylist') or DENY)
        self.pad = float(cfg.get('pad_seconds', 2.0))
        self.smb_conf = write_smb_conf(cfg, rt)
        self.slots = threading.BoundedSemaphore(int(cfg.get('max_parallel', 12)))
        self.audit_lock = threading.Lock()

    def t(self, s):
        return self.cat.get(s, s)

    def is_trusted(self, addr):
        try:
            a = ipaddress.ip_address(addr)
        except ValueError:
            return False
        return any(a in n for n in self.trusted)

    def client_ip(self, peer, xff):
        """The TCP peer; behind a trusted proxy the rightmost X-Forwarded-For entry that is not trusted."""
        if not self.is_trusted(peer):
            return peer
        for part in reversed([p.strip() for p in (xff or '').split(',') if p.strip()]):
            try:
                ipaddress.ip_address(part)
            except ValueError:
                return peer   # not an address: do not guess
            if not self.is_trusted(part):
                return part
        return peer

    def token(self):
        ts = str(int(time.time()))
        nonce = secrets.token_hex(12)
        mac = hmac.new(self.key, ('%s|%s' % (ts, nonce)).encode(), hashlib.sha256).hexdigest()
        return '%s.%s.%s' % (ts, nonce, mac)

    def use_token(self, tok):
        """True once for a token this process made, not older than 15 minutes."""
        try:
            ts, nonce, mac = (tok or '').split('.')
            age = time.time() - int(ts)
        except (ValueError, UnicodeError):
            return False
        good = hmac.new(self.key, ('%s|%s' % (ts, nonce)).encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(good.encode(), mac.encode('utf-8', 'replace')) or age > TOKEN_TTL or age < -60:
            return False
        with self.used_lock:
            if nonce in self.used:
                return False
            self.used[nonce] = True
            while len(self.used) > TABLE_MAX:
                self.used.popitem(last=False)
        return True

    def page(self, msg='', kind='', rule=None):
        text = self.template
        body = ''
        if msg:
            body = '<p class="msg %s" role="alert">%s' % (kind or 'err', html.escape(self.t(msg)))
            if rule:
                body += ' ' + html.escape(self.t(rule))
            body += '</p>'
        text = re.sub(r'\[\[(.+?)\]\]', lambda m: html.escape(self.t(m.group(1))), text)
        for k, v in (('{title}', html.escape(self.t('Change your password'))), ('{msg}', body), ('{token}', self.token()), ('{lang}', self.lang)):
            text = text.replace(k, v)
        return text.encode('utf-8')

    def audit(self, ip, user, result):
        u = user if user and re.fullmatch(r'[A-Za-z0-9._-]{1,64}', user) else '-'
        i = ip if ip and re.fullmatch(r'[0-9A-Fa-f:.]{2,45}', ip) else '-'
        with self.audit_lock:
            print('audit\t%s\t%s\t%s\t%s' % (datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), i, u, result), flush=True)

    def run_smbpasswd(self, user, old, new):
        env = {'PATH': self.cfg.get('path', '/run/current-system/sw/bin'), 'LANG': 'C.UTF-8'}
        try:
            p = subprocess.run([self.cfg['smbpasswd'], '-s', '-r', self.cfg['dc_address'], '-U', user, '--configfile', self.smb_conf],
                               input=old + '\n' + new + '\n' + new + '\n', capture_output=True, text=True, timeout=20, env=env)
            return p.returncode, (p.stdout or '') + (p.stderr or '')
        except (OSError, subprocess.SubprocessError):
            return 124, ''

    def change(self, ip, user, old, new, repeat):
        """The part after the CSRF check -> (http status, category, message, rule). Order: input, denylist, limits, smbpasswd, map."""
        what, val = check_input(user, old, new, repeat, self.deny)
        keys = ['ip:' + ip]
        if what == 'input':
            return 400, 'input', val, None, None
        if what == 'bad':
            u = clean_user(user) or ''
            self.limiter.fail(keys + ['acct:' + norm_user(u)])
            return 403, 'bad', MSG_BAD, None, u
        keys.append('acct:' + norm_user(val))
        if self.limiter.attempt(keys) > 0:   # counted before the DC is asked: every DC try counts, whatever the answer
            return 429, 'limited', MSG_LIMITED, None, val
        rc, out = self.run_smbpasswd(val, old, new)
        cat, msg, rule = map_result(rc, out)
        if cat == 'ok':
            self.limiter.success(keys)
        status = {'ok': 200, 'bad': 403, 'policy': 400, 'unavailable': 503}[cat]
        return status, cat, msg, rule, val


def make_handler(svc):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'hs-selfservice'
        sys_version = ''
        protocol_version = 'HTTP/1.0'
        timeout = 10

        def log_message(self, *a):
            pass

        def _send(self, status, body=b'', ctype='text/html; charset=utf-8', extra=None):
            self.send_response(status)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Content-Security-Policy', svc.csp)
            self.send_header('X-Frame-Options', 'DENY')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'same-origin')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Strict-Transport-Security', 'max-age=31536000')
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(body)

        def _text(self, status, msg, kind='err', rule=None):
            self._send(status, svc.page(msg, kind, rule))

        def _gate(self):
            """HTTPS through a trusted proxy only -> the client address, or None after the 403."""
            peer = self.client_address[0]
            proto = [p.strip().lower() for p in (self.headers.get('X-Forwarded-Proto') or '').split(',') if p.strip()]
            if not svc.is_trusted(peer) or not proto or any(p != 'https' for p in proto):
                svc.audit(svc.client_ip(peer, self.headers.get('X-Forwarded-For')), '-', 'plain-http')
                self._send(403, svc.t(MSG_PLAIN).encode('utf-8'), 'text/plain; charset=utf-8')
                return None
            return svc.client_ip(peer, self.headers.get('X-Forwarded-For'))

        def _path(self):
            return urlsplit(self.path).path

        def do_GET(self):
            ip = self._gate()
            if ip is None:
                return
            p = self._path()
            if p == '/password':
                self._text(200, '')
            elif p == '/':
                self._send(302, b'', extra={'Location': '/password'})
            else:
                self._send(404, svc.t(MSG_NOT_FOUND).encode('utf-8'), 'text/plain; charset=utf-8')

        do_HEAD = do_GET

        def _other(self):
            if self._gate() is not None:
                self._send(405, b'', extra={'Allow': 'GET, POST'})
        do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _other

        def do_POST(self):
            t0 = time.monotonic()
            if not svc.slots.acquire(blocking=False):
                self._send(503, svc.page(MSG_BUSY, 'err'))
                return
            try:
                res = self._post()
            except (OSError, ValueError):
                res = None
            finally:
                svc.slots.release()
            if res is None:
                self.close_connection = True
                return
            wait = svc.pad - (time.monotonic() - t0)   # same timing whatever the result
            if wait > 0:
                time.sleep(wait)
            self._send(*res)

        def _post(self):
            """-> (status, body, content type). The form is never shown over plain HTTP."""
            def page(status, msg, kind='err', rule=None):
                return status, svc.page(msg, kind, rule), 'text/html; charset=utf-8'
            ip = self._gate_quiet()
            if ip is None:
                return 403, svc.t(MSG_PLAIN).encode('utf-8'), 'text/plain; charset=utf-8'
            if self._path() != '/password':
                return page(404, MSG_NOT_FOUND)
            ctype = (self.headers.get('Content-Type') or '').split(';')[0].strip().lower()
            try:
                n = int(self.headers.get('Content-Length') or '')
            except ValueError:
                n = -1
            if ctype != 'application/x-www-form-urlencoded' or not 0 <= n <= MAX_BODY:
                return page(400, MSG_BAD_REQUEST)
            body = self.rfile.read(n).decode('utf-8', 'replace')
            form = {k: v[0] for k, v in parse_qs(body, keep_blank_values=True).items()}
            origin = self.headers.get('Origin') or self.headers.get('Referer') or ''
            same = urlsplit(origin).netloc.lower() == (self.headers.get('Host') or '-').lower() if origin else False
            if not same or not svc.use_token(form.get('token', '')):
                svc.audit(ip, '-', 'input')
                return page(403, MSG_EXPIRED)
            status, cat, msg, rule, user = svc.change(ip, form.get('user', ''), form.get('old', ''), form.get('new', ''), form.get('repeat', ''))
            svc.audit(ip, user, cat)
            return page(status, msg, 'ok' if cat == 'ok' else 'err', rule)

        def _gate_quiet(self):
            # the same check as _gate, but the answer is made by do_POST (padded like every POST answer)
            peer = self.client_address[0]
            proto = [p.strip().lower() for p in (self.headers.get('X-Forwarded-Proto') or '').split(',') if p.strip()]
            ip = svc.client_ip(peer, self.headers.get('X-Forwarded-For'))
            if not svc.is_trusted(peer) or not proto or any(p != 'https' for p in proto):
                svc.audit(ip, '-', 'plain-http')
                return None
            return ip

    return Handler


def watch(cfg):
    files = cfg.get('capability_files') or {}
    every = float(cfg.get('watch_interval', 10))
    while True:
        time.sleep(every)
        if package_on(files) is False:
            print('stopping: the package is off', flush=True)
            os._exit(0)


def cmd_serve(argv):
    if len(argv) != 2 or argv[0] != '--config':
        print('usage: selfservice.py serve --config <file>', file=sys.stderr)
        return 2
    with open(argv[1], encoding='utf-8') as f:
        cfg = json.load(f)
    rt = os.environ.get('RUNTIME_DIRECTORY') or cfg.get('runtime_dir')
    if not rt:
        print('no RUNTIME_DIRECTORY', file=sys.stderr)
        return 1
    svc = Service(cfg, rt.split(':')[0])
    srv = ThreadingHTTPServer(('127.0.0.1', int(cfg['port'])), make_handler(svc))
    srv.daemon_threads = True
    threading.Thread(target=watch, args=(cfg,), daemon=True).start()
    print('listening on 127.0.0.1:%s' % cfg['port'], flush=True)
    srv.serve_forever()
    return 0


def cmd_map(argv):
    rc = int(argv[0]) if argv else 1
    cat, msg, rule = map_result(rc, sys.stdin.read())
    print('%s\t%s' % (cat, msg + ((' ' + rule) if rule else '')))
    return 0


def cmd_limit_test(argv):
    now = [0.0]
    lim = Limiter(clock=lambda: now[0])
    for line in sys.stdin:
        p = line.split()
        if len(p) < 2:
            continue
        now[0] = float(p[0])
        verb, keys = p[1], p[2:]
        if verb == 'check':
            print(lim.check(keys))
        elif verb == 'attempt':
            print(lim.attempt(keys))
        elif verb == 'fail':
            lim.fail(keys)
        elif verb == 'success':
            lim.success(keys)
        elif verb == 'size':
            print(lim.size())
    return 0


def cmd_check_input(argv):
    d = json.load(sys.stdin)
    what, val = check_input(d.get('user', ''), d.get('old', ''), d.get('new', ''), d.get('repeat', ''))
    print('%s\t%s' % (what, val if val is not None else '-'))
    return 0


def cmd_make_config(argv):
    """make-config <file> key=value...: the config of the daemon, written the whole at once (no secret in it)."""
    if not argv:
        return 2
    here = os.path.dirname(os.path.abspath(__file__))
    kv = dict(x.split('=', 1) for x in argv[1:] if '=' in x)
    cfg = {'port': int(kv.get('port', 8486)), 'dc_address': kv.get('dc_address', ''), 'realm': kv.get('realm', ''),
           'workgroup': kv.get('workgroup', ''), 'language': kv.get('language', 'en') or 'en', 'smbpasswd': kv.get('smbpasswd', ''),
           'trusted_proxies': ['127.0.0.1', '::1'] + [x for x in kv.get('trusted', '').split(',') if x],
           'denylist': list(DENY), 'limits': {'account': [3, 900], 'ip': [5, 900], 'global': [30, 60]},
           'capability_files': {'list': kv.get('caps', ''), 'on': kv.get('caps_on', ''), 'off': kv.get('caps_off', '')},
           'i18n': os.path.join(here, 'i18n', 'de.tsv'), 'form': os.path.join(here, 'form.html')}
    tmp = argv[0] + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=1)
        f.write(chr(10))
    os.chmod(tmp, 0o644)
    os.replace(tmp, argv[0])
    return 0


def cmd_conf(argv):
    """conf <file> <key>: one value of the config ("" when missing)."""
    try:
        with open(argv[0], encoding='utf-8') as f:
            v = json.load(f).get(argv[1], '')
    except (OSError, ValueError, IndexError):
        v = ''
    print(v if isinstance(v, (str, int)) else json.dumps(v))
    return 0


def main(argv):
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(newline='\n', encoding='utf-8')
    if not argv:
        print(__doc__.strip().split('\n\n')[0], file=sys.stderr)
        return 2
    cmds = {'serve': cmd_serve, 'map': cmd_map, 'limit-test': cmd_limit_test, 'check-input': cmd_check_input,
            'make-config': cmd_make_config, 'conf': cmd_conf}
    if argv[0] not in cmds:
        print('unknown command', file=sys.stderr)
        return 2
    return cmds[argv[0]](argv[1:])


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
