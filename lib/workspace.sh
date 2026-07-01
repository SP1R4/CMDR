#!/bin/bash
# ============================================================================
# CMDR :: lib/workspace.sh
# Workspace management and environment variables
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

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
    [ "${CMDR_JSON:-false}" = true ] && { json_workspaces; return 0; }
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
# Atomic single key/value write into the workspace env store. Callers wrap this
# in with_store_lock so concurrent run captures and `--env` writes don't clobber.
_env_set_kv() {
    local key="$1" val="$2"
    [ ! -f "$ENV_FILE" ] && echo "{}" > "$ENV_FILE"
    local tmp_file
    tmp_file=$(_mktemp_beside "$ENV_FILE")
    jq --arg key "$key" --arg val "$val" '. + {($key): $val}' "$ENV_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$ENV_FILE"
}

set_env_var() {
    local pair="$1"
    local key="${pair%%=*}"
    local value="${pair#*=}"

    if [ -z "$key" ] || [ "$key" = "$pair" ]; then
        echo -e "${RED}Error:${NC} Invalid format. Use: --env KEY=VALUE"
        exit 1
    fi

    with_store_lock _env_set_kv "$key" "$value"

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

