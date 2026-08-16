# DR-009: API-driven runner provisioning via Actions Runner Controller

**Status:** Proposed
**Date:** 2026-08-14
**Trigger:** Operator design review (2026-08-14) while designing declarative fleet provisioning (DR-043 / `macf#838`): *"I really didn't want to have as part of fleet provisioning a moment when you have to provision runners."* The VM-based fleet from DR-003 works, but it can only be provisioned by SSH + `make` + operator credentials against one specific machine — which is exactly the step a declarative bootstrap cannot take.
**Extends:** DR-003 (self-hosted GitHub runner, VM/systemd). **DR-003 is NOT superseded** — per the operator decision of 2026-08-14 the VM fleet stays permanently, and ARC is an additive second tier serving new fleets (§7).
**Tracking:** `groundnuty/macf-devops-toolkit#184` · cross-repo blocker `groundnuty/macf-actions#72`

---

## 1. Context — what breaks at fleet scale

`runner/runners.yaml` is a good registry: one entry generates its make targets, tab-completion, and var-copy, with nothing hardcoded. Four runners run live under it today, serving real routing traffic (9 jobs in a representative 2-hour window, all green).

It does not survive contact with declarative fleet provisioning, for three reasons:

1. **It needs operator credentials.** Registration requires `administration:*`; the bot is permanently 403 there (verified again 2026-08-14 across all four repos). That is a deliberate safety property, not an oversight — so the runner step is the one part of fleet bootstrap an agent *cannot* execute.
2. **It needs a specific machine.** Provisioning is `ssh` + `make runner-<name>` against the agents VM, with systemd units and `/mnt/volume1` state. Nothing about that is expressible as fleet intent.
3. **It is hard to destroy and re-create.** Testing a fleet means tearing runners down and standing them back up. Today that is a privileged, stateful, per-VM operation.

### The constraint that does *not* go away

`groundnuty` is a **User** account (`type=User`; `/orgs/groundnuty` 404s). Per GitHub's docs, *"Repository-level runners are dedicated to a single repository,"* and org-level runners — the only shared kind — require an organization. Runner **groups** additionally appear to require GitHub Team.

Therefore **one runner registration serves exactly one repo**, and a repo may have any number of runners. The constraint is *scope*, not *count*. "One runner per fleet" is impossible here; "N runners per repo" is freely available. No design below changes this — ARC makes runners disposable, not fewer.

Also load-bearing: a runner processes **one job at a time**. Observed directly — two `macf` router runs 26s apart, the second starting 23:20:17, two seconds after the first finished at 23:20:15, zero overlap. Parallelism comes from runner count, never from a single runner.

---

## 2. Decision 1 — Actions Runner Controller, not a bespoke provisioning API

The considered alternative was a small tailnet-exposed HTTP service with `register` / `unregister` / `status` endpoints.

**Rejected.** Those four operations (with `list`, which the sketch omitted and which idempotency, teardown, and drift-detection all require) are exactly the semantics of a Kubernetes resource. ARC provides them already:

| Operation | Mechanism |
|---|---|
| register | `apply` an `AutoscalingRunnerSet` |
| unregister | `delete` it |
| list | `get` |
| status | the CR status subresource + ARC listener state |

Building the facade means writing idempotency, status-truth, and authentication ourselves, on day one, in a service that would itself become a fleet component needing provisioning — and which would hold a GitHub App with `Administration: Read and write`. An unauthenticated version of that on the tailnet is a materially different object from our unauthenticated Grafana: Grafana can only be read, whereas this could mint or destroy runners across every repo.

A thin facade remains open as a **later** addition once the semantics have proven themselves, including one that performs commits on our behalf if that turns out to be wanted. It is explicitly not a starting point.

---

## 3. Decision 2 — two layers, two different drivers

The seam that makes this tractable:

**Platform layer** — installed once per cluster, changes rarely, **GitOps / argocd**:
- ARC controller (`gha-runner-scale-set-controller`)
- the `coredns-custom` `ts.net` stanza (§5)
- namespace, RBAC, and the namespace-scoped ServiceAccount the bootstrap authenticates as
- secret *scaffolding* (never the secret itself)

**Runner layer** — one `AutoscalingRunnerSet` per agent repo, churning as fleets come and go, **API-driven, NOT GitOps**. Fleet bootstrap talks to the Kubernetes API with a ServiceAccount token. It does **not** commit to a repo — that was the operator's explicit objection to a GitOps-only design, and it is honoured here.

---

## 4. Decision 3 — a separate platform repo: `groundnuty/runner-platform`

**Note the reasoning, because the obvious justification is wrong.** Cluster portability comes from the argocd `Application`'s `destination`, not from repo boundaries — a self-contained *directory* in this repo would be equally portable across clusters.

The real reasons to split:

- **Reuse without inheritance.** The CV and icsoc fleets will want a runner platform. They should not have to take our observability stack (Tempo, Langfuse, kube-prometheus, argocd bootstrap) to get one.
- **Independent lifecycle.** The platform layer is small and stable; this repo's contents are neither.
- **Smaller grant.** Anything that needs to read the platform manifests gets a small dedicated repo, not the whole devops toolkit.

The name is deliberately **fleet-agnostic** (`runner-platform`, not `macf-runner-platform`) because a `macf-` prefix would imply macf-only ownership and discourage the reuse that motivates the split.

**Portability is a property to be maintained, not assumed.** The repo must parameterise every cluster-specific value (GitHub config URL scope, MagicDNS resolver address, storage class, node selectors, `minRunners`) and must not hard-depend on our observability CRDs — a chart that assumes `ServiceMonitor` exists will not install on a bare cluster. A nominally-separate repo that only works on one cluster is the worst of both.

---

## 5. Verified: the network path works, with one fix

The k3s cluster runs on the monitoring VM; agents and their channel-servers are on a separate VM, reached over Tailscale. Routing jobs must POST to those channel-servers, so pod→tailnet reachability decides whether this design is viable at all. Probed 2026-08-14 from a throwaway pod in the live cluster:

```
TCP  100.124.163.105:22                      → OK
ICMP 2 packets transmitted, 0% loss, avg 3.3ms
nslookup orzech-dev-agents.tail491af.ts.net             → NXDOMAIN
nslookup orzech-dev-agents.tail491af.ts.net 100.100.100.100
                                                        → 100.124.163.105
```

**Routing works out of the box** — pods reach the tailnet through the node's interface, at ~3ms. **MagicDNS does not resolve**, because CoreDNS forwards to the host's `/etc/resolv.conf` (`nameserver 127.0.0.53`), a systemd-resolved stub that only exists in the host's network namespace.

Because pods *can* route to the tailnet, they can query Tailscale's resolver directly. The fix is one server block:

```
ts.net:53 {
    errors
    cache 30
    forward . 100.100.100.100
}
```

Delivered via the **`coredns-custom` ConfigMap**, not by editing the managed Corefile — k3s reconciles that file and reverts direct edits. This keeps the fix declarative and part of the platform layer.

Using raw tailnet IPs instead was considered and rejected: this repo's own convention is to reach hosts by MagicDNS name precisely because the IPs are mutable.

---

## 6. Decision 4/5 — credential and host

**A new dedicated GitHub App** (`macf-runner-provisioner`) rather than extending the devops-agent App.

**Provisioned and verified 2026-08-16** (operator-created; the blocker is cleared):

| | |
|---|---|
| App | `macf-runner-provisioner`, owner `groundnuty` |
| App ID | `4613177` (Client ID `Iv23liDfFLotsU87OjzE`) |
| Installation ID | `154151387` |
| Private key | `orzech-dev-agents-monitoring:~/runner-provisioner.pem` |
| `repository_selection` | `all` |
| Permissions | `administration: write`, `actions: read`, `metadata: read` |

Verified by minting a real installation token against the live API — not read off the settings page. `administration: write` is exactly what repo-scoped ARC requires, and the devops-agent App keeps its deliberate 403, so the blast-radius separation §6 argued for is intact.

Two notes for whoever operationalises this:

- **The key was mode `644` (world-readable to any user on that VM) and is now `600`.** It is a private key with `administration: write` across the account; anything less than `600` is a finding in its own right.
- **`repository_selection: all` is a deliberate testing posture** (operator: *"it's for the whole account, not a single repository… we are fine with it at the moment while we are testing"*). It is broader than this DR's steady-state intent: a dedicated App scoped to *all* repos can administer any repo in the account, so the separation achieved is from the devops bot, not from the rest of the fleet. **Narrowing the installation to the canary repo is the tightening step** once the spike proves out — worth doing before anything long-lived depends on it.
- The key currently lives in a home directory on the monitoring VM. Per this section its destination is a **Kubernetes Secret** referenced by `githubConfigSecret`; the VM copy should be removed once the Secret exists, so the credential has one home rather than two. Repo-scoped ARC needs `Administration: Read and write`; granting that to the devops bot would permanently widen its power across every repo it is installed on and destroy the 403 that currently makes runner operations deliberately operator-gated. The new App's credential lives only as a cluster Secret, referenced by `githubConfigSecret`. (Org scope would need only `Self-hosted runners: R/W` — one more small argument for the org path if it is ever taken.)

**Host: the observability k3s cluster — a deliberate compromise, not the ideal.** Operator ruling, 2026-08-15: *"we are deploying it on the observability Kubernetes, we are not deploying another cluster"*, and — stated in the same breath — *"normally it would be ideal to have a dedicated cluster, I agree, but at the moment we are compromising."*

Both halves are load-bearing, so record them together:

- **The target state is a dedicated runner cluster.** Collocation is accepted for cost and operational simplicity — a second cluster means another failure domain, another upgrade cadence, another provisioning step — not because sharing is better.
- **It is therefore not "spike-scoped, revisit before cutover"** (the earlier framing, now retired) **nor permanent.** It is a compromise held until a dedicated cluster is worth its overhead.

An interim revision proposed moving to a dedicated cluster on the agents VM immediately, reading the decoupling constraint as a mandate for *physical* separation. That over-read it: the constraint is about **dependency**, not **location**. Sharing a cluster by accident is exactly what the operator described.

**This is precisely why §6.1 is a hard invariant rather than a style preference.** The decoupling rule is what makes the compromise safe *now* and what makes the eventual move cheap *later* — if nothing in the runner platform depends on the observability stack, relocating it is a redeploy against a different `destination`, not a migration. **Every coupling admitted today is a tax on the move to the ideal.** That is the standard §6.1 has to be enforced against.

**Correction (2026-08-15):** an earlier revision claimed `/mnt/volume1` on the monitoring VM was "at 72%" and used it as a reason to revisit hosting. **That figure was wrong — it came from a `df` run on the *agents* VM (where the DR-003 runners live) and was misattributed to the monitoring host.** Measured directly over ssh:

| | monitoring VM | agents VM |
|---|---|---|
| `/mnt/volume1` | **36G of 196G (19%)** | 134G of 196G (72%) |
| `/` | 7.3G of 96G (8%) | 84G of 96G (87%) |
| mem available | 46 GB of 55 | 39 GB of 55 |

The monitoring cluster has ~160 GB free and 46 GB RAM available — ample. The disk pressure is on the *agents* VM, which is where the VM-tier runners already live.

**Correction (2026-08-15):** an earlier revision of this paragraph claimed `/mnt/volume1` on the monitoring VM was "at 72%" and used it as a second reason to revisit. **That figure was wrong — it came from a `df` run on the *agents* VM (where the DR-003 runners live) and was misattributed to the monitoring host.** Measured directly over ssh:

| | monitoring VM | agents VM |
|---|---|---|
| `/mnt/volume1` | **36G of 196G (19%)** | 134G of 196G (72%) |
| `/` | 7.3G of 96G (8%) | 84G of 96G (87%) |
| mem available | 46 GB of 55 | 39 GB of 55 |

So capacity is **not** an argument against the monitoring cluster — it has ~160 GB free on the data volume. The disk pressure is on the *agents* VM, which is where the VM-tier runners already live. **The only real reason to move the runner platform off the monitoring cluster is the coupling concern in §6.1**, and that reason should stand or fall on its own rather than borrowing a resource argument that was never true.

### 6.1 Decoupling invariant — collocation must stay accidental

**Operator constraint, 2026-08-15:** the runner platform and the observability stack must have **no relationship beyond sharing a host by accident**. The runner platform must never become a dependant of Prometheus, Grafana, Tempo, Langfuse, or argocd-the-observability-bootstrap.

§4 already states the repo-level half ("must not hard-depend on our observability CRDs — a chart that assumes `ServiceMonitor` exists will not install on a bare cluster"). This section states the operational half and the test.

**The acceptance test for every artifact in `runner-platform`:**

> Does it install and run on a **bare k3s cluster with no observability stack present**?

If the answer is no, the artifact is coupled and must be changed. Concretely, the three places coupling would otherwise creep in:

1. **The queue-time instrument (criterion 0) — the highest risk, because it is the one thing that genuinely wants a metrics backend.** It must **expose** metrics (a `/metrics` endpoint, or a plain queryable record) and must not **require** a scraper. kube-prometheus-stack may *consume* it where one happens to exist; the instrument must remain fully functional without it. A `ServiceMonitor` may ship, but only as an optional, flag-gated extra that is absent by default. **Observability is a consumer of the runner platform, never a dependency of it.**
2. **The `coredns-custom` `ts.net` stanza (§5).** This is coupling to the *cluster*, not to observability — it exists so runner pods can resolve the agents' channel-servers. It travels with the runner platform if it moves, and it is a no-op for anything else on the cluster. Acceptable, but it must live in `runner-platform` so a move carries it, never in `environments/macf/`.
3. **Shared argocd.** If the platform is delivered by the monitoring cluster's argocd instance, that instance becomes a dependency. Acceptable for the spike since argocd is a delivery mechanism rather than a runtime one — but the manifests must be plain enough that `helm install` / `kubectl apply` works without argocd at all, which is also what makes the repo portable per §4.

**Direction of dependency, stated once:** runner tier → *may report to* → observability tier. Never the reverse, and never a runtime dependency in either direction. Concretely for §7.4: **hibernation and scale-up decisions must keep working when Prometheus is down** — they read from the GitHub API and ARC's own state, never from the observability stack.

**Consequence:** because nothing in the runner platform may depend on the observability stack, moving it to a dedicated cluster later is a **relocation, not a migration** — redeploy the same manifests against a different `destination`. Since §6 records a dedicated cluster as the *target state*, that property is not a nice-to-have: it is the mechanism that keeps the compromise reversible.

---

## 7. Coexistence — the VM runners are NOT retired

**Operator decision, 2026-08-14: the VM runners stay, permanently.** This supersedes the retirement framing this section originally carried (and the retirement language in DR-003's supersession note at the head of this DR — DR-009 *extends* DR-003, it does not replace it).

The two mechanisms are not competitors; they are **two tiers with different characteristics**, and each is better at what the other is bad at:

| | VM runners (DR-003) | ARC (this DR) |
|---|---|---|
| Serves | the existing 4-repo macf fleet | new fleets provisioned declaratively |
| Provisioning | operator, SSH + `make` | Kubernetes API, no credentials in the bootstrap |
| Idle cost | ~144 MB always-on, per repo | one small listener; runner pods at **zero** |
| Cold start | none — always warm | per-job pod start |
| Churn | stable, hand-managed | create/destroy is the point |

Keeping the VM fleet removes the migration risk that dominated the original §7: there is no cutover window, no "which half broke" ambiguity, and no repo that must be moved. ARC is **purely additive**. If it never proves out, it is torn down and nothing regresses, because nothing depended on it.

The criteria below therefore change meaning: they are no longer *permission to retire something*, they are **the bar ARC must clear before new fleets depend on it in production**. They stay because that bar is still worth stating in advance.

**ARC is considered production-ready for new fleets when all hold:**

0. **A queue-time instrument exists** and is running. Criteria 1 and 2 are only observable if something measures dispatch latency and queued-but-unstarted jobs. A queued job is *precisely* the silent failure — no error, no red check, just absence — so without this, "zero queue-stalls observed" degrades to "nobody looked," the same shape as a doctor reporting green on a uniformly stale fleet. **The instrument is part of the spike, not an assumption of it**, and it is criterion 0 because criteria 1-2 are unmeasurable without it. (Raised by `@macf-science-agent[bot]` on PR #185.)
1. A canary scale set on a **private** repo has served **≥ 50 real routing jobs over ≥ 7 days** with zero queue-stalls (jobs dispatched, not merely pods running), as measured by criterion 0.
2. p95 end-to-end routing-job latency is **≤ 16s**, against the VM baseline of ~13.6s — i.e. within ~2.5s of the tier it must not regress. See §7.3: the original ≤20s bar was too loose, since it would have permitted giving back 60% of the ~10s this entire subsystem exists to save.
3. **Destroy/recreate proven**: the scale set is deleted and re-created via the Kubernetes API alone, and resumes serving — no SSH, no `make`, no manual GitHub steps. This is the whole point of the change and is not optional.
4. `macf-actions#72` has landed and **at least one repo routes to ARC** through the real `pick-runner` path, not only a scratch workflow — **and that repo's detection and dispatch agree**: the register-before-route gate scored `present` *for the runner that actually served the jobs*. This must be verified on a repo with **no VM runner registered**, since coexistence (§7) makes "a runner exists" ambiguous — the gate could vouch for the VM runner while ARC serves nothing, and the criterion would pass on evidence about the wrong tier (§8).
5. Liveness/alerting equivalent to `fleet/runner-watchdog.sh` exists for the ARC path.

**Then**, and only then, new fleets are provisioned onto ARC as their default. The existing four repos stay on their VM runners and are **not** migrated — `runners.yaml` keeps its entries and `runner/` keeps its scripts.

**Public repos stay on the VM path by default.** GitHub advises against self-hosted runners on public repositories, and both of our safety layers (origin-routing, fork-PR approval) are workflow-side. Moving a public repo onto ARC would require re-verifying both under the new dispatch path; since nothing forces that move, it should not happen incidentally.

### 7.1 Why "scale down when idle" does not apply to the VM tier

A natural question (operator, 2026-08-14): *could we keep runners registered forever and have a policy that scales them down after, say, ten idle days, then scales up when a job arrives?*

**For the ARC tier the policy has nothing to act on: runner pods are already at zero.** Ephemeral runners are deleted after each job, so a scale set returns to zero within seconds of its last job, not after ten days. `minRunners: 0` is the whole feature. (Footgun: `minRunners` *and* `maxRunners` both at 0 creates nothing at all.)

**For the VM tier the policy cannot be implemented at all**, and this is the sharp edge. GitHub **never connects inward**. Dispatch is not routed *through* the controller — the listener holds an outbound HTTPS long-poll, GitHub sends a *Job Available* message down that already-open connection, and the listener then patches the `EphemeralRunnerSet` replica count via the Kubernetes API. So the listener is not a thing dispatch passes through; it is **the thing that asks**.

The consequence: **whatever is scaled down can never be woken by a job arriving.** Scale the listener (or a VM runner process) to zero and that repo goes deaf — GitHub has no path to announce work, jobs queue indefinitely, and there is no error, no red check, and nothing to alarm on. An idle-scale-down policy applied to the listening component is not an optimisation; it is a silent outage with a timer on it.

**One component is therefore irreducible: the listener.** One small listener per scale set is the floor.

The only architecture that inverts this is **webhooks**, where GitHub connects inward and a single always-on receiver could wake capacity for an entire fleet — one resident component instead of N. That is the legacy `HorizontalRunnerAutoscaler` mode, being phased out in favour of the listener model, so it is recorded here as the shape of the answer rather than a path to build on.

**Consequence for fleet scale, and it is favourable.** Each additional agent repo on the ARC tier costs one small Go listener plus **zero** idle runner pods, against a ~144 MB always-on .NET process on the VM tier. The "dozens of idle runners" concern that motivated this DR is materially reduced for new fleets — though not eliminated, since listener count still tracks repo count until the scope constraint in §1 is addressed by an organization.

### 7.2 Abandonment criterion

§7 as first drafted defined **proven** and never defined **failed** — an exit that only opens on success is not an exit (`@macf-science-agent[bot]`, PR #185).

**Coexistence makes this criterion more critical, not less** (same reviewer, PR #186 — correcting my initial read that its stakes merely dropped). Under the retirement framing there were *two* forcing functions: the date, and the fact that VM runners could not retire until ARC proved out. The second did most of the work, because a stalled spike was **visibly blocking something**. Coexistence removes exactly that pressure: nothing now waits on ARC, so a stall costs nothing anyone will notice and "we'll get back to it" carries no cost signal. The stakes fall; the *probability of silent drift* rises; and the date becomes the **only** remaining mechanism that produces a decision.

**Abandonment — default teardown, not escalation.** If criteria 0-5 are not all met by **2026-10-14 (two months)** or after **three tuning iterations** on criterion 2, whichever comes first, the ARC platform **is torn down by default** and this DR closes as *not-taken*, with the measured reasons recorded. Continuation past that date requires an **explicit re-authorization by the operator**, recorded on #184 with a new date — not merely an intention to continue.

The polarity matters and this section previously got it wrong, stating teardown in its headline and escalation in its closing sentence. Those are different mechanisms: an escalation *without* a default outcome is a request for attention, which is precisely how `macf#872` sat 36 days with an owner who fully intended to return. A default outcome with an override is a decision that happens on its own, and makes continuation a positive act — the right polarity when nothing else is pushing.

Nothing regresses on teardown: the VM fleet was never displaced, and new fleets fall back to §10's option (b), which works today. **The retirement-ownership and weekly-cadence clauses are removed** — with no retirement there is nothing to schedule. The criteria are tracked as checklist items on #184.

### 7.3 The cold-start tension — scale-to-zero and low latency are mutually exclusive

Raised by the operator, 2026-08-14, and it is the sharpest objection to this DR: *if every job spins a fresh pod, the pod start may cost more than the ~10s tailnet join we eliminated — in which case the whole subsystem is self-defeating.*

**The objection is correct on its own terms.** An ephemeral runner's cold start is pod scheduling + image pull (cached after first use) + runner process start + registration + job assignment. That plausibly lands in the same range as, or worse than, the ~10s saved. If it does, ARC at `minRunners: 0` is *slower than GitHub-hosted runners with a tailnet join* — §10's option (b), which needs no infrastructure at all.

**But scale-to-zero is a setting, not a property of ARC.** `minRunners: 1` keeps a warm pod idle and ready, so a job is assigned to an already-running runner with no cold start — the same latency profile as a VM runner. The tension is therefore explicit and tunable:

| Config | Latency | Idle cost |
|---|---|---|
| `minRunners: 0` | pod cold start per job | zero |
| `minRunners: 1` | warm, ≈ VM tier | one idle pod per repo |

**The consequence must be stated honestly, because it undercuts a benefit claimed earlier in this DR.** If latency matters for a repo, that repo runs `minRunners: ≥1`, and its idle cost is then comparable to the VM runner it was meant to improve on. **ARC's benefit for such repos is provisioning ergonomics — declarative create/destroy, no SSH, no operator credentials — and NOT resource savings.** §7.1's "zero idle runner pods" applies only to repos genuinely willing to trade latency for cost.

This is a real weakening of the case, and it compounds `@macf-science-agent[bot]`'s §10.1 argument: if warm pods are required to preserve the ~10s, ARC costs roughly a VM runner's idle footprint *plus* a Kubernetes dependency, purchased for provisioning ergonomics alone. That makes option (c) — removing the subsystem entirely — proportionally more attractive, not less.

**Therefore: measuring cold start is a go/no-go gate, not a tuning step, and it comes FIRST.** Before the platform repo is fleshed out or the canary clock starts, deploy one scale set and measure job-assignment latency at `minRunners: 0` and `minRunners: 1`. This measurement reuses criterion 0's instrument, which is why criterion 0 is ordered first.

§7.4 resolves the tension: the operator has ruled that latency is non-negotiable, which settles the default and demotes the measurement from *decides-whether-to-proceed* to *quantifies-the-dormant-wake-cost*.

---

### 7.4 Decision: warm by default; hibernate only the dormant

**Operator ruling, 2026-08-14, and it is the governing constraint on this DR:** the VM tier already gives well-tested, reasonably fast routing. **ARC's only job is to standardise provisioning of new runners. No functionality may be lost — latency above all.**

Therefore:

- **`minRunners: 1` is the DEFAULT** for every scale set. Active fleets — anything expected to run for a week or a month — **never scale to zero.** A warm pod is always waiting, so a routing job is assigned to a running runner and pays no cold start.
- **Idle cost is accepted deliberately.** One warm pod per repo is roughly what the VM runner costs today, and §7.3's honest conclusion stands: for these repos ARC buys **provisioning ergonomics, not resource savings**. That is the trade the operator has explicitly chosen, and it is the correct one when the alternative is regressing the thing the subsystem exists to provide.
- **Hibernation applies only to genuinely dormant fleets:** if a scale set has received no routing job for **5-10 days** (exact threshold to be set from observed data), `minRunners` drops 1 → 0. The first job after dormancy pays one cold start, and the controller restores `minRunners: 1` on observing activity, so only that single job is affected.

#### Correction: hibernation is safe, and my earlier warning did not apply to it

§7.1 warns that scaling down the listening component is "a silent outage with a timer on it." **That warning is about the LISTENER only, and it does not apply to this policy** — a distinction the earlier drafting did not make sharply enough.

The listener runs **regardless of `minRunners`**; it cannot scale to zero and is not asked to. So at `minRunners: 0` the repo is **still fully reachable**: the long-poll is still held, GitHub still delivers *Job Available*, the listener still patches the replica count, and a pod still starts. The only cost is that the pod starts cold.

That is the difference between **hibernation** (capacity at zero, still listening — safe, self-waking) and **deafness** (nothing listening — jobs queue forever with no error). The operator's policy is the former. My earlier answer treated the ten-day proposal as having "nothing to act on," which was true only while `minRunners: 0` was assumed to be the default; once latency mandates `minRunners: 1`, the policy has something real to act on and is sound.

#### What this requires

- **A signal:** last-routing-job time per scale set. ARC's listener publishes Prometheus metrics carrying repository and job labels, and criterion 0's queue-time instrument needs the same event stream — so **one instrument serves both the proving criteria and the hibernation policy**, which is a good sign the seam is in the right place.
- **An actuator:** a small controller (or CronJob) that patches `minRunners` on the `AutoscalingRunnerSet`. `minRunners` is a mutable field on a running scale set, so this is a patch, not a redeploy.
- **The idle-versus-broken ambiguity is ACCEPTED, and fleet-health detection stays OUT of the runner layer** (operator, 2026-08-14). Dormancy is inferred from absence of jobs, and a silently-broken fleet produces the same signal as a legitimately idle one. An earlier draft made the hibernation controller responsible for telling them apart; that was **misplaced**. If a fleet has sent no routing job in 10-20 days the agents are dormant too, and hibernating their runner is the correct response regardless of *why* it is quiet. A broken fleet is a **fleet-level** problem — the runner layer has no visibility that would let it do better, and pretending otherwise would put fleet-liveness detection in the component least equipped to perform it. Hibernation is a cost optimisation, not a health check.

- **But hibernation must CONSUME a health signal, not COMPUTE one** (`@macf-science-agent[bot]`, PR #187 — a sharper form of the guard, reconciled with the scoping above). Their objection to the first draft holds: handing the distinction to "criterion 5 also watches" leaves **two independent consumers of one ambiguous input drawing opposite conclusions** — the controller reading silence as *idle, save money*, the alert reading it as *possibly dead, escalate*. Two actors racing on one signal with contradictory semantics is a coin flip, not a guard.

  The resolution that satisfies both constraints is **one evaluation, three outputs**: silence + affirmatively healthy → hibernate; silence + unhealthy → alert, never hibernate; silence + health *unknown* → alert, never hibernate. That is fail-closed, and it keeps health *detection* at the fleet layer while making hibernation a *reader* of the fleet's published health rather than an inferrer of it. If the fleet layer publishes no health signal, hibernation does not run — which is the correct degradation, since the cost saved is one idle pod and the cost of being wrong is silent.

  **Where I do push back:** their supporting argument that *"the idle warm pod is the only artifact distinguishing quiet from dead"* overstates it. A warm pod is not a health signal — it sits there identically whether the fleet is thriving or dead, so hibernating it destroys no diagnostic that existed. Fleet liveness is established by the DR-006 watchdog and fleet-level health, not by runner capacity. The **recovery asymmetry** they raise is real and is the load-bearing half — a healthy hibernated fleet self-wakes on its next job, a broken one never does, because the thing that would wake it is the thing that stopped working — but that asymmetry holds with or without hibernation: a broken fleet routes nothing either way. It argues for fail-closed as cheap insurance, which is why the three-output rule above is adopted; it does not argue that hibernation destroys evidence.

---

## 8. Known blocker — `runs-on` is incompatible today

`macf-actions@v3.4.2` `pick-runner` emits `labels='["self-hosted","macf-vm"]'`, and every downstream job derives `runs-on` from it. **ARC scale sets are addressed by installation name, not by label matching**, so the current router would never dispatch to an ARC runner — jobs would queue indefinitely, silently, behind a green `pick-runner`.

Filed as `groundnuty/macf-actions#72`. It gates **cutover**, not the spike: ARC is validated end-to-end with a scratch workflow using `runs-on: <scale-set-name>` directly, so the two proceed independently.

**The blocker has a second half, in a different repo — and fixing only the first makes things worse** (`@macf-science-agent[bot]`, PR #185 / #184). The register-before-route gate `checkRunnerUsableByRepo` (shipped in `macf#927`) decides whether to write `MACF_TRUSTED_ACTORS` by resolving runner **presence and visibility** — repo-scoped runner count, plus org runner-groups visible to the repo — and **never compares the runner's labels against what `pick-runner` emits**. That is harmless today only because VM runners happen to carry `macf-vm`.

Under ARC it inverts: an ARC scale set registers runners the detection query *does* see, so the gate scores `present`, writes the variable, `pick-runner` emits `["self-hosted","macf-vm"]`, and nothing matches — **every routed job queues to timeout behind a green gate that has just confirmed a runner exists.** The safety mechanism becomes the delivery mechanism for the failure, precisely *because* it is working as designed.

So the gate's invariant must widen from *"a runner usable by this repo exists"* to *"a runner **matching the labels this router will emit** is usable by this repo."* Fixing `runs-on` alone yields detection that is confidently wrong — strictly worse than today's, which is at least correctly blind to ARC. **Phase 4's real scope is therefore "dispatch and detection agree on one predicate," spanning `macf-actions` and `macf`**; an implementer reading only `#72` would fix half and reasonably believe the blocker cleared.

### 8.1 Coexistence makes the addressing a per-repo VARIABLE, never a second constant

The shape of the Phase-4 fix changes with the coexistence decision, and in a way that is easy to get wrong (`@macf-science-agent[bot]`, PR #186).

`pick-runner` today emits a **hardcoded constant**, `labels='["self-hosted","macf-vm"]'`. Under the retirement framing that constant would eventually have been replaced once, globally, by a scale-set name. **Under coexistence it can never be a constant again**: VM-tier repos need labels and ARC-tier repos need a scale-set name, permanently and simultaneously.

§11's note that the tier is "lookup-able in `runners.yaml` versus the cluster" is true for a human debugging, but **`pick-runner` can read neither** — it runs inside a workflow with no access to this repo's `runners.yaml` and no cluster credentials. So both dispatch and detection need a **per-repo signal**, or they cannot agree on a predicate whose right answer differs by repo.

**That signal already exists and is already ratified: DR-043 Amendment H's `fleet.yaml` block.**

```yaml
routing:
  runner:
    labels: [self-hosted, macf-vm]
    scope: repo
    name: macf-vm
```

`labels` / `scope` / `name` is exactly the addressing information both consumers need, declared per fleet. **The coexistence decision promotes that block from a description of what `deploy` should register into the source of truth for how a repo is addressed.**

Implementable shape for Phase 4: `apply` writes the declared addressing to a per-repo Actions variable (as it already writes `MACF_TRUSTED_ACTORS`); `pick-runner` emits **from that variable** instead of a constant; `checkRunnerUsableByRepo` evaluates presence **against the same declared value**. One source, two consumers, no way for dispatch and detection to disagree — which is exactly the property §8 requires and which cannot be achieved while either side reads a constant.

**An implementer who reads `macf-actions#72` as "switch to scale-set addressing" will build the retirement-shaped fix — a second constant — and coexistence needs a variable.** Recorded here because that mistake would look correct in review and fail only on the second tier.

---

## 9. Status/verification must distinguish two facts

Whatever reports "the runner is up" must separate:

- the **pod is running** (cluster-side), and
- **GitHub considers it online** and will dispatch to it (GitHub-side).

These disagree silently. That is precisely what mis-diagnosed the 0.2.56 fleet roll: a `/health` answered from a stale registration while the real process was gone, the halt named `bad-release` for a release that was fine, and the whole fleet roll stopped to contain a problem that did not exist (`macf#899`).

Bootstrap **gates on the GitHub-side fact**; both are reported so a mismatch is visible rather than inferred. This is the Pattern-A result-invariant from `silent-fallback-hazards.md` applied at the provisioning boundary.

---

## 10. Alternative not taken — delete the subsystem

The entire runner fleet buys **~10 seconds per routing job** (24s → 13.6s measured), solely by skipping the tailnet join. Against that it costs a provisioning stage in every fleet bootstrap, a resident listener per repo, a security carve-out for public repos, and a watchdog.

If channel-servers were reachable without a tailnet join — and they already do mTLS, which is the hard part — GitHub-hosted runners would work and this subsystem would delete itself, taking its provisioning stage with it rather than relocating it. The counter-cost is Actions minutes on private repos, a billing question rather than an architectural one.

### 10.1 Corrected framing — three options, and the middle one already works

The draft above compared two options and got the cost axis wrong in the direction that argues against its own conclusion (`@macf-science-agent[bot]`, PR #185). There are **three**:

- **(a)** self-hosted runners — VM today, ARC proposed. No tailnet join; a provisioning stage per fleet.
- **(b)** hosted runners + tailnet join — **the status-quo fallback, working right now.** ~10s/job and metered minutes on private repos.
- **(c)** channel-servers reachable without a join — hosted runners, no join, metered minutes, **zero** provisioning, more network exposure.

**Option (b) is why there is no urgency: the runner is not on fleet provisioning's critical path.** A fleet with no runner at all routes on hosted minutes and *works* — that is exactly what the register-before-route gate guarantees, with hosted as the deliberate safe default. So §10's original "the fleet needs runner provisioning before that could land" overstates the dependency. The fleet needs runner provisioning to be **cheap**, not to **function**.

**And ~10s/job is the wrong measure of the runner's cost.** Its real price is design and failure surface, and this arc has the receipts: in roughly one week the runner produced DR-003's Amendment H, a live billing regression that ran undetected (`macf#924`→`#927`), a policy-gate design and implementation (`#929`→`#931`), `macf-actions#72`, the detection/dispatch split in §8, and this DR. Six artifacts, each a place a fleet can silently stop coordinating — against ten seconds on a coordination event no human is waiting on.

**Consequence for this DR:** build the spike, because the ARC learning is cheap and the destroy/recreate property is genuinely valuable — but **weigh (c) against (a) on failure surface, not latency**, and treat §7.2's abandonment criterion as the thing that routes to (c) rather than back to (b) by default. On current evidence (c) carries real weight, and this DR should not be read as having settled that question.

### 10.2 Alternative — webhook-driven (legacy) ARC mode

Raised by the operator, 2026-08-14. ARC has a **second, older autoscaling mode** that inverts the direction of control, and it addresses several complaints this DR has accumulated.

**Mechanism.** Three pieces: a `RunnerDeployment`/`RunnerSet`, a `HorizontalRunnerAutoscaler` (HRA), and a **single cluster-wide `github-webhook-server`**. GitHub POSTs a `workflow_job` event on job queue; the webhook server routes it to the HRA whose backing RunnerDeployment carries **matching runner labels**; the HRA adds capacity. Scale-down fires on `workflow_job` `completed`/`canceled`, with a per-trigger `duration` timeout as backstop if the completion event never arrives.

**What it buys — and it is not a small list:**

1. **No per-repo listener.** One webhook server serves every runner deployment in the cluster. This is the direct answer to the concern that started this DR — dozens of resident per-repo processes — and it is the only architecture examined here that actually eliminates them rather than shrinking them.
2. **Label-based addressing survives.** Runners register as ordinary self-hosted runners with normal labels, and the HRA matches on those labels. So `pick-runner`'s existing `["self-hosted","macf-vm"]` works **unchanged** — which means §8's blocker and §8.1's per-repo-variable requirement largely dissolve, and `checkRunnerUsableByRepo`'s presence check stops being ambiguous because both tiers are label-addressed.
3. **Hibernate/wake is native.** The `duration`-based scale-down is precisely §7.4's policy, implemented by the mode rather than by a controller we would write.

**What it costs:**

1. **Community-maintained only.** GitHub's own statement: *"With the introduction of autoscaling runner scale sets, the existing autoscaling modes are now legacy. The legacy modes have certain use cases and will continue to be maintained by the community only."* Official support and documentation point at scale sets. Choosing this mode means depending on a control plane GitHub has stepped back from — a real risk for infrastructure meant to outlive several fleets.
2. **It requires inbound reachability.** GitHub must be able to POST to the webhook server, so an endpoint must be exposed to GitHub's network.

**And cost 2 is the observation that matters most.** Requiring an inbound endpoint is *exactly* option (c)'s requirement. If we are willing to expose an endpoint to the outside world to make runners cheaper, the question that must be asked in the same breath is whether exposing the **channel-servers** instead — which already speak mTLS — would remove the need for self-hosted runners at all. **Both paths pay the same architectural price; only one of them deletes a subsystem in exchange.**

### 10.2.1 DECIDED: webhook mode (operator, 2026-08-15)

**The operator has committed to ARC in webhook-driven mode.** Option (c) is agreed to be the better end-state but is "too big a revolution at the moment" — so it is deferred, not rejected, and §7.2's abandonment still routes there.

**What this decision resolves** — five open items collapse:

| Was open | Now |
|---|---|
| Per-repo listener pod (the original idle-cost objection) | **Gone.** One cluster-wide `github-webhook-server` serves every runner deployment. |
| `macf-actions#72` — `runs-on` label array can't address a scale set | **Largely dissolves.** Webhook-mode runners register as ordinary self-hosted runners with normal labels, so `pick-runner`'s existing constant works unchanged. |
| §8.1 — per-repo addressing variable | **Dissolves** for the same reason. No `fleet.yaml`-to-variable plumbing needed to make dispatch work. |
| §8 — `checkRunnerUsableByRepo` presence/label ambiguity | **MASKED, not dissolved** — see §10.2.1a. Correct only by convention. |
| §7.4 hibernation controller (a thing we would have written) | **Native.** The HRA's `duration`-based scale-down IS the policy. |

**An unplanned synergy worth naming:** webhook mode's structural weakness is that scale-up is *push*. If the webhook server is unreachable when a job is queued, there is no polling fallback — the listener model self-heals by reconnecting, a missed webhook simply never arrives. **`minReplicas: 1` (§7.4's warm-by-default) mitigates exactly this**: the warm runner accepts the job without any scale-up being needed, so the webhook path is non-critical for the common case and load-bearing only for burst and for waking a hibernated fleet. The latency decision and the mode decision reinforce each other.

**Consequence for label-sharing:** if a repo carries both a VM runner and an ARC runner with identical labels, GitHub dispatches to whichever is idle. That is a *good* property for gradual migration (automatic, no cutover) but it makes ARC untestable on such a repo — which is why criterion 4 requires verification on a repo with **no VM runner registered**. New fleet repos are unambiguous by construction.

**The per-repo addressing variable (§8.1) is deferred, not wasted.** It becomes necessary again the moment any fleet wants its own labelled pool — tier isolation, or a repo that must not share capacity — because the shared constant breaks at exactly that point. Recorded so a future reader does not re-derive it from scratch.

#### 10.2.1a The gate ambiguity is masked by convention, not resolved by construction

The table above originally claimed the gate's ambiguity "dissolves." **That was overstated, and the overstatement is the dangerous kind** (`@macf-science-agent[bot]`, PR #188).

`checkRunnerUsableByRepo` still resolves **presence and visibility only** — it has never compared labels. Under webhook mode it *appears* correct because both tiers use `macf-vm` by convention, so presence happens to imply label-match. **Nothing enforces that convention.** Configure one `RunnerDeployment` with `arc-runner` labels — an entirely reasonable choice for pool isolation — and the original failure returns in full: gate sees a runner → scores `present` → writes `MACF_TRUSTED_ACTORS` → `pick-runner` emits `macf-vm` → nothing matches → **every job queues to timeout behind a green gate.** Identical to the §8 failure, but now with no migration underway to warn anyone it is coming.

**So the cheap half of the Phase-4 fix survives and should still be built: the gate must verify that a runner carries the labels `pick-runner` will emit**, even while that remains a constant. No manifest plumbing, no per-repo variable, no `macf-actions` change — a label comparison inside a function that already fetches the runner list. That converts *"safe because everyone follows the convention"* into *"safe because a violation is detected,"* which is the distinction between this codebase's guards and its incidents.

### 10.2.2 The new blocker this decision introduces — inbound reachability

Scale-set mode needs only *outbound* connectivity, which §5 verified works. **Webhook mode requires GitHub to POST *into* the cluster, and nothing in the current topology permits that.** Verified 2026-08-15 on the monitoring VM:

```
ip -4 -o addr:   ens3 192.168.102.15/24   (private LAN, DHCP)
                 tailscale0 100.120.127.76/32
default route:   via 192.168.102.1 dev ens3
public egress:   149.156.10.142            (NAT — matches no local interface)
```

**No public IP on any interface.** The VM egresses through an institutional NAT it does not control, so `api.github.com` has no route to a webhook endpoint here. This is a hard prerequisite, not a tuning detail: without it, webhook mode cannot scale up at all.

Candidate resolutions, in preference order:

1. **Tailscale Funnel** — exposes a tailnet service to the public internet over Tailscale's relays, HTTPS on 443/8443/10000, which suits a webhook receiver. Uses infrastructure already in place. **Status: RESOLVED — the prerequisite was already satisfied (verified 2026-08-16).** See §10.2.2c.
2. **Institutional port-forward** on the NAT gateway — unlikely to be available on a university network, and brittle if it is.
3. **A relay/tunnel** (Cloudflare Tunnel or similar) — works, but adds a third-party dependency to the routing path.

**Security note:** any of these places a **publicly-reachable endpoint** in front of the cluster — a materially different posture from today's tailnet-only boundary, and the first such endpoint in this stack. GitHub's webhook secret (HMAC signature validation) is mandatory, not optional, and the receiver must reject unsigned or mis-signed payloads. This is the one place where the "unauthenticated is fine on the tailnet" reasoning used elsewhere in this repo explicitly does **not** apply.

#### 10.2.2c RESOLVED — Funnel prerequisites were already in place (verified 2026-08-16)

The operator supplied a Tailscale API key to settle this rather than leave it as an operator-gated unknown. **No ACL change is required — the grant already exists**, and the earlier "unverified / must be confirmed before Phase 2" status was over-cautious.

Tailnet policy (`GET /api/v2/tailnet/-/acl`, backed up before inspection):

```json
"nodeAttrs": [ { "target": ["autogroup:member"], "attr": ["funnel"] } ]
```

Tailnet DNS: `{"magicDNS": true}`.

**Confirmed at the node itself**, which is the load-bearing check — a policy grant does not prove the node holds the capability. `tailscale status --json | .Self.CapMap` on the monitoring VM:

```
funnel
https
https://tailscale.com/cap/funnel-ports?ports=443,8443,10000
```

So the monitoring node **holds** `funnel` and `https`, and Funnel is permitted on 443 / 8443 / 10000 — exactly what an HTTPS webhook receiver needs. `tailscale funnel status` returning "No serve config" earlier meant *unconfigured*, never *unpermitted*; conflating those is what produced the false blocker.

**Nothing is configured, and deliberately so.** The serve config that points Funnel at the webhook receiver belongs in Phase 2, when a receiver exists to point at. Enabling Funnel now would create public exposure serving nothing.

**Still outstanding for this path, and both belong to Phase 2:**

- An **end-to-end reachability proof** — Funnel being permitted is not proof that a POST from the public internet arrives. That test is cheap but is itself a brief public exposure, so it is operator-gated.
- **HMAC validation remains mandatory** (§10.2.2). The `autogroup:member` grant is broad — *any* member device may funnel — so the tailnet does not constrain what gets exposed; only the receiver's own signature check does.

**Handling note for whoever automates this:** the policy was fetched with `Accept: application/json`, which **strips HuJSON comments**. Any future write-back must use the HuJSON form or it will silently delete the operator's policy comments. Nothing was written during this inspection.

#### 10.2.2a Webhook-delivery health needs an owner — `minReplicas: 1` is what hides its failure

§10.2.1 credits warm-by-default with neutralising webhook mode's push-without-fallback weakness. **That mitigation also conceals the weakness's failure mode** (`@macf-science-agent[bot]`, PR #188), which is the exact shape this DR keeps cataloguing: a degradation masked by the mitigation that makes it survivable.

If Funnel drops, the `nodeAttrs` grant is revoked, or the serve config is lost across a node restart, GitHub's POSTs fail, retry, and give up. **Scale-up dies. Jobs keep running** — on the single warm pod — so nothing errors and nothing alarms, while the fleet quietly serves all load at concurrency 1 and queues under any burst.

It is observable without new infrastructure: **GitHub records per-hook delivery status**, so failed deliveries are queryable. **Webhook-delivery success is the health signal for the scale-up path, and nothing else watches it** — so it belongs in criterion 0's instrument alongside queue-time. Without it, "autoscaling works" is asserted by absence-of-complaint.

**Per §6.1 this instrument must be self-contained.** It reads from the GitHub API and from ARC's own state, not from the observability stack — so webhook-delivery health and hibernation decisions keep working when Prometheus does not. Exporting these metrics *to* the observability tier is welcome; *depending* on it is not.

#### 10.2.2b Node exposure inventory — audited 2026-08-15 (LIVE, and load-bearing)

> **An interim revision marked this audit "superseded / moot" on the assumption that a dedicated runner cluster would put the Funnel endpoint on a different node.** The operator's 2026-08-15 ruling (§6) settles the opposite: the runner platform is collocated on the observability cluster. **So the Funnel endpoint WILL land on the node running Prometheus, Tempo, Grafana, Langfuse and ArgoCD, and this table is a direct input to that decision rather than background.** The un-mooting is worth stating loudly, because a security audit that was retired on a premise that then reversed is exactly the kind of thing that stays retired by inertia.

The larger risk is not the webhook receiver, which is the well-secured part. It is that **this node's other services were built assuming the tailnet is the access control** (CLAUDE.md states this explicitly for Prometheus). Funnel is port- and path-scoped, so exposing one receiver does not expose them — but it enlarges the blast radius of any future serve-config mistake on a node full of services that assume no unauthenticated caller can reach them.

Probed over the tailnet, 2026-08-15:

| Service | Port | Probe result | Posture |
|---|---|---|---|
| Prometheus | 9090 | `200` on `/api/v1/status/config` | **unauthenticated** — full scrape config readable |
| Tempo query | 3200 | `200` on `/api/status/buildinfo` | **unauthenticated** — all traces queryable |
| node_exporter | 9100 | `200` on `/metrics` | **unauthenticated** — host metrics |
| OTLP HTTP | 4318 | `405` on GET `/v1/traces` | reachable; **unauthenticated ingest** |
| Langfuse | 3001 | `200` on `/api/public/health` | inconclusive — that path is public *by design*; not evidence the app is open |
| Grafana | 3000 | `401` on `/api/org` | authenticated |
| ArgoCD | 8080 | `401` on `/api/v1/applications` | authenticated |
| k3s API / kubelet | 6443 / 10250 | listening on all interfaces | certificate auth |

**Three services plus OTLP ingest are genuinely unauthenticated**, exactly as the documented posture intends — the tailnet *is* the control. That posture is sound today and is precisely what a public endpoint on this node sits alongside. The inventory is recorded so the decision to add Funnel is made against a known list rather than an assumption, and so any future serve-config change can be checked against it.

**Not a blocker and not an argument against Funnel** — port/path scoping means these stay unreachable. It is the five-minute audit that is worth having before the grant lands rather than after an incident.

**The parallel with option (c) is now exact and should be weighed deliberately:** webhook mode requires exposing an inbound endpoint to make runners cheaper; option (c) requires exposing the channel-servers to delete runners entirely. Both pay the same architectural price. Only one removes a subsystem. The operator has chosen the former on grounds of revolution-size, with the latter explicitly deferred rather than dismissed.

### 10.2.3 What does NOT change

Unaffected by the mode decision, still required:

- **The CoreDNS `ts.net` stanza (§5).** Runner pods must still reach the agents' channel-servers *outbound* over the tailnet; that path and its MagicDNS gap are identical in both modes.
- **The GitHub App with `Administration: Read and write`** — runner registration is the same operation either way.
- **Criterion 0's queue-time instrument** — still the only way criteria 1-2 are observable, and still the hibernation signal.
- **`minReplicas: 1` warm-by-default** (§7.4) — now doing double duty, per §10.2.1.
- **The legacy-mode support risk** — the chart is `actions-runner-controller`, not `gha-runner-scale-set`, and GitHub's own guidance points at the latter. This is a standing dependency risk, accepted with the decision.

---

## 10.3 The value claim, stated mechanically — and nothing more

Three revisions have each conceded something: coexistence removed retirement, §7.3 removed resource savings, §7.4 confirmed that removal for active fleets. Asked whether that trend means the answer is really option (c), `@macf-science-agent[bot]` gave the discriminator (PR #187): **every concession was an *inferred* benefit** — something assumed to follow from scale-to-zero, which reality then took back — while **the mechanical claim has not moved**.

So this DR's justification is stated here in mechanical terms only, and future revisions should not add inferential ones:

> **The Kubernetes API can create and destroy a runner. A bootstrap holding one credential can do it with no host access and no human action — and it can *destroy* one, which the VM path cannot do at all** (DR-043 Amendment G's teardown ladder cannot remove a VM-hosted or token-registered runner, so fleet teardown is incomplete without an API-driven runner).

That is a fact about the mechanism, not a prediction about behaviour, which is why nothing in three revisions has eroded it. **If that sentence does not justify the cost, the answer is option (c)** — but that is then a judgment on a settled claim rather than a fourth concession.

**Reading note:** §7.3's cold-start go/no-go **has already been answered by §7.4** — the operator chose warm-by-default and explicitly accepted ergonomics-without-savings. The measurement still matters, but it now *sizes the dormant wake-cost*; it does not decide whether to proceed. A gate answered by decree that still reads as open invites someone later to "satisfy" it with a measurement without noticing the decision was already taken.

---

## 11. Consequences

- Fleet bootstrap gains a Kubernetes API call per agent repo, and loses SSH, `make`, and any need for operator credentials.
- **Two provisioning mechanisms exist permanently** (VM + ARC), by decision rather than by drift (§7). The cost is a standing one: two things to understand, patch, and debug, and a question — *"which tier is this repo on?"* — that every future runner investigation must ask first. Accepted deliberately in exchange for zero migration risk. The mitigation is that the tiers are cleanly split by *which repos they serve*, so the answer is always lookup-able in `runners.yaml` (VM) versus the cluster (ARC), never inferred.
- **Because both tiers can satisfy "a runner exists," any presence-based check is now ambiguous by construction.** This is not hypothetical — it is exactly the register-before-route gate's failure mode in §8, and coexistence makes it permanent rather than transitional. Every such check must resolve *which tier*, not merely *whether*.
- One listener pod per repo remains. If that count becomes objectionable, the fix is an organization, not a different controller — a decision this DR deliberately leaves open, and whose first step is a five-minute test: create a free org and check whether `POST /orgs/<x>/actions/runners/registration-token` returns 200.
- Public and private repos stay on **separate pools** under every future shape. This survives an org migration and is the one irreversible mistake available here.
