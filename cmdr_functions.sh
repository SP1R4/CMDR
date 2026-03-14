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

# Return merged JSON of global/workspace + local commands.
# Local entries override global entries with the same tag.
get_effective_commands() {
    if [ -f "$LOCAL_COMMANDS_FILE" ] && jq -e . "$LOCAL_COMMANDS_FILE" >/dev/null 2>&1 \
       && [ "$(jq 'length' "$LOCAL_COMMANDS_FILE" 2>/dev/null)" -gt 0 ]; then
        jq -s '.[0] * .[1]' "$COMMANDS_FILE" "$LOCAL_COMMANDS_FILE"
    else
        cat "$COMMANDS_FILE"
    fi
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

# Full command resolution pipeline: environment variables first, then
# positional arguments for any remaining {placeholder} tokens.
resolve_command() {
    local cmd="$1"
    shift
    local run_args=("$@")

    # Step 1: substitute environment variables
    cmd=$(resolve_env_vars "$cmd")

    # Step 2: substitute positional parameters for remaining placeholders
    local placeholders
    mapfile -t placeholders < <(grep -oE '\{[a-zA-Z_][a-zA-Z0-9_]*\}' <<< "$cmd" | awk '!seen[$0]++')

    if [ "${#placeholders[@]}" -gt 0 ] && [ -n "${placeholders[0]}" ]; then
        local i=0
        for placeholder in "${placeholders[@]}"; do
            local name="${placeholder:1:${#placeholder}-2}"
            if [ "$i" -lt "${#run_args[@]}" ]; then
                cmd="${cmd//"$placeholder"/${run_args[$i]}}"
            else
                local value
                read -p "Enter value for $name: " value
                cmd="${cmd//"$placeholder"/$value}"
            fi
            ((i++))
        done
    fi

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
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
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
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
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

    backup_commands "$WRITE_COMMANDS_FILE"

    local tmp_file
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
    if ! jq --arg tag "$tag" --argjson entry "$entry" \
        '. + {($tag): $entry}' "$WRITE_COMMANDS_FILE" > "$tmp_file" 2>/dev/null; then
        log_event "ERROR" "jq failed while adding command"
        echo -e "${RED}Error:${NC} Failed to update commands file."
        rm -f "$tmp_file"
        exit 1
    fi
    mv "$tmp_file" "$WRITE_COMMANDS_FILE"

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

    backup_commands "$WRITE_COMMANDS_FILE"

    local tmp_file
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
    if ! jq --arg tag "$tag" --argjson update "$update" \
        '.[$tag] = (.[$tag] * $update)' "$WRITE_COMMANDS_FILE" > "$tmp_file" 2>/dev/null; then
        log_event "ERROR" "jq failed while editing command"
        echo -e "${RED}Error:${NC} Failed to update commands file."
        rm -f "$tmp_file"
        exit 1
    fi
    mv "$tmp_file" "$WRITE_COMMANDS_FILE"

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
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
    if ! jq --arg tag "$tag" 'del(.[$tag])' "$WRITE_COMMANDS_FILE" > "$tmp_file" 2>/dev/null; then
        log_event "ERROR" "jq failed while deleting command"
        echo -e "${RED}Error:${NC} Failed to delete command."
        rm -f "$tmp_file"
        exit 1
    fi
    mv "$tmp_file" "$WRITE_COMMANDS_FILE"

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
        while IFS=$'\t' read -r tag cmd desc alias_str; do
            # Highlight {placeholder} tokens in yellow
            local cmd_display
            cmd_display=$(echo "$cmd" | sed $'s/{[a-zA-Z_][a-zA-Z0-9_]*}/\033[0;33m&\033[0m/g')

            local tag_line
            if [ -n "$alias_str" ]; then
                tag_line=$(printf "    ${CYAN}%-20s${NC}  %b  ${CYAN}(aka: %s)${NC}" "$tag" "$cmd_display" "$alias_str")
            else
                tag_line=$(printf "    ${CYAN}%-20s${NC}  %b" "$tag" "$cmd_display")
            fi
            echo -e "$tag_line"

            if [ -n "$desc" ]; then
                printf "    %-20s  ${YELLOW}# %s${NC}\n" "" "$desc"
            fi
        done < <(jq -r --arg cat "$category" \
            'to_entries[] | select(.value.category == $cat) |
            "\(.key)\t\(.value.command)\t\(.value.description // "")\t\(.value.aliases // [] | join(", "))"' \
            "$file")
        echo ""
    done < <(jq -r '[to_entries[] | .value.category] | unique[]' "$file")

    return 0
}

# Show all commands grouped by category, including workspace and local.
show_commands() {
    log_event "DEBUG" "Showing commands"

    local global_count=0 local_count=0
    [ -s "$COMMANDS_FILE" ] && global_count=$(jq 'length' "$COMMANDS_FILE" 2>/dev/null || echo 0)
    if [ -f "$LOCAL_COMMANDS_FILE" ] && jq -e . "$LOCAL_COMMANDS_FILE" >/dev/null 2>&1; then
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
        ) | "\(.value.category)\t\(.key)\t\(.value.command)\t\(.value.description // "")\t\(.value.aliases // [] | join(", "))"')

    if [ -z "$results" ]; then
        echo -e "${YELLOW}No commands matching '$keyword'.${NC}"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Search results for '${keyword}':${NC}"
    echo ""
    printf "  ${CYAN}%-12s  %-16s  %-30s  %s${NC}\n" "CATEGORY" "TAG" "COMMAND" "DESCRIPTION"

    while IFS=$'\t' read -r cat tag cmd desc alias_str; do
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

# Run a stored command by tag or alias with full resolution pipeline.
run_command() {
    local tag="$1"
    shift
    local run_args=("$@")

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

    local cmd
    cmd=$(echo "$effective" | jq -r --arg tag "$tag" '.[$tag].command // empty')

    if [ -z "$cmd" ]; then
        log_event "ERROR" "Command '$tag' not found"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi

    # Full resolution: env vars -> positional params
    cmd=$(resolve_command "$cmd" "${run_args[@]}")

    # Dry-run: print without executing
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN]${NC} Would execute: $cmd"
        log_event "INFO" "Dry run for '$tag': $cmd"
        return 0
    fi

    echo -e "${GREEN}Running command:${NC} $cmd"

    local start_time status
    start_time=$(date +%s)

    # Execute with optional output capture
    if [ "$SAVE_OUTPUT" = true ]; then
        mkdir -p "$OUTPUTS_DIR"
        local output_file="$OUTPUTS_DIR/${tag}_$(date +%Y%m%d_%H%M%S).log"
        bash -c "$cmd" 2>&1 | tee "$output_file"
        status=${PIPESTATUS[0]}
        echo -e "${CYAN}Output saved to:${NC} $output_file"
    else
        bash -c "$cmd"
        status=$?
    fi

    local end_time elapsed duration
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    duration=$(format_duration "$elapsed")

    echo -e "${CYAN}Completed in ${duration} (exit: $status)${NC}"
    log_event "INFO" "Ran command '$tag': $cmd (exit: $status, ${duration})"
    return $status
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
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
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

    local tags_array
    mapfile -t tags_array < <(jq -r --arg name "$name" '.[$name][]' "$PLAYBOOKS_FILE")

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
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
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
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
    if ! echo "$validated_json" | jq -s '.[0] * .[1]' "$WRITE_COMMANDS_FILE" - > "$tmp_file" 2>/dev/null; then
        log_event "ERROR" "Failed to merge commands"
        echo -e "${RED}Error:${NC} Failed to merge commands."
        rm -f "$tmp_file"
        exit 1
    fi
    mv "$tmp_file" "$WRITE_COMMANDS_FILE"

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
    echo -e "${BOLD}${YELLOW}CMDR Interactive Mode${NC} (select 'exit' to quit)"
    if [ "$ACTIVE_WORKSPACE" != "default" ]; then
        echo -e "${CYAN}Workspace: $ACTIVE_WORKSPACE${NC}"
    fi

    while true; do
        local effective
        effective=$(get_effective_commands)
        local cat_array
        mapfile -t cat_array < <(echo "$effective" | jq -r '[to_entries[] | .value.category] | unique[]' 2>/dev/null)
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
                local cmd_array
                mapfile -t cmd_array < <(echo "$effective" | jq -r --arg cat "$category" \
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
            echo "Usage: cmdr -r <tag> [arg1 arg2 ...] [--save]"
            echo ""
            echo "Run a stored command. Extra args fill {placeholder} parameters."
            echo "Environment variables ({KEY}) are substituted first."
            echo ""
            echo "  --save         Save output to outputs/ directory"
            echo "  -n, --dry-run  Print command without executing"
            echo ""
            echo "Examples:"
            echo "  cmdr -r serve"
            echo "  cmdr -r scan 192.168.1.1"
            echo "  cmdr -r scan --save"
            echo "  cmdr -n -r scan 10.0.0.1"
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
    echo "  -a <tag> <cmd> [cat] [--desc ..] [--alias ..]  Add a command"
    echo "  -e <tag> [cmd] [cat] [--desc ..] [--alias ..]  Edit a command"
    echo "  -d <tag> [-y]                                  Delete a command"
    echo "  -s                                             Show all commands"
    echo "  -r <tag> [args...] [--save]                    Run a command"
    echo "  -f <keyword>                                   Search commands"
    echo "  -c <tag> [args...]                             Copy command to clipboard"
    echo ""
    echo -e "${YELLOW}Workspaces & Environment:${NC}"
    echo "  -w <name>              Switch workspace"
    echo "  -w                     Show active workspace"
    echo "  -W                     List all workspaces"
    echo "  --env KEY=VALUE        Set environment variable"
    echo "  --env                  Show environment variables"
    echo "  --env-clear KEY        Clear environment variable"
    echo "  --local                Use project-local .cmdr.json"
    echo ""
    echo -e "${YELLOW}Playbooks & Chains:${NC}"
    echo "  --chain <tags...>                  Run commands in sequence"
    echo "  --playbook <name> <tags...>        Create a playbook"
    echo "  -p <name>                          Run a playbook"
    echo "  --playbooks                        List playbooks"
    echo ""
    echo -e "${YELLOW}Notes & Outputs:${NC}"
    echo "  --note <tag> \"text\"     Add a note/finding"
    echo "  --notes [tag]           Show notes"
    echo "  --outputs [tag]         Show saved outputs"
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
    echo "  cmdr --env TARGET=10.10.10.1"
    echo "  cmdr -r scan"
    echo "  cmdr -r scan --save"
    echo "  cmdr -c scan"
    echo "  cmdr --note scan 'Found port 8080 open, Tomcat'"
    echo "  cmdr -w htb-box && cmdr --pack load ctf-network"
    echo "  cmdr --playbook recon quick-scan dirfuzz nikto-scan"
    echo "  cmdr -p recon"
    echo "  cmdr --local -a build 'make -j4' dev"
    echo ""
}
