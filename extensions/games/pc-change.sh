#!/usr/bin/env bash
# help: change a saved game PC without asking anything: what would happen (plan), then do it (start)
# help.de: einen gemerkten Spiele-PC ändern, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start <name> wake | plan|start <name> add --mac <mac> [--ip <ip>] | plan|start <name> remove
# System command (hs sys ext games plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like
# jobs-change.sh. The work is pc.sh's (no logic is repeated here).
#   wake    send the Wake-on-LAN packet to the PC (pc.sh wake <name>); the plan names the MAC address it goes to. The packet is instant, so
#           start does not run a background job: it answers status done.
#   add     save the PC (pc.sh add <name> <mac> [<ip>]); a name that is saved already gets the new MAC and address. Without --mac the
#           plan answers status needs, needs<TAB>mac (exit 2).
#   remove  forget the saved PC (pc.sh remove <name>). Nothing else is touched; it can be added again. Not red: one line of a text file.
# plan: exit 0 = allowed, 1 = refused, 2 = something is missing. Output: status ok|refused|needs, reason<TAB><text>, needs<TAB><what>,
#   heading|step|note|warn|command<TAB><line>, long<TAB>no.
# start: the same checks, then status<TAB>done (or refused).
# Test knobs: HS_PC (stand-in for pc.sh), HS_STATE_DIR (the folder with the file `pcs`).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pc=${HS_PC:-$here/pc.sh}
file=${HS_STATE_DIR:-/var/lib/hs}/pcs

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; name=${2:-}; action=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: pc-change.sh plan|start <name> wake|remove | add --mac <mac> [--ip <ip>]" >&2; exit 1 ;; esac
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,40}$ ]] || refuse "invalid PC name"
case "$action" in wake|add|remove) ;; *) refuse "unknown action (wake, add or remove)" ;; esac
shift 3 || true
mac="" ip=""
if [ "$action" = add ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --mac) mac=${2:-}; shift 2 || refuse "--mac needs a value" ;;
      --ip)  ip=${2:-}; shift 2 || refuse "--ip needs a value" ;;
      *) refuse "unknown option $1" ;;
    esac
  done
  if [ -z "$mac" ]; then printf 'status	needs
needs	mac
'; exit 2; fi
  [[ "$mac" =~ ^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$ ]] || refuse "'$mac' is not a MAC address (like aa:bb:cc:dd:ee:ff)"
  if [ -n "$ip" ]; then
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || refuse "'$ip' is not an IPv4 address"
    IFS=. read -r o1 o2 o3 o4 <<<"$ip"
    for o in $o1 $o2 $o3 $o4; do [ "$((10#$o))" -le 255 ] || refuse "'$ip' is not an IPv4 address"; done
  fi
  mac=$(tr 'A-F-' 'a-f:' <<<"$mac")
else
  [ $# -eq 0 ] || refuse "unexpected extra arguments"
fi

line=$(awk -F'	' -v n="$name" '$1 == n { print; exit }' "$file" 2>/dev/null || true)
if [ "$action" != add ]; then
  [ -n "$line" ] || refuse "No PC called '$name' is saved."
  IFS=$'	' read -r _ mac ip <<<"$line"
fi

case "$action" in
  wake)   cmd=(bash "$pc" wake "$name") ;;
  remove) cmd=(bash "$pc" remove "$name") ;;
  add)    cmd=(bash "$pc" add "$name" "$mac"); [ -z "$ip" ] || cmd+=("$ip") ;;
esac
if [ "$verb" = start ]; then
  rc=0; out=$("${cmd[@]}" </dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'status	refused
reason	%s
' "$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)"
    exit 1
  fi
  printf 'status	done
'
  exit 0
fi

printf 'status	ok
'
case "$action" in
  wake)
    printf 'heading	wake %s
' "$name"
    printf 'step	send the Wake-on-LAN packet to %s from this server
' "$mac"
    printf 'note	The PC needs Wake-on-LAN switched on in its BIOS and network card. The server cannot tell afterwards whether it has started.
'
    [ -z "$ip" ] || printf 'note	Its address is %s; Sunshine answers there once the PC is up.
' "$ip" ;;
  add)
    printf 'heading	save the game PC %s
' "$name"
    printf 'step	remember %s with the MAC address %s%s
' "$name" "$mac" "${ip:+ and the address $ip}"
    [ -z "$line" ] || printf 'warn	%s is saved already: its MAC address and address are replaced.
' "$name"
    [ -n "$ip" ] || printf 'note	Without an address the server cannot see whether Sunshine answers on the PC.
'
    printf 'note	The PC itself needs Wake-on-LAN switched on and Sunshine installed.
' ;;
  remove)
    printf 'heading	forget the game PC %s
' "$name"
    printf 'step	take %s (%s) off the list
' "$name" "$mac"
    printf 'note	The PC itself is not touched. Add it again any time.
' ;;
esac
printf 'command	%s
' "${cmd[*]}"
printf 'long	no
'
