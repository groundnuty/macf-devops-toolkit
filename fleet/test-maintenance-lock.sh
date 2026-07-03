#!/usr/bin/env bash
#
# test-maintenance-lock.sh — offline unit + integration tests for the DR-040
# Decision-4 maintenance-lock primitive (macf-devops-toolkit#158):
#   - the library itself (fleet/maintenance-lock.sh): acquire→active, heartbeat
#     keeps it active, release→inactive, a stale-heartbeat lock reads inactive,
#     a malformed lock reads inactive (fail-toward-resuming-keep-alive).
#   - the READ-side integration (fleet/reconcile.sh): a locked-down agent is
#     SKIPped (not relaunched); an unlocked-down agent is still LAUNCHed exactly
#     as before (the primitive must not change baseline behaviour).
#
# Pure-offline: everything runs against a temp MAINT_LOCK_DIR, canned fleet-
# doctor fixtures via --fleet-json, and reconcile.sh's other action paths stay
# in dry-run (no real tmux/launches). Run: ./fleet/test-maintenance-lock.sh.

set -uo pipefail
cd "$(dirname "$0")/.."   # repo root
LOCKLIB=fleet/maintenance-lock.sh
REC=fleet/reconcile.sh
MAN=fleet/desired-agents.example.yaml
FX=fleet/testdata
pass=0 fail=0

ok()   { echo "  ok: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "== library: lock_acquire -> lock_active (fresh lock reads ACTIVE) =="
LD1="$(mktemp -d)"
( MACF_MAINT_LOCK_DIR="$LD1" bash -c "
    source $LOCKLIB
    lock_acquire agent-a 1.2.3 >/dev/null 2>&1
    lock_active agent-a
  " )
if [ $? -eq 0 ]; then ok "fresh lock is ACTIVE"; else bad "fresh lock should be ACTIVE"; fi

echo "== library: lock file schema (schema_version/agent/target_version/started_at/heartbeat_at) =="
LOCKFILE="$LD1/agent-a.lock"
if [ -f "$LOCKFILE" ]; then
  got_schema="$(jq -r '.schema_version' "$LOCKFILE")"
  got_agent="$(jq -r '.agent' "$LOCKFILE")"
  got_target="$(jq -r '.target_version' "$LOCKFILE")"
  got_started="$(jq -r '.started_at' "$LOCKFILE")"
  got_hb="$(jq -r '.heartbeat_at' "$LOCKFILE")"
  [ "$got_schema" = "1" ] && ok "schema_version == 1" || bad "schema_version got '$got_schema' want 1"
  [ "$got_agent" = "agent-a" ] && ok "agent == agent-a" || bad "agent got '$got_agent'"
  [ "$got_target" = "1.2.3" ] && ok "target_version == 1.2.3" || bad "target_version got '$got_target'"
  case "$got_started" in ''|*[!0-9]*) bad "started_at not numeric: '$got_started'" ;; *) ok "started_at is numeric epoch ($got_started)" ;; esac
  [ "$got_started" = "$got_hb" ] && ok "heartbeat_at == started_at on fresh acquire" || bad "heartbeat_at ($got_hb) != started_at ($got_started) on fresh acquire"
else
  bad "lock file not created at $LOCKFILE"
fi

echo "== library: lock_heartbeat refreshes heartbeat_at + keeps the lock ACTIVE =="
LD2="$(mktemp -d)"
( MACF_MAINT_LOCK_DIR="$LD2" bash -c "
    source $LOCKLIB
    lock_acquire agent-b 2.0.0 >/dev/null 2>&1
  " )
# back-date heartbeat_at so we can OBSERVE the heartbeat actually advances it
BACKDATED=$(( $(date +%s) - 100 ))
jq --argjson hb "$BACKDATED" '.heartbeat_at=$hb' "$LD2/agent-b.lock" > "$LD2/agent-b.lock.tmp" && mv "$LD2/agent-b.lock.tmp" "$LD2/agent-b.lock"
pre_hb="$(jq -r '.heartbeat_at' "$LD2/agent-b.lock")"
( MACF_MAINT_LOCK_DIR="$LD2" bash -c "source $LOCKLIB; lock_heartbeat agent-b >/dev/null 2>&1" )
post_hb="$(jq -r '.heartbeat_at' "$LD2/agent-b.lock")"
if [ "$post_hb" -gt "$pre_hb" ]; then ok "lock_heartbeat advanced heartbeat_at ($pre_hb -> $post_hb)"; else bad "heartbeat_at did not advance ($pre_hb -> $post_hb)"; fi
post_target="$(jq -r '.target_version' "$LD2/agent-b.lock")"
[ "$post_target" = "2.0.0" ] && ok "lock_heartbeat preserves target_version" || bad "target_version drifted to '$post_target'"
( MACF_MAINT_LOCK_DIR="$LD2" bash -c "source $LOCKLIB; lock_active agent-b" )
if [ $? -eq 0 ]; then ok "heartbeated lock stays ACTIVE"; else bad "heartbeated lock should stay ACTIVE"; fi

echo "== library: lock_heartbeat on a NON-EXISTENT lock is a no-op (does not create one) =="
LD3="$(mktemp -d)"
( MACF_MAINT_LOCK_DIR="$LD3" bash -c "source $LOCKLIB; lock_heartbeat agent-ghost" >/dev/null 2>&1 )
if [ $? -ne 0 ] && [ ! -e "$LD3/agent-ghost.lock" ]; then ok "heartbeat on absent lock fails + creates nothing"; else bad "heartbeat on absent lock should fail without creating a file"; fi

echo "== library: lock_release -> lock_active reads INACTIVE =="
LD4="$(mktemp -d)"
( MACF_MAINT_LOCK_DIR="$LD4" bash -c "source $LOCKLIB; lock_acquire agent-c 3.0.0 >/dev/null 2>&1" )
( MACF_MAINT_LOCK_DIR="$LD4" bash -c "source $LOCKLIB; lock_active agent-c" )
[ $? -eq 0 ] && ok "lock is ACTIVE before release" || bad "lock should be ACTIVE before release"
( MACF_MAINT_LOCK_DIR="$LD4" bash -c "source $LOCKLIB; lock_release agent-c >/dev/null 2>&1" )
[ -e "$LD4/agent-c.lock" ] && bad "lock file still present after release" || ok "lock file removed by release"
( MACF_MAINT_LOCK_DIR="$LD4" bash -c "source $LOCKLIB; lock_active agent-c" )
if [ $? -ne 0 ]; then ok "released lock reads INACTIVE"; else bad "released lock should read INACTIVE"; fi
( MACF_MAINT_LOCK_DIR="$LD4" bash -c "source $LOCKLIB; lock_release agent-c" >/dev/null 2>&1 )
if [ $? -eq 0 ]; then ok "lock_release is idempotent (no-op on already-absent lock)"; else bad "lock_release should be idempotent"; fi

echo "== library: a STALE-heartbeat lock reads INACTIVE (TTL expiry) =="
LD5="$(mktemp -d)"
( MACF_MAINT_LOCK_DIR="$LD5" MACF_MAINT_LOCK_TTL=60 bash -c "source $LOCKLIB; lock_acquire agent-d 4.0.0 >/dev/null 2>&1" )
# heartbeat_at far in the past — older than a 60s TTL
STALE=$(( $(date +%s) - 3600 ))
jq --argjson hb "$STALE" '.heartbeat_at=$hb' "$LD5/agent-d.lock" > "$LD5/agent-d.lock.tmp" && mv "$LD5/agent-d.lock.tmp" "$LD5/agent-d.lock"
( MACF_MAINT_LOCK_DIR="$LD5" MACF_MAINT_LOCK_TTL=60 bash -c "source $LOCKLIB; lock_active agent-d" )
if [ $? -ne 0 ]; then ok "stale-heartbeat lock (age 3600s > ttl 60s) reads INACTIVE"; else bad "stale lock should read INACTIVE"; fi
# a heartbeat still WELL within a larger TTL reads ACTIVE (sanity: not just "always inactive")
( MACF_MAINT_LOCK_DIR="$LD5" MACF_MAINT_LOCK_TTL=7200 bash -c "source $LOCKLIB; lock_active agent-d" )
if [ $? -eq 0 ]; then ok "same lock reads ACTIVE under a larger TTL (7200s > 3600s age)"; else bad "should read ACTIVE under a larger TTL"; fi

echo "== library: a MALFORMED lock (missing/non-numeric heartbeat_at) reads INACTIVE =="
LD6="$(mktemp -d)"; mkdir -p "$LD6"
printf '{"schema_version":1,"agent":"agent-e","target_version":"5.0.0","started_at":123}' > "$LD6/agent-e.lock"
( MACF_MAINT_LOCK_DIR="$LD6" bash -c "source $LOCKLIB; lock_active agent-e" )
if [ $? -ne 0 ]; then ok "lock with missing heartbeat_at reads INACTIVE (fail-toward-resume)"; else bad "missing-heartbeat lock should read INACTIVE"; fi
printf 'not even json' > "$LD6/agent-f.lock"
( MACF_MAINT_LOCK_DIR="$LD6" bash -c "source $LOCKLIB; lock_active agent-f" )
if [ $? -ne 0 ]; then ok "non-JSON lock file reads INACTIVE (fail-toward-resume)"; else bad "corrupt lock should read INACTIVE"; fi

echo "== library: lock_heartbeat_loop dead-man's-switch (max-iters bounds the loop) =="
LD7="$(mktemp -d)"
( MACF_MAINT_LOCK_DIR="$LD7" bash -c "
    source $LOCKLIB
    lock_acquire agent-g 6.0.0 >/dev/null 2>&1
    lock_heartbeat_loop agent-g 1 2   # 1s interval, 2 iterations -> ~2s then self-exits
  " ) &
LOOP_PID=$!
sleep 4
if kill -0 "$LOOP_PID" 2>/dev/null; then
  bad "heartbeat_loop with max-iters=2 still running after 4s (dead-man's-switch failed)"
  kill "$LOOP_PID" 2>/dev/null || true
else
  ok "heartbeat_loop with max-iters=2 self-terminated (dead-man's-switch works)"
fi
hb_count_lock="$LD7/agent-g.lock"
if [ -f "$hb_count_lock" ]; then ok "bounded loop still refreshed the lock at least once"; else bad "bounded loop never wrote the lock"; fi

echo "== reconcile.sh integration: locked-down agent is SKIPped, unlocked-down agent still LAUNCHes =="
PAUSED="$(mktemp -d)"; LASTEXIT="$(mktemp -d)"; LOCKDIR="$(mktemp -d)"
BASE=(--manifest "$MAN" --paused-dir "$PAUSED" --last-exit-dir "$LASTEXIT" --maint-lock-dir "$LOCKDIR")
export MACF_TEST_BUSY=""

# fleet-degraded.json: devops-agent is PRESENT-but-unreachable (reachable=false,
# accepted=false) -> HEAL (deaf-channel-down), same as test-reconcile.sh's baseline.
# code-agent is ABSENT from the fixture entirely -> LAUNCH (cold-start). Both are
# "down" in the operator sense; they exercise the two different reconcile branches
# the maintenance-lock must suppress (spec's literal ask: "SKIPS a locked-down
# agent but RELAUNCHES an unlocked-down one" = the LAUNCH branch via code-agent;
# devops-agent additionally proves the lock ALSO suppresses the HEAL ladder, a
# deliberate widening beyond the literal ask — see maintenance-lock design notes).
base_out="$("$REC" "${BASE[@]}" --fleet-json "$FX/fleet-degraded.json" 2>&1)"
base_launch="$(printf '%s\n' "$base_out" | awk '$1=="code-agent"{print $2; exit}')"
base_heal="$(printf '%s\n' "$base_out" | awk '$1=="devops-agent"{print $2; exit}')"
[ "$base_launch" = "LAUNCH" ] && ok "baseline (no lock): code-agent (absent) -> LAUNCH" || bad "baseline code-agent got '$base_launch' want LAUNCH"
[ "$base_heal" = "HEAL" ] && ok "baseline (no lock): devops-agent (present, unreachable) -> HEAL" || bad "baseline devops-agent got '$base_heal' want HEAL"

# acquire ACTIVE locks for BOTH -> reconcile must SKIP both, not LAUNCH/HEAL them.
( MACF_MAINT_LOCK_DIR="$LOCKDIR" bash -c "source $LOCKLIB; lock_acquire code-agent 9.9.9 >/dev/null 2>&1; lock_acquire devops-agent 9.9.9 >/dev/null 2>&1" )
locked_out="$("$REC" "${BASE[@]}" --fleet-json "$FX/fleet-degraded.json" 2>&1)"
locked_launch="$(printf '%s\n' "$locked_out" | awk '$1=="code-agent"{print $2; exit}')"
locked_heal="$(printf '%s\n' "$locked_out" | awk '$1=="devops-agent"{print $2; exit}')"
[ "$locked_launch" = "SKIP" ] && ok "locked code-agent (was LAUNCH) -> SKIP (not relaunched)" || bad "locked code-agent got '$locked_launch' want SKIP"
[ "$locked_heal" = "SKIP" ] && ok "locked devops-agent (was HEAL) -> SKIP (not healed either)" || bad "locked devops-agent got '$locked_heal' want SKIP"
if printf '%s\n' "$locked_out" | grep -qF "maintenance lock active"; then ok "SKIP line names the maintenance lock"; else bad "SKIP line missing the maintenance-lock label"; fi
if printf '%s\n' "$locked_out" | grep -qF "tmux new-session -d -s macf@code-agent"; then
  bad "locked agent's launch command was still constructed (lock did not suppress it)"
else
  ok "no LAUNCH command constructed for the locked agent"
fi
# a THIRD, unlocked desired agent is unaffected by the other two agents' locks
# (per-agent scoping, not a global freeze).
science_decision="$(printf '%s\n' "$locked_out" | awk '$1=="science-agent"{print $2; exit}')"
if [ "$science_decision" = "HEAL" ]; then ok "science-agent (unlocked, reachable-not-accepted) still HEALs normally"; else bad "science-agent decision got '$science_decision' want HEAL"; fi

# release code-agent's lock -> reconcile goes back to LAUNCHing it (proves SKIP was
# lock-driven, not some other side-effect of the fixture/flags); devops-agent stays
# locked+SKIPped (per-agent — releasing one lock doesn't touch the other).
( MACF_MAINT_LOCK_DIR="$LOCKDIR" bash -c "source $LOCKLIB; lock_release code-agent >/dev/null 2>&1" )
released_out="$("$REC" "${BASE[@]}" --fleet-json "$FX/fleet-degraded.json" 2>&1)"
released_decision="$(printf '%s\n' "$released_out" | awk '$1=="code-agent"{print $2; exit}')"
still_locked="$(printf '%s\n' "$released_out" | awk '$1=="devops-agent"{print $2; exit}')"
[ "$released_decision" = "LAUNCH" ] && ok "after lock_release, code-agent -> LAUNCH again" || bad "post-release code-agent got '$released_decision' want LAUNCH"
[ "$still_locked" = "SKIP" ] && ok "devops-agent's SEPARATE lock is unaffected by code-agent's release" || bad "devops-agent got '$still_locked' want still-SKIP"

# a STALE lock (heartbeat older than TTL) must ALSO not block relaunch — proves the
# watchdog self-frees from a crashed upgrade without a manual unlock.
( MACF_MAINT_LOCK_DIR="$LOCKDIR" bash -c "source $LOCKLIB; lock_acquire code-agent 9.9.9 >/dev/null 2>&1" )
STALE_HB=$(( $(date +%s) - 999999 ))
jq --argjson hb "$STALE_HB" '.heartbeat_at=$hb' "$LOCKDIR/code-agent.lock" > "$LOCKDIR/code-agent.lock.tmp" && mv "$LOCKDIR/code-agent.lock.tmp" "$LOCKDIR/code-agent.lock"
stale_decision="$("$REC" "${BASE[@]}" --fleet-json "$FX/fleet-degraded.json" 2>&1 | awk '$1=="code-agent"{print $2; exit}')"
if [ "$stale_decision" = "LAUNCH" ]; then ok "STALE-heartbeat lock does NOT block relaunch (crash-safety self-free)"; else bad "stale-locked decision got '$stale_decision' want LAUNCH"; fi

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
