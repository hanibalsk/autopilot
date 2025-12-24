#!/usr/bin/env bash
#
# BMAD Autopilot Installer
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR=""
RESTORE_MANIFEST=""
BACKUP_DIR=""
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

# Read version from VERSION file
AUTOPILOT_VERSION="0.1.0"
if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    AUTOPILOT_VERSION=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')
fi

usage() {
    cat <<EOF
BMAD Autopilot Installer v$AUTOPILOT_VERSION

Usage:
  ./install.sh [options] [project_dir]

Options:
  --restore FILE    Restore from uninstall backup manifest
  --list-backups    List available backup manifests
  --help            Show this help

Examples:
  ./install.sh                              # Install to current directory
  ./install.sh /path/to/project             # Install to specific directory
  ./install.sh --restore path/to/manifest   # Restore from backup
  ./install.sh --list-backups               # List available backups
EOF
}

list_backups() {
    local search_dir="${1:-$(pwd)}"
    local backup_dir="$search_dir/.autopilot-backups"

    echo "📦 Available backup manifests:"
    echo ""

    if [ -d "$backup_dir" ]; then
        local found=false
        for manifest in "$backup_dir"/*.manifest; do
            if [ -f "$manifest" ]; then
                found=true
                local date_str=$(basename "$manifest" | sed 's/uninstall_//' | sed 's/.manifest//')
                local formatted_date=$(echo "$date_str" | sed 's/_/ /' | sed 's/\(....\)\(..\)\(..\)/\1-\2-\3/')
                echo "   $manifest"
                echo "      Created: $formatted_date"

                # Count items in manifest
                local count=$(grep -v "^#" "$manifest" | grep -c "|" || echo "0")
                echo "      Items: $count"
                echo ""
            fi
        done

        if [ "$found" = false ]; then
            echo "   No backup manifests found in $backup_dir"
        fi
    else
        echo "   No backup directory found at $backup_dir"
    fi

    echo ""
    echo "To restore, run:"
    echo "  ./install.sh --restore <manifest_path>"
}

restore_from_backup() {
    local manifest="$1"

    if [ ! -f "$manifest" ]; then
        echo "❌ Manifest file not found: $manifest"
        exit 1
    fi

    echo "🔄 BMAD Autopilot Restore"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📋 Manifest: $manifest"

    # Parse manifest header
    local target_dir=$(grep "^# Target:" "$manifest" | cut -d: -f2 | tr -d ' ')
    local archive_name=$(grep "^# Archive:" "$manifest" | cut -d: -f2 | tr -d ' ')
    local backup_dir=$(dirname "$manifest")
    local archive="$backup_dir/$archive_name"

    echo "   Target:  $target_dir"
    echo "   Archive: $archive"
    echo ""

    if [ ! -f "$archive" ]; then
        echo "❌ Archive file not found: $archive"
        echo ""
        echo "Looking for fallback files..."

        if [ -d "$backup_dir/files" ]; then
            echo "   Found: $backup_dir/files/"
            archive=""
        else
            echo "   No fallback files found"
            exit 1
        fi
    fi

    # List items to restore
    echo "📦 Items to restore:"
    local restore_count=0
    while IFS='|' read -r type original_path archive_path; do
        # Skip comments and empty lines
        [[ "$type" =~ ^# ]] && continue
        [[ -z "$type" ]] && continue

        restore_count=$((restore_count + 1))
        case "$type" in
            autopilot) echo "   • Autopilot: $archive_path" ;;
            local-command) echo "   • Local command: $archive_path" ;;
            local-skill) echo "   • Local skill: $archive_path" ;;
            global-command) echo "   • Global command: $archive_path" ;;
            global-skill) echo "   • Global skill: $archive_path" ;;
            github-workflow) echo "   • GitHub workflow: $archive_path" ;;
            *) echo "   • Unknown: $archive_path" ;;
        esac
    done < "$manifest"

    echo ""
    echo "Total: $restore_count item(s)"
    echo ""

    read -p "Continue with restore? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "⏹️  Restore cancelled"
        exit 0
    fi

    echo ""
    echo "🔄 Restoring files..."

    # Create temp directory for extraction
    local temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT

    # Extract archive if it exists
    if [ -n "$archive" ] && [ -f "$archive" ]; then
        unzip -q "$archive" -d "$temp_dir"
    fi

    # Restore each item
    while IFS='|' read -r type original_path archive_path; do
        # Skip comments and empty lines
        [[ "$type" =~ ^# ]] && continue
        [[ -z "$type" ]] && continue

        local source_path=""
        if [ -n "$archive" ]; then
            # Find in extracted archive
            source_path=$(find "$temp_dir" -path "*$archive_path" -o -name "$(basename "$archive_path")" 2>/dev/null | head -1)
        fi

        # Fallback to files directory
        if [ -z "$source_path" ] || [ ! -e "$source_path" ]; then
            source_path="$backup_dir/files/$(basename "$archive_path")"
        fi

        if [ -e "$source_path" ]; then
            # Determine destination based on type
            local dest_path=""
            case "$type" in
                autopilot)
                    dest_path="$target_dir/.autopilot/$(basename "$archive_path")"
                    mkdir -p "$target_dir/.autopilot"
                    ;;
                local-command)
                    dest_path="$target_dir/.claude/commands/$(basename "$archive_path")"
                    mkdir -p "$target_dir/.claude/commands"
                    ;;
                local-skill)
                    dest_path="$target_dir/.claude/skills/$(basename "$archive_path")"
                    mkdir -p "$target_dir/.claude/skills"
                    ;;
                global-command)
                    dest_path="$HOME/.claude/commands/$(basename "$archive_path")"
                    mkdir -p "$HOME/.claude/commands"
                    ;;
                global-skill)
                    dest_path="$HOME/.claude/skills/$(basename "$archive_path")"
                    mkdir -p "$HOME/.claude/skills"
                    ;;
                github-workflow)
                    dest_path="$target_dir/.github/workflows/$(basename "$archive_path")"
                    mkdir -p "$target_dir/.github/workflows"
                    ;;
            esac

            if [ -n "$dest_path" ]; then
                if [ -d "$source_path" ]; then
                    cp -r "$source_path" "$dest_path"
                else
                    cp "$source_path" "$dest_path"
                fi
                echo "   ✓ Restored: $(basename "$archive_path")"
            fi
        else
            echo "   ⚠️  Not found: $(basename "$archive_path")"
        fi
    done < "$manifest"

    # Make script executable
    if [ -f "$target_dir/.autopilot/bmad-autopilot.sh" ]; then
        chmod +x "$target_dir/.autopilot/bmad-autopilot.sh"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎉 Restore complete!"
    echo ""
    echo "Usage:"
    echo "  cd $target_dir"
    echo "  ./.autopilot/bmad-autopilot.sh"
    echo ""
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --restore|-r)
            RESTORE_MANIFEST="$2"
            shift 2
            ;;
        --list-backups|-l)
            list_backups "${2:-$(pwd)}"
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "" >&2
            usage >&2
            exit 1
            ;;
        *)
            TARGET_DIR="$1"
            shift
            ;;
    esac
done

# Handle restore mode
if [ -n "$RESTORE_MANIFEST" ]; then
    restore_from_backup "$RESTORE_MANIFEST"
    exit 0
fi

# Set default target directory
TARGET_DIR="${TARGET_DIR:-$(pwd)}"
BACKUP_DIR="$TARGET_DIR/.autopilot/backup"

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
        echo ".autopilot-backups/" >> "$TARGET_DIR/.gitignore"
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
echo "Other commands:"
echo "  ./uninstall.sh                           # uninstall (creates backup)"
echo "  ./install.sh --list-backups              # list available backups"
echo "  ./install.sh --restore <manifest>        # restore from backup"
echo ""
