DAT-backed full release-date sorting update

- Build Android Database.ps1 now writes releaseDateEpoch into game_catalog.json.
- Static DAT-backed metadata backfill asks IGDB for release_dates.platform + release_dates.date.
- For each game it stores the earliest dated release on the selected platform, preserving year/month/day.
- If IGDB has no dated release for that platform, it falls back to first_release_date.
- Existing platform caches missing releaseDateEpoch are automatically backfilled during the next database build.
- Android V48.54 uses this epoch for instant local Newest/Oldest sorting.
