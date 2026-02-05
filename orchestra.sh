#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# ORCHESTRA v2.0 — Development Lifecycle Orchestrator
#
# This script IS the brain. The Claude Code orchestrator just runs
# this script and acts on the output. That's it.
#
# Usage:
#   ./orchestra.sh init                    # First time setup
#   ./orchestra.sh next                    # What should I do next?
#   ./orchestra.sh status                  # Full status report
#   ./orchestra.sh cleanup <task>          # Clean stale signals after FIXED
#   ./orchestra.sh spawn <agent> [target] [task_name] [feature_name]
#   ./orchestra.sh clear                   # Reset all signals
#   ./orchestra.sh help                    # Show commands
#
# v2.0 Changes:
#   - Per-type signal directories (dev/, review/, test/, etc.)
#   - Integration testing in planning + dev loop
#   - UI feature detection and UI dev agent support
#   - Single feature builder mode (feature description → full pipeline)
#   - Multi feature builder mode (kicks off planning only)
#   - Playwright-based UI testing
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-.}"
ORCHESTRA_DIR="$PROJECT_ROOT/.orchestra"
SIGNALS_DIR="$ORCHESTRA_DIR/signals"
AGENTS_DIR="$PROJECT_ROOT/agents"

# ─── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${BLUE}[ORCHESTRA]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; }

# ─── Helpers ──────────────────────────────────────────────────────

read_signal() {
    # Reads the FIRST LINE of a signal file (status word)
    # Metadata on subsequent lines is preserved but not returned here
    local signal_file="$1"
    if [ -f "$signal_file" ]; then
        head -1 "$signal_file" 2>/dev/null | tr -d '[:space:]'
    else
        echo "NONE"
    fi
}

signal_path() {
    # Returns the full path for a signal given type and name
    # Signal types: dev, review, test, integration, planning, feature, task, aar
    local sig_type="$1"
    local sig_name="$2"
    echo "$SIGNALS_DIR/$sig_type/${sig_name}.signal"
}

task_name_from_file() {
    basename "$1" .task.md
}

feature_name_from_file() {
    basename "$1" .feature.md
}

is_ui_task() {
    # Check if a task file contains UI-related markers
    local task_file="$1"
    if [ -f "$task_file" ]; then
        # Check for explicit type markers
        grep -qiE '##\s*Type:\s*(ui|frontend)' "$task_file" 2>/dev/null && return 0
        grep -qiE '##\s*Has\s*UI:\s*(true|yes)' "$task_file" 2>/dev/null && return 0
        # Check for various key-value patterns
        grep -qiE '(ui[_-]?type|has[_-]?ui|ui[_-]?component):\s*(true|yes|ui|frontend)' "$task_file" 2>/dev/null && return 0
        grep -qiE '^\s*-?\s*type:\s*(ui|frontend)' "$task_file" 2>/dev/null && return 0
        # Check for Playwright section
        grep -qiE '## (UI Tests|Playwright)' "$task_file" 2>/dev/null && return 0
    fi
    return 1
}

is_ui_feature() {
    # Check if a feature file contains UI-related markers
    local feature_file="$1"
    if [ -f "$feature_file" ]; then
        grep -qiE '(has[_-]?ui|ui[_-]?components?|frontend|requires[_-]?ui):\s*(true|yes)' "$feature_file" 2>/dev/null && return 0
        grep -qiE '## UI' "$feature_file" 2>/dev/null && return 0
    fi
    return 1
}

has_integration_tasks() {
    # Check if a feature requires integration testing
    local feature_name="$1"
    local feat_prefix
    feat_prefix=$(echo "$feature_name" | cut -d'-' -f1)

    # Check the feature file itself for integration flags
    local feature_file="$ORCHESTRA_DIR/features/${feature_name}.feature.md"
    if [ -f "$feature_file" ]; then
        grep -qiE '(integration[_-]?required|integration required):\s*(true|yes)' "$feature_file" 2>/dev/null && return 0
    fi

    # Check for dedicated integration task files
    for task in "$ORCHESTRA_DIR/tasks/${feat_prefix}"-*-integration*.task.md; do
        [ -f "$task" ] && return 0
    done

    # Check if any task in this feature has integration test markers
    for task in "$ORCHESTRA_DIR/tasks/${feat_prefix}"-*.task.md; do
        [ -f "$task" ] || continue
        grep -qiE '(integration[_-]?test|integration[_-]?required):\s*(true|yes)' "$task" 2>/dev/null && return 0
    done
    return 1
}

count_iterations() {
    local task_name="$1"
    local count=0
    count=$(ls -1 "$ORCHESTRA_DIR/reviews/${task_name}".review*.md 2>/dev/null | wc -l)
    echo "$count"
}

get_feature_prefix() {
    # Extract feature prefix from task name (e.g., "01" from "01-02-login")
    echo "$1" | cut -d'-' -f1
}

get_task_seq() {
    # Extract task sequence from task name (e.g., "02" from "01-02-login")
    echo "$1" | cut -d'-' -f2
}

is_first_task_in_feature() {
    # Returns 0 if this is the first (lowest sequence) task in its feature
    local task_name="$1"
    local feat_prefix
    feat_prefix=$(get_feature_prefix "$task_name")
    local task_seq
    task_seq=$(get_task_seq "$task_name")

    for t in "$ORCHESTRA_DIR/tasks/${feat_prefix}"-*.task.md; do
        [ -f "$t" ] || continue
        local other_name
        other_name=$(task_name_from_file "$t")
        local other_seq
        other_seq=$(get_task_seq "$other_name")
        if [ "$other_seq" \< "$task_seq" ]; then
            return 1
        fi
    done
    return 0
}

prev_task_done() {
    # Check if the previous task in this feature's sequence is PASSED
    local task_name="$1"
    local feat_prefix
    feat_prefix=$(get_feature_prefix "$task_name")
    local task_seq
    task_seq=$(get_task_seq "$task_name")

    # If first task, no predecessor needed
    is_first_task_in_feature "$task_name" && return 0

    # Find the task with sequence just before ours
    local prev_seq=""
    for t in "$ORCHESTRA_DIR/tasks/${feat_prefix}"-*.task.md; do
        [ -f "$t" ] || continue
        local other_name
        other_name=$(task_name_from_file "$t")
        local other_seq
        other_seq=$(get_task_seq "$other_name")
        if [ "$other_seq" \< "$task_seq" ]; then
            if [ -z "$prev_seq" ] || [ "$other_seq" \> "$prev_seq" ]; then
                prev_seq="$other_seq"
            fi
        fi
    done

    if [ -n "$prev_seq" ]; then
        # Find the actual task file with this sequence
        for t in "$ORCHESTRA_DIR/tasks/${feat_prefix}-${prev_seq}"-*.task.md; do
            [ -f "$t" ] || continue
            local prev_name
            prev_name=$(task_name_from_file "$t")
            local test_sig
            test_sig=$(signal_path "test" "${prev_name}-complete")
            local test_status
            test_status=$(read_signal "$test_sig")
            [ "$test_status" = "PASSED" ] && return 0
            return 1
        done
    fi
    return 0
}

all_feature_tasks_passed() {
    # Check if all tasks in a feature have passed testing
    # Feature name is like "01-auth", tasks are like "01-01-models", "01-02-login"
    # We match on the feature sequence prefix (e.g., "01-")
    local feature_name="$1"
    local feat_prefix
    feat_prefix=$(echo "$feature_name" | cut -d'-' -f1)

    local found_any=false
    for task in "$ORCHESTRA_DIR/tasks/${feat_prefix}"-*.task.md; do
        [ -f "$task" ] || continue
        found_any=true
        local tname
        tname=$(task_name_from_file "$task")
        local test_sig
        test_sig=$(signal_path "test" "${tname}-complete")
        local status
        status=$(read_signal "$test_sig")
        [ "$status" != "PASSED" ] && return 1
    done
    # If no tasks found, feature isn't ready
    [ "$found_any" = false ] && return 1
    return 0
}

# ─── Init ─────────────────────────────────────────────────────────

cmd_init() {
    log "Initializing Orchestra v2.0 project structure..."

    # Per-type signal directories
    mkdir -p "$SIGNALS_DIR"/{dev,review,test,integration,planning,feature,task,aar}
    mkdir -p "$ORCHESTRA_DIR"/{specs,features,tasks,reviews,tests,aar,tmp}
    mkdir -p "$PROJECT_ROOT/docs" "$PROJECT_ROOT/src" "$PROJECT_ROOT/tests"
    mkdir -p "$PROJECT_ROOT/tests/e2e"   # Playwright e2e test directory
    mkdir -p "$PROJECT_ROOT/tests/integration"  # Integration test directory

    if [ ! -d "$AGENTS_DIR" ]; then
        error "agents/ directory not found. Agent prompt files are required."
        echo "Expected: agents/planning-agent.md, agents/feature-agent.md, etc."
        return 1
    fi

    success "Project structure ready"
    echo ""

    if [ -z "$(ls -A "$PROJECT_ROOT/docs/" 2>/dev/null)" ]; then
        warn "docs/ is empty — add your project documentation before starting"
    else
        success "docs/ contains $(ls -1 "$PROJECT_ROOT/docs/" | wc -l) file(s)"
    fi
}

# ─── Next Action (THE BRAIN) ─────────────────────────────────────
# Outputs structured key:value pairs. The orchestrator parses
# these and acts. The orchestrator NEVER thinks — this script
# tells it what to do.
#
# Signal paths now use per-type directories:
#   .orchestra/signals/dev/01-01-login-complete.signal
#   .orchestra/signals/review/01-01-login-complete.signal
#   .orchestra/signals/test/01-01-login-complete.signal
#   .orchestra/signals/integration/01-auth-complete.signal
#   .orchestra/signals/planning/planning-complete.signal
#   .orchestra/signals/feature/features-complete.signal
#   .orchestra/signals/task/tasks-01-auth-complete.signal
#   .orchestra/signals/aar/aar-01-auth-complete.signal
# ──────────────────────────────────────────────────────────────────

cmd_next() {
    # Not initialized?
    if [ ! -d "$ORCHESTRA_DIR" ]; then
        echo "ACTION:INIT"
        return 0
    fi

    # Phase 1: Planning
    local planning_sig
    planning_sig=$(signal_path "planning" "planning-complete")
    if [ "$(read_signal "$planning_sig")" = "NONE" ]; then
        echo "ACTION:SPAWN"
        echo "AGENT:planning"
        echo "PHASE:1-planning"
        return 0
    fi

    # Phase 2: Features
    local features_sig
    features_sig=$(signal_path "feature" "features-complete")
    if [ "$(read_signal "$features_sig")" = "NONE" ]; then
        echo "ACTION:SPAWN"
        echo "AGENT:feature"
        echo "PHASE:2-features"
        return 0
    fi

    # Phase 3: Task Breakdown — batch parallel task builders
    local task_batch_items=()
    local task_batch_count=0
    for feature in "$ORCHESTRA_DIR/features"/*.feature.md; do
        [ -f "$feature" ] || continue
        local fname
        fname=$(feature_name_from_file "$feature")
        local task_sig
        task_sig=$(signal_path "task" "tasks-${fname}-complete")
        if [ "$(read_signal "$task_sig")" = "NONE" ]; then
            task_batch_items+=("$feature|$fname")
            task_batch_count=$((task_batch_count + 1))
        fi
    done

    if [ "$task_batch_count" -eq 1 ]; then
        local item="${task_batch_items[0]}"
        local feat_file="${item%%|*}"
        local feat_name="${item##*|}"
        echo "ACTION:SPAWN"
        echo "AGENT:task-builder"
        echo "TARGET:$feat_file"
        echo "FEATURE_NAME:$feat_name"
        echo "PHASE:3-tasks"
        return 0
    elif [ "$task_batch_count" -gt 1 ]; then
        echo "ACTION:SPAWN_BATCH"
        echo "COUNT:$task_batch_count"
        echo "PHASE:3-tasks"
        local idx=1
        for item in "${task_batch_items[@]}"; do
            local feat_file="${item%%|*}"
            local feat_name="${item##*|}"
            echo "BATCH_ITEM:$idx"
            echo "AGENT:task-builder"
            echo "TARGET:$feat_file"
            echo "FEATURE_NAME:$feat_name"
            idx=$((idx + 1))
        done
        return 0
    fi

    # Phase 4: Dev Loop — parallel across features, sequential within
    local dev_batch_items=()
    local dev_batch_count=0
    local features_with_active_work=()
    local has_credentials_block=false
    local cred_task="" cred_tname="" cred_details=""

    for task in "$ORCHESTRA_DIR/tasks"/*.task.md; do
        [ -f "$task" ] || continue
        local tname
        tname=$(task_name_from_file "$task")
        local feat_prefix
        feat_prefix=$(get_feature_prefix "$tname")

        local dev_sig review_sig test_sig
        dev_sig=$(signal_path "dev" "${tname}-complete")
        review_sig=$(signal_path "review" "${tname}-complete")
        test_sig=$(signal_path "test" "${tname}-complete")

        local dev_status review_status test_status
        dev_status=$(read_signal "$dev_sig")
        review_status=$(read_signal "$review_sig")
        test_status=$(read_signal "$test_sig")

        # Task done
        [ "$test_status" = "PASSED" ] && continue

        # Already working on a task in this feature? Skip (sequential within feature)
        local already_active=false
        for active_feat in "${features_with_active_work[@]+"${features_with_active_work[@]}"}"; do
            [ "$active_feat" = "$feat_prefix" ] && already_active=true && break
        done
        [ "$already_active" = true ] && continue

        # Previous task in feature not done? Skip
        prev_task_done "$tname" || continue

        # Credential request blocking
        if [ -f "$SIGNALS_DIR/need-credentials-${tname}.signal" ]; then
            has_credentials_block=true
            cred_task="$task"
            cred_tname="$tname"
            cred_details="$(cat "$SIGNALS_DIR/need-credentials-${tname}.signal")"
            features_with_active_work+=("$feat_prefix")
            continue
        fi

        # Developer wrote FIXED → cleanup then re-review
        if [ "$dev_status" = "FIXED" ]; then
            # Check iteration count for escalation
            local iters
            iters=$(count_iterations "$tname")
            if [ "$iters" -ge 3 ]; then
                echo "ACTION:ESCALATE"
                echo "TASK:$task"
                echo "TASK_NAME:$tname"
                echo "ITERATIONS:$iters"
                echo "REASON:3+ rejection/failure cycles"
                echo "PHASE:4-dev-loop"
                return 0
            fi
            echo "ACTION:CLEANUP_THEN_SPAWN"
            echo "AGENT:code-reviewer"
            echo "TARGET:$task"
            echo "TASK_NAME:$tname"
            echo "PHASE:4-dev-loop"
            return 0
        fi

        # No dev signal → spawn developer (or UI dev if UI task)
        if [ "$dev_status" = "NONE" ]; then
            local agent_type="developer"
            if is_ui_task "$task"; then
                agent_type="ui-developer"
            fi
            dev_batch_items+=("$task|$tname|$agent_type")
            dev_batch_count=$((dev_batch_count + 1))
            features_with_active_work+=("$feat_prefix")
            continue
        fi

        # Dev complete, no review → spawn reviewer
        if [ "$dev_status" = "COMPLETE" ] && [ "$review_status" = "NONE" ]; then
            dev_batch_items+=("$task|$tname|code-reviewer")
            dev_batch_count=$((dev_batch_count + 1))
            features_with_active_work+=("$feat_prefix")
            continue
        fi

        # Reviewed REJECTED → spawn developer in review-fix mode
        if [ "$review_status" = "REJECTED" ]; then
            local iters
            iters=$(count_iterations "$tname")
            if [ "$iters" -ge 3 ]; then
                echo "ACTION:ESCALATE"
                echo "TASK:$task"
                echo "TASK_NAME:$tname"
                echo "ITERATIONS:$iters"
                echo "REASON:3+ review rejections"
                echo "PHASE:4-dev-loop"
                return 0
            fi
            local agent_type="developer"
            if is_ui_task "$task"; then
                agent_type="ui-developer"
            fi
            dev_batch_items+=("$task|$tname|${agent_type}|review-fix")
            dev_batch_count=$((dev_batch_count + 1))
            features_with_active_work+=("$feat_prefix")
            continue
        fi

        # Reviewed APPROVED, no test → spawn tester (UI tester if UI task)
        if [ "$review_status" = "APPROVED" ] && [ "$test_status" = "NONE" ]; then
            local agent_type="tester"
            if is_ui_task "$task"; then
                agent_type="ui-tester"
            fi
            dev_batch_items+=("$task|$tname|${agent_type}")
            dev_batch_count=$((dev_batch_count + 1))
            features_with_active_work+=("$feat_prefix")
            continue
        fi

        # Test FAILED → spawn developer in test-fix mode
        if [ "$test_status" = "FAILED" ]; then
            local iters
            iters=$(count_iterations "$tname")
            if [ "$iters" -ge 3 ]; then
                echo "ACTION:ESCALATE"
                echo "TASK:$task"
                echo "TASK_NAME:$tname"
                echo "ITERATIONS:$iters"
                echo "REASON:3+ test failures"
                echo "PHASE:4-dev-loop"
                return 0
            fi
            local agent_type="developer"
            if is_ui_task "$task"; then
                agent_type="ui-developer"
            fi
            dev_batch_items+=("$task|$tname|${agent_type}|test-fix")
            dev_batch_count=$((dev_batch_count + 1))
            features_with_active_work+=("$feat_prefix")
            continue
        fi

        # Mark feature as having active work (in-progress states)
        features_with_active_work+=("$feat_prefix")
    done

    # Emit dev loop batch
    if [ "$dev_batch_count" -eq 1 ]; then
        local item="${dev_batch_items[0]}"
        IFS='|' read -r d_task d_tname d_agent d_mode <<< "$item"
        echo "ACTION:SPAWN"
        echo "AGENT:$d_agent"
        echo "TARGET:$d_task"
        echo "TASK_NAME:$d_tname"
        [ -n "${d_mode:-}" ] && echo "MODE:$d_mode"
        echo "PHASE:4-dev-loop"
        return 0
    elif [ "$dev_batch_count" -gt 1 ]; then
        echo "ACTION:SPAWN_BATCH"
        echo "COUNT:$dev_batch_count"
        echo "PHASE:4-dev-loop"
        local idx=1
        for item in "${dev_batch_items[@]}"; do
            IFS='|' read -r d_task d_tname d_agent d_mode <<< "$item"
            echo "BATCH_ITEM:$idx"
            echo "AGENT:$d_agent"
            echo "TARGET:$d_task"
            echo "TASK_NAME:$d_tname"
            [ -n "${d_mode:-}" ] && echo "MODE:$d_mode"
            idx=$((idx + 1))
        done
        return 0
    fi

    # If we had a credentials block and nothing else actionable, surface it
    if [ "$has_credentials_block" = true ] && [ "$dev_batch_count" -eq 0 ]; then
        echo "ACTION:CREDENTIALS_NEEDED"
        echo "TASK:$cred_task"
        echo "TASK_NAME:$cred_tname"
        echo "DETAILS:$cred_details"
        echo "PHASE:4-dev-loop"
        return 0
    fi

    # Phase 4.5: Integration Testing (per feature, after all tasks pass)
    local int_batch_items=()
    local int_batch_count=0
    for feature in "$ORCHESTRA_DIR/features"/*.feature.md; do
        [ -f "$feature" ] || continue
        local fname
        fname=$(feature_name_from_file "$feature")

        # Skip if no tasks for this feature
        local feat_prefix_num
        feat_prefix_num=$(echo "$fname" | cut -d'-' -f1)
        local has_tasks=false
        for t in "$ORCHESTRA_DIR/tasks/${feat_prefix_num}"-*.task.md; do
            [ -f "$t" ] && has_tasks=true && break
        done
        [ "$has_tasks" = false ] && continue

        # Skip if not all tasks passed
        all_feature_tasks_passed "$fname" || continue

        # Skip if integration not applicable for this feature
        has_integration_tasks "$fname" || continue

        # Check integration signal
        local int_sig
        int_sig=$(signal_path "integration" "${fname}-complete")
        local int_status
        int_status=$(read_signal "$int_sig")

        if [ "$int_status" = "NONE" ]; then
            int_batch_items+=("$feature|$fname")
            int_batch_count=$((int_batch_count + 1))
        elif [ "$int_status" = "FAILED" ]; then
            # Integration failed → spawn developer to fix
            echo "ACTION:SPAWN"
            echo "AGENT:developer"
            echo "TARGET:$feature"
            echo "FEATURE_NAME:$fname"
            echo "MODE:integration-fix"
            echo "PHASE:4.5-integration"
            return 0
        fi
    done

    if [ "$int_batch_count" -eq 1 ]; then
        local item="${int_batch_items[0]}"
        local feat_file="${item%%|*}"
        local feat_name="${item##*|}"
        echo "ACTION:SPAWN"
        echo "AGENT:integration-tester"
        echo "TARGET:$feat_file"
        echo "FEATURE_NAME:$feat_name"
        echo "PHASE:4.5-integration"
        return 0
    elif [ "$int_batch_count" -gt 1 ]; then
        echo "ACTION:SPAWN_BATCH"
        echo "COUNT:$int_batch_count"
        echo "PHASE:4.5-integration"
        local idx=1
        for item in "${int_batch_items[@]}"; do
            local feat_file="${item%%|*}"
            local feat_name="${item##*|}"
            echo "BATCH_ITEM:$idx"
            echo "AGENT:integration-tester"
            echo "TARGET:$feat_file"
            echo "FEATURE_NAME:$feat_name"
            idx=$((idx + 1))
        done
        return 0
    fi

    # Phase 5: After Action Reports
    local aar_batch_items=()
    local aar_batch_count=0
    for feature in "$ORCHESTRA_DIR/features"/*.feature.md; do
        [ -f "$feature" ] || continue
        local fname
        fname=$(feature_name_from_file "$feature")

        all_feature_tasks_passed "$fname" || continue

        # If integration was required, check it passed too
        if has_integration_tasks "$fname"; then
            local int_sig
            int_sig=$(signal_path "integration" "${fname}-complete")
            [ "$(read_signal "$int_sig")" != "PASSED" ] && continue
        fi

        local aar_sig
        aar_sig=$(signal_path "aar" "aar-${fname}-complete")
        if [ "$(read_signal "$aar_sig")" = "NONE" ]; then
            aar_batch_items+=("$feature|$fname")
            aar_batch_count=$((aar_batch_count + 1))
        fi
    done

    if [ "$aar_batch_count" -eq 1 ]; then
        local item="${aar_batch_items[0]}"
        local feat_file="${item%%|*}"
        local feat_name="${item##*|}"
        echo "ACTION:SPAWN"
        echo "AGENT:task-reviewer"
        echo "TARGET:$feat_file"
        echo "FEATURE_NAME:$feat_name"
        echo "PHASE:5-aar"
        return 0
    elif [ "$aar_batch_count" -gt 1 ]; then
        echo "ACTION:SPAWN_BATCH"
        echo "COUNT:$aar_batch_count"
        echo "PHASE:5-aar"
        local idx=1
        for item in "${aar_batch_items[@]}"; do
            local feat_file="${item%%|*}"
            local feat_name="${item##*|}"
            echo "BATCH_ITEM:$idx"
            echo "AGENT:task-reviewer"
            echo "TARGET:$feat_file"
            echo "FEATURE_NAME:$feat_name"
            idx=$((idx + 1))
        done
        return 0
    fi

    # Check if everything is truly done
    local all_done=true
    for feature in "$ORCHESTRA_DIR/features"/*.feature.md; do
        [ -f "$feature" ] || continue
        local fname
        fname=$(feature_name_from_file "$feature")
        local aar_sig
        aar_sig=$(signal_path "aar" "aar-${fname}-complete")
        [ "$(read_signal "$aar_sig")" = "NONE" ] && all_done=false && break
    done

    if [ "$all_done" = true ]; then
        echo "ACTION:COMPLETE"
        echo "PHASE:done"
    else
        # Something is in progress — nothing actionable right now
        echo "ACTION:WAIT"
        echo "PHASE:4-dev-loop"
        echo "REASON:Agents are running, no new work to dispatch"
    fi
    return 0
}

# ─── Cleanup ──────────────────────────────────────────────────────

cmd_cleanup() {
    local task_name="${1:-}"
    if [ -z "$task_name" ]; then
        error "Usage: ./orchestra.sh cleanup <task_name>"
        return 1
    fi

    log "Cleaning signals for task: $task_name"

    # Remove stale review and test signals
    local review_sig
    review_sig=$(signal_path "review" "${task_name}-complete")
    local test_sig
    test_sig=$(signal_path "test" "${task_name}-complete")

    [ -f "$review_sig" ] && rm -f "$review_sig" && log "  Removed review signal"
    [ -f "$test_sig" ] && rm -f "$test_sig" && log "  Removed test signal"

    # Reset FIXED → COMPLETE in dev signal (preserve metadata)
    local dev_sig
    dev_sig=$(signal_path "dev" "${task_name}-complete")
    if [ -f "$dev_sig" ]; then
        local first_line
        first_line=$(head -1 "$dev_sig")
        if [ "$(echo "$first_line" | tr -d '[:space:]')" = "FIXED" ]; then
            # Replace first line, keep the rest
            local rest
            rest=$(tail -n +2 "$dev_sig")
            echo "COMPLETE" > "$dev_sig"
            [ -n "$rest" ] && echo "$rest" >> "$dev_sig"
            log "  Reset dev signal: FIXED → COMPLETE"
        fi
    fi

    # Remove credential signal if present
    [ -f "$SIGNALS_DIR/need-credentials-${task_name}.signal" ] && rm -f "$SIGNALS_DIR/need-credentials-${task_name}.signal"

    success "Cleanup complete for $task_name"
}

# ─── Spawn Agent ──────────────────────────────────────────────────
# Writes the fully-substituted prompt to a temp file and outputs
# the path. Keeps prompts out of conversation history.

cmd_spawn() {
    local agent_type="${1:-}"
    local target="${2:-}"
    local task_name="${3:-}"
    local feature_name="${4:-}"

    if [ -z "$agent_type" ]; then
        error "Usage: ./orchestra.sh spawn <agent_type> [target] [task_name] [feature_name]"
        return 1
    fi

    local prompt_file="$AGENTS_DIR/${agent_type}-agent.md"

    if [ ! -f "$prompt_file" ]; then
        error "Agent prompt not found: $prompt_file"
        return 1
    fi

    # Read and substitute variables
    local prompt
    prompt=$(cat "$prompt_file")
    [ -n "$target" ] && prompt=$(echo "$prompt" | sed "s|{FEATURE_FILE}|$target|g; s|{TASK_FILE}|$target|g")
    [ -n "$task_name" ] && prompt=$(echo "$prompt" | sed "s|{TASK_NAME}|$task_name|g")
    [ -n "$feature_name" ] && prompt=$(echo "$prompt" | sed "s|{FEATURE_NAME}|$feature_name|g")

    # Substitute signal directory paths (agents need to know the new structure)
    prompt=$(echo "$prompt" | sed "s|{SIGNALS_DIR}|$SIGNALS_DIR|g")
    prompt=$(echo "$prompt" | sed "s|{ORCHESTRA_DIR}|$ORCHESTRA_DIR|g")

    # Write to temp file
    mkdir -p "$ORCHESTRA_DIR/tmp"
    local tmp_file="$ORCHESTRA_DIR/tmp/${agent_type}-${task_name:-${feature_name:-run}}-$$.md"
    echo "$prompt" > "$tmp_file"

    echo "PROMPT_FILE:$tmp_file"
}

# ─── Status ───────────────────────────────────────────────────────

cmd_status() {
    echo ""
    echo -e "${BOLD}═══ ORCHESTRA v2.0 STATUS ═══${NC}"
    echo ""

    # Phase status
    local planning_sig
    planning_sig=$(signal_path "planning" "planning-complete")
    local features_sig
    features_sig=$(signal_path "feature" "features-complete")

    if [ "$(read_signal "$planning_sig")" != "NONE" ]; then
        echo -e "  ${GREEN}✓${NC} Constitution"
    else
        echo -e "  ${YELLOW}○${NC} Constitution (pending)"
    fi

    local spec_count
    spec_count=$(ls -1 "$ORCHESTRA_DIR/specs"/*.spec.md 2>/dev/null | wc -l || echo 0)
    local feature_count
    feature_count=$(ls -1 "$ORCHESTRA_DIR/features"/*.feature.md 2>/dev/null | wc -l || echo 0)
    local task_count
    task_count=$(ls -1 "$ORCHESTRA_DIR/tasks"/*.task.md 2>/dev/null | wc -l || echo 0)

    echo -e "  Specs:${BOLD}$spec_count${NC}  Features:${BOLD}$feature_count${NC}  Tasks:${BOLD}$task_count${NC}"
    echo ""

    # Task table
    if [ "$task_count" -gt 0 ]; then
        printf "  ${BOLD}%-40s %-10s %-12s %-10s${NC}\n" "TASK" "DEV" "REVIEW" "TEST"
        echo -e "  $(printf '─%.0s' {1..72})"

        for task in "$ORCHESTRA_DIR/tasks"/*.task.md; do
            [ -f "$task" ] || continue
            local tname
            tname=$(task_name_from_file "$task")

            local dev_sig review_sig test_sig
            dev_sig=$(signal_path "dev" "${tname}-complete")
            review_sig=$(signal_path "review" "${tname}-complete")
            test_sig=$(signal_path "test" "${tname}-complete")

            local dev_s review_s test_s
            dev_s=$(read_signal "$dev_sig")
            review_s=$(read_signal "$review_sig")
            test_s=$(read_signal "$test_sig")

            # Color coding
            local dev_c review_c test_c
            case "$dev_s" in
                COMPLETE) dev_c="${GREEN}${dev_s}${NC}" ;;
                FIXED)    dev_c="${YELLOW}${dev_s}${NC}" ;;
                NONE)     dev_c="—" ;;
                *)        dev_c="$dev_s" ;;
            esac
            case "$review_s" in
                APPROVED) review_c="${GREEN}${review_s}${NC}" ;;
                REJECTED) review_c="${RED}${review_s}${NC}" ;;
                NONE)     review_c="—" ;;
                *)        review_c="$review_s" ;;
            esac
            case "$test_s" in
                PASSED) test_c="${GREEN}${test_s}${NC}" ;;
                FAILED) test_c="${RED}${test_s}${NC}" ;;
                NONE)   test_c="—" ;;
                *)      test_c="$test_s" ;;
            esac

            local ui_marker=""
            is_ui_task "$task" && ui_marker=" ${PURPLE}[UI]${NC}"

            printf "  %-40s %-10b %-12b %-10b%b\n" "$tname" "$dev_c" "$review_c" "$test_c" "$ui_marker"

            # Show signal metadata
            if [ -f "$dev_sig" ]; then
                tail -n +2 "$dev_sig" 2>/dev/null | while IFS= read -r line; do
                    [ -n "$line" ] && echo -e "    ${CYAN}$line${NC}"
                done
            fi
        done
    fi

    echo ""

    # Integration test status
    local has_any_integration=false
    for feature in "$ORCHESTRA_DIR/features"/*.feature.md; do
        [ -f "$feature" ] || continue
        local fname
        fname=$(feature_name_from_file "$feature")
        if has_integration_tasks "$fname"; then
            if [ "$has_any_integration" = false ]; then
                echo -e "  ${BOLD}INTEGRATION TESTS${NC}"
                has_any_integration=true
            fi
            local int_sig
            int_sig=$(signal_path "integration" "${fname}-complete")
            local int_s
            int_s=$(read_signal "$int_sig")
            case "$int_s" in
                PASSED) echo -e "    ${GREEN}✓${NC} $fname: ${GREEN}PASSED${NC}" ;;
                FAILED) echo -e "    ${RED}✗${NC} $fname: ${RED}FAILED${NC}" ;;
                NONE)   echo -e "    ${YELLOW}○${NC} $fname: pending" ;;
            esac
        fi
    done
    [ "$has_any_integration" = true ] && echo ""

    # AARs
    echo -e "  ${BOLD}AFTER ACTION REPORTS${NC}"
    for feature in "$ORCHESTRA_DIR/features"/*.feature.md; do
        [ -f "$feature" ] || continue
        local fname
        fname=$(feature_name_from_file "$feature")
        local aar_sig
        aar_sig=$(signal_path "aar" "aar-${fname}-complete")
        local aar_s
        aar_s=$(read_signal "$aar_sig")
        case "$aar_s" in
            COMPLETE) echo -e "    ${GREEN}✓${NC} $fname" ;;
            NONE)     echo -e "    ${YELLOW}○${NC} $fname (pending)" ;;
        esac
    done
    echo ""

    # Blockers
    local has_blockers=false
    for signal in "$SIGNALS_DIR"/need-credentials-*.signal; do
        [ -f "$signal" ] || continue
        if [ "$has_blockers" = false ]; then
            echo -e "  ${BOLD}${RED}Blockers:${NC}"
            has_blockers=true
        fi
        echo -e "    ${RED}🔑${NC} $(basename "$signal"): $(head -1 "$signal")"
    done
    [ "$has_blockers" = false ] && echo -e "  ${GREEN}No blockers${NC}"
    echo ""
}

# ─── Clear ────────────────────────────────────────────────────────

cmd_clear() {
    warn "Clearing all signals..."
    find "$SIGNALS_DIR" -name "*.signal" -delete 2>/dev/null
    success "All signals cleared"
}

# ─── Help ─────────────────────────────────────────────────────────

cmd_help() {
    cat << 'EOF'
═══ ORCHESTRA v2.0 ═══
Development Lifecycle Orchestrator

Commands:
  init                          Initialize project structure
  next                          Get next action (THE MAIN COMMAND)
  status                        Full status report
  cleanup <task_name>           Clean stale signals after developer FIXED
  spawn <agent> [target] [task_name] [feature_name]
                                Spawn a sub-agent with variable substitution
  clear                         Reset all signals
  help                          Show this help

Agent Types (for spawn):
  planning, feature, task-builder, developer, ui-developer,
  code-reviewer, tester, ui-tester, integration-tester,
  task-reviewer

Signal Directory Structure:
  .orchestra/signals/
  ├── dev/          # Developer completion signals
  ├── review/       # Code review signals
  ├── test/         # Test result signals
  ├── integration/  # Integration test signals
  ├── planning/     # Planning phase signals
  ├── feature/      # Feature phase signals
  ├── task/         # Task builder signals
  └── aar/          # After action report signals

The 'next' command outputs structured data:
  ACTION:SPAWN|SPAWN_BATCH|CLEANUP_THEN_SPAWN|CREDENTIALS_NEEDED|ESCALATE|COMPLETE|WAIT|INIT
  AGENT:<agent-type>
  TARGET:<file-path>
  TASK_NAME:<n>
  FEATURE_NAME:<n>
  MODE:<review-fix|test-fix|integration-fix>
  PHASE:<current-phase>

Parallelism rules:
  Tasks within a feature:  SEQUENTIAL
  Tasks across features:   PARALLEL
  Dev→Review→Test:         SEQUENTIAL per task
  Task builders:           PARALLEL
  Integration tests:       PARALLEL (per feature)
  AARs:                    PARALLEL
EOF
}

# ─── Main ─────────────────────────────────────────────────────────

case "${1:-help}" in
    init)      cmd_init ;;
    next)      cmd_next ;;
    status)    cmd_status ;;
    cleanup)   cmd_cleanup "${2:-}" ;;
    spawn)     cmd_spawn "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
    clear)     cmd_clear ;;
    help|*)    cmd_help ;;
esac
