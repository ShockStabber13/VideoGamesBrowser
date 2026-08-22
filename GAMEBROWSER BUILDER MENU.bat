@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title GameBrowser - Build / Share Menu

:menu
cls
echo ============================================================
echo               GAMEBROWSER BUILD / SHARE MENU
echo ============================================================
echo.
echo Choose package:
echo   1. Database only ^(DAT-backed systems^)
echo   2. Daily Chunks only
echo   3. Windows Steam Index only
echo   4. Database + Daily Chunks
echo   5. ALL THREE
echo   Q. Quit
echo.
choice /c 12345Q /n /m "Package: "
if errorlevel 6 exit /b 0
if errorlevel 5 set "TARGET=All"
if errorlevel 4 if not errorlevel 5 set "TARGET=Both"
if errorlevel 3 if not errorlevel 4 set "TARGET=Windows"
if errorlevel 2 if not errorlevel 3 set "TARGET=DailyChunks"
if errorlevel 1 if not errorlevel 2 set "TARGET=Database"

echo.
echo Build package now?
echo   Y. Build / refresh it
echo   N. NO BUILD - use existing ZIP only
choice /c YN /n /m "Build: "
if errorlevel 2 (set "DOBUILD=0") else (set "DOBUILD=1")

echo.
echo Share package over LAN after that?
echo   Y. Start download server
echo   N. NO SHARE - leave files in _android only
choice /c YN /n /m "Share: "
if errorlevel 2 (set "DOSHARE=0") else (set "DOSHARE=1")

if "%DOBUILD%"=="0" if "%DOSHARE%"=="0" (
  echo.
  echo Nothing selected: NO BUILD + NO SHARE would do nothing.
  pause
  goto menu
)

set "ARGS=-Target %TARGET%"
if "%DOBUILD%"=="1" set "ARGS=%ARGS% -Build"
if "%DOSHARE%"=="1" set "ARGS=%ARGS% -Share"

echo.
echo ------------------------------------------------------------
echo Target: %TARGET%
echo Build : %DOBUILD%
echo Share : %DOSHARE%
echo ------------------------------------------------------------
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_tools\Run Build Share.ps1" %ARGS%
if errorlevel 1 (
  echo.
  echo ERROR: Action failed.
  pause
  exit /b 1
)
if "%DOSHARE%"=="0" pause
exit /b 0
