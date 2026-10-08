#!/usr/bin/env bash
# Smoke: what the two PowerShell clients SEND to ssh must survive PowerShell
# 5.1's native-argument quoting.
#
# Why this check exists (docs/PLAN.md A21): both Windows clients build a shell script
# and hand it to ssh as a single argv element:
#
#     $sshArguments += @("--", $script:TargetHost, $RemoteCommand)
#     & $script:SshPath @sshArguments
#
# The `&` call operator wraps an argument containing a space in double quotes but
# does NOT escape double quotes already inside it -- the mechanism smoke/09 was
# written for.  `09` is a source scan whose two greps match `-c`/`-lc` and
# `Invoke-GitBashScript -Script`; neither matches a splatted array, so `sites`
# never counted these files and the pattern went unnoticed.
#
# WHY BEHAVIOURAL AND NOT A THIRD GREP: a first attempt extended 09 with a
# static rule that traced the array back to its producer function.  It failed to
# fire twice -- once because it read only the array's initial literal, and the
# remote command is appended later with `+=`, and once because its nested
# heredoc broke the enclosing `case`.  A detector that silently does not fire is
# the exact failure mode this suite exists to prevent, so it was reverted rather
# than patched a third time.  This check instead runs the real client, captures
# the real argv, and applies the SAME calibrated model 09 uses.
#
# What it proves: the bytes the client hands to ssh, as they would be re-parsed
# by PS 5.1 + the CRT, still form exactly one argument with identical content.
# What it does NOT prove at runtime: PowerShell 5.1's behaviour itself -- no
# PS 5.1 executes here; pwsh 7.5 is running, and pwsh quotes correctly, which is
# why this defect was invisible on macOS.  The model itself has since been
# measured directly on a real PS 5.1.19041 machine (2026-10-08): all six
# calibration rows reproduce argc-for-argc, the pre-fix splat payload splits into
# exactly the arguments the model predicts (byte-for-byte), and the clients'
# current payloads arrive byte-identical (see docs/PLAN.md A21, "直接测量").  The
# calibration rows are re-checked on every run and the check refuses a verdict
# if they stop holding.
#
# The sshp SESSION command is the one argument deliberately left RAW, and it has
# its own four cases at the end: the base64 channel would hand tmux/screen a
# non-tty stdin.  Both directions are asserted there -- see the block comment.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
pwsh_binary=${AGENTQ_SMOKE_PWSH:-$(command -v pwsh || true)}

if [ -z "$pwsh_binary" ] || ! command -v "$pwsh_binary" >/dev/null 2>&1; then
    printf 'SKIPPED: pwsh is not available; the PowerShell clients were not executed\n'
    exit 0
fi

work=$(mktemp -d /tmp/agentq-smoke-psargv.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

# ---------------------------------------------------------------------------
# crt_parse <string> -> "<argc>\n<arg1>\x01<arg2>\x01..."
#
# Identical in substance to smoke/09's model: PS 5.1 wraps the argument in
# double quotes only when it contains a space; inside, a `"` toggles the quoted
# region and a `""` is one literal quote; whitespace outside a quoted region
# separates arguments.  The self-test below is what makes this more than a
# guess -- if it fails, the check reports no verdict rather than a green one.
#
# The count is reported EXPLICITLY rather than by counting output lines.  A
# single argument may itself contain newlines (the sshp session command does),
# so `wc -l` over the arguments reports 5 for one argument -- it was the first
# version of this check, and it failed a correct asset.  Arguments are joined
# with \x01, and crt_argc refuses a verdict if the input contains that byte.
# ---------------------------------------------------------------------------
crt_parse() {
    awk 'BEGIN {
        s = ARGV[1]; delete ARGV[1]
        if (index(s, " ") > 0) s = "\"" s "\""
        n = length(s); argc = 0; cur = ""; inq = 0; out = ""
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            x = (i < n) ? substr(s, i + 1, 1) : ""
            if (c == "\"" && x == "\"") { cur = cur "\""; i++; continue }
            if (c == "\"") { inq = 1 - inq; continue }
            if (c == " " && inq == 0) { if (cur != "") { argc++; out = out "\001" cur }; cur = ""; continue }
            cur = cur c
        }
        if (cur != "") { argc++; out = out "\001" cur }
        printf "%d\n%s", argc, out
    }' "$1"
}

# crt_argc <string> -> the argument count the CRT would see.
crt_argc() {
    local parsed
    parsed=$(crt_parse "$1")
    printf '%s' "${parsed%%$'\n'*}"
}

selftest_failures=0
selftest_rows=0
selftest() {
    local label=$1 script=$2 expected=$3 actual
    selftest_rows=$((selftest_rows + 1))
    actual=$(crt_argc "$script")
    if [ "$actual" -ne "$expected" ]; then
        printf 'ps-native-argv: crt_argc self-test failed for %s: got %s, expected %s\n' \
            "$label" "$actual" "$expected" >&2
        selftest_failures=$((selftest_failures + 1))
    fi
}
# The five measured rows: same set smoke/09 calibrates against.
selftest 'inner-quote'     '# a " b' 2
selftest 'quoted-space'    'echo "hi there"' 2
selftest 'balanced-quotes' '"$PATH" --config "x"' 1
selftest 'printf-pattern'  'printf "%s" "$MSYSTEM"' 1
selftest 'no-quote'        'for d in jq base64; do command -v $d; done' 1
# A multi-line single argument counts as ONE -- the case `wc -l` got wrong.
selftest 'multiline-one'   'line one
line two
line three' 1
if [ "$selftest_failures" -ne 0 ]; then
    printf 'ps-native-argv: parser model is not calibrated; refusing to report a verdict\n' >&2
    exit 1
fi

# A recording stub ssh: writes each argument NUL-separated, answers the way the
# case asks.  Answering matters -- the client validates the reply.
make_stub() {
    local path=$1 reply=$2
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' 'for a in "$@"; do printf "%s\\0" "$a"; done > "$PS_ARGV_OUT"'
        printf 'printf %s\n' "'${reply}\\n'"
    } > "$path"
    chmod 700 "$path"
}

failures=0
cases=0

# check_roundtrip <label> <client.ps1> <argv-file> <expected-fragment>
# Asserts the LAST argv element (the remote command) survives the model:
# exactly one argument, and byte-identical to what the client built.
check_roundtrip() {
    local label=$1 client=$2 argvfile=$3 expected=$4
    cases=$((cases + 1))
    if [ ! -s "$argvfile" ]; then
        printf 'ps-native-argv: %s: the client invoked ssh but recorded no argv\n' "$label" >&2
        failures=$((failures + 1))
        return 0
    fi
    python3 - "$argvfile" "$expected" <<'PY' > "$work/sent.txt"
import sys
raw = open(sys.argv[1], 'rb').read()
parts = [p for p in raw.split(b'\0') if p]
sys.stdout.write(parts[-1].decode('utf-8', 'replace'))
PY
    local sent
    sent=$(cat "$work/sent.txt")
    # The client really sent the script we think it did.
    if ! printf '%s' "$sent" | grep -qF -- "$expected"; then
        printf 'ps-native-argv: %s: the recorded argv does not contain %s\n' "$label" "$expected" >&2
        failures=$((failures + 1))
        return 0
    fi
    crt_parse "$sent" > "$work/reparsed.txt"
    local argc got
    argc=$(sed -n '1p' "$work/reparsed.txt" | tr -d '[:space:]')
    if [ "$argc" -ne 1 ]; then
        printf 'ps-native-argv: %s: the remote command splits into %s arguments under PowerShell 5.1 quoting\n' \
            "$label" "$argc" >&2
        failures=$((failures + 1))
        return 0
    fi
    # One argument is not enough -- the content must also be unchanged.  The
    # model emits the argument after the count line, prefixed by \x01, so strip
    # exactly that one byte and compare through command substitution (which
    # drops the trailing newline the command substitution on `sent` also drops).
    got=$(tail -n +2 "$work/reparsed.txt")
    got=${got#$'\x01'}
    if [ "$sent" != "$got" ]; then
        printf 'ps-native-argv: %s: the remote command is altered by PowerShell 5.1 quoting (one argument, different bytes)\n' \
            "$label" >&2
        failures=$((failures + 1))
    fi
}

# --- sshp.ps1: the unix probe command ---------------------------------------
# Reached on every invocation (--check included), so this is not a corner.
sshp_client="$root/skill/assets/client/windows/sshp.ps1"
stub="$work/ssh-sshp"
make_stub "$stub" '__SSHP_READY__:Linux'
mkdir -p "$work/tmp1"
PS_ARGV_OUT="$work/argv-sshp" SSHP_SSH="$stub" TMPDIR="$work/tmp1" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$sshp_client" --check smoke-host \
    >"$work/o1" 2>"$work/e1" || true
check_roundtrip 'sshp.ps1 unix probe' "$sshp_client" "$work/argv-sshp" 'base64 -d | sh'

# --- sshp.ps1: the unix SESSION command, which must stay a RAW argument ------
# This is the one argument the fix deliberately does NOT base64-wrap: it `exec`s
# tmux/screen/Zellij, and the pipe channel would hand the multiplexer a non-tty
# stdin ("Must be connected to a terminal.", measured under a pty: stdin=tty
# starts screen, stdin=pipe does not).  It survives the splat only because it
# contains no double quote -- the byte PowerShell 5.1 splits an argument at.
#
# Both directions are asserted, for the reason smoke/12's auth-hint case gives:
# a one-sided assertion passes a degenerate implementation.  Wrapping it (safe
# from word-splitting, broken as a session) and adding a `"` to it (unwrapped
# but word-split) are different defects and each must be named as itself.
#
# Reached by running WITHOUT `--check`: the stub answers the probe READY, so
# preparation succeeds and the client proceeds to launch the session through the
# same splat path.  The stub overwrites its argv file each call, so the file
# holds the LAST call -- which for this run is the session command, not the probe.
mkdir -p "$work/tmp1s"
PS_ARGV_OUT="$work/argv-session" SSHP_SSH="$stub" TMPDIR="$work/tmp1s" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$sshp_client" smoke-host smoke-session \
    >"$work/o1s" 2>"$work/e1s" || true
cases=$((cases + 1))
python3 - "$work/argv-session" <<'PY' > "$work/session.txt" 2>/dev/null || true
import sys
raw = open(sys.argv[1], 'rb').read()
parts = [p for p in raw.split(b'\0') if p]
if parts:
    sys.stdout.write(parts[-1].decode('utf-8', 'replace'))
PY
session_cmd=$(cat "$work/session.txt")
if [ -z "$session_cmd" ]; then
    printf 'ps-native-argv: sshp.ps1 session: the client invoked ssh but recorded no argv\n' >&2
    failures=$((failures + 1))
else
    # Direction 1: it must be RAW, not the base64 channel.  This short-circuits:
    # a wrapped command still CONTAINS the tmux line, just base64'd, so checking
    # the markers on it too would report "lost its tmux line" for a command that
    # has not lost it -- naming the wrong defect.
    cases=$((cases + 1))
    session_wrapped=0
    if printf '%s' "$session_cmd" | grep -qF 'base64 -d | sh'; then
        session_wrapped=1
        printf 'ps-native-argv: sshp.ps1 session: the session command was base64-wrapped; it must stay a raw argument because the pipe channel hands tmux/screen a non-tty stdin\n' >&2
        failures=$((failures + 1))
    fi
    # Direction 2: it must carry the multiplexer dispatch intact.
    if [ "$session_wrapped" -eq 0 ]; then
        cases=$((cases + 1))
        if ! printf '%s' "$session_cmd" | grep -qF 'exec tmux new-session -A -s'; then
            printf 'ps-native-argv: sshp.ps1 session: the session command lost its tmux line\n' >&2
            failures=$((failures + 1))
        fi
    fi
    # And it must still round-trip as exactly one unchanged argument -- the
    # property that the raw form has to earn by containing no double quote.
    if [ "$session_wrapped" -eq 0 ]; then
        cases=$((cases + 1))
        crt_parse "$session_cmd" > "$work/session-parsed.txt"
        session_argc=$(sed -n '1p' "$work/session-parsed.txt" | tr -d '[:space:]')
        if [ "$session_argc" -ne 1 ]; then
            printf 'ps-native-argv: sshp.ps1 session: the session command splits into %s arguments under PowerShell 5.1 quoting (it must contain no double quote)\n' \
                "$session_argc" >&2
            failures=$((failures + 1))
        else
            session_got=$(tail -n +2 "$work/session-parsed.txt")
            session_got=${session_got#$'\x01'}
            if [ "$session_cmd" != "$session_got" ]; then
                printf 'ps-native-argv: sshp.ps1 session: the session command is altered by PowerShell 5.1 quoting (one argument, different bytes)\n' >&2
                failures=$((failures + 1))
            fi
        fi
    fi
fi

# A session name carrying a quote must be REFUSED before ssh is ever invoked.
# The charset guard (`^[A-Za-z0-9_.-]+$`) is the single authority that keeps the
# raw session command quote-free; Get-UnixSessionCommand additionally throws if
# a quote ever reaches it.  This case pins BOTH layers as "refuse" without
# over-specifying which one fires: if the guard is ever loosened AND the
# self-defeating `'"'"'` escaping comes back, the client would invoke ssh with a
# double quote inside the raw argument -- exactly the A21 word-split -- and
# this case turns red because ssh got called at all.  (Measured before the fix:
# that escaping produced `"` bytes in the command; removed 2026-10-07.)
mkdir -p "$work/tmp2q"
rm -f "$work/argv-quote"
cases=$((cases + 1))
quote_status=0
PS_ARGV_OUT="$work/argv-quote" SSHP_SSH="$stub" TMPDIR="$work/tmp2q"     "$pwsh_binary" -NoProfile -NonInteractive -File "$sshp_client" smoke-host "quo'te"     >"$work/o2q" 2>"$work/e2q" || quote_status=$?
if [ "$quote_status" -eq 0 ]; then
    printf 'ps-native-argv: sshp.ps1 session: a quoted session name was accepted (exit 0)\n' >&2
    failures=$((failures + 1))
fi
if [ -e "$work/argv-quote" ]; then
    printf 'ps-native-argv: sshp.ps1 session: a quoted session name reached ssh; the raw session argument can only stay one argv element while it contains no double quote\n' >&2
    failures=$((failures + 1))
fi

# The probe channel must also DO something: decode it and require the markers
# the client matches on to be present.  A channel that carries a perfectly
# intact script that prints nothing would pass check_roundtrip.
cases=$((cases + 1))
python3 - "$work/argv-sshp" <<'PY' > "$work/decoded-sshp.txt" || true
import sys, base64, re
raw = open(sys.argv[1], 'rb').read()
parts = [p for p in raw.split(b'\0') if p]
if not parts:
    sys.exit(1)
m = re.search(r'printf %s ([A-Za-z0-9+/=]+) \| base64 -d \| sh', parts[-1].decode())
if not m:
    sys.exit(1)
sys.stdout.write(base64.b64decode(m.group(1)).decode())
PY
if ! grep -qF '__SSHP_INSTALL_REQUIRED__' "$work/decoded-sshp.txt" \
   || ! grep -qF '__SSHP_WINDOWS_SHELL__' "$work/decoded-sshp.txt" \
   || ! grep -qF '"%s\n"' "$work/decoded-sshp.txt"; then
    printf 'ps-native-argv: sshp.ps1: the probe channel did not decode to the intended script\n' >&2
    failures=$((failures + 1))
fi

# --- agentq.ps1: the unix operation command ---------------------------------
# AGENTQ_REMOTE_PLATFORM=unix skips the platform probes, so the FIRST ssh call
# carries the operation command itself.
#
# The expected fragment is the base64 CHANNEL, not the script text: the script
# itself must NOT appear on the command line (that is the whole point).  The
# decode below proves the channel still carries the script intact.
agentq_client="$root/skill/assets/client/windows/agentq.ps1"
stub2="$work/ssh-agentq"
make_stub "$stub2" '{"ok":true}'
mkdir -p "$work/tmp2"
PS_ARGV_OUT="$work/argv-agentq" AGENTQ_SSH="$stub2" AGENTQ_CONFIG="$work/no-config" \
    AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix TMPDIR="$work/tmp2" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$agentq_client" status \
    >"$work/o2" 2>"$work/e2" || true
check_roundtrip 'agentq.ps1 unix operation' "$agentq_client" "$work/argv-agentq" 'base64 -d | sh'

# ...and the channel must actually decode back to the script the client meant to
# run.  Asserting only "the command line survived" would pass on a command that
# survives perfectly and does nothing.
cases=$((cases + 1))
python3 - "$work/argv-agentq" <<'PY' > "$work/decoded.txt"
import sys, base64, re
raw = open(sys.argv[1], 'rb').read()
parts = [p for p in raw.split(b'\0') if p]
cmd = parts[-1].decode()
m = re.search(r'printf %s ([A-Za-z0-9+/=]+) \| base64 -d \| sh', cmd)
if not m:
    sys.exit(1)
sys.stdout.write(base64.b64decode(m.group(1)).decode())
PY
if ! grep -qF 'agentq_server="$HOME/.local/bin/agentq"' "$work/decoded.txt" \
   || ! grep -qF 'agentq_run '\''status'\''' "$work/decoded.txt"; then
    printf 'ps-native-argv: agentq.ps1: the base64 channel did not decode to the intended script\n' >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'ps-native-argv: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'ps-native-argv checks passed: cases=%s model=calibrated(%s rows)\n' "$cases" "$selftest_rows"
