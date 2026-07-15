@echo off
REM Wrapper for rendezvous.ps1 so it runs regardless of PowerShell's script execution policy.
REM Forwards arguments, e.g.  rendezvous.cmd -Port 9000
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rendezvous.ps1" %*
