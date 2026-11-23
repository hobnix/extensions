#!/usr/bin/env bash
# help: game lobbies on Incus instances: list, add, remove, wake links that expire
# help.de: Spiel-Lobbys auf Incus-Instanzen: anzeigen, hinzufügen, entfernen, Aufweck-Links mit Ablauf
# args: list | --list | --state | --summary | --checks | --worlds | --links | add <name> <instance> <port> [<game>] | remove <name> | link <name> [--hours N] | link list | link revoke <id> | redeem
# A lobby is a name for an Incus instance that runs a game server (name, instance, port, game) in /var/lib/hs/game-lobbies/lobbies. Wake links are
# lines of /var/lib/hs/game-lobbies/links (id, lobby, sha256 of the token as hex, expires as epoch, created as epoch; the file is 0600). The token itself is
# shown once when the link is made and never stored or logged.
# Machine-readable (hs sys ext game-lobbies ...), no header, nothing for no row, an empty field is -:
#   --list     name TAB instance TAB port TAB game
#   --state    name TAB instance TAB state (running|stopped|missing) TAB players TAB port; players = established TCP connections to the port counted
#              inside the instance (- when it is not running; a game that talks UDP only shows 0)
#   --summary  level TAB line for the card: off (no lobby), info (none running), ok (players and running lobbies)
#   --checks   level TAB message per lobby for the health check: ok (running), info (stopped: nobody is playing, not a problem), warn (its instance is gone)
#   --worlds   lobby TAB snapshot TAB created (YYYY-MM-DD HH:MM), newest first
#   --links    id TAB lobby TAB expires (YYYY-MM-DD HH:MM) TAB state (active|expired)
# redeem reads one token line from stdin (never an argument) and starts the instance of its lobby while the link has not expired.
# Test knobs: HS_STATE_DIR (the folder with game-lobbies/), HS_INCUS (stand-in for incus), HS_NOW (epoch seconds).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scripts=${HS_SCRIPTS:-$here/../../scripts}   # the core helpers; hs and hs-web set HS_SCRIPTS
. "$scripts/lib/ui.sh"
state=${HS_STATE_DIR:-/var/lib/hs}/game-lobbies
file=$state/lobbies
links=$state/links
inc=${HS_INCUS:-incus}
name_re='^[A-Za-z0-9][A-Za-z0-9._-]{0,40}$'
inst_re='^[A-Za-z0-9][A-Za-z0-9-]{0,62}$'

usage() {
  say "usage: hs ext game-lobbies list"
  say "       hs ext game-lobbies add <name> <instance> <port> [<game>]"
  say "       hs ext game-lobbies remove <name>"
  say "       hs ext game-lobbies link <name> [--hours N] | list | revoke <id>"
  exit 1
}
now() { printf '%s' "${HS_NOW:-$(date +%s)}"; }
fmt_time() { date -u -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' -; }
find_lobby() {   # find_lobby <name>: the line, empty when unknown
  [ -f "$file" ] || return 0
  awk -F'\t' -v n="$1" '$1 == n { print; exit }' "$file"
}
inst_state() {   # inst_state <instance>: running | stopped | missing
  local s
  s=$("$inc" query "/1.0/instances/$1" 2>/dev/null | jq -r '.status // empty') || s=""
  case "$s" in
    Running) echo running ;;
    "") echo missing ;;
    *) echo stopped ;;
  esac
}
players() {      # players <instance> <port>: established TCP connections to the port, counted inside the instance
  local n
  n=$(timeout 3 "$inc" exec "$1" -- ss -Htn state established "( sport = :$2 )" 2>/dev/null | wc -l) || n=0
  printf '%s' "${n//[[:space:]]/}"
}
rewrite() {      # rewrite <file> <awk-condition-on-$1 to keep>: drop the lines of one first field, keep the mode 0600
  local f=$1 key=$2
  [ -f "$f" ] || return 0
  awk -F'\t' -v k="$key" '$1 != k' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
}
rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

[ $# -ge 1 ] || usage
cmd=$1; shift
umask 077
case "$cmd" in
--list)
  [ ! -s "$file" ] || awk -F'\t' '{ printf "%s\t%s\t%s\t%s\n", $1, $2, $3, ($4 == "" ? "-" : $4) }' "$file" ;;

--state)
  [ -s "$file" ] || exit 0
  while IFS=$'\t' read -r n inst port _; do
    [ -n "$n" ] || continue
    st=$(inst_state "$inst"); p=-
    [ "$st" != running ] || p=$(players "$inst" "$port")
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$inst" "$st" "$p" "$port"
  done < "$file" ;;

--summary)
  total=0 run=0 pl=0
  while IFS=$'\t' read -r _ _ st p _; do
    total=$((total + 1))
    if [ "$st" = running ]; then run=$((run + 1)); pl=$((pl + ${p//-/0})); fi
  done < <(bash "$0" --state)
  if [ "$total" -eq 0 ]; then printf 'off\tNo lobby saved\n'
  elif [ "$run" -eq 0 ]; then printf 'info\tNo lobby is running (%s saved)\n' "$total"
  else printf 'ok\t%s players in %s of %s lobbies\n' "$pl" "$run" "$total"; fi ;;

--checks)
  [ -s "$file" ] || exit 0
  while IFS=$'	' read -r n inst st p _; do
    case "$st" in
      running) printf 'ok	Lobby %s is running (%s players)
' "$n" "${p//-/0}" ;;
      stopped) printf 'info	Lobby %s is stopped
' "$n" ;;
      *)       printf 'warn	Lobby %s: the instance %s does not exist
' "$n" "$inst" ;;
    esac
  done < <(bash "$0" --state) ;;

--worlds)
  [ -s "$file" ] || exit 0
  while IFS=$'\t' read -r n inst _; do
    [ -n "$n" ] || continue
    "$inc" query "/1.0/instances/$inst/snapshots?recursion=1" 2>/dev/null |
      jq -r --arg l "$n" 'sort_by(.created_at) | reverse | .[] | [$l, (.name | sub(".*/"; "")), (.created_at | .[0:16] | sub("T"; " "))] | @tsv' || true
  done < "$file" ;;

--links)
  [ -s "$links" ] || exit 0
  ts=$(now)
  while IFS=$'\t' read -r id lob _ exp _; do
    [ -n "$id" ] || continue
    st=active; [ "$exp" -gt "$ts" ] || st=expired
    printf '%s\t%s\t%s\t%s\n' "$id" "$lob" "$(fmt_time "$exp")" "$st"
  done < "$links" ;;

list)
  if [ ! -s "$file" ]; then note "No lobby saved yet."; next_step "hs ext game-lobbies add <name> <instance> <port> [<game>]"; exit 0; fi
  { thead 'Name' 'Instance' 'Port' 'Game'
    bash "$0" --list; } | table ;;

add)
  [ $# -ge 3 ] && [ $# -le 4 ] || usage
  name=$1; inst=$2; port=$3; game=${4:-}
  [[ "$name" =~ $name_re ]] || fail "$(t "'%s' is not a usable name (letters, digits, . _ -)" "$name")"
  case "$name" in list|revoke) fail "$(t "'%s' is a reserved word, pick another name" "$name")" ;; esac
  [[ "$inst" =~ $inst_re ]] || fail "$(t "'%s' is not an instance name" "$inst")"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$port))" -ge 1 ] && [ "$((10#$port))" -le 65535 ] || fail "$(t "'%s' is not a port (1-65535)" "$port")"
  [[ -z "$game" || "$game" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]{0,40}$ ]] || fail "$(t "'%s' is not a usable game name" "$game")"
  mkdir -p "$state"
  { { [ ! -f "$file" ] || awk -F'\t' -v n="$name" '$1 != n' "$file"; }; printf '%s\t%s\t%s\t%s\n' "$name" "$inst" "$((10#$port))" "$game"; } > "$file.tmp"
  mv "$file.tmp" "$file"
  ok "$(t "Saved '%s' (instance %s, port %s)" "$name" "$inst" "$((10#$port))")"
  next_step "hs ext game-lobbies link $name" ;;

remove)
  [ $# -eq 1 ] || usage
  [ -n "$(find_lobby "$1")" ] || fail_fix "$(t "No lobby called '%s'" "$1")" "hs ext game-lobbies list"
  rewrite "$file" "$1"
  if [ -f "$links" ]; then awk -F'\t' -v n="$1" '$2 != n' "$links" > "$links.tmp"; mv "$links.tmp" "$links"; fi
  ok "$(t "Removed '%s' and its wake links" "$1")" ;;

link)
  [ $# -ge 1 ] || usage
  case "$1" in
  list)
    if [ ! -s "$links" ]; then note "No wake link yet."; exit 0; fi
    { thead 'Id' 'Lobby' 'Expires' 'State'
      bash "$0" --links; } | table ;;
  revoke)
    [ $# -eq 2 ] && [[ "$2" =~ ^[0-9a-f]{8}$ ]] || usage
    grep -q "^$2	" "$links" 2>/dev/null || fail_fix "$(t "No wake link '%s'" "$2")" "hs ext game-lobbies link list"
    rewrite "$links" "$2"
    ok "$(t "Revoked wake link %s" "$2")" ;;
  *)
    name=$1; shift; hours=24
    while [ $# -gt 0 ]; do
      case "$1" in
        --hours) hours=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$(find_lobby "$name")" ] || fail_fix "$(t "No lobby called '%s'" "$name")" "hs ext game-lobbies list"
    [[ "$hours" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$hours))" -ge 1 ] && [ "$((10#$hours))" -le 720 ] || fail "$(t "--hours is 1 to 720 (30 days)" )"
    mkdir -p "$state"
    id=$(rand_hex 4); tok=$(rand_hex 16); ts=$(now)
    exp=$((ts + 10#$hours * 3600))
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$(printf '%s' "$tok" | sha256sum | cut -d' ' -f1)" "$exp" "$ts" >> "$links"
    ok "$(t "Wake link %s for '%s' made, valid until %s UTC" "$id" "$name" "$(fmt_time "$exp")")"
    kv "token" "$tok"
    note "The token is shown only now and cannot be shown again; whoever has it can start this lobby until it expires. Revoke it with: hs ext game-lobbies link revoke $id" ;;
  esac ;;

redeem)
  IFS= read -r tok || tok=""
  [[ "$tok" =~ ^[0-9a-f]{32}$ ]] || fail "This wake link is not valid."
  # only the sha256 of the token is stored; compared in constant time (hmac.compare_digest): exit 0 = match (prints the lobby), 3 = expired, 1 = none
  rc=0; lob=$(printf '%s\n' "$tok" | python3 -I -c '
import hashlib, hmac, sys
want = hashlib.sha256(sys.stdin.readline().strip().encode()).hexdigest()
now = int(sys.argv[2])
hit = None
try:
    rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1])]
except OSError:
    rows = []
for r in rows:
    if len(r) >= 4 and hmac.compare_digest(r[2], want):   # no early exit: every row is compared
        hit = r
if hit is None:
    sys.exit(1)
if int(hit[3]) <= now:
    sys.exit(3)
print(hit[1])
' "$links" "$(now)") || rc=$?
  [ "$rc" -ne 3 ] || fail "This wake link has expired."
  [ "$rc" -eq 0 ] || fail "This wake link is not valid."
  lline=$(find_lobby "$lob")
  [ -n "$lline" ] || fail "This wake link is not valid."
  IFS=$'\t' read -r _ inst _ <<<"$lline"
  case "$(inst_state "$inst")" in
    running) ok "$(t "'%s' is already running" "$lob")" ;;
    missing) fail "$(t "The instance of '%s' does not exist" "$lob")" ;;
    *) "$inc" start "$inst" >/dev/null 2>&1 || fail "$(t "'%s' could not be started" "$lob")"
       ok "$(t "'%s' is starting" "$lob")" ;;
  esac ;;

*) usage ;;
esac
