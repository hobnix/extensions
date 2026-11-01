#!/usr/bin/env bash
# The extension ad-selfservice (extensions/ad-selfservice): the registry rows, the smbpasswd mapping, the limiter, the input checks, the web form
# served in-process with a fake smbpasswd, the --status/--log shapes, plan/start/stop/expose and the boot hook.
# No root, no network, no Samba: every place it looks at is a knob. The daemon test binds a free port on 127.0.0.1 (needs Linux or WSL).
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
PKGS=$HERE/extensions
export HS_PACKAGES_DIR=$PKGS   # the core finds the extensions here (it has none of its own)
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_PYTHON=python3
unset HS_GUIDED_TTY
export MSYS2_ARG_CONV_EXCL='*'
P=$PKGS/ad-selfservice
export HS_SCRIPTS=$SCRIPTS
export HS_CAPABILITIES_FILE=$WORK/caps HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/settings HS_MACHINE_FILE=$WORK/machine.toml
export HS_SERVICES_DIR=$WORK/services.d HS_DC=dc1
export HS_SYSTEMCTL=$WORK/fake/systemctl HS_SYSTEMD_RUN=$WORK/fake/systemd-run HS_INCUS=$WORK/fake/incus HS_ADSS_SMBPASSWD=$WORK/fake/smbpasswd
export HS_ADSS_ROUTES=$WORK/routes HS_ADSS_JOURNAL=$WORK/journal HS_ADSS_TUNNEL_FROM=$WORK/tunnel-from
mkdir -p "$WORK/fake" "$HS_STATE_DIR" "$HS_SETTINGS_DIR" "$HS_SERVICES_DIR"
T=$'\t'
SS="python3 -I $P/selfservice.py"
C="bash $P/selfservice-change.sh"
S="bash $P/selfservice.sh"
HSB="bash $SCRIPTS/lib/hs.sh"
printf 'ad\ngateway\nad-selfservice\n' > "$HS_CAPABILITIES_FILE"
printf 'hostName = "homeserver"\nadDomain = { realm = "AD.HOME.TEST", workgroup = "EX" }\n' > "$HS_MACHINE_FILE"
printf '10.99.0.2/32\n' > "$HS_ADSS_TUNNEL_FROM"
: > "$HS_ADSS_ROUTES"
echo inactive > "$WORK/unit-state"
# the fakes: systemctl (is-active reads unit-state, stop writes it), systemd-run (records its argv, the unit is active then), incus (the DC)
cat > "$WORK/fake/systemctl" <<EOF
#!/bin/bash
echo "\$@" >> "$WORK/systemctl.log"
case "\$1" in is-active) cat "$WORK/unit-state" ;; stop) echo inactive > "$WORK/unit-state" ;; esac
exit 0
EOF
cat > "$WORK/fake/systemd-run" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/systemd-run.argv"
echo x >> "$WORK/systemd-run.count"
echo active > "$WORK/unit-state"
exit 0
EOF
cat > "$WORK/fake/incus" <<'EOF'
#!/bin/bash
case "$1" in
  list) echo '10.10.95.5 (eth0)' ;;
  exec) printf 'Minimum password length: 7\nAccount lockout threshold (attempts): 0\n' ;;
esac
exit 0
EOF
# the fake smbpasswd: records argv, stdin and environment next to itself; the old password "oldpw" is the right one
cat > "$WORK/fake/smbpasswd" <<'EOF'
#!/bin/bash
d=$(dirname "$0")
echo "$@" > "$d/smb.argv"
cat > "$d/smb.stdin"
export -p > "$d/smb.env"
echo x >> "$d/smb.ran"
if [ "$(sed -n 1p "$d/smb.stdin")" = unavpw ]; then echo "something nobody has seen"; exit 1; fi
if [ "$(sed -n 1p "$d/smb.stdin")" = oldpw ]; then echo "Password changed for user alice"; exit 0; fi
echo "Failed to change password for alice: NT_STATUS_LOGON_FAILURE"; exit 1
EOF
chmod +x "$WORK"/fake/*
count() { wc -l < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

echo "-- registry rows"
. "$SCRIPTS/lib/registry-load.sh"
for w in "ext ad-selfservice status" "ext ad-selfservice log" "ext ad-selfservice start" "ext ad-selfservice stop" "ext ad-selfservice expose" \
         "sys ext ad-selfservice status" "sys ext ad-selfservice log" "sys ext ad-selfservice plan <action>" "sys ext ad-selfservice start <action>" "sys ext ad-selfservice boot"; do
  check_out "row: $w" "${T}$w${T}" registry_rows
done
check_eq "no row of the package is refused" "" "$(registry_refused ad-selfservice | paste -sd, -)"
printf 'ad\ngateway\n' > "$HS_CAPABILITIES_FILE"
check_eq "no row while the package is off" "0" "$(registry_rows | grep -c 'ad-selfservice')"
printf 'ad\ngateway\nad-selfservice\n' > "$HS_CAPABILITIES_FILE"

echo "-- smbpasswd output -> category (golden texts; made up for the tests, not seen on hardware)"
mapc() { printf '%s\n' "$2" | $SS map "$1"; }
check_eq "rc 0 is ok" "ok${T}Your password was changed." "$(mapc 0 'Password changed for user alice')"
for st in LOGON_FAILURE WRONG_PASSWORD NO_SUCH_USER ACCOUNT_LOCKED_OUT ACCOUNT_DISABLED ACCOUNT_RESTRICTION; do
  check_eq "NT_STATUS_$st is bad" "bad${T}The user name or the current password is wrong." "$(mapc 1 "Failed to change password for alice: NT_STATUS_$st")"
done
check_eq "NT_STATUS_PASSWORD_RESTRICTION is policy, the generic line" "policy${T}The new password does not meet the password rules of the domain." \
  "$(mapc 1 'machine dc1 rejected the password change: Error was : NT_STATUS_PASSWORD_RESTRICTION')"
check_out "policy with a complexity reason shows the fixed rule line" "^policy${T}.*must be more complex" \
  mapc 1 'dc1 rejected the password change: Error was: Password does not meet complexity requirements (NT_STATUS_PASSWORD_RESTRICTION)'
check_out "policy with a history reason" "^policy${T}.*was used before" mapc 1 'rejected the password change: Password was recently used (history)'
check_out "policy with a minimum age reason" "^policy${T}.*too recently" mapc 1 'rejected the password change: the password is too recent (minimum age)'
check_out "policy with a length reason" "^policy${T}.*too short" mapc 1 'rejected the password change: the password is too short'
check_eq "a server text never reaches the page" "policy${T}The new password does not meet the password rules of the domain." \
  "$(mapc 1 'NT_STATUS_PASSWORD_RESTRICTION <script>alert(1)</script> internal path /var/lib/samba')"
check_out "an unknown text is unavailable" "^unavailable${T}" mapc 1 'something nobody has seen'
check_out "a connection error is unavailable" "^unavailable${T}" mapc 1 'Connection to 10.10.95.5 failed (Error NT_STATUS_CONNECTION_REFUSED)'
check_out "a timeout (rc 124, no text) is unavailable" "^unavailable${T}" mapc 124 ''
check_out "rc 0 with a failure text is not ok" "^unavailable${T}" mapc 0 'Failed to change password'
a=$(mapc 1 'NT_STATUS_LOGON_FAILURE'); b=$(mapc 1 'NT_STATUS_NO_SUCH_USER')
check_eq "LOGON_FAILURE and NO_SUCH_USER give the identical message" "$a" "$b"

echo "-- the limiter with a fake clock"
lim() { $SS limit-test; }
check_eq "delays 1, 2, 4, 8 after each failure (IP key)" "1 2 4 8" "$(printf '%s\n' '0 fail ip:x' '0 check ip:x' '1 fail ip:x' '1 check ip:x' '3 fail ip:x' '3 check ip:x' '7 fail ip:x' '7 check ip:x' | lim | paste -sd' ' -)"
check_eq "the first attempt and one after the delay go through" "0 0" "$(printf '%s\n' '0 check acct:u' '0 fail acct:u' '1 check acct:u' | lim | paste -sd' ' -)"
check_eq "the 4th account failure within 900 s is limited" "yes" "$(printf '%s\n' '0 fail acct:u' '1 fail acct:u' '3 fail acct:u' '10 check acct:u' | lim | awk '$1 > 800 { print "yes" }')"
check_eq "limited at 899.5 s (1 s to wait), free again at 900 s" "1 0" "$(printf '%s
' '0 fail acct:u' '1 fail acct:u' '3 fail acct:u' '899.5 check acct:u' '900 check acct:u' | lim | paste -sd' ' -)"
check_eq "attempt counts the try up front: delays 1, 2 and the 4th is limited" "0 1 0 0 yes" "$(printf '%s
' '0 attempt acct:q' '0 attempt acct:q' '1 attempt acct:q' '3 attempt acct:q' '10 attempt acct:q' | lim | awk 'NR < 5 { printf "%s ", $1 } NR == 5 { print ($1 > 800 ? "yes" : "no") }')"
check_eq "a success after attempt resets" "0" "$(printf '%s
' '0 attempt acct:r' '0.1 success acct:r' '0.1 attempt acct:r' | lim | tail -n 1)"
check_eq "a success resets the account" "0" "$(printf '%s\n' '0 fail acct:s' '1 fail acct:s' '3 fail acct:s' '4 success acct:s' '4 check acct:s' | lim)"
check_eq "the IP limit is 5" "yes" "$(printf '%s\n' '0 fail ip:z' '1 fail ip:z' '3 fail ip:z' '7 fail ip:z' '15 fail ip:z' '40 check ip:z' | lim | awk '$1 > 800 { print "yes" }')"
glob=$(awk 'BEGIN { for (i = 1; i <= 31; i++) print 100, "check ip:k" i; print 160, "check ip:k99" }' | lim)
check_eq "the first 30 attempts in 60 s go through" "30" "$(head -n 30 <<<"$glob" | grep -c '^0$')"
check_eq "the 31st attempt in 60 s is limited, free after the window" "60 0" "$(tail -n 2 <<<"$glob" | paste -sd' ' -)"
check_eq "the table stays at 10000 keys" "10000" "$(awk 'BEGIN { for (i = 0; i < 10005; i++) print 0, "fail acct:k" i; print 0, "size" }' | lim)"

echo "-- check-input"
ci() { python3 -I -c 'import json,sys; print(json.dumps(dict(zip(("user", "old", "new", "repeat"), sys.argv[1:]))))' "$@" | $SS check-input; }
check_eq "DOMAIN\\user is normalised" "ok${T}alice" "$(ci 'EX\alice' a b b)"
check_eq "user@realm is normalised" "ok${T}alice" "$(ci 'alice@ad.home.test' a b b)"
check_out "a newline in a password is input" "^input${T}" ci alice a $'x\ny' $'x\ny'
check_out "a NUL-free but too long password is input" "^input${T}" ci alice a "$(printf 'x%.0s' $(seq 1 257))" "$(printf 'x%.0s' $(seq 1 257))"
check_out "new != repeat is input" "^input${T}" ci alice a b c
check_out "new == old is input" "^input${T}" ci alice same same same
check_out "an empty user name is input" "^input${T}" ci '' a b b
check_out "a user name with a space is input" "^input${T}" ci 'al ice' a b b
check_eq "a trailing newline does not get past the denylist" "bad${T}-" "$(ci $'Administrator
' a b b)"
check_out "a full-width look-alike is not a valid name" "^input${T}" ci 'ＡＤＭＩＮ' a b b
check_eq "norm_user folds case and compatibility forms" "krbtgt" "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import selfservice; print(selfservice.norm_user(" Ｋｒｂｔｇｔ"))' "$P")"
for u in Administrator KRBTGT guest EX\\Administrator administrator@ad.home.test; do
  check_eq "$u is bad" "bad${T}-" "$(ci "$u" a b b)"
done

echo "-- the server: HTTPS only, CSRF, headers, timing, no password anywhere"
rm -f "$WORK"/fake/smb.*
cat > "$WORK/server-test.py" <<'PYEOF'
import http.client, json, os, re, socket, subprocess, sys, threading, time
work, pkg = sys.argv[1], sys.argv[2]
s = socket.socket(); s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]; s.close()
rt = os.path.join(work, 'rt'); os.makedirs(rt, exist_ok=True)
caps = os.path.join(work, 'srv-caps'); open(caps, 'w').write('ad-selfservice\n')
cfg = {'port': port, 'dc_address': '10.10.95.5', 'realm': 'AD.HOME.TEST', 'workgroup': 'EX', 'language': 'en', 'smbpasswd': os.path.join(work, 'fake', 'smbpasswd'),
       'trusted_proxies': ['127.0.0.1', '::1'], 'denylist': ['administrator', 'krbtgt', 'guest'], 'limits': {}, 'runtime_dir': rt,
       'path': '/usr/bin:/bin', 'watch_interval': 1, 'capability_files': {'list': caps, 'on': os.path.join(work, 'none'), 'off': os.path.join(work, 'none-off')},
       'i18n': os.path.join(pkg, 'i18n', 'de.tsv'), 'form': os.path.join(pkg, 'form.html')}
cf = os.path.join(work, 'srv-config.json'); json.dump(cfg, open(cf, 'w'))
out = open(os.path.join(work, 'daemon.out'), 'w')
proc = subprocess.Popen([sys.executable, '-I', os.path.join(pkg, 'selfservice.py'), 'serve', '--config', cf], stdout=out, stderr=subprocess.STDOUT)
for _ in range(50):
    try: socket.create_connection(('127.0.0.1', port), 1).close(); break
    except OSError: time.sleep(0.1)
res = []
def ok(name, cond, detail=''): res.append(('ok   ' if cond else 'FAIL ') + name + ('' if cond else ': ' + str(detail)))
H = {'Host': 'pw.example.org', 'X-Forwarded-Proto': 'https'}
def req(method, path, headers=None, body=None):
    c = http.client.HTTPConnection('127.0.0.1', port, timeout=30)
    t = time.monotonic(); c.request(method, path, body=body, headers=headers or {}); r = c.getresponse(); data = r.read().decode('utf-8', 'replace')
    return r.status, r.getheaders(), data, time.monotonic() - t
def token(ip='192.0.2.1'):
    st, h, body, _ = req('GET', '/password', dict(H, **{'X-Forwarded-For': ip}))
    m = re.search(r'name="token" value="([^"]+)"', body); return m.group(1) if m else ''
def post(user, old, new, repeat, ip, tok=None, origin='https://pw.example.org', extra=None):
    from urllib.parse import urlencode
    f = {'user': user, 'old': old, 'new': new, 'repeat': repeat, 'token': token(ip) if tok is None else tok}
    h = dict(H, **{'Content-Type': 'application/x-www-form-urlencoded', 'X-Forwarded-For': ip}); h.update(extra or {})
    if origin: h['Origin'] = origin
    return req('POST', '/password', h, urlencode(f))
def hdr(h, k): return [v for n, v in h if n.lower() == k.lower()]
try:
    st, h, body, _ = req('GET', '/password', {'Host': 'pw.example.org'})
    ok('plain request (no X-Forwarded-Proto) -> 403, no form', st == 403 and '<form' not in body, (st, body[:80]))
    st, h, body, _ = req('GET', '/password', dict(H, **{'X-Forwarded-Proto': 'http'}))
    ok('X-Forwarded-Proto http -> 403', st == 403)
    st, h, body, _ = req('GET', '/password', H)
    ok('GET /password -> 200 with a form and a token', st == 200 and '<form' in body and 'name="token"' in body, st)
    csp = ' '.join(hdr(h, 'Content-Security-Policy'))
    ok('CSP with the style hash, form-action, frame-ancestors', "style-src 'sha256-" in csp and "form-action 'self'" in csp and "frame-ancestors 'none'" in csp and "default-src 'none'" in csp, csp)
    for k, v in (('X-Frame-Options', 'DENY'), ('X-Content-Type-Options', 'nosniff'), ('Referrer-Policy', 'same-origin'), ('Cache-Control', 'no-store')):
        ok('header ' + k, hdr(h, k) == [v], hdr(h, k))
    ok('header Strict-Transport-Security', any(v.startswith('max-age=') for v in hdr(h, 'Strict-Transport-Security')))
    ok('no Set-Cookie', not hdr(h, 'Set-Cookie'))
    ok('the page has no JavaScript', '<script' not in body)
    st, h, body, _ = req('GET', '/', H); ok('GET / -> 302 /password', st == 302 and hdr(h, 'Location') == ['/password'], st)
    st, h, body, _ = req('GET', '/other', H); ok('anything else -> 404', st == 404, st)
    st, *_ = post('alice', 'oldpw', 'newpw1', 'newpw1', '192.0.2.10', tok='')
    ok('POST without a token -> 403', st == 403, st)
    st, *_ = post('alice', 'oldpw', 'newpw1', 'newpw1', '192.0.2.10', origin='https://evil.example.net')
    ok('POST with a wrong Origin -> 403', st == 403, st)
    st, *_ = post('alice', 'oldpw', 'newpw1', 'newpw1', '192.0.2.10', origin=None)
    ok('POST without Origin and Referer -> 403', st == 403, st)
    ok('the fake smbpasswd has not run yet', not os.path.exists(os.path.join(work, 'fake', 'smb.ran')))
    tok = token('192.0.2.11')
    st, h, body, dt = post('alice', 'oldpw', 'newpw1', 'newpw1', '192.0.2.11', tok=tok)
    ok('a good request -> 200 "Your password was changed."', st == 200 and 'Your password was changed.' in body, (st, body[-200:]))
    ok('ok takes at least 2.0 s', dt >= 1.95, dt)
    stdin = open(os.path.join(work, 'fake', 'smb.stdin')).read()
    ok('smbpasswd got old, new, new on stdin', stdin == 'oldpw\nnewpw1\nnewpw1\n', repr(stdin))
    argv = open(os.path.join(work, 'fake', 'smb.argv')).read()
    ok('argv: -s -r <dc> -U <user> --configfile, no password', argv.startswith('-s -r 10.10.95.5 -U alice --configfile ') and 'oldpw' not in argv and 'newpw1' not in argv, argv)
    env = open(os.path.join(work, 'fake', 'smb.env')).read()
    ok('no password in the environment of smbpasswd', 'oldpw' not in env and 'newpw1' not in env)
    conf = open(os.path.join(rt, 'smb.conf')).read()
    ok('smb.conf: signing and encryption required, SMB2+', 'client signing = required' in conf and 'client smb encrypt = required' in conf and 'client min protocol = SMB2_02' in conf)
    st, *_ = post('alice', 'oldpw', 'newpw2', 'newpw2', '192.0.2.11', tok=tok)
    ok('a used token -> 403', st == 403, st)
    st, h, body, dt = post('carol', 'wrongpw', 'newpw3', 'newpw3', '192.0.2.12')
    ok('wrong old password -> the "wrong" message', 'The user name or the current password is wrong.' in body, body[-200:])
    ok('bad takes at least 2.0 s', dt >= 1.95, dt)
    for f in ('smb.ran',):
        try: os.remove(os.path.join(work, 'fake', f))
        except OSError: pass
    for u in ('Administrator', 'KRBTGT', 'guest', 'EX\\administrator'):
        st, h, body, dt = post(u, 'oldpw', 'newpw4', 'newpw4', '192.0.2.13')
        ok('denied account ' + u + ' -> the "wrong" message', 'The user name or the current password is wrong.' in body, body[-120:])
    ok('the denied accounts never reached smbpasswd', not os.path.exists(os.path.join(work, 'fake', 'smb.ran')))
    st, h, body, dt = post('alice', 'oldpw', 'newpw5', 'different', '192.0.2.14')
    ok('new != repeat -> 400, no DC call', st == 400 and not os.path.exists(os.path.join(work, 'fake', 'smb.ran')), st)
    st, h, body, dt = post('gina', 'oldpw', 'newpw7', 'newpw7', '192.0.2.30', origin=None, extra={'Referer': 'https://pw.example.org/password'})
    ok('a browser with Referrer-Policy same-origin may send only a Referer: accepted', st == 200 and 'Your password was changed.' in body, (st, body[-120:]))
    st, *_ = post('gina', 'oldpw', 'newpw7', 'newpw7', '192.0.2.31', origin='null')
    ok('Origin: null is refused (what no-referrer made browsers send)', st == 403, st)
    st, h, body, dt = post('gina', 'oldpw', 'newpw7', 'newpw7', '192.0.2.32', tok='é.é.é')
    ok('a non-ASCII token gets the normal padded 403', st == 403 and dt >= 1.95, (st, dt))
    # parallel tries on one account cannot all reach the DC; unavailable tries count too
    ran = os.path.join(work, 'fake', 'smb.ran')
    def nran():
        try: return len(open(ran).read().split())
        except OSError: return 0
    before = nran(); par = []
    def one(i): par.append(post('erin', 'wrongpw', 'newpw8', 'newpw8', '192.0.2.%d' % (40 + i))[0])
    ts = [threading.Thread(target=one, args=(i,)) for i in range(8)]
    [t.start() for t in ts]; [t.join() for t in ts]
    ok('8 parallel tries on one account: at most 3 reach the DC', nran() - before <= 3 and 429 in par, (nran() - before, sorted(par)))
    codes = []
    for i in range(4):
        codes.append(post('frank', 'unavpw', 'newpw9', 'newpw9', '192.0.2.%d' % (60 + i))[0]); time.sleep(3)
    ok('unavailable answers count: 3 tries (503), the 4th is limited', codes == [503, 503, 503, 429], codes)
    # the account limit: 3 failures, the 4th try is limited (a second between them so the growing delay has passed)
    codes = []
    for i in range(4):
        st, h, body, dt = post('dave', 'wrongpw', 'newpw6', 'newpw6', '192.0.2.%d' % (20 + i))
        codes.append(st); time.sleep(3)
    ok('3 bad tries, the 4th is limited (429)', codes == [403, 403, 403, 429], codes)
    ok('the limited answer says so', 'Too many tries' in body, body[-200:])
    ok('the limited answer also takes 2.0 s', dt >= 1.95, dt)
    time.sleep(0.5)
    lines = open(os.path.join(work, 'daemon.out')).read().splitlines()
    audit = [l for l in lines if l.startswith('audit\t')]
    ok('every audit line has 5 fields', all(len(l.split('\t')) == 5 for l in audit), audit[:2])
    results = [l.split('\t')[4] for l in audit]
    ok('audit has plain-http, ok, bad, limited, input', all(r in results for r in ('plain-http', 'ok', 'bad', 'limited', 'input')), results)
    alltext = '\n'.join(lines)
    ok('no password in the audit/journal output', not re.search(r'oldpw|newpw|wrongpw|different', alltext), alltext[:200])
    ok('only audit lines or plain lines are printed', all(l.startswith('audit\t') or l.startswith('listening') for l in lines), [l for l in lines if not (l.startswith('audit\t') or l.startswith('listening'))][:3])
    open(caps, 'w').write('')
    for _ in range(80):
        if proc.poll() is not None: break
        time.sleep(0.1)
    ok('the daemon exits 0 within seconds once the package is off', proc.poll() == 0, proc.poll())
    ok('and says why', 'stopping: the package is off' in open(os.path.join(work, 'daemon.out')).read())
finally:
    if proc.poll() is None: proc.kill()
print('\n'.join(res))
PYEOF
if o=$(python3 -I "$WORK/server-test.py" "$WORK" "$P" 2>&1); then
  while IFS= read -r line; do case "$line" in 'ok   '*) pass "${line#ok   }" ;; 'FAIL '*) fail "${line#FAIL }" ;; *) fail "server test output: $line" ;; esac; done <<<"$o"
else fail "server test crashed: $(tail -n 5 <<<"$o" | tr '\n' ' ')"; fi

echo "-- --status and --log"
check_eq "--status with nothing set up: 14 keys, - for what is missing" "running${T}no
wanted${T}no
port${T}8486
dc${T}dc1
dc_address${T}-
exposure${T}private
fqdn${T}-
public_proxy${T}-
tls_route${T}no
ad_lockout_threshold${T}0
limit_account${T}3/900
limit_ip${T}5/900
limit_global${T}30/60
package${T}on" "$($S --status 2>/dev/null)"
check_eq "--status without a readable DC says - for the threshold" "-" "$(HS_INCUS=false $S --status 2>/dev/null | awk -F"$T" '$1 == "ad_lockout_threshold" { print $2 }')"
printf 'listening on 127.0.0.1:8486\naudit\t2026-01-01T10:00:00Z\t10.0.0.5\talice\tok\naudit\t2026-01-01T10:01:00Z\t10.0.0.6\tbad user!\tbad\naudit\t2026-01-01T10:02:00Z\t10.0.0.7\tbob\tlimited\naudit\tshort\tline\naudit\t2026-01-01T10:03:00Z\t10.0.0.8\tcarol\tevil\n' > "$HS_ADSS_JOURNAL"
check_eq "--log: newest first, bad names become -, short lines and unknown results are dropped" "2026-01-01T10:02:00Z${T}10.0.0.7${T}bob${T}limited
2026-01-01T10:01:00Z${T}10.0.0.6${T}-${T}bad
2026-01-01T10:00:00Z${T}10.0.0.5${T}alice${T}ok" "$($S --log 2>/dev/null)"
check_out "hs sys ext ad-selfservice log is the same" "alice${T}ok" $HSB sys ext ad-selfservice log
check_out "hs ext ad-selfservice log shows a table" "bob" $HSB ext ad-selfservice log --lines 2
check_out "hs ext ad-selfservice log --lines must be a number" "number" bash -c "$HSB ext ad-selfservice log --lines x 2>&1"

echo "-- plan and start: the TLS route comes first"
run() { rc=0; out=$(timeout 60 "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
echo zoraxy > "$HS_SETTINGS_DIR/reverseProxy"
printf 'ok%spw.example.org%s/password%shttp://127.0.0.1:8486%sad-selfservice%s\n' "$T" "$T" "$T" "$T" "$T" > "$HS_ADSS_ROUTES"
run $C plan start start; if [ "$rc" = 1 ] && has "^reason${T}no TLS route" && has "^fix${T}hs services apply"; then pass "reverseProxy = zoraxy: refused with the fix lines"; else fail "zoraxy: rc=$rc $out"; fi
echo traefik-public > "$HS_SETTINGS_DIR/reverseProxy"
: > "$HS_ADSS_ROUTES"
run $C plan start; if [ "$rc" = 1 ] && has "^reason${T}no TLS route"; then pass "no ok row in the routes: refused"; else fail "no row: rc=$rc $out"; fi
printf 'ok%spw.example.org%s/%shttp://127.0.0.1:8486%sad-selfservice%s\n' "$T" "$T" "$T" "$T" "$T" > "$HS_ADSS_ROUTES"
run $C plan start; if [ "$rc" = 1 ]; then pass "an ok row for / only is not a /password route"; else fail "wrong path: rc=$rc $out"; fi
run $C start start; if [ "$rc" = 1 ] && [ ! -f "$HS_STATE_DIR/ad-selfservice/wanted" ] && [ ! -f "$WORK/systemd-run.argv" ]; then pass "start refused: no unit, no wanted marker"; else fail "start without route: rc=$rc $out"; fi
check_eq "start declared the descriptor first (so the route can be made)" "yes" "$([ -f "$HS_SERVICES_DIR/ad-selfservice.toml" ] && grep -q 'port = 8486' "$HS_SERVICES_DIR/ad-selfservice.toml" && echo yes)"
printf 'ok%spw.example.org%s/password%shttp://127.0.0.1:8486%sad-selfservice%s\n' "$T" "$T" "$T" "$T" "$T" > "$HS_ADSS_ROUTES"
run $C plan start; if [ "$rc" = 0 ] && has "^status${T}ok" && has "^long${T}no"; then pass "plan start with the route: ok"; else fail "plan start: rc=$rc $out"; fi
printf 'gateway\nad-selfservice\n' > "$HS_CAPABILITIES_FILE"
run $C plan start; if [ "$rc" = 1 ] && has "capability ad is off"; then pass "ad off: refused"; else fail "ad off: rc=$rc $out"; fi
printf 'ad\ngateway\n' > "$HS_CAPABILITIES_FILE"
run $C plan start; if [ "$rc" = 1 ] && has "ad-selfservice is off"; then pass "package off: refused"; else fail "package off: rc=$rc $out"; fi
printf 'ad\ngateway\nad-selfservice\n' > "$HS_CAPABILITIES_FILE"
run env HS_ADSS_SMBPASSWD=/nonexistent/smbpasswd PATH=/usr/bin:/bin $C plan start; if [ "$rc" = 1 ] && has "smbpasswd"; then pass "no smbpasswd: refused"; else fail "no smbpasswd: rc=$rc $out"; fi
run $C start start
if [ "$rc" = 0 ] && has "^status${T}done"; then pass "start with the route: done"; else fail "start: rc=$rc $out"; fi
argv=$(cat "$WORK/systemd-run.argv" 2>/dev/null)
check_out "systemd-run has DynamicUser=yes" "^DynamicUser=yes$" echo "$argv"
check_out "systemd-run has IPAddressAllow with the DC" "^IPAddressAllow=127.0.0.1 ::1 10.10.95.5$" echo "$argv"
check_out "systemd-run runs selfservice.py serve --config" "selfservice.py" echo "$argv"
if grep -Eqi 'pass|secret|token|oldpw' <<<"$argv"; then fail "no password or secret in the systemd-run argv: $argv"; else pass "no password or secret in the systemd-run argv"; fi
check_eq "wanted is written (0644)" "yes" "$([ -f "$HS_STATE_DIR/ad-selfservice/wanted" ] && echo yes)"
check_out "config.json: DC address, port, tunnel source trusted, realm" '"dc_address": "10.10.95.5"' cat "$HS_STATE_DIR/ad-selfservice/config.json"
check_out "config.json trusts the tunnel source" '10.99.0.2/32' cat "$HS_STATE_DIR/ad-selfservice/config.json"
if grep -Eqi 'password|secret' "$HS_STATE_DIR/ad-selfservice/config.json"; then fail "config.json holds no secret"; else pass "config.json holds no secret"; fi
echo traefik-public > "$HS_SETTINGS_DIR/reverseProxy"
n1=$(count "$WORK/systemd-run.count")
run $C start start; check_eq "start again while running stops and runs it again (the new DC address applies)" "$((n1 + 1))" "$(count "$WORK/systemd-run.count")"
check_out "...after a stop" "^stop hs-ad-selfservice" cat "$WORK/systemctl.log"

echo "-- hs ext ad-selfservice status/stop through hs"
check_out "status shows running and the route" "Running" $HSB ext ad-selfservice status
check_eq "--status after start: running, wanted, tls_route" "yes yes yes" "$($S --status 2>/dev/null | awk -F"$T" '$1 == "running" || $1 == "wanted" || $1 == "tls_route" { print $2 }' | paste -sd' ' -)"
$HSB ext ad-selfservice stop >/dev/null 2>&1
check_eq "stop removes wanted and stops the unit" "no" "$([ -f "$HS_STATE_DIR/ad-selfservice/wanted" ] && echo yes || echo no)"
check_eq "stop: the unit is inactive" "inactive" "$(cat "$WORK/unit-state")"

echo "-- expose"
echo zoraxy > "$HS_SETTINGS_DIR/reverseProxy"
run $C plan expose public pw.example.org; if [ "$rc" = 1 ] && has "traefik-public"; then pass "expose public refused without traefik-public"; else fail "expose public zoraxy: rc=$rc $out"; fi
echo traefik-public > "$HS_SETTINGS_DIR/reverseProxy"
run $C plan expose public pw.example.org
if [ "$rc" = 0 ] && has "^confirm_name${T}pw.example.org$" && has "^warn${T}" && has "^long${T}no"; then pass "plan expose public: warn rows and confirm_name"; else fail "plan expose public: rc=$rc $out"; fi
run $C plan expose public 'not a name'; if [ "$rc" = 1 ]; then pass "a bad host name is refused"; else fail "bad name: rc=$rc"; fi
run $C start expose public pw.example.org; if [ "$rc" = 1 ] && has "type the full name"; then pass "start expose public without --confirm: refused"; else fail "no confirm: rc=$rc $out"; fi
run $C start expose public pw.example.org --confirm wrong.example.org; if [ "$rc" = 1 ]; then pass "a wrong --confirm is refused"; else fail "wrong confirm: rc=$rc"; fi
run $C start expose public pw.example.org --confirm pw.example.org
d=$HS_SERVICES_DIR/ad-selfservice.toml
if [ "$rc" = 0 ] && grep -q '^exposure = "public-ok"' "$d" && grep -q 'public_paths = \["/password"\]' "$d" && grep -q 'fqdn = \["pw.example.org"\]' "$d"; then pass "with --confirm the descriptor is public-ok, public_paths /password, the name"; else fail "expose public: rc=$rc $out $(cat "$d" 2>/dev/null | tr '\n' ' ')"; fi
check_out "hs ext ad-selfservice expose public --confirm (through hs)" "hs services apply" $HSB ext ad-selfservice expose public pw.example.org --confirm pw.example.org
check_out "expose public without a terminal and without --confirm fails" "Nobody to ask" bash -c "$HSB ext ad-selfservice expose public pw.example.org 2>&1 </dev/null"
echo active > "$WORK/unit-state"; : > "$HS_STATE_DIR/ad-selfservice/wanted"
run $C plan expose private; if [ "$rc" = 0 ] && has "^warn${T}.*stopped"; then pass "plan expose private while running warns that it is stopped"; else fail "plan private: rc=$rc $out"; fi
run $C start expose private
if [ "$rc" = 0 ] && grep -q '^exposure = "private-ok"' "$d"; then pass "expose private: the descriptor is private-ok again"; else fail "expose private: rc=$rc $out"; fi
check_eq "expose private while running stops the unit and removes wanted" "inactive no" "$(cat "$WORK/unit-state") $([ -f "$HS_STATE_DIR/ad-selfservice/wanted" ] && echo yes || echo no)"

echo "-- boot"
rm -f "$WORK/systemd-run.count" "$HS_STATE_DIR/ad-selfservice/wanted"; echo inactive > "$WORK/unit-state"
run $C boot; if [ "$rc" = 0 ] && has "^status${T}skipped" && [ ! -f "$WORK/systemd-run.count" ]; then pass "boot without wanted: skipped, the unit is not run"; else fail "boot no wanted: rc=$rc $out"; fi
: > "$HS_STATE_DIR/ad-selfservice/wanted"
run $C boot; if [ "$rc" = 0 ] && has "^status${T}started" && [ "$(count "$WORK/systemd-run.count")" = 1 ]; then pass "boot with wanted: started, the unit is run"; else fail "boot wanted: rc=$rc $out"; fi
check_out "boot runs from config.json (the DC address)" "^IPAddressAllow=127.0.0.1 ::1 10.10.95.5$" cat "$WORK/systemd-run.argv"
rm -f "$WORK/systemd-run.count"; printf 'ad\ngateway\n' > "$HS_CAPABILITIES_FILE"
run $C boot; if [ "$rc" = 0 ] && has "^status${T}skipped" && [ ! -f "$WORK/systemd-run.count" ]; then pass "boot with the package off: skipped"; else fail "boot package off: rc=$rc $out"; fi
printf 'ad\ngateway\nad-selfservice\n' > "$HS_CAPABILITIES_FILE"
mv "$HS_STATE_DIR/ad-selfservice/config.json" "$WORK/config.json.bak"
run $C boot; if [ "$rc" = 0 ] && has "^status${T}refused"; then pass "boot without config.json: refused, exit 0"; else fail "boot no config: rc=$rc $out"; fi
mv "$WORK/config.json.bak" "$HS_STATE_DIR/ad-selfservice/config.json"
check_eq "boot through hs sys: exit 0 and a status line" "yes" "$($HSB sys ext ad-selfservice boot </dev/null 2>/dev/null | grep -q "^status${T}" && echo yes)"
finish
