#!/usr/bin/env bash
# Smoke: assets/windows-git-bash/install-agentq.ps1 -- its parameter contract and
# its platform gate.  This file is the second-largest asset in the repo (2,881
# lines) and, before this check, nothing had ever executed it: 01 parses it with
# the PowerShell AST and 10 asserts four source-level invariants about it, but
# neither runs it.
#
# THE LIMIT, stated up front because it decides what this file is allowed to
# claim.  Measured on this machine: with ANY argument combination the installer
# dies at its first statement, Resolve-GitBashPaths, with
#   Exception calling "GetCurrent" ... "Windows Principal functionality is not
#   supported on this platform."
# so the platform gate runs BEFORE the staging validation.  That ordering is
# measured, not assumed: a nonexistent stage directory and a fully populated one
# produce the identical error.  Consequence: the staging / asset / sha256 /
# ACL / transaction behaviour of this installer is UNREACHABLE off Windows and
# is NOT covered here -- closing that needs a real Windows host.  What this
# check does cover is real and worth having: the parameter contract (four
# measured messages) and the platform gate's most important property -- it must
# fail before doing anything, not half-install and then die.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
installer="$root/assets/windows-git-bash/install-agentq.ps1"
stage_source="$root/assets/windows-git-bash"
pwsh_binary=$(command -v pwsh || true)

if [ -z "$pwsh_binary" ]; then
    printf '%s\n' 'SKIPPED: pwsh is not available; the Windows installer was not executed'
    exit 0
fi

work=$(mktemp -d /tmp/agentq-smoke-psinstaller.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

failures=0
cases=0

# expect_rejected <expected-stderr-fragment> [args...]
#
# The installer's own parameter binding rejects these before a single statement
# of the script body runs, so nothing is written anywhere; the exit code is 1
# (PowerShell's terminating-error code), not the 2 the POSIX installer uses.
expect_rejected() {
    local expected=$1
    shift
    local label=$*
    cases=$((cases + 1))
    local status=0
    (cd "$work" && HOME="$work/home" "$pwsh_binary" -NoProfile -NonInteractive \
        -File "$installer" "$@" >"$work/out" 2>"$work/err") || status=$?
    if [ "$status" -eq 0 ]; then
        printf 'ps-installer %s: expected a non-zero exit, got 0\n' "${label:-<no args>}" >&2
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/err"; then
        printf 'ps-installer %s: stderr does not contain %s\n' "${label:-<no args>}" "$expected" >&2
        head -2 "$work/err" >&2 || true
        failures=$((failures + 1))
    fi
}

mkdir -p "$work/home"

# --- the parameter contract ---------------------------------------------------
# -StageDirectory is mandatory, must be non-empty, and unknown parameters are
# refused.  These four messages were measured off the installer rather than
# guessed -- the first version of this file asserted wording that does not exist.
expect_rejected 'Cannot process command because of one or more missing mandatory parameters: StageDirectory.'
expect_rejected "Missing an argument for parameter 'StageDirectory'." -StageDirectory
expect_rejected "Cannot validate argument on parameter 'StageDirectory'." -StageDirectory ''
expect_rejected "A parameter cannot be found that matches parameter name 'Bogus'." -Bogus x

# --- the platform gate --------------------------------------------------------
# A valid invocation on a non-Windows platform must fail without side effects.
# The stage directory is populated with every asset the installer's own staging
# list requires, so the ONLY thing that can stop it here is the platform gate --
# if a future edit moves staging validation ahead of the gate, this case starts
# exercising that path and will say so.
stage="$work/stage"
mkdir -p "$stage"
for asset in agentq agentq-launcher.ps1 agentq-start-daemon.ps1 agentq-durable-move.ps1 pueue.yml; do
    cp "$stage_source/$asset" "$stage/$asset"
done
stage_before=$(find "$stage" -type f -exec shasum -a 256 {} + | LC_ALL=C sort)

cases=$((cases + 1))
gate_status=0
(cd "$work" && HOME="$work/home" "$pwsh_binary" -NoProfile -NonInteractive \
    -File "$installer" -StageDirectory "$stage" >"$work/gate.out" 2>"$work/gate.err") || gate_status=$?
if [ "$gate_status" -eq 0 ]; then
    printf '%s\n' 'ps-installer: a non-Windows run exited 0 instead of failing' >&2
    failures=$((failures + 1))
elif ! grep -qF 'Windows Principal functionality is not supported on this platform' "$work/gate.err"; then
    printf 'ps-installer: the platform gate reported something unexpected: %s\n' \
        "$(head -1 "$work/gate.err")" >&2
    failures=$((failures + 1))
fi

# The gate must run BEFORE staging validation -- that ordering is the whole
# reason this file can say anything at all off Windows, and it is the thing a
# future edit could silently invert.  An EMPTY stage directory proves it: if the
# gate still runs first the error is the platform error, and if the ordering
# ever flips the error becomes a missing-asset error instead.  (Measured before
# this case existed: a nonexistent stage directory and a fully populated one
# produce the identical platform error.)
empty_stage="$work/empty-stage"
mkdir -p "$empty_stage"
cases=$((cases + 1))
empty_status=0
(cd "$work" && HOME="$work/home" "$pwsh_binary" -NoProfile -NonInteractive \
    -File "$installer" -StageDirectory "$empty_stage" >"$work/empty.out" 2>"$work/empty.err") || empty_status=$?
if [ "$empty_status" -eq 0 ]; then
    printf '%s\n' 'ps-installer: an empty stage directory did not fail' >&2
    failures=$((failures + 1))
elif ! grep -qF 'Windows Principal functionality is not supported on this platform' "$work/empty.err"; then
    printf 'ps-installer: staging validation now runs before the platform gate: %s\n' \
        "$(head -1 "$work/empty.err")" >&2
    failures=$((failures + 1))
fi
if [ -n "$(find "$empty_stage" -mindepth 1 -print -quit)" ]; then
    printf '%s\n' 'ps-installer: the empty stage directory was written to' >&2
    failures=$((failures + 1))
fi

# ...and it must not have modified the staged assets it was handed.
stage_after=$(find "$stage" -type f -exec shasum -a 256 {} + | LC_ALL=C sort)
if [ "$stage_before" != "$stage_after" ]; then
    printf '%s\n' 'ps-installer: the platform gate modified the staged assets' >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'ps-installer-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'ps-installer-contract checks passed: cases=%s pwsh=%s staging=NOT-covered(needs-Windows)\n' \
    "$cases" "$("$pwsh_binary" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
