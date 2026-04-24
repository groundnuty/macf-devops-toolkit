# macf-devops-toolkit

Home workspace for `macf-devops-agent[bot]` — the MACF project's devops agent. Sibling to `macf-science-agent[bot]` (orchestrator / design / paper) and `macf-code-agent[bot]` (framework TypeScript).

**Role + scope + workflow: see `.claude/rules/agent-identity.md`.**

**Cross-cutting coordination (issue lifecycle, peer dynamic, PR discipline, token hygiene): see `.claude/rules/coordination.md`, `peer-dynamic.md`, `pr-discipline.md`, `delegation-template.md`.**

## How work arrives

Via GitHub issues labeled `devops-agent` on:

- `groundnuty/macf-devops-toolkit` (this repo)
- `groundnuty/macf-science-agent`
- `groundnuty/macf`

The SessionStart hook polls all three queues and surfaces open issues as a prompt.

## Immediate orientation on fresh session

1. Read `.claude/rules/agent-identity.md` (auto-loaded alongside other rules).
2. Read `.claude/rules/coordination.md` for cross-cutting rules.
3. Run the queue check in §"Checking for Work" of `agent-identity.md`.
4. Pick up the highest-priority open issue. Read its body + comments fully.
5. If unclear, @mention the reporter on the issue and wait.

**Do NOT start speculative work without an issue.** If you think something needs doing that isn't on a queue, file an issue first (on the appropriate repo) and proceed once it has the `devops-agent` label.

## This repo's contents

This is the devops workspace. Contents grow as work lands:

- `.claude/` — rules, identity scripts, settings
- `claude.sh` — launcher (fail-loud token refresh + tmux session)
- `.github-app-key.pem` — GitHub App private key (gitignored)
- Future: helm values (`values/`), k8s manifests (`manifests/`), runbooks (`runbooks/`), terraform (`terraform/`), ops scripts (`scripts/`). Layout emerges per delivered issue.

## Related repos (read-only reference)

- `groundnuty/macf` — MACF framework source. Read `design/decisions/DR-*.md`, `packages/macf/plugin/rules/*.md`, `claude.sh` template for pattern reference. Never write here; file issues for `macf-code-agent[bot]`.
- `groundnuty/macf-science-agent` — design orchestrator's workspace. Read `research/2026-04-2*.md` (especially the four-doc observability cluster ending in `2026-04-23-helm-vs-compose-maturity-for-recommended-stack.md`) for the rationale behind any observability-related issue you get assigned.
