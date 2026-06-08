#!/usr/bin/env bash
# Self-hosted GitHub Actions runner — host setup for the MACF VM (macf-devops-toolkit#90, DR-003).
#
# Why: ~46% of routing wall-clock is Tailscale (connect + a load-bearing
# `sleep 10`). A runner ON the VM pays none of it (already on the tailnet/LAN;
# inject becomes a local `tmux send-keys`) → expected ~40s → ~6-9s (~4-6×).
#
# SECURITY (DR-003): the runner runs workflow code on the VM as its registered
# user. We run as a DEDICATED LOW-PRIV `macf-runner` user FROM THE START
# (operator-confirmed 2026-06-08) — NOT `ubuntu` — whose ONLY elevated grant is
# running the tmux send-helper as the agent owner via a single-command sudoers
# rule. NO `*.pem` App keys, NO `~/.kube`, NO other agents' /proc. So a workflow
# RCE (PR_TITLE injection, fork-PR secrets) is bounded to "can send a tmux
# prompt", not "owns the host + every bot identity".
#
# GATES — `register`/`start` are intentionally NOT run by `setup`. Do NOT
# register until ALL hold (see DR-003 "Gates"):
#   1. macf-actions#47 (PR_TITLE injection hardening) MERGED.
#   2. fork-PR toggles OFF + fork-approval-required on macf + macf-actions (operator).
#   3. org-scoped registration token available (operator/org-admin).
#   4. runner group scoped to macf + macf-actions; egress restricted (operator).
#
# Usage:
#   setup-github-runner.sh setup       # host prep: user + minimal grant + download + wrapper + unit. No token. SAFE/reversible.
#   REG_TOKEN=<org-reg-token> setup-github-runner.sh register   # config + install service. GATED — prints the checklist, needs REG_TOKEN.
#   setup-github-runner.sh status      # show what's installed
# Override via env: RUNNER_USER RUNNER_DIR RUNNER_VERSION ORG_URL LABELS RUNNER_GROUP EPHEMERAL AGENT_OWNER SEND_HELPER

set -euo pipefail

RUNNER_USER="${RUNNER_USER:-macf-runner}"          # low-priv, NOT ubuntu (DR-003)
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_VERSION="${RUNNER_VERSION:-}"               # empty → fetch latest at setup
ORG_URL="${ORG_URL:-https://github.com/groundnuty}"
LABELS="${LABELS:-self-hosted,macf-vm}"
RUNNER_GROUP="${RUNNER_GROUP:-macf-vm-runners}"    # operator scopes this group to macf + macf-actions
EPHEMERAL="${EPHEMERAL:-true}"                      # production posture; spike MAY use false for simplicity (DR-003)
AGENT_OWNER="${AGENT_OWNER:-ubuntu}"               # the user the agent tmux sessions run as
SEND_HELPER="${SEND_HELPER:-$(cd "$(dirname "$0")/../../.." && pwd)/.claude/scripts/tmux-send-to-claude.sh}"
SUDOERS_FILE="/etc/sudoers.d/macf-runner-tmux-send"

die() { echo "FATAL: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "this phase needs root (run via sudo); current uid=$(id -u)"; }

print_gates() {
  cat <<'GATES'
=== GATE CHECKLIST — ALL required before register (DR-003) ===
  [ ] macf-actions#47 (PR_TITLE injection hardening) MERGED
  [ ] fork-PR toggles OFF + fork-approval-required on macf + macf-actions (operator)
  [ ] org-scoped registration token available (operator/org-admin) → REG_TOKEN
  [ ] runner group scoped to macf + macf-actions; egress restricted (operator)
GATES
}

phase_setup() {
  need_root
  echo "[setup] creating low-priv runner user '${RUNNER_USER}' (no login shell, no sudo except the send-helper)"
  id "$RUNNER_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin "$RUNNER_USER"

  echo "[setup] installing single-command sudoers grant: ${RUNNER_USER} may run ONLY the send-helper as ${AGENT_OWNER}"
  [ -x "$SEND_HELPER" ] || die "send helper not executable at $SEND_HELPER (set SEND_HELPER=)"
  printf '%s ALL=(%s) NOPASSWD: %s\n' "$RUNNER_USER" "$AGENT_OWNER" "$SEND_HELPER" > "$SUDOERS_FILE"
  chmod 0440 "$SUDOERS_FILE"
  visudo -cf "$SUDOERS_FILE" || { rm -f "$SUDOERS_FILE"; die "sudoers validation failed — removed"; }

  local ver="$RUNNER_VERSION"
  if [ -z "$ver" ]; then
    echo "[setup] resolving latest actions/runner release..."
    ver="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')" \
      || die "could not resolve latest runner version (set RUNNER_VERSION=)"
  fi
  echo "[setup] installing actions/runner ${ver} to ${RUNNER_DIR} (owned by ${RUNNER_USER})"
  mkdir -p "$RUNNER_DIR"
  local arch=x64; local tgz="actions-runner-linux-${arch}-${ver}.tar.gz"
  if [ ! -f "${RUNNER_DIR}/run.sh" ]; then
    curl -fsSL -o "/tmp/${tgz}" "https://github.com/actions/runner/releases/download/v${ver}/${tgz}" || die "runner download failed"
    tar -C "$RUNNER_DIR" -xzf "/tmp/${tgz}"; rm -f "/tmp/${tgz}"
  fi
  chown -R "$RUNNER_USER":"$RUNNER_USER" "$RUNNER_DIR"

  echo "[setup] writing ephemeral respawn wrapper + systemd unit (NOT started)"
  cat > "${RUNNER_DIR}/run-ephemeral.sh" <<WRAP
#!/usr/bin/env bash
# Ephemeral respawn loop: each iteration mints a FRESH org registration token
# (RUNNER_TOKEN_CMD — operator wires a GitHub App/PAT with
# organization_self_hosted_runners:write), configures a one-shot runner, runs
# ONE job, then loops. config state never persists across jobs.
set -euo pipefail
cd "${RUNNER_DIR}"
: "\${RUNNER_TOKEN_CMD:?set RUNNER_TOKEN_CMD to a command that prints a fresh registration token}"
while true; do
  TOKEN="\$(\$RUNNER_TOKEN_CMD)" || { echo "token mint failed; retrying in 30s" >&2; sleep 30; continue; }
  ./config.sh --unattended --replace --url "${ORG_URL}" --token "\$TOKEN" \\
    --labels "${LABELS}" --runnergroup "${RUNNER_GROUP}" --ephemeral --name "macf-vm-\$(hostname -s)"
  ./run.sh || true   # ephemeral: exits after one job
done
WRAP
  chmod +x "${RUNNER_DIR}/run-ephemeral.sh"
  chown "$RUNNER_USER":"$RUNNER_USER" "${RUNNER_DIR}/run-ephemeral.sh"

  cat > /etc/systemd/system/macf-github-runner.service <<UNIT
[Unit]
Description=MACF self-hosted GitHub Actions runner (ephemeral, low-priv) — DR-003
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
User=${RUNNER_USER}
WorkingDirectory=${RUNNER_DIR}
# RUNNER_TOKEN_CMD must be provided via an EnvironmentFile the operator installs
# (the token-mint credential). Until then the unit fails fast (no silent no-op).
EnvironmentFile=/etc/macf-github-runner.env
ExecStart=${RUNNER_DIR}/run-ephemeral.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  echo "[setup] DONE. Runner downloaded + user + grant + wrapper + unit in place."
  echo "[setup] NOT registered/started. When the gates clear, run: REG_TOKEN=... $0 register"
  print_gates
}

phase_register() {
  need_root
  print_gates
  : "${REG_TOKEN:?register needs REG_TOKEN (org-scoped registration token from the operator/org-admin)}"
  echo ">>> Proceeding to register — confirm the gate checklist above is satisfied. Ctrl-C now if not."
  [ -f "${RUNNER_DIR}/config.sh" ] || die "runner not set up; run '$0 setup' first"
  if [ "$EPHEMERAL" = "true" ]; then
    echo "[register] ephemeral mode → install the systemd respawn unit (needs RUNNER_TOKEN_CMD in /etc/macf-github-runner.env)"
    [ -f /etc/macf-github-runner.env ] || die "create /etc/macf-github-runner.env with RUNNER_TOKEN_CMD=... first (token-mint credential)"
    systemctl enable --now macf-github-runner.service
  else
    echo "[register] non-ephemeral (spike) → one-shot config + svc.sh install"
    sudo -u "$RUNNER_USER" bash -c "cd '$RUNNER_DIR' && ./config.sh --unattended --replace --url '$ORG_URL' --token '$REG_TOKEN' --labels '$LABELS' --runnergroup '$RUNNER_GROUP' --name macf-vm-\$(hostname -s)"
    "${RUNNER_DIR}/svc.sh" install "$RUNNER_USER"
    "${RUNNER_DIR}/svc.sh" start
  fi
  echo "[register] DONE."
}

case "${1:-}" in
  setup)    phase_setup ;;
  register) phase_register ;;
  status)
    echo "user: $(id "$RUNNER_USER" 2>/dev/null || echo 'NOT created')"
    echo "runner dir: $([ -f "${RUNNER_DIR}/run.sh" ] && echo "$RUNNER_DIR (installed)" || echo 'NOT installed')"
    echo "sudoers grant: $([ -f "$SUDOERS_FILE" ] && echo present || echo absent)"
    echo "systemd unit: $(systemctl list-unit-files macf-github-runner.service 2>/dev/null | grep -q macf && echo installed || echo absent)"
    ;;
  *) echo "usage: $0 {setup|register|status}"; echo; print_gates ;;
esac
