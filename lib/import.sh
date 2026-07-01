#!/bin/bash
# ============================================================================
# CMDR :: lib/import.sh
# Import commands from external sources (shell history, tldr, cheat.sh, files)
# ============================================================================
# Lowers the cost of building a command library by pulling one-liners from
# sources you already have. Every source funnels into a common preview-then-
# confirm-then-merge path, so nothing is written without showing it first, and
# duplicate tags are auto-uniquified rather than overwriting existing commands.
#
#   cmdr --import history [N]     most recent N unique shell-history commands
#   cmdr --import tldr <page>     example commands from a tldr page
#   cmdr --import cheat <topic>   commands from cheat.sh/<topic> (needs curl)
#   cmdr --import file <path>     a JSON pack or a plain text list of commands
#
# Add -y to skip the confirmation. Writes go to the active store (or the
# project-local store with --local). Bash 3.2 compatible (no assoc arrays).
# ============================================================================

# Derive a valid tag from a command line: first non-flag/non-assignment token,
# reduced to [a-zA-Z0-9_-]. Falls back to "cmd".
_import_tag_from_cmd() {
    local cmd="$1" base
    base=$(printf '%s\n' "$cmd" | awk '{for(i=1;i<=NF;i++){ if($i !~ /^-/ && $i !~ /=/ ){print $i; exit}}}')
    [ -z "$base" ] && base=$(printf '%s\n' "$cmd" | awk '{print $1}')
    base=$(basename "$base" 2>/dev/null)
    base=$(printf '%s' "$base" | tr -c 'a-zA-Z0-9_-' '-' | sed 's/-\{1,\}/-/g;s/^-//;s/-$//')
    [ -z "$base" ] && base="cmd"
    printf '%s' "$base"
}

# --- Sources: each emits rows "tag<US>command<US>description<US>category", where
#     <US> is the ASCII unit separator (0x1f). It is used instead of a tab so an
#     empty middle field (e.g. a missing description) is not collapsed by read.

_import_source_history() {
    local n="${1:-30}" hf="" cand
    for cand in "${HISTFILE:-}" "$HOME/.bash_history" "$HOME/.zsh_history"; do
        [ -n "$cand" ] && [ -f "$cand" ] && { hf="$cand"; break; }
    done
    [ -z "$hf" ] && { echo -e "${RED}Error:${NC} No shell history file found." >&2; return 1; }
    # zsh EXTENDED_HISTORY lines look like ": 1680000000:0;the command" — strip
    # that prefix; then drop blanks, keep most-recent unique, take the last N.
    sed -E 's/^: [0-9]+:[0-9]+;//' "$hf" 2>/dev/null \
        | grep -vE '^[[:space:]]*$' \
        | awk '!seen[$0]++' \
        | tail -n "$n" \
        | while IFS= read -r c; do
              printf '%s\037%s\037%s\037history\n' "$(_import_tag_from_cmd "$c")" "$c" "from shell history"
          done
}

_import_source_tldr() {
    local page="$1"
    [ -z "$page" ] && { echo -e "${RED}Error:${NC} Usage: cmdr --import tldr <page>" >&2; return 1; }
    command -v tldr >/dev/null 2>&1 || { echo -e "${RED}Error:${NC} 'tldr' client not installed." >&2; return 1; }
    local raw
    raw=$(tldr "$page" 2>/dev/null) || { echo -e "${RED}Error:${NC} tldr page '$page' not found." >&2; return 1; }
    # Prefer backtick-wrapped commands (raw markdown / clients that keep them);
    # fall back to indented example lines when the client strips backticks.
    local cmds
    cmds=$(printf '%s\n' "$raw" | grep -oE '`[^`]+`' | sed 's/^`//;s/`$//')
    if [ -z "$cmds" ]; then
        cmds=$(printf '%s\n' "$raw" \
            | grep -E '^[[:space:]]+[^[:space:]-]' \
            | sed 's/^[[:space:]]*//')
    fi
    printf '%s\n' "$cmds" | grep -vE '^[[:space:]]*$' \
        | while IFS= read -r c; do
              printf '%s\037%s\037%s\037tldr\n' "$(_import_tag_from_cmd "$c")" "$c" "tldr:$page"
          done
}

_import_source_cheat() {
    local topic="$1"
    [ -z "$topic" ] && { echo -e "${RED}Error:${NC} Usage: cmdr --import cheat <topic>" >&2; return 1; }
    command -v curl >/dev/null 2>&1 || { echo -e "${RED}Error:${NC} 'curl' required for cheat.sh import." >&2; return 1; }
    local raw
    raw=$(curl -fsS "https://cheat.sh/${topic}?T" 2>/dev/null) \
        || { echo -e "${RED}Error:${NC} Could not fetch cheat.sh/${topic}." >&2; return 1; }
    # cheat.sh plain-text pages interleave "# comment" descriptions with command
    # lines. Pair each command with the nearest preceding comment as description.
    printf '%s\n' "$raw" | awk -F'\t' '
        /^[[:space:]]*#/ { d=$0; sub(/^[[:space:]]*#[[:space:]]*/,"",d); next }
        /^[[:space:]]*$/ { next }
        { print $0 "\t" d }' \
        | while IFS=$'\t' read -r c d; do
              [ -z "$c" ] && continue
              printf '%s\037%s\037%s\037cheat\n' "$(_import_tag_from_cmd "$c")" "$c" "${d:-cheat:$topic}"
          done
}

_import_source_file() {
    local path="$1"
    [ -z "$path" ] && { echo -e "${RED}Error:${NC} Usage: cmdr --import file <path>" >&2; return 1; }
    [ -f "$path" ] || { echo -e "${RED}Error:${NC} No such file: $path" >&2; return 1; }
    if jq -e . "$path" >/dev/null 2>&1; then
        # JSON: a pack object {tag:{command,category,description}} or an array of
        # {tag|name, command, category?, description?}.
        jq -r '
            if type=="array" then
                .[] | [(.tag // .name // ""), .command, (.description // ""), (.category // "file")]
            else
                to_entries[] | [.key, .value.command, (.value.description // ""), (.value.category // "file")]
            end | join("\u001f")' "$path" 2>/dev/null
    else
        grep -vE '^[[:space:]]*(#|$)' "$path" \
            | while IFS= read -r c; do
                  printf '%s\037%s\037%s\037file\n' "$(_import_tag_from_cmd "$c")" "$c" "from $(basename "$path")"
              done
    fi
}

# Common path: dedup + uniquify tags, preview, confirm, merge into the store.
_import_apply() {
    local rows="$1"
    local target="${WRITE_COMMANDS_FILE:-$COMMANDS_FILE}"
    [ -f "$target" ] || echo "{}" > "$target"

    local existing
    existing=$(jq -r 'keys[]' "$target" 2>/dev/null)

    local newjson="{}" count=0 skipped=0
    local tag cmd desc cat base i
    while IFS=$'\037' read -r tag cmd desc cat; do
        [ -z "$cmd" ] && continue
        cmd=$(sanitize_command "$cmd" 2>/dev/null) || { skipped=$((skipped + 1)); continue; }
        [ -z "$tag" ] && tag=$(_import_tag_from_cmd "$cmd")
        tag=$(sanitize_tag "$tag" 2>/dev/null) || { skipped=$((skipped + 1)); continue; }
        [ -z "$cat" ] && cat="imported"

        # Uniquify against existing store tags and tags already staged this run.
        base="$tag"; i=2
        while printf '%s\n' "$existing" | grep -qxF "$tag" \
              || printf '%s' "$newjson" | jq -e --arg t "$tag" 'has($t)' >/dev/null 2>&1; do
            tag="${base}-${i}"; i=$((i + 1))
        done

        newjson=$(printf '%s' "$newjson" | jq --arg t "$tag" --arg c "$cmd" --arg d "$desc" --arg cat "$cat" \
            '. + {($t): {command:$c, category:$cat, description:$d, aliases:[]}}')
        count=$((count + 1))
    done <<< "$rows"

    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}Nothing to import.${NC} ($skipped skipped)"
        return 0
    fi

    echo -e "${BOLD}${YELLOW}Preview — $count command(s) to import${NC} into $(basename "$target"):"
    printf '%s' "$newjson" | jq -r 'to_entries[] | "  \(.key)  [\(.value.category)]  \(.value.command)"'
    [ "$skipped" -gt 0 ] && echo -e "${CYAN}($skipped line(s) skipped as empty/invalid)${NC}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN]${NC} No changes written."
        return 0
    fi

    if [ "${CMDR_FORCE_YES:-false}" != true ]; then
        printf "Import these %d command(s)? (y/N): " "$count"
        local confirm; read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo -e "${YELLOW}Import cancelled.${NC}"
            return 0
        fi
    fi

    with_store_lock _import_merge "$target" "$newjson"
    log_event "INFO" "Imported $count command(s) into $target"
    echo -e "${GREEN}Imported $count command(s).${NC}"
}

# Merge staged entries into the target, keeping existing commands (fresh tags
# were already uniquified, so a plain right-biased-toward-existing merge is safe).
_import_merge() {
    local target="$1" newjson="$2" tmp
    tmp=$(_mktemp_beside "$target")
    printf '%s' "$newjson" | jq -s '.[1] * .[0]' "$target" - > "$tmp" && mv "$tmp" "$target"
}

# Entry point: `cmdr --import <source> [args...]`.
import_external() {
    local source="${1:-}"
    shift 2>/dev/null || true

    local rows rc
    case "$source" in
        history) rows=$(_import_source_history "$@"); rc=$? ;;
        tldr)    rows=$(_import_source_tldr "$@");    rc=$? ;;
        cheat)   rows=$(_import_source_cheat "$@");   rc=$? ;;
        file)    rows=$(_import_source_file "$@");    rc=$? ;;
        ""|--help|help)
            display_subcommand_help "import"; return 0 ;;
        *)
            echo -e "${RED}Error:${NC} Unknown import source '$source'. Use history|tldr|cheat|file." >&2
            return 1 ;;
    esac
    [ "${rc:-1}" -ne 0 ] && return 1
    if [ -z "$rows" ]; then
        echo -e "${YELLOW}Nothing to import from '$source'.${NC}"
        return 0
    fi
    _import_apply "$rows"
}
