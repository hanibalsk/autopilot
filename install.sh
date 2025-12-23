#!/usr/bin/env bash
#
# BMAD Autopilot Installer
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$(pwd)}"

echo "🚀 BMAD Autopilot Installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check prerequisites
echo "📋 Checking prerequisites..."
missing=()
for cmd in jq git gh claude rg; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "❌ Missing required commands: ${missing[*]}"
  echo ""
  echo "Install them first:"
  echo "  jq     - brew install jq"
  echo "  gh     - brew install gh"
  echo "  claude - pip install claude-cli (or follow Anthropic docs)"
  echo "  rg     - brew install ripgrep"
  exit 1
fi
echo "✅ All prerequisites found"
echo ""

# Install main script and config example
echo "📁 Installing to: $TARGET_DIR/.autopilot/"
mkdir -p "$TARGET_DIR/.autopilot"
cp "$SCRIPT_DIR/scripts/bmad-autopilot.sh" "$TARGET_DIR/.autopilot/"
chmod +x "$TARGET_DIR/.autopilot/bmad-autopilot.sh"
cp "$SCRIPT_DIR/config.example" "$TARGET_DIR/.autopilot/config.example"
echo "✅ Main script installed"
echo "✅ Config example installed (copy to 'config' to customize)"

# Install Claude commands to project-local .claude/commands
echo ""
read -p "📦 Install Claude Code commands to $TARGET_DIR/.claude/commands? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
  mkdir -p "$TARGET_DIR/.claude/commands"
  cp "$SCRIPT_DIR/commands/"*.md "$TARGET_DIR/.claude/commands/"
  echo "✅ Claude commands installed to .claude/commands/"
else
  echo "⏭️  Skipped Claude commands"
fi

# Add to .gitignore if not already there
echo ""
if [ -f "$TARGET_DIR/.gitignore" ]; then
  if ! grep -q "^\.autopilot/$" "$TARGET_DIR/.gitignore" 2>/dev/null; then
    echo "" >> "$TARGET_DIR/.gitignore"
    echo "# BMAD Autopilot (local)" >> "$TARGET_DIR/.gitignore"
    echo ".autopilot/" >> "$TARGET_DIR/.gitignore"
    echo "✅ Added .autopilot/ to .gitignore"
  else
    echo "✅ .autopilot/ already in .gitignore"
  fi
else
  echo "⚠️  No .gitignore found - consider adding .autopilot/ to it"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Installation complete!"
echo ""
echo "Usage:"
echo "  cd $TARGET_DIR"
echo "  ./.autopilot/bmad-autopilot.sh           # process all epics"
echo "  ./.autopilot/bmad-autopilot.sh \"7A 8A\"   # specific epics"
echo "  ./.autopilot/bmad-autopilot.sh --continue # resume"
echo ""

