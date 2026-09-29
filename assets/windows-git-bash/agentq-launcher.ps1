[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ArgumentsBase64
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Read-AgentQBoundedText {
    param(
        [Parameter(Mandatory = $true)][System.IO.TextReader]$Reader,
        [int]$MaximumCharacters = 1048576
    )

    if ($MaximumCharacters -le 0) {
        throw "AgentQ argument payload limit must be positive"
    }
    $buffer = [char[]]::new(4096)
    $builder = [System.Text.StringBuilder]::new()
    while ($true) {
        $readCount = $Reader.Read($buffer, 0, $buffer.Length)
        if ($readCount -le 0) {
            break
        }
        if (($builder.Length + $readCount) -gt $MaximumCharacters) {
            throw "AgentQ argument payload exceeds $MaximumCharacters characters"
        }
        [void]$builder.Append($buffer, 0, $readCount)
    }
    return $builder.ToString()
}

function Read-AgentQArguments {
    param([string]$Encoded)

    if ($Encoded -eq "-") {
        $Encoded = Read-AgentQBoundedText -Reader ([Console]::In)
    }
    $Encoded = $Encoded.Trim()
    if ([string]::IsNullOrWhiteSpace($Encoded)) {
        throw "AgentQ argument payload is empty"
    }

    $bytes = [Convert]::FromBase64String($Encoded)
    $arguments = [System.Collections.Generic.List[string]]::new()
    $offset = 0
    while ($offset -lt $bytes.Length) {
        $end = $offset
        while (($end -lt $bytes.Length) -and ($bytes[$end] -ne 0)) {
            $end += 1
        }
        if ($end -eq $bytes.Length) {
            throw "AgentQ argument payload is malformed"
        }
        [void]$arguments.Add([System.Text.Encoding]::UTF8.GetString($bytes, $offset, ($end - $offset)))
        $offset = $end + 1
    }
    if ($arguments.Count -eq 0) {
        throw "AgentQ argument payload contains no arguments"
    }

    return $arguments.ToArray()
}

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
    foreach ($entry in @{
        "HOME" = $profile
        "USER" = $UserEnvironment.UserName
        "USERNAME" = $UserEnvironment.UserName
        "USERPROFILE" = $profile
        "APPDATA" = $UserEnvironment.AppData
        "LOCALAPPDATA" = $UserEnvironment.LocalAppData
        "HOMEDRIVE" = $UserEnvironment.HomeDrive
        "HOMEPATH" = $UserEnvironment.HomePath
        "TEMP" = $UserEnvironment.Temp
        "TMP" = $UserEnvironment.Temp
        "Path" = $UserEnvironment.Path
        "PATHEXT" = $UserEnvironment.PathExt
        "ComSpec" = $UserEnvironment.ComSpec
        "SystemDrive" = $UserEnvironment.SystemDrive
        "WINDIR" = $UserEnvironment.WindowsDirectory
        "SystemRoot" = $UserEnvironment.SystemRoot
    }.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }
}

function Test-AgentQLauncherRuntimeFilePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.PSIsContainer -or
                (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))) {
            return $false
        }

        $parent = [System.IO.Directory]::GetParent($fullPath)
        if ($null -eq $parent) {
            return $false
        }
        while ($null -ne $parent) {
            $parentItem = Get-Item -LiteralPath $parent.FullName -Force -ErrorAction SilentlyContinue
            if ($null -eq $parentItem -or $parentItem.PSIsContainer -eq $false -or
                    (($parentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                return $false
            }
            $parent = $parent.Parent
        }
        return $true
    } catch {
        return $false
    }
}

function Assert-AgentQLauncherRuntimeFilePath {
    param([string]$Path)

    if (!(Test-AgentQLauncherRuntimeFilePath -Path $Path)) {
        throw "Invalid AgentQ launcher runtime file path; expected a regular non-reparse file: $Path"
    }
}

function Remove-AgentQLauncherRuntimeFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }
    if (!(Test-AgentQLauncherRuntimeFilePath -Path $Path)) {
        [Console]::Error.WriteLine("$($script:Program): refusing to remove an unsafe AgentQ launcher runtime file: $Path")
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $true
    }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        [Console]::Error.WriteLine("$($script:Program): failed to remove AgentQ launcher runtime file: $Path")
        return $false
    }
    $remaining = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -ne $remaining) {
        [Console]::Error.WriteLine("$($script:Program): AgentQ launcher runtime file remained after cleanup: $Path")
        return $false
    }
    return $true
}

function Test-AgentQLauncherRequiredFilePath {
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

function Assert-AgentQLauncherRequiredFile {
    param(
        [string]$Path,
        [string]$Description
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        throw "$Description is missing: $Path"
    }
    if (!(Test-AgentQLauncherRequiredFilePath -Path $Path)) {
        throw "$Description is not a regular non-reparse file: $Path"
    }
}

function New-AgentQLauncherRuntimePath {
    param(
        [string]$Directory,
        [string]$Prefix
    )

    if ([string]::IsNullOrWhiteSpace($Directory) -or [string]::IsNullOrWhiteSpace($Prefix)) {
        throw "AgentQ launcher runtime directory and prefix are required"
    }
    # Runtime files use the agentq-launcher-runtime- prefix under the protected launcher root.
    for ($attempt = 0; $attempt -lt 20; $attempt += 1) {
        $candidate = Join-Path $Directory ("$Prefix-$PID-$([Guid]::NewGuid().ToString('N')).sh")
        try {
            $stream = [System.IO.File]::Open(
                $candidate,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            $stream.Dispose()
            try {
                Assert-AgentQLauncherRuntimeFilePath -Path $candidate
            } catch {
                [void](Remove-AgentQLauncherRuntimeFile -Path $candidate)
                throw
            }
            return [System.IO.Path]::GetFullPath($candidate)
        } catch [System.IO.IOException] {
            continue
        }
    }
    throw "Unable to create a unique AgentQ launcher runtime file"
}

$rootDirectory = $PSScriptRoot
$serverPath = Join-Path $rootDirectory "agentq"
$gitBashPath = '__AGENTQ_GIT_BASH_LAUNCHER__'

Assert-AgentQLauncherRequiredFile -Path $serverPath -Description "AgentQ server"
Assert-AgentQLauncherRequiredFile -Path $gitBashPath -Description "Git Bash launcher"

$encodedArguments = $ArgumentsBase64.Trim()
[string[]]$arguments = @(Read-AgentQArguments -Encoded $encodedArguments)
$currentUserEnvironment = Get-CurrentWindowsUserEnvironment
Set-AgentQUserEnvironment -UserEnvironment $currentUserEnvironment
$environmentVariable = "AGENTQ_SERVER_PATH"
$argumentCountEnvironmentVariable = "AGENTQ_ARGUMENT_COUNT"
$argumentEnvironmentPrefix = "AGENTQ_ARGUMENT_"
$previousServerPath = [Environment]::GetEnvironmentVariable($environmentVariable, "Process")
$previousArgumentCount = [Environment]::GetEnvironmentVariable($argumentCountEnvironmentVariable, "Process")
$previousArguments = @{}
$runtimeScriptPath = $null
$runtimeScriptContent = @'
#!/usr/bin/env bash

set -euo pipefail

server_path=$(cygpath -u -- "$AGENTQ_SERVER_PATH") || exit 2
count=${AGENTQ_ARGUMENT_COUNT-}
[ -n "$count" ] || exit 2
case "$count" in
    *[!0-9]*) exit 2 ;;
esac

set --
index=0
while [ "$index" -lt "$count" ]; do
    name=AGENTQ_ARGUMENT_$index
    argument=${!name-}
    set -- "$@" "$argument"
    unset "$name"
    index=$((index + 1))
done
unset AGENTQ_ARGUMENT_COUNT
exec "$server_path" "$@"
'@
$runtimeScriptCreated = $false
$exitCode = 2

try {
    $runtimeScriptPath = New-AgentQLauncherRuntimePath -Directory $rootDirectory -Prefix "agentq-launcher-runtime"
    $runtimeScriptCreated = $true
    [Environment]::SetEnvironmentVariable("MSYS_NO_PATHCONV", "1", "Process")
    [Environment]::SetEnvironmentVariable($environmentVariable, $serverPath, "Process")
    [Environment]::SetEnvironmentVariable($argumentCountEnvironmentVariable, [string]$arguments.Count, "Process")
    for ($index = 0; $index -lt $arguments.Count; $index += 1) {
        $argumentEnvironmentVariable = "$argumentEnvironmentPrefix$index"
        $previousArguments[$argumentEnvironmentVariable] = [Environment]::GetEnvironmentVariable($argumentEnvironmentVariable, "Process")
        [Environment]::SetEnvironmentVariable($argumentEnvironmentVariable, $arguments[$index], "Process")
    }
    Assert-AgentQLauncherRuntimeFilePath -Path $runtimeScriptPath
    [System.IO.File]::WriteAllText($runtimeScriptPath, $runtimeScriptContent, [System.Text.UTF8Encoding]::new($false))
    Assert-AgentQLauncherRuntimeFilePath -Path $runtimeScriptPath
    & $gitBashPath --noprofile --norc $runtimeScriptPath
    $exitCode = $LASTEXITCODE
} finally {
    if ($runtimeScriptCreated) {
        if (!(Remove-AgentQLauncherRuntimeFile -Path $runtimeScriptPath)) {
            $exitCode = 2
        }
    }
    [Environment]::SetEnvironmentVariable($environmentVariable, $previousServerPath, "Process")
    [Environment]::SetEnvironmentVariable($argumentCountEnvironmentVariable, $previousArgumentCount, "Process")
    foreach ($argumentEnvironmentVariable in $previousArguments.Keys) {
        [Environment]::SetEnvironmentVariable($argumentEnvironmentVariable, $previousArguments[$argumentEnvironmentVariable], "Process")
    }
}

exit $exitCode
