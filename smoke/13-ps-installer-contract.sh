#!/usr/bin/env bash
# Smoke: assets/windows-git-bash/install-agentq.ps1 -- its parameter contract and
# its platform gate.  This file is the second-largest asset in the repo (3,072
# lines) and, before this check, nothing had ever executed it: 01 parses it with
# the PowerShell AST and 10 asserts four source-level invariants about it, but
# neither runs it.  (2026-10-07: it gained the W5 crash-leftover guard, which IS
# driven here -- see the W5 section at the bottom.)
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
# AGENTQ_SMOKE_INSTALLER points this check at a mutated copy of the installer;
# same convention as smoke/05 and smoke/07 (their AGENTQ_SMOKE_CLIENT).
installer="${AGENTQ_SMOKE_INSTALLER:-$root/skill/assets/windows-git-bash/install-agentq.ps1}"
stage_source="$root/skill/assets/windows-git-bash"
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

# --- W5: crash-leftover detection, driven on the extracted functions ----------
# The installer's platform gate makes the whole file unrunnable here, but
# Find-AgentQCrashLeftovers / Assert-NoCrashLeftoverTransactions are pure .NET:
# extract them (same AST technique as smoke/22/23/25) and drive them against a
# real directory tree.  This is the only way to give the W5 refusal a behavioural
# lock without a Windows host, and it is the half that CAN be verified off-box --
# the swap itself still needs Windows.
extract_script="$work/w5-extract.ps1"
cat > "$extract_script" <<'EXTRACT'
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$installerPath = $args[0]
$workDir = $args[1]
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { [Console]::Error.WriteLine("installer did not parse"); exit 3 }
$wanted = @("Find-AgentQCrashLeftovers", "Assert-NoCrashLeftoverTransactions")
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$source = [System.Text.StringBuilder]::new()
foreach ($name in $wanted) {
    $match = $functions | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($null -eq $match) { [Console]::Error.WriteLine("missing function: $name"); exit 3 }
    [void]$source.AppendLine($match.Extent.Text)
}
Invoke-Expression $source.ToString()

$parent = Join-Path $workDir "programdata"
$root = Join-Path $parent "AgentQ"
[System.IO.Directory]::CreateDirectory($parent) | Out-Null

function Reset-Tree {
    foreach ($d in @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Expect-Refusal([string]$label, [string]$fragment) {
    # Assert the DIRECTION, not just that something was thrown: the two refusal
    # messages carry different recovery guidance (move the backup back vs. inspect
    # a concurrent/crashed run), so a swapped condition must fail here.  Measured:
    # asserting only the "refusing to install:" prefix let a swapped-condition
    # mutation pass (mutation M6) -- a false green this fragment check closes.
    try {
        Assert-NoCrashLeftoverTransactions -ParentDirectory $parent -RootName "AgentQ" -RootDirectory $root
    } catch {
        if ($_.Exception.Message -notlike "refusing to install:*") {
            [Console]::Error.WriteLine("W5 ${label}: threw, but not the controlled refusal: $($_.Exception.Message)"); exit 1
        }
        if ($_.Exception.Message -notlike "*$fragment*") {
            [Console]::Error.WriteLine("W5 ${label}: refused for the wrong reason (wanted *$fragment*): $($_.Exception.Message)"); exit 1
        }
        return
    }
    [Console]::Error.WriteLine("W5 ${label}: did NOT refuse"); exit 1
}
function Expect-Pass([string]$label) {
    try {
        Assert-NoCrashLeftoverTransactions -ParentDirectory $parent -RootName "AgentQ" -RootDirectory $root
    } catch {
        [Console]::Error.WriteLine("W5 ${label}: refused a clean tree: $($_.Exception.Message)"); exit 1
    }
}

# 1. Clean tree, no root: a genuine fresh install must PROCEED (this is the
#    direction that keeps a guard from being "refuse everything").
Reset-Tree
Expect-Pass "clean-no-root"

# 2. Clean tree WITH a root: a normal upgrade must PROCEED.
Reset-Tree
[System.IO.Directory]::CreateDirectory($root) | Out-Null
Expect-Pass "clean-with-root"

# 3. THE DEFECT: root missing, `.AgentQ.backup.1234` present -> refuse.
Reset-Tree
[System.IO.Directory]::CreateDirectory((Join-Path $parent ".AgentQ.backup.1234")) | Out-Null
Expect-Refusal "missing-root-with-backup" "is missing but a previous run's transaction residue exists"
# ...and the recovery guidance must name the daemon restart (a crashed run has
# already stopped the daemon, so moving the backup back alone leaves the operator
# stuck on the NEXT check).  Same measured reason as smoke/11.
Expect-Refusal "missing-root-names-daemon-restart" "restart the AgentQ daemon"

# 4. A stage leftover beside a missing root -> refuse.
Reset-Tree
[System.IO.Directory]::CreateDirectory((Join-Path $parent ".AgentQ.stage.999")) | Out-Null
Expect-Refusal "missing-root-with-stage" "is missing but a previous run's transaction residue exists"

# 5. Residue beside a PRESENT root -> refuse too (crash after swap / concurrent).
Reset-Tree
[System.IO.Directory]::CreateDirectory($root) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $parent ".AgentQ.backup.4242")) | Out-Null
Expect-Refusal "present-root-with-backup" "exists beside the AgentQ root"

# 6. A directory that merely LOOKS similar must NOT be flagged: no leading dot,
#    or a different root name.  Guards against a too-loose pattern.
Reset-Tree
[System.IO.Directory]::CreateDirectory($root) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $parent "AgentQ.backup.7")) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $parent ".OtherRoot.backup.7")) | Out-Null
Expect-Pass "lookalike-not-flagged"

# 7. The scan itself must FAIL CLOSED: if the parent cannot be listed (here it
#    does not exist), the guard must refuse rather than see "no residue" and
#    proceed.  A `-ErrorAction SilentlyContinue` here would let an unreadable
#    directory bypass the guard exactly as a missing root does.
Reset-Tree
Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue
Expect-Refusal "unlistable-parent" "cannot inspect"
[System.IO.Directory]::CreateDirectory($parent) | Out-Null

[Console]::Out.WriteLine("W5-OK")
EXTRACT

cases=$((cases + 1))
w5_status=0
w5_out=$("$pwsh_binary" -NoProfile -NonInteractive -File "$extract_script" "$installer" "$work" 2>"$work/w5.err") || w5_status=$?
if [ "$w5_status" -ne 0 ] || [ "$w5_out" != "W5-OK" ]; then
    printf 'ps-installer (W5 crash-leftover): the guard failed: %s\n' \
        "$(head -2 "$work/w5.err" | tr '\n' ' ')" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'ps-installer-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'ps-installer-contract checks passed: cases=%s pwsh=%s crash-leftover=covered staging=NOT-covered(needs-Windows)\n' \
    "$cases" "$("$pwsh_binary" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
