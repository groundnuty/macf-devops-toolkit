#!/usr/bin/env bash
#
# reconcile.sh — the VM cron-watchdog DESIRED-STATE RECONCILER (DR-006).
#
# Drives actual fleet state → operator-owned DESIRED state (DR-006 §A.1):
#   - desired & not-running       → LAUNCH   (cold-start / reboot-recovery, §A.4)
#   - desired & running-but-deaf  → HEAL     (the tiered ladder, §"Tiered response")
#   - desired-down                → SKIP     (never resurrect — don't-fight-the-operator)
#       desired-down = `paused` sentinel (explicit, §A.3) OR last-exit==0 (the
#       operator typed `/exit`, §B.1) — the two compose (DR-031 §A.3 unification).
#   - desired & reachable+accept  → OK
#
# This is the Kubernetes reconcile model on the VM: desired (the manifest) vs
# actual (probed live). It CONSUMES DR-030's `macf fleet doctor --json` — it does
# NOT re-implement detection (DR-006 §"Decision"). Identity is keyed on the
# per-agent `ack_agent` (kebab routing-label), NOT `name` (registry-key form).
#
# INCREMENT 1: the reconcile ENGINE (decisions, report-only).
# INCREMENT 2 (this): ACTION EXECUTION — the exit-code intent layer (B.1/B.2),
#   LAUNCH (detached, exit-code-capture wrapper), and the tiered HEAL ladder
#   (Tier-1 gated inject → Tier-2 graceful-restart [--allow-restart] → Tier-3
#   alert). DRY-RUN BY DEFAULT — constructs + prints commands; `--execute` runs.
#
# Refs: design/DR-006-vm-cron-watchdog-agent-supervision-impl.md ; macf DR-031.

set -euo pipefail

# --- config / args -----------------------------------------------------------
MANIFEST="${MACF_DESIRED_AGENTS:-$HOME/.macf/desired-agents.yaml}"
PAUSED_DIR="${MACF_PAUSED_DIR:-$HOME/.macf/paused}"
LAST_EXIT_DIR="${MACF_LAST_EXIT_DIR:-$HOME/.macf/last-exit}"
ALERT_DIR="${MACF_ALERT_DIR:-$HOME/.macf/alerts}"
FLEET_JSON=""            # optional: read fleet-doctor output from a file (tests/offline)
FLEET_DOCTOR_CMD="${MACF_FLEET_DOCTOR_CMD:-macf fleet doctor --json}"
EXPECTED_SCHEMA=1
EXECUTE=0                # 0 = dry-run (print commands); 1 = actually act (--execute)
ALLOW_RESTART=0          # Tier-2 graceful-restart gate (--allow-restart); default OFF

usage() {
  cat <<USAGE
reconcile.sh — DR-006 desired-state reconciler (increment 2: action execution)

  --manifest <path>     desired-agents.yaml (default: \$HOME/.macf/desired-agents.yaml)
  --fleet-json <file>   read 'fleet doctor --json' from a file (tests/offline)
  --paused-dir <dir>    paused-sentinel dir (default: \$HOME/.macf/paused)
  --last-exit-dir <dir> per-agent last-exit-code dir (default: \$HOME/.macf/last-exit)
  --execute             ACTUALLY act (launch/inject/restart/alert). Default: dry-run.
  --allow-restart       enable Tier-2 graceful-restart (held behind operator sign-off).
  -h, --help

Intent (B.1/B.2): a not-running agent whose last-exit==0 (operator typed /exit)
is desired-DOWN → SKIP. last-exit!=0 or absent (signal/crash/never-ran) → LAUNCH.

Exit: 0 = all OK/paused/down; 1 = action(s) taken or needed; 2 = usage/precondition.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)      MANIFEST="$2"; shift 2 ;;
    --fleet-json)    FLEET_JSON="$2"; shift 2 ;;
    --paused-dir)    PAUSED_DIR="$2"; shift 2 ;;
    --last-exit-dir) LAST_EXIT_DIR="$2"; shift 2 ;;
    --execute)       EXECUTE=1; shift ;;
    --allow-restart) ALLOW_RESTART=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "reconcile.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "FATAL: jq not found (cron needs host-prelude)" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "FATAL: desired-agents manifest not found: $MANIFEST" >&2; exit 2; }

# --- 1. read DESIRED state ---------------------------------------------------
# Minimal awk parse of the fixed manifest shape (no yq dependency — cron-light).
# Pairs each "- agent: <x>" with the following "workspace: <y>". Yields TSV.
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
ACTUAL="$(printf '%s' "$ACTUAL_RAW" \
  | jq -r '.agents[] | [(.ack_agent // "?"), (.reachable|tostring), (.accepted|tostring)] | @tsv')"

actual_field() { # $1=agent $2=col(2|3) -> reachable|accepted, "" if absent
  printf '%s\n' "$ACTUAL" | awk -F'\t' -v a="$1" -v c="$2" '$1==a{print $c; f=1} END{if(!f) print ""}'
}

# --- action helpers (dry-run by default; EXECUTE=1 runs) ---------------------
act() { # $1=label  $2...=command — print always; run only if EXECUTE
  local label="$1"; shift
  if [ "$EXECUTE" -eq 1 ]; then echo "    [EXECUTE] $label"; "$@";
  else echo "    [dry-run] $label: $*"; fi
}

# Tier 0 — LAUNCH a not-running desired agent. The watchdog owns session creation
# (deterministic macf@<agent>) + the exit-code-capture wrapper (B.2): claude's
# real exit code lands in LAST_EXIT_DIR/<agent> so a future /exit (0) is seen as
# desired-down. MACF_NO_TMUX_WRAP=1 avoids double-wrap (we provide the session).
do_launch() {
  local agent="$1" ws="$2"
  local inner="cd $ws && MACF_NO_TMUX_WRAP=1 ./claude.sh; echo \$? > $LAST_EXIT_DIR/$agent"
  if [ "$EXECUTE" -eq 1 ]; then mkdir -p "$LAST_EXIT_DIR"; fi
  act "launch macf@$agent (detached, exit-code-captured)" \
    tmux new-session -d -s "macf@$agent" "$inner"
}

# Tier 1 — inject a self-diagnose prompt, GATED by the Pattern-C session_activity
# check (vs the Instance-3 RC-bound-tmux silent-no-op). Returns 0 if the inject
# was confirmed-delivered (activity advanced), 1 if not (→ fall through to Tier 2).
tier1_inject() {
  local agent="$1" sess="macf@$1"
  local msg="⚠️ You appear OFF-CHANNELS (watchdog): your channel is down/not-accepting. Investigate, clear any stale registry entry, and request a relaunch."
  if [ "$EXECUTE" -ne 1 ]; then
    echo "    [dry-run] Tier-1 inject → $sess (gated by session_activity advance)"
    return 1   # dry-run can't confirm delivery → reports fall-through path
  fi
  local pre post
  pre="$(tmux display -p -t "$sess" '#{session_activity}' 2>/dev/null || echo '')"
  [ -n "$pre" ] || { echo "    [EXECUTE] Tier-1: no tmux session $sess — cannot inject"; return 1; }
  tmux send-keys -t "$sess" "$msg" Enter 2>/dev/null || true
  sleep 2
  post="$(tmux display -p -t "$sess" '#{session_activity}' 2>/dev/null || echo "$pre")"
  if [ "$post" -gt "$pre" ] 2>/dev/null; then
    echo "    [EXECUTE] Tier-1 inject DELIVERED to $sess (activity advanced)"; return 0
  fi
  echo "    [EXECUTE] Tier-1 inject NOT confirmed on $sess (RC-bound?) → fall through"; return 1
}

# Tier 2 — graceful restart of a deaf agent (the external equivalent of
# restart-self): SIGTERM the agent's claude process (graceful → hooks/deregister
# get their ~1.5s, exit 143 → non-zero → next reconcile relaunches), then launch.
# HELD behind --allow-restart (operator sign-off, DR-006 §"Tiered response").
tier2_restart() {
  local agent="$1" ws="$2"
  if [ "$ALLOW_RESTART" -ne 1 ]; then
    echo "    [held] Tier-2 graceful-restart of $agent SUPPRESSED (no --allow-restart; operator sign-off required)"
    return 1
  fi
  local pid=""
  if [ "$EXECUTE" -eq 1 ]; then
    for p in $(pgrep -x claude 2>/dev/null || true); do
      [ "$(readlink "/proc/$p/cwd" 2>/dev/null)" = "$ws" ] && pid="$p"
    done
  fi
  act "Tier-2 graceful-restart $agent: SIGTERM pid=${pid:-<resolve@exec>} (graceful) then relaunch" \
    bash -c "[ -n '$pid' ] && kill -TERM '$pid'; sleep 3"
  do_launch "$agent" "$ws"
}

# Tier 3 — raise a dedup'd alert (one per agent per failure-episode). Stub: writes
# a sentinel; a later increment wires `gh issue create`. Dedup via the sentinel.
tier3_alert() {
  local agent="$1" why="$2"
  if [ -e "$ALERT_DIR/$agent" ]; then
    echo "    [skip] Tier-3 alert for $agent already open (dedup)"; return 0
  fi
  if [ "$EXECUTE" -eq 1 ]; then mkdir -p "$ALERT_DIR"; fi
  act "Tier-3 alert for $agent ($why)" \
    bash -c "echo '$why' > '$ALERT_DIR/$agent'"
}

# HEAL ladder: Tier-1 (gated) → if not delivered, Tier-2 (if allowed) → Tier-3.
do_heal() {
  local agent="$1" ws="$2" why="$3"
  tier1_inject "$agent" && return 0
  tier2_restart "$agent" "$ws" && { tier3_alert "$agent" "restarted after deaf: $why"; return 0; }
  tier3_alert "$agent" "$why"
}

# --- 3. reconcile: decide + act ----------------------------------------------
rc=0
printf '%-16s %-10s %s\n' "AGENT" "DECISION" "DETAIL"
printf '%-16s %-10s %s\n' "-----" "--------" "------"
while IFS=$'\t' read -r agent workspace; do
  [ -n "$agent" ] || continue
  reachable="$(actual_field "$agent" 2)"
  accepted="$(actual_field "$agent" 3)"

  # desired-down (SKIP): explicit paused sentinel OR last-exit==0 (typed /exit)
  if [ -e "$PAUSED_DIR/$agent" ]; then
    printf '%-16s %-10s %s\n' "$agent" "SKIP" "paused (desired-down; explicit) — not resurrected"
    continue
  fi
  if [ -z "$reachable" ] && [ "$(cat "$LAST_EXIT_DIR/$agent" 2>/dev/null || echo X)" = "0" ]; then
    printf '%-16s %-10s %s\n' "$agent" "SKIP" "not running + last-exit==0 (operator /exit) — desired-down, not restarted"
    continue
  fi

  if [ -z "$reachable" ]; then
    printf '%-16s %-10s %s\n' "$agent" "LAUNCH" "not running, last-exit!=0/absent → cold-start (ws: $workspace)"
    do_launch "$agent" "$workspace"; rc=1
  elif [ "$reachable" = "true" ] && [ "$accepted" = "true" ]; then
    printf '%-16s %-10s %s\n' "$agent" "OK" "reachable + accepting"
  elif [ "$reachable" = "true" ]; then
    printf '%-16s %-10s %s\n' "$agent" "HEAL" "reachable but NOT accepting → ladder"
    do_heal "$agent" "$workspace" "reachable-not-accepting"; rc=1
  else
    printf '%-16s %-10s %s\n' "$agent" "HEAL" "registered but channel DOWN (deaf) → ladder"
    do_heal "$agent" "$workspace" "deaf-channel-down"; rc=1
  fi
done <<< "$DESIRED"

echo
mode="dry-run"; [ "$EXECUTE" -eq 1 ] && mode="EXECUTE"; restart="off"; [ "$ALLOW_RESTART" -eq 1 ] && restart="on"
if [ "$rc" -eq 0 ]; then
  echo "reconcile [$mode, restart:$restart]: all desired agents OK / down — no action."
else
  echo "reconcile [$mode, restart:$restart]: action(s) taken or needed above."
fi
exit "$rc"
