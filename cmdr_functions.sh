#!/bin/bash
# CMDR v2.0 - Functions

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

# Sanitize tag: alphanumeric, underscores, hyphens only
sanitize_tag() {
    local input="$1"
    # Trim leading/trailing whitespace only (preserve internal spaces — though tags shouldn't have them)
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
    # Trim leading/trailing whitespace only — preserve the actual command
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

    # Update commands file using safe --arg (no injection)
    local tmp_file
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
    if ! jq --arg tag "$tag" --arg cmd "$cmd" --arg cat "$category" \
        '. + {($tag): {command: $cmd, category: $cat}}' "$COMMANDS_FILE" > "$tmp_file" 2>/dev/null; then
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

    if ! jq -e --arg tag "$tag" 'has($tag)' "$COMMANDS_FILE" >/dev/null 2>&1; then
        log_event "ERROR" "Tag '$tag' not found for editing"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi

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

    local tmp_file
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)

    if [ -n "$new_category" ]; then
        jq --arg tag "$tag" --arg cmd "$new_cmd" --arg cat "$new_category" \
            '.[$tag].command = $cmd | .[$tag].category = $cat' "$COMMANDS_FILE" > "$tmp_file"
    else
        jq --arg tag "$tag" --arg cmd "$new_cmd" \
            '.[$tag].command = $cmd' "$COMMANDS_FILE" > "$tmp_file"
    fi
    mv "$tmp_file" "$COMMANDS_FILE"

    log_event "INFO" "Edited command: tag='$tag', command='$new_cmd'"
    echo -e "${GREEN}Command '$tag' updated successfully.${NC}"
}

# Delete a command
delete_command() {
    local tag="$1"
    tag=$(sanitize_tag "$tag") || exit 1

    if ! jq -e --arg tag "$tag" 'has($tag)' "$COMMANDS_FILE" >/dev/null 2>&1; then
        log_event "ERROR" "Command '$tag' not found"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi

    local tmp_file
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
    jq --arg tag "$tag" 'del(.[$tag])' "$COMMANDS_FILE" > "$tmp_file" && mv "$tmp_file" "$COMMANDS_FILE"

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
    local categories
    categories=$(jq -r 'to_entries[] | .value.category' "$COMMANDS_FILE" | sort -u)
    for category in $categories; do
        echo -e "  ${GREEN}[$category]${NC}"
        jq -r --arg cat "$category" \
            'to_entries[] | select(.value.category == $cat) | "    \(.key)\t\(.value.command)"' \
            "$COMMANDS_FILE" | column -t -s $'\t'
        echo ""
    done
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
            (.value.category | ascii_downcase | contains($kw | ascii_downcase))
        ) | "  \(.value.category)\t\(.key)\t\(.value.command)"' "$COMMANDS_FILE")

    if [ -z "$results" ]; then
        echo -e "${YELLOW}No commands matching '$keyword'.${NC}"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Search results for '${keyword}':${NC}"
    echo ""
    echo -e "  ${CYAN}CATEGORY\tTAG\tCOMMAND${NC}"
    echo "$results" | column -t -s $'\t'
    log_event "INFO" "Search completed for '$keyword'"
}

# Run a command
run_command() {
    local tag="$1"
    tag=$(sanitize_tag "$tag") || exit 1

    local cmd
    cmd=$(jq -r --arg tag "$tag" '.[$tag].command // empty' "$COMMANDS_FILE")

    if [ -z "$cmd" ]; then
        log_event "ERROR" "Command '$tag' not found"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
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

# Install commands from a file (merge, not overwrite)
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

    # Build a validated subset and merge into existing commands
    local validated_json="{}"
    local skipped=0
    local imported=0

    while IFS= read -r tag; do
        local cmd
        cmd=$(jq -r --arg tag "$tag" '.[$tag].command // empty' "$input_file")
        local cat
        cat=$(jq -r --arg tag "$tag" '.[$tag].category // "default"' "$input_file")

        if [ -z "$cmd" ]; then
            echo -e "${YELLOW}Skipping '$tag': no command defined.${NC}"
            ((skipped++))
            continue
        fi

        # Validate tag format
        if ! sanitize_tag "$tag" >/dev/null 2>&1; then
            echo -e "${YELLOW}Skipping '$tag': invalid tag format.${NC}"
            ((skipped++))
            continue
        fi

        validated_json=$(echo "$validated_json" | jq --arg tag "$tag" --arg cmd "$cmd" --arg cat "$cat" \
            '. + {($tag): {command: $cmd, category: $cat}}')
        ((imported++))
    done < <(jq -r 'keys[]' "$input_file")

    # Merge validated commands into existing store
    local tmp_file
    tmp_file=$(mktemp /tmp/cmdr.XXXXXX.json)
    echo "$validated_json" | jq -s '.[0] * .[1]' "$COMMANDS_FILE" - > "$tmp_file"
    mv "$tmp_file" "$COMMANDS_FILE"

    log_event "INFO" "Installed $imported commands from: $input_file ($skipped skipped)"
    echo -e "${GREEN}Imported $imported commands${NC} ($skipped skipped)."
}

# Interactive mode
interactive_mode() {
    log_event "INFO" "Entered interactive mode"
    echo -e "${BOLD}${YELLOW}CMDR Interactive Mode${NC} (select 'exit' to quit)"

    while true; do
        local categories
        categories=$(jq -r 'to_entries[] | .value.category' "$COMMANDS_FILE" 2>/dev/null | sort -u)
        if [ -z "$categories" ]; then
            echo -e "${YELLOW}No commands available.${NC}"
            return 0
        fi

        echo -e "\n${GREEN}Categories:${NC}"
        select category in $categories "exit"; do
            if [ "$category" = "exit" ]; then
                log_event "INFO" "Exited interactive mode"
                echo -e "${GREEN}Bye.${NC}"
                return 0
            fi
            if [ -n "$category" ]; then
                echo -e "\n${GREEN}Commands in '$category':${NC}"
                local commands
                commands=$(jq -r --arg cat "$category" \
                    'to_entries[] | select(.value.category == $cat) | .key' "$COMMANDS_FILE")
                if [ -z "$commands" ]; then
                    echo -e "${YELLOW}No commands in '$category'.${NC}"
                    break
                fi
                select tag in $commands "back"; do
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

# Display help message
display_help() {
    echo ""
    echo -e "${GREEN}   ██████╗███╗   ███╗██████╗ ██████╗ ${NC}"
    echo -e "${GREEN}  ██╔════╝████╗ ████║██╔══██╗██╔══██╗${NC}"
    echo -e "${GREEN}  ██║     ██╔████╔██║██║  ██║██████╔╝${NC}"
    echo -e "${GREEN}  ██║     ██║╚██╔╝██║██║  ██║██╔══██╗${NC}"
    echo -e "${GREEN}  ╚██████╗██║ ╚═╝ ██║██████╔╝██║  ██║${NC}"
    echo -e "${GREEN}   ╚═════╝╚═╝     ╚═╝╚═════╝ ╚═╝  ╚═╝${NC}"
    echo -e "  ${CYAN}Command Manager v2.0${NC}"
    echo ""
    echo -e "${YELLOW}Usage:${NC} $0 [options]"
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo "  -a <tag> <command> [category]  Add a command (default category: 'default')"
    echo "  -e <tag> [command] [category]  Edit an existing command"
    echo "  -d <tag>                       Delete a command"
    echo "  -s                             Show all commands by category"
    echo "  -r <tag>                       Run a command by tag"
    echo "  -f <keyword>                   Search commands by keyword"
    echo "  -x <output_file>               Export commands to JSON file"
    echo "  -l <output_file>               Export logs to file"
    echo "  -i <input_file>                Import commands from JSON file (merge)"
    echo "  -m                             Interactive mode"
    echo "  -v                             Enable debug logging"
    echo "  -h                             Show this help"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  $0 -a myserver 'python3 -m http.server 8080' dev"
    echo "  $0 -e myserver 'python3 -m http.server 9090'"
    echo "  $0 -f python"
    echo "  $0 -r myserver"
    echo "  $0 -s"
    echo "  $0 -m"
    echo ""
}
