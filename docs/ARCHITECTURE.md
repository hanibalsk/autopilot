# BMAD Autopilot Architecture

## Overview

BMAD Autopilot is a state-machine-driven bash orchestrator that automates the entire development lifecycle from epic discovery to PR merge.

## Core Components

### 1. State Machine

The autopilot operates as a finite state machine with the following states:

```
CHECK_PENDING_PR → FIND_EPIC → CREATE_BRANCH → DEVELOP_STORIES → 
CODE_REVIEW → CREATE_PR → WAIT_COPILOT → WAIT_CHECKS → MERGE_PR → (loop)
                                ↓              ↓
                           FIX_ISSUES ←────────┘
                                ↓
                           WAIT_COPILOT (re-review)
```

### 2. State Persistence

State is stored in `.autopilot/state.json`:

```json
{
  "phase": "WAIT_COPILOT",
  "current_epic": "7A",
  "completed_epics": ["1", "2A", "2B"]
}
```

This allows the autopilot to resume after interruptions.

### 3. Claude Code Integration

The autopilot uses Claude Code CLI (`claude`) for AI-powered tasks:

- **Story Development**: Implements features based on epic requirements
- **Code Review**: Reviews and fixes code quality issues
- **Issue Fixing**: Addresses CI failures and Copilot feedback

### 4. GitHub Integration

Uses GitHub CLI (`gh`) for:

- Branch management
- PR creation and management
- Copilot review monitoring
- CI check status
- PR merging

## Phase Details

### CHECK_PENDING_PR

Scans for any open PRs from previous runs before starting new work:

```bash
gh pr list --state open --json headRefName,number \
  -q '.[] | select(.headRefName | test("^feature/epic-"))'
```

If found, resumes that PR instead of starting a new epic.

### FIND_EPIC

Parses epic files from `_bmad-output/`:

- `epics.md`, `@epics.md`, `epics-002.md`, etc.
- Extracts IDs from lines like `#### Epic 7A: Title`
- Filters by user-provided patterns (optional)
- Skips already-completed epics

### DEVELOP_STORIES

Invokes Claude Code with BMAD workflow:

```bash
claude -p "/bmad:bmm:workflows:dev-story develop epic stories ${EPIC_ID}.*"
```

Claude works autonomously to:
1. Create story files
2. Implement features
3. Write tests
4. Commit changes

### CODE_REVIEW

Two-step review process:

1. **BMAD Review**: `/bmad:bmm:workflows:code-review`
2. **Verification Loop**: Run local checks, fix issues, retry (max 3 attempts)

### WAIT_COPILOT

Monitors PR for Copilot activity:

```bash
gh pr view --json comments,reviews -q '
  [.comments[], .reviews[]] | 
  select(.author.login | test("copilot"; "i"))
'
```

Handles:
- Regular comments (`.comments[]`)
- Review comments (`.reviews[]`)
- Review states: `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`

### FIX_ISSUES

Collects all issues and sends to Claude:

- Copilot feedback from review
- CI failure details

Claude fixes issues and generates a structured reply table.

### MERGE_PR

Final merge with cleanup:

```bash
gh pr merge --squash --delete-branch
```

## Data Flow

```
┌─────────────────┐
│   epics.md      │ ──► parse_epics_from_bmad_output()
└─────────────────┘
         │
         ▼
┌─────────────────┐
│  State Machine  │ ◄──► .autopilot/state.json
└─────────────────┘
         │
         ▼
┌─────────────────┐
│  Claude Code    │ ──► AI Development + Review
└─────────────────┘
         │
         ▼
┌─────────────────┐
│  GitHub CLI     │ ──► PRs, Copilot, CI
└─────────────────┘
         │
         ▼
┌─────────────────┐
│  Merged to main │
└─────────────────┘
```

## Error Handling

### BLOCKED State

When the autopilot cannot proceed:
1. State is set to `BLOCKED`
2. Error details logged to `autopilot.log`
3. Script exits with code 1
4. User can fix manually and resume with `--continue`

### Retry Logic

- Code review: 3 attempts max
- CI check waiting: 60 iterations (30s each = 30 min)
- Copilot waiting: Infinite (Copilot always comments)

## Extensibility

### Custom Checks

Modify `autopilot_checks()` function to add project-specific checks:

```bash
autopilot_checks() {
  # Add your checks here
  npm run lint
  npm run test
  npm run build
}
```

### BMAD Workflows

The autopilot calls these BMAD workflows by default:
- `dev-story`
- `code-review`

You can customize these in your BMAD configuration.

## Security Considerations

1. **No Secrets in State**: State files don't contain sensitive data
2. **GitHub Auth**: Uses `gh` CLI's existing authentication
3. **Claude Permissions**: Uses `acceptEdits` mode for controlled changes
4. **Local Only**: `.autopilot/` should be gitignored

