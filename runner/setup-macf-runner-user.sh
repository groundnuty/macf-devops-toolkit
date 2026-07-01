#!/usr/bin/env bash
# setup-macf-runner-user.sh — create the low-priv `macf-runner` user + its ONE grant
# (the narrow tmux-send-helper sudoers rule). Run once per VM, as root/sudo.
# devops-toolkit#90. See runner/RUNNER.md for the security model.
#
# Deliberately minimal privilege: NO login shell perks, NO docker group, NO sudo except
# the single send-helper as the agent-owner. So a compromised routing job can drive an
# agent (send a prompt) but cannot read the App key / ~/.kube / other agents' /proc.
#
# SECURITY (science's #145 review): a sudoers rule that runs a script AS ubuntu is only
# safe if the invoking user (macf-runner) cannot MODIFY that script — and directory-write
# beats file-ownership (owning the dir lets you unlink+recreate the file). So the helper
# lives at a ROOT-owned path (/usr/local/bin), NOT in the runner's own home, and we ASSERT
# (Pattern B) that the helper + every parent dir is non-writable by macf-runner BEFORE
# installing the sudoers rule — else the grant would be an escalation to ubuntu.
set -euo pipefail

RUNNER_USER="${MACF_RUNNER_USER:-macf-runner}"
AGENT_USER="${MACF_AGENT_USER:-ubuntu}"          # the user the agents' tmux runs as
RUNNER_HOME="${MACF_RUNNER_HOME:-/opt/macf-runner}"
# The sudo-invoked helper MUST live where macf-runner can't tamper (root-owned dir), NOT in
# RUNNER_HOME (which macf-runner owns). Default: /usr/local/bin (root:root).
SEND_HELPER="${MACF_SEND_HELPER:-/usr/local/bin/macf-tmux-send.sh}"
# Source to install from (the agent's send helper in the workspace).
SEND_HELPER_SRC="${MACF_SEND_HELPER_SRC:-$(cd "$(dirname "$0")/.." && pwd)/.claude/scripts/tmux-send-to-claude.sh}"

[ "$(id -u)" = 0 ] || { echo "FATAL: run as root (sudo)" >&2; exit 1; }

# 1. the user — system account, no login shell, own home under $RUNNER_HOME
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$RUNNER_HOME" --shell /usr/sbin/nologin "$RUNNER_USER"
  echo "created user $RUNNER_USER (system, nologin, home=$RUNNER_HOME)"
else
  echo "user $RUNNER_USER already exists — leaving as-is"
fi
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_HOME"

# 2. install the send helper at the ROOT-owned path (root:root 0755) — macf-runner can
#    execute it but cannot modify it (nor its dir).
if [ -f "$SEND_HELPER_SRC" ]; then
  install -o root -g root -m 0755 "$SEND_HELPER_SRC" "$SEND_HELPER"
  echo "installed send helper: $SEND_HELPER (root:root 0755) from $SEND_HELPER_SRC"
else
  echo "NOTE: send-helper source not found ($SEND_HELPER_SRC)." >&2
  echo "      Pass MACF_SEND_HELPER_SRC=<path> or place $SEND_HELPER (root:root 0755) yourself." >&2
fi

# GUARD: never install a sudoers grant pointing at a MISSING helper. Catches the
# source-not-resolved case (e.g. running this script from /tmp, where the relative
# SEND_HELPER_SRC mis-resolves) so we fail loud instead of granting sudo to a path that
# doesn't exist (broken) or that someone could later create.
[ -x "$SEND_HELPER" ] || {
  echo "FATAL: $SEND_HELPER is not an executable file — refusing to install the sudoers grant." >&2
  echo "       Re-run from the repo (so the default source resolves) or pass MACF_SEND_HELPER_SRC=<path>." >&2
  exit 1
}

# 3. ASSERT non-tamperability (Pattern B, science's #145 fix): the helper + EVERY parent dir
#    up to / must be non-writable by $RUNNER_USER — else macf-runner could swap the script
#    and the sudo-as-ubuntu grant becomes an escalation. Fail-loud; refuse to install the rule.
d="$SEND_HELPER"
while :; do
  if sudo -u "$RUNNER_USER" test -w "$d" 2>/dev/null; then
    echo "FATAL: $RUNNER_USER can write '$d' — the sudo-invoked helper would be TAMPERABLE" >&2
    echo "       (escalation to $AGENT_USER). Move the helper to a root-owned path + fix perms." >&2
    exit 1
  fi
  [ "$d" = "/" ] && break
  d="$(dirname "$d")"
done
echo "asserted: $RUNNER_USER cannot modify $SEND_HELPER (nor any parent dir) — grant is safe"

# 4. the ONE grant — run the (now-tamper-proof) send helper only, as the agent-owner.
#    visudo -c before install so a bad rule can't lock sudo.
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
~/.kube, other agents' /proc. Only capability: sudo -u $AGENT_USER $SEND_HELPER (root-owned,
tamper-proof). Register the runner as $RUNNER_USER (runner/install-runner.sh). Apply the
egress lock (RUNNER.md) before it serves real routing.
NOTE
