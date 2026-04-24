# `ops/k8s/` — MACF observability stack on k3s

**Status:** scaffold for issue #1 (phase 1 of observability-stack cutover). Acceptance criteria not yet validated against a live cluster. Iteration PRs will follow.

**Scope:** k3s single-node + 4 helm charts operational end-to-end (`cert-manager`, `kube-prometheus-stack`, `grafana-community/tempo`, `opentelemetry-operator`) + one `OpenTelemetryCollector` CR fanning OTLP → Tempo + Prometheus. Langfuse is **phase 2** (issue #2) and is **not** deployed here.

## Version matrix (verified 2026-04-24)

| Component | Pinned | Released | Source |
|---|---|---|---|
| k3s | `v1.35.3+k3s1` | 2026-03-28 | [k3s-io/k3s releases](https://github.com/k3s-io/k3s/releases) |
| cert-manager | `v1.20.2` (chart + app) | 2026-04-11 | [cert-manager releases](https://github.com/cert-manager/cert-manager/releases) |
| kube-prometheus-stack | `84.0.0` | 2026-04-23 | [prometheus-community/helm-charts](https://github.com/prometheus-community/helm-charts/releases) — **major bump: Grafana v11→v12** |
| grafana-community/tempo (monolithic) | `2.0.0` (app `2.10.1`) | 2026 | [grafana-community/helm-charts](https://github.com/grafana-community/helm-charts) |
| opentelemetry-operator (chart) | `0.110.0` (operator `v0.148.0`) | 2026-04-16 | [opentelemetry-helm-charts](https://github.com/open-telemetry/opentelemetry-helm-charts) |

**Delta from `groundnuty/macf-science-agent:research/2026-04-23-helm-vs-compose-maturity-for-recommended-stack.md`:**

- kube-prometheus-stack bumped 83.7.0 → 84.0.0 (Grafana v12). Major bump; watch for dashboard-plugin regressions on first install.
- **Tempo monolithic chart moved** from `grafana/helm-charts` to `grafana-community/helm-charts` (completed 2026-01-30). The research doc said the monolithic chart was "staying in `grafana/helm-charts`" — that's outdated. Helm repo is now `https://grafana-community.github.io/helm-charts`.
- Tempo chart jumped to 2.0.0 — values schema changed vs. 1.24.x cited in the doc.

## Install order

Webhooks in kube-prometheus-stack and opentelemetry-operator require cert-manager CRDs + webhook cert to be reconciled first. `scripts/install.sh` encodes the order.

```
1. k3s (system service)
2. cert-manager      (CRDs + webhook; wait Ready)
3. kube-prometheus-stack  (Grafana + Prometheus + Alertmanager; wait Ready)
4. grafana-community/tempo  (StatefulSet; wait Ready)
5. opentelemetry-operator  (operator Deployment + CRDs; wait Ready)
6. manifests/tempo-grafana-datasource.yaml  (ConfigMap; Grafana sidecar picks up)
7. manifests/otel-collector.yaml  (namespace + RBAC + OpenTelemetryCollector CR)
```

### k3s bootstrap

```
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.35.3+k3s1 sh -
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes  # expect Ready
```

k3s ships `local-path` as the default StorageClass and Traefik as the built-in ingress controller. No Helm Traefik override needed.

### Helm repo setup

```
helm repo add jetstack https://charts.jetstack.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

### Installation

```
bash scripts/install.sh
```

Idempotent; safe to re-run if a step fails mid-way. Each `helm upgrade --install` with `--wait` blocks until the release is ready.

## Access

Port-forward (no ingress in this phase):

```
# Grafana (default admin password retrieved from Secret)
kubectl -n monitoring port-forward svc/kube-prom-stack-grafana 3000:80
kubectl -n monitoring get secret kube-prom-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d

# Tempo (for curl/grpcurl smoke tests against the OTLP receivers)
kubectl -n tempo port-forward svc/tempo 3200:3200 4317:4317 4318:4318

# OpenTelemetry Collector (OTLP ingress for test spans)
kubectl -n otel port-forward svc/central-collector 4317:4317 4318:4318
```

Open Grafana at `http://127.0.0.1:3000`, Explore → Tempo datasource → run a trace search.

## Round-trip smoke test

Send a test span via `grpcurl` (or any OTLP-aware tool) to the Collector's `:4317`, confirm it lands in Tempo via Grafana Explore. **Pending: live-cluster validation in a follow-up PR. Exact curl/grpcurl command to be pasted into that PR's description.**

## Uninstall / teardown

```
bash scripts/uninstall.sh
```

Order is reverse of install. If a helm uninstall hangs (CRD finalizers), the script has `kubectl delete --grace-period=0 --force` escape hatches documented inline.

Full cluster reset (nuclear option):

```
sudo /usr/local/bin/k3s-uninstall.sh
sudo rm -rf /var/lib/rancher/k3s /etc/rancher/k3s
```

Persistent state between spike attempts has bitten previous observability rollouts (see `groundnuty/macf-science-agent:research/2026-04-23-helm-vs-compose-maturity-for-recommended-stack.md` §8 note 3). Reset to a clean cluster if debugging in circles.

## Known gotchas

- **kube-prometheus-stack 4 k3s disables.** `kubeScheduler`, `kubeControllerManager`, `kubeProxy`, `kubeEtcd` — all `enabled: false`. k3s collapses these into a single binary that doesn't expose `/metrics` on standard ports. Alternative (not taken): `--kube-*-arg='bind-address=0.0.0.0'` at k3s install time. For a single-node spike, disable is simpler.
- **Grafana sidecar datasource label.** The kube-prom-stack Grafana deployment watches for ConfigMaps labeled `grafana_datasource: "1"`. `manifests/tempo-grafana-datasource.yaml` carries that label; the Tempo chart does not ship one of its own.
- **`k8sattributes` processor requires cluster-wide RBAC.** The OpenTelemetry Collector's ServiceAccount needs `get/watch/list` on pods, namespaces, nodes, replicasets, deployments. `manifests/otel-collector.yaml` includes the ClusterRole + binding.
- **Tempo chart schema delta.** Version 2.0.0 (grafana-community) has a different values schema than 1.24.x (the old grafana/ path). The `tempo.storage.trace.backend: local` form is used here; older tutorials may still cite `storage.trace.backend` without the `tempo.` prefix — doesn't apply to 2.0.0.

## Files

| Path | Purpose |
|---|---|
| `values/cert-manager.yaml` | cert-manager values (CRD install enabled) |
| `values/kube-prometheus-stack.yaml` | Grafana + Prometheus + Alertmanager; 4 k3s toggles; local-path PVCs |
| `values/tempo.yaml` | Tempo monolithic values; local-path PVC; OTLP receivers on 4317/4318 |
| `values/opentelemetry-operator.yaml` | Operator values; contrib collector image |
| `manifests/tempo-grafana-datasource.yaml` | ConfigMap for Grafana sidecar to auto-wire Tempo datasource |
| `manifests/otel-collector.yaml` | Namespace, ServiceAccount, ClusterRole, ClusterRoleBinding, `OpenTelemetryCollector` CR |
| `scripts/install.sh` | Install orchestrator (idempotent) |
| `scripts/uninstall.sh` | Teardown orchestrator |
