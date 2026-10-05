@echo off
REM Edge Downgrade - Enhanced Automated Version
REM Double-click to run with full automation and aggressive freeze
REM No manual work needed - handles all Windows versions

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Edge-Downgrade-OneClick-Enhanced.ps1" %*
pause
