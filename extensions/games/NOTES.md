# games

Game streaming: the saved game PCs (`hs ext games list|add|remove|wake`, Sunshine on the PC) and the web page `/games`.
Off by default. Scripts: pc.sh, pc-change.sh in this folder (they find the core helpers through HS_SCRIPTS, set by hs). Web: web/src/pages/Games.svelte. The Sunshine server container (recipe `sunshine`) is parked.

An extension package (docs/PLAN-extensions.md): switch on with `hs ext enable games` (no rebuild). Commands: capabilities/games/commands.tsv (`ext games ...`, `sys ext games ...`); the old words `hs pc ...` are legacy rows of the core for one release. The web page reads `/api/sys/ext/games/...` and changes through the area `ext/games`, declared in capability.toml.

Two slots besides the page (hobnix/server#472, the pilot of an extension that uses two different slots): a health check `[[health]]` (`hs sys ext games checks`, rows `level<TAB>message`: ok for a saved PC whose Sunshine answers, `info` for one that does not (a switched-off PC is normal; off, asleep and "on but Sunshine not running" cannot be told apart, so there is never a warn)) and an action `[[web.actions]]` "Wake all PCs" (plan `ext/games wake-all`, role app-manager; `hs sys ext games plan|start wake-all` in pc-change.sh). A PC that is simply switched off shows as a warning; acknowledge it in System > Health. Both need core 0.12 (the slots); not tested on hardware yet.
