#!/usr/bin/env bash
#
# test-reconcile.sh — unit tests for the DR-006 reconciler (reconcile.sh).
# Pure-offline: canned `fleet doctor --json` fixtures via --fleet-json, and all
# action paths run in DRY-RUN (no real tmux/launches/kills). Temp dirs isolate
# the paused / last-exit / alert state. Run: ./fleet/test-reconcile.sh.

set -uo pipefail
cd "$(dirname "$0")/.."   # repo root
REC=fleet/reconcile.sh
MAN=fleet/desired-agents.example.yaml
FX=fleet/testdata
PAUSED="$(mktemp -d)"; LASTEXIT="$(mktemp -d)"; ALERTS="$(mktemp -d)"
BASE=(--manifest "$MAN" --paused-dir "$PAUSED" --last-exit-dir "$LASTEXIT")
export MACF_ALERT_DIR="$ALERTS"
pass=0 fail=0

run() { "$REC" "${BASE[@]}" "$@" 2>&1; }   # always dry-run unless --execute passed

# assert_decision <fixture> <agent> <expected> [extra args...]
assert_decision() {
  local fx="$1" agent="$2" want="$3"; shift 3
  local got; got="$(run --fleet-json "$FX/$fx" "$@" | awk -v a="$agent" '$1==a{print $2; exit}')"
  if [ "$got" = "$want" ]; then echo "  ok: [$fx] $agent → $want"; pass=$((pass+1))
  else echo "  FAIL: [$fx] $agent → got '$got' want '$want'"; fail=$((fail+1)); fi
}
# assert_contains <desc> <substring> -- <run-args...>
# Capture output first, THEN grep — avoids the pipefail+`grep -q`-SIGPIPE trap
# (grep -q exits on match → producer gets SIGPIPE 141 → pipefail false-fails).
assert_contains() {
  local desc="$1" sub="$2"; shift 2; [ "$1" = "--" ] && shift
  local out; out="$(run "$@")"
  if printf '%s\n' "$out" | grep -qF "$sub"; then echo "  ok: $desc"; pass=$((pass+1))
  else echo "  FAIL: $desc (missing: '$sub')"; fail=$((fail+1)); fi
}
assert_exit() {
  local fx="$1" want="$2"; shift 2; run --fleet-json "$FX/$fx" "$@" >/dev/null 2>&1
  local got=$?; if [ "$got" -eq "$want" ]; then echo "  ok: [$fx] exit=$want"; pass=$((pass+1))
  else echo "  FAIL: [$fx] exit got $got want $want"; fail=$((fail+1)); fi
}

echo "== decision engine (increment 1, still green) =="
assert_decision fleet-healthy.json  devops-agent  OK
assert_decision fleet-healthy.json  code-agent    OK
assert_exit     fleet-healthy.json  0
: > "$PAUSED/auditor-agent"
assert_decision fleet-healthy.json  auditor-agent SKIP
assert_decision fleet-degraded.json devops-agent  HEAL
assert_decision fleet-degraded.json science-agent HEAL
assert_decision fleet-degraded.json code-agent    LAUNCH
assert_exit     fleet-degraded.json 1
assert_exit     fleet-badschema.json 2

echo "== exit-code intent layer (increment 2, B.1/B.2) =="
# code-agent is missing in fleet-degraded; with no last-exit → LAUNCH (absent→restore)
assert_decision fleet-degraded.json code-agent LAUNCH
# last-exit==0 (operator typed /exit) → SKIP (desired-down)
echo 0 > "$LASTEXIT/code-agent"
assert_decision fleet-degraded.json code-agent SKIP
# last-exit==143 (SIGTERM / operational) → LAUNCH (non-zero → restore)
echo 143 > "$LASTEXIT/code-agent"
assert_decision fleet-degraded.json code-agent LAUNCH
rm -- "$LASTEXIT/code-agent" 2>/dev/null || : > "$LASTEXIT/code-agent"

echo "== action construction (dry-run; no real side effects) =="
assert_contains "LAUNCH builds detached exit-code-captured tmux session" \
  "tmux new-session -d -s macf@code-agent" -- --fleet-json "$FX/fleet-degraded.json"
assert_contains "LAUNCH wrapper captures \$? to last-exit" \
  "echo \$? > $LASTEXIT/code-agent" -- --fleet-json "$FX/fleet-degraded.json"
assert_contains "HEAL ladder shows Tier-1 gated inject" \
  "Tier-1 inject" -- --fleet-json "$FX/fleet-degraded.json"

echo "== Tier-2 restart gating (held behind --allow-restart) =="
assert_contains "Tier-2 SUPPRESSED without --allow-restart" \
  "Tier-2 graceful-restart of devops-agent SUPPRESSED" -- --fleet-json "$FX/fleet-degraded.json"
assert_contains "Tier-2 constructs restart cmd WITH --allow-restart" \
  "Tier-2 graceful-restart devops-agent" -- --fleet-json "$FX/fleet-degraded.json" --allow-restart

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
