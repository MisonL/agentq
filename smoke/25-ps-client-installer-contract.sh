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

# AGENTQ_SMOKE_PWSH selects the interpreter, as in the other PS checks (measured
# 2026-10-13: 23 was the lone PS check without the hook).
pwsh_binary=${AGENTQ_SMOKE_PWSH:-$(command -v pwsh || true)}
if [ -z "$pwsh_binary" ]; then
    printf '%s\n' 'SKIPPED: pwsh is not available; the client installer was not executed'
    exit 0
fi
# A bogus override is an environment fault, not an asset one: skip, do not fail.
if ! command -v "$pwsh_binary" >/dev/null 2>&1; then
    printf 'SKIPPED: pwsh is not available (AGENTQ_SMOKE_PWSH=%s is not an executable on PATH)\n' "$pwsh_binary"
    exit 0
fi

# Present is not the same as working.  A corrupt pwsh startup cache makes
# every launch die (measured five times in this repo, with four different
# messages: "String cannot have zero length", "Stack overflow",
# FileLoadException, and Abort trap: 6).  The existence tests above cannot see
# that, so every case below would run against a pwsh that never starts and
# report its failures as asset defects -- the misdiagnosis smoke/01 fixed for
# itself in 2026-09-28.  Probe once: an unusable interpreter is an ENVIRONMENT
# fault, say so with the fix, and do not claim the check ran.
pwsh_probe_status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command 'exit 0' >/dev/null 2>&1 || pwsh_probe_status=$?
if [ "$pwsh_probe_status" -ne 0 ]; then
    printf '%s\n' 'Client-installer contract NOT run: the pwsh on PATH cannot execute (startup cache).' >&2
    printf '%s\n' 'Try: mv ~/.cache/powershell/StartupProfileData-NonInteractive{,.broken}' >&2
    exit 1
fi

work=$(mktemp -d /tmp/agentq-smoke-psclientinstaller.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

# --- Binder messages are LOCALISED (2026-10-20, measured on a zh-CN Windows 10) -
# The rejection cases below assert the exact wording PowerShell's parameter
# binder produces.  That wording follows [Thread]::CurrentThread.CurrentUICulture,
# so on a non-English Windows the SAME refusal reads `找不到与参数名称"Bogus"匹配的参数`
# and every case fails -- reporting a correct asset as broken.  CI's windows-latest
# is an English image, which is why this stayed invisible; a real test host is not.
# Measured on Windows PowerShell 5.1.19041 (zh-CN) with the real asset: setting
# CurrentUICulture to en-US in-process makes all four messages byte-identical to
# the English strings asserted here.
#
# So: probe the UI culture once.  English -> run the asset directly (the shipped
# path, unchanged).  Anything else -> run it through a wrapper that sets en-US
# first, and SAY SO in the summary.  If an invocation still fails, that is an
# environment fault and must not be read as an asset defect.
pwsh_ui_culture=$("$pwsh_binary" -NoProfile -NonInteractive \
    -Command '[System.Globalization.CultureInfo]::CurrentUICulture.Name' 2>/dev/null | tr -d '\r\n')
case $pwsh_ui_culture in
    ''|en|en-*) pwsh_binder=en ;;
    *) pwsh_binder="en-US-via-wrapper(host=$pwsh_ui_culture)" ;;
esac
if [ "$pwsh_binder" != en ]; then
    cat > "$work/binder-en.ps1" <<'WRAPPER'
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$ArgumentFile
)
# Binder messages follow the UI culture; the checks assert the English wording,
# so pin it BEFORE the target script binds its parameters.
[System.Threading.Thread]::CurrentThread.CurrentUICulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
# Arguments arrive NUL-delimited from the check.
#
# They are re-assembled into a command line rather than splatted as an array.
# Measured 2026-10-20 on Windows PowerShell 5.1: `& $target @array` passes every
# element POSITIONALLY -- '-Bogus' becomes a value, not a parameter name -- so the
# refusal names a different parameter and looks like an asset defect.  A token
# that starts with '-' is therefore emitted verbatim (that is exactly how
# PowerShell's own -File parser reads it); everything else is single-quoted with
# '' doubling, which also preserves the empty argument as ''.
$bytes = [System.IO.File]::ReadAllBytes($ArgumentFile)
$text = [System.Text.Encoding]::UTF8.GetString($bytes)
if ($text.EndsWith([char]0)) { $text = $text.Substring(0, $text.Length - 1) }
$targetArguments = if ($text.Length -eq 0) { @() } else { $text -split [char]0 }
$escapedTarget = $Target.Replace("'", "''")
$builder = New-Object System.Text.StringBuilder
[void]$builder.Append("& '").Append($escapedTarget).Append("'")
foreach ($argument in $targetArguments) {
    if ($argument -match '^-[A-Za-z?]') {
        [void]$builder.Append(' ').Append($argument)
    } else {
        [void]$builder.Append(" '").Append($argument.Replace("'", "''")).Append("'")
    }
}
try {
    Invoke-Expression $builder.ToString()
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
WRAPPER
fi
mkdir -p "$work/home"

failures=0
cases=0

# strip_ansi <file> -- PowerShell colourises its error output; the assertions are
# on the message text, which is wrapped in escape sequences on a tty-capable
# stderr.  Same handling smoke/13 relies on being absent -- this check normalises.
strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*m//g' "$1"; }
# Same join discipline as smoke/23 (2026-10-13): PS 5.1 wraps binder messages
# across lines, so the CR/join half belongs here too even though pwsh 7 alone
# never needs it.
# PowerShell formats a terminating error to the CONSOLE BUFFER WIDTH and hard-
# wraps at that column -- mid-word when the message crosses it.  Measured
# 2026-10-21 on a real Windows host: width 120, and the refusals these checks
# assert arrived as `SourcePa` + `th` and `B` + `ogus`.  Flattening the newline
# to a SPACE then splits the word for good and a correct asset reads as broken
# (intermittent: it depends on where the column lands).  So rejoin a line that
# fills the buffer (>= width-1) with NO separator -- that break was inside a
# word -- and join the rest with a space.  The width is probed, not assumed.
pwsh_wrap_width=$("$pwsh_binary" -NoProfile -NonInteractive \
    -Command '$Host.UI.RawUI.BufferSize.Width' 2>/dev/null | tr -d '\r\n')
case $pwsh_wrap_width in ''|*[!0-9]*) pwsh_wrap_width=0 ;; esac
flatten_err() {
    strip_ansi "$1" | tr -d '\r' | awk -v w="$pwsh_wrap_width" '
        { line[NR] = $0 }
        END {
            out = ""
            for (i = 1; i <= NR; i++) {
                out = out line[i]
                if (i < NR) { out = out ((w > 0 && length(line[i]) >= w - 1) ? "" : " ") }
            }
            gsub(/[ \t]+/, " ", out)
            print out
        }'
}

# run_installer [args...] -- runs the installer in the sandbox HOME, capturing
# status/stdout/stderr; prints the status.  HOME is redirected so a run that got
# past the gate could not touch the real user's .local/bin -- defence in depth,
# the gate itself already prevents it.
run_installer() {
    local status=0
    (cd "$work" && HOME="$work/home" run_asset "$installer" "$@" >"$work/out" 2>"$work/err") || status=$?
    printf '%s' "$status"
}

# expect_rejected <label> <expected-stderr-fragment> [args...]
#
# The installer's own parameter binder rejects these before a single statement of
# the body runs, so nothing is written anywhere; the exit code is 1 (PowerShell's
# terminating-error code), not the 2 the POSIX installer uses.
# Run the asset under the current UI culture (the shipped path), or through the
# en-US wrapper when the host is not English.  $1 = the asset path, rest = args.
# The wrapper takes the arguments as an ARRAY, so an empty argument stays empty
# and a leading-dash argument stays a parameter name -- quoting them would
# change what PowerShell's binder sees (measured 2026-10-20: quoting turned
# `-SourcePath` into a positional value and the refusal moved to another
# parameter, which looked exactly like an asset defect).
run_asset() {
    local asset_path=$1
    shift
    if [ "$pwsh_binder" = en ]; then
        "$pwsh_binary" -NoProfile -NonInteractive -File "$asset_path" "$@"
    else
        local arg_file="$work/binder-args.$$"
        : > "$arg_file"
        for a in "$@"; do
            printf '%s\0' "$a" >> "$arg_file"
        done
        "$pwsh_binary" -NoProfile -NonInteractive -File "$work/binder-en.ps1" \
            -Target "$asset_path" -ArgumentFile "$arg_file"
        local wrapper_status=$?
        rm -f "$arg_file"
        return $wrapper_status
    fi
}

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
    if ! grep -qF -- "$expected" <<< "$(flatten_err "$work/err")"; then
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
# NON-WINDOWS ONLY, and the boundary is a property of the case, not a shortfall
# of effort: the thing under test is the `This installer must run on Windows`
# throw, which by definition cannot fire ON Windows.  Measured 2026-10-20 on a
# real Windows 10 host: with a valid destination the installer does not hit the
# gate -- it INSTALLS, and (without -SkipPathUpdate) rewrites the user's PATH.
# That is correct behaviour for the asset and a HAZARD for this check, which
# must never be the thing that installs AgentQ onto a developer's machine.  It
# did exactly that once before this guard existed: the run appended a dead
# `.../agentq-smoke-psclientinstaller.*/destination` entry to HKCU\Environment
# Path.  So on a Windows host the case is skipped and declared, and every
# invocation below additionally passes -SkipPathUpdate as defence in depth --
# a valid call that still reached the install path could then write files, but
# could never edit the user's PATH.
host_kind=$(uname -s 2>/dev/null || printf 'unknown')
case $host_kind in
    MINGW*|MSYS*|CYGWIN*) host_is_windows=true ;;
    *) host_is_windows=false ;;
esac
if [ "$host_is_windows" = true ]; then
    printf 'ps-client-installer: the platform-gate cases are NOT-covered(needs-non-Windows) on %s; the installer was not invoked with a valid argument set\n' "$host_kind"
else
    destination="$work/destination"
    mkdir -p "$destination"
    cases=$((cases + 1))
    gate_status=$(run_installer -SkipPathUpdate -DestinationDirectory "$destination")
    if [ "$gate_status" -eq 0 ]; then
        printf '%s\n' 'ps-client-installer: a non-Windows run exited 0 instead of failing' >&2
        failures=$((failures + 1))
    elif ! grep -qF 'This installer must run on Windows' <<< "$(strip_ansi "$work/err")"; then
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
    check_status=$(run_installer -Check -SkipPathUpdate -DestinationDirectory "$check_destination")
    if [ "$check_status" -eq 0 ]; then
        printf '%s\n' 'ps-client-installer -Check: a non-Windows run exited 0 instead of failing' >&2
        failures=$((failures + 1))
    elif ! grep -qF 'This installer must run on Windows' <<< "$(strip_ansi "$work/err")"; then
        printf 'ps-client-installer -Check: the platform gate reported something unexpected: %s\n' \
            "$(strip_ansi "$work/err" | head -1)" >&2
        failures=$((failures + 1))
    fi
    cases=$((cases + 1))
    if [ -n "$(find "$check_destination" -mindepth 1 -print -quit)" ]; then
        printf '%s\n' 'ps-client-installer -Check: the gated -Check run wrote to the destination' >&2
        failures=$((failures + 1))
    fi
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
# The platform-gate coverage is reported, not assumed: on a Windows host those
# cases did not run (the gate cannot fire there), and saying "covered" would be
# the same false claim in the other direction.
# staging is a SEPARATE boundary with a DIFFERENT reason on each host, and the
# old unconditional `staging=NOT-covered(needs-Windows)` became self-
# contradictory the moment this check entered the Windows CI job: a Windows log
# line reading "needs-Windows" claims the very thing it is denying, and it also
# implied that running the check ON Windows would exercise staging -- it does
# not, and it must not.  On Windows the accurate reason is that a valid
# invocation is deliberately never issued here (measured 2026-10-20: doing so
# ran the client installer and rewrote the user's PATH).
if [ "$host_is_windows" = true ]; then
    platform_gate_state='platform-gate=NOT-covered(needs-non-Windows)'
    staging_state='staging=NOT-covered(deliberately-not-exercised)'
else
    platform_gate_state='platform-gate=covered'
    staging_state='staging=NOT-covered(needs-Windows)'
fi
printf 'ps-client-installer-contract checks passed: cases=%s pwsh=%s binder=%s pair-atomic=covered %s %s\n' \
    "$cases" "$("$pwsh_binary" -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || printf 'unknown')" "$pwsh_binder" "$platform_gate_state" "$staging_state"
