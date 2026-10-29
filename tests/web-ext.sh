#!/usr/bin/env bash
# The web interface of the core with the packages of this repository (tests/web-ext-test.py). No root.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
if o=$(HS_CORE="$CORE" python3 -I "$HERE/tests/web-ext-test.py" 2>&1); then pass "web tests ($(grep -E '^Ran ' <<<"$o"))"; else fail "web tests: $(tail -n 25 <<<"$o")"; fi
if o=$(HS_CORE="$CORE" python3 -I "$HERE/tests/web-poster-test.py" 2>&1); then pass "poster API tests ($(grep -E '^Ran ' <<<"$o"))"; else fail "poster API: $(tail -n 25 <<<"$o")"; fi
finish
