#!/usr/bin/env bash
#
# BMAD Autopilot - Autonomous Development Orchestrator (Claude Code)
#
# Usage:
#   ./bmad-autopilot.sh                           # auto-detect: process ALL epics from epics.md
#   ./bmad-autopilot.sh "7A 8A 10B"               # specific epics only
#   ./bmad-autopilot.sh "10A-SSO"                 # epic with suffix
#   ./bmad-autopilot.sh "10A.*"                   # regex: matches 10A, 10A-SSO, etc.
#   ./bmad-autopilot.sh "7.* 10.*"                # regex patterns (space-separated)
#   ./bmad-autopilot.sh --continue                # resume previous run (all epics)
#   ./bmad-autopilot.sh "7A" --continue           # resume with specific pattern
#   ./bmad-autopilot.sh --debug                   # enable debug logging to .autopilot/tmp/debug.log
#   AUTOPILOT_DEBUG=1 ./bmad-autopilot.sh        # alternative: enable debug via env var
#
# Branch Protection Requirements:
#   - Copilot review triggers automatically on every push
#   - Requires Copilot APPROVED before merge
#   - Stale approvals are dismissed on new commits
#   - Script waits for both CI checks AND Copilot approval
#
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

# --- minimal shared helpers (embedded to avoid external dependency) ---
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ Required command not found: $cmd" >&2
    exit 1
  fi
}

require_clean_git() {
  if [ -n "$(git status --porcelain)" ]; then
    echo "❌ Git working tree not clean" >&2
    exit 1
  fi
}

autopilot_checks() {
  # Backend (Rust)
  if [ -f "$ROOT_DIR/backend/Cargo.toml" ]; then
    (cd "$ROOT_DIR/backend" && cargo fmt --check)
    (cd "$ROOT_DIR/backend" && cargo clippy --workspace --all-targets -- -D warnings)
    (cd "$ROOT_DIR/backend" && cargo test --workspace)
  fi

  # Frontend (pnpm + biome)
  if [ -f "$ROOT_DIR/frontend/package.json" ]; then
    require_cmd pnpm
    (cd "$ROOT_DIR/frontend" && pnpm run check)
    # Run typecheck only if script exists in package.json
    if (cd "$ROOT_DIR/frontend" && pnpm run typecheck --help >/dev/null 2>&1); then
      (cd "$ROOT_DIR/frontend" && pnpm run typecheck) || true
    fi
    # Run tests only if script exists
    if (cd "$ROOT_DIR/frontend" && pnpm run test --help >/dev/null 2>&1); then
      (cd "$ROOT_DIR/frontend" && pnpm -r run test) || true
    fi
  fi

  # Mobile native (Gradle) - OFF by default (often needs Android toolchain)
  if [ "${AUTOPILOT_RUN_MOBILE_NATIVE:-0}" = "1" ] && [ -f "$ROOT_DIR/mobile-native/gradlew" ]; then
    (cd "$ROOT_DIR/mobile-native" && ./gradlew build)
  fi
}

# Config - parse arguments (handle --continue and --debug as first or second arg)
EPIC_PATTERN=""
CONTINUE_FLAG=""
DEBUG_MODE="${AUTOPILOT_DEBUG:-0}"
for arg in "$@"; do
  if [ "$arg" = "--continue" ]; then
    CONTINUE_FLAG="--continue"
  elif [ "$arg" = "--debug" ]; then
    DEBUG_MODE="1"
  elif [ -z "$EPIC_PATTERN" ]; then
    EPIC_PATTERN="$arg"
  fi
done
AUTOPILOT_DIR="$ROOT_DIR/.autopilot"
STATE_FILE="$AUTOPILOT_DIR/state.json"
LOG_FILE="$AUTOPILOT_DIR/autopilot.log"
TMP_DIR="$AUTOPILOT_DIR/tmp"
DEBUG_LOG="$TMP_DIR/debug.log"

MAX_TURNS="${MAX_TURNS:-80}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}" # seconds
MAX_CHECK_WAIT="${MAX_CHECK_WAIT:-60}" # iterations

mkdir -p "$AUTOPILOT_DIR" "$TMP_DIR"

# Initialize debug log if debug mode is enabled
if [ "$DEBUG_MODE" = "1" ]; then
  echo "=== Debug session started: $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$DEBUG_LOG"
fi

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" | tee -a "$LOG_FILE"
}

debug() {
  if [ "$DEBUG_MODE" = "1" ]; then
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $1"
    echo "$msg" >> "$DEBUG_LOG"
  fi
}

require_tooling() {
  require_cmd jq
  require_cmd git
  require_cmd gh
  require_cmd claude
  require_cmd rg
}

state_init_if_missing() {
  if [ ! -f "$STATE_FILE" ]; then
    echo '{"phase":"FIND_EPIC","current_epic":null,"completed_epics":[]}' >"$STATE_FILE"
  fi
}

state_get() {
  state_init_if_missing
  cat "$STATE_FILE"
}

state_phase() {
  state_init_if_missing
  jq -r '.phase' "$STATE_FILE"
}

state_current_epic() {
  state_init_if_missing
  jq -r '.current_epic' "$STATE_FILE"
}

state_completed_csv() {
  state_init_if_missing
  jq -r '.completed_epics | join(",")' "$STATE_FILE"
}

state_set() {
  local phase="$1"
  local epic_json="${2:-null}" # JSON string or null
  state_init_if_missing
  local completed
  completed="$(jq '.completed_epics' "$STATE_FILE" 2>/dev/null || echo '[]')"
  jq -n --arg phase "$phase" --argjson current_epic "$epic_json" --argjson completed_epics "$completed" \
    '{phase:$phase,current_epic:$current_epic,completed_epics:$completed_epics}' >"$STATE_FILE"
}

state_mark_completed() {
  local epic="$1"
  state_init_if_missing
  jq --arg epic "$epic" '.completed_epics += [$epic] | .completed_epics |= unique' "$STATE_FILE" >"$STATE_FILE.tmp" \
    && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

parse_epics_from_bmad_output() {
  # Extract epic IDs from epics files in _bmad-output/, supporting:
  # - epics.md
  # - @epics.md
  # - epics-002.md, epics-*.md, etc.
  #
  # Lines look like:
  #   "#### Epic 7A: ..." => 7A
  #   "#### Epic 10A-SSO: ..." => 10A-SSO
  local bmad_out_dir="$ROOT_DIR/_bmad-output"
  if [ ! -d "$bmad_out_dir" ]; then
    return 0
  fi

  local files=()
  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(find "$bmad_out_dir" -maxdepth 1 -type f \( -iname 'epics*.md' -o -iname '@epics.md' \) | LC_ALL=C sort)

  if [ "${#files[@]}" -eq 0 ]; then
    return 0
  fi

  local f
  for f in "${files[@]}"; do
    rg -N --no-filename '^#### Epic ' "$f" || true
  done \
    | sed -E 's/^#### Epic ([^:]+):.*/\1/' \
    | tr -d '\r' \
    | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

epic_matches_patterns() {
  local epic="$1"
  # No pattern -> match everything
  if [ -z "$EPIC_PATTERN" ]; then
    return 0
  fi
  # EPIC_PATTERN is space-separated regex patterns
  local pat
  for pat in $EPIC_PATTERN; do
    if echo "$epic" | rg -iq -- "$pat"; then
      return 0
    fi
  done
  return 1
}

find_next_epic() {
  state_init_if_missing
  local completed_csv
  completed_csv="$(state_completed_csv)"

  while IFS= read -r epic; do
    [ -z "$epic" ] && continue
    epic_matches_patterns "$epic" || continue
    if [ -n "$completed_csv" ] && echo ",$completed_csv," | grep -q ",$epic,"; then
      continue
    fi
    echo "$epic"
    return 0
  done < <(parse_epics_from_bmad_output)

  return 1
}

# Run Claude headless and capture output to a file
# Usage: run_claude_headless "prompt" [max_turns] [allowed_tools] [output_file]
run_claude_headless() {
  local prompt="$1"
  local max_turns="${2:-$MAX_TURNS}"
  local allowed_tools="${3:-Bash,Read,Write,Edit,Grep}"
  local output_file="${4:-$TMP_DIR/claude-output.txt}"

  log "🤖 Claude headless (max_turns=$max_turns)"
  claude -p "$prompt" \
    --permission-mode acceptEdits \
    --allowedTools "$allowed_tools" \
    --max-turns "$max_turns" \
    2>&1 | tee "$output_file"
}

# ============================================
# PHASE: CHECK_PENDING_PR
# ============================================
phase_check_pending_pr() {
  log "🔍 PHASE: CHECK_PENDING_PR"

  # 1) Count and list all open epic PRs - we must finish them before starting new epics
  local open_epic_branches
  open_epic_branches="$(
    gh pr list --state open --json headRefName,number \
      -q '.[] | select(.headRefName | test("^feature/epic-")) | "\(.number):\(.headRefName)"'
  )"

  local open_count
  open_count="$(echo "$open_epic_branches" | grep -c . || echo 0)"

  if [ "$open_count" -gt 0 ]; then
    log "📋 Found $open_count open epic PR(s):"
    echo "$open_epic_branches" | while read -r pr_info; do
      log "   - PR #${pr_info%%:*} → ${pr_info#*:}"
    done

    # Pick the first one to handle
    local first_pr_info
    first_pr_info="$(echo "$open_epic_branches" | head -n 1)"
    local pr_number="${first_pr_info%%:*}"
    local open_epic_branch="${first_pr_info#*:}"

    log "⚠️ Resuming first open PR #$pr_number ($open_epic_branch)"

    # Clean up any stale comment tracking from previous PR
    rm -f "$TMP_DIR/last_copilot_comment_id.txt" "$TMP_DIR/copilot.txt" "$TMP_DIR/copilot_latest.json" 2>/dev/null || true

    git fetch origin "$open_epic_branch" 2>/dev/null || true
    git checkout "$open_epic_branch" 2>/dev/null || git checkout -b "$open_epic_branch" "origin/$open_epic_branch"

    local epic_id="${open_epic_branch#feature/epic-}"
    state_set "WAIT_COPILOT" "\"$epic_id\""
    return 0
  fi

  # 2) Check if our current branch is an epic branch and needs finishing.
  local current_branch
  current_branch="$(git branch --show-current)"

  if [[ "$current_branch" == feature/epic-* ]]; then
    # Extract epic ID from branch name
    local epic_id="${current_branch#feature/epic-}"
    log "Found feature branch: $current_branch (epic: $epic_id)"

    # Check if there's an open PR for this branch
    if gh pr view >/dev/null 2>&1; then
      local pr_number
      pr_number="$(gh pr view --json number -q '.number')"
      log "⚠️ Found open PR #$pr_number for epic $epic_id - resuming PR flow"

      # Clean up stale comment tracking
      rm -f "$TMP_DIR/last_copilot_comment_id.txt" 2>/dev/null || true

      state_set "WAIT_COPILOT" "\"$epic_id\""
      return 0
    else
      log "Branch exists but no PR - checking if we need to create one"
      # Check if there are unpushed commits
      git fetch origin "$current_branch" 2>/dev/null || true
      if [ -n "$(git log "origin/$current_branch..HEAD" 2>/dev/null)" ] || [ -n "$(git diff origin/main..HEAD --name-only 2>/dev/null)" ]; then
        log "Found unpushed changes - resuming from CODE_REVIEW"
        state_set "CODE_REVIEW" "\"$epic_id\""
        return 0
      fi
    fi
  fi

  log "✅ No pending PRs found - proceeding to find next epic"
  state_set "FIND_EPIC" "null"
  return 0
}

# ============================================
# PHASE: FIND_EPIC
# ============================================
phase_find_epic() {
  log "📋 PHASE: FIND_EPIC"

  if next="$(find_next_epic)"; then
    log "✅ Found epic: $next"
    state_set "CREATE_BRANCH" "\"$next\""
    return 0
  fi

  log "🎉 No more epics - ALL DONE!"
  state_set "DONE" "null"
  return 1
}

# ============================================
# PHASE: CREATE_BRANCH
# ============================================
phase_create_branch() {
  log "🌿 PHASE: CREATE_BRANCH"

  local epic_id
  epic_id="$(state_current_epic)"
  if [ "$epic_id" = "null" ] || [ -z "$epic_id" ]; then
    log "❌ current_epic missing"
    state_set "BLOCKED" "null"
    return 1
  fi

  local branch_name="feature/epic-${epic_id}"
  log "Creating branch: $branch_name"

  git fetch origin
  git checkout main
  git pull origin main
  git checkout -b "$branch_name" 2>/dev/null || git checkout "$branch_name"
  git push -u origin "$branch_name" 2>/dev/null || true

  state_set "DEVELOP_STORIES" "\"$epic_id\""
  log "✅ Branch ready: $branch_name"
}

# ============================================
# PHASE: DEVELOP_STORIES
# ============================================
phase_develop_stories() {
  log "💻 PHASE: DEVELOP_STORIES"

  local epic_id
  epic_id="$(state_current_epic)"

  require_clean_git

  local output_file="$TMP_DIR/develop-stories-output.txt"

  run_claude_headless "
/bmad:bmm:workflows:dev-story develop epic stories ${epic_id}.*

## YOLO MODE ENABLED
For each story in epic ${epic_id}:
1. Create storyfile if it doesn't exist
2. Implement the story completely
3. Write unit tests
4. Commit after each story: git add -A && git commit -m \"feat(${epic_id}): [story description]\"

Work autonomously without asking questions. Make your own decisions.

When you complete ALL stories, respond exactly:
STATUS: STORIES_COMPLETE

If you encounter a blocker you cannot resolve:
STATUS: STORIES_BLOCKED - [reason]
" 50 "Bash,Read,Write,Edit,Grep" "$output_file"

  # Check Claude output for BLOCKED status
  if grep -qi "STATUS: STORIES_BLOCKED" "$output_file" 2>/dev/null; then
    log "❌ Claude reported stories blocked"
    state_set "BLOCKED" "\"$epic_id\""
    return 1
  fi

  log "Running local checks gate..."
  if ! autopilot_checks; then
    log "⚠️ Local checks failed after story development, moving to CODE_REVIEW for fixes"
  fi

  state_set "CODE_REVIEW" "\"$epic_id\""
  log "✅ Stories phase complete"
}

# ============================================
# PHASE: CODE_REVIEW
# ============================================
phase_code_review() {
  log "🔍 PHASE: CODE_REVIEW"

  local epic_id
  epic_id="$(state_current_epic)"

  # First: Run BMAD code-review workflow
  log "Running BMAD code-review workflow for epic $epic_id"
  run_claude_headless "
/bmad:bmm:workflows:code-review ${epic_id}-*

Review all code changes for epic ${epic_id}.
Fix any issues found during the review.
Commit fixes: git add -A && git commit -m 'fix: address code review feedback'

At the end, output exactly:
STATUS: CODE_REVIEW_DONE
" 30 "Bash,Read,Write,Edit,Grep"

  # Then: Verify checks pass with retry loop
  local attempts=0
  local max_attempts=3

  while [ "$attempts" -lt "$max_attempts" ]; do
    attempts=$((attempts + 1))
    log "Verification attempt $attempts/$max_attempts"

    run_claude_headless "
Verify all code review issues are resolved. Check and fix any remaining problems.

Steps:
1. Review diff: git diff main...HEAD
2. Fix issues you find (readability, architecture, tests, lint)
3. If you change code, commit: git add -A && git commit -m \"fix: review cleanup\"

At the end, output exactly:
STATUS: REVIEW_DONE
" 20 "Bash,Read,Write,Edit,Grep"

    if autopilot_checks; then
      git push 2>/dev/null || true
      state_set "CREATE_PR" "\"$epic_id\""
      log "✅ Code review passed"
      return 0
    fi

    log "⚠️ Checks still failing after review attempt, retrying..."
  done

  log "❌ Code review failed after $max_attempts attempts"
  state_set "BLOCKED" "\"$epic_id\""
  return 1
}

# ============================================
# PHASE: CREATE_PR
# ============================================
phase_create_pr() {
  log "📝 PHASE: CREATE_PR"

  local epic_id
  epic_id="$(state_current_epic)"

  if ! gh pr view >/dev/null 2>&1; then
    gh pr create --fill --label "epic,automated,epic-$epic_id" || gh pr create --fill
  fi

  # Note: Copilot review triggers automatically on push (branch protection)
  # No need to manually request @copilot review

  state_set "WAIT_COPILOT" "\"$epic_id\""
  log "✅ PR created, Copilot review will trigger automatically on push"
}

# ============================================
# PHASE: WAIT_COPILOT
# ============================================
phase_wait_copilot() {
  log "🤖 PHASE: WAIT_COPILOT"

  local epic_id
  epic_id="$(state_current_epic)"

  local pr_number
  pr_number="$(gh pr view --json number -q '.number')"
  log "Waiting for GitHub Copilot review on PR #$pr_number"

  # Get the last processed Copilot comment/review ID to avoid reacting to old ones
  local last_processed_id=""
  if [ -f "$TMP_DIR/last_copilot_comment_id.txt" ]; then
    last_processed_id="$(cat "$TMP_DIR/last_copilot_comment_id.txt")"
    log "Last processed Copilot ID: $last_processed_id"
  fi

  local i=0
  while true; do
    i=$((i + 1))

    # Copilot can post as:
    # - Regular comments (.comments[]) with author.login containing "copilot"
    # - Reviews (.reviews[]) with author.login containing "copilot"
    # The actual login is usually "copilot[bot]" or similar
    #
    # First, dump ALL comments and reviews for debugging (only on first iteration)
    if [ "$i" -eq 1 ]; then
      debug "Fetching all comments/reviews authors..."
      gh pr view --json comments,reviews -q '
        "Comments: " + ([.comments[].author.login] | join(", ")) + " | Reviews: " + ([.reviews[] | .author.login + "(" + .state + ")"] | join(", "))
      ' 2>/dev/null | while read -r line; do debug "$line"; done || true
    fi

    # We check BOTH and take the most recent one
    gh pr view --json comments,reviews -q '
      (
        [.comments[] | select(.author.login | test("copilot"; "i")) | {id: .id, body: .body, createdAt: .createdAt, type: "comment", author: .author.login}] +
        [.reviews[] | select(.author.login | test("copilot"; "i")) | {id: .id, body: .body, createdAt: .createdAt, type: "review", state: .state, author: .author.login}]
      ) | sort_by(.createdAt) | .[-1] // {}
    ' >"$TMP_DIR/copilot_latest.json" 2>/dev/null || echo "{}" >"$TMP_DIR/copilot_latest.json"

    # Debug: show what we found
    if [ "$i" -eq 1 ] || [ "$((i % 10))" -eq 0 ]; then
      debug "copilot_latest.json = $(cat "$TMP_DIR/copilot_latest.json" | head -c 500)"
    fi

    local latest_id
    latest_id="$(jq -r '.id // empty' "$TMP_DIR/copilot_latest.json" 2>/dev/null || echo "")"

    local latest_type
    latest_type="$(jq -r '.type // empty' "$TMP_DIR/copilot_latest.json" 2>/dev/null || echo "")"

    local latest_author
    latest_author="$(jq -r '.author // empty' "$TMP_DIR/copilot_latest.json" 2>/dev/null || echo "")"

    # Skip if no comment/review found
    if [ -z "$latest_id" ]; then
      log "… waiting for Copilot to review ($i)"
      sleep "$CHECK_INTERVAL"
      continue
    fi

    # Skip if same as already processed
    if [ "$latest_id" = "$last_processed_id" ]; then
      log "… waiting for NEW Copilot activity (already processed $latest_id) ($i)"
      sleep "$CHECK_INTERVAL"
      continue
    fi

    # New comment/review found!
    log "✅ Copilot ($latest_author) has posted a new $latest_type (ID: $latest_id)"

    # Extract body for analysis
    jq -r '.body // ""' "$TMP_DIR/copilot_latest.json" >"$TMP_DIR/copilot.txt"

    # For reviews, also check the state (APPROVED, CHANGES_REQUESTED, COMMENTED)
    local review_state
    review_state="$(jq -r '.state // empty' "$TMP_DIR/copilot_latest.json" 2>/dev/null || echo "")"

    # Save this ID as processed
    echo "$latest_id" >"$TMP_DIR/last_copilot_comment_id.txt"

    # Check if Copilot approved or found issues
    if [ "$review_state" = "APPROVED" ]; then
      log "✅ Copilot APPROVED the PR"
      state_set "WAIT_CHECKS" "\"$epic_id\""
      return 0
    elif [ "$review_state" = "CHANGES_REQUESTED" ]; then
      log "⚠️ Copilot REQUESTED CHANGES"
      state_set "FIX_ISSUES" "\"$epic_id\""
      return 0
    fi

    # For comments or COMMENTED reviews, check content for actionable items
    if grep -qiE "suggest|issue|fix|problem|consider|warning|error|should|could|recommend|nit|improvement|change|update|missing|add|remove" "$TMP_DIR/copilot.txt"; then
      log "⚠️ Copilot review has actionable suggestions - need to fix"
      state_set "FIX_ISSUES" "\"$epic_id\""
      return 0
    else
      log "✅ Copilot review has no actionable issues"
      state_set "WAIT_CHECKS" "\"$epic_id\""
      return 0
    fi
  done
}

# ============================================
# PHASE: WAIT_CHECKS
# ============================================
phase_wait_checks() {
  log "⏳ PHASE: WAIT_CHECKS"

  local epic_id
  epic_id="$(state_current_epic)"

  local pr_number
  pr_number="$(gh pr view --json number -q '.number')"
  log "Waiting for CI checks and Copilot approval on PR #$pr_number"

  for i in $(seq 1 "$MAX_CHECK_WAIT"); do
    # Check CI status
    local check_conclusions
    check_conclusions="$(gh pr checks --json conclusion -q '.[].conclusion' 2>/dev/null || echo "")"

    # Failures? (case-insensitive)
    if echo "$check_conclusions" | grep -iq "failure"; then
      log "❌ CI checks failed"
      gh pr checks --json name,conclusion,detailsUrl >"$TMP_DIR/failed-checks.json" || true
      state_set "FIX_ISSUES" "\"$epic_id\""
      return 0
    fi

    # Check if CI is still pending
    local ci_pending=false
    if echo "$check_conclusions" | grep -iq "pending"; then
      ci_pending=true
    fi

    # Check Copilot approval status (required by branch protection)
    local copilot_approved=false
    local copilot_state
    copilot_state="$(gh pr view --json reviews -q '
      [.reviews[] | select(.author.login | test("copilot"; "i"))] | sort_by(.submittedAt) | .[-1].state // ""
    ' 2>/dev/null || echo "")"

    if [ "$copilot_state" = "APPROVED" ]; then
      copilot_approved=true
    elif [ "$copilot_state" = "CHANGES_REQUESTED" ]; then
      log "⚠️ Copilot requested changes during WAIT_CHECKS"
      state_set "FIX_ISSUES" "\"$epic_id\""
      return 0
    fi

    # Both CI and Copilot must pass
    if [ "$ci_pending" = true ]; then
      log "… CI checks pending ($i/$MAX_CHECK_WAIT)"
      sleep "$CHECK_INTERVAL"
      continue
    fi

    if [ "$copilot_approved" = false ]; then
      log "… Waiting for Copilot approval ($i/$MAX_CHECK_WAIT) [current: $copilot_state]"
      sleep "$CHECK_INTERVAL"
      continue
    fi

    # All checks passed AND Copilot approved
    log "✅ All CI checks passed AND Copilot approved"
    state_set "MERGE_PR" "\"$epic_id\""
    return 0
  done

  log "⚠️ Timeout waiting for checks/approval"
  state_set "BLOCKED" "\"$epic_id\""
}

# ============================================
# PHASE: FIX_ISSUES
# ============================================
phase_fix_issues() {
  log "🔧 PHASE: FIX_ISSUES"

  local epic_id
  epic_id="$(state_current_epic)"

  local pr_number
  pr_number="$(gh pr view --json number -q '.number')"

  # Build issues string with proper newlines
  local issues=""
  local has_copilot_issues=false
  local copilot_feedback=""
  if [ -f "$TMP_DIR/copilot.txt" ] && [ -s "$TMP_DIR/copilot.txt" ]; then
    copilot_feedback="$(cat "$TMP_DIR/copilot.txt")"
    issues=$(printf "%s\n\nCOPILOT REVIEW:\n%s" "$issues" "$copilot_feedback")
    has_copilot_issues=true
  fi
  if [ -f "$TMP_DIR/failed-checks.json" ] && [ -s "$TMP_DIR/failed-checks.json" ]; then
    issues=$(printf "%s\n\nCI FAILURES:\n%s" "$issues" "$(cat "$TMP_DIR/failed-checks.json")")
  fi

  local output_file="$TMP_DIR/fix-issues-output.txt"

  run_claude_headless "
Fix ONLY issues from CI failures and/or Copilot review feedback.

Issues:
$issues

Rules:
- Do not introduce new features
- Keep changes minimal
- Fix each issue mentioned by Copilot
- After fixes: git add -A && git commit -m \"fix: address ci/review\" && git push

## IMPORTANT: Generate a detailed reply for Copilot

After fixing, you MUST generate a reply that addresses EACH point from Copilot's review.
Format your reply EXACTLY like this (the REPLY_TO_COPILOT marker is required):

REPLY_TO_COPILOT:
## Addressed Feedback

| Copilot Suggestion | Action Taken |
|-------------------|--------------|
| [Quote or summarize first suggestion] | [What you did to fix it, include commit if relevant] |
| [Quote or summarize second suggestion] | [What you did to fix it] |
...

Additional notes: [Any other relevant context]

END_REPLY

At the end, output exactly:
STATUS: FIXED
" 30 "Bash,Read,Write,Edit,Grep" "$output_file"

  log "Running local checks gate..."
  autopilot_checks || true

  # If we fixed Copilot issues, reply to the PR with detailed response
  if [ "$has_copilot_issues" = true ]; then
    log "Posting detailed reply to Copilot review..."

    # Extract reply from Claude output
    local reply_text=""
    if grep -q "REPLY_TO_COPILOT:" "$output_file" 2>/dev/null; then
      # Extract between REPLY_TO_COPILOT: and END_REPLY (or STATUS: FIXED if no END_REPLY)
      reply_text=$(sed -n '/REPLY_TO_COPILOT:/,/END_REPLY\|STATUS: FIXED/p' "$output_file" \
        | grep -v "REPLY_TO_COPILOT:\|END_REPLY\|STATUS: FIXED" \
        | sed '/^$/d' | head -50)
    fi

    # Generate default reply if Claude didn't provide one
    if [ -z "$reply_text" ] || [ "$(echo "$reply_text" | wc -w)" -lt 5 ]; then
      reply_text="## ✅ Addressed Copilot Review Feedback

Thank you @copilot for the review! I've addressed the suggestions in the latest commit(s).

**Summary of changes:**
- Reviewed and fixed all actionable items from your feedback
- Ran local checks to verify the fixes

Please re-review when ready. 🙏"
    else
      # Prepend acknowledgment header
      reply_text="## ✅ Addressed Copilot Review Feedback

@copilot - Thank you for the review! Here's what I fixed:

$reply_text"
    fi

    # Post the reply
    gh pr comment "$pr_number" --body "$reply_text" 2>/dev/null || true
    log "✅ Posted detailed reply to Copilot review"
  fi

  rm -f "$TMP_DIR/failed-checks.json" 2>/dev/null || true
  # Note: keeping copilot.txt for reference, but we track by comment ID now

  # Loop back to wait for Copilot to review the fixes
  state_set "WAIT_COPILOT" "\"$epic_id\""
  log "✅ Issues fixed, waiting for Copilot to re-review"
}

# ============================================
# PHASE: MERGE_PR
# ============================================
phase_merge_pr() {
  log "🔀 PHASE: MERGE_PR"

  local epic_id
  epic_id="$(state_current_epic)"

  gh pr merge --squash --delete-branch

  git checkout main
  git pull origin main

  log "Running post-merge checks..."
  autopilot_checks

  # Clean up Copilot comment tracking for this PR (fresh start for next epic)
  rm -f "$TMP_DIR/last_copilot_comment_id.txt" "$TMP_DIR/copilot.txt" "$TMP_DIR/copilot_latest.json" 2>/dev/null || true

  state_mark_completed "$epic_id"
  # Go back to CHECK_PENDING_PR to handle any other unfinished PRs before starting new epic
  state_set "CHECK_PENDING_PR" "null"
  log "✅ Epic merged and marked completed: $epic_id"
}

main() {
  require_tooling

  # If no pattern provided, auto-detect mode (process all epics in order)
  if [ -z "$EPIC_PATTERN" ]; then
    log "ℹ️ No epic pattern provided - will process ALL epics from _bmad-output/epics.md in order"
  fi

  if [ "$CONTINUE_FLAG" != "--continue" ] || [ ! -f "$STATE_FILE" ]; then
    log "🚀 BMAD Autopilot starting (fresh)"
    # Start with CHECK_PENDING_PR to handle any unfinished PRs from previous runs
    echo '{"phase":"CHECK_PENDING_PR","current_epic":null,"completed_epics":[]}' >"$STATE_FILE"
  else
    log "🚀 BMAD Autopilot resuming (--continue)"
    state_init_if_missing
  fi

  while true; do
    local phase
    phase="$(state_phase)"
    log "━━━ Current phase: $phase ━━━"

    case "$phase" in
      "CHECK_PENDING_PR")
        phase_check_pending_pr
        ;;
      "FIND_EPIC")
        phase_find_epic || break
        ;;
      "CREATE_BRANCH")
        phase_create_branch
        ;;
      "DEVELOP_STORIES")
        phase_develop_stories
        ;;
      "CODE_REVIEW")
        phase_code_review || true
        ;;
      "CREATE_PR")
        phase_create_pr
        ;;
      "WAIT_COPILOT")
        phase_wait_copilot
        ;;
      "WAIT_CHECKS")
        phase_wait_checks
        ;;
      "FIX_ISSUES")
        phase_fix_issues || true
        ;;
      "MERGE_PR")
        phase_merge_pr
        ;;
      "BLOCKED")
        log "⚠️ BLOCKED - manual intervention needed"
        log "Fix manually then resume with: $0 \"$EPIC_PATTERN\" --continue"
        exit 1
        ;;
      "DONE")
        log "🎉 ALL EPICS COMPLETED!"
        log "Completed epics: $(jq -r '.completed_epics | join(", ")' "$STATE_FILE")"
        exit 0
        ;;
      *)
        log "❌ Unknown phase: $phase"
        exit 1
        ;;
    esac

    sleep 2
  done
}

main "$@"
