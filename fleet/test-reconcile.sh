#!/usr/bin/env bash
#
# test-reconcile.sh — unit tests for the DR-006 reconcile engine (reconcile.sh).
# Pure-offline: feeds canned `fleet doctor --json` fixtures via --fleet-json, so
# no live fleet / network is needed. Run: ./fleet/test-reconcile.sh  (or `make test`).

set -uo pipefail
cd "$(dirname "$0")/.."   # repo root
REC=fleet/reconcile.sh
MAN=fleet/desired-agents.example.yaml
FX=fleet/testdata
PAUSED="$(mktemp -d)"
pass=0 fail=0

# assert_decision <fixture> <agent> <expected-decision> [extra reconcile args...]
assert_decision() {
  local fixture="$1" agent="$2" want="$3"; shift 3
  local got
  got="$("$REC" --manifest "$MAN" --fleet-json "$FX/$fixture" "$@" 2>/dev/null \
        | awk -v a="$agent" '$1==a{print $2}')"
  if [ "$got" = "$want" ]; then
    echo "  ok: [$fixture] $agent → $want"; pass=$((pass+1))
  else
    echo "  FAIL: [$fixture] $agent → got '$got', want '$want'"; fail=$((fail+1))
  fi
}
# assert_exit <fixture> <expected-exit> [extra args...]
assert_exit() {
  local fixture="$1" want="$2"; shift 2
  "$REC" --manifest "$MAN" --fleet-json "$FX/$fixture" "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then echo "  ok: [$fixture] exit=$want"; pass=$((pass+1))
  else echo "  FAIL: [$fixture] exit got $got, want $want"; fail=$((fail+1)); fi
}

echo "== reconcile engine tests =="
# healthy fleet → every desired agent OK, exit 0
assert_decision fleet-healthy.json devops-agent  OK
assert_decision fleet-healthy.json code-agent    OK
assert_exit     fleet-healthy.json 0
# paused agent → SKIP (desired-down, never resurrected)
: > "$PAUSED/auditor-agent"
assert_decision fleet-healthy.json auditor-agent SKIP --paused-dir "$PAUSED"
# degraded fleet → deaf=HEAL, not-accepting=HEAL, missing=LAUNCH, exit 1
assert_decision fleet-degraded.json devops-agent  HEAL
assert_decision fleet-degraded.json science-agent HEAL
assert_decision fleet-degraded.json auditor-agent OK
assert_decision fleet-degraded.json code-agent    LAUNCH
assert_exit     fleet-degraded.json 1
# drifted schema_version → fail-loud, exit 2 (the silent-fallback guard)
assert_exit     fleet-badschema.json 2

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
