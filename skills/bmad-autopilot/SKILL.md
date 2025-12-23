---
name: bmad-autopilot
description: Autonomous development orchestrator for processing epics. Use when the user wants to run the autopilot, process epics, or automate the development workflow with BMAD method.
allowed-tools: Bash, Read
---

# BMAD Autopilot - Autonomous Development Orchestrator

This skill runs the BMAD Autopilot bash orchestrator to automatically process epics through the full development cycle.

## When to Use

Activate this skill when the user:
- Wants to run the autopilot or orchestrator
- Asks to process epics automatically
- Mentions BMAD development workflow
- Wants to automate PR creation and review cycles

## Execution

Run the orchestrator from the repository root:

```bash
# Process ALL epics automatically
./.autopilot/bmad-autopilot.sh

# Process specific epics
./.autopilot/bmad-autopilot.sh "7A 8A"

# With verbose output
./.autopilot/bmad-autopilot.sh --verbose

# Resume after interruption
./.autopilot/bmad-autopilot.sh --continue
```

## Workflow States

The orchestrator runs through these phases:
1. CHECK_PENDING_PR - Find unfinished PRs
2. FIND_EPIC - Select next epic to process
3. CREATE_BRANCH - Create feature branch
4. DEVELOP_STORIES - Claude develops the epic
5. CODE_REVIEW - Run local checks and review
6. CREATE_PR - Create pull request
7. WAIT_COPILOT - Wait for Copilot review
8. WAIT_CHECKS - Wait for CI to pass
9. MERGE_PR - Merge when approved
10. Loop to next epic or DONE

## Logs and State

- Log: `.autopilot/autopilot.log`
- State: `.autopilot/state.json`
- Debug: `.autopilot/tmp/debug.log` (when --debug)

## Prerequisites

The script requires: `claude`, `gh`, `jq`, `rg`, `git`
