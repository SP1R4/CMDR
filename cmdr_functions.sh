#!/bin/bash
# ============================================================================
# CMDR v3.0 - Command Manager Functions
# ============================================================================
# Core engine for CMDR: command storage, workspace isolation, environment
# variables, playbooks, output capture, notes, and extensible command packs.
#
# All functions read global variables set by cmdr.sh (COMMANDS_FILE, ENV_FILE,
# NOTES_FILE, PLAYBOOKS_FILE, OUTPUTS_DIR, etc.) and the modifier flags
# (DRY_RUN, SAVE_OUTPUT, USE_LOCAL, CMDR_DESC, CMDR_ALIASES, CMDR_FORCE_YES).
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

# ----------------------------------------------------------------------------
# Section 3: Resolution Helpers
# Resolve tags/aliases across global, workspace, and local command stores.
# Merge environment variables into command templates.
# ----------------------------------------------------------------------------

# Hash a file's contents (used to pin trusted project-local command files).
_hash_file() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" | awk '{print $1}'
    else
        # Weak fallback when no SHA tool exists: byte count.
        wc -c < "$f" | tr -d ' '
    fi
}

# True only when the current project-local .cmdr.json exists and its content
# matches the hash recorded in the trust store. Untrusted/modified files fail.
is_local_trusted() {
    [ -f "$LOCAL_COMMANDS_FILE" ] || return 1
    [ -f "$TRUST_FILE" ] || return 1
    local current stored
    current=$(_hash_file "$LOCAL_COMMANDS_FILE")
    stored=$(jq -r --arg p "$LOCAL_COMMANDS_FILE" '.[$p] // empty' "$TRUST_FILE" 2>/dev/null)
    [ -n "$stored" ] && [ "$stored" = "$current" ]
}

# Print a one-time notice when a non-empty but untrusted .cmdr.json is present.
# Called from main-shell entry points (not subshells) so it fires once.
notify_untrusted_local() {
    if [ -f "$LOCAL_COMMANDS_FILE" ] \
       && [ "$(jq 'length' "$LOCAL_COMMANDS_FILE" 2>/dev/null || echo 0)" -gt 0 ] \
       && ! is_local_trusted; then
        echo -e "${YELLOW}Note:${NC} Ignoring untrusted .cmdr.json in $(pwd)." >&2
        echo -e "      Review it, then run ${CYAN}cmdr --trust${NC} to enable it." >&2
    fi
}

# Record the current local file's hash as trusted (quiet; used after --local writes).
_retrust_local() {
    [ -f "$LOCAL_COMMANDS_FILE" ] || return 0
    [ ! -f "$TRUST_FILE" ] && echo "{}" > "$TRUST_FILE"
    local h tmp_file
    h=$(_hash_file "$LOCAL_COMMANDS_FILE")
    tmp_file=$(_mktemp_beside "$TRUST_FILE")
    jq --arg p "$LOCAL_COMMANDS_FILE" --arg h "$h" '. + {($p): $h}' "$TRUST_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$TRUST_FILE"
}

# Return merged JSON of global/workspace + local commands.
# Local entries override global entries with the same tag, but only when the
# local file is trusted (see is_local_trusted) to avoid auto-running commands
# from an untrusted directory's .cmdr.json.
get_effective_commands() {
    if [ -f "$LOCAL_COMMANDS_FILE" ] && jq -e . "$LOCAL_COMMANDS_FILE" >/dev/null 2>&1 \
       && [ "$(jq 'length' "$LOCAL_COMMANDS_FILE" 2>/dev/null)" -gt 0 ] \
       && is_local_trusted; then
        jq -s '.[0] * .[1]' "$COMMANDS_FILE" "$LOCAL_COMMANDS_FILE"
    else
        cat "$COMMANDS_FILE"
    fi
}

# Approve the current directory's .cmdr.json so its commands are merged and runnable.
trust_local() {
    if [ ! -f "$LOCAL_COMMANDS_FILE" ]; then
        echo -e "${RED}Error:${NC} No .cmdr.json in $(pwd)."
        exit 1
    fi
    if ! jq -e . "$LOCAL_COMMANDS_FILE" >/dev/null 2>&1; then
        echo -e "${RED}Error:${NC} .cmdr.json in $(pwd) is not valid JSON."
        exit 1
    fi
    _retrust_local
    log_event "INFO" "Trusted local file: $LOCAL_COMMANDS_FILE"
    echo -e "${GREEN}Trusted:${NC} $LOCAL_COMMANDS_FILE"
}

# Revoke trust for the current directory's .cmdr.json.
untrust_local() {
    if [ ! -f "$TRUST_FILE" ] \
       || ! jq -e --arg p "$LOCAL_COMMANDS_FILE" 'has($p)' "$TRUST_FILE" >/dev/null 2>&1; then
        echo -e "${YELLOW}Not trusted:${NC} $LOCAL_COMMANDS_FILE"
        return 0
    fi
    local tmp_file
    tmp_file=$(_mktemp_beside "$TRUST_FILE")
    jq --arg p "$LOCAL_COMMANDS_FILE" 'del(.[$p])' "$TRUST_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$TRUST_FILE"
    log_event "INFO" "Untrusted local file: $LOCAL_COMMANDS_FILE"
    echo -e "${GREEN}Untrusted:${NC} $LOCAL_COMMANDS_FILE"
}

# Resolve a user-supplied name to a canonical tag. Checks direct tag match
# first, then scans aliases. Searches effective (merged) commands by default,
# or a specific file if $2 is provided.
resolve_tag_or_alias() {
    local input="$1"
    local file="${2:-}"
    local source

    if [ -n "$file" ]; then
        source=$(cat "$file")
    else
        source=$(get_effective_commands)
    fi

    # Direct tag match
    if echo "$source" | jq -e --arg tag "$input" 'has($tag)' >/dev/null 2>&1; then
        echo "$input"
        return 0
    fi

    # Alias scan
    local resolved
    resolved=$(echo "$source" | jq -r --arg a "$input" \
        'to_entries[] | select((.value.aliases // []) | index($a) != null) | .key' | head -1)
    if [ -n "$resolved" ]; then
        log_event "DEBUG" "Resolved alias '$input' to tag '$resolved'"
        echo "$resolved"
        return 0
    fi

    return 1
}

# Substitute {KEY} placeholders with values from the workspace environment.
# Only exact case matches are replaced.
resolve_env_vars() {
    local cmd="$1"
    if [ ! -f "$ENV_FILE" ] || [ ! -s "$ENV_FILE" ]; then
        echo "$cmd"
        return
    fi
    while IFS=$'\t' read -r key value; do
        cmd="${cmd//\{$key\}/$value}"
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$ENV_FILE" 2>/dev/null)
    echo "$cmd"
}

# Full command resolution pipeline. Placeholder forms, resolved left-to-right:
#   {VAR}            env var, else next positional arg, else interactive prompt
#   {VAR:=default}   env var, else next positional arg, else 'default' (no prompt)
#   {VAR:?}          env var, else next positional arg, else hard error (required)
# Returns non-zero if a required placeholder cannot be satisfied.
resolve_command() {
    local cmd="$1"
    shift
    local run_args=("$@")

    # Step 1: substitute plain {KEY} env vars up front (back-compat / fast path).
    cmd=$(resolve_env_vars "$cmd")

    # Step 2: unified left-to-right pass over remaining placeholders.
    local i=0
    while :; do
        local token
        token=$(printf '%s' "$cmd" \
            | grep -oE '\{[a-zA-Z_][a-zA-Z0-9_]*(:=[^}]*|:\?)?\}' | head -1)
        [ -z "$token" ] && break

        local inner="${token:1:${#token}-2}"   # strip surrounding { }
        local name mod="" default=""
        if [[ "$inner" == *:=* ]]; then
            name="${inner%%:=*}"; default="${inner#*:=}"; mod="default"
        elif [[ "$inner" == *":?" ]]; then
            name="${inner%:?}"; mod="required"
        else
            name="$inner"
        fi

        # Prefer an env value (covers the modifier forms, which step 1 skips).
        local value="" envval=""
        if [ -f "$ENV_FILE" ]; then
            envval=$(jq -r --arg k "$name" '.[$k] // empty' "$ENV_FILE" 2>/dev/null)
        fi

        if [ -n "$envval" ]; then
            value="$envval"
        elif [ "$i" -lt "${#run_args[@]}" ]; then
            value="${run_args[$i]}"; ((i++))
        elif [ "$mod" = "default" ]; then
            value="$default"
        elif [ "$mod" = "required" ]; then
            echo -e "${RED}Error:${NC} Required value '{$name}' not provided." >&2
            return 1
        elif [ "$DRY_RUN" = true ]; then
            # Never block on a prompt during a dry run; show the gap instead.
            value="<$name>"
        else
            read -p "Enter value for $name: " value
        fi

        # Replace every occurrence of this exact token in one shot.
        cmd="${cmd//"$token"/$value}"
    done

    echo "$cmd"
}

# Ensure no alias collides with an existing tag or another entry's alias.
validate_aliases() {
    local current_tag="$1"
    shift
    local new_aliases=("$@")
    local effective
    effective=$(get_effective_commands)

    for a in "${new_aliases[@]}"; do
        # Conflict with existing tag
        if [ "$a" != "$current_tag" ] && echo "$effective" | jq -e --arg tag "$a" 'has($tag)' >/dev/null 2>&1; then
            echo -e "${RED}Error:${NC} Alias '$a' conflicts with existing tag '$a'."
            return 1
        fi
        # Conflict with another entry's alias
        local owner
        owner=$(echo "$effective" | jq -r --arg a "$a" --arg self "$current_tag" \
            'to_entries[] | select(.key != $self) | select((.value.aliases // []) | index($a) != null) | .key' | head -1)
        if [ -n "$owner" ]; then
            echo -e "${RED}Error:${NC} Alias '$a' already in use by '$owner'."
            return 1
        fi
    done
    return 0
}

# ----------------------------------------------------------------------------
# Section 4: Workspace Management
# Workspaces isolate command stores, env vars, notes, playbooks, and outputs.
# The active workspace name is persisted in .cmdr_active_workspace.
# ----------------------------------------------------------------------------

# Switch to a named workspace. Creates the workspace directory if needed.
switch_workspace() {
    local name="$1"

    # Sanitize: workspace names become path components, so reject anything
    # outside [a-zA-Z0-9_-] to prevent path traversal (e.g. -w ../../etc).
    name=$(sanitize_tag "$name") || exit 1

    if [ "$name" = "default" ]; then
        rm -f "$WORKSPACE_FILE"
        log_event "INFO" "Switched to default workspace"
        echo -e "${GREEN}Switched to default workspace.${NC}"
        return 0
    fi

    local ws_dir="$DATA_DIR/workspaces/$name"
    mkdir -p "$ws_dir"

    # Seed workspace with an empty command store
    [ ! -f "$ws_dir/my_commands.json" ] && echo "{}" > "$ws_dir/my_commands.json"

    echo "$name" > "$WORKSPACE_FILE"
    log_event "INFO" "Switched to workspace: $name"
    echo -e "${GREEN}Switched to workspace:${NC} $name"
}

# Print the active workspace name.
show_workspace() {
    if [ "$ACTIVE_WORKSPACE" = "default" ]; then
        echo -e "${GREEN}Active workspace:${NC} default"
    else
        local count
        count=$(jq 'length' "$COMMANDS_FILE" 2>/dev/null || echo 0)
        echo -e "${GREEN}Active workspace:${NC} $ACTIVE_WORKSPACE ($count commands)"
    fi
}

# List all workspaces with command counts.
list_workspaces() {
    echo -e "${BOLD}${YELLOW}Workspaces:${NC}"

    # Default workspace
    local default_count
    default_count=$(jq 'length' "$DATA_DIR/my_commands.json" 2>/dev/null || echo 0)
    local marker=""
    [ "$ACTIVE_WORKSPACE" = "default" ] && marker=" ${GREEN}(active)${NC}"
    echo -e "  ${CYAN}default${NC}${marker}  ($default_count commands)"

    # Named workspaces
    if [ -d "$DATA_DIR/workspaces" ]; then
        while IFS= read -r ws_dir; do
            local ws_name count ws_marker=""
            ws_name=$(basename "$ws_dir")
            count=$(jq 'length' "$ws_dir/my_commands.json" 2>/dev/null || echo 0)
            [ "$ws_name" = "$ACTIVE_WORKSPACE" ] && ws_marker=" ${GREEN}(active)${NC}"
            echo -e "  ${CYAN}${ws_name}${NC}${ws_marker}  ($count commands)"
        done < <(find "$DATA_DIR/workspaces" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

        # Locked (encrypted) workspaces
        while IFS= read -r blob; do
            [ -f "$blob" ] || continue
            local locked_name
            locked_name=$(basename "$blob" .cmdrlock)
            echo -e "  ${CYAN}${locked_name}${NC}  ${YELLOW}(locked)${NC}"
        done < <(find "$DATA_DIR/workspaces" -mindepth 1 -maxdepth 1 -name '*.cmdrlock' 2>/dev/null | sort)
    fi
}

# ----------------------------------------------------------------------------
# Section 5: Environment Variables
# Per-workspace key-value pairs stored in .cmdr_env.json. Referenced in
# commands as {KEY} and substituted at runtime before positional args.
# ----------------------------------------------------------------------------

# Set a workspace-scoped environment variable (KEY=VALUE).
set_env_var() {
    local pair="$1"
    local key="${pair%%=*}"
    local value="${pair#*=}"

    if [ -z "$key" ] || [ "$key" = "$pair" ]; then
        echo -e "${RED}Error:${NC} Invalid format. Use: --env KEY=VALUE"
        exit 1
    fi

    [ ! -f "$ENV_FILE" ] && echo "{}" > "$ENV_FILE"

    local tmp_file
    tmp_file=$(_mktemp_beside "$ENV_FILE")
    jq --arg key "$key" --arg val "$value" '. + {($key): $val}' "$ENV_FILE" > "$tmp_file"
    mv "$tmp_file" "$ENV_FILE"

    log_event "INFO" "Set env var: $key=$value"
    echo -e "${GREEN}Set:${NC} $key=$value"
}

# Display all workspace environment variables.
show_env_vars() {
    if [ ! -f "$ENV_FILE" ] || [ "$(jq 'length' "$ENV_FILE" 2>/dev/null)" -eq 0 ]; then
        echo -e "${YELLOW}No environment variables set.${NC}"
        if [ "$ACTIVE_WORKSPACE" != "default" ]; then
            echo -e "${CYAN}Workspace:${NC} $ACTIVE_WORKSPACE"
        fi
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Environment variables:${NC}"
    if [ "$ACTIVE_WORKSPACE" != "default" ]; then
        echo -e "${CYAN}Workspace:${NC} $ACTIVE_WORKSPACE"
    fi
    echo ""
    jq -r 'to_entries[] | "  \(.key) = \(.value)"' "$ENV_FILE"
}

# Remove a single environment variable by key.
clear_env_var() {
    local key="$1"
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${YELLOW}No environment variables set.${NC}"
        return 0
    fi

    if ! jq -e --arg key "$key" 'has($key)' "$ENV_FILE" >/dev/null 2>&1; then
        echo -e "${YELLOW}Variable '$key' not found.${NC}"
        return 0
    fi

    local tmp_file
    tmp_file=$(_mktemp_beside "$ENV_FILE")
    jq --arg key "$key" 'del(.[$key])' "$ENV_FILE" > "$tmp_file"
    mv "$tmp_file" "$ENV_FILE"

    log_event "INFO" "Cleared env var: $key"
    echo -e "${GREEN}Cleared:${NC} $key"
}

# ----------------------------------------------------------------------------
# Section 6: CRUD Operations
# Add, edit, and delete commands. Writes target WRITE_COMMANDS_FILE which
# is either the global/workspace file or the project-local .cmdr.json
# when --local is active.
# ----------------------------------------------------------------------------

# Add a new tagged command with optional description and aliases.
add_command() {
    local tag="$1"
    local cmd="$2"
    local category="${3:-default}"

    log_event "DEBUG" "add_command: tag='$tag', command='$cmd', category='$category'"

    tag=$(sanitize_tag "$tag") || exit 1
    cmd=$(sanitize_command "$cmd") || exit 1
    category="$(echo "$category" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$category" ] && category="default"

    if ! validate_command "$cmd"; then
        echo -e "${RED}Error:${NC} Command validation failed."
        exit 1
    fi

    # Duplicate check against the target file
    if jq -e --arg tag "$tag" 'has($tag)' "$WRITE_COMMANDS_FILE" >/dev/null 2>&1; then
        log_event "ERROR" "Tag '$tag' already exists"
        echo -e "${RED}Error:${NC} Tag '$tag' already exists. Use -e to edit it."
        exit 1
    fi

    if [ "${#CMDR_ALIASES[@]}" -gt 0 ]; then
        if ! validate_aliases "$tag" "${CMDR_ALIASES[@]}"; then
            exit 1
        fi
    fi

    # Build the entry as a JSON object
    local entry
    entry=$(jq -n --arg cmd "$cmd" --arg cat "$category" '{command: $cmd, category: $cat}')

    if [ -n "$CMDR_DESC" ]; then
        entry=$(echo "$entry" | jq --arg desc "$CMDR_DESC" '. + {description: $desc}')
    fi

    if [ "${#CMDR_ALIASES[@]}" -gt 0 ]; then
        local aliases_json
        aliases_json=$(printf '%s\n' "${CMDR_ALIASES[@]}" | jq -R . | jq -s .)
        entry=$(echo "$entry" | jq --argjson aliases "$aliases_json" '. + {aliases: $aliases}')
    fi

    if [ "$CMDR_DANGER" = true ]; then
        entry=$(echo "$entry" | jq '. + {danger: true}')
    fi

    backup_commands "$WRITE_COMMANDS_FILE"

    local tmp_file
    tmp_file=$(_mktemp_beside "$WRITE_COMMANDS_FILE")
    if ! jq --arg tag "$tag" --argjson entry "$entry" \
        '. + {($tag): $entry}' "$WRITE_COMMANDS_FILE" > "$tmp_file" 2>/dev/null; then
        log_event "ERROR" "jq failed while adding command"
        echo -e "${RED}Error:${NC} Failed to update commands file."
        rm -f "$tmp_file"
        exit 1
    fi
    mv "$tmp_file" "$WRITE_COMMANDS_FILE"

    # Authoring your own local file implies trust; keep its hash current.
    [ "$USE_LOCAL" = true ] && _retrust_local

    local scope=""
    [ "$USE_LOCAL" = true ] && scope=" (local)"
    log_event "INFO" "Added command: tag='$tag', category='$category', command='$cmd'${scope}"
    echo -e "${GREEN}Command added successfully:${NC} '$tag' in category '$category'${scope}."
}

# Edit an existing command's shell string, category, description, or aliases.
edit_command() {
    local tag="$1"
    local new_cmd="$2"
    local new_category="$3"

    tag=$(sanitize_tag "$tag") || exit 1

    local resolved
    resolved=$(resolve_tag_or_alias "$tag" "$WRITE_COMMANDS_FILE")
    if [ -z "$resolved" ]; then
        log_event "ERROR" "Tag '$tag' not found for editing"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi
    tag="$resolved"

    # Interactive prompt when no new command is provided
    if [ -z "$new_cmd" ]; then
        local current
        current=$(jq -r --arg tag "$tag" '.[$tag].command' "$WRITE_COMMANDS_FILE")
        echo -e "${YELLOW}Current command:${NC} $current"
        read -p "New command (leave empty to keep): " new_cmd
        [ -z "$new_cmd" ] && new_cmd="$current"
    fi

    new_cmd=$(sanitize_command "$new_cmd") || exit 1

    if ! validate_command "$new_cmd"; then
        echo -e "${RED}Error:${NC} Command validation failed."
        exit 1
    fi

    if [ "${#CMDR_ALIASES[@]}" -gt 0 ]; then
        if ! validate_aliases "$tag" "${CMDR_ALIASES[@]}"; then
            exit 1
        fi
    fi

    # Build a partial update object and merge onto the existing entry
    local update
    update=$(jq -n --arg cmd "$new_cmd" '{command: $cmd}')

    if [ -n "$new_category" ]; then
        update=$(echo "$update" | jq --arg cat "$new_category" '. + {category: $cat}')
    fi
    if [ -n "$CMDR_DESC" ]; then
        update=$(echo "$update" | jq --arg desc "$CMDR_DESC" '. + {description: $desc}')
    fi
    if [ "${#CMDR_ALIASES[@]}" -gt 0 ]; then
        local aliases_json
        aliases_json=$(printf '%s\n' "${CMDR_ALIASES[@]}" | jq -R . | jq -s .)
        update=$(echo "$update" | jq --argjson aliases "$aliases_json" '. + {aliases: $aliases}')
    fi
    if [ "$CMDR_DANGER" = true ]; then
        update=$(echo "$update" | jq '. + {danger: true}')
    fi

    backup_commands "$WRITE_COMMANDS_FILE"

    local tmp_file
    tmp_file=$(_mktemp_beside "$WRITE_COMMANDS_FILE")
    if ! jq --arg tag "$tag" --argjson update "$update" \
        '.[$tag] = (.[$tag] * $update)' "$WRITE_COMMANDS_FILE" > "$tmp_file" 2>/dev/null; then
        log_event "ERROR" "jq failed while editing command"
        echo -e "${RED}Error:${NC} Failed to update commands file."
        rm -f "$tmp_file"
        exit 1
    fi
    mv "$tmp_file" "$WRITE_COMMANDS_FILE"
    [ "$USE_LOCAL" = true ] && _retrust_local

    log_event "INFO" "Edited command: tag='$tag', command='$new_cmd'"
    echo -e "${GREEN}Command '$tag' updated successfully.${NC}"
}

# Delete a command by tag or alias. Prompts for confirmation unless -y.
delete_command() {
    local tag="$1"
    local force="${2:-false}"

    tag=$(sanitize_tag "$tag") || exit 1

    local resolved
    resolved=$(resolve_tag_or_alias "$tag" "$WRITE_COMMANDS_FILE")
    if [ -z "$resolved" ]; then
        log_event "ERROR" "Command '$tag' not found"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi
    tag="$resolved"

    if [ "$force" != "true" ]; then
        local cmd
        cmd=$(jq -r --arg tag "$tag" '.[$tag].command // empty' "$WRITE_COMMANDS_FILE")
        echo -e "${YELLOW}Command:${NC} $cmd"
        read -p "Delete '$tag'? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo -e "${YELLOW}Cancelled.${NC}"
            return 0
        fi
    fi

    backup_commands "$WRITE_COMMANDS_FILE"

    local tmp_file
    tmp_file=$(_mktemp_beside "$WRITE_COMMANDS_FILE")
    if ! jq --arg tag "$tag" 'del(.[$tag])' "$WRITE_COMMANDS_FILE" > "$tmp_file" 2>/dev/null; then
        log_event "ERROR" "jq failed while deleting command"
        echo -e "${RED}Error:${NC} Failed to delete command."
        rm -f "$tmp_file"
        exit 1
    fi
    mv "$tmp_file" "$WRITE_COMMANDS_FILE"
    [ "$USE_LOCAL" = true ] && _retrust_local

    log_event "INFO" "Deleted command with tag '$tag'"
    echo -e "${GREEN}Command '$tag' deleted successfully.${NC}"
}

# ----------------------------------------------------------------------------
# Section 7: Display & Search
# Show commands by category, search across tags/commands/descriptions/aliases.
# Both functions display from effective (merged global+local) commands.
# ----------------------------------------------------------------------------

# Render a single file's commands grouped by category.
_display_commands_from_file() {
    local file="$1"

    if [ ! -s "$file" ] || ! jq -e 'length > 0' "$file" >/dev/null 2>&1; then
        return 1
    fi

    while IFS= read -r category; do
        echo -e "  ${BOLD}${GREEN}[$category]${NC}"
        while IFS=$'\037' read -r tag cmd desc alias_str danger; do
            # Highlight {placeholder} tokens in yellow
            local cmd_display
            cmd_display=$(echo "$cmd" | sed $'s/{[a-zA-Z_][a-zA-Z0-9_]*}/\033[0;33m&\033[0m/g')

            # Mark dangerous commands
            local danger_mark=""
            [ "$danger" = "true" ] && danger_mark=" ${RED}${BOLD}[!]${NC}"

            local tag_line
            if [ -n "$alias_str" ]; then
                tag_line=$(printf "    ${CYAN}%-20s${NC}  %b%b  ${CYAN}(aka: %s)${NC}" "$tag" "$cmd_display" "$danger_mark" "$alias_str")
            else
                tag_line=$(printf "    ${CYAN}%-20s${NC}  %b%b" "$tag" "$cmd_display" "$danger_mark")
            fi
            echo -e "$tag_line"

            if [ -n "$desc" ]; then
                printf "    %-20s  ${YELLOW}# %s${NC}\n" "" "$desc"
            fi
        done < <(jq -r --arg cat "$category" \
            'to_entries[] | select(.value.category == $cat) |
            [.key, .value.command, (.value.description // ""), (.value.aliases // [] | join(", ")), (.value.danger // false | tostring)] | join("\u001f")' \
            "$file")
        echo ""
    done < <(jq -r '[to_entries[] | .value.category] | unique[]' "$file")

    return 0
}

# Show all commands grouped by category, including workspace and local.
show_commands() {
    log_event "DEBUG" "Showing commands"

    notify_untrusted_local

    local global_count=0 local_count=0
    [ -s "$COMMANDS_FILE" ] && global_count=$(jq 'length' "$COMMANDS_FILE" 2>/dev/null || echo 0)
    # Only count/show local commands when the local file is trusted.
    if [ -f "$LOCAL_COMMANDS_FILE" ] && jq -e . "$LOCAL_COMMANDS_FILE" >/dev/null 2>&1 \
       && is_local_trusted; then
        local_count=$(jq 'length' "$LOCAL_COMMANDS_FILE" 2>/dev/null || echo 0)
    fi

    if [ "$global_count" -eq 0 ] && [ "$local_count" -eq 0 ]; then
        echo -e "${YELLOW}No commands available.${NC}"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Available commands:${NC}"
    if [ "$ACTIVE_WORKSPACE" != "default" ]; then
        echo -e "  ${CYAN}Workspace: $ACTIVE_WORKSPACE${NC}"
    fi
    echo ""

    if [ "$global_count" -gt 0 ]; then
        _display_commands_from_file "$COMMANDS_FILE"
    fi

    if [ "$local_count" -gt 0 ]; then
        echo -e "  ${BOLD}${YELLOW}── Project-Local ($(basename "$(pwd)")) ──${NC}"
        echo ""
        _display_commands_from_file "$LOCAL_COMMANDS_FILE"
    fi

    log_event "INFO" "Displayed commands"
}

# Search across effective (merged) commands by keyword. Matches tag, command,
# category, description, and aliases (case-insensitive).
search_commands() {
    local keyword="$1"
    if [ -z "$keyword" ]; then
        echo -e "${RED}Error:${NC} Search keyword required."
        exit 1
    fi

    log_event "DEBUG" "Searching for: '$keyword'"

    notify_untrusted_local
    local effective
    effective=$(get_effective_commands)

    local results
    results=$(echo "$effective" | jq -r --arg kw "$keyword" \
        'to_entries[] | select(
            (.key | ascii_downcase | contains($kw | ascii_downcase)) or
            (.value.command | ascii_downcase | contains($kw | ascii_downcase)) or
            (.value.category | ascii_downcase | contains($kw | ascii_downcase)) or
            ((.value.description // "") | ascii_downcase | contains($kw | ascii_downcase)) or
            ((.value.aliases // []) | any(ascii_downcase | contains($kw | ascii_downcase)))
        ) | [.value.category, .key, .value.command, (.value.description // ""), (.value.aliases // [] | join(", "))] | join("\u001f")')

    if [ -z "$results" ]; then
        echo -e "${YELLOW}No commands matching '$keyword'.${NC}"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Search results for '${keyword}':${NC}"
    echo ""
    printf "  ${CYAN}%-12s  %-16s  %-30s  %s${NC}\n" "CATEGORY" "TAG" "COMMAND" "DESCRIPTION"

    while IFS=$'\037' read -r cat tag cmd desc alias_str; do
        local cmd_display
        cmd_display=$(echo "$cmd" | sed $'s/{[a-zA-Z_][a-zA-Z0-9_]*}/\033[0;33m&\033[0m/g')

        local tag_display="$tag"
        [ -n "$alias_str" ] && tag_display="$tag (aka: $alias_str)"

        printf "  %-12s  %-16s  %b" "$cat" "$tag_display" "$cmd_display"
        [ -n "$desc" ] && printf "  ${YELLOW}# %s${NC}" "$desc"
        printf "\n"
    done <<< "$results"

    log_event "INFO" "Search completed for '$keyword'"
}

# ----------------------------------------------------------------------------
# Section 8: Execution Engine
# Run commands with env-var and placeholder substitution, timing, optional
# output capture (--save), dry-run, clipboard copy, and command chaining.
# ----------------------------------------------------------------------------

# Run a stored command by tag or alias. Supports host targeting (@name / --on /
# --all-hosts), output capture (--capture), danger confirmation, and history.
run_command() {
    local tag="$1"
    shift
    local run_args=("$@")

    notify_untrusted_local

    # History re-run: `cmdr -r !` or `cmdr -r last`
    if [ "$tag" = "!" ] || [ "$tag" = "last" ]; then
        rerun_last
        return $?
    fi

    tag=$(sanitize_tag "$tag") || exit 1

    local resolved
    resolved=$(resolve_tag_or_alias "$tag")
    if [ -z "$resolved" ]; then
        log_event "ERROR" "Command '$tag' not found"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi
    tag="$resolved"

    local effective
    effective=$(get_effective_commands)

    local cmd danger
    cmd=$(echo "$effective" | jq -r --arg tag "$tag" '.[$tag].command // empty')
    danger=$(echo "$effective" | jq -r --arg tag "$tag" '.[$tag].danger // false')

    if [ -z "$cmd" ]; then
        log_event "ERROR" "Command '$tag' not found"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi

    # Pull any @host selector out of the positional args.
    local host_sel="" filtered_args=()
    local a
    for a in "${run_args[@]}"; do
        if [ "${a:0:1}" = "@" ]; then host_sel="${a:1}"; else filtered_args+=("$a"); fi
    done
    run_args=("${filtered_args[@]}")
    # --on implies a host target for SSH.
    [ -n "$CMDR_ON" ] && [ -z "$host_sel" ] && host_sel="$CMDR_ON"

    # Build the list of hosts to run against ("" = a single local, host-less run).
    local hosts=()
    if [ "$CMDR_ALL_HOSTS" = true ]; then
        local h
        while IFS= read -r h; do [ -n "$h" ] && hosts+=("$h"); done < <(list_host_names)
        if [ "${#hosts[@]}" -eq 0 ]; then
            echo -e "${RED}Error:${NC} No hosts defined. Add one with 'cmdr --host add'."
            exit 1
        fi
    elif [ -n "$host_sel" ]; then
        hosts=("$host_sel")
    else
        hosts=("")
    fi

    local overall=0
    local hcmd label rcmd st
    for h in "${hosts[@]}"; do
        hcmd="$cmd"
        label="$tag"
        if [ -n "$h" ]; then
            if ! _host_exists "$h"; then
                echo -e "${RED}Error:${NC} Unknown host '$h'."
                overall=1; continue
            fi
            hcmd=$(apply_host_vars "$hcmd" "$h")
            label="$tag@$h"
        fi
        if ! rcmd=$(resolve_command "$hcmd" "${run_args[@]}"); then
            overall=1; continue
        fi
        _run_one "$tag" "$label" "$rcmd" "$h" "$danger"
        st=$?
        [ "$st" -ne 0 ] && overall=$st
    done
    return $overall
}

# Execute a single fully-resolved invocation: danger gate, dry-run, local or
# remote (SSH) execution, output capture/save, timing, and history.
_run_one() {
    local tag="$1" label="$2" cmd="$3" host="$4" danger="$5"

    # Danger gate: always confirm, even under -y, unless dry-running.
    if [ "$danger" = "true" ] && [ "$DRY_RUN" != true ]; then
        echo -e "${RED}${BOLD}DANGER:${NC} $cmd"
        read -p "Run this command marked dangerous? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo -e "${YELLOW}Skipped '$label'.${NC}"
            return 0
        fi
    fi

    # Wrap for remote execution when --on targets a host.
    local exec_cmd="$cmd"
    if [ -n "$CMDR_ON" ] && [ -n "$host" ]; then
        if ! exec_cmd=$(build_ssh_cmd "$host" "$cmd"); then
            return 1
        fi
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN]${NC} (${label}) Would execute: $exec_cmd"
        log_event "INFO" "Dry run for '$label': $exec_cmd"
        return 0
    fi

    echo -e "${GREEN}Running (${label}):${NC} $cmd"

    local start_time status output output_file=""
    start_time=$(date +%s)

    if [ -n "$CMDR_CAPTURE" ]; then
        # Capture stdout into a var (stderr still streams to the terminal).
        output=$(bash -c "$exec_cmd")
        status=$?
        printf '%s\n' "$output"
        if [ "$SAVE_OUTPUT" = true ]; then
            mkdir -p "$OUTPUTS_DIR"
            output_file="$OUTPUTS_DIR/${tag}_$(date +%Y%m%d_%H%M%S).log"
            printf '%s\n' "$output" > "$output_file"
        fi
        _capture_store "$output"
    elif [ "$SAVE_OUTPUT" = true ]; then
        mkdir -p "$OUTPUTS_DIR"
        output_file="$OUTPUTS_DIR/${tag}_$(date +%Y%m%d_%H%M%S).log"
        bash -c "$exec_cmd" 2>&1 | tee "$output_file"
        status=${PIPESTATUS[0]}
    else
        bash -c "$exec_cmd"
        status=$?
    fi

    local end_time elapsed duration
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    duration=$(format_duration "$elapsed")

    [ -n "$output_file" ] && echo -e "${CYAN}Output saved to:${NC} $output_file"
    echo -e "${CYAN}Completed in ${duration} (exit: $status)${NC}"
    record_history "$tag" "$cmd" "$host" "$status" "$duration"
    log_event "INFO" "Ran '$label': $cmd (exit: $status, ${duration})"
    return $status
}

# Store captured output into a workspace env var. CMDR_CAPTURE is "VAR" or
# "VAR:regex"; with a regex, the first match is stored, else the trimmed output.
_capture_store() {
    local output="$1"
    local var="${CMDR_CAPTURE%%:*}"
    local regex=""
    [ "$CMDR_CAPTURE" != "$var" ] && regex="${CMDR_CAPTURE#*:}"

    var=$(sanitize_tag "$var") || return 1

    local value
    if [ -n "$regex" ]; then
        value=$(printf '%s\n' "$output" | grep -oE "$regex" | head -1)
    else
        value=$(printf '%s' "$output" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi

    [ ! -f "$ENV_FILE" ] && echo "{}" > "$ENV_FILE"
    local tmp_file
    tmp_file=$(_mktemp_beside "$ENV_FILE")
    jq --arg k "$var" --arg v "$value" '. + {($k): $v}' "$ENV_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$ENV_FILE"
    log_event "INFO" "Captured env var $var from '$tag'"
    echo -e "${GREEN}Captured${NC} {$var} = ${value}"
}

# Run multiple tagged commands in sequence. Stops on first failure.
chain_commands() {
    local tags=("$@")

    if [ "${#tags[@]}" -eq 0 ]; then
        echo -e "${RED}Error:${NC} No commands specified for chain."
        exit 1
    fi

    echo -e "${BOLD}${GREEN}Running chain:${NC} ${tags[*]}"
    echo ""

    local step=1
    for tag in "${tags[@]}"; do
        echo -e "${CYAN}[${step}/${#tags[@]}] Running: $tag${NC}"
        run_command "$tag"
        local status=$?
        if [ $status -ne 0 ] && [ "$DRY_RUN" != true ]; then
            echo -e "${RED}Chain stopped: '$tag' failed (exit: $status)${NC}"
            return $status
        fi
        ((step++))
        echo ""
    done

    echo -e "${GREEN}Chain completed successfully.${NC}"
}

# Copy the fully-resolved command to the system clipboard instead of running it.
clipboard_copy() {
    local tag="$1"
    shift
    local run_args=("$@")

    notify_untrusted_local
    tag=$(sanitize_tag "$tag") || exit 1

    local resolved
    resolved=$(resolve_tag_or_alias "$tag")
    if [ -z "$resolved" ]; then
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi
    tag="$resolved"

    local effective
    effective=$(get_effective_commands)

    local cmd
    cmd=$(echo "$effective" | jq -r --arg tag "$tag" '.[$tag].command // empty')

    if [ -z "$cmd" ]; then
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi

    cmd=$(resolve_command "$cmd" "${run_args[@]}")

    # Try available clipboard tools in order of preference
    if command -v xclip >/dev/null 2>&1; then
        echo -n "$cmd" | xclip -selection clipboard
    elif command -v xsel >/dev/null 2>&1; then
        echo -n "$cmd" | xsel --clipboard --input
    elif command -v pbcopy >/dev/null 2>&1; then
        echo -n "$cmd" | pbcopy
    elif command -v wl-copy >/dev/null 2>&1; then
        echo -n "$cmd" | wl-copy
    else
        echo -e "${YELLOW}No clipboard tool found.${NC} Command:"
        echo "$cmd"
        log_event "WARNING" "No clipboard tool available"
        return 1
    fi

    echo -e "${GREEN}Copied to clipboard:${NC} $cmd"
    log_event "INFO" "Copied command '$tag' to clipboard"
}

# ----------------------------------------------------------------------------
# Section 8b: Host / Target Model
# Per-workspace inventory of hosts. Commands reference {TARGET}/{RHOST}/{OS}/
# {RUSER}/{RPORT}; selecting a host (@name, --on, --all-hosts) fills them.
# ----------------------------------------------------------------------------

# True if a host with the given name exists.
_host_exists() {
    [ -f "$HOSTS_FILE" ] && jq -e --arg n "$1" 'has($n)' "$HOSTS_FILE" >/dev/null 2>&1
}

# Read a single field of a host (ip/hostname/os/user/port).
_host_get() {
    [ -f "$HOSTS_FILE" ] || return 1
    jq -r --arg n "$1" --arg f "$2" '.[$n][$f] // empty' "$HOSTS_FILE" 2>/dev/null
}

# Print all host names, one per line.
list_host_names() {
    [ -f "$HOSTS_FILE" ] || return 0
    jq -r 'keys[]' "$HOSTS_FILE" 2>/dev/null
}

# Substitute host placeholders in a command for the named host.
apply_host_vars() {
    local cmd="$1" name="$2"
    local ip host os user port target
    ip=$(_host_get "$name" ip)
    host=$(_host_get "$name" hostname)
    os=$(_host_get "$name" os)
    user=$(_host_get "$name" user)
    port=$(_host_get "$name" port)
    target="${ip:-$host}"

    cmd="${cmd//\{TARGET\}/$target}"
    cmd="${cmd//\{RHOST\}/$target}"
    [ -n "$host" ] && cmd="${cmd//\{RHOSTNAME\}/$host}"
    [ -n "$os" ]   && cmd="${cmd//\{OS\}/$os}"
    [ -n "$user" ] && cmd="${cmd//\{RUSER\}/$user}"
    [ -n "$port" ] && cmd="${cmd//\{RPORT\}/$port}"
    echo "$cmd"
}

# Build an `ssh ...` command string (for bash -c) that runs cmd on a host.
build_ssh_cmd() {
    local host="$1" cmd="$2"
    local ip hostname user port target dest
    ip=$(_host_get "$host" ip)
    hostname=$(_host_get "$host" hostname)
    user=$(_host_get "$host" user)
    port=$(_host_get "$host" port)
    target="${ip:-$hostname}"

    if [ -z "$target" ]; then
        echo -e "${RED}Error:${NC} Host '$host' has no ip/hostname for SSH." >&2
        return 1
    fi

    dest="$target"
    [ -n "$user" ] && dest="$user@$target"

    if [ -n "$port" ]; then
        printf 'ssh -p %q %q %q' "$port" "$dest" "$cmd"
    else
        printf 'ssh %q %q' "$dest" "$cmd"
    fi
}

# Add or update a host. IP is positional; name/os/user/port/hostname via flags.
host_add() {
    local ip="$1"
    if [ -z "$ip" ]; then
        echo -e "${RED}Error:${NC} Usage: cmdr --host add <ip> --name <name> [--hostname h] [--os o] [--user u] [--port p]"
        exit 1
    fi

    local name="${CMDR_HOST_NAME:-$ip}"
    name=$(sanitize_tag "$name") || exit 1

    [ ! -f "$HOSTS_FILE" ] && echo "{}" > "$HOSTS_FILE"

    local entry
    entry=$(jq -n --arg ip "$ip" '{ip: $ip}')
    [ -n "$CMDR_HOST_HOSTNAME" ] && entry=$(echo "$entry" | jq --arg v "$CMDR_HOST_HOSTNAME" '. + {hostname: $v}')
    [ -n "$CMDR_HOST_OS" ]       && entry=$(echo "$entry" | jq --arg v "$CMDR_HOST_OS" '. + {os: $v}')
    [ -n "$CMDR_HOST_USER" ]     && entry=$(echo "$entry" | jq --arg v "$CMDR_HOST_USER" '. + {user: $v}')
    [ -n "$CMDR_HOST_PORT" ]     && entry=$(echo "$entry" | jq --arg v "$CMDR_HOST_PORT" '. + {port: $v}')

    local tmp_file
    tmp_file=$(_mktemp_beside "$HOSTS_FILE")
    jq --arg n "$name" --argjson e "$entry" '. + {($n): $e}' "$HOSTS_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$HOSTS_FILE"

    log_event "INFO" "Host added: $name ($ip)"
    echo -e "${GREEN}Host added:${NC} $name ($ip)"
}

# List all hosts in the active workspace.
host_list() {
    if [ ! -f "$HOSTS_FILE" ] || [ "$(jq 'length' "$HOSTS_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}No hosts defined.${NC}"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Hosts:${NC}"
    if [ "$ACTIVE_WORKSPACE" != "default" ]; then
        echo -e "${CYAN}Workspace: $ACTIVE_WORKSPACE${NC}"
    fi
    echo ""
    printf "  ${CYAN}%-16s  %-16s  %-20s  %-10s  %s${NC}\n" "NAME" "IP" "HOSTNAME" "OS" "USER"
    # Use ASCII Unit Separator (0x1f) so empty middle fields aren't collapsed
    # by read's IFS-whitespace merging.
    jq -r 'to_entries[] | [.key, (.value.ip//""), (.value.hostname//""), (.value.os//""), (.value.user//"")] | join("\u001f")' "$HOSTS_FILE" \
        | while IFS=$'\037' read -r name ip hn os user; do
            printf "  %-16s  %-16s  %-20s  %-10s  %s\n" "$name" "$ip" "$hn" "$os" "$user"
        done
}

# Remove a host by name.
host_rm() {
    local name="$1"
    if [ -z "$name" ]; then
        echo -e "${RED}Error:${NC} Usage: cmdr --host rm <name>"
        exit 1
    fi
    if ! _host_exists "$name"; then
        echo -e "${YELLOW}Host '$name' not found.${NC}"
        return 0
    fi
    local tmp_file
    tmp_file=$(_mktemp_beside "$HOSTS_FILE")
    jq --arg n "$name" 'del(.[$n])' "$HOSTS_FILE" > "$tmp_file" && mv "$tmp_file" "$HOSTS_FILE"
    log_event "INFO" "Host removed: $name"
    echo -e "${GREEN}Host removed:${NC} $name"
}

# ----------------------------------------------------------------------------
# Section 8c: Run History
# Append-only (capped) log of executed commands. Enables review and re-run.
# ----------------------------------------------------------------------------

# Record one run. Capped to the last $HISTORY_MAX entries.
record_history() {
    local tag="$1" cmd="$2" host="$3" status="$4" duration="$5"
    [ ! -f "$HISTORY_FILE" ] && echo "[]" > "$HISTORY_FILE"
    local ts
    ts=$(date +"%Y-%m-%d %T")
    local tmp_file
    tmp_file=$(_mktemp_beside "$HISTORY_FILE")
    jq --arg ts "$ts" --arg tag "$tag" --arg cmd "$cmd" --arg host "$host" \
       --arg st "$status" --arg dur "$duration" --argjson max "$HISTORY_MAX" \
       '. + [{timestamp:$ts, tag:$tag, command:$cmd, host:$host, exit:($st|tonumber), duration:$dur}] | .[-$max:]' \
       "$HISTORY_FILE" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$HISTORY_FILE"
}

# Show recent history (default 20 entries, newest first).
show_history() {
    local count="${1:-20}"
    if [ ! -f "$HISTORY_FILE" ] || [ "$(jq 'length' "$HISTORY_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}No run history.${NC}"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Run history (last $count):${NC}"
    echo ""
    jq -r --argjson n "$count" '.[-$n:] | reverse | .[]
        | [.timestamp, (.exit|tostring), .tag, (.host // ""), .command] | join("\u001f")' "$HISTORY_FILE" \
        | while IFS=$'\037' read -r ts ex tag host cmd; do
            local mark="${GREEN}ok${NC}"
            [ "$ex" != "0" ] && mark="${RED}$ex${NC}"
            local label="$tag"
            [ -n "$host" ] && label="$tag@$host"
            printf "  ${CYAN}%s${NC}  [%b]  %-18s  %s\n" "$ts" "$mark" "$label" "$cmd"
        done
}

# Re-run the most recent history entry (by tag, re-resolving env/host).
rerun_last() {
    if [ ! -f "$HISTORY_FILE" ] || [ "$(jq 'length' "$HISTORY_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${RED}Error:${NC} No run history."
        exit 1
    fi
    local last_tag last_host
    last_tag=$(jq -r '.[-1].tag // empty' "$HISTORY_FILE")
    last_host=$(jq -r '.[-1].host // empty' "$HISTORY_FILE")
    if [ -z "$last_tag" ]; then
        echo -e "${RED}Error:${NC} No run history."
        exit 1
    fi
    echo -e "${CYAN}Re-running:${NC} $last_tag${last_host:+ @$last_host}"
    if [ -n "$last_host" ]; then
        run_command "$last_tag" "@$last_host"
    else
        run_command "$last_tag"
    fi
}

# ----------------------------------------------------------------------------
# Section 8d: Findings & Reporting
# Structured findings (severity/host/title/evidence) and a markdown report
# that bundles hosts, findings, notes, and recent history.
# ----------------------------------------------------------------------------

# Record a finding. Severity must be critical/high/medium/low/info.
add_finding() {
    local severity="$1" host="$2" title="$3"
    if [ -z "$severity" ] || [ -z "$title" ]; then
        echo -e "${RED}Error:${NC} Usage: cmdr --finding <severity> <host> \"title\" [--evidence path]"
        echo -e "Severity: critical | high | medium | low | info  (use '-' for no host)"
        exit 1
    fi
    severity=$(echo "$severity" | tr '[:upper:]' '[:lower:]')
    case "$severity" in
        critical|high|medium|low|info) ;;
        *) echo -e "${RED}Error:${NC} Severity must be critical/high/medium/low/info."; exit 1 ;;
    esac
    [ "$host" = "-" ] && host=""

    [ ! -f "$FINDINGS_FILE" ] && echo "[]" > "$FINDINGS_FILE"
    local ts
    ts=$(date +"%Y-%m-%d %T")
    local tmp_file
    tmp_file=$(_mktemp_beside "$FINDINGS_FILE")
    jq --arg sev "$severity" --arg host "$host" --arg title "$title" \
       --arg ev "$CMDR_EVIDENCE" --arg ts "$ts" \
       '. + [{severity:$sev, host:$host, title:$title, evidence:$ev, timestamp:$ts}]' \
       "$FINDINGS_FILE" > "$tmp_file" && mv "$tmp_file" "$FINDINGS_FILE"

    log_event "INFO" "Finding added: [$severity] $title"
    echo -e "${GREEN}Finding recorded:${NC} [${severity}] $title"
}

# List findings, ordered by severity (critical first).
list_findings() {
    if [ ! -f "$FINDINGS_FILE" ] || [ "$(jq 'length' "$FINDINGS_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}No findings.${NC}"
        return 0
    fi
    echo -e "${BOLD}${YELLOW}Findings:${NC}"
    if [ "$ACTIVE_WORKSPACE" != "default" ]; then
        echo -e "${CYAN}Workspace: $ACTIVE_WORKSPACE${NC}"
    fi
    echo ""
    jq -r '
        def rank: {"critical":0,"high":1,"medium":2,"low":3,"info":4}[.severity] // 5;
        sort_by(rank) | .[]
        | [.severity, (.host // ""), .title, (.evidence // ""), .timestamp] | join("\u001f")' "$FINDINGS_FILE" \
        | while IFS=$'\037' read -r sev host title ev ts; do
            local color="$CYAN"
            case "$sev" in
                critical|high) color="$RED" ;;
                medium) color="$YELLOW" ;;
                low|info) color="$GREEN" ;;
            esac
            printf "  ${color}%-9s${NC} %-14s %s\n" "[$sev]" "${host:-—}" "$title"
            [ -n "$ev" ] && printf "            ${CYAN}evidence:${NC} %s\n" "$ev"
        done
}

# Generate a markdown engagement report. Writes to $1 if given, else stdout.
generate_report() {
    local out="${1:-}"
    local ts
    ts=$(date +"%Y-%m-%d %T")

    _report_body() {
        echo "# Engagement Report — ${ACTIVE_WORKSPACE}"
        echo ""
        echo "_Generated: ${ts}_"
        echo ""

        echo "## Hosts"
        echo ""
        if [ -f "$HOSTS_FILE" ] && [ "$(jq 'length' "$HOSTS_FILE" 2>/dev/null || echo 0)" -gt 0 ]; then
            echo "| Name | IP | Hostname | OS | User |"
            echo "|------|----|----------|----|------|"
            jq -r 'to_entries[] | "| \(.key) | \(.value.ip // "") | \(.value.hostname // "") | \(.value.os // "") | \(.value.user // "") |"' "$HOSTS_FILE"
        else
            echo "_None recorded._"
        fi
        echo ""

        echo "## Findings"
        echo ""
        if [ -f "$FINDINGS_FILE" ] && [ "$(jq 'length' "$FINDINGS_FILE" 2>/dev/null || echo 0)" -gt 0 ]; then
            jq -r '
                def rank: {"critical":0,"high":1,"medium":2,"low":3,"info":4}[.severity] // 5;
                sort_by(rank) | .[]
                | "### [\(.severity | ascii_upcase)] \(.title)\n\n"
                  + "- Host: \(if (.host // "") == "" then "—" else .host end)\n"
                  + "- Time: \(.timestamp)\n"
                  + (if (.evidence // "") == "" then "" else "- Evidence: `\(.evidence)`\n" end)' "$FINDINGS_FILE"
        else
            echo "_None recorded._"
        fi
        echo ""

        echo "## Notes"
        echo ""
        if [ -f "$NOTES_FILE" ] && [ "$(jq 'length' "$NOTES_FILE" 2>/dev/null || echo 0)" -gt 0 ]; then
            jq -r 'to_entries[] | "### \(.key)\n\n" + (.value | map("- [\(.timestamp)] \(.note)") | join("\n")) + "\n"' "$NOTES_FILE"
        else
            echo "_None recorded._"
        fi
        echo ""

        echo "## Recent Command History"
        echo ""
        if [ -f "$HISTORY_FILE" ] && [ "$(jq 'length' "$HISTORY_FILE" 2>/dev/null || echo 0)" -gt 0 ]; then
            echo "| Time | Exit | Tag | Host | Command |"
            echo "|------|------|-----|------|---------|"
            jq -r '.[-30:] | reverse | .[] | "| \(.timestamp) | \(.exit) | \(.tag) | \(.host // "") | `\(.command)` |"' "$HISTORY_FILE"
        else
            echo "_None recorded._"
        fi
    }

    if [ -n "$out" ]; then
        _report_body > "$out"
        log_event "INFO" "Report written to $out"
        echo -e "${GREEN}Report written to:${NC} $out"
    else
        _report_body
    fi
}

# ----------------------------------------------------------------------------
# Section 8e: Fuzzy Picker
# fzf-driven command selector. Falls back to interactive mode without fzf.
# ----------------------------------------------------------------------------

pick_command() {
    if ! command -v fzf >/dev/null 2>&1; then
        echo -e "${YELLOW}fzf not found.${NC} Falling back to interactive mode."
        interactive_mode
        return $?
    fi

    notify_untrusted_local
    local effective
    effective=$(get_effective_commands)

    if [ "$(echo "$effective" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}No commands available.${NC}"
        return 0
    fi

    local sel
    sel=$(echo "$effective" \
        | jq -r 'to_entries[] | "\(.key)\t\(.value.command)\t\(.value.description // "")"' \
        | fzf --delimiter='\t' --with-nth=1,3 \
              --preview 'echo {2}' --preview-window=down,3,wrap \
              --prompt='cmdr> ' --height=60%)
    [ -z "$sel" ] && return 0

    local tag
    tag=$(printf '%s' "$sel" | cut -f1)
    [ -n "$tag" ] && run_command "$tag"
}

# ----------------------------------------------------------------------------
# Section 8f: Encrypted Workspaces
# Encrypt a named workspace's directory to a single blob at rest (age or gpg).
# ----------------------------------------------------------------------------

# True if an encryption backend is available.
_have_crypto() {
    command -v age >/dev/null 2>&1 || command -v gpg >/dev/null 2>&1
}

# Encrypt stdin to file $1 (prompts for passphrase).
_encrypt_stdin_to() {
    if command -v age >/dev/null 2>&1; then
        age -p -o "$1"
    elif command -v gpg >/dev/null 2>&1; then
        gpg --batch --yes -c -o "$1"
    else
        return 1
    fi
}

# Decrypt file $1 to stdout (prompts for passphrase).
_decrypt_to_stdout() {
    if command -v age >/dev/null 2>&1; then
        age -d "$1"
    elif command -v gpg >/dev/null 2>&1; then
        gpg -d "$1"
    else
        return 1
    fi
}

# Encrypt a named workspace dir into <name>.cmdrlock and remove the plaintext.
lock_workspace() {
    local name="${1:-$ACTIVE_WORKSPACE}"
    if [ "$name" = "default" ]; then
        echo -e "${RED}Error:${NC} The default workspace cannot be locked. Use a named workspace."
        exit 1
    fi
    name=$(sanitize_tag "$name") || exit 1
    if ! _have_crypto; then
        echo -e "${RED}Error:${NC} Need 'age' or 'gpg' installed to encrypt."
        exit 1
    fi

    local ws_dir="$DATA_DIR/workspaces/$name"
    local blob="$DATA_DIR/workspaces/${name}.cmdrlock"
    if [ ! -d "$ws_dir" ]; then
        echo -e "${RED}Error:${NC} Workspace '$name' not found."
        exit 1
    fi
    if [ -f "$blob" ]; then
        echo -e "${RED}Error:${NC} An encrypted blob for '$name' already exists."
        exit 1
    fi

    echo -e "${CYAN}Encrypting workspace '$name'...${NC}"
    if tar -czf - -C "$DATA_DIR/workspaces" "$name" | _encrypt_stdin_to "$blob"; then
        rm -rf "$ws_dir"
        # If we just locked the active workspace, drop back to default.
        [ "$name" = "$ACTIVE_WORKSPACE" ] && rm -f "$WORKSPACE_FILE"
        log_event "INFO" "Locked workspace: $name"
        echo -e "${GREEN}Workspace locked:${NC} $blob"
    else
        rm -f "$blob"
        echo -e "${RED}Error:${NC} Encryption failed."
        exit 1
    fi
}

# Decrypt <name>.cmdrlock back into a workspace directory.
unlock_workspace() {
    local name="$1"
    if [ -z "$name" ]; then
        echo -e "${RED}Error:${NC} Usage: cmdr --unlock-workspace <name>"
        exit 1
    fi
    name=$(sanitize_tag "$name") || exit 1

    local ws_dir="$DATA_DIR/workspaces/$name"
    local blob="$DATA_DIR/workspaces/${name}.cmdrlock"
    if [ ! -f "$blob" ]; then
        echo -e "${RED}Error:${NC} No encrypted blob for '$name'."
        exit 1
    fi
    if [ -d "$ws_dir" ]; then
        echo -e "${RED}Error:${NC} Plaintext workspace '$name' already exists."
        exit 1
    fi

    echo -e "${CYAN}Decrypting workspace '$name'...${NC}"
    if _decrypt_to_stdout "$blob" | tar -xzf - -C "$DATA_DIR/workspaces"; then
        rm -f "$blob"
        log_event "INFO" "Unlocked workspace: $name"
        echo -e "${GREEN}Workspace unlocked:${NC} $name"
    else
        rm -rf "$ws_dir"
        echo -e "${RED}Error:${NC} Decryption failed (wrong passphrase?)."
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# Section 9: Playbooks
# Named sequences of tags executed in order. Stored in .cmdr_playbooks.json.
# ----------------------------------------------------------------------------

# Create a named playbook from a list of tag names.
create_playbook() {
    local name="$1"
    shift
    local tags=("$@")

    if [ -z "$name" ] || [ "${#tags[@]}" -eq 0 ]; then
        echo -e "${RED}Error:${NC} Usage: cmdr --playbook <name> <tag1> <tag2> ..."
        exit 1
    fi

    [ ! -f "$PLAYBOOKS_FILE" ] && echo "{}" > "$PLAYBOOKS_FILE"

    local tags_json
    tags_json=$(printf '%s\n' "${tags[@]}" | jq -R . | jq -s .)

    local tmp_file
    tmp_file=$(_mktemp_beside "$PLAYBOOKS_FILE")
    jq --arg name "$name" --argjson tags "$tags_json" \
        '. + {($name): $tags}' "$PLAYBOOKS_FILE" > "$tmp_file"
    mv "$tmp_file" "$PLAYBOOKS_FILE"

    log_event "INFO" "Created playbook: $name (${tags[*]})"
    echo -e "${GREEN}Playbook '$name' created:${NC} ${tags[*]}"
}

# Execute all commands in a named playbook sequentially.
run_playbook() {
    local name="$1"

    if [ ! -f "$PLAYBOOKS_FILE" ]; then
        echo -e "${RED}Error:${NC} No playbooks defined."
        exit 1
    fi

    local tags_json
    tags_json=$(jq -r --arg name "$name" '.[$name] // empty' "$PLAYBOOKS_FILE")

    if [ -z "$tags_json" ] || [ "$tags_json" = "null" ]; then
        echo -e "${RED}Error:${NC} Playbook '$name' not found."
        exit 1
    fi

    echo -e "${BOLD}${GREEN}Running playbook: $name${NC}"
    echo ""

    local tags_array=()
    while IFS= read -r _t; do tags_array+=("$_t"); done \
        < <(jq -r --arg name "$name" '.[$name][]' "$PLAYBOOKS_FILE")

    local step=1
    for tag in "${tags_array[@]}"; do
        echo -e "${CYAN}[${step}/${#tags_array[@]}] Running: $tag${NC}"
        run_command "$tag"
        local status=$?
        if [ $status -ne 0 ] && [ "$DRY_RUN" != true ]; then
            echo -e "${RED}Playbook stopped: '$tag' failed (exit: $status)${NC}"
            return $status
        fi
        ((step++))
        echo ""
    done

    echo -e "${GREEN}Playbook '$name' completed successfully.${NC}"
}

# List all defined playbooks with their step counts.
list_playbooks() {
    if [ ! -f "$PLAYBOOKS_FILE" ] || [ "$(jq 'length' "$PLAYBOOKS_FILE" 2>/dev/null)" -eq 0 ]; then
        echo -e "${YELLOW}No playbooks defined.${NC}"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Playbooks:${NC}"
    echo ""

    while IFS=$'\t' read -r name tags_str; do
        local count
        count=$(jq -r --arg name "$name" '.[$name] | length' "$PLAYBOOKS_FILE")
        printf "  ${CYAN}%-20s${NC}  %d steps  [%s]\n" "$name" "$count" "$tags_str"
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value | join(" -> "))"' "$PLAYBOOKS_FILE")
}

# ----------------------------------------------------------------------------
# Section 10: Notes & Output Capture
# Timestamped annotations per tag (findings, observations).
# Saved command output files in the outputs/ directory.
# ----------------------------------------------------------------------------

# Attach a timestamped note to a command tag.
add_note() {
    local tag="$1"
    local note_text="$2"

    if [ -z "$tag" ] || [ -z "$note_text" ]; then
        echo -e "${RED}Error:${NC} Usage: cmdr --note <tag> \"text\""
        exit 1
    fi

    local resolved
    resolved=$(resolve_tag_or_alias "$tag")
    if [ -z "$resolved" ]; then
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi
    tag="$resolved"

    [ ! -f "$NOTES_FILE" ] && echo "{}" > "$NOTES_FILE"

    local timestamp
    timestamp=$(date +"%Y-%m-%d %T")

    local tmp_file
    tmp_file=$(_mktemp_beside "$NOTES_FILE")
    jq --arg tag "$tag" --arg note "$note_text" --arg ts "$timestamp" \
        '.[$tag] = ((.[$tag] // []) + [{timestamp: $ts, note: $note}])' \
        "$NOTES_FILE" > "$tmp_file"
    mv "$tmp_file" "$NOTES_FILE"

    log_event "INFO" "Note added to '$tag'"
    echo -e "${GREEN}Note added to '$tag'.${NC}"
}

# Display all notes for a given command tag.
show_notes() {
    local tag="$1"

    if [ -z "$tag" ]; then
        # Show all notes across all tags
        if [ ! -f "$NOTES_FILE" ] || [ "$(jq 'length' "$NOTES_FILE" 2>/dev/null)" -eq 0 ]; then
            echo -e "${YELLOW}No notes found.${NC}"
            return 0
        fi
        echo -e "${BOLD}${YELLOW}All notes:${NC}"
        echo ""
        while IFS= read -r t; do
            echo -e "  ${CYAN}[$t]${NC}"
            jq -r --arg tag "$t" '.[$tag][] | "    [\(.timestamp)] \(.note)"' "$NOTES_FILE"
            echo ""
        done < <(jq -r 'keys[]' "$NOTES_FILE")
        return 0
    fi

    local resolved
    resolved=$(resolve_tag_or_alias "$tag")
    if [ -z "$resolved" ]; then
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi
    tag="$resolved"

    if [ ! -f "$NOTES_FILE" ]; then
        echo -e "${YELLOW}No notes for '$tag'.${NC}"
        return 0
    fi

    local count
    count=$(jq -r --arg tag "$tag" '(.[$tag] // []) | length' "$NOTES_FILE")

    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}No notes for '$tag'.${NC}"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Notes for '$tag':${NC}"
    jq -r --arg tag "$tag" '.[$tag][] | "  [\(.timestamp)] \(.note)"' "$NOTES_FILE"
}

# List saved output files, optionally filtered by tag prefix.
show_outputs() {
    local tag_filter="${1:-}"

    if [ ! -d "$OUTPUTS_DIR" ]; then
        echo -e "${YELLOW}No saved outputs.${NC}"
        return 0
    fi

    local pattern="*.log"
    [ -n "$tag_filter" ] && pattern="${tag_filter}_*.log"

    echo -e "${BOLD}${YELLOW}Saved outputs:${NC}"
    echo ""

    local found=false
    while IFS= read -r output_file; do
        found=true
        local filename size
        filename=$(basename "$output_file")
        size=$(du -h "$output_file" | cut -f1)
        printf "  ${CYAN}%-45s${NC}  %s\n" "$filename" "$size"
    done < <(find "$OUTPUTS_DIR" -name "$pattern" -type f 2>/dev/null | sort -r)

    if [ "$found" = false ]; then
        echo -e "${YELLOW}No outputs found${tag_filter:+ for '$tag_filter'}.${NC}"
    fi
}

# ----------------------------------------------------------------------------
# Section 11: Import, Export & Command Packs
# Import/export JSON files, and load pre-built command packs from packs/.
# ----------------------------------------------------------------------------

# Export all commands to a JSON file.
extract_commands() {
    local output_file="$1"
    if [ -z "$output_file" ]; then
        echo -e "${RED}Error:${NC} Output file path required."
        exit 1
    fi

    if [ ! -s "$COMMANDS_FILE" ] || [ "$(jq 'length' "$COMMANDS_FILE")" -eq 0 ]; then
        echo -e "${YELLOW}No commands to extract.${NC}"
        return 0
    fi

    jq '.' "$COMMANDS_FILE" > "$output_file"
    log_event "INFO" "Extracted commands to: $output_file"
    echo -e "${GREEN}Commands extracted to:${NC} $output_file"
}

# Export the log file.
extract_logs() {
    local output_file="$1"
    if [ -z "$output_file" ]; then
        echo -e "${RED}Error:${NC} Output file path required."
        exit 1
    fi

    if [ ! -s "$LOG_FILE" ]; then
        echo -e "${YELLOW}Log file is empty.${NC}"
        return 0
    fi

    cp "$LOG_FILE" "$output_file"
    log_event "INFO" "Extracted logs to: $output_file"
    echo -e "${GREEN}Logs extracted to:${NC} $output_file"
}

# Import and merge commands from a JSON file. Single-pass validation with jq
# filters invalid tags and empty commands in one shot (O(1) jq calls).
install_commands() {
    local input_file="$1"
    if [ -z "$input_file" ] || [ ! -f "$input_file" ]; then
        echo -e "${RED}Error:${NC} Input file not provided or does not exist."
        exit 1
    fi

    if [ ! -s "$input_file" ]; then
        echo -e "${RED}Error:${NC} Input file is empty."
        exit 1
    fi

    if ! jq -e . "$input_file" >/dev/null 2>&1; then
        echo -e "${RED}Error:${NC} Input file is not valid JSON."
        exit 1
    fi

    # Single-pass: validate tags, filter empties, default categories
    local validated_json
    validated_json=$(jq '
        to_entries
        | map(select(
            (.key | test("^[a-zA-Z0-9_-]+$")) and
            ((.value.command // "") | length > 0)
        ))
        | map(.value.category //= "default")
        | from_entries
    ' "$input_file")

    local total imported skipped
    total=$(jq 'length' "$input_file")
    imported=$(echo "$validated_json" | jq 'length')
    skipped=$((total - imported))

    if [ "$imported" -eq 0 ]; then
        echo -e "${YELLOW}No valid commands to import.${NC}"
        return 0
    fi

    backup_commands "$WRITE_COMMANDS_FILE"

    local tmp_file
    tmp_file=$(_mktemp_beside "$WRITE_COMMANDS_FILE")
    if ! echo "$validated_json" | jq -s '.[0] * .[1]' "$WRITE_COMMANDS_FILE" - > "$tmp_file" 2>/dev/null; then
        log_event "ERROR" "Failed to merge commands"
        echo -e "${RED}Error:${NC} Failed to merge commands."
        rm -f "$tmp_file"
        exit 1
    fi
    mv "$tmp_file" "$WRITE_COMMANDS_FILE"
    [ "$USE_LOCAL" = true ] && _retrust_local

    log_event "INFO" "Installed $imported commands from: $input_file ($skipped skipped)"
    echo -e "${GREEN}Imported $imported commands${NC} ($skipped skipped)."
}

# List available command packs from the packs/ directory.
list_packs() {
    if [ ! -d "$PACKS_DIR" ]; then
        echo -e "${YELLOW}No packs directory found.${NC}"
        return 0
    fi

    local found=false
    echo -e "${BOLD}${YELLOW}Available command packs:${NC}"
    echo ""

    for pack_file in "$PACKS_DIR"/*.json; do
        [ ! -f "$pack_file" ] && continue
        found=true
        local pack_name count categories
        pack_name=$(basename "$pack_file" .json)
        count=$(jq 'length' "$pack_file" 2>/dev/null || echo 0)
        categories=$(jq -r '[.[] | .category] | unique | join(", ")' "$pack_file" 2>/dev/null)
        printf "  ${CYAN}%-20s${NC}  %d commands  [%s]\n" "$pack_name" "$count" "$categories"
    done

    if [ "$found" = false ]; then
        echo -e "${YELLOW}No packs available.${NC}"
    fi
}

# Load a named pack by importing its JSON file.
load_pack() {
    local name="$1"
    local pack_file="$PACKS_DIR/${name}.json"

    if [ ! -f "$pack_file" ]; then
        echo -e "${RED}Error:${NC} Pack '$name' not found."
        echo -e "Run ${CYAN}cmdr --pack list${NC} to see available packs."
        exit 1
    fi

    echo -e "${GREEN}Loading pack:${NC} $name"
    install_commands "$pack_file"
}

# ----------------------------------------------------------------------------
# Section 12: Interactive Mode
# Menu-driven interface for browsing and running commands.
# ----------------------------------------------------------------------------

interactive_mode() {
    log_event "INFO" "Entered interactive mode"
    notify_untrusted_local
    echo -e "${BOLD}${YELLOW}CMDR Interactive Mode${NC} (select 'exit' to quit)"
    if [ "$ACTIVE_WORKSPACE" != "default" ]; then
        echo -e "${CYAN}Workspace: $ACTIVE_WORKSPACE${NC}"
    fi

    while true; do
        local effective
        effective=$(get_effective_commands)
        local cat_array=()
        while IFS= read -r _c; do cat_array+=("$_c"); done \
            < <(echo "$effective" | jq -r '[to_entries[] | .value.category] | unique[]' 2>/dev/null)
        if [ "${#cat_array[@]}" -eq 0 ]; then
            echo -e "${YELLOW}No commands available.${NC}"
            return 0
        fi

        echo -e "\n${GREEN}Categories:${NC}"
        select category in "${cat_array[@]}" "exit"; do
            if [ "$category" = "exit" ]; then
                log_event "INFO" "Exited interactive mode"
                echo -e "${GREEN}Bye.${NC}"
                return 0
            fi
            if [ -n "$category" ]; then
                echo -e "\n${GREEN}Commands in '$category':${NC}"
                local cmd_array=()
                while IFS= read -r _k; do cmd_array+=("$_k"); done \
                    < <(echo "$effective" | jq -r --arg cat "$category" \
                        'to_entries[] | select(.value.category == $cat) | .key')
                if [ "${#cmd_array[@]}" -eq 0 ]; then
                    echo -e "${YELLOW}No commands in '$category'.${NC}"
                    break
                fi
                select tag in "${cmd_array[@]}" "back"; do
                    if [ "$tag" = "back" ]; then
                        break
                    fi
                    if [ -n "$tag" ]; then
                        local cmd
                        cmd=$(echo "$effective" | jq -r --arg tag "$tag" '.[$tag].command')
                        echo -e "${YELLOW}Command:${NC} $cmd"
                        read -p "Run this command? (y/N): " choice
                        if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
                            run_command "$tag"
                        fi
                    fi
                    break
                done
            fi
            break
        done
    done
}

# ----------------------------------------------------------------------------
# Section 13: Help System
# Main help display and per-subcommand help pages.
# ----------------------------------------------------------------------------

# Per-subcommand help pages shown via `cmdr <flag> --help`.
display_subcommand_help() {
    case "$1" in
        add)
            echo "Usage: cmdr -a <tag> <command> [category] [--desc \"text\"] [--alias name]..."
            echo ""
            echo "Add a new command to the store."
            echo ""
            echo "  tag          Unique name (alphanumeric, hyphens, underscores)"
            echo "  command      Shell command to store (quote if it contains spaces)"
            echo "  category     Optional grouping (default: 'default')"
            echo "  --desc       Add a description"
            echo "  --alias      Add an alias (repeatable)"
            echo "  --local      Store in project-local .cmdr.json"
            echo ""
            echo "Examples:"
            echo "  cmdr -a serve 'python3 -m http.server 8080' dev"
            echo "  cmdr -a scan 'nmap {TARGET} -sV' security --desc 'Service scan' --alias s"
            echo "  cmdr --local -a build 'make -j4' dev"
            ;;
        edit)
            echo "Usage: cmdr -e <tag> [command] [category] [--desc \"text\"] [--alias name]..."
            echo ""
            echo "Edit an existing command. Omit command to be prompted."
            echo ""
            echo "  --desc       Update description"
            echo "  --alias      Set aliases (repeatable, replaces existing)"
            ;;
        delete)
            echo "Usage: cmdr -d <tag> [-y]"
            echo ""
            echo "Delete a command (prompts for confirmation)."
            echo ""
            echo "  -y    Skip confirmation prompt"
            ;;
        show)
            echo "Usage: cmdr -s"
            echo ""
            echo "Show all commands grouped by category."
            echo "Includes workspace and project-local commands."
            ;;
        run)
            echo "Usage: cmdr -r <tag|!|last> [arg1 arg2 ...] [@host] [options]"
            echo ""
            echo "Run a stored command. Extra args fill {placeholder} parameters."
            echo "Environment variables ({KEY}) are substituted first."
            echo "Placeholder forms: {VAR}, {VAR:=default}, {VAR:?} (required)."
            echo "Use '!' or 'last' to re-run the most recent command."
            echo ""
            echo "  --save           Save output to outputs/ directory"
            echo "  --capture VAR    Store stdout into env {VAR} (or VAR:regex)"
            echo "  @host            Fill {TARGET}/{RHOST}/{OS}/{RUSER}/{RPORT} from a host"
            echo "  --on <host>      Execute the command on <host> over SSH"
            echo "  --all-hosts      Run once per defined host"
            echo "  -n, --dry-run    Print command without executing"
            echo "  --               End of options: pass following tokens as literal args"
            echo ""
            echo "Examples:"
            echo "  cmdr -r scan 192.168.1.1"
            echo "  cmdr -r scan @dc01 --save"
            echo "  cmdr -r get-token --capture TOKEN:'eyJ[A-Za-z0-9._-]+'"
            echo "  cmdr -r linpeas --on dc01"
            echo "  cmdr -r nmap --all-hosts"
            echo "  cmdr -r last"
            ;;
        search)
            echo "Usage: cmdr -f <keyword>"
            echo ""
            echo "Search commands by tag, command, category, description, or alias."
            ;;
        extract)
            echo "Usage: cmdr -x <output_file>"
            echo ""
            echo "Export all commands to a JSON file."
            ;;
        logs)
            echo "Usage: cmdr -l <output_file>"
            echo ""
            echo "Export log file."
            ;;
        install)
            echo "Usage: cmdr -i <input_file>"
            echo ""
            echo "Import and merge commands from a JSON file."
            ;;
        interactive)
            echo "Usage: cmdr -m"
            echo ""
            echo "Enter interactive mode to browse and run commands."
            ;;
        clipboard)
            echo "Usage: cmdr -c <tag> [arg1 arg2 ...]"
            echo ""
            echo "Copy the resolved command to clipboard instead of running it."
            echo "Supports env var and placeholder substitution."
            ;;
        workspace)
            echo "Usage: cmdr -w <name>     Switch workspace"
            echo "       cmdr -w            Show active workspace"
            echo "       cmdr -W            List all workspaces"
            echo ""
            echo "Workspaces isolate commands, env vars, notes, playbooks, and outputs."
            echo "Use 'default' to return to the default workspace."
            ;;
        env)
            echo "Usage: cmdr --env KEY=VALUE   Set a variable"
            echo "       cmdr --env             Show all variables"
            echo "       cmdr --env-clear KEY   Remove a variable"
            echo ""
            echo "Variables are per-workspace and substitute {KEY} in commands at runtime."
            ;;
        chain)
            echo "Usage: cmdr --chain <tag1> <tag2> [tag3 ...]"
            echo ""
            echo "Run multiple commands in sequence. Stops on first failure."
            ;;
        playbook)
            echo "Usage: cmdr --playbook <name> <tag1> <tag2> ...   Create a playbook"
            echo "       cmdr -p <name>                             Run a playbook"
            echo "       cmdr --playbooks                           List playbooks"
            echo ""
            echo "Playbooks are named sequences of command tags."
            ;;
        note)
            echo "Usage: cmdr --note <tag> \"text\"   Add a note"
            echo "       cmdr --notes [tag]          Show notes"
            echo ""
            echo "Attach timestamped findings or observations to commands."
            ;;
        pack)
            echo "Usage: cmdr --pack list           List available packs"
            echo "       cmdr --pack load <name>    Import a command pack"
            echo ""
            echo "Packs are pre-built command sets for CTF, development, etc."
            ;;
        host)
            echo "Usage: cmdr --host add <ip> --name <name> [--hostname h] [--os o] [--user u] [--port p]"
            echo "       cmdr --host list"
            echo "       cmdr --host rm <name>"
            echo ""
            echo "Hosts populate {TARGET}/{RHOST}/{RHOSTNAME}/{OS}/{RUSER}/{RPORT} when a"
            echo "command runs against them via '@name', '--on name', or '--all-hosts'."
            echo ""
            echo "Examples:"
            echo "  cmdr --host add 10.10.10.5 --name dc01 --os windows --user admin"
            echo "  cmdr -r winrm @dc01"
            echo "  cmdr -r nmap --all-hosts"
            ;;
        finding)
            echo "Usage: cmdr --finding <severity> <host> \"title\" [--evidence path]"
            echo "       cmdr --findings            List findings"
            echo "       cmdr --report [file]       Render a markdown engagement report"
            echo ""
            echo "Severity: critical | high | medium | low | info   (use '-' for no host)"
            echo ""
            echo "Examples:"
            echo "  cmdr --finding high dc01 \"Unauth WinRM\" --evidence outputs/winrm_x.log"
            echo "  cmdr --report engagement.md"
            ;;
    esac
}

# Main help page with all available flags and examples.
display_help() {
    echo ""
    echo -e "${GREEN}   ██████╗███╗   ███╗██████╗ ██████╗ ${NC}"
    echo -e "${GREEN}  ██╔════╝████╗ ████║██╔══██╗██╔══██╗${NC}"
    echo -e "${GREEN}  ██║     ██╔████╔██║██║  ██║██████╔╝${NC}"
    echo -e "${GREEN}  ██║     ██║╚██╔╝██║██║  ██║██╔══██╗${NC}"
    echo -e "${GREEN}  ╚██████╗██║ ╚═╝ ██║██████╔╝██║  ██║${NC}"
    echo -e "${GREEN}   ╚═════╝╚═╝     ╚═╝╚═════╝ ╚═╝  ╚═╝${NC}"
    echo -e "  ${CYAN}Command Manager v${CMDR_VERSION}${NC}"
    echo ""
    echo -e "${YELLOW}Usage:${NC} cmdr [options]"
    echo ""
    echo -e "${YELLOW}Command Management:${NC}"
    echo "  -a <tag> <cmd> [cat] [--desc ..] [--alias ..] [--danger]  Add a command"
    echo "  -e <tag> [cmd] [cat] [--desc ..] [--alias ..] [--danger]  Edit a command"
    echo "  -d <tag> [-y]                                  Delete a command"
    echo "  -s                                             Show all commands"
    echo "  -r <tag|!|last> [args...] [@host] [opts]        Run a command"
    echo "  -f <keyword>                                   Search commands"
    echo "  -c <tag> [args...]                             Copy command to clipboard"
    echo "  --pick                                         Fuzzy-pick a command (fzf)"
    echo ""
    echo -e "${YELLOW}Run Options (with -r):${NC}"
    echo "  --save                 Save output to outputs/"
    echo "  --capture VAR[:regex]  Store stdout into env {VAR}"
    echo "  @host / --on <host>    Target a host (fill vars / run over SSH)"
    echo "  --all-hosts            Run once per defined host"
    echo ""
    echo -e "${YELLOW}Workspaces & Environment:${NC}"
    echo "  -w <name>              Switch workspace"
    echo "  -w                     Show active workspace"
    echo "  -W                     List all workspaces"
    echo "  --env KEY=VALUE        Set environment variable"
    echo "  --env                  Show environment variables"
    echo "  --env-clear KEY        Clear environment variable"
    echo "  --local                Use project-local .cmdr.json"
    echo "  --trust                Trust the current dir's .cmdr.json"
    echo "  --untrust              Revoke trust for the current dir's .cmdr.json"
    echo "  --lock-workspace [n]   Encrypt a named workspace at rest (age/gpg)"
    echo "  --unlock-workspace <n> Decrypt a locked workspace"
    echo ""
    echo -e "${YELLOW}Hosts:${NC}"
    echo "  --host add <ip> --name <n> [--os ..] [--user ..] [--port ..]"
    echo "  --host list            List hosts"
    echo "  --host rm <name>       Remove a host"
    echo ""
    echo -e "${YELLOW}Playbooks & Chains:${NC}"
    echo "  --chain <tags...>                  Run commands in sequence"
    echo "  --playbook <name> <tags...>        Create a playbook"
    echo "  -p <name>                          Run a playbook"
    echo "  --playbooks                        List playbooks"
    echo ""
    echo -e "${YELLOW}Notes, Findings & History:${NC}"
    echo "  --note <tag> \"text\"               Add a note"
    echo "  --notes [tag]                      Show notes"
    echo "  --outputs [tag]                    Show saved outputs"
    echo "  --finding <sev> <host> \"title\"     Record a finding"
    echo "  --findings                         List findings"
    echo "  --report [file]                    Markdown engagement report"
    echo "  --history [n]                      Show recent run history"
    echo ""
    echo -e "${YELLOW}Import/Export & Packs:${NC}"
    echo "  -x <file>              Export commands to JSON"
    echo "  -l <file>              Export logs"
    echo "  -i <file>              Import commands (merge)"
    echo "  --pack list            List available packs"
    echo "  --pack load <name>     Load a command pack"
    echo ""
    echo -e "${YELLOW}General:${NC}"
    echo "  -m                     Interactive mode"
    echo "  -u, --undo             Undo last change"
    echo "  -n, --dry-run          Show command without running"
    echo "  -v                     Enable debug logging"
    echo "  -V, --version          Show version"
    echo "  -h, --help             Show this help"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  cmdr -a scan 'nmap {TARGET} -sV' security --desc 'Service scan'"
    echo "  cmdr --host add 10.10.10.5 --name dc01 --os windows"
    echo "  cmdr -r scan @dc01 --save"
    echo "  cmdr -r get-token --capture TOKEN && cmdr -r whoami-api"
    echo "  cmdr -r linpeas --on dc01"
    echo "  cmdr --finding high dc01 'Unauth WinRM' && cmdr --report report.md"
    echo "  cmdr -p recon   # cmdr -r last   # cmdr --history"
    echo ""
}
