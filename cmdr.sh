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

CMDR_VERSION="3.3.0"

# Resolve the script's install directory (follows symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$( cd -P "$( dirname "$SOURCE" )" &> /dev/null && pwd )"
    SOURCE="$( readlink "$SOURCE" )"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" &> /dev/null && pwd )"

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
LOCK_DIR="${XDG_RUNTIME_DIR:-/tmp}/cmdr.lock.d"
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
HOSTS_FILE="$ACTIVE_DATA_DIR/.cmdr_hosts.json"
FINDINGS_FILE="$ACTIVE_DATA_DIR/.cmdr_findings.json"
HISTORY_FILE="$ACTIVE_DATA_DIR/.cmdr_history.json"
WORKFLOWS_FILE="$ACTIVE_DATA_DIR/.cmdr_workflows.json"
SECRETS_FILE="$ACTIVE_DATA_DIR/.cmdr_secrets.json"
HISTORY_MAX=200
OUTPUTS_DIR="$ACTIVE_DATA_DIR/outputs"
LOCAL_COMMANDS_FILE="$(pwd)/.cmdr.json"

# Trust store for project-local .cmdr.json files (global, keyed by absolute path).
# Local commands are only merged/executed when their current content is trusted.
TRUST_FILE="$DATA_DIR/.cmdr_trusted.json"

# ---------------------------------------------------------------------------
# Global modifier flags (pre-scanned before argument parsing)
# ---------------------------------------------------------------------------
VERBOSITY="INFO"
DRY_RUN=false
SAVE_OUTPUT=false
USE_LOCAL=false
CMDR_JSON=false
CMDR_DESC=""
CMDR_ALIASES=()
CMDR_FORCE_YES=false

# Feature flags collected during argument parsing
CMDR_CAPTURE=""        # --capture VAR[:regex]  (run: stdout -> env var)
CMDR_ON=""             # --on HOST              (run: execute over SSH)
CMDR_ALL_HOSTS=false   # --all-hosts           (run: fan across all hosts)
CMDR_DANGER=false      # --danger              (add/edit: mark destructive)
CMDR_EVIDENCE=""       # --evidence PATH       (finding: attach evidence)
CMDR_HOST_NAME=""      # --name                (host add)
CMDR_HOST_OS=""        # --os                  (host add)
CMDR_HOST_USER=""      # --user                (host add)
CMDR_HOST_PORT=""      # --port                (host add)
CMDR_HOST_HOSTNAME=""  # --hostname            (host add)
CMDR_REPORT_FORMAT=""  # --format              (report: md|csv|html|pdf)

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
# shellcheck source=cmdr_functions.sh
source "$FUNCTIONS_FILE"

if ! command -v jq >/dev/null; then
    echo -e "${RED}Error:${NC} 'jq' is required. Install with 'sudo apt-get install jq'."
    exit 1
fi

initialize_files

# ---------------------------------------------------------------------------
# Lock management (serializes data-store writes only)
# ---------------------------------------------------------------------------
# Only mutating actions acquire the lock, and only for the short duration of
# the write. Read-only and long-running actions (run, interactive, search) stay
# lock-free so a second terminal is never blocked by a running command.
LOCK_ACQUIRED=false

# Portable, atomic lock via `mkdir` (works on macOS and Linux without flock).
# `mkdir` on an existing dir fails atomically, giving mutual exclusion. Since
# writes are short, a contending writer waits briefly (bounded) rather than
# failing outright, so concurrent quick writes queue instead of being dropped.
# A stale lock (owner PID no longer running) is reclaimed immediately.
acquire_lock() {
    local tries=0 max_tries=50   # ~5s total at 0.1s per retry
    while true; do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo "$$ $(date +%s)" > "$LOCK_DIR/pid" 2>/dev/null
            LOCK_ACQUIRED=true
            log_event "DEBUG" "Lock acquired (PID $$)"
            return 0
        fi

        # Lock exists: reclaim it only if the owner is gone AND the lock is older
        # than the grace period. Reclaiming on a dead pid alone is racy — the pid
        # may belong to a holder that just finished and was replaced, so removing
        # the dir would delete a live successor's lock (see _lock_is_stale).
        if _lock_is_stale "$LOCK_DIR"; then
            log_event "DEBUG" "Removing stale lock"
            rm -rf "$LOCK_DIR"
            continue
        fi

        tries=$((tries + 1))
        if [ "$tries" -ge "$max_tries" ]; then
            log_event "ERROR" "Another instance is running ($LOCK_DIR)"
            echo -e "${RED}Another instance is running.${NC}"
            exit 1
        fi
        sleep 0.1
    done
}

cleanup() {
    # Only remove the lock if this process actually holds it, otherwise a
    # read-only invocation would delete a lock held by a concurrent writer.
    [ "$LOCK_ACQUIRED" = true ] || return 0
    rm -rf "$LOCK_DIR"
    log_event "DEBUG" "Lock released (PID $$)"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Main: argument parsing and dispatch
# ---------------------------------------------------------------------------
main() {
    if [ "$#" -eq 0 ]; then
        # On an interactive terminal with fzf, jump straight into the picker.
        if [ -t 1 ] && command -v fzf >/dev/null 2>&1; then
            pick_command
            exit $?
        fi
        display_help
        exit 1
    fi

    # Pre-scan global modifier flags so they're active for all operations.
    # Stop at "--" so flags after it are treated as positional command args.
    for arg in "$@"; do
        [ "$arg" = "--" ] && break
        case "$arg" in
            -v)        VERBOSITY="DEBUG"; log_event "DEBUG" "Verbosity set to DEBUG" ;;
            -n|--dry-run) DRY_RUN=true; log_event "DEBUG" "Dry-run mode enabled" ;;
            --local)   USE_LOCAL=true; log_event "DEBUG" "Local mode enabled" ;;
            --save)    SAVE_OUTPUT=true; log_event "DEBUG" "Save output enabled" ;;
            --json)    CMDR_JSON=true; log_event "DEBUG" "JSON output enabled" ;;
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
                [ "$#" -ge 1 ] && [[ "${1:-}" != --* ]] && action_args+=("$1") && shift
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        --desc)   shift; [ "$#" -ge 1 ] && CMDR_DESC="$1" && shift ;;
                        --alias)  shift; [ "$#" -ge 1 ] && CMDR_ALIASES+=("$1") && shift ;;
                        --danger) CMDR_DANGER=true; shift ;;
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
                [ "$#" -ge 1 ] && [[ "${1:-}" != --* ]] && action_args+=("$1") && shift
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        --desc)   shift; [ "$#" -ge 1 ] && CMDR_DESC="$1" && shift ;;
                        --alias)  shift; [ "$#" -ge 1 ] && CMDR_ALIASES+=("$1") && shift ;;
                        --danger) CMDR_DANGER=true; shift ;;
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
                        --)          shift; while [ "$#" -gt 0 ]; do action_args+=("$1"); shift; done; break ;;
                        --capture)   shift; [ "$#" -ge 1 ] && CMDR_CAPTURE="$1" && shift ;;
                        --on)        shift; [ "$#" -ge 1 ] && CMDR_ON="$1" && shift ;;
                        --all-hosts) CMDR_ALL_HOSTS=true; shift ;;
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
                        --) shift; while [ "$#" -gt 0 ]; do action_args+=("$1"); shift; done; break ;;
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

            # --- Hosts ---
            --host)
                shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "host"; exit 0; }
                case "${1:-}" in
                    add)
                        action="host_add"; shift
                        [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift  # ip
                        while [ "$#" -gt 0 ]; do
                            case "$1" in
                                --name)     shift; [ "$#" -ge 1 ] && CMDR_HOST_NAME="$1" && shift ;;
                                --hostname) shift; [ "$#" -ge 1 ] && CMDR_HOST_HOSTNAME="$1" && shift ;;
                                --os)       shift; [ "$#" -ge 1 ] && CMDR_HOST_OS="$1" && shift ;;
                                --user)     shift; [ "$#" -ge 1 ] && CMDR_HOST_USER="$1" && shift ;;
                                --port)     shift; [ "$#" -ge 1 ] && CMDR_HOST_PORT="$1" && shift ;;
                                -v|-n|--dry-run|--local|--save) shift ;;
                                *) break ;;
                            esac
                        done
                        ;;
                    list|ls) action="host_list"; shift ;;
                    rm|del)  action="host_rm"; shift; [ "$#" -ge 1 ] && action_args+=("$1") && shift ;;
                    *)
                        echo -e "${RED}Error:${NC} Unknown host subcommand '${1:-}'. Use add/list/rm." >&2
                        exit 1 ;;
                esac
                ;;

            # --- Findings & Reporting ---
            --finding)
                action="add_finding"; shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "finding"; exit 0; }
                # Positionals allow a bare "-" (no-host sentinel); only "--flags" stop them.
                [ "$#" -ge 1 ] && [[ "${1:-}" != --* ]] && action_args+=("$1") && shift  # severity
                [ "$#" -ge 1 ] && [[ "${1:-}" != --* ]] && action_args+=("$1") && shift  # host
                [ "$#" -ge 1 ] && [[ "${1:-}" != --* ]] && action_args+=("$1") && shift  # title
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        --evidence) shift; [ "$#" -ge 1 ] && CMDR_EVIDENCE="$1" && shift ;;
                        -v|-n|--dry-run|--local|--save) shift ;;
                        *) break ;;
                    esac
                done
                ;;
            --findings)
                action="list_findings"; shift
                ;;
            --report)
                action="report"; shift
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift  # optional output file
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        --format) shift; [ "$#" -ge 1 ] && CMDR_REPORT_FORMAT="$1" && shift ;;
                        -v|-n|--dry-run|--local|--save) shift ;;
                        *) break ;;
                    esac
                done
                ;;

            # --- History ---
            --history)
                action="show_history"; shift
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift  # optional count
                ;;

            # --- Workflows ---
            --flow)
                shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "flow"; exit 0; }
                case "${1:-}" in
                    run)    action="flow_run"; shift; [ "$#" -ge 1 ] && action_args+=("$1") && shift ;;
                    list|ls) action="flow_list"; shift ;;
                    import) action="flow_import"; shift; [ "$#" -ge 1 ] && action_args+=("$1") && shift ;;
                    show)   action="flow_show"; shift; [ "$#" -ge 1 ] && action_args+=("$1") && shift ;;
                    *) echo -e "${RED}Error:${NC} Unknown flow subcommand '${1:-}'. Use run/list/import/show." >&2; exit 1 ;;
                esac
                ;;

            # --- Secrets ---
            --secret)
                action="set_secret"; shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "secret"; exit 0; }
                [ "$#" -ge 1 ] && action_args+=("$1") && shift  # name
                [ "$#" -ge 1 ] && action_args+=("$1") && shift  # spec
                ;;
            --secrets)
                action="list_secrets"; shift
                ;;
            --secret-clear)
                action="clear_secret"; shift
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
                ;;

            # --- Lint / Sync ---
            --lint)
                action="lint"; shift
                ;;
            --sync)
                action="sync"; shift
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift  # optional message
                ;;
            --sync-remote)
                action="sync_remote"; shift
                [ "$#" -ge 1 ] && action_args+=("$1") && shift
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
            --import)
                action="import_ext"; shift
                [ "${1:-}" = "--help" ] && { display_subcommand_help "import"; exit 0; }
                # source + up to one positional arg (page/topic/path/count); a
                # trailing -y is captured as the force-yes modifier.
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        -y) CMDR_FORCE_YES=true; shift ;;
                        -v|-n|--dry-run|--local|--save|--json) shift ;;
                        *) break ;;
                    esac
                done
                ;;
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
            --pick)         action="pick"; shift ;;
            -I|--menu|--interactive) action="menu"; shift ;;
            --lock-workspace)
                action="lock_workspace"; shift
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                ;;
            --unlock-workspace)
                action="unlock_workspace"; shift
                [ "$#" -ge 1 ] && [[ "${1:-}" != -* ]] && action_args+=("$1") && shift
                ;;
            --trust)        action="trust_local"; shift ;;
            --untrust)      action="untrust_local"; shift ;;
            -u|--undo)      action="undo"; shift ;;
            -h|--help)      action="help"; shift ;;
            -V|--version)   echo "CMDR v${CMDR_VERSION}"; exit 0 ;;

            # Global modifiers (already pre-scanned)
            -v|-n|--dry-run|--local|--save|--json) shift ;;

            *)
                log_event "ERROR" "Invalid option: $1"
                echo -e "${RED}Invalid option: $1${NC}" 1>&2
                exit 1
                ;;
        esac
    done

    # ----- Lock only mutating actions, for the duration of the write -----
    case "$action" in
        add|edit|delete|set_env|clear_env|create_playbook|add_note|install|load_pack|undo|switch_workspace|trust_local|untrust_local|host_add|host_rm|add_finding|lock_workspace|unlock_workspace|flow_import|set_secret|clear_secret|import_ext)
            acquire_lock ;;
    esac

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

        # Hosts
        host_add)         host_add "${action_args[0]:-}" ;;
        host_list)        host_list ;;
        host_rm)          host_rm "${action_args[0]:-}" ;;

        # Findings & Reporting
        add_finding)      add_finding "${action_args[0]:-}" "${action_args[1]:-}" "${action_args[2]:-}" ;;
        list_findings)    list_findings ;;
        report)           generate_report "${action_args[0]:-}" ;;

        # History
        show_history)     show_history "${action_args[0]:-20}" ;;

        # Workflows
        flow_run)         flow_run "${action_args[0]:-}" ;;
        flow_list)        flow_list ;;
        flow_import)      flow_import "${action_args[0]:-}" ;;
        flow_show)        flow_show "${action_args[0]:-}" ;;

        # Secrets
        set_secret)       set_secret "${action_args[0]:-}" "${action_args[1]:-}" ;;
        list_secrets)     list_secrets ;;
        clear_secret)     clear_secret "${action_args[0]:-}" ;;

        # Lint & sync
        lint)             lint_all ;;
        sync)             sync_data "${action_args[0]:-}" ;;
        sync_remote)      sync_set_remote "${action_args[0]:-}" ;;

        # Picker & encrypted workspaces
        pick)             pick_command ;;
        menu)             interactive_menu ;;
        lock_workspace)   lock_workspace "${action_args[0]:-}" ;;
        unlock_workspace) unlock_workspace "${action_args[0]:-}" ;;

        # Import/Export & Packs
        extract)          extract_commands "${action_args[@]}" ;;
        import_ext)       import_external "${action_args[@]}" ;;
        logs)             extract_logs "${action_args[@]}" ;;
        install)          install_commands "${action_args[@]}" ;;
        list_packs)       list_packs ;;
        load_pack)        load_pack "${action_args[0]:-}" ;;

        # Trust
        trust_local)      trust_local ;;
        untrust_local)    untrust_local ;;

        # General
        interactive)      interactive_mode ;;
        undo)             undo_command ;;
        help)             display_help ;;
        *)                display_help; exit 1 ;;
    esac

    # Propagate the dispatched action's exit code (the EXIT trap preserves it).
    exit $?
}

main "$@"
