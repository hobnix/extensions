#!/usr/bin/env bash
# The extensions of this repository (games, posters, passthrough) as the command loader of the core sees them: their rows, the old words, nothing refused.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/extensions
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_STATE_DIR=$WORK/state HS_CAPABILITIES_FILE=$WORK/caps HS_MACHINE_FILE=$WORK/machine.toml
export HS_COMPLETE_DIR=$WORK/complete HS_SETTINGS_DIR=$WORK/settings
mkdir -p "$HS_STATE_DIR"
: > "$HS_CAPABILITIES_FILE"
printf 'hostName = "t"\n' > "$HS_MACHINE_FILE"
tab=$'\t'
HS="bash $SCRIPTS/lib/hs.sh"
export HS_PACKAGES_DIR=$PKGS   # the core finds the extensions here (it has none of its own)
. "$SCRIPTS/lib/registry-load.sh"


echo "-- the real packages (games, posters), their old words, the web declarations"
check_eq "games and posters are packages" "yes" "$(ext_package_names | paste -sd' ' | grep -q 'games' && ext_package_names | grep -qx posters && echo yes)"
check_eq "both are off by default" "0" "$($HS help --all | grep -cE 'ext (games|posters)')"
printf 'games
posters
gateway
passthrough
' > "$HS_CAPABILITIES_FILE"
for w in "ext passthrough list" "ext passthrough status" "ext passthrough add" "ext passthrough remove" "ext passthrough refresh" "sys ext passthrough state" "sys ext passthrough plan <domain> <action>" "sys ext passthrough start <domain> <action>"; do
  check_out "row: $w" "${tab}$w${tab}" registry_rows
done
for w in "ext games list" "ext games add" "ext games remove" "ext games wake" "ext posters generate" "sys ext games list" "sys ext games state" "sys ext games plan <name> <action>" "sys ext games start <name> <action>" \
         "sys ext posters generate" "sys ext posters list" "sys ext posters plan <action>" "sys ext posters start <action>"; do
  check_out "row: $w" "${tab}$w${tab}" registry_rows
done
check_eq "no row of the real packages is refused" "" "$(registry_refused | paste -sd, -)"
check_eq "hs ext games list runs pc.sh" "yes" "$($HS ext games list 2>&1 | grep -q 'No PC saved yet' && echo yes)"
check_eq "hs sys ext games list is plain and empty without a PC" "" "$($HS sys ext games list)"
$HS ext games add gaming AA:BB:CC:DD:EE:FF 10.10.95.30 >/dev/null 2>&1
check_eq "hs sys ext games list prints the row" "$(printf 'gaming\taa:bb:cc:dd:ee:ff\t10.10.95.30')" "$($HS sys ext games list)"
err=$($HS pc list 2>&1 >/dev/null)
check_out "the old word says where it went" "'hs pc list' has moved to the extension games: hs ext games list" echo "$err"
check_eq "and still runs while the package is on" "$(printf 'gaming\taa:bb:cc:dd:ee:ff\t10.10.95.30')" "$($HS sys ext games list)"
check_eq "the old word is not in hs help" "0" "$($HS help --all | grep -cE '^  (pc |generate poster)')"
: > "$HS_CAPABILITIES_FILE"
check_eq "passthrough rows vanish while it is off" "0" "$($HS help --all | grep -c 'ext passthrough')"
out=$($HS pc list 2>&1; echo "rc=$?")
check_out "off: the old word names the new form and the switch" "hs ext enable games" echo "$out"
check_out "and exits 1" "rc=1" echo "$out"
out=$($HS generate poster 2>&1; echo "rc=$?")
check_out "the old poster word moved too" "has moved to the extension posters: hs ext posters generate" echo "$out"

finish
