#!/usr/bin/env bash
# install-runner.sh — download the pinned actions/runner + configure it REPO-scoped +
# EPHEMERAL. Run as the macf-runner user (NOT root, NOT ubuntu). devops-toolkit#90.
#
#   sudo -u macf-runner ./install-runner.sh --repo groundnuty/<repo> --token <REG_TOKEN>
#
# The registration token is short-lived (~1h, operator-minted; the bot is 403). Ephemeral
# = the runner de-registers after ONE job; run-ephemeral-loop.sh (via systemd) re-registers.
set -euo pipefail

RUNNER_VERSION="${MACF_RUNNER_VERSION:-2.321.0}"   # pin; bump deliberately
RUNNER_DIR="${MACF_RUNNER_DIR:-/opt/macf-runner/actions-runner}"
LABELS="${MACF_RUNNER_LABELS:-self-hosted,macf-vm}"
REPO="" ; TOKEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  REPO="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --version) RUNNER_VERSION="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ]  || { echo "FATAL: --repo groundnuty/<repo> required" >&2; exit 2; }
[ -n "$TOKEN" ] || { echo "FATAL: --token <registration-token> required (operator-minted)" >&2; exit 2; }
[ "$(id -un)" != root ] || { echo "FATAL: do NOT run as root — run as the macf-runner user" >&2; exit 2; }

mkdir -p "$RUNNER_DIR"; cd "$RUNNER_DIR"
TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
if [ ! -f "./config.sh" ]; then
  echo "downloading actions/runner $RUNNER_VERSION ..."
  curl -fsSL -o "$TARBALL" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"
  tar xzf "$TARBALL" && rm -f "$TARBALL"
fi

# repo-scoped (user account => no org scope), ephemeral, labelled. --unattended + --replace
# so the systemd loop can re-register non-interactively.
./config.sh \
  --url "https://github.com/$REPO" \
  --token "$TOKEN" \
  --name "macf-vm-$(hostname -s)-$$" \
  --labels "$LABELS" \
  --ephemeral --unattended --replace

echo "configured ephemeral runner for $REPO (labels: $LABELS). Start via:"
echo "  sudo systemctl enable --now macf-runner@$(printf '%s' "$REPO" | tr '/' '-')"
