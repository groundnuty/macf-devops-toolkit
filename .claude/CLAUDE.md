# .claude for macf-devops-toolkit

Project-level Claude Code configuration for the MACF devops agent.

**Role + workflow:** see `rules/agent-identity.md` (auto-loaded).
**Cross-cutting coordination:** see `rules/coordination.md`, `peer-dynamic.md`, `pr-discipline.md`, `delegation-template.md` (all auto-loaded).
**Project overview + orientation:** see `../CLAUDE.md` at the workspace root.

## Active rule files

Loaded on every session (alphabetical):

- `agent-identity.md` — who you are, scope, per-repo workflow
- `autonomous-work.md` — how to behave unattended (from template)
- `content-invariants.md` — file-writing invariants (from template)
- `coordination.md` — canonical MACF cross-cutting rules (substrate copy)
- `delegation-template.md` — canonical 6-section issue template
- `devbox-usage.md` — devbox idioms (from template)
- `exploration-fast-track.md`, `exploration-folder-protocol.md` — template exploration rules
- `gh-token-refresh.md` — GH_TOKEN discipline
- `makefile-conventions.md` — Make targets (from template)
- `meta-governance.md` — rule-governance protocol (from template)
- `peer-dynamic.md` — canonical MACF peer-dynamic rule
- `pr-discipline.md` — canonical MACF PR-discipline rule (replaces template's version)
- `project-conventions.md` — per-project overrides (placeholder)
- `session-logging.md` — session log discipline (from template)
- `summary-parity.md` — summary ↔ diff parity (from template)
- `testing-discipline.md` — TDD loop (from template)
- `verification-before-done.md` — done-gate check (from template)
- `writing-quality.md` — prose conventions (from template)

## Substrate, not macf-consumer

This workspace is one of three **MACF substrate workspaces** (alongside `macf-science-agent` and `macf` / code-agent). Substrate = source of canonical patterns. This workspace does NOT run `macf init` / `macf update` / `macf rules refresh`. Rule files here are maintained manually; updates flow into `groundnuty/macf:packages/macf/plugin/rules/` only after proving themselves in substrate pair work.

If a rule here proves useful across sessions, propose promoting it to canonical via a PR on `groundnuty/macf`.
