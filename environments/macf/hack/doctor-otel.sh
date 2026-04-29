#!/usr/bin/env bash
# Pattern A defense at the agent-process level (per silent-fallback-hazards.md
# Instance 8 Tier 4 — devops#62, 2026-04-29).
#
# Background: a long-lived claude process whose bundled OTel exporter
# experienced sustained connect-refused (e.g., during the
# pre-devops#60-PR#61 window when :4318 had no listener) can enter a
# state where it stops re-attempting connection — even after the
# downstream issue resolves. The process keeps running normally, claude
# keeps doing work, but no traces / metrics / logs reach the cluster.
#
# `check-tempo-ingestion.sh` (sister script) detects the cluster-side
# ingestion-vs-search invariant. `doctor-otel.sh` (this script) detects
# the agent-side process-vs-traces invariant — for each running claude
# process with `OTEL_TRACES_EXPORTER=otlp` set, asks Tempo whether
# spans for its `OTEL_SERVICE_NAME` have arrived over the recent window.
# Reports on stuck processes (OTel-configured but Tempo-silent) — the
# canonical Tier 4 firing condition.
#
# Usage:
#   bash hack/doctor-otel.sh                # default 30-min window
#   WINDOW_MINUTES=10 bash hack/doctor-otel.sh
#
# Exit codes:
#   0 — no agents detected, or all OTel-configured agents have traces
#   1 — at least one agent is OTel-configured but Tempo-silent (stuck)
#   2 — Tempo unreachable / port-forward failed
#
# Operator remediation when stuck agents found:
#   tmux send-keys -t <session> '/exit' Enter   # graceful
#   tmux kill-session -t <session>              # forceful
#   ./claude.sh                                 # relaunch with fresh OTel state

set -euo pipefail

WINDOW_MINUTES="${WINDOW_MINUTES:-30}"
TEMPO_NS="${TEMPO_NS:-tempo}"
TEMPO_SVC="${TEMPO_SVC:-tempo}"
TEMPO_PORT="${TEMPO_PORT:-13200}"

# Auto-start tempo port-forward if not already listening
if ! ss -tlnp 2>/dev/null | grep -q ":${TEMPO_PORT} "; then
  kubectl -n "$TEMPO_NS" port-forward "svc/$TEMPO_SVC" "${TEMPO_PORT}:3200" >/tmp/pf-doctor-tempo.log 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null || true' EXIT
  sleep 3
fi

# Sanity-check Tempo reachable
if ! curl -sS -m 5 "http://127.0.0.1:${TEMPO_PORT}/status/services" >/dev/null 2>&1; then
  echo "::error::Tempo unreachable at 127.0.0.1:${TEMPO_PORT} — port-forward setup failed?"
  exit 2
fi

START_EPOCH=$(date -u -d "${WINDOW_MINUTES} minutes ago" +%s)
END_EPOCH=$(date -u +%s)

echo "doctor-otel: checking agent OTel emission over last ${WINDOW_MINUTES}min"
echo "  window: $START_EPOCH → $END_EPOCH"
echo ""

# Find every running claude process owned by current user
CLAUDE_PIDS=$(pgrep -f -u "$USER" '^claude($| )' 2>/dev/null || true)
if [ -z "$CLAUDE_PIDS" ]; then
  echo "::notice::No running claude processes found for user $USER — nothing to check."
  exit 0
fi

stuck_count=0
healthy_count=0
unconfigured_count=0
report=()

for pid in $CLAUDE_PIDS; do
  # Read environ; skip if unreadable. /proc/$pid/environ has perms 600 +
  # owner-uid; even when pgrep -u $USER returns the PID, some processes
  # (e.g., docker-group-wrapped via `sg docker -c`) end up with effective
  # uid that differs from owner. Use cat with stderr redirect (shell-level
  # `<` redirect leaks the "Permission denied" to script stderr — cat's
  # stderr stays inside the subshell where 2>/dev/null catches it).
  envs=$(cat "/proc/$pid/environ" 2>/dev/null | tr '\0' '\n') || continue
  [ -z "$envs" ] && continue

  # Extract relevant OTel envs
  traces_exporter=$(echo "$envs" | awk -F= '/^OTEL_TRACES_EXPORTER=/{print $2}')
  service_name=$(echo "$envs" | awk -F= '/^OTEL_SERVICE_NAME=/{print $2}')
  endpoint=$(echo "$envs" | awk -F= '/^OTEL_EXPORTER_OTLP_ENDPOINT=/{print $2}')

  # If OTel is not configured for traces, skip — not in scope for this check
  if [ "$traces_exporter" != "otlp" ] || [ -z "$service_name" ]; then
    unconfigured_count=$((unconfigured_count + 1))
    continue
  fi

  # Query Tempo for any traces from this service in the window
  # Use --data-urlencode for the service-name tag value (handles special chars)
  trace_count=$(curl -sS -G "http://127.0.0.1:${TEMPO_PORT}/api/search" \
    --data-urlencode "tags=service.name=${service_name}" \
    --data-urlencode "limit=1" \
    --data-urlencode "start=$START_EPOCH" \
    --data-urlencode "end=$END_EPOCH" 2>/dev/null \
    | jq -r '.traces | length' 2>/dev/null || echo "0")

  if [ "$trace_count" -gt 0 ]; then
    healthy_count=$((healthy_count + 1))
    report+=("✓ ${service_name} (PID $pid) — traces flowing")
  else
    stuck_count=$((stuck_count + 1))
    started=$(awk '{print $22}' /proc/$pid/stat 2>/dev/null)
    report+=("✗ ${service_name} (PID $pid, endpoint=${endpoint:-unset}) — STUCK: 0 traces in window")
  fi
done

# Print report
echo "Agents OTel-configured + healthy:    $healthy_count"
echo "Agents OTel-configured + STUCK:      $stuck_count"
echo "Agents not configured for traces:    $unconfigured_count"
echo ""
for line in "${report[@]}"; do
  echo "  $line"
done
echo ""

if [ "$stuck_count" -gt 0 ]; then
  echo "::error::Tier 4 firing — $stuck_count agent(s) configured for OTLP traces but emitting nothing."
  echo "::error::Cached exporter state from a previous connect-refused window is the typical cause."
  echo "::error::Remediation: relaunch the agent's claude process to reset OTel SDK state."
  echo "::error::See silent-fallback-hazards.md Instance 8 + devops#62 for the diagnosis pattern."
  exit 1
fi

if [ "$healthy_count" -eq 0 ] && [ "$unconfigured_count" -gt 0 ]; then
  echo "::notice::No OTel-configured agents detected — Tier 4 invariant vacuously holds."
  echo "  ($unconfigured_count agent(s) running without OTEL_TRACES_EXPORTER=otlp.)"
fi

exit 0
