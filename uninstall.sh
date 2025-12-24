#!/usr/bin/env bash
#
# BMAD Autopilot Uninstaller
# Compatible with bash 3.x (macOS default)
#
set -euo pipefail

TARGET_DIR="${1:-$(pwd)}"
BACKUP_DIR="$TARGET_DIR/.autopilot-backups"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

echo "🗑️  BMAD Autopilot Uninstaller"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if autopilot is installed
if [ ! -d "$TARGET_DIR/.autopilot" ] && [ ! -d "$TARGET_DIR/.claude" ]; then
    echo "❌ No autopilot installation found in $TARGET_DIR"
    echo ""
    echo "Usage: ./uninstall.sh [project_dir]"
    exit 1
fi

echo "📍 Target directory: $TARGET_DIR"
echo ""

# Detect what's installed - use simple arrays (bash 3.x compatible)
echo "🔍 Detecting installed components..."

# Autopilot components (parallel arrays for name and path)
AUTOPILOT_NAMES=()
AUTOPILOT_PATHS=()

if [ -f "$TARGET_DIR/.autopilot/bmad-autopilot.sh" ]; then
    AUTOPILOT_NAMES+=("autopilot-script")
    AUTOPILOT_PATHS+=("$TARGET_DIR/.autopilot/bmad-autopilot.sh")
    echo "   ✓ Main script: .autopilot/bmad-autopilot.sh"
fi

if [ -f "$TARGET_DIR/.autopilot/config" ]; then
    AUTOPILOT_NAMES+=("autopilot-config")
    AUTOPILOT_PATHS+=("$TARGET_DIR/.autopilot/config")
    echo "   ✓ Config file: .autopilot/config"
fi

if [ -f "$TARGET_DIR/.autopilot/config.example" ]; then
    AUTOPILOT_NAMES+=("autopilot-config-example")
    AUTOPILOT_PATHS+=("$TARGET_DIR/.autopilot/config.example")
    echo "   ✓ Config example: .autopilot/config.example"
fi

if [ -d "$TARGET_DIR/.autopilot/state" ]; then
    AUTOPILOT_NAMES+=("autopilot-state")
    AUTOPILOT_PATHS+=("$TARGET_DIR/.autopilot/state")
    echo "   ✓ State files: .autopilot/state/"
fi

# Check local Claude commands
LOCAL_COMMANDS=()
if [ -f "$TARGET_DIR/.claude/commands/autopilot.md" ]; then
    LOCAL_COMMANDS+=("$TARGET_DIR/.claude/commands/autopilot.md")
    echo "   ✓ Local command: .claude/commands/autopilot.md"
fi
if [ -f "$TARGET_DIR/.claude/commands/bmad-autopilot.md" ]; then
    LOCAL_COMMANDS+=("$TARGET_DIR/.claude/commands/bmad-autopilot.md")
    echo "   ✓ Local command: .claude/commands/bmad-autopilot.md"
fi
if [ -f "$TARGET_DIR/.claude/commands/gh-pr.md" ]; then
    LOCAL_COMMANDS+=("$TARGET_DIR/.claude/commands/gh-pr.md")
    echo "   ✓ Local command: .claude/commands/gh-pr.md"
fi

# Check local Claude skills
LOCAL_SKILLS=()
if [ -d "$TARGET_DIR/.claude/skills/bmad-autopilot" ]; then
    LOCAL_SKILLS+=("$TARGET_DIR/.claude/skills/bmad-autopilot")
    echo "   ✓ Local skill: .claude/skills/bmad-autopilot/"
fi
if [ -d "$TARGET_DIR/.claude/skills/gh-pr-handling" ]; then
    LOCAL_SKILLS+=("$TARGET_DIR/.claude/skills/gh-pr-handling")
    echo "   ✓ Local skill: .claude/skills/gh-pr-handling/"
fi

# Check global Claude commands
GLOBAL_COMMANDS=()
if [ -f "$HOME/.claude/commands/autopilot.md" ]; then
    GLOBAL_COMMANDS+=("$HOME/.claude/commands/autopilot.md")
    echo "   ✓ Global command: ~/.claude/commands/autopilot.md"
fi
if [ -f "$HOME/.claude/commands/bmad-autopilot.md" ]; then
    GLOBAL_COMMANDS+=("$HOME/.claude/commands/bmad-autopilot.md")
    echo "   ✓ Global command: ~/.claude/commands/bmad-autopilot.md"
fi
if [ -f "$HOME/.claude/commands/gh-pr.md" ]; then
    GLOBAL_COMMANDS+=("$HOME/.claude/commands/gh-pr.md")
    echo "   ✓ Global command: ~/.claude/commands/gh-pr.md"
fi

# Check global Claude skills
GLOBAL_SKILLS=()
if [ -d "$HOME/.claude/skills/bmad-autopilot" ]; then
    GLOBAL_SKILLS+=("$HOME/.claude/skills/bmad-autopilot")
    echo "   ✓ Global skill: ~/.claude/skills/bmad-autopilot/"
fi
if [ -d "$HOME/.claude/skills/gh-pr-handling" ]; then
    GLOBAL_SKILLS+=("$HOME/.claude/skills/gh-pr-handling")
    echo "   ✓ Global skill: ~/.claude/skills/gh-pr-handling/"
fi

# Check GitHub workflow
GITHUB_WORKFLOW=""
if [ -f "$TARGET_DIR/.github/workflows/auto-approve.yml" ]; then
    GITHUB_WORKFLOW="$TARGET_DIR/.github/workflows/auto-approve.yml"
    echo "   ✓ GitHub workflow: .github/workflows/auto-approve.yml"
fi

echo ""

TOTAL_COMPONENTS=$((${#AUTOPILOT_PATHS[@]} + ${#LOCAL_COMMANDS[@]} + ${#LOCAL_SKILLS[@]} + ${#GLOBAL_COMMANDS[@]} + ${#GLOBAL_SKILLS[@]}))
if [ -n "$GITHUB_WORKFLOW" ]; then
    TOTAL_COMPONENTS=$((TOTAL_COMPONENTS + 1))
fi

if [ "$TOTAL_COMPONENTS" -eq 0 ]; then
    echo "❌ No autopilot components found to uninstall"
    exit 0
fi

# Confirm uninstallation
echo "⚠️  This will remove $TOTAL_COMPONENTS component(s)"
echo ""

read -p "Continue with uninstallation? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "⏹️  Uninstallation cancelled"
    exit 0
fi

echo ""

# Create backup directory and manifest
mkdir -p "$BACKUP_DIR"
BACKUP_ARCHIVE="$BACKUP_DIR/uninstall_${TIMESTAMP}.zip"
BACKUP_MANIFEST="$BACKUP_DIR/uninstall_${TIMESTAMP}.manifest"

echo "📦 Creating backup..."

# Initialize manifest
cat > "$BACKUP_MANIFEST" << EOF
# BMAD Autopilot Uninstall Backup Manifest
# Created: $(date '+%Y-%m-%dT%H:%M:%S')
# Target: $TARGET_DIR
# Archive: uninstall_${TIMESTAMP}.zip
#
# Format: TYPE|ORIGINAL_PATH|ARCHIVE_PATH
EOF

# Backup function that records to manifest
backup_item() {
    local item="$1"
    local type="$2"
    local archive_path="$3"

    if [ -e "$item" ]; then
        echo "   → $(basename "$item")"

        if command -v zip >/dev/null 2>&1; then
            if [ -d "$item" ]; then
                (cd "$(dirname "$item")" && zip -q -r -u "$BACKUP_ARCHIVE" "$(basename "$item")" 2>/dev/null) || \
                (cd "$(dirname "$item")" && zip -q -r "$BACKUP_ARCHIVE" "$(basename "$item")")
            else
                zip -q -u "$BACKUP_ARCHIVE" "$item" 2>/dev/null || zip -q "$BACKUP_ARCHIVE" "$item"
            fi
        else
            # Fallback: copy to backup dir
            mkdir -p "$BACKUP_DIR/files"
            if [ -d "$item" ]; then
                cp -r "$item" "$BACKUP_DIR/files/"
            else
                cp "$item" "$BACKUP_DIR/files/"
            fi
        fi

        # Record in manifest
        echo "$type|$item|$archive_path" >> "$BACKUP_MANIFEST"
    fi
}

# Backup autopilot files
for i in "${!AUTOPILOT_PATHS[@]}"; do
    path="${AUTOPILOT_PATHS[$i]}"
    backup_item "$path" "autopilot" ".autopilot/$(basename "$path")"
done

# Backup local commands
if [ ${#LOCAL_COMMANDS[@]} -gt 0 ]; then
    for cmd in "${LOCAL_COMMANDS[@]}"; do
        backup_item "$cmd" "local-command" ".claude/commands/$(basename "$cmd")"
    done
fi

# Backup local skills
if [ ${#LOCAL_SKILLS[@]} -gt 0 ]; then
    for skill in "${LOCAL_SKILLS[@]}"; do
        backup_item "$skill" "local-skill" ".claude/skills/$(basename "$skill")"
    done
fi

# Backup global commands
if [ ${#GLOBAL_COMMANDS[@]} -gt 0 ]; then
    for cmd in "${GLOBAL_COMMANDS[@]}"; do
        backup_item "$cmd" "global-command" "~/.claude/commands/$(basename "$cmd")"
    done
fi

# Backup global skills
if [ ${#GLOBAL_SKILLS[@]} -gt 0 ]; then
    for skill in "${GLOBAL_SKILLS[@]}"; do
        backup_item "$skill" "global-skill" "~/.claude/skills/$(basename "$skill")"
    done
fi

# Backup GitHub workflow
if [ -n "$GITHUB_WORKFLOW" ]; then
    backup_item "$GITHUB_WORKFLOW" "github-workflow" ".github/workflows/auto-approve.yml"
fi

echo ""
echo "✅ Backup saved to: $BACKUP_DIR/"
echo "   Archive:  uninstall_${TIMESTAMP}.zip"
echo "   Manifest: uninstall_${TIMESTAMP}.manifest"
echo ""

# Remove components
echo "🗑️  Removing components..."

# Remove autopilot files
if [ ${#AUTOPILOT_PATHS[@]} -gt 0 ]; then
    for path in "${AUTOPILOT_PATHS[@]}"; do
        rm -rf "$path" 2>/dev/null || true
    done
    echo "   ✓ Removed autopilot files"
fi

# Remove local Claude commands
LOCAL_COMMANDS_COUNT=${#LOCAL_COMMANDS[@]}
if [ "$LOCAL_COMMANDS_COUNT" -gt 0 ]; then
    for cmd in "${LOCAL_COMMANDS[@]}"; do
        rm -f "$cmd" 2>/dev/null || true
    done
    echo "   ✓ Removed local Claude commands"

    # Clean up empty directories
    rmdir "$TARGET_DIR/.claude/commands" 2>/dev/null || true
fi

# Remove local Claude skills
LOCAL_SKILLS_COUNT=${#LOCAL_SKILLS[@]}
if [ "$LOCAL_SKILLS_COUNT" -gt 0 ]; then
    for skill in "${LOCAL_SKILLS[@]}"; do
        rm -rf "$skill" 2>/dev/null || true
    done
    echo "   ✓ Removed local Claude skills"

    # Clean up empty directories
    rmdir "$TARGET_DIR/.claude/skills" 2>/dev/null || true
fi

# Clean up .claude directory if empty
rmdir "$TARGET_DIR/.claude" 2>/dev/null || true

# Remove global Claude commands (ask first)
GLOBAL_COMMANDS_COUNT=${#GLOBAL_COMMANDS[@]}
if [ "$GLOBAL_COMMANDS_COUNT" -gt 0 ]; then
    echo ""
    read -p "   Remove global Claude commands from ~/.claude/commands/? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for cmd in "${GLOBAL_COMMANDS[@]}"; do
            rm -f "$cmd" 2>/dev/null || true
        done
        echo "   ✓ Removed global Claude commands"
    else
        echo "   ⏭️  Kept global Claude commands"
    fi
fi

# Remove global Claude skills (ask first)
GLOBAL_SKILLS_COUNT=${#GLOBAL_SKILLS[@]}
if [ "$GLOBAL_SKILLS_COUNT" -gt 0 ]; then
    echo ""
    read -p "   Remove global Claude skills from ~/.claude/skills/? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for skill in "${GLOBAL_SKILLS[@]}"; do
            rm -rf "$skill" 2>/dev/null || true
        done
        echo "   ✓ Removed global Claude skills"
    else
        echo "   ⏭️  Kept global Claude skills"
    fi
fi

# Remove GitHub workflow (ask first)
if [ -n "$GITHUB_WORKFLOW" ]; then
    echo ""
    read -p "   Remove GitHub auto-approve workflow? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$GITHUB_WORKFLOW"
        echo "   ✓ Removed GitHub workflow"
        # Clean up empty directories
        rmdir "$TARGET_DIR/.github/workflows" 2>/dev/null || true
        rmdir "$TARGET_DIR/.github" 2>/dev/null || true
    else
        echo "   ⏭️  Kept GitHub workflow"
    fi
fi

# Remove main autopilot directory if empty or ask
if [ -d "$TARGET_DIR/.autopilot" ]; then
    # Check if only backup dir remains
    remaining=$(find "$TARGET_DIR/.autopilot" -mindepth 1 -maxdepth 1 ! -name "backup" | wc -l)
    if [ "$remaining" -eq 0 ]; then
        # Only backup dir or empty - clean up
        if [ -d "$TARGET_DIR/.autopilot/backup" ]; then
            # Move old backups to new location
            mv "$TARGET_DIR/.autopilot/backup/"* "$BACKUP_DIR/" 2>/dev/null || true
            rmdir "$TARGET_DIR/.autopilot/backup" 2>/dev/null || true
        fi
        rmdir "$TARGET_DIR/.autopilot" 2>/dev/null || true
        echo "   ✓ Cleaned up .autopilot directory"
    fi
fi

# Clean up .gitignore entry
if [ -f "$TARGET_DIR/.gitignore" ]; then
    if grep -q "^\.autopilot/$" "$TARGET_DIR/.gitignore" 2>/dev/null; then
        echo ""
        read -p "   Remove .autopilot/ from .gitignore? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Remove the autopilot entries (macOS compatible)
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' '/^# BMAD Autopilot/d' "$TARGET_DIR/.gitignore"
                sed -i '' '/^\.autopilot\/$/d' "$TARGET_DIR/.gitignore"
                sed -i '' '/^\.autopilot-backups\/$/d' "$TARGET_DIR/.gitignore"
            else
                sed -i '/^# BMAD Autopilot/d' "$TARGET_DIR/.gitignore"
                sed -i '/^\.autopilot\/$/d' "$TARGET_DIR/.gitignore"
                sed -i '/^\.autopilot-backups\/$/d' "$TARGET_DIR/.gitignore"
            fi
            echo "   ✓ Removed .autopilot/ from .gitignore"
        fi
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Uninstallation complete!"
echo ""
echo "📦 Backups saved to: $BACKUP_DIR/"
echo ""
echo "To restore from backup, run:"
echo "  ./install.sh --restore $BACKUP_DIR/uninstall_${TIMESTAMP}.manifest"
echo ""
echo "To reinstall fresh, run:"
echo "  ./install.sh $TARGET_DIR"
echo ""
