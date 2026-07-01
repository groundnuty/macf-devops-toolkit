#!/usr/bin/env bash
# run-ephemeral-loop.sh — the ephemeral respawn: run ONE job, then (since --ephemeral
# de-registers the runner) re-register + run again. Driven by the systemd unit as
# macf-runner. devops-toolkit#90.
#
# Needs a fresh registration token per re-register. Two options:
#   - MACF_RUNNER_TOKEN_CMD: a command that prints a fresh repo registration token
#     (operator-provided; e.g. a helper that mints one). Preferred for unattended.
#   - else: run.sh once and exit (attended — operator re-runs install-runner.sh per job).
set -euo pipefail

RUNNER_DIR="${MACF_RUNNER_DIR:-/opt/macf-runner/actions-runner}"
REPO="${MACF_RUNNER_REPO:?set MACF_RUNNER_REPO=groundnuty/<repo>}"
cd "$RUNNER_DIR"

run_once() { ./run.sh; }   # exits after one job (ephemeral)

if [ -n "${MACF_RUNNER_TOKEN_CMD:-}" ]; then
  # unattended: loop — re-register with a fresh token, run one job, repeat.
  while true; do
    tok="$($MACF_RUNNER_TOKEN_CMD)" || { echo "token mint failed — backing off 30s" >&2; sleep 30; continue; }
    [ -n "$tok" ] || { echo "empty token — backing off 30s" >&2; sleep 30; continue; }
    ./config.sh --url "https://github.com/$REPO" --token "$tok" \
      --name "macf-vm-$(hostname -s)-$$" --labels "${MACF_RUNNER_LABELS:-self-hosted,macf-vm}" \
      --ephemeral --unattended --replace
    run_once || true
  done
else
  # attended: single job, then exit (operator re-registers via install-runner.sh).
  echo "no MACF_RUNNER_TOKEN_CMD — single-job mode (attended). Re-register via install-runner.sh."
  run_once
fi
