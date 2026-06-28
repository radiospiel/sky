---
name: auto-fix
description: Fix one or more GitHub issues or PRs in a two-phase workflow (plan, then implement). Pass issue/PR URLs or number ranges as arguments.
argument-hint: "<issue-url-or-range> [...]"
---

Fix the issues listed in: $ARGUMENTS

Work in two phases:

## Phase 1: Plan (wait for approval before proceeding)

For each issue:
1. Read the issue description (use `gh issue view` or `gh pr view`)
2. Identify the files that need to change
3. Describe the approach in 1-2 sentences
4. Flag anything ambiguous or where multiple approaches exist

Present the plan as a table:

| Issue | Files | Approach | Open questions |
|-------|-------|----------|----------------|

Also note any cross-issue dependencies or ordering constraints.

**Stop here and wait for the human to approve or adjust the plan.**

## Phase 2: Implement

After approval, implement all fixes:

- **One commit per issue.** Each commit message references the issue number.
- **Use existing patterns and helpers** rather than rolling your own — check the
  project's conventions first.
- **Run the full build and tests** before finishing.
- **Write an agent log** in `agents/logs/` using the template at `sky/agents/logs-template.md`.

When in doubt about where to put something (which layer, which abstraction, which
cache), ask — don't guess.
