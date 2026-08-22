@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_tools\Build Windows Steam Index One Country.ps1" -Country CA -ForceRebuild
if errorlevel 1 (echo.&echo ERROR: Action failed.)
pause
