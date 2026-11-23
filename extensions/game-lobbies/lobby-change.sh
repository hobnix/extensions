#!/usr/bin/env bash
# help: change a game lobby without asking anything: what would happen (plan), then do it (start)
# help.de: eine Spiel-Lobby ändern, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start <name> restore <snapshot> | <name> link [--hours N] | <name> add --instance <i> --port <p> [--game <g>] | <name> remove | <id> revoke
# System command (hs sys ext game-lobbies plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like
# jobs-change.sh. The work is lobby.sh's (saving, forgetting, links) and the core's manage-ct.sh (the restore); no logic is repeated here.
#   restore  go back to a snapshot of the lobby's instance (manage-ct.sh <instance> --restore <snapshot>). ZFS can only go back to the newest
#            snapshot, so newer ones are deleted first: the plan names them. Players are disconnected. An extension start cannot run as a
#            background job yet, so it is synchronous (the plan says `long yes`).
#   link     make a wake link that expires (--hours 1..720, default 24)
#   revoke   delete a wake link by its id
#   add      save the lobby; without --instance or --port the plan answers status needs (exit 2)
#   remove   forget the lobby and its wake links (instance and snapshots stay)
# plan: exit 0 = allowed, 1 = refused, 2 = something is missing. Output: status ok|refused|needs, reason<TAB><text>, needs<TAB><what>,
#   heading|step|note|warn<TAB><line>, long<TAB>yes|no. start: the same checks, then status<TAB>done (or refused).
# Test knobs: HS_LOBBY (stand-in for lobby.sh), HS_CT (stand-in for manage-ct.sh), HS_INCUS, HS_STATE_DIR.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scripts=${HS_SCRIPTS:-$here/../../scripts}
lobby=${HS_LOBBY:-$here/lobby.sh}
ct=${HS_CT:-$scripts/manage-ct.sh}
inc=${HS_INCUS:-incus}
file=${HS_STATE_DIR:-/var/lib/hs}/game-lobbies/lobbies

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; name=${2:-}; action=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: lobby-change.sh plan|start <name> restore <snapshot> | link | add | remove | <id> revoke" >&2; exit 1 ;; esac
case "$action" in restore|link|add|remove|revoke) ;; *) refuse "unknown action (restore, link, add, remove or revoke)" ;; esac
shift 3 || true
if [ "$action" = revoke ]; then
  [[ "$name" =~ ^[0-9a-f]{8}$ ]] || refuse "invalid link id"
else
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,40}$ ]] || refuse "invalid lobby name"
fi

line=$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' "$file" 2>/dev/null || true)
inst="" snap="" hours=24 ainst="" aport="" agame=""
if [ "$action" != add ] && [ "$action" != revoke ]; then
  [ -n "$line" ] || refuse "No lobby called '$name' is saved."
  IFS=$'\t' read -r _ inst _ <<<"$line"
fi

case "$action" in
  restore)
    snap=${1:-}; shift || true; [ $# -eq 0 ] || refuse "unexpected extra arguments"
    [[ "$snap" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || refuse "invalid snapshot name"
    snaps=$("$inc" query "/1.0/instances/$inst/snapshots?recursion=1" 2>/dev/null | jq -r 'sort_by(.created_at) | .[].name | sub(".*/"; "")') ||
      refuse "The instance '$inst' of '$name' could not be read."
    grep -qxF "$snap" <<<"$snaps" || refuse "'$inst' has no snapshot called '$snap'."
    newer=$(awk -v s="$snap" 'f { print } $0 == s { f = 1 }' <<<"$snaps") ;;
  link)
    while [ $# -gt 0 ]; do
      case "$1" in
        --hours) hours=${2:-}; shift 2 || refuse "--hours needs a value" ;;
        *) refuse "unknown option $1" ;;
      esac
    done
    [[ "$hours" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$hours))" -ge 1 ] && [ "$((10#$hours))" -le 720 ] || refuse "--hours is 1 to 720" ;;
  add)
    while [ $# -gt 0 ]; do
      case "$1" in
        --instance) ainst=${2:-}; shift 2 || refuse "--instance needs a value" ;;
        --port)     aport=${2:-}; shift 2 || refuse "--port needs a value" ;;
        --game)     agame=${2:-}; shift 2 || refuse "--game needs a value" ;;
        *) refuse "unknown option $1" ;;
      esac
    done
    if [ -z "$ainst" ]; then printf 'status\tneeds\nneeds\tinstance\n'; exit 2; fi
    if [ -z "$aport" ]; then printf 'status\tneeds\nneeds\tport\n'; exit 2; fi
    [[ "$ainst" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || refuse "'$ainst' is not an instance name"
    [[ "$aport" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$aport))" -ge 1 ] && [ "$((10#$aport))" -le 65535 ] || refuse "'$aport' is not a port (1-65535)" ;;
  remove|revoke) [ $# -eq 0 ] || refuse "unexpected extra arguments" ;;
esac

if [ "$verb" = plan ]; then
  printf 'status\tok\n'
  case "$action" in
    restore)
      printf 'heading\tgo back to the snapshot %s\n' "$snap"
      printf 'step\tgo back to the snapshot "%s" of the instance %s (lobby %s)\n' "$snap" "$inst" "$name"
      printf 'warn\tEveryone playing in %s is disconnected and the world is what it was at that snapshot.\n' "$name"
      if [ -n "$newer" ]; then
        printf 'warn\tNewer snapshots are deleted for good (the file system can only go back to the newest one): %s\n' "$(tr '\n' ' ' <<<"$newer" | sed 's/ $//')"
      fi
      printf 'note\tTake a snapshot of the current state first if you may want it back.\nlong\tyes\n' ;;
    link)
      printf 'heading\tmake a wake link for %s\n' "$name"
      printf 'step\tmake a link that starts %s and expires after %s hours\n' "$name" "$((10#$hours))"
      printf 'note\tWhoever has the link can start the lobby until it expires. Revoke it in the list of links.\nlong\tno\n' ;;
    revoke)
      printf 'heading\trevoke the wake link %s\nstep\tdelete the link; it stops working at once\nlong\tno\n' "$name" ;;
    add)
      printf 'heading\tsave the lobby %s\nstep\tsave %s as the instance %s on port %s\nlong\tno\n' "$name" "$name" "$ainst" "$((10#$aport))" ;;
    remove)
      printf 'heading\tforget the lobby %s\nstep\tremove %s and its wake links from the list\nnote\tThe instance and its snapshots are not touched.\nlong\tno\n' "$name" "$name" ;;
  esac
  exit 0
fi

# start
run() {
  local rc=0 out
  out=$("$@" </dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'status\trefused\nreason\t%s\n' "$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)"
    exit 1
  fi
}
case "$action" in
  restore) run bash "$ct" "$inst" --restore "$snap" ;;
  link)    run bash "$lobby" link "$name" --hours "$((10#$hours))" ;;
  revoke)  run bash "$lobby" link revoke "$name" ;;
  add)     run bash "$lobby" add "$name" "$ainst" "$((10#$aport))" ${agame:+"$agame"} ;;
  remove)  run bash "$lobby" remove "$name" ;;
esac
printf 'status\tdone\n'
