VIDEO GAMES BROWSER - IGDB PLATFORM INDEX WORKFLOW
=================================================

Adds a fifth independent GitHub Action:
  Update IGDB Platform Index

Runs:
  - Manually from GitHub Actions
  - Daily at 4:30 AM Asia/Singapore

Uses existing GitHub Secrets:
  IGDB_CLIENT_ID
  IGDB_CLIENT_SECRET

Publishes:
  https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/igdb-index-latest/GameBrowser-IGDB-Platform-Index.zip

ZIP contents:
  igdb-games-platforms.csv
  igdb-platforms.csv
  manifest.json

The main CSV contains one row per game/platform combination with:
  game_id
  title
  slug
  platform_id
  platform_name
  platform_abbreviation
  release_date
  release_year
  first_release_date
  first_release_year
  game_type_id
  version_parent_id
  updated_at

No posters, screenshots, descriptions or ratings are downloaded.

TO INSTALL
----------
Extract this patch into the root of your existing VideoGamesBrowser Git repo,
then run in PowerShell:

  git add -A
  git commit -m "Add IGDB platform index workflow"
  git push origin main

Then go to GitHub -> Actions -> Update IGDB Platform Index -> Run workflow.
