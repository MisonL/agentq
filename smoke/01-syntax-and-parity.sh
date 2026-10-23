#!/usr/bin/env bash
# Smoke: every asset parses under the interpreter that will run it, and the two
# canonical server assets are byte-identical.
#
#   shell assets  -> bash -n and zsh -n
#   .ps1 assets   -> PowerShell AST parse; reports 'skipped(pwsh-absent)' if pwsh
#                    is missing and 'skipped(pwsh-unusable)' (plus a failure) if
#                    pwsh is on PATH but cannot run -- an environment fault must
#                    not be reported as seven broken assets.  The same AST pass
#                    also runs the static rules (ps1_static): a name assigned
#                    only $null must not be read, a name assigned anywhere
#                    must be read somewhere, and no .NET API may be used that
#                    .NET Framework 4.x lacks -- Windows PowerShell 5.1 and
#                    PowerShell 7.x must both be able to run these assets
#                    (see the rule comments below)
#   .plist assets -> XML well-formedness, plus plutil -lint on macOS
#   .yml assets   -> YAML parse (python3 + pyyaml)
#   .service      -> structural check: required sections and keys, absolute
#                    ExecStart; systemd-analyze is Linux-only and not required
#   .cmd assets   -> structural check: no CRLF assumptions, and every .cmd must
#                    delegate to the .ps1 beside it with the same flags
#   canonical     -> assets/unix/agentq-server == assets/windows-git-bash/agentq
#   version       -> AgentQ's own version is one X.Y.Z recorded in the POSIX
#                    installer, the Windows installer, the server and README.md,
#                    and both success lines interpolate it -- not Pueue's
#                    release_version
#   tools         -> every probe tool is inventoried; one that is missing turns
#                    the summary into skipped(tool-...), which run-tests.sh
#                    routes to its PART bucket instead of a green ok
#   repo scripts  -> no pipeline into a quiet grep (`grep -q`/`-m`): it exits
#                    before draining stdin, so any upstream stage can take
#                    SIGPIPE and pipefail turns a FOUND match into "absent".
#                    Writer-agnostic on purpose -- function writers and
#                    absolute paths both escaped the first, printf-only rule.
#                    `grep -c` is excluded: it must read every line.
#   redirects     -> no `cmd < "$f" 2>/dev/null`: the `2>` is applied AFTER the
#                    open, so the shell's own error escapes it
#   local hazards -> no assignment inside a function to a name another function
#                    declares `local`: bash resolves it through the DYNAMIC
#                    scope and writes into the caller's frame
#
# The shell-asset list is computed ONCE (shell_assets below) and used by every
# rule that scans them.  It used to be spelled out at each rule; three copies of
# one file list is the shape this repo has been bitten by repeatedly (fix one,
# miss two).
#
# These are syntax and shape checks, not behaviour.  A .cmd can be
# well-formed and still wrong; a plist can parse and still be rejected by
# launchd.  They exist because these files had NO parsing coverage at all --
# a malformed plist or a YAML typo shipped silently.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
failures=0
shell_count=0

# Every shell asset, in one place: the file set the pipe lock, the redirect lock
# and the local-hazard lock all scan.  A single source for the list means adding
# an asset cannot silently leave one rule behind.
shell_assets=$(
    find "$root/skill/assets" -type f \
        \( -name '*.sh' -o -name 'agentq' -o -name 'agentq-server' -o -name 'sshp' \
        -o -name 'durable-move' -o -name 'start-daemon' \) | sort
)
# The gate belongs HERE, not on any one consumer: an empty list makes every
# rule that scans it pass vacuously, and measuring it per-rule is how one of
# them (the redirect lock) ended up with no check at all.  The pipe lock's own
# count is a different number -- it also counts the smoke scripts -- so it
# could never have caught an empty ASSET list.
if [ -z "$shell_assets" ]; then
    printf '%s\n' 'no shell assets were enumerated for the static shell rules; refusing to report a pass' >&2
    failures=$((failures + 1))
fi

check_shell() {
    local file=$1
    if ! bash -n "$file"; then
        printf 'bash -n FAILED: %s\n' "${file#"$root"/}" >&2
        failures=$((failures + 1))
    fi
    if command -v zsh >/dev/null 2>&1; then
        if ! zsh -n "$file"; then
            printf 'zsh -n FAILED: %s\n' "${file#"$root"/}" >&2
            failures=$((failures + 1))
        fi
    fi
}

# Every file whose shebang names a shell interpreter, so a newly added asset
# cannot escape parsing just because its name has an unexpected extension.
while IFS= read -r file; do
    check_shell "$file"
    shell_count=$((shell_count + 1))
done < <(find "$root/skill/assets" -type f -exec sh -c '
    first=$(head -1 "$1" 2>/dev/null) || exit 0
    case "$first" in
        "#!"*) ;;
        *) exit 0 ;;
    esac
    interpreter=${first#\#!}
    interpreter=${interpreter##* }
    case "$interpreter" in
        *sh) printf "%s\n" "$1" ;;
    esac
' _ {} \; | sort)

ps_count=0
# `command -v pwsh` only proves the binary is on PATH, not that it RUNS.  A
# pwsh whose startup cache is corrupt aborts on every invocation -- and then
# every .ps1 asset is reported as "PowerShell parse FAILED", which points the
# operator at seven correct files instead of at pwsh.  Measured twice in this
# project (2026-09-26 and 2026-09-28): a damaged
# ~/.cache/powershell/StartupProfileData-NonInteractive makes pwsh die with
# `Abort trap: 6` before it reads any script, and the two crashes did not even
# share a message (`String cannot have zero length` vs `Stack overflow`).
# So probe it once, and if it cannot run, say THAT instead of blaming the assets.
pwsh_state=absent
if command -v pwsh >/dev/null 2>&1; then
    pwsh_probe_status=0
    pwsh -NoProfile -NonInteractive -Command 'exit 0' >/dev/null 2>&1 || pwsh_probe_status=$?
    if [ "$pwsh_probe_status" -eq 0 ]; then
        pwsh_state=usable
    else
        pwsh_state=unusable
        printf 'pwsh is on PATH but cannot run (exit %s); the .ps1 assets were NOT checked.\n' "$pwsh_probe_status" >&2
        printf 'This is an environment fault, not an asset fault -- a corrupt pwsh startup cache does this.\n' >&2
        printf 'Try: mv ~/.cache/powershell/StartupProfileData-NonInteractive{,.broken}   # pwsh regenerates it\n' >&2
        failures=$((failures + 1))
    fi
fi

# Encoding rule, independent of pwsh: a .ps1 that is not pure ASCII MUST carry
# a UTF-8 BOM.  Windows PowerShell 5.1 decodes a BOM-less script with the ANSI
# code page, so a non-ASCII byte inside a STRING LITERAL silently becomes
# mojibake -- measured on the windows CI job (run 37810470283): the literal
# `任务` reached the payload as `ä»»åŠ¡`.  A non-ASCII byte in a COMMENT is
# harmless today, but the rule is byte-level because "comment vs literal" is
# exactly what a later edit can change.  The launcher carries a BOM already;
# the other six assets are ASCII, which is the simplest state to keep.
ps1_encoding_failures=0
while IFS= read -r file; do
    bom=$(head -c 3 "$file" | od -An -tx1 | tr -d ' \n')
    if [ "$bom" = "efbbbf" ]; then
        continue
    fi
    if LC_ALL=C grep -q '[^[:print:][:space:]]' "$file"; then
        printf 'non-ASCII in a BOM-less .ps1: %s (PowerShell 5.1 decodes it with the ANSI code page; add a UTF-8 BOM or keep the file ASCII)\n' "${file#"$root"/}" >&2
        ps1_encoding_failures=$((ps1_encoding_failures + 1))
    fi
done < <(find "$root/skill/assets" -type f -name '*.ps1' | sort)
if [ "$ps1_encoding_failures" -ne 0 ]; then
    failures=$((failures + ps1_encoding_failures))
fi
ps1_encoding_summary=checked

if [ "$pwsh_state" = usable ]; then
    parse_ps1=$(mktemp "${TMPDIR:-/tmp}/agentq-parse-ps1.XXXXXX.ps1")
    trap 'rm -f -- "$parse_ps1"' EXIT
    cat > "$parse_ps1" <<'PSEOF'
param([string]$Path)
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host ("line " + $_.Extent.StartLineNumber + ": " + $_.Message) }
    exit 1
}
exit 0
PSEOF
    while IFS= read -r file; do
        if ! pwsh -NoProfile -NonInteractive -File "$parse_ps1" -Path "$file" >/dev/null; then
            printf 'PowerShell parse FAILED: %s\n' "${file#"$root"/}" >&2
            pwsh -NoProfile -NonInteractive -File "$parse_ps1" -Path "$file" >&2 || true
            failures=$((failures + 1))
        fi
        ps_count=$((ps_count + 1))
    done < <(find "$root/skill/assets" -type f -name '*.ps1' | sort)
    ps_summary=$ps_count

    # --- PowerShell variable rules ------------------------------------------
    # Two defects found by reading the assets, both invisible to the parse above
    # and to every behavioural check (the installers only run on a Windows host):
    #
    #  1. `2> $smokeLogErrorPath` in Assert-PueueSmokeLogContainsToken, where
    #     that name was assigned ONLY `$null`, and only in the CALLING function.
    #     PowerShell's dynamic scope resolves the name from the caller, so the
    #     redirect quietly became `2> $null` -- and the cleanup branch guarding
    #     it could never run.  Measured on this host: `2> $null` and `2> <a
    #     variable holding $null>` both discard the child's stderr and create no
    #     file.  The defect is not the discard; it is that the code SAYS it is
    #     capturing stderr to a file it will clean up, and does neither.
    #  2. `$health = Get-PueueHealthFromTemporaryFile ...` where the value is
    #     never read.  The call must stay -- it is the validation -- but the
    #     bare `$name =` reads as "the result matters" and, more importantly,
    #     invites a future edit to drop the assignment: the installer's success
    #     stream IS its JSON response, so an unconsumed return would land in
    #     front of it.
    #
    # Rule 1: a variable assigned only $null must not be read.  A `[ref]`
    # parameter is exempt -- the callee writes it, which is why it starts $null.
    # Rule 2: a variable assigned somewhere must be read SOMEWHERE in the file.
    # File-wide, not function-scoped, on purpose: dynamic scope lets a callee
    # read the caller's variable, so a function-scoped read set would report
    # false positives.  That makes rule 2 blind to a name that is written in one
    # function and read in another -- the direction that is safe here, since a
    # missed read only means a missed warning, never a false alarm.
    #
    # Neither rule is `PSUseDeclaredVarsMoreThanAssignments`: it misses rule 1
    # entirely (the name IS read), and it flags the `[ref]` out-parameters.
    rules_ps1=$(mktemp "${TMPDIR:-/tmp}/agentq-ps-static-rules.XXXXXX.ps1")
    trap 'rm -f -- "$parse_ps1" "$rules_ps1"' EXIT
    cat > "$rules_ps1" <<'PSEOF'
param([string]$Root, [switch]$Calibrate)

$errors = $null; $tokens = $null

# Preference and automatic variables are read by the RUNTIME, not by any
# expression in the file, so a static read-collector cannot see their reads.
$runtimeRead = @('erroractionpreference','progresspreference','warningpreference',
    'verbosepreference','debugpreference','informationpreference','confirmpreference',
    'whatifpreference','outputencoding','ofs')

# Static members that exist on .NET Core (PowerShell 7.x) but NOT on .NET
# Framework 4.x (Windows PowerShell 5.1).  Each entry carries the portable
# alternative, because the point of the rule is that the FIX is mechanical.
# Measured 2026-10-19 on pwsh 7.5.4: [System.IO.File].GetMethods() lists
# Move(String, String) and Move(String, String, Boolean).
#
# The list must stay SHORT and true.  The first version of this rule also
# carried Directory.Move and File.Move arity 2 -- the opposite mistake, with
# the same effect on the reader: a rule that flags portable code.
# Directory.Move is BCL since 2.0 and File.Move(a, b) likewise; they belong on
# the allowed side.  Both are gone, and the calibration fixture now calls the
# two-argument File.Move so the always-correct form is refused if it returns.
$coreOnlyTraps = @(
    @{ Type = 'System.IO.File';      Member = 'Move';     Arity = 3;
       Why = 'File.Move(a, b, overwrite) is .NET Core 3.0+ only; when the destination exists use [System.IO.File]::Replace (2.0+), otherwise the 2-arg File.Move' },
    @{ Type = 'System.IO.Path';      Member = 'Join';     Arity = -1;
       Why = 'Path.Join is .NET Core 2.0+ only; use [System.IO.Path]::Combine' },
    @{ Type = 'System.IO.File';      Member = 'ReadAllTextAsync';  Arity = -1; Why = 'the async file APIs are Core-only' },
    @{ Type = 'System.IO.File';      Member = 'WriteAllTextAsync'; Arity = -1; Why = 'the async file APIs are Core-only' },
    @{ Type = 'System.IO.File';      Member = 'AppendAllTextAsync'; Arity = -1; Why = 'the async file APIs are Core-only' }
)

# Two traps that take an INSTANCE receiver, so the static-member loop below
# cannot see them.  [string]::Contains does not exist on any runtime (measured
# 2026-10-19 on pwsh 7.5.4: "[System.String] does not contain a method named
# 'Contains'"), and String.Contains(String, StringComparison) is .NET Core 2.1+
# only with no 5.1 form at all.  The calibration fixture exercises both.
#
# Type names both entries so the STATIC form is caught too: `[string]::Contains`
# is the same nonexistent member written as a static call, and the first version
# of this table only looked at instance receivers, so that spelling escaped.
# Instance receivers carry no type, so the member/arity match stands alone there.
$instanceOnlyTraps = @(
    @{ Type = 'System.String'; Member = 'Contains'; Arity = 2;
       Why = 'String.Contains(String, StringComparison) is .NET Core 2.1+ only (and String has no static Contains on any runtime); use IndexOf(...) -ge 0' }
)

function Get-PsStaticViolations {
    param([string]$Path)

    $out = New-Object System.Collections.ArrayList
    $err = $null; $tok = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$err)
    if ($err.Count) { return $out }   # the parse pass owns syntax failures
    $name = Split-Path -Leaf $Path

    # --- rule 1: a variable whose only value is $null must not be read --------
    # A name is DECLARED by an assignment, a foreach loop variable, or a
    # parameter.  The foreach case cost a false positive: `$e = $null` followed
    # by `foreach ($e in ...)` assigns a REAL value every iteration, but a
    # ForEachStatementAst is not an AssignmentStatementAst, so the null-only map
    # saw a variable that is null forever and flagged legal code.
    $nullOnly = @{}
    $record = {
        param($varAst, $isNull, $line)
        $n = $varAst.VariablePath.UserPath
        if ($n -eq 'null' -or $n.Contains(':')) { return }
        $k = $n.ToLower()
        if (-not $nullOnly.ContainsKey($k)) { $nullOnly[$k] = @{ Real = $false; Line = $line; Name = $n } }
        if (-not $isNull) { $nullOnly[$k].Real = $true }
    }
    foreach ($a in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $l = $a.Left
        if ($l -is [System.Management.Automation.Language.ConvertExpressionAst]) { $l = $l.Child }
        if (-not ($l -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }
        $rhs = $a.Right
        if ($rhs -is [System.Management.Automation.Language.PipelineAst] -and $rhs.PipelineElements.Count -eq 1) { $rhs = $rhs.PipelineElements[0] }
        if ($rhs -is [System.Management.Automation.Language.CommandExpressionAst]) { $rhs = $rhs.Expression }
        if ($rhs -is [System.Management.Automation.Language.ParenExpressionAst]) { $rhs = $rhs.Pipeline }
        if ($rhs -is [System.Management.Automation.Language.PipelineAst] -and $rhs.PipelineElements.Count -eq 1) { $rhs = $rhs.PipelineElements[0] }
        if ($rhs -is [System.Management.Automation.Language.CommandExpressionAst]) { $rhs = $rhs.Expression }
        $isNull = ($rhs -is [System.Management.Automation.Language.VariableExpressionAst] -and $rhs.VariablePath.UserPath -eq 'null')
        & $record $l $isNull $a.Extent.StartLineNumber
    }
    foreach ($fe in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        & $record $fe.Variable $false $fe.Extent.StartLineNumber
    }
    $refUsed = @{}
    foreach ($c in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ConvertExpressionAst] }, $true)) {
        if ($c.Type.TypeName.Name -eq 'ref' -and $c.Child -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $refUsed[$c.Child.VariablePath.UserPath.ToLower()] = $true
        }
    }
    foreach ($v in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $k = $v.VariablePath.UserPath.ToLower()
        if (-not $nullOnly.ContainsKey($k) -or $nullOnly[$k].Real -or $refUsed.ContainsKey($k)) { continue }
        $p = $v.Parent
        if ($p -is [System.Management.Automation.Language.AssignmentStatementAst] -and $p.Left -eq $v) { continue }
        if ($p -is [System.Management.Automation.Language.ConvertExpressionAst] -and $p.Parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and $p.Parent.Left -eq $p) { continue }
        if ($p -is [System.Management.Automation.Language.ParameterAst]) { continue }
        if ($p -is [System.Management.Automation.Language.ForEachStatementAst]) { continue }
        [void]$out.Add(("{0}:{1}: `${2} is assigned only `$null (line {3}) but read here; the read can never see anything else" -f $name, $v.Extent.StartLineNumber, $nullOnly[$k].Name, $nullOnly[$k].Line))
    }

    # --- rule 2: a name assigned somewhere must be read somewhere -------------
    # File-wide, not function-scoped, on purpose: dynamic scope lets a callee
    # read the caller's variable, so a function-scoped read set would report
    # false positives.  The cost is blindness to write-here/read-there, which
    # can only MISS a warning, never raise a false one.
    $assigned = @{}
    foreach ($a in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $l = $a.Left
        if ($l -is [System.Management.Automation.Language.ConvertExpressionAst]) { $l = $l.Child }
        if (-not ($l -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }
        $raw = $l.VariablePath.UserPath
        if ($raw -match '^env:') { continue }   # an environment write IS the side effect
        if ($raw.Contains(':')) { $raw = $raw.Substring($raw.LastIndexOf(':') + 1) }
        $k = $raw.ToLower()
        if ($raw -eq 'null' -or $runtimeRead -contains $k -or $k.StartsWith('_')) { continue }
        if (-not $assigned.ContainsKey($k)) { $assigned[$k] = @($raw, $a.Extent.StartLineNumber) }
    }
    $read = @{}
    foreach ($v in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $p = $v.Parent
        if ($p -is [System.Management.Automation.Language.AssignmentStatementAst] -and $p.Left -eq $v) { continue }
        if ($p -is [System.Management.Automation.Language.ConvertExpressionAst] -and $p.Parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and $p.Parent.Left -eq $p) { continue }
        $raw = $v.VariablePath.UserPath
        if ($raw.Contains(':')) { $raw = $raw.Substring($raw.LastIndexOf(':') + 1) }
        $read[$raw.ToLower()] = $true
    }
    foreach ($k in ($assigned.Keys | Sort-Object)) {
        if ($read.ContainsKey($k)) { continue }
        [void]$out.Add(("{0}:{1}: `${2} is assigned and never read anywhere in the file; the call is for its side effect, so say so (`$null = ... or [void](...))" -f $name, $assigned[$k][1], $assigned[$k][0]))
    }

    # --- rule 3: only .NET APIs that exist on BOTH runtimes -------------------
    # The deployment unit has to run under Windows PowerShell 5.1 (.NET
    # Framework) and PowerShell 7.x (.NET Core); a Core-only member is not a
    # parse error and not a lint hit -- it is a RUNTIME binding failure on 5.1,
    # and 5.1 is what the .cmd/.bash launchers use.  This is the check that the
    # local suite could not otherwise perform, because pwsh 7 is the only
    # engine the suite runs on here.
    #
    # The type name is RESOLVED before it is compared.  Originally the
    # comparison was ieq against the table's long form, so `[IO.File]::Move(a,
    # b, $true)` -- legal PowerShell, same .NET type -- matched nothing and the
    # rule was blind to it (measured: the written name is `IO.File`, and
    # `[IO.File]::Move` is what a short-form edit produces).  A profile-blind
    # rule is worse than none when its whole purpose is a second engine the
    # development host does not have.  GetReflectionType() is the resolver
    # PowerShell itself uses for `[IO.File]`, so `[IO.File]` and
    # `[System.IO.File]` both arrive as System.IO.File and `[File]` -- which
    # resolves only with a `using namespace` this repo does not use -- arrives
    # empty and falls back to the written name, i.e. matches the table only
    # when the table itself is written that way.
    foreach ($n in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        $member = $n.Member.Extent.Text
        $arity = @($n.Arguments).Count
        if ($n.Static) {
            if (-not ($n.Expression -is [System.Management.Automation.Language.TypeExpressionAst])) { continue }
            $written = $n.Expression.TypeName.FullName
            $resolved = ''
            try { $resolved = $n.Expression.TypeName.GetReflectionType().FullName } catch { }
            if ([string]::IsNullOrEmpty($resolved)) { $resolved = $written }
            # Both tables: the instance table carries a Type precisely so its
            # static spelling (`[string]::Contains`, nonexistent on every
            # runtime) is caught here as well.
            foreach ($t in @($coreOnlyTraps) + @($instanceOnlyTraps)) {
                if (($resolved -ieq $t.Type -or $written -ieq $t.Type) -and $member -ieq $t.Member -and ($t.Arity -eq -1 -or $arity -eq $t.Arity)) {
                    [void]$out.Add(("{0}:{1}: [{2}]::{3} with {4} argument(s) -- {5}" -f $name, $n.Extent.StartLineNumber, $resolved, $member, $arity, $t.Why))
                }
            }
        } else {
            # An instance receiver can be any object, and its type is not
            # recoverable by static analysis here (the assets always call
            # $variable.Contains(...)).  Member + arity alone is therefore NOT
            # enough: HashSet<T>.Contains(item, comparer) has the same shape as
            # the defect and is portable -- an earlier version of this rule
            # reported it, which is the false-positive class that gets a rule
            # switched off.  The second argument is the discriminator (see
            # below).  The STATIC spelling of the same trap is caught by the
            # static arm above, which is why the entry carries a Type.
            foreach ($t in $instanceOnlyTraps) {
                if (-not ($member -ieq $t.Member -and $arity -eq $t.Arity)) { continue }
                # Member+arity alone is not the defect: HashSet<T>.Contains(x,
                # comparer) takes two arguments, is portable, and this repo
                # constructs eight Generic.List[string] collections already --
                # a rule that cries wolf on that gets switched off.  The
                # discriminator is the SECOND ARGUMENT: only the String overload
                # takes a StringComparison, and that overload is the Core-only
                # one.  So require the second argument to be a member access on
                # System.StringComparison (`[System.StringComparison]::Ordinal`).
                # A StringComparison held in a VARIABLE is not resolved here --
                # recorded as a blind spot rather than guessed at; the shape the
                # assets would actually write is the inline member.
                $second = @($n.Arguments)[$arity - 1]
                $comparisonType = ''
                if ($second -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    $second.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) {
                    try { $comparisonType = $second.Expression.TypeName.GetReflectionType().FullName } catch { }
                }
                if ($comparisonType -ine 'System.StringComparison') { continue }
                [void]$out.Add(("{0}:{1}: .{2} with {3} argument(s) and a StringComparison -- {4}" -f $name, $n.Extent.StartLineNumber, $member, $arity, $t.Why))
            }
        }
    }

    return $out
}

if ($Calibrate) {
    # A rule that has never been shown to accept legal code is a rule that gets
    # switched off the first time it cries wolf; a rule that has never been
    # shown to reject the defect is a rule that may match nothing at all.  Both
    # fixtures travel with the rule.
    $calibration = Join-Path ([System.IO.Path]::GetTempPath()) ("agentq-psstatic-" + $PID)
    $null = New-Item -ItemType Directory -Path $calibration -Force
    try {
        $legal = Join-Path $calibration 'legal.ps1'
        Set-Content -LiteralPath $legal -Value @'
Set-StrictMode -Version Latest
function Get-Legal {
    param([string]$Path)
    $literal = $null
    $parsed = [int]::TryParse("5", [ref]$literal)
    Write-Host "parsed=$parsed literal=$literal"
    foreach ($item in @(1, 2)) { Write-Host "in loop: $item" }
    $entry = $null
    foreach ($entry in @(1, 2)) { Write-Host "released after: $entry" }
    $table = @{ LiteralPath = $Path }
    Get-Item @table | Out-Null
    $env:AGENTQ_CALIBRATION = "1"
    [System.IO.File]::Move($Path, "$Path.moved")
    if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace("$Path.new", $Path, "$Path.bak", $true) }
    [System.IO.Directory]::Move("$Path.a", "$Path.b")
    Write-Host ("contains: " + ([string]::Join(",", @("a", "b"))))
    if ($Path.IndexOf("x", [System.StringComparison]::Ordinal) -ge 0) { Write-Host "found" }
    if ($Path.Contains("x")) { Write-Host "plain contains is fine" }
    # A two-argument Contains on a COLLECTION is portable and must stay legal:
    # HashSet<T>.Contains(item, comparer) takes two arguments, and this repo
    # constructs Generic.List/HashSet collections in eight places.  The rule
    # keys on the StringComparison argument, not on member+arity, so this
    # fixture turns red if that discrimination is ever lost.
    $set = [System.Collections.Generic.HashSet[string]]::new()
    if ($set.Contains("x", [System.StringComparer]::OrdinalIgnoreCase)) { Write-Host "collection contains is fine" }
}
function Use-Legal { Get-Legal -Path "/tmp" }
Use-Legal
'@
        $defect = Join-Path $calibration 'defect.ps1'
        Set-Content -LiteralPath $defect -Value @'
Set-StrictMode -Version Latest
function Invoke-Outer {
    $errorPath = $null
    Invoke-Inner
    $health = Get-Item -LiteralPath "/tmp"
    [System.IO.File]::Move("/tmp/a", "/tmp/b", $true)
    [IO.File]::Move("/tmp/c", "/tmp/d", $true)
    $text = "abc"
    if ($text.Contains("b", [System.StringComparison]::Ordinal)) { Write-Host "hit" }
}
function Invoke-Inner {
    & sh -c 'true' 2> $errorPath
}
Invoke-Outer
'@
        $legalOut = Get-PsStaticViolations -Path $legal
        if ($legalOut.Count -ne 0) {
            Write-Host "calibration FAILED: the rules reject legal code ($($legalOut.Count) violations)"
            $legalOut | ForEach-Object { Write-Host "  $_" }
            exit 2
        }
        $defectOut = Get-PsStaticViolations -Path $defect
        if ($defectOut.Count -ne 5) {
            Write-Host "calibration FAILED: the rules found $($defectOut.Count) violations in the defect fixture, expected 5"
            $defectOut | ForEach-Object { Write-Host "  $_" }
            exit 2
        }
        Write-Host "ps-static rules calibrated (legal=0 defects=5)"
    } finally {
        Remove-Item -LiteralPath $calibration -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$violations = 0
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.ps1 | Sort-Object FullName)
if ($files.Count -eq 0) { Write-Host "no .ps1 assets were enumerated under $Root"; exit 2 }
foreach ($file in $files) {
    $found = Get-PsStaticViolations -Path $file.FullName
    foreach ($line in $found) { Write-Host $line; $violations++ }
}
if ($violations -gt 0) { exit 1 }
if (-not $Calibrate) { Write-Host ("ps-static rules ok (NOT calibrated): files={0}" -f $files.Count) }
exit 0
PSEOF
    # -Calibrate is not optional.  It runs the rule over a LEGAL fixture and a
    # DEFECT fixture built inside the script, and refuses to report on the
    # assets unless the rule accepts the first and flags the second.  Without
    # it, a rule that has quietly stopped matching anything reads exactly like
    # a clean tree -- the failure mode this repo has already paid for twice
    # (smoke/01's own config-pattern extraction, smoke/10's rule A).
    if ! pwsh -NoProfile -NonInteractive -File "$rules_ps1" -Root "$root/skill/assets" -Calibrate >/dev/null; then
        printf '%s\n' 'PowerShell static rules FAILED (a $null-only variable that is read, an assignment nobody reads, or a .NET API that is missing on Windows PowerShell 5.1):' >&2
        pwsh -NoProfile -NonInteractive -File "$rules_ps1" -Root "$root/skill/assets" -Calibrate >&2 || true
        failures=$((failures + 1))
    fi
    ps_static_rules=ok
else
    # Do not let a missing OR broken parser read as "the .ps1 assets were
    # checked".  These are distinct states: absent means the check could not run
    # here, unusable means the environment is broken -- and the latter already
    # counted a failure above.  "skipped(tool-absent)" names the tool inventory
    # below as the reason, so the summary line points at what is missing.
    case $pwsh_state in
        absent) ps_summary='skipped(tool-absent)' ;;
        *) ps_summary="skipped(pwsh-$pwsh_state)" ;;
    esac
    ps_static_rules='skipped(pwsh-'"$pwsh_state"')'
fi

# --- tool inventory ----------------------------------------------------------
# Each probe silently stops checking something when its tool is missing, and
# "the check ran" then depends on the environment, not on the assets -- the
# same shape as the pwsh case above, which this project has now hit in four
# different tools (pwsh, pyyaml, zsh, xmllint).  So every tool this check needs
# is probed once and reported in the summary line as tool_full=N/M; when one is
# missing the summary carries skipped(tool-<names>), which run-tests.sh routes
# to its PART bucket (an honest "ran, but not fully") instead of a green ok.
# plutil is deliberately NOT in this list: it only exists on macOS, the plist
# loop documents "plutil -lint where available", and the macOS CI job is where
# that lint runs.  Counting it here would mark every Linux run partial by
# design and drown out the real gaps.
tool_total=0
tool_present=0
tool_missing=
tool_note() {
    local label=$1
    shift
    tool_total=$((tool_total + 1))
    if "$@" >/dev/null 2>&1; then
        tool_present=$((tool_present + 1))
    else
        tool_missing="$tool_missing,$label"
    fi
}
tool_note pwsh test "$pwsh_state" = usable
tool_note xmllint command -v xmllint
tool_note zsh command -v zsh
tool_note pyyaml python3 -c 'import yaml'
tool_note cmp command -v cmp
tool_note find command -v find
tool_summary=0
if [ -n "$tool_missing" ]; then
    tool_summary="skipped(tool-${tool_missing#,})"
fi

# --- .plist: XML well-formedness, and plutil -lint where available -----------
plist_count=0
plist_summary=0
while IFS= read -r file; do
    plist_count=$((plist_count + 1))
    if command -v xmllint >/dev/null 2>&1; then
        if ! xmllint --noout "$file" 2>&1; then
            printf 'plist XML FAILED: %s\n' "${file#"$root"/}" >&2
            failures=$((failures + 1))
            continue
        fi
    fi
    if command -v plutil >/dev/null 2>&1; then
        if ! plutil -lint "$file" >/dev/null 2>&1; then
            printf 'plutil -lint FAILED: %s\n' "${file#"$root"/}" >&2
            plutil -lint "$file" >&2 || true
            failures=$((failures + 1))
            continue
        fi
    fi
    plist_summary=$((plist_summary + 1))
done < <(find "$root/skill/assets" -type f -name '*.plist' | sort)

# --- .yml: real YAML parse ---------------------------------------------------
yaml_count=0
yaml_summary=0
if python3 -c 'import yaml' >/dev/null 2>&1; then
    while IFS= read -r file; do
        yaml_count=$((yaml_count + 1))
        if ! python3 -c 'import sys, yaml
try:
    yaml.safe_load(open(sys.argv[1], "rb").read())
except Exception as exc:
    print(exc, file=sys.stderr)
    sys.exit(1)' "$file"; then
            printf 'YAML parse FAILED: %s\n' "${file#"$root"/}" >&2
            failures=$((failures + 1))
            continue
        fi
        yaml_summary=$((yaml_summary + 1))
    done < <(find "$root/skill/assets" -type f -name '*.yml' | sort)
else
    yaml_summary='skipped(no pyyaml)'
fi

# --- .service: structural ----------------------------------------------------
# systemd-analyze verify needs systemd, which macOS does not have, so this
# asserts the shape the unit must have rather than asking systemd.  An
# ExecStart that is not an absolute path is the failure this catches -- a
# relative one is accepted by systemd's parser and then fails at boot.
service_count=0
service_summary=0
while IFS= read -r file; do
    service_count=$((service_count + 1))
    service_ok=true
    for section in '[Unit]' '[Service]' '[Install]'; do
        grep -qF -- "$section" "$file" || {
            printf 'service FAILED (missing %s): %s\n' "$section" "${file#"$root"/}" >&2
            service_ok=false
        }
    done
    # systemd expands %h to the user's home, which is absolute, so an ExecStart
    # beginning with %h is as valid as one beginning with /.  Anything else --
    # a bare relative path, or a bare command name -- is accepted by systemd's
    # parser and then fails at boot.
    if ! grep -qE '^ExecStart=(/|%h/)[^ ]' "$file"; then
        printf 'service FAILED (ExecStart must start with / or %%h/): %s\n' "${file#"$root"/}" >&2
        service_ok=false
    fi
    if ! grep -qE '^WantedBy=' "$file"; then
        printf 'service FAILED (no WantedBy in [Install]): %s\n' "${file#"$root"/}" >&2
        service_ok=false
    fi
    if [ "$service_ok" = true ]; then
        service_summary=$((service_summary + 1))
    else
        failures=$((failures + 1))
    fi
done < <(find "$root/skill/assets" -type f -name '*.service' | sort)

# --- .cmd: structural --------------------------------------------------------
# There is no CMD parser here, so this checks the two things that actually
# break these shims: the delegation target must exist, and every .cmd must pass
# the same PowerShell flags.  A .cmd that drops -NonInteractive changes
# behaviour on a host with an interactive console, and that difference is
# invisible until something prompts.
cmd_count=0
cmd_summary=0
while IFS= read -r file; do
    cmd_count=$((cmd_count + 1))
    cmd_ok=true
    target=$(sed -n 's/.*-File "%~dp0\([^"]*\)".*/\1/p' "$file" | head -1)
    if [ -z "$target" ]; then
        printf 'cmd FAILED (no -File "%%~dp0<target>" delegation): %s\n' "${file#"$root"/}" >&2
        cmd_ok=false
    elif [ ! -f "${file%/*}/$target" ]; then
        printf 'cmd FAILED (delegates to a missing file %s): %s\n' "$target" "${file#"$root"/}" >&2
        cmd_ok=false
    fi
    # -NonInteractive must match the script being delegated to, not be present
    # unconditionally.  agentq.ps1 has no interactive construct and must never
    # block on a prompt; sshp.ps1 calls Read-Host (Confirm-Install) and drives
    # `ssh -tt` for a human session, so forcing -NonInteractive on it would
    # break the very thing it exists for.  Requiring the flag everywhere is
    # wrong, and so is omitting it everywhere -- the invariant is agreement.
    cmd_has_flag=true
    # Comments are excluded before matching.  Without this, deleting the real
    # `-NonInteractive` from the command line and leaving a `rem -NonInteractive`
    # behind kept the flag test true (measured 2026-10-21) -- the same
    # "explanation satisfies the rule" hole smoke/12's stdin-guard lock closes
    # by stripping comment lines.
    # awk, NOT a printf-to-grep pipeline.  Under `set -o pipefail` a `grep -q`
    # exits on its FIRST match and closes the pipe; printf then dies with
    # SIGPIPE (141), and the pipeline reports failure even though the match was
    # found -- a rule that was meant to say PRESENT says ABSENT.  Measured
    # 2026-10-21 in a full suite run: this rule reported sshp.cmd as
    # "delegates to a non-interactive script but omits -NonInteractive" with
    # `printf: write error: Broken pipe` on stderr.  sshp.cmd omits the flag on
    # purpose, so the wrong half is the TARGET predicate: sshp.ps1 does call
    # Read-Host (line 903) and that pipeline still reported no match.  The
    # trigger was not isolatable: the same pipeline over the same bytes passed
    # 500 times standalone, 200 more under CPU load; a forced >64 KiB payload
    # is the only reproducible form (rc=141).  Mechanism measured, rate not.
    # One process, no pipe, no race.  [Rr][Ee][Mm]: BSD awk has no IGNORECASE.
    if awk '!/^[[:space:]]*(@?[Rr][Ee][Mm]([[:space:]]|$)|::)/ && /-NonInteractive/ { found = 1; exit } END { exit !found }' "$file"; then
        cmd_has_flag=true
    else
        cmd_has_flag=false
    fi
    target_has_interactive=false
    if [ -n "$target" ] && [ -f "${file%/*}/$target" ]; then
        # Same exclusion on the target: a `# Read-Host` comment must not make a
        # non-interactive script look interactive (which would invert the rule
        # and REQUIRE the flag to be dropped).
        if awk '!/^[[:space:]]*#/ && /Read-Host|ShouldContinue|ReadKey/ { found = 1; exit } END { exit !found }' "${file%/*}/$target"; then
            target_has_interactive=true
        fi
    fi
    if [ "$target_has_interactive" = false ] && [ "$cmd_has_flag" = false ]; then
        printf 'cmd FAILED (delegates to a non-interactive script but omits -NonInteractive): %s\n' "${file#"$root"/}" >&2
        cmd_ok=false
    fi
    if [ "$target_has_interactive" = true ] && [ "$cmd_has_flag" = true ]; then
        printf 'cmd FAILED (delegates to an interactive script but forces -NonInteractive): %s\n' "${file#"$root"/}" >&2
        cmd_ok=false
    fi
    if [ "$cmd_ok" = true ]; then
        cmd_summary=$((cmd_summary + 1))
    else
        failures=$((failures + 1))
    fi
done < <(find "$root/skill/assets" -type f -name '*.cmd' | sort)

if ! cmp -s "$root/skill/assets/unix/agentq-server" "$root/skill/assets/windows-git-bash/agentq"; then
    printf '%s\n' 'canonical server parity FAILED: assets/unix/agentq-server != assets/windows-git-bash/agentq' >&2
    failures=$((failures + 1))
fi

# --- AgentQ's own version: one value, six records ---------------------------
# The 2026-10-08 defect this replaces: both installers printed Pueue's
# release_version (the value that builds the download URL) as AgentQ's own, and
# nothing noticed because nothing read either value.  The six records -- the two
# installers, the server (doctor reports it as agentq=), README.md, and the two
# CLIENTS (whose constants were added to this comparison 2026-10-21 after a
# one-sided bump went unnoticed) -- must agree and be X.Y.Z.  The success lines
# must interpolate the AgentQ value: a revert to release_version leaves every
# definition agreeing, so the values alone cannot catch that shape.  Same lesson
# as rule E for the launcher protocol: one mechanism copied into several files
# stays consistent only if a check compares the copies.
version_summary=0
version_posix_line=$(grep -m1 '^agentq_version=' "$root/skill/assets/unix/install-agentq.sh" || true)
version_posix=${version_posix_line#agentq_version=}
version_posix=${version_posix#\'}
version_posix=${version_posix%\'}
version_windows_line=$(grep -m1 '^\$agentqVersion = ' "$root/skill/assets/windows-git-bash/install-agentq.ps1" || true)
version_windows=${version_windows_line#* = }
version_windows=${version_windows#\"}
version_windows=${version_windows%\"}
version_server_line=$(grep -m1 '^agentq_version=' "$root/skill/assets/unix/agentq-server" || true)
version_server=${version_server_line#agentq_version=}
version_server=${version_server#\'}
version_server=${version_server%\'}
# The two CLIENT constants belong in this comparison too.  Measured 2026-10-21:
# bumping only `agentq_client_version` in the POSIX client (or only
# $script:ClientVersion in the Windows one) left every check green -- the
# single-deployment-unit rule (CLAUDE.md) exists precisely because clients and
# server are upgraded together, and the one file that carries a client version
# was the one file nothing compared.
version_unix_client_line=$(grep -m1 '^agentq_client_version=' "$root/skill/assets/client/unix/agentq" || true)
version_unix_client=${version_unix_client_line#agentq_client_version=}
version_unix_client=${version_unix_client#\'}
version_unix_client=${version_unix_client%\'}
version_windows_client_line=$(grep -m1 '^\$script:ClientVersion = ' "$root/skill/assets/client/windows/agentq.ps1" || true)
version_windows_client=${version_windows_client_line#* = }
version_windows_client=${version_windows_client#\"}
version_windows_client=${version_windows_client%\"}
version_readme_line=$(grep -m1 '^\*\*Version:\*\* ' "$root/README.md" || true)
version_readme=${version_readme_line#\*\*Version:\*\* }
version_readme=${version_readme%% *}

version_recorded=
version_check_record() {
    # $1 label, $2 value
    if [ -z "$2" ]; then
        printf 'version FAILED: no AgentQ version recorded for the %s\n' "$1" >&2
        failures=$((failures + 1))
        return
    fi
    if ! grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<< "$2"; then
        printf 'version FAILED: the %s records "%s", which is not X.Y.Z\n' "$1" "$2" >&2
        failures=$((failures + 1))
        return
    fi
    version_recorded="$version_recorded $2"
}
version_check_record 'POSIX installer' "$version_posix"
version_check_record 'Windows installer' "$version_windows"
version_check_record 'server' "$version_server"
version_check_record 'README' "$version_readme"
version_check_record 'POSIX client' "$version_unix_client"
version_check_record 'Windows client' "$version_windows_client"

version_unique_count=0
if [ -n "$version_recorded" ]; then
    version_unique_count=$(printf '%s\n' $version_recorded | sort -u | grep -c . || true)
fi
if [ -z "$version_recorded" ]; then
    printf '%s\n' 'version FAILED: no version was extracted from any of the six files; refusing to report a pass' >&2
    failures=$((failures + 1))
elif [ "$version_unique_count" -ne 1 ]; then
    printf 'version FAILED: the six records disagree -- POSIX installer "%s", Windows installer "%s", server "%s", README "%s", POSIX client "%s", Windows client "%s"\n' \
        "$version_posix" "$version_windows" "$version_server" "$version_readme" "$version_unix_client" "$version_windows_client" >&2
    failures=$((failures + 1))
else
    version_summary=$version_posix
fi

version_posix_success=$(grep -m1 -F 'installed at' "$root/skill/assets/unix/install-agentq.sh" || true)
case $version_posix_success in
    *'${agentq_version}'*) ;;
    *)
        printf '%s\n' 'version FAILED: install-agentq.sh success line does not interpolate ${agentq_version} -- the 2026-10-08 defect printed Pueue release_version there' >&2
        failures=$((failures + 1))
        ;;
esac
version_windows_success=$(grep -m1 -F 'installed at' "$root/skill/assets/windows-git-bash/install-agentq.ps1" || true)
case $version_windows_success in
    *'$agentqVersion'*) ;;
    *)
        printf '%s\n' 'version FAILED: install-agentq.ps1 success line does not interpolate $agentqVersion -- the 2026-10-08 defect printed Pueue releaseVersion there' >&2
        failures=$((failures + 1))
        ;;
esac

# --- config-file path patterns must still point at real files ----------------
# .gitattributes and .editorconfig name paths in order to protect them, and a
# pattern that matches nothing is not an error in either format -- it simply
# stops protecting.  When the Skill moved under skill/ on 2026-09-29,
# .editorconfig's `[assets/**]` kept parsing fine and matched zero files, so the
# section that exists to stop editors rewriting the byte-verified assets became
# a silent no-op.  Verified with a real editorconfig implementation: the two
# canonical servers resolved to end_of_line=lf / trim_trailing_whitespace=true,
# i.e. exactly what that section was written to prevent.
#
# So: every path-qualified pattern in these two files must match a real file.
config_patterns=0
config_failures=0

glob_to_regex() {
    local glob=$1 out= i=0 n c d
    # n must be computed AFTER `local glob=$1`: in `local glob=$1 n=${#glob}`
    # the expansion happens before the assignment, so n would be 0 and this
    # function would emit an empty pattern that matches nothing.
    n=${#glob}
    while [ "$i" -lt "$n" ]; do
        c=${glob:$i:1}
        case $c in
            '*')
                if [ "${glob:$((i + 1)):1}" = '*' ]; then
                    if [ "${glob:$((i + 2)):1}" = / ]; then
                        out="$out(.*/)?"; i=$((i + 3))
                    else
                        out="$out.*"; i=$((i + 2))
                    fi
                else
                    out="$out[^/]*"; i=$((i + 1))
                fi
                ;;
            '?') out="$out[^/]"; i=$((i + 1)) ;;
            '{')
                local inner= j=$((i + 1)) depth=1
                while [ "$j" -lt "$n" ] && [ "$depth" -gt 0 ]; do
                    d=${glob:$j:1}
                    [ "$d" = '{' ] && depth=$((depth + 1))
                    [ "$d" = '}' ] && depth=$((depth - 1))
                    [ "$depth" -gt 0 ] && inner="$inner$d"
                    j=$((j + 1))
                done
                out="$out(${inner//,/|})"; i=$j
                ;;
            '.'|'+'|'('|')'|'|'|'^'|'$'|'['|']'|'\\') out="$out\\$c"; i=$((i + 1)) ;;
            *) out="$out$c"; i=$((i + 1)) ;;
        esac
    done
    printf '%s' "$out"
}

pattern_matches_under() {
    local re f rel start=$root
    re="^$(glob_to_regex "$1")\$"
    [ -n "${2:-}" ] && start="$root/$2"
    while IFS= read -r f; do
        rel=${f#"$root"/}
        if [[ $rel =~ $re ]]; then
            return 0
        fi
    done < <(find "$start" -path "$root/.git" -prune -o -type f -print)
    return 1
}

pattern_matches_a_file() {
    pattern_matches_under "$1" ''
}

for config_file in .editorconfig .gitattributes; do
    [ -f "$root/$config_file" ] || continue
    while IFS= read -r pattern; do
        case $pattern in
            */*) ;;
            *) continue ;;
        esac
        config_patterns=$((config_patterns + 1))
        if ! pattern_matches_a_file "$pattern"; then
            printf '%s\n' "$config_file: pattern '$pattern' matches no file in the repository" >&2
            config_failures=$((config_failures + 1))
            failures=$((failures + 1))
        fi
    done < <(
        if [ "$config_file" = .editorconfig ]; then
            sed -n 's/^\[\(.*\)\]$/\1/p' "$root/$config_file"
        else
            sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$root/$config_file" | awk '{print $1}'
        fi
    )
done

# ...and the section that protects the assets must still exist.  Deleting it
# leaves every surviving pattern valid, so the rule above stays green while the
# protection is gone -- measured: removing the [skill/assets/**] section drops
# configpaths from 3 to 2 and the check reports a pass.
asset_protection=0
section=
while IFS= read -r line; do
    case $line in
        \[*\])
            section=${line#\[}
            section=${section%\]}
            continue
            ;;
    esac
    case $line in
        *end_of_line*unset*)
            if [ -n "$section" ] && pattern_matches_under "$section" skill/assets; then
                asset_protection=$((asset_protection + 1))
            fi
            ;;
    esac
done < "$root/.editorconfig"
if [ "$asset_protection" -eq 0 ]; then
    printf '%s\n' '.editorconfig: no section sets end_of_line = unset for anything under skill/assets -- the byte-verified assets are no longer protected from editor rewrites' >&2
    failures=$((failures + 1))
fi

# A pattern count of zero means the extraction broke, not that there was
# nothing to check -- the same reasoning as the shell-asset enumeration above.
if [ "$config_patterns" -eq 0 ]; then
    printf '%s\n' 'no config-file path patterns were extracted; refusing to report a pass' >&2
    failures=$((failures + 1))
fi

# Zero shell assets parsed means the enumeration itself failed (missing find,
# wrong root), not that there was nothing to check.
if [ "$shell_count" -eq 0 ]; then
    printf '%s\n' 'no shell assets were enumerated; refusing to report a pass' >&2
    failures=$((failures + 1))
fi

# --- repo scripts: no pipeline into a quiet grep -----------------------------
# The hazard is described in the .cmd rule above and in the header.  Every site
# found on 2026-10-21 was converted, most to `grep ... <<< "$VAR"`; this lock
# keeps the shape from returning.  Comment lines are skipped, so the rules'
# own explanations may keep naming the pattern.  The diagnostic text is
# deliberately worded WITHOUT the literal pipe, so this rule cannot flag its
# own file.
repo_pipe_count=0
repo_script_count=0
# The invariant is on the CONSUMER, not the writer: `grep -q` (and `-m`) exit
# before draining stdin, so ANY upstream stage can take SIGPIPE, and under
# pipefail that makes the pipeline non-zero even when the pattern matched --
# `if !` then reads a found match as absent.  So the rule bans every pipeline
# whose last stage is a quiet grep, whatever writes into it and however the
# command is spelled (absolute paths like /usr/bin/grep escaped the first
# version, which expected whitespace before the token).  `grep -c` is NOT
# matched: it must read every line to count, so it cannot cause the race.
# `(^|[^|])` keeps `a || grep -q file` from matching -- that is a fallback,
# not a pipeline.
#
# `-[a-zA-Z]*[qm]` -- the `m` arm was MISSING until 2026-10-22 even though the
# comment above always said `-q` (and `-m`): the old pattern ended in `q`, so
# `| grep -m1` (same SIGPIPE mechanism, `-m` also exits at its match limit)
# passed the lock.  A flag cluster ending in either letter is now caught;
# `-c` still is not, and `-q`/`-m` inside a longer cluster (`-Eq`, `-m1`) is.
# A pipeline SPLIT ACROSS LINES escapes the regex above, and that is not
# hypothetical: `cat file | \` on one line and `grep -q pattern` on the next is
# an ordinary way to format a long pipeline, and the per-line match sees neither
# a `|` followed by grep nor a grep preceded by `|`.  Measured 2026-10-22: the
# two-line form matched NOTHING while the one-line form was caught.  So logical
# lines are joined first, on BOTH continuations the shell honours: a trailing
# backslash, and a trailing `|` (which continues the command just as surely --
# `cat x |` / newline / `grep -q y` is one pipeline).  This is the same join
# smoke/02's rules 1 and 2 already do.
repo_pipe_scan() {
    awk '
        {
            line = $0
            if (pending != "") { line = pending " " line; pending = "" }
            if (line ~ /\\[[:space:]]*$/ || line ~ /[|][[:space:]]*$/) {
                sub(/\\[[:space:]]*$/, "", line)
                pending = line
                next
            }
            printf "%d:%s\n", NR, line
        }
        END { if (pending != "") printf "%d:%s\n", NR, pending }
    ' "$1"
}
repo_pipe_re='(^|[^|])[|][^|;&]*grep[^|;&]*(-[a-zA-Z]*[qm]|[[:space:]]--(quiet|max-count|silent))'
while IFS= read -r repo_script; do
    repo_script_count=$((repo_script_count + 1))
    repo_hits=$(repo_pipe_scan "$repo_script" 2>/dev/null | grep -E "$repo_pipe_re" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    if [ -n "$repo_hits" ]; then
        while IFS= read -r repo_hit; do
            printf 'repo script FAILED (a pipeline into a quiet grep reads a FOUND match as absent under pipefail): %s: %s\n' \
                "${repo_script#"$root"/}" "$repo_hit" >&2
            repo_pipe_count=$((repo_pipe_count + 1))
        done <<EOF
$repo_hits
EOF
        failures=$((failures + 1))
    fi
done <<EOF
$(find "$root/smoke" -type f -name '*.sh' | sort)
$root/run-tests.sh
$root/sandbox.sh
$shell_assets
EOF
if [ "$repo_script_count" -eq 0 ]; then
    printf '%s\n' 'no repo scripts were enumerated for the pipe-lock; refusing to report a pass' >&2
    failures=$((failures + 1))
fi

# A `2>/dev/null` written ON a redirection does not suppress the shell's own
# open error: `cmd < "$f" 2>/dev/null` still prints `bash: <f>: No such file or
# directory`, because that message is written BEFORE the redirect applies.
# Measured 2026-10-23: the same command inside `{ ...; } 2>/dev/null` is silent,
# so the two spellings differ in meaning and only the grouped one is a
# suppression.  This matters because the clients capture the remote stderr to
# look for `reason=`: a benign concurrent delete then leaves unexplained text on
# a call that succeeded.  Rule: no asset may rely on the no-op spelling.
#
# The rule is about the CONSTRUCT, not about a file being deleted: it fires on
# the spelling alone, so it keeps working on code paths nobody has raced yet.
#
# `(^|[^<])` before the `<` excludes a HERE-STRING (`<<<"$body" 2>/dev/null`),
# which is not a file redirect at all and cannot fail to open: the first draft
# of this rule flagged `... <<<"$file_body" 2>/dev/null` in the server, a false
# positive caught by running the rule before trusting it.
redir_noop_count=0
local_hazard_count=0
# Collected into a variable and tested for emptiness, exactly like the pipe lock
# above.  A `while read` over an empty heredoc runs ONCE with an empty string
# (the substitution yields one blank line), so the first version reported a
# violation with no file and no line -- a false red on a clean tree, caught by
# running the rule before trusting it.
redir_noop_hits=$(
    while IFS= read -r repo_script; do
        repo_pipe_scan "$repo_script" 2>/dev/null |
            grep -E '(^|[^<])<[[:space:]]*"\$[^"]*"[[:space:]]+2>/dev/null' |
            grep -vE '^[0-9]+:[[:space:]]*#' |
            sed "s|^|${repo_script#"$root"/}:|" || true
    done <<SCRIPTS
$shell_assets
SCRIPTS
)
if [ -n "$redir_noop_hits" ]; then
    while IFS= read -r redir_hit; do
        [ -n "$redir_hit" ] || continue
        printf 'repo script FAILED (2>/dev/null on a redirect does not suppress the shell open error; wrap the command in { ...; } instead): %s\n' \
            "$redir_hit" >&2
        redir_noop_count=$((redir_noop_count + 1))
    done <<EOF
$redir_noop_hits
EOF
    failures=$((failures + 1))
fi

# --- shell assets: unlocalized writes into a caller's local ------------------
# bash resolves an unqualified assignment through the DYNAMIC scope: a write to
# a name the callee did not declare `local` lands in whichever frame up the
# stack declared it -- or in the global scope.  Measured 2026-10-23 with a
# two-function probe: the callee's bare write is visible to a caller that
# declared `local` for the same name.  The failure mode is silent and the value
# looks like the caller's own.
#
# The rule: inside a function, an assignment to a name that some OTHER function
# declares `local` must itself be declared `local` in the assigning function.
# The ONE sanctioned exception is read_lock_metadata's out-parameters
# (lock_pid, lock_identity): that function's contract is to publish them for the
# caller, and its header says so.  Any other hit is a real hazard, not a style
# nit -- the two this rule was built from (tombstone_body, and main's
# task_id/status_mode/doctor_mode) were both introduced by the same author in
# the same session as the code they broke.
#
# Every shell asset under skill/assets is scanned (the quiet-grep lock next to
# this one taught the same lesson: a lock scoped to the file it was found in has
# a one-file hole).  Honest limit, recorded rather than papered over: the POSIX
# client, sshp and both installers never use `local` at all, so this rule cannot
# fire on them -- they pass through their state as deliberate globals.  Today
# the only assets that can trip it are the server's two canonical copies; the
# wider root means any future shell asset that DOES use `local` is covered
# without anyone having to remember to widen the lock again.
#
# A name never declared `local` anywhere is NOT flagged: it is a deliberate
# global (the cleanup trap's file variables, the exported env, IFS).  Disabling
# the allowlist line below makes the rule print exactly the two sanctioned
# out-parameters and nothing else (measured 2026-10-23), which is how the
# allowlist's width was checked -- the same measurement also confirms nothing
# in the tree needs a THIRD exception.
local_hazard_prog=$(
    cat <<'AWK'
FNR == 1 { depth = 0; infn = 0 }
function leading(s,   i) {
    i = 1
    while (i <= length(s) && (substr(s, i, 1) == " " || substr(s, i, 1) == "\t")) i++
    return substr(s, 1, i - 1)
}
/^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\) \{/ {
    # Functions may be NESTED (the server defines a jq() wrapper inside
    # install_jq_line_ending_shim).  A parser that only sees a column-0
    # definition treats the nested body as part of its parent, so a write
    # inside the nested function is blamed on the parent -- a false negative
    # exactly where the parent happens to declare the same name local.  Track
    # a stack keyed by the definition's own indentation: the matching close is
    # the first line that is exactly that indentation followed by "}".
    depth++
    fn = $0; sub(/^[[:space:]]*/, "", fn); sub(/\(\).*/, "", fn)
    stackfn[depth] = fn; stacklead[depth] = leading($0); infn = 1; next
}
infn && $0 == stacklead[depth] "}" {
    depth--; infn = (depth > 0); next
}
!infn { next }
{
    line = $0
    if (line ~ /^[[:space:]]*#/) next
    if (line ~ /^[[:space:]]*local[[:space:]]/) {
        # Peel the `local` keyword off FIRST, then split what is left.  The
        # first version split the whole indented line and skipped the fields
        # that were "" or "local" -- which worked only because this awk happens
        # to emit an empty leading field for a whitespace separator.  Peeling
        # first removes the reliance on that field-counting rule, so the rule
        # reads the same names on every awk (mawk and gawk disagree with BWK
        # awk about the leading empty field; that difference is the one thing
        # here that would silently change the rule's verdict between hosts).
        decl = line
        sub(/^[[:space:]]*local[[:space:]]+/, "", decl)
        n = split(decl, parts, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
            v = parts[i]; sub(/=.*/, "", v)
            gsub(/[^A-Za-z0-9_]/, "", v)
            if (v != "") { local[fn, v] = 1; declared[v] = 1 }
        }
    }
    while (match(line, /(^|[;&|]|then|do|else)[[:space:]]*[A-Za-z_][A-Za-z0-9_]*([+]=|=)/)) {
        seg = substr(line, RSTART, RLENGTH)
        # The match ends with '=', and a greedy `.*[^A-Za-z0-9_]` would consume
        # the whole name along with it (measured: the first version returned ""
        # for every assignment and the rule was silently green on a violation).
        sub(/=.*$/, "", seg)
        sub(/[+]$/, "", seg)
        sub(/.*[^A-Za-z0-9_]/, "", seg)
        if (seg != "") { assigned[fn, seg] = 1; fns[fn] = 1; names[seg] = 1 }
        line = substr(line, RSTART + RLENGTH)
    }
    # `if NAME=...` / `elif` / `while` / `until` are assignment statements too,
    # and the loop above cannot see them: none of its preceders is a member of
    # that set.  This is not a hypothetical gap -- it hid a real site in the
    # server (`if probe=$( {...} | jq ... )` in
    # task_instance_created_at_is_recorded, where another function declares
    # `local probe`).  A second pass, deliberately kept separate: the keyword
    # must stand ALONE (the preceding character is not a word character), so
    # `otherwise_x=` and `verify_x=` are not read as `else`/`if`.  Without that
    # boundary the name extraction would strip the keyword's tail and report a
    # variable that does not exist.
    # A `#` starts a comment (this ignores quoting: a `#` inside a string is
    # read as one too).  That direction is deliberate -- a quoted `#` can only
    # make the pass MISS a real site, never invent one, and inventing one would
    # redden a correct tree.  Measured 2026-10-23: without this, a trailing
    # comment carrying `# if zzz=2` was reported as a violation in a function
    # that assigns nothing of the sort.
    hashpos = index($0, "#")
    if (hashpos == 0) hashpos = length($0) + 1
    p = 1
    while (p <= length($0)) {
        if (!match(substr($0, p), /(then|do|else|if|elif|while|until)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*([+]=|=)/)) break
        kwpos = p + RSTART - 1
        if (kwpos >= hashpos) break
        pre = (kwpos == 1) ? "" : substr($0, kwpos - 1, 1)
        if (pre == "" || pre !~ /[A-Za-z0-9_]/) {
            v = substr($0, kwpos, RLENGTH)
            sub(/=.*/, "", v)
            sub(/[+]$/, "", v)
            sub(/^.*[[:space:]]/, "", v)
            if (v ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
                assigned[fn, v] = 1; fns[fn] = 1; names[v] = 1
            }
        }
        p = kwpos + RLENGTH
    }
}
END {
    for (f in fns) for (v in names) {
        if (!((f, v) in assigned)) continue
        if ((f, v) in local) continue
        if (!(v in declared)) continue
        if (f == "read_lock_metadata" && (v == "lock_pid" || v == "lock_identity")) continue
        printf "%s: %s\n", f, v
    }
}
AWK
)
local_hazard_files=$shell_assets
local_hazard_file_count=$(printf '%s\n' "$local_hazard_files" | grep -c . || true)
local_hazard_hits=$(
    while IFS= read -r hazard_asset; do
        [ -n "$hazard_asset" ] || continue
        awk "$local_hazard_prog" "$hazard_asset" |
            sed "s|^|${hazard_asset#"$root"/}: |"
    done <<ASSETS
$local_hazard_files
ASSETS
)
local_hazard_hits=$(printf '%s\n' "$local_hazard_hits" | grep . | sort || true)
if [ -n "$local_hazard_hits" ]; then
    while IFS= read -r hazard; do
        [ -n "$hazard" ] || continue
        printf 'server FAILED (an unlocalized write into a caller local: declare it local, or document it as an out-parameter): %s\n' \
            "$hazard" >&2
        local_hazard_count=$((local_hazard_count + 1))
    done <<EOF
$local_hazard_hits
EOF
    failures=$((failures + 1))
fi

# Self-check: a construct-level rule that silently never fires reports the same
# green as a clean tree.  This rule died TWICE while being written -- an empty
# first field from split(), then a greedy sub() that ate the whole name -- and
# both times it printed zero hits on an input that contained the violation.  So
# run it against a planted copy and require it to shout.  The anchor is the
# function header: present in every version of the asset, unlike any statement
# the fixes added.
local_hazard_selftest=$(mktemp)
# Three plants with DISTINCT names -- one per arm of the rule (plain `NAME=`,
# `if NAME=`, `NAME+=`) -- each inserted with its own single-line sed append:
# BSD sed ends an `a` command at the first line that is not backslash-continued,
# so a two-line body in one append silently truncates (measured here).  A plant
# per arm is what makes deleting an arm visible; a single plant only exercises
# whichever arm happens to see it.
sed '/^acquire_request_lock() {$/a\
    maintenance_lock_pid_path=/tmp/planted
' "$root/skill/assets/unix/agentq-server" |
    sed '/^[[:space:]]*maintenance_lock_pid_path=\/tmp\/planted$/a\
    if lock_holder_age=$(true); then :; fi
' | sed '/^[[:space:]]*if lock_holder_age=/a\
    log_encoded+=("appended")
' >"$local_hazard_selftest"
if ! grep -q '^[[:space:]]*maintenance_lock_pid_path=/tmp/planted$' "$local_hazard_selftest" ||
    ! grep -q '^[[:space:]]*if lock_holder_age=' "$local_hazard_selftest"; then
    printf '%s\n' 'server FAILED (the local-hazard self-check could not plant its violations: the anchor moved)' >&2
    failures=$((failures + 1))
    local_hazard_count=$((local_hazard_count + 1))
else
    local_hazard_selftest_report=$(awk "$local_hazard_prog" "$local_hazard_selftest")
    # ONE planted violation per ARM of the rule, with distinct names, so
    # dropping any arm reddens this self-check.  A single plant would only ever
    # exercise whichever arm happens to see it -- and that is not hypothetical:
    # the keyword arm (`if NAME=`) and the append arm (`NAME+=`) were each added
    # because the previous arms could not see that form, and a self-check that
    # could not tell the difference would have reported the removal as green.
    if [ -z "$local_hazard_selftest_report" ]; then
        printf '%s\n' 'server FAILED (the local-hazard rule is silent on a planted violation: the detector itself is broken)' >&2
        failures=$((failures + 1))
        local_hazard_count=$((local_hazard_count + 1))
    else
        if ! grep -q '^acquire_request_lock: maintenance_lock_pid_path$' <<<"$local_hazard_selftest_report"; then
            printf '%s\n' 'server FAILED (the local-hazard rule missed the plain NAME= plant, or blamed the wrong function)' >&2
            failures=$((failures + 1))
            local_hazard_count=$((local_hazard_count + 1))
        fi
        if ! grep -q '^acquire_request_lock: lock_holder_age$' <<<"$local_hazard_selftest_report"; then
            printf '%s\n' 'server FAILED (the local-hazard rule missed the `if NAME=` plant: that pass is not running)' >&2
            failures=$((failures + 1))
            local_hazard_count=$((local_hazard_count + 1))
        fi
        # A THIRD plant for the append form: `NAME+=` is the same hazard, and
        # it is the one that appends to a caller's local instead of replacing
        # it -- a silent widening rather than a silent overwrite.
        if ! grep -q '^acquire_request_lock: log_encoded$' <<<"$local_hazard_selftest_report"; then
            printf '%s\n' 'server FAILED (the local-hazard rule missed the `NAME+=` plant: the append arm is not matching)' >&2
            failures=$((failures + 1))
            local_hazard_count=$((local_hazard_count + 1))
        fi
    fi
fi
rm -f "$local_hazard_selftest"

if [ "$failures" -ne 0 ]; then
    printf 'syntax-and-parity: %s failure(s)\n' "$failures" >&2
    exit 1
fi
summary=$(printf 'syntax-and-parity checks passed: shell=%s ps1=%s ps1_static=%s ps1_encoding=%s plist=%s yml=%s service=%s cmd=%s configpaths=%s parity=ok version=%s tool_full=%s/%s repo_scripts=%s repo_pipes=%s redir_noop=%s local_hazards=%s local_hazard_files=%s' \
    "$shell_count" "$ps_summary" "$ps_static_rules" "$ps1_encoding_summary" "$plist_summary" "$yaml_summary" "$service_summary" "$cmd_summary" "$config_patterns" "$version_summary" "$tool_present" "$tool_total" "$repo_script_count" "$repo_pipe_count" "$redir_noop_count" "$local_hazard_count" "$local_hazard_file_count")
[ "$tool_summary" = 0 ] || summary="$summary $tool_summary"
printf '%s\n' "$summary"
