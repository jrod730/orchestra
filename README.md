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

> **Tip:** If you prefer `./launch` without the `.sh`, create an alias: `alias launch='./launch.sh'`

## How It Works

Orchestra follows a spec-driven pipeline. Every piece of code traces back to a specification, and every specification traces back to your requirements.

### Single Feature Flow (two phases)

```
PHASE 1 — PLANNING (runs once)
  Your description
      ↓
  Single Feature Planner Agent → creates ALL of:
      → spec file (technical how)
      → feature file (what to build)
      → task files (atomic work items)
      → all planning signals

PHASE 2 — DEVELOPMENT (loops until done)
  ./orchestra.sh next → reads signals, sees planning is done, jumps to dev
      ↓
  Developer Agent     → writes code + unit tests
      ↓
  Code Reviewer Agent → approves or rejects
      ↓
  Tester Agent        → runs functional tests
      ↓
  Task Reviewer Agent → after action report
```

Phase 1 runs once. Phase 2 loops through `./orchestra.sh next` which skips planning/feature/task creation (those signals already exist) and goes straight to spawning developer agents.

### Multi Feature Flow

```
Planning Agent      → constitution.md + spec files
    ↓
Feature Agent       → feature files (what to build)
    ↓
Task Builder Agent  → task files per feature (how to build it)
    ↓
[same dev loop as above, per task]
```

### The Dev Loop (both modes)

If the reviewer rejects code, the developer gets the rejection reasons and tries again. If tests fail, the developer gets the failure details and fixes. This loop continues until the task passes all gates.

## File Structure

```
orchestra/
├── launch.sh                       # Entry point — start here
├── orchestra.sh                    # Decision engine (agents don't touch this)
├── CLAUDE_CODE_ORCHESTRATOR.md     # Standard orchestrator prompt
├── README.md
├── agents/
│   ├── planning-agent.md           # Creates constitution & specs
│   ├── feature-agent.md            # Decomposes specs into features
│   ├── single-feature-planner-agent.md  # Scoped planner for single features
│   ├── task-builder-agent.md       # Breaks features into atomic tasks
│   ├── developer-agent.md          # Writes code
│   ├── ui-developer-agent.md       # Writes UI code (React, etc.)
│   ├── code-reviewer-agent.md      # Reviews for quality & standards
│   ├── tester-agent.md             # Functional & integration testing
│   └── task-reviewer-agent.md      # After action reports
└── prompts/
    ├── SINGLE_FEATURE_BUILDER.md   # Orchestrator prompt for single features
    └── MULTI_FEATURE_BUILDER.md    # Orchestrator prompt for full projects
```

When running, Orchestra creates a `.orchestra/` directory in your project:

```
.orchestra/
├── constitution.md                 # Coding standards & patterns
├── tmp/
│   └── feature-description.md      # Your feature description (single mode)
├── specs/
│   └── *.spec.md                   # Technical specifications
├── features/
│   └── *.feature.md                # Feature definitions
├── tasks/
│   └── *.task.md                   # Atomic task definitions
├── reviews/
│   └── *.review.md                 # Code review reports
├── tests/
│   └── *.test-report.md            # Test results
├── aar/
│   └── *.aar.md                    # After action reports
└── signals/
    ├── dev/                        # Developer completion signals
    ├── review/                     # Code review signals
    ├── test/                       # Test signals
    ├── tasks/                      # Task builder signals
    ├── features/                   # Feature planning signals
    └── aar/                        # After action report signals
```

## Naming Convention

All files use descriptive, slug-based names derived from the feature or task content. No generic `task-01` or `feature-01` names.

The planner derives a slug from your feature description — a short, lowercase, hyphenated summary:

| Feature Description | Slug |
|---|---|
| "Fix the rate limiter tests by adding a clock abstraction" | `rate-limiter-test-fix` |
| "Add logout button to dashboard header" | `dashboard-logout-button` |
| "Implement case creation workflow" | `case-creation-workflow` |

That slug flows through every artifact:

```
Spec:     .orchestra/specs/single-rate-limiter-test-fix.spec.md
Feature:  .orchestra/features/single-rate-limiter-test-fix.feature.md
Tasks:    .orchestra/tasks/single-rate-limiter-test-fix-01-clock-interface.task.md
          .orchestra/tasks/single-rate-limiter-test-fix-02-inject-into-limiter.task.md
          .orchestra/tasks/single-rate-limiter-test-fix-03-update-unit-tests.task.md
Signals:  .orchestra/signals/dev/dev-single-rate-limiter-test-fix-01-clock-interface-complete.signal
          .orchestra/signals/review/review-single-rate-limiter-test-fix-01-clock-interface-complete.signal
          .orchestra/signals/tasks/tasks-single-rate-limiter-test-fix-complete.signal
```

Task names also include a descriptor after the sequence number — `01-clock-interface`, not just `01`.

## Modes

### Single Feature

Builds one feature from a description you provide. Your description gets saved to `.orchestra/tmp/feature-description.md` — this file becomes the single source of truth that every downstream agent is scope-locked to.

```bash
./launch.sh single "Fix the rate limiter tests by adding a clock abstraction"
```

Or with a file for longer descriptions:

```bash
./launch.sh single --file feature-description.md
```

From that description, the pipeline creates:

```
.orchestra/tmp/feature-description.md          ← Your description (saved by launch.sh)
    ↓
.orchestra/specs/single-{name}.spec.md         ← Technical spec (scope-locked to description)
    ↓
.orchestra/features/single-{name}.feature.md   ← Feature definition (references the spec)
    ↓
.orchestra/tasks/{name}-01-{task}.task.md       ← Atomic tasks (trace back to spec sections)
```

**Scope lock:** Every file in this chain is constrained to your description. Downstream agents can only work within that scope — they won't discover unrelated work from your project specs.

### Multi Feature

Plans and builds the entire project from documentation in your `/docs` directory. The planning agent reads your docs, creates a constitution and specs, then the feature agent decomposes everything into buildable features.

```bash
./launch.sh multi
```

Put your requirements, PRDs, design docs, or any project documentation in `/docs` before running.

### Resume

Picks up an existing orchestration from where it left off. Reads the signal files to figure out what's done and what's next.

```bash
./launch.sh resume
```

## Setup

1. Copy the orchestra files into your project (or keep them in a separate directory and reference them):

```bash
cp -r /path/to/orchestra /your/project/
cd /your/project
chmod +x orchestra/launch.sh orchestra/orchestra.sh
```

2. For **multi** mode, add your project documentation to `/docs`:

```bash
mkdir -p docs
# Add your requirements, PRDs, technical specs, etc.
```

3. Run:

```bash
./orchestra/launch.sh single "your feature description"
# or
./orchestra/launch.sh multi
```

## Architecture Decisions

**Why a shell script as the brain?** `orchestra.sh` handles all decision logic (which agent to spawn next, signal checking, cleanup). This keeps the orchestrator's Claude Code context window small — it just runs the script and acts on the output instead of reasoning about state.

**Why file-based signals?** Signals are the coordination mechanism between agents. Each agent writes a signal when it finishes. The shell script reads signals to determine the next action. This is simpler and more debuggable than any in-memory state.

**Why `launch.sh`?** Two reasons. First, Claude Code only skips permissions when launched via CLI with `--dangerously-skip-permissions`. Pasting a prompt into an interactive session will always prompt for approval. Second, `launch.sh` uses `--system-prompt-file` with an initial message argument instead of `cat | claude -p -`. The `-p` (print) flag runs in non-interactive mode with no live output — you'd see nothing until it finishes. Using `--system-prompt-file` launches the full Claude Code TUI so you see everything streaming in real-time.

**Why scope locking?** Without explicit scope constraints, agents that read all project specs will plan work for the entire project — even when you only asked for one feature. The scope lock chain (description → spec → feature → tasks) ensures each layer can only reference what the layer above defined.

## Parallelization

Orchestra can run independent work in parallel:

| Parallel OK | Must Be Sequential |
|---|---|
| Task builders for different features | Planning → Features → Tasks (init) |
| Developers for independent tasks | Dev → Review → Test (per task) |
| Task reviewers for completed features | |

## Monitoring

```bash
# Full status dashboard
./orchestra.sh status

# Check signals
ls -la .orchestra/signals/*/

# Check a specific signal
cat .orchestra/signals/dev/dev-{task-name}-complete.signal
```

## Troubleshooting

**"File not found" when using `--file`?**
`launch.sh` auto-searches multiple locations: the path you gave, `.orchestra/tmp/`, `prompts/`, and the script directory. If it still can't find the file, it lists what's available in `.orchestra/tmp/` so you can see the right name. You can use just the filename — no need for the full path:
```bash
# All of these work if the file is in .orchestra/tmp/:
./launch.sh single --file fix-clock-tests-feature.md
./launch.sh single --file .orchestra/tmp/fix-clock-tests-feature.md
```

**No output or feedback in the terminal?**
Make sure you're using the latest `launch.sh`. Older versions used `cat | claude -p -` which runs in print mode with no live output. The current version uses `--system-prompt-file` which launches Claude Code's full TUI with real-time streaming.

**Agent keeps rebuilding the whole project in single-feature mode?**
Make sure you're using the updated `single-feature-planner-agent.md` with the scope lock. The feature file should contain `Mode: SINGLE FEATURE` in its Scope Lock section.

**Main thread asking for permissions?**
Use `./launch.sh` instead of pasting prompts into Claude Code. The launcher starts the orchestrator with `--dangerously-skip-permissions`.

**Orchestrator loops back to planning instead of dev?**
The planner must create task files AND the tasks signal in one pass. Check that `.orchestra/signals/tasks/tasks-*-complete.signal` exists after the planner finishes. If not, the planner agent needs updating.

**Stuck in a review/test loop?**
After 3 rejections on the same task, the orchestrator escalates to you. Check the review/test reports in `.orchestra/reviews/` and `.orchestra/tests/` for patterns.

**Sub-agents can't run bash commands?**
Make sure sub-agents are spawned with `--allowedTools "Edit,Write,Bash,Read,MultiTool"`. The launcher and orchestrator prompts handle this automatically.

**Orchestrator exited unexpectedly?**
Run `./launch.sh resume` to pick up where it left off. It reads the signal files and figures out what's done and what's next.

## License

MIT
