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

This is the devops workspace. Layout follows `groundnuty/onedata/spice-deployments` conventions (see `design/DR-001-argocd-gitops-for-observability-spike.md`):

- `.claude/` — rules, identity scripts, settings
- `claude.sh` — launcher (fail-loud token refresh + tmux session, with `sg docker -c` wrapper for the docker-group inheritance issue on this host's stale tmux)
- `.github-app-key.pem` — GitHub App private key (gitignored)
- `design/DR-NNN-*.md` — Design Records. Non-trivial decisions land here BEFORE the implementation PR (per `feedback_design_and_research_folders.md` memory).
- `research/YYYY-MM-DD-*.md` — investigation findings, dated. Live-fetch chart versions before pinning (see `feedback_verify_devops_versions.md`).
- `environments/<env>/` — per-env stack. Currently: `macf` only.
  - `apps/*-app.yaml` — argocd `Application` CRs, sync-wave annotated
  - `values/*.yaml` — helm values referenced via `$values/` multi-source pattern
  - `manifests/<component>/*.yaml` — raw k8s manifests applied alongside (Collector CR, Tempo datasource, etc.)
  - `k3d/{config,version}.yaml` — declarative k3d cluster config (host-port mappings, k3s image pin)
  - `Makefile` (thin) + `devbox.json` (helm, kubectl, k3d, grpcurl, yq-go, jq pinned)
  - `hack/*.sh` — operator scripts (smoke, langfuse-bootstrap)
- `environments/Makefile` — shared parent Makefile; child envs `include ../Makefile`. **`make` is the operational interface** — every casual op is a target (per `feedback_devbox_makefile_interface.md`).

## Cluster topology + standard endpoints (live)

A k3d cluster named `macf` runs on this VM, managed via argocd-driven GitOps. Key endpoints:

| What | URL | Notes |
|---|---|---|
| **Stable OTLP HTTP** | `http://127.0.0.1:14318/v1/traces` | No port-forward needed — host-port-mapped via k3d serverlb to the `central-collector-lb` LoadBalancer Service. Testers + smoke scripts use this. |
| **Stable OTLP gRPC** | `127.0.0.1:14317` | Same routing |
| **Tailnet OTLP HTTP** (remote agents) | `http://<machine>.<tailnet>.ts.net:14318/v1/traces` | Requires `make tailscale-otlp-up` once on VM. Same path as stable but reachable from off-VM agents. See `docs/remote-agent-otlp-setup.md`. |
| Grafana UI | `make pf-grafana` → `http://127.0.0.1:3000` | port-forward; password via `make grafana-password` |
| Tempo query API | `make pf-tempo` → `http://127.0.0.1:13200` | port-forward; smoke.sh's Tempo leg uses this |
| Langfuse UI | `make pf-langfuse` → `http://127.0.0.1:3001` | port-forward; admin login printed by `make langfuse-bootstrap` |
| ArgoCD UI | `make pf-argocd` → `http://127.0.0.1:8080` | port-forward; password via `make argocd-password` |

Persistent state lives on `/mnt/volume1` (`/dev/vdb`, ~200 GiB) — never the root disk. k3d registry data + cluster PVCs both bind-mount there. See `feedback_use_mnt_volume1_for_heavy_storage` memory.

## Bootstrap flow summary

First-install on a fresh VM:

```
cd environments/macf
devbox install                 # pull pinned tools
sudo usermod -aG docker ubuntu # ONE-TIME if not already (and tmux kill-server to pick up)
make doctor                    # preflight
make all                       # = make cluster + make argocd-bootstrap
                               # argocd reconciles all charts; Langfuse pods CrashLoop on missing Secrets
make langfuse-bootstrap        # autonomous: generates 6 Secrets, runs init, prints admin login
make smoke                     # OTLP round-trip — Tempo + Langfuse legs
```

`make langfuse-bootstrap` is **destructive on re-run** — rotates ALL secrets (DB passwords + API keys). Run once per fresh install. The script truncates init-state tables before restart to handle salt-skew on legitimate re-runs (see `reference_langfuse_bootstrap_salt_skew` memory for the gotcha + paste-ready verification commands).

## Operational patterns to know

- **Argocd's root-app reverts feature-branch retargets.** When validating a feature-branch's manifest changes against the live cluster, `kubectl patch app <X> --type merge -p '{"spec":{"source":{"targetRevision":"feat/..."}}}'` works for one reconcile cycle then root-app reverts to `HEAD`. Either suspend root-app sync briefly OR just push + merge + let argocd pick up from main. Spike-mode acceptable; goes away once the PR merges.
- **Helm chart values vs argocd's actual rendering** — when a values key doesn't render into the deployed manifests, suspect:
  - The chart version doesn't support the values key yet (e.g. `additionalEnvFrom` is on chart-main but not 1.5.27 — caught during PR #12).
  - The path is at `langfuse.web.pod.<key>` (web-only) vs `langfuse.<key>` (all deployments).
  - Always verify via `helm template <release> <chart> --version <ver> --values <file>` before committing.
- **Stale tmux + docker group**: this host's tmux server predates the ubuntu→docker group membership. Wrap docker-touching commands in `sg docker -c "..."` until tmux-server is restarted. `claude.sh` handles this for new-launched sessions automatically. See `reference_docker_sg_workaround_stale_tmux` memory.
- **Compose stack on the same VM** (`macf-obs-*`) still binds `:4317/:4318/:3200` from the previous-generation observability rollout. Cluster's stable endpoint uses `:14317/:14318/:13200` to avoid collision. Eventually the compose stack gets retired (post-#11 closure) via a cleanup PR on `groundnuty/macf-science-agent:ops/observability/`.

## Related repos (read-only reference)

- `groundnuty/macf` — MACF framework source. Read `design/decisions/DR-*.md`, `packages/macf/plugin/rules/*.md`, `claude.sh` template for pattern reference. Never write here; file issues for `macf-code-agent[bot]`.
- `groundnuty/macf-science-agent` — design orchestrator's workspace. Read `research/2026-04-2*.md` (especially the four-doc observability cluster ending in `2026-04-23-helm-vs-compose-maturity-for-recommended-stack.md`) for the rationale behind any observability-related issue you get assigned.
