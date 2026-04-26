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

# Read OTLP-related settings from settings.local.json with shell-default
# fallbacks. The CC process reads its own .env block on launch, but THIS
# launcher (which runs before CC starts) needs the values via direct jq
# lookup. `// empty` returns empty when the key is absent, distinguishing
# null-from-jq vs missing-key — we treat both as "use default".
MACF_AGENT_NAME_FROM_SETTINGS=$(jq -r '.env.MACF_AGENT_NAME // empty' "$SETTINGS")
MACF_AGENT_ROLE_FROM_SETTINGS=$(jq -r '.env.MACF_AGENT_ROLE // empty' "$SETTINGS")
MACF_OTEL_ENDPOINT_FROM_SETTINGS=$(jq -r '.env.MACF_OTEL_ENDPOINT // empty' "$SETTINGS")
[ -n "$MACF_AGENT_NAME_FROM_SETTINGS" ] && : "${MACF_AGENT_NAME:=$MACF_AGENT_NAME_FROM_SETTINGS}"
[ -n "$MACF_AGENT_ROLE_FROM_SETTINGS" ] && : "${MACF_AGENT_ROLE:=$MACF_AGENT_ROLE_FROM_SETTINGS}"
[ -n "$MACF_OTEL_ENDPOINT_FROM_SETTINGS" ] && : "${MACF_OTEL_ENDPOINT:=$MACF_OTEL_ENDPOINT_FROM_SETTINGS}"

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

# --- OTLP telemetry (refs #24, aligned per #26) ----------------------------
# Wires Claude Code's built-in OpenTelemetry support so every conversation
# emits traces (per tool call), metrics (token counts, model usage), and
# logs into the cluster's stable OTLP ingress.
#
# Resource-attr naming follows OTel GenAI semantic conventions:
#   gen_ai.agent.name   — semconv-compliant agent identity (vs the informal
#                         flat `agent.id` from PR #25, corrected per code-
#                         agent's review of macf#245).
#   gen_ai.agent.role   — extension of the gen_ai.* namespace; same
#                         convention code-agent uses in the canonical
#                         `claude-sh.ts` template.
#   OTEL_SERVICE_NAME   — `macf-agent-<role>` groups all MACF agents under
#                         one service.name family for Issue H per-cell
#                         tooling queries.
#
# Endpoint defaults to OTel canonical `:4318`; this workspace's stable
# ingress is on `:14318` (avoids collision with a pre-existing compose
# stack on the same host) so we override via MACF_OTEL_ENDPOINT, set in
# `.claude/settings.local.json`.
#
# `${VAR=default}` semantics: assigns ONLY if VAR is unset; empty stays
# empty. Two preserved override paths:
#   - Opt-out for one session:
#       MACF_OTEL_DISABLED=1 ./claude.sh
#       (or the more general: CLAUDE_CODE_ENABLE_TELEMETRY= ./claude.sh)
#   - Endpoint override for one session:
#       MACF_OTEL_ENDPOINT=http://other.ci:4318 ./claude.sh
#
# `gen_ai.agent.name` + `gen_ai.agent.role` are the load-bearing paper-dim
# resource attrs. The Collector's `resource/paper-dims` processor (in env
# macf) does NOT default these — agents that fail to stamp them are
# visibly absent in queries (fail-loud-on-absent), which is the right
# shape for the measurement apparatus. See PR #12 review thread + the
# central Collector CR's `resource/paper-dims` block for the rationale.

if [ "${MACF_OTEL_DISABLED:-}" != "1" ]; then
  : "${CLAUDE_CODE_ENABLE_TELEMETRY=1}"
  : "${OTEL_METRICS_EXPORTER=otlp}"
  : "${OTEL_LOGS_EXPORTER=otlp}"
  : "${OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf}"
  : "${MACF_OTEL_ENDPOINT=http://localhost:4318}"
  : "${OTEL_EXPORTER_OTLP_ENDPOINT=$MACF_OTEL_ENDPOINT}"
  # Agent name + role parameterized via settings.local.json — defaults
  # below are sane fallbacks for this devops workspace, but the
  # MACF_AGENT_NAME / MACF_AGENT_ROLE jq-reads above populate them from
  # settings, so changing identity is a one-line settings edit.
  : "${MACF_AGENT_NAME:=macf-devops-agent}"
  : "${MACF_AGENT_ROLE:=devops}"
  : "${OTEL_SERVICE_NAME=macf-agent-${MACF_AGENT_ROLE}}"
  : "${OTEL_RESOURCE_ATTRIBUTES=gen_ai.agent.name=${MACF_AGENT_NAME},gen_ai.agent.role=${MACF_AGENT_ROLE}}"

  # --- Conversation-content logging (#32, experimental on devops only) ----
  # Enables the four content-capture knobs documented in
  # https://code.claude.com/docs/en/monitoring-usage:
  #   OTEL_LOG_USER_PROMPTS=1   — full user-prompt text as `user_prompt`
  #                               log events (default: redacted)
  #   OTEL_LOG_TOOL_CONTENT=1   — full tool input/output as span events
  #                               (60 KB inline cap)
  #   OTEL_LOG_TOOL_DETAILS=1   — Bash command names, MCP names, skill
  #                               names on tool_result + user_prompt events
  #   OTEL_LOG_RAW_API_BODIES=1 — full Anthropic Messages API request +
  #                               response bodies (60 KB inline cap; the
  #                               only path to capture model COMPLETIONS,
  #                               since there's no separate _COMPLETIONS
  #                               env var)
  # Together: full conversation transparency (prompts + completions +
  # tool I/O). Lands in Loki + ClickHouse-logs via the central Collector's
  # logs pipeline (per #28). Per-event 60 KB inline cap means very long
  # prompts (e.g. cached 900k contexts) get truncated; flip
  # OTEL_LOG_RAW_API_BODIES to `=file:/var/log/claude-api-bodies/` for
  # untruncated capture if needed.
  #
  # Stage 1 scope per #32: experimental, devops-agent only. After one
  # session of observation + sample inspection, decide whether to
  # propagate to science / code / tester via sister PRs.
  #
  # Privacy: conversation content includes EVERYTHING the agent saw
  # (file contents, env vars, GH tokens if mishandled, internal
  # reasoning). Stored in Loki/CH (7d retention per #19). Anyone with
  # cluster access reads everything. Acceptable for this single-VM dev
  # spike; production deployment needs scrubbing + access controls.
  #
  # Opt-out at the same MACF_OTEL_DISABLED gate above (turning off
  # telemetry entirely also disables this). For finer-grained opt-out
  # (telemetry on but content off), unset these four individually.
  : "${OTEL_LOG_USER_PROMPTS=1}"
  : "${OTEL_LOG_TOOL_CONTENT=1}"
  : "${OTEL_LOG_TOOL_DETAILS=1}"
  : "${OTEL_LOG_RAW_API_BODIES=1}"
  export CLAUDE_CODE_ENABLE_TELEMETRY OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER \
         OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_ENDPOINT \
         OTEL_SERVICE_NAME OTEL_RESOURCE_ATTRIBUTES \
         OTEL_LOG_USER_PROMPTS OTEL_LOG_TOOL_CONTENT \
         OTEL_LOG_TOOL_DETAILS OTEL_LOG_RAW_API_BODIES
fi

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
