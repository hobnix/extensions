# passthrough

Outside domains for other people's reverse proxies on the LAN: `<domain>` and `*.<domain>` from the internet are forwarded to an address on the LAN
(TLS passthrough by SNI on the public HTTPS entrypoint, plain HTTP by Host on the public HTTP entrypoint, optional PROXY protocol v2 toward the target).
An extension package (docs/PLAN-extensions.md) on top of the capability `gateway` (`requires`): `hs ext enable passthrough`, no rebuild, no Nix module.
Commands: commands.tsv (`ext passthrough list|status|add|remove|refresh`, `sys ext passthrough ...`). Web page: `/extensions/passthrough`
(declared in capability.toml, form web/src/forms/ops/PassthroughForm.svelte).

## Ports (decision of the user)
The router forwards the internet's 443 and 80 straight to this server. The public ports are options of the gateway, never hard-coded here:
`gatewayPublicHttps` (set 443) and `gatewayPublicHttp` (set 80), both 0 = off by default; 4443 and 8008 only behind a router that translates
ports. The route files read the ports from `/etc/hs/gateway-public` (knob `HS_GATEWAY_PUBLIC_FILE`). With `gatewayPublicHttp = 80` the HTTP
routers use the entrypoint `lan-http` (it is port 80), otherwise `public-http`. The web interface stays on its direct port 8480.

## Files
Route files `/var/lib/hs-gateway/routes/pt-<domain>.yml`, rendered by passthrough.py, written to `/var/lib/hs-gateway/tmp/` and `mv`d in (one bad YAML
freezes every update of Traefik). Line 1 is a header (`# hs-gateway passthrough v1 domain= address= https= http= proxy=`) and the ONLY thing read
back. Every `start` renders all `pt-*` files again from their headers (a changed gateway-public is picked up); `hs ext passthrough refresh` does only that.

## Rules
- Targets are private LAN addresses and never this server itself (its own `ip addr`), loopback, scope ids or non-LAN addresses (publish this server's own apps with `hs services`).
- An Incus container of this server (`incus list -c n46`) is refused by default and allowed only with `--container-ok` plus the typed domain (`--confirm <domain>`, on
  `start`; the web form sends `--container-ok` once the plan refuses and the CreateDialog asks for the typed name). Why: a reverse proxy (Zoraxy) in a container
  on the same server is a real setup. Security: the whole domain goes to that container and it is exposed to the internet on that domain; the plan says so in a warn
  row. Local routers of the gateway are unaffected: passthrough routes use only the public entrypoints and never reach them. `HS_PT_INSTANCE_ADDRS` is the csv of
  `incus list -c n46` (name first); bare `address (iface)` lines still work and give no name.
- Admin pages: a container target is refused when its https or http port, with the container's name, is in `ADMIN_TARGETS` (scripts/services.py, read with `ast`)
  or in the `warn` rows of `admin_builtin_dc1` in scripts/ports.sh (`monitoring:*` etc.; read as text, `/var/lib/hs/ports-admin` is not); never copied; unreadable = refused. A shared address (docker0) keeps all its names and each is checked.
- The container list fails closed: if `incus` is installed and `incus list` fails or times out, every target is refused ("cannot read the container list");
  only a missing `incus` binary counts as "no containers" (`HS_PT_INSTANCE_FAIL=1` simulates it). An unparsable csv is refused too.
- Static addresses: `incus list` shows no address for a stopped container, so `incus list --format json` is read too (`passthrough.py static-addrs`:
  `expanded_devices.*.ipv4.address` / `ipv6.address`) and treated like running addresses. Limit: a stopped container that gets its address by DHCP is unknown whenever it is
  stopped (no address to match), and routes are not rechecked when it starts. Because of that the route header records `container=yes` (after the typed
  confirmation; `list` keeps its 5 columns, `list --full` adds it) and `hs ext passthrough status` / `refresh` run `passthrough-change.sh plan --audit audit`:
  every route without that mark whose target now matches a container gets a warning. Give such containers a static address.
- "no public port": when `gatewayPublicHttps` is already non-zero in machine.toml (machine_get), the refusal says to run `hs rebuild` instead.
- Never a domain that overlaps `proxyDomains`, a host of the public reverse proxy, the gateway's local domain (`<site>.<realm>`), the AD realm,
  a `local-*` host or another `pt-*` domain (the same domain again replaces its target).
  Exception: the overlap with `proxyDomains` / hosts of the public reverse proxy is allowed when the target is exactly the container the public reverse proxy runs in
  (its provider's `info` key `container`, test knob `HS_PT_PROXY_CT`): its routes stay valid behind the passthrough. It needs `--container-ok` + confirm and the
  admin-port guard as always; the container is looked up in the default project only (`incus list --project default`, test knob `HS_PT_DEFAULT_ADDRS`); unknown proxy container or any other target = refused (`guard --target --instance-addrs --proxy-container`).
- Only `pt-*` files are written. No middleware on purpose: these routes are public. Only the public entrypoints are used.
- Passthrough routers have long rules and win over the catch-all of the gateway (priority 1); they match only their own domain and its subdomains.
- With a public port 80, 100.64.0.0/10 is dropped from the local allowlist (capabilities/gateway/module.nix; CGNAT clients would pass). If the router rewrites the source to its own LAN address everything looks local: the guide tells how to test from mobile data.
- Traefik keeps the real client address: PROXY protocol is never used on the entrypoint itself, only (per domain, off by default) toward the target,
  on HTTPS only. On HTTP the target gets X-Forwarded-For.
- Traefik 3.3+ may log `proxyProtocol` on a TCP service as deprecated; it is kept (not tested on hardware).
- Domains over 64 characters are refused (the web confirm limit).
