# runner/make-completion.bash — tab-completion for `make` bound to the RUNNER
# TARGET NAMES generated from runners.yaml (devops-toolkit#90 make-ergonomics
# follow-up). Bash sibling of make-completion.zsh — see that file's header
# comment for the full root-cause writeup (generated make targets aren't
# introspectable by generic completers, which silently fall back to filename
# completion — e.g. `uninstall-runner.sh` polluting `uninstall-<TAB>`).
#
# Sourced ONLY inside the runner/ devbox shell (via devbox.json's
# shell.init_hook) — scoped to that subshell, not installed into the user's
# global bash config. Safe to source by hand too: `. runner/make-completion.bash`.

# Capture this file's own directory AT SOURCE TIME via BASH_SOURCE (stable
# even once referenced later from inside a function) — this is where
# Makefile + runners.yaml live, so completion works regardless of $PWD when
# `make` is invoked, and regardless of how this file was sourced (devbox
# init_hook with an absolute path, or a manual `.` from anywhere).
_RUNNER_MAKE_COMPLETION_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

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
    local json r f
    json="$(yq -o=json "$dir/runners.yaml" 2>/dev/null)"
    if [[ -n "$json" ]]; then
      while IFS= read -r r; do
        [[ -n "$r" ]] && printf 'runner-%s\nuninstall-%s\nreinstall-%s\n' "$r" "$r" "$r"
      done < <(printf '%s' "$json" | jq -r '.fleets[].runners[].name' 2>/dev/null)
      while IFS= read -r f; do
        [[ -n "$f" ]] && printf 'fleet-%s\n' "$f"
      done < <(printf '%s' "$json" | jq -r '.fleets[].name' 2>/dev/null)
    fi
  fi
}

# The completer itself — offers ONLY the target names above via COMPREPLY.
# Deliberately NOT registered with `-o default`/`-o bashdefault`, so an empty
# COMPREPLY does not fall through to filename completion (the bug this file
# fixes — e.g. `uninstall-runner.sh` polluting `uninstall-<TAB>`).
_runner_make_complete() {
  local cur targets
  cur="${COMP_WORDS[COMP_CWORD]}"
  targets="$(_runner_make_target_names)"
  COMPREPLY=($(compgen -W "$targets" -- "$cur"))
}

complete -F _runner_make_complete make
