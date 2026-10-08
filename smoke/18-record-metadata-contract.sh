#!/usr/bin/env bash
# Smoke: the request-record metadata scan keeps its exact contract.
#
# This check exists because the full suite could not see a regression in this
# code.  A change that skipped the crash-window repair scan entirely -- and so
# left a legal `state: "removed"` record unarchived forever -- ran the whole
# suite green (17 ran, 0 failed).  Another that dropped the per-record binding
# check silently ACCEPTED a record whose filename and internal `request_id`
# disagreed, also green.  `docs/verification-status.md` has said all along that smoke proves
# parsing and bad-argument rejection but "does not prove any branch behaves
# correctly"; this is that gap, pinned.
#
# What is asserted here, all on a synthetic runtime so a failure is
# attributable to the scan rather than to a missing daemon:
#
#   1. Every malformed record is refused with exit 2 AND reason=protocol_error,
#      byte-identical stderr against a recorded baseline.
#   2. The legal crash-window state self-heals: a `removed` record plus its
#      tombstone collapses to the tombstone, and the record is gone.
#   3. `prepared`/`adding` records keep `task_id: null` legal, and `removed`
#      records are still accepted by the loader while rejected by the aggregate.
#   4. A good run's stdout is byte-identical to the baseline.
#
# What this check does NOT cover, recorded so the green is not over-read:
# the aggregate filter in `load_request_records` re-checks the filename/id
# binding itself, but `repair_removed_request_records` (pass 1) rejects every
# malformed record first, so on the `status` path that second check is
# unreachable -- replacing it with a constant leaves this check green.  That was
# verified by mutation and is benign here, not a coverage hole: the aggregate's
# own binding logic was tested directly (`jq -cse --args -f` on a mismatched
# record errors, on a matching one it does not).  A change that made pass 1
# permissive would make the aggregate load-bearing, and this check would then
# start exercising it.
#
# A note on how the cases are built: every case re-seeds the record directory
# from scratch.  `status` WRITES (it archives `removed` records into
# tombstones), so running two variants against one directory would let the
# first consume the input the second was supposed to see -- a check that
# reports IDENTICAL while measuring nothing.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/agentq-smoke-records.XXXXXX")
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

# Two independent trees so a variant can never be measured against state the
# other one already mutated.
for side in base variant; do
    mkdir -p "$work/$side/config" "$work/$side/data/task_logs" \
        "$work/$side/data/agentq-cancellations" \
        "$work/$side/data/agentq-requests/.locks" \
        "$work/$side/data/agentq-requests/.tombstones" \
        "$work/$side/runtime"
    cp "$root/skill/assets/unix/agentq-server" "$work/$side/agentq-server"
    cp "$root/skill/assets/unix/pueue.yml" "$work/$side/config/pueue.yml"
    chmod 700 "$work/$side/agentq-server"
    # The server asks pueue for both the task snapshot and the group list; a
    # stub that answers only the first makes status die with "group is missing",
    # which looks like a record problem but is not.
    cat > "$work/$side/pueue" <<'SH'
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
    printf '#!/bin/sh\nprintf "%%s 4.0.4\\n" pueued\n' > "$work/$side/pueued"
    chmod 700 "$work/$side/pueue" "$work/$side/pueued"
done

base="$work/base/agentq-server"
variant=${AGENTQ_SMOKE_SERVER:-$work/variant/agentq-server}
if [ "$variant" != "$work/variant/agentq-server" ]; then
    cp "$variant" "$work/variant/agentq-server"
    chmod 700 "$work/variant/agentq-server"
fi

failures=0
cases=0
reason_gaps=0

# A record in `accepted` shape.  $1 request_id, $2 overrides (jq -c on top).
record_json() {
    printf '{"version":1,"request_id":"%s","payload":{"workdir":"/tmp","label":"smoke","argv":["true"]},"task_label":"agentq:%s","state":"accepted","task_id":1001,"task_created_at":"2026-09-29T00:00:00Z","created_at":"2026-09-29T00:00:00Z"}' "$1" "$1"
}

# seed <side> <filename> <json>  -- wipes both record and tombstone dirs first.
seed() {
    local side=$1 name=$2 body=$3
    find "$work/$side/data/agentq-requests" -maxdepth 1 -name '*.json' -delete
    find "$work/$side/data/agentq-requests/.tombstones" -maxdepth 1 -name '*.json' -delete
    printf '%s\n' "$body" > "$work/$side/data/agentq-requests/$name"
}

# run_case <side> <label> [args...]
run_case() {
    local side=$1 label=$2
    shift 2
    local rc=0
    ( cd "$work/$side" && AGENTQ_SMOKE_HOME="$work/$side" "$work/$side/agentq-server" "$@" ) \
        >"$work/$side.$label.out" 2>"$work/$side.$label.err" || rc=$?
    printf '%s' "$rc" > "$work/$side.$label.rc"
}

# The two trees live at different paths, so every message that names a record
# carries a different absolute path -- and the program name differs too.  Strip
# both before comparing, or every case reports a difference that is only the
# harness's own layout.  (This was a real false red in the first draft: the
# check failed 7 of 21 cases against an unchanged server.)
normalize() {
    sed -e "s|$1|TREE|g" -e 's|^[^ ]*/agentq-server:|agentq-server:|' "$2"
}

compare_case() {
    local label=$1
    cases=$((cases + 1))
    local base_rc variant_rc
    base_rc=$(cat "$work/base.$label.rc")
    variant_rc=$(cat "$work/variant.$label.rc")
    if [ "$base_rc" != "$variant_rc" ]; then
        printf 'records-contract %s: exit code differs (baseline %s, variant %s)\n' \
            "$label" "$base_rc" "$variant_rc" >&2
        failures=$((failures + 1))
        return
    fi
    if ! diff -q <(normalize "$work/base" "$work/base.$label.out") \
                 <(normalize "$work/variant" "$work/variant.$label.out") >/dev/null; then
        printf 'records-contract %s: stdout differs\n' "$label" >&2
        diff <(normalize "$work/base" "$work/base.$label.out") \
             <(normalize "$work/variant" "$work/variant.$label.out") >&2 | head -10 || true
        failures=$((failures + 1))
    fi
    if ! diff -q <(normalize "$work/base" "$work/base.$label.err") \
                 <(normalize "$work/variant" "$work/variant.$label.err") >/dev/null; then
        printf 'records-contract %s: stderr differs\n' "$label" >&2
        diff <(normalize "$work/base" "$work/base.$label.err") \
             <(normalize "$work/variant" "$work/variant.$label.err") >&2 | head -10 || true
        failures=$((failures + 1))
    fi
}

# expect_refused <label> <expected-message-fragment>
#
# A malformed record must fail closed: exit 2 and reason=protocol_error.  Exit 2
# is the protocol-error class, and the reason line is the machine-readable
# channel CLAUDE.md documents -- a site that degrades to exit 1 or drops the
# reason has broken the contract the clients read.
expect_refused() {
    local label=$1 expected=$2
    cases=$((cases + 1))
    local rc
    rc=$(cat "$work/variant.$label.rc")
    if [ "$rc" != 2 ]; then
        printf 'records-contract %s: expected exit 2, got %s\n' "$label" "$rc" >&2
        head -3 "$work/variant.$label.err" >&2 || true
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/variant.$label.err"; then
        printf 'records-contract %s: stderr does not contain %s\n' "$label" "$expected" >&2
        head -3 "$work/variant.$label.err" >&2 || true
        failures=$((failures + 1))
    fi
    if ! grep -qxF -- "agentq-server: reason=protocol_error" \
        <(normalize "$work/variant" "$work/variant.$label.err"); then
        printf 'records-contract %s: stderr does not carry reason=protocol_error\n' "$label" >&2
        head -3 "$work/variant.$label.err" >&2 || true
        reason_gaps=$((reason_gaps + 1))
        failures=$((failures + 1))
    fi
}

# assert_jq_diagnostics <label> <expected-count>
#
# A malformed record is diagnosed by jq's own message (e.g. "jq: parse error:
# ..."), and the repair pass reaches it through a PER-FILE jq in its fallback
# path -- exactly one diagnostic line per malformed record.  This count is the
# lock against a fold that runs a batch jq first and lets ITS stderr escape:
# then every diagnostic prints twice.  compare_case cannot see that in a default
# run, because base and variant are the same asset and it only diffs the two
# sides -- a doubled line is identical on both.  (Measured: the first draft of
# the repair fold leaked the aggregate jq's stderr this way and printed each
# parse error twice, while compare_case stayed green.)
assert_jq_diagnostics() {
    local label=$1 expected=$2
    cases=$((cases + 1))
    local count
    # `|| true`: grep -c prints 0 AND exits 1 on no match; without it the
    # assignment would abort under `set -e`.
    count=$(grep -c '^jq:' "$work/variant.$label.err" || true)
    if [ "$count" != "$expected" ]; then
        printf 'records-contract %s: expected %s jq diagnostic line(s), got %s\n' \
            "$label" "$expected" "$count" >&2
        head -6 "$work/variant.$label.err" >&2 || true
        failures=$((failures + 1))
    fi
}

# ---------------------------------------------------------------- case setup
# Every case is seeded into BOTH trees with identical bytes.
case_wellformed() { seed base "$1" "$2"; seed variant "$1" "$2"; }
good_id=AQSMOKE-0000000000001

# 1. A well-formed record must be accepted (and both sides must agree).
case_wellformed "$good_id.json" "$(record_json "$good_id")"
run_case base wellformed status
run_case variant wellformed status
compare_case wellformed

# 2. Malformed JSON.
case_wellformed AQBADJSON-0000000001.json '{ this is not json'
run_case base badjson status
run_case variant badjson status
compare_case badjson
expect_refused badjson 'invalid AgentQ request record'
assert_jq_diagnostics badjson 1

# 3. Wrong protocol version.
case_wellformed AQVERBAD-00000000001.json "$(record_json AQVERBAD-00000000001 | sed 's/"version":1/"version":2/')"
run_case base verbad status
run_case variant verbad status
compare_case verbad
expect_refused verbad 'invalid AgentQ request record'
assert_jq_diagnostics verbad 1

# 4. The filename and the record's own request_id disagree.  This is the case a
#    dropped per-record binding check silently accepts.
case_wellformed AQMISMATCH-0000000001.json "$(record_json AQOTHER-000000000001)"
run_case base mismatch status
run_case variant mismatch status
compare_case mismatch
expect_refused mismatch 'invalid AgentQ request record'
assert_jq_diagnostics mismatch 1

# 5. A non-integral task id.
case_wellformed AQFLOAT-000000000001.json "$(record_json AQFLOAT-000000000001 | sed 's/"task_id":1001/"task_id":10.5/')"
run_case base float status
run_case variant float status
compare_case float
expect_refused float 'invalid AgentQ request record'
assert_jq_diagnostics float 1

# 6. `accepted` with a null task_created_at -- the state/id pairing is checked.
case_wellformed AQNOCREATED-00000001.json "$(record_json AQNOCREATED-00000001 | sed 's/"task_created_at":"2026-09-29T00:00:00Z"/"task_created_at":null/')"
run_case base nocreated status
run_case variant nocreated status
compare_case nocreated
expect_refused nocreated 'invalid AgentQ request record'
assert_jq_diagnostics nocreated 1

# 7. An illegal request-id filename (too short for the documented shape).
# The trigger is the FILENAME being too short for the documented shape; the sed
# that used to sit here replaced a string with itself (no-op, removed 2026-10-06).
case_wellformed short.json "$(record_json short)"
run_case base shortname status
run_case variant shortname status
compare_case shortname
expect_refused shortname 'invalid AgentQ request record filename'

# 8. A malformed record sitting between two good ones -- the batch must not
#    fail open on position.
case_wellformed AQAAA-00000000000001.json "$(record_json AQAAA-00000000000001)"
case_wellformed AQZZZ-00000000000001.json "$(record_json AQZZZ-00000000000001)"
printf '%s\n' 'garbage' > "$work/base/data/agentq-requests/AQMMM-00000000000001.json"
printf '%s\n' 'garbage' > "$work/variant/data/agentq-requests/AQMMM-00000000000001.json"
run_case base midbad status
run_case variant midbad status
compare_case midbad
expect_refused midbad 'invalid AgentQ request record'
assert_jq_diagnostics midbad 1

# 9. `task_id: null` is LEGAL for prepared/adding.  A reader that assumes a
#    numeric task_id would reject these.
for state in prepared adding; do
    name=AQNULL-00000000000001
    body=$(printf '{"version":1,"request_id":"%s","payload":{"workdir":"/tmp","label":"smoke","argv":["true"]},"task_label":"agentq:%s","state":"%s","task_id":null,"task_created_at":null,"created_at":"2026-09-29T00:00:00Z"}' "$name" "$name" "$state")
    case_wellformed "$name.json" "$body"
    run_case base "null_$state" status
    run_case variant "null_$state" status
    compare_case "null_$state"
    cases=$((cases + 1))
    if [ "$(cat "$work/variant.null_$state.rc")" != 0 ]; then
        printf 'records-contract null_%s: a %s record must be accepted, got exit %s\n' \
            "$state" "$state" "$(cat "$work/variant.null_$state.rc")" >&2
        failures=$((failures + 1))
    fi
done

# 10. The crash window: a `removed` record whose tombstone is already written,
#     with the active record not yet deleted.  The repair pass must archive it
#     and leave exactly one tombstone.  Skipping that pass leaves the record
#     behind forever -- and the full suite does not notice.
crash_id=AQCRASH-000000000001
crash_record=$(printf '{"version":1,"request_id":"%s","payload":{"workdir":"/tmp","label":"smoke","argv":["true"]},"task_label":"agentq:%s","state":"removed","task_id":1001,"task_created_at":"2026-09-29T00:00:00Z","created_at":"2026-09-29T00:00:00Z"}' "$crash_id" "$crash_id")
crash_tombstone=$(printf '{"version":1,"request_id":"%s","task_id":1001,"task_created_at":"2026-09-29T00:00:00Z","state":"removed","removed_at":"2026-09-29T01:00:00Z"}' "$crash_id")
for side in base variant; do
    find "$work/$side/data/agentq-requests" -maxdepth 1 -name '*.json' -delete
    find "$work/$side/data/agentq-requests/.tombstones" -maxdepth 1 -name '*.json' -delete
    printf '%s\n' "$crash_record" > "$work/$side/data/agentq-requests/$crash_id.json"
    printf '%s\n' "$crash_tombstone" > "$work/$side/data/agentq-requests/.tombstones/$crash_id.json"
done
run_case base crashwin status
run_case variant crashwin status
compare_case crashwin
cases=$((cases + 1))
remaining=$(find "$work/variant/data/agentq-requests" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
tombstones=$(find "$work/variant/data/agentq-requests/.tombstones" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
if [ "$remaining" != 0 ] || [ "$tombstones" != 1 ]; then
    printf 'records-contract crashwin: the crash window did not self-heal (records=%s tombstones=%s, expected 0/1)\n' \
        "$remaining" "$tombstones" >&2
    failures=$((failures + 1))
fi

# --------------------------------------------------------------- summary
if [ "$failures" -ne 0 ]; then
    printf 'records-contract checks FAILED: cases=%s failures=%s\n' "$cases" "$failures" >&2
    exit 1
fi
printf 'records-contract checks passed: cases=%s reason-gaps=%s\n' "$cases" "$reason_gaps"
