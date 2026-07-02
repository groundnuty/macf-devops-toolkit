# runner/Makefile — operate + document the self-hosted runners we manage (devops-toolkit#90).
#
# SINGLE SOURCE OF TRUTH = runners.yaml. This Makefile GENERATES a target per entry:
#   make runner-<name>   — reconcile ONE runner (verify → prompt-install-if-unhealthy → verify)
#   make fleet-<name>    — reconcile every runner in that fleet (depends on its runner-* targets)
# via $(foreach)+$(eval) reading runners.yaml — NOTHING hardcoded. Add a runner = one YAML
# entry → its target appears.
#
# Needs yq (mikefarah v4) + jq. Self-contained devbox: `cd runner && devbox shell` (see
# devbox.json) pins both + gh + working tab-completion for these generated targets
# (make-completion.zsh / make-completion.bash, loaded by devbox's shell.init_hook — see
# RUNNER.md). The generic "read the make database" completion approaches (bash-completion's
# default, or zsh's `zstyle ':completion:*:make:*:targets' call-command true`) do NOT work
# here because these targets are $(shell)-generated at parse time, not static rules — with
# no completion script bound, they silently fall back to filename completion instead
# (e.g. `uninstall-runner.sh` polluting `make uninstall-<TAB>`). The $(error) guard below
# converts the same yq/jq-missing condition from "silently generate zero targets" into a
# loud, actionable failure.
# Extraction goes yq→json→jq (portable string-shaping vs mikefarah-yq's differing syntax).
YQ  ?= yq
JQ  ?= jq

# Fail LOUD, not silently-empty: without yq/jq, $(shell $(YQ) ... | $(JQ) ...) below returns
# "" for BOTH $(RUNNERS) and $(FLEETS) — every generated runner-*/uninstall-*/reinstall-*/
# fleet-* target simply never gets $(eval)'d, and `make <that-target>` fails with a bare
# "No rule to make target" that gives no hint why. Assert the real precondition instead.
ifeq ($(shell command -v $(YQ) 2>/dev/null),)
$(error yq (mikefarah v4) not found on PATH -- runner/Makefile generates its runner-*/fleet-*/uninstall-*/reinstall-* targets from runners.yaml via yq+jq, so without yq every one of those targets silently fails to exist ("No rule to make target"). Fix: run inside the runner devbox -- `cd runner && devbox shell` (pins yq/jq/gh + working tab-completion, see RUNNER.md) -- or one-off from the repo root: `devbox run --config runner -- make <target>`)
endif
ifeq ($(shell command -v $(JQ) 2>/dev/null),)
$(error jq not found on PATH -- same fix as the yq guard above: `cd runner && devbox shell`, or `devbox run --config runner -- make <target>` from the repo root)
endif

REG := runners.yaml
J   := $(YQ) -o=json $(REG) | $(JQ) -r
RUNNERS := $(shell $(YQ) -o=json $(REG) 2>/dev/null | $(JQ) -r '.fleets[].runners[].name' 2>/dev/null)
FLEETS  := $(shell $(YQ) -o=json $(REG) 2>/dev/null | $(JQ) -r '.fleets[].name' 2>/dev/null)

# MULTI-RUNNER-PER-HOST: each runner installs isolated under
# $(MACF_RUNNER_BASE)/<name> on the big volume (root disk is 84% full), sharing ONE
# action-archive-cache + the ONE macf-runner OS user across all runners. `?=` picks up an
# operator-exported MACF_RUNNER_BASE the same way reconcile-runner.sh's bash
# `${MACF_RUNNER_BASE:-...}` does, so the two stay in lockstep without hardcoding twice.
# `runner-<name>`/`reinstall-<name>` compute this INSIDE reconcile-runner.sh (it has
# --name); `uninstall-<name>` below calls uninstall-runner.sh DIRECTLY (bypassing
# reconcile), so it threads the same formula here — the one unavoidable duplication.
MACF_RUNNER_BASE ?= /mnt/volume1/macf-runners
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

# uninstall-<name>: tear down ONE runner (stop+remove svc.sh service + Restart drop-in +
# de-register from GitHub). Repo resolved from runners.yaml; prompts for the remove-token.
# Threads MACF_RUNNER_DIR = $(MACF_RUNNER_BASE)/<name>/actions-runner — the ONLY per-runner
# path uninstall-runner.sh actually consumes — via `sudo env VAR=val cmd`, not `sudo -E`:
# sudo resets the environment by default (env_reset) and honoring -E depends on sudoers
# policy the operator's shell may not have; `env VAR=val` is an explicit assignment to the
# child, unaffected by that policy. This target calls uninstall-runner.sh DIRECTLY (not via
# reconcile-runner.sh, which has --name and computes the same path internally) — see the
# MACF_RUNNER_BASE comment above for why the formula is duplicated here.
define _uninstall_rule
uninstall-$(1): ; sudo env MACF_RUNNER_DIR=$(MACF_RUNNER_BASE)/$(1)/actions-runner ./uninstall-runner.sh --repo $(shell $(YQ) -o=json $(REG) 2>/dev/null | $(JQ) -r '.fleets[].runners[]|select(.name=="$(1)").repo' 2>/dev/null)
endef
$(foreach r,$(RUNNERS),$(eval $(call _uninstall_rule,$(r))))

# reinstall-<name>: dogfood the full lifecycle — uninstall then FORCE install (devops-toolkit
# reinstall-skips-install bug, 2026-07-02). MUST NOT depend on runner-$(1) (the plain
# verify-gated reconcile target): a just-uninstalled runner run through verify-runner.sh
# WITHOUT sudo can read back as "healthy" (root-only checks silently [skip] instead of
# [FAIL]), so runner-$(1) would see "already healthy; nothing to do" and skip the install —
# leaving the runner torn down + de-registered while the echo below lies "re-registered".
# --force (reconcile-runner.sh) removes exactly that health-check bypass; the install step
# always runs after the uninstall prerequisite.
define _reinstall_rule
reinstall-$(1): uninstall-$(1)
	@./reconcile-runner.sh --name $(1) --force
	@echo "reinstall $(1): torn down + re-registered."
endef
$(foreach r,$(RUNNERS),$(eval $(call _reinstall_rule,$(r))))

##@ Generic mechanism (rarely called directly — the generated targets use these)

.PHONY: setup-user
setup-user:  ## Create the low-priv macf-runner user + send-helper sudoers rule (once per VM; sudo)
	sudo bash ./setup-macf-runner-user.sh

.PHONY: copy-vars
copy-vars:  ## Copy a fleet's shared vars from its var_source to a repo (REPO=owner/repo FLEET=macf)
	@[ -n "$(REPO)" ] && [ -n "$(FLEET)" ] || { echo "set REPO=owner/repo FLEET=<name>"; exit 2; }
	@./copy-vars.sh --to "$(REPO)" --fleet "$(FLEET)"
