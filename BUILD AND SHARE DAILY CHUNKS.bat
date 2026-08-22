@echo off
setlocal
cd /d "%~dp0"
title GameBrowser - Build + Share Daily Chunks
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_tools\Run Build Share.ps1" -Target DailyChunks -Build -Share
if errorlevel 1 (
  echo.
  echo ERROR: Action failed.
  pause
  exit /b 1
)
