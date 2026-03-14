#!/bin/bash
# ============================================================================
# CMDR v3.0 - Tab Completion for Bash and Zsh (via bashcompinit)
# ============================================================================
# Provides context-aware completions for all CMDR flags, tags, aliases,
# categories, workspaces, playbooks, packs, and file paths.
# ============================================================================

_cmdr_completions() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Locate the data directory and commands file
    local data_dir="${CMDR_DATA_DIR:-}"
    if [ -z "$data_dir" ]; then
        local cmdr_path
        cmdr_path=$(command -v cmdr 2>/dev/null || true)
        if [ -n "$cmdr_path" ]; then
            cmdr_path=$(readlink -f "$cmdr_path" 2>/dev/null || echo "$cmdr_path")
            data_dir=$(dirname "$cmdr_path")
        fi
    fi

    # Resolve active workspace
    local active_data_dir="$data_dir"
    if [ -f "$data_dir/.cmdr_active_workspace" ]; then
        local ws
        ws=$(cat "$data_dir/.cmdr_active_workspace" 2>/dev/null)
        if [ -n "$ws" ] && [ "$ws" != "default" ] && [ -d "$data_dir/workspaces/$ws" ]; then
            active_data_dir="$data_dir/workspaces/$ws"
        fi
    fi

    local commands_file="${active_data_dir:+$active_data_dir/}my_commands.json"
    local playbooks_file="${active_data_dir:+$active_data_dir/}.cmdr_playbooks.json"
    local packs_dir="${data_dir:+$data_dir/}packs"

    # Helper: complete with tag names and aliases
    _cmdr_complete_tags() {
        if [ -f "$commands_file" ]; then
            local tags aliases
            tags=$(jq -r 'keys[]' "$commands_file" 2>/dev/null)
            aliases=$(jq -r '[.[] | .aliases // [] | .[]] | .[]' "$commands_file" 2>/dev/null)
            COMPREPLY=( $(compgen -W "$tags $aliases" -- "$cur") )
        fi
    }

    case "$prev" in
        -r|-d|-e|-c)
            _cmdr_complete_tags
            return ;;
        -f)
            # Complete with categories
            if [ -f "$commands_file" ]; then
                local categories
                categories=$(jq -r '[.[] | .category] | unique | .[]' "$commands_file" 2>/dev/null)
                COMPREPLY=( $(compgen -W "$categories" -- "$cur") )
            fi
            return ;;
        -x|-l|-i)
            COMPREPLY=( $(compgen -f -- "$cur") )
            return ;;
        -w|--workspace)
            # Complete with workspace names
            local workspaces="default"
            if [ -d "$data_dir/workspaces" ]; then
                workspaces="$workspaces $(ls "$data_dir/workspaces" 2>/dev/null)"
            fi
            COMPREPLY=( $(compgen -W "$workspaces" -- "$cur") )
            return ;;
        -p)
            # Complete with playbook names
            if [ -f "$playbooks_file" ]; then
                local names
                names=$(jq -r 'keys[]' "$playbooks_file" 2>/dev/null)
                COMPREPLY=( $(compgen -W "$names" -- "$cur") )
            fi
            return ;;
        --note|--notes)
            _cmdr_complete_tags
            return ;;
        --outputs)
            _cmdr_complete_tags
            return ;;
        --desc|--alias|--env|--env-clear)
            return ;;
        load)
            # After `--pack load`, complete with pack names
            if [ -d "$packs_dir" ]; then
                local packs
                packs=$(ls "$packs_dir"/*.json 2>/dev/null | xargs -I{} basename {} .json)
                COMPREPLY=( $(compgen -W "$packs" -- "$cur") )
            fi
            return ;;
        --pack)
            COMPREPLY=( $(compgen -W "list load" -- "$cur") )
            return ;;
    esac

    # Top-level flag completion
    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "
            -a -e -d -s -r -f -c -x -l -i -m -p
            -w -W -u -n -v -V -h
            --help --version --undo --dry-run --local --save
            --desc --alias --env --env-clear
            --chain --playbook --playbooks
            --note --notes --outputs --pack
        " -- "$cur") )
        return
    fi

    # Context-aware: if a tag-accepting flag appeared earlier, complete tags
    local i
    for (( i=1; i < COMP_CWORD; i++ )); do
        case "${COMP_WORDS[$i]}" in
            -r|-d|-e|-c|--chain)
                _cmdr_complete_tags
                return ;;
            --playbook)
                # After name, complete tags for the steps
                if [ "$((i + 1))" -lt "$COMP_CWORD" ]; then
                    _cmdr_complete_tags
                fi
                return ;;
        esac
    done
}

complete -F _cmdr_completions cmdr

# Zsh support via bashcompinit
if [ -n "$ZSH_VERSION" ]; then
    autoload -Uz bashcompinit && bashcompinit
    complete -F _cmdr_completions cmdr
fi
