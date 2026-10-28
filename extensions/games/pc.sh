#!/usr/bin/env bash
# help: game PCs at home that stream with Sunshine: list, add, remove, wake (Wake-on-LAN)
# help.de: Spiele-PCs zu Hause, die mit Sunshine streamen: anzeigen, hinzufügen, entfernen, aufwecken (Wake-on-LAN)
# args: list | --list | --state | add <name> <mac> [<ip>] | remove <name> | wake <name> [--wait]
# Remembers a PC (name, MAC, optional address) in /var/lib/hs/pcs. `wake` sends the magic packet from the server (the
# server sits in the network the PC is in, a TV in another VLAN cannot wake it); with --wait it then waits (up to 3
# minutes) until the PC's Sunshine answers on port 47989, which needs the address. The PC itself needs Wake-on-LAN
# switched on in its BIOS and network card, and Sunshine installed.
# --list = name TAB MAC TAB address (- when none), one row per PC, no header, nothing for no PC (machine readable, `hs sys ext games list`; reads
# the file only, wakes nothing and says nothing about whether the PC is on).
# --state (hs sys ext games state) = name TAB address TAB state, one row per PC, no header: state up when Sunshine answers on port 47989 at the address
# (a 1 s try each), down when it does not (the PC is off or asleep, or Sunshine is not running: the two cannot be told apart), unknown when no
# address is saved. Wakes nothing. HS_PC_PROBE (called with address and port, exit 0 = answers) stands in for the try.
# HS_STATE_DIR points tests at another folder; HS_WOL_CMD (called with the MAC) stands in for the packet, HS_PC_WAIT_SECONDS
# for the 180 s of --wait, HS_PC_PORT for the port 47989 it waits for.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scripts=${HS_SCRIPTS:-$here/../../scripts}   # the core helpers; hs and hs-web set HS_SCRIPTS
. "$scripts/lib/ui.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
file=$state/pcs

usage() {
  say "usage: hs ext games list"
  say "       hs ext games add <name> <mac> [<ip>]"
  say "       hs ext games remove <name>"
  say "       hs ext games wake <name> [--wait]"
  exit 1
}
mac_re='^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$'
ip_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
find_pc() {   # find_pc <name>: the line, empty when unknown
  [ -f "$file" ] || return 0
  awk -F'\t' -v n="$1" '$1 == n { print; exit }' "$file"
}

[ $# -ge 1 ] || usage
cmd=$1; shift
case "$cmd" in
--list)
  [ ! -s "$file" ] || awk -F'\t' '{ printf "%s\t%s\t%s\n", $1, $2, ($3 == "" ? "-" : $3) }' "$file" ;;

--state)
  [ -s "$file" ] || exit 0
  while IFS=$'	' read -r n _ ip; do
    [ -n "$n" ] || continue
    if [ -z "$ip" ]; then st=unknown
    elif [ -n "${HS_PC_PROBE:-}" ]; then if "$HS_PC_PROBE" "$ip" "${HS_PC_PORT:-47989}" >/dev/null 2>&1; then st=up; else st=down; fi
    elif timeout 1 bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$ip" "${HS_PC_PORT:-47989}" >/dev/null 2>&1; then st=up
    else st=down; fi
    printf '%s	%s	%s
' "$n" "${ip:--}" "$st"
  done < "$file" ;;

list)
  if [ ! -s "$file" ]; then note "No PC saved yet."; next_step "hs ext games add <name> <mac> [<ip>]"; exit 0; fi
  { thead 'Name' 'MAC' 'Address'
    awk -F'\t' '{ printf "%s\t%s\t%s\n", $1, $2, ($3 == "" ? "-" : $3) }' "$file"; } | table ;;

add)
  [ $# -ge 2 ] && [ $# -le 3 ] || usage
  name=$1; mac=$2; ip=${3:-}
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "$(t "'%s' is not a usable name (letters, digits, . _ -)" "$name")"
  [[ "$mac" =~ $mac_re ]] || fail "$(t "'%s' is not a MAC address (like aa:bb:cc:dd:ee:ff)" "$mac")"
  [ -z "$ip" ] || [[ "$ip" =~ $ip_re ]] || fail "$(t "'%s' is not an IPv4 address" "$ip")"
  mac=$(tr 'A-F-' 'a-f:' <<<"$mac")
  mkdir -p "$state"
  { { [ ! -f "$file" ] || awk -F'\t' -v n="$name" '$1 != n' "$file"; } ; printf '%s\t%s\t%s\n' "$name" "$mac" "$ip"; } > "$file.tmp"
  mv "$file.tmp" "$file"
  ok "$(t "Saved '%s' (%s)" "$name" "$mac")"
  next_step "hs ext games wake $name" ;;

remove)
  [ $# -eq 1 ] || usage
  [ -n "$(find_pc "$1")" ] || fail_fix "$(t "No PC called '%s'" "$1")" "hs ext games list"
  awk -F'\t' -v n="$1" '$1 != n' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
  ok "$(t "Removed '%s'" "$1")" ;;

wake)
  [ $# -ge 1 ] && [ $# -le 2 ] || usage
  name=$1; wait=false
  [ "${2:-}" != --wait ] || wait=true
  [ $# -eq 1 ] || $wait || usage
  line=$(find_pc "$name")
  [ -n "$line" ] || fail_fix "$(t "No PC called '%s'" "$name")" "hs ext games list"
  IFS=$'\t' read -r _ mac ip <<<"$line"
  if [ -n "${HS_WOL_CMD:-}" ]; then
    "$HS_WOL_CMD" "$mac"
  else
    command -v python3 >/dev/null 2>&1 || fail "python3 is needed to send the packet"
    python3 - "$mac" <<'PY'
import socket, sys
mac = bytes.fromhex(sys.argv[1].replace(":", ""))
packet = b"\xff" * 6 + mac * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for port in (9, 7):
    s.sendto(packet, ("255.255.255.255", port))
PY
  fi
  ok "$(t "Wake-up packet sent to '%s' (%s)" "$name" "$mac")"
  if $wait; then
    [ -n "$ip" ] || fail_fix "--wait needs the address of the PC." "hs ext games add $name $mac <ip>"
    secs=${HS_PC_WAIT_SECONDS:-180}
    spin "$(t "Waiting for Sunshine on '%s' (%s)" "$name" "$ip")" \
      bash -c 'end=$((SECONDS + $2)); while [ "$SECONDS" -lt "$end" ]; do timeout 2 bash -c "exec 3<>/dev/tcp/$1/$3" 2>/dev/null && exit 0; sleep 2; done; exit 1' _ "$ip" "$secs" "${HS_PC_PORT:-47989}" ||
      fail "$(t "'%s' did not answer within %s seconds. Is Wake-on-LAN on in its BIOS and is Sunshine running?" "$name" "$secs")"
    ok "$(t "'%s' is up and Sunshine answers" "$name")"
  fi ;;

*) usage ;;
esac
