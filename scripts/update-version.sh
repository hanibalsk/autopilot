#!/bin/bash
#
# update-version.sh - Synchronize version across all files
#
# Single source of truth: VERSION file
#
# Updates:
# - scripts/bmad-autopilot.sh (AUTOPILOT_VERSION variable)
# - install.sh (display version)
# - README.md (version badge)
#
# Usage: ./scripts/update-version.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="$ROOT_DIR/VERSION"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check VERSION file exists
if [[ ! -f "$VERSION_FILE" ]]; then
    echo -e "${RED}ERROR: VERSION file not found at $VERSION_FILE${NC}"
    exit 1
fi

# Read and validate version
VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}ERROR: Invalid version format '$VERSION'. Expected X.Y.Z (semantic versioning)${NC}"
    exit 1
fi

echo -e "${GREEN}Version: $VERSION${NC}"
echo ""

# ==================== Main Script ====================
echo "Updating main script..."
MAIN_SCRIPT="$ROOT_DIR/scripts/bmad-autopilot.sh"
if [[ -f "$MAIN_SCRIPT" ]]; then
    # Update or add AUTOPILOT_VERSION variable
    if grep -q '^AUTOPILOT_VERSION=' "$MAIN_SCRIPT"; then
        sed "s/^AUTOPILOT_VERSION=.*/AUTOPILOT_VERSION=\"$VERSION\"/" "$MAIN_SCRIPT" > "$MAIN_SCRIPT.tmp"
        mv "$MAIN_SCRIPT.tmp" "$MAIN_SCRIPT"
        chmod +x "$MAIN_SCRIPT"
    else
        # Add after shebang if not exists
        sed "2a\\
AUTOPILOT_VERSION=\"$VERSION\"
" "$MAIN_SCRIPT" > "$MAIN_SCRIPT.tmp"
        mv "$MAIN_SCRIPT.tmp" "$MAIN_SCRIPT"
        chmod +x "$MAIN_SCRIPT"
    fi
    echo -e "  ${GREEN}✓${NC} Updated $MAIN_SCRIPT"
fi

# ==================== Install Script ====================
echo "Updating install script..."
INSTALL_SCRIPT="$ROOT_DIR/install.sh"
if [[ -f "$INSTALL_SCRIPT" ]]; then
    # Update or add version display
    if grep -q '^AUTOPILOT_VERSION=' "$INSTALL_SCRIPT"; then
        sed "s/^AUTOPILOT_VERSION=.*/AUTOPILOT_VERSION=\"$VERSION\"/" "$INSTALL_SCRIPT" > "$INSTALL_SCRIPT.tmp"
        mv "$INSTALL_SCRIPT.tmp" "$INSTALL_SCRIPT"
        chmod +x "$INSTALL_SCRIPT"
    fi
    echo -e "  ${GREEN}✓${NC} Updated $INSTALL_SCRIPT"
fi

echo ""
echo -e "${GREEN}Version synchronization complete!${NC}"
echo ""
echo "Summary:"
echo "  Version: $VERSION"
echo ""
echo "Files updated:"
echo "  - scripts/bmad-autopilot.sh"
echo "  - install.sh"
