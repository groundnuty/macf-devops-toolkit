# DR-003 — Self-hosted GitHub Actions runner on the VM (routing-latency spike → hardened permanent)

**Status:** Accepted (scaffolding); **register/start gated** — see "Gates" below.
**Refs:** macf-devops-toolkit#90 (this repo's slice), groundnuty/macf-actions#49 + #52 (routing-side self-hosted enablement — `runs-on` param + skip Tailscale), groundnuty/macf-actions#47 (T4 `PR_TITLE` injection hardening — HARD GATE), bundle shipped as `v1.3.5` (`79b1364`), macf#444 (A/B telemetry instrument).
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

### The grant must be tamper-proof — setup-time assertion (#91 review MUST)

The low-priv bound rests on a single precondition: `macf-runner` must **not** be able to replace the sudoers-allowed `tmux-send-to-claude.sh` helper. If it could (rewrite the file, or write+traverse to any parent dir to swap it), the `NOPASSWD` grant would become arbitrary code as `$AGENT_OWNER` — the bound collapses to full-`ubuntu`, the exact thing this design prevents. The default (root/`ubuntu`-owned git checkout) is safe, but `phase_setup` **asserts** it rather than assuming, before the grant is ever written: it walks the helper path (and its symlink-resolved target) and every ancestor dir, modelling POSIX **traversal** — an un-searchable ancestor (e.g. a `0750` home dir) makes deeper paths unreachable, so a writable-but-unreachable dir is a non-fatal latent-risk note, not a failure; a writable+**reachable** dir or file `die`s. True-by-construction, not by-trust.

*Latent finding (this host):* the assert flagged `/home/ubuntu/repos` as `0777`. It is currently **unreachable** to a `--system` `macf-runner` (whose primary group is not `nogroup`) because `/home/ubuntu` is `0750` and denies traversal — so the bound holds — but the `0777` is worth tightening so the bound doesn't depend on `/home/ubuntu`'s perms staying `0750`.

### Accepted residual — the grant can puppet any agent's tmux (#91 review NOTE 1)

The grant is unrestricted on arguments (it must be — the router has to reach *any* agent's session). So a `macf-runner` RCE can `sudo -u $AGENT_OWNER <helper> <any-session> <any-keystrokes>` → inject arbitrary keystrokes into any agent's tmux, and an agent can run bash / use its own token. This is **bounded and inherent to routing** (no *direct* key / `~/.kube` / `/proc` access — strictly less than RCE-as-`ubuntu`), and it's the right tradeoff for the latency win. Stated plainly so the bound is never read as tighter than it is: it is "can puppet any agent via tmux," **not** "can send one tmux prompt."

## Gates — ALL required before the runner registers/starts (incl. the spike)

The spike's A/B routes **real** `issue_comment`/PR events through the VM runner during the measurement window — that **is** "serving real routing," at full blast radius for the duration. So these gate the spike, not just "permanent":

1. **T4 — the router the runner runs must be hardened AND pinned.** The hardening + self-hosted-enablement bundle (`macf-actions#47` `PR_TITLE` hardening + #42 + #49/#52) **shipped in the `v1.3.5` tag** (`v1.3.5` / `v1.3` / `v1` → `79b1364`). NB it is **`v1.3.5`, not `v1.3.4`** — `v1.3.4` was already taken by the macf-actions#45 route-correlation marker (cut 2026-06-06), so code-agent cut `v1.3.5` for this bundle. The merge/tag is not the whole gate: the VM runner executes whatever ref the **macf caller pins**. Gate-1 is satisfied only when the **macf caller is pinned to `@v1.3.5` (or floating `@v1.3`)** AND the consumer-repo variable `MACF_ROUTING_RUNS_ON` is set to the runner labels (`["self-hosted","macf-vm"]`). The tag exists; the **caller pin + var flip** are the remaining part (operator / science).
2. **Fork-PR toggles OFF** + **fork-approval-required** on `groundnuty/macf` + `groundnuty/macf-actions` (operator — bot is 403). Without this a fork PR's workflow runs on the VM with secrets = RCE.
3. **Org-scoped registration token** (operator / org-admin — bot is 403).
4. **Runner group scoped** to `macf` + `macf-actions` only; **egress restricted** to agent host + Tempo (operator / org-admin).
5. **Inject path reconciled (#52 ↔ #91)** — on self-hosted, routing must inject via the **no-SSH direct-helper** path and `AGENT_SSH_KEY` must NOT be exposed to the runner. See the section below. macf-actions#52 currently ships only the SSH path; until the no-SSH branch lands the low-priv bound does NOT hold on the runner.

This PR (scaffolding) wires **none** of register/start — it is inert and reversible until the gates clear.

## Inject path — the low-priv bound requires the no-SSH direct-helper inject (#52 ↔ #91)

macf-actions#52 enabled the self-hosted runner (parameterized `runs-on`, skipped the hosted-runner Tailscale join) but for the **inject** kept the existing **SSH send path** (the AC-accepted lower-diff fallback): the routing job writes `secrets.AGENT_SSH_KEY` to `~/.ssh/id_agent` and `ssh ${SSH_USER}@${HOST}` to run the helper — or, in the fallback, a raw `cd … && tmux send-keys …` chain (`agent-router.yml@v1.3.5`, lines ~216–230).

**That SSH path defeats the low-priv `macf-runner` bound on a self-hosted runner.** `AGENT_SSH_KEY` is a **full-shell** key for `${SSH_USER}@agent-host` (the fallback runs an arbitrary command chain, which a forced-command key can't serve). On a *hosted* runner that key lives only in the ephemeral hosted VM; on **our** self-hosted runner it is a job secret **on the agent host itself** — readable by a workflow-code RCE, the very thing #47 + the low-priv user defend against. RCE → read `AGENT_SSH_KEY` → SSH-as-`${SSH_USER}` **full shell** → the runner-user sandbox is moot. Running as `macf-runner` buys nothing if the workflow hands the attacker an agent-host shell key.

**Requirement (the bound's precondition on the routing side):** on `runner.environment == 'self-hosted'`, routing must inject by calling the helper **locally** — `sudo -u $AGENT_OWNER "$HELPER" "$TARGET" "$PROMPT"` (base64-decoded per #47), the exact invocation #91's single-command sudoers grant authorizes — and must **not** materialize `AGENT_SSH_KEY` on the box. No SSH, no agent-host shell key. This is the no-SSH direct-helper follow-up #52 offered; it is a **hard gate**, not an optimization.

**#91 needs no change** — its sudoers grant (`macf-runner ALL=($AGENT_OWNER) NOPASSWD: $HELPER`) is purpose-built for exactly this local invocation. The reconciliation is on the routing side (code-agent): land the self-hosted no-SSH branch and ensure `AGENT_SSH_KEY` is not exposed to the self-hosted arm.

## Ephemeral + respawn

`--ephemeral` makes the runner deregister + exit after one job (clean per-job state, no leakage). To keep serving, a **respawn wrapper** loops: mint a fresh registration token → `config.sh --ephemeral --token <fresh>` → `run.sh` (one job) → repeat. Registration tokens are short-lived + org-admin-scoped, so the respawn needs an **org-admin token-mint credential** on the host (a GitHub App / PAT with `organization_self_hosted_runners: write`) exposed via a pluggable `RUNNER_TOKEN_CMD` — an operator setup, NOT a `*.pem` the low-priv user otherwise holds.

**Spike simplification (optional):** for the time-boxed A/B a **non-ephemeral** runner (register once, persistent) avoids the token-mint dependency and is sufficient to prove the number; ephemeral + respawn is the production posture. `EPHEMERAL=true|false` is parameterized.

**Token-mint credential exposure — permanent posture only (#91 review NOTE 2).** Because `RUNNER_TOKEN_CMD` is supplied via an `EnvironmentFile`, it lands in the `macf-runner` service environment and is readable by a `macf-runner` RCE through its own `/proc/self/environ`. So the org `self_hosted_runners:write` minter is reachable by the very process we sandbox. Mitigations (the **spike avoids this entirely** by running non-ephemeral, `EPHEMERAL=false`, with no token-mint cred on the host): (a) scope that PAT/App to **exactly** `organization_self_hosted_runners: write` and nothing else — worst case is registering rogue runners, not org access; (b) `/etc/macf-github-runner.env` must be `root:root 0600` — `phase_register` asserts owner+mode before enabling the unit and `die`s otherwise.

## Sequencing

`scaffold (#91, merged)` → [caller pinned `@v1.3.5` + `MACF_ROUTING_RUNS_ON` flipped + no-SSH direct-helper inject landed + fork-toggles off + reg token + runner-group scoped] → `register + start` (run-as `macf-runner` from the start) → **A/B measurement** (science owns) → **permanent** (ephemeral + respawn + token-mint). Run-as is `macf-runner` throughout (no spike-as-`ubuntu` step), so there is no "harden later" — the bound holds from minute one.

## Alternatives considered

- **GitHub-hosted runner + faster Tailscale** — can't remove the connect + the load-bearing `sleep 10`; the ~46% is structural to off-VM.
- **Spike-as-`ubuntu` (original)** — rejected on the security analysis above; the run-as user doesn't affect the latency number.
- **Non-org (repo-scoped) runner** — would need per-repo registration; org-scoped + group-scoping gets the same containment with one registration.
