#!/usr/bin/env bash
# grafana-reset-password.sh — realign Grafana's DB admin password to whatever
# the `kube-prom-stack-grafana` Secret currently publishes (devops-toolkit#183).
#
# WHY THIS EXISTS
#   `adminPassword: ""` in values/kube-prometheus-stack.yaml (see the comment
#   block there) makes the chart GENERATE a password into the Secret.
#   `GF_SECURITY_ADMIN_PASSWORD` (the pod env var sourced from that Secret)
#   only seeds Grafana's `admin` DB row at FIRST DATABASE INIT — the PVC
#   persists the user table across every later restart/upgrade, so once the
#   DB has an `admin` row, the env var is read once at container start and
#   never resyncs it. When the Secret's value changes without the DB
#   following (helm re-render, `kubectl delete secret`, manual edit — see
#   #183 for a concrete mechanism), the published password stops matching
#   what the DB accepts. The deployment otherwise looks completely healthy
#   (pod env == Secret, /api/health green) — the only symptom is `POST
#   /login` 401ing with the password `make grafana-password` just printed.
#
# WHAT THIS DOES
#   Reads the CURRENT Secret value (the source of truth for "what should the
#   password be") and re-applies it to the live DB via `grafana cli admin
#   reset-admin-password`, run in-pod with the password piped over stdin
#   (never argv — argv is visible to anyone who can read the container's
#   process list / /proc/<pid>/cmdline). Then verifies the DB actually
#   accepted it with a real POST /login.
#
# SAFETY — READ BEFORE RUNNING
#   This resets a shared UI's ADMIN credential. If a human has deliberately
#   hand-set a password and is relying on it (e.g. a live browser session,
#   a password manager entry), running this locks them out — the DB gets
#   overwritten to match whatever the Secret currently holds, not the other
#   way around. This script is OPERATOR-INVOKED ONLY: nothing in this repo's
#   automation calls it unattended. Confirm nobody's relying on an
#   out-of-band password before running `make grafana-reset-password`.
#
# IDEMPOTENT — safe to run when nothing is broken. `reset-admin-password`
# sets the DB to the value given; if the DB already matches the Secret, this
# is a no-op with a slightly wasteful round-trip, not a destructive action.
#
# Usage:
#   make grafana-reset-password
#   bash hack/grafana-reset-password.sh
#
# Env overrides (mirror check-fleet-telemetry-ingestion.sh's naming):
#   GRAFANA_NS, GRAFANA_SECRET, GRAFANA_DEPLOY, GRAFANA_CONTAINER, GRAFANA_USER
#   MACF_MON_HOST, MACF_GRAFANA_URL

set -euo pipefail

GRAFANA_NS="${GRAFANA_NS:-monitoring}"
GRAFANA_SECRET="${GRAFANA_SECRET:-kube-prom-stack-grafana}"
GRAFANA_DEPLOY="${GRAFANA_DEPLOY:-deployment/kube-prom-stack-grafana}"
GRAFANA_CONTAINER="${GRAFANA_CONTAINER:-grafana}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
MON_HOST="${MACF_MON_HOST:-orzech-dev-agents-monitoring.tail491af.ts.net}"
GRAFANA_URL="${MACF_GRAFANA_URL:-http://$MON_HOST:3000}"

echo "=== grafana-reset-password: ns/$GRAFANA_NS secret/$GRAFANA_SECRET -> $GRAFANA_DEPLOY ==="

# --- resolve the pod dynamically -----------------------------------------------
# `kubectl exec deployment/<name>` resolves to whichever pod the Deployment
# currently owns at call time — never hardcode a pod name, it changes on
# every rollout/reschedule. Fail loud up front if the Deployment is gone
# rather than let `exec` produce a confusing "not found" deep in the chain.
kubectl -n "$GRAFANA_NS" get "$GRAFANA_DEPLOY" >/dev/null || {
  echo "FATAL: $GRAFANA_DEPLOY not found in ns/$GRAFANA_NS" >&2
  exit 1
}

# --- read the Secret's CURRENT value — the source of truth ---------------------
PASSWORD=$(kubectl -n "$GRAFANA_NS" get secret "$GRAFANA_SECRET" \
  -o jsonpath='{.data.admin-password}' | base64 -d)
[ -n "$PASSWORD" ] || {
  echo "FATAL: empty admin-password in secret/$GRAFANA_SECRET (ns/$GRAFANA_NS)" >&2
  exit 1
}

# --- realign the DB: password piped via stdin, NEVER argv ----------------------
# `grafana cli admin reset-admin-password <pw>` (positional arg) would put the
# password in the container's argv — visible via `ps` / /proc/<pid>/cmdline to
# anyone with exec access to the pod. `--password-from-stdin` avoids that.
# (This exact invocation is the one already verified working against this
# cluster's Grafana 13.0.1 — see devops-toolkit#183.)
echo "--- resetting DB admin password (stdin, not argv) ---"
printf '%s' "$PASSWORD" | kubectl -n "$GRAFANA_NS" exec -i "$GRAFANA_DEPLOY" -c "$GRAFANA_CONTAINER" -- \
  grafana cli --homepath /usr/share/grafana admin reset-admin-password --password-from-stdin

# --- verify: the DB must now accept the Secret's password ----------------------
echo "--- verifying via POST $GRAFANA_URL/login ---"
HTTP_CODE=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d "{\"user\":\"$GRAFANA_USER\",\"password\":\"$PASSWORD\"}" \
  "$GRAFANA_URL/login" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" != "200" ]; then
  echo "FATAL: POST $GRAFANA_URL/login -> $HTTP_CODE (expected 200) — reset did not take." >&2
  echo "  Check: is $GRAFANA_URL reachable from here? Does ns/$GRAFANA_NS/secret/$GRAFANA_SECRET" >&2
  echo "  actually match what was just applied? (a concurrent ArgoCD selfHeal sync could have" >&2
  echo "  overwritten the Secret again between the read above and this check — re-run to confirm)." >&2
  exit 1
fi

echo "✓ POST $GRAFANA_URL/login -> 200. Grafana's DB password now matches secret/$GRAFANA_SECRET."
echo "  Retrieve it any time with: make grafana-password"
