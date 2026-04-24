# `environments/macf/` — MACF observability stack on k3d + ArgoCD

**Status:** phase-1 live ([#1](https://github.com/groundnuty/macf-devops-toolkit/issues/1)) + phase-2 scaffold ([#2](https://github.com/groundnuty/macf-devops-toolkit/issues/2)).

**Scope:** k3d single-node cluster + ArgoCD reconciling five helm charts — `cert-manager`, `kube-prometheus-stack`, `grafana-community/tempo` (monolithic), `opentelemetry-operator`, `langfuse-k8s` — plus a central `OpenTelemetryCollector` CR fanning OTLP → Tempo + Prometheus `:8889`, and the Langfuse application for LLM observability.

**Canonical design + rationale:** [`../../design/DR-001-argocd-gitops-for-observability-spike.md`](../../design/DR-001-argocd-gitops-for-observability-spike.md).
**Version verification evidence:** [`../../research/2026-04-24-chart-version-verification.md`](../../research/2026-04-24-chart-version-verification.md).

Layout mirrors [`groundnuty/onedata/spice-deployments`](~/repos/onedata/spice-deployments) almost verbatim.

## Operator interface: `make`

All casual operations go through `make <target>` from this directory. Inside a devbox shell:

```
cd environments/macf
devbox install
devbox shell
make help
```

### Common flows

```
make doctor              # preflight: docker, devbox, /mnt/volume1, tool versions
make all                 # = make cluster + make argocd-bootstrap
make argocd-password     # retrieve the generated admin password
make pf-argocd           # port-forward argocd UI to http://127.0.0.1:8080
make status              # kubectl get app -A
make sync                # force argocd hard-refresh on every app
make nuke                # teardown: cluster + registry + /mnt/volume1 data
```

Individual targets: `cluster-up`, `cluster-down`, `registry-up`, `registry-down`, `argocd-bootstrap`, `pf-grafana`, `pf-tempo`, `pf-collector`, `pf-langfuse`, `grafana-password`, `langfuse-secrets`, `smoke`, `lint`, `env-test`, `help`.

### Langfuse (phase 2)

Langfuse needs 7 secrets (3 app-layer + 4 subchart auth) that aren't shipped in Git. Generate them once at first install:

```
make langfuse-secrets     # generates + kubectl-applies 5 Secret resources to ns/langfuse
```

This creates `langfuse-secrets` (salt / encryptionKey / nextauth) plus `langfuse-postgresql`, `langfuse-redis`, `langfuse-clickhouse`, `langfuse-s3`. Re-running **rotates** the secrets, which will invalidate the existing PVC data (Postgres/ClickHouse will reject the new passwords). Run once per fresh install.

After secrets are in place, argocd reconciles the `langfuse-app` (sync-wave 2) and stands up 7 pods (postgresql, clickhouse, clickhouse-zookeeper, redis, minio, langfuse-web, langfuse-worker). First install takes ~2-3 min — mostly Prisma migrating 390+ schemas.

```
make pf-langfuse          # http://127.0.0.1:3001 (Langfuse UI)
```

## Stable OTLP endpoint

Testers + any host-side OTLP producer can push traces directly to the central Collector without `kubectl port-forward`:

```
OTLP gRPC:  127.0.0.1:14317
OTLP HTTP:  http://127.0.0.1:14318/v1/traces
```

Wired via: `central-collector-lb` LoadBalancer Service (ns/otel) → klipper-lb node-bound ports → k3d serverlb nginx proxy → host ports 14317/14318 (declared in `k3d/config.yaml:ports`).

Live cluster (no recreate) gets the mapping via:
```
k3d cluster edit macf \
  --port-add "127.0.0.1:14317:4317@loadbalancer" \
  --port-add "127.0.0.1:14318:4318@loadbalancer"
```
Fresh clusters pick it up automatically from `k3d/config.yaml`.

High host ports (14317/14318 instead of 4317/4318) avoid collision with the existing compose observability stack on the same VM.

`make pf-collector` (port-forward to the ClusterIP service) and the stable endpoint serve **different debugging purposes** — not one supersedes the other:
- **Stable endpoint** (`:14317`/`:14318`): load-balanced across all Collector replicas via klipper-lb. The right tool for normal tester traffic + smoke tests.
- **`make pf-collector`**: targets the ClusterIP service which round-robins per kube-proxy iptables; with `--pod-ip-of <pod>` it can target a specific replica. The right tool for comparing pod-A vs pod-B output, debugging a single replica during a crashloop investigation.

Smoke tests + routine tester OTLP traffic should use the stable endpoint; `make pf-collector` stays as a debugging escape hatch.

## Bootstrap flow (one-time)

The very first `make all` does two imperative things — after that, everything reconciles from Git:

1. **k3d cluster + persistent registry** via `k3d cluster create --config k3d/config.yaml`. Registry persists on `/mnt/volume1/k3d-registry-data`; cluster PVCs on `/mnt/volume1/k3d-storage`.
2. **ArgoCD + ArgoCD-Apps** via `helm upgrade -i`. Once the `argocd-apps` root reconciles, it walks `apps/*-app.yaml` and creates Application CRs for every chart + manifest in this directory.

From that point on, `git commit && git push` is the deploy command. No more `helm install` from the operator side.

## Directory map

| Path | Purpose |
|---|---|
| `Makefile` | thin wrapper — `include ../Makefile` |
| `devbox.json` | pinned toolchain (`helm`, `kubectl`, `k3d`, `grpcurl`, `yq-go`, `jq`) |
| `k3d/version.yaml` | k3s image tag read by Makefile (source of truth) |
| `k3d/config.yaml` | k3d cluster declarative config (1 server, 0 agents, volume mounts) |
| `k3d/registry.yaml` | k3d registry declarative config (persistent on `/mnt/volume1`) |
| `apps/*.yaml` | ArgoCD `Application` CRs, one per helm chart or manifest bundle |
| `values/argocd.yaml` | bootstrap values for the ArgoCD chart itself |
| `values/argocd-apps.yaml` | `projects:` + root `root-app` pointing at `apps/` recursively |
| `values/langfuse.yaml` | Langfuse helm values (single-node dev sizing; probes tuned for first-install migrations) |
| `values/cert-manager.yaml` | cert-manager helm values (installCRDs=true) |
| `values/kube-prometheus-stack.yaml` | kube-prom-stack values (4 k3s toggles, local-path PVCs, Grafana v12) |
| `values/tempo.yaml` | Tempo monolithic values (OTLP 4317/4318, local-path PVC) |
| `values/opentelemetry-operator.yaml` | otel-operator values (contrib image default, cert-manager webhooks) |
| `manifests/otel-collector/` | `OpenTelemetryCollector` CR + RBAC — applied by `apps/otel-collector-app.yaml` |
| `manifests/tempo-datasource/` | Grafana-datasource ConfigMap — applied by `apps/tempo-datasource-app.yaml` |
| `manifests/langfuse/secrets.yaml.example` | Secret template for the 7 Langfuse secrets — `hack/langfuse-secrets.sh` renders the actual values |
| `hack/smoke.sh` | OTLP round-trip smoke test (POST span → Collector → Tempo) |
| `hack/langfuse-secrets.sh` | Generate + apply the 5 Langfuse Secret objects with random hex passwords |

## Sync-wave topology

| Wave | Applications | Why this wave |
|---|---|---|
| `-1` | `cert-manager` | CRDs + webhook required before any chart with a cert-manager-backed admission webhook reconciles |
| `0`  | `argocd`, `argocd-apps`, `kube-prometheus-stack`, `tempo`, `otel-operator` | core infra; argocd self-manages after bootstrap, others install their CRDs so wave-1 dependents have something to point at |
| `1`  | `otel-collector`, `tempo-datasource` | Collector CR needs `OpenTelemetryCollector` CRD (from otel-operator); Grafana datasource ConfigMap is picked up by kube-prom's Grafana sidecar |

## Access

All services reached via `kubectl port-forward` (no ingress in the spike). Each has a Makefile target:

```
make pf-grafana          # http://127.0.0.1:3000
make pf-tempo            # http://127.0.0.1:3200 + OTLP 4317/4318
make pf-collector        # Collector OTLP 4317/4318
make pf-argocd           # http://127.0.0.1:8080
make grafana-password    # print Grafana admin password
make argocd-password     # print ArgoCD admin password
```

## Version matrix (verified 2026-04-24)

Full provenance: [`../../research/2026-04-24-chart-version-verification.md`](../../research/2026-04-24-chart-version-verification.md).

| Component | Pin | Released |
|---|---|---|
| `rancher/k3s` (in k3d) | `v1.35.3-k3s1` | 2026-03-28 |
| `argo-cd` chart | `9.5.4` | 2026-04-22 |
| `argocd-apps` chart | `2.0.4` | 2026-01-12 |
| `cert-manager` chart | `v1.20.2` | 2026-04-11 |
| `kube-prometheus-stack` chart | `84.0.0` | 2026-04-23 — ships Grafana v12 |
| `grafana-community/tempo` chart | `2.0.0` (app 2.10.1) | migrated from `grafana/helm-charts` on 2026-01-30 |
| `opentelemetry-operator` chart | `0.110.0` (operator v0.148.0) | 2026-04-16 |

Version pins live in `apps/*-app.yaml` as `targetRevision`; Makefile extracts ArgoCD's own versions via `yq` so `make argocd-bootstrap` knows what chart version to install. Bumps are one-liner PRs.

## Known gotchas

- **Docker permission-denied in stale-tmux sessions.** If `make doctor` reports "docker inaccessible," the current tmux predates the `ubuntu`→`docker` group membership. Workaround: wrap any docker-touching command with `sg docker -c "..."`. Permanent fix: `tmux kill-server` + relaunch. See [`../../memory/reference_docker_sg_workaround_stale_tmux.md`](../../memory/reference_docker_sg_workaround_stale_tmux.md) (local memory, not in git).
- **k3s vs k3d image tag format.** `version.yaml:k3s_image` uses `rancher/k3s:vX.Y.Z-k3s1` (Docker tag, `-`). The k3s GitHub release tags are `vX.Y.Z+k3s1` (`+`). The `+` is invalid in an OCI image tag — always use `-` when composing the k3d image.
- **Registry lifecycle is independent of cluster.** `k3d cluster delete` does NOT remove `k3d-macf-mirror`. That's intentional — the registry is the persistent image cache. To blow it away, `make registry-down` (or `make nuke`).
- **4 k3s control-plane scrape targets disabled** in `values/kube-prometheus-stack.yaml` (kubeScheduler/kubeControllerManager/kubeProxy/kubeEtcd). k3s collapses these into a single binary that doesn't expose `/metrics` on standard ports. Alternative not taken: `--kube-*-arg='bind-address=0.0.0.0'` at cluster start.
- **Tempo chart repo migration.** Use `grafana-community/tempo`, not `grafana/tempo`. The old `grafana/helm-charts/charts/tempo` is a README redirect since 2026-01-30.
- **Grafana v11 → v12 in kube-prom 84.0.0.** First install may surface dashboard-plugin regressions; no explicit BREAKING CHANGE markers in release notes. See Grafana 12 upgrade guide: https://grafana.com/docs/grafana/latest/upgrade-guide/upgrade-v12.0/
- **`OpenTelemetryCollector` CR is `opentelemetry.io/v1beta1`.** Training data + some older docs show `v1alpha1` — that's still accepted but `v1beta1` is the storage version in operator v0.148.0+.
- **`k8sattributes` processor needs cluster-wide RBAC.** ClusterRole + Binding shipped alongside the Collector CR in `manifests/otel-collector/otel-collector.yaml` — don't strip on a values cleanup pass.

## Round-trip smoke test

Pending live-cluster validation. Target form (recorded here so the follow-up PR reproduces it):

```
# From inside environments/macf, in a devbox shell with the cluster up + argocd reconciled:
make pf-collector &                                                    # terminal 1
grpcurl -plaintext -d '...otel-protobuf-request-body...' 127.0.0.1:4317 \
    opentelemetry.proto.collector.trace.v1.TraceService/Export         # terminal 2
make pf-grafana                                                         # browse to :3000, Explore → Tempo → query by traceId
```

Literal tool output will land in the follow-up PR description per `verify-before-claim.md`.

## Teardown

```
make nuke                 # uninstall stack + delete cluster + delete registry + wipe /mnt/volume1 data
```

**Note:** `make nuke` calls `sudo rm -rf $(REGISTRY_DATA)` to wipe the bind-mounted registry directory on `/mnt/volume1`. It will prompt for your sudo password once at that step. Everything else in the Makefile runs unprivileged; this is the only sudo call.

k3d is container-wrapped — there's no systemd service to uninstall and no host packages to remove. The VM is back to "k3d binary exists" state.
