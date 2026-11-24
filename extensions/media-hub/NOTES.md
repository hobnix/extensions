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
- **Poller:** the extension protocol has no timer, so the service (a Rust program, `src/`, `[[binary]]` `bin/media-svc`, hobnix/extensions#27) polls on its
  own clock in a worker thread, every 30 s (`HS_MEDIA_POLL_SECONDS`, 0 = off). It asks the app for its sessions, notices when one is gone, and counts it with
  the minutes between first and last sight (at least one minute, at most a day; a pause counts as playing; under 60 s, `HS_MEDIA_MIN_SECONDS`, it is not
  counted): an `emit` of `session-completed` and a `rollup` of the same kind (`pkg.media-hub.session-completed`: the core adds to the monthly rollup only for
  a metric event kind of the package), both through the protocol, no `record-session` call. `hs ext media-hub stats` and the page add that kind to the old
  `media-watch` (record-session, and the history from before the Rust service). Who plays now is the snapshot topic `now-playing` (one document, overwritten).
- **Adapters:** one function pair per app in `src/adapter.rs` (Jellyfin, Plex): the endpoint, the key header and a parse that returns `{id, user, title,
  path}`. **UNVERIFIED**: written from the public API descriptions and tested only against the hand-made fixtures in `tests/fixtures/media-hub/` (unit tests
  and `tests/service.rs`, which runs the real program against a local http server that serves them). Plex is not a recipe of the core; its adapter is used
  only when a package named `plex` declares `[integrations.media]`.
- **Plain http only:** the SDK client has no TLS. A provider whose `api_url` starts with `https://` is named in the log once (`TlsUnsupported`) and not
  polled; put a local TLS-terminating proxy in front of it or use the plain http address of the app on the same host.
- **Keys by provider:** the listing (`hs sys pkg integrations media`, run by the service: still an `hs` call, to be replaced by `init.integrations` when the core has it (hobnix/core#1129 step 3)) names each provider; its key is the systemd credential
  `integration-media-<provider>` read with the SDK (`credential_for`), never from argv or the environment, never logged, and sent only to the address of
  its own provider in the header of its row (a row without `key_header` gets the header of the adapter: Jellyfin `X-Emby-Token`, Plex `X-Plex-Token`). A
  provider without an adapter (Radarr, Sonarr, SABnzbd) is skipped and named once in the log; one without a credential is named once and not asked. The
  old known gap (one credential for all providers) is closed by the per-provider credentials of the core.
- **Poster:** an `imported` event (`pkg.media-hub.imported`, written by `record-import`; nothing writes it by itself yet) is handled by the package `posters`,
  not by this service: its service `poster-svc.py` subscribes to the event and draws the poster itself. media-svc runs no host command for it (inside the
  confined unit `hs` cannot see the package registry or the job store). If `posters` is off, nothing is drawn and nothing fails.
- **Storage suggestion:** the service keeps `/var/lib/hs/media-hub/watched.tsv` (the file name and folder an app reported for each finished playback, newest 200).
  `hs sys ext media-hub suggestions` lists what was watched 30 or more days ago as a move from the smallest writable pool to the largest. The page shows
  it with a row action "Move..."; that opens the plan dialog (the file manager's own `plan move`), and only the start after the confirmation makes the
  background job (`fm.sh start move`). The service never starts one. The folder is the path the app reports (inside the app's container, probably) and is
  assumed to exist at the same place in both pools: heuristic, unverified; the file manager's plan refuses otherwise.

Not built yet: bandwidth per month and tunnel throughput per remote stream, a poller for the import events of Radarr and Sonarr, German page texts, a guide.
Not tested on hardware yet.
