# Orchestra: Specification-Driven Development with Sub-Agents

A token-efficient orchestration system for Claude Code that spawns specialized sub-agents to handle all development work while keeping the main thread lightweight.

## 🎯 Philosophy

**The Orchestrator doesn't do work—it spawns agents that do work.**

This maximizes parallelization and minimizes context window usage by delegating all substantive tasks to specialized sub-agents.

## 📁 File Structure

```
orchestra/
├── ORCHESTRATOR_PROMPT.md      # Full orchestrator instructions
├── ORCHESTRATOR_MINIMAL.md     # Token-optimized version
├── orchestra.sh                # Bash helper script
├── agents/
│   ├── planning-agent.md       # Creates constitution & specs
│   ├── feature-agent.md        # Breaks specs into features
│   ├── task-builder-agent.md   # Breaks features into tasks
│   ├── developer-agent.md      # Writes code & unit tests
│   ├── code-reviewer-agent.md  # Reviews for quality
│   ├── tester-agent.md         # Functional testing
│   └── task-reviewer-agent.md  # After Action Reports
└── README.md                   # This file
```

## 🚀 Quick Start

### 1. Setup Project

```bash
# Create your project directory
mkdir my-project && cd my-project

# Copy orchestra files
cp -r /path/to/orchestra/* .

# Create docs directory with your project documentation
mkdir docs
# Add your requirements, PRD, design docs, etc. to /docs
```

### 2. Start Orchestration

**Option A: Use the Full Prompt**
```bash
# Give Claude Code the full orchestrator prompt
cat ORCHESTRATOR_PROMPT.md
```

**Option B: Use the Minimal Prompt (Recommended)**
```bash
# For maximum token efficiency
cat ORCHESTRATOR_MINIMAL.md
```

### 3. Let It Run

The orchestrator will:
1. Initialize the `.orchestra/` structure
2. Spawn the Planning Agent to create constitution & specs
3. Spawn the Feature Agent to decompose into features
4. Spawn Task Builders for each feature
5. Run the Dev→Review→Test loop for each task
6. Generate After Action Reports

## 📊 Development Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        ORCHESTRATOR                              │
│  (Lightweight - only checks signals and spawns agents)          │
└─────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
   ┌─────────┐         ┌───────────┐         ┌──────────┐
   │Planning │    →    │ Feature   │    →    │  Task    │
   │ Agent   │         │  Agent    │         │ Builder  │
   └─────────┘         └───────────┘         └──────────┘
        │                    │                     │
        ▼                    ▼                     ▼
   constitution.md      *.feature.md          *.task.md
   *.spec.md
                              │
                              ▼
              ┌───────────────────────────────┐
              │      DEVELOPMENT LOOP         │
              │  ┌─────────────────────────┐  │
              │  │                         │  │
              │  ▼                         │  │
              │ Developer → Reviewer → Tester │
              │  │            │          │  │
              │  │   REJECT   │  FAIL    │  │
              │  └────────────┴──────────┘  │
              │         (loops until PASS)   │
              └───────────────────────────────┘
                              │
                              ▼
                    ┌──────────────┐
                    │Task Reviewer │
                    │   (AAR)      │
                    └──────────────┘
```

## 🔧 Signal System

Agents communicate via signal files in `.orchestra/signals/`:

| Signal | Created By | Means |
|--------|-----------|-------|
| `planning-complete.signal` | Planning Agent | Specs ready |
| `features-complete.signal` | Feature Agent | Features defined |
| `tasks-{feature}-complete.signal` | Task Builder | Tasks ready |
| `dev-{task}-complete.signal` | Developer | Code written |
| `review-{task}-complete.signal` | Reviewer | Contains: APPROVED/REJECTED |
| `test-{task}-complete.signal` | Tester | Contains: PASSED/FAILED |
| `aar-{feature}-complete.signal` | Task Reviewer | Report complete |
| `need-credentials-{task}.signal` | Tester | Needs API keys |

## 🎛️ Configuration

### Parallel Execution
- ✅ Task Builders for different features
- ✅ Developers for independent tasks
- ✅ AAR writers for completed features
- ❌ Dev→Review→Test must be sequential per task

### Credentials
If the Tester Agent needs API keys:
1. It creates `need-credentials-{task}.signal`
2. Orchestrator pauses and asks you
3. You provide credentials (saved to `.orchestra/secrets.env`)
4. Orchestrator re-spawns tester

## 📝 Agent Customization

Each agent prompt can be customized for your project:

- **Constitution standards**: Edit `planning-agent.md` to change what goes in the constitution
- **Feature sizing**: Edit `feature-agent.md` to change how features are scoped
- **Task granularity**: Edit `task-builder-agent.md` for different task sizes
- **Code standards**: Edit `code-reviewer-agent.md` for your review criteria
- **Test depth**: Edit `tester-agent.md` for your testing requirements

## 🔍 Monitoring Progress

```bash
# Check status
./orchestra.sh status

# View signals
ls -la .orchestra/signals/

# Check specific signal
cat .orchestra/signals/review-auth-login.signal
```

## 💡 Tips

1. **Documentation matters**: Better docs in `/docs` = better specs = better code
2. **Start small**: Try with one feature first to tune the process
3. **Watch the loop**: If Dev→Review→Test loops too many times, check constitution clarity
4. **Read the AARs**: They capture valuable lessons for process improvement

## 🚨 Troubleshooting

**Agent seems stuck?**
- Check for signal files
- Look for error output
- Re-spawn with same parameters

**Too many review cycles?**
- Constitution may be ambiguous
- Task specs may be unclear
- Developer agent may need more context

**Tests keep failing?**
- Check if tester has needed credentials
- Verify test environment setup
- Review functional test requirements in task

## 📄 License

MIT - Use freely, modify as needed.

---

Built for the [Claude Code](https://claude.ai/code) development workflow.
