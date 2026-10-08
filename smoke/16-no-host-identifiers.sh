#!/usr/bin/env bash
# Smoke: no host identifier may appear anywhere in this repo, or in the
# project's memory directory.
#
# Why this is its own check.  The rule is already written down -- CLAUDE.md's
# 操作边界 says 仓库与记忆里一律不出现主机名或 IP -- and CHANGELOG records a
# 2026-09-22 cleanup of 9 occurrences whose verification was "a repo-wide regex
# scan, excluding loopback, reporting zero hits".  But nothing RE-RAN that scan,
# so the rule decayed silently: by 2026-09-27 the tree carried 7 distinct
# addresses across 46 lines, plus account names, two third-party public-key
# comment strings (carrying a real name and two machine names), an
# ~/.ssh/config alias, and a private-key FILENAME derived from an address.  A
# rule that is written down but not checked is a comment, and comments drift.
# Every rule in this suite that has survived did so because a check re-runs it
# (01 parity, 10 A-G); this one had none.
#
# The seven shapes below are the ones that actually leaked.  Each is calibrated
# in BOTH directions by the self-test before the scan is trusted: every rule is
# required to fire on the shape it exists for AND stay silent on the
# placeholders that replaced it.  That self-test runs first and its result gates
# the report, so a rule loosened into matching nothing fails here instead of
# printing a clean scan.  (The first draft of this file defined its self-test
# helpers and then never called them -- a self-test that cannot fail is the same
# false green it was written to prevent, so it is wired to the exit path.)
#
# What this proves: these seven shapes are absent from the scanned text.  What it
# does not prove: that no other shape carries an address -- a host recorded as
# "the box in the corner" is invisible to a scanner.  That is a deliberate limit,
# not an oversight.  This is a content scan and says nothing about behaviour.
# One rule carries a scoped exemption rather than a file exemption: R4 stands
# down inside .github/workflows/ only -- the `uses: owner/repo@vN` construct --
# and the scope of that exemption is pinned in both directions below, so
# widening it fails the self-test instead of silently blinding a rule.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
memory_dir="$HOME/.claude/projects/-Volumes-Work-code-agentq/memory"

# The rules.  One definition, used by both the scan and the self-test, so the
# two can never disagree about what a rule means.
#
# R1  an IPv4 literal that is not loopback/unspecified.  Loopback is allowed: it
#     is the 07 sandbox sshd's listen address, a fixture, not a host.
# R2  an mDNS hostname.  Measured leaks: two Mac names, one inside a third
#     party's public-key comment.
# R3  user@fqdn.  The `user@host: ` prefix OpenSSH writes is the shape that
#     leaked, and 05's classifier fixture is built from it.
# R4  @a-bareword-containing-a-digit -- catches the serial-number host name that
#     R3 misses (no dot).  Deliberately narrower than "@any bareword": the
#     synthetic fixture `smokeuser@smoke-host` in 05 is legitimate.
#     Skipped under .github/workflows/ and nowhere else -- see r4_path_exempt
#     below.  A workflow pins its actions as `uses: owner/repo@vN`: the `@` is
#     syntax and the digit is a version, which is exactly this rule's shape.
#     Measured 2026-10-08: the repository's own four new CI reference lines were
#     four R4 violations.  The exemption is by path and construct, never by
#     exempting a file: R1-R3 and R5-R7 stay active in workflow files (an
#     address or an ssh URL pasted into one still fires) and R4 stays active
#     everywhere else -- the canary below runs outside .github and proves it.
# R5  an address flattened into an identifier -- the private-key filename shape.
#     No `\b`: it fails between `_` and a digit, which is how the first version
#     of this rule matched nothing at all while reporting a clean tree.
# R6  a FQDN under an internal-only TLD.  Added 2026-10-05: the original five
#     shapes missed the most common real leak of all -- an intranet host name
#     under an internal TLD (`.corp`, `.intranet`, `.lan`, ...) -- because R2
#     only knows `.local` and
#     R3/R4 require an `@`.  The TLD must be the LAST label (nothing but a
#     non-dot, non-alnum separator or end-of-line after it): without that anchor
#     `web01.corp.example.com` matches, and RFC 2606 reserves `example`/`test`/
#     `invalid` precisely so that placeholder FQDNs are safe to write down --
#     this file's own CHANGELOG entry cites one.  Excluding the reserved TLDs
#     keeps documentation placeholders legal while still catching the internal
#     names they stand in for.
RE_R1='([0-9]{1,3}\.){3}[0-9]{1,3}'
RE_R2='[A-Za-z0-9][A-Za-z0-9-]*\.local'
RE_R3='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+'
RE_R4='@[A-Za-z0-9-]*[0-9][A-Za-z0-9-]*'
RE_R5='[0-9]{1,3}(_[0-9]{1,3}){3}'
RE_R6='[A-Za-z0-9][A-Za-z0-9-]*\.(internal|intranet|lan|corp|localdomain|home)([^A-Za-z0-9.-]|$)'
# R7  an auto-generated Windows computer name: uppercase letters, a hyphen, an
#     embedded 8-digit date, trailing letters.  Added 2026-10-06: the C3
#     write-up put the test VM's computer name into docs/PLAN.md and CHANGELOG.md,
#     and R1-R6 all missed it -- every one of them needs a dot, an `@`, or an
#     address shape, and this is a bare token.  The negatives below pin the two
#     edges: the trailing-letter requirement alone keeps dated release tags out
#     (RELEASE-20260926), while a synthetic task id (AQAAA-00000000000001)
#     needs BOTH edges removed before it matches -- measured, not assumed.  It
#     does NOT cover
#     account names (arbitrary words, removed by reading -- the way the
#     2026-09-27 cleanup did it) nor lowercase or dateless bare host names;
#     those stay inside the boundary the header records.
RE_R7='[A-Z][A-Z0-9]*-20[0-9]{6}[A-Z][A-Z0-9]*'
# R1 additionally excludes these, which are fixtures rather than hosts.
RE_R1_ALLOW='^(127\.|0\.0\.0\.0$)'

failures=0
selftest_failures=0
scanned=0

# mask <string> -- never echo a match back in full.  This check's own output is
# read, pasted and archived; printing the address here would turn the detector
# into a fresh leak vector, which is the same mistake in a new place.
#
# Only the first two characters survive.  Showing a suffix was the first
# version's mistake: for an IPv4 literal the suffix is the host octet, i.e. the
# most identifying part, so a mask that kept it narrowed the host while looking
# redacted.  Two characters of a private-range literal reveal only the RFC1918
# block, which the surrounding text usually implies anyway; the file:line is the
# pointer to act on, and the length distinguishes two matches of the same rule.
mask() {
    local s=$1 n=${#1}
    if [ "$n" -le 2 ]; then
        printf '%s' '**'
    else
        printf '%s%s(len %s)' "${s:0:2}" "$(printf '%*s' $((n - 2)) '' | tr ' ' '*')" "$n"
    fi
}

report() {
    printf '%s:%s  %s  %s\n' "${1#"$root"/}" "$2" "$3" "$(mask "$4")" >&2
    failures=$((failures + 1))
}

# first_match <rule> <line> -- the first offending token, or empty.  Used by the
# self-test only; the scan itself runs one `grep -n` per rule per file, because
# a fork per rule per line is 165k forks on a 33k-line tree and this project has
# measured fork+exec at ~15ms -- that shape takes tens of minutes.  Measured on
# this tree: the per-line version did not finish in 120s.
first_match() {
    local rule=$1 line=$2 got
    case "$rule" in
    R1)
        got=$(printf '%s' "$line" | grep -oE "$RE_R1" | grep -vE "$RE_R1_ALLOW" | head -1 || true)
        ;;
    R2) got=$(printf '%s' "$line" | grep -oE "$RE_R2" | head -1 || true) ;;
    R3) got=$(printf '%s' "$line" | grep -oE "$RE_R3" | head -1 || true) ;;
    R4) got=$(printf '%s' "$line" | grep -oE "$RE_R4" | head -1 || true) ;;
    R5) got=$(printf '%s' "$line" | grep -oE "$RE_R5" | head -1 || true) ;;
    R6) got=$(printf '%s' "$line" | grep -oE "$RE_R6" | head -1 || true) ;;
    R7) got=$(printf '%s' "$line" | grep -oE "$RE_R7" | head -1 || true) ;;
    esac
    printf '%s' "$got"
}

# r4_path_exempt <path-relative-to-root> -- R4 only, only for workflow files.
# The path is matched relative to the scan root, so moving the repository cannot
# change the verdict, and the pattern is exactly one directory deep: widening it
# to `.github/*` or to `*` is caught by the scope self-test, not left to trust.
# Boundary, recorded: a DOTTED action pin (`owner/repo@v<major>.<minor>`) would fire R3
# instead of R4; if one is ever added, the check goes red and the operator
# judges it then rather than this rule silently widening now.
r4_path_exempt() {
    case $1 in
        .github/workflows/*) return 0 ;;
        *) return 1 ;;
    esac
}

# scan_file <path> -- one `grep -n` per rule, so a file costs one fork per rule
# instead of one per line.  The per-rule loop is unrolled rather than looped so
# the rule name and its regex stay adjacent to the code that uses them.
scan_file() {
    local file=$1 hits ln tok
    scanned=$((scanned + 1))

    # R1's allowance applies to the MATCH, never to the line: a line may carry
    # both a loopback fixture and a real address.  An earlier version pre-filtered
    # whole lines with `grep -vE ':[0-9]+:.*^(127\.|...)'` -- but `^` after `.*`
    # is a literal caret, not an anchor, so that pattern matched nothing and the
    # filter silently did nothing.  It was harmless (it never dropped a line, so
    # no violation was missed) and is removed rather than fixed: line-level
    # filtering is the wrong shape here.
    hits=$(grep -nE "$RE_R1" "$file" 2>/dev/null || true)
    if [ -n "$hits" ]; then
        while IFS= read -r ln; do
            [ -n "$ln" ] || continue
            tok=$(printf '%s' "${ln#*:}" | grep -oE "$RE_R1" | grep -vE "$RE_R1_ALLOW" | head -1 || true)
            [ -n "$tok" ] && report "$file" "${ln%%:*}" R1 "$tok"
        done <<EOF
$hits
EOF
    fi

    for spec in "R2:$RE_R2" "R3:$RE_R3" "R4:$RE_R4" "R5:$RE_R5" "R6:$RE_R6" "R7:$RE_R7"; do
        rule=${spec%%:*}
        re=${spec#*:}
        if [ "$rule" = R4 ] && r4_path_exempt "${file#"$root"/}"; then
            continue
        fi
        hits=$(grep -nE "$re" "$file" 2>/dev/null || true)
        [ -n "$hits" ] || continue
        while IFS= read -r ln; do
            [ -n "$ln" ] || continue
            tok=$(printf '%s' "${ln#*:}" | grep -oE "$re" | head -1 || true)
            [ -n "$tok" ] && report "$file" "${ln%%:*}" "$rule" "$tok"
        done <<EOF
$hits
EOF
    done
}

# --- self-calibration, run FIRST and gate the scan -------------------------
# Samples are assembled at runtime from fragments so that this file contains no
# address literal of its own -- otherwise the scan below would report the
# checker, and the only way to silence it would be to exempt a file, which is
# how a rule grows a hole.  The fragments have to be chosen with care, not just
# split anywhere: the first version built the mDNS sample with the suffix
# written out whole inside a printf format string, and that format string was
# itself a match, so the check reported its own source.  That is the check
# behaving correctly -- a scan that skipped its own source would be the hole --
# so the fix is to split the literal further, never to exempt the file.
expect() { # expect <fire|silent> <rule> <text> <what>
    local want=$1 rule=$2 text=$3 what=$4 got
    got=$(first_match "$rule" "$text")
    case "$want" in
    fire)
        if [ -z "$got" ]; then
            printf 'self-test: rule %s no longer fires on %s\n' "$rule" "$what" >&2
            selftest_failures=$((selftest_failures + 1))
        fi
        ;;
    silent)
        if [ -n "$got" ]; then
            printf 'self-test: rule %s false-positives on %s (%s)\n' "$rule" "$what" "$(mask "$got")" >&2
            selftest_failures=$((selftest_failures + 1))
        fi
        ;;
    esac
}

s_ipv4=$(printf '%s.%s.%s.%s' 10 0 91 3)
s_mdns=$(printf '%s.%s' Example-Mac local)
s_user=$(printf '%s@%s' someone host7A2B3C)
s_user_fqdn=$(printf '%s@%s.%s' someone host example)
s_flat=$(printf '%s_%s_%s_%s' 10 0 91 3)
s_loopback=$(printf '%s.%s.%s.%s' 127 0 0 1)
s_unspec=$(printf '%s.%s.%s.%s' 0 0 0 0)
s_placeholder=$(printf '%s@%s' '<user>' '<host>')
s_fixture=$(printf '%s@%s' smokeuser smoke-host)
s_benign=$(printf 'task_id=%s records=%s' 4200 1507407)
# R6.  Built from fragments for the same reason as the rest: this file must not
# contain the shape it hunts.  The negative sample is the one that decides
# whether the rule is usable at all -- a placeholder FQDN under a reserved TLD
# has to stay legal, and the repo's own CHANGELOG cites exactly that form.
s_internal=$(printf '%s.%s' db01 corp)
s_internal2=$(printf '%s.%s' jump intranet)
s_reserved_fqdn=$(printf '%s.%s.%s.%s' web01 corp example com)
# R7.  Built from fragments like the rest: this file must not contain the shape
# it hunts.  The negatives decide the rule's edges, and both are shapes this
# repo actually writes: a synthetic task id (uppercase, hyphen, digits -- but
# the digits are not a date) and a dated release tag (a date, nothing after it).
s_machine=$(printf '%s-%s%s' EXMPL 2020 0101ABC)
s_taskid=$(printf '%s-%s' AQAAA 00000000000001)
s_datedtag=$(printf '%s-%s' RELEASE 20260926)
s_lowerdate=$(printf '%s-%s%s' agentq 2026 0926abc)

expect fire   R1 "$s_ipv4"        'a bare IPv4 literal'
expect silent R1 "$s_loopback"    'loopback (07 sandbox sshd)'
expect silent R1 "$s_unspec"      'the unspecified address'
expect silent R1 "$s_benign"      'unrelated numbers'
expect fire   R2 "$s_mdns"        'an mDNS hostname'
expect fire   R3 "$s_user_fqdn"   'user@fqdn'
expect silent R3 "$s_placeholder" 'the <user>@<host> placeholder'
expect silent R3 "$s_fixture"     'the smokeuser@smoke-host fixture'
expect fire   R4 "$s_user"        'user@serial-number-host'
expect silent R4 "$s_fixture"     'the smokeuser@smoke-host fixture'
expect silent R4 "$s_benign"      'unrelated numbers'
expect fire   R5 "$s_flat"        'an address flattened into a filename'
expect silent R5 "$s_benign"      'unrelated numbers'
expect fire   R6 "$s_internal"    'an intranet FQDN under .corp'
expect fire   R6 "$s_internal2"   'an intranet FQDN under .intranet'
expect silent R6 "$s_reserved_fqdn" 'a placeholder FQDN under the reserved .example TLD'
expect silent R6 "$s_mdns"        'the .local sample (R2 territory, not R6)'
expect silent R6 "$s_benign"      'unrelated numbers'
expect fire   R7 "$s_machine"     'a date-stamped computer name'
expect silent R7 "$s_taskid"      'a synthetic task id (digits are not a date)'
expect silent R7 "$s_datedtag"    'a dated release tag (nothing after the date)'
expect silent R7 "$s_lowerdate"   'a lowercase dated file name'

# The R4 path exemption's SCOPE, pinned in both directions: the workflows
# directory is exempt, and nothing else is.  Without this, widening the pattern
# to `.github/*` or to `*` would leave every sample above green -- they all run
# through first_match, which never sees a path.
expect_path() { # expect_path <exempt|active> <path> <what>
    local want=$1 path=$2 what=$3
    if r4_path_exempt "$path"; then
        [ "$want" = exempt ] || {
            printf 'self-test: the R4 path exemption covers %s (%s) but must not\n' "$path" "$what" >&2
            selftest_failures=$((selftest_failures + 1))
        }
    else
        [ "$want" = active ] || {
            printf 'self-test: the R4 path exemption misses %s (%s)\n' "$path" "$what" >&2
            selftest_failures=$((selftest_failures + 1))
        }
    fi
}
expect_path exempt .github/workflows/ci.yml      'a workflow file (uses: owner/repo@vN)'
expect_path active .github/SECURITY.md           'a community file under .github'
expect_path active .github/ISSUE_TEMPLATE/bug_report.md 'an issue template under .github'
expect_path active smoke/16-no-host-identifiers.sh 'the check itself'
expect_path active CHANGELOG.md                  'a root document'

if [ "$selftest_failures" -ne 0 ]; then
    printf 'no-host-identifiers: %s self-test failure(s); the scan below would not have been trustworthy\n' \
        "$selftest_failures" >&2
    exit 1
fi

# --- canary: prove the whole pipeline, not just the regexes ----------------
# The self-test above checks the regexes.  It does NOT check that scan_file ->
# report actually reaches the exit path -- and a mutation that disables the
# self-test gate was measured to go unnoticed (recorded honestly: the gate and
# the scan are the only two things that could catch each other, and a check that
# has been disabled is caught by nothing, which is true of every check here).
# What CAN be verified cheaply is that a known-bad file, fed through the real
# scan path, produces a real violation.  That makes the pipeline self-proving
# every run, independently of the gate: loosen a rule far enough that the canary
# stops firing and this fails, whatever the self-test says.
# ONE line per rule, so every rule is exercised end to end.  The first version
# carried only an IPv4 sample, which left R2-R5 covered by nothing but the
# self-test -- and the self-test is exactly what a loosened rule disables
# (measured: loosening R2 with the gate off was not caught by the R1-only canary).
canary_file=$(mktemp "${TMPDIR:-/tmp}/agentq-smoke-hostid.XXXXXX")
trap 'rm -f -- "$canary_file"' EXIT
printf '%s\n' "$s_ipv4" "$s_mdns" "$s_user_fqdn" "$s_user" "$s_flat" "$s_internal" "$s_machine" > "$canary_file"
canary_failures_before=$failures
# The canary is expected to be caught, so its report is noise on a green run;
# swallow it here.  Only the COUNT matters -- if it is short, the message below
# says which rules went quiet.
scan_file "$canary_file" 2>/dev/null
canary_caught=$((failures - canary_failures_before))
if [ "$canary_caught" -lt 7 ]; then
    printf 'no-host-identifiers: canary caught %s of 7 rules -- a rule that no longer fires on its own sample means the scan path is broken for it, regardless of what the self-test says\n' \
        "$canary_caught" >&2
    exit 1
fi
failures=$canary_failures_before
scanned=$((scanned - 1))

# --- the tree --------------------------------------------------------------
# Binary files are skipped: they are not text a reader copies an address out of,
# and grepping them produces noise.  `grep -Iq .` is the test for "is text".
tree_scanned=0
while IFS= read -r file; do
    grep -Iq . "$file" 2>/dev/null || continue
    tree_scanned=$((tree_scanned + 1))
    scan_file "$file"
done <<EOF
$(find "$root" -type f -not -path '*/.git/*' -not -name '*.syntax.*' | sort)
EOF
# Zero files means the enumeration broke, not that the tree is clean.  Without
# this guard a bad root reported "files=17 violations=0" (all from the memory
# half) and exited 0 -- measured 2026-10-06 by pointing root at an empty
# directory.  Same class as 01's shell_count/config_patterns guards.
if [ "$tree_scanned" -eq 0 ]; then
    printf 'no-host-identifiers: FAIL (the repository scan enumerated 0 files; a broken tree walk must not read as a clean scan)\n' >&2
    exit 1
fi

# --- the memory directory --------------------------------------------------
# Not part of the repo, but the rule covers it, and it is where the address
# originally came from.  Reported explicitly when absent, so a missing directory
# cannot read as a clean scan.
if [ -d "$memory_dir" ]; then
    memory_state=scanned
    while IFS= read -r file; do
        grep -Iq . "$file" 2>/dev/null || continue
        scan_file "$file"
    done <<EOF
$(find "$memory_dir" -type f | sort)
EOF
else
    memory_state='absent(NOT-verified)'
fi

# Violations are reported FIRST and unconditionally.  Order matters here: an
# earlier draft exited SKIPPED from the absent-memory branch above, which would
# have hidden real repo violations behind a skip whenever the memory directory
# happened to be missing.
if [ "$failures" -ne 0 ]; then
    printf 'no-host-identifiers: %s violation(s) across %s file(s); the addresses are masked above -- read the file:line, do not re-print the match\n' \
        "$failures" "$scanned" >&2
    exit 1
fi

# A run that could not scan memory is a PARTIAL verification.  Exiting 0 here
# would be printed by run-tests.sh as `ok`, which is the false green this
# suite's doctrine calls out ("SKIP is not PASS").  Emitting SKIPPED routes it
# to the SKIP column, and the summary line then adds NOT A FULL PASS.  Measured:
# without this, dropping the memory scan entirely printed
# `ok ... memory=absent(NOT-verified)` and the run still exited 0.
if [ "$memory_state" != scanned ]; then
    printf 'no-host-identifiers: SKIPPED (memory directory not present at %s; the repo scan ran but the memory half of the rule is NOT verified)\n' \
        "$memory_dir"
    exit 0
fi

printf 'no-host-identifiers checks passed: files=%s rules=7 selftest=calibrated memory=%s violations=0\n' \
    "$scanned" "$memory_state"
