#!/bin/bash
# ============================================================================
# CMDR v3.0 - Command Manager Functions (loader)
# ============================================================================
# Core engine for CMDR: command storage, workspace isolation, environment
# variables, playbooks, output capture, notes, and extensible command packs.
#
# All functions read global variables set by cmdr.sh (COMMANDS_FILE, ENV_FILE,
# NOTES_FILE, PLAYBOOKS_FILE, OUTPUTS_DIR, etc.) and the modifier flags
# (DRY_RUN, SAVE_OUTPUT, USE_LOCAL, CMDR_DESC, CMDR_ALIASES, CMDR_FORCE_YES).
#
# The implementation is split into focused modules under lib/. This file only
# sources them, in dependency order, so `source cmdr_functions.sh` keeps the
# same public surface it always had.
# ============================================================================

# Resolve this file's directory (it may be reached through a symlink).
_CMDR_FN_SRC="${BASH_SOURCE[0]}"
while [ -h "$_CMDR_FN_SRC" ]; do
    _CMDR_FN_DIR="$( cd -P "$( dirname "$_CMDR_FN_SRC" )" >/dev/null 2>&1 && pwd )"
    _CMDR_FN_SRC="$( readlink "$_CMDR_FN_SRC" )"
    [[ "$_CMDR_FN_SRC" != /* ]] && _CMDR_FN_SRC="$_CMDR_FN_DIR/$_CMDR_FN_SRC"
done
CMDR_LIB_DIR="$( cd -P "$( dirname "$_CMDR_FN_SRC" )" >/dev/null 2>&1 && pwd )/lib"
unset _CMDR_FN_SRC _CMDR_FN_DIR

if [ ! -d "$CMDR_LIB_DIR" ]; then
    echo "Error: CMDR module directory '$CMDR_LIB_DIR' not found." >&2
    exit 1
fi

# Source order matters only for the handful of top-level assignments in the
# modules (e.g. LINT_TOTAL); function definitions are order-independent because
# everything lands in the same shell. Keep the original section order. The
# sources are spelled out (rather than looped) so `shellcheck -x` can follow
# each module and see the globals defined in cmdr.sh being used here.
# shellcheck source=lib/core.sh
source "$CMDR_LIB_DIR/core.sh"
# shellcheck source=lib/resolve.sh
source "$CMDR_LIB_DIR/resolve.sh"
# shellcheck source=lib/index.sh
source "$CMDR_LIB_DIR/index.sh"
# shellcheck source=lib/json_out.sh
source "$CMDR_LIB_DIR/json_out.sh"
# shellcheck source=lib/workspace.sh
source "$CMDR_LIB_DIR/workspace.sh"
# shellcheck source=lib/commands.sh
source "$CMDR_LIB_DIR/commands.sh"
# shellcheck source=lib/run.sh
source "$CMDR_LIB_DIR/run.sh"
# shellcheck source=lib/findings.sh
source "$CMDR_LIB_DIR/findings.sh"
# shellcheck source=lib/menu.sh
source "$CMDR_LIB_DIR/menu.sh"
# shellcheck source=lib/crypto.sh
source "$CMDR_LIB_DIR/crypto.sh"
# shellcheck source=lib/playbooks.sh
source "$CMDR_LIB_DIR/playbooks.sh"
# shellcheck source=lib/packs.sh
source "$CMDR_LIB_DIR/packs.sh"
# shellcheck source=lib/import.sh
source "$CMDR_LIB_DIR/import.sh"
# shellcheck source=lib/flow.sh
source "$CMDR_LIB_DIR/flow.sh"
# shellcheck source=lib/maintenance.sh
source "$CMDR_LIB_DIR/maintenance.sh"
# shellcheck source=lib/help.sh
source "$CMDR_LIB_DIR/help.sh"
