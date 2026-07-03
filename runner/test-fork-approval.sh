#!/usr/bin/env bash
# test-fork-approval.sh — offline unit tests for the fork-PR-approval precheck
# (runner/fork-pr-approval-check.sh), added alongside install-runner.sh's new
# "0. fork-PR-approval precheck" step (devops-toolkit "fork-PR-approval safety
# precheck for the self-hosted-runner deploy procedure").
#
# NO `gh` MOCKING: no existing test in this repo stubs external CLI binaries
# (test-maintenance-lock.sh / test-reconcile.sh / test-upgrade.sh /
# test-resume.sh all test pure shell logic via `source`, never CLI-call
# interception) — introducing a first-of-its-kind `gh` mock here would be
# inconsistent with the established style. Instead, fork-pr-approval-check.sh
# factors the actual security-relevant decision into a PURE function
# (_fork_approval_decide: two string args in, SKIP|PASS|FATAL out, no gh call,
# no I/O) specifically so it's testable without mocking anything. What's left
# untested here is check_fork_pr_approval's two `gh api` calls themselves —
# "did we call the right endpoint with the right creds," which is a live /
# integration concern (see fork-pr-approval-check.sh's header for the two
# verified endpoints), not a unit-test concern. The one exception is the
# override short-circuit, which is exercised for real below because it
# deliberately returns BEFORE either gh call — safe to run with no `gh` creds
# (or no `gh` binary at all) in this environment.

set -uo pipefail
cd "$(dirname "$0")/.."   # repo root
FAC=runner/fork-pr-approval-check.sh
pass=0 fail=0

ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# shellcheck source=./fork-pr-approval-check.sh
source "$FAC"

echo "== _fork_approval_decide: pure decision table (no gh call) =="

check_decision() {
  local desc="$1" vis="$2" policy="$3" want="$4" got
  got="$(_fork_approval_decide "$vis" "$policy")"
  [ "$got" = "$want" ] && ok "$desc -> $want" || bad "$desc got '$got' want '$want'"
}

# --- the 5 scenarios named in the task spec ---
check_decision "public + all_external_contributors (strictest)"            "public"   "all_external_contributors"              "PASS"
check_decision "public + first_time_contributors (weaker)"                 "public"   "first_time_contributors"                "FATAL"
check_decision "public + empty/unreadable policy"                          "public"   ""                                       "FATAL"
check_decision "private repo (fork-PR-approval N/A)"                       "private"  "all_external_contributors"              "SKIP"

# --- additional coverage beyond the 5 named scenarios ---
check_decision "public + first_time_contributors_new_to_github (weakest)"  "public"   "first_time_contributors_new_to_github"  "FATAL"
check_decision "internal repo also SKIPs"                                  "internal" ""                                       "SKIP"
check_decision "private repo SKIPs even with a weak policy (N/A regardless)" "private" "first_time_contributors"                "SKIP"
check_decision "unknown/unreadable visibility + strict policy -> conservative fall-through PASSes" "" "all_external_contributors" "PASS"
check_decision "unknown/unreadable visibility + unreadable policy -> FATAL (never silent-pass)"    "" ""                        "FATAL"

echo "== check_fork_pr_approval: MACF_RUNNER_SKIP_FORK_APPROVAL_CHECK=1 short-circuits BEFORE any gh call =="
REPO_FOR_TEST="groundnuty/does-not-matter-no-gh-call-should-happen"
out="$(MACF_RUNNER_SKIP_FORK_APPROVAL_CHECK=1 REPO="$REPO_FOR_TEST" bash -c "source $FAC; check_fork_pr_approval" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] && ok "override short-circuit returns 0 (install proceeds)" || bad "override short-circuit returned $rc, want 0"
printf '%s\n' "$out" | grep -qF "SKIPPED via override" && ok "override prints a loud warn naming the skip" || bad "override output missing the loud-warn text: $out"
printf '%s\n' "$out" | grep -qF "macf-actions#59" && ok "override warn points at the real long-term gate (macf-actions#59)" || bad "override warn missing the macf-actions#59 pointer: $out"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
