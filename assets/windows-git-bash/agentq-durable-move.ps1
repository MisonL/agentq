[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class AgentQDurabilityNative
{
    private static readonly IntPtr InvalidHandleValue = new IntPtr(-1);
    private const uint GenericRead = 0x80000000;
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint FileShareDelete = 0x00000004;
    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint MoveFileReplaceExisting = 0x00000001;
    private const uint MoveFileWriteThrough = 0x00000008;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FlushFileBuffers(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileEx(
        string existingFileName,
        string newFileName,
        uint flags);

    private static IntPtr OpenForFlush(string path, bool directory)
    {
        // FlushFileBuffers requires a handle opened with GENERIC_WRITE.  A
        // read-only handle fails with ERROR_ACCESS_DENIED (5) -- verified on
        // Windows 10 for both the directory opened with FILE_FLAG_BACKUP_SEMANTICS
        // and the just-written file.  Both paths therefore need write access.
        uint access = GenericRead | GenericWrite;
        uint flags = directory ? FileFlagBackupSemantics : 0;
        IntPtr handle = CreateFile(
            path,
            access,
            FileShareRead | FileShareWrite | FileShareDelete,
            IntPtr.Zero,
            OpenExisting,
            flags,
            IntPtr.Zero);
        if (handle == InvalidHandleValue)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFile failed");
        }
        return handle;
    }

    private static void FlushPath(string path, bool directory)
    {
        IntPtr handle = OpenForFlush(path, directory);
        try
        {
            if (!FlushFileBuffers(handle))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "FlushFileBuffers failed");
            }
        }
        finally
        {
            if (!CloseHandle(handle))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CloseHandle failed");
            }
        }
    }

    public static void MoveAndFlush(string sourcePath, string destinationPath, string destinationDirectory)
    {
        FlushPath(sourcePath, false);
        if (!MoveFileEx(sourcePath, destinationPath, MoveFileReplaceExisting | MoveFileWriteThrough))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "MoveFileEx failed");
        }
        FlushPath(destinationDirectory, true);
    }
}
"@

$sourcePath = [System.IO.Path]::GetFullPath($SourcePath)
$destinationPath = [System.IO.Path]::GetFullPath($DestinationPath)
$destinationDirectory = [System.IO.Path]::GetFullPath($DestinationDirectory)

[AgentQDurabilityNative]::MoveAndFlush($sourcePath, $destinationPath, $destinationDirectory)
