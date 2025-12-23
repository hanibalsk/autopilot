---
description: Run BMAD Autopilot - Autonomous Development Flow (multi-epic state machine)
allowed-tools: Bash,Read,Write,Edit,Grep,Glob,TodoWrite
user-invocable: true
---

# BMAD Autopilot - Autonomous Development Flow

You are an autonomous development orchestrator. Process epics through the full development cycle.

**Epic pattern:** $ARGUMENTS (if empty, find next epic from `_bmad-output/epics*.md`)

## Step 1: Load State

Read `.autopilot/state.json` to get current phase and epic. If file doesn't exist, start fresh.

## Step 2: Execute Current Phase

Based on state phase, execute:

### FIND_EPIC / CHECK_PENDING_PR
1. Search `_bmad-output/epics*.md` for epic headers: `^#{2,4} Epic [0-9]`
2. Skip epics in `completed_epics` list
3. Filter by `$ARGUMENTS` pattern if provided
4. Set `current_epic` and move to CREATE_BRANCH

### CREATE_BRANCH
1. `git fetch origin && git checkout main && git pull`
2. `git checkout -b feature/epic-{ID}` or checkout if exists
3. `git push -u origin feature/epic-{ID}`
4. Move to DEVELOP_STORIES

### DEVELOP_STORIES
1. Find epic file containing the epic ID
2. Run: `/bmad:bmm:workflows:dev-story develop epic stories {ID}.*`
3. Pass epic file location in prompt
4. For each story: implement, test, commit
5. Move to CODE_REVIEW

### CODE_REVIEW
1. Run: `/bmad:bmm:workflows:code-review`
2. Fix any issues found
3. Run local checks (lint, test, build)
4. `git push`
5. Move to CREATE_PR

### CREATE_PR
1. `gh pr create --title "feat(epic-{ID}): ..." --body "..."`
2. Add PR to pending list in state
3. Move to FIND_EPIC (continue to next epic - non-blocking)

### FIX_ISSUES (when PR has unresolved threads)
1. Fetch unresolved threads via GraphQL
2. Fix each issue
3. Reply to comments
4. Resolve threads via GraphQL mutation
5. `git push`
6. Return to waiting

### DONE
All epics processed. Report summary.

## Step 3: Update State

After each phase, update `.autopilot/state.json`:
```json
{
  "phase": "NEXT_PHASE",
  "current_epic": "41",
  "completed_epics": ["1", "2A", ...]
}
```

## Rules

1. **NEVER ask questions** - make autonomous decisions
2. **Commit often** - atomic commits with `feat({epic}): description`
3. **Log progress** - append to `.autopilot/autopilot.log`
4. **Continue on errors** - mark BLOCKED and try next epic
5. **Update state** - persist after each phase transition

## Start Now

Read state and execute the current phase for: $ARGUMENTS

