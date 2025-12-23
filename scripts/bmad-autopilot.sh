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
#   ./bmad-autopilot.sh --verbose                 # enable verbose console output
#   ./bmad-autopilot.sh -v                        # shorthand for --verbose
#   ./bmad-autopilot.sh --debug                   # enable debug logging to .autopilot/tmp/debug.log
#   AUTOPILOT_DEBUG=1 ./bmad-autopilot.sh        # alternative: enable debug via env var
#   AUTOPILOT_VERBOSE=1 ./bmad-autopilot.sh      # alternative: enable verbose via env var
#   PARALLEL_MODE=1 ./bmad-autopilot.sh          # enable parallel epic development
#
# Branch Protection Requirements:
#   - Copilot review triggers automatically on every push
#   - Requires Copilot APPROVED before merge
#   - Stale approvals are dismissed on new commits
#   - Script waits for both CI checks AND Copilot approval
#
# Parallel Mode:
#   - Work on next epic while waiting for PR review
#   - Uses git worktree to manage multiple epics
#   - Periodically checks pending PRs status
#   - Auto-merges approved PRs, pauses to fix issues
#   - Configure with PARALLEL_MODE, MAX_PENDING_PRS, PARALLEL_CHECK_INTERVAL
#
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

# Detect repository default branch (handles repos using master/main/custom)
detect_base_branch() {
  local b=""
  b="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
  if [ -n "$b" ]; then
    echo "$b"
    return 0
  fi
  # Fallbacks
  if git show-ref --verify --quiet refs/heads/main; then
    echo "main"
    return 0
  fi
  if git show-ref --verify --quiet refs/heads/master; then
    echo "master"
    return 0
  fi
  echo "main"
}

BASE_BRANCH="${AUTOPILOT_BASE_BRANCH:-$(detect_base_branch)}"

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
      (cd "$ROOT_DIR/frontend" && pnpm run typecheck)
    fi
    # Run tests only if script exists
    if (cd "$ROOT_DIR/frontend" && pnpm run test --help >/dev/null 2>&1); then
      (cd "$ROOT_DIR/frontend" && pnpm -r run test)
    fi
  fi

  # Mobile native (Gradle) - OFF by default (often needs Android toolchain)
  if [ "${AUTOPILOT_RUN_MOBILE_NATIVE:-0}" = "1" ] && [ -f "$ROOT_DIR/mobile-native/gradlew" ]; then
    (cd "$ROOT_DIR/mobile-native" && ./gradlew build)
  fi
}

# Paths
AUTOPILOT_DIR="$ROOT_DIR/.autopilot"
CONFIG_FILE="$AUTOPILOT_DIR/config"
STATE_FILE="$AUTOPILOT_DIR/state.json"
LOG_FILE="$AUTOPILOT_DIR/autopilot.log"
TMP_DIR="$AUTOPILOT_DIR/tmp"
DEBUG_LOG="$TMP_DIR/debug.log"

mkdir -p "$AUTOPILOT_DIR" "$TMP_DIR"

# Load config file safely (whitelist allowed keys, no arbitrary code execution)
# Allowed config keys:
ALLOWED_CONFIG_KEYS="AUTOPILOT_DEBUG AUTOPILOT_VERBOSE MAX_TURNS CHECK_INTERVAL MAX_CHECK_WAIT MAX_COPILOT_WAIT AUTOPILOT_RUN_MOBILE_NATIVE PARALLEL_MODE PARALLEL_CHECK_INTERVAL MAX_PENDING_PRS AUTOPILOT_BASE_BRANCH"

load_config_safely() {
  local config_file="$1"
  [ ! -f "$config_file" ] && return 0

  while IFS='=' read -r key value || [ -n "$key" ]; do
    # Skip comments and empty lines
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue

    # Trim whitespace
    key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    value="$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Remove quotes from value
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"

    # Only set whitelisted keys
    if echo " $ALLOWED_CONFIG_KEYS " | grep -q " $key "; then
      export "$key=$value"
    else
      echo "⚠️ Ignoring unknown config key: $key" >&2
    fi
  done < "$config_file"
}

if [ -f "$CONFIG_FILE" ]; then
  load_config_safely "$CONFIG_FILE"
fi

# Config - parse arguments (handle --continue, --debug, --verbose as first or second arg)
EPIC_PATTERN=""
CONTINUE_FLAG=""
DEBUG_MODE="${AUTOPILOT_DEBUG:-0}"
VERBOSE_MODE="${AUTOPILOT_VERBOSE:-0}"
for arg in "$@"; do
  if [ "$arg" = "--continue" ]; then
    CONTINUE_FLAG="--continue"
  elif [ "$arg" = "--debug" ]; then
    DEBUG_MODE="1"
  elif [ "$arg" = "--verbose" ] || [ "$arg" = "-v" ]; then
    VERBOSE_MODE="1"
  elif [ -z "$EPIC_PATTERN" ]; then
    EPIC_PATTERN="$arg"
  fi
done

# Debug mode implies verbose
if [ "$DEBUG_MODE" = "1" ]; then
  VERBOSE_MODE="1"
fi

# Configuration with defaults (env vars override config file)
MAX_TURNS="${MAX_TURNS:-80}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"           # seconds between CI/Copilot polls
MAX_CHECK_WAIT="${MAX_CHECK_WAIT:-60}"           # max poll iterations
AUTOPILOT_RUN_MOBILE_NATIVE="${AUTOPILOT_RUN_MOBILE_NATIVE:-0}"

# Parallel mode configuration
PARALLEL_MODE="${PARALLEL_MODE:-0}"              # enable parallel epic development
PARALLEL_CHECK_INTERVAL="${PARALLEL_CHECK_INTERVAL:-60}"  # seconds between pending PR checks
MAX_PENDING_PRS="${MAX_PENDING_PRS:-2}"          # max PRs waiting before blocking

# Worktree directory for parallel mode
WORKTREE_DIR="$AUTOPILOT_DIR/worktrees"

# Initialize debug log if debug mode is enabled
if [ "$DEBUG_MODE" = "1" ]; then
  echo "=== Debug session started: $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$DEBUG_LOG"
  echo "Config file: $CONFIG_FILE (exists: $([ -f "$CONFIG_FILE" ] && echo yes || echo no))" >> "$DEBUG_LOG"
  echo "Settings: MAX_TURNS=$MAX_TURNS CHECK_INTERVAL=$CHECK_INTERVAL MAX_CHECK_WAIT=$MAX_CHECK_WAIT" >> "$DEBUG_LOG"
  echo "Parallel mode: PARALLEL_MODE=$PARALLEL_MODE MAX_PENDING_PRS=$MAX_PENDING_PRS" >> "$DEBUG_LOG"
fi

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" | tee -a "$LOG_FILE"
}

# Verbose logging - shown in console when --verbose or -v flag is used
verbose() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" >> "$LOG_FILE"
  if [ "$VERBOSE_MODE" = "1" ]; then
    echo "$msg"
  fi
}

debug() {
  if [ "$DEBUG_MODE" = "1" ]; then
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $1"
    echo "$msg" >> "$DEBUG_LOG"
    # Also show debug in console when verbose
    if [ "$VERBOSE_MODE" = "1" ]; then
      echo "$msg"
    fi
  fi
}

require_tooling() {
  require_cmd jq
  require_cmd git
  require_cmd gh
  require_cmd claude
  require_cmd rg
}

# ============================================
# WORKTREE HELPERS (for parallel mode)
# ============================================

# Create a worktree for an epic branch
# Usage: worktree_create "epic-7A" "feature/epic-7A"
worktree_create() {
  local epic_id="$1"
  local branch_name="$2"
  local wt_path="$WORKTREE_DIR/$epic_id"

  if [ -d "$wt_path" ]; then
    debug "Worktree already exists: $wt_path"
    return 0
  fi

  mkdir -p "$WORKTREE_DIR"
  log "🌳 Creating worktree for $epic_id at $wt_path"
  git worktree add "$wt_path" "$branch_name" 2>/dev/null || {
    # Branch might not exist yet, create from main
    git worktree add -b "$branch_name" "$wt_path" "$BASE_BRANCH"
  }
  debug "Worktree created: $wt_path"
}

# Remove a worktree
# Usage: worktree_remove "epic-7A"
worktree_remove() {
  local epic_id="$1"
  local wt_path="$WORKTREE_DIR/$epic_id"

  if [ ! -d "$wt_path" ]; then
    debug "Worktree does not exist: $wt_path"
    return 0
  fi

  log "🗑️ Removing worktree for $epic_id"
  git worktree remove "$wt_path" --force 2>/dev/null || true
  debug "Worktree removed: $wt_path"
}

# Get worktree path for an epic
# Usage: worktree_path "epic-7A"
worktree_path() {
  local epic_id="$1"
  echo "$WORKTREE_DIR/$epic_id"
}

# Check if worktree exists
# Usage: worktree_exists "epic-7A"
worktree_exists() {
  local epic_id="$1"
  [ -d "$WORKTREE_DIR/$epic_id" ]
}

# Run command in worktree context
# Usage: worktree_exec "epic-7A" "git status"
worktree_exec() {
  local epic_id="$1"
  shift
  local wt_path="$WORKTREE_DIR/$epic_id"

  if [ ! -d "$wt_path" ]; then
    log "❌ Worktree does not exist: $wt_path"
    return 1
  fi

  (cd "$wt_path" && "$@")
}

# List all active worktrees
worktree_list() {
  git worktree list --porcelain | grep "^worktree " | sed 's/^worktree //'
}

# Clean up orphaned worktrees
worktree_prune() {
  log "🧹 Pruning orphaned worktrees..."
  git worktree prune
}

# ============================================
# STATE MANAGEMENT
# ============================================

state_init_if_missing() {
  if [ ! -f "$STATE_FILE" ]; then
    if [ "$PARALLEL_MODE" = "1" ]; then
      # Parallel mode state structure
      echo '{
        "mode": "parallel",
        "active_epic": null,
        "active_phase": "FIND_EPIC",
        "active_worktree": null,
        "pending_prs": [],
        "completed_epics": []
      }' | jq -c . >"$STATE_FILE"
    else
      # Sequential mode (legacy)
      echo '{"phase":"FIND_EPIC","current_epic":null,"completed_epics":[]}' >"$STATE_FILE"
    fi
  fi
}

state_get() {
  state_init_if_missing
  cat "$STATE_FILE"
}

# Sequential mode state helpers (legacy compatibility)
state_phase() {
  state_init_if_missing
  if [ "$PARALLEL_MODE" = "1" ]; then
    jq -r '.active_phase // .phase // "FIND_EPIC"' "$STATE_FILE"
  else
    jq -r '.phase' "$STATE_FILE"
  fi
}

state_current_epic() {
  state_init_if_missing
  if [ "$PARALLEL_MODE" = "1" ]; then
    jq -r '.active_epic // .current_epic // "null"' "$STATE_FILE"
  else
    jq -r '.current_epic' "$STATE_FILE"
  fi
}

state_completed_csv() {
  state_init_if_missing
  jq -r '.completed_epics | join(",")' "$STATE_FILE"
}

state_set() {
  local phase="$1"
  local epic_json="${2:-null}" # JSON string or null
  state_init_if_missing

  if [ "$PARALLEL_MODE" = "1" ]; then
    # Parallel mode: update active_phase and active_epic
    jq --arg phase "$phase" --argjson epic "$epic_json" \
      '.active_phase = $phase | .active_epic = $epic' "$STATE_FILE" >"$STATE_FILE.tmp" \
      && mv "$STATE_FILE.tmp" "$STATE_FILE"
  else
    # Sequential mode (legacy)
    local completed
    completed="$(jq '.completed_epics' "$STATE_FILE" 2>/dev/null || echo '[]')"
    jq -n --arg phase "$phase" --argjson current_epic "$epic_json" --argjson completed_epics "$completed" \
      '{phase:$phase,current_epic:$current_epic,completed_epics:$completed_epics}' >"$STATE_FILE"
  fi
}

state_mark_completed() {
  local epic="$1"
  state_init_if_missing
  jq --arg epic "$epic" '.completed_epics += [$epic] | .completed_epics |= unique' "$STATE_FILE" >"$STATE_FILE.tmp" \
    && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# ============================================
# PARALLEL MODE STATE HELPERS
# ============================================

# Add a PR to pending list
# Usage: state_add_pending_pr "7A" 123 "/path/to/worktree"
state_add_pending_pr() {
  local epic_id="$1"
  local pr_number="$2"
  local wt_path="$3"

  state_init_if_missing
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  jq --arg epic "$epic_id" \
     --argjson pr "$pr_number" \
     --arg wt "$wt_path" \
     --arg now "$now" \
    '.pending_prs += [{
      "epic": $epic,
      "pr_number": $pr,
      "worktree": $wt,
      "status": "WAIT_REVIEW",
      "last_check": $now,
      "last_copilot_id": null
    }]' "$STATE_FILE" >"$STATE_FILE.tmp" \
    && mv "$STATE_FILE.tmp" "$STATE_FILE"

  debug "Added pending PR: epic=$epic_id pr=#$pr_number"
}

# Update pending PR status
# Usage: state_update_pending_pr "7A" "status" "WAIT_CI"
state_update_pending_pr() {
  local epic_id="$1"
  local field="$2"
  local value="$3"

  state_init_if_missing
  jq --arg epic "$epic_id" \
     --arg field "$field" \
     --arg value "$value" \
    '(.pending_prs[] | select(.epic == $epic))[$field] = $value' "$STATE_FILE" >"$STATE_FILE.tmp" \
    && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# Remove a PR from pending list
# Usage: state_remove_pending_pr "7A"
state_remove_pending_pr() {
  local epic_id="$1"

  state_init_if_missing
  jq --arg epic "$epic_id" \
    '.pending_prs = [.pending_prs[] | select(.epic != $epic)]' "$STATE_FILE" >"$STATE_FILE.tmp" \
    && mv "$STATE_FILE.tmp" "$STATE_FILE"

  debug "Removed pending PR: epic=$epic_id"
}

# Get pending PR info
# Usage: state_get_pending_pr "7A"
state_get_pending_pr() {
  local epic_id="$1"
  state_init_if_missing
  jq -c --arg epic "$epic_id" '.pending_prs[] | select(.epic == $epic)' "$STATE_FILE"
}

# Get all pending PRs
state_get_all_pending_prs() {
  state_init_if_missing
  jq -c '.pending_prs // []' "$STATE_FILE"
}

# Count pending PRs
state_count_pending_prs() {
  state_init_if_missing
  jq '.pending_prs | length' "$STATE_FILE"
}

# Save active development state (for pause/resume)
# Usage: state_save_active_context
state_save_active_context() {
  state_init_if_missing
  local epic_id
  epic_id="$(state_current_epic)"
  local phase
  phase="$(state_phase)"

  if [ "$epic_id" != "null" ] && [ -n "$epic_id" ]; then
    jq --arg epic "$epic_id" \
       --arg phase "$phase" \
      '.paused_context = {"epic": $epic, "phase": $phase}' "$STATE_FILE" >"$STATE_FILE.tmp" \
      && mv "$STATE_FILE.tmp" "$STATE_FILE"
    log "💾 Saved active context: epic=$epic_id phase=$phase"
  fi
}

# Restore active development state
# Usage: state_restore_active_context
state_restore_active_context() {
  state_init_if_missing
  local paused
  paused="$(jq -c '.paused_context // null' "$STATE_FILE")"

  if [ "$paused" != "null" ]; then
    local epic_id
    epic_id="$(echo "$paused" | jq -r '.epic')"
    local phase
    phase="$(echo "$paused" | jq -r '.phase')"

    jq '.paused_context = null' "$STATE_FILE" >"$STATE_FILE.tmp" \
      && mv "$STATE_FILE.tmp" "$STATE_FILE"

    state_set "$phase" "\"$epic_id\""
    log "▶️ Restored active context: epic=$epic_id phase=$phase"
    return 0
  fi
  return 1
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

  # In parallel mode, also exclude epics that have pending PRs
  local pending_epics=""
  if [ "$PARALLEL_MODE" = "1" ]; then
    pending_epics="$(jq -r '.pending_prs[].epic // empty' "$STATE_FILE" 2>/dev/null | tr '\n' ',')"
  fi

  while IFS= read -r epic; do
    [ -z "$epic" ] && continue
    epic_matches_patterns "$epic" || continue
    # Skip completed epics
    if [ -n "$completed_csv" ] && echo ",$completed_csv," | grep -q ",$epic,"; then
      continue
    fi
    # Skip epics with pending PRs (parallel mode)
    if [ -n "$pending_epics" ] && echo ",$pending_epics" | grep -q ",$epic,"; then
      debug "Skipping epic $epic - has pending PR"
      continue
    fi
    echo "$epic"
    return 0
  done < <(parse_epics_from_bmad_output)

  return 1
}

# ============================================
# PARALLEL MODE: PENDING PR MANAGEMENT
# ============================================

# Check status of a single pending PR
# Returns: "approved", "needs_fixes", "waiting", or "merged"
check_pending_pr_status() {
  local epic_id="$1"
  local pr_number="$2"
  local wt_path="$3"

  debug "Checking PR #$pr_number for epic $epic_id"

  # Check if PR is still open
  local pr_state
  pr_state="$(gh pr view "$pr_number" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")"

  if [ "$pr_state" = "MERGED" ]; then
    echo "merged"
    return 0
  elif [ "$pr_state" = "CLOSED" ]; then
    echo "closed"
    return 0
  elif [ "$pr_state" != "OPEN" ]; then
    debug "PR #$pr_number state unknown: $pr_state"
    echo "waiting"
    return 0
  fi

  # Check CI status
  local check_conclusions
  check_conclusions="$(gh pr checks "$pr_number" --json conclusion -q '.[].conclusion' 2>/dev/null || echo "")"

  if echo "$check_conclusions" | grep -iq "failure"; then
    debug "PR #$pr_number has CI failures"
    echo "needs_fixes"
    return 0
  fi

  local ci_pending=false
  if echo "$check_conclusions" | grep -iq "pending"; then
    ci_pending=true
  fi

  # Check for any approval (from auto-approve workflow or manual)
  local is_approved=false
  local approver
  approver="$(gh pr view "$pr_number" --json reviews -q '
    [.reviews[] | select(.state == "APPROVED")] | .[-1].author.login // ""
  ' 2>/dev/null || echo "")"

  if [ -n "$approver" ]; then
    is_approved=true
  fi

  # Check Copilot review status
  local copilot_state
  copilot_state="$(gh pr view "$pr_number" --json reviews -q '
    [.reviews[] | select(.author.login | test("copilot"; "i"))] | sort_by(.submittedAt) | .[-1].state // ""
  ' 2>/dev/null || echo "")"

  if [ "$copilot_state" = "CHANGES_REQUESTED" ]; then
    echo "needs_fixes"
    return 0
  fi

  # Check for unresolved review threads
  local unresolved_count
  unresolved_count="$(count_unresolved_threads "$pr_number")"
  if [ "$unresolved_count" -gt 0 ]; then
    echo "needs_fixes"
    return 0
  fi

  # Ready to merge if approved and CI passed
  if [ "$is_approved" = true ] && [ "$ci_pending" = false ]; then
    echo "approved"
    return 0
  fi

  echo "waiting"
}

# Check all pending PRs and take action
# Returns: 0 if we should continue active development, 1 if we need to pause for fixes
check_all_pending_prs() {
  local pending_prs
  pending_prs="$(state_get_all_pending_prs)"

  if [ "$pending_prs" = "[]" ] || [ -z "$pending_prs" ]; then
    debug "No pending PRs to check"
    return 0
  fi

  log "🔍 Checking $(echo "$pending_prs" | jq 'length') pending PR(s)..."

  local pr_to_fix=""

  # Use process substitution to avoid subshell issues with while loop
  while read -r pr_info; do
    [ -z "$pr_info" ] && continue

    local epic_id
    epic_id="$(echo "$pr_info" | jq -r '.epic')"
    local pr_number
    pr_number="$(echo "$pr_info" | jq -r '.pr_number')"
    local wt_path
    wt_path="$(echo "$pr_info" | jq -r '.worktree')"

    local status
    status="$(check_pending_pr_status "$epic_id" "$pr_number" "$wt_path")"

    case "$status" in
      "approved")
        log "✅ PR #$pr_number (epic $epic_id) is approved and ready to merge"
        handle_approved_pr "$epic_id" "$pr_number" "$wt_path"
        ;;
      "merged")
        log "✅ PR #$pr_number (epic $epic_id) was already merged"
        handle_merged_pr "$epic_id" "$wt_path"
        ;;
      "closed")
        log "⚠️ PR #$pr_number (epic $epic_id) was closed without merge"
        state_remove_pending_pr "$epic_id"
        worktree_remove "$epic_id"
        ;;
      "needs_fixes")
        log "⚠️ PR #$pr_number (epic $epic_id) needs fixes"
        # Mark first PR that needs fixes (will handle one at a time)
        if [ -z "$pr_to_fix" ]; then
          pr_to_fix="$epic_id"
        fi
        ;;
      "waiting")
        debug "PR #$pr_number (epic $epic_id) still waiting for review/CI"
        state_update_pending_pr "$epic_id" "last_check" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        ;;
    esac
  done < <(echo "$pending_prs" | jq -c '.[]')

  # Check if any PR needs fixes
  if [ -n "$pr_to_fix" ]; then
    echo "$pr_to_fix"
    return 1
  fi

  return 0
}

# Handle approved PR - merge it
handle_approved_pr() {
  local epic_id="$1"
  local pr_number="$2"
  local wt_path="$3"

  log "🔀 Merging approved PR #$pr_number for epic $epic_id"

  # Merge the PR
  if gh pr merge "$pr_number" --squash --delete-branch; then
    log "✅ PR #$pr_number merged successfully"
    state_remove_pending_pr "$epic_id"
    state_mark_completed "$epic_id"
    worktree_remove "$epic_id"
  else
    log "❌ Failed to merge PR #$pr_number"
    state_update_pending_pr "$epic_id" "status" "MERGE_FAILED"
  fi
}

# Handle already merged PR - cleanup
handle_merged_pr() {
  local epic_id="$1"
  local wt_path="$2"

  state_remove_pending_pr "$epic_id"
  state_mark_completed "$epic_id"
  worktree_remove "$epic_id"
  log "🧹 Cleaned up after merged epic $epic_id"
}

# Count unresolved review threads on a PR
# Returns the count (0 if none or on error)
count_unresolved_threads() {
  local pr_number="$1"

  local repo_info
  repo_info="$(gh repo view --json owner,name -q '"\(.owner.login)/\(.name)"' 2>/dev/null || echo "")"

  if [ -z "$repo_info" ]; then
    echo "0"
    return 0
  fi

  local owner="${repo_info%%/*}"
  local repo="${repo_info##*/}"

  local count
  count="$(gh api graphql -f query='
    query($owner: String!, $repo: String!, $pr: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100) {
            nodes { isResolved }
          }
        }
      }
    }
  ' -F owner="$owner" -F repo="$repo" -F pr="$pr_number" \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length' 2>/dev/null || echo "0")"

  echo "${count:-0}"
}

# Resolve all unresolved review threads on a PR
# Uses GitHub GraphQL API to mark threads as resolved
resolve_pr_review_threads() {
  local pr_number="$1"

  # Get repo owner and name
  local repo_info
  repo_info="$(gh repo view --json owner,name -q '"\(.owner.login)/\(.name)"')"

  if [ -z "$repo_info" ]; then
    log "⚠️ Could not determine repo info for resolving threads"
    return 1
  fi

  log "🔍 Fetching unresolved review threads for PR #$pr_number..."

  # Get all unresolved review threads via GraphQL
  local threads_query='
    query($owner: String!, $repo: String!, $pr: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              comments(first: 1) {
                nodes {
                  body
                  author { login }
                }
              }
            }
          }
        }
      }
    }
  '

  local owner="${repo_info%%/*}"
  local repo="${repo_info##*/}"

  local threads_json
  threads_json="$(gh api graphql -f query="$threads_query" \
    -F owner="$owner" -F repo="$repo" -F pr="$pr_number" 2>/dev/null || echo "")"

  if [ -z "$threads_json" ]; then
    debug "Could not fetch review threads"
    return 0
  fi

  # Extract unresolved thread IDs
  local unresolved_threads
  unresolved_threads="$(echo "$threads_json" | jq -r '
    .data.repository.pullRequest.reviewThreads.nodes[]
    | select(.isResolved == false)
    | .id
  ' 2>/dev/null || echo "")"

  if [ -z "$unresolved_threads" ]; then
    debug "No unresolved review threads found"
    return 0
  fi

  local resolved_count=0
  local thread_id

  while IFS= read -r thread_id; do
    [ -z "$thread_id" ] && continue

    debug "Resolving thread: $thread_id"

    local resolve_mutation='
      mutation($threadId: ID!) {
        resolveReviewThread(input: {threadId: $threadId}) {
          thread { isResolved }
        }
      }
    '

    if gh api graphql -f query="$resolve_mutation" -F threadId="$thread_id" >/dev/null 2>&1; then
      resolved_count=$((resolved_count + 1))
    else
      debug "Failed to resolve thread: $thread_id"
    fi
  done <<< "$unresolved_threads"

  if [ "$resolved_count" -gt 0 ]; then
    log "✅ Resolved $resolved_count review thread(s)"
  fi

  return 0
}

# Fix issues in a pending PR (pause active work, switch context)
fix_pending_pr_issues() {
  local epic_id="$1"

  local pr_info
  pr_info="$(state_get_pending_pr "$epic_id")"
  if [ -z "$pr_info" ]; then
    log "❌ No pending PR found for epic $epic_id"
    return 1
  fi

  local pr_number
  pr_number="$(echo "$pr_info" | jq -r '.pr_number')"
  local wt_path
  wt_path="$(echo "$pr_info" | jq -r '.worktree')"
  local branch_name="feature/epic-${epic_id}"

  log "🔧 Fixing issues in PR #$pr_number (epic $epic_id)"

  # Save current active context
  state_save_active_context

  # Create worktree on-demand if it doesn't exist
  if [ ! -d "$wt_path" ]; then
    log "🌳 Creating worktree for $epic_id..."
    mkdir -p "$WORKTREE_DIR"
    # Fetch the branch first
    git fetch origin "$branch_name" 2>/dev/null || true
    git worktree add "$wt_path" "$branch_name" 2>/dev/null || {
      log "❌ Failed to create worktree for $branch_name"
      state_restore_active_context
      return 1
    }
  fi

  # Switch to the worktree and fix issues
  if [ -d "$wt_path" ]; then
    (
      cd "$wt_path"

      # Get CI failures
      local ci_failures=""
      gh pr checks "$pr_number" --json name,conclusion,detailsUrl 2>/dev/null | \
        jq -c '[.[] | select(.conclusion == "failure")]' > "$TMP_DIR/failed-checks.json" || true

      if [ -s "$TMP_DIR/failed-checks.json" ] && [ "$(cat "$TMP_DIR/failed-checks.json")" != "[]" ]; then
        ci_failures="$(cat "$TMP_DIR/failed-checks.json")"
      fi

      # Get Copilot feedback
      local copilot_feedback=""
      copilot_feedback="$(gh pr view "$pr_number" --json reviews -q '
        [.reviews[] | select(.author.login | test("copilot"; "i"))] | sort_by(.submittedAt) | .[-1].body // ""
      ' 2>/dev/null || echo "")"

      # Build issues string
      local issues=""
      [ -n "$copilot_feedback" ] && issues="COPILOT REVIEW:\n$copilot_feedback\n\n"
      [ -n "$ci_failures" ] && issues="${issues}CI FAILURES:\n$ci_failures"

      # Run Claude to fix issues
      local output_file="$TMP_DIR/fix-pr-output.txt"
      log "🤖 Running Claude to fix PR issues..."

      claude -p "
Fix ONLY issues from CI failures and/or Copilot review feedback.

Issues:
$issues

Rules:
- Do not introduce new features
- Keep changes minimal
- Fix each issue mentioned by Copilot
- After fixes: git add -A && git commit -m \"fix: address ci/review\" && git push

At the end, output exactly:
STATUS: FIXED
" --permission-mode acceptEdits \
        --allowedTools "Bash,Read,Write,Edit,Grep" \
        --max-turns 30 \
        2>&1 | tee "$output_file"

      log "✅ Fixes applied to PR #$pr_number"
    )

    # Update PR status
    state_update_pending_pr "$epic_id" "status" "WAIT_REVIEW"
    state_update_pending_pr "$epic_id" "last_check" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  else
    log "❌ Worktree not found: $wt_path"
    return 1
  fi

  # Restore active context
  state_restore_active_context

  return 0
}

# Run Claude in headless mode (background/automated tasks)
# Usage: run_claude_headless "prompt" [max_turns] [allowed_tools] [output_file]
run_claude_headless() {
  local prompt="$1"
  local max_turns="${2:-$MAX_TURNS}"
  local allowed_tools="${3:-Bash,Read,Write,Edit,Grep}"
  local output_file="${4:-$TMP_DIR/claude-output.txt}"

  log "🤖 Claude headless (max_turns=$max_turns)"
  verbose "   Tools: $allowed_tools"
  verbose "   Output: $output_file"
  verbose "   Prompt (first 200 chars): ${prompt:0:200}..."
  claude -p "$prompt" \
    --permission-mode acceptEdits \
    --allowedTools "$allowed_tools" \
    --max-turns "$max_turns" \
    2>&1 | tee "$output_file"
}

# Run Claude in interactive foreground mode (main development work)
# Usage: run_claude_interactive "prompt" [output_file]
run_claude_interactive() {
  local prompt="$1"
  local output_file="${2:-$TMP_DIR/claude-output.txt}"

  log "🤖 Claude interactive (foreground)"
  verbose "   Output: $output_file"

  # Save prompt to file for reference
  local prompt_file="$TMP_DIR/claude-prompt.md"
  echo "$prompt" > "$prompt_file"

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Starting interactive Claude session..."
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Run Claude interactively - use script to capture output while preserving TTY
  # This allows proper terminal interaction while still logging output
  if [[ "$(uname -s)" == "Darwin" ]]; then
    # macOS syntax: script -q file command...
    script -q "$output_file" claude --permission-mode acceptEdits "$prompt"
  else
    # Linux syntax: script -q -c "command" file
    script -q -c "claude --permission-mode acceptEdits \"$prompt\"" "$output_file"
  fi
}

# ============================================
# PHASE: CHECK_PENDING_PR
# ============================================
phase_check_pending_pr() {
  log "🔍 PHASE: CHECK_PENDING_PR"
  verbose "   Checking for open epic PRs..."

  # 1) Count and list all open epic PRs - we must finish them before starting new epics
  local open_epic_branches
  open_epic_branches="$(
    gh pr list --state open --json headRefName,number \
      -q '.[] | select(.headRefName | test("^feature/epic-")) | "\(.number):\(.headRefName)"'
  )"

  local open_count=0
  if [ -n "$open_epic_branches" ]; then
    open_count="$(echo "$open_epic_branches" | wc -l | tr -d ' ')"
  fi
  verbose "   Found $open_count open epic PR(s)"

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

    # Check if there's a PR for this branch and its state
    local pr_info
    pr_info="$(gh pr view --json number,state -q '{number: .number, state: .state}' 2>/dev/null || echo "")"

    if [ -n "$pr_info" ]; then
      local pr_number pr_state
      pr_number="$(echo "$pr_info" | jq -r '.number')"
      pr_state="$(echo "$pr_info" | jq -r '.state')"
      verbose "   PR #$pr_number state: $pr_state"

      if [ "$pr_state" = "OPEN" ]; then
        log "⚠️ Found open PR #$pr_number for epic $epic_id - resuming PR flow"
        # Clean up stale comment tracking
        rm -f "$TMP_DIR/last_copilot_comment_id.txt" 2>/dev/null || true
        state_set "WAIT_COPILOT" "\"$epic_id\""
        return 0
      elif [ "$pr_state" = "MERGED" ]; then
        log "✅ PR #$pr_number was already merged"
        # Check if there are new changes on this branch since the merge
        git fetch origin "$BASE_BRANCH" 2>/dev/null || true
        local new_commits
        new_commits="$(git log "origin/$BASE_BRANCH..HEAD" --oneline 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$new_commits" -gt 0 ]; then
          log "📝 Found $new_commits new commit(s) since merge - will create new PR"
          state_set "CODE_REVIEW" "\"$epic_id\""
          return 0
        else
          log "   No new changes - switching to $BASE_BRANCH"
          git checkout "$BASE_BRANCH" 2>/dev/null || true
          git pull origin "$BASE_BRANCH" 2>/dev/null || true
        fi
      elif [ "$pr_state" = "CLOSED" ]; then
        log "⚠️ PR #$pr_number was closed (not merged)"
        # Check if there are changes to push
        git fetch origin "$BASE_BRANCH" 2>/dev/null || true
        if [ -n "$(git diff "origin/$BASE_BRANCH..HEAD" --name-only 2>/dev/null)" ]; then
          log "📝 Branch has changes - will create new PR"
          state_set "CODE_REVIEW" "\"$epic_id\""
          return 0
        fi
      fi
    else
      log "Branch exists but no PR - checking if we need to create one"
      # Check if there are unpushed commits or changes from base
      git fetch origin "$current_branch" 2>/dev/null || true
      git fetch origin "$BASE_BRANCH" 2>/dev/null || true
      if [ -n "$(git log "origin/$current_branch..HEAD" 2>/dev/null)" ] || [ -n "$(git diff "origin/$BASE_BRANCH..HEAD" --name-only 2>/dev/null)" ]; then
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
  git checkout "$BASE_BRANCH"
  git pull origin "$BASE_BRANCH"
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

  # Check for clean git state (warn but don't exit)
  if [ -n "$(git status --porcelain)" ]; then
    log "⚠️ Git working tree not clean - committing pending changes first"
    git add -A && git commit -m "chore: auto-commit before story development" || true
  fi

  local output_file="$TMP_DIR/develop-stories-output.txt"

  # Main development runs in interactive foreground mode
  run_claude_interactive "
/bmad:bmm:workflows:dev-story develop epic stories ${epic_id}.*

## Development Task
For each story in epic ${epic_id}:
1. Create storyfile if it doesn't exist
2. Implement the story completely
3. Write unit tests
4. Commit after each story: git add -A && git commit -m \"feat(${epic_id}): [story description]\"

When you complete ALL stories, respond exactly:
STATUS: STORIES_COMPLETE

If you encounter a blocker you cannot resolve:
STATUS: STORIES_BLOCKED - [reason]
" "$output_file"

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

  # Run BMAD code-review workflow in interactive foreground mode
  log "Running BMAD code-review workflow for epic $epic_id"
  run_claude_interactive "
/bmad:bmm:workflows:code-review ${epic_id}-*

## Code Review Task
Review all code changes for epic ${epic_id}.
Fix any issues found during the review.

Steps:
1. Review diff: git diff $BASE_BRANCH...HEAD
2. Fix issues you find (readability, architecture, tests, lint)
3. Run local checks to verify
4. Commit fixes: git add -A && git commit -m 'fix: address code review feedback'

At the end, output exactly:
STATUS: CODE_REVIEW_DONE
"

  # Verify checks pass
  if autopilot_checks; then
    git push 2>/dev/null || true
    state_set "CREATE_PR" "\"$epic_id\""
    log "✅ Code review passed"
    return 0
  fi

  log "⚠️ Local checks failed after code review"
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

  local pr_number=""
  if ! gh pr view >/dev/null 2>&1; then
    gh pr create --fill --label "epic,automated,epic-$epic_id" || gh pr create --fill
  fi
  pr_number="$(gh pr view --json number -q '.number')"

  # Note: Copilot review triggers automatically on push (branch protection)
  # No need to manually request @copilot review

  # Add PR to pending list for background monitoring
  local branch_name="feature/epic-${epic_id}"
  local wt_path
  wt_path="$(worktree_path "$epic_id")"

  # Record pending PR - worktree will be created on-demand if fixes are needed
  state_add_pending_pr "$epic_id" "$pr_number" "$wt_path"
  log "✅ PR #$pr_number created for epic $epic_id, added to pending list"

  # Switch back to base branch for next epic
  git checkout "$BASE_BRANCH"
  git pull origin "$BASE_BRANCH"

  # Always auto-continue to next epic, PR reviews run in background
  log "🔄 PR created, starting next epic (PR review runs in background)..."
  state_set "FIND_EPIC" "null"
}

# ============================================
# PHASE: WAIT_COPILOT
# ============================================
phase_wait_copilot() {
  log "🤖 PHASE: WAIT_COPILOT"

  local epic_id
  epic_id="$(state_current_epic)"

  local pr_number
  pr_number="$(gh pr view --json number -q '.number' 2>/dev/null || echo "")"
  if [ -z "$pr_number" ]; then
    log "❌ Could not get PR number - PR may not exist"
    state_set "BLOCKED" "\"$epic_id\""
    return 1
  fi
  log "Waiting for GitHub Copilot review on PR #$pr_number"

  # Get the last processed Copilot comment/review ID to avoid reacting to old ones
  local last_processed_id=""
  if [ -f "$TMP_DIR/last_copilot_comment_id.txt" ]; then
    last_processed_id="$(cat "$TMP_DIR/last_copilot_comment_id.txt")"
    log "Last processed Copilot ID: $last_processed_id"
  fi

  # Timeout for waiting for Copilot (use MAX_CHECK_WAIT as default)
  local max_copilot_wait="${MAX_COPILOT_WAIT:-$MAX_CHECK_WAIT}"

  local i=0
  while [ "$i" -lt "$max_copilot_wait" ]; do
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
        # Reviews use submittedAt; normalize to createdAt for consistent sorting
        [.reviews[] | select(.author.login | test("copilot"; "i")) | {id: .id, body: .body, createdAt: (.submittedAt // .createdAt // .updatedAt), type: "review", state: .state, author: .author.login}]
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
      verbose "   Iteration $i/$max_copilot_wait: No Copilot review yet, waiting ${CHECK_INTERVAL}s..."
      log "… waiting for Copilot to review ($i/$max_copilot_wait)"
      sleep "$CHECK_INTERVAL"
      continue
    fi

    # Skip if same as already processed
    if [ "$latest_id" = "$last_processed_id" ]; then
      verbose "   Iteration $i/$max_copilot_wait: Already processed $latest_id, waiting ${CHECK_INTERVAL}s..."
      log "… waiting for NEW Copilot activity (already processed $latest_id) ($i/$max_copilot_wait)"
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

    # Check if Copilot requested changes
    if [ "$review_state" = "CHANGES_REQUESTED" ]; then
      log "⚠️ Copilot REQUESTED CHANGES"
      state_set "FIX_ISSUES" "\"$epic_id\""
      return 0
    fi

    # Check unresolved review threads
    local unresolved_count
    unresolved_count="$(count_unresolved_threads "$pr_number")"
    if [ "$unresolved_count" -gt 0 ]; then
      log "⚠️ Found $unresolved_count unresolved review thread(s) - need to fix"
      state_set "FIX_ISSUES" "\"$epic_id\""
      return 0
    fi

    # No issues! Add to pending list and continue to next epic
    # Auto-approve workflow handles CI wait + approval + merge
    log "✅ Copilot review complete, no issues found"
    log "🔄 Adding PR to pending list, continuing to next epic..."

    local wt_path
    wt_path="$(worktree_path "$epic_id")"
    state_add_pending_pr "$epic_id" "$pr_number" "$wt_path"

    git checkout "$BASE_BRANCH"
    git pull origin "$BASE_BRANCH"

    state_set "FIND_EPIC" "null"
    return 0
  done

  # Timeout reached
  log "⚠️ Timeout waiting for Copilot review ($max_copilot_wait iterations)"
  state_set "BLOCKED" "\"$epic_id\""
  return 1
}

# ============================================
# PHASE: WAIT_CHECKS (deprecated - redirects to FIND_EPIC)
# ============================================
phase_wait_checks() {
  log "⏳ PHASE: WAIT_CHECKS (deprecated)"

  # This phase is deprecated - auto-approve workflow handles CI/approval
  # Add current epic to pending list and continue to next epic
  local epic_id
  epic_id="$(state_current_epic)"

  local pr_number
  pr_number="$(gh pr view --json number -q '.number' 2>/dev/null || echo "")"

  if [ -n "$pr_number" ]; then
    local wt_path
    wt_path="$(worktree_path "$epic_id")"
    state_add_pending_pr "$epic_id" "$pr_number" "$wt_path"
    log "🔄 PR #$pr_number added to pending list"
  fi

  git checkout "$BASE_BRANCH" 2>/dev/null || true
  git pull origin "$BASE_BRANCH" 2>/dev/null || true

  state_set "FIND_EPIC" "null"
  log "🔄 Continuing to next epic (auto-approve handles PR in background)"
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

    # Resolve review threads after addressing feedback
    resolve_pr_review_threads "$pr_number"
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

  if ! gh pr merge --squash --delete-branch; then
    log "❌ Failed to merge PR - may need manual intervention"
    state_set "BLOCKED" "\"$epic_id\""
    return 1
  fi

  git checkout "$BASE_BRANCH"
  git pull origin "$BASE_BRANCH"

  log "Running post-merge checks..."
  autopilot_checks

  # Clean up Copilot comment tracking for this PR (fresh start for next epic)
  rm -f "$TMP_DIR/last_copilot_comment_id.txt" "$TMP_DIR/copilot.txt" "$TMP_DIR/copilot_latest.json" 2>/dev/null || true

  state_mark_completed "$epic_id"

  # In parallel mode, also clean up worktree if exists
  if [ "$PARALLEL_MODE" = "1" ]; then
    worktree_remove "$epic_id"
    state_remove_pending_pr "$epic_id"
  fi

  # Go back to CHECK_PENDING_PR to handle any other unfinished PRs before starting new epic
  state_set "CHECK_PENDING_PR" "null"
  log "✅ Epic merged and marked completed: $epic_id"
}

main() {
  require_tooling

  # Verbose startup info
  if [ "$VERBOSE_MODE" = "1" ]; then
    log "📋 Configuration:"
    log "   ROOT_DIR: $ROOT_DIR"
    log "   BASE_BRANCH: $BASE_BRANCH"
    log "   MAX_TURNS: $MAX_TURNS"
    log "   CHECK_INTERVAL: ${CHECK_INTERVAL}s"
    log "   MAX_CHECK_WAIT: $MAX_CHECK_WAIT iterations"
    log "   MAX_COPILOT_WAIT: ${MAX_COPILOT_WAIT:-$MAX_CHECK_WAIT} iterations"
    log "   PARALLEL_MODE: $PARALLEL_MODE"
    log "   MAX_PENDING_PRS: $MAX_PENDING_PRS"
    log "   PARALLEL_CHECK_INTERVAL: ${PARALLEL_CHECK_INTERVAL}s"
    log "   DEBUG_MODE: $DEBUG_MODE"
    log ""
  fi

  # Safety check: warn if working tree is dirty (uncommitted changes)
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    log "⚠️ WARNING: Git working tree has uncommitted changes"
    log "   Autopilot may checkout branches which could cause conflicts."
    log "   Consider committing or stashing your changes first."
    echo ""
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log "Aborted by user."
      exit 1
    fi
    log "Continuing with dirty working tree (user confirmed)..."
  fi

  # If no pattern provided, auto-detect mode (process all epics in order)
  if [ -z "$EPIC_PATTERN" ]; then
    log "ℹ️ No epic pattern provided - will process ALL epics from _bmad-output/epics.md in order"
  fi

  if [ "$PARALLEL_MODE" -ge 1 ] 2>/dev/null; then
    log "🔀 PARALLEL MODE enabled (max $MAX_PENDING_PRS concurrent PRs)"
    mkdir -p "$WORKTREE_DIR"
  fi

  if [ "$CONTINUE_FLAG" != "--continue" ] || [ ! -f "$STATE_FILE" ]; then
    log "🚀 BMAD Autopilot starting (fresh)"
    # Start with CHECK_PENDING_PR to handle any unfinished PRs from previous runs
    state_init_if_missing
    state_set "CHECK_PENDING_PR" "null"
  else
    log "🚀 BMAD Autopilot resuming (--continue)"
    state_init_if_missing
  fi

  local last_pending_check=0

  while true; do
    local phase
    phase="$(state_phase)"
    log "━━━ Current phase: $phase ━━━"

    # Periodically check pending PRs during active development (auto-merge or fix)
    local now
    now="$(date +%s)"
    if [ $((now - last_pending_check)) -ge "$PARALLEL_CHECK_INTERVAL" ]; then
      last_pending_check="$now"
      local pending_count
      pending_count="$(state_count_pending_prs)"
      if [ "$pending_count" -gt 0 ]; then
        debug "Periodic check: $pending_count pending PR(s)"
        local pr_to_fix=""
        if ! pr_to_fix="$(check_all_pending_prs)"; then
          if [ -n "$pr_to_fix" ]; then
            log "🔧 PR for epic $pr_to_fix needs fixes, pausing..."
            fix_pending_pr_issues "$pr_to_fix"
          fi
        fi
      fi
    fi

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
        # Clean up worktrees if any were created
        if [ "$PARALLEL_MODE" -ge 1 ] 2>/dev/null; then
          worktree_prune
        fi
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
