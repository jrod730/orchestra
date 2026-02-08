# Orchestra

Specification-driven development orchestration for Claude Code. Spawns specialized sub-agents that do all the work while keeping the main thread lightweight.

## Quick Start

```bash
# Single feature — just describe what you want built
./launch.sh single "Add a logout button to the dashboard header"

# Single feature — longer description from a file
./launch.sh single --file my-feature.md

# Full project — plans and builds everything from /docs
./launch.sh multi

# Resume — pick up where a previous run left off
./launch.sh resume
```

That's it. No permissions prompts, no human interaction. Fully autonomous from start to finish.

## How It Works

Orchestra follows a spec-driven pipeline. Every piece of code traces back to a specification, and every specification traces back to your requirements.

### The Dev Loop (v2.1 — Inner Loop Enforced)

Each task goes through a strict inner loop. **A task cannot advance until all three gates pass:**

```
Developer Agent     → writes code + unit tests
    ↓
Code Reviewer Agent → approves or rejects
    ↓
Tester Agent        → runs functional tests
    ↓
(next task)
```

If the reviewer rejects, the developer gets the rejection reasons and fixes. If tests fail, the developer gets the failure details and fixes. The task stays in this loop until it passes all three gates.

### Parallel Execution via TRACKs

Features run in parallel. Each feature gets its own **track** with an independent state machine:

```
Feature A:  task-01 → dev → review → test → task-02 → dev → review → test
Feature B:  task-01 → dev → review → test → task-02 → dev → review → test
                     ↑ these interleave ↑
```

In a single call to `./orchestra.sh next`, you might get:
- **Track 01:** spawn code-reviewer (auth task — dev just finished)
- **Track 02:** spawn developer (dashboard task — hasn't started)

Each track's agent type is determined independently by the inner loop state machine.

### Full Pipeline

```
Phase 1: Planning      → constitution + specs
Phase 2: Features      → feature definitions
Phase 3: Tasks         → atomic task files per feature
Phase 4: Dev Loop      → dev → review → test (parallel across features)
Phase 4.5: Integration → cross-component tests (if needed)
Phase 5: AAR           → after action reports
```

## File Structure

```
orchestra/
├── launch.sh                       # Entry point — start here
├── orchestra.sh                    # Decision engine (agents don't touch this)
├── CLAUDE_CODE_ORCHESTRATOR.md     # Standard orchestrator prompt
├── README.md
├── agents/
│   ├── planning-agent.md
│   ├── feature-agent.md
│   ├── single-feature-planner-agent.md
│   ├── task-builder-agent.md
│   ├── developer-agent.md
│   ├── ui-developer-agent.md
│   ├── code-reviewer-agent.md
│   ├── tester-agent.md
│   ├── integration-tester-agent.md
│   └── task-reviewer-agent.md
└── prompts/
    ├── SINGLE_FEATURE_BUILDER.md
    └── MULTI_FEATURE_BUILDER.md
```

When running, Orchestra creates a `.orchestra/` directory in your project:

```
.orchestra/
├── constitution.md
├── tmp/
│   └── feature-description.md
├── specs/
├── features/
├── tasks/
├── reviews/
├── tests/
├── aar/
└── signals/
    ├── dev/          # COMPLETE or FIXED
    ├── review/       # APPROVED or REJECTED
    ├── test/         # PASSED or FAILED
    ├── integration/
    ├── planning/
    ├── feature/
    ├── task/
    └── aar/
```

## v2.1 Changes

- **TRACK-based dev loop**: Phase 4 outputs one TRACK per feature, each with its own agent type. Prevents the orchestrator from confusing agent types across features.
- **Inner loop strictly enforced**: `dev → review → test` per task. No task advances until `test=PASSED`.
- **Clearer output format**: `TRACK:feature-prefix` + `---` separators make parsing unambiguous.
- **Backward compatible**: Phases 1-3 and 4.5-5 still use `SPAWN` and `SPAWN_BATCH` as before.

## Architecture Decisions

**Why a shell script as the brain?** `orchestra.sh` handles all decision logic. This keeps the orchestrator's context window small — it just runs the script and acts on the output instead of reasoning about state.

**Why TRACK blocks instead of BATCH_ITEMs?** The old `SPAWN_BATCH` format listed all items with the same structure, which led to the orchestrator treating all items as the same agent type. TRACK blocks make each feature's agent type explicit and separated by `---` delimiters.

**Why file-based signals?** Signals are the coordination mechanism between agents. Each agent writes a signal when it finishes. The shell script reads signals to determine the next action. Simple and debuggable.

**Why scope locking?** Without explicit scope constraints, agents that read all project specs will plan work for the entire project — even when you only asked for one feature.
