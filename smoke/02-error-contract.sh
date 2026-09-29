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
cp "$root/assets/unix/agentq-server" "$work/agentq-server"
cp "$root/assets/unix/pueue.yml" "$work/config/pueue.yml"
for stub in pueue pueued; do
    printf '#!/bin/sh\nprintf "%%s 4.0.4\\n" "%s"\n' "$stub" > "$work/$stub"
    chmod 700 "$work/$stub"
done

server="$work/agentq-server"
failures=0

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
            }
        }' "$server"
)
if [ -n "$reason_gap_sites" ]; then
    printf 'exit-2 sites print a message but no reason line:\n%s\n' "$reason_gap_sites" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'error-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'error-contract checks passed: cases=9 commands=%s runtime=synthetic reasons=asserted reason-gaps=0\n' \
    "$(printf '%s\n' $documented_commands | wc -l | tr -d ' ')"
