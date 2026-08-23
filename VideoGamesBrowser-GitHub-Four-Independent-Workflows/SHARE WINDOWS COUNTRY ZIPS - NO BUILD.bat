@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_tools\Windows Country Zip Server.ps1"
if errorlevel 1 (echo.&echo ERROR: Action failed.&pause)
