#!/usr/bin/env bash
# Smoke: the npm copier (`bin/agentq-skill.js`) behaves as documented.
#
# Why this check exists.  `bin/agentq-skill.js` is a PUBLISHED artifact -- the
# only thing `npx agentq-skill` runs -- and until now its entire coverage was
# `node --check` plus an exec-bit list in check 01.  Syntax is not behaviour:
# the exit codes, the file count, the canonical-pair invariant and the drift
# report were all untested, so the two defects an audit found there (a `--check`
# that ignored extra files, and an install that never removes them) had nowhere
# to show up.
#
# What it proves: `--dest` writes the 30 manifest files with the documented
# modes; a second install of the same version is idempotent; `--check` exits 0
# on a clean tree and names the specific problem otherwise (tampered bytes, a
# stray file, a missing execute bit); a destination that is a symlink or a
# regular file is refused with 2.  What it does NOT prove: that npm packs the
# right files (that is `scripts/verify-pack.js`) or that the copied Skill is
# any good (that is the summary checks).
set -u

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
copier=$root/bin/agentq-skill.js

if ! command -v node >/dev/null 2>&1; then
    printf '%s\n' 'SKIPPED (no-node): the npm copier needs node; nothing here was verified'
    exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/agentq-skill-copier.XXXXXX")
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT

cases=0
failures=0
note() { printf '  %s\n' "$*" >&2; }

# --- 1. a fresh install writes the whole manifest --------------------------
dest=$work/dest
cases=$((cases + 1))
state=0
node "$copier" --dest "$dest" >"$work/install.out" 2>"$work/install.err" || state=$?
if [ "$state" -ne 0 ]; then
    note "install exited $state: $(head -2 "$work/install.err" | tr '\n' '|')"
    failures=$((failures + 1))
fi

listed=$(node "$copier" --list) || { note 'the copier cannot list its own manifest'; failures=$((failures + 1)); }
listed_count=$(printf '%s\n' "$listed" | grep -c . || true)

cases=$((cases + 1))
# Cross-check against GIT, not against a number.  A lower bound of 25 tolerated
# a manifest that had silently lost five files (measured 2026-11-27): every
# remaining file would still compare byte-for-byte, because `--list`, the copy
# and `--check` all read the SAME list.  `git ls-files` is the independent side.
if [ -d "$root/.git" ] && command -v git >/dev/null 2>&1; then
    cases=$((cases + 1))
    git_listed=$(git -C "$root" ls-files skill | LC_ALL=C sort)
    if [ "$(printf '%s\n' "$git_listed")" != "$(printf '%s\n' "$listed" | LC_ALL=C sort)" ]; then
        note "the copier's manifest and 'git ls-files skill' disagree:"
        printf '%s\n' "$listed" | LC_ALL=C sort > "$work/manifest.sorted"
        printf '%s\n' "$git_listed" > "$work/git.sorted"
        diff -u "$work/git.sorted" "$work/manifest.sorted" | sed 's/^/    /' >&2
        failures=$((failures + 1))
    fi
fi
if [ "$listed_count" -lt 25 ]; then
    note "the manifest lists only $listed_count files; refusing to compare against that"
    failures=$((failures + 1))
fi

# Every listed file must exist on disk with the same bytes -- under the
# DESTINATION name, which drops the package's `skill/` prefix.  `--dest` names a
# Skill directory, the thing a loader looks for `SKILL.md` in, and the package
# root is the repository root.
cases=$((cases + 1))
missing=0
for manifest_file in $listed; do
    installed_name=${manifest_file#skill/}
    if [ ! -f "$dest/$installed_name" ]; then
        note "listed but not installed: $installed_name"
        missing=$((missing + 1))
    elif ! cmp -s "$root/$manifest_file" "$dest/$installed_name"; then
        note "bytes differ after the copy: $installed_name"
        missing=$((missing + 1))
    fi
done
[ "$missing" -eq 0 ] || failures=$((failures + 1))

# --- 1b. the layout a Skill loader actually needs --------------------------
# Measured 2026-11-27: the copier joined the manifest path straight onto
# `--dest`, so `--dest ~/.agents/skills/agentq` (also the default) produced
# `~/.agents/skills/agentq/skill/SKILL.md`.  A loader asking for
# `<dir>/SKILL.md` found nothing, and `--check` could not validate a correctly
# installed Skill either.  Asserting the SHAPE is what keeps this from coming
# back: the byte loop above would happily follow the prefix anywhere.
cases=$((cases + 1))
layout_gaps=0
for required in SKILL.md agents references assets; do
    if [ ! -e "$dest/$required" ]; then
        note "the destination is missing $required at its root (the copier nested the package prefix?)"
        layout_gaps=$((layout_gaps + 1))
    fi
done
if [ -e "$dest/skill" ]; then
    note "the destination contains a nested skill/ directory: --dest is a Skill root, not the package root"
    layout_gaps=$((layout_gaps + 1))
fi
[ "$layout_gaps" -eq 0 ] || failures=$((failures + 1))

# The canonical pair is the package's hard invariant; it must survive a copy.
cases=$((cases + 1))
if ! cmp -s "$dest/assets/unix/agentq-server" "$dest/assets/windows-git-bash/agentq"; then
    note 'the two canonical server copies differ after the copy'
    failures=$((failures + 1))
fi

# --- 2. --check on the fresh install is clean ------------------------------
cases=$((cases + 1))
state=0
node "$copier" --dest "$dest" --check >"$work/check.out" 2>"$work/check.err" || state=$?
if [ "$state" -ne 0 ]; then
    note "--check exited $state on a tree it had just written: $(head -2 "$work/check.err" | tr '\n' '|')"
    failures=$((failures + 1))
fi
# ...and it must SAY it saw no extras.  A bare "matches" would also have passed
# before 2026-11-27, when the extra-file arm did not exist.
cases=$((cases + 1))
if ! grep -q 'no extras' "$work/check.out"; then
    note "--check no longer reports the extras scan: $(head -1 "$work/check.out")"
    failures=$((failures + 1))
fi

# --- 3. a second install is idempotent ------------------------------------
cases=$((cases + 1))
state=0
node "$copier" --dest "$dest" >/dev/null 2>"$work/reinstall.err" || state=$?
if [ "$state" -ne 0 ]; then
    note "a second install of the same version exited $state: $(head -2 "$work/reinstall.err" | tr '\n' '|')"
    failures=$((failures + 1))
fi

# --- 4. each drift shape is NAMED, not merely counted ---------------------
expect_drift() { # $1=label $2=expected substring $3=setup command
    cases=$((cases + 1))
    local label=$1 expected=$2
    eval "$3"
    local state=0
    node "$copier" --dest "$dest" --check >"$work/$label.out" 2>"$work/$label.err" || state=$?
    if [ "$state" -ne 1 ]; then
        note "$label: exit=$state, expected 1: $(head -2 "$work/$label.err" | tr '\n' '|')"
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/$label.err"; then
        note "$label: stderr does not name [$expected]: $(head -2 "$work/$label.err" | tr '\n' '|')"
        failures=$((failures + 1))
    fi
}

expect_drift extra-file 'not part of this package' \
    ': >"$dest/stale.txt"'
rm -f "$dest/stale.txt"

# A stray file in a SUBDIRECTORY is the shape that matters: a renamed reference
# would leave one behind, and a top-level-only scan would miss it.
expect_drift extra-nested 'not part of this package' \
    ': >"$dest/references/stale-note.md"'
rm -f "$dest/references/stale-note.md"

expect_drift missing-file 'missing or different' \
    'rm -f "$dest/SKILL.md"'
node "$copier" --dest "$dest" >/dev/null 2>&1 || true

expect_drift tampered-bytes 'missing or different' \
    'printf "\n# tampered\n" >>"$dest/SKILL.md"'
node "$copier" --dest "$dest" >/dev/null 2>&1 || true

expect_drift no-execute-bit 'not executable' \
    'chmod 644 "$dest/assets/unix/agentq-server"'
node "$copier" --dest "$dest" >/dev/null 2>&1 || true

# --- 5. an unsafe destination is refused with the controlled 2 ------------
cases=$((cases + 1))
link_target=$work/linked-dest
mkdir -p "$link_target"
ln -s "$link_target" "$work/symlink-dest"
state=0
node "$copier" --dest "$work/symlink-dest" >/dev/null 2>"$work/symlink.err" || state=$?
if [ "$state" -ne 2 ]; then
    note "a symlinked destination exited $state, expected the controlled 2"
    failures=$((failures + 1))
fi

cases=$((cases + 1))
: >"$work/plain-file"
state=0
node "$copier" --dest "$work/plain-file" >/dev/null 2>"$work/plainfile.err" || state=$?
if [ "$state" -ne 2 ]; then
    note "a destination that is a regular file exited $state, expected the controlled 2"
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'skill-copier: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'skill-copier checks passed: cases=%s manifest=%s layout=skill-root extras=named drift=named/extra/nested/missing/tampered/mode unsafe=symlink+file canonical=equal\n' \
    "$cases" "$listed_count"
