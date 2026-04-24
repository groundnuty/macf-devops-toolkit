#!/usr/bin/env bash
# Tear down the MACF observability stack (reverse of install.sh).
# Leaves k3s itself running; see README §teardown for the full cluster reset.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"

# Helm uninstall is idempotent (--ignore-not-found). Namespace deletes are not
# — they may hang on finalizers, so we delete releases first, then namespaces.

echo "==> Deleting central OpenTelemetryCollector CR + RBAC"
kubectl delete -f "$K8S_DIR/manifests/otel-collector.yaml" --ignore-not-found

echo "==> Deleting Tempo Grafana-datasource ConfigMap"
kubectl delete -f "$K8S_DIR/manifests/tempo-grafana-datasource.yaml" --ignore-not-found

echo "==> Uninstalling opentelemetry-operator"
helm uninstall otel-operator --namespace otel-operator-system --ignore-not-found
kubectl delete namespace otel-operator-system --ignore-not-found --wait=false
kubectl delete namespace otel --ignore-not-found --wait=false

echo "==> Uninstalling tempo"
helm uninstall tempo --namespace tempo --ignore-not-found
kubectl delete namespace tempo --ignore-not-found --wait=false

echo "==> Uninstalling kube-prometheus-stack"
helm uninstall kube-prom-stack --namespace monitoring --ignore-not-found
# kube-prom-stack leaves CRDs behind by design; explicit cleanup if desired:
#   kubectl delete crd prometheuses.monitoring.coreos.com \
#     servicemonitors.monitoring.coreos.com ... (see chart README)
kubectl delete namespace monitoring --ignore-not-found --wait=false

echo "==> Uninstalling cert-manager"
helm uninstall cert-manager --namespace cert-manager --ignore-not-found
kubectl delete namespace cert-manager --ignore-not-found --wait=false

echo
echo "=========================================================="
echo "Uninstall complete."
echo "k3s itself is still running. For a full reset:"
echo "  sudo /usr/local/bin/k3s-uninstall.sh"
echo "  sudo rm -rf /var/lib/rancher/k3s /etc/rancher/k3s"
echo "=========================================================="
