#!/usr/bin/env bash
# Smoke: the POSIX `sshp` client's LOCAL contract.  No remote is contacted -- a
# stub `SSHP_SSH` answers the platform probe and records the argv it was given.
#
# Why this check exists: `assets/client/unix/sshp` is 1,346 lines and, before
# this file, NOTHING in the suite had ever executed it.  `01` parses it
# (`sh -n`), `10` asserts a couple of installer invariants about other files,
# and that was the whole of it.  Together with `sshp.ps1` (1,361 lines) it is
# the largest zero-coverage asset in the repo -- and unlike the installers it is
# not a one-shot tool: it is the interactive session path a human uses every
# day.
#
# Shape, borrowed from `05-client-contract` and `11-installer-contract`: assert
# the CONTRACT, not the success path.  A real session needs a remote host with
# tmux/screen/Zellij, so the reachable surface on this machine is the local
# validation, the probe dispatch, and the reconnect policy.  Those are exactly
# the parts that can be wrong without anyone noticing.
#
# The one case that is genuinely security-relevant: the session name is
# interpolated into a REMOTE SHELL COMMAND (`exec tmux new-session -A -s
# '$session'`).  The only thing standing between a session name and command
# injection on the remote host is the `*[!A-Za-z0-9_.-]*` guard, so it is
# asserted directly and in both directions.
#
# NOT covered, and this is the honest limit:
#   - any real remote.  The stub is not ssh; it proves what sshp SENDS, not what
#     a real sshd does with it.
#   - the interactive session itself (`run_ssh_logged` with `-tt`).  Reaching it
#     needs a remote that answers the probe as READY; the stub can fake the
#     probe, but the session then blocks on a terminal.  The argv it WOULD use
#     is asserted instead, by reading it out of the probe/session option sets.
#   - the Windows path (`run_windows_remote_command`, the expect script, the
#     mkfifo fallback).  It needs a Windows target; only the MINGW routing
#     decision is asserted here.
#   - the remote install path.  It runs a package manager on the remote host.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
client="$root/skill/assets/client/unix/sshp"
# The asset path is overridable so a mutated copy can drive this check (mirrors
# smoke/05's AGENTQ_SMOKE_CLIENT); without it the trap-window locks below could
# not be proven to go red.
client=${AGENTQ_SMOKE_CLIENT:-$client}
[ -f "$client" ] || { printf '%s\n' 'sshp-contract: missing client asset' >&2; exit 1; }

# sshp walks every path component and rejects symlinks (runtime_path_is_safe),
# and on macOS /tmp IS a symlink to /private/tmp -- so a plain `mktemp -d` under
# /tmp is rejected as "temporary directory is not a safe directory" before any
# case runs.  `pwd -P` resolves it.  Same idiom as smoke/05 and smoke/11.
work=$(mktemp -d /tmp/agentq-smoke-sshp.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
cleanup_sandbox() { rm -rf -- "$work"; }
trap cleanup_sandbox EXIT HUP INT TERM

home="$work/home"
mkdir -p "$home" "$work/bin" "$work/tmp"
printf 'y\n' > "$work/yes-stdin"
# sshp puts its runtime directory under TMPDIR and removes it in the EXIT trap.
# Pointing TMPDIR at a sandbox directory is what turns "leaves no residue" into
# an assertion instead of a hope.
export TMPDIR="$work/tmp"

calls="$work/calls"
: >"$calls"

# ---------------------------------------------------------------------------
# A stub ssh.  It does three things: record the argv it received, emit whatever
# stdout the current case asked for, and exit with the status that case asked
# for.  Control is by FILE, not by environment variable, so a case cannot leak
# its setting into the next one.
#
# `-E <file>` is honoured: sshp passes it on every call, and the reconnect case
# depends on the transport-error line landing in that file (sshp reads the file,
# not stderr -- writing the fixture to stderr would be modelling a transport
# that does not exist, which is the mistake smoke/05 already made once).
# ---------------------------------------------------------------------------
cat > "$work/bin/ssh" <<'STUB'
#!/bin/sh
# SSHP_STUB_DIR holds: responses (one "<status>\t<stdout>" line per call),
# logfile-lines (lines to append to the -E file on call N), count, argv.N
stub_dir=$SSHP_STUB_DIR
n=$(cat "$stub_dir/count" 2>/dev/null || true)
n=${n:-0}
n=$((n + 1))
printf '%s' "$n" > "$stub_dir/count"

# Record argv NUL-separated so a multi-line argument (the probe command is a
# multi-line shell script) stays one field.
: > "$stub_dir/argv.$n"
for arg in "$@"; do
    printf '%s\0' "$arg" >> "$stub_dir/argv.$n"
done

# Append this call's diagnostic lines to the -E file, if any.
logfile=
prev=
for arg in "$@"; do
    if [ "$prev" = "-E" ]; then logfile=$arg; break; fi
    prev=$arg
done
if [ -n "$logfile" ]; then
    sed -n "${n}p" "$stub_dir/logfile-lines" 2>/dev/null | while IFS= read -r line; do
        [ -n "$line" ] && printf '%s\n' "$line" >> "$logfile"
    done
fi

line=$(sed -n "${n}p" "$stub_dir/responses")
# Past the end of the plan, repeat the LAST line rather than answering nothing.
# Answering nothing is not a neutral default: an empty probe output sends sshp
# down the "unexpected Windows response" branch, so a case that merely ran after
# a previous case would fail for a reason that has nothing to do with sshp.
# Measured: that is exactly how the first version of this check reported a
# phantom failure on a correct asset.
if [ -z "$line" ]; then
    line=$(sed -n '$p' "$stub_dir/responses")
fi
status=${line%%	*}
stdout=${line#*	}
[ -n "$stdout" ] && printf '%s\n' "$stdout"
exit "${status:-0}"
STUB
chmod 700 "$work/bin/ssh"

# Plan the stub's per-call behaviour.  $1 = tab-separated "status<TAB>stdout"
# lines; $2 = optional tab-separated per-call lines to append to the -E file.
plan_stub() {
    printf '%s\n' "$1" > "$work/responses"
    if [ "$#" -ge 2 ]; then printf '%s\n' "$2" > "$work/logfile-lines"
    else : > "$work/logfile-lines"; fi
    # `: >` rather than writing '0': a file containing "0" is still NON-EMPTY,
    # so `[ -s count ]` would read as "ssh was called" on a run that never
    # called it.  That mistake made the --help case fail on its first run.
    : > "$work/count"
    rm -f "$work"/argv.*
    printf '%s' "$work" > "$work/stubdir"
}

cases=0
failures=0
stub_dir="$work"

# run_case <name> <expected-status> <expected-stderr-substring> [--] <args...>
# Every case runs against the sandbox HOME, the sandbox TMPDIR, and the stub.
# `env -i` is deliberately NOT used: sshp legitimately reads SSHP_* and HOME.
run_case() {
    local name=$1 expected_status=$2 expected_message=$3
    shift 3
    [ "${1:-}" = "--" ] && shift
    cases=$((cases + 1))
    local status=0
    SSHP_STUB_DIR="$stub_dir" \
    SSHP_SSH="$work/bin/ssh" \
    HOME="$home" TMPDIR="$work/tmp" \
    PATH="$work/bin:/usr/bin:/bin" \
        /bin/sh "$client" "$@" >"$work/out" 2>"$work/err" || status=$?
    if [ "$status" -ne "$expected_status" ]; then
        printf 'sshp-contract: %s: expected exit %s, got %s\n' \
            "$name" "$expected_status" "$status" >&2
        sed 's/^/    stderr: /' "$work/err" >&2
        failures=$((failures + 1))
        return 0
    fi
    if [ -n "$expected_message" ] && ! grep -qF -- "$expected_message" "$work/err"; then
        printf 'sshp-contract: %s: stderr did not contain %s\n' \
            "$name" "$expected_message" >&2
        sed 's/^/    stderr: /' "$work/err" >&2
        failures=$((failures + 1))
    fi
}

# ---------------------------------------------------------------------------
# Argument validation.  These run before any ssh call, so the stub is irrelevant
# to them -- but it is installed anyway, so that a regression which moves the
# validation AFTER the first ssh call is caught as a stub call rather than
# silently reaching the network.
# ---------------------------------------------------------------------------
plan_stub '0	__SSHP_READY__:Linux'

run_case 'no arguments'            2 'Usage:'
run_case 'three arguments'         2 'Usage:' -- smoke-host session extra
run_case 'empty host'              2 'must not be empty or begin with a hyphen' -- ''
run_case 'host beginning with -'   2 'must not be empty or begin with a hyphen' -- -oProxyCommand=evil
# An EMPTY session name is legal, not an error: the asset reads
# `session=${2:-ghostty}`, and `:-` substitutes on null as well as unset, so an
# empty string falls back to the default.  Asserting a refusal here would have
# been asserting a contract the asset never had.  It is pinned as an ACCEPTANCE
# case in the probe section instead.
run_case 'session name with space' 2 'session name must contain only' -- smoke-host 'a b'
run_case 'session name with slash' 2 'session name must contain only' -- smoke-host 'a/b'
# The security-relevant one.  The session name is interpolated into a remote
# shell command inside single quotes; a quote or a semicolon here would be
# command injection on the remote host.  Both directions are asserted below:
# this case must be REFUSED, and a legal name must be ACCEPTED.
run_case 'session name with quote' 2 'session name must contain only' -- smoke-host "a'; touch /tmp/pwned; '"
run_case 'session name with semi'  2 'session name must contain only' -- smoke-host 'a;id'

# ---------------------------------------------------------------------------
# Environment validation.
# ---------------------------------------------------------------------------
cases=$((cases + 1))
if SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/bin/ssh" HOME="$home" TMPDIR="$work/tmp" \
        PATH="$work/bin:/usr/bin:/bin" SSHP_RECONNECT_DELAY=abc \
        /bin/sh "$client" smoke-host >"$work/out" 2>"$work/err"; then status=0; else status=$?; fi
if [ "$status" -ne 2 ] || ! grep -qF 'SSHP_RECONNECT_DELAY must be a non-negative integer' "$work/err"; then
    printf 'sshp-contract: SSHP_RECONNECT_DELAY=abc: expected exit 2 with the delay message, got %s\n' "$status" >&2
    failures=$((failures + 1))
fi

cases=$((cases + 1))
if SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/not-executable" HOME="$home" TMPDIR="$work/tmp" \
        PATH="$work/bin:/usr/bin:/bin" \
        /bin/sh "$client" smoke-host >"$work/out" 2>"$work/err"; then status=0; else status=$?; fi
if [ "$status" -ne 2 ] || ! grep -qF 'SSHP_SSH is not executable' "$work/err"; then
    printf 'sshp-contract: unusable SSHP_SSH: expected exit 2 with the executable message, got %s\n' "$status" >&2
    failures=$((failures + 1))
fi

# `[ -x ]` is TRUE for a directory (it tests the search bit), so a directory
# passed the SSHP_SSH guard and the failure came back as exit 126 with a
# MISLEADING message ("remote dependency probe failed for both Unix and
# Windows shells" -- blaming the remote for a local misconfiguration).
# Measured 2026-10-27; the Windows twin refuses the same input with exit 2.
cases=$((cases + 1))
mkdir -p "$work/ssh-dir"
if SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/ssh-dir" HOME="$home" TMPDIR="$work/tmp" \
        PATH="$work/bin:/usr/bin:/bin" \
        /bin/sh "$client" --check smoke-host >"$work/out" 2>"$work/err"; then status=0; else status=$?; fi
if [ "$status" -ne 2 ] || ! grep -qF 'SSHP_SSH must be a regular file' "$work/err"; then
    printf 'sshp-contract: SSHP_SSH=directory: expected exit 2 naming the shape, got %s [%s]\n' \
        "$status" "$(head -1 "$work/err")" >&2
    failures=$((failures + 1))
fi
if grep -qF 'remote dependency probe failed' "$work/err"; then
    printf '%s\n' 'sshp-contract: SSHP_SSH=directory: the failure was blamed on the remote host' >&2
    failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# --help is a success path and must not touch ssh.
# ---------------------------------------------------------------------------
cases=$((cases + 1))
if SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/bin/ssh" HOME="$home" TMPDIR="$work/tmp" \
        PATH="$work/bin:/usr/bin:/bin" \
        /bin/sh "$client" --help >"$work/out" 2>"$work/err"; then status=0; else status=$?; fi
if [ "$status" -ne 0 ] || ! grep -qF 'Usage:' "$work/out"; then
    printf 'sshp-contract: --help: expected exit 0 with usage on stdout, got %s\n' "$status" >&2
    failures=$((failures + 1))
fi
if [ -s "$work/count" ]; then
    printf 'sshp-contract: --help invoked ssh; it must not\n' >&2
    failures=$((failures + 1))
fi

# Help is recognised on the first token after the optional --check, like the
# Windows twin.  `--check --help` used to fall through to host validation and
# exit 2 here while `sshp.ps1 --check --help` printed usage and exited 0
# (measured 2026-10-17); smoke/20's help-after-check case pins the ps1 side,
# this pins the POSIX side of the same contract.  --check alone must still
# reach the probe -- a guard that swallowed every token after --check would
# pass the help case and break the client.
cases=$((cases + 1))
if SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/bin/ssh" HOME="$home" TMPDIR="$work/tmp" \
        PATH="$work/bin:/usr/bin:/bin" \
        /bin/sh "$client" --check --help >"$work/out" 2>"$work/err"; then status=0; else status=$?; fi
if [ "$status" -ne 0 ] || ! grep -qF 'Usage:' "$work/out"; then
    printf 'sshp-contract: --check --help: expected exit 0 with usage on stdout, got %s\n' "$status" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/bin/ssh" HOME="$home" TMPDIR="$work/tmp" \
        PATH="$work/bin:/usr/bin:/bin" \
        /bin/sh "$client" --check --check >"$work/out" 2>"$work/err"; then status=0; else status=$?; fi
if [ "$status" -eq 0 ]; then
    printf 'sshp-contract: --check --check: a repeated flag must not be treated as help or a host\n' >&2
    failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Probe dispatch.  Each case plans what the stub answers and asserts the exit
# code and message sshp derives from it.
# ---------------------------------------------------------------------------
plan_stub '0	__SSHP_READY__:Linux'
run_case 'check: unix ready' 0 '' -- --check smoke-host
if ! grep -qF 'persistent remote session: tmux, GNU screen, or Zellij' "$work/out"; then
    printf 'sshp-contract: --check ready: did not report the unix session kind\n' >&2
    failures=$((failures + 1))
fi

# An empty session name must be ACCEPTED and fall back to the default, not
# refused.  This is the other half of the guard asserted above: a guard that
# rejected everything would pass those cases and fail this one.  The Windows
# twin assigned the empty string and then refused it until 2026-10-17, so the
# same input was accepted by one client and rejected by the other.
run_case 'empty session name is accepted' 0 '' -- --check smoke-host ''

# A whitespace-only host must be refused.  The Windows twin's IsNullOrWhiteSpace
# rejected it from the start; this side only refused '' and '-', so a name that
# ssh would have to quote its way through reached ssh (2026-10-17).
run_case 'whitespace host is refused' 2 'SSH host must not contain whitespace' -- --check ' '
# ... and ANY whitespace, not only a whitespace-only name.  `*[[:space:]]*` is
# the guard; a whitespace-only case alone cannot distinguish it from an
# IsNullOrWhiteSpace-style test, and the Windows twin had exactly that weaker
# form until 2026-10-17 (measured: `sshp.ps1 --check 'foo bar'` exited 0 and
# ran the probe while this side refused).  The tab form is here because
# `[[:space:]]` covers it and a space-only fixture would not notice a guard
# that only looked for ' '.
run_case 'host with an embedded space is refused' 2 'SSH host must not contain whitespace' -- --check 'foo bar'
run_case 'host with an embedded tab is refused' 2 'SSH host must not contain whitespace' -- --check "$(printf 'host\ttab')"

# The reconnect delay is a 32-bit non-negative integer on BOTH clients.  The
# charset-only check here accepted a 20-digit value and the failure surfaced
# later as a bare `sleep` usage error with exit 1 -- a code the contract does
# not define, disconnected from the variable that caused it (measured
# 2026-10-17).  Both bounds are asserted: the largest legal value passes, one
# past it is refused.
reconnect_boundary_case() {
    local name=$1 value=$2 expected=$3
    cases=$((cases + 1))
    local status=0
    plan_stub "$(printf '0\t__SSHP_READY__:Linux')"
    SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/bin/ssh" SSHP_RECONNECT_DELAY="$value" \
    HOME="$home" TMPDIR="$work/tmp" PATH="$work/bin:/usr/bin:/bin" \
        /bin/sh "$client" --check smoke-host >"$work/out" 2>"$work/err" || status=$?
    if [ "$status" -ne "$expected" ]; then
        printf 'sshp-contract: %s: expected exit %s, got %s\n' "$name" "$expected" "$status" >&2
        sed 's/^/    stderr: /' "$work/err" >&2
        failures=$((failures + 1))
    fi
}
reconnect_boundary_case 'reconnect delay at the 32-bit maximum is accepted' 2147483647 0
reconnect_boundary_case 'reconnect delay one past the 32-bit maximum is refused' 2147483648 2
reconnect_boundary_case 'reconnect delay with a leading plus is refused' '+5' 2

# `--check` must NEVER install.  The probe says a dependency is missing and a
# package manager exists; sshp must refuse rather than run the installer.  The
# assertion is two-sided: the exit code, AND that only ONE ssh call was made
# (an install attempt would be a second call).
plan_stub '42	__SSHP_INSTALL_REQUIRED__:Linux'
run_case 'check: missing dependency is not installed' 127 'tmux, GNU screen, or Zellij is required' -- --check smoke-host
# `cat` of an EMPTY file succeeds with empty output, so the old `|| printf 0`
# never fired and `[ "" -ne N ]` errored instead of counting (latent since the
# empty-stub case was masked by other assertions; fixed 2026-10-06).
calls_made=$(cat "$work/count" 2>/dev/null || printf '0')
calls_made=${calls_made:-0}
if [ "$calls_made" -ne 1 ]; then
    printf 'sshp-contract: --check with a missing dependency made %s ssh call(s); it must probe once and stop\n' "$calls_made" >&2
    failures=$((failures + 1))
fi

plan_stub '127	__SSHP_INSTALL_UNAVAILABLE__:Linux'
run_case 'check: no supported package manager' 127 'install tmux, GNU screen, or Zellij manually' -- --check smoke-host

# A flattened Windows install status (A5b).  An sshd whose DefaultShell is
# powershell.exe turns the probe's 42 into 1; the MARKER is the contract, not
# the exact code.  sshp.ps1 has been marker-first since 0.1.16; this side still
# demanded exactly 42, so the same answer was "installable" on the Windows
# client and "invalid Windows install status" (exit 2) here -- measured
# 2026-10-17.  --check must therefore answer 127 (installable, not installing),
# not 2.
plan_stub '43	__SSHP_WINDOWS_SHELL__:MINGW64_NT-10.0-19045
1	__SSHP_INSTALL_REQUIRED__:Windows'
run_case 'probe: flattened install status is still installable' 127     'native Zellij is required on Windows' -- --check smoke-host

# A marker must START a line.  The Windows twin matches `(?m)^...$`; this side
# matched the marker ANYWHERE in the output (glob), so a banner or shell-profile
# line that merely CONTAINS the phrase was read as a protocol answer.  Measured
# 2026-10-17: `banner: __SSHP_READY__:Linux is a phrase` was accepted as READY
# (exit 0) here while sshp.ps1 refused it (exit 2).  Each case below feeds a
# mid-line marker on the first call and a failing answer on the second (the
# client falls through to the Windows probe when the Unix answer is not
# recognised), and asserts the "both shells" verdict -- not READY, and not the
# Windows-only wording that a successful Windows-shell route would produce.
plan_stub '0	banner: __SSHP_READY__:Linux is a phrase
2	'
run_case 'probe: mid-line READY marker is not READY' 2 \
    'remote dependency probe failed for both Unix and Windows shells' -- --check smoke-host
plan_stub '42	note __SSHP_INSTALL_REQUIRED__:Linux here
2	'
run_case 'probe: mid-line INSTALL_REQUIRED marker is not installable' 2 \
    'remote dependency probe failed for both Unix and Windows shells' -- --check smoke-host
plan_stub '43	x __SSHP_WINDOWS_SHELL__:MINGW64 here
2	'
run_case 'probe: mid-line Windows shell marker does not route to Windows' 2 \
    'remote dependency probe failed for both Unix and Windows shells' -- --check smoke-host

# SKILL.md's promise -- "the first connection asks before installing it; with
# no TTY the client refuses explicitly and never installs silently" -- had no
# behavioural lock on EITHER client until 2026-10-17.  The stronger form is
# asserted: stdin is a PIPE carrying `y`, so a client that merely checked
# whether stdin had data (or read the answer without a tty test) would install.
# Three assertions: exit 1, the refusal message, and exactly ONE ssh call (the
# probe) -- an install attempt is a second call.
plan_stub '42	__SSHP_INSTALL_REQUIRED__:Linux'
cases=$((cases + 1))
install_status=0
SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/bin/ssh" HOME="$home" TMPDIR="$work/tmp" \
    PATH="$work/bin:/usr/bin:/bin" \
    /bin/sh "$client" smoke-host <"$work/yes-stdin" >"$work/out" 2>"$work/err" || install_status=$?
install_calls=$(cat "$work/count" 2>/dev/null || printf '0')
install_calls=${install_calls:-0}
if [ "$install_status" -ne 1 ]; then
    printf 'sshp-contract: piped-y install: expected exit 1, got %s\n' "$install_status" >&2
    sed 's/^/    stderr: /' "$work/err" >&2
    failures=$((failures + 1))
fi
if ! grep -qF 'dependency installation requires an interactive local terminal' "$work/err"; then
    printf 'sshp-contract: piped-y install: the no-tty refusal message is missing\n' >&2
    failures=$((failures + 1))
fi
if [ "$install_calls" -ne 1 ]; then
    printf 'sshp-contract: piped-y install: made %s ssh call(s); a piped confirmation must never reach the installer\n' "$install_calls" >&2
    failures=$((failures + 1))
fi

# A probe that reports INSTALL_UNAVAILABLE must be refused, not guessed at.
# The stub feeds the MARKER, so this case is about the client's routing, not
# about which platforms the probe treats as supported (that is the matrix
# below); the platform in the marker is irrelevant here.
plan_stub '127	__SSHP_INSTALL_UNAVAILABLE__:FreeBSD'
run_case 'check: unsupported platform' 127 'install tmux, GNU screen, or Zellij manually' -- --check smoke-host

# A MINGW probe answer routes to the Windows path.  The evidence is the MESSAGE:
# "for the Windows shell" is emitted only when windows_probe_required is true,
# and the alternative wording ("for both Unix and Windows shells") is what a
# non-Windows routing produces.  The exit code is the stub's own status
# propagated through, so it is asserted too but it is the weaker of the two.
# The Windows probe itself needs a real PowerShell and is out of scope here.
plan_stub '43	__SSHP_WINDOWS_SHELL__:MINGW64_NT-10.0-19045'
run_case 'probe: MINGW routes to the Windows path' 43 \
    'remote dependency probe failed for the Windows shell' -- --check smoke-host

# ---------------------------------------------------------------------------
# Transport-error reconnect.  The stub fails call 1 with 255 AND a transport
# line in the -E log, then answers READY on call 2.  sshp must reconnect (not
# give up) and then succeed -- so the assertion is "exit 0 after exactly two
# calls", which a policy that gave up would fail and a policy that retried
# forever would hang on.
# ---------------------------------------------------------------------------
plan_stub '255	'$'\n''0	__SSHP_READY__:Linux' \
          $'ssh: connect to host smoke-host port 22: Connection refused'
cases=$((cases + 1))
if SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/bin/ssh" HOME="$home" TMPDIR="$work/tmp" \
        PATH="$work/bin:/usr/bin:/bin" SSHP_RECONNECT_DELAY=0 \
        /bin/sh "$client" --check smoke-host >"$work/out" 2>"$work/err"; then status=0; else status=$?; fi
if [ "$status" -ne 0 ]; then
    printf 'sshp-contract: transport reconnect: expected exit 0 after the retry, got %s\n' "$status" >&2
    sed 's/^/    stderr: /' "$work/err" >&2
    failures=$((failures + 1))
fi
if ! grep -qF 'initial SSH transport lost; reconnecting' "$work/err"; then
    printf 'sshp-contract: transport reconnect: did not report the lost transport\n' >&2
    failures=$((failures + 1))
fi
# `cat` of an EMPTY file succeeds with empty output, so the old `|| printf 0`
# never fired and `[ "" -ne N ]` errored instead of counting (latent since the
# empty-stub case was masked by other assertions; fixed 2026-10-06).
calls_made=$(cat "$work/count" 2>/dev/null || printf '0')
calls_made=${calls_made:-0}
if [ "$calls_made" -ne 2 ]; then
    printf 'sshp-contract: transport reconnect: made %s ssh call(s); expected exactly 2 (fail, retry)\n' "$calls_made" >&2
    failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# --check must NOT retry a persistently-dropped transport forever.  The
# interactive session path may (a human is watching and can Ctrl-C), but --check
# is the non-interactive, read-only probe: a remote that accepts the TCP
# connection and then drops it would spin the `while :` reconnect loop with no
# terminal and no human.  The stub now fails EVERY call with 255 + a transport
# line, so an unbounded loop would never return; the assertion is "returns 255
# after a bounded number of calls".
# ---------------------------------------------------------------------------
# Every call needs its own transport line: the stub writes logfile-lines line N
# to the -E file on call N (past the end it writes nothing), and sshp only
# reconnects when the -E log actually shows a transport error.
transport_line='ssh: connect to host smoke-host port 22: Connection refused'
# The stub repeats the LAST responses line past the end, so a single "255" line
# makes every call fail; logfile-lines, though, is read per call index, so it
# needs one transport line per call.
printf '255	\n255	__SSHP_READY__:Linux\n' > "$work/responses"
printf '%s\n' "$transport_line" "$transport_line" "$transport_line" "$transport_line" "$transport_line" > "$work/logfile-lines"
: > "$work/count"
rm -f "$work"/argv.*
printf '%s' "$work" > "$work/stubdir"
cases=$((cases + 1))
check_loop_status=0
if SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/bin/ssh" HOME="$home" TMPDIR="$work/tmp"         PATH="$work/bin:/usr/bin:/bin" SSHP_RECONNECT_DELAY=0         /bin/sh "$client" --check smoke-host >"$work/out" 2>"$work/err"; then check_loop_status=0; else check_loop_status=$?; fi
if [ "$check_loop_status" -ne 255 ]; then
    printf 'sshp-contract: --check transport loop: expected exit 255 after a bounded retry budget, got %s (an unbounded --check would hang here)\n' \
        "$check_loop_status" >&2
    failures=$((failures + 1))
fi
if ! grep -qF -- '--check does not retry forever' "$work/err"; then
    printf '%s\n' 'sshp-contract: --check transport loop: did not report the bounded-retry give-up' >&2
    failures=$((failures + 1))
fi
check_loop_calls=$(cat "$work/count" 2>/dev/null || printf '0')
check_loop_calls=${check_loop_calls:-0}
# 1 initial + at most the --check budget (3); a policy that gave up immediately
# would be 1, and an unbounded one would never reach this line.
if [ "$check_loop_calls" -lt 2 ] || [ "$check_loop_calls" -gt 4 ]; then
    printf 'sshp-contract: --check transport loop: made %s ssh call(s); expected between 2 and 4\n' \
        "$check_loop_calls" >&2
    failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# The option set sshp sends.  Read out of the recorded argv rather than out of
# the source: a source-level assertion cannot tell whether the options were
# actually passed to ssh.
#
# sshp deliberately does NOT send BatchMode -- unlike the `agentq` client, it is
# an interactive session tool and must be able to prompt.  Asserting the absence
# is the point: if someone "fixes" sshp by copying agentq's option builder, the
# password path silently stops working.
# ---------------------------------------------------------------------------
plan_stub '0	__SSHP_READY__:Linux'
SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/bin/ssh" HOME="$home" TMPDIR="$work/tmp" \
    PATH="$work/bin:/usr/bin:/bin" \
    /bin/sh "$client" --check smoke-host >/dev/null 2>&1 || true
if [ -f "$work/argv.1" ]; then
    tr '\0' '\n' < "$work/argv.1" > "$work/argv1.txt"
    for expected in '-E' 'LogLevel=ERROR' '-T' 'ConnectTimeout=10' \
                    'ServerAliveInterval=10' 'ServerAliveCountMax=6' 'TCPKeepAlive=yes'; do
        if ! grep -qxF -- "$expected" "$work/argv1.txt"; then
            printf 'sshp-contract: the probe did not pass %s to ssh\n' "$expected" >&2
            failures=$((failures + 1))
        fi
    done
    if grep -qF 'BatchMode' "$work/argv1.txt"; then
        printf 'sshp-contract: sshp sent BatchMode; it is an interactive tool and must not\n' >&2
        failures=$((failures + 1))
    fi
    # The host must be passed as its own argv element after `--`, so a hostname
    # that looks like an option can never be read as one.
    if ! grep -qxF -- 'smoke-host' "$work/argv1.txt"; then
        printf 'sshp-contract: the host was not passed as its own argument\n' >&2
        failures=$((failures + 1))
    fi
else
    printf 'sshp-contract: the probe made no ssh call, so no argv could be checked\n' >&2
    failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# The two sshp clients embed ONE remote dependency probe and ONE remote
# installer.
# ---------------------------------------------------------------------------
# Why this section exists (docs/PLAN.md 第四十五类): both clients carry the
# probe and the installer as a single-quoted shell string / a PowerShell
# here-string, and NOTHING ran either one.  `14` measured their LENGTH, `20`
# measured the Windows side's encoding, and the `plan_stub` cases here feed the
# POSIX client CANNED markers -- so the two bodies could answer different
# things, and did, with every check green.
#
# Measured 2026-10-28 by executing both extracted bodies against a fake `uname`
# and a fake PATH:
#   * FreeBSD with tmux: the POSIX body said 127 `__SSHP_INSTALL_UNAVAILABLE__`
#     ("install tmux ... manually" -- on a host that HAS tmux), the Windows body
#     said 0 READY.  The platform allow-list sat BEFORE the readiness check,
#     and the session command (`exec tmux new-session ...`) is portable shell
#     that needs no platform at all.
#   * Linux with only Homebrew: the POSIX body said 42 INSTALL_REQUIRED, the
#     Windows body said 127 UNAVAILABLE -- while BOTH clients' install bodies
#     are a flat apt/dnf/yum/pacman/zypper/apk/brew/port list, so the Windows
#     probe refused an install the same client would have performed.
#
# The rule is therefore two-sided, and both sides are asserted: the bodies are
# byte-identical, AND each one answers every row of the matrix below from an
# absolute oracle (a comparison that only asked "do they agree" would pass if
# both drifted the same way).  The self-test at the end re-adds the platform
# gate to a copy and requires the FreeBSD row to go red, so the matrix is
# proven able to see the defect it was written for.
sshp_ps_client=${AGENTQ_SMOKE_SSHP_PS_CLIENT:-$root/skill/assets/client/windows/sshp.ps1}
if [ ! -f "$sshp_ps_client" ]; then
    printf 'sshp-contract: missing the Windows sshp asset: %s\n' "$sshp_ps_client" >&2
    exit 1
fi

# extract_posix_body <file> <variable-name> -> the body on stdout.
# The body is the text between `<var>='` and the next line that is exactly `'`.
extract_posix_body() {
    awk -v var="$2" -v q="'" '
        $0 == var "=" q { inside = 1; next }
        inside && $0 == q { exit }
        inside { print }
    ' "$1"
}
# extract_ps_body <file> <function-name> -> the body on stdout.
# The body is the text between `-Script @'` (inside that function) and the next
# line that is exactly `'@`.
extract_ps_body() {
    awk -v fn="function $2 {" -v open="    return Convert-ToPosixScriptCommand -Script @'" -v q="'" '
        $0 == fn { infn = 1; next }
        infn && $0 == open { inside = 1; next }
        inside && $0 == q "@" { exit }
        inside { print }
    ' "$1"
}

probe_posix="$work/remote-probe-posix.sh"
probe_win="$work/remote-probe-windows.sh"
install_posix="$work/remote-install-posix.sh"
install_win="$work/remote-install-windows.sh"
extract_posix_body "$client" remote_probe_command > "$probe_posix"
extract_ps_body "$sshp_ps_client" Get-UnixProbeCommand > "$probe_win"
extract_posix_body "$client" remote_install_command > "$install_posix"
extract_ps_body "$sshp_ps_client" Get-UnixInstallCommand > "$install_win"

# An extractor whose anchor moved yields an EMPTY body, and comparing two empty
# bodies is green.  Refuse to compare anything that is not the script it claims
# to be: every one of the four starts with `set -eu`.
for extracted in "$probe_posix" "$probe_win" "$install_posix" "$install_win"; do
    if ! grep -qx 'set -eu' "$extracted"; then
        printf 'sshp-contract: no remote script was extracted into %s (the anchor moved); refusing to compare two empty bodies\n' \
            "${extracted#"$work"/}" >&2
        failures=$((failures + 1))
    fi
done

# Both pairs must be the SAME text.  A divergence here is always a defect: the
# two clients face the same target with the same requirements.
cases=$((cases + 1))
if ! cmp -s "$probe_posix" "$probe_win"; then
    printf '%s\n' 'sshp-contract: the two clients embed DIFFERENT dependency probes:' >&2
    diff -u "$probe_posix" "$probe_win" >&2 || true
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if ! cmp -s "$install_posix" "$install_win"; then
    printf '%s\n' 'sshp-contract: the two clients embed DIFFERENT installers:' >&2
    diff -u "$install_posix" "$install_win" >&2 || true
    failures=$((failures + 1))
fi

# run_probe_body <body> <uname> [tool...] -> "<status>\t<stdout>"
# The target is modelled by a PATH that contains ONLY a lying `uname` and the
# named tools: a host tool left on PATH would answer `command -v` for a row
# that is meant to model its absence (measured 2026-10-28 -- prepending to the
# real PATH made every "nothing installed" row report a multiplexer).
run_probe_body() {
    local body=$1 uname_value=$2
    shift 2
    local fake status=0 out tool
    fake=$(mktemp -d "$work/fake-target.XXXXXX")
    printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$uname_value" > "$fake/uname"
    chmod 700 "$fake/uname"
    for tool in "$@"; do
        printf '#!/bin/sh\nexit 0\n' > "$fake/$tool"
        chmod 700 "$fake/$tool"
    done
    out=$(PATH="$fake" /bin/sh "$body" 2>/dev/null) || status=$?
    rm -rf -- "$fake"
    printf '%s\t%s' "$status" "$out"
}

# run_install_body <body> <uname> [installer...] -> "<status>\t<trace>"
# `id` answers 0 so `run_as_root` execs the installer directly (no sudo in the
# fake PATH), and every installer records "<tool> <args>" to a trace, so the
# comparison is on what WOULD RUN, not merely on an exit code.
run_install_body() {
    local body=$1 uname_value=$2
    shift 2
    local fake trace status=0 tool
    fake=$(mktemp -d "$work/fake-target.XXXXXX")
    trace="$work/fake-trace"
    : > "$trace"
    printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$uname_value" > "$fake/uname"
    printf '#!/bin/sh\nprintf "0\\n"\n' > "$fake/id"
    chmod 700 "$fake/uname" "$fake/id"
    for tool in "$@"; do
        printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 0\n' "$tool" "$trace" > "$fake/$tool"
        chmod 700 "$fake/$tool"
    done
    PATH="$fake" /bin/sh "$body" >/dev/null 2>&1 || status=$?
    rm -rf -- "$fake"
    printf '%s\t%s' "$status" "$(tr '\n' ';' < "$trace")"
}

# Rows: <uname>|<tools>|<expected status>|<expected stdout>.  `tools` is
# word-split on purpose -- it is this fixture's own text, never user input.
probe_matrix='Linux|tmux|0|__SSHP_READY__:Linux
Darwin|screen|0|__SSHP_READY__:Darwin
FreeBSD|tmux|0|__SSHP_READY__:FreeBSD
Linux||127|__SSHP_INSTALL_UNAVAILABLE__:Linux
FreeBSD||127|__SSHP_INSTALL_UNAVAILABLE__:FreeBSD
Linux|brew|42|__SSHP_INSTALL_REQUIRED__:Linux
Darwin|port|42|__SSHP_INSTALL_REQUIRED__:Darwin
MINGW64_NT-10.0-19045||43|__SSHP_WINDOWS_SHELL__:MINGW64_NT-10.0-19045'
probe_rows=0
while IFS='|' read -r row_uname row_tools row_status row_marker; do
    [ -n "$row_uname" ] || continue
    probe_rows=$((probe_rows + 1)); cases=$((cases + 1))
    expected=$(printf '%s\t%s' "$row_status" "$row_marker")
    # shellcheck disable=SC2086 # row_tools is this fixture's own word list
    got_posix=$(run_probe_body "$probe_posix" "$row_uname" $row_tools)
    # shellcheck disable=SC2086
    got_windows=$(run_probe_body "$probe_win" "$row_uname" $row_tools)
    if [ "$got_posix" != "$expected" ] || [ "$got_windows" != "$expected" ]; then
        printf 'sshp-contract: probe matrix [%s tools=%s]: expected [%s]\n  posix   got [%s]\n  windows got [%s]\n' \
            "$row_uname" "${row_tools:-<none>}" "$expected" "$got_posix" "$got_windows" >&2
        failures=$((failures + 1))
    fi
done <<< "$probe_matrix"

# The installer half.  A candidate the probe offers must be a command the
# installer actually runs -- that invariant is what the Windows side broke.
install_matrix='Linux|apt-get|0|apt-get update;apt-get install -y tmux;
Linux|brew|0|brew install tmux;
Darwin|port|0|port install tmux;
FreeBSD|pkg|127|
Linux||127|'
install_rows=0
while IFS='|' read -r row_uname row_tools row_status row_trace; do
    [ -n "$row_uname" ] || continue
    install_rows=$((install_rows + 1)); cases=$((cases + 1))
    expected=$(printf '%s\t%s' "$row_status" "$row_trace")
    # shellcheck disable=SC2086
    got_posix=$(run_install_body "$install_posix" "$row_uname" $row_tools)
    # shellcheck disable=SC2086
    got_windows=$(run_install_body "$install_win" "$row_uname" $row_tools)
    if [ "$got_posix" != "$expected" ] || [ "$got_windows" != "$expected" ]; then
        printf 'sshp-contract: install matrix [%s tools=%s]: expected [%s]\n  posix   got [%s]\n  windows got [%s]\n' \
            "$row_uname" "${row_tools:-<none>}" "$expected" "$got_posix" "$got_windows" >&2
        failures=$((failures + 1))
    fi
done <<< "$install_matrix"

# A matrix that stopped enumerating reports green on nothing.  The expected
# count is COMPUTED from the table (the twin table's rule: a literal cannot
# move when the coverage changes), and an independent FLOOR is kept under it so
# a table truncated together with its expectation still trips something.
probe_matrix_rows=$(grep -c . <<< "$probe_matrix")
install_matrix_rows=$(grep -c . <<< "$install_matrix")
cases=$((cases + 1))
if [ "$probe_rows" -ne "$probe_matrix_rows" ] || [ "$install_rows" -ne "$install_matrix_rows" ]; then
    printf 'sshp-contract: the remote-script matrix ran %s probe row(s) and %s install row(s); the tables declare %s and %s\n' \
        "$probe_rows" "$install_rows" "$probe_matrix_rows" "$install_matrix_rows" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if [ "$probe_matrix_rows" -lt 8 ] || [ "$install_matrix_rows" -lt 5 ]; then
    printf 'sshp-contract: the remote-script tables shrank to %s probe row(s) and %s install row(s); the floor is 8 and 5\n' \
        "$probe_matrix_rows" "$install_matrix_rows" >&2
    failures=$((failures + 1))
fi

# Self-test: the matrix must be able to SEE the defect this round fixed.
# Re-insert the platform allow-list (the exact pre-fix shape) after the MINGW
# case and require the FreeBSD+tmux row to stop being READY.  If the mutation
# does not apply, say so -- a self-test that silently did nothing passes on
# nothing.
probe_gated="$work/remote-probe-gated.sh"
awk '
    { print }
    $0 == "esac" && !done {
        print "case \"$platform\" in Darwin*|Linux*) ;; *) exit 127 ;; esac"
        done = 1
    }
' "$probe_posix" > "$probe_gated"
cases=$((cases + 1))
if cmp -s "$probe_posix" "$probe_gated"; then
    printf '%s\n' 'sshp-contract: probe matrix self-test: the platform-gate mutation did not apply; the matrix cannot be proven able to fail' >&2
    failures=$((failures + 1))
else
    gated_answer=$(run_probe_body "$probe_gated" FreeBSD tmux)
    if [ "$gated_answer" = "$(printf '0\t%s' '__SSHP_READY__:FreeBSD')" ]; then
        printf 'sshp-contract: probe matrix self-test: a probe carrying the old platform allow-list still answered READY for FreeBSD+tmux [%s]; the matrix cannot see the class it was written for\n' \
            "$gated_answer" >&2
        failures=$((failures + 1))
    fi
fi
remote_script_state="identical(2/2) matrix=$((probe_rows + install_rows))/$((probe_matrix_rows + install_matrix_rows))"

# ---------------------------------------------------------------------------
# The same contract for the pair ONE FILE OVER: the WINDOWS-target resolver,
# probe and installer that both clients embed.
# ---------------------------------------------------------------------------
# Why this section exists (docs/PLAN.md 第四十六类): the section above unified
# the two clients' UNIX-target bodies.  Both clients ALSO carry a Windows-target
# half -- a resolver prelude (`windows_common_script` / `Get-WindowsZellijResolver
# Script`) plus a probe and an installer that each concatenate it -- and that
# half had drifted into three different programs.  The extractors above cannot
# reach it: neither POSIX tail opens with `<var>='` (both are
# `$windows_common_script'` concatenations), and both Windows tails open with
# `-ScriptText ($resolver + @'`.
#
# Measured 2026-10-28 by extracting all three parts from both clients (pre-fix
# sizes: resolver 8105/8097, probe 580/637, install 736/1073 bytes) and driving
# the two INSTALL bodies through the real channel both clients use -- the payload
# on stdin to `pwsh -NoProfile -NonInteractive -Command -`, preceded by the two
# preamble lines and followed by the trailing blank line, with the resolver
# replaced by a stub.  Of the eleven rows below, five disagreed, and each side
# held one half the other was missing:
#   * no installer resolvable -- POSIX 127 with the intended one-line message,
#     Windows 1 with a `Write-Error:` block.  `$ErrorActionPreference = "Stop"`
#     makes Write-Error THROW, so the `exit 127` beneath it was dead code -- the
#     class agentq-start-daemon.ps1 fixed on 2026-10-07, and the last live
#     Write-Error left anywhere in skill/assets/.
#   * unsupported installer kind -- POSIX 127, Windows 1 with an `Exception:`
#     block (`throw` under the same preference).
#   * the installer call returns WITHOUT setting $LASTEXITCODE -- Windows 1 via
#     the fail-closed guard, POSIX **0**: a FAILED install reported as SUCCESS
#     (`exit $LASTEXITCODE` with the variable unset is `exit $null`).
# The probe tails differed too: only the Windows copy emitted
# `__SSHP_ZELLIJ__:<path>`.  The POSIX client never consumes that line (its
# Windows session command is `exec zellij attach --create` with a bare name --
# checked, not assumed), so this one was inert THERE; it is still a divergence
# of the same contract, and the Windows twin parses it into the path its session
# command embeds (`& '<path>' attach --create`), so a body that stopped emitting
# it would break that client alone.  The resolver also spelled one constructor
# two ways (`New-Object "…List[string]"` vs `[…]::new()`; pwsh 7.5 answers
# identically, measured).
#
# The rule is the round-45 rule applied to the Windows pair, and it is asserted
# the same two-sided way: the three parts are byte-identical, AND each body
# answers every row of the matrix from an absolute oracle -- a comparison that
# only asked "do they agree" would pass if both drifted the same way.  The
# resolver prelude is compared byte-for-byte but NOT executed: it calls
# WindowsIdentity, Get-Acl and the profile registry key, so only a Windows host
# can run it (the same boundary smoke/22 reports as windows-api=NOT-covered).
# The two tails ARE executed, with the resolver replaced by a stub -- the stub
# is this fixture's model of the target, exactly as the fake PATH above is.
#
# extract_posix_windows_part <file> <opening-line> -> the body on stdout.
# The body runs from a line that EQUALS the opening line to the next line that
# is exactly `'`.  The three openings differ (`windows_common_script='` assigns;
# the two tails are `$windows_common_script'` concatenations), so the opening
# line is passed in rather than derived.
extract_posix_windows_part() {
    awk -v open="$2" -v q="'" '
        $0 == open { inside = 1; next }
        inside && $0 == q { exit }
        inside { print }
    ' "$1"
}
# extract_ps_windows_part <file> <function-name> -> the here-string body.
# Anchored on `function <name> {` and then the FIRST line whose last two
# characters are `@'`, so a neighbouring function's here-string cannot be picked
# up; it ends at the first line that STARTS with `'@` (the tails close with
# `'@)`, the resolver with a bare `'@`).
extract_ps_windows_part() {
    awk -v fn="function $2 {" -v open_at="@" -v q="'" '
        $0 == fn { infn = 1; next }
        infn && !inside && substr($0, length($0) - 1) == open_at q { inside = 1; next }
        inside && substr($0, 1, 2) == q "@" { exit }
        inside { print }
    ' "$1"
}

win_resolver_posix="$work/win-resolver-posix.ps1"
win_resolver_win="$work/win-resolver-windows.ps1"
win_probe_posix="$work/win-probe-posix.ps1"
win_probe_win="$work/win-probe-windows.ps1"
win_install_posix="$work/win-install-posix.ps1"
win_install_win="$work/win-install-windows.ps1"
extract_posix_windows_part "$client" "windows_common_script='" > "$win_resolver_posix"
extract_ps_windows_part "$sshp_ps_client" Get-WindowsZellijResolverScript > "$win_resolver_win"
extract_posix_windows_part "$client" "windows_probe_script=\$windows_common_script'" > "$win_probe_posix"
extract_ps_windows_part "$sshp_ps_client" Get-WindowsProbeCommand > "$win_probe_win"
extract_posix_windows_part "$client" "windows_install_script=\$windows_common_script'" > "$win_install_posix"
extract_ps_windows_part "$sshp_ps_client" Get-WindowsInstallCommand > "$win_install_win"

# An anchor that moved yields an EMPTY body, and two empty bodies compare equal.
# A NON-empty wrong body is the other half of the same hazard, so the guard is a
# content sentinel unique to each part rather than a length test.
cases=$((cases + 1))
win_extract_bad=0
if ! grep -qF 'function Resolve-RemoteInstaller {' "$win_resolver_posix" ||
    ! grep -qF 'function Resolve-RemoteInstaller {' "$win_resolver_win"; then
    printf '%s\n' 'sshp-contract: no Windows dependency resolver was extracted from one of the two clients (the anchor moved); refusing to compare two empty bodies' >&2
    win_extract_bad=1
fi
cases=$((cases + 1))
if ! grep -qF '__SSHP_READY__:Windows' "$win_probe_posix" ||
    ! grep -qF '__SSHP_READY__:Windows' "$win_probe_win"; then
    printf '%s\n' 'sshp-contract: no Windows probe tail was extracted from one of the two clients (the anchor moved); refusing to compare two empty bodies' >&2
    win_extract_bad=1
fi
cases=$((cases + 1))
if ! grep -qF 'switch ($installer.Kind) {' "$win_install_posix" ||
    ! grep -qF 'switch ($installer.Kind) {' "$win_install_win"; then
    printf '%s\n' 'sshp-contract: no Windows install tail was extracted from one of the two clients (the anchor moved); refusing to compare two empty bodies' >&2
    win_extract_bad=1
fi
if [ "$win_extract_bad" -ne 0 ]; then
    failures=$((failures + 1))
fi

# Both sides must be the SAME text.  A divergence here is always a defect: the
# two clients face the same Windows target with the same requirements.
compare_windows_part() { # <label> <posix-file> <windows-file>
    cases=$((cases + 1))
    if cmp -s "$2" "$3"; then
        return 0
    fi
    printf 'sshp-contract: the two clients embed DIFFERENT Windows-target %s scripts:\n' "$1" >&2
    diff -u "$2" "$3" >&2 || true
    failures=$((failures + 1))
}
compare_windows_part resolver "$win_resolver_posix" "$win_resolver_win"
compare_windows_part probe "$win_probe_posix" "$win_probe_win"
compare_windows_part installer "$win_install_posix" "$win_install_win"
windows_script_state='identical(3/3)'

# --- The behavioural half.  Needs a WORKING pwsh. --------------------------
# Present is not the same as working (a corrupt startup cache makes every launch
# die -- five occurrences in this repo, four different messages), so the probe
# below runs before any case and an unusable interpreter is named as an
# ENVIRONMENT fault rather than reported as an asset defect.
pwsh_binary=${AGENTQ_SMOKE_PWSH:-$(command -v pwsh || true)}
windows_matrix_state='not-run'
if [ -z "$pwsh_binary" ] || ! command -v "$pwsh_binary" >/dev/null 2>&1; then
    printf '%s\n' 'sshp-contract: the Windows-target scripts were extracted and compared byte-for-byte, but NOT executed: no pwsh is available (skipped(pwsh-absent))'
    windows_matrix_state='skipped(pwsh-absent)'
else
    pwsh_probe_status=0
    "$pwsh_binary" -NoProfile -NonInteractive -Command 'exit 0' >/dev/null 2>&1 || pwsh_probe_status=$?
    if [ "$pwsh_probe_status" -ne 0 ]; then
        printf '%s\n' 'sshp-contract: the pwsh on PATH cannot execute (startup cache); the Windows-target scripts were compared but NOT executed -- an ENVIRONMENT fault, not an asset result' >&2
        printf '%s\n' 'Try: mv ~/.cache/powershell/StartupProfileData-NonInteractive{,.broken}' >&2
        windows_matrix_state='skipped(pwsh-unusable)'
        failures=$((failures + 1))
    else
        windows_matrix_state='run'
    fi
fi

if [ "$windows_matrix_state" = 'run' ]; then
    # The stub stands in for the resolver prelude.  Its SHAPE is the contract the
    # tails consume -- `Resolve-RemoteZellij` returns a path or $null,
    # `Resolve-RemoteInstaller` returns Kind+Path or $null -- and it is driven by
    # environment variables so each row can model one target state.
    win_stub="$work/win-resolver-stub.ps1"
    cat > "$win_stub" <<'POWERSHELL'
$script:SshpStubZellij = $env:SSHP_SMOKE_ZELLIJ
$script:SshpStubInstallerKind = $env:SSHP_SMOKE_INSTALLER_KIND
$script:SshpStubInstallerPath = $env:SSHP_SMOKE_INSTALLER_PATH
function Resolve-RemoteZellij {
    if ([string]::IsNullOrEmpty($script:SshpStubZellij)) { return $null }
    return $script:SshpStubZellij
}
function Resolve-RemoteInstaller {
    if ([string]::IsNullOrEmpty($script:SshpStubInstallerKind)) { return $null }
    return [pscustomobject]@{ Kind = $script:SshpStubInstallerKind; Path = $script:SshpStubInstallerPath }
}
POWERSHELL

    # Installer fixtures.  `zero`/`five` are native children that exit with that
    # status; `noexec` is a file the OS refuses to START (mode 0644), which is
    # this fixture's model of the CreateProcess failure a Windows AV or policy
    # would cause -- the call returns, a non-terminating error is recorded, and
    # $LASTEXITCODE is never set (measured 2026-10-17, and again here: success=
    # False, lastExitPresent=False).  `noop.ps1` is the same state reached
    # in-process, which needs no exec bit and is therefore portable.
    printf '#!/bin/sh\nexit 0\n' > "$work/win-installer-zero"
    printf '#!/bin/sh\nexit 5\n' > "$work/win-installer-five"
    printf '#!/bin/sh\nexit 7\n' > "$work/win-installer-noexec"
    chmod 700 "$work/win-installer-zero" "$work/win-installer-five"
    chmod 644 "$work/win-installer-noexec"
    printf '%s\n' '# no-op installer: an in-process call that never sets $LASTEXITCODE' > "$work/win-installer-noop.ps1"

    # run_windows_target_body <body> <zellij> <kind> <path> -> "<status>\t<stdout>\t<stderr>"
    # The channel is the clients' own: `$ProgressPreference` and
    # `$env:MSYS_NO_PATHCONV` first, then the script, then a BLANK line -- `-`
    # reads stdin in interactive mode and DISCARDS a pending block at EOF without
    # one (A20; measured again here: without it every row answers 0).
    run_windows_target_body() {
        local body=$1 status=0
        {
            printf '%s\n' '$ProgressPreference = "SilentlyContinue"'
            printf '%s\n' '$env:MSYS_NO_PATHCONV = "1"'
            cat "$win_stub"
            cat "$body"
            printf '\n'
        } > "$work/win-target-payload.ps1"
        SSHP_SMOKE_ZELLIJ="$2" SSHP_SMOKE_INSTALLER_KIND="$3" SSHP_SMOKE_INSTALLER_PATH="$4" \
            "$pwsh_binary" -NoProfile -NonInteractive -Command - \
            < "$work/win-target-payload.ps1" \
            > "$work/win-target-out" 2> "$work/win-target-err" || status=$?
        printf '%s\t%s\t%s' "$status" \
            "$(flatten_pwsh_stream "$work/win-target-out")" \
            "$(flatten_pwsh_stream "$work/win-target-err")"
    }
    # pwsh's console host emits ANSI cursor escapes on a pipe; they are noise,
    # not output.  CRLF is normalised because [Console]::Error.WriteLine on a
    # Windows target writes it and the twin's own marker matcher strips it.
    flatten_pwsh_stream() {
        sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$1" | tr -d '\r' | tr '\n' '|' | sed 's/^ *//; s/ *$//'
    }

    # Rows: <label>|<zellij>|<kind>|<path>|<expected status>|<stderr must contain>|
    # <stderr must NOT contain>.  The oracle is ABSOLUTE on purpose: the expected
    # values are the contract's, not the other body's answer.  The three rows the
    # pre-fix bodies failed are `no-installer`, `unsupported-kind` and
    # `call-sets-no-exit-code`; the "must NOT contain" column is what pins the
    # defect CLASS rather than one exit code -- `Write-Error:` and `Exception:`
    # are the two shapes the pre-fix Windows body produced.
    win_install_matrix="zellij-present|C:\\zellij.exe|||0||
no-installer||||127|sshp: no supported Windows installer found for Zellij.|Write-Error,Exception:
unsupported-kind||bogus|@WORK@/win-installer-zero|127|sshp: unsupported Windows installer: bogus|Write-Error,Exception:
installer-exits-5||winget|@WORK@/win-installer-five|5||
installer-exits-0||scoop|@WORK@/win-installer-zero|0||
call-sets-no-exit-code||choco|@WORK@/win-installer-noop.ps1|1||
cannot-start||choco|@WORK@/win-installer-noexec|1||
path-absent||winget|@WORK@/win-installer-absent|1||"
    win_install_rows=0
    while IFS='|' read -r row_label row_zellij row_kind row_path row_status row_err_must row_err_mustnot; do
        [ -n "$row_label" ] || continue
        win_install_rows=$((win_install_rows + 1)); cases=$((cases + 1))
        row_path=${row_path//@WORK@/$work}
        for side in posix windows; do
            if [ "$side" = posix ]; then
                body=$win_install_posix
            else
                body=$win_install_win
            fi
            got=$(run_windows_target_body "$body" "$row_zellij" "$row_kind" "$row_path")
            got_status=${got%%	*}
            got_rest=${got#*	}
            got_stdout=${got_rest%%	*}
            got_stderr=${got_rest#*	}
            why=''
            if [ "$got_status" != "$row_status" ]; then
                why="status $got_status, expected $row_status"
            fi
            if [ -n "$row_err_must" ]; then
                case $got_stderr in
                    *"$row_err_must"*) ;;
                    *) why="$why; stderr does not contain [$row_err_must]" ;;
                esac
            fi
            if [ -n "$row_err_mustnot" ]; then
                old_ifs=$IFS; IFS=','
                for forbidden in $row_err_mustnot; do
                    case $got_stderr in
                        *"$forbidden"*) why="$why; stderr contains [$forbidden] (a refusal must not be reported as a PowerShell error record)" ;;
                    esac
                done
                IFS=$old_ifs
            fi
            if [ -n "$why" ]; then
                printf 'sshp-contract: Windows install matrix [%s] on the %s body: %s (stdout=[%s] stderr=[%s])\n' \
                    "$row_label" "$side" "$why" "$got_stdout" "$got_stderr" >&2
                failures=$((failures + 1))
            fi
        done
    done <<< "$win_install_matrix"

    # The probe tail has its own oracle: the READY answer must carry the resolved
    # Zellij path (the session command embeds it -- smoke/14's M4 covers the same
    # property statically), and the two refusal answers must carry their markers
    # and their messages.
    win_probe_matrix="ready|C:\\zellij.exe|||0|__SSHP_READY__:Windows|__SSHP_ZELLIJ__:C:\\zellij.exe
install-required||winget|@WORK@/win-installer-zero|42|__SSHP_INSTALL_REQUIRED__:Windows|
unavailable||||127|__SSHP_INSTALL_UNAVAILABLE__:Windows|"
    win_probe_rows=0
    while IFS='|' read -r row_label row_zellij row_kind row_path row_status row_stdout_must row_stdout_mustnot; do
        [ -n "$row_label" ] || continue
        win_probe_rows=$((win_probe_rows + 1)); cases=$((cases + 1))
        row_path=${row_path//@WORK@/$work}
        for side in posix windows; do
            if [ "$side" = posix ]; then
                body=$win_probe_posix
            else
                body=$win_probe_win
            fi
            got=$(run_windows_target_body "$body" "$row_zellij" "$row_kind" "$row_path")
            got_status=${got%%	*}
            got_rest=${got#*	}
            got_stdout=${got_rest%%	*}
            why=''
            if [ "$got_status" != "$row_status" ]; then
                why="status $got_status, expected $row_status"
            fi
            if [ -n "$row_stdout_must" ]; then
                case $got_stdout in
                    *"$row_stdout_must"*) ;;
                    *) why="$why; stdout does not contain [$row_stdout_must]" ;;
                esac
            fi
            if [ -n "$row_stdout_mustnot" ]; then
                # The path line is asserted as a SEPARATE requirement rather than
                # as part of the READY marker: the pre-fix POSIX tail answered
                # READY without it, and a single-substring expectation would have
                # been satisfiable by a body that emitted the marker twice.
                case $got_stdout in
                    *"$row_stdout_mustnot"*) ;;
                    *) why="$why; stdout does not contain [$row_stdout_mustnot]" ;;
                esac
            fi
            if [ -n "$why" ]; then
                printf 'sshp-contract: Windows probe matrix [%s] on the %s body: %s (stdout=[%s])\n' \
                    "$row_label" "$side" "$why" "$got_stdout" >&2
                failures=$((failures + 1))
            fi
        done
    done <<< "$win_probe_matrix"

    # Row-count gates: computed from the tables, with an independent floor under
    # them (the same shape as the round-45 tables above).
    win_install_matrix_rows=$(grep -c . <<< "$win_install_matrix")
    win_probe_matrix_rows=$(grep -c . <<< "$win_probe_matrix")
    cases=$((cases + 1))
    if [ "$win_install_rows" -ne "$win_install_matrix_rows" ] || [ "$win_probe_rows" -ne "$win_probe_matrix_rows" ]; then
        printf 'sshp-contract: the Windows-target matrix ran %s install row(s) and %s probe row(s); the tables declare %s and %s\n' \
            "$win_install_rows" "$win_probe_rows" "$win_install_matrix_rows" "$win_probe_matrix_rows" >&2
        failures=$((failures + 1))
    fi
    cases=$((cases + 1))
    if [ "$win_install_matrix_rows" -lt 8 ] || [ "$win_probe_matrix_rows" -lt 3 ]; then
        printf 'sshp-contract: the Windows-target tables shrank to %s install row(s) and %s probe row(s); the floor is 8 and 3\n' \
            "$win_install_matrix_rows" "$win_probe_matrix_rows" >&2
        failures=$((failures + 1))
    fi

    # Self-test: the matrix must be able to SEE the two defects this round fixed.
    # Each mutation re-creates the exact PRE-FIX shape (measured above) in a copy
    # and requires the row to stop answering correctly.  A mutation that does not
    # apply is reported -- a self-test that silently did nothing passes on
    # nothing.
    win_install_writeerror="$work/win-install-writeerror.ps1"
    sed 's|^    \[Console\]::Error.WriteLine("sshp: no supported Windows installer found for Zellij.")$|    Write-Error "sshp: no supported Windows installer found for Zellij."|' \
        "$win_install_posix" > "$win_install_writeerror"
    cases=$((cases + 1))
    if cmp -s "$win_install_posix" "$win_install_writeerror"; then
        printf '%s\n' 'sshp-contract: Windows matrix self-test: the Write-Error mutation did not apply; the matrix cannot be proven able to fail' >&2
        failures=$((failures + 1))
    else
        got=$(run_windows_target_body "$win_install_writeerror" '' '' '')
        if [ "${got%%	*}" = '127' ]; then
            printf 'sshp-contract: Windows matrix self-test: an install body that reports its refusal with Write-Error still exited 127 [%s]; the matrix cannot see the class it was written for\n' \
                "$got" >&2
            failures=$((failures + 1))
        fi
    fi
    win_install_bare="$work/win-install-bare.ps1"
    awk '
        index($0, "# NOT $lastExitCode:") == 1 { inblock = 1; next }
        inblock && $0 == "exit ([int]$installerProbe.Value)" { print "exit $LASTEXITCODE"; inblock = 0; next }
        inblock { next }
        { print }
    ' "$win_install_posix" > "$win_install_bare"
    cases=$((cases + 1))
    if cmp -s "$win_install_posix" "$win_install_bare"; then
        printf '%s\n' 'sshp-contract: Windows matrix self-test: the bare-LASTEXITCODE mutation did not apply; the matrix cannot be proven able to fail' >&2
        failures=$((failures + 1))
    else
        got=$(run_windows_target_body "$win_install_bare" '' choco "$work/win-installer-noop.ps1")
        if [ "${got%%	*}" = '1' ]; then
            printf 'sshp-contract: Windows matrix self-test: an install body ending in a bare `exit $LASTEXITCODE` still exited 1 for a call that never set it [%s]; a failed install would be reported as success\n' \
                "$got" >&2
            failures=$((failures + 1))
        fi
    fi
    windows_matrix_state="$((win_probe_rows + win_install_rows))/$((win_probe_matrix_rows + win_install_matrix_rows))"
fi

# ---------------------------------------------------------------------------
# No residue.  sshp creates a private runtime directory under TMPDIR and removes
# it in the EXIT trap.  A leak here is invisible in every other check and would
# accumulate one directory per invocation on a long-lived machine.
# ---------------------------------------------------------------------------
leftovers=$(find "$work/tmp" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d '[:space:]')
if [ "$leftovers" -ne 0 ]; then
    printf 'sshp-contract: %s file(s) left in TMPDIR\n' "$leftovers" >&2
    find "$work/tmp" -mindepth 1 -maxdepth 1 >&2
    failures=$((failures + 1))
fi

# Static lock on the signal-trap window.  sshp creates its runtime directory
# early, but before 2026-10-12 the HUP/INT/TERM trap was set ~790 lines later,
# just before the main loop -- so a signal during the probe / reconnect /
# install window ran NO cleanup on dash (a fatal signal with no handler does not
# run the EXIT trap there; measured).  The first fix bound the trap right AFTER
# runtime creation; the 2026-10-12 follow-up moved BOTH traps to sit BEFORE
# initialize_ssh_runtime, closing the microsecond window between directory
# creation and trap binding (a signal landing there still leaked the directory,
# because no handler existed yet).  So the assertion is now: the signal trap
# must bind STRICTLY ABOVE `initialize_ssh_runtime`, in the hardened `|| true`
# form.  A trap moved back below runtime creation -- the shape the first fix
# allowed and this one rejects -- must go red, which a bare grep of the trap
# text (position-blind) would miss.
cases=$((cases + 1))
init_line=$(grep -n '^initialize_ssh_runtime$' "$client" | head -1 | cut -d: -f1) || true
trap_line=$(grep -n "trap 'cleanup_ssh_runtime || true; exit 130' HUP INT TERM" "$client" | head -1 | cut -d: -f1) || true
if [ -z "$trap_line" ]; then
    printf '%s\n' 'sshp-contract: the signal trap does not clean up authoritatively before exit 130 (expected the `|| true` form)' >&2
    failures=$((failures + 1))
elif [ -z "$init_line" ] || [ "$trap_line" -ge "$init_line" ]; then
    printf 'sshp-contract: the signal trap binds at line %s, not before initialize_ssh_runtime (%s); a signal between runtime creation and trap binding leaks the directory on dash\n' \
        "${trap_line:-<absent>}" "${init_line:-<absent>}" >&2
    failures=$((failures + 1))
fi
# The EXIT trap must ALSO precede runtime creation: on dash the EXIT trap only
# runs if a handler exists for the fatal signal, so binding EXIT before the
# directory exists is what makes the pre-trap window leak-free.  And it carries
# `|| true` (2026-10-13): a non-zero cleanup return under `set -e` would replace
# the session's exit code with the cleanup's -- the same clobber the signal trap
# was hardened against, on the slot that was still bare.
cases=$((cases + 1))
exit_trap_line=$(grep -n "^trap 'cleanup_ssh_runtime || true' EXIT$" "$client" | head -1 | cut -d: -f1) || true
if [ -z "$exit_trap_line" ]; then
    printf '%s\n' 'sshp-contract: the EXIT trap is not in the hardened `cleanup_ssh_runtime || true` form; a failing cleanup would replace the session exit code' >&2
    failures=$((failures + 1))
elif [ -n "$init_line" ] && [ "$exit_trap_line" -ge "$init_line" ]; then
    printf 'sshp-contract: the EXIT trap binds at line %s, not before initialize_ssh_runtime (%s); a signal in the early window would still clean up\n' \
        "$exit_trap_line" "$init_line" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'sshp-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'sshp-contract checks passed: cases=%s stub-ssh=yes reconnect=covered argv=checked residue=none trap-window=pinned remote-scripts=%s windows-scripts=%s windows-matrix=%s\n' \
    "$cases" "$remote_script_state" "$windows_script_state" "$windows_matrix_state"
