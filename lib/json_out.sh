#!/bin/bash
# ============================================================================
# CMDR :: lib/json_out.sh
# Machine-readable (--json) output for read commands
# ============================================================================
# When the global --json flag is set, read commands emit structured JSON to
# stdout instead of the human-formatted tables, so CMDR composes with jq,
# scripts, and other tools. Only read/list actions support it; mutating actions
# ignore the flag. Each json_* helper prints a single JSON document.
# ============================================================================

# Pretty-print a JSON file, or a fallback literal when it is missing/empty/bad.
_json_emit_file() {
    local file="$1" fallback="${2:-[]}"
    if [ -s "$file" ] && jq -e . "$file" >/dev/null 2>&1; then
        jq . "$file"
    else
        printf '%s\n' "$fallback"
    fi
}

# All effective (workspace + trusted-local) commands, as the stored object.
json_commands() {
    get_effective_commands | jq .
}

# Subset of effective commands whose tag/command/category/description/alias
# matches the keyword (case-insensitive) — same predicate as the text search.
json_search() {
    local keyword="$1"
    get_effective_commands | jq --arg kw "$keyword" '
        with_entries(select(
            (.key | ascii_downcase | contains($kw | ascii_downcase)) or
            (.value.command | ascii_downcase | contains($kw | ascii_downcase)) or
            (.value.category | ascii_downcase | contains($kw | ascii_downcase)) or
            ((.value.description // "") | ascii_downcase | contains($kw | ascii_downcase)) or
            ((.value.aliases // []) | any(ascii_downcase | contains($kw | ascii_downcase)))
        ))'
}

json_history()  { _json_emit_file "$HISTORY_FILE"  '[]'; }
json_findings() { _json_emit_file "$FINDINGS_FILE" '[]'; }
json_hosts()    { _json_emit_file "$HOSTS_FILE"    '{}'; }

# Workspaces as an array of {name, active, commands, locked}.
json_workspaces() {
    local out="[]"
    local def_count
    def_count=$(jq 'length' "$DATA_DIR/my_commands.json" 2>/dev/null || echo 0)
    out=$(jq -n --arg n default --argjson c "${def_count:-0}" \
        --argjson active "$([ "$ACTIVE_WORKSPACE" = default ] && echo true || echo false)" \
        '[{name:$n, active:$active, commands:$c, locked:false}]')

    if [ -d "$DATA_DIR/workspaces" ]; then
        while IFS= read -r ws_dir; do
            [ -z "$ws_dir" ] && continue
            local name count
            name=$(basename "$ws_dir")
            count=$(jq 'length' "$ws_dir/my_commands.json" 2>/dev/null || echo 0)
            out=$(printf '%s' "$out" | jq --arg n "$name" --argjson c "${count:-0}" \
                --argjson active "$([ "$name" = "$ACTIVE_WORKSPACE" ] && echo true || echo false)" \
                '. + [{name:$n, active:$active, commands:$c, locked:false}]')
        done < <(find "$DATA_DIR/workspaces" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
        while IFS= read -r blob; do
            [ -f "$blob" ] || continue
            local name
            name=$(basename "$blob" .cmdrlock)
            out=$(printf '%s' "$out" | jq --arg n "$name" \
                '. + [{name:$n, active:false, commands:null, locked:true}]')
        done < <(find "$DATA_DIR/workspaces" -mindepth 1 -maxdepth 1 -name '*.cmdrlock' 2>/dev/null | sort)
    fi
    printf '%s\n' "$out"
}

# Packs as an array of {name, path, commands, categories:[...]}.
json_packs() {
    if [ ! -d "$PACKS_DIR" ]; then printf '%s\n' '[]'; return 0; fi
    local out="[]"
    for pack_file in "$PACKS_DIR"/*.json; do
        [ -f "$pack_file" ] || continue
        local name count cats
        name=$(basename "$pack_file" .json)
        count=$(jq 'length' "$pack_file" 2>/dev/null || echo 0)
        cats=$(jq -c '[.[] | .category] | unique' "$pack_file" 2>/dev/null || echo '[]')
        out=$(printf '%s' "$out" | jq --arg n "$name" --arg p "$pack_file" \
            --argjson c "${count:-0}" --argjson cats "${cats:-[]}" \
            '. + [{name:$n, path:$p, commands:$c, categories:$cats}]')
    done
    printf '%s\n' "$out"
}
