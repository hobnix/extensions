# ad-selfservice

A domain user changes their own AD password on a small web form (`https://<name>/password`). The service checks the old password against the DC with
the user's own credentials, holds no admin credential and no stored secret, and starts again after a reboot. An extension package
(docs/PLAN-extensions.md) on top of the capabilities `ad` and `gateway`: `hs ext enable ad-selfservice`, no rebuild, no Nix module.
Commands: commands.tsv (`ext ad-selfservice status|log|start|stop|expose`, `sys ext ad-selfservice ...`). Web page: `/extensions/ad-selfservice`.

## What runs
`selfservice.py serve` (Python standard library only) listens on 127.0.0.1:8486 as a transient systemd unit `hs-ad-selfservice`
(`systemd-run`, DynamicUser, no capabilities, IPAddressAllow only loopback and the DC). A NixOS package module would not be loaded from the
packages folder and no persistent unit file can be written on NixOS, so the core's boot unit `hs-ext-boot` runs `sys ext ad-selfservice boot`,
which starts the unit again when a person started it before (marker `wanted`, `stop` removes it). `hs ext disable` runs no package hook: the daemon
looks at the capability files every 10 s and exits when the package is off.

## Rules
- **TLS on every route.** `start` and the boot hook refuse unless a TLS route to `/password` exists: `reverseProxy = traefik-public` and a row `ok` for
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
- **Audit:** one line per request in the journal, `audit<TAB>time<TAB>ip<TAB>user<TAB>result`, never a password. `hs ext ad-selfservice log` shows them.
- **Files** in `/var/lib/hs/ad-selfservice/`: `config.json` (port, DC address, realm, limits; no secret), `wanted` (marker).

## Not verified on hardware
smbpasswd's prompt order and error texts for `-r` as a non-root user, the smb.conf option names on the NixOS Samba version, that Traefik keeps the
tunnel's `X-Forwarded-Proto: https`, the tunnel source address list (`/etc/hs/gateway-tunnel-from`), and whether `smbpasswd` is on the PATH of
`/run/current-system/sw/bin`. The tests use golden texts and fakes.
