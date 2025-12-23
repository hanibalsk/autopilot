# CLAUDE.md - BMAD Autopilot

## Project Overview

BMAD Autopilot is an **installable autonomous development orchestrator** for Claude Code. It's a bash-based state machine that automates the entire development cycle from epic selection through PR merge.

**This is NOT a standalone project** - it's a toolkit that gets installed INTO other projects via `install.sh`.

## What Gets Installed

When a user runs `./install.sh /path/to/target`:

1. **Main script** → `{target}/.autopilot/bmad-autopilot.sh`
2. **Claude commands** (optional) → `{target}/.claude/commands/*.md` (project-local, not global)
3. **gitignore entry** → `.autopilot/` added to target's `.gitignore`

## Repository Structure

```
autopilot/
├── scripts/
│   └── bmad-autopilot.sh    # Main orchestrator (830 lines bash)
├── commands/
│   ├── autopilot.md         # Claude slash command /autopilot
│   └── bmad-autopilot.md    # Alternative command
├── docs/
│   ├── ARCHITECTURE.md      # State machine details
│   ├── CONFIGURATION.md     # Environment variables
│   └── TROUBLESHOOTING.md   # Debug guide
├── install.sh               # Installer script
└── README.md                # User documentation
```

## State Machine

The autopilot operates as a finite state machine with phases:

```
CHECK_PENDING_PR → FIND_EPIC → CREATE_BRANCH → DEVELOP_STORIES →
CODE_REVIEW → CREATE_PR → WAIT_COPILOT → WAIT_CHECKS → MERGE_PR → (loop)
                                ↓              ↓
                           FIX_ISSUES ←────────┘
```

State persists in `.autopilot/state.json` allowing resume after interruptions.

## Key Integrations

### Claude Code CLI
- Runs headless with `claude -p "prompt" --permission-mode acceptEdits`
- Uses BMAD workflows: `/bmad:bmm:workflows:dev-story`, `/bmad:bmm:workflows:code-review`
- Max 80 turns per phase by default

### GitHub CLI (`gh`)
- PR creation, management, merging
- Copilot review monitoring (detects `copilot[bot]` comments/reviews)
- CI check status polling

### GitHub Copilot
- Waits for Copilot review on every PR
- Detects APPROVED, CHANGES_REQUESTED, or actionable comments
- Fixes issues and loops back for re-review

## Development Guidelines

### When Modifying the Script

1. **State transitions** are in the `main()` function's case statement
2. **Phase logic** is in `phase_*` functions (e.g., `phase_wait_copilot`)
3. **Helper functions** at top: `state_*`, `require_*`, `parse_*`

### Testing Changes

Since this installs to OTHER projects, test by:
```bash
# Create test target
mkdir -p /tmp/test-project && cd /tmp/test-project
git init && touch README.md && git add . && git commit -m "init"

# Install from this repo
/path/to/autopilot/install.sh .

# Verify
ls -la .autopilot/
cat ~/.claude/commands/autopilot.md
```

### Adding New Phases

1. Add case in `main()` switch
2. Create `phase_new_phase()` function
3. Update state transitions with `state_set "NEW_PHASE" "\"$epic_id\""`
4. Document in `docs/ARCHITECTURE.md`

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAX_TURNS` | 80 | Claude turns per phase |
| `CHECK_INTERVAL` | 30 | Seconds between CI/Copilot polls |
| `MAX_CHECK_WAIT` | 60 | Max poll iterations |
| `AUTOPILOT_RUN_MOBILE_NATIVE` | 0 | Enable Gradle builds |

## Common Commands

```bash
# Test installer
./install.sh /tmp/test-project

# View script without installing
less scripts/bmad-autopilot.sh

# Check command format
cat commands/autopilot.md
```

## Design Principles

1. **Zero dependencies beyond prerequisites** - pure bash, uses standard tools
2. **Resumable** - state file allows recovery from any interruption
3. **Non-invasive** - installs to `.autopilot/` which is gitignored
4. **Copilot-aware** - waits for and responds to Copilot reviews
5. **BMAD-integrated** - uses BMAD workflows for story development
