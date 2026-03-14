<div align="center">

# CMDR v3.0

**A command manager built for CTF players and developers**

Store, organize, and run shell commands with workspaces, environment variables,
playbooks, output capture, notes, and extensible command packs.

[Features](#features) · [Installation](#installation) · [Quick Start](#quick-start) · [CTF Workflow](#ctf-workflow) · [Dev Workflow](#dev-workflow) · [Command Reference](#command-reference)

</div>

---

## Features

| Feature | Description |
|---------|-------------|
| **Command Management** | Store, tag, search, alias, and run commands instantly |
| **Parameterized Commands** | `nmap {TARGET} -sV` with auto-substitution from args or env vars |
| **Workspaces** | Isolated command stores per engagement or project |
| **Environment Variables** | Set `TARGET=10.10.10.1` once, use `{TARGET}` everywhere |
| **Playbooks** | Chain commands into named, reusable sequences |
| **Output Capture** | Save command output with timestamps (`--save`) |
| **Command Packs** | Pre-built command sets for CTF and development |
| **Project-Local Commands** | `.cmdr.json` per repository with `--local` |
| **Notes & Findings** | Attach timestamped notes to commands |
| **Clipboard Copy** | Copy resolved commands to clipboard (`-c`) |
| **Execution Timing** | Shows elapsed time after every command run |
| **Tab Completion** | Bash and Zsh support |
| **Dry-Run** | Preview commands without executing (`-n`) |
| **Undo** | Single-level undo for all write operations (`-u`) |

## Installation

```bash
git clone https://github.com/SP1R4/CMDR.git
cd CMDR
./install.sh
```

The installer will:
- Install `jq` if missing (supports apt, dnf, yum, pacman, brew)
- Set file permissions
- Offer alias or `~/.local/bin` symlink install
- Enable tab completion

After install:
```bash
cmdr -h
```

## Quick Start

```bash
# Add a command
cmdr -a serve 'python3 -m http.server 8080' dev --desc 'Quick HTTP server'

# Add with alias
cmdr -a scan 'nmap {TARGET} -sV' security --desc 'Service scan' --alias s

# Set an env variable
cmdr --env TARGET=10.10.10.1

# Run it (TARGET auto-fills from env)
cmdr -r scan

# Or pass args directly
cmdr -r scan 192.168.1.1

# Dry-run to preview
cmdr -n -r scan

# Copy to clipboard instead of running
cmdr -c scan

# Show all commands
cmdr -s

# Search
cmdr -f nmap
```

## CTF Workflow

```bash
# 1. Create a workspace for the engagement
cmdr -w htb-box

# 2. Load CTF command packs
cmdr --pack load ctf-network
cmdr --pack load ctf-web
cmdr --pack load ctf-privesc

# 3. Set target variables
cmdr --env TARGET=10.10.10.50
cmdr --env LPORT=4444

# 4. Run recon
cmdr -r quick-scan --save
cmdr -r dirfuzz --save

# 5. Add findings as notes
cmdr --note quick-scan "Port 8080 open - Apache Tomcat"
cmdr --note dirfuzz "Found /admin and /api endpoints"

# 6. Create a recon playbook for reuse
cmdr --playbook recon quick-scan dirfuzz nikto-scan

# 7. Run the playbook on the next target
cmdr --env TARGET=10.10.10.51
cmdr -p recon

# 8. Review notes and outputs
cmdr --notes
cmdr --outputs quick-scan

# 9. Switch back to default when done
cmdr -w default
```

## Dev Workflow

```bash
# 1. Load dev packs globally (in default workspace)
cmdr --pack load dev-python
cmdr --pack load dev-docker
cmdr --pack load dev-git

# 2. Add project-local commands
cmdr --local -a build 'make -j$(nproc)' dev --desc 'Build project'
cmdr --local -a test 'python3 -m pytest -v tests/' dev --desc 'Run tests'
cmdr --local -a lint 'flake8 . && mypy .' dev --desc 'Lint check'

# 3. Create a CI-like chain
cmdr --playbook ci lint test build

# 4. Run it
cmdr -p ci

# 5. Quick git workflow
cmdr -r glog              # Pretty git log
cmdr -r git-branch-clean  # Clean merged branches
```

## Workspaces

Workspaces isolate commands, env vars, notes, playbooks, and outputs.

```bash
cmdr -w myproject       # Switch to workspace
cmdr -w                 # Show active workspace
cmdr -W                 # List all workspaces
cmdr -w default         # Return to default workspace
```

## Environment Variables

Per-workspace variables that auto-substitute `{KEY}` placeholders at runtime.

```bash
cmdr --env TARGET=10.10.10.1   # Set
cmdr --env PORT=8080           # Set another
cmdr --env                     # Show all
cmdr --env-clear PORT          # Remove one
```

Resolution order: env vars are substituted first, then remaining `{placeholders}` are filled from positional arguments or prompted interactively.

## Playbooks & Chains

```bash
# Create a named playbook
cmdr --playbook recon quick-scan dirfuzz nikto-scan

# Run it
cmdr -p recon

# List all playbooks
cmdr --playbooks

# One-off chain (no save)
cmdr --chain cmd1 cmd2 cmd3

# Dry-run a playbook
cmdr -n -p recon
```

Playbooks and chains stop on first failure (non-zero exit).

## Command Packs

Pre-built command sets in the `packs/` directory.

```bash
cmdr --pack list              # See available packs
cmdr --pack load ctf-web      # Load a pack
```

| Pack | Commands | Category |
|------|----------|----------|
| `ctf-network` | nmap scans, enum4linux, netcat, DNS | ctf-recon, ctf-enum, ctf-exploit |
| `ctf-web` | ffuf, gobuster, sqlmap, nikto, wfuzz | ctf-web |
| `ctf-privesc` | SUID, capabilities, cron, sudo, linpeas | ctf-privesc |
| `dev-python` | venv, pytest, flake8, http.server | dev-python |
| `dev-docker` | build, run, compose, prune, exec | dev-docker |
| `dev-git` | log, undo, amend, stash, branch cleanup | dev-git |

## Notes & Output Capture

```bash
# Attach a finding to a command
cmdr --note scan "Found port 8080, Apache Tomcat 9.0"

# View notes
cmdr --notes scan     # For one command
cmdr --notes          # All notes

# Save command output
cmdr -r scan --save

# View saved outputs
cmdr --outputs        # All
cmdr --outputs scan   # Filtered
```

## Project-Local Commands

Place a `.cmdr.json` in any directory. CMDR automatically merges it with your global/workspace commands. Local commands take precedence.

```bash
# Add to the local file
cmdr --local -a build 'make -j4' dev

# Shows under "Project-Local" section
cmdr -s

# Run normally (resolved from local first)
cmdr -r build
```

## Command Reference

### Core Commands

| Flag | Usage | Description |
|------|-------|-------------|
| `-a` | `cmdr -a <tag> <cmd> [cat] [--desc ..] [--alias ..]` | Add a command |
| `-e` | `cmdr -e <tag> [cmd] [cat] [--desc ..] [--alias ..]` | Edit a command |
| `-d` | `cmdr -d <tag> [-y]` | Delete (with confirmation) |
| `-s` | `cmdr -s` | Show all commands |
| `-r` | `cmdr -r <tag> [args..] [--save]` | Run a command |
| `-f` | `cmdr -f <keyword>` | Search commands |
| `-c` | `cmdr -c <tag> [args..]` | Copy to clipboard |

### Workspaces & Environment

| Flag | Usage | Description |
|------|-------|-------------|
| `-w` | `cmdr -w <name>` | Switch workspace |
| `-w` | `cmdr -w` | Show active workspace |
| `-W` | `cmdr -W` | List all workspaces |
| `--env` | `cmdr --env KEY=VALUE` | Set env variable |
| `--env` | `cmdr --env` | Show env variables |
| `--env-clear` | `cmdr --env-clear KEY` | Clear env variable |
| `--local` | `cmdr --local -a ...` | Use project-local `.cmdr.json` |

### Playbooks & Chains

| Flag | Usage | Description |
|------|-------|-------------|
| `--playbook` | `cmdr --playbook <name> <tags..>` | Create playbook |
| `-p` | `cmdr -p <name>` | Run playbook |
| `--playbooks` | `cmdr --playbooks` | List playbooks |
| `--chain` | `cmdr --chain <tags..>` | Run commands in sequence |

### Notes, Outputs & Packs

| Flag | Usage | Description |
|------|-------|-------------|
| `--note` | `cmdr --note <tag> "text"` | Add a note |
| `--notes` | `cmdr --notes [tag]` | Show notes |
| `--outputs` | `cmdr --outputs [tag]` | Show saved outputs |
| `--pack` | `cmdr --pack list` | List packs |
| `--pack` | `cmdr --pack load <name>` | Load a pack |

### General

| Flag | Usage | Description |
|------|-------|-------------|
| `-x` | `cmdr -x <file>` | Export commands to JSON |
| `-l` | `cmdr -l <file>` | Export logs |
| `-i` | `cmdr -i <file>` | Import commands (merge) |
| `-m` | `cmdr -m` | Interactive mode |
| `-u` | `cmdr -u` | Undo last change |
| `-n` | `cmdr -n` | Dry-run mode |
| `-v` | `cmdr -v` | Debug logging |
| `-V` | `cmdr -V` | Show version |
| `-h` | `cmdr -h` | Show help |

## License

MIT
