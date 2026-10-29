#!/usr/bin/env bash
# hs sys ext games plan|start <name> wake (capabilities/games/pc-change.sh): the Wake button of the web interface. A stand-in sends the "packet". No root.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/extensions
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
export HS_STATE_DIR=$WORK/state; mkdir -p "$HS_STATE_DIR"
printf 'gaming\taa:bb:cc:dd:ee:ff\t10.10.10.50\nlaptop\t11:22:33:44:55:66\t\n' > "$HS_STATE_DIR/pcs"
printf '#!/usr/bin/env bash\necho "$1" >> "%s/wol.log"\n' "$WORK" > "$WORK/wol-cmd"; chmod +x "$WORK/wol-cmd"
export HS_WOL_CMD=$WORK/wol-cmd
run() { rc=0; out=$(timeout 20 bash "$PKGS/games/pc-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- plan"
run plan gaming wake
check_eq "plan: exit 0" 0 "$rc"
has '^status	ok$' && has '^heading	wake gaming$' && has 'aa:bb:cc:dd:ee:ff' && has '^command	bash .*pc.sh wake gaming$' && has '^long	no$' && pass "plan names the PC, the MAC and the command" || fail "plan: $out"
has '^danger' && fail "wake is not red" || pass "wake is not red"
run plan laptop wake
has '10.10.10.50' && fail "address of another PC" || pass "no address note for a PC without one"
check_eq "plan sends nothing" "" "$(cat "$WORK/wol.log" 2>/dev/null)"
run plan nobody wake
check_eq "unknown PC: refused" 1 "$rc"
has "No PC called 'nobody'" && pass "says so" || fail "nobody: $out"
run plan 'bad name' wake
check_eq "bad name: refused" 1 "$rc"
run plan gaming sleep
check_eq "unknown action: refused" 1 "$rc"
run plan gaming wake --wait
check_eq "extra argument: refused" 1 "$rc"

echo "-- start"
run start gaming wake
check_eq "start: exit 0" 0 "$rc"
has '^status	done$' && pass "status done" || fail "start: $out"
check_eq "the packet went to the MAC" "aa:bb:cc:dd:ee:ff" "$(tail -n 1 "$WORK/wol.log" 2>/dev/null)"
run start nobody wake
check_eq "start for an unknown PC: refused" 1 "$rc"

echo "-- add"
run plan newpc add
check_eq "add without a MAC: needs (exit 2)" 2 "$rc"
has '^status	needs$' && has '^needs	mac$' && pass "says the MAC is needed" || fail "needs: $out"
run plan newpc add --mac AA-BB-CC-00-11-22 --ip 10.10.10.60
check_eq "add plan: exit 0" 0 "$rc"
has '^heading	save the game PC newpc$' && has 'aa:bb:cc:00:11:22 and the address 10.10.10.60' && has '^command	bash .*pc.sh add newpc aa:bb:cc:00:11:22 10.10.10.60$' && pass "plan names the MAC (lower case) and the address" || fail "add plan: $out"
has '^warn' && fail "a new name has no replace warning" || pass "no replace warning for a new name"
check_eq "plan saves nothing" 2 "$(wc -l < "$HS_STATE_DIR/pcs" | tr -d ' ')"
run plan newpc add --mac aa:bb:cc:00:11:22
has '^note	Without an address' && pass "no address: a note" || fail "no-ip note: $out"
run plan gaming add --mac 11:11:11:11:11:11
has '^warn	gaming is saved already' && pass "an existing name is flagged" || fail "replace warn: $out"
for bad in "--mac nonsense" "--mac aa:bb:cc:00:11:22 --ip 10.10.10" "--mac aa:bb:cc:00:11:22 --ip 10.10.10.300" "--mac aa:bb:cc:00:11:22 --ip a.b.c.d" "--mac aa:bb:cc:00:11:22 --x 1" "--mac"; do
  run plan newpc add $bad
  check_eq "refused: $bad" 1 "$rc"
done
run start newpc add --mac AA:BB:CC:00:11:22 --ip 10.10.10.60
check_eq "start add: exit 0" 0 "$rc"
check_eq "the PC is saved with the MAC in lower case" "$(printf 'newpc	aa:bb:cc:00:11:22	10.10.10.60')" "$(grep '^newpc' "$HS_STATE_DIR/pcs")"
run start newpc add --mac AA:BB:CC:00:11:22
check_eq "add replaces, not duplicates" 1 "$(grep -c '^newpc' "$HS_STATE_DIR/pcs" | tr -d ' ')"
run start newpc add
check_eq "start without a MAC: needs (nothing saved)" 2 "$rc"

echo "-- remove"
run plan newpc remove
check_eq "remove plan: exit 0" 0 "$rc"
has '^heading	forget the game PC newpc$' && has '^command	bash .*pc.sh remove newpc$' && pass "remove plan" || fail "remove plan: $out"
has '^danger' && fail "remove is not red" || pass "remove is not red"
run plan nobody remove
check_eq "remove an unknown PC: refused" 1 "$rc"
run plan newpc remove --mac x
check_eq "remove with extra arguments: refused" 1 "$rc"
run start newpc remove
check_eq "start remove: exit 0" 0 "$rc"
check_eq "it is gone" 0 "$(grep -c '^newpc' "$HS_STATE_DIR/pcs" | tr -d ' ')"
check_eq "the others stay" 2 "$(wc -l < "$HS_STATE_DIR/pcs" | tr -d ' ')"

finish
