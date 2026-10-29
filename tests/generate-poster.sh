#!/usr/bin/env bash
# hs ext posters generate: the system command (capabilities/posters/generate-poster.sh over poster.py) and the guided front
# (generate-poster-guided.sh). Drawing needs python3 with Pillow; the guided dialogue runs against a stand-in.
# No root, no network.
# The core checkout (CI puts it in ./core; HS_CORE names another). The packages under test are the ones of THIS repository.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
export HS_SCRIPTS=$CORE/scripts
PKGS=$HERE/extensions
export HS_PACKAGES_DIR=$PKGS   # the core finds the extensions here (it has none of its own)
export HS_LANG=en HS_PLAIN=1
S=$SCRIPTS
REG=$PKGS/posters/commands.tsv      # the commands of the extension package "posters"
CORE=$S/lib/registry.tsv

echo "-- rows and syntax"
check "generate-poster.sh parses" bash -n "$PKGS/posters/generate-poster.sh"
check "generate-poster-guided.sh parses" bash -n "$PKGS/posters/generate-poster-guided.sh"
check_eq "the system row" "@/generate-poster.sh" "$(awk -F'\t' '$2 == "sys ext posters generate" { print $3 }' "$REG")"
check_eq "the user row is guided" "guided,topic:system,changes" "$(awk -F'\t' '$2 == "ext posters generate" { print $7 }' "$REG")"
check_eq "the old words are a hidden legacy row of the core" "guided,topic:system,changes,legacy:ext posters generate,nohelp" "$(awk -F'\t' '$2 == "generate poster" { print $7 }' "$CORE")"

have python3 || { skip "python3 is needed"; finish; exit 0; }
PYT=python3
$PYT -c 'import PIL' 2>/dev/null && PIL=true || PIL=false
D=$WORK/out; mkdir -p "$D"; cd "$D"
GEN="bash $PKGS/posters/generate-poster.sh"

echo "-- refusals (no Pillow needed)"
check_out "the eyebrow is required" "status.refused|reason.*eyebrow" $GEN --title Filme
check_out "the title is required" "reason.*title" $GEN --eyebrow Bibliothek
check_eq "a refusal exits 1" 1 "$($GEN --title x >/dev/null; echo $?)"
check_out "a bad colour is named" "reason.*colour 'pink2'" $GEN --eyebrow a --title b --color pink2
check_out "a bad seed is refused" "reason.*seed" $GEN --eyebrow a --title b --seed abc
check_out "a bad size is refused" "reason.*size" $GEN --eyebrow a --title b --size 10x10
check_out "the colours are listed" "^red$" $GEN --list-colors
check_out "an unknown option is refused" "unknown or incomplete option" $GEN --nope

if ! $PIL; then skip "Pillow is needed to draw"; else
echo "-- drawing"
out=$($GEN --eyebrow Bibliothek --title Filme --color red --seed 5 --size 768x432)
check_out "status ok" "^status.ok" echo "$out"
check_out "the file is named after the title and the seed" "poster-filme-5.png" echo "$out"
check "the file exists" test -s poster-filme-5.png
check_eq "its size" "768 432" "$($PYT -c 'from PIL import Image; print(*Image.open("poster-filme-5.png").size)')"
check_out "the colour and seed are reported" "^seed.5" echo "$out"
check_out "an existing file is kept" "exists already" $GEN --eyebrow Bibliothek --title Filme --color red --seed 5 --size 768x432
check "--force replaces it" $GEN --eyebrow Bibliothek --title Filme --color red --seed 5 --size 768x432 --force
$GEN --eyebrow B --title Same --color blue --seed 9 --size 768x432 --out a.png >/dev/null
$GEN --eyebrow B --title Same --color blue --seed 9 --size 768x432 --out b.png >/dev/null
$GEN --eyebrow B --title Same --color blue --seed 10 --size 768x432 --out c.png >/dev/null
check "the same seed draws the same poster" cmp -s a.png b.png
check "another seed draws another poster" test "$(md5sum < a.png)" != "$(md5sum < c.png)"
out=$($GEN --eyebrow B --title T --seed 77 --size 768x432 --out d.png)
check_out "no colour: made up from the seed" "^color.random" echo "$out"
out=$($GEN --eyebrow B --title T --size 768x432 --out e.png)
check_out "no seed: a seed is made up" "^seed.[0-9]+" echo "$out"
mkdir -p into
check_out "a folder as --out gets the default name" "poster-hallo-4.png" $GEN --eyebrow B --title Hallo --seed 4 --size 768x432 --out into
check_out "a #rrggbb colour works" "^color.#1d4ef0" $GEN --eyebrow B --title T --color '#1d4ef0' --seed 1 --size 768x432 --out f.png
check_out "a title that is too long is refused" "too long" $GEN --eyebrow B --title "$(printf 'x%.0s' $(seq 1 90))" --size 768x432 --out g.png
check_out "--case keep keeps the letters" "^status.ok" $GEN --eyebrow Bib --title Filme --case keep --seed 2 --size 768x432 --out h.png
fi

echo "-- the guided dialogue"
B=$WORK/fake; mkdir -p "$B"
cat > "$B/gen.sh" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = --list-colors ]; then printf 'red\nyellow\nblue\n'; exit 0; fi
echo "args:$*" >> "$HS_FAKE_LOG"
printf 'status\tok\nfile\t/tmp/poster-x-1.png\ncolor\t%s\nseed\t%s\nsize\t1920x1080\n' "random #12" "4711"
FAKE
chmod +x "$B/gen.sh"
export HS_GENERATE_POSTER="$B/gen.sh" HS_FAKE_LOG="$WORK/gen.log" HS_GUIDED_TTY=1
G="bash $PKGS/posters/generate-poster-guided.sh"
: > "$HS_FAKE_LOG"
cat > "$B/manage-shares.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'media\tshare\t/bulk/shares/media\toff\t-\t\nphotos\tsensitive\t/bulk/sensitive/photos\toff\t-\t\n'
FAKE
export HS_MANAGE_SHARES="$B/manage-shares.sh"
# eyebrow, title, colour 2 (red), seed 1 (random), where 1 (this folder)
out=$(printf 'Bibliothek\nFilme\n2\n1\n1\n' | $G 2>&1) || true
check_out "it asks and draws" "Saved: /tmp/poster-x-1.png" echo "$out"
check_out "the answers reach the system command (no --out for this folder)" "args:--eyebrow Bibliothek --title Filme --color red$" cat "$HS_FAKE_LOG"
check_out "it names the command to draw the same again" "hs ext posters generate --eyebrow 'Bibliothek' --title 'Filme' --seed 4711" echo "$out"
: > "$HS_FAKE_LOG"
out=$(printf 'A\nB\n1\n2\n42\n1\n' | $G 2>&1) || true   # colour random, seed typed, this folder
check_out "a typed seed is handed over" "args:--eyebrow A --title B --seed 42$" cat "$HS_FAKE_LOG"
: > "$HS_FAKE_LOG"
out=$(printf '1\n' | $G --eyebrow E --title T --color blue --seed 3 --size 768x432 2>&1) || true
check_out "options skip the questions and pass through" "args:--eyebrow E --title T --color blue --seed 3 --size 768x432$" cat "$HS_FAKE_LOG"
: > "$HS_FAKE_LOG"
out=$(printf '3\n2\n' | $G --eyebrow E --title T --color blue --seed 3 2>&1) || true     # where: a share, the second one
check_out "a share is listed and its folder becomes --out" "args:--eyebrow E --title T --color blue --seed 3 --out /bulk/sensitive/photos$" cat "$HS_FAKE_LOG"
check_out "the list shows name and path" "media  \(/bulk/shares/media\)" echo "$out"
: > "$HS_FAKE_LOG"
out=$(printf '4\n/srv/pics\n' | $G --eyebrow E --title T --color blue --seed 3 2>&1) || true   # another folder, typed
check_out "another folder is typed" "args:.* --out /srv/pics$" cat "$HS_FAKE_LOG"
check_out "the repeat command carries it" "Next: .* --out '/srv/pics'" echo "$out"
: > "$HS_FAKE_LOG"
out=$(HS_MANAGE_SHARES=/nonexistent printf '3\n' | HS_MANAGE_SHARES=/nonexistent $G --eyebrow E --title T --color blue --seed 3 2>&1) || true
check_out "no shares: this folder, with a note" "No shares found" echo "$out"
: > "$HS_FAKE_LOG"
$G --eyebrow E --title T --color blue --seed 3 --out /x/y.png </dev/null >/dev/null 2>&1 || true
check_out "--out skips the question" "args:.* --out /x/y.png$" cat "$HS_FAKE_LOG"
unset HS_GUIDED_TTY
check_out "no terminal and no title: it says so" "required" env HS_CALLER=test $G --eyebrow E </dev/null
finish
