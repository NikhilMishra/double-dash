@echo off
REM Double-click-friendly launcher. Runs play-online.ps1 regardless of PowerShell's execution policy.
REM Examples:
REM   play-online.cmd -Host
REM   play-online.cmd -Join 100.101.102.103 -Game "D:\path\to\MKDD.rvz"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0play-online.ps1" %*
