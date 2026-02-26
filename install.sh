#!/bin/bash
# CMDR v2.1 - Installer

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

echo ""
echo -e "${GREEN}   ██████╗███╗   ███╗██████╗ ██████╗ ${NC}"
echo -e "${GREEN}  ██╔════╝████╗ ████║██╔══██╗██╔══██╗${NC}"
echo -e "${GREEN}  ██║     ██╔████╔██║██║  ██║██████╔╝${NC}"
echo -e "${GREEN}  ██║     ██║╚██╔╝██║██║  ██║██╔══██╗${NC}"
echo -e "${GREEN}  ╚██████╗██║ ╚═╝ ██║██████╔╝██║  ██║${NC}"
echo -e "${GREEN}   ╚═════╝╚═╝     ╚═╝╚═════╝ ╚═╝  ╚═╝${NC}"
echo -e "  ${CYAN}Installer v2.1${NC}"
echo ""

# Check and install jq
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YELLOW}jq not found. Installing...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y -qq jq
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y -q jq
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y -q jq
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm jq
    elif command -v brew >/dev/null 2>&1; then
        brew install jq
    else
        echo -e "${RED}Error:${NC} Could not install jq automatically."
        echo "Please install jq manually: https://stedolan.github.io/jq/download/"
        exit 1
    fi
    echo -e "${GREEN}jq installed.${NC}"
else
    echo -e "${GREEN}jq found.${NC}"
fi

# Set permissions
chmod +x "$SCRIPT_DIR/cmdr.sh" "$SCRIPT_DIR/cmdr_functions.sh"
echo -e "${GREEN}Permissions set.${NC}"

# Initialize commands file if it doesn't exist
if [ ! -f "$SCRIPT_DIR/my_commands.json" ]; then
    echo "{}" > "$SCRIPT_DIR/my_commands.json"
    echo -e "${GREEN}Created empty commands file.${NC}"
fi

# Detect shell config file
SHELL_RC=""
if [ -n "$ZSH_VERSION" ] || [ "$(basename "$SHELL")" = "zsh" ]; then
    SHELL_RC="$HOME/.zshrc"
else
    SHELL_RC="$HOME/.bashrc"
fi

# Choose install method
echo ""
echo -e "${YELLOW}Install method:${NC}"
echo "  1) Shell alias (source from $SHELL_RC)"
echo "  2) Symlink to ~/.local/bin/cmdr (XDG-compliant)"
echo ""
read -p "Choose method [1]: " method
method="${method:-1}"

ALIAS_LINE="alias cmdr='$SCRIPT_DIR/cmdr.sh'"
SYMLINK_DIR="$HOME/.local/bin"
SYMLINK_PATH="$SYMLINK_DIR/cmdr"

if [ "$method" = "2" ]; then
    # XDG symlink method
    mkdir -p "$SYMLINK_DIR"

    # Check if ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$SYMLINK_DIR:"* ]]; then
        echo -e "${YELLOW}Warning:${NC} $SYMLINK_DIR is not in your PATH."
        echo -e "Add this to $SHELL_RC:  ${CYAN}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
        echo ""
        read -p "Add it now? (Y/n): " add_path
        add_path="${add_path:-Y}"
        if [ "$add_path" = "y" ] || [ "$add_path" = "Y" ]; then
            echo "" >> "$SHELL_RC"
            echo '# CMDR - PATH' >> "$SHELL_RC"
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
            echo -e "${GREEN}Added PATH entry to $SHELL_RC${NC}"
        fi
    fi

    # Create/update symlink
    ln -sf "$SCRIPT_DIR/cmdr.sh" "$SYMLINK_PATH"
    echo -e "${GREEN}Symlink created: $SYMLINK_PATH -> $SCRIPT_DIR/cmdr.sh${NC}"

    # Remove conflicting alias if present
    if grep -qF "alias cmdr=" "$SHELL_RC" 2>/dev/null; then
        tmp_rc=$(mktemp)
        grep -vF "alias cmdr=" "$SHELL_RC" > "$tmp_rc" && mv "$tmp_rc" "$SHELL_RC"
        echo -e "${YELLOW}Removed old cmdr alias from $SHELL_RC${NC}"
    fi
else
    # Alias method (default)
    if grep -qF "alias cmdr=" "$SHELL_RC" 2>/dev/null; then
        # Update existing alias using temp-file-and-mv (portable, no sed -i)
        tmp_rc=$(mktemp)
        sed "s|alias cmdr=.*|$ALIAS_LINE|" "$SHELL_RC" > "$tmp_rc" && mv "$tmp_rc" "$SHELL_RC"
        echo -e "${GREEN}Updated cmdr alias in $SHELL_RC${NC}"
    else
        echo "" >> "$SHELL_RC"
        echo "# CMDR - Command Manager" >> "$SHELL_RC"
        echo "$ALIAS_LINE" >> "$SHELL_RC"
        echo -e "${GREEN}Added cmdr alias to $SHELL_RC${NC}"
    fi
fi

# Set up tab completion
COMPLETION_FILE="$SCRIPT_DIR/cmdr_completion.bash"
if [ -f "$COMPLETION_FILE" ]; then
    source_line="source '$COMPLETION_FILE'"
    export_line="export CMDR_DATA_DIR='$SCRIPT_DIR'"

    if ! grep -qF "cmdr_completion" "$SHELL_RC" 2>/dev/null; then
        echo "" >> "$SHELL_RC"
        echo "# CMDR - Tab completion" >> "$SHELL_RC"
        echo "$export_line" >> "$SHELL_RC"
        echo "$source_line" >> "$SHELL_RC"
        echo -e "${GREEN}Tab completion enabled in $SHELL_RC${NC}"
    else
        echo -e "${GREEN}Tab completion already configured.${NC}"
    fi
fi

echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo -e "${YELLOW}Run 'source $SHELL_RC' or restart your terminal.${NC}"
echo -e "Run ${CYAN}cmdr -h${NC} (or ${CYAN}$SCRIPT_DIR/cmdr.sh -h${NC}) to get started."
echo ""
