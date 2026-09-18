@echo off
REM Double-click this. It elevates itself and runs the whole downgrade unattended.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Edge-Downgrade-OneClick.ps1" %*
