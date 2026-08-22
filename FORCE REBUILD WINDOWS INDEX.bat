@echo off
cd /d "%~dp0"
echo This deletes only the resumable Windows StoreQuery batch cache and starts the Windows index from 0.
echo The existing _android\GameBrowser-Windows.zip is not replaced until the new build completes.
echo.
choice /c YN /n /m "Force full Windows rebuild? [Y/N]: "
if errorlevel 2 exit /b 0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_tools\Build Windows Steam Index.ps1" -ForceRebuild
if errorlevel 1 (echo.&echo ERROR: Windows index rebuild failed.)
pause
