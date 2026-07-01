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

1. **Origin-routing (the primary control — SHIPPED in macf-actions #60, code-agent owns).**
   A `pick-runner` job picks the runner by trigger trust, and every downstream job does
   `runs-on: ${{ fromJSON(needs.pick-runner.outputs.labels) }}`. The pick logic (bash,
   `set -f` so `[bot]` logins don't glob):
   ```bash
   # self-host ONLY for a trusted actor on a NON-fork event
   if [ "$IS_FORK" != "true" ] && [ -n "$TRUSTED_ACTORS" ]; then
     for a in ${TRUSTED_ACTORS//,/ }; do [ "$a" = "$ACTOR" ] && labels='["self-hosted","macf-vm"]'; done
   fi   # else: ubuntu-latest (fail-safe)
   ```
   **`MACF_TRUSTED_ACTORS` is plain logins, comma/space/newline-separated — NOT a JSON
   array** (e.g. `groundnuty macf-code-agent[bot] … macf-release-agent[bot]`). A JSON-array
   value silently fails to match (splits into bracket/quote tokens) → everything routes
   github-hosted + the self-hosted runner sits idle. Trusted actors (operator + agents +
   the **release agent**) → self-hosted; everyone else → github-hosted. `github.actor` /
   `head.repo.fork` are **GitHub-set, not spoofable**, and for a `pull_request` the **base**
   repo's workflow runs — a fork can't rewrite the routing. Fail-safe: unset/empty var →
   ubuntu-latest. Scanners still see `self-hosted` in the YAML but can't reach it.

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
macf-runner ALL=(ubuntu) NOPASSWD: /usr/local/bin/macf-tmux-send.sh
```

**The helper lives at a ROOT-owned path — NOT in the runner's home** (science's #145
review): a sudoers rule that runs a script *as ubuntu* is only safe if `macf-runner`
cannot **modify** that script, and **directory-write beats file-ownership** — if the
helper sat in `/opt/macf-runner` (which `macf-runner` owns), the runner could `unlink`
it and drop its own, then `sudo -u ubuntu <helper>` runs attacker code as ubuntu =
full escalation. So the helper is `/usr/local/bin/macf-tmux-send.sh` (`root:root 0755`),
and `setup-macf-runner-user.sh` **asserts** (Pattern B, fail-loud) that the helper +
every parent dir is non-writable by `macf-runner` *before* installing the sudoers rule;
`verify-runner.sh` re-checks it so drift is caught at health-check.

Explicitly **NOT** granted: a login shell as ubuntu, docker group, the App key dir,
`~/.kube`, other agents' `/proc`. So a compromised job can drive an agent (send it a
prompt) but — with the helper tamper-proof — cannot read the VM's secrets directly.
(Driving an agent is itself a capability — hence layers 1–2 keep untrusted triggers off
the runner entirely; this grant is the floor for what a *trusted* routing job needs.)

---

## Setup sequence (operator + devops)

**Order matters — do NOT land the origin-routing `runs-on` before a runner exists**
(trusted-actor jobs would hang forever waiting for an absent runner).

1. **Operator — set the trusted-actors allowlist** (repo variable, per repo). Plain logins,
   space-separated (macf-actions #60's shape — NOT a JSON array):
   ```bash
   gh variable set MACF_TRUSTED_ACTORS --repo groundnuty/<repo> \
     --body 'groundnuty macf-code-agent[bot] macf-science-agent[bot] macf-devops-agent[bot] macf-auditor-agent[bot] macf-release-agent[bot]'
   ```
   (Or copy from the fleet's `var_source` with `copy-vars.sh` once one repo has it — one source of truth.)
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

## Operational interface (`runner/Makefile`) — single source, generated targets

`runners.yaml` is the single source. The Makefile **generates** a target per entry via
`$(foreach)+$(eval)` — nothing hardcoded, so adding a runner is **one YAML line**:

- **`make runner-<name>`** — reconcile ONE runner: **verify → (if unhealthy) prompt to copy-vars +
  install + register → verify again** (idempotent, self-proving). Generated from the YAML.
- **`make fleet-<name>`** — reconcile every runner in that fleet (depends on its `runner-*` targets).
- **`make verify-all`** — read-only health-check across the registry (no install prompts).
- **`make runners`** — document the registry; **`make copy-vars REPO=… FLEET=…`** — sync shared vars;
  **`make setup-user`** — the low-priv user (once per VM).

**Tab-completion, no custom script:** the generated targets land in the make **database**, so any
completion that reads it lists `make runner-<TAB>` / `fleet-<TAB>` — bash-completion's default, or
zsh with the one-liner `zstyle ':completion:*:make:*:targets' call-command true` (config, not a
script). Add a runner to the YAML → its target *and* its completion appear automatically.

**Var-drift killer:** each fleet has a `var_source` repo; `copy-vars.sh` copies `shared_vars`
(e.g. `MACF_TRUSTED_ACTORS`) from it to each runner-repo, and `--check` verifies every repo still
matches — so the actors allowlist is set ONCE, not per-repo. (Via devbox: `devbox run -- make -C runner <t>`.)

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

- `runners.yaml` — the single-source runner REGISTRY (fleets → runners; `var_source`, `shared_vars`).
- `Makefile` — generates `runner-<name>`/`fleet-<name>` from the YAML (+ `runners`/`verify-all`/`copy-vars`).
- `reconcile-runner.sh` — the per-runner reconcile (verify → prompt-install → verify); behind `runner-<name>`.
- `copy-vars.sh` — copy/`--check` a fleet's shared vars from its `var_source` (the var-drift killer).
- `verify-runner.sh` — the Pattern-A health check (per repo).
- `setup-macf-runner-user.sh` — create the low-priv user + the narrow send-helper sudoers rule.
- `install-runner.sh` — download the pinned `actions/runner`, `config.sh` repo-scoped.
- `run-ephemeral-loop.sh` — re-register + run-one-job loop (the ephemeral respawn).
- `macf-runner@.service` — systemd template unit (one instance per repo).

## Refs

devops-toolkit#90 · macf-actions#47 (T4 PR_TITLE hardening, landed) · the macf-actions
origin-routing issue (code-agent) · GitHub docs: "self-hosted runners with public repos."
