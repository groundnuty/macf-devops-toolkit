#!/usr/bin/env bash
# setup-macf-runner-user.sh — create the low-priv `macf-runner` user + its ONE grant
# (the narrow tmux-send-helper sudoers rule). Run once per VM, as root/sudo.
# devops-toolkit#90. See runner/RUNNER.md for the security model.
#
# Deliberately minimal privilege: NO login shell perks, NO docker group, NO sudo except
# the single send-helper as the agent-owner. So a compromised routing job can drive an
# agent (send a prompt) but cannot read the App key / ~/.kube / other agents' /proc.
set -euo pipefail

RUNNER_USER="${MACF_RUNNER_USER:-macf-runner}"
AGENT_USER="${MACF_AGENT_USER:-ubuntu}"          # the user the agents' tmux runs as
RUNNER_HOME="${MACF_RUNNER_HOME:-/opt/macf-runner}"
SEND_HELPER="${MACF_SEND_HELPER:-$RUNNER_HOME/tmux-send-to-claude.sh}"

[ "$(id -u)" = 0 ] || { echo "FATAL: run as root (sudo)" >&2; exit 1; }

# 1. the user — system account, no login shell, own home under $RUNNER_HOME
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$RUNNER_HOME" --shell /usr/sbin/nologin "$RUNNER_USER"
  echo "created user $RUNNER_USER (system, nologin, home=$RUNNER_HOME)"
else
  echo "user $RUNNER_USER already exists — leaving as-is"
fi
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_HOME"

# 2. the ONE grant — run the send helper (only) as the agent-owner, no password.
#    validated with visudo -c before install so a bad rule can't lock sudo.
SUDOERS=/etc/sudoers.d/macf-runner
TMP="$(mktemp)"
printf '%s ALL=(%s) NOPASSWD: %s\n' "$RUNNER_USER" "$AGENT_USER" "$SEND_HELPER" > "$TMP"
if visudo -c -f "$TMP" >/dev/null 2>&1; then
  install -m 0440 "$TMP" "$SUDOERS"; rm -f "$TMP"
  echo "installed $SUDOERS: $RUNNER_USER may run ONLY $SEND_HELPER as $AGENT_USER"
else
  rm -f "$TMP"; echo "FATAL: generated sudoers rule failed visudo -c — NOT installed" >&2; exit 1
fi

cat <<NOTE

macf-runner user ready. NOT granted (by design): login shell, docker group, App key dir,
~/.kube, other agents' /proc. Only capability: sudo -u $AGENT_USER $SEND_HELPER.

Next: place the send helper at $SEND_HELPER (owned by $AGENT_USER, mode 0755), then
register the runner as $RUNNER_USER (runner/install-runner.sh). Apply the egress lock
(RUNNER.md) before it serves real routing.
NOTE
