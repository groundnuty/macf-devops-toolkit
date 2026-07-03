#!/usr/bin/env bash
# install-runner.sh — download + register a PERSISTENT (non-ephemeral) self-hosted runner
# as a svc.sh systemd service WITH the Restart=always oversight. Run with sudo (root):
# config.sh runs as the low-priv macf-runner user (correct _work ownership); svc.sh +
# the systemd drop-in need root. devops-toolkit#90.
#
#   sudo ./install-runner.sh --repo groundnuty/<repo> [--token <REG_TOKEN>] [--ephemeral]
#
# NON-EPHEMERAL by default (survives jobs — the stable A/B baseline). --ephemeral opts into
# the de-register-after-one-job mode (needs an external token-refresh loop; bot is 403).
# The REGISTRATION token is auto-minted via YOUR gh admin creds (the bot is always 403 on
# administration:write, so it can't self-mint) — falls back to an interactive prompt only if
# auto-mint fails, or FATALs if there's no TTY either. Pass --token to skip both.
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
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] || { echo "FATAL: --repo groundnuty/<repo> required" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "FATAL: run with sudo (root) — svc.sh + the systemd drop-in need it" >&2; exit 2; }
REPO_SLUG="${REPO//\//-}"   # owner/repo -> owner-repo, matches svc.sh's actions.runner.<slug>.<name>.service
id "$RUNNER_USER" >/dev/null 2>&1 || { echo "FATAL: user $RUNNER_USER missing — run setup-macf-runner-user.sh first" >&2; exit 2; }

# refuse to clobber an existing registration (remove-then-readd is uninstall-runner.sh's job)
[ -f "$RUNNER_DIR/.runner" ] && { echo "FATAL: already registered ($RUNNER_DIR/.runner exists). Run: sudo ./uninstall-runner.sh --repo $REPO  first." >&2; exit 2; }

# 0. fork-PR-approval precheck (public repos only) — a self-hosted runner on a
# PUBLIC repo is a fork-PR code-execution risk; until macf-actions#59 (origin-
# routing) lands, GitHub's native "require approval for ALL external
# contributors" fork-PR setting is the ONLY thing standing between an
# untrusted fork PR and code execution on this VM. Placed EARLY (before any
# download/register/token-mint work) so an unsafe public repo aborts before
# touching anything. See RUNNER.md "The security model" +
# fork-pr-approval-check.sh's header for the full threat writeup + the two
# verified gh endpoints this depends on. Override: MACF_RUNNER_SKIP_FORK_APPROVAL_CHECK=1.
# shellcheck source=./fork-pr-approval-check.sh
. "$HERE/fork-pr-approval-check.sh"
check_fork_pr_approval || exit 2

# 1. token — precedence: --token (explicit) > auto-mint (your gh admin creds) > interactive prompt.
#    The bot's own creds are ALWAYS 403 on administration:write, so auto-mint runs as the
#    INVOKING operator, not root/macf-runner — under sudo that's $SUDO_USER's stored `gh auth`,
#    reached via `sudo -u` WITHOUT -E so a bot GH_TOKEN sitting in this root shell's env can't
#    leak into the operator's call (sudo -u resets HOME too, so gh reads the operator's own config).
mint_token() {
  # $1 = registration-token | remove-token ; prints the token to stdout on success, nothing on failure
  local endpoint="$1" who tok
  local gh_as=(gh)
  who="$(id -un)"
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    gh_as=(sudo -u "$SUDO_USER" -- gh)
    who="$SUDO_USER"
  fi
  tok="$("${gh_as[@]}" api -X POST "/repos/$REPO/actions/runners/$endpoint" --jq '.token' 2>/dev/null)"
  if [ -n "$tok" ] && [ "$tok" != "null" ]; then
    echo "  ✓ auto-minted $endpoint via ${who}'s gh credentials" >&2
    printf '%s' "$tok"
  fi
}

if [ -z "$TOKEN" ]; then
  TOKEN="$(mint_token registration-token)"
fi
if [ -z "$TOKEN" ]; then
  if [ -t 0 ]; then
    echo "Auto-mint failed — the active gh credentials likely lack admin / administration:write on $REPO" >&2
    echo "(the bot's credentials are ALWAYS 403 on this endpoint by design)." >&2
    echo "Mint one at: https://github.com/$REPO/settings/actions/runners" >&2
    echo "  or: gh api -X POST /repos/$REPO/actions/runners/registration-token --jq .token" >&2
    read -r -p "Paste the registration-token: " TOKEN
  else
    echo "FATAL: no registration token — auto-mint failed and no TTY to prompt." >&2
    echo "       Pass --token <REG_TOKEN>, or mint one yourself:" >&2
    echo "       gh api -X POST /repos/$REPO/actions/runners/registration-token --jq .token" >&2
    exit 2
  fi
fi
[ -n "$TOKEN" ] || { echo "FATAL: no registration token" >&2; exit 2; }

# 2. download the runner tarball into the (macf-runner-owned) dir
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_DIR"
if [ \! -f "$RUNNER_DIR/config.sh" ]; then
  TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  echo "downloading actions/runner $RUNNER_VERSION ..."
  sudo -u "$RUNNER_USER" bash -c "cd '$RUNNER_DIR' && curl -fsSL -o '$TARBALL' \
    'https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}' \
    && tar xzf '$TARBALL' && rm -f '$TARBALL'"
fi

# 3. register (as macf-runner — correct _work ownership). NON-ephemeral unless --ephemeral.
# --replace: if a runner with this name is ALREADY registered on GitHub (e.g. a prior install's
# local dir was deleted out from under it, leaving a stale GitHub-side registration), replace it
# instead of failing "a runner with that name already exists". Idempotent re-registration; safe
# because the name is per-repo. (The LOCAL clean-slot is still uninstall's job — see the header.)
EPH=""; [ "$EPHEMERAL" -eq 1 ] && EPH="--ephemeral"
sudo -u "$RUNNER_USER" bash -c "cd '$RUNNER_DIR' && ./config.sh \
  --url 'https://github.com/$REPO' --token '$TOKEN' \
  --name 'macf-vm-$(hostname -s)' --labels '$LABELS' --unattended --replace $EPH"

# 3b. Lever B (action-archive-cache) — arm the runner's .env BEFORE the service starts (the
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

# 4. install + start the svc.sh systemd service (runs as macf-runner)
( cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER" && ./svc.sh start )

# 5. install the Restart=always oversight drop-in (the svc.sh unit omits Restart= → a crash
#    leaves it dead; #90). Assert it took. Filtered by THIS repo's slug — with multiple
#    runners on one host, an unfiltered `head -1` can grab a SIBLING runner's service
#    (devops-toolkit multi-runner-per-host fix) and apply the drop-in to the wrong unit.
SVC="$(systemctl list-units --type=service --all 2>/dev/null | grep -oE "actions\.runner\.${REPO_SLUG}\.[^ ]+\.service" | head -1)"
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
