# media-hub

Media statistics (hobnix/core#928, part of the 1.0 showcase #917): the media apps found through the integration `media`, watch minutes and plays per month, and a
page that draws them. Off by default; switch on with `hs ext enable media-hub` (no rebuild). Needs core 0.12 (the integrations, the event retention classes and
the rollup helper).

First slice, and what it keeps:
- **Apps:** `hs ext media-hub apps` reads `hs pkg integrations media` (Radarr, Sonarr, SABnzbd, Jellyfin declare `[integrations.media]`). The permission
  `integration:media` is declared for the API key; the second slice reads it for the poller.
- **Events** (package.toml `[[events]]`): `session-completed` is `metric` (counted, raw rows kept 35 days), `now-playing` is `ephemeral` (7 days), `imported` and
  `upgraded` are `audit`.
- **Rollup:** kind `media-watch` in the table `rollups` of `state.db`: n = plays, sum = minutes, one row per (month, user). Five years of 5 users are 300 rows, far under
  50 KB (tests/media-hub.sh checks it).
- **Page:** stat tiles, a chart of minutes per month, the list of apps (reads `apps`, `stats`, `months`).

Second slice (needs core API level 10 for the `[service]` table):
- **Poller:** the extension protocol has no timer, so `media-svc.py` (the `[service]`) polls on its own clock, every 30 s (`HS_MEDIA_POLL_SECONDS`, 0 = off). It
  asks the app for its sessions, notices when one is gone, and calls `record-session` with the minutes between first and last sight (at least one minute, at
  most a day; a pause counts as playing). Who plays now is the snapshot topic `now-playing` (one document, overwritten). The key is read per call, never logged (see Keys by provider).
- **Adapters:** one small file per app, `adapter_jellyfin.py` and `adapter_plex.py`: the endpoint, the key header and a `parse` that returns `{id, user, title,
  path}`. **UNVERIFIED**: written from the public API descriptions and tested only against the hand-made fixtures in `tests/fixtures/media-hub/`. Plex is
  not a recipe of the core; its adapter is used only when a package named `plex` declares `[integrations.media]`.
- **Keys by provider** (core 0.12 `integration_key <name> <provider> <caller>`, the `key_header` column of `hs pkg integrations`): the poller reads the listing,
  polls every provider that has a key, an address and an adapter, and sends each key only to the address of its own package, in the header of its row (a row
  without `key_header` gets the header of the adapter: Jellyfin `X-Emby-Token`, Plex `X-Plex-Token`). A provider without an adapter (Radarr, Sonarr, SABnzbd)
  is skipped and named once in the log. The key of a provider comes from the systemd credential `integration-media` only for the package that credential belongs
  to (the first row of the listing with a key, the rule of core's `integration-grant`), never for another; any other provider's key is asked through
  `integration_key media <provider> media-hub`. Tests with a Jellyfin and a Radarr row prove that no key crosses (tests/media-hub-poll.py).
- **Known gap:** the platform hands a confined service ONE credential per integration (`integration-media`, the key of the first provider with a key file), and
  the service is not told whose it is. Inside the sandbox the key files and the vault are out of reach, so the `integration_key ... <provider>` call of the
  poller finds nothing there: a second provider (Plex next to Jellyfin) is polled only where that call works. Needs a core change: one credential per
  provider (e.g. `integration-<name>-<provider>`) or a listing of the credential owners. The hub then asks for the credential of each provider.
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
