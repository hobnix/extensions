# Writing a package

1. One folder per package under `extensions/<name>/` with a `package.toml`:
   `name` (= folder), `version` (semver), `kind = "extension"`, `title`, `title_de`, `requires_core = ">=1"` (the API level of the core
   helpers it uses), `audience = "generic"` (or `"personal"`: hidden unless asked for).
2. `capability.toml` and `commands.tsv` describe the commands (`hs ext <name> <command>`), the web reads and the page; scripts are referenced as `@/file`.
3. Versions (hobnix/server#615): a pull request does not raise a version. It carries the label `bump: minor` (a feature) or `bump: major` (a person has to act); no label means patch, and at most one bump label (CI refuses two). The release preparation raises `version` in `package.toml` and `index.toml` together: the workflow `prepare-release` on `develop` (or `bash <core>/scripts/dev/prepare-release.sh`) takes the highest label of the merged pull requests per package and opens a pull request into `develop`; a version raised by hand since the last tag is kept, never raised twice. On the release pull request (into `main`) the check fails for every package whose folder changed since the last tag without a higher version in both files (`python3 <core>/scripts/pkg.py repo-unbumped <tag> .` runs the same check on your machine).
4. `python3 <core>/scripts/pkg.py validate` and `repo-check .` must pass (CI runs them against the core).
5. Work on a branch `feature/<topic>` or `fix/<topic>` started from `develop`, and open the pull request against `develop` (the default branch). `main` holds released versions only.
6. A release is a pull request from `develop` into `main`, merged with a merge commit (no squash), then a signed tag `vX.Y.Z` on the commit with the new index. The maintainer cuts it with the workflow `release` (Actions, branch `main`, the tag level the preparation names; the environment `release` asks for approval and holds the signing key), or with `bash <core>/scripts/dev/release.sh [patch|minor|major]` on `main` with the key on the maintainer's machine. Both run the same checks and verify the signature against the core's trusted keys.

## Rust extensions (a static program in the package)

Decision (hobnix/core#1129): a Rust extension ships a static musl program inside its package folder, for `x86_64-unknown-linux-musl` only. NixOS cannot run a dynamically linked program, and `hs pkg` installs the files of the signed tag as they are, so a committed static program needs nothing new in the core. A Python or shell extension has no program and is not affected.

1. The crate lives in the package folder: `extensions/<name>/Cargo.toml`, `Cargo.lock` (committed), `src/`. The SDK is `hobnix-ext-sdk` from hobnix/core, by git: `examples/rust-hello/Cargo.toml` shows how and why it is pinned by commit (the SDK is not published and no core tag has it yet). `examples/rust-hello` is an example only: it is not under `extensions/`, not in `index.toml`, and ships nothing.
2. The program is declared in `package.toml` (the core's manifest has no field for it yet and ignores this table; the rules below live in this repository):
   ```toml
   [[binary]]
   path = "bin/<name>"                    # inside the package folder; a service points `exec = "@/bin/<name>"` at it
   target = "x86_64-unknown-linux-musl"
   sha256 = "<hex>"                       # written by the script below
   bin = "<name>"                         # the cargo bin name (default: the file name of path)
   ```
3. `scripts/rust-build.sh [crate folder]` builds the crate **twice** (two target folders) with `--locked`, the toolchain of `rust-toolchain.toml`, a fixed `SOURCE_DATE_EPOCH`, stripped symbols and `--remap-path-prefix`, and fails when the two sha256 differ. It needs `rustup` and, for crates with C code, `musl-tools`. `--install` copies the program to `path`, sets the executable bit and writes the `sha256` into `package.toml`.
4. CI (`.github/workflows/rust.yml`, job `rust`) runs the same build with a cargo cache, then `scripts/binary-check.py check --built built`. The rules: a compiled program (ELF, PE, Mach-O) exists only in a folder with a `Cargo.toml` and is named in `[[binary]]`; at most 15 MB; executable bit set in the index; an x86-64 ELF with no interpreter (static); its sha256 is the one in `package.toml` and equals the program the build made from the source of this commit. On a pull request into `main` the program must also be committed. `tests/rust-binaries.sh` tests the rules without Rust.

### Committed program or release asset

| | Committed in the package folder | Release asset + sha256 in `package.toml` |
|---|---|---|
| Works with today's core | yes: the signed tag carries it and is the integrity check | no: `hs pkg` would need a download and hash step and a second trust path (a network change: owner decision) |
| History | every committed version stays for good. A stripped static program is about 2-4 MB (estimate, not measured), compresses to maybe 1-2 MB and deltas badly, so every clone pays about that much per commit of the program, per crate | none |
| Review | the bytes cannot be read; CI proves they equal the source | same |

**Recommendation: commit it, but only in the release preparation.** A feature pull request never commits a program: it changes source and `Cargo.lock`, CI builds it and proves it reproducible, and the build is kept as the workflow artifact `rust-programs`. The release preparation (the pull request that raises the versions) runs `scripts/rust-build.sh --install` and commits program and hash once per release, so the history grows by one program per crate per release, not per pull request. Never commit a rebuilt program when the source did not change: a different hash without a source change means the toolchain moved, so raise `rust-toolchain.toml` in its own pull request. If the history gets too heavy (rule of thumb: the clone has doubled), move to release assets, which needs core work first. Do not rewrite history to drop a program: that breaks the signed tags.
