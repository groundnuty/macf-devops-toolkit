#!/usr/bin/env bash
# verify-runner.sh — Pattern-A health check for a self-hosted runner (devops-toolkit#90).
# Asserts the runner's result-INVARIANTS (not "setup exited 0"): the low-priv user, the
# send helper, the sudoers grant, the runner CONFIGURED for the expected repo, and the
# listener process. Run with sudo for the full check (a couple of files are root-owned);
# without sudo it degrades and marks those [skip].
#
#   ./verify-runner.sh --repo groundnuty/macf-science-agent
set -uo pipefail
REPO=""
RUNNER_USER="${MACF_RUNNER_USER:-macf-runner}"
RUNNER_HOME="${MACF_RUNNER_HOME:-/opt/macf-runner}"
RUNNER_DIR="$RUNNER_HOME/actions-runner"
SEND_HELPER="${MACF_SEND_HELPER:-/usr/local/bin/macf-tmux-send.sh}"   # root-owned, per #145 fix
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] || { echo "FATAL: --repo owner/repo required" >&2; exit 2; }

fail=0 warn=0
ck()  { printf '  [ ok ] %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }
wrn() { printf '  [warn] %s\n' "$1"; warn=$((warn+1)); }
skp() { printf '  [skip] %s (run with sudo)\n' "$1"; }

echo "runner health — $REPO  (user=$RUNNER_USER  home=$RUNNER_HOME)"

# 1. low-priv user
id "$RUNNER_USER" >/dev/null 2>&1 && ck "user $RUNNER_USER exists" \
  || bad "user $RUNNER_USER MISSING (run setup-macf-runner-user.sh)"

# 2. send helper — the ONE capability the runner has
if [ -x "$SEND_HELPER" ]; then ck "send helper present + executable ($SEND_HELPER)"
else bad "send helper missing / not executable ($SEND_HELPER)"; fi

# 2b. send helper NON-TAMPERABLE by the runner (science's #145 fix): the sudo-invoked helper
# + every parent dir must be non-writable by $RUNNER_USER, else the grant escalates to $AGENT_USER.
if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" = 0 -o -n "${MACF_CAN_SUDO:-}" ]; then
  tamper="" d="$SEND_HELPER"
  while :; do
    sudo -u "$RUNNER_USER" test -w "$d" 2>/dev/null && { tamper="$d"; break; }
    [ "$d" = "/" ] && break; d="$(dirname "$d")"
  done
  [ -z "$tamper" ] && ck "send helper non-tamperable by $RUNNER_USER (no writable parent)" \
    || bad "$RUNNER_USER CAN WRITE '$tamper' → sudo helper is tamperable = escalation to ${MACF_AGENT_USER:-ubuntu}"
else
  skp "send-helper non-tamperability ($SEND_HELPER + parents not writable by $RUNNER_USER)"
fi

# 3. sudoers grant (needs sudo to read /etc/sudoers.d)
SUDOERS=/etc/sudoers.d/macf-runner
if [ -r "$SUDOERS" ]; then
  grep -q "$RUNNER_USER" "$SUDOERS" && ck "sudoers send-helper grant present" \
    || bad "sudoers file present but no $RUNNER_USER rule"
elif [ "$(id -u)" = 0 ]; then
  [ -f "$SUDOERS" ] && ck "sudoers send-helper grant present" || bad "sudoers grant MISSING ($SUDOERS)"
else skp "sudoers grant ($SUDOERS)"; fi

# 4. runner CONFIGURED for THIS repo — the key invariant: .runner gitHubUrl matches
RC="$RUNNER_DIR/.runner"
if [ -r "$RC" ]; then
  url="$(jq -r '.gitHubUrl // empty' "$RC" 2>/dev/null || true)"
  want="https://github.com/$REPO"
  if [ "$url" = "$want" ]; then ck "configured for $REPO (.runner gitHubUrl matches)"
  else bad "configured for '${url:-<none>}' but expected '$want' (wrong repo / not registered)"; fi
elif [ "$(id -u)" = 0 ]; then bad "no .runner config ($RC) — not registered"
else skp ".runner config ($RC)"; fi

# 5. listener process — informational (only up during a service / measurement window)
if pgrep -u "$RUNNER_USER" -f 'Runner.Listener|run\.sh' >/dev/null 2>&1; then
  ck "listener process RUNNING (serving jobs)"
else
  wrn "listener NOT running — fine if idle/between windows (start via ./run.sh or the systemd unit)"
fi

# 5b. AUTO-RESTART OVERSIGHT (Pattern A: assert the supervisor exists). GitHub's svc.sh unit
# has NO Restart= → a crash (network blip / broker SocketException) leaves the runner dead with
# no restore (observed #90, 2026-07-01). The systemd-restart-override.conf drop-in adds
# Restart=always. Assert it's in effect so a runner missing the oversight is caught here.
if command -v systemctl >/dev/null 2>&1; then
  SVC="$(systemctl list-units --type=service --all 2>/dev/null | grep -oE 'actions\.runner\.[^ ]+\.service' | head -1)"
  if [ -n "$SVC" ]; then
    POLICY="$(systemctl show "$SVC" -p Restart --value 2>/dev/null)"
    if [ "$POLICY" = "always" ]; then ck "auto-restart oversight: $SVC Restart=always"
    else bad "NO auto-restart: $SVC Restart='${POLICY:-<none>}' — a crash leaves it DEAD (install runner/systemd-restart-override.conf)"; fi
  else wrn "no actions.runner systemd service found (foreground/run.sh mode?)"; fi
else
  skp "auto-restart policy (systemctl — Restart=always oversight)"
fi

# 5c. LEVER B (action-archive-cache, #150) — the runner-side latency lever (~2s/job, ~50% of the
# action-fetch phase). Arm = ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE in .env; seed = ≥1 SHA-keyed
# tarball ({cacheDir}/{owner}_{repo}/{sha}.tar.gz). PASS armed+seeded; WARN armed-but-unseeded
# (fresh runner, pre-first-job — seeds via seed-action-cache.sh after the first job); FAIL not armed.
CACHE_DIR="${MACF_ACTION_ARCHIVE_CACHE:-$RUNNER_HOME/action-archive-cache}"
ENV_FILE="$RUNNER_DIR/.env"
if grep -qs '^ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE=' "$ENV_FILE" 2>/dev/null; then
  if ls "$CACHE_DIR"/*/*.tar.gz >/dev/null 2>&1; then
    ck "Lever B armed + seeded ($(ls "$CACHE_DIR"/*/*.tar.gz 2>/dev/null | wc -l | tr -d ' ') archive(s) in $CACHE_DIR)"
  else
    wrn "Lever B armed but UNSEEDED — no *.tar.gz in $CACHE_DIR (fresh runner; seeds after the first job via seed-action-cache.sh)"
  fi
elif [ -r "$ENV_FILE" ] || [ "$(id -u)" = 0 ]; then
  bad "Lever B NOT armed — no ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE in $ENV_FILE (re-run install-runner.sh; jobs pay the full codeload fetch)"
else
  skp "Lever B .env arming ($ENV_FILE)"
fi

# 6. GitHub-side 'registered + online' — needs administration:read (bot is 403); operator/gh-side
wrn "GitHub-side registered+online NOT checked here — verify in Settings→Actions→Runners (needs admin)"

echo
if [ "$fail" -gt 0 ]; then echo "→ $fail FAIL / $warn warn — NOT healthy for $REPO"; exit 1; fi
echo "→ healthy for $REPO ($warn warn)"
