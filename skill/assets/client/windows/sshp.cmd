@echo off
setlocal DisableDelayedExpansion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sshp.ps1" %*
exit /b %ERRORLEVEL%
