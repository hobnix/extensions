#!/usr/bin/env python3
"""Checks, route files and list of the extension passthrough (capabilities/passthrough/NOTES.md), standard library only.

  passthrough.py domain <d>                           normalised domain (lower case), or refuse
  passthrough.py address <a> --host-addrs F --instance-addrs F [--container-ok yes] [--domain d]
                                                      [--https-port p] [--http-port p] [--admin-from services.py] [--ports-from ports.sh] [--dc-name n] [--ports-admin F] [--instance-failed yes]
                                                      a private LAN address that is not this server, or refuse; a container of this server
                                                      only with --container-ok (the refusal names it)
  passthrough.py container <a> --instance-addrs F     the name of the Incus instance that has this address, or exit 1
  passthrough.py port <p>                             1..65535
  passthrough.py guard <d> --proxy-domains a,b --local-domain x --realm r --proxy-hosts F --routes DIR
  passthrough.py render <d> <a> <https> <http|-> <on|off> <public-http port|0>    the route file on stdout
                                                      (public port 80 = the entrypoint lan-http itself, else public-http; 0 = no HTTP router)
  passthrough.py list <dir>                           domain address https http proxy (TAB, sorted, - for empty) of every pt-*.yml

Exit 0 = ok, 1 = refused (the reason is ONE line on stdout), 2 = usage. One YAML error freezes every update of Traefik, so
the files are only ever rendered here (golden tests, tests/passthrough.sh) and moved in atomically by the caller. Only line 1
of a file is read back, YAML is never parsed.
"""
import ast
import csv
import fnmatch
import ipaddress
import json
import os
import re
import sys

DOM = re.compile(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$')
BAD_ENDINGS = ('.local', '.lan', '.home.arpa', '.internal', '.localhost')
MAGIC = '# hs-gateway passthrough v1 '
HEADER = re.compile(r'^# hs-gateway passthrough v1 domain=(\S+) address=(\S+) https=([0-9]{1,5}) http=([0-9]{1,5}|-) proxy=(on|off)( container=yes)?$')
LOCAL_HEADER = re.compile(r'^# hs-gateway local v1 host=(\S+)')
PRIVATE_NETS = [ipaddress.ip_network(n) for n in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', 'fc00::/7')]


def refuse(msg):
    sys.stdout.write(msg + '\n')
    sys.exit(1)


def usage():
    sys.stderr.write(__doc__)
    sys.exit(2)


def norm_domain(d):
    if d != d.strip():
        refuse('the domain has spaces or a line break around it')
    d = d.lower()
    if len(d) > 64:
        refuse('%s is longer than 64 characters' % d[:64])
    if '*' in d:
        refuse('give the domain without a wildcard: its subdomains are forwarded anyway')
    if '.' not in d:
        refuse("'%s' is a single name: give a domain such as example.com" % d)
    if not DOM.fullmatch(d):
        refuse("'%s' is not a domain name (letters, digits, - and dots)" % d)
    for e in BAD_ENDINGS:
        if d.endswith(e):
            refuse('%s is a name for the home network, not for the internet' % d)
    return d


def parse_ip(s):
    if '%' in s or not re.fullmatch(r'[0-9a-fA-F:.]+', s):   # a scope id (fe80::1%eth0) takes any character: never accepted
        return None
    try:
        return ipaddress.ip_address(s)
    except ValueError:
        return None


def addrs_of(path):
    """every IP address found in a file (ip -o addr show, incus list csv, one per line): tokens are tried one by one"""
    out = set()
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            text = f.read()
    except OSError:
        return out
    for tok in re.split(r'[\s",;()]+', text):
        tok = tok.split('/')[0]
        ip = parse_ip(tok)
        if ip is not None:
            out.add(ip)
    return out


NAME = re.compile(r'^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$')


def inst_names(path):
    """-> (address -> instance name, readable) from `incus list --format csv -c n46` (name, then cells with one 'address (iface)'
    per line). A record whose first cell is itself an address has no name (older test files): the name is then ''.
    readable is False when a non-empty line is neither that nor 'name' with empty cells: the caller then refuses (fail closed)."""
    out = {}
    try:
        with open(path, encoding='utf-8', errors='replace', newline='') as f:
            rows = list(csv.reader(f, strict=True))
    except OSError:
        return out, True          # no list at all (incus not installed): nothing to match
    except csv.Error:
        return out, False
    for row in rows:
        if not any(c.strip() for c in row):
            continue
        name, cells = '', row
        if not any(parse_ip(t.split('/')[0]) for t in re.split(r'[\s",;()]+', row[0])):
            name, cells = row[0].strip(), row[1:]
            if not NAME.match(name) or not cells:
                return out, False
        found = False
        for cell in cells:
            for tok in re.split(r'[\s",;()]+', cell):
                ip = parse_ip(tok.split('/')[0])
                if ip is not None:
                    if (name or '?') not in out.setdefault(ip, []):   # one address, several names (docker0 is listed by many)
                        out[ip].append(name or '?')
                    found = True
        if not found and any(c.strip() for c in cells):
            return out, False
    return out, True


def container_of(a, inst_file):
    """names of the instances that have this address (['?'] when unknown), or None"""
    ip = parse_ip(a)
    names, _ = inst_names(inst_file)
    if ip is None:
        return None
    if ip in names:
        return names[ip]
    return ['?'] if ip in addrs_of(inst_file) else None


def static_addrs(json_file):
    """csv rows 'name,address,' for the static addresses in the devices of every instance (a stopped container shows none in
    `incus list`); `incus list --format json` -> expanded_devices.*.ipv4.address / ipv6.address. Exit 1 when it is no such JSON."""
    try:
        with open(json_file, encoding='utf-8') as f:
            data = json.load(f)
        rows = []
        for inst in data:
            for dev in (inst.get('expanded_devices') or {}).values():
                for key in ('ipv4.address', 'ipv6.address'):
                    v = dev.get(key) if isinstance(dev, dict) else None
                    if not isinstance(v, str):
                        continue
                    for part in v.split(','):   # routed / ipvlan NICs take a list; 'none' (ipv4.address=none) = no static address
                        part = part.strip().split('/')[0]
                        if parse_ip(part) is not None:
                            rows.append((str(inst['name']), part))
        return rows
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return None


PORTS_ROW = re.compile(r"printf '([^\\']+)\\t([^\\']+)\\t[^']*\\t(warn|info)\\n'")
PORTS_FUNC = re.compile(r'^admin_builtin_dc1\(\) \{\n(.*?)^\}', re.M | re.S)


def admin_targets(services_py, ports_sh, dc_name='dc1', user_file=''):
    """-> (set of (container, port) from ADMIN_TARGETS in scripts/services.py, read with ast; list of (container glob, port spec) of the
    'warn' rows of admin_builtin_dc1 in scripts/ports.sh with dc1 renamed to dc_name (what ports.sh does), plus the rows of the user file
    ports-admin that ports.sh reads too). The files are only read, never run or imported. None (= refuse) when anything cannot be read or
    parsed: one unparsable row, a missing row that exists today (zoraxy:8000, monitoring:*), a bad user row."""
    try:
        pairs = None
        with open(services_py, encoding='utf-8') as f:
            tree = ast.parse(f.read())
        for node in tree.body:
            if isinstance(node, ast.Assign) and any(getattr(t, 'id', '') == 'ADMIN_TARGETS' for t in node.targets):
                pairs = {(str(c).lower(), int(p)) for c, p in ast.literal_eval(node.value)}
        with open(ports_sh, encoding='utf-8') as f:
            m = PORTS_FUNC.search(f.read())
        if pairs is None or not m:
            return None
        rules = []
        for line in m.group(1).split('\n'):
            line = line.strip()
            if not line:
                continue
            r = PORTS_ROW.fullmatch(line)
            if not r:
                return None
            w, spec, sev = r.groups()
            if w == 'dc1':
                w = dc_name
            if w != 'host' and sev == 'warn':
                rules.append((w.lower(), spec))
        if ('zoraxy', '8000') not in rules or ('monitoring', '*') not in rules:
            return None
        if user_file and os.path.exists(user_file):
            with open(user_file, encoding='utf-8') as f:
                for line in f.read().split('\n'):
                    t = line.split()
                    if not t or t[0].startswith('#'):
                        continue
                    if len(t) < 3:
                        return None
                    if t[-1] != 'info':
                        rules.append((t[0].lower(), t[1]))
        return pairs, rules
    except (OSError, SyntaxError, ValueError, TypeError):
        return None


def in_spec(port, spec):
    if spec == '*':
        return True
    m = re.fullmatch(r'([0-9]+)(?:-([0-9]+))?', spec)
    return bool(m) and int(m.group(1)) <= port <= int(m.group(2) or m.group(1))


def is_admin(name, port, tables):
    pairs, rules = tables
    name = name.lower()
    return (name, port) in pairs or any(fnmatch.fnmatchcase(name, w) and in_spec(port, spec) for w, spec in rules)


def check_address(a, host_file, inst_file, container_ok=False, domain='', ports=(), admin_file='', inst_failed=False, ports_file='', dc_name='dc1', user_file=''):
    ip = parse_ip(a)
    if ip is None:
        refuse("'%s' is not an IP address" % a)
    if ip.is_loopback or ip.is_link_local or ip.is_unspecified or ip.is_multicast or not any(ip in n for n in PRIVATE_NETS):
        refuse('targets must be private LAN addresses (10.x, 172.16-31.x, 192.168.x, fc00::/7)')
    names, readable = inst_names(inst_file)
    if inst_failed:
        refuse('cannot read the container list (incus failed or did not answer in time), so this address cannot be checked: try again')
    if not readable:
        refuse('the list of containers of this server cannot be read, so this address cannot be checked: try again, or check incus')
    if ip in addrs_of(host_file):
        refuse("that is this server: publish this server's own apps with hs services")
    cname = container_of(a, inst_file)
    if cname is not None:
        if not container_ok:
            refuse("that is the container '%s' of this server: to forward a domain to it, confirm with --container-ok --confirm %s"
                   % (', '.join(cname), domain or '<domain>'))
        msg = admin_refusal(cname, ports, admin_file, ports_file, dc_name, user_file)
        if msg:
            refuse(msg)
    return str(ip)


def admin_refusal(cname, ports, admin_file, ports_file, dc_name, user_file):
    """the refusal text when a container (list of names) may not be a target on these ports, else None"""
    admin = admin_targets(admin_file, ports_file, dc_name, user_file)
    if admin is None:
        return 'the list of admin pages (scripts/services.py) cannot be read, so a container cannot be forwarded to'
    if '?' in cname:
        return 'the name of the container with this address is unknown, so it cannot be checked against the admin pages'
    for port in ports:
        hit = [n for n in cname if is_admin(n, int(port), admin)]
        if hit:
            return ("the container '%s' on port %s is an admin page: it is never forwarded to the internet (ADMIN_TARGETS in scripts/services.py)"
                    % (', '.join(hit), port))
    return None


def check_port(p):
    if not re.fullmatch(r'[0-9]{1,5}', p) or not 1 <= int(p) <= 65535:
        refuse("'%s' is not a port (1 to 65535)" % p)
    return str(int(p))


def related(a, b):
    return a == b or a.endswith('.' + b) or b.endswith('.' + a)


def read_header(path, pat):
    try:
        with open(path, encoding='utf-8') as f:
            return pat.match(f.readline().rstrip('\n'))
    except OSError:
        return None


def list_rows(d):
    rows = []
    for name in sorted(os.listdir(d) if os.path.isdir(d) else []):
        if not (name.startswith('pt-') and name.endswith('.yml')):
            continue
        m = read_header(os.path.join(d, name), HEADER)
        if m:
            g = m.groups()
            rows.append(g[:5] + ('yes' if g[5] else '-',))
    rows.sort()
    return rows


def guard(d, opts):
    # the public reverse proxy itself as the target (its container, known from its provider): its routes stay valid behind the passthrough
    pct = opts.get('--proxy-container', '').strip()
    own = pct != '' and container_of(opts.get('--target', ''), opts.get('--instance-addrs', os.devnull)) == [pct]
    unless = ', unless the target is the public reverse proxy itself'
    for p in [x for x in opts.get('--proxy-domains', '').split(',') if x.strip()]:
        if not own and related(d, p.strip().lower()):
            refuse('%s overlaps %s, a domain of the public reverse proxy%s' % (d, p.strip().lower(), unless))
    for key, what in (('--local-domain', "the gateway's local domain"), ('--realm', 'the domain of the network (AD realm)')):
        x = opts.get(key, '').strip().lower()
        if x and related(d, x):
            refuse('%s overlaps %s (%s): nothing under it is forwarded from the internet' % (d, x, what))
    try:
        with open(opts.get('--proxy-hosts', os.devnull), encoding='utf-8') as f:
            hosts = [h.strip().lower() for h in f.read().split() if h.strip()]
    except OSError:
        hosts = []
    for h in hosts:
        h = h.lstrip('*.')
        if h and not own and related(d, h):
            refuse('%s overlaps %s, a host of the public reverse proxy%s' % (d, h, unless))
    routes = opts.get('--routes', '')
    for row in list_rows(routes):
        if row[0] != d and related(d, row[0]):
            refuse('%s overlaps %s, which is forwarded already' % (d, row[0]))
    for name in sorted(os.listdir(routes) if os.path.isdir(routes) else []):
        if name.startswith('local-') and name.endswith('.yml'):
            m = read_header(os.path.join(routes, name), LOCAL_HEADER)
            if m and related(d, m.group(1)):
                refuse('%s overlaps %s, a local name of the gateway proxy' % (d, m.group(1)))


def hostport(a, port):
    return ('[%s]:%s' % (a, port)) if ':' in a else ('%s:%s' % (a, port))


def render(d, a, https, http, proxy, pub_http, container=False):
    # defensive: whatever calls this, only these shapes ever reach the YAML
    if not DOM.fullmatch(d) or len(d) > 64 or parse_ip(a) is None or str(parse_ip(a)) != a:
        raise ValueError('bad domain or address')
    for p in (https, http):
        if p != '-' and not re.fullmatch(r'[0-9]{1,5}', p):
            raise ValueError('bad port')
    did = d.replace('.', '-')
    esc = d.replace('.', '\\.')
    out = ['%sdomain=%s address=%s https=%s http=%s proxy=%s%s' % (MAGIC, d, a, https, http, proxy, ' container=yes' if container else ''),
           '# written by hs ext passthrough; do not edit',
           'tcp:', '  routers:', '    pt-%s:' % did, '      entryPoints: [public-https]',
           "      rule: 'HostSNI(`%s`) || HostSNIRegexp(`^.+\\.%s$`)'" % (d, esc),
           '      tls:', '        passthrough: true', '      service: pt-%s' % did,
           '  services:', '    pt-%s:' % did, '      loadBalancer:', '        servers:',
           "          - address: '%s'" % hostport(a, https)]
    if proxy == 'on':
        out += ['        proxyProtocol:', '          version: 2']
    if http != '-' and pub_http != '0':
        entry = 'lan-http' if pub_http == '80' else 'public-http'
        out += ['http:', '  routers:', '    pt-%s-http:' % did, '      entryPoints: [%s]' % entry,
                "      rule: 'Host(`%s`) || HostRegexp(`^.+\\.%s$`)'" % (d, esc), '      service: pt-%s-http' % did,
                '  services:', '    pt-%s-http:' % did, '      loadBalancer:', '        passHostHeader: true', '        servers:',
                "          - url: 'http://%s'" % hostport(a, http)]
    return '\n'.join(out) + '\n'


def options(argv):
    opts, i = {}, 0
    while i < len(argv):
        if argv[i].startswith('--') and i + 1 < len(argv):
            opts[argv[i]] = argv[i + 1]
            i += 2
        else:
            usage()
    return opts


def main(argv):
    if len(argv) < 2:
        usage()
    cmd, rest = argv[1], argv[2:]
    sys.stdout.reconfigure(newline='\n')   # the same bytes on every platform (a CRLF would end up in the route files)
    if cmd == 'domain' and len(rest) == 1:
        print(norm_domain(rest[0]))
    elif cmd == 'address' and len(rest) % 2 == 1 and len(rest) >= 5:
        o = options(rest[1:])
        print(check_address(rest[0], o.get('--host-addrs', os.devnull), o.get('--instance-addrs', os.devnull),
                            o.get('--container-ok') == 'yes', o.get('--domain', ''),
                            [p for p in (o.get('--https-port', '-'), o.get('--http-port', '-')) if p.isdigit()], o.get('--admin-from', ''), o.get('--instance-failed') == 'yes', o.get('--ports-from', ''), o.get('--dc-name', 'dc1'), o.get('--ports-admin', '')))
    elif cmd == 'container' and len(rest) == 3:
        n = container_of(rest[0], options(rest[1:]).get('--instance-addrs', os.devnull))
        if n is None:
            sys.exit(1)
        print(', '.join(n))
    elif cmd == 'static-addrs' and len(rest) == 1:
        rows = static_addrs(rest[0])
        if rows is None:
            sys.exit(1)
        sys.stdout.reconfigure(newline='\n')
        w = csv.writer(sys.stdout, lineterminator='\n')
        for name, ip in rows:
            w.writerow([name, ip, ''])
    elif cmd == 'admin-check' and len(rest) % 2 == 1:   # admin-check <address> --instance-addrs F --https-port --http-port --admin-from ...: exit 1 + text when it is an admin container
        o = options(rest[1:])
        cn = container_of(rest[0], o.get('--instance-addrs', os.devnull))
        if cn is not None:
            msg = admin_refusal(cn, [p for p in (o.get('--https-port', '-'), o.get('--http-port', '-')) if p.isdigit()], o.get('--admin-from', ''),
                                o.get('--ports-from', ''), o.get('--dc-name', 'dc1'), o.get('--ports-admin', ''))
            if msg:
                refuse(msg)
    elif cmd == 'port' and len(rest) == 1:
        print(check_port(rest[0]))
    elif cmd == 'guard' and len(rest) >= 1 and len(rest) % 2 == 1:
        guard(norm_domain(rest[0]), options(rest[1:]))
    elif cmd == 'render' and len(rest) in (6, 7):
        d, a, https, http, proxy, pub = rest[:6]
        if len(rest) == 7 and rest[6] != 'container':
            usage()
        if not DOM.fullmatch(d) or parse_ip(a) is None or proxy not in ('on', 'off') or not re.fullmatch(r'[0-9]{1,5}', pub):
            usage()
        check_port(https)
        if http != '-':
            check_port(http)
        if chr(10) in a or parse_ip(a) is None:
            usage()
        try:
            sys.stdout.write(render(d, str(parse_ip(a)), https, http, proxy, pub, len(rest) == 7))
        except ValueError:
            usage()
    elif cmd == 'list' and len(rest) in (1, 2) and (len(rest) == 1 or rest[1] == '--full'):
        for row in list_rows(rest[0]):   # the 5 columns are a contract with the web interface; --full adds container (yes|-)
            sys.stdout.write('\t'.join(row if len(rest) == 2 else row[:5]) + '\n')
    else:
        usage()


if __name__ == '__main__':
    main(sys.argv)
