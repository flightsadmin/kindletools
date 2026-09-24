@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0KindleManager.ps1" %*
if errorlevel 1 pause
