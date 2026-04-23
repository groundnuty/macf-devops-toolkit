# Verification before done

Applied before claiming any piece of work is complete.

## The gate

Before saying "done", Claude must verify, in order:

1. **Tests pass.** `make check` or the equivalent. All of them.
2. **Lint is clean.** Zero warnings.
3. **Types are clean.** If the language has a type checker, it passes.
4. **The feature actually works.** Exercise it. Type-checks alone do not prove correctness.
5. **Docs are updated.** If the change affects a documented API or config, update the doc.
6. **No uncommitted changes.** `git status` shows a clean tree.

## The `superpowers:verification-before-completion` skill

Reference it. It encodes this gate as a checklist.

## If verification fails

- **Do not rationalize.** "The test was already flaky" is not an answer.
- **Fix or flag.** Resolve or pause with a clear note about what's blocked.
- **Never commit a failure hoping someone else resolves it.**

## If verification tooling is missing

- If `make check` doesn't exist, flag it as a gap. Do not invent a different verification command.
- If the project has no tests, surface that. Do not claim "done" on an untested new feature.
