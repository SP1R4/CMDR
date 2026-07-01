#!/usr/bin/env bats
# ============================================================================
# CMDR bats suite — structured, isolated tests using bats-core.
#
#   Install:  brew install bats-core   |   npm i -g bats   |   apt install bats
#   Run:      bats tests/cmdr.bats
#
# tests/run.sh remains the exhaustive, dependency-free suite that CI runs; this
# file is a focused, readable bats layer for TDD on the newer features. Each
# test gets a fresh CMDR_DATA_DIR so nothing leaks between cases.
# ============================================================================

setup() {
    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    C="$ROOT/cmdr.sh"
    CMDR_DATA_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/cmdrbats.XXXXXX")"
    export CMDR_DATA_DIR
}

teardown() {
    [ -n "$CMDR_DATA_DIR" ] && rm -rf "$CMDR_DATA_DIR"
}

@test "add then show lists the command" {
    run "$C" -a serve 'echo hi' dev --desc 'quick'
    [ "$status" -eq 0 ]
    run "$C" -s
    [ "$status" -eq 0 ]
    [[ "$output" == *serve* ]]
}

@test "--json produces valid JSON for show" {
    "$C" -a nmap-sv 'nmap {T} -sV' net >/dev/null
    run bash -c "'$C' -s --json | jq -e '.\"nmap-sv\".command'"
    [ "$status" -eq 0 ]
}

@test "search --json filters to matching commands only" {
    "$C" -a nmap-sv 'nmap {T} -sV' net --alias scan >/dev/null
    "$C" -a serve 'echo hi' dev >/dev/null
    run bash -c "'$C' -f scan --json | jq -e 'has(\"nmap-sv\") and (has(\"serve\")|not)'"
    [ "$status" -eq 0 ]
}

@test "import file adds commands and uniquifies duplicate tags" {
    "$C" -a serve 'echo existing' dev >/dev/null
    printf '%s\n' 'nmap -sV 10.0.0.1' 'serve --foo' > "$CMDR_DATA_DIR/snips.txt"
    run "$C" --import file "$CMDR_DATA_DIR/snips.txt" -y
    [ "$status" -eq 0 ]
    run bash -c "'$C' -s --json | jq -e 'has(\"nmap\") and has(\"serve-2\")'"
    [ "$status" -eq 0 ]
}

@test "import dry-run writes nothing" {
    printf '%s\n' 'echo hi' > "$CMDR_DATA_DIR/snips.txt"
    "$C" -n --import file "$CMDR_DATA_DIR/snips.txt" >/dev/null
    run bash -c "'$C' -s --json | jq -e 'length == 0'"
    [ "$status" -eq 0 ]
}

@test "import rejects an unknown source" {
    run "$C" --import bogus
    [ "$status" -ne 0 ]
}

@test "search index matches the jq path (when sqlite3 is present)" {
    if ! command -v sqlite3 >/dev/null 2>&1; then skip "sqlite3 not installed"; fi
    "$C" -a a1 'nmap {T} -sV' net --alias s1 >/dev/null
    "$C" -a b1 'gobuster dir -u {U}' web >/dev/null
    for kw in nmap web zzz s1; do
        a="$(CMDR_INDEX=0 "$C" -f "$kw" 2>&1)"
        b="$(CMDR_INDEX=1 "$C" -f "$kw" 2>&1)"
        [ "$a" = "$b" ]
    done
}

@test "concurrent runs all record history (run-path lock)" {
    "$C" -a t1 'true' x >/dev/null
    for i in 1 2 3 4 5 6; do ( "$C" -r t1 >/dev/null 2>&1 ) & done
    wait
    run bash -c "jq 'length' '$CMDR_DATA_DIR/.cmdr_history.json'"
    [ "$output" = "6" ]
}
