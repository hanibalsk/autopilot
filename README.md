# BMAD Autopilot

**Autonomous Development Orchestrator for Claude Code**

BMAD Autopilot is a state-machine-driven bash orchestrator that automates the entire development cycle from epic selection to PR merge. It works with Claude Code CLI and GitHub Copilot to provide a fully autonomous development experience.

## Features

- 🤖 **Fully Autonomous** - No human intervention required after starting
- 🔄 **State Machine** - Resumable workflow that survives interruptions
- 📋 **Multi-Epic Support** - Process all epics or filter by pattern
- 🔍 **GitHub Copilot Integration** - Waits for reviews, fixes issues, replies to comments
- ✅ **CI Integration** - Waits for checks, fixes failures automatically
- 📝 **Detailed Logging** - Full audit trail in `.autopilot/autopilot.log`
- 🔀 **Parallel Mode** - Work on next epic while waiting for PR review (experimental)
- 🔒 **Secure Config** - Safe config parsing with whitelisted keys only

## Prerequisites

Required tools:
- `claude` - [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- `gh` - [GitHub CLI](https://cli.github.com/)
- `jq` - JSON processor
- `rg` - [ripgrep](https://github.com/BurntSushi/ripgrep)
- `git` - Git version control

## Installation

### Quick Install

```bash
# Clone the repository
git clone https://github.com/hanibalsk/autopilot.git
cd autopilot

# Run the install script
./install.sh
```

### Manual Install

1. Copy the main script to your project:

```bash
mkdir -p /your/project/.autopilot
cp scripts/bmad-autopilot.sh /your/project/.autopilot/
chmod +x /your/project/.autopilot/bmad-autopilot.sh
```

2. (Optional) Install Claude Code commands:

```bash
# Local installation (recommended)
mkdir -p /your/project/.claude/commands
cp commands/*.md /your/project/.claude/commands/

# Or global installation
mkdir -p ~/.claude/commands
cp commands/*.md ~/.claude/commands/
```

## Usage

### Basic Usage

```bash
# From your project root:
cd /path/to/your/project

# Process ALL epics from _bmad-output/epics.md
./.autopilot/bmad-autopilot.sh

# Process specific epics only
./.autopilot/bmad-autopilot.sh "7A 8A 10B"

# Process epic with suffix
./.autopilot/bmad-autopilot.sh "10A-SSO"

# Use regex patterns
./.autopilot/bmad-autopilot.sh "10A.*"      # matches 10A, 10A-SSO, etc.
./.autopilot/bmad-autopilot.sh "7.* 10.*"   # multiple patterns
```

### Resume After Interruption

```bash
# Resume from where it left off
./.autopilot/bmad-autopilot.sh --continue

# Resume with specific pattern
./.autopilot/bmad-autopilot.sh "7A" --continue
```

### Using Claude Code Commands

If you installed the Claude Code commands:

```
/autopilot           # process all epics
/autopilot 7A 8A     # specific epics
```

## Workflow State Machine

```
┌─────────────────────────────────────────────────────────────────┐
│  INIT -> CHECK_PENDING_PR -> FIND_EPIC -> CREATE_BRANCH ->     │
│  DEVELOP_STORIES -> CODE_REVIEW -> CREATE_PR ->                 │
│  WAIT_COPILOT -> WAIT_CHECKS -> MERGE_PR -> (loop) -> DONE     │
│       │              │                                          │
│       ▼              ▼                                          │
│  FIX_ISSUES ◄────────┴─── (fix Copilot comments + CI failures) │
│       │                                                         │
│       └──────► WAIT_COPILOT (re-review after fixes)            │
└─────────────────────────────────────────────────────────────────┘
```

### Phase Descriptions

| Phase | Description |
|-------|-------------|
| `CHECK_PENDING_PR` | Look for unfinished PRs from previous runs |
| `FIND_EPIC` | Find next epic from `_bmad-output/epics*.md` |
| `CREATE_BRANCH` | Create `feature/epic-{ID}` branch |
| `DEVELOP_STORIES` | Run BMAD dev-story workflow via Claude |
| `CODE_REVIEW` | Run BMAD code-review workflow, fix issues |
| `CREATE_PR` | Create PR, request Copilot review |
| `WAIT_COPILOT` | Wait for Copilot to comment (it always does) |
| `WAIT_CHECKS` | Wait for CI checks to pass |
| `FIX_ISSUES` | Fix Copilot/CI issues, post reply, loop back |
| `MERGE_PR` | Squash merge, delete branch, mark complete |
| `DONE` | All epics processed! |
| `BLOCKED` | Manual intervention needed |

## Configuration

### Configuration File

Copy `config.example` to `.autopilot/config` and customize:

```bash
cp .autopilot/config.example .autopilot/config
```

Settings can be configured via (in order of priority):
1. Command line flags (`--debug`)
2. Environment variables (`AUTOPILOT_DEBUG=1`)
3. Config file (`.autopilot/config`)

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOPILOT_DEBUG` | `0` | Enable debug logging to `.autopilot/tmp/debug.log` |
| `MAX_TURNS` | `80` | Max Claude turns per phase |
| `CHECK_INTERVAL` | `30` | Seconds between CI/Copilot checks |
| `MAX_CHECK_WAIT` | `60` | Max iterations waiting for CI checks |
| `MAX_COPILOT_WAIT` | `60` | Max iterations waiting for Copilot review |
| `AUTOPILOT_RUN_MOBILE_NATIVE` | `0` | Set to `1` to run Gradle builds |
| `AUTOPILOT_BASE_BRANCH` | auto | Override base branch (auto-detects main/master) |

### Parallel Mode (Experimental)

| Variable | Default | Description |
|----------|---------|-------------|
| `PARALLEL_MODE` | `0` | Enable parallel epic development |
| `PARALLEL_CHECK_INTERVAL` | `60` | Seconds between pending PR checks |
| `MAX_PENDING_PRS` | `2` | Max concurrent PRs waiting for review |

When enabled, the autopilot will start working on the next epic while PRs are waiting for review. Uses git worktrees to manage multiple concurrent branches.

### Epic Source Files

The autopilot reads epics from `_bmad-output/` directory:

- `epics.md`
- `@epics.md`
- `epics-002.md`, `epics-*.md`, etc.

Epic IDs are extracted from lines like:
```markdown
#### Epic 7A: User Authentication
#### Epic 10A-SSO: Cross-Platform SSO
```

## Project Structure

```
.autopilot/
├── bmad-autopilot.sh    # Main orchestrator script
├── state.json           # Current state (auto-managed)
├── autopilot.log        # Full execution log
└── tmp/                 # Temporary files
    ├── copilot.txt
    ├── copilot_latest.json
    └── claude-output.txt
```

## Customization

### Local Checks

The `autopilot_checks()` function in the script auto-detects your project type:

- **Rust** (`backend/Cargo.toml`): `cargo fmt`, `cargo clippy`, `cargo test`
- **TypeScript/pnpm** (`frontend/package.json`): `pnpm run check`, `pnpm run test`
- **Gradle** (`mobile-native/gradlew`): Optional, set `AUTOPILOT_RUN_MOBILE_NATIVE=1`

Modify this function to add your own checks.

### BMAD Workflows

The script calls these BMAD workflows:
- `/bmad:bmm:workflows:dev-story` - Story development
- `/bmad:bmm:workflows:code-review` - Code review

Ensure these are available in your `.claude/commands/bmad/` or `.cursor/rules/bmad/`.

## Troubleshooting

### View Logs

```bash
tail -f .autopilot/autopilot.log
```

### Check State

```bash
cat .autopilot/state.json | jq
```

### Reset State

```bash
rm .autopilot/state.json
```

### Debug Mode

```bash
# Via command line flag
./.autopilot/bmad-autopilot.sh --debug

# Via environment variable
AUTOPILOT_DEBUG=1 ./.autopilot/bmad-autopilot.sh

# View debug log
tail -f .autopilot/tmp/debug.log
```

Debug mode logs detailed information about Copilot detection, state transitions, and API calls.

## License

MIT License - see [LICENSE](LICENSE)

## Contributing

Contributions welcome! Please read the contributing guidelines first.

## Credits

Built for use with [BMAD Method](https://github.com/bmad-method) and Claude Code.
