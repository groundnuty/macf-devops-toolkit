#!/usr/bin/env bash
# Archive agent session JSONLs (per #33, extended for testers per #47).
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
# 2026-04-26 design call: agents archive these JSONLs to a flat layout
# (separate from per-issue observability bundles); update mechanism is
# a periodic `cp` because the source is append-only on disk → re-copy
# is idempotent + always reflects the latest growth.
#
# Scope: substrate agents (devops, science, code) AND testers (1..N).
# Tester JSONLs may contain content that OTLP redacts when
# OTEL_LOG_USER_PROMPTS / RAW_API_BODIES are off — same threat model
# as devops-toolkit#32 stage 2+ and testbed#73 rollout. Treat archive
# privacy accordingly.
#
# Layout in the destination:
#   <out-dir>/sessions/<agent-name>/<session-uuid>.jsonl
#
# This script does NOT push to a remote (e.g. macf-observability-archive
# repo). The caller (a cron / systemd timer / GitHub Action workflow)
# wraps the push step. Keeping the script transport-agnostic lets the
# scheduling decision (which the issue defers) stay separate from the
# data-layout decision (which is fixed by this script).

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

# Resolve a project-dir basename to a canonical agent name. Returns
# empty string if the directory belongs to neither a known substrate
# nor a tester home.
#
# Tester home convention: project dirs encode `/home/ubuntu/tester-N-home`
# as `-home-ubuntu-tester-N-home`. Regex captures the digit suffix, so
# adding tester-5/6/... requires no edit here.
resolve_agent() {
  local base=$1
  for repo in "${!AGENT_FOR_REPO[@]}"; do
    if [[ "$base" == *"groundnuty-$repo" ]]; then
      echo "${AGENT_FOR_REPO[$repo]}"
      return
    fi
  done
  if [[ "$base" =~ -home-ubuntu-tester-([0-9]+)-home$ ]]; then
    echo "macf-tester-${BASH_REMATCH[1]}-agent"
    return
  fi
}

# Resolve a tester project-dir basename to its $HOME / workspace path.
# `=file:<dir>` mode for OTEL_LOG_RAW_API_BODIES (per #50) writes
# untruncated request + response bodies to disk under that dir; we use
# `$HOME/.claude/api-bodies/` so each tester's bodies live alongside
# its session JSONLs and inherit the same per-tester $HOME isolation.
#
# Substrate agents share one $HOME on the host (the operator's user dir)
# so attribution-per-substrate from a shared api-bodies/ dir is
# ambiguous; deferred until substrate-side =file: rolls out + we decide
# on a per-session-uuid sub-layout. Returns empty for substrates here.
resolve_tester_home() {
  local base=$1
  if [[ "$base" =~ -home-ubuntu-tester-([0-9]+)-home$ ]]; then
    echo "/home/ubuntu/tester-${BASH_REMATCH[1]}-home"
    return
  fi
}

mkdir -p "$OUT_DIR/sessions"

ARCHIVED=0
SKIPPED=0

for proj_dir in "$PROJECTS_DIR"/-*; do
  [ -d "$proj_dir" ] || continue
  base=$(basename "$proj_dir")

  agent=$(resolve_agent "$base")
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

# Tester api-bodies archive (per #50). `OTEL_LOG_RAW_API_BODIES=file:$HOME/.claude/api-bodies/`
# writes untruncated request + response bodies to disk; archive them
# alongside the session JSONLs so per-issue / per-scenario bundles can
# reference full input-context content for paper-evidence-grade analysis.
# (Default OTLP `=1` mode caps at 60 KB inline — request bodies hit the
# cap empirically on testbed#73 verification, motivating this path.)
API_BODIES_ARCHIVED=0
for proj_dir in "$PROJECTS_DIR"/-*; do
  [ -d "$proj_dir" ] || continue
  base=$(basename "$proj_dir")
  agent=$(resolve_agent "$base")
  [ -z "$agent" ] && continue

  tester_home=$(resolve_tester_home "$base")
  [ -z "$tester_home" ] && continue   # substrate: api-bodies attribution deferred

  api_dir="$tester_home/.claude/api-bodies"
  [ -d "$api_dir" ] || continue

  dest="$OUT_DIR/api-bodies/$agent"
  mkdir -p "$dest"
  # Preserve internal structure (Claude Code may organize by session-uuid
  # subdirs). cp -rp keeps mtimes; trailing /. copies dir contents not the
  # dir itself.
  cp -rp "$api_dir/." "$dest/" 2>/dev/null || true
  count=$(find "$dest" -type f 2>/dev/null | wc -l)
  API_BODIES_ARCHIVED=$((API_BODIES_ARCHIVED + count))
done
# Total bytes across all archived api-bodies — paired with count so
# operators can spot whether capture is functioning at expected scale
# (e.g., 100 files × <1 KB might indicate truncation/error vs healthy
# 100 × ~60 KB). Per science-agent design note on #50.
API_BODIES_TOTAL_BYTES=0
if [ -d "$OUT_DIR/api-bodies" ]; then
  API_BODIES_TOTAL_BYTES=$(find "$OUT_DIR/api-bodies" -type f -exec stat -c '%s' {} \; 2>/dev/null | awk '{s+=$1} END {print s+0}')
fi
if [ "$API_BODIES_ARCHIVED" -gt 0 ]; then
  echo "OK archived $API_BODIES_ARCHIVED api-body file(s) (${API_BODIES_TOTAL_BYTES} bytes) to $OUT_DIR/api-bodies/"
else
  echo "(no api-bodies on disk yet — sister testbed-side claude.sh edit pending)"
fi

# Manifest: a tiny JSON file in the archive root recording when this
# run happened + what was captured. Useful for diff-based "what
# changed since last archive" reporting if we ever wire one.
cat > "$OUT_DIR/archive-manifest.json" <<MANIFEST
{
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": "$(hostname)",
  "archived_count": $ARCHIVED,
  "api_bodies_archived_count": $API_BODIES_ARCHIVED,
  "api_bodies_total_bytes": $API_BODIES_TOTAL_BYTES,
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
