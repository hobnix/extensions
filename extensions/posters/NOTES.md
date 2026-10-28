# posters

Halftone posters (PNG): `hs ext posters generate` and the web page `/operations/posters`.
Off by default. Scripts in this folder: generate-poster*.sh, poster-change.sh, poster.py (Pillow), fonts/ (Inter, OFL; a copy of the matrix-card fonts). Guide: capabilities/posters/guide.md.

An extension package (docs/PLAN-extensions.md): switch on with `hs ext enable posters` (no rebuild). Commands: capabilities/posters/commands.tsv (`ext posters generate`, `sys ext posters generate|list|plan|start`); the old word `hs generate poster` is a legacy row of the core for one release. The web page reads `/api/sys/ext/posters/list` and changes through the area `ext/posters`, declared in capability.toml.
