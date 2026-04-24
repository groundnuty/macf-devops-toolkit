#!/usr/bin/env bash
# Prompt operator for Langfuse project API keys + apply to ns/otel as
# `langfuse-api-keys` Secret (consumed by the central OpenTelemetry
# Collector's otlphttp/langfuse exporter).
#
# How to get the keys (one-time):
#   1. make pf-langfuse    (in another terminal, blocks)
#   2. Open http://127.0.0.1:3001 in a browser
#   3. First-time: sign up (first user becomes admin of the default org)
#   4. "New project" → name it (e.g. "macf-dev")
#   5. Project settings → API Keys → "Create new API key"
#   6. Copy the public key (starts pk-lf-) + secret key (starts sk-lf-)
#   7. Run this script + paste when prompted
#
# The Collector's Deployment picks up the updated Secret on next rollout.
# `kubectl rollout restart deployment/central-collector -n otel` triggers it.

set -euo pipefail

NS="${NS:-otel}"

echo "=== langfuse-api-keys: ns=$NS ==="
echo
echo "Retrieve keys from Langfuse UI first (see comment block in this script)."
echo

read -r -p "Public key  (pk-lf-...): " PUBLIC_KEY
read -r -s -p "Secret key (sk-lf-...): " SECRET_KEY
echo
echo

# Quick sanity check — warn if keys don't look right, but don't block.
case "$PUBLIC_KEY" in
    pk-lf-*) ;;
    *) echo "WARN: public key doesn't start with 'pk-lf-'. Continuing anyway." ;;
esac
case "$SECRET_KEY" in
    sk-lf-*) ;;
    *) echo "WARN: secret key doesn't start with 'sk-lf-'. Continuing anyway." ;;
esac

# Apply Secret.
TMP=$(mktemp /tmp/langfuse-api-keys.XXXXXX.yaml)
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<EOF
apiVersion: v1
kind: Secret
metadata: { name: langfuse-api-keys, namespace: $NS }
type: Opaque
stringData:
  public-key: "$PUBLIC_KEY"
  secret-key: "$SECRET_KEY"
EOF

kubectl apply -f "$TMP"
echo
echo "=== Secret langfuse-api-keys applied to ns/$NS ==="
echo
echo "Triggering central-collector rollout to pick up the new keys..."
kubectl -n "$NS" rollout restart deployment/central-collector 2>/dev/null || \
    echo "NOTE: central-collector deployment not found (probably not yet reconciled); restart happens automatically on next argocd sync."

echo "=== done. ==="
