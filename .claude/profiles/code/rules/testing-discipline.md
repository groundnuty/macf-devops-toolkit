# Testing discipline

Applied to every code-writing session.

## TDD, not vibes

Every new feature or bug fix follows the TDD loop:

1. **Red**: write a failing test that captures the desired behavior.
2. **Green**: write the minimum implementation that makes it pass.
3. **Refactor**: tidy the implementation, re-run tests.
4. **Commit**: each cycle ends with a commit.

Reference: `superpowers:test-driven-development` skill.

## Coverage

Target **80%+ line coverage** for new code. Generate coverage: `make coverage` or language-specific tool.

## Test layout

- Mirror the source tree. `src/foo/bar.ts` <-> `tests/foo/bar.test.ts`.
- One behavior per test. Named `test_<what>_<condition>_<expected>`.
- Arrange / Act / Assert — three blocks, blank-line separated.

## Test isolation

- Tests do not depend on order.
- Tests do not depend on shared state.
- Tests do not hit the network. Use local mock servers.
- Tests do not require the developer's machine to be in a specific state.

## When a test is flaky

Do not rerun. Investigate. A flaky test is a real bug.

## Never

- `--no-verify` (deny-list).
- Commenting out a failing test "temporarily".
- Writing the test after the implementation and calling it TDD.
