#!/usr/bin/env bash
# help: forward or stop forwarding an outside domain without asking anything: what would happen (plan), then do it (start)
# help.de: eine fremde Domain durchreichen oder nicht mehr durchreichen, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start <domain> add --address <a> [--https-port 443] [--http-port 80 | --no-http] [--proxy-protocol] [--container-ok] [--confirm <domain>] | plan|start <domain> remove [--confirm <domain>]
# System command (hs sys ext passthrough plan|start): for the interface and tests. It never asks and prints key<TAB>value lines like
# capabilities/games/pc-change.sh. The route files are rendered by passthrough.py and moved in through the gateway's tmp/ folder.
#   add     TLS passthrough by SNI on the public HTTPS port, plain HTTP by Host on the public HTTP port (not when --no-http or the
#           gateway's public HTTP port is 0), optional PROXY protocol v2 on HTTPS. Without --address: status needs, needs<TAB>address (exit 2).
#           A target that is an Incus container of this server (e.g. a reverse proxy in a container) is refused (reason names it) unless
#           --container-ok; then the plan warns and asks for confirm_name, and start needs --confirm <domain> (the web interface appends it).
#           The host's own addresses, loopback and non-LAN addresses stay refused whatever is passed.
#   remove  delete the route file; red: the visitors of the domain get no answer. start needs --confirm <domain>.
# plan: exit 0 = allowed, 1 = refused, 2 = something is missing. Output: status ok|refused|needs, reason<TAB><text>, needs<TAB><what>,
#   heading|step|note|warn|danger|command<TAB><line>, confirm_name<TAB><domain> (remove, add with --container-ok), long<TAB>no.
# start: the same checks, then status<TAB>done (or refused).
# HS_PT_INSTANCE_ADDRS is `incus list --format csv -c n46`: name, then cells of 'address (iface)'; lines of bare 'address (iface)' work too (no name).
# Test knobs: HS_GATEWAY_DIR, HS_GATEWAY_PUBLIC_FILE, HS_PT_HOST_ADDRS, HS_PT_INSTANCE_ADDRS, HS_PT_INSTANCE_FAIL (1 = incus failed: every address refused), HS_PT_PROXY_HOSTS, HS_SETTINGS_DIR,
# HS_MACHINE_FILE, HS_SITE_NAME_FILE, HS_CAPABILITIES_FILE, HS_GATEWAY_LISTENERS, HS_PYTHON.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scripts=${HS_SCRIPTS:-$here/../../scripts}   # the core helpers; hs and hs-web set HS_SCRIPTS
. "$scripts/lib/machine.sh"
. "$scripts/lib/setting.sh"
. "$scripts/lib/capability.sh"
. "$scripts/lib/dc.sh"
. "$scripts/lib/localdomain.sh"
gdir=${HS_GATEWAY_DIR:-/var/lib/hs-gateway}
routes_dir=$gdir/routes
tmp_dir=$gdir/tmp
public_file=${HS_GATEWAY_PUBLIC_FILE:-/etc/hs/gateway-public}
py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python
tab=$'\t'
umask 027
pt() { PYTHONUTF8=1 "$py" -I "$here/passthrough.py" "$@"; }

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }
# chk <variable> <args of passthrough.py>: the answer goes into the variable (not a $(...): refuse must exit this shell); exit 1 = refused
chk() { local __v=$1 __o __rc=0; shift; __o=$(pt "$@" 2>/dev/null) || __rc=$?; [ "$__rc" -eq 0 ] || refuse "${__o:-bad input}"; printf -v "$__v" '%s' "$__o"; }

admin_a=()
admin_args() {   # the tables of admin ports: services.py, ports.sh (dc1 renamed the way ports.sh does it), the user rows of ports-admin
  admin_a=(--admin-from "$scripts/services.py" --ports-from "$scripts/ports.sh" --dc-name "$(dc_name 2>/dev/null || echo dc1)"
    --ports-admin "${HS_STATE_DIR:-/var/lib/hs}/ports-admin")
}
admin_hit() {   # admin_hit <address> <https> <http>: exit 1 and the text on stdout when the target is an admin container/port
  [ -n "${admin_a[*]:-}" ] || admin_args
  pt admin-check "$1" --instance-addrs "$inst_addrs" --https-port "$2" --http-port "$3" ${admin_a[@]+"${admin_a[@]}"} 2>/dev/null
}
load_inst() {   # inst_addrs (csv of the instances: name, running addresses, static addresses of their devices) and inst_failed
  inst_addrs=${HS_PT_INSTANCE_ADDRS:-}
  inst_failed=${HS_PT_INSTANCE_FAIL:+yes}   # test knob: simulate "incus is installed but failed"
  if [ -z "$inst_addrs" ]; then
    local inst_json
    inst_addrs=$(mktemp); trap 'rm -f "${host_addrs:-}" "$inst_addrs"' EXIT
    if command -v incus >/dev/null 2>&1; then   # no incus at all = a host without containers; a failing incus = unknown, so refuse
      timeout 10 incus list --all-projects --format csv -c n46 >"$inst_addrs" 2>/dev/null || inst_failed=yes
      # a stopped container with a static address shows none in the list above: add the addresses of the devices
      inst_json=$(mktemp)
      if timeout 10 incus list --all-projects --format json >"$inst_json" 2>/dev/null && pt static-addrs "$inst_json" >>"$inst_addrs" 2>/dev/null; then :; else inst_failed=yes; fi
      rm -f "$inst_json"
    fi
  fi
  inst_loaded=1
}

verb=${1:-}; dom=${2:-}; action=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: passthrough-change.sh plan|start <domain> add --address <a> [...] | remove [--confirm <domain>]" >&2; exit 1 ;; esac
shift 3 2>/dev/null || true
[ "$dom" != --refresh ] || action=refresh   # hs ext passthrough refresh: write every file again, no guard
[ "$dom" != --audit ] || action=audit       # hs ext passthrough status|refresh: warn about routes whose target is a container now
case "$action" in add|remove|refresh|audit) ;; *) refuse "unknown action (add or remove)" ;; esac

capability_on gateway || refuse 'the gateway proxy is off (capabilities = ["gateway"], hs rebuild)'
if [ "$action" = audit ]; then
  load_inst
  printf 'status	ok
heading	check the targets of the routes
'
  if [ -n "$inst_failed" ]; then
    printf 'note	cannot read the container list: the targets of the routes were not checked
'
  else
    while IFS=$'	' read -r d a s h _ c; do
      [ -n "$d" ] || continue
      if cn=$(pt container "$a" --instance-addrs "$inst_addrs" 2>/dev/null); then
        [ "$c" = yes ] || printf 'warn	the route of %s goes to %s, which is the container %s of this server now, and it was never confirmed with --container-ok: forward the domain again with --container-ok --confirm %s, or stop forwarding it
' "$d" "$a" "$cn" "$d"
        if ! msg=$(admin_hit "$a" "$s" "$h"); then printf 'warn	the route of %s: %s
' "$d" "$msg"; fi
      fi
    done < <(pt list "$routes_dir" --full)
  fi
  printf 'long	no
'
  exit 0
fi
pub() { local v; v=$(sed -n "s/^$1=//p" "$public_file" 2>/dev/null | head -n 1); printf '%s' "${v:-0}"; }
pub_https=$(pub https); pub_http=$(pub http)
if [ "$pub_https" = 0 ]; then
  cfg_https=$(machine_get gatewayPublicHttps 2>/dev/null || true)
  case "$cfg_https" in ''|0|*[!0-9]*) refuse 'no public port: set gatewayPublicHttps = 443 in machine.toml, then hs rebuild' ;; esac
  refuse 'gatewayPublicHttps is set in machine.toml but not applied yet: run hs rebuild'
fi
[ "$action" = refresh ] || chk dom domain "$dom"
file=$routes_dir/pt-$dom.yml
old=""
[ ! -f "$file" ] || old=$(pt list "$routes_dir" | awk -F"$tab" -v d="$dom" '$1 == d { print $2; exit }')

addr="" https=443 http=80 proxy=off confirm="" container_ok=""
while [ $# -gt 0 ]; do
  case "$1" in
    --address) [ "$action" = add ] || refuse "unknown option $1"; addr=${2:-}; shift 2 || refuse "--address needs a value" ;;
    --https-port) [ "$action" = add ] || refuse "unknown option $1"; https=${2:-}; shift 2 || refuse "--https-port needs a value" ;;
    --http-port) [ "$action" = add ] || refuse "unknown option $1"; http=${2:-}; shift 2 || refuse "--http-port needs a value" ;;
    --no-http) [ "$action" = add ] || refuse "unknown option $1"; http=-; shift ;;
    --proxy-protocol) [ "$action" = add ] || refuse "unknown option $1"; proxy=on; shift ;;
    --container-ok) [ "$action" = add ] || refuse "unknown option $1"; container_ok=yes; shift ;;
    --confirm) confirm=${2:-}; shift 2 || refuse "--confirm needs a value" ;;
    *) refuse "unknown option $1" ;;
  esac
done

warns=()
write_file() {   # write_file <domain> <address> <https> <http> <proxy> [yes: confirmed container target]: render into tmp/, move in (atomic)
  local tmp
  mkdir -p "$tmp_dir" "$routes_dir" 2>/dev/null
  tmp=$(mktemp "$tmp_dir/pt-$1.XXXXXX") || return 1
  if ! pt render "$1" "$2" "$3" "$4" "$5" "$pub_http" ${6:+container} >"$tmp"; then rm -f "$tmp"; return 1; fi
  chmod 0640 "$tmp" && mv -f "$tmp" "$routes_dir/pt-$1.yml" || { rm -f "$tmp"; return 1; }
}
skipped=()
refresh_all() {   # every pt- file again from its header (a changed gateway-public is picked up); a route whose target is an admin container now is left as it is
  local d a s h p c msg
  [ -n "${inst_loaded:-}" ] || { load_inst; inst_loaded=1; }
  while IFS=$'	' read -r d a s h p c; do
    [ -n "$d" ] || continue
    if [ -n "$inst_failed" ]; then
      skipped+=("the route of $d was not written again: the container list cannot be read")
      continue
    fi
    if ! msg=$(admin_hit "$a" "$s" "$h"); then
      skipped+=("the route of $d was not written again: $msg")
      continue
    fi
    write_file "$d" "$a" "$s" "$h" "$p" "$([ "$c" = yes ] && echo yes)" || return 1
  done < <(pt list "$routes_dir" --full)
}

if [ "$action" = refresh ]; then
  [ "$verb" = start ] || { printf 'status	ok
heading	write the route files again
long	no
'; exit 0; }
  refresh_all || refuse "could not write the route files"
  for w in "${skipped[@]+"${skipped[@]}"}"; do printf 'warn	%s
' "$w"; done
  printf 'status	done
'
  exit 0
fi
if [ "$action" = remove ]; then
  [ -f "$file" ] || refuse "$dom is not forwarded."
  if [ "$verb" = start ]; then
    [ "$confirm" = "$dom" ] || refuse "type the domain to confirm: $dom"
    rm -f "$file" && refresh_all || refuse "could not write the route files"
    printf 'status\tdone\n'
    exit 0
  fi
  printf 'status\tok\nheading\tstop forwarding %s\n' "$dom"
  printf 'step\tdelete pt-%s.yml (Traefik drops the route within seconds)\n' "$dom"
  printf 'danger\tVisitors of %s and *.%s get no answer until it is added again.\n' "$dom" "$dom"
  printf 'confirm_name\t%s\nlong\tno\n' "$dom"
  exit 0
fi

# add
if [ -z "$addr" ]; then printf 'status\tneeds\nneeds\taddress\n'; exit 2; fi
chk https port "$https"
[ "$http" = - ] || chk http port "$http"

# inputs of the guard
host_addrs=${HS_PT_HOST_ADDRS:-}
if [ -z "$host_addrs" ]; then host_addrs=$(mktemp); trap 'rm -f "$host_addrs"' EXIT; ip -o addr show >"$host_addrs" 2>/dev/null || true; fi
load_inst
[ -z "$container_ok" ] || admin_args
chk addr address "$addr" --host-addrs "$host_addrs" --instance-addrs "$inst_addrs" --domain "$dom" --https-port "$https" --http-port "$http" ${admin_a[@]+"${admin_a[@]}"} ${container_ok:+--container-ok yes} ${inst_failed:+--instance-failed yes}
cname=$(pt container "$addr" --instance-addrs "$inst_addrs" 2>/dev/null) || cname=""

rp=$(setting_get reverseProxy 2>/dev/null || true)
proxy_hosts=${HS_PT_PROXY_HOSTS:-}
if [ -z "$proxy_hosts" ]; then
  proxy_hosts=$(mktemp); trap 'rm -f "$host_addrs" "$inst_addrs" "$proxy_hosts"' EXIT
  if [ -n "$rp" ] && [ -f "$scripts/providers/reverse-proxy/$rp.sh" ]; then
    timeout 15 bash "$scripts/providers/reverse-proxy/$rp.sh" list 2>/dev/null | awk -F"$tab" '{ print $1 }' >"$proxy_hosts" ||
      warns+=("could not read the routes of the reverse proxy; only proxyDomains was checked")
  elif [ -n "$rp" ]; then
    warns+=("could not read the routes of the reverse proxy; only proxyDomains was checked")
  fi
fi
# the container the public reverse proxy runs in (its provider's info says it; unknown = empty = the overlap stays refused)
# the proxy runs in the default project: only that project's list counts (a container of the same name elsewhere gets no exception; failure = empty = refused)
default_addrs=${HS_PT_DEFAULT_ADDRS:-}
if [ -z "$default_addrs" ]; then
  if [ -n "${HS_PT_INSTANCE_ADDRS:-}" ]; then default_addrs=$inst_addrs
  else
    default_addrs=$(mktemp); trap 'rm -f "$host_addrs" "$inst_addrs" "$proxy_hosts" "$default_addrs"' EXIT
    timeout 10 incus list --project default --format csv -c n46 >"$default_addrs" 2>/dev/null || : >"$default_addrs"
  fi
fi
proxy_ct=${HS_PT_PROXY_CT:-}
if [ -z "$proxy_ct" ] && [ -n "$rp" ] && [ -f "$scripts/providers/reverse-proxy/$rp.sh" ]; then
  proxy_ct=$(timeout 15 bash "$scripts/providers/reverse-proxy/$rp.sh" info 2>/dev/null | awk -F"$tab" '$1 == "container" { print $2; exit }') || proxy_ct=""
fi
realm=$(machine_get adDomain.realm 2>/dev/null | tr 'A-Z' 'a-z' | tr -d ' \r\n' || true)
chk _ guard "$dom" --proxy-domains "$(setting_get proxyDomains 2>/dev/null || true)" --local-domain "$(local_domain)" --realm "$realm" \
  --proxy-hosts "$proxy_hosts" --routes "$routes_dir" --target "$addr" --instance-addrs "$default_addrs" --proxy-container "$proxy_ct"

if [ "$verb" = start ]; then
  [ -z "$cname" ] || [ "$confirm" = "$dom" ] || refuse "type the domain to confirm: $dom"
  write_file "$dom" "$addr" "$https" "$http" "$proxy" "$([ -n "$cname" ] && echo yes)" && refresh_all || refuse "could not write the route files"
  printf 'status\tdone\n'
  exit 0
fi

cmd="passthrough.py render $dom $addr $https $http $proxy $pub_http"
printf 'status\tok\nheading\tforward %s and *.%s to %s\n' "$dom" "$dom" "$addr"
printf 'step\tpublic port %s (TLS passthrough by SNI) -> %s:%s%s\n' "$pub_https" "$addr" "$https" "$([ "$proxy" = on ] && echo ' with PROXY protocol v2')"
if [ "$http" != - ] && [ "$pub_http" != 0 ]; then
  printf 'step\tpublic port %s (HTTP, Host header kept) -> %s:%s\n' "$pub_http" "$addr" "$http"
else
  printf 'note\tHTTP is not forwarded (--no-http, or gatewayPublicHttp = 0)\n'
fi
if [ -n "$cname" ]; then
  printf 'warn\tThe WHOLE domain %s (apex and every subdomain) goes to the container %s of this server, and that container is reachable from the internet through this.\n' "$dom" "$cname"
fi
[ -z "$old" ] || printf 'warn\t%s is forwarded already (to %s): the target is replaced\n' "$dom" "$old"
for w in "${warns[@]+"${warns[@]}"}"; do printf 'warn\t%s\n' "$w"; done
st=$(timeout 10 bash "$scripts/gateway.sh" --status 2>/dev/null || true)
for k in https http; do
  o=$(awk -F"$tab" -v k="port_public_$k" '$1 == k { print $2; exit }' <<<"$st")
  case "${o:--}" in traefik|free|-) ;; *) printf 'warn\tthe public %s port is held by %s, not by Traefik\n' "$k" "$o" ;; esac
done
printf 'note\tDNS of %s and *.%s must point at the public address, and the router must forward its port 443 to port %s and its port 80 to port %s of this server.\n' "$dom" "$dom" "$pub_https" "$pub_http"
printf 'note\tThis server holds no certificate: the target answers TLS itself.\n'
[ -z "$cname" ] || printf 'confirm_name\t%s\n' "$dom"
printf 'command\t%s\nlong\tno\n' "$cmd"
exit 0
