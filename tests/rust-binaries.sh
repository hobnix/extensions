#!/usr/bin/env bash
# The rules for compiled programs (scripts/binary-check.py) on a throwaway git repository with hand-made ELF files. No Rust needed.
here=$(cd "$(dirname "$0")/.." && pwd)
chk="$here/scripts/binary-check.py"
command -v python3 >/dev/null && command -v git >/dev/null || exit 77
python3 -c 'import tomllib' 2>/dev/null || exit 77
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# elf <file> [interp]: a 64-bit x86-64 ELF header with one program header (PT_LOAD, or PT_INTERP when "interp" is given)
elf() {
  python3 -I -c '
import struct, sys
ptype = 3 if len(sys.argv) > 2 else 1
h = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8) + struct.pack("<HHIQQQIHHHHHH", 2, 62, 1, 0, 64, 0, 0, 64, 56, 1, 0, 0, 0)
ph = struct.pack("<IIQQQQQQ", ptype, 5, 0, 0, 0, 0, 0, 0)
open(sys.argv[1], "wb").write(h + ph + b"payload")' "$@"
}
sha() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# fresh <name>: a repository with a Rust package "p" (Cargo.toml, program bin/p) whose package.toml is right
fresh() {
  r="$t/$1"; mkdir -p "$r/extensions/p/bin"; git -C "$r" init -q
  : > "$r/extensions/p/Cargo.toml"
  elf "$r/extensions/p/bin/p"; chmod 755 "$r/extensions/p/bin/p"
  printf 'name = "p"\n[[binary]]\npath = "bin/p"\nsha256 = "%s"\n' "$(sha "$r/extensions/p/bin/p")" > "$r/extensions/p/package.toml"
  git -C "$r" add -A; git -C "$r" -c core.fileMode=true update-index --chmod=+x extensions/p/bin/p
}
run() { python3 -I "$chk" check "$@" 2>&1; }

fresh good
out=$(run "$r") && ok "a listed static program with its hash passes" || bad "good case refused: $out"

fresh nocargo; rm "$r/extensions/p/Cargo.toml"; git -C "$r" add -A
out=$(run "$r") && bad "program without Cargo.toml accepted" || { grep -q "without Cargo.toml" <<<"$out" && ok "program without Cargo.toml refused" || bad "wrong message: $out"; }

fresh unlisted; printf 'name = "p"\n' > "$r/extensions/p/package.toml"
out=$(run "$r") && bad "unlisted program accepted" || { grep -q "not listed" <<<"$out" && ok "unlisted program refused" || bad "wrong message: $out"; }

fresh hash; elf "$r/extensions/p/bin/p" x; git -C "$r" add -A
out=$(run "$r") && bad "changed program accepted" || { grep -q "sha256 in package.toml" <<<"$out" && ok "hash mismatch refused" || bad "wrong message: $out"; }

fresh nohash; printf 'name = "p"\n[[binary]]\npath = "bin/p"\n' > "$r/extensions/p/package.toml"
out=$(run "$r") && bad "program without a hash accepted" || { grep -q "sha256 missing" <<<"$out" && ok "missing hash refused" || bad "wrong message: $out"; }

fresh exec; git -C "$r" update-index --chmod=-x extensions/p/bin/p
out=$(run "$r") && bad "program without executable bit accepted" || { grep -q "executable bit" <<<"$out" && ok "missing executable bit refused" || bad "wrong message: $out"; }

fresh dyn; elf "$r/extensions/p/bin/p" interp
sed -i "s/sha256 = .*/sha256 = \"$(sha "$r/extensions/p/bin/p")\"/" "$r/extensions/p/package.toml"; git -C "$r" add -A
out=$(run "$r") && bad "dynamic program accepted" || { grep -q "dynamically linked" <<<"$out" && ok "dynamically linked program refused" || bad "wrong message: $out"; }

fresh big; python3 -I -c 'import sys; open(sys.argv[1],"ab").write(bytes(16*1024*1024))' "$r/extensions/p/bin/p"
sed -i "s/sha256 = .*/sha256 = \"$(sha "$r/extensions/p/bin/p")\"/" "$r/extensions/p/package.toml"; git -C "$r" add -A
out=$(run "$r") && bad "16 MB program accepted" || { grep -q "the limit is" <<<"$out" && ok "size limit refused" || bad "wrong message: $out"; }

fresh cmp; mkdir -p "$t/built/extensions/p"; elf "$t/built/extensions/p/p" x
out=$(run --built "$t/built" "$r") && bad "program differing from the build accepted" || { grep -q "differs from the program built" <<<"$out" && ok "committed program not equal to the build refused" || bad "wrong message: $out"; }
cp "$r/extensions/p/bin/p" "$t/built/extensions/p/p"
out=$(run --built "$t/built" "$r") && ok "committed program equal to the build passes" || bad "equal build refused: $out"

fresh rel; rm "$r/extensions/p/bin/p"; git -C "$r" add -A
out=$(run "$r") && ok "a declared program may be absent before the release" || bad "absent program refused: $out"
out=$(run --release "$r") && bad "release without the program accepted" || { grep -q "not committed" <<<"$out" && ok "release needs the program" || bad "wrong message: $out"; }

# install: copies, sets the bit, writes the hash
fresh inst; printf 'name = "p"\n[[binary]]\npath = "bin/p"\n' > "$r/extensions/p/package.toml"; elf "$t/new" x; mv "$t/new" "$t/p"
python3 -I "$chk" install "$r/extensions/p" "$t/p" >/dev/null && grep -q "sha256 = \"$(sha "$t/p")\"" "$r/extensions/p/package.toml" && ok "install writes the hash" || bad "install failed"

# guard: a pull request outside the release preparation adds no program and no big executable
g() { python3 -I "$chk" guard --base-branch develop --base base "$@" 2>&1; }
gfresh() {   # a repository with a commit "base" (a package with a crate and no program yet), then HEAD on a feature branch
  r="$t/$1"; mkdir -p "$r/extensions/p/src"; git -C "$r" init -q -b main
  : > "$r/extensions/p/Cargo.toml"; printf 'name = "p"\n[[binary]]\npath = "bin/p"\n' > "$r/extensions/p/package.toml"
  git -C "$r" add -A; git -C "$r" -c user.name=t -c user.email=t@t commit -q -m base; git -C "$r" branch base
  git -C "$r" checkout -q -b feat
}
gcommit() { git -C "$r" add -A; git -C "$r" -c user.name=t -c user.email=t@t commit -q -m change; }
gfresh g1; echo x > "$r/extensions/p/src/main.rs"; gcommit
out=$(g --head-branch feature/x "$r") && ok "guard: a source change passes" || bad "guard refused a source change: $out"
gfresh g2; mkdir "$r/extensions/p/bin"; elf "$r/extensions/p/bin/p"; chmod 755 "$r/extensions/p/bin/p"; gcommit
out=$(g --head-branch feature/x "$r") && bad "guard: a listed program in a feature PR accepted" || { grep -q "listed in \[\[binary\]\]" <<<"$out" && ok "guard: a listed program in a feature PR refused" || bad "wrong message: $out"; }
out=$(g --head-branch release/prepare-20260101-0000 "$r") && ok "guard: the release branch may carry the program" || bad "guard refused the release branch: $out"
out=$(python3 -I "$chk" guard --base-branch main --head-branch develop --base base "$r" 2>&1) && ok "guard: the release (into main) may carry it" || bad "guard refused the release PR: $out"
gfresh g3; python3 -I -c 'import sys; open(sys.argv[1],"wb").write(b"\x00"*(2*1024*1024))' "$r/tool"; chmod 755 "$r/tool"; git -C "$r" add tool; git -C "$r" update-index --chmod=+x tool; gcommit
out=$(g --head-branch feature/x "$r") && bad "guard: 2 MB executable accepted: $out" || { grep -q "over 1 MB" <<<"$out" && ok "guard: an executable over 1 MB refused" || bad "wrong message: $out"; }
gfresh g4; python3 -I -c 'import sys; open(sys.argv[1],"wb").write(b"\x00"*(2*1024*1024))' "$r/data.bin"; gcommit
out=$(g --head-branch feature/x "$r") && ok "guard: a big file without the executable bit passes" || bad "guard refused a data file: $out"
gfresh g5; printf 'name = "p"\n[[binary]]\npath = "bin/q"\n' > "$r/extensions/p/package.toml"; mkdir "$r/extensions/p/bin"; echo x > "$r/extensions/p/bin/q"; gcommit
out=$(g --head-branch feature/x "$r") && bad "guard: a program newly listed in the same PR accepted" || ok "guard: a program listed by the PR itself refused"

# report: path, size, sha256 and the commit
fresh rep; out=$(python3 -I "$chk" report "$r" 2>&1)
grep -q "extensions/p/bin/p" <<<"$out" && grep -q "$(sha "$r/extensions/p/bin/p")" <<<"$out" && ok "report lists path and sha256" || bad "report: $out"

# toolchain: one exact version, in rust-toolchain.toml only
tc() { python3 -I "$chk" toolchain "$@" 2>&1; }
mkdir -p "$t/tc/.github/workflows"; printf '[toolchain]\nchannel = "1.94.1"\n' > "$t/tc/rust-toolchain.toml"
out=$(tc --rustc "rustc 1.94.1 (abc 2026-03-25)" "$t/tc") && ok "toolchain: the pinned compiler passes" || bad "pinned compiler refused: $out"
out=$(tc --rustc "rustc 1.95.0 (abc 2026-03-25)" "$t/tc") && bad "toolchain: another compiler accepted" || ok "toolchain: another compiler refused"
printf '[toolchain]\nchannel = "stable"\n' > "$t/tc/rust-toolchain.toml"
out=$(tc "$t/tc") && bad "toolchain: channel stable accepted" || ok "toolchain: a floating channel refused"
printf '[toolchain]\nchannel = "1.94.1"\n' > "$t/tc/rust-toolchain.toml"; printf 'jobs:\n  a:\n    steps:\n      - uses: dtolnay/rust-toolchain@v1\n        with:\n          toolchain: 1.80.0\n' > "$t/tc/.github/workflows/x.yml"
out=$(tc "$t/tc") && bad "toolchain: a second pin in a workflow accepted" || ok "toolchain: a second pin in a workflow refused"
out=$(tc "$here") && ok "toolchain: this repository pins one version" || bad "this repository: $out"

exit $fail
