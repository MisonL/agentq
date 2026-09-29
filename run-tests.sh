#!/usr/bin/env bash
# The single development entry point.  Runs every smoke check in smoke/, in
# order, and exits non-zero if any fails.
#
#   ./run-tests.sh          all checks
#   ./run-tests.sh --quick  only 01 (syntax, parity, PowerShell parse)
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
quick=false
[ "${1:-}" = "--quick" ] && quick=true

start=$(date +%s)
failures=0
ran=0
skipped=0

# The check list is held in a variable, NOT streamed into the loop on stdin.
# A check may spawn a process that reads stdin -- 07-client-transport starts a
# real sshd and drives it with ssh, which drains whatever is on fd 0.  With the
# list on stdin that drain silently truncated the loop: 08 and 09 never ran,
# `ran` was 7 while smoke/ held 9, and the run still reported PASS.  Measured:
# feeding each check 5 lines on stdin left 5 unread for 03/04/06 and 0 for 07.
# The list lives on fd 3, NOT fd 0.  A heredoc or a process substitution both
# still use stdin, so they do not help: the drain described above empties them
# just the same.  A separate descriptor is the only form that isolates the loop
# from whatever a check does to stdin.
check_list=$(mktemp)
trap 'rm -f -- "$check_list"' EXIT
find "$root/smoke" -name '*.sh' -type f | sort >"$check_list"
check_count=$(grep -c . "$check_list" || true)
exec 3<"$check_list"
while IFS= read -r check <&3; do
    [ -n "$check" ] || continue
    name=$(basename "$check" .sh)
    if [ "$quick" = true ]; then
        case "$name" in
            01-*) ;;
            *) continue ;;
        esac
    fi

    ran=$((ran + 1))

    # A check must PARSE before it runs.  A syntax error on a line bash has not
    # reached yet does not change the script's own exit status -- verified: a
    # script that ends in `exit 0` followed by an unterminated `if` still exits
    # 0 while printing "syntax error: unexpected end of file".  Without this the
    # check would be reported ok while having aborted part-way, which is exactly
    # how a half-run check hides.  `bash -n` reads the whole file up front.
    # The scratch file goes in /tmp, not beside the check.  `"$check.syntax.$$"`
    # put it inside smoke/, which bumped that directory's mtime on every run --
    # so a frozen-window comparison (`find . -newer <stamp>`) always reported
    # ./smoke, and the project's own rule is that detailed output goes to /tmp.
    # A signal that is always present is a signal nobody reads.
    syntax_output=$(mktemp "${TMPDIR:-/tmp}/agentq-syntax.XXXXXX")
    if ! bash -n "$check" 2>"$syntax_output"; then
        printf 'FAIL  %-28s syntax error\n' "$name"
        sed 's/^/      /' "$syntax_output"
        rm -f "$syntax_output"
        failures=$((failures + 1))
        continue
    fi
    rm -f "$syntax_output"

    output=$(mktemp)
    status=0
    if "$check" >"$output" 2>&1; then
        status=0
    else
        status=$?
    fi

    if [ "$status" -ne 0 ]; then
        printf 'FAIL  %-28s exit=%s\n' "$name" "$status"
        sed 's/^/      /' "$output"
        failures=$((failures + 1))
    elif grep -q 'SKIPPED' "$output"; then
        printf 'SKIP  %-28s %s\n' "$name" "$(grep SKIPPED "$output" | head -1)"
        skipped=$((skipped + 1))
    elif [ ! -s "$output" ]; then
        # A check that exits 0 without printing anything has not demonstrated
        # anything.  Treat silence as failure so a vacuous pass cannot hide
        # here the way it did in the old fixture suite.
        printf 'FAIL  %-28s exit=0 with no output\n' "$name"
        failures=$((failures + 1))
    else
        printf 'ok    %-28s %s\n' "$name" "$(tail -1 "$output")"
    fi
    rm -f "$output"
done
exec 3<&-

# Zero checks run is never a pass: it means smoke/ is missing, empty, or the
# filter matched nothing.
if [ "$ran" -eq 0 ]; then
    printf '%s\n' 'FAIL  no smoke checks ran' >&2
    failures=$((failures + 1))
fi

# Nor is a partial run.  Every discovered check must have been executed --
# `skipped` is a SUBSET of `ran` (a check is counted as run, then reclassified
# as skipped), so the comparison is against `ran` alone.  A shortfall means
# something ate the iteration (see the stdin note above).  Comparing against the
# discovered count rather than a literal keeps this honest as checks are added.
if [ "$quick" = false ] && [ "$ran" -ne "$check_count" ]; then
    printf 'FAIL  only %s of %s smoke checks ran\n' "$ran" "$check_count" >&2
    failures=$((failures + 1))
fi

elapsed=$(( $(date +%s) - start ))

# A skipped check is not a passing check, and the summary line is what people
# read -- the old form printed "PASS 10 ran, 3 skipped, 0 failed", which reads
# as a green run even though a third of the suite never executed.  That is the
# most likely misreading this script can produce, so the warning goes ON the
# summary line rather than in a note underneath it, where it was easy to scroll
# past.  The exit code stays 0: skipping is a property of the environment, not a
# failure of the code under test.
verdict=$([ "$failures" -eq 0 ] && echo PASS || echo FAIL)
if [ "$skipped" -ne 0 ]; then
    printf '\n%s checks: %s ran, %s skipped, %s failed (%ss)\n' \
        "$verdict" "$ran" "$skipped" "$failures" "$elapsed"
    printf '%s\n' "NOT A FULL PASS: $skipped check(s) skipped and therefore not verified."
    printf '%s\n' 'Set AGENTQ_SMOKE_HOME to a runtime containing pueue to run them (see CLAUDE.md).'
else
    printf '\n%s checks: %s ran, %s skipped, %s failed (%ss)\n' \
        "$verdict" "$ran" "$skipped" "$failures" "$elapsed"
fi

[ "$failures" -eq 0 ] || exit 1
exit 0
