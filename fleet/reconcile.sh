#!/usr/bin/env bash
#
# reconcile.sh — the VM cron-watchdog DESIRED-STATE RECONCILER (DR-006).
#
# Drives actual fleet state → operator-owned DESIRED state (DR-006 §A.1):
#   - desired & not-running       → LAUNCH   (cold-start / reboot-recovery, §A.4)
#   - desired & running-but-deaf  → HEAL     (the tiered ladder, §"Tiered response")
#   - desired-down (paused, §A.3) → SKIP     (never resurrect — don't-fight-the-operator)
#   - desired & reachable+accept  → OK
#
# This is the Kubernetes reconcile model on the VM: desired (the manifest) vs
# actual (probed live). It CONSUMES DR-030's `macf fleet doctor --json` — it does
# NOT re-implement detection (DR-006 §"Decision"). Identity is keyed on the
# per-agent `ack_agent` (kebab routing-label), NOT `name` (registry-key form) —
# verified against the 0.2.39 schema (macf#118).
#
# INCREMENT 1 (this file): the reconcile ENGINE — read desired → probe actual →
#   compute + report per-agent decisions. Report-only (no kills/launches).
# INCREMENT 2 (follow-up): action execution — the tiered ladder (Tier-1 gated
#   inject → Tier-2 restart-self [held behind operator sign-off] → Tier-3 alert)
#   + LAUNCH (detached claude.sh) + host-installed cron + the self-heartbeat.
#
# The routing-infra probe (`macf routing doctor --json`) is a later increment;
# note its `session_ok` is currently a false-positive on hand-wired substrate
# agents (assert-if-present gap, macf#610) — the reconciler will treat it as
# assert-if-present and NOT fault on it.
#
# Refs: design/DR-006-vm-cron-watchdog-agent-supervision-impl.md ; macf DR-031.

set -euo pipefail

# --- config / args -----------------------------------------------------------
MANIFEST="${MACF_DESIRED_AGENTS:-$HOME/.macf/desired-agents.yaml}"
PAUSED_DIR="${MACF_PAUSED_DIR:-$HOME/.macf/paused}"
FLEET_JSON=""            # optional: read fleet-doctor output from a file (tests/offline)
FLEET_DOCTOR_CMD="${MACF_FLEET_DOCTOR_CMD:-macf fleet doctor --json}"
EXPECTED_SCHEMA=1

usage() {
  cat <<USAGE
reconcile.sh — DR-006 desired-state reconciler (increment 1: report-only)

  --manifest <path>   desired-agents.yaml (default: \$HOME/.macf/desired-agents.yaml)
  --fleet-json <file> read 'fleet doctor --json' from a file instead of running it
                      (for tests / offline); else runs: $FLEET_DOCTOR_CMD
  --paused-dir <dir>  paused-sentinel dir (default: \$HOME/.macf/paused)
  -h, --help

Exit: 0 = all desired agents OK (or paused); 1 = one or more need LAUNCH/HEAL;
      2 = usage/precondition error.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)   MANIFEST="$2"; shift 2 ;;
    --fleet-json) FLEET_JSON="$2"; shift 2 ;;
    --paused-dir) PAUSED_DIR="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "reconcile.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "FATAL: jq not found (cron needs host-prelude)" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "FATAL: desired-agents manifest not found: $MANIFEST" >&2; exit 2; }

# --- 1. read DESIRED state ---------------------------------------------------
# Minimal awk parse of the fixed manifest shape (no yq dependency — cron-light;
# the manifest is a controlled internal format, see desired-agents.example.yaml).
# Pairs each "- agent: <x>" with the following "workspace: <y>". Strips inline
# comments + surrounding whitespace/quotes. Yields lines: "<agent>\t<workspace>".
DESIRED="$(awk '
  function clean(s){ sub(/[[:space:]]*#.*$/,"",s); gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
  /^[[:space:]]*-[[:space:]]*agent:/ { sub(/^[^:]*:[[:space:]]*/,""); ag=clean($0); next }
  /^[[:space:]]*workspace:/ && ag!="" { sub(/^[^:]*:[[:space:]]*/,""); print ag "\t" clean($0); ag="" }
' "$MANIFEST")"
[ -n "$DESIRED" ] || { echo "FATAL: manifest has no agents (expected '- agent:'/'workspace:' pairs): $MANIFEST" >&2; exit 2; }

# --- 2. probe ACTUAL state (consume DR-030 fleet doctor --json) ---------------
if [ -n "$FLEET_JSON" ]; then
  [ -f "$FLEET_JSON" ] || { echo "FATAL: --fleet-json file not found: $FLEET_JSON" >&2; exit 2; }
  ACTUAL_RAW="$(cat "$FLEET_JSON")"
else
  ACTUAL_RAW="$($FLEET_DOCTOR_CMD)" \
    || { echo "FATAL: '$FLEET_DOCTOR_CMD' failed (mesh probe)" >&2; exit 2; }
fi

# HARD schema-version assert (a silent field-rename would blind the supervisor —
# itself a silent-fallback; macf#118). Fail LOUD on unknown version.
GOT_SCHEMA="$(printf '%s' "$ACTUAL_RAW" | jq -r '.schema_version // "missing"')"
[ "$GOT_SCHEMA" = "$EXPECTED_SCHEMA" ] || {
  echo "FATAL: fleet doctor --json schema_version=$GOT_SCHEMA, expected $EXPECTED_SCHEMA — refusing to parse a drifted schema" >&2
  exit 2
}

# index actual agents by ack_agent (the kebab routing-label identity, NOT name)
# -> "<ack_agent>\t<reachable>\t<accepted>"
ACTUAL="$(printf '%s' "$ACTUAL_RAW" \
  | jq -r '.agents[] | [(.ack_agent // "?"), (.reachable|tostring), (.accepted|tostring)] | @tsv')"

actual_field() { # $1=agent $2=col(2|3)  -> reachable|accepted, or "" if absent
  printf '%s\n' "$ACTUAL" | awk -F'\t' -v a="$1" -v c="$2" '$1==a{print $c; found=1} END{if(!found) print ""}'
}

# --- 3. reconcile: desired vs actual -----------------------------------------
rc=0
printf '%-16s %-10s %s\n' "AGENT" "DECISION" "DETAIL"
printf '%-16s %-10s %s\n' "-----" "--------" "------"
while IFS=$'\t' read -r agent workspace; do
  [ -n "$agent" ] || continue
  if [ -e "$PAUSED_DIR/$agent" ]; then
    printf '%-16s %-10s %s\n' "$agent" "SKIP" "paused (desired-down; $PAUSED_DIR/$agent) — not resurrected"
    continue
  fi
  reachable="$(actual_field "$agent" 2)"
  accepted="$(actual_field "$agent" 3)"
  if [ -z "$reachable" ]; then
    printf '%-16s %-10s %s\n' "$agent" "LAUNCH" "not registered/running → cold-start (ws: $workspace)"
    rc=1
  elif [ "$reachable" = "true" ] && [ "$accepted" = "true" ]; then
    printf '%-16s %-10s %s\n' "$agent" "OK" "reachable + accepting"
  elif [ "$reachable" = "true" ]; then
    printf '%-16s %-10s %s\n' "$agent" "HEAL" "reachable but NOT accepting → tiered ladder (incr.2)"
    rc=1
  else
    printf '%-16s %-10s %s\n' "$agent" "HEAL" "registered but channel DOWN (deaf) → tiered ladder (incr.2)"
    rc=1
  fi
done <<< "$DESIRED"

echo
if [ "$rc" -eq 0 ]; then
  echo "reconcile: all desired agents OK or paused — no action."
else
  echo "reconcile: one or more agents need LAUNCH/HEAL (action execution = increment 2)."
fi
exit "$rc"
