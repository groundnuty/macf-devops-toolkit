---
id: DR-001
title: ArgoCD GitOps for the MACF observability spike
status: accepted
date: 2026-04-24
participants:
  - macf-devops-agent[bot]
  - macf-science-agent[bot]
  - operator
supersedes: none
related:
  - groundnuty/macf-devops-toolkit#1 (phase 1 of observability-stack cutover)
  - groundnuty/macf-science-agent:research/2026-04-23-helm-vs-compose-maturity-for-recommended-stack.md
  - research/2026-04-24-chart-version-verification.md (in this repo)
---

# DR-001: ArgoCD GitOps for the MACF observability spike

## Context

Issue #1 (phase 1 of the MACF observability-stack cutover) calls for standing up a single-node Kubernetes cluster plus four helm charts — `cert-manager`, `kube-prometheus-stack`, `grafana-community/tempo` (monolithic), `opentelemetry-operator` — with an `OpenTelemetryCollector` CR fanning OTLP to Tempo and a Prometheus-scraping endpoint. PR #3 (merged as `6966eae`) scaffolded the tree with values files, a Collector CR manifest, and install/uninstall shell scripts under `ops/k8s/`.

During scaffold review the operator surfaced four operational preferences that reshape the follow-up:

1. Tooling should live in devbox, not on the VM. Every casual op should have a Makefile target.
2. Heavy storage (container images, pod logs, PVCs) goes on `/mnt/volume1` (`/dev/vdb`, ~200 GiB), never the root disk.
3. This workspace should follow GitOps discipline. The operator is an Argo CD person — `~/repos/onedata/spice-deployments` on this host is the canonical template.
4. The cluster itself should be container-wrapped (k3d) rather than a systemd service (k3s bare-metal), to minimize VM installs. A persistent k3d registry on `/mnt/volume1` acts as the system-level image cache that bare-metal k3s's containerd store would otherwise provide.

## Decision

The follow-up PR adopts **seven coupled decisions** that together replace the procedural-shell approach of PR #3 with a GitOps-first, spice-deployments-shaped operational surface:

### 1. ArgoCD (not Flux CD) as the GitOps control plane

Matches the operator's spice-deployments pattern verbatim. Every operational convention carries over: multi-source `Application` CRs, `argocd-apps` helm chart for the app-of-apps root, sync-wave annotations, `project: operations` for infrastructure, `finalizers: resources-finalizer.argocd.argoproj.io`, `syncPolicy.automated.prune + selfHeal`, `syncOptions: CreateNamespace=true + ServerSideApply=true`.

### 2. k3d (not bare-metal k3s) for the cluster runtime

A `k3d` cluster runs k3s inside Docker containers, avoiding a systemd install of k3s on the host. Operator has not used k3d before; this spike is the trial. If k3d proves too finicky at our load, pivoting to bare-metal k3s is a one-target change in the Makefile with no effect on the Argo CD layout.

### 3. Persistent k3d registry on `/mnt/volume1/k3d-registry-data`

Created once via `k3d registry create`, referenced via `--registry-use` on cluster creation. Survives `k3d cluster delete` and provides the shared image cache role that bare-metal k3s's `/var/lib/rancher/k3s/agent/containerd/` would serve. Addresses the one real advantage k3s bare-metal had over container-wrapped distros (kind / k3d's default re-pull-on-recreate behavior).

### 4. Directory layout mirrors `groundnuty/onedata/spice-deployments`

Concretely:

    environments/macf/
      apps/            # Argo CD Application YAMLs (one per chart)
      values/          # helm values referenced via $values ref in Applications
      manifests/       # raw k8s manifests applied alongside (Tempo datasource CM, Collector CR)
      k3d/             # declarative k3d config — version.yaml, config.yaml, registry.yaml
      Makefile         # env-facing, includes ../Makefile
      devbox.json      # helm, kubectl, k3d, grpcurl, yq-go, jq pinned
    environments/
      Makefile         # shared targets: k3d-install, argocd-bootstrap, lint, smoke

PR #3's `ops/k8s/` contents migrate into `environments/macf/` via `git mv`. No content changes to the helm values files or manifests — only path moves plus the new `apps/`, `k3d/`, `Makefile`, `devbox.json` additions.

### 5. devbox + Makefile is the operational interface

Tool installation on the VM is limited to what cannot be container-wrapped: at present just the `docker` daemon itself. Everything else — `helm`, `kubectl`, `k3d`, `grpcurl`, `yq-go`, `jq` — is a devbox package pinned in `environments/macf/devbox.json`. All operator actions flow through `make <target>` in `environments/macf/`.

Targets include: `doctor`, `cluster-up` (= `registry-up` + `k3d cluster create`), `argocd-bootstrap`, `sync`, `status`, `cluster-down`, `registry-down`, `nuke`, `pf-grafana`, `pf-tempo`, `pf-collector`, `grafana-password`, `lint`.

### 6. All persistent state lands on `/mnt/volume1`

- **Registry data**: `/mnt/volume1/k3d-registry-data` (bind-mounted into the registry container at `/var/lib/registry`)
- **Cluster PVC storage**: `/mnt/volume1/k3d-storage` (bind-mounted into every k3d node container at `/var/lib/rancher/k3s/storage`, the default path of the bundled local-path provisioner)
- No per-chart `storageClassName` overrides needed — the bind-mount redirect covers all PVCs uniformly.

### 7. Public HTTPS for Argo CD's git access

`repoURL: https://github.com/groundnuty/macf-devops-toolkit.git` with no credentials. The repo is a public GitHub repository; no deploy-key secret, no `knownHosts` section. Spice-deployments uses SSH+deploy-key because its Bitbucket instance is private; the argument does not carry over here.

## Alternatives considered and rejected

- **Flux CD over Argo CD.** Technically lighter (4 controllers vs Argo's 5-6) and CLI-native, which fits the devbox+Makefile aesthetic. Rejected because the operator is Argo-fluent and spice-deployments is already the canonical template. Teaching-new-tool overhead not justified for a paper-scale workload.
- **Bare-metal k3s.** Would give direct shared containerd image cache (no registry hop) and matches spice-deployments' own cluster choice. Rejected *for this spike* because the operator explicitly wants to try k3d. Reversible — if k3d breaks, the pivot is a small change in `Makefile` plus replacing `k3d/config.yaml` with `k3s/config.yaml`. Apps/, values/, manifests/ layouts are unchanged.
- **Tier A (compose, no Kubernetes).** Simpler, zero image-isolation overhead, documented in the helm-vs-compose research doc §7 as a legitimate answer. Rejected because it loses the Operator/CRD surface (no `OpenTelemetryCollector` CR, no `ServiceMonitor`, no curated Grafana dashboards bundle) that makes helm meaningfully easier than compose for 3 of the 4 charts.
- **Flat `ops/k8s/` layout (no `environments/<env>/` nesting).** Slightly cheaper for the single-env case. Rejected because the env-folder pattern matches spice verbatim (future muscle-memory transfer), makes multi-env evolution zero-friction if ever needed, and avoids a "semantic-mirror-but-differently-rooted" mismatch that would subtly drift from spice over time.
- **`helm install` from the Makefile (not GitOps).** Faster to ship, no Argo dependency. Rejected because it skips the commit-friendly workflow the operator asked for — drift between on-cluster state and git state becomes invisible, rollback is a manual `helm rollback`, and there's no audit trail beyond shell history.
- **Deploy-key for git access.** More secure in principle. Rejected because the repo is public; no access-control benefit from the key, only setup cost.

## Consequences

**Positive:**
- Every state change is a Git commit: reviewable diff, rollback via `git revert`, audit trail survives rebuilds.
- Operator rebuilds the VM → `make cluster-up && make argocd-bootstrap` → back to known state.
- Layout is immediately familiar to anyone who knows spice-deployments.
- Devbox-pinned tools are reproducible across operator machines.
- PVC storage on `/mnt/volume1` bounds root-disk pressure; containerd image cache isolation is covered by the registry mirror.

**Negative:**
- Extra moving parts: ArgoCD (5 controllers + CRDs), persistent k3d registry container.
- `flux/argo bootstrap` itself is imperative — the very first install is shell-driven, not GitOps. Not a new problem; every GitOps tool has this paradox. The `argocd-bootstrap` Makefile target encapsulates it.
- Cross-cutting behavior (sync waves, finalizer, syncOptions) lives in every `*-app.yaml` — duplication, but matches spice and is preferable to a custom ApplicationSet template that diverges from the reference.
- k3d adds a Docker-daemon dependency; a stale tmux server on this host currently blocks docker access from inside this session, worked around via `sg docker -c "..."` wrapping (see `reference_docker_sg_workaround_stale_tmux.md`).

## Acceptance-criteria mapping to issue #1

- **AC #1** (k3s single-node Ready): satisfied by `k3d cluster create` + `kubectl get nodes`. k3d runs k3s inside Docker; from the Kubernetes API's perspective the cluster is indistinguishable.
- **AC #2** (helm install kube-prometheus-stack): satisfied by Argo CD reconciling `apps/kube-prom-stack-app.yaml`. Argo internally uses the helm SDK; "helm install succeeded" holds in the literal sense, triggered declaratively.
- **AC #3** (helm install grafana/tempo): same, via `apps/tempo-app.yaml` pointing at `grafana-community/tempo` chart 2.0.0.
- **AC #4** (opentelemetry-operator + OpenTelemetryCollector CR): `apps/otel-operator-app.yaml` for the operator helm chart; `manifests/otel/` contains the `OpenTelemetryCollector` CR, applied by an `apps/otel-collector-app.yaml` with sync-wave 1 (after the operator's CRDs reconcile).
- **AC #5** (round-trip OTLP smoke test): covered by `make smoke` Makefile target, producing the literal tool output for the follow-up PR body per `verify-before-claim.md`.
- **AC #6** (`ops/k8s/` directory + README runbook): moved to `environments/macf/` per this DR; runbook updates point to `make help` as the primary entry.
- **AC #7** (teardown reversible): `make nuke` (alias for `make uninstall && make cluster-down && make registry-down`). Documented in the runbook.

## References

- Issue #1: https://github.com/groundnuty/macf-devops-toolkit/issues/1
- PR #3 (merged, baseline): https://github.com/groundnuty/macf-devops-toolkit/pull/3
- Spice-deployments repo: `~/repos/onedata/spice-deployments` (on this host)
- Helm-vs-compose maturity research: `groundnuty/macf-science-agent:research/2026-04-23-helm-vs-compose-maturity-for-recommended-stack.md`
- Chart-version verification research: `research/2026-04-24-chart-version-verification.md` (this repo, companion to this DR)
- Memory: `feedback_devbox_makefile_interface.md`, `feedback_use_mnt_volume1_for_heavy_storage.md`, `feedback_design_and_research_folders.md`, `reference_docker_sg_workaround_stale_tmux.md`
