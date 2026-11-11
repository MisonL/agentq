#!/usr/bin/env bash
# Smoke: the POSIX `sshp` client's LOCAL contract.  No remote is contacted -- a
# stub `SSHP_SSH` answers the platform probe and records the argv it was given.
#
# Why this check exists: `assets/client/unix/sshp` is 1,487 lines and, before
# this file, NOTHING in the suite had ever executed it.  `01` parses it
# (`sh -n`), `10` asserts a couple of installer invariants about other files,
# and that was the whole of it.  Together with `sshp.ps1` (1,440 lines) it is
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
#     **2026-10-29: the WINDOWS session command is now an exception** -- it is a
#     single ssh argv element (not a pty line), so the stub captures it exactly
#     and the section at the end of this file drives the real client end to end.
#   - the Windows session's RUNTIME: whether a real sshd with each of the three
#     DefaultShell values accepts that command line.  Only its construction is
#     proven here, and construction is precisely what this round could measure.
#   - the Windows probe/install path (`run_windows_remote_command`) and the
#     expect wrapper.  They need a Windows target; only the MINGW routing
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
# A stdout field starting with `@` names a FILE whose contents are the answer.
# Needed because the Windows READY answer is TWO lines (`__SSHP_READY__:Windows`
# plus `__SSHP_ZELLIJ__:<path>`) and the plan format is one line per call.
# No existing plan begins with `@`, so this is additive, not a re-reading of the
# format -- and unlike `printf '%b'` it cannot reinterpret a backslash that is
# part of a Windows path.
case "$stdout" in
    @*) cat "${stdout#@}" ;;
    *) [ -n "$stdout" ] && printf '%s\n' "$stdout" ;;
esac
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
# Bracket RANGES (`A-Za-z`) are collation-dependent: under bash with a collating
# locale -- macOS defaults to en_US.UTF-8, and /bin/sh is bash 3.2 there --
# accented Latin letters fall inside `A-Z`.  Measured 2026-11-06: `café` went
# through the old guard and drove the probe (rc=255) while the Windows twin
# refused it with 2.  dash, zsh and any C locale refused the same bytes, so
# this is a shell x locale divergence, not a platform difference.  The name
# must be refused IN EVERY shell we can actually run; the positive control
# right after it makes sure a "refuse everything" guard cannot pass.
# `run_case` always invokes /bin/sh, so the shell x locale matrix is driven
# DIRECTLY here (one case per cell) with the same stub environment.  The
# positive control asserts that a legal ASCII name still reaches the probe --
# without it a guard that refused every non-empty name would pass all the red
# rows.  The stub's plan makes the probe fail deterministically at 255.
sshp_accented=$(printf 'caf\303\251')
sshp_charset_cells=0
sshp_range_vulnerable_cells=0
for sshp_charset_shell in /bin/sh bash dash zsh; do
    command -v "$sshp_charset_shell" >/dev/null 2>&1 || continue
    for sshp_charset_locale in C en_US.UTF-8; do
        cases=$((cases + 1)); sshp_charset_cells=$((sshp_charset_cells + 1))
        # Does THIS cell even have the hazard?  Probe the old idiom directly with
        # a single accented letter.  Measured 2026-11-06: macOS (BSD libc, bash
        # 3.2) answers "in the range"; Ubuntu 24.04 (glibc, bash 5.2, en_US.UTF-8
        # generated) answers "not in the range".  So the refusals below are
        # asserted everywhere, but only a vulnerable cell can go RED if the
        # range spelling comes back -- see the note printed when none is found.
        if LC_ALL="$sshp_charset_locale" "$sshp_charset_shell" \
            -c 'case "$1" in [A-Za-z]) exit 0 ;; esac; exit 1' _ "$(printf '\303\251')" 2>/dev/null; then
            sshp_range_vulnerable_cells=$((sshp_range_vulnerable_cells + 1))
        fi
        sshp_charset_rc=0
        SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/bin/ssh" HOME="$home" \
        TMPDIR="$work/tmp" PATH="$work/bin:/usr/bin:/bin" \
        LC_ALL="$sshp_charset_locale" "$sshp_charset_shell" "$client" \
            smoke-host "$sshp_accented" >"$work/out" 2>"$work/err" || sshp_charset_rc=$?
        if [ "$sshp_charset_rc" -ne 2 ] ||
            ! grep -qF 'session name must contain only' "$work/err"; then
            printf 'sshp-contract: accented session name [%s/%s] was not refused by the charset guard (exit %s): %s\n' \
                "$sshp_charset_shell" "$sshp_charset_locale" "$sshp_charset_rc" \
                "$(head -1 "$work/err")" >&2
            failures=$((failures + 1))
        fi
    done
done
# A table that silently shrinks to zero rows is a green table.  Calibrate the
# enumeration instead of trusting it: this host must be able to run at least
# /bin/sh (the asset's own shebang) under both locales.
cases=$((cases + 1))
if [ "$sshp_charset_cells" -lt 2 ]; then
    printf 'sshp-contract: only %s shell x locale cell(s) ran; the charset matrix cannot claim coverage\n' \
        "$sshp_charset_cells" >&2
    failures=$((failures + 1))
fi
# Coverage premise, stated rather than assumed: with zero vulnerable cells the
# refusals above still hold, but NO cell here could turn red if the guard went
# back to a range.  That is not an asset failure (glibc measured immune), so it
# is a note, not a failure -- but it must not read as a demonstrated lock.
if [ "$sshp_range_vulnerable_cells" -eq 0 ]; then
    printf 'sshp-contract: note: 0 of %s shell x locale cell(s) here treat a character RANGE as collating (glibc measured immune); this matrix cannot go red on this host -- smoke/01 chr_ranges is the cross-platform lock\n' \
        "$sshp_charset_cells" >&2
fi
run_case 'session name with CJK' 2 'session name must contain only' -- smoke-host "$(printf 'a\344\270\255')"
# Positive control: --check with a legal ASCII name must get PAST the guard and
# complete the (stubbed) probe with exit 0.  Without it a guard that refused
# every name would pass all the red rows above.  plan_stub resets the call
# counter, so the later "--help must not invoke ssh" assertion still reads a
# clean slate.
run_case 'session name ascii accepted' 0 '' -- --check smoke-host abc-1.2
plan_stub '0	__SSHP_READY__:Linux'

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

# `[ -x ]` is a PERMISSION, not a promise: it says the file MAY be executed, not
# that it CAN be.  The directory above was only the first shape of that gap.
# Three ordinary files pass the regular-file rule AND `-x` and then make the
# SHELL -- not the tool -- report a failure on every call: a 0755 file of plain
# text, a script whose interpreter does not exist, and a script whose shebang
# line ends in CR.  Before 2026-10-30 all three surfaced as exit 126/127 with
# "remote dependency probe failed for both Unix and Windows shells" -- outside
# the documented contract, and blaming the REMOTE host for a LOCAL
# misconfiguration.  The Windows twin refuses the same configuration with exit 2
# and "SSHP_SSH cannot be launched" (smoke/12).
#
# POSIX has no "would exec(2) succeed" primitive, so the client probes by
# RUNNING the file (`-V`, no connection) and refuses only when the shell's own
# 126/127 comes back.  The three shapes are generated here, not committed.
launch_shape_cases=0
for launch_shape in text missing-interpreter crlf-shebang; do
    case "$launch_shape" in
        text)                printf 'not an executable\n' > "$work/ssh-$launch_shape" ;;
        missing-interpreter) printf '#!/nonexistent/interpreter\nexec /usr/bin/ssh "$@"\n' > "$work/ssh-$launch_shape" ;;
        crlf-shebang)        printf '#!/bin/sh\r\nexec /usr/bin/ssh "$@"\r\n' > "$work/ssh-$launch_shape" ;;
    esac
    chmod 755 "$work/ssh-$launch_shape"
    cases=$((cases + 1)); launch_shape_cases=$((launch_shape_cases + 1))
    if SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/ssh-$launch_shape" HOME="$home" TMPDIR="$work/tmp" \
            PATH="$work/bin:/usr/bin:/bin" \
            /bin/sh "$client" --check smoke-host >"$work/out" 2>"$work/err"; then status=0; else status=$?; fi
    if [ "$status" -ne 2 ] || ! grep -qF 'SSHP_SSH cannot be launched' "$work/err"; then
        printf 'sshp-contract: SSHP_SSH=%s: expected exit 2 naming the launch failure, got %s [%s]\n' \
            "$launch_shape" "$status" "$(head -1 "$work/err")" >&2
        failures=$((failures + 1))
    fi
    if grep -qF 'remote dependency probe failed' "$work/err"; then
        printf 'sshp-contract: SSHP_SSH=%s: the failure was blamed on the remote host\n' "$launch_shape" >&2
        failures=$((failures + 1))
    fi
done

# The other direction, and the load-bearing one: a file that DOES run must never
# be refused, even when the remote command fails with the same 126/127 the shell
# uses for its own exec failures.  The fixture is a working script that answers
# `-V` the way real OpenSSH does (exit 0) and every other call with 127, which is
# exactly what a missing remote dependency looks like.  A refusal keyed on the
# status alone -- "anything 126/127 is a local launch failure" -- passes every
# case above and fails here.
cat > "$work/ssh-remote-127" <<'STUB'
#!/bin/sh
case "$1" in
    -V) printf '%s\n' 'OpenSSH_9.9p1, LibreSSL 3.3.6' >&2; exit 0 ;;
esac
exit 127
STUB
chmod 755 "$work/ssh-remote-127"
cases=$((cases + 1)); launch_shape_cases=$((launch_shape_cases + 1))
if SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/ssh-remote-127" HOME="$home" TMPDIR="$work/tmp" \
        PATH="$work/bin:/usr/bin:/bin" \
        /bin/sh "$client" --check smoke-host >"$work/out" 2>"$work/err"; then status=0; else status=$?; fi
if [ "$status" -ne 127 ] || ! grep -qF 'remote dependency probe failed' "$work/err"; then
    printf 'sshp-contract: a working ssh whose remote probe exits 127: expected the remote-blame verdict at exit 127, got %s [%s]\n' \
        "$status" "$(head -1 "$work/err")" >&2
    failures=$((failures + 1))
fi
if grep -qF 'cannot be launched' "$work/err"; then
    printf '%s\n' 'sshp-contract: a working ssh whose remote probe exits 127 was refused as a local launch failure' >&2
    failures=$((failures + 1))
fi
if [ "$launch_shape_cases" -lt 4 ]; then
    printf 'sshp-contract: the launch-shape block ran only %s case(s) (expected 4)\n' \
        "$launch_shape_cases" >&2
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
# `__SSHP_ZELLIJ__:<path>`.  At the time the POSIX client did not consume that
# line (its Windows session command was `exec zellij attach --create` with a
# bare name -- checked, not assumed), so the missing line was inert THERE; it
# was still a divergence of the same contract, because the Windows twin parsed
# it into the path its session command embeds.  **2026-10-29: that bare-name
# session line was itself the defect** -- see the session-command section at the
# end of this file, which now drives this client end to end and compares the
# command it emits with the twin's own builder, byte for byte.  The resolver
# also spelled one constructor two ways (`New-Object "…List[string]"` vs
# `[…]::new()`; pwsh 7.5 answers identically, measured).
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
# A separate flag because `windows_matrix_state` is later overwritten with the
# row counts; a boolean that changes meaning mid-file is a boolean that lies.
pwsh_usable=false
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
        pwsh_usable=true
    fi
fi

if [ "$pwsh_usable" = true ]; then
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
    # status; `noexec` is a path the OS refuses to START, which is this
    # fixture's model of the CreateProcess failure a Windows AV or policy would
    # cause -- the call returns, a non-terminating error is recorded, and
    # $LASTEXITCODE is never set (measured 2026-10-17, and again here: success=
    # False, lastExitPresent=False).  `noop.ps1` is the same state reached
    # in-process, which needs no exec bit and is therefore portable.
    #
    # `noexec` IS A DANGLING SYMLINK, AND THAT IS THE WHOLE POINT.  On the test
    # host, `& '<path>'` for an EXISTING non-executable file does not fail -- it
    # calls macOS LaunchServices, which OPENS the file in whatever app the
    # machine associates with that type.  Measured 2026-10-29 on one machine:
    # no extension -> TextEdit, `.exe` -> Parallels Desktop, `.dat` -> IINA; one
    # window per row, per run, piling up on the desktop.  The extension is NOT
    # a safety property -- it only chooses WHICH app opens the file, so any
    # suffix-based "fix" is one user's file associations away from being wrong
    # again (an earlier `.exe` suffix passed a TextEdit-only window count and
    # still opened Parallels).  A DANGLING SYMLINK never reaches LaunchServices
    # at all: there is no target to open, so `&` fails with "The file ... does
    # not exist", a NON-TERMINATING error that leaves $LASTEXITCODE unset --
    # exactly the state this row models, and measured to still discriminate
    # (fixed body 1, round-46 tail 0).  This is a property of the TEST HOST, not
    # of the code under test: a real Windows target fails in CreateProcess and
    # never consults LaunchServices.
    #
    # Measured alternatives, all rejected: mode 0644/000 regular file -> opens
    # (or attempts to open) via LaunchServices; 0755 with an invalid
    # interpreter, a directory, or an absent path -> a TERMINATING error, so
    # the fail-closed guard never runs and the row would pass for the wrong
    # reason.  The guard below pins the dangling-symlink property in BOTH
    # directions, because a predicate that cannot fire is decoration.
    win_installer_noexec="$work/win-installer-noexec"
    ln -s "$work/win-installer-noexec-target-that-does-not-exist" "$win_installer_noexec"
    # True only for a symlink whose target does not resolve.  This is the
    # predicate that keeps macOS LaunchServices away from the fixture.
    fixture_is_launch_safe() { [ -L "$1" ] && [ ! -e "$1" ]; }
    guard_regular="$work/win-installer-guard-probe"
    : > "$guard_regular"
    if fixture_is_launch_safe "$guard_regular"; then
        printf '%s\n' 'sshp-contract: the launch-safety guard accepted a regular file -- the guard is broken, not the fixture' >&2
        failures=$((failures + 1))
    fi
    if ! fixture_is_launch_safe "$win_installer_noexec"; then
        printf '%s\n' 'sshp-contract: the cannot-start fixture is not a dangling symlink; macOS LaunchServices opens any existing non-executable file in a GUI app (measured: no extension -> TextEdit, .exe -> Parallels Desktop, .dat -> IINA), one window per row per run' >&2
        failures=$((failures + 1))
    fi
    printf '#!/bin/sh\nexit 0\n' > "$work/win-installer-zero"
    printf '#!/bin/sh\nexit 5\n' > "$work/win-installer-five"
    chmod 700 "$work/win-installer-zero" "$work/win-installer-five"
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
# The Windows SESSION command (2026-10-29, 第四十七类).
#
# Rounds 45 and 46 compared what the two sshp clients EMBED -- the unix-target
# and Windows-target script bodies.  This is the layer below that: the command
# each client puts on the wire to START the session.  Comparing the bodies had
# just made the POSIX probe report `__SSHP_ZELLIJ__:<path>` like the twin's, and
# the POSIX client still threw that path away: it wrote
#
#     exec zellij attach --create '<name>'\r\n
#
# into a FIFO feeding `ssh -tt` with NO remote command, so the line was parsed by
# whatever the target's DefaultShell is.  This file's own header (round 46) had
# recorded that line as "checked, not assumed" and moved on.  It was wrong, in
# two independent ways, both reachable on configurations this repo has measured
# on real hosts:
#
#   * `exec` is a POSIX builtin.  SKILL.md documents `cmd.exe`, `powershell.exe`
#     and Git Bash as the three DefaultShell values, all three real-host measured
#     -- and the FIRST is the OpenSSH default when the key is unset.  Measured
#     2026-10-29: under PowerShell the line dies as `Switch-Process:`; cmd.exe
#     has no such command at all.  sshp.ps1 sends `powershell.exe ...`, which
#     every one of the three shells can run.
#   * the BARE NAME is a PATH lookup, performed by the very session whose probe
#     had just resolved an absolute path to dodge a stale PATH.  The line above
#     this probe call in the asset says the probe uses native PowerShell
#     "because WinGet, Scoop, or Chocolatey installs" leave the SSH-server PATH
#     stale.  Measured 2026-10-29 with zellij present only at the resolver's
#     absolute path: `exec zellij ...` -> `sh: line 0: exec: zellij: not found`,
#     `exec '<abs>' ...` -> starts.  The client's OWN install flow produces that
#     state: install via winget, re-probe -> READY with the path, start the
#     session -> dead.  `--check` on the same host had already printed
#     "persistent remote session: Zellij (Windows)".
#
# The fix makes this client send the twin's command, and the lock proves that in
# two directions: the emitted payload is decoded against an absolute expectation
# (a comparison of the two clients to each other would pass if both drifted the
# same way), AND the twin's own builder is run through pwsh on the same inputs
# and required to agree byte for byte.
# ---------------------------------------------------------------------------
win_session_dir="$work/win-session"
mkdir -p "$win_session_dir"

# One Windows READY answer per fixture.  `@` makes the stub answer with a FILE so
# the probe can reply on two lines, as the real body does.  An empty path means
# the answer has no `__SSHP_ZELLIJ__` line at all -- the state the round-46 probe
# could produce and the old client silently ignored.
win_ready() { # $1 = name, $2 = the __SSHP_ZELLIJ__ value (empty => no marker line)
    if [ -n "$2" ]; then
        printf '%s\n%s\n' '__SSHP_READY__:Windows' "__SSHP_ZELLIJ__:$2" > "$win_session_dir/$1"
    else
        printf '%s\n' '__SSHP_READY__:Windows' > "$win_session_dir/$1"
    fi
}
win_path_normal='C:\Program Files\zellij\zellij.exe'
win_path_hostile="C:\Users\O'Brien\zellij.exe"
win_path_control=$(printf 'C:\\a\tb.exe')
win_path_long=$(awk 'BEGIN { for (i = 0; i < 1100; i++) printf "p" }')
win_ready ready-good "$win_path_normal"
win_ready ready-hostile "$win_path_hostile"
win_ready ready-control "$win_path_control"
win_ready ready-long "$win_path_long"
win_ready ready-nomarker ''

# run_windows_session <fixture> [client] -> sets ws_status, ws_calls, ws_command
run_windows_session() {
    local fixture=$1 runner=${2:-$client}
    plan_stub "43	__SSHP_WINDOWS_SHELL__:MINGW64_NT-10.0-19045
0	@$fixture
0	"
    local status=0
    SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/bin/ssh" HOME="$home" TMPDIR="$work/tmp" \
        PATH="$work/bin:/usr/bin:/bin" \
        /bin/sh "$runner" smoke-host work >"$win_session_dir/out" 2>"$win_session_dir/err" || status=$?
    ws_status=$status
    ws_calls=$(cat "$work/count" 2>/dev/null || printf '0')
    ws_calls=${ws_calls:-0}
    ws_command=''
    if [ -f "$work/argv.3" ]; then
        ws_command=$(tr '\0' '\n' < "$work/argv.3" | LC_ALL=C sed -n '$p')
    fi
    ws_stderr=$(cat "$win_session_dir/err")
}

# decode_session_command <command> -> the UTF-16LE payload as UTF-8 on stdout
decode_session_command() {
    printf '%s' "${1##* }" | base64 -d 2>/dev/null | iconv -f UTF-16LE -t UTF-8 2>/dev/null || true
}

# The absolute oracle, not a cross-client comparison: this is the exact script
# sshp.ps1's here-string is written to produce (LF between the two lines, no
# trailing newline -- measured against [Convert]::ToBase64String on the asset).
ws_expected=$(printf '%s\n%s' \
    "\$ErrorActionPreference = 'Stop'" \
    "& '$win_path_normal' attach --create 'work'")

# payload_invokes_bare_name <decoded script> -> 0 when the payload names Zellij
# with a bare name instead of an absolute path.
#
# The detector is the contract: "the session runs the path the PROBE resolved".
# Written as a predicate so the self-test below can feed it a bare-name payload
# directly and require it to fire -- a detector exercised only by the asset it
# was written against is a detector nobody has seen say yes.
#
# `grep -c` + arithmetic, NOT `grep -q`: this file runs under `set -o pipefail`,
# where a quiet grep exits at its first match, `printf` takes SIGPIPE, and a
# FOUND pattern reads as ABSENT -- `smoke/01`'s quiet-grep lock caught exactly
# that shape here on the first run.  `-c` must read every line to count.
payload_invokes_bare_name() {
    local bare_matches
    bare_matches=$(printf '%s' "$1" | grep -E -c "& '[^']*[\\\\/][^']*' attach --create") || bare_matches=0
    [ "${bare_matches:-0}" -eq 0 ]
}

# assert_good_session <label> -> six assertions on the CURRENT ws_* values.
assert_good_session() {
    local label=$1 decoded
    decoded=$(decode_session_command "$ws_command")
    cases=$((cases + 1))
    if [ "$ws_status" -ne 0 ]; then
        printf 'sshp-contract: Windows session [%s]: exit %s on a well-formed resolved path; expected 0. stderr: %s\n' \
            "$label" "$ws_status" "$ws_stderr" >&2
        failures=$((failures + 1))
    fi
    cases=$((cases + 1))
    if [ "$ws_calls" -ne 3 ]; then
        printf 'sshp-contract: Windows session [%s]: %s ssh call(s), expected 3 (unix probe, Windows probe, session)\n' \
            "$label" "$ws_calls" >&2
        failures=$((failures + 1))
    fi
    cases=$((cases + 1))
    case "$ws_command" in
        'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '*) ;;
        *)
            printf 'sshp-contract: Windows session [%s]: the third call is not the twin''s encoded remote command: [%s]\n' \
                "$label" "$ws_command" >&2
            failures=$((failures + 1))
            ;;
    esac
    cases=$((cases + 1))
    if [ "$decoded" != "$ws_expected" ]; then
        printf 'sshp-contract: Windows session [%s]: the decoded payload is not the expected script\n  got      [%s]\n  expected [%s]\n' \
            "$label" "$decoded" "$ws_expected" >&2
        failures=$((failures + 1))
    fi
    # The whole point of the change: the path the PROBE resolved is the path the
    # session runs, and the bare name is gone.  `grep -c` for the same pipefail
    # reason as payload_invokes_bare_name.
    cases=$((cases + 1))
    path_matches=$(printf '%s' "$decoded" | grep -F -c -- "& '$win_path_normal'") || path_matches=0
    if [ "${path_matches:-0}" -eq 0 ]; then
        printf 'sshp-contract: Windows session [%s]: the resolved path was not embedded verbatim: %s\n' \
            "$label" "$decoded" >&2
        failures=$((failures + 1))
    fi
    cases=$((cases + 1))
    if payload_invokes_bare_name "$decoded"; then
        printf 'sshp-contract: Windows session [%s]: the payload invokes Zellij by BARE NAME instead of an absolute path, so a stale SSH PATH kills the session: %s\n' \
            "$label" "$decoded" >&2
        failures=$((failures + 1))
    fi
}

# --- The happy path: an encoded remote command carrying the resolved path ----
run_windows_session "$win_session_dir/ready-good"
assert_good_session happy-path

# --- The guards: refuse, and emit NOTHING. --------------------------------
# Each message is the twin's, verbatim: the refusal is part of the answer two
# clients must agree on.  Zero ssh calls past the probe is the other half -- a
# guard that fires after the command was sent guards nothing.
win_guard() { # $1 = label, $2 = fixture, $3 = expected message
    cases=$((cases + 1))
    run_windows_session "$2"
    if [ "$ws_status" -ne 2 ]; then
        printf 'sshp-contract: Windows session %s: expected refusal exit 2, got %s\n' "$1" "$ws_status" >&2
        failures=$((failures + 1))
    fi
    cases=$((cases + 1))
    # Count over the FILE, not a pipe into `grep -q`: this file runs under
    # `set -o pipefail`, where a quiet grep's early exit makes the writer take
    # SIGPIPE and a FOUND message read as absent.
    stderr_matches=$(grep -F -c -- "$3" "$win_session_dir/err") || stderr_matches=0
    if [ "${stderr_matches:-0}" -eq 0 ]; then
        printf 'sshp-contract: Windows session %s: stderr lacks %s\n  got: %s\n' "$1" "$3" "$ws_stderr" >&2
        failures=$((failures + 1))
    fi
    cases=$((cases + 1))
    if [ "$ws_calls" -ne 2 ]; then
        printf 'sshp-contract: Windows session %s: %s ssh call(s); a refusal must not send a session command\n' "$1" "$ws_calls" >&2
        failures=$((failures + 1))
    fi
}
win_guard hostile-path "$win_session_dir/ready-hostile" 'the resolved Zellij path contains a quote or line break'
win_guard control-path "$win_session_dir/ready-control" 'the resolved Zellij path contains a control character'
win_guard over-long-path "$win_session_dir/ready-long" 'the resolved Zellij path is longer than'
win_guard missing-marker "$win_session_dir/ready-nomarker" 'no resolved Zellij path from the probe'

# --- The bound's UNIT: UTF-16 code units, under EVERY shell and locale. ----
# The bound exists so the two clients refuse the same answers, and the twin's
# answer is `String.Length -gt 1024` -- UTF-16 CODE UNITS.  `${#var}` is not
# that number, and it is not even a stable number: measured 2026-10-29 on this
# machine, one 1220-byte CJK path counted 420 under bash+UTF-8, 1220 under
# bash+LC_ALL=C, and 1220 under dash -- so bash and dash gave OPPOSITE verdicts
# on the same path, and only the bash+UTF-8 number agreed with the twin.
# 600 emoji invert it: 620 code points but 1220 UTF-16 units, so a code-point
# counter ACCEPTS what the twin refuses.  That is why this is asserted across a
# shell x locale matrix instead of in one run: any single cell can be right by
# accident, and the client must not answer a question about its CALLER.
#
# The fixtures are built by repetition so the three units separate by
# construction, and the expected verdict is computed here from iconv -- an
# oracle independent of the client's own arithmetic.  `| wc -c` on a PIPE, not
# `>/dev/null`: measured 2026-10-29, macOS iconv fails with ENOTTY ("Inappropriate
# ioctl for device") writing a large enough conversion to /dev/null (340 CJK
# chars fine, 360 fail, while ASCII of twice the byte count is fine), so a
# /dev/null-based probe reports a valid path as invalid.
win_repeat() { # $1 = unit, $2 = count
    local out='' i=0
    while [ "$i" -lt "$2" ]; do out="$out$1"; i=$((i + 1)); done
    printf '%s' "$out"
}
win_units_of() { # $1 = text -> UTF-16 code units (the twin's unit)
    local bytes
    bytes=$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | wc -c) || return 1
    printf '%s' "$(( ${bytes//[[:space:]]/} / 2 ))"
}
# 400 CJK chars: 420 units (<= 1024), 1220 bytes (> 1024).  The twin accepts;
# a byte counter refuses.
win_path_units_accept="C:\\Users\\$(win_repeat 中 400)\\zellij.exe"
# 600 emoji: 620 code points (<= 1024), 1220 units (> 1024).  The twin refuses;
# a code-point counter accepts.
win_path_units_refuse="C:\\Users\\$(win_repeat 😀 600)\\zellij.exe"
win_ready ready-units-accept "$win_path_units_accept"
win_ready ready-units-refuse "$win_path_units_refuse"

# run_windows_session_in <fixture> <shell> <locale> -> ws_* like run_windows_session
run_windows_session_in() {
    local fixture=$1 shell=$2 locale=$3
    plan_stub "43	__SSHP_WINDOWS_SHELL__:MINGW64_NT-10.0-19045
0	@$fixture
0	"
    local status=0
    LC_ALL="$locale" SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/bin/ssh" HOME="$home" TMPDIR="$work/tmp" \
        PATH="$work/bin:/usr/bin:/bin" \
        "$shell" "$client" smoke-host work >"$win_session_dir/out" 2>"$win_session_dir/err" || status=$?
    ws_status=$status
    ws_calls=$(cat "$work/count" 2>/dev/null || printf '0')
    ws_calls=${ws_calls:-0}
    ws_command=''
    if [ -f "$work/argv.3" ]; then
        ws_command=$(tr '\0' '\n' < "$work/argv.3" | LC_ALL=C sed -n '$p')
    fi
    ws_stderr=$(cat "$win_session_dir/err")
}

# The matrix.  bash and zsh count CODE POINTS in a UTF-8 locale and BYTES under
# LC_ALL=C; dash counts BYTES always.  A shell that is absent is not counted as
# a pass -- it is reported, exactly like the pwsh gate above, because "the check
# could not run here" and "the check ran and passed" are different facts.
#
# Each cell's UNIT is measured, not assumed.  A locale name that does not exist
# on this host SILENTLY falls back to C (measured), so a hard-coded
# `en_US.UTF-8` cell that counted bytes would be a cell that never tested what
# its label claims.  The probe reports what each cell actually measured and the
# summary says whether the matrix spanned both units -- a host whose only shell
# counts bytes still runs every assertion, but it is not called a bytes+chars
# matrix.
win_units_cells=''
win_units_skipped=''
win_units_units=''
win_units_state='not-run'
# The locale is PICKED, not assumed: a name that does not exist silently falls
# back to C (measured), so hard-coding `en_US.UTF-8` would give a cell labelled
# utf8 that counts bytes -- never testing what the label claims.  Try the usual
# UTF-8 names and keep the first one where a shell really counts code points;
# if none does, say so (the note below) rather than pretend.
win_units_utf8_locale=''
win_units_pick_locale() {
    local candidate probe_shell
    # Probe with EACH shell, not just one: on Debian/Ubuntu /bin/sh is dash,
    # which counts bytes under every locale, so probing with /bin/sh alone would
    # conclude "no UTF-8 locale here" on a host where bash would count code
    # points perfectly well.  A locale counts as usable for this matrix if ANY
    # shell present turns 中 into 1 under it.
    for candidate in C.UTF-8 en_US.UTF-8 en_US.utf8; do
        for probe_shell in bash zsh /bin/sh; do
            command -v "$probe_shell" >/dev/null 2>&1 || continue
            if [ "$(LC_ALL="$candidate" "$probe_shell" -c 'x=中; printf "%s" "${#x}"' 2>/dev/null)" = 1 ]; then
                win_units_utf8_locale=$candidate
                return 0
            fi
        done
    done
    # No UTF-8 locale here: keep a name so the cells still run, and let each
    # cell's measured unit (which will read `bytes`) plus the note say so.
    win_units_utf8_locale=en_US.UTF-8
}
win_units_pick_locale
win_units_unit() { # $1 = shell, $2 = locale -> chars|bytes|unknown
    local measured
    # 中 is three UTF-8 bytes and one code point.  LC_ALL=C forces bytes in
    # every shell; no shell turns bytes into code points.
    measured=$(LC_ALL="$2" "$1" -c 'x=中; printf "%s" "${#x}"' 2>/dev/null) || measured=''
    case "$measured" in
        1) printf 'chars' ;;
        3) printf 'bytes' ;;
        *) printf 'unknown' ;;
    esac
}
win_units_run() { # $1 = label, $2 = shell, $3 = locale
    local label=$1 shell=$2 locale=$3 unit
    if ! command -v "$shell" >/dev/null 2>&1; then
        win_units_skipped="$win_units_skipped $label"
        return 0
    fi
    unit=$(win_units_unit "$shell" "$locale")
    win_units_cells="$win_units_cells $label"
    case "$win_units_units" in
        *"$unit"*) ;;
        *) win_units_units="$win_units_units $unit" ;;
    esac

    # The accept fixture must be ACCEPTED: exit 0, and the path embedded.
    cases=$((cases + 1))
    run_windows_session_in "$win_session_dir/ready-units-accept" "$shell" "$locale"
    if [ "$ws_status" -ne 0 ]; then
        printf 'sshp-contract: unit matrix [%s, %s]: a %s-unit path (bound %s) was refused with exit %s; the twin ACCEPTS it. stderr: %s\n' \
            "$label" "$unit" "$(win_units_of "$win_path_units_accept")" "$windows_path_limit_expected" "$ws_status" "$ws_stderr" >&2
        failures=$((failures + 1))
    fi
    cases=$((cases + 1))
    accept_decoded=$(decode_session_command "$ws_command")
    accept_matches=$(printf '%s' "$accept_decoded" | grep -F -c -- "& '$win_path_units_accept'") || accept_matches=0
    if [ "${accept_matches:-0}" -eq 0 ]; then
        printf 'sshp-contract: unit matrix [%s, %s]: the accepted session does not carry the multibyte path verbatim\n' \
            "$label" "$unit" >&2
        failures=$((failures + 1))
    fi

    # The refuse fixture must be REFUSED: 1220 units > 1024 even though its
    # code-point count is 620.
    cases=$((cases + 1))
    run_windows_session_in "$win_session_dir/ready-units-refuse" "$shell" "$locale"
    if [ "$ws_status" -ne 2 ]; then
        printf 'sshp-contract: unit matrix [%s, %s]: a %s-unit path (bound %s) was NOT refused (exit %s); the twin REFUSES it -- a code-point counter would accept it\n' \
            "$label" "$unit" "$(win_units_of "$win_path_units_refuse")" "$windows_path_limit_expected" "$ws_status" >&2
        failures=$((failures + 1))
    fi
}

# Say so when the matrix could not span both units.  Not a failure -- a host
# whose every shell counts bytes is legal -- but a host where the CODE-POINT
# direction was never exercised is not the same evidence, and silence would let
# it read as if it were.
win_units_matrix_note() {
    case " $win_units_units " in
        *' chars '*) ;;
        *)
            printf 'sshp-contract: note: no cell counted code points here (units:%s); the code-point half of the matrix is untested on this host\n' \
                "$win_units_units" >&2
            ;;
    esac
    case " $win_units_units " in
        *' bytes '*) ;;
        *)
            printf 'sshp-contract: note: no cell counted bytes here (units:%s); the byte half of the matrix is untested on this host\n' \
                "$win_units_units" >&2
            ;;
    esac
}

# The expected bound is the twin's, read below into twin_limit; an empty value
# is already a failure, and the cells must not silently pass on it.

# --- --check must never build one.  It is read-only and must not acquire a
# dependency on iconv/base64 or on a well-formed path.                      ---
plan_stub '43	__SSHP_WINDOWS_SHELL__:MINGW64_NT-10.0-19045
0	@'"$win_session_dir/ready-nomarker"'
'
check_status=0
SSHP_STUB_DIR="$stub_dir" SSHP_SSH="$work/bin/ssh" HOME="$home" TMPDIR="$work/tmp" \
    PATH="$work/bin:/usr/bin:/bin" \
    /bin/sh "$client" --check smoke-host >"$win_session_dir/co" 2>"$win_session_dir/ce" || check_status=$?
cases=$((cases + 1))
if [ "$check_status" -ne 0 ] || [ "$(cat "$work/count")" != '2' ] ||
    ! grep -qF 'persistent remote session: Zellij (Windows)' "$win_session_dir/co"; then
    printf 'sshp-contract: Windows --check on a host with NO resolved path: exit %s, %s ssh call(s) -- it must still report READY and build no session command\n' \
        "$check_status" "$(cat "$work/count" 2>/dev/null || printf '?')" >&2
    failures=$((failures + 1))
fi

# --- The bound is the twin's, and read from the twin. ----------------------
# A restated 1024 is a constant that drifts; this is the same rule smoke/14
# learned when a mutation raising the limit left the length site green because
# the extractor had hard-coded the number it was checking.
twin_limit=$(LC_ALL=C sed -n 's/.*ResolvedZellijPath\.Length -gt \([0-9][0-9]*\).*/\1/p' "$sshp_ps_client" | LC_ALL=C sed -n '1p')
our_limit=$(LC_ALL=C sed -n 's/^windows_zellij_path_limit=\([0-9][0-9]*\)$/\1/p' "$client" | LC_ALL=C sed -n '1p')
cases=$((cases + 1))
if [ -z "$twin_limit" ] || [ "$our_limit" != "$twin_limit" ]; then
    printf 'sshp-contract: the path-length bound is %s here but %s in sshp.ps1 (the bound is shared contract, not a local taste)\n' \
        "${our_limit:-<none>}" "${twin_limit:-<none>}" >&2
    failures=$((failures + 1))
fi

# The SESSION NAME's bound is a second shared constant, and it is read the same
# way for the same reason: it is a number both clients must agree on, so the
# only place it may be written down is the asset, and the extractor must find it
# in both.  A missing constant is a failure here too -- an empty read would
# otherwise compare "" to "" and pass.
twin_session_limit=$(LC_ALL=C grep -c 'SessionName\.Length -gt \$script:SessionNameLimit' "$sshp_ps_client" || true)
twin_session_value=$(LC_ALL=C sed -n 's/^\$script:SessionNameLimit = \([0-9][0-9]*\)$/\1/p' "$sshp_ps_client" | LC_ALL=C sed -n '1p')
our_session_limit=$(LC_ALL=C sed -n 's/^session_name_limit=\([0-9][0-9]*\)$/\1/p' "$client" | LC_ALL=C sed -n '1p')
cases=$((cases + 1))
if [ -z "$twin_session_value" ] || [ -z "$our_session_limit" ] || [ "$our_session_limit" != "$twin_session_value" ]; then
    printf 'sshp-contract: the session-name bound is %s here but %s in sshp.ps1 (the bound is shared contract, not a local taste)\n' \
        "${our_session_limit:-<none>}" "${twin_session_value:-<none>}" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if [ "${twin_session_limit:-0}" -eq 0 ]; then
    printf '%s\n' 'sshp-contract: sshp.ps1 no longer bounds the session name during argv validation; the POSIX constant is now unpaired' >&2
    failures=$((failures + 1))
fi

windows_path_limit_expected=${twin_limit:-?}

# A static pin beside the behavioural matrix: `${#windows_zellij_path}` is the
# exact construct that made the bound shell- and locale-dependent, and no
# fixture arrangement can see it if the fixtures ever drift.  Asserted in BOTH
# directions -- the unit must come from a UTF-16 conversion AND the shell's own
# `${#...}` must not be used on this value -- so a rewrite that measures some
# OTHER way has to say what it is doing here.
#
# It reads CODE LINES only.  The asset's comment explains why `${#...}` is
# wrong and therefore contains it; a detector that matches its own explanation
# reports a correct asset as broken, which is the false-red class smoke/16's
# self-masking detector already taught.
client_code_only="$work/sshp-code-only"
LC_ALL=C grep -v '^[[:space:]]*#' "$client" > "$client_code_only"
cases=$((cases + 1))
if LC_ALL=C grep -q '\${#windows_zellij_path}' "$client_code_only"; then
    printf '%s\n' 'sshp-contract: the client measures the Zellij path with ${#windows_zellij_path}; that is bytes under dash and any C locale and code points under bash+UTF-8, not the twin'"'"'s UTF-16 code units' >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if ! LC_ALL=C grep -q "iconv -f UTF-8 -t UTF-16LE | wc -c" "$client_code_only"; then
    printf '%s\n' 'sshp-contract: the client no longer measures the Zellij path through a UTF-8 to UTF-16LE conversion; the bound is no longer in the twin'"'"'s unit' >&2
    failures=$((failures + 1))
fi

win_units_run 'sh+C' /bin/sh C
win_units_run 'sh+utf8' /bin/sh "$win_units_utf8_locale"
win_units_run 'bash+C' bash C
win_units_run 'bash+utf8' bash "$win_units_utf8_locale"
win_units_run 'dash+C' dash C
win_units_run 'dash+utf8' dash "$win_units_utf8_locale"
win_units_run 'zsh+C' zsh C
win_units_run 'zsh+utf8' zsh "$win_units_utf8_locale"
if [ -n "$win_units_cells" ]; then
    win_units_state="matrix(${win_units_cells# } units:${win_units_units# })"
fi
if [ -n "$win_units_skipped" ]; then
    win_units_state="$win_units_state skipped(${win_units_skipped# })"
fi
win_units_matrix_note

# --- The differential: run the TWIN's own builder, same inputs. ------------
# Only when pwsh actually works, and reported as such -- `windows_matrix_state`
# above already refuses to call an unusable interpreter an asset result.
win_session_state='not-run(pwsh)'
if [ "$pwsh_usable" = true ]; then
    # Pull Get-WindowsSessionCommand out of the asset by BRACE DEPTH.  A line
    # window cannot do this: the function contains a here-string and comments,
    # and smoke/10 rule J settled years ago that "near" is not "inside".
    twin_builder="$work/twin-session-builder.ps1"
    LC_ALL=C awk '
        !have && /^function Get-WindowsSessionCommand[ \t]*\{/ { have = 1; depth = 0 }
        have {
            print
            line = $0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (c == "{") depth++
                else if (c == "}") depth--
            }
            if (depth == 0) exit
        }
    ' "$sshp_ps_client" > "$twin_builder"
    cases=$((cases + 1))
    twin_lines=$(wc -l < "$twin_builder" | tr -d '[:space:]')
    if ! grep -q '^function Get-WindowsSessionCommand {' "$twin_builder" ||
        [ "$(LC_ALL=C sed -n '$p' "$twin_builder")" != '}' ]; then
        printf 'sshp-contract: could not extract Get-WindowsSessionCommand from sshp.ps1 by brace depth (%s line(s)); the differential would compare nothing\n' "$twin_lines" >&2
        failures=$((failures + 1))
    else
        {
            printf '%s\n' 'function Stop-Sshp { param([string]$Message) [Console]::Error.WriteLine("sshp: $Message"); exit 2 }'
            printf '%s\n' '$script:ResolvedZellijPath = $env:SMOKE_TWIN_PATH'
            printf '%s\n' '$script:SessionName = $env:SMOKE_TWIN_SESSION'
            cat "$twin_builder"
            printf '%s\n' '$c = Get-WindowsSessionCommand'
            printf '%s\n' '[Console]::Out.Write($c)'
        } > "$work/twin-session-run.ps1"
        # The guard cases above overwrite ws_*; re-capture the happy path so the
        # comparison below is against a live POSIX command, not a stale one.
        run_windows_session "$win_session_dir/ready-good"
        twin_out="$work/twin-session.out"; twin_err="$work/twin-session.err"
        twin_status=0
        SMOKE_TWIN_PATH="$win_path_normal" SMOKE_TWIN_SESSION='work' \
            "$pwsh_binary" -NoProfile -NonInteractive -File "$work/twin-session-run.ps1" \
            >"$twin_out" 2>"$twin_err" || twin_status=$?
        twin_command=$(cat "$twin_out")
        cases=$((cases + 1))
        if [ "$twin_status" -ne 0 ] || [ -z "$twin_command" ]; then
            printf 'sshp-contract: the twin session builder did not run (exit %s): %s\n' \
                "$twin_status" "$(head -1 "$twin_err")" >&2
            failures=$((failures + 1))
        fi
        cases=$((cases + 1))
        if [ "$twin_command" != "$ws_command" ]; then
            printf 'sshp-contract: the two clients build DIFFERENT Windows session commands for the same path and session\n  posix: %s\n  twin : %s\n' \
                "$ws_command" "$twin_command" >&2
            failures=$((failures + 1))
        fi
        # And the twin's guard must fire on the same input the POSIX guard fires
        # on, with the same message -- otherwise the two clients still answer
        # differently, just in a place that no longer builds a command.
        SMOKE_TWIN_PATH="$win_path_hostile" SMOKE_TWIN_SESSION='work' \
            "$pwsh_binary" -NoProfile -NonInteractive -File "$work/twin-session-run.ps1" \
            >"$work/twin-hostile.out" 2>"$twin_err" || twin_hostile_status=$?
        twin_hostile_status=${twin_hostile_status:-0}
        cases=$((cases + 1))
        if [ "$twin_hostile_status" -ne 2 ] ||
            ! grep -qF 'the resolved Zellij path contains a quote or line break' "$twin_err"; then
            printf 'sshp-contract: the twin did not refuse the hostile path the way this client does (exit %s)\n' "$twin_hostile_status" >&2
            failures=$((failures + 1))
        fi
        # The builder must be the thing being compared, not a pair of empty
        # strings: a mutation that makes the POSIX client emit nothing would
        # otherwise satisfy `[ "$twin_command" != "$ws_command" ]` only if this
        # check were absent.
        cases=$((cases + 1))
        if [ -z "$ws_command" ]; then
            printf 'sshp-contract: the differential compared an empty POSIX session command\n' >&2
            failures=$((failures + 1))
        fi
        win_session_state='compared'
    fi
fi

# --- Self-test: the payload detector must be able to fire. -----------------
# The detector is exercised on a hand-written bare-name payload FIRST, so its
# ability to say yes does not depend on the asset under test -- this runs
# unchanged against the pre-fix client too, where the mutation below cannot be
# applied at all (there is no `$windows_zellij_path` line to mutate).
cases=$((cases + 1))
if ! payload_invokes_bare_name "&\$ErrorActionPreference = 'Stop'
& 'zellij' attach --create 'work'"; then
    printf '%s\n' 'sshp-contract: the bare-name detector did not fire on a hand-written bare-name payload; it cannot be proving anything about the asset' >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if payload_invokes_bare_name "& 'C:\Program Files\zellij\zellij.exe' attach --create 'work'"; then
    printf '%s\n' 'sshp-contract: the bare-name detector fired on a legitimate absolute path; it would reject a correct asset' >&2
    failures=$((failures + 1))
fi

# Then mutate a COPY of the asset back to the old bare-name shape and require
# the same detector to reject what the client actually emits.  The asset itself
# is never touched.
bare_name_copy="$work/sshp-bare-name"
mutate_status=0
LC_ALL=C awk '
    /& '\''\$windows_zellij_path'\'' attach --create/ {
        sub(/\$windows_zellij_path/, "zellij")
        seen = 1
    }
    { print }
    END { if (!seen) exit 3 }
' "$client" > "$bare_name_copy" || mutate_status=$?
cases=$((cases + 1))
if [ "$mutate_status" -ne 0 ] || ! grep -qF "& 'zellij' attach --create" "$bare_name_copy"; then
    # Reaching here means the asset has no `$windows_zellij_path` session line,
    # i.e. this round's fix is absent.  That is the pre-fix state, and the
    # assertions above have already failed loudly; record it, do not double-count
    # it as an un-mutable self-test.
    printf 'sshp-contract: the payload lock could not be exercised against the asset (no `$windows_zellij_path` session line to mutate -- either this round''s fix is absent or something already removed that line)\n' >&2
    failures=$((failures + 1))
else
    run_windows_session "$win_session_dir/ready-good" "$bare_name_copy"
    mutated_decoded=$(decode_session_command "$ws_command")
    cases=$((cases + 1))
    if ! payload_invokes_bare_name "$mutated_decoded"; then
        printf 'sshp-contract: the bare-name detector did not fire on the asset mutated back to the old shape [%s]\n' \
            "$mutated_decoded" >&2
        failures=$((failures + 1))
    fi
    # The oracle must also reject it: the mutation must change what is emitted,
    # not merely pass through.
    cases=$((cases + 1))
    if [ "$mutated_decoded" = "$ws_expected" ]; then
        printf '%s\n' 'sshp-contract: the mutated client emitted the SAME payload as the fixed one; the mutation did not reproduce the old shape' >&2
        failures=$((failures + 1))
    fi
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

# The Windows sibling's top-level trap, added in 0.1.29.  The POSIX checks
# above pin sshp's signal traps; sshp.ps1 had NO trap at all, so an unexpected
# throw ended it with exit 1 and a raw PowerShell exception dump (file, line,
# ANSI colour) where the POSIX twin writes one `sshp: <msg>` line and exits 2.
# Measured 2026-11-10 on the SAME symlinked-TMPDIR input fed to both.
#
# Position and form are both asserted, for the reason the POSIX trap-window
# locks below give: a bare grep of the trap text is position-blind, and a trap
# placed after the first function would leave every call that runs before it
# unguarded.  A trap does NOT intercept `exit`, so deliberate codes keep
# their value either way -- this lock is about the UNEXPECTED path only.
cases=$((cases + 1))
ps_trap_line=$(grep -n '^trap {$' "$sshp_ps_client" | head -1 | cut -d: -f1) || true
ps_first_function=$(grep -n '^function ' "$sshp_ps_client" | head -1 | cut -d: -f1) || true
if [ -z "$ps_trap_line" ]; then
    printf '%s\n' 'sshp-contract: sshp.ps1 has no top-level trap; an unexpected throw exits 1 with a raw PowerShell dump' >&2
    failures=$((failures + 1))
elif [ -n "$ps_first_function" ] && [ "$ps_trap_line" -ge "$ps_first_function" ]; then
    printf 'sshp-contract: the sshp.ps1 trap binds at line %s, not before the first function (%s); calls above it stay unguarded\n' \
        "$ps_trap_line" "$ps_first_function" >&2
    failures=$((failures + 1))
else
    # The trap window is captured into a variable FIRST and grepped through
    # here-strings: a `sed | grep -q` pipeline reads a FOUND match as absent
    # under pipefail (sed takes SIGPIPE when the quiet grep exits on its first
    # match), and the repo's own quiet-grep rule reported exactly that shape
    # in this file on the first full-suite run.
    ps_trap_window=$(sed -n "${ps_trap_line},$((ps_trap_line + 3))p" "$sshp_ps_client") || true
    if ! grep -qF '[Console]::Error.WriteLine("$($script:Program): $($_.Exception.Message)")' <<<"$ps_trap_window" ||
        ! grep -qx '    exit 2' <<<"$ps_trap_window"; then
        printf '%s\n' 'sshp-contract: the sshp.ps1 trap is not the stderr-one-line-plus-exit-2 form; the diagnostic contract would diverge from the POSIX twin' >&2
        failures=$((failures + 1))
    fi
fi

if [ "$failures" -ne 0 ]; then
    printf 'sshp-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'sshp-contract checks passed: cases=%s stub-ssh=yes reconnect=covered argv=checked residue=none trap-window=pinned charset-cells=%s charset-vulnerable=%s remote-scripts=%s windows-scripts=%s windows-matrix=%s windows-session=%s windows-units=%s\n' \
    "$cases" "$sshp_charset_cells" "$sshp_range_vulnerable_cells" "$remote_script_state" "$windows_script_state" "$windows_matrix_state" "$win_session_state" "$win_units_state"
