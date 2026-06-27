# DR-006 watchdog — live rollout runbook (ride the v0.2.40 relaunch)

The watchdog is built + **live-dry-run-validated** end-to-end (macf-devops-toolkit#118).
The remaining step is bringing it **live** (`--execute`) — staged, operator-gated.
The natural moment is the **v0.2.40 release + fleet relaunch**: a fresh, cleanly-
registered fleet, and the same relaunch that closes the verify-on-release items.

**Posture:** never jump straight to `--execute --allow-restart`. Each stage proves
the prior one against the live fleet before widening blast radius. Stages 0–3 touch
no agent (read-only / report-only). Stage 4+ acts; do it **with the operator**.

---

## Stage 0 — the relaunch lands (operator)

1. v0.2.40 published (channel-server + CLI) → **relaunch each agent** onto it.
2. **Verify-on-release (devops, rides this relaunch):**
   - **#590** — `invoke_agent` spans now emit kebab `gen_ai.agent.name` (not
     `DEVOPS_AGENT`). Query Tempo (post-relaunch window) → confirm only kebab →
     **close #590** (reporter).
   - **#627** — a real-agent `/exit` now deregisters cleanly (no stale entry until
     TTL). Re-run the throwaway-agent `/exit` test against the deployed cs →
     confirm deregister → **close #627** (reporter).

## Stage 1 — desired-state manifest (operator/devops, one-time)

    cp fleet/desired-agents.example.yaml ~/.macf/desired-agents.yaml
    # confirm the 4 substrate agents + their workspaces (code's home is `macf`,
    # NOT macf-code-agent — agent↔workspace isn't 1:1 with the handle).

## Stage 2 — live dry-run (read-only; touches nothing)

    GH_TOKEN=$(...mint...) ./fleet/reconcile.sh --manifest ~/.macf/desired-agents.yaml --with-routing

Expect: the 4 agents `OK` (post-relaunch all up). Any `HEAL`/`LAUNCH` here is a
**real signal** to investigate before going further (e.g. a stale registration the
relaunch should have cleared, or an agent that didn't come back).

## Stage 3 — report-only cron (acts on nothing; build trust)

    ./fleet/install-cron.sh --with-routing            # report-only, every 10 min, token-mint baked
    crontab -l | grep macf-watchdog                   # verify installed
    tail -f ~/.macf/watchdog.log                      # watch a few cycles

Watch for: correct decisions each sweep, and the token-mint working (no 401 in the
log). The log itself proves the sweep ran (the heartbeat file is execute-gated, so
it only starts updating at Stage 4). Let it run several cycles; confirm steady-state
is "all OK, no action."

## Stage 4 — `--execute` (ACTS: launches a missing desired agent) — WITH THE OPERATOR

The one **unvalidated-live** path is the LAUNCH wrapper (it spawns a real
`claude.sh`). Validate it deliberately:

1. **Controlled LAUNCH test:** pick ONE agent, stop it on purpose **by signal**
   (so last-exit≠0 → the reconciler will relaunch it — NOT `/exit`, which is
   desired-down). Run one `--execute` sweep by hand:

        ./fleet/reconcile.sh --manifest ~/.macf/desired-agents.yaml --with-routing --execute

   Confirm it launches `macf@<agent>` correctly (identity, cert, registration),
   the agent comes back healthy, and the exit-code wrapper wrote `~/.macf/last-exit/<agent>`.
   **Mind the auditor carve-out:** its `role` must stay `auditor` through any relaunch.
2. **Confirm the don't-fight-the-operator path:** `/exit` an agent yourself →
   confirm the next sweep SKIPs it (last-exit==0 → desired-down), does NOT relaunch.
3. Once both pass, install the acting cron:

        ./fleet/install-cron.sh --with-routing --execute     # Tier-2 restart still HELD

## Stage 5 — `--allow-restart` (Tier-2 graceful-restart of a deaf agent)

Only after Stage 4 is trusted. Enables the watchdog to SIGTERM+relaunch a
confirmed-deaf agent (the macf#553-class auto-heal):

    ./fleet/install-cron.sh --with-routing --execute --allow-restart

## Rollback (any stage)

    ./fleet/install-cron.sh --uninstall      # remove the cron immediately

`paused` an individual agent without uninstalling: `touch ~/.macf/paused/<agent>`
(the reconciler SKIPs it; remove the sentinel to resume).

## Follow-ups (not blocking the rollout)

- **#123** — heartbeat external consumer (a monitoring-VM alert on heartbeat-age
  closes the who-watches-the-cron loop; until then the heartbeat is stamp-only).
- K8s — deferred (an operator/controller, not static manifests, when agents move
  to pods).
