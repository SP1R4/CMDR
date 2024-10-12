
# Command Manager Script

## Overview

The Command Manager Script allows you to manage and execute custom commands easily. You can add, delete, run, and list commands stored in a JSON file. This script is designed for use in a Linux environment and requires `jq` for JSON manipulation.

## Features

- **Add a Command**: Store custom commands with a unique tag.
- **Delete a Command**: Remove commands using their tag.
- **Show Commands**: List all available commands.
- **Run a Command**: Execute a stored command.
- **Extract Commands**: Save all commands to a specified output file.
- **Extract Logs**: Save the command execution logs to a specified file.
- **Install Commands**: Load commands from a specified input file.

## Usage

To run the script, use the following command:

```bash
sudo ./cmdr.sh [options]
```

### Options

- `-a <tag> <command>`: Add a new command with the specified tag.
- `-d <tag>`: Delete the command associated with the specified tag.
- `-s`: Show available commands.
- `-r <tag>`: Run the command associated with the specified tag.
- `-x <output_file>`: Extract commands to the specified output file.
- `-l <output_file>`: Extract logs to the specified output file.
- `-i <input_file>`: Install commands from the specified input file.
- `-h`: Display help message.

### Examples

1. **Add a new command**:
   ```bash
   sudo ./cmdr.sh -a mycmd 'echo Hello'
   ```

2. **Delete a command**:
   ```bash
   sudo ./cmdr.sh -d mycmd
   ```

3. **Show available commands**:
   ```bash
   sudo ./cmdr.sh -s
   ```

4. **Run a command**:
   ```bash
   sudo ./cmdr.sh -r mycmd
   ```

5. **Extract commands to a file**:
   ```bash
   sudo ./cmdr.sh -x extracted_commands.json
   ```

6. **Extract logs to a file**:
   ```bash
   sudo ./cmdr.sh -l commands_log.log
   ```

7. **Install commands from a file**:
   ```bash
   sudo ./cmdr.sh -i commands_to_install.json
   ```

## Requirements

- **Bash**: Ensure you're running a compatible shell.
- **jq**: Install `jq` for JSON processing:
  ```bash
  sudo apt-get install jq  # For Debian-based systems
  ```

## Locking Mechanism

The script employs a locking mechanism to prevent multiple instances from running simultaneously. A lock file is created in the user's home directory (`$HOME/command_manager.lock`). 

## Temporary File Cleanup

The script performs cleanup of temporary files created during command manipulation to avoid clutter.
