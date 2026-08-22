@echo off
setlocal
cd /d "%~dp0"
title GameBrowser - Share Database + Daily Chunks - No Build
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_tools\Run Build Share.ps1" -Target Both -Share
if errorlevel 1 (
  echo.
  echo ERROR: Action failed.
  pause
  exit /b 1
)
