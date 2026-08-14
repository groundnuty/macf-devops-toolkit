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

1. A canary scale set on a **private** repo has served **≥ 50 real routing jobs over ≥ 7 days** with zero queue-stalls (jobs dispatched, not merely pods running).
2. p95 end-to-end routing-job latency is **≤ 20s**, against the VM baseline of ~13.6s. If cold-start blows this, `minRunners` is tuned and the run repeats.
3. **Destroy/recreate proven**: the scale set is deleted and re-created via the Kubernetes API alone, and resumes serving — no SSH, no `make`, no manual GitHub steps. This is the whole point of the change and is not optional.
4. `macf-actions#72` has landed and **at least one repo has cut over** through the real `pick-runner` path, not only a scratch workflow.
5. Liveness/alerting equivalent to `fleet/runner-watchdog.sh` exists for the ARC path.

**Then**, and only then, retire VM runners **one repo at a time**, removing each `runners.yaml` entry as its ARC replacement takes over. Public repos (`macf`, `macf-devops-toolkit`) go **last**: GitHub advises against self-hosted runners on public repositories, and both of our safety layers (origin-routing, fork-PR approval) are workflow-side, so they must be re-verified under ARC rather than assumed to carry over.

---

## 8. Known blocker — `runs-on` is incompatible today

`macf-actions@v3.4.2` `pick-runner` emits `labels='["self-hosted","macf-vm"]'`, and every downstream job derives `runs-on` from it. **ARC scale sets are addressed by installation name, not by label matching**, so the current router would never dispatch to an ARC runner — jobs would queue indefinitely, silently, behind a green `pick-runner`.

Filed as `groundnuty/macf-actions#72`. It gates **cutover**, not the spike: ARC is validated end-to-end with a scratch workflow using `runs-on: <scale-set-name>` directly, so the two proceed independently.

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

Not taken now: it is a larger change touching the agents' network exposure, and the fleet needs runner provisioning before that could land. **Recorded because it is the only option that removes the stage rather than moving it**, and it should be re-weighed if the ARC path proves costly to operate.

---

## 11. Consequences

- Fleet bootstrap gains a Kubernetes API call per agent repo, and loses SSH, `make`, and any need for operator credentials.
- One more provisioning mechanism exists during the transition (VM + ARC). §7 is what stops that from becoming permanent.
- One listener pod per repo remains. If that count becomes objectionable, the fix is an organization, not a different controller — a decision this DR deliberately leaves open, and whose first step is a five-minute test: create a free org and check whether `POST /orgs/<x>/actions/runners/registration-token` returns 200.
- Public and private repos stay on **separate pools** under every future shape. This survives an org migration and is the one irreversible mistake available here.
