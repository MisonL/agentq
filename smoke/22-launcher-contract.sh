#!/usr/bin/env bash
# Smoke: assets/windows-git-bash/agentq-launcher.ps1 -- the parts of it that run
# on this machine.
#
# Why this check exists: at 430 lines it is the LARGEST asset in the repo that no
# check has ever executed (CLAUDE.md's "no check has ever executed it" table; 01
# parses it with the PowerShell AST, 10 asserts a couple of source invariants
# about the launcher protocol, but neither runs a line of it).  It is also one of
# the THREE copies of the launcher payload protocol that smoke/10's rule E keeps
# in sync at the SOURCE level -- there was never a behavioural assertion on any
# of the three.
#
# It ALSO covers agentq-start-daemon.ps1's two path guards.  Those guards are
# near-verbatim copies of the launcher's (the repo's recurring "same mechanism
# written in several places, only one gets fixed" pathology -- A9, A19, rule E),
# and start-daemon itself is otherwise unreachable here.  Asserting BOTH copies
# behave identically is what catches a fix applied to one and not the other.
#
# What runs here and what does not, measured, not assumed:
#   - RUNS: Read-AgentQArguments (the NUL-separated base64 payload decoder), the
#     launcher's runtime/required file-path guards, start-daemon's two guards,
#     and the bash "environment -> positional arguments" round-trip script the
#     launcher writes out and hands to Git Bash.  None of these touch a Windows
#     API, so pwsh 7.5 on macOS executes them.
#   - DOES NOT RUN: Get-CurrentWindowsUserEnvironment (WindowsIdentity +
#     HKLM ProfileList) and everything downstream of it -- Assert-...RequiredFile
#     on the real server path, New-AgentQLauncherRuntimePath against the real
#     root, and the actual `& $gitBashPath` invocation.  Those need a real
#     Windows host.  This check says so on its summary line rather than implying
#     the whole file was exercised.
#
# The payload decoder is worth its own note: it is the receiving end of the
# protocol smoke/10 rule E compares across three files.  A drift that kept the
# three copies byte-identical but broke the DECODER would pass rule E and every
# other check.  This one runs the decoder.
set -euo pipefail

root=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
launcher="$root/skill/assets/windows-git-bash/agentq-launcher.ps1"
start_daemon="$root/skill/assets/windows-git-bash/agentq-start-daemon.ps1"
[ -f "$launcher" ] || { printf '%s\n' 'launcher-contract: missing launcher asset' >&2; exit 1; }
[ -f "$start_daemon" ] || { printf '%s\n' 'launcher-contract: missing start-daemon asset' >&2; exit 1; }

pwsh_binary=${AGENTQ_SMOKE_PWSH:-$(command -v pwsh || true)}
if [ -z "$pwsh_binary" ]; then
    printf '%s\n' 'SKIPPED: pwsh is not available; the launcher was not executed'
    exit 0
fi

# The launcher's path guards reject any path whose chain contains a symlink, and
# on macOS /tmp IS a symlink -- so the PowerShell side must be handed a resolved
# path.  `pwd -P` here; the PowerShell helper does the same via GetFullPath plus
# its own parent-chain walk.  Same idiom as smoke/05, 11, 13, 19.
work=$(mktemp -d /tmp/agentq-smoke-launcher.XXXXXX)
work=$(unset CDPATH; cd -- "$work" && pwd -P)
cleanup_sandbox() { rm -rf -- "$work"; }
trap cleanup_sandbox EXIT HUP INT TERM

failures=0
cases=0

# A PowerShell driver that extracts the pure functions from the REAL asset (not
# a copy) and exercises them, printing "label=value" lines the shell asserts on.
# Extraction is by function-name regex so it keeps working as the file changes;
# if a function is renamed the extraction fails loudly rather than testing air.
driver="$work/driver.ps1"
cat > "$driver" <<'PS1'
param([string]$LauncherPath, [string]$StartDaemonPath, [string]$WorkDirectory)
$ErrorActionPreference = "Stop"

function Get-Fn([string]$src, [string]$name) {
    $pattern = '(?s)function ' + [regex]::Escape($name) + ' \{.*?\n\}\n'
    $m = [regex]::Match($src, $pattern)
    if (-not $m.Success) { throw "could not extract function $name" }
    return $m.Value
}

$src = Get-Content -Raw $LauncherPath
$sdSrc = Get-Content -Raw $StartDaemonPath

$names = @(
    'Read-AgentQBoundedText',
    'Read-AgentQArguments',
    'Test-AgentQLauncherRuntimeFilePath',
    'Assert-AgentQLauncherRuntimeFilePath',
    'Remove-AgentQLauncherRuntimeFile',
    'Test-AgentQLauncherRequiredFilePath',
    'Assert-AgentQLauncherRequiredFile'
)
foreach ($n in $names) { Invoke-Expression (Get-Fn $src $n) }

# start-daemon's two guards, extracted from the REAL asset.  Their names differ
# (Test-NonReparseWindows*) so they load alongside the launcher's without clashing.
$sdNames = @('Test-NonReparseWindowsProfilePath', 'Test-NonReparseWindowsRequiredFilePath')
foreach ($n in $sdNames) { Invoke-Expression (Get-Fn $sdSrc $n) }

# Set-AgentQUserEnvironment is the other pure-.NET function in start-daemon: it
# takes a resolved user-environment object and pushes 16 variables into the
# PROCESS environment.  It carries a documented security property -- the daemon
# must derive HOME/USERPROFILE from the process SID's profile, NOT from whatever
# USERPROFILE/HOME the ambient (Git Bash / OpenSSH / runas) environment happens
# to hold -- so it is worth driving rather than trusting.  It touches no Windows
# API of its own (only [Environment]::SetEnvironmentVariable), so it runs here.
foreach ($n in @('Set-AgentQUserEnvironment')) { Invoke-Expression (Get-Fn $sdSrc $n) }

function Emit([string]$label, $value) { Write-Output ("$label=" + $value) }

# --- payload decoder ----------------------------------------------------------
function Encode-Args([string[]]$items) {
    $bytes = [System.Collections.Generic.List[byte]]::new()
    foreach ($a in $items) {
        foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($a)) { [void]$bytes.Add($b) }
        [void]$bytes.Add(0)
    }
    return [Convert]::ToBase64String($bytes.ToArray())
}

$decoded = Read-AgentQArguments -Encoded (Encode-Args @('submit','--workdir','/tmp/my dir'))
Emit 'decoded.argc' $decoded.Count
Emit 'decoded.arg0' $decoded[0]
Emit 'decoded.arg2' $decoded[2]
# A non-ASCII argument must survive the UTF-8 round-trip (the server receives it
# verbatim; a byte-wise bug here would corrupt paths with spaces and accents).
$unicode = Read-AgentQArguments -Encoded (Encode-Args @('任务','ünïcode'))
Emit 'decoded.unicode0' $unicode[0]
Emit 'decoded.unicode1' $unicode[1]

# Rejections: each must throw, not return something usable.
#
# Mutation note, recorded honestly: removing the decoder's own
# `IsNullOrWhiteSpace` guard (M5) is NOT caught here, and it is a BENIGN
# mutation, not a coverage hole.  An empty payload still throws -- downstream,
# from `if ($arguments.Count -eq 0) { throw "AgentQ argument payload contains no
# arguments" }` -- so the rejection property holds either way; only the message
# differs.  Verified by running the mutated decoder directly: `''` and `'   '`
# both still throw.  Asserting the exact message would catch M5 but would pin an
# implementation detail (which guard fires), not a contract, so it is not done.
function Test-Rejects([string]$label, [scriptblock]$body) {
    try { & $body | Out-Null; Emit $label 'NOT-REJECTED' }
    catch { Emit $label 'rejected' }
}
Test-Rejects 'reject.empty'      { Read-AgentQArguments -Encoded '' }
Test-Rejects 'reject.badbase64'  { Read-AgentQArguments -Encoded 'not base64!!' }
Test-Rejects 'reject.noNul'      { Read-AgentQArguments -Encoded ([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('status'))) }

# --- path guards --------------------------------------------------------------
$d = $WorkDirectory
$file = Join-Path $d 'regular.txt'
Set-Content -Path $file -Value 'x'
$dir = Join-Path $d 'subdir'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$link = Join-Path $d 'filelink'
if (-not (Test-Path $link)) { New-Item -ItemType SymbolicLink -Path $link -Target $file | Out-Null }
# A symlink to a DIRECTORY, and a real file inside it.  This is what exercises
# the PARENT-CHAIN walk: the leaf (inner.txt) is an ordinary file, so only the
# walk over its ancestors can notice the linked directory above it.  A link to a
# FILE (above) is rejected by the leaf check and never reaches the walk -- which
# is why the first version of this check missed a mutation that removed the
# parent-chain reparse check (M7, a real coverage hole, now closed).
$dirLink = Join-Path $d 'dirlink'
if (-not (Test-Path $dirLink)) { New-Item -ItemType SymbolicLink -Path $dirLink -Target $dir | Out-Null }
# A REAL subdirectory reached THROUGH the link.  The profile guard requires the
# path itself to be an existing directory, so `$dirLink/sub` must actually exist
# -- otherwise Get-Item throws, the guard returns False at the leaf, and the
# parent-chain walk is never reached (the fixture bug that made M7 pass).
# Creating it via the link writes into $dir/sub; the guard then sees a real
# directory whose ANCESTOR ($dirLink) is a reparse point.
$innerDir = Join-Path $dirLink 'sub'
New-Item -ItemType Directory -Path $innerDir -Force | Out-Null
$innerFile = Join-Path $dirLink 'inner.txt'
Set-Content -Path $innerFile -Value 'z'

Emit 'required.regularFile' (Test-AgentQLauncherRequiredFilePath -Path $file)
Emit 'required.directory'   (Test-AgentQLauncherRequiredFilePath -Path $dir)
Emit 'required.missing'     (Test-AgentQLauncherRequiredFilePath -Path (Join-Path $d 'nope'))
Emit 'required.empty'       (Test-AgentQLauncherRequiredFilePath -Path '')
Emit 'required.symlink'     (Test-AgentQLauncherRequiredFilePath -Path $link)
# The leaf is a real file; only the parent-chain walk can reject it.
Emit 'required.underLinkedDir' (Test-AgentQLauncherRequiredFilePath -Path $innerFile)

Emit 'runtime.regularFile'  (Test-AgentQLauncherRuntimeFilePath -Path $file)
Emit 'runtime.directory'    (Test-AgentQLauncherRuntimeFilePath -Path $dir)
Emit 'runtime.underLinkedDir' (Test-AgentQLauncherRuntimeFilePath -Path $innerFile)

# start-daemon's guards, on the same fixtures.  Profile guard wants a DIRECTORY,
# required guard wants a FILE -- and both must refuse a reparse point.
Emit 'sd.profile.directory'   (Test-NonReparseWindowsProfilePath -Path $dir)
Emit 'sd.profile.file'        (Test-NonReparseWindowsProfilePath -Path $file)
Emit 'sd.profile.symlink'     (Test-NonReparseWindowsProfilePath -Path $link)
Emit 'sd.profile.underLinkedDir' (Test-NonReparseWindowsProfilePath -Path (Join-Path $dirLink 'sub'))
Emit 'sd.required.file'       (Test-NonReparseWindowsRequiredFilePath -Path $file)
Emit 'sd.required.directory'  (Test-NonReparseWindowsRequiredFilePath -Path $dir)
Emit 'sd.required.symlink'    (Test-NonReparseWindowsRequiredFilePath -Path $link)
# A file UNDER a symlinked directory: the parent-chain walk must catch it.
Emit 'sd.required.underLink'  (Test-NonReparseWindowsRequiredFilePath -Path $innerFile)

# --- Set-AgentQUserEnvironment: the process env must come from the SID profile --
# Drive it with a synthetic user-environment object and read back what it set.
# The values are deliberately unlike the ambient environment (a real Windows
# profile path), so a function that merely PASSED THROUGH the inherited env --
# the exact defect the comment in the asset warns about -- would leave HOME and
# USERPROFILE at their smoke-run values instead of the object's.
$ambientHome = $env:HOME
$ambientProfile = $env:USERPROFILE
$fake = [pscustomobject]@{
    Profile          = 'C:\Users\SidResolved'
    UserName         = 'SidResolved'
    AppData          = 'C:\Users\SidResolved\AppData\Roaming'
    LocalAppData     = 'C:\Users\SidResolved\AppData\Local'
    HomeDrive        = 'C:'
    HomePath         = '\Users\SidResolved'
    Temp             = 'C:\Users\SidResolved\AppData\Local\Temp'
    Path             = 'C:\Windows;C:\Tools'
    PathExt          = '.COM;.EXE;.BAT'
    ComSpec          = 'C:\Windows\system32\cmd.exe'
    SystemDrive      = 'C:'
    WindowsDirectory = 'C:\Windows'
    SystemRoot       = 'C:\Windows'
}
Set-AgentQUserEnvironment -UserEnvironment $fake
Emit 'env.HOME'        ([Environment]::GetEnvironmentVariable('HOME','Process'))
Emit 'env.USERPROFILE' ([Environment]::GetEnvironmentVariable('USERPROFILE','Process'))
Emit 'env.USERNAME'    ([Environment]::GetEnvironmentVariable('USERNAME','Process'))
Emit 'env.APPDATA'     ([Environment]::GetEnvironmentVariable('APPDATA','Process'))
Emit 'env.TEMP'        ([Environment]::GetEnvironmentVariable('TEMP','Process'))
Emit 'env.TMP'         ([Environment]::GetEnvironmentVariable('TMP','Process'))
Emit 'env.PATHEXT'     ([Environment]::GetEnvironmentVariable('PATHEXT','Process'))
Emit 'env.SystemRoot'  ([Environment]::GetEnvironmentVariable('SystemRoot','Process'))
Emit 'env.USER'        ([Environment]::GetEnvironmentVariable('USER','Process'))
Emit 'env.LOCALAPPDATA' ([Environment]::GetEnvironmentVariable('LOCALAPPDATA','Process'))
Emit 'env.HOMEDRIVE'   ([Environment]::GetEnvironmentVariable('HOMEDRIVE','Process'))
Emit 'env.HOMEPATH'    ([Environment]::GetEnvironmentVariable('HOMEPATH','Process'))
Emit 'env.Path'        ([Environment]::GetEnvironmentVariable('Path','Process'))
Emit 'env.ComSpec'     ([Environment]::GetEnvironmentVariable('ComSpec','Process'))
Emit 'env.SystemDrive' ([Environment]::GetEnvironmentVariable('SystemDrive','Process'))
Emit 'env.WINDIR'      ([Environment]::GetEnvironmentVariable('WINDIR','Process'))
# Both aliases must be set from the SAME source field, not left to chance.
Emit 'env.TEMP_eq_TMP' ([Environment]::GetEnvironmentVariable('TEMP','Process') -ceq [Environment]::GetEnvironmentVariable('TMP','Process'))
Emit 'env.HOME_eq_USERPROFILE' ([Environment]::GetEnvironmentVariable('HOME','Process') -ceq [Environment]::GetEnvironmentVariable('USERPROFILE','Process'))
Emit 'env.ambient_home_ignored' ([Environment]::GetEnvironmentVariable('HOME','Process') -cne $ambientHome)

# Assert-* must THROW on a bad path and not throw on a good one.
Test-Rejects 'assert.requiredRejectsDir' { Assert-AgentQLauncherRequiredFile -Path $dir -Description 'test' }
try { Assert-AgentQLauncherRequiredFile -Path $file -Description 'test'; Emit 'assert.requiredAcceptsFile' 'ok' }
catch { Emit 'assert.requiredAcceptsFile' ('threw: ' + $_.Exception.Message) }
Test-Rejects 'assert.runtimeRejectsDir'  { Assert-AgentQLauncherRuntimeFilePath -Path $dir }

# Remove must refuse an unsafe path (a directory) and must actually remove a
# regular file, then confirm it is gone.
Emit 'remove.rejectsDirectory' (Remove-AgentQLauncherRuntimeFile -Path $dir)
$victim = Join-Path $d 'victim.txt'; Set-Content -Path $victim -Value 'y'
$removedOk = Remove-AgentQLauncherRuntimeFile -Path $victim
Emit 'remove.removedFile' ($removedOk -and -not (Test-Path $victim))
PS1

run_driver() {
    local status=0
    "$pwsh_binary" -NoProfile -NonInteractive -File "$driver" -LauncherPath "$launcher" -StartDaemonPath "$start_daemon" -WorkDirectory "$work/pw" \
        >"$work/driver.out" 2>"$work/driver.err" || status=$?
    printf '%s' "$status"
}

mkdir -p "$work/pw"
cases=$((cases + 1))
if [ "$(run_driver)" -ne 0 ]; then
    printf 'launcher-contract: the PowerShell driver failed to run\n' >&2
    head -3 "$work/driver.err" >&2 || true
    failures=$((failures + 1))
fi

# assert_eq <label> <expected>
assert_eq() {
    local label=$1 expected=$2
    cases=$((cases + 1))
    local actual
    actual=$(sed -n "s/^${label}=//p" "$work/driver.out")
    if [ "$actual" != "$expected" ]; then
        printf 'launcher-contract %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}

# --- decoder assertions -------------------------------------------------------
assert_eq 'decoded.argc'      '3'
assert_eq 'decoded.arg0'      'submit'
assert_eq 'decoded.arg2'      '/tmp/my dir'
assert_eq 'decoded.unicode0'  '任务'
assert_eq 'decoded.unicode1'  'ünïcode'
assert_eq 'reject.empty'      'rejected'
assert_eq 'reject.badbase64'  'rejected'
assert_eq 'reject.noNul'      'rejected'

# --- path-guard assertions ----------------------------------------------------
assert_eq 'required.regularFile' 'True'
assert_eq 'required.directory'   'False'
assert_eq 'required.missing'     'False'
assert_eq 'required.empty'       'False'
# The security-relevant one: a symlink is a reparse point and must be refused,
# so the launcher never writes its runtime script through a link.
assert_eq 'required.symlink'     'False'
assert_eq 'required.underLinkedDir' 'False'
assert_eq 'runtime.regularFile'  'True'
assert_eq 'runtime.underLinkedDir' 'False'
assert_eq 'runtime.directory'    'False'
# start-daemon guards: profile wants a directory, required wants a file, both
# refuse a symlink (the parent-chain walk catches a file under a linked dir).
assert_eq 'sd.profile.directory'  'True'
assert_eq 'sd.profile.file'       'False'
assert_eq 'sd.profile.symlink'    'False'
assert_eq 'sd.profile.underLinkedDir' 'False'
assert_eq 'sd.required.file'      'True'
assert_eq 'sd.required.directory' 'False'
assert_eq 'sd.required.symlink'   'False'
assert_eq 'sd.required.underLink' 'False'
assert_eq 'assert.requiredRejectsDir'  'rejected'
assert_eq 'assert.requiredAcceptsFile' 'ok'
assert_eq 'assert.runtimeRejectsDir'   'rejected'
assert_eq 'remove.rejectsDirectory'    'False'
assert_eq 'remove.removedFile'         'True'
# Set-AgentQUserEnvironment must take every value from the SID-resolved object.
assert_eq 'env.HOME'        'C:\Users\SidResolved'
assert_eq 'env.USERPROFILE' 'C:\Users\SidResolved'
assert_eq 'env.USERNAME'    'SidResolved'
assert_eq 'env.APPDATA'     'C:\Users\SidResolved\AppData\Roaming'
assert_eq 'env.TEMP'        'C:\Users\SidResolved\AppData\Local\Temp'
assert_eq 'env.TMP'         'C:\Users\SidResolved\AppData\Local\Temp'
assert_eq 'env.PATHEXT'     '.COM;.EXE;.BAT'
assert_eq 'env.SystemRoot'  'C:\Windows'
assert_eq 'env.USER'         'SidResolved'
assert_eq 'env.LOCALAPPDATA' 'C:\Users\SidResolved\AppData\Local'
assert_eq 'env.HOMEDRIVE'    'C:'
assert_eq 'env.HOMEPATH'     '\Users\SidResolved'
assert_eq 'env.Path'         'C:\Windows;C:\Tools'
assert_eq 'env.ComSpec'      'C:\Windows\system32\cmd.exe'
assert_eq 'env.SystemDrive'  'C:'
assert_eq 'env.WINDIR'       'C:\Windows'
assert_eq 'env.TEMP_eq_TMP' 'True'
assert_eq 'env.HOME_eq_USERPROFILE' 'True'
# The whole point: the ambient HOME must NOT survive.  If the function were a
# no-op (or passed the inherited env through), HOME would still be the smoke
# run's value and this is the assertion that says so.
assert_eq 'env.ambient_home_ignored' 'True'

# --- the bash round-trip script ----------------------------------------------
# The launcher writes a bash script that rebuilds positional arguments from
# AGENTQ_ARGUMENT_<i> environment variables and execs the server.  That script is
# plain bash and runs here.  It is the other half of the payload protocol: the
# decoder above proves the base64 arrives intact, this proves the arguments then
# reach the server as separate argv elements with spaces and quotes preserved.
runtime_script="$work/runtime.sh"
python3 - "$launcher" > "$runtime_script" <<'PY'
import io, re, sys
src = io.open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"\$runtimeScriptContent = @'\n(.*?)\n'@", src, re.S)
if not m:
    sys.exit("could not extract the runtime script")
sys.stdout.write(m.group(1))
PY

# A cygpath stub (identity) and a server stub that echoes its argv one per line.
stub_dir="$work/stubbin"
mkdir -p "$stub_dir"
cat > "$stub_dir/cygpath" <<'SH'
#!/bin/sh
for last; do :; done
printf '%s' "$last"
SH
cat > "$stub_dir/fakeserver" <<'SH'
#!/bin/sh
i=0
for a in "$@"; do
    printf 'argv[%s]=[%s]\n' "$i" "$a"
    i=$((i + 1))
done
SH
chmod 700 "$stub_dir/cygpath" "$stub_dir/fakeserver"

run_runtime() {
    # run_runtime <count> [args...] -- exports AGENTQ_ARGUMENT_<i> and runs the script.
    local count=$1
    shift
    local i=0
    local status=0
    (
        export PATH="$stub_dir:$PATH"
        export AGENTQ_SERVER_PATH="$stub_dir/fakeserver"
        export AGENTQ_ARGUMENT_COUNT="$count"
        for a in "$@"; do
            export "AGENTQ_ARGUMENT_$i=$a"
            i=$((i + 1))
        done
        sh "$runtime_script"
    ) >"$work/runtime.out" 2>"$work/runtime.err" || status=$?
    printf '%s' "$status"
}

# Arguments with a space, a double quote, and a newline must all survive as
# single argv elements -- this is exactly the class of corruption A21 was about.
cases=$((cases + 1))
rt_status=$(run_runtime 3 'status' '--workdir' '/tmp/a b"c')
if [ "$rt_status" -ne 0 ]; then
    printf 'launcher-contract runtime: exit %s\n' "$rt_status" >&2
    failures=$((failures + 1))
fi
for expected in 'argv[0]=[status]' 'argv[1]=[--workdir]' 'argv[2]=[/tmp/a b"c]'; do
    cases=$((cases + 1))
    if ! grep -qxF "$expected" "$work/runtime.out"; then
        printf 'launcher-contract runtime: missing %s\n' "$expected" >&2
        failures=$((failures + 1))
    fi
done
# And no extra argument must appear (a naive word-split would split argv[2]).
cases=$((cases + 1))
if grep -q '^argv\[3\]=' "$work/runtime.out"; then
    printf 'launcher-contract runtime: an argument was word-split (argv[3] exists)\n' >&2
    failures=$((failures + 1))
fi

# A non-numeric AGENTQ_ARGUMENT_COUNT must be refused with exit 2 -- the script
# runs `case "$count" in *[!0-9]*) exit 2`, which is the guard against an
# injected count.
cases=$((cases + 1))
inject_status=$(run_runtime '1;rm -rf /' 'status')
if [ "$inject_status" -ne 2 ]; then
    printf 'launcher-contract runtime: non-numeric count gave exit %s, expected 2\n' "$inject_status" >&2
    failures=$((failures + 1))
fi
# A missing count must also exit 2, not run with an empty argument vector.
cases=$((cases + 1))
missing_status=0
(export PATH="$stub_dir:$PATH"; export AGENTQ_SERVER_PATH="$stub_dir/fakeserver"; sh "$runtime_script") \
    >"$work/missing.out" 2>&1 || missing_status=$?
if [ "$missing_status" -ne 2 ]; then
    printf 'launcher-contract runtime: missing count gave exit %s, expected 2\n' "$missing_status" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'launcher-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'launcher-contract checks passed: cases=%s decoder=covered pathguards=covered roundtrip=covered windows-api=NOT-covered(needs-Windows)\n' "$cases"
