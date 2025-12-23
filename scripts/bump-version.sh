#!/bin/bash
#
# bump-version.sh - Bump version number
#
# Usage:
#   ./scripts/bump-version.sh patch   # 0.1.0 -> 0.1.1
#   ./scripts/bump-version.sh minor   # 0.1.1 -> 0.2.0
#   ./scripts/bump-version.sh major   # 0.2.0 -> 1.0.0
#
# After bumping, automatically runs update-version.sh to sync all files.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="$ROOT_DIR/VERSION"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check argument
BUMP_TYPE="${1:-patch}"

if [[ ! "$BUMP_TYPE" =~ ^(major|minor|patch)$ ]]; then
    echo -e "${RED}ERROR: Invalid bump type '$BUMP_TYPE'${NC}"
    echo "Usage: $0 [major|minor|patch]"
    exit 1
fi

# Check VERSION file exists
if [[ ! -f "$VERSION_FILE" ]]; then
    echo -e "${RED}ERROR: VERSION file not found at $VERSION_FILE${NC}"
    exit 1
fi

# Read current version
CURRENT_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')

if [[ ! "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}ERROR: Invalid current version format '$CURRENT_VERSION'${NC}"
    exit 1
fi

# Parse version components
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# Bump version based on type
case "$BUMP_TYPE" in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"

echo -e "${YELLOW}Bumping version: $CURRENT_VERSION -> $NEW_VERSION ($BUMP_TYPE)${NC}"

# Write new version
echo "$NEW_VERSION" > "$VERSION_FILE"

echo -e "${GREEN}✓ VERSION file updated${NC}"

# Run update-version.sh to sync all files
echo ""
echo "Synchronizing version across all files..."
"$SCRIPT_DIR/update-version.sh"
