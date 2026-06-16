# DR-004 — Migrate the observability stack to a new VM on native k3s, with real etcd backups

- **Status:** proposed
- **Date:** 2026-06-16
- **Author:** macf-devops-agent
- **Supersedes:** DR-001's k3d choice (for the new VM); k3d remains historical record
- **Related:** the 2026-06-16 OOM crash post-mortem; recovered-secrets forensics (gitignored)

## Context

The original VM (`orzech-dev-agents`, this workspace's host) OOM-crashed. The
crash + reboot **destroyed the k3d node container**, and with it the k3s
datastore (etcd/kine) where **every Kubernetes Secret lived**. PVC *data*
survived on the `/mnt/volume1` bind-mount, but the Secrets did not. There was
**no etcd snapshot and no VM snapshot**. We salvaged some credentials from
agent session-logs (SALT, API keys, admin pw, S3 pw — see gitignored
`manifests/langfuse/recovered-secrets/`), but `encryptionKey`, `nextauth`, and
all four DB passwords were unrecoverable from logs.

This is the second disruption in ~2 weeks (the 06-10/11 disk event was the
first). The lesson is unambiguous: **the cluster had no backup strategy, and
critical state lived inside an ephemeral container.** The operator has
provisioned a fresh VM (`orzech-dev-agents-monitoring`, `192.168.102.15`,
reached via `alice-bastion` ProxyJump) and directed that the migration also be
an **infrastructure improvement**, with three explicit requirements:

1. **Native k3s**, not k3d (k3d was chosen in DR-001 only to work around
   operational friction; on a dedicated VM that friction is gone).
2. **A clear, committed cluster config file** in this repo.
3. **A real etcd backup strategy**, so a node loss never again loses Secrets —
   and **nothing of importance ever lives only inside a container.**

## Decision

Rebuild the stack on the new VM as **native k3s (single-node, embedded etcd)**,
GitOps-reconciled by argocd exactly as today, with three durability changes
baked in from day one: scheduled etcd snapshots to the persistent volume,
all stateful data on `/mnt/volume1` (never container-local), and a committed
declarative k3s config.

### Why native k3s over k3d

| Concern | k3d (old VM) | native k3s (new VM) |
|---|---|---|
| etcd/datastore location | inside the node **container** (lost on container delete) | on the **host** at `/var/lib/rancher/k3s/server/db` (survives reboots) |
| etcd snapshots | not built-in for k3d's container | **built-in** k3s scheduled etcd snapshots (`--etcd-snapshot-*`) |
| host-port mapping | k3d serverlb + `--port-add` indirection (see memory: `host_map_clusterip_via_lb_serverlb`) | k3s binds host ports natively; ServiceLB (klipper) works directly |
| docker dependency | requires docker (the stale-tmux `sg docker` workaround) | k3s uses containerd directly; **no docker, no sg-docker workaround** |
| storage | docker bind-mount of `/var/lib/rancher/k3s/storage` | k3s writes there on the host directly |

k3d's entire reason-for-being on the old box (docker-group/tmux friction,
quick teardown) does not apply to a dedicated long-lived monitoring VM. Native
k3s removes a whole layer of indirection AND is the layer that gives us
first-class etcd backups.

## Reference implementation: `groundnuty/onedata/spice-deployments`

This is NOT a greenfield design — the sibling `spice-deployments` repo (which
this workspace's layout already mirrors, per CLAUDE.md) runs **native k3s with
exactly this shape** across four production environments (`cloud-pl`,
`cloud-sk`, `uibk`, `azure-interway`). DR-004 adopts its proven patterns and
fixes the one anti-pattern it carries (a committed cluster token). Concrete
files to copy/adapt:

- `enviroments/<env>/k3s/{config,config-agent,registries,version}.yaml` — the
  committed config layout (validates `environments/macf/k3s/` in this DR).
- `enviroments/Makefile` targets `k3s-install` / `k3s-upgrade` / `reset-k3s` —
  airgap install: download pinned `k3s` binary + `k3s-airgap-images-*.tar.zst`,
  `cp k3s/config.yaml /etc/rancher/k3s/`, `INSTALL_K3S_SKIP_DOWNLOAD=true
  ./install.sh`. Version-deterministic; better than `curl get.k3s.io`.
- All four envs use the **same etcd-snapshot quartet** we propose (they run
  `0 */24 * * *` retention 14; we keep tighter cadence — see below).

### Version: pin to the LATEST stable k3s (operator directive)

`k3s/version.yaml` → **`k3s_version: v1.36.1+k3s1`** (latest stable as of
2026-05-20, live-fetched from k3s-io/k3s releases on 2026-06-16). This is
newer than the old cluster's `v1.35.3+k3s1` and spice-deployments' `v1.34.1`.
Per the verify-versions rule, re-check `gh api repos/k3s-io/k3s/releases/latest`
at implementation time and bump if a newer stable exists. Charts are
k8s-version-agnostic at our usage; a one-minor jump (1.35→1.36) is low-risk for
a single-node observability stack — verify CRDs (otel-operator, cert-manager,
kube-prometheus-stack) support 1.36 before cutover (they do as of their current
pinned versions; confirm in Phase 1).

### Airgap install = fast nuke-and-rebuild (operator-valued)

The airgap pattern isn't only for offline installs — because the pinned `k3s`
binary + `k3s-airgap-images-*.tar.zst` are cached locally, `make reset-k3s &&
make all` rebuilds the entire cluster in **minutes with no re-download**. This
makes "nuke everything and rebuild from git" a cheap, routine operation (the
operator explicitly wants this). Combined with etcd snapshots + PVC data on the
persistent volume, a full rebuild is: `reset-k3s` → `k3s-install` (cached) →
`argocd-bootstrap` (reconciles from git) → restore etcd snapshot OR re-apply
secrets + rsync data. We keep the cached airgap artifacts on `/mnt/volume1` so
they survive a root-disk wipe too.

### 1. Declarative k3s config — committed

New `environments/macf/k3s/config.yaml` (k3s reads `/etc/rancher/k3s/config.yaml`;
`make k3s-install` copies it there). Modeled on `spice-deployments/.../uibk/k3s/config.yaml`:

```yaml
# /etc/rancher/k3s/config.yaml  (source: environments/macf/k3s/config.yaml)
# So k3s uses embedded etcd instead of sqlite (REQUIRED for etcd snapshots).
cluster-init: true
write-kubeconfig-mode: "0660"
write-kubeconfig-group: 1000
tls-san:
  - "127.0.0.1"
  - "localhost"
  - "orzech-dev-agents-monitoring"
  - "192.168.102.15"
  # + the tailnet MagicDNS name once tailscale is up (for off-VM agents)
# disable k3s bundled components we don't use / replace
disable: traefik,local-storage
disable-default-registry-endpoint: true
# Keep containerd images + data-root OFF the root disk (lesson from the OOM/disk incidents)
data-dir: /mnt/volume1/k3s
# --- DURABILITY: scheduled etcd snapshots to the PERSISTENT volume ---
# Tighter cadence than spice-deployments (24h) — this is a more volatile dev box.
etcd-snapshot-schedule-cron: "0 */6 * * *"          # every 6h
etcd-snapshot-retention: 28                          # ~7 days
etcd-snapshot-dir: /mnt/volume1/k3s-etcd-snapshots   # NOT root disk, NOT a container
etcd-snapshot-compress: true                         # spice-deployments uses this — adopt
# NOTE: cluster token is NOT committed here (see "Improvement" below) — it is
# installed from a gitignored k3s/.token file via `make k3s-install`.
```

**Improvement over the reference:** spice-deployments commits the cluster
`token:` in plaintext in the tracked `config.yaml` (with an inline "do not use
in production!" comment). That is the exact secret-in-VCS class this whole DR
exists to prevent. We instead: keep `token` OUT of the committed config, store
the real token in a gitignored `environments/macf/k3s/.token`, and have
`make k3s-install` write it to `/etc/rancher/k3s/` separately (same mechanism
spice-deployments already uses for its `auth-token` file — we just extend it to
the cluster token too).

### local-storage note

spice-deployments sets `disable: ...,local-storage` and runs its own storage.
Our charts currently rely on the `local-path` StorageClass (PVCs use
`storageClass: local-path`). Two options, decided at implementation: (a) keep
k3s's bundled local-path (do NOT disable it) and point its path at
`/mnt/volume1/k3s-storage` via a committed `local-path-config` ConfigMap; or
(b) disable it and provision local-path ourselves. Prefer (a) — least change,
keeps PVC manifests untouched. (DR-004's earlier `default-local-storage-path`
line is not a real k3s flag; the correct mechanism is the local-path-provisioner
ConfigMap — corrected here.)

Host ports: native k3s ServiceLB binds the LoadBalancer Services' ports on the
host directly, so the stable OTLP endpoints (`14317/14318`), Tempo query
(`13200`), and `6443` are reached **without** the k3d serverlb `--port-add`
dance. The LoadBalancer Services already in `manifests/` keep working; we drop
the k3d-specific port plumbing.

### 2. etcd backup strategy (the core ask)

- **Scheduled, automatic:** k3s `--etcd-snapshot-schedule-cron` every 6h,
  retention 28, written to **`/mnt/volume1/k3s-etcd-snapshots`** (the
  persistent `/dev/vdb` volume — NOT the root disk, NOT a container).
- **Off-box copy:** a `make etcd-backup-sync` target (+ optional systemd timer)
  that rsyncs the snapshot dir to a second location (the old VM, or an object
  store) so a *whole-VM* loss is also survivable. Snapshots on the same VM
  protect against node/etcd corruption; the off-box copy protects against VM
  loss. Both matter — this incident was the latter class.
- **Restore is one command:** `k3s server --cluster-reset
  --cluster-reset-restore-path=<snapshot>`. Documented in a runbook.
- **What the snapshot contains:** all of etcd = every Secret, every CR, every
  argocd Application. Combined with PVC data on `/mnt/volume1`, a snapshot +
  volume = complete, restorable cluster. This is precisely what we lacked.

### 3. Nothing of importance inside a container

- **etcd/datastore:** on host (`/mnt/volume1/k3s/server/db`) — survives
  reboot/container-equivalent loss.
- **PVC data:** local-path provisioner → `/mnt/volume1/k3s-storage`.
- **Secrets:** still k8s Secrets (in etcd, now snapshotted) AND their
  generators are committed (`secrets.yaml.example` + `langfuse-bootstrap`), so
  they are reconstructible. We ALSO keep an encrypted, off-box copy of the
  *generated* secret values (sops/age-encrypted, committed) so a bootstrap is
  never needed for disaster recovery — eliminating the salt-skew re-init
  problem entirely. (Follow-up DR if sops adoption needs its own decision.)
- **Container images:** containerd cache on `/mnt/volume1/k3s` — rebuildable
  anyway (pulled from upstream registries).

### 4. Fix the OOM root cause

The crash was RAM exhaustion with **zero swap**. Both old and new VMs are
55Gi/no-swap. Add a swap file on the new VM (e.g. 8–16Gi on `/mnt/volume1`) as
a spill buffer + a memory-pressure alert in the existing kube-prometheus-stack
(we run Prometheus already — wire an alert rule on node MemAvailable). Swap
turns a hard OOM-crash into degradation we can observe and react to.

## Migration procedure (data-preserving, resumable)

Phased; each phase verifiable; the data copy is rsync (resumable, your
explicit ask). The source PVC data is intact on the old VM's `/mnt/volume1`.

**Phase 0 — target prep (idempotent):**
1. `ssh-keygen -R 192.168.102.15` on this box (stale `alice-argocd` host key).
2. On target: partition+format `/dev/vdb` ext4, mount `/mnt/volume1` (fstab),
   `mkdir` the k3s subdirs. Add swap file. Clone the repo, `devbox install`.

**Phase 1 — install native k3s with the committed config:**
3. `make k3s-install` (new target, ported from `spice-deployments/enviroments/Makefile`):
   downloads the pinned `k3s` binary + `k3s-airgap-images-amd64.tar.zst` for
   `k3s/version.yaml`'s version; copies `k3s/config.yaml` +
   `k3s/registries.yaml` + the gitignored `k3s/.token` to `/etc/rancher/k3s/`;
   runs `INSTALL_K3S_SKIP_DOWNLOAD=true ./install.sh`. Version-deterministic,
   no piped-curl-to-shell. (Fallback: `curl -sfL https://get.k3s.io |
   INSTALL_K3S_VERSION=v1.36.1+k3s1 sh -`.)
4. Verify embedded-etcd backend + snapshot schedule active: `k3s etcd-snapshot ls`.
5. `make argocd-bootstrap` — argocd reconciles every chart from git. Empty
   stack comes up (Langfuse CrashLoops on missing Secrets, as expected).

**Phase 2 — migrate the data (rsync, resumable, uid-preserving):**
6. **Stop the target's stateful pods** (scale Langfuse/Prometheus/Tempo/Loki to
   0, or suspend argocd auto-sync) so nothing writes while we copy.
7. rsync each PVC from old→new. **Mandatory flags** (your uid/gid caution):
   ```
   sudo rsync -aHAX --numeric-ids --partial --info=progress2 \
       -e 'ssh -J alice-bastion' \
       /mnt/volume1/k3d-storage/<pvc>/  ubuntu@192.168.102.15:/mnt/volume1/k3s-storage/<pvc>/
   ```
   `-aHAX --numeric-ids` preserves the container uids (472 grafana, 1001
   bitnami, 10001 loki, 2000) raw; `--partial` makes it resumable across
   bastion drops. **Run as root on source** (PVC dirs are mode-700 uid-owned).
   The new PVC dir names differ (k3s local-path uses a different naming) — map
   each old PVC to the new PV's path; do this per-volume after the empty PVCs
   are created in Phase 1 so the target paths exist.

**Phase 3 — credential reconciliation (the recovered-secrets work):**
8. Apply recovered Secrets: SALT, S3 root (from gitignored recovered file);
   generate fresh `encryptionKey` + `nextauth`.
9. Postgres password reset: boot PG standalone in `trust` against copied data,
   `ALTER USER postgres PASSWORD`, set the matching k8s Secret, restart.
10. ClickHouse: try fresh-password-as-config first; reset only if access/ dir
    rejects.
11. Re-apply the recovered `pk-lf/sk-lf` to ns/otel `langfuse-api-keys` so the
    Collector + all agents keep working with no reconfiguration.
12. Run the salt-skew check (memory: `langfuse_bootstrap_salt_skew`): recompute
    `HMAC(salt, sk-lf)` vs stored `fast_hashed_secret_key`. If skew, we hold
    plaintext `sk-lf` → overwrite the stored hash.

**Phase 4 — verify + cut over:**
13. Re-enable argocd sync; all pods healthy.
14. Tempo traces queryable; Langfuse login + historical traces visible; Grafana
    dashboards render; `make smoke` OTLP round-trip green.
15. First etcd snapshot present in `/mnt/volume1/k3s-etcd-snapshots`; test a
    restore into a throwaway to prove the backup path BEFORE trusting it.
16. Repoint agents/Collector OTLP endpoint to the new VM (tailnet/host).

## Alternatives considered

- **k3d again on the new VM** — rejected: reproduces the exact "Secrets live in
  a container" failure that caused this incident; no native etcd snapshots.
- **Full managed k8s** — rejected: overkill for a single-node dev/monitoring
  box; the operator's environment is VM-based.
- **Logical dump/restore (pg_dump + ClickHouse BACKUP) instead of raw PVC
  rsync** — viable and sidesteps uid/permission issues, BUT requires the source
  cluster *running* to export; the source cluster is GONE. Raw PVC rsync is the
  only option that works against a dead cluster's surviving disk. (If we ever
  do a *live* migration, prefer logical dump.)
- **Abandon history, fresh start** — rejected by operator; history is
  recoverable and worth keeping.

## Consequences

- **Positive:** survivable infra (6-hourly etcd snapshots + off-box copy +
  data on persistent volume), simpler stack (no k3d/docker/serverlb
  indirection, no sg-docker workaround), committed declarative config, OOM
  made observable (swap + alert). A future node loss is a one-command restore.
- **Negative / cost:** the migration is multi-phase and needs operator root on
  the source for the rsync (harness blocks sudo for the agent). `encryptionKey`
  loss means a thin band of Langfuse in-app encrypted config is gone (not trace
  data). The k3s config + backup targets are new surface to maintain.
- **Follow-ups:** sops/age-encrypted committed secret values (own DR); decide
  whether the old VM is retained as the off-box snapshot target or retired.
