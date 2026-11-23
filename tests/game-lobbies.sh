#!/usr/bin/env bash
# `hs ext game-lobbies` (lobby.sh, lobby-change.sh) with a stand-in for incus and for manage-ct.sh. No root, no incus.
# The core checkout (CI puts it in ./core; HS_CORE names another).
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "jq is missing" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
export HS_PACKAGES_DIR=$HERE/extensions
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_STATE_DIR=$WORK/state
mkdir -p "$HS_STATE_DIR"
PK=$HERE/extensions/game-lobbies
L="bash $PK/lobby.sh"
C="bash $PK/lobby-change.sh"

# stand-in for incus: instance "mc" runs and has three snapshots, "idle" is stopped, anything else does not exist
cat > "$WORK/incus" <<'F'
#!/usr/bin/env bash
case "$1 $2" in
  "query /1.0/instances/mc")   echo '{"status":"Running"}' ;;
  "query /1.0/instances/idle") echo '{"status":"Stopped"}' ;;
  "query /1.0/instances/mc/snapshots?recursion=1")
    echo '[{"name":"mc/a","created_at":"2026-11-01T10:00:00Z"},{"name":"mc/b","created_at":"2026-11-02T10:00:00Z"},{"name":"mc/c","created_at":"2026-11-03T10:00:00Z"}]' ;;
  "query /1.0/instances/idle/snapshots?recursion=1") echo '[]' ;;
  "exec mc") printf '%s\n' c1 c2 ;;
  "start idle") echo "$2" >> "$INC_LOG" ;;
  *) exit 1 ;;
esac
F
chmod +x "$WORK/incus"
cat > "$WORK/ct" <<'F'
#!/usr/bin/env bash
echo "$*" >> "$CT_LOG"
F
export HS_INCUS=$WORK/incus INC_LOG=$WORK/inc.log HS_CT=$WORK/ct CT_LOG=$WORK/ct.log

check "scripts parse" bash -c "bash -n $PK/lobby.sh && bash -n $PK/lobby-change.sh"

echo "-- lobby.sh"
check_out "empty list says how to add" "game-lobbies add" $L list
check_out "add" "Saved 'minecraft'" $L add minecraft mc 25565 Minecraft
$L add quiet idle 7777 >/dev/null
check_eq "--list rows" "$(printf 'minecraft\tmc\t25565\tMinecraft\nquiet\tidle\t7777\t-')" "$($L --list)"
check "bad port refused" bash -c "! $L add x mc 70000 2>/dev/null"
check "reserved name refused" bash -c "! $L add list mc 1 2>/dev/null"
check_eq "--state counts players of the running one" "$(printf 'minecraft\tmc\trunning\t2\t25565\nquiet\tidle\tstopped\t-\t7777')" "$($L --state)"
check_eq "--summary for the card" "$(printf 'ok\t2 players in 1 of 2 lobbies')" "$($L --summary)"
check_eq "--checks: running is ok, stopped is info" "$(printf 'ok	Lobby minecraft is running (2 players)
info	Lobby quiet is stopped')" "$($L --checks)"
$L add gone nope 1234 >/dev/null
check_eq "--checks: a missing instance is warn" "warn	Lobby gone: the instance nope does not exist" "$($L --checks | grep '^warn')"
$L remove gone >/dev/null
check_eq "--checks is empty without lobbies" "" "$(HS_STATE_DIR=$WORK/none $L --checks)"
check_eq "--worlds newest first" "$(printf 'minecraft\tc\t2026-11-03 10:00\nminecraft\tb\t2026-11-02 10:00\nminecraft\ta\t2026-11-01 10:00')" "$($L --worlds)"

echo "-- wake link"
export HS_NOW=1000000
out=$($L link quiet --hours 2)
check_out "link made" "valid until" echo "$out"
tok=$(sed -n 's/^ *token *//p' <<<"$out" | tr -d ' ')
check "token is 32 hex" bash -c "[[ '$tok' =~ ^[0-9a-f]{32}\$ ]]"
check "links file is private" bash -c "[ \"\$(stat -c %a $HS_STATE_DIR/game-lobbies/links)\" = 600 ]"
check "the token is not stored in plain text" bash -c "! grep -rq '$tok' $HS_STATE_DIR"
check_eq "the stored value is the sha256 of the token" "$(printf '%s' "$tok" | sha256sum | cut -d' ' -f1)" "$(cut -f3 "$HS_STATE_DIR/game-lobbies/links")"
check "--links shows no token and no hash" bash -c "! $L --links | grep -q '$tok'"
check_out "link listed active" "quiet.*active" bash -c "$L --links | tr '\t' ' '"
check "the hash itself is not a token" bash -c "! printf '%s\n' \"\$(cut -f3 $HS_STATE_DIR/game-lobbies/links)\" | $L redeem 2>/dev/null"
check_out "redeem starts the instance" "starting" bash -c "printf '%s\n' $tok | $L redeem"
check_eq "the instance was started" "idle" "$(sort -u "$INC_LOG")"
check_out "the same link works again before it expires (not single-use)" "already running|starting" bash -c "printf '%s\n' $tok | $L redeem"
check_out "a wrong token says not valid" "not valid" bash -c "printf '%s\n' ffffffffffffffffffffffffffffffff | $L redeem 2>&1 || true"
check "unknown token refused" bash -c "! printf '%s\n' 00000000000000000000000000000000 | $L redeem 2>/dev/null"
check "garbage token refused" bash -c "! printf '%s\n' 'x y' | $L redeem 2>/dev/null"
HS_NOW=$((1000000 + 3 * 3600)); export HS_NOW
check "expired link refused" bash -c "! printf '%s\n' $tok | $L redeem 2>/dev/null"
check_out "an expired token says expired" "expired" bash -c "printf '%s\n' $tok | $L redeem 2>&1 || true"
check_out "expired link shows expired" "expired" bash -c "$L --links"
check "hours out of range refused" bash -c "! $L link quiet --hours 9999 2>/dev/null"
id=$($L --links | cut -f1)
check_out "revoke" "Revoked" $L link revoke "$id"
check_eq "no link left" "" "$($L --links)"

echo "-- manifest"
check_out "health check and gated tab are declared" "health.*lobbies" bash -c "grep -A3 '^\[\[health' $PK/capability.toml | tr '\n' ' '"
check "health read is declared in commands.tsv" grep -q 'sys ext game-lobbies checks' $PK/commands.tsv

echo "-- lobby-change.sh"
check_out "restore plan names the newer snapshots" "warn.*b c" bash -c "$C plan minecraft restore a | tr '\t' ' '"
check_out "restore plan is long" "long.yes" bash -c "$C plan minecraft restore a | tr '\t' ' '"
check "unknown snapshot refused" bash -c "! $C plan minecraft restore nope >/dev/null"
check "unknown lobby refused" bash -c "! $C plan ghost restore a >/dev/null"
check "hostile snapshot name refused" bash -c "! $C plan minecraft restore '../x' >/dev/null"
check_out "restore start answers done" "status.done" bash -c "$C start minecraft restore c | tr '\t' ' '"
check_eq "manage-ct got the restore" "mc --restore c" "$(cat "$CT_LOG")"
check_out "add without port needs" "needs.port" bash -c "$C plan fresh add --instance idle | tr '\t' ' '"
check_out "add start" "status.done" bash -c "$C start fresh add --instance idle --port 9000 --game Valheim | tr '\t' ' '"
check_out "added lobby is listed" "fresh +idle +9000 +Valheim" bash -c "$L --list | tr '\t' ' '"
check_out "link start" "status.done" bash -c "$C start fresh link --hours 1 | tr '\t' ' '"
check_out "remove start" "status.done" bash -c "$C start fresh remove | tr '\t' ' '"
check_eq "removed lobby has no link left" "" "$($L --links | grep fresh || true)"
finish
