GAMEBROWSER HYBRID - SWITCH + WINDOWS DAILY CHUNK RESOLVER FIX
================================================================

Base remains:
  - V3.4 database / DAT builder
  - V3.4 IGDB updated_at incremental patch
  - V3.6 expanded Daily Chunk library

This patch changes ONLY Daily Chunk resolution/support data.

Nintendo Switch / IGDB-only fix
--------------------------------
- The V3.6 resolver filtered /games using release_dates.platform.
- It now filters the game's platforms relation directly: platforms = (<platform id>).
- Exact normalized canonical names and exact normalized IGDB alternative names are accepted.
- Matching still fails closed when zero or multiple IGDB games are exact matches.

Windows fixes
-------------
- Windows Daily Chunk cache keys are now title-based consistently.
- Existing V1 Steam mappings are migrated by title instead of being stranded behind IGDB-ID keys.
- A V2 Windows cache contains the 200 current curated titles and 200 genuine Steam AppIDs.
- Alan Wake is seeded as Steam AppID 108710.
- Stale V1 controllerChecked=true + blank-support entries are forced to refresh once.
- Steam appdetails metadata/controller checks use one AppID per request to avoid HTTP 400 multi-AppID failures.

Expected first test
-------------------
Run:
  BUILD DAILY CHUNKS - NO SHARE.bat

The previous bad indicators were:
  Nintendo Switch: 39/200
  Windows indexed: 167 total | 0 Full | 1 Partial | 166 All-only/unflagged

After this patch, Windows should index all 200 curated Steam games before controller classification.
Switch should resolve substantially more than 39; its final count is determined live by IGDB and remains strict.
