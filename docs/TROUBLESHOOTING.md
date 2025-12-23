# Troubleshooting Guide

## Common Issues

### 1. "Required command not found"

**Error:**
```
❌ Required command not found: claude
```

**Solution:**
Install the missing command:

```bash
# jq
brew install jq

# gh (GitHub CLI)
brew install gh
gh auth login

# ripgrep
brew install ripgrep

# Claude Code CLI
# Follow: https://docs.anthropic.com/en/docs/claude-code
```

### 2. "Git working tree not clean"

**Error:**
```
❌ Git working tree not clean
```

**Solution:**
Commit or stash your changes:

```bash
git add -A && git commit -m "wip"
# or
git stash
```

### 3. Autopilot Gets Stuck Waiting for Copilot

**Symptoms:**
- Log shows: `… waiting for Copilot to review (50)`
- Copilot never comments

**Debug:**
Check what comments/reviews exist:

```bash
gh pr view --json comments,reviews | jq '.comments[].author.login, .reviews[].author.login'
```

**Possible causes:**
1. Copilot not enabled for the repository
2. Copilot's author login is different than expected

**Solution:**
Check the DEBUG logs in `.autopilot/autopilot.log` to see what authors are being detected.

### 4. Copilot Reviews But Autopilot Doesn't See It

**Symptoms:**
- Copilot has commented on the PR
- Autopilot keeps waiting

**Debug:**
```bash
# Check what the autopilot detected
cat .autopilot/tmp/copilot_latest.json | jq
```

**Solution:**
The script checks for author login containing "copilot" (case-insensitive). If Copilot uses a different username, update the jq filter in `phase_wait_copilot()`.

### 5. "No more epics - ALL DONE" Too Early

**Symptoms:**
- Autopilot completes but didn't process all epics
- Epics exist in epics.md

**Debug:**
```bash
# Check what epics are being parsed
cd /your/project
rg -N '^#### Epic ' _bmad-output/epics*.md
```

**Possible causes:**
1. Epic format doesn't match expected pattern
2. Epics already in `completed_epics` array

**Solution:**
```bash
# Reset state
rm .autopilot/state.json

# Run again
./.autopilot/bmad-autopilot.sh
```

### 6. State Corruption

**Symptoms:**
- Autopilot errors with JSON parsing issues
- Unexpected phase transitions

**Solution:**
```bash
# View current state
cat .autopilot/state.json

# Reset if corrupted
rm .autopilot/state.json

# Start fresh
./.autopilot/bmad-autopilot.sh
```

### 7. Multiple Open PRs Accumulated

**Symptoms:**
- Multiple `feature/epic-*` PRs are open
- Autopilot was interrupted multiple times

**Solution:**
The autopilot now handles this automatically - it will process open PRs before starting new epics. Run:

```bash
./.autopilot/bmad-autopilot.sh
```

It will resume the first open epic PR it finds.

### 8. CI Checks Never Pass

**Symptoms:**
- Stuck in WAIT_CHECKS phase
- CI keeps failing

**Debug:**
```bash
# Check CI status
gh pr checks

# View failed checks
cat .autopilot/tmp/failed-checks.json | jq
```

**Solution:**
1. Fix CI issues manually
2. Push the fix
3. Resume: `./.autopilot/bmad-autopilot.sh --continue`

### 9. Claude Runs Out of Turns

**Symptoms:**
- Phase completes but work is incomplete
- Log shows max-turns reached

**Solution:**
Increase MAX_TURNS:

```bash
MAX_TURNS=150 ./.autopilot/bmad-autopilot.sh --continue
```

### 10. Permission Denied on Script

**Error:**
```
-bash: ./.autopilot/bmad-autopilot.sh: Permission denied
```

**Solution:**
```bash
chmod +x ./.autopilot/bmad-autopilot.sh
```

## Debugging Tips

### Enable Verbose Logging

The script already logs to `.autopilot/autopilot.log`. For real-time viewing:

```bash
# In one terminal
./.autopilot/bmad-autopilot.sh

# In another terminal
tail -f .autopilot/autopilot.log
```

### Check Temporary Files

```bash
ls -la .autopilot/tmp/

# View Copilot detection
cat .autopilot/tmp/copilot_latest.json | jq

# View Claude output
cat .autopilot/tmp/claude-output.txt | head -100
```

### Manual State Transitions

For testing, you can manually set the state:

```bash
# Skip to a specific phase
echo '{"phase":"CREATE_PR","current_epic":"7A","completed_epics":[]}' > .autopilot/state.json
./.autopilot/bmad-autopilot.sh --continue
```

### Run Individual Phases

You can source the script and run functions manually:

```bash
source ./.autopilot/bmad-autopilot.sh

# Initialize
require_tooling
state_init_if_missing

# Run specific phase
phase_find_epic
```

## Getting Help

1. Check the logs: `.autopilot/autopilot.log`
2. Check temporary files: `.autopilot/tmp/`
3. Check state: `.autopilot/state.json`
4. Open an issue: https://github.com/hanibalsk/autopilot/issues

