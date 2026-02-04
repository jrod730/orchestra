# 🎵 Orchestra

**Autonomous, specification-driven multi-agent development pipeline for Claude Code.**

Orchestra coordinates seven specialized AI agents through a complete software development lifecycle — planning, task decomposition, development, code review, testing, and retrospectives — with zero human intervention.

Built for **Claude Opus 4.5** running through **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)**.

---

## How It Works

Orchestra runs on three primitives:

### Shell Script Brain (`orchestra.sh`)

The decision engine. Reads project state from signal files, determines the next action, and outputs structured commands. It never writes code, never reads specs — it only dispatches.

### Signal-Based State Management

Agents communicate through signal files — small state markers like `dev-01-01-login-complete.signal` containing a status word (`COMPLETE`, `REJECTED`, `PASSED`, `FIXED`, `FAILED`) plus metadata about the work performed.

Rejection and failure signals are **never deleted** until the developer agent has read them and written a fix. This preserves the full investigation chain so the developer can trace every flagged issue before correcting it.

### On-Demand Agent Prompts

Seven agent prompts live in `agents/` and are loaded only when spawned — never embedded in the orchestrator's context. This keeps the orchestrator under **~800 tokens per cycle**, which is critical for long-running sessions where conversation history accumulates fast.

---

## The Pipeline

```
Phase 1: PLANNING    → Constitution + Component Specs
Phase 2: FEATURES    → Sequenced, dependency-aware feature decomposition
Phase 3: TASKS       → Atomic, testable task files with acceptance criteria
Phase 4: DEV LOOP    → Develop → Review → Test (iterative, per task)
Phase 5: AAR         → After Action Reports with metrics per feature
```

### Phase 4 State Machine (Per Task)

```
Happy Path:
  [no signals] → dev:COMPLETE → review:APPROVED → test:PASSED ✅

Review Rejection:
  dev:COMPLETE → review:REJECTED
  → Developer reads rejection, investigates, fixes
  → dev:FIXED → cleanup → fresh review cycle

Test Failure:
  review:APPROVED → test:FAILED
  → Developer reads test report, investigates, fixes
  → dev:FIXED → cleanup → fresh review cycle (code changed, needs re-review)

Escalation:
  3+ rejection/failure cycles on the same task → ESCALATE to user
```

---

## Agents

| Agent | Role | Signal |
|-------|------|--------|
| **Planning** | Reads `/docs`, creates constitution + specs | `planning-complete.signal` |
| **Feature** | Decomposes specs into sequenced features | `features-complete.signal` |
| **Task Builder** | Breaks features into atomic tasks | `tasks-{feature}-complete.signal` |
| **Developer** | Writes code + unit tests; 3 modes (fresh, review-fix, test-fix) | `dev-{task}-complete.signal` |
| **Code Reviewer** | Reviews against constitution; tracks iterations | `review-{task}-complete.signal` |
| **Tester** | Functional tests, regression detection, credential blocking | `test-{task}-complete.signal` |
| **Task Reviewer** | After-action reports with cycle metrics | `aar-{feature}-complete.signal` |

Every agent runs a **Step 0 idempotency check** before doing work. If the signal already exists and work is complete, the agent exits immediately. This means restarting the orchestrator mid-project never duplicates effort.

---

## Key Features

- **Signal-preserving investigation flow** — Rejection/failure signals stay until the developer reads them and writes `FIXED`
- **Parallel execution across features** — Tasks in different features run concurrently; tasks within a feature stay sequential
- **Token-efficient** — ~800 token orchestrator; agent prompts loaded on-demand from files, piped via stdin
- **Idempotent agents** — Every agent checks for existing work before starting; safe to restart anytime
- **Loop detection** — Escalates to user after 3 rejection/failure cycles on the same task
- **Credential blocking** — Tester halts and requests API keys when needed; pipeline resumes after user provides them
- **Verbose signals** — Signals include metadata (timestamps, file lists, issue counts) visible in the status dashboard
- **Iteration history** — Review and test reports are archived (`review-iter1.md`, `review-iter2.md`) so developers see the full rejection history

---

## Quick Start

### Prerequisites

- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** installed and configured
- **Claude Max / Pro / Team / Enterprise** subscription (for Opus 4.5 access)

### Setup

```bash
git clone https://github.com/jrod730/orchestra.git
cd your-project
cp -r /path/to/orchestra/orchestra.sh .
cp -r /path/to/orchestra/agents ./agents
cp /path/to/orchestra/CLAUDE_CODE_ORCHESTRATOR.md .
```

### Add Your Project Documentation

Place your project documentation in a `/docs` folder:

```
your-project/
├── docs/
│   ├── requirements.md
│   ├── architecture.md
│   └── ...any project docs...
├── orchestra.sh
├── agents/
│   ├── planning-agent.md
│   ├── feature-agent.md
│   ├── task-builder-agent.md
│   ├── developer-agent.md
│   ├── code-reviewer-agent.md
│   ├── tester-agent.md
│   └── task-reviewer-agent.md
└── CLAUDE_CODE_ORCHESTRATOR.md
```

### Run

Open Claude Code and paste the contents of `CLAUDE_CODE_ORCHESTRATOR.md` as your initial prompt. The orchestrator will:

1. `chmod +x orchestra.sh`
2. `./orchestra.sh init` — creates the `.orchestra/` directory structure
3. `./orchestra.sh next` — begins the autonomous loop

From there, it runs hands-free until the project is complete, credentials are needed, or a task escalates.

---

## Commands

| Command | Description |
|---------|-------------|
| `./orchestra.sh init` | Initialize project structure |
| `./orchestra.sh next` | Get next action (the main loop command) |
| `./orchestra.sh status` | Full status dashboard with color-coded signals |
| `./orchestra.sh cleanup <task>` | Clean stale signals after developer writes FIXED |
| `./orchestra.sh spawn <agent> [target] [task] [feature]` | Generate agent prompt file |
| `./orchestra.sh clear` | Reset all signals |
| `./orchestra.sh help` | Show help |

### Status Dashboard

```
═══ ORCHESTRA STATUS ═══

  ✓ Constitution
  Specs:4  Features:3  Tasks:12

  TASK                                     DEV        REVIEW      TEST
  ────────────────────────────────────────────────────────────────
  01-01-setup-auth                         COMPLETE   APPROVED    PASSED
    Task: 01-01-setup-auth
    Completed: 2026-02-03 14:30
    Files:
      - src/Auth/AuthService.cs
  01-02-login-flow                         FIXED      REJECTED    —
  02-01-dashboard-layout                   COMPLETE   APPROVED    —

Press any key to close...
```

---

## Parallelism

The `next` command batches independent work and outputs `ACTION:SPAWN_BATCH` when multiple agents can run concurrently.

**Rules:**
- Tasks **within** a feature → **sequential** (task 02 may depend on task 01)
- Tasks **across** features → **parallel** (feature 01 and feature 02 run simultaneously)
- Task builders → **parallel** (one per feature)
- After-action reports → **parallel** (one per feature)
- Dev → Review → Test → **always sequential** per task

---

## Architecture

```
CLAUDE_CODE_ORCHESTRATOR.md    ← Slim dispatcher prompt (~800 tokens)
orchestra.sh                   ← Decision-making brain (all logic lives here)
agents/
├── planning-agent.md          ← Creates constitution + specs
├── feature-agent.md           ← Decomposes specs into features
├── task-builder-agent.md      ← Breaks features into tasks
├── developer-agent.md         ← Writes code (3 modes: fresh/review-fix/test-fix)
├── code-reviewer-agent.md     ← Reviews against constitution
├── tester-agent.md            ← Functional tests + credential handling
└── task-reviewer-agent.md     ← After-action reports
.orchestra/                    ← Created at runtime by orchestra.sh init
├── constitution.md
├── specs/
├── features/
├── tasks/
├── reviews/                   ← Includes iteration archives (review-iter1.md, etc.)
├── tests/                     ← Includes iteration archives (test-report-iter1.md, etc.)
├── aar/
├── signals/                   ← State markers read by orchestra.sh
├── secrets.env                ← Credentials (user-provided)
└── tmp/                       ← Temp prompt files for spawning
```

---

## Why Claude Opus 4.5?

Orchestra was purpose-built for Opus 4.5's strengths:

- **80.9% on SWE-bench Verified** — highest of any model, ahead of GPT-5.1 (76.3%) and Gemini 3 Pro (76.2%)
- **29% more than Sonnet 4.5 on Vending-Bench** — which tests long-horizon agent coherence over 20M+ token runs
- **Consistent performance through 30-minute autonomous coding sessions** with fewer dead-ends
- **50–75% reduction in tool-calling errors and build/lint errors** vs previous models
- **Leads in 7 of 8 languages** on SWE-bench Multilingual

The combination of strong code generation, reliable multi-step tool use, and sustained coherence across dozens of agent spawns is what makes the autonomous loop viable.

---

## How Sub-Agents Are Spawned

Orchestra spawns agents via the `claude` CLI through bash — **not** through Claude Code's built-in Task tool (which doesn't support `--dangerously-skip-permissions`).

```bash
# Generate the prompt file (substitutes variables, writes to .orchestra/tmp/)
./orchestra.sh spawn developer .orchestra/tasks/01-01-login.task.md 01-01-login

# Spawn the agent via stdin pipe
cat .orchestra/tmp/developer-01-01-login-*.md | claude --dangerously-skip-permissions --allowedTools "Edit,Write,Bash,Read,MultiTool" -p -
```

For parallel batches:
```bash
cat /path/to/prompt1.md | claude --dangerously-skip-permissions --allowedTools "Edit,Write,Bash,Read,MultiTool" -p - &
cat /path/to/prompt2.md | claude --dangerously-skip-permissions --allowedTools "Edit,Write,Bash,Read,MultiTool" -p - &
wait
```

---

## License

MIT

---

## Contributing

Issues, forks, and PRs welcome. If you build something interesting on top of Orchestra, I'd love to hear about it.