<!-- Profile: code -->

## Profile: code

Code-centric work — writing and refactoring code. Language-agnostic baseline.

### Recommended next step: `/configure-ecc`

For language-specific reviewers and patterns (go-reviewer, python-reviewer, django-patterns, springboot-tdd, etc.), run the [`everything-claude-code`](https://github.com/affaan-m/everything-claude-code) plugin's interactive installer:

```
/configure-ecc
```

Pick only the skills/agents relevant to your language. This is opt-in — the template does not enable `everything-claude-code` by default because the full bundle (183 skills, 48 agents) is heavy.

### Devbox

This profile assumes [devbox](https://www.jetify.com/devbox) for toolchain management. If you prefer Nix flakes directly, or another toolchain manager, see `rules/devbox-usage.md` and adapt.

### Active profile-specific rules

- `writing-quality.md` (from info — still applies to code comments and docs).
- `makefile-conventions.md` — standard Make targets.
- `devbox-usage.md` — devbox idioms and CI.
- `testing-discipline.md` — TDD loop, coverage, test layout.
- `verification-before-done.md` — the "am I actually done?" gate.
