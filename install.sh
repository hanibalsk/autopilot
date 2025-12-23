#!/usr/bin/env bash
#
# BMAD Autopilot Installer
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$(pwd)}"
BACKUP_DIR="$TARGET_DIR/.autopilot/backup"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

# Read version from VERSION file
AUTOPILOT_VERSION="0.1.0"
if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
  AUTOPILOT_VERSION=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')
fi

echo "🚀 BMAD Autopilot Installer v$AUTOPILOT_VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
BACKUP_CREATED=false
backup_file() {
  local file="$1"
  if [ -f "$file" ]; then
    mkdir -p "$BACKUP_DIR"
    local backup_zip="$BACKUP_DIR/${TIMESTAMP}.zip"
    if [ "$BACKUP_CREATED" = false ]; then
      echo "⚠️  Found existing files, creating backup..."
      BACKUP_CREATED=true
    fi
    echo "   → $(basename "$file")"
    zip -q -u "$backup_zip" "$file" 2>/dev/null || zip -q "$backup_zip" "$file"
  fi
}

# Check for existing installation and backup
echo "🔍 Checking for existing installation..."

# Backup autopilot files
backup_file "$TARGET_DIR/.autopilot/bmad-autopilot.sh"
backup_file "$TARGET_DIR/.autopilot/config"
backup_file "$TARGET_DIR/.autopilot/config.example"

# Backup local Claude commands
backup_file "$TARGET_DIR/.claude/commands/autopilot.md"
backup_file "$TARGET_DIR/.claude/commands/bmad-autopilot.md"

# Backup local Claude skills
if [ -f "$TARGET_DIR/.claude/skills/bmad-autopilot/SKILL.md" ]; then
  backup_file "$TARGET_DIR/.claude/skills/bmad-autopilot/SKILL.md"
fi

# Backup global Claude commands
backup_file "$HOME/.claude/commands/autopilot.md"
backup_file "$HOME/.claude/commands/bmad-autopilot.md"

# Backup global Claude skills
if [ -f "$HOME/.claude/skills/bmad-autopilot/SKILL.md" ]; then
  backup_file "$HOME/.claude/skills/bmad-autopilot/SKILL.md"
fi

if [ "$BACKUP_CREATED" = true ]; then
  echo "✅ Backup created: $BACKUP_DIR/${TIMESTAMP}.zip"
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

# Install Claude commands
echo ""
read -p "📦 Install Claude Code commands? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
  # Detect previous installation location
  COMMANDS_LOCATION=""
  if [ -f "$TARGET_DIR/.claude/commands/autopilot.md" ]; then
    COMMANDS_LOCATION="local"
  elif [ -f "$HOME/.claude/commands/autopilot.md" ]; then
    COMMANDS_LOCATION="global"
  fi

  if [ -n "$COMMANDS_LOCATION" ]; then
    echo "ℹ️  Previous installation detected: $COMMANDS_LOCATION"
    if [ "$COMMANDS_LOCATION" = "local" ]; then
      COMMANDS_DIR="$TARGET_DIR/.claude/commands"
    else
      COMMANDS_DIR="$HOME/.claude/commands"
    fi
  else
    echo ""
    echo "Where to install commands?"
    echo "  1) Local  - $TARGET_DIR/.claude/commands (recommended)"
    echo "  2) Global - ~/.claude/commands"
    read -p "Choose [1/2] (default: 1): " -n 1 -r
    echo ""
    if [[ $REPLY = "2" ]]; then
      COMMANDS_DIR="$HOME/.claude/commands"
      echo "Installing to global ~/.claude/commands/"
    else
      COMMANDS_DIR="$TARGET_DIR/.claude/commands"
      echo "Installing to local .claude/commands/"
    fi
  fi

  mkdir -p "$COMMANDS_DIR"
  cp "$SCRIPT_DIR/commands/"*.md "$COMMANDS_DIR/"
  echo "✅ Claude commands installed to $COMMANDS_DIR/"

  # Also install skills to the same scope
  if [ "$COMMANDS_DIR" = "$TARGET_DIR/.claude/commands" ]; then
    SKILLS_DIR="$TARGET_DIR/.claude/skills"
  else
    SKILLS_DIR="$HOME/.claude/skills"
  fi

  if [ -d "$SCRIPT_DIR/skills" ]; then
    mkdir -p "$SKILLS_DIR"
    cp -r "$SCRIPT_DIR/skills/"* "$SKILLS_DIR/"
    echo "✅ Claude skills installed to $SKILLS_DIR/"
  fi
else
  echo "⏭️  Skipped Claude commands and skills"
fi

# Install GitHub workflows
echo ""
if [ -d "$SCRIPT_DIR/workflows" ]; then
  WORKFLOWS_DIR="$TARGET_DIR/.github/workflows"

  # Check for existing workflow
  if [ -f "$WORKFLOWS_DIR/auto-approve.yml" ]; then
    echo "ℹ️  GitHub workflow already exists at $WORKFLOWS_DIR/auto-approve.yml"
    read -p "🔄 Update auto-approve workflow? [y/N] " -n 1 -r
    echo ""
    INSTALL_WORKFLOW=$([[ $REPLY =~ ^[Yy]$ ]] && echo "yes" || echo "no")
  else
    read -p "🤖 Install auto-approve GitHub workflow? [y/N] " -n 1 -r
    echo ""
    INSTALL_WORKFLOW=$([[ $REPLY =~ ^[Yy]$ ]] && echo "yes" || echo "no")
  fi

  if [ "$INSTALL_WORKFLOW" = "yes" ]; then
    mkdir -p "$WORKFLOWS_DIR"
    cp "$SCRIPT_DIR/workflows/auto-approve.yml" "$WORKFLOWS_DIR/"
    echo "✅ GitHub workflow installed to $WORKFLOWS_DIR/auto-approve.yml"
    echo "   → Auto-approves PRs when CI passes and Copilot review has no unresolved threads"
  else
    echo "⏭️  Skipped GitHub workflow"
  fi
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

