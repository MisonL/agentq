#!/usr/bin/env bash
# Smoke: the server must never hand a file path to jq as a command-line
# argument.  Every jq file input must arrive on stdin (`< "$file"` or a
# here-string), or, where a jq option requires a filename, through
# `jq_file_argument` -- which converts the path with `cygpath -aw` on Windows
# and returns it unchanged on unix.
#
# Why this is its own check.  On Windows the server runs under Git Bash and
# exports MSYS_NO_PATHCONV=1 (agentq-server, windows branch) so that user
# arguments such as `cmd /c` survive intact.  The side effect is that MSYS's
# automatic POSIX->Windows path translation is off for every child process,
# and jq is a NATIVE Windows binary.  A call shaped `jq -e FILTER /tmp/x.json`
# therefore reaches jq unconverted and fails with "Could not open file"; the
# same file read through stdin works, because the shell performs the redirect
# and no path is ever passed as an argument.
#
# This was a real defect, not a hypothetical.  On Windows 10 with Git Bash and
# chocolatey's jq, every one of these call sites failed: `status` and `doctor`
# exited 2, `submit` reconciled the request to `removed`, and `logs` returned
# 6/unavailable.  The server reported each failure as a data problem, so the
# cause was invisible from the outside.
#
# The check is behavioural, not a source-text scan.  jq is shimmed to record
# its own argv, the server is driven through the whole command surface, and the
# recorded argv is asserted to contain no absolute path used as a positional
# argument, except where a jq option legitimately demands a filename.  A text
# scan was tried first and abandoned: quoting and command substitution make it
# unreliable, and it reported --arg values as file arguments.
#
# The runtime below is deliberately more than a version-printing stub.  It
# answers the group and status JSON queries and serves one finished task with a
# log, and it seeds a request record plus a matching cancellation marker for a
# task id the stub does NOT serve.  Both matter for sensitivity, not realism:
# with an empty task map, `cancel` and `wait` never reach the replay and
# reconciliation code, and a mutation in those paths survives.  Mutation-tested
# at 10/10 after those seeds were added; an earlier revision missed 3 because
# the stub served the probed task id, so those branches were never entered.
#
# What it proves: for the commands this check runs, no jq invocation receives
# a file path as a positional argument.  What it does not prove: anything
# about jq's filters, or about Windows-only branches this check never reaches.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/agentq-smoke-jqpath.XXXXXX")
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

real_jq=$(command -v jq) || {
    printf 'jq-path-arguments: jq is required to run this check\n' >&2
    exit 1
}

# The shim records argv NUL-separated, then behaves exactly like jq.
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

# A minimal runtime the server accepts, with stubs for the Pueue binaries so
# startup gets past the executable checks and into the jq calls.
mkdir -p "$work/config" "$work/data/task_logs" "$work/data/agentq-cancellations" \
    "$work/data/agentq-requests/.locks" "$work/data/agentq-requests/.tombstones" \
    "$work/runtime"
cp "$root/skill/assets/unix/agentq-server" "$work/agentq-server"
cp "$root/skill/assets/unix/pueue.yml" "$work/config/pueue.yml"
# The Pueue stubs answer the JSON queries the server makes, so that the jq
# calls downstream of them are actually reached.  A stub that only prints a
# version string leaves `verify_group`, `ensure_group` and the status
# compaction untouched -- and a mutation in one of those would then survive
# this check, which is exactly the vacuous pass it exists to prevent.
cat > "$work/pueue" <<'STUB'
#!/bin/sh
case "$*" in
    *"group --json"*)
        printf '{"agentq":{"status":"Running","parallel_tasks":1}}\n'
        ;;
    *"status --json"*)
        # One finished task, so `logs 0` gets past compact_task and reaches the
        # log-shape validation.  With an empty task map that call fails early
        # and a violation inside the log path would survive this check.
        printf '{"tasks":{"0":{"id":0,"label":"agentq:jq-path-stub-task-0001","group":"agentq","path":"/tmp","created_at":"2026-01-01T00:00:00Z","status":{"Done":{"enqueued_at":"2026-01-01T00:00:00Z","start":"2026-01-01T00:00:01Z","end":"2026-01-01T00:00:02Z","result":"Success"}}}},"groups":{"agentq":{"parallel_tasks":1}}}\n'
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

# A request record plus a cancellation marker whose created_at matches it, for
# task id 1 -- an id the stub above does NOT serve.  `cancel 1` therefore falls
# through to the replay branch, the only caller of task_instance_created_at,
# which scans the persisted records and tombstones with jq.  Without these seeds
# (and with the stub serving the probed id) that function is never reached and a
# violation inside it survives this check.
printf '%s\n' '{"version":1,"request_id":"jq-path-seed-00000001","state":"accepted","task_id":1,"task_created_at":"2026-01-01T00:00:00Z","task_label":"agentq:jq-path-seed-00000001","created_at":"2026-01-01T00:00:00Z","payload":{"workdir":"/tmp","label":"","argv":["true"]}}' \
    >"$work/data/agentq-requests/jq-path-seed-00000001.json"
printf '%s\n' '{"task_id":1,"state":"requested","created_at":"2026-01-01T00:00:00Z","requested_at":"2026-01-01T00:00:00Z","reason":"smoke"}' \
    >"$work/data/agentq-cancellations/1.json"

# Drive the whole command surface.  Exit codes are irrelevant here -- the stub
# Pueue makes most commands fail -- what matters is that every jq call the
# server makes on the way is recorded and inspected.
run_all() {
    "$server" >/dev/null 2>&1 || true
    "$server" --help >/dev/null 2>&1 || true
    "$server" status >/dev/null 2>&1 || true
    "$server" doctor >/dev/null 2>&1 || true
    "$server" lookup "jq-path-probe-0001" >/dev/null 2>&1 || true
    "$server" wait 0 >/dev/null 2>&1 || true
    "$server" logs 0 --tail all >/dev/null 2>&1 || true
    # Probe id 1, which the stub does not serve: `cancel 1` takes the replay
    # branch (reaching task_instance_created_at) and `wait 1` takes the
    # reconciliation branch.  Id 0 is served, so it exercises the ordinary
    # paths instead.
    "$server" cancel 1 >/dev/null 2>&1 || true
    "$server" wait 1 >/dev/null 2>&1 || true
    "$server" remove 0 >/dev/null 2>&1 || true
    "$server" submit --workdir "$work/workdir" --label smoke \
        --request-id "jq-path-submit-0001" -- true >/dev/null 2>&1 || true
}
run_all

# The check must have observed jq traffic, or it proves nothing.
invocations=$(tr -cd '\0' <"$work/jq-argv" | wc -c | tr -d ' ')
if [ "$invocations" -lt 5 ]; then
    printf 'jq-path-arguments: only %s jq argument(s) recorded; the shim or the command surface has drifted\n' \
        "$invocations" >&2
    exit 1
fi

# Walk the recorded argv, one NUL-terminated argument at a time.  An absolute
# path used as a positional argument is a violation; the only exceptions are
# the arguments a jq option legitimately consumes as a filename.  Note that the
# `--slurpfile` sites are correct by construction -- they route the path through
# jq_file_argument, which on Windows yields `C:\...` (no leading slash, so it
# would not be flagged anyway) and on unix returns the POSIX path unchanged
# (which is why the filename-option exception has to exist).
failures=0
python3 - "$work/jq-argv" <<'PY' || failures=$((failures + 1))
import re
import sys

raw = open(sys.argv[1], "rb").read()
args = [a.decode("utf-8", "surrogateescape") for a in raw.split(b"\0") if a]

# Options whose next argument is legitimately a filename.  `--slurpfile NAME
# FILE` consumes two arguments; the filename is the one after the NAME.
FILENAME_OPTS = {"-f", "--from-file", "--rawfile", "--argfile"}

violations = []
for i, arg in enumerate(args):
    if not arg.startswith("/"):
        continue
    # Every absolute-path positional argument is a violation.  Two narrower
    # tests were tried and both were wrong:
    #   * os.path.exists() -- the server deletes its temporary files as it
    #     finishes with them, so by the time this walks the recorded argv they
    #     are gone and real violations were filtered out.  That is how this
    #     check first passed while a mutation was active.
    #   * matching only `.agentq-*` temp-file names -- the server also hands jq
    #     persisted request records and tombstones, whose names have no such
    #     prefix, so a violation in those loops was invisible.
    # Any path reaching jq as an argument is wrong on Windows, whatever the
    # file is, so the rule is simply "no absolute path arguments".
    # Decide by walking the argv from the start, tracking how many values each
    # option still consumes.  A fixed lookback window is wrong here: the filter
    # sits between an option and the argument it governs, so `args[i - 2]` can
    # be an --arg value rather than the option, which silently swallowed real
    # violations when this check was mutation-tested.
    consumed_until = -1
    role = None  # "value" for --arg/--argjson, "filename" for file options
    k = 0
    while k < i:
        tok = args[k]
        if k > consumed_until:
            if tok in ("--arg", "--argjson"):
                consumed_until = k + 2
                role = "value"
            elif tok in FILENAME_OPTS:
                consumed_until = k + 1
                role = "filename"
            elif tok == "--slurpfile":
                consumed_until = k + 2
                role = "filename"
            elif tok in ("--indent", "--tab", "--seq"):
                consumed_until = k + 1
                role = "value"
        k += 1
    if consumed_until >= i and role in ("value", "filename"):
        continue
    violations.append((i, arg))

if violations:
    print(
        f"jq-path-arguments: {len(violations)} jq call(s) received a file path "
        "as a positional argument",
        file=sys.stderr,
    )
    for _, arg in violations[:10]:
        print(f"    {arg}", file=sys.stderr)
    sys.exit(1)

print(
    f"jq-path-arguments checks passed: jq_argv={len(args)} "
    "path_arguments=0"
)
PY

if [ "$failures" -ne 0 ]; then
    exit 1
fi
