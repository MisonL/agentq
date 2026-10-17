#!/usr/bin/env bash
# Smoke: assets/windows-git-bash/agentq-launcher.ps1 -- the parts of it that run
# on this machine.
#
# Why this check exists: at 430 lines it is the LARGEST asset in the repo that no
# check has ever executed (docs/verification-status.md's "no check has ever executed it" table; 01
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
# The same reasoning, one round later, pulled in the StrictMode LASTEXITCODE
# guard across all five PowerShell assets that have one (see the guard section
# below); the two Windows clients were the copies the first sweep missed.
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
    printf '%s\n' 'launcher-contract NOT run: the python3 on PATH cannot execute (a Microsoft Store alias cannot run scripts).' >&2
    printf '%s\n' 'Install a real Python 3 and put it on PATH, then re-run.' >&2
    exit 1
fi
launcher=${AGENTQ_SMOKE_LAUNCHER:-$root/skill/assets/windows-git-bash/agentq-launcher.ps1}
# Overridable like the launcher, so the static LASTEXITCODE lock can be
# proven red by a mutated copy (the repo rule: a lock without a red proof is
# not a lock).
start_daemon=${AGENTQ_SMOKE_START_DAEMON:-$root/skill/assets/windows-git-bash/agentq-start-daemon.ps1}
installer=${AGENTQ_SMOKE_INSTALLER:-$root/skill/assets/windows-git-bash/install-agentq.ps1}
# The two Windows CLIENT assets carry the same guard (agentq.ps1 has TWO sites,
# sshp.ps1 has two: the shared Get-LastExitCodeOrFailure helper and a wrapper
# tail).  They were already fail-closed before this round, but unlocked -- the
# lock was written for the three server-side assets and the sweep stopped
# there.  A guard with no lock is exactly what the eighth round proved can be
# silently regressed.
ps_client=${AGENTQ_SMOKE_PS_CLIENT:-$root/skill/assets/client/windows/agentq.ps1}
sshp_client=${AGENTQ_SMOKE_SSHP_PS_CLIENT:-$root/skill/assets/client/windows/sshp.ps1}
[ -f "$launcher" ] || { printf '%s\n' 'launcher-contract: missing launcher asset' >&2; exit 1; }
[ -f "$start_daemon" ] || { printf '%s\n' 'launcher-contract: missing start-daemon asset' >&2; exit 1; }
[ -f "$installer" ] || { printf '%s\n' 'launcher-contract: missing installer asset' >&2; exit 1; }
[ -f "$ps_client" ] || { printf '%s\n' 'launcher-contract: missing Windows client asset' >&2; exit 1; }
[ -f "$sshp_client" ] || { printf '%s\n' 'launcher-contract: missing Windows sshp asset' >&2; exit 1; }

pwsh_binary=${AGENTQ_SMOKE_PWSH:-$(command -v pwsh || true)}
if [ -z "$pwsh_binary" ]; then
    printf '%s\n' 'SKIPPED: pwsh is not available; the launcher was not executed'
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
    printf '%s\n' 'Launcher contract NOT run: the pwsh on PATH cannot execute (startup cache).' >&2
    printf '%s\n' 'Try: mv ~/.cache/powershell/StartupProfileData-NonInteractive{,.broken}' >&2
    exit 1
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
# Written WITH a UTF-8 BOM, and that is load-bearing on Windows PowerShell 5.1:
# a BOM-less .ps1 is read as the ANSI codepage (CP1252 on the CI runner), so the
# non-ASCII literals below (decoded.unicode0/1) were re-decoded byte-wise at
# PARSE time and reached the decoder as mojibake -- `任务` -> `ä»»åŠ¡` -- which
# is exactly what the first real CI run reported (run 37810470283, windows job).
# pwsh 7 assumes UTF-8 and hid this; the BOM is the signal 5.1 honours.
# The EMIT side ALSO needs a pin: the earlier note here said "none was measured
# broken", and that was true only on the English CI image.  Measured 2026-10-20
# on a zh-CN Windows 10 (PS 5.1.19041): stdout defaults to the console code page
# (GBK), so `任务` reached the shell as `????` and both unicode assertions failed
# while the decoder was correct.  Pinning [Console]::OutputEncoding to UTF-8 is
# the emitting half of the same rule the BOM applies to the parsing half.
printf '\xEF\xBB\xBF' > "$driver"
cat >> "$driver" <<'PS1'
param([string]$LauncherPath, [string]$StartDaemonPath, [string]$WorkDirectory)
$ErrorActionPreference = "Stop"
# Emit UTF-8 regardless of the host's console code page (measured 2026-10-20 on
# a zh-CN Windows: GBK stdout turned the non-ASCII round-trip fixture into ????).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# Mirror the asset's own strictness.  The launcher sets Set-StrictMode -Version
# Latest at its top; a driver that omits it expands an unset $script: variable
# to the empty string instead of throwing, so a cleanup branch that references
# an undefined name (the 2026-10-13 $script:Program defect) printed its message
# and returned as if healthy -- the driver tested a weakened environment and
# stayed green while the real asset threw.  Same class as the "the stub must
# copy the real tool" rule this suite records elsewhere.
Set-StrictMode -Version Latest

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

# The extracted functions read $script:Program in their diagnostics.  The asset
# defines it at its top; the extraction above lifts only the function bodies, so
# the driver must reproduce that top-level assignment -- and it must take it FROM
# the asset, not invent one, or the driver would stay green even if the asset
# dropped the assignment (the 2026-10-13 defect: without it, StrictMode throws in
# every cleanup-failure branch).  Extract the assignment; a missing one is a
# loud failure here.
$programAssignment = [regex]::Match($src, '(?m)^\s*\$script:Program\s*=.*$')
if (-not $programAssignment.Success) {
    throw "launcher: the asset no longer assigns `$script:Program, which its cleanup diagnostics read under StrictMode"
}
Invoke-Expression $programAssignment.Value

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
#
# Run it with BASH, not `sh`.  The script's shebang is `#!/usr/bin/env bash` and
# the launcher executes it via git-bash; it uses `set -o pipefail` and `${!name-}`,
# which dash rejects with exit 2.  `sh` is bash on macOS but dash on Debian/Ubuntu,
# so invoking it as `sh` was a macOS-only false green.
runtime_bash=${AGENTQ_SMOKE_BASH:-bash}
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
        "$runtime_bash" "$runtime_script"
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
(export PATH="$stub_dir:$PATH"; export AGENTQ_SERVER_PATH="$stub_dir/fakeserver"; "$runtime_bash" "$runtime_script") \
    >"$work/missing.out" 2>&1 || missing_status=$?
if [ "$missing_status" -ne 2 ]; then
    printf 'launcher-contract runtime: missing count gave exit %s, expected 2\n' "$missing_status" >&2
    failures=$((failures + 1))
fi

# --- start-daemon's failure CONTRACT must actually reach `exit 2` -------------
# The three refusal sites in agentq-start-daemon.ps1 were `Write-Error` +
# `exit 2` -- but the script sets $ErrorActionPreference = "Stop", so Write-Error
# THROWS and the process exits with PowerShell's terminating-error code instead;
# the `exit 2` was dead code and the documented parameter-error contract never
# held (measured on a minimal script 2026-10-07: EAP=Stop + Write-Error exits 1
# and never reaches the next statement).  The fix writes to stderr with
# [Console]::Error and then `exit 2`.  This drives the REAL function in a real
# child pwsh -- the only way to observe the process exit code, because dot-sourcing
# runs the exit in the driver's session (a trap smoke/12 already documented).
sd_driver="$work/sd-contract.ps1"
# BOM for the same reason as driver.ps1 above: this file is executed by whatever
# PowerShell the run selected, and on Windows PowerShell 5.1 a BOM-less .ps1 is
# read as ANSI.  No literal here is non-ASCII today, so the BOM is prophylactic
# -- it keeps the rule "a generated .ps1 that 5.1 will parse is written UTF-8"
# true without anyone having to remember it when the first accent is added.
printf '\xEF\xBB\xBF' > "$sd_driver"
cat >> "$sd_driver" <<'PS1'
param([string]$StartDaemonPath, [string]$WorkDirectory)
$ErrorActionPreference = "Stop"
function Get-Fn([string]$src, [string]$name) {
    $pattern = '(?s)function ' + [regex]::Escape($name) + ' \{.*?\n\}\n'
    $m = [regex]::Match($src, $pattern)
    if (-not $m.Success) { throw "could not extract function $name" }
    return $m.Value
}
$sdSrc = Get-Content -Raw $StartDaemonPath
$script:StartDaemonProgram = "agentq-start-daemon.ps1"
foreach ($n in @('Test-NonReparseWindowsRequiredFilePath', 'Assert-AgentQRequiredFile')) {
    Invoke-Expression (Get-Fn $sdSrc $n)
}
if ($args.Count -eq 1 -and $args[0] -eq "missing") {
    # The refusal itself: a path that does not exist must exit 2 from THIS
    # process with the documented message on stderr -- not throw out of
    # Write-Error under EAP=Stop.
    Assert-AgentQRequiredFile -Path (Join-Path $WorkDirectory "no-such-file") -Description "Required AgentQ path"
    exit 0
}
$existing = Join-Path $WorkDirectory "sd-existing.bin"
Set-Content -Path $existing -Value 'x' -NoNewline
Assert-AgentQRequiredFile -Path $existing -Description "Required AgentQ path"
exit 0
PS1
cases=$((cases + 1))
sd_status=0
"$pwsh_binary" -NoProfile -NonInteractive -File "$sd_driver" -StartDaemonPath "$start_daemon" -WorkDirectory "$work/pw" missing \
    >"$work/sd.out" 2>"$work/sd.err" || sd_status=$?
if [ "$sd_status" -ne 2 ]; then
    printf 'launcher-contract: start-daemon contract: a missing required path must exit 2, got %s (Write-Error under EAP=Stop exits 1 -- the contract was dead code)\n' "$sd_status" >&2
    sed 's/^/    stderr: /' "$work/sd.err" | head -3 >&2 || true
    failures=$((failures + 1))
fi
if ! grep -qF 'Required AgentQ path is missing' "$work/sd.err"; then
    printf '%s\n' 'launcher-contract: start-daemon contract: stderr does not carry the refusal message' >&2
    failures=$((failures + 1))
fi
# The other direction: a good path must still pass (a function that always
# exits 2 would satisfy both assertions above).
cases=$((cases + 1))
sd_ok_status=0
"$pwsh_binary" -NoProfile -NonInteractive -File "$sd_driver" -StartDaemonPath "$start_daemon" -WorkDirectory "$work/pw" \
    >"$work/sd.ok.out" 2>"$work/sd.ok.err" || sd_ok_status=$?
if [ "$sd_ok_status" -ne 0 ]; then
    printf 'launcher-contract: start-daemon contract: a valid required path must exit 0, got %s\n' "$sd_ok_status" >&2
    sed 's/^/    stderr: /' "$work/sd.ok.err" | head -3 >&2 || true
    failures=$((failures + 1))
fi

# --- LASTEXITCODE guards: start-daemon, the launcher, the installer, the two
# --- Windows clients ----------------------------------------------------------
# A CreateProcess failure (AV or a policy blocking the binary) is a
# NON-terminating error that never sets $LASTEXITCODE.  All five assets set
# Set-StrictMode -Version Latest, where a bare read THROWS "The variable
# '$LASTEXITCODE' cannot be retrieved" -- measured 2026-10-17 in pwsh 7.5: the
# direct read throws, Get-Variable returns null.  start-daemon then exited 1
# with a PowerShell error (the defect fixed this round); the launcher's trap
# kept the contract's 2 but reported the wrong cause; the installer's 18 sites
# would each exit 1 the same way.  The two Windows CLIENT assets already had
# fail-closed guards (a shared Get-LastExitCodeOrFailure helper plus a wrapper
# tail each) but no lock -- the sweep initially stopped at the three
# server-side assets, so those two are locked here too.  STATIC locks, because
# the top level of each file is unreachable on this host (WindowsIdentity / a
# real Git Bash / a real ssh).
#
# The rule has TWO halves, and the second is the one that matters: the guard
# EXISTING is not the fix -- the fail-closed BRANCH is.  Measured: deleting
# only the `if ($null -eq ...)` block (keeping the Get-Variable assignment and
# the .Value read) left a guard-presence-only lock green, while the real
# behaviour under StrictMode is the original exit-1 throw.  And EVERY
# Get-Variable site is checked, not just the last: the client assets have two
# sites each, and a version that tracked only the last assignment would stay
# green when the FIRST site's null branch was deleted (measured: client-m1).
# PowerShell identifiers are CASE-INSENSITIVE and `${VAR}` is the same variable
# as `$VAR` -- measured 2026-10-18 in pwsh 7.5: `${LASTEXITCODE}` and
# `$LastExitCode` both return the value a native child set, and
# `Get-Variable -Name LastExitCode` resolves the same variable.  A case-sensitive
# scan therefore misses two real forms of the very defect this lock exists for:
# measured mutants M7 (`$LastExitCode` bare read) and M8 (`${LASTEXITCODE}` bare
# read) both stayed green at 74 cases.  The scanner lowercases the line first and
# also matches the brace form.
bare_last_exitcode_lines() {
    awk '
        { line = $0; sub(/^[ \t]+/, "", line); if (substr(line, 1, 1) == "#") next }
        {
            lowered = tolower(line)
            # `${...}` form, and the plain form guarded against `$NAME` prefixes.
            if (lowered ~ /[$][{]lastexitcode[}]/) { print NR; next }
            if (lowered ~ /(^|[^[:alnum:]_.])[$]lastexitcode([^[:alnum:]_]|$)/) { print NR }
        }
    ' "$1"
}

assert_last_exitcode_guard() {
    # $1 = file, $2 = label, $3 = fail-closed token(s), `|`-separated
    # (`exit 2` / `return 1`; the client files reach different tokens at their
    # two sites -- `return 1` in the helper, `exit 1` in the wrapper tail).
    # EVERY assignment site is checked: an earlier version tracked only the
    # LAST one, so a file with two sites passed when either single site was
    # intact -- the same "at least one vs every" pathology this repo keeps
    # finding in assertions.
    #
    # The token must be INSIDE the `if ($null -eq $var) { ... }` block, not
    # merely near it.  Measured: a mutant whose null branch does nothing while
    # an `exit 2` sits a few lines later passed a proximity rule -- and when
    # $LASTEXITCODE is unset that shape falls through to the .Value read and
    # throws, which is the defect this lock exists to prevent.  Brace depth is
    # tracked from the null-test line; the token only counts at depth > 0.
    # A `.Value` read INSIDE the null branch is always a defect (the variable
    # is null there, so it throws), as is one BEFORE the null test.
    local guard_file=$1 guard_label=$2 guard_token=$3
    cases=$((cases + 1))
    local guard_bare
    guard_bare=$(bare_last_exitcode_lines "$guard_file")
    if [ -n "$guard_bare" ]; then
        printf 'launcher-contract: %s reads $LASTEXITCODE directly at line(s) %s; under StrictMode an unset variable throws and a process that never started exits 1 instead of a controlled failure\n' "$guard_label" "$guard_bare" >&2
        failures=$((failures + 1))
    fi
    cases=$((cases + 1))
    if ! awk -v tokens="$guard_token" '
        BEGIN { token_count = split(tokens, token_list, "|") }
        # Character-wise brace tracking.  A line-level net delta is not enough:
        # `} else {` nets to zero, so a token in the ELSE branch would count as
        # inside the null branch -- a still-wrong program satisfying the rule
        # (measured: mutant M5 passed a delta-based rule).  scan() fills two
        # globals: `any` = text at depth >= 1 (a .Value read there is a defect:
        # the variable is null), `top` = text at depth 1 (only there does a
        # fail-closed token count; a token nested deeper is conditional and may
        # not run -- mutant M6).  Known boundary: a string literal with an
        # UNBALANCED brace would skew the count; the real assets use balanced
        # format strings (`{0}`/`{1}`), and an unbalanced one inside a null
        # branch would only cause a false RED, never a false green.
        #
        # Everything below matches on the LOWERCASED line: PowerShell
        # identifiers, `Get-Variable`/`-Name`, `$null`, `.Value` and the
        # `exit`/`return` keywords are all case-insensitive, so a case-sensitive
        # scan would accept `$LastExitCode`, `Get-Variable -name lastexitcode`,
        # `.value` etc. as "not the thing we are looking for".
        function scan(s,   i, n, c) {
            any = ""; top = ""
            n = length(s)
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (c == "{") { depth++; continue }
                if (c == "}") { depth--; if (depth <= 0) { depth = 0; return }; continue }
                if (depth >= 1) any = any c
                if (depth == 1) top = top c
            }
        }
        { line = $0; sub(/^[ \t]+/, "", line); line = tolower(line) }
        substr(line, 1, 1) == "#" { next }
        match(line, /^[$][A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*get-variable[ \t]+-name[ \t]+lastexitcode/) {
            if (probe_var != "" && !(null_seen && closed)) bad_site = assign_line
            probe_var = line
            sub(/^[$]/, "", probe_var)
            sub(/[[:space:]]*=.*$/, "", probe_var)
            assign_line = NR
            null_seen = 0; closed = 0; depth = 0; sites++
            next
        }
        probe_var == "" { next }
        !null_seen && index(line, "$" probe_var ".value") > 0 { bad_site = NR }
        !null_seen && index(line, "$null -eq $" probe_var) > 0 {
            null_seen = 1
            depth = 0
            scan(line)
            for (i = 1; i <= token_count; i++) { if (index(top, tolower(token_list[i])) > 0) closed = 1 }
            next
        }
        null_seen && depth > 0 {
            scan(line)
            if (index(any, "$" probe_var ".value") > 0) bad_site = NR
            for (i = 1; i <= token_count; i++) { if (index(top, tolower(token_list[i])) > 0) closed = 1 }
            next
        }
        END {
            if (probe_var != "" && !(null_seen && closed)) bad_site = assign_line
            exit (sites > 0 && bad_site == 0) ? 0 : 1
        }
    ' "$guard_file"; then
        printf 'launcher-contract: %s does not fail closed on an unset LASTEXITCODE at every Get-Variable site (the `%s` must be directly INSIDE the null branch, with no .Value read before it or inside it) -- under StrictMode the .Value read throws\n' "$guard_label" "$guard_token" >&2
        failures=$((failures + 1))
    fi
}

# A guard variable named like the automatic variable is the same variable.
# PowerShell identifiers are case-insensitive, so `$lastExitCode = Get-Variable
# -Name LASTEXITCODE ...` assigns THROUGH to $LASTEXITCODE itself.  Inside a
# function that only shadows the global; at SCRIPT scope it replaces the
# integer with a PSVariable object and the next `.Value` read throws "Cannot
# convert System.Management.Automation.PSVariable to System.Int32" (measured
# 2026-10-18 in pwsh 7.5).  Two real sites had this shape (the launcher's
# top-level try, sshp's generated installer script) and BOTH were introduced by
# this same self-review series -- a rename that looks cosmetic and is not.
# The rule is deliberately scope-blind: one name that is correct in both
# scopes is simpler to keep correct than "this name is fine here, not there".
assert_last_exitcode_alias() {
    # $1 = file, $2 = label
    local alias_file=$1 alias_label=$2
    cases=$((cases + 1))
    local alias_sites
    alias_sites=$(awk '
        { line = $0; sub(/^[ \t]+/, "", line); if (substr(line, 1, 1) == "#") next }
        {
            lowered = tolower(line)
            if (match(lowered, /^[$][a-z_][a-z0-9_]*[ \t]*=[ \t]*get-variable[ \t]+-name[ \t]+lastexitcode/)) {
                name = lowered
                sub(/^[$]/, "", name)
                sub(/[ \t]*=.*$/, "", name)
                if (name == "lastexitcode") print NR
            }
        }
    ' "$alias_file")
    if [ -n "$alias_sites" ]; then
        printf 'launcher-contract: %s assigns the LASTEXITCODE guard to a variable whose name IS the automatic variable (line(s) %s); at script scope that replaces the integer with a PSVariable and the .Value read throws\n' "$alias_label" "$alias_sites" >&2
        failures=$((failures + 1))
    fi
}

assert_last_exitcode_alias "$start_daemon" 'start-daemon probe'
assert_last_exitcode_alias "$launcher" 'launcher Git Bash spawn'
assert_last_exitcode_alias "$installer" 'installer native calls'
assert_last_exitcode_alias "$ps_client" 'Windows client'
assert_last_exitcode_alias "$sshp_client" 'Windows sshp'

assert_last_exitcode_guard "$start_daemon" 'start-daemon probe' 'exit 2'
assert_last_exitcode_guard "$launcher" 'launcher Git Bash spawn' 'exit 2'
assert_last_exitcode_guard "$installer" 'installer native calls' 'return 1'
assert_last_exitcode_guard "$ps_client" 'Windows client' 'return 1|exit 1'
assert_last_exitcode_guard "$sshp_client" 'Windows sshp' 'return 1|exit 1'

# Behavioural half for the installer's helper: it is a pure function, so it can
# be extracted from the REAL asset and driven in a real child pwsh.  The static
# rule above proves the shape; this proves the answer -- unset must fail closed
# (1), a real 0 must stay 0, and a real non-zero must pass through unchanged
# (a helper that always returned 1 would satisfy the fail-closed direction and
# silently turn every successful pueue call into an installer failure).
lec_driver="$work/lec-driver.ps1"
# The child shell is resolved HERE, not inside the driver: this check also runs
# in the windows job with real PowerShell 5.1 (AGENTQ_SMOKE_PWSH=powershell.exe),
# and a literal `/bin/sh` in the driver would resolve to `\bin\sh` there and
# throw CommandNotFoundException -- the same "hand a POSIX path to a native
# interpreter" mistake this file's own header warns about.  `command -v sh` in
# Git Bash gives an MSYS path, which MSYS converts when it crosses into the
# native process (the same mechanism every other -File invocation here relies on).
lec_shell=$(command -v sh || true)
[ -n "$lec_shell" ] || { printf '%s\n' 'launcher-contract: no sh on PATH for the exit-code driver' >&2; exit 1; }
printf '\xEF\xBB\xBF' > "$lec_driver"
cat >> "$lec_driver" <<'PS1'
param([string]$InstallerPath, [string]$ShellPath)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
function Get-Fn([string]$src, [string]$name) {
    $pattern = '(?s)function ' + [regex]::Escape($name) + ' \{.*?\n\}\n'
    $m = [regex]::Match($src, $pattern)
    if (-not $m.Success) { throw "could not extract function $name" }
    return $m.Value
}
$src = Get-Content -Raw $InstallerPath
Invoke-Expression (Get-Fn $src 'Get-NativeExitCode')
"unset=$(Get-NativeExitCode)"
# A POSIX shell rather than COMSPEC: any native child sets $LASTEXITCODE
# identically, and Git Bash provides sh in the windows job.
& $ShellPath -c "exit 0"
"zero=$(Get-NativeExitCode)"
& $ShellPath -c "exit 7"
"seven=$(Get-NativeExitCode)"
PS1
cases=$((cases + 1))
lec_status=0
"$pwsh_binary" -NoProfile -NonInteractive -File "$lec_driver" -InstallerPath "$installer" -ShellPath "$lec_shell" \
    >"$work/lec.out" 2>"$work/lec.err" || lec_status=$?
lec_unset=$(sed -n 's/^unset=//p' "$work/lec.out")
lec_zero=$(sed -n 's/^zero=//p' "$work/lec.out")
lec_seven=$(sed -n 's/^seven=//p' "$work/lec.out")
if [ "$lec_status" -ne 0 ] || [ "$lec_unset" != "1" ] || [ "$lec_zero" != "0" ] || [ "$lec_seven" != "7" ]; then
    printf 'launcher-contract: installer exit-code helper: unset=%s (want 1) zero=%s (want 0) seven=%s (want 7)\n' \
        "${lec_unset:-?}" "${lec_zero:-?}" "${lec_seven:-?}" >&2
    sed 's/^/    stderr: /' "$work/lec.err" | head -3 >&2 || true
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'launcher-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
# Static lock: the argument-payload parse must be wrapped so a malformed payload
# exits 2 (the contract's argument-error code), not 1.  Read-AgentQArguments
# throws on empty / non-NUL-separated / over-limit / malformed payloads; with no
# catch and $ErrorActionPreference="Stop" an uncaught throw exits a -File script
# with 1 (measured 2026-10-12).  The client-side wrapper rejects oversize
# payloads with the same ceiling before invoking the launcher, so this is
# defense in depth, not a reachable path today -- but the code it reports must
# still be the contract's 2.
cases=$((cases + 1))
if ! grep -q 'Read-AgentQArguments -Encoded \$encodedArguments' "$launcher"; then
    printf '%s\n' 'launcher-contract: the launcher no longer calls Read-AgentQArguments (the static lock below would be vacuous)' >&2
    failures=$((failures + 1))
elif ! awk '
    # Anchored END-state machine (2026-10-13: the previous rolling-window rule
    # was mutation-verified vacuous -- "caught" was satisfied by ANY catch in
    # the file, including an unrelated function and a comment, and the rule
    # passed implicitly when no window matched).  Require a verbatim window:
    # `try {` immediately followed by the call, then `} catch {`, then exit 2
    # within three lines.
    { lines[NR] = $0 }
    END {
        found = 0
        for (i = 2; i <= NR - 1; i++) {
            if (lines[i] == "try {" && lines[i + 1] ~ /Read-AgentQArguments -Encoded \$encodedArguments/) {
                found = 1
                if (lines[i + 2] !~ /^\} catch \{/) exit 1
                ok = 0
                for (j = i + 3; j <= i + 5 && j <= NR; j++) {
                    if (lines[j] ~ /exit 2/) ok = 1
                }
                if (!ok) exit 1
            }
        }
        exit found ? 0 : 1
    }
' "$launcher"; then
    printf '%s\n' 'launcher-contract: the argument parse is not wrapped in try/catch, so a malformed payload exits 1 instead of the contract 2' >&2
    failures=$((failures + 1))
fi

cases=$((cases + 1))
# The per-argument environment write must be wrapped in try/catch: a single
# argument past ~32.5K characters overflows the per-process environment block
# (CreateProcess 32767, measured 2026-10-14 on the Windows test host) and
# SetEnvironmentVariable throws ArgumentException.  Without the catch the throw
# was uncaught -- the wrapper died with exit 1 and a CLIXML stack trace, no
# contract error.  Same structural rule as the parse lock above: `try {`
# immediately before the SetEnvironmentVariable loop, `} catch {` right after,
# an `exit 2` within five lines of the catch, and the emitted reason class.
if ! awk '
    { lines[NR] = $0 }
    END {
        found = 0
        for (i = 2; i <= NR - 8 && i <= NR; i++) {
            if (lines[i] == "    try {" && lines[i + 1] ~ /for \(\$index = 0; \$index -lt \$arguments\.Count/) {
                found = 1
                # The loop body (SetEnvironmentVariable on the argument variable)
                # must be inside, the catch within the next few lines, and the
                # contract code + reason class must both follow the catch.
                body = 0
                catch_line = -1
                for (j = i + 1; j <= i + 6 && j <= NR; j++) {
                    if (lines[j] ~ /SetEnvironmentVariable\(\$argumentEnvironmentVariable/) body = 1
                    if (lines[j] ~ /^[[:space:]]*\} catch \{/) { catch_line = j; break }
                }
                if (!body || catch_line < 0) exit 1
                ok = 0
                reason = 0
                for (j = catch_line; j <= catch_line + 5 && j <= NR; j++) {
                    if (lines[j] ~ /exit 2/) ok = 1
                    if (lines[j] ~ /reason=protocol_error/) reason = 1
                }
                if (!ok || !reason) exit 1
            }
        }
        exit found ? 0 : 1
    }
' "$launcher"; then
    printf '%s\n' 'launcher-contract: the argument environment write is not wrapped in try/catch with reason=protocol_error, so an environment-block overflow exits 1 instead of the contract 2' >&2
    failures=$((failures + 1))
fi

cases=$((cases + 1))
# The top-level trap: every throw OUTSIDE the two guarded sites (the parse
# catch and the env-overflow catch) — the top-level required-file asserts, the
# five profile-resolution throws, runtime-path exhaustion, WriteAllText / the
# git-bash spawn — reaches the top of a -File script and, with no trap, exits 1
# with a CLIXML stack; the client wrapper's `agentq-exit` token never runs, so
# the operator gets an unclassified 1 instead of the contract's 2.  Measured
# 2026-10-17 on the real asset with the server file absent (exit 1, no token)
# and after the fix (exit 2 + reason + token).  The lock asserts the trap's
# whole contract shape: message, reason class, exit token, exit 2.  The two
# guarded sites are NOT intercepted by the trap (`exit` is not an exception —
# measured: the inner parse catch still emits only its own message), so this
# lock and the two site locks above pin three disjoint paths.
if ! awk '
    { lines[NR] = $0 }
    END {
        found = 0
        for (i = 1; i <= NR - 5; i++) {
            if (lines[i] == "trap {") {
                found = 1
                ok = 0
                reason = 0
                token = 0
                for (j = i + 1; j <= i + 6 && j <= NR; j++) {
                    if (lines[j] ~ /agentq: \$\(\$_\.Exception\.Message\)/) ok = 1
                    if (lines[j] ~ /reason=protocol_error/) reason = 1
                    if (lines[j] ~ /agentq-exit:2/) token = 1
                }
                if (!ok || !reason || !token) exit 1
            }
        }
        exit found ? 0 : 1
    }
' "$launcher"; then
    printf '%s\n' 'launcher-contract: the top-level trap is missing or does not emit message + reason=protocol_error + agentq-exit:2, so an uncaught throw exits 1 with no token instead of the contract 2' >&2
    failures=$((failures + 1))
fi

cases=$((cases + 1))
# Behavioural half: the real launcher, executed as a subprocess in a directory
# that lacks the server file, must exit 2 with the reason line and the exit
# token on stderr -- the exact shape the wrapper's `agentq-exit` reader (and
# the POSIX client's tail -n 1 reader) consumes.  The static lock above pins
# the shape; this pins that the shape is REACHED, which is what the mutation
# "trap renamed to trapx" fails at runtime as well as statically.
trap_dir="$work/trap-behaviour"
mkdir -p "$trap_dir"
cp "$launcher" "$trap_dir/agentq-launcher.ps1"
trap_status=0
(cd "$trap_dir" && "$pwsh_binary" -NoProfile -NonInteractive -File ./agentq-launcher.ps1 -ArgumentsBase64 "c3RhdHVzAA==") >/dev/null 2>"$work/trap-behaviour.err" || trap_status=$?
if [ "$trap_status" -ne 2 ] || ! grep -qF 'reason=protocol_error' "$work/trap-behaviour.err" || ! grep -qF 'agentq-exit:2' "$work/trap-behaviour.err"; then
    printf 'launcher-contract: the top-level trap did not produce exit 2 + reason + token for a missing server file (got exit %s)\n' "$trap_status" >&2
    head -3 "$work/trap-behaviour.err" >&2 || true
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf 'launcher-contract: %s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'launcher-contract checks passed: cases=%s pwsh=%s decoder=covered pathguards=covered roundtrip=covered lastexitcode-guards=5/5 windows-api=NOT-covered(needs-Windows) malformed-payload=exit2\n' "$cases" \
    "$("$pwsh_binary" -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || printf 'unknown')"
