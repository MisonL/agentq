[CmdletBinding()]
param(
    [string]$DestinationDirectory = "",
    [switch]$SkipPathUpdate,
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Program = "agentq-client-installer"

$scriptDirectory = Split-Path -Parent $PSCommandPath
if (([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT)) {
    throw "This installer must run on Windows. Use assets/client/unix/install-client.sh on macOS, Linux, or WSL."
}

function Test-NonReparsePathChain {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    try {
        $currentPath = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $false
    }
    while (![string]::IsNullOrWhiteSpace($currentPath)) {
        $item = $null
        try {
            $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        } catch {
            if ($_.Exception -isnot [System.Management.Automation.ItemNotFoundException]) {
                return $false
            }
        }
        if ($null -ne $item -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return $false
        }
        $parentPath = Split-Path -Parent $currentPath
        if ([string]::IsNullOrWhiteSpace($parentPath) -or ($parentPath -eq $currentPath)) {
            break
        }
        $currentPath = $parentPath
    }
    return $true
}

function Resolve-CurrentWindowsUserProfile {
    try {
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
        if (!(Test-NonReparsePathChain -Path $profile)) {
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
        return [System.IO.Path]::GetFullPath($profile)
    } catch {
        throw "Unable to resolve the current Windows user profile from the process SID: $($_.Exception.Message)"
    }
}
$windowsUserProfile = Resolve-CurrentWindowsUserProfile
$script:WindowsUserLocalAppData = Join-Path $windowsUserProfile "AppData\Local"
if ([string]::IsNullOrWhiteSpace($DestinationDirectory)) {
    $DestinationDirectory = Join-Path $windowsUserProfile ".local\bin"
}

function Assert-NonReparsePathChain {
    param(
        [string]$Path,
        [string]$Description
    )

    if (!(Test-NonReparsePathChain -Path $Path)) {
        throw "Invalid reparse path for $Description`: $Path"
    }
}

function Get-CanonicalClientCheckEntries {
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($client in @("agentq", "sshp")) {
        foreach ($extension in @(".ps1", ".cmd")) {
            [void]$entries.Add([pscustomobject]@{
                Name = $client + $extension
                SourcePath = Join-Path $scriptDirectory ($client + $extension)
                DestinationPath = Join-Path $DestinationDirectory ($client + $extension)
            })
        }
    }
    $gitBashPath = Resolve-GitBashPath
    if ($null -ne $gitBashPath) {
        foreach ($client in @("agentq", "sshp")) {
            [void]$entries.Add([pscustomobject]@{
                Name = $client
                SourcePath = Join-Path $scriptDirectory ($client + ".bash")
                DestinationPath = Join-Path $DestinationDirectory $client
            })
        }
    }
    return $entries.ToArray()
}

function Invoke-CanonicalClientCheck {
    if (!(Test-NonReparsePathChain -Path $DestinationDirectory)) {
        [Console]::Error.WriteLine("$($script:Program): client destination is an unsafe reparse path: $DestinationDirectory")
        return 2
    }

    $hasMismatch = $false
    $hasUnsafePath = $false
    foreach ($entry in @(Get-CanonicalClientCheckEntries)) {
        $destinationItem = Get-Item -LiteralPath $entry.DestinationPath -Force -ErrorAction SilentlyContinue
        if ($null -eq $destinationItem) {
            [Console]::Error.WriteLine("$($script:Program): client is missing: $($entry.Name)")
            $hasMismatch = $true
            continue
        }
        if (!(Test-NonReparsePathChain -Path $entry.DestinationPath)) {
            [Console]::Error.WriteLine("$($script:Program): client path is a symbolic link or unsafe reparse path: $($entry.Name)")
            $hasUnsafePath = $true
            continue
        }
        if ($destinationItem.PSIsContainer) {
            [Console]::Error.WriteLine("$($script:Program): client is not a file: $($entry.Name)")
            $hasMismatch = $true
            continue
        }
        $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $entry.SourcePath).Hash.ToLowerInvariant()
        $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $entry.DestinationPath).Hash.ToLowerInvariant()
        if ($sourceHash -ne $destinationHash) {
            [Console]::Error.WriteLine("$($script:Program): client does not match canonical asset: $($entry.Name)")
            $hasMismatch = $true
        }
    }

    if ($hasUnsafePath) {
        return 2
    }
    if ($hasMismatch) {
        return 1
    }
    [Console]::Out.WriteLine("AgentQ Windows clients match canonical assets")
    return 0
}

function Remove-InstallerTemporaryFile {
    param(
        [string]$Path,
        [string]$Description = "client installer temporary file"
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $true
    }
    if (!(Test-NonReparsePathChain -Path $Path)) {
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

function New-InstallerTemporaryFile {
    param(
        [string]$Directory,
        [string]$Prefix
    )

    if ([string]::IsNullOrWhiteSpace($Directory) -or [string]::IsNullOrWhiteSpace($Prefix)) {
        throw "Client installer temporary directory and prefix are required"
    }
    Assert-NonReparsePathChain -Path $Directory -Description "client temporary directory"
    for ($attempt = 0; $attempt -lt 20; $attempt += 1) {
        $candidate = Join-Path $Directory (".agentq-client-$Prefix-$([Guid]::NewGuid().ToString('N')).tmp")
        try {
            $stream = [System.IO.File]::Open(
                $candidate,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            $stream.Dispose()
            try {
                Assert-NonReparsePathChain -Path $Directory -Description "client temporary directory"
                Assert-NonReparsePathChain -Path $candidate -Description "client temporary file"
            } catch {
                [void](Remove-InstallerTemporaryFile -Path $candidate -Description "client temporary file")
                throw
            }
            return [System.IO.Path]::GetFullPath($candidate)
        } catch [System.IO.IOException] {
            continue
        }
    }
    throw "Unable to create a unique client installer temporary file"
}

function Install-CommitSet {
    # Pair-atomic commit (PLAN.md A28 W4, the installer half): stage EVERYTHING
    # first, then replace destinations in one commit phase.  Per-item
    # stage+replace installs agentq and then fails on sshp, leaving a NEW agentq
    # paired with a STALE sshp -- and the pair is only ever read together.  A
    # failure INSIDE the commit phase cannot be made atomic without transactional
    # filesystem support; what this bounds is the crash/failure window to the
    # replacements themselves (adjacent [File] calls), instead of every copy,
    # chmod/ACL and replace of the remaining items.  On the known Windows failure
    # modes -- source asset missing/unreadable, ACL write denied -- the throw
    # happens during staging and NEITHER destination moves.  That is the
    # property smoke/25 asserts; the residue of a mid-commit crash is caught by
    # --check (one side drifted) and a rerun heals both.
    param(
        [array]$Items
    )

    $staged = [System.Collections.Generic.List[object]]::new()
    $stagedTemporaryPaths = [System.Collections.Generic.List[string]]::new()
    $originalError = $null
    try {
        foreach ($item in $Items) {
            $sourcePath = $item.SourcePath
            $destinationPath = $item.DestinationPath
            $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction SilentlyContinue
            if ($null -eq $sourceItem) {
                throw "Client asset is missing: $sourcePath"
            }
            Assert-NonReparsePathChain -Path $sourcePath -Description "client source file"
            if ($sourceItem.PSIsContainer) {
                throw "Client asset is not a file: $sourcePath"
            }
            $destinationItem = Get-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $destinationItem) {
                Assert-NonReparsePathChain -Path $destinationPath -Description "client destination file"
                if ($destinationItem.PSIsContainer) {
                    throw "Client destination is not a file: $destinationPath"
                }
            }
            Assert-NonReparsePathChain -Path $DestinationDirectory -Description "client destination directory"
            $temporaryPath = New-InstallerTemporaryFile -Directory $DestinationDirectory -Prefix "stage"
            Assert-NonReparsePathChain -Path $temporaryPath -Description "client temporary file"
            [void]$stagedTemporaryPaths.Add($temporaryPath)
            Copy-Item -LiteralPath $SourcePath -Destination $temporaryPath -Force
            if ($item.PSObject.Properties["Prepare"] -and $null -ne $item.Prepare) {
                & $item.Prepare $temporaryPath
            }
            # Prepare/PostCommit are optional per-item hooks (only the Git Bash
            # shims carry them).  Under StrictMode a missing property THROWS on
            # access, so both are copied through a property-existence guard --
            # measured 2026-10-07: reading $item.PostCommit unconditionally
            # broke the plain .ps1/.cmd items.
            $entry = [ordered]@{
                TemporaryPath      = $temporaryPath
                DestinationPath    = $destinationPath
                DestinationExisted = ($null -ne $destinationItem)
                Description        = $item.Description
            }
            if ($item.PSObject.Properties["PostCommit"]) {
                $entry["PostCommit"] = $item.PostCommit
            }
            [void]$staged.Add([pscustomobject]$entry)
        }

        for ($index = 0; $index -lt $staged.Count; $index++) {
            $entry = $staged[$index]
            Assert-NonReparsePathChain -Path $entry.DestinationPath -Description "client destination file"
            if ($entry.DestinationExisted) {
                $backupPath = New-InstallerTemporaryFile -Directory $DestinationDirectory -Prefix "backup"
                Assert-NonReparsePathChain -Path $backupPath -Description "client backup file"
                [System.IO.File]::Replace($entry.TemporaryPath, $entry.DestinationPath, $backupPath)
                if (!(Remove-InstallerTemporaryFile -Path $backupPath -Description "client backup file")) {
                    throw "Client installer temporary cleanup failed"
                }
            } else {
                [System.IO.File]::Move($entry.TemporaryPath, $entry.DestinationPath)
            }
            # Post-replace work (the ACL) runs inside the commit phase on
            # purpose: the file must not become visible as committed before its
            # protection lands.
            if ($entry.PSObject.Properties["PostCommit"] -and $null -ne $entry.PostCommit) {
                & $entry.PostCommit $entry.DestinationPath
            }
        }
    } catch {
        $originalError = $_
        throw
    } finally {
        $cleanupFailed = $false
        foreach ($temporaryPath in $stagedTemporaryPaths) {
            # Commit moves the staged file away, so a path that no longer exists
            # was consumed by a successful replace -- that is success, not
            # residue, and Remove-InstallerTemporaryFile already treats a missing
            # path that way.
            if (!(Remove-InstallerTemporaryFile -Path $temporaryPath -Description "client temporary file")) {
                $cleanupFailed = $true
            }
        }
        if ($cleanupFailed) {
            # A `throw` from `finally` replaces the in-flight exception, so when
            # the try body already failed, report the cleanup failure to stderr
            # and let the ORIGINAL error propagate instead of masking it.  Only
            # when the body succeeded is the cleanup failure itself the error.
            if ($null -ne $originalError) {
                [Console]::Error.WriteLine("Client installer temporary cleanup failed")
            } else {
                throw "Client installer temporary cleanup failed"
            }
        }
    }
}

function Resolve-GitBashPath {
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
        if ($null -eq $command) {
            continue
        }
        $commandPath = $command.Source
        if ([string]::IsNullOrWhiteSpace($commandPath)) {
            $commandPath = $command.Path
        }
        if (![string]::IsNullOrWhiteSpace($commandPath)) {
            [void]$candidatePaths.Add($commandPath)
        }
    }
    foreach ($programFilesPath in @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86),
        $env:ProgramW6432,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    )) {
        if (![string]::IsNullOrWhiteSpace($programFilesPath)) {
            [void]$candidateRoots.Add($programFilesPath)
        }
    }
    if (![string]::IsNullOrWhiteSpace($script:WindowsUserLocalAppData)) {
        [void]$candidateRoots.Add((Join-Path $script:WindowsUserLocalAppData "Programs"))
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
            $launcherPath = Join-Path $candidateRoot "bin\bash.exe"
            $runtimePath = Join-Path $candidateRoot "usr\bin\bash.exe"
            $launcherItem = Get-Item -LiteralPath $launcherPath -Force -ErrorAction SilentlyContinue
            $runtimeItem = Get-Item -LiteralPath $runtimePath -Force -ErrorAction SilentlyContinue
            if (!(Test-NonReparsePathChain -Path $launcherPath)) {
                throw "Git Bash with bin\\bash.exe and usr\\bin\\bash.exe is required; unsafe launcher candidate: $launcherPath"
            }
            if (!(Test-NonReparsePathChain -Path $runtimePath)) {
                throw "Git Bash with bin\\bash.exe and usr\\bin\\bash.exe is required; unsafe runtime candidate: $runtimePath"
            }
            if (($null -ne $launcherItem) -and ($null -ne $runtimeItem) -and
                !$launcherItem.PSIsContainer -and !$runtimeItem.PSIsContainer) {
                return [System.IO.Path]::GetFullPath($launcherPath)
            }
        }
    }
    return $null
}

function Add-DirectoryToUserPath {
    param([string]$Path)

    $userPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
    $parts = @($userPath -split ";" | Where-Object { ![string]::IsNullOrWhiteSpace($_) })
    $alreadyPresent = $false
    foreach ($part in $parts) {
        if ([string]::Equals($part.TrimEnd("\\"), $Path.TrimEnd("\\"), [StringComparison]::OrdinalIgnoreCase)) {
            $alreadyPresent = $true
            break
        }
    }
    if (!$alreadyPresent) {
        $updatedPath = if ($parts.Count -eq 0) { $Path } else { ($parts -join ";") + ";" + $Path }
        [Environment]::SetEnvironmentVariable("Path", $updatedPath, [EnvironmentVariableTarget]::User)
    }
    if (@($env:Path -split ";" | Where-Object { [string]::Equals($_.TrimEnd("\\"), $Path.TrimEnd("\\"), [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
        $env:Path = if ([string]::IsNullOrWhiteSpace($env:Path)) { $Path } else { $env:Path + ";" + $Path }
    }
}

if ($Check) {
    exit (Invoke-CanonicalClientCheck)
}

Assert-NonReparsePathChain -Path $DestinationDirectory -Description "client destination directory"
[System.IO.Directory]::CreateDirectory($DestinationDirectory) | Out-Null
Assert-NonReparsePathChain -Path $DestinationDirectory -Description "client destination directory"

$clientCommitItems = [System.Collections.Generic.List[object]]::new()
foreach ($client in @("agentq", "sshp")) {
    foreach ($extension in @(".ps1", ".cmd")) {
        $sourcePath = Join-Path $scriptDirectory ($client + $extension)
        $destinationPath = Join-Path $DestinationDirectory ($client + $extension)
        [void]$clientCommitItems.Add([pscustomobject]@{
                SourcePath       = $sourcePath
                DestinationPath  = $destinationPath
                Description      = $client + $extension
            })
    }
}

function Set-ClientLauncherAcl {
    param([string]$Path)

    # Restrict the Git Bash launcher to its owner, the way `chmod 700` does on a
    # POSIX host -- by setting an ACL, not by calling chmod.
    #
    # Why chmod cannot be used here.  Git for Windows mounts every volume with
    # `noacl` (/etc/fstab: `none / cygdrive binary,posix=0,noacl,user`), so
    # chmod does NOTHING: measured on Windows 10, `chmod 700` and `chmod 600` on
    # the same file both exit 0 and leave it at 644.  The call was silent -- it
    # returns success, so the installer reported that the launcher had been made
    # executable when the mode had not changed at all.
    #
    # What the ACL does NOT do: cut inheritance.  These launchers live in the
    # user's PATH and inherit the profile's protection; replacing the whole ACL
    # would strip grants the surrounding tooling relies on.  The owner keeps
    # FullControl and every other identity is limited to ReadAndExecute --
    # a launcher only needs to be readable and executable to be run, so nothing
    # legitimate is lost, while write access stops being inherited from
    # permissive parents.  ReadAndExecute is granted even though the shim holds
    # no credentials: it is a wrapper around agentq.ps1, so withholding read
    # would only break invocation.
    Assert-NonReparsePathChain -Path $Path -Description "client launcher ACL path"
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        throw "client launcher ACL path must be a file: $Path"
    }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ([string]::IsNullOrWhiteSpace($identity)) {
        throw "unable to determine the current Windows identity for launcher ACL: $Path"
    }

    # Drop every inherited rule, then re-add the two explicit grants.  Without
    # removing the inherited entries an inherited Allow would survive alongside
    # the tightened rule and the restriction would be cosmetic.
    @($acl.Access) | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    $acl.SetAccessRuleProtection($true, $false)
    $readExecute = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($rule in @(
            @{ Identity = $identity; Rights = $fullControl },
            @{ Identity = "NT AUTHORITY\SYSTEM"; Rights = $fullControl },
            @{ Identity = "BUILTIN\Administrators"; Rights = $fullControl },
            @{ Identity = "NT AUTHORITY\Authenticated Users"; Rights = $readExecute }
        )) {
        [void]$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $rule.Identity, $rule.Rights, $allow)))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl

    # Verify it landed.  The whole point of this function is that the previous
    # approach reported success while changing nothing, so trusting the call
    # again would repeat the defect.
    $applied = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $ownerRule = @($applied.Access | Where-Object {
            $_.AccessControlType -eq $allow -and
            ($_.IdentityReference.Value -eq $identity) -and
            (($_.FileSystemRights -band $fullControl) -eq $fullControl)
        }).Count -gt 0
    if (!$applied.AreAccessRulesProtected -or !$ownerRule) {
        throw "client launcher ACL did not apply: $Path"
    }
}

# Set-ClientLauncherAcl is defined before it is REFERENCED here, but the
# [pscustomobject] scriptblock below only runs it during Install-CommitSet --
# by then the function exists.
$gitBashPath = Resolve-GitBashPath
if ($null -ne $gitBashPath) {
    foreach ($client in @("agentq", "sshp")) {
        $shimSourcePath = Join-Path $scriptDirectory ($client + ".bash")
        $shimPath = Join-Path $DestinationDirectory $client
        [void]$clientCommitItems.Add([pscustomobject]@{
                SourcePath    = $shimSourcePath
                DestinationPath = $shimPath
                Description   = $client
                Prepare       = { param($path) Set-ClientLauncherAcl -Path $path }
            })
    }
}

# ONE commit for all four/five client files: every source is readable and every
# stage completes before any destination moves, and the only per-item work left
# inside the commit is the replacement itself plus the ACL that must land with it.
Install-CommitSet -Items $clientCommitItems.ToArray()

if (!$SkipPathUpdate) {
    Add-DirectoryToUserPath -Path $DestinationDirectory
}

[Console]::Out.WriteLine("installed AgentQ clients in $DestinationDirectory")
if ($null -eq $gitBashPath) {
    [Console]::Out.WriteLine("Git Bash was not found; rerun this installer after Git for Windows is installed to add its launchers.")
}
if (!$SkipPathUpdate) {
    [Console]::Out.WriteLine("Open a new terminal before invoking agentq or sshp by name.")
}
