Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Program = Split-Path -Leaf $PSCommandPath
$script:ReconnectDelayInput = if (![string]::IsNullOrWhiteSpace($env:SSHP_RECONNECT_DELAY)) {
    $env:SSHP_RECONNECT_DELAY
} else {
    "2"
}
$script:ReconnectDelay = 0
$script:SshPath = $null
$script:TargetHost = ""
$script:SessionName = "ghostty"
$script:LastInteractiveSshResult = $null
$script:PreparationResult = $null

function Show-Usage {
    [Console]::Out.WriteLine(@"
Usage: $($script:Program) [--check] <ssh-host-or-alias> [session-name]

Attach to a persistent tmux, GNU screen, or Zellij session on an SSH host.
The default session name is ghostty.
On a missing dependency, the first connection asks before installing it.
The --check mode only probes and never installs anything.
"@)
}

function Stop-Sshp {
    param([string]$Message)

    [Console]::Error.WriteLine("$($script:Program): $Message")
    exit 2
}

function Convert-ToReconnectDelay {
    param([string]$Value)

    [int]$seconds = 0
    if (![int]::TryParse($Value, [ref]$seconds) -or ($seconds -lt 0)) {
        Stop-Sshp "SSHP_RECONNECT_DELAY must be a non-negative 32-bit integer"
    }
    return $seconds
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

function Resolve-SshPath {
    if (![string]::IsNullOrWhiteSpace($env:SSHP_SSH)) {
        $sshItem = Get-Item -LiteralPath $env:SSHP_SSH -Force -ErrorAction SilentlyContinue
        if ($null -eq $sshItem) {
            Stop-Sshp "SSHP_SSH is not an executable file: $env:SSHP_SSH"
        }
        if (!(Test-NonReparseWindowsFilePath -Path $env:SSHP_SSH)) {
            Stop-Sshp "SSHP_SSH is not a regular non-reparse file: $env:SSHP_SSH"
        }
        return [System.IO.Path]::GetFullPath($env:SSHP_SSH)
    }

    $command = Get-Command ssh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        $command = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -eq $command) {
        Stop-Sshp "OpenSSH client is required; install ssh.exe or set SSHP_SSH"
    }

    $path = $command.Source
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = $command.Path
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        Stop-Sshp "OpenSSH client path is unavailable"
    }
    $sshItem = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($null -eq $sshItem) {
        Stop-Sshp "OpenSSH client path is unavailable"
    }
    if (!(Test-NonReparseWindowsFilePath -Path $path)) {
        Stop-Sshp "OpenSSH client path is unsafe: $path"
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
    throw "Unable to create a unique sshp temporary file for $Prefix"
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
        throw "Invalid sshp temporary file path; expected a regular non-reparse file: $Path"
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
        [Console]::Error.WriteLine("$($script:Program): refusing to remove an unsafe sshp temporary file: $Path")
        return $false
    }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        [Console]::Error.WriteLine("$($script:Program): failed to remove sshp temporary file: $Path")
        return $false
    }
    $remaining = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -ne $remaining) {
        [Console]::Error.WriteLine("$($script:Program): sshp temporary file remained after cleanup: $Path")
        return $false
    }
    return $true
}

function Get-FileTextOrEmpty {
    param(
        [string]$Path,
        [switch]$Bounded,
        [string]$TruncationMarker
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
    # BOM-aware decode.  PowerShell 5.1's `2> $file` redirection (like `1>`)
    # decodes the child's output through the console code page and rewrites it
    # as UTF-16LE WITH a BOM (measured for `1>` on 2026-09-21: 1507407 ->
    # 3014810 bytes; smoke/10 rule B pins the coupling).  A UTF-8-only decode
    # of such a file yields interleaved NULs, so the `agentq-exit:` token and
    # the `reason=` line were unreadable on real PS 5.1 -- the A5b channel was
    # a no-op for this client.  Detect the BOM and decode accordingly; plain
    # UTF-8 (pwsh 7 redirection) stays byte-identical.
    $textOffset = 0
    $textEncoding = [System.Text.UTF8Encoding]::new($false, $false)
    if ($bytesRead -ge 2 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) {
        $textEncoding = [System.Text.UnicodeEncoding]::new($false, $false)
        $textOffset = 2
    } elseif ($bytesRead -ge 2 -and $buffer[0] -eq 0xFE -and $buffer[1] -eq 0xFF) {
        $textEncoding = [System.Text.UnicodeEncoding]::new($true, $false)
        $textOffset = 2
    } elseif ($bytesRead -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) {
        $textOffset = 3
    }
    $text = $textEncoding.GetString($buffer, $textOffset, $bytesRead - $textOffset)
    if ($truncated) {
        if (!$text.EndsWith("`n")) {
            $text += [Environment]::NewLine
        }
        if ([string]::IsNullOrEmpty($TruncationMarker)) {
            $TruncationMarker = "[diagnostic truncated after $maximumDiagnosticBytes bytes]"
        }
        $text += $TruncationMarker
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

function Join-Diagnostics {
    param(
        [string]$TransportDiagnostics,
        [string]$StandardError
    )

    $combined = $TransportDiagnostics
    if (![string]::IsNullOrWhiteSpace($StandardError)) {
        if (![string]::IsNullOrEmpty($combined) -and !$combined.EndsWith("`n")) {
            $combined += [Environment]::NewLine
        }
        $combined += $StandardError
    }
    return $combined
}

function Convert-ToEncodedPowerShellCommand {
    param([string]$ScriptText)

    if ([string]::IsNullOrEmpty($ScriptText)) {
        Stop-Sshp "cannot encode an empty Windows PowerShell command"
    }
    $effectiveScriptText = '$ProgressPreference = "SilentlyContinue"' + [Environment]::NewLine + $ScriptText
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($effectiveScriptText))
    return "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
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
    return "ssh"
}

function Invoke-SshLogged {
    param(
        [bool]$Interactive,
        [string]$RemoteCommand
    )

    $logPath = New-TemporaryPath -Prefix "sshp-log"
    $outputPath = $null
    $errorPath = $null
    $result = $null
    $operationError = $null
    $cleanupFailurePaths = @()
    try {
        Assert-NonReparseTemporaryFilePath -Path $logPath
        $sshArguments = @(
            "-E", $logPath,
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=6",
            "-o", "TCPKeepAlive=yes"
        )
        if ($Interactive) {
            $sshArguments += "-tt"
        } else {
            $sshArguments += "-T"
        }
        $sshArguments += @("--", $script:TargetHost, $RemoteCommand)

        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            if ($Interactive) {
                # Do not capture this call. Zellij and other terminal multiplexers need a direct TTY.
                & $script:SshPath @sshArguments
                $exitCode = Get-LastExitCodeOrFailure
                $transportDiagnostics = Get-FileTextOrEmpty -Path $logPath -Bounded
                $script:LastInteractiveSshResult = [pscustomobject]@{
                    ExitCode = $exitCode
                    Output = ""
                    TransportDiagnostics = $transportDiagnostics
                    Diagnostics = $transportDiagnostics
                }
                return
            }

            $outputPath = New-TemporaryPath -Prefix "sshp-output"
            $errorPath = New-TemporaryPath -Prefix "sshp-error"
            Assert-NonReparseTemporaryFilePath -Path $outputPath
            Assert-NonReparseTemporaryFilePath -Path $errorPath
            & $script:SshPath @sshArguments 1> $outputPath 2> $errorPath
            $exitCode = Get-LastExitCodeOrFailure
            $transportDiagnostics = Get-FileTextOrEmpty -Path $logPath -Bounded
            $standardError = Get-FileTextOrEmpty -Path $errorPath -Bounded
            $result = [pscustomobject]@{
                ExitCode = $exitCode
                Output = Get-FileTextOrEmpty -Path $outputPath -Bounded -TruncationMarker "[sshp stdout truncated after 65536 bytes]"
                TransportDiagnostics = $transportDiagnostics
                Diagnostics = Join-Diagnostics -TransportDiagnostics $transportDiagnostics -StandardError $standardError
            }
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    } catch {
        $operationError = $_
    } finally {
        $cleanupFailurePaths = @()
        foreach ($path in @($logPath, $outputPath, $errorPath)) {
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
        if ($Interactive -and $null -ne $script:LastInteractiveSshResult -and $cleanupFailurePaths.Count -gt 0) {
            $cleanupDiagnostics = ($cleanupFailurePaths | ForEach-Object {
                "$($script:Program): temporary cleanup failed: $_"
            }) -join [Environment]::NewLine
            if (![string]::IsNullOrEmpty($script:LastInteractiveSshResult.Diagnostics) -and
                !$script:LastInteractiveSshResult.Diagnostics.EndsWith("`n")) {
                $script:LastInteractiveSshResult.Diagnostics += [Environment]::NewLine
            }
            $script:LastInteractiveSshResult.Diagnostics += $cleanupDiagnostics
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
    if (!$Interactive) {
        return $result
    }
}

function Write-Diagnostics {
    param([string]$Diagnostics)

    if ([string]::IsNullOrEmpty($Diagnostics)) {
        return
    }
    $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($Diagnostics)
    $diagnosticClass = Get-SshDiagnosticClass -Diagnostics $Diagnostics
    [Console]::Error.WriteLine("$($script:Program): SSH diagnostic omitted for safety (class=$diagnosticClass, $byteCount bytes)")
}

function Get-WindowsZellijResolverScript {
    return @'
function Resolve-RemoteApplication {
    param(
        [string[]]$CommandNames,
        [string[]]$Candidates
    )

    foreach ($commandName in $CommandNames) {
        $command = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            continue
        }
        $commandPath = $command.Source
        if ([string]::IsNullOrWhiteSpace($commandPath)) {
            $commandPath = $command.Path
        }
        if ([string]::IsNullOrWhiteSpace($commandPath)) {
            continue
        }
        $commandItem = Get-Item -LiteralPath $commandPath -Force -ErrorAction SilentlyContinue
        if ($null -eq $commandItem) {
            continue
        }
        if (!(Test-NonReparseWindowsApplicationPath -Path $commandPath)) {
            throw "Remote application path is unsafe: $commandPath"
        }
        if (!$commandItem.PSIsContainer) {
            return [System.IO.Path]::GetFullPath($commandPath)
        }
    }
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $candidateItem = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if ($null -eq $candidateItem) {
            continue
        }
        if (!(Test-NonReparseWindowsApplicationPath -Path $candidate)) {
            throw "Remote application path is unsafe: $candidate"
        }
        if (!$candidateItem.PSIsContainer) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Test-NonReparseWindowsApplicationPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.PSIsContainer -or
            (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
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
    } catch {
        return $false
    }
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

function Resolve-RemoteUserEnvironment {
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
    return [pscustomobject]@{
        Profile = [System.IO.Path]::GetFullPath($profile)
        LocalAppData = Join-Path $profile "AppData\Local"
    }
}

$remoteUserEnvironment = Resolve-RemoteUserEnvironment

function Resolve-RemoteZellij {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if (![string]::IsNullOrWhiteSpace($remoteUserEnvironment.LocalAppData)) {
        [void]$candidates.Add((Join-Path $remoteUserEnvironment.LocalAppData "Microsoft\WinGet\Links\zellij.exe"))
        $packageRoot = Join-Path $remoteUserEnvironment.LocalAppData "Microsoft\WinGet\Packages"
        foreach ($package in @(Get-ChildItem -LiteralPath $packageRoot -Directory -Filter "Zellij.Zellij_*" -ErrorAction SilentlyContinue)) {
            [void]$candidates.Add((Join-Path $package.FullName "zellij.exe"))
        }
    }
    if (![string]::IsNullOrWhiteSpace($remoteUserEnvironment.Profile)) {
        [void]$candidates.Add((Join-Path $remoteUserEnvironment.Profile "scoop\shims\zellij.exe"))
        [void]$candidates.Add((Join-Path $remoteUserEnvironment.Profile "scoop\apps\zellij\current\zellij.exe"))
        [void]$candidates.Add((Join-Path $remoteUserEnvironment.Profile ".cargo\bin\zellij.exe"))
    }
    if (![string]::IsNullOrWhiteSpace($env:ProgramData)) {
        [void]$candidates.Add((Join-Path $env:ProgramData "chocolatey\bin\zellij.exe"))
    }
    return Resolve-RemoteApplication -CommandNames @("zellij.exe") -Candidates $candidates.ToArray()
}

function Resolve-RemoteInstaller {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if (![string]::IsNullOrWhiteSpace($remoteUserEnvironment.LocalAppData)) {
        [void]$candidates.Add((Join-Path $remoteUserEnvironment.LocalAppData "Microsoft\WindowsApps\winget.exe"))
    }
    $winget = Resolve-RemoteApplication -CommandNames @("winget.exe") -Candidates $candidates.ToArray()
    if ($null -ne $winget) {
        return [pscustomobject]@{ Kind = "winget"; Path = $winget }
    }

    $candidates.Clear()
    if (![string]::IsNullOrWhiteSpace($remoteUserEnvironment.Profile)) {
        [void]$candidates.Add((Join-Path $remoteUserEnvironment.Profile "scoop\shims\scoop.cmd"))
    }
    $scoop = Resolve-RemoteApplication -CommandNames @("scoop.cmd", "scoop.exe") -Candidates $candidates.ToArray()
    if ($null -ne $scoop) {
        return [pscustomobject]@{ Kind = "scoop"; Path = $scoop }
    }

    $candidates.Clear()
    if (![string]::IsNullOrWhiteSpace($env:ProgramData)) {
        [void]$candidates.Add((Join-Path $env:ProgramData "chocolatey\bin\choco.exe"))
    }
    $choco = Resolve-RemoteApplication -CommandNames @("choco.exe") -Candidates $candidates.ToArray()
    if ($null -ne $choco) {
        return [pscustomobject]@{ Kind = "choco"; Path = $choco }
    }
    return $null
}
'@
}

function Get-WindowsProbeCommand {
    $resolver = Get-WindowsZellijResolverScript
    return Convert-ToEncodedPowerShellCommand -ScriptText ($resolver + @'
$ErrorActionPreference = "Stop"
$zellij = Resolve-RemoteZellij
if ($null -ne $zellij) {
    [Console]::Out.Write("__SSHP_READY__:Windows")
    exit 0
}
$installer = Resolve-RemoteInstaller
if ($null -ne $installer) {
    [Console]::Error.WriteLine("sshp: native Zellij is missing; a supported Windows installer is available.")
    [Console]::Out.Write("__SSHP_INSTALL_REQUIRED__:Windows")
    exit 42
}
[Console]::Error.WriteLine("sshp: native Zellij is missing and no supported Windows installer was found.")
[Console]::Out.Write("__SSHP_INSTALL_UNAVAILABLE__:Windows")
exit 127
'@)
}

function Convert-ToPosixScriptCommand {
    param([string]$Script)

    # Hand a POSIX shell script to ssh WITHOUT putting it on the command line.
    #
    # PowerShell 5.1 wraps a native argument containing a space in double quotes
    # but does not escape the double quotes already inside it, so a script passed
    # through `& $script:SshPath @sshArguments` is word-split before ssh sees it:
    # `printf "%s\n"` arrives as `printf %s\n`, `"$installer"` as `$installer`.
    # Measured both ways in a real shell -- the damaged probe exits 127 with a
    # corrupted marker instead of exiting 42 with `__SSHP_INSTALL_REQUIRED__`,
    # which the client reports as "remote dependency probe failed" and blames
    # the deployment.  See PLAN.md A21 and smoke/20.
    #
    # base64 is used rather than stdin because the install path runs with `-tt`
    # and needs its terminal on stdin; the payload rides the command line, which
    # costs nothing since the base64 alphabet needs no quoting.  `sh` is last in
    # the pipeline, so the script's exit status is what ssh reports.
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Script))
    return "printf %s $encoded | base64 -d | sh"
}

function Get-UnixProbeCommand {
    return Convert-ToPosixScriptCommand -Script @'
set -eu
platform=$(uname -s 2>/dev/null || printf "%s" unknown)
case "$platform" in
    MINGW*|MSYS*|CYGWIN*)
        printf "%s\n" "__SSHP_WINDOWS_SHELL__:$platform"
        exit 43
        ;;
    *)
        if command -v tmux >/dev/null 2>&1 || command -v screen >/dev/null 2>&1 || command -v zellij >/dev/null 2>&1; then
            printf "%s\n" "__SSHP_READY__:$platform"
            exit 0
        fi
        ;;
esac

installer=
installer_label=
package_label=tmux
case "$platform" in
    MINGW*|MSYS*|CYGWIN*)
        package_label=zellij
        if command -v winget.exe >/dev/null 2>&1; then installer=winget; installer_label=winget
        elif command -v scoop >/dev/null 2>&1; then installer=scoop; installer_label=scoop
        elif command -v choco.exe >/dev/null 2>&1; then installer=choco; installer_label=Chocolatey
        fi
        ;;
    Darwin*)
        if command -v brew >/dev/null 2>&1; then installer=brew; installer_label=Homebrew
        elif command -v port >/dev/null 2>&1; then installer=port; installer_label=MacPorts
        fi
        ;;
    Linux*)
        if command -v apt-get >/dev/null 2>&1; then installer=apt; installer_label=apt
        elif command -v dnf >/dev/null 2>&1; then installer=dnf; installer_label=dnf
        elif command -v yum >/dev/null 2>&1; then installer=yum; installer_label=yum
        elif command -v pacman >/dev/null 2>&1; then installer=pacman; installer_label=pacman
        elif command -v zypper >/dev/null 2>&1; then installer=zypper; installer_label=zypper
        elif command -v apk >/dev/null 2>&1; then installer=apk; installer_label=apk
        fi
        ;;
esac

if [ -z "$installer" ]; then
    printf "%s\n" "sshp: no supported package manager found for $platform; install $package_label manually." >&2
    printf "%s\n" "__SSHP_INSTALL_UNAVAILABLE__:$platform"
    exit 127
fi
printf "%s\n" "sshp: $package_label is missing; installer candidate: $installer_label." >&2
printf "%s\n" "__SSHP_INSTALL_REQUIRED__:$platform"
exit 42
'@
}

function Get-WindowsInstallCommand {
    $resolver = Get-WindowsZellijResolverScript
    return Convert-ToEncodedPowerShellCommand -ScriptText ($resolver + @'
$ErrorActionPreference = "Stop"
$zellij = Resolve-RemoteZellij
if ($null -ne $zellij) {
    exit 0
}
$installer = Resolve-RemoteInstaller
if ($null -eq $installer) {
    Write-Error "sshp: no supported Windows installer found for Zellij."
    exit 127
}
switch ($installer.Kind) {
    "winget" {
        & $installer.Path install --id Zellij.Zellij --exact --accept-source-agreements --accept-package-agreements --disable-interactivity
    }
    "scoop" {
        & $installer.Path install zellij
    }
    "choco" {
        & $installer.Path install zellij --yes --no-progress
    }
    default {
        throw "sshp: unsupported Windows installer: $($installer.Kind)"
    }
}
$lastExitCode = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
if ($null -eq $lastExitCode) {
    exit 1
}
exit ([int]$lastExitCode.Value)
'@)
}

function Get-UnixInstallCommand {
    return Convert-ToPosixScriptCommand -Script @'
set -eu
if command -v tmux >/dev/null 2>&1 || command -v screen >/dev/null 2>&1 || command -v zellij >/dev/null 2>&1; then
    exit 0
fi
run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; elif command -v sudo >/dev/null 2>&1; then sudo "$@"; else exit 127; fi
}
if command -v apt-get >/dev/null 2>&1; then run_as_root apt-get update && run_as_root apt-get install -y tmux
elif command -v dnf >/dev/null 2>&1; then run_as_root dnf install -y tmux
elif command -v yum >/dev/null 2>&1; then run_as_root yum install -y tmux
elif command -v pacman >/dev/null 2>&1; then run_as_root pacman -S --needed --noconfirm tmux
elif command -v zypper >/dev/null 2>&1; then run_as_root zypper --non-interactive install tmux
elif command -v apk >/dev/null 2>&1; then run_as_root apk add tmux
elif command -v brew >/dev/null 2>&1; then brew install tmux
elif command -v port >/dev/null 2>&1; then run_as_root port install tmux
else exit 127
fi
'@
}

function Confirm-Install {
    if ([Console]::IsInputRedirected) {
        [Console]::Error.WriteLine("$($script:Program): dependency installation requires an interactive local terminal.")
        return $false
    }
    try {
        $answer = Read-Host "sshp: install the missing remote dependency automatically now? [y/N]"
    } catch {
        [Console]::Error.WriteLine("$($script:Program): dependency installation requires an interactive local terminal.")
        return $false
    }
    return (($answer -eq "y") -or ($answer -eq "Y") -or ($answer -eq "yes") -or ($answer -eq "YES"))
}

function Get-ProbeOutcome {
    param([pscustomobject]$Result)

    $marker = $Result.Output.Trim()
    if ($Result.ExitCode -eq 0) {
        if ($marker -match '(?m)^__SSHP_READY__:Windows$') {
            return [pscustomobject]@{ Platform = "windows"; Ready = $true }
        }
        if ($marker -match '(?m)^__SSHP_READY__:[^\r\n]+$') {
            return [pscustomobject]@{ Platform = "unix"; Ready = $true }
        }
    }
    if ($Result.ExitCode -eq 42) {
        if ($marker -match '(?m)^__SSHP_INSTALL_REQUIRED__:Windows$') {
            return [pscustomobject]@{ Platform = "windows"; Ready = $false }
        }
        if ($marker -match '(?m)^__SSHP_INSTALL_REQUIRED__:[^\r\n]+$') {
            return [pscustomobject]@{ Platform = "unix"; Ready = $false }
        }
    }
    if (($Result.ExitCode -eq 127) -and ($marker -match '(?m)^__SSHP_INSTALL_UNAVAILABLE__:[^\r\n]+$')) {
        return [pscustomobject]@{ Platform = "unix"; Ready = $false; InstallUnavailable = $true }
    }
    return $null
}

function Test-WindowsShellMarker {
    param([pscustomobject]$Result)

    return ($Result.Output -match '(?m)^__SSHP_WINDOWS_SHELL__:(MINGW|MSYS|CYGWIN)[^\r\n]*$')
}

function Get-WindowsProbeOutcome {
    param([pscustomobject]$Result)

    $marker = $Result.Output.Trim()
    if (($Result.ExitCode -eq 0) -and ($marker -match '(?m)^__SSHP_READY__:Windows$')) {
        return [pscustomobject]@{ Platform = "windows"; Ready = $true }
    }
    if (($Result.ExitCode -eq 42) -and ($marker -match '(?m)^__SSHP_INSTALL_REQUIRED__:Windows$')) {
        return [pscustomobject]@{ Platform = "windows"; Ready = $false }
    }
    if (($Result.ExitCode -eq 127) -and ($marker -match '(?m)^__SSHP_INSTALL_UNAVAILABLE__:Windows$')) {
        return [pscustomobject]@{ Platform = "windows"; Ready = $false; InstallUnavailable = $true }
    }
    return $null
}

function Write-MissingDependency {
    param([string]$Platform)

    switch ($Platform) {
        "windows" {
            [Console]::Error.WriteLine("$($script:Program): persistent remote session unavailable: native Zellij is required on Windows.")
        }
        "unix" {
            [Console]::Error.WriteLine("$($script:Program): persistent remote session unavailable: tmux, GNU screen, or Zellij is required.")
        }
    }
}

function Set-PreparationResult {
    param(
        [int]$ExitCode,
        [string]$Platform
    )

    $script:PreparationResult = [pscustomobject]@{
        ExitCode = $ExitCode
        Platform = $Platform
    }
}

function Prepare-Remote {
    param([bool]$AllowInstall)

    $installationAttempted = $false
    while ($true) {
        $unixProbe = Invoke-SshLogged -Interactive $false -RemoteCommand (Get-UnixProbeCommand)
        $outcome = Get-ProbeOutcome -Result $unixProbe
        $windowsShellDetected = Test-WindowsShellMarker -Result $unixProbe
        if (($null -eq $outcome) -or $windowsShellDetected) {
            if (($unixProbe.ExitCode -eq 255) -and (Test-SshTransportError -Diagnostics $unixProbe.TransportDiagnostics)) {
                Write-Diagnostics -Diagnostics $unixProbe.Diagnostics
                [Console]::Error.WriteLine("$($script:Program): initial SSH transport lost; reconnecting in $($script:ReconnectDelay)s...")
                Start-Sleep -Seconds $script:ReconnectDelay
                continue
            }

            # Always use native PowerShell for Windows, including Git Bash servers.
            # The SSH server process may have a stale PATH that cannot reliably find Zellij.
            $windowsProbe = Invoke-SshLogged -Interactive $false -RemoteCommand (Get-WindowsProbeCommand)
            $outcome = Get-WindowsProbeOutcome -Result $windowsProbe
            if ($null -eq $outcome) {
                if (($windowsProbe.ExitCode -eq 255) -and (Test-SshTransportError -Diagnostics $windowsProbe.TransportDiagnostics)) {
                    Write-Diagnostics -Diagnostics $windowsProbe.Diagnostics
                    [Console]::Error.WriteLine("$($script:Program): initial SSH transport lost; reconnecting in $($script:ReconnectDelay)s...")
                    Start-Sleep -Seconds $script:ReconnectDelay
                    continue
                }
                if (($windowsProbe.ExitCode -eq 127) -and ($windowsProbe.Output.Trim() -match '(?m)^__SSHP_INSTALL_UNAVAILABLE__:Windows$')) {
                    Write-Diagnostics -Diagnostics $windowsProbe.Diagnostics
                    [Console]::Error.WriteLine("$($script:Program): persistent remote session unavailable: native Zellij is required on Windows and no supported installer was found.")
                    Set-PreparationResult -ExitCode 127 -Platform "windows"
                    return
                }
                Write-Diagnostics -Diagnostics $unixProbe.Diagnostics
                Write-Diagnostics -Diagnostics $windowsProbe.Diagnostics
                $failureDescription = if ($windowsShellDetected) { "the Windows shell" } else { "both Unix and Windows shells" }
                [Console]::Error.WriteLine("$($script:Program): remote dependency probe failed for $failureDescription.")
                Set-PreparationResult -ExitCode 2 -Platform ""
                return
            }
            Write-Diagnostics -Diagnostics $windowsProbe.Diagnostics
        } else {
            Write-Diagnostics -Diagnostics $unixProbe.Diagnostics
        }

        if ($outcome.Ready) {
            Set-PreparationResult -ExitCode 0 -Platform $outcome.Platform
            return
        }

        if (($outcome.PSObject.Properties.Name -contains "InstallUnavailable") -and $outcome.InstallUnavailable) {
            if ($outcome.Platform -eq "windows") {
                [Console]::Error.WriteLine("$($script:Program): persistent remote session unavailable: native Zellij is required on Windows and no supported installer was found.")
            } else {
                [Console]::Error.WriteLine("$($script:Program): persistent remote session unavailable: install tmux, GNU screen, or Zellij manually on the remote host.")
            }
            Set-PreparationResult -ExitCode 127 -Platform $outcome.Platform
            return
        }
        if (!$AllowInstall) {
            Write-MissingDependency -Platform $outcome.Platform
            Set-PreparationResult -ExitCode 127 -Platform $outcome.Platform
            return
        }
        if ($installationAttempted) {
            [Console]::Error.WriteLine("$($script:Program): installation completed, but the dependency is still unavailable in a fresh SSH session.")
            Set-PreparationResult -ExitCode 127 -Platform $outcome.Platform
            return
        }
        if (!(Confirm-Install)) {
            [Console]::Error.WriteLine("$($script:Program): dependency installation declined.")
            Set-PreparationResult -ExitCode 1 -Platform $outcome.Platform
            return
        }

        $installCommand = if ($outcome.Platform -eq "windows") { Get-WindowsInstallCommand } else { Get-UnixInstallCommand }
        if ($outcome.Platform -eq "unix") {
            Invoke-SshLogged -Interactive $true -RemoteCommand $installCommand
            $installResult = $script:LastInteractiveSshResult
        } else {
            $installResult = Invoke-SshLogged -Interactive $false -RemoteCommand $installCommand
        }
        Write-Diagnostics -Diagnostics $installResult.Diagnostics
        if ($installResult.ExitCode -ne 0) {
            if (($installResult.ExitCode -eq 255) -and (Test-SshTransportError -Diagnostics $installResult.TransportDiagnostics)) {
                [Console]::Error.WriteLine("$($script:Program): installation SSH transport was lost; installation state is unknown, so it will not be retried automatically.")
            }
            Set-PreparationResult -ExitCode $installResult.ExitCode -Platform $outcome.Platform
            return
        }
        $installationAttempted = $true
    }
}

function Get-WindowsSessionCommand {
    $sessionLiteral = $script:SessionName.Replace("'", "''")
    $resolver = Get-WindowsZellijResolverScript
    $sessionScript = @"
`$ErrorActionPreference = 'Stop'
`$sessionName = '$sessionLiteral'
`$zellij = Resolve-RemoteZellij
if (`$null -eq `$zellij) {
    throw 'sshp: native Zellij is unavailable on the remote Windows host.'
}
& `$zellij attach --create `$sessionName
"@
    return Convert-ToEncodedPowerShellCommand -ScriptText ($resolver + $sessionScript)
}

function Get-UnixSessionCommand {
    # DELIBERATELY NOT base64-wrapped, unlike the probe and install commands.
    # This script `exec`s tmux/screen/Zellij, which require stdin to be a tty;
    # the `printf %s <b64> | base64 -d | sh` channel hands `sh` a PIPE on stdin
    # and the multiplexer then refuses with "Must be connected to a terminal."
    # (measured under a pty: stdin=tty starts screen, stdin=pipe does not).
    # What keeps this shape safe is that the script carries NO double quote at
    # all -- PowerShell 5.1 word-splits a splatted argument only at a `"`, so a
    # script without one survives as a single argument.  The session name is
    # single-quoted and its value is already restricted to `[A-Za-z0-9_.-]` at
    # argv parse time, so no quote can enter.  There used to be a single-quote
    # escape here that doubled `'` as `'""'` -- it would have INSERTED the very
    # double quotes that break this channel, silently re-opening the A21 word
    # split the moment it ever ran.  Removed.  If the charset guard is ever
    # loosened, the failure must be LOUD, so this function refuses a name that
    # carries any quote rather than transforming it (a `''` rewrite would
    # silently DROP the quote from the session name -- corruption, not safety).
    # `smoke/20` asserts this argument still round-trips as one argv element and
    # that the script still contains no `"`.
    if ($script:SessionName.Contains([string][char]39) -or $script:SessionName.Contains([string][char]34)) {
        throw "sshp: the session name may not contain quotes; the charset guard should have refused it earlier."
    }
    $escapedSession = $script:SessionName
    return @"
if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s '$escapedSession'; fi
if command -v screen >/dev/null 2>&1; then exec screen -xRR -S '$escapedSession'; fi
if command -v zellij >/dev/null 2>&1; then exec zellij attach --create '$escapedSession'; fi
printf '%s\n' 'sshp: remote host has neither tmux, GNU screen, nor Zellij.' >&2
exit 127
"@
}

$script:ReconnectDelay = Convert-ToReconnectDelay -Value $script:ReconnectDelayInput
$arguments = @($args)
$checkOnly = $false
if (($arguments.Count -gt 0) -and ($arguments[0] -eq "--check")) {
    $checkOnly = $true
    if ($arguments.Count -eq 1) {
        $arguments = @()
    } else {
        $arguments = @($arguments[1..($arguments.Count - 1)])
    }
}
if (($arguments.Count -eq 1) -and (($arguments[0] -eq "-h") -or ($arguments[0] -eq "--help"))) {
    Show-Usage
    exit 0
}
if (($arguments.Count -lt 1) -or ($arguments.Count -gt 2)) {
    Show-Usage
    exit 2
}

$script:TargetHost = $arguments[0]
if ([string]::IsNullOrWhiteSpace($script:TargetHost)) {
    Stop-Sshp "SSH host must not be empty"
}
if ($script:TargetHost.StartsWith("-", [System.StringComparison]::Ordinal)) {
    Stop-Sshp "SSH host must not begin with a hyphen"
}
if ($arguments.Count -eq 2) {
    $script:SessionName = $arguments[1]
}
if ($script:SessionName -notmatch '^[A-Za-z0-9_.-]+$') {
    Stop-Sshp "session name must contain only letters, numbers, dots, underscores, or hyphens"
}
if ($script:SessionName.StartsWith("-", [System.StringComparison]::Ordinal)) {
    Stop-Sshp "session name must not begin with a hyphen"
}

$script:SshPath = Resolve-SshPath
$script:PreparationResult = $null
Prepare-Remote -AllowInstall (!$checkOnly)
$preparation = $script:PreparationResult
if ($null -eq $preparation) {
    Stop-Sshp "internal error: remote preparation returned no result"
}
if ($preparation.ExitCode -ne 0) {
    exit $preparation.ExitCode
}
if ($checkOnly) {
    if ($preparation.Platform -eq "windows") {
        [Console]::Out.WriteLine("persistent remote session: Zellij (Windows)")
    } else {
        [Console]::Out.WriteLine("persistent remote session: tmux, GNU screen, or Zellij")
    }
    exit 0
}

$sessionCommand = if ($preparation.Platform -eq "windows") { Get-WindowsSessionCommand } else { Get-UnixSessionCommand }
while ($true) {
    $script:LastInteractiveSshResult = $null
    Invoke-SshLogged -Interactive $true -RemoteCommand $sessionCommand
    $result = $script:LastInteractiveSshResult
    if ($null -eq $result) {
        Stop-Sshp "internal error: interactive SSH invocation returned no result"
    }
    Write-Diagnostics -Diagnostics $result.Diagnostics
    if ($result.ExitCode -ne 255) {
        exit $result.ExitCode
    }
    if (!(Test-SshTransportError -Diagnostics $result.TransportDiagnostics)) {
        exit $result.ExitCode
    }
    [Console]::Error.WriteLine("$($script:Program): SSH transport lost; reconnecting in $($script:ReconnectDelay)s...")
    Start-Sleep -Seconds $script:ReconnectDelay
}
