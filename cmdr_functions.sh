#!/bin/bash

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Initialize files
initialize_files() {
    log_event "DEBUG" "Initializing files: COMMANDS_FILE=$COMMANDS_FILE, LOG_FILE=$LOG_FILE"
    if [ ! -f "$COMMANDS_FILE" ]; then
        touch "$COMMANDS_FILE" || { log_event "ERROR" "Failed to create $COMMANDS_FILE"; echo -e "${RED}Error:${NC} Failed to create commands file."; exit 1; }
        echo "{}" > "$COMMANDS_FILE" || { log_event "ERROR" "Failed to write to $COMMANDS_FILE"; echo -e "${RED}Error:${NC} Failed to write to commands file."; exit 1; }
        log_event "INFO" "Created commands file: $COMMANDS_FILE"
    fi
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE" || { log_event "ERROR" "Failed to create $LOG_FILE"; echo -e "${RED}Error:${NC} Failed to create log file."; exit 1; }
        log_event "INFO" "Created log file: $LOG_FILE"
    fi
    # Verify COMMANDS_FILE is valid JSON
    if ! jq -e . "$COMMANDS_FILE" >/dev/null 2>&1; then
        log_event "ERROR" "Invalid JSON in $COMMANDS_FILE, resetting to empty object"
        echo "{}" > "$COMMANDS_FILE" || { log_event "ERROR" "Failed to reset $COMMANDS_FILE"; echo -e "${RED}Error:${NC} Failed to reset commands file."; exit 1; }
    fi
}

# Log function with levels
log_event() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %T")

    # Log based on verbosity
    case "$VERBOSITY" in
        "DEBUG")
            if [ "$level" = "DEBUG" ] || [ "$level" = "INFO" ] || [ "$level" = "ERROR" ]; then
                echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || echo "[$timestamp] [$level] Failed to write to log: $message" >&2
            fi
            ;;
        "INFO")
            if [ "$level" = "INFO" ] || [ "$level" = "ERROR" ]; then
                echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || echo "[$timestamp] [$level] Failed to write to log: $message" >&2
            fi
            ;;
        "ERROR")
            if [ "$level" = "ERROR" ]; then
                echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || echo "[$timestamp] [$level] Failed to write to log: $message" >&2
            fi
            ;;
    esac
}

# Sanitize input
sanitize_input() {
    local input="$1"
    local type="$2" # "tag" or "command"
    # Clean input: remove leading/trailing whitespace
    input=$(echo "$input" | tr -d '[:space:]')
    log_event "DEBUG" "Sanitizing input: '$input' (type: $type, raw bytes: $(echo -n "$input" | od -An -tx1))"
    if [ "$type" = "tag" ]; then
        # Tags: alphanumeric, underscores, hyphens only
        if [[ "$input" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_event "DEBUG" "Tag '$input' is valid"
            echo "$input"
            return 0
        else
            log_event "ERROR" "Invalid tag '$input': only alphanumeric, underscores, hyphens allowed"
            echo -e "${RED}Error:${NC} Invalid tag '$input'. Use alphanumeric, underscores, or hyphens."
            return 1
        fi
    elif [ "$type" = "command" ]; then
        # Commands: disallow dangerous characters like semicolons, pipes
        if echo "$input" | grep -q '[|;]'; then
            log_event "ERROR" "Invalid command '$input': contains dangerous characters (;, |)"
            echo -e "${RED}Error:${NC} Command contains unsafe characters (;, |)."
            return 1
        fi
        log_event "DEBUG" "Command '$input' is valid"
        echo "$input"
        return 0
    fi
}

# Validate command
validate_command() {
    local cmd="$1"
    log_event "DEBUG" "Validating command: '$cmd'"
    cmd=$(sanitize_input "$cmd" "command") || return 1
    if [ -z "$cmd" ]; then
        log_event "ERROR" "Command cannot be empty"
        echo -e "${RED}Error:${NC} Command cannot be empty."
        return 1
    fi
    local executable=$(echo "$cmd" | awk '{print $1}')
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
    local command="$2"
    local category="${3:-default}"
    log_event "DEBUG" "Entering add_command: tag='$tag', command='$command', category='$category'"

    # Sanitize inputs
    log_event "DEBUG" "Sanitizing tag: '$tag'"
    tag=$(sanitize_input "$tag" "tag") || { log_event "ERROR" "Tag sanitization failed for '$tag'"; echo -e "${RED}Error:${NC} Tag sanitization failed."; exit 1; }
    log_event "DEBUG" "Sanitizing command: '$command'"
    command=$(sanitize_input "$command" "command") || { log_event "ERROR" "Command sanitization failed for '$command'"; echo -e "${RED}Error:${NC} Command sanitization failed."; exit 1; }
    log_event "DEBUG" "After sanitization: tag='$tag', command='$command'"

    # Check for empty inputs
    if [ -z "$tag" ] || [ -z "$command" ]; then
        log_event "ERROR" "Tag or command is empty after sanitization"
        echo -e "${RED}Error:${NC} Tag and command must not be empty."
        exit 1
    fi

    # Validate command
    log_event "DEBUG" "Validating command: '$command'"
    if ! validate_command "$command"; then
        log_event "ERROR" "Command validation failed for: '$command'"
        echo -e "${RED}Error:${NC} Command validation failed."
        exit 1
    fi

    # Check if tag exists
    log_event "DEBUG" "Checking if tag '$tag' exists in $COMMANDS_FILE"
    if jq -e "has(\"$tag\")" "$COMMANDS_FILE" >/dev/null 2>&1; then
        log_event "ERROR" "Tag '$tag' already exists"
        echo -e "${RED}Error:${NC} Tag '$tag' already exists."
        exit 1
    fi

    # Construct JSON
    local json_command="{\"$tag\": {\"command\": \"$command\", \"category\": \"$category\"}}"
    log_event "DEBUG" "Constructed JSON: $json_command"

    # Update commands file
    log_event "DEBUG" "Attempting to update $COMMANDS_FILE"
    local tmp_file="/tmp/cmdr_tmp.$$.json"
    if ! jq --argjson new "$json_command" '. += $new' "$COMMANDS_FILE" > "$tmp_file" 2>/tmp.jq.err; then
        local jq_error=$(cat tmp.jq.err)
        log_event "ERROR" "jq failed: $jq_error"
        echo -e "${RED}Error:${NC} Failed to update commands file: $jq_error"
        rm -f "$tmp_file" tmp.jq.err
        exit 1
    fi
    if ! mv "$tmp_file" "$COMMANDS_FILE" 2>/tmp.mv.err; then
        local mv_error=$(cat tmp.mv.err)
        log_event "ERROR" "mv failed: $mv_error"
        echo -e "${RED}Error:${NC} Failed to move temporary file: $mv_error"
        rm -f "$tmp_file" tmp.mv.err
        exit 1
    fi
    rm -f tmp.jq.err tmp.mv.err
    log_event "INFO" "Successfully added command: tag='$tag', category='$category', command='$command'"
    echo -e "${GREEN}Command added successfully:${NC} '$tag' in category '$category'."
}

# Delete a command
delete_command() {
    local tag="$1"
    log_event "DEBUG" "Deleting command with tag: '$tag'"
    tag=$(sanitize_input "$tag" "tag") || exit 1

    if [ -z "$tag" ]; then
        log_event "ERROR" "Tag is required"
        echo -e "${RED}Error:${NC} Tag is required."
        exit 1
    fi

    if ! jq -e "has(\"$tag\")" < "$COMMANDS_FILE" &>/dev/null; then
        log_event "ERROR" "Command '$tag' not found"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi

    jq "del(.\"$tag\")" "$COMMANDS_FILE" > tmp.$$.json && mv tmp.$$.json "$COMMANDS_FILE"
    log_event "INFO" "Deleted command with tag '$tag'"
    echo -e "${GREEN}Command '$tag' deleted successfully.${NC}"
}

# Show available commands
show_commands() {
    log_event "DEBUG" "Showing commands from $COMMANDS_FILE"
    if [ ! -s "$COMMANDS_FILE" ] || [ "$(jq 'length' "$COMMANDS_FILE")" -eq 0 ]; then
        log_event "INFO" "No commands available"
        echo -e "${YELLOW}No commands available.${NC}"
        exit 0
    fi

    echo -e "${YELLOW}Available commands by category:${NC}"
    local categories=$(jq -r 'to_entries[] | .value.category' "$COMMANDS_FILE" | sort -u)
    if [ -z "$categories" ]; then
        log_event "INFO" "No categories defined"
        echo -e "${YELLOW}No categories defined.${NC}"
        exit 0
    fi
    for category in $categories; do
        echo -e "${GREEN}Category: $category${NC}"
        jq -r --arg cat "$category" \
            'to_entries[] | select(.value.category == $cat) | "  \(.key): \(.value.command)"' \
            "$COMMANDS_FILE"
    done
    log_event "INFO" "Displayed commands"
}

# Run a command
run_command() {
    local tag="$1"
    log_event "DEBUG" "Running command with tag: '$tag'"
    tag=$(sanitize_input "$tag" "tag") || exit 1

    if [ -z "$tag" ]; then
        log_event "ERROR" "Tag is required"
        echo -e "${RED}Error:${NC} Tag is required."
        exit 1
    fi
    local command=$(jq -r ".$tag.command" "$COMMANDS_FILE")

    if [ "$command" = "null" ]; then
        log_event "ERROR" "Command '$tag' not found"
        echo -e "${RED}Error:${NC} Command '$tag' not found."
        exit 1
    fi

    echo -e "${GREEN}Running command:${NC} $command"
    "$SHELL" -c "$command"
    local status=$?
    log_event "INFO" "Ran command with tag '$tag': $command (status: $status)"
    exit $status
}

# Extract commands to a file
extract_commands() {
    local output_file="$1"
    log_event "DEBUG" "Extracting commands to: '$output_file'"
    if [ -z "$output_file" ]; then
        log_event "ERROR" "Output file path not provided"
        echo -e "${RED}Error:${NC} Output file path not provided."
        exit 1
    fi

    if [ ! -s "$COMMANDS_FILE" ] || [ "$(jq 'length' "$COMMANDS_FILE")" -eq 0 ]; then
        log_event "INFO" "No commands available"
        echo -e "${YELLOW}No commands available.${NC}"
        exit 0
    fi

    jq '.' "$COMMANDS_FILE" > "$output_file"
    log_event "INFO" "Extracted commands to file: $output_file"
    echo -e "${GREEN}Commands extracted successfully:${NC} $output_file"
}

# Extract log file
extract_logs() {
    local output_file="$1"
    log_event "DEBUG" "Extracting logs to: '$output_file'"
    if [ -z "$output_file" ]; then
        log_event "ERROR" "Output file path not provided"
        echo -e "${RED}Error:${NC} Output file path not provided."
        exit 1
    fi

    if [ ! -s "$LOG_FILE" ]; then
        log_event "INFO" "Log file is empty or does not exist"
        echo -e "${YELLOW}Log file is empty or does not exist.${NC}"
        exit 0
    fi

    cp "$LOG_FILE" "$output_file"
    log_event "INFO" "Extracted logs to file: $output_file"
    echo -e "${GREEN}Log file extracted successfully:${NC} $output_file"
}

# Install commands from a file
install_commands() {
    local input_file="$1"
    log_event "DEBUG" "Installing commands from: '$input_file'"
    if [ -z "$input_file" ] || [ ! -f "$input_file" ]; then
        log_event "ERROR" "Input file path not provided or does not exist"
        echo -e "${RED}Error:${NC} Input file path not provided or does not exist."
        exit 1
    fi

    if [ ! -s "$input_file" ]; then
        log_event "ERROR" "Input file is empty"
        echo -e "${RED}Error:${NC} Input file is empty."
        exit 1
    fi

    if ! jq . "$input_file" >/dev/null 2>&1; then
        log_event "ERROR" "Input file is not valid JSON"
        echo -e "${RED}Error:${NC} Input file is not valid JSON."
        exit 1
    fi

    # Validate each command
    while IFS= read -r tag; do
        local cmd=$(jq -r ".\"$tag\".command" "$input_file")
        if [ "$cmd" = "null" ]; then
            log_event "WARNING" "Skipping invalid command for tag '$tag'"
            echo -e "${YELLOW}Skipping invalid command for tag '$tag'.${NC}"
            continue
        fi
        tag=$(sanitize_input "$tag" "tag") || continue
        cmd=$(sanitize_input "$cmd" "command") || continue
        if ! validate_command "$cmd"; then
            log_event "WARNING" "Skipping '$tag' due to validation failure"
            echo -e "${YELLOW}Skipping '$tag' due to validation failure.${NC}"
            continue
        fi
    done < <(jq -r 'keys[]' "$input_file")

    cp "$input_file" "$COMMANDS_FILE"
    log_event "INFO" "Installed commands from file: $input_file"
    echo -e "${GREEN}Commands installed successfully:${NC} $input_file"
}

# Interactive mode
interactive_mode() {
    log_event "INFO" "Entered interactive mode"
    echo -e "${YELLOW}Interactive Mode (select 'exit' to quit):${NC}"
    while true; do
        local categories=$(jq -r 'to_entries[] | .value.category' "$COMMANDS_FILE" | sort -u)
        if [ -z "$categories" ]; then
            log_event "INFO" "No commands available in interactive mode"
            echo -e "${YELLOW}No commands available.${NC}"
            categories="default"
        fi
        echo -e "${GREEN}\nCategories:${NC}"
        select category in $categories "exit"; do
            if [ "$category" = "exit" ]; then
                log_event "INFO" "Exited interactive mode"
                echo -e "${GREEN}Exiting interactive mode.${NC}"
                exit 0
            fi
            if [ -n "$category" ]; then
                echo -e "${GREEN}\nCommands in '$category':${NC}"
                local commands=$(jq -r --arg cat "$category" \
                    'to_entries[] | select(.value.category == $cat) | .key' "$COMMANDS_FILE")
                if [ -z "$commands" ]; then
                    log_event "INFO" "No commands in category '$category'"
                    echo -e "${YELLOW}No commands in '$category'.${NC}"
                    break
                fi
                select tag in $commands "back"; do
                    if [ "$tag" = "back" ]; then
                        break
                    fi
                    if [ -n "$tag" ]; then
                        local cmd=$(jq -r ".\"$tag\".command" "$COMMANDS_FILE")
                        log_event "DEBUG" "Selected command '$tag' in interactive mode"
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
    clear
    echo ""
    echo -e "${GREEN}        ███████╗██████╗  ██╗██████╗ ██╗  ██╗        ${NC}"
    echo -e "${GREEN}        ██╔════╝██╔══██╗███║██╔══██╗██║  ██║        ${NC}"
    echo -e "${GREEN}        ███████╗██████╔╝╚██║██████╔╝███████║        ${NC}"
    echo -e "${GREEN}        ╚════██║██╔═══╝  ██║██╔══██╗╚════██║        ${NC}"
    echo -e "${GREEN}        ███████║██║      ██║██║  ██║     ██║        ${NC}"
    echo -e "${GREEN}        ╚══════╝╚═╝      ╚═╝╚═╝  ╚═╝     ╚═╝        ${NC}"
    echo ""
    echo -e "${YELLOW}Usage:${NC} $0 [-a <tag> <command> [category]] [-d <tag>] [-s] [-r <tag>] [-x <output_file>] [-l <output_file>] [-i <input_file>] [-m] [-v] [-h]"
    echo -e "${YELLOW}Options:${NC}"
    echo "  -a <tag> <command> [category]  Add a command with tag and optional category (default: 'default')."
    echo "  -d <tag>                       Delete the command with the specified tag."
    echo "  -s                             Show commands grouped by category."
    echo "  -r <tag>                       Run the command with the specified tag."
    echo "  -x <output_file>               Extract commands to the specified output file."
    echo "  -l <output_file>               Extract logs to the specified output file."
    echo "  -i <input_file>                Install commands from the specified input file."
    echo "  -m                             Enter interactive mode to browse and run commands."
    echo "  -v                             Enable debug logging (default: info)."
    echo "  -h                             Display this help message."
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  $0 -a mycmd 'echo Hello' dev      # Add command with tag 'mycmd' in category 'dev'"
    echo "  $0 -d mycmd                        # Delete command with tag 'mycmd'"
    echo "  $0 -s                               # Show commands by category"
    echo "  $0 -r mycmd                         # Run command with tag 'mycmd'"
    echo "  $0 -x commands.json                 # Extract commands to 'commands.json'"
    echo "  $0 -l logs.log                      # Extract logs to 'logs.log'"
    echo "  $0 -i new_commands.json             # Install commands from 'new_commands.json'"
    echo "  $0 -m                               # Enter interactive mode"
    echo "  $0 -v -s                            # Show commands with debug logging"
    echo ""
}