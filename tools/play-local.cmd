@echo off
REM Wrapper for play-local.ps1 so it runs regardless of PowerShell's script
REM execution policy (batch files aren't restricted). Forwards any arguments,
REM e.g.  play-local.cmd -InputDelay 2
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0play-local.ps1" %*
