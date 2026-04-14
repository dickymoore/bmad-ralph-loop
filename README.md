# BMAD Ralph Loop

[![MIT License](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Made%20with-Bash-1f425f.svg)](https://www.gnu.org/software/bash/)
[![Claude Code](https://img.shields.io/badge/For-Claude%20Code-blueviolet)](https://claude.ai)
[![BMAD Method](https://img.shields.io/badge/BMAD-Method-orange)](https://github.com/bmad-method)

> **Automate your BMAD development workflow with Claude Code CLI or OpenAI Codex CLI**

BMAD Ralph Loop is a CLI automation tool that orchestrates development cycles using Claude Code CLI or OpenAI Codex CLI and the BMAD Method agents. It manages the complete story lifecycle: from story creation by the Scrum Master agent, through implementation by the Developer agent, to code review and follow-up rework until the story is clean — all running autonomously.

![Demo](docs/assets/demo.gif)
*Demo placeholder - Record your own workflow!*

---

## Features

- **Autonomous Development Loop** — Runs the full cycle: create-story → dev-story → code-review, looping review feedback back into dev-story until clean
- **BMAD Method Integration** — Built for the BMAD (BMad Agile Development) methodology
- **Multi-Agent Orchestration** — Coordinates SM (Scrum Master) and DEV (Developer) agents
- **Sprint Status Tracking** — YAML-based status management with automatic updates
- **Intelligent Story Processing** — Handles backlog, ready-for-dev, review, and done states, including review-to-dev retries
- **Epic Management** — Automatic epic completion detection, retrospectives, and end-of-epic branch sync
- **Parallel Story Workers** — Optional worktree-based parallel execution with dependency-aware scheduling
- **Dry-Run Mode** — Preview all actions before execution
- **Selective Processing** — Target specific epics or individual stories
- **Auto-Commit** — Commits each story and finalizes each completed epic with a dedicated commit
- **Log-Safe Commits** — Excludes Ralph runtime logs from Ralph-generated commits
- **Verbose Logging** — Detailed logs for debugging and audit trails

---

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/NathanJ60/bmad-ralph-loop.git
cd claude-ralph-loop

# 2. Install
./install.sh

# 3. Run in your project
cd /path/to/your/project
claude-ralph-loop
# or, using Codex
codex-ralph-loop
```

---

## Installation

### Prerequisites

- **Claude Code CLI** — [Install from claude.ai](https://claude.ai)
- **OpenAI Codex CLI** — [Install from OpenAI docs](https://developers.openai.com/codex/cli)
- **yq** — YAML processor
- **Bash 4+** — Modern bash shell (`Bash 4.3+` required for parallel mode)

Install at least one provider CLI (Claude or Codex).

### Via Install Script (Recommended)

```bash
git clone https://github.com/NathanJ60/bmad-ralph-loop.git
cd claude-ralph-loop
./install.sh
```

### Manual Installation

```bash
# Clone
git clone https://github.com/NathanJ60/bmad-ralph-loop.git

# Make executable
chmod +x claude-ralph-loop/claude-ralph-loop.sh claude-ralph-loop/codex-ralph-loop.sh

# Add to PATH (choose one). Keep the core and wrappers together.
sudo cp claude-ralph-loop/ralph-loop-core.sh /usr/local/bin/ralph-loop-core.sh
sudo cp claude-ralph-loop/claude-ralph-loop.sh /usr/local/bin/claude-ralph-loop
sudo cp claude-ralph-loop/codex-ralph-loop.sh /usr/local/bin/codex-ralph-loop
# OR (user-only)
cp claude-ralph-loop/ralph-loop-core.sh ~/bin/ralph-loop-core.sh
cp claude-ralph-loop/claude-ralph-loop.sh ~/bin/claude-ralph-loop
cp claude-ralph-loop/codex-ralph-loop.sh ~/bin/codex-ralph-loop
```

### Install Dependencies

```bash
# macOS
brew install yq

# Linux (Debian/Ubuntu)
sudo apt install yq

# Linux (snap)
sudo snap install yq
```

---

## Usage

```bash
claude-ralph-loop [OPTIONS]
# or
codex-ralph-loop [OPTIONS]
```

### Options

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview actions without executing |
| `--epic N` | Process only stories from epic N |
| `--story X-Y` | Process a specific story (e.g., `1-2`) |
| `--skip-review` | Skip the code-review step |
| `--skip-retro` | Skip retrospective prompt when epics complete |
| `--verbose` | Show detailed agent output |
| `--help` | Display help message |

### Examples

```bash
# Process all pending stories
claude-ralph-loop

# Preview what would happen
claude-ralph-loop --dry-run

# Process only Epic 2 stories
claude-ralph-loop --epic 2

# Process a single story
claude-ralph-loop --story 1-3

# Fast mode: skip code review
claude-ralph-loop --skip-review

# Debug mode: see all output
claude-ralph-loop --verbose

# Use Codex instead of Claude
codex-ralph-loop

# Run multiple ready stories in parallel
RALPH_CONCURRENCY=3 codex-ralph-loop
```

### Choose Your CLI

Use `claude-ralph-loop` for Claude Code CLI or `codex-ralph-loop` for OpenAI Codex CLI.

---

## Configuration

### Sprint Status File

BMAD Ralph Loop expects a `sprint-status.yaml` file in your project. Default location:

```
your-project/
└── _bmad-output/
    └── implementation-artifacts/
        └── sprint-status.yaml
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RALPH_PROJECT_ROOT` | Auto-detected | Project root directory |
| `RALPH_SPRINT_STATUS` | `_bmad-output/implementation-artifacts/sprint-status.yaml` | Path to sprint status |
| `RALPH_LOG_DIR` | `logs/` | Directory for log files |
| `RALPH_SKIP_RETRO` | `false` | Skip retrospective prompt when epics complete |
| `RALPH_AUTO_RETROSPECTIVE` | `true` | Run retrospectives automatically when an epic completes |
| `RALPH_MAX_REVIEW_PASSES` | `5` | Maximum review/dev loops before Ralph aborts a story |
| `RALPH_PROMPT_ON_FAILURE` | `false` | Ask before continuing after failures |
| `RALPH_AUTO_PUSH_EPIC` | `true` | Push the current branch when an epic completes |
| `RALPH_EPIC_PUSH_REMOTE` | Current upstream | Override the remote used for automatic epic pushes |
| `RALPH_CONCURRENCY` | `1` | Number of stories to process in parallel |
| `RALPH_RUNTIME_ROOT` | `../.ralph-runtime/<repo>` | Shared runtime root for parallel worker state |
| `RALPH_WORKTREE_ROOT` | `$RALPH_RUNTIME_ROOT/worktrees` | Parallel worker git worktrees |
| `RALPH_RESULT_ROOT` | `$RALPH_RUNTIME_ROOT/results` | Parallel worker result and console logs |
| `RALPH_KEEP_WORKTREES_ON_SUCCESS` | `false` | Keep successful worker worktrees for inspection |
| `RALPH_KEEP_WORKTREES_ON_FAILURE` | `true` | Keep failed worker worktrees for debugging |
| `RALPH_WORKFLOW_IDLE_TIMEOUT` | `7200` | Fail a provider workflow after this many idle seconds with no new output |
| `RALPH_WORKER_IDLE_TIMEOUT` | `10800` | Fail a parallel worker after this many idle seconds with no new output |
| `RALPH_CONTROL_FILE` | `$RALPH_RUNTIME_ROOT/control` | Runtime control file for `pause`, `resume`, `drain`, or `stop` |

### Sprint Status Format

```yaml
# sprint-status.yaml
sprint_info:
  sprint_number: 1
  sprint_goal: "MVP Implementation"

development_status:
  epic-1: "in-progress"
  1-1: "done"
  1-2: "ready-for-dev"
  1-3: "backlog"
  epic-2: "backlog"
  2-1: "backlog"
  2-2: "backlog"
```

See [examples/sprint-status.example.yaml](examples/sprint-status.example.yaml) for a complete example.

### Parallel Mode

Set `RALPH_CONCURRENCY` above `1` to enable worktree-based parallel execution. Ralph keeps the main repo as the controller, launches one worker branch/worktree per runnable story, merges completed worker commits back serially, and only finalizes epics on the controller branch.

Parallel mode has a few safety rules:
- The authoritative project worktree must be clean except for Ralph log files.
- `RALPH_WORKTREE_ROOT` and `RALPH_RESULT_ROOT` must stay outside the project repository.
- Absolute `story_location` values must point inside the project repo; Ralph remaps them into each worker worktree automatically.
- Story dependencies in `sprint-status.yaml` must be `done` before a dependent story will launch.
- Failed worker integrations keep the worker worktree for inspection and leave the authoritative story status unchanged.
- Stale provider workflows and parallel workers are failed automatically once their idle timeout expires, so a wedged CLI does not block the entire run forever.
- When a story is retried, Ralph attaches the latest kept worktree for that story under `.ralph/previous-attempt/` inside the new worker so the agent can salvage useful prior work.
- The wrapper scripts run from a per-run snapshot of `ralph-loop-core.sh`, so editing the repo copy while Ralph is active will not corrupt the live run.
- Ralph prints both the controller PID and control-file path at startup. You can send `TERM` to the controller PID for a graceful drain, or write commands to the control file while the run is active.

### Runtime Control File

Ralph polls `RALPH_CONTROL_FILE` while it is running. Update the file with one of these commands:

```bash
echo pause > /path/to/control
echo resume > /path/to/control
echo drain > /path/to/control
echo stop > /path/to/control
```

- `pause`: stop launching new stories, but let already-running work continue
- `resume`: start launching eligible stories again
- `drain`: stop launching new stories and exit after active work finishes
- `stop`: terminate active work and exit without integrating unfinished stories

Ralph ignores stale control-file contents from before the current run. You must rewrite the file during the active run for a command to take effect.

---

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                    BMAD Ralph Loop                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐  │
│   │ BACKLOG │ ──▶ │ READY   │ ──▶ │ REVIEW  │ ──▶ │  DONE   │  │
│   │         │     │ FOR DEV │     │         │     │         │  │
│   └─────────┘     └─────────┘     └─────────┘     └─────────┘  │
│        │               │               │               │        │
│        ▼               ▼               ▼               ▼        │
│   ┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐  │
│   │   SM    │     │   DEV   │     │   DEV   │     │  AUTO   │  │
│   │ create  │     │  dev    │     │  code   │     │ COMMIT  │  │
│   │ -story  │     │ -story  │     │ -review │     │         │  │
│   └─────────┘     └─────────┘     └─────────┘     └─────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Workflow Steps

1. **Story Creation (SM Agent)**
   - Reads epic requirements from planning artifacts
   - Creates detailed story file with acceptance criteria
   - Updates status: `backlog` → `ready-for-dev`

2. **Story Implementation (DEV Agent)**
   - Reads story file and implements requirements
   - Writes code, tests, and documentation
   - Updates status: `ready-for-dev` → `review`

3. **Code Review (DEV Agent)**
   - Reviews implementation against story requirements
   - Can make fixes or request another dev pass
   - Updates status: `review` → `ready-for-dev` when follow-up work is needed, otherwise `review` → `done`

4. **Auto-Commit**
   - Commits all changes with conventional commit format
   - Message: `feat(epic-N): implement X-Y`

5. **Epic Finalization**
   - Marks the epic complete when all stories are done
   - Runs the retrospective automatically by default
   - Creates a final epic completion commit and pushes the branch

---

## BMAD Method Integration

BMAD Ralph Loop **automates Step 3: Build Your Project** from the [BMAD Method](https://github.com/bmad-method/BMAD-METHOD) — a structured approach to AI-assisted software development.

### Where BMAD Ralph Loop Fits

```
BMAD Method Workflow:
├── Phase 1: Discovery (BA Agent)
├── Phase 2: Planning (PM Agent)
├── Phase 3: Solutioning (Architect + PM Agents)
└── Step 3: Build Your Project ◀── CLAUDE RALPH LOOP AUTOMATES THIS
    │
    ├── Sprint Planning (SM Agent)
    └── Build Cycle (repeated for each story):
        ├── create-story (SM Agent)
        ├── dev-story (DEV Agent)
        └── code-review (DEV Agent, loops back to dev-story until clean)
```

### The Build Cycle

In the BMAD Method, each story goes through this cycle:

| Step | Agent | Workflow | Purpose |
|------|-------|----------|---------|
| 1 | SM | `create-story` | Create story file from epic |
| 2 | DEV | `dev-story` | Implement the story |
| 3 | DEV | `code-review` | Quality validation and dev-loop feedback |

**BMAD Ralph Loop automates this entire cycle**, running each workflow autonomously for every pending story until review is clean.

### Prerequisites

Before using BMAD Ralph Loop, complete the BMAD planning phases:
1. **Phase 1**: Run BA agent workflows (discovery, analysis)
2. **Phase 2**: Run PM agent workflows (PRD creation)
3. **Phase 3**: Run Architect + PM workflows (architecture, epics & stories)
4. **Initialize Sprint**: Run SM agent `sprint-planning` workflow

Then let BMAD Ralph Loop handle the implementation automation.

### Expected Artifacts

The tool expects BMAD-style artifacts:
- Epic definitions in `_bmad-output/planning-artifacts/`
- Story templates following BMAD conventions
- Sprint status tracking in `sprint-status.yaml`

---

## Requirements

| Requirement | Version | Notes |
|-------------|---------|-------|
| Claude Code CLI | Latest | Install from [claude.ai](https://claude.ai) |
| OpenAI Codex CLI | Latest | Install from [OpenAI docs](https://developers.openai.com/codex/cli) |
| yq | 4.x+ | YAML processor |
| Bash | 4.0+ | Modern bash features |
| Git | 2.x+ | For auto-commit feature |

### Check Your Setup

```bash
# Verify all dependencies (use the provider you selected)
claude --version  # Claude Code CLI
codex             # OpenAI Codex CLI (if using codex-ralph-loop)
yq --version
bash --version
git --version
```

---

## Troubleshooting

### "Claude Code CLI not found"

Install Claude Code CLI from [claude.ai](https://claude.ai)

### "Codex CLI not found"

Install OpenAI Codex CLI from [OpenAI docs](https://developers.openai.com/codex/cli)

### "yq not found"

```bash
# macOS
brew install yq

# Linux
sudo snap install yq
```

### "sprint-status.yaml not found"

Run sprint planning first or create the file manually. See [examples/sprint-status.example.yaml](examples/sprint-status.example.yaml).

### "Story file NOT created"

The SM agent failed to create the story. Check:
1. Epic definitions exist in `_bmad-output/planning-artifacts/`
2. Agent CLI has necessary permissions
3. Run with `--verbose` for detailed output

---

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Quick Contribution Guide

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'feat: add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Credits

**Author:** Nathan Jacas

**Built for:** [BMAD Method](https://github.com/bmad-method/BMAD-METHOD)

---

## Star History

If you find this useful, please star the repo!

```
         ⭐ Star this repo to support the project! ⭐
```
