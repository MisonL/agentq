#!/usr/bin/env bash
# Smoke: what the server does when Pueue answers with something it did not
# promise.  Every case here is a `fail` site that no other check reaches,
# because reaching it needs Pueue to emit a shape it never emits on purpose.
#
# The theme is one sentence: **a hostile or broken Pueue must produce a
# controlled exit 2 with a message naming the culprit, never a crash, never a
# silent success, and never a task state the caller could mistake for an
# answer.**  That is why each case asserts the message TEXT and the `reason=`
# class, not just the exit code -- three unrelated situations all exit 2, and a
# caller that reads only the code cannot tell "your argument is wrong" from
# "the queue is lying to me".
#
# Why this check needs a real pueue/pueued and builds a throwaway runtime
# instead of a stub script: the shapes under test are Pueue's OWN output
# formats, and a hand-written JSON stub would be a second, invented transport.
# smoke/15 already took this path for transient failures; the difference here
# is that Pueue ANSWERS and the answer is malformed.
#
# Nothing outside $work is touched, and the throwaway daemon is killed by the
# trap -- including when a case fails.
set -euo pipefail

source_home=${AGENTQ_SMOKE_HOME:-}

if [ -z "$source_home" ] || [ ! -x "$source_home/pueue" ]; then
    printf '%s\n' 'hostile-pueue: SKIPPED (needs AGENTQ_SMOKE_HOME with a real pueue)'
    exit 0
fi

for command_name in jq mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$command_name" >&2
        exit 2
    }
done
# python3 is a real dependency: the low-precision copy is built by patching the
# asset, and a patch that silently did nothing would make four cases vacuous.
# Probe that it RUNS, not just that it is on PATH -- a Microsoft Store alias
# answers `command -v` and then exits 49 with no output, which reads as a
# contract failure instead of an environment fault (smoke/01 states the rule,
# and its python3 census requires the `if !`/`|| exit` shape used here).
command -v python3 >/dev/null 2>&1 || {
    printf '%s\n' 'missing required command: python3' >&2
    exit 2
}
if ! python3 -c 'import sys' >/dev/null 2>&1; then
    printf '%s\n' 'python3 is present but cannot execute; the low-precision fixture cannot be built' >&2
    exit 2
fi

# /tmp, not TMPDIR: pueued binds a unix socket here and macOS refuses a path
# longer than SUN_LEN.  Same reason smoke/04 states.
work=$(mktemp -d /tmp/agentq-smoke-hostile.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
case "$work" in
    /private/var/folders/*)
        printf '%s\n' 'refusing to run: the work directory is too long for a unix socket' >&2
        exit 2
        ;;
esac
daemon_pid=''
cleanup() {
    if [ -n "$daemon_pid" ]; then
        kill "$daemon_pid" >/dev/null 2>&1 || true
        wait "$daemon_pid" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT

home="$work/home"
control="$work/control"
mkdir -p "$home/config" "$home/data/task_logs" "$home/data/agentq-cancellations" \
    "$home/data/agentq-requests/.locks" "$home/data/agentq-requests/.tombstones" \
    "$home/runtime" "$control"

cp "$source_home/pueue" "$home/pueue.real"
cp "$source_home/pueued" "$home/pueued"
root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cp "${AGENTQ_SMOKE_SERVER:-$root/skill/assets/unix/agentq-server}" "$home/agentq-server"
chmod 700 "$home/pueue.real" "$home/pueued" "$home/agentq-server"

# The server invokes pueue through `env -i`, so a control flag cannot arrive as
# an environment variable.  A file beside the wrapper is the only way in --
# the same constraint smoke/04 and smoke/15 document.
#
# `hostile` names a shape to answer with instead of delegating; `fail-status`
# makes every second-and-later status call fail, so the daemon probe that runs
# FIRST still passes (without that the server would try to restart a daemon it
# believes is down, which on macOS means launchctl against the real domain).
cat > "$home/pueue" <<'WRAPPER'
#!/bin/sh
here=$(CDPATH=; cd -- "$(dirname -- "$0")" && pwd -P)
control="$here/../control"
real="$here/pueue.real"
[ -d "$control" ] || exit 1

subcommand=''
expect_value=0
for argument in "$@"; do
    if [ "$expect_value" -eq 1 ]; then expect_value=0; continue; fi
    case "$argument" in
        --config) expect_value=1 ;;
        -*) ;;
        *) subcommand=$argument; break ;;
    esac
done

hostile=$(cat "$control/hostile" 2>/dev/null || printf 'none')

# A malformed TASK record: `status` is present but is a bare string where the
# filter requires an object with a known variant, and `id` is absent entirely.
if [ "$subcommand" = status ] && [ "$hostile" = bad-task ]; then
    printf '{"tasks":{"1":{"status":"Done"}},"groups":{"agentq":{"status":"Running","parallel_tasks":1}}}\n'
    exit 0
fi

# A malformed LOG record: `task.id` is a string where the filter requires a
# number, so no key can be proven to name the task it claims.
if [ "$subcommand" = log ] && [ "$hostile" = bad-log ]; then
    printf '{"1":{"task":{"id":"not-a-number"},"output":""}}\n'
    exit 0
fi

# Pueue's own status, but with a task id above 2^53.  On a jq that rounds, two
# such ids compare equal, so the server must refuse rather than match one task
# to another's record.
if [ "$subcommand" = status ] && [ "$hostile" = big-id ]; then
    cat "$control/hostile-status"
    exit 0
fi

# A task whose `created_at` is not a string.  It binds a task NUMBER to a task
# INSTANCE (Pueue reuses numbers), so a wait that cannot read it must refuse
# rather than assume "same number, same task".
if [ "$subcommand" = status ] && [ "$hostile" = bad-created ]; then
    cat "$control/hostile-created"
    exit 0
fi

# A task that PASSES `validate_pueue_task_shape_in_file` -- the id is a number,
# it is integral and non-negative, and the key equals it -- but whose
# `created_at` is an object.  That filter only looks at the id and the key, so
# the object sails through it and dies in the summary's own `error(...)`.  This
# is a DIFFERENT message from the one the task-shape filter emits, which is
# exactly why the round that silenced eight jq leaks missed it: the hunt grepped
# for `invalid visible Pueue task metadata` and this says `invalid task in
# AgentQ status summary`.
if [ "$subcommand" = status ] && [ "$hostile" = bad-created-summary ]; then
    cat "$control/hostile-summary"
    exit 0
fi

# Valid JSON of the wrong shape entirely.
if [ "$subcommand" = status ] && [ "$hostile" = not-json ]; then
    printf 'definitely not json\n'
    exit 0
fi

target=$(cat "$control/status.target" 2>/dev/null || printf '0')
if [ "$subcommand" = status ] && [ "$target" -gt 0 ]; then
    count=$(cat "$control/status.count" 2>/dev/null || printf '0')
    count=$((count + 1))
    printf '%s\n' "$count" > "$control/status.count"
    if [ "$count" -ge "$target" ]; then
        printf 'hostile-pueue: simulated failure for pueue status (call %s)\n' "$count" >&2
        exit 1
    fi
fi

exec "$real" "$@"
WRAPPER
chmod 700 "$home/pueue"
printf 'none\n' > "$control/hostile"
printf '0\n' > "$control/status.target"
printf '0\n' > "$control/status.count"

# Absolute paths: run_pueue runs with `env -i HOME="$HOME"`, so '~' would expand
# against the real home directory.
cat > "$home/config/pueue.yml" <<YAML
shared:
  pueue_directory: '$home/data'
  runtime_directory: '$home/runtime'
  use_unix_socket: true
  unix_socket_permissions: 448
  pid_path: '$home/runtime/pueued.pid'
client:
  read_local_logs: true
  show_confirmation_questions: false
  edit_mode: 'toml'
daemon:
  pause_group_on_failure: false
  pause_all_on_failure: false
  compress_state_file: true
  shell_command:
    - '/bin/bash'
    - '-lc'
    - '{{ pueue_command_string }}'
YAML
chmod 600 "$home/config/pueue.yml"

# No -d: that forks and the parent exits, leaving $! naming a dead process and
# the trap unable to stop the real daemon.
"$home/pueued" --config "$home/config/pueue.yml" >/dev/null 2>&1 &
daemon_pid=$!
ready=0
for _ in $(seq 1 60); do
    if "$home/pueue.real" --config "$home/config/pueue.yml" status --json >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.5
done
if [ "$ready" -ne 1 ]; then
    printf '%s\n' 'the throwaway pueued did not become reachable' >&2
    exit 1
fi

server="$home/agentq-server"
workdir="$work/workdir"
mkdir -p "$workdir"

# The throwaway daemon starts with only the `default` group, and the server
# checks `pueue group --json` before it compacts a status snapshot.  My wrapper
# DELEGATES that call (the shapes under test are status/log), so without this
# the group check fires first and every case reports
# `AgentQ group is missing or has unexpected parallelism` -- measured on the
# first run of this check, which is why it is here and not assumed.
"$home/pueue.real" --config "$home/config/pueue.yml" group add agentq >/dev/null 2>&1 || true
"$home/pueue.real" --config "$home/config/pueue.yml" parallel 1 --group agentq >/dev/null 2>&1 || true

failures=0
cases=0
note() { printf '  %s\n' "$1" >&2; }

# Low-precision jq: the branch `jq_preserves_integer_digits` guards is the one
# that runs on jq <= 1.6, which returns a float for anything above 2^53.  This
# host's jq does not, so the branch is unreachable without forcing it -- and a
# forced copy is the only honest way to test code whose whole purpose is to
# handle a runtime we do not have.  The patch site is asserted exactly once, so
# a renamed function makes this check fail instead of silently testing nothing.
lowp_server="$home/agentq-server-lowp"
if ! python3 - "$server" "$lowp_server" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
needle = 'jq_preserves_integer_digits() {'
if text.count(needle) != 1:
    sys.stderr.write('fixture: jq_preserves_integer_digits is not defined exactly once\n')
    sys.exit(3)
text = text.replace(needle, needle + '\n    return 1  # SMOKE: pretend a jq that rounds', 1)
open(dst, 'w').write(text)
PY
then
    printf '%s\n' 'hostile-pueue: could not build the low-precision copy; the precision cases would prove nothing' >&2
    exit 2
fi
chmod 700 "$lowp_server"

# expect_fail <label> <server> <expected-message> <args...>
#
# Asserts the three things that make a controlled refusal distinguishable from
# a crash: exit 2, the message text, and the reason class on its own line.
expect_fail() {
    local label=$1 which=$2 expected=$3
    shift 3
    local state=0
    cases=$((cases + 1))
    "$which" "$@" >"$work/$label.out" 2>"$work/$label.err" || state=$?
    if [ "$state" -ne 2 ]; then
        note "$label: exit=$state, expected the controlled 2: $(head -2 "$work/$label.err" | tr '\n' '|')"
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/$label.err"; then
        note "$label: stderr does not contain [$expected]: $(head -2 "$work/$label.err" | tr '\n' '|')"
        failures=$((failures + 1))
    fi
    # The reason line is prefixed with the program's own name, and the
    # low-precision copy is a different file: match the class, not the prefix.
    if ! grep -qE ': reason=protocol_error$' "$work/$label.err"; then
        note "$label: stderr does not carry reason=protocol_error"
        failures=$((failures + 1))
    fi
    # A crash would leave a shell diagnostic on stderr, and the clients scan
    # this stream for `reason=` -- unexplained text is a leak, not a detail.
    # `jq: error` belongs on the same list and for a sharper reason: jq is what
    # VALIDATES the shape, so when it complains the server has already decided
    # to refuse -- its diagnostic is the raw probe text that the controlled
    # message exists to replace.  Measured 2026-11-25: without the redirect,
    # `wait` printed "jq: error (at <stdin>:1): invalid visible Pueue task
    # metadata" and the caller's stderr scan saw it first.
    if grep -qE 'line [0-9]+: |unbound variable|command not found|syntax error|^jq: error' "$work/$label.err"; then
        note "$label: a raw tool diagnostic reached stderr: $(grep -E 'line [0-9]+: |unbound variable|command not found|syntax error|^jq: error' "$work/$label.err" | head -1)"
        failures=$((failures + 1))
    fi
}

submit() {
    local label=$1 request_id=$2
    shift 2
    local output
    output=$("$server" submit --workdir "$workdir" --label "$label" \
        --request-id "$request_id" -- "$@") || return 1
    jq -er '.task_id' <<<"$output"
}

# ---------------------------------------------------------------------------
# 1. A task record whose shape Pueue never emits.  `status` is a bare string
#    where the filter requires a variant object and `id` is missing, so the
#    server cannot prove which task it is looking at.  Answering anything but a
#    refusal would mean inventing an identity.
# ---------------------------------------------------------------------------
printf 'bad-task\n' > "$control/hostile"
expect_fail status-bad-task "$server" 'Pueue returned an invalid task identity in status' status
expect_fail summary-bad-task "$server" 'Pueue returned an invalid task identity in status' status --summary

# The summary's own validator, reached by a shape that passes the shared one.
cat > "$control/hostile-summary" <<'JSON'
{"tasks":{"1":{"id":1,"created_at":{"not":"a string"},"command":"true","path":"/tmp","group":"agentq","label":"agentq:h","status":{"Done":{"enqueued_at":"2026-11-25T00:00:00Z","start":"2026-11-25T00:00:00Z","end":"2026-11-25T00:00:01Z","result":{"Success":0}}}}},"groups":{"agentq":{"status":"Running","parallel_tasks":1}}}
JSON
printf 'bad-created-summary\n' > "$control/hostile"
expect_fail summary-bad-created "$server" 'cannot summarise Pueue status for AgentQ' status --summary
# Back to bad-task, NOT to none: the four callers below still need the malformed
# task shape.  Restoring the wrong value made `wait`/`logs` answer
# `unknown AgentQ task id` instead -- measured here, and the two failures it
# produced are the reason this line is explicit about what it restores.
printf 'bad-task\n' > "$control/hostile"

# The same malformed answer must be refused on EVERY command that compacts a
# task, not just on the one that happened to be tested.  These four share
# `compact_task`, and a guard that only one caller honours is a guard the other
# three bypass -- the exact shape this repository has measured more than once.
expect_fail wait-bad-task "$server" 'Pueue returned an invalid task identity in status' wait 1
expect_fail logs-bad-task "$server" 'Pueue returned an invalid task identity in status' logs 1

# Not JSON at all: the same refusal, because "I cannot parse this" and "this is
# the wrong shape" are the same answer to the caller.
printf 'not-json\n' > "$control/hostile"
expect_fail status-not-json "$server" 'Pueue returned an invalid task identity in status' status
printf 'none\n' > "$control/hostile"

# ---------------------------------------------------------------------------
# 2. A LOG record whose `task.id` is a string.  The filter requires a number
#    that also equals the record's own key, so this record cannot be attributed
#    to any task -- returning the log anyway would attach one task's output to
#    another task's id.
# ---------------------------------------------------------------------------
task_id=$(submit hostile-log "smoke-hostile-log-$$" sleep 900) || {
    printf '%s\n' 'submit for the log-shape case failed' >&2
    exit 1
}
printf 'bad-log\n' > "$control/hostile"
expect_fail logs-bad-log "$server" 'Pueue returned an invalid task identity in logs' logs "$task_id"
printf 'none\n' > "$control/hostile"
# The control: the same call on a healthy Pueue must still succeed.  Without
# this, a server that refused every log read would pass the case above.
cases=$((cases + 1))
if ! "$server" logs "$task_id" >"$work/log-ok.out" 2>"$work/log-ok.err"; then
    note "logs on a healthy Pueue failed: $(head -2 "$work/log-ok.err" | tr '\n' '|')"
    failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# 3. Pueue simply fails, after the daemon probe has already succeeded.  The two
#    readers are different functions with different call sites and different
#    messages; asserting only one of them is how the other stayed uncovered.
# ---------------------------------------------------------------------------
printf '2\n' > "$control/status.target"
printf '0\n' > "$control/status.count"
expect_fail status-transient "$server" 'cannot inspect Pueue while reading AgentQ status' status
printf '2\n' > "$control/status.target"
printf '0\n' > "$control/status.count"
expect_fail summary-transient "$server" 'cannot summarise Pueue status for AgentQ' status --summary
printf '0\n' > "$control/status.target"
# And the healthy control again: a server that always refused would pass both.
cases=$((cases + 1))
if ! "$server" status >/dev/null 2>"$work/status-ok.err"; then
    note "status on a healthy Pueue failed: $(head -2 "$work/status-ok.err" | tr '\n' '|')"
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if ! "$server" status --summary >/dev/null 2>"$work/summary-ok.err"; then
    note "status --summary on a healthy Pueue failed: $(head -2 "$work/summary-ok.err" | tr '\n' '|')"
    failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# 4. A task id above 2^53 on a jq that cannot represent it.  This is not a
#    hypothetical: jq <= 1.6 parses every number as a double, so 2^53 and
#    2^53+1 compare equal and a task can be matched to the WRONG record.  The
#    server refuses the range instead of answering about a task it cannot
#    distinguish -- and it must do so on both the argv path and the Pueue-JSON
#    path, which are separate functions.
# ---------------------------------------------------------------------------
expect_fail argv-id-too-precise "$lowp_server" \
    'task id exceeds the exact-integer range of the configured jq' wait 9007199254740993
expect_fail status-id-too-precise "$lowp_server" \
    'task id exceeds the exact-integer range of the configured jq' status --task 9007199254740993

# The Pueue-JSON path: Pueue REPORTS an id the configured jq cannot carry.
# The validator reads Pueue's own status snapshot, not the request record --
# measured on the first draft of this case, which planted a record and watched
# the argv validator answer instead.  So the wrapper answers with such a task.
# The shape must be REAL, field for field: a hand-reduced object would fail the
# SHAPE validator first and the case would prove the wrong guard.  Measured
# 2026-11-25 on this host's pueue 4.0.4 -- the top-level keys are id,
# created_at, original_command, command, path, envs, status, group, label,
# dependencies, priority, and the precision probe greps a numeric `"id"` field.
hostile_status="$control/hostile-status"
cat > "$hostile_status" <<'JSON'
{"tasks":{"9007199254740993":{"id":9007199254740993,"created_at":"2026-11-25T00:00:00Z","original_command":"true","command":"true","path":"/tmp","envs":{},"group":"agentq","label":"agentq:hostile","dependencies":[],"priority":null,"status":{"Done":{"enqueued_at":"2026-11-25T00:00:00Z","start":"2026-11-25T00:00:00Z","end":"2026-11-25T00:00:01Z","result":{"Success":0}}}}},"groups":{"agentq":{"status":"Running","parallel_tasks":1}}}
JSON
printf 'big-id\n' > "$control/hostile"
expect_fail status-json-too-precise "$lowp_server" \
    'Pueue task id exceeds the exact-integer range of the configured jq' status
expect_fail logs-json-too-precise "$lowp_server" \
    'Pueue task id exceeds the exact-integer range of the configured jq' logs 1
printf 'none\n' > "$control/hostile"

# The same id on the normal jq must be ACCEPTED: this host's jq keeps every
# digit, so the id is exact and there is nothing to refuse.  Without this case a
# server that refused all large ids would pass the two above.
cases=$((cases + 1))
state=0
"$server" status --task 9007199254740993 >"$work/exact-id.out" 2>"$work/exact-id.err" || state=$?
if [ "$state" -eq 2 ] && grep -qF 'exceeds the exact-integer range' "$work/exact-id.err"; then
    note "a jq that preserves digits refused 9007199254740993, which it represents exactly"
    failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# 4b. A PERSISTED task id with leading zeros.  `task_log_path` and
#     `cancellation_marker_path` interpolate the id into a FILENAME, so a value
#     that is not canonical would name a different file than the caller means --
#     `1` and `0001` would be two ids and one path.  The argv is canonicalized
#     before it reaches those functions, so this guard is only reachable from a
#     persisted value; the plant below is a marker file whose NAME carries the
#     zeros.
#
#     Two guards sit on that path and the OUTER one answers first, with its own
#     message ("... cancellation marker filename"), because the loader checks
#     the filename before it checks the id it parses out of it.  Both messages
#     are controlled refusals; what must never happen is a path built from the
#     non-canonical value, or jq noise on stderr.  Pinning the message that
#     actually fires means a refactor that swaps which guard answers shows up
#     here rather than passing silently under a looser match.
# ---------------------------------------------------------------------------
cursor_dir="$home/data/agentq-cancellations"
mkdir -p "$cursor_dir"
printf '{"version":1,"task_id":"0001","task_created_at":"2026-11-25T00:00:00Z","state":"requested","requested_at":"2026-11-25T00:00:00Z","created_at":"2026-11-25T00:00:00Z","reason":"hostile"}\n' \
    > "$cursor_dir/0001.json"
printf 'none\n' > "$control/hostile"
# Strict 2, not "1 or 2".  When this case was first written, the marker loader
# was the left side of a pipeline, so its `fail` ended only the subshell and the
# caller folded the status into `return 1` -- stderr said reason=protocol_error
# on top of exit 1, code and class disagreeing.  The loader now redirects to a
# file instead of piping, so the body keeps the main shell and the 2 is real.
# The assertion is strict on purpose: asserting "1 or 2" would have let the
# defect live on underneath a green check.
expect_fail non-canonical-marker "$server" 'non-canonical AgentQ cancellation marker filename' status
rm -f "$cursor_dir/0001.json"

# A marker file whose CONTENT is not JSON at all.  Same family, same fix: this
# used to answer exit 1 with a `reason=protocol_error` line attached, because the
# loader's `fail` sat in a pipeline subshell.  With the redirect it is a real
# exit 2, so the assertion is strict.
printf 'not json at all\n' > "$cursor_dir/1.json"
cases=$((cases + 1))
state=0
"$server" status >"$work/corrupt-marker.out" 2>"$work/corrupt-marker.err" || state=$?
if [ "$state" -ne 2 ]; then
    note "corrupt-marker: exit=$state, expected the controlled 2: $(head -2 "$work/corrupt-marker.err" | tr '\n' '|')"
    failures=$((failures + 1))
elif ! grep -qF 'invalid AgentQ cancellation marker' "$work/corrupt-marker.err"; then
    note "corrupt-marker: stderr does not name the guard: $(head -2 "$work/corrupt-marker.err" | tr '\n' '|')"
    failures=$((failures + 1))
elif ! grep -qE ': reason=protocol_error$' "$work/corrupt-marker.err"; then
    note 'corrupt-marker: stderr does not carry reason=protocol_error'
    failures=$((failures + 1))
fi
# jq's own parse error must NOT reach stderr: the clients scan that stream for
# `reason=`, and a raw parser diagnostic is the leak this repository keeps
# closing (the same shape as the three jq sites fixed in this round).
cases=$((cases + 1))
if grep -qE '^jq: parse error|^jq: error' "$work/corrupt-marker.err"; then
    note "corrupt-marker: a raw jq diagnostic reached stderr: $(grep -E '^jq: ' "$work/corrupt-marker.err" | head -1)"
    failures=$((failures + 1))
fi
rm -f "$cursor_dir/1.json"

# ---------------------------------------------------------------------------
# 5. A creation time the server cannot read.  `created_at` is what binds a task
#    NUMBER to a task INSTANCE -- Pueue reuses numbers, and a cancellation
#    marker or a tombstone is only trustworthy if the instance matches.  A
#    non-string value must refuse, not fall through to "same number, same task".
# ---------------------------------------------------------------------------
hostile_created="$control/hostile-created"
cat > "$hostile_created" <<'JSON'
{"tasks":{"1":{"id":1,"created_at":{"not":"a string"},"original_command":"true","command":"true","path":"/tmp","envs":{},"group":"agentq","label":"agentq:hostile","dependencies":[],"priority":null,"status":{"Done":{"enqueued_at":"2026-11-25T00:00:00Z","start":"2026-11-25T00:00:00Z","end":"2026-11-25T00:00:01Z","result":{"Success":0}}}}},"groups":{"agentq":{"status":"Running","parallel_tasks":1}}}
JSON
printf 'bad-created\n' > "$control/hostile"
# The jq that validates a compacted task answers `error(...)`, which exits 5 --
# the code the contract reserves for a REMOVED task.  Both readers must report
# "cannot inspect", NOT "unknown AgentQ task id": the id is not unknown, the
# answer is unintelligible.  Measured pre-fix on this host: `wait 1` exited 2
# with "unknown AgentQ task id: 1" and a raw `jq: error (at <stdin>:1): invalid
# visible Pueue task metadata` line above it -- the operator is sent to check
# its arguments, and the stream the clients scan for `reason=` carries jq noise.
expect_fail wait-bad-created "$server" 'cannot inspect Pueue while reading AgentQ task' wait 1
expect_fail logs-bad-created "$server" 'cannot inspect Pueue while reading AgentQ task' logs 1
expect_fail status-bad-created "$server" 'cannot inspect Pueue while reading AgentQ task' status --task 1
printf 'none\n' > "$control/hostile"

# ---------------------------------------------------------------------------
# 5b. A marker or a member of the request-record set whose FILENAME is not a
#     usable id at all.  Both loaders used to be the left side of a pipeline, so
#     their `fail` could only end a subshell: the exit 2 became the pipeline's
#     status 1, the caller folded it into `return 1`, and stderr carried
#     `reason=protocol_error` on top of exit 1 -- a code the contract reads as
#     "general failure, retry" for a corruption that no retry can clear.
#     Measured 2026-11-25 before the fix: `status` 1, `remove --label` 1, while
#     `status --summary` answered 0 (its path loads neither file).  One
#     corruption, three answers.
#
#     Both loaders now REDIRECT into a temp file instead of piping, so the loop
#     keeps the main shell and its `fail` is the process's real exit 2.  These
#     rows are strict about it: asserting "1 or 2" would let the defect survive
#     under a green check, which is exactly what the first version of this
#     check did.
# ---------------------------------------------------------------------------
printf '{"version":1,"task_id":"1","task_created_at":"2026-11-25T00:00:00Z","state":"requested","requested_at":"2026-11-25T00:00:00Z","created_at":"2026-11-25T00:00:00Z","reason":"hostile"}\n' \
    > "$cursor_dir/notanid.json"
expect_fail marker-bad-filename "$server" 'invalid AgentQ cancellation marker filename' status
expect_fail marker-bad-filename-batch "$server" 'invalid AgentQ cancellation marker filename' remove --label hostile --confirm
rm -f "$cursor_dir/notanid.json"

# The request-record twin: a filename that is not a request id.  This one is
# reached by every command that reads records, so it is asserted from three.
printf '{"version":1,"request_id":"notanid","label":"hostile","workdir":"/tmp","task_id":1,"task_created_at":"2026-11-25T00:00:00Z","state":"accepted","created_at":"2026-11-25T00:00:00Z"}\n' \
    > "$home/data/agentq-requests/notanid.json"
expect_fail record-bad-filename "$server" 'invalid AgentQ request record filename' status
expect_fail record-bad-filename-summary "$server" 'invalid AgentQ request record filename' status --summary
expect_fail record-bad-filename-doctor "$server" 'invalid AgentQ request record filename' doctor
# The summary and the full status used to DISAGREE about the same tree (0 vs 1)
# because only one of them loads records.  Both must now refuse, which is what
# these two rows together pin.
rm -f "$home/data/agentq-requests/notanid.json"

# ---------------------------------------------------------------------------
# 6. The same "raw validator diagnostic must not reach the caller" rule, applied
#    to the files AgentQ itself writes.  jq is the validator for a request
#    record and for a tombstone as well as for Pueue's output, and in each case
#    its parse error is the probe text that the controlled `fail` replaces.
#    Measured 2026-11-25: `status` on a corrupt record printed
#    `jq: parse error: Invalid numeric literal at line 1, column 4` above
#    `invalid AgentQ request record`, and `lookup` on a corrupt tombstone did the
#    same -- the clients capture that stream and look for `reason=`, so a
#    corrupt file put unexplained text in front of the machine-readable line.
#
#    These are files the server OWNS, so this is not a hostile-input case: it is
#    what a truncated write or a full disk leaves behind.
# ---------------------------------------------------------------------------
corrupt_record="$home/data/agentq-requests/smoke-hostile-record-$$.json"
printf 'not json\n' > "$corrupt_record"
expect_fail corrupt-record "$server" 'invalid AgentQ request record' status
rm -f "$corrupt_record"

corrupt_tomb="$home/data/agentq-requests/.tombstones/smoke-hostile-tomb-$$.json"
printf 'not json\n' > "$corrupt_tomb"
expect_fail corrupt-tombstone "$server" 'invalid AgentQ request tombstone' lookup "smoke-hostile-tomb-$$"
rm -f "$corrupt_tomb"

# The controls: with those files gone, the same two commands must succeed.  A
# server that refused every status/lookup would pass the two cases above.
cases=$((cases + 1))
if ! "$server" status >/dev/null 2>"$work/recovered-status.err"; then
    note "status after removing the corrupt files failed: $(head -2 "$work/recovered-status.err" | tr '\n' '|')"
    failures=$((failures + 1))
fi
cases=$((cases + 1))
state=0
"$server" lookup "smoke-hostile-tomb-$$" >/dev/null 2>"$work/recovered-lookup.err" || state=$?
if [ "$state" -ne 3 ]; then
    note "lookup on an absent id exited $state, expected 3/not_found: $(head -2 "$work/recovered-lookup.err" | tr '\n' '|')"
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'hostile-pueue: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'hostile-pueue checks passed: cases=%s shapes=bad-task/not-json/bad-log transient=status/summary precision=argv/json-nonvenient corrupt=record/tombstone/marker leak=jq/shell guards=asserted\n' "$cases"
