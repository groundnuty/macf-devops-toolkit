#!/usr/bin/env bash
# Install the MACF observability stack on k3s (idempotent).
# See ../README.md for the full version matrix and rationale.
#
# Prerequisite: k3s must already be running and $KUBECONFIG must resolve.
# See README §k3s bootstrap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"

# Pinned chart versions — see ../README.md "Version matrix".
CERT_MANAGER_VERSION="v1.20.2"
KUBE_PROM_STACK_VERSION="84.0.0"
TEMPO_VERSION="2.0.0"
OTEL_OPERATOR_VERSION="0.110.0"

echo "==> kubectl context: $(kubectl config current-context 2>/dev/null || echo '<none>')"
kubectl cluster-info >/dev/null || { echo "ERROR: cluster unreachable; check KUBECONFIG"; exit 1; }

echo "==> Adding / updating helm repos"
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update
helm repo update

echo "==> 1/5 cert-manager (required for kube-prom + otel-operator webhooks)"
helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --values "$K8S_DIR/values/cert-manager.yaml" \
    --wait --timeout 5m

echo "==> 2/5 kube-prometheus-stack (Prometheus + Grafana + Alertmanager)"
helm upgrade --install kube-prom-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --version "$KUBE_PROM_STACK_VERSION" \
    --values "$K8S_DIR/values/kube-prometheus-stack.yaml" \
    --wait --timeout 10m

echo "==> 3/5 tempo (monolithic, from grafana-community repo)"
helm upgrade --install tempo grafana-community/tempo \
    --namespace tempo --create-namespace \
    --version "$TEMPO_VERSION" \
    --values "$K8S_DIR/values/tempo.yaml" \
    --wait --timeout 5m

echo "==> Applying Tempo Grafana-datasource ConfigMap"
kubectl apply -f "$K8S_DIR/manifests/tempo-grafana-datasource.yaml"

echo "==> 4/5 opentelemetry-operator"
helm upgrade --install otel-operator open-telemetry/opentelemetry-operator \
    --namespace otel-operator-system --create-namespace \
    --version "$OTEL_OPERATOR_VERSION" \
    --values "$K8S_DIR/values/opentelemetry-operator.yaml" \
    --wait --timeout 5m

echo "==> 5/5 Applying central OpenTelemetryCollector CR + RBAC"
kubectl apply -f "$K8S_DIR/manifests/otel-collector.yaml"

# Wait for the collector Deployment to come up (CR creation -> Deployment
# reconciliation is a few seconds via the operator).
echo "==> Waiting for central-collector rollout"
kubectl -n otel rollout status deployment/central-collector --timeout=3m

echo
echo "=========================================================="
echo "Install complete."
echo
echo "Grafana:"
echo "  kubectl -n monitoring port-forward svc/kube-prom-stack-grafana 3000:80"
echo "  kubectl -n monitoring get secret kube-prom-stack-grafana \\"
echo "    -o jsonpath='{.data.admin-password}' | base64 -d"
echo
echo "Collector OTLP ingress:"
echo "  kubectl -n otel port-forward svc/central-collector 4317:4317 4318:4318"
echo "=========================================================="
