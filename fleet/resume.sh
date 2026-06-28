#!/usr/bin/env bash
#
# resume.sh — nudge a STALLED agent back into motion ("please continue").
#
# THE load-bearing automation primitive (operator, 2026-06-28): agents stop after
# each turn and wait for the next prompt. A transient interruption — a server-side
# rate-limit, an aborted turn — leaves the agent IDLE at its prompt with in-progress
# work abandoned, and the ONLY recovery is to ask it to continue. Without an
# automated nudge, any interruption silently kills the agent's flow until a human
# prompts it. Unattended operation (the DR-006 watchdog / #543) needs this.
#
# Resume is NOT restart: a restart loses the in-progress work AND (for a rate-limit)
# re-hits the limit. A nudge ("continue") resumes the SAME session, preserving its
# work — the gentlest possible recovery (it approves nothing, destroys nothing).
#
# SAFETY CONTRACT (mirrors DR-033's allowlist-only discipline — a wrong nudge is
# low-blast-radius but spam is real):
#   - **Allowlist-only.** Nudge ONLY an idle agent whose recent pane matches a KNOWN
#     stall-signature (rate-limit, etc.). A clean-idle agent (NO signature) is
#     legitimately idle/done → NEVER nudged (no spam, no waking a finished agent).
#   - **Idle-gate.** Never nudge a BUSY agent (session_activity advancing) — it's
#     working; a nudge would interrupt.
#   - **Verify-resumed.** After the nudge, confirm session_activity advanced (the
#     agent woke + is processing). If not (still throttled / RC-bound) → back off,
#     don't re-spam; retry next sweep. This self-corrects the "nudged into an active
#     throttle" case (the limit clears, a later sweep's nudge takes).
#   - **Fire-cap + log.** Cap nudges per stall-episode; log every nudge.
#
# DRY-RUN BY DEFAULT — detects stalls + prints the nudge plan; `--execute` nudges.
#
# Refs: design/DR-006-vm-cron-watchdog-agent-supervision-impl.md ; macf DR-031 ;
#       macf-devops-toolkit#129 (rate-limit resilience) ; macf DR-033 (sibling
#       allowlist discipline).

set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST="${MACF_DESIRED_AGENTS:-$HOME/.macf/desired-agents.yaml}"
SIG_FILE="${MACF_STALL_SIGNATURES:-fleet/stall-signatures.json}"
STATE_DIR="${MACF_RESUME_STATE:-$HOME/.macf/resume-state}"   # per-agent fire-counter
PANE_LINES="${MACF_RESUME_PANE_LINES:-40}"                   # how many tail lines to scan
EXECUTE=0

usage() {
  cat <<USAGE
resume.sh — nudge stalled agents to continue (allowlist-only; dry-run by default)

  --manifest <path>   desired-agents.yaml (default: \$HOME/.macf/desired-agents.yaml)
  --signatures <file> stall-signature allowlist (default: fleet/stall-signatures.json)
  --state-dir <dir>   per-agent fire-counter dir (default: \$HOME/.macf/resume-state)
  --execute           ACTUALLY nudge (else dry-run: print the plan)
  -h, --help

Nudges ONLY an IDLE agent whose pane matches a known stall-signature, verifies it
resumed, fire-caps. A clean-idle agent is NEVER nudged.
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)   MANIFEST="$2"; shift 2 ;;
    --signatures) SIG_FILE="$2"; shift 2 ;;
    --state-dir)  STATE_DIR="$2"; shift 2 ;;
    --execute)    EXECUTE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "resume.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null   || { echo "FATAL: jq not found" >&2; exit 2; }
command -v tmux >/dev/null  || { echo "FATAL: tmux not found" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "FATAL: manifest not found: $MANIFEST" >&2; exit 2; }
[ -f "$SIG_FILE" ] || { echo "FATAL: stall-signatures not found: $SIG_FILE" >&2; exit 2; }

# desired agents (kebab routing-label; workspace unused here)
AGENTS="$(awk '/^[[:space:]]*-[[:space:]]*agent:/ { sub(/^[^:]*:[[:space:]]*/,""); gsub(/[[:space:]]|["'\'']/,""); print }' "$MANIFEST")"
[ -n "$AGENTS" ] || { echo "FATAL: manifest has no agents" >&2; exit 2; }

# is the agent's pane IDLE? 0(true)=idle, 1=busy/no-session.
# Uses CAPTURE-PANE-DIFF, not tmux session_activity: a working Claude agent is busy
# via pane OUTPUT (spinner, streaming, tool renders), and session_activity tracks
# INPUT not output (verified empirically 2026-06-28 — an output-loop leaves
# session_activity STABLE while capture-pane content CHANGES). So pane-content
# stable over the window = idle; changing = busy.
pane_idle() {
  local sess="macf@$1" a b
  tmux has-session -t "$sess" 2>/dev/null || return 1   # gone → not idle (resume can't help)
  a="$(tmux capture-pane -t "$sess" -p 2>/dev/null | md5sum)"
  sleep 2
  b="$(tmux capture-pane -t "$sess" -p 2>/dev/null | md5sum)"
  [ "$a" = "$b" ]                                        # unchanged → idle
}

# first stall-signature (by name) matching the agent's recent pane, else ""
matched_signature() {
  local sess="macf@$1" pane
  pane="$(tmux capture-pane -t "$sess" -p -S -"$PANE_LINES" 2>/dev/null || echo '')"
  [ -n "$pane" ] || { echo ""; return; }
  local n s
  while IFS=$'\t' read -r n s; do
    [ -n "$s" ] || continue
    printf '%s' "$pane" | grep -qiE "$s" && { echo "$n"; return; }
  done < <(jq -r '.[] | [.name, .signature] | @tsv' "$SIG_FILE")
  echo ""
}
sig_field() { jq -r --arg n "$1" '.[] | select(.name==$n) | .'"$2"' // empty' "$SIG_FILE"; }

# --- detect + nudge ----------------------------------------------------------
echo "Resume sweep — nudge stalled agents  [$([ "$EXECUTE" -eq 1 ] && echo EXECUTE || echo dry-run)]"
printf '%-16s %-10s %s\n' "AGENT" "STATE" "ACTION"
printf '%-16s %-10s %s\n' "-----" "-----" "------"
nudged=0
while read -r agent; do
  [ -n "$agent" ] || continue
  if ! tmux has-session -t "macf@$agent" 2>/dev/null; then
    printf '%-16s %-10s %s\n' "$agent" "no-session" "skip (gone — resume can't help; reconcile.sh LAUNCHes)"
    continue
  fi
  if ! pane_idle "$agent"; then
    printf '%-16s %-10s %s\n' "$agent" "busy" "skip (working — never interrupt)"
    continue
  fi
  sig="$(matched_signature "$agent")"
  if [ -z "$sig" ]; then
    printf '%-16s %-10s %s\n' "$agent" "idle-clean" "skip (no stall-signature — legitimately idle/done, NEVER nudge)"
    continue
  fi
  # idle + known stall-signature → candidate. Fire-cap.
  cap="$(sig_field "$sig" max_fires)"; [ -n "$cap" ] || cap=3
  sf="$STATE_DIR/$agent"; n=$(( $(cat "$sf" 2>/dev/null || echo 0) ))
  if [ "$n" -ge "$cap" ]; then
    printf '%-16s %-10s %s\n' "$agent" "stalled" "skip ($sig: fire-cap $cap reached → escalate, not re-nudge)"
    continue
  fi
  msg="$(sig_field "$sig" nudge)"; [ -n "$msg" ] || msg="Please continue your work."
  nudged=$((nudged+1))
  if [ "$EXECUTE" -ne 1 ]; then
    printf '%-16s %-10s %s\n' "$agent" "stalled" "[dry-run] NUDGE ($sig): send \"$msg\" → verify resumed (fire $((n+1))/$cap)"
    continue
  fi
  # EXECUTE: nudge + verify-resumed (capture-pane-diff: did the pane start changing?)
  pre="$(tmux capture-pane -t "macf@$agent" -p 2>/dev/null | md5sum)"
  tmux send-keys -t "macf@$agent" "$msg" Enter 2>/dev/null || true
  mkdir -p "$STATE_DIR"; echo "$((n+1))" > "$sf"
  sleep 3
  post="$(tmux capture-pane -t "macf@$agent" -p 2>/dev/null | md5sum)"
  if [ "$pre" != "$post" ]; then
    printf '%-16s %-10s %s\n' "$agent" "resumed" "[EXECUTE] nudged ($sig) → RESUMED (pane changing); reset counter"
    rm -f "$sf"   # resumed → fresh episode next time
  else
    printf '%-16s %-10s %s\n' "$agent" "stalled" "[EXECUTE] nudged ($sig) → NOT confirmed (still throttled/RC-bound) → back off, retry next sweep ($((n+1))/$cap)"
  fi
done <<< "$AGENTS"

echo
[ "$nudged" -eq 0 ] && echo "No stalled agents needing a nudge." || echo "$nudged stalled agent(s) $([ "$EXECUTE" -eq 1 ] && echo nudged || echo "would be nudged (dry-run)")."
exit 0
