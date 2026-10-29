#!/usr/bin/env bash
# help: outside domains forwarded to reverse proxies on the LAN (through the gateway proxy): list, status, add, remove, refresh
# help.de: fremde Domains, die an Reverse-Proxys im LAN durchgereicht werden (über den Gateway-Proxy): anzeigen, Status, hinzufügen, entfernen, neu schreiben
# args: list | status | add <domain> <address> [...] | remove <domain> [--confirm <domain>] | refresh | --list | --state | --status
# Forwards <domain> and *.<domain> from the internet to a reverse proxy on the LAN that is not this server: TLS passthrough by SNI on the
# public HTTPS port of the gateway proxy, plain HTTP by Host on its public HTTP port (capabilities/passthrough/NOTES.md). The work is
# passthrough-change.sh's (plan, start); this script shows it to people.
#   --list     domain TAB address TAB https TAB http TAB proxy (- for empty), no header (hs sys ext passthrough list)
#   --state    domain TAB address TAB https_state TAB http_state: up|down by a 1 s TCP try, - when http is off
#   --status   key TAB value: gateway, public_https, public_http, port_public_https, port_public_http, domains
# Test knobs: HS_GATEWAY_DIR, HS_PT_PROBE (called with address and port, exit 0 = answers), HS_GATEWAY_LISTENERS, HS_PYTHON; the rest are
# passthrough-change.sh's.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scripts=${HS_SCRIPTS:-$here/../../scripts}   # the core helpers; hs and hs-web set HS_SCRIPTS
. "$scripts/lib/ui.sh"
. "$scripts/lib/capability.sh"
routes_dir=${HS_GATEWAY_DIR:-/var/lib/hs-gateway}/routes
py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python
tab=$'\t'
pt() { PYTHONUTF8=1 "$py" -I "$here/passthrough.py" "$@"; }
change() { bash "$here/passthrough-change.sh" "$@"; }

usage() {
  say "usage: hs ext passthrough list | status"
  say "       hs ext passthrough add <domain> <address> [--https-port N] [--http-port N | --no-http] [--proxy-protocol] [--container-ok --confirm <domain>] [--yes]"
  say "       hs ext passthrough remove <domain> [--confirm <domain>]"
  say "       hs ext passthrough refresh"
  exit 1
}
probe() {   # probe <address> <port>
  if [ -n "${HS_PT_PROBE:-}" ]; then "$HS_PT_PROBE" "$1" "$2" >/dev/null 2>&1
  else timeout 1 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$1" "$2" >/dev/null 2>&1; fi
}
state_rows() {
  local d a s h p hs_
  while IFS=$'\t' read -r d a s h p; do
    [ -n "$d" ] || continue
    if probe "$a" "$s"; then s=up; else s=down; fi
    if [ "$h" = - ]; then hs_=-; elif probe "$a" "$h"; then hs_=up; else hs_=down; fi
    printf '%s\t%s\t%s\t%s\n' "$d" "$a" "$s" "$hs_"
  done < <(pt list "$routes_dir")
}
status_rows() {
  local g=off st n
  ! capability_on gateway || g=on
  st=$(timeout 10 bash "$scripts/gateway.sh" --status 2>/dev/null || true)
  printf 'gateway\t%s\n' "$g"
  for k in public_https public_http port_public_https port_public_http; do
    printf '%s\t%s\n' "$k" "$(awk -F"$tab" -v k="$k" '$1 == k { print $2; exit }' <<<"$st" | grep . || echo -)"
  done
  n=$(pt list "$routes_dir" | grep -c . || true)
  printf 'domains\t%s\n' "${n:-0}"
}
line_t() {   # line_t <plan text>: the three texts with names in them through t (the plan itself stays English: it is a contract with the web interface)
  local s=$1 a b c
  case "$s" in
    "that is the container '"*"' of this server: to forward a domain to it, confirm with --container-ok --confirm "*)
      a=${s#"that is the container '"}; a=${a%%"' of this server"*}; b=${s##* --confirm }
      t "that is the container '%s' of this server: to forward a domain to it, confirm with --container-ok --confirm %s" "$a" "$b" ;;
    "The WHOLE domain "*" goes to the container "*)
      a=${s#The WHOLE domain }; a=${a%% *}; b=${s#*goes to the container }; b=${b% of this server, and that container*}
      t "The WHOLE domain %s (apex and every subdomain) goes to the container %s of this server, and that container is reachable from the internet through this." "$a" "$b" ;;
    *" overlaps "*", a domain of the public reverse proxy, unless the target is the public reverse proxy itself")
      a=${s%% overlaps *}; b=${s#* overlaps }; b=${b%%, a domain*}
      t "%s overlaps %s, a domain of the public reverse proxy, unless the target is the public reverse proxy itself" "$a" "$b" ;;
    "the container '"*"' on port "*" is an admin page: "*)
      a=${s#"the container '"}; a=${a%%"'"*}; b=${s#*"' on port "}; b=${b%% *}
      t "the container '%s' on port %s is an admin page: it is never forwarded to the internet (ADMIN_TARGETS in scripts/services.py)" "$a" "$b" ;;
    "the route of "*" goes to "*", which is the container "*" of this server now, "*)
      a=${s#the route of }; a=${a%% *}; b=${s#* goes to }; b=${b%%,*}; c=${s#*which is the container }; c=${c% of this server now, *}
      t "the route of %s goes to %s, which is the container %s of this server now, and it was never confirmed with --container-ok: forward the domain again with --container-ok --confirm %s, or stop forwarding it" "$a" "$b" "$c" "$a" ;;
    *) _tr "$s" ;;
  esac
}
audit_routes() {   # warn about routes whose target is a container of this server now but was never confirmed
  local out
  out=$(change plan --audit audit 2>/dev/null) || true
  show_plan "$(grep -v '^heading' <<<"$out")"
}
show_plan() {   # show_plan <plan output>: the lines for people
  local k v
  while IFS=$'\t' read -r k v; do
    case "$k" in
      heading) step "$v" ;;
      step|note) note "$v" ;;
      warn) warn "$(line_t "$v")" ;;
      danger) danger "$v" ;;
    esac
  done <<<"$1"
}
plan_value() { awk -F"$tab" -v k="$2" '$1 == k { print $2; exit }' <<<"$1"; }

[ $# -ge 1 ] || usage
cmd=$1; shift
case "$cmd" in
--list) pt list "$routes_dir" ;;
--state) state_rows ;;
--status) status_rows ;;

list)
  if [ -z "$(pt list "$routes_dir")" ]; then note "No domain is forwarded yet."; next_step "hs ext passthrough add <domain> <address>"; exit 0; fi
  { thead 'Domain' 'Address' 'HTTPS' 'HTTP' 'PROXY'; pt list "$routes_dir"; } | table ;;

status)
  declare -A v=()
  while IFS=$'\t' read -r k val; do v[$k]=$val; done < <(status_rows)
  step "$(t 'Passthrough domains')"
  kv "Gateway proxy" "${v[gateway]}"
  kv "Public HTTPS" "${v[public_https]}$([ "${v[port_public_https]}" = - ] || printf ' (%s)' "${v[port_public_https]}")"
  kv "Public HTTP" "${v[public_http]}$([ "${v[port_public_http]}" = - ] || printf ' (%s)' "${v[port_public_http]}")"
  kv "Domains" "${v[domains]}"
  [ "${v[gateway]}" = on ] || warn "$(t 'The gateway proxy is off.')"
  [ "${v[public_https]}" != off ] && [ "${v[public_https]}" != - ] || warn "$(t 'No public HTTPS port: set gatewayPublicHttps = 443 in machine.toml, then hs rebuild.')"
  for k in port_public_https port_public_http; do
    case "${v[$k]}" in free|traefik|-) ;; *) warn "$(t 'A port is held by %s, not by Traefik (%s).' "${v[$k]}" "$k")" ;; esac
  done
  warn "$(t 'If the router rewrites the source address of forwarded traffic to its own address, every internet client looks local.')"
  note "$(t 'Test: open a local name of this server from a phone on mobile data; it must answer 403 (or 404), never a page.')"
  if [ "${v[domains]}" != 0 ]; then
    { thead 'Domain' 'Address' 'HTTPS' 'HTTP'; state_rows; } | table
    state_rows | awk -F"$tab" '$3 == "down" || $4 == "down" { print $1 }' | while IFS= read -r d; do
      warn "$(t 'The target of %s does not answer.' "$d")"
    done
    audit_routes
  fi ;;

add)
  [ $# -ge 2 ] || usage
  dom=$1; addr=$2; shift 2
  yes=false; args=(); typed=""
  while [ $# -gt 0 ]; do   # --confirm is the typed domain (needed for a container target), not an argument of the plan
    case "$1" in
      --yes) yes=true ;;
      --confirm) typed=${2:-}; [ $# -lt 2 ] || shift ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  rc=0; out=$(change plan "$dom" add --address "$addr" "${args[@]+"${args[@]}"}") || rc=$?
  [ "$rc" -eq 0 ] || fail "$(line_t "$(plan_value "$out" reason)")"
  show_plan "$out"
  name=$(plan_value "$out" confirm_name)
  if [ -n "$name" ]; then   # a container of this server: the typed domain, --yes does not replace it
    if [ "$typed" != "$name" ]; then
      [ -z "$typed" ] || fail "$(t 'The typed name does not match: %s' "$name")"
      [ -t 0 ] || fail "$(t 'Nobody to ask: add --confirm %s to go on.' "$name")"
      confirm_name "$name" "the domain" || fail "$(t 'Cancelled.')"
    fi
  elif ! $yes; then
    [ -t 0 ] || fail "$(t 'Nobody to ask: add --yes to go on.')"
    confirm "Forward this domain?" || fail "$(t 'Cancelled.')"
  fi
  rc=0; res=$(change start "$dom" add --address "$addr" "${args[@]+"${args[@]}"}" ${name:+--confirm "$name"}) || rc=$?
  [ "$rc" -eq 0 ] || fail "$(plan_value "$res" reason)"
  ok "$(t 'Forwarding %s and its subdomains to %s' "$(plan_value "$out" heading | awk '{ print $2 }')" "$addr")"
  next_step "hs ext passthrough status" ;;

remove)
  [ $# -ge 1 ] || usage
  dom=$1; shift
  typed=""
  [ "${1:-}" != --confirm ] || typed=${2:-}
  rc=0; out=$(change plan "$dom" remove) || rc=$?
  [ "$rc" -eq 0 ] || fail "$(line_t "$(plan_value "$out" reason)")"
  show_plan "$out"
  name=$(plan_value "$out" confirm_name)
  if [ "$typed" != "$name" ]; then
    [ -z "$typed" ] || fail "$(t 'The typed name does not match: %s' "$name")"
    [ -t 0 ] || fail "$(t 'Nobody to ask: add --confirm %s to go on.' "$name")"
    confirm_name "$name" "the domain" || fail "$(t 'Cancelled.')"
  fi
  rc=0; res=$(change start "$dom" remove --confirm "$name") || rc=$?
  [ "$rc" -eq 0 ] || fail "$(plan_value "$res" reason)"
  ok "$(t 'Stopped forwarding %s' "$name")" ;;

refresh)
  rc=0; out=$(change start --refresh refresh) || rc=$?
  [ "$rc" -eq 0 ] || fail "$(line_t "$(plan_value "$out" reason)")"
  show_plan "$out"   # the routes that were left as they are, with the reason
  ok "$(t 'The route files are written again.')"
  audit_routes ;;

*) usage ;;
esac
