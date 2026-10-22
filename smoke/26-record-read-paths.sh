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
#     that widened `request_record_vanished` to "unreadable" fails here.)
clear_runtime
ln -s /nonexistent/agentq-vanish-target \
    "$work/data/agentq-requests/AQREAD-VDANGLE-0000001.json"
run_case v2 status
assert_rc v2 2
assert_err_has v2 'invalid AgentQ request record path'
assert_reason v2
find "$work/data/agentq-requests" -maxdepth 1 -name '*.json' -type l -delete

# V3. The source of the vanish arm is visible in the asset: the checks exist at
#     both readers that can race an archiver -- load_request_records (3 sites:
#     guard, guard, read) and the shared request_record_path_guards_or_fail
#     used by the repair pass (2 sites).  A copy on a SUCCESS path would restore
#     the 4-guard cost that loop was trimmed for, so the count is also the
#     shape.
cases=$((cases + 1))
vanish_sites=$(grep -c 'request_record_vanished ' "$work/agentq-server" || true)
if [ "$vanish_sites" != 5 ]; then
    printf 'read-paths v3: expected 5 request_record_vanished sites, got %s\n' \
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

# --------------------------------------------------------------- summary
if [ "$failures" -ne 0 ]; then
    printf 'read-paths checks FAILED: cases=%s failures=%s\n' "$cases" "$failures" >&2
    exit 1
fi
printf 'read-paths checks passed: cases=%s reason-gaps=%s\n' "$cases" "$reason_gaps"
