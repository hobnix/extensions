#!/usr/bin/env python3
"""Rules for compiled programs in this repository (CONTRIBUTING.md "Rust extensions"). Python 3.11+, standard library only.

  binary-check.py check [--built DIR] [--release] [ROOT]
      ROOT = the repository (default: the folder above scripts/). Looks at extensions/* and examples/*.
      --built DIR   the output of scripts/rust-build.sh: a committed program must equal the one built from the source here
      --release     a program named in a [[binary]] table must be committed (the release pull request, into main)
  binary-check.py install CRATE_FOLDER BUILT_FILE
      copies the built program to the path of the [[binary]] table, sets the executable bit, writes the sha256 into package.toml
  binary-check.py guard --base-branch B --head-branch H [--base REV] [--head REV] [ROOT]
      a pull request that is not the release preparation (head release/prepare-*) or the release (into main) must not add or change a
      file named in a [[binary]] table, nor an executable file over 1 MB (REV defaults: origin/B, HEAD; compared from their merge base)
  binary-check.py report [--commit SHA] [ROOT]
      Markdown table of every committed [[binary]]: path, size, sha256 and the commit the program was built from (SHA, default HEAD)
  binary-check.py toolchain [--online] [--rustc "<rustc --version>"] [ROOT]
      the pinned Rust version (rust-toolchain.toml, the only place); --online checks that the release exists, --rustc that the compiler is it

A package declares its program in package.toml (the core's manifest has no field for it yet, it ignores the table):

  [[binary]]
  path = "bin/media-svc"                 # inside the package folder
  target = "x86_64-unknown-linux-musl"   # the only target for now
  sha256 = "<hex>"                       # written by scripts/rust-build.sh --install; empty until the release preparation
  bin = "media-svc"                      # the cargo bin name (default: the file name of path)

Rules: a compiled program (ELF, PE, Mach-O) lives only in a folder with a Cargo.toml and is named in [[binary]]; at most MAX_BYTES; the
executable bit is set in git; an x86-64 ELF without an interpreter (static); its sha256 is the one in package.toml and, with --built, the one
the build produced.
"""
import hashlib
import os
import re
import shutil
import stat
import subprocess
import sys
import tomllib

MAX_BYTES = 15 * 1024 * 1024
TARGET = "x86_64-unknown-linux-musl"
MAGIC = (b"\x7fELF", b"MZ", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")
SKIP = {"target", ".git", "__pycache__"}
SHA = re.compile(r"^[0-9a-f]{64}$")
GUARD_BYTES = 1024 * 1024
RELEASE_BRANCH = "release/prepare-"   # the branch scripts/dev/prepare-release.sh of the core makes
DIST = "https://static.rust-lang.org/dist/channel-rust-%s.toml"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def is_native(path):
    try:
        with open(path, "rb") as f:
            head = f.read(4)
    except OSError:
        return False
    return any(head.startswith(m) for m in MAGIC)


def elf_problem(path):
    """None for a static x86-64 ELF, else the reason."""
    with open(path, "rb") as f:
        h = f.read(64)
        if len(h) < 64 or h[:4] != b"\x7fELF":
            return "is not an ELF file"
        if h[4] != 2 or h[5] != 1:
            return "is not a 64-bit little-endian ELF"
        if int.from_bytes(h[18:20], "little") != 62:
            return "is not an x86-64 program"
        phoff = int.from_bytes(h[32:40], "little")
        phentsize = int.from_bytes(h[54:56], "little")
        phnum = int.from_bytes(h[56:58], "little")
        for i in range(phnum):
            f.seek(phoff + i * phentsize)
            if int.from_bytes(f.read(4), "little") == 3:   # PT_INTERP
                return "is dynamically linked (has an interpreter); NixOS cannot run it, build for " + TARGET
    return None


def git_mode(root, rel):
    """The file mode git records (e.g. 100755), or None when the file is not tracked."""
    try:
        r = subprocess.run(["git", "-C", root, "ls-files", "-s", "--", rel], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    parts = r.stdout.split()
    return parts[0] if r.returncode == 0 and parts else None


def executable(root, rel):
    mode = git_mode(root, rel)
    if mode is not None:
        return mode == "100755"
    return bool(os.stat(os.path.join(root, rel)).st_mode & stat.S_IXUSR)


def folders(root):
    for sub in ("extensions", "examples"):
        d = os.path.join(root, sub)
        if os.path.isdir(d):
            for n in sorted(os.listdir(d)):
                if os.path.isdir(os.path.join(d, n)):
                    yield f"{sub}/{n}"


def natives_in(folder):
    for base, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if d not in SKIP]
        for n in files:
            p = os.path.join(base, n)
            if not os.path.islink(p) and is_native(p):
                yield os.path.relpath(p, folder).replace(os.sep, "/")


def check(root, built=None, release=False):
    out = []
    for rel in folders(root):
        folder = os.path.join(root, rel)
        has_crate = os.path.isfile(os.path.join(folder, "Cargo.toml"))
        manifest = {}
        mf = os.path.join(folder, "package.toml")
        if os.path.isfile(mf):
            try:
                with open(mf, "rb") as f:
                    manifest = tomllib.load(f)
            except tomllib.TOMLDecodeError as e:
                out.append(f"{rel}: package.toml: {e}")
                continue
        decl = manifest.get("binary", [])
        if not isinstance(decl, list) or not all(isinstance(b, dict) for b in decl):
            out.append(f"{rel}: binary must be a list of [[binary]] tables")
            continue
        listed = {}
        for b in decl:
            p = b.get("path")
            if not isinstance(p, str) or not p or p.startswith("/") or ".." in p.split("/") or "\\" in p:
                out.append(f"{rel}: [[binary]] path {p!r} must be a relative path inside the package")
                continue
            listed[p] = b
        if decl and not has_crate:
            out.append(f"{rel}: has [[binary]] but no Cargo.toml: a program is built from a crate in the package folder")
        for p in natives_in(folder):
            if not has_crate:
                out.append(f"{rel}/{p}: compiled program in a package without Cargo.toml (only Rust extensions may ship one)")
            elif p not in listed:
                out.append(f"{rel}/{p}: compiled program not listed in a [[binary]] table of package.toml")
        for p, b in listed.items():
            where = f"{rel}/{p}"
            if b.get("target", TARGET) != TARGET:
                out.append(f"{where}: target must be {TARGET}")
            full = os.path.join(folder, p)
            if os.path.islink(full):
                out.append(f"{where}: a link, not a file")
                continue
            if not os.path.isfile(full):
                if release:
                    out.append(f"{where}: listed in package.toml but not committed (the release needs the program: scripts/rust-build.sh --install)")
                continue
            size = os.path.getsize(full)
            if size > MAX_BYTES:
                out.append(f"{where}: {size} bytes, the limit is {MAX_BYTES} (15 MB)")
            if not executable(root, f"{rel}/{p}"):
                out.append(f"{where}: executable bit not set (git update-index --chmod=+x)")
            reason = elf_problem(full)
            if reason:
                out.append(f"{where}: {reason}")
            want = b.get("sha256")
            have = sha256(full)
            if not isinstance(want, str) or not SHA.match(want):
                out.append(f"{where}: [[binary]] sha256 missing or not 64 hex digits (scripts/rust-build.sh --install writes it)")
            elif want != have:
                out.append(f"{where}: sha256 in package.toml is {want[:12]}..., the file is {have[:12]}...")
            if built:
                name = b.get("bin") or os.path.basename(p)
                bf = os.path.join(built, rel, name)
                if not os.path.isfile(bf):
                    out.append(f"{where}: no build output {bf} to compare with (is the crate built?)")
                elif sha256(bf) != have:
                    out.append(f"{where}: differs from the program built from the source here ({sha256(bf)[:12]}... vs {have[:12]}...)")
    return out


def install(crate, built_file):
    mf = os.path.join(crate, "package.toml")
    try:
        with open(mf, encoding="utf-8") as f:
            text = f.read()
        decl = tomllib.loads(text).get("binary", [])
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"{crate}: package.toml: {e}", file=sys.stderr)
        return 1
    name = os.path.basename(built_file)
    hit = [b for b in decl if (b.get("bin") or os.path.basename(str(b.get("path")))) == name]
    if len(hit) != 1:
        print(f"{crate}: package.toml needs exactly one [[binary]] for {name} (found {len(hit)}); not installing", file=sys.stderr)
        return 1
    dest = os.path.join(crate, hit[0]["path"])
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copyfile(built_file, dest)
    os.chmod(dest, 0o755)
    digest = sha256(dest)
    # rewrite the sha256 line inside this table only
    blocks = re.split(r"(?m)^(?=\[\[binary\]\]|\[)", text)
    for i, blk in enumerate(blocks):
        if blk.startswith("[[binary]]") and re.search(r'(?m)^path\s*=\s*"%s"' % re.escape(hit[0]["path"]), blk):
            if re.search(r"(?m)^sha256\s*=", blk):
                blk = re.sub(r'(?m)^sha256\s*=.*$', f'sha256 = "{digest}"', blk)
            else:
                blk = re.sub(r'(?m)^(path\s*=.*)$', lambda m: m.group(1) + f'\nsha256 = "{digest}"', blk, count=1)
            blocks[i] = blk
    with open(mf, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(blocks))
    print(f"installed {dest}  sha256 {digest}")
    print("also: git update-index --chmod=+x " + dest + "  (after git add, on a system without an executable bit)")
    return 0


def binary_paths(manifest_text, rel):
    """Repo-relative paths named in the [[binary]] tables of a package.toml text."""
    try:
        decl = tomllib.loads(manifest_text).get("binary", [])
    except tomllib.TOMLDecodeError:
        return set()
    return {f"{rel}/{b['path']}" for b in decl if isinstance(decl, list) and isinstance(b, dict) and isinstance(b.get("path"), str)}


def guard(root, base_branch, head_branch, base=None, head="HEAD"):
    """Problems of a pull request that is neither the release preparation nor the release."""
    if head_branch.startswith(RELEASE_BRANCH) or base_branch == "main":
        return []
    base = base or "origin/" + base_branch

    def run(*args):
        return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)
    mb = run("merge-base", base, head)
    if mb.returncode != 0:
        return [f"cannot find the merge base of {base} and {head}"]
    mb = mb.stdout.strip()
    diff = run("diff", "--name-status", "--no-renames", "-z", mb, head)
    if diff.returncode != 0:
        return [f"diff failed: {diff.stderr.strip()}"]
    parts = diff.stdout.split("\0")
    changed = [parts[i + 1] for i in range(0, len(parts) - 1, 2) if parts[i] != "D"]   # a deleted program is fine
    listed = set()
    for ref in (head, mb):   # a program named before or after the pull request
        for rel in run("ls-tree", "-d", "--name-only", ref, "extensions/", "examples/").stdout.split():
            r = run("show", f"{ref}:{rel}/package.toml")
            if r.returncode == 0:
                listed |= binary_paths(r.stdout, rel)
    out = []
    for p in changed:
        if p in listed:
            out.append(f"{p}: a program listed in [[binary]] is added or changed; only the release preparation (branch {RELEASE_BRANCH}*) commits programs")
            continue
        ls = run("ls-tree", "-l", head, "--", p).stdout.split()
        if len(ls) >= 4 and ls[0] == "100755" and ls[3].isdigit() and int(ls[3]) > GUARD_BYTES:
            out.append(f"{p}: an executable file of {ls[3]} bytes (over 1 MB) is added or changed; a program belongs to the release preparation")
    return out


def report(root, commit=None):
    head = commit or subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip() or "unknown"
    rows = []
    for rel in folders(root):
        try:
            with open(os.path.join(root, rel, "package.toml"), encoding="utf-8") as f:
                paths = sorted(binary_paths(f.read(), rel))
        except OSError:
            continue
        for p in paths:
            full = os.path.join(root, p)
            if os.path.isfile(full):
                rows.append(f"| `{p}` | {os.path.getsize(full)} | `{sha256(full)}` | `{head}` |")
    return rows


def pinned(root):
    with open(os.path.join(root, "rust-toolchain.toml"), "rb") as f:
        ch = tomllib.load(f).get("toolchain", {}).get("channel")
    if not isinstance(ch, str) or not re.fullmatch(r"\d+\.\d+\.\d+", ch):
        raise ValueError("rust-toolchain.toml: [toolchain] channel must be an exact version like 1.94.1 (not stable, not 1.94)")
    return ch


def toolchain(root, online, rustc):
    try:
        ch = pinned(root)
    except (OSError, tomllib.TOMLDecodeError, ValueError) as e:
        return [str(e)]
    out = []
    wf = os.path.join(root, ".github", "workflows")   # one place only: nothing else may name a version
    for n in sorted(os.listdir(wf)) if os.path.isdir(wf) else []:
        with open(os.path.join(wf, n), encoding="utf-8") as f:
            for i, line in enumerate(f, 1):
                if not line.lstrip().startswith("#") and re.search(r"RUSTUP_TOOLCHAIN|toolchain:\s*['\"]?\d|rustup (toolchain install|default) +\d", line):
                    out.append(f".github/workflows/{n}:{i}: names a toolchain; the version lives only in rust-toolchain.toml")
    if rustc is not None and not re.match(r"rustc %s " % re.escape(ch), rustc):
        out.append(f"the compiler is '{rustc.strip()}', rust-toolchain.toml pins {ch}")
    if online:
        import urllib.error
        import urllib.request
        try:
            urllib.request.urlopen(urllib.request.Request(DIST % ch, method="HEAD"), timeout=30).close()
        except urllib.error.HTTPError as e:
            out.append(f"Rust {ch} is not installable: {DIST % ch} answers {e.code}")
        except (urllib.error.URLError, OSError) as e:
            out.append(f"could not reach {DIST % ch} to check Rust {ch}: {e}")
    if not out:
        print(f"ok   pinned Rust {ch}" + (" (release exists)" if online else ""))
    return out


def other(cmd, rest):
    root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    o = {"online": False}
    while rest:
        a = rest.pop(0)
        if a == "--online":
            o["online"] = True
        elif a.startswith("--") and rest:
            o[a[2:]] = rest.pop(0)
        else:
            root = os.path.abspath(a)
    if cmd == "report":
        rows = report(root, o.get("commit"))
        if rows:
            print("| program | bytes | sha256 | built from commit |\n|---|---|---|---|")
            print("\n".join(rows))
        return 0
    if cmd == "guard":
        if "base-branch" not in o or "head-branch" not in o:
            print(__doc__, file=sys.stderr)
            return 2
        problems = guard(root, o["base-branch"], o["head-branch"], o.get("base"), o.get("head", "HEAD"))
        if not problems:
            print("ok   no program added or changed outside the release preparation")
    else:
        problems = toolchain(root, o["online"], o.get("rustc"))
    for p in problems:
        print("FAIL " + p)
    return 1 if problems else 0


def main(argv):
    if argv and argv[0] in ("guard", "report", "toolchain"):
        return other(argv[0], argv[1:])
    if not argv or argv[0] not in ("check", "install"):
        print(__doc__, file=sys.stderr)
        return 2
    if argv[0] == "install":
        if len(argv) != 3:
            print(__doc__, file=sys.stderr)
            return 2
        return install(argv[1], argv[2])
    built, release, root = None, False, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    rest = argv[1:]
    while rest:
        a = rest.pop(0)
        if a == "--built" and rest:
            built = rest.pop(0)
        elif a == "--release":
            release = True
        else:
            root = a
    problems = check(os.path.abspath(root), built, release)
    for p in problems:
        print("FAIL " + p)
    if not problems:
        print("ok   compiled programs: rules hold")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
