#\!/usr/bin/env bash
# install-runner.sh — download + register a PERSISTENT (non-ephemeral) self-hosted runner
# as a svc.sh systemd service WITH the Restart=always oversight. Run with sudo (root):
# config.sh runs as the low-priv macf-runner user (correct _work ownership); svc.sh +
# the systemd drop-in need root. devops-toolkit#90.
#
#   sudo ./install-runner.sh --repo groundnuty/<repo> [--token <REG_TOKEN>] [--ephemeral]
#
# NON-EPHEMERAL by default (survives jobs — the stable A/B baseline). --ephemeral opts into
# the de-register-after-one-job mode (needs an external token-refresh loop; bot is 403).
# The REGISTRATION token is operator-minted (bot is 403); if --token omitted, prompts for it.
# Expects a CLEAN slot — run uninstall-runner.sh first to re-register (config.sh --replace is
# insufficient: "already configured" → remove-then-readd; that's uninstall-runner.sh's job).
set -uo pipefail

RUNNER_VERSION="${MACF_RUNNER_VERSION:-2.321.0}"   # pin; self-updates to latest on first connect
RUNNER_USER="${MACF_RUNNER_USER:-macf-runner}"
RUNNER_HOME="${MACF_RUNNER_HOME:-/opt/macf-runner}"
RUNNER_DIR="${MACF_RUNNER_DIR:-$RUNNER_HOME/actions-runner}"
LABELS="${MACF_RUNNER_LABELS:-self-hosted,macf-vm}"
CACHE_DIR="${MACF_ACTION_ARCHIVE_CACHE:-$RUNNER_HOME/action-archive-cache}"  # Lever B; OUTSIDE
                                            #   $RUNNER_DIR so it survives uninstall/reinstall
HERE="$(cd "$(dirname "$0")" && pwd)"       # for the Restart override .conf + seed helper
REPO="" ; TOKEN="" ; EPHEMERAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  REPO="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --version) RUNNER_VERSION="$2"; shift 2 ;;
    --ephemeral) EPHEMERAL=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] || { echo "FATAL: --repo groundnuty/<repo> required" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "FATAL: run with sudo (root) — svc.sh + the systemd drop-in need it" >&2; exit 2; }
id "$RUNNER_USER" >/dev/null 2>&1 || { echo "FATAL: user $RUNNER_USER missing — run setup-macf-runner-user.sh first" >&2; exit 2; }

# refuse to clobber an existing registration (remove-then-readd is uninstall-runner.sh's job)
[ -f "$RUNNER_DIR/.runner" ] && { echo "FATAL: already registered ($RUNNER_DIR/.runner exists). Run: sudo ./uninstall-runner.sh --repo $REPO  first." >&2; exit 2; }

# 0. token
if [ -z "$TOKEN" ]; then
  echo "Mint a REGISTRATION token as YOURSELF (bot is 403):"
  echo "  gh api -X POST /repos/$REPO/actions/runners/registration-token --jq .token"
  read -r -p "Paste the registration-token: " TOKEN
fi
[ -n "$TOKEN" ] || { echo "FATAL: no registration token" >&2; exit 2; }

# 1. download the runner tarball into the (macf-runner-owned) dir
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_DIR"
if [ \! -f "$RUNNER_DIR/config.sh" ]; then
  TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  echo "downloading actions/runner $RUNNER_VERSION ..."
  sudo -u "$RUNNER_USER" bash -c "cd '$RUNNER_DIR' && curl -fsSL -o '$TARBALL' \
    'https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}' \
    && tar xzf '$TARBALL' && rm -f '$TARBALL'"
fi

# 2. register (as macf-runner — correct _work ownership). NON-ephemeral unless --ephemeral.
EPH=""; [ "$EPHEMERAL" -eq 1 ] && EPH="--ephemeral"
sudo -u "$RUNNER_USER" bash -c "cd '$RUNNER_DIR' && ./config.sh \
  --url 'https://github.com/$REPO' --token '$TOKEN' \
  --name 'macf-vm-$(hostname -s)' --labels '$LABELS' --unattended $EPH"

# 2b. Lever B (action-archive-cache) — arm the runner's .env BEFORE the service starts (the
#     listener inherits $ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE at start). Pure optimization:
#     File.Copy a local SHA-keyed tarball instead of re-fetching every uses: action from codeload
#     each job (verified ~2s/job, ~50% of the fetch phase; #150). Seeding needs a prior Worker log
#     (chicken-and-egg on a fresh runner) → seed now if warm, else after the first routing job.
#     A seed failure is a WARN, NEVER fatal — the runner works without it (falls back to codeload;
#     fails safe). Cache dir is outside $RUNNER_DIR so it survives uninstall/reinstall.
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$CACHE_DIR"
ENV_FILE="$RUNNER_DIR/.env"
if ! grep -qs '^ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE=' "$ENV_FILE" 2>/dev/null; then
  echo "ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE=$CACHE_DIR" >> "$ENV_FILE"   # idempotent (grep-guarded)
fi
if ls "$RUNNER_DIR"/_diag/Worker_*.log >/dev/null 2>&1; then            # warm / reinstall — seed now
  if MACF_ACTION_ARCHIVE_CACHE="$CACHE_DIR" MACF_RUNNER_DIAG="$RUNNER_DIR/_diag" \
       "$HERE/seed-action-cache.sh"; then
    chown -R "$RUNNER_USER":"$RUNNER_USER" "$CACHE_DIR"
    LEVER_B="armed + seeded"
  else
    echo "  WARN: Lever B seed failed — cache incomplete; jobs fall back to codeload (fails safe)." >&2
    echo "        Re-seed later: $HERE/seed-action-cache.sh" >&2
    chown -R "$RUNNER_USER":"$RUNNER_USER" "$CACHE_DIR" 2>/dev/null || true
    LEVER_B="armed (seed FAILED — see WARN, non-fatal)"
  fi
else                                                                   # brand-new runner — no log yet
  echo "  note: Lever B armed; cache seeds after the FIRST routing job. Once a job has run, seed it:"
  echo "        $HERE/seed-action-cache.sh   (or 'make seed-<name>' if wired into runner/Makefile)"
  LEVER_B="armed (pending first-job seed)"
fi
echo "  ✓ Lever B (action-archive-cache): $LEVER_B  [$CACHE_DIR]"

# 3. install + start the svc.sh systemd service (runs as macf-runner)
( cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER" && ./svc.sh start )

# 4. install the Restart=always oversight drop-in (the svc.sh unit omits Restart= → a crash
#    leaves it dead; #90). Assert it took.
SVC="$(systemctl list-units --type=service --all 2>/dev/null | grep -oE 'actions\.runner\.[^ ]+\.service' | head -1)"
if [ -n "$SVC" ] && [ -f "$HERE/systemd-restart-override.conf" ]; then
  mkdir -p "/etc/systemd/system/${SVC}.d"
  cp "$HERE/systemd-restart-override.conf" "/etc/systemd/system/${SVC}.d/restart.conf"
  systemctl daemon-reload
  systemctl restart "$SVC"
  POLICY="$(systemctl show "$SVC" -p Restart --value 2>/dev/null)"
  [ "$POLICY" = "always" ] && echo "  ✓ Restart=always oversight installed" \
    || echo "  WARN: Restart policy is '$POLICY' — override may not have applied" >&2
else
  echo "  WARN: could not install Restart override (svc='$SVC', conf missing?)" >&2
fi

echo "→ installed $([ "$EPHEMERAL" -eq 1 ] && echo ephemeral || echo NON-ephemeral) runner for $REPO as $SVC (Restart=always). Verify: runner/verify-runner.sh --repo $REPO"
