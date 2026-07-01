#!/bin/bash
# ============================================================================
# CMDR :: lib/playbooks.sh
# Playbooks, notes and output capture
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

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

