# sky

A shared agent toolkit for Claude Code and OpenCode — scripts, configs, and
workflow guides maintained in one place and consumed as a git submodule.

## What's included

```
sky/
├── CLAUDE.md                           # Base Claude Code agent instructions
├── AGENTS.md                           # Base OpenCode instructions
├── install.sh                          # One-liner to set up sky in a project
├── .claude/
│   ├── settings.json                   # Shared Claude Code project settings
│   ├── settings.local.json.example     # Permissions template
│   ├── hooks/
│   │   └── session-start.sh           # Session-start hook (customizable)
│   └── skills/
│       └── auto-fix/
│           └── SKILL.md               # Auto-fix skill (plan → implement)
├── agents/
│   ├── strategy-guide.md              # Task strategy selection guide
│   └── logs-template.md               # Task progress log template
└── scripts/
    ├── git-stack-create               # Create stacked PR branches
    ├── git-stack-restack              # Sync stacked PRs after merges
    ├── cleanup-claude-sessions.sh     # Bulk-archive Claude Code sessions
    └── freeport.go                    # Find a free TCP port
```

## Quick start

Run this one-liner from the **root of your project**:

```bash
/path/to/sky/install.sh
```

Or if sky is already on GitHub:

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
| `cleanup-claude-sessions.sh` | Bulk-archive Claude Code web sessions |
| `go run sky/scripts/freeport.go` | Print a free TCP port |

## .claude/settings.local.json

This file contains Claude Code permissions and is **not tracked in git** (each
developer maintains their own). The installer creates it from the example
template. Review and customize it for your project's needs.
