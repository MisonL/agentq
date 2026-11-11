#!/usr/bin/env bash
# Smoke: a transient Pueue read failure must never be mistaken for "the task is
# gone".
#
# This is the regression lock for a P0 defect found by an external review
# (2026-09-24).  `find_request_task` reports "cannot inspect Pueue" by calling
# `fail`, which is `exit 2`; but every one of its call sites used the shape
# `if task=$(find_request_task ...)`, and `exit` inside `$( )` terminates only
# the subshell.  The caller therefore saw an EMPTY string and a FALSE condition,
# concluded the task did not exist, and archived a LIVE request as `removed`:
# the active request record was deleted, a tombstone was written, and the task
# kept running.  The state was permanent -- `lookup` returned 5 forever, the
# task lost all `agentq` metadata, and the request id could never be reused.
#
# No existing check could catch it: they all assert exit codes for STABLE
# conditions and never for a Pueue read that fails mid-operation.  So this check
# injects exactly one failure, at exactly the reconcile call, and asserts the
# side effects that must NOT happen.
#
# Runs against a throwaway runtime under /tmp.  Nothing outside $work is touched.
set -euo pipefail

source_home=${AGENTQ_SMOKE_HOME:-}

if [ -z "$source_home" ] || [ ! -x "$source_home/pueue" ]; then
    printf '%s\n' 'transient-pueue-failure: SKIPPED (needs AGENTQ_SMOKE_HOME with a real pueue)'
    exit 0
fi

for command_name in jq mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$command_name" >&2
        exit 2
    }
done

# Not TMPDIR: pueued binds a unix socket in here and macOS fails the bind once
# the path exceeds SUN_LEN, and $TMPDIR is /var/folders/<long hash>/T/.
work=$(mktemp -d /tmp/agentq-smoke-transient.XXXXXX)
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
mkdir -p "$home/config" "$home/data/task_logs" "$home/data/agentq-cancellations" \
    "$home/data/agentq-requests/.locks" "$home/data/agentq-requests/.tombstones" \
    "$home/runtime" "$work/control"
control="$work/control"

cp "$source_home/pueue" "$home/pueue.real"
cp "$source_home/pueued" "$home/pueued"
# The SERVER under test is the repo asset, not the runtime's snapshot (same fix
# as smoke/04/06, 2026-10-21): "$source_home/agentq-server" is whatever
# sandbox.sh wrote when the SANDBOX was created -- measured at 247276 bytes
# against the repo asset's 248213 -- so server-side changes after that moment
# were invisible here.
root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cp "${AGENTQ_SMOKE_SERVER:-$root/skill/assets/unix/agentq-server}" "$home/agentq-server"
chmod 700 "$home/pueue.real" "$home/pueued" "$home/agentq-server"

# The server runs pueue through `env -i`, so the control channel has to be a
# file.  status.target names the Nth `status --json` call to fail: call 1 is the
# daemon probe inside ensure_daemon, call 2 is the one inside reconcile.  Failing
# call 1 instead would make the server believe the daemon is down and reach for
# launchctl -- a real service change.
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

if [ "$subcommand" = status ]; then
    target=$(cat "$control/status.target" 2>/dev/null || printf '0')
    if [ "$target" -gt 0 ]; then
        count=$(cat "$control/status.count" 2>/dev/null || printf '0')
        count=$((count + 1))
        printf '%s\n' "$count" > "$control/status.count"
        if [ "$count" -eq "$target" ]; then
            printf 'transient-pueue-failure: simulated failure for pueue status (call %s)\n' "$count" >&2
            exit 1
        fi
    fi
fi

exec "$real" "$@"
WRAPPER
chmod 700 "$home/pueue"
printf '0\n' > "$control/status.target"
printf '0\n' > "$control/status.count"

# Absolute paths: run_pueue uses `env -i HOME="$HOME"`, so '~' would expand
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

# Start the daemon up front: with none running, ensure_daemon falls through to
# launchctl on macOS, which is a service change against the real launchd domain.
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
requests="$home/data/agentq-requests"
tombstones="$home/data/agentq-requests/.tombstones"

failures=0
note() { printf '  %s\n' "$1" >&2; }

record_count() { find "$requests" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
tombstone_count() { find "$tombstones" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

request_id="smoke-transient-$$-$(date -u '+%Y%m%dT%H%M%SZ')"
request_id=${request_id:0:120}

# A long-running task, so it is unambiguously still live when the read fails.
if ! submit_output=$("$server" submit --workdir "$workdir" --label transient \
        --request-id "$request_id" -- sh -c 'sleep 60'); then
    printf '%s\n' 'submit failed' >&2
    exit 1
fi
task_id=$(jq -er '.task_id' <<<"$submit_output") || {
    printf 'submit returned no task_id: %s\n' "$submit_output" >&2
    exit 1
}
sleep 2

records_before=$(record_count)
tombstones_before=$(tombstone_count)

# Fail the reconcile call, and only that one.
printf '2\n' > "$control/status.target"
printf '0\n' > "$control/status.count"
lookup_status=0
lookup_output=$("$server" lookup "$request_id" 2>"$work/lookup.stderr") || lookup_status=$?
printf '0\n' > "$control/status.target"

# 1. The failure must be REPORTED, not silently converted into a data verdict.
if [ "$lookup_status" -ne 2 ]; then
    note "lookup returned $lookup_status after a transient Pueue failure; expected 2"
    failures=$((failures + 1))
fi
if ! grep -q 'cannot inspect Pueue' "$work/lookup.stderr"; then
    note 'lookup did not report that Pueue could not be inspected'
    failures=$((failures + 1))
fi
if ! grep -qx 'agentq-server: reason=protocol_error' "$work/lookup.stderr"; then
    note 'lookup did not carry reason=protocol_error'
    failures=$((failures + 1))
fi

# 2. The live request must NOT have been archived.  This is the defect: the
#    record was deleted and a tombstone written while the task kept running.
if [ "$(record_count)" != "$records_before" ]; then
    note "a live request was archived during a transient failure (records $records_before -> $(record_count))"
    failures=$((failures + 1))
fi
# Computed, not a literal: the summary prints this number, and `tombstones=0`
# typed into the printf could not move if the sandbox ever started with one.
tombstones_written=$(( $(tombstone_count) - tombstones_before ))
if [ "$tombstones_written" -ne 0 ]; then
    note "a tombstone was written for a live request during a transient failure"
    failures=$((failures + 1))
fi

# 3. And it must not be reported as removed -- that is the caller-visible lie.
if grep -q '"state":"removed"' <<<"$lookup_output"; then
    note "lookup reported a live request as removed: $lookup_output"
    failures=$((failures + 1))
fi

# 4. Once Pueue answers again, the request must be intact and resolvable.
recovered=0
lookup_after=$("$server" lookup "$request_id" 2>/dev/null) || recovered=$?
if [ "$recovered" -ne 0 ]; then
    note "lookup did not recover after the transient failure (exit $recovered)"
    failures=$((failures + 1))
elif [ "$(jq -r '.task_id' <<<"$lookup_after")" != "$task_id" ]; then
    note "lookup returned a different task after recovery: $lookup_after"
    failures=$((failures + 1))
fi

# 5. The task itself must still be visible and still running.
if ! task_state=$("$server" status 2>/dev/null | jq -r --argjson id "$task_id" \
        '.tasks[($id|tostring)].status | keys[0]'); then
    note 'could not read the task state after recovery'
    failures=$((failures + 1))
elif [ "$task_state" != "Running" ] && [ "$task_state" != "Queued" ]; then
    note "the task did not survive the transient failure: state=$task_state"
    failures=$((failures + 1))
fi

# --- 6. A transient read failure on logs/cancel/remove must not be reported as
#        "unknown AgentQ task id" --------------------------------------------
#
# Same root cause as the P0 above, on the three paths that resolve a task
# through compact_task/raw_compact_task instead of find_request_task.  Those
# helpers distinguish two outcomes: 4 means Pueue ANSWERED and this id is
# genuinely not visible; 1 (read failure) and 2/5 (malformed status) mean the
# task's existence is UNKNOWN.  Every call site collapsed all of them into
# "unknown AgentQ task id", whose documented meaning is an argument error --
# so a caller was told to fix its arguments when the truth was "Pueue could not
# be read, retry".  The identical defect was already fixed for find_request_task
# (see the header) but left on these three paths; measured 2026-10-07.
probe_request_id="smoke-transient-probe-$$-$(date -u '+%Y%m%dT%H%M%SZ')"
probe_request_id=${probe_request_id:0:120}
if ! probe_submit=$("$server" submit --workdir "$workdir" --label transient-probe \
        --request-id "$probe_request_id" -- sh -c 'sleep 300'); then
    printf '%s
' 'submit of the probe task failed' >&2
    exit 1
fi
probe_task_id=$(jq -er '.task_id' <<<"$probe_submit") || {
    printf 'probe submit returned no task_id: %s\n' "$probe_submit" >&2
    exit 1
}
sleep 2

# One injected failure at the SECOND `status --json` call: call 1 is the
# ensure_daemon probe, call 2 is the read inside compact_task/raw_compact_task.
# Failing call 1 instead would make the server reach for launchctl (a real
# service change).
for probe_command in logs cancel remove; do
    printf '2\n' > "$control/status.target"
    printf '0\n' > "$control/status.count"
    probe_status=0
    # stdout is discarded, not captured: the assertions are on stderr, the exit
    # code, and the surviving state.  (A captured-but-unread variable here is
    # what shellcheck reports as SC2034, the shape this repo deleted from the
    # server's remove_task -- it reads like a value about to be tested.)
    "$server" "$probe_command" "$probe_task_id" >/dev/null 2>"$work/probe.stderr" || probe_status=$?
    printf '0\n' > "$control/status.target"

    if grep -q 'unknown AgentQ task id' "$work/probe.stderr"; then
        note "$probe_command reported a transient Pueue read failure as an unknown task id"
        failures=$((failures + 1))
    fi
    if ! grep -q 'cannot inspect Pueue' "$work/probe.stderr"; then
        note "$probe_command did not report that Pueue could not be inspected"
        failures=$((failures + 1))
    fi
    if ! grep -qx 'agentq-server: reason=protocol_error' "$work/probe.stderr"; then
        note "$probe_command did not carry reason=protocol_error"
        failures=$((failures + 1))
    fi
    if [ "$probe_status" -ne 2 ]; then
        note "$probe_command returned $probe_status after a transient failure; expected 2"
        failures=$((failures + 1))
    fi
done

# A pending cancellation marker must not turn a READ FAILURE into
# 4/cancellation_pending ("the task is gone while the cancellation outcome
# remains unresolved").  On a read failure we do not know the task is gone, so
# the only honest answer is "cannot inspect Pueue".  The rc=4 gate that keeps
# these apart is load-bearing: without it this case reports the task as gone.
printf '{"version":1,"task_id":%s,"created_at":"2026-09-29T00:00:00Z","requested_at":"2026-09-29T00:05:00Z","reason":"kill_unconfirmed","state":"pending"}\n' \
    "$probe_task_id" > "$home/data/agentq-cancellations/$probe_task_id.json"
printf '2\n' > "$control/status.target"
printf '0\n' > "$control/status.count"
marker_status=0
marker_output=$("$server" cancel "$probe_task_id" 2>"$work/marker.stderr") || marker_status=$?
printf '0\n' > "$control/status.target"
rm -f "$home/data/agentq-cancellations/$probe_task_id.json"
if [ "$marker_status" -ne 2 ]; then
    note "cancel with a pending marker under a read failure returned $marker_status; expected 2"
    failures=$((failures + 1))
fi
if grep -q 'cancellation_pending' <<<"$marker_output"; then
    note "cancel claimed the task is gone (cancellation_pending) while Pueue was merely unreadable"
    failures=$((failures + 1))
fi
if ! grep -q 'cannot inspect Pueue' "$work/marker.stderr"; then
    note 'cancel with a pending marker did not report that Pueue could not be inspected'
    failures=$((failures + 1))
fi

# A confirmed-cancel replay needs a READABLE Pueue (0.1.29).  Before that, a
# tombstone alone was accepted while Pueue was unreadable -- but a tombstone
# only proves an EARLIER instance was removed, and Pueue recycles numeric ids,
# so the id may now be a NEW, running task.  Measured 2026-11-10 (independent
# review): old marker + old tombstone + a live reused id + one failed status
# read returned exit 0 with reused:true while the task stayed Running.  The
# answer must now be a failure, the same one logs/remove give for an
# unreadable queue.
replay_task_id=991177
replay_request_id="smoke-replay-$$-$(date -u '+%Y%m%dT%H%M%SZ')"
replay_request_id=${replay_request_id:0:120}
cat > "$home/data/agentq-requests/.tombstones/$replay_request_id.json" <<TOMBSTONE
{"version":1,"request_id":"$replay_request_id","task_id":$replay_task_id,"task_created_at":"2026-09-29T00:00:00Z","state":"removed","removed_at":"2026-09-29T01:00:00Z"}
TOMBSTONE
printf '{"version":1,"task_id":%s,"created_at":"2026-09-29T00:00:00Z","requested_at":"2026-09-29T00:05:00Z","reason":"kill_confirmed","state":"requested"}\n' \
    "$replay_task_id" > "$home/data/agentq-cancellations/$replay_task_id.json"
printf '2\n' > "$control/status.target"
printf '0\n' > "$control/status.count"
replay_status=0
replay_output=$("$server" cancel "$replay_task_id" 2>"$work/replay.stderr") || replay_status=$?
printf '0\n' > "$control/status.target"
rm -f "$home/data/agentq-cancellations/$replay_task_id.json" \
    "$home/data/agentq-requests/.tombstones/$replay_request_id.json"
if [ "$(jq -r '.reused' <<<"$replay_output" 2>/dev/null)" = true ]; then
    note "a tombstone-only marker replayed as reused:true while Pueue was unreadable; a tombstone proves only that an OLDER instance was removed"
    failures=$((failures + 1))
fi
if [ "$replay_status" -eq 0 ]; then
    note "a tombstone-only marker exited 0 while Pueue was unreadable; only a readable Pueue can prove the id is free"
    failures=$((failures + 1))
fi
if ! grep -qx 'agentq-server: reason=protocol_error' "$work/replay.stderr"; then
    note 'a tombstone-only replay did not carry reason=protocol_error'
    failures=$((failures + 1))
fi

# The OTHER direction, and the reason the two grades exist: the same marker with
# only an ACCEPTED RECORD behind it must NOT replay while Pueue is unreadable.
# Pueue recycles ids, so a record from an earlier instance satisfies the
# instance binding exactly, and the live task this call is about may be a
# different, still-running one -- answering "cancelled" there is a false success
# about a running task.  Same marker, same creation time, record instead of
# tombstone, and the answer must be a failure, not reused:true.
record_task_id=991178
record_request_id="smoke-replay-record-$$-$(date -u '+%Y%m%dT%H%M%SZ')"
record_request_id=${record_request_id:0:120}
cat > "$home/data/agentq-requests/$record_request_id.json" <<RECORD
{"version":1,"request_id":"$record_request_id","task_id":$record_task_id,"task_created_at":"2026-09-29T00:00:00Z","task_label":"agentq:$record_request_id","state":"accepted","created_at":"2026-09-29T00:00:00Z","payload":{"workdir":"/tmp","label":"command","argv":["sleep","300"]}}
RECORD
printf '{"version":1,"task_id":%s,"created_at":"2026-09-29T00:00:00Z","requested_at":"2026-09-29T00:05:00Z","reason":"kill_confirmed","state":"requested"}\n' \
    "$record_task_id" > "$home/data/agentq-cancellations/$record_task_id.json"
printf '2\n' > "$control/status.target"
printf '0\n' > "$control/status.count"
record_status=0
record_output=$("$server" cancel "$record_task_id" 2>"$work/record.stderr") || record_status=$?
printf '0\n' > "$control/status.target"
rm -f "$home/data/agentq-cancellations/$record_task_id.json" \
    "$home/data/agentq-requests/$record_request_id.json"
if [ "$(jq -r '.reused' <<<"$record_output" 2>/dev/null)" = true ]; then
    note "a record-only marker replayed as reused:true while Pueue was unreadable; the instance binding cannot distinguish a live reused id from the recorded one"
    failures=$((failures + 1))
fi
if [ "$record_status" -eq 0 ]; then
    note "a record-only marker exited 0 while Pueue was unreadable; only a tombstone proves the task is gone"
    failures=$((failures + 1))
fi

# The probe task must have survived all three, and logs must work again.
if ! probe_state=$("$server" status 2>/dev/null | jq -r --argjson id "$probe_task_id" \
        '.tasks[($id|tostring)].status | keys[0]'); then
    note 'could not read the probe task state after the injected failures'
    failures=$((failures + 1))
elif [ "$probe_state" != "Running" ] && [ "$probe_state" != "Queued" ]; then
    note "the probe task did not survive the injected failures: state=$probe_state"
    failures=$((failures + 1))
fi
# The log BODY is not asserted: the probe task is `sh -c 'sleep 300'`, which
# prints nothing, so an emptiness assertion would be measuring the fixture.  What
# matters is that `logs` succeeds again.
if ! "$server" logs "$probe_task_id" >/dev/null 2>/dev/null; then
    note 'logs failed for the probe task after Pueue recovered'
    failures=$((failures + 1))
fi

"$server" remove "$probe_task_id" >/dev/null 2>&1 || true
"$server" remove "$task_id" >/dev/null 2>&1 || true

if [ "$failures" -ne 0 ]; then
    printf 'transient-pueue-failure: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'transient-pueue-failure checks passed: exit=2/reason live-request-preserved=yes tombstones=%s recovery=ok task=survived\n' "$tombstones_written"
