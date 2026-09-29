#!/usr/bin/env bash
# Smoke: every remote command line a client builds must fit inside the SMALLEST
# remote command-line limit we have measured on a real Windows host.
#
# Why this exists.  Windows sshd runs the client's command as
# `<DefaultShell> <DefaultShellCommandOption> "<command>"`, and DefaultShell can
# be cmd.exe, powershell.exe or Git Bash -- three different parsers with three
# different limits.  Measured by character-wise bisection on a real host
# (2026-09-22):
#
#     Git Bash  (bash -lc "<cmd>")              8,176
#     cmd.exe   (cmd /c "<cmd>")                8,155
#     powershell (-c/-Command "<cmd>")          8,125   <-- the smallest
#
# Exceeding the limit does not fail loudly.  The command line is TRUNCATED; for
# an -EncodedCommand payload that cuts the base64 mid-stream, PowerShell reports
# a parse error ("TerminatorExpectedAtEndOfString"), and the client reports a
# protocol-probe failure -- every command on that host stops working, and the
# message points at the remote deployment rather than at the client's own
# command length.
#
# This is not hypothetical.  The Windows protocol probe grew from 491 to 3,216
# script characters when reparse-point validation was added, putting its command
# line at 8,658 -- over ALL THREE limits.  Nothing in the suite noticed, because
# every other check either parses the file or runs it on macOS.  Length is a
# purely static quantity, so it can be asserted here without any remote host.
#
# WHAT THIS DOES NOT COVER: whether the command actually runs, whether the
# chosen limit is right for a host we have not measured, or the exit-code
# behaviour of each DefaultShell (see PLAN.md A5b -- an outer PowerShell flattens
# non-zero exit codes to 1, which this check cannot see).
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
posix_client="$root/skill/assets/client/unix/agentq"
windows_client="$root/skill/assets/client/windows/agentq.ps1"

# The smallest measured limit, with a deliberate margin: a command that only
# just fits is one small edit away from not fitting.
smallest_measured_limit=8125
safety_margin=256
budget=$((smallest_measured_limit - safety_margin))
# The shortest thing any of these sites can legitimately be (a bare
# `powershell.exe` plus a flag) -- anything below this means the extractor
# found no command line at all.
min_plausible=32

# The exact prefix both clients prepend to the base64 payload.  Its length is
# part of the command line, so it is measured rather than assumed.
prefix='powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '

failures=0

# command_line_length <script-text>
# Encodes exactly as the clients do: UTF-16LE, then base64, then the prefix.
# Reads the script from stdin so multi-line scripts need no quoting games.
command_line_length() {
    local encoded
    encoded=$(iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n') || return 1
    printf '%s' "$(( ${#prefix} + ${#encoded} ))"
}

# extract_between <file> <start-marker> <end-marker>
# Prints the text strictly between the two markers, exclusive.
extract_between() {
    python3 - "$1" "$2" "$3" <<'PY'
import io, sys
path, start_marker, end_marker = sys.argv[1], sys.argv[2], sys.argv[3]
src = io.open(path, encoding='utf-8').read()
i = src.find(start_marker)
if i < 0:
    sys.exit("start marker not found: %s" % start_marker)
j = src.find(end_marker, i + len(start_marker))
if j < 0:
    sys.exit("end marker not found: %s" % end_marker)
sys.stdout.write(src[i + len(start_marker):j])
PY
}

# check_site <label> <length>
check_site() {
    local label=$1 length=$2
    local verdict
    # A zero length is not a short command line -- it is an extraction that
    # matched nothing, and reporting it as "ok" is the false-green this file has
    # already been bitten by twice (the site-2 marker that matched a variable
    # name and reported a meaningless 150).  Every real site is at least a
    # program name, so require a floor rather than trusting `<= budget`.
    if [ "$length" -lt "$min_plausible" ]; then
        printf '%s\n' "FAIL $label: measured $length chars, below the $min_plausible floor -- the extraction matched nothing" >&2
        failures=$((failures + 1))
        return
    fi
    if [ "$length" -le "$budget" ]; then
        verdict='ok'
    else
        verdict='OVER'
        failures=$((failures + 1))
    fi
    printf '%-46s %6s chars  (budget %s)  %s\n' "$label" "$length" "$budget" "$verdict"
}

# 1. POSIX client: the Windows protocol probe.
#
# What matters is the COMMAND LINE the client sends, not the size of the script
# it carries.  A probe that ships its body on stdin has a small constant command
# line no matter how large the script grows -- which is exactly the property the
# fix introduced, so measuring the script would report the fix as still broken.
# The probe's command line is whatever `windows_probe_command_line` prints.
probe_cmdline=$(extract_between "$posix_client" 'windows_probe_command_line() {' '}' |
    grep -o 'powershell\.exe[^"]*')
check_site 'POSIX client: Windows protocol probe' "$(printf '%s' "$probe_cmdline" | wc -c | tr -d '[:space:]')"

# The script body must NOT be on that command line.  If a future edit goes back
# to -EncodedCommand, site 1 above stays short only by accident of the extraction
# and this assertion is what catches it.
if printf '%s' "$probe_cmdline" | grep -q -- '-EncodedCommand'; then
    printf 'POSIX client: Windows protocol probe puts the script on the command line (-EncodedCommand)\n' >&2
    failures=$((failures + 1))
fi
if printf '%s' "$probe_cmdline" | grep -q -- '-Command -'; then
    :
else
    printf 'POSIX client: Windows protocol probe does not read its script from stdin (-Command -)\n' >&2
    failures=$((failures + 1))
fi

# 2. POSIX client: the Windows platform probe.
#
# It does not inline a command line -- it calls the two helpers, so the thing to
# assert is that it ROUTES through them.  Checking only the shared constant
# (which site 1 already measures) would let the platform probe regress to
# -EncodedCommand while every length stayed green.
platform_probe_body=$(extract_between "$posix_client" 'windows_probe_command() {' '}')
if printf '%s' "$platform_probe_body" | grep -q 'make_windows_probe_script_file'; then
    :
else
    printf 'POSIX client: Windows platform probe does not build a stdin script file\n' >&2
    failures=$((failures + 1))
fi
if printf '%s' "$platform_probe_body" | grep -q 'windows_probe_command_line'; then
    :
else
    printf 'POSIX client: Windows platform probe does not use the shared command line\n' >&2
    failures=$((failures + 1))
fi
if printf '%s' "$platform_probe_body" | grep -q -- '-EncodedCommand'; then
    printf 'POSIX client: Windows platform probe puts the script on the command line (-EncodedCommand)\n' >&2
    failures=$((failures + 1))
fi
# Both probes share one command line, so it is measured once (site 1) rather than
# counted twice; report it here so the four-site layout stays legible.
printf '%-46s %6s chars  (budget %s)  %s\n' \
    'POSIX client: Windows platform probe' "${#probe_cmdline}" "$budget" 'ok'

# 3. POSIX client: the launcher wrapper that carries a real submit's arguments.
launcher_script=$(extract_between "$posix_client" "windows_launcher_wrapper='" "'"$'\n')
check_site 'POSIX client: launcher argument wrapper' \
    "$(printf '%s' "$launcher_script" | command_line_length)"

# 4. Windows client: the Windows protocol probe.
#
# Same rule as site 1 -- what matters is the command line, which the client now
# takes from a single constant.  Measure that constant and assert it neither
# carries the script (-EncodedCommand) nor forgets the stdin form (-Command -).
win_probe_cmdline=$(python3 - "$windows_client" <<'PYEOF3'
import io, re, sys
src = io.open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'\$script:WindowsProbeCommandLine\s*=\s*"([^"]*)"', src)
sys.stdout.write(m.group(1) if m else "")
PYEOF3
)
check_site 'Windows client: Windows protocol probe' \
    "$(printf '%s' "$win_probe_cmdline" | wc -c | tr -d '[:space:]')"
if printf '%s' "$win_probe_cmdline" | grep -q -- '-EncodedCommand'; then
    printf 'Windows client: Windows protocol probe puts the script on the command line (-EncodedCommand)\n' >&2
    failures=$((failures + 1))
fi
if printf '%s' "$win_probe_cmdline" | grep -q -- '-Command -'; then
    :
else
    printf 'Windows client: Windows protocol probe does not read its script from stdin (-Command -)\n' >&2
    failures=$((failures + 1))
fi

# 5. Windows client: the launcher argument wrapper.
#
# This site was missing, and its absence was invisible: the check counted four
# sites and the Windows client's OWN launcher wrapper -- a different string from
# the POSIX client's, at a different length -- was never measured.  Padding it
# past the budget changed nothing here.  It is sent the same way (base64 via
# -EncodedCommand), so it is subject to the same truncation failure.
#
# The wrapper is a PowerShell here-string, so the length that matters is the
# length of the COMMAND LINE the client builds: the literal prefix plus the
# base64 of the UTF-16LE wrapper.
win_launcher_len=$(python3 - "$windows_client" <<'PYEOF4'
import base64, io, re, sys
src = io.open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"\$launcherWrapper\s*=\s*@'\r?\n(.*?)\r?\n'@", src, re.S)
if not m:
    sys.stdout.write("0")
    sys.exit(0)
body = m.group(1).replace("\r\n", "\n")
encoded = base64.b64encode(body.encode("utf-16-le")).decode("ascii")
prefix = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "
sys.stdout.write(str(len(prefix) + len(encoded)))
PYEOF4
)
check_site 'Windows client: launcher argument wrapper' "$win_launcher_len"

# The three DefaultShell limits this budget came from, restated so a reader can
# re-derive the number instead of trusting it.
printf '\nlimits measured on a real host: bash=8176 cmd=8155 powershell=8125\n'

if [ "$failures" -ne 0 ]; then
    printf '\n%s remote command line(s) exceed the budget.\n' "$failures" >&2
    printf '%s\n' 'A command over the limit is TRUNCATED by the remote shell, not rejected:' >&2
    printf '%s\n' 'for an -EncodedCommand payload the base64 is cut mid-stream and the' >&2
    printf '%s\n' 'client reports a protocol-probe failure. See PLAN.md A5.' >&2
    exit 1
fi

printf '\nremote-command-length checks passed: sites=5 budget=%s smallest-limit=%s\n' \
    "$budget" "$smallest_measured_limit"
