#!/usr/bin/env bash
# Smoke: assets/client/windows/install-client.ps1 -- its parameter contract and
# its platform gate.
#
# Why this check exists: 496 lines, and until now nothing had ever EXECUTED it.
# smoke/10 asserts four source-level invariants about it (the ACL property names,
# the chmod ban, the read-back pairing) and smoke/01 parses it with the PowerShell
# AST, but neither runs it.  Its sibling -- the SERVER installer install-agentq.ps1
# -- got exactly this treatment in smoke/13; this closes the same gap for the
# client installer.
#
# THE LIMIT, stated up front because it decides what this file may claim.  The
# installer's very first statement after `Set-StrictMode` is a platform gate:
#
#     if (([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT)) { throw ... }
#
# so on macOS EVERY invocation dies there, before any file is touched.  Measured,
# not assumed: a run with a real destination directory leaves it empty (0 entries)
# and exits 1.  Consequence: the staging / ACL / atomic-move / PATH-update
# behaviour is UNREACHABLE off Windows and is NOT covered here -- closing that
# needs a real Windows host.  What this check covers is real and worth having:
# the parameter contract (measured messages), the platform gate, and -- the
# property a future edit could silently invert -- that the gate runs BEFORE any
# write, so a non-Windows run is a clean failure rather than a half-install.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
installer="$root/skill/assets/client/windows/install-client.ps1"
[ -f "$installer" ] || { printf '%s\n' 'ps-client-installer: missing asset' >&2; exit 1; }

pwsh_binary=$(command -v pwsh || true)
if [ -z "$pwsh_binary" ]; then
    printf '%s\n' 'SKIPPED: pwsh is not available; the client installer was not executed'
    exit 0
fi

work=$(mktemp -d /tmp/agentq-smoke-psclientinstaller.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/home"

failures=0
cases=0

# strip_ansi <file> -- PowerShell colourises its error output; the assertions are
# on the message text, which is wrapped in escape sequences on a tty-capable
# stderr.  Same handling smoke/13 relies on being absent -- this check normalises.
strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*m//g' "$1"; }

# run_installer [args...] -- runs the installer in the sandbox HOME, capturing
# status/stdout/stderr; prints the status.  HOME is redirected so a run that got
# past the gate could not touch the real user's .local/bin -- defence in depth,
# the gate itself already prevents it.
run_installer() {
    local status=0
    (cd "$work" && HOME="$work/home" "$pwsh_binary" -NoProfile -NonInteractive \
        -File "$installer" "$@" >"$work/out" 2>"$work/err") || status=$?
    printf '%s' "$status"
}

# expect_rejected <label> <expected-stderr-fragment> [args...]
#
# The installer's own parameter binder rejects these before a single statement of
# the body runs, so nothing is written anywhere; the exit code is 1 (PowerShell's
# terminating-error code), not the 2 the POSIX installer uses.
expect_rejected() {
    local label=$1 expected=$2
    shift 2
    cases=$((cases + 1))
    local status
    status=$(run_installer "$@")
    if [ "$status" -eq 0 ]; then
        printf 'ps-client-installer %s: expected a non-zero exit, got 0\n' "$label" >&2
        failures=$((failures + 1))
        return
    fi
    if ! strip_ansi "$work/err" | grep -qF -- "$expected"; then
        printf 'ps-client-installer %s: stderr does not contain %s\n' "$label" "$expected" >&2
        strip_ansi "$work/err" | head -2 >&2 || true
        failures=$((failures + 1))
    fi
}

# --- the parameter contract ---------------------------------------------------
# Every message below was MEASURED off the installer, not guessed -- smoke/13's
# first version asserted wording that did not exist, and that is the trap.
expect_rejected 'missing value' \
    "Missing an argument for parameter 'DestinationDirectory'." -DestinationDirectory
expect_rejected 'unknown parameter' \
    "A parameter cannot be found that matches parameter name 'Bogus'." -Bogus x
# An unknown parameter is refused even alongside a valid -Check: the binder runs
# before the body, so the gate never gets a chance to mask it.
expect_rejected 'unknown parameter with -Check' \
    "A parameter cannot be found that matches parameter name 'Bogus'." -Check -Bogus x

# `-?` is PowerShell's own help switch (not the script's): it prints the usage
# synopsis to stdout and exits 0.  This is the ONLY reachable zero-exit path, and
# it must not be confused with the installer doing work -- assert nothing is
# written and the synopsis names the three real parameters.
cases=$((cases + 1))
help_status=$(run_installer '-?')
if [ "$help_status" -ne 0 ]; then
    printf 'ps-client-installer -?: expected 0, got %s\n' "$help_status" >&2
    failures=$((failures + 1))
elif ! grep -qF -- '-DestinationDirectory' "$work/out" \
   || ! grep -qF -- '-SkipPathUpdate' "$work/out" \
   || ! grep -qF -- '-Check' "$work/out"; then
    printf '%s\n' 'ps-client-installer -?: the synopsis does not list the three parameters' >&2
    failures=$((failures + 1))
fi

# --- the platform gate --------------------------------------------------------
# A VALID invocation on a non-Windows platform must fail, and the failure must be
# the platform gate -- not a missing-asset error, not a silent success.
destination="$work/destination"
mkdir -p "$destination"
cases=$((cases + 1))
gate_status=$(run_installer -DestinationDirectory "$destination")
if [ "$gate_status" -eq 0 ]; then
    printf '%s\n' 'ps-client-installer: a non-Windows run exited 0 instead of failing' >&2
    failures=$((failures + 1))
elif ! strip_ansi "$work/err" | grep -qF 'This installer must run on Windows'; then
    printf 'ps-client-installer: the platform gate reported something unexpected: %s\n' \
        "$(strip_ansi "$work/err" | head -1)" >&2
    failures=$((failures + 1))
fi

# The gate must run BEFORE any write.  That ordering is the whole reason this
# file can say anything at all off Windows, and it is the thing a future edit
# could silently invert.  Prove it by the filesystem: after a gated run the
# destination directory must still be empty.  A future edit that created the
# directory, wrote a staging file, or updated PATH before the gate would leave a
# trace here.
cases=$((cases + 1))
residue=$(find "$destination" -mindepth 1 | wc -l | tr -d ' ')
if [ "$residue" -ne 0 ]; then
    printf 'ps-client-installer: the platform gate ran after a write (%s entr(ies) left in the destination)\n' "$residue" >&2
    failures=$((failures + 1))
fi

# -Check is the read-only mode and must ALSO hit the gate -- a -Check that
# short-circuited to a success off Windows would be a silently-passing no-op.
# Asserted with its own destination so the residue check above stays isolated.
check_destination="$work/check-destination"
mkdir -p "$check_destination"
cases=$((cases + 1))
check_status=$(run_installer -Check -DestinationDirectory "$check_destination")
if [ "$check_status" -eq 0 ]; then
    printf '%s\n' 'ps-client-installer -Check: a non-Windows run exited 0 instead of failing' >&2
    failures=$((failures + 1))
elif ! strip_ansi "$work/err" | grep -qF 'This installer must run on Windows'; then
    printf 'ps-client-installer -Check: the platform gate reported something unexpected: %s\n' \
        "$(strip_ansi "$work/err" | head -1)" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if [ -n "$(find "$check_destination" -mindepth 1 -print -quit)" ]; then
    printf '%s\n' 'ps-client-installer -Check: the gated -Check run wrote to the destination' >&2
    failures=$((failures + 1))
fi

# --- W4: pair-atomic staging, driven on the extracted function -----------------
# The install used to stage+replace each client in turn, so a failure on the
# second client left a NEW first client paired with a STALE second -- and the
# pair is only ever read together (docs/PLAN.md A28 W4).  The fix stages EVERY item
# before replacing ANY.  The installer's platform gate makes the whole file
# unrunnable here, but Install-CommitSet is pure .NET: extract it (plus the two
# temporary-file helpers and the reparse guard it calls) and drive it directly.
# Same technique as smoke/22/23 -- and it is the only way to give this invariant
# a behavioural lock without a Windows host.
extract_script="$work/extract.ps1"
cat > "$extract_script" <<'EXTRACT'
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$installerPath = $args[0]
$workDir = $args[1]
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { [Console]::Error.WriteLine("installer did not parse"); exit 3 }
$wanted = @("Test-NonReparsePathChain", "Assert-NonReparsePathChain",
    "Remove-InstallerTemporaryFile", "New-InstallerTemporaryFile", "Install-CommitSet")
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$source = [System.Text.StringBuilder]::new()
foreach ($name in $wanted) {
    $match = $functions | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($null -eq $match) { [Console]::Error.WriteLine("missing function: $name"); exit 3 }
    [void]$source.AppendLine($match.Extent.Text)
}
$script:Program = "agentq-client-installer"
Invoke-Expression $source.ToString()

$dir = Join-Path $workDir "dest"
[System.IO.Directory]::CreateDirectory($dir) | Out-Null
# Install-CommitSet reads the script-scope $DestinationDirectory (the installer
# sets it at the top from the -DestinationDirectory parameter); the driver must
# provide the same environment, or every call dies with "variable not set" --
# which the failure-path try/catch below would have swallowed as the expected
# throw, a false green the happy path then caught.  Measured 2026-10-07.
$DestinationDirectory = $dir
function Write-File([string]$path, [string]$content) {
    [System.IO.File]::WriteAllText($path, $content)
}
# Two "clients", each with a pre-existing OLD destination.
$newA = Join-Path $workDir "new-a"; $newB = Join-Path $workDir "new-b"
Write-File $newA "NEW-A"
Write-File $newB "NEW-B"
$dstA = Join-Path $dir "a"; $dstB = Join-Path $dir "b"
Write-File $dstA "OLD-A"
Write-File $dstB "OLD-B"

# Item B's source is a directory: staging B must fail AFTER A is staged but
# BEFORE any replace -- so neither destination may change.
$badB = Join-Path $workDir "bad-b"
[System.IO.Directory]::CreateDirectory($badB) | Out-Null
$items = @(
    [pscustomobject]@{ SourcePath = $newA; DestinationPath = $dstA; Description = "a" },
    [pscustomobject]@{ SourcePath = $badB; DestinationPath = $dstB; Description = "b" }
)
$failed = $false
$failureMessage = ""
try { Install-CommitSet -Items $items } catch { $failed = $true; $failureMessage = $_.Exception.Message }
if (!$failed) { [Console]::Error.WriteLine("PAIR: a failing second stage did not throw"); exit 1 }
# Pin WHY it threw: an unrelated throw (undefined variable, path guard) would
# also leave both destinations unchanged and fake a pass.
if ($failureMessage -notlike "*Client asset is not a file*") {
    [Console]::Error.WriteLine("PAIR: the failure was not the staged one: $failureMessage"); exit 1
}
if ((Get-Content -Raw $dstA) -ne "OLD-A") { [Console]::Error.WriteLine("PAIR: first client was replaced despite the second failing"); exit 1 }
if ((Get-Content -Raw $dstB) -ne "OLD-B") { [Console]::Error.WriteLine("PAIR: second client changed despite its stage failing"); exit 1 }
$residue = @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -ne "a" -and $_.Name -ne "b" })
if ($residue.Count -ne 0) { [Console]::Error.WriteLine("PAIR: $($residue.Count) staging file(s) left behind"); exit 1 }

# And the happy path commits BOTH.
$goodItems = @(
    [pscustomobject]@{ SourcePath = $newA; DestinationPath = $dstA; Description = "a" },
    [pscustomobject]@{ SourcePath = $newB; DestinationPath = $dstB; Description = "b" }
)
Install-CommitSet -Items $goodItems
if ((Get-Content -Raw $dstA) -ne "NEW-A") { [Console]::Error.WriteLine("PAIR: happy path did not commit the first client"); exit 1 }
if ((Get-Content -Raw $dstB) -ne "NEW-B") { [Console]::Error.WriteLine("PAIR: happy path did not commit the second client"); exit 1 }
$residue = @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -ne "a" -and $_.Name -ne "b" })
if ($residue.Count -ne 0) { [Console]::Error.WriteLine("PAIR: happy path left $($residue.Count) staging file(s)"); exit 1 }
[Console]::Out.WriteLine("PAIR-OK")
EXTRACT

cases=$((cases + 1))
pair_status=0
pair_out=$("$pwsh_binary" -NoProfile -NonInteractive -File "$extract_script" "$installer" "$work" 2>"$work/pair.err") || pair_status=$?
if [ "$pair_status" -ne 0 ] || [ "$pair_out" != "PAIR-OK" ]; then
    printf 'ps-client-installer (W4 pair): the staging invariant failed: %s
'         "$(strip_ansi "$work/pair.err" | head -2 | tr '
' ' ')" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'ps-client-installer-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'ps-client-installer-contract checks passed: cases=%s pwsh=%s pair-atomic=covered staging=NOT-covered(needs-Windows)\n' \
    "$cases" "$("$pwsh_binary" -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || printf 'unknown')"
