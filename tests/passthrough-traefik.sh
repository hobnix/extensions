#!/usr/bin/env bash
# Live test of the extension passthrough with a real Traefik (exit 77 = skipped when `traefik` is not installed). Traefik listens on 127.0.0.1 test ports:
# public-https (passthrough by SNI) and lan-http, which is ALSO the public HTTP entrypoint (gatewayPublicHttp = 80). The base file has the catch-all of
# capabilities/gateway/module.nix with a source range that does NOT contain the peer (127.0.0.1), so the peer plays "a public source".
# The targets are python TCP/HTTP servers; the render bypasses the guard.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/extensions
export HS_PACKAGES_DIR=$PKGS   # the core finds the extensions here (it has none of its own)
command -v traefik >/dev/null 2>&1 || { echo "traefik is not installed: skipped"; exit 77; }
command -v curl >/dev/null 2>&1 || { echo "curl is not installed: skipped"; exit 77; }
PT=$PKGS/passthrough/passthrough.py
HTTPS=18543 HTTP=18080 TLST=18591 HTTPT=18592 TLST2=18593 WEBUI=18594
mkdir -p "$WORK/routes"
pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

# a TCP target that writes the first bytes it gets to a file, and an HTTP target that writes the Host header
python3 - "$WORK" <<'PY' &
import socketserver, sys, threading, http.server
work = sys.argv[1]
def tcp(port, name):
    class H(socketserver.BaseRequestHandler):
        def handle(self):
            data = self.request.recv(4096)
            open('%s/%s.bytes' % (work, name), 'wb').write(data)
    s = socketserver.ThreadingTCPServer(('127.0.0.1', port), H); s.allow_reuse_address = True
    threading.Thread(target=s.serve_forever, daemon=True).start()
class W(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(work + '/http.host', 'w').write(self.headers.get('Host', ''))
        self.send_response(200); self.end_headers(); self.wfile.write(b'http-target')
    def log_message(self, *a): pass
class U(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'the web interface')
    def log_message(self, *a): pass
tcp(18591, 'a'); tcp(18593, 'b')
for port, h in ((18592, W), (18594, U)):
    threading.Thread(target=http.server.ThreadingHTTPServer(('127.0.0.1', port), h).serve_forever, daemon=True).start()
threading.Event().wait()
PY
pids+=($!)

# the base file: only lan-http routers with the lanClient rule (a range without the peer), and the dead end of the public HTTPS entrypoint
python3 - "$WORK/routes" "$WEBUI" <<'PY'
import json, sys
d, webui = sys.argv[1], sys.argv[2]
client = '(ClientIP(`10.0.0.0/8`) || ClientIP(`192.168.0.0/16`))'
doc = {'http': {'services': {'hs-webui': {'loadBalancer': {'servers': [{'url': 'http://127.0.0.1:' + webui}]}}},
    'routers': {'hs-fallback': {'entryPoints': ['lan-http'], 'rule': 'HostRegexp(`.+`) && ' + client, 'priority': 1, 'service': 'hs-webui'}}},
  'tcp': {'routers': {'hs-deadend': {'entryPoints': ['public-https'], 'rule': 'HostSNI(`*`)', 'priority': 1, 'tls': {'passthrough': True}, 'service': 'hs-deadend'}},
          'services': {'hs-deadend': {'loadBalancer': {'servers': [{'address': '127.0.0.1:1'}]}}}}}
open(d + '/00-hs-base.yml', 'w').write(json.dumps(doc))
PY
render() {   # render <domain> <address> <https port> <http port|-> <proxy on|off>: public http port 80 = lan-http
  python3 "$PT" render "$1" "$2" "$3" "$4" "$5" 80 > "$WORK/routes/pt-$1.yml"
}
render a.example.com 127.0.0.1 $TLST $HTTPT off
render p.example.net 127.0.0.1 $TLST2 - on
printf '{"entryPoints":{"lan-http":{"address":"127.0.0.1:%s"},"public-https":{"address":"127.0.0.1:%s"}},"providers":{"file":{"directory":"%s","watch":true}},"log":{"level":"ERROR"}}\n' \
  $HTTP $HTTPS "$WORK/routes" > "$WORK/static.yml"
( cd "$WORK" && exec traefik --configfile="$WORK/static.yml" >"$WORK/t.log" 2>&1 ) & pids+=($!)
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$HTTP/" && break; sleep 0.2; done
sleep 1

hello() {   # hello <sni>: send a TLS ClientHello with that server name, print nothing; the answer (if any) is the connection state
  python3 - "$1" "$HTTPS" <<'PY'
import socket, ssl, sys
sni, port = sys.argv[1], int(sys.argv[2])
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
inc, out = ssl.MemoryBIO(), ssl.MemoryBIO()
obj = ctx.wrap_bio(inc, out, server_hostname=sni)
try: obj.do_handshake()
except ssl.SSLWantReadError: pass
s = socket.create_connection(('127.0.0.1', port), timeout=3)
s.sendall(out.read())
try: print('open' if s.recv(10) else 'closed')
except OSError: print('closed')
PY
}
wait_for() { for _ in $(seq 1 20); do [ -s "$1" ] && return 0; sleep 0.25; done; return 1; }

echo "-- TLS passthrough by SNI"
rm -f "$WORK/a.bytes"; hello a.example.com >/dev/null; wait_for "$WORK/a.bytes"
check_eq "a ClientHello for the domain reaches the target" "16" "$(head -c1 "$WORK/a.bytes" | od -An -tx1 | tr -d ' ')"
rm -f "$WORK/a.bytes"; hello www.a.example.com >/dev/null; wait_for "$WORK/a.bytes"
check_eq "and one for a subdomain" "16" "$(head -c1 "$WORK/a.bytes" | od -An -tx1 | tr -d ' ')"
rm -f "$WORK/a.bytes"
check_eq "another name is closed (dead end)" "closed" "$(hello other.org)"
check_eq "and does not reach the target" "no" "$([ -s "$WORK/a.bytes" ] && echo yes || echo no)"
rm -f "$WORK/b.bytes"; hello p.example.net >/dev/null; wait_for "$WORK/b.bytes"
check_eq "PROXY protocol v2 comes first when it is on" "0d0a0d0a000d0a515549540a" "$(head -c12 "$WORK/b.bytes" | od -An -tx1 | tr -d ' \n')"

echo "-- HTTP by Host on the same entrypoint as the local names"
check_eq "the domain's Host reaches the http target" "http-target" "$(curl -s -m 5 -H 'Host: x.a.example.com' "http://127.0.0.1:$HTTP/")"
check_eq "with the Host header kept" "x.a.example.com" "$(cat "$WORK/http.host")"
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Host: nobody.example.org' "http://127.0.0.1:$HTTP/")
check_eq "an unknown Host from a public source gets 404" "404" "$code"
check_eq "and never the web interface" "0" "$(curl -s -m 5 -H 'Host: nobody.example.org' "http://127.0.0.1:$HTTP/" | grep -c 'web interface')"
check_eq "a domain without an http port answers 404 on http" "404" "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Host: p.example.net' "http://127.0.0.1:$HTTP/")"

echo "-- deleting the file stops it"
rm -f "$WORK/routes/pt-a.example.com.yml"
ok=no; for _ in $(seq 1 20); do [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Host: x.a.example.com' "http://127.0.0.1:$HTTP/")" = 404 ] && { ok=yes; break; }; sleep 0.25; done
check_eq "within 5 s the http route is gone" "yes" "$ok"
check_eq "and the https route too" "closed" "$(hello a.example.com)"
finish
