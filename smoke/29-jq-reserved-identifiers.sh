#!/usr/bin/env bash
# Smoke: no jq program the server runs may use a jq RESERVED WORD as an
# identifier.  jq 1.6 lexes a set of words as keywords (label, and, or, if,
# then, else, end, reduce, foreach, try, catch, as, def, import, include,
# module, null, true, false, break, __loc__...); using one where the grammar
# wants an identifier is a COMPILE error, and only 1.7 relaxed that.
#
# Why this is its own check, and why it is behavioural.  Measured, real:
#
#   jq 1.6 (el9 / RHEL / Rocky / Fedora / Debian 11 / Ubuntu 20.04-22.04)
#       jq -n --arg label x '{label: $label}'   -> syntax error, 1 compile error
#       jq -n '{label, id}'                     -> syntax error
#       jq -n '{label: 1}'                      -> {"label":1}   (key: expr is fine)
#   jq 1.7.1
#       all three succeed
#
# The server used `--arg label` / `$label` in request_payload and object
# shorthand `label,` in the status compaction filter.  On any jq-1.6 host this
# made request_payload a compile error, so `submit` fell through with
# payload=null and STILL EXITED 0 -- writing a request record that
# request_record_filter then rejected, so lookup/wait/cancel on that id all
# failed and `status` exited 3.  Every command on that host was affected.
#
# No local check could see it: the host jq is 1.7, which accepts all three
# forms, so running the server here is green regardless.  The defect exists
# only under a jq this repo never runs -- so, exactly like smoke/09 models
# PowerShell 5.1 and smoke/08 captures jq argv, this check inspects the jq
# PROGRAM TEXT the server actually hands to jq.  It does not run jq 1.6; it
# refuses the SHAPE that only 1.7 accepts and 1.6 rejects.
#
# What it proves: no jq program the server executes (over the whole command
# surface, including the request-record and cancellation paths) uses a reserved
# word in an identifier position -- as an --arg/--argjson name, a $variable, an
# `as $var` binding, or an object shorthand key.  What it does not prove: that
# some OTHER jq version quirk does not bite, or anything about jq filters the
# driven command surface never reaches (client-side filters, Windows-only
# branches).  The classifier is calibrated by self-test against measured jq
# verdicts (see CALIBRATION below); if the classifier is edited, the self-test
# fails rather than silently changing what this check accepts.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/agentq-smoke-jqreserved.XXXXXX")
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

real_jq=$(command -v jq) || {
    printf 'jq-reserved-identifiers: jq is required to run this check\n' >&2
    exit 1
}

# Record argv NUL-separated, then behave exactly like jq.  Each invocation ends
# with an extra NUL (so invocations are separable) -- the same shim smoke/08
# uses, which is proven to capture this server's jq traffic.
mkdir -p "$work/shim"
cat > "$work/shim/jq" <<SHIM
#!/bin/sh
{
    for arg in "\$@"; do
        printf '%s\\0' "\$arg"
    done
    printf '\\0'
} >>"$work/jq-argv"
exec "$real_jq" "\$@"
SHIM
chmod 700 "$work/shim/jq"
PATH="$work/shim:$PATH"
export PATH
: >"$work/jq-argv"

# A minimal runtime the server accepts, with Pueue stubs that answer the JSON
# queries so the jq calls downstream are actually reached.  Copied from
# smoke/08: a stub that only prints a version string would leave whole jq
# programs (status compaction, record scanning) unexecuted, and a reserved
# word in one of those would then survive this check -- the vacuous pass it
# exists to prevent.
mkdir -p "$work/config" "$work/data/task_logs" "$work/data/agentq-cancellations" \
    "$work/data/agentq-requests/.locks" "$work/data/agentq-requests/.tombstones" \
    "$work/runtime"
cp "$root/skill/assets/unix/agentq-server" "$work/agentq-server"
cp "$root/skill/assets/unix/pueue.yml" "$work/config/pueue.yml"
cat > "$work/pueue" <<'STUB'
#!/bin/sh
case "$*" in
    *"group --json"*)
        printf '{"agentq":{"status":"Running","parallel_tasks":1}}\n'
        ;;
    *"status --json"*)
        printf '{"tasks":{"0":{"id":0,"label":"agentq:jq-reserved-stub-0001","group":"agentq","path":"/tmp","created_at":"2026-01-01T00:00:00Z","status":{"Done":{"enqueued_at":"2026-01-01T00:00:00Z","start":"2026-01-01T00:00:01Z","end":"2026-01-01T00:00:02Z","result":"Success"}}}},"groups":{"agentq":{"parallel_tasks":1}}}\n'
        ;;
    *"log --json"*)
        printf '{"0":{"task":{"id":0,"created_at":"2026-01-01T00:00:00Z"},"output":"hello"}}\n'
        ;;
    *"group add"*|*"parallel"*)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
STUB
chmod 700 "$work/pueue"
cp "$work/pueue" "$work/pueued"
server="$work/agentq-server"
mkdir -p "$work/workdir"

# Seed a request record + a matching cancellation marker for a task id the stub
# does NOT serve, so `cancel 1` falls through to the replay branch -- the only
# caller of the record/tombstone scanning jq programs.
printf '%s\n' '{"version":1,"request_id":"jq-reserved-seed-0001","state":"accepted","task_id":1,"task_created_at":"2026-01-01T00:00:00Z","task_label":"agentq:jq-reserved-seed-0001","created_at":"2026-01-01T00:00:00Z","payload":{"workdir":"/tmp","label":"","argv":["true"]}}' \
    >"$work/data/agentq-requests/jq-reserved-seed-0001.json"
printf '%s\n' '{"task_id":1,"state":"requested","created_at":"2026-01-01T00:00:00Z","requested_at":"2026-01-01T00:00:00Z","reason":"smoke"}' \
    >"$work/data/agentq-cancellations/1.json"

# Drive the whole command surface.  Exit codes are irrelevant -- the stub Pueue
# makes most commands fail -- what matters is that every jq call the server
# makes on the way is recorded.
run_all() {
    "$server" >/dev/null 2>&1 || true
    "$server" --help >/dev/null 2>&1 || true
    "$server" status >/dev/null 2>&1 || true
    "$server" doctor >/dev/null 2>&1 || true
    "$server" lookup "jq-reserved-probe-0001" >/dev/null 2>&1 || true
    "$server" wait 0 >/dev/null 2>&1 || true
    "$server" logs 0 --tail all >/dev/null 2>&1 || true
    "$server" cancel 1 >/dev/null 2>&1 || true
    "$server" wait 1 >/dev/null 2>&1 || true
    "$server" remove 0 >/dev/null 2>&1 || true
    "$server" submit --workdir "$work/workdir" --label smoke \
        --request-id "jq-reserved-submit-0001" -- true >/dev/null 2>&1 || true
}
run_all

invocations=$(tr -cd '\0' <"$work/jq-argv" | wc -c | tr -d ' ')
if [ "$invocations" -lt 5 ]; then
    printf 'jq-reserved-identifiers: only %s jq argument(s) recorded; the shim or the command surface has drifted\n' \
        "$invocations" >&2
    exit 1
fi

python3 - "$work/jq-argv" <<'PY'
import re
import sys

# jq 1.6 reserved words (the lexer's keyword set).  "__loc__" is included
# because the grammar also refuses it as an identifier; the values it must not
# be used for are exactly the four positions the classifier tests.
RESERVED = [
    "__loc__", "and", "as", "break", "catch", "def", "elif", "else", "end",
    "false", "for", "foreach", "if", "import", "include", "label", "module",
    "null", "or", "reduce", "then", "true", "try",
]
ALT = "|".join(sorted(RESERVED, key=len, reverse=True))

# CALIBRATION: (sample, position, expected).  expected == True means the sample
# MUST be reported as a violation.  The verdicts are the measured behaviour of
# jq 1.6 (see the header); if the classifier is edited so it no longer agrees
# with these, the self-test fails and the check refuses to report.
CALIBRATION = [
    ("--arg label x '{label: $label}'", "argv", True),   # --arg label
    ("{label: $label}",                 "program", True), # $label
    ("{label, id}",                     "program", True), # shorthand key
    ("reduce .[] as $label (0; .+1)",   "program", True), # as $label
    ("{label: 1}",                      "program", False),# key: expr is legal
    ("{id, group, path}",               "program", False),# non-reserved shorthand
    ("$request_id as $x | $x",          "program", False),# non-reserved variable
    ('{"label": 1}',                    "program", False),# quoted key is legal
    ("if .a then .b else .c end",       "program", False),# keywords used properly
    ("$labelx | .",                     "program", False),# longer identifier, not reserved
]

def classify_argv_value(name):
    """A value passed to --arg/--argjson must be an identifier, never a keyword."""
    return name in RESERVED

def classify_program(text):
    """Return [(position, matched, line)] for reserved words used as identifiers.

    `line` is the source line of the jq program that carries the match, so the
    report names the offending site rather than dumping the whole program.
    """
    found = []
    lines = text.split("\n")

    def line_of(offset):
        return lines[text.count("\n", 0, offset)].strip()

    # $variable reference (also covers `as $var`, whose $var is a $variable).
    for m in re.finditer(r'\$(' + ALT + r')(?![\w])', text):
        found.append(("$" + m.group(1), m.group(0), line_of(m.start())))
    # object shorthand key: {key, ...} / {key} / , key, ... with NO colon.
    for m in re.finditer(r'(?:^|[{,])\s*(' + ALT + r')\s*(?=[,}])', text, re.MULTILINE):
        found.append(("key:" + m.group(1), m.group(1), line_of(m.start())))
    return found

def program_violations(text):
    return [name for name, _, _ in classify_program(text)]

# --- self-test ------------------------------------------------------------
selftest_failures = 0
for sample, kind, expected in CALIBRATION:
    if kind == "argv":
        # "--arg <name>" extracted the way the walker below does.
        m = re.search(r'--arg(?:json)?\s+([A-Za-z_][A-Za-z0-9_]*)', sample)
        got = bool(m) and classify_argv_value(m.group(1))
    else:
        got = bool(program_violations(sample))
    if got != expected:
        print(
            "jq-reserved-identifiers: classifier self-test failed for %r "
            "(kind=%s): got violation=%s, expected %s"
            % (sample, kind, got, expected),
            file=sys.stderr,
        )
        selftest_failures += 1
if selftest_failures:
    print(
        "jq-reserved-identifiers: classifier is not calibrated; refusing to report a verdict",
        file=sys.stderr,
    )
    sys.exit(1)

# --- walk the recorded jq argv -------------------------------------------
raw = open(sys.argv[1], "rb").read()
# Split into invocations on the double NUL the shim emits between them.
invocations = [chunk for chunk in raw.split(b"\0\0") if chunk]
# A trailing single NUL leaves one empty chunk; drop empties.
records = []
for chunk in invocations:
    args = [a.decode("utf-8", "surrogateescape") for a in chunk.split(b"\0") if a != b""]
    if args:
        records.append(args)

# Options whose next argument(s) are values, not jq programs.
VALUE_OPTS_1 = {"--arg", "--argjson", "--slurpfile", "--indent", "--tab", "--seq"}
FILE_OPTS_1 = {"-f", "--from-file", "--rawfile", "--argfile"}

violations = []
programs_seen = 0
for args in records:
    i = 0
    n = len(args)
    while i < n:
        tok = args[i]
        if tok in VALUE_OPTS_1:
            # --arg NAME VALUE / --argjson NAME VALUE / --slurpfile NAME FILE
            if tok in ("--arg", "--argjson") and i + 1 < n:
                name = args[i + 1]
                if classify_argv_value(name):
                    violations.append(
                        ("--arg name", name, " ".join(args[:i + 2])[:120])
                    )
            i += 3
            continue
        if tok == "--slurpfile":
            i += 3
            continue
        if tok in FILE_OPTS_1:
            i += 2
            continue
        if tok in ("--indent", "--tab", "--seq"):
            i += 2
            continue
        if tok == "--args" or tok == "--jsonargs":
            i += 1
            continue
        if tok == "--":
            break
        if tok.startswith("-"):
            # A bare flag (-e, -r, -c, -n, -s, -j, ...); no argument consumed.
            i += 1
            continue
        # First non-option, not a consumed value: the jq PROGRAM.
        programs_seen += 1
        for name, matched, line in classify_program(tok):
            violations.append((name, matched, line))
        i += 1

if violations:
    # Dedupe: the same program text can be handed to jq many times (every
    # status call re-runs the compaction filter), and one bad line should be
    # reported once.
    seen = set()
    unique = []
    for name, matched, line in violations:
        key = (name, line)
        if key in seen:
            continue
        seen.add(key)
        unique.append((name, matched, line))
    print(
        "jq-reserved-identifiers: %d reserved word(s) used as a jq identifier"
        % len(unique),
        file=sys.stderr,
    )
    for name, matched, line in unique[:12]:
        print("    %s  in: %s" % (name, line), file=sys.stderr)
    sys.exit(1)

print(
    "jq-reserved-identifiers checks passed: jq_invocations=%d programs=%d violations=0"
    % (len(records), programs_seen)
)
PY
