WINDOWS STEAM INDEX - PC FIRST BUILD

This builder now has a separate Windows pipeline. It does NOT mix Windows into DAT matching.

Run: BUILD WINDOWS INDEX - NO SHARE.bat

What it does:
- Pages Steam IStoreQueryService/Query using game-type filters.
- Uses deterministic sort=2 (AppID / Identifier order).
- Keeps only Windows-compatible StoreQuery records when platform metadata is present.
- Stores only lightweight list metadata needed by the Android app.
- Shows processed/total, percent, Windows game count, batch, elapsed time, speed and estimated remaining time.
- Saves every successful batch plus state.json under _cache\windows-steam-index\<COUNTRY>\.
- If stopped, simply run BUILD WINDOWS INDEX - NO SHARE.bat again. It resumes from the last completed raw offset.
- Creates _android\GameBrowser-Windows.zip only when the full crawl is complete.

Once a build is complete, ordinary reruns do not crawl all 180k-ish records again. Use FORCE REBUILD WINDOWS INDEX.bat only when you intentionally want another complete PC crawl. Android handles normal incremental updates after import.

Convenience BATs:
- BUILD WINDOWS INDEX - NO SHARE.bat
- SHARE WINDOWS INDEX - NO BUILD.bat
- BUILD AND SHARE WINDOWS INDEX.bat
- FORCE REBUILD WINDOWS INDEX.bat
- BUILD ALL THREE - NO SHARE.bat
- SHARE ALL THREE - NO BUILD.bat
- BUILD AND SHARE ALL THREE.bat

The original Database + Daily Chunks BATs still mean those two packages only.
