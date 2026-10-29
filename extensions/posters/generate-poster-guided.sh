#!/usr/bin/env bash
# help: draw a poster step by step: asks the eyebrow, the title, the colour and the seed (hs ext posters generate)
# help.de: ein Poster Schritt für Schritt zeichnen: fragt Eyebrow, Titel, Farbe und Seed (hs ext posters generate)
# args: [--eyebrow <text>] [--title <text>] [--color <name|#rrggbb>] [--seed <n>] [--size <WxH>] [--case upper|keep] [--out <file>] [--force]
# A halftone poster like the Matrix cards, for example the picture of a Jellyfin library. Guided front for the system command
# `hs sys ext posters generate` (generate-poster.sh in this package): it asks what is missing, every answer is also an option. The eyebrow
# and the title are required; colour and seed are random unless given (the same seed always gives the same poster). Without a
# terminal nothing is asked: the eyebrow and the title must be given. A random poster can be redrawn with a new seed right away.
# Where it is saved is asked too: this folder, your home folder, a share (listed) or another folder; --out skips the question.
# HS_GENERATE_POSTER points tests at a stand-in, HS_GUIDED_TTY=1 = "there is a terminal".
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scripts=${HS_SCRIPTS:-$here/../../scripts}   # the core helpers; hs and hs-web set HS_SCRIPTS
. "$scripts/lib/ui.sh"
gen=${HS_GENERATE_POSTER:-$here/generate-poster.sh}
msh=${HS_MANAGE_SHARES:-$scripts/manage-shares.sh}

usage() {
  say "usage: hs ext posters generate [--eyebrow <text>] [--title <text>] [--color <name|#rrggbb>] [--seed <n>]"
  say "                          [--size <WxH>] [--case upper|keep] [--out <file|folder>] [--force]"
  exit 1
}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

eyebrow=""; title=""; color=""; seed=""; out=""; extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --eyebrow) [ $# -ge 2 ] || usage; eyebrow=$2; shift 2 ;;
    --title)   [ $# -ge 2 ] || usage; title=$2; shift 2 ;;
    --color)   [ $# -ge 2 ] || usage; color=$2; shift 2 ;;
    --seed)    [ $# -ge 2 ] || usage; seed=$2; shift 2 ;;
    --out)     [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
    --size|--case) [ $# -ge 2 ] || usage; extra+=("$1" "$2"); shift 2 ;;
    --force)   extra+=(--force); shift ;;
    *) usage ;;
  esac
done

random_seed=false; random_color=false
if interactive; then
  while [ -z "$eyebrow" ]; do eyebrow=$(ask "Eyebrow (the small line above the title, for example Library)" ""); done
  while [ -z "$title" ]; do title=$(ask "Title (for example Movies)" ""); done
  if [ -z "$color" ]; then
    mapfile -t names < <(bash "$gen" --list-colors)
    pick=$(choose "Colour" "random" "${names[@]}" "own colour (#rrggbb)") || exit 1
    case "$pick" in
      random) ;;
      "own colour"*) color=$(ask "Colour as #rrggbb" "") ;;
      *) color=$pick ;;
    esac
  fi
  if [ -z "$seed" ]; then
    pick=$(choose "Seed (the same seed always draws the same poster)" "random" "I type a number") || exit 1
    [ "$pick" = random ] || seed=$(ask "Seed (a whole number)" "")
  fi
  if [ -z "$out" ]; then
    home=$(getent passwd "${SUDO_USER:-${USER:-root}}" 2>/dev/null | cut -d: -f6 || true)
    pick=$(choose "Where to save it?" "This folder ($PWD)" "My home folder (${home:-$HOME})" "A share" "Another folder") || exit 1
    case "$pick" in
      "This folder"*) ;;
      "My home folder"*) out=${home:-$HOME} ;;
      "A share")
        # name, kind, path, ... of every share (the list the Shares tab reads)
        mapfile -t shares < <(bash "$msh" --list 2>/dev/null | awk -F'\t' '$1 != "" { print $1 "  (" $3 ")" }' || true)
        if [ ${#shares[@]} -eq 0 ]; then
          note "No shares found: the poster is saved in this folder."
        else
          pick=$(choose "Which share?" "${shares[@]}") || exit 1
          out=$(sed 's/^.*(\(.*\))$/\1/' <<<"$pick")
        fi ;;
      *) out=$(ask "Folder (full path, it must exist)" "") ;;
    esac
  fi
fi
[ -n "$eyebrow" ] && [ -n "$title" ] || fail "The eyebrow and the title are required."
[ -n "$color" ] || random_color=true
[ -n "$seed" ] || random_seed=true

draw() {   # draw: runs the system command, prints the result, sets $res_seed
  local args=(--eyebrow "$eyebrow" --title "$title") res rc=0
  [ -z "$color" ] || args+=(--color "$color")
  [ -z "$seed" ] || args+=(--seed "$seed")
  [ -z "$out" ] || args+=(--out "$out")
  res=$(mktemp)
  spin "Drawing the poster" bash -c 'bash "$1" "${@:3}" >"$2"' _ "$gen" "$res" "${args[@]}" "${extra[@]}" || rc=$?
  if [ "$rc" != 0 ]; then
    local why; why=$(awk -F'\t' '$1 == "reason" { print $2; exit }' "$res")
    # the spinner hides the output of a failed step only when it printed nothing useful: say the reason ourselves
    rm -f "$res"
    fail "${why:-The poster could not be drawn.}"
  fi
  val() { awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$res"; }
  ok "$(t 'Saved: %s' "$(val file)")"
  kv "Colour" "$(val color)"
  kv "Seed" "$(val seed)"
  kv "Size" "$(val size)"
  res_seed=$(val seed); res_color=$(val color); res_file=$(val file)
  rm -f "$res"
}

res_seed=""; res_color=""; res_file=""
draw
# the same poster again, from the command line
again="hs ext posters generate --eyebrow '$eyebrow' --title '$title' --seed $res_seed"
case "$res_color" in random*) ;; *) again+=" --color $res_color" ;; esac
[ -z "$out" ] || again+=" --out '$out'"
next_step "$again"
if interactive && $random_seed; then
  while confirm "Draw another one with a new seed?"; do
    seed=""
    draw
  done
fi
