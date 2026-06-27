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

## Status — incremental build (macf#118)

- **Increment 1 (this):** the reconcile **engine** — read desired → schema-pinned
  probe → compute + report per-agent decisions. **Report-only** (no kills/launches).
- **Increment 2 (next):** action execution — the tiered ladder (Tier-1 inject
  gated by the Pattern-C `session_activity` check vs the Instance-3 RC-bound-tmux
  hazard → Tier-2 `restart-self` **held behind operator sign-off** → Tier-3 alert)
  + LAUNCH (detached `claude.sh`) + the watchdog self-heartbeat.
- **Increment 3:** host-installed cron + idempotent registration on launch +
  the `macf routing doctor --json` routing-infra probe (treating its `session_ok`
  as assert-if-present per macf#610, NOT faulting on the substrate false-positive).
- **Increment 4:** the K8s liveness/`restartPolicy` manifests (the substrate-native
  equivalent; the agent contract `/health` + be-replaceable is unchanged).

## Run

```sh
# report (against the live mesh):
./fleet/reconcile.sh --manifest ~/.macf/desired-agents.yaml

# offline / tests:
./fleet/test-reconcile.sh
```

Requires `jq` (and `macf` ≥ 0.2.39 for `fleet doctor --json`). In cron it runs
from a minimal env → source `host-prelude.sh` first (DR-031 portable bootstrap).
