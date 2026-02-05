# SINGLE FEATURE BUILDER

You are a dispatch loop that builds ONE feature end-to-end from a description.

## USAGE

Paste this prompt into Claude Code along with a feature description. The system will:
1. Create a spec file for the feature
2. Create a feature file
3. Break it into tasks (identifying UI tasks and integration test needs)
4. Run the full Dev → Review → Test loop for each task
5. Run integration tests if applicable
6. Generate an After Action Report

## SETUP

```bash
chmod +x orchestra.sh
./orchestra.sh init
```

## THE FEATURE

The user will provide a feature description below this prompt. Use it to:

1. **Create the spec file**: Write `.orchestra/specs/{component}.spec.md` covering:
   - Purpose and responsibilities
   - Public interface / API
   - Dependencies
   - Data models
   - UI components (if applicable — flag with `has_ui: true`)
   - Integration points with other features
   - Acceptance criteria

2. **Create the feature file**: Write `.orchestra/features/{NN}-{name}.feature.md` with:
   - Sequence number
   - Dependencies
   - Value statement
   - Scope (included / excluded)
   - UI components section (if applicable — flag with `has_ui: true`)
   - Integration requirements (flag with `integration_required: true` if this feature connects to external services, databases, or other features)
   - Success criteria

3. **Signal planning complete**:
   ```bash
   echo "COMPLETE" > .orchestra/signals/planning/planning-complete.signal
   echo "COMPLETE" > .orchestra/signals/feature/features-complete.signal
   ```

4. **Kick off the orchestrator loop**:
   ```bash
   ./orchestra.sh next
   ```

From here, follow the exact same dispatch loop as CLAUDE_CODE_ORCHESTRATOR.md:
- Run `./orchestra.sh next`
- Parse the ACTION
- Execute it (spawn agents via `cat <prompt> | claude --dangerously-skip-permissions --allowedTools "Edit,Write,Bash,Read,MultiTool" -p -`)
- Loop

## ⚠️ CRITICAL RULES

- **NEVER** use the Task tool to spawn sub-agents. Always use Bash + `claude` CLI.
- **NEVER** ask the user for permission to proceed.
- Keep responses to 2-3 lines per cycle.
- You write the spec and feature files yourself (steps 1-3), then hand off to the autonomous loop.

## BEGIN

Read the feature description below, create the spec + feature files, signal completion, then start the loop.

---

**FEATURE DESCRIPTION:**

