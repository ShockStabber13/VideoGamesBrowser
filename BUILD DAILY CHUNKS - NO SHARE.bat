@echo off
setlocal
cd /d "%~dp0"
title GameBrowser - Build Daily Chunks - No Share
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_tools\Run Build Share.ps1" -Target DailyChunks -Build
if errorlevel 1 (
  echo.
  echo ERROR: Action failed.
  pause
  exit /b 1
)
echo.
pause
