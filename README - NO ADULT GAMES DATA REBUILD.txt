VideoGamesBrowser data builder - no-adult rebuild

This copy keeps the current database/builder behavior but excludes explicit adult sexual titles during new builds:

- Steam Windows indexes: skips content descriptor IDs 3 and 4.
- Steam cache path is versioned to windows-steam-index-no-adult-v1 so old completed caches are not silently reused.
- IGDB catalogs, incremental maps, direct browsing and Daily Chunk resolution exclude theme 42 (Erotic).
- The IGDB discovery schema is bumped to games-platform-v2-no-erotic, forcing a one-time clean platform-map rebuild.

Use this builder for the next database/index build so old adult entries are removed from packaged data.
