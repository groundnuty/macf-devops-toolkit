# DR-008: A2A delivery-guarantee + relaunch reconciliation — durable messaging that survives restart

**Status:** Proposed
**Date:** 2026-07-01
**Trigger:** Operator reliability review (2026-07-01): direct agent-to-agent messaging is "fire-and-hope" — you send and hope it arrives; if the peer is slow/down/restarting you can't tell. And the operational case: **what happens to messages when an agent is down or being restarted** (a VM relaunch, or — the K8s future — a pod recreate)? We cover *some* of this (the `agent-offline` label, GitHub-anchored routing), but it deserves a deeper study. This DR is the devops-side design framing + the delegation trigger for the framework work (the channel-server delivery contract, DR-023's deferred "Phase 2.5"); same split as DR-006↔`macf` DR-031 and DR-007↔`macf` DR-037.

Motivating incident: **the devops agent was down ~8h on 2026-07-01** (register-race on a stale registry entry + TUI stuck at the channels prompt). Any *direct* A2A sent during that window was dropped; in-flight task state died with the process. Concrete evidence this is real, not theoretical.

---

## Context — what's guaranteed today, and the one hole

Verified against the current channel-server source (`a2a-client.js` / `a2a-task.js` / `comms-ledger.js`):

| Path | Delivery semantics today |
|---|---|
| `message/send` (direct A2A) | **at-most-once — NO retry.** Source comment: *"Does NOT retry on failure (per design Q4 — `message/send` is not idempotent)."* Peer down → `TRANSPORT_ERROR` → **dropped.** |
| A2A task state | **in-memory only.** *"NOT durable across channel-server restarts; Phase 2.5 will revisit."* Lost on agent restart / **K8s pod-recreate.** |
| `comms-ledger.jsonl` | **durable — but an AUDIT trail, not a delivery queue.** *"NO central durable sink."* Records what happened; does **not** re-deliver. |
| `getAgentCard()` | retries 3× w/ backoff — but that's *discovery*, not the message. |
| **GitHub-anchored coordination** (issue-routing, `agent-offline` label) | **durable + survives everything** — persists on GitHub; startup-check drains it on recovery. |

**The shape:** GitHub-anchored coordination is durable and self-healing; **direct A2A (`notify_peer`/`message/send`) has neither durability nor a pull-backstop** — it never touches GitHub, so it's the one path that silently drops on a down/restarting/pod-recreating peer. The framework explicitly deferred the fix ("Phase 2.5"); the operator's ask makes it due.

**Today's *effective* guarantee is PULL, not push:** `coordination.md §5` has the recipient *assert GitHub state* (review/gate sweeps) rather than trust the ping arrived. Push is a latency optimization; GitHub is the durable truth. Direct A2A is the gap because it has no GitHub anchor to pull from.

---

## Decision

### 1. Hybrid substrate — GitHub for coordination-anchored, channel-server inbox/outbox for the direct path

Keep the two planes, each doing what it's good at:

- **GitHub stays the durable substrate for coordination-anchored messages** (issue-routing, reviews, gates, `agent-offline`). It already survives recipient-down / restart / pod-recreate for free, and it's the pull-truth §5 asserts against. Don't rebuild this.
- **The channel-server gains a persistent inbox/outbox for the *direct* path** (`notify_peer`/`message/send`) — the Phase-2.5 durability the source earmarked. This is the new build.

### 2. Delivery guarantee — at-least-once + idempotent dedup = effectively-once

- **Sender outbox** — persist the message before send; retry-to-ACK with backoff; survive *sender* restart. Requires a **message-id + receiver-side dedup** to make `message/send` safe to retry (this resolves the "not idempotent" blocker design-Q4 named — idempotency comes from the id, not from the operation).
- **Receiver inbox** — persist inbound; dedup by message-id; **drain on recovery**; survive *receiver* restart. **This is what makes the down / restart / pod-recreate case work** — a message sent while the peer was down is redelivered (or drained from its inbox) when it returns, instead of dropped.

### 3. The store is a pluggable driver — the K8s forcing function (decision/driver split, per DR-007/DR-037)

The current in-memory store **dies with the agent/pod** — that's exactly the restart/pod-recreate failure. So the outbox/inbox store **MUST be external to the ephemeral agent process**:

| Runtime | Store driver |
|---|---|
| VM | a **local disk spool** (the `comms-ledger` already writes synchronous disk — extend that surface to a delivery queue, not just an audit trail) |
| K8s (future) | a **PVC** or a **broker** (NATS / Redis) — outlives the pod |

The outbox/inbox/ACK/retry/dedup **logic is runtime-agnostic**; the **store is the pluggable driver** — the same decision/driver boundary as DR-007's fleet-upgrade and DR-037's operational layer. Get it right once and VM + K8s fall out of one design.

### 4. Relaunch reconciliation — the completeness half (delivery alone is NOT enough)

**A persistent inbox is necessary but not sufficient: if the relaunch injection doesn't surface everything, the agent is partly blind from the start** — worst on an *unclean* restart (crash / register-race / pod-kill, like the 8h outage), which leaves no resume-note and no compaction summary. So the recovery contract is not "persist the messages" but **"on relaunch, RECONCILE against every durable source, injected and complete"** — Pattern A (assert against durable state) applied to startup.

What a relaunched agent must be handed, in the injected prompt:

| Source | Today | Target |
|---|---|---|
| labeled-issue queue | ✅ `startup_check` (per-repo loop) | keep — but **fix the enumeration** (§5) |
| reviews / gates / @mentions | ⚠️ manual §5 sweep (agent must *remember*) | **automatic + injected on startup** |
| drained A2A inbox (§2) | ❌ dropped | **drain + surface on startup** |
| in-flight work | ✅ resume-note / compaction handoff | keep — **absent on unclean restart** → the above IS the safety net |

So the fix has **two halves that must land together**: (a) the persistent inbox/outbox, and (b) a **complete startup-reconciliation** that drains it *and* runs the review/gate/mention sweeps automatically — promoting §5 from "a discipline the agent might forget" to "an injected startup step." Without (b), (a) is invisible.

### 5. The queue-source — App-install × label, complete-by-construction (NOT global-search, NOT hardcoded)

The labeled-issue queue (the §4 first row) has its own sub-problem, resolved here with live evidence.

**How the agent queries today:** a per-repo loop over a **hardcoded** 3-repo list (`agent-identity.md §"Checking for Work"`). Safe (only repos I belong to) but **as incomplete as the list** — work in a 4th repo is silently missed (the §4 blindness, at the queue level).

**Why NOT "search all of GitHub for my label":** labels are **not namespaced across GitHub**. Verified live — `gh search issues --label devops-agent` returned our issues **plus `rafamqrs/devops-slack-demo#2`**, a stranger's public repo that happens to use a `devops-agent` label. A global label-search **poisons the queue with strangers' issues.** (Namespacing the label — `macf-devops-agent` — doesn't fix it either: MACF is a framework others deploy, so another fleet reuses the same labels.)

**Why the bot login can't anchor it:** the bot handle *is* globally unique, but verified live — a `[bot]` **cannot be an issue assignee** (`/assignees/macf-devops-agent[bot]` → 404). So the one globally-unique GitHub identity can't anchor a label/assignee query.

**The answer — the App installation IS the unique identity; scope the label query to it:**

```
enumerate  /installation/repositories   →   for each repo:  gh issue list --label <mine>
```

- **App-install set** = "repos that are *mine*" — globally unique (it's literally my App's token; verified: returns exactly our 6 repos, **excludes** `rafamqrs`).
- **label** = the intra-repo disambiguator (which of *our* agents in a shared repo).
- **(App-install set) × (label) = unique + complete + drift-free** — bounded like the hardcoded loop (no poisoning), complete like the search (auto-updates when the App is installed on a new repo), no hardcoded-list drift.

**And it's complete-by-CONSTRUCTION, not best-effort** — because of the install-boundary finding below.

### 6. Install boundary = action boundary = queue boundary (verified)

Operator question: *can an agent be @mentioned in a repo where its App is NOT installed, and comment/review there with its unique identity?* Verified live — **no**, and this is load-bearing for §5's completeness claim:

| In a NOT-installed repo | Result (verified) |
|---|---|
| someone **types** `@macf-devops-agent[bot]` | renders (handle is global) — **but inert** |
| bot **receives** the mention (routing/wake) | ❌ App webhooks fire only for installed repos |
| bot **reads** a public issue | ✅ — but that's anonymous public-read, not "acting as the bot" |
| bot **comments / reviews** | ❌ **404/403** — the install token has no write scope there |

**The App identity is installation-scoped: to *act* (comment/review/receive-mention-routing), the App must be installed.** There is no "act as the bot but not installed" path (the only alternative is acting as the *operator's* PAT — the attribution trap we avoid). The `rafamqrs` issue is the live proof: titled `[DevOps Agent] …`, world-readable, but it never *reached* us and we *cannot* act on it.

**Consequence:** the install set is not merely an efficient scoping — it is the **exact and complete action boundary**. An agent literally *cannot* act outside its install set with its own identity, so there is **no "active outside my install set" case to miss**. That's why §5's App-install-set enumeration is complete *by construction*, and why the inert-mention case is correctly *excluded* (the agent couldn't act there anyway). Install boundary = action boundary = queue boundary — the same set.

**Operator-facing rule (→ onboarding runbook, `macf#698`):** to bring an agent into a new repo you **install its App there** — then webhooks fire (mentions route + wake), it can comment/review, *and* the queue-enumeration picks it up automatically. A mention typed in a not-installed repo is a **silent black hole** (renders as a link; the typer may think they reached the agent; the agent never sees it and couldn't act). So "install-to-participate" is the rule; `macf onboard-agent` (#698) makes **install-the-App-on-the-repo** step one.

---

## Build split & ownership

Mirrors DR-006↔DR-031 and DR-007↔DR-037: the **channel-server delivery contract is framework (code + science)** — literally DR-023's deferred Phase 2.5; **devops owns the substrate + the reconciliation-discipline promotion.**

| Piece | Owner |
|---|---|
| persistent inbox/outbox + message-id + dedup + retry-to-ACK (Phase 2.5) | **code + science** (DR-023 extension) |
| the store *interface* + drain-on-recovery + effectively-once contract | **code + science** |
| startup-reconciliation: extend the plugin's `startup_check` from issue-queue-only → drain-inbox + reviews/gates/mentions | **code** (the plugin owns SessionStart) |
| **App-install × label queue-source** (replace the hardcoded loop; §5) | **code** (plugin/CLI) — aligns with `macf onboard-agent` #698's App-install enumeration |
| the VM disk-spool store driver; the K8s PVC/broker driver | **devops** (substrate) |
| `coordination.md §5` sweep-logic → the injected startup step | **devops** (canonical rule) + **code** (wiring) |
| the onboarding "install-to-participate" note | **→ `macf#698`** (this DR files it) |

---

## Boundaries / non-goals

- **Not** replacing GitHub-anchored coordination — that stays the durable substrate; this adds durability to the *direct* path only.
- **Not** a central message broker as the default — the VM store is a local disk spool (extend `comms-ledger`); a broker is the *K8s* driver, not a VM dependency.
- **Not** the macf-operator / K8s design — that's future; this DR only fixes the store as a pluggable driver so K8s is a driver-swap, not a rewrite.
- **Not** guaranteed *ordering* — effectively-once delivery, not a total order (agents coordinate through GitHub for anything order-sensitive).

---

## Open questions (for the framework study)

1. **ACK transport** — synchronous ACK on the `message/send` response, or a separate ACK message? (Sync is simpler; async survives a receiver that accepts-then-restarts-before-processing.)
2. **Retry budget + dead-letter** — how many retries before an undeliverable direct message falls back to a GitHub-anchored escalation (so it doesn't retry forever into a permanently-gone peer)?
3. **Inbox drain trigger** — on SessionStart injection (§4), or a channel-server-internal drain-on-reconnect, or both?
4. **message-id shape** — ULID / UUID / content-hash? (dedup + ordering-hint tradeoffs.)
5. **Store-driver interface** — the exact methods (append / ack / drain / dedup-seen) the VM-spool and K8s-broker drivers both implement.

---

## Cross-references

- **`macf` DR-023** — the channel-server + A2A architecture; its deferred **Phase 2.5** (task-store durability) is what §2 realizes.
- **DR-006 ↔ `macf` DR-031** ; **DR-007 ↔ `macf` DR-037** — the same devops-design ↔ framework-contract split this DR follows.
- **`coordination.md §5`** — the pull-based gate/review sweeps §4 promotes from manual discipline to an injected startup step.
- **`silent-fallback-hazards.md`** — at-most-once A2A drop + the inert-mention black hole are both silent-fallbacks; the reconciliation is Pattern A at startup.
- **`macf#698`** — the add-an-agent onboarding runbook; §6's install-to-participate note lands there; §5's queue-source aligns with `macf onboard-agent`'s App-install enumeration.
- **`agent-identity.md §"Checking for Work"`** — the hardcoded per-repo loop §5 replaces.
