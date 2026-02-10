#!/bin/bash
# BrainX Stable Backup Script
# Push current state to private backup repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="${1:-$(date +%Y%m%d_%H%M%S)}"
MESSAGE="${2:-Stable backup $VERSION}"

echo "Creating stable backup..."
echo "  Version: $VERSION"
echo "  Message: $MESSAGE"

# Check if stable remote exists
if ! git remote get-url stable &>/dev/null; then
    echo "Error: 'stable' remote not found"
    echo "Run: git remote add stable https://github.com/Mdx2025/BrainX-stable.git"
    exit 1
fi

# Stage all changes
git add -A

# Commit with version tag
git commit -m "$MESSAGE" || echo "Nothing to commit"
git tag -f "v$VERSION"

# Push to stable repo
git push stable main
git push stable "v$VERSION"

echo ""
echo "✓ Stable backup completed"
echo "  Repo: https://github.com/Mdx2025/BrainX-stable"
echo "  Tag: v$VERSION"
