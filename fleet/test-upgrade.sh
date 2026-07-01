#!/usr/bin/env bash
# test-upgrade.sh — offline classify + busy-gate tests for upgrade.sh via seams
# (MACF_TEST_LIVE_VERSIONS + MACF_TEST_BUSY). Dry-run only — never restarts an agent.
set -uo pipefail
cd "$(dirname "$0")/.."
UP=fleet/upgrade.sh
TMP="$(mktemp -d)"
pass=0 fail=0
cat > "$TMP/desired.yaml" <<YAML
agents:
  - agent: t-current
    workspace: /tmp
  - agent: t-behind
    workspace: /tmp
  - agent: t-busy
    workspace: /tmp
  - agent: t-down
    workspace: /tmp
YAML
run() {
  MACF_TEST_LIVE_VERSIONS="t-current=0.2.44 t-behind=0.2.40 t-busy=0.2.40 t-down=" \
  MACF_TEST_BUSY="t-busy" \
    "$UP" --manifest "$TMP/desired.yaml" --target 0.2.44 "$@" 2>&1
}
line() { run | awk -v a="$1" '$1==a{$1="";print;exit}'; }
chk() { local d="$1" want="$2" a="$3" got; got="$(line "$a")"
  if printf '%s' "$got" | grep -qF "$want"; then echo "  ok: $d"; pass=$((pass+1))
  else echo "  FAIL: $d — got '$got' want '*$want*'"; fail=$((fail+1)); fi; }

echo "== upgrade classify + busy-gate (offline seams, dry-run) =="
chk "at-target agent → OK"                "OK (at target)"        t-current
chk "behind+idle agent → UPGRADE"         "UPGRADE 0.2.40→0.2.44" t-behind
chk "behind+BUSY agent → SKIP+REPORT"     "BUSY — SKIP + REPORT"  t-busy
chk "unreachable agent → skip"            "UNREACHABLE"           t-down
out="$(run)"
if printf '%s' "$out" | grep -qE 't-busy .*UPGRADE'; then echo "  FAIL: busy agent entered the roll"; fail=$((fail+1))
else echo "  ok: busy agent NOT in the roll (never interrupt)"; pass=$((pass+1)); fi
if printf '%s' "$out" | grep -qF "1 idle agent(s) behind target"; then echo "  ok: roll counts only idle-behind"; pass=$((pass+1))
else echo "  FAIL: roll count wrong"; fail=$((fail+1)); fi
allout="$(MACF_TEST_LIVE_VERSIONS='t-current=0.2.44 t-behind=0.2.44 t-busy=0.2.44 t-down=0.2.44' MACF_TEST_BUSY='' \
  "$UP" --manifest "$TMP/desired.yaml" --target 0.2.44 2>&1 || true)"
if printf '%s' "$allout" | grep -qF "No behind-and-idle agents"; then echo "  ok: all-at-target → nothing to upgrade"; pass=$((pass+1))
else echo "  FAIL: all-at-target not detected"; fail=$((fail+1)); fi
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
