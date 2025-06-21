#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Define files
COMMANDS_FILE="$SCRIPT_DIR/my_commands.json"
LOG_FILE="$SCRIPT_DIR/commands_log.log"
LOCK_FILE="$HOME/command_manager.lock"

# Source functions
FUNCTIONS_FILE="$SCRIPT_DIR/cmdr_functions.sh"
if [ ! -f "$FUNCTIONS_FILE" ]; then
    echo -e "${RED}Error:${NC} Functions file '$FUNCTIONS_FILE' not found."
    exit 1
fi
source "$FUNCTIONS_FILE"

# Check if script is run with sudo
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Error:${NC} This script must be run with sudo."
    exit 1
fi

# Check for jq dependency
if ! command -v jq >/dev/null; then
    echo -e "${RED}Error:${NC} 'jq' is required. Install with 'sudo apt-get install jq'."
    exit 1
fi

# Initialize files
initialize_files

# Global verbosity level (default: INFO)
VERBOSITY="INFO"

# Acquire the lock
acquire_lock() {
    # Check for stale lock file
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$pid" ] && ! ps -p "$pid" >/dev/null 2>&1; then
            log_event "DEBUG" "Removing stale lock file (PID $pid)"
            rm -f "$LOCK_FILE"
        fi
    fi

    # Use flock
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

    while getopts ":a:d:sr:x:l:i:mhv" opt; do
        case ${opt} in
            a )
                shift $((OPTIND-1))
                add_command "$1" "$2" "$3"
                exit 0
                ;;
            d )
                delete_command "$OPTARG"
                exit 0
                ;;
            s )
                show_commands
                exit 0
                ;;
            r )
                run_command "$OPTARG"
                ;;
            x )
                extract_commands "$OPTARG"
                exit 0
                ;;
            l )
                extract_logs "$OPTARG"
                exit 0
                ;;
            i )
                install_commands "$OPTARG"
                exit 0
                ;;
            m )
                interactive_mode
                exit 0
                ;;
            h )
                display_help
                exit 0
                ;;
            v )
                VERBOSITY="DEBUG"
                log_event "DEBUG" "Verbosity set to DEBUG"
                ;;
            \? )
                log_event "ERROR" "Invalid option: -$OPTARG"
                echo -e "${RED}Invalid option: -$OPTARG${NC}" 1>&2
                exit 1
                ;;
            : )
                log_event "ERROR" "Option -$OPTARG requires an argument"
                echo -e "${RED}Invalid option: -$OPTARG requires an argument${NC}" 1>&2
                exit 1
                ;;
        esac
    done
    shift $((OPTIND -1))
}

main "$@"
