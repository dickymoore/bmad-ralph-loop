#!/bin/bash
#
# Claude Ralph Loop - Wrapper
#

set -e

SOURCE_PATH="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
    SOURCE_PATH="$(realpath "$SOURCE_PATH")"
elif command -v readlink >/dev/null 2>&1; then
    SOURCE_PATH="$(readlink -f "$SOURCE_PATH" 2>/dev/null || echo "$SOURCE_PATH")"
else
    # Portable symlink resolution fallback (Python is common on dev machines)
    SOURCE_PATH="$(python -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SOURCE_PATH" 2>/dev/null || echo "$SOURCE_PATH")"
fi

SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
CORE_PATH="$SCRIPT_DIR/ralph-loop-core.sh"
if [[ -z "${RALPH_LIB_DIR:-}" ]]; then
    if [[ -d "$SCRIPT_DIR/ralph-loop-lib" ]]; then
        export RALPH_LIB_DIR="$SCRIPT_DIR/ralph-loop-lib"
    else
        export RALPH_LIB_DIR="$SCRIPT_DIR/lib"
    fi
else
    export RALPH_LIB_DIR
fi
SNAPSHOT_PARENT="${RALPH_SCRIPT_SNAPSHOT_ROOT:-${TMPDIR:-/tmp}}"
SNAPSHOT_DIR=""
SNAPSHOT_CORE=""

export PROVIDER="claude"

cleanup_script_snapshot() {
    if [[ -n "$SNAPSHOT_DIR" && -d "$SNAPSHOT_DIR" ]]; then
        rm -rf "$SNAPSHOT_DIR"
    fi
}

if [[ ! -f "$CORE_PATH" ]]; then
    echo "Error: ralph-loop-core.sh not found in $SCRIPT_DIR" >&2
    exit 1
fi

mkdir -p "$SNAPSHOT_PARENT"
SNAPSHOT_DIR="$(mktemp -d "$SNAPSHOT_PARENT/ralph-script-snapshot.XXXXXX")"
chmod 700 "$SNAPSHOT_DIR"
trap cleanup_script_snapshot EXIT

SNAPSHOT_CORE="$SNAPSHOT_DIR/ralph-loop-core.sh"
cp "$CORE_PATH" "$SNAPSHOT_CORE"
chmod +x "$SNAPSHOT_CORE"

# shellcheck source=ralph-loop-core.sh
source "$SNAPSHOT_CORE"

main "$@"
