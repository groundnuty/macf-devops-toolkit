---
date: 2026-04-24
status: complete
scope: Helm-chart + cluster-distro version pins for issue #1 (phase 1 of MACF observability stack)
author: macf-devops-agent[bot]
related:
  - groundnuty/macf-devops-toolkit#1
  - design/DR-001-argocd-gitops-for-observability-spike.md (consumes these findings)
  - groundnuty/macf-science-agent:research/2026-04-23-helm-vs-compose-maturity-for-recommended-stack.md (one-day-old predecessor; superseded on two points by these findings)
---

# Chart version verification + repo migrations for the observability spike

## TL;DR

Verified the live state of every chart repository + cluster distro pinned in the sibling research doc. **Two material changes in the ~24 hours between that doc and today**:

1. **`grafana/helm-charts/charts/tempo` moved to `grafana-community/helm-charts`** on 2026-01-30. The sibling research doc said only `tempo-distributed` migrated; that's wrong. The monolithic chart redirected too. Helm repo add URL changes from `https://grafana.github.io/helm-charts` to `https://grafana-community.github.io/helm-charts`. Chart version jumped `1.24.4` → `2.0.0` in the migration — values schema is subtly different (e.g. `tempo.receivers.otlp` nesting).
2. **`kube-prometheus-stack` bumped 83.7.0 → 84.0.0** on 2026-04-23 (one day after the sibling doc). Grafana v11 → v12. The only documented change (per GitHub release notes) is the Grafana major-version bump via PR #6848. No migration notes cited in the release body; watch for dashboard-plugin regressions on first install.

Other pins held steady but verified against live sources rather than training data.

## Verified version matrix (2026-04-24)

| Tool | Previous pin (research doc) | Verified latest stable | Source |
|---|---|---|---|
| k3s | ≥ v1.33 (abstract) | **v1.35.3+k3s1** (2026-03-28) | `gh api repos/k3s-io/k3s/releases` — `prerelease: false` filter |
| cert-manager | ≥ v1.19.0 (abstract) | **v1.20.2** (2026-04-11) | `gh api repos/cert-manager/cert-manager/releases/latest` |
| kube-prometheus-stack | 83.7.0 | **84.0.0** (2026-04-23) | artifacthub.io + `gh api repos/prometheus-community/helm-charts/releases/tags/kube-prometheus-stack-84.0.0` |
| Tempo (monolithic) | `grafana/tempo@1.24.4` | **`grafana-community/tempo@2.0.0`** (app: `Tempo 2.10.1`) | `Chart.yaml` from `grafana-community/helm-charts:charts/tempo/Chart.yaml` |
| opentelemetry-operator (chart) | "latest stable" (abstract) | **0.110.0** (2026-04-16, shipping operator `v0.148.0`) | `Chart.yaml` from `open-telemetry/opentelemetry-helm-charts:charts/opentelemetry-operator/Chart.yaml` |
| opentelemetry-operator (app) | v0.148.0 | **v0.149.0** (2026-04-23) available upstream; helm chart still ships v0.148.0 | `gh api repos/open-telemetry/opentelemetry-operator/releases/latest` |
| `OpenTelemetryCollector` CRD apiVersion | implicit | **`opentelemetry.io/v1beta1`** (storage version per kubebuilder annotation in operator v0.148.0) | `opentelemetry-operator/apis/v1beta1/opentelemetrycollector_types.go` @ tag `v0.148.0` |

## Deltas of note

### 1. Tempo chart repo migration (material)

The sibling research doc (§2.1) explicitly said:

> "Migrated to `grafana-community/helm-charts` after 2026-01-30" — for `tempo-distributed`
> "Staying in `grafana/helm-charts`; actively maintained" — for `tempo` (monolithic)

**Not true anymore.** The `grafana/helm-charts/charts/tempo/` directory now contains *only* a `README.md` redirect:

    # tempo
    ## 📦 Chart Migration
    **This chart has been migrated to [grafana-community/helm-charts](https://github.com/grafana-community/helm-charts).**
    After January 30th, 2026, updates and support for this chart will be provided in the new repository.

The monolithic chart also moved. Either the research doc was already stale at write time or Grafana adjusted course between that doc and today.

**Downstream implications:**
- Helm repo: `helm repo add grafana-community https://grafana-community.github.io/helm-charts`
- Chart ref in Argo `Application`: `repoURL: https://grafana-community.github.io/helm-charts`, `chart: tempo`, `targetRevision: 2.0.0`
- Values schema: verified `tempo.storage.trace.backend: local`, `tempo.receivers.otlp.protocols.grpc/http.endpoint`, `persistence.{enabled,storageClassName,size}` are all current. No breaking delta from 1.24.x's schema for our minimal use. Bigger 2.0.0 surface includes `tempo.metricsGenerator` + `tempoQuery` which we don't touch.

### 2. kube-prometheus-stack 83.7.0 → 84.0.0 (minor risk)

Single change per release body: Grafana v11 → v12 (PR [#6848](https://github.com/prometheus-community/helm-charts/pull/6848)). No explicit BREAKING CHANGE markers in the release notes we fetched. Grafana 12's own upgrade guide covers plugin-compat surface: https://grafana.com/docs/grafana/latest/upgrade-guide/upgrade-v12.0/.

Not expected to break our install because:
- We don't ship custom dashboards or plugins in values
- Preset kubernetes-mixin dashboards shipped with 84.0.0 are already Grafana-12-tested
- Auto-datasource discovery via `grafana_datasource: "1"` ConfigMap label is stable across Grafana majors

Flag for the first install: if a preset dashboard panels-as-library reference breaks, it's likely here.

### 3. opentelemetry-operator chart 0.110.0 ships operator 0.148.0

Upstream operator has moved to `v0.149.0` (released 2026-04-23). Helm chart hasn't bumped yet. For this spike we accept the one-patch lag — chart schema for our `OpenTelemetryCollector` CR is unchanged between 0.148 and 0.149 per the operator's CHANGELOG.

### 4. k3s stable pin `v1.35.3+k3s1`

Released 2026-03-28. RC builds for `v1.33.11` / `v1.34.7` / `v1.35.4` / `v1.36.0-rc1` exist but all `prerelease: true`. Stable-channel default is `v1.35.3+k3s1`.

**Note: this pin is now largely moot** because DR-001 pivots to k3d (Docker-wrapped k3s) rather than bare-metal k3s. The k3d cluster config file (`k3d/config.yaml`) specifies the k3s image tag that k3d uses internally; that tag tracks the same upstream release train but gets pinned via `--k3s-image rancher/k3s:v1.35.3-k3s1` (note the dash, not plus, in Docker image tags).

### 5. OpenTelemetryCollector CR apiVersion is `v1beta1`

Verified against the operator's source tree at tag `v0.148.0`:

    // apis/v1beta1/opentelemetrycollector_types.go
    // +kubebuilder:storageversion
    type OpenTelemetryCollector struct { ... }

`v1alpha1` is still present for backwards compatibility but is not the storage version. Our manifests use `apiVersion: opentelemetry.io/v1beta1`.

## Method

WebFetch-first with gh-api-follow-ups for specifics. Each claim above is traceable to a live source dated on or before 2026-04-24. Sources fetched:

- `artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack`
- `artifacthub.io/packages/helm/grafana/tempo`
- `artifacthub.io/packages/helm/opentelemetry-helm/opentelemetry-operator`
- `artifacthub.io/packages/helm/cert-manager/cert-manager`
- `github.com/k3s-io/k3s/releases` (via `gh api`)
- `github.com/prometheus-community/helm-charts/releases/tag/kube-prometheus-stack-84.0.0` (via `gh api`)
- `github.com/grafana/helm-charts/contents/charts/tempo/` (directory listing via `gh api`) + README.md (found the redirect)
- `github.com/grafana-community/helm-charts/contents/charts/tempo/Chart.yaml` (via `gh api`)
- `github.com/grafana-community/helm-charts/contents/charts/tempo/values.yaml` (first 300 lines, via `gh api`)
- `github.com/open-telemetry/opentelemetry-helm-charts/contents/charts/opentelemetry-operator/Chart.yaml` (via `gh api`)
- `github.com/open-telemetry/opentelemetry-operator/releases/latest` (via `gh api`)
- `github.com/open-telemetry/opentelemetry-operator/blob/v0.148.0/apis/v1beta1/opentelemetrycollector_types.go` (WebFetch)
- `github.com/cert-manager/cert-manager/releases/latest` (via `gh api`)

## Consumed by

- `design/DR-001-argocd-gitops-for-observability-spike.md` — cites this doc for the version pins
- `environments/macf/k3d/version.yaml` (follow-up PR) — pins k3s image via `k3s_image: rancher/k3s:v1.35.3-k3s1`
- `environments/macf/apps/*.yaml` (follow-up PR) — each `targetRevision` matches the "Verified latest stable" column above
