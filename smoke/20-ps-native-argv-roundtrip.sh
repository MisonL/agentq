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
    printf '%s\n' 'ps-native-argv NOT run: the python3 on PATH cannot execute (a Microsoft Store alias cannot run scripts).' >&2
    printf '%s\n' 'Install a real Python 3 and put it on PATH, then re-run.' >&2
    exit 1
fi
pwsh_binary=${AGENTQ_SMOKE_PWSH:-$(command -v pwsh || true)}

if [ -z "$pwsh_binary" ] || ! command -v "$pwsh_binary" >/dev/null 2>&1; then
    printf 'SKIPPED: pwsh is not available; the PowerShell clients were not executed\n'
    exit 0
fi

# Present is not the same as working.  A corrupt pwsh startup cache makes
# every launch die (measured five times in this repo, with four different
# messages: "String cannot have zero length", "Stack overflow",
# FileLoadException, and Abort trap: 6).  The existence tests above cannot see
# that, so every case below would run against a pwsh that never starts and
# report its failures as asset defects -- the misdiagnosis smoke/01 fixed for
# itself in 2026-09-28.  Probe once: an unusable interpreter is an ENVIRONMENT
# fault, say so with the fix, and do not claim the check ran.
pwsh_probe_status=0
"$pwsh_binary" -NoProfile -NonInteractive -Command 'exit 0' >/dev/null 2>&1 || pwsh_probe_status=$?
if [ "$pwsh_probe_status" -ne 0 ]; then
    printf '%s\n' 'Native-argv contract NOT run: the pwsh on PATH cannot execute (startup cache).' >&2
    printf '%s\n' 'Try: mv ~/.cache/powershell/StartupProfileData-NonInteractive{,.broken}' >&2
    exit 1
fi

work=$(mktemp -d /tmp/agentq-smoke-psargv.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT

# --- the ssh stub: a script on POSIX hosts, a native recorder on Windows -----
# The client under test is a Windows PowerShell on the Windows CI job, and it
# cannot execute the shebang stub the POSIX hosts use: Get-Item cannot resolve
# the MSYS path (the client stops at "SSHP_SSH is not an executable file") and
# CreateProcess cannot run a `#!/bin/sh` file even with a correct path -- which
# is why the first real CI run reported "the client invoked ssh but recorded no
# argv" (37810470283).  There the stub is a native recorder compiled with the
# framework csc: the same technique PLAN.md A21 used to measure these payloads
# on a real PS 5.1 host.  That matters here -- the point of the check is the
# argv a NATIVE ssh.exe would receive, so routing it through a batch file's
# re-parse would measure the wrong thing.
#
# Both forms read the same two variables from the client's environment:
# PS_ARGV_OUT (NUL-separated argv, `>`-truncated so the last call wins) and
# PS_STUB_REPLY (the answer the client validates).  The POSIX stub's reply moved
# from baked-in text to $PS_STUB_REPLY so there is one contract, not two.
stub_windows=0
stub_exe=""
if [ -n "${AGENTQ_SMOKE_PWSH:-}" ] && command -v cygpath >/dev/null 2>&1; then
    stub_windows=1
    stub_exe="$work/stub-ssh.exe"
    stub_cs="$work/stub-ssh.cs"
    cat > "$stub_cs" <<'CS'
using System;
using System.IO;
using System.Text;

// Stand-in for ssh.exe.  Several contracts share this one binary, selected by
// PS_STUB_MODE:
//   empty -- the legacy argv recorder the round-trip cases use (PS_ARGV_OUT +
//   PS_STUB_REPLY);
//   "sshp-win" / "sshp-parity" -- the routing stubs the sshp.ps1 Windows cases
//   drive, answering per the LAST argv element's shape.  These mirror, byte for
//   byte in behaviour, the `stub-ssh-win` / `stub-ssh-parity` sh scripts used
//   on POSIX hosts -- a drift between the two forms is a fixture drift, not a
//   client property.  Windows hosts need this binary because a `#!/bin/sh`
//   file cannot be executed there and the MSYS path cannot even be resolved
//   (measured: the first real CI run, run 37810470283).
// The routing arms, in order (win): `printf %s` platform probe -> MINGW
// marker/43; `-Command -` -> drain stdin (saving it when SSHP_WIN_STDIN is
// set) then READY + the resolved path; `-EncodedCommand` -> save the session
// command, exit 7.  The parity arm additionally appends each stdin-channel
// command to SSHP_PARITY_CALLS and routes on STUB_PARITY_MODE (ready /
// flattened-required / failing).
internal static class StubSsh {
    private static void Record(string path, string text) {
        if (string.IsNullOrEmpty(path)) { return; }
        System.IO.File.WriteAllText(path, text, new UTF8Encoding(false));
    }

    private static void Append(string path, string text) {
        if (string.IsNullOrEmpty(path)) { return; }
        System.IO.File.AppendAllText(path, text + "\n", new UTF8Encoding(false));
    }

    private static string DrainStandardInput(string savePath) {
        string saved = "";
        using (Stream stdin = Console.OpenStandardInput()) {
            using (MemoryStream buffer = new MemoryStream()) {
                byte[] chunk = new byte[65536];
                int read;
                while ((read = stdin.Read(chunk, 0, chunk.Length)) > 0) {
                    buffer.Write(chunk, 0, read);
                }
                byte[] payload = buffer.ToArray();
                if (!string.IsNullOrEmpty(savePath)) {
                    System.IO.File.WriteAllBytes(savePath, payload);
                }
                saved = Encoding.UTF8.GetString(payload);
            }
        }
        return saved;
    }

    private static int Main(string[] args) {
        string argvPath = Environment.GetEnvironmentVariable("PS_ARGV_OUT");
        if (!string.IsNullOrEmpty(argvPath)) {
            using (FileStream stream = new FileStream(argvPath, FileMode.Create, FileAccess.Write)) {
                foreach (string argument in args) {
                    byte[] bytes = Encoding.UTF8.GetBytes(argument);
                    stream.Write(bytes, 0, bytes.Length);
                    stream.WriteByte(0);
                }
            }
        }
        string mode = Environment.GetEnvironmentVariable("PS_STUB_MODE");
        if (mode == "sshp-win") {
            string last = args.Length > 0 ? args[args.Length - 1] : "";
            Record(Environment.GetEnvironmentVariable("SSHP_WIN_LAST"), last);
            if (last.Contains("printf %s")) {
                Console.Out.WriteLine("__SSHP_WINDOWS_SHELL__:MINGW64_NT-10.0-19045");
                return 43;
            }
            if (last.Contains("-Command -")) {
                DrainStandardInput(Environment.GetEnvironmentVariable("SSHP_WIN_STDIN"));
                string zellij = Environment.GetEnvironmentVariable("STUB_ZELLIJ_PATH");
                if (zellij == null) { zellij = "C:\\Users\\me\\scoop\\apps\\zellij\\current\\zellij.exe"; }
                Console.Out.WriteLine("__SSHP_READY__:Windows");
                Console.Out.WriteLine("__SSHP_ZELLIJ__:" + zellij);
                return 0;
            }
            string sessionPath = Environment.GetEnvironmentVariable("SSHP_WIN_SESSION");
            if (last.Contains("-EncodedCommand") && sessionPath != null) {
                Record(sessionPath, last);
                return 7;
            }
            Console.Out.WriteLine("unexpected");
            return 2;
        }
        if (mode == "sshp-parity") {
            string last = args.Length > 0 ? args[args.Length - 1] : "";
            if (last.Contains("printf %s")) {
                Console.Out.WriteLine("__SSHP_WINDOWS_SHELL__:MINGW64_NT-10.0-19045");
                return 43;
            }
            if (last.Contains("-Command -")) {
                Append(Environment.GetEnvironmentVariable("SSHP_PARITY_CALLS"), last);
                DrainStandardInput(null);
                string parityMode = Environment.GetEnvironmentVariable("STUB_PARITY_MODE");
                if (parityMode == "flattened-required") {
                    Console.Out.WriteLine("__SSHP_INSTALL_REQUIRED__:Windows");
                    return 1;
                }
                if (parityMode == "failing") {
                    return 7;
                }
                Console.Out.WriteLine("__SSHP_READY__:Windows");
                Console.Out.WriteLine("__SSHP_ZELLIJ__:C:\\zellij.exe");
                return 0;
            }
            Console.Out.WriteLine("unexpected");
            return 2;
        }
        string reply = Environment.GetEnvironmentVariable("PS_STUB_REPLY");
        if (reply != null) {
            byte[] bytes = Encoding.UTF8.GetBytes(reply + "\n");
            Stream stdout = Console.OpenStandardOutput();
            stdout.Write(bytes, 0, bytes.Length);
            stdout.Flush();
        }
        return 0;
    }
}
CS
    csc="/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
    if [ ! -x "$csc" ]; then
        printf 'ps-native-argv: the framework csc.exe is missing at %s; the native ssh stub cannot be built\n' "$csc" >&2
        exit 1
    fi
    # MSYS2_ARG_CONV_EXCL stops Git Bash from rewriting /nologo and /out: into
    # paths; the file arguments are handed over in Windows form instead.
    MSYS2_ARG_CONV_EXCL='*' "$csc" /nologo "/out:$(cygpath -w "$stub_exe")" "$(cygpath -w "$stub_cs")" >/dev/null 2>&1 || {
        printf 'ps-native-argv: csc.exe could not build the native ssh stub\n' >&2
        exit 1
    }
fi

# win_path <path> -- the Windows form under Windows PowerShell, unchanged else.
win_path() {
    if [ "$stub_windows" = 1 ]; then
        cygpath -w "$1"
    else
        printf '%s' "$1"
    fi
}

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
#
# make_stub <path> writes the POSIX stub script and ECHOES the path the client
# must be handed ($SSHP_SSH/$AGENTQ_SSH): that path is this script on POSIX
# hosts, and the native recorder's Windows form under Windows PowerShell (the
# recorder is shared -- its behaviour is driven entirely by the environment).
make_stub() {
    local path=$1
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' 'for a in "$@"; do printf "%s\\0" "$a"; done > "$PS_ARGV_OUT"'
        printf '%s\n' 'printf "%s\\n" "$PS_STUB_REPLY"'
    } > "$path"
    chmod 700 "$path"
    if [ "$stub_windows" = 1 ]; then
        cygpath -w "$stub_exe"
    else
        printf '%s' "$path"
    fi
}

failures=0
cases=0

# check_roundtrip <label> <argv-file> <expected-fragment>
# Asserts the LAST argv element (the remote command) survives the model:
# exactly one argument, and byte-identical to what the client built.
# (A <client.ps1> parameter used to sit second here and was never read --
# a shellcheck run reported it SC2034; it is gone rather than left looking
# load-bearing.)
check_roundtrip() {
    local label=$1 argvfile=$2 expected=$3
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
    if ! grep -qF -- "$expected" <<< "$sent"; then
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
# Windows PowerShell 5.1 rejects a POSIX path for -File (pwsh 7.5 accepts it), so
# under it the client path is handed over in Windows form.  Same switch as
# smoke/12's client_arg.
sshp_client_arg=$(win_path "$sshp_client")
stub="$work/ssh-sshp"
stub_ssh=$(make_stub "$stub")
mkdir -p "$work/tmp1"
PS_ARGV_OUT="$(win_path "$work/argv-sshp")" SSHP_SSH="$stub_ssh" PS_STUB_REPLY='__SSHP_READY__:Linux' TMPDIR="$work/tmp1" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$sshp_client_arg" --check smoke-host \
    >"$work/o1" 2>"$work/e1" || true
check_roundtrip 'sshp.ps1 unix probe' "$work/argv-sshp" 'base64 -d | sh'

# --- sshp.ps1: the WINDOWS probe command, which must NOT be on the line ------
#
# The MINGW marker in the stub's reply routes the client to the Windows probe.
# That command used to be `powershell.exe ... -EncodedCommand <base64>` with the
# whole ~8.1K resolver + body ON the command line (measured 23,210 chars -- the
# P1 the 2026-10-17 audit found, since smoke/14 measured no sshp.ps1 Windows
# site).  Fixed like agentq.ps1's protocol probe: a short `-Command -` command
# line, the script on STDIN.  Asserted three ways:
#   1. the LAST argv (the command) is short and carries -Command -, NOT
#      -EncodedCommand -- the same two directions site 4 of smoke/14 pins
#      statically, asserted behaviourally here on the real client's output;
#   2. the payload the client piped to the stub's stdin decodes to the script
#      with the marker the client matches on -- the command must DO something;
#   3. the payload carries the resolved-zellij path report the session start
#      depends on (see Get-WindowsSessionCommand's two-stage shape).
mkdir -p "$work/tmp-w"
cat > "$work/stub-ssh-win" <<'WINSTUB'
#!/bin/sh
last=''
for a in "$@"; do last=$a; done
printf '%s' "$last" > "$SSHP_WIN_LAST"
case "$last" in
  *'printf %s'*) printf '__SSHP_WINDOWS_SHELL__:MINGW64_NT-10.0-19045\n'; exit 43 ;;
  *'-Command -'*) cat > "$SSHP_WIN_STDIN"; printf '__SSHP_READY__:Windows\n__SSHP_ZELLIJ__:%s\n' "${STUB_ZELLIJ_PATH:-C:\\Users\\me\\scoop\\apps\\zellij\\current\\zellij.exe}"; exit 0 ;;
  *'-EncodedCommand'*) printf '%s' "$last" > "$SSHP_WIN_SESSION"; exit 7 ;;
esac
printf 'unexpected\n'; exit 2
WINSTUB
chmod 700 "$work/stub-ssh-win"
# Windows hosts cannot execute the sh stub or even resolve its MSYS path (see
# the recorder block above): there the pair below points at the csc-compiled
# binary, whose PS_STUB_MODE routes the same three shapes.  POSIX hosts keep
# the script.  Both forms are exercised by CI -- the Windows branch's first
# execution is the windows-latest job, exactly like every other Windows branch
# in this file.
stub_win_ssh="$work/stub-ssh-win"
stub_win_mode=""
if [ "$stub_windows" = 1 ]; then
    # The client is native on Windows: it needs the recorder's Windows path
    # (same conversion make_stub performs) and the mode that selects the
    # routing contract inside that binary.
    stub_win_ssh=$(cygpath -w "$stub_exe")
    stub_win_mode="sshp-win"
fi
win_status=0
SSHP_WIN_SESSION="$(win_path "$work/win-session")" SSHP_WIN_LAST="$(win_path "$work/win-last")" SSHP_WIN_STDIN="$(win_path "$work/win-stdin")" SSHP_SSH="$stub_win_ssh" PS_STUB_MODE="$stub_win_mode" TMPDIR="$work/tmp-w" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$sshp_client_arg" --check smoke-host \
    >"$work/o-win" 2>"$work/e-win" || win_status=$?
cases=$((cases + 1))
if [ "$win_status" -ne 0 ] || ! grep -qF 'persistent remote session: Zellij (Windows)' "$work/o-win"; then
    printf 'ps-native-argv: sshp.ps1 Windows probe: the client did not reach READY through the stdin channel (exit %s): %s\n' \
        "$win_status" "$(head -1 "$work/e-win")" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
win_last=$(cat "$work/win-last" 2>/dev/null || true)
if [ -z "$win_last" ]; then
    printf 'ps-native-argv: sshp.ps1 Windows probe: the client invoked ssh but no command was recorded\n' >&2
    failures=$((failures + 1))
else
    if [ "${#win_last}" -gt 200 ]; then
        printf 'ps-native-argv: sshp.ps1 Windows probe: the command line is %s chars -- the script went back on the command line\n' "${#win_last}" >&2
        failures=$((failures + 1))
    fi
    if grep -q -- '-EncodedCommand' <<< "$win_last"; then
        printf 'ps-native-argv: sshp.ps1 Windows probe: -EncodedCommand is back on the command line\n' >&2
        failures=$((failures + 1))
    fi
    if ! grep -q -- '-Command -' <<< "$win_last"; then
        printf 'ps-native-argv: sshp.ps1 Windows probe: does not read its script from stdin (-Command -)\n' >&2
        failures=$((failures + 1))
    fi
fi
cases=$((cases + 1))
if ! grep -qF '__SSHP_ZELLIJ__' "$work/win-stdin" 2>/dev/null || ! grep -qF 'Resolve-RemoteZellij' "$work/win-stdin" 2>/dev/null; then
    printf 'ps-native-argv: sshp.ps1 Windows probe: the stdin payload does not carry the resolver script and its zellij-path report\n' >&2
    failures=$((failures + 1))
fi
# --check must never reach the SESSION command: the stub records any
# -EncodedCommand invocation into win-session, and that file must not exist.
cases=$((cases + 1))
if [ -e "$work/win-session" ]; then
    printf 'ps-native-argv: sshp.ps1 --check: started a session command (should be read-only)\n' >&2
    failures=$((failures + 1))
fi

# --- sshp.ps1: CRLF-terminated probe output ---------------------------------
#
# The client redirects ssh's stdout to a file and reads it back.  On Windows
# that file separates lines with CRLF -- PowerShell 5.1's `>` re-emits through
# Out-File (platform newline), and this check's own native recorder writes
# CRLF via WriteLine -- so on the windows-latest job (and on any real Windows
# client) every marker line ends with `\r`.  .NET's `(?m)^...$` does NOT match
# before `\r\n` (measured: the position before `\n` is after `\r`, and `$`
# requires the line to end there), so the two-line READY+ZELLIJ output that
# 0.1.16 introduced failed the READY match and every Windows probe reported
# "remote dependency probe failed" -- measured 2026-10-17 with a CRLF stub,
# while the LF stub stayed green (the whole reason this defect is invisible on
# macOS).  The single-line probe that preceded 0.1.16 survived only because
# .Trim() removes the TRAILING CRLF; an INTERNAL one is untouched.
#
# This case drives the CRLF stub on the POSIX path so the property is pinned
# here too, not only on the Windows job.  The assertion is the client's own
# verdict (READY + the session line), not an implementation detail: any fix
# that normalizes or tolerates CRLF passes.
mkdir -p "$work/tmp-crlf"
cat > "$work/stub-ssh-crlf" <<'CRLFSTUB'
#!/bin/sh
last=''
for a in "$@"; do last=$a; done
printf '%s' "$last" > "$SSHP_WIN_LAST"
case "$last" in
  *'printf %s'*) printf '__SSHP_WINDOWS_SHELL__:MINGW64_NT-10.0-19045\r\n'; exit 43 ;;
  *'-Command -'*) cat > "$SSHP_WIN_STDIN"; printf '__SSHP_READY__:Windows\r\n__SSHP_ZELLIJ__:C:\\zellij.exe\r\n'; exit 0 ;;
  *'-EncodedCommand'*) printf '%s' "$last" > "$SSHP_WIN_SESSION"; exit 7 ;;
esac
printf 'unexpected\r\n'; exit 2
CRLFSTUB
chmod 700 "$work/stub-ssh-crlf"
# Dual-platform wiring, exactly like the win block above: on Windows the csc
# recorder's WriteLine emits Environment.NewLine, which IS CRLF there, so
# PS_STUB_MODE=sshp-win exercises this property natively; POSIX hosts need
# the sh stub (a `#!/bin/sh` file cannot run on Windows and its MSYS path
# cannot even be resolved).
stub_crlf_ssh="$work/stub-ssh-crlf"
stub_crlf_mode=""
if [ "$stub_windows" = 1 ]; then
    stub_crlf_ssh="$stub_win_ssh"
    stub_crlf_mode="$stub_win_mode"
fi
crlf_status=0
SSHP_WIN_SESSION="$(win_path "$work/crlf-session-cmd")" SSHP_WIN_LAST="$(win_path "$work/crlf-last")" SSHP_WIN_STDIN="$(win_path "$work/crlf-stdin")" \
SSHP_SSH="$stub_crlf_ssh" PS_STUB_MODE="$stub_crlf_mode" TMPDIR="$work/tmp-crlf" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$sshp_client_arg" --check smoke-host \
    >"$work/o-crlf" 2>"$work/e-crlf" || crlf_status=$?
cases=$((cases + 1))
if [ "$crlf_status" -ne 0 ] || ! grep -qF 'persistent remote session: Zellij (Windows)' "$work/o-crlf"; then
    printf 'ps-native-argv: sshp.ps1 CRLF probe output: the client did not reach READY (exit %s): %s\n' \
        "$crlf_status" "$(head -1 "$work/e-crlf")" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
# And the path parsed out of the CRLF output must not carry the carriage
# return into the session command.  Positive assertion: the full session must
# reach the stub's -EncodedCommand arm (recorded, exit 7 propagated).  A path
# that still carried `\r` would trip the quote/linebreak guard (exit 2, no
# session command), and a probe that failed would never get that far.
crlf_session_status=0
SSHP_WIN_SESSION="$(win_path "$work/crlf-session-cmd")" SSHP_WIN_LAST="$(win_path "$work/crlf-last")" SSHP_WIN_STDIN="$(win_path "$work/crlf-stdin")" \
SSHP_SSH="$stub_crlf_ssh" PS_STUB_MODE="$stub_crlf_mode" TMPDIR="$work/tmp-crlf" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$sshp_client_arg" smoke-host \
    >"$work/o-crlf2" 2>"$work/e-crlf2" || crlf_session_status=$?
if [ "$crlf_session_status" -ne 7 ] || [ ! -e "$work/crlf-session-cmd" ]; then
    printf 'ps-native-argv: sshp.ps1 CRLF probe output: the parsed Zellij path did not reach a session command (exit %s): %s\n' \
        "$crlf_session_status" "$(head -1 "$work/e-crlf2")" >&2
    failures=$((failures + 1))
fi

# --- sshp.ps1: the two-stage WINDOWS SESSION command -------------------------
#
# The session is the half of the P1 fix that has NO stdin channel: -tt gives the
# pty's stdin to the multiplexer, so the session command rides the command line
# and must stay short AND carry the path the probe resolved.  Three properties,
# each measured on the real client against the real stub above:
#   1. the command embeds the probe's path verbatim (and the session name);
#      a parse that silently drops the path makes the attach meaningless and
#      the next call refuses with "no resolved Zellij path" -- measured mutant:
#      forcing the parse to yield '' left BOTH smoke/14 and this file green,
#      because neither decodes the session command;
#   2. the session's exit code reaches the caller (the stub answers 7);
#   3. a hostile path from the probe answer is REFUSED before it can be
#      embedded -- an apostrophe would close the single-quoted literal and put
#      arbitrary PowerShell on the remote command line; the oversized path
#      (>1024) would push the command line back over the truncation budget.
#      Measured mutant: deleting the quote guard produced a 322-byte session
#      command containing `O'Brien` while every existing check stayed green.
for sess_case in good hostile long; do
    mkdir -p "$work/tmp-sess-$sess_case"
    sess_path='C:\Program Files\zellij\zellij.exe'
    case "$sess_case" in
        hostile) sess_path="C:\\Users\\O'Brien\\zellij.exe" ;;
        long) sess_path=$(awk 'BEGIN{for(i=0;i<1100;i++)printf "p"}') ;;
    esac
    sess_status=0
    STUB_ZELLIJ_PATH="$sess_path" SSHP_WIN_SESSION="$(win_path "$work/sess-$sess_case-cmd")" SSHP_WIN_LAST="$(win_path "$work/sess-$sess_case-last")" SSHP_WIN_STDIN="$(win_path "$work/sess-$sess_case-stdin")" SSHP_SSH="$stub_win_ssh" PS_STUB_MODE="$stub_win_mode" TMPDIR="$work/tmp-sess-$sess_case" \
        "$pwsh_binary" -NoProfile -NonInteractive -File "$sshp_client_arg" smoke-host \
        >"$work/o-sess-$sess_case" 2>"$work/e-sess-$sess_case" || sess_status=$?
    if [ "$sess_case" = good ]; then
        cases=$((cases + 1))
        if [ "$sess_status" -ne 7 ]; then
            printf 'ps-native-argv: sshp.ps1 Windows session: expected the stub exit code 7 to propagate, got %s: %s\n' \
                "$sess_status" "$(head -1 "$work/e-sess-good")" >&2
            failures=$((failures + 1))
        fi
        cases=$((cases + 1))
        decoded=$(python3 - "$work/sess-good-cmd" <<'PYEOF' 2>/dev/null || true
import base64, re, sys
raw = open(sys.argv[1]).read()
m = re.search(r'-EncodedCommand (\S+)', raw)
if m:
    sys.stdout.write(base64.b64decode(m.group(1)).decode('utf-16-le'))
PYEOF
)
        if [ -z "$decoded" ]; then
            printf 'ps-native-argv: sshp.ps1 Windows session: no decodable -EncodedCommand was emitted\n' >&2
            failures=$((failures + 1))
        elif ! grep -qF "attach --create 'ghostty'" <<< "$decoded"; then
            printf 'ps-native-argv: sshp.ps1 Windows session: the attach/session part is missing: %s\n' "$decoded" >&2
            failures=$((failures + 1))
        elif ! grep -qF "& 'C:\Program Files\zellij\zellij.exe' attach" <<< "$decoded"; then
            printf 'ps-native-argv: sshp.ps1 Windows session: the resolved Zellij path was not embedded verbatim (dropped or rewritten): %s\n' "$decoded" >&2
            failures=$((failures + 1))
        fi
    else
        cases=$((cases + 1))
        if [ "$sess_status" -ne 2 ]; then
            printf 'ps-native-argv: sshp.ps1 Windows session %s-path: expected refusal exit 2, got %s\n' "$sess_case" "$sess_status" >&2
            failures=$((failures + 1))
        fi
        cases=$((cases + 1))
        if [ -e "$work/sess-$sess_case-cmd" ]; then
            printf 'ps-native-argv: sshp.ps1 Windows session %s-path: a session command was emitted despite the guard\n' "$sess_case" >&2
            failures=$((failures + 1))
        fi
    fi
done
cases=$((cases + 1))
if ! grep -qF 'the resolved Zellij path contains a quote or line break' "$work/e-sess-hostile" 2>/dev/null; then
    printf 'ps-native-argv: sshp.ps1 Windows session hostile-path: the refusal message is missing\n' >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if ! grep -qF 'the resolved Zellij path is longer than 1024 characters' "$work/e-sess-long" 2>/dev/null; then
    printf 'ps-native-argv: sshp.ps1 Windows session long-path: the refusal message is missing\n' >&2
    failures=$((failures + 1))
fi

# --- sshp.ps1: the five 0.1.16 parity fixes, each driven behaviourally --------
#
# Reverting any ONE of these fixes left every check green (measured 2026-10-17,
# right after the release): smoke/20 exercised none of them, smoke/14 measures
# only lengths, and no other check runs this client at all. The POSIX twin has
# its own locks for the same properties in smoke/19, so an unlocked ps1 side is
# exactly the silent divergence the 0.1.16 theme was supposed to end.
#
# Each case drives the real client through the stub defined above:
#   1. SSHP_RECONNECT_DELAY='+5' must be refused at startup (exit 2).  The POSIX
#      twin refuses it; [int]::TryParse alone accepts it (measured: +5 -> 5).
#      Before 0.1.16 the two clients disagreed on the same input.
#   2. An installable host whose exit code is FLATTENED (the A5b form: a
#      DefaultShell=powershell.exe sshd turns a native 42 into 1) must still be
#      read as INSTALL_REQUIRED from the marker, and --check must still refuse
#      to install (exit 127 + the missing-dependency message).  A marker+code
#      pair check reads 1+REQUIRED as "probe failed" and points at the wrong
#      thing -- and after the 0.1.16 probeExitCode change a probe failure would
#      print the FLATTENED code, making the misreport harder to spot.
#   3. A probe that fails with its own code (7) and no marker must propagate 7,
#      not collapse to 2 (the POSIX twin propagates; measured mutant: reverting
#      to a flat 2 stayed green everywhere).
#   4. `-h extra` and `--check --help` are help requests (exit 0, usage on
#      stdout, no ssh call) -- the POSIX twin's semantics, pinned by smoke/19's
#      --help case for the POSIX side.
#   5. An EMPTY session-name argument falls back to the default (ghostty),
#      exactly like the POSIX `${2:-ghostty}`; assigning '' hit the charset
#      guard and refused, the mirror-image divergence of smoke/19's
#      "empty session name is accepted" case.
mkdir -p "$work/tmp-parity"
cat > "$work/stub-ssh-parity" <<'PARITYSTUB'
#!/bin/sh
last=''
for a in "$@"; do last=$a; done
case "$last" in
  *'printf %s'*) printf '__SSHP_WINDOWS_SHELL__:MINGW64_NT-10.0-19045\n'; exit 43 ;;
  *'-Command -'*)
    printf '%s\n' "$last" >> "$SSHP_PARITY_CALLS"
    cat > /dev/null
    case "${STUB_PARITY_MODE:-ready}" in
      ready) printf '__SSHP_READY__:Windows\n__SSHP_ZELLIJ__:C:\\zellij.exe\n'; exit 0 ;;
      flattened-required) printf '__SSHP_INSTALL_REQUIRED__:Windows\n'; exit 1 ;;
      failing) printf ''; exit 7 ;;
    esac
    ;;
esac
printf 'unexpected\n'; exit 2
PARITYSTUB
chmod 700 "$work/stub-ssh-parity"
stub_parity_ssh="$work/stub-ssh-parity"
stub_parity_mode=""
if [ "$stub_windows" = 1 ]; then
    stub_parity_ssh=$(cygpath -w "$stub_exe")
    stub_parity_mode="sshp-parity"
fi

parity_run() {
    local label=$1 expected=$2 needle=$3 mode=$4 delay=$5
    shift 5
    local output="$work/parity-$label-out" error="$work/parity-$label-err"
    local status=0
    SSHP_PARITY_CALLS="$(win_path "$work/parity-$label-calls")" STUB_PARITY_MODE="$mode" \
        SSHP_SSH="$stub_parity_ssh" PS_STUB_MODE="$stub_parity_mode" SSHP_RECONNECT_DELAY="$delay" TMPDIR="$work/tmp-parity" \
        "$pwsh_binary" -NoProfile -NonInteractive -File "$sshp_client_arg" "$@" \
        >"$output" 2>"$error" || status=$?
    cases=$((cases + 1))
    if [ "$status" -ne "$expected" ]; then
        printf 'ps-native-argv: sshp.ps1 parity (%s): expected exit %s, got %s: %s\n' \
            "$label" "$expected" "$status" "$(head -1 "$error")" >&2
        failures=$((failures + 1))
    fi
    cases=$((cases + 1))
    if [ -n "$needle" ] && ! grep -qF "$needle" "$error" "$output" 2>/dev/null; then
        printf 'ps-native-argv: sshp.ps1 parity (%s): expected message missing: %s\n' "$label" "$needle" >&2
        failures=$((failures + 1))
    fi
}

# 1. reconnect delay: `+5` refused at startup.  The delay is validated before
#    the host arguments, so no host is needed to reach it.
parity_run 'delay-plus' 2 'SSHP_RECONNECT_DELAY must be a non-negative 32-bit integer' ready '+5'
# 2. flattened installable host: the marker decides, and --check never installs.
parity_run 'flattened-required' 127 'native Zellij is required on Windows' flattened-required '' --check smoke-host
cases=$((cases + 1))
flattened_calls=$(wc -l < "$work/parity-flattened-required-calls" 2>/dev/null || printf '0')
if [ "$flattened_calls" -gt 3 ]; then
    printf 'ps-native-argv: sshp.ps1 parity (flattened-required): %s ssh calls -- the client tried to INSTALL under --check\n' "$flattened_calls" >&2
    failures=$((failures + 1))
fi
# 3. probe failure propagates its own code, not a flat 2.
parity_run 'probe-propagates' 7 'remote dependency probe failed' failing '' --check smoke-host
# 4. help semantics: `-h extra` and `--check --help` are help requests.
parity_run 'help-extra' 0 'Usage:' ready '' -h extra
parity_run 'help-after-check' 0 'Usage:' ready '' --check --help
# 5. empty session argument falls back to the default (ghostty).  The empty
#    argument is passed as its own argv element -- quoted, so bash keeps it.
parity_run 'empty-session' 0 'persistent remote session: Zellij (Windows)' ready '' --check smoke-host ''
# 6. A host carrying ANY whitespace is refused at startup, like the POSIX
#    twin's `*[[:space:]]*` guard.  IsNullOrWhiteSpace alone (the pre-fix
#    form) only caught a whitespace-ONLY name: measured 2026-10-17,
#    `sshp.ps1 --check 'foo bar'` exited 0 and ran the probe against a name
#    ssh has to quote its way through, while the POSIX client refused with
#    exit 2.  0.1.16 added the POSIX guard but not this one -- the same
#    one-side-only divergence the version set out to end.  The tab form is
#    asserted too: a space-only fixture cannot tell `[[:space:]]` from a
#    literal-space test.
parity_run 'host-whitespace' 2 'SSH host must not contain whitespace' ready '' --check 'foo bar'
parity_run 'host-tab' 2 'SSH host must not contain whitespace' ready '' --check "$(printf 'host\ttab')"
# 7. The install confirmation must come from a TERMINAL.  SKILL.md promises
#    "the first connection asks before installing it; with no TTY the client
#    refuses explicitly and never installs silently", and that had no
#    behavioural lock on either client until 2026-10-17.  The strong form is
#    asserted: stdin is a pipe carrying `y`, so a client that only checked
#    whether input was available (or read the answer without a tty test) would
#    install.  `flattened-required` is exactly the installable-host answer.
#    Assertions: exit 1, the refusal message, and at most 2 ssh calls (the
#    platform probe + the Windows probe) -- an install attempt is a third.
#    DELIBERATELY without -NonInteractive: sshp.cmd and sshp.bash both invoke
#    `powershell.exe -NoProfile -ExecutionPolicy Bypass -File` (checked in the
#    assets), so the REAL invocation lets Read-Host consume a pipe.  With
#    -NonInteractive, Read-Host throws instead, the catch prints the same
#    refusal, and deleting the IsInputRedirected guard is invisible -- measured
#    2026-10-17: mutant M6 (guard removed) stayed green under -NonInteractive
#    and ran the installer (3 ssh calls) without it.  The lock must model the
#    launcher's argv, not a stricter one.
install_status=0
printf 'y\n' > "$work/parity-yes-stdin"
SSHP_PARITY_CALLS="$(win_path "$work/parity-install-calls")" STUB_PARITY_MODE=flattened-required \
    SSHP_SSH="$stub_parity_ssh" PS_STUB_MODE="$stub_parity_mode" SSHP_RECONNECT_DELAY='' TMPDIR="$work/tmp-parity" \
    "$pwsh_binary" -NoProfile -File "$sshp_client_arg" smoke-host <"$work/parity-yes-stdin" \
    >"$work/parity-install-out" 2>"$work/parity-install-err" || install_status=$?
cases=$((cases + 1))
if [ "$install_status" -ne 1 ]; then
    printf 'ps-native-argv: sshp.ps1 piped-y install: expected exit 1, got %s: %s\n' \
        "$install_status" "$(head -1 "$work/parity-install-err")" >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
if ! grep -qF 'dependency installation requires an interactive local terminal' "$work/parity-install-err"; then
    printf 'ps-native-argv: sshp.ps1 piped-y install: the no-tty refusal message is missing\n' >&2
    failures=$((failures + 1))
fi
cases=$((cases + 1))
install_calls=$(wc -l < "$work/parity-install-calls" 2>/dev/null || printf '0')
if [ "${install_calls:-0}" -gt 1 ]; then
    printf 'ps-native-argv: sshp.ps1 piped-y install: %s ssh call(s) -- a piped confirmation reached the installer\n' "$install_calls" >&2
    failures=$((failures + 1))
fi

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
PS_ARGV_OUT="$(win_path "$work/argv-session")" SSHP_SSH="$stub_ssh" PS_STUB_REPLY='__SSHP_READY__:Linux' TMPDIR="$work/tmp1s" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$sshp_client_arg" smoke-host smoke-session \
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
    if grep -qF 'base64 -d | sh' <<< "$session_cmd"; then
        session_wrapped=1
        printf 'ps-native-argv: sshp.ps1 session: the session command was base64-wrapped; it must stay a raw argument because the pipe channel hands tmux/screen a non-tty stdin\n' >&2
        failures=$((failures + 1))
    fi
    # Direction 2: it must carry the multiplexer dispatch intact.
    if [ "$session_wrapped" -eq 0 ]; then
        cases=$((cases + 1))
        if ! grep -qF 'exec tmux new-session -A -s' <<< "$session_cmd"; then
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
PS_ARGV_OUT="$(win_path "$work/argv-quote")" SSHP_SSH="$stub_ssh" PS_STUB_REPLY='__SSHP_READY__:Linux' TMPDIR="$work/tmp2q" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$sshp_client_arg" smoke-host "quo'te" \
    >"$work/o2q" 2>"$work/e2q" || quote_status=$?
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
agentq_client_arg=$(win_path "$agentq_client")
stub2="$work/ssh-agentq"
stub2_ssh=$(make_stub "$stub2")
mkdir -p "$work/tmp2"
PS_ARGV_OUT="$(win_path "$work/argv-agentq")" AGENTQ_SSH="$stub2_ssh" PS_STUB_REPLY='{"ok":true}' AGENTQ_CONFIG="$work/no-config" \
    AGENTQ_HOST=smoke-host AGENTQ_REMOTE_PLATFORM=unix TMPDIR="$work/tmp2" \
    "$pwsh_binary" -NoProfile -NonInteractive -File "$agentq_client_arg" status \
    >"$work/o2" 2>"$work/e2" || true
check_roundtrip 'agentq.ps1 unix operation' "$work/argv-agentq" 'base64 -d | sh'

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
printf 'ps-native-argv checks passed: cases=%s model=calibrated(%s rows) pwsh=%s\n' "$cases" "$selftest_rows" \
    "$("$pwsh_binary" -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || printf 'unknown')"
