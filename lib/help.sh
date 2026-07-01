#!/bin/bash
# ============================================================================
# CMDR :: lib/help.sh
# Help system
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

# ----------------------------------------------------------------------------
# Section 13: Help System
# Main help display and per-subcommand help pages.
# ----------------------------------------------------------------------------

# Per-subcommand help pages shown via `cmdr <flag> --help`.
display_subcommand_help() {
    case "$1" in
        add)
            echo "Usage: cmdr -a <tag> <command> [category] [--desc \"text\"] [--alias name]..."
            echo ""
            echo "Add a new command to the store."
            echo ""
            echo "  tag          Unique name (alphanumeric, hyphens, underscores)"
            echo "  command      Shell command to store (quote if it contains spaces)"
            echo "  category     Optional grouping (default: 'default')"
            echo "  --desc       Add a description"
            echo "  --alias      Add an alias (repeatable)"
            echo "  --local      Store in project-local .cmdr.json"
            echo ""
            echo "Examples:"
            echo "  cmdr -a serve 'python3 -m http.server 8080' dev"
            echo "  cmdr -a scan 'nmap {TARGET} -sV' security --desc 'Service scan' --alias s"
            echo "  cmdr --local -a build 'make -j4' dev"
            ;;
        edit)
            echo "Usage: cmdr -e <tag> [command] [category] [--desc \"text\"] [--alias name]..."
            echo ""
            echo "Edit an existing command. Omit command to be prompted."
            echo ""
            echo "  --desc       Update description"
            echo "  --alias      Set aliases (repeatable, replaces existing)"
            ;;
        delete)
            echo "Usage: cmdr -d <tag> [-y]"
            echo ""
            echo "Delete a command (prompts for confirmation)."
            echo ""
            echo "  -y    Skip confirmation prompt"
            ;;
        show)
            echo "Usage: cmdr -s"
            echo ""
            echo "Show all commands grouped by category."
            echo "Includes workspace and project-local commands."
            ;;
        run)
            echo "Usage: cmdr -r <tag|!|last> [arg1 arg2 ...] [@host] [options]"
            echo ""
            echo "Run a stored command. Extra args fill {placeholder} parameters."
            echo "Environment variables ({KEY}) are substituted first."
            echo "Placeholder forms: {VAR}, {VAR:=default}, {VAR:?} (required)."
            echo "Use '!' or 'last' to re-run the most recent command."
            echo ""
            echo "  --save           Save output to outputs/ directory"
            echo "  --capture VAR    Store stdout into env {VAR} (or VAR:regex)"
            echo "  @host            Fill {TARGET}/{RHOST}/{OS}/{RUSER}/{RPORT} from a host"
            echo "  --on <host>      Execute the command on <host> over SSH"
            echo "  --all-hosts      Run once per defined host"
            echo "  -n, --dry-run    Print command without executing"
            echo "  --               End of options: pass following tokens as literal args"
            echo ""
            echo "Examples:"
            echo "  cmdr -r scan 192.168.1.1"
            echo "  cmdr -r scan @dc01 --save"
            echo "  cmdr -r get-token --capture TOKEN:'eyJ[A-Za-z0-9._-]+'"
            echo "  cmdr -r linpeas --on dc01"
            echo "  cmdr -r nmap --all-hosts"
            echo "  cmdr -r last"
            ;;
        search)
            echo "Usage: cmdr -f <keyword>"
            echo ""
            echo "Search commands by tag, command, category, description, or alias."
            ;;
        extract)
            echo "Usage: cmdr -x <output_file>"
            echo ""
            echo "Export all commands to a JSON file."
            ;;
        logs)
            echo "Usage: cmdr -l <output_file>"
            echo ""
            echo "Export log file."
            ;;
        install)
            echo "Usage: cmdr -i <input_file>"
            echo ""
            echo "Import and merge commands from a JSON file."
            ;;
        import)
            echo "Usage: cmdr --import <source> [arg] [-y]"
            echo ""
            echo "Import commands from an external source. Shows a preview and asks"
            echo "for confirmation before writing (skip with -y). Duplicate tags are"
            echo "auto-uniquified, never overwritten. Honors --local and -n (dry-run)."
            echo ""
            echo "  history [N]   Most recent N unique shell-history commands (default 30)"
            echo "  tldr <page>   Example commands from a tldr page (needs the tldr client)"
            echo "  cheat <topic> Commands from cheat.sh/<topic> (needs curl + network)"
            echo "  file <path>   A JSON pack/array, or a plain-text list (one per line)"
            echo ""
            echo "Examples:"
            echo "  cmdr --import history 20"
            echo "  cmdr --import tldr nmap"
            echo "  cmdr --import file ~/snippets.txt -y"
            echo "  cmdr -n --import cheat tar    # preview only"
            ;;
        interactive)
            echo "Usage: cmdr -m"
            echo ""
            echo "Enter interactive mode to browse and run commands."
            ;;
        clipboard)
            echo "Usage: cmdr -c <tag> [arg1 arg2 ...]"
            echo ""
            echo "Copy the resolved command to clipboard instead of running it."
            echo "Supports env var and placeholder substitution."
            ;;
        workspace)
            echo "Usage: cmdr -w <name>     Switch workspace"
            echo "       cmdr -w            Show active workspace"
            echo "       cmdr -W            List all workspaces"
            echo ""
            echo "Workspaces isolate commands, env vars, notes, playbooks, and outputs."
            echo "Use 'default' to return to the default workspace."
            ;;
        env)
            echo "Usage: cmdr --env KEY=VALUE   Set a variable"
            echo "       cmdr --env             Show all variables"
            echo "       cmdr --env-clear KEY   Remove a variable"
            echo ""
            echo "Variables are per-workspace and substitute {KEY} in commands at runtime."
            ;;
        chain)
            echo "Usage: cmdr --chain <tag1> <tag2> [tag3 ...]"
            echo ""
            echo "Run multiple commands in sequence. Stops on first failure."
            ;;
        playbook)
            echo "Usage: cmdr --playbook <name> <tag1> <tag2> ...   Create a playbook"
            echo "       cmdr -p <name>                             Run a playbook"
            echo "       cmdr --playbooks                           List playbooks"
            echo ""
            echo "Playbooks are named sequences of command tags."
            ;;
        note)
            echo "Usage: cmdr --note <tag> \"text\"   Add a note"
            echo "       cmdr --notes [tag]          Show notes"
            echo ""
            echo "Attach timestamped findings or observations to commands."
            ;;
        pack)
            echo "Usage: cmdr --pack list           List available packs"
            echo "       cmdr --pack load <name>    Import a command pack"
            echo ""
            echo "Packs are pre-built command sets for CTF, development, etc."
            ;;
        host)
            echo "Usage: cmdr --host add <ip> --name <name> [--hostname h] [--os o] [--user u] [--port p]"
            echo "       cmdr --host list"
            echo "       cmdr --host rm <name>"
            echo ""
            echo "Hosts populate {TARGET}/{RHOST}/{RHOSTNAME}/{OS}/{RUSER}/{RPORT} when a"
            echo "command runs against them via '@name', '--on name', or '--all-hosts'."
            echo ""
            echo "Examples:"
            echo "  cmdr --host add 10.10.10.5 --name dc01 --os windows --user admin"
            echo "  cmdr -r winrm @dc01"
            echo "  cmdr -r nmap --all-hosts"
            ;;
        finding)
            echo "Usage: cmdr --finding <severity> <host> \"title\" [--evidence path]"
            echo "       cmdr --findings            List findings"
            echo "       cmdr --report [file] [--format md|csv|html|pdf]"
            echo ""
            echo "Severity: critical | high | medium | low | info   (use '-' for no host)"
            echo "Report format is inferred from the file extension, or set with --format."
            echo "html/pdf need pandoc; csv exports findings only."
            echo ""
            echo "Examples:"
            echo "  cmdr --finding high dc01 \"Unauth WinRM\" --evidence outputs/winrm_x.log"
            echo "  cmdr --report engagement.md"
            echo "  cmdr --report findings.csv"
            echo "  cmdr --report report.html"
            ;;
        flow)
            echo "Usage: cmdr --flow run <name|file.json>   Run a workflow"
            echo "       cmdr --flow import <file.json>     Store a workflow by its name"
            echo "       cmdr --flow list                   List stored workflows"
            echo "       cmdr --flow show <name|file>       Print a workflow"
            echo ""
            echo "A workflow is JSON: { \"name\": \"...\", \"steps\": [ <step>, ... ] }."
            echo "Step fields: run, args (incl @host), when, capture {VAR:regex},"
            echo "register, retry, timeout, remote, continue_on_error; or { parallel: [..] }."
            echo ""
            echo "Conditions: 'env:NAME == x', 'step:id.exit == 0', 'env:X contains y',"
            echo "'NAME matches re', 'env:X exists'; join with && or ||, negate with !."
            echo ""
            echo "  cmdr -n --flow run recon    # dry-run: show steps and decisions"
            ;;
        secret)
            echo "Usage: cmdr --secret NAME <provider>:<ref>   Register a secret"
            echo "       cmdr --secrets                         List secrets (no values)"
            echo "       cmdr --secret-clear NAME               Remove a secret"
            echo ""
            echo "Providers: pass:path | cmd:'shell' | env:VAR | age:file | file:path"
            echo ""
            echo "Reference a secret as {NAME} in any command. It is fetched only at"
            echo "execution time, so it never appears in the stored command, the run"
            echo "history, or the on-screen command line."
            echo ""
            echo "Examples:"
            echo "  cmdr --secret DBPASS pass:work/db"
            echo "  cmdr -a psql 'psql -h {TARGET} -U admin' db   # PGPASSWORD via {PGPASSWORD}"
            ;;
    esac
}

# Main help page with all available flags and examples.
display_help() {
    echo ""
    echo -e "${GREEN}   ██████╗███╗   ███╗██████╗ ██████╗ ${NC}"
    echo -e "${GREEN}  ██╔════╝████╗ ████║██╔══██╗██╔══██╗${NC}"
    echo -e "${GREEN}  ██║     ██╔████╔██║██║  ██║██████╔╝${NC}"
    echo -e "${GREEN}  ██║     ██║╚██╔╝██║██║  ██║██╔══██╗${NC}"
    echo -e "${GREEN}  ╚██████╗██║ ╚═╝ ██║██████╔╝██║  ██║${NC}"
    echo -e "${GREEN}   ╚═════╝╚═╝     ╚═╝╚═════╝ ╚═╝  ╚═╝${NC}"
    echo -e "  ${CYAN}Command Manager v${CMDR_VERSION}${NC}"
    echo ""
    echo -e "${YELLOW}Usage:${NC} cmdr [options]"
    echo ""
    echo -e "${YELLOW}Command Management:${NC}"
    echo "  -a <tag> <cmd> [cat] [--desc ..] [--alias ..] [--danger]  Add a command"
    echo "  -e <tag> [cmd] [cat] [--desc ..] [--alias ..] [--danger]  Edit a command"
    echo "  -d <tag> [-y]                                  Delete a command"
    echo "  -s                                             Show all commands"
    echo "  -r <tag|!|last> [args...] [@host] [opts]        Run a command"
    echo "  -f <keyword>                                   Search commands"
    echo "  -c <tag> [args...]                             Copy command to clipboard"
    echo "  --pick                                         Fuzzy-pick a command (fzf)"
    echo "  -I, --menu                                     Interactive tick-menu (fzf multi-select; bash fallback)"
    echo ""
    echo -e "${YELLOW}Run Options (with -r):${NC}"
    echo "  --save                 Save output to outputs/"
    echo "  --capture VAR[:regex]  Store stdout into env {VAR}"
    echo "  @host / --on <host>    Target a host (fill vars / run over SSH)"
    echo "  --all-hosts            Run once per defined host"
    echo ""
    echo -e "${YELLOW}Workspaces & Environment:${NC}"
    echo "  -w <name>              Switch workspace"
    echo "  -w                     Show active workspace"
    echo "  -W                     List all workspaces"
    echo "  --env KEY=VALUE        Set environment variable"
    echo "  --env                  Show environment variables"
    echo "  --env-clear KEY        Clear environment variable"
    echo "  --local                Use project-local .cmdr.json"
    echo "  --trust                Trust the current dir's .cmdr.json"
    echo "  --untrust              Revoke trust for the current dir's .cmdr.json"
    echo "  --lock-workspace [n]   Encrypt a named workspace at rest (age/gpg)"
    echo "  --unlock-workspace <n> Decrypt a locked workspace"
    echo ""
    echo -e "${YELLOW}Hosts:${NC}"
    echo "  --host add <ip> --name <n> [--os ..] [--user ..] [--port ..]"
    echo "  --host list            List hosts"
    echo "  --host rm <name>       Remove a host"
    echo ""
    echo -e "${YELLOW}Playbooks & Chains:${NC}"
    echo "  --chain <tags...>                  Run commands in sequence"
    echo "  --playbook <name> <tags...>        Create a playbook"
    echo "  -p <name>                          Run a playbook"
    echo "  --playbooks                        List playbooks"
    echo ""
    echo -e "${YELLOW}Notes, Findings & History:${NC}"
    echo "  --note <tag> \"text\"               Add a note"
    echo "  --notes [tag]                      Show notes"
    echo "  --outputs [tag]                    Show saved outputs"
    echo "  --finding <sev> <host> \"title\"     Record a finding"
    echo "  --findings                         List findings"
    echo "  --report [file] [--format fmt]     Report (md/csv/html/pdf)"
    echo "  --history [n]                      Show recent run history"
    echo ""
    echo -e "${YELLOW}Workflows & Secrets:${NC}"
    echo "  --flow run <name|file>             Run a conditional workflow"
    echo "  --flow import|list|show ...        Manage stored workflows"
    echo "  --secret NAME provider:ref         Register a runtime secret"
    echo "  --secrets / --secret-clear NAME    List / remove secrets"
    echo ""
    echo -e "${YELLOW}Maintenance:${NC}"
    echo "  --lint                             Validate stores, packs, workflows"
    echo "  --sync [msg] / --sync-remote <url> Git-version the data dir"
    echo ""
    echo -e "${YELLOW}Import/Export & Packs:${NC}"
    echo "  -x <file>              Export commands to JSON"
    echo "  -l <file>              Export logs"
    echo "  -i <file>              Import commands (merge)"
    echo "  --import <src> [arg]   Import from history/tldr/cheat/file"
    echo "  --pack list            List available packs"
    echo "  --pack load <name>     Load a command pack"
    echo ""
    echo -e "${YELLOW}General:${NC}"
    echo "  -m                     Interactive mode"
    echo "  -u, --undo             Undo last change"
    echo "  -n, --dry-run          Show command without running"
    echo "  -v                     Enable debug logging"
    echo "  -V, --version          Show version"
    echo "  -h, --help             Show this help"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  cmdr -a scan 'nmap {TARGET} -sV' security --desc 'Service scan'"
    echo "  cmdr --host add 10.10.10.5 --name dc01 --os windows"
    echo "  cmdr -r scan @dc01 --save"
    echo "  cmdr -r get-token --capture TOKEN && cmdr -r whoami-api"
    echo "  cmdr -r linpeas --on dc01"
    echo "  cmdr --finding high dc01 'Unauth WinRM' && cmdr --report report.md"
    echo "  cmdr -p recon   # cmdr -r last   # cmdr --history"
    echo ""
}
