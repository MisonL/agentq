#!/usr/bin/env python3
"""Flag a raw redirect into a directory the SAME file fills with symlinks.

Why: `cat > "$dir/tool"` FOLLOWS a symlink.  A "stub PATH" fixture builds $dir
by symlinking the host's real binaries into it

    for entry in /bin/*; do
        name=${entry##*/}
        ln -s "$entry" "$D/$name"
    done

so a later raw write over one of those entries truncates the REAL binary the
link points at.  This repo paid for it twice: on a Linux CI host the heredoc
building smoke/11's stub_linux wrote THROUGH its link toward /usr/bin/loginctl
(the exclusion comment there records the incident), and on 2026-10-25 the same
shape -- built by a session-level fixture, not by a check -- truncated a
developer's Homebrew python3; for ~40 minutes every python3 on the machine
exited 0, printed nothing and did nothing, which read as a working interpreter.

The sanctioned writer is smoke/11's `write_stub`: it removes an existing symlink
BEFORE writing, so the stub lands as a regular file in the fixture directory and
the farm entry is replaced, never followed.

WHAT COUNTS AS A FARM (the whole precision of this rule): a `ln -s` whose
DESTINATION is exactly two components and BOTH are variables -- "$D/$X".  That
is the link-everything idiom above.  Every other symlink shape in this tree is
deliberately NOT a farm, each exclusion measured against the fixture that
provoked it -- a first draft that counted any symlink destination flagged every
ordinary `> "$work/out"` in smoke/05 and smoke/18:

    "$work/src-link"                literal component      smoke/11
    "$guard_path/sh"                literal component      smoke/05
    "$work/askpass-link"            literal component      smoke/05
    "$work/$side/data/x.json"       deeper than two        smoke/18, smoke/26

A function whose body links "$p/$X" with p bound from $1 (smoke/11's
build_stub_path) propagates: each "$VAR" argument at its call sites is a farm.

Usage:
    01-farm-write.py <root>        scan the repo's shell scripts, print hits
    01-farm-write.py --self-test   run the fixtures below through analyse()

Exit: 0 clean, 1 hits found, 2 self-test disagreement OR nothing enumerated, 3 crash
(a scan that looked at no files must not share the clean verdict).  smoke/01
invokes this file as its own source of truth, so the self-test exercises what
actually ships.
"""
import os
import re
import sys
import tempfile

# one line:  ln -s <src> "$D/$X"   with BOTH destination components variables
LINK = re.compile(r'\bln\s+-s\w*\s+[^|;&]*?"(\$[A-Za-z_]\w*)/(\$[A-Za-z_]\w*)"')
# any redirect into "$D/<something>" (fd redirects like 2> are included; the
# (?<![0-9]) keeps `1>&2`-style digits from splitting a match)
REDIR = re.compile(r'(?<![0-9])>>?\s*"?\$(\w+)/')
FUNC = re.compile(r'^([A-Za-z_]\w*)\s*\(\)\s*\{')
BINDS_1 = re.compile(r'\b([A-Za-z_]\w*)\s*=\s*\$1(?![0-9A-Za-z_])')


def analyse(text):
    """Return (farm_vars, [(lineno, line), ...])."""
    lines = text.split("\n")
    code = ["" if re.match(r"\s*#", l) else l for l in lines]
    farm = set()
    for l in code:
        for m in LINK.finditer(l):
            farm.add(m.group(1))
    # functions that turn their first argument into a farm directory:
    # a body that binds `p=$1` and then links "$p/$X" is a farm builder
    funcs = {}
    cur, param, confirmed = None, None, False
    for l in code:
        m = FUNC.match(l)
        if m:
            cur, param, confirmed = m.group(1), None, False
            continue
        if cur is None:
            continue
        if l.strip() == "}":
            if confirmed:
                funcs[cur] = param
            cur, param, confirmed = None, None, False
            continue
        if param is None:
            b = BINDS_1.search(l)
            if b:
                param = "$" + b.group(1)
        elif re.search(r'\bln\s+-s\w*\s', l) and '"' + param + '/$' in l:
            confirmed = True
    for l in code:
        for fn, p in funcs.items():
            m = re.search(
                r'(?<![A-Za-z0-9_])' + re.escape(fn) + r'\s+"(\$[A-Za-z_]\w*)"', l
            )
            if m:
                farm.add(m.group(1))
    # Aliases.  smoke/11 iterates `for stub in "$stub_bare" "$stub_pkgmgr"
    # "$stub_full"` and writes through "$stub/..." -- three sites.  Without this
    # propagation the lock is SILENT on them: measured 2026-10-25 by turning
    # `write_stub "$stub/uname"` back into `cat > "$stub/uname"` (exit 0, zero
    # hits).  A lock that misses the form the repo actually uses protects
    # nothing.  Narrow by construction: a `for` word counts only when it is
    # EXACTLY "$X"/$X with X already a farm (`"$work"/*` is a glob, not a
    # farm), and an assignment counts only when its right side is exactly a
    # farm reference.  Iterate to a fixpoint so chains (a -> b -> c) resolve.
    for _ in range(8):
        before = len(farm)
        for l in code:
            m = re.match(r"\s*for\s+([A-Za-z_]\w*)\s+in\s+(.+?)(?:\s*;\s*do\b.*)?$", l)
            if m:
                words = m.group(2).split()
                if any(w.strip('"') in farm for w in words):
                    farm.add("$" + m.group(1))
                continue
            m = re.match(
                r"\s*(?:local\s+|export\s+|readonly\s+)?([A-Za-z_]\w*)=(?:\"(\$[A-Za-z_]\w*)\"|(\$[A-Za-z_]\w*))\s*$",
                l,
            )
            if m:
                src = m.group(2) or m.group(3)
                if src in farm:
                    farm.add("$" + m.group(1))
        if len(farm) == before:
            break
    hits = []
    for n, l in enumerate(code, 1):
        if not l or "write_stub" in l:
            continue
        for m in REDIR.finditer(l):
            if "$" + m.group(1) in farm:
                hits.append((n, lines[n - 1].strip()))
                break
    return farm, hits


def walk(root):
    """Yield (path, group).  The group counts are a guard, not bookkeeping: a
    scan that enumerates nothing must not read as a clean tree (the same shape
    smoke/16 guards with its `tree_scanned -eq 0` arm, and smoke/01 with its
    empty-`shell_assets` refusal).  Measured 2026-10-25: pointing this script
    at an empty directory, at a nonexistent path, or at `/` all exited 0 with
    no output -- "clean" for a scan that looked at nothing."""
    for name in ("run-tests.sh", "sandbox.sh"):
        p = os.path.join(root, name)
        if os.path.isfile(p):
            yield p, "entry"
    for group, base in (
        ("smoke", os.path.join(root, "smoke")),
        ("assets", os.path.join(root, "skill", "assets")),
    ):
        for dirpath, _, files in os.walk(base):
            for f in sorted(files):
                p = os.path.join(dirpath, f)
                if f.endswith((".sh", ".bash")) or f in ("agentq", "agentq-server", "sshp"):
                    yield p, group


GROUPS = ("entry", "smoke", "assets")


def scan(root, quiet=False):
    """Return (rc, [(relpath, lineno, text), ...]).

    rc 0 = clean, 1 = hits, 2 = nothing to scan.  Exit 2 is deliberately not
    folded into 0: a broken enumeration and a clean tree must not share a
    verdict, and the caller (smoke/01) must be able to tell a classifier
    failure from a clean run.
    """
    hits = []
    seen = {}
    for path, group in walk(root):
        if path in seen:
            continue
        seen[path] = group
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        _, file_hits = analyse(text)
        for n, l in file_hits:
            hits.append((os.path.relpath(path, root), n, l))
    counts = {g: 0 for g in GROUPS}
    for group in seen.values():
        counts[group] += 1
    empty = [g for g in GROUPS if counts[g] == 0]
    if empty:
        if not quiet:
            print(
                "01-farm-write.py: enumerated no files for %s under %s -- a scan "
                "that looked at nothing must not report a clean tree"
                % (", ".join(empty), root),
                file=sys.stderr,
            )
        return 2, hits
    return (1 if hits else 0), hits


CASES = [
    # name, body, must_fire
    ("defect", 'D=$1\nfor entry in /bin/*; do\n    ln -s "$entry" "$D/$name"\ndone\ncat > "$D/mytool" <<\'STUB\'\n', True),
    ("sanctioned", 'D=$1\nfor entry in /bin/*; do\n    ln -s "$entry" "$D/$name"\ndone\nwrite_stub "$D/mytool" <<\'STUB\'\n', False),
    ("single-link", 'for entry in /bin/*; do\n    ln -s "$entry" "$work/src-link"\ndone\nprintf \'x\\n\' > "$work/out"\n', False),
    ("deep-path", 'for side in a b; do\n    ln -s "$target" "$work/$side/data/x.json"\ndone\nprintf \'y\\n\' > "$work/base/data/y.json"\n', False),
    ("via-function", 'fill() {\n    local d=$1\n    for e in /usr/bin/*; do\n        ln -s "$e" "$d/$n"\n    done\n}\nfill "$stubdir"\ncat > "$stubdir/tool" <<\'S\'\n', True),
    # smoke/11's real shape: the write goes through a LOOP ALIAS of the farm
    # directories.  Measured 2026-10-25: without alias propagation this was
    # silent on a genuine `cat >` regression at three sites.
    ("via-loop-alias", 'A=$1\nB=$2\nfor e in /usr/bin/*; do\n    ln -s "$e" "$A/$n"\n    ln -s "$e" "$B/$n"\ndone\nfor stub in "$A" "$B"; do\n    cat > "$stub/tool" <<\'S\'\ndone\n', True),
    ("via-alias-assignment", 'A=$1\nfor e in /usr/bin/*; do\n    ln -s "$e" "$A/$n"\ndone\nhere=$A\ncat > "$here/tool" <<\'S\'\n', True),
    # A glob over a farm is NOT a farm: "$A"/* has one literal component and the
    # expansion names real files, so a redirect into it follows nothing new.
    ("glob-over-farm", 'A=$1\nfor e in /usr/bin/*; do\n    ln -s "$e" "$A/$n"\ndone\nfor f in "$A"/*; do\n    printf x > "$f"\ndone\n', False),
]


def self_test():
    failed = []
    # The fixtures are the source of truth, so a case that disappears must be
    # caught too: renaming one is how a self-check quietly stops checking.
    # Measured during development -- renaming ("defect", ...) left this function
    # green while the detector still worked, and the reverse edit (disabling the
    # comparison) is invisible to any check inside this file.
    if len(CASES) < 5 or not any(c[2] for c in CASES) or not any(not c[2] for c in CASES):
        print("farm-write self-test: the fixture list lost a case or a "
              "direction (need >=5 cases with both fire and silent)",
              file=sys.stderr)
        return 2
    for name, body, must_fire in CASES:
        farm, hits = analyse(body)
        fired = bool(hits)
        if fired != must_fire:
            failed.append(
                "%s: expected %s, got %s (farm=%s hits=%s)"
                % (name, "fire" if must_fire else "silent",
                   "fire" if fired else "silent", sorted(farm), hits[:1])
            )
    # The enumeration guard is exercised through the SHIPPED scan(), on trees
    # built here: an empty directory and a tree holding only the two entry
    # points must both refuse to report clean.  Measured before the guard:
    # all three exited 0 with no output.
    tree_checks = 0
    with tempfile.TemporaryDirectory() as t:
        rc, _ = scan(t, quiet=True)
        tree_checks += 1
        if rc != 2:
            failed.append("empty tree: expected rc 2 (nothing enumerated), got %d" % rc)
        for name in ("run-tests.sh", "sandbox.sh"):
            with open(os.path.join(t, name), "w", encoding="utf-8") as fh:
                fh.write("#!/bin/sh\n")
        rc, _ = scan(t, quiet=True)
        tree_checks += 1
        if rc != 2:
            failed.append(
                "entry-points-only tree: expected rc 2 (no smoke/ or assets/ "
                "files), got %d" % rc
            )
    if tree_checks < 2:
        failed.append("the tree-enumeration fixtures lost a case")
    if failed:
        for f in failed:
            print("farm-write self-test: " + f, file=sys.stderr)
        return 2
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) != 2:
        print("usage: 01-farm-write.py <root> | --self-test", file=sys.stderr)
        return 2
    root = argv[1]
    rc, hits = scan(root)
    for rel, n, l in hits:
        print("%s:%d: %s" % (rel, n, l))
    return rc


if __name__ == "__main__":
    # Exit codes are a contract with smoke/01: 0 clean, 1 hits, 2 usage /
    # self-test disagreement / nothing enumerated.  An UNCAUGHT exception must
    # not exit 1 -- the caller reads 1 as "hits found", and a crash on the real
    # tree that the self-test never reaches would then report farm_writes=0
    # (measured 2026-10-25: a RuntimeError raised only for paths under
    # skill/assets passed --self-test and left smoke/01 green with 0 hits).
    # A Python SyntaxError exits 1 before any of this runs; the caller's
    # "exit 1 requires non-empty stdout" rule covers that side.
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except BaseException:
        import traceback

        traceback.print_exc()
        sys.exit(3)
