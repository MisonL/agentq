#!/usr/bin/env bash
# Smoke: the server rejects bad invocations with the documented exit codes and
# the documented message.  Exit code alone is not enough here: this check runs
# against a synthetic runtime assembled on the spot, so a "2" really means the
# argument was rejected rather than that startup failed for an unrelated
# reason.  Each case asserts the message too, so the failure is attributable.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/agentq-smoke-error.XXXXXX")
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

# Minimal runtime layout the server insists on before it will parse arguments.
mkdir -p "$work/config" "$work/data/task_logs" "$work/data/agentq-cancellations" \
    "$work/data/agentq-requests/.locks" "$work/data/agentq-requests/.tombstones" \
    "$work/runtime"
# AGENTQ_SMOKE_SERVER selects the server under test (same hook as smoke/18) so
# the static rules below can be mutation-proven against a modified copy.
cp "${AGENTQ_SMOKE_SERVER:-$root/skill/assets/unix/agentq-server}" "$work/agentq-server"
cp "$root/skill/assets/unix/pueue.yml" "$work/config/pueue.yml"
for stub in pueue pueued; do
    printf '#!/bin/sh\nprintf "%%s 4.0.4\\n" "%s"\n' "$stub" > "$work/$stub"
    chmod 700 "$work/$stub"
done

server="$work/agentq-server"
failures=0
cases=0

# expect_rejected <label> <expected-message-fragment> <expected-reason> [args...]
#
# The third argument is the machine-readable failure class the server must print
# as `reason=<class>`.  Exit code 2 covers three unrelated situations (argument
# errors, lock contention, cancelling a finished task) and used to be
# distinguishable only by matching the human-readable message; the reason line
# is the reliable channel.  Asserting it here means a site that loses its reason
# -- or one that acquires the wrong class -- fails this check.
expect_rejected() {
    local label=$1 expected=$2 reason=$3
    shift 3
    local actual=0
    cases=$((cases + 1))
    "$server" "$@" >"$work/$label.stdout" 2>"$work/$label.stderr" || actual=$?
    if [ "$actual" -ne 2 ]; then
        printf '%s: expected exit 2, got %s\n' "$label" "$actual" >&2
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/$label.stderr"; then
        printf '%s: stderr does not contain %s\n' "$label" "$expected" >&2
        head -3 "$work/$label.stderr" >&2 || true
        failures=$((failures + 1))
    fi
    if ! grep -qxF -- "agentq-server: reason=$reason" "$work/$label.stderr"; then
        printf '%s: stderr does not carry reason=%s\n' "$label" "$reason" >&2
        head -3 "$work/$label.stderr" >&2 || true
        failures=$((failures + 1))
    fi
}

expect_rejected no-args 'Usage:' protocol_error
expect_rejected unknown-command 'unknown command: definitely-not-a-command' protocol_error definitely-not-a-command
expect_rejected submit-no-request-id '--request-id must be' protocol_error submit --workdir "$work" -- true
expect_rejected lookup-short-id 'request id must be' protocol_error lookup abc
expect_rejected wait-non-numeric 'task id must be a non-negative integer' protocol_error wait abc
expect_rejected logs-no-task 'logs requires one task id' protocol_error logs
expect_rejected cancel-no-task 'cancel requires one task id' protocol_error cancel
expect_rejected remove-no-task 'remove requires one task id' protocol_error remove
expect_rejected status-extra-arg 'status accepts no arguments' protocol_error status extra

# A malformed Pueue status must NOT surface as exit 5.  The contract reserves 5
# for a REMOVED task; but compact_status's jq filter ends in
# error("invalid visible Pueue task metadata"), and jq exits 5 on error() -- so
# before 2026-10-12 `status`/`doctor` exited 5 with no body and no reason line,
# and a caller reading 5 as "removed" was misled.  This drives status against a
# stub whose `status --json` returns a task MISSING `created_at` (a shape
# validate_pueue_task_shape_in_file does not check -- it only validates id
# precision), so the error() fires for real.  Every other compactor (logs, wait,
# cancel, remove) folds this through report_compact_task_failure.
bad_status_run() {
    local op=$1
    cases=$((cases + 1))
    local status_rc=0
    # The server resolves pueue as "$agentq_root/pueue" (its own directory),
    # NOT via PATH -- so swap $work/pueue itself, then restore it.
    cp "$work/pueue" "$work/pueue.real"
    cat > "$work/pueue" <<'STUB'
#!/bin/sh
# `status --json` returns a group with one task that has an id but no
# created_at; `group --json` reports the agentq group so verify_group passes.
case "$*" in
    *"group --json"*) printf '{"agentq":{"parallel_tasks":1}}\n' ;;
    *"status --json"*)
        printf '{"tasks":{"7":{"id":7,"group":"agentq"}},"groups":{"agentq":{"parallel_tasks":1}}}\n'
        ;;
    *) printf 'pueue 4.0.4\n' ;;
esac
STUB
    chmod 700 "$work/pueue"
    "$server" "$op" >"$work/bad.$op.out" 2>"$work/bad.$op.err" || status_rc=$?
    mv "$work/pueue.real" "$work/pueue"
    if [ "$status_rc" -ne 2 ]; then
        printf 'a malformed Pueue status made `%s` exit %s; the contract reserves 5 for a removed task and requires 2 (protocol_error) for an unreadable status\n' \
            "$op" "$status_rc" >&2
        head -3 "$work/bad.$op.err" >&2 || true
        failures=$((failures + 1))
        return
    fi
    if ! grep -q 'reason=protocol_error' "$work/bad.$op.err"; then
        printf 'a malformed Pueue status made `%s` exit 2 without reason=protocol_error\n' "$op" >&2
        head -3 "$work/bad.$op.err" >&2 || true
        failures=$((failures + 1))
    fi
}
bad_status_run status
bad_status_run doctor

# `cancel` on a finished task (`reason=task_not_running`) is deliberately NOT
# asserted here: it needs a real Pueue task that has actually completed, and
# this check's runtime is a stub.  It is covered in 03, which runs against the
# real runtime -- asserting it against the stub would only prove that a broken
# stub still produces exit 2.

# The usage text is the machine-readable command surface.  It must list exactly
# the commands SKILL.md and CLAUDE.md document -- no more, no fewer -- so a
# command cannot be added or dropped without the documentation following.
documented_commands='submit lookup status logs cancel wait remove doctor'
"$server" >"$work/usage.stdout" 2>"$work/usage.stderr" || true
actual_commands=$(
    sed -n 's/^  [^ ][^ ]* \([a-z][a-z]*\).*/\1/p' "$work/usage.stderr" \
        | sort -u | tr '\n' ' ' | sed 's/ $//'
)
expected_commands=$(printf '%s\n' $documented_commands | sort -u | tr '\n' ' ' | sed 's/ $//')
if [ "$actual_commands" != "$expected_commands" ]; then
    printf 'command surface drift:\n  documented: %s\n  usage:      %s\n' \
        "$expected_commands" "$actual_commands" >&2
    failures=$((failures + 1))
fi

# Static companion to the runtime cases above: every exit-2 site that prints a
# message must also print a reason line.  The runtime cases only reach the
# dispatcher's argument paths; the Windows-only paths (MSYSTEM missing, jq
# missing, profile metadata incomplete, cygpath failure, empty home path) are
# unreachable on this host and are exactly the ones that had lost their reason
# line -- a caller following the documented rule ("read reason, never match
# message text") got nothing there, and would read the silence as a client-side
# regression.
#
# The rule is structural, not a fixed line window: a printf writing to stderr
# that does not itself carry `reason=` and whose next statement is `exit 2`.
# Windows in either direction are wrong -- a narrow one misses a re-check a few
# lines later, a wide one matches the next function (both mistakes were made in
# smoke/10's rule G).  Blank lines and comments between the two are tolerated.
# `fail()` is excluded: it emits reason= from the one place that owns it.
# Continuation lines are JOINED before the test.  Without that, a message split
# as `printf '...' \\` / `"$program" >&2` never satisfies the `>&2` test and the
# site is invisible -- the same shape the rule exists to catch, just wrapped.
#
# Why the rule matches literal `exit 2` and NOT `return 2`: the contract
# promises a reason line on every path that reaches the top level as 2.  A
# `return 2` inside a function is an internal value; whether it becomes the
# process exit code depends on how each caller folds it.  A 2026-10-12 review
# audited all 13 `return 2` sites (1188/1199/1507/1526/1540/1581/1588/1595/
# 1790/1794/1800/1807/3601) and concluded every one is folded -- but that audit
# MISSED the maintenance-lock family (recover_stale_maintenance_lock's three
# refusal sites, 1507/1526/1540 back then): it is called BARE from
# ensure_not_in_maintenance, which itself is called bare from main(), so its
# `return 2` reached the top level as exit 2 with NO reason line (reproduced
# 2026-10-13: a live-holder identity mismatch printed the refusal and exited 2
# with `grep -c reason=` = 0).  Fixed 2026-10-13: all three sites now emit
# `reason=protocol_error` before returning.  Matching `return 2` here instead
# would have reported all 13 and buried the one real gap, so the rule stays on
# `exit 2` and the return-2 audit lives in this comment plus the fix above.
reason_gap_sites=$(
    awk '
        {
            line = $0
            if (pending != "") { line = pending " " line; pending = "" }
            if (line ~ /\\[[:space:]]*$/) {
                sub(/\\[[:space:]]*$/, "", line)
                pending = line
                next
            }
            joined[++n] = line
        }
        END {
            if (pending != "") joined[++n] = pending
            for (i = 1; i < n; i++) {
                if (joined[i] !~ /printf/ || joined[i] ~ /reason=/ || joined[i] !~ />&2/) continue
                j = i + 1
                while (j <= n && (joined[j] ~ /^[[:space:]]*$/ || joined[j] ~ /^[[:space:]]*#/)) j++
                if (j <= n && joined[j] ~ /^[[:space:]]*exit 2[[:space:]]*$/) printf "%d:%s\n", i, joined[i]
                # Same one-liner shape on a single physical line
                # (`printf ... >&2; exit 2`): none exist today (checked
                # 2026-10-13) but the shape escapes the join above -- a
                # semicolon-joined printf+exit-2 is reported as
                # cannot-conclude rather than silently invisible.
                if (j == i + 1 && joined[i] ~ /printf.*>&2;[[:space:]]*exit 2[[:space:]]*$/ && joined[i] !~ /reason=/)
                    printf "%d:CANNOT-CONCLUDE(one-liner printf+exit2):%s\n", i, joined[i]
            }
        }' "$server"
)
if [ -n "$reason_gap_sites" ]; then
    printf 'exit-2 sites print a message but no reason line:\n%s\n' "$reason_gap_sites" >&2
    failures=$((failures + 1))
fi
# The gap count is derived from the same variable the guard above acts on, not a
# hardcoded 0: a literal would keep reading "reason-gaps=0" if the guard were
# ever separated from the summary.  It is 0 whenever this line is reached.
if [ -n "$reason_gap_sites" ]; then
    reason_gap_count=$(printf '%s\n' "$reason_gap_sites" | grep -c .)
else
    reason_gap_count=0
fi

# Second structural rule, closing the hole the first one cannot see: a message
# followed by `return 2` inside a function that is invoked BARE (not as an `if`
# condition and not under `||`/`&&`) somewhere in the file.  A bare call under
# `set -e` turns that return value into the process exit code, so the contract
# applies to it exactly as to a literal `exit 2` -- this is precisely the shape
# the 2026-10-12 manual audit missed (recover_stale_maintenance_lock, see the
# comment above).  The rule is structural, not a name list: renaming the
# function, adding a call site, or dropping the reason line all go red.
# Functions are tracked by scanning for `name() {` definitions; a site is
# "bare" when some line consists of (optional leading whitespace +) the name
# alone.  Calls guarded by if/||/&&/&& or inside $( ) are fine -- their return
# value is folded by the caller, which must then carry the reason itself.
return2_gap_sites=$(
    awk '
        {
            line = $0
            if (pending != "") { line = pending " " line; pending = "" }
            if (line ~ /\\[[:space:]]*$/) {
                sub(/\\[[:space:]]*$/, "", line)
                pending = line
                next
            }
            joined[++n] = line
        }
        END {
            if (pending != "") joined[++n] = pending
            for (i = 1; i <= n; i++) {
                if (joined[i] ~ /^[[:space:]]*[a-z_]+[[:space:]]*$/) {
                    f = joined[i]; sub(/^[[:space:]]*/, "", f); sub(/[[:space:]]*$/, "", f)
                    bare[f] = 1
                }
            }
            cur = ""
            for (i = 1; i < n; i++) {
                if (joined[i] ~ /^[[:space:]]*[a-z_]+\(\) \{[[:space:]]*$/) {
                    cur = joined[i]; sub(/^[[:space:]]*/, "", cur); sub(/\(\) \{[[:space:]]*$/, "", cur)
                }
                if (joined[i] !~ /printf/ || joined[i] ~ /reason=/ || joined[i] !~ />&2/) continue
                j = i + 1
                while (j <= n && (joined[j] ~ /^[[:space:]]*$/ || joined[j] ~ /^[[:space:]]*#/)) j++
                if (j <= n && joined[j] ~ /^[[:space:]]*return 2[[:space:]]*$/ && cur != "" && bare[cur]) printf "%d [%s]: %s\n", i, cur, joined[i]
            }
        }' "$server"
)
if [ -n "$return2_gap_sites" ]; then
    printf 'return-2 sites in bare-invoked functions print a message but no reason line:\n%s\n' "$return2_gap_sites" >&2
    failures=$((failures + 1))
fi

# Third structural rule: the server's EXIT trap must be `|| true`-guarded.
# Measured 2026-10-13 on bash and dash: under `set -e`, a non-zero return from
# the trap body trips errexit and the process exits with the CLEANUP's code --
# a successful `exit 0` reads as 1, and a `wait`'s 5/6 or a `fail`'s 2 (reason
# already printed) read as an undifferentiated 1.  Reproduced on a real server
# with a lock directory made unremovable: stdout was the correct removed JSON
# and the exit code was 1.  The POSIX clients' signal traps were hardened in
# 0.1.5/0.1.6 and the server's EXIT slot was the one missed; this rule pins the
# hardened form so the next trap edit cannot regress it.
cases=$((cases + 1))
if ! grep -q "^trap 'cleanup || true' EXIT$" "$server"; then
    printf '%s\n' 'error-contract: the server EXIT trap is not `|| true`-guarded; a failing lock/teardown cleanup replaces the server protocol exit code (measured 2026-10-13)' >&2
    failures=$((failures + 1))
fi

# A bash function called at top level BEFORE its definition dies with
# "command not found" (exit 127) -- on the Windows target that surfaced as the
# installer's launcher smoke reading 127 instead of the contract's 2
# (measured on the test VM 2026-10-14: install_jq_line_ending_shim was called
# at line 220 from the platform dispatch while its definition sat at 382; the
# whole doctor path returned 127).  Lock the measured case structurally: the
# shim installer's definition must precede its every call site.
cases=$((cases + 1))
shim_def_line=$(grep -n '^install_jq_line_ending_shim() {' "$server" | head -1 | cut -d: -f1)
shim_call_lines=$(grep -n '^[[:space:]]*install_jq_line_ending_shim$' "$server" | cut -d: -f1)
if [ -z "$shim_def_line" ] || [ -z "$shim_call_lines" ]; then
    printf '%s\n' 'error-contract: install_jq_line_ending_shim definition or call sites vanished (the static ordering lock below would be vacuous)' >&2
    failures=$((failures + 1))
else
    for line in $shim_call_lines; do
        if [ "$line" -lt "$shim_def_line" ]; then
            printf 'error-contract: install_jq_line_ending_shim is called at line %s before its definition at line %s; the Windows dispatch exits 127 there (measured on the test VM, 2026-10-14)\n' "$line" "$shim_def_line" >&2
            failures=$((failures + 1))
        fi
    done
fi

if [ "$failures" -ne 0 ]; then
    printf 'error-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'error-contract checks passed: cases=%s commands=%s runtime=synthetic reasons=asserted reason-gaps=%s\n' \
    "$cases" \
    "$(printf '%s\n' $documented_commands | wc -l | tr -d ' ')" \
    "$reason_gap_count"
