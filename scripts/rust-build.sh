#!/usr/bin/env bash
# Builds the Rust crates of this repository as static musl programs and proves the build is reproducible.
#   scripts/rust-build.sh [--out DIR] [--install] [<crate folder>...]
# Crate folder = a folder with a Cargo.toml: extensions/<name> (the crate of a package) or examples/<name>. No folder given = all of them.
# Each crate is built TWICE, in two different target folders, and the sha256 of both programs must be equal (--locked, SOURCE_DATE_EPOCH, remapped paths).
# The program lands in DIR/<crate folder>/<bin name> (default DIR=built). --install copies it to the path the [[binary]] table of the package
# names, sets the executable bit and writes the sha256 into package.toml: the step of the release preparation, never of a feature pull request.
# Needs: cargo with the target x86_64-unknown-linux-musl (rust-toolchain.toml installs it), python3 (3.11+).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
out=built; install=0; crates=()
while [ $# -gt 0 ]; do
  case $1 in
    --out) out=$2; shift 2 ;;
    --install) install=1; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) crates+=("${1%/}"); shift ;;
  esac
done
if [ ${#crates[@]} -eq 0 ]; then
  for f in extensions/*/Cargo.toml examples/*/Cargo.toml; do [ -f "$f" ] && crates+=("$(dirname "$f")"); done
fi
if [ ${#crates[@]} -eq 0 ]; then echo "no Rust crate in this repository: nothing to build"; exit 0; fi

target=x86_64-unknown-linux-musl
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1700000000}   # fixed: the build must not depend on the day it runs
export CARGO_INCREMENTAL=0
python3 -I scripts/binary-check.py toolchain --rustc "$(rustc --version)" || exit 1   # the compiler must be the one rust-toolchain.toml pins
sysroot=$(rustc --print sysroot)
cargo_home=${CARGO_HOME:-$HOME/.cargo}

hash_of() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
bin_name() {   # the name of the first [[bin]] (or the package name) of the crate
  python3 -I -c '
import sys, tomllib
c = tomllib.load(open(sys.argv[1], "rb"))
bins = c.get("bin", [])
print(bins[0]["name"] if bins else c["package"]["name"])' "$1/Cargo.toml"
}
build_once() {   # build_once <crate folder> <target folder>: prints the sha256 of the program
  local crate=$1 tdir=$2
  # strip = no symbols; remap = the paths of the checkout, the cargo home and the toolchain become fixed names
  RUSTFLAGS="-C strip=symbols -C target-feature=+crt-static --remap-path-prefix=$here=/src --remap-path-prefix=$cargo_home=/cargo --remap-path-prefix=$sysroot=/rust" \
    cargo build --release --locked --target "$target" --manifest-path "$crate/Cargo.toml" --target-dir "$tdir" >&2
  hash_of "$tdir/$target/release/$(bin_name "$crate")"
}

bad=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for crate in "${crates[@]}"; do
  [ -f "$crate/Cargo.toml" ] || { echo "$crate: no Cargo.toml" >&2; bad=1; continue; }
  name=$(bin_name "$crate")
  h1=$(build_once "$crate" "$tmp/a/$crate")
  h2=$(build_once "$crate" "$tmp/b/$crate")
  if [ "$h1" != "$h2" ]; then
    echo "FAIL $crate: not reproducible, two builds differ ($h1 / $h2)" >&2; bad=1; continue
  fi
  mkdir -p "$out/$crate"
  cp "$tmp/a/$crate/$target/release/$name" "$out/$crate/$name"
  chmod 755 "$out/$crate/$name"
  echo "ok   $crate  $name  sha256 $h1"
  if [ $install -eq 1 ]; then python3 -I scripts/binary-check.py install "$crate" "$out/$crate/$name" || bad=1; fi
done
exit $bad
