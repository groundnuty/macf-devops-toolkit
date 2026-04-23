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

## Notes for Opus 4.7+

Claude Opus 4.7 behaves differently from earlier models in ways that matter for autonomous work:

- **More literal instruction following.** The model does not silently generalize an instruction from one item to another, or infer requests you didn't make. Be explicit about scope. If you want a change applied across multiple files, say so.
- **Fewer subagents by default.** The model prefers direct reasoning over delegation. If you want subagent dispatch (e.g., feature-dev:code-reviewer, Explore), request it explicitly.
- **Fewer tool calls by default.** If a task seems underdone or reasoning seems shallow, don't prompt around it — check the `effortLevel` in settings.json. The template defaults to `xhigh` for agentic work. Lower values (low, medium) scope narrower.
- **Response length calibrated to complexity.** Short prompts get short answers; open-ended analysis gets long ones. If you need a specific verbosity, say so explicitly.
- **Cybersecurity safeguards may refuse** legitimate security work (penetration testing, red-teaming). For those use cases, apply to the Cyber Verification Program.

## Bash deny-rule coverage (Claude Code v2.1.113+)

Our `Bash(...)` deny patterns (sudo, `git push --force*`, `docker push *`, `rm -rf /`, `git commit --no-verify`) now match commands wrapped in common exec wrappers as of Claude Code v2.1.113: `env`, `sudo`, `watch`, `ionice`, `setsid`, and similar. So `env sudo rm -rf /` or `watch sudo docker push ...` are caught by our existing denies without us needing to enumerate every wrapped variant.

This is a Claude Code-level behavior change, not a template-level rule change — no action needed on your part, but worth knowing the surface area is wider than the literal patterns suggest.
