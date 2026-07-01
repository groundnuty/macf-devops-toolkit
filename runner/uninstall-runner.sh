#!/usr/bin/env bash
# uninstall-runner.sh — cleanly tear down a self-hosted runner (devops-toolkit#90).
# Run with sudo (root): stops + removes the svc.sh systemd service, removes the
# Restart=always drop-in, and DE-REGISTERS the runner from GitHub (config.sh remove).
# The actions-runner install dir + the low-priv macf-runner user are LEFT in place
# (a fresh install-runner.sh re-registers into them; use --purge to also wipe the dir).
#
#   sudo ./uninstall-runner.sh --repo groundnuty/<repo> [--token <REMOVE_TOKEN>] [--purge]
#
# The REMOVE token is a distinct endpoint from the registration token, operator-minted
# (the bot is 403 on administration:write):
#   gh api -X POST /repos/groundnuty/<repo>/actions/runners/remove-token --jq .token
# If --token is omitted, the script prompts for it (mint as YOURSELF: `unset GH_TOKEN` first).
set -uo pipefail

RUNNER_USER="${MACF_RUNNER_USER:-macf-runner}"
RUNNER_DIR="${MACF_RUNNER_DIR:-/opt/macf-runner/actions-runner}"
REPO="" ; TOKEN="" ; PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  REPO="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --purge) PURGE=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] || { echo "FATAL: --repo groundnuty/<repo> required" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "FATAL: run with sudo (root) — svc.sh + systemd need it" >&2; exit 2; }

SVC="$(systemctl list-units --type=service --all 2>/dev/null | grep -oE 'actions\.runner\.[^ ]+\.service' | head -1)"

# 1. stop + uninstall the systemd service (svc.sh removes the unit + the enable symlink)
if [ -x "$RUNNER_DIR/svc.sh" ]; then
  ( cd "$RUNNER_DIR" && ./svc.sh stop 2>/dev/null; ./svc.sh uninstall 2>/dev/null ) \
    && echo "  svc.sh service stopped + uninstalled" || echo "  (svc.sh stop/uninstall: nothing to do / not installed)"
fi
# 2. remove the Restart=always drop-in (if any)
if [ -n "$SVC" ] && [ -d "/etc/systemd/system/${SVC}.d" ]; then
  rm -f "/etc/systemd/system/${SVC}.d/restart.conf"
  rmdir "/etc/systemd/system/${SVC}.d" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  echo "  removed Restart=always drop-in"
fi
# 3. de-register from GitHub (config.sh remove — needs a REMOVE token; run as the runner user)
if [ -f "$RUNNER_DIR/.runner" ]; then
  if [ -z "$TOKEN" ]; then
    echo "  Mint a REMOVE token as YOURSELF (bot is 403):"
    echo "    gh api -X POST /repos/$REPO/actions/runners/remove-token --jq .token"
    read -r -p "  Paste the remove-token: " TOKEN
  fi
  if [ -n "$TOKEN" ]; then
    ( cd "$RUNNER_DIR" && sudo -u "$RUNNER_USER" ./config.sh remove --token "$TOKEN" ) \
      && echo "  de-registered from GitHub (config.sh remove)" \
      || echo "  WARN: config.sh remove failed — check the token / remove it manually in Settings→Actions→Runners" >&2
  else
    echo "  WARN: no remove-token — GitHub-side registration NOT removed (a stale offline runner will linger)" >&2
  fi
else
  echo "  (no .runner config — nothing to de-register)"
fi
# 4. optional: wipe the install dir
if [ "$PURGE" -eq 1 ]; then
  rm -rf "$RUNNER_DIR"
  echo "  --purge: removed $RUNNER_DIR"
fi

echo "→ uninstalled runner for $REPO (user + $([ "$PURGE" -eq 1 ] && echo 'dir purged' || echo 'install dir kept for reinstall'))."
