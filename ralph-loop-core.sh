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

is_transient_provider_failure() {
    local capture_file="$1"

    [[ -f "$capture_file" ]] || return 1

    grep -Eqi \
        "ERROR: Reconnecting|temporary errors|currently experiencing high demand|timed out|ECONNRESET|connection reset|rate limit|429|502|503|504" \
        "$capture_file"
}

bash_supports_parallel_mode() {
    if [[ "${BASH_VERSINFO[0]}" -gt 4 ]]; then
        return 0
    fi

    if [[ "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -ge 3 ]]; then
        return 0
    fi

    return 1
}

resolve_absolute_path() {
    local path="$1"

    if [[ "$path" != /* ]]; then
        path="$PROJECT_ROOT/$path"
    fi

    if command -v realpath >/dev/null 2>&1; then
        realpath "$path" 2>/dev/null && return 0
    fi

    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$path" 2>/dev/null && return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null && return 0
    fi

    if command -v python >/dev/null 2>&1; then
        python -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null && return 0
    fi

    echo "$path"
}

get_repo_relative_path() {
    local path="$1"
    local resolved_path=""
    local resolved_project_root=""

    resolved_path="$(resolve_absolute_path "$path")"
    resolved_project_root="$(resolve_absolute_path "$PROJECT_ROOT")"

    case "$resolved_path/" in
        "$resolved_project_root/"*|"$resolved_project_root/")
            if [[ "$resolved_path" == "$resolved_project_root" ]]; then
                echo "."
            else
                echo "${resolved_path#$resolved_project_root/}"
            fi
            ;;
    esac
}

ensure_parallel_runtime_outside_repo() {
    local resolved_project_root=""
    local resolved_worktree_root=""
    local resolved_result_root=""

    resolved_project_root="$(resolve_absolute_path "$PROJECT_ROOT")"
    resolved_worktree_root="$(resolve_absolute_path "$WORKTREE_ROOT")"
    resolved_result_root="$(resolve_absolute_path "$RESULT_ROOT")"

    case "$resolved_worktree_root/" in
        "$resolved_project_root/"*|"$resolved_project_root/")
            log ERROR "RALPH_WORKTREE_ROOT must be outside the project repository in parallel mode."
            exit 1
            ;;
    esac

    case "$resolved_result_root/" in
        "$resolved_project_root/"*|"$resolved_project_root/")
            log ERROR "RALPH_RESULT_ROOT must be outside the project repository in parallel mode."
            exit 1
            ;;
    esac
}

count_entries() {
    local count=0
    local _

    for _ in "$@"; do
        count=$((count + 1))
    done

    echo "$count"
}

controller_shutdown_requested() {
    [[ "$WORKER_MODE" != "true" && "$SHUTDOWN_REQUESTED" == "true" ]]
}

controller_stop_requested() {
    [[ "$WORKER_MODE" != "true" && "$STOP_NOW_REQUESTED" == "true" ]]
}

controller_paused() {
    [[ "$WORKER_MODE" != "true" && "$CONTROL_PAUSED" == "true" ]]
}

request_controller_shutdown() {
    local signal="$1"

    if [[ "$WORKER_MODE" == "true" ]]; then
        return 0
    fi

    if [[ "$SHUTDOWN_REQUESTED" == "true" ]]; then
        return 0
    fi

    SHUTDOWN_REQUESTED=true
    SHUTDOWN_SIGNAL="$signal"
    log WARN "Received $signal. Ralph will stop launching new stories and wait for active workers to finish."
}

request_controller_stop() {
    local source="$1"

    if [[ "$WORKER_MODE" == "true" ]]; then
        return 0
    fi

    if [[ "$STOP_NOW_REQUESTED" == "true" ]]; then
        return 0
    fi

    STOP_NOW_REQUESTED=true
    SHUTDOWN_REQUESTED=true
    SHUTDOWN_SIGNAL="$source"
    log WARN "Received $source. Ralph will stop launching new stories and terminate active work."
}

request_controller_pause() {
    local source="$1"

    if [[ "$WORKER_MODE" == "true" ]]; then
        return 0
    fi

    if controller_shutdown_requested || controller_stop_requested; then
        log WARN "Ignoring pause request from $source because shutdown is already in progress."
        return 0
    fi

    if [[ "$CONTROL_PAUSED" == "true" ]]; then
        return 0
    fi

    CONTROL_PAUSED=true
    log WARN "Pause requested via $source. Ralph will stop launching new stories until resumed."
}

request_controller_resume() {
    local source="$1"

    if [[ "$WORKER_MODE" == "true" ]]; then
        return 0
    fi

    if controller_shutdown_requested || controller_stop_requested; then
        log WARN "Ignoring resume request from $source because shutdown is already in progress."
        return 0
    fi

    if [[ "$CONTROL_PAUSED" != "true" ]]; then
        return 0
    fi

    CONTROL_PAUSED=false
    log INFO "Resume requested via $source. Ralph will continue launching eligible stories."
}

file_mtime_epoch() {
    local path="$1"

    [[ -e "$path" ]] || return 1

    if stat -c %Y "$path" >/dev/null 2>&1; then
        stat -c %Y "$path"
        return 0
    fi

    if stat -f %m "$path" >/dev/null 2>&1; then
        stat -f %m "$path"
        return 0
    fi

    return 1
}

latest_file_mtime_epoch() {
    local latest=0
    local path=""
    local current=0

    for path in "$@"; do
        current="$(file_mtime_epoch "$path" 2>/dev/null || echo 0)"
        [[ "$current" =~ ^[0-9]+$ ]] || current=0
        if [[ "$current" -gt "$latest" ]]; then
            latest="$current"
        fi
    done

    echo "$latest"
}

read_controller_command() {
    [[ -f "$CONTROL_FILE" ]] || return 1

    awk '
        {
            gsub(/\r/, "")
        }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            print tolower($1)
            exit
        }
    ' "$CONTROL_FILE"
}

poll_controller_control_file() {
    local current_mtime=0
    local command=""

    if [[ "$WORKER_MODE" == "true" ]]; then
        return 0
    fi

    current_mtime="$(file_mtime_epoch "$CONTROL_FILE" 2>/dev/null || echo 0)"
    [[ "$current_mtime" =~ ^[0-9]+$ ]] || current_mtime=0

    command="$(read_controller_command 2>/dev/null || true)"

    if [[ "$current_mtime" -le "$CONTROL_FILE_LAST_MTIME" && "$command" == "$CONTROL_FILE_LAST_COMMAND" ]]; then
        return 0
    fi

    CONTROL_FILE_LAST_MTIME="$current_mtime"
    CONTROL_FILE_LAST_COMMAND="$command"

    case "$command" in
        pause)
            request_controller_pause "control file ($CONTROL_FILE)"
            ;;
        resume|run|continue)
            request_controller_resume "control file ($CONTROL_FILE)"
            ;;
        drain|shutdown)
            request_controller_shutdown "control file ($CONTROL_FILE)"
            ;;
        stop|abort)
            request_controller_stop "control file ($CONTROL_FILE)"
            ;;
        "")
            log INFO "Control file changed but contained no command. Supported commands: pause, resume, drain, stop."
            ;;
        *)
            log WARN "Ignoring unknown control command '$command' in $CONTROL_FILE. Supported commands: pause, resume, drain, stop."
            ;;
    esac
}

wait_while_controller_paused() {
    while controller_paused; do
        poll_controller_control_file

        if controller_shutdown_requested || controller_stop_requested; then
            break
        fi

        sleep 1
    done
}

list_child_pids() {
    ps -o pid= --ppid "$1" 2>/dev/null | awk '{$1=$1; print}'
}

terminate_process_tree() {
    local pid="$1"
    local signal="${2:-TERM}"
    local child=""

    while IFS= read -r child; do
        [[ -n "$child" ]] && terminate_process_tree "$child" "$signal"
    done < <(list_child_pids "$pid")

    kill "-$signal" "$pid" 2>/dev/null || true
}

force_stop_process_tree() {
    local pid="$1"
    local deadline=$(( $(date +%s) + 5 ))

    terminate_process_tree "$pid" TERM

    while kill -0 "$pid" 2>/dev/null; do
        if [[ "$(date +%s)" -ge "$deadline" ]]; then
            break
        fi
        sleep 1
    done

    if kill -0 "$pid" 2>/dev/null; then
        terminate_process_tree "$pid" KILL
    fi
}

run_command_with_watchdog() {
    local workflow_name="$1"
    local capture_file="${2:-}"
    shift 2
    local command=("$@")
    local watch_files=("$LOG_FILE")
    local runner_pid=0
    local last_activity=0
    local current_activity=0
    local now=0
    local exit_code=0
    local timed_out=false
    local interrupted_by_controller=false
    local poll_interval=1

    if [[ -n "$capture_file" ]]; then
        : > "$capture_file"
        watch_files+=("$capture_file")
    fi

    (
        if [[ "$VERBOSE" == "true" || -n "$capture_file" ]]; then
            local tee_args=("-a" "$LOG_FILE")
            if [[ -n "$capture_file" ]]; then
                tee_args+=("$capture_file")
            fi

            if [[ "$VERBOSE" == "true" ]]; then
                "${command[@]}" 2>&1 | tee "${tee_args[@]}"
            else
                "${command[@]}" 2>&1 | tee "${tee_args[@]}" >/dev/null
            fi
            exit "${PIPESTATUS[0]}"
        fi

        "${command[@]}" >> "$LOG_FILE" 2>&1
    ) &
    runner_pid=$!

    if [[ "$WORKFLOW_IDLE_TIMEOUT" -gt 0 ]]; then
        last_activity="$(latest_file_mtime_epoch "${watch_files[@]}")"
        if [[ "$last_activity" -le 0 ]]; then
            last_activity="$(date +%s)"
        fi
    fi

    while kill -0 "$runner_pid" 2>/dev/null; do
        if [[ "$WORKER_MODE" != "true" ]]; then
            poll_controller_control_file
            if controller_stop_requested; then
                log WARN "Immediate stop requested. Terminating workflow $workflow_name."
                force_stop_process_tree "$runner_pid"
                interrupted_by_controller=true
                break
            fi
        fi

        if [[ "$WORKFLOW_IDLE_TIMEOUT" -gt 0 ]]; then
            current_activity="$(latest_file_mtime_epoch "${watch_files[@]}")"
            if [[ "$current_activity" -gt "$last_activity" ]]; then
                last_activity="$current_activity"
            fi

            now="$(date +%s)"
            if [[ "$last_activity" -gt 0 && $((now - last_activity)) -ge "$WORKFLOW_IDLE_TIMEOUT" ]]; then
                log ERROR "Workflow $workflow_name exceeded the idle timeout (${WORKFLOW_IDLE_TIMEOUT}s) with no new output. Terminating the provider process."
                force_stop_process_tree "$runner_pid"
                timed_out=true
                break
            fi
        fi

        sleep "$poll_interval"
    done

    if wait "$runner_pid"; then
        exit_code=0
    else
        exit_code=$?
    fi

    if [[ "$timed_out" == "true" ]]; then
        return 124
    fi

    if [[ "$interrupted_by_controller" == "true" ]]; then
        return 130
    fi

    return "$exit_code"
}

parallel_mode_enabled() {
    if [[ "$WORKER_MODE" == "true" ]]; then
        return 1
    fi

    if [[ -n "$SPECIFIC_STORY" ]]; then
        return 1
    fi

    if [[ "$CONCURRENCY" -le 1 ]]; then
        return 1
    fi

    return 0
}

worker_last_activity_epoch() {
    local result_file="$1"
    local console_log="$2"
    local result_dir=""
    local worker_log_dir=""
    local worker_log=""
    local watch_files=()

    result_dir="$(dirname "$result_file")"
    worker_log_dir="$result_dir/logs"
    watch_files+=("$console_log" "$result_file" "$result_dir/sprint-status.yaml")

    if [[ -d "$worker_log_dir" ]]; then
        while IFS= read -r worker_log; do
            [[ -n "$worker_log" ]] && watch_files+=("$worker_log")
        done < <(find "$worker_log_dir" -maxdepth 1 -type f -name 'ralph-*.log' 2>/dev/null)
    fi

    latest_file_mtime_epoch "${watch_files[@]}"
}

worker_is_stale() {
    local result_file="$1"
    local console_log="$2"
    local last_activity=0
    local now=0

    if [[ "$WORKER_IDLE_TIMEOUT" -le 0 ]]; then
        return 1
    fi

    last_activity="$(worker_last_activity_epoch "$result_file" "$console_log")"
    if [[ "$last_activity" -le 0 ]]; then
        return 1
    fi

    now="$(date +%s)"
    [[ $((now - last_activity)) -ge "$WORKER_IDLE_TIMEOUT" ]]
}

ensure_parallel_safe_worktree() {
    local non_log_changes=""

    non_log_changes="$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | grep -Ev '^[ MARCUD?]{2} (logs/ralph-[0-9]{8}-[0-9]{6}\.log|\.codex)$' || true)"

    if [[ -n "$non_log_changes" ]]; then
        log ERROR "Parallel mode requires a clean project worktree except for Ralph logs."
        log ERROR "Clean or commit these changes before using RALPH_CONCURRENCY>1:"
        printf '%s\n' "$non_log_changes"
        exit 1
    fi
}

prepare_parallel_runtime() {
    ensure_parallel_runtime_outside_repo
    mkdir -p "$WORKTREE_ROOT" "$RESULT_ROOT"
}

prepare_worker_sprint_status() {
    local worker_sprint_status="$1"
    local worktree_dir="$2"
    local configured_story_location=""
    local resolved_story_location=""
    local resolved_project_root=""
    local worker_story_location=""

    configured_story_location="$(yq -r '.story_location // ""' "$worker_sprint_status" 2>/dev/null || true)"

    if [[ -z "$configured_story_location" || "$configured_story_location" == "null" ]]; then
        return 0
    fi

    if [[ "$configured_story_location" != /* ]]; then
        return 0
    fi

    resolved_story_location="$(resolve_absolute_path "$configured_story_location")"
    resolved_project_root="$(resolve_absolute_path "$PROJECT_ROOT")"

    case "$resolved_story_location/" in
        "$resolved_project_root/"*|"$resolved_project_root/")
            worker_story_location="$worktree_dir${resolved_story_location#$resolved_project_root}"
            yq -yi ".story_location = \"$worker_story_location\"" "$worker_sprint_status"
            return 0
            ;;
    esac

    log ERROR "Parallel mode requires story_location to be relative or under the project root (got: $configured_story_location)"
    return 1
}

find_latest_story_result_dir() {
    local story_key="$1"
    local current_result_dir="${2:-}"
    local result_dir=""
    local latest_result_dir=""

    while IFS= read -r result_dir; do
        [[ -z "$result_dir" ]] && continue
        [[ -n "$current_result_dir" && "$result_dir" == "$current_result_dir" ]] && continue
        latest_result_dir="$result_dir"
    done < <(find "$RESULT_ROOT" -maxdepth 1 -mindepth 1 -type d -name "${story_key}-*" 2>/dev/null | sort)

    [[ -n "$latest_result_dir" ]] && echo "$latest_result_dir"
}

copy_retry_context_untracked_files() {
    local previous_worktree="$1"
    local destination_root="$2"
    local path=""

    mkdir -p "$destination_root"

    while IFS= read -r -d '' path; do
        case "$path" in
            .codex|.codex/*|.ralph/previous-attempt|.ralph/previous-attempt/*|logs/ralph-*.log)
                continue
                ;;
        esac

        [[ -e "$previous_worktree/$path" ]] || continue
        mkdir -p "$destination_root/$(dirname "$path")"
        cp -a "$previous_worktree/$path" "$destination_root/$path"
    done < <(git -C "$previous_worktree" ls-files --others --exclude-standard -z 2>/dev/null)
}

prepare_retry_context() {
    local story_key="$1"
    local current_result_dir="$2"
    local worktree_dir="$3"
    local previous_result_dir=""
    local previous_result_file=""
    local previous_result_status="unknown"
    local previous_commit_sha=""
    local previous_log_file=""
    local previous_worktree=""
    local context_dir=""
    local previous_story_rel=""
    local previous_story_path=""
    local copied_untracked_root=""

    previous_result_dir="$(find_latest_story_result_dir "$story_key" "$current_result_dir")"
    [[ -n "$previous_result_dir" ]] || return 0

    previous_result_file="$previous_result_dir/result.env"
    if [[ -f "$previous_result_file" ]]; then
        unset RALPH_WORKER_RESULT_STATUS RALPH_WORKER_RESULT_COMMIT_SHA
        unset RALPH_WORKER_RESULT_LOG_FILE RALPH_WORKER_RESULT_WORKTREE
        # shellcheck disable=SC1090
        source "$previous_result_file"
        previous_result_status="${RALPH_WORKER_RESULT_STATUS:-unknown}"
        previous_commit_sha="${RALPH_WORKER_RESULT_COMMIT_SHA:-}"
        previous_log_file="${RALPH_WORKER_RESULT_LOG_FILE:-}"
        previous_worktree="${RALPH_WORKER_RESULT_WORKTREE:-}"
    fi

    if [[ -z "$previous_worktree" ]]; then
        previous_worktree="$WORKTREE_ROOT/$(basename "$previous_result_dir")"
    fi

    if [[ ! -d "$previous_worktree" ]]; then
        log WARN "Found previous attempt metadata for $story_key but the kept worktree is missing: $previous_worktree"
        return 0
    fi

    context_dir="$worktree_dir/.ralph/previous-attempt"
    rm -rf "$context_dir"
    mkdir -p "$context_dir"

    previous_story_rel="$(get_repo_relative_path "$(get_story_file_path "$story_key")")"
    if [[ -n "$previous_story_rel" ]]; then
        previous_story_path="$previous_worktree/$previous_story_rel"
        if [[ -f "$previous_story_path" ]]; then
            cp -a "$previous_story_path" "$context_dir/story.md"
        fi
    fi

    if [[ -n "$previous_log_file" && -f "$previous_log_file" ]]; then
        tail -n 200 "$previous_log_file" > "$context_dir/previous-log-tail.txt"
    fi

    if git -C "$previous_worktree" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "$previous_worktree" status --short --untracked-files=all > "$context_dir/previous-status.txt" 2>/dev/null || true
        git -C "$previous_worktree" diff --binary > "$context_dir/previous-worktree.diff" 2>/dev/null || true
        git -C "$previous_worktree" diff --binary --cached > "$context_dir/previous-index.diff" 2>/dev/null || true

        if [[ -n "$previous_commit_sha" && "$previous_commit_sha" != "''" ]] && git -C "$previous_worktree" cat-file -e "${previous_commit_sha}^{commit}" 2>/dev/null; then
            git -C "$previous_worktree" show --stat --summary "$previous_commit_sha" > "$context_dir/previous-commit-summary.txt" 2>/dev/null || true
            git -C "$previous_worktree" show "$previous_commit_sha" > "$context_dir/previous-commit.patch" 2>/dev/null || true
        fi

        copied_untracked_root="$context_dir/untracked"
        copy_retry_context_untracked_files "$previous_worktree" "$copied_untracked_root"
        if [[ -d "$copied_untracked_root" ]] && [[ -z "$(find "$copied_untracked_root" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            rmdir "$copied_untracked_root" 2>/dev/null || true
        fi
    fi

    for path in \
        "$context_dir/previous-status.txt" \
        "$context_dir/previous-worktree.diff" \
        "$context_dir/previous-index.diff" \
        "$context_dir/previous-commit-summary.txt" \
        "$context_dir/previous-commit.patch" \
        "$context_dir/previous-log-tail.txt"; do
        [[ -s "$path" ]] || rm -f "$path"
    done

    cat > "$context_dir/README.md" <<EOF
# Previous Ralph Attempt

Ralph found a previous kept worktree for story \`$story_key\`.

- Previous result directory: \`$previous_result_dir\`
- Previous worktree: \`$previous_worktree\`
- Previous result status: \`$previous_result_status\`
- Previous commit SHA: \`${previous_commit_sha:-none}\`
- Previous log file: \`${previous_log_file:-none}\`

Use the files in this directory as reference material before starting work again. Salvage useful context, patches, and files instead of starting from scratch when that is faster.

Important:
- The authoritative repo state is still the current main worktree, not the old kept worktree.
- Do not commit anything from \`.ralph/previous-attempt\` itself.
- If \`previous-commit.patch\` exists, it is the best summary of a prior successful worker that later failed integration.
- If \`previous-worktree.diff\` or \`untracked/\` exist, they capture unfinished changes from a failed worker attempt.
EOF

    log INFO "Attached previous attempt context for $story_key from $previous_result_dir"
}

get_retry_context_prompt() {
    local context_dir="$PROJECT_ROOT/.ralph/previous-attempt"

    if [[ -f "$context_dir/README.md" ]]; then
        cat <<'EOF'
A previous Ralph attempt for this story is available under .ralph/previous-attempt/. Review that reference material before starting, salvage useful changes or patches from it when appropriate, and do not commit anything from .ralph/previous-attempt itself.
EOF
    fi
}

get_story_dependencies() {
    local story_key="$1"

    yq -r ".dependencies.\"$story_key\"[]?" "$SPRINT_STATUS" 2>/dev/null || true
}

story_dependencies_satisfied() {
    local story_key="$1"
    local dependency=""
    local dependency_status=""

    while IFS= read -r dependency; do
        [[ -z "$dependency" ]] && continue
        dependency_status="$(get_story_status "$dependency")"
        if [[ "$dependency_status" != "done" ]]; then
            return 1
        fi
    done < <(get_story_dependencies "$story_key")

    return 0
}

mark_epic_in_progress_for_story() {
    local story_key="$1"
    local epic_num=""
    local epic_key=""
    local epic_status=""

    epic_num="$(get_epic_for_story "$story_key")"
    epic_key="epic-$epic_num"
    epic_status="$(get_story_status "$epic_key")"

    if [[ "$epic_status" == "backlog" ]]; then
        update_story_status "$epic_key" "in-progress"
    fi
}

write_worker_result() {
    local result_file="$1"
    local result_status="$2"
    local story_key="$3"
    local branch_name="$4"
    local worktree_dir="$5"
    local exit_code="$6"
    local commit_sha="${7:-}"
    local worker_log_file="${8:-}"

    mkdir -p "$(dirname "$result_file")"

    {
        printf 'RALPH_WORKER_RESULT_STATUS=%q\n' "$result_status"
        printf 'RALPH_WORKER_RESULT_STORY=%q\n' "$story_key"
        printf 'RALPH_WORKER_RESULT_BRANCH=%q\n' "$branch_name"
        printf 'RALPH_WORKER_RESULT_WORKTREE=%q\n' "$worktree_dir"
        printf 'RALPH_WORKER_RESULT_EXIT_CODE=%q\n' "$exit_code"
        printf 'RALPH_WORKER_RESULT_COMMIT_SHA=%q\n' "$commit_sha"
        printf 'RALPH_WORKER_RESULT_LOG_FILE=%q\n' "$worker_log_file"
    } > "$result_file"
}

cleanup_worker_checkout() {
    local branch_name="$1"
    local worktree_dir="$2"
    local keep_checkout="$3"

    if [[ "$keep_checkout" == "true" ]]; then
        log INFO "Keeping worker worktree: $worktree_dir"
        return 0
    fi

    git -C "$PROJECT_ROOT" worktree remove --force "$worktree_dir" >/dev/null 2>&1 || true
    if [[ -n "$branch_name" ]]; then
        git -C "$PROJECT_ROOT" branch -D "$branch_name" >/dev/null 2>&1 || true
    fi
}

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

hash_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

capture_worktree_fingerprint() {
    (
        cd "$PROJECT_ROOT"

        {
            git status --porcelain=v1 2>/dev/null
            git diff --no-ext-diff --binary 2>/dev/null
            git diff --no-ext-diff --cached --binary 2>/dev/null

            while IFS= read -r -d '' file; do
                local file_hash=""
                if [[ -f "$file" ]]; then
                    file_hash="$(hash_stream < "$file")"
                else
                    file_hash="missing"
                fi
                printf 'UNTRACKED %s %s\n' "$file_hash" "$file"
            done < <(git ls-files --others --exclude-standard -z 2>/dev/null)
        } | hash_stream
    )
}

extract_review_result() {
    local capture_file="$1"
    local review_result=""

    review_result="$(grep -Eo 'RALPH_REVIEW_RESULT=(clean|changes-required)' "$capture_file" | tail -n 1 | cut -d'=' -f2 || true)"

    case "$review_result" in
        clean|changes-required)
            echo "$review_result"
            ;;
    esac
}

extract_review_findings_text() {
    local capture_file="$1"

    awk '
        /RALPH_REVIEW_RESULT=/ { exit }
        /^\*\*Findings\*\*$/ { capture=1 }
        capture == 0 && /^[[:space:]]*[0-9]+\.[[:space:]]+(High|Medium|Low):/ { capture=1 }
        capture == 1 {
            if ($0 ~ /^hook: Stop/) {
                exit
            }
            print
        }
    ' "$capture_file"
}

capture_review_findings_fingerprint() {
    local capture_file="$1"
    local findings_text=""

    findings_text="$(extract_review_findings_text "$capture_file")"
    [[ -n "$findings_text" ]] || return 0

    printf '%s\n' "$findings_text" \
        | sed -E \
            -e 's/\[[^]]+\]\([^)]*\)/LINK/g' \
            -e 's#/home/[^ )]+#PATH#g' \
            -e 's/[0-9]+/N/g' \
            -e 's/[[:space:]]+/ /g' \
            -e 's/^ //g' \
            -e 's/ $//g' \
        | hash_stream
}

code_review_requires_dev() {
    local story_key="$1"
    local review_pass="$2"
    local previous_review_fingerprint="${3:-}"
    local previous_repeat_count="${4:-0}"
    local before_fingerprint=""
    local after_fingerprint=""
    local review_capture=""
    local review_result=""
    local review_findings_fingerprint=""

    REVIEW_LOOP_LAST_FINGERPRINT=""
    REVIEW_LOOP_REPEAT_COUNT=0
    REVIEW_LOOP_STUCK=false

    before_fingerprint="$(capture_worktree_fingerprint)"
    review_capture="$(mktemp "${TMPDIR:-/tmp}/ralph-review-${story_key}-${review_pass}.XXXXXX")"

    if ! run_agent_workflow "DEV" "code-review" "Review implementation for story $story_key" "Review the changes made for story $story_key. Follow the review loop contract so Ralph can decide whether to run dev-story again." "$review_capture"; then
        rm -f "$review_capture"
        return 2
    fi

    after_fingerprint="$(capture_worktree_fingerprint)"
    review_result="$(extract_review_result "$review_capture")"
    review_findings_fingerprint="$(capture_review_findings_fingerprint "$review_capture")"
    rm -f "$review_capture"

    REVIEW_LOOP_LAST_FINGERPRINT="$review_findings_fingerprint"
    if [[ -n "$review_findings_fingerprint" && "$review_findings_fingerprint" == "$previous_review_fingerprint" ]]; then
        REVIEW_LOOP_REPEAT_COUNT=$((previous_repeat_count + 1))
    else
        REVIEW_LOOP_REPEAT_COUNT=1
    fi

    if [[ -n "$review_findings_fingerprint" && "$review_result" == "changes-required" && "$REVIEW_LOOP_REPEAT_COUNT" -ge "$REVIEW_REPEAT_LIMIT" ]]; then
        REVIEW_LOOP_STUCK=true
        log ERROR "Code review findings repeated $REVIEW_LOOP_REPEAT_COUNT consecutive pass(es) for $story_key. Likely stuck in a review loop."
        log ERROR "Inspect the latest review findings before re-running dev-story."
        return 3
    fi

    if [[ "$before_fingerprint" != "$after_fingerprint" ]]; then
        if [[ "$review_result" == "clean" ]]; then
            log WARN "Code review pass $review_pass reported clean but changed the worktree. Re-running dev-story."
            return 0
        fi

        if [[ -z "$review_result" ]]; then
            log WARN "Code review pass $review_pass changed the worktree without emitting RALPH_REVIEW_RESULT. Re-running dev-story."
        else
            log WARN "Code review pass $review_pass requested another dev pass."
        fi
        return 0
    fi

    if [[ "$review_result" == "changes-required" ]]; then
        log WARN "Code review pass $review_pass requested another dev pass."
        return 0
    fi

    if [[ -z "$review_result" ]]; then
        log WARN "Code review pass $review_pass did not emit RALPH_REVIEW_RESULT. Assuming review is clean because the worktree did not change."
    else
        log OK "Code review pass $review_pass finished cleanly."
    fi

    return 1
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
            if code_review_requires_dev "$story_key" "$review_pass" "$previous_review_fingerprint" "$repeated_review_count"; then
                review_outcome=0
            else
                review_outcome=$?
            fi

            previous_review_fingerprint="$REVIEW_LOOP_LAST_FINGERPRINT"
            repeated_review_count="$REVIEW_LOOP_REPEAT_COUNT"

            case "$review_outcome" in
                0)
                    if [[ "$review_pass" -gt "$MAX_REVIEW_PASSES" ]]; then
                        log ERROR "Final verification review still requested another dev pass for $story_key after $MAX_REVIEW_PASSES completed review cycle(s)."
                        log ERROR "Inspect the latest review findings before continuing."
                        return 1
                    fi
                    update_story_status "$story_key" "ready-for-dev"
                    current_status="ready-for-dev"
                    continue
                    ;;
                1)
                    update_story_status "$story_key" "done"
                    current_status="done"
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

        if [[ "$epic_status" == "done" && ( "$AUTO_RETROSPECTIVE" != "true" || "$retrospective_status" == "done" ) ]]; then
            log INFO "Epic $epic_num is already finalized"
            return 0
        fi

        log OK "Epic $epic_num completed! All stories are done."
        update_story_status "$epic_key" "done"

        if [[ "$AUTO_RETROSPECTIVE" == "true" ]]; then
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

worker_main() {
    local story_key="$SPECIFIC_STORY"
    local branch_name="${RALPH_WORKER_BRANCH:-}"
    local worktree_dir="${RALPH_WORKER_WORKTREE:-$PROJECT_ROOT}"
    local result_file="$WORKER_RESULT_FILE"
    local worker_exit_code=0
    local starting_head=""
    local ending_head=""
    local commit_sha=""

    normalize_provider
    validate_provider
    mkdir -p "$LOG_DIR"

    if [[ -z "$story_key" ]]; then
        log ERROR "Worker mode requires a specific story"
        return 1
    fi

    if [[ -z "$result_file" ]]; then
        log ERROR "Worker mode requires RALPH_WORKER_RESULT_FILE"
        return 1
    fi

    log INFO "Worker story: $story_key"
    log INFO "Worker branch: ${branch_name:-unknown}"
    log INFO "Worker worktree: $worktree_dir"

    check_dependencies
    check_sprint_status
    starting_head="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"

    if process_story "$story_key"; then
        ending_head="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
        if [[ -n "$ending_head" && "$ending_head" != "$starting_head" ]]; then
            commit_sha="$ending_head"
        fi
        write_worker_result "$result_file" "success" "$story_key" "$branch_name" "$worktree_dir" "0" "$commit_sha" "$LOG_FILE"
        return 0
    else
        worker_exit_code=$?
        write_worker_result "$result_file" "failed" "$story_key" "$branch_name" "$worktree_dir" "$worker_exit_code" "" "$LOG_FILE"
        return "$worker_exit_code"
    fi
}

launch_story_worker() {
    local story_key="$1"
    local launch_id=""
    local branch_name=""
    local worktree_dir=""
    local result_dir=""
    local result_file=""
    local worker_log_dir=""
    local worker_console_log=""
    local worker_args=()
    local worker_pid=0

    launch_id="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    branch_name="ralph/${story_key}-${launch_id}"
    worktree_dir="$WORKTREE_ROOT/${story_key}-${launch_id}"
    result_dir="$RESULT_ROOT/${story_key}-${launch_id}"
    result_file="$result_dir/result.env"
    worker_log_dir="$result_dir/logs"
    worker_console_log="$result_dir/worker-console.log"

    mkdir -p "$result_dir" "$worker_log_dir"
    cp "$SPRINT_STATUS" "$result_dir/sprint-status.yaml"

    if git -C "$PROJECT_ROOT" worktree add -b "$branch_name" "$worktree_dir" HEAD >/dev/null 2>&1; then
        :
    else
        log ERROR "Failed to create worker worktree for $story_key"
        return 1
    fi

    if ! prepare_worker_sprint_status "$result_dir/sprint-status.yaml" "$worktree_dir"; then
        cleanup_worker_checkout "$branch_name" "$worktree_dir" "false"
        return 1
    fi

    if ! prepare_retry_context "$story_key" "$result_dir" "$worktree_dir"; then
        cleanup_worker_checkout "$branch_name" "$worktree_dir" "false"
        return 1
    fi

    worker_args=("--story" "$story_key")
    if [[ "$SKIP_CODE_REVIEW" == "true" ]]; then
        worker_args+=("--skip-review")
    fi
    if [[ "$VERBOSE" == "true" ]]; then
        worker_args+=("--verbose")
    fi

    (
        cd "$worktree_dir"
        export PROVIDER="$PROVIDER"
        export RALPH_PROJECT_ROOT="$worktree_dir"
        export RALPH_SPRINT_STATUS="$result_dir/sprint-status.yaml"
        export RALPH_LOG_DIR="$worker_log_dir"
        export RALPH_WORKER_MODE=true
        export RALPH_WORKER_STORY="$story_key"
        export RALPH_WORKER_BRANCH="$branch_name"
        export RALPH_WORKER_WORKTREE="$worktree_dir"
        export RALPH_WORKER_RESULT_FILE="$result_file"
        export RALPH_CONCURRENCY=1
        export RALPH_AUTO_PUSH_EPIC=false
        bash "$CORE_SCRIPT_PATH" "${worker_args[@]}"
    ) >"$worker_console_log" 2>&1 &
    worker_pid=$!

    log INFO "Launched worker for $story_key on branch $branch_name (pid: $worker_pid)"

    LAUNCHED_WORKER_PID="$worker_pid"
    LAUNCHED_WORKER_BRANCH="$branch_name"
    LAUNCHED_WORKER_WORKTREE="$worktree_dir"
    LAUNCHED_WORKER_RESULT_FILE="$result_file"
    LAUNCHED_WORKER_CONSOLE_LOG="$worker_console_log"
    return 0
}

integrate_story_commit() {
    local story_key="$1"
    local commit_sha="$2"
    local _worktree_dir="$3"
    local branch_name="$4"
    local epic_num=""
    local epic_key=""
    local subject=""
    local modified_files=""

    epic_num="$(get_epic_for_story "$story_key")"
    epic_key="epic-$epic_num"
    subject="feat(epic-$epic_num): implement $story_key"

    log STEP "Integrating $story_key from $branch_name..."
    cd "$PROJECT_ROOT"

    if [[ -n "$commit_sha" ]]; then
        if git cherry-pick --no-commit "$commit_sha" >/dev/null 2>&1; then
            :
        else
            log ERROR "Cherry-pick failed for $story_key from $branch_name"
            git cherry-pick --abort >/dev/null 2>&1 || git reset --merge >/dev/null 2>&1 || true
            return 1
        fi
    else
        log INFO "Worker for $story_key produced no repository commit; recording the authoritative status update only."
    fi

    if [[ "$(get_story_status "$epic_key")" == "backlog" ]]; then
        update_story_status "$epic_key" "in-progress"
    fi
    update_story_status "$story_key" "done"
    git add "$SPRINT_STATUS"

    if ! unstage_ralph_logs; then
        git cherry-pick --abort >/dev/null 2>&1 || git reset --merge >/dev/null 2>&1 || true
        return 1
    fi

    if ! unstage_codex_runtime_files; then
        git cherry-pick --abort >/dev/null 2>&1 || git reset --merge >/dev/null 2>&1 || true
        return 1
    fi

    if git diff --cached --quiet; then
        log WARN "No staged changes remained while integrating $story_key"
        git cherry-pick --abort >/dev/null 2>&1 || git reset --merge >/dev/null 2>&1 || true
        return 1
    fi

    if [[ -n "$commit_sha" ]]; then
        if git commit -C "$commit_sha" >/dev/null 2>&1; then
            log OK "Integrated story $story_key into $(git branch --show-current 2>/dev/null || echo current branch)"
            return 0
        fi
    else
        modified_files="$(summarize_staged_files)"
        if git commit -m "$(cat <<EOF
$subject

Files: $modified_files
EOF
)"; then
            log OK "Integrated story $story_key into $(git branch --show-current 2>/dev/null || echo current branch)"
            return 0
        fi
    fi

    log ERROR "Commit failed while integrating $story_key from $branch_name"
    git cherry-pick --abort >/dev/null 2>&1 || git reset --merge >/dev/null 2>&1 || true
    return 1
}

wait_for_worker_completion() {
    local -n active_pids_ref="$1"
    local -n active_stories_ref="$2"
    local -n active_results_ref="$3"
    local -n active_worktrees_ref="$4"
    local -n active_branches_ref="$5"
    local -n active_console_logs_ref="$6"
    local -n processed_ref="$7"
    local -n failed_ref="$8"
    local -n deferred_ref="$9"

    local index=0
    local pid=0
    local wait_status=0
    local result_file=""
    local story_key=""
    local branch_name=""
    local worktree_dir=""
    local result_status=""
    local result_exit_code=""
    local result_commit_sha=""
    local result_log_file=""
    local keep_checkout="false"
    local stale_worker="false"
    local stop_requested="false"

    while true; do
        poll_controller_control_file

        if controller_stop_requested; then
            for pid in "${active_pids_ref[@]}"; do
                [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && force_stop_process_tree "$pid"
            done
        fi

        for index in "${!active_pids_ref[@]}"; do
            pid="${active_pids_ref[$index]}"
            result_file="${active_results_ref[$index]}"
            story_key="${active_stories_ref[$index]}"
            branch_name="${active_branches_ref[$index]}"
            worktree_dir="${active_worktrees_ref[$index]}"
            stale_worker="false"
            stop_requested="false"

            if kill -0 "$pid" 2>/dev/null; then
                if controller_stop_requested; then
                    stop_requested="true"
                    force_stop_process_tree "$pid"
                elif worker_is_stale "$result_file" "${active_console_logs_ref[$index]}"; then
                    stale_worker="true"
                    log ERROR "Worker for $story_key exceeded the idle timeout (${WORKER_IDLE_TIMEOUT}s) with no new output. Terminating the worker so Ralph can continue."
                    force_stop_process_tree "$pid"
                else
                    continue
                fi
            fi

            if wait "$pid"; then
                wait_status=0
            else
                wait_status=$?
            fi
            if [[ "$stale_worker" == "true" ]]; then
                wait_status=124
            fi

            result_status="failed"
            result_commit_sha=""
            result_log_file="${active_console_logs_ref[$index]}"

            if [[ -f "$result_file" ]]; then
                unset RALPH_WORKER_RESULT_STATUS RALPH_WORKER_RESULT_STORY RALPH_WORKER_RESULT_BRANCH
                unset RALPH_WORKER_RESULT_WORKTREE RALPH_WORKER_RESULT_EXIT_CODE RALPH_WORKER_RESULT_COMMIT_SHA
                unset RALPH_WORKER_RESULT_LOG_FILE
                # shellcheck disable=SC1090
                source "$result_file"
                result_status="${RALPH_WORKER_RESULT_STATUS:-failed}"
                result_exit_code="${RALPH_WORKER_RESULT_EXIT_CODE:-}"
                result_commit_sha="${RALPH_WORKER_RESULT_COMMIT_SHA:-}"
                result_log_file="${RALPH_WORKER_RESULT_LOG_FILE:-$result_log_file}"
            fi

            if controller_stop_requested || [[ "$stop_requested" == "true" ]]; then
                deferred_ref=$((deferred_ref + 1))
                log WARN "Worker stopped for $story_key due to controller stop request. Authoritative status was left unchanged."
                keep_checkout="$KEEP_WORKTREES_ON_FAILURE"
            elif [[ "$result_status" == "success" && "$result_exit_code" == "0" && "$wait_status" -ne 0 ]]; then
                log WARN "Worker for $story_key exited with status $wait_status after recording a successful result. Trusting result.env and continuing integration."
                wait_status=0
            fi

            if controller_stop_requested || [[ "$stop_requested" == "true" ]]; then
                :
            elif [[ "$wait_status" -eq 0 && "$result_status" == "success" ]]; then
                if integrate_story_commit "$story_key" "$result_commit_sha" "$worktree_dir" "$branch_name"; then
                    processed_ref=$((processed_ref + 1))
                    check_epic_completion "$(get_epic_for_story "$story_key")" || {
                        failed_ref=$((failed_ref + 1))
                        log ERROR "Failed to finalize epic after integrating $story_key"
                    }
                    keep_checkout="$KEEP_WORKTREES_ON_SUCCESS"
                else
                    failed_ref=$((failed_ref + 1))
                    keep_checkout="$KEEP_WORKTREES_ON_FAILURE"
                fi
            else
                failed_ref=$((failed_ref + 1))
                if [[ "$stale_worker" == "true" ]]; then
                    log ERROR "Worker timed out waiting for new output: ${result_log_file:-$result_file}"
                fi
                log ERROR "Worker failed for $story_key (exit code: $wait_status)"
                log ERROR "Inspect worker logs: ${result_log_file:-$result_file}"
                keep_checkout="$KEEP_WORKTREES_ON_FAILURE"
            fi

            cleanup_worker_checkout "$branch_name" "$worktree_dir" "$keep_checkout"
            unset 'active_pids_ref[$index]' 'active_stories_ref[$index]' 'active_results_ref[$index]' \
                'active_worktrees_ref[$index]' 'active_branches_ref[$index]' 'active_console_logs_ref[$index]'
            return 0
        done

        sleep 1
    done
}

run_parallel_stories() {
    local pending_stories=("$@")
    local active_pids=()
    local active_stories=()
    local active_results=()
    local active_worktrees=()
    local active_branches=()
    local active_console_logs=()
    local processed=0
    local failed=0
    local deferred=0
    local launched_this_round=false
    local story_key=""
    local index=0
    local ready_found=false

    ensure_parallel_safe_worktree
    prepare_parallel_runtime

    while true; do
        poll_controller_control_file
        launched_this_round=false

        while [[ "$SHUTDOWN_REQUESTED" != "true" && "$CONTROL_PAUSED" != "true" && "$(count_entries "${active_pids[@]}")" -lt "$CONCURRENCY" ]]; do
            ready_found=false

            for index in "${!pending_stories[@]}"; do
                story_key="${pending_stories[$index]}"
                if story_dependencies_satisfied "$story_key"; then
                    ready_found=true
                    break
                fi
            done

            if [[ "$ready_found" != "true" ]]; then
                break
            fi

            if launch_story_worker "$story_key"; then
                active_pids+=("$LAUNCHED_WORKER_PID")
                active_stories+=("$story_key")
                active_results+=("$LAUNCHED_WORKER_RESULT_FILE")
                active_worktrees+=("$LAUNCHED_WORKER_WORKTREE")
                active_branches+=("$LAUNCHED_WORKER_BRANCH")
                active_console_logs+=("$LAUNCHED_WORKER_CONSOLE_LOG")
                unset 'pending_stories[$index]'
                launched_this_round=true
            else
                failed=$((failed + 1))
                log ERROR "Failed to launch worker for $story_key"
                unset 'pending_stories[$index]'
            fi
        done

        if controller_stop_requested && [[ "$(count_entries "${active_pids[@]}")" -eq 0 ]]; then
            deferred=$((deferred + $(count_entries "${pending_stories[@]}")))
            break
        fi

        if [[ "$(count_entries "${active_pids[@]}")" -eq 0 && "$(count_entries "${pending_stories[@]}")" -eq 0 ]]; then
            break
        fi

        if controller_shutdown_requested && [[ "$(count_entries "${active_pids[@]}")" -eq 0 ]]; then
            deferred=$((deferred + $(count_entries "${pending_stories[@]}")))
            break
        fi

        if controller_paused && [[ "$(count_entries "${active_pids[@]}")" -eq 0 ]] && [[ "$(count_entries "${pending_stories[@]}")" -gt 0 ]]; then
            wait_while_controller_paused
            continue
        fi

        if [[ "$(count_entries "${active_pids[@]}")" -eq 0 && "$(count_entries "${pending_stories[@]}")" -gt 0 ]]; then
            log ERROR "No runnable stories remain; unresolved dependencies are blocking progress:"
            for story_key in "${pending_stories[@]}"; do
                [[ -n "$story_key" ]] && echo "  - $story_key"
            done
            failed=$((failed + $(count_entries "${pending_stories[@]}")))
            break
        fi

        if [[ "$launched_this_round" == "true" || "$(count_entries "${active_pids[@]}")" -gt 0 ]]; then
            wait_for_worker_completion active_pids active_stories active_results active_worktrees active_branches active_console_logs processed failed deferred
        fi
    done

    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN}                  Implementation Summary${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo -e "  ${GREEN}[+] Processed:${NC} $processed stories"
    if [[ $failed -gt 0 ]]; then
        echo -e "  ${RED}[x] Failed:${NC}    $failed stories"
    fi
    if [[ $deferred -gt 0 ]]; then
        echo -e "  ${YELLOW}[!] Deferred:${NC}  $deferred stories"
    fi
    echo -e "  ${BLUE}[i] Log:${NC}       $LOG_FILE"
    echo ""

    if [[ $failed -gt 0 ]]; then
        return 1
    fi

    if controller_stop_requested; then
        log WARN "Stop completed. Active work was terminated and ${deferred} story/stories remain pending."
        return 130
    fi

    if controller_shutdown_requested; then
        log WARN "Graceful shutdown completed after draining active workers. ${deferred} story/stories remain pending."
        return 130
    fi

    return 0
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
