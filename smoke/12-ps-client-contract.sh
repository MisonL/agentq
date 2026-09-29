#!/usr/bin/env bash
# Smoke: the PowerShell client's LOCAL contract, run under pwsh.  No remote is
# contacted -- every case here is rejected during argument validation, before
# the client resolves ssh or builds an invocation.
#
# Why this check exists: before it, assets/client/windows/agentq.ps1 had no
# executable coverage anywhere in the suite.  01 parses it with the PowerShell
# AST, and 10 asserts two source-level invariants about it, but nothing had ever
# RUN it.  Its bad-argument contract was recorded in CLAUDE.md prose as "13 cases
# measured on a Windows 11 VM" -- a real measurement, but not a re-runnable one.
#
# THE LIMIT, stated up front because it is the whole point of this file's
# placement in the suite: this runs under pwsh 7.5, NOT under Windows
# PowerShell 5.1.  pwsh does NOT reproduce the two PS 5.1 defects this project
# has actually been bitten by -- the native-argument word-splitting that
# smoke/09 models, and the -EncodedCommand path.  So this check proves the
# contract holds under pwsh.  It does NOT close the PS 5.1 gap, and the CLAUDE.md
# note about the VM measurement stays the only PS 5.1 evidence there is.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
client="$root/assets/client/windows/agentq.ps1"
# Windows PowerShell 5.1 does not accept a POSIX path for -File (pwsh 7.5
# does), so when this check runs under it on a real Windows host the path has to
# be handed over in Windows form.  `cygpath` exists only under Git Bash, so this
# stays a no-op everywhere else -- including the normal pwsh run on macOS.
if [ -n "${AGENTQ_SMOKE_PWSH:-}" ] && command -v cygpath >/dev/null 2>&1; then
    client_arg=$(cygpath -w "$client")
else
    client_arg=$client
fi
# AGENTQ_SMOKE_PWSH lets this check run under a DIFFERENT PowerShell than the
# one on PATH -- specifically Windows PowerShell 5.1, which is the version this
# project has actually been bitten by and which pwsh does not reproduce.  Set it
# to `powershell.exe` to run the same 31 cases on the interpreter that matters.
# Left unset (the normal case) the behaviour is unchanged.
pwsh_binary=${AGENTQ_SMOKE_PWSH:-$(command -v pwsh || true)}

if [ -z "$pwsh_binary" ] || ! command -v "$pwsh_binary" >/dev/null 2>&1; then
    printf 'SKIPPED: pwsh is not available (AGENTQ_SMOKE_PWSH=%s); the PowerShell client was not executed\n' \
        "${AGENTQ_SMOKE_PWSH:-<unset>}"
    exit 0
fi

work=$(mktemp -d /tmp/agentq-smoke-psclient.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

failures=0
cases=0

# expect_rejected <expected-message-fragment> [args...]
#
# AGENTQ_HOST is set so the run gets past the host check and reaches the
# per-command validation under test.  No ssh is resolved or contacted: every
# case below fails before Initialize-ClientTransport.
expect_rejected() {
    local expected=$1
    shift
    local label=$*
    cases=$((cases + 1))
    local status=0
    AGENTQ_HOST=smoke-host "$pwsh_binary" -NoProfile -NonInteractive \
        -File "$client_arg" "$@" >"$work/out" 2>"$work/err" || status=$?
    if [ "$status" -ne 2 ]; then
        printf 'ps-client %s: expected exit 2, got %s\n' "${label:-<no args>}" "$status" >&2
        head -3 "$work/err" >&2 || true
        failures=$((failures + 1))
        return
    fi
    if ! grep -qF -- "$expected" "$work/err"; then
        printf 'ps-client %s: stderr does not contain %s\n' "${label:-<no args>}" "$expected" >&2
        head -3 "$work/err" >&2 || true
        failures=$((failures + 1))
    fi
}

# --- host and top-level argument handling ------------------------------------
# AGENTQ_CONFIG is redirected at a path that does not exist, and this is not
# optional housekeeping: the client reads AGENTQ_HOST out of
# ~/.config/agentq/config when the environment does not set it, and this machine
# HAS that file (measured: it exists and supplies a host).  Without the redirect
# the no-host case silently resolved a real host, fell through to the
# missing-command branch, and printed usage instead -- so the assertion failed
# while the client was behaving correctly.  A check that reads the developer's
# own config is not hermetic, and it would behave differently on another machine.
cases=$((cases + 1))
status=0
AGENTQ_CONFIG="$work/absent-config" "$pwsh_binary" -NoProfile -NonInteractive \
    -File "$client_arg" >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 2 ] || ! grep -qF 'no SSH host configured' "$work/err"; then
    printf '%s\n' 'ps-client <no args>: expected exit 2 and "no SSH host configured"' >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

expect_rejected '--host requires an SSH host' --host
expect_rejected 'SSH host must not begin with a hyphen' --host -evil status
expect_rejected 'unknown command: bogus' --host smoke-host bogus

# A host followed by nothing: the client prints usage and exits 2, rather than
# treating the missing command as an empty string.
cases=$((cases + 1))
status=0
AGENTQ_HOST=smoke-host "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 2 ] || ! grep -qF 'Usage:' "$work/out" "$work/err"; then
    printf '%s\n' 'ps-client <no command>: expected exit 2 and a usage listing' >&2
    failures=$((failures + 1))
fi

# --- per-command arity and value validation ----------------------------------
expect_rejected 'lookup requires one request id' --host smoke-host lookup
expect_rejected 'lookup requires one request id' --host smoke-host lookup a b
expect_rejected 'status accepts no arguments' --host smoke-host status extra

# `logs` has its own message because it also accepts --tail; the other three
# share the plain arity message.  Both were read off the client rather than
# guessed -- the first version of this file asserted messages that do not exist.
expect_rejected 'logs requires a task id' --host smoke-host logs
expect_rejected 'logs requires a task id' --host smoke-host logs 1 2
for command in cancel wait remove; do
    expect_rejected "$command requires one task id" --host smoke-host "$command"
    expect_rejected "$command requires one task id" --host smoke-host "$command" 1 2
    expect_rejected 'task id must be a non-negative integer' --host smoke-host "$command" notanumber
    expect_rejected 'task id must be a non-negative integer' --host smoke-host "$command" -1
done

expect_rejected '--workdir is required' --host smoke-host submit -- true
expect_rejected '--workdir requires a directory' --host smoke-host submit --workdir
expect_rejected 'submit requires a command after --' \
    --host smoke-host submit --workdir /tmp
expect_rejected '--label requires a label' \
    --host smoke-host submit --workdir /tmp --label
expect_rejected '--request-id requires a value' \
    --host smoke-host submit --workdir /tmp --request-id

# --- environment validation --------------------------------------------------
# The client validates these before any transport work, so a bad value must be
# rejected on the --help path too.
cases=$((cases + 1))
status=0
AGENTQ_HOST=smoke-host AGENTQ_SUBMIT_RETRY_ATTEMPTS=0 \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" --help \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 2 ] || ! grep -qF 'must be a positive 32-bit integer' "$work/err"; then
    printf '%s\n' 'ps-client AGENTQ_SUBMIT_RETRY_ATTEMPTS=0: expected exit 2 and "must be a positive 32-bit integer"' >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

# --- the reason channel must survive the client's redaction -------------------
# Write-Diagnostics deliberately withholds raw SSH diagnostics and prints only a
# class and a byte count.  The server's machine-readable `reason=<class>` line
# is carved out of that redaction -- and only that line, and only when it
# matches the strict token class, so the exception cannot become an injection
# channel.  These cases call the function directly rather than driving a whole
# ssh invocation: it is the classification that carries the risk.
reason_probe='
. "'"$client_arg"'" 2>$null
$cases = @(
    @{ n = "plain";    v = "agentq-server: reason=lock_contention";             e = "lock_contention" },
    @{ n = "crlf";     v = "agentq-server: reason=task_not_running`r";          e = "task_not_running" },
    @{ n = "mixed";    v = "agentq-server: already in progress`nagentq-server: reason=lock_contention`n"; e = "lock_contention" },
    @{ n = "inject";   v = "agentq-server: reason=lock_contention; rm -rf /";   e = "" },
    @{ n = "upper";    v = "agentq-server: reason=Lock_Contention";             e = "" },
    @{ n = "space";    v = "agentq-server: reason=lock contention";             e = "" },
    @{ n = "absent";   v = "agentq-server: some other failure";                 e = "" },
    @{ n = "empty";    v = "";                                                  e = "" }
)
$bad = 0
foreach ($case in $cases) {
    $actual = Get-RemoteFailureReason -Diagnostics $case.v
    if ($null -eq $actual) { $actual = "" }
    if ($actual -ne $case.e) {
        [Console]::Error.WriteLine("reason case $($case.n): expected [$($case.e)] got [$actual]")
        $bad += 1
    }
}
if ($bad -ne 0) { exit 1 }
"reason cases ok: $($cases.Count)"
'
cases=$((cases + 1))
status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command "$reason_probe" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] || ! grep -qF 'reason cases ok' "$work/out"; then
    printf '%s\n' 'ps-client: the remote failure reason channel misbehaves' >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

# --- an authentication failure must say what to DO about it -------------------
# The class line (`class=authentication`) is correct but does not tell the
# operator anything actionable, and the line the caller prints next on a failed
# platform probe -- "set AGENTQ_REMOTE_PLATFORM" -- points the wrong way, because
# no value of that variable fixes a missing key.  The POSIX client prints an
# extra hint; this client did not, and the gap was invisible because the
# classifier itself was right (the class said `authentication`, the hint just
# never followed).  Measured on a real host offering only password auth: the
# operator saw only the AGENTQ_REMOTE_PLATFORM direction, which reads like a
# remote service fault.
#
# Both directions are asserted: the hint MUST appear for an authentication
# failure, and must NOT appear for any other class -- otherwise it degrades into
# noise that operators learn to skip, which is how the original hint lost its
# value.
authhint_probe='
. "'"$client_arg"'" 2>$null
$cases = @(
    @{ n = "permission";  v = "user@host: Permission denied (publickey,password,keyboard-interactive).`r`n"; want = $true },
    @{ n = "hostkey";     v = "Host key verification failed.`r`n";                                    want = $true },
    @{ n = "other";       v = "ssh: connect to host example port 22: Connection refused`r`n";          want = $false },
    @{ n = "empty";       v = "";                                                                      want = $false }
)
$bad = 0
foreach ($case in $cases) {
    $sb = New-Object System.Text.StringBuilder
    $sw = New-Object System.IO.StringWriter($sb)
    $old = [Console]::Error
    [Console]::SetError($sw)
    try {
        Write-Diagnostics -Diagnostics $case.v
    } finally {
        [Console]::SetError($old)
    }
    $text = $sb.ToString()
    $has = $text -match "BatchMode=yes, so it cannot answer a password prompt"
    if ($has -ne $case.want) {
        [Console]::Error.WriteLine("auth hint case $($case.n): expected hint=$($case.want) got=$has")
        $bad += 1
    }
    # The hint must name the host, or it does not tell the operator which key to
    # install.
    if ($case.want -and $text -notmatch [regex]::Escape([string]$script:TargetHost)) {
        [Console]::Error.WriteLine("auth hint case $($case.n): hint does not name the target host")
        $bad += 1
    }
}
if ($bad -ne 0) { exit 1 }
"auth hint cases ok: $($cases.Count)"
'
cases=$((cases + 1))
status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command "$authhint_probe" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] || ! grep -qF 'auth hint cases ok' "$work/out"; then
    printf '%s\n' 'ps-client: the authentication hint is missing or misfires' >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

# --- the out-of-band exit token must survive an INDENTED multi-line probe ----
# Under a `DefaultShell` of powershell.exe the outer shell flattens every non-zero
# exit code to 1, so the probe reports its real code on stdout as
# `agentq-exit:<code>` and the caller reads that instead.  For the token line to
# run at all, every `exit N` in the probe body has to be rewritten to an
# assignment -- otherwise the first `exit` ends the script and the token is never
# printed.
#
# The rewrite used `(?m)(^|;[ \t]*)exit ([0-9]+)`, and `(?m)^` matches only
# immediately after a newline.  The AgentQ protocol probe body is an indented
# multi-line here-string, so ZERO of its exits were rewritten; the platform
# probe, which is a single line, worked -- which is why this went unnoticed.
# Measured before the fix: 0 of 7 rewritten on the real body.
#
# This asserts the property, not the regex: after rewriting, no bare `exit N` may
# remain and every code must have become an assignment.
token_probe='
. "'"$client_arg"'" 2>$null
$body = @"
if (`$null -eq `$launcherItem) {
    [Console]::Out.Write(""agentq-windows-launcher-missing"")
    exit 42
}
try {
    exit 43
} catch {
    exit 44
}
exit 45
"@
$rewritten = Add-ProbeExitToken -Script $body
$bare = ([regex]::Matches($rewritten, "(?m)^[ \t]*exit [0-9]+")).Count
$assigned = ([regex]::Matches($rewritten, "\`$agentqProbeExit = [0-9]+")).Count
if ($bare -ne 0) {
    [Console]::Error.WriteLine("probe exit rewrite left $bare bare exit statement(s)")
    exit 1
}
# 4 from the body plus 1 from the appended token line, which the same rewrite
# also turns into an assignment (that is what makes the token printable).
if ($assigned -ne 5) {
    [Console]::Error.WriteLine("probe exit rewrite assigned $assigned of 5 expected")
    exit 1
}
if ($rewritten -notmatch "agentq-exit:") {
    [Console]::Error.WriteLine("rewritten probe does not emit the agentq-exit token")
    exit 1
}
"exit-token rewrite ok: assigned=$assigned bare=0"
'
cases=$((cases + 1))
status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command "$token_probe" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] || ! grep -qF 'exit-token rewrite ok' "$work/out"; then
    printf '%s\n' 'ps-client: the probe exit token does not survive an indented multi-line body' >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

# --- credential sources -------------------------------------------------------
# The BatchMode decision is what makes password authentication possible at all,
# and nothing asserted the option VALUE before: smoke/14 measures command-line
# length, smoke/01 only parses.  A client that always sent the same value would
# pass both.  So both directions are asserted here.
credential_probe='
. "'"$client_arg"'" 2>$null
$script:TargetHost = "smoke-host"
$bad = 0

$script:CredentialSource = ""
$script:CredentialOptionLines = Get-CredentialSshOptions
$joined = ($script:CredentialOptionLines -join " ")
if ($joined -notmatch "(^| )-o BatchMode=yes( |$)") {
    [Console]::Error.WriteLine("no-source: expected BatchMode=yes, got: $joined")
    $bad += 1
}
if ($joined -match "NumberOfPasswordPrompts") {
    [Console]::Error.WriteLine("no-source: prompts option must not appear: $joined")
    $bad += 1
}

$script:CredentialSource = "askpass"
$script:AskPassProgram = "helper.exe"
$script:CredentialOptionLines = Get-CredentialSshOptions
$joined = ($script:CredentialOptionLines -join " ")
if ($joined -notmatch "(^| )-o BatchMode=no( |$)") {
    [Console]::Error.WriteLine("askpass: expected BatchMode=no, got: $joined")
    $bad += 1
}
if ($joined -notmatch "NumberOfPasswordPrompts=1") {
    [Console]::Error.WriteLine("askpass: expected a password prompt bound, got: $joined")
    $bad += 1
}

# The arrays must actually splice: an option list that never reaches ssh would
# satisfy every assertion above while doing nothing.
$script:CredentialSource = ""
$script:CredentialOptionLines = Get-CredentialSshOptions
$argv = @("-E","log","-o","LogLevel=ERROR") + $script:CredentialOptionLines + @("-o","ConnectTimeout=10","--","smoke-host","cmd")
if (($argv -join " ") -notmatch "LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=10") {
    [Console]::Error.WriteLine("splice: options did not land in order: $($argv -join " ")")
    $bad += 1
}
if ($argv[-1] -ne "cmd" -or $argv[-2] -ne "smoke-host") {
    [Console]::Error.WriteLine("splice: trailing arguments were displaced: $($argv -join " ")")
    $bad += 1
}

if ($bad -ne 0) { exit 1 }
"credential cases ok"
'
cases=$((cases + 1))
status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command "$credential_probe" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] || ! grep -qF 'credential cases ok' "$work/out"; then
    printf '%s\n' 'ps-client: the BatchMode decision or the POSIX-only refusals are wrong' >&2
    head -5 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

# POSIX-only sources must be refused here, not silently ignored.  Windows ssh
# reads the password from the console and blocks when there is none, so
# accepting these would hang an unattended call instead of failing.
#
# Invoked as a process rather than dot-sourced: the refusal path exits, and an
# exit inside a dot-sourced script ends the whole script -- a try/catch cannot
# see it, so an in-process probe would report success for a refusal that never
# happened.
AGENTQ_PASSWORD=secret AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
    >"$work/out" 2>"$work/err" || status=$?
cases=$((cases + 1))
if [ "${status:-0}" -ne 2 ]; then
    printf 'ps-client: AGENTQ_PASSWORD was not refused on Windows (expected exit 2, got %s)\n' "${status:-0}" >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
elif ! grep -qF 'AGENTQ_PASSWORD is not supported on Windows' "$work/err"; then
    printf '%s\n' 'ps-client: AGENTQ_PASSWORD was refused, but not for the stated reason' >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi
status=0
AGENTQ_PASSWORD_PROMPT=1 AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
    >"$work/out" 2>"$work/err" || status=$?
cases=$((cases + 1))
if [ "${status:-0}" -ne 2 ]; then
    printf 'ps-client: AGENTQ_PASSWORD_PROMPT was not refused on Windows (expected exit 2, got %s)\n' "${status:-0}" >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
elif ! grep -qF 'AGENTQ_PASSWORD_PROMPT is not supported on Windows' "$work/err"; then
    printf '%s\n' 'ps-client: AGENTQ_PASSWORD_PROMPT was refused, but not for the stated reason' >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi
status=0
AGENTQ_ASKPASS="$work/absent-askpass" AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
    >"$work/out" 2>"$work/err" || status=$?
cases=$((cases + 1))
if [ "${status:-0}" -ne 2 ]; then
    printf 'ps-client: a nonexistent AGENTQ_ASKPASS was not refused (expected exit 2, got %s)\n' "${status:-0}" >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
elif ! grep -qF 'AGENTQ_ASKPASS is not a regular non-reparse file' "$work/err"; then
    printf '%s\n' 'ps-client: a nonexistent AGENTQ_ASKPASS was refused, but not for the stated reason' >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi
status=0

# ssh executes the WHOLE SSH_ASKPASS value as a single file name -- no shell, no
# word splitting -- so an argument or a surrounding quote can never be part of it.
# Measured on a real Windows host (Git Bash MSYS ssh 9.9p1) and locally
# (OpenSSH 10.3p1): a bare path authenticates, while both of these fail.  An
# earlier revision validated only the FIRST token (from the since-disproved
# belief that "cmd.exe /c helper.cmd" was the working shape), so it ACCEPTED
# them and the failure surfaced later as a connection timeout -- pointing the
# operator at the network instead of at the credential setting.  Both
# directions are asserted: the working shape must still be accepted below.
for shape in '--flag' 'quoted'; do
    cases=$((cases + 1))
    status=0
    if [ "$shape" = 'quoted' ]; then
        value="\"$work/absent-askpass\""
    else
        value="$work/absent-askpass --flag"
    fi
    AGENTQ_ASKPASS="$value" AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
        "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
        >"$work/out" 2>"$work/err" || status=$?
    if [ "${status:-0}" -ne 2 ]; then
        printf 'ps-client: AGENTQ_ASKPASS with %s was not refused (expected exit 2, got %s)\n' "$shape" "${status:-0}" >&2
        head -3 "$work/err" >&2 || true
        failures=$((failures + 1))
    elif ! grep -qF 'must be a single executable path' "$work/err"; then
        printf 'ps-client: AGENTQ_ASKPASS with %s was refused, but not for the shape\n' "$shape" >&2
        head -3 "$work/err" >&2 || true
        failures=$((failures + 1))
    fi
    status=0
done

# The other direction: a well-formed single path must PASS the guard.  Without
# this, a guard that refuses everything would satisfy every case above.  The
# client is pointed at a host that cannot resolve, so it must get past the
# credential check and fail later -- the assertion is that the failure is NOT a
# credential refusal.  (Mutation-tested: making the guard unconditional left the
# earlier cases green, which is why this one exists.)
#
# Two well-formed shapes, and the second one is the reason this matters: a path
# containing a SPACE is legal, because ssh executes the whole value as a single
# file name and never splits it.  "C:\Program Files\..." is the everyday case.
# An earlier revision rejected any value containing a space, which refused such
# paths outright -- so both are asserted.
for shape in 'plain' 'space'; do
    cases=$((cases + 1))
    status=0
    if [ "$shape" = 'space' ]; then
        mkdir -p "$work/askpass dir"
        real_askpass="$work/askpass dir/real-askpass.sh"
    else
        real_askpass="$work/real-askpass.sh"
    fi
    printf '#!/bin/sh\nprintf "%%s\\n" "x"\n' > "$real_askpass"
    chmod 700 "$real_askpass"
    AGENTQ_ASKPASS="$real_askpass" AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
        "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
        >"$work/out" 2>"$work/err" || status=$?
    if grep -qF 'must be a single executable path' "$work/err" ||
       grep -qF 'is not a regular non-reparse file' "$work/err"; then
        printf 'ps-client: a well-formed AGENTQ_ASKPASS (%s) was refused by the credential guard\n' "$shape" >&2
        head -3 "$work/err" >&2 || true
        failures=$((failures + 1))
    fi
    status=0
done

# --- the one case that must succeed ------------------------------------------
cases=$((cases + 1))
status=0
AGENTQ_HOST=smoke-host "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" --help \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ]; then
    printf 'ps-client --help: expected exit 0, got %s\n' "$status" >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
elif ! grep -qF 'submit --workdir' "$work/out"; then
    printf '%s\n' 'ps-client --help: usage does not list the submit form' >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'ps-client-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
# The ps51= token states whether THIS run exercised Windows PowerShell 5.1.
# Under pwsh it must keep saying NOT-covered -- pwsh does not reproduce the two
# PS 5.1 defects this project has been bitten by, so a green pwsh run says
# nothing about 5.1.  Under AGENTQ_SMOKE_PWSH=powershell.exe it says covered,
# because then it genuinely was.
ps_version=$("$pwsh_binary" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' | tr -d '\r')
case "$ps_version" in
    5.1.*) ps51_state=covered ;;
    *)     ps51_state=NOT-covered ;;
esac
printf 'ps-client-contract checks passed: cases=%s pwsh=%s ps51=%s reason=forwarded/injection-safe\n' \
    "$cases" "$ps_version" "$ps51_state"
