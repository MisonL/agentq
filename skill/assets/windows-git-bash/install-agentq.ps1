[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$StageDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:Program = "agentq-installer"

$taskName = "AgentQ Pueued"
$rootDirectory = "C:\ProgramData\AgentQ"
$parentDirectory = Split-Path -Parent $rootDirectory
$rootName = Split-Path -Leaf $rootDirectory
$expectedClientHash = "28b0756d54ec16ce13d78b251d086aa62e0057089cb27f793cd649f9762b996a"
$expectedDaemonHash = "aafa05e2f26cda9aff3eeb9be261e8f9f67752d1e9bb7fbcb47318e35c52ab1d"
$releaseVersion = "4.0.4"
$releaseBaseUrl = "https://github.com/Nukesor/pueue/releases/download/v$releaseVersion"
$clientAssetName = "pueue-x86_64-pc-windows-msvc.exe"
$daemonAssetName = "pueued-x86_64-pc-windows-msvc.exe"
$gitBashPath = $null
$gitBashRuntimePath = $null

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

$currentUserEnvironment = Get-CurrentWindowsUserEnvironment
$currentIdentity = $currentUserEnvironment.Identity
$legacyRootDirectory = $currentUserEnvironment.Profile
$legacyBinDirectory = Join-Path $legacyRootDirectory ".local\bin"
$legacyConfigPath = Join-Path $legacyRootDirectory ".config\agentq\pueue.yml"
$legacyClientPath = Join-Path $legacyBinDirectory "pueue.exe"
$legacyDaemonPath = Join-Path $legacyBinDirectory "pueued.exe"
$legacyStartupPath = Join-Path $legacyBinDirectory "agentq-start-daemon.ps1"
$legacyDataDirectory = Join-Path $legacyRootDirectory "AppData\Local\AgentQ"
$env:HOME = $currentUserEnvironment.Profile
$env:USER = $currentUserEnvironment.UserName
$env:USERNAME = $currentUserEnvironment.UserName
$env:USERPROFILE = $currentUserEnvironment.Profile
$env:APPDATA = $currentUserEnvironment.AppData
$env:LOCALAPPDATA = $currentUserEnvironment.LocalAppData
$env:HOMEDRIVE = $currentUserEnvironment.HomeDrive
$env:HOMEPATH = $currentUserEnvironment.HomePath
$env:TEMP = $currentUserEnvironment.Temp
$env:TMP = $currentUserEnvironment.Temp
$env:Path = $currentUserEnvironment.Path
$env:PATHEXT = $currentUserEnvironment.PathExt
$env:ComSpec = $currentUserEnvironment.ComSpec
$env:SystemDrive = $currentUserEnvironment.SystemDrive
$env:WINDIR = $currentUserEnvironment.WindowsDirectory
$env:SystemRoot = $currentUserEnvironment.SystemRoot

$transactionActive = $false
$rollbackRunning = $false
$candidateInstalled = $false
$previousRootMoved = $false
$previousDaemonStopped = $false
$previousDaemonStopAttempted = $false
$previousTask = $null
$failedRootDirectory = $null
$backupRootDirectory = $null
$stageRootDirectory = $null
$legacyWorkDirectory = $null
$legacyBackupDirectory = $null
$legacyDaemonStopped = $false
$legacyDaemonStopAttempted = $false
$legacyMovedArtifacts = [System.Collections.Generic.List[object]]::new()
$legacyMigrationRequired = $false
$preserveRecoveryArtifacts = $false
$rollbackFailures = [System.Collections.Generic.List[string]]::new()
$maintenanceLockDirectory = "$rootDirectory.maintenance.lock"
$maintenanceLockHeld = $false

function Require-Path {
    param([string]$Path)

    $pathItem = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $pathItem) {
        throw "Required AgentQ path is missing: $Path"
    }
    if (!(Test-NonReparseArtifactPath -Path $Path)) {
        throw "Required AgentQ path must be a regular non-reparse path: $Path"
    }
}

function Assert-Sha256 {
    param(
        [string]$Path,
        [string]$Expected
    )

    Assert-NonReparseFilePath -Path $Path -Description "SHA-256 input"
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) {
        throw "SHA-256 mismatch for $Path"
    }
}

function Resolve-GitBashPaths {
    $candidateRoots = [System.Collections.Generic.List[string]]::new()
    $candidatePaths = [System.Collections.Generic.List[string]]::new()

    foreach ($registryPath in @(
        "HKLM:\SOFTWARE\GitForWindows",
        "HKLM:\SOFTWARE\WOW6432Node\GitForWindows",
        "HKCU:\SOFTWARE\GitForWindows"
    )) {
        try {
            $installPath = (Get-ItemProperty -LiteralPath $registryPath -Name InstallPath -ErrorAction Stop).InstallPath
            if (![string]::IsNullOrWhiteSpace($installPath)) {
                [void]$candidateRoots.Add($installPath)
            }
        } catch {
        }
    }

    foreach ($commandName in @("git.exe", "bash.exe")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            $commandPath = $command.Source
            if ([string]::IsNullOrWhiteSpace($commandPath)) {
                $commandPath = $command.Path
            }
            if (![string]::IsNullOrWhiteSpace($commandPath)) {
                [void]$candidatePaths.Add($commandPath)
            }
        }
    }

    foreach ($programFilesPath in @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86),
        $env:ProgramW6432,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    )) {
        if (![string]::IsNullOrWhiteSpace($programFilesPath) -and !$candidateRoots.Contains($programFilesPath)) {
            [void]$candidateRoots.Add($programFilesPath)
        }
    }

    foreach ($path in $candidatePaths) {
        $candidateDirectory = Split-Path -Parent $path
        for ($depth = 0; $depth -lt 6 -and ![string]::IsNullOrWhiteSpace($candidateDirectory); $depth += 1) {
            if (!$candidateRoots.Contains($candidateDirectory)) {
                [void]$candidateRoots.Add($candidateDirectory)
            }
            $parentDirectory = Split-Path -Parent $candidateDirectory
            if ($parentDirectory -eq $candidateDirectory) {
                break
            }
            $candidateDirectory = $parentDirectory
        }
    }

    foreach ($root in $candidateRoots) {
        foreach ($candidateRoot in @($root, (Join-Path $root "Git"))) {
            $candidateLauncher = Join-Path $candidateRoot "bin\bash.exe"
            $candidateRuntime = Join-Path $candidateRoot "usr\bin\bash.exe"
            $candidateLauncherItem = Get-Item -LiteralPath $candidateLauncher -Force -ErrorAction SilentlyContinue
            $candidateRuntimeItem = Get-Item -LiteralPath $candidateRuntime -Force -ErrorAction SilentlyContinue
            if (($null -ne $candidateLauncherItem) -and !(Test-NonReparseFilePath -Path $candidateLauncher)) {
                throw "Git Bash with bin\\bash.exe and usr\\bin\\bash.exe is required; unsafe launcher candidate: $candidateLauncher"
            }
            if (($null -ne $candidateRuntimeItem) -and !(Test-NonReparseFilePath -Path $candidateRuntime)) {
                throw "Git Bash with bin\\bash.exe and usr\\bin\\bash.exe is required; unsafe runtime candidate: $candidateRuntime"
            }
            if (($null -ne $candidateLauncherItem) -and
                ($null -ne $candidateRuntimeItem) -and
                !$candidateLauncherItem.PSIsContainer -and
                !$candidateRuntimeItem.PSIsContainer) {
                return [pscustomobject]@{
                    LauncherPath = [System.IO.Path]::GetFullPath($candidateLauncher)
                    RuntimePath = [System.IO.Path]::GetFullPath($candidateRuntime)
                }
            }
        }
    }

    throw "Git Bash with bin\\bash.exe and usr\\bin\\bash.exe is required"
}

function Invoke-GitBashScript {
    param(
        [string]$GitBashPath,
        [string]$Script,
        [switch]$Login
    )

    # The script is transferred as base64 rather than as a command-line
    # argument.  PowerShell 5.1 wraps a native-command argument containing
    # spaces in double quotes but does not escape double quotes already inside
    # it, so the wrapper ends at the script's first quoted phrase and the CRT
    # parser word-splits the remainder.  Measured on Windows 10 /
    # PowerShell 5.1.19041: a script whose comment read
    # `# reports "Could not open file"` reached bash as two lines, and bash
    # exited 0 with no output at all -- the truncation surfaced far away as an
    # empty result.  pwsh 7.5 quotes correctly; 5.1 does not.  Base64's
    # alphabet is [A-Za-z0-9+/=], so the argument never needs quoting.
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Script))
    $command = "printf %s $encoded | base64 -d | bash --noprofile --norc"
    if ($Login) {
        $command += " -l"
    }
    & $GitBashPath --noprofile --norc -c $command
}

function Resolve-GitBashMsystem {
    param([string]$GitBashPath)

    $output = @(Invoke-GitBashScript -GitBashPath $GitBashPath -Script 'printf "%s" "$MSYSTEM"')
    if ($LASTEXITCODE -ne 0) {
        throw "Git Bash did not report its MSYSTEM value"
    }
    $msystem = ([string]($output | Select-Object -Last 1)).Trim()
    if ([string]::IsNullOrWhiteSpace($msystem)) {
        throw "Git Bash did not report its MSYSTEM value"
    }
    return $msystem
}

function Convert-ToPueueYamlSingleQuotedString {
    param([string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Convert-ToPowerShellSingleQuotedString {
    param([string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Install-PueueConfiguration {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$GitBashRuntimePath
    )

    $template = Read-AgentQInstallerTemplateFile -Path $SourcePath -Description "Pueue configuration template"
    $placeholder = "'__AGENTQ_GIT_BASH_RUNTIME__'"
    if ($template.IndexOf($placeholder, [System.StringComparison]::Ordinal) -lt 0) {
        throw "AgentQ Pueue configuration template is missing the Git Bash runtime placeholder"
    }

    $rendered = $template.Replace($placeholder, (Convert-ToPueueYamlSingleQuotedString -Value ($GitBashRuntimePath -replace '\\', '/')))
    if ($rendered.IndexOf($placeholder, [System.StringComparison]::Ordinal) -ge 0) {
        throw "AgentQ Pueue configuration template retained the Git Bash runtime placeholder"
    }

    Assert-NonReparseFilePath -Path $DestinationPath -Description "Pueue configuration destination" -AllowMissing
    $destinationDirectory = Split-Path -Parent $DestinationPath
    $temporaryPath = New-AgentQInstallerTemporaryFile -Directory $destinationDirectory -Prefix "config" -CandidatePath "$DestinationPath.new.$PID"
    # A `throw` inside a `finally` REPLACES the in-flight exception and aborts
    # the rest of the block -- so an unconditional cleanup throw here would
    # mask the real failure (e.g. a checksum mismatch) behind "cleanup
    # failed".  Merge both errors instead, like the other sites in this file.
    $operationError = $null
    $cleanupError = $null
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $rendered, [System.Text.UTF8Encoding]::new($false))
        Assert-NonReparseFilePath -Path $temporaryPath -Description "Pueue configuration temporary file"
        Assert-NonReparseFilePath -Path $DestinationPath -Description "Pueue configuration destination" -AllowMissing
        Move-Item -LiteralPath $temporaryPath -Destination $DestinationPath -Force
    } catch {
        $operationError = $_
    } finally {
        if (!(Remove-AgentQInstallerTemporaryFile -Path $temporaryPath -Description "Pueue configuration temporary file")) {
            $cleanupError = "Pueue configuration temporary cleanup failed: $temporaryPath"
        }
    }
    if ($null -ne $operationError) {
        if ($null -ne $cleanupError) {
            throw "$($operationError.Exception.Message); $cleanupError"
        }
        throw $operationError
    }
    if ($null -ne $cleanupError) {
        throw $cleanupError
    }
}

function Install-AgentQLauncher {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$GitBashPath
    )

    $template = Read-AgentQInstallerTemplateFile -Path $SourcePath -Description "AgentQ launcher template"
    $placeholder = "'__AGENTQ_GIT_BASH_LAUNCHER__'"
    if ($template.IndexOf($placeholder, [System.StringComparison]::Ordinal) -lt 0) {
        throw "AgentQ launcher template is missing the Git Bash launcher placeholder"
    }

    $rendered = $template.Replace($placeholder, (Convert-ToPowerShellSingleQuotedString -Value $GitBashPath))
    if ($rendered.IndexOf($placeholder, [System.StringComparison]::Ordinal) -ge 0) {
        throw "AgentQ launcher template retained the Git Bash launcher placeholder"
    }

    Assert-NonReparseFilePath -Path $DestinationPath -Description "AgentQ launcher destination" -AllowMissing
    $destinationDirectory = Split-Path -Parent $DestinationPath
    $temporaryPath = New-AgentQInstallerTemporaryFile -Directory $destinationDirectory -Prefix "launcher" -CandidatePath "$DestinationPath.new.$PID"
    # A `throw` inside a `finally` REPLACES the in-flight exception and aborts
    # the rest of the block -- so an unconditional cleanup throw here would
    # mask the real failure (e.g. a checksum mismatch) behind "cleanup
    # failed".  Merge both errors instead, like the other sites in this file.
    $operationError = $null
    $cleanupError = $null
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $rendered, [System.Text.UTF8Encoding]::new($false))
        Assert-NonReparseFilePath -Path $temporaryPath -Description "AgentQ launcher temporary file"
        Assert-NonReparseFilePath -Path $DestinationPath -Description "AgentQ launcher destination" -AllowMissing
        Move-Item -LiteralPath $temporaryPath -Destination $DestinationPath -Force
    } catch {
        $operationError = $_
    } finally {
        if (!(Remove-AgentQInstallerTemporaryFile -Path $temporaryPath -Description "AgentQ launcher temporary file")) {
            $cleanupError = "AgentQ launcher temporary cleanup failed: $temporaryPath"
        }
    }
    if ($null -ne $operationError) {
        if ($null -ne $cleanupError) {
            throw "$($operationError.Exception.Message); $cleanupError"
        }
        throw $operationError
    }
    if ($null -ne $cleanupError) {
        throw $cleanupError
    }
}

function Set-PrivatePathAcl {
    param([string]$Path)

    Assert-NonReparseFilePath -Path $Path -Description "private tree ACL path"
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::None
    }

    $acl.SetAccessRuleProtection($true, $false)
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($identity in @($currentIdentity, "NT AUTHORITY\SYSTEM", "BUILTIN\Administrators")) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, [System.Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow)
        [void]$acl.AddAccessRule($rule)
    }

    Set-Acl -LiteralPath $Path -AclObject $acl

    # Read it back.  A successful Set-Acl is not evidence that the protection
    # landed, and this tree is the reason the ACL exists at all -- if it stays
    # inherited, every later read of the shared secret and the daemon key is
    # exposed to whatever the profile grants.  The same "set it and assume it
    # applied" shape is what let `chmod 700` report success on a noacl mount in
    # the client installer, so the write is verified rather than trusted.
    $applied = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $ownerRule = @($applied.Access | Where-Object {
            $_.AccessControlType -eq $allow -and
            ($_.IdentityReference.Value -eq $currentIdentity) -and
            (($_.FileSystemRights -band $fullControl) -eq $fullControl)
        }).Count -gt 0
    if (!$applied.AreAccessRulesProtected -or !$ownerRule) {
        throw "AgentQ private path ACL did not apply: $Path"
    }
}

function Get-PrivateTreeItems {
    param([string]$Path)

    $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (($null -eq $rootItem) -or !$rootItem.PSIsContainer) {
        throw "AgentQ private tree is missing or is not a directory: $Path"
    }
    if (!(Test-NonReparseDirectoryPath -Path $Path)) {
        throw "AgentQ private tree must be a regular non-reparse directory path: $Path"
    }

    $root = $rootItem
    if (($root.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "AgentQ private tree must not be a reparse point: $Path"
    }

    $items = [System.Collections.Generic.List[System.IO.FileSystemInfo]]::new()
    $directories = [System.Collections.Generic.Queue[System.IO.DirectoryInfo]]::new()
    [void]$items.Add($root)
    $directories.Enqueue([System.IO.DirectoryInfo]$root)

    while ($directories.Count -gt 0) {
        $directory = $directories.Dequeue()
        foreach ($child in @($directory.EnumerateFileSystemInfos())) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "AgentQ private tree contains a reparse point: $($child.FullName)"
            }
            [void]$items.Add($child)
            if ($child -is [System.IO.DirectoryInfo]) {
                $directories.Enqueue($child)
            }
        }
    }

    return $items.ToArray()
}

function Set-PrivateTreeAcl {
    param([string]$Path)

    foreach ($item in @(Get-PrivateTreeItems -Path $Path)) {
        Set-PrivatePathAcl -Path $item.FullName
    }
}

function Test-PueueConnection {
    param(
        [string]$ClientPath,
        [string]$ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($ClientPath) -or [string]::IsNullOrWhiteSpace($ConfigPath)) {
        return $false
    }
    Assert-NonReparseFilePath -Path $ClientPath -Description "Pueue client path" -AllowMissing
    Assert-NonReparseFilePath -Path $ConfigPath -Description "Pueue config path" -AllowMissing
    $clientItem = Get-Item -LiteralPath $ClientPath -Force -ErrorAction SilentlyContinue
    $configItem = Get-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
    if (($null -ne $clientItem) -and !(Test-NonReparseFilePath -Path $ClientPath)) {
        throw "AgentQ Pueue client path must be a regular non-reparse path: $ClientPath"
    }
    if (($null -ne $configItem) -and !(Test-NonReparseFilePath -Path $ConfigPath)) {
        throw "AgentQ Pueue config path must be a regular non-reparse path: $ConfigPath"
    }
    if (($null -eq $clientItem) -or ($null -eq $configItem)) {
        return $false
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $ClientPath --config $ConfigPath status --json 1> $null 2> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Assert-ManagedPueueConnection {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$DaemonPath,
        [string]$Description
    )

    if (!(Test-PueueConnection -ClientPath $ClientPath -ConfigPath $ConfigPath)) {
        throw "$Description AgentQ daemon is unavailable: $DaemonPath"
    }
    if (!(Test-ManagedPueueProcess -DaemonPath $DaemonPath)) {
        throw "$Description AgentQ endpoint is not served by the expected daemon: $DaemonPath"
    }
}

function Get-ManagedPueueProcesses {
    param([string]$DaemonPath)

    Assert-NonReparseFilePath -Path $DaemonPath -Description "Pueue daemon path" -AllowMissing
    $target = [System.IO.Path]::GetFullPath($DaemonPath)
    return @(
        Get-Process -Name pueued -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($_.Path -ieq $target) {
                    $_
                }
            } catch {
            }
        }
    )
}

function Test-ManagedPueueProcess {
    param([string]$DaemonPath)

    return (@(Get-ManagedPueueProcesses -DaemonPath $DaemonPath).Count -gt 0)
}

function Get-PueueStatus {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$TemporaryDirectory = "",
        [int]$MaximumBytes = 1048576
    )

    if ([string]::IsNullOrWhiteSpace($TemporaryDirectory)) {
        $TemporaryDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($ConfigPath))
    }
    return (Get-PueueStatusFromTemporaryFile -ClientPath $ClientPath -ConfigPath $ConfigPath -TemporaryDirectory $TemporaryDirectory -MaximumBytes $MaximumBytes)
}

function Assert-NoActivePueueTasks {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$Description
    )

    # This reads the RAW `pueue status --json`, whose size tracks the host's
    # entire task history, so it gets the large ceiling rather than the 1 MiB
    # default.  Still finite: 64 MiB is far above any real queue and far below
    # anything that would exhaust memory.
    $state = Get-PueueStatus -ClientPath $ClientPath -ConfigPath $ConfigPath -MaximumBytes 67108864
    if ($null -eq $state.tasks) {
        throw "$Description Pueue status omitted the tasks object"
    }
    $activeTasks = @($state.tasks.PSObject.Properties | Where-Object {
        $status = $_.Value.status
        $null -eq $status -or @($status.PSObject.Properties | Where-Object { $_.Name -eq "Done" }).Count -eq 0
    })
    if ($activeTasks.Count -ne 0) {
        throw "$Description AgentQ queue has active tasks; wait for them to finish before update"
    }
}

function Stop-PueueDaemon {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$DaemonPath
    )

    Assert-NonReparseFilePath -Path $DaemonPath -Description "Pueue daemon path" -AllowMissing
    $isReachable = Test-PueueConnection -ClientPath $ClientPath -ConfigPath $ConfigPath
    $processes = @(Get-ManagedPueueProcesses -DaemonPath $DaemonPath)
    if (!$isReachable -and $processes.Count -eq 0) {
        return
    }

    if ($isReachable) {
        if ($processes.Count -eq 0) {
            throw "Pueue endpoint is reachable but is not served by the expected daemon: $DaemonPath"
        }

        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $ClientPath --config $ConfigPath shutdown 1> $null 2> $null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to stop Pueue daemon: $ClientPath"
            }
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    }

    Wait-ForDaemonStop -ClientPath $ClientPath -ConfigPath $ConfigPath -DaemonPath $DaemonPath
}

function Wait-ForDaemon {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$DaemonPath,
        [int]$Attempts = 10
    )

    for ($attempt = 0; $attempt -lt $Attempts; $attempt += 1) {
        if ((Test-PueueConnection -ClientPath $ClientPath -ConfigPath $ConfigPath) -and (Test-ManagedPueueProcess -DaemonPath $DaemonPath)) {
            return
        }
        Start-Sleep -Seconds 1
    }

    throw "Pueue daemon did not become ready after $Attempts seconds"
}

function Get-ProcessDescendants {
    param([int]$ParentId)

    foreach ($child in @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $ParentId" -ErrorAction Stop)) {
        foreach ($descendant in @(Get-ProcessDescendants -ParentId ([int]$child.ProcessId))) {
            $descendant
        }
        $child
    }
}

function Test-ProcessSnapshotIdentity {
    param([object]$Snapshot)

    $processId = [int]$Snapshot.ProcessId
    $current = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop)
    if ($current.Count -eq 0) {
        return $false
    }
    if ($current.Count -ne 1 -or
        [string]::IsNullOrEmpty([string]$Snapshot.CreationDate) -or
        [string]::IsNullOrEmpty([string]$current[0].CreationDate) -or
        [int]$current[0].ParentProcessId -ne [int]$Snapshot.ParentProcessId -or
        [string]$current[0].CreationDate -ne [string]$Snapshot.CreationDate) {
        throw "AgentQ process identity changed before forced termination: $processId"
    }
    return $true
}

function Stop-ManagedPueueProcessTree {
    param([object]$RootProcess)

    $rootId = [int]$RootProcess.Id
    $rootStartTime = $RootProcess.StartTime
    $currentRoot = Get-Process -Id $rootId -ErrorAction SilentlyContinue
    if ($null -eq $currentRoot) {
        return
    }
    if ($currentRoot.StartTime -ne $rootStartTime) {
        throw "AgentQ daemon process identity changed before forced termination: $rootId"
    }
    $descendants = @(Get-ProcessDescendants -ParentId $rootId)
    $validatedDescendants = @()
    foreach ($descendant in $descendants) {
        if (Test-ProcessSnapshotIdentity -Snapshot $descendant) {
            $validatedDescendants += $descendant
        }
    }
    $currentRoot = Get-Process -Id $rootId -ErrorAction SilentlyContinue
    if ($null -eq $currentRoot) {
        return
    }
    if ($currentRoot.StartTime -ne $rootStartTime) {
        throw "AgentQ daemon process identity changed before forced termination: $rootId"
    }
    foreach ($descendant in $validatedDescendants) {
        $process = Get-Process -Id ([int]$descendant.ProcessId) -ErrorAction SilentlyContinue
        if ($null -ne $process) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        }
    }

    $currentRoot = Get-Process -Id $rootId -ErrorAction SilentlyContinue
    if ($null -eq $currentRoot) {
        return
    }
    if ($currentRoot.StartTime -ne $rootStartTime) {
        throw "AgentQ daemon process identity changed before forced termination: $rootId"
    }
    Stop-Process -Id $currentRoot.Id -Force -ErrorAction Stop
}

function Wait-ForDaemonStop {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$DaemonPath,
        [int]$Attempts = 10
    )

    for ($attempt = 0; $attempt -lt $Attempts; $attempt += 1) {
        if (!(Test-PueueConnection -ClientPath $ClientPath -ConfigPath $ConfigPath) -and !(Test-ManagedPueueProcess -DaemonPath $DaemonPath)) {
            return
        }
        Start-Sleep -Seconds 1
    }

    foreach ($process in @(Get-ManagedPueueProcesses -DaemonPath $DaemonPath)) {
        Stop-ManagedPueueProcessTree -RootProcess $process
    }

    for ($attempt = 0; $attempt -lt $Attempts; $attempt += 1) {
        if (!(Test-PueueConnection -ClientPath $ClientPath -ConfigPath $ConfigPath) -and !(Test-ManagedPueueProcess -DaemonPath $DaemonPath)) {
            return
        }
        Start-Sleep -Seconds 1
    }

    throw "Pueue daemon did not stop after graceful shutdown and forced termination: $DaemonPath"
}

function Start-PueueDaemon {
    param(
        [string]$StartupPath,
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$DaemonPath
    )

    Assert-NonReparseFilePath -Path $StartupPath -Description "AgentQ startup launcher"
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $StartupPath 1> $null 2> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to launch AgentQ Pueue daemon"
    }
    Wait-ForDaemon -ClientPath $ClientPath -ConfigPath $ConfigPath -DaemonPath $DaemonPath
}

function Assert-NonReparseDirectory {
    param(
        [string]$Path,
        [string]$Description
    )

    $directoryItem = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (($null -eq $directoryItem) -or !$directoryItem.PSIsContainer) {
        throw "AgentQ Pueue $Description is missing or is not a directory: $Path"
    }

    if (!(Test-NonReparseDirectoryPath -Path $Path)) {
        throw "AgentQ Pueue $Description must be a regular non-reparse directory: $Path"
    }
}

function Test-NonReparseFilePath {
    param(
        [string]$Path,
        [switch]$AllowMissing
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) {
            foreach ($systemAlias in @('/var', '/tmp')) {
                $aliasItem = Get-Item -LiteralPath $systemAlias -Force -ErrorAction SilentlyContinue
                $privateAlias = Join-Path '/private' $systemAlias.TrimStart('/')
                $privateAliasItem = Get-Item -LiteralPath $privateAlias -Force -ErrorAction SilentlyContinue
                if ($null -ne $aliasItem -and
                    (($aliasItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -and
                    $null -ne $privateAliasItem -and $privateAliasItem.PSIsContainer -and
                    ($fullPath -eq $systemAlias -or $fullPath.StartsWith("$systemAlias/", [System.StringComparison]::Ordinal))) {
                    $fullPath = '/private' + $fullPath
                    break
                }
            }
        }
    } catch {
        return $false
    }

    $item = $null
    try {
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    } catch {
        if (!$AllowMissing -or ($_.Exception -isnot [System.Management.Automation.ItemNotFoundException])) {
            return $false
        }
    }
    if ($null -ne $item -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        return $false
    }

    $parent = [System.IO.Directory]::GetParent($fullPath)
    if ($null -eq $parent) {
        return $false
    }
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

function Assert-NonReparseFilePath {
    param(
        [string]$Path,
        [string]$Description,
        [switch]$AllowMissing
    )

    if (!(Test-NonReparseFilePath -Path $Path -AllowMissing:$AllowMissing)) {
        throw "AgentQ $Description must be a regular non-reparse path: $Path"
    }
}

function Get-AgentQInstallerFileIdentity {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if (!(Test-NonReparseFilePath -Path $Path)) {
        return $null
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return $null
        }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName -ErrorAction Stop).Hash.ToLowerInvariant()
        return [string]::Join("|", @(
            [System.IO.Path]::GetFullPath($item.FullName),
            [string]$item.Length,
            [string]$item.CreationTimeUtc.Ticks,
            [string]$item.LastWriteTimeUtc.Ticks,
            $hash
        ))
    } catch {
        return $null
    }
}

function Remove-AgentQInstallerResponseTemporaryFile {
    param(
        [string]$Path,
        [AllowNull()][string]$ExpectedIdentity,
        [string]$Description = "installer response temporary file"
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedIdentity)) {
        [Console]::Error.WriteLine("$($script:Program): refusing to remove $Description without a recorded identity`: $Path")
        return $false
    }
    $observedIdentity = Get-AgentQInstallerFileIdentity -Path $Path
    if ([string]::IsNullOrWhiteSpace($observedIdentity)) {
        [Console]::Error.WriteLine("$($script:Program): refusing to remove $Description with an unreadable identity`: $Path")
        return $false
    }
    if ($observedIdentity -cne $ExpectedIdentity) {
        [Console]::Error.WriteLine("$($script:Program): $Description identity changed during cleanup; preserving it`: $Path")
        return $false
    }
    return (Remove-AgentQInstallerTemporaryFile -Path $Path -Description $Description)
}

function Read-AgentQInstallerJsonFile {
    param(
        [string]$Path,
        [string]$Description = "AgentQ installer JSON response",
        [int]$MaximumBytes = 1048576
    )

    Assert-NonReparseFilePath -Path $Path -Description "$Description file"

    # Pueue retains every finished task, so a raw `pueue status --json` grows
    # without bound over a machine's lifetime.  A fixed 1 MiB ceiling made the
    # installer refuse to update any host with enough history -- measured on a
    # real host at 270 tasks: 1507407 bytes, i.e. 458831 over.  The default
    # stays at 1 MiB for the small, bounded payloads (group query, health
    # check, launcher smoke); only the status reader passes a larger ceiling,
    # and that ceiling is still finite so a runaway response cannot exhaust
    # memory.
    if ($MaximumBytes -le 0) {
        throw "$Description JSON limit must be positive"
    }
    $maximumJsonBytes = $MaximumBytes
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $buffer = [byte[]]::new($maximumJsonBytes + 1)
        $offset = 0
        while ($offset -lt $buffer.Length) {
            $readCount = $stream.Read($buffer, $offset, $buffer.Length - $offset)
            if ($readCount -eq 0) {
                break
            }
            $offset += $readCount
        }
    } catch {
        throw "$Description could not be read"
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    if ($offset -gt $maximumJsonBytes) {
        throw "$Description exceeded the fixed JSON limit of $maximumJsonBytes bytes"
    }

    try {
        if ($offset -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) {
            $encoding = [System.Text.UTF8Encoding]::new($true, $true)
            $contentOffset = 3
        } elseif ($offset -ge 2 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) {
            $encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true)
            $contentOffset = 2
        } elseif ($offset -ge 2 -and $buffer[0] -eq 0xFE -and $buffer[1] -eq 0xFF) {
            $encoding = [System.Text.UnicodeEncoding]::new($true, $true, $true)
            $contentOffset = 2
        } else {
            $encoding = [System.Text.UTF8Encoding]::new($false, $true)
            $contentOffset = 0
        }
        $jsonText = $encoding.GetString($buffer, $contentOffset, $offset - $contentOffset)
    } catch {
        throw "$Description returned invalid JSON encoding"
    }

    try {
        return ($jsonText | ConvertFrom-Json)
    } catch {
        throw "$Description returned invalid JSON"
    }
}

function Read-AgentQInstallerTemplateFile {
    param(
        [string]$Path,
        [string]$Description = "AgentQ installer template"
    )

    Assert-NonReparseFilePath -Path $Path -Description "$Description file"
    try {
        $sourceItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        throw "$Description could not be read"
    }
    if ($sourceItem.PSIsContainer) {
        throw "$Description must be a regular non-reparse file: $Path"
    }

    $maximumTemplateBytes = 1048576
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $buffer = [byte[]]::new($maximumTemplateBytes + 1)
        $offset = 0
        while ($offset -lt $buffer.Length) {
            $readCount = $stream.Read($buffer, $offset, $buffer.Length - $offset)
            if ($readCount -eq 0) {
                break
            }
            $offset += $readCount
        }
    } catch {
        throw "$Description could not be read"
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    if ($offset -gt $maximumTemplateBytes) {
        throw "$Description exceeded the fixed template limit of $maximumTemplateBytes bytes"
    }

    try {
        if ($offset -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) {
            $encoding = [System.Text.UTF8Encoding]::new($true, $true)
            $contentOffset = 3
        } elseif ($offset -ge 2 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) {
            $encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true)
            $contentOffset = 2
        } elseif ($offset -ge 2 -and $buffer[0] -eq 0xFE -and $buffer[1] -eq 0xFF) {
            $encoding = [System.Text.UnicodeEncoding]::new($true, $true, $true)
            $contentOffset = 2
        } else {
            $encoding = [System.Text.UTF8Encoding]::new($false, $true)
            $contentOffset = 0
        }
        return $encoding.GetString($buffer, $contentOffset, $offset - $contentOffset)
    } catch {
        throw "$Description returned invalid template encoding"
    }
}

function Get-PueueGroupsFromTemporaryFile {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$RuntimeDirectory
    )

    $temporaryPath = $null
    $temporaryIdentity = $null
    $result = $null
    $operationError = $null
    $cleanupError = $null
    try {
        $temporaryPath = New-AgentQInstallerTemporaryFile -Directory $RuntimeDirectory -Prefix "group-status"
        Assert-NonReparseFilePath -Path $temporaryPath -Description "Pueue group response temporary file"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $ClientPath --config $ConfigPath group --json 1> $temporaryPath 2> $null
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $temporaryItem = Get-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $temporaryItem) {
            $temporaryIdentity = Get-AgentQInstallerFileIdentity -Path $temporaryPath
        }
        if ($exitCode -ne 0) {
            throw "Staged Pueue group query failed"
        }
        Assert-NonReparseFilePath -Path $temporaryPath -Description "Pueue group response temporary file"
        if ([string]::IsNullOrWhiteSpace($temporaryIdentity)) {
            throw "Unable to record Pueue group response temporary file identity"
        }
        $result = Read-AgentQInstallerJsonFile -Path $temporaryPath -Description "Staged Pueue group query"
        if ($null -eq $result) {
            throw "Staged Pueue group query returned an empty JSON payload"
        }
    } catch {
        $operationError = $_
    } finally {
        if (!(Remove-AgentQInstallerResponseTemporaryFile -Path $temporaryPath -ExpectedIdentity $temporaryIdentity -Description "Pueue group response temporary file")) {
            $cleanupError = "Pueue group response temporary cleanup failed: $temporaryPath"
        }
    }
    if ($null -ne $operationError) {
        if ($null -ne $cleanupError) {
            throw "$($operationError.Exception.Message); $cleanupError"
        }
        throw $operationError
    }
    if ($null -ne $cleanupError) {
        throw $cleanupError
    }
    return $result
}

function Get-PueueHealthFromTemporaryFile {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$RuntimeDirectory
    )

    $temporaryPath = $null
    $temporaryIdentity = $null
    $result = $null
    $operationError = $null
    $cleanupError = $null
    try {
        $temporaryPath = New-AgentQInstallerTemporaryFile -Directory $RuntimeDirectory -Prefix "health-status"
        Assert-NonReparseFilePath -Path $temporaryPath -Description "Pueue health response temporary file"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $exitCode = Invoke-AgentQInstallerPueueStatus -ClientPath $ClientPath -ConfigPath $ConfigPath -DestinationPath $temporaryPath
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $temporaryItem = Get-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $temporaryItem) {
            $temporaryIdentity = Get-AgentQInstallerFileIdentity -Path $temporaryPath
        }
        if ($exitCode -ne 0) {
            throw "Staged Pueue health check failed"
        }
        Assert-NonReparseFilePath -Path $temporaryPath -Description "Pueue health response temporary file"
        if ([string]::IsNullOrWhiteSpace($temporaryIdentity)) {
            throw "Unable to record Pueue health response temporary file identity"
        }
        # Raw status, whose size tracks the host's whole task history -- same
        # reasoning as Assert-NoActivePueueTasks.  The 1 MiB default is for the
        # small bounded payloads (group query, launcher smoke).
        $result = Read-AgentQInstallerJsonFile -Path $temporaryPath -Description "Staged Pueue health check" -MaximumBytes 67108864
        $tasks = $null
        $agentqGroup = $null
        if ($null -ne $result) {
            $tasksProperty = $result.PSObject.Properties["tasks"]
            if ($null -ne $tasksProperty) {
                $tasks = $tasksProperty.Value
            }
            $groupsProperty = $result.PSObject.Properties["groups"]
            if ($null -ne $groupsProperty -and $null -ne $groupsProperty.Value) {
                $agentqProperty = $groupsProperty.Value.PSObject.Properties["agentq"]
                if ($null -ne $agentqProperty) {
                    $agentqGroup = $agentqProperty.Value
                }
            }
        }
        if ($null -eq $result -or $null -eq $tasks -or $null -eq $agentqGroup) {
            throw "AgentQ health check returned an invalid Pueue status payload"
        }
    } catch {
        $operationError = $_
    } finally {
        if (!(Remove-AgentQInstallerResponseTemporaryFile -Path $temporaryPath -ExpectedIdentity $temporaryIdentity -Description "Pueue health response temporary file")) {
            $cleanupError = "Pueue health response temporary cleanup failed: $temporaryPath"
        }
    }
    if ($null -ne $operationError) {
        if ($null -ne $cleanupError) {
            throw "$($operationError.Exception.Message); $cleanupError"
        }
        throw $operationError
    }
    if ($null -ne $cleanupError) {
        throw $cleanupError
    }
    return $result
}

function Invoke-AgentQInstallerPueueStatus {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$DestinationPath
    )

    # Capture `pueue status --json` WITHOUT going through PowerShell's
    # redirection.  `& $exe ... 1> $file` makes PowerShell decode the child's
    # stdout using the console code page and then re-encode it as UTF-16LE.
    # On a host whose code page is not UTF-8 (measured: 936 / GBK) that
    # corrupts any non-ASCII byte in the payload: a path containing U+F03A
    # arrives as two unrelated CJK characters, the byte count doubles, and
    # ConvertFrom-Json then fails with "unrecognized escape sequence" at an
    # offset that has nothing to do with the real cause.  Verified on Windows
    # 10 / PS 5.1.26100: the redirect path fails to parse a 270-task status,
    # while ProcessStartInfo with an explicit UTF-8 stdout encoding parses it
    # and reproduces the non-ASCII fields byte for byte.
    #
    # stderr is read asynchronously so a child that fills the stderr pipe
    # cannot deadlock against our stdout read.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ClientPath
    $startInfo.Arguments = "--config `"$ConfigPath`" status --json"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
    } catch {
        throw "Pueue status command could not be started: $ClientPath"
    }
    try {
        $errorTask = $process.StandardError.ReadToEndAsync()
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        [void]$errorTask.Result
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }

    # UTF-8 without a BOM: the reader below probes for a BOM and would
    # otherwise mis-detect the payload's encoding.
    [System.IO.File]::WriteAllText($DestinationPath, $standardOutput, [System.Text.UTF8Encoding]::new($false))
    return $exitCode
}

function Get-PueueStatusFromTemporaryFile {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$TemporaryDirectory,
        [int]$MaximumBytes = 1048576
    )

    $temporaryPath = $null
    $temporaryIdentity = $null
    $result = $null
    $operationError = $null
    $cleanupError = $null
    try {
        $temporaryPath = New-AgentQInstallerTemporaryFile -Directory $TemporaryDirectory -Prefix "status"
        Assert-NonReparseFilePath -Path $temporaryPath -Description "Pueue status response temporary file"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $exitCode = Invoke-AgentQInstallerPueueStatus -ClientPath $ClientPath -ConfigPath $ConfigPath -DestinationPath $temporaryPath
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $temporaryItem = Get-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $temporaryItem) {
            $temporaryIdentity = Get-AgentQInstallerFileIdentity -Path $temporaryPath
        }
        if ($exitCode -ne 0) {
            throw "Pueue status command failed: $ClientPath"
        }
        Assert-NonReparseFilePath -Path $temporaryPath -Description "Pueue status response temporary file"
        if ([string]::IsNullOrWhiteSpace($temporaryIdentity)) {
            throw "Unable to record Pueue status response temporary file identity"
        }
        $result = Read-AgentQInstallerJsonFile -Path $temporaryPath -Description "Pueue status command" -MaximumBytes $MaximumBytes
        if ($null -eq $result) {
            throw "Pueue status command returned an empty JSON payload"
        }
    } catch {
        $operationError = $_
    } finally {
        if (!(Remove-AgentQInstallerResponseTemporaryFile -Path $temporaryPath -ExpectedIdentity $temporaryIdentity -Description "Pueue status response temporary file")) {
            $cleanupError = "Pueue status response temporary cleanup failed: $temporaryPath"
        }
    }
    if ($null -ne $operationError) {
        if ($null -ne $cleanupError) {
            throw "$($operationError.Exception.Message); $cleanupError"
        }
        throw $operationError
    }
    if ($null -ne $cleanupError) {
        throw $cleanupError
    }
    return $result
}

function Remove-AgentQInstallerTemporaryFile {
    param(
        [string]$Path,
        [string]$Description = "installer temporary file"
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $true
    }
    if (!(Test-NonReparseFilePath -Path $Path)) {
        [Console]::Error.WriteLine("$($script:Program): refusing to remove unsafe $Description`: $Path")
        return $false
    }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        [Console]::Error.WriteLine("$($script:Program): failed to remove $Description`: $Path")
        return $false
    }
    $remaining = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -ne $remaining) {
        [Console]::Error.WriteLine("$($script:Program): $Description remained after cleanup: $Path")
        return $false
    }
    return $true
}

function New-AgentQInstallerTemporaryFile {
    param(
        [string]$Directory,
        [string]$Prefix,
        [string]$CandidatePath = ""
    )

    if ([string]::IsNullOrWhiteSpace($Directory) -or [string]::IsNullOrWhiteSpace($Prefix)) {
        throw "AgentQ installer temporary directory and prefix are required"
    }
    if (!(Test-NonReparseDirectoryPath -Path $Directory)) {
        throw "AgentQ installer temporary directory must be a regular non-reparse path: $Directory"
    }
    for ($attempt = 0; $attempt -lt 20; $attempt += 1) {
        $candidate = if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
            Join-Path $Directory (".agentq-installer-$Prefix-$PID-$([Guid]::NewGuid().ToString('N')).tmp")
        } else {
            [System.IO.Path]::GetFullPath($CandidatePath)
        }
        try {
            Assert-NonReparseFilePath -Path $candidate -Description "installer temporary file" -AllowMissing
            $stream = [System.IO.File]::Open(
                $candidate,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            $stream.Dispose()
            try {
                Assert-NonReparseFilePath -Path $candidate -Description "installer temporary file"
            } catch {
                [void](Remove-AgentQInstallerTemporaryFile -Path $candidate -Description "installer temporary file")
                throw
            }
            return [System.IO.Path]::GetFullPath($candidate)
        } catch [System.IO.IOException] {
            if (![string]::IsNullOrWhiteSpace($CandidatePath)) {
                throw "AgentQ installer temporary path is already in use: $candidate"
            }
            continue
        }
    }
    throw "Unable to create a unique AgentQ installer temporary file"
}

function Test-NonReparseArtifactPath {
    param(
        [string]$Path,
        [switch]$AllowMissing
    )

    return (Test-NonReparseFilePath -Path $Path -AllowMissing:$AllowMissing)
}

function Assert-NonReparseArtifactPath {
    param(
        [string]$Path,
        [string]$Description,
        [switch]$AllowMissing
    )

    if (!(Test-NonReparseArtifactPath -Path $Path -AllowMissing:$AllowMissing)) {
        throw "AgentQ $Description must be a regular non-reparse path: $Path"
    }
}

function Test-NonReparseDirectoryPath {
    param(
        [string]$Path,
        [switch]$AllowMissing
    )

    if (![string]::IsNullOrWhiteSpace($Path) -and !(Test-NonReparseArtifactPath -Path $Path -AllowMissing:$AllowMissing)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $item = $null
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        if ($_.Exception -isnot [System.Management.Automation.ItemNotFoundException]) {
            return $false
        }
        return [bool]$AllowMissing
    }
    if (!$item.PSIsContainer) {
        return $false
    }
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
}

function Assert-NonReparseDirectoryPath {
    param(
        [string]$Path,
        [string]$Description,
        [switch]$AllowMissing
    )

    if (!(Test-NonReparseDirectoryPath -Path $Path -AllowMissing:$AllowMissing)) {
        throw "AgentQ $Description must be a regular non-reparse path: $Path"
    }
}

function Assert-PueueCredentialFile {
    param(
        [string]$Path,
        [string]$Description,
        [int64]$ExpectedLength = 0
    )

    $credentialItem = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (($null -eq $credentialItem) -or $credentialItem.PSIsContainer) {
        throw "AgentQ Pueue $Description is missing or is not a regular file: $Path"
    }

    if (!(Test-NonReparseFilePath -Path $Path)) {
        throw "AgentQ Pueue $Description must be a regular non-reparse path: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "AgentQ Pueue $Description must not be a reparse point: $Path"
    }
    if ($item.Length -le 0) {
        throw "AgentQ Pueue $Description is empty: $Path"
    }
    if (($ExpectedLength -gt 0) -and ($item.Length -ne $ExpectedLength)) {
        throw "AgentQ Pueue $Description has an unexpected length: $Path"
    }
}

function Assert-ManagedPueueCredentials {
    param([string]$DataDirectory)

    $certificateDirectory = Join-Path $DataDirectory "certs"
    Assert-NonReparseDirectory -Path $DataDirectory -Description "data directory"
    Assert-NonReparseDirectory -Path $certificateDirectory -Description "certificate directory"
    Assert-PueueCredentialFile -Path (Join-Path $certificateDirectory "daemon.cert") -Description "TLS certificate"
    Assert-PueueCredentialFile -Path (Join-Path $certificateDirectory "daemon.key") -Description "TLS private key"
    Assert-PueueCredentialFile -Path (Join-Path $DataDirectory "shared_secret") -Description "shared secret" -ExpectedLength 512
}

function Get-PueueTaskResult {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$TaskId,
        [string]$GitBashPath,
        [string]$TemporaryDirectory
    )

    $temporaryPath = $null
    $temporaryIdentity = $null
    $operationError = $null
    $cleanupError = $null
    $environmentValues = @{
        "AGENTQ_SMOKE_PUEUE_PATH" = $ClientPath
        "AGENTQ_SMOKE_CONFIG_PATH" = $ConfigPath
        "AGENTQ_SMOKE_TASK_ID" = $TaskId
        "AGENTQ_SMOKE_STATUS_PATH" = $null
        "MSYS_NO_PATHCONV" = "1"
    }
    $previousValues = @{}
    $hadPreviousValues = @{}

    foreach ($name in $environmentValues.Keys) {
        $environmentPath = "Env:$name"
        $hadPreviousValues[$name] = Test-Path -LiteralPath $environmentPath
        $previousValues[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }

    try {
        $temporaryPath = New-AgentQInstallerTemporaryFile -Directory $TemporaryDirectory -Prefix "smoke-status"
        Assert-NonReparseFilePath -Path $temporaryPath -Description "Pueue shell smoke status temporary file"
        $environmentValues["AGENTQ_SMOKE_STATUS_PATH"] = $temporaryPath
        foreach ($name in $environmentValues.Keys) {
            $environmentPath = "Env:$name"
            $hadPreviousValues[$name] = Test-Path -LiteralPath $environmentPath
            $previousValues[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            [Environment]::SetEnvironmentVariable($name, $environmentValues[$name], "Process")
        }

        $statusCommand = @'
set -e
pueue_path=$(cygpath -u -- "$AGENTQ_SMOKE_PUEUE_PATH") || exit 2
status_path=$(cygpath -u -- "$AGENTQ_SMOKE_STATUS_PATH") || exit 2
"$pueue_path" --config "$AGENTQ_SMOKE_CONFIG_PATH" status --json > "$status_path"
# Feed the file on stdin rather than as a jq argument.  This block runs with
# MSYS_NO_PATHCONV=1 set (see the environment table above), which disables
# MSYS path translation for child processes, and jq here is a native Windows
# binary -- so a POSIX path passed as an argument arrives unconverted and jq
# reports "Could not open file".  Verified on Windows 10 / Git Bash: with the
# path as an argument the read fails (exit 2); through stdin it succeeds.
jq -er --arg task_id "$AGENTQ_SMOKE_TASK_ID" '.tasks[$task_id].status.Done.result' < "$status_path"
'@
        try {
            $resultOutput = @(Invoke-GitBashScript -GitBashPath $GitBashPath -Script $statusCommand -Login)
            $exitCode = $LASTEXITCODE
        } catch {
            $exitCode = 1
        }
        $temporaryItem = Get-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $temporaryItem) {
            $temporaryIdentity = Get-AgentQInstallerFileIdentity -Path $temporaryPath
        }
        if ($exitCode -ne 0) {
            throw "Pueue shell smoke task result could not be read: $TaskId"
        }
        Assert-NonReparseFilePath -Path $temporaryPath -Description "Pueue shell smoke status temporary file"
        if ([string]::IsNullOrWhiteSpace($temporaryIdentity)) {
            throw "Unable to record Pueue shell smoke status temporary file identity"
        }
        if ($resultOutput.Count -eq 0) {
            throw "Pueue shell smoke task result was empty: $TaskId"
        }

        $result = ([string]($resultOutput | Select-Object -Last 1)).Trim()
    } catch {
        $operationError = $_
    } finally {
        try {
            if (!(Remove-AgentQInstallerResponseTemporaryFile -Path $temporaryPath -ExpectedIdentity $temporaryIdentity -Description "Pueue shell smoke status temporary file")) {
                $cleanupError = "Pueue shell smoke status cleanup failed: $temporaryPath"
            }
        } catch {
            $cleanupError = "Pueue shell smoke status cleanup failed: $temporaryPath"
        }
        foreach ($name in $environmentValues.Keys) {
            if ($hadPreviousValues.ContainsKey($name) -and $hadPreviousValues[$name]) {
                [Environment]::SetEnvironmentVariable($name, $previousValues[$name], "Process")
            } elseif ($hadPreviousValues.ContainsKey($name)) {
                [Environment]::SetEnvironmentVariable($name, $null, "Process")
            }
        }
    }
    if ($null -ne $operationError) {
        if ($null -ne $cleanupError) {
            throw "$($operationError.Exception.Message); $cleanupError"
        }
        throw $operationError
    }
    if ($null -ne $cleanupError) {
        throw $cleanupError
    }
    return $result
}

function Assert-PueueSmokeLogContainsToken {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$TaskId,
        [string]$SmokeToken,
        [string]$TemporaryDirectory
    )

    $temporaryPath = $null
    $temporaryIdentity = $null
    $operationError = $null
    $cleanupError = $null
    try {
        $temporaryPath = New-AgentQInstallerTemporaryFile -Directory $TemporaryDirectory -Prefix "smoke-log"
        Assert-NonReparseFilePath -Path $temporaryPath -Description "Pueue shell smoke log temporary file"
        try {
            & $ClientPath --config $ConfigPath log --full $TaskId 1> $temporaryPath
            $exitCode = $LASTEXITCODE
        } catch {
            $exitCode = 1
        }
        $temporaryItem = Get-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $temporaryItem) {
            $temporaryIdentity = Get-AgentQInstallerFileIdentity -Path $temporaryPath
        }
        if ($exitCode -ne 0) {
            throw "Pueue shell smoke log could not be read: $TaskId"
        }
        Assert-NonReparseFilePath -Path $temporaryPath -Description "Pueue shell smoke log temporary file"
        if ([string]::IsNullOrWhiteSpace($temporaryIdentity)) {
            throw "Unable to record Pueue shell smoke log temporary file identity"
        }
        if (!(Select-String -LiteralPath $temporaryPath -SimpleMatch -Pattern $SmokeToken -Quiet)) {
            throw "Pueue shell smoke output did not contain its sentinel: $TaskId"
        }
    } catch {
        $operationError = $_
    } finally {
        try {
            if (!(Remove-AgentQInstallerResponseTemporaryFile -Path $temporaryPath -ExpectedIdentity $temporaryIdentity -Description "Pueue shell smoke log temporary file")) {
                $cleanupError = "Pueue shell smoke log cleanup failed: $temporaryPath"
            }
        } catch {
            $cleanupError = "Pueue shell smoke log cleanup failed: $temporaryPath"
        }
    }
    if ($null -ne $operationError) {
        if ($null -ne $cleanupError) {
            throw "$($operationError.Exception.Message); $cleanupError"
        }
        throw $operationError
    }
    if ($null -ne $cleanupError) {
        throw $cleanupError
    }
}

function Invoke-PueueShellCommandSmoke {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$WorkingDirectory,
        [string]$GitBashPath
    )

    $smokeToken = "agentq-install-smoke-$PID-$([Guid]::NewGuid().ToString('N'))"
    $smokeLabel = "agentq-installer-$PID"
    $taskId = $null
    $taskRemoved = $false
    $smokeFailure = $null
    $cleanupFailure = $null

    try {
        $addArguments = @(
            "--config", $ConfigPath,
            "add",
            "--group", "agentq",
            "--working-directory", $WorkingDirectory,
            "--label", $smokeLabel,
            "--print-task-id",
            "--escape",
            "--",
            "printf", "%s\n", $smokeToken
        )
        $taskIdOutput = @(& $ClientPath @addArguments)
        if ($LASTEXITCODE -ne 0) {
            throw "Pueue shell smoke task could not be submitted"
        }

        $taskId = ([string]($taskIdOutput | Select-Object -Last 1)).Trim()
        if ($taskId -notmatch '^[0-9]+$') {
            throw "Pueue shell smoke returned an invalid task id: $taskId"
        }

        & $ClientPath --config $ConfigPath wait --quiet $taskId 1> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Pueue shell smoke task failed: $taskId"
        }

        $taskResult = Get-PueueTaskResult -ClientPath $ClientPath -ConfigPath $ConfigPath -TaskId $taskId -GitBashPath $GitBashPath -TemporaryDirectory (Join-Path $WorkingDirectory "runtime")
        if ($taskResult -ne "Success") {
            throw "Pueue shell smoke task did not finish successfully: $taskId"
        }

        Assert-PueueSmokeLogContainsToken -ClientPath $ClientPath -ConfigPath $ConfigPath -TaskId $taskId -SmokeToken $smokeToken -TemporaryDirectory (Join-Path $WorkingDirectory "runtime")
    } catch {
        $smokeFailure = $_.Exception
    }

    if ($null -ne $taskId) {
        try {
            & $ClientPath --config $ConfigPath remove $taskId 1> $null
            if ($LASTEXITCODE -ne 0) {
                throw "Pueue shell smoke task cleanup failed: $taskId"
            }
            $taskRemoved = $true
        } catch {
            $cleanupFailure = $_.Exception
        }
    }

    if ($null -ne $smokeFailure) {
        if ($null -ne $cleanupFailure) {
            throw "$($smokeFailure.Message); $($cleanupFailure.Message)"
        }
        throw $smokeFailure
    }
    if ($null -ne $cleanupFailure) {
        throw $cleanupFailure
    }
    if (!$taskRemoved) {
        throw "Pueue shell smoke task was not cleaned up"
    }
}

function Invoke-AgentQLauncherSmoke {
    param(
        [string]$LauncherPath,
        [switch]$ExpectMaintenanceRejection
    )

    $launcherItem = Get-Item -LiteralPath $LauncherPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $launcherItem) {
        if (Test-NonReparseFilePath -Path $LauncherPath -AllowMissing) {
            throw "AgentQ launcher smoke path is missing: $LauncherPath"
        }
        throw "AgentQ launcher smoke path must be a regular non-reparse path: $LauncherPath"
    }
    if ($launcherItem.PSIsContainer) {
        throw "AgentQ launcher smoke path is not a regular file: $LauncherPath"
    }
    Assert-NonReparseFilePath -Path $LauncherPath -Description "AgentQ launcher smoke path"

    $payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("doctor`0"))
    $errorPath = $null
    $statusPath = $null
    $statusIdentity = $null
    $statusHasOutput = $false
    $status = $null
    $operationError = $null
    $cleanupErrors = [System.Collections.Generic.List[string]]::new()
    try {
        $errorPath = New-AgentQInstallerTemporaryFile -Directory ([System.IO.Path]::GetTempPath()) -Prefix "launcher-smoke"
        $statusPath = New-AgentQInstallerTemporaryFile -Directory ([System.IO.Path]::GetTempPath()) -Prefix "launcher-status"
        Assert-NonReparseFilePath -Path $errorPath -Description "AgentQ launcher smoke diagnostics"
        Assert-NonReparseFilePath -Path $statusPath -Description "AgentQ launcher smoke status"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            # The maintenance response intentionally exits nonzero and writes to stderr.
            # Capture it below instead of allowing PowerShell to promote it to a terminating error.
            $ErrorActionPreference = "Continue"
            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $LauncherPath -ArgumentsBase64 $payload 1> $statusPath 2> $errorPath
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        Assert-NonReparseFilePath -Path $errorPath -Description "AgentQ launcher smoke diagnostics"
        Assert-NonReparseFilePath -Path $statusPath -Description "AgentQ launcher smoke status"
        $statusIdentity = Get-AgentQInstallerFileIdentity -Path $statusPath
        $statusHasOutput = ((Get-Item -LiteralPath $statusPath -Force).Length -ne 0)
        if ($ExpectMaintenanceRejection) {
            $maintenanceMessage = "agentq: AgentQ maintenance is in progress; retry after the installer completes"
            $hasMaintenanceMessage = Select-String -LiteralPath $errorPath -SimpleMatch -Pattern $maintenanceMessage -Quiet
            if ($exitCode -ne 2) {
                throw "AgentQ launcher maintenance smoke returned unexpected exit code: $exitCode"
            }
            if ($statusHasOutput) {
                throw "AgentQ launcher maintenance smoke unexpectedly produced standard output"
            }
            if (!$hasMaintenanceMessage) {
                throw "AgentQ launcher maintenance smoke did not report the expected maintenance rejection"
            }
        } else {
            if ($exitCode -ne 0) {
                throw "AgentQ launcher smoke command failed with exit code: $exitCode"
            }

            $status = Read-AgentQInstallerJsonFile -Path $statusPath -Description "AgentQ launcher smoke"
            # StrictMode turns a missing property into a terminating error, so a
            # parsed payload must be reached through PSObject.Properties -- same
            # idiom as the staged health check above.
            $statusTasks = $null
            $statusAgentqGroup = $null
            if ($null -ne $status) {
                $tasksProperty = $status.PSObject.Properties["tasks"]
                if ($null -ne $tasksProperty) {
                    $statusTasks = $tasksProperty.Value
                }
                $groupsProperty = $status.PSObject.Properties["groups"]
                if ($null -ne $groupsProperty -and $null -ne $groupsProperty.Value) {
                    $agentqProperty = $groupsProperty.Value.PSObject.Properties["agentq"]
                    if ($null -ne $agentqProperty) {
                        $statusAgentqGroup = $agentqProperty.Value
                    }
                }
            }
            if ($null -eq $statusTasks -or $null -eq $statusAgentqGroup) {
                throw "AgentQ launcher smoke returned an invalid status payload"
            }
        }
    } catch {
        $operationError = $_
    } finally {
        if ($null -ne $errorPath) {
            try {
                if (!(Remove-AgentQInstallerTemporaryFile -Path $errorPath -Description "AgentQ launcher smoke diagnostics")) {
                    [void]$cleanupErrors.Add("AgentQ launcher smoke diagnostics cleanup failed: $errorPath")
                }
            } catch {
                [void]$cleanupErrors.Add("AgentQ launcher smoke diagnostics cleanup failed: $errorPath")
            }
        }
        if ($null -ne $statusPath) {
            try {
                if (!(Remove-AgentQInstallerResponseTemporaryFile -Path $statusPath -ExpectedIdentity $statusIdentity -Description "AgentQ launcher smoke status")) {
                    [void]$cleanupErrors.Add("AgentQ launcher smoke status cleanup failed: $statusPath")
                }
            } catch {
                [void]$cleanupErrors.Add("AgentQ launcher smoke status cleanup failed: $statusPath")
            }
        }
    }
    if ($null -ne $operationError) {
        if ($cleanupErrors.Count -gt 0) {
            throw "$($operationError.Exception.Message); $($cleanupErrors -join '; ')"
        }
        throw $operationError
    }
    if ($cleanupErrors.Count -gt 0) {
        throw ($cleanupErrors -join '; ')
    }
}

function Assert-PowerShellSyntax {
    param([string]$Path)

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if (($null -ne $parseErrors) -and ($parseErrors.Count -gt 0)) {
        $firstError = $parseErrors[0]
        throw "AgentQ PowerShell syntax check failed at $($firstError.Extent.StartLineNumber): $($firstError.Message)"
    }
}

function Download-VerifiedPueueBinary {
    param(
        [string]$DestinationPath,
        [string]$AssetName,
        [string]$ExpectedHash
    )

    $downloadUrl = "$releaseBaseUrl/$AssetName"
    Assert-NonReparseFilePath -Path $DestinationPath -Description "verified Pueue destination" -AllowMissing
    $destinationDirectory = Split-Path -Parent $DestinationPath
    $temporaryPath = New-AgentQInstallerTemporaryFile -Directory $destinationDirectory -Prefix "download" -CandidatePath "$DestinationPath.download.$PID"
    # A `throw` inside a `finally` REPLACES the in-flight exception and aborts
    # the rest of the block -- so an unconditional cleanup throw here would
    # mask the real failure (e.g. a checksum mismatch) behind "cleanup
    # failed".  Merge both errors instead, like the other sites in this file.
    $operationError = $null
    $cleanupError = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloadUrl -OutFile $temporaryPath -UseBasicParsing -TimeoutSec 300
        Assert-NonReparseFilePath -Path $temporaryPath -Description "verified Pueue temporary file"
        Assert-Sha256 -Path $temporaryPath -Expected $ExpectedHash
        Assert-NonReparseFilePath -Path $DestinationPath -Description "verified Pueue destination" -AllowMissing
        Move-Item -LiteralPath $temporaryPath -Destination $DestinationPath -Force
    } catch {
        $operationError = $_
    } finally {
        if (!(Remove-AgentQInstallerTemporaryFile -Path $temporaryPath -Description "verified Pueue temporary file")) {
            $cleanupError = "verified Pueue temporary cleanup failed: $temporaryPath"
        }
    }
    if ($null -ne $operationError) {
        if ($null -ne $cleanupError) {
            throw "$($operationError.Exception.Message); $cleanupError"
        }
        throw $operationError
    }
    if ($null -ne $cleanupError) {
        throw $cleanupError
    }
}

function Install-StageAsset {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    Assert-NonReparseFilePath -Path $SourcePath -Description "staged asset source"
    Assert-NonReparseFilePath -Path $DestinationPath -Description "staged asset destination" -AllowMissing
    $destinationDirectory = Split-Path -Parent $DestinationPath
    $temporaryPath = New-AgentQInstallerTemporaryFile -Directory $destinationDirectory -Prefix "stage" -CandidatePath "$DestinationPath.new.$PID"
    # A `throw` inside a `finally` REPLACES the in-flight exception and aborts
    # the rest of the block -- so an unconditional cleanup throw here would
    # mask the real failure (e.g. a checksum mismatch) behind "cleanup
    # failed".  Merge both errors instead, like the other sites in this file.
    $operationError = $null
    $cleanupError = $null
    try {
        Copy-Item -LiteralPath $SourcePath -Destination $temporaryPath -Force
        Assert-NonReparseFilePath -Path $temporaryPath -Description "staged asset temporary file"
        Assert-NonReparseFilePath -Path $DestinationPath -Description "staged asset destination" -AllowMissing
        Move-Item -LiteralPath $temporaryPath -Destination $DestinationPath -Force
    } catch {
        $operationError = $_
    } finally {
        if (!(Remove-AgentQInstallerTemporaryFile -Path $temporaryPath -Description "staged asset temporary file")) {
            $cleanupError = "staged asset temporary cleanup failed: $temporaryPath"
        }
    }
    if ($null -ne $operationError) {
        if ($null -ne $cleanupError) {
            throw "$($operationError.Exception.Message); $cleanupError"
        }
        throw $operationError
    }
    if ($null -ne $cleanupError) {
        throw $cleanupError
    }
}

function Copy-VerifiedPueueBinary {
    param(
        [string]$DestinationPath,
        [string]$AssetName,
        [string]$ExpectedHash,
        [string]$ExistingPath
    )

    $stageBinaryPath = Join-Path $StageDirectory $AssetName
    $stageBinaryItem = Get-Item -LiteralPath $stageBinaryPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $stageBinaryItem) {
        Assert-NonReparseFilePath -Path $stageBinaryPath -Description "staged Pueue binary source"
        Assert-Sha256 -Path $stageBinaryPath -Expected $ExpectedHash
        Install-StageAsset -SourcePath $stageBinaryPath -DestinationPath $DestinationPath
        return
    }

    $existingBinaryItem = Get-Item -LiteralPath $ExistingPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existingBinaryItem) {
        Assert-NonReparseFilePath -Path $ExistingPath -Description "existing Pueue binary source"
        try {
            Assert-Sha256 -Path $ExistingPath -Expected $ExpectedHash
            Install-StageAsset -SourcePath $ExistingPath -DestinationPath $DestinationPath
            return
        } catch {
        }
    }

    Download-VerifiedPueueBinary -DestinationPath $DestinationPath -AssetName $AssetName -ExpectedHash $ExpectedHash
}

function Set-AgentQStartupTask {
    param([string]$StartupPath)

    Assert-NonReparseFilePath -Path $StartupPath -Description "AgentQ startup launcher" -AllowMissing
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$StartupPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentIdentity
    $principal = New-ScheduledTaskPrincipal -UserId $currentIdentity -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
}

function Get-ScheduledTaskDefinition {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return $null
    }
    return (Export-ScheduledTask -TaskName $taskName)
}

function Restore-ScheduledTaskDefinition {
    param([AllowNull()][string]$Definition)

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    # A `[string]` parameter coerces $null to "", so `$null -ne $Definition` is
    # true for the first-install case where no previous task existed -- and
    # Register-ScheduledTask then rejects the empty Xml.  Test for empty, not
    # for null.  Verified on Windows 10 / PS 5.1: a [AllowNull()][string] bound
    # to $null reports isNull=False / isNullOrEmpty=True.
    if (![string]::IsNullOrWhiteSpace($Definition)) {
        Register-ScheduledTask -TaskName $taskName -Xml $Definition | Out-Null
    }
}

function Invoke-BashSyntaxCheck {
    param([string]$Path)

    $environmentVariable = "AGENTQ_SYNTAX_PATH"
    $environmentPath = "Env:$environmentVariable"
    $hadPreviousValue = Test-Path -LiteralPath $environmentPath
    $previousValue = [Environment]::GetEnvironmentVariable($environmentVariable, "Process")

    try {
        [Environment]::SetEnvironmentVariable($environmentVariable, $Path, "Process")
        $syntaxCommand = 'script_path=$(cygpath -u -- "$AGENTQ_SYNTAX_PATH") || exit 2; bash -n -- "$script_path"'
        Invoke-GitBashScript -GitBashPath $gitBashPath -Script $syntaxCommand -Login
        if ($LASTEXITCODE -ne 0) {
            throw "AgentQ server shell syntax check failed: $Path"
        }
    } finally {
        if ($hadPreviousValue) {
            [Environment]::SetEnvironmentVariable($environmentVariable, $previousValue, "Process")
        } else {
            [Environment]::SetEnvironmentVariable($environmentVariable, $null, "Process")
        }
    }
}

function Get-GitBashMissingRuntimeDependencies {
    $probeCommand = 'for dependency in jq base64 date find grep mktemp tail tr cygpath ps powershell.exe; do command -v "$dependency" >/dev/null 2>&1 || printf "%s\n" "$dependency"; done'
    $output = @(Invoke-GitBashScript -GitBashPath $gitBashPath -Script $probeCommand -Login)
    if ($LASTEXITCODE -ne 0) {
        throw "Git Bash runtime dependency probe failed"
    }

    return @(
        $output |
            ForEach-Object { $_.ToString().Trim() } |
            Where-Object { $_ -ne "" }
    )
}

function Add-CurrentProcessPathEntry {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    $pathItem = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $pathItem) {
        return
    }
    if (!$pathItem.PSIsContainer) {
        if (($pathItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Assert-NonReparseDirectoryPath -Path $Path -Description "current process PATH entry"
        }
        return
    }
    Assert-NonReparseDirectoryPath -Path $Path -Description "current process PATH entry"

    $entries = @($env:Path -split ';' | Where-Object { $_ -ne "" })
    if ($entries -notcontains $Path) {
        $env:Path = [string]::Join(';', @($entries + $Path))
    }
}

function Install-GitBashJq {
    if (Get-Command jq.exe -ErrorAction SilentlyContinue) {
        return
    }

    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        Write-Host "AgentQ is installing missing Git Bash dependency jq with winget"
        & winget.exe install --id jqlang.jq --exact --accept-source-agreements --accept-package-agreements --disable-interactivity
    } elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Host "AgentQ is installing missing Git Bash dependency jq with scoop"
        & scoop install jq
    } elseif (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        Write-Host "AgentQ is installing missing Git Bash dependency jq with Chocolatey"
        & choco.exe install jq --yes --no-progress
    } else {
        throw "Git Bash is missing jq and no supported Windows package manager is available"
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install missing Git Bash dependency jq"
    }

    Add-CurrentProcessPathEntry -Path (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links")
    Add-CurrentProcessPathEntry -Path (Join-Path $env:ProgramData "chocolatey\bin")
    Add-CurrentProcessPathEntry -Path (Join-Path $env:USERPROFILE "scoop\shims")
}

function Ensure-GitBashRuntimeDependencies {
    $missing = @(Get-GitBashMissingRuntimeDependencies)
    if ($missing.Count -eq 0) {
        return
    }

    $unsupported = @($missing | Where-Object { $_ -ne "jq" })
    if ($unsupported.Count -gt 0) {
        throw "Git Bash is missing built-in AgentQ runtime dependencies: $($unsupported -join ', ')"
    }

    Install-GitBashJq
    $remaining = @(Get-GitBashMissingRuntimeDependencies)
    if ($remaining.Count -gt 0) {
        throw "Git Bash is missing AgentQ runtime dependencies after jq installation: $($remaining -join ', ')"
    }
}

function Restore-LegacyDaemon {
    $legacyConfigItem = Get-Item -LiteralPath $legacyConfigPath -Force -ErrorAction SilentlyContinue
    $legacyClientItem = Get-Item -LiteralPath $legacyClientPath -Force -ErrorAction SilentlyContinue
    if (($null -eq $legacyConfigItem) -or ($null -eq $legacyClientItem)) {
        return
    }

    foreach ($path in @($legacyClientPath, $legacyConfigPath)) {
        Assert-NonReparseFilePath -Path $path -Description "legacy AgentQ endpoint path"
    }
    $legacyStartupItem = Get-Item -LiteralPath $legacyStartupPath -Force -ErrorAction SilentlyContinue
    $legacyDaemonItem = Get-Item -LiteralPath $legacyDaemonPath -Force -ErrorAction SilentlyContinue
    $hasLegacyStartupPath = $null -ne $legacyStartupItem
    $hasLegacyDaemonPath = $null -ne $legacyDaemonItem
    if ($hasLegacyStartupPath) {
        Assert-NonReparseFilePath -Path $legacyStartupPath -Description "legacy AgentQ startup launcher"
    }
    if ($hasLegacyDaemonPath) {
        Assert-NonReparseFilePath -Path $legacyDaemonPath -Description "legacy AgentQ daemon binary"
    }

    if (Test-PueueConnection -ClientPath $legacyClientPath -ConfigPath $legacyConfigPath) {
        if (Test-ManagedPueueProcess -DaemonPath $legacyDaemonPath) {
            return
        }
        throw "Legacy AgentQ endpoint is reachable but is not served by the expected daemon: $legacyDaemonPath"
    }

    if ($hasLegacyStartupPath) {
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $legacyStartupPath 1> $null 2> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to restore the legacy AgentQ Pueue daemon"
        }
        Wait-ForDaemon -ClientPath $legacyClientPath -ConfigPath $legacyConfigPath -DaemonPath $legacyDaemonPath
        return
    }
    if ($hasLegacyDaemonPath) {
        Start-Process -FilePath $legacyDaemonPath -ArgumentList @("--config", $legacyConfigPath) -WindowStyle Hidden | Out-Null
        Wait-ForDaemon -ClientPath $legacyClientPath -ConfigPath $legacyConfigPath -DaemonPath $legacyDaemonPath
        return
    }

    throw "Legacy AgentQ deployment cannot be restored because no daemon launcher is available"
}

function Move-LegacyArtifact {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    $sourceItem = Get-Item -LiteralPath $SourcePath -Force -ErrorAction SilentlyContinue
    if ($null -ne $sourceItem) {
        $destinationParent = Split-Path -Parent $DestinationPath
        Assert-NonReparseArtifactPath -Path $SourcePath -Description "legacy artifact source"
        Assert-NonReparseArtifactPath -Path $destinationParent -Description "legacy artifact destination parent" -AllowMissing
        [System.IO.Directory]::CreateDirectory($destinationParent) | Out-Null
        Assert-NonReparseArtifactPath -Path $destinationParent -Description "legacy artifact destination parent"
        Assert-NonReparseArtifactPath -Path $DestinationPath -Description "legacy artifact destination" -AllowMissing
        Move-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
        Assert-NonReparseArtifactPath -Path $DestinationPath -Description "legacy artifact destination"
        [void]$legacyMovedArtifacts.Add([pscustomobject]@{
            Source = $SourcePath
            Destination = $DestinationPath
        })
    }
}

function Restore-MovedLegacyArtifacts {
    foreach ($artifact in @($legacyMovedArtifacts | Sort-Object { $_.Destination.Length } -Descending)) {
        $destinationItem = Get-Item -LiteralPath $artifact.Destination -Force -ErrorAction SilentlyContinue
        if ($null -eq $destinationItem) {
            if (Test-NonReparseArtifactPath -Path $artifact.Destination -AllowMissing) {
                throw "Legacy AgentQ artifact is missing during rollback: $($artifact.Destination)"
            }
            throw "Legacy AgentQ artifact is unsafe during rollback: $($artifact.Destination)"
        }

        Assert-NonReparseArtifactPath -Path $artifact.Destination -Description "legacy rollback destination"
        $sourceItem = Get-Item -LiteralPath $artifact.Source -Force -ErrorAction SilentlyContinue
        if ($null -ne $sourceItem) {
            Assert-NonReparseArtifactPath -Path $artifact.Source -Description "legacy rollback source"
            throw "Legacy AgentQ source path unexpectedly exists during rollback: $($artifact.Source)"
        }
        if (!(Test-NonReparseArtifactPath -Path $artifact.Source -AllowMissing)) {
            throw "Legacy AgentQ source path is unsafe during rollback: $($artifact.Source)"
        }
        $sourceParent = Split-Path -Parent $artifact.Source
        Assert-NonReparseArtifactPath -Path $sourceParent -Description "legacy rollback source parent" -AllowMissing
        [System.IO.Directory]::CreateDirectory($sourceParent) | Out-Null
        Assert-NonReparseArtifactPath -Path $sourceParent -Description "legacy rollback source parent"
        Assert-NonReparseArtifactPath -Path $artifact.Source -Description "legacy rollback source" -AllowMissing
        Move-Item -LiteralPath $artifact.Destination -Destination $artifact.Source
        Assert-NonReparseArtifactPath -Path $artifact.Source -Description "legacy rollback source"
    }
    $legacyMovedArtifacts.Clear()
}

function Copy-AgentQData {
    param(
        [string]$SourceDirectory,
        [string]$DestinationDirectory
    )

    Assert-NonReparseArtifactPath -Path $SourceDirectory -Description "AgentQ data source" -AllowMissing
    $sourceItem = Get-Item -LiteralPath $SourceDirectory -Force -ErrorAction SilentlyContinue
    if ($null -eq $sourceItem) {
        return
    }
    Assert-NonReparseDirectoryPath -Path $SourceDirectory -Description "AgentQ data source"
    Assert-NonReparseDirectoryPath -Path $DestinationDirectory -Description "AgentQ data destination"
    [void]@(Get-PrivateTreeItems -Path $SourceDirectory)
    [void]@(Get-PrivateTreeItems -Path $DestinationDirectory)
    foreach ($item in @(Get-ChildItem -LiteralPath $SourceDirectory -Force)) {
        $destinationItem = Join-Path $DestinationDirectory $item.Name
        Assert-NonReparseArtifactPath -Path $destinationItem -Description "AgentQ data destination item" -AllowMissing
        Copy-Item -LiteralPath $item.FullName -Destination $DestinationDirectory -Recurse -Force
        Assert-NonReparseArtifactPath -Path $destinationItem -Description "AgentQ data destination item"
    }
    [void]@(Get-PrivateTreeItems -Path $DestinationDirectory)
}

function Remove-SafeTransactionDirectory {
    param(
        [string]$Path,
        [string]$Description
    )

    $pathItem = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $pathItem) {
        return $true
    }
    if (!(Test-NonReparseDirectoryPath -Path $Path)) {
        [Console]::Error.WriteLine("AgentQ $Description is not a safe regular directory; preserving it: $Path")
        return $false
    }
    try {
        [void]@(Get-PrivateTreeItems -Path $Path)
        Assert-NonReparseDirectoryPath -Path $Path -Description $Description
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        [Console]::Error.WriteLine("AgentQ $Description cleanup was not safe; preserving it: $Path")
        return $false
    }
    $remaining = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -ne $remaining) {
        [Console]::Error.WriteLine("AgentQ $Description remained after cleanup; preserving it: $Path")
        return $false
    }
    return $true
}

function Get-ProcessIdentityState {
    param([string]$ProcessId)

    if ($ProcessId -notmatch '^[1-9][0-9]*$') {
        return $null
    }

    try {
        $process = Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue
    } catch {
        return $null
    }
    if ($null -eq $process) {
        return "dead"
    }

    try {
        $identity = $process.StartTime.ToUniversalTime().Ticks
    } catch {
        return $null
    }
    if ($identity -le 0) {
        return $null
    }

    return "alive:$identity"
}

function Get-CurrentProcessIdentity {
    $state = Get-ProcessIdentityState -ProcessId ([string]$PID)
    if ($state -notlike "alive:*") {
        throw "Unable to determine the current PowerShell process identity"
    }

    return $state.Substring(6)
}

function Test-ProcessIsConfirmedDead {
    param(
        [string]$ProcessId,
        [string]$ExpectedIdentity
    )

    $state = Get-ProcessIdentityState -ProcessId $ProcessId
    if ($state -eq "dead") {
        return $true
    }
    if ([string]::IsNullOrEmpty($ExpectedIdentity) -or $state -notlike "alive:*") {
        return $false
    }

    return $state.Substring(6) -ne $ExpectedIdentity
}

function Test-NonReparseLockPath {
    param(
        [string]$Path,
        [switch]$AllowMissing,
        [switch]$RequireContainer
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    if (!(Test-NonReparseFilePath -Path $Path -AllowMissing:$AllowMissing)) {
        return $false
    }

    if ($RequireContainer) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            return [bool]$AllowMissing
        }
        if (!$item.PSIsContainer) {
            return $false
        }
    }

    return $true
}

function Read-LockMetadata {
    param([string]$Path)

    if (!(Test-NonReparseLockPath -Path $Path)) {
        return $null
    }

    try {
        $maximumMetadataBytes = 4096
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        try {
            $buffer = [byte[]]::new($maximumMetadataBytes + 1)
            $offset = 0
            while ($offset -lt $buffer.Length) {
                $readCount = $stream.Read($buffer, $offset, $buffer.Length - $offset)
                if ($readCount -eq 0) {
                    break
                }
                $offset += $readCount
            }
            if ($offset -gt $maximumMetadataBytes) {
                return $null
            }
            $contents = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $offset).TrimEnd([char[]]"`r`n")
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $null
    }

    $parts = $contents -split "`t", 2
    if ($parts.Count -eq 0 -or $parts[0] -notmatch '^[1-9][0-9]*$') {
        return $null
    }

    return [pscustomobject]@{
        Pid = $parts[0]
        Identity = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    }
}

function Test-LockOwnedByCurrentProcess {
    param([string]$Path)

    $metadata = Read-LockMetadata -Path $Path
    if ($null -eq $metadata -or $metadata.Pid -ne ([string]$PID) -or [string]::IsNullOrEmpty($metadata.Identity)) {
        return $false
    }

    try {
        $currentIdentity = Get-CurrentProcessIdentity
    } catch {
        return $false
    }
    return $metadata.Identity -eq $currentIdentity
}

function Release-MaintenanceLock {
    if ($script:maintenanceLockHeld -and (Test-NonReparseLockPath -Path $maintenanceLockDirectory) -and (Test-LockOwnedByCurrentProcess -Path $maintenanceLockDirectory)) {
        if (!(Remove-AgentQInstallerTemporaryFile -Path $maintenanceLockDirectory -Description "AgentQ maintenance lock")) {
            throw "failed to remove AgentQ maintenance lock: $maintenanceLockDirectory"
        }
    }
    $script:maintenanceLockHeld = $false
}

function Remove-StaleMaintenanceLock {
    $lockItem = $null
    try {
        $lockItem = Get-Item -LiteralPath $maintenanceLockDirectory -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        return $true
    } catch {
        return $false
    }

    if (!(Test-NonReparseLockPath -Path $maintenanceLockDirectory) -or $lockItem.PSIsContainer) {
        return $false
    }

    $lockMetadata = Read-LockMetadata -Path $maintenanceLockDirectory

    if ($null -eq $lockMetadata) {
        return $false
    }

    if (!(Test-ProcessIsConfirmedDead -ProcessId $lockMetadata.Pid -ExpectedIdentity $lockMetadata.Identity)) {
        return $false
    }

    if (!(Test-NonReparseLockPath -Path $maintenanceLockDirectory)) {
        return $false
    }

    return (Remove-AgentQInstallerTemporaryFile -Path $maintenanceLockDirectory -Description "stale AgentQ maintenance lock")
}

function Acquire-MaintenanceLock {
    if (!(Test-NonReparseLockPath -Path $maintenanceLockDirectory -AllowMissing)) {
        throw "invalid AgentQ maintenance lock path: $maintenanceLockDirectory"
    }

    for ($attempt = 0; $attempt -lt 2; $attempt += 1) {
        if (!(Test-NonReparseLockPath -Path $maintenanceLockDirectory -AllowMissing)) {
            throw "invalid AgentQ maintenance lock path: $maintenanceLockDirectory"
        }
        $stream = $null
        $writer = $null
        $temporaryPath = "$maintenanceLockDirectory.new.$PID.$([Guid]::NewGuid().ToString('N'))"
        $temporaryCreated = $false
        $moveAttempted = $false
        try {
            Assert-NonReparseFilePath -Path $temporaryPath -Description "AgentQ maintenance lock temporary file" -AllowMissing
            $stream = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $temporaryCreated = $true
            Assert-NonReparseFilePath -Path $temporaryPath -Description "AgentQ maintenance lock temporary file"
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::ASCII)
            $currentProcessIdentity = Get-CurrentProcessIdentity
            $writer.WriteLine("$PID`t$currentProcessIdentity")
            $writer.Flush()
            $stream.Flush($true)
            $writer.Dispose()
            $writer = $null
            $stream = $null
            $moveAttempted = $true
            [System.IO.File]::Move($temporaryPath, $maintenanceLockDirectory)
            $temporaryPath = $null
            $script:maintenanceLockHeld = $true
            return
        } catch {
            if ($null -ne $writer) {
                $writer.Dispose()
            } elseif ($null -ne $stream) {
                $stream.Dispose()
            }
            if ($temporaryCreated -and $null -ne $temporaryPath) {
                if (!(Remove-AgentQInstallerTemporaryFile -Path $temporaryPath -Description "AgentQ maintenance lock temporary file")) {
                    throw "failed to remove AgentQ maintenance lock temporary file: $temporaryPath"
                }
            }
            if (!$moveAttempted) {
                throw "failed to initialize the AgentQ maintenance lock: $maintenanceLockDirectory"
            }
            if (Remove-StaleMaintenanceLock) {
                continue
            }
            throw "AgentQ maintenance is already in progress: $maintenanceLockDirectory"
        }
    }

    throw "AgentQ maintenance is already in progress: $maintenanceLockDirectory"
}

function Wait-ForAgentQOperationLock {
    param([string]$RuntimeDirectory)

    $operationLockDirectory = Join-Path $RuntimeDirectory "agentq-operation.lock"
    if (!(Test-NonReparseLockPath -Path $RuntimeDirectory -RequireContainer)) {
        throw "invalid AgentQ operation lock parent path: $RuntimeDirectory"
    }
    for ($attempt = 0; $attempt -lt 30; $attempt += 1) {
        $operationLockItem = Get-Item -LiteralPath $operationLockDirectory -Force -ErrorAction SilentlyContinue
        if ($null -eq $operationLockItem) {
            return
        }
        if (!(Test-NonReparseLockPath -Path $operationLockDirectory -RequireContainer)) {
            throw "invalid AgentQ operation lock path: $operationLockDirectory"
        }
        $metadata = Read-LockMetadata -Path (Join-Path $operationLockDirectory "pid")
        if ($null -ne $metadata -and (Test-ProcessIsConfirmedDead -ProcessId $metadata.Pid -ExpectedIdentity $metadata.Identity)) {
            if (!(Test-NonReparseLockPath -Path $operationLockDirectory -RequireContainer)) {
                throw "invalid AgentQ operation lock path: $operationLockDirectory"
            }
            try {
                Remove-Item -LiteralPath $operationLockDirectory -Recurse -Force -ErrorAction Stop
            } catch {
            }
            $operationLockItem = Get-Item -LiteralPath $operationLockDirectory -Force -ErrorAction SilentlyContinue
            if ($null -eq $operationLockItem) {
                continue
            }
        }
        Start-Sleep -Seconds 1
    }
    throw "AgentQ request is still in progress; refusing to update: $operationLockDirectory"
}

function Invoke-RollbackStep {
    param(
        [string]$Description,
        [scriptblock]$Action
    )

    try {
        & $Action | Out-Null
        return $true
    } catch {
        [void]$rollbackFailures.Add("${Description}: $($_.Exception.Message)")
        return $false
    }
}

function Test-PueueDaemonStopped {
    param(
        [string]$ClientPath,
        [string]$ConfigPath,
        [string]$DaemonPath
    )

    return (!(Test-PueueConnection -ClientPath $ClientPath -ConfigPath $ConfigPath) -and !(Test-ManagedPueueProcess -DaemonPath $DaemonPath))
}

function Restore-Transaction {
    if (!$script:transactionActive -or $script:rollbackRunning) {
        return [pscustomobject]@{
            Succeeded = $true
            Errors = @()
        }
    }

    $script:rollbackRunning = $true
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Stop"
    $canRestore = $true
    [Console]::Error.WriteLine("AgentQ installation failed; restoring the previous deployment")

    try {
        if ($candidateInstalled) {
            $candidateClientPath = Join-Path $rootDirectory "pueue.exe"
            $candidateConfigPath = Join-Path $rootDirectory "config\pueue.yml"
            $candidateDaemonPath = Join-Path $rootDirectory "pueued.exe"
            $candidateRootItem = Get-Item -LiteralPath $rootDirectory -Force -ErrorAction SilentlyContinue
            if ($null -ne $candidateRootItem) {
                if (!(Invoke-RollbackStep -Description "failed to stop the candidate AgentQ daemon" -Action {
                            Assert-NonReparseDirectoryPath -Path $rootDirectory -Description "candidate AgentQ root"
                            Stop-PueueDaemon -ClientPath $candidateClientPath -ConfigPath $candidateConfigPath -DaemonPath $candidateDaemonPath
                        })) {
                    $canRestore = $false
                }
            }
            if ($canRestore -and !(Test-PueueDaemonStopped -ClientPath $candidateClientPath -ConfigPath $candidateConfigPath -DaemonPath $candidateDaemonPath)) {
                [void]$rollbackFailures.Add("candidate AgentQ daemon is still reachable or running: $candidateDaemonPath")
                $canRestore = $false
            }
        }

        if ($canRestore -and $legacyMovedArtifacts.Count -gt 0) {
            if (!(Invoke-RollbackStep -Description "failed to restore migrated legacy AgentQ artifacts" -Action {
                        Restore-MovedLegacyArtifacts
                    })) {
                $canRestore = $false
            }
        }

        $candidateRootItem = Get-Item -LiteralPath $rootDirectory -Force -ErrorAction SilentlyContinue
        if ($canRestore -and $candidateInstalled -and ($null -ne $candidateRootItem)) {
            if (!(Invoke-RollbackStep -Description "failed to isolate the candidate AgentQ root" -Action {
                        Assert-NonReparseDirectoryPath -Path $rootDirectory -Description "candidate AgentQ root"
                        Assert-NonReparseArtifactPath -Path $failedRootDirectory -Description "failed AgentQ root" -AllowMissing
                        $failedRootItem = Get-Item -LiteralPath $failedRootDirectory -Force -ErrorAction SilentlyContinue
                        if ($null -ne $failedRootItem) {
                            throw "AgentQ transaction path already exists: $failedRootDirectory"
                        }
                        Move-Item -LiteralPath $rootDirectory -Destination $failedRootDirectory -Force
                        Assert-NonReparseDirectoryPath -Path $failedRootDirectory -Description "failed AgentQ root"
                    })) {
                $canRestore = $false
            }
        }

        if ($canRestore -and $previousRootMoved) {
            $backupRootItem = Get-Item -LiteralPath $backupRootDirectory -Force -ErrorAction SilentlyContinue
            if ($null -eq $backupRootItem) {
                [void]$rollbackFailures.Add("previous AgentQ root is missing from backup: $backupRootDirectory")
                $canRestore = $false
            } elseif (!(Invoke-RollbackStep -Description "failed to restore the previous AgentQ root" -Action {
                            Assert-NonReparseDirectoryPath -Path $backupRootDirectory -Description "backup AgentQ root"
                            Assert-NonReparseArtifactPath -Path $rootDirectory -Description "AgentQ root" -AllowMissing
                            $restoredRootItem = Get-Item -LiteralPath $rootDirectory -Force -ErrorAction SilentlyContinue
                            if ($null -ne $restoredRootItem) {
                                throw "AgentQ transaction path already exists: $rootDirectory"
                            }
                            Move-Item -LiteralPath $backupRootDirectory -Destination $rootDirectory -Force
                            Assert-NonReparseDirectoryPath -Path $rootDirectory -Description "restored AgentQ root"
                        })) {
                $canRestore = $false
            }
        }

        if ($canRestore) {
            if (!(Invoke-RollbackStep -Description "failed to restore the previous AgentQ startup task" -Action {
                        Restore-ScheduledTaskDefinition -Definition $previousTask
                    })) {
                $canRestore = $false
            }
        }

        if ($canRestore -and ($previousRootMoved -or $previousDaemonStopped -or $previousDaemonStopAttempted)) {
            $restoredClientPath = Join-Path $rootDirectory "pueue.exe"
            $restoredConfigPath = Join-Path $rootDirectory "config\pueue.yml"
            $restoredStartupPath = Join-Path $rootDirectory "agentq-start-daemon.ps1"
            $restoredDaemonPath = Join-Path $rootDirectory "pueued.exe"
            $restoredStartupItem = Get-Item -LiteralPath $restoredStartupPath -Force -ErrorAction SilentlyContinue
            $restoredClientItem = Get-Item -LiteralPath $restoredClientPath -Force -ErrorAction SilentlyContinue
            $restoredDaemonItem = Get-Item -LiteralPath $restoredDaemonPath -Force -ErrorAction SilentlyContinue
            if (($null -ne $restoredStartupItem) -and ($null -ne $restoredClientItem) -and ($null -ne $restoredDaemonItem)) {
                if (!(Invoke-RollbackStep -Description "failed to restart the previous AgentQ daemon" -Action {
                            Start-PueueDaemon -StartupPath $restoredStartupPath -ClientPath $restoredClientPath -ConfigPath $restoredConfigPath -DaemonPath $restoredDaemonPath
                        })) {
                    $canRestore = $false
                }
            } else {
                [void]$rollbackFailures.Add("previous AgentQ root is incomplete after rollback: $rootDirectory")
                $canRestore = $false
            }
        } elseif ($canRestore -and ($legacyDaemonStopped -or $legacyDaemonStopAttempted)) {
            if (!(Invoke-RollbackStep -Description "failed to restart the legacy AgentQ daemon" -Action {
                        Restore-LegacyDaemon
                    })) {
                $canRestore = $false
            }
        }
    } catch {
        [void]$rollbackFailures.Add("rollback controller failed: $($_.Exception.Message)")
        $canRestore = $false
    } finally {
        if (!$canRestore) {
            $script:preserveRecoveryArtifacts = $true
        }
        $script:transactionActive = $false
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        Succeeded = ($canRestore -and ($rollbackFailures.Count -eq 0))
        Errors = @($rollbackFailures)
    }
}

$gitBashPaths = Resolve-GitBashPaths
$gitBashPath = $gitBashPaths.LauncherPath
$gitBashRuntimePath = $gitBashPaths.RuntimePath
$gitBashMsystem = Resolve-GitBashMsystem -GitBashPath $gitBashPath
$env:MSYSTEM = $gitBashMsystem
$env:MSYS_NO_PATHCONV = "1"

Require-Path -Path $StageDirectory
Require-Path -Path $gitBashPath
Require-Path -Path $gitBashRuntimePath
foreach ($path in @(
    (Join-Path $StageDirectory "agentq"),
    (Join-Path $StageDirectory "agentq-launcher.ps1"),
    (Join-Path $StageDirectory "agentq-start-daemon.ps1"),
    (Join-Path $StageDirectory "agentq-durable-move.ps1"),
    (Join-Path $StageDirectory "pueue.yml")
)) {
    Require-Path -Path $path
}

$configDirectory = Join-Path $rootDirectory "config"
$dataDirectory = Join-Path $rootDirectory "data"
$runtimeDirectory = Join-Path $rootDirectory "runtime"
$newClientPath = Join-Path $rootDirectory "pueue.exe"
$newDaemonPath = Join-Path $rootDirectory "pueued.exe"
$newConfigPath = Join-Path $configDirectory "pueue.yml"
$newLauncherPath = Join-Path $rootDirectory "agentq-launcher.ps1"
$newStartupPath = Join-Path $rootDirectory "agentq-start-daemon.ps1"

$existingRootItem = Get-Item -LiteralPath $rootDirectory -Force -ErrorAction SilentlyContinue
if (($null -ne $existingRootItem) -and !$existingRootItem.PSIsContainer) {
    throw "Existing AgentQ root is not a directory: $rootDirectory"
}
if ($null -ne $existingRootItem) {
    Assert-NonReparseDirectoryPath -Path $rootDirectory -Description "existing AgentQ root"
    foreach ($path in @($newClientPath, $newDaemonPath, $newConfigPath, $newStartupPath)) {
        Require-Path -Path $path
    }
    Assert-Sha256 -Path $newClientPath -Expected $expectedClientHash
    Assert-Sha256 -Path $newDaemonPath -Expected $expectedDaemonHash
    Assert-ManagedPueueConnection -ClientPath $newClientPath -ConfigPath $newConfigPath -DaemonPath $newDaemonPath -Description "Existing protected"
}

$existingLegacyConfigItem = Get-Item -LiteralPath $legacyConfigPath -Force -ErrorAction SilentlyContinue
if (($null -eq $existingRootItem) -and ($null -ne $existingLegacyConfigItem)) {
    $legacyMigrationRequired = $true
    foreach ($path in @($legacyClientPath, $legacyDaemonPath, $legacyConfigPath)) {
        Require-Path -Path $path
    }
    Assert-Sha256 -Path $legacyClientPath -Expected $expectedClientHash
    Assert-Sha256 -Path $legacyDaemonPath -Expected $expectedDaemonHash
    if (!(Test-PueueConnection -ClientPath $legacyClientPath -ConfigPath $legacyConfigPath)) {
        Restore-LegacyDaemon
        Wait-ForDaemon -ClientPath $legacyClientPath -ConfigPath $legacyConfigPath -DaemonPath $legacyDaemonPath
    }
    Assert-ManagedPueueConnection -ClientPath $legacyClientPath -ConfigPath $legacyConfigPath -DaemonPath $legacyDaemonPath -Description "Legacy"
}

$stageRootDirectory = Join-Path $parentDirectory (".$rootName.stage.$PID")
$backupRootDirectory = Join-Path $parentDirectory (".$rootName.backup.$PID")
$failedRootDirectory = Join-Path $parentDirectory (".$rootName.failed.$PID")
Assert-NonReparseDirectoryPath -Path $parentDirectory -Description "AgentQ transaction parent"
foreach ($path in @($stageRootDirectory, $backupRootDirectory, $failedRootDirectory)) {
    Assert-NonReparseArtifactPath -Path $path -Description "AgentQ transaction path" -AllowMissing
    $transactionPathItem = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($null -ne $transactionPathItem) {
        throw "AgentQ transaction path already exists: $path"
    }
}

try {
    Acquire-MaintenanceLock
    $rootForMaintenanceItem = Get-Item -LiteralPath $rootDirectory -Force -ErrorAction SilentlyContinue
    if ($null -ne $rootForMaintenanceItem) {
        Wait-ForAgentQOperationLock -RuntimeDirectory $runtimeDirectory
        Assert-NoActivePueueTasks -ClientPath $newClientPath -ConfigPath $newConfigPath -Description "Protected"
    } elseif ($legacyMigrationRequired) {
        Assert-NoActivePueueTasks -ClientPath $legacyClientPath -ConfigPath $legacyConfigPath -Description "Legacy"
    }
    Assert-NonReparseArtifactPath -Path $stageRootDirectory -Description "staging root" -AllowMissing
    [System.IO.Directory]::CreateDirectory($stageRootDirectory) | Out-Null
    Assert-NonReparseDirectoryPath -Path $stageRootDirectory -Description "staging root"
    $stageConfigDirectory = Join-Path $stageRootDirectory "config"
    $stageDataDirectory = Join-Path $stageRootDirectory "data"
    $stageRuntimeDirectory = Join-Path $stageRootDirectory "runtime"
    $stageDirectories = @(
        $stageConfigDirectory,
        $stageDataDirectory,
        (Join-Path $stageDataDirectory "task_logs"),
        (Join-Path $stageDataDirectory "agentq-cancellations"),
        (Join-Path $stageDataDirectory "agentq-requests"),
        (Join-Path $stageDataDirectory "agentq-requests\.locks"),
        (Join-Path $stageDataDirectory "agentq-requests\.tombstones"),
        $stageRuntimeDirectory
    )
    foreach ($directory in $stageDirectories) {
        Assert-NonReparseArtifactPath -Path $directory -Description "staging directory" -AllowMissing
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        Assert-NonReparseDirectoryPath -Path $directory -Description "staging directory"
    }

    Install-StageAsset -SourcePath (Join-Path $StageDirectory "agentq") -DestinationPath (Join-Path $stageRootDirectory "agentq")
    Install-AgentQLauncher -SourcePath (Join-Path $StageDirectory "agentq-launcher.ps1") -DestinationPath (Join-Path $stageRootDirectory "agentq-launcher.ps1") -GitBashPath $gitBashPath
    Install-StageAsset -SourcePath (Join-Path $StageDirectory "agentq-start-daemon.ps1") -DestinationPath (Join-Path $stageRootDirectory "agentq-start-daemon.ps1")
    Install-StageAsset -SourcePath (Join-Path $StageDirectory "agentq-durable-move.ps1") -DestinationPath (Join-Path $stageRootDirectory "agentq-durable-move.ps1")
    Install-PueueConfiguration -SourcePath (Join-Path $StageDirectory "pueue.yml") -DestinationPath (Join-Path $stageConfigDirectory "pueue.yml") -GitBashRuntimePath $gitBashRuntimePath
    Copy-VerifiedPueueBinary -DestinationPath (Join-Path $stageRootDirectory "pueue.exe") -AssetName $clientAssetName -ExpectedHash $expectedClientHash -ExistingPath $newClientPath
    Copy-VerifiedPueueBinary -DestinationPath (Join-Path $stageRootDirectory "pueued.exe") -AssetName $daemonAssetName -ExpectedHash $expectedDaemonHash -ExistingPath $newDaemonPath
    Assert-Sha256 -Path (Join-Path $stageRootDirectory "pueue.exe") -Expected $expectedClientHash
    Assert-Sha256 -Path (Join-Path $stageRootDirectory "pueued.exe") -Expected $expectedDaemonHash
    Ensure-GitBashRuntimeDependencies
    Invoke-BashSyntaxCheck -Path (Join-Path $stageRootDirectory "agentq")
    Assert-PowerShellSyntax -Path (Join-Path $stageRootDirectory "agentq-launcher.ps1")
    Assert-PowerShellSyntax -Path (Join-Path $stageRootDirectory "agentq-durable-move.ps1")
    & (Join-Path $stageRootDirectory "pueue.exe") --version 1> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Staged Pueue client cannot run"
    }
    & (Join-Path $stageRootDirectory "pueued.exe") --version 1> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Staged Pueue daemon cannot run"
    }
    Set-PrivateTreeAcl -Path $stageRootDirectory

    $previousTask = Get-ScheduledTaskDefinition
    $transactionActive = $true

    $previousRootItem = Get-Item -LiteralPath $rootDirectory -Force -ErrorAction SilentlyContinue
    if ($null -ne $previousRootItem) {
        Assert-NonReparseDirectoryPath -Path $rootDirectory -Description "previous AgentQ root"
        [void]@(Get-PrivateTreeItems -Path $rootDirectory)
        $previousDaemonStopAttempted = $true
        Stop-PueueDaemon -ClientPath $newClientPath -ConfigPath $newConfigPath -DaemonPath $newDaemonPath
        $previousDaemonStopped = $true
        Copy-AgentQData -SourceDirectory (Join-Path $rootDirectory "data") -DestinationDirectory $stageDataDirectory
        Set-PrivateTreeAcl -Path $stageRootDirectory
        Assert-NonReparseArtifactPath -Path $backupRootDirectory -Description "backup AgentQ root" -AllowMissing
        $backupRootItem = Get-Item -LiteralPath $backupRootDirectory -Force -ErrorAction SilentlyContinue
        if ($null -ne $backupRootItem) {
            throw "AgentQ transaction path already exists: $backupRootDirectory"
        }
        Move-Item -LiteralPath $rootDirectory -Destination $backupRootDirectory -Force
        Assert-NonReparseDirectoryPath -Path $backupRootDirectory -Description "backup AgentQ root"
        $previousRootMoved = $true
    } elseif ($legacyMigrationRequired) {
        $legacyDaemonStopAttempted = $true
        Stop-PueueDaemon -ClientPath $legacyClientPath -ConfigPath $legacyConfigPath -DaemonPath $legacyDaemonPath
        $legacyDaemonStopped = $true
        Copy-AgentQData -SourceDirectory $legacyDataDirectory -DestinationDirectory $stageDataDirectory
        Set-PrivateTreeAcl -Path $stageRootDirectory
    }

    Assert-NonReparseDirectoryPath -Path $stageRootDirectory -Description "staging root"
    Assert-NonReparseArtifactPath -Path $rootDirectory -Description "AgentQ root" -AllowMissing
    $rootBeforeInstallItem = Get-Item -LiteralPath $rootDirectory -Force -ErrorAction SilentlyContinue
    if ($null -ne $rootBeforeInstallItem) {
        throw "AgentQ transaction path already exists: $rootDirectory"
    }
    Move-Item -LiteralPath $stageRootDirectory -Destination $rootDirectory -Force
    $candidateInstalled = $true
    Assert-NonReparseDirectoryPath -Path $rootDirectory -Description "AgentQ root"
    Set-PrivateTreeAcl -Path $rootDirectory

    Set-AgentQStartupTask -StartupPath $newStartupPath
    Start-PueueDaemon -StartupPath $newStartupPath -ClientPath $newClientPath -ConfigPath $newConfigPath -DaemonPath $newDaemonPath
    Assert-ManagedPueueCredentials -DataDirectory $dataDirectory
    Set-PrivateTreeAcl -Path $rootDirectory
    Assert-ManagedPueueConnection -ClientPath $newClientPath -ConfigPath $newConfigPath -DaemonPath $newDaemonPath -Description "Staged protected"
    $groups = Get-PueueGroupsFromTemporaryFile -ClientPath $newClientPath -ConfigPath $newConfigPath -RuntimeDirectory $runtimeDirectory
    # A missing group is the normal first-install case, and StrictMode would
    # otherwise turn that absence into a terminating error instead of the
    # `group add` branch below.
    $agentqGroupProperty = $null
    if ($null -ne $groups) {
        $agentqGroupProperty = $groups.PSObject.Properties["agentq"]
    }
    if ($null -ne $agentqGroupProperty) {
        & $newClientPath --config $newConfigPath parallel --group agentq 1 1> $null
    } else {
        & $newClientPath --config $newConfigPath group add --parallel 1 agentq 1> $null
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Staged Pueue AgentQ group setup failed"
    }
    $health = Get-PueueHealthFromTemporaryFile -ClientPath $newClientPath -ConfigPath $newConfigPath -RuntimeDirectory $runtimeDirectory
    Invoke-PueueShellCommandSmoke -ClientPath $newClientPath -ConfigPath $newConfigPath -WorkingDirectory $rootDirectory -GitBashPath $gitBashPath
    Invoke-AgentQLauncherSmoke -LauncherPath $newLauncherPath -ExpectMaintenanceRejection
    Set-PrivateTreeAcl -Path $rootDirectory
    Assert-NoActivePueueTasks -ClientPath $newClientPath -ConfigPath $newConfigPath -Description "Staged protected"

    if ($legacyMigrationRequired) {
        $legacyArtifacts = @(
            @{ Source = (Join-Path $legacyRootDirectory ".config\agentq"); Destination = "config-agentq" },
            @{ Source = $legacyDataDirectory; Destination = "data-agentq" },
            @{ Source = (Join-Path $legacyBinDirectory "agentq"); Destination = "agentq" },
            @{ Source = (Join-Path $legacyBinDirectory "agentq-start-daemon.ps1"); Destination = "agentq-start-daemon.ps1" },
            @{ Source = $legacyClientPath; Destination = "pueue.exe" },
            @{ Source = $legacyDaemonPath; Destination = "pueued.exe" }
        )
        $existingLegacyArtifacts = @($legacyArtifacts | Where-Object {
                $null -ne (Get-Item -LiteralPath $_.Source -Force -ErrorAction SilentlyContinue)
            })
        if ($existingLegacyArtifacts.Count -gt 0) {
            $legacyWorkDirectory = Join-Path $rootDirectory ("legacy-work-" + $PID)
            $legacyBackupDirectory = Join-Path $legacyWorkDirectory ("backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
            Assert-NonReparseArtifactPath -Path $legacyWorkDirectory -Description "legacy migration work directory" -AllowMissing
            Assert-NonReparseDirectoryPath -Path $legacyWorkDirectory -Description "legacy migration work directory" -AllowMissing
            [System.IO.Directory]::CreateDirectory($legacyWorkDirectory) | Out-Null
            Assert-NonReparseDirectoryPath -Path $legacyWorkDirectory -Description "legacy migration work directory"
            Assert-NonReparseArtifactPath -Path $legacyBackupDirectory -Description "legacy migration backup directory" -AllowMissing
            $legacyBackupItem = Get-Item -LiteralPath $legacyBackupDirectory -Force -ErrorAction SilentlyContinue
            if ($null -ne $legacyBackupItem) {
                Assert-NonReparseDirectoryPath -Path $legacyBackupDirectory -Description "legacy migration backup directory"
            }
            [System.IO.Directory]::CreateDirectory($legacyBackupDirectory) | Out-Null
            Assert-NonReparseDirectoryPath -Path $legacyBackupDirectory -Description "legacy migration backup directory"
            foreach ($artifact in $existingLegacyArtifacts) {
                Move-LegacyArtifact -SourcePath $artifact.Source -DestinationPath (Join-Path $legacyBackupDirectory $artifact.Destination)
            }
        }
    }
    Set-PrivateTreeAcl -Path $rootDirectory

    $transactionActive = $false
    $legacyMovedArtifacts.Clear()
    if (!(Remove-SafeTransactionDirectory -Path $backupRootDirectory -Description "backup AgentQ root")) {
        throw "backup AgentQ root cleanup failed: $backupRootDirectory"
    }

    [pscustomobject]@{
        root = $rootDirectory
        identity = $currentIdentity
        pueue_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $newClientPath).Hash.ToLowerInvariant()
        pueued_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $newDaemonPath).Hash.ToLowerInvariant()
        scheduled_task = $taskName
        legacy_backup = $legacyBackupDirectory
        updated_atomically = $true
    } | ConvertTo-Json -Compress
} catch {
    $installFailure = $_
    $rollbackOutcome = Restore-Transaction
    if (!$rollbackOutcome.Succeeded) {
        $rollbackDetails = ($rollbackOutcome.Errors -join "; ")
        [Console]::Error.WriteLine("AgentQ rollback is incomplete: $rollbackDetails")
        throw [System.InvalidOperationException]::new("AgentQ installation failed: $($installFailure.Exception.Message). Rollback is incomplete: $rollbackDetails", $installFailure.Exception)
    }
    throw
} finally {
    # A `throw` inside a `finally` REPLACES the in-flight exception and aborts
    # the rest of the block -- so a cleanup failure here would both mask the
    # real install error (from the catch above) and skip Release-MaintenanceLock,
    # leaving the lock held for the next invocation.  Each cleanup step is
    # therefore made non-throwing (report to stderr, keep going), and the lock
    # release is wrapped in its OWN finally so it runs no matter what.
    try {
        if (!(Remove-SafeTransactionDirectory -Path $stageRootDirectory -Description "staging root")) {
            [Console]::Error.WriteLine("AgentQ staging root cleanup failed; preserving it: $stageRootDirectory")
        }
        if (!$preserveRecoveryArtifacts) {
            if (!(Remove-SafeTransactionDirectory -Path $failedRootDirectory -Description "failed AgentQ root")) {
                [Console]::Error.WriteLine("AgentQ failed root cleanup failed; preserving it: $failedRootDirectory")
            }
        } else {
            [Console]::Error.WriteLine("AgentQ recovery artifacts were preserved at $rootDirectory and $backupRootDirectory")
        }
    } catch {
        [Console]::Error.WriteLine("AgentQ transaction cleanup error: $($_.Exception.Message)")
    } finally {
        if (!$preserveRecoveryArtifacts) {
            Release-MaintenanceLock
        }
    }
}
