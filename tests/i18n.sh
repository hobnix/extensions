#!/usr/bin/env bash
# The German texts of the extensions: the interactive scripts' texts are translated (in the extension's own i18n/de.tsv or in the core catalog),
# nothing in a catalog is unused, the placeholders agree. No root.
HERE=$(cd "$(dirname "$0")/.." && pwd)
CORE=${HS_CORE:-$HERE/core}
[ -f "$CORE/tests/lib.sh" ] || { echo "no core checkout: set HS_CORE=<folder of hobnix/server>" >&2; exit 77; }
# shellcheck source=/dev/null
. "$CORE/tests/lib.sh"
PKGS=$HERE/extensions
CATALOG=$CORE/scripts/lib/i18n/de.tsv
KEYS="python3 -I $CORE/scripts/dev/i18n-keys.py"
has() { [ -f "$1" ] && awk -F'\t' -v k="$2" '$1 == k { f = 1 } END { exit !f }' "$1"; }   # the exact text, not a part of a longer one

# extension -> the scripts whose messages are translated
declare -A SCRIPTS_OF=([games]="pc.sh" [posters]="generate-poster-guided.sh")
missing=""; stale=""; ph=""
for e in "${!SCRIPTS_OF[@]}"; do
  own=$PKGS/$e/i18n/de.tsv
  files=""; for s in ${SCRIPTS_OF[$e]}; do files="$files $PKGS/$e/$s"; done
  keys=$($KEYS $files)
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    has "$CATALOG" "$k" || has "$own" "$k" || missing="$missing [$e: $k]"
  done <<<"$keys"
  [ -f "$own" ] || continue
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && [ "${k:0:1}" != "#" ] || continue
    grep -qxF -- "$k" <<<"$keys" || stale="$stale [$e: $k]"
  done < "$own"
done
for own in "$PKGS"/*/i18n/de.tsv; do
  [ -f "$own" ] || continue
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && [ "${k:0:1}" != "#" ] || continue
    [ "$(grep -o '%[sd]' <<<"$k" | wc -l)" = "$(grep -o '%[sd]' <<<"$v" | wc -l)" ] || ph="$ph [$(basename "$(dirname "$(dirname "$own")")"): $k]"
  done < "$own"
done
check_eq "every text of games and posters is translated" "" "$(head -c 600 <<<"$missing")"
check_eq "no translation of an extension is unused" "" "$(head -c 600 <<<"$stale")"
check_eq "every translation keeps its placeholders" "" "$(head -c 600 <<<"$ph")"
finish
