# posters

Halftone posters (PNG): `hs ext posters generate` and the web page `/operations/posters`.
Off by default. Scripts in this folder: generate-poster*.sh, poster-change.sh, poster.py (Pillow), fonts/ (Inter, OFL; a copy of the matrix-card fonts). Guide: capabilities/posters/guide.md.

An extension package (docs/PLAN-extensions.md): switch on with `hs ext enable posters` (no rebuild). Commands: capabilities/posters/commands.tsv (`ext posters generate`, `sys ext posters generate|list|plan|start`); the old word `hs generate poster` is a legacy row of the core for one release. The web page reads `/api/sys/ext/posters/list` and changes through the area `ext/posters`, declared in capability.toml.

Service (hobnix/core#1129): `poster-svc.py` subscribes to `pkg.media-hub.imported` and draws a poster for the title of the event ("New in the library", seed = crc32 of the
title, so the same title draws the same file and an event delivered twice does no harm). It calls `poster-change.sh start generate` directly, never `hs`: the media-hub
service is confined and runs no host command, so the trigger lives here. A failed drawing is logged and the event is still acknowledged. Needs core API level 10.
Not tested on hardware yet.
