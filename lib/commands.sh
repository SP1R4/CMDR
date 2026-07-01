#!/bin/bash
# ============================================================================
# CMDR :: lib/commands.sh
# Command CRUD, display and search
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

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

    # Single jq pass: emit rows sorted by category (stable sort keeps tag order
    # within a category) and print a header when the category changes. This used
    # to run one jq per category (N+1 processes); it is now a single invocation.
    local _dc_last="" _dc_seen=false
    while IFS=$'\037' read -r category tag cmd desc alias_str danger; do
            if [ "$category" != "$_dc_last" ]; then
                [ "$_dc_seen" = true ] && echo ""
                echo -e "  ${BOLD}${GREEN}[$category]${NC}"
                _dc_last="$category"; _dc_seen=true
            fi
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
    done < <(jq -r \
        'to_entries | sort_by(.value.category)[] |
        [.value.category, .key, .value.command, (.value.description // ""), (.value.aliases // [] | join(", ")), (.value.danger // false | tostring)] | join("\u001f")' \
        "$file")
    [ "$_dc_seen" = true ] && echo ""

    return 0
}

# Show all commands grouped by category, including workspace and local.
show_commands() {
    [ "${CMDR_JSON:-false}" = true ] && { json_commands; return 0; }
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

    [ "${CMDR_JSON:-false}" = true ] && { json_search "$keyword"; return 0; }

    log_event "DEBUG" "Searching for: '$keyword'"

    notify_untrusted_local
    local effective
    effective=$(get_effective_commands)

    # Fast path: answer from the SQLite mirror when it is enabled for this store
    # (large store, or CMDR_INDEX=1). _index_search returns non-zero to signal
    # "not used" -- then fall back to the jq scan, the default for typical
    # stores, which produces identical output.
    local results
    if ! results=$(_index_search "$effective" "$keyword"); then
        results=$(echo "$effective" | jq -r --arg kw "$keyword" \
            'to_entries[] | select(
                (.key | ascii_downcase | contains($kw | ascii_downcase)) or
                (.value.command | ascii_downcase | contains($kw | ascii_downcase)) or
                (.value.category | ascii_downcase | contains($kw | ascii_downcase)) or
                ((.value.description // "") | ascii_downcase | contains($kw | ascii_downcase)) or
                ((.value.aliases // []) | any(ascii_downcase | contains($kw | ascii_downcase)))
            ) | [.value.category, .key, .value.command, (.value.description // ""), (.value.aliases // [] | join(", "))] | join("\u001f")')
    fi

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

