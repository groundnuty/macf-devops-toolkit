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

This workspace is one of three **MACF substrate workspaces** (alongside `macf-science-agent` and `macf` / code-agent). Substrate = source of canonical patterns. This workspace does NOT run `macf init` / `macf update` / `macf rules refresh`. Rule files here are maintained manually; updates flow into `groundnuty/macf:packages/macf/plugin/rules/` only after proving themselves in substrate pair work.

If a rule here proves useful across sessions, propose promoting it to canonical via a PR on `groundnuty/macf`.
