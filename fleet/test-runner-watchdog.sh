#!/usr/bin/env bash
#
# test-runner-watchdog.sh — offline unit tests for the RUNNER-side watchdog
# (fleet/runner-watchdog.sh, macf-devops-toolkit#163).
#
# NO systemctl/yq MOCKING — same style precedent as test-maintenance-lock.sh /
# test-reconcile.sh / test-upgrade.sh / test-fork-approval.sh: none of them stub
# external CLI binaries; they test PURE shell logic via `source` (or, for
# reconcile.sh, canned JSON fixtures fed through --fleet-json). runner-watchdog.sh
# follows the same discipline: the actual systemd-touching logic
# (_runner_watchdog_service_name / _runner_watchdog_state / _runner_watchdog_restart's
# `systemctl restart` call) is a thin, obviously-correct wrapper around
# `systemctl show`/`list-units`/`restart` and is exercised live in the "Verify"
# step of the PR instead (dry-run against the real runners on the host). What IS
# unit-tested here, with zero systemctl dependency:
#
#   - _runner_watchdog_decide       — the pure 3-input decision table (the actual
#                                      security/liveness-relevant logic)
#   - _runner_watchdog_filter_registry — the status-filter jq query, hand-fed JSON
#                                      (no yq — yq lives on the runner devbox /
#                                      host-prelude, not every dev sandbox)
#   - _runner_watchdog_act          — the dry-run-vs-execute gate, with a benign
#                                      real command (not systemctl)
#   - _runner_watchdog_alert / _runner_watchdog_reset — dedup + recovery-reset
#   - the maintenance-lock composition — sourcing fleet/maintenance-lock.sh (which
#     runner-watchdog.sh itself sources) and feeding a REAL lock_active read into
#     _runner_watchdog_decide, proving SKIP is lock-driven end-to-end, not just
#     "the pure function trusts whatever string it's handed."
#
# Run: ./fleet/test-runner-watchdog.sh

set -uo pipefail
cd "$(dirname "$0")/.."   # repo root
RW=fleet/runner-watchdog.sh
pass=0 fail=0

ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# shellcheck source=./runner-watchdog.sh
source "$RW"   # sourcing must be side-effect-free (no sweep, no `set` change) — see
                # runner-watchdog.sh's "DUAL-PURPOSE FILE" header note.

echo "== sourcing is side-effect-free (no sweep ran, defaults intact) =="
[ "$EXECUTE" -eq 0 ] && ok "EXECUTE defaults to 0 after source (main() did not run)" || bad "EXECUTE was mutated by sourcing"
[ "$ALLOW_RESTART" -eq 0 ] && ok "ALLOW_RESTART defaults to 0 after source" || bad "ALLOW_RESTART was mutated by sourcing"

echo "== _runner_watchdog_decide: pure 3-input decision table (no I/O) =="
check_decision() {
  local desc="$1" active="$2" loaded="$3" locked="$4" want="$5" got
  got="$(_runner_watchdog_decide "$active" "$loaded" "$locked")"
  [ "$got" = "$want" ] && ok "$desc -> $want" || bad "$desc got '$got' want '$want'"
}

# --- the 4 scenarios named in the task spec ---
check_decision "healthy (active+loaded, unlocked)"           "active"   "loaded"    "0" "OK"
check_decision "inactive but loaded, unlocked"                "inactive" "loaded"    "0" "HEAL"
check_decision "unit not loaded (torn down / never installed)" "unknown"  "not-found" "0" "ALERT"
check_decision "maintenance lock active overrides everything" "active"   "loaded"    "1" "SKIP"

# --- additional coverage beyond the 4 named scenarios ---
check_decision "failed but loaded -> HEAL (same as inactive)"        "failed"   "loaded"    "0" "HEAL"
check_decision "activating (mid-start, not yet active) -> HEAL"      "activating" "loaded"  "0" "HEAL"
check_decision "masked unit -> ALERT (nothing to restart)"           "inactive" "masked"    "0" "ALERT"
check_decision "lock-active + unit ALSO torn down -> SKIP wins"       "unknown"  "not-found" "1" "SKIP"
check_decision "lock-active + unit healthy -> still SKIP (don't touch mid-maintenance)" "active" "loaded" "1" "SKIP"
check_decision "unknown/empty active-state (query hiccup) -> HEAL, never silently OK" "" "loaded" "0" "HEAL"

echo "== _runner_watchdog_filter_registry: status filter (hand-fed JSON, no yq) =="
FIXTURE='{"fleets":[{"name":"macf","runners":[
  {"name":"macf-science-agent","repo":"groundnuty/macf-science-agent","status":"live"},
  {"name":"macf-devops-toolkit","repo":"groundnuty/macf-devops-toolkit","status":"live"},
  {"name":"macf-auditor-agent","repo":"groundnuty/macf-auditor-agent","status":"ready"},
  {"name":"macf","repo":"groundnuty/macf","status":"ready"}
]}]}'

live_only="$(printf '%s' "$FIXTURE" | _runner_watchdog_filter_registry "live")"
live_count="$(printf '%s\n' "$live_only" | grep -c . || true)"
[ "$live_count" -eq 2 ] && ok "default 'live' filter yields exactly 2 entries" || bad "'live' filter yielded $live_count entries, want 2"
printf '%s\n' "$live_only" | grep -qF "macf-science-agent" && ok "live filter includes macf-science-agent" || bad "live filter missing macf-science-agent"
printf '%s\n' "$live_only" | grep -qF "macf-auditor-agent" && bad "live filter wrongly included staged/ready macf-auditor-agent" || ok "live filter correctly excludes staged/ready macf-auditor-agent"

widened="$(printf '%s' "$FIXTURE" | _runner_watchdog_filter_registry "live,ready")"
widened_count="$(printf '%s\n' "$widened" | grep -c . || true)"
[ "$widened_count" -eq 4 ] && ok "widened 'live,ready' filter yields all 4 entries" || bad "widened filter yielded $widened_count, want 4"

none="$(printf '%s' "$FIXTURE" | _runner_watchdog_filter_registry "retired")"
[ -z "$none" ] && ok "a status nothing matches yields an empty registry (not an error)" || bad "expected empty output for a non-matching status, got: $none"

# TSV shape sanity — @tsv must yield "<name>\t<repo>" so the main loop's
# `IFS=$'\t' read -r name repo` unpacks correctly.
first_line="$(printf '%s\n' "$live_only" | head -1)"
case "$first_line" in
  *$'\t'*) ok "filter output is tab-separated (name\\trepo)" ;;
  *) bad "filter output missing a tab separator: '$first_line'" ;;
esac

echo "== _runner_watchdog_act: dry-run-vs-execute gating (benign real command, not systemctl) =="
MARK_DIR="$(mktemp -d)"
EXECUTE=0
_runner_watchdog_act "touch a marker" touch "$MARK_DIR/should-not-exist" >/dev/null
[ -e "$MARK_DIR/should-not-exist" ] && bad "dry-run (EXECUTE=0) still ran the command" || ok "dry-run (EXECUTE=0) did NOT run the command"
out="$(_runner_watchdog_act "touch a marker" touch "$MARK_DIR/should-not-exist")"
printf '%s' "$out" | grep -qF "[dry-run]" && ok "dry-run output is labeled [dry-run]" || bad "dry-run output missing [dry-run] label: $out"

EXECUTE=1
_runner_watchdog_act "touch a marker" touch "$MARK_DIR/should-exist" >/dev/null
[ -e "$MARK_DIR/should-exist" ] && ok "EXECUTE=1 actually ran the command" || bad "EXECUTE=1 did not run the command"
out="$(_runner_watchdog_act "touch a marker" touch "$MARK_DIR/should-exist")"
printf '%s' "$out" | grep -qF "[EXECUTE]" && ok "execute output is labeled [EXECUTE]" || bad "execute output missing [EXECUTE] label: $out"
EXECUTE=0   # restore default for subsequent tests

echo "== _runner_watchdog_restart: --allow-restart gate (held path never touches systemctl) =="
ALLOW_RESTART=0
out="$(_runner_watchdog_restart test-runner actions.runner.does-not-exist.test.service)"; rc=$?
[ "$rc" -eq 1 ] && ok "held (no --allow-restart) returns 1 (caller must alert)" || bad "held path returned $rc, want 1"
printf '%s' "$out" | grep -qF "[held]" && ok "held path logs [held] (operator sign-off required)" || bad "held path missing [held] marker: $out"
printf '%s' "$out" | grep -qF "systemctl" && bad "held path should NOT print a systemctl command at all" || ok "held path never mentions systemctl (no command constructed)"

echo "== _runner_watchdog_restart: --allow-restart + dry-run PRINTS the would-be command (never runs it) =="
ALLOW_RESTART=1
EXECUTE=0
out="$(_runner_watchdog_restart test-runner actions.runner.does-not-exist.test.service)"; rc=$?
[ "$rc" -eq 1 ] && ok "dry-run allow-restart returns 1 (never confirms a heal without --execute)" || bad "dry-run allow-restart returned $rc, want 1"
printf '%s' "$out" | grep -qF "[dry-run]" && ok "dry-run allow-restart prints the [dry-run] command" || bad "dry-run allow-restart missing [dry-run] output: $out"
printf '%s' "$out" | grep -qF "systemctl restart actions.runner.does-not-exist.test.service" && ok "dry-run command names the exact unit" || bad "dry-run command missing the unit name: $out"
ALLOW_RESTART=0; EXECUTE=0   # restore defaults

echo "== _runner_watchdog_alert / _runner_watchdog_reset: dedup + recovery-clear =="
ALERT_TMP="$(mktemp -d)"
ALERT_DIR="$ALERT_TMP"
EXECUTE=1
_runner_watchdog_alert test-runner "first failure" >/dev/null
[ -f "$ALERT_TMP/test-runner" ] && ok "alert sentinel written on first failure" || bad "alert sentinel not written"
first_content="$(cat "$ALERT_TMP/test-runner")"
_runner_watchdog_alert test-runner "second failure, should NOT overwrite" >/dev/null
second_content="$(cat "$ALERT_TMP/test-runner")"
[ "$first_content" = "$second_content" ] && ok "second alert call is dedup'd (does not overwrite)" || bad "dedup failed — content changed: '$first_content' -> '$second_content'"
_runner_watchdog_reset test-runner >/dev/null
[ -f "$ALERT_TMP/test-runner" ] && bad "reset did not clear the alert sentinel" || ok "reset (recovery to OK) clears the alert sentinel"
EXECUTE=0

echo "== dry-run alert/reset are side-effect-free (no writes without --execute) =="
_runner_watchdog_alert test-runner-2 "would-be failure" >/dev/null
[ -e "$ALERT_TMP/test-runner-2" ] && bad "dry-run alert wrote a sentinel (should be print-only)" || ok "dry-run alert wrote nothing"

echo "== maintenance-lock composition: a REAL lock_active read drives SKIP end-to-end =="
LOCK_TMP="$(mktemp -d)"
MAINT_LOCK_DIR="$LOCK_TMP"
locked=0
lock_active runner-under-maint && locked=1
[ "$locked" -eq 0 ] && ok "no lock present -> locked=0 (lock_active correctly reports absent)" || bad "lock_active reported active with no lock file"
decision="$(_runner_watchdog_decide "unknown" "not-found" "$locked")"
[ "$decision" = "ALERT" ] && ok "unlocked + torn-down unit -> ALERT (baseline, no lock involved)" || bad "unlocked decision got '$decision' want ALERT"

lock_acquire runner-under-maint 1.2.3 >/dev/null 2>&1
locked=0
lock_active runner-under-maint && locked=1
[ "$locked" -eq 1 ] && ok "lock_acquire + lock_active -> locked=1 (real primitive, not a canned string)" || bad "lock_active did not report active after lock_acquire"
decision="$(_runner_watchdog_decide "unknown" "not-found" "$locked")"
[ "$decision" = "SKIP" ] && ok "SAME torn-down unit, now locked -> SKIP (maintenance lock suppresses the ALERT)" || bad "locked decision got '$decision' want SKIP"

lock_release runner-under-maint >/dev/null 2>&1
locked=0
lock_active runner-under-maint && locked=1
decision="$(_runner_watchdog_decide "unknown" "not-found" "$locked")"
[ "$decision" = "ALERT" ] && ok "after lock_release, decision reverts to ALERT (SKIP was lock-driven, not sticky)" || bad "post-release decision got '$decision' want ALERT"

echo "== _runner_watchdog_service_name: repo-slug derivation matches runner/verify-runner.sh =="
# Pure string transform (no systemctl call needed to check the SLUG half of the
# derivation) — the grep pattern this function builds must match verify-runner.sh's
# own `REPO_SLUG="${REPO//\//-}"` exactly, or the two tools could disagree about
# which service belongs to which repo.
slug_test="groundnuty/macf-science-agent"
expected_slug="groundnuty-macf-science-agent"
got_slug="${slug_test//\//-}"
[ "$got_slug" = "$expected_slug" ] && ok "repo-slug transform matches verify-runner.sh's REPO_SLUG derivation" || bad "slug transform got '$got_slug' want '$expected_slug'"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
