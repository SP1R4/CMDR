# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.2.0]

### Added
- **Workflow engine** (`--flow run|list|import|show`): JSON workflows of
  conditional, capturing, retrying, optionally-parallel steps. Steps support
  `run`, `args` (incl. `@host`), `when`, `capture`, `register`, `retry`,
  `timeout`, `remote`, `continue_on_error`, and `parallel` blocks. Safe
  condition DSL (`env:`/`step:` with `== != contains matches exists`, joined by
  `&& / ||`, negatable). Honors dry-run.
- **Secrets** (`--secret`, `--secrets`, `--secret-clear`): map `{NAME}` to a
  provider (`pass`/`cmd`/`env`/`age`/`file`). Resolved only at execution time,
  so secrets never appear in the stored command, run history, or the on-screen
  command line. Clipboard copy resolves them (for pasting).
- **`--lint`**: validates command stores, packs, and workflows (JSON, empty
  commands, bad tag names, unbalanced placeholders, unknown workflow step refs).
- **Report formats**: `--report` infers format from the file extension or
  `--format md|csv|html|pdf`. CSV exports findings; HTML/PDF via pandoc.
- **Git-backed sync** (`--sync [msg]`, `--sync-remote <url>`): version/share the
  data dir; refuses to run against the CMDR install directory.
- **`@host` tab completion** and completion for workflows/secrets/formats.

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
- Dry-run (`-n`) never prompts for missing placeholders; it shows `<name>`
  for the gap instead of blocking.

## [3.0.0]
- Initial public release: command store with tags/aliases/categories,
  workspaces, environment variables, playbooks, chains, notes, output capture,
  command packs, project-local commands, tab completion, dry-run, and undo.
