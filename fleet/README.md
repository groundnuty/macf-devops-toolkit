# `fleet/` — the VM cron-watchdog desired-state reconciler (DR-006)

The devops realization of `macf` **DR-031** (agent supervision) on the VM substrate:
a stateless cron one-shot that drives **actual** fleet state → operator-owned
**desired** state. See `../design/DR-006-vm-cron-watchdog-agent-supervision-impl.md`.

## Model (DR-006 §A.1)

Each run reconciles the delta between **desired** (the manifest) and **actual**
(probed live via DR-030's `macf fleet doctor --json`):

| state | decision |
|---|---|
| desired & reachable+accepting | **OK** |
| desired & not-registered/running | **LAUNCH** (cold-start / reboot-recovery) |
| desired & registered-but-deaf | **HEAL** (the tiered ladder) |
| desired-down (`paused`) | **SKIP** (never resurrect — don't-fight-the-operator) |

This is the Kubernetes reconcile model on the VM (desired replicas vs running
pods); on K8s it is native. The reconciler **consumes** `fleet doctor --json` —
it does not re-implement detection. Identity keys on the per-agent **`ack_agent`**
(kebab routing-label), not `name` (the registry-key form).

## Files

- **`reconcile.sh`** — the reconcile engine. `--manifest`, `--fleet-json <file>`
  (inject probe output for tests/offline), `--paused-dir`. HARD-asserts the
  `fleet doctor --json` `schema_version` (a silent field-rename would blind the
  supervisor — itself a silent-fallback). Exit: `0` all-OK/paused, `1` LAUNCH/HEAL
  needed, `2` usage/precondition.
- **`desired-agents.example.yaml`** — the operator-owned desired-state manifest
  (DR-006 §A.2). Copy to `~/.macf/desired-agents.yaml`. **Not** derived from the
  registry (that is *actual* state; this is *desired*).
- **`test-reconcile.sh`** — offline unit tests (canned fixtures, no live fleet).
- **`testdata/`** — `fleet doctor --json` fixtures.

## Intent signal — the exit code (DR-006 Amendment B)

A not-running desired agent is reconciled by **`claude`'s last exit code** (captured
by the LAUNCH wrapper into `~/.macf/last-exit/<agent>`):

- `last-exit == 0` (the operator typed `/exit`) → **desired-DOWN → SKIP** (don't-fight).
- `last-exit != 0` or **absent** (SIGTERM / crash / never-ran) → **LAUNCH** (restore).

This is POSIX-stable (not coupled to Claude Code internals — empirically: `/exit`=0,
SIGTERM=143, SIGHUP=129, SIGKILL=137) and **fails safe toward restore** (ambiguity
always restores; even a SIGKILL'd wrapper leaves no `0` → restore). It composes with
the explicit `paused` sentinel: **desired-down = `paused` OR `last-exit==0`**.

## Status — incremental build (macf#118)

- **Increment 1 (merged):** the reconcile **engine** — decisions, report-only.
- **Increment 2 (this):** **action execution** — the exit-code intent layer +
  LAUNCH (detached, exit-code-captured tmux session) + the tiered HEAL ladder
  (Tier-1 inject gated by the Pattern-C `session_activity` check vs the Instance-3
  RC-bound-tmux hazard → Tier-2 graceful-restart **held behind `--allow-restart`** →
  Tier-3 dedup'd alert). **DRY-RUN BY DEFAULT** — constructs + prints commands;
  `--execute` actually acts, `--allow-restart` enables Tier-2.
- **Increment 3 (next):** host-installed cron + idempotent registration on launch +
  the watchdog self-heartbeat + the `macf routing doctor --json` routing-infra probe
  (treating `session_ok`/`pins_consistent` as known false-positives per macf#610/#614,
  keying on the real per-agent invariants).
- **Increment 4:** the K8s liveness/`restartPolicy` manifests (the substrate-native
  equivalent — `restartPolicy: OnFailure` consumes the *same* exit-code contract;
  the agent contract `/health` + be-replaceable + exit-code-intent is unchanged).

## Run

```sh
# dry-run (default — reports decisions + prints the commands it WOULD run):
./fleet/reconcile.sh --manifest ~/.macf/desired-agents.yaml

# actually act (launch missing agents, run the HEAL ladder):
./fleet/reconcile.sh --manifest ~/.macf/desired-agents.yaml --execute

# also enable Tier-2 graceful-restart (operator sign-off; default OFF):
./fleet/reconcile.sh --manifest ~/.macf/desired-agents.yaml --execute --allow-restart

# offline / tests:
./fleet/test-reconcile.sh
```

Requires `jq` (and `macf` ≥ 0.2.39 for `fleet doctor --json`). In cron it runs
from a minimal env → source `host-prelude.sh` first (DR-031 portable bootstrap).
