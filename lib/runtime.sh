# shellcheck shell=bash

# Runtime and process-control helpers for ralph-loop-core.sh.

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
