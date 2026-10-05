Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Program = Split-Path -Leaf $PSCommandPath

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

function Resolve-CurrentWindowsUserProfile {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
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
            return [System.IO.Path]::GetFullPath($profile)
        } catch {
            throw "Unable to resolve the current Windows user profile from the process SID: $($_.Exception.Message)"
        }
    }

    foreach ($candidate in @($env:USERPROFILE, $HOME)) {
        if (![string]::IsNullOrWhiteSpace($candidate)) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    throw "User profile is unavailable"
}

function Test-NonReparseWindowsFilePath {
    param([string]$Path)

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

$script:UserProfileDirectory = Resolve-CurrentWindowsUserProfile
$script:ConfigPath = if (![string]::IsNullOrWhiteSpace($env:AGENTQ_CONFIG)) {
    $env:AGENTQ_CONFIG
} else {
    Join-Path $script:UserProfileDirectory ".config\agentq\config"
}
$script:SubmitRetryAttempts = if (![string]::IsNullOrWhiteSpace($env:AGENTQ_SUBMIT_RETRY_ATTEMPTS)) {
    $env:AGENTQ_SUBMIT_RETRY_ATTEMPTS
} else {
    "6"
}
$script:SubmitRetryDelay = if (![string]::IsNullOrWhiteSpace($env:AGENTQ_SUBMIT_RETRY_DELAY)) {
    $env:AGENTQ_SUBMIT_RETRY_DELAY
} else {
    "2"
}
$script:OperationRetryAttempts = if (![string]::IsNullOrWhiteSpace($env:AGENTQ_OPERATION_RETRY_ATTEMPTS)) {
    $env:AGENTQ_OPERATION_RETRY_ATTEMPTS
} else {
    "6"
}
$script:OperationRetryDelay = if (![string]::IsNullOrWhiteSpace($env:AGENTQ_OPERATION_RETRY_DELAY)) {
    $env:AGENTQ_OPERATION_RETRY_DELAY
} else {
    "2"
}
$script:PlatformProbeTimeout = if (![string]::IsNullOrWhiteSpace($env:AGENTQ_PLATFORM_PROBE_TIMEOUT)) {
    $env:AGENTQ_PLATFORM_PROBE_TIMEOUT
} else {
    "30"
}
$script:RemotePlatform = if (![string]::IsNullOrWhiteSpace($env:AGENTQ_REMOTE_PLATFORM)) {
    $env:AGENTQ_REMOTE_PLATFORM
} else {
    "auto"
}
$script:SshPath = $null
$script:TargetHost = $null
# Credential source for ssh password authentication.  Empty keeps BatchMode=yes
# exactly as it always was: fail fast, never wait for input.  A non-empty value
# switches ssh to BatchMode=no plus an askpass program.
#
# This is NOT the POSIX design transplanted, but it is closer than it looks.  On
# Windows ssh has no terminal to prompt on, so an askpass program is mandatory:
# with no console its readpassphrase() reads the CONSOLE via _getwch() and blocks
# forever instead of failing, which would hang an unattended queue.  Askpass is
# therefore the ONLY source this platform offers: see Resolve-CredentialSource.
# Like the POSIX client, the program is reached through SSH_ASKPASS_REQUIRE=force
# -- without it ssh never invokes the program at all (there is no DISPLAY on
# Windows, so it has no other trigger) and blocks on the console instead.
$script:CredentialSource = ""
$script:CredentialOptionLines = @()

function Show-Usage {
    [Console]::Out.WriteLine(@"
Usage:
  $($script:Program) [--host <ssh-host>] submit --workdir <remote-directory> [--label <label>] [--request-id <id>] -- <command> [arguments...]
  $($script:Program) [--host <ssh-host>] lookup <request-id>
  $($script:Program) [--host <ssh-host>] status
  $($script:Program) [--host <ssh-host>] logs <task-id> [--tail <lines>]
  $($script:Program) [--host <ssh-host>] cancel <task-id>
  $($script:Program) [--host <ssh-host>] wait <task-id>
  $($script:Program) [--host <ssh-host>] remove <task-id>
  $($script:Program) [--host <ssh-host>] doctor

Environment:
  AGENTQ_HOST                      Default SSH host when --host is omitted.
  AGENTQ_CONFIG                    Optional config file containing AGENTQ_HOST.
  AGENTQ_ASKPASS                   Program that prints the SSH password; enables
                                   password authentication.  Must be exactly one
                                   executable path: ssh executes the whole value as
                                   a single file name, so arguments and quotes are
                                   NOT supported.  A shebang script works on Git
                                   Bash's ssh; a .cmd or .ps1 does not.
  AGENTQ_PASSWORD                  SSH password as an environment variable.
                                   POSIX only; refused on Windows.
  AGENTQ_SUBMIT_RETRY_ATTEMPTS     Confirmed transport retries for submit.
  AGENTQ_SUBMIT_RETRY_DELAY        Delay in seconds between submit retries.
  AGENTQ_OPERATION_RETRY_ATTEMPTS  Confirmed transport retries for safe operations.
  AGENTQ_OPERATION_RETRY_DELAY     Delay in seconds between safe-operation retries.
  AGENTQ_PLATFORM_PROBE_TIMEOUT    Read-only platform/launcher probe limit in seconds.
  AGENTQ_SSH                       OpenSSH client path; defaults to ssh.exe found on PATH.
  AGENTQ_REMOTE_PLATFORM           auto, unix, or windows; defaults to auto.
"@)
}

function Stop-AgentQ {
    param([string]$Message)

    [Console]::Error.WriteLine("$($script:Program): $Message")
    exit 2
}

function Test-PositiveInteger {
    param([string]$Value)

    return ($Value -match '^[1-9][0-9]*$')
}

function Convert-ToPositiveInt32 {
    param(
        [string]$Value,
        [string]$Name
    )

    if (!(Test-PositiveInteger -Value $Value)) {
        Stop-AgentQ "$Name must be a positive 32-bit integer"
    }

    [long]$parsed = 0
    try {
        $parsed = [long]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        Stop-AgentQ "$Name must be a positive 32-bit integer"
    }
    if ($parsed -gt [int]::MaxValue) {
        Stop-AgentQ "$Name must be a positive 32-bit integer"
    }
    return [int]$parsed
}

function Test-PositiveIntegerOrAll {
    param([string]$Value)

    return (($Value -eq "all") -or (Test-PositiveInteger -Value $Value))
}

function Test-TaskId {
    param([string]$Value)

    return ($Value -match '^[0-9]+$')
}

function Convert-ToCanonicalTaskIdString {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $typeName = $Value.GetType().FullName
    $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
    switch ($typeName) {
        { $_ -in @(
                "System.Byte", "System.SByte", "System.Int16", "System.UInt16",
                "System.Int32", "System.UInt32", "System.Int64", "System.UInt64"
        ) } {
            if ($Value -lt 0) {
                return $null
            }
            if ($Value -eq 0) {
                return "0"
            }
            return ([System.IFormattable]$Value).ToString("0", $invariantCulture).TrimStart('0')
        }
        "System.Numerics.BigInteger" {
            if ($Value -lt 0) {
                return $null
            }
            if ($Value -eq 0) {
                return "0"
            }
            return ([System.IFormattable]$Value).ToString("0", $invariantCulture).TrimStart('0')
        }
        "System.Decimal" {
            [decimal]$decimalValue = $Value
            if ($decimalValue -lt 0 -or [decimal]::Truncate($decimalValue) -ne $decimalValue) {
                return $null
            }
            if ($decimalValue -eq 0) {
                return "0"
            }
            return $decimalValue.ToString("0", $invariantCulture).TrimStart('0')
        }
        "System.Double" {
            [double]$doubleValue = $Value
            $maxSafeInteger = 9007199254740991
            if ([double]::IsNaN($doubleValue) -or [double]::IsInfinity($doubleValue) -or
                $doubleValue -lt 0 -or [math]::Floor($doubleValue) -ne $doubleValue -or
                $doubleValue -gt $maxSafeInteger) {
                return $null
            }
            if ($doubleValue -eq 0) {
                return "0"
            }
            return $doubleValue.ToString("0", $invariantCulture).TrimStart('0')
        }
        "System.Single" {
            [double]$singleValue = $Value
            $maxSafeInteger = 9007199254740991
            if ([double]::IsNaN($singleValue) -or [double]::IsInfinity($singleValue) -or
                $singleValue -lt 0 -or [math]::Floor($singleValue) -ne $singleValue -or
                $singleValue -gt $maxSafeInteger) {
                return $null
            }
            if ($singleValue -eq 0) {
                return "0"
            }
            return $singleValue.ToString("0", $invariantCulture).TrimStart('0')
        }
        default {
            return $null
        }
    }
}

function Test-TaskIdMatch {
    param(
        [AllowNull()][object]$Actual,
        [string]$Expected
    )

    if ([string]::IsNullOrEmpty($Expected)) {
        return $true
    }
    if (!(Test-TaskId -Value $Expected)) {
        return $false
    }

    $canonicalExpected = $Expected.TrimStart('0')
    if ([string]::IsNullOrEmpty($canonicalExpected)) {
        $canonicalExpected = "0"
    }
    $canonicalActual = Convert-ToCanonicalTaskIdString -Value $Actual
    if ($null -eq $canonicalActual) {
        return $false
    }
    if ([string]::IsNullOrEmpty($canonicalActual)) {
        $canonicalActual = "0"
    }
    return $canonicalActual -ceq $canonicalExpected
}

function Test-RequestId {
    param([string]$Value)

    return (($Value -match '^[A-Za-z0-9][A-Za-z0-9._-]{15,127}$'))
}

function Read-AgentQConfigFile {
    param([string]$Path)

    Assert-NonReparseTemporaryFilePath -Path $Path

    $maximumConfigBytes = 4096
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $buffer = [byte[]]::new($maximumConfigBytes + 1)
        $offset = 0
        while ($offset -lt $buffer.Length) {
            $readCount = $stream.Read($buffer, $offset, $buffer.Length - $offset)
            if ($readCount -eq 0) {
                break
            }
            $offset += $readCount
        }
    } catch {
        throw "AgentQ config file could not be read"
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    if ($offset -gt $maximumConfigBytes) {
        throw "AgentQ config file exceeded the fixed limit of $maximumConfigBytes bytes"
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
        throw "AgentQ config file returned invalid encoding"
    }
}

function Get-ConfiguredHost {
    $configItem = Get-Item -LiteralPath $script:ConfigPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $configItem) {
        return ""
    }

    $configuredHost = ""
    $configText = Read-AgentQConfigFile -Path $script:ConfigPath
    foreach ($line in @($configText -split "`r?`n")) {
        if ($line -match '^AGENTQ_HOST=([^\s]+)$') {
            $configuredHost = $Matches[1]
        }
    }
    return $configuredHost
}

# Refuse rather than silently fall back to key-only authentication: a silent
# fallback would leave the operator believing a password was being used.
function Stop-Credential {
    param([string]$Message)

    [Console]::Error.WriteLine("$($script:Program): $Message")
    [Console]::Error.WriteLine("$($script:Program): refusing to run; clear the credential variable to go back to key-only authentication")
    exit 2
}

# Resolve the credential source.  Validation happens here, before anything
# reaches ssh -- including the platform probe, which is itself an ssh call that
# runs before operation dispatch.
function Resolve-CredentialSource {
    if (![string]::IsNullOrWhiteSpace($env:AGENTQ_ASKPASS)) {
        $program = $env:AGENTQ_ASKPASS
        # ssh executes the WHOLE SSH_ASKPASS value as a SINGLE file name.  There
        # is no shell in between and no word splitting, so the value is legal
        # exactly when it names an existing executable file -- spaces and all: a
        # path under "Program Files" works, while "<path> --flag" and
        # "<path>" (quoted) do not.  The test is the FILE SYSTEM, not the
        # characters; rejecting anything containing a space would refuse good
        # paths.  Measured on a real Windows host (Git Bash MSYS ssh 9.9p1) and
        # confirmed locally (OpenSSH 10.3p1):
        #   <path with space>       -> authenticates (rc=0)
        #   <path> --flag           -> fails
        #   "<path>"                -> fails
        #   "cmd.exe /c helper.cmd" -> ssh_askpass: exec(...): No such file or directory
        # A ".ps1"/".cmd" therefore cannot be the program itself.
        #
        # Validating only the FIRST token (as an earlier revision did, when the
        # "cmd.exe /c" shape was believed to work) accepted values ssh can never
        # exec, and the failure surfaced as a connection timeout -- pointing the
        # operator at the network instead of at the credential setting.
        if (!(Test-NonReparseWindowsFilePath -Path $program)) {
            # Only diagnose the shape when the whole value really is not a file;
            # otherwise the file is fine and the problem is something else.
            if ($program.Contains('"') -or $program.Contains(' ')) {
                Stop-Credential ("AGENTQ_ASKPASS must be a single executable path with no arguments and no quotes; " +
                    "ssh executes the whole value as one file name, so neither is supported: $program")
            }
            Stop-Credential "AGENTQ_ASKPASS is not a regular non-reparse file: $program"
        }

        if (![string]::IsNullOrWhiteSpace($env:AGENTQ_PASSWORD)) {
            Stop-Credential "AGENTQ_ASKPASS and AGENTQ_PASSWORD are both set; set only one"
        }

        $script:CredentialSource = "askpass"
        $script:AskPassProgram = $program
        return
    }

    if (![string]::IsNullOrWhiteSpace($env:AGENTQ_PASSWORD)) {
        # Deliberately not supported on this platform, while it IS on POSIX.
        # AgentQ would have to write the secret somewhere ssh can read it, and
        # every available shape is worse than letting the user own it: a
        # temporary here has no cleanup mechanism to hook (this client has no
        # top-level trap), and a cmd.exe helper reading it back would corrupt any
        # password containing cmd metacharacters.  Neither can be measured
        # without a Windows host.  The askpass source has neither problem, so it
        # is the only one offered here.
        Stop-Credential "AGENTQ_PASSWORD is not supported on Windows; set AGENTQ_ASKPASS to a program that prints the password"
    }

    if (![string]::IsNullOrWhiteSpace($env:AGENTQ_PASSWORD_PROMPT)) {
        # Also not supported: Windows ssh reads the password from the console via
        # _getwch(), and with no console it blocks rather than failing -- so an
        # unattended call would hang forever instead of erroring.
        Stop-Credential "AGENTQ_PASSWORD_PROMPT is not supported on Windows; use AGENTQ_ASKPASS"
    }
}

# For AGENTQ_PASSWORD the secret would otherwise sit in the environment of every
# ssh child, so it is moved into a private temporary script that reads it from
# the environment.  The script carries no credential itself.
function Get-CredentialSshOptions {
    if ($script:CredentialSource -eq "") {
        return @("-o", "BatchMode=yes")
    }
    return @("-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1")
}

function Resolve-SshPath {
    if (![string]::IsNullOrWhiteSpace($env:AGENTQ_SSH)) {
        $sshItem = Get-Item -LiteralPath $env:AGENTQ_SSH -Force -ErrorAction SilentlyContinue
        if ($null -eq $sshItem) {
            Stop-AgentQ "AGENTQ_SSH is not an executable file: $env:AGENTQ_SSH"
        }
        if (!(Test-NonReparseWindowsFilePath -Path $env:AGENTQ_SSH)) {
            Stop-AgentQ "AGENTQ_SSH is not a regular non-reparse file: $env:AGENTQ_SSH"
        }
        return [System.IO.Path]::GetFullPath($env:AGENTQ_SSH)
    }

    $command = Get-Command ssh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        $command = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -eq $command) {
        Stop-AgentQ "OpenSSH client is required; install ssh.exe or set AGENTQ_SSH"
    }

    $path = $command.Source
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = $command.Path
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        Stop-AgentQ "OpenSSH client path is unavailable"
    }
    $sshItem = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($null -eq $sshItem) {
        Stop-AgentQ "OpenSSH client path is unavailable"
    }
    if (!(Test-NonReparseWindowsFilePath -Path $path)) {
        Stop-AgentQ "OpenSSH client path is unsafe: $path"
    }
    return [System.IO.Path]::GetFullPath($path)
}

function New-TemporaryPath {
    param([string]$Prefix)

    for ($attempt = 0; $attempt -lt 20; $attempt += 1) {
        $candidate = Join-Path ([System.IO.Path]::GetTempPath()) ("$Prefix-$PID-$([Guid]::NewGuid().ToString('N')).tmp")
        try {
            $stream = [System.IO.File]::Open(
                $candidate,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            $stream.Dispose()
            try {
                Assert-NonReparseTemporaryFilePath -Path $candidate
            } catch {
                $identityFailureMessage = $_.Exception.Message
                if (!(Remove-SafeTemporaryFile -Path $candidate)) {
                    throw "$identityFailureMessage; temporary cleanup failed: $candidate"
                }
                throw
            }
            return $candidate
        } catch [System.IO.IOException] {
            continue
        }
    }
    throw "Unable to create a unique AgentQ temporary file for $Prefix"
}

function Test-NonReparseTemporaryFilePath {
    param([string]$Path)

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
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            if ($item.PSIsContainer -or
                (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                return $false
            }
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

function Assert-NonReparseTemporaryFilePath {
    param([string]$Path)

    if (!(Test-NonReparseTemporaryFilePath -Path $Path)) {
        throw "Invalid AgentQ temporary file path; expected a regular non-reparse file: $Path"
    }
}

function Remove-SafeTemporaryFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $true
    }
    if (!(Test-NonReparseTemporaryFilePath -Path $Path)) {
        [Console]::Error.WriteLine("$($script:Program): refusing to remove an unsafe AgentQ temporary file: $Path")
        return $false
    }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        [Console]::Error.WriteLine("$($script:Program): failed to remove AgentQ temporary file: $Path")
        return $false
    }
    $remaining = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -ne $remaining) {
        [Console]::Error.WriteLine("$($script:Program): AgentQ temporary file remained after cleanup: $Path")
        return $false
    }
    return $true
}

function Get-FileTextOrEmpty {
    param(
        [string]$Path,
        [switch]$Bounded
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return ""
    }
    Assert-NonReparseTemporaryFilePath -Path $Path

    if (!$Bounded) {
        return [System.IO.File]::ReadAllText($Path)
    }

    $maximumDiagnosticBytes = 65536
    $buffer = [byte[]]::new($maximumDiagnosticBytes + 1)
    $stream = $null
    $bytesRead = 0
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        while ($bytesRead -lt $buffer.Length) {
            $readCount = $stream.Read($buffer, $bytesRead, $buffer.Length - $bytesRead)
            if ($readCount -le 0) {
                break
            }
            $bytesRead += $readCount
        }
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    $truncated = $bytesRead -gt $maximumDiagnosticBytes
    if ($truncated) {
        $bytesRead = $maximumDiagnosticBytes
    }
    $text = ([System.Text.UTF8Encoding]::new($false, $false)).GetString($buffer, 0, $bytesRead)
    if ($truncated) {
        if (!$text.EndsWith("`n")) {
            $text += [Environment]::NewLine
        }
        $text += "[diagnostic truncated after $maximumDiagnosticBytes bytes]"
    }
    return $text
}

function Get-LastExitCodeOrFailure {
    $lastExitCode = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    if ($null -eq $lastExitCode) {
        return 1
    }
    return [int]$lastExitCode.Value
}

function Convert-ToProcessArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes += 1
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function New-SshProcessStartInfo {
    param(
        [string[]]$Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:SshPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    # The askpass program has to reach ssh through the environment.  Set on the
    # ProcessStartInfo rather than through $env: so it cannot leak into any other
    # child this client starts.
    #
    # SSH_ASKPASS_REQUIRE=force is not optional here.  ssh reaches for the
    # askpass program only when it has no terminal AND is allowed to; on Windows
    # there is no DISPLAY, so WITHOUT this variable the program is never invoked
    # and ssh falls back to readpassphrase(), which reads the CONSOLE via
    # _getwch() -- and with no console it blocks forever instead of failing.
    # Measured on the real Windows test host (OpenSSH_for_Windows_9.5p1, started
    # the way this client starts ssh: ProcessStartInfo, redirected streams): with
    # the variable unset the call BLOCKS and the program is never called; with
    # `force` it returns rc=0 and the program is called once.  An earlier revision
    # omitted it on the false premise that "Windows ssh has no equivalent of
    # SSH_ASKPASS_REQUIRE" -- the Win32-OpenSSH builds in use here do support it
    # (measured: 9.5p1, the PATH default, and the Git Bash MSYS 9.9p1; only the
    # much older System32 8.1p1 predates it and blocks regardless).
    if ($script:CredentialSource -ne "") {
        $startInfo.EnvironmentVariables["SSH_ASKPASS"] = $script:AskPassProgram
        $startInfo.EnvironmentVariables["SSH_ASKPASS_REQUIRE"] = "force"
    } else {
        # EnvironmentVariables starts as a copy of THIS process's environment, so
        # an inherited SSH_ASKPASS would otherwise reach ssh.  Git Bash exports
        # one (measured on the real host: SSH_ASKPASS=C:/Git/mingw64/bin/
        # git-askpass.exe), and the POSIX client clears it for the same reason --
        # the credential sources are AGENTQ_ASKPASS/AGENTQ_PASSWORD, not whatever
        # the ambient environment happens to hold.  Remove is safe when absent.
        [void]$startInfo.EnvironmentVariables.Remove("SSH_ASKPASS")
        [void]$startInfo.EnvironmentVariables.Remove("SSH_ASKPASS_REQUIRE")
    }
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $hasArgumentList = @($startInfo.PSObject.Properties.Match("ArgumentList")).Count -gt 0
    if ($hasArgumentList) {
        foreach ($argument in $Arguments) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
    } else {
        $startInfo.Arguments = (($Arguments | ForEach-Object { Convert-ToProcessArgument -Value $_ }) -join ' ')
    }
    return $startInfo
}

function Stop-ProbeProcess {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process -or $Process.HasExited) {
        return ""
    }
    try {
        $Process.Kill($true)
        return ""
    } catch [System.Management.Automation.MethodException] {
        try {
            $Process.Kill()
            return ""
        } catch {
            return "; failed to terminate probe process: $($_.Exception.Message)"
        }
    } catch {
        return "; failed to terminate probe process: $($_.Exception.Message)"
    }
}

function Read-BoundedProcessStreamChunk {
    param(
        [Parameter(Mandatory = $true)][psobject]$State,
        [int]$MaximumCharacters
    )

    if ($State.Complete) {
        return $false
    }

    try {
        [int]$readCount = $State.Task.GetAwaiter().GetResult()
    } catch {
        $State.Complete = $true
        $State.Failure = $_.Exception.Message
        return $true
    }

    if ($readCount -le 0) {
        $State.Complete = $true
        return $true
    }

    if ($State.Characters -lt $MaximumCharacters) {
        [int]$remaining = $MaximumCharacters - $State.Characters
        [int]$copyCount = [Math]::Min($remaining, $readCount)
        if ($copyCount -gt 0) {
            [void]$State.Builder.Append($State.Buffer, 0, $copyCount)
            $State.Characters += $copyCount
        }
        if ($copyCount -lt $readCount) {
            $State.Truncated = $true
        }
    } else {
        $State.Truncated = $true
    }

    try {
        $State.Task = $State.Reader.ReadAsync($State.Buffer, 0, $State.Buffer.Length)
    } catch {
        $State.Complete = $true
        $State.Failure = $_.Exception.Message
    }
    return $true
}

function Invoke-SshLoggedWithTimeout {
    param(
        [string]$RemoteCommand,
        [AllowNull()][string]$InputPayload,
        [int]$TimeoutSeconds
    )

    $sshLogPath = New-TemporaryPath -Prefix "agentq-ssh-probe-log"
    try {
        Assert-NonReparseTemporaryFilePath -Path $sshLogPath
    } catch {
        $identityFailureMessage = $_.Exception.Message
        if (!(Remove-SafeTemporaryFile -Path $sshLogPath)) {
            throw "$identityFailureMessage; temporary cleanup failed: $sshLogPath"
        }
        throw
    }
    $process = $null
    try {
        $startInfo = New-SshProcessStartInfo -Arguments (@(
            "-E", $sshLogPath,
            "-o", "LogLevel=ERROR") + $script:CredentialOptionLines + @(
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=12",
            "-o", "TCPKeepAlive=yes",
            "--", $script:TargetHost, $RemoteCommand
        ))
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
    } catch {
        $setupFailureMessage = $_.Exception.Message
        if ($null -ne $process) {
            $process.Dispose()
        }
        if (!(Remove-SafeTemporaryFile -Path $sshLogPath)) {
            throw "$setupFailureMessage; temporary cleanup failed: $sshLogPath"
        }
        throw
    }
    $started = $false
    $result = $null
    $timedOut = $false
    try {
        $started = $process.Start()
        if (!$started) {
            throw "failed to start OpenSSH client"
        }
        if ($null -ne $InputPayload) {
            $process.StandardInput.Write($InputPayload)
        }
        $process.StandardInput.Close()

        $maximumProbeStreamCharacters = 65536
        $probeStreamBufferCharacters = 4096
        $stdoutState = [pscustomobject]@{
            Name = "stdout"
            Reader = $process.StandardOutput
            Buffer = [char[]]::new($probeStreamBufferCharacters)
            Task = $null
            Builder = [System.Text.StringBuilder]::new()
            Characters = 0
            Truncated = $false
            Failure = ""
            Complete = $false
        }
        $stderrState = [pscustomobject]@{
            Name = "stderr"
            Reader = $process.StandardError
            Buffer = [char[]]::new($probeStreamBufferCharacters)
            Task = $null
            Builder = [System.Text.StringBuilder]::new()
            Characters = 0
            Truncated = $false
            Failure = ""
            Complete = $false
        }
        $stdoutState.Task = $stdoutState.Reader.ReadAsync(
            $stdoutState.Buffer,
            0,
            $stdoutState.Buffer.Length
        )
        $stderrState.Task = $stderrState.Reader.ReadAsync(
            $stderrState.Buffer,
            0,
            $stderrState.Buffer.Length
        )

        [int64]$timeoutMilliseconds = [int64]$TimeoutSeconds * 1000
        if ($timeoutMilliseconds -gt [int]::MaxValue) {
            $timeoutMilliseconds = [int]::MaxValue
        }
        $probeDeadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMilliseconds)
        while ($true) {
            $progressed = $false
            if (!$stdoutState.Complete -and $stdoutState.Task.IsCompleted) {
                [void](Read-BoundedProcessStreamChunk -State $stdoutState -MaximumCharacters $maximumProbeStreamCharacters)
                $progressed = $true
            }
            if (!$stderrState.Complete -and $stderrState.Task.IsCompleted) {
                [void](Read-BoundedProcessStreamChunk -State $stderrState -MaximumCharacters $maximumProbeStreamCharacters)
                $progressed = $true
            }

            if ($process.HasExited) {
                break
            }
            if ([DateTime]::UtcNow -ge $probeDeadline) {
                $timedOut = $true
                break
            }
            if (!$progressed) {
                [void]$process.WaitForExit(50)
            }
        }

        if ($timedOut) {
            $timedOut = $true
            $killDiagnostic = Stop-ProbeProcess -Process $process
            $terminationDeadline = [DateTime]::UtcNow.AddMilliseconds(5000)
            while (!$process.HasExited -and [DateTime]::UtcNow -lt $terminationDeadline) {
                try {
                    [void]$process.WaitForExit(50)
                } catch {
                    $killDiagnostic += "; failed while waiting for probe process termination: $($_.Exception.Message)"
                    break
                }
            }
            $result = [pscustomobject]@{
                ExitCode = 124
                Output = ""
                TransportDiagnostics = Get-FileTextOrEmpty -Path $sshLogPath -Bounded
                Diagnostics = "$($script:Program): remote platform/protocol probe timed out after $TimeoutSeconds seconds$killDiagnostic"
            }
        }

        $drainDeadline = [DateTime]::UtcNow.AddMilliseconds(5000)
        while (!$stdoutState.Complete -or !$stderrState.Complete) {
            $progressed = $false
            if (!$stdoutState.Complete -and $stdoutState.Task.IsCompleted) {
                [void](Read-BoundedProcessStreamChunk -State $stdoutState -MaximumCharacters $maximumProbeStreamCharacters)
                $progressed = $true
            }
            if (!$stderrState.Complete -and $stderrState.Task.IsCompleted) {
                [void](Read-BoundedProcessStreamChunk -State $stderrState -MaximumCharacters $maximumProbeStreamCharacters)
                $progressed = $true
            }
            if (!$progressed) {
                if ([DateTime]::UtcNow -ge $drainDeadline) {
                    if (!$stdoutState.Complete) {
                        $stdoutState.Complete = $true
                        $stdoutState.Failure = "stream drain timed out after 5 seconds"
                    }
                    if (!$stderrState.Complete) {
                        $stderrState.Complete = $true
                        $stderrState.Failure = "stream drain timed out after 5 seconds"
                    }
                    break
                }
                [void]$process.WaitForExit(50)
            }
        }

        $standardOutput = $stdoutState.Builder.ToString()
        if ($stdoutState.Truncated) {
            if (!$standardOutput.EndsWith("`n")) {
                $standardOutput += [Environment]::NewLine
            }
            $standardOutput += "[probe stdout truncated after $maximumProbeStreamCharacters characters]"
        }
        if (![string]::IsNullOrEmpty($stdoutState.Failure)) {
            if (!$standardOutput.EndsWith("`n")) {
                $standardOutput += [Environment]::NewLine
            }
            $standardOutput += "[probe stdout read failed: $($stdoutState.Failure)]"
        }
        $standardError = $stderrState.Builder.ToString()
        if ($stderrState.Truncated) {
            if (!$standardError.EndsWith("`n")) {
                $standardError += [Environment]::NewLine
            }
            $standardError += "[probe stderr truncated after $maximumProbeStreamCharacters characters]"
        }
        if (![string]::IsNullOrEmpty($stderrState.Failure)) {
            if (!$standardError.EndsWith("`n")) {
                $standardError += [Environment]::NewLine
            }
            $standardError += "[probe stderr read failed: $($stderrState.Failure)]"
        }
        $transportDiagnostics = Get-FileTextOrEmpty -Path $sshLogPath -Bounded
        if ($timedOut) {
            $result.TransportDiagnostics = $transportDiagnostics
            if (![string]::IsNullOrWhiteSpace($standardError)) {
                if (![string]::IsNullOrEmpty($result.Diagnostics) -and !$result.Diagnostics.EndsWith("`n")) {
                    $result.Diagnostics += [Environment]::NewLine
                }
                $result.Diagnostics += $standardError
            }
        } else {
            $diagnostics = $transportDiagnostics
            if (![string]::IsNullOrWhiteSpace($standardError)) {
                if (![string]::IsNullOrEmpty($diagnostics) -and !$diagnostics.EndsWith("`n")) {
                    $diagnostics += [Environment]::NewLine
                }
                $diagnostics += $standardError
            }
            $result = [pscustomobject]@{
                ExitCode = $process.ExitCode
                Output = $standardOutput
                TransportDiagnostics = $transportDiagnostics
                Diagnostics = $diagnostics
            }
        }
    } catch {
        $result = [pscustomobject]@{
            ExitCode = 1
            Output = ""
            TransportDiagnostics = ""
            Diagnostics = "$($script:Program): failed to run remote platform/protocol probe: $($_.Exception.Message)"
        }
    } finally {
        if ($started -and !$process.HasExited) {
            [void](Stop-ProbeProcess -Process $process)
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
        if (!(Remove-SafeTemporaryFile -Path $sshLogPath) -and $null -ne $result) {
            $cleanupDiagnostic = "$($script:Program): temporary cleanup failed: $sshLogPath"
            if (![string]::IsNullOrEmpty($result.Diagnostics) -and !$result.Diagnostics.EndsWith("`n")) {
                $result.Diagnostics += [Environment]::NewLine
            }
            $result.Diagnostics += $cleanupDiagnostic
        }
    }
    return $result
}

function Invoke-SshLogged {
    param(
        [string]$RemoteCommand,
        [AllowNull()][string]$InputPayload
    )

    $sshLogPath = $null
    $outputPath = $null
    $errorPath = $null
    $result = $null
    $operationError = $null
    $cleanupFailurePaths = @()
    try {
        $sshLogPath = New-TemporaryPath -Prefix "agentq-ssh-log"
        $outputPath = New-TemporaryPath -Prefix "agentq-ssh-output"
        $errorPath = New-TemporaryPath -Prefix "agentq-ssh-error"
        Assert-NonReparseTemporaryFilePath -Path $sshLogPath
        Assert-NonReparseTemporaryFilePath -Path $outputPath
        Assert-NonReparseTemporaryFilePath -Path $errorPath
        $sshArguments = @(
            "-E", $sshLogPath,
            "-o", "LogLevel=ERROR") + $script:CredentialOptionLines + @(
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=12",
            "-o", "TCPKeepAlive=yes",
            "--", $script:TargetHost, $RemoteCommand
        )

        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $previousAskPass = $env:SSH_ASKPASS
        $previousAskPassRequire = $env:SSH_ASKPASS_REQUIRE
        try {
            if ($script:CredentialSource -ne "") {
                $env:SSH_ASKPASS = $script:AskPassProgram
                # Without this ssh never invokes the program on Windows (no
                # DISPLAY) and blocks reading the console.  See
                # New-SshProcessStartInfo for the measurement.
                $env:SSH_ASKPASS_REQUIRE = "force"
            } else {
                # Clear an inherited value for the same reason the
                # ProcessStartInfo path does (Git Bash exports SSH_ASKPASS).
                Remove-Item Env:\SSH_ASKPASS -ErrorAction SilentlyContinue
                Remove-Item Env:\SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
            }
            if ($null -eq $InputPayload) {
                & $script:SshPath @sshArguments 1> $outputPath 2> $errorPath
            } else {
                $InputPayload | & $script:SshPath @sshArguments 1> $outputPath 2> $errorPath
            }
            $exitCode = Get-LastExitCodeOrFailure
            $transportDiagnostics = Get-FileTextOrEmpty -Path $sshLogPath -Bounded
            $standardError = Get-FileTextOrEmpty -Path $errorPath -Bounded
            # The launcher wrapper reports its status out of band on stderr as
            # `agentq-exit:<code>`, because an sshd whose DefaultShell is
            # powershell.exe flattens a native child's exit code to 1 -- so on
            # such a target the SSH exit code loses the 2/3/4/5/6 the recovery
            # logic depends on.  The wrapper emits the token for every
            # DefaultShell value and it agrees with the SSH code whenever that
            # code is trustworthy, so the token wins when present.  Only the
            # Windows launcher emits it; other remote commands do not.
            if ($script:RemotePlatform -eq "windows") {
                # The LAST token wins, not the first.  Two reasons, and the
                # second is the one that matters:
                #   * the wrapper writes its authoritative token AFTER the
                #     launcher's own stderr, so the last one is the real one;
                #   * this text is remote-controlled.  A remote (or anything that
                #     can write to its stderr) that emits `agentq-exit:0`
                #     before its real token would make a first-match reader
                #     report SUCCESS where the operation actually failed -- and
                #     this value drives the 3/4/5/6 recovery decisions, so a
                #     forged 0 silently skips the reconcile.
                # The POSIX client has always taken the last match; this aligns
                # the two copies rather than leaving them to disagree.
                $exitTokenMatches = [regex]::Matches($standardError, '(?m)^agentq-exit:(\d+)\s*$')
                if ($exitTokenMatches.Count -gt 0) {
                    $exitCode = [int]$exitTokenMatches[$exitTokenMatches.Count - 1].Groups[1].Value
                }
            }
            $diagnostics = $transportDiagnostics
            if (![string]::IsNullOrWhiteSpace($standardError)) {
                if (![string]::IsNullOrEmpty($diagnostics) -and !$diagnostics.EndsWith("`n")) {
                    $diagnostics += [Environment]::NewLine
                }
                $diagnostics += $standardError
            }
            $result = [pscustomobject]@{
                ExitCode = $exitCode
                Output = Get-FileTextOrEmpty -Path $outputPath
                TransportDiagnostics = $transportDiagnostics
                Diagnostics = $diagnostics
            }
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
            # Restored by assignment, not Remove-Item: the variable may have been
            # set in the environment before this client ran.
            if ($null -eq $previousAskPass) {
                Remove-Item Env:\SSH_ASKPASS -ErrorAction SilentlyContinue
            } else {
                $env:SSH_ASKPASS = $previousAskPass
            }
            if ($null -eq $previousAskPassRequire) {
                Remove-Item Env:\SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
            } else {
                $env:SSH_ASKPASS_REQUIRE = $previousAskPassRequire
            }
        }
    } catch {
        $operationError = $_
    } finally {
        $cleanupFailurePaths = @()
        foreach ($path in @($sshLogPath, $outputPath, $errorPath)) {
            if (!(Remove-SafeTemporaryFile -Path $path)) {
                $cleanupFailurePaths += $path
            }
        }
        if ($null -ne $result -and $cleanupFailurePaths.Count -gt 0) {
            $cleanupDiagnostics = ($cleanupFailurePaths | ForEach-Object {
                "$($script:Program): temporary cleanup failed: $_"
            }) -join [Environment]::NewLine
            if (![string]::IsNullOrEmpty($result.Diagnostics) -and !$result.Diagnostics.EndsWith("`n")) {
                $result.Diagnostics += [Environment]::NewLine
            }
            $result.Diagnostics += $cleanupDiagnostics
        }
    }
    if ($null -ne $operationError) {
        if ($cleanupFailurePaths.Count -gt 0) {
            $cleanupDiagnostics = ($cleanupFailurePaths | ForEach-Object {
                "$($script:Program): temporary cleanup failed: $_"
            }) -join [Environment]::NewLine
            throw "$($operationError.Exception.Message); $cleanupDiagnostics"
        }
        throw $operationError
    }
    return $result
}

function Invoke-PlatformProbeWithRecovery {
    param([Parameter(Mandatory = $true)]$Probe)

    $RemoteCommand = $Probe.Command
    $InputPayload = $Probe.Input
    $attempt = 0
    while ($true) {
        $result = Invoke-SshLoggedWithTimeout -RemoteCommand $RemoteCommand -InputPayload $InputPayload -TimeoutSeconds $script:PlatformProbeTimeout
        if (($result.ExitCode -ne 255) -or !(Test-SshTransportError -Diagnostics $result.TransportDiagnostics)) {
            return $result
        }

        $attempt += 1
        if ($attempt -gt $script:OperationRetryAttempts) {
            return $result
        }
        [Console]::Error.WriteLine("$($script:Program): SSH transport lost while detecting the remote platform; retrying $attempt/$($script:OperationRetryAttempts)...")
        Start-Sleep -Seconds $script:OperationRetryDelay
    }
}

function Get-SshDiagnosticClass {
    param([string]$Diagnostics)

    if ([string]::IsNullOrEmpty($Diagnostics)) {
        return "unknown"
    }
    if (Test-SshTransportError -Diagnostics $Diagnostics) {
        return "transport"
    }
    if ([regex]::IsMatch(
            ($Diagnostics -replace "`r", ""),
            '(?im)^([^:]*: )?(Permission denied|Host key verification failed|Could not resolve hostname|No supported authentication methods available)')) {
        return "authentication"
    }
    if ($Diagnostics -match '(?i)remote platform/protocol probe timed out after') {
        return "timeout"
    }
    return "ssh"
}

function Get-RemoteFailureReason {
    param([string]$Diagnostics)

    # The server emits a machine-readable `reason=<class>` line alongside every
    # exit-2 failure (see fail() in agentq-server).  Only that controlled token
    # is forwarded -- the character class is restricted to lower-case letters
    # and underscores, so a remote cannot smuggle arbitrary text through it.
    # Everything else in the diagnostics stays redacted to metadata only.
    if ([string]::IsNullOrEmpty($Diagnostics)) {
        return $null
    }
    $match = [regex]::Match(($Diagnostics -replace "`r", ""), "(?m)^[^:]*: reason=([a-z][a-z_]*)$")
    if (!$match.Success) {
        return $null
    }
    return $match.Groups[1].Value
}

function Write-Diagnostics {
    param([string]$Diagnostics)

    if ([string]::IsNullOrEmpty($Diagnostics)) {
        return
    }
    $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($Diagnostics)
    $diagnosticClass = Get-SshDiagnosticClass -Diagnostics $Diagnostics
    $remoteReason = Get-RemoteFailureReason -Diagnostics $Diagnostics
    if ($null -ne $remoteReason) {
        [Console]::Error.WriteLine("$($script:Program): remote failure reason: $remoteReason")
    }
    [Console]::Error.WriteLine("$($script:Program): SSH diagnostic omitted for safety (class=$diagnosticClass, $byteCount bytes)")
    # The class line alone does not tell the operator what to DO, and the line
    # the caller prints on a failed platform probe ("set AGENTQ_REMOTE_PLATFORM")
    # actively points the wrong way: no value of that variable fixes a missing
    # key.  Measured on a real host offering only password auth: every AgentQ
    # command failed with the AGENTQ_REMOTE_PLATFORM hint and nothing else, which
    # reads like a remote service fault.
    #
    # This mirrors the POSIX client.  It was missing here for a while, and the
    # gap was invisible because the classifier itself was correct -- the class
    # said `authentication`, the hint just never followed.  Two of this client's
    # ssh calls hard-code BatchMode=yes, so it cannot answer a password prompt
    # either.
    #
    # The hint goes HERE, not at the caller's decision point: the caller invokes
    # the probe inside a command substitution, so the class and the log it
    # derived from are gone by the time the caller could act on them.
    # Branched, because the advice that fixes one case is wrong for the other.
    # The unconfigured branch is byte-for-byte the message this client has always
    # printed, so the existing assertion on it stays meaningful.
    if ($diagnosticClass -eq "authentication") {
        if ($script:CredentialSource -eq "") {
            [Console]::Error.WriteLine("$($script:Program): ssh could not authenticate to $($script:TargetHost); AgentQ runs ssh with BatchMode=yes, so it cannot answer a password prompt. Install a key for this host, or use an ssh-agent.")
            [Console]::Error.WriteLine("$($script:Program): to authenticate with a password instead, set AGENTQ_ASKPASS to a program that prints it (for example a system credential helper), or set AGENTQ_PASSWORD.")
        } else {
            [Console]::Error.WriteLine("$($script:Program): ssh could not authenticate to $($script:TargetHost) even though a credential source ($($script:CredentialSource)) is configured. Either the password was rejected, or the host does not accept password authentication; keys are tried first, so a key is not the problem.")
        }
    }
}

function Write-ResponseMetadata {
    param([AllowNull()][string]$Output)

    if ([string]::IsNullOrEmpty($Output)) {
        [Console]::Error.WriteLine("$($script:Program): raw response was empty")
        return
    }
    $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($Output)
    [Console]::Error.WriteLine("$($script:Program): raw response omitted for safety ($byteCount bytes)")
}

function Write-OperationOutput {
    param([string]$Output)

    if (![string]::IsNullOrEmpty($Output)) {
        [Console]::Out.Write($Output)
    }
}

function Test-JsonObjectProperty {
    param(
        [AllowNull()][object]$Object,
        [string]$Name
    )

    return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name])
}

function Test-JsonNumber {
    param([AllowNull()][object]$Value)

    return ($null -ne (Convert-ToCanonicalTaskIdString -Value $Value))
}

function Test-JsonTaskMap {
    param([AllowNull()][object]$Tasks)

    if ($null -eq $Tasks -or $Tasks -isnot [pscustomobject]) {
        return $false
    }

    foreach ($property in $Tasks.PSObject.Properties) {
        if ($property.Name -notmatch '^[0-9]+$') {
            return $false
        }
        $canonicalKey = $property.Name.TrimStart('0')
        if ([string]::IsNullOrEmpty($canonicalKey)) {
            $canonicalKey = "0"
        }
        if ($canonicalKey -cne $property.Name) {
            return $false
        }
        $task = $property.Value
        if ($task -isnot [pscustomobject] -or
            !(Test-JsonObjectProperty -Object $task -Name "id") -or
            !(Test-JsonNumber -Value $task.id) -or
            !(Test-TaskIdMatch -Actual $task.id -Expected $property.Name)) {
            return $false
        }
    }

    return $true
}

function Test-Base64String {
    param([AllowNull()][object]$Value)

    if ($Value -isnot [string]) {
        return $false
    }
    if ($Value.Length -eq 0) {
        return $false
    }
    if (![regex]::IsMatch($Value, '^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        return $false
    }
    try {
        [void][Convert]::FromBase64String($Value)
        return $true
    } catch {
        return $false
    }
}

function Test-JsonTimestamp {
    param([AllowNull()][object]$Value)

    return (($Value -is [string] -and $Value.Length -gt 0) -or
        ($Value -is [datetime]) -or ($Value -is [datetimeoffset]))
}

function Test-AgentQJsonResponse {
    param(
        [string]$Operation,
        [string]$Output,
        [string]$ExpectedRequestId = "",
        [string]$ExpectedTaskId = ""
    )

    if ([string]::IsNullOrWhiteSpace($Output)) {
        [Console]::Error.WriteLine("$($script:Program): remote $Operation response failed the AgentQ JSON protocol validation: response was empty")
        return $false
    }

    try {
        $convertFromJson = Get-Command ConvertFrom-Json -ErrorAction Stop
        if ($convertFromJson.Parameters.ContainsKey("Depth")) {
            $response = $Output | ConvertFrom-Json -Depth 100 -ErrorAction Stop
        } else {
            $response = $Output | ConvertFrom-Json -ErrorAction Stop
        }
    } catch {
        [Console]::Error.WriteLine("$($script:Program): remote $Operation response failed the AgentQ JSON protocol validation: invalid JSON response")
        Write-ResponseMetadata -Output $Output
        return $false
    }

    $valid = $false
    switch ($Operation) {
        "submit" {
            $valid = (Test-JsonObjectProperty -Object $response -Name "task_id") -and
                (Test-JsonObjectProperty -Object $response -Name "request_id") -and
                (Test-JsonObjectProperty -Object $response -Name "reused") -and
                (Test-JsonNumber -Value $response.task_id) -and
                ($response.request_id -is [string]) -and
                ($response.request_id.Length -gt 0) -and
                ([string]::IsNullOrEmpty($ExpectedRequestId) -or $response.request_id -ceq $ExpectedRequestId) -and
                ($response.reused -is [bool])
        }
        "lookup" {
            $taskIdProperty = $response.PSObject.Properties["task_id"]
            $taskIdValue = if ($null -ne $taskIdProperty) {
                $taskIdProperty.Value
            } else {
                $null
            }
            $hasAcceptedFields = (Test-JsonObjectProperty -Object $response -Name "task_id") -and
                (Test-JsonObjectProperty -Object $response -Name "request_id") -and
                (Test-JsonObjectProperty -Object $response -Name "reused") -and
                !(Test-JsonObjectProperty -Object $response -Name "state") -and
                (Test-JsonNumber -Value $taskIdValue) -and
                ($response.request_id -is [string]) -and
                ($response.request_id.Length -gt 0) -and
                ([string]::IsNullOrEmpty($ExpectedRequestId) -or $response.request_id -ceq $ExpectedRequestId) -and
                ($response.reused -is [bool])
            $states = @("not_found", "not_started", "accepted", "ambiguous", "removing", "removed")
            $stateTaskIdValid = if (Test-JsonObjectProperty -Object $response -Name "state") {
                switch ([string]$response.state) {
                    { $_ -eq "not_found" -or $_ -eq "not_started" -or $_ -eq "ambiguous" } {
                        $null -eq $taskIdValue
                    }
                    { $_ -eq "accepted" -or $_ -eq "removing" -or $_ -eq "removed" } {
                        Test-JsonNumber -Value $taskIdValue
                    }
                    default {
                        $false
                    }
                }
            } else {
                $false
            }
            $hasState = (Test-JsonObjectProperty -Object $response -Name "state") -and
                !(Test-JsonObjectProperty -Object $response -Name "reused") -and
                ($response.state -is [string]) -and
                ($states -contains $response.state) -and
                (Test-JsonObjectProperty -Object $response -Name "request_id") -and
                ($response.request_id -is [string]) -and
                ($response.request_id.Length -gt 0) -and
                ([string]::IsNullOrEmpty($ExpectedRequestId) -or $response.request_id -ceq $ExpectedRequestId) -and
                (Test-JsonObjectProperty -Object $response -Name "task_id") -and
                $stateTaskIdValid
            $valid = $hasAcceptedFields -or $hasState
        }
        { $_ -eq "status" -or $_ -eq "doctor" } {
            $valid = (Test-JsonObjectProperty -Object $response -Name "tasks") -and
                (Test-JsonTaskMap -Tasks $response.tasks)
        }
        "logs" {
            $taskObject = if (Test-JsonObjectProperty -Object $response -Name "task") {
                $response.task
            } else {
                $null
            }
            $taskIdProperty = if (Test-JsonObjectProperty -Object $taskObject -Name "id") {
                $taskObject.PSObject.Properties["id"]
            } else {
                $null
            }
            $taskIdValue = if ($null -ne $taskIdProperty) { $taskIdProperty.Value } else { $null }
            $hasPlainOutput = (Test-JsonObjectProperty -Object $response -Name "output") -and
                ($response.output -is [string]) -and
                !(Test-JsonObjectProperty -Object $response -Name "output_encoding") -and
                !(Test-JsonObjectProperty -Object $response -Name "output_base64")
            $hasBase64Output = (Test-JsonObjectProperty -Object $response -Name "output") -and
                ($null -eq $response.output) -and
                (Test-JsonObjectProperty -Object $response -Name "output_encoding") -and
                ($response.output_encoding -eq "base64") -and
                (Test-JsonObjectProperty -Object $response -Name "output_base64") -and
                (Test-Base64String -Value $response.output_base64)
            $valid = (Test-JsonObjectProperty -Object $response -Name "task") -and
                ($taskObject -is [pscustomobject]) -and
                (Test-JsonNumber -Value $taskIdValue) -and
                (Test-TaskIdMatch -Actual $taskIdValue -Expected $ExpectedTaskId) -and
                ($hasPlainOutput -or $hasBase64Output)
        }
        "wait" {
            $valid = (Test-JsonObjectProperty -Object $response -Name "task") -and
                ($response.task -is [pscustomobject]) -and
                (Test-JsonObjectProperty -Object $response.task -Name "id") -and
                (Test-JsonNumber -Value $response.task.id) -and
                (Test-TaskIdMatch -Actual $response.task.id -Expected $ExpectedTaskId) -and
                (Test-JsonObjectProperty -Object $response.task -Name "status") -and
                ($response.task.status -is [pscustomobject]) -and
                (Test-JsonObjectProperty -Object $response.task.status -Name "Done") -and
                ($response.task.status.Done -is [pscustomobject]) -and
                (Test-JsonObjectProperty -Object $response.task.status.Done -Name "result") -and
                (($response.task.status.Done.result -is [string] -and $response.task.status.Done.result.Length -gt 0) -or
                    ($response.task.status.Done.result -is [pscustomobject] -and
                        @($response.task.status.Done.result.PSObject.Properties).Count -gt 0))
            if (!$valid) {
                $valid = (Test-JsonObjectProperty -Object $response -Name "task_id") -and
                    (Test-JsonNumber -Value $response.task_id) -and
                    (Test-TaskIdMatch -Actual $response.task_id -Expected $ExpectedTaskId) -and
                    (Test-JsonObjectProperty -Object $response -Name "state") -and
                    (($response.state -eq "removed") -or ($response.state -eq "unavailable"))
            }
        }
        "cancel" {
            $valid = (Test-JsonObjectProperty -Object $response -Name "task_id") -and
                (Test-JsonNumber -Value $response.task_id) -and
                (Test-TaskIdMatch -Actual $response.task_id -Expected $ExpectedTaskId) -and
                (Test-JsonObjectProperty -Object $response -Name "action") -and
                ($response.action -eq "cancel_requested") -and
                (Test-JsonObjectProperty -Object $response -Name "cancellation_requested_at") -and
                (Test-JsonTimestamp -Value $response.cancellation_requested_at) -and
                (!(Test-JsonObjectProperty -Object $response -Name "cancellation_mode") -or
                    ($response.cancellation_mode -eq "queued_removed"))
        }
        "cancel_pending" {
            $valid = (Test-JsonObjectProperty -Object $response -Name "task_id") -and
                (Test-JsonNumber -Value $response.task_id) -and
                (Test-TaskIdMatch -Actual $response.task_id -Expected $ExpectedTaskId) -and
                (Test-JsonObjectProperty -Object $response -Name "state") -and
                ($response.state -eq "cancellation_pending") -and
                (Test-JsonObjectProperty -Object $response -Name "cancellation_requested_at") -and
                (Test-JsonTimestamp -Value $response.cancellation_requested_at)
        }
        "remove" {
            $valid = (Test-JsonObjectProperty -Object $response -Name "task_id") -and
                (Test-JsonNumber -Value $response.task_id) -and
                (Test-TaskIdMatch -Actual $response.task_id -Expected $ExpectedTaskId) -and
                (Test-JsonObjectProperty -Object $response -Name "removed") -and ($response.removed -eq $true)
        }
        default {
            $valid = ($response -is [pscustomobject])
        }
    }

    if ($valid) {
        return $true
    }

    [Console]::Error.WriteLine("$($script:Program): remote $Operation response failed the AgentQ JSON protocol validation")
    Write-ResponseMetadata -Output $Output
    return $false
}

function Test-AgentQWaitContract {
    param(
        [string]$Output,
        [int]$ExitCode,
        [string]$ExpectedTaskId = ""
    )

    if (!(Test-AgentQJsonResponse -Operation "wait" -Output $Output -ExpectedTaskId $ExpectedTaskId)) {
        return $false
    }

    try {
        if ([string]::IsNullOrWhiteSpace($Output)) {
            return $false
        }
        $parsed = if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey("Depth")) {
            $Output | ConvertFrom-Json -Depth 100 -ErrorAction Stop
        } else {
            $Output | ConvertFrom-Json -ErrorAction Stop
        }
        if ($ExitCode -eq 0) {
            return $parsed.task.status.Done.result -eq "Success"
        }
        if ($ExitCode -eq 1) {
            return (Test-JsonObjectProperty -Object $parsed -Name "task") -and
                ($parsed.task -is [pscustomobject]) -and
                (Test-JsonObjectProperty -Object $parsed.task -Name "status") -and
                ($parsed.task.status -is [pscustomobject]) -and
                (Test-JsonObjectProperty -Object $parsed.task.status -Name "Done") -and
                ($parsed.task.status.Done -is [pscustomobject]) -and
                (Test-JsonObjectProperty -Object $parsed.task.status.Done -Name "result") -and
                (($parsed.task.status.Done.result -is [string] -and $parsed.task.status.Done.result.Length -gt 0) -or
                    ($parsed.task.status.Done.result -is [pscustomobject] -and
                        @($parsed.task.status.Done.result.PSObject.Properties).Count -gt 0)) -and
                ($parsed.task.status.Done.result -ne "Success")
        }
        if ($ExitCode -eq 5) {
            return ($parsed.state -eq "removed") -and (Test-JsonNumber -Value $parsed.task_id)
        }
        if ($ExitCode -eq 6) {
            return ($parsed.state -eq "unavailable") -and (Test-JsonNumber -Value $parsed.task_id)
        }
        return $true
    } catch {
        return $false
    }
}

function Test-SshTransportError {
    param([string]$Diagnostics)

    if ([string]::IsNullOrWhiteSpace($Diagnostics)) {
        return $false
    }

    $normalized = $Diagnostics -replace "`r", ""
    $pattern = '^(ssh: connect to host [^\s]+ port [0-9]+: (Connection (refused|timed out|reset by peer|aborted)|Operation timed out|No route to host|Network is unreachable|Host is down)|Connection reset by [^\s]+ port [0-9]+\.?|Connection timed out during banner exchange|banner exchange: Connection to [^\s]+ port [0-9]+: (Connection (timed out|reset by peer)|No route to host|Network is unreachable|Host is down)|kex_exchange_identification: (read: )?(Connection (reset by peer|timed out|refused)|No route to host|Network is unreachable|Host is down)|client_loop: .* (Broken pipe|Connection reset by peer)|packet_write_wait: Connection to [^:]+: Broken pipe|Write failed: Broken pipe|Read from remote host [^:]+: Connection reset by peer|Timeout, server [^\s]+ not responding\.)$'
    return [regex]::IsMatch($normalized, $pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
}

function Convert-ToPosixQuotedArgument {
    param([string]$Value)

    $singleQuote = [string][char]39
    $quoteEscape = $singleQuote + [string][char]92 + $singleQuote + $singleQuote
    return $singleQuote + $Value.Replace($singleQuote, $quoteEscape) + $singleQuote
}

function New-UnixRemoteInvocation {
    param([string[]]$Arguments)

    $script = 'agentq_run() { agentq_server="$HOME/.local/bin/agentq"; exec "$agentq_server" "$@"; }; agentq_run'
    foreach ($argument in $Arguments) {
        $script += " " + (Convert-ToPosixQuotedArgument -Value $argument)
    }
    # The script travels base64-encoded, NOT as a command-line argument.
    # PowerShell 5.1 wraps a native argument containing a space in double quotes
    # but does not escape the double quotes already inside it, so handing this
    # script to ssh through `& $script:SshPath @sshArguments` splits it: `"$@"`
    # arrives as `$@` and the remote shell then word-splits every argument a
    # second time, so `--workdir '/tmp/my dir'` reaches the server as two
    # arguments.  Measured against the model smoke/09 calibrates and executed
    # both ways in a real shell -- see PLAN.md A21 and smoke/20.  The base64
    # alphabet needs no quoting, so the command line survives whatever the local
    # PowerShell does to it; `sh` is last in the pipeline, so the script's exit
    # status is still what ssh returns.
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($script))
    return [pscustomobject]@{
        Command = "printf %s $encoded | base64 -d | sh"
        Input = $null
    }
}

function Convert-ArgumentsToBase64 {
    param([string[]]$Arguments)

    $bytes = [System.Collections.Generic.List[byte]]::new()
    foreach ($argument in $Arguments) {
        if ($argument.IndexOf([char]0) -ge 0) {
            Stop-AgentQ "arguments cannot contain NUL bytes"
        }
        foreach ($byte in [System.Text.Encoding]::UTF8.GetBytes($argument)) {
            [void]$bytes.Add($byte)
        }
        [void]$bytes.Add(0)
    }
    if ($bytes.Count -eq 0) {
        Stop-AgentQ "internal error: Windows argument stream is empty"
    }
    return [Convert]::ToBase64String($bytes.ToArray())
}

function New-WindowsRemoteInvocation {
    param([string[]]$Arguments)

    $launcherWrapper = @'
$ProgressPreference = "SilentlyContinue"
$maximumArgumentPayloadCharacters = 1048576
$payloadBuffer = [char[]]::new(4096)
$payloadBuilder = [System.Text.StringBuilder]::new()
while ($true) {
    $payloadReadCount = [Console]::In.Read($payloadBuffer, 0, $payloadBuffer.Length)
    if ($payloadReadCount -le 0) {
        break
    }
    if (($payloadBuilder.Length + $payloadReadCount) -gt $maximumArgumentPayloadCharacters) {
        [Console]::Error.WriteLine("agentq: Windows argument payload exceeds $maximumArgumentPayloadCharacters characters")
        [Console]::Error.WriteLine("agentq-exit:2")
        exit 2
    }
    [void]$payloadBuilder.Append($payloadBuffer, 0, $payloadReadCount)
}
$payload = $payloadBuilder.ToString()
& "C:\ProgramData\AgentQ\agentq-launcher.ps1" -ArgumentsBase64 $payload
$launcherExitCode = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
if ($null -eq $launcherExitCode) {
    [Console]::Error.WriteLine("agentq-exit:1")
    exit 1
}
$agentqLauncherExit = [int]$launcherExitCode.Value
[Console]::Error.WriteLine("agentq-exit:$agentqLauncherExit")
exit $agentqLauncherExit
'@
    $encodedWrapper = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($launcherWrapper))
    return [pscustomobject]@{
        Command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedWrapper"
        Input = Convert-ArgumentsToBase64 -Arguments $Arguments
    }
}

function New-RemoteInvocation {
    param([string[]]$Arguments)

    switch ($script:RemotePlatform) {
        "unix" {
            return New-UnixRemoteInvocation -Arguments $Arguments
        }
        "windows" {
            return New-WindowsRemoteInvocation -Arguments $Arguments
        }
        default {
            Stop-AgentQ "internal error: unsupported remote platform: $($script:RemotePlatform)"
        }
    }
}

function Initialize-ClientTransport {
    if (![string]::IsNullOrWhiteSpace($script:SshPath)) {
        return
    }
    $script:SshPath = Resolve-SshPath
    Initialize-RemoteInvocation
}

# Windows remote command lines are TRUNCATED, not rejected, past the remote
# shell's limit -- and that limit depends on the DefaultShell sshd was configured
# with (measured on a real host: Git Bash 8,176 / cmd.exe 8,155 /
# powershell.exe 8,125).  The reparse hardening pushed the protocol probe's script
# to 3,216 characters, an 8,658-character command line: over all three.  The base64
# was cut mid-stream and every command on that host failed, reporting a protocol
# problem that pointed at the deployment rather than at the client.
#
# So the script body does not go on the command line.  It travels on stdin, which
# leaves a fixed 76-character command line however large the script grows.
# Measured on the same host: 8,658 -> rc=1 with empty output (dead);
# 76 -> rc=0 with the correct token.
$script:WindowsProbeCommandLine = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command -"

# Wrap a probe script so its exit status survives the REMOTE shell, not just
# PowerShell.  With DefaultShell=powershell.exe an outer PowerShell flattens a
# native child's non-zero exit code to 1 (measured: inner 2/42/43/44/45/124 all
# arrive as 1), destroying the launcher's 42-45 contract.  Git Bash and cmd.exe
# pass it through.  The fix is out of band: the script prints "agentq-exit:<code>"
# and the caller reads the code from stdout -- measured to survive all three
# outer shells intact while only the exit-code column was flattened.
function Add-ProbeExitToken {
    param([string]$Script)

    # A probe signals failure with `exit N`.  That ends the whole script, so a
    # token line appended after the body would never run -- and under an outer
    # PowerShell the code would arrive flattened to 1 with nothing to recover it.
    # So every `exit N` in the body is rewritten to `$agentqProbeExit = N` and the
    # token line at the end reports it.  The rewrite is anchored to a statement
    # boundary so an `exit` inside a string cannot match.
    # The alternation must allow LEADING INDENTATION before a bare `exit`, not
    # just `^` or `;`.  (?m)^ matches only immediately after a newline, so on an
    # indented multi-line body -- which is what the AgentQ protocol probe is --
    # every `exit N` was skipped and the token line never ran.  Measured: 0 of 7
    # exits rewritten on the real probe body, so under a `DefaultShell` of
    # powershell.exe the 42/43/44/45 codes flattened to 1 with nothing to recover
    # them -- exactly the regression this channel exists to close.  `[ \t]*`
    # covers indentation; the `;` alternative still covers the single-line
    # `; exit N` form the platform probe uses.
    $rewritten = [regex]::Replace($Script, '(?m)(^[ \t]*|;[ \t]*)exit ([0-9]+)', '${1}$agentqProbeExit = $2')
    # The probe body travels to `powershell.exe -Command -` on STDIN, and stdin
    # is read in INTERACTIVE mode: a line that opens a block (`if {`, `function
    # {`, `try {`) puts the reader into continuation, and the buffered statement
    # runs only when a BLANK LINE terminates it.  At EOF a pending buffer is
    # DISCARDED SILENTLY -- rc=0, no output, nothing executed.  The protocol
    # probe is a multi-line here-string, so without this terminator the whole
    # probe body is thrown away and every command against a Windows target fails
    # with "protocol probe failed", pointing at the deployment rather than at the
    # client.  Measured on a real Windows host (OpenSSH_for_Windows sshd, PS
    # 5.1): the identical body with one trailing newline -> empty output rc=0;
    # with a blank line appended -> "agentq-windows-launcher-ready" + the exit
    # token.  Reproduced four ways (pwsh 7 and PS 5.1, via Git Bash ssh and via a
    # POSIX ssh).  The platform probe is single-line and so was never affected --
    # which is why only the protocol probe, and only Windows targets, broke.
    return ($rewritten + "`n" +
        'if ($null -eq $agentqProbeExit) { $agentqProbeExit = 0 }' + "`n" +
        '[Console]::Out.Write("agentq-exit:" + $agentqProbeExit)' + "`n" +
        'exit $agentqProbeExit' + "`n`n")
}

function Get-WindowsProbeCommand {
    $script = '$ProgressPreference = "SilentlyContinue"; [Console]::Out.Write("agentq-windows")'
    return [pscustomobject]@{
        Command = $script:WindowsProbeCommandLine
        Input = (Add-ProbeExitToken -Script $script)
    }
}

function Get-WindowsAgentQProtocolProbeCommand {
    $script = @'
$ProgressPreference = "SilentlyContinue"
$launcher = "C:\ProgramData\AgentQ\agentq-launcher.ps1"
$launcherItem = Get-Item -LiteralPath $launcher -Force -ErrorAction SilentlyContinue
if ($null -eq $launcherItem) {
    [Console]::Out.Write("agentq-windows-launcher-missing")
    exit 42
}
function Test-NonReparseLauncherPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $pathItem = Get-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
        if ($null -eq $pathItem -or $pathItem.PSIsContainer -or
            (($pathItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
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
    } catch {
        return $false
    }
    return $true
}
if (!(Test-NonReparseLauncherPath -Path $launcher)) {
    [Console]::Out.Write("agentq-windows-launcher-invalid")
    exit 44
}
$maximumLauncherBytes = 262144
$launcherStream = $null
try {
    $launcherStream = [System.IO.File]::Open(
        $launcher,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $launcherBytes = [byte[]]::new($maximumLauncherBytes + 1)
    $launcherOffset = 0
    while ($launcherOffset -lt $launcherBytes.Length) {
        $readCount = $launcherStream.Read($launcherBytes, $launcherOffset, $launcherBytes.Length - $launcherOffset)
        if ($readCount -eq 0) {
            break
        }
        $launcherOffset += $readCount
    }
} catch {
    [Console]::Out.Write("agentq-windows-launcher-invalid")
    exit 44
} finally {
    if ($null -ne $launcherStream) {
        $launcherStream.Dispose()
    }
}
if ($launcherOffset -gt $maximumLauncherBytes) {
    [Console]::Out.Write("agentq-windows-launcher-too-large")
    exit 45
}
try {
    if ($launcherOffset -ge 3 -and $launcherBytes[0] -eq 0xEF -and $launcherBytes[1] -eq 0xBB -and $launcherBytes[2] -eq 0xBF) {
        $launcherEncoding = [System.Text.UTF8Encoding]::new($true, $true)
        $launcherContentOffset = 3
    } elseif ($launcherOffset -ge 2 -and $launcherBytes[0] -eq 0xFF -and $launcherBytes[1] -eq 0xFE) {
        $launcherEncoding = [System.Text.UnicodeEncoding]::new($false, $true, $true)
        $launcherContentOffset = 2
    } elseif ($launcherOffset -ge 2 -and $launcherBytes[0] -eq 0xFE -and $launcherBytes[1] -eq 0xFF) {
        $launcherEncoding = [System.Text.UnicodeEncoding]::new($true, $true, $true)
        $launcherContentOffset = 2
    } else {
        $launcherEncoding = [System.Text.UTF8Encoding]::new($false, $true)
        $launcherContentOffset = 0
    }
    $contents = $launcherEncoding.GetString($launcherBytes, $launcherContentOffset, $launcherOffset - $launcherContentOffset)
} catch {
    [Console]::Out.Write("agentq-windows-launcher-invalid")
    exit 44
}
if (!(Test-NonReparseLauncherPath -Path $launcher)) {
    [Console]::Out.Write("agentq-windows-launcher-invalid")
    exit 44
}
if ($contents.IndexOf("ArgumentsBase64", [System.StringComparison]::Ordinal) -lt 0) {
    [Console]::Out.Write("agentq-windows-launcher-incompatible")
    exit 43
}
[Console]::Out.Write("agentq-windows-launcher-ready")
'@
    return [pscustomobject]@{
        Command = $script:WindowsProbeCommandLine
        Input = (Add-ProbeExitToken -Script $script)
    }
}

# Read a probe's status from its out-of-band token when it carries one.
#
# A Windows probe ends by printing "agentq-exit:<code>" (see Add-ProbeExitToken).
# That is authoritative, because an outer PowerShell flattens the SSH exit code
# to 1 when sshd's DefaultShell is powershell.exe.  Without the token the probe
# is not one of ours, so the SSH exit code stands.
function Resolve-ProbeExitToken {
    param(
        [int]$SshExitCode,
        [string]$Output
    )

    # The LAST token wins, matching the POSIX client's
    # windows_probe_apply_exit_token (which strips up to the final
    # `agentq-exit:` via ${raw##*agentq-exit:}).  The probe body prints its token
    # last, so the last one is authoritative; and the output is remote-controlled,
    # so a first-match reader could be steered by a planted leading token.  Both
    # callers additionally require an exact Output value, which already rejects
    # most forgeries -- this keeps the two copies aligned rather than relying on
    # that as the only defense.
    $exitTokenMatches = [regex]::Matches($Output, 'agentq-exit:(\d+)')
    if ($exitTokenMatches.Count -gt 0) {
        $lastToken = $exitTokenMatches[$exitTokenMatches.Count - 1]
        $Output = $Output.Substring(0, $lastToken.Index).TrimEnd()
        return [pscustomobject]@{ ExitCode = [int]$lastToken.Groups[1].Value; Output = $Output }
    }
    return [pscustomobject]@{ ExitCode = $SshExitCode; Output = $Output }
}

function Confirm-WindowsAgentQProtocol {
    $protocolProbe = Invoke-PlatformProbeWithRecovery -Probe (Get-WindowsAgentQProtocolProbeCommand)
    Resolve-ProbeExitToken -SshExitCode $protocolProbe.ExitCode -Output $protocolProbe.Output |
        ForEach-Object { $protocolProbe.ExitCode = $_.ExitCode; $protocolProbe.Output = $_.Output }
    if (($protocolProbe.ExitCode -eq 0) -and ($protocolProbe.Output.Trim() -eq "agentq-windows-launcher-ready")) {
        return
    }

    Write-Diagnostics -Diagnostics $protocolProbe.Diagnostics
    if ($protocolProbe.ExitCode -eq 124) {
        exit 124
    }
    if (($protocolProbe.ExitCode -eq 42) -and ($protocolProbe.Output.Trim() -eq "agentq-windows-launcher-missing")) {
        Stop-AgentQ "remote Windows AgentQ deployment is incomplete: C:/ProgramData/AgentQ/agentq-launcher.ps1 is missing; upgrade AgentQ on $($script:TargetHost) before using it"
    }
    if (($protocolProbe.ExitCode -eq 43) -and ($protocolProbe.Output.Trim() -eq "agentq-windows-launcher-incompatible")) {
        Stop-AgentQ "remote Windows AgentQ deployment is incompatible: C:/ProgramData/AgentQ/agentq-launcher.ps1 does not support the ArgumentsBase64 protocol; upgrade AgentQ on $($script:TargetHost) before using it"
    }
    if (($protocolProbe.ExitCode -eq 44) -and ($protocolProbe.Output.Trim() -eq "agentq-windows-launcher-invalid")) {
        Stop-AgentQ "remote Windows AgentQ deployment is unsafe: C:/ProgramData/AgentQ/agentq-launcher.ps1 or its parent is a reparse path; repair the protected deployment before using it"
    }
    if (($protocolProbe.ExitCode -eq 45) -and ($protocolProbe.Output.Trim() -eq "agentq-windows-launcher-too-large")) {
        Stop-AgentQ "remote Windows AgentQ deployment is incompatible: C:/ProgramData/AgentQ/agentq-launcher.ps1 exceeds the protocol probe size limit; repair the protected deployment before using it"
    }
    Stop-AgentQ "native Windows AgentQ service protocol probe failed on $($script:TargetHost)"
}

function Confirm-NativeWindowsPlatform {
    $windowsProbe = Invoke-PlatformProbeWithRecovery -Probe (Get-WindowsProbeCommand)
    Resolve-ProbeExitToken -SshExitCode $windowsProbe.ExitCode -Output $windowsProbe.Output |
        ForEach-Object { $windowsProbe.ExitCode = $_.ExitCode; $windowsProbe.Output = $_.Output }
    if (($windowsProbe.ExitCode -eq 0) -and ($windowsProbe.Output.Trim() -eq "agentq-windows")) {
        $script:RemotePlatform = "windows"
        Confirm-WindowsAgentQProtocol
        return $true
    }

    Write-Diagnostics -Diagnostics $windowsProbe.Diagnostics
    if ($windowsProbe.ExitCode -eq 124) {
        exit 124
    }
    if (($windowsProbe.ExitCode -eq 255) -and (Test-SshTransportError -Diagnostics $windowsProbe.TransportDiagnostics)) {
        Stop-AgentQ "SSH transport failed while confirming the remote Windows platform"
    }
    Stop-AgentQ "native Windows platform probe failed after a Windows shell was detected"
}

function Initialize-RemoteInvocation {
    switch ($script:RemotePlatform) {
        "auto" {
            $unixProbe = Invoke-PlatformProbeWithRecovery -Probe ([pscustomobject]@{
                Command = "uname -s 2>/dev/null"
                Input = $null
            })
            if ($unixProbe.ExitCode -eq 0) {
                switch ($unixProbe.Output.Trim()) {
                    { $_ -like "MINGW*" -or $_ -like "MSYS*" -or $_ -like "CYGWIN*" } {
                        [void](Confirm-NativeWindowsPlatform)
                        return
                    }
                    { $_ -like "Linux*" -or $_ -like "Darwin*" } {
                        $script:RemotePlatform = "unix"
                        return
                    }
                }
            } elseif ($unixProbe.ExitCode -eq 255) {
                Write-Diagnostics -Diagnostics $unixProbe.Diagnostics
                if (Test-SshTransportError -Diagnostics $unixProbe.TransportDiagnostics) {
                    Stop-AgentQ "SSH transport failed while detecting the remote platform"
                }
            } elseif ($unixProbe.ExitCode -eq 124) {
                Write-Diagnostics -Diagnostics $unixProbe.Diagnostics
                exit 124
            }

            $windowsProbe = Invoke-PlatformProbeWithRecovery -Probe (Get-WindowsProbeCommand)
            Resolve-ProbeExitToken -SshExitCode $windowsProbe.ExitCode -Output $windowsProbe.Output |
                ForEach-Object { $windowsProbe.ExitCode = $_.ExitCode; $windowsProbe.Output = $_.Output }
            if (($windowsProbe.ExitCode -eq 0) -and ($windowsProbe.Output.Trim() -eq "agentq-windows")) {
                $script:RemotePlatform = "windows"
                Confirm-WindowsAgentQProtocol
                return
            }
            Write-Diagnostics -Diagnostics $windowsProbe.Diagnostics
            if ($windowsProbe.ExitCode -eq 124) {
                exit 124
            }
            if (($unixProbe.ExitCode -ne 0) -and ($windowsProbe.ExitCode -ne 0)) {
                Stop-AgentQ "unable to detect the remote platform; set AGENTQ_REMOTE_PLATFORM to unix or windows only when the target is known"
            }
            Stop-AgentQ "unsupported or undetectable remote platform: $($unixProbe.Output.Trim())"
        }
        "unix" {
            return
        }
        "windows" {
            Confirm-WindowsAgentQProtocol
            return
        }
        default {
            Stop-AgentQ "AGENTQ_REMOTE_PLATFORM must be auto, unix, or windows"
        }
    }
}

function Invoke-SubmitWithRecovery {
    param(
        [string]$RequestId,
        [pscustomobject]$SubmitInvocation,
        [pscustomobject]$LookupInvocation
    )

    $attempt = 0
    while ($true) {
        $result = Invoke-SshLogged -RemoteCommand $SubmitInvocation.Command -InputPayload $SubmitInvocation.Input
        Write-Diagnostics -Diagnostics $result.Diagnostics
        if ($result.ExitCode -eq 0) {
            if (!(Test-AgentQJsonResponse -Operation "submit" -Output $result.Output -ExpectedRequestId $RequestId)) {
                return 2
            }
            Write-OperationOutput -Output $result.Output
            return 0
        }
        if (($result.ExitCode -ne 255) -or !(Test-SshTransportError -Diagnostics $result.TransportDiagnostics)) {
            Write-OperationOutput -Output $result.Output
            return $result.ExitCode
        }

        $attempt += 1
        if ($attempt -gt [int]$script:SubmitRetryAttempts) {
            [Console]::Error.WriteLine("$($script:Program): SSH transport remained unavailable while submitting request $RequestId; recover later with: $($script:Program) --host $($script:TargetHost) lookup $RequestId")
            return 255
        }

        [Console]::Error.WriteLine("$($script:Program): SSH transport lost while submitting request $RequestId; reconciling attempt $attempt/$($script:SubmitRetryAttempts)...")
        Start-Sleep -Seconds ([int]$script:SubmitRetryDelay)
        $lookup = Invoke-SshLogged -RemoteCommand $LookupInvocation.Command -InputPayload $LookupInvocation.Input
        Write-Diagnostics -Diagnostics $lookup.Diagnostics
        if ($lookup.ExitCode -eq 0) {
            if (!(Test-AgentQJsonResponse -Operation "lookup" -Output $lookup.Output -ExpectedRequestId $RequestId)) {
                return 2
            }
            Write-OperationOutput -Output $lookup.Output
            return 0
        }
        if ($lookup.ExitCode -in @(3, 4, 5)) {
            if (!(Test-AgentQJsonResponse -Operation "lookup" -Output $lookup.Output -ExpectedRequestId $RequestId)) {
                return 2
            }
        }
        if ($lookup.ExitCode -eq 3) {
            continue
        }
        if (($lookup.ExitCode -eq 255) -and (Test-SshTransportError -Diagnostics $lookup.TransportDiagnostics)) {
            continue
        }
        Write-OperationOutput -Output $lookup.Output
        return $lookup.ExitCode
    }
}

function Invoke-SafeOperationWithRecovery {
    param(
        [string]$OperationName,
        [pscustomobject]$Invocation,
        [string]$ExpectedRequestId = "",
        [string]$ExpectedTaskId = ""
    )

    $attempt = 0
    while ($true) {
        $result = Invoke-SshLogged -RemoteCommand $Invocation.Command -InputPayload $Invocation.Input
        Write-Diagnostics -Diagnostics $result.Diagnostics
        if ($result.ExitCode -eq 0) {
            if (!(Test-AgentQJsonResponse -Operation $OperationName -Output $result.Output -ExpectedRequestId $ExpectedRequestId -ExpectedTaskId $ExpectedTaskId)) {
                return 2
            }
            if (($OperationName -eq "wait") -and !(Test-AgentQWaitContract -Output $result.Output -ExitCode 0 -ExpectedTaskId $ExpectedTaskId)) {
                [Console]::Error.WriteLine("$($script:Program): remote wait response failed the AgentQ exit/result contract for exit 0")
                return 2
            }
            Write-OperationOutput -Output $result.Output
            return 0
        }
        if (($OperationName -eq "wait") -and ($result.ExitCode -in @(1, 5, 6)) -and
            !(Test-AgentQWaitContract -Output $result.Output -ExitCode $result.ExitCode -ExpectedTaskId $ExpectedTaskId)) {
            [Console]::Error.WriteLine("$($script:Program): remote wait response failed the AgentQ exit/result contract for exit $($result.ExitCode)")
            return 2
        }
        if (($OperationName -eq "lookup") -and ($result.ExitCode -in @(3, 4, 5))) {
            if (!(Test-AgentQJsonResponse -Operation "lookup" -Output $result.Output -ExpectedRequestId $ExpectedRequestId)) {
                return 2
            }
        }
        if (($result.ExitCode -ne 255) -or !(Test-SshTransportError -Diagnostics $result.TransportDiagnostics)) {
            Write-OperationOutput -Output $result.Output
            return $result.ExitCode
        }

        $attempt += 1
        if ($attempt -gt [int]$script:OperationRetryAttempts) {
            [Console]::Error.WriteLine("$($script:Program): SSH transport remained unavailable while running $OperationName on $($script:TargetHost)")
            return 255
        }
        [Console]::Error.WriteLine("$($script:Program): SSH transport lost while running $OperationName; retrying $attempt/$($script:OperationRetryAttempts)...")
        Start-Sleep -Seconds ([int]$script:OperationRetryDelay)
    }
}

function Invoke-Mutation {
    param(
        [string]$OperationName,
        [pscustomobject]$Invocation,
        [string]$ExpectedTaskId = ""
    )

    $result = Invoke-SshLogged -RemoteCommand $Invocation.Command -InputPayload $Invocation.Input
    Write-Diagnostics -Diagnostics $result.Diagnostics
    if ($result.ExitCode -eq 0 -and !(Test-AgentQJsonResponse -Operation $OperationName -Output $result.Output -ExpectedTaskId $ExpectedTaskId)) {
        return 2
    }
    if (($OperationName -eq "cancel") -and ($result.ExitCode -eq 4) -and
        !(Test-AgentQJsonResponse -Operation "cancel_pending" -Output $result.Output -ExpectedTaskId $ExpectedTaskId)) {
        return 2
    }
    Write-OperationOutput -Output $result.Output
    return $result.ExitCode
}

$script:SubmitRetryAttempts = Convert-ToPositiveInt32 -Value $script:SubmitRetryAttempts -Name "AGENTQ_SUBMIT_RETRY_ATTEMPTS"
$script:SubmitRetryDelay = Convert-ToPositiveInt32 -Value $script:SubmitRetryDelay -Name "AGENTQ_SUBMIT_RETRY_DELAY"
$script:OperationRetryAttempts = Convert-ToPositiveInt32 -Value $script:OperationRetryAttempts -Name "AGENTQ_OPERATION_RETRY_ATTEMPTS"
$script:OperationRetryDelay = Convert-ToPositiveInt32 -Value $script:OperationRetryDelay -Name "AGENTQ_OPERATION_RETRY_DELAY"
$script:PlatformProbeTimeout = Convert-ToPositiveInt32 -Value $script:PlatformProbeTimeout -Name "AGENTQ_PLATFORM_PROBE_TIMEOUT"

# Resolved before anything reaches ssh: the platform probe is itself an ssh call
# and runs before operation dispatch, so a source applied only to the operation
# path would be unreachable.
Resolve-CredentialSource
$script:CredentialOptionLines = Get-CredentialSshOptions

$configuredHost = Get-ConfiguredHost
$script:TargetHost = if (![string]::IsNullOrWhiteSpace($env:AGENTQ_HOST)) { $env:AGENTQ_HOST } else { $configuredHost }
$arguments = @($args)
$position = 0
while ($position -lt $arguments.Count) {
    if ($arguments[$position] -eq "--host") {
        if (($position + 1) -ge $arguments.Count) {
            Stop-AgentQ "--host requires an SSH host"
        }
        $script:TargetHost = $arguments[$position + 1]
        $position += 2
        continue
    }
    if (($arguments[$position] -eq "-h") -or ($arguments[$position] -eq "--help") -or ($arguments[$position] -eq "help")) {
        Show-Usage
        exit 0
    }
    break
}

if ([string]::IsNullOrWhiteSpace($script:TargetHost)) {
    Stop-AgentQ "no SSH host configured; pass --host or set AGENTQ_HOST"
}
if ($script:TargetHost.StartsWith("-", [System.StringComparison]::Ordinal)) {
    Stop-AgentQ "SSH host must not begin with a hyphen"
}
if ($position -ge $arguments.Count) {
    Show-Usage
    exit 2
}

$operation = $arguments[$position]
$position += 1
switch ($operation) {
    "submit" {
        $workdir = ""
        $label = "command"
        $requestId = ""
        $commandStart = -1
        while ($position -lt $arguments.Count) {
            switch ($arguments[$position]) {
                "--workdir" {
                    if (($position + 1) -ge $arguments.Count) {
                        Stop-AgentQ "--workdir requires a directory"
                    }
                    $workdir = $arguments[$position + 1]
                    $position += 2
                    continue
                }
                "--label" {
                    if (($position + 1) -ge $arguments.Count) {
                        Stop-AgentQ "--label requires a label"
                    }
                    $label = $arguments[$position + 1]
                    $position += 2
                    continue
                }
                "--request-id" {
                    if (($position + 1) -ge $arguments.Count) {
                        Stop-AgentQ "--request-id requires a value"
                    }
                    $requestId = $arguments[$position + 1]
                    $position += 2
                    continue
                }
                "--" {
                    $commandStart = $position + 1
                    $position = $arguments.Count
                    continue
                }
                default {
                    Stop-AgentQ "unknown submit option: $($arguments[$position])"
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($workdir)) {
            Stop-AgentQ "--workdir is required"
        }
        if ($commandStart -lt 0 -or $commandStart -ge $arguments.Count) {
            Stop-AgentQ "submit requires a command after --"
        }
        if ([string]::IsNullOrWhiteSpace($requestId)) {
            $requestId = "aq-" + ([Guid]::NewGuid().ToString("N"))
        }
        if (!(Test-RequestId -Value $requestId)) {
            Stop-AgentQ "--request-id must be 16-128 ASCII letters, numbers, dots, underscores, or hyphens and start with a letter or number"
        }

        Initialize-ClientTransport
        $commandArguments = @($arguments[$commandStart..($arguments.Count - 1)])
        $submitArguments = @("submit", "--workdir", $workdir, "--label", $label, "--request-id", $requestId, "--") + $commandArguments
        $lookupArguments = @("lookup", $requestId)
        $submitInvocation = New-RemoteInvocation -Arguments $submitArguments
        $lookupInvocation = New-RemoteInvocation -Arguments $lookupArguments
        exit (Invoke-SubmitWithRecovery -RequestId $requestId -SubmitInvocation $submitInvocation -LookupInvocation $lookupInvocation)
    }
    "lookup" {
        if (($arguments.Count - $position) -ne 1) {
            Stop-AgentQ "lookup requires one request id"
        }
        if (!(Test-RequestId -Value $arguments[$position])) {
            Stop-AgentQ "request id must be 16-128 ASCII letters, numbers, dots, underscores, or hyphens and start with a letter or number"
        }
        Initialize-ClientTransport
        $invocation = New-RemoteInvocation -Arguments @("lookup", $arguments[$position])
        exit (Invoke-SafeOperationWithRecovery -OperationName "lookup" -Invocation $invocation -ExpectedRequestId $arguments[$position])
    }
    "status" {
        if (($arguments.Count - $position) -ne 0) {
            Stop-AgentQ "status accepts no arguments"
        }
        Initialize-ClientTransport
        $invocation = New-RemoteInvocation -Arguments @("status")
        exit (Invoke-SafeOperationWithRecovery -OperationName "status" -Invocation $invocation)
    }
    "doctor" {
        if (($arguments.Count - $position) -ne 0) {
            Stop-AgentQ "doctor accepts no arguments"
        }
        Initialize-ClientTransport
        $invocation = New-RemoteInvocation -Arguments @("doctor")
        exit (Invoke-SafeOperationWithRecovery -OperationName "doctor" -Invocation $invocation)
    }
    "logs" {
        $remaining = $arguments.Count - $position
        if (($remaining -ne 1) -and ($remaining -ne 3)) {
            Stop-AgentQ "logs requires a task id and optional --tail <lines>"
        }
        $taskId = $arguments[$position]
        if (!(Test-TaskId -Value $taskId)) {
            Stop-AgentQ "task id must be a non-negative integer"
        }
        $remoteArguments = @("logs", $taskId)
        if ($remaining -eq 3) {
            if ($arguments[$position + 1] -ne "--tail") {
                Stop-AgentQ "logs accepts only --tail <lines>"
            }
            if (!(Test-PositiveIntegerOrAll -Value $arguments[$position + 2])) {
                Stop-AgentQ "--tail must be a positive integer or all"
            }
            $remoteArguments += @("--tail", $arguments[$position + 2])
        }
        Initialize-ClientTransport
        $invocation = New-RemoteInvocation -Arguments $remoteArguments
        exit (Invoke-SafeOperationWithRecovery -OperationName "logs" -Invocation $invocation -ExpectedTaskId $taskId)
    }
    "cancel" {
        if (($arguments.Count - $position) -ne 1) {
            Stop-AgentQ "cancel requires one task id"
        }
        if (!(Test-TaskId -Value $arguments[$position])) {
            Stop-AgentQ "task id must be a non-negative integer"
        }
        Initialize-ClientTransport
        $invocation = New-RemoteInvocation -Arguments @("cancel", $arguments[$position])
        exit (Invoke-Mutation -OperationName "cancel" -Invocation $invocation -ExpectedTaskId $arguments[$position])
    }
    "wait" {
        if (($arguments.Count - $position) -ne 1) {
            Stop-AgentQ "wait requires one task id"
        }
        if (!(Test-TaskId -Value $arguments[$position])) {
            Stop-AgentQ "task id must be a non-negative integer"
        }
        Initialize-ClientTransport
        $invocation = New-RemoteInvocation -Arguments @("wait", $arguments[$position])
        exit (Invoke-SafeOperationWithRecovery -OperationName "wait" -Invocation $invocation -ExpectedTaskId $arguments[$position])
    }
    "remove" {
        if (($arguments.Count - $position) -ne 1) {
            Stop-AgentQ "remove requires one task id"
        }
        if (!(Test-TaskId -Value $arguments[$position])) {
            Stop-AgentQ "task id must be a non-negative integer"
        }
        Initialize-ClientTransport
        $invocation = New-RemoteInvocation -Arguments @("remove", $arguments[$position])
        exit (Invoke-Mutation -OperationName "remove" -Invocation $invocation -ExpectedTaskId $arguments[$position])
    }
    default {
        Stop-AgentQ "unknown command: $operation"
    }
}
