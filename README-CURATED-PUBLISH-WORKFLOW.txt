VIDEOGAMESBROWSER - SIMPLIFIED CURATION/PUBLISH WORKFLOW
======================================================

SCHEDULED / OBJECTIVE DATA
--------------------------
04:30 Asia/Singapore  Update IGDB Platform Index
05:30 Asia/Singapore  Update DAT Catalogs
08:30 Asia/Singapore  Update Windows Indexes

CURATED / ON PUSH ONLY
----------------------
Daily Chunks and Featured no longer run on a daily schedule.
They run only when their curated JSON files are pushed (or when manually dispatched).

Daily Chunks source folder:
  _curated\daily-chunks\

Featured source folder:
  _curated\featured\

Normal update routine:
  git add -A
  git commit -m "Update curated game data"
  git push origin main

Permanent app-facing URLs stay unchanged:
  https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/dat-catalogs-latest/GameBrowser-DailyChunks.zip
  https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/featured-latest/GameBrowser-Featured.zip

IGDB SCRIPT FIX INCLUDED
------------------------
1. Uses $platformId rather than PowerShell's reserved read-only $PID variable.
2. Workflow no longer checks $LASTEXITCODE after invoking the .ps1 directly.
   PowerShell exceptions and explicit output-file checks determine success.
