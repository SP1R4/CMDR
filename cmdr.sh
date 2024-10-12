#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Define commands file and log file in the script directory
COMMANDS_FILE="$SCRIPT_DIR/my_commands.json"
LOG_FILE="$SCRIPT_DIR/commands_log.log"
LOCK_FILE="$HOME/command_manager.lock"  # Updated lock file location

# Check if commands file exists, if not create it
if [ ! -f "$COMMANDS_FILE" ]; then
    touch "$COMMANDS_FILE"
    # Initialize the file with an empty JSON object
    echo "{}" > "$COMMANDS_FILE"
fi

# Check if script is run with sudo
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Error:${NC} This script must be run with sudo."
    exit 1
fi

# Check if log file exists, if not create it
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
fi

# Function to log events
log_event() {
    local timestamp=$(date +"%Y-%m-%d %T")
    local event="$1"
    echo "[$timestamp] $event" >> "$LOG_FILE"
}

# Acquire the lock
(
    flock -n 200 || { echo -e "${RED}Another instance is running.${NC}"; exit 1; }

    # Add a new command
    add_command() {
        local tag="$1"
        local command="$2"

        if [ -z "$tag" ] || [ -z "$command" ]; then
            echo -e "${RED}Error:${NC} Tag and command must not be empty."
            exit 1
        fi

        local json_command="{\"$tag\": \"$command\"}"

        if jq -e . >/dev/null 2>&1 <<<"$json_command"; then
            jq ". += $json_command" "$COMMANDS_FILE" > tmp.$$.json && mv tmp.$$.json "$COMMANDS_FILE"
            echo -e "${GREEN}Command added successfully.${NC}"
            log_event "Added command with tag '$tag': $command"
        else
            echo -e "${RED}Error:${NC} Invalid JSON command."
            exit 1
        fi
    }

    # Delete a command
    delete_command() {
        local tag="$1"

        if ! jq -e "has(\"$tag\")" < "$COMMANDS_FILE" &>/dev/null; then
            echo -e "${RED}Error:${NC} Command '$tag' not found."
            exit 1
        fi

        jq "del(.\"$tag\")" "$COMMANDS_FILE" > tmp.$$.json && mv tmp.$$.json "$COMMANDS_FILE"
        echo -e "${GREEN}Command '$tag' deleted successfully.${NC}"
        log_event "Deleted command with tag '$tag'"
    }

    # Show available commands
    show_commands() {
        if [ ! -s "$COMMANDS_FILE" ]; then
            echo -e "${YELLOW}No commands available.${NC}"
            exit 0
        fi

        echo -e "${YELLOW}Available commands:${NC}"
        jq '. | to_entries[] | "\(.key): \(.value)"' "$COMMANDS_FILE"
    }

    # Run a command
    run_command() {
        local tag="$1"
        local command=$(jq -r ".$tag" "$COMMANDS_FILE")

        if [ "$command" = "null" ]; then
            echo -e "${RED}Error:${NC} Command '$tag' not found."
            exit 1
        fi

        echo -e "${GREEN}Running command:${NC} $command"
        "$SHELL" -c "$command"  # Using shell execution instead of eval
        log_event "Ran command with tag '$tag': $command"
    }

    # Extract commands to a file
    extract_commands() {
        local output_file="$1"

        if [ -z "$output_file" ]; then
            echo -e "${RED}Error:${NC} Output file path not provided."
            exit 1
        fi

        if [ ! -s "$COMMANDS_FILE" ]; then
            echo -e "${YELLOW}No commands available.${NC}"
            exit 0
        fi

        jq '.' "$COMMANDS_FILE" > "$output_file"
        echo -e "${GREEN}Commands extracted successfully.${NC}"
        log_event "Extracted commands to file: $output_file"
    }

    # Extract log file
    extract_logs() {
        local output_file="$1"

        if [ -z "$output_file" ]; then
            echo -e "${RED}Error:${NC} Output file path not provided."
            exit 1
        fi

        if [ ! -s "$LOG_FILE" ]; then
            echo -e "${YELLOW}Log file is empty or does not exist.${NC}"
            exit 0
        fi

        cp "$LOG_FILE" "$output_file"
        echo -e "${GREEN}Log file extracted successfully.${NC}"
    }

    # Install commands from a file
    install_commands() {
        local input_file="$1"

        if [ -z "$input_file" ]; then
            echo -e "${RED}Error:${NC} Input file path not provided."
            exit 1
        fi

        if [ ! -s "$input_file" ]; then
            echo -e "${RED}Error:${NC} Input file is empty or does not exist."
            exit 1
        fi

        cp "$input_file" "$COMMANDS_FILE"
        echo -e "${GREEN}Commands installed successfully.${NC}"
        log_event "Installed commands from file: $input_file"
    }

    # Display help message
    display_help() {
        clear;
        # Define colors
        GREEN='\033[0;32m'
        YELLOW='\033[0;33m'
        NC='\033[0m' # No Color

        # ASCII art with colors
        echo ""
        echo ""
        echo -e "${GREEN}        ███████╗██████╗  ██╗██████╗ ██╗  ██╗        ${NC}"
        echo -e "${GREEN}        ██╔════╝██╔══██╗███║██╔══██╗██║  ██║        ${NC}"
        echo -e "${GREEN}        ███████╗██████╔╝╚██║██████╔╝███████║        ${NC}"
        echo -e "${GREEN}        ╚════██║██╔═══╝  ██║██╔══██╗╚════██║        ${NC}"
        echo -e "${GREEN}        ███████║██║      ██║██║  ██║     ██║        ${NC}"
        echo -e "${GREEN}        ╚══════╝╚═╝      ╚═╝╚═╝  ╚═╝     ╚═╝        ${NC}"
        echo ""
        echo ""
        echo -e "${YELLOW}Usage:${NC} $0 [-a <tag> <command>] [-d <tag>] [-s] [-r <tag>] [-x <output_file>] [-l <output_file>] [-i <input_file>] [-h]"
        echo -e "${YELLOW}Options:${NC}"
        echo "  -a <tag> <command>   Add a new command with the specified tag."
        echo "                       The tag must be unique and not empty."
        echo "                       The command must be enclosed in single or double quotes."
        echo "  -d <tag>             Delete the command associated with the specified tag."
        echo "  -s                   Show available commands."
        echo "  -r <tag>             Run the command associated with the specified tag."
        echo "  -x <output_file>     Extract commands to the specified output file."
        echo "  -l <output_file>     Extract logs to the specified output file."
        echo "  -i <input_file>      Install commands from the specified input file."
        echo "  -h                    Display this help message."
        echo ""
        echo -e "${YELLOW}Examples:${NC}"
        echo "  $0 -a mycmd 'echo Hello'                 # Add a new command with tag 'mycmd'"
        echo "  $0 -d mycmd                               # Delete the command with tag 'mycmd'"
        echo "  $0 -s                                      # Show available commands"
        echo "  $0 -r mycmd                                # Run command with tag 'mycmd'"
        echo "  $0 -x extracted_commands.json             # Extract commands to 'extracted_commands.json'"
        echo "  $0 -l commands_log.log                    # Extract logs to 'commands_log.log'"
        echo "  $0 -i commands_to_install.json            # Install commands from 'commands_to_install.json'"
        echo ""
    }

    # Main function
    main() {
        if [ "$#" -eq 0 ]; then
            display_help
            exit 1
        fi

        while getopts ":a:d:sr:x:l:i:h" opt; do
            case ${opt} in
                a )
                    add_command "$OPTARG" "$3"
                    shift 2
                    ;;
                d )
                    delete_command "$OPTARG"
                    ;;
                s )
                    show_commands
                    ;;
                r )
                    run_command "$OPTARG"
                    ;;
                x )
                    extract_commands "$OPTARG"
                    ;;
                l )
                    extract_logs "$OPTARG"
                    ;;
                i )
                    install_commands "$OPTARG"
                    ;;
                h )
                    display_help
                    exit 0
                    ;;
                \? )
                    echo -e "${RED}Invalid option: -$OPTARG${NC}" 1>&2
                    exit 1
                    ;;
                : )
                    echo -e "${RED}Invalid option: -$OPTARG requires an argument${NC}" 1>&2
                    exit 1
                    ;;
            esac
        done
        shift $((OPTIND -1))
    }

    main "$@"
) 200>"$LOCK_FILE"
