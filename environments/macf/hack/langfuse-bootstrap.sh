#!/usr/bin/env bash
# Autonomous Langfuse bootstrap — generates + applies ALL secrets needed to
# bring Langfuse from "argocd has installed the chart, pods are CrashLooping
# on missing Secret refs" to "fully operational + Collector fanout authed."
#
# What this creates:
#   ns/langfuse/secrets:
#     langfuse-secrets        — salt + encryptionKey + nextauth (3 app secrets)
#     langfuse-postgresql     — PG password
#     langfuse-redis          — Valkey password
#     langfuse-clickhouse     — CH password
#     langfuse-s3             — MinIO root-user + root-password
#     langfuse-init           — headless-init env vars: LANGFUSE_INIT_ORG_ID,
#                               PROJECT_ID, PROJECT_PUBLIC_KEY, PROJECT_SECRET_KEY,
#                               USER_EMAIL, USER_NAME, USER_PASSWORD, ORG_NAME,
#                               PROJECT_NAME (read by langfuse-web on first boot)
#   ns/otel/secrets:
#     langfuse-api-keys       — public-key + secret-key (mirrors langfuse-init's
#                               PROJECT_PUBLIC_KEY + PROJECT_SECRET_KEY).
#                               The Collector's otlphttp/langfuse exporter
#                               reads from here for Basic-Auth.
#
# After this script:
#   - kubectl rollout restart deployment/langfuse-web (so it boots with init env)
#   - kubectl rollout restart deployment/central-collector (so it picks up the
#     real keys instead of the placeholder)
#
# Idempotency: re-running rotates ALL secrets, which destroys existing
# Langfuse state (PG/CH password mismatch). Run ONCE per fresh install.
# A second-run-detection guard would be nice but is intentionally omitted —
# explicit operator destructiveness preference: "if you run this twice you
# meant to."

set -euo pipefail

LANGFUSE_NS="${LANGFUSE_NS:-langfuse}"
OTEL_NS="${OTEL_NS:-otel}"

echo "=== langfuse-bootstrap: ns/$LANGFUSE_NS + ns/$OTEL_NS ==="

# Ensure namespaces exist (argocd creates them via syncOptions=CreateNamespace=true,
# but if running pre-argocd-sync, we need them).
kubectl create namespace "$LANGFUSE_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$OTEL_NS" --dry-run=client -o yaml | kubectl apply -f -

# --- Random value generation ---------------------------------------------------
# Hex-only for passwords (URL-safe; avoids Prisma P1013 on base64 +/=).
SALT=$(openssl rand -base64 32)            # NextAuth treats salt as opaque; b64 OK
ENC_KEY=$(openssl rand -hex 32)            # Langfuse expects 32-byte hex (256-bit)
NEXTAUTH=$(openssl rand -base64 32)
PG_PW=$(openssl rand -hex 24)
REDIS_PW=$(openssl rand -hex 24)
CH_PW=$(openssl rand -hex 24)
MINIO_PW=$(openssl rand -hex 24)

# Headless-init values
LF_ORG_ID="macf-org"
LF_ORG_NAME="MACF"
LF_PROJECT_ID="macf-dev"
LF_PROJECT_NAME="macf-dev"
LF_PUBLIC_KEY="pk-lf-$(openssl rand -hex 16)"
LF_SECRET_KEY="sk-lf-$(openssl rand -hex 32)"
LF_USER_EMAIL="admin@macf.local"
LF_USER_NAME="MACF Admin"
LF_USER_PASSWORD=$(openssl rand -hex 16)

TMP=$(mktemp /tmp/langfuse-bootstrap.XXXXXX.yaml)
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<EOF
---
# === ns/$LANGFUSE_NS — subchart auth + app secrets ===========================
apiVersion: v1
kind: Secret
metadata: { name: langfuse-secrets, namespace: $LANGFUSE_NS }
type: Opaque
stringData:
  salt: "$SALT"
  encryptionKey: "$ENC_KEY"
  nextauth: "$NEXTAUTH"
---
apiVersion: v1
kind: Secret
metadata: { name: langfuse-postgresql, namespace: $LANGFUSE_NS }
type: Opaque
stringData: { password: "$PG_PW" }
---
apiVersion: v1
kind: Secret
metadata: { name: langfuse-redis, namespace: $LANGFUSE_NS }
type: Opaque
stringData: { password: "$REDIS_PW" }
---
apiVersion: v1
kind: Secret
metadata: { name: langfuse-clickhouse, namespace: $LANGFUSE_NS }
type: Opaque
stringData: { password: "$CH_PW" }
---
apiVersion: v1
kind: Secret
metadata: { name: langfuse-s3, namespace: $LANGFUSE_NS }
type: Opaque
stringData:
  root-user: "langfuse-minio"
  root-password: "$MINIO_PW"
---
# Headless-init Secret — keys are env-var-named (consumed via additionalEnvFrom
# secretRef in values/langfuse.yaml). See:
# https://langfuse.com/self-hosting/headless-initialization
apiVersion: v1
kind: Secret
metadata: { name: langfuse-init, namespace: $LANGFUSE_NS }
type: Opaque
stringData:
  LANGFUSE_INIT_ORG_ID: "$LF_ORG_ID"
  LANGFUSE_INIT_ORG_NAME: "$LF_ORG_NAME"
  LANGFUSE_INIT_PROJECT_ID: "$LF_PROJECT_ID"
  LANGFUSE_INIT_PROJECT_NAME: "$LF_PROJECT_NAME"
  LANGFUSE_INIT_PROJECT_PUBLIC_KEY: "$LF_PUBLIC_KEY"
  LANGFUSE_INIT_PROJECT_SECRET_KEY: "$LF_SECRET_KEY"
  LANGFUSE_INIT_USER_EMAIL: "$LF_USER_EMAIL"
  LANGFUSE_INIT_USER_NAME: "$LF_USER_NAME"
  LANGFUSE_INIT_USER_PASSWORD: "$LF_USER_PASSWORD"
---
# === ns/$OTEL_NS — Collector's basic-auth source ============================
# Same public+secret keys as the headless-init Secret above (single source of
# truth — keys generated once + flow into both consumers).
apiVersion: v1
kind: Secret
metadata: { name: langfuse-api-keys, namespace: $OTEL_NS }
type: Opaque
stringData:
  public-key: "$LF_PUBLIC_KEY"
  secret-key: "$LF_SECRET_KEY"
EOF

kubectl apply -f "$TMP"

echo
echo "=== rolling restart langfuse-web (re-init from env) + central-collector (pick up real keys) ==="
kubectl -n "$LANGFUSE_NS" rollout restart deployment/langfuse-web 2>/dev/null || \
    echo "  langfuse-web Deployment not yet reconciled — argocd will start it with these secrets present"
kubectl -n "$OTEL_NS" rollout restart deployment/central-collector 2>/dev/null || \
    echo "  central-collector Deployment not yet reconciled — argocd will pick up secrets on next sync"

echo
echo "=== bootstrap complete ==="
echo
echo "Admin login (Langfuse UI via \`make pf-langfuse\`, http://127.0.0.1:3001):"
echo "  email:    $LF_USER_EMAIL"
echo "  password: $LF_USER_PASSWORD"
echo
echo "Run \`make smoke\` to verify the OTLP round-trip via Tempo + Langfuse."
