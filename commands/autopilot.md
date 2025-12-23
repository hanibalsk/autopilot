---
description: Run BMAD Autopilot orchestrator (alias)
allowed-tools: Bash
user-invocable: true
---

Run the BMAD Autopilot orchestrator.

If no epic pattern is provided, it will **auto-detect and process ALL epics** from `_bmad-output/` epics files in order:

- `epics.md`
- `@epics.md`
- `epics-002.md`, `epics-*.md`, etc.

Examples:
- `/autopilot` — process all epics automatically
- `/autopilot 7A 8A 10B` — specific epics only
- `/autopilot 10A-SSO` — epic with suffix
- `/autopilot 10A.*` — regex: matches 10A, 10A-SSO, etc.
- `/autopilot 7.* 10.*` — regex patterns (space-separated)

Then execute from the repo root:

```bash
./.autopilot/bmad-autopilot.sh $ARGUMENTS
```

To resume after an interruption:

```bash
./.autopilot/bmad-autopilot.sh --continue
# or with specific pattern:
./.autopilot/bmad-autopilot.sh "$ARGUMENTS" --continue
```

