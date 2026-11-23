#!/usr/bin/env bash
# The binary step of the release preparation (hobnix/extensions#30, hobnix/core#1129). Run INSIDE the checkout, on the release branch that
# scripts/dev/prepare-release.sh of the core made (release/prepare-*), AFTER its version-bump commit:
#   scripts/prepare-binaries.sh [--push] [--no-pr] [<crate folder>...]
# 1. scripts/rust-build.sh --install: builds every crate twice with the pinned toolchain, stops when the two sha256 differ, copies the
#    program to the [[binary]] path and writes its sha256 into package.toml.
# 2. Refuses a changed program whose source did not change since the program was committed (the toolchain moved: that is its own pull request).
# 3. scripts/binary-check.py check --built: size limit, executable bit, static ELF, listed hash, equal to the build.
# 4. ONE commit with the programs and the hashes, apart from the version bump commit. Nothing is committed when nothing changed.
# 5. --push: pushes the branch. Unless --no-pr: appends the table (path, size, sha256, source commit) to the body of the open pull request of
#    this branch (gh), after the push. Without --push nothing leaves the machine. Needs: the tools of rust-build.sh, git, gh for step 5.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
pr=1; push=0; crates=()
while [ $# -gt 0 ]; do
  case $1 in
    --no-pr) pr=0; shift ;;
    --push) push=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) crates+=("${1%/}"); shift ;;
  esac
done
die() { echo "FAIL $*" >&2; exit 1; }

branch=$(git branch --show-current)
case $branch in release/prepare-*) ;; *) die "this runs on the release branch release/prepare-*, not on '$branch': a feature branch never commits a program" ;; esac
[ -z "$(git status --porcelain)" ] || die "the tree has uncommitted changes"
source_commit=$(git rev-parse HEAD)   # what the programs are built from: the bump commit changes versions, not crates

if [ ${#crates[@]} -eq 0 ]; then
  for f in extensions/*/Cargo.toml; do [ -f "$f" ] && crates+=("$(dirname "$f")"); done   # examples/ ships nothing
fi
if [ ${#crates[@]} -eq 0 ]; then echo "no Rust extension: no program to commit"; exit 0; fi

built=$(mktemp -d); trap 'rm -rf "$built"' EXIT
bash scripts/rust-build.sh --out "$built" --install "${crates[@]}" || die "build or install failed; nothing committed"

# a different program although no source changed since the last program commit = the toolchain or the build moved
bin_paths() {   # bin_paths <crate folder>: the [[binary]] paths, repo-relative
  python3 -I -c '
import sys, tomllib
c = tomllib.load(open(sys.argv[1] + "/package.toml", "rb"))
for b in c.get("binary", []): print(sys.argv[1] + "/" + b["path"])' "$1"
}
for crate in "${crates[@]}"; do
  for p in $(bin_paths "$crate"); do
    git diff --quiet -- "$p" && continue                       # unchanged program
    last=$(git log -1 --format=%H -- "$p")
    [ -n "$last" ] || continue                                 # first program of this crate
    if git diff --quiet "$last" HEAD -- "$crate" ":(exclude)$p" ":(exclude)$crate/package.toml" rust-toolchain.toml; then
      die "$p changed but nothing it is built from changed since ${last:0:7}: the build is not stable, or the toolchain moved (raise rust-toolchain.toml in its own pull request first). Nothing committed"
    fi
  done
done

python3 -I scripts/binary-check.py check --built "$built" || die "binary-check failed on the new programs; nothing committed"

if [ -z "$(git status --porcelain)" ]; then echo "ok   programs unchanged: no binary commit"; exit 0; fi
for crate in "${crates[@]}"; do
  git add -- "$crate/package.toml"
  for p in $(bin_paths "$crate"); do git add -- "$p"; git update-index --chmod=+x -- "$p"; done
done
[ -z "$(git diff --name-only; git ls-files -o --exclude-standard)" ] || die "files changed that are neither a program nor a package.toml; not committing"
git commit -q -s -m "Add built programs and their sha256 (source ${source_commit:0:12})" \
  -m "Built twice with the pinned toolchain, hashes equal, binary-check passed. Source commit: $source_commit."
echo "ok   binary commit made on $branch"

table=$(python3 -I scripts/binary-check.py report --commit "$source_commit")
printf '%s\n' "$table"
# push BEFORE the body names the programs: a body must never describe a commit that is not on the branch
if [ $push -eq 1 ]; then git push -q origin "HEAD:$branch" || die "the push failed"; fi
if [ $pr -eq 1 ]; then
  command -v gh >/dev/null || die "gh is not installed: add the table above to the pull request by hand"
  body=$(gh pr view "$branch" --json body --jq .body) || die "no open pull request for $branch"
  gh pr edit "$branch" --body "$body

## Programs (built from \`$source_commit\`, one commit apart from the version bump)
Each was built twice with the pinned toolchain (equal hashes) and passed \`scripts/binary-check.py\`. Nobody reviews a binary: to check one,
build the source commit with \`scripts/rust-build.sh\` and compare the sha256.

$table" >/dev/null || die "could not update the pull request body"
fi
