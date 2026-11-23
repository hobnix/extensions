#!/usr/bin/env bash
# help: media statistics: the media apps found, watch minutes and plays per month
# help.de: Medien-Statistik: die gefundenen Medien-Apps, Minuten und Wiedergaben pro Monat
# args: apps | stats | record-session <user> <minutes> [<title>] | record-import imported|upgraded <title> [<app>] | --apps | --stats | --months
# First slice of the media hub (hobnix/core#928). It keeps no live state of its own: the apps come from `hs pkg integrations media`, the history is
# the monthly rollups in state.db (n = plays, sum = minutes; one row per month and user, never pruned, docs/extensions-sdk.md: kind media-watch
# from record-session and from before the Rust service, kind pkg.media-hub.session-completed from the service; every reader adds both), and
# the milestones are package events (pkg.media-hub.*, retention classes in package.toml). The service (a Rust program, src/, bin/media-svc) polls the
# media apps and counts a playback itself through the service protocol (adapters: src/adapter.rs, UNVERIFIED); media-suggest.sh holds the storage suggestion.
# --apps = package TAB address TAB key state (ok|locked|missing|-) TAB kind (- when the app names none), one row per media app, no header.
# --stats = one row: plays this month, minutes this month, plays in all, minutes in all, media apps found.
# --months = month TAB minutes TAB plays, oldest first, the last 24 months, all users added; nothing when nothing is recorded.
# Test knobs: HS_MEDIA_INTEGRATIONS (a file with the rows of `hs sys pkg integrations media`), HS_MEDIA_MONTH (the current month, YYYY-MM),
# HS_STATE_DB (the database the core helpers use).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scripts=${HS_SCRIPTS:-$here/../../scripts}   # the core helpers; hs and hs-web set HS_SCRIPTS
. "$scripts/lib/ui.sh"
. "$scripts/lib/event.sh"
kind=media-watch   # the rollup kind of record-session (a person's own count), and of the history before the Rust service
svc_kind=pkg.media-hub.session-completed   # the rollup kind the service media-svc writes through the protocol (the core allows only a metric event kind of the package)
user_re='^[A-Za-z0-9_.@-]{1,64}$'
tab=$'	'

usage() {
  say "usage: hs ext media-hub apps"
  say "       hs ext media-hub stats"
  say "       hs ext media-hub record-session <user> <minutes> [<title>]"
  say "       hs ext media-hub record-import imported|upgraded <title> [<app>]"
  exit 1
}

integrations() {   # the rows of `hs sys pkg integrations media`
  if [ -n "${HS_MEDIA_INTEGRATIONS:-}" ]; then cat "$HS_MEDIA_INTEGRATIONS"; return 0; fi
  bash "$scripts/pkg.sh" --integrations media 2>/dev/null || true
}
apps_rows() {   # package, address, key state, kind
  integrations | awk -F'\t' 'NF >= 5 {
    kind = "-"; n = split($6, e, ",")
    for (i = 1; i <= n; i++) if (e[i] ~ /^kind=/) kind = substr(e[i], 6)
    printf "%s\t%s\t%s\t%s\n", $1, $4, $5, kind }'
}
rollups() {   # month TAB user TAB kind TAB n TAB sum, oldest first: both kinds, the readers add them up
  { bash "$scripts/state.sh" rollups "$kind" 2>/dev/null || true; bash "$scripts/state.sh" rollups "$svc_kind" 2>/dev/null || true; } | sort -t "$tab" -k1,1 -s
}
months_rows() {   # month, minutes, plays: all users added, the last 24
  rollups | awk -F'\t' '{ n[$1] += $4; s[$1] += $5 } END { for (m in n) printf "%s\t%d\t%d\n", m, s[m], n[m] }' | sort | tail -n 24
}
stats_row() {
  local now apps
  now=${HS_MEDIA_MONTH:-$(date -u +%Y-%m)}
  apps=$(apps_rows | wc -l | tr -d ' ')
  rollups | awk -F'\t' -v now="$now" -v apps="$apps" '
    { tn += $4; ts += $5; if ($1 == now) { mn += $4; ms += $5 } }
    END { printf "%d\t%d\t%d\t%d\t%d\n", mn, ms, tn, ts, apps }'
}

json_text() {   # a free text made safe for a JSON string: no quote, backslash or control character, at most 120 characters
  printf '%s' "$1" | tr -d '"\\' | tr -d '[:cntrl:]' | cut -c1-120
}

record_session() {
  local user=${1:-} minutes=${2:-} title
  [[ "$user" =~ $user_re ]] || fail "The user is a name of letters, digits and _.@- (at most 64 characters)"
  [[ "$minutes" =~ ^[0-9]{1,4}$ ]] && [ "$minutes" -ge 1 ] && [ "$minutes" -le 1440 ] || fail "The minutes are a whole number from 1 to 1440"
  title=$(json_text "${3:-}")
  bash "$scripts/state.sh" rollup-add "$kind" "$user" --n 1 --sum "$minutes" || fail "Could not write the monthly sum"
  event_emit pkg.media-hub.session-completed "$user" "Playback finished" --payload "{\"minutes\":$minutes,\"title\":\"$title\"}"
  ok "Counted $minutes minutes for $user"
}

record_import() {
  local what=${1:-} title app
  case "$what" in imported|upgraded) ;; *) usage ;; esac
  [ -n "${2:-}" ] || usage
  title=$(json_text "$2"); app=$(json_text "${3:-}")
  [ -n "$app" ] || app=media
  [[ "$app" =~ ^[A-Za-z0-9_.-]{1,40}$ ]] || fail "The app is a name of letters, digits and _.-"
  event_emit "pkg.media-hub.$what" "$app" "Media $what" --payload "{\"title\":\"$title\",\"app\":\"$app\"}"
  ok "Noted: $what $title"
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  --apps) apps_rows ;;
  --stats) stats_row ;;
  --months) months_rows ;;
  apps)
    rows=$(apps_rows)
    if [ -z "$rows" ]; then note "No media app found. Install Radarr, Sonarr, SABnzbd or Jellyfin."
    else { printf 'App\tAddress\tKey\tKind\n'; printf '%s\n' "$rows"; } | table; fi ;;
  stats)
    IFS=$'\t' read -r pm mm pa ma na <<<"$(stats_row)"
    kv "Plays this month" "$pm"; kv "Minutes this month" "$mm"; kv "Plays in all" "$pa"; kv "Minutes in all" "$ma"; kv "Media apps found" "$na" ;;
  record-session) record_session "$@" ;;
  record-import) record_import "$@" ;;
  *) usage ;;
esac
