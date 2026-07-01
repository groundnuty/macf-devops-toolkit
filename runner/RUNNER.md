# Self-hosted GitHub Actions runner — guardrailed setup (devops-toolkit#90)

Speeds up MACF routing by running the router **on the agents VM** — already on the
tailnet, so the ~46% of routing wall-clock currently spent on Tailscale connect +
`sleep 10` drops to ~0 (inject becomes a local `tmux send-keys`). Expected **~40s →
~6–9s** (~4–6×). Science owns the A/B measurement (#90).

> **STATUS: staged scaffolding — NOT yet live.** These scripts are reviewed but not
> executed; they are validated at registration time (they need `sudo` + a live
> registration token + are host-mutating). Nothing here registers a runner on its own.

---

## The security model — READ THIS FIRST

`groundnuty` is a **user account** (not an org), and 3 of the 4 router repos
(`macf`, `macf-actions`, `macf-devops-toolkit`) are **public**. A self-hosted runner
on a public repo is the config GitHub explicitly discourages: *any* fork PR can target
it and run code on the VM. Four layers contain that, in priority order:

1. **Origin-routing (the primary control — lives in macf-actions, code-agent owns).**
   The router job picks its runner by trigger trust:
   ```yaml
   runs-on: ${{ contains(fromJSON(vars.MACF_TRUSTED_ACTORS), github.actor)
                && fromJSON('["self-hosted","macf-vm"]') || 'ubuntu-latest' }}
   ```
   Trusted actors (operator + the agents + the **release agent**) → self-hosted;
   everyone else → github-hosted. `github.actor`/`head.repo.fork` are **GitHub-set,
   not spoofable**, and for a `pull_request` the **base** repo's workflow runs — a fork
   can't rewrite the routing. Outsider triggers go to github-hosted **by construction**.
   Scanners still see `self-hosted` in the YAML but can't reach it.

2. **This router never runs fork code.** No `pull_request_target`, no `run:` steps; it
   reads event metadata + delegates to the pinned macf-actions reusable workflow. The
   classic "fork's build runs on your runner" vector doesn't apply. (code-agent confirms
   the reusable workflow likewise never `checkout`s+runs untrusted PR code.)

3. **Low-priv `macf-runner` user — NEVER `ubuntu`.** So even a routing-logic bug that let
   an untrusted job through can't read the App `.pem`, `~/.kube`, or other agents'
   `/proc/*/environ`. Its *only* capability is invoking the tmux-send helper (below),
   via a **narrow sudoers rule** — not a shell as `ubuntu`.

4. **Ephemeral + egress-locked.** `--ephemeral` = the runner de-registers after one job
   (no cross-job state). Egress restricted to the agent host + Tempo.

**Residual (accepted by operator):** a trusted-actor allowlist typo or a mis-set repo
variable. Contained by layers 3–4 to "can send a routed tmux keystroke," not secret theft.

---

## The `macf-runner` capability boundary

The runner must inject routed prompts into the agents' tmux sessions — nothing more.
So `macf-runner` gets **exactly one** grant: a sudoers rule permitting it to run the
send helper **as the agent-owner user (`ubuntu`), for that helper only**:

```
# /etc/sudoers.d/macf-runner  (installed by setup-macf-runner-user.sh)
macf-runner ALL=(ubuntu) NOPASSWD: /opt/macf-runner/tmux-send-to-claude.sh
```

Explicitly **NOT** granted: a login shell as ubuntu, docker group, the App key dir,
`~/.kube`, other agents' `/proc`. So a compromised job can drive an agent (send it a
prompt) but cannot read the VM's secrets directly. (Driving an agent is itself a
capability — hence layers 1–2 keep untrusted triggers off the runner entirely; this
grant is the floor for what a *trusted* routing job legitimately needs.)

---

## Setup sequence (operator + devops)

**Order matters — do NOT land the origin-routing `runs-on` before a runner exists**
(trusted-actor jobs would hang forever waiting for an absent runner).

1. **Operator — set the trusted-actors allowlist** (repo variable, per repo):
   ```bash
   gh variable set MACF_TRUSTED_ACTORS --repo groundnuty/<repo> \
     --body '["groundnuty","macf-code-agent[bot]","macf-science-agent[bot]","macf-devops-agent[bot]","macf-auditor-agent[bot]","macf-release-agent[bot]"]'
   ```
2. **devops — create the low-priv user** (once per VM): `sudo ./setup-macf-runner-user.sh`
3. **Operator — mint a repo-scoped registration token** (short-lived ~1h; bot is 403):
   ```bash
   gh api -X POST /repos/groundnuty/<repo>/actions/runners/registration-token --jq .token
   ```
4. **devops — register + install the ephemeral runner** (as `macf-runner`):
   ```bash
   sudo -u macf-runner ./install-runner.sh --repo groundnuty/<repo> --token <TOKEN>
   sudo systemctl enable --now macf-runner@<repo-slug>
   ```
5. **Prove it in isolation** — a throwaway trusted-actor-triggered job lands on the
   runner (check the run log shows `self-hosted, macf-vm`). No routing depends on it yet.
6. **code-agent — land the origin-routing `runs-on`** in the macf-actions reusable
   workflow. NOW trusted routing flows to the runner; outsiders to github-hosted.
7. **science — run the A/B**, confirm the ~4–6×.

**Egress lock** (step 2/4, host firewall — operator applies, tune to your setup):
restrict `macf-runner`'s egress to the agent host (localhost tmux is local anyway) +
the Tempo endpoint; deny the rest so a compromised job can't exfiltrate.

---

## Multi-repo

The router runs in 4 repos; a repo-scoped runner serves ONE repo. One VM hosts all —
register one ephemeral runner per repo (`macf-runner@<repo-slug>` systemd instances).
Start with one repo for the spike; fan out after the A/B confirms the win.

## Operational interface (`runner/Makefile`) — the registry + the mechanism

Two layers, config-driven off `runners.yaml` (the documented registry) so adding a runner is
one entry — no per-repo target to hand-maintain (same anti-drift as the trusted-actors list):

- **`make runners`** — document the registry (fleets → runners → status).
- **`make verify-all`** / **`verify-fleet FLEET=macf`** — Pattern-A health-check across the registry /
  a fleet (asserts user + send-helper + sudoers + *configured-for-the-right-repo* + listener —
  not "setup exited 0"; `sudo` for the sudoers/`.runner` legs).
- **`make verify REPO=…`** / **`setup-user`** / **`install REPO=… TOKEN=…`** / **`up`** — the generic
  per-runner mechanism. Via devbox: `devbox run -- make -C runner <target>`.

## Two corrections (learned during the first live registration, 2026-07-01)

1. **Install the unit before enabling it** — `install-runner.sh` configures the runner but does
   NOT place the systemd unit. Before `systemctl enable`:
   `sudo cp macf-runner@.service /etc/systemd/system/ && sudo systemctl daemon-reload`.
2. **Ephemeral + unattended systemd needs a token-mint command** — an `--ephemeral` runner
   de-registers after one job, so the respawn must re-register with a *fresh* token each time;
   minting registration tokens needs `administration:write` (the **bot is 403** — only the operator
   mints). So for the **spike / A/B**, use a **non-ephemeral** runner (`install-runner.sh` *without*
   `--ephemeral` — register once, serves many jobs); the durable ephemeral+systemd form waits on
   an operator-provided token-mint helper. The **isolation proof** needs neither — just `make up`
   (`./run.sh`) → "Listening for Jobs".

## Files

- `runners.yaml` — the documented runner REGISTRY (fleets → runners); the Makefile aggregates it.
- `Makefile` — the operational interface (registry/aggregate + generic per-runner; above).
- `verify-runner.sh` — the Pattern-A health check (per repo).
- `setup-macf-runner-user.sh` — create the low-priv user + the narrow send-helper sudoers rule.
- `install-runner.sh` — download the pinned `actions/runner`, `config.sh` ephemeral + repo-scoped.
- `run-ephemeral-loop.sh` — re-register + run-one-job loop (the ephemeral respawn).
- `macf-runner@.service` — systemd template unit (one instance per repo).

## Refs

devops-toolkit#90 · macf-actions#47 (T4 PR_TITLE hardening, landed) · the macf-actions
origin-routing issue (code-agent) · GitHub docs: "self-hosted runners with public repos."
