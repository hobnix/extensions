# Game lobbies

Keep game servers that run in Incus instances as named lobbies: see who plays, go back to a snapshot of the world, and give friends a link that wakes a stopped server.

## Before you start
- The server is installed and Incus is on ([Install](install.md)).
- A game server runs in an Incus instance, for example `minecraft`, and listens on a known port.
- You are an admin to add a lobby, an app-manager to restore or make wake links.

## Switch it on
Not tested on hardware yet.

```bash
sudo hs ext enable game-lobbies
```

The page "Game lobbies" appears in Apps.

## Add a lobby
A lobby is a name for an instance. The game name is optional. Not tested on hardware yet.

```bash
sudo hs ext game-lobbies add survival minecraft 25565 Minecraft
```

The card "Active lobbies" shows how many players are in how many running lobbies. A lobby whose instance is stopped shows as stopped; that is not a problem.

## Take a snapshot and go back to it
Snapshots are the worlds of a lobby. Take one before a risky change. Not tested on hardware yet.

```bash
sudo hs ct minecraft snapshot
```

The tab "Worlds and console" lists them, newest first. **Going back disconnects every player and deletes all snapshots newer than the one you pick.** The plan names them before you confirm. Choose Restore on the snapshot, read the plan, confirm. Restore runs while you wait; it is not a background job yet. Not tested on hardware yet.

## Make a wake link
A wake link starts a stopped lobby for whoever has it, until it expires. The token is shown once. Not tested on hardware yet.

```bash
sudo hs ext game-lobbies link survival --hours 24
```

List the links, then revoke one by its id. The list never shows the token. Not tested on hardware yet.

```bash
sudo hs ext game-lobbies link list
```

The tab "Wake links" is shown while the gateway is on ([Give the services local names](gateway.md)). The page that serves a link over HTTP is not part of this release.

## Check that it worked
- The card shows `N players in M of K lobbies`, or `No lobby is running` when all are stopped. Not tested on hardware yet.
- System > Health lists the package "Game lobbies" only when a lobby's instance is gone (a warning). Stopped lobbies are information, never a problem. Not tested on hardware yet.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| Health warns "the instance does not exist" | the instance was deleted or renamed | forget the lobby with `sudo hs ext game-lobbies remove <name>` and add it again |
| Players shows 0 for a busy game | the game talks UDP; only TCP connections are counted | none; the count is TCP only |
| Wake links tab is missing | the gateway is off | switch it on, or use the command line |
| Restore is refused | the snapshot name is not one of the instance | pick one from the list |

## Next
- [Extensions](extensions.md)
