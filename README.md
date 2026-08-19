# agents_config

Single source of truth for specialist agent prompts and orchestration rules. The
`agents_config` installer syncs canonical agent definitions from this repo into
the global config directories of Cursor, OpenCode, Gemini (Antigravity), Codex,
and Pi.

Canonical agent files live in [`agents/`](agents/). Shared orchestration rules
live in [`AGENTS.md`](AGENTS.md). The installer never edits those files — it
symlinks or generates tool-specific copies in each tool's config directory.

## Prerequisites

- **Ruby** — the installer uses stdlib only (`fileutils`, `json`, `optparse`, `yaml`); no
  `bundle install` required
- **Stable repo path** — clone or place this repo at a fixed location (e.g.
  `~/agents_config`); symlinks and generated files reference it

## Quick start

```bash
# Install for one tool
ruby ~/agents_config/bin/agents_config cursor

# Install for all supported tools
ruby ~/agents_config/bin/agents_config --all

# List targets and their config paths
ruby ~/agents_config/bin/agents_config --list

# Show help
ruby ~/agents_config/bin/agents_config --help

# Remove installed artifacts
ruby ~/agents_config/bin/agents_config cursor --remove

# Remove + delete empty leftover dirs
ruby ~/agents_config/bin/agents_config cursor --remove --prune

# Remove from every target
ruby ~/agents_config/bin/agents_config --all --remove
```

**Optional:** add the script to your `PATH` so you can run `agents_config`
directly:

```bash
ln -sf ~/agents_config/bin/agents_config ~/.local/bin/agents_config
```

## Supported targets

| Target | Config directory | Install behavior |
|--------|------------------|------------------|
| `gemini` | `~/.gemini/config` | Symlink `AGENTS.md`; generate `agents/<name>.md` with Gemini frontmatter (`name`, `description`, `model`, `subagent`) |
| `opencode` | `~/.config/opencode` | Symlink entire `agents/` directory and `AGENTS.md` (read-through, no transform) |
| `cursor` | `~/.cursor` | Symlink `AGENTS.md`; generate `agents/<name>.md` with Cursor frontmatter (`name`, `description`) |
| `codex` | `~/.codex` | Symlink `AGENTS.md`; generate `agents/<name>.toml` with TOML fields (`name`, `description`, `developer_instructions`) |
| `pi` | `~/.pi/agent` | Symlink `AGENTS.md`; generate frontmatter-first `agents/<name>.md` for the optional pi-sub-agent extension, with each model from `opencode.json` |

### Symlink vs generated

- **OpenCode** uses direct symlinks. Edit canonical files in this repo and changes
  are live immediately — no re-run needed.
- **Gemini, Cursor, Codex, and Pi** write generated files marked with
  `# agents_config:generated`. **Re-run install after editing**
  canonical `agents/*.md` to regenerate derived files. Pi places its marker just
  after YAML frontmatter so its parser still sees frontmatter first.

### Pi models

Pi agent model assignments are sourced exclusively from checked-in
[`opencode.json`](opencode.json), at `agent.<canonical-agent-name>.model`. Every
canonical agent must have a non-empty string model there; Pi installation fails
before replacing its legacy `agents/` symlink if that configuration is invalid or
incomplete. The installer also generates Pi's `models.json` from
`provider.ollama.options.baseURL` and the referenced `provider.ollama.models`,
using Pi's OpenAI-compatible Ollama provider format. It intentionally excludes
OpenCode permissions, plugins, and MCP configuration.

Pi's `agents/` directory is installer-managed and contains generated Markdown
plus an ownership marker. Do not hand-edit these files; edit canonical agents or
`opencode.json`, then rerun the installer.

## Day-to-day workflow

1. Edit canonical files in [`agents/<name>.md`](agents/) or [`AGENTS.md`](AGENTS.md).
2. Re-run `agents_config <target>` (or `--all`) to push changes to tools that
   use generated files.
3. Do not edit generated files in tool config directories — changes will be
   overwritten on the next install.

### Canonical frontmatter

Agent files use YAML frontmatter. Common keys:

| Key | Purpose |
|-----|---------|
| `name` | Required by Pi; must match the agent filename stem |
| `description` | Propagated to all targets |
| `mode` | `primary` (e.g. orchestrator) or `subagent` — affects Gemini `subagent` field |
| `permission` | OpenCode-only; dropped for other targets |

The canonical frontmatter does not set a generic `model`: that would affect
Gemini. Pi's `model` is injected only into its generated files from
[`opencode.json`](opencode.json).

Example canonical file:

```yaml
---
name: sprinter
description: "Fast implementation engineer for small, direct, reviewable code changes."
mode: subagent
---
You are Sprinter, a fast implementation engineer.
...
```

## Safety behavior

The installer is designed to be safe to re-run and conservative about deleting
files:

- **Idempotent** — re-running install is safe; unchanged generated files are
  skipped.
- **Clobber protection** — if a real (non-generated) file/directory or a foreign
  symlink already exists at a destination, the installer skips it and prints a warning.
- **Selective removal** — `--remove` only deletes symlinks pointing into this
  repo or files marked `# agents_config:generated`.
- **Hand-edited files** — generated files edited without the marker are never
  overwritten or deleted. Back them up, then use `--remove` if you want a clean
  reinstall.

## Running tests

Tests run in a throwaway temp `HOME` so your real tool configs are never touched:

```bash
ruby ~/agents_config/bin/agents_config_test.rb
```

## Adding a new target

To support another tool, add an entry to `TARGETS` and a `build_*` function in
[`bin/agents_config`](bin/agents_config), then register it in `BUILDERS`. Each
artifact is either a `:symlink` (read-through) or `:generate` (transform
frontmatter/body into a tool-specific format). See the existing `build_gemini`,
`build_opencode`, `build_cursor`, and `build_codex` functions for the pattern.
