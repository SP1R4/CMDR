#!/bin/bash
# ============================================================================
# CMDR :: lib/menu.sh
# Fuzzy picker and interactive tick-menu
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

# ----------------------------------------------------------------------------
# Section 8e: Fuzzy Picker
# fzf-driven command selector. Falls back to interactive mode without fzf.
# ----------------------------------------------------------------------------

pick_command() {
    if ! command -v fzf >/dev/null 2>&1; then
        echo -e "${YELLOW}fzf not found.${NC} Falling back to interactive mode."
        interactive_mode
        return $?
    fi

    notify_untrusted_local
    local effective
    effective=$(get_effective_commands)

    if [ "$(echo "$effective" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}No commands available.${NC}"
        return 0
    fi

    # Stage the data the preview pane needs into a temp dir and generate a
    # self-contained preview script. fzf runs the script per highlighted row
    # (passing the tag as {1}); doing it via a script keeps us from re-sourcing
    # all of CMDR on every keystroke.
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/cmdrpick.XXXXXX")
    printf '%s' "$effective" > "$tmpdir/cmds.json"
    { [ -f "$NOTES_FILE" ] && cat "$NOTES_FILE"; } 2>/dev/null > "$tmpdir/notes.json" || true
    [ -s "$tmpdir/notes.json" ] || echo '{}' > "$tmpdir/notes.json"
    { [ -f "$HISTORY_FILE" ] && cat "$HISTORY_FILE"; } 2>/dev/null > "$tmpdir/hist.json" || true
    [ -s "$tmpdir/hist.json" ] || echo '[]' > "$tmpdir/hist.json"

    cat > "$tmpdir/preview.sh" <<'PREV'
#!/bin/bash
d="$1"; tag="$2"
C='\033[0;36m'; Y='\033[0;33m'; G='\033[0;32m'; R='\033[0;31m'; B='\033[1m'; N='\033[0m'
[ -z "$tag" ] && exit 0
cmd=$(jq -r --arg t "$tag" '.[$t].command // ""' "$d/cmds.json")
cat=$(jq -r --arg t "$tag" '.[$t].category // ""' "$d/cmds.json")
desc=$(jq -r --arg t "$tag" '.[$t].description // ""' "$d/cmds.json")
al=$(jq -r --arg t "$tag" '(.[$t].aliases // []) | join(", ")' "$d/cmds.json")
danger=$(jq -r --arg t "$tag" '.[$t].danger // false' "$d/cmds.json")
printf "${B}${C}%s${N}" "$tag"
[ "$danger" = "true" ] && printf "  ${R}${B}[DANGER]${N}"
printf "\n"
[ -n "$cat" ]  && printf "${Y}category:${N} %s\n" "$cat"
[ -n "$al" ]   && printf "${Y}aliases:${N}  %s\n" "$al"
[ -n "$desc" ] && printf "${Y}desc:${N}     %s\n" "$desc"
printf "\n${G}%s${N}\n" "$cmd"
ph=$(printf '%s\n' "$cmd" | grep -oE '\{[a-zA-Z_][a-zA-Z0-9_]*(:[-=?][^}]*)?\}' | sort -u | tr '\n' ' ')
[ -n "$ph" ] && printf "\n${Y}placeholders:${N} %s\n" "$ph"
notes=$(jq -r --arg t "$tag" '(.[$t] // []) | length' "$d/notes.json" 2>/dev/null)
if [ -n "$notes" ] && [ "$notes" -gt 0 ] 2>/dev/null; then
    printf "\n${Y}notes (%s):${N}\n" "$notes"
    jq -r --arg t "$tag" '(.[$t] // [])[] | "  - \(.text // .)"' "$d/notes.json" 2>/dev/null | head -5
fi
last=$(jq -r --arg t "$tag" '[.[] | select(.tag==$t)] | last | if .==null then "" else "\(.timestamp)  exit \(.exit)  \(.duration)" end' "$d/hist.json" 2>/dev/null)
[ -n "$last" ] && printf "\n${Y}last run:${N} %s\n" "$last"
PREV
    chmod +x "$tmpdir/preview.sh"

    local out key sel tag
    out=$(echo "$effective" \
        | jq -r 'to_entries[] | "\(.key)\t\(.value.category // "")\t\(.value.command)\t\(.value.description // "")"' \
        | fzf --delimiter='\t' --with-nth=1,2,4 \
              --preview "bash '$tmpdir/preview.sh' '$tmpdir' {1}" \
              --preview-window='right,55%,wrap' \
              --prompt='cmdr> ' --height=80% --ansi \
              --header='enter: run   ctrl-n: dry-run   ctrl-y: copy   ctrl-/: toggle preview' \
              --bind='ctrl-/:toggle-preview' \
              --expect=ctrl-n,ctrl-y)
    rm -rf "$tmpdir"

    key=$(printf '%s\n' "$out" | sed -n '1p')
    sel=$(printf '%s\n' "$out" | sed -n '2p')
    [ -z "$sel" ] && return 0
    tag=$(printf '%s' "$sel" | cut -f1)
    [ -z "$tag" ] && return 0

    case "$key" in
        ctrl-n) DRY_RUN=true run_command "$tag" ;;
        ctrl-y) clipboard_copy "$tag" ;;
        *)      run_command "$tag" ;;
    esac
}

# ----------------------------------------------------------------------------
# Section 8e: Interactive Menu (optional, tick-based)
# An opt-in TUI (cmdr -I / --menu) that lets you tick options instead of typing
# flags. Uses fzf multi-select when available, with a zero-dependency pure-bash
# checklist fallback. UI goes to stderr / the tty; selected keys to stdout.
# ----------------------------------------------------------------------------

# Read one keypress from the tty; echo a normalized token. Handles arrow keys
# (and vim h/j/k/l), ENTER, SPACE, 'a', 'q'. bash 3.2 safe: arrow escape bytes
# arrive together, so the integer -t 1 read returns immediately.
_imenu_read_key() {
    local k rest
    IFS= read -rsn1 k </dev/tty 2>/dev/null || { printf 'quit'; return; }
    case "$k" in
        $'\x1b')
            IFS= read -rsn2 -t 1 rest </dev/tty 2>/dev/null
            case "$rest" in
                '[A'|'OA') printf 'up' ;;
                '[B'|'OB') printf 'down' ;;
                *)         printf 'esc' ;;
            esac ;;
        ''|$'\n'|$'\r') printf 'enter' ;;
        ' ')            printf 'space' ;;
        k|K)            printf 'up' ;;
        j|J)            printf 'down' ;;
        a|A)            printf 'all' ;;
        q|Q)            printf 'quit' ;;
        *)              printf 'other' ;;
    esac
}

# Terminal size from the controlling tty (works even when stdout is captured,
# unlike `tput` which queries stdout). Echoes "rows" or "cols".
_imenu_rows() {
    local s; s=$(stty size </dev/tty 2>/dev/null); s="${s%% *}"
    case "$s" in ''|*[!0-9]*) echo 24 ;; *) echo "$s" ;; esac
}
_imenu_cols() {
    local s; s=$(stty size </dev/tty 2>/dev/null); s="${s##* }"
    case "$s" in ''|*[!0-9]*) echo 80 ;; *) echo "$s" ;; esac
}

# Rows of the list to show at once (terminal height minus chrome).
_imenu_vh() {
    local n="$1" lines vh
    lines=$(_imenu_rows)
    vh=$(( lines > 8 ? lines - 6 : lines ))
    [ "$vh" -lt 1 ] && vh=1
    [ "$vh" -gt "$n" ] && vh="$n"
    printf '%s' "$vh"
}

# Pure-bash single-select with arrow navigation + scrolling viewport.
# Reads "key<TAB>label" lines on stdin; echoes the chosen key.
_imenu_bash_one() {
    local prompt="$1" k l; local keys=() labels=()
    while IFS=$'\t' read -r k l; do keys+=("$k"); labels+=("$l"); done
    local n=${#keys[@]}; [ "$n" -eq 0 ] && return 0
    local vh; vh=$(_imenu_vh "$n")
    local cur=0 top=0 drawn=0 key row idx disp
    local maxw=$(( $(_imenu_cols) - 4 )); [ "$maxw" -lt 12 ] && maxw=12
    printf '\n%s  \033[2m(\xe2\x86\x91/\xe2\x86\x93 move \xc2\xb7 ENTER select \xc2\xb7 q cancel)\033[0m\n' "$prompt" >&2
    while true; do
        [ "$cur" -lt "$top" ] && top=$cur
        [ "$cur" -ge "$((top + vh))" ] && top=$((cur - vh + 1))
        [ "$drawn" -eq 1 ] && printf '\033[%dA' "$((vh + 1))" >&2
        for ((row=0; row<vh; row++)); do
            idx=$((top + row))
            if [ "$idx" -lt "$n" ]; then
                disp="${labels[$idx]}"; [ "${#disp}" -gt "$maxw" ] && disp="${disp:0:maxw}"
                if [ "$idx" -eq "$cur" ]; then printf '\033[2K\033[36m> %s\033[0m\n' "$disp" >&2
                else printf '\033[2K  %s\n' "$disp" >&2; fi
            else printf '\033[2K\n' >&2; fi
        done
        printf '\033[2K  \033[2m[%d/%d]\033[0m\n' "$((cur + 1))" "$n" >&2
        drawn=1
        key=$(_imenu_read_key)
        case "$key" in
            up)    cur=$(( (cur - 1 + n) % n )) ;;
            down)  cur=$(( (cur + 1) % n )) ;;
            enter) printf '%s\n' "${keys[$cur]}"; return 0 ;;
            quit)  return 0 ;;
        esac
    done
}

# Pure-bash multi-select checklist with arrow navigation + scrolling viewport.
# Reads "key<TAB>label"; echoes the ticked keys.
_imenu_bash_many() {
    local prompt="$1" k l; local keys=() labels=() mark=()
    while IFS=$'\t' read -r k l; do keys+=("$k"); labels+=("$l"); mark+=(0); done
    local n=${#keys[@]}; [ "$n" -eq 0 ] && return 0
    local vh; vh=$(_imenu_vh "$n")
    local cur=0 top=0 drawn=0 key i row idx allv ptr box disp
    local maxw=$(( $(_imenu_cols) - 8 )); [ "$maxw" -lt 12 ] && maxw=12
    printf '\n%s  \033[2m(\xe2\x86\x91/\xe2\x86\x93 move \xc2\xb7 SPACE tick \xc2\xb7 a all \xc2\xb7 ENTER confirm \xc2\xb7 q cancel)\033[0m\n' "$prompt" >&2
    while true; do
        [ "$cur" -lt "$top" ] && top=$cur
        [ "$cur" -ge "$((top + vh))" ] && top=$((cur - vh + 1))
        [ "$drawn" -eq 1 ] && printf '\033[%dA' "$((vh + 1))" >&2
        for ((row=0; row<vh; row++)); do
            idx=$((top + row))
            if [ "$idx" -lt "$n" ]; then
                ptr="  "; box="[ ]"
                [ "$idx" -eq "$cur" ] && ptr=$'\033[36m> \033[0m'
                [ "${mark[$idx]}" -eq 1 ] && box=$'\033[32m[x]\033[0m'
                disp="${labels[$idx]}"; [ "${#disp}" -gt "$maxw" ] && disp="${disp:0:maxw}"
                printf '\033[2K%b%b %s\n' "$ptr" "$box" "$disp" >&2
            else printf '\033[2K\n' >&2; fi
        done
        printf '\033[2K  \033[2m[%d/%d]\033[0m\n' "$((cur + 1))" "$n" >&2
        drawn=1
        key=$(_imenu_read_key)
        case "$key" in
            up)    cur=$(( (cur - 1 + n) % n )) ;;
            down)  cur=$(( (cur + 1) % n )) ;;
            space) if [ "${mark[$cur]}" -eq 1 ]; then mark[$cur]=0; else mark[$cur]=1; fi ;;
            all)   allv=1; for ((i=0; i<n; i++)); do [ "${mark[$i]}" -eq 1 ] && allv=0; done
                   for ((i=0; i<n; i++)); do mark[$i]=$allv; done ;;
            enter) break ;;
            quit)  return 0 ;;
        esac
    done
    for ((i=0; i<n; i++)); do [ "${mark[$i]}" -eq 1 ] && printf '%s\n' "${keys[$i]}"; done
}

# Select wrappers: fzf when present, pure-bash otherwise.
_imenu_one()  {
    if command -v fzf >/dev/null 2>&1; then
        fzf --delimiter='\t' --with-nth=2.. --prompt="$1 > " --height=60% --reverse | cut -f1
    else
        _imenu_bash_one "$1"
    fi
}
_imenu_many() {
    if command -v fzf >/dev/null 2>&1; then
        fzf --multi --delimiter='\t' --with-nth=2.. --prompt="$1 (TAB=tick) > " \
            --height=70% --reverse --header='TAB tick · ENTER confirm · ESC cancel' | cut -f1
    else
        _imenu_bash_many "$1"
    fi
}

# Tick commands, then run / dry-run / copy each ticked one (placeholders are
# filled by the normal run path, which prompts and pre-fills from env).
_imenu_run() {
    local effective; effective=$(get_effective_commands)
    if [ "$(echo "$effective" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}No commands available.${NC}" >&2; return 0
    fi
    local tags
    tags=$(echo "$effective" \
        | jq -r 'to_entries[] | "\(.key)\t[\(.value.category)] \(.key) - \(.value.description // .value.command)"' \
        | _imenu_many "Tick commands")
    [ -z "$tags" ] && return 0
    local mode
    mode=$(printf '%s\n' $'run\tRun the ticked commands' $'dry\tDry-run (preview only)' $'copy\tCopy to clipboard' \
        | _imenu_one "Action")
    [ -z "$mode" ] && mode="run"
    # Collect ticked tags into an array FIRST. Running inside a `while ... <<<`
    # loop would redirect stdin to the tag list, so run_command's interactive
    # prompts (placeholders, danger confirms) would read the wrong input / hang.
    # A plain for-loop leaves stdin pointing at the terminal.
    local t; local tarr=()
    while IFS= read -r t; do [ -n "$t" ] && tarr+=("$t"); done <<< "$tags"
    local _odr="$DRY_RUN"
    for t in "${tarr[@]}"; do
        echo -e "\n${CYAN}▶ $t${NC}" >&2
        case "$mode" in
            dry)  DRY_RUN=true; run_command "$t"; DRY_RUN="$_odr" ;;
            copy) clipboard_copy "$t" ;;
            *)    run_command "$t" ;;
        esac
    done
}

# Tick packs, load each ticked one.
_imenu_packs() {
    local list
    list=$( for f in "$PACKS_DIR"/*.json; do
                [ -f "$f" ] || continue
                local b c; b=$(basename "$f" .json); c=$(jq 'length' "$f" 2>/dev/null || echo 0)
                printf '%s\t%s (%s commands)\n' "$b" "$b" "$c"
            done | _imenu_many "Tick packs to load" )
    [ -z "$list" ] && return 0
    local p; local parr=()
    while IFS= read -r p; do [ -n "$p" ] && parr+=("$p"); done <<< "$list"
    for p in "${parr[@]}"; do load_pack "$p"; done
}

# Prompt for an env var name + value.
_imenu_env() {
    local k v
    printf "Variable name: " >&2; read -r k </dev/tty || return 0
    [ -z "$k" ] && return 0
    printf "Value for %s: " "$k" >&2; read -r v </dev/tty || return 0
    set_env_var "$k=$v"
}

# Pick a workspace to switch to (default + any under workspaces/).
_imenu_workspace() {
    local ws
    ws=$( {
            printf '%s\t%s\n' default "default"
            if [ -d "$DATA_DIR/workspaces" ]; then
                for d in "$DATA_DIR/workspaces"/*/; do
                    [ -d "$d" ] || continue
                    local n; n=$(basename "$d"); printf '%s\t%s\n' "$n" "$n"
                done
            fi
          } | _imenu_one "Switch workspace" )
    [ -n "$ws" ] && switch_workspace "$ws"
}

# Top-level hub. Optional: only runs with a real terminal on stdin.
interactive_menu() {
    if [ ! -t 0 ]; then
        echo -e "${YELLOW}The interactive menu (cmdr -I) needs a terminal.${NC}" >&2
        return 0
    fi
    notify_untrusted_local
    log_event "INFO" "Entered interactive menu"
    echo -e "${BOLD}${YELLOW}CMDR — interactive menu${NC}" >&2
    [ "$ACTIVE_WORKSPACE" != "default" ] && echo -e "${CYAN}Workspace: $ACTIVE_WORKSPACE${NC}" >&2
    while true; do
        local action
        action=$(printf '%s\n' \
            $'run\tRun commands (tick one or more)' \
            $'pack\tLoad command packs' \
            $'env\tSet an environment variable' \
            $'ws\tSwitch workspace' \
            $'show\tShow all commands' \
            $'quit\tQuit' | _imenu_one "CMDR menu")
        case "$action" in
            run)  _imenu_run ;;
            pack) _imenu_packs ;;
            env)  _imenu_env ;;
            ws)   _imenu_workspace ;;
            show) show_commands ;;
            quit|"") echo -e "${GREEN}Bye.${NC}" >&2; return 0 ;;
        esac
    done
}

