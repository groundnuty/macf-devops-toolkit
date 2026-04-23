# PR discipline

## Commit message format

```
<type>: <description>

<optional body>
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`, `build`.

## Message body

- **Why, not what.** The diff shows what changed. The message explains why.
- **Reference spec / plan sections when applicable** — e.g., `(per Task 5 in docs/plans/<plan>)`.
- **No attribution footer.** User-global setting strips Co-Authored-By automatically.

## When to open a PR

- Feature complete and verified — all tests pass, all lints clean.
- Logical unit of work — don't bundle unrelated changes.
- PR title under 70 characters; use the body for detail.

## PR body structure

```markdown
## Summary
<1-3 bullets>

## Test plan
- [ ] <manual or automated check>
- [ ] <another>
```

## Never

- `git push --force` or any variant (blocked by the deny list).
- `git commit --no-verify` (blocked).
- Merging without tests passing (use `superpowers:verification-before-completion`).
