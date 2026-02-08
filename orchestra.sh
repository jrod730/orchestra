#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# ORCHESTRA v2.1 — Development Lifecycle Orchestrator
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
# v2.1 Changes:
#   - TRACK-based Phase 4 output (one action per feature track)
#   - Inner loop strictly enforced: dev → review → test per task
#   - No task advances until test=PASSED
#   - Clearer output format prevents orchestrator confusion
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
    local signal_file="$1"
    if [ -f "$signal_file" ]; then
        head -1 "$signal_file" 2>/dev/null | tr -d '[:space:]'
    else
        echo "NONE"
    fi
}

signal_path() {
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
    local task_file="$1"
    if [ -f "$task_file" ]; then
        grep -qiE '##\s*Type:\s*(ui|frontend)' "$task_file" 2>/dev/null && return 0
        grep -qiE '##\s*Has\s*UI:\s*(true|yes)' "$task_file" 2>/dev/null && return 0
        grep -qiE '(ui[_-]?type|has[_-]?ui|ui[_-]?component):\s*(true|yes|ui|frontend)' "$task_file" 2>/dev/null && return 0
        grep -qiE '^\s*-?\s*type:\s*(ui|frontend)' "$task_file" 2>/dev/null && return 0
        grep -qiE '## (UI Tests|Playwright)' "$task_file" 2>/dev/null && return 0
    fi
    return 1
}

is_ui_feature() {
    local feature_file="$1"
    if [ -f "$feature_file" ]; then
        grep -qiE '(has[_-]?ui|ui[_-]?components?|frontend|requires[_-]?ui):\s*(true|yes)' "$feature_file" 2>/dev/null && return 0
        grep -qiE '## UI' "$feature_file" 2>/dev/null && return 0
    fi
    return 1
}

has_integration_tasks() {
    local feature_name="$1"
    local feat_prefix
    feat_prefix=$(echo "$feature_name" | cut -d'-' -f1)

    local feature_file="$ORCHESTRA_DIR/features/${feature_name}.feature.md"
    if [ -f "$feature_file" ]; then
        grep -qiE '(integration[_-]?required|integration required):\s*(true|yes)' "$feature_file" 2>/dev/null && return 0
    fi

    for task in "$ORCHESTRA_DIR/tasks/${feat_prefix}"-*-integration*.task.md; do
        [ -f "$task" ] && return 0
    done

    for task in "$ORCHESTRA_DIR/tasks/${feat_prefix}"-*.task.md; do
        [ -f "$task" ] || continue
        grep -qiE '(integration[_-]?test|integration[_-]?required):\s*(true|yes)' "$task" 2>/dev/null && return 0
    done
    return 1
}

count_iterations() {
    local task_name="$1"
    local count=0
    count=$(ls -1 "$ORCHESTRA_DIR/reviews/${task_name}".review*.md 2>/dev/null | wc -l || echo 0)
    echo "$count"
}

get_feature_prefix() {
    echo "$1" | cut -d'-' -f1
}

get_task_seq() {
    echo "$1" | cut -d'-' -f2
}

is_first_task_in_feature() {
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
    local task_name="$1"
    local feat_prefix
    feat_prefix=$(get_feature_prefix "$task_name")
    local task_seq
    task_seq=$(get_task_seq "$task_name")

    is_first_task_in_feature "$task_name" && return 0

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
    [ "$found_any" = false ] && return 1
    return 0
}

# ─── Init ─────────────────────────────────────────────────────────

cmd_init() {
    log "Initializing Orchestra v2.1 project structure..."

    mkdir -p "$SIGNALS_DIR"/{dev,review,test,integration,planning,feature,task,aar}
    mkdir -p "$ORCHESTRA_DIR"/{specs,features,tasks,reviews,tests,aar,tmp}
    mkdir -p "$PROJECT_ROOT/docs" "$PROJECT_ROOT/src" "$PROJECT_ROOT/tests"
    mkdir -p "$PROJECT_ROOT/tests/e2e"
    mkdir -p "$PROJECT_ROOT/tests/integration"

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
#
# Phase 4 output uses TRACK blocks:
#
#   TRACK:<feature-prefix>
#   ACTION:SPAWN
#   AGENT:<agent-type>           ← developer, code-reviewer, OR tester
#   TARGET:<task-file>
#   TASK_NAME:<task-name>
#   [MODE:<mode>]
#   ---
#   ...more tracks...
#   TRACK_COUNT:<N>
#   PHASE:4-dev-loop
#
# Each track = one feature's CURRENT inner-loop action.
# The orchestrator spawns all tracks, waits, then calls next again.
# ──────────────────────────────────────────────────────────────────

cmd_next() {
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

    # Phase 3: Task Breakdown (SPAWN_BATCH unchanged)
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

    # ══════════════════════════════════════════════════════════════
    # Phase 4: Dev Loop — TRACK-BASED PARALLEL EXECUTION
    #
    # One TRACK per feature. Each track contains exactly ONE action
    # for that feature's current task in the inner loop.
    #
    # INNER LOOP (strictly enforced per task):
    #   dev → review → test → (next task)
    #   rejection → dev fix → cleanup → review → test
    #   test fail → dev fix → cleanup → review → test
    #
    # A task CANNOT advance until test=PASSED.
    # ══════════════════════════════════════════════════════════════

    local track_count=0
    local features_processed=""
    local has_credentials_block=false
    local cred_task="" cred_tname="" cred_details=""

    for task in "$ORCHESTRA_DIR/tasks"/*.task.md; do
        [ -f "$task" ] || continue
        local tname
        tname=$(task_name_from_file "$task")
        local feat_prefix
        feat_prefix=$(get_feature_prefix "$tname")

        # One track per feature — skip if already emitted
        if echo "$features_processed" | grep -q ":${feat_prefix}:"; then
            continue
        fi

        local dev_sig review_sig test_sig
        dev_sig=$(signal_path "dev" "${tname}-complete")
        review_sig=$(signal_path "review" "${tname}-complete")
        test_sig=$(signal_path "test" "${tname}-complete")

        local dev_status review_status test_status
        dev_status=$(read_signal "$dev_sig")
        review_status=$(read_signal "$review_sig")
        test_status=$(read_signal "$test_sig")

        # Task fully done — skip to next task in feature
        [ "$test_status" = "PASSED" ] && continue

        # Previous task not done — skip entire feature
        if ! prev_task_done "$tname"; then
            features_processed="${features_processed}:${feat_prefix}:"
            continue
        fi

        # Lock this feature — no more tasks from it this cycle
        features_processed="${features_processed}:${feat_prefix}:"

        # ── Credential block ──
        if [ -f "$SIGNALS_DIR/need-credentials-${tname}.signal" ]; then
            has_credentials_block=true
            cred_task="$task"
            cred_tname="$tname"
            cred_details="$(cat "$SIGNALS_DIR/need-credentials-${tname}.signal")"
            continue
        fi

        # ── Escalation check ──
        local iters
        iters=$(count_iterations "$tname")

        # ═══════════════════════════════════════════════════════
        # INNER LOOP STATE MACHINE (one action per task)
        #
        # Signal states → action:
        #   dev=NONE                    → SPAWN developer
        #   dev=COMPLETE, review=NONE   → SPAWN code-reviewer
        #   review=REJECTED             → SPAWN developer (review-fix)
        #   review=APPROVED, test=NONE  → SPAWN tester
        #   test=FAILED                 → SPAWN developer (test-fix)
        #   dev=FIXED                   → CLEANUP_THEN_SPAWN code-reviewer
        #   test=PASSED                 → (done, handled above)
        # ═══════════════════════════════════════════════════════

        # dev=FIXED → cleanup stale signals, then re-review
        if [ "$dev_status" = "FIXED" ]; then
            if [ "$iters" -ge 3 ]; then
                echo "ACTION:ESCALATE"
                echo "TASK:$task"
                echo "TASK_NAME:$tname"
                echo "ITERATIONS:$iters"
                echo "REASON:3+ rejection/failure cycles"
                echo "PHASE:4-dev-loop"
                return 0
            fi
            echo "TRACK:${feat_prefix}"
            echo "ACTION:CLEANUP_THEN_SPAWN"
            echo "AGENT:code-reviewer"
            echo "TARGET:$task"
            echo "TASK_NAME:$tname"
            echo "---"
            track_count=$((track_count + 1))
            continue
        fi

        # dev=NONE → spawn developer
        if [ "$dev_status" = "NONE" ]; then
            local agent_type="developer"
            is_ui_task "$task" && agent_type="ui-developer"
            echo "TRACK:${feat_prefix}"
            echo "ACTION:SPAWN"
            echo "AGENT:$agent_type"
            echo "TARGET:$task"
            echo "TASK_NAME:$tname"
            echo "MODE:fresh"
            echo "---"
            track_count=$((track_count + 1))
            continue
        fi

        # dev=COMPLETE, review=NONE → spawn code-reviewer
        if [ "$dev_status" = "COMPLETE" ] && [ "$review_status" = "NONE" ]; then
            echo "TRACK:${feat_prefix}"
            echo "ACTION:SPAWN"
            echo "AGENT:code-reviewer"
            echo "TARGET:$task"
            echo "TASK_NAME:$tname"
            echo "---"
            track_count=$((track_count + 1))
            continue
        fi

        # review=REJECTED → spawn developer in review-fix mode
        if [ "$review_status" = "REJECTED" ]; then
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
            is_ui_task "$task" && agent_type="ui-developer"
            echo "TRACK:${feat_prefix}"
            echo "ACTION:SPAWN"
            echo "AGENT:$agent_type"
            echo "TARGET:$task"
            echo "TASK_NAME:$tname"
            echo "MODE:review-fix"
            echo "---"
            track_count=$((track_count + 1))
            continue
        fi

        # review=APPROVED, test=NONE → spawn tester
        if [ "$review_status" = "APPROVED" ] && [ "$test_status" = "NONE" ]; then
            local agent_type="tester"
            is_ui_task "$task" && agent_type="ui-tester"
            echo "TRACK:${feat_prefix}"
            echo "ACTION:SPAWN"
            echo "AGENT:$agent_type"
            echo "TARGET:$task"
            echo "TASK_NAME:$tname"
            echo "---"
            track_count=$((track_count + 1))
            continue
        fi

        # test=FAILED → spawn developer in test-fix mode
        if [ "$test_status" = "FAILED" ]; then
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
            is_ui_task "$task" && agent_type="ui-developer"
            echo "TRACK:${feat_prefix}"
            echo "ACTION:SPAWN"
            echo "AGENT:$agent_type"
            echo "TARGET:$task"
            echo "TASK_NAME:$tname"
            echo "MODE:test-fix"
            echo "---"
            track_count=$((track_count + 1))
            continue
        fi

    done

    # Emit track footer if we found work
    if [ "$track_count" -gt 0 ]; then
        echo "TRACK_COUNT:$track_count"
        echo "PHASE:4-dev-loop"
        return 0
    fi

    # Credentials blocking with nothing else to do
    if [ "$has_credentials_block" = true ]; then
        echo "ACTION:CREDENTIALS_NEEDED"
        echo "TASK:$cred_task"
        echo "TASK_NAME:$cred_tname"
        echo "DETAILS:$cred_details"
        echo "PHASE:4-dev-loop"
        return 0
    fi

    # Phase 4.5: Integration Testing
    local int_batch_items=()
    local int_batch_count=0
    for feature in "$ORCHESTRA_DIR/features"/*.feature.md; do
        [ -f "$feature" ] || continue
        local fname
        fname=$(feature_name_from_file "$feature")

        local feat_prefix_num
        feat_prefix_num=$(echo "$fname" | cut -d'-' -f1)
        local has_tasks=false
        for t in "$ORCHESTRA_DIR/tasks/${feat_prefix_num}"-*.task.md; do
            [ -f "$t" ] && has_tasks=true && break
        done
        [ "$has_tasks" = false ] && continue

        all_feature_tasks_passed "$fname" || continue
        has_integration_tasks "$fname" || continue

        local int_sig
        int_sig=$(signal_path "integration" "${fname}-complete")
        local int_status
        int_status=$(read_signal "$int_sig")

        if [ "$int_status" = "NONE" ]; then
            int_batch_items+=("$feature|$fname")
            int_batch_count=$((int_batch_count + 1))
        elif [ "$int_status" = "FAILED" ]; then
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

    # Phase 5: AARs
    local aar_batch_items=()
    local aar_batch_count=0
    for feature in "$ORCHESTRA_DIR/features"/*.feature.md; do
        [ -f "$feature" ] || continue
        local fname
        fname=$(feature_name_from_file "$feature")

        all_feature_tasks_passed "$fname" || continue

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

    # Done check
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

    local review_sig
    review_sig=$(signal_path "review" "${task_name}-complete")
    local test_sig
    test_sig=$(signal_path "test" "${task_name}-complete")

    [ -f "$review_sig" ] && rm -f "$review_sig" && log "  Removed review signal"
    [ -f "$test_sig" ] && rm -f "$test_sig" && log "  Removed test signal"

    local dev_sig
    dev_sig=$(signal_path "dev" "${task_name}-complete")
    if [ -f "$dev_sig" ]; then
        local first_line
        first_line=$(head -1 "$dev_sig")
        if [ "$(echo "$first_line" | tr -d '[:space:]')" = "FIXED" ]; then
            local rest
            rest=$(tail -n +2 "$dev_sig")
            echo "COMPLETE" > "$dev_sig"
            [ -n "$rest" ] && echo "$rest" >> "$dev_sig"
            log "  Reset dev signal: FIXED → COMPLETE"
        fi
    fi

    [ -f "$SIGNALS_DIR/need-credentials-${task_name}.signal" ] && rm -f "$SIGNALS_DIR/need-credentials-${task_name}.signal"

    success "Cleanup complete for $task_name"
}

# ─── Spawn Agent ──────────────────────────────────────────────────
# Builds a COMPLETE prompt with all relevant project context injected.
# Each sub-agent receives everything it needs to do its job without
# having to read files itself. This keeps agents focused and ensures
# they have full project awareness.
#
# Context injected per agent type:
#   ALL agents:          constitution, project structure summary
#   planning:            docs/ contents
#   feature:             constitution, all spec files
#   task-builder:        constitution, feature file, referenced specs
#   developer:           constitution, spec, feature, task, prior reviews/tests
#   ui-developer:        same as developer
#   code-reviewer:       constitution, spec, feature, task, prior reviews
#   tester:              constitution, spec, feature, task, review report
#   integration-tester:  constitution, feature, all task files for feature
#   task-reviewer:       constitution, feature, all tasks/reviews/tests for feature
#   single-feature-planner: constitution (if exists), feature description

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

    # Read the agent prompt template
    local agent_prompt
    agent_prompt=$(cat "$prompt_file")

    # Do variable substitution
    [ -n "$target" ] && agent_prompt=$(echo "$agent_prompt" | sed "s|{FEATURE_FILE}|$target|g; s|{TASK_FILE}|$target|g")
    [ -n "$task_name" ] && agent_prompt=$(echo "$agent_prompt" | sed "s|{TASK_NAME}|$task_name|g")
    [ -n "$feature_name" ] && agent_prompt=$(echo "$agent_prompt" | sed "s|{FEATURE_NAME}|$feature_name|g")
    agent_prompt=$(echo "$agent_prompt" | sed "s|{SIGNALS_DIR}|$SIGNALS_DIR|g")
    agent_prompt=$(echo "$agent_prompt" | sed "s|{ORCHESTRA_DIR}|$ORCHESTRA_DIR|g")

    # ── Build context package ──
    local context=""

    # Helper: safely read a file into context with a header
    inject_file() {
        local label="$1"
        local filepath="$2"
        if [ -f "$filepath" ]; then
            context+="
━━━ ${label} ━━━
$(cat "$filepath")
"
        fi
    }

    # Helper: inject all files matching a glob with headers
    inject_glob() {
        local label_prefix="$1"
        local glob_pattern="$2"
        for f in $glob_pattern; do
            [ -f "$f" ] || continue
            local fname
            fname=$(basename "$f")
            context+="
━━━ ${label_prefix}: ${fname} ━━━
$(cat "$f")
"
        done
    }

    # Helper: get the feature file for a task (by feature prefix)
    get_feature_file_for_task() {
        local tname="$1"
        local fprefix
        fprefix=$(get_feature_prefix "$tname")
        for ff in "$ORCHESTRA_DIR/features/${fprefix}"-*.feature.md; do
            [ -f "$ff" ] && echo "$ff" && return
        done
    }

    # Helper: get spec files referenced by a feature file
    get_specs_for_feature() {
        local feature_file="$1"
        [ -f "$feature_file" ] || return
        # Look for "Specs Referenced" section or spec file mentions
        grep -oE '[a-zA-Z0-9_-]+\.spec\.md' "$feature_file" 2>/dev/null | sort -u | while read -r spec_name; do
            local spec_path="$ORCHESTRA_DIR/specs/$spec_name"
            [ -f "$spec_path" ] && echo "$spec_path"
        done
        # Also check for spec references without .spec.md extension
        grep -oE 'specs/[a-zA-Z0-9_-]+' "$feature_file" 2>/dev/null | sort -u | while read -r spec_ref; do
            local spec_path="$ORCHESTRA_DIR/${spec_ref}.spec.md"
            [ -f "$spec_path" ] && echo "$spec_path"
        done
    }

    context="
╔══════════════════════════════════════════════════════════════╗
║  INJECTED PROJECT CONTEXT — DO NOT SKIP, READ EVERYTHING    ║
║  This is your complete project knowledge. You do NOT need   ║
║  to read these files yourself — they are already here.      ║
╚══════════════════════════════════════════════════════════════╝
"

    # ── Constitution (ALL agents except planning on first run) ──
    inject_file "CONSTITUTION (Coding Standards & Patterns)" "$ORCHESTRA_DIR/constitution.md"

    # ── Agent-specific context ──
    case "$agent_type" in

        planning)
            # Planning agent needs all docs
            context+="
━━━ PROJECT DOCUMENTATION ━━━
"
            for doc in "$PROJECT_ROOT/docs"/*; do
                [ -f "$doc" ] || continue
                local docname
                docname=$(basename "$doc")
                context+="
── doc: ${docname} ──
$(cat "$doc")
"
            done

            # Include existing project structure scan
            context+="
━━━ EXISTING PROJECT STRUCTURE ━━━
$(find "$PROJECT_ROOT" -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.cs" -o -name "*.java" -o -name "*.go" -o -name "*.rs" \) \
    ! -path "*/node_modules/*" ! -path "*/.orchestra/*" ! -path "*/dist/*" ! -path "*/build/*" | head -80 2>/dev/null || echo "(no source files found)")
"
            ;;

        feature)
            # Feature agent needs all specs
            inject_glob "SPEC FILE" "$ORCHESTRA_DIR/specs/*.spec.md"
            ;;

        single-feature-planner)
            # Needs the feature description + existing code scan
            inject_file "FEATURE DESCRIPTION (YOUR ENTIRE SCOPE)" "$ORCHESTRA_DIR/tmp/feature-description.md"

            context+="
━━━ EXISTING PROJECT STRUCTURE ━━━
$(find "$PROJECT_ROOT" -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.cs" -o -name "*.java" -o -name "*.go" -o -name "*.rs" \) \
    ! -path "*/node_modules/*" ! -path "*/.orchestra/*" ! -path "*/dist/*" ! -path "*/build/*" | head -80 2>/dev/null || echo "(no source files found)")
"
            # Include a few key existing files for pattern detection
            for src in $(find "$PROJECT_ROOT" -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.py" -o -name "*.cs" \) \
                ! -path "*/node_modules/*" ! -path "*/.orchestra/*" ! -path "*/dist/*" ! -path "*/build/*" | head -5 2>/dev/null); do
                inject_file "EXISTING SOURCE (for pattern reference): $(basename "$src")" "$src"
            done
            ;;

        task-builder)
            # Needs the feature file and referenced specs
            if [ -n "$target" ] && [ -f "$target" ]; then
                inject_file "FEATURE FILE (your target)" "$target"

                # Inject referenced specs
                while IFS= read -r spec_path; do
                    [ -n "$spec_path" ] && inject_file "REFERENCED SPEC: $(basename "$spec_path")" "$spec_path"
                done < <(get_specs_for_feature "$target")
            fi

            # Also inject all specs if there aren't many
            local spec_count
            spec_count=$(ls -1 "$ORCHESTRA_DIR/specs"/*.spec.md 2>/dev/null | wc -l || echo 0)
            if [ "$spec_count" -le 5 ]; then
                inject_glob "SPEC FILE" "$ORCHESTRA_DIR/specs/*.spec.md"
            fi

            # Project structure for realistic file paths
            context+="
━━━ EXISTING PROJECT STRUCTURE ━━━
$(find "$PROJECT_ROOT" -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.cs" \) \
    ! -path "*/node_modules/*" ! -path "*/.orchestra/*" ! -path "*/dist/*" ! -path "*/build/*" | head -60 2>/dev/null || echo "(no source files found)")
"
            ;;

        developer|ui-developer)
            # Needs: spec, feature, task, prior reviews, prior test reports
            if [ -n "$task_name" ]; then
                # Inject the task file
                inject_file "YOUR TASK (implement this)" "$target"

                # Find and inject the parent feature file
                local feat_file
                feat_file=$(get_feature_file_for_task "$task_name")
                inject_file "PARENT FEATURE" "$feat_file"

                # Inject referenced specs from the feature
                if [ -n "$feat_file" ]; then
                    while IFS= read -r spec_path; do
                        [ -n "$spec_path" ] && inject_file "REFERENCED SPEC: $(basename "$spec_path")" "$spec_path"
                    done < <(get_specs_for_feature "$feat_file")
                fi

                # Also inject all specs if few
                local spec_count
                spec_count=$(ls -1 "$ORCHESTRA_DIR/specs"/*.spec.md 2>/dev/null | wc -l || echo 0)
                if [ "$spec_count" -le 5 ]; then
                    inject_glob "SPEC FILE" "$ORCHESTRA_DIR/specs/*.spec.md"
                fi

                # Prior review (if review-fix mode)
                inject_file "CODE REVIEW (fix these issues)" "$ORCHESTRA_DIR/reviews/${task_name}.review.md"

                # Prior review iterations
                inject_glob "PRIOR REVIEW ITERATION" "$ORCHESTRA_DIR/reviews/${task_name}.review-iter*.md"

                # Prior test report (if test-fix mode)
                inject_file "TEST REPORT (fix these failures)" "$ORCHESTRA_DIR/tests/${task_name}.test-report.md"

                # Work completed by prior tasks in this feature (for context)
                local feat_prefix
                feat_prefix=$(get_feature_prefix "$task_name")
                local task_seq
                task_seq=$(get_task_seq "$task_name")

                context+="
━━━ PRIOR COMPLETED TASKS IN THIS FEATURE ━━━
"
                for prior_task in "$ORCHESTRA_DIR/tasks/${feat_prefix}"-*.task.md; do
                    [ -f "$prior_task" ] || continue
                    local prior_name
                    prior_name=$(task_name_from_file "$prior_task")
                    local prior_seq
                    prior_seq=$(get_task_seq "$prior_name")
                    # Only include tasks that come before this one
                    if [ "$prior_seq" \< "$task_seq" ]; then
                        local prior_test_sig
                        prior_test_sig=$(signal_path "test" "${prior_name}-complete")
                        local prior_status
                        prior_status=$(read_signal "$prior_test_sig")
                        context+="
── Prior Task: ${prior_name} (status: ${prior_status}) ──
$(cat "$prior_task")
"
                    fi
                done
            fi
            ;;

        code-reviewer)
            # Needs: constitution, spec, feature, task, prior reviews
            if [ -n "$task_name" ]; then
                inject_file "TASK UNDER REVIEW" "$target"

                local feat_file
                feat_file=$(get_feature_file_for_task "$task_name")
                inject_file "PARENT FEATURE" "$feat_file"

                if [ -n "$feat_file" ]; then
                    while IFS= read -r spec_path; do
                        [ -n "$spec_path" ] && inject_file "REFERENCED SPEC: $(basename "$spec_path")" "$spec_path"
                    done < <(get_specs_for_feature "$feat_file")
                fi

                local spec_count
                spec_count=$(ls -1 "$ORCHESTRA_DIR/specs"/*.spec.md 2>/dev/null | wc -l || echo 0)
                if [ "$spec_count" -le 5 ]; then
                    inject_glob "SPEC FILE" "$ORCHESTRA_DIR/specs/*.spec.md"
                fi

                # Prior review iterations (so reviewer knows what was already flagged)
                inject_glob "PRIOR REVIEW ITERATION" "$ORCHESTRA_DIR/reviews/${task_name}.review-iter*.md"
                inject_file "MOST RECENT REVIEW" "$ORCHESTRA_DIR/reviews/${task_name}.review.md"
            fi
            ;;

        tester|ui-tester)
            # Needs: constitution, spec, feature, task, review report
            if [ -n "$task_name" ]; then
                inject_file "TASK UNDER TEST" "$target"

                local feat_file
                feat_file=$(get_feature_file_for_task "$task_name")
                inject_file "PARENT FEATURE" "$feat_file"

                if [ -n "$feat_file" ]; then
                    while IFS= read -r spec_path; do
                        [ -n "$spec_path" ] && inject_file "REFERENCED SPEC: $(basename "$spec_path")" "$spec_path"
                    done < <(get_specs_for_feature "$feat_file")
                fi

                local spec_count
                spec_count=$(ls -1 "$ORCHESTRA_DIR/specs"/*.spec.md 2>/dev/null | wc -l || echo 0)
                if [ "$spec_count" -le 5 ]; then
                    inject_glob "SPEC FILE" "$ORCHESTRA_DIR/specs/*.spec.md"
                fi

                # The review that approved this for testing
                inject_file "CODE REVIEW (approved)" "$ORCHESTRA_DIR/reviews/${task_name}.review.md"

                # Prior test reports (if re-testing after fix)
                inject_glob "PRIOR TEST REPORT" "$ORCHESTRA_DIR/tests/${task_name}.test-report*.md"
            fi
            ;;

        integration-tester)
            # Needs: feature, all tasks for feature, all specs
            if [ -n "$feature_name" ]; then
                inject_file "FEATURE UNDER INTEGRATION TEST" "$target"

                local feat_prefix
                feat_prefix=$(echo "$feature_name" | cut -d'-' -f1)

                inject_glob "TASK IN THIS FEATURE" "$ORCHESTRA_DIR/tasks/${feat_prefix}-*.task.md"
                inject_glob "SPEC FILE" "$ORCHESTRA_DIR/specs/*.spec.md"

                # Include all test reports for this feature's tasks
                for task in "$ORCHESTRA_DIR/tasks/${feat_prefix}"-*.task.md; do
                    [ -f "$task" ] || continue
                    local tname
                    tname=$(task_name_from_file "$task")
                    inject_file "TEST REPORT: ${tname}" "$ORCHESTRA_DIR/tests/${tname}.test-report.md"
                done
            fi
            ;;

        task-reviewer)
            # Needs: feature, all tasks, all reviews, all test reports
            if [ -n "$feature_name" ]; then
                inject_file "FEATURE FOR AAR" "$target"

                local feat_prefix
                feat_prefix=$(echo "$feature_name" | cut -d'-' -f1)

                inject_glob "TASK" "$ORCHESTRA_DIR/tasks/${feat_prefix}-*.task.md"
                inject_glob "CODE REVIEW" "$ORCHESTRA_DIR/reviews/${feat_prefix}-*.review*.md"
                inject_glob "TEST REPORT" "$ORCHESTRA_DIR/tests/${feat_prefix}-*.test-report*.md"

                # Integration test report if exists
                inject_file "INTEGRATION TEST REPORT" "$ORCHESTRA_DIR/tests/${feature_name}.integration-report.md"
            fi
            ;;

    esac

    # ── Assemble final prompt ──
    mkdir -p "$ORCHESTRA_DIR/tmp"
    local tmp_file="$ORCHESTRA_DIR/tmp/${agent_type}-${task_name:-${feature_name:-run}}-$$.md"

    # Context FIRST, then agent instructions
    {
        echo "$context"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  END OF CONTEXT — YOUR INSTRUCTIONS BEGIN BELOW"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "$agent_prompt"
    } > "$tmp_file"

    echo "PROMPT_FILE:$tmp_file"
}

# ─── Status ───────────────────────────────────────────────────────

cmd_status() {
    echo ""
    echo -e "${BOLD}═══ ORCHESTRA v2.1 STATUS ═══${NC}"
    echo ""

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

            if [ -f "$dev_sig" ]; then
                tail -n +2 "$dev_sig" 2>/dev/null | while IFS= read -r line; do
                    [ -n "$line" ] && echo -e "    ${CYAN}$line${NC}"
                done
            fi
        done
    fi

    echo ""

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
═══ ORCHESTRA v2.1 ═══
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

Phase 4 Output Format (TRACK-based):
  TRACK:<feature-prefix>
  ACTION:SPAWN
  AGENT:<agent-type>        ← developer, code-reviewer, OR tester
  TARGET:<task-file>
  TASK_NAME:<task-name>
  [MODE:<mode>]
  ---
  TRACK_COUNT:<N>
  PHASE:4-dev-loop

Inner Loop (strictly enforced per task):
  dev → review → test → next task
  A task CANNOT advance until test=PASSED.

Parallelism:
  Within feature:   SEQUENTIAL (task N+1 waits for N)
  Across features:  PARALLEL (via TRACK blocks)
  Dev→Review→Test:  SEQUENTIAL per task
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