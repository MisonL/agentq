#!/usr/bin/env bash
# Smoke: the PowerShell client's LOCAL contract, run under pwsh.  No remote is
# contacted -- every case here is rejected during argument validation, before
# the client resolves ssh or builds an invocation.
#
# Why this check exists: before it, assets/client/windows/agentq.ps1 had no
# executable coverage anywhere in the suite.  01 parses it with the PowerShell
# AST, and 10 asserts two source-level invariants about it, but nothing had ever
# RUN it.  Its bad-argument contract was recorded in docs/verification-status.md prose as "13 cases
# measured on a Windows 11 VM" -- a real measurement, but not a re-runnable one.
#
# THE LIMIT, stated up front because it is the whole point of this file's
# placement in the suite: this runs under pwsh 7.5, NOT under Windows
# PowerShell 5.1.  pwsh does NOT reproduce the two PS 5.1 defects this project
# has actually been bitten by -- the native-argument word-splitting that
# smoke/09 models, and the -EncodedCommand path.  So this check proves the
# contract holds under pwsh.  It does NOT close the PS 5.1 gap, and the docs/verification-status.md
# note about the VM measurement stays the only PS 5.1 evidence there is.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

# python3 is a real dependency of this check: the extraction / parsing steps
# below are Python.  Probe that it RUNS, not that a name resolves -- measured
# 2026-10-20 on a zh-CN Windows 10, where `python3` is the Microsoft Store
# alias: the check died at its first Python step with exit 49 and ZERO output,
# which run-tests.sh can only report as a bare FAIL with no cause.  Same rule as
# the pwsh usability probes: an interpreter that cannot execute is an
# ENVIRONMENT fault, say so and do not claim the contract ran.
python3_probe_status=0
python3 -c 'import sys' >/dev/null 2>&1 || python3_probe_status=$?
if [ "$python3_probe_status" -ne 0 ]; then
    printf '%s\n' 'ps-client-contract NOT run: the python3 on PATH cannot execute (a Microsoft Store alias cannot run scripts).' >&2
    printf '%s\n' 'Install a real Python 3 and put it on PATH, then re-run.' >&2
    exit 1
fi
# The client path can be overridden (mirrors smoke/05's AGENTQ_SMOKE_CLIENT and
# smoke/18's AGENTQ_SMOKE_SERVER) so a mutation proof can point this whole check
# at a modified copy -- without the hook, red-proofing a source-level fix means
# swapping the real asset under the check while it runs.
client=${AGENTQ_SMOKE_PS_CLIENT:-$root/skill/assets/client/windows/agentq.ps1}
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
# to `powershell.exe` to run the same cases on the interpreter that matters.
# Left unset (the normal case) the behaviour is unchanged.
pwsh_binary=${AGENTQ_SMOKE_PWSH:-$(command -v pwsh || true)}

if [ -z "$pwsh_binary" ] || ! command -v "$pwsh_binary" >/dev/null 2>&1; then
    printf 'SKIPPED: pwsh is not available (AGENTQ_SMOKE_PWSH=%s); the PowerShell client was not executed\n' \
        "${AGENTQ_SMOKE_PWSH:-<unset>}"
    exit 0
fi

# Present is not the same as working.  A corrupt pwsh startup cache makes
# every launch die (measured five times in this repo, with four different
# messages: "String cannot have zero length", "Stack overflow",
# FileLoadException, and Abort trap: 6).  The existence test above cannot see
# that, so every case below would run against a pwsh that never starts and
# report its failures as asset defects -- the misdiagnosis smoke/01 fixed for
# itself in 2026-09-28.  Probe once: an unusable interpreter is an ENVIRONMENT
# fault, say so with the fix, and do not claim the check ran.
pwsh_probe_status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command 'exit 0' >/dev/null 2>&1 || pwsh_probe_status=$?
if [ "$pwsh_probe_status" -ne 0 ]; then
    printf '%s\n' \
        'PowerShell client contract NOT run: the pwsh on PATH cannot execute (startup cache).' >&2
    printf '%s\n' 'Try: mv ~/.cache/powershell/StartupProfileData-NonInteractive{,.broken}' >&2
    exit 1
fi

work=$(mktemp -d /tmp/agentq-smoke-psclient.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
# Keep the client's platform-probe cache inside this run's temp dir (0.1.11).
# A cache under the real ~/.config/agentq would (a) write into the developer's
# own config and (b) leak the resolved platform of this check's test hosts into
# other cases or other suites, which then SKIP the probe they mean to exercise.
export AGENTQ_PLATFORM_CACHE_DIR="$work/platform-cache"
# and default the cache OFF: these cases exercise probing itself, and a
# warm entry (written by an earlier case for the same test host) would skip
# the probe under test. The dedicated cache case below re-enables it with
# its own fresh directory.
export AGENTQ_PLATFORM_PROBE_CACHE=off
trap 'rm -rf -- "$work"' EXIT

failures=0

# Normalized stderr matching, exactly as smoke/23 documents: Windows PowerShell
# 5.1 wraps error messages across lines at the console width (measured on CI,
# 2026-10-13) and pwsh 7 colourises them; the fragment assertions are on the
# message text.  Same mechanism, one definition per file by design (12/13/23
# each define it; 12 and 13 gained it after 23's CI red proved the gap).
strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*m//g' "$1"; }
flatten_err() { strip_ansi "$1" | tr -d '\r' | tr '\n' ' ' | sed -E 's/ +/ /g'; }

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
    if ! grep -qF -- "$expected" <<< "$(flatten_err "$work/err")"; then
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
# `status` gained the --summary/--task modes (0.1.11); the client forwards
# them instead of rejecting, so the only rejection left is an argument that is
# neither mode.
expect_rejected 'status accepts --summary or --task' --host smoke-host status extra

# `logs` has its own message because it also accepts --tail; the other three
# share the plain arity message.  Both were read off the client rather than
# guessed -- the first version of this file asserted messages that do not exist.
expect_rejected 'logs requires a task id' --host smoke-host logs
expect_rejected 'logs requires a task id' --host smoke-host logs 1 2
for command in cancel wait remove; do
    if [ "$command" = wait ]; then
        expect_rejected 'wait requires a task id and optional --timeout <seconds>' --host smoke-host "$command"
        expect_rejected 'wait accepts only --timeout <seconds>' --host smoke-host "$command" 1 --nope 3
        expect_rejected '--timeout must be a positive integer' --host smoke-host "$command" 1 --timeout abc
    else
        expect_rejected "$command requires one task id" --host smoke-host "$command"
        expect_rejected "$command requires one task id" --host smoke-host "$command" 1 2
    fi
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
# Both ends of the accepted range, for the same reason the POSIX twin's loop
# tests three shapes (see smoke/05): `0` pins the lower end, `05` pins the shape
# the two clients used to disagree about (measured 2026-10-21: this client
# refused it, the POSIX one accepted it), and 2147483648 pins the upper end
# against the [int] behind Start-Sleep.  2147483647 must be ACCEPTED -- the
# positive control that keeps the bound from quietly tightening.
for numeric_case in "0:2" "05:2" "2147483648:2" "2147483647:0"; do
    numeric_value=${numeric_case%:*}
    numeric_expected=${numeric_case#*:}
    cases=$((cases + 1))
    numeric_status=0
    AGENTQ_HOST=smoke-host AGENTQ_SUBMIT_RETRY_ATTEMPTS="$numeric_value" \
        "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" --help \
        >"$work/out" 2>"$work/err" || numeric_status=$?
    if [ "$numeric_status" -ne "$numeric_expected" ]; then
        printf 'ps-client AGENTQ_SUBMIT_RETRY_ATTEMPTS=%s: expected exit %s, got %s\n' \
            "$numeric_value" "$numeric_expected" "$numeric_status" >&2
        head -3 "$work/err" >&2 || true
        failures=$((failures + 1))
    elif [ "$numeric_expected" -eq 2 ] && ! grep -qF 'must be a positive 32-bit integer' "$work/err"; then
        printf 'ps-client AGENTQ_SUBMIT_RETRY_ATTEMPTS=%s: stderr lacks the controlled message\n' \
            "$numeric_value" >&2
        failures=$((failures + 1))
    fi
done

# An AGENTQ_SSH that cannot be launched must be REFUSED with the contract's
# exit 2, not die as an unhandled throw.  Measured 2026-10-21 on this platform
# with a non-executable regular file: exit 1, empty stdout and stderr -- a
# failure with no diagnosis at all -- while the POSIX twin refused the same
# configuration at startup with exit 2 and a controlled message.  Windows has no
# execute bit, so what this asserts is the LAUNCH, which is the only question
# that can be answered on both platforms.
unlaunchable_dir="$work/unlaunchable"
mkdir -p "$unlaunchable_dir"
unlaunchable="$unlaunchable_dir/ssh-not-executable"
printf 'not an executable\n' > "$unlaunchable"
chmod 644 "$unlaunchable"
if [ "$client_arg" != "$client" ]; then
    unlaunchable_arg=$(cygpath -w "$unlaunchable")
else
    unlaunchable_arg="$unlaunchable"
fi
status=0
AGENTQ_SSH="$unlaunchable_arg" AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
    >"$work/out" 2>"$work/err" || status=$?
cases=$((cases + 1))
if [ "$status" -ne 2 ]; then
    printf 'ps-client: an unlaunchable AGENTQ_SSH exited %s, expected 2 (not an unhandled throw)\n' \
        "$status" >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
elif ! grep -qF 'AGENTQ_SSH cannot be launched' "$work/err"; then
    printf 'ps-client: an unlaunchable AGENTQ_SSH lacked the controlled message: %s\n' \
        "$(head -2 "$work/err" | tr '\n' '|')" >&2
    failures=$((failures + 1))
fi

# AGENTQ_REMOTE_PLATFORM is matched case-insensitively here (the `switch` is by
# language rule) and the POSIX twin now normalises the value on read.  Both
# accept every case form and both refuse an unrecognised one; measured
# 2026-10-21 that only this client accepted `AUTO`/`Unix`, so the same
# instruction was a no-op on one platform and an argument error on the other.
# Driven through a stub ssh that fails like an unreachable host: every accepted
# form must get PAST the switch and reach ssh (255).
platform_stub_dir="$work/platform-ssh"
mkdir -p "$platform_stub_dir"
if [ "$client_arg" != "$client" ]; then
    platform_stub="$platform_stub_dir/ssh.cmd"
    printf '%s\r\n' '@echo off' 'exit /b 255' > "$platform_stub"
    platform_stub_arg=$(cygpath -w "$platform_stub")
else
    platform_stub="$platform_stub_dir/ssh"
    printf '#!/bin/sh\nexit 255\n' > "$platform_stub"
    chmod 700 "$platform_stub"
    platform_stub_arg="$platform_stub"
fi
for platform_case in auto unix windows AUTO Unix WINDOWS bogus; do
    cases=$((cases + 1))
    platform_status=0
    AGENTQ_REMOTE_PLATFORM="$platform_case" AGENTQ_SSH="$platform_stub_arg" \
        AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
        AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
        AGENTQ_PLATFORM_PROBE_CACHE=off \
        "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
        >"$work/out" 2>"$work/err" || platform_status=$?
    case "$platform_case" in
        bogus)
            if [ "$platform_status" -ne 2 ] || ! grep -qF 'AGENTQ_REMOTE_PLATFORM must be auto, unix, or windows' "$work/err"; then
                printf 'ps-client AGENTQ_REMOTE_PLATFORM=bogus: expected exit 2 and the controlled message, got %s\n' \
                    "$platform_status" >&2
                head -2 "$work/err" >&2 || true
                failures=$((failures + 1))
            fi
            ;;
        *)
            # NOT "must be 255": a `windows` value also runs the launcher
            # protocol probe, whose own failure code is legitimate here.  What
            # must NOT happen is the argument error -- 2 with the switch's
            # message -- which is what a case-sensitive match produced.
            if [ "$platform_status" -eq 2 ] && grep -qF 'AGENTQ_REMOTE_PLATFORM must be auto, unix, or windows' "$work/err"; then
                printf 'ps-client AGENTQ_REMOTE_PLATFORM=%s was refused as an invalid value; it is accepted case-insensitively\n' \
                    "$platform_case" >&2
                failures=$((failures + 1))
            fi
            ;;
    esac
done

# --tail's shape must be the same on both clients.  Measured 2026-10-21: the
# The MINGW arm's own status must reach the caller.  `uname -s` answers MINGW
# (so the client takes its "a Windows shell was detected" path) and every other
# call fails like a dead transport (255).  The client used to collapse that to 2
# via Stop-AgentQ, while the POSIX twin returns the probe's status unchanged --
# the same "2 means fix your arguments, 255 means retry" inversion that was
# already fixed in Confirm-WindowsAgentQProtocol, one function away.
# NOT asserting `exit 255` outright: the launcher-protocol probe runs next and
# its own code is legitimate here too.  What must NOT happen is 2.
mingw_stub_dir="$work/mingw-ssh"
mkdir -p "$mingw_stub_dir"
if [ "$client_arg" != "$client" ]; then
    mingw_stub="$mingw_stub_dir/ssh.cmd"
    # .cmd cannot inspect argv positionally without %~N, so the stub branches on
    # whether a second argument arrived: the client's `uname -s` probe passes
    # one, the PowerShell probe command passes several.
    printf '%s\r\n' '@echo off' \
        'if "%~2"=="" (' \
        '  echo MINGW64_NT-10.0' \
        '  exit /b 0' \
        ')' \
        'exit /b 255' > "$mingw_stub"
    mingw_stub_arg=$(cygpath -w "$mingw_stub")
else
    mingw_stub="$mingw_stub_dir/ssh"
    printf '#!/bin/sh\ncase "$*" in *"uname -s"*) echo MINGW64_NT-10.0; exit 0 ;; esac\nexit 255\n' > "$mingw_stub"
    chmod 700 "$mingw_stub"
    mingw_stub_arg="$mingw_stub"
fi
cases=$((cases + 1))
mingw_status=0
AGENTQ_REMOTE_PLATFORM=auto AGENTQ_SSH="$mingw_stub_arg" \
    AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    AGENTQ_PLATFORM_PROBE_CACHE=off \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
    >"$work/mingw.out" 2>"$work/mingw.err" || mingw_status=$?
if [ "$mingw_status" -eq 2 ]; then
    printf 'ps-client: a failed Windows platform probe after MINGW was detected exited 2 (the argument-error code) instead of the probe status; the POSIX twin propagates it\n' >&2
    head -3 "$work/mingw.err" >&2 || true
    failures=$((failures + 1))
fi

# POSIX client accepted `05` (forwarded it to the server, which canonicalizes
# leading zeros) while this one refused it, so the same command line meant
# different things depending on which client the caller happened to run.  Both
# now take `^[1-9][0-9]*$` or the literal `all`; the accepted forms are asserted
# too, or a validator that refused everything would pass the refusal cases.
#
# `ALL`/`All` joined on 2026-10-27, and they are the OTHER direction: `all` is a
# value forwarded verbatim, and the server compares it case-SENSITIVELY
# (`[ "$2" = all ]`), so the POSIX client refused the variant locally with exit
# 2 while this one -- whose Test-PositiveIntegerOrAll used `-eq` -- accepted it,
# paid an SSH round trip, and (on an unreachable host) reported a transport
# failure for a typo.  The option TOKENS stay case-insensitive (that is what
# `-eq` is for); this value must not be folded.  Those rows are also why the
# expected codes here are not all read off this client: `ALL:2` is the POSIX
# client's answer, and the point of the row is that the two now agree.
# A stub that fails like an unreachable host: the accepted forms must get PAST
# validation and reach ssh (255), which is what distinguishes "accepted" from
# "refused" here -- without it the accepted rows would pass on any error.  Two
# shapes for the same reason as the askpass stub below: this check runs the
# client under a native pwsh AND, under Git Bash, against the Windows-form
# path, and AGENTQ_SSH must name something that platform can execute.
tail_stub_dir="$work/tail-ssh"
mkdir -p "$tail_stub_dir"
if [ "$client_arg" != "$client" ]; then
    tail_stub_win="$tail_stub_dir/ssh.cmd"
    printf '%s\r\n' '@echo off' 'exit /b 255' > "$tail_stub_win"
    tail_stub_arg=$(cygpath -w "$tail_stub_win")
else
    tail_stub_win="$tail_stub_dir/ssh"
    printf '#!/bin/sh\nexit 255\n' > "$tail_stub_win"
    chmod 700 "$tail_stub_win"
    tail_stub_arg="$tail_stub_win"
fi
for tail_case in "05:2" "00:2" "x:2" "5:255" "all:255" "ALL:2" "All:2"; do
    tail_value=${tail_case%:*}
    tail_expected=${tail_case#*:}
    cases=$((cases + 1))
    tail_status=0
    AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
        AGENTQ_SSH="$tail_stub_arg" \
        "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" logs 1 --tail "$tail_value" \
        >"$work/out" 2>"$work/err" || tail_status=$?
    if [ "$tail_status" -ne "$tail_expected" ]; then
        printf 'ps-client logs --tail %s: expected exit %s, got %s\n' \
            "$tail_value" "$tail_expected" "$tail_status" >&2
        head -2 "$work/err" >&2 || true
        failures=$((failures + 1))
    fi
done

# --- the two clients are one contract: same argv, same answer ----------------
# The twin-client rule had been checked by hand before (a differential sweep on
# 2026-10-21 found five divergences that reading the code did not), but nothing
# in the suite RAN both clients on the same argv: each check exercised one side
# against expectations transcribed from that side.  That is exactly how the
# 2026-10-27 pair stayed invisible -- `--VERSION`/`--HELP`/`HELP`/`-H` exited 0
# here and 2 on the POSIX client, and `--tail ALL` exited 2 there and 255 here
# (accepted locally, forwarded, refused by the case-sensitive server after a
# round trip).  So: one table, both clients, exit code plus a message fragment,
# and the expected code asserted on BOTH sides -- a comparison that only asked
# "do they agree" would pass if both broke the same way.  Rows are locally
# decided (refusal, or reaching the stub ssh and failing there as 255), so no
# remote is needed and no row depends on a live server.
#
# The differential needs a host that can run BOTH clients, which a Windows host
# cannot: this client's twin is the POSIX one, a `/bin/sh` artifact that ships
# to Linux/macOS and expects jq on PATH, while Git Bash's `sh` is neither the
# platform it ships to nor a faithful `sh` for it.  Running it on the Windows CI
# job would report the harness's gaps as contract divergences.  So that host
# declares the sub-part NOT-covered with a named reason -- NOT `SKIPPED`, which
# the Windows job refuses, and NOT a silent pass, which would let a section that
# never ran read as green.
twin_platform_state='checked'
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) twin_platform_state='NOT-covered(needs-non-Windows)' ;;
esac
twin_posix="$root/skill/assets/client/unix/agentq"
twin_stub_dir="$work/twin-ssh"
mkdir -p "$twin_stub_dir"
# Each side gets the stub shape IT can execute: the POSIX client runs under
# /bin/sh and needs the shebang script at a POSIX path; the Windows client needs
# the Windows form when this check itself runs under Git Bash.  Handing one
# arg to both would make the POSIX side refuse `AGENTQ_SSH is not executable`
# on Windows and read as a contract divergence that is really the harness's.
twin_stub_posix="$twin_stub_dir/ssh"
printf '#!/bin/sh\nexit 255\n' > "$twin_stub_posix"
chmod 700 "$twin_stub_posix"
if [ "$client_arg" != "$client" ]; then
    twin_stub_win="$twin_stub_dir/ssh.cmd"
    printf '%s\r\n' '@echo off' 'exit /b 255' > "$twin_stub_win"
    twin_stub_arg=$(cygpath -w "$twin_stub_win")
else
    twin_stub_arg="$twin_stub_posix"
fi

# twin_run_pair <posix-copy> [args...] -> twin_p_status / twin_w_status
# Same environment for both, in one place: the first hand sweep of this class
# produced two false divergences because the two sides were set up separately
# (an `env VAR=` / `env VAR` mix-up, and AGENTQ_SSH left unset for one of them).
twin_run_pair() {
    local posix_copy=$1
    shift
    twin_p_status=0
    twin_w_status=0
    AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    AGENTQ_SSH="$twin_stub_posix" AGENTQ_CONFIG="$work/absent-config" \
        /bin/sh "$posix_copy" "$@" >"$work/twin-p.out" 2>"$work/twin-p.err" || twin_p_status=$?
    AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    AGENTQ_SSH="$twin_stub_arg" AGENTQ_CONFIG="$work/absent-config" \
        "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" "$@" \
        >"$work/twin-w.out" 2>"$work/twin-w.err" || twin_w_status=$?
}

twin_table='0|agentq 0.1.|--version
0|agentq 0.1.|--VERSION
0|agentq 0.1.|--Version
0|Usage:|--help
0|Usage:|--HELP
0|Usage:|HELP
0|Usage:|Help
0|Usage:|-h
0|Usage:|-H
2|--host requires an SSH host|--host
2|--host requires an SSH host|--HOST
2|unknown command: bogus|bogus
255||--HOST smoke-host status
255||status
255||STATUS
255||doctor --FULL
255||logs 1 --tail all
255||logs 1 --TAIL all
255||logs 1 --tail 5
255||remove --label smoke-x --CONFIRM
2|--tail must be a positive integer or all|logs 1 --tail ALL
2|--tail must be a positive integer or all|logs 1 --tail All
2|--tail must be a positive integer or all|logs 1 --tail 05
2|SSH host must not begin with a hyphen|--host -x status
2|SSH host must not begin with a hyphen|--host -- status
2|SSH host must not begin with a hyphen|--host -evil status'
twin_table_rows=$(grep -c . <<< "$twin_table")
twin_rows=0
# A table that lost most of its rows still agrees with a loop that runs what is
# left, so the equality gate below cannot see it -- the same shape as a shrunk
# enumeration.  The floor is a LOWER BOUND, not the count (the reported count
# stays computed): today's table has 26 rows and a rewrite that drops below 25
# is a different table, not a smaller one.
if [ "$twin_table_rows" -lt 25 ]; then
    printf 'ps-client twin: the differential table has %s row(s), below the floor of 25; it no longer covers the token surface it was built for\n' \
        "$twin_table_rows" >&2
    failures=$((failures + 1))
fi
if [ "$twin_platform_state" = checked ]; then
while IFS='|' read -r twin_expected twin_fragment twin_args; do
    [ -n "$twin_expected" ] || continue
    twin_rows=$((twin_rows + 1))
    cases=$((cases + 1))
    # read -ra, not `set --`: this runs in the script's own shell, and `set --`
    # would replace the check's positional parameters for everything after the
    # sweep.  The row IS an argv, so word splitting is the point.
    read -ra twin_argv <<< "$twin_args"
    twin_run_pair "$twin_posix" "${twin_argv[@]}"
    twin_problems=''
    [ "$twin_p_status" -eq "$twin_expected" ] || twin_problems="$twin_problems posix-exit=$twin_p_status"
    [ "$twin_w_status" -eq "$twin_expected" ] || twin_problems="$twin_problems windows-exit=$twin_w_status"
    [ "$twin_p_status" -eq "$twin_w_status" ] || twin_problems="$twin_problems clients-disagree"
    if [ -n "$twin_fragment" ]; then
        grep -qF -- "$twin_fragment" "$work/twin-p.out" "$work/twin-p.err" \
            || twin_problems="$twin_problems posix-missing-message"
        # Not `... | grep -qF`: a quiet grep exits at the first match and the
        # writer takes SIGPIPE, which pipefail turns into a FAILED pipeline --
        # the repo's own quiet-grep trap.  Redirect, then grep the file.
        { flatten_err "$work/twin-w.err"; cat "$work/twin-w.out"; } > "$work/twin-w.combined"
        grep -qF -- "$twin_fragment" "$work/twin-w.combined" \
            || twin_problems="$twin_problems windows-missing-message"
    fi
    if [ -n "$twin_problems" ]; then
        printf 'ps-client twin [%s]: expected exit %s;%s\n' "$twin_args" "$twin_expected" "$twin_problems" >&2
        head -2 "$work/twin-p.err" "$work/twin-w.err" >&2 || true
        failures=$((failures + 1))
    fi
done <<< "$twin_table"
# The table's row count is computed independently of the loop that runs it: a
# loop that silently dropped rows would otherwise report a shorter sweep as a
# complete one (the blind-enumerator class).
if [ "$twin_rows" -ne "$twin_table_rows" ]; then
    printf 'ps-client twin: ran %s of %s table row(s); a truncated sweep proves nothing\n' \
        "$twin_rows" "$twin_table_rows" >&2
    failures=$((failures + 1))
fi
# --- the host VALUE's shape: argv cannot carry a whitespace-only word ---------
# `read -ra` word-splits, so the table above can express `--host -x` but never
# `--host ' '`.  The whitespace family goes through AGENTQ_HOST instead -- which
# is also the env path where the twin resolves the value with
# IsNullOrWhiteSpace.  A whitespace-only host is a permanent argument error,
# not a transport failure: measured 2026-10-27, the POSIX client exited 255
# (the RETRYABLE class) on every one of these while the twin exited 2.
twin_host_run() {
    local posix_copy=$1 host_value=$2
    twin_p_status=0
    twin_w_status=0
    AGENTQ_HOST="$host_value" AGENTQ_REMOTE_PLATFORM=unix \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    AGENTQ_SSH="$twin_stub_posix" AGENTQ_CONFIG="$work/absent-config" \
        /bin/sh "$posix_copy" status >"$work/twin-p.out" 2>"$work/twin-p.err" || twin_p_status=$?
    AGENTQ_HOST="$host_value" AGENTQ_REMOTE_PLATFORM=unix \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    AGENTQ_SSH="$twin_stub_arg" AGENTQ_CONFIG="$work/absent-config" \
        "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
        >"$work/twin-w.out" 2>"$work/twin-w.err" || twin_w_status=$?
}
twin_host_rows=0
# twin_host_case <label> <host-value>
twin_host_case() {
    local label=$1 host_value=$2 problems=''
    twin_host_rows=$((twin_host_rows + 1))
    cases=$((cases + 1))
    twin_host_run "$twin_posix" "$host_value"
    [ "$twin_p_status" -eq 2 ] || problems="$problems posix-exit=$twin_p_status"
    [ "$twin_w_status" -eq 2 ] || problems="$problems windows-exit=$twin_w_status"
    grep -qF 'no SSH host configured' "$work/twin-p.err" \
        || problems="$problems posix-missing-message"
    { flatten_err "$work/twin-w.err"; cat "$work/twin-w.out"; } > "$work/twin-w.combined"
    grep -qF 'no SSH host configured' "$work/twin-w.combined" \
        || problems="$problems windows-missing-message"
    if [ -n "$problems" ]; then
        printf 'ps-client twin host-value [%s]:%s\n' "$label" "$problems" >&2
        head -2 "$work/twin-p.err" "$work/twin-w.err" >&2 || true
        failures=$((failures + 1))
    fi
}
twin_host_case space ' '
twin_host_case tab $'\t'
twin_host_case carriage-return $'\r'
twin_host_case space-newline $' \n'
twin_host_case vertical-tab $'\v'
# A block that stopped enumerating reports green on nothing (the
# blind-enumerator class), so the executed count has its own floor.
if [ "$twin_host_rows" -lt 5 ]; then
    printf 'ps-client twin host-value: only %s case(s) ran (expected 5); the enumeration broke\n' \
        "$twin_host_rows" >&2
    failures=$((failures + 1))
fi
# The sharpest face of this defect is not the exit code.  With a config file
# naming one host while AGENTQ_HOST holds only whitespace, the twin resolves
# with IsNullOrWhiteSpace and uses the CONFIGURED host; `:-` substitutes only
# for EMPTY, so the POSIX client ssh'd to " ".  Same environment, two different
# machines -- measured 2026-10-27.  Capture the host each side actually hands
# ssh and require the configured one on both.
twin_capture_stub="$twin_stub_dir/ssh-capture"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "${TWIN_ARGV_LOG:?}"\nexit 255\n' > "$twin_capture_stub"
chmod 700 "$twin_capture_stub"
printf 'AGENTQ_HOST=cfg-host\n' > "$work/twin-config"
chmod 600 "$work/twin-config"
twin_capture_host() {
    # <posix|windows> <argv-log>
    local side=$1 log=$2
    if [ "$side" = posix ]; then
        TWIN_ARGV_LOG="$log" AGENTQ_HOST=' ' AGENTQ_REMOTE_PLATFORM=unix \
        AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
        AGENTQ_SSH="$twin_capture_stub" AGENTQ_CONFIG="$work/twin-config" \
            /bin/sh "$twin_posix" status >/dev/null 2>&1 || true
    else
        TWIN_ARGV_LOG="$log" AGENTQ_HOST=' ' AGENTQ_REMOTE_PLATFORM=unix \
        AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
        AGENTQ_SSH="$twin_capture_stub" AGENTQ_CONFIG="$work/twin-config" \
            "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
            >/dev/null 2>&1 || true
    fi
}
cases=$((cases + 1))
twin_capture_host posix "$work/twin-cfg-p.argv"
twin_capture_host windows "$work/twin-cfg-w.argv"
twin_cfg_p=$(awk 'p{print; exit} $0=="--"{p=1}' "$work/twin-cfg-p.argv" 2>/dev/null || true)
twin_cfg_w=$(awk 'p{print; exit} $0=="--"{p=1}' "$work/twin-cfg-w.argv" 2>/dev/null || true)
if [ "$twin_cfg_p" != cfg-host ] || [ "$twin_cfg_w" != cfg-host ]; then
    printf 'ps-client twin host-value [config fallback]: AGENTQ_HOST was whitespace-only and the config names cfg-host, but ssh was sent to posix=[%s] windows=[%s] (both must be cfg-host)\n' \
        "$twin_cfg_p" "$twin_cfg_w" >&2
    failures=$((failures + 1))
fi
# --- an executable path must be a REGULAR file -------------------------------
# `[ -x ]` tests the search bit, which every directory has, so a directory
# passed the POSIX client's AGENTQ_SSH guard and the failure came back as exit
# 126 -- a code outside the documented contract (0-6 / 42-45 / 124) with no
# diagnostic -- while the twin refused the same input with exit 2.  Measured
# 2026-10-27.  The messages differ by platform ("regular file" vs "regular
# non-reparse file"), so this row asserts the exit code, which is the contract.
twin_exec_rows=0
mkdir -p "$work/twin-exec-dir"
twin_exec_run() { # <posix-copy> <path>
    local posix_copy=$1 value=$2
    twin_p_status=0
    twin_w_status=0
    AGENTQ_HOST=smoke-host AGENTQ_SSH="$value" AGENTQ_REMOTE_PLATFORM=unix \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    AGENTQ_CONFIG="$work/absent-config" \
        /bin/sh "$posix_copy" status >"$work/twin-p.out" 2>"$work/twin-p.err" || twin_p_status=$?
    AGENTQ_HOST=smoke-host AGENTQ_SSH="$value" AGENTQ_REMOTE_PLATFORM=unix \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    AGENTQ_CONFIG="$work/absent-config" \
        "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
        >"$work/twin-w.out" 2>"$work/twin-w.err" || twin_w_status=$?
}
twin_exec_case() { # <label> <path>
    local label=$1 value=$2 problems=''
    twin_exec_rows=$((twin_exec_rows + 1)); cases=$((cases + 1))
    twin_exec_run "$twin_posix" "$value"
    [ "$twin_p_status" -eq 2 ] || problems="$problems posix-exit=$twin_p_status"
    [ "$twin_w_status" -eq 2 ] || problems="$problems windows-exit=$twin_w_status"
    if [ -n "$problems" ]; then
        printf 'ps-client twin executable [%s]:%s\n' "$label" "$problems" >&2
        head -1 "$work/twin-p.err" "$work/twin-w.err" >&2 || true
        failures=$((failures + 1))
    fi
}
twin_exec_case 'AGENTQ_SSH=directory' "$work/twin-exec-dir"
if [ "$twin_exec_rows" -lt 1 ]; then
    printf 'ps-client twin executable: %s case(s) ran (expected 1); the enumeration broke\n' \
        "$twin_exec_rows" >&2
    failures=$((failures + 1))
fi
# --- the config FILE's value grammar ----------------------------------------
# Both clients read `AGENTQ_HOST=<value>` from the config and both take the
# LAST matching line, so the regex quantifier decides what a trailing
# `AGENTQ_HOST=` means.  The POSIX parser accepts an empty value (`*`); this
# twin's required at least one character (`+`), so the blank line did not
# match, the earlier value survived, and the SAME config resolved to different
# hosts -- measured 2026-10-27: `AGENTQ_HOST=first-host` followed by
# `AGENTQ_HOST=` made the POSIX client refuse with exit 2 ("no SSH host
# configured") while this one connected to first-host.  Blanking a line is how
# a user unsets a host; the fail-closed answer is the POSIX one, and the twin
# rule is that the same input gets the same answer.
#
# The rows that reach ssh also assert WHICH host arrived: an exit code alone
# cannot tell `alpha` from `beta`.
twin_config_rows=0
twin_config_run() { # <posix-copy> <windows-copy> <config-path>
    local posix_copy=$1 windows_copy=$2 config=$3
    twin_p_status=0
    twin_w_status=0
    : > "$work/twin-cfg-p.argv"
    : > "$work/twin-cfg-w.argv"
    TWIN_ARGV_LOG="$work/twin-cfg-p.argv" env -u AGENTQ_HOST \
    AGENTQ_REMOTE_PLATFORM=unix AGENTQ_OPERATION_RETRY_ATTEMPTS=1 \
    AGENTQ_OPERATION_RETRY_DELAY=1 AGENTQ_SSH="$twin_capture_stub" \
    AGENTQ_CONFIG="$config" \
        /bin/sh "$posix_copy" status >"$work/twin-p.out" 2>"$work/twin-p.err" || twin_p_status=$?
    TWIN_ARGV_LOG="$work/twin-cfg-w.argv" env -u AGENTQ_HOST \
    AGENTQ_REMOTE_PLATFORM=unix AGENTQ_OPERATION_RETRY_ATTEMPTS=1 \
    AGENTQ_OPERATION_RETRY_DELAY=1 AGENTQ_SSH="$twin_capture_stub" \
    AGENTQ_CONFIG="$config" \
        "$pwsh_binary" -NoProfile -NonInteractive -File "$windows_copy" status \
        >"$work/twin-w.out" 2>"$work/twin-w.err" || twin_w_status=$?
    twin_cfg_p_host=$(awk 'p{print; exit} $0=="--"{p=1}' "$work/twin-cfg-p.argv" 2>/dev/null || true)
    twin_cfg_w_host=$(awk 'p{print; exit} $0=="--"{p=1}' "$work/twin-cfg-w.argv" 2>/dev/null || true)
}
# twin_config_case <label> <expected-exit> <expected-host|-> <content>
twin_config_case() { # <windows-copy> <label> <expected-exit> <expected-host> <content>
    local windows_copy=$1 label=$2 want=$3 want_host=$4 content=$5 problems=''
    twin_config_rows=$((twin_config_rows + 1)); cases=$((cases + 1))
    printf '%s' "$content" > "$work/twin-config-$label"
    chmod 600 "$work/twin-config-$label"
    twin_config_run "$twin_posix" "$windows_copy" "$work/twin-config-$label"
    [ "$twin_p_status" -eq "$want" ] || problems="$problems posix-exit=$twin_p_status"
    [ "$twin_w_status" -eq "$want" ] || problems="$problems windows-exit=$twin_w_status"
    if [ "$want" -eq 255 ]; then
        [ "$twin_cfg_p_host" = "$want_host" ] || problems="$problems posix-host=[$twin_cfg_p_host]"
        [ "$twin_cfg_w_host" = "$want_host" ] || problems="$problems windows-host=[$twin_cfg_w_host]"
    fi
    if [ -n "$problems" ]; then
        printf 'ps-client twin config [%s]: expected exit %s host %s;%s\n' \
            "$label" "$want" "$want_host" "$problems" >&2
        head -1 "$work/twin-p.err" "$work/twin-w.err" >&2 || true
        failures=$((failures + 1))
    fi
}
twin_config_case "$client_arg" empty-last    2   -      'AGENTQ_HOST=first-host
AGENTQ_HOST=
'
twin_config_case "$client_arg" empty-only    2   -      'AGENTQ_HOST=
'
twin_config_case "$client_arg" two-values    255 beta   'AGENTQ_HOST=alpha
AGENTQ_HOST=beta
'
twin_config_case "$client_arg" space-value   2   -      'AGENTQ_HOST=
'
twin_config_case "$client_arg" blank-middle  255 beta   'AGENTQ_HOST=alpha
AGENTQ_HOST=
AGENTQ_HOST=beta
'
if [ "$twin_config_rows" -lt 5 ]; then
    printf 'ps-client twin config: only %s row(s) ran (expected 5); the enumeration broke\n' \
        "$twin_config_rows" >&2
    failures=$((failures + 1))
fi
# --- which STREAM a diagnostic belongs on -----------------------------------
# stdout is the DATA channel and stderr the DIAGNOSTIC one -- SKILL.md's whole
# redaction policy is built on that split, and the POSIX clients honour it:
# usage goes to stdout for --help and to stderr (`usage >&2`) for a bad
# invocation.  BOTH Windows clients printed the banner on STDOUT on the ERROR
# path and left stderr EMPTY -- measured 2026-10-28: agentq.ps1 with no
# arguments gave stdout 2673 B / stderr 0 B where the POSIX client gave
# stdout 0 B / stderr 2596 B; sshp.ps1 no-args gave 305 B / 0 B against
# 0 B / 379 B.  A caller doing `out=$(client ...)` captured the banner as data
# and saw nothing on stderr.
#
# The twin differential ABOVE cannot see this: its fragment check reads stdout
# and stderr together, so a message on the wrong stream still matches.  These
# rows therefore assert the stream, and the sshp side is exercised here because
# no other check ever ran both sshp implementations on the same argv.
stream_rows=0
stream_home="$work/stream-home"
stream_tmp="$work/stream-tmp"
mkdir -p "$stream_home" "$stream_tmp"
# stream_case <posix-client> <ps-client> <expected-exit> <out|err> <fragment> [args...]
# `where` is the stream the usage/fragment MUST land on; the other stream must
# be EMPTY (that is the assertion the merged fragment check cannot make).
stream_case() {
    local posix_client=$1 ps_client=$2 want=$3 where=$4 fragment=$5
    shift 5
    # Name the client in the label: `<no args>` alone does not say WHICH pair
    # failed, and this block covers two.
    local label
    label=$(basename "$ps_client")${*:+ $*}
    [ "$*" = "$label" ] || label="$label"
    problems=''
    stream_rows=$((stream_rows + 1)); cases=$((cases + 1))
    local p=0 w=0
    AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
    AGENTQ_REMOTE_PLATFORM=unix AGENTQ_SSH="$twin_stub_posix" \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    SSHP_SSH="$twin_stub_posix" HOME="$stream_home" TMPDIR="$stream_tmp" \
        /bin/sh "$posix_client" "$@" >"$work/stream-p.out" 2>"$work/stream-p.err" || p=$?
    AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
    AGENTQ_REMOTE_PLATFORM=unix AGENTQ_SSH="$twin_stub_arg" \
    AGENTQ_OPERATION_RETRY_ATTEMPTS=1 AGENTQ_OPERATION_RETRY_DELAY=1 \
    SSHP_SSH="$twin_stub_arg" HOME="$stream_home" TMPDIR="$stream_tmp" \
        "$pwsh_binary" -NoProfile -NonInteractive -File "$ps_client" "$@" \
        >"$work/stream-w.out" 2>"$work/stream-w.err" || w=$?
    [ "$p" -eq "$want" ] || problems="$problems posix-exit=$p"
    [ "$w" -eq "$want" ] || problems="$problems windows-exit=$w"
    if [ "$where" = err ]; then
        [ -s "$work/stream-p.out" ] && problems="$problems posix-stdout-not-empty($(wc -c <"$work/stream-p.out" | tr -d ' ')B)"
        [ -s "$work/stream-w.out" ] && problems="$problems windows-stdout-not-empty($(wc -c <"$work/stream-w.out" | tr -d ' ')B)"
        grep -qF -- "$fragment" "$work/stream-p.err" || problems="$problems posix-missing-on-stderr"
        { flatten_err "$work/stream-w.err"; cat "$work/stream-w.out"; } > "$work/stream-w.combined"
        grep -qF -- "$fragment" "$work/stream-w.combined" || problems="$problems windows-missing-message"
        grep -qF -- "$fragment" "$work/stream-w.err" || problems="$problems windows-missing-on-stderr"
    else
        [ -s "$work/stream-p.err" ] && problems="$problems posix-stderr-not-empty($(wc -c <"$work/stream-p.err" | tr -d ' ')B)"
        [ -s "$work/stream-w.err" ] && problems="$problems windows-stderr-not-empty($(wc -c <"$work/stream-w.err" | tr -d ' ')B)"
        grep -qF -- "$fragment" "$work/stream-p.out" || problems="$problems posix-missing-on-stdout"
        grep -qF -- "$fragment" "$work/stream-w.out" || problems="$problems windows-missing-on-stdout"
    fi
    if [ -n "$problems" ]; then
        printf 'ps-client stream [%s] (%s):%s\n' "$label" "$where" "$problems" >&2
        failures=$((failures + 1))
    fi
}
# Override hooks, same pattern as AGENTQ_SMOKE_CLIENT / AGENTQ_SMOKE_PS_CLIENT:
# a mutation proof points these at modified copies instead of swapping the real
# asset under a running check.
sshp_posix_client=${AGENTQ_SMOKE_SSHP_CLIENT:-$root/skill/assets/client/unix/sshp}
sshp_ps_client=${AGENTQ_SMOKE_SSHP_PS_CLIENT:-$root/skill/assets/client/windows/sshp.ps1}
if [ -n "${AGENTQ_SMOKE_PWSH:-}" ] && command -v cygpath >/dev/null 2>&1; then
    sshp_ps_client_arg=$(cygpath -w "$sshp_ps_client")
else
    sshp_ps_client_arg=$sshp_ps_client
fi
# agentq: no command is an argument error; --help is a success path.
stream_case "$twin_posix" "$client_arg" 2 err 'Usage:'
stream_case "$twin_posix" "$client_arg" 0 out 'Usage:' --help
# sshp: the same split, plus the two session-name reasons the POSIX client used
# to report with one (wrong) message.
stream_case "$sshp_posix_client" "$sshp_ps_client_arg" 2 err 'Usage:'
stream_case "$sshp_posix_client" "$sshp_ps_client_arg" 2 err 'Usage:' h s x
stream_case "$sshp_posix_client" "$sshp_ps_client_arg" 2 err 'Usage:' --check
stream_case "$sshp_posix_client" "$sshp_ps_client_arg" 0 out 'Usage:' -h
stream_case "$sshp_posix_client" "$sshp_ps_client_arg" 2 err 'session name must not begin with a hyphen' h -s
stream_case "$sshp_posix_client" "$sshp_ps_client_arg" 2 err 'session name must contain only' h a:b
stream_case "$sshp_posix_client" "$sshp_ps_client_arg" 2 err 'begin with a hyphen' -x
if [ "$stream_rows" -lt 9 ]; then
    printf 'ps-client stream: only %s row(s) ran (expected 9); the enumeration broke\n' \
        "$stream_rows" >&2
    failures=$((failures + 1))
fi
# And the comparator must be provably able to go RED, or the section is a
# rubber stamp.  Revert the POSIX client's global-token fold in a copy and
# require the same row to disagree; if the fold line cannot be found the
# mutation never happened, and saying so beats passing on nothing.
twin_mutant="$work/twin-posix-unfolded"
sed 's/^    global_option=.*/    global_option=$1/' "$twin_posix" > "$twin_mutant"
if cmp -s "$twin_posix" "$twin_mutant"; then
    printf '%s\n' 'ps-client twin self-test: the POSIX global-token fold line was not found; the comparator cannot be proven able to fail' >&2
    failures=$((failures + 1))
else
    twin_run_pair "$twin_mutant" --VERSION
    if [ "$twin_p_status" -eq "$twin_w_status" ]; then
        printf 'ps-client twin self-test: an unfolded --VERSION still agreed with the Windows twin (posix=%s windows=%s)\n' \
            "$twin_p_status" "$twin_w_status" >&2
        failures=$((failures + 1))
    fi
fi
# The host guard is two separate rules, so a mutation of one says nothing about
# the other: revert each in its own copy and require the corresponding row to
# disagree.  If the guard line cannot be found the mutation never happened, and
# saying so beats passing on nothing (same rule as the fold self-test above).
twin_host_mutant_hyphen="$work/twin-posix-nohyphen"
sed "s/^    -\*) fail 'SSH host must not begin with a hyphen' ;;/    __twin_nomatch__) fail 'SSH host must not begin with a hyphen' ;;/" \
    "$twin_posix" > "$twin_host_mutant_hyphen"
if cmp -s "$twin_posix" "$twin_host_mutant_hyphen"; then
    printf '%s\n' 'ps-client twin self-test: the POSIX hyphen-host guard was not found; the host rows cannot be proven able to fail' >&2
    failures=$((failures + 1))
else
    twin_run_pair "$twin_host_mutant_hyphen" --host -x status
    if [ "$twin_p_status" -eq "$twin_w_status" ]; then
        printf 'ps-client twin self-test: a POSIX client without the hyphen guard still agreed with the twin on --host -x (posix=%s windows=%s)\n' \
            "$twin_p_status" "$twin_w_status" >&2
        failures=$((failures + 1))
    fi
fi
twin_host_mutant_blank="$work/twin-posix-noblank"
sed "s/^    \*) fail 'no SSH host configured; pass --host or set AGENTQ_HOST' ;;/    *) : ;;/" \
    "$twin_posix" > "$twin_host_mutant_blank"
if cmp -s "$twin_posix" "$twin_host_mutant_blank"; then
    printf '%s\n' 'ps-client twin self-test: the POSIX blank-host guard was not found; the host rows cannot be proven able to fail' >&2
    failures=$((failures + 1))
else
    twin_host_run "$twin_host_mutant_blank" ' '
    if [ "$twin_p_status" -eq "$twin_w_status" ]; then
        printf 'ps-client twin self-test: a POSIX client without the blank guard still agreed with the twin on a whitespace host (posix=%s windows=%s)\n' \
            "$twin_p_status" "$twin_w_status" >&2
        failures=$((failures + 1))
    fi
fi
# Same for the regular-file guard this round added: widen `! -f` to `! -e` in a
# copy (a directory IS `-e`) and require the executable row to disagree.
twin_exec_mutant="$work/twin-posix-noregular"
sed 's/\[ ! -f "\$ssh_binary" \]/[ ! -e "$ssh_binary" ]/' \
    "$twin_posix" > "$twin_exec_mutant"
if cmp -s "$twin_posix" "$twin_exec_mutant"; then
    printf '%s\n' 'ps-client twin self-test: the POSIX regular-file guard was not found; the executable row cannot be proven able to fail' >&2
    failures=$((failures + 1))
else
    twin_exec_run "$twin_exec_mutant" "$work/twin-exec-dir"
    if [ "$twin_p_status" -eq "$twin_w_status" ]; then
        printf 'ps-client twin self-test: a POSIX client without the regular-file guard still agreed with the twin on a directory (posix=%s windows=%s)\n' \
            "$twin_p_status" "$twin_w_status" >&2
        failures=$((failures + 1))
    fi
fi
# Same for the config grammar this round aligned: put the `+` back in a copy of
# the WINDOWS client and require the empty-last row to disagree.  The sed anchor
# is the quantifier itself; if it cannot be found the mutation never happened,
# and saying so beats passing on nothing.
twin_config_mutant="$work/twin-windows-plus"
sed "s/AGENTQ_HOST=(\[^\\\\s\]\*)/AGENTQ_HOST=([^\\\\s]+)/" \
    "$client" > "$twin_config_mutant"
if cmp -s "$client" "$twin_config_mutant"; then
    printf '%s\n' 'ps-client twin self-test: the Windows config-value quantifier was not found; the config rows cannot be proven able to fail' >&2
    failures=$((failures + 1))
else
    twin_config_run "$twin_posix" "$twin_config_mutant" "$work/twin-config-empty-last"
    if [ "$twin_p_status" -eq "$twin_w_status" ]; then
        printf 'ps-client twin self-test: a Windows client with the old `+` quantifier still agreed with the POSIX side on a trailing blank host line (posix=%s windows=%s)\n' \
            "$twin_p_status" "$twin_w_status" >&2
        failures=$((failures + 1))
    fi
fi
twin_state="checked($twin_rows/$twin_table_rows)+host($twin_host_rows/5)+exec($twin_exec_rows/1)+config($twin_config_rows/5)+stream($stream_rows/9)"
else
twin_state=$twin_platform_state
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
# Hermetic state, set AFTER sourcing: without this the probe inherits whatever
# the real user config and environment left behind.  Two independent vacuity
# bugs lived here until 2026-10-16: (a) `$script:TargetHost` came from the real
# ~/.config/agentq (or was empty, e.g. on CI), and the host assertion below was
# `$text -notmatch [regex]::Escape("")`, which is ALWAYS false -- an empty
# pattern matches everything, so "the hint names the host" was never actually
# checked; (b) `$script:CredentialSource` came from the ambient
# AGENTQ_ASKPASS/AGENTQ_PASSWORD, which picks the OTHER hint branch (the one
# without the BatchMode sentence) and would fail the $has assertion on a
# developer machine that exports one.  Both are pinned to literals now, and the
# caller also passes AGENTQ_CONFIG pointing at a file that does not exist.
$script:TargetHost = "authhint-target"
$script:CredentialSource = ""
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
    # install.  An empty pattern would make this pass unconditionally, so the
    # host is asserted to be the literal set above, not merely "some string".
    if ($case.want -and $text -notmatch [regex]::Escape($script:TargetHost)) {
        [Console]::Error.WriteLine("auth hint case $($case.n): hint does not name the target host")
        $bad += 1
    }
}
if ($bad -ne 0) { exit 1 }
"auth hint cases ok: $($cases.Count)"
'
cases=$((cases + 1))
status=0
env -u AGENTQ_ASKPASS -u AGENTQ_PASSWORD -u AGENTQ_PASSWORD_PROMPT \
    AGENTQ_CONFIG="$work/absent-config" \
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
# The property, restated for the fixed rewrite (2026-10-06): every `exit N`
# must have the token write for the SAME code BEFORE it, so no failure path can
# terminate without emitting its code -- the first fix rewrote exits to
# assignments, which do not terminate, and the branches fell through to the
# ready marker.  Counting assignments is no longer the right assertion.
$exitSites = [regex]::Matches($rewritten, "(?m)(?:^[ \t]*|;[ \t]*)exit ([0-9]+)")
$bad = 0
foreach ($m in $exitSites) {
    $code = $m.Groups[1].Value
    $before = $rewritten.Substring(0, $m.Index)
    # Exit sites write the token as a concatenation (`agentq-exit:" + N`); the
    # success trailer writes it literally (`agentq-exit:0`).  Accept both forms.
    $byConcat = [regex]::Escape("agentq-exit:`" + " + $code)
    $byLiteral = [regex]::Escape("agentq-exit:" + $code)
    if (($before -notmatch $byConcat) -and ($before -notmatch $byLiteral)) { $bad++ }
}
if ($bad -ne 0) {
    [Console]::Error.WriteLine("probe exit rewrite left $bad exit statement(s) without a token write for the same code")
    exit 1
}
$writes = ([regex]::Matches($rewritten, "agentq-exit:`" \+ (42|43|44|45)")).Count
if ($writes -ne 4) {
    [Console]::Error.WriteLine("probe exit rewrite produced $writes exit-site token write(s), expected 4")
    exit 1
}
if ($exitSites.Count -ne 5) {
    [Console]::Error.WriteLine("probe exit rewrite left $($exitSites.Count) exit statement(s), expected 5 (4 sites + the success trailer)")
    exit 1
}
"exit-token rewrite ok: sites=$writes trailer=1"
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

# --- the askpass environment must force ssh to use the program ----------------
# ssh runs SSH_ASKPASS only when it has no terminal AND is allowed to reach for
# it.  On POSIX the trigger is SSH_ASKPASS_REQUIRE=force; on Windows there is no
# DISPLAY at all, so WITHOUT that variable the program is never invoked and ssh
# falls back to readpassphrase(), which reads the CONSOLE via _getwch() -- with
# no console it blocks forever instead of failing.  The client sets SSH_ASKPASS
# but an earlier revision did NOT set SSH_ASKPASS_REQUIRE, on the false premise
# (stated in its own header comment) that "Windows ssh has no equivalent of
# OpenSSH's SSH_ASKPASS_REQUIRE".  Measured on the real Windows test host
# (OpenSSH_for_Windows_9.5p1, PATH default; ProcessStartInfo with redirected
# streams, exactly how the client starts ssh): with the variable unset the call
# BLOCKS and the askpass program is never called; with `force` it returns rc=0
# and the program is called once.  (The native System32 8.1p1 build predates the
# variable and blocks either way -- but that is not the build this client
# resolves by default, and it is out of scope here.)
#
# Both directions are asserted: the variable must be set to `force` when a
# credential source is configured, and must be ABSENT otherwise (an exported
# force with no program is the inverse defect, and would make ssh try to exec
# an empty askpass).
askpass_env_probe='
. "'"$client_arg"'" 2>$null
$bad = 0
# EnvironmentVariables is a plain dictionary that THROWS on a missing key, so
# every read goes through this helper rather than indexing directly.
function Get-EnvValue($si, $name) {
    if ($si.EnvironmentVariables.ContainsKey($name)) { return $si.EnvironmentVariables[$name] }
    return $null
}
$script:CredentialSource = "askpass"
$script:AskPassProgram = "helper.exe"
$si = New-SshProcessStartInfo -Arguments @("-o","BatchMode=no","--","smoke-host","cmd")
$askpass = Get-EnvValue $si "SSH_ASKPASS"
$require = Get-EnvValue $si "SSH_ASKPASS_REQUIRE"
if ($askpass -ne "helper.exe") {
    [Console]::Error.WriteLine("askpass-env: SSH_ASKPASS not set on the ssh process: [$askpass]")
    $bad += 1
}
if ($require -ne "force") {
    [Console]::Error.WriteLine("askpass-env: SSH_ASKPASS_REQUIRE must be force, got: [$require]")
    $bad += 1
}
# No source -> neither variable may be present.
$script:CredentialSource = ""
$si = New-SshProcessStartInfo -Arguments @("-o","BatchMode=yes","--","smoke-host","cmd")
if (![string]::IsNullOrEmpty((Get-EnvValue $si "SSH_ASKPASS"))) {
    [Console]::Error.WriteLine("askpass-env: SSH_ASKPASS leaked without a credential source")
    $bad += 1
}
if (![string]::IsNullOrEmpty((Get-EnvValue $si "SSH_ASKPASS_REQUIRE"))) {
    [Console]::Error.WriteLine("askpass-env: SSH_ASKPASS_REQUIRE leaked without a credential source")
    $bad += 1
}
if ($bad -ne 0) { exit 1 }
"askpass env cases ok"
'
cases=$((cases + 1))
status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command "$askpass_env_probe" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] || ! grep -qF 'askpass env cases ok' "$work/out"; then
    printf '%s\n' 'ps-client: the askpass environment does not force ssh to use the program' >&2
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
#
# `status=0` before the call: without the reset the check below reads whatever
# the PREVIOUS case left behind when this command exits 0 (the `|| status=$?`
# only fires on failure), so a vanished refusal could pass on a stale 2.  This
# was the one pwsh case in the file without the reset (2026-10-16).
status=0
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

# Two credential sources set at once must be refused, not silently resolved in
# one direction.  Measured 2026-10-21: with AGENTQ_ASKPASS and
# AGENTQ_PASSWORD_PROMPT both set, the POSIX twin exited 2 with "set only one"
# while this client accepted the pair and used askpass -- so the same
# environment meant "ambiguous, fix it" on one platform and "fine" on the other.
# The refusal carries a second, Windows-specific reason: PASSWORD_PROMPT is not
# supported here at all, so whoever set it expected it to be used.
#
# Both orders of the pair are NOT asserted separately: the check is on the
# presence of both, so one case pins the rule.  The ASKPASS+AGENTQ_PASSWORD
# pair has its own case above.
#
# The askpass value must be a file that EXISTS: the file-shape guard runs before
# the ambiguity guard, so a nonexistent path would be refused for being absent
# first and this case would pass without ever reaching the rule it names.
# Measured 2026-10-21: with $work/absent-askpass, stderr is
# "AGENTQ_ASKPASS is not a regular non-reparse file" -- exit 2, wrong reason.
# The file is never executed: the ambiguity guard fires before any ssh call.
ambiguous_askpass="$work/ambiguous-askpass"
printf '#!/bin/sh\nexit 1\n' > "$ambiguous_askpass"
chmod 755 "$ambiguous_askpass"
status=0
AGENTQ_ASKPASS="$ambiguous_askpass" AGENTQ_PASSWORD_PROMPT=1 \
    AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
    >"$work/out" 2>"$work/err" || status=$?
cases=$((cases + 1))
if [ "${status:-0}" -ne 2 ]; then
    printf 'ps-client: AGENTQ_ASKPASS and AGENTQ_PASSWORD_PROMPT were both set without a refusal (expected exit 2, got %s)\n' "${status:-0}" >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
elif ! grep -qF 'AGENTQ_ASKPASS and AGENTQ_PASSWORD_PROMPT are both set' "$work/err"; then
    printf '%s\n' 'ps-client: both credential sources were set and the refusal did not name the ambiguity' >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

# A nonexistent AGENTQ_ASKPASS is refused on its own; the pair case just above
# must not be confused with it.
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
# client is pointed at a stub ssh that records its invocation and exits 255
# (transport failure): reaching the stub at all PROVES the credential guard let
# the value through.  The assertion is positive -- the stub must have been
# CALLED -- not merely that two refusal messages are absent: until 2026-10-16
# this case only checked stderr for the refusals, so a client that died before
# the guard (e.g. an unresolvable cache directory, or a probe failure that
# exits 2 with a different message) passed green while exercising nothing.
# The recorded call count and the forced `AGENTQ_REMOTE_PLATFORM=unix` are what
# turn "no refusal text" into "the guard was really consulted and passed".
#
# Two well-formed shapes, and the second one is the reason this matters: a path
# containing a SPACE is legal, because ssh executes the whole value as a single
# file name and never splits it.  "C:\Program Files\..." is the everyday case.
# An earlier revision rejected any value containing a space, which refused such
# paths outright -- so both are asserted.
askpass_ssh_dir="$work/askpass-ssh"
mkdir -p "$askpass_ssh_dir"
if [ "$client_arg" != "$client" ]; then
    askpass_ssh_stub="$askpass_ssh_dir/ssh.cmd"
    printf '%s\r\n' \
        '@echo off' \
        'echo called>>"%AQ_SSH_CALLS%"' \
        'exit /b 255' > "$askpass_ssh_stub"
    askpass_ssh_arg=$(cygpath -w "$askpass_ssh_stub")
    askpass_calls_arg=$(cygpath -w "$work/askpass-ssh.calls")
else
    askpass_ssh_stub="$askpass_ssh_dir/ssh"
    cat > "$askpass_ssh_stub" <<'STUB'
#!/bin/sh
cat > /dev/null 2>&1 || true
printf 'called\n' >> "$AQ_SSH_CALLS"
exit 255
STUB
    chmod 700 "$askpass_ssh_stub"
    askpass_ssh_arg="$askpass_ssh_stub"
    askpass_calls_arg="$work/askpass-ssh.calls"
fi
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
    : > "$askpass_calls_arg"
    AGENTQ_SSH="$askpass_ssh_arg" AGENTQ_REMOTE_PLATFORM=unix \
        AQ_SSH_CALLS="$askpass_calls_arg" \
        AGENTQ_ASKPASS="$real_askpass" AGENTQ_HOST=smoke-host AGENTQ_CONFIG="$work/absent-config" \
        "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
        >"$work/out" 2>"$work/err" || status=$?
    if grep -qF 'must be a single executable path' "$work/err" ||
       grep -qF 'is not a regular non-reparse file' "$work/err"; then
        printf 'ps-client: a well-formed AGENTQ_ASKPASS (%s) was refused by the credential guard\n' "$shape" >&2
        head -3 "$work/err" >&2 || true
        failures=$((failures + 1))
    elif [ ! -s "$askpass_calls_arg" ]; then
        printf 'ps-client: a well-formed AGENTQ_ASKPASS (%s) never reached ssh -- the client stopped before or at the credential guard (exit %s)\n' \
            "$shape" "${status:-0}" >&2
        head -3 "$work/err" >&2 || true
        failures=$((failures + 1))
    fi
    status=0
done

# --- the launcher wrapper must emit the out-of-band exit token ---------------
# Same defect class as the probe token above, on the OPERATION path.  When
# sshd's DefaultShell is powershell.exe the outer PowerShell flattens the exit
# code of the native launcher child to 1, so the wrapper prints the real code on
# stderr as `agentq-exit:<code>` and Invoke-SshLogged reads that back.  If the
# wrapper stops emitting the FINAL token (the one carrying the launcher's real
# code), every nonzero protocol code degrades to 1 on such a target and the
# recovery logic breaks.
#
# Asserted by building the wrapper and checking the emission is present and
# carries the launcher's code -- not a substring test, because the wrapper also
# emits a token in its too-large and null-exit branches, so a substring test
# would stay green if only the final one were dropped.  (Measured: that is
# exactly how a first version of the smoke/05 lock missed its mutation.)
wrapper_probe='
. "'"$client_arg"'" 2>$null
$invocation = New-WindowsRemoteInvocation -Arguments @("status")
$encoded = ($invocation.Command -replace "^.*-EncodedCommand ", "")
$wrapper = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
$tokenLiteral = "agentq-exit:" + [char]36 + "agentqLauncherExit"
$exitLiteral = "exit " + [char]36 + "agentqLauncherExit"
if (!$wrapper.Contains($tokenLiteral)) {
    [Console]::Error.WriteLine("launcher wrapper does not emit the final agentq-exit token")
    exit 1
}
if (!$wrapper.Contains($exitLiteral)) {
    [Console]::Error.WriteLine("launcher wrapper does not exit with the launcher code")
    exit 1
}
"launcher exit token ok"
'
cases=$((cases + 1))
status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command "$wrapper_probe" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] || ! grep -qF 'launcher exit token ok' "$work/out"; then
    printf '%s\n' 'ps-client: the launcher wrapper does not emit its out-of-band exit token' >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

# --- the exit token reader must take the LAST token, not the first -----------
# The wrapper writes its authoritative token AFTER the launcher's own stderr, so
# the last one is the real code -- and the text is remote-controlled: a target
# that emits `agentq-exit:0` before its real token would make a first-match
# reader report SUCCESS where the operation failed, silently skipping the 3/4/5/6
# reconcile.  The POSIX client has always taken the last match; this pins the
# PowerShell copy to agree.  Behavioral on purpose -- a source-level assertion
# would have to re-implement the regex and could not see the count-1 index.
#
# A stub ssh on AGENTQ_SSH emits two tokens (0 then 3) and exits 1.  The real
# Invoke-SshLogged is driven, and its ExitCode must be 3 (the last), not 0 (the
# first) and not 1 (the ssh code).
#
# Two stubs, keyed off whether the client path had to be converted to Windows
# form (the same condition as the -File conversion above).  Under Windows
# PowerShell the shebang script is unusable twice over: Get-Item cannot resolve
# the MSYS path, so the client stops at "AGENTQ_SSH is not an executable file:
# /c/Users/..." (measured on the first real CI run, 37810470283), and
# CreateProcess cannot execute a `#!/bin/sh` file even with a correct path.  So
# there the stub is a .cmd.  It needs no argument handling at all -- everything
# Invoke-SshLogged passes is ignored, exactly as the sh stub ignores it -- which
# is why the batch file contains no %* to be re-expanded.
exit_token_dir="$work/exit-token-ssh"
mkdir -p "$exit_token_dir"
if [ "$client_arg" != "$client" ]; then
    exit_token_stub="$exit_token_dir/ssh.cmd"
    printf '%s\r\n' \
        '@echo off' \
        'echo agentq-exit:0 1>&2' \
        'echo agentq-exit:3 1>&2' \
        'exit /b 1' > "$exit_token_stub"
    exit_token_ssh=$(cygpath -w "$exit_token_stub")
else
    exit_token_stub="$exit_token_dir/ssh"
    cat > "$exit_token_stub" <<'STUB'
#!/bin/sh
cat > /dev/null 2>&1 || true
printf 'agentq-exit:0\n' >&2
printf 'agentq-exit:3\n' >&2
exit 1
STUB
    chmod 700 "$exit_token_stub"
    exit_token_ssh="$exit_token_stub"
fi
exit_token_probe='
. "'"$client_arg"'" 2>$null
$env:AGENTQ_SSH = "'"$exit_token_ssh"'"
$script:SshPath = Resolve-SshPath
$script:RemotePlatform = "windows"
$script:TargetHost = "smoke-host"
$script:CredentialSource = ""
$script:CredentialOptionLines = Get-CredentialSshOptions
$r = Invoke-SshLogged -RemoteCommand "ignored" -InputPayload $null
if ($r.ExitCode -ne 3) {
    [Console]::Error.WriteLine("exit token: expected the LAST token (3), got $($r.ExitCode)")
    exit 1
}
"exit token last-wins ok"
'
cases=$((cases + 1))
status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command "$exit_token_probe" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] || ! grep -qF 'exit token last-wins ok' "$work/out"; then
    printf '%s\n' 'ps-client: the exit token reader does not take the last match' >&2
    grep -i 'exit token' "$work/err" >&2 || head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

# --- wait --timeout must actually RETURN the response ------------------------
# Invoke-WaitSshWithTimeout runs ssh through New-SshProcessStartInfo, which
# redirects stdout and stderr to PIPES.  The first version never read those
# pipes and took Output from an empty temporary file instead, so a wait that
# completed inside its budget came back as "response was empty" and exited 2 --
# every `wait --timeout` was broken on this client (measured 2026-10-16 with a
# stub ssh that prints a valid Success response and exits 0).  The second half
# of the same defect is that an unread pipe deadlocks ssh once the response
# exceeds the pipe buffer, which the deadline loop then reports as a timeout.
#
# This drives the real function against a stub ssh, so it pins the reading, not
# the shape of the code that does it.
wait_timeout_dir="$work/wait-timeout-ssh"
mkdir -p "$wait_timeout_dir"
if [ "$client_arg" != "$client" ]; then
    wait_timeout_stub="$wait_timeout_dir/ssh.cmd"
    printf '%s\r\n' \
        '@echo off' \
        'echo {"task":{"id":5,"group":"agentq","created_at":"2026-01-01T00:00:00Z","status":{"Done":{"result":"Success"}}}}' \
        'exit /b 0' > "$wait_timeout_stub"
    wait_timeout_ssh=$(cygpath -w "$wait_timeout_stub")
else
    wait_timeout_stub="$wait_timeout_dir/ssh"
    cat > "$wait_timeout_stub" <<'STUB'
#!/bin/sh
cat > /dev/null 2>&1 || true
printf '%s\n' '{"task":{"id":5,"group":"agentq","created_at":"2026-01-01T00:00:00Z","status":{"Done":{"result":"Success"}}}}'
exit 0
STUB
    chmod 700 "$wait_timeout_stub"
    wait_timeout_ssh="$wait_timeout_stub"
fi
wait_timeout_probe='
. "'"$client_arg"'" 2>$null
$env:AGENTQ_SSH = "'"$wait_timeout_ssh"'"
$script:SshPath = Resolve-SshPath
$script:RemotePlatform = "unix"
$script:TargetHost = "smoke-host"
$script:CredentialSource = ""
$script:CredentialOptionLines = Get-CredentialSshOptions
$r = Invoke-WaitSshWithTimeout -RemoteCommand "ignored" -InputPayload $null -TimeoutSeconds 30
if ($r.ExitCode -ne 0) {
    [Console]::Error.WriteLine("wait timeout: expected exit 0 from the completed wait, got $($r.ExitCode)")
    exit 1
}
if ($r.Output -notmatch ''"task"'') {
    [Console]::Error.WriteLine("wait timeout: the response body was not read back (Output was $($r.Output.Length) chars)")
    exit 1
}
if (!(Test-AgentQJsonResponse -Operation "wait" -Output $r.Output -ExpectedTaskId "5")) {
    [Console]::Error.WriteLine("wait timeout: the response did not pass the wait validator")
    exit 1
}
"wait timeout response ok"
'
cases=$((cases + 1))
status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command "$wait_timeout_probe" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] || ! grep -qF 'wait timeout response ok' "$work/out"; then
    printf '%s\n' 'ps-client: wait --timeout does not return the remote response' >&2
    grep -i 'wait timeout' "$work/err" >&2 || head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

# --- the PROBE token reader must take the last token too ---------------------
# The same divergence existed on the PROBE path, over stdout instead of stderr:
# the POSIX client's windows_probe_apply_exit_token strips up to the FINAL
# `agentq-exit:` (${raw##*agentq-exit:}), while this copy used a first-match
# regex.  A remote whose stdout carries a planted leading `agentq-exit:0` would
# make the first-match reader report a platform it never answered for.  Both
# callers already require an exact Output value, so this is defence in depth --
# the point is that the two copies stop disagreeing.
#
# Five cases: three single-token ones that must be BYTE-IDENTICAL to the pre-fix
# implementation (so this case also proves the fix is narrow), plus the two
# multi-token ones, whose EXIT codes must match the POSIX result (3 and 5) and
# whose Output is everything before the last token (then TrimEnd()ed, which is
# this copy's pre-existing behaviour -- the POSIX side keeps the trailing
# newline, so the two are compared on exit code and on content, not bytes).
probe_token_probe='
. "'"$client_arg"'" 2>$null
function Resolve-ProbeExitTokenBefore {
    param([int]$SshExitCode,[string]$Output)
    if ($Output -match "agentq-exit:(\d+)") {
        $Output = $Output -replace "agentq-exit:\d+\s*$", ""
        return [pscustomobject]@{ ExitCode = [int]$Matches[1]; Output = $Output.TrimEnd() }
    }
    return [pscustomobject]@{ ExitCode = $SshExitCode; Output = $Output }
}
$bad = 0
# (name, output, expected exit, expected output, must-match-pre-fix)
$cases = @(
    @{ n="single0";  o="agentq-windows`nagentq-exit:0"; e=0;  x="agentq-windows"; old=$true },
    @{ n="single42"; o="agentq-windows-launcher-missing`nagentq-exit:42"; e=42; x="agentq-windows-launcher-missing"; old=$true },
    @{ n="notoken";  o="agentq-windows"; e=1;  x="agentq-windows"; old=$true },
    @{ n="planted";  o="agentq-exit:0`nagentq-windows`nagentq-exit:3"; e=3; x="agentq-exit:0`nagentq-windows"; old=$false },
    @{ n="midtoken"; o="agentq-exit:5`nagentq-windows"; e=5; x=""; old=$false }
)
foreach ($c in $cases) {
    $r = Resolve-ProbeExitToken -SshExitCode 1 -Output $c.o
    if ($r.ExitCode -ne $c.e -or $r.Output -cne $c.x) {
        [Console]::Error.WriteLine("probe token $($c.n): expected exit=$($c.e) out=[$($c.x)] got exit=$($r.ExitCode) out=[$($r.Output)]")
        $bad += 1
        continue
    }
    if ($c.old) {
        $o = Resolve-ProbeExitTokenBefore -SshExitCode 1 -Output $c.o
        if ($o.ExitCode -ne $r.ExitCode -or $o.Output -cne $r.Output) {
            [Console]::Error.WriteLine("probe token $($c.n): single-token case changed (before exit=$($o.ExitCode) out=[$($o.Output)])")
            $bad += 1
        }
    }
}
if ($bad -ne 0) { exit 1 }
"probe exit token last-wins ok"
'
cases=$((cases + 1))
status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command "$probe_token_probe" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] || ! grep -qF 'probe exit token last-wins ok' "$work/out"; then
    printf '%s\n' 'ps-client: the PROBE exit token reader does not take the last match' >&2
    grep -i 'probe token' "$work/err" >&2 || head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

# --- the probe body must actually RUN when fed to `-Command -` on stdin ------
# The Windows probes travel to `powershell.exe -Command -` on STDIN, and stdin is
# read in INTERACTIVE mode: a line that opens a block (`if {`, `function {`,
# `try {`) buffers until a BLANK LINE terminates it, and at EOF a pending buffer
# is DISCARDED SILENTLY -- rc=0, no output, nothing executed.  The protocol probe
# is a multi-line here-string, so without a terminating blank line its whole body
# is thrown away: every command against a Windows target fails with "protocol
# probe failed", which points at the deployment rather than at the client.  The
# platform probe is single-line and so was never affected.
#
# This case is BEHAVIORAL on purpose: the source-level assertions above cannot
# see it, because the bug is in how PowerShell consumes the text, not in the
# text.  It builds the real probe input and feeds it to the SAME interpreter
# running this check (via the current process's own image), so it is meaningful
# under both pwsh 7 and Windows PowerShell 5.1.  The assertion is that the probe
# produced its exit token -- that proves the body executed.  Which token value
# appears is deliberately NOT asserted: on a host with the launcher deployed it
# is `agentq-exit:0`, and without it `agentq-exit:42`, and both prove the body
# ran.  Measured: with the defect, out=[] for the multi-line body.
probe_stdin_probe='
. "'"$client_arg"'" 2>$null
$probe = Get-WindowsAgentQProtocolProbeCommand
$exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$si = [System.Diagnostics.ProcessStartInfo]::new()
$si.FileName = $exe
$si.UseShellExecute = $false
$si.CreateNoWindow = $true
$si.RedirectStandardInput = $true
$si.RedirectStandardOutput = $true
$si.RedirectStandardError = $true
$si.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command -"
$p = [System.Diagnostics.Process]::Start($si)
$p.StandardInput.Write($probe.Input)
$p.StandardInput.Close()
$out = $p.StandardOutput.ReadToEnd()
$err = $p.StandardError.ReadToEnd()
$p.WaitForExit(30000) | Out-Null
if ($out -notmatch "agentq-exit:\d+") {
    [Console]::Error.WriteLine("the probe body did not run when fed to -Command - on stdin (out=[$out] err=[$err])")
    exit 1
}
"probe stdin delivery ok"
'
cases=$((cases + 1))
status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command "$probe_stdin_probe" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] || ! grep -qF 'probe stdin delivery ok' "$work/out"; then
    printf '%s\n' 'ps-client: the probe body is silently discarded by -Command - on stdin' >&2
    head -5 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

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

# --- probe failure branches must not fall through to the ready marker ---------
# Measured 2026-10-06: both clients rewrote `exit N` to `$agentqProbeExit = N`,
# and an ASSIGNMENT does not terminate.  The probe bodies are sequential `if`
# statements, so a missing launcher fell through every later check and the
# unconditional final `...-ready` write, and the LAST code assigned (44) won
# the token -- the client reported "protocol probe failed" + 44 where the
# contract says "deployment is incomplete" + 2, and the 42/43 branches were
# unreachable.  The rewrite now writes the token AT the exit site and exits.
# These cases drive each asset's OWN body and OWN rewrite (extracted at run
# time, like the other extraction cases here): a regression in either half is
# caught, and a source-level assertion could not see this class at all -- the
# defect lives in what PowerShell does with the rewritten text.
probe_work="$work/probe"
mkdir -p "$probe_work"
# The probe bodies hardcode C:\ProgramData\AgentQ\agentq-launcher.ps1 and take
# the 42 branch only when that file is ABSENT.  The fixture used to rely on the
# HOST lacking it: true on a clean macOS, false on any machine where AgentQ is
# installed.  Measured 2026-10-20 on a real Windows host running 0.1.8: the
# launcher was present, the probe correctly reached `ready`, and the case
# reported 6 failures that all read like asset defects.  A case whose premise
# the environment can supply is not a test, so the extraction below rewrites
# that one literal to a path under the fixture directory that nothing creates.
# The rest of the body -- every exit site the rewrite must preserve -- is still
# the asset's own text, which is what these cases are about.
python3 - "$root" "$probe_work" <<'PYEXT'
import io, os, re, subprocess, sys
root, out = sys.argv[1], sys.argv[2]

# POSIX asset: its protocol-probe body and its own sed program.
# A path under the fixture dir that nothing ever creates: the probe's
# `Get-Item -ErrorAction SilentlyContinue` returns null there on every host, so
# the 42 branch is reachable even where AgentQ is deployed for real.
missing_launcher = os.path.abspath(os.path.join(out, 'no-such-launcher.ps1'))

# The launcher path must be READ FROM THE ASSET, not written down here.  A
# literal copy is a second source of truth that can silently drift out of step
# with the asset -- and the drift is invisible, because the Windows asset names
# this path TWICE (once in the protocol probe's existence check, once in the
# actual invocation) while the POSIX asset embeds it once.  Measured 2026-10-20
# by editing the run-time occurrence only: every case stayed green, since the
# probe kept reading a path that no longer matched what the client would run.
# `expected` is what both assets must agree on; the retarget below is applied to
# a body only after it is shown to carry exactly that value.
LAUNCHER_PATH_RE = re.compile(
    r'[A-Za-z]:[\\/]ProgramData[\\/]AgentQ[\\/][A-Za-z0-9._-]+\.ps1')

def launcher_literal_from(asset_text, label):
    # The pattern matches ANY .ps1 under ProgramData\\AgentQ, not just the
    # current file name -- a rename of ONE site must show up as two values, not
    # as an invisible non-match (measured: a name-specific pattern let the
    # invocation site drift while the probe kept reading the old path).
    # Both slash styles occur in every asset (the probe and the invocation use
    # backslashes, the operator-facing diagnostics use forward slashes), so
    # uniqueness is judged on the NORMALIZED value; the value actually RETARGETED
    # is the backslash form, which is what the probe body carries (counted on the
    # body itself, so this cannot mask an extra occurrence there).
    raw = {m.group(0) for m in LAUNCHER_PATH_RE.finditer(asset_text)}
    normalized = {v.replace(chr(92), '/') for v in raw}
    if len(normalized) != 1:
        raise SystemExit(
            'extraction: the %s asset names %d distinct launcher paths %r; '
            'update this fixture with the asset.' % (label, len(normalized), sorted(normalized)))
    target = normalized.pop()
    backslashed = {v for v in raw if chr(92) in v}
    return backslashed.pop() if backslashed else target

def retarget(body, literal, label):
    if body.count(literal) != 1:
        raise SystemExit(
            'extraction: the %s probe body no longer contains exactly one '
            'launcher literal (%d); update this fixture with the asset.'
            % (label, body.count(literal)))
    return body.replace(literal, missing_launcher)

posix = io.open(root + '/skill/assets/client/unix/agentq', encoding='utf-8').read()
posix_launcher = launcher_literal_from(posix, 'POSIX')
body = retarget(re.search(r"windows_protocol_script='([^']*)'", posix).group(1), posix_launcher, 'POSIX')
sedprog = re.search(r"sed -E '(s/.*?)'\)", posix, re.S).group(1)
rewritten = subprocess.run(['sed', '-E', sedprog], input=body + '\n',
                           capture_output=True, text=True, check=True).stdout
io.open(out + '/posix-probe.ps1', 'w').write(
    rewritten + '[Console]::Out.Write("agentq-exit:0")\n' + 'exit 0\n')

# Windows asset: its body plus the exact regex and replacement of its rewrite.
win = io.open(root + '/skill/assets/client/windows/agentq.ps1', encoding='utf-8').read()
seg = win[win.index('function Get-WindowsAgentQProtocolProbeCommand'):]
win_launcher = launcher_literal_from(win, 'Windows')
body2 = retarget(re.search(r"\$script = @'\n(.*?)\n'@", seg, re.S).group(1), win_launcher, 'Windows')
line = [l for l in win.split('\n') if '[regex]::Replace($Script' in l][0]
pat = line[line.index("Replace($Script, '") + len("Replace($Script, '"):line.rindex("', '")]
rep = line[line.rindex("', '") + 4:-2]
win_ps = ("$body = @'\n" + body2 + "\n'@\n"
          + "$out = [regex]::Replace($body, '" + pat + "', '" + rep + "')\n"
          + "$out + \"`n\" + '[Console]::Out.Write(\"agentq-exit:0\")' + \"`n\" + 'exit 0' + \"`n`n\"\n")
io.open(out + '/win-probe.ps1', 'w').write(win_ps)

# The BOM fixture: what PS 5.1's `2>` redirection writes (UTF-16LE with BOM,
# measured for `1>` on 2026-09-21: the byte count doubles; smoke/10 rule B pins
# the same coupling for the installer).  The reader used to be UTF-8-only, so
# the token and the reason line were unreadable on real PS 5.1.
io.open(out + '/bom-stderr.bin', 'wb').write(
    b'\xff\xfe' + 'agentq-exit:3\n'.encode('utf-16-le'))
fn = re.search(r'function Get-FileTextOrEmpty \{.*?\n\}\n', win, re.S).group(0)
io.open(out + '/bom-driver.ps1', 'w').write(
    'function Assert-NonReparseTemporaryFilePath { param([string]$Path) }\n'
    + fn
    + '$text = Get-FileTextOrEmpty -Path "' + out + '/bom-stderr.bin" -Bounded\n'
    + "$m = [regex]::Matches($text, '(?m)^agentq-exit:(\\d{1,3})\\s*$')\n"
    + 'if ($m.Count -gt 0) { [Console]::Out.Write("token=" + $m[$m.Count - 1].Groups[1].Value) } else { [Console]::Out.Write("token=NONE") }\n')
print('extracted')
PYEXT
if [ ! -s "$probe_work/posix-probe.ps1" ] || [ ! -s "$probe_work/win-probe.ps1" ] || [ ! -s "$probe_work/bom-driver.ps1" ]; then
    printf '%s\n' 'ps-client: probe/BOM fixture extraction failed; the cases below cannot conclude' >&2
    failures=$((failures + 1))
else
    # Case A: the POSIX asset's own rewrite keeps failure control flow.
    cases=$((cases + 1))
    posix_probe_status=0
    "$pwsh_binary" -NoProfile -NonInteractive -Command - < "$probe_work/posix-probe.ps1" > "$probe_work/posix.out" 2>/dev/null || posix_probe_status=$?
    posix_probe_out=$(tr -d '\033' < "$probe_work/posix.out" | sed 's/\[?1[lh]//g')
    case "$posix_probe_out" in
        *agentq-windows-launcher-missing*agentq-exit:42) ;;
        *) printf 'POSIX probe (missing launcher) produced %s; expected the missing marker and token 42\n' "$posix_probe_out" >&2
           failures=$((failures + 1)) ;;
    esac
    case "$posix_probe_out" in
        *ready*) printf '%s\n' 'the POSIX probe fell through to the ready marker after a failure branch' >&2
                 failures=$((failures + 1)) ;;
    esac
    if [ "$posix_probe_status" -ne 42 ]; then
        printf 'POSIX probe (missing launcher) exited %s, expected 42\n' "$posix_probe_status" >&2
        failures=$((failures + 1))
    fi

    # Case B: the Windows asset's own rewrite does the same.  Two stages: the
    # generator (the asset's regex + replacement) runs under -File so its
    # multi-line here-string is not swallowed by `-Command -`'s interactive
    # reader (A20); it prints the rewritten script, a blank line terminates it
    # for the same reader, and only then is the script executed.
    cases=$((cases + 1))
    "$pwsh_binary" -NoProfile -NonInteractive -File "$probe_work/win-probe.ps1" > "$probe_work/win-rewritten.ps1" 2>/dev/null
    printf '\n' >> "$probe_work/win-rewritten.ps1"
    win_probe_status=0
    "$pwsh_binary" -NoProfile -NonInteractive -Command - < "$probe_work/win-rewritten.ps1" > "$probe_work/win.out" 2>/dev/null || win_probe_status=$?
    win_probe_out=$(tr -d '\033' < "$probe_work/win.out" | sed 's/\[?1[lh]//g')
    case "$win_probe_out" in
        *agentq-windows-launcher-missing*agentq-exit:42) ;;
        *) printf 'Windows probe (missing launcher) produced %s; expected the missing marker and token 42\n' "$win_probe_out" >&2
           failures=$((failures + 1)) ;;
    esac
    case "$win_probe_out" in
        *ready*) printf '%s\n' 'the Windows probe fell through to the ready marker after a failure branch' >&2
                 failures=$((failures + 1)) ;;
    esac
    if [ "$win_probe_status" -ne 42 ]; then
        printf 'Windows probe (missing launcher) exited %s, expected 42\n' "$win_probe_status" >&2
        failures=$((failures + 1))
    fi

    # Case C: the stderr reader decodes a PS 5.1-shaped UTF-16LE+BOM file.
    cases=$((cases + 1))
    bom_out=$("$pwsh_binary" -NoProfile -NonInteractive -File "$probe_work/bom-driver.ps1" 2>/dev/null | tr -d '\r')
    case "$bom_out" in
        *token=3*) ;;
        *) printf 'the stderr reader did not decode a UTF-16LE+BOM capture (got %s; PS 5.1 `2>` writes that shape)\n' "$bom_out" >&2
           failures=$((failures + 1)) ;;
    esac
fi

# The gate that acts on $failures sits at the END of this file, after every
# check has had its chance to increment it -- an earlier mid-file gate let the
# checks appended after it print "checks passed" on a run that had already
# failed (observed 2026-10-15: the 0.1.11 validator block incremented
# $failures, the run kept going and printed the passed line, exit 0).
# Static lock: the probe-path exit-token reader must bound its digit run to
# three, exactly like the operation-path reader.  An unbounded `\d+` let a
# remote probe print `agentq-exit:<huge>` and make the following `[int]` cast
# throw; the client has no top-level trap, so that exits 1 with a PowerShell
# error instead of the fail-closed fallback to the SSH exit code (measured
# 2026-10-12: `[int]"99999999999999999999"` throws RuntimeException).  The two
# readers drifting apart is the "same mechanism, one copy fixed" shape this
# repo keeps hitting, so both are pinned here.
cases=$((cases + 1))
# (the ps1 path is the existing $client)
# EVERY reader of the out-of-band token must bound its digit run, not merely one
# of them.  Until 2026-10-16 this was a single `grep -q "agentq-exit:(\\d{1,3})"`
# -- "at least one occurrence exists" -- so deleting the probe-path reader
# (Resolve-ProbeExitToken) left the lock green as long as the two operation-path
# readers remained, and a new UNBOUNDED reader elsewhere was invisible.  The
# invariant is per-reader: a reader is a `[regex]::Matches` call that reads the
# token, and each one must carry `\d{1,3}`.  The count is pinned so a reader
# cannot be deleted unnoticed either (a raw `grep -c` over the whole file would
# count COMMENT mentions too -- there are two -- so the count is taken over
# reader lines only).
exit_readers=$(grep -F '[regex]::Matches' "$client" | grep -cF 'agentq-exit:' || true)
exit_readers_bounded=$(grep -F '[regex]::Matches' "$client" | grep -cF 'agentq-exit:(\d{1,3})' || true)
if [ "$exit_readers" -ne 3 ]; then
    printf 'ps-client-contract: expected 3 exit-token readers, found %s\n' "$exit_readers" >&2
    failures=$((failures + 1))
fi
if [ "$exit_readers_bounded" -ne "$exit_readers" ]; then
    printf 'ps-client-contract: %s of %s exit-token readers bound their digit run to {1,3}\n' \
        "$exit_readers_bounded" "$exit_readers" >&2
    failures=$((failures + 1))
fi
if grep -qF 'agentq-exit:(\d+)' "$client"; then
    printf '%s\n' 'ps-client-contract: an unbounded \d+ exit-token reader is present; a huge token would crash the [int] cast' >&2
    failures=$((failures + 1))
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

# --- the 0.1.11 modes: the client must answer them with the RIGHT shapes ------
# Driving the real operation path needs a stub ssh.exe; instead these call the
# validator directly on each documented response shape (the same pattern the
# reason/auth-hint probes use): a client whose status_summary/status_task/
# remove_batch validator accepted the WRONG shape (or rejected the documented
# one) fails here.  Measured PS quirk this encodes: ConvertFrom-Json turns `[]`
# into $null and a single-element array into the bare element, so the batch
# validator must iterate @(...) rather than test -is [array].
validator_probe='
. "'"$client_arg"'" 2>$null
$summaryJson = "{`"tasks`":{`"3`":{`"id`":3,`"state`":`"Done`",`"result`":`"Success`",`"label`":`"agentq:x`"}},`"group`":null,`"summary`":true}"
$taskJson = "{`"task`":{`"id`":3,`"group`":`"agentq`",`"created_at`":`"2026-01-01T00:00:00Z`",`"status`":{`"Done`":{`"result`":`"Success`"}}}}"
$fullJson = "{`"tasks`":{},`"group`":null}"
$batchEmptyJson = "[]"
$batchOneJson = "[{`"task_id`":3,`"removed`":true}]"
$batchTwoJson = "[{`"task_id`":3,`"removed`":true},{`"task_id`":4,`"removed`":false,`"state`":`"failed`"}]"
$cases = @(
    @{ n = "summary-ok";      op = "status_summary"; v = $summaryJson; id = ""; want = $true },
    @{ n = "summary-marker";  op = "status_summary"; v = $fullJson;    id = ""; want = $false },
    # The plain `status` (full decorated map) arm was not exercised at all here.
    @{ n = "status-full-ok";  op = "status";         v = $fullJson;    id = ""; want = $true },
    @{ n = "task-ok";         op = "status_task";    v = $taskJson;    id = "3"; want = $true },
    @{ n = "task-id-mismatch"; op = "status_task";   v = $taskJson;    id = "9"; want = $false },
    @{ n = "doctor-full-ok";  op = "doctor_full";    v = $fullJson;    id = ""; want = $true },
    @{ n = "doctor-summary-ok"; op = "doctor";       v = $summaryJson; id = ""; want = $true },
    # The doctor directions are BOTH ways, not just the accept: doctor must
    # reject the full body.  Without that negative, folding `{doctor,
    # doctor_full}` into the single `status` arm -- which accepts either shape,
    # measured 2026-10-16 -- kept every case above green.  (The reverse
    # negative, doctor_full rejecting a summary body, is NOT asserted because
    # it is not true: Test-JsonTaskMap accepts the summary map, and asserting
    # it would pin a behaviour the client does not have.)
    @{ n = "doctor-rejects-full"; op = "doctor"; v = $fullJson; id = ""; want = $false },
    @{ n = "batch-empty";     op = "remove_batch";   v = $batchEmptyJson; id = ""; want = $true },
    @{ n = "batch-one";       op = "remove_batch";   v = $batchOneJson;   id = ""; want = $true },
    @{ n = "batch-two";       op = "remove_batch";   v = $batchTwoJson;   id = ""; want = $true },
    @{ n = "batch-bad-entry"; op = "remove_batch";   v = "[{`"task_id`":3}]"; id = ""; want = $false }
)
$bad = 0
foreach ($case in $cases) {
    $actual = Test-AgentQJsonResponse -Operation $case.op -Output $case.v -ExpectedTaskId $case.id
    if ($actual -ne $case.want) {
        [Console]::Error.WriteLine("validator case $($case.n): expected $($case.want) got $actual")
        $bad += 1
    }
}
if ($bad -ne 0) { exit 1 }
"mode validator cases ok: $($cases.Count)"
'
cases=$((cases + 1))
status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command "$validator_probe" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] || ! grep -qF 'mode validator cases ok' "$work/out"; then
    printf '%s\n' 'ps-client: the 0.1.11 mode response validators misbehave' >&2
    head -3 "$work/err" >&2
    failures=$((failures + 1))
fi
# Static locks: the stdin-script channel, the batch form, and the doctor --full
# escape hatch must exist in the client source (behaviour is pinned on the POSIX
# twin's run; the ps1 side here pins the surface).
# The stdin-script guard is pinned by STRUCTURE, not by `grep -q -- 'command -v
# base64'`: that token also sits in the client's LOCAL check, so a guard deleted
# from the remote string stays green on a name-only grep (the twin's behavioural
# lock in smoke/05 cannot reach this copy -- it runs the POSIX client's emitted
# command).  What is asserted is the position of the guard INSIDE the same
# string as the decode pipeline: the remote command must carry the guard
# followed by `;` and the pipeline, and the guard must not be attached as a
# pipeline recovery clause (`| sh || { ... }` runs only after the pipeline has
# already exited 0 -- measured on the POSIX twin).  Comment lines are excluded
# so removing the real guard while keeping its explanation cannot pass.
mode_static_failures=0
grep -q -- '--stdin-script' "$client" || { printf '%s\n' 'ps-client: missing submit --stdin-script' >&2; mode_static_failures=$((mode_static_failures + 1)); }
ps1_stdin_guard_line=$(/usr/bin/grep -v '^[[:space:]]*#' "$client" | /usr/bin/grep -F -- '$commandArguments = @("sh", "-c", "command -v base64' || true)
ps1_stdin_guard_problem=''
if [ -z "$ps1_stdin_guard_line" ]; then
    ps1_stdin_guard_problem='the stdin-script decode command with a target-side guard is not in the client'
elif ! /usr/bin/grep -qF -- 'command -v base64 >/dev/null 2>&1 || { echo' <<< "$ps1_stdin_guard_line"; then
    ps1_stdin_guard_problem='the stdin-script decode command lost its target-side base64 guard'
elif ! /usr/bin/grep -qF -- 'exit 2; }; printf %s $scriptBase64 | base64 -d | sh' <<< "$ps1_stdin_guard_line"; then
    # The guard's block must be followed directly by the pipeline: that is what
    # pins it BEFORE the pipeline.  A recovery clause (`| sh || { ... }`) would
    # put the pipeline first and run the guard only after the pipeline already
    # exited 0 (the fail-open shape, measured on the POSIX twin).
    ps1_stdin_guard_problem='the stdin-script decode guard is not positioned before the pipeline (or is attached as a pipeline recovery clause)'
fi
if [ -n "$ps1_stdin_guard_problem" ]; then
    printf 'ps-client: %s\n' "$ps1_stdin_guard_problem" >&2
    mode_static_failures=$((mode_static_failures + 1))
fi

# The platform cache must live under the SAME SID-resolved profile as the config
# path.  The client's stated rule is that USERPROFILE is not trusted (Git Bash,
# OpenSSH, runas and stale sessions pollute it), and it resolves the profile
# from the process SID for exactly that reason -- but the cache path read the
# raw environment until 2026-10-21, i.e. a second location the same rule was
# meant to cover.  A source-level lock, because the behavioural difference only
# appears on Windows with a polluted USERPROFILE (off Windows both spellings
# resolve to the same fallback, so a fixture cannot distinguish them).
cache_path_body=$(awk '/^function Get-PlatformProbeCachePath/,/^}/' "$client" \
    | /usr/bin/grep -v '^[[:space:]]*#')
if [ -z "$cache_path_body" ]; then
    printf '%s\n' 'ps-client: Get-PlatformProbeCachePath is missing from the client' >&2
    mode_static_failures=$((mode_static_failures + 1))
elif /usr/bin/grep -qF -- '$env:USERPROFILE' <<< "$cache_path_body"; then
    printf '%s\n' 'ps-client: the platform cache path reads $env:USERPROFILE (must use $script:UserProfileDirectory, the SID-resolved profile)' >&2
    mode_static_failures=$((mode_static_failures + 1))
elif ! /usr/bin/grep -qF -- '$script:UserProfileDirectory' <<< "$cache_path_body"; then
    printf '%s\n' 'ps-client: the platform cache path no longer derives from $script:UserProfileDirectory' >&2
    mode_static_failures=$((mode_static_failures + 1))
fi
grep -q -- '--confirm' "$client" || { printf '%s\n' 'ps-client: missing remove --label --confirm handling' >&2; mode_static_failures=$((mode_static_failures + 1)); }
grep -q -- '--full' "$client" || { printf '%s\n' 'ps-client: missing doctor --full' >&2; mode_static_failures=$((mode_static_failures + 1)); }
grep -q -- '--summary' "$client" || { printf '%s\n' 'ps-client: missing status --summary' >&2; mode_static_failures=$((mode_static_failures + 1)); }
failures=$((failures + mode_static_failures))

# The LOCAL command-line budget.  The unix-target payload is base64'd twice
# (submit arm + New-UnixRemoteInvocation) and both copies ride ONE argv
# element of the local ssh.exe, so the platform's command-line limit applies:
# CreateProcess caps a Windows command line at 32767 characters.  The declared
# unix limit was 100000 base64 characters -- 4.2x more than Windows can
# transmit -- so scripts between 13.5 KB and 75 KB were accepted here and then
# failed at the local process launch (an unclassified exit 1 with the
# diagnostic redacted).  Measured 2026-10-22 with this repo's stub ssh: an
# 8-byte script produced a 750-character local argv, so the fixed overhead is
# about 734 and the usable budget on Windows is about 24000 base64 chars.
#
# The static lock pins the WINDOWS value: the platform branch is chosen at
# runtime, so a case run under pwsh on macOS exercises the POSIX limit, and
# only the constant can carry the Windows one.
grep -q 'LocalCommandLineLimit' "$client" ||
    { printf '%s\n' 'ps-client: no local command-line budget for the ssh payload' >&2; mode_static_failures=$((mode_static_failures + 1)); }
grep -q '32767' "$client" ||
    { printf '%s\n' 'ps-client: the local command-line budget does not carry the Windows CreateProcess limit (32767)' >&2; mode_static_failures=$((mode_static_failures + 1)); }
grep -q 'LocalCommandLineFixedOverhead' "$client" ||
    { printf '%s\n' 'ps-client: the local command-line budget has no measured fixed overhead' >&2; mode_static_failures=$((mode_static_failures + 1)); }
failures=$((failures + mode_static_failures))

# The behavioural half: a payload beyond the local budget must be REFUSED with
# the controlled message, before any ssh launch -- not accepted and then failed
# at the process launch.  The budget is read from the asset's own constants so
# the case does not restate them (a second copy would drift).
cases=$((cases + 1))
oversize_probe='
$ErrorActionPreference = "Stop"
. "'"$client_arg"'" 2>$null
$limit = [int](($script:LocalCommandLineLimit - $script:LocalCommandLineFixedOverhead) * 3 / 4)
$payload = "x" * ($limit + 4096)
$scriptBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))
Write-Output ("limit=" + $limit + " b64=" + $scriptBase64.Length)
'
oversize_out=$("$pwsh_binary" -NoProfile -NonInteractive -Command "$oversize_probe" 2>/dev/null | tr -d '\r')
oversize_limit=$(printf '%s\n' "$oversize_out" | sed -n 's/^limit=\([0-9]*\) .*/\1/p')
oversize_b64=$(printf '%s\n' "$oversize_out" | sed -n 's/.*b64=\([0-9]*\)$/\1/p')
if [ -z "$oversize_limit" ] || [ -z "$oversize_b64" ]; then
    printf 'ps-client: could not read the local command-line budget from the asset: %s\n' "$oversize_out" >&2
    failures=$((failures + 1))
elif [ "$oversize_b64" -le "$oversize_limit" ]; then
    printf 'ps-client: the local command-line budget did not shrink the usable payload (%s > %s is false)\n' "$oversize_b64" "$oversize_limit" >&2
    failures=$((failures + 1))
fi

# --version must be byte-identical to the POSIX twin's line.  Measured
# 2026-10-21: this client printed `agentq.ps1 0.1.16` while the POSIX client
# printed `agentq 0.1.16` -- the program name came from $script:Program, which
# is the FILE name (right for error prefixes, wrong for this line), and no case
# pinned the output at all.
cases=$((cases + 1))
version_out=$("$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" --version 2>/dev/null | tr -d '\r')
case $version_out in
    'agentq '[0-9]*.[0-9]*.[0-9]*) ;;
    *) printf 'ps-client --version: expected "agentq <x.y.z>", got "%s"\n' "$version_out" >&2
       failures=$((failures + 1)) ;;
esac

# A configured-but-bad cache TTL must be REFUSED at startup, not silently
# replaced by the default.  Measured 2026-10-21: the POSIX client refused it
# while this one fell back to 604800 -- `AGENTQ_PLATFORM_PROBE_CACHE_TTL=abc`
# quietly meant "seven days", and no check covered the Windows side at all.
# A malformed cache entry is a MISS, never an error.  Measured 2026-10-21: a
# file holding valid JSON with a missing field (`{}`, `null`,
# `{"platform":"unix"}`) made StrictMode throw PropertyNotFoundException
# OUTSIDE the old try, so an uncaught error escaped as exit 1 with a stack and
# every later command against that host failed -- until the file was deleted by
# hand.  This drives the real function against each shape and requires a clean
# `false`, which is exactly what the cache's contract promises.
cache_miss_probe=$(cat <<'PSCACHE'
$ErrorActionPreference = "Stop"
. "__CLIENT__" 2>$null
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ("aq-cache-shape-" + $PID)
$env:AGENTQ_PLATFORM_CACHE_DIR = $dir
$env:AGENTQ_PLATFORM_PROBE_CACHE = "on"
[void](New-Item -ItemType Directory -Path (Join-Path $dir "platform-cache") -Force)
$path = Get-PlatformProbeCachePath
$bad = 0
foreach ($body in @('{}', 'null', '{"platform":"unix"}', '{"platform":"bogus","probed_at":1}', 'not json at all')) {
    [System.IO.File]::WriteAllText($path, $body)
    $script:RemotePlatform = "auto"
    try {
        $hit = Read-PlatformProbeCache
        if ($hit) { [Console]::Error.WriteLine("cache shape " + $body + ": treated as a HIT"); $bad += 1 }
    } catch {
        [Console]::Error.WriteLine("cache shape " + $body + ": threw " + $_.Exception.GetType().Name)
        $bad += 1
    }
}
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
if ($bad -eq 0) { [Console]::Out.WriteLine("cache-miss-shapes-ok") }
PSCACHE
)
cache_miss_probe=${cache_miss_probe//__CLIENT__/$client_arg}

# Validation runs before any ssh call, so no stub is needed here.
cases=$((cases + 1))
ttl_status=0
AGENTQ_PLATFORM_PROBE_CACHE_TTL=abc AGENTQ_HOST=smoke-host \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$client_arg" status \
    >"$work/out" 2>"$work/err" || ttl_status=$?
if [ "$ttl_status" -ne 2 ] || ! grep -qF 'AGENTQ_PLATFORM_PROBE_CACHE_TTL must be a positive' "$work/err"; then
    printf 'ps-client: AGENTQ_PLATFORM_PROBE_CACHE_TTL=abc was not refused at startup (exit %s)\n' "$ttl_status" >&2
    head -2 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

cases=$((cases + 1))
cache_miss_status=0
cache_miss_out=$("$pwsh_binary" -NoProfile -NonInteractive -Command "$cache_miss_probe" 2>"$work/cache-miss.err") || cache_miss_status=$?
# The dot-source prints the client's usage on stdout (no arguments), so the
# verdict is "the probe's own token is present", not "stdout is exactly it".
if [ "$cache_miss_status" -ne 0 ] || ! grep -qF 'cache-miss-shapes-ok' <<< "$cache_miss_out"; then
    printf 'ps-client: a malformed platform-cache entry is not treated as a cache miss (exit %s)\n' "$cache_miss_status" >&2
    head -3 "$work/cache-miss.err" >&2 || true
    failures=$((failures + 1))
fi

# --- the platform-probe cache write must not use a .NET Core-only overload ---
# Write-PlatformProbeCache used `[System.IO.File]::Move($temporary, $path,
# $true)`.  The three-argument overwrite overload exists on .NET Core 3.0+
# (pwsh 7 -- measured here: GetMethods lists Move(String, String, Boolean)) but
# NOT on .NET Framework, which is what Windows PowerShell 5.1 runs on.  There it
# is a binding failure, the function's own catch swallows it as "no cache", and
# the cache silently never works -- on the interpreter the .cmd/.bash launchers
# actually use.  No other check could see this: every check sets
# AGENTQ_PLATFORM_PROBE_CACHE=off, so the write path was never executed.
#
# The lock is behavioural, not a grep for the bad call: it dot-sources the
# client and drives Write-PlatformProbeCache twice (fresh write, then overwrite)
# against a private cache directory.  A grep would pass on any rewrite that
# reintroduces the overload somewhere else, and would also pass if the function
# were broken in a new way.
cache_probe='
$ErrorActionPreference = "Stop"
. "'"$client_arg"'" 2>$null
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ("aq-cache-lock-" + $PID)
$env:AGENTQ_PLATFORM_CACHE_DIR = $dir
$env:AGENTQ_PLATFORM_PROBE_CACHE = "on"
$script:RemotePlatform = "unix"
$bad = 0
Write-PlatformProbeCache
$path = Get-PlatformProbeCachePath
if (!(Test-Path -LiteralPath $path -PathType Leaf)) { [Console]::Error.WriteLine("cache: the first write created no file"); $bad += 1 }
else {
    $first = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($first.platform -ne "unix") { [Console]::Error.WriteLine("cache: first entry has platform=$($first.platform)"); $bad += 1 }
}
# Second write must OVERWRITE an existing entry.  This is the arm that used the
# 5.1-incompatible overload; on a correct implementation the file is replaced
# and no .bak / .tmp is left behind.
$script:RemotePlatform = "windows"
Write-PlatformProbeCache
if (!(Test-Path -LiteralPath $path -PathType Leaf)) { [Console]::Error.WriteLine("cache: the overwrite removed the file"); $bad += 1 }
else {
    $second = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($second.platform -ne "windows") { [Console]::Error.WriteLine("cache: the overwrite did not take (platform=$($second.platform))"); $bad += 1 }
}
$leftovers = @(Get-ChildItem -LiteralPath $dir -Recurse -Force -File | Where-Object { $_.FullName -ne $path })
if ($leftovers.Count -ne 0) { [Console]::Error.WriteLine("cache: temporary/backup files left behind: " + (($leftovers | ForEach-Object Name) -join ",")); $bad += 1 }
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
if ($bad -ne 0) { exit 1 }
"cache write cases ok"
'
cases=$((cases + 1))
status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command "$cache_probe" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] || ! grep -qF 'cache write cases ok' "$work/out"; then
    printf '%s\n' 'ps-client: the platform-probe cache write is broken (a .NET Framework runtime would silently never cache)' >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

# An unguarded `ConvertFrom-Json -Depth` is a PARAMETER binding failure on
# Windows PowerShell 5.1 (measured on this host with PSScriptAnalyzer's 5.1
# profile: "The parameter 'Depth' is not available for command
# 'ConvertFrom-Json' by default in PowerShell version '5.1.17763.316'"), and
# the catch around both call sites would turn it into "invalid JSON response"
# for every call.  The asset guards both sites with
# `Parameters.ContainsKey("Depth")`; that guard is load-bearing and had no
# lock.  The check is structural (AST ancestor, not a line window or a grep
# count): every ConvertFrom-Json command carrying -Depth must sit inside an
# if whose condition tests the parameter.  It self-calibrates on a fixture
# with one unguarded and one guarded site, so a scanner that has stopped
# matching cannot read as a clean tree.
cases=$((cases + 1))
# The fixture is materialized by bash (a quoted heredoc has no quoting layers
# to fight); the PowerShell probe only reads two files.  Calibration: the
# fixture holds one guarded and one unguarded site, so a scanner that has
# stopped matching (or that matches everything) fails here before the asset is
# judged.
cat > "$work/depth-fixture.ps1" <<'AQPSEOF'
function Test-Good {
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey("Depth")) {
        $x = "{}" | ConvertFrom-Json -Depth 100
    } else {
        $x = "{}" | ConvertFrom-Json
    }
}
function Test-Bad {
    $y = "{}" | ConvertFrom-Json -Depth 100
}
AQPSEOF
depth_probe='
param([string]$FixturePath, [string]$ClientPath)
$ErrorActionPreference = "Stop"
function Get-UnguardedDepthSites([string]$Path) {
    $err = $null; $tok = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$err)
    $bad = @()
    foreach ($c in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $elements = $c.CommandElements
        if ($elements.Count -lt 1) { continue }
        if ($elements[0].Extent.Text -ne "ConvertFrom-Json") { continue }
        # -Depth may be written `-Depth 100` OR `-Depth:100`; the colon form is
        # a single CommandParameterAst whose extent text is "-Depth:100", so
        # comparing Extent.Text to "-Depth" misses it.  ParameterName is
        # "Depth" in both spellings (measured), so test that instead.
        $hasDepth = $false
        for ($i = 1; $i -lt $elements.Count; $i++) {
            if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
                $elements[$i].ParameterName -ieq "Depth") { $hasDepth = $true }
        }
        if (-not $hasDepth) { continue }
        $guarded = $false
        $p = $c.Parent
        while ($null -ne $p) {
            if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
                foreach ($clause in $p.Clauses) {
                    if ($clause.Item1.Extent.Text -match "Parameters\.ContainsKey\(\s*`"Depth`"\s*\)") { $guarded = $true }
                }
            }
            $p = $p.Parent
        }
        if (-not $guarded) { $bad += $c.Extent.StartLineNumber }
    }
    return $bad
}
$calibration = @(Get-UnguardedDepthSites -Path $FixturePath)
if ($calibration.Count -ne 1) {
    [Console]::Error.WriteLine("depth guard: calibration found $($calibration.Count) unguarded site(s) in the fixture, expected 1")
    exit 1
}
$real = @(Get-UnguardedDepthSites -Path $ClientPath)
if ($real.Count -ne 0) {
    [Console]::Error.WriteLine("depth guard: unguarded ConvertFrom-Json -Depth at line(s): " + ($real -join ","))
    exit 1
}
"depth guard cases ok"
'
# The fixture path is passed as a NAMED PARAMETER to a -File script -- the same
# shape as the other -File fixtures in this check (win-probe.ps1,
# bom-driver.ps1), which the windows CI job runs under real 5.1.  Those cases
# pass there with POSIX /tmp paths, which is the evidence that this one can too
# (Git Bash converts arguments for native binaries; that mechanism is inference,
# the passing cases are the measurement).  Only the client path gets an explicit
# cygpath at the top, because the check invokes the client through -File from
# contexts where no conversion happens.  This block runs under 5.1 in CI too.
printf '%s\n' "$depth_probe" > "$work/depth-guard.ps1"
status=0
"$pwsh_binary" -NoProfile -NonInteractive -File "$work/depth-guard.ps1" \
    -FixturePath "$work/depth-fixture.ps1" -ClientPath "$client_arg" \
    >"$work/out" 2>"$work/err" || status=$?
if [ "$status" -ne 0 ] || ! grep -qF 'depth guard cases ok' "$work/out"; then
    printf '%s\n' 'ps-client: a ConvertFrom-Json -Depth call is not guarded by Parameters.ContainsKey("Depth") (a parameter binding failure on Windows PowerShell 5.1)' >&2
    head -3 "$work/err" >&2 || true
    failures=$((failures + 1))
fi

# The launcher path is stated in FIVE places across the two clients -- the POSIX
# asset's protocol probe, its launcher wrapper (the ACTUAL invocation), and the
# Windows asset's probe plus two (invocation + diagnostic) -- and nothing else
# can keep them in step.  Measured 2026-10-20: editing the Windows asset's
# invocation line alone left every case above green, because the probe -- the
# only path these cases exercise -- still read the old value.  A probe that
# checks a path the client would never call is a false green.  So: extract every
# occurrence of the path from both assets (both slash styles), normalize, and
# require ONE value across the pair.  Reading them from the assets (not a
# literal here) is the whole point: a literal is a second source of truth that
# drifts on its own.
cases=$((cases + 1))
launcher_parity=$(python3 - "$root" <<'PYPARITY' 2>&1
import io, re, sys
root = sys.argv[1]
# Any .ps1 under ProgramData\\AgentQ, in either slash style -- a rename of ONE
# site must read as a second value, not as an invisible non-match.
pattern = re.compile(r'[A-Za-z]:[\\/]ProgramData[\\/]AgentQ[\\/][A-Za-z0-9._-]+\.ps1')
found = {}
for rel in ('skill/assets/client/unix/agentq', 'skill/assets/client/windows/agentq.ps1'):
    text = io.open(root + '/' + rel, encoding='utf-8').read()
    values = {m.group(0).replace(chr(92), '/') for m in pattern.finditer(text)}
    if len(values) != 1:
        sys.exit('%s names %d launcher paths %r; expected exactly one'
                  % (rel, len(values), sorted(values)))
    found[rel] = values.pop()
if len(set(found.values())) != 1:
    sys.exit('the launcher path drifts between the two clients: %r' % found)
print('ok')
PYPARITY
) || true
if [ "$launcher_parity" != ok ]; then
    printf 'ps-client: the two clients do not name the same Windows launcher path: %s\n' "$launcher_parity" >&2
    failures=$((failures + 1))
fi

# cancel exit 4: the CODE is the contract, the body is decoration.  Until
# 2026-10-21 Invoke-Mutation replaced 4 with 2 whenever the body failed its
# `cancellation_pending` validation -- i.e. it reported "protocol/parameter
# error, fix your arguments and retry" for the one state whose documented
# meaning is "the server cannot decide safely; STOP, do not retry".  The POSIX
# twin's behaviour is pinned in smoke/05; this is the same lock on this copy,
# driven by overriding Invoke-SshLogged rather than a stub binary.
cases=$((cases + 1))
cancel4_probe='
$ErrorActionPreference = "Stop"
. "__CLIENT__" 2>$null
function Invoke-SshLogged {
    param([string]$RemoteCommand, [AllowNull()][string]$InputPayload)
    return [pscustomobject]@{ ExitCode = 4; Output = $script:FakeCancelBody; Diagnostics = "" }
}
$bad = 0
$script:FakeCancelBody = "{`"task_id`":1,`"state`":`"bogus_state`"}"
$code = Invoke-Mutation -OperationName "cancel" -Invocation ([pscustomobject]@{ Command = "x"; Input = "" }) -ExpectedTaskId "1"
if ($code -ne 4) { [Console]::Error.WriteLine("cancel with exit 4 and an unvalidated body returned $code, expected 4"); $bad += 1 }
$script:FakeCancelBody = "{`"task_id`":1,`"state`":`"cancellation_pending`",`"cancellation_requested_at`":`"2026-10-21T00:00:00Z`"}"
$code = Invoke-Mutation -OperationName "cancel" -Invocation ([pscustomobject]@{ Command = "x"; Input = "" }) -ExpectedTaskId "1"
if ($code -ne 4) { [Console]::Error.WriteLine("cancel with exit 4 and a valid cancellation_pending body returned $code, expected 4"); $bad += 1 }
if ($bad -eq 0) { [Console]::Out.WriteLine("cancel4-ok") }
'
cancel4_probe=${cancel4_probe//__CLIENT__/$client_arg}
cases=$((cases + 1))
cancel4_status=0
cancel4_out=$("$pwsh_binary" -NoProfile -NonInteractive -Command "$cancel4_probe" 2>"$work/cancel4.err") || cancel4_status=$?
if [ "$cancel4_status" -ne 0 ] || ! grep -qF 'cancel4-ok' <<< "$cancel4_out"; then
    printf 'ps-client: cancel with exit 4 does not preserve the code (exit %s)\n' "$cancel4_status" >&2
    head -3 "$work/cancel4.err" >&2 || true
    failures=$((failures + 1))
fi

# The success line is printed only AFTER the failure gate: until 2026-10-16 it
# came first, so a red run printed "checks passed: cases=..." and then the
# failures on stderr -- a tail of stdout alone read as a green summary.
if [ "$failures" -ne 0 ]; then
    printf 'ps-client-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi

printf 'ps-client-contract checks passed: cases=%s twin=%s pwsh=%s ps51=%s reason=forwarded/injection-safe modes=validated\n' \
    "$cases" "$twin_state" "$ps_version" "$ps51_state"
