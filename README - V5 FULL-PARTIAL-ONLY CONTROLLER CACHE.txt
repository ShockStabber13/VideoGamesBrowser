GameBrowser Daily Chunks V5 - Full/Partial-only controller cache

This patch keeps the Windows Daily Chunk cache aligned with the three Windows platforms:

Windows (All)
- Uses every mapped Windows Daily Chunk game.
- The cache does not need a "None" controller category.
- The Android Details page determines/displays controller support live when needed.

Windows (Partial Controller Support)
- Uses only entries classified "Partial Controller Support".

Windows (Full Controller Support)
- Uses only entries classified "Full Controller Support".

For a Steam game with neither Full nor Partial controller flags:
- controllerSupport stays blank.
- controllerChecked=true is stored internally so the builder does not re-check the same game every run.

Old cache entries containing controllerSupport="None" are automatically migrated to:
- controllerSupport=""
- controllerChecked=true
