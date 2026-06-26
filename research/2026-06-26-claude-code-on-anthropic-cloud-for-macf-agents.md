# Can a MACF agent run on Claude Code's Anthropic-hosted cloud? (research)

**Date:** 2026-06-26
**Context:** While reviewing the supervision DRs (`macf` DR-031 + `macf-devops-toolkit` DR-006), the operator raised the heterogeneous-fleet question — agents may run on VMs, Kubernetes, **or Claude Code on Anthropic's cloud** (`claude.ai/code`). The operator has used cloud-code with hooks and reports its sandbox is "kind of restrictive." Question: **can a MACF agent run there, and does the supervision/routing model apply?** Research the docs first; experiment later if warranted.
**Method:** Live-fetched the current official docs 2026-06-26 (cloud-code is a research preview + evolving, so training data is unreliable — per `feedback_verify_devops_versions`). Two passes: direct WebFetch of the "Claude Code on the web" Network-access section + the sandboxing engineering post; a `claude-code-guide` deep dive across 9 capability dimensions. Citations inline.

## TL;DR

**A cloud-code session cannot be a push-routed MACF peer** — the three things our routing+supervision model assumes (an **inbound** mTLS `/health` port reachable by the GitHub-Actions router, **tailnet** membership, and a **persistent** cert/identity) are all unavailable. Outbound is an **HTTP/HTTPS allowlist proxy** only (no raw TCP / arbitrary-port / VPN), the filesystem **does not persist across sessions**, and there is **no cron/always-on** primitive.

**But cloud-code is viable as a different agent *class*** — an **event-driven worker** (Anthropic's **Routines** + auto-fix-PRs fire a fresh session on a GitHub event / schedule, it clones → works → pushes a PR → exits). That's outbound-only + ephemeral + Anthropic-supervised — a fundamentally different connectivity + supervision contract from our always-on push-routed peers.

**And the operator's second pointer — Claude *Managed Agents* — opens a third, more capable path,** especially its **self-hosted-sandbox** mode: Anthropic runs the agent *harness* (model loop, session state, checkpointing, a durable **work queue**, built-in **liveness + graceful-stop + agent-versioning**) while **tool execution runs on infrastructure you control** — so on our VM the tools get **our** network (tailnet, cluster, no allowlist proxy). Delivery inverts to a **poll-based queue** (our worker polls Anthropic, outbound-only → **no inbound needed**; work *queues* if the worker is down). This is the option that genuinely *could* host a MACF agent with full network access — but it's a **re-platform** of the Stage-3 transport, not a tweak to the supervision DRs. So the heterogeneity maps to **three agent classes**, not one capability gradient.

## Capability matrix (vs. what a push-routed MACF agent needs)

| Dimension | Finding | MACF need | Verdict |
|---|---|---|---|
| **Execution env** | Anthropic-managed Linux container per session, bubblewrap OS-level sandbox; sessions persist across browser-close, monitorable from mobile. Research preview (Pro/Max/Team/Enterprise). | a place to run | ✅ runs |
| **INBOUND network** | Not documented/supported — no listening-port-reachable-from-outside, no tunnel/public-URL, no Tailscale. The sandboxing post: outbound-proxy only; "inbound connectivity and non-HTTP protocols are not mentioned as supported." | router (GHA) → agent mTLS `/health`; peer A2A inbound | 🔴 **NO — load-bearing blocker** |
| **OUTBOUND network** | Levels **None / Trusted (default; allowlisted package+GitHub+cloud-SDK domains) / Full (any domain) / Custom**. But strictly an **HTTP/HTTPS proxy** ("Environments run behind an HTTP/HTTPS network proxy"). Raw TCP / non-HTTP / arbitrary host:port not supported through it. | OTLP to collector:4318; mTLS to peers; `gh` to api.github.com | 🟡 HTTP-allowlist only — `gh` ✅; OTLP/mTLS to our **tailnet-only** VM ❌ (would need a public HTTPS-allowlistable collector) |
| **Tailnet (Tailscale)** | Not supported (no `tailscaled`, no VPN). | reach the cluster + peers over the tailnet | 🔴 NO |
| **Long-lived background process** | Docs silent on whether a spawned server survives across turns. | channel-server stays up listening | 🟡 **UNCLEAR — needs experiment** (and moot for inbound) |
| **MCP servers** | Remote MCP ✅ (routed via Anthropic, no allowlist needed). stdio MCP: not explicitly cloud-documented — likely-yes, verify. | channel-server is an MCP stdio child | 🟡 likely-yes (verify), but it must also *bind an inbound port* → blocked anyway |
| **Filesystem persistence** | Fresh container per session; **no documented cross-session persistence**. `~/.macf` certs/config do **not** carry over. | persistent agent cert/identity (CN=routing-label) | 🔴 NO — re-provision every session |
| **Lifecycle / always-on** | Task-driven, not daemon-like; no idle-timeout SLA documented. **Routines** (schedule / API / GitHub-event) is the *separate* scheduled primitive. "Restart" = create a *new* session (immutable). | always-on peer + `restart-self` | 🔴 no always-on; ✅ but only as event-triggered |
| **Hooks** | ✅ supported; detect via `$CLAUDE_CODE_REMOTE=true`; restriction — no `/dev/tty` (use `terminalSequence` in hook JSON). | the MACF PreToolUse/Stop hooks | ✅ (with the tty caveat) |
| **Sandbox specifics** | bubblewrap; writes scoped (cwd-centric); `sudo`/privileged-ports undocumented; pre-install via a `packages` config (apt/npm/pip/cargo/gem/go). | bind ports, write `~/.macf`, install tools | 🟡 partly — writes outside cwd + privileged ports likely blocked (verify) |

## Why the current push model is incompatible (the three-way block)

Stage-3 routing is **router → agent**: a GHA runner joins the tailnet and **mTLS-POSTs to the agent's `/health`/notify endpoint** at a registry-published `host:port`. A cloud session provides **none** of the three preconditions:

1. **No inbound** → nothing for the router to POST to.
2. **No tailnet** → even if it could listen, it's not on the network the router reaches it over.
3. **No persistent identity** → the per-agent leaf cert (CN=routing-label) + registry registration can't survive a fresh-container-per-session.

Supervision (DR-031/DR-006) inherits the same blocks: `restart-self` (Anthropic owns the lifecycle; "restart" = new session), the cron trigger (no user cron; Routines is the substrate scheduler), and the `/health` self-report (no inbound to serve it).

## The viable alternative: cloud-code as an *event-driven worker* class

The docs surface a genuinely different execution model that **sidesteps inbound entirely**:

- **Routines** — "automate work on a schedule, via API call, or **in response to GitHub events**" on Anthropic infra.
- **Auto-fix PRs** — cloud sessions "respond automatically to CI failures and review comments."

So a cloud MACF agent would be **outbound-only + ephemeral + event-spawned**: a GitHub issue/label/mention (or schedule) fires a Routine → a fresh session clones the repo, does the work, **pushes a PR via the GitHub proxy**, and exits. It never listens, never joins the tailnet, never holds a persistent cert. Its "supervision" is Anthropic's infra (the substrate is the scheduler + the respawner). This is a **second agent class** with its own contract — not the push-routed peer the supervision DRs are about.

**Trade-offs of the event-driven class:** no peer-to-peer A2A push (it's not reachable); coordination is GitHub-state-mediated (it reads issues/PRs on spin-up, writes PRs/comments out); telemetry needs a **public** HTTPS OTLP endpoint (our tailnet-only collector won't do); no mid-task wake (it runs to completion then dies). For tasks that are "triggered → bounded work → PR" (much of code-agent's and devops-agent's actual workload), that's a clean fit; for a long-lived coordinator that must be reachable at any moment, it isn't.

## What the docs leave open (would need a live experiment, *only if we pursue the event-driven class*)

1. Does a spawned background process (e.g. `node server.js`) survive across turns within one session? (Mostly moot — inbound is blocked regardless.)
2. stdio-MCP support in cloud sessions (the channel-server packaging).
3. Actual write-scope outside cwd; `sudo`; privileged-port binding.
4. Session idle-timeout / lifecycle SLA; how Routines' GitHub-event triggering maps to the MACF label-routing model.

A minimal experiment: a Routine triggered on a labeled issue that does `gh pr create` and emits one OTLP span to a **public** collector — confirms the event-driven loop end-to-end without needing any inbound.

## Claude Managed Agents (the operator's second pointer) — a different architecture, the genuinely viable path

Managed Agents (`platform.claude.com/docs/en/managed-agents/*`, beta `managed-agents-2026-04-01`) is Anthropic's **agent harness as a managed service** — *not* the interactive web IDE. It changes the picture: it **inverts delivery** (the Anthropic API is the inbox) and offers a **self-hosted** execution mode.

**The model.** Four concepts: **Agent** (model + system prompt + tools + MCP servers + skills, *versioned*), **Environment** (where sessions run — Anthropic cloud sandbox *or self-hosted on your infra*), **Session** (a running instance — *stateful, runs for hours, checkpointed, resumable, 30-day*), **Events** (messages between your app and the agent). An external caller `POST /v1/sessions/$ID/events` a `user.message`; the agent runs autonomously; results stream back via SSE. **The agent never listens on a port — the API is the inbox.**

**Two execution modes, very different for MACF:**

| | C1 — Managed Agents, **Anthropic cloud sandbox** | C2 — Managed Agents, **self-hosted sandbox** |
|---|---|---|
| Where tools run | Anthropic infra | **your VM / cluster** |
| Tool network | Anthropic allowlist proxy; no tailnet | **your network policy** — tailnet, cluster, internal hosts ✓ |
| Inbound | none (API is inbox) | none — **worker polls Anthropic** (outbound HTTPS) |
| Delivery | POST events to the session | session enqueued → **your worker claims it** (`ant beta:worker poll`); *queues* if no worker |
| Persistence | checkpoint (30-day) | your filesystem (you manage) |
| Liveness | — | **`work.stats.workers_polling`** (built-in) |
| Stop / upgrade | `work.stop` / **agent versioning** (pin + staged rollout) | same |

**Why C2 (self-hosted) is the one that matters.** It clears every blocker that killed cloud-code-web *for an agent that needs our network*: tool execution + files + egress stay on our infra (tailnet + cluster reachable), delivery is a **durable poll queue** (outbound-only; work survives a down worker — sturdier than mTLS-push), and Anthropic provides *for free* the very primitives DR-031/DR-006 are hand-building — **`workers_polling` liveness**, **graceful `work.stop`**, **native agent-versioning** (the declarative upgrade). The worker runs anywhere (Anthropic lists VM / GKE-Agent-Sandbox / Lambda / Cloudflare / E2B / Modal / Vercel), so it's **multi-substrate by construction**.

**Why it's a re-platform, not a tweak.** C2 replaces the Stage-3 channel-server / mTLS / tailnet / registry machinery with the Managed-Agents harness: the "router" becomes *create-a-session with the issue ref in `metadata`*; the channel-server becomes *the worker process*; the registry becomes *the environment + work queue*; telemetry may move to Managed-Agents **session tracing**; coordination (@mentions/routing) stays GitHub-mediated. Costs to weigh: **beta**; **no Memory with self-hosted**; **no ZDR/HIPAA** (stateful); **API billing** (the model runs on Anthropic, tool I/O flows to the control plane — a data-flow boundary to accept); MCP **vaults** might replace the GH-App-token refresh dance (worth checking).

**Open (one experiment resolves it):** stand up a `self_hosted` environment + `ant beta:worker poll` on the monitoring VM; an agent whose tools `gh`-clone + push a PR; create a session with an issue ref in `metadata` → confirm queue→claim→work→PR end-to-end **and** that the worker's tool execution reaches the tailnet cluster.

## Recommendation

- **For DR-031 + DR-006 (now):** unchanged — scope the supervision/routing model to **VM + Kubernetes** (inbound + persistent identity + a respawn primitive), and mark **all Anthropic-cloud options out-of-scope-*with-rationale*** (different connectivity contracts, above), not unsupported-by-accident. **Don't block ratification** — the supervision DRs stand on VM+K8s; everything here is additive future scope.
- **Two distinct future Anthropic-cloud paths, each its own design + experiment:**
  - **Event-driven worker (interactive cloud-code / Routines):** ephemeral, outbound-only, GitHub-event→PR. Cheapest to try; fits "trigger → bounded work → PR"; doesn't fit a long-lived reachable peer.
  - **Managed Agents self-hosted (C2):** the strategically interesting one — Anthropic harness + **our-infra tool execution** + poll-queue delivery + **built-in liveness/stop/versioning**. Could host a full MACF agent *and replace much of the supervision machinery we're building*. It's a **re-platform of the Stage-3 transport** → its own DR + the one experiment above + an explicit cost/data-flow decision; not a fold-in.
- **Sequencing:** ratify DR-031/DR-006 (VM+K8s) now; treat **Managed-Agents-self-hosted as a separate strategic spike** to schedule deliberately — it could simplify the fleet, or it could be a beta we don't want a hard dependency on yet. A call for the operator + science, informed by the one experiment.

## Sources

- [Use Claude Code on the web — official docs](https://code.claude.com/docs/en/claude-code-on-the-web) (Network access levels, GitHub proxy, security proxy, default allowlist, Limitations, `--remote`/`--teleport`)
- [Managed Agents: cloud environment setup — Anthropic API docs](https://platform.claude.com/docs/en/managed-agents/environments) (network modes, container-per-session, packages)
- [Making Claude Code more secure and autonomous with sandboxing — Anthropic Engineering](https://www.anthropic.com/engineering/claude-code-sandboxing) (outbound-proxy-only network isolation; cwd-scoped writes)
- [Hooks — Claude Code docs](https://code.claude.com/docs/en/hooks) (`$CLAUDE_CODE_REMOTE`, `/dev/tty` restriction)
- [Routines — Claude Code docs](https://code.claude.com/docs/en/routines) (schedule / API / GitHub-event triggers — the event-driven primitive)
- [MCP — Claude Code docs](https://code.claude.com/docs/en/mcp)
- [Claude Managed Agents — blog announcement](https://claude.com/blog/claude-managed-agents) (positioning; long-running sessions; persistence)
- [Managed Agents overview — Claude Platform docs](https://platform.claude.com/docs/en/managed-agents/overview) (agent/environment/session/events model; SSE; stateful; beta header)
- [Start a session — Managed Agents docs](https://platform.claude.com/docs/en/managed-agents/sessions) (`POST /v1/sessions` + `/events` `user.message` — API-as-inbox delivery; vaults; checkpoint/30-day)
- [Self-hosted sandboxes — Managed Agents docs](https://platform.claude.com/docs/en/managed-agents/self-hosted-sandboxes) (tool execution on your infra + your network; the poll-based work queue; `ant beta:worker poll`; `work.stats.workers_polling` liveness; `work.stop`; multi-substrate worker integrations)
