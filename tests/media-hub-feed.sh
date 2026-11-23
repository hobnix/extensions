#!/usr/bin/env bash
# media-hub feeder (hobnix/core#928, second slice): the adapters and the poller against fixtures, the service against the core's reference supervisor
# (poster on an imported event), and the storage suggestion (a plan and a start only through the change rows, never alone). No root, python3 only.
# Every app answer here is a hand-made fixture: the adapters are UNVERIFIED against a real Jellyfin or Plex.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
EXT=$HERE/extensions/media-hub
FIX=$HERE/tests/fixtures/media-hub
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
export HS_LANG=en HS_PLAIN=1
tab=$'\t'

echo "-- adapters and poller (fixtures)"
mkdir -p "$WORK/poll"
res=$(python3 -I "$HERE/tests/media-hub-poll.py" "$(wp "$EXT")" "$(wp "$FIX")" "$(wp "$WORK/poll")" | tr -d '\r')
while IFS= read -r l; do
  case "$l" in ok\ *) pass "${l#ok }" ;; *) fail "$l" ;; esac
done <<<"$res"

echo "-- manifest"
check "a [service] table with the imported event" grep -q '^subscribe = \["pkg.media-hub.imported"\]' "$EXT/package.toml"
check "the permission list stays small (no net, no host)" bash -c "! grep -E '^permissions' '$EXT/package.toml' | grep -q 'net:\\|host:'"
check "the adapters say they are unverified" bash -c "grep -q 'UNVERIFIED' '$EXT/adapter_jellyfin.py' && grep -q 'UNVERIFIED' '$EXT/adapter_plex.py'"

echo "-- service: an imported event draws a poster"
export HS_MEDIA_STATE_DIR=$(wp "$WORK/state") HS_MEDIA_POLL_SECONDS=0
mkdir -p "$WORK/state"
cat > "$WORK/poster-stub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HS_STUB_LOG"
[ "${STUB_FAIL:-}" != 1 ] || { printf 'status\trefused\nreason\tno such extension\n'; exit 1; }
printf 'status\tdone\n'
STUB
chmod +x "$WORK/poster-stub.sh"
export HS_MEDIA_POSTER_CMD=$(wp "$WORK/poster-stub.sh") HS_STUB_LOG=$(wp "$WORK/poster.log")
EV=$WORK/events.jsonl
printf '{"id":1,"time":1700000000,"source":"pkg","kind":"media-hub.imported","subject":"radarr","level":"info","text":"t","payload":{"title":"A Film","app":"radarr"}}\n' > "$EV"
printf '{"id":2,"time":1700000001,"source":"pkg","kind":"media-hub.imported","subject":"radarr","level":"info","text":"t","payload":{"app":"radarr"}}\n' >> "$EV"
RUN="python3 -I $HS_SCRIPTS/lib/ext_service.py"
run_svc() { rc=0; out=$($RUN run --name media-hub --subscribe 'pkg.media-hub.imported' --events "$(wp "$EV")" --cursor "$(wp "$WORK/cur")" --run-for 3 --health-interval 1 --grace 1 -- python3 -I "$(wp "$EXT/media-svc.py")" 2>&1) || rc=$?; }
run_svc
check_eq "the supervisor stops it on request" 0 "$rc"
check_eq "one poster call (the event without a title draws nothing)" 1 "$(grep -c . "$WORK/poster.log")"
check "the call names the title and the posters command" grep -q -- "--eyebrow New in the library --title A Film --seed" "$WORK/poster.log"
check_eq "both events are acknowledged" 2 "$(cat "$WORK/cur")"
rm -f "$WORK/cur"; STUB_FAIL=1 run_svc
check_out "a failing poster is logged, not fatal" "poster not drawn: no such extension" printf '%s' "$out"
check_eq "and the event is still acknowledged" 2 "$(cat "$WORK/cur")"

echo "-- service: the poller reports why it does not poll"
printf 'radarr\tmedia\trecipe\thttp://10.0.0.5:7878\tok\tkind=movies\tX-Api-Key\njellyfin\tmedia\trecipe\thttp://10.0.0.6:8096\tok\t-\tX-Emby-Token\n' > "$WORK/int"
HS_MEDIA_INTEGRATIONS=$(wp "$WORK/int") HS_MEDIA_POLL_SECONDS=1 run_svc
check_out "radarr has no adapter, jellyfin is polled, said once in the log" "polling jellyfin .not polled: radarr has no adapter" printf '%s' "$out"

echo "-- storage suggestion"
S=$EXT/media-suggest.sh
export HS_MEDIA_NOW=2000000000
t_old=$((HS_MEDIA_NOW - 40 * 86400)); t_new=$((HS_MEDIA_NOW - 2 * 86400))
printf '%s\tOld Film.mkv\t/shares/media/movies\n%s\tNew Film.mkv\t/shares/media/movies\n' "$t_old" "$t_new" > "$WORK/state/watched.tsv"
cat > "$WORK/fm-stub.sh" <<'STUB'
#!/usr/bin/env bash
# a stand-in for fm.sh: locations, plan and start; every call is logged with its selection
case "$1" in
  locations) printf 'status\tok\nwrite\tyes\nloc\tpool:fast\tpool\tfast\tzfs\t1000\t100\tyes\t-\tfast\t-\tyes\nloc\tpool:bulk\tpool\tbulk\tzfs\t9000\t5000\tyes\t-\tbulk\t-\tyes\nloc\tshare:media\tshare\tmedia\tzfs\t9000\t5000\tyes\t-\t-\t-\tyes\n' ;;
  plan|start) printf '%s %s\n' "$1" "$*" >> "$HS_STUB_FM"; tr '\0' '|' < /dev/stdin >> "$HS_STUB_FM"; printf '\n' >> "$HS_STUB_FM"
    if [ "$1" = plan ]; then printf 'status\tok\nheading\tmove 1 file\nlong\tno\n'; else printf 'status\tdone\nunit\ths-fm-1\n'; fi ;;
esac
STUB
chmod +x "$WORK/fm-stub.sh"
export HS_MEDIA_FM=$(wp "$WORK/fm-stub.sh") HS_STUB_FM=$(wp "$WORK/fm.log")
out=$(bash "$S" list | tr -d '\r')
check_eq "only the old one is suggested, small pool to large pool" "$(printf 'Old Film.mkv\tpool:fast\tpool:bulk\t/shares/media/movies\t40')" "$out"
check_eq "a plan shows the file manager's plan and starts nothing" "plan" "$(bash "$S" plan move-watched "Old Film.mkv" pool:fast pool:bulk /shares/media/movies | tr -d '\r' | awk -F'\t' '$1=="status"{print "plan"}')"
check "the plan was asked with the name on stdin" grep -q 'Old Film.mkv|' "$WORK/fm.log"
check_eq "no start so far" 0 "$(grep -c '^start' "$WORK/fm.log")"
check "a name that was not watched is refused" bash -c "! bash '$S' plan move-watched 'Other.mkv' pool:fast pool:bulk /shares/media/movies"
check "a path with .. is refused" bash -c "! bash '$S' plan move-watched 'Old Film.mkv' pool:fast pool:bulk /shares/../etc"
check "a name with a slash is refused" bash -c "! bash '$S' start move-watched 'a/b' pool:fast pool:bulk /shares/media/movies"
check "the same place twice is refused" bash -c "! bash '$S' plan move-watched 'Old Film.mkv' pool:fast pool:fast /shares/media/movies"
check_eq "a start runs the job (status done)" "done" "$(bash "$S" start move-watched "Old Film.mkv" pool:fast pool:bulk /shares/media/movies | tr -d '\r' | awk -F'\t' '$1=="status"{print $2}')"
check_eq "a moved file is no suggestion any more" "" "$(bash "$S" list | tr -d '\r')"
check "the rows exist in commands.tsv" bash -c "grep -q \"^sys${tab}sys ext media-hub start <action>${tab}\" '$EXT/commands.tsv'"
check "the web may only plan and start move-watched" grep -q "'^move-watched\$'" "$EXT/capability.toml"
finish
