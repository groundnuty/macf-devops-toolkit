#!/usr/bin/env bash
set -euo pipefail

# MACF Agent Launcher: devops-agent (HAND-WIRED substrate — DR-005 Decision 6).
#
# This launcher is RECONCILED to the framework generation (groundnuty/macf
# src/cli/claude-sh.ts) but maintained by hand: this is a substrate workspace,
# NOT a `macf init` consumer (macf#273). Do NOT run `macf init`/`macf update`
# here. Changes that should be canonical graduate UP into the framework
# template (DR-029); genuine host-specifics live in host-prelude.sh / env.local.*.
#
# Thin launcher (macf#342): per-concern env exports live in .claude/.macf/env.*
# and are sourced via the loop below. The minimal channel-server plugin
# (.macf/plugin-cs, mcpServers-only — macf#533, proven loadable) brings up the
# Stage-3 channel server as claude's MCP child via --plugin-dir.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Host-local prelude FIRST — before the env.* loop, because env.github mints the
# bot token via brew-installed openssl/curl on this VM. (host-prelude.sh is the
# DR-005 early host-specific slot; the framework env.local.*/env.zz.* slots sort
# POST-canonical, too late for tools env.github needs.)
[ -f "$SCRIPT_DIR/.claude/.macf/host-prelude.sh" ] && source "$SCRIPT_DIR/.claude/.macf/host-prelude.sh"

# Source per-concern env files (macf#342). env._helpers (underscore) sorts first
# and defines macf_settings_get used by env.identity/env.telemetry.
if [ -d "$SCRIPT_DIR/.claude/.macf" ]; then
  for f in "$SCRIPT_DIR/.claude/.macf"/env.*; do
    [ -f "$f" ] && source "$f"
  done
fi

# Channel-server network identity (DR-005 Decisions 2+3). The channel server
# (MCP child) inherits these from the process env. WITHOUT MACF_ADVERTISE_HOST
# it defaults the registry-advertised host to 127.0.0.1 — unreachable from the
# GitHub-hosted router AND a SAN-mismatch against the FQDN leaf cert → route
# fails. All substrate homes share this host's MagicDNS FQDN; MACF_PORT is the
# per-agent fixed port from the DR-005 Decision-3 map (devops=8701). MACF_*
# prefix → captured by the tmux -e passthrough below + inherited by the MCP child.
export MACF_HOST="${MACF_HOST:-0.0.0.0}"
export MACF_ADVERTISE_HOST="${MACF_ADVERTISE_HOST:-orzech-dev-agents.tail491af.ts.net}"
export MACF_PORT="${MACF_PORT:-8701}"

# Tmux self-wrap (macf#313/#340). If launched outside tmux and not opted out,
# re-exec inside a session named <MACF_PROJECT>@<MACF_AGENT_NAME> = macf@devops-agent.
# The -e MACF_* passthrough pins this workspace's identity over the tmux
# server-global env (macf#340 collision guard). The inner invocation has $TMUX
# set, re-sources env.* fresh (so OTEL_*/GH_TOKEN are re-derived in-session — no
# manual cross-boundary inlining needed; that + the sg-docker wrap are dropped).
#
# Opt-out: MACF_NO_TMUX_WRAP=1 ./claude.sh
if [ -z "${TMUX:-}" ] && [ "${MACF_NO_TMUX_WRAP:-}" != "1" ]; then
  SESSION_NAME="${MACF_PROJECT}@${MACF_AGENT_NAME}"
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    exec tmux attach -t "$SESSION_NAME"
  else
    MACF_TMUX_E_ARGS=()
    while IFS= read -r macf_env_line; do
      MACF_TMUX_E_ARGS+=("-e" "$macf_env_line")
    done < <(env | grep -E "^MACF_" || true)
    exec tmux new-session "${MACF_TMUX_E_ARGS[@]}" -s "$SESSION_NAME" -c "$SCRIPT_DIR" "$0" "$@"
  fi
fi

# Inside the session: launch Claude Code with the minimal channel-server plugin.
# --plugin-dir loads .macf/plugin-cs (mcpServers-only) → spawns the channel
# server as the MCP child, which self-registers MACF_AGENT_DEVOPS_AGENT.
if [ -n "${MACF_TEST:-}" ]; then
  exec claude --permission-mode acceptEdits --plugin-dir "$SCRIPT_DIR/.macf/plugin-cs" "$@"
else
  claude --permission-mode acceptEdits -c --plugin-dir "$SCRIPT_DIR/.macf/plugin-cs" "$@" \
    || exec claude --permission-mode acceptEdits --plugin-dir "$SCRIPT_DIR/.macf/plugin-cs" "$@"
fi
