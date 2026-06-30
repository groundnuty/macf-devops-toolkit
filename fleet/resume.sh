#!/usr/bin/env bash
#
# resume.sh — act on a STALLED or BLOCKED idle agent: nudge it to continue, or
# REPORT it when it's silently waiting on an operator-input prompt.
#
# THE load-bearing automation primitive (operator, 2026-06-28): agents stop after
# each turn and wait. An idle agent is one of three things, and only the pane tells
# them apart — so this is the unattended-operation family's "idle + pane-signature →
# action" dispatcher, with a per-signature `action` (the operator's "one allowlist,
# not three scripts" frame, #129/#132/DR-033):
#
#   - idle-CLEAN (no signature)        → legitimately idle/done → DO NOTHING (no spam).
#   - idle-STALLED (rate-limit/aborted) → action=nudge: "please continue" (#129/#131).
#   - idle-BLOCKED (permission/trust/   → action=report: a DURABLE operator alert —
#     skill/memory prompt)                NEVER auto-answered (#132).
#   - (ceremony launch-prompt           → action=answer: DR-033's auto-responder, code's
#     dev-channels/resume ack)             macf#645/#646 — plugs into this same allowlist.)
#
# Why NUDGE-not-restart: a restart loses in-progress work AND (for a rate-limit) re-hits
# the limit; a nudge resumes the SAME session, preserving its work — the gentlest recovery
# (approves nothing, destroys nothing).
#
# Why REPORT-not-answer for operator-input prompts (#132): a permission / trust / skill /
# memory prompt is an AUTHORIZATION decision — it requires human judgment (DR-033's
# ceremony-not-authorization invariant FORBIDS auto-answering it). So the correct
# automation is NOT to answer it but to make the silent block LOUD: a durable,
# operator-reachable alert ("agent X is blocked on Y — needs your input"). An away
# operator otherwise has no way to know an agent is idle-because-blocked vs idle-because-
# done — it strands indefinitely. The report is the non-negotiable floor; auto-answer
# (DR-033) is the constrained ceiling for the ceremony subset only.
#
# SAFETY CONTRACT (allowlist-only; a wrong action is low-blast-radius but spam is real):
#   - **Allowlist-only.** Act ONLY on an idle agent whose recent pane matches a KNOWN
#     signature. A clean-idle agent (NO signature) is legitimately idle/done → never
#     touched (no spam, no waking a finished agent, no false alert).
#   - **Idle-gate.** Never act on a BUSY agent — it's working. Busy = pane CONTENT
#     changing over the window (CAPTURE-PANE-DIFF, NOT tmux session_activity, which is
#     NOT a reliable busy signal — verified 2026-06-28, devops + science: an output-loop
#     leaves session_activity STABLE while the captured pane content changes).
#   - **Verify-resumed (nudge only).** After a nudge, confirm the pane started changing
#     (capture-pane-diff). If not (still throttled / RC-bound) → back off, don't re-spam.
#   - **Report-never-answers.** The report action only ALERTS — it never send-keys into
#     an authorization prompt.
#   - **Fire-cap + per-episode reset.** Cap actions per episode; reset the counter when
#     the agent returns to idle-clean (the episode ended) so a fresh episode re-fires.
#
# DRY-RUN BY DEFAULT — detects + prints the plan; `--execute` nudges / raises alerts.
#
# Refs: design/DR-006-vm-cron-watchdog-agent-supervision-impl.md ; macf DR-031 ;
#       macf-devops-toolkit#129 (rate-limit resilience) ; #132 (operator-blocked report) ;
#       macf DR-033 (sibling allowlist / ceremony-not-authorization).

set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST="${MACF_DESIRED_AGENTS:-$HOME/.macf/desired-agents.yaml}"
SIG_FILE="${MACF_STALL_SIGNATURES:-fleet/stall-signatures.json}"
STATE_DIR="${MACF_RESUME_STATE:-$HOME/.macf/resume-state}"   # per-agent fire-counter
PANE_LINES="${MACF_RESUME_PANE_LINES:-40}"                   # how many tail lines to scan
ALERT_REPO="${MACF_ALERT_REPO:-groundnuty/macf-devops-toolkit}"  # where report-alerts land
ALERT_LABEL="${MACF_ALERT_LABEL:-operator-blocked}"          # best-effort label on the alert
EXECUTE=0

usage() {
  cat <<USAGE
resume.sh — act on stalled/blocked idle agents (allowlist-only; dry-run by default)

  --manifest <path>   desired-agents.yaml (default: \$HOME/.macf/desired-agents.yaml)
  --signatures <file> signature allowlist (default: fleet/stall-signatures.json)
  --state-dir <dir>   per-agent fire-counter dir (default: \$HOME/.macf/resume-state)
  --alert-repo <r>    repo for operator-blocked REPORT alerts (default: $ALERT_REPO)
  --execute           ACTUALLY nudge / raise alerts (else dry-run: print the plan)
  -h, --help

Per-signature \`action\`: nudge (resume a stalled agent) | report (raise a durable
operator alert for an idle agent blocked on a permission/trust/skill/memory prompt —
NEVER auto-answered). A clean-idle agent (no signature) is never touched.
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)   MANIFEST="$2"; shift 2 ;;
    --signatures) SIG_FILE="$2"; shift 2 ;;
    --state-dir)  STATE_DIR="$2"; shift 2 ;;
    --alert-repo) ALERT_REPO="$2"; shift 2 ;;
    --execute)    EXECUTE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "resume.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null   || { echo "FATAL: jq not found" >&2; exit 2; }
command -v tmux >/dev/null  || { echo "FATAL: tmux not found" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "FATAL: manifest not found: $MANIFEST" >&2; exit 2; }
[ -f "$SIG_FILE" ] || { echo "FATAL: signatures not found: $SIG_FILE" >&2; exit 2; }

# desired agents (kebab routing-label; workspace unused here)
AGENTS="$(awk '/^[[:space:]]*-[[:space:]]*agent:/ { sub(/^[^:]*:[[:space:]]*/,""); gsub(/[[:space:]]|["'\'']/,""); print }' "$MANIFEST")"
[ -n "$AGENTS" ] || { echo "FATAL: manifest has no agents" >&2; exit 2; }

# is the agent's pane IDLE? 0(true)=idle, 1=busy/no-session.
# CAPTURE-PANE-DIFF, not tmux session_activity (NOT a reliable busy signal — verified
# 2026-06-28, devops + science: an output-loop leaves session_activity STABLE while the
# captured pane content CHANGES). A working agent is busy via pane OUTPUT (spinner /
# streaming / tool renders), so pane-content stable over the window = idle; changing = busy.
pane_idle() {
  local sess="macf@$1" a b
  tmux has-session -t "$sess" 2>/dev/null || return 1   # gone → not idle (resume can't help)
  a="$(tmux capture-pane -t "$sess" -p 2>/dev/null | md5sum)"
  sleep 2
  b="$(tmux capture-pane -t "$sess" -p 2>/dev/null | md5sum)"
  [ "$a" = "$b" ]                                        # unchanged → idle
}

# first signature (by name) matching the agent's recent pane, else ""
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

# report_blocked <agent> <sig> <summary> — raise a DURABLE, dedup'd, operator-reachable
# alert (a GitHub issue: an away operator gets a notification; a forensic-log file alone
# wouldn't reach them). Dedup via an open-issue title-search so a re-run (or a lost
# counter) doesn't double-file. NEVER send-keys — an authorization prompt needs a human.
report_blocked() {
  local agent="$1" sig="$2" summary="$3"
  local title="operator-input blocked: $agent ($sig)"
  command -v gh >/dev/null || { echo "       WARN: gh not found — cannot raise alert (log only): $title" >&2; return 0; }
  local existing
  existing="$(gh issue list --repo "$ALERT_REPO" --state open --search "in:title \"$title\"" \
    --json number --jq '.[0].number // empty' 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    echo "       (dedup: alert #$existing already open for $agent)"; return 0
  fi
  local body
  body="$(cat <<BODY
**Agent \`$agent\` is idle-BLOCKED, not idle-done** — silently waiting on an operator-input prompt.

- **Signature:** \`$sig\`
- **What:** $summary
- **Detected by:** the DR-006 watchdog / \`fleet/resume.sh\` (capture-pane-diff idle + prompt-signature match).

**Action needed:** attach to the agent's TUI and respond to the prompt:

    tmux attach -t macf@$agent

This alert was raised because the prompt is an **authorization** decision that the
fleet must NOT auto-answer (DR-033 ceremony-not-authorization). It auto-dedups (one
open alert per agent per episode); close it once you've handled the prompt.

Refs: macf-devops-toolkit#132 ; silent-fallback-hazards.md (idle-blocked is invisible
unless surfaced).
BODY
)"
  if gh issue create --repo "$ALERT_REPO" --title "$title" --body "$body" \
       --label "$ALERT_LABEL" >/dev/null 2>&1; then
    echo "       alert raised on $ALERT_REPO: \"$title\""
  elif gh issue create --repo "$ALERT_REPO" --title "$title" --body "$body" >/dev/null 2>&1; then
    # label may not exist on the repo — retry unlabeled rather than fail the report
    echo "       alert raised on $ALERT_REPO (unlabeled — '$ALERT_LABEL' absent): \"$title\""
  else
    echo "       WARN: alert-issue create FAILED (gh/token/repo?) — block NOT surfaced: $title" >&2
    return 1
  fi
}

# --- detect + act ------------------------------------------------------------
echo "Resume sweep — nudge stalled / report blocked agents  [$([ "$EXECUTE" -eq 1 ] && echo EXECUTE || echo dry-run)]"
printf '%-16s %-10s %s\n' "AGENT" "STATE" "ACTION"
printf '%-16s %-10s %s\n' "-----" "-----" "------"
acted=0
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
    # idle-clean: the episode (if any) ended → reset the fire-counters so a future
    # stall/block re-fires (per-episode cap, not lifetime).
    [ "$EXECUTE" -eq 1 ] && rm -f "$STATE_DIR/$agent" "$STATE_DIR/$agent.report" 2>/dev/null || true
    printf '%-16s %-10s %s\n' "$agent" "idle-clean" "skip (no signature — legitimately idle/done, never touched)"
    continue
  fi

  action="$(sig_field "$sig" action)"; [ -n "$action" ] || action="nudge"

  if [ "$action" = "report" ]; then
    # idle-BLOCKED on an operator-input prompt → REPORT (durable, never auto-answer).
    cap="$(sig_field "$sig" max_fires)"; [ -n "$cap" ] || cap=1
    rf="$STATE_DIR/$agent.report"; rn=$(( $(cat "$rf" 2>/dev/null || echo 0) ))
    summary="$(sig_field "$sig" report)"; [ -n "$summary" ] || summary="blocked on an operator-input prompt — needs your input"
    if [ "$rn" -ge "$cap" ]; then
      printf '%-16s %-10s %s\n' "$agent" "blocked" "skip ($sig: already reported this episode — operator notified)"
      continue
    fi
    acted=$((acted+1))
    if [ "$EXECUTE" -ne 1 ]; then
      printf '%-16s %-10s %s\n' "$agent" "blocked" "[dry-run] REPORT ($sig): $summary → durable operator alert (NOT auto-answered)"
      continue
    fi
    printf '%-16s %-10s %s\n' "$agent" "blocked" "[EXECUTE] REPORT ($sig) → raising operator alert (never auto-answered)"
    report_blocked "$agent" "$sig" "$summary" || true
    mkdir -p "$STATE_DIR"; echo "$((rn+1))" > "$rf"
    continue
  fi

  # action=nudge (default): idle-STALLED → nudge to continue. Fire-cap.
  cap="$(sig_field "$sig" max_fires)"; [ -n "$cap" ] || cap=3
  sf="$STATE_DIR/$agent"; n=$(( $(cat "$sf" 2>/dev/null || echo 0) ))
  if [ "$n" -ge "$cap" ]; then
    printf '%-16s %-10s %s\n' "$agent" "stalled" "skip ($sig: fire-cap $cap reached → escalate, not re-nudge)"
    continue
  fi
  msg="$(sig_field "$sig" nudge)"; [ -n "$msg" ] || msg="Please continue your work."
  acted=$((acted+1))
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
[ "$acted" -eq 0 ] && echo "No stalled/blocked agents needing action." || echo "$acted agent(s) $([ "$EXECUTE" -eq 1 ] && echo "acted on" || echo "would be acted on (dry-run)")."
exit 0
