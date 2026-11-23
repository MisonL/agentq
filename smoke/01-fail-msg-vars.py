#!/usr/bin/env python3
"""Flag a `fail` message that expands a variable which is unset at that point.

Why this is a defect and not a style point: every shell asset runs under
`set -u`, and a MESSAGE is expanded BEFORE fail() runs.  So a message naming a
variable that has no value yet does not print an empty field -- it aborts the
shell.  At top level that skips fail()'s cleanup and its mandated
`reason=<class>` line; inside `$( )` the subshell exits 1, and callers READ
STATUS 1 AS "no matching task / record absent".  Measured 2026-11-22 (final
review round): one injected `jq -r length` failure inside find_request_task
made `submit` enqueue a DUPLICATE task for a request whose task was already
visible, and exit 0.  The message there was `fail "... AgentQ task: $task_id"`
where task_id is a caller local that was still empty.

Scope of the rule (deliberately narrow, both directions measured):

  * Only variables DECLARED `local` in the same function are judged.  A name
    that is never declared local is a deliberate global (initialised at the
    top of the script) or a positional parameter, and none of those are
    reported.
  * A reference with a default (`${var-}`, `${var:-...}`) is SAFE by
    construction and never reported -- that is the sanctioned spelling for a
    message that must name an identifier which may legitimately be unset.
  * A bare `$var` / `${var}` is reported when the first assignment to it in
    the function is (a) absent, (b) after the fail line, or (c) on the fail
    line itself before an `||`/`&&` -- the `x=$(cmd) || fail "... $x"` shape,
    where the failing command is exactly what would have set x.
  * An assignment EARLIER in the function is accepted as "set", even when it
    sits in one branch.  That direction can only MISS a site, never invent
    one; inventing one would redden a correct tree, which is worse.

Known blind spot, recorded rather than papered over: a function reading a
CALLER's local through bash's dynamic scope (find_request_task used to print
the caller's `$task_id`) has no local declaration here, so this rule cannot
see it.  The same review round converted every such message to the
`${task_id-}` spelling, and the behavioural lock in smoke/27 case S16 covers
the duplicate-enqueue consequence directly.

Invocations take a ROOT (the repository) and scan only files under
skill/assets whose shebang names a shell -- the same census smoke/01's
`shell=` count uses.  --self-test runs the SAME code against embedded
fixtures and is what keeps the rule from silently going blind.
"""

import glob
import os
import re
import sys

FUNC_START = re.compile(r"^([ \t]*)([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
# `local` may declare several names; `local x=$1` initialises at entry.
LOCAL_DECL = re.compile(r"^([ \t]*)local[ \t]+(.*)$")
VAR_REF = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)([:\-+]?[^}]*)\}|([A-Za-z_][A-Za-z0-9_]*))")
POSITIONAL = {"1", "2", "3", "4", "5", "6", "7", "8", "9", "@", "*", "#", "?", "$", "!", "-"}


def strip_comment(line):
    """Text before an unquoted-looking '#'.  A '#' inside a string is also cut;
    that direction can only miss a site, never invent one."""
    out = []
    quote = ""
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = ""
            out.append(ch)
            continue
        if ch in "\"'":
            quote = ch
            out.append(ch)
            continue
        if ch == "#" and (i == 0 or line[i - 1] in " \t;&|("):
            break
        out.append(ch)
    return "".join(out)


def logical_lines(lines):
    """Join backslash continuations: one logical line per returned entry, with
    the 1-based line number of its FIRST physical line."""
    merged = []
    i = 0
    while i < len(lines):
        start = i
        text = lines[i]
        while text.rstrip().endswith("\\") and i + 1 < len(lines):
            text = text.rstrip()[:-1] + " " + lines[i + 1]
            i += 1
        merged.append((start + 1, text))
        i += 1
    return merged


def functions(lines):
    """(name, first_line, last_line) for every function, nesting included."""
    stack = []
    found = []
    for number, line in enumerate(lines, 1):
        m = FUNC_START.match(line)
        if m:
            stack.append((m.group(2), number, len(m.group(1)), None))
            continue
        if stack and line.strip() == "}":
            name, start, _, _ = stack.pop()
            found.append((name, start, number))
    # Unclosed functions run to EOF.
    for name, start, _, _ in stack:
        found.append((name, start, len(lines)))
    return sorted(found, key=lambda f: f[1])


def assignments(text, lineno, decls, assigns):
    """Record assignments that are certain, not speculative."""
    # `if`/`elif`/`while`/`until` are assignment positions too: the tree
    # contains `if request_id=$(...); then`, and missing the keyword means
    # every such site reads as never-assigned (measured false positive on
    # validate_task_removal the day this rule was written).
    for m in re.finditer(r"(?:^|[;&|({]|\bthen\b|\bdo\b|\belse\b|\bif\b|\belif\b|\bwhile\b|\buntil\b)[ \t]*([A-Za-z_][A-Za-z0-9_]*)=", text):
        if m.group(1) in decls:
            assigns.setdefault(m.group(1), (lineno, m.start()))
    # A `read` variable ends the word list with a newline OR `;` (`while IFS=
    # read -r x; do` is one logical line).  Anchoring only on end-of-line
    # missed every read inside a while condition -- the same measured false
    # positive, in recover_removing_requests.
    for m in re.finditer(r"\b(?:read|readarray|mapfile)\b[^\n;]*?\b([A-Za-z_][A-Za-z0-9_]*)(?=\s*(?:;|$))", text):
        if m.group(1) in decls:
            assigns.setdefault(m.group(1), (lineno, m.start()))
    for m in re.finditer(r"\bfor[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]+in\b", text):
        if m.group(1) in decls:
            assigns.setdefault(m.group(1), (lineno, m.start()))


def scan_text(text, label):
    """Return a list of (label, lineno, function, variable) hits."""
    raw = text.split("\n")
    lines = [strip_comment(l) for l in raw]
    hits = []
    for name, start, end in functions(lines):
        body = lines[start - 1:end]
        decls = set()
        assigns = {}
        for offset, line in enumerate(body):
            lineno = start + offset
            m = LOCAL_DECL.match(line)
            if m:
                peeled = m.group(2)
                # Split on whitespace and semicolons; a name with '=' is an
                # inline initialisation and therefore assigned HERE.
                for part in re.split(r"[ \t;]+", peeled):
                    if not part or part.startswith("-"):
                        continue
                    var = part.split("=", 1)[0]
                    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", var):
                        continue
                    decls.add(var)
                    if "=" in part:
                        assigns.setdefault(var, (lineno, 0))
            assignments(line, lineno, decls, assigns)
        # Judge fail invocations over LOGICAL lines so a message split with
        # backslashes is read whole.
        logical = logical_lines(body)
        for offset, line in logical:
            lineno = start + offset - 1
            for fm in re.finditer(r"\bfail\b", line):
                tail = line[fm.end():]
                for vm in VAR_REF.finditer(tail):
                    braced, modifier, bare = vm.group(1), vm.group(2), vm.group(3)
                    var = braced or bare
                    if var is None or var in POSITIONAL:
                        continue
                    if braced is not None and modifier:
                        # ${var-...} / ${var:-...} / ${var:+...}: a default or
                        # alternative is spelled out -- safe under set -u.
                        continue
                    if var not in decls:
                        continue
                    first = assigns.get(var)
                    bad = False
                    if first is None:
                        bad = True
                    elif first[0] > lineno:
                        bad = True
                    elif first[0] == lineno and first[1] < (fm.start() + len("fail") + vm.start()):
                        between = line[first[1]:fm.start()]
                        if not re.search(r"[;]", between):
                            bad = True
                    if bad:
                        hits.append((label, lineno, name, var))
    return hits


def shell_assets(root):
    out = []
    for path in glob.glob(os.path.join(root, "skill", "assets", "*", "*")):
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "rb") as fh:
                first = fh.readline().decode("utf-8", "replace").strip()
        except OSError:
            continue
        if not first.startswith("#!"):
            continue
        interpreter = first.split()[-1] if first.split() else ""
        if interpreter.endswith("sh"):
            out.append(path)
    return sorted(out)


SELF_TEST_FIXTURES = [
    # (name, source, should_flag)
    ("declared-unassigned, bare reference", """\
f() {
    local x
    y=$(g) || fail "bad: $x"
}
""", True),
    ("declared-unassigned, braced reference", """\
f() {
    local x
    y=$(g) || fail "bad: ${x}"
}
""", True),
    ("default spelling is safe", """\
f() {
    local x
    y=$(g) || fail "bad: ${x-}"
}
""", False),
    ("colon-default spelling is safe", """\
f() {
    local x
    y=$(g) || fail "bad: ${x:-none}"
}
""", False),
    ("self-referencing assignment on the fail line", """\
f() {
    local x
    x=$(g) || fail "bad: $x"
}
""", True),
    ("assigned on an earlier line", """\
f() {
    local x
    x=$(g) || return 1
    fail "bad: $x"
}
""", False),
    ("inline local initialisation counts", """\
f() {
    local x=$1
    fail "bad: $x"
}
""", False),
    ("global (never local) is out of scope", """\
g() {
    fail "bad: $program $2"
}
""", False),
    ("assigned after the fail line", """\
f() {
    local x
    fail "bad: $x"
    x=1
}
""", True),
    ("loop variable is an assignment", """\
f() {
    local x
    for x in a b; do :; done
    fail "bad: $x"
}
""", False),
    ("comment mention does not assign", """\
f() {
    local x
    # x=1
    fail "bad: $x"
}
""", True),
    ("continued message is judged whole", """\
f() {
    local x
    fail "bad: " \\
        "$x"
}
""", True),
]


def self_test():
    failed = 0
    for name, source, want in SELF_TEST_FIXTURES:
        hits = scan_text(source, "<fixture>")
        got = bool(hits)
        if got != want:
            failed += 1
            print("self-test FAILED: %s (want flag=%s, got %s)"
                  % (name, want, hits), file=sys.stderr)
    if failed:
        print("%d self-test fixture(s) wrong" % failed, file=sys.stderr)
        return 1
    print("%d" % len(SELF_TEST_FIXTURES))
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) != 2:
        print("usage: %s <root> | --self-test" % os.path.basename(argv[0]), file=sys.stderr)
        return 2
    root = argv[1]
    assets = shell_assets(root)
    if not assets:
        print("no shell assets found under %s" % os.path.join(root, "skill", "assets"),
              file=sys.stderr)
        return 2
    total = 0
    for path in assets:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        if "fail" not in text:
            continue
        rel = os.path.relpath(path, root)
        for label, lineno, func, var in scan_text(text, rel):
            print("%s:%d: function %s expands unset $%s in a fail message"
                  % (label, lineno, func, var))
            total += 1
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
