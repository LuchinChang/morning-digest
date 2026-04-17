#!/usr/bin/env python3
"""
Normalize reading-log.json to the canonical schema expected by the dashboard.

Runs as the final step of the daily digest scheduled task. Idempotent — safe to
run at any time; re-running produces the same output.

Canonical article schema:
  id                string   "YYYY-MM-DD-###"
  title             string
  url               string
  source            string   publisher/author/person (e.g. "arXiv", "Simon Willison")
  date              string   YYYY-MM-DD, when the article was published
  tags              list     UPPERCASE, e.g. ["DEEP DIVE", "FORMAL METHODS", "READ"]
  status            string   one of: assigned | in-progress | bookmarked | completed
  assignedDate      string   YYYY-MM-DD, the digest day this was assigned to (null if bookmarked)
  estimatedMinutes  int|null
  digestDay         int|null 1-indexed across all unique assignedDates

Legacy fields this migrates away from:
  dateAdded → assignedDate
  author    → source
  type      → first tag

Canonical meta schema:
  started           string YYYY-MM-DD
  dayCount          int, recomputed as the number of unique non-null assignedDates
  researchArea      string (preserved as-is)
  dailyMinutes      int (preserved as-is)
  format            string (preserved as-is)
  feedSource        string (preserved as-is)

Usage:
  python3 normalize-log.py [PATH]              # rewrite PATH (or default) in place
  python3 normalize-log.py --check [PATH]      # validate only, do not write; exit 1 on hard errors

Hard errors (always fail; exit 1):
  - file missing, invalid JSON, or articles is not a list
  - duplicate article ids
  - same URL assigned to the same day twice
  - article with status "assigned" missing assignedDate
  - article missing url or title

Soft warnings (printed but do not fail):
  - cross-day URL duplicates (treated as expected for multi-day reads / promotions)
  - missing optional meta fields (filled with defaults in normal mode)
  - articles with no URL (dropped in normal mode)
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
VALID_STATUSES = {"assigned", "in-progress", "bookmarked", "completed"}


def normalize_article(a: dict) -> dict:
    # Field-name migration
    if "assignedDate" not in a and "dateAdded" in a:
        a["assignedDate"] = a.pop("dateAdded")
    if "source" not in a and "author" in a:
        a["source"] = a.pop("author")

    # Tags: always uppercase, always a list
    tags = a.get("tags") or []
    if isinstance(tags, str):
        tags = [tags]
    a["tags"] = [str(t).upper() for t in tags if t]

    # status fallback
    if a.get("status") not in VALID_STATUSES:
        a["status"] = "assigned" if a.get("assignedDate") else "bookmarked"

    # Dates: enforce YYYY-MM-DD or null
    for k in ("assignedDate", "date"):
        v = a.get(k)
        if v is not None and not DATE_RE.match(str(v)):
            a[k] = None

    # Numeric fields
    if a.get("estimatedMinutes") is not None:
        try:
            a["estimatedMinutes"] = int(a["estimatedMinutes"])
        except (TypeError, ValueError):
            a["estimatedMinutes"] = None

    # Required string fields default to empty
    for k in ("title", "url", "source"):
        if a.get(k) is None:
            a[k] = ""

    return a


def normalize(log: dict) -> tuple[dict, list[str], list[str]]:
    """Returns (log, errors, warnings). Errors are conditions a --check run rejects."""
    errors: list[str] = []
    warnings: list[str] = []

    if "meta" not in log:
        log["meta"] = {}
    if "articles" not in log or not isinstance(log["articles"], list):
        errors.append("missing or invalid articles list")
        log["articles"] = []
        return log, errors, warnings

    # Normalize each article
    for a in log["articles"]:
        normalize_article(a)

    # Drop articles with no URL (irrecoverable). Warning, not error — they couldn't
    # render in the dashboard anyway.
    before = len(log["articles"])
    log["articles"] = [a for a in log["articles"] if a.get("url")]
    if len(log["articles"]) != before:
        warnings.append(f"dropped {before - len(log['articles'])} articles with no URL")

    # HARD ERROR: missing required fields on retained articles
    for a in log["articles"]:
        if not a.get("title"):
            errors.append(f"article {a.get('id', '?')} missing title")
        if a.get("status") == "assigned" and not a.get("assignedDate"):
            errors.append(f"article {a.get('id', '?')} status=assigned but assignedDate is null")

    # Assign ids where missing
    used_ids: set[str] = set()
    for a in log["articles"]:
        if a.get("id"):
            used_ids.add(a["id"])
    for a in log["articles"]:
        if a.get("id"):
            continue
        base = a.get("assignedDate") or a.get("date") or "unknown"
        i = 1
        while True:
            candidate = f"{base}-{i:03d}"
            if candidate not in used_ids:
                a["id"] = candidate
                used_ids.add(candidate)
                break
            i += 1

    # HARD ERROR: duplicate ids
    id_counts: dict[str, int] = {}
    for a in log["articles"]:
        id_counts[a["id"]] = id_counts.get(a["id"], 0) + 1
    for aid, n in id_counts.items():
        if n > 1:
            errors.append(f"duplicate article id: {aid} appears {n} times")

    # Recompute digestDay from unique non-null assignedDates (chronological)
    unique_dates = sorted({a["assignedDate"] for a in log["articles"] if a.get("assignedDate")})
    day_index = {d: i + 1 for i, d in enumerate(unique_dates)}
    for a in log["articles"]:
        ad = a.get("assignedDate")
        a["digestDay"] = day_index.get(ad) if ad else None

    # Meta.dayCount is the number of unique assigned days
    log["meta"]["dayCount"] = len(unique_dates)

    # meta.started = earliest assignedDate if not already set
    if not log["meta"].get("started") and unique_dates:
        log["meta"]["started"] = unique_dates[0]

    # Check required meta fields (warn + default-fill)
    for k, default in (("researchArea", ""), ("dailyMinutes", 45), ("format", "html")):
        if k not in log["meta"]:
            log["meta"][k] = default
            warnings.append(f"meta.{k} missing; set to default {default!r}")

    # Duplicate URL analysis. Hard error if same URL appears on the SAME day.
    # Soft warning if same URL appears on DIFFERENT days (multi-day reads, promotions).
    url_day_pairs: dict[tuple[str, str], int] = {}
    url_to_entries: dict[str, list[dict]] = {}
    for a in log["articles"]:
        url = a["url"]
        ad = a.get("assignedDate") or "unscheduled"
        url_day_pairs[(url, ad)] = url_day_pairs.get((url, ad), 0) + 1
        url_to_entries.setdefault(url, []).append(a)

    for (url, day), count in url_day_pairs.items():
        if count > 1:
            errors.append(f"URL assigned to same day {day} {count} times: {url}")

    for url, entries in url_to_entries.items():
        if len(entries) <= 1:
            continue
        # Suppress warning if any entry is tagged MULTI-DAY (intentional re-include)
        if any("MULTI-DAY" in (e.get("tags") or []) for e in entries):
            continue
        dates = [e.get("assignedDate") or "unscheduled" for e in entries]
        warnings.append(f"duplicate URL across days ({', '.join(dates)}): {url}")

    return log, errors, warnings


def main(argv: list[str]) -> int:
    args = argv[1:]
    check_only = False
    if args and args[0] == "--check":
        check_only = True
        args = args[1:]

    if args:
        path = args[0]
    else:
        here = os.path.dirname(os.path.abspath(__file__))
        path = os.path.join(here, "reading-log.json")

    if not os.path.exists(path):
        print(f"ERROR: not found: {path}", file=sys.stderr)
        return 1
    try:
        with open(path) as f:
            log = json.load(f)
    except json.JSONDecodeError as e:
        print(f"ERROR: invalid JSON in {path}: {e}", file=sys.stderr)
        return 1

    log, errors, warnings = normalize(log)

    if not check_only:
        # Write atomically (write to .tmp, rename)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(log, f, indent=2)
        os.replace(tmp, path)

    ts = datetime.utcnow().isoformat(timespec="seconds") + "Z"
    label = "validated" if check_only else "normalized"
    print(f"[{ts}] {label} {path}")
    print(f"  articles: {len(log['articles'])}")
    print(f"  meta.dayCount: {log['meta']['dayCount']}")

    if errors:
        print(f"  ERRORS ({len(errors)}):", file=sys.stderr)
        for e in errors:
            print(f"    - {e}", file=sys.stderr)

    if warnings:
        print(f"  warnings ({len(warnings)}):")
        for w in warnings:
            print(f"    - {w}")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
