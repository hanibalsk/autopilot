# Configuration Guide

## Environment Variables

### Core Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOPILOT_DEBUG` | `0` | Enable debug logging to `.autopilot/tmp/debug.log` |
| `MAX_TURNS` | `80` | Maximum Claude turns per phase |
| `CHECK_INTERVAL` | `30` | Seconds between CI/Copilot checks |
| `MAX_CHECK_WAIT` | `60` | Maximum iterations waiting for CI checks |
| `MAX_COPILOT_WAIT` | `60` | Maximum iterations waiting for Copilot review |
| `AUTOPILOT_RUN_MOBILE_NATIVE` | `0` | Set to `1` to run Gradle builds |
| `AUTOPILOT_BASE_BRANCH` | auto | Override base branch (auto-detects main/master) |

### Parallel Mode Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `PARALLEL_MODE` | `0` | Enable parallel epic development |
| `PARALLEL_CHECK_INTERVAL` | `60` | Seconds between pending PR checks |
| `MAX_PENDING_PRS` | `2` | Maximum concurrent PRs waiting for review |

### Example

```bash
# Run with custom settings
MAX_TURNS=100 CHECK_INTERVAL=60 ./.autopilot/bmad-autopilot.sh

# Enable debug mode
./.autopilot/bmad-autopilot.sh --debug

# Enable parallel mode
PARALLEL_MODE=1 ./.autopilot/bmad-autopilot.sh
```

## Configuration File

Settings can be configured in `.autopilot/config` using key=value format:

```bash
# Copy example config
cp .autopilot/config.example .autopilot/config
```

### Config Priority

Settings are applied in this order (later overrides earlier):
1. Default values in script
2. Config file (`.autopilot/config`)
3. Environment variables
4. Command line flags (`--debug`)

### Security

The config file parser uses a **whitelist approach** - only known configuration keys are accepted. This prevents arbitrary code execution if a malicious config file is provided.

Allowed keys:
```
AUTOPILOT_DEBUG, MAX_TURNS, CHECK_INTERVAL, MAX_CHECK_WAIT, MAX_COPILOT_WAIT,
AUTOPILOT_RUN_MOBILE_NATIVE, PARALLEL_MODE, PARALLEL_CHECK_INTERVAL,
MAX_PENDING_PRS, AUTOPILOT_BASE_BRANCH
```

Unknown keys are logged with a warning and ignored.

## Base Branch Detection

The script auto-detects the default branch in this order:
1. `AUTOPILOT_BASE_BRANCH` environment variable or config (if set)
2. `origin/HEAD` symbolic ref
3. Existence of `main` branch
4. Existence of `master` branch
5. Falls back to `main`

Override with:
```bash
AUTOPILOT_BASE_BRANCH=develop ./.autopilot/bmad-autopilot.sh
```

## Epic Source Files

The autopilot looks for epic definitions in `_bmad-output/`:

### Supported Filenames

- `epics.md` (primary)
- `@epics.md` (alternative)
- `epics-001.md`, `epics-002.md`, etc. (numbered versions)
- Any file matching `epics*.md` pattern

### Epic Format

Epics are extracted from markdown headers:

```markdown
#### Epic 1: User Authentication
...

#### Epic 7A: Organizations
...

#### Epic 10A-SSO: Cross-Platform SSO
...
```

Supported ID formats:
- Numeric: `1`, `2`, `10`
- Alphanumeric: `7A`, `10B`
- With suffix: `10A-SSO`, `7B-2`

## Local Checks Configuration

### Auto-Detection

The autopilot automatically detects your project type:

```bash
# Rust (backend/Cargo.toml)
cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace

# TypeScript/pnpm (frontend/package.json)
pnpm run check
pnpm run typecheck  # if script exists
pnpm run test       # if script exists

# Gradle (mobile-native/gradlew)
# Only if AUTOPILOT_RUN_MOBILE_NATIVE=1
./gradlew build
```

### Custom Checks

Edit the `autopilot_checks()` function in `bmad-autopilot.sh`:

```bash
autopilot_checks() {
  # Your custom checks
  cd "$ROOT_DIR"
  
  npm run lint
  npm run test
  npm run build
  
  # Python example
  if [ -f "pyproject.toml" ]; then
    poetry run pytest
    poetry run ruff check .
  fi
}
```

## BMAD Workflow Customization

### Default Workflows

The autopilot uses these BMAD workflows:

```bash
/bmad:bmm:workflows:dev-story    # Story development
/bmad:bmm:workflows:code-review  # Code review
```

### Custom Prompts

You can modify the Claude prompts in the script:

```bash
# In phase_develop_stories()
run_claude_headless "
/your-custom-workflow

Your custom instructions here...
"
```

## GitHub Integration

### Branch Naming

Default pattern: `feature/epic-{ID}`

Examples:
- `feature/epic-1`
- `feature/epic-7A`
- `feature/epic-10A-SSO`

### PR Labels

Default labels: `epic`, `automated`, `epic-{ID}`

### Copilot Review

Copilot review is typically triggered automatically by branch protection on push.

```
(If needed) request a review manually in the PR UI or via GitHub settings/automation.
```

## State Management

### State File Location

`.autopilot/state.json`

### State Structure

```json
{
  "phase": "DEVELOP_STORIES",
  "current_epic": "7A",
  "completed_epics": ["1", "2A", "2B"]
}
```

### Manual State Manipulation

```bash
# Reset state
rm .autopilot/state.json

# View current state
cat .autopilot/state.json | jq

# Force a specific phase
echo '{"phase":"CODE_REVIEW","current_epic":"7A","completed_epics":[]}' > .autopilot/state.json
```

## Logging

### Log Location

`.autopilot/autopilot.log`

### Log Format

```
[2024-12-23 10:30:45] BMAD Autopilot starting (fresh)
[2024-12-23 10:30:46] Current phase: CHECK_PENDING_PR
[2024-12-23 10:30:47] No pending PRs found
[2024-12-23 10:30:48] PHASE: FIND_EPIC
```

### Debug Logging

Enable debug mode via:
- Command line: `--debug` flag
- Environment: `AUTOPILOT_DEBUG=1`
- Config file: `AUTOPILOT_DEBUG=1`

Debug logs are written to `.autopilot/tmp/debug.log` and prefixed with `DEBUG:`:

```
[2024-12-23 10:31:00] DEBUG: Fetching all comments/reviews authors...
[2024-12-23 10:31:01] DEBUG: Comments: user1 | Reviews: copilot[bot](APPROVED)
```

View debug log in real-time:
```bash
tail -f .autopilot/tmp/debug.log
```

## Ignoring Files

Add to your `.gitignore`:

```gitignore
# BMAD Autopilot (local)
.autopilot/
```

The installer does this automatically.

