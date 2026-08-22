COMPLETE GAMEBROWSER DATABASE BUILDER
=====================================

This package is the current merged builder so we stay on one track.

Base included:
  V3.4 UpdatedAt incremental builder
  V3.6 Daily Chunks hybrid logic
  Windows Steam index builder with resume/progress
  Existing DAT-backed database/Daily Chunk build and share scripts
  Five-country Windows package scripts

Main scripts:
  BUILD DATABASE - NO SHARE.bat
    Builds GameBrowser-Data.zip only.

  BUILD DAILY CHUNKS - NO SHARE.bat
    Builds GameBrowser-DailyChunks.zip only.

  BUILD WINDOWS INDEX - NO SHARE.bat
    Builds one Windows package using steam-config.json CountryCode, or system country if not set.

  BUILD WINDOWS INDEX - ALL FIVE COUNTRIES - NO SHARE.bat
    Builds all five Windows country packages in one run:
      _android\GameBrowser-Windows-US.zip
      _android\GameBrowser-Windows-UK.zip   (Steam country code GB)
      _android\GameBrowser-Windows-GB.zip   (alias for UK)
      _android\GameBrowser-Windows-SG.zip
      _android\GameBrowser-Windows-CA.zip
      _android\GameBrowser-Windows-MY.zip
    It also copies SG to _android\GameBrowser-Windows.zip for old Android builds.

  SHARE WINDOWS COUNTRY ZIPS - NO BUILD.bat
    Serves the five country Windows ZIPs over LAN after they are built.

Optional one-country scripts:
  BUILD WINDOWS INDEX - US - NO SHARE.bat
  BUILD WINDOWS INDEX - UK GB - NO SHARE.bat
  BUILD WINDOWS INDEX - SG - NO SHARE.bat
  BUILD WINDOWS INDEX - CANADA CA - NO SHARE.bat
  BUILD WINDOWS INDEX - MALAYSIA MY - NO SHARE.bat

Country codes:
  US = United States
  GB = United Kingdom / Great Britain
  SG = Singapore
  CA = Canada
  MY = Malaysia

Resume/cache:
  Each country keeps its own checkpoint under:
    _cache\windows-steam-index\US
    _cache\windows-steam-index\GB
    _cache\windows-steam-index\SG
    _cache\windows-steam-index\CA
    _cache\windows-steam-index\MY

Important:
  The five-country script temporarily changes steam-config.json while building.
  It restores your original steam-config.json at the end.

Recommended next step:
  Run BUILD WINDOWS INDEX - ALL FIVE COUNTRIES - NO SHARE.bat
  Then send _android\GameBrowser-Windows-Country-Packages-Report.txt if anything looks wrong.
