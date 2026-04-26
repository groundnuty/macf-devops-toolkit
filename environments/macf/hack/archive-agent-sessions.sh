#!/usr/bin/env bash
# Archive substrate-agent session JSONLs (per #33).
#
# Claude Code stores per-conversation transcripts at:
#   ~/.claude/projects/<encoded-project-path>/<session-uuid>.jsonl
#
# These files are durable + append-only on disk: Claude Code keeps
# appending to the SAME UUID across compactions. So the JSONL IS the
# canonical pre-compact archive — every turn the agent has had since
# the conversation started.
#
# Per DR-002 §"The 900k context as observability artifact" + operator's
# 2026-04-26 design call: substrate agents archive these JSONLs to a
# flat layout (separate from per-issue observability bundles); update
# mechanism is a periodic `cp` because the source is append-only on
# disk → re-copy is idempotent + always reflects the latest growth.
#
# Layout in the destination:
#   <out-dir>/sessions/<agent-name>/<session-uuid>.jsonl
#
# This script does NOT push to a remote (e.g. macf-observability-archive
# repo). The caller (a cron / systemd timer / GitHub Action workflow)
# wraps the push step. Keeping the script transport-agnostic lets the
# scheduling decision (which the issue defers) stay separate from the
# data-layout decision (which is fixed by this script).
#
# Testers deferred per #33 body — substrate agents only.

set -euo pipefail

OUT_DIR="${OUT_DIR:-/tmp/agent-archive}"
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/.claude/projects}"

# Map known substrate-agent project-dir paths → canonical agent names.
# The encoded-path scheme is `-Users-...repos-groundnuty-<repo>`; matching
# on the trailing repo name avoids hardcoding the operator's filesystem
# layout (e.g. /Users/orzech/Dropbox/... on this VM).
declare -A AGENT_FOR_REPO=(
  [macf-devops-toolkit]="macf-devops-agent"
  [macf-science-agent]="macf-science-agent"
  [macf]="macf-code-agent"
)

mkdir -p "$OUT_DIR/sessions"

ARCHIVED=0
SKIPPED=0

for proj_dir in "$PROJECTS_DIR"/-*; do
  [ -d "$proj_dir" ] || continue
  base=$(basename "$proj_dir")

  # Find which substrate agent this directory belongs to (if any).
  agent=""
  for repo in "${!AGENT_FOR_REPO[@]}"; do
    if [[ "$base" == *"groundnuty-$repo" ]]; then
      agent="${AGENT_FOR_REPO[$repo]}"
      break
    fi
  done
  if [ -z "$agent" ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  dest="$OUT_DIR/sessions/$agent"
  mkdir -p "$dest"

  # Copy each top-level session JSONL (one file per session UUID).
  # Subagent JSONLs (under <uuid>/subagents/) are deliberately not
  # archived per #33 body; revisit if size analysis proves valuable.
  shopt -s nullglob
  for jsonl in "$proj_dir"/*.jsonl; do
    cp -p "$jsonl" "$dest/$(basename "$jsonl")"
    ARCHIVED=$((ARCHIVED + 1))
  done
  shopt -u nullglob
done

echo "OK archived $ARCHIVED session JSONL(s) to $OUT_DIR/sessions/ ($SKIPPED non-substrate dirs skipped)"

# Manifest: a tiny JSON file in the archive root recording when this
# run happened + what was captured. Useful for diff-based "what
# changed since last archive" reporting if we ever wire one.
cat > "$OUT_DIR/archive-manifest.json" <<MANIFEST
{
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": "$(hostname)",
  "archived_count": $ARCHIVED,
  "skipped_dirs": $SKIPPED,
  "sessions": [
$(find "$OUT_DIR/sessions" -name '*.jsonl' -type f | while read f; do
    uuid=$(basename "$f" .jsonl)
    agent=$(basename "$(dirname "$f")")
    size=$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null)
    mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
    echo "    {\"agent\": \"$agent\", \"session_uuid\": \"$uuid\", \"bytes\": $size, \"mtime_unix\": $mtime},"
  done | sed '$ s/,$//')
  ]
}
MANIFEST

echo "  manifest: $OUT_DIR/archive-manifest.json"
