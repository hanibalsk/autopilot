#!/usr/bin/env bash
#
# BMAD Autopilot Installer
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$(pwd)}"
BACKUP_DIR="$TARGET_DIR/.autopilot/backup"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

echo "🚀 BMAD Autopilot Installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check prerequisites
echo "📋 Checking prerequisites..."
missing=()
for cmd in jq git gh claude rg zip; do
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
  echo "  zip    - brew install zip (or apt install zip)"
  exit 1
fi
echo "✅ All prerequisites found"
echo ""

# Backup existing files before installation
backup_if_exists() {
  local file="$1"
  if [ -f "$file" ]; then
    mkdir -p "$BACKUP_DIR"
    local backup_zip="$BACKUP_DIR/${TIMESTAMP}.zip"
    echo "📦 Backing up existing file: $file"
    zip -q -u "$backup_zip" "$file" 2>/dev/null || zip -q "$backup_zip" "$file"
  fi
}

# Check for existing installation and backup
echo "🔍 Checking for existing installation..."
files_to_backup=()
[ -f "$TARGET_DIR/.autopilot/bmad-autopilot.sh" ] && files_to_backup+=("$TARGET_DIR/.autopilot/bmad-autopilot.sh")
[ -f "$TARGET_DIR/.autopilot/config" ] && files_to_backup+=("$TARGET_DIR/.autopilot/config")
[ -f "$TARGET_DIR/.autopilot/config.example" ] && files_to_backup+=("$TARGET_DIR/.autopilot/config.example")

# Check for Claude commands
if [ -d "$TARGET_DIR/.claude/commands" ]; then
  for cmd_file in "$TARGET_DIR/.claude/commands/autopilot.md" "$TARGET_DIR/.claude/commands/bmad-autopilot.md"; do
    [ -f "$cmd_file" ] && files_to_backup+=("$cmd_file")
  done
fi

if [ ${#files_to_backup[@]} -gt 0 ]; then
  echo "⚠️  Found existing files, creating backup..."
  mkdir -p "$BACKUP_DIR"
  backup_zip="$BACKUP_DIR/${TIMESTAMP}.zip"
  for file in "${files_to_backup[@]}"; do
    echo "   → $(basename "$file")"
    zip -q -u "$backup_zip" "$file" 2>/dev/null || zip -q "$backup_zip" "$file"
  done
  echo "✅ Backup created: $backup_zip"
else
  echo "✅ No existing installation found"
fi
echo ""

# Install main script and config example
echo "📁 Installing to: $TARGET_DIR/.autopilot/"
mkdir -p "$TARGET_DIR/.autopilot"
cp "$SCRIPT_DIR/scripts/bmad-autopilot.sh" "$TARGET_DIR/.autopilot/"
chmod +x "$TARGET_DIR/.autopilot/bmad-autopilot.sh"
cp "$SCRIPT_DIR/config.example" "$TARGET_DIR/.autopilot/config.example"
echo "✅ Main script installed"
echo "✅ Config example installed"

# Ask about installing active config
echo ""
if [ -f "$TARGET_DIR/.autopilot/config" ]; then
  echo "ℹ️  Config file already exists at $TARGET_DIR/.autopilot/config"
else
  read -p "⚙️  Create config file from example? [y/N] " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    cp "$SCRIPT_DIR/config.example" "$TARGET_DIR/.autopilot/config"
    echo "✅ Config file created (edit .autopilot/config to customize)"
  else
    echo "⏭️  Skipped config (copy config.example to config when ready)"
  fi
fi

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

