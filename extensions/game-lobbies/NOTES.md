# game-lobbies

First slice of the game edge (hobnix/server#924, pillar A of #917). A lobby is a saved name for an Incus instance that runs a game server
(`hs ext game-lobbies add <name> <instance> <port> [<game>]`). State lives in `/var/lib/hs/game-lobbies/` (`lobbies`, `links`).

Slots (hobnix/server#472): a page with two tabs, "Lobbies" (stat tiles, the lobbies table) and "Worlds and console" (snapshots with a Restore row
action that goes through plan and start, role app-manager), a state card ("Active lobbies", `--summary`), and the action "Make wake link". Wake links
carry a random token and an expiry; `redeem` reads the token from stdin and starts the instance.

Not here yet: the PTY terminal, the game's RCON console, the HTTP page that serves a wake link, restore as a background job. See the pull request.
Scripts: lobby.sh (reads, add, remove, link, redeem), lobby-change.sh (plan and start). Test stand-ins: HS_INCUS, HS_CT (manage-ct.sh), HS_STATE_DIR, HS_NOW.
