# Self-hosted GitHub Actions runner — guardrailed setup (devops-toolkit#90)

Speeds up MACF routing by running the router **on the agents VM** — already on the
tailnet, so the ~46% of routing wall-clock currently spent on Tailscale connect +
`sleep 10` drops to ~0 (inject becomes a local `tmux send-keys`). Expected **~40s →
~6–9s** (~4–6×). Science owns the A/B measurement (#90).

> **STATUS (2026-07-01): the `macf-science-agent` runner is LIVE** — non-ephemeral `svc.sh`
> systemd service, listening + serving trusted routing (see `runners.yaml`). The other repos'
> runners remain staged. Standup requires `sudo` (host-mutating); `install-runner.sh` /
> `uninstall-runner.sh` now **auto-mint** the registration/remove token via the invoking
> operator's `gh` admin creds (falling back to a prompt only if that fails) — see "Setup
> sequence" and "Standing up a NON-EPHEMERAL runner" below.
>
> **UPDATE (multi-runner-per-host): runners now install onto `/mnt/volume1`, isolated per
> repo, sharing one action-archive-cache.** `groundnuty` is a user account (no org runners),
> so a second repo's runner would collide with the first under the old single fixed-path
> model (`/opt/macf-runner`, also on the near-full root disk). See "Multi-runner-per-host
> layout" below for the new `$MACF_RUNNER_BASE/<name>` scheme, and "Migrating the
> `macf-science-agent` runner" for moving the existing LIVE runner off `/opt/macf-runner`.

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

## Fork-PR-approval precheck (public repos)

Layer 1 above (origin-routing, macf-actions#59) is the intended **primary** control —
but it is **not landed yet**. Until it lands, the *only* thing standing between an
untrusted fork PR and code execution on this VM is GitHub's own native "require
approval for outside collaborators" fork-PR setting on the repo. `install-runner.sh`
now asserts that setting is in its strictest state **before** it does any
download/register/token-mint work, so an unsafe public repo aborts up front instead
of quietly registering a runner that origin-routing hasn't caught up to yet.

- **What it checks:** on a repo whose visibility is `public` (or whose visibility
  couldn't be determined — treated as public, conservatively), the runner
  `/repos/{owner}/{repo}/actions/permissions/fork-pr-contributor-approval` policy
  must be `all_external_contributors` — the setting that gates *every* outside fork
  PR behind a maintainer's manual "Approve and run" click before any workflow
  executes. The two weaker settings (`first_time_contributors`,
  `first_time_contributors_new_to_github`) both let a once-merged / once-approved
  contributor trigger unapproved runs afterwards — not safe for a public repo with a
  self-hosted runner attached, and the precheck FATALs (exit 2) on either of them,
  on an empty/unreadable policy, or on any endpoint failure. It never silently
  proceeds on "couldn't confirm the policy."
- **Needs OPERATOR creds, not the bot's.** Visibility (`.visibility`) is readable
  with the bot's own token (`metadata:read`). The approval-policy endpoint needs
  admin / `repo` scope — the bot App is **always 403** here (same shape as
  `install-runner.sh`'s own token auto-mint being 403 on `administration:write`), so
  the check runs `gh` as the invoking operator (`sudo -u "$SUDO_USER" -- gh`,
  mirroring `mint_token()`'s pattern) rather than as root/macf-runner.
- **A repo confirmed `private` or `internal` skips the check entirely** — there's no
  anonymous fork surface for the setting to matter on.
- **Override:** `MACF_RUNNER_SKIP_FORK_APPROVAL_CHECK=1` skips the whole check with a
  loud one-line warning (sister to the repo's other `MACF_SKIP_*`-family escape
  hatches). Legitimate uses: macf-actions#59 (origin-routing) has landed and is now
  the real gate, or a deliberate, documented operator call. This precheck is
  **belt-and-suspenders once #59 lands** — it doesn't go away, since origin-routing
  and fork-PR-approval are independent controls (a routing-logic bug shouldn't also
  require a GitHub-setting misconfiguration to become exploitable).
- **Implementation:** `runner/fork-pr-approval-check.sh` — sourced by
  `install-runner.sh`. The decision table (SKIP/PASS/FATAL given a visibility +
  policy pair) is factored into a pure `_fork_approval_decide()` function so it's
  unit-testable without calling `gh` — see `runner/test-fork-approval.sh`.

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
3. **devops — register + install the runner** (as `macf-runner`). The REGISTRATION token is
   **auto-minted** via the invoking operator's `gh` admin creds — no manual pre-mint step
   needed (the bot is always 403 on `administration:write`, so it can't self-mint):
   ```bash
   sudo ./install-runner.sh --repo groundnuty/<repo>
   sudo systemctl enable --now macf-runner@<repo-slug>
   ```
   Falls back to an interactive prompt only if auto-mint fails (e.g. your own `gh auth` also
   lacks repo-admin); pass `--token <TOKEN>` to skip both with a token minted yourself:
   ```bash
   gh api -X POST /repos/groundnuty/<repo>/actions/runners/registration-token --jq .token
   ```
4. **Prove it in isolation** — a throwaway trusted-actor-triggered job lands on the
   runner (check the run log shows `self-hosted, macf-vm`). No routing depends on it yet.
5. **code-agent — land the origin-routing `runs-on`** in the macf-actions reusable
   workflow. NOW trusted routing flows to the runner; outsiders to github-hosted.
6. **science — run the A/B**, confirm the ~4–6×.

**Egress lock** (step 2/3, host firewall — operator applies, tune to your setup):
restrict `macf-runner`'s egress to the agent host (localhost tmux is local anyway) +
the Tempo endpoint; deny the rest so a compromised job can't exfiltrate.

---

## Multi-repo

The router runs in 4 repos; a repo-scoped runner serves ONE repo (`groundnuty` is a user
account — no org-scoped runners). One VM hosts all of them, one **non-ephemeral `svc.sh`
systemd service per repo**, each isolated under its own dir on `/mnt/volume1` — see
"Multi-runner-per-host layout" below for the directory scheme. Service names don't
collide either: `svc.sh` derives `actions.runner.<owner>-<repo>.<name>.service` from the
registered repo, so `verify-runner.sh` / `uninstall-runner.sh` / `install-runner.sh` all
target the SPECIFIC service for their `--repo`, not just "whichever service comes first."
Start with one repo for the spike (done: `macf-science-agent`); fan out via
`make runner-<name>` once the A/B confirms the win.

## Multi-runner-per-host layout (`/mnt/volume1`)

**Heavy/growing storage goes on the big volume, not the (84%-full) root disk** — same
rule as the observability cluster's `/mnt/volume1` convention. Each runner installs
ISOLATED under its own name:

```
/mnt/volume1/macf-runners/
├── macf-science-agent/
│   └── actions-runner/        # this runner's config.sh registration + _work + _diag
├── macf-devops-toolkit/
│   └── actions-runner/        # a second repo's runner — no path collision
└── action-archive-cache/      # SHARED — Lever B; router actions are identical across
                                # repos, so one cache serves every runner (devops#150)
```

- **`MACF_RUNNER_BASE`** (default `/mnt/volume1/macf-runners`) — the base dir; override to
  relocate the whole fleet. `reconcile-runner.sh` computes `$MACF_RUNNER_BASE/<name>` from
  the `runners.yaml` `name` field and exports `MACF_RUNNER_HOME` / `MACF_RUNNER_DIR` /
  `MACF_ACTION_ARCHIVE_CACHE` / `MACF_RUNNER_DIAG` before calling install/uninstall/verify —
  the single point where the per-runner path formula lives. The Makefile's `uninstall-<name>`
  target calls `uninstall-runner.sh` DIRECTLY (bypassing reconcile, since uninstall doesn't
  need the verify/install dance), so it threads the same formula independently — the one
  unavoidable duplication, called out in the Makefile's `MACF_RUNNER_BASE` comment.
- **ISOLATED per runner:** the `actions-runner` install dir (registration, `_work`, `_diag`,
  the per-runner `.env`).
- **SHARED across every runner:**
  - the `action-archive-cache` (Lever B) — one cache, `{cacheDir}/{owner}_{repo}/{sha}.tar.gz`
    keyed, so it's already namespaced per-repo internally; no reason to duplicate it per runner.
  - the low-priv **`macf-runner` OS user** — one system account runs every runner's listener
    process (each with its own `_work`, so no cross-repo bleed); set up ONCE per VM via
    `setup-macf-runner-user.sh` (unchanged — its `MACF_RUNNER_HOME` is the OS user's `$HOME`,
    a small metadata dir, NOT where the actions-runner installs land).
- **Threading through `sudo`:** `reconcile-runner.sh` exports the per-runner vars, then calls
  `sudo ./install-runner.sh` / `sudo ./uninstall-runner.sh` via **`sudo env VAR=val cmd`**, not
  `sudo -E` — `sudo` resets the environment by default (`env_reset`), and whether `-E` is
  honored depends on sudoers policy the operator's shell may not have. `env VAR=val` is an
  explicit assignment consumed by `env(1)` before it execs the child, so it works regardless
  of that policy.
- **Bare / manual invocation still works:** each script's own default (`MACF_RUNNER_HOME:-
  /opt/macf-runner`, etc.) is UNCHANGED — a direct `sudo ./install-runner.sh --repo ...` with
  no env overrides still installs to the old single-runner location. The multi-runner scheme
  is opt-in via `reconcile-runner.sh` / `make runner-<name>`, the primary interface.

### Migrating the `macf-science-agent` runner off `/opt/macf-runner`

The runner registered before this change is still on the OLD path. Move it onto the volume:

```bash
make reinstall-macf-science-agent   # uninstalls the /opt/macf-runner registration,
                                     # re-installs onto /mnt/volume1/macf-runners/macf-science-agent
sudo rm -rf /opt/macf-runner        # reclaim the root-disk space once verify-runner.sh is green
```

The shared action-archive-cache starts **fresh** on the volume (the old `/opt/macf-runner/
action-archive-cache` isn't migrated — it's a pure optimization, not state). It re-seeds
after the first routed job, or immediately via `./seed-action-cache.sh` if the migrated
runner already has a Worker log (a `make reinstall-<name>` warm-reinstall does, since
`install-runner.sh` seeds immediately when one exists — see "Lever B" below).

## Operational interface (`runner/Makefile`) — single source, generated targets

`runners.yaml` is the single source. The Makefile **generates** a target per entry via
`$(foreach)+$(eval)` — nothing hardcoded, so adding a runner is **one YAML line**:

- **`make runner-<name>`** — reconcile ONE runner: **verify → (if unhealthy) prompt to copy-vars +
  install + register → verify again** (idempotent, self-proving). Generated from the YAML.
- **`make fleet-<name>`** — reconcile every runner in that fleet (depends on its `runner-*` targets).
- **`make verify-all`** — read-only health-check across the registry (no install prompts).
- **`make runners`** — document the registry; **`make copy-vars REPO=… FLEET=…`** — sync shared vars;
  **`make setup-user`** — the low-priv user (once per VM).

### Self-contained devbox — yq/jq/gh + working tab-completion (no more silent-empty targets)

The Makefile's `runner-<name>` / `uninstall-<name>` / `reinstall-<name>` / `fleet-<name>`
targets are **generated at parse time** from `runners.yaml` via `$(shell yq ... | jq ...)`
— a make *variable*, not a static rule. Two consequences that used to bite:

1. **Without yq/jq on PATH, generation silently returns nothing** — `make <generated-target>`
   used to fail with a bare `No rule to make target`, no hint why. `runner/Makefile` now
   asserts the precondition right after the `YQ`/`JQ` definitions and fails LOUD instead
   (`$(error) yq (mikefarah v4) not found on PATH -- ...`) — same for `jq`.
2. **The generic "read the make database" completion trick doesn't work for these targets**
   (bash-completion's default, or zsh's `zstyle ':completion:*:make:*:targets' call-command
   true`) — because a `$(shell)`-computed variable isn't a static rule in the database for
   either mechanism to introspect. With nothing to offer, both fall back to **filename**
   completion — `make uninstall-<TAB>` used to offer `uninstall-runner.sh`, not
   `uninstall-macf-science-agent`.

Fix — `runner/devbox.json` (packages: `yq-go`, `jq`, `gh`, matching `environments/macf`'s pin
style) plus two completion scripts that derive candidates the SAME way the Makefile does
(`yq -o=json runners.yaml | jq -r '...'`), bound directly to `make` so filename completion
never runs for it:

```
cd runner && devbox shell     # yq/jq/gh on PATH; completion loaded automatically
make reinstall-<TAB>          # → reinstall-macf-science-agent  (not a .sh filename)
make uninstall-<TAB>          # → uninstall-macf-science-agent
make fleet-<TAB>               # → fleet-macf
```

- **`make-completion.zsh`** / **`make-completion.bash`** — both derive: the Makefile's own
  self-documenting `target:  ## comment` targets (`help`, `runners`, `verify-all`,
  `setup-user`, `copy-vars`) PLUS the generated `runner-*`/`uninstall-*`/`reinstall-*` (per
  runner) and `fleet-*` (per fleet) names from `runners.yaml`. Resilient: if yq/jq or
  `runners.yaml` are unavailable, completion just offers the static targets (never errors,
  never falls back to filenames).
- **`devbox.json`**'s `shell.init_hook` sources whichever of the two matches the running
  shell (`$ZSH_VERSION`/`$BASH_VERSION`) and prints a one-line ready hint. Scoped to the
  `runner/` devbox shell only — nothing is installed into your global zsh/bash config.
- **One-off (no interactive shell) from the repo root:**
  `devbox run --config runner -- make <target>` — devbox resolves `runner/devbox.json`
  without a `cd`, and `make` runs with yq/jq/gh already on PATH (no completion in this
  non-interactive form, obviously — that's an interactive-shell feature).
- Add a runner to the YAML → its target *and* its completion appear automatically, same as
  before — only the completion *mechanism* changed, not the single-source-of-truth model.

**Var-drift killer:** each fleet has a `var_source` repo; `copy-vars.sh` copies `shared_vars`
(e.g. `MACF_TRUSTED_ACTORS`) from it to each runner-repo, and `--check` verifies every repo still
matches — so the actors allowlist is set ONCE, not per-repo.

## Standing up a NON-EPHEMERAL runner (the A/B path — verified 2026-07-01)

The proven live-standup sequence for a persistent runner (macf-science-agent was stood up this
way), shown here as the raw `config.sh` recipe — useful for troubleshooting or when bypassing
the wrapper scripts. **Prefer the wrapper scripts when possible**: `install-runner.sh` and
`uninstall-runner.sh` now **auto-mint** both token types via the invoking operator's `gh` admin
creds (bot is 403 on `administration:write`, so it can't self-mint), so a normal
`sudo ./uninstall-runner.sh --repo ... && sudo ./install-runner.sh --repo ...` no longer needs a
manual `gh api` mint step at all. The steps below remain useful for driving `config.sh` directly.

```bash
cd /mnt/volume1/macf-runners/<name>/actions-runner   # per-runner dir; see "Multi-runner-per-host layout"
sudo ./svc.sh stop; sudo ./svc.sh uninstall     # if a prior service exists
unset GH_TOKEN                                   # mint as the OPERATOR, not the bot (bot=403)
# REMOVE the old registration first — `config.sh --replace` is INSUFFICIENT ("Cannot configure
# … already configured; run './config.sh remove' first"). Remove needs a REMOVE-token (distinct
# from the registration-token endpoint):
RM=$(gh api -X POST /repos/<owner>/<repo>/actions/runners/remove-token --jq .token)
sudo -u macf-runner ./config.sh remove --token "$RM"
# RE-REGISTER non-ephemeral: OMIT --ephemeral (→ .runner `ephemeral:null` = non-ephemeral,
# survives jobs). Fresh registration-token:
REG=$(gh api -X POST /repos/<owner>/<repo>/actions/runners/registration-token --jq .token)
sudo -u macf-runner ./config.sh --url https://github.com/<owner>/<repo> \
  --token "$REG" --name macf-vm-<agent> --labels self-hosted,macf-vm --unattended
grep -o '"ephemeral":[a-z]*' .runner             # GATE: must be null/false BEFORE starting
sudo ./svc.sh install macf-runner && sudo ./svc.sh start && sudo ./svc.sh status
```

Gotchas that bit us: (1) `--replace` doesn't reconfigure an existing runner → **remove-then-readd**;
(2) the token must be minted with `GH_TOKEN` **unset** (else it runs as the bot → 403 → empty token
→ `config.sh --token ""` fails silently, leaving the old config); (3) verify `.runner` `ephemeral`
is null/false **before** `svc.sh start` — an ephemeral runner under a persistent service de-registers
after one job then flaps. **FOLLOW-UP:** teach `install-runner.sh` a `--non-ephemeral` flag + a
remove-then-readd path so this isn't a manual dance (filed).

**Egress-lock is still pending** for this runner (RUNNER.md's host-firewall step) — acceptable while
it's private-repo + trusted-actor-only, but apply before broadening.

## Auto-restart oversight — REQUIRED (GitHub's svc.sh omits it)

**GitHub's `svc.sh`-generated systemd unit has NO `Restart=` directive.** It's `enabled` (restarts
on VM *reboot*) but NOT supervised against *crashes* — a transient failure (network blip, broker
`SocketException`, OOM) kills the runner **permanently** while the VM stays up, with no restore.
Observed 2026-07-01: a Tailscale/network blip during the fleet upgrade threw
`SocketException (125): Operation canceled` on the broker connection → the listener exited → systemd
left it dead (no oversight). This is the exact silent-death-no-restore gap the fleet cares about.

**Fix — systemd IS the runner's supervisor; configure its restart policy** (do NOT bolt a second
watchdog on top — a systemd *service* is systemd's to supervise). A repo-tracked drop-in
(`runner/systemd-restart-override.conf`) adds `Restart=always` + `RestartSec=5` +
`StartLimitIntervalSec=0`; drop-ins survive `svc.sh` regen:

```bash
# Filtered by the repo's slug (owner-repo) — with multiple runners on one host, an
# unfiltered `head -1` can grab a SIBLING runner's service. install-runner.sh /
# uninstall-runner.sh / verify-runner.sh all do this filtering internally already;
# this raw form is for manual troubleshooting only.
SVC=$(systemctl list-units --type=service --all | grep -oE 'actions\.runner\.<owner>-<repo>\.[^ ]+\.service' | head -1)
sudo mkdir -p "/etc/systemd/system/${SVC}.d"
sudo cp runner/systemd-restart-override.conf "/etc/systemd/system/${SVC}.d/restart.conf"
sudo systemctl daemon-reload && sudo systemctl restart "$SVC"
systemctl show "$SVC" -p Restart --value    # → always
```

`verify-runner.sh` now ASSERTS `Restart=always` (Pattern A — a runner missing the oversight FAILs
the health-check). Every runner standup should install this drop-in. FOLLOW-UP: `install-runner.sh`
should install it automatically so it's not a manual post-step.

## Lever B — action-archive-cache (the ~2s/job optimization)

The runner deletes `_work/_actions` and **re-fetches every `uses:` action from codeload on every
job** (by design — `ActionManager.cs`). GitHub's native archive-cache (runner v2.311+) turns that
network fetch into a local `File.Copy` of a SHA-keyed tarball. Measured win: **~2s/job (~50% of
the action-fetch phase)**.

`install-runner.sh` **bakes Lever B in** — no manual post-step:

- creates the cache dir (`/mnt/volume1/macf-runners/action-archive-cache` under the
  multi-runner scheme — **SHARED across every runner** on the host, threaded via
  `reconcile-runner.sh`'s `MACF_ACTION_ARCHIVE_CACHE` export; bare/manual invocation
  defaults to `/opt/macf-runner/action-archive-cache`, override either way with
  `MACF_ACTION_ARCHIVE_CACHE`) and arms the runner's `.env` with
  `ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE=<dir>` **before** `svc.sh start` (the listener must inherit
  the env at start). Idempotent — a re-run won't duplicate the `.env` line.
- **seeds immediately** when the runner already has a Worker log (warm / reinstall). A brand-new
  runner has no log yet (chicken-and-egg), so its cache **seeds after the first routing job**: run
  `./seed-action-cache.sh` once a job has run (install prints this note; a `make seed-<name>`
  wrapper can be added to `runner/Makefile` later).

Key properties:

- **Survives uninstall/reinstall** — the cache lives OUTSIDE `$RUNNER_DIR` (each runner's
  `actions-runner` subdir), so re-registering a runner keeps the warm cache. Under the
  multi-runner scheme this ALSO means uninstalling/reinstalling one runner never touches
  the shared cache other runners are reading from.
- **`seed-action-cache.sh` is drift-proof + fail-safe** — it derives the exact
  `{owner}/{repo}/{sha}` set from the runner's OWN latest Worker log (no hardcoded SHAs to rot when
  a tag moves); a SHA-keyed miss (a moving `@vN` tag) just falls back to codeload — never breaks a
  job, only forgoes the speedup until re-seeded.
- **A seed failure is non-fatal** — Lever B is a pure optimization; install WARNs and the runner
  still serves jobs (paying the full codeload fetch).

`verify-runner.sh` asserts Lever B: **PASS** = `.env` armed + ≥1 cached tarball; **WARN** = armed
but unseeded (fresh, pre-first-job); **FAIL** = not armed.

## Two corrections (learned during the first live registration, 2026-07-01)

1. **Install the unit before enabling it** — `install-runner.sh` configures the runner but does
   NOT place the systemd unit. Before `systemctl enable`:
   `sudo cp macf-runner@.service /etc/systemd/system/ && sudo systemctl daemon-reload`.
2. **Ephemeral + unattended systemd needs a token-mint command** — an `--ephemeral` runner
   de-registers after one job, so the respawn must re-register with a *fresh* token each time;
   minting registration tokens needs `administration:write` (the **bot is 403**). `install-runner.sh`
   now **auto-mints** for the *interactive, operator-present* call (via `$SUDO_USER`'s `gh` creds
   under `sudo`) — but that doesn't help an *unattended* systemd-triggered respawn with no
   operator in the loop, which still has no token source. So for the **spike / A/B**, use a
   **non-ephemeral** runner (`install-runner.sh` *without* `--ephemeral` — register once, serves
   many jobs, mint happens once at standup time); the durable ephemeral+systemd form still waits on
   a separate unattended token-mint helper. The **isolation proof** needs neither — just `make up`
   (`./run.sh`) → "Listening for Jobs".

## Files

- `runners.yaml` — the single-source runner REGISTRY (fleets → runners; `var_source`, `shared_vars`).
  Also documents the multi-runner-per-host `/mnt/volume1/macf-runners/<name>` layout (top-of-file note).
- `Makefile` — generates `runner-<name>`/`fleet-<name>`/`uninstall-<name>`/`reinstall-<name>` from the
  YAML (+ `runners`/`verify-all`/`copy-vars`); fails loud via `$(error)` if yq/jq aren't on PATH instead
  of silently generating zero targets. `MACF_RUNNER_BASE` (default `/mnt/volume1/macf-runners`) is the
  per-runner base dir, threaded into `uninstall-<name>` directly (see "Multi-runner-per-host layout").
- `devbox.json` — self-contained devbox for this directory (`yq-go`, `jq`, `gh`); `shell.init_hook`
  loads the matching tab-completion script + prints a ready hint. `cd runner && devbox shell`.
- `make-completion.zsh` / `make-completion.bash` — bind `make` completion to the target names
  generated from `runners.yaml` (+ the Makefile's own documented targets); no filename fallback.
- `reconcile-runner.sh` — the per-runner reconcile (verify → prompt-install → verify); behind `runner-<name>`.
- `copy-vars.sh` — copy/`--check` a fleet's shared vars from its `var_source` (the var-drift killer).
- `verify-runner.sh` — the Pattern-A health check (per repo).
- `setup-macf-runner-user.sh` — create the low-priv user + the narrow send-helper sudoers rule.
- `fork-pr-approval-check.sh` — the fork-PR-approval-precheck library (see "Fork-PR-approval
  precheck (public repos)" above); sourced by `install-runner.sh`. Its decision table
  (`_fork_approval_decide`) is a pure function, kept separate from the `gh`-calling wrapper
  (`check_fork_pr_approval`) specifically so it's unit-testable.
- `install-runner.sh` — download the pinned `actions/runner`, `config.sh` repo-scoped (registration
  token **auto-minted** via the invoking operator's `gh` creds, prompt-fallback), install the
  non-ephemeral `svc.sh` service + `Restart=always` oversight, and arm Lever B (archive-cache).
  Runs the fork-PR-approval precheck FIRST, before any of that.
- `uninstall-runner.sh` — stop/remove the `svc.sh` service + drop-in, and de-register from GitHub
  (`config.sh remove`; remove-token **auto-minted** the same way, prompt-fallback, non-fatal WARN
  if neither is available — the rest of the teardown still proceeds).
- `seed-action-cache.sh` — drift-proof + fail-safe action-archive-cache seeder (Lever B).
- `run-ephemeral-loop.sh` — re-register + run-one-job loop (the ephemeral respawn).
- `macf-runner@.service` — systemd template unit (one instance per repo).
- `test-fork-approval.sh` — offline unit tests for `fork-pr-approval-check.sh`'s decision table
  (see "Fork-PR-approval precheck (public repos)" above).

## Refs

devops-toolkit#90 · macf-actions#47 (T4 PR_TITLE hardening, landed) · the macf-actions
origin-routing issue (code-agent) · GitHub docs: "self-hosted runners with public repos."
