#!/usr/bin/env bash
# The extension passthrough (capabilities/passthrough): golden route files, the guard, plan/start of add and remove, the list/state/status shapes.
# No root, no Traefik, no network: every place it looks at is a knob.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/extensions
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_PYTHON=python3
unset HS_GUIDED_TTY
export MSYS2_ARG_CONV_EXCL='*'
P=$PKGS/passthrough
export HS_SCRIPTS=$SCRIPTS
export HS_GATEWAY_DIR=$WORK/gw HS_GATEWAY_PUBLIC_FILE=$WORK/etc/gateway-public HS_CAPABILITIES_FILE=$WORK/caps HS_STATE_DIR=$WORK/state
export HS_SETTINGS_DIR=$WORK/settings HS_MACHINE_FILE=$WORK/machine.toml HS_SITE_NAME_FILE=$WORK/site-name
export HS_PT_HOST_ADDRS=$WORK/host-addrs HS_PT_INSTANCE_ADDRS=$WORK/inst-addrs HS_PT_PROXY_HOSTS=$WORK/proxy-hosts
export HS_GATEWAY_LISTENERS=$WORK/listeners HS_ETC_DIR=$WORK/etc HS_GATEWAY_UNIT_STATE=$WORK/unit HS_PT_PROBE=$WORK/probe HS_INCUS=false
mkdir -p "$HS_GATEWAY_DIR/routes" "$HS_GATEWAY_DIR/tmp" "$HS_SETTINGS_DIR" "$HS_STATE_DIR" "$HS_ETC_DIR"
R="python3 $P/passthrough.py"
C="bash $P/passthrough-change.sh"
S="bash $P/passthrough.sh"
RT=$HS_GATEWAY_DIR/routes
T=$'\t'
echo gateway > "$HS_CAPABILITIES_FILE"
printf 'https=443\nhttp=80\n' > "$HS_GATEWAY_PUBLIC_FILE"
printf 'hostName = "homeserver"\nadDomain = { realm = "AD.HOME.TEST", workgroup = "EX" }\n' > "$HS_MACHINE_FILE"
echo homeserver > "$HS_SITE_NAME_FILE"
printf 'example.org,example.net\n' > "$HS_SETTINGS_DIR/proxyDomains"
printf '2: br0    inet 192.168.1.10/24 brd 192.168.1.255 scope global br0\n2: br0    inet6 fd00::10/64 scope global\n' > "$HS_PT_HOST_ADDRS"
printf '10.10.95.5 (eth0)\n' > "$HS_PT_INSTANCE_ADDRS"
printf 'public.example.io\n' > "$HS_PT_PROXY_HOSTS"
echo active > "$HS_GATEWAY_UNIT_STATE"; : > "$HS_GATEWAY_LISTENERS"
printf '#!/usr/bin/env bash\ncase "$1" in 192.168.1.20) exit 0 ;; esac\nexit 1\n' > "$WORK/probe"; chmod +x "$WORK/probe"
run() { rc=0; out=$(timeout 30 "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
refused() {   # refused <what> <text> <args of plan>
  local what=$1 text=$2; shift 2
  run $C plan "$@"
  if [ "$rc" = 1 ] && has "^reason${T}.*$text"; then pass "$what"; else fail "$what: rc=$rc $out"; fi
}

echo "-- render: golden files"
g1="# hs-gateway passthrough v1 domain=a.example.com address=192.168.1.20 https=443 http=80 proxy=off
# written by hs ext passthrough; do not edit
tcp:
  routers:
    pt-a-example-com:
      entryPoints: [public-https]
      rule: 'HostSNI(\`a.example.com\`) || HostSNIRegexp(\`^.+\.a\.example\.com\$\`)'
      tls:
        passthrough: true
      service: pt-a-example-com
  services:
    pt-a-example-com:
      loadBalancer:
        servers:
          - address: '192.168.1.20:443'
http:
  routers:
    pt-a-example-com-http:
      entryPoints: [lan-http]
      rule: 'Host(\`a.example.com\`) || HostRegexp(\`^.+\.a\.example\.com\$\`)'
      service: pt-a-example-com-http
  services:
    pt-a-example-com-http:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: 'http://192.168.1.20:80'"
check_eq "v4, proxy off, http on port 80 (the entrypoint lan-http)" "$g1" "$($R render a.example.com 192.168.1.20 443 80 off 80)"
out=$($R render x.example.com fd00::5 443 80 on 8008)
check_out "v6 is bracketed" "address: '\[fd00::5\]:443'" echo "$out"
check_out "proxy on: PROXY protocol v2" "proxyProtocol:" echo "$out"
check_out "a public http port other than 80: entrypoint public-http" "entryPoints: \[public-http\]" echo "$out"
check_out "http url is bracketed too" "url: 'http://\[fd00::5\]:80'" echo "$out"
out=$($R render x.example.com 192.168.1.20 443 - off 80)
check_eq "http off: no http section" "0" "$(grep -c '^http:' <<<"$out")"
check_eq "proxy off: no proxyProtocol" "0" "$(grep -c proxyProtocol <<<"$out")"
out=$($R render x.example.com 192.168.1.20 443 80 off 0)
check_eq "public http 0: no http section" "0" "$(grep -c '^http:' <<<"$out")"
check_eq "the header is line 1" "1" "$(head -n 1 <<<"$out" | grep -c '^# hs-gateway passthrough v1 domain=x.example.com address=192.168.1.20 https=443 http=80 proxy=off$')"

echo "-- checks of the input"
for d in 'EXAMPLE.com' ; do check_eq "a domain is lower-cased" "example.com" "$($R domain $d)"; done
for bad in single '*.x.com' 'a.local' 'a.lan' 'a.home.arpa' 'a.internal' 'a.localhost' 'a b.com' "$(printf 'a%.0s' $(seq 1 63)).com"; do
  rc=0; $R domain "$bad" >/dev/null 2>&1 || rc=$?; check_eq "domain refused: $bad" 1 "$rc"
done
A="$R address"; K="--host-addrs $HS_PT_HOST_ADDRS --instance-addrs $HS_PT_INSTANCE_ADDRS"
check_eq "a private v4 address is fine" "192.168.1.20" "$($A 192.168.1.20 $K)"
check_eq "a ULA v6 address is fine" "fd00::5" "$($A fd00::5 $K)"
for bad in 127.0.0.1 ::1 169.254.1.1 fe80::1 8.8.8.8 0.0.0.0 224.0.0.1 192.168.1.10 fd00::10 10.10.95.5 nonsense; do
  rc=0; $A $bad $K >/dev/null 2>&1 || rc=$?; check_eq "address refused: $bad" 1 "$rc"
done
check_eq "port 443 ok" "443" "$($R port 443)"
for bad in 0 70000 abc; do rc=0; $R port $bad >/dev/null 2>&1 || rc=$?; check_eq "port refused: $bad" 1 "$rc"; done

echo "-- injection through the address or the domain"
bad_addrs=("fd00::5%a'}]" "fd00::5%eth0" $'fd00::5\nkey: x' $'192.168.1.20\n' 'fd00::5`' '192.168.1.20{x}' "192.168.1.20'")
for bad in "${bad_addrs[@]}"; do
  rc=0; $A "$bad" $K >/dev/null 2>&1 || rc=$?; check_eq "address refused: ${bad//$'\n'/\\n}" 1 "$rc"
  rc=0; $R render x.example.com "$bad" 443 80 off 80 >/dev/null 2>&1 || rc=$?; check_eq "render refuses: ${bad//$'\n'/\\n}" 2 "$rc"
done
bad_doms=($'a.example.com\n' $'a.example.com\nx: y' "a'.example.com" 'a.example.com`' 'a.example.com}' 'a{b}.example.com')
for bad in "${bad_doms[@]}"; do
  rc=0; $R domain "$bad" >/dev/null 2>&1 || rc=$?; check_eq "domain refused: ${bad//$'\n'/\\n}" 1 "$rc"
  rc=0; $R render "$bad" 192.168.1.20 443 80 off 80 >/dev/null 2>&1 || rc=$?; check_eq "render refuses domain: ${bad//$'\n'/\\n}" 2 "$rc"
done
rc=0; $R render x.example.com 192.168.1.20 $'443\nx' 80 off 80 >/dev/null 2>&1 || rc=$?; check_eq "render refuses a port with a newline" 1 "$rc"
printf '10.10.95.5 (eth0)\nfd42:1:2::5 (eth0)\n' > "$HS_PT_INSTANCE_ADDRS"
refused "a container IPv6 address" 'this server' example.com add --address fd42:1:2::5
refused "the server's own ULA" 'this server' example.com add --address fd00::10
printf '10.10.95.5 (eth0)
' > "$HS_PT_INSTANCE_ADDRS"

echo "-- plan: add"
run $C plan example.com add --address 192.168.1.20
check_eq "plan exit 0" 0 "$rc"
has "^status${T}ok$" && has "^heading${T}forward example.com and \*.example.com to 192.168.1.20$" && has "^step${T}public port 443 (TLS passthrough by SNI) -> 192.168.1.20:443$" &&
  has "^step${T}public port 80 (HTTP, Host header kept) -> 192.168.1.20:80$" && has "^command${T}" && has "^long${T}no$" && pass "plan lines" || fail "plan: $out"
has "^note${T}This server holds no certificate" && has "^note${T}DNS of example.com" && pass "plan notes" || fail "notes: $out"
check_eq "plan writes nothing" "0" "$(find "$RT" "$HS_GATEWAY_DIR/tmp" -type f | wc -l | tr -d ' ')"
run $C plan example.com add
check_eq "no address: exit 2" 2 "$rc"; has "^needs${T}address$" && pass "needs address" || fail "needs: $out"
run $C plan example.com add --address 192.168.1.20 --no-http --proxy-protocol
has "HTTP is not forwarded" && has "with PROXY protocol v2" && pass "no-http and proxy in the plan" || fail "$out"

echo "-- refusals of the common checks"
: > "$HS_CAPABILITIES_FILE"
refused "gateway not on" 'gateway proxy is off' example.com add --address 192.168.1.20
echo gateway > "$HS_CAPABILITIES_FILE"
printf 'https=0\nhttp=0\n' > "$HS_GATEWAY_PUBLIC_FILE"
refused "public https port 0" 'no public port' example.com add --address 192.168.1.20
printf 'gatewayPublicHttps = 443\n' >> "$HS_MACHINE_FILE"
refused "public https port 0 but set in machine.toml" 'set in machine.toml but not applied yet: run hs rebuild' example.com add --address 192.168.1.20
sed -i '/^gatewayPublicHttps/d' "$HS_MACHINE_FILE"
printf 'https=443\nhttp=80\n' > "$HS_GATEWAY_PUBLIC_FILE"
refused "bad domain" 'single name' single add --address 192.168.1.20
refused "wildcard" 'wildcard' '*.x.com' add --address 192.168.1.20
refused ".local" 'home network' a.local add --address 192.168.1.20
refused "65 characters" 'longer than 64' "$(printf 'a%.0s' $(seq 1 61)).com" add --address 192.168.1.20
refused "loopback" 'private LAN' example.com add --address 127.0.0.1
refused "public address" 'private LAN' example.com add --address 8.8.8.8
refused "link-local v6" 'private LAN' example.com add --address fe80::1
refused "this server" 'this server' example.com add --address 192.168.1.10
refused "a container" 'this server' example.com add --address 10.10.95.5

echo "-- a container of this server as the target"
printf 'zoraxy,"10.10.95.5 (eth0)\nfd42:1:2::5 (eth0)",\nmonitoring,10.10.95.6 (eth0),\nplain,,\n' > "$HS_PT_INSTANCE_ADDRS"
refused "container: named, no flag" "that is the container 'zoraxy' of this server.*--container-ok --confirm example.com" example.com add --address 10.10.95.5
refused "container v6 (second line of the cell): named" "container 'zoraxy'" example.com add --address fd42:1:2::5
run $C plan example.com add --address 10.10.95.5 --container-ok
check_eq "container with the flag: plan exit 0" 0 "$rc"
has "^warn${T}.*WHOLE domain example.com.*container zoraxy.*internet" && has "^confirm_name${T}example.com$" && pass "container plan: warning and confirm_name" || fail "container plan: $out"
run $C start example.com add --address 10.10.95.5 --container-ok
check_eq "container start without --confirm: refused" 1 "$rc"
run $C start example.com add --address 10.10.95.5 --container-ok --confirm other.com
check_eq "container start with the wrong --confirm: refused" 1 "$rc"
check_eq "nothing written yet" "0" "$(find "$RT" -type f | wc -l | tr -d ' ')"
run $C start example.com add --address 10.10.95.5 --confirm example.com
check_eq "--confirm without --container-ok: refused" 1 "$rc"
run $C start example.com add --address 10.10.95.5 --container-ok --confirm example.com
check_eq "container start with both: done" 0 "$rc"
check_eq "route written" "1" "$(grep -c "address: '10.10.95.5:443'" "$RT/pt-example.com.yml")"
rm -f "$RT"/pt-example.com.yml
refused "host address with the flag" 'that is this server' example.com add --address 192.168.1.10 --container-ok --confirm example.com
refused "host v6 with the flag" 'that is this server' example.com add --address fd00::10 --container-ok --confirm example.com
refused "loopback with the flag" 'private LAN' example.com add --address 127.0.0.1 --container-ok --confirm example.com
refused "public address with the flag" 'private LAN' example.com add --address 8.8.8.8 --container-ok --confirm example.com
refused "scope id with the flag" 'not an IP address' example.com add --address 'fd42:1:2::5%eth0' --container-ok --confirm example.com
refused "--container-ok on remove" 'unknown option' example.com remove --container-ok
run $C plan example.com add --address 10.10.95.5 --container-ok --https-port 443 --http-port 80
check_eq "zoraxy on 443 and 80 stays allowed" 0 "$rc"
run $C plan example.com add --address 10.10.95.5 --container-ok --no-http
check_eq "zoraxy on 443 without http stays allowed" 0 "$rc"
refused "zoraxy admin port 8000 as https" "container 'zoraxy' on port 8000 is an admin page" example.com add --address 10.10.95.5 --container-ok --https-port 8000
refused "zoraxy admin port 8000 as http" "container 'zoraxy' on port 8000 is an admin page" example.com add --address 10.10.95.5 --container-ok --http-port 8000
refused "grafana (monitoring:3000) as http" "container 'monitoring' on port" example.com add --address 10.10.95.6 --container-ok --confirm example.com --http-port 3000
run $C start example.com add --address 10.10.95.6 --container-ok --confirm example.com --http-port 3000
check_eq "grafana start refused too" 1 "$rc"
echo "-- the list of containers is garbage: fail closed"
for junk in 'this is not csv at all' 'foo,bar' '"unterminated,10.10.95.5'; do
  printf '%s\n' "$junk" > "$HS_PT_INSTANCE_ADDRS"
  refused "garbage list ($junk): any target" 'cannot be read' example.com add --address 192.168.1.20
  refused "garbage list ($junk): with the flag" 'cannot be read' example.com add --address 192.168.1.20 --container-ok --confirm example.com
done
printf 'garbage line\n10.10.95.5 (eth0)\n' > "$HS_PT_INSTANCE_ADDRS"
refused "garbage next to an address: still refused" 'cannot be read' example.com add --address 10.10.95.5 --container-ok --confirm example.com
printf 'web,10.10.95.5 (eth0)\n' > "$HS_PT_INSTANCE_ADDRS"
check_eq "a plain name,address list parses" "web" "$($R container 10.10.95.5 --instance-addrs $HS_PT_INSTANCE_ADDRS)"
printf '10.10.95.5 (eth0)\n' > "$HS_PT_INSTANCE_ADDRS"
refused "an unnamed container cannot be checked" "name of the container with this address is unknown" example.com add --address 10.10.95.5 --container-ok
refused "an unnamed container: no flag" "container '?'" example.com add --address 10.10.95.5
echo "-- incus failed, shared addresses, static addresses, no services.py"
printf 'zoraxy,"10.10.95.5 (eth0)",\n' > "$HS_PT_INSTANCE_ADDRS"
export HS_PT_INSTANCE_FAIL=1
refused "incus failed: a plain LAN target is refused" 'cannot read the container list' example.com add --address 192.168.1.20
refused "incus failed: a container address is refused (no way around it)" 'cannot read the container list' example.com add --address 10.10.95.5 --https-port 8000
refused "incus failed: with the flag too" 'cannot read the container list' example.com add --address 10.10.95.5 --container-ok --confirm example.com
unset HS_PT_INSTANCE_FAIL
: > "$HS_PT_INSTANCE_ADDRS"
run $C plan example.com add --address 192.168.1.20
check_eq "an empty list from a working incus (or none installed) means no containers" 0 "$rc"
printf 'docker,172.17.0.1 (docker0),\nzoraxy,172.17.0.1 (docker0),\n' > "$HS_PT_INSTANCE_ADDRS"
refused "shared address: every name is shown" "container 'docker, zoraxy'" example.com add --address 172.17.0.1
refused "shared address: zoraxy:8000 is checked although docker is listed first" "container 'zoraxy' on port 8000" example.com add --address 172.17.0.1 --container-ok --http-port 8000
refused "shared address: docker:80 is an admin page too" "container 'docker' on port 80" example.com add --address 172.17.0.1 --container-ok
run $C plan example.com add --address 172.17.0.1 --container-ok --no-http
check_eq "shared address on 443 without http is allowed with the flag" 0 "$rc"
rc=0; $R address 172.17.0.1 --host-addrs $HS_PT_HOST_ADDRS --instance-addrs $HS_PT_INSTANCE_ADDRS --container-ok yes --admin-from "$WORK/no-such-services.py" >/dev/null 2>&1 || rc=$?
check_eq "services.py unreadable: a container target is refused (fail closed)" 0 "$((rc == 1 ? 0 : 1))"
printf 'def x(:\n' > "$WORK/bad-services.py"
printf 'zoraxy,10.10.95.5 (eth0),\n' > "$HS_PT_INSTANCE_ADDRS"
out=$($R address 10.10.95.5 --host-addrs $HS_PT_HOST_ADDRS --instance-addrs $HS_PT_INSTANCE_ADDRS --container-ok yes --admin-from "$WORK/bad-services.py" 2>&1) || true
check_out "services.py unparsable: says so" "list of admin pages" echo "$out"
printf '[{"name":"stopped-proxy","expanded_devices":{"eth0":{"type":"nic","ipv4.address":"10.10.95.9","ipv6.address":"fd42:1:2::9"},"root":{"type":"disk"}}},{"name":"dyn","expanded_devices":{"eth0":{"type":"nic"}}}]' > "$WORK/inst.json"
check_eq "static addresses of the devices" "stopped-proxy,10.10.95.9,
stopped-proxy,fd42:1:2::9," "$($R static-addrs "$WORK/inst.json")"
printf 'stopped-proxy,\n' > "$HS_PT_INSTANCE_ADDRS"
$R static-addrs "$WORK/inst.json" >> "$HS_PT_INSTANCE_ADDRS"
refused "a stopped container with a static address is a container" "container 'stopped-proxy'" example.com add --address 10.10.95.9
refused "its v6 address too" "container 'stopped-proxy'" example.com add --address fd42:1:2::9
rc=0; echo 'not json' > "$WORK/bad.json"; $R static-addrs "$WORK/bad.json" >/dev/null 2>&1 || rc=$?
check_eq "static-addrs: no JSON is an error" 1 "$rc"
echo "-- ipv4.address=none, the admin ports of ports.sh"
printf '[{"name":"web","expanded_devices":{"eth0":{"type":"nic","ipv4.address":"none","ipv6.address":""}}}]' > "$WORK/none.json"
check_eq "static-addrs: none and empty are no address" "" "$($R static-addrs "$WORK/none.json")"
printf 'web,\n' > "$HS_PT_INSTANCE_ADDRS"
$R static-addrs "$WORK/none.json" >> "$HS_PT_INSTANCE_ADDRS"
run $C plan example.com add --address 192.168.1.20
check_eq "a list with a 'none' device does not refuse a plain LAN host" 0 "$rc"
printf 'zoraxy,"10.10.95.5 (eth0)\nfd42:1:2::5 (eth0)",\nmonitoring,10.10.95.6 (eth0),\nplain,,\n' > "$HS_PT_INSTANCE_ADDRS"
refused "monitoring:9090 (Prometheus) is refused: every port of monitoring" "container 'monitoring' on port 9090" example.com add --address 10.10.95.6 --container-ok --https-port 9090
refused "zoraxy:8000 is refused (ports.sh)" "container 'zoraxy' on port 8000" example.com add --address 10.10.95.5 --container-ok --http-port 8000
run $C plan example.com add --address 10.10.95.5 --container-ok
check_eq "zoraxy on 443 and 80 is allowed" 0 "$rc"
echo "-- dc1 renamed, user rows, damaged ports.sh, comma lists"
printf 'dcName = "ad"\n' >> "$HS_MACHINE_FILE"
printf 'ad,10.10.95.8 (eth0),\n' >> "$HS_PT_INSTANCE_ADDRS"
refused "the domain controller named by dcName is an admin container" "container 'ad' on port" example.com add --address 10.10.95.8 --container-ok
sed -i '/^dcName/d' "$HS_MACHINE_FILE"
printf 'custom 8123 My own admin page\n' > "$HS_STATE_DIR/ports-admin"
printf 'custom,10.10.95.9 (eth0),\n' >> "$HS_PT_INSTANCE_ADDRS"
refused "a user row of ports-admin" "container 'custom' on port 8123" example.com add --address 10.10.95.9 --container-ok --https-port 8123
rm -f "$HS_STATE_DIR/ports-admin"
A2="$R address 10.10.95.5 --host-addrs $HS_PT_HOST_ADDRS --instance-addrs $HS_PT_INSTANCE_ADDRS --container-ok yes --admin-from $SCRIPTS/services.py"
check_eq "the real ports.sh parses (zoraxy 443 is fine)" "10.10.95.5" "$($A2 --ports-from $SCRIPTS/ports.sh)"
sed '/^  printf .uptime-kuma/s/.*/  echo broken/' "$SCRIPTS/ports.sh" > "$WORK/ports-bad1.sh"
sed '/zoraxy.t8000/d' "$SCRIPTS/ports.sh" > "$WORK/ports-bad2.sh"
for bad in 1 2; do
  rc=0; out=$($A2 --ports-from "$WORK/ports-bad$bad.sh" 2>&1) || rc=$?
  check_eq "damaged ports.sh ($bad): refused, fail closed: $out" 1 "$rc"
done
printf '[{"name":"routed","expanded_devices":{"eth0":{"type":"nic","ipv4.address":"10.30.0.1, 10.30.0.2/24"}}}]' > "$WORK/comma.json"
check_eq "static-addrs: a comma list gives every address" "routed,10.30.0.1,
routed,10.30.0.2," "$($R static-addrs "$WORK/comma.json")"
printf 'zoraxy,"10.10.95.5 (eth0)\nfd42:1:2::5 (eth0)",\nmonitoring,10.10.95.6 (eth0),\nplain,,\n' > "$HS_PT_INSTANCE_ADDRS"
printf 'docker,172.17.0.1 (docker0),\nzoraxy,172.17.0.1 (docker0),\n' > "$HS_PT_INSTANCE_ADDRS"
run $C plan example.com add --address 172.17.0.1 --container-ok --no-http
has "container docker, zoraxy of this server" && pass "the warning shows every name" || fail "names: $out"
printf 'zoraxy,"10.10.95.5 (eth0)\nfd42:1:2::5 (eth0)",\nmonitoring,10.10.95.6 (eth0),\nplain,,\n' > "$HS_PT_INSTANCE_ADDRS"
echo "-- the header remembers the confirmed container; status/refresh warn about the others"
run $C start example.com add --address 10.10.95.5 --container-ok --confirm example.com
check_eq "container route written" 0 "$rc"
check_eq "header carries container=yes" "1" "$(head -n 1 "$RT/pt-example.com.yml" | grep -c ' proxy=off container=yes$')"
check_eq "list keeps its 5 columns" "example.com${T}10.10.95.5${T}443${T}80${T}off" "$($R list "$RT")"
run $C start --refresh refresh
check_eq "refresh keeps the flag" "1" "$(head -n 1 "$RT/pt-example.com.yml" | grep -c 'container=yes$')"
run $C start plain.example.dev add --address 192.168.1.20
check_eq "a plain route written" 0 "$rc"
check_eq "no container flag on a plain route" "0" "$(head -n 1 "$RT/pt-plain.example.dev.yml" | grep -c container=)"
run $C plan --audit audit
check_eq "audit: nothing to warn about" "0" "$(grep -c '^warn' <<<"$out")"
printf 'zoraxy,10.10.95.5 (eth0),\nnewproxy,192.168.1.20 (eth0),\n' > "$HS_PT_INSTANCE_ADDRS"
run $C plan --audit audit
has "^warn${T}the route of plain.example.dev goes to 192.168.1.20, which is the container newproxy of this server now" && pass "audit: a plain route whose target became a container" || fail "audit: $out"
check_eq "audit: the confirmed route is not warned about" "0" "$(grep -c 'route of example.com' <<<"$out")"
HS_PT_INSTANCE_FAIL=1 run $C plan --audit audit
has "^note${T}cannot read the container list" && pass "audit: unreadable list is said" || fail "audit failed list: $out"
printf 'monitoring,10.10.95.5 (eth0),\n' > "$HS_PT_INSTANCE_ADDRS"
run $C plan --audit audit
has "^warn${T}the route of example.com: the container 'monitoring' on port" && pass "audit: a confirmed route whose target is an admin container now" || fail "audit admin: $out"
run $C start --refresh refresh
has "^warn${T}the route of example.com was not written again: the container 'monitoring'" && pass "refresh leaves a route that hits an admin container, and says so" || fail "refresh admin: $out"
HS_PT_INSTANCE_FAIL=1 run $C start --refresh refresh
has "^warn${T}the route of example.com was not written again: the container list cannot be read" && pass "refresh with an unreadable list leaves the routes" || fail "refresh failed list: $out"
rm -f "$RT"/pt-example.com.yml "$RT"/pt-plain.example.dev.yml
printf 'zoraxy,"10.10.95.5 (eth0)\nfd42:1:2::5 (eth0)",\nmonitoring,10.10.95.6 (eth0),\nplain,,\n' > "$HS_PT_INSTANCE_ADDRS"
run $C plan example.com add --address 192.168.1.20 --container-ok
if has "^confirm_name"; then fail "a normal target must not ask for confirm_name"; else pass "a normal target with the flag: no confirm_name"; fi
echo "-- the CLI: a container target needs the typed domain"
rc=0; out=$($S add example.com 10.10.95.5 --container-ok --yes </dev/null 2>&1) || rc=$?
check_eq "cli: --yes does not replace the typed domain: $out" 1 "$rc"
rc=0; out=$($S add example.com 10.10.95.5 --container-ok --confirm example.com </dev/null 2>&1) || rc=$?
check_eq "cli: container with --container-ok --confirm: $out" 0 "$rc"
rm -f "$RT"/pt-example.com.yml

refused "port 0" 'not a port' example.com add --address 192.168.1.20 --https-port 0
refused "port 70000" 'not a port' example.com add --address 192.168.1.20 --http-port 70000
refused "unknown option" 'unknown option' example.com add --address 192.168.1.20 --bogus
run $C plan Example.COM add --address 192.168.1.20
has "^heading${T}forward example.com " && pass "upper case is normalised" || fail "upper: $out"

echo "-- the guard"
refused "proxyDomains equal" 'overlaps example.org' example.org add --address 192.168.1.20
refused "under a proxyDomain" 'overlaps example.org' a.example.org add --address 192.168.1.20
printf 'sub.example.net\n' > "$HS_SETTINGS_DIR/proxyDomains"
refused "parent of a proxyDomain entry" 'overlaps sub.example.net' example.net add --address 192.168.1.20
printf 'example.org,example.net\n' > "$HS_SETTINGS_DIR/proxyDomains"
refused "the local domain" 'overlaps homeserver.ad.home.test' homeserver.ad.home.test add --address 192.168.1.20
refused "under the local domain" 'overlaps' x.homeserver.ad.home.test add --address 192.168.1.20
refused "the AD realm (with the local domain)" 'overlaps' ad.home.test add --address 192.168.1.20
check_out "the AD realm alone" "AD realm" $R guard corp.home.test --realm corp.home.test --routes $RT
refused "a host of the public proxy" 'overlaps public.example.io' public.example.io add --address 192.168.1.20
refused "under a host of the public proxy" 'overlaps public.example.io' x.public.example.io add --address 192.168.1.20
refused "the refusal names the exception" 'unless the target is the public reverse proxy itself' example.org add --address 192.168.1.20
echo "-- the public reverse proxy itself as the target may carry its own domains"
printf 'zoraxy,10.10.95.5 (eth0),\nmonitoring,10.10.95.6 (eth0),\n' > "$HS_PT_INSTANCE_ADDRS"
printf 'other,10.10.95.7 (eth0),
' >> "$HS_PT_INSTANCE_ADDRS"
export HS_PT_PROXY_CT=zoraxy
run $C plan example.org add --address 10.10.95.5 --container-ok
[ "$rc" = 0 ] && pass "overlap + target = the proxy container: allowed" || fail "proxy container: rc=$rc $out"
run $C plan public.example.io add --address 10.10.95.5 --container-ok
[ "$rc" = 0 ] && pass "a host of the proxy, target = the proxy container: allowed" || fail "proxy host: rc=$rc $out"
refused "overlap + the proxy container without --container-ok" "container 'zoraxy'" example.org add --address 10.10.95.5
refused "overlap + another container" 'overlaps example.org' example.org add --address 10.10.95.7 --container-ok
refused "overlap + an admin container is refused as an admin page" 'admin page' example.org add --address 10.10.95.6 --container-ok
refused "overlap + a plain LAN address" 'overlaps example.org' example.org add --address 192.168.1.20
refused "overlap + the proxy container on the admin port" 'admin page' example.org add --address 10.10.95.5 --container-ok --https-port 8000
export HS_PT_PROXY_CT=nobody
refused "overlap + a proxy container that is another one" 'overlaps example.org' example.org add --address 10.10.95.5 --container-ok
export HS_PT_PROXY_CT=zoraxy HS_PT_DEFAULT_ADDRS=$WORK/default-addrs
printf 'monitoring,10.10.95.6 (eth0),
' > "$HS_PT_DEFAULT_ADDRS"
refused "overlap + a container of that name in another project" 'overlaps example.org' example.org add --address 10.10.95.5 --container-ok
: > "$HS_PT_DEFAULT_ADDRS"
refused "overlap + the default project list unreadable or empty" 'overlaps example.org' example.org add --address 10.10.95.5 --container-ok
unset HS_PT_DEFAULT_ADDRS
unset HS_PT_PROXY_CT
refused "overlap + the proxy container unknown" 'overlaps example.org' example.org add --address 10.10.95.5 --container-ok
printf '10.10.95.5 (eth0)\n' > "$HS_PT_INSTANCE_ADDRS"
printf '# hs-gateway local v1 host=app.home.example.com\n' > "$RT/local-app.home.example.com.yml"
refused "a local- host" 'local name' home.example.com add --address 192.168.1.20
rm -f "$RT/local-app.home.example.com.yml"

echo "-- start: add, replace, remove"
run $C start example.com add --address 192.168.1.20 --proxy-protocol
check_eq "start exit 0" 0 "$rc"
has "^status${T}done$" && pass "status done" || fail "start: $out"
f=$RT/pt-example.com.yml
check_eq "the route file exists" "yes" "$([ -f "$f" ] && echo yes)"
check_eq "its header" "# hs-gateway passthrough v1 domain=example.com address=192.168.1.20 https=443 http=80 proxy=on" "$(head -n 1 "$f")"
check_eq "mode 0640" "640" "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")"
check_eq "tmp/ is empty" "0" "$(ls -A "$HS_GATEWAY_DIR/tmp" | wc -l | tr -d ' ')"
run $C plan example.com add --address 192.168.1.21
has "^warn${T}example.com is forwarded already (to 192.168.1.20): the target is replaced$" && pass "replace warns" || fail "replace: $out"
run $C start other.org add --address fd00::5 --no-http --https-port 8443
check_eq "list shape" "$(printf 'example.com\t192.168.1.20\t443\t80\ton\nother.org\tfd00::5\t8443\t-\toff')" "$($R list "$RT")"
refused "overlap with another pt- domain" 'forwarded already' sub.example.com add --address 192.168.1.20

echo "-- refresh picks up a changed public port"
printf 'https=443\nhttp=0\n' > "$HS_GATEWAY_PUBLIC_FILE"
run $C start --refresh refresh
check_eq "refresh: done" "status${T}done" "$out"
check_eq "public http 0: no http router left" "0" "$(grep -c '^http:' "$f")"
check_eq "the header keeps the http port" "yes" "$(head -n 1 "$f" | grep -q 'http=80' && echo yes)"
printf 'https=443\nhttp=80\n' > "$HS_GATEWAY_PUBLIC_FILE"
run $C start --refresh refresh
check_eq "back to 80: the http router is back" "1" "$(grep -c '^http:' "$f")"

echo "-- remove"
refused "unknown domain" 'is not forwarded' nobody.org remove
run $C plan example.com remove
has "^danger${T}Visitors of example.com and \*.example.com get no answer" && has "^confirm_name${T}example.com$" && has "^step${T}delete pt-example.com.yml" && pass "remove plan" || fail "remove plan: $out"
run $C start example.com remove
check_eq "start without --confirm: refused" 1 "$rc"
has 'type the domain to confirm: example.com' && pass "says so" || fail "$out"
run $C start example.com remove --confirm other.org
check_eq "wrong --confirm: refused" 1 "$rc"
check_eq "the file is still there" "yes" "$([ -f "$f" ] && echo yes)"
run $C start example.com remove --confirm example.com
check_eq "right --confirm: done" "status${T}done" "$out"
check_eq "the file is gone" "no" "$([ -f "$f" ] && echo yes || echo no)"
check_eq "the other domain stays" "other.org" "$($R list "$RT" | cut -f1)"

echo "-- sys shapes"
run $S --list
check_eq "--list" "$(printf 'other.org\tfd00::5\t8443\t-\toff')" "$out"
run $S --state
check_eq "--state: down by the probe, - for http off" "$(printf 'other.org\tfd00::5\tdown\t-')" "$out"
run $C start example.com add --address 192.168.1.20
run $S --state
check_eq "--state: up for the target that answers" "$(printf 'example.com\t192.168.1.20\tup\tup')" "$(grep '^example.com' <<<"$out")"
printf 'LISTEN 0 4096 *:443 *:* users:(("traefik",pid=1,fd=8))\nLISTEN 0 4096 *:80 *:* users:(("nginx",pid=2,fd=8))\n' > "$HS_GATEWAY_LISTENERS"
run $S --status
check_eq "--status" "$(printf 'gateway\ton\npublic_https\t443\npublic_http\t80\nport_public_https\ttraefik\nport_public_http\tnginx\ndomains\t2')" "$out"
run $C plan third.org add --address 192.168.1.30
has "^warn${T}the public http port is held by nginx, not by Traefik$" && pass "a foreign port holder warns" || fail "port warn: $out"
: > "$HS_GATEWAY_LISTENERS"
: > "$HS_CAPABILITIES_FILE"
run $S --status
check_out "--status with the gateway off" "^gateway${T}off$" echo "$out"
rm -f "$RT"/pt-*.yml
run $S --list
check_eq "--list is empty without a domain" "" "$out"

echo "-- hs ext passthrough through hs, with the package on"
printf 'gateway\npassthrough\n' > "$HS_CAPABILITIES_FILE"
HSB="bash $SCRIPTS/lib/hs.sh"
check_out "list is empty and says so" "No domain is forwarded yet" $HSB ext passthrough list
$HSB ext passthrough add example.com 192.168.1.20 --yes >/dev/null 2>&1
check_out "list shows the domain" "example.com" $HSB ext passthrough list
check_out "remove without a terminal and without --confirm fails" "Nobody to ask" bash -c "$HSB ext passthrough remove example.com 2>&1 </dev/null"
$HSB ext passthrough remove example.com --confirm example.com >/dev/null 2>&1
check_eq "remove --confirm deletes it" "" "$($R list "$RT")"
finish
