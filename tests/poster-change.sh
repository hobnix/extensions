#!/usr/bin/env bash
# hs sys ext posters list|plan|start (poster-change.sh): draw, list and delete the posters. The web API test stays in the core.
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
T=$'\t'
export HS_POSTER_DIR=$WORK/posters
cat > "$WORK/gen-stub.sh" <<'STUB'
#!/usr/bin/env bash
# a stand-in for generate-poster.sh: writes the picture into --out and reports like the real one
out=""; seed=7; color=teal; title=x
while [ $# -gt 0 ]; do case "$1" in --out) out=$2; shift 2 ;; --seed) seed=$2; shift 2 ;; --color) color=$2; shift 2 ;; --title) title=$2; shift 2 ;; *) shift ;; esac; done
f=$out/poster-$(printf '%s' "$title" | tr 'A-Z ' 'a-z-')-$seed.png
printf 'PNG-stand-in' > "$f"
printf 'status\tok\nfile\t%s\ncolor\t%s\nseed\t%s\nsize\t1600x900\n' "$f" "$color" "$seed"
STUB
export HS_POSTER_GEN=$WORK/gen-stub.sh
run() { rc=0; out=$(timeout 60 bash "$PKGS/posters/poster-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- plan"
run plan generate --eyebrow "Movie night" --title "Dune"; check_eq "plan: exit 0" 0 "$rc"
has "Movie night" && pass "names the texts" || fail "$out"
run plan generate --eyebrow "x";                          check_eq "a title is needed" 1 "$rc"
long=$(printf 'x%.0s' $(seq 1 81))
run plan generate --eyebrow "$long" --title t;            check_eq "81 characters is too long" 1 "$rc"
run plan generate --eyebrow a --title b --color "not a colour"; check_eq "a bad colour is refused" 1 "$rc"
run plan generate --eyebrow a --title b --color '#12ab9f'; check_eq "a hex colour is fine" 0 "$rc"
run plan generate --eyebrow a --title b --seed 12x;       check_eq "a bad seed is refused" 1 "$rc"
run plan generate --eyebrow a --title b --case shout;     check_eq "a bad case is refused" 1 "$rc"
run plan generate --eyebrow a --title b --bogus;          check_eq "an unknown option is refused" 1 "$rc"

echo "-- start and list"
run start generate --eyebrow "Movie night" --title "Dune" --seed 42 --color teal; check_eq "start: exit 0" 0 "$rc"
has "^status${T}done" && pass "done" || fail "$out"
has "^file${T}poster-dune-42.png$" && pass "the file name only, no path" || fail "$out"
has "^seed${T}42" && has "^color${T}teal" && pass "seed and colour are reported" || fail "$out"
check "the picture is in the folder" test -s "$HS_POSTER_DIR/poster-dune-42.png"
run list; has "^poster-dune-42.png${T}12${T}[0-9]" && pass "the list names it with its size" || fail "$out"
echo x > "$HS_POSTER_DIR/notes.txt"; run list; check_eq "only posters are listed" 1 "$(grep -c . <<<"$out")"

echo "-- delete"
run plan delete poster-dune-42.png; check_eq "delete plan: exit 0" 0 "$rc"
run plan delete ../x.png;           check_eq "a path is refused" 1 "$rc"
run plan delete poster-nothere.png; check_eq "a missing file is refused" 1 "$rc"
run start delete poster-dune-42.png; check_eq "delete start: exit 0" 0 "$rc"
check "it is gone" test ! -e "$HS_POSTER_DIR/poster-dune-42.png"

echo "-- the real drawing (Pillow)"
if python3 -c "import PIL" 2>/dev/null; then
  export HS_POSTER_GEN=$PKGS/posters/generate-poster.sh
  run start generate --eyebrow "Test" --title "Real" --seed 5
  check_eq "drawn: exit 0" 0 "$rc"
  has "^file${T}poster-real-5.png$" && pass "the real file name" || fail "$out"
  check "a PNG was written" test "$(head -c 4 "$HS_POSTER_DIR/poster-real-5.png" | tail -c 3)" = PNG
else
  skip "Pillow is not installed"
fi
finish
