#!/bin/bash
# ============================================================
# Sync latest reading-log.json to the GitHub Pages site
# Run after each daily digest generation
# ============================================================

SITE_DIR="$(cd "$(dirname "$0")" && pwd)"
DIGEST_DIR="$(dirname "$SITE_DIR")"

echo "=== Syncing digest data to GitHub ==="

# Copy latest reading-log.json
cp "$DIGEST_DIR/reading-log.json" "$SITE_DIR/digests/reading-log.json"

cd "$SITE_DIR"

# Check if there are changes
if git diff --quiet && git diff --cached --quiet; then
  echo "No changes to sync."
  exit 0
fi

# Commit and push
DATE=$(date +%Y-%m-%d)
git add -A
git commit -m "Update digest: $DATE"
git push

echo "=== Sync complete ==="
