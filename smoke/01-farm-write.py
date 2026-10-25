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

Exit: 0 clean, 1 hits found, 2 self-test disagreement.  smoke/01 invokes this
file as its own source of truth, so the self-test exercises what actually ships.
"""
import os
import re
import sys

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
    for name in ("run-tests.sh", "sandbox.sh"):
        p = os.path.join(root, name)
        if os.path.isfile(p):
            yield p
    for base in (os.path.join(root, "smoke"), os.path.join(root, "skill", "assets")):
        for dirpath, _, files in os.walk(base):
            for f in sorted(files):
                p = os.path.join(dirpath, f)
                if f.endswith((".sh", ".bash")) or f in ("agentq", "agentq-server", "sshp"):
                    yield p


CASES = [
    # name, body, must_fire
    ("defect", 'D=$1\nfor entry in /bin/*; do\n    ln -s "$entry" "$D/$name"\ndone\ncat > "$D/mytool" <<\'STUB\'\n', True),
    ("sanctioned", 'D=$1\nfor entry in /bin/*; do\n    ln -s "$entry" "$D/$name"\ndone\nwrite_stub "$D/mytool" <<\'STUB\'\n', False),
    ("single-link", 'for entry in /bin/*; do\n    ln -s "$entry" "$work/src-link"\ndone\nprintf \'x\\n\' > "$work/out"\n', False),
    ("deep-path", 'for side in a b; do\n    ln -s "$target" "$work/$side/data/x.json"\ndone\nprintf \'y\\n\' > "$work/base/data/y.json"\n', False),
    ("via-function", 'fill() {\n    local d=$1\n    for e in /usr/bin/*; do\n        ln -s "$e" "$d/$n"\n    done\n}\nfill "$stubdir"\ncat > "$stubdir/tool" <<\'S\'\n', True),
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
    bad = 0
    for path in sorted(set(walk(root))):
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        _, hits = analyse(text)
        for n, l in hits:
            print("%s:%d: %s" % (os.path.relpath(path, root), n, l))
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
