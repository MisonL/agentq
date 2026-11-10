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
# AGENTQ_SMOKE_PWSH selects the interpreter, exactly as smoke/12/20/22/23 do.
# Leaving the hook out made 23 the lone PS check pinned to whatever `pwsh` is on
# PATH while the windows job counted it as 5.1 evidence -- measured 2026-10-13.
pwsh_binary=${AGENTQ_SMOKE_PWSH:-$(command -v pwsh || true)}

if [ -z "$pwsh_binary" ]; then
    printf '%s\n' 'SKIPPED: pwsh is not available; the Windows installer was not executed'
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
    printf '%s\n' 'PowerShell installer contract NOT run: the pwsh on PATH cannot execute (startup cache).' >&2
    printf '%s\n' 'Try: mv ~/.cache/powershell/StartupProfileData-NonInteractive{,.broken}' >&2
    exit 1
fi

work=$(mktemp -d /tmp/agentq-smoke-psinstaller.XXXXXX)
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

failures=0

# Normalized stderr matching, exactly as smoke/23 documents: Windows PowerShell
# 5.1 wraps error messages across lines at the console width (measured on CI,
# 2026-10-13) and pwsh 7 colourises them; the fragment assertions are on the
# message text.  Same mechanism, one definition per file by design (12/13/23
# each define it; 12 and 13 gained it after 23's CI red proved the gap).
strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*m//g' "$1"; }
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

cases=0

# expect_rejected <expected-stderr-fragment> [args...]
#
# The installer's own parameter binding rejects these before a single statement
# of the script body runs, so nothing is written anywhere; the exit code is 1
# (PowerShell's terminating-error code), not the 2 the POSIX installer uses.
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
    local expected=$1
    shift
    local label=$*
    cases=$((cases + 1))
    local status=0
    (cd "$work" && HOME="$work/home" run_asset "$installer" "$@" >"$work/out" 2>"$work/err") || status=$?
    if [ "$status" -eq 0 ]; then
        printf 'ps-installer %s: expected a non-zero exit, got 0\n' "${label:-<no args>}" >&2
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" <<< "$(flatten_err "$work/err")"; then
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

# Portable sha256 over a directory tree.  Git for Windows ships coreutils'
# `sha256sum` but NOT `shasum` (a perl script from perl modules on macOS), so a
# plain `find -exec shasum` died here with "shasum: No such file" on 2026-10-20
# -- an environment fact about the platform this check now runs on (the windows
# CI job and the real Windows host), not about the asset under test.  Emit one
# digest per file, sorted by path, so the comparison is stable and a file added
# or removed between before/after shows up as a changed line, not a shifted one.
stage_digests() {
    local target=$1 hash_util file rel digest
    # The two utilities take the algorithm differently: `shasum -a 256 FILE`
    # versus `sha256sum FILE`.  Passing shasum's flag to sha256sum fails with
    # "invalid option -- a" -- measured 2026-10-20, after a first version of
    # this helper did exactly that and would have broken the Windows CI job.
    if command -v shasum >/dev/null 2>&1; then
        hash_util=shasum
    elif command -v sha256sum >/dev/null 2>&1; then
        hash_util=sha256sum
    else
        printf 'ps-installer: neither shasum nor sha256sum is on PATH; the staged-asset check cannot run\n' >&2
        return 127
    fi
    while IFS= read -r file; do
        rel=${file#"$target"/}
        if [ "$hash_util" = shasum ]; then
            digest=$(shasum -a 256 "$file")
        else
            digest=$(sha256sum "$file")
        fi
        printf '%s  %s\n' "${digest%% *}" "$rel"
    done < <(find "$target" -type f | LC_ALL=C sort)
}

# --- the platform gate --------------------------------------------------------
# NON-WINDOWS ONLY, and the boundary belongs to the case rather than to the
# effort spent on it: the thing under test is the `Windows Principal
# functionality is not supported on this platform` throw, which by definition
# cannot fire ON Windows.  Measured 2026-10-20 on a real Windows 10 host: with
# a populated stage directory the installer does not stop at the gate -- it
# proceeds to install the daemon and rewrite the launcher's install state.  That
# is correct behaviour for the asset and a HAZARD for this check, which must
# never be the thing that installs AgentQ onto a developer's machine.  So on a
# Windows host the case is skipped and declared rather than run.
host_kind=$(uname -s 2>/dev/null || printf 'unknown')
case $host_kind in
    MINGW*|MSYS*|CYGWIN*) host_is_windows=true ;;
    *) host_is_windows=false ;;
esac
if [ "$host_is_windows" = true ]; then
    printf 'ps-installer: the platform-gate cases are NOT-covered(needs-non-Windows) on %s; the installer was not invoked with a valid argument set\n' "$host_kind"
else
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
    stage_before=$(stage_digests "$stage")

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
    stage_after=$(stage_digests "$stage")
    if [ "$stage_before" != "$stage_after" ]; then
        printf '%s\n' 'ps-installer: the platform gate modified the staged assets' >&2
        failures=$((failures + 1))
    fi
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
# Convert-ToPowerShellSingleQuotedString is extracted too: the refusal builds its
# recovery command with the same helper the installer uses elsewhere, so the
# extraction has to carry it or Invoke-Expression would fail on the call.
$wanted = @("Find-AgentQCrashLeftovers", "Assert-NoCrashLeftoverTransactions", "Convert-ToPowerShellSingleQuotedString")
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
        $script:refusalMessage = $_.Exception.Message
        if ($script:refusalMessage -notlike "refusing to install:*") {
            [Console]::Error.WriteLine("W5 ${label}: threw, but not the controlled refusal: $($script:refusalMessage)"); exit 1
        }
        if ($script:refusalMessage -notlike "*$fragment*") {
            [Console]::Error.WriteLine("W5 ${label}: refused for the wrong reason (wanted *$fragment*): $($script:refusalMessage)"); exit 1
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

# 3. THE DEFECT: root missing, a backup leftover present -> refuse.  The residue
#    name carries an APOSTROPHE on purpose: pasteability is only proven when the
#    quoting actually has to escape something.  Measured (mutation M4): with a
#    plain name, `'a path'` built by string concatenation is byte-identical to the
#    properly quoted one and passed every check below.
Reset-Tree
[System.IO.Directory]::CreateDirectory((Join-Path $parent ".AgentQ.backup.Smoke'AbC")) | Out-Null
Expect-Refusal "missing-root-with-backup" "is missing but a previous run's transaction residue exists"
# ...and the recovery guidance must name the daemon restart (a crashed run has
# already stopped the daemon, so moving the backup back alone leaves the operator
# stuck on the NEXT check).  Same measured reason as smoke/11.
Expect-Refusal "missing-root-names-daemon-restart" "restart the AgentQ daemon"

# 3b. The recovery command must WORK WHEN PASTED.  The message used to read
#     "Move-Item <the .AgentQ.backup directory> $RootDirectory" -- the reader had
#     to hand-edit a placeholder, in a refusing path where a wrong edit destroys
#     the queue.  The POSIX twin got real commands built from the scanned paths
#     in 0.1.13; this side still carried the placeholder (found 2026-10-16 in the
#     parallel-implementation sweep that fix prompted).
#     The oracle is the PowerShell PARSER, not a comparison against the
#     installer's own quoting helper -- using the helper here would let a broken
#     helper satisfy its own test.  The residue name carries an apostrophe, so a
#     command assembled by naive concatenation parses to a DIFFERENT path.
#     Measured (mutation M4): with an apostrophe-free name that command is
#     byte-identical to the correct one and passes every check here.
$realBackup = (Join-Path $parent ".AgentQ.backup.Smoke'AbC")
if ($script:refusalMessage -like "*<*") {
    [Console]::Error.WriteLine("W5 recovery-command: the refusal still contains an angle-bracket placeholder: $($script:refusalMessage)"); exit 1
}
$commandLabel = "Restore it with:"
$commandStart = $script:refusalMessage.IndexOf($commandLabel)
$commandEnd = $script:refusalMessage.IndexOf(" then restart the AgentQ daemon")
if ($commandStart -lt 0 -or $commandEnd -lt $commandStart) {
    [Console]::Error.WriteLine("W5 recovery-command: the refusal frames no restore command: $($script:refusalMessage)"); exit 1
}
$restoreCommand = $script:refusalMessage.Substring($commandStart + $commandLabel.Length, $commandEnd - $commandStart - $commandLabel.Length).Trim()
$commandTokens = $null
$commandErrors = $null
$parsedCommand = [System.Management.Automation.Language.Parser]::ParseInput($restoreCommand, [ref]$commandTokens, [ref]$commandErrors)
if ($commandErrors.Count -gt 0) {
    [Console]::Error.WriteLine("W5 recovery-command: the restore command does not parse: $restoreCommand"); exit 1
}
$commandArguments = @($parsedCommand.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
if ($commandArguments -notcontains $realBackup) {
    [Console]::Error.WriteLine("W5 recovery-command: the restore command does not name the real residue path (parsed: $($commandArguments -join ' | ')): $restoreCommand"); exit 1
}
if ($commandArguments -notcontains $root) {
    [Console]::Error.WriteLine("W5 recovery-command: the restore command does not name the AgentQ root (parsed: $($commandArguments -join ' | ')): $restoreCommand"); exit 1
}
# The present-root refusal carries the same real paths and had the sibling
# "restore the .backup" wording with no command at all -- pin that it is
# placeholder-free too.
Reset-Tree
[System.IO.Directory]::CreateDirectory($root) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $parent ".AgentQ.backup.9012")) | Out-Null
Expect-Refusal "present-root-has-no-placeholder" "exists beside the AgentQ root"
if ($script:refusalMessage -like "*<*") {
    [Console]::Error.WriteLine("W5 recovery-command: the present-root refusal contains an angle-bracket placeholder: $($script:refusalMessage)"); exit 1
}

# 4. A stage leftover beside a missing root -> refuse, and the guidance must say
#    that NOTHING here is restorable: a `.stage` directory is the half-written
#    NEW root, so offering a `Move-Item` for it would deploy a partial tree over
#    a missing one.  Same two-way split as the POSIX twin; without this case the
#    second branch is unreachable by any other assertion (mutation M3 proved it:
#    the absence check did not fire until this case existed).
Reset-Tree
[System.IO.Directory]::CreateDirectory((Join-Path $parent ".AgentQ.stage.999")) | Out-Null
Expect-Refusal "missing-root-with-stage" "is missing but a previous run's transaction residue exists"
Expect-Refusal "missing-root-stage-not-restorable" "none of it is a backup directory that could be restored"
if ($script:refusalMessage -like "*<*") {
    [Console]::Error.WriteLine("W5 missing-root-with-stage: the refusal contains an angle-bracket placeholder: $($script:refusalMessage)"); exit 1
}
if ($script:refusalMessage.Contains("Move-Item")) {
    [Console]::Error.WriteLine("W5 missing-root-with-stage: offers a restore command although the residue holds no backup: $($script:refusalMessage)"); exit 1
}

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

# --- the operation lock's stale recovery, driven on the extracted functions ---
# Wait-ForAgentQOperationLock was unrunnable off Windows for the same reason as
# everything else in this file (the platform gate), and its stale path removed
# the WHOLE lock directory with `Remove-Item -Recurse -Force`.  That deletes
# whatever else lives in the directory -- including the files of a lock another
# process created after the holder died -- and the test only proves the
# directory is not a reparse point.  The mirror is the POSIX twin
# remove_stale_operation_lock: re-read the SAME identity, re-judge death, then
# remove only the verified pid file and the now-empty directory.
#
# Same AST technique as the W5 block: the functions are pure .NET over paths, so
# they run here unchanged.  `sleep` is replaced by a counter -- the wait loop's
# 30 one-second sleeps would otherwise cost the case half a minute.
lock_extract="$work/oplock-extract.ps1"
cat > "$lock_extract" <<'LOCKEXTRACT'
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$installerPath = $args[0]
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { [Console]::Error.WriteLine("installer did not parse"); exit 3 }
$wanted = @(
    "Wait-ForAgentQOperationLock",
    "Remove-StaleOperationLock",
    "Remove-AgentQInstallerTemporaryFile",
    "Read-LockMetadata",
    "Test-ProcessIsConfirmedDead",
    "Get-ProcessIdentityState",
    "Test-NonReparseLockPath",
    "Test-NonReparseFilePath"
)
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$source = [System.Text.StringBuilder]::new()
foreach ($name in $wanted) {
    $match = $functions | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($null -eq $match) { [Console]::Error.WriteLine("missing function: $name"); exit 3 }
    [void]$source.AppendLine($match.Extent.Text)
}
Invoke-Expression $source.ToString()
$script:Program = 'install-agentq.ps1'

function Start-Sleep { param([int]$Seconds) $script:sleepCalls += 1 }

function Get-DeadProcessId {
    $process = [System.Diagnostics.Process]::Start([System.Diagnostics.ProcessStartInfo]::new("/bin/sh", "-c exit 0"))
    $process.WaitForExit()
    return [string]$process.Id
}
function Get-HolderIdentity {
    return ([System.Diagnostics.Process]::GetCurrentProcess()).StartTime.ToUniversalTime().Ticks.ToString()
}

$runtime = Join-Path $args[1] "runtime"
[System.IO.Directory]::CreateDirectory($runtime) | Out-Null
$lock = Join-Path $runtime "agentq-operation.lock"
function Reset-Lock {
    if ([System.IO.Directory]::Exists($lock)) { [System.IO.Directory]::Delete($lock, $true) }
    [System.IO.Directory]::CreateDirectory($lock) | Out-Null
}
function Write-LockMetadata([string]$PidValue, [string]$Identity) {
    [System.IO.File]::WriteAllText((Join-Path $lock "pid"), "$PidValue`t$Identity")
}

$deadPid = Get-DeadProcessId
$holderIdentity = Get-HolderIdentity

# 1. Holder confirmed dead, nothing unknown beside it -> the lock is recovered
#    and the wait returns.
Reset-Lock
Write-LockMetadata $deadPid "Mon Jan  1 00:00:00 2001"
$script:sleepCalls = 0
Wait-ForAgentQOperationLock -RuntimeDirectory $runtime
if ([System.IO.Directory]::Exists($lock)) {
    [Console]::Error.WriteLine("oplock dead-holder: the stale lock survived"); exit 1
}

# 2. Holder confirmed dead, but the directory holds a file the protocol does
#    not define.  A recursive delete would destroy it; the recovery must remove
#    its own pid and then FAIL, leaving the unknown file and the directory in
#    place.  With the pid file gone and the directory non-empty, the wait then
#    throws -- the wait cannot leave a lock it does not own behind silently.
Reset-Lock
Write-LockMetadata $deadPid "Mon Jan  1 00:00:00 2001"
$unknownPath = Join-Path $lock "unknown"
[System.IO.File]::WriteAllText($unknownPath, "keep me")
$script:sleepCalls = 0
$refused = $false
try {
    Wait-ForAgentQOperationLock -RuntimeDirectory $runtime
} catch {
    $refused = $_.Exception.Message -like "*still in progress*" -or
        $_.Exception.Message -like "*cannot recover stale AgentQ operation lock*"
}
if (!$refused) {
    [Console]::Error.WriteLine("oplock unknown-child: the wait did not refuse the unrecoverable lock"); exit 1
}
if (![System.IO.File]::Exists($unknownPath)) {
    [Console]::Error.WriteLine("oplock unknown-child: the recovery deleted a file it does not own"); exit 1
}
if (![System.IO.Directory]::Exists($lock)) {
    [Console]::Error.WriteLine("oplock unknown-child: the recovery removed a directory it does not own"); exit 1
}

# 3. THE RACE: the stale holder's pid file makes the recovery judge the lock
#    dead, and before the re-read a different, LIVE lock is in its place (a new
#    pid file).  That lock belongs to someone else and must survive; the new
#    holder's directory must not lose anything either.
Reset-Lock
Write-LockMetadata $deadPid "Mon Jan  1 00:00:00 2001"
$swapScript = Join-Path $args[1] "swap.ps1"
[System.IO.File]::WriteAllText($swapScript, @'
param([string]$Lock, [string]$HolderPid, [string]$HolderIdentity)
Remove-Item -LiteralPath (Join-Path $Lock "pid") -Force
[System.IO.File]::WriteAllText((Join-Path $Lock "pid"), "$HolderPid`t$HolderIdentity")
Set-Content -LiteralPath (Join-Path $Lock "swapped") -Value "live holder's file"
'@)
# Hook the FIRST Test-ProcessIsConfirmedDead call (the one Wait-ForAgentQOperationLock
# makes, before Remove-StaleOperationLock runs) and swap the lock behind it.
# Remove-StaleOperationLock re-reads afterwards and sees the changed identity,
# so it retries the 3 attempts, then returns 2 -- the wait then throws the
# unverifiable-lock message, and the live lock and its extra file survive.
$original = ${function:Test-ProcessIsConfirmedDead}
function Test-ProcessIsConfirmedDead {
    param([string]$ProcessId, [string]$ExpectedIdentity)
    $result = & $original -ProcessId $ProcessId -ExpectedIdentity $ExpectedIdentity
    if ($result -and !$script:swapped) {
        $script:swapped = $true
        & $swapScript -Lock $lock -HolderPid ([string]$PID) -HolderIdentity $holderIdentity
    }
    return $result
}
$script:swapped = $false
$script:sleepCalls = 0
$refused = $false
try {
    Wait-ForAgentQOperationLock -RuntimeDirectory $runtime
} catch {
    $refused = $_.Exception.Message -like "*cannot recover stale AgentQ operation lock*"
}
if (!$refused) {
    [Console]::Error.WriteLine("oplock swapped-live: the wait did not throw the cannot-recover refusal"); exit 1
}
$swapMetadata = Read-LockMetadata -Path (Join-Path $lock "pid")
if ($null -eq $swapMetadata -or $swapMetadata.Pid -ne [string]$PID) {
    [Console]::Error.WriteLine("oplock swapped-live: the recovery deleted the live holder's lock"); exit 1
}
if (![System.IO.File]::Exists((Join-Path $lock "swapped"))) {
    [Console]::Error.WriteLine("oplock swapped-live: the recovery deleted the live holder's file"); exit 1
}

[Console]::Out.WriteLine("OPLOCK-OK")
LOCKEXTRACT

cases=$((cases + 1))
lock_status=0
lock_out=$("$pwsh_binary" -NoProfile -NonInteractive -File "$lock_extract" "$installer" "$work" 2>"$work/oplock.err") || lock_status=$?
if [ "$lock_status" -ne 0 ] || [ "$lock_out" != "OPLOCK-OK" ]; then
    printf 'ps-installer (operation lock): the stale recovery failed: %s\n' \
        "$(head -3 "$work/oplock.err" | tr '\n' ' ')" >&2
    failures=$((failures + 1))
fi
if [ "$failures" -ne 0 ]; then
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
printf 'ps-installer-contract checks passed: cases=%s pwsh=%s binder=%s crash-leftover=covered operation-lock=covered %s %s\n' \
    "$cases" "$("$pwsh_binary" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')" "$pwsh_binder" "$platform_gate_state" "$staging_state"
