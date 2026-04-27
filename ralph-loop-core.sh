#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║   ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗                        ║
# ║  ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝                        ║
# ║  ██║     ██║     ███████║██║   ██║██║  ██║█████╗                          ║
# ║  ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝                          ║
# ║  ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗                        ║
# ║   ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝                        ║
# ║                                                                           ║
# ║  ██████╗  █████╗ ██╗     ██████╗ ██╗  ██╗    ██╗      ██████╗  ██████╗ ██████╗  ║
# ║  ██╔══██╗██╔══██╗██║     ██╔══██╗██║  ██║    ██║     ██╔═══██╗██╔═══██╗██╔══██╗ ║
# ║  ██████╔╝███████║██║     ██████╔╝███████║    ██║     ██║   ██║██║   ██║██████╔╝ ║
# ║  ██╔══██╗██╔══██║██║     ██╔═══╝ ██╔══██║    ██║     ██║   ██║██║   ██║██╔═══╝  ║
# ║  ██║  ██║██║  ██║███████╗██║     ██║  ██║    ███████╗╚██████╔╝╚██████╔╝██║      ║
# ║  ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝  ╚═╝    ╚══════╝ ╚═════╝  ╚═════╝ ╚═╝      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# BMAD Ralph Loop - Autonomous Development Workflow Automation
# ==============================================================
# Automates the development loop: SM create-story -> DEV dev-story -> DEV code-review
#
# Usage:
#   claude-ralph-loop              # Process all pending stories
#   codex-ralph-loop               # Same workflow using Codex
#   claude-ralph-loop --dry-run    # Preview without executing
#   claude-ralph-loop --epic 1     # Process only epic 1
#   claude-ralph-loop --story 1-1  # Process specific story
#
# Repository: https://github.com/NathanJ60/bmad-ralph-loop
# License: MIT
#

set -e

SOURCE_PATH="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
    SOURCE_PATH="$(realpath "$SOURCE_PATH")"
elif command -v readlink >/dev/null 2>&1; then
    SOURCE_PATH="$(readlink -f "$SOURCE_PATH" 2>/dev/null || echo "$SOURCE_PATH")"
fi
CORE_SCRIPT_PATH="$SOURCE_PATH"
CORE_SCRIPT_DIR="$(cd "$(dirname "$CORE_SCRIPT_PATH")" && pwd)"

if [[ -z "${RALPH_LIB_DIR:-}" ]]; then
    if [[ -d "$CORE_SCRIPT_DIR/ralph-loop-lib" ]]; then
        RALPH_LIB_DIR="$CORE_SCRIPT_DIR/ralph-loop-lib"
    else
        RALPH_LIB_DIR="$CORE_SCRIPT_DIR/lib"
    fi
fi
export RALPH_LIB_DIR

# =============================================================================
# Configuration
# =============================================================================

# Auto-detect project root (can be overridden with RALPH_PROJECT_ROOT)
if [[ -n "$RALPH_PROJECT_ROOT" ]]; then
    PROJECT_ROOT="$RALPH_PROJECT_ROOT"
else
    PROJECT_ROOT="$(pwd)"
fi

# Output directories (BMAD-compatible structure)
BMAD_OUTPUT="$PROJECT_ROOT/_bmad-output"
PLANNING_ARTIFACTS="$BMAD_OUTPUT/planning-artifacts"
IMPLEMENTATION_ARTIFACTS="$BMAD_OUTPUT/implementation-artifacts"

# Sprint status file (can be overridden with RALPH_SPRINT_STATUS)
if [[ -n "$RALPH_SPRINT_STATUS" ]]; then
    SPRINT_STATUS="$RALPH_SPRINT_STATUS"
else
    SPRINT_STATUS="$IMPLEMENTATION_ARTIFACTS/sprint-status.yaml"
fi

# Logging
LOG_DIR="${RALPH_LOG_DIR:-$PROJECT_ROOT/logs}"
LOG_FILE="$LOG_DIR/ralph-$(date +%Y%m%d-%H%M%S).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Flags
DRY_RUN=false
ASSUME_YES=false
NOTIFY_BELL=false
SPECIFIC_EPIC=""
SPECIFIC_STORY=""
SKIP_CODE_REVIEW=false
SKIP_RETRO="${RALPH_SKIP_RETRO:-false}"
VERBOSE=false
SHUTDOWN_REQUESTED=false
SHUTDOWN_SIGNAL=""
STOP_NOW_REQUESTED=false
CONTROL_PAUSED=false
CONTROL_FILE_LAST_MTIME=0
CONTROL_FILE_LAST_COMMAND=""

# Provider selection (claude|codex)
PROVIDER="${PROVIDER:-claude}"

# Codex options (only used when PROVIDER=codex)
CODEX_FULL_AUTO="${RALPH_CODEX_FULL_AUTO:-true}"
CODEX_SANDBOX="${RALPH_CODEX_SANDBOX:-}"
CODEX_MODEL="${RALPH_CODEX_MODEL:-}"
CODEX_SEARCH="${RALPH_CODEX_SEARCH:-false}"
WORKFLOW_RETRY_LIMIT="${RALPH_WORKFLOW_RETRY_LIMIT:-2}"
AUTO_RETROSPECTIVE="${RALPH_AUTO_RETROSPECTIVE:-true}"
MAX_REVIEW_PASSES="${RALPH_MAX_REVIEW_PASSES:-5}"
REVIEW_REPEAT_LIMIT="${RALPH_REVIEW_REPEAT_LIMIT:-2}"
PROMPT_ON_FAILURE="${RALPH_PROMPT_ON_FAILURE:-false}"
AUTO_PUSH_EPIC="${RALPH_AUTO_PUSH_EPIC:-true}"
NOTIFY_BELL="${RALPH_NOTIFY_BELL:-$NOTIFY_BELL}"
EPIC_PUSH_REMOTE="${RALPH_EPIC_PUSH_REMOTE:-}"
CONCURRENCY="${RALPH_CONCURRENCY:-1}"
WORKER_MODE="${RALPH_WORKER_MODE:-false}"
WORKER_STORY="${RALPH_WORKER_STORY:-}"
WORKER_RESULT_FILE="${RALPH_WORKER_RESULT_FILE:-}"
KEEP_WORKTREES_ON_SUCCESS="${RALPH_KEEP_WORKTREES_ON_SUCCESS:-false}"
KEEP_WORKTREES_ON_FAILURE="${RALPH_KEEP_WORKTREES_ON_FAILURE:-true}"
PROJECT_PARENT="$(cd "$PROJECT_ROOT/.." 2>/dev/null && pwd || echo "$PROJECT_ROOT")"
RUNTIME_ROOT="${RALPH_RUNTIME_ROOT:-$PROJECT_PARENT/.ralph-runtime/$(basename "$PROJECT_ROOT")}"
WORKTREE_ROOT="${RALPH_WORKTREE_ROOT:-$RUNTIME_ROOT/worktrees}"
RESULT_ROOT="${RALPH_RESULT_ROOT:-$RUNTIME_ROOT/results}"
WORKFLOW_IDLE_TIMEOUT="${RALPH_WORKFLOW_IDLE_TIMEOUT:-7200}"
WORKER_IDLE_TIMEOUT="${RALPH_WORKER_IDLE_TIMEOUT:-10800}"
CONTROL_FILE="${RALPH_CONTROL_FILE:-$RUNTIME_ROOT/control}"

# =============================================================================
# Helper Functions
# =============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Ensure log directory exists
    mkdir -p "$LOG_DIR"

    # Log to file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    # Log to console with colors
    case "$level" in
        INFO)  echo -e "${BLUE}[i]${NC} $message" ;;
        OK)    echo -e "${GREEN}[+]${NC} $message" ;;
        WARN)  echo -e "${YELLOW}[!]${NC} $message" ;;
        ERROR) echo -e "${RED}[x]${NC} $message" ;;
        STEP)  echo -e "${CYAN}[>]${NC} $message" ;;
    esac
}

notify_controller_completion() {
    if [[ "$WORKER_MODE" == "true" || "$NOTIFY_BELL" != "true" ]]; then
        return 0
    fi

    if [[ -w /dev/tty ]]; then
        printf '\a' > /dev/tty
    else
        printf '\a'
    fi
}

banner() {
    echo ""
    echo -e "${MAGENTA}"
    echo "  ____        _         _       _"
    echo " |  _ \\ __ _ | |_ __ _ | |__   | |    ___   ___  _ __"
    echo " | |_) / _\` || | '_ \` || '_ \  | |   / _ \\ / _ \\| '_ \\"
    echo " |  _ < (_| || | |_) || | | | | |__| (_) | (_) | |_) |"
    echo " |_| \\_\\__,_||_| .__/ |_| |_| |_____\\___/ \\___/| .__/"
    echo "               |_|                             |_|"
    echo -e "${NC}"
    echo -e "${CYAN}  Autonomous Development Workflow Automation${NC}"
    echo ""
}

usage() {
    local cli_name
    cli_name="$(basename "$0")"
    echo "Usage: $cli_name [OPTIONS]"
    echo ""
    case "$PROVIDER" in
        claude)
            echo "Automate your BMAD development workflow with Claude Code CLI."
            ;;
        codex)
            echo "Automate your BMAD development workflow with OpenAI Codex CLI."
            ;;
        *)
            echo "Automate your BMAD development workflow with the selected agent CLI."
            ;;
    esac
    echo "Orchestrates the full story lifecycle: create -> implement -> review"
    echo ""
    echo "Options:"
    echo "  --dry-run           Preview actions without executing"
    echo "  --yes, -y           Skip the implementation confirmation prompt"
    echo "  --bell              Ring the terminal bell when the controller exits"
    echo "  --epic N            Process only stories from epic N"
    echo "  --story X-Y         Process specific story (e.g., 1-1)"
    echo "  --skip-review       Skip code-review step"
    echo "  --skip-retro        Skip retrospective prompt when epics complete"
    echo "  --verbose           Show detailed agent output"
    echo "  --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $cli_name                # Process all pending stories"
    echo "  $cli_name --yes          # Run without asking for confirmation"
    echo "  $cli_name --bell         # Ring the terminal bell on completion"
    echo "  $cli_name --dry-run      # Preview what would happen"
    echo "  $cli_name --epic 1       # Process only Epic 1 stories"
    echo "  $cli_name --story 1-2    # Process only story 1-2"
    echo ""
    echo "Environment Variables:"
    echo "  RALPH_PROJECT_ROOT    Project root directory (default: current dir)"
    echo "  RALPH_SPRINT_STATUS   Path to sprint-status.yaml"
    echo "  RALPH_LOG_DIR         Directory for log files"
    echo "  RALPH_SKIP_RETRO      Skip retrospective prompt (true/false)"
    echo "  RALPH_AUTO_RETROSPECTIVE Automatically run retrospective on epic completion (default: true)"
    echo "  RALPH_MAX_REVIEW_PASSES Maximum review/dev loops before aborting (default: 5)"
    echo "  RALPH_REVIEW_REPEAT_LIMIT Consecutive identical review findings before aborting as looped churn (default: 2)"
    echo "  RALPH_PROMPT_ON_FAILURE Prompt before continuing after failures (default: false)"
    echo "  RALPH_AUTO_PUSH_EPIC  Push the current branch when an epic completes (default: true)"
    echo "  RALPH_NOTIFY_BELL    Ring the terminal bell when the controller exits (default: false)"
    echo "  RALPH_EPIC_PUSH_REMOTE Remote to use for automatic epic pushes (default: current upstream)"
    echo "  RALPH_CONCURRENCY     Number of stories to process in parallel (default: 1)"
    echo "  RALPH_RUNTIME_ROOT    Shared runtime root for parallel worker state"
    echo "  RALPH_WORKTREE_ROOT   Directory for parallel story worktrees"
    echo "  RALPH_RESULT_ROOT     Directory for parallel worker result files"
    echo "  RALPH_KEEP_WORKTREES_ON_SUCCESS Keep successful worker worktrees (default: false)"
    echo "  RALPH_KEEP_WORKTREES_ON_FAILURE Keep failed worker worktrees (default: true)"
    echo "  RALPH_WORKFLOW_IDLE_TIMEOUT Fail a provider workflow after this many idle seconds (default: 7200)"
    echo "  RALPH_WORKER_IDLE_TIMEOUT Fail a parallel worker after this many idle seconds (default: 10800)"
    echo "  RALPH_CONTROL_FILE    Runtime control file for pause/resume/drain/stop commands"
    if [[ "$PROVIDER" == "codex" ]]; then
        echo "  RALPH_CODEX_FULL_AUTO Use --full-auto with codex exec (default: true)"
        echo "  RALPH_CODEX_SANDBOX   Codex sandbox mode (e.g., danger-full-access)"
        echo "  RALPH_CODEX_MODEL     Codex model override (optional)"
        echo "  RALPH_CODEX_SEARCH    Enable codex --search (default: false)"
    fi
    echo ""
    echo "Documentation: https://github.com/YOUR_USERNAME/claude-ralph-loop"
    echo ""
}

normalize_provider() {
    PROVIDER="$(echo "$PROVIDER" | tr '[:upper:]' '[:lower:]')"
}

validate_provider() {
    case "$PROVIDER" in
        claude|codex) return 0 ;;
        *)
            log ERROR "Unsupported provider: $PROVIDER (use claude or codex)"
            exit 1
            ;;
    esac
}

check_dependencies() {
    log INFO "Checking dependencies..."

    local missing=()

    # Check provider CLI
    case "$PROVIDER" in
        claude)
            if ! command -v claude &> /dev/null; then
                missing+=("claude (Claude Code CLI)")
            fi
            ;;
        codex)
            if ! command -v codex &> /dev/null; then
                missing+=("codex (OpenAI Codex CLI)")
            fi
            ;;
    esac

    # Check if yq is available (for YAML parsing)
    if ! command -v yq &> /dev/null; then
        missing+=("yq (YAML processor)")
    fi

    # Check bash version
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        log WARN "Bash version ${BASH_VERSION} detected. Version 4+ recommended."
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log ERROR "Missing dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        echo ""
        echo "Install with:"
        if [[ "$PROVIDER" == "claude" ]]; then
            echo "  Claude Code CLI: Install from https://claude.ai"
        else
            echo "  OpenAI Codex CLI: Install from OpenAI documentation"
        fi
        echo "  yq:     brew install yq (macOS) or snap install yq (Linux)"
        exit 1
    fi

    log OK "All dependencies found"
}

check_sprint_status() {
    if [[ ! -f "$SPRINT_STATUS" ]]; then
        log WARN "sprint-status.yaml not found at: $SPRINT_STATUS"
        echo ""
        echo -e "${YELLOW}Sprint status file doesn't exist yet.${NC}"
        echo "You need to run sprint-planning first or create it manually."
        echo ""
        echo "Options:"
        echo "  1) Run sprint-planning now (requires SM agent)"
        echo "  2) Exit and create manually"
        echo ""
        read -p "Choose [1/2]: " choice

        case "$choice" in
            1)
                log STEP "Running sprint-planning workflow..."
                run_agent_workflow "SM" "sprint-planning" "Initialize sprint status"

                if [[ ! -f "$SPRINT_STATUS" ]]; then
                    log ERROR "sprint-status.yaml still not found after running sprint-planning"
                    exit 1
                fi
                ;;
            *)
                log INFO "Exiting. Create sprint-status.yaml manually or run sprint-planning."
                echo ""
                echo "See: examples/sprint-status.example.yaml"
                exit 0
                ;;
        esac
    fi

    log OK "Found sprint-status.yaml"
}

validate_numeric_setting() {
    local name="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log ERROR "$name must be a non-negative integer (got: $value)"
        exit 1
    fi
}

for ralph_lib_file in \
    "$RALPH_LIB_DIR/runtime.sh" \
    "$RALPH_LIB_DIR/review-loop.sh" \
    "$RALPH_LIB_DIR/parallel.sh"; do
    if [[ ! -f "$ralph_lib_file" ]]; then
        echo "Error: required Ralph library not found: $ralph_lib_file" >&2
        return 1 2>/dev/null || exit 1
    fi

    # shellcheck source=/dev/null
    source "$ralph_lib_file"
done
unset ralph_lib_file


# =============================================================================
# Core Functions
# =============================================================================

run_agent_workflow() {
    local agent="$1"
    local workflow="$2"
    local description="$3"
    local extra_context="${4:-}"
    local capture_file="${5:-}"

    log STEP "[$agent] Running: $workflow"
    log INFO "Description: $description"

    if [[ "$DRY_RUN" == "true" ]]; then
        log WARN "[DRY-RUN] Would execute: $PROVIDER with /$agent -> $workflow"
        return 0
    fi

    # Build the prompt for the agent
    local prompt="Load the $agent agent and execute the $workflow workflow. $extra_context"

    if [[ "$workflow" == "code-review" ]]; then
        prompt="$prompt

CRITICAL: Run in fully autonomous mode. Do NOT ask questions or wait for user input. Choose reasonable defaults when options are presented. Complete the entire workflow without stopping for confirmations.

REVIEW MODE: This is a read-only review gate. Do NOT modify repository files, story files, sprint tracking files, or generated artifacts during review. Inspect the current implementation, report whether another dev pass is required, and finish with the required RALPH_REVIEW_RESULT line."
    else
        prompt="$prompt

CRITICAL: Run in fully autonomous mode. Do NOT ask questions or wait for user input. Auto-fix any issues found. Choose reasonable defaults when options are presented. Complete the entire workflow without stopping for confirmations."
    fi

    if [[ "$workflow" == "code-review" ]]; then
        prompt="$prompt

REVIEW LOOP CONTRACT:
- If review is clean and no additional implementation work is needed, print exactly: RALPH_REVIEW_RESULT=clean
- If review finds issues that need another dev pass, or if you make repository changes during review, print exactly: RALPH_REVIEW_RESULT=changes-required
- The RALPH_REVIEW_RESULT line must be the final line of your response."
    fi

    local exit_code=0
    local max_attempts=1
    local attempt=1
    local tmp_capture=""
    local effective_capture_file="$capture_file"

    if [[ "$PROVIDER" == "codex" && "$WORKFLOW_RETRY_LIMIT" -gt 0 ]]; then
        max_attempts=$((WORKFLOW_RETRY_LIMIT + 1))
    fi

    if [[ -z "$effective_capture_file" ]]; then
        tmp_capture="$(mktemp "${TMPDIR:-/tmp}/ralph-workflow-${workflow}.XXXXXX")"
        effective_capture_file="$tmp_capture"
    fi

    while true; do
        # Run provider with the workflow
        case "$PROVIDER" in
            claude)
                local claude_cmd=("claude" "--print" "--dangerously-skip-permissions" "$prompt")

                if run_command_with_watchdog "$workflow" "$effective_capture_file" "${claude_cmd[@]}"; then
                    exit_code=0
                else
                    exit_code=$?
                fi
                ;;
            codex)
                local codex_args=("exec")

                if [[ "$CODEX_FULL_AUTO" == "true" ]]; then
                    codex_args+=("--full-auto")
                fi

                if [[ "$CODEX_SEARCH" == "true" ]]; then
                    codex_args+=("--search")
                fi

                if [[ -n "$CODEX_SANDBOX" ]]; then
                    codex_args+=("--sandbox" "$CODEX_SANDBOX")
                fi

                if [[ -n "$CODEX_MODEL" ]]; then
                    codex_args+=("--model" "$CODEX_MODEL")
                fi

                local codex_cmd=("codex" "${codex_args[@]}" "$prompt")

                if run_command_with_watchdog "$workflow" "$effective_capture_file" "${codex_cmd[@]}"; then
                    exit_code=0
                else
                    exit_code=$?
                fi
                ;;
        esac

        if [[ $exit_code -eq 0 ]]; then
            break
        fi

        if [[ "$PROVIDER" != "codex" || "$attempt" -ge "$max_attempts" ]]; then
            break
        fi

        if ! is_transient_provider_failure "$effective_capture_file"; then
            break
        fi

        log WARN "Transient provider failure detected for $workflow (attempt $attempt/$max_attempts). Retrying..."
        attempt=$((attempt + 1))
        sleep 5
    done

    if [[ -n "$tmp_capture" ]]; then
        rm -f "$tmp_capture"
    fi

    if [[ $exit_code -eq 0 ]]; then
        log OK "Workflow completed: $workflow"
    else
        log ERROR "Workflow failed: $workflow (exit code: $exit_code)"
        return $exit_code
    fi
}

verify_story_file_created() {
    local story_key="$1"
    local story_file
    story_file="$(get_story_file_path "$story_key")"

    if [[ -f "$story_file" ]]; then
        log OK "Story file verified: $story_file"
        return 0
    else
        log ERROR "Story file NOT created: $story_file"
        log ERROR "create-story workflow failed silently!"
        return 1
    fi
}

get_story_directory() {
    local configured_path=""

    configured_path="$(yq -r '.story_location // ""' "$SPRINT_STATUS" 2>/dev/null || true)"

    if [[ -z "$configured_path" || "$configured_path" == "null" ]]; then
        echo "$IMPLEMENTATION_ARTIFACTS"
    elif [[ "$configured_path" = /* ]]; then
        echo "$configured_path"
    else
        echo "$PROJECT_ROOT/$configured_path"
    fi
}

get_story_file_path() {
    local story_key="$1"
    local story_dir
    story_dir="$(get_story_directory)"
    echo "$story_dir/${story_key}.md"
}


verify_implementation() {
    local story_key="$1"

    # Check git status for recent changes
    local changes=$(cd "$PROJECT_ROOT" && git status --porcelain 2>/dev/null | grep -E '^\s*[AM]' | wc -l)

    if [[ "$changes" -gt 0 ]]; then
        log OK "Implementation verified: $changes file(s) modified"
        return 0
    else
        log WARN "No file changes detected for implementation"
        return 0
    fi
}

should_continue_after_failure() {
    local prompt_text="$1"

    if [[ "$PROMPT_ON_FAILURE" != "true" ]]; then
        log WARN "Failure encountered. Continuing automatically (RALPH_PROMPT_ON_FAILURE=false)."
        return 0
    fi

    echo ""
    read -p "$prompt_text [Y/n]: " continue_choice
    if [[ "$continue_choice" =~ ^[Nn] ]]; then
        return 1
    fi

    return 0
}

unstage_paths() {
    local reason="$1"
    shift
    local paths=("$@")

    if [[ ${#paths[@]} -eq 0 ]]; then
        return 0
    fi

    if git reset -q HEAD -- "${paths[@]}" 2>/dev/null; then
        log INFO "Excluded $reason from commit: ${#paths[@]} file(s)"
        return 0
    fi

    if git restore --staged -- "${paths[@]}" >/dev/null 2>&1; then
        log INFO "Excluded $reason from commit: ${#paths[@]} file(s)"
        return 0
    fi

    log ERROR "Failed to exclude $reason from commit staging"
    return 1
}

unstage_paths_matching_regex() {
    local reason="$1"
    local regex="$2"
    local matches=()
    local path=""

    while IFS= read -r -d '' path; do
        if [[ "$path" =~ $regex ]]; then
            matches+=("$path")
        fi
    done < <(git diff --cached --name-only -z 2>/dev/null)

    unstage_paths "$reason" "${matches[@]}"
}

unstage_ralph_logs() {
    unstage_paths_matching_regex "Ralph logs" '(^|/)ralph-[0-9]{8}-[0-9]{6}\.log$'
}

unstage_codex_runtime_files() {
    unstage_paths_matching_regex "Codex runtime files" '(^|/)\.codex$'
}

unstage_retry_context_files() {
    if git diff --cached --quiet -- .ralph/previous-attempt 2>/dev/null; then
        return 0
    fi

    unstage_paths "parallel retry context" ".ralph/previous-attempt"
}

unstage_worker_commit_noise() {
    local story_dir_rel=""
    local current_story_rel=""
    local repo_sprint_status_rel=""
    local path=""
    local base=""
    local exclusions=()

    if [[ "$WORKER_MODE" != "true" || -z "$SPECIFIC_STORY" ]]; then
        return 0
    fi

    story_dir_rel="$(get_repo_relative_path "$(get_story_directory)")"
    current_story_rel="$(get_repo_relative_path "$(get_story_file_path "$SPECIFIC_STORY")")"
    repo_sprint_status_rel="$(get_repo_relative_path "$IMPLEMENTATION_ARTIFACTS/sprint-status.yaml")"

    while IFS= read -r -d '' path; do
        if [[ -n "$repo_sprint_status_rel" && "$path" == "$repo_sprint_status_rel" ]]; then
            exclusions+=("$path")
            continue
        fi

        if [[ -n "$story_dir_rel" && "$path" == "$story_dir_rel/"*.md ]]; then
            base="${path##*/}"
            if [[ "$base" =~ ^[0-9]+-[0-9]+.*\.md$ && "$path" != "$current_story_rel" ]]; then
                exclusions+=("$path")
            fi
        fi
    done < <(git diff --cached --name-only -z 2>/dev/null)

    unstage_paths "worker-only story metadata" "${exclusions[@]}"
}

summarize_staged_files() {
    git diff --cached --name-only 2>/dev/null | head -10 | tr '\n' ', ' | sed 's/,$//'
}

commit_changes() {
    local subject="$1"
    local label="$2"
    local dry_run_description="$3"
    local modified_files=""

    if [[ "$DRY_RUN" == "true" ]]; then
        log WARN "[DRY-RUN] Would commit $dry_run_description"
        return 0
    fi

    cd "$PROJECT_ROOT"

    git add -A

    if ! unstage_ralph_logs; then
        return 1
    fi

    if ! unstage_codex_runtime_files; then
        return 1
    fi

    if ! unstage_retry_context_files; then
        return 1
    fi

    if ! unstage_worker_commit_noise; then
        return 1
    fi

    modified_files="$(summarize_staged_files)"

    if git diff --cached --quiet; then
        log WARN "No changes to commit for $label"
        return 0
    fi

    if git commit -m "$(cat <<EOF
$subject

Files: $modified_files
EOF
)"; then
        log OK "Committed: $label"
    else
        log ERROR "Commit failed for $label"
        return 1
    fi
}

commit_story_changes() {
    local story_key="$1"
    local epic_num="$2"

    log STEP "Committing changes for $story_key..."
    commit_changes "feat(epic-$epic_num): implement $story_key" "$story_key" "changes for $story_key"
}

commit_epic_changes() {
    local epic_num="$1"
    local epic_key="epic-$epic_num"

    log STEP "Committing epic completion changes for $epic_key..."
    commit_changes "chore(epic-$epic_num): complete $epic_key" "$epic_key" "epic completion for $epic_key"
}

push_epic_changes() {
    local epic_num="$1"
    local epic_key="epic-$epic_num"
    local current_branch=""
    local configured_remote="$EPIC_PUSH_REMOTE"
    local remotes=()

    if [[ "$AUTO_PUSH_EPIC" != "true" ]]; then
        log INFO "Skipping automatic push for $epic_key (RALPH_AUTO_PUSH_EPIC=false)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log WARN "[DRY-RUN] Would push changes for $epic_key"
        return 0
    fi

    cd "$PROJECT_ROOT"

    current_branch="$(git branch --show-current 2>/dev/null || true)"
    if [[ -z "$current_branch" ]]; then
        log WARN "Skipping automatic push for $epic_key: current branch could not be determined"
        return 0
    fi

    if [[ -n "$configured_remote" ]]; then
        if ! git remote get-url "$configured_remote" >/dev/null 2>&1; then
            log ERROR "Configured epic push remote not found: $configured_remote"
            return 1
        fi

        if git push -u "$configured_remote" "$current_branch"; then
            log OK "Pushed $epic_key to $configured_remote/$current_branch"
            return 0
        fi

        log ERROR "Push failed for $epic_key via $configured_remote/$current_branch"
        return 1
    fi

    if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        if git push; then
            log OK "Pushed $epic_key to the configured upstream branch"
            return 0
        fi

        log ERROR "Push failed for $epic_key via the configured upstream branch"
        return 1
    fi

    while IFS= read -r remote_name; do
        [[ -n "$remote_name" ]] && remotes+=("$remote_name")
    done < <(git remote)

    if [[ ${#remotes[@]} -eq 1 ]]; then
        log WARN "No upstream branch configured. Pushing $epic_key to ${remotes[0]}/$current_branch."
        if git push -u "${remotes[0]}" "$current_branch"; then
            log OK "Pushed $epic_key to ${remotes[0]}/$current_branch"
            return 0
        fi

        log ERROR "Push failed for $epic_key via ${remotes[0]}/$current_branch"
        return 1
    fi

    log WARN "Skipping automatic push for $epic_key: no upstream branch configured and remote target is ambiguous"
    return 0
}

update_story_status() {
    local story_key="$1"
    local new_status="$2"
    local update_result=0

    log INFO "Updating status: $story_key -> $new_status"

    if [[ "$DRY_RUN" == "true" ]]; then
        log WARN "[DRY-RUN] Would update $story_key to $new_status"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$SPRINT_STATUS" "$story_key" "$new_status" <<'PY' || update_result=$?
from __future__ import annotations

from datetime import datetime
from pathlib import Path
import re
import sys


status_path = Path(sys.argv[1])
story_key = sys.argv[2]
new_status = sys.argv[3]
text = status_path.read_text(encoding="utf-8")

status_pattern = re.compile(rf"^(\s*{re.escape(story_key)}:\s*).*$", re.MULTILINE)
updated_text, replacements = status_pattern.subn(rf"\1{new_status}", text, count=1)
if replacements == 0:
    raise SystemExit(2)

timestamp = datetime.now().astimezone().replace(microsecond=0).isoformat()
last_updated_pattern = re.compile(r"^(last_updated:\s*)(['\"]?).*?\2\s*$", re.MULTILINE)

def replace_last_updated(match: re.Match[str]) -> str:
    quote = match.group(2)
    return f"{match.group(1)}{quote}{timestamp}{quote}"

updated_text, _ = last_updated_pattern.subn(replace_last_updated, updated_text, count=1)

status_path.write_text(updated_text, encoding="utf-8")
PY
    else
        update_result=2
    fi

    if [[ "$update_result" -ne 0 ]]; then
        log WARN "Falling back to yq status update for $story_key; file formatting may change."
        yq -yi ".development_status.\"$story_key\" = \"$new_status\"" "$SPRINT_STATUS"
    fi

    log OK "Status updated: $story_key = $new_status"
}

get_story_status() {
    local story_key="$1"
    local status
    status="$(yq -r ".development_status.\"$story_key\"" "$SPRINT_STATUS" 2>/dev/null || echo "unknown")"
    if [[ -z "$status" || "$status" == "null" ]]; then
        echo "unknown"
    else
        echo "$status"
    fi
}

resolve_story_key() {
    local selector="$1"
    local exact_match=""
    local prefix_matches=()
    local line=""

    exact_match="$(yq -r ".development_status.\"$selector\"" "$SPRINT_STATUS" 2>/dev/null || true)"
    if [[ -n "$exact_match" && "$exact_match" != "null" ]]; then
        echo "$selector"
        return 0
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] && prefix_matches+=("$line")
    done < <(yq -r ".development_status | keys | .[] | select(test(\"^${selector}-\"))" "$SPRINT_STATUS" 2>/dev/null)

    if [[ "${#prefix_matches[@]}" -eq 1 ]]; then
        echo "${prefix_matches[0]}"
        return 0
    fi

    return 1
}

get_pending_stories() {
    # Get all stories with status: backlog, ready-for-dev, or review
    # Filter out epic entries and retrospectives
    yq -r '.development_status | to_entries | .[] | select(.value == "backlog" or .value == "ready-for-dev" or .value == "review") | select(.key | test("^[0-9]+-[0-9]+")) | .key' "$SPRINT_STATUS" 2>/dev/null
}

get_epic_for_story() {
    local story_key="$1"
    # Extract epic number from story key (e.g., "1-2" -> "1")
    echo "$story_key" | cut -d'-' -f1
}

process_story() {
    local story_key="$1"
    local epic_num=$(get_epic_for_story "$story_key")
    local current_status=$(get_story_status "$story_key")
    local review_pass=0
    local retry_context_prompt=""
    local create_story_context=""
    local dev_story_context=""
    local before_fingerprint=""
    local after_fingerprint=""
    local previous_review_fingerprint=""
    local repeated_review_count=0

    retry_context_prompt="$(get_retry_context_prompt)"
    create_story_context="The story to create is $story_key from Epic $epic_num."
    dev_story_context="The story to implement is $story_key."
    if [[ -n "$retry_context_prompt" ]]; then
        create_story_context+=$'\n\n'"$retry_context_prompt"
        dev_story_context+=$'\n\n'"$retry_context_prompt"
    fi

    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN}  Processing Story: $story_key${NC} (Epic $epic_num)"
    echo -e "${CYAN}============================================================${NC}"
    log INFO "Current status: $current_status"

    # Update epic status to in-progress if not already
    local epic_key="epic-$epic_num"
    local epic_status=$(get_story_status "$epic_key")
    if [[ "$epic_status" == "backlog" ]]; then
        update_story_status "$epic_key" "in-progress"
    fi

    # Step 1: Create Story (SM agent)
    if [[ "$current_status" == "backlog" ]]; then
        log STEP "[1/3] Creating story file..."
        if ! run_agent_workflow "SM" "create-story" "Create story file for $story_key" "$create_story_context"; then
            log ERROR "Aborting: create-story failed for $story_key"
            return 1
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            log INFO "[1/3] Dry run: skipping story file verification and status update"
            current_status="ready-for-dev"
        else
            # Verify story file was actually created
            if ! verify_story_file_created "$story_key"; then
                log ERROR "Aborting: Story file verification failed for $story_key"
                return 1
            fi

            update_story_status "$story_key" "ready-for-dev"
            current_status="ready-for-dev"
        fi
    else
        log INFO "[1/3] Story file already exists, skipping create-story"
    fi

    while true; do
        # Step 2: Implement Story (DEV agent)
        if [[ "$current_status" == "ready-for-dev" ]]; then
            if [[ "$review_pass" -gt 0 ]]; then
                log INFO "Re-entering dev-story after code review feedback (next pass: $((review_pass + 1)))"
            fi
            log STEP "[2/3] Implementing story..."
            before_fingerprint="$(capture_worktree_fingerprint)"
            if ! run_agent_workflow "DEV" "dev-story" "Implement story $story_key" "$dev_story_context"; then
                log ERROR "Aborting: dev-story failed for $story_key"
                return 1
            fi
            after_fingerprint="$(capture_worktree_fingerprint)"

            verify_implementation "$story_key"
            if [[ "$before_fingerprint" == "$after_fingerprint" ]]; then
                log WARN "No repository changes detected during dev-story for $story_key"
            fi

            update_story_status "$story_key" "review"
            current_status="review"
        else
            log INFO "[2/3] Story already implemented, skipping dev-story"
        fi

        # Step 3: Code Review (DEV agent)
        if [[ "$current_status" == "review" && "$SKIP_CODE_REVIEW" == "false" ]]; then
            local review_outcome=0
            local next_review_pass=0
            local review_cap_with_final_verification=0

            next_review_pass=$((review_pass + 1))
            review_cap_with_final_verification=$((MAX_REVIEW_PASSES + 1))

            if [[ "$next_review_pass" -gt "$review_cap_with_final_verification" ]]; then
                log ERROR "Review loop exceeded $MAX_REVIEW_PASSES pass(es) plus one final verification review for $story_key"
                log ERROR "Inspect the workflow output or raise RALPH_MAX_REVIEW_PASSES if the loop is intentional."
                return 1
            fi

            review_pass="$next_review_pass"
            log STEP "[3/3] Running code review (pass $review_pass/$MAX_REVIEW_PASSES)..."
            if run_code_review_gate "$story_key" "$review_pass" "$previous_review_fingerprint" "$repeated_review_count"; then
                review_outcome=0
            else
                review_outcome=$?
            fi

            previous_review_fingerprint="$REVIEW_LOOP_LAST_FINGERPRINT"
            repeated_review_count="$REVIEW_LOOP_REPEAT_COUNT"

            case "$review_outcome" in
                0)
                    update_story_status "$story_key" "done"
                    current_status="done"
                    ;;
                1)
                    if [[ "$review_pass" -gt "$MAX_REVIEW_PASSES" ]]; then
                        log ERROR "Final verification review still requested another dev pass for $story_key after $MAX_REVIEW_PASSES completed review cycle(s)."
                        log ERROR "Inspect the latest review findings before continuing."
                        return 1
                    fi
                    update_story_status "$story_key" "ready-for-dev"
                    current_status="ready-for-dev"
                    continue
                    ;;
                3)
                    log ERROR "Aborting: repeated review findings indicate looped churn for $story_key"
                    return 1
                    ;;
                *)
                    log ERROR "Aborting: code review failed for $story_key"
                    return 1
                    ;;
            esac
        elif [[ "$current_status" == "review" && "$SKIP_CODE_REVIEW" == "true" ]]; then
            log WARN "[3/3] Skipping code review (--skip-review flag)"
            update_story_status "$story_key" "done"
            current_status="done"
        fi

        if [[ "$current_status" == "done" ]]; then
            break
        fi

        log ERROR "Unexpected story status after processing: $current_status"
        return 1
    done

    # Step 4: Commit changes
    commit_story_changes "$story_key" "$epic_num"

    log OK "Story $story_key completed!"
    echo ""
}

check_epic_completion() {
    local epic_num="$1"
    local epic_key="epic-$epic_num"
    local epic_status
    local retrospective_key="${epic_key}-retrospective"
    local retrospective_status

    # Count stories in this epic that are not done
    local pending=$(yq ".development_status | to_entries | .[] | select(.key | test(\"^${epic_num}-\")) | select(.value != \"done\") | .key" "$SPRINT_STATUS" 2>/dev/null | wc -l)

    if [[ "$pending" -eq 0 ]]; then
        epic_status="$(get_story_status "$epic_key")"
        retrospective_status="$(get_story_status "$retrospective_key")"

        if [[ "$epic_status" == "done" && ( "$SKIP_RETRO" == "true" || "$AUTO_RETROSPECTIVE" != "true" || "$retrospective_status" == "done" ) ]]; then
            log INFO "Epic $epic_num is already finalized"
            return 0
        fi

        log OK "Epic $epic_num completed! All stories are done."
        update_story_status "$epic_key" "done"

        if [[ "$SKIP_RETRO" == "true" ]]; then
            log INFO "Skipping retrospective (--skip-retro)"
        elif [[ "$AUTO_RETROSPECTIVE" == "true" ]]; then
            log INFO "Running retrospective automatically for Epic $epic_num"
            if ! run_agent_workflow "SM" "retrospective" "Run retrospective for Epic $epic_num"; then
                log ERROR "Retrospective failed for Epic $epic_num"
                return 1
            fi
            update_story_status "${epic_key}-retrospective" "done"
        else
            log INFO "Skipping retrospective for Epic $epic_num (RALPH_AUTO_RETROSPECTIVE=false)"
        fi

        commit_epic_changes "$epic_num"
        push_epic_changes "$epic_num"
    fi
}


# =============================================================================
# Main Execution
# =============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --yes|-y)
                ASSUME_YES=true
                shift
                ;;
            --bell)
                NOTIFY_BELL=true
                shift
                ;;
            --epic)
                SPECIFIC_EPIC="$2"
                shift 2
                ;;
            --story)
                SPECIFIC_STORY="$2"
                shift 2
                ;;
            --skip-review)
                SKIP_CODE_REVIEW=true
                shift
                ;;
            --skip-retro)
                SKIP_RETRO=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log ERROR "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [[ -n "$WORKER_STORY" && -z "$SPECIFIC_STORY" ]]; then
        SPECIFIC_STORY="$WORKER_STORY"
    fi

    validate_numeric_setting "RALPH_CONCURRENCY" "$CONCURRENCY"
    validate_numeric_setting "RALPH_MAX_REVIEW_PASSES" "$MAX_REVIEW_PASSES"
    validate_numeric_setting "RALPH_REVIEW_REPEAT_LIMIT" "$REVIEW_REPEAT_LIMIT"
    validate_numeric_setting "RALPH_WORKFLOW_IDLE_TIMEOUT" "$WORKFLOW_IDLE_TIMEOUT"
    validate_numeric_setting "RALPH_WORKER_IDLE_TIMEOUT" "$WORKER_IDLE_TIMEOUT"

    if [[ "$DRY_RUN" == "true" && "$CONCURRENCY" -gt 1 ]]; then
        log WARN "Parallel execution is disabled during dry-run previews; falling back to sequential planning mode."
        CONCURRENCY=1
    fi

    if [[ "$CONCURRENCY" -gt 1 ]] && ! bash_supports_parallel_mode; then
        log ERROR "Parallel mode requires Bash 4.3+ (current: $BASH_VERSION)"
        exit 1
    fi

    # Setup
    normalize_provider
    validate_provider
    banner
    mkdir -p "$LOG_DIR"

    log INFO "Project root: $PROJECT_ROOT"
    log INFO "Provider: $PROVIDER"
    log INFO "Log file: $LOG_FILE"
    if [[ "$WORKER_MODE" != "true" ]]; then
        mkdir -p "$(dirname "$CONTROL_FILE")"
        CONTROL_FILE_LAST_MTIME="$(file_mtime_epoch "$CONTROL_FILE" 2>/dev/null || echo 0)"
        CONTROL_FILE_LAST_COMMAND="$(read_controller_command 2>/dev/null || true)"
        log INFO "Controller PID: $$"
        log INFO "Control file: $CONTROL_FILE"
        trap 'request_controller_shutdown TERM' TERM
        trap 'request_controller_shutdown INT' INT
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}  [DRY-RUN MODE] No changes will be made${NC}"
        echo ""
    fi

    if [[ "$WORKER_MODE" == "true" ]]; then
        worker_main
        return $?
    fi

    # Pre-flight checks
    check_dependencies
    check_sprint_status

    # Get stories to process
    local stories=()

    if [[ -n "$SPECIFIC_STORY" ]]; then
        local resolved_story=""
        if ! resolved_story="$(resolve_story_key "$SPECIFIC_STORY")"; then
            log ERROR "Could not resolve story selector '$SPECIFIC_STORY' to a unique story key in $SPRINT_STATUS"
            exit 1
        fi
        stories=("$resolved_story")
        log INFO "Processing single story: $resolved_story (requested: $SPECIFIC_STORY)"
    elif [[ -n "$SPECIFIC_EPIC" ]]; then
        stories=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && stories+=("$line")
        done < <(yq -r ".development_status | to_entries | .[] | select(.key | test(\"^${SPECIFIC_EPIC}-\")) | select(.value == \"backlog\" or .value == \"ready-for-dev\" or .value == \"review\") | .key" "$SPRINT_STATUS" 2>/dev/null)
        log INFO "Processing Epic $SPECIFIC_EPIC stories: ${#stories[@]} found"
    else
        stories=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && stories+=("$line")
        done < <(get_pending_stories)
        log INFO "Processing all pending stories: ${#stories[@]} found"
    fi

    if [[ ${#stories[@]} -eq 0 ]]; then
        log OK "No pending stories to process!"
        echo ""
        echo "All stories are either completed or in progress."
        echo "Check sprint-status.yaml for current state."
        notify_controller_completion
        exit 0
    fi

    # Show plan
    echo ""
    echo -e "${CYAN}Stories to process:${NC}"
    for story in "${stories[@]}"; do
        local status=$(get_story_status "$story")
        echo "  - $story ($status)"
    done
    echo ""

    if [[ "$DRY_RUN" == "false" && "$ASSUME_YES" != "true" ]]; then
        read -p "Proceed with implementation? [Y/n]: " confirm
        if [[ "$confirm" =~ ^[Nn] ]]; then
            log INFO "Aborted by user"
            notify_controller_completion
            exit 0
        fi
    fi

    if parallel_mode_enabled; then
        log INFO "Parallel mode enabled (RALPH_CONCURRENCY=$CONCURRENCY)"
        run_parallel_stories "${stories[@]}"
        local parallel_status=$?
        notify_controller_completion
        return "$parallel_status"
    fi

    # Process each story
    local processed=0
    local failed=0
    local current_epic=""

    for story in "${stories[@]}"; do
        poll_controller_control_file

        if controller_paused; then
            wait_while_controller_paused
        fi

        if controller_stop_requested; then
            log WARN "Immediate stop requested. Stopping before launching story $story."
            break
        fi

        if controller_shutdown_requested; then
            log WARN "Graceful shutdown requested. Stopping before launching story $story."
            break
        fi

        local epic_num=$(get_epic_for_story "$story")

        # Track epic changes for retrospective
        if [[ "$current_epic" != "$epic_num" && -n "$current_epic" ]]; then
            if ! check_epic_completion "$current_epic"; then
                failed=$((failed + 1))
                log ERROR "Failed to finalize epic: $current_epic"

                if ! should_continue_after_failure "Continue after epic finalization failure?"; then
                    break
                fi
            fi
        fi
        current_epic="$epic_num"

        if process_story "$story"; then
            processed=$((processed + 1))
        else
            if controller_stop_requested; then
                log WARN "Immediate stop requested while processing story: $story"
                break
            fi
            failed=$((failed + 1))
            log ERROR "Failed to process story: $story"

            if ! should_continue_after_failure "Continue with next story after failure?"; then
                break
            fi
        fi
    done

    # Final epic check
    if [[ -n "$current_epic" && "$STOP_NOW_REQUESTED" != "true" ]]; then
        if ! check_epic_completion "$current_epic"; then
            failed=$((failed + 1))
            log ERROR "Failed to finalize epic: $current_epic"
        fi
    fi

    # Summary
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN}                  Implementation Summary${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo -e "  ${GREEN}[+] Processed:${NC} $processed stories"
    if [[ $failed -gt 0 ]]; then
        echo -e "  ${RED}[x] Failed:${NC}    $failed stories"
    fi
    if controller_shutdown_requested || controller_stop_requested; then
        local pending_after_shutdown=$(( ${#stories[@]} - processed - failed ))
        if [[ "$pending_after_shutdown" -gt 0 ]]; then
            echo -e "  ${YELLOW}[!] Deferred:${NC}  $pending_after_shutdown stories"
        fi
    fi
    echo -e "  ${BLUE}[i] Log:${NC}       $LOG_FILE"
    echo ""

    if [[ $failed -gt 0 ]]; then
        notify_controller_completion
        exit 1
    fi

    if controller_stop_requested; then
        log WARN "Immediate stop completed."
        notify_controller_completion
        exit 130
    fi

    if controller_shutdown_requested; then
        log WARN "Graceful shutdown completed after the current story finished."
        notify_controller_completion
        exit 130
    fi

    notify_controller_completion
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
