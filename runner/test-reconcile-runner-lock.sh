#!/usr/bin/env bash
#
# test-reconcile-runner-lock.sh — the maintenance-lock lifecycle around a runner
# reinstall (macf-devops-toolkit#165).
#
# Same discipline as the sibling suites: no mocking of sudo/systemctl. The install
# path itself needs root and a live GitHub registration, so it is exercised in the
# PR's "Verify" step against the real host. What IS testable offline, and is where
# the actual risk lives:
#
#   - the lock is acquired BEFORE anything destructive, and released ONLY on a
#     green post-install verify (ordering in the source — a future edit that moves
#     the release above the verify would silently reopen the window)
#   - a HALTED reinstall LEAVES the lock (TTL frees it) rather than releasing it,
#     per DR-040 Decision 4 — releasing on failure would hand a half-torn-down
#     runner back as "fine"
#   - the paths that don't install (--verify-only) take no lock at all
#   - end-to-end: a lock held under the runner's NAME actually makes
#     runner-watchdog.sh decide SKIP for a torn-down unit (the whole point)
#
# Run: ./runner/test-reconcile-runner-lock.sh

set -uo pipefail
cd "$(dirname "$0")/.."   # repo root
RR=runner/reconcile-runner.sh
pass=0 fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "== lock ORDERING: acquire before teardown, release only after verify =="
ln_acquire=$(grep -n 'lock_acquire "\$NAME"' "$RR" | head -1 | cut -d: -f1)
# match the INVOCATION (it passes --repo), not the header comment that merely
# names the script — an over-loose grep here made this assertion compare against
# a comment on line 49 and report a phantom failure.
ln_uninst=$(grep -n 'uninstall-runner\.sh --repo' "$RR" | head -1 | cut -d: -f1)
ln_install=$(grep -n 'install-runner\.sh --repo' "$RR" | tail -1 | cut -d: -f1)
# The POST-INSTALL verify specifically. `head -1` matched the EARLY health-check
# gate instead (the one inside the non---force branch), making the release-ordering
# comparison trivially true — it passed even with a release injected right before
# the real verify. Match the exact post-install form: no output redirect.
ln_verify=$(grep -n 'if \./verify-runner\.sh --repo "\$REPO"; then' "$RR" | tail -1 | cut -d: -f1)
# FIRST call-site (excluding the function definition). Must be `tail`-free: an
# assertion on the LAST occurrence passes even when an EXTRA release is added
# before the verify — which is precisely the regression this guards against, and
# is exactly how this assertion first failed its own negative control.
ln_release=$(grep -n '_lock_cleanup_release' "$RR" | grep -v '_lock_cleanup_release()' | head -1 | cut -d: -f1)

[ -n "$ln_acquire" ] && [ -n "$ln_uninst" ] && [ "$ln_acquire" -lt "$ln_uninst" ] \
  && ok "lock_acquire precedes uninstall-runner.sh (teardown never runs unlocked)" \
  || bad "lock_acquire ($ln_acquire) does not precede uninstall ($ln_uninst)"
[ "$ln_acquire" -lt "$ln_install" ] \
  && ok "lock is held across the install window too" \
  || bad "lock acquired after install-runner.sh"
[ "$ln_release" -gt "$ln_verify" ] \
  && ok "release happens only AFTER the post-install verify (not before)" \
  || bad "release ($ln_release) is not after the verify ($ln_verify)"

echo "== HALT semantics: the trap stops the heartbeat but must NOT release =="
# DR-040 Decision 4: a halted reinstall leaves the lock; its TTL frees it. If the
# trap released, an interrupted teardown would immediately un-SKIP the watchdog.
trap_line="$(grep -n 'trap .* EXIT INT TERM' "$RR" | head -1)"
printf '%s' "$trap_line" | grep -q '_lock_cleanup_keep' \
  && ok "trap uses _lock_cleanup_keep (leaves the lock on halt)" \
  || bad "trap does not use the keep-variant: $trap_line"
printf '%s' "$trap_line" | grep -q '_lock_cleanup_release' \
  && bad "trap RELEASES on halt — a crashed reinstall would look healthy" \
  || ok "trap does not release on halt"
# the keep-variant must not call lock_release, even transitively
sed -n "/^_lock_cleanup_keep()/,/^}/p" "$RR" | grep -q 'lock_release' \
  && bad "_lock_cleanup_keep calls lock_release" \
  || ok "_lock_cleanup_keep never calls lock_release"

echo "== --verify-only takes NO lock (non-installing paths stay lock-free) =="
LOCKDIR="$(mktemp -d)/locks"
MACF_MAINT_LOCK_DIR="$LOCKDIR" MACF_RUNNERS_YAML=runner/runners.yaml \
  bash "$RR" --name macf-devops-toolkit --verify-only >/dev/null 2>&1
[ ! -e "$LOCKDIR/macf-devops-toolkit.lock" ] \
  && ok "--verify-only leaves no lock behind" \
  || bad "--verify-only acquired a maintenance-lock"

echo "== end-to-end: a reinstall-held lock makes the watchdog SKIP that runner =="
# The actual AC — uses the REAL primitives on both sides (lock_acquire from
# maintenance-lock.sh, _runner_watchdog_decide from runner-watchdog.sh), keyed on
# the runner NAME exactly as reconcile-runner.sh keys it.
export MACF_MAINT_LOCK_DIR="$LOCKDIR"
# shellcheck source=../fleet/maintenance-lock.sh
. fleet/maintenance-lock.sh
# shellcheck source=../fleet/runner-watchdog.sh
. fleet/runner-watchdog.sh

locked=0; lock_active reinstall-victim && locked=1
d="$(_runner_watchdog_decide "unknown" "not-found" "$locked")"
[ "$d" = "ALERT" ] && ok "baseline: torn-down unit, no lock -> ALERT" || bad "baseline got '$d' want ALERT"

lock_acquire reinstall-victim "reinstall" >/dev/null 2>&1
locked=0; lock_active reinstall-victim && locked=1
d="$(_runner_watchdog_decide "unknown" "not-found" "$locked")"
[ "$d" = "SKIP" ] && ok "same torn-down unit during a locked reinstall -> SKIP (no transient ALERT)" \
  || bad "locked reinstall got '$d' want SKIP"

lock_release reinstall-victim >/dev/null 2>&1
locked=0; lock_active reinstall-victim && locked=1
d="$(_runner_watchdog_decide "unknown" "not-found" "$locked")"
[ "$d" = "ALERT" ] && ok "after release, a still-broken runner ALERTs again (SKIP wasn't sticky)" \
  || bad "post-release got '$d' want ALERT"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
