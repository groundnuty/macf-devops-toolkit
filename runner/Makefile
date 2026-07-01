# runner/Makefile — operate + document the self-hosted runners we manage (devops-toolkit#90).
#
# TWO LAYERS (per the operator's design):
#   - REGISTRY / aggregate — reads runners.yaml (the documented inventory) and drives the
#     generic layer across a fleet / all. Self-documenting: `make runners` prints what we run.
#   - GENERIC per-runner — operate ONE runner (REPO=owner/repo). The mechanism.
# Data (runners.yaml) is the registry; this Makefile is the mechanism. Add a runner in
# runners.yaml and every aggregate target picks it up — no per-repo target to hand-maintain.
#
# Needs yq (mikefarah v4) + jq. devbox provides them: `devbox run -- make -C runner <target>`
# (or from environments/macf). The sudo targets prompt for the operator's password.
# Extraction goes yq→json→jq: yq converts the yaml, jq does the shaping (portable
# string-interpolation, vs mikefarah-yq's differing string syntax).
YQ  ?= yq
JQ  ?= jq
REG := runners.yaml
J   = $(YQ) -o=json $(REG) | $(JQ) -r
.DEFAULT_GOAL := help

.PHONY: help
help:  ## Show targets
	@awk 'BEGIN{FS=":.*## "} /^##@ /{printf "\n\033[1m%s\033[0m\n",substr($$0,5)} /^[a-zA-Z_-]+:.*## /{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

##@ Registry / aggregate (reads runners.yaml — the documented inventory)

.PHONY: runners
runners:  ## Document the registry — all fleets → runners → status
	@$(J) '.fleets[] | "fleet: \(.name)  (registry \(.registry))", (.runners[] | "  - \(.repo)  [\(.visibility)] \(.status)  — \(.note)")'

.PHONY: verify-all
verify-all:  ## Health-check EVERY runner in the registry
	@$(J) '.fleets[].runners[].repo' | while read -r r; do \
	  echo "== $$r =="; ./verify-runner.sh --repo "$$r" || true; echo; done

.PHONY: verify-fleet
verify-fleet:  ## Health-check a fleet's runners (FLEET=macf)
	@[ -n "$(FLEET)" ] || { echo "set FLEET=<name> (see: make runners)"; exit 2; }
	@$(J) '.fleets[] | select(.name=="$(FLEET)") | .runners[].repo' | while read -r r; do \
	  echo "== $$r =="; ./verify-runner.sh --repo "$$r" || true; echo; done

##@ Generic per-runner (REPO=owner/repo — the mechanism)

.PHONY: verify
verify:  ## Health-check ONE runner (REPO=groundnuty/macf-science-agent)
	@[ -n "$(REPO)" ] || { echo "set REPO=owner/repo"; exit 2; }
	@./verify-runner.sh --repo "$(REPO)"

.PHONY: setup-user
setup-user:  ## Create the low-priv macf-runner user + send-helper sudoers rule (once per VM; sudo)
	sudo bash ./setup-macf-runner-user.sh

.PHONY: install
install:  ## Register ONE ephemeral runner (REPO=owner/repo TOKEN=<reg-token>; runs as macf-runner)
	@[ -n "$(REPO)" ] && [ -n "$(TOKEN)" ] || { echo "set REPO=owner/repo TOKEN=<operator-minted reg token>"; exit 2; }
	sudo -u macf-runner bash ./install-runner.sh --repo "$(REPO)" --token "$(TOKEN)"

.PHONY: up
up:  ## Run the listener in the foreground (the isolation proof / measurement window; sudo)
	sudo -u macf-runner bash -c 'cd /opt/macf-runner/actions-runner && ./run.sh'

# NOTE (multi-repo refinement): install-runner.sh currently uses ONE runner dir
# (/opt/macf-runner/actions-runner). Serving MULTIPLE repos from one VM needs a per-repo
# dir (e.g. actions-runner-<slug>) + a per-repo systemd instance. The registry (runners.yaml)
# + verify already support N; the install/up paths get per-repo dirs when we add the 2nd runner.
