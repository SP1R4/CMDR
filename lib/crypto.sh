#!/bin/bash
# ============================================================================
# CMDR :: lib/crypto.sh
# Encrypted workspaces
# Part of cmdr_functions.sh, split into modules. Sourced by the loader;
# relies on globals set in cmdr.sh. Do not execute directly.
# ============================================================================

# ----------------------------------------------------------------------------
# Section 8f: Encrypted Workspaces
# Encrypt a named workspace's directory to a single blob at rest (age or gpg).
# ----------------------------------------------------------------------------

# True if an encryption backend is available.
_have_crypto() {
    command -v age >/dev/null 2>&1 || command -v gpg >/dev/null 2>&1
}

# Encrypt stdin to file $1 (prompts for passphrase).
_encrypt_stdin_to() {
    if command -v age >/dev/null 2>&1; then
        age -p -o "$1"
    elif command -v gpg >/dev/null 2>&1; then
        gpg --batch --yes -c -o "$1"
    else
        return 1
    fi
}

# Decrypt file $1 to stdout (prompts for passphrase).
_decrypt_to_stdout() {
    if command -v age >/dev/null 2>&1; then
        age -d "$1"
    elif command -v gpg >/dev/null 2>&1; then
        gpg -d "$1"
    else
        return 1
    fi
}

# Encrypt a named workspace dir into <name>.cmdrlock and remove the plaintext.
lock_workspace() {
    local name="${1:-$ACTIVE_WORKSPACE}"
    if [ "$name" = "default" ]; then
        echo -e "${RED}Error:${NC} The default workspace cannot be locked. Use a named workspace."
        exit 1
    fi
    name=$(sanitize_tag "$name") || exit 1
    if ! _have_crypto; then
        echo -e "${RED}Error:${NC} Need 'age' or 'gpg' installed to encrypt."
        exit 1
    fi

    local ws_dir="$DATA_DIR/workspaces/$name"
    local blob="$DATA_DIR/workspaces/${name}.cmdrlock"
    if [ ! -d "$ws_dir" ]; then
        echo -e "${RED}Error:${NC} Workspace '$name' not found."
        exit 1
    fi
    if [ -f "$blob" ]; then
        echo -e "${RED}Error:${NC} An encrypted blob for '$name' already exists."
        exit 1
    fi

    echo -e "${CYAN}Encrypting workspace '$name'...${NC}"
    if tar -czf - -C "$DATA_DIR/workspaces" "$name" | _encrypt_stdin_to "$blob"; then
        rm -rf "$ws_dir"
        # If we just locked the active workspace, drop back to default.
        [ "$name" = "$ACTIVE_WORKSPACE" ] && rm -f "$WORKSPACE_FILE"
        log_event "INFO" "Locked workspace: $name"
        echo -e "${GREEN}Workspace locked:${NC} $blob"
    else
        rm -f "$blob"
        echo -e "${RED}Error:${NC} Encryption failed."
        exit 1
    fi
}

# Decrypt <name>.cmdrlock back into a workspace directory.
unlock_workspace() {
    local name="$1"
    if [ -z "$name" ]; then
        echo -e "${RED}Error:${NC} Usage: cmdr --unlock-workspace <name>"
        exit 1
    fi
    name=$(sanitize_tag "$name") || exit 1

    local ws_dir="$DATA_DIR/workspaces/$name"
    local blob="$DATA_DIR/workspaces/${name}.cmdrlock"
    if [ ! -f "$blob" ]; then
        echo -e "${RED}Error:${NC} No encrypted blob for '$name'."
        exit 1
    fi
    if [ -d "$ws_dir" ]; then
        echo -e "${RED}Error:${NC} Plaintext workspace '$name' already exists."
        exit 1
    fi

    echo -e "${CYAN}Decrypting workspace '$name'...${NC}"
    if _decrypt_to_stdout "$blob" | tar -xzf - -C "$DATA_DIR/workspaces"; then
        rm -f "$blob"
        log_event "INFO" "Unlocked workspace: $name"
        echo -e "${GREEN}Workspace unlocked:${NC} $name"
    else
        rm -rf "$ws_dir"
        echo -e "${RED}Error:${NC} Decryption failed (wrong passphrase?)."
        exit 1
    fi
}

