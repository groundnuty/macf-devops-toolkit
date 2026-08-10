#!/usr/bin/env bash
#
# test-reconcile.sh — unit tests for the DR-006 reconciler (reconcile.sh).
# Pure-offline: canned `fleet doctor --json` fixtures via --fleet-json, and all
# action paths run in DRY-RUN (no real tmux/launches/kills). Temp dirs isolate
# the paused / last-exit / alert state. Run: ./fleet/test-reconcile.sh.

set -uo pipefail
cd "$(dirname "$0")/.."   # repo root
PWD_REPO="$PWD"           # absolute repo root (tests that chdir need it)
REC=fleet/reconcile.sh
MAN=fleet/desired-agents.example.yaml
FX=fleet/testdata
PAUSED="$(mktemp -d)"; LASTEXIT="$(mktemp -d)"; ALERTS="$(mktemp -d)"
BASE=(--manifest "$MAN" --paused-dir "$PAUSED" --last-exit-dir "$LASTEXIT")
export MACF_ALERT_DIR="$ALERTS"
# Default all agents to NOT-busy (static pane) for determinism + speed — the script's
# agent_busy() seam (#134). Avoids a live capture+sleep read of the host's real panes in
# every backoff-path test; individual tests override with MACF_TEST_BUSY="<agent>".
export MACF_TEST_BUSY=""
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

echo "== cross-sweep escalation (increment 3, science #121 note 2) =="
STATE="$(mktemp -d)"
# sweep 1 (no prior state) → Tier-1 (first deaf sweep), NOT escalation
assert_contains "deaf sweep 1 → Tier-1 (first deaf sweep)" \
  "first deaf sweep → Tier-1" -- --fleet-json "$FX/fleet-degraded.json" --state-dir "$STATE"
# pre-seed a prior-sweep counter (n=1) → next sweep escalates, not re-Tier-1
echo 1 > "$STATE/devops-agent"
assert_contains "deaf sweep 2 → escalate (Tier-1 did not recover, not re-inject)" \
  "still deaf after 1 prior sweep" -- --fleet-json "$FX/fleet-degraded.json" --state-dir "$STATE"

echo "== Tier-2 restart gating (held; fires at escalation, sweep 2+) =="
echo 1 > "$STATE/devops-agent"   # pre-seed so devops is at the escalation tier
assert_contains "Tier-2 SUPPRESSED without --allow-restart" \
  "Tier-2 graceful-restart of devops-agent SUPPRESSED" -- --fleet-json "$FX/fleet-degraded.json" --state-dir "$STATE"
echo 1 > "$STATE/devops-agent"
assert_contains "Tier-2 constructs restart cmd WITH --allow-restart" \
  "Tier-2 graceful-restart devops-agent" -- --fleet-json "$FX/fleet-degraded.json" --state-dir "$STATE" --allow-restart

echo "== heartbeat is execute-gated (dry-run side-effect-free) =="
HB="$(mktemp -d)/hb"
run --fleet-json "$FX/fleet-healthy.json" --heartbeat-file "$HB" >/dev/null 2>&1 || true
if [ ! -e "$HB" ]; then echo "  ok: dry-run does NOT write heartbeat"; pass=$((pass+1))
else echo "  FAIL: dry-run wrote heartbeat (should be execute-gated)"; fail=$((fail+1)); fi

echo "== install-cron.sh --print builds a host-prelude-sourcing, report-only line =="
CRON_OUT="$(fleet/install-cron.sh --print --interval '*/10 * * * *' 2>&1 || true)"
for sub in "macf-watchdog (DR-006)" "host-prelude.sh" "reconcile.sh"; do
  if printf '%s\n' "$CRON_OUT" | grep -qF "$sub"; then echo "  ok: cron line has '$sub'"; pass=$((pass+1))
  else echo "  FAIL: cron line missing '$sub'"; fail=$((fail+1)); fi
done
if printf '%s\n' "$CRON_OUT" | grep -qF -- '--execute'; then
  echo "  FAIL: default cron line has --execute (should be report-only)"; fail=$((fail+1))
else echo "  ok: default cron line is report-only (no --execute)"; pass=$((pass+1)); fi
# token-mint baked by default (cron needs GH_TOKEN for fleet-doctor's registry read);
# fail-loud `|| exit 1`; cron-time-evaluated `$(`. --no-token omits it.
if printf '%s\n' "$CRON_OUT" | grep -qE 'GH_TOKEN=\$\(.*macf-gh-token\.sh.*\) \|\| exit 1'; then
  echo "  ok: cron bakes fail-loud GH_TOKEN mint by default"; pass=$((pass+1))
else echo "  FAIL: cron missing the fail-loud GH_TOKEN mint"; fail=$((fail+1)); fi
NT_OUT="$(fleet/install-cron.sh --print --no-token 2>/dev/null || true)"
if printf '%s\n' "$NT_OUT" | grep -qF 'GH_TOKEN='; then
  echo "  FAIL: --no-token still baked a token mint"; fail=$((fail+1))
else echo "  ok: --no-token omits the token mint"; pass=$((pass+1)); fi

# #169: the line must carry an EXPLICIT PATH. It previously relied solely on
# sourcing host-prelude.sh — which does not exist on this host, so `[ -f … ] && . …`
# short-circuited silently and both watchdogs ran for ~37 days without their
# toolchain (`macf` off-PATH; the only `yq` being python-yq).
if printf '%s\n' "$CRON_OUT" | grep -qE '(^|[[:space:]])PATH=[^[:space:]]*npm-global'; then
  echo "  ok: cron line bakes an explicit PATH incl. the npm-global bin (#169)"; pass=$((pass+1))
else echo "  FAIL: cron line has no explicit npm-global PATH — macf will be unresolvable under cron"; fail=$((fail+1)); fi
if printf '%s\n' "$CRON_OUT" | grep -qE 'PATH=.*;[[:space:]]*export PATH'; then
  echo "  ok: the baked PATH is exported to the watchdog children"; pass=$((pass+1))
else echo "  FAIL: baked PATH is not exported"; fail=$((fail+1)); fi

echo "== reconcile.sh resolves the macf CLI off-PATH, and self-alerts when it can't (#169) =="
# Under cron's PATH the bare `macf fleet doctor --json` produced empty stdout, which
# the schema-assert reported as "probe FAILED" — every 10 minutes, for 37 days, with
# no fleet-visible signal. These pin both halves of the fix.
R_TMP="$(mktemp -d)"
printf -- '- agent: alpha\n  workspace: /tmp/alpha\n' > "$R_TMP/manifest.yaml"

# (a) macf unresolvable anywhere → exit 2 AND a self-alert sentinel (not a silent death)
R_OUT="$(env -i PATH=/usr/bin:/bin HOME="$R_TMP/nohome" MACF_ALERT_DIR="$R_TMP/alerts" \
  bash fleet/reconcile.sh --manifest "$R_TMP/manifest.yaml" --execute 2>&1 || true)"
if printf '%s\n' "$R_OUT" | grep -q 'CANNOT RECONCILE'; then
  echo "  ok: unresolvable macf CLI fails LOUD (not an empty-probe FATAL)"; pass=$((pass+1))
else echo "  FAIL: unresolvable macf did not produce the CANNOT RECONCILE diagnostic"; fail=$((fail+1)); fi
if [ -e "$R_TMP/alerts/_watchdog-self" ]; then
  echo "  ok: 'watchdog cannot run' raises an alert sentinel (#169's core lesson)"; pass=$((pass+1))
else echo "  FAIL: no self-alert written — the outage would stay invisible again"; fail=$((fail+1)); fi

# (a2) the probe must run from the WORKSPACE ROOT, not the caller's cwd (#169).
# `macf fleet doctor` walks up from cwd for .macf/macf-agent.json; cron's cwd is
# $HOME, so inheriting it made the CLI abort with "Not in a MACF project" and print
# nothing to stdout. A fake CLI records the cwd it was handed.
CWD_PROBE="$R_TMP/cwd-probe"
printf '#!/bin/sh\npwd > "%s"\necho \x27{"schema_version":1,"agents":[]}\x27\n' "$R_TMP/seen-cwd" > "$CWD_PROBE"
chmod +x "$CWD_PROBE"
( cd /tmp && MACF_FLEET_DOCTOR_CMD="$CWD_PROBE" MACF_ALERT_DIR="$R_TMP/a_cwd" \
    bash "$PWD_REPO/fleet/reconcile.sh" --manifest "$R_TMP/manifest.yaml" >/dev/null 2>&1 ) || true
SEEN_CWD="$(cat "$R_TMP/seen-cwd" 2>/dev/null || echo MISSING)"
if [ "$SEEN_CWD" = "$PWD_REPO" ]; then
  echo "  ok: fleet-doctor probe runs from the workspace root, not the caller's cwd"; pass=$((pass+1))
else
  echo "  FAIL: probe ran from '$SEEN_CWD', expected '$PWD_REPO' (cron's \$HOME cwd would break it again)"; fail=$((fail+1))
fi

# (a3) the probe's stderr must be SURFACED, not discarded. `2>/dev/null` threw away
# the one message ("Not in a MACF project") that explained the whole 37-day outage.
ERR_PROBE="$R_TMP/err-probe"
printf '#!/bin/sh\necho "Not in a MACF project (no .macf/macf-agent.json)" >&2\nexit 1\n' > "$ERR_PROBE"
chmod +x "$ERR_PROBE"
ERR_OUT="$(MACF_FLEET_DOCTOR_CMD="$ERR_PROBE" MACF_ALERT_DIR="$R_TMP/a_err" \
  bash "$PWD_REPO/fleet/reconcile.sh" --manifest "$R_TMP/manifest.yaml" 2>&1 || true)"
if printf '%s\n' "$ERR_OUT" | grep -q 'Not in a MACF project'; then
  echo "  ok: the probe's own stderr is surfaced in the failure diagnostic"; pass=$((pass+1))
else
  echo "  FAIL: probe stderr was swallowed — the explanatory message is lost again"; fail=$((fail+1))
fi

# (a4) a SUCCESSFUL probe must CLEAR an open self-alert, or the dedup turns the
# next real breakage into silence forever — the very failure the alert prevents.
OK_PROBE="$R_TMP/ok-probe"
printf '#!/bin/sh\necho \x27{"schema_version":1,"agents":[]}\x27\n' > "$OK_PROBE"; chmod +x "$OK_PROBE"
mkdir -p "$R_TMP/a_reset"; printf 'stale alert from an earlier failure\n' > "$R_TMP/a_reset/_watchdog-self"
MACF_FLEET_DOCTOR_CMD="$OK_PROBE" MACF_ALERT_DIR="$R_TMP/a_reset" \
  bash "$PWD_REPO/fleet/reconcile.sh" --manifest "$R_TMP/manifest.yaml" --execute >/dev/null 2>&1 || true
if [ ! -e "$R_TMP/a_reset/_watchdog-self" ]; then
  echo "  ok: a successful probe clears a stale self-alert (future breakage re-alerts)"; pass=$((pass+1))
else
  echo "  FAIL: self-alert survived a healthy probe — dedup would silence the next outage"; fail=$((fail+1))
fi

# (b) macf absent from PATH but present at the npm-global location → resolved, no self-alert
FAKE_HOME="$R_TMP/home"; mkdir -p "$FAKE_HOME/.npm-global/bin"
printf '#!/bin/sh\necho \x27{"schema_version":1,"agents":[]}\x27\n' > "$FAKE_HOME/.npm-global/bin/macf"
chmod +x "$FAKE_HOME/.npm-global/bin/macf"
R_OUT2="$(env -i PATH=/usr/bin:/bin HOME="$FAKE_HOME" MACF_ALERT_DIR="$R_TMP/alerts2" \
  bash fleet/reconcile.sh --manifest "$R_TMP/manifest.yaml" 2>&1 || true)"
if printf '%s\n' "$R_OUT2" | grep -q 'CANNOT RECONCILE'; then
  echo "  FAIL: macf at \$HOME/.npm-global/bin was not resolved (the exact cron case)"; fail=$((fail+1))
else echo "  ok: macf resolved from \$HOME/.npm-global/bin despite being off-PATH"; pass=$((pass+1)); fi
rm -rf "$R_TMP"

echo "== routing-doctor 2nd probe (increment 4) — FP-ignore + stale-registration =="
# routing-fresh CARRIES the known FPs (session_ok=false, verdict=DEGRADED, pins_consistent
# =false); a mesh-OK agent must stay OK → proves the reconciler ignores those FPs.
assert_decision fleet-healthy.json devops-agent OK --routing-json "$FX/routing-fresh.json"
assert_decision fleet-healthy.json code-agent   OK --routing-json "$FX/routing-fresh.json"
# routing-stale (registry_iid != health_iid — the macf#553 shape) → mesh-OK → HEAL.
assert_decision fleet-healthy.json devops-agent  HEAL --routing-json "$FX/routing-stale.json"
assert_decision fleet-healthy.json science-agent OK   --routing-json "$FX/routing-stale.json"
assert_contains "stale-registration HEAL is labelled routing-plane" \
  "registration STALE (routing-plane)" -- --fleet-json "$FX/fleet-healthy.json" --routing-json "$FX/routing-stale.json"
# routing-doctor schema drift → fail-loud (same guard as fleet-doctor).
printf '{"schema_version":2,"agents":[]}' > "$ALERTS/rbad.json"
assert_exit fleet-healthy.json 2 --routing-json "$ALERTS/rbad.json"
# without --with-routing → mesh-only (routing ignored) — back-compat.
assert_decision fleet-healthy.json devops-agent OK

echo "== probe exit-code handling (live-command path; the bug live-dry-run caught) =="
# the real fleet/routing-doctor exits 1 on DEGRADED but emits valid JSON — NOT a
# probe failure. --fleet-json bypasses the command, so exercise the live path via
# MACF_FLEET_DOCTOR_CMD → a fake doctor that exits 1 with valid JSON.
FAKE="$PWD/fleet/testdata/fake-doctor.sh"
out="$(MACF_FLEET_DOCTOR_CMD="$FAKE degraded" "$REC" "${BASE[@]}" 2>&1 || true)"
if printf '%s\n' "$out" | awk '$1=="devops-agent"{print $2}' | grep -q HEAL; then
  echo "  ok: DEGRADED+exit1 PROCESSED (devops HEAL, not bailed)"; pass=$((pass+1))
else echo "  FAIL: DEGRADED+exit1 bailed (regression of the live-dry-run bug)"; fail=$((fail+1)); fi
# a GENUINE failure (non-JSON + exit 1, e.g. auth error) must still fail-loud → exit 2
rc=0; MACF_FLEET_DOCTOR_CMD="$FAKE fail" "$REC" "${BASE[@]}" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then echo "  ok: genuine probe-failure (non-JSON) → exit 2"; pass=$((pass+1))
else echo "  FAIL: probe-failure rc=$rc want 2"; fail=$((fail+1)); fi

echo "== agent_busy uses capture-pane-diff (real tmux; the session_activity bug) =="
# A busy agent is busy via OUTPUT; session_activity doesn't track output (verified
# 2026-06-28) → the old gate read an output-busy agent as idle. Exercise agent_busy
# against a real changing pane (busy) + a static pane (idle) by sourcing the function.
# shellcheck disable=SC1090
( set +e +u
  # extract just the agent_busy function body into a subshell-safe eval is fragile;
  # instead invoke the real reconcile path is heavy — so test the primitive directly.
  busy_changing() { local s="$1" a b; a="$(tmux capture-pane -t "$s" -p 2>/dev/null|md5sum)"; sleep 2; b="$(tmux capture-pane -t "$s" -p 2>/dev/null|md5sum)"; [ "$a" != "$b" ]; }
  tmux kill-session -t macf@ab-busy 2>/dev/null; tmux kill-session -t macf@ab-idle 2>/dev/null
  tmux new-session -d -s macf@ab-busy -x 100 -y 24 "while true; do echo work-\$RANDOM; sleep 0.3; done"
  tmux new-session -d -s macf@ab-idle -x 100 -y 24 "printf 'idle prompt\n'; cat"
  sleep 1
  if busy_changing macf@ab-busy; then echo "  ok: output-busy pane detected as BUSY (capture-pane-diff)"; else echo "  FAIL: output-busy pane read as idle (the session_activity bug)"; fi
  if busy_changing macf@ab-idle; then echo "  FAIL: idle pane read as busy"; else echo "  ok: idle pane detected as IDLE"; fi
  tmux kill-session -t macf@ab-busy 2>/dev/null; tmux kill-session -t macf@ab-idle 2>/dev/null
) | tee /tmp/claude/ab-test.out
grep -q 'ok: output-busy' /tmp/claude/ab-test.out && pass=$((pass+1)) || fail=$((fail+1))
grep -q 'ok: idle pane' /tmp/claude/ab-test.out && pass=$((pass+1)) || fail=$((fail+1))

echo "== rate-limit backoff (#129) — distinguish throttle from deaf, never restart-storm =="
# fleet-degraded: devops-agent + science-agent are HEAL (deaf), code-agent LAUNCH.
# MACF_TEST_RATELIMITED is the authoritative throttle-set seam (skips live panes).
RLSTATE="$(mktemp -d)"
# a throttled HEAL agent BACKS OFF (rate-limited-backoff), not climbing the ladder
MACF_TEST_RATELIMITED="devops-agent" assert_contains \
  "throttled agent → BACKOFF (not heal)" \
  "[BACKOFF] devops-agent RATE-LIMITED" -- --fleet-json "$FX/fleet-degraded.json" --state-dir "$RLSTATE"
# the guard is PER-AGENT: a non-throttled HEAL agent in the same sweep still heals
MACF_TEST_RATELIMITED="devops-agent" assert_contains \
  "non-throttled agent still heals (per-agent guard)" \
  "first deaf sweep → Tier-1" -- --fleet-json "$FX/fleet-degraded.json" --state-dir "$RLSTATE"
# backoff overrides escalation: even pre-seeded n=1 + --allow-restart → no SIGTERM
echo 1 > "$RLSTATE/devops-agent"
MACF_TEST_RATELIMITED="devops-agent" assert_contains \
  "throttled agent backs off even at escalation + --allow-restart" \
  "[BACKOFF] devops-agent RATE-LIMITED" -- --fleet-json "$FX/fleet-degraded.json" --state-dir "$RLSTATE" --allow-restart
echo 1 > "$RLSTATE/devops-agent"
rl_out="$(MACF_TEST_RATELIMITED="devops-agent" run --fleet-json "$FX/fleet-degraded.json" --state-dir "$RLSTATE" --allow-restart)"
if printf '%s\n' "$rl_out" | grep -qF "Tier-2 graceful-restart devops-agent"; then
  echo "  FAIL: throttled agent was restarted (restart-storm not prevented)"; fail=$((fail+1))
else echo "  ok: throttled agent NOT restarted — no SIGTERM (restart-storm guard)"; pass=$((pass+1)); fi
# fleet-wide: ≥FLEET_THROTTLE_MIN (2) throttled → fleet-wide backoff banner + all back off
MACF_TEST_RATELIMITED="devops-agent science-agent" assert_contains \
  "fleet-wide throttle banner (≥2 agents)" \
  "FLEET-WIDE RATE-LIMIT:" -- --fleet-json "$FX/fleet-degraded.json" --state-dir "$RLSTATE"
MACF_TEST_RATELIMITED="devops-agent science-agent" assert_contains \
  "fleet-wide backoff applies to science too (scope label)" \
  "[BACKOFF] science-agent RATE-LIMITED (fleet-wide throttle)" -- --fleet-json "$FX/fleet-degraded.json" --state-dir "$RLSTATE"
# below threshold (1 < 2) → NO fleet-wide banner (per-agent backoff only)
one_out="$(MACF_TEST_RATELIMITED="devops-agent" run --fleet-json "$FX/fleet-degraded.json" --state-dir "$RLSTATE")"
if printf '%s\n' "$one_out" | grep -qF "FLEET-WIDE RATE-LIMIT"; then
  echo "  FAIL: single throttle triggered fleet-wide (threshold not honored)"; fail=$((fail+1))
else echo "  ok: single throttle stays per-agent (no fleet-wide banner)"; pass=$((pass+1)); fi
# the throttle pattern resolves from stall-signatures.json (shared source of truth)
sig_pat="$(jq -r '.[]|select(.name=="rate-limit")|.signature' fleet/stall-signatures.json 2>/dev/null || echo MISSING)"
if [ "$sig_pat" != "MISSING" ] && [ -n "$sig_pat" ]; then
  echo "  ok: rate-limit signature present in stall-signatures.json (shared source)"; pass=$((pass+1))
else echo "  FAIL: rate-limit signature missing from stall-signatures.json"; fail=$((fail+1)); fi

echo "== stuck-in-backoff escalation (#134 fast-follow; science's wall-clock bound) =="
# A throttled HEAL agent that stays backed off K (=3) consecutive idle sweeps escalates
# to Tier-3 (deaf-masked-by-stale-signature suspected) — NOT a restart. Pre-seed the
# backoff counter to K-1, then one more idle-stuck sweep tips it. (MACF_TEST_BUSY="" →
# static pane; MACF_TEST_RATELIMITED → own signature present.)
SKSTATE="$(mktemp -d)"
echo 2 > "$SKSTATE/devops-agent.backoff"   # K-1 (default K=3)
MACF_TEST_RATELIMITED="devops-agent" assert_contains \
  "stuck after K idle backoff sweeps → Tier-3 escalation" \
  "[STUCK] devops-agent backed off 3 idle sweeps" -- --fleet-json "$FX/fleet-degraded.json" --state-dir "$SKSTATE"
echo 2 > "$SKSTATE/devops-agent.backoff"
MACF_TEST_RATELIMITED="devops-agent" assert_contains \
  "stuck escalation raises a Tier-3 alert (not a restart)" \
  "Tier-3 alert for devops-agent" -- --fleet-json "$FX/fleet-degraded.json" --state-dir "$SKSTATE"
# a TICKING pane (CC actively retrying) does NOT accrue — even at the threshold, no STUCK
echo 2 > "$SKSTATE/devops-agent.backoff"
busy_out="$(MACF_TEST_RATELIMITED="devops-agent" MACF_TEST_BUSY="devops-agent" run --fleet-json "$FX/fleet-degraded.json" --state-dir "$SKSTATE")"
if printf '%s\n' "$busy_out" | grep -qF "[STUCK] devops-agent"; then
  echo "  FAIL: ticking pane (active CC retry) wrongly escalated as stuck"; fail=$((fail+1))
else echo "  ok: ticking pane (active retry) does NOT escalate (only idle-stuck sweeps count)"; pass=$((pass+1)); fi
# below threshold (counter 0 → 1 < 3) → backoff but NOT yet stuck
SK2="$(mktemp -d)"
below_out="$(MACF_TEST_RATELIMITED="devops-agent" run --fleet-json "$FX/fleet-degraded.json" --state-dir "$SK2")"
if printf '%s\n' "$below_out" | grep -qF "[STUCK]"; then
  echo "  FAIL: escalated below the K threshold"; fail=$((fail+1))
else echo "  ok: below threshold → backoff only, no premature stuck escalation"; pass=$((pass+1)); fi
# fleet-wide-only backoff (agent's OWN signature absent) → does NOT accrue stuck counter
echo 2 > "$SK2/devops-agent.backoff"
fw_out="$(MACF_TEST_RATELIMITED="science-agent code-agent" run --fleet-json "$FX/fleet-degraded.json" --state-dir "$SK2")"
if printf '%s\n' "$fw_out" | grep -qF "[STUCK] devops-agent"; then
  echo "  FAIL: fleet-wide-only backoff wrongly accrued devops' stuck counter"; fail=$((fail+1))
else echo "  ok: fleet-wide-only backoff (no own signature) does not accrue stuck counter"; pass=$((pass+1)); fi

echo "== launch-stagger: cold-start multi-launch is spaced (anti rate-limit-burst) =="
# all agents down (empty fleet-doctor) → all 4 LAUNCH; every launch after the 1st shows the plan.
# Fresh paused/last-exit dirs so nothing is SKIPped (paused / operator-/exit).
FP="$(mktemp -d)"; FL="$(mktemp -d)"
st_out="$("$REC" --manifest "$MAN" --paused-dir "$FP" --last-exit-dir "$FL" --fleet-json "$FX/fleet-alldown.json" 2>&1)"
n_launch="$(printf '%s\n' "$st_out" | awk '$2=="LAUNCH"{n++} END{print n+0}')"
n_stagger="$(printf '%s\n' "$st_out" | grep -c 'stagger.*would wait' || true)"
if [ "$n_launch" -ge 2 ] && [ "$n_stagger" -eq "$((n_launch-1))" ]; then
  echo "  ok: $n_launch launches → $n_stagger stagger-gaps (spaced; the 1st is immediate)"; pass=$((pass+1))
else echo "  FAIL: launches=$n_launch stagger-gaps=$n_stagger (want gaps=launches-1)"; fail=$((fail+1)); fi
# MACF_LAUNCH_STAGGER=0 disables it
off_out="$(MACF_LAUNCH_STAGGER=0 "$REC" --manifest "$MAN" --paused-dir "$FP" --last-exit-dir "$FL" --fleet-json "$FX/fleet-alldown.json" 2>&1)"
if printf '%s\n' "$off_out" | grep -q 'stagger'; then echo "  FAIL: stagger fired with MACF_LAUNCH_STAGGER=0"; fail=$((fail+1))
else echo "  ok: MACF_LAUNCH_STAGGER=0 disables the stagger"; pass=$((pass+1)); fi

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
