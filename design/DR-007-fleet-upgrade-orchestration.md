# DR-007: Fleet-upgrade orchestration — deterministic, runtime-portable, busy-aware

**Status:** Proposed
**Date:** 2026-07-01
**Trigger:** Operator design session (2026-07-01). Fleets are growing (2 → 4–5 agents) and upgrades are getting more frequent, so "ask an agent to upgrade the fleet" needs to become **operationally deterministic**: one command that upgrades a whole fleet's framework version *and* restarts its sessions, on **Linux and macOS now**, **Kubernetes-compatible by design** (a future *macf operator*, never `kubectl rollout restart`), and — non-negotiable — **never interrupting an agent that is mid-work**.

Builds directly on **DR-006 §A.7** (upgrade = the reconciler applied to the *version* dimension of desired state; the VM upgrade-driver = version-check → `restart-self` with new bits → rolling verify-green-before-next) and **`macf` DR-031** (the `/health` liveness + `restart-self` contract). DR-006 §A.7 established the *concept*; this DR is the *orchestration design* — the multi-fleet reality, the decision/driver boundary that makes it runtime-portable, the `/health` contract additions it needs, and the build split.

---

## Context — the hard parts are already built

The instinct in the operator session ("`macf ps` for a global view + version, then a `fleet` subcommand to select and upgrade") is the right shape, and most of the load-bearing machinery already exists:

| Primitive | What it gives | Runtime-portable? |
|---|---|---|
| `macf update` | per-workspace upgrade — bump version pins + regenerate `claude.sh` | ✅ node/npm |
| `macf restart-self --confirm` | per-agent **clean restart, no work lost** — detached relauncher outlives the session (DR-031) | ✅ tmux |
| `macf fleet status` | roster + online/offline + **idle/busy per agent** ("busy 1m on turn 73") + uptime + cert-expiry | ✅ mTLS `/health` self-report |
| reconcile.sh aliveness-gate (#128/#130) | structurally **aborts a restart of a busy agent** (capture-pane-diff) | ❌ VM /proc+tmux |
| `#627` graceful-deregister (`mcp-stdin-close`) | clean exit → deregister before the process dies | ✅ (= a K8s preStop hook) |
| `macf ps` | host process view (running/not, cwd, identity) | ❌ **Linux /proc only; no version; no `--json`** |
| `fleet/upgrade.sh` (devops WIP) | DR-006 §A.7 rolling upgrade — detect+plan built; execute-path unfinished | ❌ Linux (reuses reconcile.sh) |

**The genuinely hard problems — restart-without-losing-work, per-workspace upgrade, and busy-detection — are solved.** What is missing is a thin *orchestration* layer, one *visibility* gap (version), and *runtime portability*.

---

## Decision — a decision/driver split on the `/health` self-report substrate

The design has exactly two layers, and **only the bottom one is runtime-specific**. Getting this boundary right is the whole DR: it is what makes Linux, macOS, and the K8s future fall out of one design instead of three.

### 1. Decision layer (runtime-agnostic) — drives off self-reported state, never `/proc`/tmux/kubectl

The orchestrator reads `macf fleet status` (`/health` self-report: roster, version, idle/busy), computes who-is-behind-target, and drives the **rolling sequence**: for each agent → **busy-gate** → upgrade → restart → **verify-green** → next. It **never** touches the process table, tmux, or the Kubernetes API directly — it calls the driver. This layer is identical whether the agent is a VM tmux session or a K8s pod, because both **register and serve `/health`**.

### 2. Driver layer (pluggable, per-runtime) — the only place the runtime leaks

| Concern | VM driver (Linux/macOS) | K8s driver (future — the *macf operator*) |
|---|---|---|
| upgrade version | `macf update` (bump pin) → new bits on relaunch | operator patches the agent's desired image/version |
| restart cleanly | `macf restart-self` (detached relauncher / tmux) | operator terminates the pod → scheduler reschedules on the new version |
| busy / idle | **`/health` self-report** | **same `/health` self-report** |
| version source | **`/health.version`** | **same `/health.version`** |
| alive vs dead | exit-code intent (DR-006 B.1) | pod phase |

**Hard rule the DR locks:** nothing runtime-specific leaks above the driver line. My current `fleet/upgrade.sh` violates this (it reuses reconcile.sh's `/proc` + capture-pane) — acceptable as the *VM reference impl*, but the *canonical* orchestrator must not, or K8s means a rewrite.

### 3. The `/health` contract is the universal substrate — it needs `version`

The decision layer stands on two self-reported facts, one of which is missing:

- **idle/busy** — ✅ already reported (`fleet status` STATE: "idle 0s on turn 3" / "busy 1m on turn 73"). This is the operator's don't-interrupt signal, self-reported, cross-runtime, **no `/proc` needed**.
- **framework version** — ❌ **not exposed anywhere.** Neither `macf ps` nor `macf fleet status` shows the version each agent runs, so you can't see who's behind → can't target an upgrade. **The one true blocker.** Fix: **add `/health.version`** (the agent self-reports its running framework version) + surface it as a `VERSION` column in `fleet status`/`ps` + `--json`. `/health.version` is the *right* source precisely because it is runtime-portable (a VM's installed pin and a pod's image tag both answer the same probe) — as opposed to reading the workspace's `macf-agent.json`, which is VM-only.

### 4. A "fleet" = the agents registered in ONE GitHub registry repo (operator ad3)

The multi-tenant reality on a single host (confirmed by `macf ps`: MACF, `icsoc-2026`, `vht-*`, CV agents all coexist): **one VM hosts multiple fleets, each registered in a *different* GitHub registry repo, each pinning its own framework version.** So a "fleet" is `{name, registry-repo, agents, version-target}`, and:

- **Selection targets a registry**, not a filter on one roster. `macf fleet upgrade --fleet <name>` (or `--registry <owner/repo>`) picks which registry's agents to roll.
- **Version-target is per-fleet** — upgrading the MACF fleet must not touch the CV fleet; each fleet advances independently.
- **`macf ps` is the host-global view** (all fleets' processes); the fleet selector narrows to one registry's agents. `macf fleet status` today operates on the *current workspace's* registry — multi-fleet needs an **explicit fleet/registry selector** and a way to **enumerate the fleets on a host** (see Open Questions).

### 5. Multi-select — default one, allow a few (operator ad4)

The common case is **one fleet at a time** (the operator's stated intent), so that is the default and the safe path. But the selector should accept a **list** (`--fleet a,b,c`) for the "upgrade several at once" case — rolled fleet-by-fleet (each fleet's verify-green gates the next), not interleaved, so a bad release still stalls at the first failure within the first fleet.

### 6. The upgrade state machine (per agent — rolling, busy-gated, verify-green)

```
for each agent in the selected fleet(s), ONE AT A TIME:
  read /health.version
  if version >= target:            → skip (already current)
  else:
    assess /health idle/busy:
      busy  → SKIP + REPORT ("not upgrading <agent> — busy on turn N")   ← operator's don't-interrupt floor
              (optionally: --wait → poll for idle up to a bound, then proceed or report-and-move-on)
      idle  → proceed:
                driver.upgrade(agent)     # macf update  |  operator patches version
                driver.restart(agent)     # restart-self |  operator cycles the pod   (alive→graceful, dead→launch)
                verify /health.version == target AND agent healthy (reachable+accepting)
                  green → continue to next agent
                  not-green within timeout → HALT the roll + alert (a bad release stalls at agent 1;
                                             it cannot take the whole fleet down at once)
```

- **Busy-gate is the operator's hard requirement**, and it is satisfied *twice*: the decision layer reads self-reported busy and **skips+reports** (or `--wait`s), and the VM restart driver's aliveness-gate (#128/#130) structurally refuses to kill a busy pane as a backstop.
- **Verify-green-before-next** is the determinism guarantee — rolling one-at-a-time with a health gate means a bad version can't brick the fleet.
- **alive vs dead** rides DR-006's exit-code intent: an alive agent gets a graceful `restart-self`; a not-running desired agent is launched at the new version (`last-exit==0`/`/exit` stays down — don't fight a deliberate stop even mid-upgrade).

### 7. The busy-gate is *why* the orchestrator exists on every runtime — including K8s

A naive `kubectl rollout restart` (or any stock rolling update) **evicts pods regardless of agent-busy-state** — it would kill an agent mid-turn. That is exactly the operator's "we will **not** be using `kubectl rollout restart`" and "we will have a **macf operator**." The **macf operator is the K8s driver**, and it must drive the roll **pod-by-pod, idle-gated on `/health`** — which is the *same decision logic* as the VM orchestrator, just a different driver. This is the strongest argument that the orchestrator is its own runtime-agnostic thing, not a shell-out to the platform's rolling primitive. (The K8s pieces that already map: `/health` = liveness/readiness probes; `#627` graceful-deregister = a preStop hook; verify-green = a readiness gate on the new pod.)

### 8. Unattended depends on `macf#645`/DR-033 — needs pushing (operator ad5)

A relaunched agent **hangs at the channels / resume launch-prompts** until DR-033's auto-responder (`macf#645`/`#646`, code-agent building) clicks through them. So:

- **Attended** fleet-upgrade works **today** — the operator clears the launch-prompts as each agent comes back.
- **Unattended** (a scheduled/self-driven fleet-upgrade) is **BLOCKED on `#645`.** Per the operator ("need to push it"), `#645`/DR-033 is on the critical path for the unattended capability and should be prioritized. Flagged as an explicit cross-agent dependency (below).

---

## Build split & ownership

| Piece | Owner | Notes |
|---|---|---|
| `/health.version` self-report | **code-agent** | the one true visibility blocker; runtime-portable version source |
| `VERSION` column + `--json` in `fleet status` / `ps` | **code-agent** | so you can *see* who's behind |
| `macf fleet upgrade` (canonical orchestrator + fleet/registry selection + multi-select) | **code-agent** | cross-platform/cross-runtime; the decision layer; rides `fleet status` + `update` + `restart-self`, never `/proc` |
| `macf ps` macOS support | **code-agent** | Linux `/proc` → macOS `ps`/`lsof`/libproc (or fold host-view into `fleet status`) |
| the **macf operator** (K8s driver — idle-gated pod roll) | **code-agent / science** | far-future; consumes the identical `/health` contract; NOT `kubectl rollout restart` |
| `#645`/DR-033 auto-responder (unattended unblock) | **code-agent** | on the critical path for unattended — push it |
| **DR-007** (this) | **devops** | the design + the decision/driver boundary + the `/health` contract asks |
| **finish `fleet/upgrade.sh`** (Linux VM reference impl / operational proof) | **devops** | the attended VM path *today*; the reference for the canonical subcommand |
| the rollout runbook (fleet-upgrade section) | **devops** | folds into `ROLLOUT.md` |

The canonical CLI + operator are code-agent's (the framework); a **`macf` DR** may be warranted for the `macf fleet upgrade` + `/health.version` contract + the operator — that is code/science's call, and this DR is the devops-side design + the delegation trigger.

---

## Phasing (each phase is independently useful)

1. **Attended VM fleet-upgrade (now-ish):** `/health.version` + `VERSION` column (code) **·** finish `fleet/upgrade.sh` execute-path (devops). → one command rolls a fleet, busy-gated, verify-green, with the operator clearing launch-prompts.
2. **Canonical + cross-platform:** `macf fleet upgrade` (code) — Linux + macOS from one code path; fleet/registry selection + multi-select.
3. **Unattended:** `#645`/DR-033 lands → the roll needs no human at the launch-prompts.
4. **K8s (far-future):** the macf operator implements the same idle-gated roll as the K8s driver.

---

## What's built vs gaps (the "how far from satisfaction" answer)

**Built:** `macf update` · `macf restart-self` · `macf fleet status` (incl. idle/busy) · reconcile.sh aliveness-gate · `#627` graceful-deregister · `fleet/upgrade.sh` detect+plan · the DR-006 §A.7 concept.

**Gaps:** `/health.version` + `VERSION` visibility (code) · the orchestrator loop / `fleet/upgrade.sh` execute-path · fleet-registry selection + enumeration (multi-fleet) · macOS `macf ps` · unattended (`#645`) · the K8s macf operator (far-future).

**Distance:** the hard parts are done; ~2 focused pieces of net-new work (version-visibility + the orchestrator loop) get **attended, single-fleet, VM** working; the rest is portability (macOS/K8s) and unattended (`#645`).

---

## Boundaries / non-goals

- **Not** a new supervisor — it composes DR-006's reconcile machinery + DR-031's `restart-self`. (Version is just another facet of desired state — DR-006 §A.7.)
- **Not** `kubectl rollout restart` or any stock rolling update on K8s — the busy-gate forbids it; the macf operator drives idle-gated.
- **Not** the macf operator's design — that's a future code/science DR; this DR only fixes it as *the K8s driver* consuming the same `/health` contract.
- **Not** unattended-by-default — unattended waits on `#645`; attended is the shipping default.

---

## Open questions (for review)

1. **Fleet enumeration on a host** — how does the orchestrator *list* the fleets present (name → registry-repo → agents)? **Resolved (science review):** DERIVE it — scan the host's workspaces, group by the registry each `macf-agent` config points at. A host-level hand-maintained `~/.macf/fleets.yaml` was rejected: it's a *new, 4th source of truth* that drifts when a fleet is added/removed (`check-before-propose.md §4` — don't build a parallel config when the state has a home). The host already knows its fleets (each workspace names its registry); an optional explicit override is an escape-hatch only. Deriving-from-existing beats a registry-of-registries.
2. **Version-target source per fleet** — npm-latest at run time, or an explicit pin per fleet (`--target <ver>` / a per-fleet config)? Lean explicit-pin-with-`--target`-override (deterministic > "whatever's latest today").
3. **Multi-select ordering / parallelism** — fleet-by-fleet serial (safe, proposed) vs bounded parallel across fleets. Serial for v1.
4. **Version comparison** — semver-compare `/health.version` vs target. **Resolved (science review):** reuse the bash semver-compare code-agent shipped for `macf-bootstrap`'s `compatibility.macf` (`macf#660`) — arithmetic per-component with pre-release handling — not a fresh impl.

---

## Review refinements (science, 2026-07-01)

- **Composition with DR-036 (guest-safety, free from registry-keyed selection):** because a "fleet" == its registry and a *guest* lives in a *different* registry, fleet-upgrade selects registry **members** and therefore **never touches guests** — a consumer doesn't supervise OR upgrade a guest (the same visibility-vs-supervision invariant). Worth stating: the registry-keyed selection gives this correctness for free.
- **A `macf` DR should carry the framework contract; DR-007 is the trigger.** The split mirrors DR-030 (macf: fleet-health *commands*) / DR-031 (macf primitives + devops watchdog cron). The **decision/driver *interface* is itself a framework architecture decision (a macf primitive)** — so `/health.version`, the `macf fleet upgrade` runtime-agnostic decision-layer + the *driver interface*, and (far-future) the macf operator belong in a **`macf` DR** authored by code/science, with DR-007 as the trigger + design source. DR-007 (devops) stays the orchestration design + the VM reference impl + the delegation trigger. (The macf operator remains its own future code/science DR — scoped out here.)
- **§8 unattended nuance:** DR-033 auto-answers only *ceremony* prompts (channels/resume). A *permission/trust* prompt during a relaunch still **blocks-and-reports** (`#132`, report-not-answer). So unattended fleet-upgrade needs the relaunch to be **ceremony-only**; if a release ever introduces a new trust/permission prompt at launch, unattended stalls-and-reports by design (correct, not a regression).

---

## Amendment A (2026-07-01): the host-local operational plane — registry-free enumeration

*From an operator follow-up: "how can I, without depending on any repository, on macOS or Linux, list all my macf agents alive or dead and reason about (or execute) an upgrade? On K8s the operator/labels do the trick, no problem there."* This sharpens a distinction §1–§4 blurred.

**Two planes, not one:**

- **The routing/delivery plane = the registry** (per-fleet GitHub org-vars). Its job is *reachability* — agents publish `host:port` so the router can dial them. It only knows **registered/alive-ish** agents, needs a **repo + network + auth**, and is **per-fleet** (N round-trips for N fleets). This is where a "fleet == a registry" (§4) lives — correct for routing + upgrade *selection isolation*.
- **The host operational plane = a LOCAL scan.** "What macf agents live on *this box*, alive or dead, at what version" is a **purely local** question — no repo, no network. The host already holds every fact locally:

  | Fact | Local, registry-free source |
  |---|---|
  | which agents exist here | scan for workspaces carrying a `.macf/` marker (+ the local `desired-agents.yaml`) |
  | alive vs **dead** | union with the running process table → present=alive, absent=**dead** |
  | version | the **on-disk pin** (`.macf/plugin/…/plugin.json`) — no `/health` call |
  | busy vs idle | the **tmux pane** (capture-pane-diff) — no `/health` call |
  | upgrade + restart | `macf update` + local relaunch |

**Consequence — the VM upgrade is registry-INDEPENDENT, exactly like K8s.** The decision layer should **enumerate + reason from the host-local plane** (alive/dead + version + busy — all local), and touch the registry ONLY for the routing it's actually for (or not at all on a pure-local upgrade). On K8s this plane is the **control plane** (`kubectl get pods -l app=macf` → alive/dead + image version, operator + labels) — free, no VM-equivalent problem. On a VM, **`macf ps` IS this plane** — the analog of `kubectl get pods -l`.

**This resolves OQ1 in the registry-free direction** (derive-from-workspaces, not a hand-maintained registry-of-registries) and *is why*: enumeration must not depend on any repo.

**`macf ps` gaps to be the full host-local view (→ macf#682):**

1. **Dead agents too** — today `ps` lists only *running* processes (a pure `/proc` scanner). The host-local view must union running-processes with **known agent workspaces** (the local `.macf`/`desired-agents.yaml` markers — NOT the registry) and mark each **alive/dead**. This is the load-bearing addition for "list all my agents alive or dead." **The workspace-scan is scoped to configured root(s)** (`MACF_WORKSPACE_ROOT`, per the #682 discovery agreement) — **NOT a whole-filesystem walk** — so a big host doesn't pay a full-FS scan per `ps` (science's #141 note).
2. **Version** — ✅ *already shipped* in code's #683 (Phase 1): `macf ps` resolves version **locally, network-free** (cs process → on-disk `package.json`) — exactly this plane's principle. (Works for a dead agent too, from the pin.)
3. **macOS** — the workspace scan is filesystem-portable; only the alive-match needs `ps`/`lsof` instead of `/proc` (Phase 3).

So: **`macf ps` (extended: alive+dead, versioned, cross-platform) is the operator's "list all my agents without a repo" view** — the VM control-plane. The registry stays the routing plane; the two never conflate.

---

## Amendment B (2026-07-01): the distribution contract — how the operational work reaches the VMs

*From an operator follow-up: "how do we deliver the operational work to the agents on multiple VMs, when the only thing we distribute today is the macf binary?"* This DR (and DR-006) produced substantial VM tooling that currently lives as **reference implementations in `macf-devops-toolkit:fleet/`** — which the VMs never receive. The contract that closes the gap:

**The macf binary IS the delivery channel — so a capability must live *in* the binary, not beside it.** Three homes, by kind:

| Kind | Home | Distribution |
|---|---|---|
| **Capability** (the upgrade orchestrator, the watchdog reconciler, resume/nudge-report, restart-self, install-cron) | a **canonical `macf` subcommand** | rides the **npm package** → every VM via `npm i -g` + `macf init`/`update` (already the channel) |
| **Per-VM config** (`desired-agents.yaml`, cron schedule, endpoints, alert-repo) | **local on each VM** | provided by `macf init`/bootstrap per VM — NOT one-size distributed |
| **Cluster-side** (the watchdog-heartbeat PrometheusRule, dashboards) | the **gitops repo** | argocd → the monitoring cluster (already solved) |

**Consequences:**

- The devops `fleet/*.sh` are **reference implementations + the interim** (VMs clone the repo until the subcommands land), NOT the distributed artifact. The distributed artifact is the CLI. This is the DR-007/DR-006 **build-split** generalized to *delivery*: devops designs + proves; the canonical `macf` subcommand is what ships.
- **Already in motion:** `macf fleet upgrade` (`macf#682`) + `restart-self` session-safety (`macf#685`). **The rest** — `macf watchdog reconcile`, `macf fleet resume`, `macf watchdog install-cron` — filed as `macf#686` (the VM-operational-layer promotion). Implementation language (bash-wrap vs native TypeScript) is code-agent's call.
- **The recursion:** once `macf fleet upgrade` is distributed, *it* is how future macf-binary updates roll across the fleet; `macf init` bootstraps a new VM. **`init` seeds; `fleet upgrade` sustains.**
- **This contract belongs equally in the forthcoming macf DR** (the framework-contract DR science recommended) — "capability-in-CLI / config-local / cluster-via-gitops" is a *distribution contract*, a framework-level architecture decision, not a devops-toolkit detail.

---

## Cross-references

- **DR-006 §A.7** — upgrade = version-dimension reconcile; VM upgrade-driver + rolling sequencer (this DR's parent).
- **DR-006 B.1–B.3** — exit-code intent (alive/dead), graceful-restart keys-on-liveness, `#627` deregister.
- **`macf` DR-031** — the `/health` + `restart-self` contract this rides.
- **DR-033 / `macf#645`,`#646`** — the launch-prompt auto-responder; the unattended blocker.
- **`macf#556`** — `macf ps` (the host process view this extends with version + macOS).
- **`#128`/`#130`** — the aliveness-gate (busy-detect backstop).
