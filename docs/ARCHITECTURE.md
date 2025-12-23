# BMAD Autopilot Architecture

## Overview

BMAD Autopilot is a state-machine-driven bash orchestrator that automates the entire development lifecycle from epic discovery to PR merge.

## Core Components

### 1. State Machine

The autopilot operates as a finite state machine with the following states:

#### Non-Blocking Flow (all modes)
```
┌─────────────────────────────────────────────────────────────────────────┐
│  ACTIVE DEVELOPMENT                    BACKGROUND (auto-approve)        │
│  ┌───────────────────┐                 ┌─────────────────────┐         │
│  │ FIND_EPIC         │                 │ auto-approve.yml    │         │
│  │ CREATE_BRANCH     │                 │ - wait 10min        │         │
│  │ DEVELOP_STORIES   │ (interactive)   │ - check CI passed   │         │
│  │ CODE_REVIEW       │ (interactive)   │ - check threads=0   │         │
│  │ CREATE_PR ────────┼──add to queue──►│ - approve PR        │         │
│  │      │            │                 └─────────────────────┘         │
│  │      ▼            │                                                  │
│  │ WAIT_COPILOT      │                 ┌─────────────────────┐         │
│  │      │            │                 │ Pending PRs         │         │
│  │ if no issues:     │                 │ - checked every 60s │◄─check──┤
│  │      ▼            │                 │ - auto-merged       │         │
│  │ FIND_EPIC (next)  │                 │ - or fix issues     │         │
│  └───────────────────┘                 └─────────────────────┘         │
│                                                                         │
│  if unresolved threads:                                                 │
│  → FIX_ISSUES (fetch threads, fix, reply, resolve)                     │
│  → WAIT_COPILOT (re-review)                                            │
└─────────────────────────────────────────────────────────────────────────┘
```

**Key principle:** Never block waiting for approval. Continue to next epic immediately.

- `PARALLEL_MODE=0`: One branch at a time (simple)
- `PARALLEL_MODE=1+`: Uses git worktrees for parallel branch management

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

Monitors PR for Copilot activity. Copilot review is typically triggered automatically via branch protection on every push.

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
- Timeout after `MAX_COPILOT_WAIT` iterations (default: 60)

### FIX_ISSUES

Comprehensive issue resolution with thread management:

1. **Fetch unresolved threads** via GraphQL:
   ```bash
   gh api graphql -f query='...' --jq '.reviewThreads.nodes[]'
   ```
   Gets file path, line number, and comment content.

2. **Send to Claude** with full context:
   - Unresolved thread content (file:line + comment)
   - Copilot review body
   - CI failure details

3. **Claude fixes issues** and commits

4. **Post reply** to PR acknowledging feedback

5. **Resolve all threads** via GraphQL mutation:
   ```bash
   gh api graphql -f query='mutation { resolveReviewThread(...) }'
   ```

6. **Return to WAIT_COPILOT** for re-review

**Critical:** Always reply AND resolve threads - both are required for auto-approve.

### Auto-Approve Workflow

The `auto-approve.yml` GitHub Actions workflow handles PR approval:

**Trigger:** Copilot submits a review (`pull_request_review: submitted`)

**Approval conditions (ALL must be met):**
1. At least 10 minutes since last push
2. Copilot review exists
3. All review threads resolved (0 unresolved)
4. All CI checks passed

**Flow:**
1. Wait 2 min for CI to start
2. Poll CI every 30s until complete
3. Check time since last push (≥10 min)
4. Check Copilot has reviewed
5. Check 0 unresolved threads via GraphQL
6. **Dismiss stale approvals** if unresolved threads exist
7. Approve if all conditions met

**Stale approval dismissal:** If conditions aren't met but a previous approval exists, it's dismissed to prevent merging with unresolved issues.

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
- CI check waiting: `MAX_CHECK_WAIT` iterations (default: 60)
- Copilot waiting: `MAX_COPILOT_WAIT` iterations (default: 60)

### Dirty Working Tree Check

At startup, the script checks for uncommitted changes. If found, it warns the user and requires confirmation before proceeding, preventing accidental loss of work during branch switches.

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
5. **Safe Config Parsing**: Config file uses whitelisted keys only, preventing arbitrary code execution
6. **Base Branch Detection**: Auto-detects main/master/custom branch names

