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
    # TMPDIR pins mktemp in the SERVER to the tree's own temp dir: macOS's
    # per-user $TMPDIR otherwise leaves a dangling `$name.maintenance.lock`
    # symlink that the next mktemp reuses -- a harness artifact, not a case.
    ( cd "$work" && TMPDIR="$work" "$work/agentq-server" "$@" ) >"$work/$label.out" 2>"$work/$label.err" || rc=$?
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

# S6. An invalid --workdir must refuse BEFORE anything is written.  Measured
#     2026-10-06: normalize_workdir's `fail` ended only the command-substitution
#     subshell, and with_operation_lock calls the command in an `if` context, so
#     errexit was disabled for the whole body -- the rejection printed and the
#     submit continued, persisting workdir:"" and enqueueing with an empty
#     working directory.  The call site now checks the assignment explicitly.
clear_runtime
write_stub "$empty_tasks"
run_case s6 submit --workdir /nonexistent/agentq-smoke-workdir --label smoke --request-id "$submit_id" -- true
assert_rc s6 2
assert_err_has s6 'working directory does not exist'
assert_reason s6
cases=$((cases + 1))
if [ -e "$work/data/agentq-requests/$submit_id.json" ]; then
    printf 'write-paths s6: a rejected submit persisted a request record: %s\n' "$(cat "$work/data/agentq-requests/$submit_id.json")" >&2
    failures=$((failures + 1))
fi

# C4. The task is gone but the marker says the outcome was never confirmed:
#     that is the degraded contract (4/cancellation_pending), NOT "unknown
#     AgentQ task id" -- the id IS known (its record and marker are on disk);
#     what is unresolved is whether the cancel took effect.  Measured
#     2026-10-06: a pending marker left by the failed-kill/failed-remove paths
#     reached the unknown-id fail and the message misattributed it.
clear_runtime
write_stub "$empty_tasks"
printf '{"version":1,"task_id":1001,"created_at":"2026-09-29T00:00:00Z","requested_at":"2026-09-29T00:05:00Z","reason":"kill_unconfirmed","state":"pending"}\n' > "$work/data/agentq-cancellations/1001.json"
run_case c4 cancel 1001
assert_rc c4 4
assert_json c4 '.state == "cancellation_pending"'
assert_err_has c4 'the task is gone while the cancellation outcome remains unresolved'

clear_runtime

# ------------------------------------------------------------------- wait cases
# `wait` must answer from the FINAL, identity-checked task snapshot: pueue
# wait's exit code is dropped once the same instance is Done with a result.
wait_task_json() { # $1 status class
    printf '{"tasks":{"1001":{"id":1001,"created_at":"2026-09-29T00:00:00Z","command":"true","label":"agentq:AQCAN-0000000000001","status":%s,"group":"agentq"}},"groups":{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}}' "$1"
}
write_wait_stub() { # $1 tasks-json, $2 pueue-wait exit
    local tasks=$1 wait_exit=$2
    cat > "$work/pueue" <<SH
#!/bin/sh
case "\$*" in
  *"wait "*) exit $wait_exit ;;
  *"status --json"*) printf '%s\n' '$tasks' ;;
  *"group --json"*) printf '%s\n' '{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}' ;;
  *) printf '%s 4.0.4\n' pueue ;;
esac
SH
    chmod 700 "$work/pueue"
}
wait_done_success=$(wait_task_json '{"Done":{"result":"Success","start":"2026-09-29T00:00:00Z","end":"2026-09-29T00:00:01Z"}}')
wait_done_failed=$(wait_task_json '{"Done":{"result":"Failed","start":"2026-09-29T00:00:00Z","end":"2026-09-29T00:00:01Z"}}')
wait_running=$(wait_task_json '{"Running":{"start":"2026-09-29T00:00:00Z"}}')
clear_runtime
put_record AQCAN-0000000000001 accepted 1001 '"2026-09-29T00:00:00Z"'

# P1. Positive control: pueue wait 0 + Done Success -> 0 with the task body.
write_wait_stub "$wait_done_success" 0
run_case p1 wait 1001
assert_rc p1 0
assert_json p1 '.task.status.Done.result == "Success"'

# P2. pueue wait failed (e.g. 124) but the snapshot is Done Success -> still 0.
write_wait_stub "$wait_done_success" 124
run_case p2 wait 1001
assert_rc p2 0
assert_json p2 '.task.status.Done.result == "Success"'

# P3. pueue wait failed and the snapshot is Done Failed -> 1, task body kept.
write_wait_stub "$wait_done_failed" 124
run_case p3 wait 1001
assert_rc p3 1
assert_json p3 '.task.status.Done.result == "Failed"'

# P4. pueue wait failed and the snapshot is NOT done -> unavailable/6 JSON on
#     stdout (never a bare 1 with empty stdout).
write_wait_stub "$wait_running" 124
run_case p4 wait 1001
assert_rc p4 6
assert_json p4 '.state == "unavailable" and .task_id == 1001'

# P6. Negative control for P2/P3: a DIFFERENT task instance on the same id
#     (created_at moved) must never answer from the new instance's result.
write_stub '{"tasks":{"1001":{"id":1001,"created_at":"2026-10-01T00:00:00Z","command":"true","label":"agentq:AQCAN-0000000000001","status":{"Done":{"result":"Success","start":"2026-10-01T00:00:00Z","end":"2026-10-01T00:00:01Z"}},"group":"agentq"}},"groups":{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}}'
run_case p6 wait 1001
assert_rc p6 6
assert_json p6 '.state == "unavailable"'

# P7. A Done snapshot whose result is EMPTY is not an answer even if pueue wait
#     failed: unavailable/6.
write_wait_stub "$(wait_task_json '{"Done":{"result":"","start":"2026-09-29T00:00:00Z","end":"2026-09-29T00:00:01Z"}}')" 124
run_case p7 wait 1001
assert_rc p7 6
assert_json p7 '.state == "unavailable"'

clear_runtime
write_stub "$empty_tasks"

# ----------------------------------------------------------- group reason case
# G1. CONTROL: the normal stub answers the group -> status 0.
run_case g1 status --summary
assert_rc g1 0
# G2. A group that is missing / has parallel_tasks != 1 is a deployment state:
#     exit 2 with reason=deployment_state (never protocol_error, never pass).
cat > "$work/pueue" <<'SH'
#!/bin/sh
case "$*" in
  *"status --json"*) printf '%s\n' '{"tasks":{},"groups":{"agentq":{"status":"Running","parallel_tasks":2},"default":{"status":"Running","parallel_tasks":1}}}' ;;
  *"group --json"*) printf '%s\n' '{"agentq":{"status":"Running","parallel_tasks":2},"default":{"status":"Running","parallel_tasks":1}}' ;;
  *) printf '%s 4.0.4\n' pueue ;;
esac
SH
chmod 700 "$work/pueue"
run_case g2 status --summary
assert_rc g2 2
assert_err_has g2 'AgentQ group is missing or has unexpected parallelism: agentq'
cases=$((cases + 1))
if ! grep -qxF -- 'agentq-server: reason=deployment_state' "$work/g2.err"; then
    printf 'write-paths g2: the group failure must carry reason=deployment_state\n' >&2
    sed -n '1,3p' "$work/g2.err" >&2 || true
    failures=$((failures + 1))
fi
cat > "$work/pueue" <<'SH'
#!/bin/sh
case "$*" in
  *"status --json"*) printf '%s\n' '{"tasks":{},"groups":{"default":{"status":"Running","parallel_tasks":1}}}' ;;
  *"group --json"*) printf '%s\n' '{"default":{"status":"Running","parallel_tasks":1}}' ;;
  *) printf '%s 4.0.4\n' pueue ;;
esac
SH
chmod 700 "$work/pueue"
run_case g3 status --summary
assert_rc g3 2
assert_err_has g3 'reason=deployment_state'
write_stub "$empty_tasks"

# ------------------------------------------------- maintenance lock (POSIX dir)
# The server derives its root from dirname($0), so the lock it looks at is the
# SIBLING of the tree, `$work.maintenance.lock`.  A POSIX installer mkdirs the
# lock BEFORE writing `pid`; `ensure_not_in_maintenance` runs before any lock is
# acquired, so a maintenance lock refused here is left exactly as-is.
maintenance_lock="$work.maintenance.lock"
lock_pid_file="$maintenance_lock/pid"
reset_maintenance_lock() { rm -rf -- "${maintenance_lock:?}"; }
assert_lock_state() { # $1 label, $2 want (present|absent)
    cases=$((cases + 1))
    if [ "$2" = present ] && { [ ! -e "$maintenance_lock" ] || [ -L "$maintenance_lock" ]; }; then
        printf 'write-paths %s: the maintenance lock was removed but must be kept\n' "$1" >&2
        failures=$((failures + 1))
    elif [ "$2" = absent ] && { [ -e "$maintenance_lock" ] || [ -L "$maintenance_lock" ]; }; then
        printf 'write-paths %s: the maintenance lock was not recovered\n' "$1" >&2
        failures=$((failures + 1))
    fi
}
assert_reason_is() { # $1 label, $2 reason
    cases=$((cases + 1))
    if ! grep -qxF -- "agentq-server: reason=$2" "$work/$1.err"; then
        printf 'write-paths %s: stderr does not carry reason=%s\n' "$1" "$2" >&2
        sed -n '1,3p' "$work/$1.err" >&2 || true
        failures=$((failures + 1))
    fi
}
backdate() { # $1 path, $2 seconds ago
    local when
    when=$(( $(date +%s) - $2 ))
    touch -t "$(date -r "$when" +%Y%m%d%H%M.%S)" "$1"
}
# M0. Positive control: no lock -> the command reaches its own logic (the
#     unknown id is answered, not a maintenance diagnostic).
reset_maintenance_lock
run_case m0 status --task 9999
assert_rc m0 2
assert_err_has m0 'unknown AgentQ task id: 9999'
assert_reason_is m0 protocol_error
# M1. A NEW empty lock (inside the 30 s grace) is a live installer between mkdir
#     and writing the pid file: keep it, lock_contention.  The age is pinned
#     with `touch` so a whole-second clock cannot put the lock right on the
#     grace boundary.
reset_maintenance_lock
mkdir -- "$maintenance_lock"
backdate "$maintenance_lock" 1
run_case m1 status --task 9999
# `status --task` runs the maintenance check first, so even an unknown task id
# answers from the lock.  M0 is the control that the same argv WITHOUT a lock
# never reports the lock.
assert_rc m1 2
assert_reason_is m1 lock_contention
assert_lock_state m1 present
# M2. An OLD empty lock (>30 s) is a crash residue: recover it, status 0.
backdate "$maintenance_lock" 90
run_case m2 status --task 9999
assert_rc m2 2
assert_err_has m2 'unknown AgentQ task id: 9999'
assert_lock_state m2 absent
# M3. A corrupt pid file NEVER authorises an age-based removal, however old.
reset_maintenance_lock
mkdir -- "$maintenance_lock"
printf 'garbage\n' > "$lock_pid_file"
backdate "$lock_pid_file" 9000
backdate "$maintenance_lock" 9000
run_case m3 lookup AQCAN-0000000000001
assert_rc m3 2
assert_err_has m3 'cannot determine maintenance lock owner; inspect lock manually'
assert_reason_is m3 deployment_state
assert_lock_state m3 present
# M4. A LIVE holder is contention, and its lock is kept.
live_pid=$$
process_identity=$(LC_ALL=C ps -o lstart= -p "$live_pid" 2>/dev/null | awk '{$1 = $1; print}') || process_identity=''
if [ -n "$process_identity" ]; then
    reset_maintenance_lock
    mkdir -- "$maintenance_lock"
    printf '%s\t%s\n' "$live_pid" "$process_identity" > "$lock_pid_file"
    run_case m4 lookup AQCAN-0000000000001
    assert_rc m4 2
    assert_reason_is m4 lock_contention
    assert_lock_state m4 present
else
    printf 'write-paths m4: could not read a live process identity; the live-holder case did not run\n' >&2
    failures=$((failures + 1))
fi
# M5. A DEAD holder (identity is a 1 that no live process carries) is recovered.
reset_maintenance_lock
mkdir -- "$maintenance_lock"
printf '%s\t%s\n' "$live_pid" 'Thu Jan  1 00:00:00 1970' > "$lock_pid_file"
run_case m5 status --task 9999
assert_rc m5 2
assert_err_has m5 'unknown AgentQ task id: 9999'
assert_lock_state m5 absent
# M6. A dead holder whose lock disappears between the decision and the removal
#     (another reader cleaned it) is SUCCESS: no ENOENT text, no reason line.
reset_maintenance_lock
mkdir -- "$maintenance_lock"
printf '%s\t%s\n' "$live_pid" 'Thu Jan  1 00:00:00 1970' > "$lock_pid_file"
( sleep 2; rm -rf -- "$maintenance_lock" ) & cleaner=$!
run_case m6 status --task 9999
wait "$cleaner"
assert_rc m6 2
assert_err_has m6 'unknown AgentQ task id: 9999'
assert_lock_state m6 absent
# The concurrently cleaned lock must not produce an ENOENT.  The server's
# normal "unknown AgentQ task id" response has its own reason= line, so we do
# NOT forbid `reason=` here.
cases=$((cases + 1))
if grep -qF 'No such file' "$work/m6.err"; then
    printf 'write-paths m6: a concurrently cleaned lock leaked an error\n' >&2
    sed -n '1,3p' "$work/m6.err" >&2
    failures=$((failures + 1))
fi
# M7. A metadata-carrying lock whose DIRECTORY is ancient is NOT aged out
#     (only truly empty directories are ageable).
reset_maintenance_lock
mkdir -- "$maintenance_lock"
printf 'garbage\n' > "$lock_pid_file"
backdate "$maintenance_lock" 9000
run_case m7 lookup AQCAN-0000000000001
assert_rc m7 2
assert_reason_is m7 deployment_state
assert_lock_state m7 present
reset_maintenance_lock

# ------------------------------------------------------ tombstone retention
# Quarantined tombstones (and everything else under .legacy-orphans/) are the
# operator's data: the production prune must never reach them, however old.
# The prune only runs in `ensure_request_record_layout` (write operations), so
# these cases use `submit` in a writeable context.
# clear_runtime() deletes every tombstone in the data directory, so it must run
# BEFORE the fixtures below are planted -- after them it deleted exactly what
# this case seeds and the prune assertion then read "0 tombstones" (measured
# 2026-11-10).  Nothing between here and the submit below writes a tombstone,
# so moving it up changes nothing else.
clear_runtime
put_tombstone AQCAN-0000000000001 1001
mkdir -p "$work/data/agentq-requests/.tombstones/.legacy-orphans"
printf '%s\n' '{"old":true}' > "$work/data/agentq-requests/.tombstones/.legacy-orphans/_oldrecord.json"
backdate "$work/data/agentq-requests/.tombstones/.legacy-orphans/_oldrecord.json" $((45 * 86400))
put_tombstone AQCAN-0000000000002 1002
backdate "$work/data/agentq-requests/.tombstones/AQCAN-0000000000002.json" $((45 * 86400))
# All these files are at least 45 days old.  The prune marker says "prune now".
printf '%s\n' '2026-09-01' > "$work/runtime/agentq-request-tombstones-pruned-at"
# Submit a new request to trigger the full ensure_request_record_layout path.
write_stateful_stub 9999
rm -f "$work/.added"
run_case t1 submit --workdir "$work" --label smoke --request-id "$submit_id" -- true
assert_rc t1 0
cases=$((cases + 1))
if [ "$(count_records)" != 1 ]; then
    printf 'write-paths t1: expected 1 record after submit\n' >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
tombstone_count=$(find "$work/data/agentq-requests/.tombstones" -maxdepth 1 -name '*.json' ! -path '*/.legacy-orphans/*' -not -path '*/.legacy-orphans' | wc -l | tr -d ' ')
if [ "$tombstone_count" -ne 1 ]; then
    printf 'write-paths t1: expected 1 tombstone (AQCAN-0000000000002 pruned), got %s\n' "$tombstone_count" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if [ ! -e "$work/data/agentq-requests/.tombstones/.legacy-orphans/_oldrecord.json" ]; then
    printf 'write-paths t1: the tombstone prune deleted a quarantined legacy file\n' >&2
    failures=$((failures + 1))
fi
find "$work/data/agentq-requests/.tombstones/.legacy-orphans" -mindepth 1 -delete
clear_runtime

# --------------------------------------------------------------- summary
if [ "$failures" -ne 0 ]; then
    printf 'write-paths checks FAILED: cases=%s failures=%s\n' "$cases" "$failures" >&2
    exit 1
fi
printf 'write-paths checks passed: cases=%s reason-gaps=%s\n' "$cases" "$reason_gaps"
