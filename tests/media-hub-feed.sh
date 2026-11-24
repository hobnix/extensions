#!/usr/bin/env bash
# media-hub feeder (hobnix/core#928, second slice): the manifest and the storage suggestion (a plan and a start only through the change rows, never
# alone). No root, python3 only. The adapters, the poller and the service (the keys, the rollup and emit messages) are
# a Rust program now: `cargo test --locked` in extensions/media-hub runs them (unit tests and tests/service.rs, which starts the real program against a
# local http server that serves tests/fixtures/media-hub). Every app answer there is a hand-made fixture: the adapters are UNVERIFIED against a real
# Jellyfin or Plex.
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

echo "-- manifest"
check "a [service] table that subscribes to nothing (posters draws the poster)" grep -q '^subscribe = \[\]' "$EXT/package.toml"
check "the permission list stays small (no net, no host)" bash -c "! grep -E '^permissions' '$EXT/package.toml' | grep -q 'net:\\|host:'"
check "the adapters say they are unverified" grep -q 'UNVERIFIED' "$EXT/src/adapter.rs"
check "the service is the Rust program of a [[binary]] table" bash -c "grep -q '^exec = \"@/bin/media-svc\"' '$EXT/package.toml' && grep -q '^path = \"bin/media-svc\"' '$EXT/package.toml'"
check "no committed program in a feature branch (the release preparation builds it)" test ! -e "$EXT/bin/media-svc"

echo "-- storage suggestion"
export HS_MEDIA_STATE_DIR=$(wp "$WORK/state")
mkdir -p "$WORK/state"
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
