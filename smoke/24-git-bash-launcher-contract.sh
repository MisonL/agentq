#!/usr/bin/env bash
# Smoke: the two Git Bash launchers -- client/windows/agentq.bash, sshp.bash.
#
# Why this check exists: 34 lines together, and until now no check had ever
# executed them.  smoke/01 runs `bash -n` on their shebang and nothing else, so
# every behaviour below was unverified.  They are not dead files: install-client.ps1
# copies each `.bash` to an EXTENSIONLESS `agentq` / `sshp` in the user's
# .local\bin whenever Git Bash is present (Resolve-GitBashPath non-null), and that
# shim is what a Git Bash user actually invokes.
#
# What they carry that matters: they turn MSYS path rewriting OFF
# (MSYS_NO_PATHCONV=1, MSYS2_ARG_CONV_EXCL='*') so that /home/..., /c/... and
# remote command arguments are not mangled by the local Git Bash before they
# reach the PowerShell client (SKILL.md states this property).  They also convert
# an ABSOLUTE AGENTQ_SSH / AGENTQ_CONFIG / SSHP_SSH from POSIX to Windows form via
# cygpath, and -- like the .cmd shims, and for the same reason -- agentq passes
# -NonInteractive while sshp must NOT (sshp is the interactive session client).
#
# HOW IT RUNS HERE: the launcher is executed for real, with a stub `cygpath` and
# a stub `powershell.exe` on PATH.  The assertions are about what the PowerShell
# child actually RECEIVES -- its argv and the MSYS_*/AGENTQ_* variables -- not
# about the text of the launcher.
#
# WHAT THIS DOES NOT COVER: a real Git Bash, a real cygpath, a real
# powershell.exe.  The stubs model the interface, not the implementation; they
# cannot show that Windows would accept these argv or these environment values.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
windows_client_dir="$root/skill/assets/client/windows"
for launcher in agentq sshp; do
    [ -f "$windows_client_dir/$launcher.bash" ] || {
        printf 'git-bash-launcher-contract: missing asset %s.bash\n' "$launcher" >&2
        exit 1
    }
done

# macOS /tmp is a symlink to /private/tmp; pwd -P resolves it so paths compare
# cleanly (same idiom as smoke/05, smoke/11, smoke/19, smoke/21).
work=$(mktemp -d /tmp/agentq-smoke-gitbash.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

# --- stubs --------------------------------------------------------------------
# cygpath -aw <posix> -> "WIN(<posix>)": a deterministic, recognisable transform
# so an assertion can tell a converted value from an unconverted one.  Every call
# is logged so we can also assert it was (or was not) invoked.
mkdir -p "$work/bin"
cat > "$work/bin/cygpath" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${CYGPATH_LOG:?}"
for last do :; done
printf 'WIN(%s)\n' "$last"
STUB
# powershell.exe: dump argv and the environment the launcher exported, then exit
# with whatever the test asks for.  Real PowerShell is not needed to observe the
# launcher's own behaviour.
cat > "$work/bin/powershell.exe" <<'STUB'
#!/bin/sh
{
    printf 'ARGV'
    for argument in "$@"; do printf ' [%s]' "$argument"; done
    printf '\n'
    printf 'MSYS_NO_PATHCONV=%s\n' "${MSYS_NO_PATHCONV-<unset>}"
    printf 'MSYS2_ARG_CONV_EXCL=%s\n' "${MSYS2_ARG_CONV_EXCL-<unset>}"
    printf 'AGENTQ_SSH=%s\n' "${AGENTQ_SSH-<unset>}"
    printf 'AGENTQ_CONFIG=%s\n' "${AGENTQ_CONFIG-<unset>}"
    printf 'SSHP_SSH=%s\n' "${SSHP_SSH-<unset>}"
} > "${PS_OUT:?}"
exit "${PS_EXIT:-0}"
STUB
chmod 700 "$work/bin/cygpath" "$work/bin/powershell.exe"

# A private copy of the launcher next to its .ps1, so `dirname "$0"` resolves to
# a directory holding the sibling script exactly as the deployed shim does.
install_launcher() {
    local client=$1
    mkdir -p "$work/$client"
    cp "$windows_client_dir/$client.bash" "$work/$client/$client"
    cp "$windows_client_dir/$client.ps1" "$work/$client/$client.ps1"
    chmod 700 "$work/$client/$client"
}

# run_launcher <client> [env assignments...] -- executes the launcher with the
# stub PATH and a fresh output/log; prints the launcher's exit status.
run_launcher() {
    local client=$1
    shift
    : > "$work/cygpath.log"
    local status=0
    env -i \
        PATH="$work/bin:/usr/bin:/bin" \
        HOME="$work/home" \
        PS_OUT="$work/ps.out" \
        PS_EXIT="${PS_EXIT:-0}" \
        CYGPATH_LOG="$work/cygpath.log" \
        "$@" \
        "$work/$client/$client" --host smoke-host submit -- "echo a*b" \
        >"$work/out" 2>"$work/err" || status=$?
    printf '%s' "$status"
}

failures=0
cases=0

# expect_line <label> <file> <expected-line>
expect_line() {
    local label=$1 file=$2 expected=$3
    cases=$((cases + 1))
    if ! grep -qxF -- "$expected" "$file"; then
        printf 'git-bash-launcher %s: expected a line %s, got:\n' "$label" "$expected" >&2
        sed 's/^/    /' "$file" >&2
        failures=$((failures + 1))
    fi
}

# expect_no_line <label> <file> <unwanted-substring>
expect_no_line() {
    local label=$1 file=$2 unwanted=$3
    cases=$((cases + 1))
    if grep -qF -- "$unwanted" "$file"; then
        printf 'git-bash-launcher %s: unexpectedly present: %s\n' "$label" "$unwanted" >&2
        sed 's/^/    /' "$file" >&2
        failures=$((failures + 1))
    fi
}

install_launcher agentq
install_launcher sshp

# --- 1. delegation: argv the PowerShell child receives ------------------------
# agentq is non-interactive; sshp deliberately is not (it drives an interactive
# ssh session).  Both pass -File <windows-form path to the sibling .ps1>.
run_launcher agentq >/dev/null
expect_line 'agentq argv (agentq.ps1 path)' "$work/ps.out" 'ARGV [-NoProfile] [-NonInteractive] [-ExecutionPolicy] [Bypass] [-File] [WIN('"$work"'/agentq/agentq.ps1)] [--host] [smoke-host] [submit] [--] [echo a*b]'
expect_line 'agentq MSYS_NO_PATHCONV' "$work/ps.out" 'MSYS_NO_PATHCONV=1'
expect_line 'agentq MSYS2_ARG_CONV_EXCL' "$work/ps.out" 'MSYS2_ARG_CONV_EXCL=*'

run_launcher sshp >/dev/null
expect_line 'sshp argv (sshp.ps1 path)' "$work/ps.out" 'ARGV [-NoProfile] [-ExecutionPolicy] [Bypass] [-File] [WIN('"$work"'/sshp/sshp.ps1)] [--host] [smoke-host] [submit] [--] [echo a*b]'
expect_no_line 'sshp must not force -NonInteractive' "$work/ps.out" '-NonInteractive'
expect_line 'sshp MSYS_NO_PATHCONV' "$work/ps.out" 'MSYS_NO_PATHCONV=1'
expect_line 'sshp MSYS2_ARG_CONV_EXCL' "$work/ps.out" 'MSYS2_ARG_CONV_EXCL=*'

# --- 2. the conditional path conversions (both directions) --------------------
# An ABSOLUTE posix path must be converted through cygpath; a RELATIVE one must be
# left exactly as it is; an unset one must stay unset.  Asserting only the
# "absolute -> converted" direction would pass a launcher that converted
# everything, which would corrupt a relative value.
run_launcher agentq AGENTQ_SSH=/c/keys/id AGENTQ_CONFIG=/c/cfg >/dev/null
expect_line 'agentq AGENTQ_SSH absolute -> converted' "$work/ps.out" 'AGENTQ_SSH=WIN(/c/keys/id)'
expect_line 'agentq AGENTQ_CONFIG absolute -> converted' "$work/ps.out" 'AGENTQ_CONFIG=WIN(/c/cfg)'

run_launcher agentq AGENTQ_SSH=relative/key AGENTQ_CONFIG=relative/cfg >/dev/null
expect_line 'agentq AGENTQ_SSH relative -> unchanged' "$work/ps.out" 'AGENTQ_SSH=relative/key'
expect_line 'agentq AGENTQ_CONFIG relative -> unchanged' "$work/ps.out" 'AGENTQ_CONFIG=relative/cfg'

run_launcher agentq >/dev/null
expect_line 'agentq AGENTQ_SSH unset -> unset' "$work/ps.out" 'AGENTQ_SSH=<unset>'
expect_line 'agentq AGENTQ_CONFIG unset -> unset' "$work/ps.out" 'AGENTQ_CONFIG=<unset>'

run_launcher sshp SSHP_SSH=/c/keys/id >/dev/null
expect_line 'sshp SSHP_SSH absolute -> converted' "$work/ps.out" 'SSHP_SSH=WIN(/c/keys/id)'

run_launcher sshp SSHP_SSH=relative/key >/dev/null
expect_line 'sshp SSHP_SSH relative -> unchanged' "$work/ps.out" 'SSHP_SSH=relative/key'

# --- 3. the child's exit status must reach the caller -------------------------
# The .cmd shims end with `exit /b %ERRORLEVEL%` for the same reason: a launcher
# that swallows the client's code turns a failed command into a reported success.
# This asserts the property, not the mechanism -- under `set -euo pipefail` the
# status propagates with or without `exec` (dropping `exec`, or piping through
# `cat`, changes nothing: `pipefail` and `set -e` both preserve a failing child's
# status, verified as benign mutations).  What it DOES catch is a launcher that
# discards the code -- `|| true`, a trailing `exit 0` under a shell without `set
# -e`, and the like.
status=$(PS_EXIT=7 run_launcher agentq)
cases=$((cases + 1))
if [ "$status" -ne 7 ]; then
    printf 'git-bash-launcher agentq: exit status is %s, expected the child status 7 -- the launcher swallowed it\n' "$status" >&2
    failures=$((failures + 1))
fi
status=$(PS_EXIT=0 run_launcher agentq)
cases=$((cases + 1))
if [ "$status" -ne 0 ]; then
    printf 'git-bash-launcher agentq: exit status is %s, expected the child status 0\n' "$status" >&2
    failures=$((failures + 1))
fi
status=$(PS_EXIT=7 run_launcher sshp)
cases=$((cases + 1))
if [ "$status" -ne 7 ]; then
    printf 'git-bash-launcher sshp: exit status is %s, expected the child status 7 -- the launcher swallowed it\n' "$status" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'git-bash-launcher-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'git-bash-launcher-contract checks passed: cases=%s delegation=covered path-conversion=covered msys-no-rewrite=asserted exit-propagation=asserted\n' "$cases"
