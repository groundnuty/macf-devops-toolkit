# .claude for macf-devops-toolkit

Project-level Claude Code configuration for the MACF devops agent.

**Role + workflow:** see `rules/agent-identity.md` (auto-loaded).
**Cross-cutting coordination:** see `rules/coordination.md`, `peer-dynamic.md`, `pr-discipline.md`, `delegation-template.md` (all auto-loaded).
**Project overview + orientation:** see `../CLAUDE.md` at the workspace root.

## Active rule files

Loaded on every session (alphabetical):

MACF identity layer:

- `agent-identity.md` — who you are, scope, per-repo workflow
- `coordination.md` — canonical MACF cross-cutting rules (substrate copy)
- `delegation-template.md` — canonical 6-section issue template
- `gh-token-refresh.md` — GH_TOKEN discipline
- `mention-routing-hygiene.md` — describing-vs-addressing handle discipline (canonical macf rule)
- `peer-dynamic.md` — canonical MACF peer-dynamic rule
- `pr-discipline.md` — canonical MACF PR-discipline rule

Behavioral discipline (distilled from science-agent + code-agent hard-won lessons, 2026-04-24):

- `verify-before-claim.md` — tool output beats memory; after every `gh` write operation, verify it landed; before ordering-claims, `gh pr view` the predecessor; before "root cause:", read the fix diff
- `check-before-propose.md` — grep existing convention before proposing a new shape; diff against a working consumer before claiming "pattern is broken"; read the file before writing code against remembered APIs
- `execute-on-directive.md` — after the user says "go"/"proceed"/"ship it", execute. Don't circle back to re-ask.

Template-origin rules (from `agentic-repo-template`, still applicable):

- `autonomous-work.md` — how to behave unattended
- `content-invariants.md` — file-writing invariants
- `devbox-usage.md` — devbox idioms
- `exploration-fast-track.md`, `exploration-folder-protocol.md` — exploration discipline
- `makefile-conventions.md` — Make targets
- `meta-governance.md` — rule-governance protocol
- `project-conventions.md` — per-project overrides (placeholder)
- `session-logging.md` — session log discipline
- `summary-parity.md` — summary ↔ diff parity
- `testing-discipline.md` — TDD loop
- `verification-before-done.md` — done-gate check
- `writing-quality.md` — prose conventions

## Substrate, not macf-consumer

This workspace is one of three **MACF substrate workspaces** (alongside `macf-science-agent` and `macf` / code-agent). Substrate = source of canonical patterns.

**It does NOT run `macf init` / `macf update`** — those rewrite the launcher and settings wholesale, and this workspace's `claude.sh` is operator-authored.

**It DOES receive canonical rules via `macf rules refresh --dir .`.** An earlier version of this section claimed rule files were "maintained manually" and that refresh was not run here. That was wrong, and it was costly: every file in `.claude/rules/` carries the `This file is managed by macf. Do not edit directly` header — they were distributed, not hand-written — and while the doc said the drift was intentional, they fell **194 lines behind canonical** in `silent-fallback-hazards.md` alone. Verified 2026-09-02 that a refresh is a pure upgrade here: the only local-only content was the managed header itself, so nothing hand-written was ever at risk.

**Direction of flow is still substrate → canonical for CONTENT.** A rule that proves useful here gets promoted by PR against `groundnuty/macf:packages/macf/plugin/rules/` — do not edit the local copy, it will be overwritten. What changed is the acknowledgement that the local copies are *copies*, kept current by the tool, rather than a separately-maintained set.

⚠ **`rules refresh` currently delivers RULES ONLY.** The published npm package omits `plugin/scripts/` (`macf#1403`), so it installs none of the PreToolUse guard scripts and reports success anyway. This workspace's guards are tracked in its own git and are unaffected; do not expect a refresh to repair a missing guard until 0.2.60+.

If a rule here proves useful across sessions, propose promoting it to canonical via a PR on `groundnuty/macf`.
