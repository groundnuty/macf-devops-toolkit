#!/bin/bash
# Launcher for macf-devops-agent
# Generates a GitHub App token, starts tmux session, boots Claude Code.
#
# Requires:
#   - .claude/settings.local.json with env.APP_ID, env.INSTALL_ID, env.KEY_PATH
#   - .github-app-key.pem (or whatever KEY_PATH points to)
#   - gh CLI installed (invoked inside macf-gh-token.sh)
#   - jq, tmux, claude

set -euo pipefail

if [ -d /home/linuxbrew/.linuxbrew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$DIR/.claude/settings.local.json"

if [ ! -f "$SETTINGS" ]; then
  echo "error: $SETTINGS not found" >&2
  echo "copy .claude/settings.local.json.example and fill in APP_ID / INSTALL_ID" >&2
  exit 1
fi

APP_ID=$(jq -r '.env.APP_ID' "$SETTINGS")
INSTALL_ID=$(jq -r '.env.INSTALL_ID' "$SETTINGS")
KEY_PATH=$(jq -r '.env.KEY_PATH' "$SETTINGS")

if [ "$APP_ID" = "null" ] || [ "$INSTALL_ID" = "null" ] || [ "$KEY_PATH" = "null" ]; then
  echo "error: APP_ID / INSTALL_ID / KEY_PATH missing in $SETTINGS" >&2
  exit 1
fi

ABS_KEY="$DIR/$KEY_PATH"
if [ ! -f "$ABS_KEY" ]; then
  echo "error: private key not found at $ABS_KEY" >&2
  exit 1
fi

# Fail-loud token generation — the naive `export GH_TOKEN=$(gh token
# generate ... | jq)` silently swallows errors (no pipefail), making
# `GH_TOKEN` the string "null" and letting `gh` fall back to stored
# user auth. This is the attribution trap (see coordination.md Token
# & Git Hygiene). The canonical helper surfaces failures.
GH_TOKEN=$("$DIR/.claude/scripts/macf-gh-token.sh" \
  --app-id "$APP_ID" --install-id "$INSTALL_ID" --key "$ABS_KEY") || {
  echo "FATAL: bot token generation failed — see stderr above." >&2
  exit 1
}

SESSION="devops-agent"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "session '$SESSION' already exists. attach with: tmux attach -t $SESSION" >&2
  exit 0
fi

# --- OTLP telemetry (refs #24) ---------------------------------------------
# Wires Claude Code's built-in OpenTelemetry support so every conversation
# emits traces (per tool call), metrics (token counts, model usage), and
# logs into the cluster's stable OTLP ingress at :14318.
#
# `${VAR=default}` assigns ONLY if VAR is unset — empty stays empty, so an
# operator can opt out of telemetry for one session via:
#   CLAUDE_CODE_ENABLE_TELEMETRY= ./claude.sh
# Or override the endpoint to point elsewhere (e.g., a CI collector):
#   OTEL_EXPORTER_OTLP_ENDPOINT=http://collector.ci:4318 ./claude.sh
#
# `agent.id` + `agent.role` are the load-bearing paper-dim resource attrs.
# The Collector's `resource/paper-dims` processor (in env macf) does NOT
# default these — agents that fail to stamp them are visibly absent in
# queries (fail-loud-on-absent), which is the right shape for the
# measurement apparatus. See PR #12 review thread + the central Collector
# CR's `resource/paper-dims` block for the rationale.
: "${CLAUDE_CODE_ENABLE_TELEMETRY=1}"
: "${OTEL_METRICS_EXPORTER=otlp}"
: "${OTEL_LOGS_EXPORTER=otlp}"
: "${OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf}"
: "${OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:14318}"
: "${OTEL_RESOURCE_ATTRIBUTES=agent.id=macf-devops-agent,agent.role=devops,service.name=claude-code-devops-agent}"
export CLAUDE_CODE_ENABLE_TELEMETRY OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER \
       OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_ENDPOINT OTEL_RESOURCE_ATTRIBUTES

# TEMPORARY: wrap claude in `sg docker -c` so claude + its Bash-tool children
# inherit the docker gid. Needed because this host's long-running tmux server
# predates the `ubuntu`→`docker` group addition (/etc/group mtime 2026-04-14),
# so panes spawned by the server lack the supplementary group. Without this,
# `docker ps` / `docker compose` / k3s's containerd-shim interactions fail
# with "permission denied while trying to connect to the docker API". Remove
# this wrapper after a fresh tmux server (`tmux kill-server` + relaunch from
# a new login shell) picks up the docker group natively. Same pattern +
# rationale as in groundnuty/macf-science-agent:claude.sh.
tmux new-session -s "$SESSION" -c "$DIR" \
  "sg docker -c 'GH_TOKEN=$GH_TOKEN claude --permission-mode acceptEdits -c || GH_TOKEN=$GH_TOKEN claude --permission-mode acceptEdits'"
