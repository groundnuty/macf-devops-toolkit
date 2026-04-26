#!/usr/bin/env bash
# Observability snapshot — bundle traces / metrics / logs from a window
# into a single directory. Per DR-002.
#
# Two modes:
#
#   --mode time-window  (the primitive)
#     Inputs: --filter-key <attr>, --filter-value <val>, --start <epoch>, --end <epoch>
#     Queries each backend for spans/metrics/logs matching the filter
#     within the time window. Writes JSON files to --out-dir.
#
#   --mode github-issue  (convenience wrapper for the per-issue use-case)
#     Inputs: --repo <owner>/<repo>, --issue <N>
#     Pulls the issue's GitHub event timeline, derives:
#       - actor = the agent who closed the issue
#       - filter = gen_ai.agent.name=<actor>
#       - time window = union of [t-5min, t+5min] around each event by actor,
#                       collapsed to overall (start, end)
#     Then dispatches to time-window mode.
#
# All queries run from the VM where the cluster lives (uses kubectl
# port-forwards and `kubectl exec`). For GH Actions remote invocation,
# the runner SSHes in and runs this script there — same execution
# environment.
#
# Out-dir layout (per DR-002):
#   <out-dir>/
#   ├── manifest.json
#   ├── traces-tempo.json
#   ├── traces-langfuse.json
#   ├── logs-loki.json
#   ├── logs-clickhouse.json
#   ├── metrics-prom.json
#   └── grafana-urls.json

set -euo pipefail

# --- Args -------------------------------------------------------------------
MODE=""
FILTER_KEY=""
FILTER_VALUE=""
START_EPOCH=""
END_EPOCH=""
OUT_DIR=""
REPO=""
ISSUE=""
GRAFANA_BASE="${GRAFANA_BASE:-http://127.0.0.1:3000}"

usage() {
  cat <<USAGE >&2
Usage:
  $0 --mode time-window --filter-key <attr> --filter-value <val> --start <epoch> --end <epoch> --out-dir <path>
  $0 --mode github-issue --repo <owner>/<repo> --issue <N> --out-dir <path>

Optional:
  --grafana-base <url>   Base URL for Grafana drill-in links (default: http://127.0.0.1:3000)
USAGE
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)         MODE="$2"; shift 2 ;;
    --filter-key)   FILTER_KEY="$2"; shift 2 ;;
    --filter-value) FILTER_VALUE="$2"; shift 2 ;;
    --start)        START_EPOCH="$2"; shift 2 ;;
    --end)          END_EPOCH="$2"; shift 2 ;;
    --repo)         REPO="$2"; shift 2 ;;
    --issue)        ISSUE="$2"; shift 2 ;;
    --out-dir)      OUT_DIR="$2"; shift 2 ;;
    --grafana-base) GRAFANA_BASE="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *)              echo "unknown arg: $1" >&2; usage ;;
  esac
done

[ -z "$OUT_DIR" ] && usage
mkdir -p "$OUT_DIR"

# --- Mode dispatch ----------------------------------------------------------
if [ "$MODE" = "github-issue" ]; then
  [ -z "$REPO" ] || [ -z "$ISSUE" ] && usage
  command -v gh >/dev/null || { echo "error: gh CLI not on PATH" >&2; exit 1; }
  echo "Deriving time window + filter from $REPO#$ISSUE GitHub events..."

  ACTOR=$(gh issue view "$ISSUE" --repo "$REPO" --json closedBy --jq '.closedBy.login // empty' 2>/dev/null || true)
  if [ -z "$ACTOR" ]; then
    # Fallback: assignee, then issue author
    ACTOR=$(gh issue view "$ISSUE" --repo "$REPO" --json assignees,author --jq '.assignees[0].login // .author.login // empty')
  fi
  # GitHub returns bot logins as `app/<name>` (or `<name>[bot]` in some
  # endpoint shapes). Strip both forms so the filter matches the
  # `gen_ai.agent.name` resource attr stamped by claude.sh (which has
  # neither prefix nor suffix — just the canonical bot name).
  AGENT_NAME=$(echo "$ACTOR" | sed -e 's,^app/,,' -e 's,\[bot\]$,,')
  FILTER_KEY="${FILTER_KEY:-gen_ai.agent.name}"
  FILTER_VALUE="${FILTER_VALUE:-$AGENT_NAME}"

  # Build time window from the issue timeline. Use the issue's
  # createdAt → closedAt as the outer bound (within-retention safe).
  CREATED_AT=$(gh issue view "$ISSUE" --repo "$REPO" --json createdAt --jq '.createdAt')
  CLOSED_AT=$(gh issue view "$ISSUE" --repo "$REPO" --json closedAt --jq '.closedAt // (now | todate)')
  START_EPOCH=$(date -u -d "$CREATED_AT" +%s)
  END_EPOCH=$(date -u -d "$CLOSED_AT" +%s)

  echo "  actor=$ACTOR  filter=$FILTER_KEY=$FILTER_VALUE  window=[$START_EPOCH, $END_EPOCH]"

elif [ "$MODE" = "time-window" ]; then
  [ -z "$FILTER_KEY" ] || [ -z "$FILTER_VALUE" ] || [ -z "$START_EPOCH" ] || [ -z "$END_EPOCH" ] && usage
else
  usage
fi

# --- Port-forward helpers ---------------------------------------------------
# Each backend gets a transient port-forward managed by this script.
declare -A PF_PIDS=()
declare -A PF_PORTS=([tempo]=13200 [loki]=3100 [langfuse]=3001 [prom]=9090)

pf_start() {
  local name=$1 ns=$2 svc=$3 lport=$4 rport=$5
  if ss -tlnp 2>/dev/null | grep -q ":${lport} "; then
    echo "  pf-$name: already listening on :${lport} (operator's port-forward) — reusing"
    return
  fi
  kubectl -n "$ns" port-forward "svc/$svc" "${lport}:${rport}" >/tmp/pf-snap-$name.log 2>&1 &
  PF_PIDS[$name]=$!
  sleep 3  # let the pf bind
}

pf_cleanup() {
  for name in "${!PF_PIDS[@]}"; do
    kill "${PF_PIDS[$name]}" 2>/dev/null || true
  done
}
trap pf_cleanup EXIT

# --- Backends ---------------------------------------------------------------
echo "Setting up port-forwards..."
pf_start tempo    tempo      tempo                                          13200 3200
pf_start loki     loki       loki                                           3100  3100
pf_start langfuse langfuse   langfuse-web                                   3001  3000
pf_start prom     monitoring kube-prom-stack-kube-prome-prometheus          9090  9090

# Translate filter to per-backend syntax. Most backends normalize `.` → `_`
# in label/attr names; ClickHouse keeps the dot via Map-key access.
FK_DOT="$FILTER_KEY"            # e.g. gen_ai.agent.name
FK_UNDERSCORE="${FK_DOT//./_}"   # e.g. gen_ai_agent_name

START_NS=$((START_EPOCH * 1000000000))
END_NS=$((END_EPOCH * 1000000000))

# 1. Tempo — TraceQL search by resource attribute
echo "Querying Tempo..."
curl -sS -G "http://127.0.0.1:13200/api/search" \
  --data-urlencode "tags=${FK_DOT}=${FILTER_VALUE}" \
  --data-urlencode "limit=200" \
  --data-urlencode "start=$START_EPOCH" \
  --data-urlencode "end=$END_EPOCH" \
  > "$OUT_DIR/traces-tempo.json" || echo "  (Tempo query failed; file will be empty/error JSON)"

# 2. Langfuse — public API filtered by metadata.resourceAttributes.
# Use a temp file rather than curl→jq pipeline so we can handle each
# stage's failure independently (set -e + bash pipelines drop intermediate
# exit codes without `pipefail`, masking which step actually broke).
echo "Querying Langfuse..."
PUB=$(kubectl -n langfuse get secret langfuse-init -o jsonpath='{.data.LANGFUSE_INIT_PROJECT_PUBLIC_KEY}' 2>/dev/null | base64 -d || true)
SK=$(kubectl -n langfuse get secret langfuse-init -o jsonpath='{.data.LANGFUSE_INIT_PROJECT_SECRET_KEY}' 2>/dev/null | base64 -d || true)
if [ -n "$PUB" ] && [ -n "$SK" ]; then
  FROM_ISO=$(date -u -d "@$START_EPOCH" +%Y-%m-%dT%H:%M:%S.000Z)
  TO_ISO=$(date -u -d "@$END_EPOCH" +%Y-%m-%dT%H:%M:%S.000Z)
  AGGFILE="$OUT_DIR/.langfuse-pages.json"
  : > "$AGGFILE"
  # Langfuse caps `limit` at 100 per page (HTTP 200 + error body if exceeded).
  # Paginate via `?page=N` until a page returns empty `.data` or fewer than
  # 100 items (last page). Hard ceiling of 50 pages = 5000 traces; if a
  # real sweep exceeds that, the script logs a truncation warning rather
  # than spinning indefinitely. Per #39.
  PAGE_CAP=50
  PAGE=1
  TOTAL_FETCHED=0
  PAGINATION_TRUNCATED=0
  while [ "$PAGE" -le "$PAGE_CAP" ]; do
    PAGE_FILE="$OUT_DIR/.langfuse-page-$PAGE.json"
    if ! curl -sS -u "$PUB:$SK" "http://127.0.0.1:3001/api/public/traces?limit=100&page=$PAGE" \
           -o "$PAGE_FILE" 2>/dev/null; then
      echo "  (Langfuse page $PAGE curl failed; stopping pagination)"
      break
    fi
    PAGE_COUNT=$(jq -r '(.data // []) | length' "$PAGE_FILE" 2>/dev/null || echo 0)
    [[ "$PAGE_COUNT" =~ ^[0-9]+$ ]] || PAGE_COUNT=0
    if [ "$PAGE_COUNT" = "0" ]; then
      rm -f "$PAGE_FILE"
      break
    fi
    cat "$PAGE_FILE" >> "$AGGFILE"
    echo >> "$AGGFILE"  # newline separator (jq -s reads JSON sequence)
    TOTAL_FETCHED=$((TOTAL_FETCHED + PAGE_COUNT))
    if [ "$PAGE_COUNT" -lt 100 ]; then
      break  # last page (less than full)
    fi
    PAGE=$((PAGE + 1))
  done
  if [ "$PAGE" -gt "$PAGE_CAP" ]; then
    PAGINATION_TRUNCATED=1
  fi

  # Concatenate pages, apply client-side window + filter via jq -s
  # (slurp). `fromTimestamp`/`toTimestamp` URL params don't reliably honor
  # on chart 1.5.27 — verified during PR #38 development.
  if [ -s "$AGGFILE" ]; then
    if jq -s --arg from "$FROM_ISO" --arg to "$TO_ISO" \
          --arg key "$FK_DOT" --arg val "$FILTER_VALUE" \
          '[ .[] | (.data // [])[]
             | select(.timestamp >= $from and .timestamp <= $to)
             | select((.metadata.resourceAttributes[$key] // "") == $val)
           ]' \
        "$AGGFILE" > "$OUT_DIR/traces-langfuse.json" 2>/dev/null; then
      :
    else
      echo "  (Langfuse jq filter failed; raw pages saved as .langfuse-page-*.json)"
      echo '[]' > "$OUT_DIR/traces-langfuse.json"
    fi
  else
    echo '[]' > "$OUT_DIR/traces-langfuse.json"
  fi
  rm -f "$AGGFILE" "$OUT_DIR"/.langfuse-page-*.json 2>/dev/null || true
else
  echo '[]' > "$OUT_DIR/traces-langfuse.json"
  echo "  (Langfuse credentials not available — empty result)"
fi

# 3. Loki — query_range with stream selector on the underscore-form label
echo "Querying Loki..."
curl -sS -G "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode "query={${FK_UNDERSCORE}=\"${FILTER_VALUE}\"}" \
  --data-urlencode "start=$START_NS" \
  --data-urlencode "end=$END_NS" \
  --data-urlencode "limit=5000" \
  > "$OUT_DIR/logs-loki.json" || echo "  (Loki query failed)"

# 4. ClickHouse-logs — Map-key access in WHERE
echo "Querying ClickHouse-logs..."
PW=$(kubectl -n langfuse get secret langfuse-clickhouse -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
if [ -n "$PW" ]; then
  kubectl -n langfuse exec langfuse-clickhouse-shard0-0 -c clickhouse -- \
    clickhouse-client --password="$PW" -q "
      SELECT *
      FROM logs.otel_logs
      WHERE ResourceAttributes['$FK_DOT'] = '$FILTER_VALUE'
        AND Timestamp >= toDateTime64($START_EPOCH, 9)
        AND Timestamp <= toDateTime64($END_EPOCH, 9)
      ORDER BY Timestamp ASC
      LIMIT 5000
      FORMAT JSON
    " > "$OUT_DIR/logs-clickhouse.json" 2>/dev/null || echo "  (ClickHouse query failed)"
else
  echo '{"data":[]}' > "$OUT_DIR/logs-clickhouse.json"
fi

# 5. Prometheus — range query for claude_code_* metrics
echo "Querying Prometheus..."
curl -sS -G "http://127.0.0.1:9090/api/v1/query_range" \
  --data-urlencode "query={__name__=~\"claude_code_.*\",${FK_UNDERSCORE}=\"${FILTER_VALUE}\"}" \
  --data-urlencode "start=$START_EPOCH" \
  --data-urlencode "end=$END_EPOCH" \
  --data-urlencode "step=60s" \
  > "$OUT_DIR/metrics-prom.json" || echo "  (Prom query failed)"

# 6. Grafana drill-in URLs (live click-through; pre-filtered)
cat > "$OUT_DIR/grafana-urls.json" <<URLS
{
  "tempo": "$GRAFANA_BASE/explore?left=%7B%22datasource%22:%22tempo%22,%22queries%22:%5B%7B%22query%22:%22%7B%20resource.${FK_DOT}%20%3D%20%5C%22${FILTER_VALUE}%5C%22%20%7D%22%7D%5D%7D",
  "loki": "$GRAFANA_BASE/explore?left=%7B%22datasource%22:%22loki%22,%22queries%22:%5B%7B%22expr%22:%22%7B${FK_UNDERSCORE}%3D%5C%22${FILTER_VALUE}%5C%22%7D%22%7D%5D%7D",
  "prometheus": "$GRAFANA_BASE/explore?left=%7B%22datasource%22:%22prometheus%22,%22queries%22:%5B%7B%22expr%22:%22%7B${FK_UNDERSCORE}%3D%5C%22${FILTER_VALUE}%5C%22%7D%22%7D%5D%7D",
  "clickhouse_logs": "$GRAFANA_BASE/explore?left=%7B%22datasource%22:%22clickhouse-logs%22%7D",
  "langfuse_native_ui": "http://127.0.0.1:3001/project/macf-dev/traces"
}
URLS

# 7. Manifest. Each backend's hit-count derived from the file we just
# wrote, with a hard `// 0` fallback INSIDE the jq filter (the trailing
# `|| echo 0` only catches jq-process-failure, not jq-returned-null;
# without `// 0` inside the filter, an empty file or unexpected schema
# yields a blank stdout that breaks the manifest's JSON syntax).
safe_count() {
  local file=$1 path=$2
  local out
  out=$(jq -r "($path) // 0" "$file" 2>/dev/null || echo 0)
  # If jq emits empty / null / non-numeric, force 0
  [[ "$out" =~ ^[0-9]+$ ]] || out=0
  echo "$out"
}

TEMPO_HITS=$(safe_count "$OUT_DIR/traces-tempo.json"      '(.traces // []) | length')
LANGFUSE_HITS=$(safe_count "$OUT_DIR/traces-langfuse.json" 'length')
LOKI_STREAMS=$(safe_count "$OUT_DIR/logs-loki.json"        '(.data.result // []) | length')
CH_ROWS=$(safe_count "$OUT_DIR/logs-clickhouse.json"       '(.data // []) | length')
PROM_SERIES=$(safe_count "$OUT_DIR/metrics-prom.json"      '(.data.result // []) | length')

# Retention-window warnings (per #39). Backend retention values mirror the
# values committed in this workspace's chart values:
#   Loki:           7d   (values/loki.yaml: limits_config.retention_period)
#   ClickHouse-logs: 7d  (values/langfuse.yaml: clickhouse exporter ttl)
#   Prometheus:     7d   (values/kube-prometheus-stack.yaml: prometheusSpec.retention)
#   Tempo:        14d    (chart default; long; rarely a concern)
# When the snapshot's window age (now - end_epoch) exceeds a backend's
# retention, that backend's count in `summary` is ambiguous — could be
# "filter matched no data" OR "data dropped from retention before the
# snapshot ran." Surface this distinction explicitly via the manifest's
# warnings array so consumers know to interpret zero-counts cautiously.
NOW_EPOCH=$(date -u +%s)
WINDOW_AGE=$((NOW_EPOCH - END_EPOCH))
WARNINGS_JSON='[]'
WARNINGS_TMP=$(mktemp)
echo '[]' > "$WARNINGS_TMP"
add_warning() {
  jq --arg msg "$1" '. + [$msg]' "$WARNINGS_TMP" > "$WARNINGS_TMP.new" && mv "$WARNINGS_TMP.new" "$WARNINGS_TMP"
}

# Per-backend retention thresholds (seconds)
LOKI_RETENTION=$((7 * 86400))
CH_RETENTION=$((7 * 86400))
PROM_RETENTION=$((7 * 86400))
TEMPO_RETENTION=$((14 * 86400))

if [ "$WINDOW_AGE" -gt "$LOKI_RETENTION" ]; then
  add_warning "loki: window end is $((WINDOW_AGE / 86400))d old (>7d Loki retention); count of $LOKI_STREAMS may be partial — data likely aged out"
fi
if [ "$WINDOW_AGE" -gt "$CH_RETENTION" ]; then
  add_warning "clickhouse-logs: window end is $((WINDOW_AGE / 86400))d old (>7d ClickHouse logs.otel_logs TTL); count of $CH_ROWS may be partial"
fi
if [ "$WINDOW_AGE" -gt "$PROM_RETENTION" ]; then
  add_warning "prometheus: window end is $((WINDOW_AGE / 86400))d old (>7d Prometheus retention); count of $PROM_SERIES may be partial"
fi
if [ "$WINDOW_AGE" -gt "$TEMPO_RETENTION" ]; then
  add_warning "tempo: window end is $((WINDOW_AGE / 86400))d old (>14d Tempo default retention); count of $TEMPO_HITS may be partial"
fi

# Pagination truncation warning (Langfuse-specific)
if [ "${PAGINATION_TRUNCATED:-0}" = "1" ]; then
  add_warning "langfuse: pagination hit 50-page cap (5000 traces); count of $LANGFUSE_HITS may be partial — narrow filter or split window"
fi

WARNINGS_JSON=$(cat "$WARNINGS_TMP")
rm -f "$WARNINGS_TMP"

cat > "$OUT_DIR/manifest.json" <<MANIFEST
{
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": "$(hostname)",
  "mode": "$MODE",
  "filter": { "key": "$FK_DOT", "value": "$FILTER_VALUE" },
  "window": {
    "start_epoch": $START_EPOCH,
    "end_epoch": $END_EPOCH,
    "start_iso": "$(date -u -d "@$START_EPOCH" +%Y-%m-%dT%H:%M:%SZ)",
    "end_iso": "$(date -u -d "@$END_EPOCH" +%Y-%m-%dT%H:%M:%SZ)",
    "duration_seconds": $((END_EPOCH - START_EPOCH))
  },
  "github": $([ -n "$REPO" ] && echo "{\"repo\":\"$REPO\",\"issue\":$ISSUE}" || echo "null"),
  "summary": {
    "tempo_traces": $TEMPO_HITS,
    "langfuse_traces": $LANGFUSE_HITS,
    "loki_streams": $LOKI_STREAMS,
    "clickhouse_rows": $CH_ROWS,
    "prometheus_series": $PROM_SERIES
  },
  "warnings": $WARNINGS_JSON
}
MANIFEST

echo
echo "OK bundle written to $OUT_DIR"
echo "  manifest summary:"
jq '.summary' "$OUT_DIR/manifest.json"
