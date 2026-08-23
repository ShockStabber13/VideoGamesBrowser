GAMEBROWSER BUILDER - SEPARATED BUILD / SHARE WORKFLOW
=========================================================

The Database and Daily Chunks are now independent packages.
Build and Share are also independent actions.

EASIEST METHOD
--------------
Run:
  GAMEBROWSER BUILDER MENU.bat

It asks three separate questions:
  1. What?   Database / Daily Chunks / Both
  2. Build?  Build / No Build
  3. Share?  Share / No Share

ONE-CLICK BAT FILES
-------------------
BUILD ONLY (creates/updates ZIP, does NOT start LAN server)
  BUILD DATABASE - NO SHARE.bat
  BUILD DAILY CHUNKS - NO SHARE.bat
  BUILD BOTH - NO SHARE.bat

SHARE EXISTING ONLY (ZERO BUILD; does not alter ZIPs)
  SHARE DATABASE - NO BUILD.bat
  SHARE DAILY CHUNKS - NO BUILD.bat
  SHARE BOTH - NO BUILD.bat

BUILD + SHARE
  BUILD AND SHARE DATABASE.bat
  BUILD AND SHARE DAILY CHUNKS.bat
  BUILD AND SHARE BOTH.bat

WHAT EACH PACKAGE MEANS
-----------------------
Database:
  _android\GameBrowser-Data.zip
  Contains DAT-backed platform catalogs only.
  Building Database refreshes the DAT-backed IGDB + DAT intersections from
  the local DAT files, then packages GameBrowser-Data.zip.
  It does NOT build Daily Chunks.

Daily Chunks:
  _android\GameBrowser-DailyChunks.zip
  Independent Daily Chunk package and direct index.
  Building Daily Chunks does NOT rebuild GameBrowser-Data.zip or DAT catalogs.

No Build:
  Uses the ZIP that already exists in _android exactly as-is.
  No IGDB scan, DAT scan, Steam lookup, or repack is performed.

No Share:
  Does not start the LAN download server. The built ZIP remains in _android.

SHARE IS NOW STRICTLY SEPARATED
-------------------------------
Database-only share exposes only GameBrowser-Data.zip + its manifest.
Daily-Chunks-only share exposes only GameBrowser-DailyChunks.zip + its manifest.
Both share exposes both packages.

DAT updates remain separate:
  UPDATE DATS.bat
  FORCE UPDATE DATS.bat
