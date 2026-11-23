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

exit $fail
