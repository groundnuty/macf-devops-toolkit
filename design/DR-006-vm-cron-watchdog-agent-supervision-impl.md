# DR-006: VM cron-watchdog — the devops realization of agent supervision (impl of DR-031)

**Status:** Proposed
**Date:** 2026-06-26
**Trigger:** The 2026-06-26 Stage-3 off-channels incident (`macf-devops-agent` silently went deaf after a relaunch — the `macf#553` collision-abort left a healthy-looking-but-deaf agent + a stale registry entry; the operator had to hand-relay a peer's review). `macf` **DR-031** ("Agent supervision — liveness contract + portable self-restart") graduated the design (`macf-devops-toolkit#115`, devops + operator session, science + code reviewed). DR-031 defines the **substrate-agnostic contract**; **this DR is its VM-cron realization** + the K8s manifests for when agents move to pods. It is the devops slice of DR-031 §"Ownership".

## Context

DR-031 makes every agent supervisable through **two agent-owned constants** — a `/health` liveness contract and a `restart-self` verb — and lets the **substrate** provide the trigger + the restart. The framework owns the contract (the `/health` hardening, `restart-self`, graceful-deregister, the registry TTL, the `host-prelude` generator); **devops owns the VM substrate realization**: the periodic trigger (cron), the stateless watchdog that consumes detection and drives the response ladder, and the K8s-native equivalents (kubelet liveness + `restartPolicy`).

This DR does **not** re-specify the contract or re-implement detection — it composes:

| Consumed from | What |
|---|---|
| **DR-030** (`macf fleet`/`macf routing`) | the detection probes (`--json`) the watchdog parses — the watchdog never re-implements the probe chain |
| **DR-031** (the contract) | `/health` liveness + `restart-self` + graceful-deregister + registry TTL + the `host-prelude` slot |
| **`macf#556`** | the dead-vs-alive `/health` primitive (`registry prune`) shared as the probe primitive |

## Decision — a stateless cron one-shot that *consumes* DR-030's detection

> **Refined by Amendment A** (2026-06-26, below): the watchdog is a **desired-state reconciler**, not a bare liveness-restarter — that reframe is what gives cold-start / one-command launch-all / reboot-recovery and the *don't-fight-a-deliberate-exit* guarantee. The §"Decision" mechanics below are the per-agent-**heal** branch (the tiered ladder); Amendment A is the reconciler model that wraps them.

### 1. The watchdog is a stateless cron one-shot

A single script: **probe → act → exit**. No long-lived daemon (the "who watches the watchdog" regress is terminated by the trigger being the OS scheduler, not a bespoke process — DR-031 §"Triggers"). It is fired by **user-level `cron`** on the VM (proven on real cron — §"Empirics"). The watchdog does **not** re-implement detection: it shells out to

```
macf fleet doctor --json      # mesh-Reachable (is each agent's channel up over mTLS?)
macf routing doctor --json    # registration-freshness (right key, instance_id/port match, no stale entry)
```

parses the verdict, and acts. **DR-030's `--json` schema IS the watchdog's input contract** (this is who that `--json` is *for*) — and the watchdog's `jq` parser **pins to the _shipped_ schema** (code posts the exact shape when `macf fleet doctor --json` merges) with a **schema-version assertion**, *not* a hand-authored guess: a field rename that silently broke the parser would blind the supervisor itself — a silent-fallback (the watcher going dark). The watchdog runs from cron — i.e. **outside Claude Code's sandbox**, which is exactly DR-030 §7's required execution context; the `host-prelude` (§5) makes the CLI runnable from cron's bare env.

**Two `--json` inputs, two DR-030 phases (sequence accordingly):** the probe-chain consumes **both** `macf fleet doctor --json` (mesh-Reachable — DR-030 **phase 1**, in active build now) **and** `macf routing doctor --json` (registration-freshness: caller-pins / #538 / `instance_id`+port staleness — DR-030 **phase 2**, not yet built). So VM v1 starts on `macf fleet doctor --json` (mesh-detection) the moment it merges and is **not blocked** waiting on `macf routing doctor`; the **full probe-chain completes when DR-030 phase 2 lands.**

**Free detection via the router** (DR-031): the v3 router reads the registry on *every* route, so a stale heartbeat / failed `/health` already surfaces "this agent looks deaf" as a side effect of normal traffic — covering *routed* agents. The cron sweep then only has to cover the **idle gap** (agents nobody is currently routing to — the case the agent itself cannot self-detect).

### 2. The tiered response ladder — delivery-confirmed-or-fall-through

Per DR-031's load-bearing doctrine (*every rung must be delivery-confirmed or fall through — a ladder with a silent rung is no ladder*):

1. **Tier 1 — inject a self-diagnose prompt** via the canonical `tmux-send-to-claude.sh` (harness-agnostic): *"⚠️ You appear OFF-CHANNELS: registry says :PORT, port DOWN, last health \<t\>. You are silently not receiving messages — investigate, clear any stale entry, request a relaunch."* The agent wakes and self-heals with full context.
   - **Gated by the Pattern-C `session_activity`-advanced check.** Tier-1 rides `tmux send-keys`, which **silently no-ops against an RC-bound TUI** (silent-fallback **Instance 3**) exactly when needed. The watchdog reads `tmux display -p '#{session_activity}'` before and after the inject; **if it did not advance, the inject is treated as not-delivered → fall through to Tier 2.**
2. **Tier 2 — `restart-self`** (the framework verb): the one thing the agent can't do mid-deafness. **The watchdog owns the *when*; the verb just executes** (no flapping-self-restart-loop, because the decision authority is external to the thing being restarted). Gated: confirmed-off-channels **and** idle **and** after a commit + RESUME-note window. **Held behind operator sign-off for v1** (see §"Phasing").
3. **Tier 3 — escalate to the operator** (open/raise an alert issue) on persistent failure / restart-loop. **Silent fleet-block becomes a loud alarm — the single most important property.**

### 3. Idempotent cron registration on launch

`claude.sh` registers the watchdog cron line **idempotently** on launch (check-for-marker → add only if absent; never duplicates on relaunch). The cron line **sources `host-prelude.sh` first** so the watchdog finds the toolchain (the CLI, `tmux`, `gh`) from cron's bare env. The registration is a no-op when the line is already present, so it is safe to run on every launch.

### 4. The watchdog self-heartbeat — terminating the who-watches-the-cron regress

The cron sweep covers the idle gap **only if cron itself runs.** So the watchdog **stamps its own heartbeat** each run (registry field or a known path). Its *absence* is then detectable — and the thing that checks it is the **operator/auditor monitoring layer, where Tier-3 escalation already lives**: watchdog-silent ⇒ heartbeat-stale ⇒ Tier-3 alarm. **The regress terminates at the human** (correct — the operator is the top of the escalation chain). On the VM, `cron` itself is the OS-level dead-man's-switch; if *cron* dies the host is in trouble, which is separately monitored.

This watchdog self-heartbeat is a **distinct signal** from the framework's *agent* registry heartbeat/TTL (DR-031): the agent stamps *"I am alive"*, the watchdog stamps *"the sweep ran"*. Both eye the registry, so to avoid **compounding** the App-token write-budget + the `macf#439` If-Match TOCTOU, the watchdog self-heartbeat writes a **distinct registry field on the _same_ If-Match path** as the agent heartbeat, at a coarse cadence — the two coexist without doubling write-contention.

### 5. `host-prelude` — re-establish the toolchain, don't inherit it

cron (and a container entrypoint) have a minimal env; `claude.sh` today *inherits* the user's login-shell toolchain, so cron can't find `claude`/`tmux`/`gh`. The watchdog, the cron line, and `claude.sh` all **source `host-prelude.sh` first**, which uses **absolute paths** (`eval "$(/home/linuxbrew/.../brew shellenv)"`) and so works from a bare env. This is **the same `host-prelude` slot DR-029's launcher template carries** (toolchain-detected at `macf init`: brew / devbox-nix / container-no-op) — extend it, do **not** fork a parallel prelude. Use the **dynamic** re-source form, not a frozen PATH snapshot, so it can't go stale.

### 6. K8s realization (future — the same contract, native backends)

When agents move to pods, the cron-watchdog is *replaced by native primitives*; the agent contract (`/health` + `restart-self`) is unchanged:

| concern | VM (this DR) | K8s |
|---|---|---|
| periodic trigger | user-level `cron` one-shot | **kubelet liveness probe** on `/health` |
| self-restart | detached `setsid`/`nohup` relauncher | exit PID 1 / liveness-fail (`restartPolicy`) |
| restart-loop → operator | watchdog threshold + alert issue | `CrashLoopBackOff` |
| env / toolchain | `host-prelude` (brew shellenv) | `host-prelude` no-op (image PATH) |

Deliverable: a liveness-probe + `restartPolicy` stanza in the agent Deployment manifest. The VM cron is explicitly **scaffolding that K8s's native liveness replaces.**

## Empirics — proven on this VM, not theory (from `macf-devops-toolkit#115` §10)

A real user-cron job (then cleaned up) established the VM realization is sound:
- user-level crontab runs as `ubuntu` / uid 1000 (the agent user);
- raw cron `PATH` lacks linuxbrew → `claude` is **MISSING** before the prelude, **FOUND** after (`/home/linuxbrew/.../claude`);
- cron reaches the default tmux socket `/tmp/tmux-1000/default` (not `PrivateTmp`'d here) → it can `kill`/`new`/`send` for restart + inject, and cron-created sessions are visible on operator login.

(If a host ever `PrivateTmp`'s cron, the fix is a fixed shared `TMUX_TMPDIR`.)

## Why not systemd (from `#115` §6)

`systemd --user` is elegant on the VM but **container-hostile**: no systemd in standard containers; it wants PID 1 + cgroup ownership; `systemctl --user` needs a user D-Bus + logind session containers lack. Choosing it **forces a two-mechanism split** (systemd on VM, something-else in container) — its elegance is a trap. `cron ⇿ kubelet-liveness` is the substrate-native 1:1 with **zero bespoke daemon**. (`s6`/`supervisord` is a valid single-supervisor-everywhere alternative but adds a daemon dependency; kept as a fallback only.)

## Heartbeat cadence — the answer to DR-031 Open-Q2

**Coarse (~5–10 min).** Rationale: once **graceful-deregister** (framework, DR-031 phase 1) lands, clean shutdowns keep the registry accurate-by-construction → the heartbeat/TTL is a **backstop for *ungraceful* death only** (crash, kill -9, OOM) — rare. So a coarse cadence keeps both the App-token write budget and the **`macf#439` register CAS/If-Match TOCTOU** exposure low (route the heartbeat write through the same If-Match path `#439` hardens). The heartbeat's remaining value is the **free-router staleness signal** (§1). Synthesis: graceful-deregister = the common case (accurate registry); coarse heartbeat/TTL = the rare-ungraceful-death backstop + the free-router signal.

## `restart-self` auto-commit safety (code's framework note 3, mirrored on the watchdog side)

The pre-kill commit Tier-2 triggers must be a **WIP-on-a-restart-marker** shape — a dedicated restart/RESUME ref or a clearly-marked WIP commit — **never an unmarked commit to the working branch**, so a restart never produces a surprising/unwanted commit on a feature branch. The verb's exact shape is the framework's to nail (DR-031 §Ownership); the watchdog must only invoke `restart-self` *after* confirming the commit/RESUME window elapsed, and must treat a restart that left an unmarked commit as a Tier-3 escalation (defensive).

## Sequencing (code's framework note 1)

The watchdog's detection-consumption depends on the two DR-030 `--json` CLIs (which land in **two phases** — §1) and on `restart-self` + graceful-deregister + TTL (DR-031 build, code). The **`/health` foundation is already merged** (`macf#572`, `/health` `state`+`otel`, 2026-06-26), and **`macf fleet doctor --json` (mesh) is in active build now** (DR-030 phase 1). So the order is: **framework lands `macf fleet doctor --json` + the DR-031 contract → the devops watchdog VM v1 consumes the mesh half → `macf routing doctor --json` (DR-030 phase 2) completes the full probe-chain.** VM v1 (Tier-1 gated inject + Tier-3 alert + self-heartbeat) is buildable as soon as `macf fleet doctor --json` merges — **not blocked on phase 2**; Tier-2 auto-restart is held behind operator sign-off regardless.

## Boundaries

- **DR-031** = the contract (consumed, not re-specified). **DR-030** = the detection (consumed via `--json`). **`macf#556`** = the shared dead-vs-alive probe. **DR-026 auditor** reasons *above* this floor.
- The **framework deliverables** (graceful-deregister, registry TTL, `restart-self` verb, `host-prelude` generator, `/health` hardening) are **code's** per DR-031 §Ownership — explicitly **out of scope** here.
- This DR = the **cron watchdog one-shot + the tiered ladder + idempotent cron registration + the watchdog self-heartbeat + the K8s liveness/`restartPolicy` manifests**, only.

## Ownership / build split (the devops slice of DR-031 §14)

- **This DR (devops, `macf-devops-toolkit`):** the cron watchdog; the tiered ladder with the Tier-1 Pattern-C gating; idempotent cron registration on `claude.sh` launch; the watchdog self-heartbeat; the K8s liveness/`restartPolicy` manifests; the upgrade-side rolling sequencer (consuming the framework version-check).
- **Depends on (framework/code, `groundnuty/macf`):** the `--json` detection CLI (DR-030); `restart-self` + graceful-deregister + registry TTL + the `host-prelude` generator + `/health` hardening (DR-031).

## Phasing (the devops slice)

1. **(framework first)** DR-030 `--json` CLI + DR-031 graceful-deregister/TTL/`restart-self`/`host-prelude` generator.
2. **Devops VM v1 (on `macf fleet doctor --json` — mesh-detection, landing now):** the cron watchdog with **Tier-1 (gated inject) + Tier-3 (alert) + the self-heartbeat**; idempotent cron registration on launch. **Hold Tier-2 (auto-restart) behind operator sign-off.** The full probe-chain (adding `macf routing doctor --json` registration-freshness) completes when DR-030 **phase 2** lands — v1 is not blocked on it.
3. **Upgrade dual-use:** the version-check driver (DR-029 `versions`) + the rolling sequencer (restart one → verify green via `macf fleet doctor` → next) — the automated form of the manual Stage-3 hand-relaunch.
4. **K8s:** the liveness/`restartPolicy` manifests when agents become pods; the agent contract is unchanged.

## Amendment A (2026-06-26): desired-state reconciler + cold-start + substrate scope

*From the operator's heterogeneous-fleet review + the cloud-substrate research (`research/2026-06-26-claude-code-on-anthropic-cloud-for-macf-agents.md`). Refines the Decision: the watchdog is a desired-state reconciler, not a bare liveness-restarter. Mirrors the DR-031 model amendment proposed on `macf-devops-toolkit#115`.*

### A.1 The watchdog is a desired-state reconciler

Reframe the cron one-shot from *"probe → if deaf, tiered-response"* to **"reconcile actual → desired state"** (the Kubernetes model). **Desired = the set of agents that should run on this host, operator-controlled.** Each sweep:

1. read **desired** (the per-host manifest, A.2) + **actual** (`macf fleet doctor --json` + a local process/tmux check);
2. desired-and-**not-running** → **launch** it (cold-start / reboot / first-bring-up);
3. desired-and-running-but-**deaf** → the tiered ladder (§"Tiered response": inject → `restart-self` → alarm);
4. **desired-down** (A.3) → **do nothing** (never resurrect).

This subsumes the four cases the operator raised: **cold-start / one-command launch-all** = reconcile from empty; **VM-reboot recovery** = the first post-boot sweep (A.4, automatic); **per-agent heal** = case 3 (the existing ladder); **don't-fight-the-operator** = case 4 (A.3). It is the K8s model (desired replicas vs running pods), so K8s realizes it natively (a Deployment); the VM cron is the tiny reconciler. **Launch (case 2) ≠ `restart-self` (case 3):** a never-started agent has no process to self-restart, so the reconciler **launches** it (detached `claude.sh`, same `host-prelude`); a present-but-deaf agent uses the verb.

### A.2 The desired-agents manifest (the new state the reconciler needs)

The reconciler needs a declarative **per-host desired-agents** source — the VM analog of a K8s Deployment spec: a small operator-owned manifest (e.g. `~/.macf/desired-agents.yaml`, `{agent, workspace}` per entry). **NOT derived from the registry** — that's *runtime* state (who's *currently* registered), not *desired* state. This is genuinely new config (which agents run on which host); on K8s it's the replica set.

### A.3 The intent signal — why the reconciler never fights a deliberate exit ("will cron fight me?")

**A bare liveness watchdog *would* fight you** — it can't tell "operator stopped it on purpose" from "it crashed," so it would relaunch a deliberately-exited agent. The reconciler doesn't, because **a deliberate stop updates desired state.** Mechanism: a per-agent **`paused`** marker (a manifest flag, or a `~/.macf/paused/<agent>` sentinel the operator drops). Paused = desired-down → the reconciler skips it (no launch, no restart) — exactly `kubectl scale deploy/<x> --replicas=0`. So **to stop an agent without a fight, pause it** (or remove it from desired); un-pause to resume. A plain `claude.sh` exit *without* pausing is still treated as a fault (relaunched) — correct, since "exited and didn't pause" is indistinguishable from a crash and the safe default is to restore the desired agent.

### A.4 Host-installed cron — survives reboot, runs on a cold box ("does the cron survive a VM restart?")

**Yes** — a user crontab persists in the cron spool across reboot and the cron daemon runs it at boot. But the catch *is* the launch-all use case: a rebooted VM has **zero agents**, and `restart-self` can't help (no agent alive to trigger it) — the reconciler must **launch**. So the watchdog cron must be **host-installed** (a one-time host-setup, persisting independently of any agent), **not** only "installed by `claude.sh` on agent launch" (§3 as written) — because on cold-boot nothing launches to install it. With the host-installed reconciler cron, the **first post-boot sweep launches the whole desired set automatically** — so the reconciler *is* the one-command launch-all **and** the auto-recovery-after-reboot, no separate mechanism. (§3's idempotent-on-launch registration stays as a self-heal for the entry; the host-install is what makes cold-boot work.)

### A.5 Passive tier reads `/health.last_processed` (local-receipt path — macf#581 / increment 1e)

The §"Tiered response" passive-delivery signal reads **`/health.last_processed`** — a true *local* mesh self-report (the channel server surfaces it from the local `processed-receipts.jsonl` the turn-receipt hook now writes, per DR-030 amendment macf#581 / increment 1e). This resolves the earlier locality precondition: passive is a real mesh self-report needing **no backend** (no Tempo round-trip), and `--inject` verifies against the same field.

### A.6 Substrate scope — VM + Kubernetes; Anthropic-cloud out-of-scope-*with-rationale*

This DR's reconciler/watchdog targets **VM (this DR) + Kubernetes** (the §6 manifests). **Anthropic-cloud substrates are out-of-scope with rationale** (not unsupported-by-accident), per the research doc: interactive cloud-code can't be a push-routed peer (no inbound / tailnet / persistence). **Managed Agents self-hosted** is a noted *future* path — it inverts delivery to a poll-queue (no inbound; tool-execution on our infra) and natively provides `workers_polling` liveness + `work.stop` + agent-versioning, so it could **replace much of this watchdog** for that substrate. A separate strategic spike, not in scope here.

### A.7 Upgrade is substrate-specific (mirrors the DR-031 capability matrix)

The §11-style upgrade-dual-use (`restart-self` + version-check + sequencer) is **VM-specific**. On K8s, upgrade is **GitOps** (bump the image → the controller reconciles a new Deployment revision; the agent is *passive*, just replaceable) — not a self-triggered restart. So the watchdog's *upgrade* role exists only on the VM substrate; on K8s the upgrade reconciler is GitOps, outside this DR. (Restart is universal — VM detached relauncher / K8s kubelet — but the *driver* differs.)

**Unification (per the DR-031 model, science's point):** "desired version" is just another facet of *desired state* — so the VM upgrade-driver (version-check → `restart-self` with new bits) is **the reconciler applied to the *version* dimension**, and the rolling sequencer is reconcile-one → verify-green → the-next. On K8s, desired-version is reconciled by GitOps (a new image) exactly as desired-replicas are. So the reconciler reconciles desired-**{set, version}** — the *set* on every substrate, the *version* via that substrate's upgrade mechanism.

## Consequences

- A silent fleet-block becomes a loud, escalating alarm — and most cases self-heal (Tier-1/2) before a human is involved.
- The watchdog is ~0 detection code — it consumes DR-030's `--json` — so the devops surface is the trigger + the ladder + the cron/K8s plumbing.
- A periodic cron job per VM host + an idempotent cron-registration step on launch; a small heartbeat write per sweep (coarse, negligible).
- The same machinery (`restart-self` + a sequencer) automates rolling fleet upgrades, retiring the manual hand-relaunch.

## Open questions

1. Tier-2 auto-restart gating beyond operator sign-off: inject-first vs. auto on confirmed-dead-and-idle after N failures (lean: inject-first, auto after N + idle).
2. Where the watchdog self-heartbeat is stamped — a registry field vs a known on-disk/observable path the operator dashboard reads (lean: registry field, so the router's free-detection and the operator both see it).
3. Alert-issue dedup for Tier-3 — one open alert per agent per failure-episode (don't spam on every sweep while an agent is down).
4. Cron cadence vs restart latency (paired with the heartbeat cadence above).

## References

`macf` DR-031 (the supervision contract — this DR realizes it) · `macf` DR-030 (interconnect detection — consumed via `--json`) · `macf` DR-026 F4 (`macf monitor` — the reasoning layer above) · `macf` DR-029 (launcher-template `host-prelude` slot + the `versions` block) · DR-004 (the native-k3s VM this watchdog runs on) · DR-005 (Stage-3 channel infra + the registry) · silent-fallback-hazards Instance 3 (RC-bound tmux send-keys — the Tier-1 gating rationale) · `macf#553` (collision / graceful-deregister / TTL) · `macf#556` (dead-vs-alive `/health` / `registry prune`) · `macf#572` (the merged `/health` `state`+`otel` foundation) · `macf-devops-toolkit#115` (the design session + §10 cron-prelude empirics + §6 why-not-systemd).
