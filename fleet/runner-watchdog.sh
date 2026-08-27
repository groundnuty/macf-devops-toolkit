#!/usr/bin/env bash
#
# runner-watchdog.sh — the RUNNER-side liveness watchdog (macf-devops-toolkit#163),
# the runner-analog of the DR-006 agent watchdog (fleet/reconcile.sh).
#
# WHY: macf-actions v3.4.1's `pick-runner` selects `[self-hosted,macf-vm]` for a
# trusted actor on a NON-fork event with NO liveness check (RUNNER.md "The security
# model", layer 1) — a down self-hosted runner does NOT fall back to github-hosted,
# it makes that repo's trusted routing QUEUE forever. `Restart=always`
# (systemd-restart-override.conf, devops-toolkit#154 / RUNNER.md "Auto-restart
# oversight") auto-recovers a bare process CRASH in ~5s, but NOT a unit that ends up
# `failed`/`inactive` past its restart budget, gets `masked`, or is torn down/
# de-registered entirely — and either way, a systemd-internal restart is SILENT: no
# fleet-visible signal, unlike the agent-watchdog's Tier-1/2/3 ladder + dedup'd
# alerts. This script closes that gap: detect (LOCAL systemd unit state only — no
# GitHub runners API; the bot is 403 on `administration:read`, RUNNER.md "The
# security model") → HEAL (systemctl restart, gated) → ALERT (dedup'd sentinel; a
# torn-down/de-registered unit needs an operator-minted token to re-register, which
# this script cannot do unattended — RUNNER.md "Setup sequence" step 3).
#
# EXTENDED DETECTION — job-wedge (active-but-not-working): the loaded/active
# checks above are a PROXY for runner health ("is the listener process up"), not
# the INVARIANT this watchdog actually exists to protect ("can this runner
# execute a routed job right now"). That proxy has a live blind spot: a runner
# can claim a job, have the claim raced by a same-instant cancellation, and end
# up with its JobDispatcher wedged — no Runner.Worker ever spawned, no
# completion ever logged, the slot never released — while `systemctl` still
# reports `ActiveState=active` because the LISTENER process itself never died.
# Observed live: a runner sat `active` for ~2 HOURS with that repo's routing
# queued dark the entire time, and this watchdog logged "OK" on every 10-minute
# sweep because ActiveState was the only signal it checked. See the "job-wedge
# detection" comment block further down (next to _runner_watchdog_wedge_sample /
# _runner_watchdog_wedge_confirmed) for the full incident evidence and the new
# WEDGED decision branch this adds — same HEAL action (`systemctl restart`,
# same --allow-restart gate), just a distinct label so the sweep table / alert
# text names the real failure instead of a false "not active". Confirmation
# requires TWO samples WEDGE_GRACE_S apart that are not just both wedge-shaped
# but demonstrably the SAME stuck claim (identical journal timestamp) — a
# single shape match, or two shape matches from two DIFFERENT jobs straddling
# the grace window, never confirms WEDGED on their own.
#
# DRY-RUN BY DEFAULT (mirrors reconcile.sh exactly): prints the decision + the
# command it WOULD run; --execute acts; --allow-restart gates the actual
# `systemctl restart` behind operator sign-off (same shape as reconcile.sh's Tier-2
# graceful-restart gate).
#
# COMPOSES WITH maintenance-lock.sh (DR-040 Decision 4, macf-devops-toolkit#158) —
# the SAME shared primitive (dir/schema/TTL) fleet/reconcile.sh reads and
# fleet/upgrade.sh writes: an ACTIVE maintenance lock for a runner's `name` SKIPs
# every action here too, so an operator-driven `make reinstall-<name>` (which
# legitimately tears the unit down mid-reinstall) doesn't read as an outage.
# FOLLOW-UP (not wired in this PR — detection/heal/alert was the asked scope):
# runner/reconcile-runner.sh does not yet ACQUIRE this lock around its own
# uninstall->install window, so a live `make reinstall-<name>` today still
# transiently ALERTs while the unit is torn down. Wiring that acquire is the
# natural next step, mirroring how fleet/upgrade.sh already does it for agents.
#
# THE PURE DECISION (zero I/O; unit-tested directly — see test-runner-watchdog.sh,
# same shape as runner/fork-pr-approval-check.sh's `_fork_approval_decide`):
#
#   _runner_watchdog_decide <active-state> <unit-loaded> <lock-active> [<wedged>]
#     -> SKIP   : lock-active == "1" — maintenance in progress, don't fight it.
#                 Checked FIRST so it overrides even an ALERT/WEDGED-shaped
#                 reading (unit torn down mid-reinstall looks identical to
#                 "de-registered"; a maintenance-driven restart looks identical
#                 to "wedged").
#     -> ALERT  : unit-loaded != "loaded" — de-registered / masked / never
#                 installed. Nothing to restart; needs an operator to re-register
#                 (`make -C runner reinstall-<name>`, RUNNER.md).
#     -> OK     : active-state == "active" AND wedged != "1" — healthy, quiet,
#                 nothing logged beyond the sweep table row.
#     -> WEDGED : active-state == "active" AND wedged == "1" — the unit LOOKS up
#                 (systemd sees the listener running) but it has claimed a job
#                 and no Runner.Worker process is executing it, CONFIRMED by
#                 two identical-timestamp samples (not just two shape matches
#                 — see the "job-wedge detection" block below, next to
#                 _runner_watchdog_wedge_confirmed, for why identity matters).
#                 Same HEAL action as the branch below (`systemctl restart`,
#                 gated behind --allow-restart) — kept as a DISTINCT label
#                 (not folded into HEAL) purely so the sweep table / alert text
#                 names the real failure instead of a misleading "not active".
#     -> HEAL   : loaded but not active (inactive/failed/dead/activating-stuck) —
#                 attempt `systemctl restart`, gated behind --allow-restart.
#
# `wedged` defaults to "0" when the 4th positional is omitted, so every
# pre-existing 3-arg call site (including every OK/HEAL/ALERT/SKIP test written
# before job-wedge detection existed) is unaffected.
#
# The "restart failed -> escalate to ALERT" leg is NOT a distinct branch in the
# decision table — it's a SECOND read of the post-restart ActiveState fed back
# through the exact same OK/HEAL predicate (see _runner_watchdog_restart below),
# so the whole tiered response reduces to one 4-input truth table, not two.
#
# DUAL-PURPOSE FILE (source for pure-function tests, execute for the real sweep):
# no existing fleet/ script needs both — reconcile.sh is only ever exec'd (never
# sourced) in its tests, while maintenance-lock.sh / fork-pr-approval-check.sh are
# PURE libraries with no top-level side effects, sourced-only, and deliberately
# carry no `set` line so they never mutate a caller's shell options (see
# maintenance-lock.sh's header). This file needs both shapes at once — a real
# standalone sweep AND a pure function worth unit-testing without re-execing the
# whole script — so it borrows the standard `[ "${BASH_SOURCE[0]}" = "${0}" ]`
# bash idiom: everything above that guard (config vars + function defs) is safe to
# `source` with zero side effects and zero shell-option changes; `set -uo
# pipefail` and the actual sweep only run inside _runner_watchdog_main, invoked
# only when the file is executed directly. (No -e, deliberately, matching the
# fleet/test-*.sh convention over reconcile.sh's `-euo pipefail`: this is a sweep
# over MULTIPLE independent runners, and a single runner's systemctl hiccup must
# not abort the rest of the sweep — see the liberal `|| true` / fallback-string
# guards throughout.)
#
# Refs: design/DR-006-vm-cron-watchdog-agent-supervision-impl.md (the agent-side
#       sibling this mirrors); fleet/maintenance-lock.sh (DR-040 Decision 4,
#       shared primitive); runner/verify-runner.sh (the per-runner health
#       PRIMITIVES reused here — repo-slug service-name derivation, the
#       Restart=always check this watchdog complements rather than duplicates);
#       runner/runners.yaml (the registry swept); macf-devops-toolkit#163.

RUNNER_WATCHDOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- config (safe to source — plain assignment, no side effects) ------------
# MACF_RUNNERS_YAML matches the SAME env var runner/reconcile-runner.sh already
# reads for this file (that script `cd`s into runner/ first so its own default is
# a bare relative "runners.yaml"; this script can run from any cwd — e.g. cron's
# — so its default is the absolute sibling path instead).
RUNNERS_YAML="${MACF_RUNNERS_YAML:-$RUNNER_WATCHDOG_DIR/../runner/runners.yaml}"
# Separate namespace from the agent-watchdog's alert/heartbeat dirs (reconcile.sh's
# MACF_ALERT_DIR / heartbeat file) — runner names and agent names are disjoint
# strings today (e.g. runner "macf-science-agent" vs agent "science-agent"), but
# keeping the two failure domains in visibly distinct paths means a human triaging
# ~/.macf/ can tell at a glance which watchdog raised a given alert/heartbeat.
ALERT_DIR="${MACF_RUNNER_ALERT_DIR:-$HOME/.macf/runner-alerts}"
HEARTBEAT_FILE="${MACF_RUNNER_WATCHDOG_HEARTBEAT:-$HOME/.macf/runner-watchdog-heartbeat}"
# Only sweep registry entries at these statuses (comma-separated). runners.yaml
# carries "ready"/staged entries (macf, macf-auditor-agent as of #163) that are
# intentionally NOT installed yet — sweeping them would ALERT on every 10-minute
# cycle for a runner nobody has stood up. "live" is the only status with an actual
# systemd unit to check; override if the registry grows new meaningful statuses.
STATUSES="${MACF_RUNNER_WATCHDOG_STATUSES:-live}"
# Reuses reconcile.sh's OTLP endpoint knob (same monitoring-VM Collector) so one
# env var / one operator mental model covers both watchdogs' external heartbeat.
WATCHDOG_OTLP_ENDPOINT="${MACF_WATCHDOG_OTLP_ENDPOINT:-${OTEL_EXPORTER_OTLP_ENDPOINT:-http://orzech-dev-agents-monitoring.tail491af.ts.net:4318}}"
# Seconds to wait after `systemctl restart` before re-reading ActiveState — restart
# is synchronous for a Type=simple unit (GitHub's svc.sh default), but a short
# settle window absorbs any startup jitter before the healed-or-still-down read.
RESTART_SETTLE_S="${MACF_RUNNER_RESTART_SETTLE_S:-3}"
# Restarting a GitHub Actions runner's systemd unit is ROOT-privileged (unlike the
# agent-watchdog's tmux-level actions) — install-runner.sh itself refuses to run
# without `[ "$(id -u)" = 0 ]`. `sudo -n` (non-interactive) so a cron lacking the
# grant FAILS FAST into the ALERT path instead of hanging on a password prompt.
# Override to "" if the watchdog cron itself runs as root. See fleet/README.md /
# RUNNER.md for the sudoers line an operator needs to grant this non-interactively.
SUDO_CMD="${MACF_RUNNER_WATCHDOG_SUDO:-sudo -n}"
# Same per-runner base dir + <name> layout every other runner script keys on
# (RUNNER.md "Multi-runner-per-host layout") — used ONLY to attribute a live
# Runner.Worker process to a specific runner by its cmdline path (see
# _runner_watchdog_worker_count below). Not otherwise used by this script.
RUNNER_BASE="${MACF_RUNNER_BASE:-/mnt/volume1/macf-runners}"
# How far back to read a unit's journal when looking for its last job-lifecycle
# marker ("Running job" / "completed with"). journalctl's tail can interleave
# with other unit chatter (registration pings, heartbeats), so `-n 1` is not
# reliably the last JOB event — see "job-wedge detection" below.
JOB_EVENT_LOOKBACK_LINES="${MACF_RUNNER_JOB_EVENT_LOOKBACK:-200}"
# Grace window between observing "job claimed, no worker yet" and re-checking
# before declaring the runner WEDGED (see "job-wedge detection" below). Bridges
# the ORDINARY gap between a JobDispatcher claiming a job and Runner.Worker
# actually spawning — without it, a routine job start caught mid-spawn by a
# sweep tick would misdiagnose as a wedge. 90s is comfortably above observed
# worker-spawn latency and comfortably below the 10-minute sweep cadence; only
# paid on the rare tick whose first sample already looks wedge-shaped — the
# common case (no job / a job with a worker already up) costs zero sleep.
#
# SWEEP-DURATION CEILING (per-runner, SERIAL sleeps — read this before raising
# either WEDGE_GRACE_S or the live-runner count): the main loop calls
# _runner_watchdog_check_wedge once per `status: live` registry entry, one
# after another, and each wedge-SHAPED runner (not just confirmed-wedged —
# the FIRST sample alone triggers the sleep) pays its own WEDGE_GRACE_S
# serially before the next runner is even looked at. Worst case — EVERY live
# runner sampling wedge-shaped on the same sweep tick (plausible: a shared
# network blip or an upstream GitHub incident hitting every runner's
# JobDispatcher at once) — is (live-runner count) * WEDGE_GRACE_S added to
# that sweep's wall-clock time. At today's 4 live runners * 90s = 360s, this
# is comfortably under the 600s (10-minute) cron cadence (install-cron.sh),
# but the margin is thinner than it looks: it is NOT a hard guarantee, cron
# does not itself prevent an overlapping invocation if one sweep runs long
# (no flock/lockfile around the whole script), and an overlapping invocation
# could each independently decide to restart the SAME runner. If the live
# count grows meaningfully past today's 4, or WEDGE_GRACE_S is raised, redo
# this arithmetic against the actual cron interval before shipping the
# change — and consider capping the total per-sweep grace budget (e.g. only
# pay the grace for the first N wedge-shaped runners, deferring the rest to
# the next sweep) or fencing the whole sweep with a lockfile, rather than
# assuming today's margin still holds.
WEDGE_GRACE_S="${MACF_RUNNER_WEDGE_GRACE_S:-90}"
EXECUTE=0
ALLOW_RESTART=0

# shellcheck source=./maintenance-lock.sh
. "$RUNNER_WATCHDOG_DIR/maintenance-lock.sh"

usage() {
  cat <<USAGE
runner-watchdog.sh — RUNNER-side liveness watchdog (macf-devops-toolkit#163),
the runner-analog of the DR-006 agent watchdog (fleet/reconcile.sh).

  --runners-yaml <path>   registry to sweep (default: runner/runners.yaml, sibling dir)
  --alert-dir <dir>       dedup'd alert-sentinel dir (default: \$HOME/.macf/runner-alerts)
  --maint-lock-dir <dir>  maintenance-lock dir (default: \$HOME/.macf/maintenance-locks —
                          SHARED with the agent watchdog + fleet/upgrade.sh, DR-040 §4)
  --heartbeat-file <f>    watchdog self-heartbeat file
                          (default: \$HOME/.macf/runner-watchdog-heartbeat)
  --execute               ACTUALLY act (restart / write alerts / heartbeat). Default: dry-run.
  --allow-restart         enable the systemctl-restart heal tier (operator sign-off; default OFF)
  -h, --help

Detection is LOCAL-ONLY (systemd unit state via 'systemctl show') — the bot's
GitHub token is 403 on administration:read, so this never calls the runners API
(RUNNER.md "The security model"). Sweeps only runners.yaml entries whose status
is in \$MACF_RUNNER_WATCHDOG_STATUSES (default: "live") — staged/"ready" runners
have no service yet by design.

An 'active' unit is ALSO cross-checked against its own journal + running
processes for a job-wedge (claimed a job, no Runner.Worker executing it — see
the script's "job-wedge detection" comment) before being reported OK; a
confirmed wedge reports WEDGED and heals the same way HEAL does (systemctl
restart, gated behind --allow-restart).

Exit: 0 = all OK/skipped/no-runners; 1 = HEAL/ALERT/WEDGED needed; 2 = usage error.
USAGE
}

# --- pure decision (unit-tested; zero I/O) -----------------------------------
# _runner_watchdog_decide <active-state> <unit-loaded> <lock-active> [<wedged>]
# -> prints exactly one of SKIP|ALERT|OK|WEDGED|HEAL, always returns 0. See the
# file header's "THE PURE DECISION" comment for the full rationale per branch.
# <wedged> defaults to "0" (not wedged) when omitted — pre-existing 3-arg call
# sites are unaffected.
_runner_watchdog_decide() {
  local active="$1" loaded="$2" locked="$3" wedged="${4:-0}"
  if [ "$locked" = "1" ]; then
    echo "SKIP"
    return 0
  fi
  if [ "$loaded" != "loaded" ]; then
    echo "ALERT"
    return 0
  fi
  if [ "$active" = "active" ]; then
    if [ "$wedged" = "1" ]; then
      echo "WEDGED"
      return 0
    fi
    echo "OK"
    return 0
  fi
  echo "HEAL"
  return 0
}

# --- registry (yq/jq isolated behind a seam so the FILTER logic — the part most
# likely to silently regress, e.g. a status typo excluding a live runner — is
# unit-testable with hand-written JSON and no yq dependency; yq lives on the
# runner devbox / host-prelude, not necessarily every dev sandbox) -----------

# _runner_watchdog_registry_json <runners.yaml> -> the registry as JSON on stdout,
# or a non-zero exit if no working YAML->JSON converter is available or the file
# can't be read.
#
# Cron-hardened (#169): the ONLY `yq` on cron's bare PATH here is /usr/bin/yq,
# which is **python-yq 3.1.0** (a jq wrapper) — it rejects `-o=json` outright, so
# the original yq-go-only implementation failed on every sweep for ~37 days.
# yq-go lives in `runner/devbox.json`, i.e. inside a devbox shell that cron never
# enters. So probe for a converter that actually works instead of assuming a
# flavour, and validate the OUTPUT (jq-parseable, non-empty) rather than the exit
# code — a wrong-flavour binary can exit 0 and emit something useless.
#   1. $MACF_YQ (explicit operator override)   2. yq-go     3. python-yq
#   4. python3 + PyYAML (always present where python-yq is)
_runner_watchdog_registry_json() {
  local yaml="$1" out
  [ -r "$yaml" ] || return 1

  _rw_emit() {  # run "$@" and echo its stdout only if it is non-empty JSON
    local o; o="$("$@" 2>/dev/null)" || return 1
    [ -n "$o" ] || return 1
    printf '%s' "$o" | jq -e . >/dev/null 2>&1 || return 1
    printf '%s' "$o"
  }

  if [ -n "${MACF_YQ:-}" ] && out="$(_rw_emit "$MACF_YQ" -o=json "$yaml")"; then
    printf '%s' "$out"; return 0
  fi
  if command -v yq >/dev/null 2>&1; then
    # yq-go
    if out="$(_rw_emit yq -o=json "$yaml")"; then printf '%s' "$out"; return 0; fi
    # python-yq: YAML in, JSON out via the jq it wraps
    if out="$(_rw_emit yq . "$yaml")";      then printf '%s' "$out"; return 0; fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    if out="$(_rw_emit python3 -c \
      'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])),sys.stdout)' "$yaml")"; then
      printf '%s' "$out"; return 0
    fi
  fi
  return 1
}

# _runner_watchdog_filter_registry <statuses-csv> — reads registry JSON on STDIN,
# prints "<name>\t<repo>" TSV for every runner whose .status is in the CSV list.
# Pure jq (jq is assumed present — reconcile.sh already hard-requires it for the
# same cron), no yq dependency, so this is testable with a literal JSON fixture.
_runner_watchdog_filter_registry() {
  local statuses="$1"
  jq -r --arg statuses "$statuses" '
    ($statuses | split(",")) as $want
    | .fleets[].runners[]
    | select(.status as $s | $want | index($s) != null)
    | [.name, .repo] | @tsv'
}

# --- effectful helpers --------------------------------------------------------

# act <label> <cmd...> — print always; run only under EXECUTE=1. Identical
# contract to reconcile.sh's own `act` helper (kept local/underscored here since
# this file may be sourced alongside reconcile.sh in the same shell).
_runner_watchdog_act() {
  local label="$1"; shift
  if [ "$EXECUTE" -eq 1 ]; then
    echo "    [EXECUTE] $label"
    "$@"
  else
    echo "    [dry-run] $label: $*"
  fi
}

# _runner_watchdog_service_name <repo> -> the actions.runner.<repo-slug>.<name>.service
# unit currently loaded into systemd, or "" if none. Reuses the EXACT derivation
# runner/verify-runner.sh / runner/install-runner.sh use (repo-slug + list-units
# grep) so the watchdog and the health-check tool can never disagree about which
# service a repo maps to.
_runner_watchdog_service_name() {
  local repo="$1" slug="${1//\//-}"
  systemctl list-units --type=service --all 2>/dev/null \
    | grep -oE "actions\.runner\.${slug}\.[^ ]+\.service" | head -1
}

# _runner_watchdog_state <service> <property> -> the systemctl property value, or
# a clearly-labeled fallback if the query fails. NEVER prints empty — a query
# hiccup must fail TOWARD the conservative (alerting/healing) branch of
# _runner_watchdog_decide, never be silently mistaken for a legitimate value.
_runner_watchdog_state() {
  local svc="$1" prop="$2" val fallback="unknown"
  [ "$prop" = "LoadState" ] && fallback="not-found"
  val="$(systemctl show "$svc" -p "$prop" --value 2>/dev/null || true)"
  printf '%s\n' "${val:-$fallback}"
}

# --- job-wedge detection ------------------------------------------------------
#
# WHY is-active IS NOT ENOUGH:
#
#   `systemctl show <svc> -p ActiveState` answers a PROXY question — "is the
#   runner's LISTENER process up" — which stays true for as long as the .NET
#   process itself hasn't crashed. It does NOT answer the actual INVARIANT this
#   watchdog exists to protect — "can this runner execute a routed job right
#   now" (RUNNER.md: "a down self-hosted runner does NOT fall back to
#   github-hosted — it makes that repo's trusted routing queue forever").
#
#   Live incident: a runner claimed a job, and a cancellation for that SAME job
#   arrived in the same instant. The runner's own _diag log:
#
#       00:26:40 JobDispatcher] Running job: route / config
#       00:26:40 JobDispatcher] Start renew job request for job 35452e21
#       00:26:40 JobDispatcher] Job cancellation request 35452e21 received
#       00:26:40 JobDispatcher] Stop renew job request
#
#   No Runner.Worker process was ever spawned, no completion was ever logged,
#   and the job slot was never released — but the systemd unit's listener
#   process never died, so ActiveState stayed `active` throughout. This
#   watchdog logged "OK" on every 10-minute sweep for ~2 HOURS while routing
#   for that repo queued dark:
#
#       macf   OK   actions.runner.groundnuty-macf.macf-vm-orzech-dev-agents.service active
#
#   Detection reads the unit's OWN journal for its last job-lifecycle event
#   ("Running job" vs "completed with") and cross-checks it against whether a
#   Runner.Worker process for THIS runner actually exists. A legitimately
#   long-running job is NOT a false positive here — a long job HAS a worker
#   process the whole time it runs; only a wedge has neither a worker nor a
#   completion. That is why this checks the INVARIANT (is it executing work)
#   rather than a duration-threshold PROXY (how long has it been running) —
#   a threshold would either false-positive on slow-but-healthy jobs or be set
#   so high it stops catching real wedges promptly.
#
#   TWO SAMPLES ARE NOT ENOUGH ON THEIR OWN — THEY MUST BE THE **SAME** CLAIM
#   (peer-review catch): re-sampling "claimed a job, no worker" 90s apart does
#   NOT by itself prove one continuous wedge. It can also occur for TWO
#   DIFFERENT jobs straddling the grace window — job A claimed, no worker yet
#   (sample 1, wedge-shaped); job A finishes and job B is claimed a moment
#   later, its worker also not yet up (sample 2, wedge-shaped) — a healthy,
#   busy runner that would misdiagnose as WEDGED and get restarted mid-job.
#   The fix: capture the journal's OWN timestamp for the claim event alongside
#   the marker text, and require the timestamp to be IDENTICAL across both
#   samples before confirming WEDGED (see _runner_watchdog_wedge_confirmed
#   below). If the timestamp advanced, a NEW event was logged between samples
#   — the runner has demonstrably made progress and is not wedged, regardless
#   of shape.
#
# _runner_watchdog_last_job_event <service> -> "<iso-timestamp>\t<marker>" for
# the most recent job-lifecycle line in the unit's journal, where <marker> is
# "Running job" | "completed with"; empty ("\t" alone, i.e. both fields empty)
# if neither has appeared in the lookback window (e.g. a runner that has never
# run a job yet). `-o short-iso` (not `-o cat`) so the timestamp survives —
# see "TWO SAMPLES ARE NOT ENOUGH" above for why the timestamp matters as much
# as the marker text. Reads JOB_EVENT_LOOKBACK_LINES lines, not just the last
# 1 — journalctl's tail can interleave with other unit chatter (registration
# pings, heartbeats), so `tail -1` after the grep is what actually finds the
# LAST job-lifecycle line.
_runner_watchdog_last_job_event() {
  local svc="$1" line ts marker
  line="$(journalctl -u "$svc" -n "$JOB_EVENT_LOOKBACK_LINES" --no-pager -o short-iso 2>/dev/null \
    | grep -E 'Running job|completed with' | tail -1)"
  if [ -z "$line" ]; then
    printf '\t\n'
    return 0
  fi
  # short-iso's timestamp is the line's first whitespace-separated field
  # (e.g. "2026-08-27T00:26:40+0000"), with no embedded spaces.
  ts="${line%% *}"
  case "$line" in
    *'Running job'*)    marker="Running job" ;;
    *'completed with'*) marker="completed with" ;;
    *)                   marker="" ;;
  esac
  printf '%s\t%s\n' "$ts" "$marker"
}

# _runner_watchdog_worker_count <name> -> number of live Runner.Worker
# processes attributable to THIS runner. Attribution is via the worker's own
# cmdline path — each runner's binary lives under its OWN
# $RUNNER_BASE/<name>/actions-runner/ (RUNNER.md "Multi-runner-per-host
# layout"), so the path segment IS the runner identity; no PID-tracking or
# process-start-time heuristics needed, and one runner's worker can never be
# mistaken for a sibling runner's. `pgrep` (not `ps | grep`) deliberately —
# same tool runner/verify-runner.sh already uses for its own Listener check —
# because pgrep excludes ITS OWN pid from the match by design, whereas a
# `ps aux | grep <pattern>` pipeline can self-match the grep process itself
# (the classic "grep grep" hazard) since the pattern text appears in grep's
# own argv too. NEVER errors on zero matches (`pgrep -c` exits 1 with no
# match but still prints "0"; `|| true` here keeps this a plain count).
_runner_watchdog_worker_count() {
  local name="$1" n
  n="$(pgrep -c -f "${RUNNER_BASE}/${name}/.*Runner\.Worker" 2>/dev/null)" || true
  printf '%s\n' "${n:-0}"
}

# _runner_watchdog_wedge_sample <last-job-event> <worker-count> -> "1" if THIS
# single sample LOOKS wedge-shaped (last event is a job claim, zero workers
# for it), else "0". PURE — no I/O, always returns 0 — unit-tested directly
# (see test-runner-watchdog.sh). A single call of this is a SHAPE check only —
# it does NOT by itself prove a wedge; see _runner_watchdog_wedge_confirmed
# below for why a second, identity-checked sample is required before WEDGED
# is ever reported.
_runner_watchdog_wedge_sample() {
  local last_event="$1" count="${2:-0}"
  if [ "$last_event" = "Running job" ] && [ "$count" -eq 0 ] 2>/dev/null; then
    echo "1"
  else
    echo "0"
  fi
}

# _runner_watchdog_wedge_confirmed <ts1> <event1> <count1> <ts2> <event2> <count2>
# -> "1" iff BOTH samples independently look wedge-shaped (per
# _runner_watchdog_wedge_sample) AND the journal timestamp is IDENTICAL across
# both. PURE — no I/O, always returns 0 — unit-tested directly.
#
# The timestamp-identity requirement is the fix for a peer-review-caught false
# positive: two wedge-shaped samples WEDGE_GRACE_S apart do NOT by themselves
# prove one continuous wedge — they can also occur for TWO DIFFERENT jobs
# straddling the grace window (job A claimed with no worker yet at t0; job A
# finishes and job B is claimed a moment later, ALSO caught with no worker yet
# at t0+WEDGE_GRACE_S). That shape is a healthy, busy runner — restarting it
# would kill a live job. Requiring ts1 == ts2 rules this out: if the
# timestamp advanced, a NEW journal line was logged between samples, which
# means the runner made progress and is not wedged, REGARDLESS of shape —
# same-shape-different-timestamp is explicitly NOT confirmed here (see its
# own test case). An empty timestamp (no job event ever seen) never confirms
# either, since "" = "" would otherwise vacuously match two never-ran
# runners — guarded by requiring ts1 to be non-empty.
_runner_watchdog_wedge_confirmed() {
  local ts1="$1" event1="$2" count1="$3" ts2="$4" event2="$5" count2="$6"
  [ "$(_runner_watchdog_wedge_sample "$event1" "$count1")" = "1" ] || { echo "0"; return 0; }
  [ "$(_runner_watchdog_wedge_sample "$event2" "$count2")" = "1" ] || { echo "0"; return 0; }
  if [ -n "$ts1" ] && [ "$ts1" = "$ts2" ]; then
    echo "1"
  else
    echo "0"
  fi
}

# _runner_watchdog_check_wedge <service> <name> -> "1" iff CONFIRMED wedged
# after the WEDGE_GRACE_S grace window (per _runner_watchdog_wedge_confirmed
# — same shape AND same journal timestamp across both samples), "0"
# otherwise. Re-samples rather than trusting one read — see WEDGE_GRACE_S's
# own comment — so the ORDINARY gap between a runner's JobDispatcher claiming
# a job and Runner.Worker actually spawning it is never mistaken for a wedge.
# Costs zero sleep on the overwhelmingly common case where the first sample
# already isn't wedge-shaped (no job running, or a job with its worker
# already up).
_runner_watchdog_check_wedge() {
  local svc="$1" name="$2"
  local sample1 ts1 event1 count1 sample2 ts2 event2 count2

  sample1="$(_runner_watchdog_last_job_event "$svc")"
  ts1="${sample1%%$'\t'*}"; event1="${sample1#*$'\t'}"
  count1="$(_runner_watchdog_worker_count "$name")"
  [ "$(_runner_watchdog_wedge_sample "$event1" "$count1")" = "1" ] || { echo "0"; return 0; }

  sleep "$WEDGE_GRACE_S"

  sample2="$(_runner_watchdog_last_job_event "$svc")"
  ts2="${sample2%%$'\t'*}"; event2="${sample2#*$'\t'}"
  count2="$(_runner_watchdog_worker_count "$name")"
  _runner_watchdog_wedge_confirmed "$ts1" "$event1" "$count1" "$ts2" "$event2" "$count2"
}

# _runner_watchdog_alert <name> <why> — dedup'd sentinel (one open alert per
# runner; mirrors reconcile.sh's tier3_alert exactly, incl. the dedup semantics).
_runner_watchdog_alert() {
  local name="$1" why="$2"
  if [ -e "$ALERT_DIR/$name" ]; then
    echo "    [skip] alert for $name already open (dedup) — clear $ALERT_DIR/$name once resolved"
    return 0
  fi
  if [ "$EXECUTE" -eq 1 ]; then mkdir -p "$ALERT_DIR"; fi
  _runner_watchdog_act "alert for $name ($why)" bash -c "echo '$why' > '$ALERT_DIR/$name'"
}

# _runner_watchdog_self_alert <why> — the watchdog cannot run AT ALL (missing dep,
# unreadable registry). #169: this used to be a bare `echo … skipping sweep` + exit 0,
# which produced 5389 identical log lines over ~37 days and no fleet-visible signal —
# the supervision layer was down and nothing said so. "The watchdog is down" is
# strictly worse than "a runner is down", so it takes the SAME alert path as a real
# outage. Reserved sentinel name (leading `_`, never a valid runner name), dedup'd so
# a persistent misconfiguration doesn't rewrite it every 10 minutes.
_runner_watchdog_self_alert() {
  local why="$1" name="_watchdog-self"
  echo "runner-watchdog: CANNOT SWEEP — $why" >&2
  if [ -e "$ALERT_DIR/$name" ]; then
    echo "    [skip] self-alert already open (dedup) — clear $ALERT_DIR/$name once fixed" >&2
    return 0
  fi
  if [ "$EXECUTE" -eq 1 ]; then
    mkdir -p "$ALERT_DIR"
    printf 'runner-watchdog cannot sweep: %s\n' "$why" > "$ALERT_DIR/$name"
    echo "    [EXECUTE] self-alert written to $ALERT_DIR/$name" >&2
  else
    echo "    [dry-run] would write self-alert to $ALERT_DIR/$name" >&2
  fi
  return 0
}

# _runner_watchdog_reset <name> — clear a stale alert once the runner recovers to
# OK, so a FUTURE failure re-alerts instead of staying dedup'd-silent forever.
_runner_watchdog_reset() {
  local name="$1"
  [ "$EXECUTE" -eq 1 ] || return 0
  [ -e "$ALERT_DIR/$name" ] && { rm -f "$ALERT_DIR/$name"; echo "    [recovered] $name OK -> alert cleared"; }
  return 0
}

# _runner_watchdog_restart <name> <service> <active-before> -> attempts the heal
# (systemctl restart), GATED behind --allow-restart (operator sign-off, same shape
# as reconcile.sh's Tier-2). Returns 0 iff the restart brought the unit back to
# `active`; 1 in every other case (held / dry-run / restart-but-still-down) so the
# caller always knows whether to escalate to ALERT.
_runner_watchdog_restart() {
  local name="$1" svc="$2"
  if [ "$ALLOW_RESTART" -ne 1 ]; then
    echo "    [held] restart of $svc SUPPRESSED (no --allow-restart; operator sign-off required)"
    return 1
  fi
  # shellcheck disable=SC2086  # SUDO_CMD is an intentional word-split (e.g. "sudo -n"); "" vanishes cleanly when unset.
  _runner_watchdog_act "systemctl restart $svc" $SUDO_CMD systemctl restart "$svc"
  if [ "$EXECUTE" -ne 1 ]; then
    return 1   # dry-run never confirms a heal
  fi
  sleep "$RESTART_SETTLE_S"
  local post_active
  post_active="$(_runner_watchdog_state "$svc" ActiveState)"
  if [ "$post_active" = "active" ]; then
    echo "    [healed] $svc back to active after restart"
    return 0
  fi
  echo "    [FAIL] $svc still '$post_active' after restart (privilege gap? crash-loop? see \$SUDO_CMD=$SUDO_CMD)"
  return 1
}

# emit_watchdog_metric — reuses reconcile.sh's exact OTLP-gauge shape (same
# best-effort short-timeout posture: a Collector hiccup NEVER fails/delays the
# sweep) under a DISTINCT metric + service.name so the two watchdogs' staleness
# alerts are independently queryable in Prometheus, while sharing one endpoint knob.
_runner_watchdog_emit_metric() {
  [ -n "$WATCHDOG_OTLP_ENDPOINT" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local now_s now_ns host
  now_s="$(date +%s)"; now_ns="$(date +%s%N)"; host="$(hostname 2>/dev/null || echo unknown)"
  curl -sS --max-time 5 -o /dev/null -X POST "$WATCHDOG_OTLP_ENDPOINT/v1/metrics" \
    -H 'Content-Type: application/json' \
    -d '{"resourceMetrics":[{"resource":{"attributes":[
          {"key":"service.name","value":{"stringValue":"macf-runner-watchdog"}},
          {"key":"host.name","value":{"stringValue":"'"$host"'"}}]},
        "scopeMetrics":[{"scope":{"name":"macf.runner_watchdog"},"metrics":[
          {"name":"macf.runner_watchdog.last_sweep_timestamp_seconds","unit":"s","gauge":{"dataPoints":[
            {"asDouble":'"$now_s"',"timeUnixNano":"'"$now_ns"'"}]}}]}]}]}' \
    2>/dev/null || true
}

# --- main ---------------------------------------------------------------------
_runner_watchdog_main() {
  set -uo pipefail   # deliberately no -e — see file header ("DUAL-PURPOSE FILE")

  while [ $# -gt 0 ]; do
    case "$1" in
      --runners-yaml)   RUNNERS_YAML="$2"; shift 2 ;;
      --alert-dir)      ALERT_DIR="$2"; shift 2 ;;
      --maint-lock-dir) MAINT_LOCK_DIR="$2"; shift 2 ;;
      --heartbeat-file) HEARTBEAT_FILE="$2"; shift 2 ;;
      --execute)        EXECUTE=1; shift ;;
      --allow-restart)  ALLOW_RESTART=1; shift ;;
      -h|--help)        usage; exit 0 ;;
      *) echo "runner-watchdog.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
  done

  if ! command -v jq >/dev/null 2>&1; then
    _runner_watchdog_self_alert "jq not found on PATH ($PATH) — cannot sweep"
    exit 0
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "runner-watchdog: systemctl not found (not a systemd host?) — observational tool, skipping sweep" >&2
    exit 0
  fi

  local registry_json
  if ! registry_json="$(_runner_watchdog_registry_json "$RUNNERS_YAML")"; then
    if [ -r "$RUNNERS_YAML" ]; then
      _runner_watchdog_self_alert "no working YAML->JSON converter for $RUNNERS_YAML (tried \$MACF_YQ, yq-go, python-yq, python3+PyYAML) on PATH ($PATH) — cannot sweep"
    else
      _runner_watchdog_self_alert "registry unreadable: $RUNNERS_YAML — cannot sweep"
    fi
    exit 0
  fi

  local registry
  registry="$(printf '%s' "$registry_json" | _runner_watchdog_filter_registry "$STATUSES" 2>/dev/null || true)"
  if [ -z "$registry" ]; then
    echo "runner-watchdog: no runners at status in [$STATUSES] found in $RUNNERS_YAML — nothing to do" >&2
    exit 0
  fi

  # We got a parseable registry with at least one runner => the watchdog itself is
  # healthy; clear any open self-alert so a FUTURE dep breakage re-alerts (#169).
  _runner_watchdog_reset "_watchdog-self"

  local rc=0
  printf '%-24s %-8s %s\n' "RUNNER" "DECISION" "DETAIL"
  printf '%-24s %-8s %s\n' "------" "--------" "------"
  local name repo locked svc loaded active wedged decision
  while IFS=$'\t' read -r name repo; do
    [ -n "$name" ] || continue
    if [ -z "$repo" ]; then
      printf '%-24s %-8s %s\n' "$name" "SKIP" "no repo field in registry — malformed entry"
      continue
    fi

    locked=0
    lock_active "$name" && locked=1

    svc="$(_runner_watchdog_service_name "$repo")"
    if [ -n "$svc" ]; then
      loaded="$(_runner_watchdog_state "$svc" LoadState)"
      active="$(_runner_watchdog_state "$svc" ActiveState)"
    else
      loaded="not-found"; active="unknown"
    fi

    # The job-wedge cross-check is only worth paying for in EXACTLY the blind
    # spot is-active can't see through — an unlocked, loaded, active unit
    # (see "job-wedge detection" above _runner_watchdog_last_job_event). A
    # locked/torn-down/inactive unit is already decided by the branches below
    # regardless of wedge state, so skip the (occasionally WEDGE_GRACE_S-long)
    # check entirely rather than pay it for nothing.
    wedged=0
    if [ "$locked" -eq 0 ] && [ "$loaded" = "loaded" ] && [ "$active" = "active" ]; then
      wedged="$(_runner_watchdog_check_wedge "$svc" "$name")"
    fi

    decision="$(_runner_watchdog_decide "$active" "$loaded" "$locked" "$wedged")"
    case "$decision" in
      SKIP)
        printf '%-24s %-8s %s\n' "$name" "SKIP" "maintenance lock active ($(lock_info "$name")) — not touched"
        ;;
      OK)
        printf '%-24s %-8s %s\n' "$name" "OK" "$svc active"
        _runner_watchdog_reset "$name"
        ;;
      ALERT)
        printf '%-24s %-8s %s\n' "$name" "ALERT" "no actions.runner service loaded for $repo (torn down / never installed?)"
        _runner_watchdog_alert "$name" "no systemd service loaded for $repo — re-register via: make -C runner reinstall-$name"
        rc=1
        ;;
      WEDGED)
        printf '%-24s %-8s %s\n' "$name" "WEDGED" "$svc active but job claimed with no worker executing it (job-wedge; see file header)"
        if _runner_watchdog_restart "$name" "$svc"; then
          : # healed — same "quiet beyond the log line" contract as HEAL below;
            # the sweep-table row + [healed] line ARE the fleet-visible signal.
        else
          local restart_note="held, no --allow-restart"
          [ "$ALLOW_RESTART" -eq 1 ] && restart_note="attempted and failed"
          _runner_watchdog_alert "$name" "$svc wedged (job claimed, no Runner.Worker) — restart $restart_note"
        fi
        rc=1
        ;;
      HEAL)
        printf '%-24s %-8s %s\n' "$name" "HEAL" "$svc loaded but not active (state: $active)"
        if _runner_watchdog_restart "$name" "$svc"; then
          : # healed — quiet beyond the [healed] log line above (Restart=always's
            # own silence is exactly the gap this watchdog exists to make visible,
            # so the sweep-table row + [healed] line ARE the fleet-visible signal;
            # no separate alert for a heal that worked).
        else
          local restart_note="held, no --allow-restart"
          [ "$ALLOW_RESTART" -eq 1 ] && restart_note="attempted and failed"
          _runner_watchdog_alert "$name" "$svc not active (state: $active) — restart $restart_note"
        fi
        rc=1
        ;;
    esac
  done <<<"$registry"

  echo
  local mode="dry-run" restart="off"
  [ "$EXECUTE" -eq 1 ] && mode="EXECUTE"
  [ "$ALLOW_RESTART" -eq 1 ] && restart="on"

  if [ "$EXECUTE" -eq 1 ]; then
    { mkdir -p "$(dirname "$HEARTBEAT_FILE")" \
      && printf '%s runner-watchdog rc=%s restart=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$restart" > "$HEARTBEAT_FILE"; } || true
    _runner_watchdog_emit_metric
  fi

  if [ "$rc" -eq 0 ]; then
    echo "runner-watchdog [$mode, restart:$restart]: all runners OK / skipped — no action."
  else
    echo "runner-watchdog [$mode, restart:$restart]: action(s) taken or needed above."
  fi
  exit "$rc"
}

# Only run the sweep when EXECUTED directly — sourcing this file (test-runner-
# watchdog.sh) gets the config vars + function defs with ZERO side effects and
# ZERO shell-option changes (see the file header's "DUAL-PURPOSE FILE" note).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _runner_watchdog_main "$@"
fi
