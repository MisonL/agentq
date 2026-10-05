#!/usr/bin/env bash
# Smoke: the request-record READ paths of `submit`, `cancel` and `remove`.
#
# Companion to smoke/26, which pinned `lookup`/`wait`.  smoke/18 pinned the
# `status` metadata scan and recorded the gap; 26 closed the lookup/wait half,
# this closes the rest.  Together they cover every command whose behaviour
# depends on reading a request record.
#
# These are the decisions being pinned, all measured on the real server first:
#
#   submit: an existing record whose payload differs -> refuse (exit 2); a
#           leftover tombstone -> refuse as consumed; a record in `adding` ->
#           exit 4 (ambiguous, never re-enqueue).
#   cancel: first call kills/removes and writes a `requested` marker (exit 0);
#           a replay with a matching marker returns reused:true (exit 0); an
#           unknown task id is exit 2.
#   remove: a matching accepted record is archived into a tombstone and the task
#           removed (exit 0); a task whose record is MISSING refuses (exit 2,
#           "missing AgentQ request record while removing task") rather than
#           silently dropping the metadata.
#
# Reachability bounds, measured and recorded so the green is not over-read:
#   * submit's `removing` branch is unreachable here -- `ensure_daemon` ->
#     `recover_removing_requests` archives the record before submit's own
#     dispatch reads it (the same masking smoke/26 documents for wait).
#   * cancel's `queued` branch (queue removal + `queued_removed`) needs a real
#     queued task; it is covered end-to-end in smoke/03 and is NOT claimed here.
#   * the cancellation-marker replay is a REQUEST-record-adjacent path, but the
#     marker's own contract (instance binding, stale rejection) lives in smoke/03.
#
# Two harness facts inherited from smoke/18 and smoke/26, both load-bearing:
#   * the server derives its root from `dirname($0)`, so the binary is COPIED
#     into the tree and the tree IS the runtime;
#   * `normalize_workdir` resolves /tmp -> /private/tmp (measured), so a
#     hand-written "matching" payload must use the resolved path or every
#     submit case fails on the payload-mismatch branch instead of its target.
#
# No SKIP: needs only bash, jq and cp.

set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/agentq-smoke-writes.XXXXXX")
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

mkdir -p "$work/config" "$work/data/task_logs" \
    "$work/data/agentq-cancellations" \
    "$work/data/agentq-requests/.locks" \
    "$work/data/agentq-requests/.tombstones" \
    "$work/runtime"
cp "${AGENTQ_SMOKE_SERVER:-$root/skill/assets/unix/agentq-server}" "$work/agentq-server"
cp "$root/skill/assets/unix/pueue.yml" "$work/config/pueue.yml"
chmod 700 "$work/agentq-server"

# The pueue stub.  `write_stub <tasks-json> <add-id>` rewrites it so each case
# controls whether task 1001 is visible and what `pueue add` returns.
write_stub() {
    local tasks=$1 add_id=${2:-4242}
    cat > "$work/pueue" <<SH
#!/bin/sh
case "\$*" in
  *"kill "*) exit 0 ;;
  *"remove "*) exit 0 ;;
  *"add "*) printf '%s\n' $add_id ;;
  *"status --json"*) printf '%s\n' '$tasks' ;;
  *"group --json"*) printf '%s\n' '{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}' ;;
  *) printf '%s 4.0.4\n' pueue ;;
esac
SH
    chmod 700 "$work/pueue"
}
empty_tasks='{"tasks":{},"groups":{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}}'
write_stub "$empty_tasks"
printf '#!/bin/sh\nprintf "%%s 4.0.4\\n" pueued\n' > "$work/pueued"
chmod 700 "$work/pueued"

failures=0
cases=0
reason_gaps=0

# `find -delete`, never a bare glob: zsh's nomatch aborts the command when the
# glob matches nothing, so cleanup silently does nothing and state leaks.
clear_runtime() {
    find "$work/data/agentq-requests" -maxdepth 1 -name '*.json' -delete
    find "$work/data/agentq-requests/.tombstones" -maxdepth 1 -name '*.json' -delete
    find "$work/data/agentq-cancellations" -maxdepth 1 -name '*.json' -delete
}

# A record whose payload matches what `submit --workdir /tmp --label smoke --
# true` computes: normalize_workdir resolves /tmp to the canonical path.
record() {
    printf '{"version":1,"request_id":"%s","payload":{"workdir":"%s","label":"smoke","argv":["true"]},"task_label":"agentq:%s","state":"%s","task_id":%s,"task_created_at":%s,"created_at":"2026-09-29T00:00:00Z"}\n' \
        "$1" "$work" "$1" "$2" "$3" "$4"
}
put_record() { record "$1" "$2" "$3" "$4" > "$work/data/agentq-requests/$1.json"; }
put_tombstone() {
    printf '{"version":1,"request_id":"%s","task_id":%s,"task_created_at":"2026-09-29T00:00:00Z","state":"removed","removed_at":"2026-09-29T01:00:00Z"}\n' \
        "$1" "$2" > "$work/data/agentq-requests/.tombstones/$1.json"
}
count_records() { find "$work/data/agentq-requests" -maxdepth 1 -name '*.json' | wc -l | tr -d ' '; }
count_tombstones() { find "$work/data/agentq-requests/.tombstones" -maxdepth 1 -name '*.json' | wc -l | tr -d ' '; }
count_markers() { find "$work/data/agentq-cancellations" -maxdepth 1 -name '*.json' | wc -l | tr -d ' '; }

run_case() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server" "$@" ) >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}

assert_rc() {
    local label=$1 expected=$2
    cases=$((cases + 1))
    local rc
    rc=$(cat "$work/$label.rc")
    if [ "$rc" != "$expected" ]; then
        printf 'write-paths %s: expected exit %s, got %s\n' "$label" "$expected" "$rc" >&2
        sed -n '1,3p' "$work/$label.err" >&2 || true
        failures=$((failures + 1))
    fi
}

# assert_json <label> [jq-args...] <expression>  -- the expression is the last arg,
# so callers may pass --arg/--argjson before it.
assert_json() {
    local label=$1
    shift
    cases=$((cases + 1))
    if ! jq -e "$@" < "$work/$label.out" >/dev/null 2>&1; then
        printf 'write-paths %s: stdout failed %s: %s\n' "$label" "$*" "$(cat "$work/$label.out")" >&2
        failures=$((failures + 1))
    fi
}

assert_err_has() {
    local label=$1 fragment=$2
    cases=$((cases + 1))
    if ! grep -qF -- "$fragment" "$work/$label.err"; then
        printf 'write-paths %s: stderr does not contain %s\n' "$label" "$fragment" >&2
        sed -n '1,3p' "$work/$label.err" >&2 || true
        failures=$((failures + 1))
    fi
}

# Every exit-2 path must carry the machine-readable reason line.
assert_reason() {
    local label=$1
    cases=$((cases + 1))
    if ! grep -qxF -- 'agentq-server: reason=protocol_error' "$work/$label.err"; then
        printf 'write-paths %s: stderr does not carry reason=protocol_error\n' "$label" >&2
        reason_gaps=$((reason_gaps + 1))
        failures=$((failures + 1))
    fi
}

assert_counts() {
    local label=$1 want_records=$2 want_tombstones=$3
    cases=$((cases + 1))
    local records tombstones
    records=$(count_records); tombstones=$(count_tombstones)
    if [ "$records" != "$want_records" ] || [ "$tombstones" != "$want_tombstones" ]; then
        printf 'write-paths %s: records=%s tombstones=%s, expected %s/%s\n' \
            "$label" "$records" "$tombstones" "$want_records" "$want_tombstones" >&2
        failures=$((failures + 1))
    fi
}

# ------------------------------------------------------------------ submit cases
submit_id=AQSUB-PROBE-0000001

# A stateful stub: `pueue add` "creates" the task, so `status --json` reports it
# only AFTER the add.  A stub that always reports the task makes submit take the
# recovery path (reused:true) instead of the add path, which is a different case.
# <tasks-fn> is a shell snippet the status branch runs, so callers can flip what
# is visible between cases.
write_stateful_stub() {
    local add_id=$1
    cat > "$work/pueue" <<SH
#!/bin/sh
case "\$*" in
  *"kill "*) exit 0 ;;
  *"remove "*) exit 0 ;;
  *"add "*) printf '%s\n' $add_id; : > "$work/.added" ;;
  *"status --json"*)
    if [ -e "$work/.added" ]; then
      printf '%s\n' '{"tasks":{"$add_id":{"id":$add_id,"created_at":"2026-09-29T00:00:00Z","command":"true","label":"agentq:$submit_id","status":{"Queued":{}},"group":"agentq"}},"groups":{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}}'
    else
      printf '%s\n' '{"tasks":{},"groups":{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}}'
    fi
    ;;
  *"group --json"*) printf '%s\n' '{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}' ;;
  *) printf '%s 4.0.4\n' pueue ;;
esac
SH
    chmod 700 "$work/pueue"
}

# S1. An existing record whose payload differs must refuse -- never silently
#     reuse the id for a different command.
clear_runtime
write_stub "$empty_tasks"
printf '{"version":1,"request_id":"%s","payload":{"workdir":"%s","label":"other","argv":["true"]},"task_label":"agentq:%s","state":"prepared","task_id":null,"task_created_at":null,"created_at":"2026-09-29T00:00:00Z"}\n' \
    "$submit_id" "$work" "$submit_id" > "$work/data/agentq-requests/$submit_id.json"
run_case s1 submit --workdir "$work" --label smoke --request-id "$submit_id" -- true
assert_rc s1 2
assert_err_has s1 'request id was already used with different submit arguments'
assert_reason s1

# S2. A leftover tombstone (record already archived): refuse as consumed.
clear_runtime
put_tombstone "$submit_id" 1001
run_case s2 submit --workdir "$work" --label smoke --request-id "$submit_id" -- true
assert_rc s2 2
assert_err_has s2 'request id was already consumed by a task that has been removed'
assert_reason s2

# S3. A record in `adding` whose payload matches: the task may or may not have
#     reached Pueue -> exit 4 (ambiguous), and the command must NOT be re-enqueued.
clear_runtime
write_stub "$empty_tasks"
put_record "$submit_id" adding null null
run_case s3 submit --workdir "$work" --label smoke --request-id "$submit_id" -- true
assert_rc s3 4
assert_json s3 '.state == "ambiguous"'
assert_err_has s3 'refusing to enqueue it again'

# S4. A fresh id with `pueue add` returning an id Pueue cannot then render:
#     exit 4, never a fabricated success.
clear_runtime
write_stub "$empty_tasks" 4242
run_case s4 submit --workdir "$work" --label smoke --request-id "$submit_id" -- true
assert_rc s4 4
assert_json s4 '.state == "ambiguous"'
clear_runtime

# S5. A fresh id, `pueue add` returns 4242, and the task becomes visible only
#     after the add: success, reused:false, record archived to accepted/4242.
clear_runtime
rm -f "$work/.added"
write_stateful_stub 4242
run_case s5 submit --workdir "$work" --label smoke --request-id "$submit_id" -- true
assert_rc s5 0
assert_json s5 '.task_id == 4242 and .reused == false'
assert_counts s5 1 0
cases=$((cases + 1))
if ! jq -e '.state == "accepted" and .task_id == 4242' "$work/data/agentq-requests/$submit_id.json" >/dev/null 2>&1; then
    printf 'write-paths s5: record not archived to accepted/4242: %s\n' \
        "$(cat "$work/data/agentq-requests/$submit_id.json" 2>/dev/null)" >&2
    failures=$((failures + 1))
fi

# ------------------------------------------------------------------ cancel cases
write_stub '{"tasks":{"1001":{"id":1001,"created_at":"2026-09-29T00:00:00Z","command":"sleep 60","label":"agentq:AQCAN-0000000000001","status":{"Running":{}},"group":"agentq"}},"groups":{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}}'

# C1. First cancel of a running task: kill, write a `requested` marker, exit 0.
clear_runtime
run_case c1 cancel 1001
assert_rc c1 0
assert_json c1 '.action == "cancel_requested" and (.reused == null)'
cases=$((cases + 1))
if [ "$(count_markers)" != 1 ]; then
    printf 'write-paths c1: expected 1 cancellation marker, got %s\n' "$(count_markers)" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if ! jq -e '.state == "requested" and .task_id == 1001' "$work/data/agentq-cancellations/1001.json" >/dev/null 2>&1; then
    printf 'write-paths c1: marker not written in requested state\n' >&2
    failures=$((failures + 1))
fi

# C2. Replaying the same cancel must return reused:true and mutate nothing.
c1_requested_at=$(jq -r '.cancellation_requested_at' "$work/c1.out")
run_case c2 cancel 1001
assert_rc c2 0
assert_json c2 --arg at "$c1_requested_at" '.reused == true and .cancellation_requested_at == $at'

# C3. An unknown task id is exit 2.
run_case c3 cancel 9999
assert_rc c3 2
assert_err_has c3 'unknown AgentQ task id: 9999'
assert_reason c3

clear_runtime

# ------------------------------------------------------------------ remove cases
# R1. A task whose matching accepted record exists: remove succeeds, the record
#     is archived into a tombstone.
clear_runtime
put_record AQCAN-0000000000001 accepted 1001 '"2026-09-29T00:00:00Z"'
run_case r1 remove 1001
assert_rc r1 0
assert_json r1 '.removed == true'
assert_counts r1 0 1
cases=$((cases + 1))
if ! jq -e '.task_id == 1001 and .state == "removed"' \
    "$work/data/agentq-requests/.tombstones/AQCAN-0000000000001.json" >/dev/null 2>&1; then
    printf 'write-paths r1: tombstone not written for the removed task\n' >&2
    failures=$((failures + 1))
fi

# R2. A visible task whose request record is MISSING must refuse (exit 2), not
#     silently drop the AgentQ metadata.
clear_runtime
run_case r2 remove 1001
assert_rc r2 2
assert_err_has r2 'missing AgentQ request record while removing task'
assert_reason r2

# R3. An unknown task id is exit 2.
run_case r3 remove 9999
assert_rc r3 2
assert_err_has r3 'unknown AgentQ task id: 9999'
assert_reason r3

clear_runtime

# --------------------------------------------------------------- summary
if [ "$failures" -ne 0 ]; then
    printf 'write-paths checks FAILED: cases=%s failures=%s\n' "$cases" "$failures" >&2
    exit 1
fi
printf 'write-paths checks passed: cases=%s reason-gaps=%s\n' "$cases" "$reason_gaps"
