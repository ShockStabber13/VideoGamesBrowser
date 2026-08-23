IGDB PLATFORM INDEX - PID FIX
=============================

Fixes the PowerShell error:
  Cannot overwrite variable PID because it is read-only or constant.

Cause:
PowerShell variable names are case-insensitive, so $pid collides with the built-in read-only $PID variable.

Install:
Extract this ZIP into the root of your VideoGamesBrowser Git repository and allow it to replace:
  _tools\Build IGDB Platform Index.ps1

Then run:
  git add -A
  git commit -m "Fix IGDB platform index PID variable"
  git push origin main

Then rerun:
  GitHub -> Actions -> Update IGDB Platform Index -> Run workflow
