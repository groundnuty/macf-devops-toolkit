# DR-005 — Stage-3 channel-routing infrastructure for the substrate (auditor canary-zero)

- **Status:** accepted (PR #106, science-approved 2026-06-25; amended for configurable registry mode)
- **Author:** macf-devops-agent
- **Date:** 2026-06-25
- **Implements:** `macf` DR-027 §Decision 6 (the devops infra expansion) for the `orzech-dev-agents` host
- **Consumes (canonical, do not restate — cite):** `macf` DR-002 (channel-per-agent), DR-004 (mTLS auth), DR-005 (agent registration / per-agent Variables), DR-006 (registry scope), DR-007 (port assignment), DR-022 (npx packaging), DR-025 (comms-ledger), DR-026 (the auditor)
- **Related:** `macf-devops-toolkit#105` (phase-0 task), `#90` (self-hosted runner — separate workstream), `macf#528`→`macf#529` (registry-scope errata; **#529 Profile mode is current**, supersedes #528's interim repo-scope)

> **Reference qualifier:** "DR-005" unqualified in *this file's own header line* is **devops-toolkit DR-005** (this doc). Every `macf`-canonical DR is prefixed `macf` (e.g. `macf` DR-007). The two repos keep independent DR series.

## Context

`macf` DR-027 (substrate Stage-2→Stage-3 migration) is **Accepted** (operator, 2026-06-25). Phase-0 is the **auditor canary-zero**: stand up the greenfield `macf-auditor-agent` on Stage-3 channels and build the per-agent channel infra it runs on, proving the layout at zero migration risk before science/code/devops migrate (phases 1–3). DR-027 §Decision 6 names the devops deliverable: "channel-server unit + CA/cert lifecycle + per-agent port map + org-secret/Variable layout." This DR is that expansion, **grounded in the actual channel-server implementation** (`@groundnuty/macf-channel-server`, `macf-core/src/config.ts`, the `agent-router.yml@v3.3.0` delivery job) rather than an assumed shape.

The grounding pass corrected one load-bearing assumption and refined the scope split; both are reflected below.

## The deployment model (corrected)

**The channel server is NOT a standalone daemon.** It is an **MCP stdio subprocess of Claude Code**, spawned by the `macf-agent` plugin's `mcpServers` entry (`npx -y @groundnuty/macf-channel-server@<pinned>`). `macf` DR-002 makes this a **constraint, not a choice**: an MCP stdio channel is 1:1 between one channel-server process and one Claude Code process — two Claude Code processes cannot share one server. Therefore:

- **There is no systemd unit for the channel server in isolation.** The supervision target is **`claude.sh`** (which launches Claude Code inside a tmux session `<PROJECT>@<AGENT>`); the channel server comes up as its MCP child, binds its HTTPS port, and **self-registers** in the registry. "Stand up agent X's channel" ≡ "launch X's `claude.sh`."
- **N agents = N Claude Code processes = N channel servers = N ports** (DR-002).

This corrects the word "unit" in DR-027 §6: any process supervision wraps `claude.sh`, not the server.

## Decision 1 — Supervision = `claude.sh`; optional systemd-wrap of `claude.sh`

The auditor (and each later substrate agent) runs via its `claude.sh` in a dedicated tmux session, per the canonical launch pattern (`coordination.md` §"One session per agent"):

```
tmux new-session -d -s "macf@auditor" "cd /home/ubuntu/repos/groundnuty/macf-auditor-agent && ./claude.sh"
```

`claude.sh` sources `.claude/.macf/env.*`, exports `MACF_HOST`/`MACF_ADVERTISE_HOST`/`MACF_PORT`, and `exec claude … --plugin-dir .macf/plugin`; the MCP child binds the port and self-registers. **Optional hardening (deferred, not phase-0):** a `systemd --user` unit that runs the tmux-detached `claude.sh` and restarts it on exit — wrapping `claude.sh`, never the server. Phase-0 uses the plain tmux launch; supervision hardening is a follow-up once the model is proven.

## Decision 2 — CA + certificate lifecycle (shared CA, single host)

Shared-CA **mutual TLS** per `macf` DR-004. One project CA; every peer trusts it; no per-cert distribution.

**Single-host shared-CA placement.** All co-tenant homes run as `ubuntu` on `orzech-dev-agents`, and the auditor's `env.certs` already points the CA at **`$HOME/.macf/certs/macf/ca-{cert,key}.pem`** (a `$HOME` path, shared across homes) while the leaf lives per-home at `$SCRIPT_DIR/.macf/certs/agent-{cert,key}.pem`. So the CA is minted **once** into `~/.macf/certs/macf/` and serves every co-tenant macf-project home.

| Cert | CN | Key | Validity | EKU | SAN | Location (mode) |
|---|---|---|---|---|---|---|
| Project CA | `macf-ca` | RSA-2048 / SHA-256 | 5 yr | — | — | `~/.macf/certs/macf/ca-cert.pem` + `ca-key.pem` (`0600`) |
| Agent leaf | `<agent-name>` | RSA-2048 / SHA-256 | 1 yr | serverAuth **+** clientAuth | **DNS:`orzech-dev-agents.tail491af.ts.net`** (+ default `IP:127.0.0.1,DNS:localhost`) | `<home>/.macf/certs/agent-{cert,key}.pem` (`0600`) |
| Routing client | `routing-action` | RSA-2048 / SHA-256 | 1 yr | clientAuth only | none (pure client) | GHA secrets `ROUTING_CLIENT_CERT/KEY` (base64 PEM) |

**CRITICAL — the FQDN must be a DNS SAN on every agent leaf.** The router connects to `https://<advertised-host>:<port>/notify` where the advertised host is the registry value; Node/curl verify the server hostname against the cert SAN. `buildPeerCert` classifies the agent's `advertise_host` via `hostToSan()` (IPv4-shape → IP SAN, else DNS SAN), so the leaf must be minted with **`--advertise-host orzech-dev-agents.tail491af.ts.net`** (confirmed via `tailscale status`: `DNSName orzech-dev-agents.tail491af.ts.net`, tailnet `100.124.163.105`). Omitting it → server-hostname-verification failure (curl error-60 class).

**Rotation (asymmetric, user-account reality per `macf#529`).** Leaf certs rotate **on the VM** under the long-lived CA — no GitHub touch (cheap; can be automated/tighter than DR-004 default). The routing **client** cert is a GHA secret: secrets stay **per-repo** (the Profile-mode registry trick is variables-only), so rotating it re-pushes to each caller repo (a 4-repo `for gh secret set` loop). The CA rotates only on compromise (5-yr validity; rotating it forces all leaves + the `MACF_CA_CERT` Variable to re-issue).

## Decision 3 — Per-agent port map (fixed band, collision-free with the CV co-tenants)

`macf` DR-007 defaults to **random** ports `8800 + randInt(1000)` → range **[8800, 9799]**, with the registry as source-of-truth. The **CV agents** (`project=academic-resume`: cv-architect, cv-project-archaeologist) are macf-init'd co-tenants already running on this host on **random** ports in that range.

For the macf-project substrate I propose **fixed** ports (set `MACF_PORT` per home) for operational legibility — `ss -tlnp | grep` identifies an agent deterministically, firewall/egress rules are stable, and debugging is reproducible. To **guarantee no collision** with the random-port CV agents, the substrate band sits **below the random floor**:

| Agent | `MACF_PORT` | Registry Variable (self-registered) |
|---|---|---|
| `macf-auditor-agent` (canary-zero) | **8700** | `MACF_AGENT_AUDITOR` |
| `macf-devops-agent` (phase 1) | 8701 | `MACF_AGENT_DEVOPS_AGENT` |
| `macf-code-agent` (phase 2) | 8702 | `MACF_AGENT_CODE_AGENT` |
| `macf-science-agent` (phase 3) | 8703 | `MACF_AGENT_SCIENCE_AGENT` |
| (reserved headroom) | 8704–8709 | — |

CV agents stay on random (different project; their own registry resolves them). Phase-0 only needs **8700** for the auditor. *(Alternative considered: keep the substrate on random per DR-007 — rejected for the static co-tenant host because a documented map is the DR-027 §6 deliverable and legibility outweighs the zero-config win when the roster is fixed and long-lived.)*

## Decision 4 — Registry + secret/Variable layout (Profile-scoped, per `macf#529`)

`groundnuty` is a **user account, not an org** (`/orgs/groundnuty` → 404). Canonical `macf` DR-006 already anticipates this: **Profile mode** uses the special `groundnuty/groundnuty` profile repo's variables as a **single user-level registry** — one registry for the whole fleet, restoring the consolidation that the interim repo-scope reading (`#528`) thought was lost. (`#529` supersedes `#528`; DR-006 needs no amendment — re-reading it was the fix.)

- **`registry-api-path = /repos/groundnuty/groundnuty`** for every caller (one shared registry). The auditor's `env.registry` moves from repo-mode to **profile-mode**: `MACF_REGISTRY_TYPE=profile`, `MACF_REGISTRY_USER=groundnuty` (per `macf-core/config.ts`).
- **Variables** (read by the router on `groundnuty/groundnuty`):
  - `MACF_CA_CERT` — the CA PEM (uploaded by `macf certs init`); the router writes it to disk to `--cacert` the mTLS call. *(A `MACF_CA_KEY_ENCRYPTED` Variable also exists from cert-init; not read by the router.)*
  - `MACF_AGENT_<NAME>` — **self-registered by each channel server on launch** (value = `{host,port,type,instance_id,started}` JSON). **Devops does not hand-set these.** All agents share the one profile registry, so the fleet's `host:port` entries live in one place.
- **Secrets stay per-repo** (the Profile-mode trick is variables-only; `#529`), on each caller repo:
  - `MACF_ROUTING_APP_ID` / `MACF_ROUTING_APP_KEY` — **set** by the operator 2026-06-25 (verified on `macf-devops-toolkit`).
  - `ROUTING_CLIENT_CERT` / `ROUTING_CLIENT_KEY` — **devops issues** (`macf certs issue-routing-client`) and the operator/we paste as base64 PEM.
  - `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET`, `AGENT_SSH_KEY` — existing (the Stage-2 fallback path; unchanged in phase-0).
- **Caller workflow:** `agent-router.yml` pinned **`@v3.3.0`** with `with: { project: macf, registry-api-path: /repos/groundnuty/groundnuty }`.

### Registry mode is a SELECTED config, not hard-coded — the org-flip path (operator's keep-both-paths-open requirement)

Profile is **today's selection**, not a baked-in assumption. The registry mode is a runtime config along two knobs that `macf` DR-006 already defines (`org` / `profile` / `repo`):

1. each agent's **`MACF_REGISTRY_TYPE`** (+ `MACF_REGISTRY_USER` / `MACF_REGISTRY_ORG`) in `env.registry`, read by the channel server when it self-registers;
2. each caller's **`registry-api-path`** input, read by the v3 router when it resolves the endpoint.

**Migrating to an org install later is a config flip, not a re-architecture.** If MACF is installed into a GitHub **org** (`groundnuty` becomes / is supplemented by an org), switch to org mode by:

- `env.registry` per agent: `MACF_REGISTRY_TYPE=org`, `MACF_REGISTRY_ORG=<org>` (was `profile`/`USER=groundnuty`);
- each caller's `registry-api-path`: `/orgs/<org>` (was `/repos/groundnuty/groundnuty`);
- re-home the registry data to the org scope: re-upload `MACF_<PROJ>_CA_CERT` (+ install the `MACF_ROUTING` App on the org with Variables:Read); agents re-self-register their `MACF_AGENT_<NAME>` on next launch.

Everything else is **registry-mode-agnostic and does not change**: the CA + agent leaf + routing-client certs, the channel-server, the mTLS machinery, the caller-workflow shape, and the per-repo secrets (`ROUTING_CLIENT_*`, `MACF_ROUTING_APP_*`, `TS_OAUTH_*` stay per-repo in every mode — the Profile/org distinction is variables-only). So the flip touches two env knobs + the registry data location, nothing structural. Nothing in this DR hard-codes Profile in a way a future org would have to be re-architected around.

## Decision 5 — Auditor canary-zero stand-up runbook (phase-0)

Ordered; steps 1–6 are scaffolding (no live route), step 7 needs the operator gate, step 8 is the co-verify.

1. **Mint the project CA** (if absent): `macf certs init` for project `macf` → writes `~/.macf/certs/macf/ca-{cert,key}.pem` (`0600`) and uploads the `MACF_CA_CERT` (+ `MACF_CA_KEY_ENCRYPTED`) Variable to the **profile registry `groundnuty/groundnuty`**. *(Confirmed gap: `~/.macf/certs/macf/` does not exist yet — init skipped leaf-gen because no CA was present.)*
2. **Mint the auditor leaf** with `--advertise-host orzech-dev-agents.tail491af.ts.net` → `<auditor-home>/.macf/certs/agent-{cert,key}.pem` (`0600`), CN=`auditor`, DNS-SAN = the FQDN, EKU server+client.
3. **Wire the F1 hook:** copy `macf/packages/macf/scripts/check-auditor-never-acts.sh` into the auditor home's `.claude/scripts/` and register it as a `PreToolUse` `Bash` hook in `.claude/settings.json`. *(Confirmed gap: absent — CLI 0.2.36 predates it. The hook is inert unless `MACF_AGENT_ROLE=auditor`, which the home already sets; it blocks `gh pr merge`/`issue close`/`pr close`, leaving propose+read verbs.)* Add `auditor.md` to `.macf/plugin/agents/` (or `macf update`). *(Confirmed gap: absent.)*
4. **Set per-agent env** in `.claude/.macf/`: `MACF_PORT=8700`, `MACF_ADVERTISE_HOST=orzech-dev-agents.tail491af.ts.net`, `MACF_HOST=0.0.0.0`; cert pointers already wired; **switch `env.registry` to profile-mode** (`MACF_REGISTRY_TYPE=profile`, `MACF_REGISTRY_USER=groundnuty` — currently repo-mode).
5. **Caller workflow + repo config:** `agent-router.yml@v3.3.0` on the auditor's caller with `project: macf`, `registry-api-path: /repos/groundnuty/groundnuty`; ensure the repo carries `MACF_ROUTING_APP_*` + `TS_OAUTH_*`.
6. **Issue + install `ROUTING_CLIENT_*`** as secrets on the caller repo(s).
7. **Launch** `claude.sh` (tmux `macf@auditor`) → the channel server binds `:8700` and self-registers `MACF_AGENT_AUDITOR` on `groundnuty/groundnuty`. **[OPERATOR GATE: the `MACF_ROUTING` App must exist + be installed on `groundnuty/groundnuty` (reads the profile registry) + my devops App must reach the relevant repos — see below.]**
8. **Acceptance / co-verify with science:** a test mention routes **over channels** (workflow → mTLS `POST /notify` → wake). The route-landed signal is the chain **`notify_received → mcp_pushed → tmux_wake_delivered`** in `<auditor-home>/.macf/logs/channel.log` (there is no log line literally named `turn_processed`; the `processed` receipt is the DR-025 comms-ledger field, backfilled by the reconciler), plus the OTel SERVER span **`macf.server.notify_received`** in Tempo. Confirm SSH+tmux (Stage-2) was *not* used.

## Decision 6 — Substrate hand-wire recipe (phases 1-3: devops → code → science)

Phase-0's auditor was greenfield + `macf init`'d, so its channel server came from the plugin (`claude --plugin-dir .macf/plugin`). The **load-bearing substrate agents are NOT `macf init` consumers** (DR-027 §3 + `macf#273`) — they are **hand-wired**. This is the canonical recipe, validated first on **canary-1 (devops)**; code (phase-2) + science (phase-3) copy it with their own name/port substituted.

**Deployment shape (minimal plugin via `--plugin-dir`).** The channel server is an MCP stdio child of Claude Code (DR-002). It is loaded **the same way CV + the auditor load theirs — `claude --plugin-dir`** — but pointed at a **minimal, channel-server-only plugin** (`.macf/plugin-cs/.claude-plugin/plugin.json`, `mcpServers`-only — no hooks/skills/agents, so it never doubles the substrate's hand-wired `settings.json` hooks). This is the **proven** mechanism (`macf#533`); the `.mcp.json` / `~/.claude.json` route was tried and **abandoned** (it did not load on relaunch). It self-registers on launch exactly as the auditor's does.

**Per-agent steps** (`<agent>` = the routing label, e.g. `devops-agent`):

1. **Minimal `.macf/macf-agent.json`** — cert-management marker only (`project`, `agent_name=<agent>`, `agent_role`, `agent_type:permanent`, `registry:{type:profile,user:groundnuty}`, `github_app`, `advertise_host`, `versions`). Does **NOT** make the home a `macf init` consumer — no plugin, no env-file regeneration; never run `macf init`/`macf update` here. Gitignored (`.macf/`).
2. **Leaf cert** — `macf certs rotate --dir <home>` (with `MACF_CA_CERT`/`MACF_CA_KEY` env → the shared CA `~/.macf/certs/macf/ca-{cert,key}.pem`) → `<home>/.macf/certs/agent-{cert,key}.pem`: `CN=<agent>`, **DNS-SAN = the FQDN** (required), EKU server+client.
3. **`MACF_CA_CERT` Variable on the CALLER repo** — the v3 router reads the CA from the caller repo's GHA `vars` context (`${{ vars.MACF_CA_CERT }}`), NOT the registry (phase-0 learning #2). Plain CA PEM as a repo Variable on each caller repo.
4. **Caller secrets** — `ROUTING_CLIENT_CERT/KEY` (base64 of the shared `routing-action` cert — identical for all callers), `MACF_ROUTING_APP_*`, `TS_OAUTH_*`.
5. **Minimal channel-server plugin** — `.macf/plugin-cs/.claude-plugin/plugin.json` (`mcpServers`-only) running `npx @groundnuty/macf-channel-server@<ver>`, loaded by `claude.sh`'s `--plugin-dir .macf/plugin-cs`. The channel server inherits the **process env** from `claude.sh` (that's how it gets the certs/registry/token); the plugin's `mcpServers.env` only needs the entries the claude→MCP-spawn boundary drops:
   - ⚠️ **`MACF_AGENT_NAME=<agent>` (routing label) — channel-server-scoped override**, set *inside* `mcpServers.env`. The substrate `claude.sh` sets `MACF_AGENT_NAME=<bot-name>` (e.g. `macf-devops-agent`) for the OTEL `gen_ai.agent.name`; the channel server needs the **routing label** for the registry key (`MACF_AGENT_DEVOPS_AGENT`) + cert CN. The auditor dodged this (name==label==`auditor`); code + science hit it. *(Framework follow-up: split into `MACF_AGENT_NAME` (OTEL) + `MACF_REGISTRY_NAME` (registry/CN); this override is the documented interim.)*
   - `OTEL_*` passthrough (`${VAR:-}`-expanded) — the only other entries the spawn boundary drops.
6. **Network identity — exported in `claude.sh`, NOT the plugin env (canary-1 learning, PR #111).** `claude.sh` must `export MACF_HOST=0.0.0.0`, `export MACF_ADVERTISE_HOST=<FQDN>`, `export MACF_PORT=<Decision-3 map>` (after the `env.*` loop, before the tmux self-wrap so the `-e MACF_*` passthrough carries them). **Omitting `MACF_ADVERTISE_HOST` is silent-fatal:** the server defaults the registry-advertised host to `127.0.0.1` → unreachable from the GitHub router **and** a SAN-mismatch against the FQDN leaf cert → the route fails the mTLS POST. (The reconciliation that *dropped* these exports is exactly the bug #111 fixed.) The rest of the `MACF_*` config (`MACF_PROJECT`, the 3 cert paths, `MACF_REGISTRY_TYPE=profile`+`MACF_REGISTRY_USER=groundnuty`, `MACF_WORKSPACE_DIR`, `MACF_LOG_PATH`) lives in `.claude/.macf/env.*`.
7. **Reconcile `claude.sh` to the framework generation** (not a bolt-on — `macf#533` graduation). Source `.claude/.macf/env.*`, the macf#340 tmux self-wrap (`macf@<bot-name>`), `--plugin-dir .macf/plugin-cs`, a `host-prelude.sh` sourced *before* `env.*` (brew must precede `env.github`'s token mint), and **drop** the `sg-docker` wrap (verified obsolete) + the manual OTEL-inlining (the in-session env.* re-source handles it). **Back the original launcher + local state out-of-tree first (Step 0).**

**Cutover ordering (SAFETY-CRITICAL) + self-restart resume.** The channel server only comes up on a session restart — and **a running agent cannot restart itself.** Order is non-negotiable:

1. Stage steps 1-5 **without** restarting/repinning — Stage-2 (SSH, `@v1.3.4`) stays live.
2. **Operator (or peer-agent backup) relaunches** the agent's tmux session → loads the channel server → self-registers `MACF_AGENT_<AGENT>`.
3. **THEN** repin the caller `@v3.3.0` (+ `with:{project,registry-api-path}`). **Never repin before step 2** — a v3 caller pointing at a not-yet-running channel routes to a dead endpoint and the agent stops receiving prompts mid-migration.
4. Co-verify (`notify_received`→`tmux_wake_delivered`).

**Resume across the restart = the migration issue thread.** Before step 2 the agent leaves a crisp `RESUME: step 3 — repin caller @v3.3.0, then co-verify` note on its migration issue; the relaunched session reads it on SessionStart and continues. The issue *is* the cross-restart memory (also how science's phase-3 self-migration works).

**Stage-2 fallback = revertability, NOT dual-routing (DR-027 §4):** **(b), definitively** — ONE active caller (v3) + **retain the SSH infra** (`AGENT_SSH_KEY`, the agent's `agent-config.json` entry, tmux reachability) so revert is a one-line pin flip `@v3.3.0`→`@v1.3.4`. Do NOT run two live callers (both fire on the same events → double-routing). Stage-2 removal waits for the 2-month all-green bake.

## Operator prerequisites (gates)

1. **`MACF_ROUTING` App** (read-only: `metadata:read` + `actions_variables:read`) — its `*_APP_ID/_KEY` secrets are **already set per-repo** (verified). It must be **installed on `groundnuty/groundnuty`** so the router can read the profile registry (`#529`'s new operator step), plus confirm the App itself exists.
2. **App install scope:** for devops to manage the auditor repo's secrets and push its caller workflow, the `macf-devops-agent` App likely needs **access to `macf-auditor-agent`** (it is not in my installation's repo selection — a scoped-App 404, not absence). Registry *Variables* now live on `groundnuty/groundnuty` (self-registered by the server using its own token); the auditor repo access is for the caller-workflow push + per-repo secret set.
3. **CA/leaf minting** runs on `orzech-dev-agents` (devops-executed; no operator action beyond the above).

## Open questions

- ~~Registry scope~~ **RESOLVED (`macf#529`):** Profile mode on `groundnuty/groundnuty` — one fleet registry; canonical DR-006 already covers it (no amendment needed).
- **Fixed vs. random ports:** this DR recommends fixed (8700-band); confirm before phases 1–3 reserve it fleet-wide.
- **systemd-wrap of `claude.sh`:** deferred hardening — adopt after canary-zero proves the model?

## Alternatives considered

- **Standalone channel-server systemd daemon** — *rejected: architecturally impossible.* The server is an MCP stdio child of Claude Code (DR-002); it cannot be supervised independently. Supervision wraps `claude.sh`.
- **Random ports for the substrate (DR-007 default)** — rejected for the static co-tenant host (legibility; the documented map is the DR-027 §6 deliverable). CV agents remain random.
- **Org-scoped registry/secrets (DR-027 original wording)** — N/A: `groundnuty` is a user account → **Profile-scoped** registry on `groundnuty/groundnuty` (`macf#529`, DR-006 Profile mode; secrets stay per-repo). The interim repo-scope reading (`#528`) is superseded.
- **Hand-set per-agent registry Variables** — unnecessary: the server self-registers on launch; manual entries would drift from the live port.

## Consequences

**Positive.** Phase-0 proves the exact co-tenant per-agent-process / distinct-port / shared-CA topology phases 1–3 will reuse, at zero migration risk; the corrected supervision model (claude.sh, not a phantom daemon) prevents an unbuildable runbook; the shared single-host CA + fixed port band give a legible, reproducible layout.

**Negative / risk (mitigations).** Repo-scoped secrets mean rotation is a 4-repo loop, not one org update (*scripted loop; not a blocker*). The auditor home has three confirmed scaffolding gaps (CA/cert, F1 hook, `auditor.md`) that init didn't fill (*Decision 5 steps 1–3 close them*). The fixed-port band must be honored by future homes to stay collision-free (*documented here + reserved headroom*). Two transports (Stage-2 fallback + Stage-3) coexist through the DR-027 2-month bake (*expected; bake-then-drop*).

## References

- `macf` DR-002 / DR-004 / DR-005 / DR-006 / DR-007 / DR-022 / DR-025 / DR-026 / **DR-027** (the charter)
- `macf-devops-toolkit#105` (phase-0), `#90` (runner), `macf#525` (DR-027 ratification), `macf#526` (epic), `macf#528`→`macf#529` (registry-scope errata; **#529 Profile mode current**)
- Channel-server source: `macf/packages/macf-channel-server/` (`server.ts`, `https.ts`, `tmux-wake.ts`), `macf/packages/macf-core/src/config.ts` + `certs/agent-cert.ts`, `macf-actions/.github/workflows/agent-router.yml@v3.3.0`
- `macf/design/operations-runbook.md` (the Stage-3 failure-mode ops reference this builds on)
