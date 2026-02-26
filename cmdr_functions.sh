#!/bin/bash
# CMDR v2.1 - Functions

# Initialize files
initialize_files() {
    log_event "DEBUG" "Initializing files: COMMANDS_FILE=$COMMANDS_FILE, LOG_FILE=$LOG_FILE"

    # Create data directory if needed
    if [ ! -d "$DATA_DIR" ]; then
        mkdir -p "$DATA_DIR" || { echo -e "${RED}Error:${NC} Failed to create data directory."; exit 1; }
    fi

    if [ ! -f "$COMMANDS_FILE" ]; then
        echo "{}" > "$COMMANDS_FILE" || { echo -e "${RED}Error:${NC} Failed to create commands file."; exit 1; }
        log_event "INFO" "Created commands file: $COMMANDS_FILE"
    fi
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE" || { echo -e "${RED}Error:${NC} Failed to create log file."; exit 1; }
        log_event "INFO" "Created log file: $LOG_FILE"
    fi
    # Verify COMMANDS_FILE is valid JSON
    if ! jq -e . "$COMMANDS_FILE" >/dev/null 2>&1; then
        log_event "ERROR" "Invalid JSON in $COMMANDS_FILE, resetting to empty object"
        echo "{}" > "$COMMANDS_FILE" || { echo -e "${RED}Error:${NC} Failed to reset commands file."; exit 1; }
    fi
}

# Log function with levels
log_event() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %T")

    # If LOG_FILE isn't set yet, skip
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

# Create a backup of the commands file before modification
backup_commands() {
    if [ -f "$COMMANDS_FILE" ]; then
        cp "$COMMANDS_FILE" "$BACKUP_FILE"
        log_event "DEBUG" "Backup created: $BACKUP_FILE"
    fi
}

# Restore commands from backup (single-level undo)
undo_command() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo -e "${RED}Error:${NC} No backup found. Nothing to undo."
        exit 1
    fi
    cp "$BACKUP_FILE" "$COMMANDS_FILE"
    rm -f "$BACKUP_FILE"
    log_event "INFO" "Restored commands from backup"
    echo -e "${GREEN}Commands restored from backup.${NC}"
}

# Resolve a tag or alias to the actual tag name
resolve_tag_or_alias() {
    local input="$1"
    # Check direct tag match
    if jq -e --arg tag "$input" 'has($tag)' "$COMMANDS_FILE" >/dev/null 2>&1; then
        echo "$input"
        return 0
    fi
    # Scan aliases
    local resolved
    resolved=$(jq -r --arg a "$input" \
        'to_entries[] | select((.value.aliases // []) | index($a) != null) | .key' \
        "$COMMANDS_FILE" | head -1)
    if [ -n "$resolved" ]; then
        log_event "DEBUG" "Resolved alias '$input' to tag '$resolved'"
        echo "$resolved"
        return 0
    fi
    return 1
}

# Sanitize tag: alphanumeric, underscores, hyphens only
sanitize_tag() {
    local input="$1"
    # Trim leading/trailing whitespace
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

# Sanitize command: trim whitespace, basic validation
sanitize_command() {
    local input="$1"
    # Trim leading/trailing whitespace
    input="$(echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [ -z "$input" ]; then
        echo -e "${RED}Error:${NC} Command cannot be empty." >&2
        return 1
    fi

    log_event "DEBUG" "Command validated: '$input'"
    echo "$input"
    return 0
}

# Validate that the command's executable exists
validate_command() {
    local cmd="$1"
    if [ -z "$cmd" ]; then
        echo -e "${RED}Error:${NC} Command cannot be empty."
        return 1
    fi
    local executable
    executable=$(echo "$cmd" | awk '{print $1}')

    # Skip validation for parameterized executables
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

# Validate alias uniqueness (no conflict with existing tags or aliases)
validate_aliases() {
    local current_tag="$1"
    shift
    local new_aliases=("$@")

    for a in "${new_aliases[@]}"; do
        # Check if alias matches an existing tag (other than current)
        if [ "$a" != "$current_tag" ] && jq -e --arg tag "$a" 'has($tag)' "$COMMANDS_FILE" >/dev/null 2>&1; then
            echo -e "${RED}Error:${NC} Alias '$a' conflicts with existing tag '$a'."
            return 1
        fi
        # Check if alias is used by another entry
        local owner
        owner=$(jq -r --arg a "$a" --arg self "$current_tag" \
            'to_entries[] | select(.key != $self) | select((.value.aliases // []) | index($a) != null) | .key' \
            "$COMMANDS_FILE" | head -1)
        if [ -n "$owner" ]; then
            echo -e "${RED}Error:${NC} Alias '$a' already in use by '$owner'."
            return 1
        fi
    done
    return 0
}

# Add a new command
add_command() {
    local tag="$1"
    local cmd="$2"
    local category="${3:-default}"

    log_event "DEBUG" "add_command: tag='$tag', command='$cmd', category='$category'"

    # Sanitize inputs
    tag=$(sanitize_tag "$tag") || exit 1
    cmd=$(sanitize_command "$cmd") || exit 1
    category="$(echo "$category" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$category" ] && category="default"

    # Validate command executable
    if ! validate_command "$cmd"; then
        echo -e "${RED}Error:${NC} Command validation failed."
        exit 1
    fi

    # Check if tag already exists
    if jq -e --arg tag "$tag" 'has($tag)' "$COMMANDS_FILE" >/dev/null 2>&1; then
        log_event "ERROR" "Tag '$tag' already exists"
        echo -e "${RED}Error:${NC} Tag '$tag' already exists. Use -e to edit it."
        exit 1
    fi

    # Validate aliases if provided
    if [ "${#CMDR_ALIASES[@]}" -gt 0 ]; then
        if ! validate_aliases "$tag" "${CMDR_ALIASES[@]}"; then
            exit 1
        fi
    fi

    # Build entry JSON
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

    backup_commands

    # Merge entry into commands file
    local tmp_file
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
    if ! jq --arg tag "$tag" --argjson entry "$entry" \
        '. + {($tag): $entry}' "$COMMANDS_FILE" > "$tmp_file" 2>/dev/null; then
        log_event "ERROR" "jq failed while adding command"
        echo -e "${RED}Error:${NC} Failed to update commands file."
        rm -f "$tmp_file"
        exit 1
    fi
    mv "$tmp_file" "$COMMANDS_FILE"

    log_event "INFO" "Added command: tag='$tag', category='$category', command='$cmd'"
    echo -e "${GREEN}Command added successfully:${NC} '$tag' in category '$category'."
}

# Edit an existing command
edit_command() {
    local tag="$1"
    local new_cmd="$2"
    local new_category="$3"

    tag=$(sanitize_tag "$tag") || exit 1

    # Resolve alias to tag
    local resolved
    resolved=$(resolve_tag_or_alias "$tag")
    if [ -z "$resolved" ]; then
        log_event "ERROR" "Tag '$tag' not found for editing"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi
    tag="$resolved"

    # If no new command provided, show current and prompt
    if [ -z "$new_cmd" ]; then
        local current
        current=$(jq -r --arg tag "$tag" '.[$tag].command' "$COMMANDS_FILE")
        echo -e "${YELLOW}Current command:${NC} $current"
        read -p "New command (leave empty to keep): " new_cmd
        [ -z "$new_cmd" ] && new_cmd="$current"
    fi

    new_cmd=$(sanitize_command "$new_cmd") || exit 1

    if ! validate_command "$new_cmd"; then
        echo -e "${RED}Error:${NC} Command validation failed."
        exit 1
    fi

    # Validate aliases if provided
    if [ "${#CMDR_ALIASES[@]}" -gt 0 ]; then
        if ! validate_aliases "$tag" "${CMDR_ALIASES[@]}"; then
            exit 1
        fi
    fi

    # Build update object
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

    backup_commands

    local tmp_file
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
    if ! jq --arg tag "$tag" --argjson update "$update" \
        '.[$tag] = (.[$tag] * $update)' "$COMMANDS_FILE" > "$tmp_file" 2>/dev/null; then
        log_event "ERROR" "jq failed while editing command"
        echo -e "${RED}Error:${NC} Failed to update commands file."
        rm -f "$tmp_file"
        exit 1
    fi
    mv "$tmp_file" "$COMMANDS_FILE"

    log_event "INFO" "Edited command: tag='$tag', command='$new_cmd'"
    echo -e "${GREEN}Command '$tag' updated successfully.${NC}"
}

# Delete a command
delete_command() {
    local tag="$1"
    local force="${2:-false}"

    tag=$(sanitize_tag "$tag") || exit 1

    # Resolve alias to tag
    local resolved
    resolved=$(resolve_tag_or_alias "$tag")
    if [ -z "$resolved" ]; then
        log_event "ERROR" "Command '$tag' not found"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi
    tag="$resolved"

    # Confirmation prompt unless -y
    if [ "$force" != "true" ]; then
        local cmd
        cmd=$(jq -r --arg tag "$tag" '.[$tag].command // empty' "$COMMANDS_FILE")
        echo -e "${YELLOW}Command:${NC} $cmd"
        read -p "Delete '$tag'? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo -e "${YELLOW}Cancelled.${NC}"
            return 0
        fi
    fi

    backup_commands

    local tmp_file
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
    if ! jq --arg tag "$tag" 'del(.[$tag])' "$COMMANDS_FILE" > "$tmp_file" 2>/dev/null; then
        log_event "ERROR" "jq failed while deleting command"
        echo -e "${RED}Error:${NC} Failed to delete command."
        rm -f "$tmp_file"
        exit 1
    fi
    mv "$tmp_file" "$COMMANDS_FILE"

    log_event "INFO" "Deleted command with tag '$tag'"
    echo -e "${GREEN}Command '$tag' deleted successfully.${NC}"
}

# Show available commands
show_commands() {
    log_event "DEBUG" "Showing commands from $COMMANDS_FILE"
    if [ ! -s "$COMMANDS_FILE" ] || [ "$(jq 'length' "$COMMANDS_FILE")" -eq 0 ]; then
        echo -e "${YELLOW}No commands available.${NC}"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Available commands by category:${NC}"
    echo ""

    while IFS= read -r category; do
        echo -e "  ${BOLD}${GREEN}[$category]${NC}"
        while IFS=$'\t' read -r tag cmd desc alias_str; do
            # Highlight placeholders in command
            local cmd_display
            cmd_display=$(echo "$cmd" | sed $'s/{[a-zA-Z_][a-zA-Z0-9_]*}/\033[0;33m&\033[0m/g')

            # Build tag line with aliases
            local tag_line
            if [ -n "$alias_str" ]; then
                tag_line=$(printf "    ${CYAN}%-20s${NC}  %b  ${CYAN}(aka: %s)${NC}" "$tag" "$cmd_display" "$alias_str")
            else
                tag_line=$(printf "    ${CYAN}%-20s${NC}  %b" "$tag" "$cmd_display")
            fi
            echo -e "$tag_line"

            # Show description on next line if present
            if [ -n "$desc" ]; then
                printf "    %-20s  ${YELLOW}# %s${NC}\n" "" "$desc"
            fi
        done < <(jq -r --arg cat "$category" \
            'to_entries[] | select(.value.category == $cat) |
            "\(.key)\t\(.value.command)\t\(.value.description // "")\t\(.value.aliases // [] | join(", "))"' \
            "$COMMANDS_FILE")
        echo ""
    done < <(jq -r '[to_entries[] | .value.category] | unique[]' "$COMMANDS_FILE")

    log_event "INFO" "Displayed commands"
}

# Search commands by keyword
search_commands() {
    local keyword="$1"
    if [ -z "$keyword" ]; then
        echo -e "${RED}Error:${NC} Search keyword required."
        exit 1
    fi

    log_event "DEBUG" "Searching for: '$keyword'"

    local results
    results=$(jq -r --arg kw "$keyword" \
        'to_entries[] | select(
            (.key | ascii_downcase | contains($kw | ascii_downcase)) or
            (.value.command | ascii_downcase | contains($kw | ascii_downcase)) or
            (.value.category | ascii_downcase | contains($kw | ascii_downcase)) or
            ((.value.description // "") | ascii_downcase | contains($kw | ascii_downcase)) or
            ((.value.aliases // []) | any(ascii_downcase | contains($kw | ascii_downcase)))
        ) | "\(.value.category)\t\(.key)\t\(.value.command)\t\(.value.description // "")\t\(.value.aliases // [] | join(", "))"' \
        "$COMMANDS_FILE")

    if [ -z "$results" ]; then
        echo -e "${YELLOW}No commands matching '$keyword'.${NC}"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Search results for '${keyword}':${NC}"
    echo ""
    printf "  ${CYAN}%-12s  %-16s  %-30s  %s${NC}\n" "CATEGORY" "TAG" "COMMAND" "DESCRIPTION"

    while IFS=$'\t' read -r cat tag cmd desc alias_str; do
        # Highlight placeholders
        local cmd_display
        cmd_display=$(echo "$cmd" | sed $'s/{[a-zA-Z_][a-zA-Z0-9_]*}/\033[0;33m&\033[0m/g')

        local tag_display="$tag"
        if [ -n "$alias_str" ]; then
            tag_display="$tag (aka: $alias_str)"
        fi

        printf "  %-12s  %-16s  %b" "$cat" "$tag_display" "$cmd_display"
        if [ -n "$desc" ]; then
            printf "  ${YELLOW}# %s${NC}" "$desc"
        fi
        printf "\n"
    done <<< "$results"

    log_event "INFO" "Search completed for '$keyword'"
}

# Run a command
run_command() {
    local tag="$1"
    shift
    local run_args=("$@")

    tag=$(sanitize_tag "$tag") || exit 1

    # Resolve alias to tag
    local resolved
    resolved=$(resolve_tag_or_alias "$tag")
    if [ -z "$resolved" ]; then
        log_event "ERROR" "Command '$tag' not found"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi
    tag="$resolved"

    local cmd
    cmd=$(jq -r --arg tag "$tag" '.[$tag].command // empty' "$COMMANDS_FILE")

    if [ -z "$cmd" ]; then
        log_event "ERROR" "Command '$tag' not found"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi

    # Handle parameterized commands
    local placeholders
    mapfile -t placeholders < <(grep -oE '\{[a-zA-Z_][a-zA-Z0-9_]*\}' <<< "$cmd" | awk '!seen[$0]++')

    if [ "${#placeholders[@]}" -gt 0 ] && [ -n "${placeholders[0]}" ]; then
        local i=0
        for placeholder in "${placeholders[@]}"; do
            local name="${placeholder:1:${#placeholder}-2}"  # strip { }
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

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN]${NC} Would execute: $cmd"
        log_event "INFO" "Dry run for '$tag': $cmd"
        return 0
    fi

    echo -e "${GREEN}Running command:${NC} $cmd"
    bash -c "$cmd"
    local status=$?
    log_event "INFO" "Ran command '$tag': $cmd (exit: $status)"
    return $status
}

# Extract commands to a file
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

# Extract log file
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

# Install commands from a file (merge, not overwrite) - single-pass jq
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

    # Single-pass: validate tags, filter empty commands, default categories
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

    backup_commands

    # Merge validated commands into existing store
    local tmp_file
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
    if ! echo "$validated_json" | jq -s '.[0] * .[1]' "$COMMANDS_FILE" - > "$tmp_file" 2>/dev/null; then
        log_event "ERROR" "Failed to merge commands"
        echo -e "${RED}Error:${NC} Failed to merge commands."
        rm -f "$tmp_file"
        exit 1
    fi
    mv "$tmp_file" "$COMMANDS_FILE"

    log_event "INFO" "Installed $imported commands from: $input_file ($skipped skipped)"
    echo -e "${GREEN}Imported $imported commands${NC} ($skipped skipped)."
}

# Interactive mode
interactive_mode() {
    log_event "INFO" "Entered interactive mode"
    echo -e "${BOLD}${YELLOW}CMDR Interactive Mode${NC} (select 'exit' to quit)"

    while true; do
        local cat_array
        mapfile -t cat_array < <(jq -r '[to_entries[] | .value.category] | unique[]' "$COMMANDS_FILE" 2>/dev/null)
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
                mapfile -t cmd_array < <(jq -r --arg cat "$category" \
                    'to_entries[] | select(.value.category == $cat) | .key' "$COMMANDS_FILE")
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
                        cmd=$(jq -r --arg tag "$tag" '.[$tag].command' "$COMMANDS_FILE")
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

# Display subcommand-specific help
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
            echo ""
            echo "Examples:"
            echo "  cmdr -a serve 'python3 -m http.server 8080' dev"
            echo "  cmdr -a scan 'nmap {target} -sV' security --desc 'Service scan' --alias s"
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
            ;;
        run)
            echo "Usage: cmdr -r <tag> [arg1 arg2 ...]"
            echo ""
            echo "Run a stored command. Extra args fill {placeholder} parameters."
            echo ""
            echo "  -n, --dry-run    Print command without executing"
            echo ""
            echo "Examples:"
            echo "  cmdr -r serve"
            echo "  cmdr -r scan 192.168.1.1"
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
    esac
}

# Display help message
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
    echo -e "${YELLOW}Options:${NC}"
    echo "  -a <tag> <cmd> [cat] [--desc ..] [--alias ..]  Add a command"
    echo "  -e <tag> [cmd] [cat] [--desc ..] [--alias ..]  Edit a command"
    echo "  -d <tag> [-y]                                  Delete a command"
    echo "  -s                                             Show all commands"
    echo "  -r <tag> [args...]                             Run a command"
    echo "  -f <keyword>                                   Search commands"
    echo "  -x <file>                                      Export commands to JSON"
    echo "  -l <file>                                      Export logs"
    echo "  -i <file>                                      Import commands (merge)"
    echo "  -m                                             Interactive mode"
    echo "  -u, --undo                                     Undo last change"
    echo "  -n, --dry-run                                  Show command without running"
    echo "  -v                                             Enable debug logging"
    echo "  -V, --version                                  Show version"
    echo "  -h, --help                                     Show this help"
    echo ""
    echo -e "${YELLOW}Modifiers:${NC}"
    echo "  --desc \"text\"   Add/update a description (with -a or -e)"
    echo "  --alias name     Add an alias (repeatable, with -a or -e)"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  cmdr -a myserver 'python3 -m http.server 8080' dev"
    echo "  cmdr -a scan 'nmap {target} -sV' security --desc 'Service scan' --alias s"
    echo "  cmdr -e myserver 'python3 -m http.server 9090'"
    echo "  cmdr -r scan 192.168.1.1"
    echo "  cmdr -n -r scan 10.0.0.1"
    echo "  cmdr -d myserver -y"
    echo "  cmdr -f python"
    echo "  cmdr -s"
    echo "  cmdr -u"
    echo "  cmdr -m"
    echo ""
}
