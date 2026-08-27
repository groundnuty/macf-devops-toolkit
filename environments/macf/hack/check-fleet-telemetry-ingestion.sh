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
# devops-toolkit#199: the roster is keyed on ROUTING_LABEL (registry var names,
# e.g. `devops-agent`), but macf#538 deliberately split that from the OTEL
# DISPLAY NAME (`gen_ai.agent.name`, e.g. `macf-devops-agent`) — they are NOT
# guaranteed to agree, and nothing constrains them to. Querying Tempo/Prometheus/
# Loki with a routing_label AS IF it were the display name is a silent-fallback
# hazard (Instance 8): a TraceQL/PromQL/LogQL selector matching nothing returns
# ZERO results, not an error — indistinguishable from a genuinely idle agent.
# The fix: resolve each routing_label against what's LIVE-OBSERVED emitting in
# Tempo before querying (see resolve_display_name() below) — never a static
# lookup table (macf#587's naming-inconsistency cleanup stays backlog; this
# script does not canonicalize anything, it only reports what it sees).
#
# VERDICT per agent per signal:
#   LANDING  — the routing_label IS the value observed emitting (or, for
#              metrics/logs, queried using the Tempo-resolved display name).
#   MISMATCH — (traces column only) routing_label itself is NOT observed, but a
#              same-core differently-spelled name (macf#538/#587 split) IS —
#              the agent is emitting fine, just not under its routing_label.
#              METRICS/LOGS legs are queried with the resolved name too, so a
#              MISMATCH'd agent should show LANDING there, not UNSEEN.
#   UNSEEN   — 0, and no related name observed either. NOT necessarily a
#              failure: an IDLE agent (no turns) emits nothing. UNSEEN =
#              idle-or-dropped; discriminate via activity (was the agent busy?)
#              + the aggregate drop-signature (check-tempo-ingestion.sh). The
#              genuinely-bad case is active-but-UNSEEN (export-succeeds-not-landing).
#   ERR      — the backend query (or, for TRACES, the name-resolution itself)
#              failed. Never silently downgraded to UNSEEN — an unresolved
#              mapping is reported loudly, not queried-anyway-and-shown-as-zero.
#
# ENDPOINTS — targets the HOST-EXPOSED monitoring-VM surfaces so it runs from ANY
# host on the tailnet (no cluster context needed):
#   - Tempo   : :3200 direct (native, post-DR-004; the quoted-dotted-attr TraceQL
#               form per Instance 8 — unquoted returns 0 SILENTLY — plus the
#               tag-values enumeration endpoint used for #199's name resolution,
#               which takes the BARE attribute name, no `resource.` scope prefix;
#               see resolve_display_name()/tempo_observed_names() below).
#   - Prom/Loki via the Grafana datasource PROXY (:3000, host-exposed, carries all
#               3 datasources). Needs the Grafana admin password (MACF_GRAFANA_PASSWORD
#               / --grafana-password); WITHOUT it those two legs SKIP (traces still run).
#
# Usage:
#   bash hack/check-fleet-telemetry-ingestion.sh                 # traces leg (no pw)
#   MACF_GRAFANA_PASSWORD=$(make grafana-password) bash hack/check-fleet-telemetry-ingestion.sh
#   WINDOW_MINUTES=60 ... --strict                               # exit 1 on any UNSEEN/MISMATCH
#
# Exit: 0 = every agent LANDING (or report-only); 1 = a UNSEEN/MISMATCH under
#       --strict OR a backend query/resolution ERROR; 2 = usage / no roster.

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

usage() { sed -n '2,64p' "$0" | sed 's/^# \{0,1\}//'; }
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

# --- routing_labels: the EXPECTED agents from the MACF registry (org-vars MACF_AGENT_*) ---
# Registry = actual/runtime state (who's registered). Falls back to the desired-agents
# manifest if the registry read fails (no GH_TOKEN / offline).
#
# NAMING (devops-toolkit#199): this returns ROUTING_LABEL values (the registry's
# key/cert-CN identity, e.g. `devops-agent`) — NOT `gen_ai.agent.name` (the OTEL
# display name, e.g. `macf-devops-agent`). macf#538 split those two fields on
# purpose; they are not interchangeable, and nothing constrains them to agree.
# A caller must resolve a routing_label to a display name (resolve_display_name(),
# below) before using it to query a backend keyed on gen_ai.agent.name — spending
# a routing_label AS a display name directly is precisely the bug this issue fixes.
routing_labels() {
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

ROUTING_LABELS="$(routing_labels)"
[ -n "$ROUTING_LABELS" ] || { echo "FATAL: no agent roster (registry read failed + no manifest at $MANIFEST)" >&2; exit 2; }

NOW="$(date -u +%s)"; START="$((NOW - WINDOW_MINUTES*60))"

# --- devops-toolkit#199: resolve routing_label -> observed gen_ai.agent.name ----
# Query WHAT IS ACTUALLY EMITTING in the window first, then compare the expected
# (routing_label) set against it — rather than querying Tempo/Prom/Loki with the
# routing_label directly and letting a mismatch render as an indistinguishable "0".
#
# Primary: Tempo's tag-values enumeration endpoint. Verified live 2026-08-27
# against this deployment's :3200 — it wants the BARE attribute name
# (`gen_ai.agent.name`), NOT the `resource.`-scoped, quoted form TraceQL search
# uses (that's a *different* endpoint solving a *different* problem). Passing
# `resource.gen_ai.agent.name` here 200s but ALWAYS returns `tagValues:[]`
# regardless of window/data — a second, distinct silent-empty gotcha from the
# Instance-8 TraceQL-quoting one (that one is about search-query syntax; this
# one is about the tag-enumeration path's tag-name syntax). start/end DO scope
# the result window correctly (verified: a 30m window returned 3 names, a 24h
# window returned 5 — monotonic widening, not a fixed all-time set).
tempo_observed_names() {
  local resp
  resp="$(curl -sS -m 12 -G "$TEMPO_URL/api/search/tag/gen_ai.agent.name/values" \
    --data-urlencode "start=$START" --data-urlencode "end=$NOW" 2>/dev/null)"
  [ -n "$resp" ] || return 1
  printf '%s' "$resp" | jq -e 'has("tagValues")' >/dev/null 2>&1 || return 1
  printf '%s' "$resp" | jq -r '.tagValues[]?' 2>/dev/null
}
# Fallback ONLY if the tag-values endpoint is unavailable / an unexpected shape on
# some other Tempo version: extract observed service names from a broad window
# search's serviceStats and strip the `macf-agent-` OTEL_SERVICE_NAME prefix back
# off to recover the gen_ai.agent.name value. Not needed against this deployment's
# Tempo (the primary path works — see report), kept as the documented fallback path.
tempo_observed_names_fallback() {
  local resp
  resp="$(curl -sS -m 15 -G "$TEMPO_URL/api/search" \
    --data-urlencode "q={}" --data-urlencode "start=$START" --data-urlencode "end=$NOW" \
    --data-urlencode "limit=200" 2>/dev/null)"
  [ -n "$resp" ] || return 1
  printf '%s' "$resp" | jq -e 'has("traces")' >/dev/null 2>&1 || return 1
  printf '%s' "$resp" | jq -r '[.traces[]?.serviceStats // {} | keys[]?] | unique[]?' 2>/dev/null \
    | sed -E 's/^macf-agent-//'
}

TEMPO_NAMES_SOURCE=""
TEMPO_NAMES_ERR=0
if OBSERVED_NAMES="$(tempo_observed_names)"; then
  TEMPO_NAMES_SOURCE="tag-values endpoint (/api/search/tag/gen_ai.agent.name/values)"
elif OBSERVED_NAMES="$(tempo_observed_names_fallback)"; then
  TEMPO_NAMES_SOURCE="broad-search fallback (serviceStats keys; tag-values endpoint unavailable)"
else
  OBSERVED_NAMES=""
  TEMPO_NAMES_SOURCE="ERROR — both tag-values endpoint and broad-search fallback failed"
  TEMPO_NAMES_ERR=1
fi

# Fuzzy "same identity, different spelling" core — heuristic ONLY, per macf#538's
# two known affix variants (a stray `macf-` prefix; a dropped `-agent` suffix).
# This is NOT a canonical mapping (macf#587 stays backlog) — it never rewrites a
# query silently, it only flags a likely mismatch for a human to see in the NOTE.
agent_core() {
  local s="$1"
  s="${s#macf-}"
  s="${s%-agent}"
  printf '%s' "$s"
}

# Resolve one routing_label against $OBSERVED_NAMES (the live window snapshot).
#   EXACT    <label>  — routing_label itself is in the observed set: query as-is.
#   MISMATCH <name>   — routing_label absent, but a same-core observed name IS
#                       present: use THAT name for the backend queries below.
#   NONE     <label>  — nothing observed under this identity or a related one:
#                       query as-is (matches pre-fix behaviour); verdict = UNSEEN.
resolve_display_name() {
  local label="$1" want_core name name_core
  if printf '%s\n' "$OBSERVED_NAMES" | grep -qx -- "$label"; then
    printf 'EXACT\t%s\n' "$label"
    return
  fi
  want_core="$(agent_core "$label")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    name_core="$(agent_core "$name")"
    if [ "$name_core" = "$want_core" ]; then
      printf 'MISMATCH\t%s\n' "$name"
      return
    fi
  done <<< "$OBSERVED_NAMES"
  printf 'NONE\t%s\n' "$label"
}

# --- backend query legs (each returns a non-negative count; "ERR" on failure) ----
# Grafana datasource proxy: find a datasource UID by type, then query through it.
graf_ds_uid() {  # $1=type (prometheus|loki)
  curl -sS -m 10 -u "$GRAFANA_USER:$GRAFANA_PASSWORD" "$GRAFANA_URL/api/datasources" 2>/dev/null \
    | jq -r --arg t "$1" '[.[] | select(.type==$t)] | .[0].uid // empty' 2>/dev/null
}
# Prometheus (via proxy): count series carrying this agent's resource attr
# (collector prometheus-exporter maps gen_ai.agent.name -> gen_ai_agent_name).
# Takes the RESOLVED display_name (see resolve_display_name()), NOT the
# routing_label — querying with the routing_label directly is devops-toolkit#199.
prom_count() {
  local display_name="$1" uid resp
  uid="$(graf_ds_uid prometheus)"; [ -n "$uid" ] || { echo "ERR"; return; }
  resp="$(curl -sS -m 12 -u "$GRAFANA_USER:$GRAFANA_PASSWORD" -G \
    "$GRAFANA_URL/api/datasources/proxy/uid/$uid/api/v1/query" \
    --data-urlencode "query=count({gen_ai_agent_name=\"$display_name\"})" 2>/dev/null)" || { echo "ERR"; return; }
  printf '%s' "$resp" | jq -r '.data.result | length' 2>/dev/null || echo "ERR"
}
# Loki (via proxy): count streams (Instance 4 — Loki indexes service_name, NOT
# arbitrary resource attrs; the agent's service.name is macf-agent-<display_name>).
# Takes the RESOLVED display_name — same rationale as prom_count() above.
loki_count() {
  local display_name="$1" uid resp
  uid="$(graf_ds_uid loki)"; [ -n "$uid" ] || { echo "ERR"; return; }
  resp="$(curl -sS -m 12 -u "$GRAFANA_USER:$GRAFANA_PASSWORD" -G \
    "$GRAFANA_URL/api/datasources/proxy/uid/$uid/loki/api/v1/query_range" \
    --data-urlencode "query={service_name=\"macf-agent-$display_name\"}" \
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
echo "  Tempo agent-name resolution source: $TEMPO_NAMES_SOURCE"
printf '%-16s %-9s %-9s %-9s %s\n' "AGENT" "TRACES" "METRICS" "LOGS" "NOTE"
printf '%-16s %-9s %-9s %-9s %s\n' "-----" "------" "-------" "----" "----"
any_unseen=0 any_err=0 any_mismatch=0
while read -r routing_label; do
  [ -n "$routing_label" ] || continue

  if [ "$TEMPO_NAMES_ERR" = 1 ]; then
    kind="ERR"; display_name="$routing_label"
  else
    IFS=$'\t' read -r kind display_name <<< "$(resolve_display_name "$routing_label")"
  fi

  if [ "$GRAF_ON" = 1 ]; then mc="$(prom_count "$display_name")"; lc="$(loki_count "$display_name")"; else mc="-"; lc="-"; fi
  mv="$(verdict "$mc")"; lv="$(verdict "$lc")"

  case "$kind" in
    EXACT)
      tv="LANDING"; note="landing OK" ;;
    MISMATCH)
      tv="MISMATCH"
      note="NAME-MISMATCH: routing_label '$routing_label' absent, but '$display_name' IS emitting in-window — macf#538/#587 split, not a telemetry gap (METRICS/LOGS queried using '$display_name')"
      any_mismatch=1 ;;
    NONE)
      tv="UNSEEN"
      note="0 traces for '$routing_label' (no similarly-named agent observed either) — idle-or-dropped (cross-check activity + check-tempo-ingestion.sh)"
      any_unseen=1 ;;
    ERR)
      tv="ERR"
      note="Tempo agent-name resolution failed: $TEMPO_NAMES_SOURCE"
      any_err=1 ;;
  esac
  { [ "$mv" = ERR ] || [ "$lv" = ERR ]; } && any_err=1

  printf '%-16s %-9s %-9s %-9s %s\n' "$routing_label" "$tv" "$mv" "$lv" "$note"
done <<< "$ROUTING_LABELS"

echo
[ "$GRAF_ON" = 1 ] || echo "NOTE: metrics/logs legs SKIPPED — re-run with MACF_GRAFANA_PASSWORD=\$(make grafana-password) on a host that can reach $GRAFANA_URL for the full 3-signal verdict."
echo "UNSEEN ≠ failure: an idle agent (no recent turns) emits nothing. The bad case is ACTIVE-but-UNSEEN (export-succeeds-not-landing, Instance 8) — discriminate via agent activity + the aggregate check-tempo-ingestion.sh drop-signature."
echo "MISMATCH ≠ telemetry gap (devops-toolkit#199): the TRACES column resolves routing_label -> gen_ai.agent.name from LIVE Tempo data only (never a static table — macf#587 stays backlog). A MISMATCH row means the agent IS emitting, just under a different display name than its routing_label."

if [ "$any_err" = 1 ]; then echo "→ a backend query or name-resolution ERRORED (see rows)."; exit 1; fi
if [ "$STRICT" = 1 ] && { [ "$any_unseen" = 1 ] || [ "$any_mismatch" = 1 ]; }; then echo "→ --strict: at least one agent UNSEEN or MISMATCH."; exit 1; fi
exit 0
