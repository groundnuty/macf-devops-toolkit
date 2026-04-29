#!/usr/bin/env bash
# Pattern A result-invariant assertion (per silent-fallback-hazards.md
# Instance 8): detect "OTLP ingested but search returns zero" silent-drops.
#
# Background: the OTel Collector + Tempo ingestion path can succeed
# (HTTP 200, `tempo_distributor_spans_received_total` increments) while
# search-side queries return zero traces. Possible causes:
#   - Wrong port: agent sends to a port no one listens on, gets retry
#     backoff, drops spans. (devops-toolkit#60 — :4318 vs :14318.)
#   - Pipeline silently broken: Collector accepts but exporter fails
#     mid-batch.
#   - Storage backend latency: ingestion ahead of indexing for >5min.
#
# This script asserts the result invariant at observation time:
#   if  (ingestion increments over window)
#   AND (search returns 0 traces in same window)
#   then alert
#
# Designed for cron/CI invocation (exits non-zero on assertion failure)
# but also useful for one-shot operator verification.
#
# Usage:
#   bash hack/check-tempo-ingestion.sh                # default 5-min window
#   WINDOW_SECONDS=300 bash hack/check-tempo-ingestion.sh
#
# Requires: kubectl access to the cluster, port-forward on :13200 (Tempo)
# auto-managed by this script if not already running.

set -euo pipefail

WINDOW_SECONDS="${WINDOW_SECONDS:-300}"
TEMPO_NS="${TEMPO_NS:-tempo}"
TEMPO_SVC="${TEMPO_SVC:-tempo}"
TEMPO_PORT="${TEMPO_PORT:-13200}"

# Auto-start tempo port-forward if not already listening
if ! ss -tlnp 2>/dev/null | grep -q ":${TEMPO_PORT} "; then
  kubectl -n "$TEMPO_NS" port-forward "svc/$TEMPO_SVC" "${TEMPO_PORT}:3200" >/tmp/pf-check-tempo.log 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null || true' EXIT
  sleep 3
fi

# Sample distributor counter pre-window
read_counter() {
  curl -sS "http://127.0.0.1:${TEMPO_PORT}/metrics" 2>/dev/null \
    | awk '/^tempo_distributor_spans_received_total/ {sum+=$2} END {print sum+0}'
}

T0=$(date -u +%s)
COUNTER_T0=$(read_counter)

echo "Pattern A check starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  window: ${WINDOW_SECONDS}s"
echo "  ingestion counter at T0: $COUNTER_T0"
echo "Waiting..."
sleep "$WINDOW_SECONDS"

T1=$(date -u +%s)
COUNTER_T1=$(read_counter)
DELTA=$((COUNTER_T1 - COUNTER_T0))

echo "  ingestion counter at T1: $COUNTER_T1"
echo "  delta over window: $DELTA spans"

# Search-side query for any traces in the window
SEARCH_RESPONSE=$(curl -sS -G "http://127.0.0.1:${TEMPO_PORT}/api/search" \
  --data-urlencode "q={}" \
  --data-urlencode "limit=1" \
  --data-urlencode "start=$T0" \
  --data-urlencode "end=$T1" 2>/dev/null)
SEARCH_COUNT=$(echo "$SEARCH_RESPONSE" | jq -r '.traces | length')
echo "  search-side trace count in window: $SEARCH_COUNT"

# Pattern A invariant: if ingestion is happening but search returns 0
# over a window, we have a silent-drop somewhere downstream.
if [ "$DELTA" -gt 0 ] && [ "$SEARCH_COUNT" -eq 0 ]; then
  echo ""
  echo "::error::Pattern A assertion FAILED — silent-drop detected"
  echo "  ingestion: $DELTA spans accepted by distributor"
  echo "  search:    0 traces queryable in the same window"
  echo ""
  echo "Likely causes:"
  echo "  1. Senders pointing to wrong host port (compose-stack:4318 vs cluster:14318)"
  echo "  2. Collector exporter pipeline silently broken (check Collector pod logs)"
  echo "  3. Tempo storage backend write failures (check tempo-0 logs + PVC)"
  echo "  4. Indexing lag > window (rare; widen WINDOW_SECONDS to discriminate)"
  echo ""
  echo "See silent-fallback-hazards.md Instance 8 + devops-toolkit#60 for diagnosis pattern."
  exit 1
fi

if [ "$DELTA" -eq 0 ]; then
  echo ""
  echo "::notice::No ingestion activity over the window — assertion vacuously holds."
  echo "  This is normal during quiet periods. Re-run during/after agent activity"
  echo "  to exercise the actual ingestion-vs-search invariant."
  exit 0
fi

echo ""
echo "::notice::Pattern A invariant holds — ingestion + search aligned."
echo "  $DELTA spans ingested, $SEARCH_COUNT traces queryable."
exit 0
