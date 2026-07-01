# runner/Makefile — operate + document the self-hosted runners we manage (devops-toolkit#90).
#
# SINGLE SOURCE OF TRUTH = runners.yaml. This Makefile GENERATES a target per entry:
#   make runner-<name>   — reconcile ONE runner (verify → prompt-install-if-unhealthy → verify)
#   make fleet-<name>    — reconcile every runner in that fleet (depends on its runner-* targets)
# via $(foreach)+$(eval) reading runners.yaml — NOTHING hardcoded. Add a runner = one YAML
# entry → its target appears (+ tab-completes, on any make-completion that reads the make
# DATABASE: bash-completion's default, or zsh with
# `zstyle ':completion:*:make:*:targets' call-command true` — config, not a custom script).
#
# Needs yq (mikefarah v4) + jq (devbox provides both): `devbox run -- make -C runner <target>`.
# Extraction goes yq→json→jq (portable string-shaping vs mikefarah-yq's differing syntax).
YQ  ?= yq
JQ  ?= jq
REG := runners.yaml
J   := $(YQ) -o=json $(REG) | $(JQ) -r
RUNNERS := $(shell $(YQ) -o=json $(REG) 2>/dev/null | $(JQ) -r '.fleets[].runners[].name' 2>/dev/null)
FLEETS  := $(shell $(YQ) -o=json $(REG) 2>/dev/null | $(JQ) -r '.fleets[].name' 2>/dev/null)
.DEFAULT_GOAL := help

.PHONY: help
help:  ## Show targets (+ the generated runner-*/fleet-* below)
	@awk 'BEGIN{FS=":.*## "} /^##@ /{printf "\n\033[1m%s\033[0m\n",substr($$0,5)} /^[a-zA-Z_-]+:.*## /{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@printf "\n\033[1mGenerated from runners.yaml\033[0m\n"
	@for r in $(RUNNERS); do printf "  \033[36mrunner-%-18s\033[0m reconcile that runner\n" "$$r"; done
	@for f in $(FLEETS);  do printf "  \033[36mfleet-%-19s\033[0m reconcile that fleet\n" "$$f"; done

##@ Registry (reads runners.yaml)

.PHONY: runners
runners:  ## Document the registry — fleets → runners → status
	@$(J) '.fleets[] | "fleet: \(.name)  (registry \(.registry), var_source \(.var_source))", (.runners[] | "  - \(.name)  \(.repo)  [\(.visibility)] \(.status)  — \(.note)")'

.PHONY: verify-all
verify-all:  ## Health-check EVERY runner (read-only; no install prompts)
	@$(J) '.fleets[].runners[].name' | while read -r n; do echo "== $$n =="; ./reconcile-runner.sh --name "$$n" --verify-only || true; echo; done

##@ Generated per-runner / per-fleet targets (from runners.yaml — see `make help`)

# runner-<name>: reconcile ONE runner (verify → prompt-install → verify).
$(foreach r,$(RUNNERS),$(eval runner-$(r): ; @./reconcile-runner.sh --name $(r)))

# fleet-<name>: reconcile every runner in the fleet — depend on its runner-* targets
# (make-idiomatic; no shell-loop escaping). Deps computed per-fleet from the yaml.
define _fleet_rule
fleet-$(1): $(addprefix runner-,$(shell $(YQ) -o=json $(REG) 2>/dev/null | $(JQ) -r '.fleets[]|select(.name=="$(1)").runners[].name' 2>/dev/null))
	@echo "fleet $(1): all runners reconciled."
endef
$(foreach f,$(FLEETS),$(eval $(call _fleet_rule,$(f))))

##@ Generic mechanism (rarely called directly — the generated targets use these)

.PHONY: setup-user
setup-user:  ## Create the low-priv macf-runner user + send-helper sudoers rule (once per VM; sudo)
	sudo bash ./setup-macf-runner-user.sh

.PHONY: copy-vars
copy-vars:  ## Copy a fleet's shared vars from its var_source to a repo (REPO=owner/repo FLEET=macf)
	@[ -n "$(REPO)" ] && [ -n "$(FLEET)" ] || { echo "set REPO=owner/repo FLEET=<name>"; exit 2; }
	@./copy-vars.sh --to "$(REPO)" --fleet "$(FLEET)"
