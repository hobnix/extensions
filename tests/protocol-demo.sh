#!/usr/bin/env bash
# `hs ext protocol-demo`: the demo of the command protocol v1 run by the core's dispatcher (hs.sh -> ext_proto.py). No root.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
[ -f "$CORE/scripts/lib/ext_proto.py" ] && grep -q dispatch "$CORE/scripts/lib/ext_proto.py" || { echo "the core has no protocol dispatcher yet" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_PACKAGES_DIR=$HERE/extensions HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_STATE_DIR=$WORK/state HS_CAPABILITIES_FILE=$WORK/caps HS_MACHINE_FILE=$WORK/machine.toml
mkdir -p "$HS_STATE_DIR"; echo protocol-demo > "$HS_CAPABILITIES_FILE"; echo 'hostName = "t"' > "$HS_MACHINE_FILE"
HS="bash $CORE/scripts/lib/hs.sh"
tab=$'\t'

check_eq "hello prints the extension's text" "Hello, Anna!" "$($HS ext protocol-demo hello Anna 2>/dev/null)"
check_eq "the language arrives" "Hallo, world!" "$(HS_LANG=de $HS ext protocol-demo hello 2>/dev/null)"
check_eq "the machine-readable list is TSV with - for an empty cell" "alpha${tab}1${tab}first
beta${tab}22${tab}-
gamma${tab}333${tab}-" "$($HS sys ext protocol-demo list)"
rc=0; $HS sys ext protocol-demo slow >/dev/null 2>&1 || rc=$?
check_eq "the row's timeout stops the extension (exit 124)" 124 "$rc"
finish
