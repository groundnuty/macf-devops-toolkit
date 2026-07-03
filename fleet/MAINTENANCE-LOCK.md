# Maintenance-lock — "upgrade ≠ outage" (DR-040 Decision 4, macf-devops-toolkit#158)

**Problem:** the DR-006 watchdog cron keeps agents alive — a down agent gets
relaunched. `fleet/upgrade.sh` intentionally stops an agent to roll it onto a new
version. Without a signal that distinguishes "planned, in-progress transition"
from "unplanned outage," a watchdog sweep landing mid-upgrade reads the stopped
agent as a crash and relaunches it — a double-launch, or a relaunch that races
the upgrade's own relaunch into the wrong tmux session.

**Fix:** a small, durable, heartbeat-refreshed **lock** that `fleet/upgrade.sh`
(the SET-side) holds for exactly the window it has the agent's process stopped,
and that `fleet/reconcile.sh` (the READ-side) checks before taking any action on
that agent. The lock is crash-safe by construction: it isn't released on failure,
it's simply left to go stale.

This file documents the primitive. The implementation is `fleet/maintenance-lock.sh`
(the library — read its header for the full contract + crash-safety reasoning);
`fleet/upgrade.sh` and `fleet/reconcile.sh` are its only two callers.

---

## The contract

One lock **file** per agent, `$MAINT_LOCK_DIR/<agent>.lock` (default
`$HOME/.macf/maintenance-locks/`), JSON:

```json
{
  "schema_version": 1,
  "agent": "code-agent",
  "target_version": "0.2.45",
  "started_at": 1751500000,
  "heartbeat_at": 1751500300
}
```

`started_at` / `heartbeat_at` are **Unix epoch seconds** (integers), not ISO8601 —
deliberately, to sidestep the GNU-`date`-vs-BSD-`date` parsing divergence that
already forced a fallback pattern elsewhere in `fleet/` (see `upgrade.sh`'s
`stat -c%s` / `stat -f%z` dance). Epoch seconds are portable, trivially
jq-comparable, and match `reconcile.sh`'s own `emit_watchdog_metric()` convention.

Four verbs, all in `fleet/maintenance-lock.sh`:

| Function | Effect |
|---|---|
| `lock_acquire <agent> <target-version>` | create/overwrite (atomic write) |
| `lock_heartbeat <agent>` | refresh `heartbeat_at` only; no-op if no lock exists |
| `lock_release <agent>` | remove the lock file; idempotent |
| `lock_active <agent>` | exit 0 iff a lock exists **and** its heartbeat is within `MAINT_LOCK_TTL` |

Plus two small helpers: `lock_info <agent>` (one-line summary for log lines) and
`lock_heartbeat_loop <agent> [interval] [max-iters]` (a background refresher —
see "Heartbeat mechanism" below).

---

## Design decision — lock path: fleet-central, not per-agent-workspace

The task brief offered two options: a file inside the agent's own workspace
(`.claude/.macf/maintenance.lock`) or a fleet-central directory
(`fleet/locks/<agent>.lock`). **This build picked fleet-central, but under
`$HOME/.macf/maintenance-locks/` rather than inside the repo** — matching the
*existing* convention exactly, not inventing a new one.

`reconcile.sh` already keys every other piece of per-agent watchdog state this
way, all under the operator's `$HOME`, none inside any repo checkout or any
agent's own workspace:

- `PAUSED_DIR` → `$HOME/.macf/paused/<agent>`
- `LAST_EXIT_DIR` → `$HOME/.macf/last-exit/<agent>`
- `STATE_DIR` → `$HOME/.macf/watchdog-state/<agent>[.backoff]`
- `ALERT_DIR` → `$HOME/.macf/alerts/<agent>`
- `SESSION_BACKUP_DIR` (`upgrade.sh`) → `$HOME/.macf/session-backups/<agent>/`

`MAINT_LOCK_DIR` → `$HOME/.macf/maintenance-locks/<agent>.lock` is the sixth
member of this family. Reasons this beats an in-workspace file:

1. **`reconcile.sh` never `cd`s into an agent's workspace.** It already resolves
   `workspace` per-agent from the manifest for exactly one purpose (constructing
   the `tmux new-session` launch command) — reading per-agent *state* is a
   completely separate concern the script already centralizes. Adding a lock
   check that requires resolving into each agent's workspace path would be new
   plumbing for no benefit.
2. **Consistency with the paused-sentinel model.** A maintenance lock is, in
   the reconcile loop's own decision model, structurally identical to the
   `paused` sentinel — both are "desired-down, SKIP" states keyed by agent
   label. Reusing the exact directory-of-per-agent-files shape as `PAUSED_DIR`
   keeps that structural identity visible in the code, not just in the comment.
3. **Git-safety for free.** `$HOME/.macf/...` is outside any repo checkout by
   construction (verified empirically — see "Verification" below) — no
   `.gitignore` maintenance needed for the default path. (A defensive
   `.gitignore` entry was still added for `fleet/locks/` and
   `.macf/maintenance-locks/` in case an operator ever points
   `MACF_MAINT_LOCK_DIR` at an in-repo path for local testing — see the repo
   root `.gitignore`.)

## Design decision — the SKIP check suppresses the WHOLE ladder, not just LAUNCH

The task brief's literal ask was "before relaunching a DOWN agent, call
`lock_active` → skip the relaunch." This build implements something slightly
broader: the lock check runs **once per agent**, immediately after the existing
`paused` / `last-exit==0` SKIP checks and **before** the LAUNCH/HEAL branching —
so an active lock suppresses LAUNCH **and** every tier of the HEAL ladder
(Tier-1 inject, Tier-2 restart, Tier-3 alert), not LAUNCH alone.

Why: during an upgrade's own stop→restart→re-register cycle, an agent can
transiently read as `reachable=true, accepted=false` (relaunched but not yet
re-registered) — the exact shape that drives `reconcile.sh`'s
`reachable-not-accepting` HEAL branch. At escalation (sweep 2+), that branch's
Tier-2 is a **second SIGTERM**, which would race the upgrade's own restart. The
literal LAUNCH-only guard would leave this window unprotected. Gating the whole
decision point closes it, at the cost of one extra `if` — cheap, and it mirrors
how the `paused` sentinel already short-circuits the same way.

## Design decision — heartbeat is a background loop, not per-step

`fleet/upgrade.sh`'s per-agent roll (`roll_one()`) has three phases of very
different, not-fully-predictable duration: `npx @groundnuty/macf@<ver> update`
(network-dependent), a fixed `sleep 3` around the restart, and a poll loop of up
to `VERIFY_TIMEOUT` (default 120s, configurable). Heartbeating *between* these
steps would stall for however long the current step takes — exactly the failure
mode a slow `npx` (a network hiccup, a slow registry) would trigger.

Instead, `lock_acquire` starts a **background** `lock_heartbeat_loop` (`&`) that
ticks independently of whatever `roll_one()`'s foreground is doing. This
decouples "is the roll still alive" from "how long is the current sub-step
taking" — a slow-but-genuinely-alive upgrade stays protected regardless of which
phase it's in.

**Dead-man's-switch on the loop itself.** A background loop process is a real
OS process; if `upgrade.sh` is ever `SIGKILL`'d (uncatchable — no trap runs), an
orphaned heartbeat loop could in principle keep refreshing the lock forever,
defeating the TTL. `lock_heartbeat_loop` accepts an optional `max-iters` bound
(`lock_heartbeat_max_iters` computes it from `MACF_MAINT_LOCK_HEARTBEAT_MAX_S`,
default 3600s = 1 hour — far beyond any plausible single-agent roll) so even an
orphaned loop self-terminates, bounding total worst-case exposure to
`max-heartbeat-lifetime + TTL` regardless of how the parent died.

---

## Lifecycle

```
fleet/upgrade.sh (roll_one, per agent, EXECUTE path only)
  │
  ├─ lock_acquire <agent> <target>        (BEFORE anything touches the process)
  ├─ lock_heartbeat_loop <agent> &        (background, ticks every ~TTL/3)
  │
  ├─ [pin-bump via npx]
  │     └─ FAILS → stop heartbeat loop, LEAVE the lock  (HALT, exit 1)
  ├─ [SIGTERM + relaunch]
  ├─ [verify-green poll, up to VERIFY_TIMEOUT]
  │     ├─ TIMES OUT → stop heartbeat loop, LEAVE the lock  (HALT, exit 1)
  │     └─ GREEN
  │           └─ session-state guard FAILS → stop heartbeat loop, LEAVE the lock (HALT)
  │           └─ session-state guard PASSES
  │                 └─ stop heartbeat loop AND lock_release  (only clean-success path)
  │
  └─ (top-level EXIT/INT/TERM trap: ALWAYS stops the heartbeat loop; NEVER
      releases the lock — see "Release policy" below)

fleet/reconcile.sh (per sweep, per desired agent)
  │
  ├─ paused sentinel?           → SKIP
  ├─ last-exit==0 (typed /exit)? → SKIP
  ├─ lock_active(agent)?        → SKIP  (maintenance lock active)
  └─ else → normal LAUNCH / HEAL / OK decision, unchanged from before #158
```

## Release policy — release ONLY on confirmed clean success

**This is a corrected design point** (the task brief's original text said
"release at the end AND on failure/exit via trap" — that was wrong and was
corrected mid-build by the SET-side owner). The actual rule:

- **Clean GREEN** (pin-bump succeeded, restart succeeded, `/health.version`
  reached target within `VERIFY_TIMEOUT`, session-state guard passed) →
  `lock_release` is called explicitly, inline, right there. The agent is handed
  back to normal watchdog reconciliation immediately.
- **Any HALT** (pin-bump failed, verify-timeout, session-state-guard failure) →
  the lock is **left in place**. Only the background heartbeat loop is stopped.
  The lock self-clears once its heartbeat goes stale (`MAINT_LOCK_TTL`, default
  900s after the last heartbeat).
- **Hard interrupt** (Ctrl-C, SIGTERM, an uncaught `set -e` bail anywhere in the
  script) → the top-level `trap _lock_cleanup_keep EXIT INT TERM` stops whatever
  heartbeat loop is currently running. It never releases.

Why leave a HALTED lock in place instead of releasing it immediately: releasing
on failure hands a possibly-broken, mid-transition agent straight back to the
watchdog's Tier-1/2/3 healing ladder the instant the roll fails — exactly the
uncoordinated, racing intervention DR-040 Decision 3 (transactional halt) exists
to avoid. Leaving the lock in place is a **bounded** grace window (the TTL, not
indefinite) for an operator to look at a halted roll before the watchdog resumes
automatic action on it.

---

## Sizing the defaults

| Knob | Default | Rationale |
|---|---|---|
| `MACF_MAINT_LOCK_TTL` | `900` (15 min) | Sized against the watchdog's own cron cadence (`install-cron.sh` default `*/10 * * * *` = 600s): 900s gives a 1.5× margin so ordinary cron jitter never reads a live-but-momentarily-quiet lock as stale, while still bounding how long a **crashed** upgrade can shield an agent from healing to roughly 15 minutes. |
| `MACF_MAINT_LOCK_HEARTBEAT_INTERVAL` | `TTL/3` (300s) | Even a single missed/delayed tick still lands a fresh heartbeat well inside the TTL window before the next cron sweep could observe staleness. |
| `MACF_MAINT_LOCK_HEARTBEAT_MAX_S` | `3600` (1h) | Dead-man's-switch bound on the background loop's own total lifetime — see "heartbeat is a background loop" above. Far beyond any plausible `roll_one()` duration (worst case ≈ `VERIFY_TIMEOUT` + `npx` overhead, realistically well under 10 minutes). |
| `MACF_MAINT_LOCK_DIR` | `$HOME/.macf/maintenance-locks` | See "lock path" design decision above. |

`reconcile.sh` also exposes `--maint-lock-dir <dir>` as a CLI flag (matching its
existing `--paused-dir` / `--last-exit-dir` / `--state-dir` pattern) for
operator/test overrides on top of the env var.

---

## K8s driver — interface only, not implemented here (DR-007's decision/driver split)

DR-007 established a decision/driver split for the *upgrade* orchestrator: the
rolling-sequence decision logic is runtime-agnostic; only the bottom "driver"
layer (how you actually stop/restart an agent, and how you actually persist a
lock) is VM- or K8s-specific. The maintenance-lock primitive follows the same
split:

| Concern | VM driver (this build) | K8s driver (future — the *macf operator*) |
|---|---|---|
| Lock storage | a lock **file** under `$MAINT_LOCK_DIR`, atomic tempfile+`mv` | a pod **annotation** (e.g. `macf.groundnuty.io/maintenance-lock: '<the same JSON>'`) or a small per-agent **ConfigMap** |
| Atomicity primitive | tempfile in the same dir (same-filesystem `mv` is atomic) + best-effort `fsync` | a single K8s API `Patch` call — the API server's optimistic-concurrency model gives atomicity for free, no temp-file dance needed |
| Staleness check | `heartbeat_at` age vs `MAINT_LOCK_TTL`, read by a cron sweep | identical logic, read by the operator's reconcile loop |
| Who sets it | `fleet/upgrade.sh` | the macf operator's upgrade driver |
| Who reads it | `fleet/reconcile.sh` | the macf operator's reconcile loop (same process, on K8s — no separate watchdog needed, per DR-006/DR-007) |

The four-verb contract (`lock_acquire` / `lock_heartbeat` / `lock_release` /
`lock_active`) is designed to be implementable against either backing store
without changing any caller — same shape as DR-007's `driver.upgrade()` /
`driver.restart()` interface. **Not implemented here**: no K8s manifests,
annotation schema validation, or operator controller code — those are scoped to
whichever future code/science DR builds the macf operator (DR-007 §7 already
notes this is "far-future" and belongs to a separate DR). This section is the
interface note the task brief asked for, not a stub implementation.

---

## Explicitly out of scope for this PR (adjacent DR-040 Decision 4 pieces)

DR-040 Decision 4 names two more effects beyond the lock itself. Both are
**documented here as adjacent**, not half-built:

1. **Routing-freeze** — while an agent is under maintenance, peer messages
   addressed to it should be *queued*, not dropped, so they're delivered once
   the agent comes back. This is very likely channel-server-side work
   (`groundnuty/macf-channel-server`, Node/TypeScript) — the VM watchdog/upgrade
   scripts in this repo have no visibility into the channel-server's message
   queue. Out of scope for this lib/tests/docs PR; needs its own issue against
   the channel-server repo, informed by whether it reads this same lock file (VM
   case) or the K8s annotation.
2. **`#733` identity-collision backstop** — the double-launch failure mode this
   primitive prevents already has (per the task brief) a backstop elsewhere:
   detecting two live instances claiming the same agent identity and resolving
   the collision. This maintenance-lock is the **prevention** half; `#733` is
   the **detection-and-recovery** half for whatever slips through (e.g. a race
   in the narrow window between `lock_acquire` and the first heartbeat, or an
   operator manually launching a second instance). Not touched by this PR.

---

## Tests

`fleet/test-maintenance-lock.sh` — pure-offline, no live tmux/agents:

- Library: acquire→active, schema fields all populated, heartbeat refreshes
  `heartbeat_at` and keeps the lock active, heartbeat on a non-existent lock is
  a no-op, release→inactive (+ idempotent), a stale-heartbeat lock reads
  inactive (TTL expiry — tested both "too old" and "still fresh under a larger
  TTL" to prove it's not just always-inactive), a malformed/missing-heartbeat
  lock reads inactive (fail-toward-resume), the heartbeat-loop dead-man's-switch
  self-terminates.
- Integration with `reconcile.sh`: a locked-down agent (both the true-absent
  LAUNCH case and the present-but-unreachable HEAL case) is SKIPped; an
  unlocked agent in the same sweep is unaffected (per-agent scoping, not a
  global freeze); releasing one agent's lock doesn't affect another's; a STALE
  lock does NOT block relaunch (proves the crash-safety self-free property).

Run: `./fleet/test-maintenance-lock.sh`. Existing suites (`test-reconcile.sh`,
`test-upgrade.sh`) re-verified green (module-local A/B against the pre-#158 tree)
with no regressions from this change.
