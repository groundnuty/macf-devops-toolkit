#!/usr/bin/env bash
# reconcile-runner.sh — make ONE runner so + prove it (devops-toolkit#90).
# The idempotent per-runner target behind `make runner-<name>`:
#   verify  →  if healthy: done  |  if not: (interactively) copy vars + install + register
#           →  verify AGAIN (prove the AC with the same check we started with).
# Reads runners.yaml (name → repo + the fleet's var_source). --verify-only skips the install
# prompt (used by `make verify-all`). Registration needs an operator-minted token (the bot is
# 403 on administration:write), so the install path PROMPTS for one — interactive by design.
#
# --force: skip the initial health-gate and go straight to the install offer, regardless of
# what verify-runner.sh reports. "reinstall" (`make reinstall-<name>` = uninstall + this,
# --force) unambiguously means tear-down-then-install; it must NOT be short-circuited by a
# health check that reads a just-torn-down runner as "healthy" (e.g. verify-runner.sh run
# without sudo degrading a would-be FAIL to [skip] — devops-toolkit reinstall-skips-install
# bug, 2026-07-02). The install path still prompts for the y/N confirm + the registration
# token (interactive by design, per above) — --force only removes the health-check bypass.
set -uo pipefail
cd "$(dirname "$0")"
REG="${MACF_RUNNERS_YAML:-runners.yaml}"
NAME="" VERIFY_ONLY=0 FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$NAME" ] || { echo "FATAL: --name <runner-name> required (see: make runners)" >&2; exit 2; }
[ "$FORCE" -eq 1 ] && [ "$VERIFY_ONLY" -eq 1 ] && { echo "FATAL: --force and --verify-only are mutually exclusive" >&2; exit 2; }
command -v yq >/dev/null && command -v jq >/dev/null || { echo "FATAL: need yq + jq" >&2; exit 2; }

# resolve name → fleet, var_source, repo
row="$(yq -o=json "$REG" | jq -r --arg n "$NAME" \
  '.fleets[] as $f | $f.runners[] | select(.name==$n) | "\($f.name)\t\($f.var_source)\t\(.repo)"')"
[ -n "$row" ] || { echo "FATAL: runner '$NAME' not in $REG" >&2; exit 2; }
IFS=$'\t' read -r FLEET VAR_SOURCE REPO <<<"$row"
echo "reconcile runner '$NAME' — repo=$REPO  fleet=$FLEET"

# 1. verify (the same check we'll prove with at the end) — skipped entirely under --force,
# so a reinstall can never be short-circuited by "already healthy; nothing to do." (that gate
# is exactly what left a torn-down runner dead + de-registered — see the --force comment above).
if [ "$FORCE" -eq 1 ]; then
  echo "→ --force: skipping health-check gate, forcing install."
else
  if ./verify-runner.sh --repo "$REPO" >/tmp/rr.$$ 2>&1; then
    cat /tmp/rr.$$; rm -f /tmp/rr.$$
    echo "→ already healthy; nothing to do."
    exit 0
  fi
  cat /tmp/rr.$$; rm -f /tmp/rr.$$
  echo "→ NOT healthy."
fi
if [ "$VERIFY_ONLY" -eq 1 ]; then exit 1; fi
[ -t 0 ] || { echo "   (non-interactive — re-run in a terminal to install, or run the steps in RUNNER.md)"; exit 1; }

# 2. offer to install — SKIPPED under --force. In the reinstall flow (`make reinstall-<name>`
# = uninstall + reconcile --force) the destructive teardown has ALREADY run as a prerequisite,
# so a "no" here would strand the runner torn-down + de-registered. --force means the caller
# already committed to the reinstall; go straight to install (install-runner.sh auto-mints the
# token, so the whole reinstall is then prompt-free).
if [ "$FORCE" -ne 1 ]; then
  read -r -p "Install + register the runner for $REPO now? [y/N] " a
  [ "${a:-N}" = y ] || [ "${a:-N}" = Y ] || { echo "skipped."; exit 1; }
fi

# 2a. copy the fleet's shared vars from var_source (so we don't hand-set them)
echo "-- copying $FLEET shared vars from $VAR_SOURCE → $REPO --"
./copy-vars.sh --to "$REPO" --fleet "$FLEET" || echo "   (var-copy had issues — continuing; verify later)"

# 2b. if a stale registration exists, tear it down first (config.sh --replace is insufficient;
# install-runner.sh refuses to clobber a live .runner → remove-then-readd is uninstall's job).
if [ -f "/opt/macf-runner/actions-runner/.runner" ]; then
  echo "-- existing registration found → uninstalling first (clean remove-then-readd) --"
  sudo ./uninstall-runner.sh --repo "$REPO" || echo "   (uninstall had issues — continuing to install attempt)"
fi

# 2c. full install: NON-ephemeral runner + svc.sh service + Restart=always oversight (root sudo;
# install-runner.sh prompts for the registration token — operator mints it, bot is 403).
sudo ./install-runner.sh --repo "$REPO" || { echo "install failed."; exit 1; }

# 3. prove it — verify again with the same check
echo "-- verifying the freshly-registered runner --"
./verify-runner.sh --repo "$REPO"
