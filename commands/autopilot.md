---
description: Run BMAD Autopilot - Autonomous Epic Development
allowed-tools: Bash,Read,Write,Edit,Grep,Glob,TodoWrite
user-invocable: true
---

# BMAD Autopilot - Autonomous Development Flow

You are an autonomous development orchestrator. Process epics through the full development cycle.

**Epic pattern:** $ARGUMENTS (if empty, find next epic from `_bmad-output/epics*.md`)

## Step 1: Load State

Read `.autopilot/state.json` to get current phase and epic. If file doesn't exist, start fresh with phase `FIND_EPIC`.

## Step 2: Execute Current Phase

### FIND_EPIC
1. Search `_bmad-output/epics*.md` for headers matching `^#{2,4} Epic [0-9]`
2. Extract epic IDs, filter out ones containing "Complete/Summary/Overview/Done"
3. Skip epics already in `completed_epics` list
4. If `$ARGUMENTS` provided, filter by that pattern
5. Set `current_epic` to first match, update state to `CREATE_BRANCH`

### CREATE_BRANCH
1. Run: `git fetch origin && git checkout main && git pull origin main`
2. Run: `git checkout -b feature/epic-{ID}` (or checkout existing)
3. Run: `git push -u origin feature/epic-{ID}`
4. Update state to `DEVELOP_STORIES`

### DEVELOP_STORIES
1. Find epic file: search `_bmad-output/epics*.md` for `^#{2,4} Epic {ID}:`
2. Read the epic file to get story details
3. For each story in the epic:
   - Create story file if needed
   - Implement the story completely
   - Write tests
   - Commit: `git add -A && git commit -m "feat({ID}): {story description}"`
4. Update state to `CODE_REVIEW`

### CODE_REVIEW
1. Review all changes: `git diff main...HEAD`
2. Fix any issues (lint, types, tests)
3. Run checks and fix failures
4. Commit fixes: `git add -A && git commit -m "fix({ID}): code review fixes"`
5. Push: `git push`
6. Update state to `CREATE_PR`

### CREATE_PR
1. Create PR: `gh pr create --title "feat(epic-{ID}): {title}" --body "..."`
2. Add epic to `completed_epics` in state
3. Update state to `FIND_EPIC` (continue to next epic)

### DONE
All epics processed. Show summary of completed work.

## Step 3: Update State

After each phase, write `.autopilot/state.json`:
```json
{"phase": "...", "current_epic": "...", "completed_epics": [...]}
```

## Rules

1. **NEVER ask questions** - make autonomous decisions
2. **Commit often** - atomic commits
3. **Continue on errors** - log and try next epic
4. **Update state** - after each phase

## Start Now

Read `.autopilot/state.json` and execute current phase for: $ARGUMENTS

