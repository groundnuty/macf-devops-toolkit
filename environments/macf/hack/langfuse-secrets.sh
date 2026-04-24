#!/usr/bin/env bash
# Generate + apply the 5 Langfuse Secrets (langfuse-secrets + 4 subchart-auth)
# to the `langfuse` namespace. Idempotent — subsequent runs REPLACE the Secrets
# with newly-generated values, which WILL invalidate the Langfuse deployment's
# JWT / encryption / DB passwords. Run ONCE at first install unless rotating.
#
# This script is the implementation behind `make langfuse-secrets`. Template
# at manifests/langfuse/secrets.yaml.example shows the shape without values.

set -euo pipefail

NS="${NS:-langfuse}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== langfuse-secrets: ns=$NS ==="

# Guard: fail loudly if the ns doesn't exist yet (argocd creates it when
# the Langfuse Application first reconciles; this script can run either before
# or after that, but we need the ns to exist one way or another).
if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
    echo "Creating namespace $NS..."
    kubectl create namespace "$NS"
fi

# Generators — keep consistent with manifests/langfuse/secrets.yaml.example.
SALT=$(openssl rand -base64 32)
ENC_KEY=$(openssl rand -hex 32)
NEXTAUTH=$(openssl rand -base64 32)
PG_PW=$(openssl rand -hex 24)
REDIS_PW=$(openssl rand -hex 24)
CH_PW=$(openssl rand -hex 24)
MINIO_PW=$(openssl rand -hex 24)

# Feed a rendered manifest through `kubectl apply` so the same set is
# replaced atomically. Temp file scoped to the process; trap cleans up.
TMP=$(mktemp /tmp/langfuse-secrets.XXXXXX.yaml)
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<EOF
---
apiVersion: v1
kind: Secret
metadata: { name: langfuse-secrets, namespace: $NS }
type: Opaque
stringData:
  salt: "$SALT"
  encryptionKey: "$ENC_KEY"
  nextauth: "$NEXTAUTH"
---
apiVersion: v1
kind: Secret
metadata: { name: langfuse-postgresql, namespace: $NS }
type: Opaque
stringData: { password: "$PG_PW" }
---
apiVersion: v1
kind: Secret
metadata: { name: langfuse-redis, namespace: $NS }
type: Opaque
stringData: { password: "$REDIS_PW" }
---
apiVersion: v1
kind: Secret
metadata: { name: langfuse-clickhouse, namespace: $NS }
type: Opaque
stringData: { password: "$CH_PW" }
---
apiVersion: v1
kind: Secret
metadata: { name: langfuse-s3, namespace: $NS }
type: Opaque
stringData:
  root-user: "langfuse-minio"
  root-password: "$MINIO_PW"
EOF

kubectl apply -f "$TMP"
echo
echo "=== done. 5 Secrets applied to ns/$NS ==="
echo "   (salt, encryptionKey, nextauth, 4 subchart auth passwords — all randomly generated)"
