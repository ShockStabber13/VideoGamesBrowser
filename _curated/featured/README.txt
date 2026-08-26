CURATED FEATURED GAMES
======================

GitHub does not choose Featured membership. Put your curated file here:

  featured_game_index.json

The publishing workflow accepts either an older rich row or the compact row below, but the
release ZIP is ALWAYS rewritten to exactly these fields:

  title
  source              Steam | IGDB:<platform>
  id                  Steam AppID or IGDB game ID
  rating              Steam review % or IGDB rating
  releaseDateEpoch    Unix seconds

No poster, summary, genres, controller support, year, order, or other metadata is published in
the Featured direct index.

Commit + push it. "Update Featured Games" validates, compacts, packages and publishes:

  https://github.com/ShockStabber13/VideoGamesBrowser/releases/download/featured-latest/GameBrowser-Featured.zip

Ratings are SORT KEYS only. They never choose Featured membership.
