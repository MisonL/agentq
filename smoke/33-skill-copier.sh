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
if [ "$listed_count" -lt 25 ]; then
    note "the manifest lists only $listed_count files; refusing to compare against that"
    failures=$((failures + 1))
fi

# Every listed file must exist on disk with the same bytes.
cases=$((cases + 1))
missing=0
for manifest_file in $listed; do
    if [ ! -f "$dest/$manifest_file" ]; then
        note "listed but not installed: $manifest_file"
        missing=$((missing + 1))
    elif ! cmp -s "$root/$manifest_file" "$dest/$manifest_file"; then
        note "bytes differ after the copy: $manifest_file"
        missing=$((missing + 1))
    fi
done
[ "$missing" -eq 0 ] || failures=$((failures + 1))

# The canonical pair is the package's hard invariant; it must survive a copy.
cases=$((cases + 1))
if ! cmp -s "$dest/skill/assets/unix/agentq-server" "$dest/skill/assets/windows-git-bash/agentq"; then
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
    ': >"$dest/skill/references/stale-note.md"'
rm -f "$dest/skill/references/stale-note.md"

expect_drift missing-file 'missing or different' \
    'rm -f "$dest/skill/SKILL.md"'
node "$copier" --dest "$dest" >/dev/null 2>&1 || true

expect_drift tampered-bytes 'missing or different' \
    'printf "\n# tampered\n" >>"$dest/skill/SKILL.md"'
node "$copier" --dest "$dest" >/dev/null 2>&1 || true

expect_drift no-execute-bit 'not executable' \
    'chmod 644 "$dest/skill/assets/unix/agentq-server"'
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
printf 'skill-copier checks passed: cases=%s manifest=%s extras=named drift=named/extra/nested/missing/tampered/mode unsafe=symlink+file canonical=equal\n' \
    "$cases" "$listed_count"
