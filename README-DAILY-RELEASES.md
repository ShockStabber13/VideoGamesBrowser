# VideoGamesBrowser daily data releases

Daily schedule (Asia/Singapore, UTC+08:00; every day):

- 02:37 — Daily Chunks: refreshes GameBrowser-DailyChunks files in dat-catalogs-latest.
- 04:37 — DAT Catalogs: refreshes the stable DAT package; creates dat-catalogs-YYYYMMDD including the most recent Daily Chunks files.
- 06:37 — Windows Indexes: rebuilds five country ZIPs; creates windows-YYYYMMDD.
- 08:37 — IGDB Platform Index: refreshes the index; creates igdb-index-YYYYMMDD.
- 10:37 — Featured Games: republishes curated data; creates featured-YYYYMMDD.

The four permanent *-latest release tags and asset URLs remain unchanged for existing app clients.
A dated release is created or updated on successful completion of the corresponding job. Schedules are intended to start 2 hours apart, but GitHub Actions may delay jobs and durations can differ.
Daily Chunks and DAT Catalogs share one release group.

Public repositories can have scheduled workflows disabled after 60 days with no commit activity. The IGDB workflow creates an empty keepalive commit only if the latest main-branch commit is at least 40 days old.
