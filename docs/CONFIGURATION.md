# Configuration Guide

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_TURNS` | `80` | Maximum Claude turns per phase |
| `CHECK_INTERVAL` | `30` | Seconds between CI/Copilot checks |
| `MAX_CHECK_WAIT` | `60` | Maximum iterations waiting for checks |
| `AUTOPILOT_RUN_MOBILE_NATIVE` | `0` | Set to `1` to run Gradle builds |

### Example

```bash
# Run with custom settings
MAX_TURNS=100 CHECK_INTERVAL=60 ./.autopilot/bmad-autopilot.sh
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
[2024-12-23 10:30:45] 🚀 BMAD Autopilot starting (fresh)
[2024-12-23 10:30:46] ━━━ Current phase: CHECK_PENDING_PR ━━━
[2024-12-23 10:30:47] ✅ No pending PRs found
[2024-12-23 10:30:48] 📋 PHASE: FIND_EPIC
```

### Debug Logging

Debug logs are prefixed with `DEBUG:`:

```
[2024-12-23 10:31:00] DEBUG: Fetching all comments/reviews authors...
[2024-12-23 10:31:01] DEBUG: Comments: user1 | Reviews: copilot[bot](APPROVED)
```

## Ignoring Files

Add to your `.gitignore`:

```gitignore
# BMAD Autopilot (local)
.autopilot/
```

The installer does this automatically.

