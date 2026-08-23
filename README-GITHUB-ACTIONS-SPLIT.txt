VideoGamesBrowser - Split GitHub Actions
========================================

There are four independent workflows under .github/workflows:

1. Update DAT Catalogs
   Publishes:
   https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/dat-catalogs-latest/GameBrowser-Data.zip

2. Update Daily Chunks
   Publishes:
   https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/dat-catalogs-latest/GameBrowser-DailyChunks.zip

3. Update Featured Games
   Publishes:
   https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/featured-latest/GameBrowser-Featured.zip

4. Update Windows Indexes
   Publishes exactly these five files:
   https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/windows-latest/GameBrowser-Windows-US.zip
   https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/windows-latest/GameBrowser-Windows-GB.zip
   https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/windows-latest/GameBrowser-Windows-SG.zip
   https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/windows-latest/GameBrowser-Windows-CA.zip
   https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/windows-latest/GameBrowser-Windows-MY.zip

Featured policy
---------------
featured-games-curated.json is the only source of Featured membership.
GitHub validates those choices but never auto-fills them and never ranks/selects them by IGDB rating or Steam review score.

First-run dependency
--------------------
Run Update DAT Catalogs once before the first Daily Chunks or Featured run so the shared validated platform catalog cache exists.
