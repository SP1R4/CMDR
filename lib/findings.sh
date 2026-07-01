#!/bin/bash
# ============================================================================
# CMDR :: lib/findings.sh
# Findings and reporting
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

# ----------------------------------------------------------------------------
# Section 8d: Findings & Reporting
# Structured findings (severity/host/title/evidence) and a markdown report
# that bundles hosts, findings, notes, and recent history.
# ----------------------------------------------------------------------------

# Record a finding. Severity must be critical/high/medium/low/info.
add_finding() {
    local severity="$1" host="$2" title="$3"
    if [ -z "$severity" ] || [ -z "$title" ]; then
        echo -e "${RED}Error:${NC} Usage: cmdr --finding <severity> <host> \"title\" [--evidence path]"
        echo -e "Severity: critical | high | medium | low | info  (use '-' for no host)"
        exit 1
    fi
    severity=$(echo "$severity" | tr '[:upper:]' '[:lower:]')
    case "$severity" in
        critical|high|medium|low|info) ;;
        *) echo -e "${RED}Error:${NC} Severity must be critical/high/medium/low/info."; exit 1 ;;
    esac
    [ "$host" = "-" ] && host=""

    [ ! -f "$FINDINGS_FILE" ] && echo "[]" > "$FINDINGS_FILE"
    local ts
    ts=$(date +"%Y-%m-%d %T")
    local tmp_file
    tmp_file=$(_mktemp_beside "$FINDINGS_FILE")
    jq --arg sev "$severity" --arg host "$host" --arg title "$title" \
       --arg ev "$CMDR_EVIDENCE" --arg ts "$ts" \
       '. + [{severity:$sev, host:$host, title:$title, evidence:$ev, timestamp:$ts}]' \
       "$FINDINGS_FILE" > "$tmp_file" && mv "$tmp_file" "$FINDINGS_FILE"

    log_event "INFO" "Finding added: [$severity] $title"
    echo -e "${GREEN}Finding recorded:${NC} [${severity}] $title"
}

# List findings, ordered by severity (critical first).
list_findings() {
    [ "${CMDR_JSON:-false}" = true ] && { json_findings; return 0; }
    if [ ! -f "$FINDINGS_FILE" ] || [ "$(jq 'length' "$FINDINGS_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}No findings.${NC}"
        return 0
    fi
    echo -e "${BOLD}${YELLOW}Findings:${NC}"
    if [ "$ACTIVE_WORKSPACE" != "default" ]; then
        echo -e "${CYAN}Workspace: $ACTIVE_WORKSPACE${NC}"
    fi
    echo ""
    jq -r '
        def rank: {"critical":0,"high":1,"medium":2,"low":3,"info":4}[.severity] // 5;
        sort_by(rank) | .[]
        | [.severity, (.host // ""), .title, (.evidence // ""), .timestamp] | join("\u001f")' "$FINDINGS_FILE" \
        | while IFS=$'\037' read -r sev host title ev ts; do
            local color="$CYAN"
            case "$sev" in
                critical|high) color="$RED" ;;
                medium) color="$YELLOW" ;;
                low|info) color="$GREEN" ;;
            esac
            printf "  ${color}%-9s${NC} %-14s %s\n" "[$sev]" "${host:-—}" "$title"
            [ -n "$ev" ] && printf "            ${CYAN}evidence:${NC} %s\n" "$ev"
        done
}

# Generate a markdown engagement report. Writes to $1 if given, else stdout.
generate_report() {
    local out="${1:-}"
    local ts
    ts=$(date +"%Y-%m-%d %T")

    _report_body() {
        echo "# Engagement Report — ${ACTIVE_WORKSPACE}"
        echo ""
        echo "_Generated: ${ts}_"
        echo ""

        echo "## Hosts"
        echo ""
        if [ -f "$HOSTS_FILE" ] && [ "$(jq 'length' "$HOSTS_FILE" 2>/dev/null || echo 0)" -gt 0 ]; then
            echo "| Name | IP | Hostname | OS | User |"
            echo "|------|----|----------|----|------|"
            jq -r 'to_entries[] | "| \(.key) | \(.value.ip // "") | \(.value.hostname // "") | \(.value.os // "") | \(.value.user // "") |"' "$HOSTS_FILE"
        else
            echo "_None recorded._"
        fi
        echo ""

        echo "## Findings"
        echo ""
        if [ -f "$FINDINGS_FILE" ] && [ "$(jq 'length' "$FINDINGS_FILE" 2>/dev/null || echo 0)" -gt 0 ]; then
            jq -r '
                def rank: {"critical":0,"high":1,"medium":2,"low":3,"info":4}[.severity] // 5;
                sort_by(rank) | .[]
                | "### [\(.severity | ascii_upcase)] \(.title)\n\n"
                  + "- Host: \(if (.host // "") == "" then "—" else .host end)\n"
                  + "- Time: \(.timestamp)\n"
                  + (if (.evidence // "") == "" then "" else "- Evidence: `\(.evidence)`\n" end)' "$FINDINGS_FILE"
        else
            echo "_None recorded._"
        fi
        echo ""

        echo "## Notes"
        echo ""
        if [ -f "$NOTES_FILE" ] && [ "$(jq 'length' "$NOTES_FILE" 2>/dev/null || echo 0)" -gt 0 ]; then
            jq -r 'to_entries[] | "### \(.key)\n\n" + (.value | map("- [\(.timestamp)] \(.note)") | join("\n")) + "\n"' "$NOTES_FILE"
        else
            echo "_None recorded._"
        fi
        echo ""

        echo "## Recent Command History"
        echo ""
        if [ -f "$HISTORY_FILE" ] && [ "$(jq 'length' "$HISTORY_FILE" 2>/dev/null || echo 0)" -gt 0 ]; then
            echo "| Time | Exit | Tag | Host | Command |"
            echo "|------|------|-----|------|---------|"
            jq -r '.[-30:] | reverse | .[] | "| \(.timestamp) | \(.exit) | \(.tag) | \(.host // "") | `\(.command)` |"' "$HISTORY_FILE"
        else
            echo "_None recorded._"
        fi
    }

    # CSV export of findings (machine-readable).
    _report_csv() {
        echo "severity,host,title,evidence,timestamp"
        [ -f "$FINDINGS_FILE" ] || return 0
        jq -r '
            def rank: {"critical":0,"high":1,"medium":2,"low":3,"info":4}[.severity] // 5;
            sort_by(rank) | .[]
            | [.severity, (.host // ""), .title, (.evidence // ""), .timestamp] | @csv' "$FINDINGS_FILE"
    }

    # Decide format: explicit --format wins, else infer from the file extension.
    local fmt="$CMDR_REPORT_FORMAT"
    if [ -z "$fmt" ] && [ -n "$out" ]; then
        case "$out" in
            *.csv)  fmt="csv" ;;
            *.html|*.htm) fmt="html" ;;
            *.pdf)  fmt="pdf" ;;
            *)      fmt="md" ;;
        esac
    fi
    [ -z "$fmt" ] && fmt="md"

    case "$fmt" in
        csv)
            if [ -n "$out" ]; then _report_csv > "$out"; echo -e "${GREEN}CSV findings written to:${NC} $out"
            else _report_csv; fi
            ;;
        html|pdf)
            if ! command -v pandoc >/dev/null 2>&1; then
                echo -e "${RED}Error:${NC} '$fmt' output needs pandoc (https://pandoc.org)."; exit 1
            fi
            [ -z "$out" ] && { echo -e "${RED}Error:${NC} $fmt output requires a file path."; exit 1; }
            if _report_body | pandoc -f markdown -t "$fmt" -s -o "$out" 2>/dev/null; then
                echo -e "${GREEN}Report (${fmt}) written to:${NC} $out"
            else
                echo -e "${RED}Error:${NC} pandoc failed to render $fmt (PDF needs a LaTeX engine)."; exit 1
            fi
            ;;
        *)
            if [ -n "$out" ]; then
                _report_body > "$out"
                log_event "INFO" "Report written to $out"
                echo -e "${GREEN}Report written to:${NC} $out"
            else
                _report_body
            fi
            ;;
    esac
}

