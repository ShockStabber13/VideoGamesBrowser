# VideoGamesBrowser daily data releases

Daily schedule (Asia/Singapore, UTC+08:00; every day):

- 02:37 — Daily Chunks: refreshes GameBrowser-DailyChunks files in dat-catalogs-latest.
- 04:37 — DAT Catalogs: dispatched from the known-good IGDB scheduler to avoid dormant DAT schedules; refreshes the stable DAT package; creates dat-catalogs-YYYYMMDD including Daily Chunks.
- 06:37 — Windows Indexes: dispatched from the known-good IGDB scheduler to avoid dormant Windows schedules; rebuilds five country ZIPs; creates windows-YYYYMMDD.
- 08:37 — IGDB Platform Index: its own daily scheduled build; refreshes the index; creates igdb-index-YYYYMMDD.
- 10:37 — Featured Games: republishes curated data; creates featured-YYYYMMDD.

The four permanent *-latest release tags and asset URLs remain unchanged for existing app clients.
A dated release is created or updated on successful completion of the corresponding job. Schedules are intended to start 2 hours apart, but GitHub Actions may delay jobs and durations can differ.
Daily Chunks and DAT Catalogs share one release group.

Public repositories can have scheduled workflows disabled after 60 days with no commit activity. The IGDB workflow creates an empty keepalive commit only if the latest main-branch commit is at least 40 days old.

The IGDB workflow is the schedule owner for the 04:37 and 06:37 dispatches; the two target workflows retain manual workflow_dispatch, with their own duplicate schedules removed. The schedule owner re-enables them before dispatching with actions:write permissions. Changing the IGDB scheduler file also triggers a one-time push-based bootstrap to validate both target workflow dispatches.
