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
#                    must be read somewhere, no .NET API may be used that
#                    .NET Framework 4.x lacks, no variable may be written
#                    under an automatic variable's name, and no PowerShell
#                    7-only syntax (??, &&, ternary, ?. -- parse errors on
#                    5.1) may appear at all; the same rules also run over
#                    PowerShell payloads EMBEDDED in shell assets -- Windows
#                    PowerShell 5.1 and PowerShell 7.x must both be able to
#                    run these assets (see the rule comments below)
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
#   uncalled      -> no function with a definition and no call site
#   asset kinds   -> every file in skill/assets belongs to a kind some rule
#                    above parses (extension, or a shebang naming a shell)
#   config files  -> every path-qualified pattern in .gitattributes and
#                    .editorconfig still names a real file, and .editorconfig
#                    still has the section that stops editors rewriting the
#                    byte-verified assets
#   gitattributes -> the attribute VALUES resolve as required, asked of git:
#                    all tracked deployment files keep `text: unset`, and the
#                    two canonical copies keep `merge: unset` (only `-merge`
#                    stops a silent three-way merge; `-diff` does not)
#   gitignore     -> the credential blocklist still blocks: 41 credential
#                    paths ignored BY THIS REPOSITORY's .gitignore, 5 that must
#                    stay visible, the three protection files tracked, and no
#                    tracked file swept up by an over-broad pattern
#
# The shell-asset list is computed ONCE (shell_assets below) and used by every
# rule that scans them -- including the parse arm, whose `shell=` count is
# compared against it.  Until 2026-10-25 the parse arm walked its own
# shebang-based list while the static rules walked a filename list, so the two
# `.bash` assets were parsed by one and invisible to the other, and both numbers
# printed side by side in the summary line.
#
# These are syntax and shape checks, not behaviour.  A .cmd can be
# well-formed and still wrong; a plist can parse and still be rejected by
# launchd.  They exist because these files had NO parsing coverage at all --
# a malformed plist or a YAML typo shipped silently.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
failures=0
shell_count=0

# Every shell asset, in one place: the file set the parse arm, the pipe lock,
# the redirect lock, the mktemp lock, the local-hazard lock and the
# uncalled-function lock all scan.  A single source for the list means adding
# an asset cannot silently leave one rule behind.
#
# The enumeration is BY SHEBANG, not by filename.  Until 2026-10-24 it was a
# name list (`*.sh`, `agentq`, `agentq-server`, `sshp`, ...), and
# `client/windows/agentq.bash` / `sshp.bash` -- two real shell assets whose
# extension is `.bash` -- matched none of those names.  The parse arm was
# already shebang-based (9 files, the `shell=` count) and checked them, while
# every static rule below scanned 7.  Both numbers were printed side by side in
# one summary line and nothing compared them.  A shebang scan cannot develop
# that hole: an asset whose first line names a shell IS a shell asset.
shell_assets=$(
    find "$root/skill/assets" -type f -exec sh -c '
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
' _ {} \; | sort
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

# The parse arm walks the same list the static rules scan.  It used to walk a
# SECOND, shebang-based enumeration while the rules used the name list above --
# two lists, one summary line, and the two `.bash` assets fell in the gap.
while IFS= read -r file; do
    [ -n "$file" ] || continue
    check_shell "$file"
    shell_count=$((shell_count + 1))
done <<SHELL_ASSETS
$shell_assets
SHELL_ASSETS

# --- the repo's OWN entry points (2026-10-25) --------------------------------
# run-tests.sh and sandbox.sh are shell scripts that drive everything else, and
# NOTHING parsed them: the arm above is scoped to skill/assets, and run-tests.sh
# only `bash -n`s the checks it is about to run -- never itself, never sandbox.
# Measured: a syntax error planted in run-tests.sh (before the verdict line)
# leaves `./run-tests.sh --quick` exiting **0** with no PASS/FAIL line at all.
# That is not a hypothetical: bash reaches EOF mid-compound-command, the
# unterminated `if` never executes, the script's last `exit 0` stands, and the
# only trace is a `syntax error` line on stderr that the CI gate never reads
# (it greps stdout for `^PASS checks:`).  So a broken entry point reports a
# green run with the summary silently missing.
#
# Why `bash -n` and NOT the shellcheck lock: measured on shellcheck 0.11.0,
# `shellcheck -s bash -i SC2319,...` **suppresses parse errors too** -- a file
# with SC1046/SC1047 (`Couldn't find 'fi'`) exits 0 under the `-i` spelling the
# repo uses, and only the unrestricted form reports it.  `bash -n` is the
# faithful grammar for both files (both are `#!/usr/bin/env bash`).
repo_entry_failures=0
repo_entry_count=0
for repo_entry in "$root/run-tests.sh" "$root/sandbox.sh"; do
    [ -f "$repo_entry" ] || {
        printf 'repo entry point missing: %s\n' "${repo_entry#"$root"/}" >&2
        repo_entry_failures=$((repo_entry_failures + 1))
        continue
    }
    if ! bash -n "$repo_entry"; then
        printf 'bash -n FAILED (the suite driver itself does not parse; a broken run-tests.sh can still exit 0 with NO summary line): %s\n' \
            "${repo_entry#"$root"/}" >&2
        repo_entry_failures=$((repo_entry_failures + 1))
    fi
    repo_entry_count=$((repo_entry_count + 1))
done
# Self-check: the detector must be able to FAIL.  A `bash -n` wrapper that
# swallowed its status (a `2>&1` without the `if !`) reads exactly like a clean
# tree.  Fixture lives in a temp dir, never in the repo.
repo_entry_selftest=$(mktemp "${TMPDIR:-/tmp}/agentq-entry-parse.XXXXXX")
printf '#!/usr/bin/env bash\necho start\nif [ 1 = 1 ]; then\n    :\n' >"$repo_entry_selftest"
if bash -n "$repo_entry_selftest" 2>/dev/null; then
    printf '%s\n' 'entry-point parser FAILED its self-check (a file with an unterminated `if` parsed clean) -- the detector itself is broken' >&2
    repo_entry_failures=$((repo_entry_failures + 1))
fi
rm -f "$repo_entry_selftest"
failures=$((failures + repo_entry_failures))

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
    # The template ENDS in the X's, deliberately: BSD mktemp (macOS) only
    # randomizes when the X's are last -- `agentq-parse-ps1.XXXXXX.ps1` creates
    # a file with that LITERAL name, so a SIGKILLed run (trap never fires)
    # leaves it behind and every later run dies "File exists" (measured
    # 2026-10-24, after a killed suite).  `pwsh -File` does not require a .ps1
    # extension (measured).  smoke/01's `mktemp_suffix` rule pins this.
    parse_ps1=$(mktemp "${TMPDIR:-/tmp}/agentq-parse-ps1.XXXXXX")
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
    rules_ps1=$(mktemp "${TMPDIR:-/tmp}/agentq-ps-static-rules.XXXXXX")
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
    param([string]$Path, [string]$Text, [string]$DisplayName, [int]$LineOffset = 0, [switch]$ParseErrorsAreViolations, [object[]]$FileTokens = @())

    $out = New-Object System.Collections.ArrayList
    $err = $null; $tok = $null
    if ($Text -ne '') {
        # An embedded payload: parse the supplied text, attribute line numbers
        # back into the shell file that carries it.
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, $DisplayName, [ref]$tok, [ref]$err)
    } else {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$err)
    }
    if ($FileTokens.Count -eq 0) { $FileTokens = @($tok) }
    $name = if ($DisplayName -ne '') { $DisplayName } else { Split-Path -Leaf $Path }
    if ($err.Count) {
        # A .ps1 file's syntax errors are owned by the separate parse pass, so
        # the rules stay quiet about them.  An EMBEDDED payload has no such
        # pass, and a truncated extraction (the shell quoter stops at the first
        # apostrophe inside the payload) would otherwise parse as an error and
        # return an EMPTY list -- a silently skipped payload.  So for payloads
        # the parse error IS the finding.
        if ($ParseErrorsAreViolations) {
            foreach ($e in $err) { [void]$out.Add(("{0}:{1}: embedded PowerShell does not parse -- {2}" -f $name, ($LineOffset + $e.Extent.StartLineNumber), $e.Message)) }
            return $out
        }
        return $out   # the parse pass owns syntax failures
    }
    # An embedded payload starts mid-file, so every reported line is offset by
    # the payload's opening shell line (minus the payload's own line 1).
    # NOTE the name: PowerShell variable names are case-insensitive, so a
    # scriptblock called `$L` would be CLOBBERED by rule 1's `$l = $a.Left`
    # (the same class as the `$lastExitCode` P0 this very rule exists to
    # catch -- caught here by actually hitting it, not by reading).
    $LineOf = { param($n) $LineOffset + $n.Extent.StartLineNumber }

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
        & $record $l $isNull (& $LineOf $a)
    }
    foreach ($fe in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        & $record $fe.Variable $false (& $LineOf $fe)
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
        [void]$out.Add(("{0}:{1}: `${2} is assigned only `$null (line {3}) but read here; the read can never see anything else" -f $name, (& $LineOf $v), $nullOnly[$k].Name, $nullOnly[$k].Line))
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
        if (-not $assigned.ContainsKey($k)) { $assigned[$k] = @($raw, (& $LineOf $a)) }
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
                    [void]$out.Add(("{0}:{1}: [{2}]::{3} with {4} argument(s) -- {5}" -f $name, (& $LineOf $n), $resolved, $member, $arity, $t.Why))
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
                [void]$out.Add(("{0}:{1}: .{2} with {3} argument(s) and a StringComparison -- {4}" -f $name, (& $LineOf $n), $member, $arity, $t.Why))
            }
        }
    }

    # --- rule 4: no assignment to an automatic variable -----------------------
    # The `$lastExitCode` P0 (0.1.16, round ten): $guard and $LASTEXITCODE are
    # the SAME identifier (PowerShell variable names are case-insensitive), so
    # a script-scope assignment REPLACED the integer with a PSVariable and
    # every Windows task reported exit 2 with the real code lost.  Any
    # assignment to an automatic variable is that same class of collision.
    # The one that survived in the assets until 2026-10-24 is `profile`: it is
    # ALSO the automatic variable holding the profile script path, and a
    # script-scope `$profile = ...` clobbers it (measured on pwsh 7.5.4).
    # The list holds the runtime-populated names only.  It deliberately
    # EXCLUDES the preference variables ($ProgressPreference and friends --
    # assignable by design; the assets set $ProgressPreference four times) and
    # $null (the documented discard idiom, `$null = ...`).  It is a SUPERSET of
    # PSScriptAnalyzer's PSAvoidAssignmentToAutomaticVariable set (measured
    # 2026-10-24 against PSSA 1.25.0, one name per probe file): every name PSSA
    # flags is here, plus `lastexitcode` (which PSSA treats as writable and so
    # does not flag, but which is THIS repo's proven P0), `switch`, and
    # `foreach`.  A superset is safe precisely because the check is on WRITES:
    # no legitimate PowerShell writes any of these names.
    # Write shapes covered: assignment LHS, foreach loop variable, param() --
    # all three shadow the automatic name.  Scope-qualified writes
    # (`$script:profile`) are a blind spot, as is any name missing from this
    # list.  PSScriptAnalyzer is the independent oracle that found the class.
    $automaticNames = @('args','consolefilename','error','event','eventargs','eventsubscriber',
        'executioncontext','false','foreach','home','host','input','iscoreclr','islinux',
        'ismacos','iswindows','lastexitcode','matches','myinvocation','nestedpromptlevel','pid',
        'profile','psboundparameters','pscmdlet','pscommandpath','psculture','psdebugcontext',
        'pshome','psitem','psscriptroot','pssenderinfo','psuiculture','psversiontable','pwd',
        'sender','shellid','stacktrace','switch','this','true','_')
    foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $v = $n.Left -as [System.Management.Automation.Language.VariableExpressionAst]
        if ($null -eq $v) { continue }
        if ($automaticNames -ccontains $v.VariablePath.UserPath.ToLowerInvariant()) {
            [void]$out.Add(("{0}:{1}: assignment to automatic variable `${2}` -- PowerShell identifiers are case-insensitive, so this can collide with the runtime variable (the `$lastExitCode` P0); rename it" -f $name, (& $LineOf $n), $v.VariablePath.UserPath))
        }
    }
    foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        $v = $n.Variable -as [System.Management.Automation.Language.VariableExpressionAst]
        if ($null -eq $v) { continue }
        if ($automaticNames -ccontains $v.VariablePath.UserPath.ToLowerInvariant()) {
            [void]$out.Add(("{0}:{1}: foreach loop variable `${2}` shadows the automatic variable of that name -- rename it" -f $name, (& $LineOf $n), $v.VariablePath.UserPath))
        }
    }
    foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
        $v = $n.Name -as [System.Management.Automation.Language.VariableExpressionAst]
        if ($null -eq $v) { continue }
        if ($automaticNames -ccontains $v.VariablePath.UserPath.ToLowerInvariant()) {
            [void]$out.Add(("{0}:{1}: parameter `${2}` shadows the automatic variable of that name -- rename it" -f $name, (& $LineOf $n), $v.VariablePath.UserPath))
        }
    }

    # Measured kinds (pwsh 7.5.4): `??`/`??=` are QuestionQuestion(Equals),
    # `&&`/`||` are AndAnd/OrOr, the ternary `?` is QuestionMark (the
    # Where-Object alias `?` tokenizes as Kind=Generic, so the alias survives).
    # `$x?.y` has NO dedicated kind -- it comes back as a single Variable token
    # whose text ends in `?`, handled by the variable arm below.  `:` is NOT in
    # the list: it is the same kind as a switch label's separator and an
    # unquoted hashtable key (measured), so it would cry wolf.
    $ps7TokenKinds = @('QuestionQuestion','QuestionQuestionEquals','AndAnd','OrOr','QuestionMark')
    foreach ($t in $FileTokens) {
        # `$obj?.Name` tokenizes under pwsh 7 as a single Variable token whose
        # text ends in `?` -- measured 2026-10-24, which is why the variable
        # arm exists: the Kind table alone reports nothing for it.  No
        # legitimate identifier ends in `?`.
        $ps7Variable = ($t.Kind -eq 'Variable' -and $t.Text.Length -gt 1 -and $t.Text.EndsWith('?'))
        if ($ps7TokenKinds -ccontains ([string]$t.Kind) -or $ps7Variable) {
            [void]$out.Add(("{0}:{1}: PowerShell 7-only syntax `{2}` -- this payload reaches Windows PowerShell 5.1 (via .cmd/.bash launchers or sshd), which cannot PARSE it (parse error before the first statement)" -f $name, (& $LineOf $t), $t.Extent.Text))
        }
    }

    return $out
}

# --- the same rules over PowerShell EMBEDDED IN SHELL ASSETS ------------------
# Nine PowerShell payloads live inside the shell assets as single-quoted shell
# strings: three `-Command '...'` arguments in each copy of the server (the
# canonical twins), two `*_script='...'` literals in the POSIX client, one
# `windows_common_script='...'` in sshp.  They are shipped PowerShell and are
# parsed by powershell.exe at runtime, so the rules above must see them too --
# a scan by file EXTENSION is exactly the blind spot that let `$profile`
# survive in all six payloads on 2026-10-24 while the .ps1 half was already
# clean.
#
# The extraction follows shell quoting, not "the next quote": a shell
# single-quoted string ends at the FIRST `'`.  Payloads containing an
# apostrophe are therefore NOT supported by this extractor; a payload that
# gets truncated this way still reports (as a parse error, via
# -ParseErrorsAreViolations), so the failure is loud rather than silent.
#
# A payload written in DOUBLE quotes is a different matter: the shell expands
# it before powershell.exe ever sees it, so `$profile` inside it may already
# have become the shell's own empty variable -- nothing static can be said
# about it.  Those are counted and REPORTED rather than skipped, because
# `-Command "Get-ScheduledTask -TaskName 'AgentQ Pueued' ..."` in the server
# is exactly such a payload: `$`-free today, and silently unchecked forever if
# this arm only looked at single quotes.
#
# The count gate in the main loop refuses to report a pass if the asset tree
# does not yield exactly 9 single-quoted payloads and 2 double-quoted ones, so
# a payload added later (or an extractor regression) cannot be silently
# skipped.  9, not 6: the canonical server twins carry the same three
# single-quoted payloads, and both copies are scanned.
$payloadPattern = "(?m)-Command '|[A-Za-z0-9_]+_script='"
$doubleQuotedPattern = '(?m)-Command "'
function Get-ShellPayloadViolations {
    param([string]$Path)
    $found = New-Object System.Collections.ArrayList
    $shellText = Get-Content -LiteralPath $Path -Raw
    foreach ($m in [regex]::Matches($shellText, $payloadPattern)) {
        $start = $m.Index + $m.Length
        $close = $shellText.IndexOf("'", $start)
        if ($close -lt 0) { continue }
        $body = $shellText.Substring($start, $close - $start)
        $openingLine = ($shellText.Substring(0, $start) -split "`n").Count
        $where = "{0}(shell line {1})" -f (Split-Path -Leaf $Path), $openingLine
        foreach ($v in (Get-PsStaticViolations -Text $body -DisplayName $where -LineOffset ($openingLine - 1) -ParseErrorsAreViolations)) {
            [void]$found.Add($v)
        }
    }
    foreach ($m in [regex]::Matches($shellText, $doubleQuotedPattern)) {
        $start = $m.Index + $m.Length
        $close = $shellText.IndexOf('"', $start)
        if ($close -lt 0) { continue }
        $body = $shellText.Substring($start, $close - $start)
        $openingLine = ($shellText.Substring(0, $start) -split "`n").Count
        $where = "{0}(shell line {1})" -f (Split-Path -Leaf $Path), $openingLine
        if ($body -match '[\$\\]') {
            # Shell expansion makes the runtime text differ from the source
            # text; nothing static can be asserted about such a payload, so it
            # is REPORTED rather than skipped.
            [void]$found.Add(("{0}: double-quoted PowerShell payload contains `$ or backslash -- the shell expands it before powershell.exe sees it, so these rules cannot verify it; rewrite it as a single-quoted payload" -f $where))
            continue
        }
        foreach ($v in (Get-PsStaticViolations -Text $body -DisplayName $where -LineOffset ($openingLine - 1) -ParseErrorsAreViolations)) {
            [void]$found.Add($v)
        }
    }
    return $found
}

# --- the same rules over PowerShell HERE-STRINGS INSIDE .PS1 ASSETS -----------
# The .ps1 clients build remote PowerShell payloads as here-strings and hand
# them to `powershell.exe -EncodedCommand` or `-Command -` (agentq.ps1: the
# launcher wrapper and the protocol probe; sshp.ps1: the Zellij resolver and
# the two invocation bodies, plus the session script).  Those payloads are
# shipped PowerShell that NO check parsed before 2026-10-24 -- the same blind
# spot one level deeper than the shell-embedded payloads above: a rule over
# the .ps1 FILE sees the here-string as one String token, never its contents.
# Measured today: 14 here-strings in the 7 .ps1 assets; 6 parse cleanly as
# PowerShell (the payloads), 4 are shell bodies (skip by content marker --
# `set -eu`, `cygpath`, `#!/`, `command -v`: their `||`/`&&` are shell
# operators, and reporting PS7-only syntax on them would be the false-red the
# repo keeps hitting), and 4 fail to parse at all (the usage text, a C#
# Add-Type body, two shell snippets) -- non-PS, skipped by the parse gate.
# The count gate below pins "6 scanned" so a NEW payload, or a shell body that
# starts looking PS-clean, cannot slip through silently.
$hereShellPattern = '(?m)^\s*(set -[a-z]|cygpath |#!/|command -v )'
function Get-Ps1HereStringViolations {
    param([string]$Path)
    $found = New-Object System.Collections.ArrayList
    $tok = $null; $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$err)
    if ($err.Count) { return $found }   # the parse pass owns a broken .ps1
    $leaf = Split-Path -Leaf $Path
    foreach ($h in $tok) {
        if ($h.Kind -ne 'HereStringLiteral' -and $h.Kind -ne 'HereStringExpandable') { continue }
        # Text = opening marker (2) + newline + body + newline + closing marker (2).
        $body = $h.Text.Substring(2).TrimStart([char]13, [char]10)
        $body = $body.Substring(0, $body.Length - 2)
        if ($body -match $hereShellPattern) { continue }
        $it = $null; $ie = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($body, 'here-classify', [ref]$it, [ref]$ie)
        if (@($ie).Count -gt 0) { continue }   # not PowerShell (C#, usage prose, shell without those markers)
        $base = $h.Extent.StartLineNumber
        $where = "{0}(here-string line {1})" -f $leaf, $base
        foreach ($v in (Get-PsStaticViolations -Text $body -DisplayName $where -LineOffset ($base - 1) -ParseErrorsAreViolations)) {
            [void]$found.Add($v)
        }
    }
    return $found
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
    # A name that merely CONTAINS an automatic variable's name is not that
    # variable: the rule matches the whole user path, not a prefix, so these
    # must stay legal (they are why `$profile` was renamed `$userProfile`
    # rather than `$profilePath`).
    $userProfile = "C:\Users\x"
    $profileItem = Get-Item -LiteralPath $userProfile
    Write-Host "$userProfile $($profileItem.Name)"
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
    $profile = "C:\Users\x"
    Write-Host $profile
    # The P0's exact shape: mixed case still matches the automatic name.
    $LastExitCode = 0
    Write-Host $LastExitCode
    # PowerShell 7-only syntax: `??`, `&&`, ternary, and `$x?.y` -- the last
    # one tokenizes as a VARIABLE whose text ends in `?` (measured), which is
    # why the rule needs a variable arm and not just a Kind table.
    $fallback = $Missing ?? "default"
    Write-Host $fallback
    $coalesced = $null
    $coalesced ??= 2
    Write-Host $coalesced
    $ok = $true && $false
    Write-Host $ok
    $either = $false || $true
    Write-Host $either
    $pick = $Missing ? "a" : "b"
    Write-Host $pick
    $len = $Missing?.Length
    Write-Host $len
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
        if ($defectOut.Count -ne 13) {
            Write-Host "calibration FAILED: the rules found $($defectOut.Count) violations in the defect fixture, expected 13"
            $defectOut | ForEach-Object { Write-Host "  $_" }
            exit 2
        }
        # The embedded-payload arm needs its own calibration: it has a shell
        # quoter in front of the parser, and a quoter that extracts the wrong
        # span would report a clean tree forever.  The fixture below is a shell
        # file with one legal payload and one that writes an automatic
        # variable; the arm must find exactly that one, at the right shell line.
        $shellFixture = Join-Path $calibration 'payload-fixture.sh'
        Set-Content -LiteralPath $shellFixture -Value @'
#!/bin/sh
legit=$(powershell.exe -NoProfile -Command '
    $ProgressPreference = "SilentlyContinue"
    $userProfile = "C:\Users\x"
    Write-Output $userProfile
')
broken=$(powershell.exe -NoProfile -Command '
    $ProgressPreference = "SilentlyContinue"
    $profile = "C:\Users\x"
    Write-Output $profile
')
'@
        $payloadOut = @(Get-ShellPayloadViolations -Path $shellFixture)
        if ($payloadOut.Count -ne 1 -or $payloadOut[0] -notmatch 'payload-fixture\.sh\(shell line 7\):9: assignment to automatic variable \$profile') {
            Write-Host "calibration FAILED: the embedded-payload arm found $($payloadOut.Count) violations in its fixture, expected exactly 1 naming `$profile at shell line 9"
            $payloadOut | ForEach-Object { Write-Host "  $_" }
            exit 2
        }
        # The double-quoted arm: a `$`-free payload is checked like any other,
        # and a payload the shell would expand is REPORTED, not skipped.  Both
        # directions here, because this arm exists to prevent silent skipping.
        $doubleFixture = Join-Path $calibration 'payload-double.sh'
        Set-Content -LiteralPath $doubleFixture -Value @'
#!/bin/sh
legal=$(powershell.exe -NoProfile -Command "Write-Output 'ok'")
expanded=$(powershell.exe -NoProfile -Command "Write-Output $profile")
'@
        $doubleOut = @(Get-ShellPayloadViolations -Path $doubleFixture)
        if ($doubleOut.Count -ne 1 -or $doubleOut[0] -notmatch 'payload-double\.sh\(shell line 3\): double-quoted PowerShell payload contains') {
            Write-Host "calibration FAILED: the double-quoted arm found $($doubleOut.Count) violations in its fixture, expected exactly 1 reporting the shell-expanded payload"
            $doubleOut | ForEach-Object { Write-Host "  $_" }
            exit 2
        }
        # The here-string arm, both directions: a legal PS payload in a .ps1
        # file must pass (it carries $userProfile, the POST-rename name), and a
        # here-string carrying an automatic-variable write must be named at the
        # right line.  The fixture file must itself parse cleanly -- the arm
        # returns early on a broken file, which would otherwise read as a pass.
        $hereFixture = Join-Path $calibration 'here-fixture.ps1'
        Set-Content -LiteralPath $hereFixture -Value @'
$clean = @"
$ProgressPreference = "SilentlyContinue"
$userProfile = "C:\Users\x"
Write-Output $userProfile
"@
Write-Output $clean
'@
        $hereOut = @(Get-Ps1HereStringViolations -Path $hereFixture)
        if ($hereOut.Count -ne 0) {
            Write-Host "calibration FAILED: the here-string arm rejected the legal fixture ($($hereOut.Count) violations)"
            $hereOut | ForEach-Object { Write-Host "  $_" }
            exit 2
        }
        $hereBad = Join-Path $calibration 'here-bad.ps1'
        Set-Content -LiteralPath $hereBad -Value @'
$payload = @"
$ProgressPreference = "SilentlyContinue"
$profile = "C:\Users\x"
Write-Output $profile
"@
Write-Output $payload
'@
        $hereBadOut = @(Get-Ps1HereStringViolations -Path $hereBad)
        if ($hereBadOut.Count -ne 1 -or $hereBadOut[0] -notmatch 'here-bad\.ps1\(here-string line 1\):2: assignment to automatic variable \$profile') {
            Write-Host "calibration FAILED: the here-string arm found $($hereBadOut.Count) violations in its defect fixture, expected exactly 1 naming `$profile at here-string line 1:2"
            $hereBadOut | ForEach-Object { Write-Host "  $_" }
            exit 2
        }
        Write-Host "ps-static rules calibrated (legal=0 defects=13 payloads=1 double=1 here=1)"
    } finally {
        Remove-Item -LiteralPath $calibration -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$violations = 0
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.ps1 | Sort-Object FullName)
if ($files.Count -eq 0) { Write-Host "no .ps1 assets were enumerated under $Root"; exit 2 }
$hereScanned = 0
foreach ($file in $files) {
    $found = Get-PsStaticViolations -Path $file.FullName
    foreach ($line in $found) { Write-Host $line; $violations++ }
    # Count the PowerShell here-string payloads this file contributes, so the
    # gate below can tell "6 payloads checked" from "the extractor broke and
    # silently skipped them all".
    $tokProbe = $null; $errProbe = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokProbe, [ref]$errProbe)
    foreach ($h in $tokProbe) {
        if ($h.Kind -ne 'HereStringLiteral' -and $h.Kind -ne 'HereStringExpandable') { continue }
        $body = $h.Text.Substring(2).TrimStart([char]13, [char]10)
        $body = $body.Substring(0, $body.Length - 2)
        if ($body -match $hereShellPattern) { continue }
        $it = $null; $ie = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($body, 'here-classify', [ref]$it, [ref]$ie)
        if (@($ie).Count -gt 0) { continue }
        $hereScanned++
    }
    foreach ($line in (Get-Ps1HereStringViolations -Path $file.FullName)) { Write-Host $line; $violations++ }
}
if ($hereScanned -ne 6) {
    Write-Host ("PowerShell here-string payload count is {0}, expected 6 -- the extractor no longer sees them, so a pass here would mean nothing" -f $hereScanned)
    exit 2
}

# --- the same rules over PowerShell EMBEDDED IN SHELL ASSETS ------------------
# (the extractor and its calibration live above, next to the rule they serve)
# The counter below is incremented INSIDE a ForEach-Object scriptblock; that is
# load-bearing and measured (2026-10-24): ForEach-Object runs in the CURRENT
# scope, so `$violations++` reaches this variable, while a `& { ... }` script
# block would run in a child scope and silently drop every count.
$payloadCount = 0
$doubleQuotedCount = 0
Get-ChildItem -LiteralPath $Root -Recurse -File |
    Where-Object { $_.Extension -ne '.ps1' } |
    Sort-Object FullName |
    ForEach-Object {
        $raw = Get-Content -LiteralPath $_.FullName -Raw
        foreach ($m in [regex]::Matches($raw, $payloadPattern)) { $payloadCount++ }
        foreach ($m in [regex]::Matches($raw, $doubleQuotedPattern)) { $doubleQuotedCount++ }
        foreach ($line in (Get-ShellPayloadViolations -Path $_.FullName)) { Write-Host $line; $violations++ }
    }
if ($payloadCount -ne 9 -or $doubleQuotedCount -ne 2) {
    Write-Host ("embedded PowerShell payload count is single-quoted={0} double-quoted={1}, expected 9 and 2 -- the extractor no longer sees them, so a pass here would mean nothing" -f $payloadCount, $doubleQuotedCount)
    exit 2
}
if ($violations -gt 0) { exit 1 }
if (-not $Calibrate) { Write-Host ("ps-static rules ok (NOT calibrated): files={0} payloads={1} here={2}" -f $files.Count, $payloadCount, $hereScanned) }
exit 0
PSEOF
    # -Calibrate is not optional.  It runs the rule over a LEGAL fixture and a
    # DEFECT fixture built inside the script, and refuses to report on the
    # assets unless the rule accepts the first and flags the second.  Without
    # it, a rule that has quietly stopped matching anything reads exactly like
    # a clean tree -- the failure mode this repo has already paid for twice
    # (smoke/01's own config-pattern extraction, smoke/10's rule A).
    if ! pwsh -NoProfile -NonInteractive -File "$rules_ps1" -Root "$root/skill/assets" -Calibrate >/dev/null; then
        printf '%s\n' 'PowerShell static rules FAILED (a $null-only variable that is read, an assignment nobody reads, a .NET API that is missing on Windows PowerShell 5.1, or a write to an automatic variable):' >&2
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
# skill/assets 之外还有两份 YAML 是部署面的一部分：SKILL.md 的 frontmatter
# （description 的拼写错误会静默改变 Skill 的触发条件）与 agents/openai.yaml
# （Skill 元数据）。它们此前不在任何解析范围内——found 2026-10-25：把
# frontmatter 改坏（未闭合的 `[`）后整个套件仍然全绿。
yaml_count=0
yaml_summary=0
if python3 -c 'import yaml' >/dev/null 2>&1; then
    yaml_parse_one() {
        python3 -c 'import sys, yaml
try:
    yaml.safe_load(open(sys.argv[1], "rb").read())
except Exception as exc:
    print(exc, file=sys.stderr)
    sys.exit(1)' "$1"
    }
    while IFS= read -r file; do
        yaml_count=$((yaml_count + 1))
        if ! yaml_parse_one "$file"; then
            printf 'YAML parse FAILED: %s\n' "${file#"$root"/}" >&2
            failures=$((failures + 1))
            continue
        fi
        yaml_summary=$((yaml_summary + 1))
    done < <(find "$root/skill/assets" -type f -name '*.yml' | sort)
    # SKILL.md frontmatter: the YAML between the first two --- lines must
    # parse, must be a mapping, and must carry a non-empty name and
    # description.  The extractor fails LOUDLY if the delimiters move -- an
    # empty extraction must never read as a parse.
    skill_md="$root/skill/SKILL.md"
    work_dir_yaml=$(mktemp -d "${TMPDIR:-/tmp}/agentq-skillmd.XXXXXX")
    fm_file="$work_dir_yaml/skill-md-frontmatter.yml"
    fm_status=0
    # NOTE the flag: in awk, `exit` in the body STILL RUNS the END block, so an
    # unconditional `END { exit 3 }` would overwrite the success exit -- the
    # same shape smoke/23's extractor guards with its `done` flag.
    awk 'NR == 1 { if ($0 != "---") { exit 2 }; next }
         /^---$/ { done = 1; exit 0 }
         { print }
         END { if (!done) exit 3 }' "$skill_md" >"$fm_file" 2>/dev/null || fm_status=$?
    if [ "$fm_status" -ne 0 ]; then
        printf 'SKILL.md frontmatter extractor FAILED (status %s): the --- delimiters moved\n' "$fm_status" >&2
        failures=$((failures + 1))
    elif ! python3 -c 'import sys, yaml
data = yaml.safe_load(open(sys.argv[1], "rb").read())
assert isinstance(data, dict), "frontmatter is not a mapping"
assert data.get("name"), "frontmatter has no name"
assert data.get("description"), "frontmatter has no description"' "$fm_file"; then
        printf 'SKILL.md frontmatter FAILED (must be a mapping with non-empty name and description)\n' >&2
        failures=$((failures + 1))
    fi
    rm -rf -- "$work_dir_yaml"
    work_dir_yaml=''
    # agents/openai.yaml: same parse, plus the three interface keys the Skill
    # metadata consumer reads.
    openai_yaml="$root/skill/agents/openai.yaml"
    if [ -f "$openai_yaml" ]; then
        if ! yaml_parse_one "$openai_yaml"; then
            printf 'YAML parse FAILED: %s\n' "${openai_yaml#"$root"/}" >&2
            failures=$((failures + 1))
        elif ! python3 -c 'import sys, yaml
data = yaml.safe_load(open(sys.argv[1], "rb").read())
iface = data.get("interface")
assert isinstance(iface, dict), "no interface mapping"
for key in ("display_name", "short_description", "default_prompt"):
    assert iface.get(key), "interface." + key + " missing"' "$openai_yaml"; then
            printf 'openai.yaml FAILED (interface must carry display_name, short_description, default_prompt)\n' >&2
            failures=$((failures + 1))
        fi
    else
        printf 'skill/agents/openai.yaml is missing\n' >&2
        failures=$((failures + 1))
    fi
else
    yaml_summary='skipped(no pyyaml)'
fi

# --- .github/workflows: YAML parse -------------------------------------------
# The workflows are the enforcement layer -- ci.yml pins the 29 check names, the
# two tool-summary tokens (shellcheck/posix) and the NOT-covered allowlist;
# release.yml is the only gate tying a tag to the recorded version.  A YAML typo
# in one of them does not fail locally in any way (measured 2026-10-25: breaking
# ci.yml's indentation left both `./smoke/01` and `./run-tests.sh --quick`
# exiting 0), and GitHub's response to an unparseable workflow is to not run it
# at all -- the CI that would have caught the mistake is the CI that stopped
# running.  (The tool word sits mid-line on purpose: a comment whose FIRST word
# after `#` is that token is parsed as a directive, and a malformed one -- as
# this line was until 2026-10-26 -- makes shellcheck stop analysing the rest of
# the file.)
# `set -u` is on: the summary below reads this even when pyyaml is absent, so
# the token is initialised OUTSIDE the probe.  A value that only exists when a
# tool is present turns a missing tool into an unbound-variable crash.
workflow_summary='skipped(no pyyaml)'
if python3 -c 'import yaml' >/dev/null 2>&1; then
    workflow_count=0
    while IFS= read -r workflow_file; do
        workflow_count=$((workflow_count + 1))
        if ! python3 -c 'import sys, yaml
try:
    data = yaml.safe_load(open(sys.argv[1], "rb").read())
except Exception as exc:
    print(exc, file=sys.stderr)
    sys.exit(1)
assert isinstance(data, dict) and data.get("jobs"), "a workflow needs a jobs mapping"
# PyYAML 1.1 resolves the bare key `on:` to the boolean True, so the trigger
# key is truthy under EITHER spelling.  Accept both, and require one of them to
# be present -- a workflow with no trigger never runs.
assert (True in data) or ("on" in data), "a workflow needs an on/trigger key"
' "$workflow_file"; then
            printf 'workflow YAML FAILED (GitHub skips an unparseable workflow, so this failure would otherwise be invisible): %s\n' \
                "${workflow_file#"$root"/}" >&2
            failures=$((failures + 1))
        fi
    done < <(find "$root/.github/workflows" -type f -name '*.yml' | sort)
    if [ "$workflow_count" -eq 0 ]; then
        printf '%s\n' 'no workflow files were enumerated; refusing to report a pass' >&2
        failures=$((failures + 1))
    fi
    workflow_summary=$workflow_count
fi

# --- ci.yml's pinned check list vs smoke/*.sh --------------------------------
# ci.yml pins the exact set of check names that must report (`expected_checks`),
# so a new or renamed check turns CI red.  Locally nothing noticed: a new
# smoke/30-*.sh ran in the suite, bumped `ran` to 30, and smoke/01 stayed green
# -- the developer sees a full pass and CI is the first thing to object, which
# inverts the point of running locally.  Measured 2026-10-25 with a planted
# smoke/30-probe-new-check.sh: smoke/01 exit 0, zero mentions of it.
#
# This compares the two lists directly rather than waiting for CI.  It does NOT
# try to check the workflow's other pins (tokens, NOT-covered allowlist) --
# those are behavioural and CI is where they get exercised; this one is a plain
# set comparison and can be done locally for free.
ci_pin_rc=0
ci_pin_summary='skipped(no pyyaml)'
if python3 -c 'import yaml' >/dev/null 2>&1; then
    ci_pin_out=$(python3 - "$root" <<'PY'
import glob
import os
import re
import sys

root = sys.argv[1]
path = os.path.join(root, ".github", "workflows", "ci.yml")
try:
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
except OSError as exc:
    print("ci.yml is unreadable: %s" % exc, file=sys.stderr)
    sys.exit(2)
m = re.search(r"expected_checks='([^']*)'", text)
if not m:
    # A missing pin must not read as "nothing to compare": the pin is the CI
    # gate, and silently dropping it would be the same false green.
    print("ci.yml has no expected_checks='...' pin", file=sys.stderr)
    sys.exit(2)
pinned = sorted(m.group(1).split())
present = sorted(
    os.path.basename(p)[:-3] for p in glob.glob(os.path.join(root, "smoke", "*.sh"))
)
if not pinned or not present:
    print(
        "empty check list (pinned=%d present=%d); refusing to compare"
        % (len(pinned), len(present)),
        file=sys.stderr,
    )
    sys.exit(2)
missing = [c for c in present if c not in pinned]
stale = [c for c in pinned if c not in present]
if missing or stale:
    for c in missing:
        print("smoke/%s.sh exists but ci.yml's expected_checks does not list it"
              " (CI would fail on the next push; add it to the pin)" % c,
              file=sys.stderr)
    for c in stale:
        print("ci.yml's expected_checks lists %s but smoke/%s.sh does not exist"
              " (the pin is stale)" % (c, c), file=sys.stderr)
    sys.exit(1)
print("%d" % len(pinned))
PY
    ) || ci_pin_rc=$?
    case $ci_pin_rc in
    0) ci_pin_summary=$ci_pin_out ;;
    *)
        printf 'ci check-list pin FAILED (the pinned set and smoke/*.sh disagree; a local run must not be greener than CI):\n' >&2
        sed 's/^/      /' >&2 <<EOF
$ci_pin_out
EOF
        failures=$((failures + 1))
        # Deliberately NOT setting a token here: smoke/01 exits 1 before the
        # summary line is printed, so `ci_pin_summary='failed'` would be dead
        # code -- the same mistake `farm_write_summary='failed(scan)'` made in
        # the round that introduced farm_writes.  The failure is already
        # reported above, on stderr, which is where a failing run's detail goes.
        ;;
    esac
else
    ci_pin_summary='skipped(no pyyaml)'
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

# ...and the section that protects the assets must still set every key that
# decides whether an editor may REWRITE them -- not just end_of_line.  Measured
# 2026-10-26: the section has three keys; deleting `trim_trailing_whitespace =
# false` or `insert_final_newline = unset`, or flipping trim to `true`, each
# left smoke/01 at exit 0 while only the end_of_line line was read.  A
# half-locked section is the shape this repo keeps fixing: the surviving line
# keeps the check green and reads like the whole section is guarded.
#
# Required values, and why each is the only safe one:
#   end_of_line = unset            -- `lf` would rewrite a CRLF asset
#   trim_trailing_whitespace = false -- `true` would strip trailing blanks
#   insert_final_newline = unset   -- `true` would append a newline
# `unset` is not the platform default; it is editorconfig's "remove the
# effect", which is what leaves the bytes alone.  Verified against a real
# implementation (py-editorconfig 0.17.1): all three resolve for files under
# skill/assets, and a file outside the section resolves to lf/true instead.
editorconfig_key_value() { # $1=file, $2=section glob, $3=key -> last value in that section
    awk -v want_section="$2" -v want_key="$3" '
        /^\[.*\]$/ {
            section = $0
            gsub(/^\[/, "", section)
            gsub(/\]$/, "", section)
            next
        }
        section == want_section {
            eq = index($0, "=")
            if (eq == 0) next
            key = substr($0, 1, eq - 1)
            gsub(/^[ \t]+|[ \t]+$/, "", key)
            if (key == want_key) {
                value = substr($0, eq + 1)
                gsub(/^[ \t]+|[ \t]+$/, "", value)
                found = value
            }
        }
        END { if (found != "") print found }
    ' "$1"
}
# Self-test: the extractor must read the LAST value in a section, must not read
# a key from a neighbouring section, and must report nothing for a missing key.
editorconfig_selftest_file=$(mktemp "${TMPDIR:-/tmp}/agentq-editorconfig-selftest.XXXXXX")
printf '[a/**]\nk = first\nk = second\n[b/**]\nk = other\n' >"$editorconfig_selftest_file"
editorconfig_selftest="$(
    printf '%s|%s|%s' \
        "$(editorconfig_key_value "$editorconfig_selftest_file" 'a/**' k)" \
        "$(editorconfig_key_value "$editorconfig_selftest_file" 'b/**' k)" \
        "$(editorconfig_key_value "$editorconfig_selftest_file" 'a/**' missing)"
)"
rm -f -- "$editorconfig_selftest_file"
if [ "$editorconfig_selftest" != 'second|other|' ]; then
    printf 'editorconfig self-test FAILED (expected "second|other|", got "%s")\n' \
        "$editorconfig_selftest" >&2
    failures=$((failures + 1))
fi
asset_protection=0
# The section that covers skill/assets is found by the same pattern matcher the
# arm above uses, so a renamed-but-equivalent section keeps working.
asset_protection_section=
while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if pattern_matches_under "$candidate" skill/assets; then
        asset_protection_section=$candidate
        break
    fi
done < <(sed -n 's/^\[\(.*\)\]$/\1/p' "$root/.editorconfig")
if [ -z "$asset_protection_section" ]; then
    printf '%s\n' '.editorconfig: no section matches anything under skill/assets -- the byte-verified assets are no longer protected from editor rewrites' >&2
    failures=$((failures + 1))
else
    while IFS='|' read -r asset_key asset_want; do
        asset_got=$(editorconfig_key_value "$root/.editorconfig" "$asset_protection_section" "$asset_key")
        if [ "$asset_got" != "$asset_want" ]; then
            printf 'editorconfig FAILED (section [%s] resolves %s to "%s", not "%s" -- an editor may rewrite the byte-verified assets): %s\n' \
                "$asset_protection_section" "$asset_key" "$asset_got" "$asset_want" "$asset_key" >&2
            failures=$((failures + 1))
        else
            asset_protection=$((asset_protection + 1))
        fi
    done <<'EOF'
end_of_line|unset
trim_trailing_whitespace|false
insert_final_newline|unset
EOF
fi

# A pattern count of zero means the extraction broke, not that there was
# nothing to check -- the same reasoning as the shell-asset enumeration above.
if [ "$config_patterns" -eq 0 ]; then
    printf '%s\n' 'no config-file path patterns were extracted; refusing to report a pass' >&2
    failures=$((failures + 1))
fi

# --- .gitattributes: the attribute VALUES, not just the path patterns -------
# The arm above proves every path pattern in .gitattributes/.editorconfig names
# a real file.  It cannot see the value stop applying: deleting the `* -text`
# line leaves every surviving pattern valid, the suite green, and 10 of the 25
# deployment files resolving to `text: unspecified`.  Measured 2026-10-26 with
# the line removed: `git check-attr text` reports `unspecified` for SKILL.md,
# agents/openai.yaml, client/unix/agentq, client/unix/sshp, unix/agentq,
# the .service, both .plists and both pueue.yml -- and smoke/01 still exits 0.
# CLAUDE.md calls `* -text` a hard requirement and records the measured
# consequence: the same CRLF file is stored 0d 0a with the file and 0a without
# it, which is exactly how the two canonical copies stop being identical.
#
# The oracle is git, not the file's text: what matters is the attribute a
# checkout/commit actually applies, so a future rewrite of .gitattributes that
# spells the protection differently but keeps the value stays green.
#
# `merge: unset` on the two canonical copies is pinned separately.  Their lines
# say `-text -diff -merge`.  `-merge` is the one that matters: measured
# 2026-10-26 (git 2.55.0, scratch repos), two branches editing different lines
# of the same file auto-merge silently when only `-text -diff` is set, and
# conflict (`Cannot merge binary files`) once `-merge` is set -- a one-sided
# change still merges cleanly either way.  `-diff` only changes how `git diff`
# displays the file; it does not stop the merge.  Both statements were the
# opposite of what the .gitattributes comments said until this arm existed, and
# deleting those two lines left the suite green.
gitattr_violations() { # $1 = the attr name the query asked for; stdin: NUL triples
    local attr_name=$1 path attr value
    while IFS= read -r -d '' path && IFS= read -r -d '' attr && IFS= read -r -d '' value; do
        # `attr` is the middle field of every triple; asserting it equals what
        # the caller asked for is this function's only use of it -- a parse
        # that drifted would otherwise skip silently.  (Before 2026-10-26 the
        # field was read and never used, which the shellcheck lock reported
        # the moment this file's analysis stopped aborting at line 1104.)
        [ "$attr" = "$attr_name" ] || continue
        [ -n "$path" ] || continue
        [ "$value" = unset ] || printf '%s\n' "$path"
    done
}
gitattr_selftest=$(printf 'a\0text\0unset\0b\0text\0set\0c\0text\0unspecified\0' |
    gitattr_violations text | sort | tr '\n' ' ')
if [ "$gitattr_selftest" != 'b c ' ]; then
    printf 'gitattributes self-test FAILED (expected b and c to be reported, got "%s")\n' \
        "$gitattr_selftest" >&2
    failures=$((failures + 1))
fi
gitattr_state='skipped(no-git)'
gitattr_count=0
if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    gitattr_state='checked'
    gitattr_tmp=$(mktemp "${TMPDIR:-/tmp}/agentq-gitattr.XXXXXX")
    git -C "$root" ls-files -z -- skill/ |
        git -C "$root" check-attr -z --stdin text >"$gitattr_tmp"
    # Each record is three NUL-terminated fields, so the file count is
    # field_count / 3.  Counting fields (not lines) is what lets this handle
    # paths with spaces, which `check-attr --stdin` accepts verbatim.
    gitattr_count=$(( $(tr -cd '\0' <"$gitattr_tmp" | wc -c) / 3 ))
    while IFS= read -r gitattr_path; do
        [ -n "$gitattr_path" ] || continue
        printf 'gitattributes FAILED (this tracked deployment file no longer resolves `text` to unset, so core.autocrlf may rewrite its bytes on checkout -- the .gitattributes protection stopped covering it): %s\n' \
            "$gitattr_path" >&2
        failures=$((failures + 1))
    done <<EOF
$(gitattr_violations text <"$gitattr_tmp")
EOF
    rm -f -- "$gitattr_tmp"
    # The two canonical copies must also stay out of textual merges.
    gitattr_pair=$(mktemp "${TMPDIR:-/tmp}/agentq-gitattr-pair.XXXXXX")
    git -C "$root" check-attr -z merge -- \
        skill/assets/unix/agentq-server skill/assets/windows-git-bash/agentq >"$gitattr_pair"
    # Same shape as the empty-enumeration guards elsewhere: zero records means
    # the query broke (wrong paths, git gone), not that both copies are safe.
    gitattr_pair_count=$(( $(tr -cd '\0' <"$gitattr_pair" | wc -c) / 3 ))
    if [ "$gitattr_pair_count" -ne 2 ]; then
        printf 'gitattributes: expected 2 canonical server copies in the merge-attribute query, got %s; refusing to report a pass\n' \
            "$gitattr_pair_count" >&2
        failures=$((failures + 1))
    fi
    while IFS= read -r gitattr_path; do
        [ -n "$gitattr_path" ] || continue
        printf 'gitattributes FAILED (a canonical server copy is no longer marked `-merge`, so a three-way merge can rewrite one copy and leave the other, breaking the byte-identity constraint silently): %s\n' \
            "$gitattr_path" >&2
        failures=$((failures + 1))
    done <<EOF
$(gitattr_violations merge <"$gitattr_pair")
EOF
    rm -f -- "$gitattr_pair"
    if [ "$gitattr_count" -eq 0 ]; then
        printf '%s\n' 'gitattributes: no tracked deployment file was enumerated; refusing to report a pass' >&2
        failures=$((failures + 1))
    fi
fi

# --- .gitignore: the credential blocklist must actually block ----------------
# CLAUDE.md states the credential rule and names .gitignore as its mechanism
# ("凭据不进仓库、不进脚本、不留盘 ... 现在是可执行的").  Nothing read the file:
# measured 2026-10-26, deleting .gitignore entirely leaves smoke/01 and smoke/16
# at exit 0, and so does narrowing `agentq-askpass.*` to `agentq-askpass.tmp` --
# the POSIX client's real askpass wrapper is `agentq-askpass.<random>`
# (client/unix/agentq:607 via make_client_temporary_file), so that edit reopens
# the exact leak the pattern exists to close.
#
# The oracle is `git check-ignore`, which answers for paths that do not exist
# (measured: `--no-index` on a nonexistent path reports its rule), so no
# fixture file is ever written.  Two guards keep the answer about THIS
# repository: `-c core.excludesFile=/dev/null` drops the developer's global
# ignore file, and the match must name `.gitignore` as its source (`-v` prints
# it; measured: `.git/info/exclude` and a global file both name themselves
# instead), so a machine-local rule cannot make a deleted pattern look alive.
#
# Bidirectional: the must-ignore table covers every credential pattern line;
# the must-stay-visible table pins the name-anchoring the file's own comment
# calls deliberate (`notes-about-askpass.md` must stay visible) and the root
# anchors (`/out`, `/err` must not match in subdirectories).  Every tracked
# file must also stay visible -- a broad `*` or `skill/` line would silently
# untrack the deployment unit, which is how a fresh clone loses its assets.
# And the three protection files themselves must be TRACKED: untracking one
# leaves the working-tree copy (and every assertion above) intact while a
# fresh clone gets no protection at all -- measured: untracking .gitignore,
# .gitattributes or .editorconfig each leaves smoke/01 at exit 0.
gitignore_source() { # $1=repo root, $2=path -> .gitignore | <other source> | none | error
    local out rc=0
    out=$(git -C "$1" -c core.excludesFile=/dev/null check-ignore -v --no-index -- "$2" 2>/dev/null) || rc=$?
    case $rc in
        0) printf '%s\n' "${out%%:*}" ;;
        1) printf 'none\n' ;;
        *) printf 'error\n' ;;
    esac
}
gitignore_state='skipped(no-git)'
if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    gitignore_state='checked'
    # Self-test first: the classifier must answer all four ways on a scratch
    # repo whose rules are known, or the tables below prove nothing.  The
    # info/exclude line is what proves the `.gitignore` source requirement
    # discriminates; the fourth probe is a root that is not a repository, which
    # must come back as `error` rather than as either answer.  This runs only
    # inside the git-available branch: on a host without git the classifier
    # cannot answer anything, and reporting that as a broken asset would be the
    # pwsh-unusable mistake in git's clothing.
    gitignore_selftest_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentq-gitignore-selftest.XXXXXX")
    git -C "$gitignore_selftest_dir" init -q 2>/dev/null || true
    printf '*.secret\n' >"$gitignore_selftest_dir/.gitignore"
    printf '*.excluded\n' >"$gitignore_selftest_dir/.git/info/exclude"
    gitignore_selftest=''
    for probe in a.secret b.txt c.excluded; do
        gitignore_selftest="$gitignore_selftest $(gitignore_source "$gitignore_selftest_dir" "$probe")"
    done
    gitignore_selftest="$gitignore_selftest $(gitignore_source "$gitignore_selftest_dir/does-not-exist" x.secret)"
    rm -rf -- "$gitignore_selftest_dir"
    if [ "$gitignore_selftest" != ' .gitignore none .git/info/exclude error' ]; then
        printf 'gitignore self-test FAILED (expected ".gitignore none .git/info/exclude error", got "%s")\n' \
            "$gitignore_selftest" >&2
        failures=$((failures + 1))
    fi
    for gitignore_file in .gitignore .gitattributes .editorconfig; do
        if ! git -C "$root" ls-files --error-unmatch "$gitignore_file" >/dev/null 2>&1; then
            printf 'gitignore FAILED (%s is not tracked, so a fresh clone has no protection at all while this working tree still looks protected): %s\n' \
                "$gitignore_file" "$gitignore_file" >&2
            failures=$((failures + 1))
        fi
    done
    # Each fixture stands for one credential pattern line in .gitignore.
    gitignore_must_ignore='.askpass
.askpass.a1
askpass
askpass.log
agentq-askpass.9fXq2
.aq-bootstrap/x
.env
.env.staging
tokens.env
server.pem
daemon.key
client.ppk
id_rsa
id_ed25519
id_ecdsa
id_dsa
ssh_host_ed25519_key
.git-credentials
.netrc
authorized_keys
known_hosts
shared_secret
daemon.cert
daemon.crt
bundle.p12
bundle.pfx
certs/daemon.key
home/.agentq/data/records.json
config/agentq/hosts.json
out
err
run.smoke-out
x.syntax.y
.DS_Store
docs/.DS_Store
notes.swp
notes.swo
backup.txt~
smoke/__pycache__/x.pyc
stray.pyc
aqsb/home/.agentq'
    gitignore_must_stay='notes-about-askpass.md
sub/out
sub/err
README.md
skill/SKILL.md'
    gitignore_fixtures=0
    while IFS= read -r gitignore_path; do
        [ -n "$gitignore_path" ] || continue
        gitignore_fixtures=$((gitignore_fixtures + 1))
        case $(gitignore_source "$root" "$gitignore_path") in
            .gitignore) ;;
            none)
                printf 'gitignore FAILED (this credential path is no longer ignored by .gitignore, so it would be committed): %s\n' \
                    "$gitignore_path" >&2
                failures=$((failures + 1))
                ;;
            error)
                printf 'gitignore: the check-ignore query itself failed for %s; refusing to read that as either answer\n' \
                    "$gitignore_path" >&2
                failures=$((failures + 1))
                ;;
            *)
                printf 'gitignore FAILED (this credential path is only ignored by a machine-local rule, not by the repository .gitignore, so a fresh clone would commit it): %s\n' \
                    "$gitignore_path" >&2
                failures=$((failures + 1))
                ;;
        esac
    done <<EOF
$gitignore_must_ignore
EOF
    while IFS= read -r gitignore_path; do
        [ -n "$gitignore_path" ] || continue
        gitignore_fixtures=$((gitignore_fixtures + 1))
        case $(gitignore_source "$root" "$gitignore_path") in
            none) ;;
            error)
                printf 'gitignore: the check-ignore query itself failed for %s; refusing to read that as either answer\n' \
                    "$gitignore_path" >&2
                failures=$((failures + 1))
                ;;
            *)
                printf 'gitignore FAILED (a file that must stay committable is ignored -- the pattern is broader than the credential class it was written for): %s\n' \
                    "$gitignore_path" >&2
                failures=$((failures + 1))
                ;;
        esac
    done <<EOF
$gitignore_must_stay
EOF
    # A floor, not the exact count: deleting half the table must not silently
    # narrow the coverage while every surviving fixture still passes.
    if [ "$gitignore_fixtures" -lt 40 ]; then
        printf 'gitignore: only %s fixtures were enumerated (expected at least 40); refusing to report a pass\n' \
            "$gitignore_fixtures" >&2
        failures=$((failures + 1))
    fi
    # No tracked file may resolve as ignored by .gitignore.  `--no-index` is
    # what makes this meaningful: without it git exempts tracked files from
    # ignore rules (measured), so a broad pattern would be invisible here.
    gitignore_sweep=$(mktemp "${TMPDIR:-/tmp}/agentq-gitignore-sweep.XXXXXX")
    gitignore_tracked=$(mktemp "${TMPDIR:-/tmp}/agentq-gitignore-tracked.XXXXXX")
    gitignore_sweep_rc=0
    git -C "$root" ls-files -z >"$gitignore_tracked" || gitignore_sweep_rc=$?
    # An empty or failed enumeration would feed check-ignore nothing and pass
    # silently -- the empty-enumeration class this repo keeps re-finding.
    gitignore_tracked_count=$(( $(tr -cd '\0' <"$gitignore_tracked" | wc -c) ))
    if [ "$gitignore_sweep_rc" -ne 0 ] || [ "$gitignore_tracked_count" -eq 0 ]; then
        printf 'gitignore: could not enumerate the tracked files (exit %s, %s paths); refusing to report a pass\n' \
            "$gitignore_sweep_rc" "$gitignore_tracked_count" >&2
        failures=$((failures + 1))
    else
        git -C "$root" -c core.excludesFile=/dev/null check-ignore -v -z --stdin --no-index \
            <"$gitignore_tracked" >"$gitignore_sweep" 2>/dev/null || gitignore_sweep_rc=$?
        case $gitignore_sweep_rc in
            0 | 1) ;;
            *)
                printf 'gitignore: the tracked-file sweep failed (check-ignore exit %s); refusing to report a pass\n' \
                    "$gitignore_sweep_rc" >&2
                failures=$((failures + 1))
                ;;
        esac
    fi
    rm -f -- "$gitignore_tracked"
    # Four NUL-terminated fields per record: source, line, pattern, path.
    while IFS= read -r -d '' gitignore_source_file &&
        IFS= read -r -d '' gitignore_line &&
        IFS= read -r -d '' gitignore_pattern &&
        IFS= read -r -d '' gitignore_path; do
        [ "$gitignore_source_file" = .gitignore ] || continue
        printf 'gitignore FAILED (a tracked file is matched by .gitignore:%s (%s), so it would be silently untracked on a fresh add): %s\n' \
            "$gitignore_line" "$gitignore_pattern" "$gitignore_path" >&2
        failures=$((failures + 1))
    done <"$gitignore_sweep"
    rm -f -- "$gitignore_sweep"
fi

# Zero shell assets parsed means the enumeration itself failed (missing find,
# wrong root), not that there was nothing to check.
if [ "$shell_count" -eq 0 ]; then
    printf '%s\n' 'no shell assets were enumerated; refusing to report a pass' >&2
    failures=$((failures + 1))
fi

# --- skill/: the index file modes must be exactly the intended ones ----------
# CLAUDE.md states the rule ("不要把 skill/assets/ 下的文件设成可执行后提交——
# install-agentq.sh 刻意保持 644"), and nothing asserted it.  Measured
# 2026-10-26, both directions were silent: `git update-index --chmod=+x
# skill/assets/unix/install-agentq.sh` (the exact forbidden state) left smoke/01
# AND --quick at exit 0, and so did `--chmod=-x skill/assets/unix/agentq-server`
# (a fresh clone would get a server binary that cannot be executed -- the
# installer's `cp` copies the source mode, and the later `chmod 700` applies to
# the staged copy only after that cp).
#
# The oracle is the INDEX (`git ls-files -s`), not the worktree: the mode that
# matters is the one a fresh clone gets, and `core.fileMode=false` makes the
# worktree bit invisible to `git status` while the index still carries it.
# The expected set is stated as two explicit lists rather than "whatever is
# there today", because the point is to fail on a CHANGE, in either direction.
# `install-client.sh` is in the executable list: the client installer documents
# copying with cp/chmod and SKILL.md does not invoke it via `sh ./`.
skill_modes_expected_exec='skill/assets/client/unix/agentq
skill/assets/client/unix/install-client.sh
skill/assets/client/unix/sshp
skill/assets/client/windows/agentq.bash
skill/assets/client/windows/sshp.bash
skill/assets/unix/agentq
skill/assets/unix/agentq-server
skill/assets/windows-git-bash/agentq'
skill_modes_want() { # $1=path -> executable | non-executable (exact line match)
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ "$path" = "$1" ]; then
            printf 'executable\n'
            return 0
        fi
    done <<EOF
$skill_modes_expected_exec
EOF
    printf 'non-executable\n'
}
# Self-test: the classifier must separate the prefix pair (`.../unix/agentq` is
# a prefix of `.../unix/agentq-server`) and must not be fooled by a path that
# merely contains an expected one as a substring.
skill_modes_selftest="$(skill_modes_want skill/assets/unix/agentq)|$(skill_modes_want skill/assets/unix/agentq-server)|$(skill_modes_want skill/assets/unix/agentq-pueued.service)|$(skill_modes_want x/skill/assets/unix/agentq)"
if [ "$skill_modes_selftest" != 'executable|executable|non-executable|non-executable' ]; then
    printf 'skill modes self-test FAILED (expected "executable|executable|non-executable|non-executable", got "%s")\n' \
        "$skill_modes_selftest" >&2
    failures=$((failures + 1))
fi
skill_modes_state='skipped(no-git)'
if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    skill_modes_state='checked'
    skill_modes_tmp=$(mktemp "${TMPDIR:-/tmp}/agentq-skill-modes.XXXXXX")
    skill_modes_rc=0
    git -C "$root" ls-files -s -- skill/ >"$skill_modes_tmp" || skill_modes_rc=$?
    skill_modes_count=$(wc -l <"$skill_modes_tmp" | tr -d ' ')
    if [ "$skill_modes_rc" -ne 0 ] || [ "$skill_modes_count" -eq 0 ]; then
        printf 'skill modes: could not enumerate the index (exit %s, %s paths); refusing to report a pass\n' \
            "$skill_modes_rc" "$skill_modes_count" >&2
        failures=$((failures + 1))
    else
        while IFS= read -r skill_modes_line; do
            skill_modes_mode=${skill_modes_line%% *}
            skill_modes_path=${skill_modes_line#*	}
            case $skill_modes_mode in
                100644) skill_modes_got='non-executable' ;;
                100755) skill_modes_got='executable' ;;
                *)
                    printf 'skill modes FAILED (unexpected index mode %s -- only 100644 and 100755 are used in this repo): %s\n' \
                        "$skill_modes_mode" "$skill_modes_path" >&2
                    failures=$((failures + 1))
                    continue
                    ;;
            esac
            skill_modes_is=$(skill_modes_want "$skill_modes_path")
            if [ "$skill_modes_got" != "$skill_modes_is" ]; then
                printf 'skill modes FAILED (this file is %s in the index but must be %s -- CLAUDE.md pins the deployment modes: install-agentq.sh stays 644 because SKILL.md calls it as `sh ./install-agentq.sh`, and the server copies must stay executable): %s\n' \
                    "$skill_modes_got" "$skill_modes_is" "$skill_modes_path" >&2
                failures=$((failures + 1))
            fi
        done <"$skill_modes_tmp"
        rm -f -- "$skill_modes_tmp"
        if [ "$skill_modes_count" -lt 25 ]; then
            printf 'skill modes: only %s tracked files under skill/ (expected at least 25); refusing to report a pass\n' \
                "$skill_modes_count" >&2
            failures=$((failures + 1))
        fi
    fi
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

# --- a coverage count in a check's summary line must be COMPUTED -------------
# A summary line is this suite's evidence, and a number in it that nothing
# computes is a claim, not an observation: it cannot move when the check's
# coverage changes, and it can be wrong for the check's whole life.  Measured
# 2026-10-27, three instances, all invisible to every other rule here:
# smoke/10 printed `files=5` while its rules read 10 distinct files (a copy
# with an 11th reference still printed 5), smoke/16 printed `rules=7` from a
# literal, and smoke/15 printed `tombstones=0` while asserting only a DELTA --
# a sandbox that started with one tombstone would have made the printed 0
# false.  smoke/08 had already argued the principle in a comment ("computed,
# not a literal"); nothing checked the other 28.
#
# Scope: coverage QUANTITIES -- how many files/rules/sites/cases this check
# examined.  Contract tokens such as `exit=0/1/2` or `wait=6/unavailable` are
# NOT in the vocabulary: there the literal IS the value the check asserts, and
# it exits non-zero before printing if the assertion fails, so the number
# cannot drift away from what ran.  A coverage literal is different in kind --
# no assertion inside the file can make it right, because the number has to be
# derived from what was scanned.
#
# The fixture is assembled with the phrase in a variable so this file does not
# contain a literal summary line of its own; the detector must not match its
# own source (the same self-match lesson as smoke/16's samples).
summary_quantity_words='files rules sites cases scripts programs records blocks invocations tombstones tokens functions specs'
summary_quantity_re="(^|[^A-Za-z0-9_.-])(${summary_quantity_words// /|})=[0-9]"
summary_quantity_hits() { # $1 = script -> "line:text" per literal coverage count in a summary line
    summary_line_no=0
    while IFS= read -r summary_line; do
        summary_line_no=$((summary_line_no + 1))
        summary_trimmed=${summary_line#"${summary_line%%[![:space:]]*}"}
        case $summary_trimmed in '#'*) continue ;; esac
        case $summary_line in
            *'checks passed'*) ;;
            *) continue ;;
        esac
        if grep -qE "$summary_quantity_re" <<< "$summary_line"; then
            printf '%s:%s\n' "$summary_line_no" "$summary_line"
        fi
    done <"$1"
}
summary_quantity_fixture=$(mktemp "${TMPDIR:-/tmp}/agentq-summary-quantity.XXXXXX")
summary_quantity_phrase='checks passed'
cat >"$summary_quantity_fixture" <<FIXTURE
printf 'x $summary_quantity_phrase: files=5\n'
printf 'x $summary_quantity_phrase: files=%s\n'
printf 'x $summary_quantity_phrase: exit=0/1/2 wait=6/unavailable\n'
printf 'x $summary_quantity_phrase: rules=7 sites=%s\n'
# printf 'x $summary_quantity_phrase: files=5\n'
printf 'not a summary files=5\n'
FIXTURE
summary_quantity_selftest=$(summary_quantity_hits "$summary_quantity_fixture" | cut -d: -f1 | tr '\n' ' ')
rm -f "$summary_quantity_fixture"
if [ "$summary_quantity_selftest" != '1 4 ' ]; then
    printf 'syntax-and-parity FAILED (the summary coverage-count lock failed its self-test: expected literal counts on fixture lines 1 and 4, got [%s])\n' \
        "$summary_quantity_selftest" >&2
    failures=$((failures + 1))
fi
summary_census_checked=0
summary_quantity_count=0
while IFS= read -r summary_script; do
    summary_census_checked=$((summary_census_checked + 1))
    while IFS= read -r summary_hit; do
        [ -n "$summary_hit" ] || continue
        printf 'syntax-and-parity FAILED (a coverage count in a summary line is a literal; it cannot move when the check'"'"'s coverage changes -- compute it from what was examined): %s:%s\n' \
            "${summary_script#"$root"/}" "$summary_hit" >&2
        summary_quantity_count=$((summary_quantity_count + 1))
    done <<EOF
$(summary_quantity_hits "$summary_script")
EOF
done <<EOF
$(find "$root/smoke" -type f -name '*.sh' | sort)
EOF
if [ "$summary_census_checked" -eq 0 ]; then
    printf '%s\n' 'no smoke scripts were enumerated for the summary coverage-count lock; refusing to report a pass' >&2
    failures=$((failures + 1))
fi
if [ "$summary_quantity_count" -ne 0 ]; then
    failures=$((failures + 1))
fi

# --- mktemp templates must END in their X's ----------------------------------
# BSD mktemp (macOS) randomizes ONLY a trailing run of X's.  Given
# `agentq-parse-ps1.XXXXXX.ps1` it creates a file with that LITERAL name --
# no randomness, no uniqueness -- and `mkstemp` then fails with "File exists"
# the second time.  Measured 2026-10-24: two such templates had shipped here,
# invisible because the EXIT trap removes the literal file on a normal exit;
# the first SIGKILLed suite left them behind and every later smoke/01 run died
# before any assertion.  The failure also poisons the NEXT run, which is what
# made it look like an environment fault (a stale temp dir) in the suite log.
# GNU mktemp accepts either form, so this is BSD-only -- which is exactly why
# the Mac suite must assert it and the Linux suite cannot.
mktemp_suffix_count=0
mktemp_suffix_hits=$(
    while IFS= read -r repo_script; do
        # `[^X"'"'"'[:space:]]` -- the X must ALSO be excluded from the
        # follower class.  Without it `[X]{3,}` matches exactly three of six
        # X's and the fourth X satisfies the follower, so a CORRECT template
        # ending in XXXXXX matched (measured: three false reds on the first
        # run of this rule).  The follower is "anything that is not X, quote
        # or space": that is exactly a suffix after the randomizing run.
        # `[^X"'"'"'[:space:])]` -- X, quotes, whitespace and the closing paren of
        # `$( ... )` all mean "the X run ends here".  Two earlier versions of
        # this follower class were wrong and BOTH cried wolf on correct code:
        # without X it matched three of six X's (the fourth X was the
        # "suffix"), and without `)` it flagged every `mktemp -d .../x.XXXXXX)`
        # in smoke/04-07.  Measured both, on the real tree.
        grep -nE 'mktemp[^|;]*[X]{3,}[^X"'"'"'[:space:])]' "$repo_script" 2>/dev/null |
            grep -vE '^[0-9]+:[[:space:]]*#' |
            sed "s|^|${repo_script#"$root"/}:|" || true
    done <<SCRIPTS
$(find "$root/smoke" -type f -name '*.sh' | sort)
$root/run-tests.sh
$root/sandbox.sh
$shell_assets
SCRIPTS
)
if [ -n "$mktemp_suffix_hits" ]; then
    while IFS= read -r mktemp_hit; do
        [ -n "$mktemp_hit" ] || continue
        printf 'repo script FAILED (a mktemp template must END in its X run -- BSD mktemp treats a suffix after the Xs as a literal name, so the second run fails with File exists): %s\n' \
            "$mktemp_hit" >&2
        mktemp_suffix_count=$((mktemp_suffix_count + 1))
    done <<EOF
$mktemp_suffix_hits
EOF
    failures=$((failures + 1))
fi

# --- repo scripts: no raw write into a symlink "farm" -------------------------
# `cat > "$dir/tool"` FOLLOWS a symlink.  A stub-PATH fixture builds $dir by
# symlinking the host's REAL binaries into it
#   for entry in <dir>/*; do ln -s "$entry" "$D/$name"; done
# so a raw write over one of those entries truncates the binary the link points
# at.  This repo has paid for that twice: a Linux CI host hit it on
# /usr/bin/loginctl while building smoke/11's stub_linux (the exclusion comment
# there records the incident: the heredoc "would then write THROUGH it to
# /usr/bin/loginctl"), and on 2026-10-25 the same shape -- built by a
# session-level fixture rather than by a check -- TRUNCATED A DEVELOPER'S
# HOMEBREW python3.  For ~40 minutes every python3 on that machine exited 0,
# printed nothing and did nothing, which read as a working interpreter.
#
# Every defence before this was a hand-written pairing: an exclusion case in the
# copy loop plus a literal `cat >` somewhere below it.  Get the pairing wrong and
# the gun fires.  smoke/11 now routes every stub through `write_stub` (unlink
# first, so the stub lands as a regular file), and this rule keeps a FUTURE raw
# write from being introduced next to such a loop.
#
# The classifier is its own file (smoke/01-farm-write.py) so the self-test can
# run the SAME code against fixtures -- a self-test that reimplements the rules
# proves nothing about the rules that ship.  It is invoked as `python3 <file>`,
# never as `./file`, so the checked-in mode stays 644 like every other asset.
farm_write_count=0
farm_write_summary=0
# An interpreter that cannot RUN is an environment fault and must be named as
# one, not reported as a broken classifier (the pwsh-unusable lesson: four
# startup-cache corruptions once reported 7 correct .ps1 assets as failures).
# `command -v python3` is not a probe -- on a zh-CN Windows the Store alias
# exists, exits 49 and prints nothing.
python3_state=unusable
if python3 -I -c 'pass' >/dev/null 2>&1; then
    python3_state=usable
fi
if [ "$python3_state" = usable ]; then
    # The exit code is LOAD-BEARING: the classifier exits 2 when it enumerated
    # nothing, and `|| true` here would turn that into farm_writes=0 (measured
    # 2026-10-25: an empty directory, a nonexistent path and `/` all exited 0
    # before the guard existed).
    farm_write_rc=0
    farm_write_err=$(mktemp "${TMPDIR:-/tmp}/agentq-farm-scan.XXXXXX")
    farm_write_hits=$(
        python3 -I "$root/smoke/01-farm-write.py" "$root" 2>"$farm_write_err"
    ) || farm_write_rc=$?
    case $farm_write_rc in
    0 | 1)
        # Exit 1 means "hits found" ONLY IF there are hits to print.  A Python
        # SyntaxError also exits 1, and so does any crash the classifier's own
        # handler has not caught; either would otherwise read as "hits found,
        # output empty" and leave farm_writes=0 green -- measured 2026-10-25 by
        # planting a RuntimeError that only the real tree reaches (the
        # self-test never walks skill/assets, so it stayed green).
        if [ "$farm_write_rc" -eq 1 ] && [ -z "$farm_write_hits" ]; then
            printf 'farm-write scan FAILED (exit 1 with no output; exit 1 means "hits found" only when there is output -- a crash or a syntax error in the classifier also exits 1):\n' >&2
            sed 's/^/      /' "$farm_write_err" >&2
            failures=$((failures + 1))
        fi
        ;;
    *)
        printf 'farm-write scan FAILED (exit %s; a scan that could not run must not read as farm_writes=0):\n' \
            "$farm_write_rc" >&2
        sed 's/^/      /' "$farm_write_err" >&2
        failures=$((failures + 1))
        ;;
    esac
    rm -f -- "$farm_write_err"
    if [ -n "$farm_write_hits" ]; then
        while IFS= read -r farm_hit; do
            [ -n "$farm_hit" ] || continue
            printf 'repo script FAILED (a raw redirect into a directory this file fills with symlinks writes THROUGH the link and truncates the real binary it points at; route it through write_stub, which unlinks first): %s\n' \
                "$farm_hit" >&2
            farm_write_count=$((farm_write_count + 1))
        done <<EOF
$farm_write_hits
EOF
        failures=$((failures + 1))
    fi
    farm_write_summary=$farm_write_count
    # Both directions: a detector that cannot fire reports a clean tree forever.
    # The fixtures live in the .py file, so this exercises the shipped classifier.
    if ! farm_selftest_out=$(python3 -I "$root/smoke/01-farm-write.py" --self-test 2>&1); then
        printf '%s\n' 'farm-write detector FAILED its self-check -- the detector itself is broken' >&2
        printf '%s\n' "$farm_selftest_out" >&2
        failures=$((failures + 1))
    fi
else
    farm_write_summary='skipped(no-python3)'
fi

# --- checks that depend on python3 must probe that it RUNS -------------------
# `command -v python3` is not a probe: on a zh-CN Windows 10 `python3` is the
# Microsoft Store alias, which EXISTS, exits 49 and runs nothing.  The failure
# this rule locks was measured 2026-10-25: with a stub python3 that exits 49,
# smoke/26 exited 49 with ZERO output, and run-tests.sh can only report that as
# a bare FAIL -- an environment fault presented as a contract failure, which is
# the same misdirection as the pwsh startup-cache rounds.  smoke/26's header
# even claimed "this needs only bash, jq and cp".  Every other python3 user
# (01, 08, 10, 11, 12, 14, 20, 22, 29) already probes; the census below is what
# keeps a NEW dependent from joining without one.
#
# The usage test is deliberately narrow (`python3 -`) rather than "the word
# python3 appears": the prose in these headers discusses python3 constantly, and
# a rule that fires on prose would be turned off within a week.  Narrow means it
# can miss an exotic invocation; that is the accepted edge, and the census
# floor below makes a broken enumeration visible.
# A probe that RUNS but whose result nobody reads is not a probe.  Measured
# 2026-10-25: `python3 -c 'import sys' >/dev/null 2>&1 || true` and
# `... || probe_failed=1` with `probe_failed` never read both passed the first
# version of this rule, which only asked whether the probe SPELLING appeared.
# The rule now requires the probe line to consume its own result in one of the
# three shapes this repo uses: `if/elif/while python3 ...`, `|| exit ...`, or
# `|| VAR=` with VAR read somewhere later in the same file.  Anything else --
# including `|| true` and `|| :` -- is a discarded probe.
python3_census() { # <file> -> 0 usage+probe, 1 usage without probe, 2 no usage
    local f=$1 usage probe_lines line var n_ok=0 n_bad=0
    usage=$(grep -nE '(^|[^[:alnum:]_-])python3[[:space:]]+-' "$f" 2>/dev/null |
        grep -vE '^[0-9]+:[[:space:]]*#' || true)
    [ -n "$usage" ] || { printf '2'; return 0; }
    # Both probe spellings in use here: `python3 -c 'import sys'` and
    # `python3 -I -c 'pass'`.
    # The closing quote is part of the pattern: `-c 'import sys, yaml'` is a
    # YAML probe, not a usability probe.  Measured 2026-10-25 -- the unanchored
    # version reported smoke/01 itself as a violation because four YAML probes
    # start with "import sys,".
    # Two exclusions, both measured 2026-10-25:
    #  * a leading `printf`/`echo` means the probe is FIXTURE TEXT being written
    #    by a self-test, not a probe that runs -- this rule's own fixtures live
    #    in this file, so without this the file reports itself as a violation;
    #  * the closing quote is part of the pattern: `-c 'import sys, yaml'` is a
    #    YAML probe, not a usability probe.
    probe_lines=$(grep -E "python3[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-c[[:space:]]+('import sys'|\"import sys\"|'pass'|\"pass\")" "$f" 2>/dev/null |
        grep -vE '^[[:space:]]*#' |
        grep -vE '^[[:space:]]*(printf|echo)[[:space:]]' || true)
    [ -n "$probe_lines" ] || { printf '1'; return 0; }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case $line in
        *'|| true'* | *'|| :'*)
            n_bad=$((n_bad + 1))
            continue
            ;;
        esac
        case $line in
        *'|| exit'*)
            n_ok=$((n_ok + 1))
            continue
            ;;
        esac
        # `*if\ python3*` is a SUBSTRING match, so it already covers
        # `elif python3` (the letters `if` end `elif`).  The two `elif`
        # alternatives were therefore dead branches -- shellcheck's SC2221/
        # SC2222, reported the moment this file's analysis stopped aborting at
        # line 1104.  Dropping them changes nothing: the surviving patterns
        # still accept `if python3`, `if ! python3`, `elif python3`,
        # `elif ! python3` and `while python3`, and still reject `|| true`.
        case $line in
        *if\ python3* | *if\ !\ python3* | *while\ python3*)
            n_ok=$((n_ok + 1))
            continue
            ;;
        esac
        var=$(printf '%s\n' "$line" |
            sed -nE 's/.*\|\|[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p')
        if [ -n "$var" ] && grep -qE "\\\$\{?${var}([^A-Za-z0-9_]|$)" "$f"; then
            n_ok=$((n_ok + 1))
        else
            n_bad=$((n_bad + 1))
        fi
    done <<EOF
$probe_lines
EOF
    if [ "$n_ok" -gt 0 ] && [ "$n_bad" -eq 0 ]; then printf '0'; else printf '1'; fi
}
# Fixtures first, built here rather than borrowed from the tree: a self-test
# that runs against whatever the repo happens to contain cannot tell a working
# rule from a lucky one.
pc_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentq-python3-census.XXXXXX")
printf '%s\n' '#!/bin/sh' 'python3 - "$1" <<PY' 'print(1)' 'PY' >"$pc_dir/bare"
printf '%s\n' '#!/bin/sh' "python3 -c 'import sys' >/dev/null 2>&1 || exit 1" \
    'python3 - "$1" <<PY' 'print(1)' 'PY' >"$pc_dir/probed"
printf '%s\n' '#!/bin/sh' 'grep foo "$1"' >"$pc_dir/none"
printf '%s\n' '#!/bin/sh' '# the python3 on PATH may be a store alias' \
    '# python3 -c is what a probe looks like' 'true' >"$pc_dir/prose"
# A probe whose result is thrown away, and one whose variable is never read,
# are both NOT probes -- measured to pass the first version of this rule.
printf '%s\n' '#!/bin/sh' "python3 -c 'import sys' >/dev/null 2>&1 || true" \
    'python3 - "$1" <<PY' 'print(1)' 'PY' >"$pc_dir/discarded-probe"
printf '%s\n' '#!/bin/sh' "python3 -c 'import sys' >/dev/null 2>&1 || probe_broken=1" \
    'python3 - "$1" <<PY' 'print(1)' 'PY' >"$pc_dir/unread-probe"
printf '%s\n' '#!/bin/sh' "python3 -c 'import sys' >/dev/null 2>&1 || probe_broken=1" \
    '[ "$probe_broken" = 1 ] && exit 1' \
    'python3 - "$1" <<PY' 'print(1)' 'PY' >"$pc_dir/read-probe"
printf '%s\n' '#!/bin/sh' \
    "if ! python3 -c 'import sys' >/dev/null 2>&1; then exit 1; fi" \
    'python3 - "$1" <<PY' 'print(1)' 'PY' >"$pc_dir/if-probe"
python3_census_failures=0
for spec in bare:1 probed:0 none:2 prose:2 discarded-probe:1 unread-probe:1 read-probe:0 if-probe:0; do
    pc_file=${spec%%:*}
    pc_want=${spec#*:}
    pc_got=$(python3_census "$pc_dir/$pc_file")
    if [ "$pc_got" != "$pc_want" ]; then
        printf 'python3-census self-test: %s expected %s, got %s\n' \
            "$pc_file" "$pc_want" "$pc_got" >&2
        python3_census_failures=$((python3_census_failures + 1))
    fi
done
rm -rf -- "$pc_dir"
if [ "$python3_census_failures" -ne 0 ]; then
    failures=$((failures + 1))
fi
python3_users=0
for pc_script in "$root"/smoke/*.sh "$root/run-tests.sh" "$root/sandbox.sh"; do
    [ -f "$pc_script" ] || continue
    pc_verdict=$(python3_census "$pc_script")
    [ "$pc_verdict" = 2 ] && continue
    python3_users=$((python3_users + 1))
    if [ "$pc_verdict" = 1 ]; then
        printf 'check FAILED (this script runs python3 but never probes that it can execute; with a Microsoft Store alias on PATH it dies with exit 49 and zero output, which reads as a contract failure instead of an environment fault -- add the `python3 -c import sys` probe the other checks use): %s\n' \
            "${pc_script#"$root"/}" >&2
        failures=$((failures + 1))
    fi
done
# The floor is what makes a broken enumeration visible: a regex that stopped
# matching would otherwise report `python3_users=0` and look perfect.
if [ "$python3_users" -lt 5 ]; then
    printf 'python3-census FAILED (only %s dependent scripts were enumerated; the census is broken, not the tree)\n' \
        "$python3_users" >&2
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

# --- shell assets: a defined function nobody calls ---------------------------
# A function with zero call sites is not automatically a defect -- an API surface
# kept for a future caller is a legitimate choice.  What is NOT legitimate is a
# SECOND IMPLEMENTATION of a validator the live code already has: the copy that
# runs gets the fixes and the copy that does not run silently keeps the bugs.
# Measured 2026-10-23: three `validate_pueue_*_in_text` validators were
# line-for-line twins of the `_in_file` versions, had never been called in any
# commit (git log -S on the call spelling returns nothing), and had already
# diverged -- the live twins got the vanish-race fixes the dead ones did not.
# Four more (`require_agentq_task` and three `*_with_operation_lock`) were plain
# leftovers from the read-lock refactor.  All seven were removed.
#
# The rule: report every function with no call site, so the choice is made in
# the open.  A deliberate keep must be named in the allowlist below WITH a
# reason -- not silently tolerated.  Allowlist is empty today.
#
# HOW it counts, stated because a detector's shape is its verdict: one pass
# splits every non-comment line into identifier tokens (`split` on
# `[^A-Za-z0-9_]+`) and tallies them; function-definition lines are skipped, so
# a name's own declaration does not count as a use of itself.  Function names
# only contain [A-Za-z0-9_], so a token boundary and the rule's former
# `(^|[^A-Za-z0-9_])NAME([^A-Za-z0-9_]|$)` are the same set.  The first draft
# re-ran a dynamic regex per (function, line) pair -- 176x6400 -- which the
# token tally replaces with a single pass.  Do not attribute the check's total
# wall clock to this rule: removing it entirely measured 62s and keeping it
# measured 53s, i.e. the 50-90s spread belongs to the pwsh AST pass.
#
# Limits, stated rather than implied: a function invoked ONLY through a
# variable (`$cmd`) or from another file is a false positive waiting to happen.
# None exist in these assets today (every `$name` reference scan came back
# empty and each asset is self-contained), which is why the allowlist can be
# empty.  `command jq` suppresses function lookup, but `jq` has real direct
# callers all over the file, so it is not a case the rule has to get right.
unused_fn_prog=$(
    cat <<'AWK'
/^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\) \{/ {
    name = $0
    sub(/^[[:space:]]*/, "", name)
    sub(/\(\).*/, "", name)
    nfn++
    fname[nfn] = name
    next
}
/^[[:space:]]*#/ { next }
{
    n = split($0, words, /[^A-Za-z0-9_]+/)
    for (i = 1; i <= n; i++) if (words[i] != "") seen[words[i]]++
}
END {
    for (i = 1; i <= nfn; i++) {
        if (!(fname[i] in seen)) printf "%s\n", fname[i]
    }
}
AWK
)
# A deliberate keep goes here as `function: reason`.  Empty today: nothing in
# the tree is intentionally uncalled.
unused_fn_allow=$(cat <<'ALLOW'
ALLOW
)
unused_fn_count=0
while IFS= read -r unused_asset; do
    [ -n "$unused_asset" ] || continue
    while IFS= read -r unused_fn; do
        [ -n "$unused_fn" ] || continue
        grep -qE "^${unused_fn}:" <<<"$unused_fn_allow" && continue
        printf 'shell asset FAILED (a function with no call site -- delete it, or name it in the allowlist with a reason): %s: %s\n' \
            "${unused_asset#"$root"/}" "$unused_fn" >&2
        unused_fn_count=$((unused_fn_count + 1))
    done <<FN
$(awk "$unused_fn_prog" "$unused_asset")
FN
done <<ASSETS
$shell_assets
ASSETS
if [ "$unused_fn_count" -gt 0 ]; then
    failures=$((failures + 1))
fi
# Sanity: the rule must have been ABLE to see functions at all.  A parse that
# finds zero definitions in seven assets (one of them 6000+ lines) cannot
# distinguish "all called" from "never looked".
unused_fn_defs=0
while IFS= read -r unused_asset; do
    [ -n "$unused_asset" ] || continue
    n=$(grep -cE '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\) \{' "$unused_asset" || true)
    unused_fn_defs=$((unused_fn_defs + n))
done <<ASSETS
$shell_assets
ASSETS
if [ "$unused_fn_defs" -lt 50 ]; then
    printf 'shell asset FAILED (the no-call-site rule could only see %s function definitions across the scanned assets; refusing to report a pass)\n' \
        "$unused_fn_defs" >&2
    unused_fn_count=$((unused_fn_count + 1))
    failures=$((failures + 1))
fi

# Self-check, for the reason spelled out above the local-hazard rule: a
# construct-level detector that quietly stops matching reads exactly like a
# clean tree.  Measured 2026-10-23: setting the comparison to an impossible
# value made this rule report nothing and the whole check went green -- the
# failure mode this very rule exists to catch, in the rule itself.  Plant an
# uncalled function in a copy and require it to be named BY NAME.
unused_fn_selftest=$(mktemp)
{ cat "$root/skill/assets/unix/agentq-server"
  printf 'zz_planted_uncalled_helper() {\n    :\n}\n'
} >"$unused_fn_selftest"
if ! grep -qx 'zz_planted_uncalled_helper' <<<"$(awk "$unused_fn_prog" "$unused_fn_selftest")"; then
    printf '%s\n' 'shell asset FAILED (the no-call-site rule is silent on a planted uncalled function: the detector itself is broken)' >&2
    unused_fn_count=$((unused_fn_count + 1))
    failures=$((failures + 1))
fi
rm -f "$unused_fn_selftest"

# Every asset must belong to a kind that some rule above parses.  The kinds are
# extension-based (.ps1/.cmd/.plist/.yml/.service) plus "first line names a
# shell" -- the same shebang rule the parse arm uses.  Without this gate a NEW
# kind of file (a .psm1, a .json) joins skill/assets and is parsed by nothing:
# every counter below counts only its own category, so the summary would not
# move.  Deliberately no "23 files" constant -- a count pins today's inventory
# but not tomorrow's, while "is this file's kind parsed by a rule?" is the
# question the summary line is actually making.
#
# OS artifacts are not deployment content and never will be; Finder creates
# .DS_Store in any directory it displays, so a red there would be a false alarm
# about a file .gitignore already keeps out.  Everything else -- including an
# unknown ASSET kind -- must be classified.
# The same table, asked for the KIND rather than a yes/no.  One table, so the
# classifier and the per-kind census below cannot answer differently.
asset_kind() { # $1 = path -> ps1|cmd|plist|yml|service|shell|junk|unknown
    local asset_path=$1 asset_first
    case ${asset_path##*/} in
        .DS_Store|Thumbs.db|desktop.ini) printf 'junk\n'; return 0 ;;
    esac
    case $asset_path in
        *.ps1) printf 'ps1\n'; return 0 ;;
        *.cmd) printf 'cmd\n'; return 0 ;;
        *.plist) printf 'plist\n'; return 0 ;;
        *.yml) printf 'yml\n'; return 0 ;;
        *.service) printf 'service\n'; return 0 ;;
    esac
    asset_first=$(head -1 "$asset_path" 2>/dev/null || true)
    case $asset_first in
        "#!"*)
            case ${asset_first##* } in
                *sh) printf 'shell\n'; return 0 ;;
            esac
            ;;
    esac
    printf 'unknown\n'
}
asset_is_classified() {
    [ "$(asset_kind "$1")" != unknown ]
}

# Self-check, for the reason the other detectors carry one: a classifier that
# accepts everything reports a clean tree forever.  Fixtures live in a temp
# directory, NOT under skill/assets -- a self-test that plants its file in the
# deployment unit and is SIGKILLed would leave residue that this very gate (and
# the byte-parity checks) then reports on every later run.
unclassified_selftest_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentq-asset-kinds.XXXXXX")
printf '{}\n' >"$unclassified_selftest_dir/zz.json"
printf 'x\n' >"$unclassified_selftest_dir/zz.ps1"
printf 'x\n' >"$unclassified_selftest_dir/.DS_Store"
printf '#!/bin/sh\n:\n' >"$unclassified_selftest_dir/zz-shim"
unclassified_selftest_bad=0
asset_is_classified "$unclassified_selftest_dir/zz.json" && unclassified_selftest_bad=1
asset_is_classified "$unclassified_selftest_dir/zz.ps1" || unclassified_selftest_bad=1
asset_is_classified "$unclassified_selftest_dir/.DS_Store" || unclassified_selftest_bad=1
asset_is_classified "$unclassified_selftest_dir/zz-shim" || unclassified_selftest_bad=1
rm -rf -- "$unclassified_selftest_dir"
if [ "$unclassified_selftest_bad" -ne 0 ]; then
    printf '%s\n' 'asset-kind detector FAILED its self-check (.json must be rejected; .ps1, .DS_Store and a #!-shim must be accepted) -- the detector itself is broken' >&2
    failures=$((failures + 1))
fi

unclassified_assets=0
while IFS= read -r asset_file; do
    if ! asset_is_classified "$asset_file"; then
        printf 'asset FAILED (no rule parses this kind of file -- add a category, or do not ship it): %s\n' \
            "${asset_file#"$root"/}" >&2
        unclassified_assets=$((unclassified_assets + 1))
    fi
done < <(find "$root/skill/assets" -type f | sort)
failures=$((failures + unclassified_assets))

# --- per-kind census: each arm's count must equal what the tree holds --------
# Every per-kind arm above enumerates with its own glob (`-name '*.plist'`,
# `-name '*.yml'`, ...) and prints how many files it saw.  Measured 2026-10-26:
# a one-letter typo in ANY of those five globs (`*.plst`, `*.yam2`, `*.srvc`,
# `*.cmdx`, `*.psx`) left that arm enumerating nothing while this check exited
# 0 -- the summary printed `plist=0` / `yml=0` / ... and the whole kind was
# parsed by no rule at all.  The `unclassified` gate above answers the
# OPPOSITE question (a file whose kind nothing parses); it cannot see an
# existing kind whose enumerator stopped matching.  The four `*_count`
# variables were write-only, and SC2034 does not flag a self-referencing
# increment (measured: `dead=0; dead=$((dead+1))` is clean), so the shellcheck
# lock could not see them either.
#
# The oracle is an independent enumeration: classify EVERY file under
# skill/assets (asset_kind, the same table the unclassified gate uses) and
# compare the per-kind totals with what each arm counted.  This proves the
# arm's glob still matches its kind.  It does NOT prove the deployment unit is
# complete -- a deleted asset is a different question, answered by the index
# floor in skill_modes (`-lt 25`); a file deleted from the WORKTREE but still
# in the index is caught by neither and shows only in `git status`.
kind_census() { # $1 = directory -> "kind count" per kind, sorted
    local census_asset
    while IFS= read -r census_asset; do
        asset_kind "$census_asset"
    done < <(find "$1" -type f | sort) | sort | uniq -c | awk '{printf "%s %s\n", $2, $1}'
}
kind_census_gate() { # $1=census text $2=kind $3=arm count $4=arm label -> rc 0 = agree
    local want
    want=$(printf '%s\n' "$1" | awk -v k="$2" '$1 == k { printf "%s", $2 }')
    [ -n "$want" ] || want=0
    if [ "$3" -ne "$want" ]; then
        printf 'per-kind census FAILED (%s: the %s arm counted %s file(s) but the tree holds %s -- the arm'"'"'s glob no longer matches its kind, so those files are parsed by nothing)\n' \
            "$2" "$4" "$3" "$want" >&2
        return 1
    fi
    return 0
}
# Self-checks, for the reason every other detector here carries one.  The census
# must classify a known fixture correctly, and the comparator must FIRE on a
# wrong count -- a comparator that always agrees would keep this gate green
# forever.
kind_census_selftest_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentq-kind-census.XXXXXX")
printf 'x\n' >"$kind_census_selftest_dir/a.plist"
printf 'x\n' >"$kind_census_selftest_dir/b.cmd"
printf '#!/bin/sh\n:\n' >"$kind_census_selftest_dir/c-shim"
printf '{}\n' >"$kind_census_selftest_dir/d.json"
kind_census_selftest=$(kind_census "$kind_census_selftest_dir" | tr '\n' ' ')
rm -rf -- "$kind_census_selftest_dir"
if [ "$kind_census_selftest" != 'cmd 1 plist 1 shell 1 unknown 1 ' ]; then
    printf 'per-kind census FAILED its self-check (expected "cmd 1 plist 1 shell 1 unknown 1 ", got "%s")\n' \
        "$kind_census_selftest" >&2
    failures=$((failures + 1))
fi
kind_census_fixture='plist 2
ps1 7'
if ! kind_census_gate "$kind_census_fixture" plist 2 'self-check (agreeing)'; then
    printf '%s\n' 'per-kind census comparator FAILED its self-check (a matching count was reported as a mismatch)' >&2
    failures=$((failures + 1))
fi
if kind_census_gate "$kind_census_fixture" plist 0 'self-check (mismatched)' 2>/dev/null; then
    printf '%s\n' 'per-kind census comparator FAILED its self-check (a wrong count was accepted)' >&2
    failures=$((failures + 1))
fi
if ! kind_census_gate "$kind_census_fixture" cmd 0 'self-check (absent kind)' 2>/dev/null; then
    printf '%s\n' 'per-kind census comparator FAILED its self-check (an absent kind must compare as 0)' >&2
    failures=$((failures + 1))
fi

kind_census_checked='checked'
kind_census_text=$(kind_census "$root/skill/assets")
kind_census_gate "$kind_census_text" shell "$shell_count" 'shell' || failures=$((failures + 1))
kind_census_gate "$kind_census_text" plist "$plist_count" '.plist' || failures=$((failures + 1))
kind_census_gate "$kind_census_text" service "$service_count" '.service' || failures=$((failures + 1))
kind_census_gate "$kind_census_text" cmd "$cmd_count" '.cmd' || failures=$((failures + 1))
if [ "$pwsh_state" = usable ]; then
    kind_census_gate "$kind_census_text" ps1 "$ps_count" '.ps1' || failures=$((failures + 1))
fi
if [ "$yaml_summary" != 'skipped(no pyyaml)' ]; then
    kind_census_gate "$kind_census_text" yml "$yaml_count" '.yml' || failures=$((failures + 1))
fi

# `shell=` (files the parse arm checked) and `local_hazard_files=` (files the
# static rules scanned) are the same set by construction -- both derive from
# $shell_assets.  Pin it anyway: for one day they were 9 and 7, printed side by
# side in this summary line, and nothing compared them.
if [ "$shell_count" -ne "$local_hazard_file_count" ]; then
    printf 'syntax-and-parity FAILED (the parse arm checked %s shell assets but the static rules scanned %s -- the two lists have drifted apart)\n' \
        "$shell_count" "$local_hazard_file_count" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'syntax-and-parity: %s failure(s)\n' "$failures" >&2
    exit 1
fi
summary=$(printf 'syntax-and-parity checks passed: shell=%s ps1=%s ps1_static=%s ps1_encoding=%s plist=%s yml=%s service=%s cmd=%s configpaths=%s parity=ok version=%s tool_full=%s/%s repo_scripts=%s repo_pipes=%s redir_noop=%s mktemp_suffix=%s local_hazards=%s local_hazard_files=%s uncalled=%s unclassified=%s farm_writes=%s python3_users=%s entrypoints=%s workflows=%s ci_pin=%s gitattr=%s gitignore=%s skill_modes=%s kinds=%s summary_census=%s' \
    "$shell_count" "$ps_summary" "$ps_static_rules" "$ps1_encoding_summary" "$plist_summary" "$yaml_summary" "$service_summary" "$cmd_summary" "$config_patterns" "$version_summary" "$tool_present" "$tool_total" "$repo_script_count" "$repo_pipe_count" "$redir_noop_count" "$mktemp_suffix_count" "$local_hazard_count" "$local_hazard_file_count" "$unused_fn_count" "$unclassified_assets" "$farm_write_summary" "$python3_users" "$repo_entry_count" "$workflow_summary" "$ci_pin_summary" "$gitattr_state" "$gitignore_state" "$skill_modes_state" "$kind_census_checked" "$summary_census_checked")
[ "$tool_summary" = 0 ] || summary="$summary $tool_summary"

# Every token this check promises must actually appear in the line.  Why this
# exists: a summary variable that is only ever assigned on a FAILING branch is
# dead code (the failure path exits before the line prints), and so is one whose
# printf argument was dropped during an edit.  Both were written and removed
# twice in the rounds that added farm_writes and ci_pin.  This lock is about the
# printed line, not the assignments: it catches a dropped printf argument and a
# token that never gets a value, without trying to parse control flow.
#
# `tool_full` is formatted as `tool_full=%s/%s`, so it is matched by prefix.
summary_tokens='shell ps1 ps1_static ps1_encoding plist yml service cmd configpaths parity version tool_full repo_scripts repo_pipes redir_noop mktemp_suffix local_hazards local_hazard_files uncalled unclassified farm_writes python3_users entrypoints workflows ci_pin gitattr gitignore skill_modes kinds summary_census'
missing_tokens=''
for tok in $summary_tokens; do
    # An EMPTY value counts as missing.  Measured 2026-10-25: a token assigned
    # only on the failing branch still printed as `ci_pin=` (empty) and the
    # key-presence test passed it -- the dead assignment became a blank column
    # that reads like a value nobody filled in.  The value must be non-empty up
    # to the next space.
    case " $summary " in
    *" $tok=" | *" $tok= "*) missing_tokens="$missing_tokens $tok" ;;
    *) ;;
    esac
done
if [ -n "$missing_tokens" ]; then
    printf 'syntax-and-parity FAILED (the summary line lost these tokens:%s -- a token that never prints cannot be read, and a token that only a failing branch assigns is dead code)\n' \
        "$missing_tokens" >&2
    failures=$((failures + 1))
fi
if [ "$failures" -ne 0 ]; then
    printf 'syntax-and-parity: %s failure(s)\n' "$failures" >&2
    exit 1
fi

printf '%s\n' "$summary"
