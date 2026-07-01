#!/bin/bash
# ============================================================================
# CMDR :: lib/index.sh
# Optional SQLite search index (performance accelerator)
# ============================================================================
# The JSON store stays the single source of truth. When `sqlite3` is present
# and a store is large, CMDR maintains a SQLite mirror of the *effective*
# command set and answers `-f`/search from it, avoiding a full jq scan (which
# re-parses the whole JSON and runs several contains() per entry) on every
# query. The mirror is rebuilt only when the underlying JSON changes (tracked
# by a content hash), so repeated searches over a stable store are cheap.
#
# Behaviour is opt-in-by-default: for typical (small) stores the gate below
# fails and search falls back to the original jq path, byte-for-byte identical.
# Set CMDR_INDEX=1 to force it on, CMDR_INDEX=0 to force it off.
#   CMDR_INDEX_MIN_BYTES  store size (bytes) above which auto-mode kicks in
#                         (default 65536)
# ============================================================================

_index_db_path() {
    echo "$ACTIVE_DATA_DIR/.cmdr_index.db"
}

# Is the SQLite accelerator usable at all? (tool present + not disabled)
_index_available() {
    [ "${CMDR_INDEX:-auto}" = "0" ] && return 1
    command -v sqlite3 >/dev/null 2>&1
}

# Should this search use the index? Gate on an explicit opt-in or store size so
# small stores keep the (already fast) jq path and identical output.
_index_should_use() {
    _index_available || return 1
    [ "${CMDR_INDEX:-auto}" = "1" ] && return 0
    local bytes
    bytes=$(wc -c < "$COMMANDS_FILE" 2>/dev/null | tr -d ' ')
    [ -n "$bytes" ] && [ "$bytes" -ge "${CMDR_INDEX_MIN_BYTES:-65536}" ]
}

_index_hash_string() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
    else
        printf '%s' "$1" | cksum | tr -d ' '
    fi
}

# Rebuild the SQLite mirror from a JSON file. sqlite's json_each/readfile parse
# the JSON directly, so command text with quotes/tabs/newlines is handled
# without any manual escaping. Row insertion order follows object order, so
# ORDER BY id reproduces jq's to_entries order.
_index_rebuild() {
    local json_file="$1" hash="$2" db
    db=$(_index_db_path)
    local tmp
    tmp=$(_mktemp_beside "$db")
    rm -f "$tmp"
    sqlite3 "$tmp" <<SQL 2>/dev/null || { rm -f "$tmp"; return 1; }
CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE cmds(id INTEGER PRIMARY KEY, tag TEXT, cmd TEXT, category TEXT, description TEXT, aliases TEXT);
INSERT INTO cmds(tag, cmd, category, description, aliases)
  SELECT je.key,
         json_extract(je.value, '\$.command'),
         json_extract(je.value, '\$.category'),
         coalesce(json_extract(je.value, '\$.description'), ''),
         coalesce((SELECT group_concat(a.value, ', ')
                   FROM json_each(je.value, '\$.aliases') a), '')
  FROM json_each(readfile('$json_file')) je;
INSERT INTO meta VALUES('hash', '$hash');
SQL
    mv "$tmp" "$db"
}

# Ensure the mirror matches the given JSON (rebuild if the hash changed).
_index_ensure() {
    local json_file="$1" hash="$2" db cur
    db=$(_index_db_path)
    if [ -f "$db" ]; then
        cur=$(sqlite3 "$db" "SELECT v FROM meta WHERE k='hash';" 2>/dev/null)
        [ "$cur" = "$hash" ] && return 0
    fi
    _index_rebuild "$json_file" "$hash"
}

# Search via the index. Prints \037-delimited rows (category, tag, cmd, desc,
# aliases) exactly like the jq search path. Returns 1 to signal "fall back to
# jq" (index unavailable, stale-rebuild failed, or gate says skip).
#
# Args: EFFECTIVE_JSON  KEYWORD
_index_search() {
    local effective="$1" keyword="$2"
    _index_should_use || return 1

    local hash json_file db
    hash=$(_index_hash_string "$effective")
    db=$(_index_db_path)

    # readfile() needs the JSON on disk; reuse COMMANDS_FILE when the effective
    # set is just the workspace store, otherwise stage the merged JSON.
    local staged=""
    if [ "$effective" = "$(cat "$COMMANDS_FILE" 2>/dev/null)" ]; then
        json_file="$COMMANDS_FILE"
    else
        staged=$(_mktemp_beside "$db")
        printf '%s' "$effective" > "$staged"
        json_file="$staged"
    fi

    _index_ensure "$json_file" "$hash" || { [ -n "$staged" ] && rm -f "$staged"; return 1; }
    [ -n "$staged" ] && rm -f "$staged"

    local kw="${keyword//\'/\'\'}"   # escape single quotes for SQL
    sqlite3 -separator $'\037' "$db" \
"SELECT category, tag, cmd, description, aliases FROM cmds
 WHERE instr(lower(tag),        lower('$kw')) > 0
    OR instr(lower(cmd),        lower('$kw')) > 0
    OR instr(lower(category),   lower('$kw')) > 0
    OR instr(lower(description),lower('$kw')) > 0
    OR instr(lower(aliases),    lower('$kw')) > 0
 ORDER BY id;" 2>/dev/null
}
