---
id: DR-002
title: Observability artifact bundles — per-scenario + per-issue snapshots
status: draft
date: 2026-04-26
participants:
  - macf-devops-agent[bot]
  - operator
supersedes: none
related:
  - groundnuty/macf-testbed#45 (testbed-side OTLP wiring; the verification cycle that surfaced this design need)
  - groundnuty/macf#245 (canonical claude.sh OTLP wiring)
  - groundnuty/macf-science-agent#3 (testbed-side scenario.run_id stamping)
  - DR-001 (ArgoCD GitOps for the obs-stack itself)
status_notes: |
  Design captured 2026-04-26 during a conversation between operator + devops-agent.
  Not yet filed as issues; awaits operator's pick of which 3 sub-points to focus on first.
  See "Implementation issue list" section below for the candidate issue set.
---

# DR-002: Observability artifact bundles — per-scenario + per-issue snapshots

## Context

The MACF observability stack (Tempo + Langfuse + Loki + ClickHouse-logs + Prometheus) is operational end-to-end as of `groundnuty/macf-devops-toolkit#28` and `#29` (both merged 2026-04-25 in PR #30). Synthetic OTLP verification confirms all 5 backends ingest data with full paper-dim resource-attribute fidelity (`gen_ai.agent.name`, `gen_ai.agent.role`, `agent.rules_variant`, `service.namespace`, etc.).

What the stack does NOT yet do: package per-work-unit observability data into self-contained artifacts that travel alongside the work's other deliverables (test-result PASS/FAIL files, GitHub issue/PR threads).

Two distinct work-unit types need this:

1. **Scenario runs** (testers driven by harness) — bounded by harness lifecycle; the `scenario.run_id` resource attribute is the natural join key.
2. **Long-running agent sessions** (substrate agents: devops/science/code working on issues + PRs) — no clean boundary; no scenario-id-equivalent; agent self-orchestration of boundary-stamping is fragile (LLMs are probabilistic; asking them to remember to mark work-unit edges is wishful thinking).

This DR captures the design discussion, the converged recommendation, and the implementation issue list — all derived during a single design conversation on 2026-04-26.

## Goal

Every "work unit" (scenario run or issue/PR resolution) produces a paper-evidence-grade observability bundle. The bundle is:
- **Self-contained**: independent of backend retention windows + reconfiguration
- **Reproducible**: same JSON shape across work-unit types
- **Citeable**: stored at a stable URL (archive repo path)
- **Discoverable**: linked from the originating GitHub issue/PR thread

## Two trigger paths

### Path 1: per-scenario (tester) bundles

**Trigger**: harness post-run finalizer — the harness already controls scenario lifecycle and knows the `scenario.run_id` it's stamping.

**Filter**: `{scenario.run_id="<run_id>"}` across the 5 backends.

**Time window**: scenario start → scenario end, recorded by the harness.

**Output**: bundle written to `artifacts/runs/<run_id>/` alongside the existing harness `result.json`.

### Path 2: per-issue/PR (substrate agent) bundles

**Trigger**: GitHub Action on `issues: closed` or `pull_request: closed` event in any of the 5 macf repos.

**Filter**: `{gen_ai.agent.name="<actor>"}` where `actor` = the agent who closed the issue / merged the PR.

**Time window**: derived from GitHub's event stream for the issue (NOT a naive `created_at`/`closed_at` span — see "GitHub-event enrichment" below).

**Output**: bundle pushed to a separate archive repo + summary comment posted on the closed issue/PR.

## Boundary inference for substrate agents (the load-bearing design call)

### What we rejected

**Asking agents to stamp work-unit boundaries (e.g., `work.issue_id=24` set mid-session via OTEL_RESOURCE_ATTRIBUTES updates)**. Rejected because:
- LLMs are probabilistic; they will forget, drift, miss edge cases
- Multi-tasking across issues makes boundaries fuzzy by nature
- Agent self-discipline as a system requirement is fragile

### What we considered

**Deterministic in-process PreToolUse hooks** that auto-stamp resource attrs based on tool patterns (`gh issue view N` → set; `gh issue close N` → unset). Considered but rejected for v1 because:
- Same signal hooks would parse from local tool calls is mirrored in GitHub's event stream
- Hooks miss work that doesn't trigger pattern-matching tool calls (e.g., pure code edits, conversational work, externally-routed pings before any `gh`)
- Hook complexity (state tracking, pattern parsing, syntax-evolution maintenance) buys precision only on edge cases

### What we picked: GitHub-event-driven enrichment

**Operator's insight (2026-04-26)**: anything an agent does via `gh`/`git` write actions is mirrored in GitHub state with a timestamp. So the deterministic boundary signals hooks would use are ALREADY available in GitHub's event stream — no in-process hooks needed.

For each issue/PR, GitHub provides an event stream:
- `issue.created_at` / `closed_at`
- Comments (with author + timestamp)
- Label changes, status changes (with actor + timestamp)
- Linked PR creation, reviews, merges
- Commit references via PR

**Snapshot algorithm for issue #N closed by agent A:**
1. `gh api repos/<owner>/<repo>/issues/<N>/timeline` → list of (actor, timestamp) events
2. Filter to events where `actor == A`
3. Build the union of small windows around each event (e.g., `[t - 5min, t + 5min]`)
4. Query each backend for A's spans/metrics/logs falling inside the union
5. Bundle

This is sharper than naive `[created_at, closed_at]` for long-living issues (collapses idle gaps) AND requires zero agent-side cooperation (no hooks, no resource-attr stamping, no agent discipline). It also handles multi-issue interleave: each issue's events define its own window union; agent activity at time T contributes to whichever issue had an event near T.

**Trade**: GitHub-event enrichment misses purely investigative activity that never produces a write action (`gh issue view` only, no comment / no commit / no close). For agents that read but never write, there's nothing on the GitHub side AND nothing arguably worth bundling either. The "loss" coincides with the case where bundling is moot.

**Hooks remain a future precision upgrade** if/when bundle fuzziness in practice creates a real problem (e.g., per-cell aggregation queries get noisy from cross-issue contamination). Land enrichment first; data tells us if hooks are worth the complexity.

## Reachability

Initial design assumed self-hosted runner needed (GH-hosted runners can't reach localhost ports on the cluster's VM). **Operator corrected**: this VM is on Tailscale; GH-hosted runners can join the tailnet via `tailscale/github-action@v2` and reach the VM directly.

Two viable patterns post-Tailscale-join:

**(A) SSH to VM, run snapshot script there, scp results back** — cleanest, fewest moving parts. Mirrors the operator's existing laptop-kubectl-via-SSH-tunnel pattern. Snapshot logic stays VM-side using existing `make pf-*` patterns.

**(B) Direct kubectl over tailnet** — needs k3d API + obs endpoints bound to tailnet IP (currently 127.0.0.1-only). More setup, lighter coupling.

**Recommended: A** for v1. Single SSH key in `actions/secrets`, runner is essentially a remote-procedure-trigger, all logic stays in the same VM-side `hack/` scripts.

## Bundle layout (per work unit)

```
artifacts/<scope>/<id>/
├── result.json                     # existing harness PASS/FAIL (scenarios) OR
│                                   # GitHub event summary (issues)
├── manifest.json                   # run metadata: cell, agents, env, start/end times
└── observability/
    ├── traces-tempo.json           # Tempo /api/search?tags=<filter>
    ├── traces-langfuse.json        # Langfuse /api/public/traces filtered
    ├── logs-loki.json              # Loki query_range with filter stream
    ├── logs-clickhouse.json        # CH SELECT FROM logs.otel_logs WHERE <filter>
    ├── metrics-prom.json           # Prometheus range queries over [start, end]
    └── grafana-urls.json           # pre-filtered Grafana Explore URLs (live click-through)
```

For per-scenario: `<scope>` = `runs`, `<id>` = `scenario.run_id`.
For per-issue: `<scope>` = `work/<repo>`, `<id>` = `<issue_number>`.

## Comment shape (for per-issue bundles)

```markdown
## 📊 Observability bundle for #24

**Window**: 2026-04-25 15:30:11 → 2026-04-26 00:39:04 (9h 9m, derived from 12 GitHub events)
**Agent**: `macf-devops-agent` ← agent-name resource attr filter

### Summary
| Backend | Count | Notes |
|---|---|---|
| Tempo | 18 traces | Avg duration 4.3s, all `claude_code.interaction` |
| Langfuse | 18 GENERATION observations | Total tokens: 47,210 in / 8,234 out; cost $0.0681 |
| Loki | 1,247 log records | severity_text breakdown: INFO 1,239 / WARN 8 / ERROR 0 |
| ClickHouse | 1,247 rows | (mirrors Loki — both backends parallel) |
| Prometheus | 4 metric series | claude_code_session_count_total{...} etc. |

### Drill-in (Grafana, pre-filtered)
- 🔍 [Tempo traces](http://...)
- 📜 [Loki logs](http://...)
- 📈 [Prometheus claude_code_*](http://...)
- 💬 [Langfuse traces](http://...)

### Full bundle
JSON snapshot: [groundnuty/macf-observability-archive/runs/macf-devops-agent/2026/04/26/24/](https://github.com/...)

🤖 Auto-generated by [observability-snapshot.yml](.github/workflows/observability-snapshot.yml)
```

## Storage of full bundles

Decision: **separate archive repo** `groundnuty/macf-observability-archive`.

Considered alternatives:
- GH Actions artifact (90d retention, fragmented across runs) — rejected; not paper-grade
- MinIO bucket (in-cluster; no GH dep) — rejected; not paper-ready, separate access path
- Inline in issue comment (zero infra) — rejected; comment-size limits, messy threads

Archive repo benefits:
- Git-tracked (immutable, diffable, version-history)
- Searchable via `git log` + `grep`
- Can be made public for paper supplementary materials
- Standard GitHub auth model

## Bundle size estimates

Measured from real tester-2 data on the live cluster:

Per `claude_code.interaction` trace (Claude Code's OTLP emission):
- Tempo: ~4 KB / 2 spans
- Langfuse: ~6 KB / 2 observations
- Combined per turn: ~10 KB metadata

**Critical finding**: Claude Code's OTLP emission ships **metadata only** (timing, names, resource attrs, span linkage) — NOT the prompt/completion text. `tokens=0` in the Langfuse observations; Langfuse can't compute token usage or cost from this. Worth filing as a separate issue: `gen_ai.usage.input_tokens` / `output_tokens` aren't propagating through Claude Code's OTLP integration.

Extrapolation to a 900k-token session (80–250 turns):

| Component | Per turn | × 80 turns | × 250 turns |
|---|---|---|---|
| Tempo + Langfuse (metadata only) | ~10 KB | 0.8 MB | 2.5 MB |
| Loki + ClickHouse logs (sparse INFO) | ~5 KB | 0.4 MB | 1.3 MB |
| Prometheus (cumulative) | — | <50 KB | <100 KB |
| **Total raw bundle** | | **~1.3 MB** | **~4 MB** |
| **Compressed (gzip on JSON)** | | ~0.5 MB | ~1.5 MB |

So **expect 1–4 MB raw, ~0.5–1.5 MB compressed** for the per-issue bundle from a 900k-context session. An archive accumulating 1000 such bundles = ~1–2 GB compressed. Comfortably under any GitHub repo size limits.

If full prompt/completion logging (`gen_ai.prompt`/`gen_ai.completion` attrs) is ever wired by Claude Code or by us, the size estimate inflates 10–100×. The bundle architecture should anticipate this; current Claude Code default has the cap.

## Implementation issue list (candidates; not yet filed)

**Path 1 (per-scenario):**
- `groundnuty/macf-devops-toolkit#X` — devops: write `hack/observability-snapshot.sh` (takes `--filter`, `--start`, `--end`, `--out-dir`)
- `groundnuty/macf-testbed#Y` — code-agent: integrate snapshot script into harness post-run finalizer

**Path 2 (per-issue):**
- `groundnuty/macf-devops-toolkit#Z` — devops: snapshot-script extension to take a GitHub issue ref + compute window union from `gh api .../timeline`
- `groundnuty/macf-observability-archive` (new repo) — operator action: create + grant write access to runner's auth identity
- `.github/workflows/observability-snapshot.yml` per macf repo (5 instances) — devops: workflow definition; checks out via Tailscale + SSH, runs script, pushes archive, posts comment
- Tailscale OAuth client in `groundnuty` org → org-level GH secret — operator action

**Cross-cutting:**
- Token-usage gap: `gen_ai.usage.*` not flowing from Claude Code → `groundnuty/macf` candidate issue (canonical claude.sh / wrapper investigation; possibly upstream Claude Code SDK question)

**Common dependency (already done):**
- ✓ Stack-side wiring (`groundnuty/macf-devops-toolkit#28`/`#29`, merged in PR #30)
- ✓ Per-substrate-agent OTLP wiring (devops: PR #25 + #27; science: commit `e2f074b`; testbed: PR #48; canonical: PR #246)
- ✓ Tester-side launcher fix (`groundnuty/macf-testbed#45`, closed)

## Operator's next decision

Three points to focus on (operator-pick) — see conversation following this DR.

## Appendix — alternatives explored + rejected

### Tool-pattern PreToolUse hooks (rejected for v1)

Considered: PreToolUse hook intercepts each tool call; on `gh issue view 24` stamps `work.issue_id=24` for subsequent emissions. Rejected because the same signals are mirrored in GitHub events (write actions); enrichment captures ~95% of what hooks would; hooks add complexity (parsing tool args, state tracking, pattern-set maintenance) for marginal precision on edge cases. Hooks remain available as a future precision upgrade if enrichment-fuzziness-in-practice causes problems.

### Asking agents to stamp work boundaries (rejected as wishful)

Considered: agents set `OTEL_RESOURCE_ATTRIBUTES` to add `work.issue_id=N` on routed pickup. Rejected because LLMs are probabilistic — they will forget, drift, miss edge cases. Substrate-agent observability shouldn't depend on agent discipline.

### Live-URL-only bundle (rejected as not paper-grade)

Considered: bundle contains only Grafana Explore URLs, no JSON snapshots. Rejected because backends rotate/restart/lose retention; paper-evidence claims need self-contained artifacts that survive infra churn.

### Self-hosted GitHub runner (rejected after Tailscale operator-correction)

Considered: GH-hosted runners can't reach VM-localhost ports → install self-hosted runner on the VM. Rejected after operator surfaced that this VM is already on Tailscale + GH-hosted runners can join via `tailscale/github-action@v2`. The single piece of infra (Tailscale OAuth client) replaces the per-repo runner registration + maintenance overhead.
