# macf-devops-toolkit

Home workspace for `macf-devops-agent[bot]` — the MACF project's devops agent — and source of truth for the MACF observability stack: a k3d single-node cluster managed by ArgoCD GitOps, running OpenTelemetry Collector, Tempo, Langfuse, Loki, ClickHouse-logs, and kube-prometheus-stack.

The repo is two things in one:

1. **An agent workspace** — rules, identity scripts, launcher (`claude.sh`), and SessionStart/PreCompact hooks for the devops agent.
2. **A GitOps source repo** — declarative cluster + helm values + ArgoCD `Application` CRs in `environments/macf/`. After bootstrap, `git push` is the deploy command.

Sibling workspaces in the MACF project: [`groundnuty/macf-science-agent`](https://github.com/groundnuty/macf-science-agent) (orchestrator / design / paper) and [`groundnuty/macf`](https://github.com/groundnuty/macf) (framework TypeScript). Cross-repo agent routing runs through [`groundnuty/macf-actions`](https://github.com/groundnuty/macf-actions) v1.3.0 (SSH + tmux).

## Architecture

```
                  AGENTS (where work happens)
                  ─────────────────────────────
   ┌──────────────────────────┐   ┌────────────────────────────┐
   │ On-VM substrate agents   │   │ Off-VM agents (laptop)     │
   │  • devops-agent[bot]     │   │  • cv-architect            │
   │  • science-agent[bot]    │   │  • cv-project-archaeologist│
   │  • code-agent[bot]       │   │  • testers (off-VM future) │
   └────────────┬─────────────┘   └─────────────┬──────────────┘
                │ OTLP (HTTP/gRPC)              │ OTLP via tailnet
                │ http://127.0.0.1:14318        │ http://<vm>.<tailnet>.ts.net:14318
                │                               │ (tailscale serve)
                ▼                               ▼
       ┌──────────────────────────────────────────────────┐
       │    k3d serverlb (nginx) — host-port 14317/14318  │
       │      ↕ klipper-lb node-bound ports               │
       │      ↕ central-collector-lb (LoadBalancer Svc)   │
       └──────────────────────┬───────────────────────────┘
                              │
                              ▼
   ┌──────────────────────────────────────────────────────────────┐
   │           central-collector  (otel/opentelemetry-collector)  │
   │                                                              │
   │  receivers:  otlp (gRPC :4317, HTTP :4318)                   │
   │  processors: k8sattributes → resource/paper-dims →           │
   │              transform/genai-semconv → batch                 │
   │  pipelines:                                                  │
   │     traces  → otlp/tempo + otlphttp/langfuse + debug         │
   │     metrics → prometheus (:8889)                             │
   │     logs    → otlphttp/loki + clickhouse + debug             │
   └──┬─────────────┬──────────────────┬──────────┬───────────────┘
      │             │                  │          │
      ▼             ▼                  ▼          ▼
   ┌──────────┐ ┌────────────┐ ┌──────────────┐ ┌─────────┐
   │  Tempo   │ │  Langfuse  │ │  Prometheus  │ │  Loki   │
   │ (traces) │ │  (web/     │ │  (metrics)   │ │ (logs)  │
   │          │ │   worker/  │ │              │ │         │
   │          │ │   CH-logs) │ │              │ │         │
   └────┬─────┘ └─────┬──────┘ └──────┬───────┘ └────┬────┘
        │             │               │              │
        └─────────────┴───────┬───────┴──────────────┘
                              ▼
                       ┌─────────────┐
                       │   Grafana   │  (kube-prometheus-stack v12)
                       │  dashboards │   datasources: Tempo, Loki,
                       │             │   Prometheus, ClickHouse-logs
                       └─────────────┘

  GITOPS                                STATE
  ──────                                ─────
  ┌──────────────────┐                  /mnt/volume1/
  │ this repo (main) │                    ├── k3d-registry-data/
  │  apps/*-app.yaml │   reconciles      ├── k3d-storage/   (PVCs)
  │  values/*.yaml   │ ───────────────►  └── (image cache)
  │  manifests/      │
  └────────┬─────────┘                  Persistent across cluster
           │                            recreate; never the root disk.
           │
           ▼
  ┌──────────────────┐
  │     ArgoCD       │ ◄─── argocd-apps root walks apps/ recursively
  │  (sync-waves -1, │      and creates an Application CR per chart
  │   0, 1)          │      or manifest bundle.
  └──────────────────┘

  CROSS-REPO ROUTING
  ──────────────────
  GitHub issue labeled devops-agent / @mention → macf-actions v1.3.0
  reusable workflow → SSH into VM → tmux send-keys to this agent's pane.
```

## Repository layout

```
.
├── claude.sh              # launcher: token refresh + tmux + sg docker -c wrapper
├── CLAUDE.md              # workspace identity (loaded every session)
├── .claude/
│   ├── rules/             # auto-loaded behavioral rules
│   │   ├── agent-identity.md          # role, scope, per-repo workflow
│   │   ├── coordination.md            # canonical MACF cross-cutting rules
│   │   ├── peer-dynamic.md            # symmetric pushback discipline
│   │   ├── pr-discipline.md           # PR as default merge checkpoint
│   │   ├── delegation-template.md     # 6-section issue template
│   │   ├── verify-before-claim.md     # tool output beats memory
│   │   ├── check-before-propose.md    # grep convention before proposing
│   │   ├── execute-on-directive.md    # act on "go", don't re-ask
│   │   ├── gh-token-refresh.md        # canonical fail-loud chain
│   │   ├── mention-routing-hygiene.md # backtick described-not-addressed handles
│   │   └── …                          # ~16 more (autonomous-work, devbox-usage, etc.)
│   ├── scripts/           # macf-gh-token.sh, check-gh-token.sh hook, etc.
│   ├── settings.json      # permissions, sandbox, hooks (Pre/Post-tool, PreCompact)
│   ├── audit.log          # ConfigChange hook appends on every .claude/* edit
│   └── session-reports/   # PreCompact + SessionEnd archives (gitignored)
│
├── environments/
│   ├── Makefile           # shared parent Makefile (every env includes this)
│   └── macf/              # the only environment today
│       ├── Makefile       # thin wrapper — include ../Makefile
│       ├── README.md      # detailed operator runbook for the macf env
│       ├── devbox.json    # pinned tools: helm, kubectl, k3d, grpcurl, yq-go, jq
│       ├── k3d/
│       │   ├── config.yaml      # declarative cluster (host-port mappings)
│       │   ├── version.yaml     # k3s image tag (source of truth)
│       │   └── registry.yaml    # persistent registry on /mnt/volume1
│       ├── apps/          # ArgoCD Application CRs, sync-wave annotated
│       │   ├── argocd-app.yaml
│       │   ├── argocd-apps-app.yaml
│       │   ├── cert-manager-app.yaml
│       │   ├── kube-prometheus-stack-app.yaml
│       │   ├── tempo-app.yaml + tempo-datasource-app.yaml
│       │   ├── otel-operator-app.yaml
│       │   ├── otel-collector-app.yaml + otel-collector-logs-app.yaml
│       │   ├── loki-app.yaml + loki-datasource-app.yaml
│       │   ├── langfuse-app.yaml
│       │   └── clickhouse-logs-datasource-app.yaml
│       ├── values/        # helm values, referenced via $values/ multi-source
│       │   ├── argocd.yaml + argocd-apps.yaml
│       │   ├── cert-manager.yaml
│       │   ├── kube-prometheus-stack.yaml   # 4 k3s toggles, Grafana v12
│       │   ├── tempo.yaml                   # monolithic, OTLP 4317/4318
│       │   ├── loki.yaml
│       │   ├── opentelemetry-operator.yaml  # contrib image, cert-manager webhooks
│       │   └── langfuse.yaml                # Langfuse v3 (web/worker/CH/PG/Valkey/MinIO/S3)
│       ├── manifests/     # raw k8s applied alongside (Collector CR, datasources)
│       │   ├── otel-collector/        # OpenTelemetryCollector CR + RBAC
│       │   ├── otel-collector-logs/   # logs-collector DaemonSet variant
│       │   ├── tempo-datasource/      # Grafana datasource ConfigMap
│       │   ├── loki-datasource/
│       │   ├── clickhouse-logs-datasource/
│       │   └── langfuse/              # secrets templates (rendered by hack/)
│       └── hack/          # operator scripts (ALL exposed as make targets)
│           ├── smoke.sh                   # OTLP round-trip Tempo + Langfuse
│           ├── doctor-otel.sh             # Pattern A: stuck-exporter cache check
│           ├── langfuse-bootstrap.sh      # autonomous one-shot init
│           ├── archive-agent-sessions.sh
│           ├── observability-snapshot.sh  # per-scenario / per-issue bundles (DR-002)
│           ├── check-tempo-ingestion.sh
│           ├── copy-clickhouse-creds.sh
│           ├── tailscale-otlp-up.sh       # tailnet OTLP on/off
│           └── tailscale-otlp-down.sh
│
├── design/                # Design Records — non-trivial decisions, ADR-style
│   ├── DR-001-argocd-gitops-for-observability-spike.md
│   └── DR-002-observability-artifact-bundles.md
│
├── research/              # Investigations, dated YYYY-MM-DD
│   └── 2026-04-24-chart-version-verification.md
│
├── docs/                  # Operator runbooks
│   ├── observability-bundle-setup.md
│   └── remote-agent-otlp-setup.md
│
├── .github/workflows/
│   ├── agent-router.yml            # delegates to macf-actions@v1.3.0 (SSH+tmux)
│   └── observability-snapshot.yml  # bundle on issue/PR close
│
├── CHANGELOG.md           # release notes
└── LICENSE                # MIT
```

## Quick start (fresh VM)

Bootstraps a complete observability cluster in roughly 10 minutes:

```bash
cd environments/macf
devbox install                  # pull pinned tools (helm, kubectl, k3d, ...)
sudo usermod -aG docker ubuntu  # one-time if not already; then `tmux kill-server`
make doctor                     # preflight: docker, /mnt/volume1, tool versions
make all                        # = make cluster + make argocd-bootstrap
                                # ArgoCD reconciles all charts; Langfuse pods
                                # CrashLoop until secrets exist (next step)
make langfuse-bootstrap         # generates 6 Secrets, runs init, prints admin login
make smoke                      # OTLP round-trip — Tempo + Langfuse legs
```

`make help` lists every target. The full operator-facing reference for the cluster lives at [`environments/macf/README.md`](environments/macf/README.md).

> ⚠️ `make langfuse-bootstrap` is **destructive on re-run** — rotates ALL secrets (DB passwords + API keys). Run once per fresh install. Truncates init-state tables to handle salt-skew on legitimate re-runs.

## Cluster endpoints

After bootstrap, the stable endpoints are:

| What | URL | Notes |
|---|---|---|
| OTLP HTTP (in-VM) | `http://127.0.0.1:14318/v1/traces` | k3d serverlb → `central-collector-lb` |
| OTLP gRPC (in-VM) | `127.0.0.1:14317` | Same routing |
| OTLP HTTP (off-VM, tailnet) | `http://<vm>.<tailnet>.ts.net:14318/v1/traces` | Run `make tailscale-otlp-up` once |
| Compat OTLP (legacy) | `127.0.0.1:4317` / `:4318` | For pre-#61 claude.sh defaults |
| Grafana UI | `make pf-grafana` → `http://127.0.0.1:3000` | password via `make grafana-password` |
| Tempo query API | `make pf-tempo` → `http://127.0.0.1:13200` | Trace search + timeline |
| Langfuse UI | `make pf-langfuse` → `http://127.0.0.1:3001` | Login printed by `make langfuse-bootstrap` |
| ArgoCD UI | `make pf-argocd` → `http://127.0.0.1:8080` | password via `make argocd-password` |

For laptop / off-VM agents, see [`docs/remote-agent-otlp-setup.md`](docs/remote-agent-otlp-setup.md). The short form: run `make tailscale-otlp-up` once on the VM, then on the laptop set `MACF_OTEL_ENDPOINT=http://<vm>.<tailnet>.ts.net:14318` and run `macf update --plugin --yes`.

## ArgoCD sync-wave topology

```
wave -1   cert-manager                      (CRDs + webhooks first)
wave  0   argocd, argocd-apps,              (core infra; argocd self-manages)
          kube-prometheus-stack, tempo,
          otel-operator, loki
wave  1   otel-collector, otel-collector-logs,
          *-datasource (tempo / loki /      (depend on wave-0 CRDs)
          clickhouse-logs), langfuse
```

After `make all`, every commit on `main` reconciles automatically. No more `helm install` from the operator side — `git push` is the deploy command.

## Pinned versions (verified 2026-04-24)

Full provenance: [`research/2026-04-24-chart-version-verification.md`](research/2026-04-24-chart-version-verification.md).

| Component | Pin | Notes |
|---|---|---|
| `rancher/k3s` (k3d-wrapped) | `v1.35.3-k3s1` | use `-` not `+` in OCI tag |
| `argo-cd` chart | `9.5.4` | |
| `argocd-apps` chart | `2.0.4` | |
| `cert-manager` chart | `v1.20.2` | |
| `kube-prometheus-stack` chart | `84.0.0` | ships Grafana v12 |
| `grafana-community/tempo` chart | `2.0.0` (app 2.10.1) | use `grafana-community/tempo`, not `grafana/tempo` |
| `opentelemetry-operator` chart | `0.110.0` (operator v0.148.0) | |
| `langfuse-k8s` chart | `1.5.27` | Langfuse v3 |
| `loki` chart | (see `apps/loki-app.yaml`) | |

Pins live in `apps/*-app.yaml` as `targetRevision`. The Makefile reads ArgoCD's own pin via `yq` so `make argocd-bootstrap` stays in sync. Bumps are one-line PRs — but always `WebFetch` artifacthub / GitHub releases first; training data goes stale fast.

## How work arrives

Issues labeled `devops-agent` on three repos:

- `groundnuty/macf-devops-toolkit` (this one)
- `groundnuty/macf-science-agent`
- `groundnuty/macf`

The SessionStart hook polls all three queues and surfaces open issues as a startup prompt. Issue lifecycle, PR discipline, GH_TOKEN refresh — all canonical and auto-loaded from `.claude/rules/`.

Cross-repo routing (a `@macf-devops-agent[bot]` mention or `devops-agent` label) goes through [`groundnuty/macf-actions`](https://github.com/groundnuty/macf-actions) v1.3.0: GitHub Actions reusable workflow → SSH into the VM → `tmux send-keys` to this agent's pane.

## Operational invariants

A few rules the cluster + scripts enforce — useful to know before debugging:

- **Persistent state lives on `/mnt/volume1`** (`/dev/vdb`, ~200 GiB). k3d registry data, k3d cluster PVCs, anything heavy. Never the root disk.
- **`make` is the operational interface.** Every casual op is a target — no ad-hoc `kubectl apply`. If a step is missing, add a target.
- **Helm values files are authoritative.** Don't `helm install --set foo=bar` in committed flows; everything goes in `values.yaml` so rollback is one git revert.
- **Run `helm template` + `kubectl apply --dry-run=server`** before any PR. Values that lint and template can still fail at admission.
- **ArgoCD's root-app reverts feature-branch retargets** within ~3 min. Spike-validation pattern: push + merge + let ArgoCD pick up from main.
- **Stale tmux + docker group**: this host's tmux predates the `ubuntu`→`docker` membership. Use `sg docker -c "..."` until `tmux kill-server` is run; `claude.sh` handles this for new sessions.
- **Compose stack on the same VM** (`macf-obs-*`) still binds `:4317/:4318/:3200` from the previous-generation rollout. The cluster uses `:14317/:14318/:13200` to avoid collision.
- **Secrets never committed.** `*.key`, `*.pem`, `*.p12`, `.env*` are in `.gitignore`. `.github-app-key.pem` is the GitHub App private key — local-only.

## Design records & research

Non-trivial design choices land as `design/DR-NNN-*.md` **before** the implementation PR. Investigations land as `research/YYYY-MM-DD-*.md`.

| Doc | Topic |
|---|---|
| [`DR-001`](design/DR-001-argocd-gitops-for-observability-spike.md) | ArgoCD GitOps for the observability spike — why this layout |
| [`DR-002`](design/DR-002-observability-artifact-bundles.md) | Per-scenario + per-issue observability bundles (paper evidence) |
| [`research/2026-04-24-chart-version-verification.md`](research/2026-04-24-chart-version-verification.md) | Live-fetched chart versions on 2026-04-24 |

Operator runbooks:

- [`docs/remote-agent-otlp-setup.md`](docs/remote-agent-otlp-setup.md) — tailnet OTLP for off-VM agents
- [`docs/observability-bundle-setup.md`](docs/observability-bundle-setup.md) — DR-002 implementation

## Substrate, not macf-consumer

This workspace is one of three **MACF substrate workspaces** (alongside `macf-science-agent` and `macf` / code-agent). Substrate = source of canonical patterns. This workspace does NOT run `macf init` / `macf update` / `macf rules refresh`. Rule files in `.claude/rules/` are maintained manually here; updates flow into `groundnuty/macf:packages/macf/plugin/rules/` only after proving themselves in substrate pair work.

If a rule here proves useful across sessions, propose promoting it to canonical via a PR on `groundnuty/macf`.

## License

MIT. See [`LICENSE`](LICENSE).
