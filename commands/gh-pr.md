---
description: GitHub CLI and PR handling reference
allowed-tools: Bash, Read
---

# GitHub CLI & PR Handling

Quick reference for `gh` commands and PR operations.

## Common Operations

**PR Info:**
```bash
gh pr view                                    # View current PR
gh pr view --json number,state -q '.state'    # Get PR state
gh pr list --state open                       # List open PRs
```

**CI Checks:**
```bash
gh pr checks                                  # View all checks
gh pr checks --watch                          # Wait for completion
```

**Copilot Review:**
```bash
gh pr view --json reviews -q '[.reviews[] | select(.author.login | test("copilot"; "i"))] | sort_by(.submittedAt) | .[-1].state'
```

**Merge:**
```bash
gh pr merge --squash --delete-branch          # Squash merge
gh pr merge --auto --squash                   # Auto-merge when ready
```

## What do you need help with?

$ARGUMENTS
