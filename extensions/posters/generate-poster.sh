#!/usr/bin/env bash
# help: draw a poster (halftone background, eyebrow line over a title) as a PNG; machine-readable: status, file, color, seed, size
# help.de: ein Poster zeichnen (Halbton-Hintergrund, kleine Zeile über dem Titel) als PNG; maschinenlesbar: status, file, color, seed, size
# args: --eyebrow <text> --title <text> [--color <name|#rrggbb>] [--seed <n>] [--size <WxH>] [--case upper|keep] [--out <file|folder>] [--force] | --list-colors
# The system command behind `hs ext posters generate` (generate-poster-guided.sh asks, this draws). Never asks. The eyebrow
# and the title are required; the colour and the seed are made up when left out (the colour from the seed, so the same seed
# always gives the same poster). Default file: poster-<title>-<seed>.png in the current folder, an existing file is kept
# unless --force. Needs Pillow (exit 2 and `needs pillow` without it). HS_POSTER_PY = another renderer (tests).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
py=${HS_POSTER_PY:-$here/poster.py}
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
rc=0
python3 "$py" "$@" >"$tmp" || rc=$?
cat "$tmp"
# run as root (hs does): the picture belongs to whoever owns its folder (the person's own folder, a share's owner), not to root
file=$(awk -F'\t' '$1 == "file" { print $2; exit }' "$tmp")
if [ "$rc" = 0 ] && [ -n "$file" ] && [ "$(id -u)" = 0 ]; then
  owner=$(stat -c '%u:%g' "$(dirname "$file")" 2>/dev/null || true)
  [ -z "$owner" ] || chown "$owner" "$file" 2>/dev/null || true
fi
exit "$rc"
