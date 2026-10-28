#!/usr/bin/env bash
# help: draw and keep posters for the web interface: list them, make one (plan, then start), delete one
# help.de: Poster für die Weboberfläche zeichnen und aufbewahren: auflisten, eines machen (plan, dann start), eines löschen
# args: list | plan|start generate --eyebrow <text> --title <text> [--color <name|#rrggbb>] [--seed <n>] [--case upper|keep] | plan|start delete <file>
# System command (hs sys ext posters list | hs sys ext posters plan|start): for the interface and tests. It never asks. The drawing is generate-poster.sh's
# (poster.py beside it, Pillow); this script only keeps the pictures in one folder ($HS_STATE_DIR/posters, root only is not needed: they are no secret)
# and checks what the web page sends.
#   list                       one row per poster, newest first: file, bytes, modified (epoch)
#   generate ...               draw a poster; start prints status done and the file, color, seed and size the drawing reported
#   delete <file>              remove one poster from the folder
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text>, heading|step|note<TAB><line>, long<TAB>no.
# start: the same checks, then the work; status done (+ file, color, seed, size for generate) or refused.
# Test knobs: HS_POSTER_DIR, HS_POSTER_GEN (stand-in for generate-poster.sh), HS_STATE_DIR.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dir=${HS_POSTER_DIR:-${HS_STATE_DIR:-/var/lib/hs}/posters}
gen=${HS_POSTER_GEN:-$here/generate-poster.sh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

if [ "${1:-}" = list ]; then
  [ -d "$dir" ] || exit 0
  for f in "$dir"/poster-*.png; do
    [ -f "$f" ] || continue
    printf '%s\t%s\t%s\n' "$(basename "$f")" "$(stat -c %s "$f")" "$(stat -c %Y "$f")"
  done | sort -t$'\t' -k3,3nr
  exit 0
fi

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: poster-change.sh list | plan|start generate ... | plan|start delete <file>" >&2; exit 1 ;; esac
case "$action" in generate|delete) ;; *) refuse "unknown action (generate or delete)" ;; esac
shift 2 || true

NAME_RE='^poster-[A-Za-z0-9._-]{1,120}\.png$'

if [ "$action" = delete ]; then
  f=${1:-}; [ $# -eq 1 ] || refuse "delete needs one file name"
  [[ "$f" =~ $NAME_RE ]] && [[ "$f" != *..* ]] || refuse "that is not a poster file name"
  [ -f "$dir/$f" ] || refuse "There is no poster $f."
  if [ "$verb" = start ]; then rm -f -- "$dir/$f"; printf 'status\tdone\n'; exit 0; fi
  printf 'status\tok\nheading\tdelete the poster %s\nstep\tremove the picture from the server\nnote\tIt cannot be brought back; draw it again with the same seed to get the same one.\nlong\tno\n' "$f"
  exit 0
fi

eyebrow="" title="" color="" seed="" case_="upper"
while [ $# -gt 0 ]; do
  case "$1" in
    --eyebrow) [ $# -ge 2 ] || refuse "--eyebrow needs a value"; eyebrow=$2; shift 2 ;;
    --title)   [ $# -ge 2 ] || refuse "--title needs a value"; title=$2; shift 2 ;;
    --color)   [ $# -ge 2 ] || refuse "--color needs a value"; color=$2; shift 2 ;;
    --seed)    [ $# -ge 2 ] || refuse "--seed needs a value"; seed=$2; shift 2 ;;
    --case)    [ $# -ge 2 ] || refuse "--case needs a value"; case_=$2; shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done
[ -n "$eyebrow" ] && [ -n "$title" ] || refuse "The small line and the title are both needed."
for v in "$eyebrow" "$title"; do
  [ "${#v}" -le 80 ] || refuse "The texts are at most 80 characters."
  [[ "$v" != *[[:cntrl:]]* ]] || refuse "The texts must not hold control characters."
done
[ -z "$color" ] || [[ "$color" =~ ^([a-z]{3,12}|#[0-9a-fA-F]{6})$ ]] || refuse "The colour is a name (red, teal ...) or #rrggbb."
[ -z "$seed" ] || [[ "$seed" =~ ^[0-9]{1,9}$ ]] || refuse "The seed is a whole number."
case "$case_" in upper|keep) ;; *) refuse "--case is upper or keep" ;; esac

if [ "$verb" = plan ]; then
  printf 'status\tok\nheading\tdraw a poster\n'
  printf 'step\twrite "%s" over "%s" on a halftone background\n' "$eyebrow" "$title"
  printf 'note\t%s\n' "${seed:+The same seed gives the same poster.}${seed:-Colour and pattern are made up; the seed is shown afterwards so you can get the same one again.}"
  printf 'long\tno\n'
  exit 0
fi

mkdir -p "$dir"
args=(--eyebrow "$eyebrow" --title "$title" --case "$case_" --out "$dir" --force)
[ -z "$color" ] || args+=(--color "$color")
[ -z "$seed" ] || args+=(--seed "$seed")
rc=0
out=$(bash "$gen" "${args[@]}" </dev/null 2>/dev/null) || rc=$?
if [ "$rc" -ne 0 ]; then
  reason=$(awk -F'\t' '$1 == "reason" { print $2; exit }' <<<"$out")
  case "$rc:$out" in 2:*needs*pillow*) reason="The drawing needs Pillow: run hs update." ;; esac
  refuse "${reason:-the poster could not be drawn}"
fi
file=$(awk -F'\t' '$1 == "file" { print $2; exit }' <<<"$out")
[ -n "$file" ] || refuse "the poster could not be drawn"
printf 'status\tdone\nfile\t%s\n' "$(basename "$file")"
awk -F'\t' '$1 == "color" || $1 == "seed" || $1 == "size" { print }' <<<"$out"
exit 0
