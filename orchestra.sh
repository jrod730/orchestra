#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# ORCHESTRA - Development Lifecycle Orchestrator
# 
# This script IS the brain. The Claude Code orchestrator just runs
# this script and acts on the output. That's it.
#
# Usage:
#   ./orchestra.sh init              # First time setup
#   ./orchestra.sh next              # What should I do next?
#   ./orchestra.sh status            # Full status report
#   ./orchestra.sh cleanup <task>    # Clean signals after FIXED
#   ./orchestra.sh spawn <agent> [target] [task_name] [feature_name]
#   ./orchestra.sh clear             # Reset all signals
#   ./orchestra.sh help              # Show commands
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
    local signal_file="$SIGNALS_DIR/$1"
    if [ -f "$signal_file" ]; then
        head -1 "$signal_file" 2>/dev/null | tr -d '[:space:]'
    else
        echo "NONE"
    fi
}

read_signal_details() {
    local signal_file="$SIGNALS_DIR/$1"
    if [ -f "$signal_file" ]; then
        tail -n +2 "$signal_file" 2>/dev/null
    fi
}

task_name_from_file() {
    basename "$1" .task.md
}

feature_name_from_file() {
    basename "$1" .feature.md
}

count_iterations() {
    local task_name="$1"
    local count=0
    count=$(ls -1 "$ORCHESTRA_DIR/reviews/${task_name}".review*.md 2>/dev/null | wc -l)
    echo "$count"
}

# ─── Init ─────────────────────────────────────────────────────────

cmd_init() {
    log "Initializing Orchestra project structure..."
    
    mkdir -p "$ORCHESTRA_DIR"/{specs,features,tasks,reviews,tests,aar,signals,tmp}
    mkdir -p "$PROJECT_ROOT/docs" "$PROJECT_ROOT/src" "$PROJECT_ROOT/tests"
    
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
# This outputs structured key:value pairs. The orchestrator parses
# these and acts. The orchestrator NEVER needs to think about what
# to do — this script tells it.
# ──────────────────────────────────────────────────────────────────

cmd_next() {
    # Not initialized?
    if [ ! -d "$ORCHESTRA_DIR" ]; then
        echo "ACTION:INIT"
        return 0
    fi

    # Phase 1: Planning (single agent, must complete before anything)
    if [ "$(read_signal planning-complete.signal)" = "NONE" ]; then
        echo "ACTION:SPAWN"
        echo "AGENT:planning"
        echo "PHASE:1-planning"
        return 0
    fi

    # Phase 2: Features (single agent, must complete before tasks)
    if [ "$(read_signal features-complete.signal)" = "NONE" ]; then
        echo "ACTION:SPAWN"
        echo "AGENT:feature"
        echo "PHASE:2-features"
        return 0
    fi

    # Phase 3: Task Breakdown — PARALLEL for all features missing tasks
    local task_batch=""
    local task_batch_count=0
    for feature in "$ORCHESTRA_DIR/features"/*.feature.md; do
        [ -f "$feature" ] || continue
        local fname
        fname=$(feature_name_from_file "$feature")
        if [ "$(read_signal "tasks-${fname}-complete.signal")" = "NONE" ]; then
            task_batch_count=$((task_batch_count + 1))
            task_batch="${task_batch}BATCH_ITEM:${task_batch_count}
AGENT:task-builder
TARGET:${feature}
FEATURE_NAME:${fname}
"
        fi
    done

    if [ $task_batch_count -gt 0 ]; then
        if [ $task_batch_count -eq 1 ]; then
            # Single feature, no batch needed
            echo "ACTION:SPAWN"
            echo "${task_batch}" | grep -E "^(AGENT|TARGET|FEATURE_NAME):"
            echo "PHASE:3-tasks"
        else
            echo "ACTION:SPAWN_BATCH"
            echo "COUNT:${task_batch_count}"
            echo "${task_batch}"
            echo "PHASE:3-tasks"
        fi
        return 0
    fi

    # Phase 4: Dev Loop — collect ALL actionable tasks
    # 
    # Parallelism rules:
    #   - Tasks within the SAME feature are SEQUENTIAL (task 02 may depend on 01)
    #   - Tasks across DIFFERENT features can run in PARALLEL
    #   - Dev→Review→Test for a single task is always sequential
    #   - Cleanups and credential blocks are always returned immediately
    #
    # Strategy: find the first actionable task PER feature, batch them.

    local dev_batch=""
    local dev_batch_count=0
    local features_seen=""

    for task in "$ORCHESTRA_DIR/tasks"/*.task.md; do
        [ -f "$task" ] || continue
        local tname
        tname=$(task_name_from_file "$task")

        # Extract feature prefix (e.g. "01" from "01-03-setup-auth.task.md")
        local feature_prefix="${tname%%-*}"

        # Skip if we already have an action for this feature (sequential within feature)
        if echo "$features_seen" | grep -q ":${feature_prefix}:"; then
            continue
        fi

        local dev_status review_status test_status
        dev_status=$(read_signal "dev-${tname}-complete.signal")
        review_status=$(read_signal "review-${tname}-complete.signal")
        test_status=$(read_signal "test-${tname}-complete.signal")

        # Task done — skip
        if [ "$test_status" = "PASSED" ]; then
            continue
        fi

        # Mark this feature as having a pending task
        features_seen="${features_seen}:${feature_prefix}:"

        # Credential block — return immediately (needs human)
        if [ -f "$SIGNALS_DIR/need-credentials-${tname}.signal" ]; then
            echo "ACTION:CREDENTIALS_NEEDED"
            echo "TASK:$task"
            echo "TASK_NAME:$tname"
            echo "DETAILS:$(cat "$SIGNALS_DIR/need-credentials-${tname}.signal")"
            echo "PHASE:4-dev-loop"
            return 0
        fi

        # Determine the action for this task
        local action="" agent="" mode=""

        if [ "$dev_status" = "FIXED" ]; then
            action="CLEANUP_THEN_SPAWN"
            agent="code-reviewer"
        elif [ "$dev_status" = "NONE" ]; then
            action="SPAWN"
            agent="developer"
        elif [ "$dev_status" = "COMPLETE" ] && [ "$review_status" = "NONE" ]; then
            action="SPAWN"
            agent="code-reviewer"
        elif [ "$review_status" = "REJECTED" ]; then
            local iters
            iters=$(count_iterations "$tname")
            if [ "$iters" -ge 3 ]; then
                echo "ACTION:ESCALATE"
                echo "TASK:$task"
                echo "TASK_NAME:$tname"
                echo "REASON:Review rejected ${iters} times. Check reviews for pattern."
                echo "PHASE:4-dev-loop"
                return 0
            fi
            action="SPAWN"
            agent="developer"
            mode="review-fix"
        elif [ "$review_status" = "APPROVED" ] && [ "$test_status" = "NONE" ]; then
            action="SPAWN"
            agent="tester"
        elif [ "$test_status" = "FAILED" ]; then
            local iters
            iters=$(count_iterations "$tname")
            if [ "$iters" -ge 3 ]; then
                echo "ACTION:ESCALATE"
                echo "TASK:$task"
                echo "TASK_NAME:$tname"
                echo "REASON:Tests failed ${iters} times. Check test reports for pattern."
                echo "PHASE:4-dev-loop"
                return 0
            fi
            action="SPAWN"
            agent="developer"
            mode="test-fix"
        fi

        if [ -n "$action" ]; then
            dev_batch_count=$((dev_batch_count + 1))
            dev_batch="${dev_batch}BATCH_ITEM:${dev_batch_count}
ACTION:${action}
AGENT:${agent}
TARGET:${task}
TASK_NAME:${tname}
"
            [ -n "$mode" ] && dev_batch="${dev_batch}MODE:${mode}
"
        fi
    done

    if [ $dev_batch_count -gt 0 ]; then
        if [ $dev_batch_count -eq 1 ]; then
            # Single task — emit flat (no batch wrapper)
            echo "${dev_batch}" | grep -E "^(ACTION|AGENT|TARGET|TASK_NAME|MODE):" | head -5
            echo "PHASE:4-dev-loop"
        else
            echo "ACTION:SPAWN_BATCH"
            echo "COUNT:${dev_batch_count}"
            echo "${dev_batch}"
            echo "PHASE:4-dev-loop"
        fi
        return 0
    fi

    # Phase 5: After Action Reports — PARALLEL for all completed features
    local aar_batch=""
    local aar_batch_count=0
    for feature in "$ORCHESTRA_DIR/features"/*.feature.md; do
        [ -f "$feature" ] || continue
        local fname
        fname=$(feature_name_from_file "$feature")
        if [ "$(read_signal "aar-${fname}-complete.signal")" = "NONE" ]; then
            aar_batch_count=$((aar_batch_count + 1))
            aar_batch="${aar_batch}BATCH_ITEM:${aar_batch_count}
AGENT:task-reviewer
TARGET:${feature}
FEATURE_NAME:${fname}
"
        fi
    done

    if [ $aar_batch_count -gt 0 ]; then
        if [ $aar_batch_count -eq 1 ]; then
            echo "ACTION:SPAWN"
            echo "${aar_batch}" | grep -E "^(AGENT|TARGET|FEATURE_NAME):"
            echo "PHASE:5-aar"
        else
            echo "ACTION:SPAWN_BATCH"
            echo "COUNT:${aar_batch_count}"
            echo "${aar_batch}"
            echo "PHASE:5-aar"
        fi
        return 0
    fi

    # All done
    echo "ACTION:COMPLETE"
    echo "PHASE:done"
    return 0
}

# ─── Cleanup signals after developer FIXED ────────────────────────

cmd_cleanup() {
    local task_name="$1"

    if [ -z "$task_name" ]; then
        error "Usage: ./orchestra.sh cleanup <task_name>"
        return 1
    fi

    if [ -f "$SIGNALS_DIR/review-${task_name}-complete.signal" ]; then
        rm -f "$SIGNALS_DIR/review-${task_name}-complete.signal"
        success "Cleaned review signal for $task_name"
    fi

    if [ -f "$SIGNALS_DIR/test-${task_name}-complete.signal" ]; then
        rm -f "$SIGNALS_DIR/test-${task_name}-complete.signal"
        success "Cleaned test signal for $task_name"
    fi

    # Reset dev signal from FIXED → COMPLETE so the decision tree
    # advances past the FIXED check on the next cycle.
    # Without this, FIXED wins the elif chain every time and
    # triggers CLEANUP_THEN_SPAWN in an infinite loop.
    if [ -f "$SIGNALS_DIR/dev-${task_name}-complete.signal" ]; then
        local current
        current=$(head -1 "$SIGNALS_DIR/dev-${task_name}-complete.signal" 2>/dev/null | tr -d '[:space:]')
        if [ "$current" = "FIXED" ]; then
            # Preserve metadata lines, just replace the status word
            sed -i '1s/^FIXED/COMPLETE/' "$SIGNALS_DIR/dev-${task_name}-complete.signal"
            success "Reset dev signal FIXED → COMPLETE for $task_name"
        fi
    fi
}

# ─── Spawn Agent ──────────────────────────────────────────────────
# Writes the fully-substituted prompt to a temp file and outputs
# the path. This avoids dumping huge prompts into conversation history.

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

    # Write to temp file
    mkdir -p "$ORCHESTRA_DIR/tmp"
    local tmp_file="$ORCHESTRA_DIR/tmp/${agent_type}-${task_name:-${feature_name:-run}}-$$.md"
    echo "$prompt" > "$tmp_file"

    log "Spawning ${CYAN}${agent_type}${NC} agent..."
    echo "PROMPT_FILE:$tmp_file"
}

# ─── Status ───────────────────────────────────────────────────────

cmd_status() {
    echo ""
    echo -e "${BOLD}═══ ORCHESTRA STATUS ═══${NC}"
    echo ""

    # Determine phase
    local phase="UNKNOWN"
    if [ "$(read_signal planning-complete.signal)" = "NONE" ]; then
        phase="1-PLANNING"
    elif [ "$(read_signal features-complete.signal)" = "NONE" ]; then
        phase="2-FEATURES"
    else
        local tasks_pending=false
        for feature in "$ORCHESTRA_DIR/features"/*.feature.md; do
            [ -f "$feature" ] || continue
            local fname=$(feature_name_from_file "$feature")
            if [ "$(read_signal "tasks-${fname}-complete.signal")" = "NONE" ]; then
                tasks_pending=true; break
            fi
        done
        
        if [ "$tasks_pending" = true ]; then
            phase="3-TASK-BREAKDOWN"
        else
            local all_done=true
            for task in "$ORCHESTRA_DIR/tasks"/*.task.md; do
                [ -f "$task" ] || continue
                local tname=$(task_name_from_file "$task")
                if [ "$(read_signal "test-${tname}-complete.signal")" != "PASSED" ]; then
                    all_done=false; phase="4-DEV-LOOP"; break
                fi
            done
            if [ "$all_done" = true ]; then
                local aars_done=true
                for feature in "$ORCHESTRA_DIR/features"/*.feature.md; do
                    [ -f "$feature" ] || continue
                    local fname=$(feature_name_from_file "$feature")
                    if [ "$(read_signal "aar-${fname}-complete.signal")" = "NONE" ]; then
                        aars_done=false; phase="5-AAR"; break
                    fi
                done
                [ "$aars_done" = true ] && phase="COMPLETE"
            fi
        fi
    fi

    echo -e "  Phase: ${BOLD}${CYAN}$phase${NC}"
    echo ""

    # Counts
    local spec_count=$(ls -1 "$ORCHESTRA_DIR/specs"/*.spec.md 2>/dev/null | wc -l | tr -d ' ')
    local feat_count=$(ls -1 "$ORCHESTRA_DIR/features"/*.feature.md 2>/dev/null | wc -l | tr -d ' ')
    local task_count=$(ls -1 "$ORCHESTRA_DIR/tasks"/*.task.md 2>/dev/null | wc -l | tr -d ' ')

    [ -f "$ORCHESTRA_DIR/constitution.md" ] && echo -e "  ${GREEN}✓${NC} Constitution" || echo -e "  ${YELLOW}○${NC} Constitution"
    echo "  Specs:$spec_count  Features:$feat_count  Tasks:$task_count"
    echo ""

    # Task table
    if [ "$task_count" -gt 0 ] 2>/dev/null; then
        printf "  ${BOLD}%-40s %-10s %-12s %-10s${NC}\n" "TASK" "DEV" "REVIEW" "TEST"
        echo "  ────────────────────────────────────────────────────────────────"
        for task in "$ORCHESTRA_DIR/tasks"/*.task.md; do
            [ -f "$task" ] || continue
            local tname=$(task_name_from_file "$task")
            local dev=$(read_signal "dev-${tname}-complete.signal")
            local rev=$(read_signal "review-${tname}-complete.signal")
            local tst=$(read_signal "test-${tname}-complete.signal")
            
            local dev_c rev_c tst_c
            case "$dev" in COMPLETE) dev_c="${GREEN}$dev${NC}";; FIXED) dev_c="${YELLOW}$dev${NC}";; NONE) dev_c="${PURPLE}—${NC}";; *) dev_c="$dev";; esac
            case "$rev" in APPROVED) rev_c="${GREEN}$rev${NC}";; REJECTED) rev_c="${RED}$rev${NC}";; NONE) rev_c="${PURPLE}—${NC}";; *) rev_c="$rev";; esac
            case "$tst" in PASSED) tst_c="${GREEN}$tst${NC}";; FAILED) tst_c="${RED}$tst${NC}";; NONE) tst_c="${PURPLE}—${NC}";; *) tst_c="$tst";; esac
            
            printf "  %-40s %-22b %-24b %-22b\n" "$tname" "$dev_c" "$rev_c" "$tst_c"

            # Show signal details if present
            local details=""
            if [ "$dev" != "NONE" ]; then
                details=$(read_signal_details "dev-${tname}-complete.signal")
            fi
            if [ -n "$details" ]; then
                echo "$details" | while IFS= read -r line; do
                    [ -n "$line" ] && echo -e "    ${CYAN}${line}${NC}"
                done
            fi
        done
        echo ""
    fi

    # Blockers
    for signal in "$SIGNALS_DIR"/need-credentials-*.signal; do
        [ -f "$signal" ] || continue
        echo -e "  ${RED}🔑 BLOCKED: $(basename "$signal")${NC}"
        echo "    $(head -1 "$signal")"
    done
    echo ""

    # Keep window open if run interactively
    if [ -t 0 ]; then
        echo -e "${BOLD}Press any key to close...${NC}"
        read -n 1 -s -r
    fi
}

# ─── Clear ────────────────────────────────────────────────────────

cmd_clear() {
    warn "Clearing all signals..."
    rm -f "$SIGNALS_DIR"/*.signal
    success "All signals cleared"
}

# ─── Help ─────────────────────────────────────────────────────────

cmd_help() {
    cat << 'EOF'
═══ ORCHESTRA ═══

Commands:
  init                       Setup project structure
  next                       Get next action (MAIN COMMAND)
  status                     Full status dashboard
  cleanup <task_name>        Clean stale signals after FIXED
  spawn <agent> [target] [task_name] [feature_name]
  clear                      Reset all signals
  help                       This message

'next' output format:

  Single action:
    ACTION:SPAWN|CLEANUP_THEN_SPAWN|CREDENTIALS_NEEDED|ESCALATE|COMPLETE|INIT
    AGENT:<type>  TARGET:<path>  TASK_NAME:<n>  FEATURE_NAME:<n>  MODE:<fix>

  Parallel batch:
    ACTION:SPAWN_BATCH
    COUNT:<number>
    BATCH_ITEM:1
    AGENT:<type>  TARGET:<path> ...
    BATCH_ITEM:2
    AGENT:<type>  TARGET:<path> ...

Parallelism rules:
  - Tasks within a feature: SEQUENTIAL (01-01 before 01-02)
  - Tasks across features:  PARALLEL   (01-01 and 02-01 together)
  - Dev→Review→Test:        SEQUENTIAL (per task)
  - Task builders:          PARALLEL   (per feature)
  - AARs:                   PARALLEL   (per feature)
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
