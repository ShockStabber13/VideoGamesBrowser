@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_tools\Build Windows Steam Index All Countries.ps1" -ForceRebuild
if errorlevel 1 (echo.&echo ERROR: Action failed.)
pause
