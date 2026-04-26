# Autonomous-work rules

Applied to every session. These govern Claude's behavior when operating without immediate human oversight.

## Core principles

- **Commit early and often.** Every logical unit of work ends in a commit with a clear message. Do not accumulate uncommitted changes across multiple subtasks — if an agent loses context, uncommitted work is lost.
- **Never force-push.** `git push --force` / `-f` / `--force-with-lease` are in the deny list. If history rewrite is truly needed, stop and surface it to the user.
- **Never `--no-verify`.** Pre-commit hooks exist for a reason. If a hook fails, fix the underlying issue, don't skip it.
- **Verify before claiming done.** Run the project's check command (test suite, linter, type checker, build) before stating that a task is complete. Use the `superpowers:verification-before-completion` skill when finishing any substantive work.

## When stuck or ambiguous

- **Stop. Write a note. Wait.** If a step is ambiguous, if evidence contradicts the plan, if a dependency is missing — do not guess forward. Write a short block in the session transcript explaining what is blocked and what information is needed. If working through a TaskList, mark the task `blocked` with the reason in its description.
- **Prefer surfacing over papering over.** Silent workarounds (suppressing linter rules, mocking what should be real, disabling tests) are prohibited in autonomous mode. Flag and pause.

## Escalation

If `settings.local.json` does not already allow an operation that appears genuinely necessary (e.g., reading a specific credential file for auth debugging), do not attempt to widen permissions by editing `settings.local.json`. Instead, surface the need and wait for user action.

## Session reporting

- The `PreCompact` hook archives the session transcript and prints a reminder to stderr. If you see that reminder and context is getting full, run `/session-report` manually before the compaction compresses history.
- The `SessionEnd` hook captures a final git-state snapshot to `.claude/session-reports/`.

## Model-era behavioral notes

See canonical `model-era-compatibility.md` (merged via macf#252) — Opus 4.7 specifics + Bash deny-rule wrapper coverage + maintenance template for future Claude releases. Origin context preserved in `groundnuty/macf-science-agent:insights/2026-04-26-substrate-evolution-analysis-cross-agent-convergence.md`.
