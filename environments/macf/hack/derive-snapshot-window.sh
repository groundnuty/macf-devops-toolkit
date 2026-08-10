#!/usr/bin/env bash
#
# derive-snapshot-window.sh — resolve the actor + the ACTIVITY window for a
# snapshot of work on a GitHub issue/PR (macf-devops-toolkit#177).
#
# WHY THIS EXISTS
#
# The window used to be the issue's `createdAt → closedAt`. For an issue that
# lived a month that is absurd: #163 yielded a 903-hour span, asking the backends
# to serve 37 days to capture maybe 40 minutes of actual work — past Tempo's
# retention, and diluted by everything else that agent did in between. The
# script's own header always documented the better intent ("union of [t-Δ, t+Δ]
# around each event by actor, collapsed"); the code just never implemented it.
# Code and doc had drifted, with the DOC being the correct one.
#
# So: cluster around the moments the actor actually DID something.
#
#   1. collect every timeline timestamp attributable to the resolved actor
#      (issue open, their comments, the close)
#   2. expand each into [t-Δ, t+Δ]
#   3. merge overlapping/adjacent intervals into disjoint activity clusters
#   4. reduce to ONE (start, end) for the single-window query layer, CLAMPING
#      to --max-span when the clusters are spread far apart
#
# On the clamp: when clusters are far apart, no single window honestly represents
# them. Rather than silently returning a 903-hour span (or silently returning
# only part of the work), we keep the MOST RECENT --max-span of activity — the
# session that closed the issue, which is what a per-issue snapshot is usually
# for — and report exactly what was dropped so the manifest can say so out loud.
# A bundle that quietly covers less than it claims is the failure mode this whole
# repo spent the day removing.
#
# DUAL-PURPOSE FILE: sourcing it defines the pure functions (no gh, no network)
# for unit tests; executing it runs the CLI.
#
# Usage:
#   derive-snapshot-window.sh --repo <owner/repo> --issue <N> [--delta 300] [--max-span 21600]
#   derive-snapshot-window.sh --events-file <json> --actor <login> [...]   # tests, no gh
#
# Emits KEY=VALUE on stdout (shell/GITHUB_OUTPUT friendly):
#   filter_value, start, end, windows_json, clusters_total, clusters_kept,
#   clamped, span_requested, span_actual, coverage_seconds

set -uo pipefail

DELTA_DEFAULT=300        # ±5 min around each event, per the documented intent
MAX_SPAN_DEFAULT=21600   # 6h — a generous single working session

# --- pure core (unit-tested; no gh, no network) ------------------------------

# _dsw_merge <delta> — epochs on stdin (any order), one per line.
# Emits disjoint merged intervals "start end", ascending. Intervals that touch
# or overlap after ±delta expansion are collapsed into one cluster.
_dsw_merge() {
  local delta="$1"
  sort -n | awk -v d="$delta" '
    NF {
      s = $1 - d; e = $1 + d
      if (!started) { cs = s; ce = e; started = 1; next }
      if (s <= ce) { if (e > ce) ce = e }        # overlap/adjacent -> extend
      else { print cs, ce; cs = s; ce = e }      # gap -> emit and restart
    }
    END { if (started) print cs, ce }
  '
}

# _dsw_reduce <max_span> — merged intervals "start end" on stdin.
# Reduces to a single (start,end) for the single-window query layer, keeping the
# MOST RECENT clusters that fit within max_span. Emits:
#   start end clusters_total clusters_kept clamped coverage_seconds
# clamped=1 means earlier activity was deliberately excluded and the caller MUST
# surface that (never let a clamp be silent).
_dsw_reduce() {
  local max_span="$1"
  awk -v max="$max_span" '
    # n MUST be initialised: an uninitialised awk variable used as a SUBSCRIPT is
    # the empty string, not 0 — so `s[n]` would write s[""] while the END block
    # reads s[0] and finds nothing. Silent, and it yields a plausible-looking
    # all-zero window rather than an error.
    BEGIN { n = 0 }
    { s[n] = $1; e[n] = $2; n++ }
    END {
      if (n == 0) { print "0 0 0 0 0 0"; exit }
      end_all = e[n-1]
      kept = 0; cov = 0; start_all = s[n-1]
      # walk newest -> oldest, keeping clusters while the span still fits
      for (i = n-1; i >= 0; i--) {
        if (end_all - s[i] > max) break
        start_all = s[i]; kept++; cov += (e[i] - s[i])
      }
      if (kept == 0) {          # a single cluster wider than max: truncate it
        start_all = end_all - max; kept = 1; cov = max
      }
      clamped = (kept < n) ? 1 : 0
      # a lone cluster that had to be truncated is also a clamp
      if (n == 1 && (e[0] - s[0]) > max) clamped = 1
      print start_all, end_all, n, kept, clamped, cov
    }
  '
}

# _dsw_windows_json — merged intervals "start end" on stdin -> JSON array.
_dsw_windows_json() {
  awk 'BEGIN { printf "[" ; first=1 }
       NF { if (!first) printf ","; printf "{\"start\":%d,\"end\":%d}", $1, $2; first=0 }
       END { printf "]" }'
}

# --- CLI ---------------------------------------------------------------------

_dsw_main() {
  local REPO="" ISSUE="" EVENTS_FILE="" ACTOR_OVERRIDE=""
  local DELTA="$DELTA_DEFAULT" MAX_SPAN="$MAX_SPAN_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)        REPO="$2"; shift 2 ;;
      --issue)       ISSUE="$2"; shift 2 ;;
      --events-file) EVENTS_FILE="$2"; shift 2 ;;
      --actor)       ACTOR_OVERRIDE="$2"; shift 2 ;;
      --delta)       DELTA="$2"; shift 2 ;;
      --max-span)    MAX_SPAN="$2"; shift 2 ;;
      -h|--help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "derive-snapshot-window.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  # RAW shape: {"issue": <gh issue view json>, "timeline": [<REST timeline events>]}
  local RAW ACTOR
  if [ -n "$EVENTS_FILE" ]; then
    [ -r "$EVENTS_FILE" ] || { echo "FATAL: --events-file not readable: $EVENTS_FILE" >&2; exit 2; }
    RAW="$(cat "$EVENTS_FILE")"
    ACTOR="$ACTOR_OVERRIDE"
  else
    [ -n "$REPO" ] && [ -n "$ISSUE" ] || { echo "FATAL: need --repo and --issue (or --events-file)" >&2; exit 2; }
    command -v gh >/dev/null || { echo "FATAL: gh not on PATH — this runs where credentials live (the runner or an operator shell), NOT the VM" >&2; exit 2; }

    # NOTE: `gh issue view --json closedBy` does NOT exist (this gh rejects it as
    # an unknown field). The previous derivation asked for it behind
    # `2>/dev/null || true`, so the error was swallowed and it ALWAYS silently
    # fell through to the assignee/author fallback — which looked correct only
    # because a self-filed issue's author is usually its closer. The REST
    # timeline is the real source for "who closed it", and it also carries every
    # other actor-attributed event, which is exactly what the clustering needs.
    local ISSUE_JSON TIMELINE_JSON
    ISSUE_JSON="$(gh issue view "$ISSUE" --repo "$REPO" --json author,createdAt,closedAt,assignees 2>&1)" \
      || { echo "FATAL: gh issue view failed for $REPO#$ISSUE: $ISSUE_JSON" >&2; exit 2; }
    TIMELINE_JSON="$(gh api "/repos/$REPO/issues/$ISSUE/timeline" --paginate 2>&1)" \
      || { echo "FATAL: timeline fetch failed for $REPO#$ISSUE: $TIMELINE_JSON" >&2; exit 2; }
    RAW="$(jq -n --argjson i "$ISSUE_JSON" --argjson t "$TIMELINE_JSON" '{issue:$i, timeline:$t}')" \
      || { echo "FATAL: could not assemble issue+timeline JSON" >&2; exit 2; }

    # closer (last `closed` event) → first assignee → author.
    ACTOR="$(printf '%s' "$RAW" | jq -r '
        ([.timeline[]? | select(.event=="closed") | (.actor.login // empty)] | last)
        // .issue.assignees[0].login // .issue.author.login // empty')"
  fi

  local FILTER_VALUE
  FILTER_VALUE="$(printf '%s' "$ACTOR" | sed -e 's,^app/,,' -e 's,\[bot\]$,,')"
  if [ -z "$FILTER_VALUE" ]; then
    echo "FATAL: could not resolve an actor (closedBy/assignee/author all empty)." >&2
    echo "       A snapshot filtered on an empty gen_ai.agent.name bundles nothing." >&2
    exit 1
  fi

  # Every timestamp attributable to THIS actor. Anything by someone else is not
  # this agent's working window and would only pad the query.
  local EPOCHS
  EPOCHS="$(printf '%s' "$RAW" | jq -r --arg a "$ACTOR" '
      [ (if (.issue.author.login // "") == $a then .issue.createdAt else empty end),
        ( .timeline[]?
          | select(((.actor.login // .user.login) // "") == $a)
          | (.created_at // .submitted_at // empty) )
      ] | .[] | select(. != null and . != "")
    ' | while read -r ts; do date -u -d "$ts" +%s 2>/dev/null || true; done)"

  if [ -z "$EPOCHS" ]; then
    echo "FATAL: no timeline events attributable to '$ACTOR' on $REPO#$ISSUE." >&2
    echo "       Refusing to guess a window — an arbitrary one produces a bundle that" >&2
    echo "       looks authoritative and isn't." >&2
    exit 1
  fi

  local MERGED REDUCED
  MERGED="$(printf '%s\n' "$EPOCHS" | _dsw_merge "$DELTA")"
  REDUCED="$(printf '%s\n' "$MERGED" | _dsw_reduce "$MAX_SPAN")"
  read -r START END N_TOTAL N_KEPT CLAMPED COVERAGE <<<"$REDUCED"

  local FIRST_EVENT LAST_EVENT SPAN_REQUESTED
  FIRST_EVENT="$(printf '%s\n' "$MERGED" | head -1 | awk '{print $1}')"
  LAST_EVENT="$(printf '%s\n' "$MERGED" | tail -1 | awk '{print $2}')"
  SPAN_REQUESTED=$((LAST_EVENT - FIRST_EVENT))

  if [ "$CLAMPED" = "1" ]; then
    echo "WARNING: activity spans ${SPAN_REQUESTED}s across $N_TOTAL clusters — wider than --max-span ${MAX_SPAN}s." >&2
    echo "         Keeping the most recent $N_KEPT cluster(s); EARLIER ACTIVITY IS EXCLUDED." >&2
    echo "         This is recorded in the manifest — the bundle must not imply coverage it doesn't have." >&2
  fi

  # Emit the manifest provenance as ONE ready-to-pass JSON value. Callers must
  # never hand-assemble this: the first attempt built it inline in the workflow's
  # YAML `run:` block, where the escaped `\"` literals collided with the real
  # quotes coming from the windows_json substitution. The result split into
  # multiple shell words, the script saw garbage args and printed its usage, and
  # the run failed at the LAST step. One value, quoted once, at the source.
  local PROVENANCE_JSON
  PROVENANCE_JSON="$(jq -cn \
      --argjson windows "$(printf '%s\n' "$MERGED" | _dsw_windows_json)" \
      --argjson total "$N_TOTAL" --argjson kept "$N_KEPT" --argjson clamped "$CLAMPED" \
      --argjson span "$SPAN_REQUESTED" --argjson coverage "$COVERAGE" \
      '{windows:$windows, clusters_total:$total, clusters_kept:$kept,
        clamped:$clamped, span_requested_seconds:$span, coverage_seconds:$coverage}')"

  cat <<OUT
filter_value=$FILTER_VALUE
start=$START
end=$END
provenance_json=$PROVENANCE_JSON
windows_json=$(printf '%s\n' "$MERGED" | _dsw_windows_json)
clusters_total=$N_TOTAL
clusters_kept=$N_KEPT
clamped=$CLAMPED
span_requested=$SPAN_REQUESTED
span_actual=$((END - START))
coverage_seconds=$COVERAGE
OUT
}

# Only run when EXECUTED; sourcing (tests) just defines the pure functions.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  _dsw_main "$@"
fi
