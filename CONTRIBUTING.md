# Contributing to CMDR

Thanks for your interest in improving CMDR! Contributions of all kinds are
welcome — bug reports, features, docs, and command packs.

## Getting started

```bash
git clone https://github.com/SP1R4/CMDR.git
cd CMDR
./install.sh        # or just run ./cmdr.sh directly
```

CMDR is plain Bash + [`jq`](https://stedolan.github.io/jq/). There is no build
step. Keep it dependency-light and POSIX-friendly where practical (the scripts
target Bash 3.2+ so they run on stock macOS as well as Linux).

## Before opening a pull request

Run the linter and the test suite — both must pass (CI runs the same):

```bash
shellcheck -x -S warning cmdr.sh cmdr_functions.sh install.sh tests/run.sh
bash tests/run.sh
```

If you add or change behavior, add matching assertions to `tests/run.sh`.

## Code style

- Match the surrounding style: 4-space indent, lowercase function names,
  `UPPER_CASE` globals, and a short comment above each function.
- All data writes go through a temp file + `mv` (atomic). Use `_mktemp_beside`.
- Quote variable expansions; prefer `[ ... ]` tests as used in the codebase.
- New user-facing flags need: argument parsing in `cmdr.sh`, a dispatch entry,
  help text (`display_help` / `display_subcommand_help`), tab completion in
  `cmdr_completion.bash`, and a line in `CHANGELOG.md`.

## Command packs

Packs live in `packs/<name>.json` as `{ "tag": { "command": "...",
"category": "..." } }`. Use `{TARGET}` / `{PORT}` style placeholders so commands
are parameterized. Send a PR adding your pack and a row in the README table.

## Reporting bugs / requesting features

Use the issue templates. For bugs, include your OS, Bash version
(`bash --version`), `jq --version`, and the exact command and output.
