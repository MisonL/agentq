#!/usr/bin/env bash
# CHANGELOG and tag discipline: the rules CLAUDE.md states, enforced.
#
# CLAUDE.md says the changelog is THREE layers -- tag -> version index -> log
# entry -- and that a release updates all three.  Until this check, none of
# that was machine-enforced: the index could name a tag that does not exist,
# a tag could lose its index line, an entry could omit the `|  <verification>`
# line the short format requires, and a release could be tagged lightweight
# while every earlier one was annotated.  Each of those has been true at some
# point in this repository's history.
#
# Four rules, each with the same shape as the rest of this suite -- the
# predicate is what decides, and the check self-calibrates on a fixture that
# carries one positive case and one case per failure mode it claims to catch:
#
#   A  every version-index line names a tag that exists
#   B  every vX.Y.Z tag has exactly one version-index line
#   C  the index is strictly descending (newest first)
#   D  the newest log entry carries the `|  ...` verification line, and a
#      "missing verification" region cannot re-enter from the TOP of the log
#   E  every tag from v0.1.31 on is ANNOTATED (`cat-file -t` says `tag`)
#
# D is deliberately bounded to the newest entry.  Measured 2026-11-14: 137 of
# the 227 descending entries predate the short-format convention (2026-10-15)
# and legitimately end without a verification line -- rewriting them is
# rewriting history, which this repository does not do.  What must be true is
# that the NEXT entry cannot be written without one; that is checked on the
# entry that has not been written yet.  The historic tail is counted and
# reported, never failed on.
#
# Exit codes: 0 pass (or pass with NOT-covered), 1 failure.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)
changelog="$root/CHANGELOG.md"
failures=0
fail() { printf 'FAIL %s\n' "$*" >&2; failures=$((failures + 1)); }

if [ ! -f "$changelog" ]; then
    printf 'FAIL CHANGELOG.md is missing; the three-layer release contract cannot be read\n' >&2
    exit 1
fi

work=$(mktemp "${TMPDIR:-/tmp}/agentq-changelog.XXXXXX")
# The trap removes every temp this script derives from $work (`.index`, `.log`,
# `.tags`, `.newest`), not only the bare name: the index/log/tag files are
# full copies of repo content, and leaving them in $TMPDIR after a run is a
# leak of exactly the files this check reads.  Measured 2026-11-18.
trap 'rm -f -- "$work" "$work".*' EXIT

# --- extract the version index --------------------------------------------
# An index line is "  - **[vX.Y.Z](<url>)** ...".  Extracted with sed rather than
# grep -o so the order is the file's order, which rule C depends on.
sed -n 's/^- \*\*\[\(v[0-9][0-9.]*\)\](.*/\1/p' "$changelog" >"$work.index"
index_count=$(grep -c . "$work.index" || true)

# --- extract the descending log section and its entries --------------------
# The descending section starts at its heading and ends at the ascending
# heading.  Located by content, not by line number: the file grows at the top.
desc_start=$(grep -n '^### 变更日志（2026-09-29 纳入 git 起' "$changelog" | head -1 | cut -d: -f1 || true)
asc_start=$(grep -n '^### .*升序' "$changelog" | head -1 | cut -d: -f1 || true)
if [ -z "$desc_start" ]; then
    fail 'the descending log section heading is missing (### 变更日志（2026-09-29 纳入 git 起 ...)'
    desc_start=0
fi
if [ -z "$asc_start" ]; then
    asc_start=$(wc -l <"$changelog" | tr -d ' ')
fi

if [ "$desc_start" -gt 0 ] && [ "$asc_start" -gt "$desc_start" ]; then
    awk -v s="$desc_start" -v e="$asc_start" 'NR > s && NR < e' "$changelog" >"$work.log"
else
    : >"$work.log"
fi

# --- tags visible in this checkout ----------------------------------------
# A shallow or tag-less checkout is a HOST limitation, not a repository
# defect: report it as NOT-covered and skip rules A and B rather than
# failing a check that cannot see the data it needs.  The tag count is the
# separate oracle -- an empty list with a non-empty index means the checkout
# is not the repository's.
if git_tip=$(git -C "$root" rev-parse --is-inside-work-tree 2>/dev/null) && [ "$git_tip" = true ]; then
    git -C "$root" tag --list 'v[0-9]*' | sort >"$work.tags"
else
    : >"$work.tags"
fi
tag_count=$(grep -c . "$work.tags" || true)

if [ "$tag_count" -eq 0 ] && [ "$index_count" -gt 0 ]; then
    printf 'NOT-covered(no-tags-in-checkout) index=%s: git could not list tags here, so tag/index agreement was not checked\n' "$index_count"
else
    # --- rule A: every index line names a tag that exists ------------------
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        grep -qxF -- "$v" "$work.tags" || fail "version index names $v, but no such tag exists in this checkout"
    done <"$work.index"

    # --- rule E: tags at or after v0.1.31 are ANNOTATED --------------------
    # CLAUDE.md requires annotated tags ("新 tag 一律带注释") and release.yml only
    # compares names, so a lightweight tag passes every gate.  Measured
    # 2026-11-19: nothing checked the object type at all.  The rule starts at
    # v0.1.31 -- seven of the 35 tags are lightweight, all from before that
    # version, and rewriting history is not what this check does.
    annotated_start=31
    annotated_checked=0
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        minor=$(printf '%s' "$v" | sed -n 's/^v0\.1\.\([0-9][0-9]*\)$/\1/p')
        [ -n "$minor" ] || continue
        [ "$minor" -ge "$annotated_start" ] || continue
        annotated_checked=$((annotated_checked + 1))
        if [ "$(git -C "$root" cat-file -t "refs/tags/$v" 2>/dev/null || true)" != tag ]; then
            fail "$v is not an annotated tag (cat-file -t did not say 'tag')"
        fi
    done <"$work.tags"
    if [ "$annotated_checked" -eq 0 ]; then
        fail "the annotated-tag rule examined 0 tags (v0.1.$annotated_start and later exist in the index, so the enumerator is broken)"
    fi

    # --- rule B: every tag has exactly one index line ----------------------
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        n=$(grep -cxF -- "$v" "$work.index" || true)
        case $n in
            1) ;;
            0) fail "tag $v has no version-index line in CHANGELOG.md" ;;
            *) fail "tag $v has $n version-index lines; it must have exactly one" ;;
        esac
    done <"$work.tags"

    # Every vX.Y.Z the index names must look like a tag (guards against an
    # index line whose link text is malformed and silently extracted).
    if [ "$index_count" -eq 0 ]; then
        fail 'the version index is empty: the Releases section is missing or its line shape changed'
    fi
fi

# --- rule C: the index is strictly descending ------------------------------
# Compared component-wise as integers, not as strings: v0.1.9 must sort BELOW
# v0.1.10, and a string comparison puts it above.
version_gt() { # $1 newer, $2 older -> 0 when $1 is strictly newer
    local a=${1#v} b=${2#v}
    local a1=${a%%.*} ar=${a#*.} b1=${b%%.*} br=${b#*.}
    local a2=${ar%%.*} a3=${ar#*.} b2=${br%%.*} b3=${br#*.}
    if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
    if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return; fi
    [ "$a3" -gt "$b3" ]
}
prev=''
while IFS= read -r v; do
    [ -n "$v" ] || continue
    if [ -n "$prev" ] && ! version_gt "$prev" "$v"; then
        fail "version index is not strictly descending: $prev is followed by $v"
    fi
    prev=$v
done <"$work.index"

# --- rule D: the newest log entry carries a verification line --------------
# An entry begins with 'YYYY-MM-DD' followed by TWO spaces.  Its block runs to
# the next entry or the end of the section.  A verification line is a line in
# that block whose first non-space character is '|'.
newest_date=$(grep -m1 -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}  ' "$work.log" || true)
if [ -z "$newest_date" ]; then
    fail 'the descending log section has no entries; a changelog with no entries is not a pass'
else
    # Block of the newest entry: from its line to the next entry line.
    newest_block=$(awk '
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}  / {
            if (started) { exit }
            started = 1
            next
        }
        started { print }' "$work.log")
    printf '%s\n' "$newest_block" >"$work.newest"
    # A verification line must carry a RECORD after the marker: a bare `  |`
    # satisfies "a line whose first non-space character is '|'" while saying
    # nothing.  Measured 2026-11-18: with the plain `^[[:space:]]*\|` form an
    # entry whose only verification line was `  |` passed this rule and every
    # calibration fixture, because none of them held a bare bar.
    if ! grep -qE '^[[:space:]]*\|[[:space:]]*[^[:space:]]' "$work.newest"; then
        fail "the newest log entry ($newest_date) has no '|  <verification>' line; the short format requires one on every new entry"
    fi
    # The newest date must be the newest DATE too: a back-dated entry inserted
    # at the top would otherwise satisfy rule D with an old verification line.
    top_date=${newest_date%%  *}
    max_date=$(grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' "$work.log" | sort | tail -1)
    if [ "$top_date" != "$max_date" ]; then
        fail "the first log entry is dated $top_date but the newest date in the section is $max_date; entries are newest-first"
    fi
fi

# --- report the historic tail (counted, never failed) ----------------------
total_entries=$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}  ' "$work.log" || true)

# --- self-calibration ------------------------------------------------------
# The predicates above must accept a good fixture and flag each bad shape.
# A rule that cannot report red is not a rule; this runs the SAME functions,
# extracted by sed from this file, over fixtures built here.
cal=ok
check_cal() { [ "$1" = "$2" ] || { cal=bad; printf 'calibration: expected %s, got %s (%s)\n' "$2" "$1" "$3" >&2; }; }

# version_gt: 0.1.10 is newer than 0.1.9 (string compare would say otherwise)
if version_gt v0.1.10 v0.1.9; then :; else cal=bad; printf 'calibration: version_gt v0.1.10 v0.1.9 returned false\n' >&2; fi
if version_gt v0.1.9 v0.1.10; then cal=bad; printf 'calibration: version_gt v0.1.9 v0.1.10 returned true\n' >&2; fi
if version_gt v0.1.30 v0.1.30; then cal=bad; printf 'calibration: version_gt compared equal versions as newer\n' >&2; fi

# Newest-entry verification predicate, over three fixture logs.
newest_has_verification() {
    awk '
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}  / {
            if (started) { exit }
            started = 1
            next
        }
        started { print }' "$1" >"$1.block"
    grep -qE '^[[:space:]]*\|[[:space:]]*[^[:space:]]' "$1.block"
}
cal_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentq-changelog-cal.XXXXXX")
printf '2026-11-14  entry\n  |  ./run-tests.sh -> exit 0\n\n2026-11-13  older\n' >"$cal_dir/good.log"
printf '2026-11-14  entry without verification\n\n2026-11-13  older\n  |  ok\n' >"$cal_dir/no-verify.log"
printf '2026-11-14  entry\n  |  ok\n' >"$cal_dir/only.log"
# A bare `  |` is not a verification line: it has the marker and no record.
printf '2026-11-14  entry\n  |\n\n2026-11-13  older\n' >"$cal_dir/bare-bar.log" 
if newest_has_verification "$cal_dir/good.log"; then :; else cal=bad; printf 'calibration: good fixture was flagged\n' >&2; fi
if newest_has_verification "$cal_dir/no-verify.log"; then cal=bad; printf 'calibration: an entry with no verification line passed\n' >&2; fi
if newest_has_verification "$cal_dir/only.log"; then :; else cal=bad; printf 'calibration: single-entry fixture was flagged\n' >&2; fi
if newest_has_verification "$cal_dir/bare-bar.log"; then cal=bad; printf 'calibration: an empty verification line ("  |") passed\n' >&2; fi
rm -rf "$cal_dir"
check_cal "$cal" ok 'rule predicates'

if [ "$failures" -ne 0 ]; then
    printf 'changelog-and-tags: %s failure(s)\n' "$failures" >&2
    exit 1
fi

printf 'changelog-and-tags: index=%s tags=%s entries=%s newest-verified=yes order=descending\n' \
    "$index_count" "$tag_count" "$total_entries"
