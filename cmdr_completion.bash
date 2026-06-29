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
    local hosts_file="${active_data_dir:+$active_data_dir/}.cmdr_hosts.json"
    local workflows_file="${active_data_dir:+$active_data_dir/}.cmdr_workflows.json"
    local secrets_file="${active_data_dir:+$active_data_dir/}.cmdr_secrets.json"
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

    # Helper: complete with host names
    _cmdr_complete_hosts() {
        if [ -f "$hosts_file" ]; then
            local hosts
            hosts=$(jq -r 'keys[]' "$hosts_file" 2>/dev/null)
            COMPREPLY=( $(compgen -W "$hosts" -- "$cur") )
        fi
    }

    # @host targeting: complete host names with the @ prefix preserved.
    if [[ "$cur" == @* ]] && [ -f "$hosts_file" ]; then
        local hn
        hn=$(jq -r 'keys[]' "$hosts_file" 2>/dev/null)
        COMPREPLY=( $(compgen -P @ -W "$hn" -- "${cur#@}") )
        return
    fi

    case "$prev" in
        -r|-d|-e|-c)
            _cmdr_complete_tags
            return ;;
        --on|rm|del)
            _cmdr_complete_hosts
            return ;;
        --host)
            COMPREPLY=( $(compgen -W "add list rm" -- "$cur") )
            return ;;
        --flow)
            COMPREPLY=( $(compgen -W "run list import show" -- "$cur") )
            return ;;
        run|show)
            # After `--flow run|show`, complete stored workflow names
            if [ -f "$workflows_file" ]; then
                local wfn
                wfn=$(jq -r 'keys[]' "$workflows_file" 2>/dev/null)
                COMPREPLY=( $(compgen -W "$wfn" -- "$cur") )
            fi
            return ;;
        import)
            COMPREPLY=( $(compgen -f -- "$cur") )
            return ;;
        --secret-clear)
            if [ -f "$secrets_file" ]; then
                local sn
                sn=$(jq -r 'keys[]' "$secrets_file" 2>/dev/null)
                COMPREPLY=( $(compgen -W "$sn" -- "$cur") )
            fi
            return ;;
        --format)
            COMPREPLY=( $(compgen -W "md csv html pdf" -- "$cur") )
            return ;;
        --sync-remote|--secret|--secrets|--lint|--sync)
            return ;;
        --unlock-workspace)
            # Complete with locked (encrypted) workspace names
            if [ -d "$data_dir/workspaces" ]; then
                local locked
                locked=$(ls "$data_dir/workspaces"/*.cmdrlock 2>/dev/null | xargs -I{} basename {} .cmdrlock)
                COMPREPLY=( $(compgen -W "$locked" -- "$cur") )
            fi
            return ;;
        --lock-workspace)
            local wsnames=""
            [ -d "$data_dir/workspaces" ] && wsnames=$(find "$data_dir/workspaces" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null)
            COMPREPLY=( $(compgen -W "$wsnames" -- "$cur") )
            return ;;
        --capture|--evidence|--name|--hostname|--os|--user|--port)
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
            --trust --untrust --pick --danger
            --capture --on --all-hosts
            --desc --alias --env --env-clear
            --chain --playbook --playbooks
            --note --notes --outputs --pack
            --host --finding --findings --report --format --history
            --lock-workspace --unlock-workspace
            --flow --secret --secrets --secret-clear --lint --sync --sync-remote
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
