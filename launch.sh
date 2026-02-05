#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# ORCHESTRA LAUNCHER
#
# Run this from your TERMINAL — not from inside Claude Code.
# This launches the orchestrator with --dangerously-skip-permissions
# and full TUI so you see live streaming output.
#
# Usage:
#   ./launch.sh single "Your feature description here"
#   ./launch.sh single --file my-feature.md
#   ./launch.sh multi
#   ./launch.sh resume
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="$SCRIPT_DIR/prompts"
AGENTS_DIR="$SCRIPT_DIR/agents"
ORCHESTRA_DIR=".orchestra"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

usage() {
    cat << 'EOF'
═══ ORCHESTRA LAUNCHER ═══

⚠️  Run this from your TERMINAL, not from inside Claude Code.

Usage:
  ./launch.sh single "Fix the rate limiter tests by adding a clock abstraction"
  ./launch.sh single --file path/to/description.md
  ./launch.sh single --file my-feature.md
  ./launch.sh multi
  ./launch.sh resume

Commands:
  single "description"       Launch single feature builder with inline description
  single --file <path>       Launch single feature builder with description from file
                             (searches current dir, .orchestra/tmp/, and prompts/)
  multi                      Launch multi feature builder (full project planning)
  resume                     Resume an existing orchestration (re-enters the dev loop)

Tip: Create an alias if you prefer shorter commands:
  alias launch='./launch.sh'

The orchestrator runs with --dangerously-skip-permissions and shows full
live output in the terminal. Fully hands-off.
EOF
    exit 1
}

# ─── File Finder ──────────────────────────────────────────────────

find_file() {
    local filename="$1"

    # 1. Exact path as given
    if [ -f "$filename" ]; then
        echo "$filename"
        return 0
    fi

    # 2. Check .orchestra/tmp/
    if [ -f "$ORCHESTRA_DIR/tmp/$filename" ]; then
        echo "$ORCHESTRA_DIR/tmp/$filename"
        return 0
    fi

    # 3. Check .orchestra/tmp/ with basename
    local base
    base=$(basename "$filename")
    if [ -f "$ORCHESTRA_DIR/tmp/$base" ]; then
        echo "$ORCHESTRA_DIR/tmp/$base"
        return 0
    fi

    # 4. Check prompts/
    if [ -f "$PROMPTS_DIR/$filename" ]; then
        echo "$PROMPTS_DIR/$filename"
        return 0
    fi

    # 5. Check script directory
    if [ -f "$SCRIPT_DIR/$filename" ]; then
        echo "$SCRIPT_DIR/$filename"
        return 0
    fi

    return 1
}

# ─── Single Feature ──────────────────────────────────────────────

launch_single() {
    local description=""

    if [ "${1:-}" = "--file" ]; then
        local input_path="${2:-}"
        if [ -z "$input_path" ]; then
            echo -e "${RED}Error: No file path provided after --file${NC}"
            echo ""
            usage
        fi

        local resolved_path
        if resolved_path=$(find_file "$input_path"); then
            if [ "$resolved_path" != "$input_path" ]; then
                echo -e "${YELLOW}File not found at '$input_path', using: $resolved_path${NC}"
            fi
            description=$(cat "$resolved_path")
        else
            echo -e "${RED}Error: File not found: $input_path${NC}"
            echo -e "${YELLOW}Searched in:${NC}"
            echo -e "  - $input_path"
            echo -e "  - $ORCHESTRA_DIR/tmp/$input_path"
            echo -e "  - $ORCHESTRA_DIR/tmp/$(basename "$input_path")"
            echo -e "  - $PROMPTS_DIR/$input_path"
            echo -e "  - $SCRIPT_DIR/$input_path"
            echo ""
            if [ -d "$ORCHESTRA_DIR/tmp" ]; then
                echo -e "${CYAN}Available files in $ORCHESTRA_DIR/tmp/:${NC}"
                ls -1 "$ORCHESTRA_DIR/tmp/"*.md 2>/dev/null || echo "  (none)"
            fi
            exit 1
        fi
    else
        description="$*"
    fi

    if [ -z "$description" ]; then
        echo -e "${RED}Error: No feature description provided${NC}"
        echo ""
        usage
    fi

    echo -e "${BOLD}═══ ORCHESTRA — Single Feature Builder ═══${NC}"
    echo -e "${CYAN}Feature:${NC} ${description:0:100}..."
    echo ""

    local prompt_file="$PROMPTS_DIR/SINGLE_FEATURE_BUILDER.md"
    if [ ! -f "$prompt_file" ]; then
        echo -e "${RED}Error: $prompt_file not found${NC}"
        exit 1
    fi

    # Pre-save the feature description
    mkdir -p "$ORCHESTRA_DIR/tmp"
    echo "$description" > "$ORCHESTRA_DIR/tmp/feature-description.md"
    echo -e "${CYAN}Saved feature description to:${NC} $ORCHESTRA_DIR/tmp/feature-description.md"

    # Build combined prompt file (system prompt + feature description)
    local tmp_prompt=$(mktemp /tmp/orchestra-launch-XXXXXX.md)
    cat "$prompt_file" > "$tmp_prompt"
    echo "" >> "$tmp_prompt"
    echo "$description" >> "$tmp_prompt"

    echo -e "${GREEN}Launching orchestrator with live output...${NC}"
    echo ""

    # Use --system-prompt-file with initial message to get full TUI
    # This gives live streaming output in the terminal
    claude \
        --dangerously-skip-permissions \
        --allowedTools "Edit,Write,Bash,Read,MultiTool" \
        --system-prompt-file "$tmp_prompt" \
        "Begin. Execute the startup sequence now. Do not ask for confirmation."

    local exit_code=$?
    rm -f "$tmp_prompt"

    if [ $exit_code -eq 0 ]; then
        echo ""
        echo -e "${GREEN}═══ ORCHESTRA COMPLETE ═══${NC}"
    else
        echo ""
        echo -e "${YELLOW}═══ ORCHESTRA EXITED (code $exit_code) ═══${NC}"
        echo -e "Run ${CYAN}./launch.sh resume${NC} to continue where it left off."
    fi
}

# ─── Multi Feature ────────────────────────────────────────────────

launch_multi() {
    echo -e "${BOLD}═══ ORCHESTRA — Multi Feature Builder ═══${NC}"
    echo ""

    local prompt_file="$PROMPTS_DIR/MULTI_FEATURE_BUILDER.md"
    if [ ! -f "$prompt_file" ]; then
        echo -e "${RED}Error: $prompt_file not found${NC}"
        exit 1
    fi

    echo -e "${GREEN}Launching orchestrator with live output...${NC}"
    echo ""

    claude \
        --dangerously-skip-permissions \
        --allowedTools "Edit,Write,Bash,Read,MultiTool" \
        --system-prompt-file "$prompt_file" \
        "Begin. Execute the startup sequence now. Do not ask for confirmation."

    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo ""
        echo -e "${GREEN}═══ ORCHESTRA COMPLETE ═══${NC}"
    else
        echo ""
        echo -e "${YELLOW}═══ ORCHESTRA EXITED (code $exit_code) ═══${NC}"
        echo -e "Run ${CYAN}./launch.sh resume${NC} to continue where it left off."
    fi
}

# ─── Resume ───────────────────────────────────────────────────────

launch_resume() {
    echo -e "${BOLD}═══ ORCHESTRA — Resuming ═══${NC}"
    echo ""

    local prompt_file=""
    for candidate in \
        "$PROMPTS_DIR/CLAUDE_CODE_ORCHESTRATOR.md" \
        "$SCRIPT_DIR/CLAUDE_CODE_ORCHESTRATOR.md" \
        "./CLAUDE_CODE_ORCHESTRATOR.md"; do
        if [ -f "$candidate" ]; then
            prompt_file="$candidate"
            break
        fi
    done

    if [ -z "$prompt_file" ]; then
        echo -e "${RED}Error: Orchestrator prompt not found${NC}"
        exit 1
    fi

    if [ ! -d "$ORCHESTRA_DIR" ]; then
        echo -e "${RED}Error: .orchestra/ directory not found. Nothing to resume.${NC}"
        exit 1
    fi

    echo -e "${CYAN}Using prompt:${NC} $prompt_file"
    echo -e "${GREEN}Resuming orchestrator with live output...${NC}"
    echo ""

    claude \
        --dangerously-skip-permissions \
        --allowedTools "Edit,Write,Bash,Read,MultiTool" \
        --system-prompt-file "$prompt_file" \
        "Resume. Run ./orchestra.sh next and continue the dispatch loop. Do not ask for confirmation."

    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo ""
        echo -e "${GREEN}═══ ORCHESTRA COMPLETE ═══${NC}"
    else
        echo ""
        echo -e "${YELLOW}═══ ORCHESTRA EXITED (code $exit_code) ═══${NC}"
        echo -e "Run ${CYAN}./launch.sh resume${NC} to try again."
    fi
}

# ─── Main ─────────────────────────────────────────────────────────

case "${1:-}" in
    single)
        shift
        launch_single "$@"
        ;;
    multi)
        launch_multi
        ;;
    resume)
        launch_resume
        ;;
    *)
        usage
        ;;
esac
