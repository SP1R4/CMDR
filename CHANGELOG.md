# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.1.0]

### Added
- **Output capture → chaining**: `cmdr -r <tag> --capture VAR[:regex]` stores a
  command's stdout into a workspace env var for use by the next command.
- **Host/target model**: `cmdr --host add/list/rm`. Selecting a host with
  `@name`, `--on`, or `--all-hosts` fills `{TARGET}`/`{RHOST}`/`{RHOSTNAME}`/
  `{OS}`/`{RUSER}`/`{RPORT}`.
- **Remote execution**: `cmdr -r <tag> --on <host>` runs over SSH.
- **Placeholder forms**: `{VAR:=default}` and `{VAR:?}` (required) in commands.
- **Findings & reporting**: `--finding`, `--findings`, and a markdown
  engagement report via `--report [file]`.
- **Run history**: `--history [n]` and re-run with `cmdr -r last` (alias `-r !`).
- **Encrypted workspaces**: `--lock-workspace` / `--unlock-workspace` encrypt a
  named workspace at rest using `age` (falls back to `gpg`).
- **Dangerous commands**: `--danger` marks a command so it always confirms
  before running, even under `-y`.
- **Fuzzy picker**: `--pick` (and a bare `cmdr` on a TTY) to fuzzy-find a
  command via `fzf`, falling back to interactive mode.
- `starter` command pack and an in-repo test suite (`tests/run.sh`) + CI.

### Changed
- Writes are now atomic on all filesystems (temp file created beside the target
  for a same-filesystem rename instead of `/tmp`).
- Locking uses a portable `mkdir` lock (no `flock` dependency; works on macOS)
  and is scoped to mutating actions only, so reads/runs never block other
  terminals.
- `cmdr -r` (and chains/playbooks) propagate the command's real exit code.
- Project-local `.cmdr.json` files are **trust-gated** (content-hash pinned);
  editing a trusted file revokes trust until re-approved.

### Fixed
- Workspace names are sanitized to prevent path traversal.
- macOS Bash 3.2 compatibility (removed `mapfile` usage).
- Display columns no longer misalign when optional fields are empty.

## [3.0.0]
- Initial public release: command store with tags/aliases/categories,
  workspaces, environment variables, playbooks, chains, notes, output capture,
  command packs, project-local commands, tab completion, dry-run, and undo.
