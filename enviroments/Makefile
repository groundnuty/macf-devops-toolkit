# Shared parent Makefile for all environments under this directory.
# Each enviroments/<env>/Makefile does `include ../Makefile` to inherit these
# targets; `ENVIRONMENT := $(notdir $(CURDIR))` in the child identifies which
# env is running.
#
# Pattern mirrored from groundnuty/onedata/spice-deployments:enviroments/Makefile.
# Divergences for this workspace: k3d instead of bare-metal k3s, no airgap
# image handling, no backup/restore targets (added later if needed).

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
	@if $(DEVBOX_RUN) k3d registry list 2>/dev/null | grep -q "^k3d-$(REGISTRY_NAME) "; then \
	  echo "k3d-$(REGISTRY_NAME) registry already exists"; \
	else \
	  $(DEVBOX_RUN) k3d registry create --config k3d/registry.yaml; \
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

.PHONY: all
all: cluster argocd-bootstrap  ## = cluster + argocd-bootstrap

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

.PHONY: pf-grafana pf-tempo pf-collector pf-argocd
pf-grafana:  ## Grafana at http://127.0.0.1:3000
	$(DEVBOX_RUN) kubectl -n monitoring port-forward svc/kube-prom-stack-grafana 3000:80

pf-tempo:  ## Tempo HTTP 3200 + OTLP 4317/4318
	$(DEVBOX_RUN) kubectl -n tempo port-forward svc/tempo 3200:3200 4317:4317 4318:4318

pf-collector:  ## Collector OTLP 4317/4318
	$(DEVBOX_RUN) kubectl -n otel port-forward svc/central-collector 4317:4317 4318:4318

pf-argocd:  ## ArgoCD UI at http://127.0.0.1:8080
	$(DEVBOX_RUN) kubectl -n argocd port-forward svc/argocd-server 8080:80

# ################################################################################
##@ Utilities
# ################################################################################

.PHONY: grafana-password
grafana-password:  ## Print the Grafana admin password
	@$(DEVBOX_RUN) kubectl -n monitoring get secret kube-prom-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d && echo

.PHONY: env-test
env-test:  ## Debug — print inherited vars
	@echo "ENVIRONMENT=$(ENVIRONMENT)"
	@echo "K3S_IMAGE=$(K3S_IMAGE)"
	@echo "ARGOCD_VERSION=$(ARGOCD_VERSION)"
	@echo "ARGOCD_APPS_VERSION=$(ARGOCD_APPS_VERSION)"
	@echo "REGISTRY_DATA=$(REGISTRY_DATA)"
	@echo "CLUSTER_STORAGE=$(CLUSTER_STORAGE)"
