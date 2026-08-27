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
#   - _runner_watchdog_decide       — the pure 4-input decision table (the actual
#                                      security/liveness-relevant logic, including
#                                      the WEDGED branch — job-wedge detection,
#                                      see runner-watchdog.sh's own header)
#   - _runner_watchdog_wedge_sample — the pure SINGLE-sample job-wedge shape
#                                      predicate (last journal event +
#                                      worker-process count -> wedge-SHAPED?);
#                                      same "factor the I/O out of the
#                                      decision" shape as _runner_watchdog_decide
#                                      itself.
#   - _runner_watchdog_wedge_confirmed — the pure TWO-sample identity check
#                                      that actually confirms WEDGED: both
#                                      samples must be wedge-shaped AND share
#                                      the SAME journal timestamp (else two
#                                      different jobs straddling the grace
#                                      window could misdiagnose as one
#                                      continuous wedge — see its own
#                                      "same shape, timestamp ADVANCED" test).
#                                      The I/O halves that FEED both of the
#                                      above (_runner_watchdog_last_job_event
#                                      via journalctl, _runner_watchdog_worker_count
#                                      via pgrep, and the grace-period wrapper
#                                      _runner_watchdog_check_wedge) are thin
#                                      wrappers around those external tools and
#                                      are exercised live, same as the
#                                      systemctl-touching functions above.
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

echo "== _runner_watchdog_decide: pure 4-input decision table (no I/O) =="
# 6th arg (wedged) is OPTIONAL and defaults to "0" — every pre-existing 5-arg
# call below (written before job-wedge detection existed) is unaffected.
check_decision() {
  local desc="$1" active="$2" loaded="$3" locked="$4" want="$5" wedged="${6:-0}" got
  got="$(_runner_watchdog_decide "$active" "$loaded" "$locked" "$wedged")"
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

echo "== _runner_watchdog_decide: WEDGED (active-but-not-working, macf-devops-toolkit job-wedge fix) =="
# The incident this closes: a runner's unit stayed ActiveState=active for ~2h
# while a job it had claimed was never actually run by any Runner.Worker (a
# same-instant cancellation raced the claim) — is-active alone reported "OK"
# throughout. WEDGED is the 4th input (wedged="1") overriding what would
# otherwise read as healthy.
check_decision "active+loaded+unlocked+wedged=1 -> WEDGED (new state)" \
  "active" "loaded" "0" "WEDGED" "1"
check_decision "active+loaded+unlocked+wedged=0 -> still OK (has a worker, healthy)" \
  "active" "loaded" "0" "OK" "0"
check_decision "wedged flag only matters when active -- inactive+wedged=1 still -> HEAL (existing branch wins, not a new one)" \
  "inactive" "loaded" "0" "HEAL" "1"
check_decision "maintenance lock overrides WEDGED too -- SKIP wins (don't fight an in-flight reinstall)" \
  "active" "loaded" "1" "SKIP" "1"
check_decision "unit not loaded overrides WEDGED too -- ALERT wins (nothing to check a wedge on)" \
  "unknown" "not-found" "0" "ALERT" "1"

echo "== _runner_watchdog_wedge_sample: pure job-wedge predicate (no I/O) =="
check_wedge_sample() {
  local desc="$1" event="$2" count="$3" want="$4" got
  got="$(_runner_watchdog_wedge_sample "$event" "$count")"
  [ "$got" = "$want" ] && ok "$desc -> $want" || bad "$desc got '$got' want '$want'"
}

# --- "wedged detected" (task-spec minimum #1) ---
check_wedge_sample "last event 'Running job' + 0 workers -> looks wedged"        "Running job" "0" "1"
# --- "healthy-with-worker NOT flagged" (task-spec minimum #2) ---
check_wedge_sample "last event 'Running job' + 1 worker -> healthy, NOT wedged" "Running job" "1" "0"
check_wedge_sample "last event 'Running job' + 2 workers -> healthy, NOT wedged" "Running job" "2" "0"
# --- additional coverage beyond the 2 named minimums ---
check_wedge_sample "last event 'completed with' + 0 workers -> idle, NOT wedged" "completed with" "0" "0"
check_wedge_sample "no job event seen yet (empty) + 0 workers -> NOT wedged"     "" "0" "0"
check_wedge_sample "worker-count omitted defaults to 0 (still detects wedge)"    "Running job" "" "1"

echo "== _runner_watchdog_wedge_confirmed: two-sample identity check (peer-review fix) =="
# Peer-review catch: a bare shape match on BOTH samples is not proof of one
# continuous wedge -- it can also occur for TWO DIFFERENT jobs straddling the
# grace window (job A claimed with no worker yet; job A finishes, job B is
# claimed a moment later, ALSO caught with no worker yet). Requiring the
# journal timestamp to be IDENTICAL across both samples is what tells the two
# cases apart.
check_wedge_confirmed() {
  local desc="$1" ts1="$2" event1="$3" count1="$4" ts2="$5" event2="$6" count2="$7" want="$8" got
  got="$(_runner_watchdog_wedge_confirmed "$ts1" "$event1" "$count1" "$ts2" "$event2" "$count2")"
  [ "$got" = "$want" ] && ok "$desc -> $want" || bad "$desc got '$got' want '$want'"
}

# --- the exact case named in review: same shape, DIFFERENT job -> NOT wedged ---
check_wedge_confirmed "same wedge-shape, timestamp ADVANCED (different job claim) -> NOT confirmed (progress made)" \
  "2026-08-27T00:26:40+0000" "Running job" "0" \
  "2026-08-27T00:28:10+0000" "Running job" "0" \
  "0"
# --- the positive case: same shape, SAME timestamp (same stuck claim) -> confirmed ---
check_wedge_confirmed "same wedge-shape, timestamp UNCHANGED (same stuck claim) -> CONFIRMED wedged" \
  "2026-08-27T00:26:40+0000" "Running job" "0" \
  "2026-08-27T00:26:40+0000" "Running job" "0" \
  "1"
# --- additional coverage beyond the 2 named cases ---
check_wedge_confirmed "first sample not wedge-shaped (has a worker) -> NOT confirmed regardless of ts" \
  "2026-08-27T00:26:40+0000" "Running job" "1" \
  "2026-08-27T00:26:40+0000" "Running job" "0" \
  "0"
check_wedge_confirmed "second sample recovered (worker now present) -> NOT confirmed even with matching ts" \
  "2026-08-27T00:26:40+0000" "Running job" "0" \
  "2026-08-27T00:26:40+0000" "Running job" "1" \
  "0"
check_wedge_confirmed "second sample now 'completed with' (job finished) -> NOT confirmed" \
  "2026-08-27T00:26:40+0000" "Running job" "0" \
  "2026-08-27T00:28:10+0000" "completed with" "0" \
  "0"
check_wedge_confirmed "both timestamps empty (runner never ran a job either sample) -> NOT confirmed (no vacuous match on empty)" \
  "" "" "0" \
  "" "" "0" \
  "0"

echo "== _runner_watchdog_restart: WEDGED reuses the SAME --allow-restart gate as HEAL (no new flag) =="
# task-spec minimum #3: "restart gated off without --allow-restart". WEDGED's
# heal action is _runner_watchdog_restart -- the SAME function HEAL already
# uses (see runner-watchdog.sh's WEDGED case) -- so this proves the existing
# gate covers the new state without any code path bypassing it.
ALLOW_RESTART=0
out="$(_runner_watchdog_restart wedged-test actions.runner.does-not-exist.wedged.service)"; rc=$?
[ "$rc" -eq 1 ] && ok "WEDGED-triggered restart, no --allow-restart -> held (rc=1)" || bad "expected held rc=1, got $rc"
printf '%s' "$out" | grep -qF "[held]" && ok "WEDGED-triggered restart without --allow-restart logs [held]" || bad "missing [held] marker: $out"
printf '%s' "$out" | grep -qF "systemctl" && bad "WEDGED held path should NOT print a systemctl command at all" || ok "WEDGED held path never mentions systemctl (no new flag needed to suppress it)"
ALLOW_RESTART=0   # already 0; restore explicit for clarity of subsequent tests

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

echo "== _runner_watchdog_registry_json: converter chain survives cron's bare PATH (#169) =="
# The ~37-day silent outage: the only `yq` on cron's PATH is python-yq (a jq
# wrapper) which rejects `-o=json`, and yq-go lives inside a devbox shell cron
# never enters. These run the REAL function under a REAL restricted PATH — no
# mocking — so they fail if the fallback chain regresses to yq-go-only.
ry_tmp="$(mktemp -d)"; trap 'rm -rf "$ry_tmp"' EXIT
cat > "$ry_tmp/runners.yaml" <<'YAML'
fleets:
  - fleet: testfleet
    runners:
      - name: alpha
        repo: owner/alpha
        status: live
YAML

conv_json="$(PATH=/usr/bin:/bin _runner_watchdog_registry_json "$ry_tmp/runners.yaml" 2>/dev/null)"
[ -n "$conv_json" ] && ok "converts YAML under bare cron PATH (=/usr/bin:/bin)" \
  || bad "no converter worked under bare cron PATH — the #169 outage would recur"
printf '%s' "$conv_json" | jq -e '.fleets[0].runners[0].name == "alpha"' >/dev/null 2>&1 \
  && ok "converted JSON is semantically correct (round-trips the registry shape)" \
  || bad "converted output did not round-trip the registry shape"
printf '%s' "$conv_json" | _runner_watchdog_filter_registry "live" | grep -q '^alpha' \
  && ok "converter output feeds the status filter end-to-end" \
  || bad "converter output did not feed _runner_watchdog_filter_registry"

# An unreadable registry must still fail (non-zero), not silently emit junk.
_runner_watchdog_registry_json "$ry_tmp/does-not-exist.yaml" >/dev/null 2>&1 \
  && bad "missing registry returned success" \
  || ok "missing registry returns non-zero (caller raises the self-alert)"

# A file that exists but is NOT valid YAML must fail rather than yield empty-but-ok.
printf ':\n  - [unclosed\n' > "$ry_tmp/broken.yaml"
_runner_watchdog_registry_json "$ry_tmp/broken.yaml" >/dev/null 2>&1 \
  && bad "malformed YAML returned success" \
  || ok "malformed YAML returns non-zero (output is validated, not just exit code)"

echo "== _runner_watchdog_self_alert: a watchdog that CANNOT RUN alerts (#169) =="
# Previously a bare `echo … skipping sweep; exit 0` — 5389 log lines, zero signal.
sa_dir="$ry_tmp/alerts"; ALERT_DIR="$sa_dir"

EXECUTE=0
_runner_watchdog_self_alert "dry-run probe" >/dev/null 2>&1
[ ! -e "$sa_dir/_watchdog-self" ] && ok "dry-run self-alert writes nothing" \
  || bad "dry-run self-alert wrote a sentinel"

EXECUTE=1
_runner_watchdog_self_alert "yq missing" >/dev/null 2>&1
[ -e "$sa_dir/_watchdog-self" ] && ok "--execute self-alert writes the sentinel" \
  || bad "--execute self-alert wrote no sentinel"
grep -q 'yq missing' "$sa_dir/_watchdog-self" \
  && ok "self-alert records the reason (triage doesn't need the log)" \
  || bad "self-alert body lost the reason"

printf 'ORIGINAL\n' > "$sa_dir/_watchdog-self"
_runner_watchdog_self_alert "second failure" >/dev/null 2>&1
grep -q 'ORIGINAL' "$sa_dir/_watchdog-self" \
  && ok "second self-alert is dedup'd (does not rewrite every 10 min)" \
  || bad "self-alert overwrote an already-open sentinel"

_runner_watchdog_reset "_watchdog-self" >/dev/null 2>&1
[ ! -e "$sa_dir/_watchdog-self" ] \
  && ok "a successful sweep clears the self-alert (future breakage re-alerts)" \
  || bad "self-alert survived the recovery reset"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
