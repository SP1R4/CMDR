#!/bin/bash
# ============================================================================
# CMDR :: lib/maintenance.sh
# Lint and git-backed sync
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

# ----------------------------------------------------------------------------
# Section 12c: Lint
# Validate command stores, packs, and workflows for common mistakes.
# ----------------------------------------------------------------------------

# Lint one command-store JSON file. Prints issues and adds to LINT_TOTAL
# (runs in the current shell, not a subshell, so the counter persists).
_lint_store() {
    local file="$1" label="$2" k
    [ -f "$file" ] || return 0
    if ! jq -e . "$file" >/dev/null 2>&1; then
        echo -e "  ${RED}✗${NC} $label: invalid JSON"; LINT_TOTAL=$((LINT_TOTAL + 1)); return 0
    fi
    # Empty commands
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        echo -e "  ${RED}✗${NC} $label: '$k' has an empty command"; LINT_TOTAL=$((LINT_TOTAL + 1))
    done < <(jq -r 'to_entries[] | select((.value.command // "") == "") | .key' "$file" 2>/dev/null)
    # Bad tag names
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        echo -e "  ${RED}✗${NC} $label: tag '$k' has invalid characters"; LINT_TOTAL=$((LINT_TOTAL + 1))
    done < <(jq -r 'keys[] | select(test("^[a-zA-Z0-9_-]+$") | not)' "$file" 2>/dev/null)
    # Unbalanced placeholder braces
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        echo -e "  ${YELLOW}!${NC} $label: '$k' has unbalanced { } in its command"; LINT_TOTAL=$((LINT_TOTAL + 1))
    done < <(jq -r 'to_entries[] | .key as $k | (.value.command // "") as $c
        | ($c | gsub("[^{]";"") | length) as $o | ($c | gsub("[^}]";"") | length) as $cl
        | select($o != $cl) | $k' "$file" 2>/dev/null)
    # Alias shadows a *different* command's tag (an alias matching its own tag is
    # redundant but allowed, matching validate_aliases).
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        echo -e "  ${RED}✗${NC} $label: alias '$k' shadows another command's tag"; LINT_TOTAL=$((LINT_TOTAL + 1))
    done < <(jq -r '(keys) as $t
        | to_entries[] | .key as $own | (.value.aliases // [])[]
        | select(. as $a | ($t | index($a)) != null and $a != $own)' "$file" 2>/dev/null)
    # Same alias claimed by two commands (same file)
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        echo -e "  ${RED}✗${NC} $label: alias '$k' is used by more than one command"; LINT_TOTAL=$((LINT_TOTAL + 1))
    done < <(jq -r '[.[].aliases[]?] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$file" 2>/dev/null)
}

LINT_TOTAL=0
lint_all() {
    LINT_TOTAL=0
    echo -e "${BOLD}${YELLOW}Linting command stores${NC}"
    _lint_store "$COMMANDS_FILE" "workspace"
    if [ -f "$LOCAL_COMMANDS_FILE" ] && is_local_trusted; then
        _lint_store "$LOCAL_COMMANDS_FILE" "local"
    fi

    echo -e "${BOLD}${YELLOW}Linting packs${NC}"
    local pf
    for pf in "$PACKS_DIR"/*.json; do
        [ -f "$pf" ] || continue
        _lint_store "$pf" "pack:$(basename "$pf" .json)"
    done

    if [ -f "$WORKFLOWS_FILE" ] && [ "$(jq 'length' "$WORKFLOWS_FILE" 2>/dev/null || echo 0)" -gt 0 ]; then
        echo -e "${BOLD}${YELLOW}Linting workflows${NC}"
        local eff; eff=$(get_effective_commands)
        local wf step_tag
        while IFS= read -r wf; do
            while IFS= read -r step_tag; do
                [ -z "$step_tag" ] && continue
                if ! printf '%s' "$eff" | jq -e --arg t "$step_tag" 'has($t) or any(.[]; (.aliases // []) | index($t))' >/dev/null 2>&1; then
                    echo -e "  ${RED}✗${NC} workflow '$wf': step references unknown command '$step_tag'"
                    LINT_TOTAL=$((LINT_TOTAL + 1))
                fi
            done < <(jq -r --arg w "$wf" '.[$w].steps[]? | (.run // empty), (.parallel[]?.run // empty)' "$WORKFLOWS_FILE" 2>/dev/null)
        done < <(jq -r 'keys[]' "$WORKFLOWS_FILE" 2>/dev/null)
    fi

    echo ""
    if [ "$LINT_TOTAL" -eq 0 ]; then
        echo -e "${GREEN}✓ No problems found.${NC}"; return 0
    fi
    echo -e "${RED}✗ $LINT_TOTAL problem(s) found.${NC}"; return 1
}

# ----------------------------------------------------------------------------
# Section 12d: Git-backed Sync
# Commit and push the data directory so command stores, hosts, findings, etc.
# can be versioned/shared across machines or operators.
# ----------------------------------------------------------------------------

# Refuse to operate on the CMDR source/install directory.
_sync_guard() {
    if [ -f "$DATA_DIR/cmdr.sh" ] && [ -f "$DATA_DIR/cmdr_functions.sh" ]; then
        echo -e "${RED}Error:${NC} Data dir looks like the CMDR install dir ($DATA_DIR)."
        echo -e "Set ${CYAN}CMDR_DATA_DIR${NC} to a separate directory to use sync."
        return 1
    fi
    return 0
}

sync_set_remote() {
    local url="$1"
    [ -z "$url" ] && { echo -e "${RED}Error:${NC} Usage: cmdr --sync-remote <git-url>"; exit 1; }
    _sync_guard || exit 1
    ( cd "$DATA_DIR" || exit 1
      [ -d .git ] || git init -q
      if git remote | grep -qx origin; then git remote set-url origin "$url"; else git remote add origin "$url"; fi )
    echo -e "${GREEN}Sync remote set:${NC} $url"
}

sync_data() {
    local msg="${1:-cmdr sync}"
    _sync_guard || exit 1
    if ! command -v git >/dev/null 2>&1; then echo -e "${RED}Error:${NC} git not installed."; exit 1; fi
    ( cd "$DATA_DIR" || exit 1
      [ -d .git ] || { git init -q; echo -e "${GREEN}Initialized git repo in $DATA_DIR${NC}"; }
      # Keep rebuildable caches and scratch files out of the synced history.
      for pat in '.cmdr_index.db' '**/.cmdr_index.db' '.cmdr.tmp.*' '**/.cmdr.tmp.*'; do
          grep -qxF "$pat" .gitignore 2>/dev/null || echo "$pat" >> .gitignore
      done
      git add -A
      if git diff --cached --quiet; then
          echo -e "${YELLOW}Nothing to sync.${NC}"
      else
          git commit -q -m "$msg"
          echo -e "${GREEN}Committed:${NC} $msg"
      fi
      if git remote | grep -qx origin; then
          local br; br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
          if git push -u origin "$br" 2>/dev/null; then
              echo -e "${GREEN}Pushed to origin/$br.${NC}"
          else
              echo -e "${YELLOW}Push failed (check remote/credentials).${NC}"
          fi
      else
          echo -e "${YELLOW}No 'origin' remote.${NC} Set one with 'cmdr --sync-remote <url>'."
      fi )
}

