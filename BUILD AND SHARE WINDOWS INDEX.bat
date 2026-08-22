@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_tools\Run Build Share.ps1" -Target Windows -Build -Share
if errorlevel 1 (echo.&echo ERROR: Action failed.&pause)
