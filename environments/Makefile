# Shared parent Makefile for all environments under this directory.
# Each environments/<env>/Makefile does `include ../Makefile` to inherit these
# targets; `ENVIRONMENT := $(notdir $(CURDIR))` in the child identifies which
# env is running.
#
# Pattern mirrored from groundnuty/onedata/spice-deployments — spice's folder
# is actually misspelled as `enviroments/` (sic); we corrected the name here
# to `environments/` without touching any other structural convention.
# Divergences for this workspace: the OLD VM ran k3d (see ##@ Cluster bootstrap).
# The NEW monitoring VM runs native k3s with airgap install + etcd backup/restore
# (see ##@ Native k3s, added in DR-004). Both target sets coexist here during the
# migration; the k3d set retires once the old VM is decommissioned.

SHELL = /bin/sh

$(info Devbox version: $(shell devbox version))

DEVBOX_RUN := devbox run -q --

# --- Version extraction via yq --------------------------------------------------
# Versions live in the yaml files they describe. Makefile reads them so no
# duplication: bump a chart's targetRevision in apps/<chart>-app.yaml, the
# Makefile picks it up on next invocation.

ARGOCD_APP_FILE := apps/argocd-app.yaml
ifneq ($(wildcard $(ARGOCD_APP_FILE)),)
ARGOCD_VERSION := $(shell $(DEVBOX_RUN) yq '.spec.sources[] | select(.chart == "argo-cd") | .targetRevision // ""' $(ARGOCD_APP_FILE) 2>/dev/null)
endif

ARGOCD_APPS_APP_FILE := apps/argocd-apps-app.yaml
ifneq ($(wildcard $(ARGOCD_APPS_APP_FILE)),)
ARGOCD_APPS_VERSION := $(shell $(DEVBOX_RUN) yq '.spec.sources[] | select(.chart == "argocd-apps") | .targetRevision // ""' $(ARGOCD_APPS_APP_FILE) 2>/dev/null)
endif

K3D_VERSION_FILE := k3d/version.yaml
ifneq ($(wildcard $(K3D_VERSION_FILE)),)
K3S_IMAGE := $(shell $(DEVBOX_RUN) yq e '.k3s_image // ""' $(K3D_VERSION_FILE) 2>/dev/null)
endif

# --- Persistent storage paths ---------------------------------------------------
# See ../design/DR-001-argocd-gitops-for-observability-spike.md §6 and the
# reference memory feedback_use_mnt_volume1_for_heavy_storage.md. All bytes
# that accumulate land on /mnt/volume1, never the root disk.
VOLUME_DIR      := /mnt/volume1
REGISTRY_DATA   := $(VOLUME_DIR)/k3d-registry-data
CLUSTER_STORAGE := $(VOLUME_DIR)/k3d-storage

# --- k3d identifiers ------------------------------------------------------------
CLUSTER_NAME  := macf
REGISTRY_NAME := macf-mirror

# --- Native k3s (new VM — DR-004) -----------------------------------------------
# Coexists with k3d during migration: the old VM uses the k3d targets above;
# the new monitoring VM uses the k3s targets below. Everything stateful (etcd,
# images, PVCs, snapshots) is pinned to $(VOLUME_DIR) — never the root disk.
K3S_DIR             := k3s
K3S_VERSION_FILE    := $(K3S_DIR)/version.yaml
ifneq ($(wildcard $(K3S_VERSION_FILE)),)
K3S_VERSION := $(shell $(DEVBOX_RUN) yq e '.k3s_version // ""' $(K3S_VERSION_FILE) 2>/dev/null)
K3S_DATA_DIR := $(shell $(DEVBOX_RUN) yq e '.data-dir // ""' $(K3S_DIR)/config.yaml 2>/dev/null)
K3S_SNAPSHOT_DIR := $(shell $(DEVBOX_RUN) yq e '.etcd-snapshot-dir // ""' $(K3S_DIR)/config.yaml 2>/dev/null)
endif
# Cached airgap artifacts live on the external volume so reset+rebuild is fast/offline.
K3S_CACHE  := $(VOLUME_DIR)/k3s-airgap/$(K3S_VERSION)
# Off-box etcd-snapshot mirror target (override on CLI: make etcd-backup-sync ETCD_BACKUP_REMOTE=user@host:/path)
ETCD_BACKUP_REMOTE ?=
SUDO ?= sudo

KUBECONFIG ?= $(HOME)/.kube/config
export KUBECONFIG

# --- Helpers --------------------------------------------------------------------
check_defined = \
    $(strip $(foreach 1,$1, \
        $(call __check_defined,$1,$(strip $(value 2)))))
__check_defined = \
    $(if $(value $1),, \
        $(error Undefined $1$(if $2, ($2))$(if $(value @), \
                required by target `$@')))

$(info ENVIRONMENT=$(ENVIRONMENT), K3S_IMAGE=$(K3S_IMAGE), ARGOCD_VERSION=$(ARGOCD_VERSION), ARGOCD_APPS_VERSION=$(ARGOCD_APPS_VERSION))

.DEFAULT_GOAL := help

# ################################################################################
# Help
# ################################################################################

.PHONY: help
help:  ## Show this help
	@awk 'BEGIN {FS = ":.*## "; printf "Usage: make \033[36m<target>\033[0m\n"} /^##@ / { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } /^[a-zA-Z_-]+:.*?## / { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ################################################################################
##@ Preflight
# ################################################################################

.PHONY: doctor
doctor:  ## Check docker, devbox, volume mount, tool availability
	@echo "=== docker ==="
	@docker version --format '{{.Server.Version}}' 2>&1 | head -1 || { \
	  echo ""; \
	  echo "FAIL: docker inaccessible. Likely stale-tmux group issue (see"; \
	  echo "      reference_docker_sg_workaround_stale_tmux.md). Workarounds:"; \
	  echo "        1) wrap each docker-touching make target: 'sg docker -c \"make <tgt>\"'"; \
	  echo "        2) tmux kill-server + relaunch from a login shell"; \
	  exit 1; }
	@echo "=== devbox ==="
	@devbox version
	@echo "=== $(VOLUME_DIR) ==="
	@df -h $(VOLUME_DIR) 2>/dev/null | tail -1 || { echo "FAIL: $(VOLUME_DIR) not mounted"; exit 1; }
	@echo "=== devbox tools ==="
	@$(DEVBOX_RUN) k3d version 2>&1 | head -2
	@$(DEVBOX_RUN) helm version --short 2>&1
	@$(DEVBOX_RUN) kubectl version --client -o yaml 2>/dev/null | grep -i gitVersion | head -1 || echo "(kubectl gitVersion check skipped — no cluster yet)"

# ################################################################################
##@ Cluster bootstrap
# ################################################################################

.PHONY: registry
registry:  ## Create persistent k3d registry backed by $(REGISTRY_DATA)
	@mkdir -p $(REGISTRY_DATA)
	@# k3d registry create does NOT support --config (only k3d cluster create does).
	@# Flags passed directly; persistent volume mount is the load-bearing bit.
	@if $(DEVBOX_RUN) k3d registry list 2>/dev/null | grep -q "^k3d-$(REGISTRY_NAME) "; then \
	  echo "k3d-$(REGISTRY_NAME) registry already exists"; \
	else \
	  $(DEVBOX_RUN) k3d registry create $(REGISTRY_NAME) \
	    --port 5001 \
	    --volume $(REGISTRY_DATA):/var/lib/registry ; \
	fi

.PHONY: cluster
cluster: registry  ## Create k3d cluster (PVC mounts on $(CLUSTER_STORAGE))
	@:$(call check_defined, K3S_IMAGE, set k3d/version.yaml:k3s_image)
	@mkdir -p $(CLUSTER_STORAGE)
	@if $(DEVBOX_RUN) k3d cluster list 2>/dev/null | awk 'NR>1 {print $$1}' | grep -qx "$(CLUSTER_NAME)"; then \
	  echo "cluster $(CLUSTER_NAME) already exists"; \
	else \
	  $(DEVBOX_RUN) k3d cluster create --config k3d/config.yaml; \
	fi
	@$(DEVBOX_RUN) kubectl cluster-info
	@$(DEVBOX_RUN) kubectl get nodes

.PHONY: cluster-down
cluster-down:  ## Delete the k3d cluster (registry persists)
	-@$(DEVBOX_RUN) k3d cluster delete $(CLUSTER_NAME)

.PHONY: registry-down
registry-down:  ## Delete the k3d registry + wipe $(REGISTRY_DATA)
	-@$(DEVBOX_RUN) k3d registry delete k3d-$(REGISTRY_NAME)
	-@sudo rm -rf $(REGISTRY_DATA)

# ################################################################################
##@ Native k3s (new monitoring VM — DR-004)
# ################################################################################
# Airgap install: pinned k3s binary + airgap images cached on $(VOLUME_DIR) so
# `make reset-k3s && make k3s-all` rebuilds in minutes, offline. ALL state
# (etcd, images, PVCs, snapshots) lives on $(VOLUME_DIR), never the root disk.

.PHONY: k3s-prereqs
k3s-prereqs:  ## Verify /mnt/volume1 mounted + k3s/.token present before install
	@test -d $(VOLUME_DIR) || { echo "FAIL: $(VOLUME_DIR) not mounted (format+mount /dev/vdb first)"; exit 1; }
	@test -f $(K3S_DIR)/.token || { echo "FAIL: $(K3S_DIR)/.token missing. Run: cp $(K3S_DIR)/.token.example $(K3S_DIR)/.token && openssl rand -hex 32 > $(K3S_DIR)/.token"; exit 1; }
	@$(SUDO) mkdir -p $(K3S_DATA_DIR) $(K3S_SNAPSHOT_DIR) $(VOLUME_DIR)/k3s-storage $(K3S_CACHE)
	@echo "k3s prereqs OK: data-dir=$(K3S_DATA_DIR) snapshots=$(K3S_SNAPSHOT_DIR)"

$(K3S_CACHE)/k3s:
	@echo "Downloading k3s $(K3S_VERSION) binary -> $(K3S_CACHE) (cached on external volume)..."
	@$(SUDO) mkdir -p $(K3S_CACHE)
	@$(SUDO) curl -fL -o $(K3S_CACHE)/k3s "https://github.com/k3s-io/k3s/releases/download/$(subst +,%2B,$(K3S_VERSION))/k3s"
	@$(SUDO) chmod +x $(K3S_CACHE)/k3s

$(K3S_CACHE)/k3s-airgap-images-amd64.tar.zst:
	@echo "Downloading k3s $(K3S_VERSION) airgap images -> $(K3S_CACHE)..."
	@$(SUDO) mkdir -p $(K3S_CACHE)
	@$(SUDO) curl -fL -o $(K3S_CACHE)/k3s-airgap-images-amd64.tar.zst "https://github.com/k3s-io/k3s/releases/download/$(subst +,%2B,$(K3S_VERSION))/k3s-airgap-images-amd64.tar.zst"

$(K3S_CACHE)/install.sh:
	@$(SUDO) mkdir -p $(K3S_CACHE)
	@$(SUDO) curl -fL -o $(K3S_CACHE)/install.sh https://get.k3s.io
	@$(SUDO) chmod +x $(K3S_CACHE)/install.sh

.PHONY: k3s-install
k3s-install: k3s-prereqs $(K3S_CACHE)/k3s $(K3S_CACHE)/k3s-airgap-images-amd64.tar.zst $(K3S_CACHE)/install.sh  ## Install native k3s from the committed config (airgap, cached)
	@:$(call check_defined, K3S_VERSION, set k3s/version.yaml:k3s_version)
	@echo "Installing k3s $(K3S_VERSION) (airgap, data on $(VOLUME_DIR))..."
	@$(SUDO) mkdir -p /etc/rancher/k3s $(K3S_DATA_DIR)/agent/images
	@$(SUDO) cp $(K3S_DIR)/config.yaml /etc/rancher/k3s/config.yaml
	@$(SUDO) cp $(K3S_DIR)/.token /etc/rancher/k3s/.token
	@$(SUDO) chmod 600 /etc/rancher/k3s/.token
	@$(SUDO) cp $(K3S_CACHE)/k3s /usr/local/bin/k3s
	@$(SUDO) chmod +x /usr/local/bin/k3s
	@$(SUDO) cp $(K3S_CACHE)/k3s-airgap-images-amd64.tar.zst $(K3S_DATA_DIR)/agent/images/
	@$(SUDO) INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_VERSION=$(K3S_VERSION) $(K3S_CACHE)/install.sh
	@echo "Waiting for node Ready + applying local-path override (PVCs -> $(VOLUME_DIR))..."
	@$(SUDO) k3s kubectl wait --for=condition=Ready node --all --timeout=120s
	@$(SUDO) k3s kubectl apply -f $(K3S_DIR)/local-path-config.yaml
	@$(SUDO) k3s kubectl -n kube-system rollout restart deployment/local-path-provisioner
	@echo "k3s installed. etcd snapshots -> $(K3S_SNAPSHOT_DIR). Verify: sudo k3s etcd-snapshot ls"

.PHONY: reset-k3s
reset-k3s:  ## Uninstall k3s + wipe its data-dir (cached airgap artifacts survive for fast rebuild)
	@echo -n "This removes k3s + ALL cluster data on $(K3S_DATA_DIR). PVC data + snapshots on $(VOLUME_DIR) are SEPARATE. Continue? [y/N] " && read a && [ "$${a:-N}" = "y" ] || { echo "Aborted."; exit 1; }
	-@$(SUDO) /usr/local/bin/k3s-uninstall.sh
	-@$(SUDO) rm -rf $(K3S_DATA_DIR)
	@echo "k3s removed. Rebuild: make k3s-install (cached) + make argocd-bootstrap"

.PHONY: k3s-all
k3s-all: k3s-install argocd-bootstrap  ## = k3s-install + argocd-bootstrap (new VM bring-up)

.PHONY: etcd-snapshot-ls
etcd-snapshot-ls:  ## List etcd snapshots on the external volume
	@$(SUDO) k3s etcd-snapshot ls 2>/dev/null || ls -lh $(K3S_SNAPSHOT_DIR) 2>/dev/null || echo "no snapshots yet at $(K3S_SNAPSHOT_DIR)"

.PHONY: etcd-snapshot-now
etcd-snapshot-now:  ## Take an on-demand etcd snapshot now
	@$(SUDO) k3s etcd-snapshot save --name on-demand
	@$(MAKE) etcd-snapshot-ls

.PHONY: etcd-backup-sync
etcd-backup-sync:  ## rsync etcd snapshots off-box (set ETCD_BACKUP_REMOTE=user@host:/path)
	@test -n "$(ETCD_BACKUP_REMOTE)" || { echo "FAIL: set ETCD_BACKUP_REMOTE=user@host:/path (off-box dest for whole-VM-loss protection)"; exit 1; }
	@echo "Syncing $(K3S_SNAPSHOT_DIR) -> $(ETCD_BACKUP_REMOTE) ..."
	@$(SUDO) rsync -aHAX --numeric-ids --partial --info=progress2 $(K3S_SNAPSHOT_DIR)/ $(ETCD_BACKUP_REMOTE)/

.PHONY: all
all: cluster argocd-bootstrap  ## = cluster + argocd-bootstrap (k3d / old VM)

# ################################################################################
##@ ArgoCD bootstrap
# ################################################################################

.PHONY: argocd-bootstrap
argocd-bootstrap:  ## Install argocd + argocd-apps (app-of-apps) — one-time
	@:$(call check_defined, ARGOCD_VERSION, should come from apps/argocd-app.yaml)
	@:$(call check_defined, ARGOCD_APPS_VERSION, should come from apps/argocd-apps-app.yaml)
	@$(DEVBOX_RUN) helm repo add argo https://argoproj.github.io/argo-helm
	@$(DEVBOX_RUN) helm repo update argo
	@echo "--- installing argo-cd $(ARGOCD_VERSION)"
	@$(DEVBOX_RUN) helm upgrade -i \
	  --namespace argocd --create-namespace \
	  --values values/argocd.yaml \
	  --version $(ARGOCD_VERSION) \
	  argocd argo/argo-cd
	@echo "--- waiting for argocd-application-controller + repo-server"
	@$(DEVBOX_RUN) kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m
	@$(DEVBOX_RUN) kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=5m
	@echo "--- ensuring argocd-applications namespace exists (where Application CRs land)"
	@# `application.namespaces=argocd-applications` in values/argocd.yaml scopes argocd to
	@# this namespace. helm's --create-namespace only creates the chart's *release* namespace,
	@# so we pre-create the Applications namespace explicitly.
	@$(DEVBOX_RUN) kubectl create namespace argocd-applications --dry-run=client -o yaml | $(DEVBOX_RUN) kubectl apply -f -
	@echo "--- installing argocd-apps $(ARGOCD_APPS_VERSION) (app-of-apps root)"
	@$(DEVBOX_RUN) helm upgrade -i \
	  --namespace argocd-apps --create-namespace \
	  --values values/argocd-apps.yaml \
	  --version $(ARGOCD_APPS_VERSION) \
	  argocd-apps argo/argocd-apps
	@echo "argocd bootstrap complete — apps/*-app.yaml reconciliation starts automatically"

# ################################################################################
##@ Day-to-day ops
# ################################################################################

.PHONY: sync
sync:  ## Force argocd hard-refresh on every app
	@$(DEVBOX_RUN) bash -c 'kubectl get app -A -o json | jq -r ".items[] | \"\(.metadata.namespace) \(.metadata.name)\"" | while read ns name; do kubectl -n $$ns annotate --overwrite app $$name argocd.argoproj.io/refresh=hard; done'

.PHONY: status
status:  ## Print argocd app status (all namespaces)
	@$(DEVBOX_RUN) kubectl get app -A

.PHONY: nuke
nuke: cluster-down registry-down  ## Teardown: cluster + registry + $(REGISTRY_DATA)

# ################################################################################
##@ Port-forwards (block until Ctrl-C)
# ################################################################################

.PHONY: pf-grafana pf-tempo pf-collector pf-argocd pf-prometheus
pf-grafana:  ## Grafana at http://127.0.0.1:3000
	$(DEVBOX_RUN) kubectl -n monitoring port-forward svc/kube-prom-stack-grafana 3000:80

pf-tempo:  ## Tempo query API — local :13200 → cluster :3200
	@# High host port to avoid collision with the existing compose stack
	@# (macf-obs-*) which binds :3200. smoke.sh hits this for trace GET.
	@# Tempo's OTLP receivers (:4317/:4318) aren't forwarded here to avoid
	@# collision with `make pf-collector` — the smoke pipeline goes through
	@# the Collector, not directly to Tempo's OTLP.
	$(DEVBOX_RUN) kubectl -n tempo port-forward svc/tempo 13200:3200

pf-collector:  ## Collector OTLP — local :14317/:14318 → cluster :4317/:4318
	@# High host ports avoid collision with the existing compose collector
	@# (macf-obs-otel-collector-1) which binds :4317/:4318. smoke.sh POSTs here.
	$(DEVBOX_RUN) kubectl -n otel port-forward svc/central-collector 14317:4317 14318:4318

pf-argocd:  ## ArgoCD UI at http://127.0.0.1:8080
	$(DEVBOX_RUN) kubectl -n argocd port-forward svc/argocd-server 8080:80

pf-langfuse:  ## Langfuse UI at http://127.0.0.1:3001 (chart default :3000 → local :3001 to avoid Grafana collision)
	$(DEVBOX_RUN) kubectl -n langfuse port-forward svc/langfuse-web 3001:3000

pf-prometheus:  ## Prometheus UI/query API at http://127.0.0.1:9090 — needed for `make smoke` metrics leg
	$(DEVBOX_RUN) kubectl -n monitoring port-forward svc/kube-prom-stack-kube-prome-prometheus 9090:9090

# ################################################################################
##@ Utilities
# ################################################################################

.PHONY: grafana-password
grafana-password:  ## Print the Grafana admin password
	@$(DEVBOX_RUN) kubectl -n monitoring get secret kube-prom-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d && echo

.PHONY: argocd-password
argocd-password:  ## Print the ArgoCD admin password (from initial-admin-secret)
	@$(DEVBOX_RUN) kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo

.PHONY: test-alerts
test-alerts:  ## promtool unit-test the PrometheusRule alert expressions (no cluster needed; runs manifests/*/tests/run.sh)
	@ran=0; for r in manifests/*/tests/run.sh; do \
	  [ -x "$$r" ] || continue; ran=1; echo "=== $$r ==="; "$$r" || exit 1; \
	done; \
	if [ "$$ran" = 1 ]; then echo "✓ all alert-rule unit tests passed"; else echo "(no manifests/*/tests/run.sh found)"; fi

.PHONY: smoke
smoke:  ## OTLP round-trip test (needs `make pf-collector` + `make pf-tempo` in other terminals)
	@bash hack/smoke.sh

.PHONY: check-tempo-ingestion
check-tempo-ingestion:  ## Pattern A defense (silent-fallback-hazards Instance 8): cluster-side ingestion-vs-search invariant. Override WINDOW_SECONDS=N (default 300).
	@bash hack/check-tempo-ingestion.sh

.PHONY: doctor-otel
doctor-otel:  ## Pattern A defense (silent-fallback-hazards Instance 8 Tier 4): per-agent-process traces-emission invariant — detects stuck OTel exporters in long-lived claude processes. Override WINDOW_MINUTES=N (default 30).
	@bash hack/doctor-otel.sh

# NOTE (DR-004 / native k3s): the tailscale-otlp-up/down targets are GONE.
# They were a k3d-era workaround — k3d's serverlb bound host ports to 127.0.0.1
# only, so `tailscale serve` was needed to ALSO reach OTLP/Tempo over the tailnet.
# Native k3s ServiceLB (klipper) binds LoadBalancer-service ports on EVERY host
# interface (private IP + localhost + the tailnet IP) via iptables — so
# central-collector-lb + tempo-query-lb already cover the tailnet with no extra
# config. `tailscale serve` is redundant on k3s and was removed.

.PHONY: github-runner-setup
github-runner-setup:  ## DR-003/#90: host-prep the LOW-PRIV self-hosted GH Actions runner (macf-runner user + single-command sudoers send-helper grant + download + ephemeral respawn wrapper + systemd unit). NEEDS sudo. Does NOT register/start — gated on REG_TOKEN + macf-actions#47 merged + fork-PR toggles off; then: REG_TOKEN=... sudo bash hack/setup-github-runner.sh register
	@bash hack/setup-github-runner.sh setup

.PHONY: langfuse-bootstrap
langfuse-bootstrap:  ## Generate ALL Langfuse secrets (subchart auth + headless-init + Collector api-keys) + restart pods. ONE-SHOT.
	@bash hack/langfuse-bootstrap.sh

.PHONY: clickhouse-logs-creds
clickhouse-logs-creds:  ## Copy ClickHouse password to ns/otel for the logs Collector's clickhouse exporter (#19c). ONE-SHOT.
	@bash hack/copy-clickhouse-creds.sh

.PHONY: archive-sessions
archive-sessions:  ## Archive substrate-agent session JSONLs (#33). Override OUT_DIR=<path> to control destination.
	@bash hack/archive-agent-sessions.sh

.PHONY: grafana-allowlist-sync
grafana-allowlist-sync:  ## Sync dispatch-allowlist regex into release-hygiene manifests from canonical hook (#74 / DR-019 Amendment A SSOT discipline). Run alongside any substrate-sync round that bumps the canonical's MACF_ACTIONS_DISPATCH_ALLOWLIST_REGEX.
	@regex=$$(grep -oP "MACF_ACTIONS_DISPATCH_ALLOWLIST_REGEX='\K[^']+" \
	    ../../.claude/scripts/check-gh-token.sh); \
	if [ -z "$$regex" ]; then \
	    echo "ERROR: could not extract MACF_ACTIONS_DISPATCH_ALLOWLIST_REGEX from .claude/scripts/check-gh-token.sh" >&2; \
	    exit 1; \
	fi; \
	echo "Canonical regex (1-backslash, for ConfigMap audit-record): $$regex"; \
	$(DEVBOX_RUN) yq -i ".data.regex = \"$$regex\"" \
	    manifests/grafana-dashboards-release-hygiene/allowlist-configmap.yaml; \
	python3 -c "import sys, re; \
p = sys.argv[1]; new_for_configmap = sys.argv[2]; \
new_for_promql = new_for_configmap.replace('\\\\', '\\\\\\\\'); \
content = open(p).read(); \
content = re.sub(r'workflow!~\"[^\"]+\"', lambda m: 'workflow!~\"' + new_for_promql + '\"', content); \
open(p, 'w').write(content); \
print('PromQL-escaped regex (2-backslash, for alerts-promrule.yaml): ' + new_for_promql)" \
	    manifests/grafana-dashboards-release-hygiene/alerts-promrule.yaml \
	    "$$regex"; \
	echo "Synced into:"; \
	echo "  - manifests/grafana-dashboards-release-hygiene/allowlist-configmap.yaml (.data.regex, 1-backslash canonical form)"; \
	echo "  - manifests/grafana-dashboards-release-hygiene/alerts-promrule.yaml (workflow!~\"...\" matcher, PromQL-escaped to 2-backslash)"; \
	echo "Verify with: git diff manifests/grafana-dashboards-release-hygiene/"

.PHONY: env-test
env-test:  ## Debug — print inherited vars
	@echo "ENVIRONMENT=$(ENVIRONMENT)"
	@echo "K3S_IMAGE=$(K3S_IMAGE)"
	@echo "ARGOCD_VERSION=$(ARGOCD_VERSION)"
	@echo "ARGOCD_APPS_VERSION=$(ARGOCD_APPS_VERSION)"
	@echo "REGISTRY_DATA=$(REGISTRY_DATA)"
	@echo "CLUSTER_STORAGE=$(CLUSTER_STORAGE)"
