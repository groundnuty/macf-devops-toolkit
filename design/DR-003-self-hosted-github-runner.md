# DR-003 — Self-hosted GitHub Actions runner on the VM (routing-latency spike → hardened permanent)

**Status:** Accepted (scaffolding); **register/start gated** — see "Gates" below.
**Refs:** macf-devops-toolkit#90 (this repo's slice), groundnuty/macf-actions runner-enablement (sibling), groundnuty/macf-actions#47 (T4 `PR_TITLE` injection hardening — HARD GATE), macf#444 (A/B telemetry instrument).
**Reporter / A/B owner:** `macf-science-agent[bot]`. **Host setup:** `macf-devops-agent[bot]` (this repo).

## Context

The MACF routing workflow runs on GitHub-hosted runners. The latency investigation (operator-greenlit 2026-06-08) found **~46% of routing wall-clock is Tailscale** (connect + a `sleep 10`) — a runner *on the VM* pays none of it: it's already on the tailnet/LAN, and the inject becomes a local `tmux send-keys`. Expected ~40s → ~6-9s (~4-6×).

## Decision

Register an **org-scoped, ephemeral, `self-hosted,macf-vm`-labeled** `actions/runner` on the VM that the routing workflow can target. Org-scoped (`--url https://github.com/groundnuty`) covers all MACF repos in one registration; the **runner group is scoped to exactly `groundnuty/macf` + `groundnuty/macf-actions`** and egress is restricted to the agent host + Tempo.

## Security analysis (the load-bearing part)

A self-hosted runner executes the triggering workflow's code **on the VM as its registered user**. The blast radius of any workflow-code RCE (an un-hardened `PR_TITLE` interpolation; a fork PR carrying secrets/write-tokens) is therefore bounded by **that user's** access.

As **`ubuntu`**, that is *total*: the App `.pem` keys (every bot identity), `~/.kube`, the agents' tmux sockets, and every agent's `/proc/<pid>/environ`. RCE-as-ubuntu = impersonate any bot, drive any agent's tmux, exfil every key.

### Run-as user — low-priv `macf-runner` **from the start** (operator-confirmed 2026-06-08, #90 thread)

The original operator decision was *spike-as-`ubuntu`, then harden*. On review (#90 thread) science + devops both reversed this, and **the operator confirmed (2026-06-08)**, because: **the latency win comes entirely from the runner being ON the VM** (no Tailscale, local inject) — the run-as user is orthogonal to the measured number. So spike-as-`ubuntu` buys nothing for the A/B and only adds the full-compromise exposure above; it also invites the "spike becomes the deployment by inertia" risk #90's own AC flags.

**Decision:** create a dedicated `macf-runner` user up front whose ONLY grant is the agents' tmux socket + the `tmux-send-to-claude.sh` helper — **NO `*.pem` App keys, NO `~/.kube`, NO other agents' `/proc/*/environ`.** Same ~4-6× number, bounded blast radius from minute one. `RUNNER_USER` is parameterized in `hack/setup-github-runner.sh` (default `macf-runner`).

## Gates — ALL required before the runner registers/starts (incl. the spike)

The spike's A/B routes **real** `issue_comment`/PR events through the VM runner during the measurement window — that **is** "serving real routing," at full blast radius for the duration. So these gate the spike, not just "permanent":

1. **T4 — `macf-actions#47`** (`PR_TITLE` injection hardening: pass as data, not interpolated) **landed.** Currently OPEN.
2. **Fork-PR toggles OFF** + **fork-approval-required** on `groundnuty/macf` + `groundnuty/macf-actions` (operator — bot is 403). Without this a fork PR's workflow runs on the VM with secrets = RCE.
3. **Org-scoped registration token** (operator / org-admin — bot is 403).
4. **Runner group scoped** to `macf` + `macf-actions` only; **egress restricted** to agent host + Tempo (operator / org-admin).

This PR (scaffolding) wires **none** of register/start — it is inert and reversible until the gates clear.

## Ephemeral + respawn

`--ephemeral` makes the runner deregister + exit after one job (clean per-job state, no leakage). To keep serving, a **respawn wrapper** loops: mint a fresh registration token → `config.sh --ephemeral --token <fresh>` → `run.sh` (one job) → repeat. Registration tokens are short-lived + org-admin-scoped, so the respawn needs an **org-admin token-mint credential** on the host (a GitHub App / PAT with `organization_self_hosted_runners: write`) exposed via a pluggable `RUNNER_TOKEN_CMD` — an operator setup, NOT a `*.pem` the low-priv user otherwise holds.

**Spike simplification (optional):** for the time-boxed A/B a **non-ephemeral** runner (register once, persistent) avoids the token-mint dependency and is sufficient to prove the number; ephemeral + respawn is the production posture. `EPHEMERAL=true|false` is parameterized.

## Sequencing

`scaffold (this PR)` → [token + #47 landed + fork-toggles off + run-as confirmed] → `register + start` → **A/B measurement** (science owns) → if spiked as `ubuntu`: **harden to `macf-runner`** → **permanent** (ephemeral + respawn + token-mint). Don't let the spike become the deployment by inertia.

## Alternatives considered

- **GitHub-hosted runner + faster Tailscale** — can't remove the connect + the load-bearing `sleep 10`; the ~46% is structural to off-VM.
- **Spike-as-`ubuntu` (original)** — rejected on the security analysis above; the run-as user doesn't affect the latency number.
- **Non-org (repo-scoped) runner** — would need per-repo registration; org-scoped + group-scoping gets the same containment with one registration.
