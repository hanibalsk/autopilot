#!/usr/bin/env bash
#
# BMAD Autopilot Uninstaller
#
set -euo pipefail

TARGET_DIR="${1:-$(pwd)}"
BACKUP_DIR="$TARGET_DIR/.autopilot/backup"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

echo "🗑️  BMAD Autopilot Uninstaller"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if autopilot is installed
if [ ! -d "$TARGET_DIR/.autopilot" ]; then
    echo "❌ No autopilot installation found in $TARGET_DIR"
    echo ""
    echo "Usage: ./uninstall.sh [project_dir]"
    exit 1
fi

echo "📍 Target directory: $TARGET_DIR"
echo ""

# Detect what's installed
echo "🔍 Detecting installed components..."
COMPONENTS=()

if [ -f "$TARGET_DIR/.autopilot/bmad-autopilot.sh" ]; then
    COMPONENTS+=("autopilot-script")
    echo "   ✓ Main script: .autopilot/bmad-autopilot.sh"
fi

if [ -f "$TARGET_DIR/.autopilot/config" ]; then
    COMPONENTS+=("autopilot-config")
    echo "   ✓ Config file: .autopilot/config"
fi

if [ -d "$TARGET_DIR/.autopilot/backup" ]; then
    COMPONENTS+=("autopilot-backup")
    echo "   ✓ Backups: .autopilot/backup/"
fi

if [ -d "$TARGET_DIR/.autopilot/state" ]; then
    COMPONENTS+=("autopilot-state")
    echo "   ✓ State files: .autopilot/state/"
fi

# Check local Claude commands
LOCAL_CLAUDE=false
if [ -f "$TARGET_DIR/.claude/commands/autopilot.md" ] || \
   [ -f "$TARGET_DIR/.claude/commands/bmad-autopilot.md" ] || \
   [ -f "$TARGET_DIR/.claude/commands/gh-pr.md" ]; then
    LOCAL_CLAUDE=true
    COMPONENTS+=("local-commands")
    echo "   ✓ Local Claude commands: .claude/commands/"
fi

if [ -d "$TARGET_DIR/.claude/skills/bmad-autopilot" ] || \
   [ -d "$TARGET_DIR/.claude/skills/gh-pr-handling" ]; then
    LOCAL_CLAUDE=true
    COMPONENTS+=("local-skills")
    echo "   ✓ Local Claude skills: .claude/skills/"
fi

# Check global Claude commands
GLOBAL_CLAUDE=false
if [ -f "$HOME/.claude/commands/autopilot.md" ] || \
   [ -f "$HOME/.claude/commands/bmad-autopilot.md" ] || \
   [ -f "$HOME/.claude/commands/gh-pr.md" ]; then
    GLOBAL_CLAUDE=true
    COMPONENTS+=("global-commands")
    echo "   ✓ Global Claude commands: ~/.claude/commands/"
fi

if [ -d "$HOME/.claude/skills/bmad-autopilot" ] || \
   [ -d "$HOME/.claude/skills/gh-pr-handling" ]; then
    GLOBAL_CLAUDE=true
    COMPONENTS+=("global-skills")
    echo "   ✓ Global Claude skills: ~/.claude/skills/"
fi

# Check GitHub workflow
if [ -f "$TARGET_DIR/.github/workflows/auto-approve.yml" ]; then
    COMPONENTS+=("github-workflow")
    echo "   ✓ GitHub workflow: .github/workflows/auto-approve.yml"
fi

echo ""

if [ ${#COMPONENTS[@]} -eq 0 ]; then
    echo "❌ No autopilot components found to uninstall"
    exit 0
fi

# Confirm uninstallation
echo "⚠️  This will remove the following components:"
for comp in "${COMPONENTS[@]}"; do
    case "$comp" in
        autopilot-script) echo "   • Main autopilot script" ;;
        autopilot-config) echo "   • Configuration file" ;;
        autopilot-backup) echo "   • Backup files" ;;
        autopilot-state) echo "   • State files" ;;
        local-commands) echo "   • Local Claude commands (.claude/commands/)" ;;
        local-skills) echo "   • Local Claude skills (.claude/skills/)" ;;
        global-commands) echo "   • Global Claude commands (~/.claude/commands/)" ;;
        global-skills) echo "   • Global Claude skills (~/.claude/skills/)" ;;
        github-workflow) echo "   • GitHub auto-approve workflow" ;;
    esac
done
echo ""

read -p "Continue with uninstallation? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "⏹️  Uninstallation cancelled"
    exit 0
fi

echo ""

# Create backup before removing
BACKUP_CREATED=false
backup_before_remove() {
    local file="$1"
    if [ -f "$file" ] || [ -d "$file" ]; then
        mkdir -p "$BACKUP_DIR"
        local backup_zip="$BACKUP_DIR/uninstall_${TIMESTAMP}.zip"
        if [ "$BACKUP_CREATED" = false ]; then
            echo "📦 Creating backup before removal..."
            BACKUP_CREATED=true
        fi
        if command -v zip >/dev/null 2>&1; then
            if [ -d "$file" ]; then
                (cd "$(dirname "$file")" && zip -q -r -u "$backup_zip" "$(basename "$file")" 2>/dev/null) || \
                (cd "$(dirname "$file")" && zip -q -r "$backup_zip" "$(basename "$file")")
            else
                zip -q -u "$backup_zip" "$file" 2>/dev/null || zip -q "$backup_zip" "$file"
            fi
        fi
    fi
}

# Backup everything first
echo "📦 Backing up before removal..."
backup_before_remove "$TARGET_DIR/.autopilot/bmad-autopilot.sh"
backup_before_remove "$TARGET_DIR/.autopilot/config"
backup_before_remove "$TARGET_DIR/.autopilot/config.example"

if [ "$LOCAL_CLAUDE" = true ]; then
    backup_before_remove "$TARGET_DIR/.claude/commands/autopilot.md"
    backup_before_remove "$TARGET_DIR/.claude/commands/bmad-autopilot.md"
    backup_before_remove "$TARGET_DIR/.claude/commands/gh-pr.md"
    backup_before_remove "$TARGET_DIR/.claude/skills/bmad-autopilot"
    backup_before_remove "$TARGET_DIR/.claude/skills/gh-pr-handling"
fi

if [ "$GLOBAL_CLAUDE" = true ]; then
    backup_before_remove "$HOME/.claude/commands/autopilot.md"
    backup_before_remove "$HOME/.claude/commands/bmad-autopilot.md"
    backup_before_remove "$HOME/.claude/commands/gh-pr.md"
    backup_before_remove "$HOME/.claude/skills/bmad-autopilot"
    backup_before_remove "$HOME/.claude/skills/gh-pr-handling"
fi

if [ -f "$TARGET_DIR/.github/workflows/auto-approve.yml" ]; then
    backup_before_remove "$TARGET_DIR/.github/workflows/auto-approve.yml"
fi

if [ "$BACKUP_CREATED" = true ]; then
    echo "✅ Backup saved to: $BACKUP_DIR/uninstall_${TIMESTAMP}.zip"
fi
echo ""

# Remove components
echo "🗑️  Removing components..."

# Remove local Claude commands
if [ "$LOCAL_CLAUDE" = true ]; then
    rm -f "$TARGET_DIR/.claude/commands/autopilot.md" 2>/dev/null || true
    rm -f "$TARGET_DIR/.claude/commands/bmad-autopilot.md" 2>/dev/null || true
    rm -f "$TARGET_DIR/.claude/commands/gh-pr.md" 2>/dev/null || true
    rm -rf "$TARGET_DIR/.claude/skills/bmad-autopilot" 2>/dev/null || true
    rm -rf "$TARGET_DIR/.claude/skills/gh-pr-handling" 2>/dev/null || true
    echo "   ✓ Removed local Claude commands and skills"

    # Clean up empty directories
    rmdir "$TARGET_DIR/.claude/commands" 2>/dev/null || true
    rmdir "$TARGET_DIR/.claude/skills" 2>/dev/null || true
    rmdir "$TARGET_DIR/.claude" 2>/dev/null || true
fi

# Remove global Claude commands (ask first)
if [ "$GLOBAL_CLAUDE" = true ]; then
    echo ""
    read -p "   Remove global Claude commands/skills from ~/.claude? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$HOME/.claude/commands/autopilot.md" 2>/dev/null || true
        rm -f "$HOME/.claude/commands/bmad-autopilot.md" 2>/dev/null || true
        rm -f "$HOME/.claude/commands/gh-pr.md" 2>/dev/null || true
        rm -rf "$HOME/.claude/skills/bmad-autopilot" 2>/dev/null || true
        rm -rf "$HOME/.claude/skills/gh-pr-handling" 2>/dev/null || true
        echo "   ✓ Removed global Claude commands and skills"
    else
        echo "   ⏭️  Kept global Claude commands and skills"
    fi
fi

# Remove GitHub workflow (ask first)
if [ -f "$TARGET_DIR/.github/workflows/auto-approve.yml" ]; then
    echo ""
    read -p "   Remove GitHub auto-approve workflow? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$TARGET_DIR/.github/workflows/auto-approve.yml"
        echo "   ✓ Removed GitHub workflow"
        # Clean up empty directories
        rmdir "$TARGET_DIR/.github/workflows" 2>/dev/null || true
        rmdir "$TARGET_DIR/.github" 2>/dev/null || true
    else
        echo "   ⏭️  Kept GitHub workflow"
    fi
fi

# Remove main autopilot directory
echo ""
read -p "   Remove .autopilot directory (includes backups and state)? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Move backup out first if user wants to keep it
    if [ -d "$TARGET_DIR/.autopilot/backup" ]; then
        read -p "   Keep backup files in ./autopilot-backup/? [Y/n] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            mv "$TARGET_DIR/.autopilot/backup" "$TARGET_DIR/autopilot-backup"
            echo "   ✓ Backups moved to: $TARGET_DIR/autopilot-backup/"
        fi
    fi

    rm -rf "$TARGET_DIR/.autopilot"
    echo "   ✓ Removed .autopilot directory"
else
    # Just remove script and config, keep backups and state
    rm -f "$TARGET_DIR/.autopilot/bmad-autopilot.sh" 2>/dev/null || true
    rm -f "$TARGET_DIR/.autopilot/config" 2>/dev/null || true
    rm -f "$TARGET_DIR/.autopilot/config.example" 2>/dev/null || true
    echo "   ✓ Removed autopilot scripts (kept backups and state)"
fi

# Clean up .gitignore entry
if [ -f "$TARGET_DIR/.gitignore" ]; then
    if grep -q "^\.autopilot/$" "$TARGET_DIR/.gitignore" 2>/dev/null; then
        echo ""
        read -p "   Remove .autopilot/ from .gitignore? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Remove the autopilot entries
            sed -i.bak '/^# BMAD Autopilot/d' "$TARGET_DIR/.gitignore"
            sed -i.bak '/^\.autopilot\/$/d' "$TARGET_DIR/.gitignore"
            rm -f "$TARGET_DIR/.gitignore.bak"
            # Remove trailing empty lines
            sed -i.bak -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$TARGET_DIR/.gitignore" 2>/dev/null || true
            rm -f "$TARGET_DIR/.gitignore.bak"
            echo "   ✓ Removed .autopilot/ from .gitignore"
        fi
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Uninstallation complete!"
echo ""
if [ -d "$TARGET_DIR/autopilot-backup" ]; then
    echo "📦 Backups preserved in: $TARGET_DIR/autopilot-backup/"
    echo "   Delete manually when no longer needed"
    echo ""
fi
echo "To reinstall, run:"
echo "  ./install.sh $TARGET_DIR"
echo ""
