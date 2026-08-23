VideoGamesBrowser GitHub Actions Setup
=====================================

Required repository secrets:
- IGDB_CLIENT_ID
- IGDB_CLIENT_SECRET
- STEAM_API_KEY

Independent workflows:
- Update DAT Catalogs
- Update Daily Chunks
- Update Featured Games
- Update Windows Indexes

Run Update DAT Catalogs once before the first Daily Chunks or Featured run so the shared validated platform-catalog cache exists.

Permanent release URLs:
- https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/dat-catalogs-latest/GameBrowser-Data.zip
- https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/dat-catalogs-latest/GameBrowser-DailyChunks.zip
- https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/featured-latest/GameBrowser-Featured.zip
- https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/windows-latest/GameBrowser-Windows-US.zip
- https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/windows-latest/GameBrowser-Windows-GB.zip
- https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/windows-latest/GameBrowser-Windows-SG.zip
- https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/windows-latest/GameBrowser-Windows-CA.zip
- https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/windows-latest/GameBrowser-Windows-MY.zip
