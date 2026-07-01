#!/usr/bin/env bash
#
# upgrade.sh — the DR-006 §A.7 / DR-007 ROLLING VERSION-UPGRADE (VM reference impl):
# reconcile the *version* dimension of desired state (reconcile.sh handles the set;
# this handles the version — desired-{set, version}).
#
# "See the fleet auto-upgrade itself": for each desired agent whose running
# channel-server version is behind the TARGET, roll it forward ONE AT A TIME —
# **busy-gate** (never interrupt a working agent) → bump the workspace pins → graceful
# restart → verify it comes up healthy on the target → only then the next agent. Rolling
# + verify-green-before-next = a bad release can't take the whole fleet down at once (it
# HALTS at the first agent that fails to come up on the target).
#
# This is the DR-007 VM DRIVER + a VM-coupled decision layer (it reads /proc + tmux — a
# CONSCIOUS reference-impl violation of DR-007's "nothing runtime-specific above the driver
# line"; the CANONICAL `macf fleet upgrade` (macf#682) stays runtime-agnostic on the
# /health self-report so Linux/macOS/K8s fall out of one design).
#
# DRY-RUN BY DEFAULT — detects + prints the PLAN (incl. busy-skips); `--execute` rolls it.
# Unattended --execute is blocked on macf#645 (a relaunched agent hangs at the channels/
# resume launch-prompts until #645's auto-responder clears them); ATTENDED works today
# (the operator clicks through). A permission/trust prompt at launch still blocks-and-
# reports by design (#132) — so unattended needs the relaunch to be ceremony-only.
#
# Refs: design/DR-007-fleet-upgrade-orchestration.md ; DR-006 §A.7 ; macf DR-031 ; macf#682.

set -euo pipefail

cd "$(dirname "$0")/.."   # repo root (for cert paths)
MANIFEST="${MACF_DESIRED_AGENTS:-$HOME/.macf/desired-agents.yaml}"
TARGET=""                # --target <ver>; default = npm latest channel-server
CA="${MACF_CA_CERT_FILE:-$HOME/.macf/certs/macf/ca-cert.pem}"
CERT="${MACF_AGENT_CERT:-.macf/certs/agent-cert.pem}"
KEY="${MACF_AGENT_KEY:-.macf/certs/agent-key.pem}"
ADV_HOST="${MACF_ADVERTISE_HOST:-orzech-dev-agents.tail491af.ts.net}"
REGISTRY_OWNER="${MACF_REGISTRY_OWNER:-groundnuty/groundnuty}"
LAST_EXIT_DIR="${MACF_LAST_EXIT_DIR:-$HOME/.macf/last-exit}"
PANE_LINES="${MACF_UPGRADE_PANE_LINES:-40}"
VERIFY_TIMEOUT="${MACF_UPGRADE_VERIFY_TIMEOUT:-120}"   # secs to wait for the target to come up green
VERIFY_INTERVAL="${MACF_UPGRADE_VERIFY_INTERVAL:-6}"
EXECUTE=0

usage() {
  cat <<USAGE
upgrade.sh — DR-007 rolling version-upgrade, VM reference impl (detect+plan; --execute rolls)

  --manifest <path>  desired-agents.yaml (default: \$HOME/.macf/desired-agents.yaml)
  --target <ver>     target channel-server version (default: npm latest)
  --execute          ACTUALLY roll the upgrade (else dry-run: print the plan)
  -h, --help

Rolls ONE agent at a time, BUSY-GATED (skips + reports a working agent — never interrupts),
verify-green-before-next (a bad release HALTS the roll). Needs GH_TOKEN (registry port
lookup) + the agent mTLS cert. Unattended --execute is blocked on macf#645 — attended works.
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    --target)   TARGET="$2"; shift 2 ;;
    --execute)  EXECUTE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "upgrade.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null   || { echo "FATAL: jq not found" >&2; exit 2; }
command -v curl >/dev/null  || { echo "FATAL: curl not found" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "FATAL: manifest not found: $MANIFEST" >&2; exit 2; }
# GH_TOKEN + npm are only needed for the LIVE paths; the offline test seams bypass them.
if [ "${MACF_TEST_LIVE_VERSIONS+set}" != set ]; then
  [ -n "${GH_TOKEN:-}" ] || { echo "FATAL: GH_TOKEN unset (needed for the registry port lookup)" >&2; exit 2; }
fi

# target = npm latest if not given
if [ -z "$TARGET" ]; then
  TARGET="$(npm view @groundnuty/macf-channel-server version 2>/dev/null || true)"
  [ -n "$TARGET" ] || { echo "FATAL: could not resolve npm-latest target (pass --target)" >&2; exit 2; }
fi

# desired agents (kebab routing-label \t workspace), same parse as reconcile.sh
DESIRED="$(awk '
  function clean(s){ sub(/[[:space:]]*#.*$/,"",s); gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); gsub(/^["'\'']|["'\'']$/,"",s); return s }
  /^[[:space:]]*-[[:space:]]*agent:/ { sub(/^[^:]*:[[:space:]]*/,""); ag=clean($0); next }
  /^[[:space:]]*workspace:/ && ag!="" { sub(/^[^:]*:[[:space:]]*/,""); print ag "\t" clean($0); ag="" }
' "$MANIFEST")"
[ -n "$DESIRED" ] || { echo "FATAL: manifest has no agents" >&2; exit 2; }

# registry key for an agent's routing-label: devops-agent -> MACF_AGENT_DEVOPS_AGENT
reg_key() { echo "MACF_AGENT_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"; }

# live channel-server version for an agent (mTLS /health.version); "" if unreachable.
# Test seam: MACF_TEST_LIVE_VERSIONS="agent=ver ..." (DEFINED ⇒ authoritative, skip mTLS).
live_version() {
  local agent="$1"
  if [ "${MACF_TEST_LIVE_VERSIONS+set}" = set ]; then
    printf '%s\n' $MACF_TEST_LIVE_VERSIONS | awk -F= -v a="$agent" '$1==a{print $2; f=1} END{if(!f) print ""}'
    return
  fi
  local port
  port="$(GH_TOKEN=$GH_TOKEN gh api "/repos/$REGISTRY_OWNER/actions/variables/$(reg_key "$agent")" \
            --jq '.value|fromjson|.port' 2>/dev/null || true)"
  [ -n "$port" ] || { echo ""; return; }
  curl -sS --max-time 6 --cacert "$CA" --cert "$CERT" --key "$KEY" \
       "https://$ADV_HOST:$port/health" 2>/dev/null | jq -r '.version // ""' 2>/dev/null || echo ""
}

# plugin-pinned cs version for an agent's workspace ("" if absent — never fails the sweep
# under set -e/pipefail: grep-no-match returns 1, so `|| true` keeps the classify loop alive)
pinned_version() {
  { grep -oE 'channel-server@[0-9.]+' "$1/.macf/plugin/.claude-plugin/plugin.json" 2>/dev/null \
    | head -1 | sed 's/.*@//'; } || true
}

# agent_busy <agent> -> 0(true) if the agent's pane is changing over a short window (WORKING).
# CAPTURE-PANE-DIFF, not session_activity (the #128/#130 lesson). The busy-gate: NEVER
# restart a working agent. Test seam: MACF_TEST_BUSY (DEFINED ⇒ authoritative busy-set).
agent_busy() {
  local agent="$1"
  if [ "${MACF_TEST_BUSY+set}" = set ]; then
    case " $MACF_TEST_BUSY " in *" $agent "*) return 0 ;; *) return 1 ;; esac
  fi
  local sess="macf@$agent" a b
  tmux has-session -t "$sess" 2>/dev/null || return 1   # gone → not busy (down; reconcile.sh relaunches)
  a="$(tmux capture-pane -t "$sess" -p 2>/dev/null | md5sum)"
  sleep 3
  b="$(tmux capture-pane -t "$sess" -p 2>/dev/null | md5sum)"
  [ "$a" != "$b" ]
}

# roll_one <agent> <ws> — the per-agent upgrade step (EXECUTE path). Returns 0 green, 1 fail.
# pin-bump (verified mechanism: the target CLI's `update` bumps the workspace pins + regens
# claude.sh) → graceful SIGTERM (exit 143 → #627 deregister ~1.5s) → detached relaunch
# (claude.sh installs the new pin) → poll /health.version==TARGET + reachable.
roll_one() {
  local agent="$1" ws="$2" sess="macf@$1" pid=""
  echo "    [1/4] bump pins → $TARGET  (npx @groundnuty/macf@$TARGET update --dir $ws --all --yes)"
  ( cd "$ws" && npx -y "@groundnuty/macf@$TARGET" update --dir "$ws" --all --yes >/dev/null 2>&1 ) \
    || { echo "    HALT: pin-bump failed for $agent"; return 1; }
  echo "    [2/4] graceful restart (SIGTERM claude → relaunch claude.sh, new pin installs on launch)"
  for p in $(pgrep -x claude 2>/dev/null || true); do
    [ "$(readlink "/proc/$p/cwd" 2>/dev/null)" = "$ws" ] && pid="$p"
  done
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  sleep 3
  mkdir -p "$LAST_EXIT_DIR"
  tmux kill-session -t "$sess" 2>/dev/null || true
  tmux new-session -d -s "$sess" "cd $ws && MACF_NO_TMUX_WRAP=1 ./claude.sh; echo \$? > $LAST_EXIT_DIR/$agent"
  echo "    [3/4] verify-green: poll /health.version == $TARGET (+ reachable), up to ${VERIFY_TIMEOUT}s"
  local waited=0 lv
  while [ "$waited" -lt "$VERIFY_TIMEOUT" ]; do
    sleep "$VERIFY_INTERVAL"; waited=$((waited+VERIFY_INTERVAL))
    lv="$(live_version "$agent")"
    if [ "$lv" = "$TARGET" ]; then
      echo "    [4/4] GREEN — $agent up on $TARGET (${waited}s). Next agent."
      return 0
    fi
  done
  echo "    HALT: $agent did NOT come up on $TARGET within ${VERIFY_TIMEOUT}s (live=${lv:-down}). Rolling STOPS here"
  echo "          (a bad release cannot take the whole fleet down — the rest stay on their current version)."
  return 1
}

# --- detect + classify -------------------------------------------------------
echo "Rolling version-upgrade — target channel-server@$TARGET  [$([ "$EXECUTE" -eq 1 ] && echo EXECUTE || echo dry-run)]"
printf '%-16s %-9s %-9s %s\n' "AGENT" "LIVE" "PIN" "PLAN"
printf '%-16s %-9s %-9s %s\n' "-----" "----" "---" "----"
ROLL=""   # newline-list of "agent\tws" that are behind-AND-idle (the roll order)
behind=0 busy_skip=0
while IFS=$'\t' read -r agent ws; do
  [ -n "$agent" ] || continue
  lv="$(live_version "$agent")"; pv="$(pinned_version "$ws")"
  if [ "$lv" = "$TARGET" ]; then
    printf '%-16s %-9s %-9s %s\n' "$agent" "${lv:-?}" "${pv:-?}" "OK (at target)"
  elif [ -z "$lv" ]; then
    printf '%-16s %-9s %-9s %s\n' "$agent" "down" "${pv:-?}" "UNREACHABLE — skip (let reconcile.sh heal first)"
  elif agent_busy "$agent"; then
    busy_skip=$((busy_skip+1))
    printf '%-16s %-9s %-9s %s\n' "$agent" "$lv" "${pv:-?}" "BUSY — SKIP + REPORT (never interrupt work; retry next pass / when idle)"
  else
    behind=$((behind+1)); ROLL="$ROLL$agent	$ws
"
    printf '%-16s %-9s %-9s %s\n' "$agent" "$lv" "${pv:-?}" "UPGRADE $lv→$TARGET (bump pins → restart → verify)"
  fi
done <<< "$DESIRED"

echo
[ "$busy_skip" -gt 0 ] && echo "$busy_skip agent(s) BUSY → skipped + reported (not interrupted)."
if [ "$behind" -eq 0 ]; then
  echo "No behind-and-idle agents to upgrade$([ "$busy_skip" -gt 0 ] && echo " (busy ones will roll on a later pass)")."
  exit 0
fi
echo "$behind idle agent(s) behind target → the roll (one at a time, verify-green-before-next):"

if [ "$EXECUTE" -ne 1 ]; then
  n=0
  while IFS=$'\t' read -r agent ws; do
    [ -n "$agent" ] || continue; n=$((n+1))
    echo "  $n. $agent  — bump pins→$TARGET, graceful restart, verify /health.version==$TARGET"
  done <<< "$ROLL"
  echo "(dry-run — re-run with --execute to roll. ATTENDED: the operator clears the channels/resume"
  echo " launch-prompts as each agent comes back. Unattended is blocked on macf#645.)"
  exit 1
fi

# --- EXECUTE: roll one at a time, verify-green-before-next, HALT on failure ---
rolled=0
while IFS=$'\t' read -r agent ws; do
  [ -n "$agent" ] || continue
  echo "── rolling $agent → $TARGET ──"
  if roll_one "$agent" "$ws"; then
    rolled=$((rolled+1))
  else
    echo
    echo "ROLL HALTED at $agent — $rolled agent(s) upgraded, the rest UNCHANGED. Investigate before continuing."
    exit 1
  fi
done <<< "$ROLL"
echo
echo "✓ rolled $rolled agent(s) to channel-server@$TARGET (verify-green each)."
exit 0
