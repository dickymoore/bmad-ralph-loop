# shellcheck shell=bash

# Review-loop helpers for ralph-loop-core.sh.

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

run_code_review_gate() {
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
            return 1
        fi

        if [[ -z "$review_result" ]]; then
            log WARN "Code review pass $review_pass changed the worktree without emitting RALPH_REVIEW_RESULT. Re-running dev-story."
        else
            log WARN "Code review pass $review_pass requested another dev pass."
        fi
        return 1
    fi

    if [[ "$review_result" == "changes-required" ]]; then
        log WARN "Code review pass $review_pass requested another dev pass."
        return 1
    fi

    if [[ -z "$review_result" ]]; then
        log WARN "Code review pass $review_pass did not emit RALPH_REVIEW_RESULT. Assuming review is clean because the worktree did not change."
    else
        log OK "Code review pass $review_pass finished cleanly."
    fi

    return 0
}
