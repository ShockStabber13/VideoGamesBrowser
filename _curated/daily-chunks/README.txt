CURATED DAILY CHUNKS
====================

Place these curated files in this folder:

  daily_chunks.json
  daily_chunk_series.json
  daily_chunk_index.json

The direct daily_chunk_index.json release is ALWAYS rewritten to exactly:

  title
  source              Steam | IGDB:<platform>
  id                  Steam AppID or IGDB game ID
  rating              Steam review % or IGDB rating
  releaseDateEpoch    Unix seconds
  dailyChunk
  minutes
  chunkability

No poster, summary, genres, controller support, year, order, chunk rule/provenance, or other rich
metadata is published in the direct index. Rich chunk provenance may exist in the curated source
for validation, but GitHub strips it before packaging.
