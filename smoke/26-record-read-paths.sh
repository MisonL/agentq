#!/usr/bin/env bash
# Smoke: the request-record READ paths of `lookup` and `wait` keep their contract.
#
# Why this exists.  smoke/18 pins the `status` request-record metadata scan, and
# its "not covered" column records the gap this check closes: only `status` was
# pinned; `lookup` and `wait` read request records through their OWN paths, which
# no check exercised.  `logs` is NOT a record-read path -- it only calls
# compact_task -- so it is deliberately absent here.
#
# Two behaviours here are fail-closed safety properties, not just plumbing:
#
#   * wait, when TWO records both claim the same task id, must REFUSE (exit 2,
#     "multiple AgentQ request records match task id") rather than silently pick
#     one.  Breaking that guard to "first match wins" leaves the whole suite
#     green today; case W4 is the lock.
#   * wait's scan must prefer a matching active RECORD over a matching tombstone
#     (case W5): the record branch reports "was removed before wait", archives the
#     record, and leaves the tombstone in place.
#
# A reachability bound, measured, recorded so the green is not over-read: wait's
# per-record scan only ever sees `accepted` records.  A `removed` record has
# already been archived by `acquire_operation_lock -> ensure_request_record_layout
# -> repair_removed_request_records`, which runs before the command's own scan; a
# `removing` record has already been archived by `ensure_daemon ->
# recover_removing_requests`, which wait calls first.  So the `removed`-skip arm of
# that loop cannot be reached from a synthetic runtime and this check does NOT
# claim it.  In particular W5 is NOT a lock against reusing `load_request_records`
# here: that refactor's behaviour difference on `removed` records is masked by the
# same repair pass, so it is a design caveat (see PLAN.md), not something a case
# can catch.
#
# Everything asserted here was measured on the real server first, not imagined.
#
# Two harness facts inherited from smoke/18, both load-bearing:
#   * the server derives its root from `dirname($0)`, NOT from any env var, so
#     the binary is COPIED into the tree and the tree IS the runtime;
#   * `path_chain_is_safe` rejects any symlink component, and macOS /tmp is a
#     symlink to /private/tmp, so the tree path is canonicalised with pwd -P.
#
# No SKIP: this needs only bash, jq and cp.

set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/agentq-smoke-readpaths.XXXXXX")
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

# The server asks pueue for both the task snapshot and the group list; a stub
# that answers only the first makes a command die with "group is missing",
# which looks like a record problem but is not.  `lookup`'s accepted path needs
# the group; `wait`'s missing-task path needs only status -- answer both.
cat > "$work/pueue" <<'SH'
#!/bin/sh
case "$*" in
  *"status --json"*)
    printf '%s\n' '{"tasks":{},"groups":{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}}'
    ;;
  *"group --json"*)
    printf '%s\n' '{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}'
    ;;
  *) printf '%s 4.0.4\n' pueue ;;
esac
SH
printf '#!/bin/sh\nprintf "%%s 4.0.4\\n" pueued\n' > "$work/pueued"
chmod 700 "$work/pueue" "$work/pueued"

failures=0
cases=0
reason_gaps=0

# clear_runtime -- wipes every record, tombstone and cancellation marker.
#
# `find -delete`, never `rm -f dir/*.json`: when the glob matches nothing, zsh
# (this project's interactive shell) aborts the command under `nomatch` and the
# cleanup silently does nothing, so state leaks between cases.  This bit the
# first draft of this check while probing.
clear_runtime() {
    find "$work/data/agentq-requests" -maxdepth 1 -name '*.json' -delete
    find "$work/data/agentq-requests/.tombstones" -maxdepth 1 -name '*.json' -delete
    find "$work/data/agentq-cancellations" -maxdepth 1 -name '*.json' -delete
}

# record <request_id> <state> <task_id-or-null> <created-or-null>
# A request record in valid shape (passes request_record_filter).  $3/$4 are
# passed through verbatim so `null` stays a JSON null.
record() {
    printf '{"version":1,"request_id":"%s","payload":{"workdir":"/tmp","label":"smoke","argv":["true"]},"task_label":"agentq:%s","state":"%s","task_id":%s,"task_created_at":%s,"created_at":"2026-09-29T00:00:00Z"}\n' \
        "$1" "$1" "$2" "$3" "$4"
}

# tombstone <request_id> <task_id> -- a tombstone matching the record above.
tombstone() {
    printf '{"version":1,"request_id":"%s","task_id":%s,"task_created_at":"2026-09-29T00:00:00Z","state":"removed","removed_at":"2026-09-29T01:00:00Z"}\n' \
        "$1" "$2"
}

put_record() { record "$1" "$2" "$3" "$4" > "$work/data/agentq-requests/$1.json"; }
put_tombstone() { tombstone "$1" "$2" > "$work/data/agentq-requests/.tombstones/$1.json"; }

# run_case <label> [args...]
run_case() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}

assert_rc() {
    local label=$1 expected=$2
    cases=$((cases + 1))
    local rc
    rc=$(cat "$work/$label.rc")
    if [ "$rc" != "$expected" ]; then
        printf 'read-paths %s: expected exit %s, got %s\n' "$label" "$expected" "$rc" >&2
        sed -n '1,3p' "$work/$label.err" >&2 || true
        failures=$((failures + 1))
    fi
}

# assert_json <label> <jq-expression>  (evaluated against stdout)
assert_json() {
    local label=$1 expr=$2
    cases=$((cases + 1))
    if ! jq -e "$expr" < "$work/$label.out" >/dev/null 2>&1; then
        printf 'read-paths %s: stdout failed %s: %s\n' "$label" "$expr" \
            "$(cat "$work/$label.out")" >&2
        failures=$((failures + 1))
    fi
}

assert_err_has() {
    local label=$1 fragment=$2
    cases=$((cases + 1))
    if ! grep -qF -- "$fragment" "$work/$label.err"; then
        printf 'read-paths %s: stderr does not contain %s\n' "$label" "$fragment" >&2
        sed -n '1,3p' "$work/$label.err" >&2 || true
        failures=$((failures + 1))
    fi
}

# assert_reason <label> -- every exit-2 path must carry the machine-readable line.
assert_reason() {
    local label=$1
    cases=$((cases + 1))
    if ! grep -qxF -- 'agentq-server: reason=protocol_error' "$work/$label.err"; then
        printf 'read-paths %s: stderr does not carry reason=protocol_error\n' "$label" >&2
        sed -n '1,3p' "$work/$label.err" >&2 || true
        reason_gaps=$((reason_gaps + 1))
        failures=$((failures + 1))
    fi
}

# assert_counts <label> <expected-records> <expected-tombstones>
assert_counts() {
    local label=$1 want_records=$2 want_tombstones=$3
    cases=$((cases + 1))
    local records tombstones
    records=$(find "$work/data/agentq-requests" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
    tombstones=$(find "$work/data/agentq-requests/.tombstones" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
    if [ "$records" != "$want_records" ] || [ "$tombstones" != "$want_tombstones" ]; then
        printf 'read-paths %s: records=%s tombstones=%s, expected %s/%s\n' \
            "$label" "$records" "$tombstones" "$want_records" "$want_tombstones" >&2
        failures=$((failures + 1))
    fi
}

# ---------------------------------------------------------------- lookup cases

# L1. A malformed record must fail closed on lookup's own path, not just status's.
clear_runtime
printf '{ this is not json\n' > "$work/data/agentq-requests/AQREAD-BADJSON-000001.json"
run_case l1 lookup AQREAD-BADJSON-000001
assert_rc l1 2
assert_err_has l1 'invalid AgentQ request record'
assert_reason l1

# L2. `state: removed` + its tombstone: lookup archives it and reports removed.
#     (The record must be gone, exactly one tombstone left -- lookup's own writer.)
clear_runtime
put_record AQREAD-REMOVED-000001 removed 1001 '"2026-09-29T00:00:00Z"'
put_tombstone AQREAD-REMOVED-000001 1001
run_case l2 lookup AQREAD-REMOVED-000001
assert_rc l2 5
assert_json l2 '.state == "removed"'
assert_json l2 '.task_id == 1001'
assert_counts l2 0 1

# L3. No record and no tombstone: not_found is exit 3, never a completion.
clear_runtime
run_case l3 lookup AQREAD-MISSING-000001
assert_rc l3 3
assert_json l3 '.state == "not_found" and .task_id == null'

# L4. A tombstone without an active record: removed, exit 5.
clear_runtime
put_tombstone AQREAD-TOMBONLY-00001 1001
run_case l4 lookup AQREAD-TOMBONLY-00001
assert_rc l4 5
assert_json l4 '.state == "removed" and .task_id == 1001'

# L5. A `prepared` record whose task never reached Pueue: not_started, exit 3.
clear_runtime
put_record AQREAD-PREPARED-00001 prepared null null
run_case l5 lookup AQREAD-PREPARED-00001
assert_rc l5 3
assert_json l5 '.state == "not_started" and .task_id == null'

# L6. An `accepted` record whose task has vanished from Pueue: removed, exit 5.
clear_runtime
put_record AQREAD-ACCEPTED-00001 accepted 1001 '"2026-09-29T00:00:00Z"'
run_case l6 lookup AQREAD-ACCEPTED-00001
assert_rc l6 5
assert_json l6 '.state == "removed" and .task_id == 1001'

# L7. An illegal request-id shape is refused before any record is touched.
clear_runtime
run_case l7 lookup 'has space'
assert_rc l7 2
assert_err_has l7 'request id must be 16-128'
assert_reason l7

# ------------------------------------------------------------------ wait cases

# W1. A task Pueue has never seen, with no record or tombstone: unknown id, exit 2.
clear_runtime
run_case w1 wait 1001
assert_rc w1 2
assert_err_has w1 'unknown AgentQ task id: 1001'
assert_reason w1

# W2. A matching tombstone: already removed, exit 5.
clear_runtime
put_tombstone AQREAD-WTOMB-00000001 1001
run_case w2 wait 1001
assert_rc w2 5
assert_json w2 '.state == "removed" and .task_id == 1001'
assert_err_has w2 'was already removed before wait'

# W3. One matching accepted record whose task vanished: removed, exit 5, and the
#     record is archived (this is wait's own writer, exercised through the scan).
clear_runtime
put_record AQREAD-WACC-000000001 accepted 1001 '"2026-09-29T00:00:00Z"'
run_case w3 wait 1001
assert_rc w3 5
assert_json w3 '.state == "removed" and .task_id == 1001'
assert_err_has w3 'was removed before wait'
assert_counts w3 0 1

# W4. THE SAFETY CASE: two records both claim task id 1001.  wait must refuse --
#     exit 2 -- rather than silently resolve to one of them.
clear_runtime
put_record AQREAD-AMBIG-A-00001 accepted 1001 '"2026-09-29T00:00:00Z"'
put_record AQREAD-AMBIG-B-00002 accepted 1001 '"2026-09-29T00:00:00Z"'
run_case w4 wait 1001
assert_rc w4 2
assert_err_has w4 'multiple AgentQ request records match task id: 1001'
assert_reason w4

# W5. Record takes precedence over tombstone in wait's scan.  With BOTH a
#     matching `accepted` record and a matching tombstone present, wait takes the
#     RECORD branch: it reports "was removed before wait" (not "...already
#     removed..."), archives the record, and leaves the pre-existing tombstone in
#     place (so the tombstone count goes to 2, not 1).  This is the reachable
#     branch of wait's own scan -- see the note below on which states are not
#     reachable here.
#
#     Why not a `removed` record (the obvious case): `acquire_operation_lock`
#     runs `ensure_request_record_layout -> repair_removed_request_records`
#     before the command's own scan, and that pass archives every `removed`
#     record itself.  A `removing` record is likewise archived by `ensure_daemon`
#     -> `recover_removing_requests`, which wait calls before this scan.  So only
#     an `accepted` record actually reaches wait's per-record loop; the `removed`
#     skip branch is unreachable on this path and is NOT claimed as covered.
clear_runtime
put_record AQREAD-BOTH-00000001 accepted 1001 '"2026-09-29T00:00:00Z"'
put_tombstone AQREAD-OTTOM-00000001 1001
run_case w5 wait 1001
assert_rc w5 5
assert_json w5 '.state == "removed" and .task_id == 1001'
assert_err_has w5 'was removed before wait'
assert_counts w5 0 2

# --------------------------------------------------------------- summary
if [ "$failures" -ne 0 ]; then
    printf 'read-paths checks FAILED: cases=%s failures=%s\n' "$cases" "$failures" >&2
    exit 1
fi
printf 'read-paths checks passed: cases=%s reason-gaps=%s\n' "$cases" "$reason_gaps"
