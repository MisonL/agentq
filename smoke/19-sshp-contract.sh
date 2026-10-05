#!/usr/bin/env bash
# Smoke: the POSIX `sshp` client's LOCAL contract.  No remote is contacted -- a
# stub `SSHP_SSH` answers the platform probe and records the argv it was given.
#
# Why this check exists: `assets/client/unix/sshp` is 1,190 lines and, before
# this file, NOTHING in the suite had ever executed it.  `01` parses it
# (`sh -n`), `10` asserts a couple of installer invariants about other files,
# and that was the whole of it.  Together with `sshp.ps1` (1,092 lines) it is
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
# rejected everything would pass those cases and fail this one.
run_case 'empty session name is accepted' 0 '' -- --check smoke-host ''

# `--check` must NEVER install.  The probe says a dependency is missing and a
# package manager exists; sshp must refuse rather than run the installer.  The
# assertion is two-sided: the exit code, AND that only ONE ssh call was made
# (an install attempt would be a second call).
plan_stub '42	__SSHP_INSTALL_REQUIRED__:Linux'
run_case 'check: missing dependency is not installed' 127 'tmux, GNU screen, or Zellij is required' -- --check smoke-host
calls_made=$(cat "$work/count" 2>/dev/null || printf '0')
if [ "$calls_made" -ne 1 ]; then
    printf 'sshp-contract: --check with a missing dependency made %s ssh call(s); it must probe once and stop\n' "$calls_made" >&2
    failures=$((failures + 1))
fi

plan_stub '127	__SSHP_INSTALL_UNAVAILABLE__:Linux'
run_case 'check: no supported package manager' 127 'install tmux, GNU screen, or Zellij manually' -- --check smoke-host

# An unsupported remote platform must be refused, not guessed at.
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
calls_made=$(cat "$work/count" 2>/dev/null || printf '0')
if [ "$calls_made" -ne 2 ]; then
    printf 'sshp-contract: transport reconnect: made %s ssh call(s); expected exactly 2 (fail, retry)\n' "$calls_made" >&2
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

if [ "$failures" -ne 0 ]; then
    printf 'sshp-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'sshp-contract checks passed: cases=%s stub-ssh=yes reconnect=covered argv=checked residue=none\n' "$cases"
