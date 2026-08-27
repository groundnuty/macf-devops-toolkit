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
#
# The fix, in two steps per agent:
#   1. Ask Tempo directly whether the routing_label itself is landing — the
#      existing quoted-dotted-attr TraceQL search (tempo_count(), Instance 8:
#      unquoted returns 0 SILENTLY). This is the source of truth for "is this
#      landing"; a real search beats trusting an enumeration endpoint's
#      membership list (which can silently truncate — see tempo_observed_names()).
#   2. Only if that comes back empty: enumerate what IS emitting in the window
#      (tempo_observed_names()) and look for a same-core, differently-spelled
#      candidate (macf#538/#587's known affix variants) — then CONFIRM the
#      candidate with its own tempo_count() search before reporting MISMATCH.
#      Never trust tag-values membership alone as the final answer; it's a
#      candidate generator, not the verdict.
# Never a static routing_label -> display_name lookup table (macf#587's
# naming-inconsistency cleanup stays backlog; this script does not canonicalize
# anything, it only reports what it live-observes).
#
# VERDICT per agent per signal:
#   LANDING  — the routing_label IS landing (direct search, step 1).
#   MISMATCH — (traces column only) routing_label itself is NOT landing, but a
#              same-core differently-spelled name IS, confirmed by its own
#              direct search (step 2). The agent is emitting fine, just not
#              under its routing_label. METRICS/LOGS legs are queried with the
#              resolved name too, so a MISMATCH'd agent should show LANDING
#              there, not UNSEEN. NOTE — this is a WINDOW-scoped read: a wider
#              --window may show LANDING instead, if the agent used its
#              routing_label as its own display name at some earlier point
#              inside that wider window (see report — this recurs in practice).
#   UNSEEN   — routing_label isn't landing, and no confirmed candidate exists
#              either. NOT necessarily a failure: an IDLE agent (no turns)
#              emits nothing. UNSEEN = idle-or-dropped; discriminate via
#              activity (was the agent busy?) + the aggregate drop-signature
#              (check-tempo-ingestion.sh). The genuinely-bad case is
#              active-but-UNSEEN (export-succeeds-not-landing).
#   ERR      — a backend query failed, OR (traces column) step 1 came back
#              empty and step 2's enumeration itself is unavailable, so a
#              name-mismatch can't be ruled out. Never silently downgraded to
#              UNSEEN — an unresolved mapping is reported loudly, not
#              queried-anyway-and-shown-as-zero.
#
# ENDPOINTS — targets the HOST-EXPOSED monitoring-VM surfaces so it runs from ANY
# host on the tailnet (no cluster context needed):
#   - Tempo   : :3200 direct (native, post-DR-004). Two distinct query paths:
#               (a) /api/search with the quoted resource."gen_ai.agent.name"
#                   TraceQL form (Instance 8: unquoted returns 0 SILENTLY) —
#                   used for the actual per-name presence check (tempo_count()).
#               (b) /api/search/tag/gen_ai.agent.name/values — the tag-values
#                   enumeration endpoint used ONLY to generate a mismatch
#                   candidate (tempo_observed_names()). This one wants the BARE
#                   attribute name, NOT the `resource.`-scoped form (a):
#                   passing `resource.gen_ai.agent.name` here 200s but ALWAYS
#                   returns tagValues:[] regardless of window/data — verified
#                   live 2026-08-27 against this deployment's :3200, a second,
#                   distinct silent-empty gotcha from (a)'s quoting one. Also
#                   verified: it's subject to Tempo's max_bytes_per_tag_values_
#                   query cap (default 5MB) and this fleet was already at
#                   ~1.6-2MB with 4 agents, so its result list can silently
#                   truncate as the fleet grows — hence step 1 above always
#                   being the actual verdict, never the enumeration alone.
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

usage() { sed -n '2,94p' "$0" | sed 's/^# \{0,1\}//'; }
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

# --- Tempo: is this NAME (whatever it is — routing_label or a candidate display
# name) actually landing in the window? Quoted dotted-attr (Instance 8 — unquoted
# = 0 SILENTLY). This is the SOURCE OF TRUTH for presence; the tag-values
# enumeration below is only ever used to generate a candidate for this to confirm.
tempo_count() {
  local name="$1" q resp
  q="{resource.\"gen_ai.agent.name\"=\"$name\"}"
  resp="$(curl -sS -m 12 -G "$TEMPO_URL/api/search" \
    --data-urlencode "q=$q" --data-urlencode "start=$START" --data-urlencode "end=$NOW" \
    --data-urlencode "limit=5" 2>/dev/null)" || { echo "ERR"; return; }
  printf '%s' "$resp" | jq -r '.traces | length' 2>/dev/null || echo "ERR"
}

# --- devops-toolkit#199: enumerate observed gen_ai.agent.name values in the
# window, for MISMATCH-candidate generation ONLY (never the verdict itself —
# see the header's ENDPOINTS section for the truncation-risk rationale, AND
# the block-granularity gotcha below — this is why every candidate this
# produces still gets its own tempo_count() confirmation before being reported).
# Primary: Tempo's tag-values enumeration endpoint. Verified live 2026-08-27
# against this deployment's :3200 — it wants the BARE attribute name
# (`gen_ai.agent.name`), NOT the `resource.`-scoped, quoted form tempo_count()
# above uses (a *different* endpoint solving a *different* problem). start/end
# DO narrow the result set with window size (a 30m window returned 3 names, a
# 24h window returned 5), but NOT at exact-span-timestamp precision — verified
# live: over a 24h window this endpoint listed `science-agent` as observed,
# while tempo_count("science-agent") over that SAME window found zero matching
# traces. Read: it appears to select by which underlying storage BLOCKS overlap
# [start,end] and then return every tag value anywhere in those blocks, not just
# values whose own span timestamp falls inside the window — so it can name a
# candidate that isn't actually landing in-window. Harmless here because it's
# only ever a candidate for tempo_count() to confirm or reject, never trusted
# on its own; document it so a future edit doesn't "simplify" that away.
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
# query silently, it only generates a CANDIDATE that still has to pass its own
# tempo_count() search before being reported as a mismatch.
agent_core() {
  local s="$1"
  s="${s#macf-}"
  s="${s%-agent}"
  printf '%s' "$s"
}

# Resolve one routing_label to a verdict-kind + the name actually used for the
# METRICS/LOGS queries below. Two-step, per the header:
#   1. Direct search on the routing_label itself (tempo_count()) — the source
#      of truth. >0 -> EXACT (LANDING).
#   2. Only if that's empty: look for a same-core candidate in the observed-names
#      enumeration, and CONFIRM it with its own direct search before returning
#      MISMATCH. If the enumeration itself is unavailable, we cannot rule a
#      mismatch out — return ERR rather than silently guessing UNSEEN (the
#      literal AC this issue asks for: "an absent mapping fails loudly").
# Output: "<KIND>\t<name-to-query-with>\t<err-reason-or->"
resolve_display_name() {
  local label="$1" tc want_core name name_core
  tc="$(tempo_count "$label")"
  if [ "$tc" = "ERR" ]; then
    printf 'ERR\t%s\t%s\n' "$label" "Tempo search for routing_label '$label' failed (endpoint reachable?)"
    return
  fi
  if [ "$tc" != 0 ]; then
    printf 'EXACT\t%s\t-\n' "$label"
    return
  fi
  if [ "$TEMPO_NAMES_ERR" = 1 ]; then
    printf 'ERR\t%s\t%s\n' "$label" "cannot rule out a name-mismatch — tag-values enumeration unavailable ($TEMPO_NAMES_SOURCE)"
    return
  fi
  want_core="$(agent_core "$label")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "$label" ] && continue
    name_core="$(agent_core "$name")"
    if [ "$name_core" = "$want_core" ]; then
      tc="$(tempo_count "$name")"
      if [ "$tc" != "ERR" ] && [ "$tc" != 0 ]; then
        printf 'MISMATCH\t%s\t-\n' "$name"
        return
      fi
    fi
  done <<< "$OBSERVED_NAMES"
  printf 'NONE\t%s\t-\n' "$label"
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
echo "  Tempo mismatch-candidate enumeration source: $TEMPO_NAMES_SOURCE"
printf '%-16s %-9s %-9s %-9s %s\n' "AGENT" "TRACES" "METRICS" "LOGS" "NOTE"
printf '%-16s %-9s %-9s %-9s %s\n' "-----" "------" "-------" "----" "----"
any_unseen=0 any_err=0 any_mismatch=0
while read -r routing_label; do
  [ -n "$routing_label" ] || continue

  IFS=$'\t' read -r kind display_name err_reason <<< "$(resolve_display_name "$routing_label")"

  if [ "$GRAF_ON" = 1 ]; then mc="$(prom_count "$display_name")"; lc="$(loki_count "$display_name")"; else mc="-"; lc="-"; fi
  mv="$(verdict "$mc")"; lv="$(verdict "$lc")"

  case "$kind" in
    EXACT)
      tv="LANDING"; note="landing OK" ;;
    MISMATCH)
      tv="MISMATCH"
      note="NAME-MISMATCH: routing_label '$routing_label' not landing, but '$display_name' IS (confirmed) in-window — macf#538/#587 split, not a telemetry gap (METRICS/LOGS queried using '$display_name'; widen --window and this may read LANDING instead if '$routing_label' also emitted earlier in the wider window)"
      any_mismatch=1 ;;
    NONE)
      tv="UNSEEN"
      note="0 traces for '$routing_label' (no confirmed same-core candidate either) — idle-or-dropped (cross-check activity + check-tempo-ingestion.sh)"
      any_unseen=1 ;;
    ERR)
      tv="ERR"
      note="$err_reason"
      any_err=1 ;;
  esac
  { [ "$mv" = ERR ] || [ "$lv" = ERR ]; } && any_err=1

  printf '%-16s %-9s %-9s %-9s %s\n' "$routing_label" "$tv" "$mv" "$lv" "$note"
done <<< "$ROUTING_LABELS"

echo
[ "$GRAF_ON" = 1 ] || echo "NOTE: metrics/logs legs SKIPPED — re-run with MACF_GRAFANA_PASSWORD=\$(make grafana-password) on a host that can reach $GRAFANA_URL for the full 3-signal verdict."
echo "UNSEEN ≠ failure: an idle agent (no recent turns) emits nothing. The bad case is ACTIVE-but-UNSEEN (export-succeeds-not-landing, Instance 8) — discriminate via agent activity + the aggregate check-tempo-ingestion.sh drop-signature."
echo "MISMATCH ≠ telemetry gap (devops-toolkit#199): the TRACES column resolves routing_label -> gen_ai.agent.name from LIVE Tempo searches only (never a static table — macf#587 stays backlog). A MISMATCH row means the agent IS emitting, just under a different display name than its routing_label — and is WINDOW-scoped (see the MISMATCH row's own NOTE)."

if [ "$any_err" = 1 ]; then echo "→ a backend query or name-resolution ERRORED (see rows)."; exit 1; fi
if [ "$STRICT" = 1 ] && { [ "$any_unseen" = 1 ] || [ "$any_mismatch" = 1 ]; }; then echo "→ --strict: at least one agent UNSEEN or MISMATCH."; exit 1; fi
exit 0
