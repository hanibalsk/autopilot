---
description: Run BMAD Autopilot - Autonomous Development Flow (multi-epic state machine)
allowed-tools: Bash,Read,Write,Edit,Grep
---

# BMAD Autopilot - Autonomous Development Flow

Run fully autonomous BMAD development cycle.

**Epic selection:**
- If `$ARGUMENTS` is provided: process only matching epics (e.g., `7A 8A`, `10A-SSO`, `10A.*`)
- If no arguments: **auto-detect and process ALL epics** from `_bmad-output/` epics files in order (`epics*.md` and `@epics.md`)

**Supported epic ID formats:** `1`, `7A`, `10B`, `10A-SSO`, etc.

## Your Role

You are an autonomous development orchestrator. Your goal is to completely process all epics in the sprint without human intervention, until everything is DONE or BLOCKED.

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

**Key flow points:**
- Before starting a new epic, CHECK_PENDING_PR looks for unfinished PRs
- WAIT_COPILOT waits for Copilot to comment (it always does when finished)
- WAIT_CHECKS waits for CI to pass
- FIX_ISSUES fixes both Copilot comments AND CI failures, then loops back
- MERGE_PR only happens when both Copilot approved and CI passed

## Execution

Run this workflow for sprint/epics: $ARGUMENTS

**Use the bash orchestrator directly:**

```bash
# Auto-detect all epics:
./.autopilot/bmad-autopilot.sh

# Specific epics only:
./.autopilot/bmad-autopilot.sh "7A 8A 10B"

# Epic with suffix:
./.autopilot/bmad-autopilot.sh "10A-SSO"

# Regex patterns (matches 10A, 10A-SSO, etc.):
./.autopilot/bmad-autopilot.sh "10A.*"

# Multiple regex patterns:
./.autopilot/bmad-autopilot.sh "7.* 10.*"
```

To resume after interruption:

```bash
./.autopilot/bmad-autopilot.sh --continue
# or with specific pattern:
./.autopilot/bmad-autopilot.sh "7A" --continue
```

## Rules for Autonomous Mode

1. **NEVER ask questions** - make decisions yourself
2. **Commit often** - small atomic commits
3. **Log everything** - append to `.autopilot/autopilot.log`
4. **Fail gracefully** - if something fails, log it and continue with next epic
5. **State persistence** - always update state file after each phase

## Error Handling

If BLOCKED state occurs:
1. Log to `.autopilot/autopilot.log`
2. Create GitHub issue with details
3. Continue with next epic if possible
4. Report all BLOCKED items at the end

