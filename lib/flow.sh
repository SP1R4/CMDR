#!/bin/bash
# ============================================================================
# CMDR :: lib/flow.sh
# Workflow engine
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

# ----------------------------------------------------------------------------
# Section 12b: Workflow Engine
# JSON workflows of conditional, capturing, retrying, optionally-parallel steps.
# A workflow is { "name": "...", "steps": [ <step>, ... ] }. Each step:
#   { "run": "tag", "args": ["@host","x"], "when": "<cond>",
#     "capture": {"VAR":"regex"}, "register": "id", "retry": N,
#     "timeout": SECS, "remote": true, "continue_on_error": true }
# or a parallel block: { "parallel": [ <step>, <step> ] }.
# Conditions (safe DSL, no shell eval): lhs OP rhs / lhs exists, joined by
# && or ||, optional leading !. lhs ∈ env:NAME | step:ID.exit | step:ID.stdout
# | NAME(=env). OP ∈ == != contains matches.
# ----------------------------------------------------------------------------

# Resolve a workflow reference (file path or stored name) to its JSON.
_flow_load() {
    local ref="$1"
    if [ -f "$ref" ]; then cat "$ref"; return 0; fi
    if [ -f "$WORKFLOWS_FILE" ] && jq -e --arg n "$ref" 'has($n)' "$WORKFLOWS_FILE" >/dev/null 2>&1; then
        jq -c --arg n "$ref" '.[$n]' "$WORKFLOWS_FILE"; return 0
    fi
    echo -e "${RED}Error:${NC} Workflow '$ref' not found (no such file or stored name)." >&2
    return 1
}

# Record one step's result in the run-state file.
_flow_state_set() {
    local state="$1" id="$2" ex="$3" so="$4" tmp
    tmp=$(_mktemp_beside "$state")
    jq --arg id "$id" --arg ex "$ex" --arg so "$so" \
        '.steps[$id] = {exit:($ex|tonumber), stdout:$so}' "$state" > "$tmp" && mv "$tmp" "$state"
}

# Resolve a condition left-hand side to a value.
_flow_lhs() {
    local l="$1" state="$2"
    l="$(echo "$l" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$l" in
        env:*)         jq -r --arg k "${l#env:}" '.[$k] // empty' "$ENV_FILE" 2>/dev/null ;;
        step:*.exit)   local i="${l#step:}"; i="${i%.exit}";   jq -r --arg i "$i" '.steps[$i].exit   // empty' "$state" 2>/dev/null ;;
        step:*.stdout) local i="${l#step:}"; i="${i%.stdout}"; jq -r --arg i "$i" '.steps[$i].stdout // empty' "$state" 2>/dev/null ;;
        *)             jq -r --arg k "$l" '.[$k] // empty' "$ENV_FILE" 2>/dev/null ;;
    esac
}

# Evaluate a single clause; return 0 if true.
_flow_clause() {
    local c="$1" state="$2" neg=0 res=1
    c="$(echo "$c" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ "${c:0:1}" = "!" ]; then neg=1; c="$(echo "${c:1}" | sed 's/^[[:space:]]*//')"; fi
    local lhs op rhs lv
    if [[ "$c" =~ ^(.+)[[:space:]]+(==|!=|contains|matches)[[:space:]]+(.+)$ ]]; then
        lhs="${BASH_REMATCH[1]}"; op="${BASH_REMATCH[2]}"; rhs="${BASH_REMATCH[3]}"
        rhs="${rhs%\"}"; rhs="${rhs#\"}"; rhs="${rhs%\'}"; rhs="${rhs#\'}"
        lv=$(_flow_lhs "$lhs" "$state")
        case "$op" in
            ==)       [ "$lv" = "$rhs" ] && res=0 ;;
            !=)       [ "$lv" != "$rhs" ] && res=0 ;;
            contains) case "$lv" in *"$rhs"*) res=0 ;; esac ;;
            matches)  printf '%s' "$lv" | grep -qE -e "$rhs" && res=0 ;;
        esac
    elif [[ "$c" =~ ^(.+)[[:space:]]+exists$ ]]; then
        lv=$(_flow_lhs "${BASH_REMATCH[1]}" "$state"); [ -n "$lv" ] && res=0
    fi
    if [ "$neg" -eq 1 ]; then [ "$res" -eq 0 ] && res=1 || res=0; fi
    return $res
}

# Evaluate a when-expression (clauses joined by && or ||).
_flow_eval_when() {
    local expr="$1" state="$2" mode="and" sep=" && " rest clause
    if [[ "$expr" == *"||"* ]]; then mode="or"; sep=" || "; fi
    rest="$expr"
    while [ -n "$rest" ]; do
        if [[ "$rest" == *"$sep"* ]]; then clause="${rest%%"$sep"*}"; rest="${rest#*"$sep"}"; else clause="$rest"; rest=""; fi
        if _flow_clause "$clause" "$state"; then
            [ "$mode" = "or" ] && return 0
        else
            [ "$mode" = "and" ] && return 1
        fi
    done
    [ "$mode" = "and" ] && return 0 || return 1
}

# Apply a step's captures (VAR -> regex|whole) from output into the env file.
_flow_apply_captures() {
    local step="$1" out="$2" var rgx val tmp
    while IFS=$'\t' read -r var rgx; do
        [ -z "$var" ] && continue
        if [ -n "$rgx" ]; then
            val=$(printf '%s\n' "$out" | grep -oE -e "$rgx" | head -1)
        else
            val=$(printf '%s' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        fi
        [ ! -f "$ENV_FILE" ] && echo "{}" > "$ENV_FILE"
        tmp=$(_mktemp_beside "$ENV_FILE")
        jq --arg k "$var" --arg v "$val" '. + {($k): $v}' "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
        echo -e "  ${GREEN}captured${NC} {$var} = $val"
    done < <(printf '%s' "$step" | jq -r '.capture // {} | to_entries[] | "\(.key)\t\(.value)"')
}

# Prepare a step: echo  tag \x1f display_cmd \x1f host \x1f danger  (nonzero on error).
_flow_prepare() {
    local s="$1" run resolved eff cmd danger host="" disp
    run=$(printf '%s' "$s" | jq -r '.run // empty')
    [ -z "$run" ] && { echo "step has no 'run'" >&2; return 2; }
    local args=() a
    while IFS= read -r a; do
        if [ "${a:0:1}" = "@" ]; then host="${a:1}"; else args+=("$a"); fi
    done < <(printf '%s' "$s" | jq -r '.args[]? // empty')
    resolved=$(resolve_tag_or_alias "$run")
    [ -z "$resolved" ] && { echo "unknown command '$run'" >&2; return 2; }
    eff=$(get_effective_commands)
    cmd=$(printf '%s' "$eff" | jq -r --arg t "$resolved" '.[$t].command // empty')
    danger=$(printf '%s' "$eff" | jq -r --arg t "$resolved" '.[$t].danger // false')
    [ -z "$cmd" ] && { echo "command '$run' empty" >&2; return 2; }
    [ -n "$host" ] && { _host_exists "$host" || { echo "unknown host '$host'" >&2; return 2; }; cmd=$(apply_host_vars "$cmd" "$host"); }
    disp=$(resolve_command "$cmd" "${args[@]}") || return 1
    printf '%s\x1f%s\x1f%s\x1f%s' "$resolved" "$disp" "$host" "$danger"
}

# Execute one workflow step. Updates state + captures; returns the step exit.
_flow_exec_one() {
    local s="$1" state="$2" idx="$3"
    local when id
    when=$(printf '%s' "$s" | jq -r '.when // empty')
    id=$(printf '%s' "$s" | jq -r '.register // .run // empty'); [ -z "$id" ] && id="step$idx"

    if [ -n "$when" ] && ! _flow_eval_when "$when" "$state"; then
        echo -e "${YELLOW}↷ skip${NC} [$id]  (when: $when)"
        return 0
    fi

    local prep tag disp host danger
    prep=$(_flow_prepare "$s") || { echo -e "${RED}✗ [$id] $prep${NC}"; return 1; }
    IFS=$'\x1f' read -r tag disp host danger <<< "$prep"
    local label="$id"; [ -n "$host" ] && label="$id@$host"

    if [ "$danger" = "true" ] && [ "$DRY_RUN" != true ]; then
        echo -e "${RED}${BOLD}DANGER:${NC} $disp"
        read -p "Run this command marked dangerous? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo -e "${YELLOW}Skipped '$label'.${NC}"; return 0
        fi
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}▷ [$label]${NC} $disp"
        _flow_state_set "$state" "$id" 0 ""
        return 0
    fi

    local exec_cmd remote
    exec_cmd=$(resolve_secrets "$disp")
    remote=$(printf '%s' "$s" | jq -r '.remote // false')
    if [ "$remote" = "true" ] && [ -n "$host" ]; then
        exec_cmd=$(build_ssh_cmd "$host" "$exec_cmd") || return 1
    fi

    local retry tmo trun=()
    retry=$(printf '%s' "$s" | jq -r '.retry // 0')
    tmo=$(printf '%s' "$s" | jq -r '.timeout // 0')
    if [ "$tmo" -gt 0 ] 2>/dev/null; then
        if command -v timeout >/dev/null 2>&1; then trun=(timeout "$tmo")
        elif command -v gtimeout >/dev/null 2>&1; then trun=(gtimeout "$tmo"); fi
    fi

    echo -e "${CYAN}▶ [$label]${NC} $disp"
    local attempt=0 status out
    while :; do
        out=$("${trun[@]}" bash -c "$exec_cmd"); status=$?
        [ "$status" -eq 0 ] && break
        attempt=$((attempt + 1))
        [ "$attempt" -gt "$retry" ] && break
        echo -e "  ${YELLOW}retry $attempt/$retry (exit $status)${NC}"
    done
    printf '%s\n' "$out"
    _flow_apply_captures "$s" "$out"
    _flow_state_set "$state" "$id" "$status" "$out"
    record_history "$tag" "$disp" "$host" "$status" "0"
    echo -e "  ${CYAN}exit $status${NC}"
    return $status
}

# Execute a parallel block: substeps run concurrently, results applied in order.
_flow_exec_parallel() {
    local s="$1" state="$2" idx="$3"
    local tmpd; tmpd=$(mktemp -d "${TMPDIR:-/tmp}/cmdrpar.XXXXXX")
    echo -e "${BOLD}${CYAN}∥ parallel block${NC}"
    local k=0 sub
    while IFS= read -r sub; do
        ( _flow_exec_one "$sub" "$state" "${idx}p${k}" >"$tmpd/$k.out" 2>&1; echo $? >"$tmpd/$k.rc" ) &
        k=$((k + 1))
    done < <(printf '%s' "$s" | jq -c '.parallel[]')
    wait

    local combined=0 j=0 rc
    while [ "$j" -lt "$k" ]; do
        sed 's/^/  /' "$tmpd/$j.out" 2>/dev/null
        rc=$(cat "$tmpd/$j.rc" 2>/dev/null || echo 1)
        [ "$rc" != "0" ] && combined="$rc"
        j=$((j + 1))
    done
    rm -rf "$tmpd"
    return "$combined"
}

# Run a workflow by name or file.
flow_run() {
    local ref="$1" wf name n i=0 overall=0 st step coe state
    wf=$(_flow_load "$ref") || exit 1
    if ! printf '%s' "$wf" | jq -e '(.steps | type) == "array"' >/dev/null 2>&1; then
        echo -e "${RED}Error:${NC} Workflow has no 'steps' array."; exit 1
    fi
    name=$(printf '%s' "$wf" | jq -r '.name // empty'); [ -z "$name" ] && name="$ref"

    echo -e "${BOLD}${GREEN}Running workflow: $name${NC}"
    [ "$DRY_RUN" = true ] && echo -e "${YELLOW}(dry run — conditions on captured values may be approximate)${NC}"
    echo ""

    state=$(_mktemp_beside "$WORKFLOWS_FILE"); echo '{"steps":{}}' > "$state"
    n=$(printf '%s' "$wf" | jq '.steps | length')
    while [ "$i" -lt "$n" ]; do
        step=$(printf '%s' "$wf" | jq -c --argjson i "$i" '.steps[$i]')
        if printf '%s' "$step" | jq -e 'has("parallel")' >/dev/null 2>&1; then
            _flow_exec_parallel "$step" "$state" "$i"; st=$?
        else
            _flow_exec_one "$step" "$state" "$i"; st=$?
        fi
        if [ "$st" -ne 0 ]; then
            coe=$(printf '%s' "$step" | jq -r '.continue_on_error // false')
            if [ "$coe" != "true" ] && [ "$DRY_RUN" != true ]; then
                echo -e "\n${RED}Workflow stopped at step $((i + 1)) (exit $st).${NC}"
                rm -f "$state"; return "$st"
            fi
            overall="$st"
        fi
        i=$((i + 1)); echo ""
    done
    rm -f "$state"
    echo -e "${GREEN}Workflow '$name' completed.${NC}"
    return "$overall"
}

# Store a workflow file under its declared .name.
flow_import() {
    local file="$1"
    if [ -z "$file" ] || [ ! -f "$file" ]; then echo -e "${RED}Error:${NC} Workflow file not found."; exit 1; fi
    if ! jq -e . "$file" >/dev/null 2>&1; then echo -e "${RED}Error:${NC} Not valid JSON."; exit 1; fi
    local name; name=$(jq -r '.name // empty' "$file")
    [ -z "$name" ] && { echo -e "${RED}Error:${NC} Workflow needs a top-level \"name\"."; exit 1; }
    if ! jq -e '(.steps | type) == "array"' "$file" >/dev/null 2>&1; then
        echo -e "${RED}Error:${NC} Workflow needs a \"steps\" array."; exit 1
    fi
    name=$(sanitize_tag "$name") || exit 1
    [ ! -f "$WORKFLOWS_FILE" ] && echo "{}" > "$WORKFLOWS_FILE"
    local doc tmp; doc=$(cat "$file")
    tmp=$(_mktemp_beside "$WORKFLOWS_FILE")
    jq --arg n "$name" --argjson d "$doc" '. + {($n): $d}' "$WORKFLOWS_FILE" > "$tmp" && mv "$tmp" "$WORKFLOWS_FILE"
    log_event "INFO" "Workflow imported: $name"
    echo -e "${GREEN}Workflow imported:${NC} $name ($(printf '%s' "$doc" | jq '.steps | length') steps)"
}

# List stored workflows.
flow_list() {
    if [ ! -f "$WORKFLOWS_FILE" ] || [ "$(jq 'length' "$WORKFLOWS_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}No workflows stored.${NC} Import one with 'cmdr --flow import <file.json>'."
        return 0
    fi
    echo -e "${BOLD}${YELLOW}Workflows:${NC}"
    echo ""
    jq -r 'to_entries[] | "\(.key)\t\(.value.steps | length)"' "$WORKFLOWS_FILE" \
        | while IFS=$'\t' read -r nm cnt; do
            printf "  ${CYAN}%-22s${NC} %s steps\n" "$nm" "$cnt"
        done
}

# Print a stored workflow (or file) as pretty JSON.
flow_show() {
    local ref="$1" wf
    wf=$(_flow_load "$ref") || exit 1
    printf '%s' "$wf" | jq .
}

