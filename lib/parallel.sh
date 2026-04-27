# shellcheck shell=bash

# Parallel worker and worktree helpers for ralph-loop-core.sh.

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
        if validate_worker_result_file "$previous_result_file"; then
            previous_result_status="$(read_worker_result_value "$previous_result_file" "RALPH_WORKER_RESULT_STATUS" "unknown")"
            previous_commit_sha="$(read_worker_result_value "$previous_result_file" "RALPH_WORKER_RESULT_COMMIT_SHA" "")"
            previous_log_file="$(read_worker_result_value "$previous_result_file" "RALPH_WORKER_RESULT_LOG_FILE" "")"
            previous_worktree="$(read_worker_result_value "$previous_result_file" "RALPH_WORKER_RESULT_WORKTREE" "")"
        fi
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

worker_result_key_allowed() {
    case "$1" in
        RALPH_WORKER_RESULT_STATUS|\
        RALPH_WORKER_RESULT_STORY|\
        RALPH_WORKER_RESULT_BRANCH|\
        RALPH_WORKER_RESULT_WORKTREE|\
        RALPH_WORKER_RESULT_EXIT_CODE|\
        RALPH_WORKER_RESULT_COMMIT_SHA|\
        RALPH_WORKER_RESULT_LOG_FILE)
            return 0
            ;;
    esac

    return 1
}

sanitize_worker_result_value() {
    local value="$1"

    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    printf '%s' "$value"
}

write_worker_result_field() {
    local key="$1"
    local value="$2"

    printf '%s=%s\n' "$key" "$(sanitize_worker_result_value "$value")"
}

validate_worker_result_file() {
    local result_file="$1"
    local line=""
    local key=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue

        if [[ "$line" != *=* ]]; then
            log WARN "Ignoring malformed worker result file: $result_file"
            return 1
        fi

        key="${line%%=*}"
        if ! worker_result_key_allowed "$key"; then
            log WARN "Ignoring worker result file with unexpected key '$key': $result_file"
            return 1
        fi
    done < "$result_file"

    return 0
}

read_worker_result_value() {
    local result_file="$1"
    local wanted_key="$2"
    local default_value="${3:-}"
    local line=""
    local key=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        key="${line%%=*}"

        if [[ "$key" == "$wanted_key" ]]; then
            printf '%s' "${line#*=}"
            return 0
        fi
    done < "$result_file"

    printf '%s' "$default_value"
    return 1
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
        write_worker_result_field "RALPH_WORKER_RESULT_STATUS" "$result_status"
        write_worker_result_field "RALPH_WORKER_RESULT_STORY" "$story_key"
        write_worker_result_field "RALPH_WORKER_RESULT_BRANCH" "$branch_name"
        write_worker_result_field "RALPH_WORKER_RESULT_WORKTREE" "$worktree_dir"
        write_worker_result_field "RALPH_WORKER_RESULT_EXIT_CODE" "$exit_code"
        write_worker_result_field "RALPH_WORKER_RESULT_COMMIT_SHA" "$commit_sha"
        write_worker_result_field "RALPH_WORKER_RESULT_LOG_FILE" "$worker_log_file"
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
            for pid in "${ACTIVE_WORKER_PIDS[@]}"; do
                [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && force_stop_process_tree "$pid"
            done
        fi

        for index in "${!ACTIVE_WORKER_PIDS[@]}"; do
            pid="${ACTIVE_WORKER_PIDS[$index]}"
            result_file="${ACTIVE_WORKER_RESULTS[$index]}"
            story_key="${ACTIVE_WORKER_STORIES[$index]}"
            branch_name="${ACTIVE_WORKER_BRANCHES[$index]}"
            worktree_dir="${ACTIVE_WORKER_WORKTREES[$index]}"
            stale_worker="false"
            stop_requested="false"

            if kill -0 "$pid" 2>/dev/null; then
                if controller_stop_requested; then
                    stop_requested="true"
                    force_stop_process_tree "$pid"
                elif worker_is_stale "$result_file" "${ACTIVE_WORKER_CONSOLE_LOGS[$index]}"; then
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
            result_log_file="${ACTIVE_WORKER_CONSOLE_LOGS[$index]}"

            if [[ -f "$result_file" ]]; then
                if validate_worker_result_file "$result_file"; then
                    result_status="$(read_worker_result_value "$result_file" "RALPH_WORKER_RESULT_STATUS" "failed")"
                    result_exit_code="$(read_worker_result_value "$result_file" "RALPH_WORKER_RESULT_EXIT_CODE" "")"
                    result_commit_sha="$(read_worker_result_value "$result_file" "RALPH_WORKER_RESULT_COMMIT_SHA" "")"
                    result_log_file="$(read_worker_result_value "$result_file" "RALPH_WORKER_RESULT_LOG_FILE" "$result_log_file")"
                fi
            fi

            if controller_stop_requested || [[ "$stop_requested" == "true" ]]; then
                PARALLEL_DEFERRED=$((PARALLEL_DEFERRED + 1))
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
                    PARALLEL_PROCESSED=$((PARALLEL_PROCESSED + 1))
                    check_epic_completion "$(get_epic_for_story "$story_key")" || {
                        PARALLEL_FAILED=$((PARALLEL_FAILED + 1))
                        log ERROR "Failed to finalize epic after integrating $story_key"
                    }
                    keep_checkout="$KEEP_WORKTREES_ON_SUCCESS"
                else
                    PARALLEL_FAILED=$((PARALLEL_FAILED + 1))
                    keep_checkout="$KEEP_WORKTREES_ON_FAILURE"
                fi
            else
                PARALLEL_FAILED=$((PARALLEL_FAILED + 1))
                if [[ "$stale_worker" == "true" ]]; then
                    log ERROR "Worker timed out waiting for new output: ${result_log_file:-$result_file}"
                fi
                log ERROR "Worker failed for $story_key (exit code: $wait_status)"
                log ERROR "Inspect worker logs: ${result_log_file:-$result_file}"
                keep_checkout="$KEEP_WORKTREES_ON_FAILURE"
            fi

            cleanup_worker_checkout "$branch_name" "$worktree_dir" "$keep_checkout"
            unset 'ACTIVE_WORKER_PIDS[$index]' 'ACTIVE_WORKER_STORIES[$index]' 'ACTIVE_WORKER_RESULTS[$index]' \
                'ACTIVE_WORKER_WORKTREES[$index]' 'ACTIVE_WORKER_BRANCHES[$index]' 'ACTIVE_WORKER_CONSOLE_LOGS[$index]'
            return 0
        done

        sleep 1
    done
}

run_parallel_stories() {
    local pending_stories=("$@")
    local launched_this_round=false
    local story_key=""
    local index=0
    local ready_found=false

    ACTIVE_WORKER_PIDS=()
    ACTIVE_WORKER_STORIES=()
    ACTIVE_WORKER_RESULTS=()
    ACTIVE_WORKER_WORKTREES=()
    ACTIVE_WORKER_BRANCHES=()
    ACTIVE_WORKER_CONSOLE_LOGS=()
    PARALLEL_PROCESSED=0
    PARALLEL_FAILED=0
    PARALLEL_DEFERRED=0

    ensure_parallel_safe_worktree
    prepare_parallel_runtime

    while true; do
        poll_controller_control_file
        launched_this_round=false

        while [[ "$SHUTDOWN_REQUESTED" != "true" && "$CONTROL_PAUSED" != "true" && "$(count_entries "${ACTIVE_WORKER_PIDS[@]}")" -lt "$CONCURRENCY" ]]; do
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
                ACTIVE_WORKER_PIDS+=("$LAUNCHED_WORKER_PID")
                ACTIVE_WORKER_STORIES+=("$story_key")
                ACTIVE_WORKER_RESULTS+=("$LAUNCHED_WORKER_RESULT_FILE")
                ACTIVE_WORKER_WORKTREES+=("$LAUNCHED_WORKER_WORKTREE")
                ACTIVE_WORKER_BRANCHES+=("$LAUNCHED_WORKER_BRANCH")
                ACTIVE_WORKER_CONSOLE_LOGS+=("$LAUNCHED_WORKER_CONSOLE_LOG")
                unset 'pending_stories[$index]'
                launched_this_round=true
            else
                PARALLEL_FAILED=$((PARALLEL_FAILED + 1))
                log ERROR "Failed to launch worker for $story_key"
                unset 'pending_stories[$index]'
            fi
        done

        if controller_stop_requested && [[ "$(count_entries "${ACTIVE_WORKER_PIDS[@]}")" -eq 0 ]]; then
            PARALLEL_DEFERRED=$((PARALLEL_DEFERRED + $(count_entries "${pending_stories[@]}")))
            break
        fi

        if [[ "$(count_entries "${ACTIVE_WORKER_PIDS[@]}")" -eq 0 && "$(count_entries "${pending_stories[@]}")" -eq 0 ]]; then
            break
        fi

        if controller_shutdown_requested && [[ "$(count_entries "${ACTIVE_WORKER_PIDS[@]}")" -eq 0 ]]; then
            PARALLEL_DEFERRED=$((PARALLEL_DEFERRED + $(count_entries "${pending_stories[@]}")))
            break
        fi

        if controller_paused && [[ "$(count_entries "${ACTIVE_WORKER_PIDS[@]}")" -eq 0 ]] && [[ "$(count_entries "${pending_stories[@]}")" -gt 0 ]]; then
            wait_while_controller_paused
            continue
        fi

        if [[ "$(count_entries "${ACTIVE_WORKER_PIDS[@]}")" -eq 0 && "$(count_entries "${pending_stories[@]}")" -gt 0 ]]; then
            log ERROR "No runnable stories remain; unresolved dependencies are blocking progress:"
            for story_key in "${pending_stories[@]}"; do
                [[ -n "$story_key" ]] && echo "  - $story_key"
            done
            PARALLEL_FAILED=$((PARALLEL_FAILED + $(count_entries "${pending_stories[@]}")))
            break
        fi

        if [[ "$launched_this_round" == "true" || "$(count_entries "${ACTIVE_WORKER_PIDS[@]}")" -gt 0 ]]; then
            wait_for_worker_completion
        fi
    done

    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN}                  Implementation Summary${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo -e "  ${GREEN}[+] Processed:${NC} $PARALLEL_PROCESSED stories"
    if [[ $PARALLEL_FAILED -gt 0 ]]; then
        echo -e "  ${RED}[x] Failed:${NC}    $PARALLEL_FAILED stories"
    fi
    if [[ $PARALLEL_DEFERRED -gt 0 ]]; then
        echo -e "  ${YELLOW}[!] Deferred:${NC}  $PARALLEL_DEFERRED stories"
    fi
    echo -e "  ${BLUE}[i] Log:${NC}       $LOG_FILE"
    echo ""

    if [[ $PARALLEL_FAILED -gt 0 ]]; then
        return 1
    fi

    if controller_stop_requested; then
        log WARN "Stop completed. Active work was terminated and ${PARALLEL_DEFERRED} story/stories remain pending."
        return 130
    fi

    if controller_shutdown_requested; then
        log WARN "Graceful shutdown completed after draining active workers. ${PARALLEL_DEFERRED} story/stories remain pending."
        return 130
    fi

    return 0
}
