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
| desired-down (`paused` OR active maintenance lock) | **SKIP** (never resurrect — don't-fight-the-operator) |

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
- **`upgrade.sh`** — DR-007 rolling version-upgrade (VM reference impl). See its
  own header + `MAINTENANCE-LOCK.md` for the lock it holds while rolling an agent.
- **`test-upgrade.sh`** — offline classify/busy-gate/session-guard tests for `upgrade.sh`.
- **`maintenance-lock.sh`** — the DR-040 Decision-4 maintenance-lock primitive
  ("upgrade ≠ outage", macf-devops-toolkit#158). Sourced by both `reconcile.sh`
  (read-side) and `upgrade.sh` (write-side). Full design writeup: **`MAINTENANCE-LOCK.md`**.
- **`test-maintenance-lock.sh`** — offline library + `reconcile.sh`-integration tests.
- **`runner-watchdog.sh`** — the RUNNER-side liveness watchdog (macf-devops-toolkit#163),
  the runner-analog of this reconciler. See "Runner-watchdog (#163)" below.
- **`test-runner-watchdog.sh`** — offline decision-table + composition tests (no
  systemctl/yq mocking; see the file's own header for what's covered live instead).

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
- **Increment 2 (merged):** **action execution** — the exit-code intent layer +
  LAUNCH (detached, exit-code-captured tmux session) + the tiered HEAL ladder
  (Tier-1 inject gated by the Pattern-C `session_activity` check vs the Instance-3
  RC-bound-tmux hazard → Tier-2 graceful-restart **held behind `--allow-restart`** →
  Tier-3 dedup'd alert). **DRY-RUN BY DEFAULT**; `--execute` acts.
- **Increment 3 (this):** the **periodic / cross-sweep** layer —
  - **`install-cron.sh`** — idempotent **host-installed** cron (survives reboot;
    the first post-boot sweep launches the desired fleet, §A.4). Sources
    `host-prelude.sh` first (cron's bare env). **Installs report-only by default**;
    `--execute` / `--allow-restart` opt in. `--uninstall` / `--print` too.
  - **Cross-sweep escalation** — the consecutive-deaf-sweep counter drives the tier:
    sweep 1 → Tier-1; sweep 2+ → escalate (Tier-2 if allowed + Tier-3). So a Tier-1
    that "delivered" (the `session_activity` heuristic — not a true receipt) but did
    NOT recover the agent escalates instead of re-injecting forever. Reset on OK.
  - **Self-heartbeat** (`--heartbeat-file`) — stamped each real sweep; its absence
    is the who-watches-the-cron signal (→ Tier-3/operator). Execute-gated.
- **Increment 4 (this):** the **`routing doctor --json` second probe** (`--with-routing`)
  — registration-freshness on top of mesh-reachability. Catches the **macf#553
  stale-registration** case mesh alone misses (the agent answers mTLS but the registry
  points at a dead/old instance → the router dials the wrong port): a mesh-OK agent
  with `registry_instance_id != health_instance_id` (or not-`routable`, or `freshness:
  stale`) → **HEAL (stale-registration)**. **Deliberately IGNORES the two known
  false-positives** on the hand-wired substrate — per-agent `session_ok` (vestigial
  agent-config, macf#610) and the aggregate `verdict`/`pins_consistent` (non-fleet
  repos, macf#614) — keying only on the real per-agent invariants (silent-fallback
  Pattern A: assert load-bearing invariants, don't trust a composite carrying a
  calibration FP). Schema-pinned like fleet-doctor. Optional (mesh-only without the flag).
- **Increment 5 (next):** the K8s liveness/`restartPolicy` manifests (the
  substrate-native equivalent — `restartPolicy: OnFailure` consumes the *same*
  exit-code contract; the agent contract `/health` + be-replaceable + exit-code-intent
  is unchanged). Plus the heartbeat external consumer (devops-toolkit#123).
- **Increment 6 (this, #158):** the **maintenance-lock** primitive (DR-040
  Decision 4 — "upgrade ≠ outage"). `upgrade.sh` acquires + heartbeats a
  per-agent lock around its stop→restart→verify window; `reconcile.sh` SKIPs
  (instead of LAUNCH/HEAL) any agent with an active lock. Crash-safe: a
  crashed/interrupted upgrade simply stops heartbeating, the lock goes stale,
  and the watchdog resumes on its own — no manual unlock. See
  **`MAINTENANCE-LOCK.md`** for the full design (lock-path choice, release
  policy, TTL/heartbeat sizing, and the K8s driver interface).

## Runner-watchdog (#163) — the self-hosted-runner analog

`runner-watchdog.sh` closes a gap this reconciler doesn't cover: a self-hosted
GitHub Actions runner (`runner/runners.yaml`) going down does **not** reroute.
macf-actions' `pick-runner` selects `[self-hosted, macf-vm]` for a trusted actor
with **no liveness check**, so a dead runner makes that repo's trusted routing
**queue forever** rather than falling back to `ubuntu-latest`. `Restart=always`
(`runner/systemd-restart-override.conf`, RUNNER.md "Auto-restart oversight")
auto-recovers a bare process crash in ~5s, but not a unit stuck `failed`/
`inactive` past its restart budget, `masked`, or torn down/de-registered
entirely — and either way a systemd-internal restart is **silent**, with none
of this reconciler's Tier-1/2/3 fleet-visible signal.

**Detection is LOCAL-ONLY** (`systemctl show` on the `actions.runner.<owner>-
<repo>.<name>.service` unit, reusing `runner/verify-runner.sh`'s exact
repo-slug + `list-units` derivation) — never the GitHub runners API, which the
bot is 403 on (`administration:read`, same shape as every other runner-side
credential boundary documented in `../runner/RUNNER.md` "The security model").

| state | decision |
|---|---|
| maintenance lock active for this runner's `name` | **SKIP** (checked first — an in-flight `make reinstall-<name>` tears the unit down on purpose) |
| unit not `loaded` (masked / torn down / never installed) | **ALERT** (dedup'd sentinel — needs an operator-minted token to re-register, this script can't do it unattended) |
| unit `loaded` + `ActiveState=active` | **OK** |
| unit `loaded` but not active (inactive/failed/dead/activating-stuck) | **HEAL** (`systemctl restart`, gated behind `--allow-restart`; re-checked after restart — still not active → escalate to **ALERT**) |

The whole tiered response is ONE 3-input pure function,
`_runner_watchdog_decide <active-state> <unit-loaded> <lock-active>`, unit-tested
in `test-runner-watchdog.sh` without touching `systemctl` at all (same
"factor the decision table out of the `gh`/`systemctl`-calling wrapper" shape
as `runner/fork-pr-approval-check.sh`'s `_fork_approval_decide`).

**Only sweeps `status: live` registry entries** (`MACF_RUNNER_WATCHDOG_STATUSES`,
default `live`) — `runners.yaml` also carries `ready`/staged entries (e.g. `macf`,
`macf-auditor-agent` as of #163) that are intentionally not installed yet;
sweeping them would ALERT every cycle for a runner nobody has stood up.

**Composes with `maintenance-lock.sh`** — the SAME shared primitive (dir /
schema / TTL) this reconciler reads and `upgrade.sh` writes. **Known gap, not
wired in #163's scope:** `runner/reconcile-runner.sh` does not yet *acquire*
the lock around its own uninstall→install window, so a live
`make reinstall-<name>` today still transiently ALERTs while the unit is torn
down. Wiring that acquire is the natural follow-up, mirroring how
`fleet/upgrade.sh` already does it for agents.

**Restarting a runner needs root** (unlike this reconciler's tmux-level
actions — `install-runner.sh` itself refuses to run without `id -u == 0`).
`runner-watchdog.sh` issues `sudo -n systemctl restart <svc>` — non-interactive,
so a cron lacking the grant fails FAST into the ALERT path instead of hanging
on a password prompt — rather than assuming passwordless privilege exists.
**This PR does not install that sudoers grant** (infra provisioning outside a
code-only change); an operator who wants `--allow-restart` to actually heal
anything needs to add one, mirroring the existing narrow tmux-send-helper grant
(`../runner/RUNNER.md` "The `macf-runner` capability boundary"), e.g.:

```
# /etc/sudoers.d/macf-runner-watchdog (operator-installed; NOT auto-created by #163)
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl restart actions.runner.*.service
```

Until that grant exists, `--allow-restart` still safely degrades to ALERT
(`sudo -n` fails fast, the post-restart re-check reads still-not-active, the
sweep escalates) — it never hangs the cron and never silently no-ops.

### Runner-watchdog cron wiring

Wired into `install-cron.sh` as an **opt-in** `--with-runner-watchdog` flag
that chains `runner-watchdog.sh` onto the SAME cron line as `reconcile.sh`,
right after it, joined with `;` (not `&&`, so a `reconcile.sh` hiccup never
suppresses the runner sweep) — reusing the SAME `--execute`/`--allow-restart`
dials (one operator-trust knob for both legs) but logging to its own file
(`~/.macf/runner-watchdog.log` by default) for easier triage. Kept as a
**separate script invoked alongside** `reconcile.sh`, not folded into it:
`reconcile.sh`'s decision model (`ack_agent` identity, `desired-agents.yaml`
schema, `fleet doctor --json` schema) is agent-shaped end to end, and a
systemd-unit-keyed-by-repo entity doesn't fit without contorting that schema —
this mirrors the existing `--with-routing` precedent (Increment 4: a second,
independently-toggleable probe bolted onto the sweep rather than a schema rewrite).

**Operator setup gap:** `runner-watchdog.sh` needs `yq` in addition to the
`jq`/tmux toolchain `host-prelude.sh` already provides for `reconcile.sh`. `yq`
is currently pinned only in `runner/devbox.json` (a project-scoped shell), not
confirmed present in `devbox global` (what `host-prelude.sh`'s `eval "$(devbox
global shellenv)"` exposes to cron). Until an operator runs
`devbox global add yq-go`, the cron leg fails open with a clear one-line
diagnostic (`yq not found ... skipping sweep`, exit 0) rather than erroring —
consistent with the script's fail-safe posture, but it means `--with-runner-
watchdog` is a no-op until that global package is added.

## Run

```sh
# dry-run (default — reports decisions + prints the commands it WOULD run):
./fleet/reconcile.sh --manifest ~/.macf/desired-agents.yaml

# actually act (launch missing agents, run the HEAL ladder):
./fleet/reconcile.sh --manifest ~/.macf/desired-agents.yaml --execute

# also enable Tier-2 graceful-restart (operator sign-off; default OFF):
./fleet/reconcile.sh --manifest ~/.macf/desired-agents.yaml --execute --allow-restart

# install the host cron (report-only first — watch the log, then re-run --execute):
./fleet/install-cron.sh                       # report-only, every 10 min, logs to ~/.macf/watchdog.log
./fleet/install-cron.sh --execute             # once trusted: acting (Tier-2 still held)
./fleet/install-cron.sh --execute --allow-restart   # full auto-restart
./fleet/install-cron.sh --with-runner-watchdog      # also chain runner-watchdog.sh (#163)
./fleet/install-cron.sh --uninstall

# runner-watchdog standalone (dry-run default, same --execute/--allow-restart shape):
./fleet/runner-watchdog.sh
./fleet/runner-watchdog.sh --execute --allow-restart

# offline / tests:
./fleet/test-reconcile.sh
./fleet/test-upgrade.sh
./fleet/test-maintenance-lock.sh
./fleet/test-runner-watchdog.sh
```

Requires `jq` (and `macf` ≥ 0.2.39 for `fleet doctor --json`). In cron it runs
from a minimal env → source `host-prelude.sh` first (DR-031 portable bootstrap).
`runner-watchdog.sh` additionally needs `yq` + `systemctl` — see "Runner-watchdog
cron wiring" above for the `devbox global add yq-go` operator gap.
