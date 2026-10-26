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

# python3 is a real dependency of this check: the extraction / parsing steps
# below are Python.  Probe that it RUNS, not that a name resolves -- measured
# 2026-10-20 on a zh-CN Windows 10, where `python3` is the Microsoft Store
# alias: the check died at its first Python step with exit 49 and ZERO output,
# which run-tests.sh can only report as a bare FAIL with no cause.  Same rule as
# the pwsh usability probes: an interpreter that cannot execute is an
# ENVIRONMENT fault, say so and do not claim the contract ran.
python3_probe_status=0
python3 -c 'import sys' >/dev/null 2>&1 || python3_probe_status=$?
if [ "$python3_probe_status" -ne 0 ]; then
    printf '%s\n' 'jq-reserved-identifiers NOT run: the python3 on PATH cannot execute (a Microsoft Store alias cannot run scripts).' >&2
    printf '%s\n' 'Install a real Python 3 and put it on PATH, then re-run.' >&2
    exit 1
fi
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
# The record file is a stream of NUL-separated argv with a DOUBLE NUL between
# invocations, and the reader below splits on that double NUL.  That encoding
# has a shape it cannot represent: an EMPTY argument produces `\0\0` on its own
# (the empty value's terminator plus the next value's), so an invocation that
# carries one is split into two records -- and two invocations appended by
# overlapping writers can lose the separator and fuse into one.  Both were
# measured on synthetic streams: one empty argument turns 1 record into 2, and a
# fused pair turns 2 records into 1 with the program count rising by one.  The
# second is exactly the 133/135 signature seen once in a full-suite run whose
# own 30 standalone reruns were all 134/134, so the count is not trustworthy as
# a "how many calls did we see" number.
#
# So the count is now measured TWICE, independently: the byte-count line below
# (a single line per invocation, appended with one write) and the NUL stream.
# They must agree, and the check refuses to report if they do not -- the same
# stance as the classifier self-test, for the same reason: a check that cannot
# account for its own inputs has no business judging the server.
cat > "$work/shim/jq" <<SHIM
#!/bin/sh
printf 'x\\n' >>"$work/jq-count"
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
: >"$work/jq-count"

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

python3 - "$work/jq-argv" "$work/jq-count" <<'PY'
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
counted = sum(1 for line in open(sys.argv[2], "rb") if line.strip())

# The NUL stream is decoded exactly as before -- one record per double-NUL
# chunk.  It is NOT repaired: a chunk whose separator was lost cannot be split
# apart again (the fused record's second half also begins with a flag), so any
# "fix" here would be a guess.  What the check can do is refuse to judge a
# capture it cannot account for, which the cross-check below does.
chunks = [chunk for chunk in raw.split(b"\0\0") if chunk]
records = []
for chunk in chunks:
    args = [a.decode("utf-8", "surrogateescape") for a in chunk.split(b"\0") if a != b""]
    if args:
        records.append(args)

# The two recorders must agree.  They are independent: the line counter appends
# one byte per invocation with a single write, the NUL stream appends the whole
# argv in several writes.  A disagreement means the stream lost or gained a
# record -- the measured signature of two overlapping appends (2 records -> 1,
# program count +1) -- and every count derived from it would be a precise-
# looking number that is not true.  Refuse instead.
if len(records) != counted:
    print(
        "jq-reserved-identifiers: the recorders disagree (%d invocation(s) in "
        "the NUL stream, %d in the line counter); the capture is malformed and "
        "this check cannot vouch for what it saw" % (len(records), counted),
        file=sys.stderr,
    )
    sys.exit(1)

# Options whose next argument(s) are values, not jq programs.
VALUE_OPTS_1 = {"--arg", "--argjson", "--slurpfile"}
FILE_OPTS_1 = {"-f", "--from-file", "--rawfile", "--argfile"}

violations = []
programs_seen = 0
per_record_programs = []
for args in records:
    i = 0
    record_programs = 0
    n = len(args)
    while i < n:
        tok = args[i]
        if tok in ("--arg", "--argjson"):
            # NAME VALUE (two consumed values, three positions)
            if i + 1 < n:
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
        if tok == "--indent":
            # consumes ONE value; the token AFTER that value is the jq PROGRAM.
            # Treating it as a two-value option skipped the program entirely
            # (measured 2026-10-13: walk(["--indent","2","prog"]) -> []).
            i += 2
            continue
        if tok in ("--tab", "--seq"):
            # jq flags, no value; the NEXT token is the program.
            i += 1
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
        record_programs += 1
        for name, matched, line in classify_program(tok):
            violations.append((name, matched, line))
        i += 1
    per_record_programs.append(record_programs)

# Every jq invocation carries exactly ONE program.  A record with two means two
# invocations were fused by a lost separator -- the measured 133/135 signature
# (records -1, programs +1) -- and a record with none means the split landed
# inside one.  This is the invariant the recorder cross-check above is a proxy
# for; asserting it directly catches the fusion even if both recorders happen
# to agree on a wrong count.
bad_records = [i for i, count in enumerate(per_record_programs) if count != 1]
if bad_records:
    print(
        "jq-reserved-identifiers: %d record(s) do not carry exactly one jq "
        "program (index:count %s).  A record with TWO means two invocations "
        "were fused by a lost separator -- the measured 133/135 signature.  A "
        "record with NONE means the split landed inside one.  A count above one "
        "can also mean jq is now given a positional input FILE (a path after "
        "the program), which no call in this server does: paths are "
        "redirections, pinned by smoke/08.  Adjudicate before trusting any "
        "count this check prints."
        % (len(bad_records), ", ".join("%d:%d" % (i, per_record_programs[i]) for i in bad_records[:8])),
        file=sys.stderr,
    )
    sys.exit(1)

if programs_seen < 1:
    print(
        "jq-reserved-identifiers: no jq program was classified; the walker or "
        "the command surface has drifted and this check would prove nothing",
        file=sys.stderr,
    )
    sys.exit(1)

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
    "jq-reserved-identifiers checks passed: jq_invocations=%d programs=%d violations=%d"
    % (len(records), programs_seen, len(violations))
)
PY
