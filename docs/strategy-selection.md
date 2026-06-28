# Task Strategy Selection

Before starting any task, categorize it:

| Task Type | Key Indicators |
|-----------|----------------|
| **Bug Fix** | Something is broken, unexpected behavior, error reports |
| **Feature (TDD)** | New functionality, user-facing capability, "add X" |
| **Refactoring** | Code quality, restructuring without changing behavior |
| **Performance** | Slow operations, memory issues, optimization requests |

If uncertain which strategy applies, ask the human for clarification before proceeding.

## Bug Fixing Strategy

**Goal**: Fix the defect while maintaining existing behavior elsewhere.

1. **Reproduce the bug** — understand the reported behavior, create a minimal reproduction case, write a failing test
2. **Locate the root cause** — trace from symptom to source, verify with debugging, document before fixing
3. **Implement the fix** — make the minimal change that fixes the issue, avoid unrelated changes
4. **Verify no regressions** — run the full test suite, manually test related functionality
5. **Document** — commit message explains what was broken and why, link to issue if one exists

**Anti-patterns**: fixing symptoms instead of root causes, unrelated changes in the same commit, skipping the reproduction test.

## Feature Development Strategy (TDD)

**Goal**: Add new functionality with confidence through test-driven development.

1. **Understand requirements** — clarify expected behavior, identify edge cases, define acceptance criteria
2. **Write failing tests first** — start with the simplest case, each test fails for the right reason
3. **Implement incrementally** — minimal code to pass each test, keep the red-green-refactor cycle tight
4. **Refactor within green** — only refactor when all tests pass, improve structure without changing behavior
5. **Integration testing** — test the feature in context with existing code and real data
6. **Manual verification** — test with actual clients or fixtures

**Anti-patterns**: writing implementation before tests, writing too many tests at once before implementing, skipping refactoring, gold-plating.

## Refactoring Strategy

**Goal**: Improve code structure without changing observable behavior.

1. **Ensure test coverage** — verify existing tests cover the code, add characterization tests if needed
2. **Define the target structure** — identify what's problematic, sketch desired end state, break into small steps
3. **Make incremental changes** — each commit leaves tests passing, use mechanical transformations (extract, inline, rename)
4. **Verify continuously** — run tests after each transformation, revert and try smaller steps on failure
5. **Clean up** — remove dead code, update documentation, ensure consistent naming

**Anti-patterns**: refactoring without tests, mixing behavior changes, big-bang rewrites, refactoring code you don't understand.

## Performance Improvement Strategy

**Goal**: Measurably improve performance without breaking functionality.

1. **Establish baseline measurements** — profile before optimizing, identify the actual bottleneck with data
2. **Set concrete targets** — define "fast enough," get agreement on trade-offs, ensure targets are measurable
3. **Analyze the bottleneck** — use profiling tools, understand why code is slow, consider algorithmic vs. implementation issues
4. **Implement optimization** — change one thing at a time, measure after each change
5. **Verify correctness** — run full test suite, performance optimizations often introduce subtle bugs
6. **Document the improvement** — record before/after measurements, explain the approach, note trade-offs

**Anti-patterns**: optimizing without profiling, premature optimization, sacrificing readability for marginal gains, optimizing before correctness is established.

## Mixed Tasks

Some tasks combine multiple strategies. Handle them by:

1. **Decompose** the task into distinct sub-tasks
2. **Identify** the strategy for each sub-task
3. **Order** by dependencies: Bug Fix → Refactoring → Feature → Performance
4. **Execute** sequentially, completing each strategy before starting the next
5. **Commit separately** to keep history clean and reversible
