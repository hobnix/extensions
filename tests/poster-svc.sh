#!/usr/bin/env bash
# poster-svc.py: the posters service draws the poster of a media-hub `imported` event (hobnix/core#1129). No root, python3 only; the drawing is a stand-in.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
SVC=$HERE/extensions/posters/poster-svc.py
cat > "$WORK/draw-stub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
[ "$STUB_FAIL" != 1 ] || { printf 'status\trefused\nreason\tno such extension\n'; exit 1; }
printf 'status\tdone\n'
STUB
chmod +x "$WORK/draw-stub.sh"
export STUB_LOG=$WORK/draw.log
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
ev() { printf '{"v":1,"type":"event","id":%s,"time":1,"source":"pkg","kind":"%s","subject":"radarr","level":"info","payload":%s}\n' "$1" "$2" "$3"; }

echo "-- manifest"
check "the service subscribes to the imported event of media-hub" grep -q '^subscribe = \["pkg.media-hub.imported"\]' "$HERE/extensions/posters/package.toml"
check "the service never calls hs" bash -c "! grep -v '^ *#' '$SVC' | grep -q '\"hs\"'"

for fail in 0 1; do
  echo "-- imported event, drawing fails=$fail"
  rm -f "$STUB_LOG"
  out=$({
    echo '{"v":1,"type":"init","name":"posters","lang":"en","subscribe":["pkg.media-hub.imported"],"health_interval":30}'
    ev 1 media-hub.imported '{"title":"A Film","app":"radarr"}'
    ev 2 media-hub.imported '{"app":"radarr"}'
    ev 3 media-hub.upgraded '{"title":"Other"}'
    echo '{"v":1,"type":"shutdown","grace_ms":1000}'
  } | HS_POSTER_CHANGE="$(wp "$WORK/draw-stub.sh")" STUB_FAIL=$fail timeout 30 python3 "$SVC")
  check "ready comes first" grep -q '"type": "ready"' <<<"$out"
  for id in 1 2 3; do check "event $id is acknowledged" grep -q "\"type\": \"ack\", \"id\": $id" <<<"$out"; done
  check_eq "one drawing only (no title, other kind: nothing)" 1 "$(wc -l < "$STUB_LOG" | tr -d ' ')"
  check "the arguments" grep -q '^start generate --eyebrow New in the library --title A Film --seed [0-9]*$' "$STUB_LOG"
  if [ "$fail" = 1 ]; then want="poster not drawn: no such extension"; else want="poster drawn for A Film"; fi
  check "the log line: $want" grep -q "$want" <<<"$out"
done
finish
