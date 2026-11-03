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
# The memory directory's name is derived from the repo's ABSOLUTE PATH (a
# Claude-projects slug), so hardcoding this checkout's slug made the scan
# silently skip on every other clone path -- repo half green, memory half
# unverified, invisible in CI because of the named allowance below.  Derive the
# slug from the actual checkout path: Claude replaces each run of non-alphanumeric
# characters with a single '-', keeping the LEADING one (measured: /Volumes/Work/
# code/agentq -> -Volumes-Work-code-agentq).  AGENTQ_SMOKE_MEMORY_DIR overrides.
memory_slug=$(printf '%s' "$root" | LC_ALL=C sed -E 's/[^A-Za-z0-9]+/-/g')
memory_dir=${AGENTQ_SMOKE_MEMORY_DIR:-$HOME/.claude/projects/$memory_slug/memory}

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
        got=$(grep -oE "$RE_R1" <<< "$line" | grep -vE "$RE_R1_ALLOW" | head -1 || true)
        ;;
    R2) got=$(grep -oE "$RE_R2" <<< "$line" | head -1 || true) ;;
    R3) got=$(grep -oE "$RE_R3" <<< "$line" | head -1 || true) ;;
    R4) got=$(grep -oE "$RE_R4" <<< "$line" | head -1 || true) ;;
    R5) got=$(grep -oE "$RE_R5" <<< "$line" | head -1 || true) ;;
    R6) got=$(grep -oE "$RE_R6" <<< "$line" | head -1 || true) ;;
    R7) got=$(grep -oE "$RE_R7" <<< "$line" | head -1 || true) ;;
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

# is_derived_bytecode <path> -- Python bytecode caches are not text and are not
# a gap in the scan: each one is compiled from a .py the walk scans, and
# .gitignore declares `__pycache__/` and `*.pyc` never committed.  Before this
# predicate existed they were caught by the NUL-byte arm below and reported as
# "skipped a file that looks binary" -- which run-tests classifies as PART for
# ANY line containing that word.  Measured 2026-10-25: one `import` of
# smoke/01-farm-write.py during development left
# smoke/__pycache__/01-farm-write.cpython-314.pyc in the tree, and the next
# full suite reported "NOT A FULL PASS: 1 check(s) only partially verified" for
# an artifact that cannot be committed and whose source was scanned.  The
# exclusion is deliberately narrow and pinned in both directions by the
# self-test below: a NUL file one directory over must still be REPORTED.
is_derived_bytecode() {
    case $1 in
        */__pycache__/*|*.pyc) return 0 ;;
        *) return 1 ;;
    esac
}

# is_os_junk <path> -- OS/environment artifacts that are not repository content
# and cannot be committed.  Finder writes .DS_Store into every directory it
# displays, so a macOS checkout that has merely been browsed grows one in the
# repo root (measured 2026-11-03: `.DS_Store`, 6148 bytes, gitignored and
# untracked).  It is a binary file, so the NUL-byte arm below REPORTED it and
# run-tests classified the whole check PART -> the full suite printed "NOT A
# FULL PASS" on macOS while every assertion had passed.  This is the same shape
# the bytecode exclusion above was added for, and smoke/01 already treats these
# three basenames as `junk` (asset_kind); this is the same table, in the other
# check.  `Thumbs.db`/`desktop.ini` are here for symmetry -- they are Windows'
# equivalents and are what that table already lists; `.DS_Store` is the one
# measured to appear in the tree (and .gitignore's OS-noise section names it).
#
# Deliberately narrow: only these three basenames.  A widened arm (`*.tmp`,
# `*~`) would also swallow a real file, and the self-test below pins both
# directions -- a NUL-bearing text file with an ordinary name must still be
# REPORTED, not skipped.
is_os_junk() {
    case ${1##*/} in
        .DS_Store|Thumbs.db|desktop.ini) return 0 ;;
        *) return 1 ;;
    esac
}

# classify_file <path> -- how a walk must treat one file.  Prints exactly one
# of `scan` (run the rules over it), `not-text` (REPORT it: a non-empty file
# whose bytes are not text, so an address could hide behind a stray NUL), or
# `skip` (nothing to scan and nothing to say: an excluded artifact, an empty
# file, or a file that is neither text nor NUL-bearing).
#
# ONE classifier for BOTH walks.  They were written separately, and the memory
# half -- added later -- reproduced neither the bytecode/OS-junk exclusions nor
# the empty-file rule, so it diverged in two measured ways (2026-11-04):
#   * a Finder `.DS_Store` in the memory directory was reported as "binary by
#     NUL bytes" and turned the whole check into a false PART -- the exact shape
#     the 第五十九类 round removed from the repo half;
#   * an EMPTY file was reported the same way, though it holds no bytes at all
#     and therefore no NUL.  The repo half already guarded this with `[ -s ]`;
#     the memory half did not.
# A twin that must agree with another twin is a copy; a copy drifts.  This is
# the single implementation both walks now call, and the self-test below pins
# all three outcomes.
classify_file() {
    local file=$1
    if is_derived_bytecode "$file" || is_os_junk "$file"; then
        printf 'skip\n'; return 0
    fi
    if grep -Iq . "$file" 2>/dev/null; then
        printf 'scan\n'; return 0
    fi
    # Not text.  An empty file has nothing to leak; only a NON-EMPTY file that
    # actually carries a NUL byte is worth reporting.
    if [ -s "$file" ] && LC_ALL=C grep -q "$(printf '\x00')" "$file" 2>/dev/null; then
        printf 'not-text\n'; return 0
    fi
    printf 'skip\n'
}

# scan_memory_dir <dir> -- the memory half of the rule, as ONE function so the
# self-test below can drive the real code on real directories instead of a
# copy of it.  Sets the global memory_state -- NOT stdout: the violation and
# `scanned` counters live in the caller, and a `$( )` capture would strand the
# memory files' contribution outside the `files=` total (measured 2026-11-03:
# the count dropped from 117 to 80 when this returned its state on stdout).
#
# Two ways this half could read green while having checked nothing, each
# MEASURED 2026-11-03.  Both used to end in the literal summary token
# `memory=scanned`, which run-tests prints for an `ok` check and ci.yml
# matched by shape -- so neither could ever show up anywhere:
#
#   * the directory exists but yields NOTHING.  `find` on an empty directory
#     prints no error and exits 0, so `scanned` claimed a verification with no
#     subject -- measured: an empty directory passed with the same words as the
#     real one.  An UNREADABLE directory read the same way: `find` printed
#     "Permission denied" and exited 0, the `$( )` kept only its (empty) stdout
#     and its stderr went to the report, so it too passed as `scanned`.
#   * a file that is NOT TEXT.  A NUL byte makes `grep -Iq .` fail, and the
#     old `|| continue` skipped the file SILENTLY -- measured: a memory file
#     holding a note with one NUL byte and a dotted-quad address passed with
#     violations=0, while the same text without the NUL was caught (exit 1).
#     A UTF-16 note is exactly that shape.  The repo walk already REFUSES to
#     skip such a file silently for the same reason ("a text leak can hide
#     behind one stray NUL"); the memory half is where the addresses actually
#     leaked from, so it must not be laxer.
#
# States: scanned | scanned(<n>-NOT-TEXT) | empty(NOT-verified).
scan_memory_dir() {
    local file scanned_text=0 not_text=0
    while IFS= read -r file; do
        [ -n "$file" ] || continue   # an empty `find` yields one empty line
        case $(classify_file "$file") in
            scan)
                scanned_text=$((scanned_text + 1))
                scan_file "$file"
                ;;
            not-text)
                printf 'no-host-identifiers: skipped a memory file that looks binary by NUL bytes (it could hide a text leak): %s\n' "$file" >&2
                not_text=$((not_text + 1))
                ;;
            *) : ;;   # bytecode/junk/empty: nothing to scan, nothing to say
        esac
    done <<EOF
$(find "$1" -type f 2>/dev/null | sort)
EOF
    # The state describes what was actually VERIFIED, so it is derived from the
    # counts, not from the directory merely existing: a directory holding only
    # junk or only empty files verified nothing and says so.
    if [ "$scanned_text" -eq 0 ] && [ "$not_text" -eq 0 ]; then
        printf 'no-host-identifiers: skipped the memory scan -- the directory at %s held no text file to scan (empty, unreadable, or only excluded artifacts); that must not read as a verified one\n' "$1" >&2
        memory_state='empty(NOT-verified)'
    elif [ "$not_text" -ne 0 ]; then
        memory_state="scanned($not_text-NOT-TEXT)"
    else
        memory_state=scanned
    fi
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
            tok=$(grep -oE "$RE_R1" <<< "${ln#*:}" | grep -vE "$RE_R1_ALLOW" | head -1 || true)
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
            tok=$(grep -oE "$re" <<< "${ln#*:}" | head -1 || true)
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

# The bytecode exclusion's SCOPE, pinned in both directions for the same reason
# as the R4 exemption above: widened to `*.py` or `*` it would still leave every
# sample above green, while a NUL-bearing text file would stop being REPORTED.
# Boundary, recorded: a .pyc force-added with `git add -f` would now be invisible
# to the content scan -- it is compiled from a source the walk does scan, and
# .gitignore declares the class uncommittable, so that is the accepted edge.
expect_bytecode() { # expect_bytecode <derived|scanned> <path> <what>
    local want=$1 path=$2 what=$3
    if is_derived_bytecode "$path"; then
        [ "$want" = derived ] || {
            printf 'self-test: the bytecode exclusion covers %s (%s) but must not\n' "$path" "$what" >&2
            selftest_failures=$((selftest_failures + 1))
        }
    else
        [ "$want" = scanned ] || {
            printf 'self-test: the bytecode exclusion misses %s (%s)\n' "$path" "$what" >&2
            selftest_failures=$((selftest_failures + 1))
        }
    fi
}
expect_bytecode derived smoke/__pycache__/01-farm-write.cpython-314.pyc 'a compiled cache of a scanned .py'
expect_bytecode derived "$root/smoke/nested/__pycache__/x.cpython-39.pyc" 'a nested cache, by absolute path'
expect_bytecode derived smoke/standalone.pyc     'a lone .pyc outside __pycache__'
expect_bytecode scanned smoke/01-farm-write.py   'the Python source itself'
expect_bytecode scanned "$root/smoke/01-farm-write.py" 'the source by absolute path'
expect_bytecode scanned smoke/16-no-host-identifiers.sh 'this check'
expect_bytecode scanned smoke/notes.pyc.txt      'a name that only ends in .pyc.txt'
expect_bytecode scanned smoke/__pycachex__/a.bin 'a directory that only looks like a cache'

# The OS-junk exclusion's SCOPE, pinned in both directions for the same reason:
# widened to `*.tmp`/`*~` (or bare `*`) it would still leave every bytecode
# sample above green while a NUL-bearing text file stopped being REPORTED.  The
# names are smoke/01's `junk` table verbatim; `.DS_Store` is the one measured
# to actually appear in the tree, but all three are the same class.
expect_junk() { # expect_junk <junk|scanned> <path> <what>
    local want=$1 path=$2 what=$3
    if is_os_junk "$path"; then
        [ "$want" = junk ] || {
            printf 'self-test: the OS-junk exclusion covers %s (%s) but must not\n' "$path" "$what" >&2
            selftest_failures=$((selftest_failures + 1))
        }
    else
        [ "$want" = scanned ] || {
            printf 'self-test: the OS-junk exclusion misses %s (%s)\n' "$path" "$what" >&2
            selftest_failures=$((selftest_failures + 1))
        }
    fi
}
expect_junk junk .DS_Store                     'Finder junk in the repo root'
expect_junk junk "$root/.DS_Store"             'the same, by absolute path'
expect_junk junk sub/dir/.DS_Store             'Finder junk in a subdirectory'
expect_junk junk notes/Thumbs.db               'Windows thumbnail cache'
expect_junk junk notes/desktop.ini             'Windows folder settings'
expect_junk scanned .DS_Store.bak              'a backup of the junk, not the junk'
expect_junk scanned smoke/.DS_Store.txt        'a name that only embeds the junk name'
expect_junk scanned logs/notes.tmp             'a temp file outside the declared class'
expect_junk scanned CHANGELOG.md               'an ordinary repository file'

# The memory-half states, driven through the REAL scan_memory_dir on real
# directories -- a self-test over a re-implementation would be the fixture
# testing itself.  Each directory is built here, scanned, then removed.  The
# catch cases are asserted by the violation COUNT delta, because the report
# masks the address (by design) and cannot be grepped for it.
mj_root=$(mktemp -d "${TMPDIR:-/tmp}/agentq-memory-states.XXXXXX")
mj_dq=$(printf '%s.%s.%s.%s' 10 1 2 3)   # assembled: this file is scanned too
mj_expect() { # mj_expect <want-state> <want-violations> <dir> <what>
    local want_state=$1 want_failures=$2 dir=$3 what=$4 got_state delta
    # Both the state and the violation count must be read from the SAME run,
    # and that run must not leak fixtures into the real scan: `failures` and
    # `scanned` would move for a fixture file, so the whole call is captured
    # in a subshell that prints exactly those two numbers back.
    read -r got_state delta <<<"$(
        before=$failures
        scan_memory_dir "$dir" 2>/dev/null
        printf '%s %s\n' "$memory_state" "$((failures - before))"
    )"
    if [ "$got_state" != "$want_state" ] || [ "$delta" -ne "$want_failures" ]; then
        printf 'self-test: memory scan of %s (%s): state [%s] violations=%s, expected [%s] violations=%s\n' \
            "$what" "$dir" "$got_state" "$delta" "$want_state" "$want_failures" >&2
        selftest_failures=$((selftest_failures + 1))
    fi
    chmod 700 "$dir" 2>/dev/null || true   # the unreadable case; harmless otherwise
    rm -rf -- "$dir" 2>/dev/null || true
}
# The classifier itself, one case per outcome.  Driven on real files (an
# outcome is a function of the bytes, not of the name alone), and both the
# bytecode and the OS-junk exclusions get a `skip` case so a widened or removed
# arm is caught here as well as by expect_bytecode/expect_junk above.
cf_root=$(mktemp -d "${TMPDIR:-/tmp}/agentq-classify.XXXXXX")
cf_expect() { # cf_expect <want> <path> <what>
    local want=$1 path=$2 what=$3 got
    got=$(classify_file "$path")
    if [ "$got" != "$want" ]; then
        printf 'self-test: classify_file(%s) = %s, expected %s (%s)\n' "$path" "$got" "$want" "$what" >&2
        selftest_failures=$((selftest_failures + 1))
    fi
}
printf 'ordinary text\n' >"$cf_root/text.md"
printf 'note\x00text\n' >"$cf_root/nul.md"
: >"$cf_root/empty.md"
printf '\x00\x00\x00\x01Bud1' >"$cf_root/.DS_Store"
printf 'anything\n' >"$cf_root/stale.pyc"
cf_expect scan    "$cf_root/text.md"     'a text file'
cf_expect not-text "$cf_root/nul.md"     'a non-empty NUL-bearing file'
cf_expect skip    "$cf_root/empty.md"    'an empty file (no byte, so no NUL to hide behind)'
cf_expect skip    "$cf_root/.DS_Store"   'Finder junk'
cf_expect skip    "$cf_root/stale.pyc"   'bytecode'
rm -rf -- "$cf_root"

mkdir -p "$mj_root/empty"
mj_expect 'empty(NOT-verified)' 0 "$mj_root/empty" 'an empty directory'
mkdir -p "$mj_root/text"
printf 'host %s here\n' "$mj_dq" >"$mj_root/text/note.md"
mj_expect scanned 1 "$mj_root/text" 'a text file holding an address'
mkdir -p "$mj_root/nul"
printf 'note\x00text %s here\n' "$mj_dq" >"$mj_root/nul/note.md"
mj_expect 'scanned(1-NOT-TEXT)' 0 "$mj_root/nul" 'a NUL-bearing file'
mkdir -p "$mj_root/mixed"
printf 'plain text, nothing to find here\n' >"$mj_root/mixed/a.md"
printf 'note\x00text %s here\n' "$mj_dq" >"$mj_root/mixed/b.md"
mj_expect 'scanned(1-NOT-TEXT)' 0 "$mj_root/mixed" 'a text file beside a NUL-bearing one'
# The two divergences the memory half was measured to have (2026-11-04), each
# asserted through the REAL scan_memory_dir.  Before the shared classifier:
#   * a directory holding only an empty file reported scanned(1-NOT-TEXT) -- an
#     empty file has no byte, so no NUL; reporting it was simply wrong.
#   * a Finder .DS_Store beside a real note reported scanned(1-NOT-TEXT), i.e.
#     the whole check went PART over an artifact every macOS user has.
mkdir -p "$mj_root/onlyempty"
: >"$mj_root/onlyempty/note.md"
mj_expect 'empty(NOT-verified)' 0 "$mj_root/onlyempty" 'a directory holding only an empty file'
mkdir -p "$mj_root/onlyjunk"
printf '\x00\x00\x00\x01Bud1' >"$mj_root/onlyjunk/.DS_Store"
mj_expect 'empty(NOT-verified)' 0 "$mj_root/onlyjunk" 'a directory holding only Finder junk'
mkdir -p "$mj_root/junkplus"
printf '\x00\x00\x00\x01Bud1' >"$mj_root/junkplus/.DS_Store"
printf 'a real memory note, nothing to find\n' >"$mj_root/junkplus/note.md"
mj_expect scanned 0 "$mj_root/junkplus" 'Finder junk beside a real note'
mkdir -p "$mj_root/emptyplus"
: >"$mj_root/emptyplus/note.md"
printf 'a real memory note, nothing to find\n' >"$mj_root/emptyplus/other.md"
mj_expect scanned 0 "$mj_root/emptyplus" 'an empty file beside a real note'
mkdir -p "$mj_root/pycplus"
printf 'not really bytecode\n' >"$mj_root/pycplus/stale.pyc"
printf 'a real memory note, nothing to find\n' >"$mj_root/pycplus/note.md"
mj_expect scanned 0 "$mj_root/pycplus" 'a .pyc beside a real note'
if mkdir -p "$mj_root/locked" 2>/dev/null && printf 'x\n' >"$mj_root/locked/a.md" &&
    chmod 000 "$mj_root/locked" 2>/dev/null && [ ! -r "$mj_root/locked" ]; then
    mj_expect 'empty(NOT-verified)' 0 "$mj_root/locked" 'an unreadable directory'
    chmod 700 "$mj_root/locked" 2>/dev/null || true
    rm -rf -- "$mj_root/locked"
else
    # Running as root: chmod 000 reads as readable, so the state is unreachable
    # HERE.  Say so rather than letting the case vanish quietly.  Deliberately
    # `skipped(...)` and not a NOT-covered token: run-tests routes the former
    # to PART (visible, honest) and the latter to the known-set gate, where a
    # check name that is not listed would turn the suite RED on a root host --
    # a whole-suite failure for a self-test sub-case, which is the wrong
    # severity.  CI runners are unprivileged and never reach this branch.
    printf '%s\n' 'self-test: skipped(needs-unprivileged-user) -- the unreadable-directory memory state was not exercised; root reads through chmod 000' >&2
    chmod 700 "$mj_root/locked" 2>/dev/null || true
    rm -rf -- "$mj_root/locked"
fi
rm -rf -- "$mj_root"

# --- the rule set must be wired everywhere it is declared -------------------
# The summary's `rules=7` was a literal in the final printf (measured
# 2026-10-27: nothing computed it, so adding a rule or wiring one into only
# some of the places that must know it could not change the number).  The
# count is derived from the RE_Rn definitions below, and every defined rule
# must be wired into BOTH places that have to know it: first_match's case arm
# (the self-test's dispatcher) and scan_file's body (the real scan).  A rule
# defined but wired into one of them is exactly the drift this file's header
# warns about -- the self-test that was written and never called.
self_name=${BASH_SOURCE[0]##*/}
self_path="$root/smoke/$self_name"
rules_defined=$(grep -oE '^RE_R[0-9]+=' "$self_path" | sed -E 's/^RE_(R[0-9]+)=/\1/' | sort -u || true)
rules_count=$(printf '%s\n' "$rules_defined" | grep -c . || true)
if [ "$rules_count" -eq 0 ]; then
    printf 'self-test: no RE_Rn rule is defined; the scan would check nothing\n' >&2
    selftest_failures=$((selftest_failures + 1))
fi
scan_body=$(awk '/^scan_file\(\) \{/ { in_fn = 1 }
                 in_fn { print }
                 in_fn && /^\}/ { exit }' "$self_path")
for rule_name in $rules_defined; do
    if ! grep -qF "\$RE_${rule_name}" <<< "$scan_body"; then
        printf 'self-test: rule %s is defined but scan_file never greps with $RE_%s; it would never run\n' \
            "$rule_name" "$rule_name" >&2
        selftest_failures=$((selftest_failures + 1))
    fi
    if ! grep -qE "^    ${rule_name}\)" "$self_path"; then
        printf 'self-test: rule %s is defined but first_match has no %s) arm; the self-test cannot calibrate it\n' \
            "$rule_name" "$rule_name" >&2
        selftest_failures=$((selftest_failures + 1))
    fi
done

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
# A file judged binary by NUL bytes alone is REPORTED, not silently skipped:
# a text leak can hide behind one stray NUL (e.g. a UTF-16 or damaged file),
# and a silent continue made that file invisible to all seven rules while the
# files= counter still grew (measured 2026-10-13, review round 4).
tree_scanned=0
while IFS= read -r file; do
    case $(classify_file "$file") in
        scan) ;;
        not-text)
            printf 'no-host-identifiers: skipped a file that looks binary by NUL bytes (it could hide a text leak): %s\n' "$file" >&2
            continue
            ;;
        *) continue ;;
    esac
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
# cannot read as a clean scan.  The scan itself is scan_memory_dir (defined
# above, next to scan_file) -- one implementation, so the self-test exercises
# the code that actually runs.
#
# `find`'s stderr is discarded INSIDE scan_memory_dir, and that is safe because
# the function reports the same fact itself: a directory whose enumeration
# comes back empty (unreadable or genuinely empty) becomes `empty(NOT-verified)`
# and the SKIPPED line names the path, so the operator learns both that it was
# not verified and which directory.  A discarded stderr with no state change is
# the shape this whole class is about; a discarded stderr WITH a named state is
# not.
if [ -d "$memory_dir" ]; then
    scan_memory_dir "$memory_dir"
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

#    Measured 2026-11-03: the old literal `memory=scanned` was printed on the
# success path, so every OTHER state returned by scan_memory_dir was invisible
# in the run-tests summary line -- an empty directory or a NUL-bearing file
# reported "scanned" alongside the same truth.  A derived token makes any new
# degraded state VISIBLE; whether it must go RED is a gate decision (ci.yml's
# pinned pattern above), not something a silent fallback gets to choose.
# A run that could not scan memory is a PARTIAL verification.  Exiting 0 here
# would be printed by run-tests.sh as `ok`, which is the false green this
# suite's doctrine calls out ("SKIP is not PASS").  Emitting SKIPPED routes it
# to the SKIP column, and the summary line then adds NOT A FULL PASS.  Measured:
# without this, dropping the memory scan entirely printed
# `ok ... memory=absent(NOT-verified)` and the run still exited 0.
if [ "$memory_state" != scanned ]; then
    printf 'no-host-identifiers: SKIPPED (memory directory at %s reports %s; the repo scan ran but that part of the memory half is NOT verified)\n' \
        "$memory_dir" "$memory_state"
    exit 0
fi

printf 'no-host-identifiers checks passed: files=%s rules=%s selftest=calibrated memory=%s violations=%s\n' \
    "$scanned" "$rules_count" "$memory_state" "$failures"
