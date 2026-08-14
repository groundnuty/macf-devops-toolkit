# DR-009: API-driven runner provisioning via Actions Runner Controller

**Status:** Proposed
**Date:** 2026-08-14
**Trigger:** Operator design review (2026-08-14) while designing declarative fleet provisioning (DR-043 / `macf#838`): *"I really didn't want to have as part of fleet provisioning a moment when you have to provision runners."* The VM-based fleet from DR-003 works, but it can only be provisioned by SSH + `make` + operator credentials against one specific machine — which is exactly the step a declarative bootstrap cannot take.
**Supersedes (eventually):** DR-003 (self-hosted GitHub runner, VM/systemd). DR-003 stays in force until the retirement criteria in §7 are met.
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

**A new dedicated GitHub App** (e.g. `macf-runner-provisioner`) rather than extending the devops-agent App. Repo-scoped ARC needs `Administration: Read and write`; granting that to the devops bot would permanently widen its power across every repo it is installed on and destroy the 403 that currently makes runner operations deliberately operator-gated. The new App's credential lives only as a cluster Secret, referenced by `githubConfigSecret`. (Org scope would need only `Self-hosted runners: R/W` — one more small argument for the org path if it is ever taken.)

**Host on the monitoring k3s for the spike.** It is proven viable above and is the fastest path to validation. This is explicitly a **spike-scoped** decision to be revisited before cutover: it co-locates CI workloads with the observability stack, and `/mnt/volume1` is at 72%. Runner pods pulling images and doing work on the same box as Tempo and ClickHouse is acceptable for a canary and questionable as a steady state.

---

## 7. Retirement criteria for the VM runners — written before we start

DR-003's fleet keeps serving throughout. Migrating a working system while validating a new design makes it impossible to tell which half broke. But a transition needs an end, or both mechanisms live forever.

**ARC is considered proven when all hold:**

0. **A queue-time instrument exists** and is running. Criteria 1 and 2 are only observable if something measures dispatch latency and queued-but-unstarted jobs. A queued job is *precisely* the silent failure — no error, no red check, just absence — so without this, "zero queue-stalls observed" degrades to "nobody looked," the same shape as a doctor reporting green on a uniformly stale fleet. **The instrument is part of the spike, not an assumption of it**, and it is criterion 0 because criteria 1-2 are unmeasurable without it. (Raised by `@macf-science-agent[bot]` on PR #185.)
1. A canary scale set on a **private** repo has served **≥ 50 real routing jobs over ≥ 7 days** with zero queue-stalls (jobs dispatched, not merely pods running), as measured by criterion 0.
2. p95 end-to-end routing-job latency is **≤ 20s**, against the VM baseline of ~13.6s. If cold-start blows this, `minRunners` is tuned and the run repeats.
3. **Destroy/recreate proven**: the scale set is deleted and re-created via the Kubernetes API alone, and resumes serving — no SSH, no `make`, no manual GitHub steps. This is the whole point of the change and is not optional.
4. `macf-actions#72` has landed and **at least one repo has cut over** through the real `pick-runner` path, not only a scratch workflow — **and that repo's detection and dispatch agree**: the register-before-route gate scored `present` *for the runner that actually served the jobs*. Without this, criterion 4 can pass on a repo that still has a VM runner registered alongside, where the gate vouched for one runner and the jobs ran on another (§8).
5. Liveness/alerting equivalent to `fleet/runner-watchdog.sh` exists for the ARC path.

**Then**, and only then, retire VM runners **one repo at a time**, removing each `runners.yaml` entry as its ARC replacement takes over. Public repos (`macf`, `macf-devops-toolkit`) go **last**: GitHub advises against self-hosted runners on public repositories, and both of our safety layers (origin-routing, fork-PR approval) are workflow-side, so they must be re-verified under ARC rather than assumed to carry over.

### 7.1 Retirement is about the VM mechanism, not about runner count

A natural question (operator, 2026-08-14): *if runners can scale down when idle and scale up when work arrives, why retire anything at all?*

That is the ARC end state, and it is what this DR migrates **to** — not something retirement works against. ARC scales runner pods to **zero** (`minRunners: 0`; note both `minRunners` and `maxRunners` at 0 creates nothing at all) and spins them up on job demand. The VM/systemd runners **cannot** participate in that: they are always-on processes at ~144 MB each, 24/7, whether or not a job ever arrives. Their inability to scale down is an argument *for* retiring them.

**One component is irreducible: the listener.** It cannot scale to zero, because GitHub never connects inward — dispatch works by the listener holding an outbound HTTPS long-poll, so if nothing is awake, nothing can learn a job exists. One small listener per scale set is the floor. (Webhook-driven scaling, which would invert that direction, belongs to the legacy `HorizontalRunnerAutoscaler` mode being phased out in favour of the listener model; not a path to build on.)

**Consequence for fleet scale, and it is favourable.** Each additional agent repo costs one small Go listener plus **zero** idle runner pods, against a ~144 MB always-on .NET process today. The "dozens of idle runners" concern that motivated this DR is materially reduced — though not eliminated, since the listener count still tracks repo count until the scope constraint in §1 is addressed by an organization.

### 7.2 Abandonment criterion and retirement ownership

§7 as first drafted defined **proven** and never defined **failed** — it was one-sided, and permitted retirement without triggering it (`@macf-science-agent[bot]`, PR #185). Both gaps reach the DR's own stated fear (both mechanisms alive forever) by *neither* criterion firing, because "not yet proven" and "quietly stalled" are indistinguishable from outside. An exit that only opens on success is not an exit.

**Abandonment.** If criteria 0-5 are not all met by **2026-10-14 (two months)** or after **three tuning iterations** on criterion 2, whichever comes first, the spike is **abandoned**: the ARC platform is torn down, the VM fleet remains authoritative, and this DR closes as *not-taken* with the measured reasons recorded. Abandonment is a legitimate outcome, not a failure to be avoided by extending the deadline — and §10's option (c) is where the abandonment routes, not back to the status quo by default.

**Ownership and cadence.** Meeting the criteria makes retirement *permitted*, not *scheduled* — the "I'll come back to it" shape that left `macf#872` sitting 36 days. So: `macf-devops-agent[bot]` owns retirement; the clock starts the day criterion 4 is met; one repo retires per week thereafter, private repos first, tracked as checklist items on #184. If a week passes with no repo retired and no blocker recorded on #184, that is itself the signal to escalate to the operator.

---

## 8. Known blocker — `runs-on` is incompatible today

`macf-actions@v3.4.2` `pick-runner` emits `labels='["self-hosted","macf-vm"]'`, and every downstream job derives `runs-on` from it. **ARC scale sets are addressed by installation name, not by label matching**, so the current router would never dispatch to an ARC runner — jobs would queue indefinitely, silently, behind a green `pick-runner`.

Filed as `groundnuty/macf-actions#72`. It gates **cutover**, not the spike: ARC is validated end-to-end with a scratch workflow using `runs-on: <scale-set-name>` directly, so the two proceed independently.

**The blocker has a second half, in a different repo — and fixing only the first makes things worse** (`@macf-science-agent[bot]`, PR #185 / #184). The register-before-route gate `checkRunnerUsableByRepo` (shipped in `macf#927`) decides whether to write `MACF_TRUSTED_ACTORS` by resolving runner **presence and visibility** — repo-scoped runner count, plus org runner-groups visible to the repo — and **never compares the runner's labels against what `pick-runner` emits**. That is harmless today only because VM runners happen to carry `macf-vm`.

Under ARC it inverts: an ARC scale set registers runners the detection query *does* see, so the gate scores `present`, writes the variable, `pick-runner` emits `["self-hosted","macf-vm"]`, and nothing matches — **every routed job queues to timeout behind a green gate that has just confirmed a runner exists.** The safety mechanism becomes the delivery mechanism for the failure, precisely *because* it is working as designed.

So the gate's invariant must widen from *"a runner usable by this repo exists"* to *"a runner **matching the labels this router will emit** is usable by this repo."* Fixing `runs-on` alone yields detection that is confidently wrong — strictly worse than today's, which is at least correctly blind to ARC. **Phase 4's real scope is therefore "dispatch and detection agree on one predicate," spanning `macf-actions` and `macf`**; an implementer reading only `#72` would fix half and reasonably believe the blocker cleared.

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

---

## 11. Consequences

- Fleet bootstrap gains a Kubernetes API call per agent repo, and loses SSH, `make`, and any need for operator credentials.
- One more provisioning mechanism exists during the transition (VM + ARC). §7 is what stops that from becoming permanent.
- One listener pod per repo remains. If that count becomes objectionable, the fix is an organization, not a different controller — a decision this DR deliberately leaves open, and whose first step is a five-minute test: create a free org and check whether `POST /orgs/<x>/actions/runners/registration-token` returns 200.
- Public and private repos stay on **separate pools** under every future shape. This survives an org migration and is the one irreversible mistake available here.
