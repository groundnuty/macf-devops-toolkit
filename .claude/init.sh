#!/usr/bin/env bash
#
# .claude/init.sh — apply a profile overlay to the base template.
#
# Usage: ./.claude/init.sh <info|research|paper|paper-latex|code> [--keep-profiles] [--dry-run]
#
# Deep-merges profiles/<profile>/settings.overlay.json into .claude/settings.json,
# copies rule files and skill dirs, appends CLAUDE.append.md to .claude/CLAUDE.md,
# merges skills.manifest.json entries, then removes profiles/ and init.sh.

set -eu

VALID_PROFILES=(info research paper paper-latex code)
JQ="${JQ:-jq}"
TEMPLATE_VERSION="v0.1.12"

usage() {
  cat <<EOF
Usage: ./.claude/init.sh <info|research|paper|paper-latex|code> [--keep-profiles] [--dry-run]

Applies a profile overlay to the base .claude/ tree.

Profiles:
  info         Pure information work — reports, document analysis, no code.
  research     Technical research — reading docs, light code analysis, no code writing.
  paper        Academic paper / manuscript writing — prose polishing, peer review,
               format-agnostic (works for LaTeX, Markdown, Word, Google Docs).
  paper-latex  Paper + LaTeX / BibTeX / TikZ layer. Apply when compiling with LaTeX.
  code         Code-centric work — Makefile/devbox/testing conventions.

Options:
  --keep-profiles  Do not delete .claude/profiles/ and this script after apply.
  --dry-run        Print what would be done without mutating files.
EOF
}

is_valid_profile() {
  local candidate="$1"
  for p in "${VALID_PROFILES[@]}"; do
    [ "$p" = "$candidate" ] && return 0
  done
  return 1
}

resolve_chain() {
  local profile="$1"
  case "$profile" in
    info)     echo "info" ;;
    research) echo "info research" ;;
    paper)    echo "info research paper" ;;
    paper-latex) echo "info research paper paper-latex" ;;
    code)     echo "info code" ;;
    *)        echo "unknown" ; return 1 ;;
  esac
}

preflight() {
  if ! command -v "$JQ" >/dev/null 2>&1; then
    echo "error: jq not found on PATH (looked for '$JQ'). Install jq and re-run." >&2
    exit 3
  fi
  if [ ! -f .claude/settings.json ]; then
    echo "error: .claude/settings.json missing. Is this the template root?" >&2
    exit 4
  fi
  if [ ! -d .claude/profiles ]; then
    echo "error: .claude/profiles/ missing. Has init.sh already been run?" >&2
    exit 4
  fi
}

apply_settings_overlay() {
  local profile_dir="$1"
  local overlay="$profile_dir/settings.overlay.json"
  [ -f "$overlay" ] || return 0

  local settings=".claude/settings.json"
  local tmp
  tmp=$(mktemp)

  # Deep-merge: arrays concatenate, objects merge recursively.
  "$JQ" --slurpfile overlay "$overlay" '
    def deep_merge(b):
      if (type == "object") and (b | type == "object")
      then reduce (b | keys_unsorted[]) as $k
             (.; .[$k] = (if (.[$k] | type) == "array" and (b[$k] | type) == "array"
                          then .[$k] + b[$k]
                          elif (.[$k] | type) == "object" and (b[$k] | type) == "object"
                          then .[$k] | deep_merge(b[$k])
                          else b[$k] end))
      else b end;
    deep_merge($overlay[0])
  ' "$settings" > "$tmp"

  mv "$tmp" "$settings"
}

copy_profile_content() {
  local profile_dir="$1"
  # Copy any of: rules/, skills/, agents/, hooks/, templates/ that exist in the profile.
  for subdir in rules skills agents hooks templates; do
    if [ -d "$profile_dir/$subdir" ]; then
      mkdir -p ".claude/$subdir"
      cp -R "$profile_dir/$subdir/." ".claude/$subdir/"
    fi
  done
}

# Kept for backward-compat with older test expectations.
copy_rules_and_skills() {
  copy_profile_content "$1"
}

append_claude_md() {
  local profile_dir="$1"
  local snippet="$profile_dir/CLAUDE.append.md"
  [ -f "$snippet" ] || return 0
  { echo; cat "$snippet"; } >> .claude/CLAUDE.md
}

merge_skills_manifest() {
  local profile_dir="$1"
  local src="$profile_dir/skills.manifest.json"
  [ -f "$src" ] || return 0
  local dest=".claude/skills.manifest.json"
  [ -f "$dest" ] || echo '{"skills": []}' > "$dest"
  local tmp
  tmp=$(mktemp)
  "$JQ" -s '{ skills: (.[0].skills + .[1].skills) }' "$dest" "$src" > "$tmp"
  mv "$tmp" "$dest"
}

cleanup_template_metadata() {
  # Remove/reset root-level files that are template metadata, not user content.
  # These are present because GitHub's "Use this template" copies them from the
  # template repo's default branch; they document the template itself, not the
  # consuming project.

  # README.md: replace with a minimal stub carrying the repo name.
  # LICENSE, .gitignore, and the root CLAUDE.md stub are kept — all reasonable
  # starting points the user can keep or replace.
  if [ -f README.md ] && head -1 README.md | grep -q '^# agentic-repo-template'; then
    local repo_name
    repo_name=$(basename "$(pwd)")
    printf '# %s\n' "$repo_name" > README.md
  fi

  # CHANGELOG.md: template release history is not relevant to the consuming
  # project. Delete if it looks like our template CHANGELOG.
  if [ -f CHANGELOG.md ] && head -5 CHANGELOG.md | grep -q 'User-facing history of this template'; then
    rm -f CHANGELOG.md
  fi
}

stamp_template_version() {
  # Record which template version/profile was applied so /template-check can
  # compare against the latest GitHub release later.
  local applied_at profile="$1"
  applied_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat > .claude/.template-version <<EOF
version=${TEMPLATE_VERSION}
profile=${profile}
applied_at=${applied_at}
EOF
}

self_delete() {
  rm -rf .claude/profiles
  rm -f  .claude/init.sh
}

main() {
  local profile=""
  local keep_profiles=0
  local dry_run=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-profiles) keep_profiles=1; shift ;;
      --dry-run)       dry_run=1; shift ;;
      -h|--help)       usage; exit 0 ;;
      -*)              echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
      *)
        if [ -z "$profile" ]; then
          profile="$1"; shift
        else
          echo "unexpected argument: $1" >&2; usage >&2; exit 2
        fi
        ;;
    esac
  done

  if [ -z "$profile" ]; then
    echo "error: profile argument required" >&2
    usage >&2
    exit 2
  fi

  if ! is_valid_profile "$profile"; then
    echo "unknown profile: $profile" >&2
    usage >&2
    exit 2
  fi

  local chain
  chain=$(resolve_chain "$profile")

  # Debug hook for testing chain resolution.
  if [ "${DEBUG_PRINT_CHAIN:-0}" = "1" ]; then
    echo "$chain"
    exit 0
  fi

  preflight

  for p in $chain; do
    profile_dir=".claude/profiles/$p"
    [ -d "$profile_dir" ] || { echo "profile dir missing: $profile_dir" >&2; exit 4; }

    if [ "$dry_run" = "1" ]; then
      echo "[dry-run] would merge $profile_dir/settings.overlay.json"
      echo "[dry-run] would copy $profile_dir/rules/ and $profile_dir/skills/"
      echo "[dry-run] would append $profile_dir/CLAUDE.append.md"
      echo "[dry-run] would merge $profile_dir/skills.manifest.json"
      continue
    fi

    apply_settings_overlay "$profile_dir"
    copy_rules_and_skills "$profile_dir"
    append_claude_md "$profile_dir"
    merge_skills_manifest "$profile_dir"
  done

  if [ "$dry_run" = "0" ]; then
    cleanup_template_metadata
    stamp_template_version "$profile"
  fi

  if [ "$dry_run" = "0" ] && [ "$keep_profiles" = "0" ]; then
    self_delete
  fi

  if [ "$dry_run" = "0" ]; then
    echo
    echo "Profile \"$profile\" applied."
    echo "  Chain: $chain"
    echo "  Plugins enabled: $("$JQ" -r '.enabledPlugins | length' .claude/settings.json)"
    echo "  Rules present:   $(find .claude/rules -name '*.md' -type f | wc -l | tr -d ' ')"
    if [ -d .claude/skills ]; then
      echo "  Skills vendored: $(find .claude/skills -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
    fi
    if [ -d .claude/agents ]; then
      echo "  Agents present:  $(find .claude/agents -maxdepth 1 -mindepth 1 -type f -name '*.md' | wc -l | tr -d ' ')"
    fi
    if [ -d .claude/hooks ]; then
      echo "  Hook scripts:    $(find .claude/hooks -maxdepth 1 -mindepth 1 -type f | wc -l | tr -d ' ')"
    fi
    if [ -d .claude/templates ]; then
      echo "  Templates:       $(find .claude/templates -maxdepth 1 -mindepth 1 -type f -name '*.md' | wc -l | tr -d ' ')"
    fi
    if [ "$keep_profiles" = "1" ]; then
      echo "  profiles/ and init.sh retained (--keep-profiles)."
    else
      echo "  profiles/ and init.sh removed (self-cleaned)."
    fi
  fi
}

main "$@"
