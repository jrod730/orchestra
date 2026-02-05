# 🎵 Orchestra v2.0

**Autonomous, specification-driven multi-agent development pipeline for Claude Code.**

Orchestra coordinates specialized AI agents through a complete software development lifecycle — planning, task decomposition, development, code review, testing, integration testing, and retrospectives — with zero human intervention.

Built for **Claude Opus 4.5** running through **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)**.

---

## What's New in v2.0

- **Single Feature Builder** — paste a feature description, get it built end-to-end
- **Multi Feature Builder** — point at your docs folder, build the whole project
- **Zero permission prompts** — the orchestrator never asks "should I proceed?"
- **UI Developer Agent** — dedicated agent for frontend/UI work with Playwright-testable output
- **UI Tester Agent** — uses Playwright MCP server for automated browser testing, no human interaction
- **Integration Tester Agent** — tests cross-component boundaries per feature
- **UI detection during planning** — specs and features flag `has_ui` and `integration_required` early
- **Per-type signal directories** — signals organized by type (dev/, review/, test/, etc.) for readability
- **Integration testing in pipeline** — Phase 4.5 runs after all feature tasks pass, before AAR
- **Playwright test plans in task files** — task builder creates specific test scenarios for UI tasks

---

## How It Works

Orchestra runs on three primitives:

### Shell Script Brain (`orchestra.sh`)
The decision engine. Reads project state from signal files, determines the next action, and outputs structured commands.

### Signal-Based State Management
Agents communicate through signal files organized by type:
```
.orchestra/signals/
├── dev/          # dev-01-01-login-complete.signal
├── review/       # review-01-01-login-complete.signal
├── test/         # test-01-01-login-complete.signal
├── integration/  # 01-auth-complete.signal
├── planning/     # planning-complete.signal
├── feature/      # features-complete.signal
├── task/         # tasks-01-auth-complete.signal
└── aar/          # aar-01-auth-complete.signal
```

### On-Demand Agent Prompts
Ten agent prompts live in `agents/` and are loaded only when spawned — never embedded in the orchestrator's context.

---

## The Pipeline

```
Phase 1: PLANNING        → Constitution + Component Specs (flags UI + integration)
Phase 2: FEATURES         → Sequenced, dependency-aware features (with test plans)
Phase 3: TASKS            → Atomic tasks with Playwright plans + integration criteria
Phase 4: DEV LOOP         → Develop → Review → Test (per task, UI-aware)
Phase 4.5: INTEGRATION    → Cross-component integration tests (per feature)
Phase 5: AAR              → After Action Reports with full metrics
```

### Phase 4 State Machine (Per Task)

```
Happy Path:
  [no signals] → dev:COMPLETE → review:APPROVED → test:PASSED ✅

UI Task Path:
  [no signals] → ui-dev:COMPLETE → review:APPROVED (checks data-testid) → ui-test:PASSED ✅

Review Rejection:
  dev:COMPLETE → review:REJECTED → dev:FIXED → cleanup → fresh review

Test Failure:
  review:APPROVED → test:FAILED → dev:FIXED → cleanup → fresh review + test

Escalation:
  3+ cycles → ESCALATE to user
```

---

## Agents

| Agent | Role | Signal Directory |
| --- | --- | --- |
| **Planning** | Constitution + specs (flags UI/integration) | `signals/planning/` |
| **Feature** | Decomposes specs into features with test plans | `signals/feature/` |
| **Task Builder** | Creates tasks with Playwright plans + integration criteria | `signals/task/` |
| **Developer** | Backend code + unit tests (fresh/review-fix/test-fix modes) | `signals/dev/` |
| **UI Developer** | Frontend code with `data-testid` attributes | `signals/dev/` |
| **Code Reviewer** | Reviews code, integration steps, UI testability | `signals/review/` |
| **Tester** | Functional tests for non-UI tasks | `signals/test/` |
| **UI Tester** | Playwright browser tests for UI tasks | `signals/test/` |
| **Integration Tester** | Cross-component boundary tests per feature | `signals/integration/` |
| **Task Reviewer** | After Action Reports with full metrics | `signals/aar/` |

---

## Quick Start

### Prerequisites
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** installed
- **Claude Max / Pro / Team / Enterprise** subscription

### Option A: Build a Single Feature

```bash
# Copy orchestra files to your project
cp -r /path/to/orchestra/orchestra.sh .
cp -r /path/to/orchestra/agents ./agents

# Open Claude Code and paste SINGLE_FEATURE_BUILDER.md
# followed by your feature description
```

### Option B: Build an Entire Project

```bash
# Copy orchestra files
cp -r /path/to/orchestra/orchestra.sh .
cp -r /path/to/orchestra/agents ./agents

# Add your project docs
mkdir docs
# Add requirements.md, architecture.md, etc.

# Open Claude Code and paste MULTI_FEATURE_BUILDER.md
# OR paste CLAUDE_CODE_ORCHESTRATOR.md
```

From there, it runs hands-free.

---

## Architecture

```
CLAUDE_CODE_ORCHESTRATOR.md        ← Slim dispatcher prompt
prompts/
├── SINGLE_FEATURE_BUILDER.md      ← One feature → full pipeline
└── MULTI_FEATURE_BUILDER.md       ← Full project → autonomous build
orchestra.sh                       ← Decision-making brain
agents/
├── planning-agent.md              ← Constitution + specs
├── feature-agent.md               ← Features with test plans
├── task-builder-agent.md          ← Tasks with Playwright plans
├── developer-agent.md             ← Backend code (4 modes)
├── ui-developer-agent.md          ← Frontend code + data-testid
├── code-reviewer-agent.md         ← Reviews + integration + UI checks
├── tester-agent.md                ← Functional tests
├── ui-tester-agent.md             ← Playwright browser tests
├── integration-tester-agent.md    ← Cross-component tests
└── task-reviewer-agent.md         ← After Action Reports
.orchestra/                        ← Created at runtime
├── constitution.md
├── specs/
├── features/
├── tasks/
├── reviews/
├── tests/
├── aar/
├── signals/
│   ├── dev/
│   ├── review/
│   ├── test/
│   ├── integration/
│   ├── planning/
│   ├── feature/
│   ├── task/
│   └── aar/
├── secrets.env
└── tmp/
```

---

## How Sub-Agents Are Spawned

```bash
# Generate the prompt file
./orchestra.sh spawn developer .orchestra/tasks/01-01-login.task.md 01-01-login

# Spawn via stdin pipe
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
