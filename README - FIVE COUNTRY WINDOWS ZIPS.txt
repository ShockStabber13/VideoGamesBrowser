FIVE COUNTRY WINDOWS ZIP BUILDER
================================

Drop these files into the ROOT of your existing GameBrowser Database Builder folder.
They do not replace your existing database/Daily Chunk build scripts.

Countries built:
  US = United States
  UK = United Kingdom Steam country code GB
  SG = Singapore
  CA = Canada
  MY = Malaysia

Run:
  BUILD WINDOWS INDEX - ALL FIVE COUNTRIES - NO SHARE.bat

This creates:
  _android\GameBrowser-Windows-US.zip
  _android\GameBrowser-Windows-UK.zip   (manifest country = GB)
  _android\GameBrowser-Windows-GB.zip   (alias copy for UK/GB)
  _android\GameBrowser-Windows-SG.zip
  _android\GameBrowser-Windows-CA.zip
  _android\GameBrowser-Windows-MY.zip

It also copies the SG package to:
  _android\GameBrowser-Windows.zip

Why SG as the generic file?
  It keeps older Android builds compatible with your original Singapore base package.

Resume behavior:
  Each country uses its own cache/checkpoint under:
    _cache\windows-steam-index\US
    _cache\windows-steam-index\GB
    _cache\windows-steam-index\SG
    _cache\windows-steam-index\CA
    _cache\windows-steam-index\MY

If the script is stopped, run it again. Completed countries rebuild their ZIP quickly from cache;
incomplete countries continue from their saved StoreQuery offset.

Force rebuild:
  FORCE REBUILD WINDOWS INDEX - ALL FIVE COUNTRIES.bat

Share all country ZIPs:
  SHARE WINDOWS COUNTRY ZIPS - NO BUILD.bat

