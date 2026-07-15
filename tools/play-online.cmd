@echo off
REM Wrapper for play-online.ps1 so it runs regardless of PowerShell's script execution policy.
REM Forwards arguments, e.g.  play-online.cmd -Host    or    play-online.cmd -Join 100.1.2.3
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0play-online.ps1" %*
