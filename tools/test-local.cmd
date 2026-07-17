@echo off
REM Double-click-friendly: run both sides of an online match on this one PC (two windows).
REM   test-local.cmd
REM   test-local.cmd -Game "D:\path\to\MKDD.rvz"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test-local.ps1" %*
