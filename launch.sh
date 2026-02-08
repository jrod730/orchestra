#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# LAUNCH — Entry point for Orchestra
#
# Usage:
#   ./launch.sh single "Add logout button to dashboard"
#   ./launch.sh single --file feature-description.md
#   ./launch.sh multi
#   ./launch.sh resume
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure orchestra.sh is executable
chmod +x "$SCRIPT_DIR/orchestra.sh"

# ─── Helpers ──────────────────────────────────────────────────────

usage() {
    echo "Orchestra Launcher"
    echo ""
    echo "Usage:"
    echo "  ./launch.sh single \"<feature description>\"   Build one feature"
    echo "  ./launch.sh single --file <path>              Build one feature from file"
    echo "  ./launch.sh multi                              Build full project from /docs"
    echo "  ./launch.sh resume                             Resume previous run"
    echo ""
    exit 1
}

ensure_claude_code() {
    if ! command -v claude &>/dev/null; then
        echo "ERROR: Claude Code CLI not found."
        echo "Install: https://docs.anthropic.com/en/docs/claude-code"
        exit 1
    fi
}

# ─── Commands ─────────────────────────────────────────────────────

cmd_single() {
    local description=""

    if [ "${1:-}" = "--file" ]; then
        local filepath="${2:-}"
        if [ -z "$filepath" ] || [ ! -f "$filepath" ]; then
            echo "ERROR: File not found: $filepath"
            exit 1
        fi
        description=$(cat "$filepath")
    else
        description="$*"
    fi

    if [ -z "$description" ]; then
        echo "ERROR: No feature description provided."
        usage
    fi

    # Initialize orchestra
    "$SCRIPT_DIR/orchestra.sh" init

    # Save feature description
    mkdir -p .orchestra/tmp
    echo "$description" > .orchestra/tmp/feature-description.md
    echo "Feature description saved to .orchestra/tmp/feature-description.md"

    # Launch Claude Code with single feature builder prompt
    echo "Launching Claude Code (single feature mode)..."
    claude --dangerously-skip-permissions \
        --system-prompt-file "$SCRIPT_DIR/prompts/SINGLE_FEATURE_BUILDER.md" \
        "Build this feature: $description"
}

cmd_multi() {
    if [ ! -d "docs" ]; then
        echo "WARNING: No /docs directory found. The planning agent will have limited context."
        echo "Consider adding your requirements, PRDs, and design docs to /docs/"
        echo ""
    fi

    # Initialize orchestra
    "$SCRIPT_DIR/orchestra.sh" init

    # Launch Claude Code with multi feature builder prompt
    echo "Launching Claude Code (multi feature mode)..."
    claude --dangerously-skip-permissions \
        --system-prompt-file "$SCRIPT_DIR/prompts/MULTI_FEATURE_BUILDER.md" \
        "Begin full project build from /docs"
}

cmd_resume() {
    if [ ! -d ".orchestra" ]; then
        echo "ERROR: No .orchestra/ directory found. Nothing to resume."
        echo "Run './launch.sh single' or './launch.sh multi' first."
        exit 1
    fi

    echo "Resuming Orchestra..."
    echo "Current status:"
    "$SCRIPT_DIR/orchestra.sh" status
    echo ""

    # Launch with standard orchestrator prompt
    claude --dangerously-skip-permissions \
        --system-prompt-file "$SCRIPT_DIR/CLAUDE_CODE_ORCHESTRATOR.md" \
        "Resume the Orchestra pipeline. Run ./orchestra.sh next and process the result."
}

# ─── Main ─────────────────────────────────────────────────────────

ensure_claude_code

case "${1:-}" in
    single)
        shift
        cmd_single "$@"
        ;;
    multi)
        cmd_multi
        ;;
    resume)
        cmd_resume
        ;;
    *)
        usage
        ;;
esac
