# CLAUDE.md — Agent Instructions

This project uses the [sky](https://github.com/radiospiel/sky) agent toolkit as a git
submodule at `sky/`. It provides shared scripts, agent configurations, and workflow
guides that stay consistent across all participating repos.

## Project-Local Guidance

For build commands, architecture, conventions, and other project-specific
instructions, see [CLAUDE.project.md](./CLAUDE.project.md). You MUST read this file. Instructions
in `CLAUDE.project.md` supersede conflicting instructions in the CLAUDE.md 

## Task Strategy Selection

Before starting any task, identify which strategy applies from `sky/agents/strategy-guide.md`:

- **Bug Fix**: Something is broken, unexpected behavior, errors
- **Feature (TDD)**: New functionality, "add X" requests
- **Refactoring**: Code quality improvements, restructuring
- **Performance**: Optimization, speed/memory issues

**Required workflow:**
1. State which strategy you're following and why
2. Follow that strategy's workflow from the guide
3. If uncertain, ask the human before proceeding
4. For mixed tasks, decompose and apply strategies separately

## Task Progress Logging

Maintain a progress log in `agents/logs/` for each significant task. This provides
visibility into agent work and captures insights for future sessions.

Use the template at `sky/agents/logs-template.md`.

**Log file naming:** `YYYYMMDD-HHMMSS-short-description.md` (e.g., `20250115-143022-fix-scroll-crash.md`)

**Complexity estimates:**
- **Simple**: Task could be completed without critical human feedback
- **Medium**: Planning stage was necessary, with important human feedback. Feedback after planning was mostly cosmetic.
- **Complex**: The initial plan was not sufficient; repeated human interventions were necessary.

Always include time-of-day in timestamps. Update the "Ended" timestamp when committing work.

**When to log:**
- Create the log when starting a non-trivial task
- Update progress as you complete steps
- Always document obstacles, even if resolved quickly
- When task completes: finalize with outcome, update the header section

**Why obstacles matter:** Documenting obstacles helps identify recurring issues, improves
future estimates, and provides context if the task is handed off or revisited.

## Stacked Pull Requests

Use **stacked PRs** by default. Unless the task is obviously a single concern, split it
into semantically meaningful, independently reviewable units that land as an ordered
chain of small PRs rather than one large PR — e.g. a refactor + a feature + a build
pipeline becomes three stacked PRs. Each PR in the stack must leave the repo green.

With `sky/scripts/` on your PATH (recommended: `PATH_add sky/scripts` in `.envrc`):

```bash
git stack-create [branch]    # create a child branch + PR off the current branch
git stack-restack            # sync the whole stack after a parent merges
```

Both commands require `GITHUB_TOKEN` or `GH_TOKEN` for GitHub API calls.

**Pushing changes:** do not rewrite published stack branches for ordinary changes — push
review fixes and follow-ups as new commits on top, with plain (non-force) pushes, so
collaborators' local checkouts keep fast-forwarding. PRs are squash-merged, so
commit-level tidiness comes from the merge, not from amending. Force pushes
(`--force-with-lease`) are reserved for restacking after a parent PR merges.

**Local checkouts of stack branches:** run `git config pull.rebase true` in your clone.
Restacks force-push rewritten history; with `pull.rebase` set, `git pull` replays only
your local commits onto the new tip (skipping already-applied ones).

## Architectural Design Documents

When you execute a plan that was explicitly built in plan mode, summarize that plan into
a markdown architectural document at `docs/design/<name>.md` as part of the
implementation. The `<name>` should match the plan's subject.

The design doc captures the *what* and *why* of the implemented system — context,
constraints, key decisions and their rationale, and the final shape of the code — so
future readers can understand the architecture without replaying the planning
conversation. Keep it concise and focused on decisions that aren't obvious from the code.

This applies only to plans deliberately built via plan mode, not to ad-hoc tasks.

## Sky Submodule

Keep the sky submodule up to date:

```bash
cd sky && git pull origin main && cd .. && git add sky && git commit -m "chore: update sky submodule"
```

The submodule provides:
- `sky/scripts/` — git-stack-create, git-stack-restack, cleanup-claude-sessions
- `sky/agents/` — strategy guide, log template
- `sky/.claude/` — shared hooks, skills config

