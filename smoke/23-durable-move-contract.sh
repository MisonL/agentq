#!/usr/bin/env bash
# Smoke: assets/windows-git-bash/agentq-durable-move.ps1 -- its parameter
# contract, plus the source-level invariant that a real Windows defect produced.
#
# Why this check exists: 118 lines, and before this file NO check had ever looked
# at it except 01's AST parse.  It is the asset where the FIRST native-Windows
# defect of this project lived -- the one that, in the field, made the operation
# lock un-acquirable on Windows and surfaced ~85s later as the misleading
# "AgentQ operation is already in progress" (CLAUDE.md, docs/PLAN.md A5's sibling).
#
# WHAT RUNS HERE: the parameter contract (four measured messages, exactly as
# smoke/13 does for the installer).  On this machine every valid invocation dies
# inside the kernel32 P/Invoke -- MoveAndFlush calls CreateFile against
# kernel32.dll, which does not exist here -- so the move/flush BEHAVIOUR is
# unreachable and is NOT covered.  That needs a real Windows host.
#
# WHAT IS PINNED AT SOURCE LEVEL: the access mask.  The defect was
# `FlushFileBuffers` failing with ERROR_ACCESS_DENIED (5) because the handle was
# opened GenericRead only; FlushFileBuffers requires GENERIC_WRITE.  The fix set
# `GenericRead | GenericWrite`.  That single constant is the whole fix, it lives
# in one place, and nothing but a real Windows host would notice a regression --
# so it is asserted here the way smoke/10 pins the ACL property name: the exact
# invariant, not a heuristic.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
asset="$root/skill/assets/windows-git-bash/agentq-durable-move.ps1"
[ -f "$asset" ] || { printf '%s\n' 'durable-move-contract: missing asset' >&2; exit 1; }

# AGENTQ_SMOKE_PWSH selects the interpreter, exactly as smoke/12/20/22 do.  The
# CI windows job sets it to powershell.exe to run under real PowerShell 5.1 --
# without this, 23 silently used whatever `pwsh` was on PATH (7.x on the runner)
# while the job's comment counted it as 5.1 evidence.  Measured 2026-10-13.
pwsh_binary=${AGENTQ_SMOKE_PWSH:-$(command -v pwsh || true)}
if [ -z "$pwsh_binary" ]; then
    printf '%s\n' 'SKIPPED: pwsh is not available; the parameter contract was not executed'
    exit 0
fi
# A bogus override (typo'd path) must not read as contract failures -- the same
# shape 12's guard pins: pwsh-unusable is an environment fault, not an asset one.
if ! command -v "$pwsh_binary" >/dev/null 2>&1; then
    printf 'SKIPPED: pwsh is not available (AGENTQ_SMOKE_PWSH=%s is not an executable on PATH)\n' "$pwsh_binary"
    exit 0
fi

work=$(mktemp -d /tmp/agentq-smoke-durable.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

failures=0
cases=0

# expect_rejected <label> <expected-stderr-fragment> [args...]
# Windows PowerShell 5.1 wraps error messages across lines (measured on CI,
# 2026-10-13: "...of one\nmore missing mandatory parameters..."), and pwsh 7
# colourises them; the fragment assertions are on the message text, so the
# stderr is ANSI-stripped and newline-joined before matching.  Under pwsh 7
# alone this normalization is invisible -- which is exactly why the pre-hook
# version of this check stayed green while never actually running under 5.1.
strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*m//g' "$1"; }
# flatten_err: strip ANSI, drop CR, join lines, collapse whitespace runs.  The
# CR drop matters: a 5.1 CRLF wrap keeps the trailing space of the wrapped line
# ("...of one \r\nmore..."), and the fragment spells it "one or more" -- without
# collapsing whitespace runs the 5.1 text does not match (measured 2026-10-13).
flatten_err() { strip_ansi "$1" | tr -d '\r' | tr '\n' ' ' | sed -E 's/ +/ /g'; }
expect_rejected() {
    local label=$1 expected=$2
    shift 2
    cases=$((cases + 1))
    local status=0
    "$pwsh_binary" -NoProfile -NonInteractive -File "$asset" "$@" >"$work/out" 2>"$work/err" || status=$?
    # PowerShell writes terminating errors to stderr and exits 1.  Assert non-zero
    # rather than exactly 1: the point is that the call was refused, and pinning
    # the numeric code would couple this to PowerShell's version.
    if [ "$status" -eq 0 ]; then
        printf 'durable-move %s: expected a non-zero exit, got 0\n' "$label" >&2
        failures=$((failures + 1))
        return
    fi
    if ! flatten_err "$work/err" | grep -qF -- "$expected"; then
        printf 'durable-move %s: stderr does not contain %s\n' "$label" "$expected" >&2
        strip_ansi "$work/err" | head -2 >&2 || true
        failures=$((failures + 1))
    fi
}

# --- the parameter contract ---------------------------------------------------
# All three parameters are mandatory and must be non-empty.  These messages were
# MEASURED off the asset, not guessed -- the recurring trap in this repo.
expect_rejected 'no arguments' \
    'Cannot process command because of one or more missing mandatory parameters: SourcePath DestinationPath DestinationDirectory.'
expect_rejected 'missing value' \
    "Missing an argument for parameter 'SourcePath'." -SourcePath
expect_rejected 'empty value' \
    "Cannot validate argument on parameter 'SourcePath'." -SourcePath '' -DestinationPath "$work/b" -DestinationDirectory "$work"
expect_rejected 'unknown parameter' \
    "A parameter cannot be found that matches parameter name 'Bogus'." -SourcePath "$work/a" -DestinationPath "$work/b" -DestinationDirectory "$work" -Bogus x

# --- the access-mask invariant (the real Windows defect) ----------------------
# The handle used for FlushFileBuffers must request write access.  Read the
# `access` line out of OpenForFlush and require BOTH GenericRead and GenericWrite.
# This is the fix for the defect where a read-only handle made FlushFileBuffers
# fail with ERROR_ACCESS_DENIED and the lock could never be acquired on Windows.
cases=$((cases + 1))
# `|| true`: a renamed access line must reach the diagnostic below, not abort
# the check with no output (same pipefail class as smoke/06).
access_line=$(grep -nE 'uint access = ' "$asset" | head -1) || true
if [ -z "$access_line" ]; then
    printf 'durable-move: could not find the access-mask line in OpenForFlush\n' >&2
    failures=$((failures + 1))
elif ! printf '%s' "$access_line" | grep -q 'GenericRead | GenericWrite'; then
    printf 'durable-move: FlushFileBuffers handle no longer requests write access: %s\n' "$access_line" >&2
    printf '%s\n' '  (FlushFileBuffers requires GENERIC_WRITE; a read-only handle fails with ERROR_ACCESS_DENIED)' >&2
    failures=$((failures + 1))
fi

# FlushFileBuffers must be reached with that handle, i.e. OpenForFlush must feed
# FlushPath.  If a future edit inlined a read-only CreateFile elsewhere the line
# above would still pass; this ties the constant to its only consumer.
cases=$((cases + 1))
if ! grep -q 'OpenForFlush' "$asset" || ! grep -q 'FlushFileBuffers(handle)' "$asset"; then
    printf 'durable-move: the flush path no longer goes through OpenForFlush\n' >&2
    failures=$((failures + 1))
fi

# MoveFileEx must ask for write-through, or the rename is not durable.
cases=$((cases + 1))
if ! grep -q 'MoveFileReplaceExisting | MoveFileWriteThrough' "$asset"; then
    printf 'durable-move: MoveFileEx no longer uses MoveFileWriteThrough\n' >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'durable-move-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'durable-move-contract checks passed: cases=%s contract=covered access-mask=pinned behaviour=NOT-covered(needs-Windows)\n' "$cases"
