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
partial=0
notcovered=0
notcovered_list=''

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
    # 3<&- : fd 3 is this loop's own list of checks.  Leaving it open meant a
    # check that read fd 3 drained the list, and the only symptom was a later
    # "only N of M smoke checks ran" with no idea which one did it.
    if "$check" 3<&- >"$output" 2>&1; then
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
    elif grep -qi 'skipped' "$output"; then
        # The whole check ran and exited 0, but it reported an inner sub-part it
        # could not verify.  smoke/01 does this: with pwsh absent it still checks
        # the 9 shell assets, the plists, the .yml and the canonical parity, and
        # only the 7 .ps1 AST parses are `skipped(pwsh-absent)`.  Classifying the
        # whole check as SKIP would UNDERSTATE what ran; classifying it ok would
        # let a real gap read as a full pass.  Neither -- so it gets its own
        # bucket, and it counts toward NOT A FULL PASS because something in the
        # check was not verified.
        printf 'PART  %-28s %s\n' "$name" "$(grep -i skipped "$output" | head -1)"
        partial=$((partial + 1))
        # Double-report: a check that BOTH skipped an inner sub-part AND declared
        # a NOT-covered platform item belongs in PART (it is genuinely partial)
        # and in the known-set gate (the NOT-covered name must be recognised).
        # Testing NOT-covered only in the arm below meant the PART arm swallowed
        # it, so a NEW platform gap inside such a check never reached ci.yml.
        if grep -q 'NOT-covered\|not-covered' "$output"; then
            printf 'NCOV  %-28s %s\n' "$name" "$(grep -E 'NOT-covered|not-covered' "$output" | head -1)"
            notcovered=$((notcovered + 1))
            notcovered_list="$notcovered_list$name "
        fi
    elif grep -q 'NOT-covered\|not-covered' "$output"; then
        # A THIRD bucket, distinct from PART.  A check whose summary says
        # `staging=NOT-covered(needs-Windows)` has admitted a named sub-part it
        # cannot verify HERE -- but that sub-part is a permanent property of the
        # platform (needs-Windows), not a gap that a better run would close.  It
        # is therefore NOT routed to PART: doing so would print `N partial` and
        # `NOT A FULL PASS` on every macOS/Linux run, and the only way to keep
        # CI green would be to relax the `0 partial` gate -- which would weaken
        # it for REAL partials too.  Instead it gets a visible bucket, a count,
        # and a named list on its own line; ci.yml asserts every name on that
        # list is in the known set, so a NEW one -- a check that silently
        # stopped covering something -- fails the gate.  Before this branch
        # existed the word was invisible: a check printing NOT-covered
        # classified `ok`, the summary said `0 partial`, and no gate ever
        # learned of it (found and reproduced by the 2026-10-12 full-dimension
        # review: a check printing NOT-covered classified `ok`, and a log with
        # three such checks passed both CI gates).
        printf 'NCOV  %-28s %s\n' "$name" "$(grep -E 'NOT-covered|not-covered' "$output" | head -1)"
        notcovered=$((notcovered + 1))
        notcovered_list="$notcovered_list$name "
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

# --- a NOT-covered declaration must be in the known set ----------------------
# CI has always policed this: the linux job compares every reported name
# against a known list and fails on a new one.  The local run did not -- it
# printed the list and exited 0.  Measured 2026-10-27 on a two-check fixture
# tree: a check printing `staging=NOT-covered(needs-Windows)` produced
# `PASS checks: 2 ran, 0 skipped, 0 partial, 0 failed` and exit 0 here, while
# the linux job's gate rejected the same log with exit 1.  A local run must not
# be greener than CI -- the same shape the ci_pin round fixed for the check
# list itself.  The known set lives in ONE file that both consumers read, so
# the two lists cannot drift apart.
not_covered_unknown() { # $1 = known set (space-delimited), $2 = reported -> unknown names
    local unknown='' name
    for name in $2; do
        case " $1 " in
            *" $name "*) ;;
            *) unknown="$unknown $name" ;;
        esac
    done
    printf '%s' "$unknown"
}
# A subset test that always passes is the false green this gate exists to
# prevent: prove it flags an unknown name and accepts a known one.
ncov_selftest_ok=true
[ "$(not_covered_unknown 'a-check b-check' 'b-check c-check')" = ' c-check' ] || ncov_selftest_ok=false
[ -z "$(not_covered_unknown 'a-check b-check' 'a-check b-check')" ] || ncov_selftest_ok=false
if [ "$ncov_selftest_ok" = false ]; then
    printf 'FAIL  the NOT-covered known-set matcher failed its self-test (it must flag an unknown name and accept a known one)\n' >&2
    failures=$((failures + 1))
fi
known_ncov_file="$root/smoke/not-covered-known.txt"
if [ ! -f "$known_ncov_file" ]; then
    printf 'FAIL  %s is missing; the platform-gap policy cannot be read, and an unreadable policy must not pass\n' \
        "${known_ncov_file#"$root"/}" >&2
    failures=$((failures + 1))
else
    known_ncov_names=$(grep -vE '^[[:space:]]*(#|$)' "$known_ncov_file" | tr '\n' ' ' || true)
    if [ -z "$known_ncov_names" ]; then
        printf 'FAIL  %s names no check; every declared platform gap would read as unknown\n' \
            "${known_ncov_file#"$root"/}" >&2
        failures=$((failures + 1))
    fi
    unknown_ncov=$(not_covered_unknown "$known_ncov_names" "$notcovered_list")
    if [ -n "$unknown_ncov" ]; then
        printf 'FAIL  check(s) declared NOT-covered without being in %s:%s\n' \
            "${known_ncov_file#"$root"/}" "$unknown_ncov" >&2
        printf '      Add the name there deliberately (and say which platform cannot exercise the sub-part in docs/PLAN.md), or drop the token -- a gap claimed for the first time is exactly what this gate exists for.\n' >&2
        failures=$((failures + 1))
    fi
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
if [ "$skipped" -ne 0 ] || [ "$partial" -ne 0 ]; then
    printf '\n%s checks: %s ran, %s skipped, %s partial, %s failed (%ss)\n' \
        "$verdict" "$ran" "$skipped" "$partial" "$failures" "$elapsed"
    printf '%s\n' "NOT A FULL PASS: $skipped check(s) skipped and $partial check(s) only partially verified."
    printf '%s\n' 'Set AGENTQ_SMOKE_HOME to a runtime containing pueue to run them (see docs/verification-status.md).'
else
    printf '\n%s checks: %s ran, %s skipped, %s partial, %s failed (%ss)\n' \
        "$verdict" "$ran" "$skipped" "$partial" "$failures" "$elapsed"
fi
# Platform-expected NOT-covered, reported on its own line so the `checks:` line
# above keeps the exact shape every gate greps for.  This line is what CI pins:
# every name on it must be in the known set (see the NCOV branch above for why
# the bucket exists).
if [ "$notcovered" -ne 0 ]; then
    printf '%s\n' "NOT-covered: $notcovered check(s) declared platform-unverifiable sub-parts: $notcovered_list"
fi

[ "$failures" -eq 0 ] || exit 1
exit 0
