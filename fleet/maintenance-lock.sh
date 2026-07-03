#!/usr/bin/env bash
#
# maintenance-lock.sh — the DR-040 Decision-4 MAINTENANCE-LOCK primitive:
# "upgrade ≠ outage". A durable, heartbeat-refreshed, crash-safe lock that tells
# the DR-006 watchdog "this agent is intentionally down for a planned upgrade —
# do NOT relaunch it." SOURCED by both:
#   - fleet/upgrade.sh   — SETS the lock around its stop→restart→verify window.
#   - fleet/reconcile.sh — READS the lock before taking ANY watchdog action.
#
# THE CONTRACT (portable across drivers — DR-006/DR-007's decision/driver split
# applied to locking, macf-devops-toolkit#158):
#
#   lock_acquire   <agent> <target-version>   create/overwrite (atomic write)
#   lock_heartbeat <agent>                    refresh heartbeat_at (no-op if absent)
#   lock_release   <agent>                    remove the lock
#   lock_active    <agent>                    exit 0 iff a lock exists AND its
#                                              heartbeat is within MAINT_LOCK_TTL —
#                                              a stale/crashed lock reads INACTIVE,
#                                              so the watchdog self-frees automatically
#   lock_info      <agent>                    one-line human-readable summary (logs)
#   lock_heartbeat_loop <agent> [interval] [max-iters]
#                                              background refresher (see below)
#
# VM DRIVER (this file): one lock FILE per agent under $MAINT_LOCK_DIR (default
# $HOME/.macf/maintenance-locks/<agent>.lock — mirrors the EXISTING fleet-central
# per-agent state convention already used for every other piece of watchdog state
# in this directory: PAUSED_DIR, LAST_EXIT_DIR, STATE_DIR, ALERT_DIR, SESSION_BACKUP_DIR
# (see reconcile.sh / resume.sh / upgrade.sh) — none of those live in the agent's
# OWN workspace either, and none are git-tracked (they're under the operator's
# $HOME, outside any repo checkout). Schema (JSON):
#
#   {"schema_version":1,"agent":"<kebab-routing-label>","target_version":"<ver>",
#    "started_at":<unix-epoch-seconds>,"heartbeat_at":<unix-epoch-seconds>}
#
# Timestamps are UNIX EPOCH SECONDS (integers), not ISO8601 — deliberately, to
# avoid the GNU-date-vs-BSD-date parsing divergence (`date -d` vs `date -j -f`)
# that already forced workarounds elsewhere in fleet/ (see upgrade.sh's
# stat -c%s / stat -f%z fallback pattern). Epoch seconds are portable, trivially
# jq-comparable, and match reconcile.sh's own emit_watchdog_metric() convention.
#
# K8S DRIVER (future, NOT implemented here — DR-007's decision/driver split):
# same four-verb contract, backed by a pod annotation (e.g.
# `macf.groundnuty.io/maintenance-lock: '<the same JSON blob>'`) or a small
# per-agent ConfigMap — whichever the future macf-operator's reconcile loop can
# read/write atomically via the K8s API (a single `kubectl patch` / API `Patch`
# call IS the K8s atomicity primitive; no temp-file+mv dance needed there, same
# way DR-007 notes the K8s upgrade-driver doesn't need /proc or tmux). Left as
# an interface note, not a stub, per the task scope (macf-devops-toolkit#158).
#
# CRASH-SAFETY MODEL (the whole point of the primitive):
#   - lock_acquire ATOMIC-WRITES (tempfile in the same dir + best-effort fsync +
#     `mv -f`) so a watchdog tick racing an in-progress write always sees either
#     the OLD complete file or the NEW complete file — never a half-written JSON.
#   - The TTL is the backstop, not lock_release, for anything that goes wrong:
#     a crashed/killed upgrade.sh stops heartbeating → lock_active() goes stale
#     within MAINT_LOCK_TTL → the watchdog resumes keep-alive on its own, no
#     manual unlock required.
#   - lock_release is a POLICY decision made by the CALLER, not this library —
#     see fleet/upgrade.sh's own comments: it releases ONLY on a confirmed clean
#     roll (DR-040 Decision 3, transactional halt). A halted/interrupted roll
#     deliberately LEAVES the lock in place (a bounded operator-grace window)
#     rather than instantly handing a possibly-broken agent back to the
#     watchdog's Tier-1/2/3 healing ladder.
#
# This file does NOT `set -e`/`-u`/`-o pipefail` — it is sourced into callers
# that already set their own shell options (reconcile.sh / upgrade.sh both use
# `set -euo pipefail`; test-maintenance-lock.sh deliberately does NOT, to keep
# testing after a failed assertion — see its header). Every function below is
# written defensively (separate `local` + assignment, so a failing command
# substitution doesn't get masked by `local`'s own exit status — the same
# footgun documented in gh-token-attribution-traps.md's export-mask note).
#
# Refs: design/DR-006-vm-cron-watchdog-agent-supervision-impl.md (watchdog);
#       design/DR-007-fleet-upgrade-orchestration.md (decision/driver split);
#       DR-040 Decision 3 (transactional halt) + Decision 4 (maintenance-lock);
#       macf-devops-toolkit#158.

MAINT_LOCK_DIR="${MACF_MAINT_LOCK_DIR:-$HOME/.macf/maintenance-locks}"
# TTL sized against the watchdog's OWN cron cadence (install-cron.sh default:
# */10 * * * * = 600s): 900s gives a 1.5x margin so ordinary cron jitter never
# reads a live-but-momentarily-quiet lock as stale, while still bounding how
# long a CRASHED upgrade can keep an agent shielded from healing to ~15 minutes.
MAINT_LOCK_TTL="${MACF_MAINT_LOCK_TTL:-900}"
# Heartbeat every ~TTL/3 (default 300s = 5min): even a single missed/delayed
# tick still lands a fresh heartbeat well inside the TTL window before the next
# cron sweep (10min) could observe staleness.
MAINT_LOCK_HEARTBEAT_INTERVAL="${MACF_MAINT_LOCK_HEARTBEAT_INTERVAL:-$((MAINT_LOCK_TTL/3))}"
# Dead-man's-switch on the background heartbeat LOOP itself (not the lock TTL):
# if the loop's parent process is ever SIGKILL'd (uncatchable — no trap can stop
# it), the loop would otherwise survive as an orphan and refresh the lock
# forever. Bounding its own total lifetime (default 3600s = 1h — far beyond any
# plausible single-agent roll_one() duration) guarantees a hard upper bound on
# total exposure: max-heartbeat-lifetime + TTL. 0 disables the bound (not
# recommended; kept only as an escape hatch).
MAINT_LOCK_HEARTBEAT_MAX_S="${MACF_MAINT_LOCK_HEARTBEAT_MAX_S:-3600}"

_maint_lock_file() { printf '%s/%s.lock' "$MAINT_LOCK_DIR" "$1"; }

# _maint_lock_write <agent> <target> <started_epoch> <heartbeat_epoch> — the
# shared ATOMIC-WRITE primitive behind lock_acquire + lock_heartbeat: write to a
# tempfile IN THE SAME DIRECTORY (guarantees `mv` is same-filesystem => atomic),
# best-effort fsync, then `mv -f`. A reader (lock_active/lock_info) racing this
# always sees a complete file, pre- or post-mv, never a partial write.
_maint_lock_write() {
  local agent="$1" target="$2" started="$3" hb="$4" lockfile tmp
  lockfile="$(_maint_lock_file "$agent")"
  mkdir -p "$MAINT_LOCK_DIR" || return 1
  tmp="$(mktemp "$MAINT_LOCK_DIR/.${agent}.lock.XXXXXX" 2>/dev/null)" || {
    echo "maintenance-lock: mktemp failed for $agent (dir: $MAINT_LOCK_DIR)" >&2; return 1; }
  if ! jq -n --arg agent "$agent" --arg target "$target" \
        --argjson started "$started" --argjson hb "$hb" \
        '{schema_version:1, agent:$agent, target_version:$target,
          started_at:$started, heartbeat_at:$hb}' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "maintenance-lock: jq write failed for $agent" >&2; return 1
  fi
  # Best-effort fsync: GNU `sync FILE` (coreutils ≥8.24) syncs just that file;
  # BSD/macOS `sync` takes no file args at all. Try per-file first, fall back to
  # a global sync, then give up silently — a missed fsync narrows (does not
  # remove) the atomicity guarantee, and is not worth failing the whole upgrade.
  sync "$tmp" 2>/dev/null || sync 2>/dev/null || true
  mv -f "$tmp" "$lockfile"
}

# lock_acquire <agent> <target-version> — create/overwrite the lock, started_at
# AND heartbeat_at both set to now.
lock_acquire() {
  local agent="$1" target="${2:-unknown}" now
  now="$(date +%s)"
  _maint_lock_write "$agent" "$target" "$now" "$now" || return 1
  echo "maintenance-lock: ACQUIRED for $agent (target=$target, ttl=${MAINT_LOCK_TTL}s)" >&2
}

# lock_heartbeat <agent> — refresh heartbeat_at only (started_at/target_version
# preserved from the existing lock). No-op (warns to stderr, returns 1) if no
# lock exists — a heartbeat cannot resurrect a released/never-acquired lock.
lock_heartbeat() {
  local agent="$1" lockfile now target started
  lockfile="$(_maint_lock_file "$agent")"
  [ -f "$lockfile" ] || { echo "maintenance-lock: heartbeat skipped — no lock for $agent" >&2; return 1; }
  target="$(jq -r '.target_version // "unknown"' "$lockfile" 2>/dev/null || echo unknown)"
  started="$(jq -r '.started_at // empty' "$lockfile" 2>/dev/null || true)"
  case "$started" in ''|*[!0-9]*) started="$(date +%s)" ;; esac
  now="$(date +%s)"
  _maint_lock_write "$agent" "$target" "$started" "$now"
}

# lock_release <agent> — remove the lock file. Idempotent (no-op if absent).
# NOTE: this library does NOT decide WHEN to call this — see the crash-safety
# model in the file header. Callers own the release policy.
lock_release() {
  local agent="$1" lockfile
  lockfile="$(_maint_lock_file "$agent")"
  if [ -e "$lockfile" ]; then
    rm -f "$lockfile"
    echo "maintenance-lock: RELEASED for $agent" >&2
  fi
}

# lock_active <agent> -> exit 0 iff a lock file exists AND heartbeat_at is
# within MAINT_LOCK_TTL of now. A missing file, an unparseable/non-numeric
# heartbeat_at, or a heartbeat older than the TTL all read as INACTIVE — fail
# TOWARD resuming watchdog keep-alive, never toward blocking it forever (a
# corrupt lock must not be able to lock a real outage out of healing).
lock_active() {
  local agent="$1" lockfile hb now age
  lockfile="$(_maint_lock_file "$agent")"
  [ -f "$lockfile" ] || return 1
  hb="$(jq -r '.heartbeat_at // 0' "$lockfile" 2>/dev/null || echo 0)"
  case "$hb" in ''|*[!0-9]*) hb=0 ;; esac
  [ "$hb" -gt 0 ] || return 1
  now="$(date +%s)"
  age=$((now - hb))
  [ "$age" -le "$MAINT_LOCK_TTL" ]
}

# lock_info <agent> — one-line human-readable summary for log/SKIP lines.
# Never fails the caller: any parse trouble degrades to a terse fallback string.
lock_info() {
  local agent="$1" lockfile out
  lockfile="$(_maint_lock_file "$agent")"
  [ -f "$lockfile" ] || { echo "no lock"; return 0; }
  out="$(jq -r '
      "target=" + (.target_version // "?")
      + " started=" + ((.started_at // 0)|tostring)
      + " heartbeat_age_s=" + (((now|floor) - (.heartbeat_at // 0))|tostring)
    ' "$lockfile" 2>/dev/null || true)"
  [ -n "$out" ] && echo "$out" || echo "lock present (unparseable)"
}

# lock_heartbeat_loop <agent> [interval=$MAINT_LOCK_HEARTBEAT_INTERVAL] [max-iters=0]
# — a background refresher: sleeps `interval`, calls lock_heartbeat, repeats.
# Intended usage is `lock_heartbeat_loop agent & pid=$!` — the caller owns
# killing `$pid` when the protected window ends (this function never exits on
# its own unless max-iters > 0, the dead-man's-switch bound: see the file
# header's MAINT_LOCK_HEARTBEAT_MAX_S). Decoupling the heartbeat cadence from
# whatever the caller's foreground steps are doing (e.g. a slow `npx` install
# or a long verify-poll loop) is the whole point of running this as a SEPARATE
# background loop rather than heartbeating between steps: the lock stays fresh
# even while the foreground is blocked deep inside one long-running step.
lock_heartbeat_loop() {
  local agent="$1" interval="${2:-$MAINT_LOCK_HEARTBEAT_INTERVAL}" max_iters="${3:-0}" i=0
  [ "$interval" -gt 0 ] 2>/dev/null || interval="$MAINT_LOCK_HEARTBEAT_INTERVAL"
  while :; do
    sleep "$interval"
    lock_heartbeat "$agent" 2>/dev/null || true
    if [ "$max_iters" -gt 0 ]; then
      i=$((i+1))
      [ "$i" -ge "$max_iters" ] && break
    fi
  done
}

# lock_heartbeat_max_iters [interval] — helper to compute a sane max-iters bound
# from MAINT_LOCK_HEARTBEAT_MAX_S, for callers that want the dead-man's-switch
# without hand-computing the division. Returns 0 (unlimited) if the max-seconds
# bound is disabled (0) or the interval is somehow non-positive.
lock_heartbeat_max_iters() {
  local interval="${1:-$MAINT_LOCK_HEARTBEAT_INTERVAL}"
  if [ "${MAINT_LOCK_HEARTBEAT_MAX_S:-0}" -gt 0 ] 2>/dev/null && [ "$interval" -gt 0 ] 2>/dev/null; then
    echo $((MAINT_LOCK_HEARTBEAT_MAX_S / interval))
  else
    echo 0
  fi
}
