# CMDR v2.0 - Command Manager

CMDR is a Bash-based command management tool for storing, organizing, and executing shell commands. Tag your commands, group them into categories, and run them from the CLI or an interactive menu. Uses JSON for storage and `jq` for processing.

## What's New in v2

- **No more sudo** — runs as your regular user
- **Edit commands** (`-e`) — update existing commands in place
- **Search** (`-f`) — find commands by keyword across tags, commands, and categories
- **Safe JSON handling** — uses `jq --arg` instead of string interpolation (no injection risk)
- **Fixed whitespace bug** — commands with spaces now work correctly
- **Smart import** — `-i` merges into existing commands instead of overwriting
- **Proper temp files** — uses `mktemp` instead of predictable paths
- **Preloaded commands** — ships with useful sysadmin, network, dev, docker, and security commands
- **CMDR ASCII banner** — new branding in help output

## Features

- **Command Storage**: Save shell commands with unique tags in a JSON file
- **Categorization**: Organize commands into custom categories (e.g., `dev`, `sysadmin`, `network`)
- **Edit Commands**: Update existing commands without delete/re-add
- **Search**: Find commands by keyword across tags, commands, and categories
- **Interactive Mode**: Browse and execute commands via a menu-driven interface
- **Validation**: Checks if executables exist before storing, with option to override
- **Logging**: Supports `DEBUG`, `INFO`, and `ERROR` logging levels
- **Locking**: Prevents concurrent runs using a lock file
- **Export/Import**: Export commands to JSON or import/merge from a JSON file
- **Modular Design**: Separates core logic (`cmdr.sh`) and functions (`cmdr_functions.sh`)

## Installation

1. **Clone the repository**:
   ```bash
   git clone https://github.com/SP1R4/CMDR
   cd CMDR
   ```

2. **Make scripts executable**:
   ```bash
   chmod +x cmdr.sh cmdr_functions.sh
   ```

3. **Install `jq`** (if not already installed):
   ```bash
   sudo apt-get install jq
   ```

4. **Run it**:
   ```bash
   ./cmdr.sh -h
   ```

## Usage

```bash
./cmdr.sh [options]
```

### Options

| Flag | Description |
|------|-------------|
| `-a <tag> <command> [category]` | Add a command with tag and optional category (default: `default`) |
| `-e <tag> [command] [category]` | Edit an existing command |
| `-d <tag>` | Delete a command |
| `-s` | Show all commands grouped by category |
| `-r <tag>` | Run a command by tag |
| `-f <keyword>` | Search commands by keyword |
| `-x <output_file>` | Export commands to JSON file |
| `-l <output_file>` | Export logs to file |
| `-i <input_file>` | Import/merge commands from JSON file |
| `-m` | Interactive mode |
| `-v` | Enable debug logging |
| `-h` | Show help |

### Examples

**Add a command:**
```bash
./cmdr.sh -a myserver 'python3 -m http.server 8080' dev
```

**Edit a command:**
```bash
./cmdr.sh -e myserver 'python3 -m http.server 9090'
```

**Search for commands:**
```bash
./cmdr.sh -f docker
```

**Run a command:**
```bash
./cmdr.sh -r myserver
```

**Show all commands:**
```bash
./cmdr.sh -s
```

**Interactive mode:**
```bash
./cmdr.sh -m
```

**Export and import:**
```bash
./cmdr.sh -x backup.json
./cmdr.sh -i backup.json
```

## Preloaded Commands

CMDR ships with commands across these categories:

| Category | Commands |
|----------|----------|
| `sysadmin` | `sysupdate`, `diskusage`, `meminfo`, `topproc` |
| `network` | `ports`, `myip`, `pingg`, `flushdns` |
| `dev` | `httpserver`, `gitlog`, `gitstatus` |
| `docker` | `dps`, `dstop` |
| `security` | `genpass`, `listener`, `sshkeys` |
| `misc` | `weather` |

Run `./cmdr.sh -s` to see them all.

## License

MIT
