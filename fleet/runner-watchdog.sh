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
#   _runner_watchdog_decide <active-state> <unit-loaded> <lock-active>
#     -> SKIP  : lock-active == "1" — maintenance in progress, don't fight it.
#                Checked FIRST so it overrides even an ALERT-shaped reading
#                (unit torn down mid-reinstall looks identical to "de-registered").
#     -> ALERT : unit-loaded != "loaded" — de-registered / masked / never
#                installed. Nothing to restart; needs an operator to re-register
#                (`make -C runner reinstall-<name>`, RUNNER.md).
#     -> OK    : active-state == "active" — healthy, quiet, nothing logged beyond
#                the sweep table row.
#     -> HEAL  : loaded but not active (inactive/failed/dead/activating-stuck) —
#                attempt `systemctl restart`, gated behind --allow-restart.
#
# The "restart failed -> escalate to ALERT" leg is NOT a distinct branch in the
# decision table — it's a SECOND read of the post-restart ActiveState fed back
# through the exact same OK/HEAL predicate (see _runner_watchdog_restart below),
# so the whole tiered response reduces to one 3-input truth table, not two.
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

Exit: 0 = all OK/skipped/no-runners; 1 = HEAL/ALERT needed; 2 = usage error.
USAGE
}

# --- pure decision (unit-tested; zero I/O) -----------------------------------
# _runner_watchdog_decide <active-state> <unit-loaded> <lock-active> -> prints
# exactly one of SKIP|ALERT|OK|HEAL, always returns 0. See the file header's
# "THE PURE DECISION" comment for the full rationale per branch.
_runner_watchdog_decide() {
  local active="$1" loaded="$2" locked="$3"
  if [ "$locked" = "1" ]; then
    echo "SKIP"
    return 0
  fi
  if [ "$loaded" != "loaded" ]; then
    echo "ALERT"
    return 0
  fi
  if [ "$active" = "active" ]; then
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
  local name repo locked svc loaded active decision
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

    decision="$(_runner_watchdog_decide "$active" "$loaded" "$locked")"
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
