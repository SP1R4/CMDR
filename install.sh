#!/bin/bash
# CMDR v2.0 - One-step installer

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
echo -e "  ${CYAN}Installer v2.0${NC}"
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

# Offer to create a global alias
echo ""
read -p "Add 'cmdr' alias to your shell? (Y/n): " add_alias
add_alias="${add_alias:-Y}"

if [ "$add_alias" = "y" ] || [ "$add_alias" = "Y" ]; then
    ALIAS_LINE="alias cmdr='$SCRIPT_DIR/cmdr.sh'"

    # Detect shell config file
    SHELL_RC=""
    if [ -n "$ZSH_VERSION" ] || [ "$(basename "$SHELL")" = "zsh" ]; then
        SHELL_RC="$HOME/.zshrc"
    else
        SHELL_RC="$HOME/.bashrc"
    fi

    # Check if alias already exists
    if grep -qF "alias cmdr=" "$SHELL_RC" 2>/dev/null; then
        # Update existing alias
        sed -i "s|alias cmdr=.*|$ALIAS_LINE|" "$SHELL_RC"
        echo -e "${GREEN}Updated cmdr alias in $SHELL_RC${NC}"
    else
        echo "" >> "$SHELL_RC"
        echo "# CMDR - Command Manager" >> "$SHELL_RC"
        echo "$ALIAS_LINE" >> "$SHELL_RC"
        echo -e "${GREEN}Added cmdr alias to $SHELL_RC${NC}"
    fi
    echo -e "${YELLOW}Run 'source $SHELL_RC' or restart your terminal to use 'cmdr'${NC}"
fi

echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo -e "Run ${CYAN}cmdr -h${NC} (or ${CYAN}$SCRIPT_DIR/cmdr.sh -h${NC}) to get started."
echo ""
