# sky

A shared agent toolkit for Claude Code and OpenCode — scripts, configs, and
workflow guides maintained in one place and consumed as a git submodule.

## Quick start

Run this one-liner from the **root of your project**:

```bash
curl -sSL https://raw.githubusercontent.com/radiospiel/sky/main/install.sh | bash
```

The installer will:
1. Add sky as a git submodule at `sky/`
2. Symlink `CLAUDE.md`, `AGENTS.md`, and `.claude/` configs into your project
3. Add `sky/scripts` to your PATH via `.envrc`
4. Create `.claude/settings.local.json` from the bundled example

## How it works

**Submodule + symlinks.** Each consuming project has `sky/` as a git submodule.
Key config files (`CLAUDE.md`, `AGENTS.md`, `.claude/settings.json`, hooks, skills)
are symlinked from the project root into the submodule. When the submodule is
updated, all consumers pick up changes automatically.

**Project-specific instructions** go in `CLAUDE.md` and `AGENTS.md` below the
marked comment block — these files are symlinked but have a clearly delimited
section for project-local content. If you need fully independent CLAUDE.md or
AGENTS.md files, break the symlink and maintain them manually (referencing
`sky/` where useful).

## Keeping sky updated

```bash
cd sky && git pull origin main && cd .. && git add sky && git commit -m "chore: update sky"
```

## Scripts

With `sky/scripts` on your PATH, scripts also work as git subcommands:

| Command | Description |
|---------|-------------|
| `git stack-create [branch]` | Create a child branch + PR off the current branch |
| `git stack-restack` | Rebase and sync a whole stack after parent merges |

