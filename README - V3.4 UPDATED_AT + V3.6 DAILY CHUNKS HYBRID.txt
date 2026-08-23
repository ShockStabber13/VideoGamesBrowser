GameBrowser Database Builder - V3.4 UpdatedAt + V3.6 Daily Chunks Hybrid
======================================================================

PURPOSE
-------
This build keeps the proven V3.4 database/DAT builder and applies the
IGDB updated_at incremental-only patch, while transplanting ONLY V3.6's
expanded Daily Chunk subsystem.

KEPT FROM V3.4
--------------
- Main database builder
- DAT update/build logic
- Conservative DAT matching
- Cache invalidation behavior
- Existing build/share menu and BAT files

APPLIED PATCH
-------------
- _tools\Local Web Server.ps1 from:
  V3.4-to-IGDB-UpdatedAt-Incremental-ONLY-PATCH
- This adds the IGDB updated_at incremental behavior.

TRANSPLANTED FROM V3.6
----------------------
- _tools\Build Daily Chunks.ps1
- _tools\Package Daily Chunks OFFLINE.ps1
- daily-chunks.json
- daily-chunk-game-specific.json
- daily-chunk-series.json (same content as V3.4, copied for completeness)
- Daily Chunk curation/validation reports

NOT TRANSPLANTED FROM V3.6
-------------------------
- V3.6 main database builder changes (none are needed here)
- Any V3.6 prebuilt Android output

IMPORTANT
---------
The old V3.4 prebuilt Daily Chunk package was intentionally removed from
_android so it cannot be shared by mistake.

For a fresh Daily Chunk package:

  1. BUILD DAILY CHUNKS - NO SHARE.bat
  2. SHARE DAILY CHUNKS - NO BUILD.bat

Or use:

  BUILD AND SHARE DAILY CHUNKS.bat

The build uses your local IGDB credentials where required and validates
Daily Chunk membership against the applicable platform source before
creating daily_chunk_index.json and GameBrowser-DailyChunks.zip.

ANDROID APP
-----------
Designed for the V48.16 DailyChunk-Package-Only Android build, where the
packaged daily_chunk_index.json is authoritative for Daily Chunk membership.
