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

# ── Step 4: Derive a clean repo slug (strip any embedded auth) ──
RAW_URL=$(git remote get-url origin)
# Remove any token that may have been left from a previous failed run
CLEAN_URL=$(echo "$RAW_URL" | sed 's|https://[^@]*@github\.com/|https://github.com/|')
REPO_SLUG=$(echo "$CLEAN_URL" | sed 's|https://github\.com/||' | sed 's|git@github\.com:||' | sed 's|\.git$||')
# Always restore the clean URL first so config is never left dirty
git remote set-url origin "https://github.com/${REPO_SLUG}.git"

# ── Step 5: Configure auth and register cleanup trap ────────
if [ -f "$TOKEN_FILE" ]; then
  TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')
  echo "🔑  Using PAT from .gh-token for auth"
  # Inject token only for the duration of the push;
  # the trap guarantees the clean URL is restored even on failure
  trap 'git remote set-url origin "https://github.com/${REPO_SLUG}.git"' EXIT
  git remote set-url origin "https://x-access-token:${TOKEN}@github.com/${REPO_SLUG}.git"
else
  echo "⚠️  No .gh-token file found at: $TOKEN_FILE"
  echo "   Create one with a GitHub PAT (Contents + Workflow write scope)."
  echo "   Skipping push."
  exit 0
fi

# ── Step 6: Commit + Push ────────────────────────────────────
DATE=$(date +%Y-%m-%d)
git commit -m "Update digest: $DATE" || echo "Nothing new to commit."

if git push origin main; then
  echo "✅  Pushed successfully."
else
  echo ""
  echo "❌  Push failed. Possible reasons:"
  echo "   1. PAT expired — regenerate at github.com/settings/tokens"
  echo "      then overwrite: $TOKEN_FILE"
  echo "   2. PAT missing 'workflow' scope (needed for .github/workflows files)"
  echo "   3. Network issue"
fi
# trap fires here → remote URL restored to clean HTTPS

echo "=== Sync complete ==="
