#!/usr/bin/env bash
# help: the password form for domain users (they change their own AD password over HTTPS): status, log, start, stop, expose
# help.de: das Passwortformular für Domänenbenutzer (sie ändern ihr AD-Passwort selbst über HTTPS): Status, Protokoll, starten, stoppen, freigeben
# args: status | log [--lines N] | start | stop | expose private [--yes] | expose public <full name> [--confirm <full name>] | --status | --log | --suggest
# The service is a transient systemd unit (selfservice.py serve); the work of start, stop, expose and boot is selfservice-change.sh's
# (plan, start); this script shows it to people (extensions/ad-selfservice/NOTES.md).
#   --status   key TAB value (- when empty): running, wanted, port, dc, dc_address, exposure, fqdn, public_proxy, tls_route,
#              ad_lockout_threshold, limit_account, limit_ip, limit_global, package
#   --log      time TAB ip TAB user TAB result, newest first, at most 200 (hs sys ext ad-selfservice log)
#   --suggest  one line: the public name the page offers (pw.<first proxy domain>), - when there is none (hs sys ext ad-selfservice suggest)
# Test knobs: HS_STATE_DIR, HS_SERVICES_DIR, HS_SYSTEMCTL, HS_INCUS, HS_DC, HS_ADSS_JOURNAL (a file read instead of the journal), HS_ADSS_ROUTES,
# HS_PYTHON; the rest are selfservice-change.sh's.
# i18n: The form has expired. Reload the page and try again. | The request was not understood. | The service is busy. Try again in a moment. | Not found.
# i18n: Your password was changed. | The user name or the current password is wrong. | The new password does not meet the password rules of the domain.
# i18n: Too many tries. Wait a few minutes and try again. | The password could not be changed right now. Try again later. | Use the https address.
# i18n: Enter your user name. | The user name is not valid. | Enter the current and the new password. | A password has 1 to 256 characters and no line breaks.
# i18n: The new password and the repeat are not the same. | The new password must differ from the current one.
# i18n: The new password is too short. | The new password must be more complex: upper and lower case letters, digits or symbols.
# i18n: The new password was used before. | The password was changed too recently.
# i18n: Change your password | User name | Current password | New password | Repeat the new password | Change password
# i18n: stop the password form | it stays stopped after a reboot | start the password form | it starts again after a reboot until you run stop
# i18n: make the password form private | the service ad-selfservice is not public any more | hs services apply removes the public route
# i18n: The form is stopped: no TLS route is left, and the form only runs with one.
# i18n: Anyone on the internet can reach the form. A stranger can try passwords and block the form for an account for 15 minutes.
# i18n: Keep the AD lockout threshold at 0 or above 3, or a stranger could lock a real account.
# i18n: hs services apply makes the route; the form starts only when that route is there (start)
# i18n: the package ad-selfservice is off (hs ext enable ad-selfservice) | the capability ad is off: there is no domain to change passwords in
# i18n: the capability gateway is off: there is no proxy that gives the form its HTTPS address
# i18n: smbpasswd or python3 was not found (the Samba client tools) | could not declare the service ad-selfservice
# i18n: no TLS route to /password: the form is only served over HTTPS (reverseProxy = traefik-public and a public name; the local proxy has no HTTPS yet)
# i18n: the form can only be public with reverseProxy = traefik-public (the proxy in a container cannot reach 127.0.0.1)
# i18n: expose public needs the full name, for example pw.example.org | expose private or expose public <full name> | could not make the service public
# i18n: could not make the service private
# i18n: systemd-run could not start the unit hs-ad-selfservice (are you root?)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scripts=${HS_SCRIPTS:-$here/../../scripts}   # the core helpers; hs and hs-web set HS_SCRIPTS
. "$scripts/lib/ui.sh"
. "$scripts/lib/capability.sh"
. "$scripts/lib/setting.sh"
. "$scripts/lib/dc.sh"
. "$scripts/lib/machine.sh"
state_root=${HS_STATE_DIR:-/var/lib/hs}
state=$state_root/ad-selfservice
conf=$state/config.json
svc_file=${HS_SERVICES_DIR:-$state_root/services.d}/ad-selfservice.toml
unit=hs-ad-selfservice
sctl=${HS_SYSTEMCTL:-systemctl}
py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python
tab=$'\t'
ss() { PYTHONUTF8=1 "$py" -I "$here/selfservice.py" "$@"; }
change() { bash "$here/selfservice-change.sh" "$@"; }

usage() {
  say "usage: hs ext ad-selfservice status | log [--lines N] | start | stop"
  say "       hs ext ad-selfservice expose private [--yes]"
  say "       hs ext ad-selfservice expose public <full name> [--confirm <full name>]"
  exit 1
}
dash() { local v; v=$(cat); echo "${v:--}"; }
conf_get() { { ss conf "$conf" "$1" 2>/dev/null || true; } | dash; }
status_rows() {
  local running=no wanted=no port dc addr exposure=private fq proxy route thr pkg=off
  if [ "$("$sctl" is-active "$unit" 2>/dev/null || true)" = active ]; then running=yes; fi
  if [ -f "$state/wanted" ]; then wanted=yes; fi
  port=$(ss conf "$conf" port 2>/dev/null || true); port=${port:-${HS_ADSS_PORT:-8486}}
  dc=$(dc_name 2>/dev/null || true)
  addr=$(conf_get dc_address)
  if grep -q '^exposure = "public-ok"' "$svc_file" 2>/dev/null; then exposure=public; fi
  fq=$({ sed -n 's/^fqdn = \["\([^"]*\)".*/\1/p' "$svc_file" 2>/dev/null || true; } | head -n 1 | dash)
  proxy=$(setting_get reverseProxy 2>/dev/null | dash || true)
  route=$(change route 2>/dev/null || echo no)
  thr=$(timeout 10 "${HS_INCUS:-incus}" exec "${dc:-dc1}" -- samba-tool domain passwordsettings show 2>/dev/null </dev/null |
    awk -F: '/lockout threshold/ { gsub(/[^0-9]/, "", $2); print $2; exit }' | dash || true)
  if capability_on ad-selfservice; then pkg=on; fi
  printf 'running\t%s\nwanted\t%s\nport\t%s\ndc\t%s\ndc_address\t%s\nexposure\t%s\nfqdn\t%s\npublic_proxy\t%s\ntls_route\t%s\nad_lockout_threshold\t%s\n' \
    "$running" "$wanted" "$port" "${dc:--}" "$addr" "$exposure" "$fq" "$proxy" "$route" "${thr:--}"
  printf 'limit_account\t3/900\nlimit_ip\t5/900\nlimit_global\t30/60\npackage\t%s\n' "$pkg"
}
suggest_name() {   # one line for the page: pw.<first reverse proxy domain>, - when there is none (it only fills the field, the person confirms the name)
  local d; d=$(setting_get proxyDomains 2>/dev/null | cut -d, -f1 || true); d=${d//[[:space:]]/}
  if [ -n "$d" ]; then echo "pw.$d"; else echo "-"; fi
}
log_rows() {   # newest first, at most 200; the user cleaned up again, the result one of the known words
  { if [ -n "${HS_ADSS_JOURNAL:-}" ]; then cat "$HS_ADSS_JOURNAL" 2>/dev/null
    else journalctl -u "$unit" -o cat --no-pager 2>/dev/null; fi; } |
    awk -F"$tab" -v OFS="$tab" '$1 == "audit" && NF == 5 && $5 ~ /^(ok|bad|policy|limited|unavailable|input|plain-http)$/ {
      u = $4; if (u !~ /^[A-Za-z0-9._-]+$/) u = "-"; print $2, $3, u, $5 }' | tac | head -n 200
}
plan_value() { awk -F"$tab" -v k="$2" '$1 == k { print $2; exit }' <<<"$1"; }
show_plan() {
  local k v
  while IFS=$'\t' read -r k v; do
    case "$k" in
      heading) step "$v" ;;
      step|note) note "$v" ;;
      warn) warn "$v" ;;
      danger) danger "$v" ;;
    esac
  done <<<"$1"
}
refused_out() {   # refused_out <output of a refused plan or start>: the reason and the fix lines for people
  local fixes
  fixes=$(awk -F"$tab" '$1 == "fix" { printf "%s%s", (n++ ? "; " : ""), $2 }' <<<"$1")
  if [ -n "$fixes" ]; then fail_fix "$(plan_value "$1" reason)" "$fixes"; fi
  fail "$(plan_value "$1" reason)"
}

[ $# -ge 1 ] || usage
cmd=$1; shift
case "$cmd" in
--status) status_rows ;;
--log) log_rows ;;
--suggest) suggest_name ;;

status)
  declare -A v=()
  while IFS=$'\t' read -r k val; do v[$k]=$val; done < <(status_rows)
  step "$(t 'Password self-service')"
  kv "Running" "${v[running]}"
  kv "Started on purpose" "${v[wanted]}"
  kv "Port" "${v[port]}"
  kv "Domain controller" "${v[dc]} (${v[dc_address]})"
  kv "Reachable" "${v[exposure]}"
  kv "Public name" "${v[fqdn]}"
  kv "TLS route" "${v[tls_route]}"
  kv "AD lockout threshold" "${v[ad_lockout_threshold]}"
  kv "Limits" "$(t '%s per account, %s per IP, %s in all (tries/seconds)' "${v[limit_account]}" "${v[limit_ip]}" "${v[limit_global]}")"
  [ "${v[package]}" = on ] || warn "$(t 'The package ad-selfservice is off.')"
  [ "${v[tls_route]}" = yes ] || warn "$(t 'There is no TLS route to the form, so it cannot start.')"
  if [ "${v[wanted]}" = yes ] && [ "${v[running]}" = no ]; then warn "$(t 'The form should be running but is not.')"; fi
  if [ "${v[tls_route]}" != yes ]; then next_step "hs ext ad-selfservice expose public <full name>"; fi ;;

log)
  n=50
  if [ "${1:-}" = --lines ]; then n=${2:-}; fi
  case "$n" in ''|*[!0-9]*) fail "$(t 'The number of lines must be a number.')" ;; esac
  rows=$(log_rows | head -n "$n")
  if [ -z "$rows" ]; then note "$(t 'No tries recorded yet.')"; exit 0; fi
  { thead 'Time' 'IP' 'User' 'Result'; echo "$rows"; } | table ;;

start)
  rc=0; out=$(change plan start) || rc=$?
  [ "$rc" -eq 0 ] || refused_out "$out"
  show_plan "$out"
  rc=0; res=$(change start start) || rc=$?
  [ "$rc" -eq 0 ] || refused_out "$res"
  ok "$(t 'The password form is running.')"
  next_step "hs ext ad-selfservice status" ;;

stop)
  rc=0; out=$(change plan stop) || rc=$?
  [ "$rc" -eq 0 ] || refused_out "$out"
  show_plan "$out"
  rc=0; res=$(change start stop) || rc=$?
  [ "$rc" -eq 0 ] || refused_out "$res"
  ok "$(t 'The password form is stopped.')" ;;

expose)
  mode=${1:-}; [ $# -ge 1 ] || usage; shift
  yes=false; typed=""; fq=""
  case "$mode" in private) ;; public) fq=${1:-}; [ $# -eq 0 ] || shift ;; *) usage ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=true ;;
      --confirm) typed=${2:-}; [ $# -lt 2 ] || shift ;;
    esac
    shift
  done
  rc=0; out=$(change plan expose "$mode" ${fq:+"$fq"}) || rc=$?
  [ "$rc" -eq 0 ] || refused_out "$out"
  show_plan "$out"
  name=$(plan_value "$out" confirm_name)
  if [ -n "$name" ]; then   # public: the typed full name, --yes does not replace it
    if [ "$typed" != "$name" ]; then
      [ -z "$typed" ] || fail "$(t 'The typed name does not match: %s' "$name")"
      [ -t 0 ] || fail "$(t 'Nobody to ask: add --confirm %s to go on.' "$name")"
      confirm_name "$name" "the host name" || fail "$(t 'Cancelled.')"
    fi
  elif [ "$("$sctl" is-active "$unit" 2>/dev/null || true)" = active ] && ! $yes; then   # private stops a running form
    [ -t 0 ] || fail "$(t 'Nobody to ask: add --yes to go on.')"
    confirm "Make the form private and stop it?" || fail "$(t 'Cancelled.')"
  fi
  rc=0; res=$(change start expose "$mode" ${fq:+"$fq"} ${name:+--confirm "$name"}) || rc=$?
  [ "$rc" -eq 0 ] || refused_out "$res"
  ok "$(t 'The service ad-selfservice is now %s.' "$mode")"
  next_step "hs services apply" ;;

*) usage ;;
esac
