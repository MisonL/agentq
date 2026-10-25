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
# same repair pass, so it is a design caveat (see docs/PLAN.md), not something a case
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
# python3 is a real dependency: the record-rewriting steps below are Python.
# The old header claimed "this needs only bash, jq and cp", which was wrong.
# Probe that it RUNS, not that a name resolves -- measured 2026-10-20 on a
# zh-CN Windows 10, where `python3` is the Microsoft Store alias.  Measured
# 2026-10-25: with a stub python3 that exits 49, this check exited 49 with
# ZERO output, which run-tests.sh can only report as a bare FAIL with no
# cause -- an ENVIRONMENT fault presented as a contract failure.  Same rule as
# the pwsh usability probes.
python3_probe_status=0
python3 -c 'import sys' >/dev/null 2>&1 || python3_probe_status=$?
if [ "$python3_probe_status" -ne 0 ]; then
    printf '%s\n' 'read-paths NOT run: the python3 on PATH cannot execute (a Microsoft Store alias cannot run scripts).' >&2
    printf '%s\n' 'Install a real Python 3 and put it on PATH, then re-run.' >&2
    exit 1
fi

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
# The task snapshot is seedable: a case that needs VISIBLE tasks writes
# tasks.json next to this stub (the same pattern smoke/27 uses); otherwise the
# empty snapshot keeps every other case unchanged.
self_dir=$(dirname "$0")
case "$*" in
  *"status --json"*)
    if [ -f "$self_dir/tasks.json" ]; then
      cat "$self_dir/tasks.json"
    else
      printf '%s\n' '{"tasks":{},"groups":{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}}'
    fi
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

# W2b. A tombstone reached through a SYMLINK must be refused.  This is the
#      tombstone-scan lock: every other case seeds a plain tombstone file, so
#      nothing exercised the scan's path guards.  The symlink points OUTSIDE
#      the tombstone directory and every chain component above it is a real
#      directory, so the refusal comes from `request_metadata_file_is_safe`,
#      which rejects a symlink at the leaf DIRECTLY (`[ ! -L "$metadata_path" ]`)
#      and again via its chain walk (`path_chain_is_safe`).  Measured 2026-10-12:
#      emptying ONLY the chain-walk check leaves this case green -- the leaf
#      check catches it first -- so the guard this fixture actually pins is the
#      pair, not the chain walk alone.  (A variant that drops the whole
#      `request_tombstone_path_guards_or_fail` call falls through to the
#      fallback `read_request_tombstone`, whose jq follows the link and ACCEPTS
#      the well-formed tombstone behind it: green with the guard, red without
#      it. Measured 2026-10-11 both ways.)
sym_tomb_target="$work/symlink-target-tomb.json"
tombstone AQREAD-SYMTOMB-000001 1001 > "$sym_tomb_target"
clear_runtime
ln -s "$sym_tomb_target" "$work/data/agentq-requests/.tombstones/AQREAD-SYMTOMB-000001.json"
run_case w2b wait 1001
assert_rc w2b 2
assert_err_has w2b 'invalid AgentQ request tombstone path'
assert_reason w2b

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

# W6. Two visible tasks share the AgentQ label: the server cannot choose
#     safely, and that is exit 4/ambiguous -- NOT "cannot inspect Pueue", which
#     claims the inspection failed when it succeeded and the result was merely
#     ambiguous.  Measured 2026-10-06: six call sites collapsed
#     find_request_task's rc=4 into the generic exit-2 fail.
clear_runtime
cat > "$work/tasks.json" <<'TASKS'
{"tasks":{"1001":{"id":1001,"created_at":"2026-09-29T00:00:00Z","command":"true","label":"agentq:AQREAD-AMBI-0000001","status":{"Done":{"result":"Success","exit_code":0}},"group":"agentq"},"1002":{"id":1002,"created_at":"2026-09-29T00:00:01Z","command":"true","label":"agentq:AQREAD-AMBI-0000001","status":{"Running":{}},"group":"agentq"}},"groups":{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}}
TASKS
put_record AQREAD-AMBI-0000001 accepted 1001 '"2026-09-29T00:00:00Z"'
run_case w6 lookup AQREAD-AMBI-0000001
assert_rc w6 4
assert_json w6 '.state == "ambiguous"'
assert_err_has w6 'multiple Pueue tasks share the AgentQ label'
rm -f "$work/tasks.json"

# ------------------------------------------------- native-Windows jq (CRLF)
# W7. A jq whose stdout is in TEXT MODE writes CRLF.  That is not a quirk of a
#     bad build: the jq a Windows user gets from chocolatey is a native Windows
#     binary, and every newline it prints is `\r\n` (measured 2026-10-10 on a
#     real Windows host, jq-1.7.1).  `$( )` strips only the FINAL newline, so
#     every INTERIOR line keeps its `\r`; the scan loops then read `275\r`,
#     which is_task_id rejects, and a task that was REMOVED comes back as
#     `invalid AgentQ task id` with exit 2 instead of 5.
#
#     Found on that real host: `wait` on a removed task failed with
#     `invalid AgentQ task id: 275` while `lookup` (a single-file read, whose
#     `$( )` strips the only newline) returned 5 correctly.  The defect predates
#     this session -- the aggregate scans that carry it landed in 76b9cfe and
#     shipped in every release since -- and no macOS or Linux check could see
#     it, because a POSIX jq writes LF.
#
#     The shim is faithful, not a mock of the failure: it runs the REAL jq and
#     appends CR to each of its output lines, which is exactly what text mode
#     does.  Both directions are asserted below (the same tombstone case with
#     and without the shim), so a fix that broke ordinary jq would be caught
#     too.
windows_jq_directory="$work/bin-windows-jq"
mkdir -p "$windows_jq_directory"
# Resolve the real jq ONCE, here, before the shim exists: the shim's own PATH
# lookup would find itself (measured: the first draft recursed and hung).
real_jq=$(command -v jq)
[ -n "$real_jq" ] || { printf '%s\n' 'read-paths: jq is required for the CRLF case' >&2; exit 1; }
cat > "$windows_jq_directory/jq" <<SH
#!/bin/sh
# Native-Windows jq: real jq, CRLF stdout.  The real binary is resolved from a
# fixed absolute path, never from PATH -- resolving it through PATH would find
# THIS script and recurse (measured: the first draft of this shim did exactly
# that and hung).
#
# CR on every line EXCEPT the last, which is the shape that actually reaches the
# server on the real host.  A text-mode jq writes \r\n on all lines, but the
# consumer reads it through \$( ), and MSYS bash's \$( ) strips a trailing
# \r\n as a unit -- so the LAST line's \r never survives while every INTERIOR
# one does.  Appending CR to all lines (the first draft) is NOT faithful: it
# leaves a trailing \r that the real path cannot produce, which made this case
# pass against two probe bugs that were fatal on the real host (a single-line
# probe and an ends-with case pattern).  Measured on the real host: the probe
# output there was \`a \\r \\n b\`, i.e. interior CR only.
#
# No \${PIPESTATUS[...]}: this is \`#!/bin/sh\`, which is dash on Debian/Ubuntu,
# where PIPESTATUS is a bashism and expands to a "Bad substitution" error.
# (Measured: the bash-only form passed on macOS and failed the linux CI job with
# \`Bad substitution\` -- the same platform-portability class the CI gate exists
# to catch.)  jq runs first into a temp file so its OWN status is what the shim
# returns -- the server uses \`jq -e\` predicates, and returning sed's status
# instead would make a false predicate look true.
output_file=\$(mktemp)
"$real_jq" "\$@" > "\$output_file"
status=\$?
sed '\$!s/\$/\r/' "\$output_file"
rm -f "\$output_file"
exit "\$status"
SH
chmod 700 "$windows_jq_directory/jq"

# The baseline first: without the shim the tombstone case must already pass, or
# the CRLF case below would be proving nothing about CR.
clear_runtime
put_tombstone AQREAD-WTOMB-00000001 1001
run_case w7base wait 1001
assert_rc w7base 5
assert_json w7base '.state == "removed" and .task_id == 1001'

# Same state, CRLF jq.  Before the fix this was exit 2 with
# `invalid AgentQ task id: 1001`; it must be identical to the baseline.
clear_runtime
put_tombstone AQREAD-WTOMB-00000001 1001
run_case_with_windows_jq() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && PATH="$windows_jq_directory:$PATH" "$work/agentq-server" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_case_with_windows_jq w7crlf wait 1001
assert_rc w7crlf 5
assert_json w7crlf '.state == "removed" and .task_id == 1001'

# And the RECORD scan (the other aggregate reader) under the same shim: an
# accepted record whose task vanished must still archive and report removed.
clear_runtime
put_record AQREAD-WCRLF-00000001 accepted 1001 '"2026-09-29T00:00:00Z"'
run_case_with_windows_jq w7record wait 1001
assert_rc w7record 5
assert_json w7record '.state == "removed" and .task_id == 1001'
assert_err_has w7record 'was removed before wait'

# ---------------------------------------------- V: the vanish window (A-F2)
#
# `load_request_records` runs on the LOCK-FREE read paths, so an archiver can
# delete a record after the guard accepted it and before the read.  That is a
# RACE, not a guard violation, and the producer must emit the `null` placeholder
# for it -- anything else turns an unrelated `status` into exit 2 while a
# concurrent remove is in flight.
#
# The window is a few microseconds per record and could not be hit from a
# synthetic runtime (40 + 25 timing trials: 0 hits).  So this case does NOT
# race.  It asserts the two END STATES the producer must discriminate, which is
# where a regression would show up:
#
#   * ABSENT  -> tolerated (placeholder, command succeeds)
#   * PRESENT but unsafe (here: a directory) -> still fatal
#
# Together they pin the guard's shape: a fix that swallowed everything would
# fail the second, and a fix that swallowed nothing would fail the first.
# The A/B evidence that the new failure-path checks are what produce the first
# row is the mutation proof in docs/PLAN.md (same `rm` injected into both the
# 0.1.17 and 0.1.18 servers: 0.1.17 exit 2, 0.1.18 exit 0).

# V1. A record path that has become a DIRECTORY must stay fatal.  It exists, so
#     it is not a vanish; `request_metadata_file_is_safe` rejects it.
clear_runtime
mkdir -p "$work/data/agentq-requests/AQREAD-VDIR-00000001.json"
run_case v1 status
assert_rc v1 2
assert_err_has v1 'invalid AgentQ request record path'
assert_reason v1
rmdir "$work/data/agentq-requests/AQREAD-VDIR-00000001.json"

# V2. A DANGLING SYMLINK at the record path is NOT a vanish: `[ -L ]` is true,
#     so the path still exists as an object even though its target does not.
#     It must stay fatal -- the distinction the fix rests on is "gone" vs
#     "present but unsafe", and a symlink is the latter.  (V1 asserted the
#     directory shape of the same verdict; this pins the other one, so a fix
#     that widened `tracked_path_vanished` (born `request_record_vanished`) to "unreadable" fails here.)
clear_runtime
ln -s /nonexistent/agentq-vanish-target \
    "$work/data/agentq-requests/AQREAD-VDANGLE-0000001.json"
run_case v2 status
assert_rc v2 2
assert_err_has v2 'invalid AgentQ request record path'
assert_reason v2
find "$work/data/agentq-requests" -maxdepth 1 -name '*.json' -type l -delete

# V3. The source of the vanish arm is visible in the asset: every reader that
#     can race an archiver carries it -- load_request_records (3 sites: guard,
#     guard, read), the shared request_record_path_guards_or_fail (2), its
#     tombstone twin request_tombstone_path_guards_or_fail (2), the single-file
#     readers' read arms (3: read_request_record, read_request_tombstone,
#     read_request_record_state_and_body), request_tombstone_is_valid (1),
#     load_cancellation_markers (2) and cancellation_marker_is_valid (3: two
#     guards plus the guard-to-read gap), and the non-UTF-8 log branch in
#     compact_log (1).  Note the OTHER readers that carry no
#     site because their whole read is wrapped in a `{ ... } 2>/dev/null`
#     group (wait's two batch scans, task_instance_created_at_is_recorded's
#     fast path): those are safe by construction, not by a vanish arm.
#     A copy on a SUCCESS path would restore the 4-guard cost
#     those loops were trimmed for, so the count is also the shape.  The
#     cancellation-marker pair was added 2026-10-22 after the same race was
#     measured there (it exited 1 -- a code the contract does not define for
#     it -- while printing reason=protocol_error); the two read arms were added
#     the same day when read_request_record turned out to have the same defect
#     (V10/V11); the tombstone twin's two arms and read_request_tombstone's
#     read arm followed in the same session (V13/V14).
cases=$((cases + 1))
vanish_sites=$(grep -c 'tracked_path_vanished ' "$work/agentq-server" || true)
if [ "$vanish_sites" != 16 ]; then
    printf 'read-paths v3: expected 16 tracked_path_vanished sites, got %s\n' \
        "$vanish_sites" >&2
    failures=$((failures + 1))
fi

# V4. The positive half: a record that DOES vanish must be tolerated.  The
#     window is microseconds and could not be hit by timing (40 + 25 trials:
#     0 hits, recorded in docs/PLAN.md), so this case FORCES it -- it copies the
#     server, injects one `rm` between the accepted guard and the precision
#     probe inside load_request_records, and requires the command to succeed.
#     An injected `rm` is not a substitute for the real race, but it is the same
#     failure the fix targets, and it is the only way to assert the arm at all.
#     A regression that dropped the vanish checks fails here with exit 2 and
#     `invalid AgentQ request record path`.
clear_runtime
put_record AQREAD-VFORCE-0000001 accepted 1001 '"2026-09-29T00:00:00Z"'
python3 - "$work/agentq-server" "$work/agentq-server-forced" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split('\n')
start = next(i for i, l in enumerate(lines) if l.startswith('load_request_records() {'))
end = next(i for i in range(start + 1, len(lines)) if lines[i] == '}')
target = next(i for i in range(start, end)
              if 'validate_task_id_precision_in_file "$record_path"' in lines[i])
indent = ' ' * (len(lines[target]) - len(lines[target].lstrip()))
lines.insert(target, indent + 'rm -f "$record_path"  # SMOKE: forced vanish')
open(dst, 'w').write('\n'.join(lines))
PY
chmod 700 "$work/agentq-server-forced"
run_forced() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server-forced" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_forced v4 status
assert_rc v4 0
assert_json v4 '.group.status == "Running"'
cases=$((cases + 1))
if grep -qF 'invalid AgentQ request record' "$work/v4.err"; then
    printf 'read-paths v4: forced vanish still reported as a record error\n' >&2
    sed -n '1,3p' "$work/v4.err" >&2
    failures=$((failures + 1))
fi

# V5. And the same forced vanish through the OTHER reader (the repair pass that
#     runs from the migrator) -- the second copy of this defect, found by V2's
#     first draft.  Its rm goes into the shared guard helper.
clear_runtime
put_record AQREAD-VREPAIR-000001 accepted 1001 '"2026-09-29T00:00:00Z"'
python3 - "$work/agentq-server" "$work/agentq-server-forced2" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.startswith('request_record_path_guards_or_fail() {'))
end = next(i for i in range(start + 1, len(lines)) if lines[i] == '}')
target = next(i for i in range(start, end)
              if 'validate_task_id_precision_in_file "$record_path"' in lines[i])
indent = ' ' * (len(lines[target]) - len(lines[target].lstrip()))
lines.insert(target, indent + 'rm -f "$record_path"  # SMOKE: forced vanish')
open(dst, 'w').write('\n'.join(lines))
PY
chmod 700 "$work/agentq-server-forced2"
run_forced2() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server-forced2" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_forced2 v5 status
assert_rc v5 0
cases=$((cases + 1))
if grep -qF 'failed to recover removing AgentQ requests' "$work/v5.err"; then
    printf 'read-paths v5: forced vanish in the repair pass still aborted recovery\n' >&2
    sed -n '1,3p' "$work/v5.err" >&2
    failures=$((failures + 1))
fi

# V6. The repair FALLBACK loop (reached only when the batch fast path failed)
#     had the same defect in a second form, found 2026-10-22 AFTER 0.1.18 was
#     cut: read_request_record_state_and_body folded the vanished verdict into
#     the failure code (`|| return 2`, written against the opposite intuition --
#     `fail` never returns, so that `||` only ever sees 1).  The result was
#     `missing AgentQ request record during recovery` on a record a concurrent
#     archiver had deleted.
#
#     The vanish must happen ONLY in the fallback, so the injected rm is
#     count-gated: the fast path's call leaves the file alone, the fallback's
#     call deletes it.  A directory record forces the fast path to fail, which
#     is what makes the fallback run at all.  Assertion: the vanished record
#     must NOT be the one named by the recovery failure -- the failure must be
#     the directory's, which is the genuinely unsafe one.
clear_runtime
put_record AQREAD-VFALLBACK-0001 accepted 1001 '"2026-09-29T00:00:00Z"'
mkdir -p "$work/data/agentq-requests/AQREAD-VFBDIR-00000002.json"
python3 - "$work/agentq-server" "$work/agentq-server-forced3" "$work/.v6cnt" <<'PYV6'
import sys
src, dst, counter = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(src).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.startswith('request_record_path_guards_or_fail() {'))
end = next(i for i in range(start + 1, len(lines)) if lines[i] == '}')
target = next(i for i in range(start, end)
              if 'validate_task_id_precision_in_file "$record_path"' in lines[i])
indent = ' ' * (len(lines[target]) - len(lines[target].lstrip()))
inj = (indent + 'case $record_path in *VFALLBACK*) '
       + 'c=$(cat "' + counter + '" 2>/dev/null || echo 0); c=$((c+1)); '
       + 'printf %s "$c" > "' + counter + '"; '
       + '[ "$c" -ge 2 ] && rm -f "$record_path" ;; esac')
lines.insert(target, inj)
open(dst, 'w').write('\n'.join(lines))
PYV6
chmod 700 "$work/agentq-server-forced3"
rm -f "$work/.v6cnt"
run_forced3() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server-forced3" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_forced3 v6 status
assert_rc v6 2
cases=$((cases + 1))
if grep -qF 'AQREAD-VFALLBACK-0001' "$work/v6.err"; then
    printf 'read-paths v6: the fallback blamed the VANISHED record instead of skipping it\n' >&2
    sed -n '1,3p' "$work/v6.err" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if ! grep -qF 'AQREAD-VFBDIR-00000002' "$work/v6.err"; then
    printf 'read-paths v6: the genuinely unsafe record was not the one reported\n' >&2
    sed -n '1,3p' "$work/v6.err" >&2
    failures=$((failures + 1))
fi
rmdir "$work/data/agentq-requests/AQREAD-VFBDIR-00000002.json"

# V7. The cancellation-marker reader is the third copy of the same race, and
#     its symptom was worse: the marker loop's `fail` made the pipeline fail,
#     so a TRANSIENT concurrent deletion surfaced as a hard failure (exit 1)
#     carrying `reason=protocol_error` -- and the documented rule is to read
#     `reason=` rather than the message, so a caller would classify a benign
#     race as a bad argument.  Markers are NOT positionally bound to ids, so
#     skipping one is safe (unlike a record, which needs the `null` placeholder
#     to keep the binding aligned).
clear_runtime
printf '{"version":1,"task_id":1,"task_created_at":"2026-09-29T00:00:00Z","state":"requested","requested_at":"2026-09-29T00:00:00Z"}\n' \
    > "$work/data/agentq-cancellations/1.json"
# A fixture that cannot be applied is a FAILURE of this case, never a crash:
# running this check against an older asset must report "the marker guard is
# not the shape this case injects into", not die with a traceback (a crash and
# an assertion-red are different verdicts -- recorded lesson from smoke/10).
cases=$((cases + 1))
if ! python3 - "$work/agentq-server" "$work/agentq-server-forced4" <<'PYV7'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
needle = '            request_metadata_file_is_safe "$marker_path" || {'
if s.count(needle) != 2:
    sys.stderr.write('fixture: expected 2 vanish-tolerant marker guards, found %d\n'
                     % s.count(needle))
    sys.exit(3)
s = s.replace(needle, '            rm -f "$marker_path"  # SMOKE: forced vanish\n' + needle, 1)
open(dst, 'w').write(s)
PYV7
then
    printf 'read-paths v7: could not inject the forced vanish (see fixture message above)\n' >&2
    failures=$((failures + 1))
fi
# When the injection failed the fixture already counted one failure; running
# against a file that was never produced would only add a `chmod: No such file`
# cascade of NOISE, which reads like two more failures than there are.
if [ ! -f "$work/agentq-server-forced4" ]; then
    clear_runtime
    : # fall through to the summary with the one failure the fixture recorded
else
chmod 700 "$work/agentq-server-forced4"
run_forced4() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server-forced4" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_forced4 v7 status
assert_rc v7 0
cases=$((cases + 1))
if grep -qF 'invalid AgentQ cancellation marker' "$work/v7.err"; then
    printf 'read-paths v7: a vanished cancellation marker was reported as invalid\n' >&2
    sed -n '1,3p' "$work/v7.err" >&2
    failures=$((failures + 1))
fi
fi
clear_runtime

# V8. The WAIT reconcile fallback is the fourth reader with the same defect
#     (found 2026-10-22 in the same self-check as V6/V7).  Its fast path runs
#     inside `with_operation_lock`, whose acquire pass calls the same guard
#     helper from the repair scan, so an injected rm count-gated to the 2nd call
#     fires in the WAIT fast path -- and it is the FALLBACK that then sees the
#     file gone.  Released 0.1.18 answered `missing AgentQ request record during
#     wait recovery`; the vanished record must instead be SKIPPED, and the
#     scanner converges on "nothing tracks this id".
#
#     Both directions are asserted: the vanished record must NOT be named, and
#     the verdict must be the converged one (`unknown AgentQ task id`), not a
#     record error.
clear_runtime
put_record AQREAD-VWAIT-000001 accepted 1001 '"2026-09-29T00:00:00Z"'
python3 - "$work/agentq-server" "$work/agentq-server-forced5" "$work/.v8cnt" <<'PYV8'
import sys
src, dst, counter = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(src).read().split('\n')
start = next(i for i, l in enumerate(lines)
             if l.startswith('request_record_path_guards_or_fail() {'))
end = next(i for i in range(start + 1, len(lines)) if lines[i] == '}')
target = next(i for i in range(start, end)
              if 'validate_task_id_precision_in_file "$record_path"' in lines[i])
indent = ' ' * (len(lines[target]) - len(lines[target].lstrip()))
inj = (indent + 'c=$(cat "' + counter + '" 2>/dev/null || echo 0); c=$((c+1)); '
       + 'printf %s "$c" > "' + counter + '"; [ "$c" -ge 2 ] && rm -f "$record_path"')
lines.insert(target, inj)
open(dst, 'w').write('\n'.join(lines))
PYV8
chmod 700 "$work/agentq-server-forced5"
rm -f "$work/.v8cnt"
run_forced5() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server-forced5" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_forced5 v8 wait 1001
assert_rc v8 2
assert_err_has v8 'unknown AgentQ task id'
cases=$((cases + 1))
if grep -qF 'missing AgentQ request record during wait recovery' "$work/v8.err"; then
    printf 'read-paths v8: the wait fallback blamed the VANISHED record instead of skipping it\n' >&2
    sed -n '1,3p' "$work/v8.err" >&2
    failures=$((failures + 1))
fi

# V9. The other direction on the same path: a record that is PRESENT but
#     UNSAFE (here a directory) must still fail loudly.  Without this, "skip
#     everything the reader refuses" would pass V8.
clear_runtime
mkdir -p "$work/data/agentq-requests/AQREAD-VWAITDIR-0002.json"
run_case v9 wait 1001
assert_rc v9 2
assert_err_has v9 'invalid AgentQ request record path'
assert_reason v9
rmdir "$work/data/agentq-requests/AQREAD-VWAITDIR-0002.json"
clear_runtime

# V10. read_request_record is the FIFTH copy of the same defect, found
#      2026-10-22 after V6-V9 were fixed.  It runs under the operation lock, but
#      the archiver it races does NOT: repair_removed_request_records is called
#      from migrate_removed_request_records on the lock-free read paths
#      (status/logs/doctor), so a lock holder is not shielded from it.  The
#      window is exactly "the record is already `removed` and a concurrent
#      status archives it" -- nothing else deletes a record.
#
#      Released 0.1.18 answered a vanished record with
#      `invalid AgentQ request record path` + exit 2: a caller told to fix its
#      arguments when the truth was "it is gone".  Measured A/B with the rm
#      injected before the guard call: 0.1.18 exit 2 with that message, the
#      fixed tree exit 3 (not_found, the converged answer) and NO stderr line
#      at all -- the read is deliberately silent so a benign race cannot put
#      unexplained text on a successful call's stderr (the clients scan that
#      stream for `reason=`).
clear_runtime
put_record AQREAD-VREADER-00001 accepted 1001 '"2026-09-29T00:00:00Z"'
cases=$((cases + 1))
# The injection point is STRUCTURAL, not a string that only exists in the
# fixed shape: it goes immediately after the existence check inside
# read_request_record, which every version of this reader has.  Anchoring on
# the fix's own variable made the case un-injectable against the pre-fix
# reader, so the mutation test reported "fixture could not inject" instead of
# "the reader answered wrongly" -- a fixture miss masquerading as coverage.
if ! python3 - "$work/agentq-server" "$work/agentq-server-forced6" <<'PYV10'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split('\n')
try:
    start = next(i for i, l in enumerate(lines) if l.startswith('read_request_record() {'))
except StopIteration:
    sys.stderr.write('fixture: read_request_record is not defined\n')
    sys.exit(3)
end = next(i for i in range(start + 1, len(lines)) if lines[i] == '}')
# Anchor on the EXISTENCE CHECK itself (`[ ! -e ... ] && [ ! -L ... ]`), which
# every version of this reader has, and insert right after the `fi` that closes
# it.  Two earlier anchors were wrong and both showed up as fixture misses
# rather than vermin: `return 1` matched the `is_request_id` refusal first
# (where `$record_path` is still unset, so the injected rm does nothing and the
# case passed for the wrong reason), and a count guard then rejected the
# pre-fix reader, whose shape has only one such line.  A fixture that cannot
# inject against the OLD code cannot prove anything about the new.
guard = next(i for i in range(start, end) if '[ ! -e "$record_path" ]' in lines[i])
fi = next(i for i in range(guard, end) if lines[i].strip() == 'fi')
check = fi
indent = ' ' * (len(lines[check]) - len(lines[check].lstrip()))
lines.insert(check + 1, indent + 'rm -f "$record_path"  # SMOKE: forced vanish')
open(dst, 'w').write('\n'.join(lines))
PYV10
then
    printf 'read-paths v10: could not inject the forced vanish (see fixture message above)\n' >&2
    failures=$((failures + 1))
fi
if [ -f "$work/agentq-server-forced6" ]; then
chmod 700 "$work/agentq-server-forced6"
run_forced6() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server-forced6" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_forced6 v10 lookup AQREAD-VREADER-00001
assert_rc v10 3
assert_json v10 '.state == "not_found"'
cases=$((cases + 1))
if grep -qF 'invalid AgentQ request record' "$work/v10.err"; then
    printf 'read-paths v10: a vanished record was reported as an invalid record\n' >&2
    sed -n '1,3p' "$work/v10.err" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if [ -s "$work/v10.err" ]; then
    printf 'read-paths v10: a benign vanish put text on stderr (clients scan it for reason=)\n' >&2
    sed -n '1,3p' "$work/v10.err" >&2
    failures=$((failures + 1))
fi
fi

# V11. The other direction on the same reader: PRESENT but UNSAFE must still
#      fail loudly, with the path message and the reason line.  Without this,
#      "treat every read failure as gone" would pass V10 -- and that is the
#      fail-open shape this project has fixed four times already.
clear_runtime
mkdir -p "$work/data/agentq-requests/AQREAD-VREADERDIR-01.json"
run_case v11 lookup AQREAD-VREADERDIR-01
assert_rc v11 2
assert_err_has v11 'invalid AgentQ request record path'
assert_reason v11
rmdir "$work/data/agentq-requests/AQREAD-VREADERDIR-01.json"

# V12. And a record that is present but MALFORMED keeps its own message: the
#      vanish arm must not swallow a real integrity failure into "not found".
#      (V10's "no stderr" assertion is only safe because THIS direction still
#      speaks.)
clear_runtime
printf '{ this is not json\n' > "$work/data/agentq-requests/AQREAD-VREADERBAD-01.json"
run_case v12 lookup AQREAD-VREADERBAD-01
assert_rc v12 2
assert_err_has v12 'invalid AgentQ request record'
assert_reason v12

# V13. The TOMBSTONE readers were the sixth and seventh copies (2026-10-23).
#      Two distinct holes, and the second is the interesting one:
#        * read_request_tombstone had a read arm but the shared guard it calls
#          (request_tombstone_path_guards_or_fail) began with a BARE `fail` for
#          "not present", so a vanish never reached the arm.  That also made the
#          `null` placeholder in wait's batch scan dead code.
#        * read_cancellation_marker had two direct guards in front of the
#          vanish-tolerant validator, so its own comment ("a vanished marker is
#          no marker") was false: the guards failed first.
#      Both are measured here with the same structural injection as V10.
clear_runtime
put_tombstone AQREAD-VTOMB-00000001 1001
cases=$((cases + 1))
if ! python3 - "$work/agentq-server" "$work/agentq-server-forced7" <<'PYV13'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split('\n')
start = next(i for i, l in enumerate(lines) if l.startswith('read_request_tombstone() {'))
end = next(i for i in range(start + 1, len(lines)) if lines[i] == '}')
guard = next(i for i in range(start, end) if '[ ! -e "$tombstone_path" ]' in lines[i])
fi = next(i for i in range(guard, end) if lines[i].strip() == 'fi')
indent = ' ' * (len(lines[fi]) - len(lines[fi].lstrip()))
lines.insert(fi + 1, indent + 'rm -f "$tombstone_path"  # SMOKE: forced vanish')
open(dst, 'w').write('\n'.join(lines))
PYV13
then
    printf 'read-paths v13: could not inject the forced vanish (see fixture message above)\n' >&2
    failures=$((failures + 1))
fi
if [ -f "$work/agentq-server-forced7" ]; then
chmod 700 "$work/agentq-server-forced7"
run_forced7() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server-forced7" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_forced7 v13 lookup AQREAD-VTOMB-00000001
assert_rc v13 3
assert_json v13 '.state == "not_found"'
cases=$((cases + 1))
if grep -qF 'invalid AgentQ request tombstone' "$work/v13.err"; then
    printf 'read-paths v13: a vanished tombstone was reported as invalid\n' >&2
    sed -n '1,3p' "$work/v13.err" >&2
    failures=$((failures + 1))
fi
fi
rm -f "$work/data/agentq-requests/.tombstones/AQREAD-VTOMB-00000001.json"

# V14. The marker reader.  This one runs through the LOCK-FREE repair path:
#      a `removed` record plus its marker makes repair archive the record, and
#      archiving removes the marker via remove_cancellation_marker_for_task ->
#      read_cancellation_marker.  Injecting the vanish inside that reader must
#      leave `status` succeeding (the marker is simply gone), not exit 2.
clear_runtime
put_record AQREAD-VMARK-00000001 removed 1001 '"2026-09-29T00:00:00Z"'
printf '{"version":1,"task_id":1001,"task_created_at":"2026-09-29T00:00:00Z","state":"requested","requested_at":"2026-09-29T00:00:00Z","created_at":"2026-09-29T00:00:00Z","reason":"smoke"}\n' \
    > "$work/data/agentq-cancellations/1001.json"
cases=$((cases + 1))
if ! python3 - "$work/agentq-server" "$work/agentq-server-forced8" <<'PYV14'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split('\n')
try:
    start = next(i for i, l in enumerate(lines) if l.startswith('read_cancellation_marker() {'))
except StopIteration:
    sys.stderr.write('fixture: read_cancellation_marker is not defined\n')
    sys.exit(3)
end = next(i for i in range(start + 1, len(lines)) if lines[i] == '}')
# STRUCTURAL anchor (same lesson as V10): insert right after the existence
# check's `fi`, which every version of this reader has -- 0.1.18, 0.1.19 and
# the fixed tree.  Anchoring on the fix's own `marker_status` lines made the
# case un-injectable against the pre-fix reader, so the mutation test reported
# "fixture could not inject" instead of "the reader answered wrongly".
guard = next((i for i in range(start, end) if '[ ! -e "$marker_path" ]' in lines[i]), None)
if guard is None:
    sys.stderr.write('fixture: read_cancellation_marker has no existence check\n')
    sys.exit(3)
fi = next((i for i in range(guard, end) if lines[i].strip() == 'fi'), None)
if fi is None:
    sys.stderr.write('fixture: existence check is not an if/fi block\n')
    sys.exit(3)
indent = ' ' * (len(lines[fi]) - len(lines[fi].lstrip()))
lines.insert(fi + 1, indent + 'rm -f "$marker_path"  # SMOKE: forced vanish')
open(dst, 'w').write('\n'.join(lines))
PYV14
then
    printf 'read-paths v14: could not inject the forced vanish (see fixture message above)\n' >&2
    failures=$((failures + 1))
fi
if [ -f "$work/agentq-server-forced8" ]; then
chmod 700 "$work/agentq-server-forced8"
run_forced8() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server-forced8" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_forced8 v14 status
assert_rc v14 0
cases=$((cases + 1))
if grep -qF 'invalid AgentQ cancellation marker' "$work/v14.err"; then
    printf 'read-paths v14: a vanished marker was reported as invalid\n' >&2
    sed -n '1,3p' "$work/v14.err" >&2
    failures=$((failures + 1))
fi
fi
clear_runtime

# V15/V16. The reverse direction for both new arms: PRESENT but UNSAFE must
#          still fail loudly.  Without these, "call every read failure gone"
#          would pass V13/V14 -- the fail-open shape this project has fixed
#          repeatedly.
mkdir -p "$work/data/agentq-requests/.tombstones/AQREAD-VTOMBAD-0001.json"
run_case v15 lookup AQREAD-VTOMBAD-0001
assert_rc v15 2
assert_err_has v15 'invalid AgentQ request tombstone path'
assert_reason v15
rmdir "$work/data/agentq-requests/.tombstones/AQREAD-VTOMBAD-0001.json"
mkdir -p "$work/data/agentq-cancellations/1001.json"
put_record AQREAD-VMARKBAD-00001 removed 1001 '"2026-09-29T00:00:00Z"'
run_case v16 status
assert_rc v16 2
assert_err_has v16 'invalid AgentQ cancellation marker path'
assert_reason v16
rmdir "$work/data/agentq-cancellations/1001.json"
clear_runtime

# V17. The marker validator's OWN guard-to-read gap.  read_cancellation_marker
#      and cancellation_marker_is_valid each read the file; fixing only the
#      first leaves the second printing bash's redirection error (measured:
#      `status` exited 0 with `<path>: No such file or directory` on stderr,
#      which the clients scan for `reason=`).  The injection goes between the
#      second guard and the read inside the VALIDATOR.
clear_runtime
mkdir -p "$work/data/agentq-cancellations"
printf '{"version":1,"task_id":1001,"task_created_at":"2026-09-29T00:00:00Z","state":"requested","requested_at":"2026-09-29T00:00:00Z","created_at":"2026-09-29T00:00:00Z","reason":"smoke"}\n' \
    > "$work/data/agentq-cancellations/1001.json"
cases=$((cases + 1))
if ! python3 - "$work/agentq-server" "$work/agentq-server-forced9" <<'PYV17'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
anchor = '    marker_read_status=0\n    marker_body=$(cat -- "$marker_path" 2>/dev/null)'
if s.count(anchor) != 1:
    sys.stderr.write('fixture: expected 1 validation read site, found %d\n' % s.count(anchor))
    sys.exit(3)
s = s.replace(anchor, '    rm -f "$marker_path"  # SMOKE: forced vanish\n' + anchor, 1)
open(dst, 'w').write(s)
PYV17
then
    printf 'read-paths v17: could not inject the forced vanish (see fixture message above)\n' >&2
    failures=$((failures + 1))
fi
if [ -f "$work/agentq-server-forced9" ]; then
chmod 700 "$work/agentq-server-forced9"
run_forced9() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server-forced9" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_forced9 v17 status
assert_rc v17 0
cases=$((cases + 1))
if [ -s "$work/v17.err" ]; then
    printf 'read-paths v17: the marker validator leaked text on a vanished file\n' >&2
    sed -n '1,3p' "$work/v17.err" >&2
    failures=$((failures + 1))
fi
fi
clear_runtime

# V18. The precision probe is the one reader that only runs on a LOW-PRECISION
#      jq (jq <= 1.6 returns early on anything newer), so this case forces that
#      branch and then vanishes the file between the guard and the `grep`.
#      Without the change, `grep` prints `<path>: No such file or directory` on
#      a call that otherwise succeeds -- measured on a copy, stderr carried that
#      line while `status` exited 0.
mkdir -p "$work/data/agentq-cancellations"
printf '{"version":1,"task_id":1001,"task_created_at":"2026-09-29T00:00:00Z","state":"requested","requested_at":"2026-09-29T00:00:00Z","created_at":"2026-09-29T00:00:00Z","reason":"smoke"}\n' \
    > "$work/data/agentq-cancellations/1001.json"
cases=$((cases + 1))
if ! python3 - "$work/agentq-server" "$work/agentq-server-forced10" <<'PYV18'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
lowp = 'jq_preserves_integer_digits() {'
if s.count(lowp) != 1:
    sys.stderr.write('fixture: jq_preserves_integer_digits is not defined\n')
    sys.exit(3)
s = s.replace(lowp, lowp + '\n    return 1  # SMOKE: pretend jq 1.6', 1)
needle = ('        fail "invalid AgentQ cancellation marker path: $marker_path"\n'
          '    }\n'
          '    validate_task_id_precision_in_file "$marker_path"')
if s.count(needle) != 1:
    sys.stderr.write('fixture: expected 1 marker precision-probe site, found %d\n' % s.count(needle))
    sys.exit(3)
s = s.replace(needle, needle.replace(
    '    validate_task_id_precision_in_file "$marker_path"',
    '    rm -f "$marker_path"  # SMOKE: forced vanish\n'
    '    validate_task_id_precision_in_file "$marker_path"'), 1)
open(dst, 'w').write(s)
PYV18
then
    printf 'read-paths v18: could not inject the forced vanish (see fixture message above)\n' >&2
    failures=$((failures + 1))
fi
if [ -f "$work/agentq-server-forced10" ]; then
chmod 700 "$work/agentq-server-forced10"
run_forced10() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server-forced10" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_forced10 v18 status
assert_rc v18 0
cases=$((cases + 1))
if [ -s "$work/v18.err" ]; then
    printf 'read-paths v18: the precision probe leaked grep text on a vanished file\n' >&2
    sed -n '1,3p' "$work/v18.err" >&2
    failures=$((failures + 1))
fi
fi
clear_runtime

# V19. The last reader with the same shape, and the only one that needs a
#      FALLBACK to reach: task_instance_created_at_is_recorded scans records in
#      a fast aggregate path and falls back to a per-file loop.  The fallback
#      read was `... < "$path" 2>/dev/null`, which LOOKS suppressed but is not:
#      a redirection error is the shell's own write and happens before the
#      redirect applies (measured 2026-10-23: bash printed the path anyway).
#      A malformed TOMBSTONE forces the fast path to fail without touching the
#      record scan, so the fallback is the code that runs.
#
#      The verdict is unchanged between versions (`unknown AgentQ task id`/2);
#      what differs is the noise on stderr, which the clients scan for
#      `reason=`.  A/B measured: 0.1.18 emits `bash: <path>: No such file or
#      directory`, the fixed tree emits nothing.
clear_runtime
put_record AQREAD-VSCAN-00000001 accepted 1001 '"2026-09-29T00:00:00Z"'
printf '{ not json\n' > "$work/data/agentq-requests/.tombstones/AQREAD-VPOISON-01.json"
printf '{"version":1,"task_id":1001,"task_created_at":"2026-09-29T00:00:00Z","state":"requested","requested_at":"2026-09-29T00:00:00Z","created_at":"2026-09-29T00:00:00Z","reason":"smoke"}\n' \
    > "$work/data/agentq-cancellations/1001.json"
cases=$((cases + 1))
if ! python3 - "$work/agentq-server" "$work/agentq-server-forced11" <<'PYV19'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
start = s.index('task_instance_created_at_is_recorded() {')
end = s.index('\n}\n', start)
body = s[start:end]
# Anchored on the READ ITSELF in either shape: the silent-cat form or the
# pre-fix `created_at=$(jq ... < "$path"` form.  A fixture that only fits the
# fixed shape reports a fixture miss against the old code instead of a verdict.
needle = '            file_body=$(cat -- "$path" 2>/dev/null) || continue'
if body.count(needle) != 2:
    needle = '            created_at=$(jq -r --argjson id "$task_id" \\'
if body.count(needle) != 2:
    sys.stderr.write('fixture: fallback read shape not recognised (%d)\n' % body.count(needle))
    sys.exit(3)
s = s[:start] + body.replace(needle, '            rm -f "$path"  # SMOKE: forced vanish\n' + needle, 1) + s[end:]
open(dst, 'w').write(s)
PYV19
then
    printf 'read-paths v19: could not inject the forced vanish (see fixture message above)\n' >&2
    failures=$((failures + 1))
fi
if [ -f "$work/agentq-server-forced11" ]; then
chmod 700 "$work/agentq-server-forced11"
run_forced11() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server-forced11" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_forced11 v19 cancel 1001
assert_rc v19 2
assert_err_has v19 'unknown AgentQ task id'
cases=$((cases + 1))
if grep -qF 'No such file or directory' "$work/v19.err"; then
    printf 'read-paths v19: a vanished record left bash noise on stderr\n' >&2
    sed -n '1,3p' "$work/v19.err" >&2
    failures=$((failures + 1))
fi
fi
clear_runtime

# V20. load_request_records' own read, the FIRST site fixed (0.1.18) and the
#      one whose `null` placeholder already had coverage -- but only for the
#      GUARD half.  The read itself was still `record=$(<"$record_path")`,
#      whose bash redirection error is written to the top-level stderr even
#      though the substitution fails "correctly" and the vanish arm then skips
#      the record.  Measured 2026-10-23: `status` exit 0, record correctly
#      skipped, and `<path>: No such file or directory` on stderr -- which the
#      clients scan for `reason=`.
clear_runtime
put_record AQREAD-VREC-000000001 accepted 1001 '"2026-09-29T00:00:00Z"'
cases=$((cases + 1))
if ! python3 - "$work/agentq-server" "$work/agentq-server-forced12" <<'PYV20'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
start = s.index('load_request_records() {')
end = s.index('\n}\n', start)
body = s[start:end]
# Either shape: the silent-cat read or the pre-fix $(<...) read.
needle = '        record=$(cat -- "$record_path" 2>/dev/null) || {'
if body.count(needle) != 1:
    needle = '        record=$(<"$record_path") || {'
if body.count(needle) != 1:
    sys.stderr.write('fixture: record read shape not recognised (%d)\n' % body.count(needle))
    sys.exit(3)
s = s[:start] + body.replace(
    needle, '        rm -f "$record_path"  # SMOKE: forced vanish\n' + needle, 1) + s[end:]
open(dst, 'w').write(s)
PYV20
then
    printf 'read-paths v20: could not inject the forced vanish (see fixture message above)\n' >&2
    failures=$((failures + 1))
fi
if [ -f "$work/agentq-server-forced12" ]; then
chmod 700 "$work/agentq-server-forced12"
run_forced12() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server-forced12" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_forced12 v20 status
assert_rc v20 0
cases=$((cases + 1))
if grep -qF 'No such file or directory' "$work/v20.err"; then
    printf 'read-paths v20: the record load leaked bash noise on stderr\n' >&2
    sed -n '1,3p' "$work/v20.err" >&2
    failures=$((failures + 1))
fi
fi
clear_runtime

# V21. The non-UTF-8 log branch of compact_log.  `logs` is NOT a request-record
#      reader, but it is one of the few places that opens a file by its own path
#      and hands it to another process.  Two defects lived there:
#        * `base64 < "$log_path"` -- a redirection, so a vanished log printed
#          bash's own message (the clients scan stderr for `reason=`);
#        * `tail ... | base64` -- under `set -o pipefail` the pipeline failed and
#          the ONLY message was `cannot encode non-UTF-8 task log`, a wrong cause
#          for a file that was simply gone.
#      A/B measured (0.1.18 and the pre-change tree both): exit 2, `tail: <path>:
#      No such file or directory` on stderr, then the encode message.  The
#      branch now captures base64's status, tells "gone" from "encode failed",
#      and emits exactly one controlled message.
clear_runtime
printf '\xff\xfe binary\n' > "$work/data/task_logs/1.log"
cases=$((cases + 1))
if ! python3 - "$work/agentq-server" "$work/agentq-server-forced13" <<'PYV21'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# STRUCTURAL anchor: the branch that turns the raw log into base64, in either
# shape -- the fixed `log_encoded=$(tail ...)` or the pre-fix
# `tail ... "$log_path" | base64`.  Anchoring on the fix's own variable name
# made the case un-injectable against the old code, which reports a FIXTURE
# miss instead of a wrong verdict (the same trap V10 and V14 hit).
anchor = '            log_encoded=$(tail -n "$tail_lines" "$log_path"'
if s.count(anchor) != 1:
    anchor = '                tail -n "$tail_lines" "$log_path" | base64'
if s.count(anchor) != 1:
    sys.stderr.write('fixture: log-encode site not recognised (%d)\n' % s.count(anchor))
    sys.exit(3)
indent = anchor[:len(anchor) - len(anchor.lstrip())]
s = s.replace(anchor, indent + 'rm -f "$log_path"  # SMOKE: forced vanish\n' + anchor, 1)
open(dst, 'w').write(s)
PYV21
then
    printf 'read-paths v21: could not inject the forced vanish (see fixture message above)\n' >&2
    failures=$((failures + 1))
fi
if [ -f "$work/agentq-server-forced13" ]; then
chmod 700 "$work/agentq-server-forced13"
cat > "$work/pueue.binary" <<'SH'
#!/bin/sh
case "$*" in
  *"status --json"*) printf '%s\n' '{"tasks":{"1":{"id":1,"group":"agentq","label":"agentq:AQREAD-VLOG-0000001","created_at":"2026-09-29T00:00:00Z","status":{"Done":{"result":"Success","start":"2026-09-29T00:00:00Z","end":"2026-09-29T00:00:01Z"},"enqueued_at":"2026-09-29T00:00:00Z"}}},"groups":{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}}' ;;
  *"group --json"*) printf '%s\n' '{"agentq":{"status":"Running","parallel_tasks":1},"default":{"status":"Running","parallel_tasks":1}}' ;;
  *"log --json"*) printf '%s\n' '{"1":{"task":{"id":1,"created_at":"2026-09-29T00:00:00Z"},"output":"(Pueue error) Failed to read local log output file: stream did not contain valid UTF-8"}}' ;;
  *) printf '%s 4.0.4\n' pueue ;;
esac
SH
chmod 700 "$work/pueue.binary"
mv "$work/pueue" "$work/pueue.plain"
cp "$work/pueue.binary" "$work/pueue"
run_forced13() {
    local label=$1
    shift
    local rc=0
    ( cd "$work" && "$work/agentq-server-forced13" "$@" ) \
        >"$work/$label.out" 2>"$work/$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$label.rc"
}
run_forced13 v21 logs 1
mv "$work/pueue.plain" "$work/pueue"
assert_rc v21 2
assert_err_has v21 'the task log disappeared while it was being read'
# `reason=`, not assert_reason: the mutant runs as agentq-server-forced13, and
# the server derives the message prefix from $0, so the machine line reads
# `agentq-server-forced13: reason=protocol_error`.  V6/V8 hit the same shape.
assert_err_has v21 'reason=protocol_error'
cases=$((cases + 1))
if grep -qF 'No such file or directory' "$work/v21.err"; then
    printf 'read-paths v21: the log read leaked the tool own path error\n' >&2
    sed -n '1,3p' "$work/v21.err" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if grep -qF 'cannot encode non-UTF-8' "$work/v21.err"; then
    printf 'read-paths v21: a vanished log was blamed on encoding\n' >&2
    sed -n '1,3p' "$work/v21.err" >&2
    failures=$((failures + 1))
fi
fi
find "$work/data/task_logs" -maxdepth 1 -name '*.log' -delete
clear_runtime

# --------------------------------------------------------------- summary
if [ "$failures" -ne 0 ]; then
    printf 'read-paths checks FAILED: cases=%s failures=%s\n' "$cases" "$failures" >&2
    exit 1
fi
printf 'read-paths checks passed: cases=%s reason-gaps=%s\n' "$cases" "$reason_gaps"
