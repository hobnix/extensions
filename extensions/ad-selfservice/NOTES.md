# ad-selfservice

A domain user changes their own AD password on a small web form (`https://<name>/password`). The service checks the old password against the DC with
the user's own credentials, holds no admin credential and no stored secret, and starts again after a reboot. A service extension package
(docs/PLAN-extensions.md, ADR 0011) on top of the capabilities `ad` and `gateway`: `hs ext enable ad-selfservice`, no rebuild, no Nix module.
Commands: commands.tsv (`ext ad-selfservice status|log|start|stop|expose`, `sys ext ad-selfservice ...`). Web page: `/extensions/ad-selfservice`.

## What runs
`service.py` is the `[service]` of the package (`exec = "@/service.py"`, no event subscribed, none emitted). The core runs it as the unit
`hs-ext-svc@ad-selfservice` (`hs ext svc-run`) and speaks JSON lines with it: `init`, `ready`, `health`, `log`, `shutdown`. The unit is confined
from the `permissions` of package.toml (`scripts/lib/ext_confine.py`): `ProtectSystem=strict`, no capabilities, no new privileges, writable only
the core's own state folder, `/var/lib/hs/ad-selfservice` (declared by the commands) and the unit's private /tmp. The form itself is `selfservice.py` (Python standard library only), served from
`service.py` on 127.0.0.1:8486.
The service is up while the package is on and was not stopped by hand (`hs ext stop` survives a reboot until `hs ext start`); the core starts it
after a reboot (`hs ext boot`), so the package has no boot row any more. It serves the form only when `config.json` exists and the web
service descriptor has a public name; until then `health` says why (`hs ext status` shows `degraded` with the reason). It reads `config.json`
again when it changes, so `start` with a new domain controller address needs no restart. Switching the package off stops the unit (the
core does that), which replaces the daemon's own 10 s look at the capability files.
`start` also stops the transient unit `hs-ad-selfservice` that version 0.2 left running, because it holds the port.

## Rules
- **TLS on every route.** `start` refuses unless a TLS route to `/password` exists: `reverseProxy = traefik-public` and a row `ok` for
  `ad-selfservice /password` in `hs sys services routes`. The local proxy has no TLS (`lan-https` does not exist), so in practice only public mode
  can start. The daemon also refuses any request whose peer is not a trusted proxy or whose `X-Forwarded-Proto` is not `https` (answer 403,
  audit result `plain-http`).
- **No admin credential, no stored secret.** The change is `smbpasswd -s -r <DC> -U <user>` with `old`, `new`, `new` on stdin: the DC checks the old
  password (SAMR over SMB3, signed and encrypted). Passwords never go through argv, the environment, a file or the journal. The CSRF key is random
  per process and only in memory.
- **Refused accounts:** Administrator, krbtgt, Guest (any case) get the usual "wrong user name or password" answer without a DC call. Domain
  Admins use `hs user`.
- **Limits** (in memory, lost on restart; bounded to 10000 keys): per account 3 failures in 900 s, per IP 5 in 900 s, 30 attempts in 60 s in all,
  and after each failure a growing delay `min(2**(n-1), 300)` s. A success resets the account and the IP. Every POST answer leaves after at least
  2 s, whatever the result. Lockout of the domain itself is the AD policy (`status` shows its threshold).
- **Answers:** one text for an unknown user, a wrong password, a locked or disabled account, so the account state never leaks. A policy refusal
  names only a rule from a fixed list. Everything else is "could not be changed right now" and never counts as done.
- **Audit:** one line per request, `audit<TAB>time<TAB>ip<TAB>user<TAB>result`, never a password. The service sends it as a `log` message and the core
  writes it to the journal of the unit (`info: audit...`); `hs ext ad-selfservice log` shows them.
- **Files** in `/var/lib/hs/ad-selfservice/`: `config.json` (port, DC address, realm, limits; no secret). "Wanted" in `--status` means: config.json
  exists and the core's marker `/var/lib/hs/ext-svc/ad-selfservice.stopped` does not.
- **Confinement is weaker on the network than in 0.2.** The transient unit allowed only the loopback and the domain controller
  (`IPAddressAllow`, `IPAddressDeny=any`), had a `DynamicUser`, `MemoryMax` and a system call filter. A core service unit is generated from the
  permissions, and `net` is declared only (D6 of docs/PLAN-extensions-access.md), so the service runs as root without capabilities and may
  connect anywhere. It still refuses to write anywhere but its state and /tmp.

## Not verified on hardware
the whole `hs-ext-svc@ad-selfservice` unit with its confinement (smbpasswd under `ProtectSystem=strict` and without capabilities), smbpasswd's prompt order and error texts for `-r` as a non-root user, the smb.conf option names on the NixOS Samba version, that Traefik keeps the
tunnel's `X-Forwarded-Proto: https`, the tunnel source address list (`/etc/hs/gateway-tunnel-from`), and whether `smbpasswd` is on the PATH of
`/run/current-system/sw/bin`. The tests use golden texts and fakes.
