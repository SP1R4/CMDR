# CMDR - Command Manager

CMDR is a Bash-based command management tool designed to store, organize, and execute shell commands securely. It allows users to tag commands, categorize them, and run them interactively or via command-line arguments. Built with security in mind, CMDR includes input sanitization to prevent command injection vulnerabilities and uses JSON for persistent storage.

## Features

- **Command Storage**: Save shell commands with unique tags in a JSON file (`my_commands.json`).
- **Categorization**: Organize commands into custom categories (e.g., `dev`, `sysadmin`).
- **Input Sanitization**: 
  - Blocks dangerous characters (`;` and `|`) in commands to prevent injection.
  - Restricts tags to alphanumeric characters, underscores, and hyphens.
- **Interactive Mode**: Browse and execute commands via a menu-driven interface.
- **Validation**: Ensures commands are executable, with an option to override for non-executable commands.
- **Logging**: Supports `DEBUG`, `INFO`, and `ERROR` logging levels for troubleshooting.
- **Locking**: Prevents concurrent runs using a lock file.
- **Export/Import**: Extract commands to a JSON file or install from a JSON file.
- **Modular Design**: Separates core logic (`cmdr.sh`) and functions (`cmdr_functions.sh`) for maintainability.

## Installation

1. **Clone the Repository**:
   ```bash
   git clone (https://github.com/SP1R4/CMDR)
   cd CMDR
   ```

2. **Set Permissions**:
   Ensure the scripts and JSON file are executable and writable:
   ```bash
   chmod +x cmdr.sh cmdr_functions.sh
   chmod 666 my_commands.json commands_log.log
   ```

3. **Install Dependencies**:
   CMDR requires `jq` for JSON processing. Install it on Ubuntu/Debian:
   ```bash
   sudo apt-get update
   sudo apt-get install jq
   ```

4. **Run with Sudo**:
   Due to file permissions, run the script with `sudo`:
   ```bash
   sudo ./cmdr.sh -h
   ```

## Usage

Run `cmdr.sh` with the following options:

```bash
sudo ./cmdr.sh [-a <tag> <command> [category]] [-d <tag>] [-s] [-r <tag>] [-x <output_file>] [-l <output_file>] [-i <input_file>] [-m] [-v] [-h]
```

### Options

- `-a <tag> <command> [category]`: Add a command with a tag and optional category (default: `default`).
- `-d <tag>`: Delete the command with the specified tag.
- `-s`: Show commands grouped by category.
- `-r <tag>`: Run the command with the specified tag.
- `-x <output_file>`: Extract commands to a JSON file.
- `-l <output_file>`: Extract logs to a file.
- `-i <input_file>`: Install commands from a JSON file.
- `-m`: Enter interactive mode to browse and run commands.
- `-v`: Enable debug logging (default: info).
- `-h`: Display help message with ASCII art.

### Examples

1. **Add a command**:
   ```bash
   sudo ./cmdr.sh -a mycmd 'echo Hello' dev
   ```
   Output:
   ```
   Validation passed: 'echo' found.
   Command added successfully: 'mycmd' in category 'dev'.
   ```

2. **Run a command**:
   ```bash
   sudo ./cmdr.sh -r mycmd
   ```
   Output:
   ```
   Running command: echo Hello
   Hello
   ```

3. **Show commands**:
   ```bash
   sudo ./cmdr.sh -s
   ```
   Output:
   ```
   Available commands by category:
   Category: dev
     mycmd: echo Hello
   ```

4. **Delete a command**:
   ```bash
   sudo ./cmdr.sh -d mycmd
   ```
   Output:
   ```
   Command 'mycmd' deleted successfully.
   ```

5. **Interactive mode**:
   ```bash
   sudo ./cmdr.sh -m
   ```
   Output:
   ```
   Interactive Mode (select 'exit' to quit):
   Categories:
   1) dev
   2) exit
   ```

6. **Enable debug logging**:
   ```bash
   sudo ./cmdr.sh -v -a list_dir 'ls -l' sysadmin
   ```
   Check logs:
   ```bash
   cat commands_log.log
   ```
