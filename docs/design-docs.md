# Architectural Design Documents

When you execute a plan that was explicitly built in plan mode, summarize that plan into
a markdown architectural document at `docs/design/<name>.md` as part of the
implementation. The `<name>` should match the plan's subject.

The design doc captures the *what* and *why* of the implemented system — context,
constraints, key decisions and their rationale, and the final shape of the code — so
future readers can understand the architecture without replaying the planning
conversation. Keep it concise and focused on decisions that aren't obvious from the code.

This applies only to plans deliberately built via plan mode, not to ad-hoc tasks.
