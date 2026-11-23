# game-lobbies

First slice of the game edge (hobnix/server#924, pillar A of #917). A lobby is a saved name for an Incus instance that runs a game server
(`hs ext game-lobbies add <name> <instance> <port> [<game>]`). State lives in `/var/lib/hs/game-lobbies/` (`lobbies`, `links`).

Slots (hobnix/server#472): a page with two tabs, "Lobbies" (stat tiles, the lobbies table) and "Worlds and console" (snapshots with a Restore row
action that goes through plan and start, role app-manager), a state card ("Active lobbies", `--summary`), and the action "Make wake link". Wake links
carry a random 128-bit token and an expiry. Only the sha256 of the token is stored (file `links`, 0600) and the token is shown once, when the link is made
(`hs ext game-lobbies link <name>`), never again and never in a log or a read. `redeem` reads the token from stdin, hashes it and compares in constant
time (hmac.compare_digest); a link works any number of times until it expires or is revoked (friends wake the same lobby again), it is not single-use.

Not here yet: the PTY terminal, the game's RCON console, the HTTP page that serves a wake link, restore as a background job. See the pull request.
Scripts: lobby.sh (reads, add, remove, link, redeem), lobby-change.sh (plan and start). Test stand-ins: HS_INCUS, HS_CT (manage-ct.sh), HS_STATE_DIR, HS_NOW.

Second slice: a `[[health]]` check `lobbies` (read `checks`, requires `incus`): a running lobby is `ok`, a stopped one `info` (not a problem, nothing is sent), a lobby
whose instance is gone `warn` (System > Health, package named). The card already answered `info` when no lobby runs. The tab "Wake links" has `requires = "gateway"`
(the wake page will sit behind it); links stay creatable from the lobby row without it. guide.md is the package guide.

Waiting on the core, not built here: PTY terminal (hobnix/server#1123), RCON console (#1124), secrets for packages, e.g. an RCON password (#1125), extension actions
as background jobs (#1126). Until #1126 the restore is synchronous (`long yes` in the plan). Idle sleep (stop an empty lobby after a while) and a snapshot before an update
need a timer or an event hook the extension protocol does not offer: open questions on #924.
