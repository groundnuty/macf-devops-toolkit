#!/usr/bin/env bash
# Copy the langfuse-clickhouse Secret's password from ns/langfuse to a new
# `langfuse-clickhouse-creds` Secret in ns/otel, so the logs DaemonSet
# Collector can authenticate to ClickHouse for the `clickhouse` exporter.
#
# Why a one-shot script vs an in-cluster sync mechanism:
#   - For the spike, single-source-of-truth + small surface > clever sync.
#   - Cross-namespace Secret references aren't supported by k8s natively.
#   - external-secrets / Reflector add a controller dependency we don't want
#     in dev. Operator runs `make clickhouse-logs-creds` once after install.
#
# Idempotent — re-running rewrites the destination Secret in place.
#
# Pattern mirrored from hack/langfuse-bootstrap.sh's cross-namespace Secret
# population (langfuse-init in ns/langfuse → langfuse-api-keys in ns/otel).

set -euo pipefail

NS_SRC="${NS_SRC:-langfuse}"
SRC_NAME="${SRC_NAME:-langfuse-clickhouse}"
NS_DST="${NS_DST:-otel}"
DST_NAME="${DST_NAME:-langfuse-clickhouse-creds}"

echo "Reading password from ${NS_SRC}/${SRC_NAME}..."
PW=$(kubectl -n "$NS_SRC" get secret "$SRC_NAME" -o jsonpath='{.data.password}' | base64 -d)
if [ -z "$PW" ]; then
    echo "FAIL: empty password in ${NS_SRC}/${SRC_NAME}" >&2
    exit 1
fi

echo "Writing ${NS_DST}/${DST_NAME} (key: password)..."
kubectl -n "$NS_DST" create secret generic "$DST_NAME" \
    --from-literal=password="$PW" \
    --dry-run=client -o yaml \
    | kubectl apply -f -

echo "OK ${NS_DST}/${DST_NAME} populated (${#PW} chars)."
