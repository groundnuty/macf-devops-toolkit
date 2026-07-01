#!/usr/bin/env bash
# reconcile-runner.sh — make ONE runner so + prove it (devops-toolkit#90).
# The idempotent per-runner target behind `make runner-<name>`:
#   verify  →  if healthy: done  |  if not: (interactively) copy vars + install + register
#           →  verify AGAIN (prove the AC with the same check we started with).
# Reads runners.yaml (name → repo + the fleet's var_source). --verify-only skips the install
# prompt (used by `make verify-all`). Registration needs an operator-minted token (the bot is
# 403 on administration:write), so the install path PROMPTS for one — interactive by design.
set -uo pipefail
cd "$(dirname "$0")"
REG="${MACF_RUNNERS_YAML:-runners.yaml}"
NAME="" VERIFY_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$NAME" ] || { echo "FATAL: --name <runner-name> required (see: make runners)" >&2; exit 2; }
command -v yq >/dev/null && command -v jq >/dev/null || { echo "FATAL: need yq + jq" >&2; exit 2; }

# resolve name → fleet, var_source, repo
row="$(yq -o=json "$REG" | jq -r --arg n "$NAME" \
  '.fleets[] as $f | $f.runners[] | select(.name==$n) | "\($f.name)\t\($f.var_source)\t\(.repo)"')"
[ -n "$row" ] || { echo "FATAL: runner '$NAME' not in $REG" >&2; exit 2; }
IFS=$'\t' read -r FLEET VAR_SOURCE REPO <<<"$row"
echo "reconcile runner '$NAME' — repo=$REPO  fleet=$FLEET"

# 1. verify (the same check we'll prove with at the end)
if ./verify-runner.sh --repo "$REPO" >/tmp/rr.$$ 2>&1; then
  cat /tmp/rr.$$; rm -f /tmp/rr.$$
  echo "→ already healthy; nothing to do."
  exit 0
fi
cat /tmp/rr.$$; rm -f /tmp/rr.$$
echo "→ NOT healthy."
if [ "$VERIFY_ONLY" -eq 1 ]; then exit 1; fi
[ -t 0 ] || { echo "   (non-interactive — re-run in a terminal to install, or run the steps in RUNNER.md)"; exit 1; }

# 2. offer to install
read -r -p "Install + register the runner for $REPO now? [y/N] " a
[ "${a:-N}" = y ] || [ "${a:-N}" = Y ] || { echo "skipped."; exit 1; }

# 2a. copy the fleet's shared vars from var_source (so we don't hand-set them)
echo "-- copying $FLEET shared vars from $VAR_SOURCE → $REPO --"
./copy-vars.sh --to "$REPO" --fleet "$FLEET" || echo "   (var-copy had issues — continuing; verify later)"

# 2b. mint a registration token — the operator does this (bot is 403). Prompt for it.
echo "-- mint a repo registration token (operator; bot is 403) --"
echo "   gh api -X POST /repos/$REPO/actions/runners/registration-token --jq .token"
read -r -p "Paste the token: " TOKEN
[ -n "$TOKEN" ] || { echo "no token — aborting install."; exit 1; }

# 2c. install/register as the low-priv macf-runner user
sudo -u macf-runner bash ./install-runner.sh --repo "$REPO" --token "$TOKEN" || { echo "install failed."; exit 1; }

# 3. prove it — verify again with the same check
echo "-- verifying the freshly-registered runner --"
./verify-runner.sh --repo "$REPO"
