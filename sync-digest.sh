#!/bin/bash
# ============================================================
# Sync latest digest files to GitHub Pages
# Run after each daily digest generation (also called by
# the Claude scheduled task automatically).
#
# AUTH: Reads a GitHub Personal Access Token from the file
#   ../Daily Digest/.gh-token   (one line: ghp_xxxxxxxxxxxx)
# If that file doesn't exist, push is skipped gracefully.
#
# LOCK FILES: Stale .git/index.lock / HEAD.lock are removed
# automatically before any git operation.
# ============================================================

set -e

SITE_DIR="$(cd "$(dirname "$0")" && pwd)"
DIGEST_DIR="$(dirname "$SITE_DIR")"
TOKEN_FILE="$DIGEST_DIR/.gh-token"

echo "=== Syncing digest data to GitHub ==="

# ── Step 1: Remove stale lock files ─────────────────────────
for lock in "$SITE_DIR/.git/index.lock" "$SITE_DIR/.git/HEAD.lock"; do
  if [ -f "$lock" ]; then
    echo "⚠️  Removing stale lock file: $(basename $lock)"
    rm -f "$lock" 2>/dev/null || {
      echo "   (could not remove lock — skipping git operations)"
      echo "   Fix manually: rm \"$lock\""
      exit 0
    }
  fi
done

# ── Step 2: Copy latest files ────────────────────────────────
echo "Copying digest files to site/digests/ ..."
cp "$DIGEST_DIR/reading-log.json" "$SITE_DIR/digests/reading-log.json"
cp "$DIGEST_DIR"/morning-digest-*.html "$SITE_DIR/digests/" 2>/dev/null || true

cd "$SITE_DIR"

# ── Step 3: Check for changes ────────────────────────────────
git add -A 2>/dev/null || true
if git diff --cached --quiet; then
  echo "No changes to sync."
  exit 0
fi

# ── Step 4: Configure auth (PAT from file) ───────────────────
REMOTE_URL=$(git remote get-url origin)
REPO_SLUG=$(echo "$REMOTE_URL" | sed 's|https://github.com/||' | sed 's|git@github.com:||' | sed 's|\.git$||')

if [ -f "$TOKEN_FILE" ]; then
  TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')
  # Temporarily override the remote URL with the token embedded
  git remote set-url origin "https://x-access-token:${TOKEN}@github.com/${REPO_SLUG}.git"
  RESTORE_URL=true
  echo "🔑  Using PAT from .gh-token for auth"
else
  echo "⚠️  No .gh-token file found at: $TOKEN_FILE"
  echo "   Attempting SSH push (will fail if SSH key not configured) ..."
  git remote set-url origin "git@github.com:${REPO_SLUG}.git"
  RESTORE_URL=false
fi

# ── Step 5: Commit + Push ────────────────────────────────────
DATE=$(date +%Y-%m-%d)
git commit -m "Update digest: $DATE" || {
  echo "Nothing new to commit."
}

git push origin main || {
  echo ""
  echo "❌  Push failed. Possible reasons:"
  echo "   1. .gh-token is missing or expired — regenerate at github.com/settings/tokens"
  echo "   2. Network issue"
  echo "   Files are already staged; next run will retry."
}

# ── Step 6: Restore clean remote URL (no token in config) ────
if [ "$RESTORE_URL" = "true" ]; then
  git remote set-url origin "https://github.com/${REPO_SLUG}.git"
fi

echo "=== Sync complete ==="
