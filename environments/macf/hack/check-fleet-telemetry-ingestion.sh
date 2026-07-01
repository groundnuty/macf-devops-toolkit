#!/usr/bin/env bash
# check-fleet-telemetry-ingestion.sh — the BACKEND-owner's-eye, PER-AGENT
# telemetry-landing diagnostic (devops-toolkit#114).
#
# `macf fleet doctor` is topology-agnostic → it can only assert EXPORT-success
# (each agent self-reports "my OTLP exporter POSTs 200"). It structurally CANNOT
# answer "is the telemetry actually LANDING / queryable in the backend?" — that
# needs the backend owner to query the stack (silent-fallback Instance 8: the
# export-vs-ingest split). For THIS deployment we own the stack, so we can.
#
# This fleet-izes the two aggregate/per-process Pattern-A scripts into ONE
# per-agent, roster-driven landing check:
#   - check-tempo-ingestion.sh → aggregate ingestion-vs-search (no per-agent)
#   - doctor-otel.sh           → per-PROCESS, traces-only, local /proc
# Here: for each agent in the REGISTRY roster, is ITS telemetry queryable in the
# backend over a recent window — traces (Tempo) + metrics (Prometheus) + logs (Loki)?
#
# VERDICT per agent per signal:
#   LANDING  — ≥1 queryable trace/series/stream in the window (backend has it).
#   UNSEEN   — 0. NOT necessarily a failure: an IDLE agent (no turns) emits nothing.
#              UNSEEN = idle-or-dropped; discriminate via activity (was the agent busy?)
#              + the aggregate drop-signature (check-tempo-ingestion.sh). The
#              genuinely-bad case is active-but-UNSEEN (export-succeeds-not-landing).
#
# ENDPOINTS — targets the HOST-EXPOSED monitoring-VM surfaces so it runs from ANY
# host on the tailnet (no cluster context needed):
#   - Tempo   : :3200 direct (native, post-DR-004; the quoted-dotted-attr TraceQL
#               form per Instance 8 — unquoted returns 0 SILENTLY).
#   - Prom/Loki via the Grafana datasource PROXY (:3000, host-exposed, carries all
#               3 datasources). Needs the Grafana admin password (MACF_GRAFANA_PASSWORD
#               / --grafana-password); WITHOUT it those two legs SKIP (traces still run).
#
# Usage:
#   bash hack/check-fleet-telemetry-ingestion.sh                 # traces leg (no pw)
#   MACF_GRAFANA_PASSWORD=$(make grafana-password) bash hack/check-fleet-telemetry-ingestion.sh
#   WINDOW_MINUTES=60 ... --strict                               # exit 1 on any UNSEEN
#
# Exit: 0 = every agent LANDING (or report-only); 1 = a UNSEEN under --strict OR a
#       backend query ERROR; 2 = usage / no roster.

set -uo pipefail

WINDOW_MINUTES="${WINDOW_MINUTES:-30}"
MON_HOST="${MACF_MON_HOST:-orzech-dev-agents-monitoring.tail491af.ts.net}"
TEMPO_URL="${MACF_TEMPO_URL:-http://$MON_HOST:3200}"
GRAFANA_URL="${MACF_GRAFANA_URL:-http://$MON_HOST:3000}"
GRAFANA_USER="${MACF_GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${MACF_GRAFANA_PASSWORD:-}"
REGISTRY_OWNER="${MACF_REGISTRY_OWNER:-groundnuty/groundnuty}"
MANIFEST="${MACF_DESIRED_AGENTS:-$HOME/.macf/desired-agents.yaml}"
STRICT=0

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --grafana-password) GRAFANA_PASSWORD="$2"; shift 2 ;;
    --window)           WINDOW_MINUTES="$2"; shift 2 ;;
    --strict)           STRICT=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null   || { echo "FATAL: jq not found" >&2; exit 2; }
command -v curl >/dev/null  || { echo "FATAL: curl not found" >&2; exit 2; }

# --- roster: the EXPECTED agents from the MACF registry (org-vars MACF_AGENT_*) ---
# Registry = actual/runtime state (who's registered). Falls back to the desired-agents
# manifest if the registry read fails (no GH_TOKEN / offline).
roster() {
  if [ -n "${GH_TOKEN:-}" ]; then
    local vars
    vars="$(GH_TOKEN=$GH_TOKEN gh api "/repos/$REGISTRY_OWNER/actions/variables" --paginate \
      --jq '.variables[]? | select(.name|startswith("MACF_AGENT_")) | .name' 2>/dev/null || true)"
    if [ -n "$vars" ]; then
      # MACF_AGENT_DEVOPS_AGENT -> devops-agent
      printf '%s\n' "$vars" | sed 's/^MACF_AGENT_//' | tr 'A-Z_' 'a-z-'
      return
    fi
  fi
  # fallback: manifest
  [ -f "$MANIFEST" ] && awk '/^[[:space:]]*-[[:space:]]*agent:/ { sub(/^[^:]*:[[:space:]]*/,""); gsub(/[[:space:]"'\'']/,""); print }' "$MANIFEST"
}

AGENTS="$(roster)"
[ -n "$AGENTS" ] || { echo "FATAL: no agent roster (registry read failed + no manifest at $MANIFEST)" >&2; exit 2; }

NOW="$(date -u +%s)"; START="$((NOW - WINDOW_MINUTES*60))"

# --- backend query legs (each returns a non-negative count; "ERR" on failure) ----
# Tempo: quoted dotted-attr (Instance 8 — unquoted = 0 SILENTLY).
tempo_count() {
  local agent="$1" q resp
  q="{resource.\"gen_ai.agent.name\"=\"$agent\"}"
  resp="$(curl -sS -m 12 -G "$TEMPO_URL/api/search" \
    --data-urlencode "q=$q" --data-urlencode "start=$START" --data-urlencode "end=$NOW" \
    --data-urlencode "limit=5" 2>/dev/null)" || { echo "ERR"; return; }
  printf '%s' "$resp" | jq -r '.traces | length' 2>/dev/null || echo "ERR"
}

# Grafana datasource proxy: find a datasource UID by type, then query through it.
graf_ds_uid() {  # $1=type (prometheus|loki)
  curl -sS -m 10 -u "$GRAFANA_USER:$GRAFANA_PASSWORD" "$GRAFANA_URL/api/datasources" 2>/dev/null \
    | jq -r --arg t "$1" '[.[] | select(.type==$t)] | .[0].uid // empty' 2>/dev/null
}
# Prometheus (via proxy): count series carrying this agent's resource attr
# (collector prometheus-exporter maps gen_ai.agent.name -> gen_ai_agent_name).
prom_count() {
  local agent="$1" uid resp
  uid="$(graf_ds_uid prometheus)"; [ -n "$uid" ] || { echo "ERR"; return; }
  resp="$(curl -sS -m 12 -u "$GRAFANA_USER:$GRAFANA_PASSWORD" -G \
    "$GRAFANA_URL/api/datasources/proxy/uid/$uid/api/v1/query" \
    --data-urlencode "query=count({gen_ai_agent_name=\"$agent\"})" 2>/dev/null)" || { echo "ERR"; return; }
  printf '%s' "$resp" | jq -r '.data.result | length' 2>/dev/null || echo "ERR"
}
# Loki (via proxy): count streams (Instance 4 — Loki indexes service_name, NOT
# arbitrary resource attrs; the agent's service.name is macf-agent-<agent>).
loki_count() {
  local agent="$1" uid resp
  uid="$(graf_ds_uid loki)"; [ -n "$uid" ] || { echo "ERR"; return; }
  resp="$(curl -sS -m 12 -u "$GRAFANA_USER:$GRAFANA_PASSWORD" -G \
    "$GRAFANA_URL/api/datasources/proxy/uid/$uid/loki/api/v1/query_range" \
    --data-urlencode "query={service_name=\"macf-agent-$agent\"}" \
    --data-urlencode "start=${START}000000000" --data-urlencode "end=${NOW}000000000" \
    --data-urlencode "limit=1" 2>/dev/null)" || { echo "ERR"; return; }
  printf '%s' "$resp" | jq -r '.data.result | length' 2>/dev/null || echo "ERR"
}

verdict() { # $1=count -> LANDING / UNSEEN / ERR / -
  case "$1" in ERR) echo "ERR";; -) echo "  -  ";; 0) echo "UNSEEN";; *) echo "LANDING";; esac
}

# --- run -----------------------------------------------------------------------
GRAF_ON=0; [ -n "$GRAFANA_PASSWORD" ] && GRAF_ON=1
echo "Fleet telemetry-ingestion check — backend-owner's-eye, per-agent  [window ${WINDOW_MINUTES}m]"
echo "  Tempo: $TEMPO_URL   Grafana-proxy(Prom/Loki): $([ "$GRAF_ON" = 1 ] && echo "$GRAFANA_URL" || echo 'SKIPPED (no --grafana-password / MACF_GRAFANA_PASSWORD)')"
printf '%-16s %-9s %-9s %-9s %s\n' "AGENT" "TRACES" "METRICS" "LOGS" "NOTE"
printf '%-16s %-9s %-9s %-9s %s\n' "-----" "------" "-------" "----" "----"
any_unseen=0 any_err=0
while read -r agent; do
  [ -n "$agent" ] || continue
  tc="$(tempo_count "$agent")"
  if [ "$GRAF_ON" = 1 ]; then mc="$(prom_count "$agent")"; lc="$(loki_count "$agent")"; else mc="-"; lc="-"; fi
  tv="$(verdict "$tc")"; mv="$(verdict "$mc")"; lv="$(verdict "$lc")"
  note=""
  case "$tv" in
    LANDING) note="landing OK" ;;
    UNSEEN)  note="0 traces — idle-or-dropped (cross-check activity + check-tempo-ingestion.sh)"; any_unseen=1 ;;
    ERR)     note="Tempo query ERROR (endpoint reachable?)"; any_err=1 ;;
  esac
  [ "$mv" = ERR ] || [ "$lv" = ERR ] && any_err=1
  printf '%-16s %-9s %-9s %-9s %s\n' "$agent" "$tv" "$mv" "$lv" "$note"
done <<< "$AGENTS"

echo
[ "$GRAF_ON" = 1 ] || echo "NOTE: metrics/logs legs SKIPPED — re-run with MACF_GRAFANA_PASSWORD=\$(make grafana-password) on a host that can reach $GRAFANA_URL for the full 3-signal verdict."
echo "UNSEEN ≠ failure: an idle agent (no recent turns) emits nothing. The bad case is ACTIVE-but-UNSEEN (export-succeeds-not-landing, Instance 8) — discriminate via agent activity + the aggregate check-tempo-ingestion.sh drop-signature."

if [ "$any_err" = 1 ]; then echo "→ a backend query ERRORED (see rows)."; exit 1; fi
if [ "$STRICT" = 1 ] && [ "$any_unseen" = 1 ]; then echo "→ --strict: at least one agent UNSEEN."; exit 1; fi
exit 0
