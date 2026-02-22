#!/bin/bash
# CMDR v2.0 - Command Manager

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Define files (user-level, no sudo needed)
DATA_DIR="${CMDR_DATA_DIR:-$SCRIPT_DIR}"
COMMANDS_FILE="$DATA_DIR/my_commands.json"
LOG_FILE="$DATA_DIR/commands_log.log"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/cmdr.lock"

# Global verbosity level (default: INFO) - set BEFORE sourcing functions
VERBOSITY="INFO"

# Source functions
FUNCTIONS_FILE="$SCRIPT_DIR/cmdr_functions.sh"
if [ ! -f "$FUNCTIONS_FILE" ]; then
    echo -e "${RED}Error:${NC} Functions file '$FUNCTIONS_FILE' not found."
    exit 1
fi
source "$FUNCTIONS_FILE"

# Check for jq dependency
if ! command -v jq >/dev/null; then
    echo -e "${RED}Error:${NC} 'jq' is required. Install with 'sudo apt-get install jq'."
    exit 1
fi

# Initialize files
initialize_files

# Acquire the lock
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$pid" ] && ! ps -p "$pid" >/dev/null 2>&1; then
            log_event "DEBUG" "Removing stale lock file (PID $pid)"
            rm -f "$LOCK_FILE"
        fi
    fi

    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log_event "ERROR" "Another instance is running ($LOCK_FILE)"
        echo -e "${RED}Another instance is running.${NC}"
        exit 1
    fi
    echo "$$" > "$LOCK_FILE"
    log_event "DEBUG" "Lock acquired (PID $$)"
}

# Clean up on exit
cleanup() {
    rm -f "$LOCK_FILE"
    log_event "DEBUG" "Lock released (PID $$)"
}
trap cleanup EXIT INT TERM

# Main function
main() {
    acquire_lock

    if [ "$#" -eq 0 ]; then
        display_help
        exit 1
    fi

    # Pre-scan for -v flag so debug is active for all operations
    for arg in "$@"; do
        if [ "$arg" = "-v" ]; then
            VERBOSITY="DEBUG"
            log_event "DEBUG" "Verbosity set to DEBUG"
            break
        fi
    done

    # Manual argument parsing (replaces broken getopts for -a)
    local action=""
    local action_args=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -a)
                action="add"
                shift
                # Collect tag, command, and optional category
                [ "$#" -ge 1 ] && action_args+=("$1") && shift  # tag
                [ "$#" -ge 1 ] && action_args+=("$1") && shift  # command
                [ "$#" -ge 1 ] && [[ "$1" != -* ]] && action_args+=("$1") && shift  # category (optional)
                ;;
            -e)
                action="edit"
                shift
                [ "$#" -ge 1 ] && action_args+=("$1") && shift  # tag
                [ "$#" -ge 1 ] && action_args+=("$1") && shift  # new command
                [ "$#" -ge 1 ] && [[ "$1" != -* ]] && action_args+=("$1") && shift  # new category (optional)
                ;;
            -d)
                action="delete"
                shift
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            -s)
                action="show"
                shift
                ;;
            -r)
                action="run"
                shift
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            -f)
                action="search"
                shift
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            -x)
                action="extract"
                shift
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            -l)
                action="logs"
                shift
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            -i)
                action="install"
                shift
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            -m)
                action="interactive"
                shift
                ;;
            -h|--help)
                action="help"
                shift
                ;;
            -v)
                shift  # already handled above
                ;;
            *)
                log_event "ERROR" "Invalid option: $1"
                echo -e "${RED}Invalid option: $1${NC}" 1>&2
                exit 1
                ;;
        esac
    done

    case "$action" in
        add)
            add_command "${action_args[@]}"
            ;;
        edit)
            edit_command "${action_args[@]}"
            ;;
        delete)
            delete_command "${action_args[@]}"
            ;;
        show)
            show_commands
            ;;
        run)
            run_command "${action_args[@]}"
            ;;
        search)
            search_commands "${action_args[@]}"
            ;;
        extract)
            extract_commands "${action_args[@]}"
            ;;
        logs)
            extract_logs "${action_args[@]}"
            ;;
        install)
            install_commands "${action_args[@]}"
            ;;
        interactive)
            interactive_mode
            ;;
        help)
            display_help
            ;;
        *)
            display_help
            exit 1
            ;;
    esac
}

main "$@"
