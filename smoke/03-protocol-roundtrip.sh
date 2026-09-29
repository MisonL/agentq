#!/usr/bin/env bash
# Smoke: the JSON protocol round-trip against a real runtime, when one is
# available.  submit -> status -> logs -> wait -> remove, plus lookup, plus the
# two cancel paths (a running task is killed; a queued task is removed and must
# then surface as removed/5 rather than as a completed task), plus cancel
# replay, plus base64 log delivery for non-UTF-8 output, plus doctor.
#
# This layer needs an installed AgentQ runtime (an agentq home containing the
# `pueue` binary and a pueued).  The project does not vendor those binaries and
# the installer downloads them, so this check SKIPS when no runtime is present
# rather than reaching the network.  Set AGENTQ_SMOKE_HOME to point at one.
set -euo pipefail

runtime_home=${AGENTQ_SMOKE_HOME:-}

if [ -z "$runtime_home" ]; then
    for candidate in "$HOME/.agentq" "$HOME/.local/share/agentq"; do
        if [ -x "$candidate/pueue" ] && [ -x "$candidate/agentq-server" ]; then
            runtime_home=$candidate
            break
        fi
    done
fi

if [ -z "$runtime_home" ] || [ ! -x "$runtime_home/pueue" ]; then
    printf '%s\n' 'protocol-roundtrip: SKIPPED (no installed runtime; set AGENTQ_SMOKE_HOME to enable)'
    exit 0
fi

for command_name in jq mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$command_name" >&2
        exit 2
    }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/agentq-smoke-protocol.XXXXXX")
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

server="$runtime_home/agentq-server"
request_id="smoke-$$-$(date -u '+%Y%m%dT%H%M%SZ')"

# The two instance-binding fixtures below plant files into the runtime's data
# directories.  Their paths are declared here, before any protocol work, so a
# leftover from an interrupted run is reported as the fixture collision it is.
# Declared later, a leftover record instead derails an earlier protocol step and
# the operator sees an unrelated failure ("ambiguous AgentQ identity") with no
# hint that the contract went unexercised.
stale_task_id=999000
stale_marker="$runtime_home/data/agentq-cancellations/$stale_task_id.json"
stale_record="$runtime_home/data/agentq-requests/smoke-stale-instance-aaaa.json"
reused_task_id=999001
reused_older_record="$runtime_home/data/agentq-requests/smoke-reuse-instance-aaaa.json"
reused_newer_record="$runtime_home/data/agentq-requests/smoke-reuse-instance-bbbb.json"
reused_marker="$runtime_home/data/agentq-cancellations/$reused_task_id.json"
ambiguous_record="$runtime_home/data/agentq-requests/smoke-ambiguous-old-aaaa.json"

for leftover in "$stale_marker" "$stale_record" \
        "$reused_older_record" "$reused_newer_record" "$reused_marker" \
        "$ambiguous_record"; do
    if [ -e "$leftover" ]; then
        printf 'fixture leftover blocks the run: %s\n' "$leftover" >&2
        printf '%s\n' 'clean it up and re-run (the instance-binding contract was NOT exercised)' >&2
        exit 1
    fi
done

# submit
if ! submit_output=$("$server" submit --workdir "$work" --label smoke \
        --request-id "$request_id" -- sh -c 'printf smoke-ok'); then
    printf '%s\n' 'submit failed' >&2
    exit 1
fi
task_id=$(jq -er '.task_id' <<<"$submit_output") || {
    printf 'submit returned no task_id: %s\n' "$submit_output" >&2
    exit 1
}

# lookup must find the same task
lookup_output=$("$server" lookup "$request_id") || {
    printf '%s\n' 'lookup failed' >&2
    exit 1
}
test "$(jq -r '.task_id' <<<"$lookup_output")" = "$task_id" || {
    printf '%s\n' 'lookup returned a different task_id' >&2
    exit 1
}

# status must list it
status_output=$("$server" status) || {
    printf '%s\n' 'status failed' >&2
    exit 1
}
jq -e --argjson id "$task_id" '.tasks | has($id|tostring)' <<<"$status_output" >/dev/null || {
    printf 'status does not list task %s\n' "$task_id" >&2
    exit 1
}

# wait must reach a terminal state.  The contract has three shapes:
#   {task: {...}}                     -- completed; exit 0 only if the task succeeded
#   {task_id, state: "removed"}       -- removed while waiting; exit 5
#   {task_id, state: "unavailable"}   -- final state unknown; exit 6
# A successful wait therefore means exit 0 AND a task whose Done.result is
# "Success".  Exit code alone is not enough, and neither is the payload alone.
wait_status=0
wait_output=$("$server" wait "$task_id") || wait_status=$?
if [ "$wait_status" -ne 0 ]; then
    printf 'wait exited %s: %s\n' "$wait_status" "$wait_output" >&2
    exit 1
fi
jq -e '.task.status.Done.result == "Success"' <<<"$wait_output" >/dev/null || {
    printf 'wait did not report a successful task: %s\n' "$wait_output" >&2
    exit 1
}

# A failing task must NOT be reported as a success.  This is the other half of
# the contract above, and it is the half a caller is most likely to get wrong:
# submit a command that exits non-zero and require wait to reject it.
failure_request_id="${request_id}-fail"
if ! failure_submit=$("$server" submit --workdir "$work" --label smoke-fail \
        --request-id "$failure_request_id" -- sh -c 'exit 7'); then
    printf '%s\n' 'submit of the failing task failed' >&2
    exit 1
fi
failure_task_id=$(jq -er '.task_id' <<<"$failure_submit") || {
    printf 'failing submit returned no task_id: %s\n' "$failure_submit" >&2
    exit 1
}
failure_status=0
failure_output=$("$server" wait "$failure_task_id") || failure_status=$?
if [ "$failure_status" -eq 0 ]; then
    printf 'wait reported exit 0 for a task that exited non-zero: %s\n' "$failure_output" >&2
    exit 1
fi
if jq -e '.task.status.Done.result == "Success"' <<<"$failure_output" >/dev/null 2>&1; then
    printf 'wait reported Done.result Success for a failing task: %s\n' "$failure_output" >&2
    exit 1
fi

# cancel on a task that has already finished: exit 2, but with the
# `task_not_running` class -- NOT `protocol_error`.  This is the case 02 cannot
# cover (its runtime is a stub with no real tasks), and it is exactly the case
# where a caller must not "fix the arguments": the answer is to read
# status/wait, and the machine-readable reason is what tells it so.
finished_cancel_status=0
finished_cancel_stderr=$("$server" cancel "$failure_task_id" 2>&1 >/dev/null) || finished_cancel_status=$?
if [ "$finished_cancel_status" -ne 2 ]; then
    printf 'cancel of a finished task exited %s, expected 2: %s\n' \
        "$finished_cancel_status" "$finished_cancel_stderr" >&2
    exit 1
fi
if ! grep -qF -- 'task is not running' <<<"$finished_cancel_stderr"; then
    printf 'cancel of a finished task did not say "task is not running": %s\n' \
        "$finished_cancel_stderr" >&2
    exit 1
fi
if ! grep -qxF -- "agentq-server: reason=task_not_running" <<<"$finished_cancel_stderr"; then
    printf 'cancel of a finished task did not carry reason=task_not_running: %s\n' \
        "$finished_cancel_stderr" >&2
    exit 1
fi

# lookup for an unknown request id must be exit 3 with state not_found -- not a
# completion, and not something a caller may treat as a transient error.
lookup_status=0
lookup_output=$("$server" lookup "${request_id}-absent") || lookup_status=$?
if [ "$lookup_status" -ne 3 ]; then
    printf 'lookup of an unknown request exited %s, expected 3: %s\n' \
        "$lookup_status" "$lookup_output" >&2
    exit 1
fi
jq -e '.state == "not_found"' <<<"$lookup_output" >/dev/null || {
    printf 'lookup of an unknown request did not report not_found: %s\n' "$lookup_output" >&2
    exit 1
}

# A stale EMPTY operation lock must be recovered rather than blocking forever.
# This exercises stat_mtime (the lock's mtime decides staleness) and the
# recovery branch in acquire_operation_lock -- a path nothing else here covers,
# and one that is impractical to trigger by hand on a live install.
lock_directory="$runtime_home/runtime/agentq-operation.lock"
if [ -e "$lock_directory" ]; then
    printf 'operation lock already present before the recovery check: %s\n' "$lock_directory" >&2
    exit 1
fi
mkdir -p "$lock_directory"
# Backdate well past the server's empty-lock grace period.
# A failure to backdate means this assertion cannot be made -- which is NOT the
# same as the contract holding.  It used to print "skipping the recovery check"
# and fall through while the summary line still claimed `stale-lock=recovered`.
touch -t 202001010000 "$lock_directory" 2>/dev/null || {
    printf '%s\n' 'cannot backdate the lock directory; the stale-lock recovery contract was NOT exercised' >&2
    exit 1
}
if [ -d "$lock_directory" ]; then
    if ! "$server" status >/dev/null 2>"$work/recovery.stderr"; then
        printf 'status failed while recovering a stale empty lock: %s\n' \
            "$(head -1 "$work/recovery.stderr")" >&2
        exit 1
    fi
    if [ -e "$lock_directory" ]; then
        printf '%s\n' 'a stale empty operation lock was not recovered' >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# cancel: the two paths, and what each one must NOT be reported as.
#
# SKILL.md gives cancel two success shapes:
#   running target -> pueue kill    -> {action: cancel_requested, cancellation_requested_at}
#   queued  target -> pueue remove  -> the same, plus cancellation_mode: "queued_removed"
# and says the second one must make a later `wait` report removed/5 rather than
# a completed task.  Nothing else in smoke/ covers either path, and both are
# easy to get wrong in the direction that matters: reporting a cancelled task
# as a finished one.
# ---------------------------------------------------------------------------

cancel_cleanup_ids=''

# --- a running task: cancel must kill it, and wait must not call it a success
running_request_id="${request_id}-run"
if ! running_submit=$("$server" submit --workdir "$work" --label smoke-run \
        --request-id "$running_request_id" -- sleep 60); then
    printf '%s\n' 'submit for the running-cancel case failed' >&2
    exit 1
fi
running_task_id=$(jq -er '.task_id' <<<"$running_submit") || {
    printf 'running-cancel submit returned no task_id: %s\n' "$running_submit" >&2
    exit 1
}
cancel_cleanup_ids="$cancel_cleanup_ids $running_task_id"

# The task must actually be running before cancel takes the kill path.
running_ready=0
for _ in $(seq 1 40); do
    if "$server" status 2>/dev/null \
        | jq -e --argjson id "$running_task_id" \
            '.tasks[($id|tostring)].status | has("Running")' >/dev/null 2>&1; then
        running_ready=1
        break
    fi
    sleep 0.5
done
if [ "$running_ready" -ne 1 ]; then
    printf 'task %s never reached Running; cannot exercise the kill path\n' \
        "$running_task_id" >&2
    exit 1
fi

running_cancel_status=0
running_cancel=$("$server" cancel "$running_task_id") || running_cancel_status=$?
if [ "$running_cancel_status" -ne 0 ]; then
    printf 'cancel of a running task exited %s: %s\n' \
        "$running_cancel_status" "$running_cancel" >&2
    exit 1
fi
jq -e '.action == "cancel_requested"' <<<"$running_cancel" >/dev/null || {
    printf 'cancel of a running task did not report cancel_requested: %s\n' "$running_cancel" >&2
    exit 1
}
jq -e '.cancellation_requested_at' <<<"$running_cancel" >/dev/null || {
    printf 'cancel did not report cancellation_requested_at: %s\n' "$running_cancel" >&2
    exit 1
}
# A killed task is not a removed one: queued_removed must not appear here.
if jq -e '.cancellation_mode == "queued_removed"' <<<"$running_cancel" >/dev/null 2>&1; then
    printf 'cancel of a running task claimed queued_removed: %s\n' "$running_cancel" >&2
    exit 1
fi

# wait must reject it.  The underlying result is Killed or Failed depending on
# the platform, so assert the contract (not Success, cancellation recorded)
# rather than a particular word.
killed_status=0
killed_output=$("$server" wait "$running_task_id") || killed_status=$?
if [ "$killed_status" -eq 0 ]; then
    printf 'wait exited 0 for a cancelled task: %s\n' "$killed_output" >&2
    exit 1
fi
if jq -e '.task.status.Done.result == "Success"' <<<"$killed_output" >/dev/null 2>&1; then
    printf 'wait reported Success for a cancelled task: %s\n' "$killed_output" >&2
    exit 1
fi
jq -e '.task.agentq.cancellation_requested_at' <<<"$killed_output" >/dev/null || {
    printf 'wait did not surface cancellation_requested_at: %s\n' "$killed_output" >&2
    exit 1
}
jq -e '.task.agentq.cancellation_reason == "user_requested"' <<<"$killed_output" >/dev/null || {
    printf 'wait did not surface cancellation_reason user_requested: %s\n' "$killed_output" >&2
    exit 1
}

# --- a queued task: cancel must remove it, and wait must report removed/5
#
# A task whose log is not valid UTF-8 must come back base64-encoded rather than
# as mangled text.  SKILL.md requires a caller to decode `output_base64` when
# `output_encoding` is "base64"; returning the bytes as a string would silently
# corrupt them.  This needs `--tail all`: Pueue only reports the unreadable file
# on the full-log path, so the default (numbered) tail never reaches it.
binary_request_id="${request_id}-bin"
if ! binary_submit=$("$server" submit --workdir "$work" --label smoke-bin \
        --request-id "$binary_request_id" -- \
        sh -c 'printf "\377\376\000binary\377"'); then
    printf '%s\n' 'submit for the binary-log case failed' >&2
    exit 1
fi
binary_task_id=$(jq -er '.task_id' <<<"$binary_submit") || {
    printf 'binary-log submit returned no task_id: %s\n' "$binary_submit" >&2
    exit 1
}
cancel_cleanup_ids="$cancel_cleanup_ids $binary_task_id"
binary_wait_status=0
"$server" wait "$binary_task_id" >/dev/null 2>&1 || binary_wait_status=$?
if [ "$binary_wait_status" -ne 0 ]; then
    printf 'the binary-log task did not succeed (wait exited %s)\n' "$binary_wait_status" >&2
    exit 1
fi

binary_log_status=0
binary_log=$("$server" logs "$binary_task_id" --tail all 2>"$work/binary.err") || binary_log_status=$?
if [ "$binary_log_status" -ne 0 ]; then
    printf 'logs --tail all exited %s for a non-UTF-8 log: %s\n' \
        "$binary_log_status" "$(head -1 "$work/binary.err")" >&2
    exit 1
fi
jq -e '.output_encoding == "base64"' <<<"$binary_log" >/dev/null || {
    printf 'a non-UTF-8 log was not reported as base64: %s\n' \
        "$(head -c 200 <<<"$binary_log")" >&2
    exit 1
}
jq -e '.output_base64 | type == "string" and length > 0' <<<"$binary_log" >/dev/null || {
    printf 'a base64 log response carried no output_base64: %s\n' \
        "$(head -c 200 <<<"$binary_log")" >&2
    exit 1
}
# Decoding must reproduce the exact bytes the command wrote.  Compare against a
# fresh encoding of the expected bytes so a truncated or re-encoded payload is
# caught rather than merely "some base64".
decoded=$(jq -r '.output_base64' <<<"$binary_log" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n') || {
    printf 'the base64 log payload did not decode: %s\n' \
        "$(head -c 200 <<<"$binary_log")" >&2
    exit 1
}
expected=$(printf '\377\376\000binary\377' | od -An -tx1 | tr -d ' \n')
if [ "$decoded" != "$expected" ]; then
    printf 'the decoded log did not match the bytes written: %s vs %s\n' \
        "$decoded" "$expected" >&2
    exit 1
fi

# A task is Queued only when no slot is free, so fill the slots FIRST and only
# then submit the victim -- submitting the victim first would let it take the
# free slot and run, and the case would silently test nothing.  How many slots a
# runtime has is its own config's business, so keep adding blockers until a
# freshly submitted task is observed Queued rather than assuming a number.
blockers=''
slots_full=0
for attempt in $(seq 1 12); do
    blocker_request_id="${request_id}-blk${attempt}"
    if ! blocker_submit=$("$server" submit --workdir "$work" --label smoke-blocker \
            --request-id "$blocker_request_id" -- sleep 60); then
        break
    fi
    blocker_id=$(jq -r '.task_id' <<<"$blocker_submit") || blocker_id=''
    [ -n "$blocker_id" ] || break
    blockers="$blockers $blocker_id"
    cancel_cleanup_ids="$cancel_cleanup_ids $blocker_id"
    sleep 1
    if "$server" status 2>/dev/null \
        | jq -e --argjson id "$blocker_id" \
            '.tasks[($id|tostring)].status | has("Queued")' >/dev/null 2>&1; then
        slots_full=1
        break
    fi
done
if [ "$slots_full" -ne 1 ]; then
    printf '%s\n' 'could not fill the runtime slots; cannot exercise the queued_removed path' >&2
    exit 1
fi

victim_request_id="${request_id}-queued"
if ! victim_submit=$("$server" submit --workdir "$work" --label smoke-queued \
        --request-id "$victim_request_id" -- sleep 60); then
    printf '%s\n' 'submit for the queued-cancel case failed' >&2
    exit 1
fi
victim_task_id=$(jq -er '.task_id' <<<"$victim_submit") || {
    printf 'queued-cancel submit returned no task_id: %s\n' "$victim_submit" >&2
    exit 1
}
cancel_cleanup_ids="$cancel_cleanup_ids $victim_task_id"

victim_queued=0
for _ in $(seq 1 20); do
    if "$server" status 2>/dev/null \
        | jq -e --argjson id "$victim_task_id" \
            '.tasks[($id|tostring)].status | has("Queued")' >/dev/null 2>&1; then
        victim_queued=1
        break
    fi
    sleep 0.5
done
if [ "$victim_queued" -ne 1 ]; then
    printf 'task %s never reached Queued; cannot exercise the queued_removed path\n' \
        "$victim_task_id" >&2
    exit 1
fi

queued_cancel_status=0
queued_cancel=$("$server" cancel "$victim_task_id") || queued_cancel_status=$?
if [ "$queued_cancel_status" -ne 0 ]; then
    printf 'cancel of a queued task exited %s: %s\n' \
        "$queued_cancel_status" "$queued_cancel" >&2
    exit 1
fi
jq -e '.cancellation_mode == "queued_removed"' <<<"$queued_cancel" >/dev/null || {
    printf 'cancel of a queued task did not report queued_removed: %s\n' "$queued_cancel" >&2
    exit 1
}
jq -e '.action == "cancel_requested"' <<<"$queued_cancel" >/dev/null || {
    printf 'queued cancel did not report cancel_requested: %s\n' "$queued_cancel" >&2
    exit 1
}

# A cancel whose task has already left Pueue must REPLAY, not fail.  A confirmed
# cancellation is recorded in the task's cancellation marker (state
# "requested") and that marker outlives the task, so asking again must return
# the same answer with reused:true and exit 0 -- not "unknown AgentQ task id"
# with exit 2, which is the code for an argument error and would tell a caller
# its retry was malformed.  This is the queued_removed case above, replayed.
replay_status=0
replay_output=$("$server" cancel "$victim_task_id" 2>"$work/replay.err") || replay_status=$?
if [ "$replay_status" -ne 0 ]; then
    printf 'replaying a confirmed cancel exited %s, expected 0: %s\n' \
        "$replay_status" "$(head -1 "$work/replay.err")" >&2
    exit 1
fi
jq -e '.action == "cancel_requested"' <<<"$replay_output" >/dev/null || {
    printf 'a replayed cancel did not report cancel_requested: %s\n' "$replay_output" >&2
    exit 1
}
jq -e '.reused == true' <<<"$replay_output" >/dev/null || {
    printf 'a replayed cancel did not report reused: %s\n' "$replay_output" >&2
    exit 1
}
# The replay must report the ORIGINAL cancellation time, not a new one.
[ "$(jq -r '.cancellation_requested_at' <<<"$replay_output")" \
    = "$(jq -r '.cancellation_requested_at' <<<"$queued_cancel")" ] || {
    printf 'the replayed cancel changed cancellation_requested_at: %s vs %s\n' \
        "$(jq -r '.cancellation_requested_at' <<<"$replay_output")" \
        "$(jq -r '.cancellation_requested_at' <<<"$queued_cancel")" >&2
    exit 1
}

# The replay must be pinned to the same task INSTANCE.  Pueue reuses numeric
# task ids, so a cancellation marker left behind by an earlier task that had
# this id must not make an unrelated task look like a replay.  Plant exactly
# that: a marker whose recorded creation time disagrees with the creation time
# AgentQ recorded for the id, and require the cancel to be refused.
stale_marker_created=0
stale_record_created=0
if [ -d "$runtime_home/data/agentq-cancellations" ] \
    && [ -d "$runtime_home/data/agentq-requests" ]; then
    # Leftovers are rejected up top, before any protocol work.  That used to
    # skip the whole assertion silently while the summary claimed the
    # stale-marker rejection held; the summary is now only printed when it ran.
    if true; then
        printf '{"task_id":%s,"created_at":"2001-01-01T00:00:00Z","requested_at":"2001-01-01T00:00:01Z","reason":"user_requested","state":"requested"}\n' \
            "$stale_task_id" > "$stale_marker"
        printf '{"version":1,"request_id":"smoke-stale-instance-aaaa","payload":{"workdir":"%s","label":"stale","argv":["true"]},"task_label":"agentq:smoke-stale-instance-aaaa","state":"accepted","task_id":%s,"task_created_at":"2002-02-02T00:00:00Z","created_at":"2001-01-01T00:00:00Z"}\n' \
            "$work" "$stale_task_id" > "$stale_record"
        stale_marker_created=1
        stale_record_created=1
    fi
fi
if [ "$stale_marker_created" -eq 1 ] && [ "$stale_record_created" -eq 1 ]; then
    stale_status=0
    stale_output=$("$server" cancel "$stale_task_id" 2>"$work/stale.err") || stale_status=$?
    rm -f -- "$stale_marker" "$stale_record"
    if [ "$stale_status" -ne 2 ]; then
        printf 'a stale marker at a reused task id was treated as a replay (exit %s): %s\n' \
            "$stale_status" "$stale_output" >&2
        exit 1
    fi
    grep -q 'unknown AgentQ task id' "$work/stale.err" || {
        printf 'a stale marker was refused for the wrong reason: %s\n' \
            "$(head -1 "$work/stale.err")" >&2
        exit 1
    }
fi

# A replay must also survive task-id REUSE.  Pueue recycles numeric ids, so an id
# that several tasks have used accumulates several records, while the
# cancellation marker names only the LATEST instance.  A scan that returns the
# FIRST record carrying the id therefore compares the marker against an EARLIER
# instance's creation time, refuses a perfectly valid replay with exit 2
# "unknown AgentQ task id", and tells the caller its retry was malformed.
# Plant exactly that shape: two records for one id, the first-sorting one
# belonging to an older instance, and a marker naming the newer one.  The cancel
# must still replay.
reused_fixture_ready=0
if [ -d "$runtime_home/data/agentq-cancellations" ] \
    && [ -d "$runtime_home/data/agentq-requests" ]; then
    # Leftovers are rejected up top, before any protocol work.
    if true; then
        printf '{"version":1,"request_id":"smoke-reuse-instance-aaaa","payload":{"workdir":"%s","label":"reuse-older","argv":["true"]},"task_label":"agentq:smoke-reuse-instance-aaaa","state":"accepted","task_id":%s,"task_created_at":"2003-03-03T00:00:00Z","created_at":"2003-03-03T00:00:00Z"}\n' \
            "$work" "$reused_task_id" > "$reused_older_record"
        printf '{"version":1,"request_id":"smoke-reuse-instance-bbbb","payload":{"workdir":"%s","label":"reuse-newer","argv":["true"]},"task_label":"agentq:smoke-reuse-instance-bbbb","state":"accepted","task_id":%s,"task_created_at":"2004-04-04T00:00:00Z","created_at":"2004-04-04T00:00:00Z"}\n' \
            "$work" "$reused_task_id" > "$reused_newer_record"
        printf '{"task_id":%s,"created_at":"2004-04-04T00:00:00Z","requested_at":"2004-04-04T00:00:01Z","reason":"user_requested","state":"requested"}\n' \
            "$reused_task_id" > "$reused_marker"
        reused_fixture_ready=1
    fi
fi
if [ "$reused_fixture_ready" -eq 1 ]; then
    reused_status=0
    reused_output=$("$server" cancel "$reused_task_id" 2>"$work/reused.err") || reused_status=$?
    rm -f -- "$reused_marker" "$reused_older_record" "$reused_newer_record"
    if [ "$reused_status" -ne 0 ]; then
        printf 'a replay at a REUSED task id was refused (exit %s), so a caller would be told its retry was malformed: %s\n' \
            "$reused_status" "$(head -1 "$work/reused.err")" >&2
        exit 1
    fi
    jq -e '.reused == true' <<<"$reused_output" >/dev/null || {
        printf 'a replay at a reused task id did not report reused: %s\n' "$reused_output" >&2
        exit 1
    }
fi

# This is the assertion the whole case exists for: a task removed because it
# was cancelled must NOT come back as a completed task.
queued_wait_status=0
queued_wait=$("$server" wait "$victim_task_id") || queued_wait_status=$?
if [ "$queued_wait_status" -ne 5 ]; then
    printf 'wait after queued_removed exited %s, expected 5: %s\n' \
        "$queued_wait_status" "$queued_wait" >&2
    exit 1
fi
jq -e '.state == "removed"' <<<"$queued_wait" >/dev/null || {
    printf 'wait after queued_removed did not report removed: %s\n' "$queued_wait" >&2
    exit 1
}
if jq -e '.task.status.Done.result' <<<"$queued_wait" >/dev/null 2>&1; then
    printf 'wait after queued_removed reported a task result: %s\n' "$queued_wait" >&2
    exit 1
fi

# lookup must agree: the same request id is removed/5, not not_found and not a
# completion.
queued_lookup_status=0
queued_lookup=$("$server" lookup "$victim_request_id") || queued_lookup_status=$?
if [ "$queued_lookup_status" -ne 5 ]; then
    printf 'lookup after queued_removed exited %s, expected 5: %s\n' \
        "$queued_lookup_status" "$queued_lookup" >&2
    exit 1
fi
jq -e '.state == "removed"' <<<"$queued_lookup" >/dev/null || {
    printf 'lookup after queued_removed did not report removed: %s\n' "$queued_lookup" >&2
    exit 1
}

# Clean up every task this case created.  `remove` (not `cancel`) is what
# archives the request record; leaving the records behind would let them
# accumulate on a long-lived runtime, and because Pueue reuses numeric task ids
# a later run can then see two active records sharing one id and get a genuine
# "ambiguous AgentQ identity" failure.
#
# A single `remove` is not enough for the blocker that was RUNNING when the
# victim was cancelled: cancelling it races the in-flight kill, and the record
# is left in `removing` (exit 4) rather than archived.  That is exactly the
# documented meaning of `removing` -- the intent is persisted and only another
# explicit `remove` continues it -- so retry until the record is gone.
#
# The invariant is "no active request record still references this task id",
# not "remove exited 0": the victim is already removed, so `remove` on it exits
# 2, which is equally clean.  Checking the records themselves also means a
# server that wrongly reports success cannot fake the cleanup.
request_record_directory="$runtime_home/data/agentq-requests"
record_still_active() {
    [ -d "$request_record_directory" ] || return 1
    # `-s ... any(...)`: with several files, plain `-e` keys its exit status off
    # the LAST file only, so a match in an earlier record would be missed.
    jq -e -s --argjson id "$1" 'any(.[]; .task_id == $id)' "$request_record_directory"/*.json >/dev/null 2>&1
}

cleanup_remaining=''
for id in $cancel_cleanup_ids; do
    for _ in $(seq 1 40); do
        record_still_active "$id" || break
        "$server" remove "$id" >/dev/null 2>&1 || true
        record_still_active "$id" || break
        sleep 0.5
    done
    record_still_active "$id" && cleanup_remaining="$cleanup_remaining $id"
done
if [ -n "$cleanup_remaining" ]; then
    printf 'cleanup left an active request record for task(s):%s\n' "$cleanup_remaining" >&2
    exit 1
fi

# doctor is the documented first call on a new host, and its happy path was
# never exercised -- only its argument rejection was.  It must report the
# runtime it is actually using (versions on stderr) and end with a usable queue
# status on stdout, so that a caller can tell "host is ready" from "host is
# half-deployed" instead of silently falling back to plain SSH.
doctor_status=0
doctor_out=$("$server" doctor 2>"$work/doctor.err") || doctor_status=$?
if [ "$doctor_status" -ne 0 ]; then
    printf 'doctor exited %s: %s\n' "$doctor_status" "$(head -1 "$work/doctor.err")" >&2
    exit 1
fi
grep -q '^pueue=' "$work/doctor.err" || {
    printf 'doctor did not report the pueue version: %s\n' \
        "$(head -c 200 "$work/doctor.err")" >&2
    exit 1
}
grep -q '^pueued=' "$work/doctor.err" || {
    printf 'doctor did not report the pueued version: %s\n' \
        "$(head -c 200 "$work/doctor.err")" >&2
    exit 1
}
jq -e 'type == "object" and (.group | type == "object")' <<<"$doctor_out" >/dev/null || {
    printf 'doctor did not end with a usable queue status: %s\n' \
        "$(head -c 200 <<<"$doctor_out")" >&2
    exit 1
}

# logs must be retrievable
"$server" logs "$task_id" >/dev/null || {
    printf '%s\n' 'logs failed' >&2
    exit 1
}

# remove must succeed, for both tasks
for id in "$task_id" "$failure_task_id"; do
    "$server" remove "$id" >/dev/null || {
        printf 'remove failed for task %s\n' "$id" >&2
        exit 1
    }
done

# ---------------------------------------------------------------------------
# When two instances share one recycled task id, `wait` must refuse to guess.
# Pueue recycles numeric ids, so a long-lived runtime can hold an older record
# for an id alongside the live task using it now.  Reporting either instance's
# outcome as the other's is exactly the confusion instance-binding exists to
# prevent, so the contract is exit 6 / {"state": "unavailable"} -- the same
# "cannot confirm" answer `wait` gives when the queue is unreachable.  This is
# the id-reuse safety half of that work (the replay half is covered above).
#
# No separate control is needed here: the two `wait` assertions earlier in this
# script already require real answers (exit 0 + Done.result == "Success", and a
# rejected failure), so a server that answered 6 to everything would fail there
# rather than pass here.
# ---------------------------------------------------------------------------
ambiguous_request_id="${request_id}-ambiguous"
if ! ambiguous_submit=$("$server" submit --workdir "$work" --label smoke-ambiguous \
        --request-id "$ambiguous_request_id" -- sleep 60); then
    printf '%s\n' 'submit for the ambiguous-identity case failed' >&2
    exit 1
fi
ambiguous_task_id=$(jq -er '.task_id' <<<"$ambiguous_submit") || {
    printf 'ambiguous-identity submit returned no task_id: %s\n' "$ambiguous_submit" >&2
    exit 1
}

# Plant the second instance: a well-formed record for a DIFFERENT request that
# claims the same task id at a different creation time.  It must be valid in
# every other respect -- an invalid record is rejected by the metadata loader
# before the identity check ever runs, which would make this pass for the wrong
# reason (measured: the run dies at an earlier protocol step instead).
printf '{"version":1,"request_id":"smoke-ambiguous-old-aaaa","payload":{"workdir":"%s","label":"ambiguous-old","argv":["true"]},"task_label":"agentq:smoke-ambiguous-old-aaaa","state":"accepted","task_id":%s,"task_created_at":"2005-05-05T00:00:00Z","created_at":"2005-05-05T00:00:00Z"}\n' \
    "$work" "$ambiguous_task_id" > "$ambiguous_record"

ambiguous_status=0
ambiguous_output=$("$server" wait "$ambiguous_task_id" 2>"$work/ambiguous.err") || ambiguous_status=$?
rm -f -- "$ambiguous_record"

if [ "$ambiguous_status" -ne 6 ]; then
    printf 'wait on an id shared by two instances exited %s, expected 6: %s\n' \
        "$ambiguous_status" "$ambiguous_output" >&2
    exit 1
fi
jq -e '.state == "unavailable"' <<<"$ambiguous_output" >/dev/null || {
    printf 'wait on an ambiguous id did not report unavailable: %s\n' "$ambiguous_output" >&2
    exit 1
}
# Exit 6 must never carry a verdict: a caller that reads only the payload must
# not be able to mistake this for a finished task.
jq -e 'has("task") | not' <<<"$ambiguous_output" >/dev/null || {
    printf 'wait on an ambiguous id also reported a task outcome: %s\n' "$ambiguous_output" >&2
    exit 1
}
grep -q 'ambiguous AgentQ identity' "$work/ambiguous.err" || {
    printf 'an ambiguous id was refused for the wrong reason: %s\n' \
        "$(head -1 "$work/ambiguous.err")" >&2
    exit 1
}

# Clean up: the planted record is gone, so the id is unambiguous again and the
# task can be removed normally.  Assert on the records themselves rather than on
# remove's exit code -- a server that wrongly reported success could not fake it.
for _ in $(seq 1 40); do
    record_still_active "$ambiguous_task_id" || break
    "$server" remove "$ambiguous_task_id" >/dev/null 2>&1 || true
    record_still_active "$ambiguous_task_id" || break
    sleep 0.5
done
if record_still_active "$ambiguous_task_id"; then
    printf 'cleanup left an active request record for ambiguous task %s\n' "$ambiguous_task_id" >&2
    exit 1
fi

# Every token below is printed only after its assertion actually ran -- the
# three that used to be conditionally skipped now exit 1 instead, so a green
# summary cannot coexist with an unexercised contract.
printf 'protocol-roundtrip checks passed: home=%s task=%s fail-task=%s lookup=not_found stale-lock=recovered cancel-running=ok cancel-queued=queued_removed/5 cancel-replay=reused reuse-replay=reused finished-cancel=task_not_running binary-log=base64 doctor=ok ambiguous-id=unavailable/6\n' \
    "$runtime_home" "$task_id" "$failure_task_id"
