# games

Game streaming: the saved game PCs (`hs ext games list|add|remove|wake`, Sunshine on the PC) and the web page `/games`.
Off by default. Scripts: pc.sh, pc-change.sh in this folder (they find the core helpers through HS_SCRIPTS, set by hs). Web: web/src/pages/Games.svelte. The Sunshine server container (recipe `sunshine`) is parked.

An extension package (docs/PLAN-extensions.md): switch on with `hs ext enable games` (no rebuild). Commands: capabilities/games/commands.tsv (`ext games ...`, `sys ext games ...`); the old words `hs pc ...` are legacy rows of the core for one release. The web page reads `/api/sys/ext/games/...` and changes through the area `ext/games`, declared in capability.toml.
