#!/usr/bin/env python3
"""Preserve existing published curated packages while merging verified, hand-picked additions.

This script is run by GitHub Actions. It does not download or package ROMs.
A failed/ambiguous identification is skipped, never substituted with a guessed game.
"""
import csv
import io
import json
import re
import sys
import unicodedata
import zipfile
from collections import defaultdict
from pathlib import Path

# GitHub Windows runners may default to cp1252; game titles contain Unicode characters.
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

ROOT = Path(__file__).resolve().parents[1]
INPUTS = ROOT / "_curated" / "_build_inputs"
PLATFORMS = json.loads((ROOT / "platforms.json").read_text(encoding="utf-8-sig"))["platforms"]
CONFIG = {p["name"]: p for p in PLATFORMS}
SKIPPED = defaultdict(int)

def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))

def zip_json(path, name):
    with zipfile.ZipFile(path) as archive:
        return json.loads(archive.read(name).decode("utf-8-sig"))

def norm(text):
    text = unicodedata.normalize("NFKD", str(text or ""))
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", " ", text.casefold()).strip()

def rows(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in ("games", "entries", "items", "index"):
            if isinstance(value.get(key), list):
                return value[key]
    raise ValueError("Expected a game index JSON array")

def identity(entry):
    source = str(entry.get("source") or "")
    identifier = entry.get("id")
    if source == "Steam" and str(identifier).isdigit():
        return ("Steam", int(identifier))
    if source.startswith("IGDB:") and str(identifier).isdigit():
        return (source, int(identifier))
    if str(entry.get("steamAppId") or "").isdigit():
        return ("Steam", int(entry["steamAppId"]))
    if entry.get("platform") and str(entry.get("igdbId") or "").isdigit():
        game_id = int(entry["igdbId"])
        if game_id > 0:
            return ("IGDB:" + str(entry["platform"]), game_id)
    return None

def validated_existing(original, label):
    result, seen = [], set()
    for entry in original:
        ident = identity(entry)
        if not ident or ident in seen:
            raise ValueError(label + " existing release has invalid/duplicate IDs; refusing to overwrite it")
        seen.add(ident)
        result.append(entry)
    if not result:
        raise ValueError(label + " existing release contains no valid entries")
    return result, seen

def make_platform_lookup():
    lookup = defaultdict(set)
    memberships = set()
    path = INPUTS / "GameBrowser-IGDB-Platform-Index.zip"
    with zipfile.ZipFile(path) as archive:
        with archive.open("igdb-games-platforms.csv") as file:
            for row in csv.DictReader(io.TextIOWrapper(file, encoding="utf-8-sig", newline="")):
                name, title, identifier = norm(row.get("platform_name")), norm(row.get("title")), row.get("game_id", "")
                if not name or not title or not identifier.isdigit():
                    continue
                game_id = int(identifier)
                lookup[(name, title)].add(game_id)
                memberships.add((name, game_id))
    if len(memberships) < 1000:
        raise ValueError("IGDB index is unexpectedly empty")
    return lookup, memberships

def dat_memberships():
    catalog = rows(zip_json(INPUTS / "GameBrowser-Data.zip", "game_catalog.json"))
    result = {(str(g.get("platform")), int(g["igdbId"])) for g in catalog
              if g.get("platform") and str(g.get("igdbId", "")).isdigit()}
    if len(result) < 1000:
        raise ValueError("DAT-backed catalog is unexpectedly empty")
    return result

TITLE_MAP, PLATFORM_IDS = make_platform_lookup()
DAT_IDS = dat_memberships()
FEATURED_ORIGINAL = rows(read_json(ROOT / "featured-games-curated.json")["games"])
STEAM_IDS = {norm(x["title"]): str(x["steamAppId"])
             for x in FEATURED_ORIGINAL if x.get("platform") == "Windows"
             and str(x.get("steamAppId", "")).isdigit()}

def resolve(entry):
    platform = str(entry.get("platform") or "").strip()
    title = str(entry.get("title") or "").strip()
    if not title or platform not in CONFIG:
        SKIPPED["bad title/platform"] += 1
        return None
    if platform == "Windows":
        steam_id = str(entry.get("steamAppId") or STEAM_IDS.get(norm(title)) or "")
        if not steam_id.isdigit() or int(steam_id) <= 0:
            SKIPPED["no verified Steam AppID"] += 1
            return None
        return {"source": "Steam", "id": int(steam_id), "title": title}
    aliases = {norm(name) for name in CONFIG[platform].get("igdbNames", [])}
    aliases.add(norm(platform))
    explicit = entry.get("igdbId")
    if explicit and str(explicit).isdigit() and int(explicit) > 0:
        game_id = int(explicit)
        matches = {game_id} if any((alias, game_id) in PLATFORM_IDS for alias in aliases) else set()
    else:
        matches = set()
        for alias in aliases:
            matches.update(TITLE_MAP.get((alias, norm(title)), set()))
    if len(matches) != 1:
        SKIPPED["missing or ambiguous IGDB ID"] += 1
        return None
    game_id = next(iter(matches))
    if CONFIG[platform]["mode"] not in ("igdb", "steam") and (platform, game_id) not in DAT_IDS:
        SKIPPED["not in strict IGDB + DAT catalog"] += 1
        return None
    return {"source": "IGDB:" + platform, "id": game_id, "title": title}

def to_compact(candidate, resolved, is_daily):
    entry = {"title": resolved["title"], "source": resolved["source"],
             "id": resolved["id"], "rating": float(candidate.get("rating") or 0),
             "releaseDateEpoch": int(candidate.get("releaseDateEpoch") or 0)}
    if is_daily:
        rule = str(candidate.get("dailyChunk") or "").strip()
        if len(rule) < 25:
            SKIPPED["missing game-specific rule"] += 1
            return None
        entry.update({"dailyChunk": rule, "minutes": int(candidate.get("minutes") or 30),
                      "chunkability": max(1, min(5, int(candidate.get("chunkability") or 4))),
                      "chunkSource": "game-specific"})
    return entry

def merge(current, original_candidates, additional_candidates, is_daily=False):
    result, seen = validated_existing(current, "Daily Chunks" if is_daily else "Featured")
    appended = []
    for candidate in list(original_candidates) + list(additional_candidates):
        resolved = resolve(candidate)
        if not resolved:
            continue
        key = (resolved["source"], resolved["id"])
        if key in seen:
            SKIPPED["already present"] += 1
            continue
        entry = to_compact(candidate, resolved, is_daily)
        if entry is None:
            continue
        result.append(entry)
        appended.append((entry, candidate))
        seen.add(key)
    if len(result) < len(current):
        raise AssertionError("A previous curated entry was lost")
    return result, appended

def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

def main(mode):
    if mode == "Featured":
        baseline = INPUTS / "GameBrowser-Featured.zip"
        original = rows(zip_json(baseline, "featured_game_index.json"))
        additions = read_json(ROOT / "_curated" / "featured" / "additions.json")
        final, appended = merge(original, FEATURED_ORIGINAL, additions)
        write_json(ROOT / "_curated" / "featured" / "featured_game_index.json", final)
    elif mode == "DailyChunks":
        baseline = INPUTS / "GameBrowser-DailyChunks.zip"
        original = rows(zip_json(baseline, "daily_chunk_index.json"))
        rich = rows(zip_json(baseline, "daily_chunks.json"))
        series = rows(zip_json(baseline, "daily_chunk_series.json"))
        existing_rich = {(norm(x.get("platform")), norm(x.get("title"))) for x in rich}
        candidates = read_json(ROOT / "daily-chunk-game-specific.json")
        additions = read_json(ROOT / "_curated" / "daily-chunks" / "additions.json")
        final, appended = merge(original, candidates, additions, is_daily=True)
        for compact, source in appended:
            platform = compact["source"][5:] if compact["source"].startswith("IGDB:") else "Windows"
            key = (norm(platform), norm(compact["title"]))
            if key not in existing_rich:
                rich.append({"id": platform + "::" + compact["title"], "platform": platform,
                             "title": compact["title"], "dailyChunk": compact["dailyChunk"],
                             "minutes": compact["minutes"], "chunkability": compact["chunkability"],
                             "chunkSource": "game-specific"})
                existing_rich.add(key)
        out = ROOT / "_curated" / "daily-chunks"
        write_json(out / "daily_chunks.json", rich)
        write_json(out / "daily_chunk_series.json", series)
        write_json(out / "daily_chunk_index.json", final)
    else:
        raise ValueError("Use Featured or DailyChunks")
    print(f"{mode}: preserved {len(original)} indexed games; added {len(appended)} newly verified selections; total {len(final)}.")
    print("Skipped: " + json.dumps(dict(SKIPPED), sort_keys=True))
    for entry, _ in appended[:30]:
        print("  + " + entry["source"] + " / " + entry["title"])

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python Prepare-Curated-Sources.py Featured|DailyChunks")
    main(sys.argv[1])
