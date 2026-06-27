#!/usr/bin/env bash
#
# install-cron.sh — idempotently install the DR-006 watchdog cron line.
#
# The watchdog cron must be HOST-INSTALLED (DR-006 §A.4): it survives a VM reboot
# (user crontab persists in the spool, cron runs it at boot) and the FIRST post-boot
# sweep launches the whole desired fleet from a cold box — so the reconciler IS the
# one-command launch-all + the reboot-recovery, no separate mechanism. It is NOT
# installed by claude.sh-on-launch, because on cold-boot nothing launches to install
# it.
#
# The cron line sources host-prelude.sh FIRST (cron's bare env lacks the toolchain —
# the CLI / tmux / gh; DR-031 portable bootstrap), then runs reconcile.sh.
#
# SAFE DEFAULT: installs in DRY-RUN (report-only → logs decisions, acts on nothing)
# so the operator can watch the log for a few cycles before trusting it. Add
# --execute to act; --allow-restart additionally enables Tier-2. Idempotent: a
# re-run replaces the existing macf-watchdog line (marker-guarded), never duplicates.
#
# Refs: design/DR-006-vm-cron-watchdog-agent-supervision-impl.md §A.4.

set -euo pipefail

MARKER="# macf-watchdog (DR-006)"
INTERVAL="${MACF_WATCHDOG_INTERVAL:-*/10 * * * *}"   # coarse default (§A.4 / heartbeat cadence)
PRELUDE="${MACF_HOST_PRELUDE:-$HOME/.claude/.macf/host-prelude.sh}"
LOG="${MACF_WATCHDOG_LOG:-$HOME/.macf/watchdog.log}"
RECON="$(cd "$(dirname "$0")" && pwd)/reconcile.sh"
MANIFEST_ARG=""
EXECUTE_ARG="" ; RESTART_ARG="" ; ROUTING_ARG="" ; UNINSTALL=0 ; NO_TOKEN=0

usage() {
  cat <<USAGE
install-cron.sh — idempotently install/remove the DR-006 watchdog cron (DR-006 §A.4)

  --manifest <path>   pass --manifest to reconcile.sh (default: its own default)
  --interval "<cron>" schedule (default: "$INTERVAL")
  --execute           install an ACTING line (default: report-only/dry-run)
  --allow-restart     also enable Tier-2 graceful-restart (implies a careful operator)
  --with-routing      also run the routing-doctor probe (registration-freshness)
  --no-token          do NOT bake a GH_TOKEN mint into the cron (operator provides it)
  --uninstall         remove the macf-watchdog cron line
  --print             print the line that WOULD be installed, don't touch crontab
  -h, --help

Installs (default) a REPORT-ONLY line logging to $LOG — watch it, then re-run with
--execute once trusted. host-prelude ($PRELUDE) is sourced first for cron's bare env.
USAGE
}

PRINT_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)      MANIFEST_ARG="--manifest $2"; shift 2 ;;
    --interval)      INTERVAL="$2"; shift 2 ;;
    --execute)       EXECUTE_ARG="--execute"; shift ;;
    --allow-restart) RESTART_ARG="--allow-restart"; shift ;;
    --with-routing)  ROUTING_ARG="--with-routing"; shift ;;
    --no-token)      NO_TOKEN=1; shift ;;
    --uninstall)     UNINSTALL=1; shift ;;
    --print)         PRINT_ONLY=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "install-cron.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v crontab >/dev/null || { echo "FATAL: crontab not found" >&2; exit 2; }
[ -f "$RECON" ] || { echo "FATAL: reconcile.sh not found at $RECON" >&2; exit 2; }

# strip any existing macf-watchdog line (idempotency); preserve the rest
EXISTING="$(crontab -l 2>/dev/null | grep -vF "$MARKER" || true)"

if [ "$UNINSTALL" -eq 1 ]; then
  printf '%s\n' "$EXISTING" | crontab -
  echo "removed macf-watchdog cron line."
  exit 0
fi

# Token-mint: the watchdog's `fleet doctor` reads MACF_CA_CERT from the registry, so the
# cron needs a fresh GH_TOKEN (cron has none — found via live-dry-run, devops-toolkit#118).
# Mint it from the workspace's App creds (same helper + creds the SessionStart hook uses),
# fail-loud (no token → abort the sweep rather than run blind into a 401). The `$(...)` is
# escaped so cron's shell evaluates it at RUN time (fresh token each sweep); the creds are
# resolved now (fixed). --no-token skips (operator supplies GH_TOKEN another way).
TOKEN_PREFIX=""
if [ "$NO_TOKEN" -ne 1 ]; then
  WS="$(cd "$(dirname "$RECON")/.." && pwd)"
  HELPER="$WS/.claude/scripts/macf-gh-token.sh"
  SETTINGS="$WS/.claude/settings.local.json"
  if [ -x "$HELPER" ] && [ -f "$SETTINGS" ]; then
    WD_APP="$(jq -r '.env.APP_ID // empty' "$SETTINGS")"
    WD_INST="$(jq -r '.env.INSTALL_ID // empty' "$SETTINGS")"
    WD_KEY="$(jq -r '.env.KEY_PATH // empty' "$SETTINGS")"
    case "$WD_KEY" in /*) ;; *) WD_KEY="$WS/$WD_KEY" ;; esac   # absolutize a relative key path
    if [ -n "$WD_APP" ] && [ -n "$WD_INST" ] && [ -n "$WD_KEY" ]; then
      TOKEN_PREFIX="GH_TOKEN=\$($HELPER --app-id $WD_APP --install-id $WD_INST --key $WD_KEY) || exit 1; export GH_TOKEN; "
    else
      echo "WARN: APP_ID/INSTALL_ID/KEY_PATH not all readable from $SETTINGS — no token baked (fleet-doctor may 401). --no-token silences." >&2
    fi
  else
    echo "WARN: token helper or settings missing ($HELPER / $SETTINGS) — no token baked. --no-token silences." >&2
  fi
fi

# the cron command: prelude (toolchain) → mint GH_TOKEN → run reconcile, append to the log
CMD="[ -f $PRELUDE ] && . $PRELUDE; ${TOKEN_PREFIX}$RECON $MANIFEST_ARG $ROUTING_ARG $EXECUTE_ARG $RESTART_ARG >> $LOG 2>&1"
LINE="$INTERVAL $CMD $MARKER"

if [ "$PRINT_ONLY" -eq 1 ]; then
  echo "$LINE"; exit 0
fi

printf '%s\n%s\n' "$EXISTING" "$LINE" | grep -v '^$' | crontab -
mode="REPORT-ONLY (dry-run)"; [ -n "$EXECUTE_ARG" ] && mode="EXECUTE"; [ -n "$RESTART_ARG" ] && mode="$mode + restart"
echo "installed macf-watchdog cron [$mode], interval '$INTERVAL', log $LOG"
echo "verify: crontab -l | grep macf-watchdog"
