#!/usr/bin/env bash
# OTLP round-trip smoke test.
#
# Sends a synthetic trace (gen_ai.* attrs) via OTLP-HTTP to the central
# Collector, then queries Tempo for it. Expects both port-forwards to be
# running in other terminals (see env vars below).
#
# Port selection: the existing compose observability stack on this host
# (macf-obs-*) binds :4317/:4318/:3200/:16686 — so we forward to high ports
# to avoid collision. Override via env if those are free on your machine.

set -euo pipefail

COLLECTOR_OTLP_HTTP="${COLLECTOR_OTLP_HTTP:-http://127.0.0.1:14318}"
TEMPO_URL="${TEMPO_URL:-http://127.0.0.1:13200}"

# Generate random IDs (traceId = 16 bytes / 32 hex; spanId = 8 bytes / 16 hex)
TRACE_ID=$(openssl rand -hex 16)
SPAN_ID=$(openssl rand -hex 8)
NOW_NS=$(date +%s%N)
END_NS=$((NOW_NS + 500000000))  # +500ms

echo "=== smoke-test: POST a gen_ai span to the Collector ==="
echo "    trace_id=$TRACE_ID"
echo "    span_id=$SPAN_ID"
echo "    collector=$COLLECTOR_OTLP_HTTP"
echo

PAYLOAD=$(cat <<EOF
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "macf-smoke-test"}},
        {"key": "service.version", "value": {"stringValue": "0.1.0"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name": "macf-smoke", "version": "0.1.0"},
      "spans": [{
        "traceId": "$TRACE_ID",
        "spanId": "$SPAN_ID",
        "name": "macf.smoke.llm.call",
        "kind": 3,
        "startTimeUnixNano": "$NOW_NS",
        "endTimeUnixNano": "$END_NS",
        "attributes": [
          {"key": "gen_ai.system", "value": {"stringValue": "anthropic"}},
          {"key": "gen_ai.request.model", "value": {"stringValue": "claude-opus-4-7"}},
          {"key": "gen_ai.operation.name", "value": {"stringValue": "chat"}},
          {"key": "test.source", "value": {"stringValue": "macf-devops-agent-smoke"}}
        ],
        "status": {"code": 1}
      }]
    }]
  }]
}
EOF
)

echo "=== curl POST ==="
echo "$PAYLOAD" | curl -sSi -X POST \
  -H 'Content-Type: application/json' \
  -d @- \
  "$COLLECTOR_OTLP_HTTP/v1/traces"
echo
echo

echo "=== waiting 3s for batch processor + Tempo ingestion ==="
sleep 3

echo "=== GET Tempo traces/$TRACE_ID ==="
curl -sSi "$TEMPO_URL/api/traces/$TRACE_ID" | head -40
echo
echo "=== done. If the trace body appears above with the 'macf.smoke.llm.call' span, the round-trip works. ==="
