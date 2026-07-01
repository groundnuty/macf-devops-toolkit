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
SEND_HELPER="$RUNNER_HOME/tmux-send-to-claude.sh"
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
if [ -x "$SEND_HELPER" ]; then ck "send helper present + executable"
else bad "send helper missing / not executable ($SEND_HELPER)"; fi

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

# 6. GitHub-side 'registered + online' — needs administration:read (bot is 403); operator/gh-side
wrn "GitHub-side registered+online NOT checked here — verify in Settings→Actions→Runners (needs admin)"

echo
if [ "$fail" -gt 0 ]; then echo "→ $fail FAIL / $warn warn — NOT healthy for $REPO"; exit 1; fi
echo "→ healthy for $REPO ($warn warn)"
