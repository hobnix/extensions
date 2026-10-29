#!/usr/bin/env bash
# hs sys ext games list|state: the machine-readable rows the web interface reads (pc.sh --list, --state). No root needed.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/extensions
export HS_LANG=en HS_PLAIN=1 HS_CALLER=ui HS_STATE_DIR=$WORK/state
mkdir -p "$HS_STATE_DIR"
tab=$'\t'

echo "-- command rows"
check "sys ext games list row (the package games)" grep -q "^sys.sys ext games list.@/pc.sh.--list." "$PKGS/games/commands.tsv"
check "row: sys ext games state (the package games)" grep -q "^sys${tab}sys ext games state${tab}" "$PKGS/games/commands.tsv"

echo "-- pc --list"
check_eq "no PC, no rows" "" "$(bash "$PKGS/games/pc.sh" --list)"
bash "$PKGS/games/pc.sh" add gaming AA:BB:CC:DD:EE:FF 10.10.95.30 >/dev/null
bash "$PKGS/games/pc.sh" add laptop 11-22-33-44-55-66 >/dev/null
l=$(bash "$PKGS/games/pc.sh" --list)
check_eq "name, mac, address" "$(printf 'gaming\taa:bb:cc:dd:ee:ff\t10.10.95.30')" "$(sed -n 1p <<<"$l")"
check_eq "no address is a dash" "$(printf 'laptop\t11:22:33:44:55:66\t-')" "$(sed -n 2p <<<"$l")"
check_eq "two rows, no header" 2 "$(wc -l <<<"$l" | tr -d ' ')"
check_out "the people's list is unchanged" "Address" bash "$PKGS/games/pc.sh" list


echo "-- pc --state"
export HS_STATE_DIR=$WORK/state2; mkdir -p "$HS_STATE_DIR"
check_eq "no PC, no rows" "" "$(bash "$PKGS/games/pc.sh" --state)"
printf 'gaming\taa:bb:cc:dd:ee:ff\t10.10.10.50\nlaptop\t11:22:33:44:55:66\t\nsleeper\t11:22:33:44:55:77\t10.10.10.51\n' > "$HS_STATE_DIR/pcs"
printf '#!/usr/bin/env bash\n[ "$1" = 10.10.10.50 ] && [ "$2" = 47989 ]\n' > "$WORK/probe"; chmod +x "$WORK/probe"
out=$(HS_PC_PROBE=$WORK/probe bash "$PKGS/games/pc.sh" --state)
check_eq "up when the probe answers" "gaming${tab}10.10.10.50${tab}up" "$(sed -n 1p <<<"$out")"
check_eq "unknown without an address" "laptop${tab}-${tab}unknown" "$(sed -n 2p <<<"$out")"
check_eq "down when it does not" "sleeper${tab}10.10.10.51${tab}down" "$(sed -n 3p <<<"$out")"

finish
