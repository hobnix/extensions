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

Second slice (needs core API level 10 for the `[service]` table):
- **Poller:** the extension protocol has no timer, so `media-svc.py` (the `[service]`) polls on its own clock, every 30 s (`HS_MEDIA_POLL_SECONDS`, 0 = off). It
  asks the app for its sessions, notices when one is gone, and calls `record-session` with the minutes between first and last sight (at least one minute, at
  most a day; a pause counts as playing). Who plays now is the snapshot topic `now-playing` (one document, overwritten). The key comes from `integration_key
  media media-hub` on a pipe, per call, never logged.
- **Adapters:** one small file per app, `adapter_jellyfin.py` and `adapter_plex.py`: the endpoint, the key header and a `parse` that returns `{id, user, title,
  path}`. **UNVERIFIED**: written from the public API descriptions and tested only against the hand-made fixtures in `tests/fixtures/media-hub/`. Plex is
  not a recipe of the core; its adapter is used only when a package named `plex` declares `[integrations.media]`.
- **Known gap:** `integration_key <name> <caller>` returns the key of the first package of the integration that has a `key_file`, not of an app of our choice.
  So the one app the hub can poll is the first row of `hs pkg integrations media` that has a key; with Radarr before Jellyfin nothing is polled and the service
  logs why. Needs a core change (a third argument naming the package).
- **Poster:** an `imported` event (`pkg.media-hub.imported`, written by `record-import`; nothing writes it by itself yet) makes the service run
  `hs sys ext posters start generate --eyebrow "New in the library" --title <title> --seed <crc of the title>`. The same title draws the same file, so an event
  delivered twice does no harm. If `posters` is off, the failure is logged and the event is still acknowledged.
- **Storage suggestion:** the service keeps `/var/lib/hs/media-hub/watched.tsv` (the file name and folder an app reported for each finished playback, newest 200).
  `hs sys ext media-hub suggestions` lists what was watched 30 or more days ago as a move from the smallest writable pool to the largest. The page shows
  it with a row action "Move..."; that opens the plan dialog (the file manager's own `plan move`), and only the start after the confirmation makes the
  background job (`fm.sh start move`). The service never starts one. The folder is the path the app reports (inside the app's container, probably) and is
  assumed to exist at the same place in both pools: heuristic, unverified; the file manager's plan refuses otherwise.

Not built yet: bandwidth per month and tunnel throughput per remote stream, a poller for the import events of Radarr and Sonarr, German page texts, a guide.
Not tested on hardware yet.
