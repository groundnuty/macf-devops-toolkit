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

# --- Langfuse leg --------------------------------------------------------------
# Second verification path per #11 + science-agent review on PR #12:
# after POSTing to the Collector's otlphttp/langfuse exporter fans to Langfuse,
# we should see the span via Langfuse's /api/public/traces API with
# gen_ai.* attrs visible.
#
# Auth: reads keys from the langfuse-api-keys Secret in ns/otel
# (see hack/langfuse-api-keys.sh). If keys are the bootstrap-placeholder
# values (pk-lf-placeholder / sk-lf-placeholder), the request 401s and we
# report SKIPPED — not a hard failure. Operator runs `make langfuse-api-keys`
# to wire real keys.

LANGFUSE_URL="${LANGFUSE_URL:-http://127.0.0.1:3001}"

echo "=== Langfuse leg ==="
if ! kubectl -n otel get secret langfuse-api-keys >/dev/null 2>&1; then
    echo "SKIP: ns/otel Secret langfuse-api-keys not found (run \`make langfuse-api-keys\` after Langfuse UI signup)"
elif [ -z "${LANGFUSE_PUBLIC_KEY:-}" ] || [ -z "${LANGFUSE_SECRET_KEY:-}" ]; then
    PK=$(kubectl -n otel get secret langfuse-api-keys -o jsonpath='{.data.public-key}' | base64 -d 2>/dev/null || echo "")
    SK=$(kubectl -n otel get secret langfuse-api-keys -o jsonpath='{.data.secret-key}' | base64 -d 2>/dev/null || echo "")
    case "$PK" in
        pk-lf-placeholder*|"" )
            echo "SKIP: langfuse-api-keys Secret holds placeholder values — run \`make langfuse-api-keys\` with real keys from Langfuse UI"
            ;;
        *)
            # Also need Langfuse port-forwarded — assume `make pf-langfuse` is running.
            echo "GET Langfuse /api/public/traces/$TRACE_ID"
            # Langfuse needs more time than Tempo on first ingest (goes through
            # queue → worker → ClickHouse). Give it 10s extra beyond the 3s
            # Tempo wait above.
            sleep 10
            curl -sS -u "$PK:$SK" "$LANGFUSE_URL/api/public/traces/$TRACE_ID" | jq -e '.observations[0].modelParameters // .gen_ai // {}' 2>/dev/null || true
            curl -sSi -u "$PK:$SK" "$LANGFUSE_URL/api/public/traces/$TRACE_ID" | head -5
            ;;
    esac
fi
echo

# --- Prometheus metrics leg ----------------------------------------------------
# Third verification path per #18: POST an OTLP metric to the Collector and
# query Prometheus for it within ~30s (Prometheus scrapes :8889 every 30s).
#
# Reuses the same trace_id as the span above — gives a stable correlation
# label (`trace_id="$TRACE_ID"` works as a metric exemplar attr too).
#
# Prometheus port-forward is operator-side: `make pf-prometheus` (or
# `kubectl -n monitoring port-forward svc/kube-prom-stack-kube-prome-prometheus 9090:9090`).
# If :9090 is not reachable, this leg SKIPs without failing the smoke.

PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"

echo "=== Prometheus metrics leg ==="
METRIC_PAYLOAD=$(cat <<EOF
{"resourceMetrics":[{"resource":{"attributes":[
  {"key":"service.name","value":{"stringValue":"macf-smoke-test"}},
  {"key":"service.version","value":{"stringValue":"0.1.0"}}
]},"scopeMetrics":[{"scope":{"name":"macf-smoke","version":"0.1.0"},
"metrics":[{"name":"macf_smoke_counter","unit":"1","sum":{
  "aggregationTemporality":2,"isMonotonic":true,
  "dataPoints":[{
    "asInt":"1","timeUnixNano":"$NOW_NS",
    "attributes":[
      {"key":"trace_id","value":{"stringValue":"$TRACE_ID"}},
      {"key":"test.source","value":{"stringValue":"macf-devops-agent-smoke"}}
    ]
  }]
}}]}]}]}
EOF
)

echo "POST $COLLECTOR_OTLP_HTTP/v1/metrics  (trace_id=$TRACE_ID)"
echo "$METRIC_PAYLOAD" | curl -sSi -X POST \
  -H 'Content-Type: application/json' \
  -d @- \
  "$COLLECTOR_OTLP_HTTP/v1/metrics" | head -3
echo

if curl -sf -o /dev/null -m 2 "$PROM_URL/-/ready"; then
    # `{` `}` `"` must be URL-encoded — `--data-urlencode` + `-G` handles it.
    Q="macf_smoke_counter_total{trace_id=\"$TRACE_ID\"}"
    echo "Polling $PROM_URL for $Q (up to 60s — scrape interval is 30s)..."
    FOUND=""
    for i in $(seq 1 12); do
        sleep 5
        if curl -sf -G "$PROM_URL/api/v1/query" --data-urlencode "query=$Q" \
             | jq -e '.data.result | length > 0' >/dev/null 2>&1; then
            FOUND=1
            echo "  ✓ found after ${i}x5s"
            break
        fi
    done
    if [ -n "$FOUND" ]; then
        curl -sS -G "$PROM_URL/api/v1/query" --data-urlencode "query=$Q" | jq '.data.result[0]'
    else
        echo "  ✗ NOT FOUND after 60s"
    fi
else
    echo "SKIP: Prometheus at $PROM_URL not reachable (run \`make pf-prometheus\`)"
fi
echo
echo "=== done. Tempo + Langfuse + Prometheus legs above. ==="
