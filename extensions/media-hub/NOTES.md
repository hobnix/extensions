# media-hub

Media statistics (hobnix/core#928, part of the 1.0 showcase #917): the media apps found through the integration `media`, watch minutes and plays per month, and a
page that draws them. Off by default; switch on with `hs ext enable media-hub` (no rebuild). Needs core 0.12 (the integrations, the event retention classes and
the rollup helper).

First slice, and what it keeps:
- **Apps:** `hs ext media-hub apps` reads `hs pkg integrations media` (Radarr, Sonarr, SABnzbd, Jellyfin declare `[integrations.media]`). The permission
  `integration:media` is declared for the API key; this slice reads no key yet.
- **Events** (package.toml `[[events]]`): `session-completed` is `metric` (counted, raw rows kept 35 days), `now-playing` is `ephemeral` (7 days), `imported` and
  `upgraded` are `audit`.
- **Rollup:** kind `media-watch` in the table `rollups` of `state.db`: n = plays, sum = minutes, one row per (month, user). Five years of 5 users are 300 rows, far under
  50 KB (tests/media-hub.sh checks it).
- **Page:** stat tiles, a chart of minutes per month, the list of apps (reads `apps`, `stats`, `months`).

Nothing polls an app yet. `record-session` and `record-import` are the entrance a Jellyfin webhook or a poller will call.

Not built yet: the poster generator on an import event, the storage suggestion (a file-manager job only after the user confirms), bandwidth per remote stream.
Not tested on hardware yet.
