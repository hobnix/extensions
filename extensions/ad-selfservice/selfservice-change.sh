#!/usr/bin/env bash
# help: start, stop or expose the password form without asking anything: what would happen (plan), then do it (start); boot brings it back
# help.de: das Passwortformular starten, stoppen oder freigeben, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start); boot holt es nach einem Neustart zurück
# args: plan|start start | plan|start stop | plan|start expose private | plan|start expose public <full name> [--confirm <full name>] | boot | route
# System command (hs sys ext ad-selfservice plan|start|boot): for the interface, tests and the core's boot unit. It never asks and prints
# key<TAB>value lines like passthrough-change.sh.
#   start   refuse unless the package, ad and gateway are on, smbpasswd and python3 are found, the DC has an address and a TLS route to
#           /password exists (tls_route below). Writes config.json (no secret), declares the service, then runs the transient unit
#           hs-ad-selfservice (systemd-run) and writes the marker `wanted`. A running unit is stopped first, so the DC address in its
#           IPAddressAllow is the new one.
#   stop    stop the unit, remove `wanted` (the service descriptor stays).
#   expose  private: the service is not public any more and, because no TLS route is left, the unit is stopped. public <full name>:
#           only with reverseProxy = traefik-public; start needs --confirm <full name> (the web interface appends it). Then: hs services apply.
#   boot    the core's hs-ext-boot: start the unit again from config.json when `wanted` exists. Never asks, exit 0 always.
#   route   internal: prints yes|no, is there a TLS route (used by selfservice.sh).
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text>, fix<TAB><command> (refused), heading|step|note|warn|danger<TAB><line>,
#   confirm_name<TAB><full name> (expose public), long<TAB>no. start: the same checks, then status<TAB>done.
#   boot: status<TAB>started|skipped|refused and reason<TAB><text>.
# Test knobs: HS_STATE_DIR, HS_SERVICES_DIR, HS_SETTINGS_DIR, HS_MACHINE_FILE, HS_CAPABILITIES_FILE, HS_SYSTEMD_RUN, HS_SYSTEMCTL, HS_INCUS, HS_DC,
# HS_ADSS_SMBPASSWD, HS_ADSS_ROUTES (a file with the routes TSV instead of services.sh), HS_ADSS_PORT, HS_ADSS_TUNNEL_FROM, HS_PYTHON.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scripts=${HS_SCRIPTS:-$here/../../scripts}   # the core helpers; hs and hs-web set HS_SCRIPTS
. "$scripts/lib/machine.sh"
. "$scripts/lib/setting.sh"
. "$scripts/lib/capability.sh"
. "$scripts/lib/dc.sh"
state_root=${HS_STATE_DIR:-/var/lib/hs}
state=$state_root/ad-selfservice
conf=$state/config.json
wanted=$state/wanted
svc_file=${HS_SERVICES_DIR:-$state_root/services.d}/ad-selfservice.toml
unit=hs-ad-selfservice
sctl=${HS_SYSTEMCTL:-systemctl}
py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python
tab=$'\t'
umask 022
ss() { PYTHONUTF8=1 "$py" -I "$here/selfservice.py" "$@"; }

refuse() {   # refuse <reason> [<fix command>...]
  local r=$1; shift
  printf 'status\trefused\nreason\t%s\n' "$r"
  for f in "$@"; do printf 'fix\t%s\n' "$f"; done
  exit 1
}
unit_active() { [ "$("$sctl" is-active "$unit" 2>/dev/null || true)" = active ]; }
fqdn_of() { sed -n 's/^fqdn = \["\([^"]*\)".*/\1/p' "$svc_file" 2>/dev/null | head -n 1; }

tls_route() {   # yes only when the public proxy is traefik-public AND its routes hold an ok row for ad-selfservice /password
  local routes
  [ "$(setting_get reverseProxy 2>/dev/null || true)" = traefik-public ] || return 1
  if [ -n "${HS_ADSS_ROUTES:-}" ]; then routes=$(cat "$HS_ADSS_ROUTES" 2>/dev/null) || return 1
  else routes=$(timeout 30 bash "$scripts/services.sh" plan --plain 2>/dev/null) || return 1; fi
  awk -F"$tab" '$1 == "ok" && $5 == "ad-selfservice" && $3 == "/password" { f = 1 } END { exit !f }' <<<"$routes"
}

prereq() {   # prints the reason and fails when something this package needs is off
  capability_on ad-selfservice || { echo 'the package ad-selfservice is off (hs ext enable ad-selfservice)'; return 1; }
  capability_on ad || { echo 'the capability ad is off: there is no domain to change passwords in'; return 1; }
  capability_on gateway || { echo 'the capability gateway is off: there is no proxy that gives the form its HTTPS address'; return 1; }
}

find_tools() {   # smbpasswd, pyabs
  smbpasswd=${HS_ADSS_SMBPASSWD:-}
  [ -n "$smbpasswd" ] || smbpasswd=$(command -v smbpasswd 2>/dev/null || true)
  [ -n "$smbpasswd" ] || [ ! -x /run/current-system/sw/bin/smbpasswd ] || smbpasswd=/run/current-system/sw/bin/smbpasswd
  [ -n "$smbpasswd" ] && [ -x "$smbpasswd" ] || return 1
  pyabs=$(command -v "$py" 2>/dev/null || true)
  [ -n "$pyabs" ]
}
dc_address() {   # the IPv4 of the DC instance
  local dc
  dc=$(dc_name 2>/dev/null || echo dc1)
  "${HS_INCUS:-incus}" list "^$dc\$" -c 4 -f csv 2>/dev/null </dev/null | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n 1
}

run_unit() {   # run_unit: the transient unit from config.json; no password or secret in argv or the environment
  local dc port
  dc=$(ss conf "$conf" dc_address); port=$(ss conf "$conf" port)
  [ -n "$dc" ] && [ -n "$port" ] || return 1
  pyabs=$(command -v "$py" 2>/dev/null || true); [ -n "$pyabs" ] || return 1
  if unit_active; then "$sctl" stop "$unit" >/dev/null 2>&1 || true; fi
  "${HS_SYSTEMD_RUN:-systemd-run}" --unit="$unit" --collect -p DynamicUser=yes -p ProtectSystem=strict -p ProtectHome=yes -p PrivateTmp=yes \
    -p PrivateDevices=yes -p NoNewPrivileges=yes -p CapabilityBoundingSet= -p "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX" -p IPAddressDeny=any \
    -p "IPAddressAllow=127.0.0.1 ::1 $dc" -p RuntimeDirectory=hs-ad-selfservice -p RuntimeDirectoryMode=0700 -p MemoryMax=128M -p TasksMax=32 \
    -p Restart=on-failure -p SystemCallFilter=@system-service "$pyabs" -I "$here/selfservice.py" serve --config "$conf" >/dev/null 2>&1
}
declare_service() {   # the descriptor: an existing exposure is kept
  bash "$scripts/services.sh" declare ad-selfservice --host 127.0.0.1 --port "${1:-8486}" --title "Change password" --icon key \
    --exposure private-ok --want local-proxy --public-path /password >/dev/null 2>&1
}
stop_unit() {
  "$sctl" stop "$unit" >/dev/null 2>&1 || true
  rm -f "$wanted"
}

verb=${1:-}; action=${2:-}
case "$verb" in plan|start|boot|route) ;; *) echo "usage: selfservice-change.sh plan|start start|stop|expose private|expose public <full name> | boot" >&2; exit 1 ;; esac
shift 2 2>/dev/null || shift $# 2>/dev/null || true

if [ "$verb" = route ]; then if tls_route; then echo yes; else echo no; fi; exit 0; fi

if [ "$verb" = boot ]; then   # never asks, exit 0 always
  skip() { printf 'status\tskipped\nreason\t%s\n' "$1"; exit 0; }
  [ -f "$wanted" ] || skip 'the form was not started'
  r=$(prereq) || skip "$r"
  [ -f "$conf" ] || { printf 'status\trefused\nreason\tconfig.json is missing: run hs ext ad-selfservice start\n'; exit 0; }
  if run_unit; then printf 'status\tstarted\n'; else printf 'status\trefused\nreason\tthe unit could not be started\n'; fi
  exit 0
fi

case "$action" in start|stop|expose) ;; *) refuse "unknown action (start, stop or expose)" ;; esac

if [ "$action" = stop ]; then
  [ "$verb" = start ] || { printf 'status\tok\nheading\tstop the password form\nstep\tstop the unit %s\nnote\tit stays stopped after a reboot\nlong\tno\n' "$unit"; exit 0; }
  stop_unit
  printf 'status\tdone\n'
  exit 0
fi

if [ "$action" = expose ]; then
  mode=${1:-}; fq=""; confirm=""
  [ $# -eq 0 ] || shift
  case "$mode" in
    private) ;;
    public)
      fq=$(tr 'A-Z' 'a-z' <<<"${1:-}"); [ $# -eq 0 ] || shift
      [ -n "$fq" ] || refuse "expose public needs the full name, for example pw.example.org"
      grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' <<<"$fq" || refuse "$fq is not a full host name"
      ;;
    *) refuse "expose private or expose public <full name>" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in --confirm) confirm=${2:-}; [ $# -lt 2 ] || shift ;; esac
    shift
  done
  if [ "$mode" = public ]; then
    [ "$(setting_get reverseProxy 2>/dev/null || true)" = traefik-public ] ||
      refuse "the form can only be public with reverseProxy = traefik-public (the proxy in a container cannot reach 127.0.0.1)" "hs config set reverseProxy traefik-public"
    if [ "$verb" = plan ]; then
      printf 'status\tok\nheading\tmake the password form public at %s\n' "$fq"
      printf 'step\tdeclare the service ad-selfservice (127.0.0.1:%s), public name %s, only the path /password\n' "${HS_ADSS_PORT:-8486}" "$fq"
      printf 'note\ths services apply makes the route; the form starts only when that route is there (start)\n'
      printf 'warn\tAnyone on the internet can reach the form. A stranger can try passwords and block the form for an account for 15 minutes.\n'
      printf 'warn\tKeep the AD lockout threshold at 0 or above 3, or a stranger could lock a real account.\n'
      printf 'confirm_name\t%s\nlong\tno\n' "$fq"
      exit 0
    fi
    [ "$confirm" = "$fq" ] || refuse "type the full name to confirm: $fq"
    [ -f "$svc_file" ] || declare_service "${HS_ADSS_PORT:-8486}" || refuse "could not declare the service ad-selfservice"
    bash "$scripts/services.sh" set ad-selfservice --public yes --public-name "$fq" >/dev/null 2>&1 || refuse "could not make the service public"
    printf 'status\tdone\n'
    exit 0
  fi
  # private
  if [ "$verb" = plan ]; then
    printf 'status\tok\nheading\tmake the password form private\nstep\tthe service ad-selfservice is not public any more\n'
    if unit_active; then
      printf 'warn\tThe form is stopped: no TLS route is left, and the form only runs with one.\n'
    fi
    printf 'note\ths services apply removes the public route\nlong\tno\n'
    exit 0
  fi
  if [ -f "$svc_file" ]; then
    bash "$scripts/services.sh" set ad-selfservice --public no >/dev/null 2>&1 || refuse "could not make the service private"
  fi
  if unit_active; then stop_unit; fi
  printf 'status\tdone\n'
  exit 0
fi

# start
r=$(prereq) || refuse "$r"
find_tools || refuse "smbpasswd or python3 was not found (the Samba client tools)"
addr=$(dc_address)
[ -n "$addr" ] || refuse "the domain controller $(dc_name 2>/dev/null || echo dc1) has no IPv4 address (is it running?)" "hs ext ad-selfservice start"
port=${HS_ADSS_PORT:-8486}
fix_route=("hs ext ad-selfservice expose public <full name>" "hs services apply")
if [ "$verb" = plan ]; then
  tls_route || refuse "no TLS route to /password: the form is only served over HTTPS (reverseProxy = traefik-public and a public name; the local proxy has no HTTPS yet)" "${fix_route[@]}"
  printf 'status\tok\nheading\tstart the password form\n'
  printf 'step\twrite %s (the domain controller at %s, no secret)\n' "$conf" "$addr"
  printf 'step\trun the unit %s on 127.0.0.1:%s (systemd-run; only the loopback and the domain controller are reachable from it)\n' "$unit" "$port"
  printf 'note\tit starts again after a reboot until you run stop\n'
  printf 'note\tthe form is shown only over HTTPS, at https://%s/password\n' "$(fqdn_of | grep . || echo '<name>')"
  printf 'long\tno\n'
  exit 0
fi
mkdir -p "$state" || refuse "could not create $state"
trusted=""
for n in $(cat "${HS_ADSS_TUNNEL_FROM:-/etc/hs/gateway-tunnel-from}" 2>/dev/null); do trusted="${trusted:+$trusted,}$n"; done
realm=$(machine_get adDomain.realm 2>/dev/null | tr -d ' \r\n' || true)
wg=$(machine_get adDomain.workgroup 2>/dev/null | tr -d ' \r\n' || true)
lang=$(setting_get language 2>/dev/null || true)
ss make-config "$conf" "port=$port" "dc_address=$addr" "realm=$realm" "workgroup=$wg" "language=${lang:-en}" "smbpasswd=$smbpasswd" "trusted=$trusted" \
  "caps=$(capability_file)" "caps_on=$state_root/capabilities-on" "caps_off=$state_root/capabilities-off" || refuse "could not write $conf"
declare_service "$port" || refuse "could not declare the service ad-selfservice"
tls_route || refuse "no TLS route to /password: the form is only served over HTTPS (reverseProxy = traefik-public and a public name; the local proxy has no HTTPS yet)" "${fix_route[@]}"
run_unit || refuse "systemd-run could not start the unit hs-ad-selfservice (are you root?)"
: > "$wanted"
printf 'status\tdone\n'
