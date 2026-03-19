#!/bin/bash
# ============================================================
# Setup script for Morning Digest GitHub Pages site
# Run this once to initialize the repo and deploy
# ============================================================

set -e

REPO_NAME="morning-digest"
SITE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Morning Digest — GitHub Pages Setup ==="
echo ""

# Check if gh is installed
if ! command -v gh &> /dev/null; then
  echo "Error: GitHub CLI (gh) is required."
  echo "Install it: brew install gh"
  exit 1
fi

# Check if logged in
if ! gh auth status &> /dev/null 2>&1; then
  echo "Please log in to GitHub first:"
  echo "  gh auth login"
  exit 1
fi

cd "$SITE_DIR"

# Initialize git if needed
if [ ! -d .git ]; then
  git init
  git branch -M main
fi

# Create .gitignore
cat > .gitignore << 'EOF'
.DS_Store
*.swp
*~
EOF

# Stage all files
git add -A
git commit -m "Initial commit: Morning Digest reading platform

- Martian Dusk / Daylight glassmorphism theme
- Full-text search with Fuse.js
- Annotation system with Markdown, LaTeX, and links
- Mobile-responsive design
- Ambient particle canvas background
- LC signature monogram"

# Create GitHub repo (public, so GitHub Pages works for free)
echo ""
echo "Creating GitHub repository: $REPO_NAME"
gh repo create "$REPO_NAME" --public --source=. --push

# Enable GitHub Pages on main branch
echo ""
echo "Enabling GitHub Pages..."
gh api repos/{owner}/$REPO_NAME/pages \
  --method POST \
  --field "build_type=workflow" \
  --field "source[branch]=main" \
  --field "source[path]=/" 2>/dev/null || \
gh api repos/{owner}/$REPO_NAME/pages \
  --method POST \
  -f "source[branch]=main" \
  -f "source[path]=/" 2>/dev/null || \
echo "(You may need to enable Pages manually in repo Settings > Pages > Source: main branch)"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Your site will be live at:"
echo "  https://$(gh api user --jq '.login').github.io/$REPO_NAME/"
echo ""
echo "To update the site after new digests:"
echo "  cd $SITE_DIR"
echo "  git add -A && git commit -m 'Update digest' && git push"
echo ""
