<p align="center"><img src=".github/branding/banner@2x.webp" alt="hobnix-extensions" width="100%"></p>

# hobnix-extensions

Packages for Hobnix, the home server (https://github.com/hobnix/server) — extensions: optional commands and pages for the server.

A package is a folder with a `package.toml` (name, semver `version`, `requires_core`), its scripts, translations and tests. `index.toml`
lists them. The server installs a package only from a release tag (`v1.2.3`) whose SSH signature verifies against the repository's
trusted key:

```
hs pkg fetch
hs pkg available
hs pkg install <name>
hs pkg update <name>
```

Packages run as root on the server: read the diff `hs pkg update` shows. Writing one: CONTRIBUTING.md.

## The name

**Hob** is a small, hairy, wizened household and farm spirit from the folklore of the English Midlands, Northern England and the
Anglo-Scottish border: the helper that quietly keeps the house running. **Nix** is NixOS, the operating system underneath. Hobnix is
the helper that keeps a NixOS home server running.

## AI was used here

Large parts of the code, the documentation and the tests of this project were written with the help of AI coding assistants. The
maintainer directs, reviews and tests the work, but not everything has been run on every kind of hardware, and AI-written code can be
wrong in ways that look right. Packages run as root on your server: read what you install (`hs pkg update` shows the diff), and report
what you find.

## Licence

MIT (see LICENSE). Contributions are accepted under the same licence.
