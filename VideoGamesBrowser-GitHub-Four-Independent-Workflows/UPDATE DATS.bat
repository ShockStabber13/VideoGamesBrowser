@echo off
cd /d "%~dp0"
title Daily Chunk Games - Update Preservation DATs

echo ============================================================
echo                 UPDATE PRESERVATION DATS
echo ============================================================
echo.
echo This downloads/refreshes the configured preservation DAT files.
echo Files are stored in the local DATs folder and reused by the website.
echo.
echo The website itself never downloads preservation DATs.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_tools\Local Web Server.ps1" -UpdatePreservationDats

echo.
pause
