# Task Progress Logging

Maintain a progress log in `agents/logs/` for each significant task. This provides
visibility into agent work and captures insights for future sessions.

Use the template at `sky/agents/logs-template.md`.

## Log file naming

`YYYYMMDD-HHMMSS-short-description.md` (e.g., `20250115-143022-fix-scroll-crash.md`)

## Complexity estimates

- **Simple**: Task could be completed without critical human feedback
- **Medium**: Planning stage was necessary, with important human feedback. Feedback after
  planning was mostly cosmetic.
- **Complex**: The initial plan was not sufficient; repeated human interventions were
  necessary.

Always include time-of-day in timestamps. Update the "Ended" timestamp when committing
work.

## When to log

- Create the log when starting a non-trivial task
- Update progress as you complete steps
- Always document obstacles, even if resolved quickly
- When task completes: finalize with outcome, update the header section

## Why obstacles matter

Documenting obstacles helps identify recurring issues, improves future estimates, and
provides context if the task is handed off or revisited.
