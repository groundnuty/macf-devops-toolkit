# k3s cluster config — macf observability VM

Committed, declarative config for the native **k3s** single-node cluster on
`orzech-dev-agents-monitoring` (192.168.102.15). Replaces the old k3d setup
(see DR-004 for the why — the k3d node container held etcd, and the OOM crash
destroyed it along with every Secret).

## Files

| File | Purpose | Committed? |
|---|---|---|
| `config.yaml` | k3s server config → `/etc/rancher/k3s/config.yaml` | ✅ yes |
| `version.yaml` | pinned k3s version (latest stable) | ✅ yes |
| `local-path-config.yaml` | points the PVC provisioner at `/mnt/volume1` | ✅ yes |
| `.token.example` | template for the cluster token | ✅ yes |
| `.token` | **real** cluster token (`openssl rand -hex 32`) | ❌ gitignored |

## Everything on the external volume (`/dev/vdb` → `/mnt/volume1`)

Per operator directive, **nothing of value is on the root disk or inside an
ephemeral container.** The config enforces:

| State | Location |
|---|---|
| embedded etcd db | `/mnt/volume1/k3s/server/db` (via `data-dir`) |
| container images + containerd state | `/mnt/volume1/k3s/agent` (via `data-dir`) |
| kubelet / pod state | `/mnt/volume1/k3s` (via `data-dir`) |
| **etcd snapshots** | `/mnt/volume1/k3s-etcd-snapshots` |
| **PVC data** (all charts) | `/mnt/volume1/k3s-storage` (via `local-path-config`) |
| airgap install artifacts | `/mnt/volume1/k3s-<version>/` (cached for fast rebuild) |

A root-disk wipe loses **nothing** — the cluster restores from the external
volume. A whole-VM loss is covered by the off-box snapshot sync
(`make etcd-backup-sync`, see DR-004).

## Install / rebuild

```sh
# first install (downloads + caches the pinned k3s airgap artifacts on /mnt/volume1):
cp .token.example .token && openssl rand -hex 32 > .token   # one-time
make k3s-install            # installs k3s + config + local-path override
make argocd-bootstrap       # argocd reconciles the whole stack from git

# nuke + rebuild (cached artifacts → minutes, offline):
make reset-k3s && make all
```

## etcd backup / restore

- **Automatic:** every 6h, 28 retained, compressed, to
  `/mnt/volume1/k3s-etcd-snapshots` (configured in `config.yaml`).
- **List:** `sudo k3s etcd-snapshot ls`
- **Off-box copy:** `make etcd-backup-sync` (guards against whole-VM loss).
- **Restore:** stop k3s, then
  `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>`,
  restart. A snapshot + the `/mnt/volume1` PVC data = full cluster recovery.
