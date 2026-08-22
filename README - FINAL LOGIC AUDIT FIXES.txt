FINAL LOGIC AUDIT FIXES
=======================

1. Windows builder mode is now truthfully "steam".
2. Static GameBrowser-Data.zip includes only DAT-backed modes; Steam and IGDB-only platforms remain live.
3. DAT-backed IGDB discovery now starts from games.platforms, then applies IGDB AND (DAT1 OR DAT2 OR ...).
   release_dates no longer decides catalog membership.
4. The first database build performs a one-time games.platforms map migration for DAT-backed systems.
5. If ANY DAT-backed platform refresh fails, the old cache is preserved but the database build exits nonzero,
   so Run Build Share does not package a mixed-age GameBrowser-Data.zip.
6. Daily Chunk architecture is unchanged.
7. BUILD DATABASE no longer runs legacy Daily Chunk-priority preparation; Daily Chunks remain a separate package.
