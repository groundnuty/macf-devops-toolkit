#!/usr/bin/env bash
# assert-cluster-identity.sh — refuse to let a mutating script act on whatever
# cluster happens to be the ambient kubectl context (devops-toolkit#202).
#
# WHY THIS EXISTS
#   grafana-reset-password.sh (#201) resolved its target purely from whatever
#   kubectl context happened to be current. Run from the agents VM (context
#   kind-datalake-v2 — an UNRELATED cluster that happens to also have a
#   ns/monitoring), it looked for deployment/kube-prom-stack-grafana, found
#   nothing (that cluster's Grafana Deployment is named monitoring-grafana),
#   and failed with a clean "not found" — which read as "doesn't work from
#   here" and was actually "the guard is absent and a naming coincidence
#   saved us." Same chart release name on that cluster and this would have
#   exec'd in and reset an unrelated cluster's Grafana admin password,
#   reporting success. See #202.
#
# WHAT THIS CHECKS
#   The `kube-prom-stack-grafana` Secret's ArgoCD `tracking-id` annotation, in
#   ns/monitoring. Deliberately NOT "does ns/monitoring exist" or "does A
#   Grafana Deployment exist" — those are exactly the checks that already
#   passed against the wrong cluster in #202's near-miss (the namespace and a
#   deployment both existed there too). The tracking-id annotation is
#   ArgoCD's own resource-provenance stamp:
#     argocd.argoproj.io/tracking-id: argocd-applications_kube-prometheus-stack:/Secret:monitoring/kube-prom-stack-grafana
#   written by the argocd Application in THIS repo (apps/kube-prometheus-
#   stack-app.yaml, sync-wave 0 — installed before anything this guard
#   protects gets a chance to run). A look-alike cluster would need an object
#   with this exact kind+namespace+name AND an ArgoCD instance tracking it
#   under this exact Application name to pass — not just a namespace or
#   deployment that happens to share a name.
#
#   Chosen over node-name / API-endpoint (the AC's other suggested marker):
#   this is already a live Kubernetes object relation with no hardcoded
#   hostname to keep in sync with the VM, and it's the AC's first-preference
#   marker (the issue confirms the annotation is already present on the real
#   cluster).
#
#   Limitation, stated rather than buried: the tracking-id encodes
#   AppProject/Application/Kind/namespace/name, not anything cluster-unique.
#   A second cluster running this exact GitOps config (same repo, same
#   Application name) would also pass. Acceptable at today's one-cluster
#   topology; would need a stronger marker (cluster UID, node name) if a
#   second copy of this stack is ever stood up.
#
# INVOCATION FORM
#   Plain `kubectl`, matching every ACTIVE mutating script in hack/ (checked
#   before writing this — grafana-reset-password.sh, langfuse-bootstrap.sh,
#   copy-clickhouse-creds.sh all call bare `kubectl`, none call
#   `sudo k3s kubectl`). `sudo k3s kubectl` — which bypasses ambient
#   KUBECONFIG entirely and can only ever target this node's own k3s, so it's
#   safe by construction — appears in exactly two places in this repo: the
#   `k3s-install` Makefile recipe (first-bring-up, before this guard's marker
#   Secret exists) and an untracked, already-executed migration script
#   (`manifests/langfuse/recovered-secrets/.phase3-secrets.sh`). Neither is
#   an ongoing entry point this guard needs to cover.
#
# USAGE
#   Source this file, then call the function before the FIRST mutating
#   kubectl/helm call in the script:
#     SCRIPT_DIR="$(dirname -- "${BASH_SOURCE[0]:-$0}")"
#     # shellcheck source=./assert-cluster-identity.sh
#     . "$SCRIPT_DIR/assert-cluster-identity.sh"
#     assert_cluster_identity || exit 1
#   (`|| exit 1` rather than relying on the caller's `set -e` — belt and
#   braces; every current caller has `set -euo pipefail` anyway.)
#
#   For a Makefile recipe that wraps its mutating kubectl call in
#   $(DEVBOX_RUN), invoke this THROUGH THE SAME WRAPPER so both halves
#   resolve `kubectl`/KUBECONFIG identically:
#     @$(DEVBOX_RUN) bash hack/assert-cluster-identity.sh
#
# OVERRIDE
#   MACF_SKIP_CLUSTER_CHECK=1 bypasses (deliberate cross-cluster run — e.g.
#   a scratch cluster). Matches the MACF_SKIP_*_CHECK family used elsewhere
#   in this fleet (check-lgtm-gate.sh, check-mention-routing.sh,
#   check-close-keyword.sh) rather than a bespoke name — this repo doesn't
#   have any other cluster-scoped opt-out to match, and MACF_SKIP_*_CHECK is
#   the dominant, currently-enforced convention (7+ instances) for "bypass
#   this one guard, deliberately, per-invocation."
#
#   The expected tracking-id is hardcoded below, NOT env-overridable — a
#   mismatch can only be worked around by the explicit env var above, never a
#   quiet default change to what "correct" means.
#
# Env overrides (WHERE to look — not what "correct" means, see above):
#   CLUSTER_GUARD_NS, CLUSTER_GUARD_SECRET

assert_cluster_identity() {
  if [ "${MACF_SKIP_CLUSTER_CHECK:-}" = "1" ]; then
    echo "WARNING: MACF_SKIP_CLUSTER_CHECK=1 — cluster-identity guard bypassed." >&2
    echo "  Proceeding on whatever context is current: $(kubectl config current-context 2>/dev/null || echo '(unresolvable)')" >&2
    return 0
  fi

  local ns secret expected ctx found
  ns="${CLUSTER_GUARD_NS:-monitoring}"
  secret="${CLUSTER_GUARD_SECRET:-kube-prom-stack-grafana}"
  expected="argocd-applications_kube-prometheus-stack:/Secret:monitoring/kube-prom-stack-grafana"

  ctx="$(kubectl config current-context 2>/dev/null || echo '(unresolvable)')"
  found="$(kubectl --request-timeout=10s -n "$ns" get secret "$secret" \
    -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null || true)"

  if [ "$found" = "$expected" ]; then
    echo "✓ cluster-identity confirmed (context=$ctx, tracking-id matches ns/$ns secret/$secret)" >&2
    return 0
  fi

  echo "FATAL: cluster-identity check failed — refusing to mutate." >&2
  echo "  kubectl context:              $ctx" >&2
  echo "  expected tracking-id:         $expected" >&2
  if [ -z "$found" ]; then
    echo "  found on ns/$ns secret/$secret: <not found — secret missing, wrong cluster, or annotation absent>" >&2
  else
    echo "  found on ns/$ns secret/$secret: $found" >&2
  fi
  echo "  This means ONE of:" >&2
  echo "    - this is genuinely the wrong cluster (most likely on the agents VM — see #202)" >&2
  echo "    - this IS the monitoring cluster but kube-prometheus-stack hasn't synced yet" >&2
  echo "      (fresh bootstrap: wait for 'make status' to show it Synced, then retry)" >&2
  echo "    - ArgoCD's tracking method differs from what this guard assumes" >&2
  echo "      (verify live: kubectl -n $ns get secret $secret -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}')" >&2
  echo "  Refusing to proceed. Deliberate cross-cluster run: MACF_SKIP_CLUSTER_CHECK=1." >&2
  return 1
}

# Allow standalone invocation for manual verification / a Makefile precheck
# step (does not require sourcing): `bash hack/assert-cluster-identity.sh`
# runs the check once and exits with its result.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  set -uo pipefail
  assert_cluster_identity
fi
