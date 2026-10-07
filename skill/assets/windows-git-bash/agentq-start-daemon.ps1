Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$env:MSYS_NO_PATHCONV = "1"

$script:StartDaemonProgram = "agentq-start-daemon.ps1"
$rootDirectory = $PSScriptRoot
$configPath = Join-Path $rootDirectory "config\pueue.yml"
$clientPath = Join-Path $rootDirectory "pueue.exe"
$daemonPath = Join-Path $rootDirectory "pueued.exe"
$dataDirectory = Join-Path $rootDirectory "data"
$runtimeDirectory = Join-Path $rootDirectory "runtime"
$taskLogDirectory = Join-Path $dataDirectory "task_logs"
$cancellationDirectory = Join-Path $dataDirectory "agentq-cancellations"
$requestDirectory = Join-Path $dataDirectory "agentq-requests"
$requestLockDirectory = Join-Path $requestDirectory ".locks"
$requestTombstoneDirectory = Join-Path $requestDirectory ".tombstones"

function Test-NonReparseWindowsProfilePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    } catch {
        return $false
    }
    if (!$item.PSIsContainer -or (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        return $false
    }

    $parent = [System.IO.Directory]::GetParent($fullPath)
    while ($null -ne $parent) {
        $parentItem = Get-Item -LiteralPath $parent.FullName -Force -ErrorAction SilentlyContinue
        if ($null -eq $parentItem -or !$parentItem.PSIsContainer -or
            (($parentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return $false
        }
        $parent = $parent.Parent
    }
    return $true
}

function Get-CurrentWindowsUserEnvironment {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if (($null -eq $identity) -or ($null -eq $identity.User)) {
        throw "Windows user SID is unavailable"
    }

    $accountName = $identity.Name
    $profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($identity.User.Value)"
    $profile = (Get-ItemProperty -LiteralPath $profileKey -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
    $profile = [Environment]::ExpandEnvironmentVariables([string]$profile)
    $profileItem = if ([string]::IsNullOrWhiteSpace($profile)) {
        $null
    } else {
        Get-Item -LiteralPath $profile -Force -ErrorAction SilentlyContinue
    }
    if ([string]::IsNullOrWhiteSpace($profile) -or ($null -eq $profileItem) -or !$profileItem.PSIsContainer) {
        throw "Windows user profile is unavailable for $($identity.Name)"
    }
    if (!(Test-NonReparseWindowsProfilePath -Path $profile)) {
        throw "Windows user profile path is not a regular non-reparse directory: $profile"
    }
    $acl = Get-Acl -LiteralPath $profile -ErrorAction Stop
    $hasUserAccess = @($acl.Access | Where-Object {
        $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
        (($_.IdentityReference.Value -eq $accountName) -or ($_.IdentityReference.Value -eq $identity.User.Value)) -and
        (($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Modify) -ne 0)
    }).Count -gt 0
    if (!$hasUserAccess) {
        throw "Windows user profile is not writable by $accountName"
    }
    $profile = [System.IO.Path]::GetFullPath($profile)
    $localAppData = Join-Path $profile "AppData\Local"
    $systemRoot = [Environment]::GetEnvironmentVariable("SystemRoot", [EnvironmentVariableTarget]::Machine)
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = [Environment]::GetEnvironmentVariable("windir", [EnvironmentVariableTarget]::Machine)
    }
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = "C:\Windows"
    }
    $systemRoot = [System.IO.Path]::GetFullPath($systemRoot)
    $systemDrive = [System.IO.Path]::GetPathRoot($systemRoot).TrimEnd("\\")
    if ([string]::IsNullOrWhiteSpace($systemDrive)) {
        $systemDrive = [System.IO.Path]::GetPathRoot($profile).TrimEnd("\\")
    }
    $homeDrive = [System.IO.Path]::GetPathRoot($profile).TrimEnd("\\")
    $homePath = $profile.Substring($homeDrive.Length)
    $userPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
    $machinePath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
    $pathParts = @(
        [Environment]::ExpandEnvironmentVariables([string]$userPath)
        [Environment]::ExpandEnvironmentVariables([string]$machinePath)
    ) | Where-Object { ![string]::IsNullOrWhiteSpace($_) }
    $windowsPath = [string]::Join(";", [string[]]$pathParts)
    if ([string]::IsNullOrWhiteSpace($windowsPath)) {
        throw "Windows user and machine PATH are unavailable"
    }
    $pathExt = [Environment]::GetEnvironmentVariable("PATHEXT", [EnvironmentVariableTarget]::User)
    if ([string]::IsNullOrWhiteSpace($pathExt)) {
        $pathExt = [Environment]::GetEnvironmentVariable("PATHEXT", [EnvironmentVariableTarget]::Machine)
    }
    if ([string]::IsNullOrWhiteSpace($pathExt)) {
        $pathExt = ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC"
    }
    $comSpec = [Environment]::GetEnvironmentVariable("ComSpec", [EnvironmentVariableTarget]::User)
    if ([string]::IsNullOrWhiteSpace($comSpec)) {
        $comSpec = [Environment]::GetEnvironmentVariable("ComSpec", [EnvironmentVariableTarget]::Machine)
    }
    if ([string]::IsNullOrWhiteSpace($comSpec)) {
        $comSpec = Join-Path $systemRoot "System32\cmd.exe"
    }

    return [pscustomobject]@{
        Identity = $identity.Name
        UserName = ($identity.Name -split "\\")[-1]
        Profile = $profile
        AppData = Join-Path $profile "AppData\Roaming"
        LocalAppData = $localAppData
        Temp = Join-Path $localAppData "Temp"
        SystemRoot = $systemRoot
        SystemDrive = $systemDrive
        HomeDrive = $homeDrive
        HomePath = $homePath
        Path = $windowsPath
        PathExt = $pathExt
        ComSpec = $comSpec
        WindowsDirectory = $systemRoot
    }
}

function Set-AgentQUserEnvironment {
    param([psobject]$UserEnvironment)

    $profile = $UserEnvironment.Profile
    $environmentValues = [ordered]@{
        HOME = $profile
        USER = $UserEnvironment.UserName
        USERNAME = $UserEnvironment.UserName
        USERPROFILE = $profile
        APPDATA = $UserEnvironment.AppData
        LOCALAPPDATA = $UserEnvironment.LocalAppData
        HOMEDRIVE = $UserEnvironment.HomeDrive
        HOMEPATH = $UserEnvironment.HomePath
        TEMP = $UserEnvironment.Temp
        TMP = $UserEnvironment.Temp
        Path = $UserEnvironment.Path
        PATHEXT = $UserEnvironment.PathExt
        ComSpec = $UserEnvironment.ComSpec
        SystemDrive = $UserEnvironment.SystemDrive
        WINDIR = $UserEnvironment.WindowsDirectory
        SystemRoot = $UserEnvironment.SystemRoot
    }
    foreach ($entry in $environmentValues.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }
}

function Test-NonReparseWindowsRequiredFilePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    } catch {
        return $false
    }
    if ($item.PSIsContainer -or (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        return $false
    }

    $parent = [System.IO.Directory]::GetParent($fullPath)
    while ($null -ne $parent) {
        $parentItem = Get-Item -LiteralPath $parent.FullName -Force -ErrorAction SilentlyContinue
        if ($null -eq $parentItem -or !$parentItem.PSIsContainer -or
            (($parentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return $false
        }
        $parent = $parent.Parent
    }
    return $true
}

function Assert-AgentQRequiredFile {
    param([string]$Path, [string]$Description)

    $requiredPath = $Path
    $item = if ([string]::IsNullOrWhiteSpace($Path)) {
        $null
    } else {
        Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $item) {
        # stderr, not Write-Error: under $ErrorActionPreference = "Stop" (set at
        # the top of this script) Write-Error THROWS, so the process exits with
        # PowerShell's terminating-error code and the `exit 2` below was dead
        # code -- the documented parameter-error contract never held.  The only
        # caller treats any non-zero the same, so this changes nothing for it
        # and makes the stated contract true (measured 2026-10-07: a script with
        # EAP=Stop + Write-Error exits 1 and never reaches the next line).
        [Console]::Error.WriteLine("{0}: Required AgentQ path is missing: {1}", $script:StartDaemonProgram, $requiredPath)
        exit 2
    }
    if (!(Test-NonReparseWindowsRequiredFilePath -Path $Path)) {
        [Console]::Error.WriteLine("{0}: {1} is not a regular non-reparse file: {2}", $script:StartDaemonProgram, $Description, $Path)
        exit 2
    }
}

$currentUserEnvironment = Get-CurrentWindowsUserEnvironment
Set-AgentQUserEnvironment -UserEnvironment $currentUserEnvironment

foreach ($directory in @(
    $dataDirectory,
    $runtimeDirectory,
    $taskLogDirectory,
    $cancellationDirectory,
    $requestDirectory,
    $requestLockDirectory,
    $requestTombstoneDirectory
)) {
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
}

foreach ($requiredPath in @($configPath, $clientPath, $daemonPath)) {
    Assert-AgentQRequiredFile -Path $requiredPath -Description "Required AgentQ path"
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& $clientPath --config $configPath status --json *> $null
$ErrorActionPreference = $previousErrorActionPreference
if ($LASTEXITCODE -eq 0) {
    exit 0
}

function Test-ManagedDaemonProcess {
    param([string]$Path)

    $target = [System.IO.Path]::GetFullPath($Path)
    foreach ($process in @(Get-Process -Name pueued -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path -ieq $target) {
                return $true
            }
        } catch {
        }
    }

    return $false
}

if (Test-ManagedDaemonProcess -Path $daemonPath) {
    [Console]::Error.WriteLine("{0}: AgentQ Pueue daemon process is already running but unavailable; refusing to start a second daemon", $script:StartDaemonProgram)
    exit 2
}

Start-Process -FilePath $daemonPath -ArgumentList @("--config", $configPath) -WorkingDirectory $rootDirectory -WindowStyle Hidden | Out-Null
exit 0
