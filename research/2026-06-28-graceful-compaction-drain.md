# Graceful compaction-drain — research + design-fit

**Date:** 2026-06-28
**Question (operator):** automate "prepare-for-compaction" — when an agent's context nears full, (1) stop it taking new work (block/queue incoming), (2) inject a prompt to consolidate memory + CLAUDE.md, (3) compact, (4) resume the queue. Does it fit our design?
**Method:** two parallel research agents — (A) Claude Code native compaction lifecycle (official docs), (B) state-of-the-art in long-running-agent context management (first-party docs/papers + community). Findings distilled below; full reports in the 2026-06-28 session transcript.

## TL;DR — it fits, and we already do the hard part

The single most-important best-practice (per every first-party source: Anthropic, Manus, Letta, Cognition) is **continuously externalize durable state to agent-authored files AS YOU WORK — not lazily at compaction.** We already do exactly this (`reflection-staging.md` → `pending.json` staged as-I-go; `project_state_*.md` memory updated throughout; restorable pointers everywhere — issue#s, paths, SHAs). So the drain doesn't *create* the durable state — it **finalizes** already-written state. That's the part most frameworks get wrong, and we get right.

What's genuinely new to build (SOTA confirms it's **not standardized** in any agent framework): the **drain/quiesce phase** (stop taking new work) + a **proactive near-full trigger**. Both are external to Claude Code (no native support), and both map onto infrastructure we already have (the channel-server queue + the watchdog/monitor + the capture-pane-diff/send-keys primitives).

## A. Claude Code native compaction lifecycle (research agent A)

| capability | native? | detail |
|---|---|---|
| **PreCompact hook** | ✅ | fires before compaction; `auto`/`manual` matchers; **can run commands**; **can block** (exit 2); **cannot inject context**; 600s timeout. We use it (harvest-reflection + transcript archive). |
| **PostCompact hook** | ✅ exists | fires after; **cannot inject context**; payload/summary undocumented (use SessionStart instead). |
| **SessionStart `source=compact`** | ✅ | fires after compaction; **CAN inject `additionalContext` (≤10K chars)** → the canonical "resume your queue" home. We have a SessionStart hook. |
| **`/compact [instructions]`** | ✅ self-triggerable | the agent can type it, with a focus hint; no SDK/CLI/hook trigger (Claude Code TUI). |
| **`autoCompactEnabled`** | ✅ setting | on/off only — **no tunable threshold**. |
| **context-fullness signal** | ❌ | NO env var / hook field / API. Only `/context` (visible in-session). Threshold opaque. → detection must be external. |
| **quiesce / pause mode** | ❌ | NO native `/pause`/`/drain`. `/background` ≠ pause (keeps working). → block-incoming must be external (our queue). |
| **thrashing guard** | ✅ (caution) | CC stops auto-compacting after a few attempts if a huge tool output refills context immediately — bound retries. |

**Native-automatable:** PreCompact runs logic + can block; SessionStart(compact) injects resume context; `/compact` self-triggerable. **Build externally:** fullness detection, quiesce/queue-hold, the orchestration.

## B. State of the art (research agent B)

**Two-track memory model is the consensus** (both tracks, mature systems run both):
- **Auto-summarize/evict** (harness decides): MemGPT recursive summarization (70% warn / 100% flush); Anthropic **compaction** (summarize near-limit → fresh window seeded with summary + 5 most-recent files; preserve decisions/bugs/next-steps, drop redundant tool output); **context-editing** `clear_tool_uses` (evict re-fetchable tool results > trigger, keep last 3, leave placeholders); LangGraph `SummarizationNode`.
- **Agent-authored persistence** (agent decides): **Anthropic memory tool** `memory_20250818` — a `/memories` file API with a hard-coded *"ASSUME INTERRUPTION: your context may reset at any moment; record progress to memory"* protocol + an official **"Using with compaction"** section + a **multi-session software pattern** (`init.sh` + `claude-progress.txt` + a feature-checklist JSON; each session re-hydrates by reading the log + git log). Letta self-edited memory blocks; Manus's **"compression must always be restorable"** (drop the body, keep the URL); LangGraph semantic/episodic/procedural store.

**Keep-vs-drop consensus:** keep **decisions, open problems, task/plan state, and restorable pointers**; drop verbose/stale tool outputs (cheapest to evict, most restorable).

**Trigger:** proactive **token-count with headroom**, not at the wall (motive: "context rot" — recall degrades before the limit). Anchors: Anthropic Compaction API default **150K trigger** (200K window); MemGPT **70%/100%**. (Community-reported CC TUI auto-compact ≈ 84–95% of usable budget — flagged community, not first-party.)

**Drain/quiesce — the notable gap:** **NO production agent framework names a "do-not-disturb before compaction" phase.** They emulate it via **tool/turn-boundary input queuing** (Claude Code reads steering input at the next tool boundary, not mid-action) + **safe-boundary checkpointing** (LangGraph super-steps, ADK state-machine stages, CrewAI `@persist`). The underlying DS drain (stop polling → finish in-flight in a grace window → reset) is borrowed from Temporal/gRPC `GracefulStop`/K8s `preStop`+`terminationGracePeriod`/Ray `DRAINING`. **→ our explicit drain phase is a defensible, novel extension; snap it to a turn/tool-call boundary** (mirror CC's input-queue model — finish the current turn, then drain).

**Resume-after-reset:** in-place summary block (Anthropic compaction `pause_after_compaction: true` → inject before resuming) OR externalized file-state re-hydration (the multi-session pattern) OR sub-agent context isolation (return a 1–2K summary to the parent). **Memory + compaction are explicitly complementary (first-party):** *"compaction keeps active context small; memory preserves what must survive summarization."*

**The 3 design choices that matter most (SOTA synthesis):**
1. **Durable file-memory written continuously, not lazily at drain** — else a crash mid-drain loses it. The drain *finalizes*; it doesn't create. ← **we already do this.**
2. **Compact-with-restorable-pointers, not lossy-summarize** — keep decisions + next-steps + re-fetchable refs (paths, issue#s, queries); drop verbose tool output. The highest-leverage keep/drop rule for reliable resume. ← **our memory files already do this.**
3. **Proactive token-threshold trigger with headroom + a thrashing guard.** ← **the gap (no native CC signal — build external).**

## C. Design fit — the graceful-drain maps onto what we have

| drain phase | native CC | our existing piece | new build |
|---|---|---|---|
| **detect near-full** (proactive, headroom) | ❌ no signal | the watchdog/monitor pattern | **transcript-size proxy** estimator (sibling of the watchdog) |
| **quiesce / block incoming** (at a turn boundary) | ❌ no pause | channel-server `/notify` queue | a **`draining` flag** the wake-path respects (sibling of `paused`) → hold incoming until resume |
| **inject "prep now" prompt** | ✅ send-keys | the resume/auto-responder primitive (#131/#645) | a new allowlisted message: "consolidate memory + CLAUDE.md, finalize pending.json, then `/compact`" |
| **stage durable state continuously** | — | `reflection-staging` + `pending.json` + `project_state_*` memory | (already done — drain finalizes) |
| **harvest at compaction** | ✅ PreCompact | `harvest-reflection.sh` | (already wired) |
| **compact** | ✅ `/compact` | — | self-triggered after prep (or auto-compact) |
| **resume queue** | ✅ SessionStart(compact) additionalContext ≤10K | the SessionStart hook | inject the held queue + "resume" via additionalContext; channel-server flushes the held queue |

**The realization:** our **current manual process** (operator asks "fix your memories before compaction") IS the best-practice graceful-drain — we just do it operator-triggered + manual. Automating it = (a) external near-full trigger replacing the operator's nudge, (b) `draining` flag at the channel-server (snap to turn boundary), (c) send-keys the prep prompt, (d) SessionStart(compact) resume-injection. Every piece is an existing primitive.

**It's the 6th member of the unattended-operation family** — detect-state → controlled-action, channel-server queue as the shared control plane: #641 channels / #642 reliability / #645 launch-prompts(answer) / #131 resume(nudge) / #132 operator-blocked(report) / **compaction-drain(quiesce+compact+resume)**. Same `idle/state + signature → action` spine; here the state is "context near-full" and the action is "drain".

## D. Risks / design cautions

- **Order is strict:** finalize-memory → quiesce(turn boundary) → compact → resume. A compact *before* memory-finalize loses in-flight reasoning (mitigated because we stage continuously, but the drain must still finalize first).
- **No native fullness signal** → the transcript-size proxy is an estimate; calibrate the threshold with headroom (≈ the 150K/70% anchors) + a thrashing guard (don't re-drain immediately if a huge artifact refilled context).
- **`additionalContext` ≤10K** caps the resume-injection — so the held queue + "what was I doing" must be a *pointer* (read `project_state_*.md` + the queue file), not a dump. (Consistent with the restorable-pointer rule.)
- **Quiesce must snap to a turn/tool boundary** (SOTA) — never mid-action; the channel-server already queues at tool boundaries (CC's input model), so the `draining` flag should hold *new* work, letting the current turn finish.

## E. Recommendation

Proceed — it fits cleanly and is well-grounded. Propose as a cross-cutting design (sibling of the supervision DRs), build-split:
- **devops** (sibling of the watchdog): the near-full **detector** + the **drain orchestrator** (prep-prompt send-keys → wait → `/compact` → verify) + the SessionStart(compact) resume-injection.
- **code** (framework): the channel-server **`draining` flag + queue-hold** (block incoming, flush on resume) — the one piece I can't do in my repo.
- **science**: the small **DR** (the drain contract: order-strict, turn-boundary-quiesce, restorable-pointer resume, thrashing-guard) + the convention (what to consolidate).

## Sources (first-party unless flagged)

- Claude Code: hooks / context-window / settings / commands / memory — code.claude.com/docs
- Anthropic eng: effective-context-engineering-for-ai-agents · effective-harnesses-for-long-running-agents · multi-agent-research-system · building-effective-agents · news/context-management
- platform.claude.com: memory-tool (`memory_20250818`, verified) · compaction (`compact-2026-01-12`, `pause_after_compaction`) · context-editing (`clear_tool_uses_20250919`)
- MemGPT arXiv:2310.08560 · Survey arXiv:2507.13334 · Letta/LangGraph/LangMem docs · Manus + Cognition essays · Temporal/gRPC/K8s/Ray drain docs
- [C] community (flagged): Claude Code TUI auto-compact %-thresholds; cross-agent "compaction showdown"
