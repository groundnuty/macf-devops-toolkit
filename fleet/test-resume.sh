#!/usr/bin/env bash
#
# test-resume.sh — tests for the stall-detect-and-nudge resume tool (resume.sh).
# Uses real throwaway tmux sessions (macf@<fake-agent>) with controlled pane
# content to exercise the idle/busy + stall-signature detection end-to-end.
# Dry-run only — never sends a real nudge to a real agent. Run: ./fleet/test-resume.sh

set -uo pipefail
cd "$(dirname "$0")/.."
RES=fleet/resume.sh
SIG=fleet/stall-signatures.json
TMP="$(mktemp -d)"; STATE="$(mktemp -d)"
pass=0 fail=0

# a manifest naming our throwaway agents
cat > "$TMP/desired.yaml" <<YAML
agents:
  - agent: t-clean
    workspace: /tmp
  - agent: t-ratelimit
    workspace: /tmp
  - agent: t-gone
    workspace: /tmp
  - agent: t-blocked
    workspace: /tmp
YAML

mksession() { # <agent> <pane-text>  — a tmux session showing fixed idle content
  local a="$1" txt="$2"
  tmux kill-session -t "macf@$a" 2>/dev/null || true
  # `cat` holds the pane open + idle (no activity) after printing the text
  tmux new-session -d -s "macf@$a" -x 200 -y 50 "printf '%s\n' \"$txt\"; cat"
}
run() { "$RES" --manifest "$TMP/desired.yaml" --signatures "$SIG" --state-dir "$STATE" "$@" 2>&1; }
decision() { run | awk -v a="$1" '$1==a{print $2" "$3; exit}'; }
chk() { # <desc> <expect-substr> <agent>
  local d="$1" want="$2" a="$3" got; got="$(run | awk -v a="$a" '$1==a{$1="";print; exit}')"
  if printf '%s' "$got" | grep -qF "$want"; then echo "  ok: $d"; pass=$((pass+1))
  else echo "  FAIL: $d — got '$got' want '*$want*'"; fail=$((fail+1)); fi
}

echo "== resume stall-detection (real tmux panes, dry-run) =="
mksession t-clean "❯ DR-032 ok"                                  # idle, no signature
mksession t-ratelimit "API Error: Server is temporarily limiting requests · Rate limited"  # idle + nudge sig
mksession t-blocked "Do you want to proceed? ❯ 1. Yes  2. Yes, and don't ask again  3. No"  # idle + report sig
# t-gone: deliberately NO session
sleep 1

# clean-idle agent → NEVER acted on
chk "clean-idle agent is NOT acted on (no signature)" "idle-clean" t-clean
chk "clean-idle reason says legitimately idle/done"   "never touched" t-clean
# rate-limited idle agent → action=nudge (dry-run plan)
chk "rate-limited idle agent → NUDGE plan"            "NUDGE (rate-limit)" t-ratelimit
# gone agent → skip (resume can't help)
chk "no-session agent → skip"                         "gone"        t-gone

echo "== operator-input-blocked → REPORT, not nudge (#132) =="
# an idle agent showing a permission prompt → action=report (durable alert, NOT a nudge)
chk "permission-prompt agent → REPORT plan (action dispatch)"   "REPORT (permission-prompt)" t-blocked
chk "report path never sends a nudge (authorization needs a human)" "NOT auto-answered" t-blocked
# trust-folder prompt also reports
mksession t-blocked "Do you trust the files in this folder? ❯ 1. Yes, proceed  2. No, exit"
sleep 1
chk "trust-folder-prompt agent → REPORT plan"                   "REPORT (trust-folder-prompt)" t-blocked
# report is fire-capped per episode (max_fires=1): a maxed counter → skip (already reported)
echo 1 > "$STATE/t-blocked.report"
rc="$(run | awk '$1=="t-blocked"{$1="";print}')"
if printf '%s' "$rc" | grep -qF "already reported this episode"; then echo "  ok: report fire-cap → reported once per episode"; pass=$((pass+1))
else echo "  FAIL: report fire-cap not honored — '$rc'"; fail=$((fail+1)); fi
rm -f "$STATE/t-blocked.report"

echo "== busy agent is never nudged =="
# a session whose pane keeps changing = busy (session_activity advances)
tmux kill-session -t macf@t-busy 2>/dev/null || true
tmux new-session -d -s macf@t-busy -x 200 -y 50 "while true; do printf 'Rate limited %s\n' \"\$RANDOM\"; sleep 0.3; done"
sleep 1
# even WITH a rate-limit string in the pane, busy → skip (don't interrupt working agent)
cat > "$TMP/d2.yaml" <<YAML
agents:
  - agent: t-busy
    workspace: /tmp
YAML
busy_dec="$("$RES" --manifest "$TMP/d2.yaml" --signatures "$SIG" --state-dir "$STATE" 2>&1 | awk '$1=="t-busy"{print $2}')"
if [ "$busy_dec" = "busy" ]; then echo "  ok: busy agent skipped even with stall-string in pane"; pass=$((pass+1))
else echo "  FAIL: busy agent decision='$busy_dec' want 'busy'"; fail=$((fail+1)); fi

echo "== fire-cap: a maxed-out counter → escalate not re-nudge =="
echo 99 > "$STATE/t-ratelimit"   # exceed max_fires
fc="$(run | awk '$1=="t-ratelimit"{$1="";print}')"
if printf '%s' "$fc" | grep -qF "fire-cap"; then echo "  ok: fire-cap reached → escalate, not re-nudge"; pass=$((pass+1))
else echo "  FAIL: fire-cap not honored — '$fc'"; fail=$((fail+1)); fi

# cleanup
for a in t-clean t-ratelimit t-busy t-blocked; do tmux kill-session -t "macf@$a" 2>/dev/null || true; done

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
