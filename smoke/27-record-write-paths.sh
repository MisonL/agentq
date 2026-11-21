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

# S7. Request ids are case-SENSITIVE.  On a filesystem that is not (APFS
#     default, NTFS) the two spellings would alias ONE record file: a submit
#     under the other spelling would read the existing record as if it were its
#     own and could overwrite it.  Measured 2026-11-10 (independent review):
#     nothing refused that write, and it was reachable through any ordinary
#     submit.
#
#     The guard is only REACHABLE where the filesystem aliases the two names,
#     so the host is probed rather than assumed (CI's ext4 is case-sensitive).
#     On a case-sensitive host the same row becomes the POSITIVE CONTROL: a
#     spelling that differs only in case is a DIFFERENT id there, and refusing
#     it would be over-refusal -- so that arm asserts the submit succeeds.
clear_runtime
case_probe=$(mktemp -d "$work/case-probe.XXXXXX")
touch "$case_probe/Upper.json"
if [ -e "$case_probe/upper.json" ]; then case_aliasing=yes; else case_aliasing=no; fi
rm -rf "$case_probe"
rm -f "$work/.added"
write_stateful_stub 4242
put_record AQCASE-ALIAS-00001 prepared null null
if [ "$case_aliasing" = yes ]; then
    run_case s7 submit --workdir "$work" --label smoke --request-id aqcase-alias-00001 -- true
    assert_rc s7 2
    assert_err_has s7 'differs only in case'
    assert_reason s7
    assert_counts s7 1 0
else
    printf '%s\n' 'write-paths s7: case-sensitive filesystem -- asserting the over-refusal control instead'
    run_case s7 submit --workdir "$work" --label smoke --request-id aqcase-alias-00001 -- true
    assert_rc s7 0
    assert_json s7 '.task_id == 4242'
    assert_counts s7 2 0
fi
clear_runtime

# S9. A reader failure is NOT an absent record.  Inject one jq failure in the
#     per-id reader only (layout validation uses the batch filter, so it cannot
#     consume the injection before submit reaches its own read).  The existing
#     record must survive byte-for-byte and nothing may be enqueued: without
#     this arm a transient read failure fell through to the "no record yet"
#     branch, which WRITES -- overwriting an accepted record (losing its
#     task_id) and enqueuing a second task under the same request id.  Measured
#     2026-11-10 (independent review) with exactly this injection: submit exited
#     0, the record was replaced and `pueue add` ran.
real_jq=$(command -v jq)
mkdir -p "$work/reader-bin"
cat > "$work/reader-bin/jq" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == -ce && ${2:-} == --arg && ${3:-} == request_id &&
      ${4:-} == "$AGENTQ_READER_ID" &&
      ${5:-} == *"error(\"invalid AgentQ request $AGENTQ_READER_KIND\")"* &&
      ! -e "$AGENTQ_READER_HIT" ]]; then
    printf '%s\n' "$AGENTQ_READER_KIND" > "$AGENTQ_READER_HIT"
    exit 5
fi
exec "$AGENTQ_REAL_JQ" "$@"
SH
chmod 700 "$work/reader-bin/jq"
for reader_kind in record tombstone; do
    clear_runtime
    rm -f "$work/.added" "$work/reader-hit"
    write_stateful_stub 4242
    if [ "$reader_kind" = record ]; then
        put_record "$submit_id" accepted 1001 '"2026-09-29T00:00:00Z"'
        reader_path="$work/data/agentq-requests/$submit_id.json"
        want_records=1
        want_tombstones=0
    else
        put_tombstone "$submit_id" 1001
        reader_path="$work/data/agentq-requests/.tombstones/$submit_id.json"
        want_records=0
        want_tombstones=1
    fi
    cp "$reader_path" "$work/reader-before.json"
    reader_case="s9-$reader_kind"
    PATH="$work/reader-bin:$PATH" AGENTQ_REAL_JQ="$real_jq" \
        AGENTQ_READER_ID="$submit_id" AGENTQ_READER_KIND="$reader_kind" \
        AGENTQ_READER_HIT="$work/reader-hit" \
        run_case "$reader_case" submit --workdir "$work" --label smoke --request-id "$submit_id" -- true
    assert_rc "$reader_case" 2
    assert_err_has "$reader_case" "invalid AgentQ request $reader_kind:"
    assert_reason "$reader_case"
    assert_counts "$reader_case" "$want_records" "$want_tombstones"
    cases=$((cases + 1))
    if [ "$(cat "$work/reader-hit" 2>/dev/null)" != "$reader_kind" ]; then
        printf 'write-paths %s: the reader failure injection was not reached\n' "$reader_case" >&2
        failures=$((failures + 1))
    fi
    cases=$((cases + 1))
    if ! cmp -s "$work/reader-before.json" "$reader_path"; then
        printf 'write-paths %s: the rejected submit changed existing metadata\n' "$reader_case" >&2
        failures=$((failures + 1))
    fi
    cases=$((cases + 1))
    if [ -e "$work/.added" ]; then
        printf 'write-paths %s: a reader failure still reached pueue add\n' "$reader_case" >&2
        failures=$((failures + 1))
    fi
    cases=$((cases + 1))
    if [ "$(grep -c '^agentq-server: reason=' "$work/$reader_case.err")" != 1 ]; then
        printf 'write-paths %s: expected exactly one reason line\n' "$reader_case" >&2
        failures=$((failures + 1))
    fi
done

# S8. Numeric ids are reused, so a marker left by an OLDER instance must be
#     discarded by the next submit -- and a marker belonging to the instance
#     being recovered must be PRESERVED (the opposite direction: a cleanup that
#     does not bind to the instance would delete a live cancellation's only
#     record).  A stale requested marker plus a tombstone must also not answer
#     for a new live instance while status cannot be read.
clear_runtime
rm -f "$work/.added" "$work/.killed" "$work/.gone" "$work/fail-status" "$work/status-count"
old_request_id=AQOLD-CANCEL-00001
new_created_at=2026-09-30T00:00:00Z
put_tombstone "$old_request_id" 1001
put_marker() {
    printf '{"version":1,"task_id":1001,"created_at":"%s","requested_at":"2026-09-29T00:05:00Z","reason":"kill_confirmed","state":"requested"}\n' \
        "$1" > "$work/data/agentq-cancellations/1001.json"
}
put_marker 2026-09-29T00:00:00Z
cat > "$work/pueue" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$work/reuse.calls"
case "\$*" in
  *"kill "*) : > "$work/.killed" ;;
  *"remove "*) : > "$work/.gone" ;;
  *"add "*) printf '%s\n' 1001; : > "$work/.added" ;;
  *"status --json"*)
    count=0
    [ ! -e "$work/status-count" ] || count=\$(cat "$work/status-count")
    count=\$((count + 1))
    printf '%s\n' "\$count" > "$work/status-count"
    if [ -e "$work/fail-status" ] && [ "\$count" -eq 2 ]; then exit 1; fi
    if [ -e "$work/.added" ] && [ ! -e "$work/.gone" ]; then
      printf '%s\n' '{"tasks":{"1001":{"id":1001,"created_at":"$new_created_at","command":"true","label":"agentq:$submit_id","status":{"Running":{}},"group":"agentq"}},"groups":{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}}'
    else
      printf '%s\n' '{"tasks":{},"groups":{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}}'
    fi
    ;;
  *"group --json"*) printf '%s\n' '{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}' ;;
  *) printf '%s 4.0.4\n' pueue ;;
esac
SH
chmod 700 "$work/pueue"
run_case s8-stale submit --workdir "$work" --label smoke --request-id "$submit_id" -- true
assert_rc s8-stale 0
assert_json s8-stale '.task_id == 1001 and .reused == false'
cases=$((cases + 1))
if [ -e "$work/data/agentq-cancellations/1001.json" ]; then
    printf 'write-paths s8-stale: submit kept the old task instance marker\n' >&2
    failures=$((failures + 1))
fi

# Recovery from prepared with an already-visible task reaches submit's final
# marker cleanup; accepted-record replay returns earlier and cannot test it.
put_record "$submit_id" prepared null null
put_marker "$new_created_at"
cp "$work/data/agentq-cancellations/1001.json" "$work/current-marker.json"
run_case s8-current submit --workdir "$work" --label smoke --request-id "$submit_id" -- true
assert_rc s8-current 0
assert_json s8-current '.task_id == 1001 and .reused == true'
cases=$((cases + 1))
if ! cmp -s "$work/current-marker.json" "$work/data/agentq-cancellations/1001.json"; then
    printf 'write-paths s8-current: recovered submit deleted its own cancellation marker\n' >&2
    failures=$((failures + 1))
fi

# Archiving an OLD removed record must not delete a NEW instance's marker.
put_marker "$new_created_at"
put_record "$old_request_id" removed 1001 '"2026-09-29T00:00:00Z"'
run_case c5-fence status --task 1001
assert_rc c5-fence 0
cases=$((cases + 1))
if ! cmp -s "$work/current-marker.json" "$work/data/agentq-cancellations/1001.json"; then
    printf 'write-paths c5-fence: archiving an old record deleted the current marker\n' >&2
    failures=$((failures + 1))
fi

# Restore a crash residue independently of submit's cleanup so this assertion
# detects the replay defect even if the cleanup fix is retained in a mutant.
put_marker 2026-09-29T00:00:00Z
cp "$work/data/agentq-cancellations/1001.json" "$work/old-marker.json"
: > "$work/reuse.calls"
rm -f "$work/status-count"
: > "$work/fail-status"
run_case c6-unreadable cancel 1001
assert_rc c6-unreadable 2
assert_reason c6-unreadable
cases=$((cases + 1))
if [ -s "$work/c6-unreadable.out" ] || [ -e "$work/.killed" ] || [ -e "$work/.gone" ] ||
   ! cmp -s "$work/old-marker.json" "$work/data/agentq-cancellations/1001.json"; then
    printf 'write-paths c6-unreadable: unreadable status produced a success or mutation\n' >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if [ "$(cat "$work/status-count")" != 2 ]; then
    printf 'write-paths c6-unreadable: did not reach the injected task-read failure\n' >&2
    failures=$((failures + 1))
fi

# Readable live instance: actually kill it and bind the new marker.
rm -f "$work/fail-status" "$work/status-count"
run_case c7-live cancel 1001
assert_rc c7-live 0
assert_json c7-live '.action == "cancel_requested" and (.reused == null)'
cases=$((cases + 1))
if [ ! -e "$work/.killed" ] ||
   ! jq -e --arg created "$new_created_at" '.created_at == $created and .state == "requested"' \
       "$work/data/agentq-cancellations/1001.json" >/dev/null; then
    printf 'write-paths c7-live: live cancellation did not kill and record the new instance\n' >&2
    failures=$((failures + 1))
fi

# Explicit absence still permits a confirmed replay, from a record OR tombstone.
: > "$work/.gone"
run_case c8-record cancel 1001
assert_rc c8-record 0
assert_json c8-record '.action == "cancel_requested" and .reused == true'
clear_runtime
put_tombstone "$old_request_id" 1001
put_marker 2026-09-29T00:00:00Z
run_case c8-tombstone cancel 1001
assert_rc c8-tombstone 0
assert_json c8-tombstone '.action == "cancel_requested" and .reused == true'
clear_runtime

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

# S6b. A --workdir whose RESOLVED path ends in a newline must refuse too.  The
#      `$( )` in normalize_workdir strips trailing newlines, so without the
#      sentinel the normalized path silently loses the last component: the
#      server enqueued in a DIFFERENT directory than the caller named -- and
#      when the stripped component was the final newline-only one, it persisted
#      workdir:"" and left a record stuck in `adding` that lookup answers 4 for
#      forever (measured 2026-11-20).  The path must exist and be a directory
#      with a trailing newline in its NAME; refusing it is the fail-closed
#      answer, because no shell can carry that value through `$( )`.
clear_runtime
write_stub "$empty_tasks"
# Built with a sentinel, not `$(printf '...\n')`: command substitution strips
# trailing newlines, so the obvious spelling creates the TWIN directory and the
# case silently tests nothing (measured here while writing it -- the first
# version's `newline` had no newline in its name and the submit legitimately
# progressed to `adding`).
nl_work=$(printf '%s/newline\nZ' "$work")
nl_work=${nl_work%Z}
mkdir -p "$nl_work"
cases=$((cases + 1))
if [ "$(printf '%s' "$nl_work" | od -An -c | tr -d ' ')" = "$(printf '%s' "${nl_work%?}" | od -An -c | tr -d ' ')" ]; then
    printf 'write-paths s6b: the fixture path does not actually end in a newline; the case would prove nothing\n' >&2
    failures=$((failures + 1))
fi
run_case s6b submit --workdir "$nl_work" --label smoke --request-id "$submit_id" -- true
assert_rc s6b 2
assert_err_has s6b 'working directory cannot end with a newline'
assert_reason s6b
cases=$((cases + 1))
if [ -e "$work/data/agentq-requests/$submit_id.json" ]; then
    printf 'write-paths s6b: a rejected submit persisted a request record: %s\n' "$(cat "$work/data/agentq-requests/$submit_id.json")" >&2
    failures=$((failures + 1))
fi
rmdir "$nl_work" 2>/dev/null || true

# S6c. A non-UTF-8 --label must refuse BEFORE any record exists.  jq's `--arg`
#      re-encodes its input and rewrites an invalid byte as U+FFFD without a
#      word, so a persisted label no longer identifies the caller's argument:
#      measured 2026-11-20, a second submit under the SAME request id with the
#      DIFFERENT label `q` + U+FFFD answered `reused:true` -- two arguments read
#      as one.  smoke/02 pins the message; this pins the NO-RECORD half, which is
#      what makes the request id reusable.
clear_runtime
write_stub "$empty_tasks"
cases=$((cases + 1))
nonutf8_label=$(printf 'q\377')
nonutf8_rc=0
( cd "$work" && TMPDIR="$work" "$work/agentq-server" submit --workdir "$work" \
    --label "$nonutf8_label" --request-id "$submit_id" -- true ) \
    >"$work/s6c.out" 2>"$work/s6c.err" || nonutf8_rc=$?
if [ "$nonutf8_rc" -ne 2 ] || ! grep -qF -- '--label must be valid UTF-8' "$work/s6c.err"; then
    printf 'write-paths s6c: a non-UTF-8 label was not refused with 2: rc=%s %s\n' \
        "$nonutf8_rc" "$(head -2 "$work/s6c.err" | tr '\n' '|')" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if [ -e "$work/data/agentq-requests/$submit_id.json" ]; then
    printf 'write-paths s6c: a non-UTF-8 label persisted a request record: %s\n' \
        "$(jq -c '.payload.label' "$work/data/agentq-requests/$submit_id.json" 2>/dev/null)" >&2
    failures=$((failures + 1))
fi
clear_runtime

# S6d. Unrecognized dotted names in the record directories are NOT AgentQ
#      records.  A stray `.notes.json` (an editor swap file, a user's own
#      scratch file) used to make the pruner `fail` with `invalid AgentQ
#      request record path`, so ONE such file turned every locked operation
#      into exit 2 -- submit could not run until it was deleted.  Measured
#      2026-11-20 (review round seven): `.notes.json` in
#      agentq-requests/ made a plain submit answer 2.  Unknown `.*.json` names
#      are skipped now; this case must show the submit SUCCEEDS with the files
#      still present (they are removed afterwards so the count assertions and
#      other cases are unaffected).
clear_runtime
rm -f "$work/.added"
write_stateful_stub 4243
printf '{"note":"editor swap"}\n' > "$work/data/agentq-requests/.notes.json"
printf 'not json at all\n' > "$work/data/agentq-requests/.stray.json"
cases=$((cases + 1))
if [ ! -f "$work/data/agentq-requests/.notes.json" ]; then
    printf '%s\n' 'write-paths s6d: the fixture files were not written; the case would prove nothing' >&2
    failures=$((failures + 1))
fi
run_case s6d submit --workdir "$work" --label smoke --request-id "$submit_id" -- true
assert_rc s6d 0
assert_json s6d '.task_id == 4243 and .reused == false'
rm -f -- "$work/data/agentq-requests/.notes.json" "$work/data/agentq-requests/.stray.json"
clear_runtime

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
    local when stamp
    when=$(( $(date +%s) - $2 ))
    # `date -r` takes an epoch on BSD/macOS and a REFERENCE FILE on GNU, where
    # the epoch form is `date -d @<epoch>`.  The macOS spelling was the only
    # one here, so the m0-m8 cases -- the ones that actually call this helper --
    # failed on ubuntu:24.04 with "date: 1794304890: No such file or directory"
    # followed by `touch: invalid date format` (measured 2026-11-10, linux CI).
    # Both branches are spelled out, and an empty stamp is refused here rather
    # than handed to touch.
    stamp=$(date -r "$when" +%Y%m%d%H%M.%S 2>/dev/null ||
        date -d "@$when" +%Y%m%d%H%M.%S 2>/dev/null) || stamp=''
    if [ -z "$stamp" ]; then
        printf 'write-paths: cannot compute a backdated timestamp on this host (neither BSD nor GNU date accepted the epoch)\n' >&2
        return 1
    fi
    touch -t "$stamp" -- "$1"
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

# ------------------------------------------------ repair guard-file leak
# `repair_removed_request_records`' fallback loop is the only place the server
# captures another reader's stderr into a file, and the reader reports through
# `fail` -- `exit 2`, which skips the function's own trailing `rm -f`.  The
# name therefore lives in a GLOBAL that cleanup() and fail() both clear.
# Measured 2026-11-20: one 0600 `agentq-repair-guard.*` empty file leaked into
# TMPDIR per failed command, unbounded.
#
# The trigger needs BOTH arms: a REMOVED record whose tombstone conflicts with
# it (so archive_removed_request's `fail` fires from inside the loop) and a
# record that cannot be read (so the batch fast path falls back to the loop).
# The removed record's id must sort BEFORE the broken one -- with the opposite
# order the `fail` fires first and the leak never happens (measured while
# writing this case: the first version was green for the wrong reason).
clear_runtime
repair_tmp="$work/repair-tmp"
mkdir -p "$repair_tmp"
repair_removed_id=AQSUB-REPAIRAA-00001
repair_broken_id=AQSUB-REPAIRZZ-00001
put_record "$repair_removed_id" removed 1001 '"2026-09-29T00:00:00Z"'
put_tombstone "$repair_removed_id" 2002
put_record "$repair_broken_id" accepted 1002 '"2026-09-29T00:00:00Z"'
chmod 000 "$work/data/agentq-requests/$repair_broken_id.json"
cases=$((cases + 1))
repair_status=0
( cd "$work" && TMPDIR="$repair_tmp" "$work/agentq-server" status --summary ) \
    >"$work/repair.out" 2>"$work/repair.err" || repair_status=$?
chmod 600 "$work/data/agentq-requests/$repair_broken_id.json"
repair_leftovers=$(find "$repair_tmp" -name 'agentq-repair-guard.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$repair_leftovers" -ne 0 ]; then
    printf 'write-paths repair: %s agentq-repair-guard temp file(s) left behind after a failed repair\n' \
        "$repair_leftovers" >&2
    failures=$((failures + 1))
fi
# The guard's own message must still reach stderr -- in a run where the guard
# is the FIRST thing the fallback loop hits.  This is the fix's delicate part:
# the reader reports through `fail`, which now clears the (global) guard file,
# and that runs inside the read's own `$( )`; the fix blanks the name THERE so
# the parent can still read it.  Getting that wrong loses the diagnostic while
# the leak test above stays green (measured 2026-11-20 on the first attempt).
cases=$((cases + 1))
clear_runtime
put_record "$repair_broken_id" accepted 1002 '"2026-09-29T00:00:00Z"'
chmod 000 "$work/data/agentq-requests/$repair_broken_id.json"
( cd "$work" && TMPDIR="$repair_tmp" "$work/agentq-server" status --summary ) \
    >"$work/repair-message.out" 2>"$work/repair-message.err" || repair_status=$?
chmod 600 "$work/data/agentq-requests/$repair_broken_id.json"
if ! grep -qF 'invalid AgentQ request record' "$work/repair-message.err"; then
    printf 'write-paths repair: the malformed record guard message did not reach stderr (exit %s): %s\n' \
        "$repair_status" "$(head -3 "$work/repair-message.err" | tr '\n' '|')" >&2
    failures=$((failures + 1))
fi
rm -rf -- "$repair_tmp"
clear_runtime

# -------------------------------------------- native-Windows jq (CRLF) cases
# A text-mode jq (the native Windows build; see smoke/26's W7) makes the server
# install its jq line-ending shim, which appends a newline to ANY non-empty jq
# output so multi-line `while read` consumers keep their last line.  The UTF-8
# validators compare BYTES, so that newline made every non-empty argument look
# invalid: measured 2026-11-21 (red proof below) -- with the shim installed,
# `submit` answered exit 2 `--label must be valid UTF-8` for any label and
# `remove --label` the same, i.e. the two write paths were dead on a native
# Windows jq.  Both validators must read jq's RAW bytes (`command jq`).
windows_jq_directory="$work/bin-windows-jq"
mkdir -p "$windows_jq_directory"
real_jq=$(command -v jq)
[ -n "$real_jq" ] || { printf '%s\n' 'write-paths: jq is required for the CRLF case' >&2; exit 1; }
cat > "$windows_jq_directory/jq" <<SH
#!/bin/sh
# Text-mode jq: omits the final line's CR, which is the shape that reaches the
# server through \$( ) (smoke/26's W7 records the measurement).
output_file=\$(mktemp)
"$real_jq" "\$@" > "\$output_file"
status=\$?
sed '\$!s/\$/\r/' "\$output_file"
rm -f "\$output_file"
exit "\$status"
SH
chmod 700 "$windows_jq_directory/jq"

run_case_with_windows_jq() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && TMPDIR="$work" PATH="$windows_jq_directory:$PATH" "$work/agentq-server" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}

# S10. A submit on a text-mode jq must succeed exactly like the baseline; the
#      UTF-8 validators must judge the ARGUMENT, not the shim's convenience
#      newline.
clear_runtime
rm -f "$work/.added"
write_stateful_stub 4242
run_case_with_windows_jq s10 submit --workdir "$work" --label smoke --request-id "$submit_id" -- true
assert_rc s10 0
assert_json s10 '.task_id == 4242 and .reused == false'

# S11. `remove --label` goes through the same byte comparison for its label;
#      it must remove the batch the S10 submit created.
run_case_with_windows_jq s11 remove --label smoke --confirm
assert_rc s11 0
assert_json s11 'type == "array" and length == 1 and .[0].removed == true and .[0].task_id == 4242'
clear_runtime
rm -f "$work/.added"

# ---------------------------------------- fail-open and convergence cases (r8)
# S12. `pwd -P` failing must reject the workdir.  The unix branch's command
#      group used to be `{ pwd -P; printf 'Z'; }`, whose status is printf's 0,
#      so a failing pwd produced an EMPTY resolved workdir: the empty string
#      round-trips the UTF-8 check and would reach `pueue add`.  The fixture
#      exports a bash function named `pwd` (BASH_FUNC environment import) that
#      fails ONLY in the sentinel directory -- the server itself resolves its
#      own root with `pwd -P` at startup, so a blanket failure would not start.
clear_runtime
mkdir -p "$work/wd-fail"
write_stub "$empty_tasks"
s12_sentinel=$(printf '%s' "$work/wd-fail" | sed 's/[\\"`$]/\\&/g')
s12_status=0
( cd "$work" && TMPDIR="$work" env "BASH_FUNC_pwd%%=() { if [ \"\$PWD\" = \"$s12_sentinel\" ]; then return 1; fi; builtin pwd -P; }" \
    "$work/agentq-server" submit --workdir "$work/wd-fail" --label smoke \
        --request-id "$submit_id" -- true ) >"$work/s12.out" 2>"$work/s12.err" || s12_status=$?
printf '%s' "$s12_status" > "$work/s12.rc"
assert_rc s12 2
assert_err_has s12 'cannot resolve the working directory'
assert_reason s12
clear_runtime

# S13. A lock-free reader wins the race between `pueue remove` and the writer's
#      archive: it converges the `removing` record to removed.  The remove must
#      report that outcome (removed + recovered) instead of failing with
#      "missing AgentQ request record".  The stub simulates the reader by
#      deleting the record and writing a matching tombstone inside `pueue
#      remove` -- exactly what recover_removing_requests leaves behind.
write_removal_race_stub() {
    local add_id=$1
    cat > "$work/pueue" <<SH
#!/bin/sh
case "\$*" in
  *"remove "*)
    rm -f -- "$work/data/agentq-requests/$submit_id.json"
    printf '{"version":1,"request_id":"%s","task_id":%s,"task_created_at":"2026-09-29T00:00:00Z","state":"removed","removed_at":"2026-09-29T00:00:00Z"}\n' \
        "$submit_id" "$add_id" > "$work/data/agentq-requests/.tombstones/$submit_id.json"
    exit 0
    ;;
  *"kill "*) exit 0 ;;
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
clear_runtime
rm -f "$work/.added"
write_removal_race_stub 4242
run_case s13 submit --workdir "$work" --label smoke --request-id "$submit_id" -- true
assert_rc s13 0
run_case s13rm remove 4242
assert_rc s13rm 0
assert_json s13rm '.removed == true and .recovered == true'
clear_runtime
rm -f "$work/.added"

# S14. `data/` and `data/task_logs/` were the only two AgentQ directories the
#      server did NOT converge to 0700 (cancellation/request/runtime already
#      are), so a deployment restored from a 0755 archive stayed readable.
clear_runtime
write_stub "$empty_tasks"
chmod 755 "$work/data" "$work/data/task_logs"
run_case s14 status --summary
assert_rc s14 0
cases=$((cases + 1))
for s14_dir in "$work/data" "$work/data/task_logs"; do
    s14_mode=$(stat -f '%Lp' "$s14_dir" 2>/dev/null || stat -c '%a' "$s14_dir")
    if [ "$s14_mode" != 700 ]; then
        printf 'write-paths s14: %s is mode %s after a command, expected 700\n' "$s14_dir" "$s14_mode" >&2
        failures=$((failures + 1))
    fi
done

# S15. A failing `pueue parallel` during submit is a DEPLOYMENT problem, not a
#      protocol/argument error: the reason class must say deployment_state, as
#      verify_group does for the same group.
cat > "$work/pueue" <<'SH'
#!/bin/sh
case "$*" in
  *"parallel "*) exit 1 ;;
  *"status --json"*) printf '%s\n' '{"tasks":{},"groups":{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}}' ;;
  *"group --json"*) printf '%s\n' '{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}' ;;
  *) printf '%s 4.0.4\n' pueue ;;
esac
SH
chmod 700 "$work/pueue"
clear_runtime
run_case s15 submit --workdir "$work" --label smoke --request-id "$submit_id" -- true
assert_rc s15 2
assert_err_has s15 'cannot ensure AgentQ group'
assert_reason_is s15 deployment_state

# --------------------------------------------------------------- summary
if [ "$failures" -ne 0 ]; then
    printf 'write-paths checks FAILED: cases=%s failures=%s\n' "$cases" "$failures" >&2
    exit 1
fi
printf 'write-paths checks passed: cases=%s reason-gaps=%s\n' "$cases" "$reason_gaps"
