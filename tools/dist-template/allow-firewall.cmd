@echo off
REM Double-click this ONCE on the machine that hosts, to let Double Dash Online receive connections
REM through Windows Firewall. Windows will ask for administrator permission -- click Yes.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0allow-firewall.ps1"
