#!/bin/bash
# ============================================================================
# CMDR :: lib/resolve.sh
# Tag/env/command resolution and secrets
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

# ----------------------------------------------------------------------------
# Section 3: Resolution Helpers
# Resolve tags/aliases across global, workspace, and local command stores.
# Merge environment variables into command templates.
# ----------------------------------------------------------------------------

# Hash a file's contents (used to pin trusted project-local command files).
_hash_file() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" | awk '{print $1}'
    else
        # Weak fallback when no SHA tool exists: byte count.
        wc -c < "$f" | tr -d ' '
    fi
}

# True only when the current project-local .cmdr.json exists and its content
# matches the hash recorded in the trust store. Untrusted/modified files fail.
is_local_trusted() {
    [ -f "$LOCAL_COMMANDS_FILE" ] || return 1
    [ -f "$TRUST_FILE" ] || return 1
    local current stored
    current=$(_hash_file "$LOCAL_COMMANDS_FILE")
    stored=$(jq -r --arg p "$LOCAL_COMMANDS_FILE" '.[$p] // empty' "$TRUST_FILE" 2>/dev/null)
    [ -n "$stored" ] && [ "$stored" = "$current" ]
}

# Print a one-time notice when a non-empty but untrusted .cmdr.json is present.
# Called from main-shell entry points (not subshells) so it fires once.
notify_untrusted_local() {
    if [ -f "$LOCAL_COMMANDS_FILE" ] \
       && [ "$(jq 'length' "$LOCAL_COMMANDS_FILE" 2>/dev/null || echo 0)" -gt 0 ] \
       && ! is_local_trusted; then
        echo -e "${YELLOW}Note:${NC} Ignoring untrusted .cmdr.json in $(pwd)." >&2
        echo -e "      Review it, then run ${CYAN}cmdr --trust${NC} to enable it." >&2
    fi
}

# Record the current local file's hash as trusted (quiet; used after --local writes).
_retrust_local() {
    [ -f "$LOCAL_COMMANDS_FILE" ] || return 0
    [ ! -f "$TRUST_FILE" ] && echo "{}" > "$TRUST_FILE"
    local h tmp_file
    h=$(_hash_file "$LOCAL_COMMANDS_FILE")
    tmp_file=$(_mktemp_beside "$TRUST_FILE")
    jq --arg p "$LOCAL_COMMANDS_FILE" --arg h "$h" '. + {($p): $h}' "$TRUST_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$TRUST_FILE"
}

# Return merged JSON of global/workspace + local commands.
# Local entries override global entries with the same tag, but only when the
# local file is trusted (see is_local_trusted) to avoid auto-running commands
# from an untrusted directory's .cmdr.json.
get_effective_commands() {
    if [ -f "$LOCAL_COMMANDS_FILE" ] && jq -e . "$LOCAL_COMMANDS_FILE" >/dev/null 2>&1 \
       && [ "$(jq 'length' "$LOCAL_COMMANDS_FILE" 2>/dev/null)" -gt 0 ] \
       && is_local_trusted; then
        jq -s '.[0] * .[1]' "$COMMANDS_FILE" "$LOCAL_COMMANDS_FILE"
    else
        cat "$COMMANDS_FILE"
    fi
}

# Approve the current directory's .cmdr.json so its commands are merged and runnable.
trust_local() {
    if [ ! -f "$LOCAL_COMMANDS_FILE" ]; then
        echo -e "${RED}Error:${NC} No .cmdr.json in $(pwd)."
        exit 1
    fi
    if ! jq -e . "$LOCAL_COMMANDS_FILE" >/dev/null 2>&1; then
        echo -e "${RED}Error:${NC} .cmdr.json in $(pwd) is not valid JSON."
        exit 1
    fi
    _retrust_local
    log_event "INFO" "Trusted local file: $LOCAL_COMMANDS_FILE"
    echo -e "${GREEN}Trusted:${NC} $LOCAL_COMMANDS_FILE"
}

# Revoke trust for the current directory's .cmdr.json.
untrust_local() {
    if [ ! -f "$TRUST_FILE" ] \
       || ! jq -e --arg p "$LOCAL_COMMANDS_FILE" 'has($p)' "$TRUST_FILE" >/dev/null 2>&1; then
        echo -e "${YELLOW}Not trusted:${NC} $LOCAL_COMMANDS_FILE"
        return 0
    fi
    local tmp_file
    tmp_file=$(_mktemp_beside "$TRUST_FILE")
    jq --arg p "$LOCAL_COMMANDS_FILE" 'del(.[$p])' "$TRUST_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$TRUST_FILE"
    log_event "INFO" "Untrusted local file: $LOCAL_COMMANDS_FILE"
    echo -e "${GREEN}Untrusted:${NC} $LOCAL_COMMANDS_FILE"
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

# Full command resolution pipeline. Placeholder forms, resolved left-to-right:
#   {VAR}            env var, else next positional arg, else interactive prompt
#   {VAR:=default}   env var, else next positional arg, else 'default' (no prompt)
#   {VAR:?}          env var, else next positional arg, else hard error (required)
# Returns non-zero if a required placeholder cannot be satisfied.
resolve_command() {
    local cmd="$1"
    shift
    local run_args=("$@")

    # Step 1: substitute plain {KEY} env vars up front (back-compat / fast path).
    cmd=$(resolve_env_vars "$cmd")

    # Step 1b: protect secret-backed placeholders so they survive this pass
    # untouched. They are filled later by resolve_secrets() at exec time, which
    # keeps the secret out of the displayed/recorded command. RS (0x1e) marker.
    local _sname
    while IFS= read -r _sname; do
        [ -z "$_sname" ] && continue
        cmd="${cmd//\{$_sname\}/$'\x1e'$_sname$'\x1e'}"
    done < <(_secret_names)

    # Step 2: unified left-to-right pass over remaining placeholders.
    local i=0
    while :; do
        local token
        token=$(printf '%s' "$cmd" \
            | grep -oE '\{[a-zA-Z_][a-zA-Z0-9_]*(:=[^}]*|:\?)?\}' | head -1)
        [ -z "$token" ] && break

        local inner="${token:1:${#token}-2}"   # strip surrounding { }
        local name mod="" default=""
        if [[ "$inner" == *:=* ]]; then
            name="${inner%%:=*}"; default="${inner#*:=}"; mod="default"
        elif [[ "$inner" == *":?" ]]; then
            name="${inner%:?}"; mod="required"
        else
            name="$inner"
        fi

        # Prefer an env value (covers the modifier forms, which step 1 skips).
        local value="" envval=""
        if [ -f "$ENV_FILE" ]; then
            envval=$(jq -r --arg k "$name" '.[$k] // empty' "$ENV_FILE" 2>/dev/null)
        fi

        if [ -n "$envval" ]; then
            value="$envval"
        elif [ "$i" -lt "${#run_args[@]}" ]; then
            value="${run_args[$i]}"; ((i++))
        elif [ "$mod" = "default" ]; then
            value="$default"
        elif [ "$mod" = "required" ]; then
            echo -e "${RED}Error:${NC} Required value '{$name}' not provided." >&2
            return 1
        elif [ "$DRY_RUN" = true ]; then
            # Never block on a prompt during a dry run; show the gap instead.
            value="<$name>"
        else
            read -p "Enter value for $name: " value
        fi

        # Replace every occurrence of this exact token in one shot.
        cmd="${cmd//"$token"/$value}"
    done

    # Restore protected secret placeholders back to {NAME} for display/exec.
    # Build the replacement in a var: backslashes in a ${//} replacement are
    # inserted literally, and a bare } would close the expansion early.
    local _restore
    while IFS= read -r _sname; do
        [ -z "$_sname" ] && continue
        _restore="{$_sname}"
        cmd="${cmd//$'\x1e'$_sname$'\x1e'/$_restore}"
    done < <(_secret_names)

    echo "$cmd"
}

# ----------------------------------------------------------------------------
# Section 3b: Secrets
# Per-workspace map of NAME -> {provider, ref}. Referenced as {NAME} in
# commands and fetched lazily at execution time, so the secret never lands in
# the stored command, the run history, or the on-screen "Running" line.
# Providers: pass | cmd | env | age | file.
# ----------------------------------------------------------------------------

# Print configured secret names, one per line.
_secret_names() {
    [ -f "$SECRETS_FILE" ] || return 0
    jq -r 'keys[]' "$SECRETS_FILE" 2>/dev/null
}

# Resolve a single secret NAME to its value (first line, trimmed). Empty on miss.
resolve_secret() {
    local name="$1"
    [ -f "$SECRETS_FILE" ] || return 0
    local provider ref
    provider=$(jq -r --arg n "$name" '.[$n].provider // empty' "$SECRETS_FILE" 2>/dev/null)
    ref=$(jq -r --arg n "$name" '.[$n].ref // empty' "$SECRETS_FILE" 2>/dev/null)
    [ -z "$provider" ] && return 0

    local val=""
    case "$provider" in
        pass) command -v pass >/dev/null 2>&1 && val=$(pass show "$ref" 2>/dev/null | head -1) ;;
        cmd)  val=$(bash -c "$ref" 2>/dev/null | head -1) ;;
        env)  val="${!ref:-}" ;;
        age)  command -v age >/dev/null 2>&1 && val=$(age -d "$ref" 2>/dev/null | head -1) ;;
        file) [ -f "$ref" ] && val=$(head -1 "$ref") ;;
        *)    val="" ;;
    esac
    printf '%s' "$val"
}

# Replace every {NAME} that maps to a secret with its live value. Used only at
# the moment of execution; the input (display) command keeps the {NAME} token.
resolve_secrets() {
    local cmd="$1" name val
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        case "$cmd" in
            *"{$name}"*) val=$(resolve_secret "$name"); cmd="${cmd//\{$name\}/$val}" ;;
        esac
    done < <(_secret_names)
    printf '%s' "$cmd"
}

# Register a secret: cmdr --secret NAME provider:ref
set_secret() {
    local name="$1" spec="$2"
    if [ -z "$name" ] || [ -z "$spec" ] || [ "$spec" = "$name" ] || [[ "$spec" != *:* ]]; then
        echo -e "${RED}Error:${NC} Usage: cmdr --secret NAME provider:ref"
        echo -e "Providers: ${CYAN}pass${NC}:path  ${CYAN}cmd${NC}:'shell'  ${CYAN}env${NC}:VAR  ${CYAN}age${NC}:file  ${CYAN}file${NC}:path"
        exit 1
    fi
    name=$(sanitize_tag "$name") || exit 1
    local provider="${spec%%:*}" ref="${spec#*:}"
    case "$provider" in
        pass|cmd|env|age|file) ;;
        *) echo -e "${RED}Error:${NC} Unknown provider '$provider'. Use pass/cmd/env/age/file."; exit 1 ;;
    esac

    [ ! -f "$SECRETS_FILE" ] && echo "{}" > "$SECRETS_FILE"
    local tmp_file
    tmp_file=$(_mktemp_beside "$SECRETS_FILE")
    jq --arg n "$name" --arg p "$provider" --arg r "$ref" \
        '. + {($n): {provider:$p, ref:$r}}' "$SECRETS_FILE" > "$tmp_file" && mv "$tmp_file" "$SECRETS_FILE"
    log_event "INFO" "Secret set: $name ($provider)"
    echo -e "${GREEN}Secret set:${NC} {$name} -> ${provider}:${ref}"
}

# List configured secrets (provider/ref shown; values never fetched here).
list_secrets() {
    if [ ! -f "$SECRETS_FILE" ] || [ "$(jq 'length' "$SECRETS_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}No secrets configured.${NC}"
        return 0
    fi
    echo -e "${BOLD}${YELLOW}Secrets${NC} (use as {NAME} in commands):"
    echo ""
    jq -r 'to_entries[] | "  {\(.key)}\t\(.value.provider):\(.value.ref)"' "$SECRETS_FILE" \
        | while IFS=$'\t' read -r nm src; do
            printf "  ${CYAN}%-22s${NC} %s\n" "$nm" "$src"
        done
}

# Remove a secret mapping.
clear_secret() {
    local name="$1"
    if [ ! -f "$SECRETS_FILE" ] || ! jq -e --arg n "$name" 'has($n)' "$SECRETS_FILE" >/dev/null 2>&1; then
        echo -e "${YELLOW}Secret '$name' not found.${NC}"; return 0
    fi
    local tmp_file
    tmp_file=$(_mktemp_beside "$SECRETS_FILE")
    jq --arg n "$name" 'del(.[$n])' "$SECRETS_FILE" > "$tmp_file" && mv "$tmp_file" "$SECRETS_FILE"
    log_event "INFO" "Secret cleared: $name"
    echo -e "${GREEN}Secret cleared:${NC} $name"
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

