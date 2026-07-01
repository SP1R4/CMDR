#!/bin/bash
# ============================================================================
# CMDR :: lib/core.sh
# Core utilities, backup & recovery
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

# ----------------------------------------------------------------------------
# Section 1: Core Utilities
# Logging, file initialization, input sanitization, and command validation.
# ----------------------------------------------------------------------------

# Create required data directories and seed empty JSON files on first run.
initialize_files() {
    log_event "DEBUG" "Initializing files: COMMANDS_FILE=$COMMANDS_FILE, LOG_FILE=$LOG_FILE"

    if [ ! -d "$DATA_DIR" ]; then
        mkdir -p "$DATA_DIR" || { echo -e "${RED}Error:${NC} Failed to create data directory."; exit 1; }
    fi

    # Ensure the active data directory exists (workspace support)
    if [ ! -d "$ACTIVE_DATA_DIR" ]; then
        mkdir -p "$ACTIVE_DATA_DIR" || { echo -e "${RED}Error:${NC} Failed to create workspace directory."; exit 1; }
    fi

    if [ ! -f "$COMMANDS_FILE" ]; then
        echo "{}" > "$COMMANDS_FILE" || { echo -e "${RED}Error:${NC} Failed to create commands file."; exit 1; }
        log_event "INFO" "Created commands file: $COMMANDS_FILE"
    fi
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE" || { echo -e "${RED}Error:${NC} Failed to create log file."; exit 1; }
        log_event "INFO" "Created log file: $LOG_FILE"
    fi

    # Reset corrupted JSON rather than crashing
    if ! jq -e . "$COMMANDS_FILE" >/dev/null 2>&1; then
        log_event "ERROR" "Invalid JSON in $COMMANDS_FILE, resetting to empty object"
        echo "{}" > "$COMMANDS_FILE" || { echo -e "${RED}Error:${NC} Failed to reset commands file."; exit 1; }
    fi
}

# Create a temp file in the SAME directory as the target so the subsequent
# `mv` is an atomic, same-filesystem rename. Using /tmp would degrade the
# rename to a non-atomic copy when the data dir is on another filesystem.
_mktemp_beside() {
    local target="$1"
    local dir
    dir="$(dirname "$target")"
    [ -d "$dir" ] || mkdir -p "$dir"
    mktemp "$dir/.cmdr.tmp.XXXXXX"
}

# True only when a lock dir belongs to a process that is gone AND has sat there
# longer than the grace period. The pid file holds "PID EPOCH"; an older format
# with no epoch is treated as not-stale (never reclaimed) to stay safe. This is
# the guard that makes stale reclamation race-free: a lock that is merely being
# handed off between short writers keeps a fresh epoch and is left alone.
_lock_is_stale() {
    local dir="$1" line pid ts now grace="${CMDR_LOCK_STALE:-30}"
    line=$(cat "$dir/pid" 2>/dev/null) || return 1
    case "$line" in
        *" "*) pid=${line%% *}; ts=${line##* } ;;
        *)     return 1 ;;
    esac
    [ -n "$pid" ] || return 1
    ps -p "$pid" >/dev/null 2>&1 && return 1        # owner still alive
    case "$ts" in ''|*[!0-9]*) return 1 ;; esac      # unparseable timestamp
    now=$(date +%s)
    [ "$((now - ts))" -ge "$grace" ]
}

# Run a store read-modify-write under the global mkdir mutex (same LOCK_DIR the
# top-level CRUD lock uses). This protects the writes on the *run* path — run
# history and captured env vars — which stay outside the coarse dispatch lock so
# a second terminal is never blocked by a long-running command. Two concurrent
# `cmdr -r ...` calls would otherwise read-modify-write the same JSON and lose an
# update; serializing just the short write closes that race without holding the
# lock for the command's whole runtime.
#
# Re-entrant: if this process already holds the coarse lock (LOCK_ACQUIRED), the
# body runs directly rather than deadlocking on our own lock. Best-effort: if the
# lock can't be taken within the bounded wait, the body still runs (a missed
# history entry must never abort a command the user asked to run).
with_store_lock() {
    if [ "${LOCK_ACQUIRED:-false}" = true ] || [ -z "${LOCK_DIR:-}" ]; then
        "$@"; return $?
    fi
    local tries=0 max_tries=50 held=false
    while true; do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo "$$ $(date +%s)" > "$LOCK_DIR/pid" 2>/dev/null
            held=true
            break
        fi
        # Reclaim only a lock that is BOTH owner-dead AND older than the grace
        # period. Reclaiming purely on a dead pid is racy: the pid we read may
        # belong to a holder that already finished and been replaced, so the
        # rm -rf would delete a *live* successor's lock and let two writers run.
        # A short-lived lock that is merely cycling always carries a fresh
        # timestamp, so it is never mistaken for stale.
        if _lock_is_stale "$LOCK_DIR"; then
            rm -rf "$LOCK_DIR"; continue
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge "$max_tries" ]; then
            log_event "DEBUG" "with_store_lock: proceeding without lock after wait"
            break
        fi
        sleep 0.1
    done
    "$@"
    local rc=$?
    [ "$held" = true ] && rm -rf "$LOCK_DIR"
    return $rc
}

# Leveled logger. Writes to LOG_FILE based on VERBOSITY threshold.
# Usage: log_event "INFO" "message"
log_event() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %T")

    [ -z "$LOG_FILE" ] && return

    case "$VERBOSITY" in
        "DEBUG")
            echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null
            ;;
        "INFO")
            if [ "$level" = "INFO" ] || [ "$level" = "ERROR" ]; then
                echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null
            fi
            ;;
        *)
            if [ "$level" = "ERROR" ]; then
                echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null
            fi
            ;;
    esac
}

# Validate and normalize a tag name. Only [a-zA-Z0-9_-] allowed.
sanitize_tag() {
    local input="$1"
    input="$(echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [ -z "$input" ]; then
        echo -e "${RED}Error:${NC} Tag cannot be empty." >&2
        return 1
    fi

    if [[ "$input" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_event "DEBUG" "Tag '$input' is valid"
        echo "$input"
        return 0
    else
        log_event "ERROR" "Invalid tag '$input': only alphanumeric, underscores, hyphens allowed"
        echo -e "${RED}Error:${NC} Invalid tag '$input'. Use alphanumeric, underscores, or hyphens." >&2
        return 1
    fi
}

# Trim whitespace and reject empty commands.
sanitize_command() {
    local input="$1"
    input="$(echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [ -z "$input" ]; then
        echo -e "${RED}Error:${NC} Command cannot be empty." >&2
        return 1
    fi

    log_event "DEBUG" "Command validated: '$input'"
    echo "$input"
    return 0
}

# Check that the command's first token is a real executable. Parameterized
# executables (e.g. {tool} arg) skip validation since the real binary
# isn't known until runtime.
validate_command() {
    local cmd="$1"
    if [ -z "$cmd" ]; then
        echo -e "${RED}Error:${NC} Command cannot be empty."
        return 1
    fi
    local executable
    executable=$(echo "$cmd" | awk '{print $1}')

    # Parameterized executable — can't validate yet
    if [[ "$executable" =~ ^\{[a-zA-Z_] ]]; then
        log_event "DEBUG" "Skipping validation for parameterized command: $cmd"
        echo -e "${YELLOW}Note:${NC} Parameterized executable, skipping validation."
        return 0
    fi

    log_event "DEBUG" "Checking executable: '$executable'"

    if command -v "$executable" >/dev/null 2>&1; then
        log_event "INFO" "Validation passed: $cmd"
        echo -e "${GREEN}Validation passed:${NC} '$executable' found."
        return 0
    else
        log_event "WARNING" "'$executable' not found in PATH"
        echo -e "${YELLOW}Warning:${NC} '$executable' not found in PATH."
        read -p "Store anyway? (y/N): " choice
        if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
            log_event "INFO" "Validation overridden: $cmd"
            return 0
        fi
        log_event "ERROR" "Validation failed: $cmd"
        return 1
    fi
}

# Format seconds into a human-readable duration string (e.g. "1m 23s").
format_duration() {
    local seconds="$1"
    if [ "$seconds" -ge 3600 ]; then
        printf "%dh %dm %ds" $((seconds / 3600)) $((seconds % 3600 / 60)) $((seconds % 60))
    elif [ "$seconds" -ge 60 ]; then
        printf "%dm %ds" $((seconds / 60)) $((seconds % 60))
    else
        printf "%ds" "$seconds"
    fi
}

# ----------------------------------------------------------------------------
# Section 2: Backup & Recovery
# Single-level undo via JSON snapshot before each write operation.
# A companion .src file tracks which file was backed up so undo restores
# to the correct location (global, workspace, or local).
# ----------------------------------------------------------------------------

# Snapshot the target file before modification.
backup_commands() {
    local target="${1:-$COMMANDS_FILE}"
    if [ -f "$target" ]; then
        cp "$target" "$BACKUP_FILE"
        echo "$target" > "${BACKUP_FILE}.src"
        log_event "DEBUG" "Backup created: $BACKUP_FILE (source: $target)"
    fi
}

# Restore the last snapshot. Only one level of undo is supported.
undo_command() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo -e "${RED}Error:${NC} No backup found. Nothing to undo."
        exit 1
    fi

    local src_file="$COMMANDS_FILE"
    if [ -f "${BACKUP_FILE}.src" ]; then
        src_file=$(cat "${BACKUP_FILE}.src")
    fi

    cp "$BACKUP_FILE" "$src_file"
    rm -f "$BACKUP_FILE" "${BACKUP_FILE}.src"
    log_event "INFO" "Restored from backup to $src_file"
    echo -e "${GREEN}Commands restored from backup.${NC}"
}

