# Observability bundle setup — operator runbook

One-time setup steps to wire `.github/workflows/observability-snapshot.yml` end-to-end. Once these land, every closed issue/PR in `groundnuty/macf-devops-toolkit` (and any sister repo with the workflow installed) gets an observability bundle commented on its thread + the JSON snapshot pushed to the archive repo.

For design rationale, see `design/DR-002-observability-artifact-bundles.md`.

## Architecture (1-line)

GitHub Actions on issue/PR close → join Tailscale → SSH to the cluster VM → run `hack/observability-snapshot.sh` → scp bundle back → push to archive repo → post comment on the issue.

## Prerequisites

- Tailscale account with admin access to the `groundnuty` tailnet (or whichever tailnet the cluster VM lives on).
- Admin on the `groundnuty` GitHub org (to set org-level secrets + create repos).
- SSH access to the VM running the cluster (`100.124.163.105` / hostname `orzech-dev-agents`).

## Step 1 — Tailscale OAuth client

The GH-hosted Actions runner joins the tailnet via `tailscale/github-action@v2`. That action authenticates using a Tailscale OAuth client with `auth_keys` scope and a tag policy.

1. **Create the OAuth client.** In Tailscale admin: Settings → OAuth clients → New client.
   - Description: `macf observability snapshot runner`
   - Scopes: `auth_keys` (write)
   - Tags allowed: `tag:gha-runner`
   - Save the client ID + secret (only shown once).

2. **Update the tailnet's ACL** to recognize the `tag:gha-runner` tag, if not already present. In the tailnet ACL JSON (Tailscale admin → Access controls), add to the `tagOwners` map:
   ```json
   "tag:gha-runner": ["autogroup:admin"]
   ```
   And ensure `tag:gha-runner` can SSH to the cluster VM. If the VM is tagged `tag:cluster` or similar:
   ```json
   "ssh": [
     {
       "action": "accept",
       "src": ["tag:gha-runner"],
       "dst": ["tag:cluster"],
       "users": ["ubuntu"]
     }
   ]
   ```

3. **Store the OAuth credentials as ORG-LEVEL GitHub Actions secrets** (so all sister repos inherit them):
   - `groundnuty` → Settings → Secrets and variables → Actions → New organization secret
   - `TAILSCALE_OAUTH_CLIENT_ID` = the client ID
   - `TAILSCALE_OAUTH_SECRET` = the client secret
   - Repository access: select the macf repos that will install the workflow (start with `macf-devops-toolkit` only).

## Step 2 — SSH key for VM access

The runner SSHes from inside the tailnet to the VM, runs the snapshot script, scp's the bundle back. One keypair, used by the workflow on every run.

1. **Generate a keypair** (locally, NOT on the VM — the private half lives in GitHub secrets):
   ```bash
   ssh-keygen -t ed25519 -f /tmp/obs-runner-key -N "" -C "macf-obs-runner@gha"
   ```
   This produces `/tmp/obs-runner-key` (private) + `/tmp/obs-runner-key.pub` (public).

2. **Install the public key on the VM**, appending to `ubuntu`'s authorized_keys:
   ```bash
   ssh ubuntu@100.124.163.105 'cat >> ~/.ssh/authorized_keys' < /tmp/obs-runner-key.pub
   ```

3. **Test SSH-via-tailscale-from-laptop** (simulates what the runner will do, before wiring the workflow):
   ```bash
   ssh -i /tmp/obs-runner-key ubuntu@100.124.163.105 "hostname; echo ok"
   ```
   Expect: `orzech-dev-agents\nok`.

4. **Store the private half as a REPO-level secret** on `groundnuty/macf-devops-toolkit`:
   - Settings → Secrets and variables → Actions → New repository secret
   - `OBS_RUNNER_SSH_KEY` = full contents of `/tmp/obs-runner-key` (incl. `-----BEGIN OPENSSH PRIVATE KEY-----` ... lines)

5. **Store the VM's tailnet hostname as a REPO-level VARIABLE** (vars, not secret — hostnames aren't sensitive given OAuth-gated tailnet access):
   - Settings → Secrets and variables → Actions → Variables tab → New repository variable
   - `OBS_RUNNER_HOST` = `100.124.163.105` (or the tailnet name `orzech-dev-agents` — both work since `ssh-keyscan` resolves either)

6. **(Optional)** Once first-run validation passes, promote `OBS_RUNNER_SSH_KEY` + `OBS_RUNNER_HOST` to **org-level** so sister-repo PRs don't each need their own copies. Same VM serves all five macf repos.

7. **Cleanup**: delete `/tmp/obs-runner-key` + `/tmp/obs-runner-key.pub` from the laptop after Step 4 lands. The private half lives only in the GitHub secret + on the VM (in authorized_keys).

## Step 3 — Archive repo

The bundle JSON is committed to a separate, dedicated repo so it's git-tracked, citeable, and survives backend retention/reconfig.

1. **Create the repo.** `groundnuty/macf-observability-archive`.
   - **Visibility decision**: private for now. Can flip to public if/when paper-supplementary materials need it. The bundles contain conversation metadata + filter labels; if `OTEL_LOG_USER_PROMPTS=1` is on (per #32 stage 1+), they may also contain user prompt text — review before flipping public.
   - Initialize with a `README.md` describing the layout: `work/<owner>/<repo>/<N>/` for per-issue bundles; `runs/<scenario_run_id>/` for per-scenario bundles (when the harness post-finalizer wires it).

2. **Generate a deploy key** (NOT a personal SSH key; this is a per-repo write key that's revocable independently):
   ```bash
   ssh-keygen -t ed25519 -f /tmp/archive-deploy -N "" -C "macf-archive-deploy@gha"
   ```

3. **Install the public half on the archive repo**, with WRITE access:
   - `groundnuty/macf-observability-archive` → Settings → Deploy keys → Add deploy key
   - Title: `macf-obs-snapshot-workflow`
   - Key: contents of `/tmp/archive-deploy.pub`
   - **Check** "Allow write access"
   - Save.

4. **Store the private half as a REPO-level secret** on `groundnuty/macf-devops-toolkit` (sister-repo cycle: same private key works on each consumer repo, since the deploy key authorizes against the archive repo, not the consumer repo):
   - `ARCHIVE_DEPLOY_KEY` = contents of `/tmp/archive-deploy`

5. **Cleanup**: delete `/tmp/archive-deploy` + `/tmp/archive-deploy.pub` from laptop after Step 4.

## Step 4 — First-run validation

1. **Trigger the workflow** by closing a test issue in `groundnuty/macf-devops-toolkit`. (Safest test: file a deliberately-trivial issue, label it for a substrate agent, close it. The workflow fires on `closed` regardless of how the close happens.)

2. **Watch the workflow run**: GitHub → Actions → observability-snapshot. Each step's logs are inspectable.

3. **Common failure modes** at first-run:
   - **Tailscale step fails with auth error** → OAuth client ID/secret mismatch, or tag policy doesn't permit the runner. Re-check Step 1.
   - **SSH step fails with permission denied** → public key not on VM authorized_keys, or private key in secret has trailing newline issues (re-paste the file contents verbatim).
   - **Archive push fails with permission denied** → deploy key not added with write access, or wrong half stored in `ARCHIVE_DEPLOY_KEY` (private goes to secret, public to deploy keys).
   - **Snapshot script fails on the VM** → the VM-side script invocation is `cd ~/repos/groundnuty/macf-devops-toolkit/environments/macf && devbox run ...`; verify the operator's repo clone path matches.

4. **Verify success indicators**:
   - Workflow run all-green.
   - Comment posted on the closed test issue with summary table + Grafana drill-in URLs + archive link.
   - New commit on `groundnuty/macf-observability-archive/main` at path `work/groundnuty/macf-devops-toolkit/<N>/`.

## Step 5 — Sister-repo propagation

Once Step 4 succeeds, propagate the workflow to the other four macf repos:

| Repo | Workflow file path | Issue closer agents |
|---|---|---|
| `groundnuty/macf-devops-toolkit` | `.github/workflows/observability-snapshot.yml` | macf-devops-agent (this) |
| `groundnuty/macf-science-agent` | same | macf-science-agent |
| `groundnuty/macf-testbed` | same | macf-code-agent + testers |
| `groundnuty/macf` | same | macf-code-agent |
| `groundnuty/macf-actions` | same | macf-code-agent |

For each: file a sister PR with an identical workflow file (modulo the per-repo `OBS_RUNNER_HOST` repo var if it ever differs). Secrets:

- **Org-level (set once, all repos inherit)**: `TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_SECRET`, `OBS_RUNNER_SSH_KEY`, `ARCHIVE_DEPLOY_KEY`.
- **Per-repo var**: `OBS_RUNNER_HOST` if it differs (currently same VM for all → can also be org-level).
- **Per-repo var (optional)**: `GRAFANA_BASE` if Grafana ever exposes externally + sister-repo issue closers don't have port-forward access.

## Operational considerations

- **Bundle size**: 1–4 MB raw / 0.5–1.5 MB compressed per typical 900k-context session (see DR-002 §"Bundle size estimates"). 1000 bundles = ~1–2 GB on the archive repo. Comfortably under git/GitHub limits.
- **Secret rotation**: Tailscale OAuth + deploy keys + SSH keys all rotatable independently. To rotate, generate new pair, update GH secrets, install new public half, then revoke the old.
- **Sister-repo workflow drift**: when the workflow YAML changes (new step, fixed bug), all five sister copies need updating. A future improvement: move the workflow body into a reusable workflow at `groundnuty/macf-actions/.github/workflows/observability-snapshot.yml`, and each sister repo has only a thin caller (`uses: groundnuty/macf-actions/.github/workflows/observability-snapshot.yml@main`). Defer until at least three sister repos have the inline workflow + drift becomes painful.

## References

- `design/DR-002-observability-artifact-bundles.md` — design rationale, alternatives explored
- `.github/workflows/observability-snapshot.yml` — the workflow this runbook configures
- `environments/macf/hack/observability-snapshot.sh` — the script the workflow invokes
- `environments/macf/hack/archive-agent-sessions.sh` — sister script for the per-agent session JSONL archive (separate trigger path; same destination repo)
