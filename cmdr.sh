#!/bin/bash
# CMDR v2.1 - Command Manager

CMDR_VERSION="2.1.0"

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Handle --version / -V early (before lock, before sourcing)
for arg in "$@"; do
    if [ "$arg" = "-V" ] || [ "$arg" = "--version" ]; then
        echo "CMDR v${CMDR_VERSION}"
        exit 0
    fi
done

# Define files (user-level, no sudo needed)
DATA_DIR="${CMDR_DATA_DIR:-$SCRIPT_DIR}"
COMMANDS_FILE="$DATA_DIR/my_commands.json"
LOG_FILE="$DATA_DIR/commands_log.log"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/cmdr.lock"
BACKUP_FILE="$DATA_DIR/.my_commands.json.bak"

# Global flags - set BEFORE sourcing functions
VERBOSITY="INFO"
DRY_RUN=false
CMDR_DESC=""
CMDR_ALIASES=()
CMDR_FORCE_YES=false

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

    # Pre-scan for -v and -n/--dry-run flags
    for arg in "$@"; do
        if [ "$arg" = "-v" ]; then
            VERBOSITY="DEBUG"
            log_event "DEBUG" "Verbosity set to DEBUG"
        fi
        if [ "$arg" = "-n" ] || [ "$arg" = "--dry-run" ]; then
            DRY_RUN=true
            log_event "DEBUG" "Dry-run mode enabled"
        fi
    done

    # Manual argument parsing
    local action=""
    local action_args=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -a)
                action="add"
                shift
                if [ "${1:-}" = "--help" ]; then
                    display_subcommand_help "add"; exit 0
                fi
                # tag (always consumed)
                [ "$#" -ge 1 ] && [[ "${1:-}" != --* ]] && action_args+=("$1") && shift
                # command (skip if --modifier)
                [ "$#" -ge 1 ] && [[ "${1:-}" != --* ]] && action_args+=("$1") && shift
                # category (optional, skip if any flag)
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                # Collect modifiers
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        --desc) shift; [ "$#" -ge 1 ] && CMDR_DESC="$1" && shift ;;
                        --alias) shift; [ "$#" -ge 1 ] && CMDR_ALIASES+=("$1") && shift ;;
                        -v|-n|--dry-run) shift ;;
                        *) break ;;
                    esac
                done
                ;;
            -e)
                action="edit"
                shift
                if [ "${1:-}" = "--help" ]; then
                    display_subcommand_help "edit"; exit 0
                fi
                # tag (always consumed)
                [ "$#" -ge 1 ] && [[ "${1:-}" != --* ]] && action_args+=("$1") && shift
                # command (skip if --modifier)
                [ "$#" -ge 1 ] && [[ "${1:-}" != --* ]] && action_args+=("$1") && shift
                # category (optional, skip if any flag)
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                # Collect modifiers
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        --desc) shift; [ "$#" -ge 1 ] && CMDR_DESC="$1" && shift ;;
                        --alias) shift; [ "$#" -ge 1 ] && CMDR_ALIASES+=("$1") && shift ;;
                        -v|-n|--dry-run) shift ;;
                        *) break ;;
                    esac
                done
                ;;
            -d)
                action="delete"
                shift
                if [ "${1:-}" = "--help" ]; then
                    display_subcommand_help "delete"; exit 0
                fi
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        -y) CMDR_FORCE_YES=true; shift ;;
                        -v|-n|--dry-run) shift ;;
                        *) break ;;
                    esac
                done
                ;;
            -s)
                action="show"
                shift
                if [ "${1:-}" = "--help" ]; then
                    display_subcommand_help "show"; exit 0
                fi
                ;;
            -r)
                action="run"
                shift
                if [ "${1:-}" = "--help" ]; then
                    display_subcommand_help "run"; exit 0
                fi
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                # Collect extra positional args for parameterized commands
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        -v|-n|--dry-run) shift ;;
                        -*) break ;;
                        *) action_args+=("$1"); shift ;;
                    esac
                done
                ;;
            -f)
                action="search"
                shift
                if [ "${1:-}" = "--help" ]; then
                    display_subcommand_help "search"; exit 0
                fi
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            -x)
                action="extract"
                shift
                if [ "${1:-}" = "--help" ]; then
                    display_subcommand_help "extract"; exit 0
                fi
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            -l)
                action="logs"
                shift
                if [ "${1:-}" = "--help" ]; then
                    display_subcommand_help "logs"; exit 0
                fi
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            -i)
                action="install"
                shift
                if [ "${1:-}" = "--help" ]; then
                    display_subcommand_help "install"; exit 0
                fi
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            -m)
                action="interactive"
                shift
                if [ "${1:-}" = "--help" ]; then
                    display_subcommand_help "interactive"; exit 0
                fi
                ;;
            -u|--undo)
                action="undo"
                shift
                ;;
            -h|--help)
                action="help"
                shift
                ;;
            -V|--version)
                echo "CMDR v${CMDR_VERSION}"
                exit 0
                ;;
            -v|-n|--dry-run)
                shift  # already handled in pre-scan
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
            delete_command "${action_args[0]:-}" "$CMDR_FORCE_YES"
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
        undo)
            undo_command
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
