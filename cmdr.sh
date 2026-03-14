#!/bin/bash
# ============================================================================
# CMDR v3.0 - Command Manager
# ============================================================================
# A command manager for CTF players and developers. Stores, organizes, and
# runs shell commands with workspaces, environment variables, playbooks,
# output capture, notes, and extensible command packs.
#
# See `cmdr -h` for full usage or `cmdr <flag> --help` for per-command help.
# ============================================================================

CMDR_VERSION="3.0.0"

# Resolve the script's install directory (follows symlinks)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Terminal colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Fast path: --version / -V exits before lock or sourcing
for arg in "$@"; do
    if [ "$arg" = "-V" ] || [ "$arg" = "--version" ]; then
        echo "CMDR v${CMDR_VERSION}"
        exit 0
    fi
done

# ---------------------------------------------------------------------------
# Path setup: base data directory and workspace resolution
# ---------------------------------------------------------------------------
DATA_DIR="${CMDR_DATA_DIR:-$SCRIPT_DIR}"
LOG_FILE="$DATA_DIR/commands_log.log"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/cmdr.lock"
WORKSPACE_FILE="$DATA_DIR/.cmdr_active_workspace"
PACKS_DIR="$SCRIPT_DIR/packs"

# Resolve active workspace
ACTIVE_WORKSPACE="default"
if [ -f "$WORKSPACE_FILE" ]; then
    ACTIVE_WORKSPACE=$(cat "$WORKSPACE_FILE" 2>/dev/null)
    [ -z "$ACTIVE_WORKSPACE" ] && ACTIVE_WORKSPACE="default"
fi

# Set all paths relative to the active workspace
if [ "$ACTIVE_WORKSPACE" != "default" ]; then
    ACTIVE_DATA_DIR="$DATA_DIR/workspaces/$ACTIVE_WORKSPACE"
else
    ACTIVE_DATA_DIR="$DATA_DIR"
fi

COMMANDS_FILE="$ACTIVE_DATA_DIR/my_commands.json"
BACKUP_FILE="$ACTIVE_DATA_DIR/.my_commands.json.bak"
ENV_FILE="$ACTIVE_DATA_DIR/.cmdr_env.json"
NOTES_FILE="$ACTIVE_DATA_DIR/.cmdr_notes.json"
PLAYBOOKS_FILE="$ACTIVE_DATA_DIR/.cmdr_playbooks.json"
OUTPUTS_DIR="$ACTIVE_DATA_DIR/outputs"
LOCAL_COMMANDS_FILE="$(pwd)/.cmdr.json"

# ---------------------------------------------------------------------------
# Global modifier flags (pre-scanned before argument parsing)
# ---------------------------------------------------------------------------
VERBOSITY="INFO"
DRY_RUN=false
SAVE_OUTPUT=false
USE_LOCAL=false
CMDR_DESC=""
CMDR_ALIASES=()
CMDR_FORCE_YES=false

# Write target: defaults to workspace commands, overridden by --local
WRITE_COMMANDS_FILE="$COMMANDS_FILE"

# ---------------------------------------------------------------------------
# Source functions and initialize
# ---------------------------------------------------------------------------
FUNCTIONS_FILE="$SCRIPT_DIR/cmdr_functions.sh"
if [ ! -f "$FUNCTIONS_FILE" ]; then
    echo -e "${RED}Error:${NC} Functions file '$FUNCTIONS_FILE' not found."
    exit 1
fi
source "$FUNCTIONS_FILE"

if ! command -v jq >/dev/null; then
    echo -e "${RED}Error:${NC} 'jq' is required. Install with 'sudo apt-get install jq'."
    exit 1
fi

initialize_files

# ---------------------------------------------------------------------------
# Lock management (single-instance protection)
# ---------------------------------------------------------------------------
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

cleanup() {
    rm -f "$LOCK_FILE"
    log_event "DEBUG" "Lock released (PID $$)"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Main: argument parsing and dispatch
# ---------------------------------------------------------------------------
main() {
    acquire_lock

    if [ "$#" -eq 0 ]; then
        display_help
        exit 1
    fi

    # Pre-scan global modifier flags so they're active for all operations
    for arg in "$@"; do
        case "$arg" in
            -v)        VERBOSITY="DEBUG"; log_event "DEBUG" "Verbosity set to DEBUG" ;;
            -n|--dry-run) DRY_RUN=true; log_event "DEBUG" "Dry-run mode enabled" ;;
            --local)   USE_LOCAL=true; log_event "DEBUG" "Local mode enabled" ;;
            --save)    SAVE_OUTPUT=true; log_event "DEBUG" "Save output enabled" ;;
        esac
    done

    # Redirect writes to local file when --local is active
    if [ "$USE_LOCAL" = true ]; then
        WRITE_COMMANDS_FILE="$LOCAL_COMMANDS_FILE"
        [ ! -f "$WRITE_COMMANDS_FILE" ] && echo "{}" > "$WRITE_COMMANDS_FILE"
    fi

    # ----- Argument parsing -----
    local action=""
    local action_args=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            # --- Command CRUD ---
            -a)
                action="add"
                shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "add"; exit 0; }
                [ "$#" -ge 1 ] && [[ "${1:-}" != --* ]] && action_args+=("$1") && shift
                [ "$#" -ge 1 ] && [[ "${1:-}" != --* ]] && action_args+=("$1") && shift
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        --desc)  shift; [ "$#" -ge 1 ] && CMDR_DESC="$1" && shift ;;
                        --alias) shift; [ "$#" -ge 1 ] && CMDR_ALIASES+=("$1") && shift ;;
                        -v|-n|--dry-run|--local|--save) shift ;;
                        *) break ;;
                    esac
                done
                ;;
            -e)
                action="edit"
                shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "edit"; exit 0; }
                [ "$#" -ge 1 ] && [[ "${1:-}" != --* ]] && action_args+=("$1") && shift
                [ "$#" -ge 1 ] && [[ "${1:-}" != --* ]] && action_args+=("$1") && shift
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        --desc)  shift; [ "$#" -ge 1 ] && CMDR_DESC="$1" && shift ;;
                        --alias) shift; [ "$#" -ge 1 ] && CMDR_ALIASES+=("$1") && shift ;;
                        -v|-n|--dry-run|--local|--save) shift ;;
                        *) break ;;
                    esac
                done
                ;;
            -d)
                action="delete"
                shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "delete"; exit 0; }
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        -y) CMDR_FORCE_YES=true; shift ;;
                        -v|-n|--dry-run|--local|--save) shift ;;
                        *) break ;;
                    esac
                done
                ;;
            -s)
                action="show"; shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "show"; exit 0; }
                ;;
            -r)
                action="run"
                shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "run"; exit 0; }
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        -v|-n|--dry-run|--local|--save) shift ;;
                        -*) break ;;
                        *) action_args+=("$1"); shift ;;
                    esac
                done
                ;;
            -f)
                action="search"; shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "search"; exit 0; }
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            -c)
                action="clipboard"
                shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "clipboard"; exit 0; }
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        -v|-n|--dry-run|--local|--save) shift ;;
                        -*) break ;;
                        *) action_args+=("$1"); shift ;;
                    esac
                done
                ;;

            # --- Workspaces ---
            -w|--workspace)
                shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "workspace"; exit 0; }
                if [ "$#" -eq 0 ] || [[ "${1:-}" == -* ]]; then
                    action="show_workspace"
                else
                    action="switch_workspace"
                    action_args+=("$1"); shift
                fi
                ;;
            -W)
                action="list_workspaces"; shift
                ;;

            # --- Environment variables ---
            --env)
                shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "env"; exit 0; }
                if [ "$#" -eq 0 ] || [[ "${1:-}" == -* ]]; then
                    action="show_env"
                elif [[ "$1" == *=* ]]; then
                    action="set_env"
                    action_args+=("$1"); shift
                else
                    action="show_env"
                fi
                ;;
            --env-clear)
                action="clear_env"; shift
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;

            # --- Playbooks & Chains ---
            --chain)
                action="chain"
                shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "chain"; exit 0; }
                while [ "$#" -gt 0 ] && [[ "$1" != -* ]]; do
                    action_args+=("$1"); shift
                done
                ;;
            --playbook)
                action="create_playbook"
                shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "playbook"; exit 0; }
                [ "$#" -ge 1 ] && action_args+=("$1") && shift  # name
                while [ "$#" -gt 0 ] && [[ "$1" != -* ]]; do
                    action_args+=("$1"); shift  # tags
                done
                ;;
            -p)
                action="run_playbook"; shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "playbook"; exit 0; }
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            --playbooks)
                action="list_playbooks"; shift
                ;;

            # --- Notes & Outputs ---
            --note)
                action="add_note"
                shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "note"; exit 0; }
                [ "$#" -ge 1 ] && action_args+=("$1") && shift  # tag
                [ "$#" -ge 1 ] && action_args+=("$1") && shift  # text
                ;;
            --notes)
                action="show_notes"; shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "note"; exit 0; }
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                ;;
            --outputs)
                action="show_outputs"; shift
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                ;;

            # --- Packs ---
            --pack)
                shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "pack"; exit 0; }
                if [ "${1:-}" = "list" ]; then
                    action="list_packs"; shift
                elif [ "${1:-}" = "load" ]; then
                    action="load_pack"; shift
                    [ "$#" -ge 1 ] && action_args+=("$1") && shift
                else
                    echo -e "${RED}Error:${NC} Unknown pack subcommand '${1:-}'. Use 'list' or 'load'." >&2
                    exit 1
                fi
                ;;

            # --- Import/Export ---
            -x)
                action="extract"; shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "extract"; exit 0; }
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            -l)
                action="logs"; shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "logs"; exit 0; }
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;
            -i)
                action="install"; shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "install"; exit 0; }
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;

            # --- General ---
            -m)
                action="interactive"; shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "interactive"; exit 0; }
                ;;
            -u|--undo)      action="undo"; shift ;;
            -h|--help)      action="help"; shift ;;
            -V|--version)   echo "CMDR v${CMDR_VERSION}"; exit 0 ;;

            # Global modifiers (already pre-scanned)
            -v|-n|--dry-run|--local|--save) shift ;;

            *)
                log_event "ERROR" "Invalid option: $1"
                echo -e "${RED}Invalid option: $1${NC}" 1>&2
                exit 1
                ;;
        esac
    done

    # ----- Dispatch -----
    case "$action" in
        # CRUD
        add)              add_command "${action_args[@]}" ;;
        edit)             edit_command "${action_args[@]}" ;;
        delete)           delete_command "${action_args[0]:-}" "$CMDR_FORCE_YES" ;;
        show)             show_commands ;;
        run)              run_command "${action_args[@]}" ;;
        search)           search_commands "${action_args[@]}" ;;
        clipboard)        clipboard_copy "${action_args[@]}" ;;

        # Workspaces
        switch_workspace) switch_workspace "${action_args[0]:-}" ;;
        show_workspace)   show_workspace ;;
        list_workspaces)  list_workspaces ;;

        # Environment
        set_env)          set_env_var "${action_args[0]:-}" ;;
        show_env)         show_env_vars ;;
        clear_env)        clear_env_var "${action_args[0]:-}" ;;

        # Playbooks & Chains
        chain)            chain_commands "${action_args[@]}" ;;
        create_playbook)  create_playbook "${action_args[@]}" ;;
        run_playbook)     run_playbook "${action_args[0]:-}" ;;
        list_playbooks)   list_playbooks ;;

        # Notes & Outputs
        add_note)         add_note "${action_args[0]:-}" "${action_args[1]:-}" ;;
        show_notes)       show_notes "${action_args[0]:-}" ;;
        show_outputs)     show_outputs "${action_args[0]:-}" ;;

        # Import/Export & Packs
        extract)          extract_commands "${action_args[@]}" ;;
        logs)             extract_logs "${action_args[@]}" ;;
        install)          install_commands "${action_args[@]}" ;;
        list_packs)       list_packs ;;
        load_pack)        load_pack "${action_args[0]:-}" ;;

        # General
        interactive)      interactive_mode ;;
        undo)             undo_command ;;
        help)             display_help ;;
        *)                display_help; exit 1 ;;
    esac
}

main "$@"
