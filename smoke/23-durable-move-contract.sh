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
    printf '%s\n' 'Durable-move contract NOT run: the pwsh on PATH cannot execute (startup cache).' >&2
    printf '%s\n' 'Try: mv ~/.cache/powershell/StartupProfileData-NonInteractive{,.broken}' >&2
    exit 1
fi

work=$(mktemp -d /tmp/agentq-smoke-durable.XXXXXX)
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
    local status=0
    run_asset "$asset" "$@" >"$work/out" 2>"$work/err" || status=$?
    # PowerShell writes terminating errors to stderr and exits 1.  Assert non-zero
    # rather than exactly 1: the point is that the call was refused, and pinning
    # the numeric code would couple this to PowerShell's version.
    if [ "$status" -eq 0 ]; then
        printf 'durable-move %s: expected a non-zero exit, got 0\n' "$label" >&2
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" <<< "$(flatten_err "$work/err")"; then
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
elif ! grep -q 'GenericRead | GenericWrite' <<< "$access_line"; then
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

# --- the C# body must compile under C# 5 (2026-10-24) ------------------------
# The Add-Type block above is 3.3 KB of C# and NOTHING had ever compiled it:
# the four cases in this file all die in PowerShell's PARAMETER BINDING, before
# a single body statement runs (verified: a script with a missing mandatory
# parameter never reaches its own body).  So a C# 6+ construct in here would
# ship green on a dev Mac -- pwsh 7 compiles C# 6 fine -- and fail on every
# real Windows host, where Add-Type uses .NET Framework's C# 5 compiler.
#
# The oracle is faithful and local: `-CompilerOptions "/langversion:5"` under
# pwsh 7 uses the same C# 5 language rules (measured 2026-10-24: it rejects
# `$"..."` with CS8026 "Feature 'interpolated strings' is not available in
# C# 5" and `?.` with "Feature 'null propagating operator'").  That is a
# LANGUAGE-version match, not a framework-API match -- the API side is rule 3
# of smoke/01's ps1_static (both runtimes must have the member).  Both
# directions are proven: the shipped body compiles (0 errors), and two planted
# C# 6 constructs are rejected by name.
cases=$((cases + 1))
cs_body_file="$work/addtype-body.cs"
python3 - "$asset" > "$cs_body_file" <<'PY'
import io, re, sys
src = io.open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'Add-Type -TypeDefinition @"\n(.*?)\n"@', src, re.S)
if not m:
    sys.exit("could not extract the C# body from the Add-Type here-string")
sys.stdout.write(m.group(1))
PY
if [ ! -s "$cs_body_file" ]; then
    printf 'durable-move: extracted an EMPTY C# body -- the extractor, not the asset, is broken\n' >&2
    failures=$((failures + 1))
else
    # The path travels in an ENVIRONMENT variable, and MSYS bash does NOT
    # rewrite POSIX paths in env vars the way it rewrites command-line
    # arguments -- so on the Windows CI job powershell.exe would receive
    # `/tmp/...` and ReadAllText would fail with "Could not find file",
    # reporting a correct asset as broken.  Convert when cygpath exists.
    cs_body_for_ps=$cs_body_file
    if command -v cygpath >/dev/null 2>&1; then
        cs_body_for_ps=$(cygpath -w -- "$cs_body_file")
    fi
    # The path travels through an ENVIRONMENT variable, not -Command arguments
    # or a positional: measured 2026-10-24, `-Command '<script>' <path>` puts the
    # path in $args reliably only under some hosts, and on macOS a bare .cs path
    # can be handed to LaunchServices ("No application knows how to open URL
    # file:///...") -- the first cut reported both as "TypeDefinition is null".
    # `-CompilerOptions` is a PowerShell 7 parameter -- real 5.1 does not have it,
    # and passing it there fails the BINDING, which would report a correct asset
    # as broken on the Windows CI job.  5.1's Add-Type already uses the C# 5
    # compiler, so on that host the plain call IS the faithful compile; on pwsh 7
    # the switch is what makes it faithful.  Same assertion, dialect-correct
    # spelling -- measured both ways (2026-10-24).
    cs_out=$(AGENTQ_CS_BODY="$cs_body_for_ps" "$pwsh_binary" -NoProfile -NonInteractive -Command '
        $body = [System.IO.File]::ReadAllText($env:AGENTQ_CS_BODY)
        $arguments = @{ TypeDefinition = $body; ErrorAction = "Stop" }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $arguments.CompilerOptions = "/langversion:5" }
        try { Add-Type @arguments; "OK" }
        catch { "FAIL " + $_.Exception.Message.Split([char]10)[0] }' 2>&1) || true
    case $cs_out in
        OK*) ;;
        *)
            printf 'durable-move: the C# body does not compile under C# 5 (Windows PowerShell 5.1 uses that compiler): %s\n' "$cs_out" >&2
            failures=$((failures + 1))
            ;;
    esac
fi

if [ "$failures" -ne 0 ]; then
    printf 'durable-move-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'durable-move-contract checks passed: cases=%s pwsh=%s binder=%s contract=covered access-mask=pinned cs5=compiled behaviour=NOT-covered(needs-Windows)\n' "$cases" \
    "$("$pwsh_binary" -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || printf 'unknown')" "$pwsh_binder"
