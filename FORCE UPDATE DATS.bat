@echo off
cd /d "%~dp0"
title Daily Chunk Games - FORCE Update Preservation DATs

echo ============================================================
echo              FORCE UPDATE PRESERVATION DATS
echo ============================================================
echo.
echo This forces a refresh attempt for EVERY configured DAT source.
echo Normal UPDATE DATS.bat is recommended for routine use because it resumes
echo failed/missing files without redownloading recent successful files.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_tools\Local Web Server.ps1" -ForceDatRefresh

echo.
pause
