<div align="center">

# CMDR v3.1

[![CI](https://github.com/SP1R4/CMDR/actions/workflows/ci.yml/badge.svg)](https://github.com/SP1R4/CMDR/actions/workflows/ci.yml) ![License](https://img.shields.io/github/license/SP1R4/CMDR?color=black) ![Top language](https://img.shields.io/github/languages/top/SP1R4/CMDR) ![Last commit](https://img.shields.io/github/last-commit/SP1R4/CMDR)

**A command manager built for CTF players and developers**

Store, organize, and run shell commands with workspaces, hosts, environment
variables, playbooks, output capture, findings, and extensible command packs.

[Features](#features) · [Installation](#installation) · [Quick Start](#quick-start) · [CTF Workflow](#ctf-workflow) · [Dev Workflow](#dev-workflow) · [Command Reference](#command-reference)

</div>

---

## Features

| Feature | Description |
|---------|-------------|
| **Command Management** | Store, tag, search, alias, and run commands instantly |
| **Parameterized Commands** | `nmap {TARGET} -sV`; `{VAR:=default}` and `{VAR:?}` (required) forms |
| **Host/Target Model** | Inventory hosts; `@name` / `--on` / `--all-hosts` fill `{TARGET}` etc. |
| **Output Capture → Chaining** | `--capture VAR[:regex]` pipes a command's stdout into an env var |
| **Remote Execution** | `--on <host>` runs a stored command over SSH |
| **Findings & Reporting** | Structured findings + markdown engagement report (`--report`) |
| **Run History** | Recorded runs; `--history`; re-run with `-r last` |
| **Encrypted Workspaces** | Lock a workspace to an encrypted blob at rest (age/gpg) |
| **Danger Flag** | `--danger` commands always confirm before running, even with `-y` |
| **Fuzzy Picker** | `--pick` (or bare `cmdr`) fuzzy-find a command via fzf |
| **Workspaces** | Isolated command stores per engagement or project |
| **Environment Variables** | Set `TARGET=10.10.10.1` once, use `{TARGET}` everywhere |
| **Playbooks** | Chain commands into named, reusable sequences |
| **Output Capture** | Save command output with timestamps (`--save`) |
| **Command Packs** | Pre-built command sets for CTF and development |
| **Project-Local Commands** | `.cmdr.json` per repository with `--local` (trust-gated) |
| **Notes** | Attach timestamped notes to commands |
| **Clipboard Copy** | Copy resolved commands to clipboard (`-c`) |
| **Tab Completion** | Bash and Zsh support |
| **Dry-Run / Undo** | Preview (`-n`) and single-level undo (`-u`) |

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

# 3. Inventory targets (fills {TARGET}/{OS}/{RUSER}/{RPORT})
cmdr --host add 10.10.10.50 --name box1 --os linux
cmdr --host add 10.10.10.51 --name box2 --os windows --user administrator
cmdr --env LPORT=4444

# 4. Recon against a host
cmdr -r quick-scan @box1 --save
cmdr -r dirfuzz @box1 --save

# 5. Chain an auth flow: capture a token, reuse it downstream
cmdr -r login @box1 --capture 'TOKEN:eyJ[A-Za-z0-9._-]+'
cmdr -r list-users @box1            # uses {TOKEN}

# 6. Record structured findings (feed the report later)
cmdr --finding high box1 "Unauth API at /admin" --evidence outputs/dirfuzz_*.log
cmdr --finding medium box1 "Tomcat 9.0 — CVE candidate"

# 7. Reusable recon playbook, then fan across every host
cmdr --playbook recon quick-scan dirfuzz nikto-scan
cmdr -r quick-scan --all-hosts --save

# 8. Run privesc remotely once you have creds
cmdr -r linpeas --on box2

# 9. Review and produce the deliverable
cmdr --findings
cmdr --history
cmdr --report engagement.md

# 10. Lock the engagement workspace at rest, switch back to default
cmdr --lock-workspace htb-box
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
| `starter` | handy sysadmin/network/dev/security one-liners | mixed |
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

Place a `.cmdr.json` in any directory. CMDR merges it with your global/workspace commands so its tags are usable from that directory. Local entries take precedence (a deep merge: fields you omit locally fall back to the global entry of the same tag).

```bash
# Add to the local file
cmdr --local -a build 'make -j4' dev

# Shows under "Project-Local" section
cmdr -s

# Run normally (resolved from local first)
cmdr -r build
```

### Trust model (important)

A `.cmdr.json` contains shell commands that CMDR will execute. To avoid running
commands from a directory you just `cd`'d into (e.g. a freshly cloned, untrusted
repo), **local files are ignored until you explicitly trust them**:

```bash
cmdr --trust      # approve the current dir's .cmdr.json after reviewing it
cmdr --untrust    # revoke trust
```

- Authoring a local file with `cmdr --local -a ...` trusts it automatically.
- Trust is pinned to the file's **content hash** — if the file changes, trust is
  revoked until you re-run `cmdr --trust`. Review the diff before re-trusting.
- Trust is recorded globally in `.cmdr_trusted.json`, keyed by absolute path.

> Note: stored commands run via `bash -c`, so values from env vars and arguments
> are shell-interpreted. Only trust local files (and run commands) you've read.

## Hosts & Targeting

Build a per-workspace host inventory, then target commands at hosts. Selecting a
host fills `{TARGET}`/`{RHOST}` (ip or hostname), `{RHOSTNAME}`, `{OS}`,
`{RUSER}`, `{RPORT}`.

```bash
cmdr --host add 10.10.10.5 --name dc01 --os windows --user admin --port 5985
cmdr --host list
cmdr --host rm dc01

cmdr -r smbscan @dc01           # fill host vars for one host
cmdr -r nmap --all-hosts        # run once per defined host
cmdr -r linpeas --on dc01       # execute over SSH (uses user/port from the host)
```

## Output Capture → Chaining

Pipe a command's stdout into a workspace env var, then use it in the next command —
ideal for tokens, session ids, and multi-step exploitation.

```bash
cmdr -r login --capture TOKEN                 # whole (trimmed) stdout -> {TOKEN}
cmdr -r login --capture 'TOKEN:eyJ[A-Za-z0-9._-]+'   # first regex match -> {TOKEN}
cmdr -r get-users                             # command references {TOKEN}
```

## Placeholder Forms

```text
{VAR}            env var, else next positional arg, else interactive prompt
{VAR:=default}   env var, else next positional arg, else 'default' (no prompt)
{VAR:?}          env var, else next positional arg, else hard error (required)
```

## Findings & Reporting

```bash
cmdr --finding high dc01 "Unauth WinRM" --evidence outputs/winrm_x.log
cmdr --finding low - "Verbose banner"      # '-' = no specific host
cmdr --findings                            # list, ordered by severity
cmdr --report engagement.md                # markdown report (hosts/findings/notes/history)
```

## Run History

```bash
cmdr --history          # recent runs (exit codes, host, command)
cmdr --history 50       # last 50
cmdr -r last            # re-run the most recent command (alias: cmdr -r !)
```

## Dangerous Commands

Mark destructive commands so they always prompt for confirmation — even under `-y`
or inside playbooks. They show a red `[!]` in `cmdr -s`.

```bash
cmdr -a wipe 'rm -rf {DIR}' ops --danger
cmdr -r wipe /data        # prompts "Run this command marked dangerous? (y/N)"
```

## Encrypted Workspaces

Encrypt a named workspace to a single blob at rest (uses `age`, falls back to
`gpg`). The plaintext directory is removed on lock and restored on unlock.

```bash
cmdr -w client-x                 # work in a named workspace
cmdr --lock-workspace client-x   # -> workspaces/client-x.cmdrlock, prompts passphrase
cmdr --unlock-workspace client-x # decrypt and restore
```

## Fuzzy Picker

```bash
cmdr --pick      # fuzzy-find a command with fzf and run it
cmdr             # bare invocation on a TTY also opens the picker (falls back to -m)
```

## Command Reference

### Core Commands

| Flag | Usage | Description |
|------|-------|-------------|
| `-a` | `cmdr -a <tag> <cmd> [cat] [--desc ..] [--alias ..] [--danger]` | Add a command |
| `-e` | `cmdr -e <tag> [cmd] [cat] [--desc ..] [--alias ..] [--danger]` | Edit a command |
| `-d` | `cmdr -d <tag> [-y]` | Delete (with confirmation) |
| `-s` | `cmdr -s` | Show all commands |
| `-r` | `cmdr -r <tag\|last> [args..] [@host] [--save] [--capture VAR] [--on host] [--all-hosts]` | Run a command |
| `-f` | `cmdr -f <keyword>` | Search commands |
| `-c` | `cmdr -c <tag> [args..]` | Copy to clipboard |
| `--pick` | `cmdr --pick` | Fuzzy-pick a command (fzf) |

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
| `--trust` | `cmdr --trust` | Trust the current dir's `.cmdr.json` |
| `--untrust` | `cmdr --untrust` | Revoke trust for the current dir's `.cmdr.json` |
| `--lock-workspace` | `cmdr --lock-workspace [name]` | Encrypt a named workspace at rest |
| `--unlock-workspace` | `cmdr --unlock-workspace <name>` | Decrypt a locked workspace |

### Hosts

| Flag | Usage | Description |
|------|-------|-------------|
| `--host add` | `cmdr --host add <ip> --name <n> [--hostname h] [--os o] [--user u] [--port p]` | Add/update a host |
| `--host list` | `cmdr --host list` | List hosts |
| `--host rm` | `cmdr --host rm <name>` | Remove a host |

### Findings & History

| Flag | Usage | Description |
|------|-------|-------------|
| `--finding` | `cmdr --finding <sev> <host> "title" [--evidence path]` | Record a finding |
| `--findings` | `cmdr --findings` | List findings |
| `--report` | `cmdr --report [file]` | Render a markdown report |
| `--history` | `cmdr --history [n]` | Show recent run history |

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

## Development & Testing

CMDR is plain Bash + `jq`, no build step. Lint and test before sending changes:

```bash
shellcheck -x -S warning cmdr.sh cmdr_functions.sh install.sh tests/run.sh
bash tests/run.sh
```

CI runs both on every push. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines
and [CHANGELOG.md](CHANGELOG.md) for release notes.

## License

[MIT](LICENSE) © SP1R4
