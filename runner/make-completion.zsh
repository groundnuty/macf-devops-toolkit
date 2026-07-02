# runner/make-completion.zsh — tab-completion for `make` bound to the RUNNER TARGET
# NAMES generated from runners.yaml (devops-toolkit#90 make-ergonomics follow-up).
#
# Problem this fixes: runner/Makefile's `runner-<name>` / `uninstall-<name>` /
# `reinstall-<name>` / `fleet-<name>` targets are generated at parse time via
# $(shell yq ... | jq ...) — a make VARIABLE, not a static rule — so zsh's generic
# `_make` completer (even with `zstyle ':completion:*:make:*:targets' call-command
# true`) has nothing reliable to introspect and silently falls back to FILENAME
# completion, offering noise like `uninstall-runner.sh` on `make uninstall-<TAB>`.
#
# Fix: complete directly against the target names derived the same way the
# Makefile derives them (yq -o=json runners.yaml | jq), plus the Makefile's own
# self-documenting `target:  ## comment` targets — and bind that completer
# directly to `make`, so filename completion never runs for this command.
#
# Sourced ONLY inside the runner/ devbox shell (via devbox.json's
# shell.init_hook) — scoped to that subshell, not installed into the user's
# global zsh config. Safe to source by hand too: `. runner/make-completion.zsh`.

# Capture this file's own directory AT SOURCE TIME (not inside the completion
# function, where $0/%x would no longer point here) — this is where
# Makefile + runners.yaml live, so completion works regardless of $PWD when
# `make` is invoked, and regardless of how this file was sourced (devbox
# init_hook with an absolute path, or a manual `.` from anywhere).
_RUNNER_MAKE_COMPLETION_DIR="${${(%):-%x}:A:h}"

# Emit one candidate target name per line: (1) grep the Makefile for its own
# `name:  ## comment` self-documenting targets, (2) if yq+jq are available and
# runners.yaml parses, add the generated runner-*/uninstall-*/reinstall-*
# (per runner) and fleet-* (per fleet) names — same derivation the Makefile
# itself uses (RUNNERS/FLEETS via `yq -o=json | jq -r`). Resilient: any
# missing file or failed parse just yields fewer/no dynamic candidates rather
# than erroring — completion never blocks on a broken registry.
_runner_make_target_names() {
  local dir="$_RUNNER_MAKE_COMPLETION_DIR"
  [[ -n "$dir" && -f "$dir/Makefile" ]] || return 0

  grep -oE '^[a-zA-Z0-9_-]+:.*##' "$dir/Makefile" 2>/dev/null | sed -E 's/:.*//'

  if command -v yq >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [[ -f "$dir/runners.yaml" ]]; then
    local json
    json="$(yq -o=json "$dir/runners.yaml" 2>/dev/null)"
    if [[ -n "$json" ]]; then
      local r f
      print -r -- "$json" | jq -r '.fleets[].runners[].name' 2>/dev/null | while IFS= read -r r; do
        [[ -n "$r" ]] && printf 'runner-%s\nuninstall-%s\nreinstall-%s\n' "$r" "$r" "$r"
      done
      print -r -- "$json" | jq -r '.fleets[].name' 2>/dev/null | while IFS= read -r f; do
        [[ -n "$f" ]] && printf 'fleet-%s\n' "$f"
      done
    fi
  fi
}

# The completer itself — offers ONLY the target names above (never falls
# through to filename completion, which is the bug this file fixes).
_runner_make() {
  local -a targets
  targets=(${(f)"$(_runner_make_target_names)"})
  (( ${#targets[@]} == 0 )) && return 0
  _describe -t runner-make-targets 'runner make target' targets
}

# `compdef` (and `_describe`) only exist once zsh's completion system has been
# bootstrapped via `compinit`. Interactively this has virtually always already
# happened by the time devbox's shell.init_hook runs (compinit is standard in
# almost every zshrc, and devbox layers its hook on top of the user's existing
# shell config rather than replacing it) — but a devbox shell invoked
# non-interactively, or from a minimal/no-rc environment, may reach this point
# with no completion system loaded yet. Guard defensively rather than assume:
# only pay the (idempotent, `-C`-fast) compinit cost when compdef isn't
# already defined, so the common case is a zero-overhead no-op.
if (( ! ${+functions[compdef]} )); then
  autoload -Uz compinit 2>/dev/null && compinit -C 2>/dev/null
fi
(( ${+functions[compdef]} )) && compdef _runner_make make
