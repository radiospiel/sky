# CLAUDE.md — Agent Instructions

## Project-focused Guidance

For build commands, architecture, conventions, and other project-specific
instructions, see [CLAUDE.project.md](./CLAUDE.project.md). You MUST read this file.
Instructions in `CLAUDE.project.md` supersede conflicting instructions in `CLAUDE.md`.

# Skills

Agent skills are reusable, named workflows that the agent loads on demand. Each skill
lives in `sky/agents/skills/<name>/SKILL.md`. Skills accept arguments and define phased workflows (e.g. plan → approval → implement).

See `sky/agents/skills/` for available skills.

## Sky agent toolkit

This project uses the [sky](https://github.com/radiospiel/sky) agent toolkit as a git
submodule at `sky/`. It provides shared scripts, agent configurations, and workflow
guides that stay consistent across all participating repos. Full on the sky agent toolkit documentation lives at [sky/docs/sky.md](./sky/docs/sky.md). 

Sky comes with detailed guides on some specific concerns:

- Before starting any task, you must identify which strategy applies and follow its
  workflow. This document describes how:
  [Task Strategy Selection](./sky/docs/strategy-selection.md)

- For every non-trivial task, you must maintain a progress log.
  This document describes how:
  [Task Progress Logging](./sky/docs/task-logging.md)

- You must use stacked PRs by default, splitting work into independently reviewable
  units. This document describes how:
  [Stacked Pull Requests](./sky/docs/stacked-prs.md)

- When executing a plan built in plan mode, you must summarize it as an architectural
  design document. This document describes how:
  [Architectural Design Documents](./sky/docs/design-docs.md)

- You must keep the sky submodule up to date. This document describes what it provides
  and how:
  [Sky Submodule](./sky/docs/submodule.md)

- Pre-built plans are blueprints for complex tasks. This document describes how to
  load and execute them:
  [Plans](./sky/docs/plans.md)

- When adding, dropping, or modifying features, you must automatically document how
  users interact with these features. This document describes how:
  [Feature Documentation](./sky/docs/features.md)

# Conventions

## Markdown

- Do not hard-wrap paragraphs. Write each paragraph as a single line and let the renderer/editor soft-wrap it. The same applies to list items — one item per line, no mid-item line breaks. Code fences, tables, and headings are exempt.
