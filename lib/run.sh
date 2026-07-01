#!/bin/bash
# ============================================================================
# CMDR :: lib/run.sh
# Execution engine, hosts, run history
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

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

    # Fill secret-backed {NAME} tokens only now, at exec time. `$cmd` keeps the
    # tokens so secrets never reach the screen, history, or logs.
    local exec_cmd
    exec_cmd=$(resolve_secrets "$cmd")

    # Wrap for remote execution when --on targets a host.
    if [ -n "$CMDR_ON" ] && [ -n "$host" ]; then
        if ! exec_cmd=$(build_ssh_cmd "$host" "$exec_cmd"); then
            return 1
        fi
    fi

    if [ "$DRY_RUN" = true ]; then
        # Show the display command (tokens, not secret values).
        local show="$cmd"
        [ -n "$CMDR_ON" ] && [ -n "$host" ] && show=$(build_ssh_cmd "$host" "$cmd")
        echo -e "${YELLOW}[DRY RUN]${NC} (${label}) Would execute: $show"
        log_event "INFO" "Dry run for '$label': $show"
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

    # Serialize with any concurrent run/CRUD writing the same env store.
    with_store_lock _env_set_kv "$var" "$value"
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
    # Clipboard contents are meant to be pasted and run, so fill secrets here.
    cmd=$(resolve_secrets "$cmd")

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
    [ "${CMDR_JSON:-false}" = true ] && { json_hosts; return 0; }
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
_record_history_write() {
    local ts="$1" tag="$2" cmd="$3" host="$4" status="$5" duration="$6"
    [ ! -f "$HISTORY_FILE" ] && echo "[]" > "$HISTORY_FILE"
    local tmp_file
    tmp_file=$(_mktemp_beside "$HISTORY_FILE")
    jq --arg ts "$ts" --arg tag "$tag" --arg cmd "$cmd" --arg host "$host" \
       --arg st "$status" --arg dur "$duration" --argjson max "$HISTORY_MAX" \
       '. + [{timestamp:$ts, tag:$tag, command:$cmd, host:$host, exit:($st|tonumber), duration:$dur}] | .[-$max:]' \
       "$HISTORY_FILE" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$HISTORY_FILE"
}

record_history() {
    local tag="$1" cmd="$2" host="$3" status="$4" duration="$5"
    local ts
    ts=$(date +"%Y-%m-%d %T")
    # Serialize with any concurrent run so two histories don't clobber each other.
    with_store_lock _record_history_write "$ts" "$tag" "$cmd" "$host" "$status" "$duration"
}

# Show recent history (default 20 entries, newest first).
show_history() {
    [ "${CMDR_JSON:-false}" = true ] && { json_history; return 0; }
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

