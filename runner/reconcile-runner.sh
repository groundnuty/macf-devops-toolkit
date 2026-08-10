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

# per-runner paths — heavy/growing runner state (the actions-runner install + its _work)
# lives on the big volume, NOT the (84%-full) root disk. Each runner gets an ISOLATED
# home+actions-runner dir keyed by its own name (no collision between repos); ALL runners
# SHARE one action-archive-cache (Lever B — the router actions are identical across repos,
# one cache serves every runner) and the ONE low-priv macf-runner OS user (RUNNER_USER,
# unchanged — set up once per VM by setup-macf-runner-user.sh, not per-runner).
# Exported so every downstream call below (verify / install / uninstall) resolves the SAME
# per-runner paths without re-deriving them. Plain export is enough for the un-sudo'd
# verify-runner.sh calls; the `sudo ./install-runner.sh` / `sudo ./uninstall-runner.sh`
# calls below thread them explicitly via `sudo env VAR=...` instead of relying on `sudo -E`
# — sudo resets the environment by default (env_reset), and whether -E is honored depends
# on sudoers policy the operator's shell may not have; `sudo env VAR=val cmd` always works
# regardless of that policy because it's not environment INHERITANCE, it's an explicit
# assignment consumed by env(1) before it execs the child.
RUNNER_BASE="${MACF_RUNNER_BASE:-/mnt/volume1/macf-runners}"
export MACF_RUNNER_HOME="$RUNNER_BASE/$NAME"
export MACF_RUNNER_DIR="$MACF_RUNNER_HOME/actions-runner"
export MACF_ACTION_ARCHIVE_CACHE="$RUNNER_BASE/action-archive-cache"
export MACF_RUNNER_DIAG="$MACF_RUNNER_DIR/_diag"
SUDO_ENV=(env
  "MACF_RUNNER_HOME=$MACF_RUNNER_HOME"
  "MACF_RUNNER_DIR=$MACF_RUNNER_DIR"
  "MACF_ACTION_ARCHIVE_CACHE=$MACF_ACTION_ARCHIVE_CACHE"
  "MACF_RUNNER_DIAG=$MACF_RUNNER_DIAG")
echo "   runner home: $MACF_RUNNER_HOME  (shared cache: $MACF_ACTION_ARCHIVE_CACHE)"

# --- maintenance-lock bookkeeping (#165, DR-040 Decision 4) -------------------
# A reinstall tears the systemd unit down on purpose. runner-watchdog.sh SKIPs a
# runner under an active lock, so without this the teardown window looks like an
# outage and emits a transient ALERT. (Before #169 the watchdog never actually
# swept, so this could not fire in practice — now it can, which is what makes
# this worth wiring rather than theoretical.)
#
# Crash-safety mirrors fleet/upgrade.sh exactly: the trap STOPS the heartbeat but
# deliberately does NOT release — a halted reinstall leaves the lock in place and
# lets its TTL free it, so an interrupted teardown is never mistaken for a healthy
# runner. Release happens ONLY on a clean post-install verify.
# shellcheck source=../fleet/maintenance-lock.sh
. "$(cd "$(dirname "$0")/../fleet" && pwd)/maintenance-lock.sh"
CURRENT_LOCK_RUNNER=""
CURRENT_HB_PID=""
_lock_cleanup_keep() {      # stop heartbeat; LEAVE the lock (halt/trap path)
  [ -n "$CURRENT_HB_PID" ] && kill "$CURRENT_HB_PID" 2>/dev/null || true
  CURRENT_HB_PID=""
}
_lock_cleanup_release() {   # stop heartbeat AND release (clean GREEN only)
  _lock_cleanup_keep
  [ -n "$CURRENT_LOCK_RUNNER" ] && lock_release "$CURRENT_LOCK_RUNNER"
  CURRENT_LOCK_RUNNER=""
}
trap _lock_cleanup_keep EXIT INT TERM

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

# 2-lock. Everything below this point can tear the unit down — hold the lock for the
# WHOLE window (uninstall → install → verify), keyed on the runner NAME, the same key
# runner-watchdog.sh and maintenance-lock.sh use. Heartbeat it so a slow reinstall
# (download + config) can't let the TTL lapse mid-window and un-SKIP the watchdog.
lock_acquire "$NAME" "reinstall"
CURRENT_LOCK_RUNNER="$NAME"
lock_heartbeat_loop "$NAME" "$MAINT_LOCK_HEARTBEAT_INTERVAL" \
  "$(lock_heartbeat_max_iters "$MAINT_LOCK_HEARTBEAT_INTERVAL")" &
CURRENT_HB_PID=$!

# 2a. copy the fleet's shared vars from var_source (so we don't hand-set them)
echo "-- copying $FLEET shared vars from $VAR_SOURCE → $REPO --"
./copy-vars.sh --to "$REPO" --fleet "$FLEET" || echo "   (var-copy had issues — continuing; verify later)"

# 2b. if a stale registration exists, tear it down first (config.sh --replace is insufficient;
# install-runner.sh refuses to clobber a live .runner → remove-then-readd is uninstall's job).
if [ -f "$MACF_RUNNER_DIR/.runner" ]; then
  echo "-- existing registration found → uninstalling first (clean remove-then-readd) --"
  sudo "${SUDO_ENV[@]}" ./uninstall-runner.sh --repo "$REPO" || echo "   (uninstall had issues — continuing to install attempt)"
fi

# 2c. full install: NON-ephemeral runner + svc.sh service + Restart=always oversight (root sudo;
# install-runner.sh prompts for the registration token — operator mints it, bot is 403).
sudo "${SUDO_ENV[@]}" ./install-runner.sh --repo "$REPO" || { echo "install failed."; exit 1; }

# 3. prove it — verify again with the same check. Release the maintenance-lock ONLY
# here, on a GREEN verify: if the reinstall left the runner broken, the lock stays
# (its TTL frees it) so the watchdog doesn't immediately re-ALERT on a runner an
# operator is probably still working on — and, more importantly, a half-finished
# reinstall is never handed back as "fine".
echo "-- verifying the freshly-registered runner --"
if ./verify-runner.sh --repo "$REPO"; then
  _lock_cleanup_release
  echo "→ reinstall complete + verified; maintenance-lock released."
else
  rc=$?
  _lock_cleanup_keep
  echo "→ post-install verify FAILED — leaving the maintenance-lock in place;" >&2
  echo "  it frees itself via its ${MAINT_LOCK_TTL}s TTL once heartbeats stop (DR-040 Decision 4)." >&2
  exit "$rc"
fi
