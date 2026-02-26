#!/bin/bash
# CMDR v2.1 - Tab completion for Bash and Zsh (via bashcompinit)

_cmdr_completions() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Locate the commands file
    local data_dir="${CMDR_DATA_DIR:-}"
    if [ -z "$data_dir" ]; then
        local cmdr_path
        cmdr_path=$(command -v cmdr 2>/dev/null || true)
        if [ -n "$cmdr_path" ]; then
            cmdr_path=$(readlink -f "$cmdr_path" 2>/dev/null || echo "$cmdr_path")
            data_dir=$(dirname "$cmdr_path")
        fi
    fi
    local commands_file="${data_dir:+$data_dir/}my_commands.json"

    case "$prev" in
        -r|-d|-e)
            # Complete with tag names and aliases
            if [ -f "$commands_file" ]; then
                local tags aliases
                tags=$(jq -r 'keys[]' "$commands_file" 2>/dev/null)
                aliases=$(jq -r '[.[] | .aliases // [] | .[]] | .[]' "$commands_file" 2>/dev/null)
                COMPREPLY=( $(compgen -W "$tags $aliases" -- "$cur") )
            fi
            return
            ;;
        -f)
            # Complete with categories
            if [ -f "$commands_file" ]; then
                local categories
                categories=$(jq -r '[.[] | .category] | unique | .[]' "$commands_file" 2>/dev/null)
                COMPREPLY=( $(compgen -W "$categories" -- "$cur") )
            fi
            return
            ;;
        -x|-l|-i)
            # Complete with file paths
            COMPREPLY=( $(compgen -f -- "$cur") )
            return
            ;;
        --desc|--alias)
            # No completion for these values
            return
            ;;
    esac

    # Top-level flag completion
    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-a -e -d -s -r -f -x -l -i -m -h -v -V -u -n --help --version --undo --dry-run --desc --alias" -- "$cur") )
        return
    fi

    # If previous flags indicate a tag context, complete tags
    local i
    for (( i=1; i < COMP_CWORD; i++ )); do
        case "${COMP_WORDS[$i]}" in
            -r|-d|-e)
                # Already past the tag position, offer file completion as fallback
                if [ "$((i + 1))" -lt "$COMP_CWORD" ]; then
                    COMPREPLY=( $(compgen -f -- "$cur") )
                else
                    if [ -f "$commands_file" ]; then
                        local tags aliases
                        tags=$(jq -r 'keys[]' "$commands_file" 2>/dev/null)
                        aliases=$(jq -r '[.[] | .aliases // [] | .[]] | .[]' "$commands_file" 2>/dev/null)
                        COMPREPLY=( $(compgen -W "$tags $aliases" -- "$cur") )
                    fi
                fi
                return
                ;;
        esac
    done
}

complete -F _cmdr_completions cmdr

# Zsh support via bashcompinit
if [ -n "$ZSH_VERSION" ]; then
    autoload -Uz bashcompinit && bashcompinit
    complete -F _cmdr_completions cmdr
fi
