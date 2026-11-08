#!/usr/bin/env python3
"""Preserve existing published curated packages while merging verified, hand-picked additions.

This script is run by GitHub Actions. It does not download or package ROMs.
A failed/ambiguous identification is skipped, never substituted with a guessed game.
"""
import csv
import io
from datetime import datetime, timezone
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
QUALITY = json.loads((ROOT / '_curated' / 'quality-review.json').read_text(encoding='utf-8'))

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
    release_dates = {}
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
                date_text = row.get('release_date') or row.get('first_release_date') or ''
                if date_text:
                    try:
                        epoch = int(datetime.fromisoformat(date_text.replace('Z', '+00:00')).replace(tzinfo=timezone.utc).timestamp())
                        if epoch > 0:
                            release_dates[(name, game_id)] = epoch
                    except (ValueError, OverflowError):
                        pass
    if len(memberships) < 1000:
        raise ValueError("IGDB index is unexpectedly empty")
    return lookup, memberships, release_dates

def dat_memberships():
    catalog = rows(zip_json(INPUTS / "GameBrowser-Data.zip", "game_catalog.json"))
    result = {(str(g.get("platform")), int(g["igdbId"])) for g in catalog
              if g.get("platform") and str(g.get("igdbId", "")).isdigit()}
    if len(result) < 1000:
        raise ValueError("DAT-backed catalog is unexpectedly empty")
    return result

TITLE_MAP, PLATFORM_IDS, PLATFORM_DATES = make_platform_lookup()
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


def fix_mojibake(value):
    """Undo the UTF-8-as-Latin-1 corruption visible in some older DAT/index titles."""
    text = str(value or "")
    if not any(seq in text for seq in ("Ã", "Â", "â€")):
        return text
    for codec in ("cp1252", "latin-1"):
        try:
            clean = text.encode(codec).decode("utf-8")
            if clean.count("Ã") + clean.count("Â") < text.count("Ã") + text.count("Â"):
                SKIPPED["repaired mojibake titles"] += 1
                return clean
        except (UnicodeError, LookupError):
            continue
    return text

def set_verified_release_dates(items):
    updates = 0
    for item in items:
        if item.get("releaseDateEpoch"):
            continue
        source = str(item.get("source") or "")
        if not source.startswith("IGDB:"):
            continue
        platform = source[5:]
        aliases = {norm(platform)} | {norm(x) for x in CONFIG.get(platform, {}).get("igdbNames", [])}
        try:
            gid = int(item["id"])
        except (ValueError, KeyError, TypeError):
            continue
        stamps = [PLATFORM_DATES[(p, gid)] for p in aliases if (p, gid) in PLATFORM_DATES]
        if stamps:
            item["releaseDateEpoch"] = min(stamps)
            updates += 1
    return updates

def featured_quality_gate(items):
    exclusions = {(e["source"], int(e["id"])) for e in QUALITY.get("featuredExclusions", [])}
    kept = [x for x in items if identity(x) not in exclusions]
    if len(kept) != len(items):
        print(f"Featured quality gate: removed {len(items) - len(kept)} verified alias/duplicate rows.")
    return kept

def improve_daily_entries(items, rich):
    """Refresh verified game-specific tasks and correct mismatched franchise instructions."""
    exact = {}
    for x in read_json(ROOT / "daily-chunk-game-specific.json"):
        platform, title = norm(x.get("platform")), norm(x.get("title"))
        if not platform or not title or not x.get("dailyChunk"):
            continue
        exact[(platform, title)] = x
    for x in read_json(ROOT / "_curated" / "daily-chunks" / "additions.json"):
        if x.get("dailyChunk"):
            exact[(norm(x.get("platform")), norm(x.get("title")))] = x

    changes = {}
    upgraded_specific = corrected_mismatch = title_fixes = 0
    for x in items:
        source = x.get("source", "")
        platform = source[5:] if source.startswith("IGDB:") else "Windows"
        old_title = x.get("title", "")
        fixed_title = fix_mojibake(old_title)
        if fixed_title != old_title:
            x["title"] = fixed_title
            title_fixes += 1
        key = (norm(platform), norm(fixed_title))
        original_rule = str(x.get("dailyChunk") or "")
        specific = exact.get(key)
        if specific:
            specific_rule = str(specific.get("dailyChunk") or "").strip()
            if len(specific_rule) >= 45 and specific_rule != original_rule:
                x["dailyChunk"] = specific_rule
                x["minutes"] = max(15, min(60, int(specific.get("minutes") or x.get("minutes") or 30)))
                x["chunkability"] = max(1, min(5, int(specific.get("chunkability") or x.get("chunkability") or 4)))
                upgraded_specific += 1
        current_rule = str(x.get("dailyChunk") or "")
        for rule in QUALITY.get("dailyOverrides", []):
            title_pattern = rule.get("pattern", "")
            if not title_pattern or not re.search(title_pattern, norm(fixed_title)):
                continue
            blocked = rule.get("notPattern")
            if blocked and re.search(blocked, norm(fixed_title)):
                continue
            expected = rule.get("when", "").casefold()
            if expected and expected not in current_rule.casefold():
                continue
            if current_rule != rule["dailyChunk"]:
                x["dailyChunk"] = rule["dailyChunk"]
                x["minutes"] = int(rule["minutes"])
                x["chunkability"] = int(rule["chunkability"])
                corrected_mismatch += 1
            break
        if not x.get("dailyChunk") or len(x["dailyChunk"]) < 40:
            raise ValueError("Unusable curated Daily Chunk instruction: " + str(x.get("title")))
        if str(x.get("dailyChunk")) != original_rule or fixed_title != old_title:
            changes[key] = x

    rich_updates = 0
    for row in rich:
        old_title = str(row.get("title") or "")
        clean_title = fix_mojibake(old_title)
        key = (norm(row.get("platform")), norm(clean_title))
        changed = changes.get(key)
        if changed:
            row["title"] = changed["title"]
            row["dailyChunk"] = changed["dailyChunk"]
            row["minutes"] = changed["minutes"]
            row["chunkability"] = changed["chunkability"]
            row["id"] = str(row.get("platform")) + "::" + changed["title"]
            rich_updates += 1
        elif clean_title != old_title:
            row["title"] = clean_title
            row["id"] = str(row.get("platform")) + "::" + clean_title
            rich_updates += 1
    print(f"Daily quality gate: {upgraded_specific} verified per-game improvements; {corrected_mismatch} wrong-genre franchise goals corrected; {title_fixes} display titles repaired; {rich_updates} detailed rows synchronized.")
    return items, rich

def main(mode):
    if mode == "Featured":
        baseline = INPUTS / "GameBrowser-Featured.zip"
        original = rows(zip_json(baseline, "featured_game_index.json"))
        additions = read_json(ROOT / "_curated" / "featured" / "additions.json")
        final, appended = merge(original, FEATURED_ORIGINAL, additions)
        final = featured_quality_gate(final)
        print(f'Featured live platform dates populated: {set_verified_release_dates(final)}')
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
        final, rich = improve_daily_entries(final, rich)
        print(f'Daily verified platform dates populated: {set_verified_release_dates(final)}')
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
