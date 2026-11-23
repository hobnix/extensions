#!/usr/bin/env bash
# media-hub: the apps through the integration media, the monthly rollup, the stats rows, and five years of rollups under 50 KB. No root, python3 only.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/extensions
M=$PKGS/media-hub/media-hub.sh
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
export HS_LANG=en HS_PLAIN=1 HS_CALLER=ui HS_EVENT_NOROOT=1
mkdir -p "$WORK/state"
export HS_STATE_DIR=$(wp "$WORK/state") HS_STATE_DB=$(wp "$WORK/state/state.db") HS_PKG_EVENTS_DIR=$(wp "$WORK/pe")
mkdir -p "$WORK/pe"
tab=$'\t'

echo "-- manifest"
check "permission integration:media" grep -q '"integration:media"' "$PKGS/media-hub/package.toml"
check "the three retention classes are declared" bash -c "grep -q 'retention = \"ephemeral\"' '$PKGS/media-hub/package.toml' && grep -q 'retention = \"audit\"' '$PKGS/media-hub/package.toml' && grep -q 'retention = \"metric\"' '$PKGS/media-hub/package.toml'"
check "row: sys ext media-hub stats" grep -q "^sys${tab}sys ext media-hub stats${tab}" "$PKGS/media-hub/commands.tsv"

echo "-- apps"
printf 'radarr\tmedia\trecipe\thttp://10.0.0.5:7878\tok\tkind=movies\n' > "$WORK/int"
printf 'jellyfin\tmedia\trecipe\thttp://10.0.0.6:8096\tmissing\t-\n' >> "$WORK/int"
export HS_MEDIA_INTEGRATIONS=$(wp "$WORK/int")
l=$(bash "$M" --apps | tr -d '\r')
check_eq "radarr row (kind from the extra keys)" "$(printf 'radarr\thttp://10.0.0.5:7878\tok\tmovies')" "$(sed -n 1p <<<"$l")"
check_eq "jellyfin row (no kind is a dash)" "$(printf 'jellyfin\thttp://10.0.0.6:8096\tmissing\t-')" "$(sed -n 2p <<<"$l")"
check_out "the people's list" "radarr" bash "$M" apps

echo "-- nothing recorded"
check_eq "no months" "" "$(bash "$M" --months | tr -d '\r')"
check_eq "stats with two apps" "$(printf '0\t0\t0\t0\t2')" "$(bash "$M" --stats | tr -d '\r')"

echo "-- record"
export HS_MEDIA_MONTH=$(date -u +%Y-%m)   # record-session counts into the month of now
bash "$M" record-session anna 90 "Film" >/dev/null
bash "$M" record-session anna 30 >/dev/null
bash "$M" record-session ben 45 >/dev/null
check_eq "a month adds up (3 plays, 165 minutes)" "$(printf '3\t165\t3\t165\t2')" "$(bash "$M" --stats | tr -d '\r')"
bash "$CORE/scripts/state.sh" rollup-add pkg.media-hub.session-completed carl --n 1 --sum 20 >/dev/null   # what the Rust service writes through the protocol
check_eq "the service's rollup kind is added to the count (4 plays, 185 minutes)" "$(printf '4	185	4	185	2')" "$(bash "$M" --stats | tr -d '')"
check "a bad user is refused" bash -c "! bash '$M' record-session 'a b' 5"
check "zero minutes are refused" bash -c "! bash '$M' record-session anna 0"
check "more than a day is refused" bash -c "! bash '$M' record-session anna 1441"
check "an unknown import word is refused" bash -c "! bash '$M' record-import deleted X"
check "an import is noted" bash "$M" record-import imported "A Film" radarr

echo "-- five years"
rm -f "$HS_STATE_DB"
out=$(python3 -I -c '
import importlib.util, os, sys
s = importlib.util.spec_from_file_location("sd", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
c = m.open_rw()
t0 = 1577836800                                    # 2020-01-01 UTC
for d in range(5 * 365):
    with c:
        for u in ("anna", "ben", "carl", "dora", "emil"):
            for i in range(4):                     # four sessions a day and user, the way record-session counts them
                m.rollup_add(c, t0 + d * 86400 + i * 3600, u, "media-watch", 1, 45)
n = c.execute("SELECT count(*) FROM rollups WHERE kind=\"media-watch\"").fetchone()[0]
c.commit()
r = sys.argv[2]
c.execute("ATTACH ? AS r", (r,)); c.execute("CREATE TABLE r.rollups AS SELECT * FROM main.rollups"); c.commit()
c.execute("DETACH r")
print(n, os.path.getsize(r) < 50000, os.path.getsize(r))
' "$CORE/scripts/state-db.py" "$(wp "$WORK/rollups.db")" | tr -d '\r')
check_eq "60 months x 5 users = 300 rows" "300" "${out%% *}"
check_eq "the rollup table alone is under 50 KB" "True" "$(cut -d' ' -f2 <<<"$out")"
finish
