@echo off
setlocal DisableDelayedExpansion
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0agentq.ps1" %*
exit /b %ERRORLEVEL%
