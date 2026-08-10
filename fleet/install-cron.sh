#!/usr/bin/env bash
#
# install-cron.sh — idempotently install the DR-006 watchdog cron line.
#
# The watchdog cron must be HOST-INSTALLED (DR-006 §A.4): it survives a VM reboot
# (user crontab persists in the spool, cron runs it at boot) and the FIRST post-boot
# sweep launches the whole desired fleet from a cold box — so the reconciler IS the
# one-command launch-all + the reboot-recovery, no separate mechanism. It is NOT
# installed by claude.sh-on-launch, because on cold-boot nothing launches to install
# it.
#
# The cron line sources host-prelude.sh FIRST (cron's bare env lacks the toolchain —
# the CLI / tmux / gh; DR-031 portable bootstrap), then runs reconcile.sh.
#
# SAFE DEFAULT: installs in DRY-RUN (report-only → logs decisions, acts on nothing)
# so the operator can watch the log for a few cycles before trusting it. Add
# --execute to act; --allow-restart additionally enables Tier-2. Idempotent: a
# re-run replaces the existing macf-watchdog line (marker-guarded), never duplicates.
#
# --with-runner-watchdog (macf-devops-toolkit#163) chains fleet/runner-watchdog.sh
# (the RUNNER-side liveness watchdog — detects a down self-hosted-runner systemd
# unit that macf-actions' pick-runner would otherwise silently queue trusted
# routing against) onto the SAME cron line, right after reconcile.sh, gated by the
# SAME --execute/--allow-restart dials (one operator-trust dial for both legs —
# DRY). Kept as a SEPARATE script invoked ALONGSIDE reconcile.sh rather than folded
# into it: reconcile.sh's whole decision model (ack_agent identity, desired-agents
# schema, fleet-doctor JSON schema) is agent-shaped, and a systemd-unit-keyed-by-
# repo entity doesn't fit that schema without contorting it. This mirrors the
# existing --with-routing precedent (DR-006 Increment 4): a second, independently
# toggleable probe/leg bolted onto the same sweep rather than a schema rewrite.
# Chained with `;` (not `&&`) so a reconcile.sh hiccup never suppresses the runner
# sweep, and logged to ITS OWN file (not reconcile.sh's $LOG) for easier triage of
# which watchdog raised what. runner-watchdog.sh needs `yq` in addition to the
# `jq`/tmux toolchain host-prelude already provides for reconcile.sh — see
# fleet/README.md "Runner-watchdog cron wiring" for the `devbox global add yq-go`
# operator step this depends on.
#
# Refs: design/DR-006-vm-cron-watchdog-agent-supervision-impl.md §A.4;
#       macf-devops-toolkit#163 (fleet/runner-watchdog.sh).

set -euo pipefail

MARKER="# macf-watchdog (DR-006)"
INTERVAL="${MACF_WATCHDOG_INTERVAL:-*/10 * * * *}"   # coarse default (§A.4 / heartbeat cadence)
PRELUDE="${MACF_HOST_PRELUDE:-$HOME/.claude/.macf/host-prelude.sh}"
LOG="${MACF_WATCHDOG_LOG:-$HOME/.macf/watchdog.log}"
RECON="$(cd "$(dirname "$0")" && pwd)/reconcile.sh"
RUNNER_WD="$(cd "$(dirname "$0")" && pwd)/runner-watchdog.sh"
RUNNER_WD_LOG="${MACF_RUNNER_WATCHDOG_LOG:-$HOME/.macf/runner-watchdog.log}"
MANIFEST_ARG=""
EXECUTE_ARG="" ; RESTART_ARG="" ; ROUTING_ARG="" ; UNINSTALL=0 ; NO_TOKEN=0 ; WITH_RUNNER_WD=0

usage() {
  cat <<USAGE
install-cron.sh — idempotently install/remove the DR-006 watchdog cron (DR-006 §A.4)

  --manifest <path>       pass --manifest to reconcile.sh (default: its own default)
  --interval "<cron>"     schedule (default: "$INTERVAL")
  --execute               install an ACTING line (default: report-only/dry-run)
  --allow-restart         also enable Tier-2 graceful-restart (implies a careful operator)
  --with-routing          also run the routing-doctor probe (registration-freshness)
  --with-runner-watchdog  also chain fleet/runner-watchdog.sh (#163, self-hosted-runner
                          liveness) onto the same line — reuses --execute/--allow-restart,
                          logs to $RUNNER_WD_LOG
  --no-token              do NOT bake a GH_TOKEN mint into the cron (operator provides it)
  --uninstall             remove the macf-watchdog cron line
  --print                 print the line that WOULD be installed, don't touch crontab
  --skip-preflight        install even if the cron-env dependency check fails (#169)
  -h, --help

Installs (default) a REPORT-ONLY line logging to $LOG — watch it, then re-run with
--execute once trusted. host-prelude ($PRELUDE) is sourced first for cron's bare env.
USAGE
}

PRINT_ONLY=0
SKIP_PREFLIGHT=0

# --- cron PATH (#169) ---------------------------------------------------------
# cron runs with PATH=/usr/bin:/bin. Neither watchdog's toolchain lives there:
# `macf` is in the npm global prefix, and `yq-go` only exists inside a devbox
# shell (the system /usr/bin/yq is python-yq, a different CLI). The line used to
# rely on host-prelude.sh for this — but that file does not exist on this host, so
# `[ -f … ] && . …` short-circuited SILENTLY and both watchdogs ran dep-less for
# ~37 days. Bake an explicit PATH into the line instead of depending on a file
# that may not be there; keep the prelude source as an additive extra.
CRON_PATH="/usr/local/bin:/usr/bin:/bin"
for d in "$HOME/.npm-global/bin" "$HOME/.nix-profile/bin" "$HOME/.local/bin"; do
  [ -d "$d" ] && CRON_PATH="$d:$CRON_PATH"
done

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)             MANIFEST_ARG="--manifest $2"; shift 2 ;;
    --interval)             INTERVAL="$2"; shift 2 ;;
    --execute)              EXECUTE_ARG="--execute"; shift ;;
    --allow-restart)        RESTART_ARG="--allow-restart"; shift ;;
    --with-routing)         ROUTING_ARG="--with-routing"; shift ;;
    --with-runner-watchdog) WITH_RUNNER_WD=1; shift ;;
    --no-token)             NO_TOKEN=1; shift ;;
    --uninstall)            UNINSTALL=1; shift ;;
    --print)                PRINT_ONLY=1; shift ;;
    --skip-preflight)       SKIP_PREFLIGHT=1; shift ;;
    -h|--help)              usage; exit 0 ;;
    *) echo "install-cron.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v crontab >/dev/null || { echo "FATAL: crontab not found" >&2; exit 2; }
[ -f "$RECON" ] || { echo "FATAL: reconcile.sh not found at $RECON" >&2; exit 2; }
if [ "$WITH_RUNNER_WD" -eq 1 ]; then
  [ -f "$RUNNER_WD" ] || { echo "FATAL: --with-runner-watchdog given but runner-watchdog.sh not found at $RUNNER_WD" >&2; exit 2; }
fi

# strip any existing macf-watchdog line (idempotency); preserve the rest
EXISTING="$(crontab -l 2>/dev/null | grep -vF "$MARKER" || true)"

if [ "$UNINSTALL" -eq 1 ]; then
  printf '%s\n' "$EXISTING" | crontab -
  echo "removed macf-watchdog cron line."
  exit 0
fi

# Token-mint: the watchdog's `fleet doctor` reads MACF_CA_CERT from the registry, so the
# cron needs a fresh GH_TOKEN (cron has none — found via live-dry-run, devops-toolkit#118).
# Mint it from the workspace's App creds (same helper + creds the SessionStart hook uses),
# fail-loud (no token → abort the sweep rather than run blind into a 401). The `$(...)` is
# escaped so cron's shell evaluates it at RUN time (fresh token each sweep); the creds are
# resolved now (fixed). --no-token skips (operator supplies GH_TOKEN another way).
TOKEN_PREFIX=""
if [ "$NO_TOKEN" -ne 1 ]; then
  WS="$(cd "$(dirname "$RECON")/.." && pwd)"
  HELPER="$WS/.claude/scripts/macf-gh-token.sh"
  SETTINGS="$WS/.claude/settings.local.json"
  if [ -x "$HELPER" ] && [ -f "$SETTINGS" ]; then
    WD_APP="$(jq -r '.env.APP_ID // empty' "$SETTINGS")"
    WD_INST="$(jq -r '.env.INSTALL_ID // empty' "$SETTINGS")"
    WD_KEY="$(jq -r '.env.KEY_PATH // empty' "$SETTINGS")"
    case "$WD_KEY" in /*) ;; *) WD_KEY="$WS/$WD_KEY" ;; esac   # absolutize a relative key path
    if [ -n "$WD_APP" ] && [ -n "$WD_INST" ] && [ -n "$WD_KEY" ]; then
      TOKEN_PREFIX="GH_TOKEN=\$($HELPER --app-id $WD_APP --install-id $WD_INST --key $WD_KEY) || exit 1; export GH_TOKEN; "
    else
      echo "WARN: APP_ID/INSTALL_ID/KEY_PATH not all readable from $SETTINGS — no token baked (fleet-doctor may 401). --no-token silences." >&2
    fi
  else
    echo "WARN: token helper or settings missing ($HELPER / $SETTINGS) — no token baked. --no-token silences." >&2
  fi
fi

# runner-watchdog leg (#163): chained with `;` (not `&&`) so a reconcile.sh hiccup
# never suppresses the runner sweep. No GH_TOKEN prefix needed — detection is
# LOCAL-ONLY (systemd unit state), never the GitHub runners API (RUNNER.md
# "security model" — the bot is 403 on administration:read anyway). Reuses the
# SAME $EXECUTE_ARG/$RESTART_ARG dials as reconcile.sh (one operator-trust knob
# for both legs); own log file so triage doesn't have to disentangle two
# watchdogs' output from one stream.
RUNNER_WD_CMD=""
if [ "$WITH_RUNNER_WD" -eq 1 ]; then
  RUNNER_WD_CMD="; $RUNNER_WD $EXECUTE_ARG $RESTART_ARG >> $RUNNER_WD_LOG 2>&1"
fi

# the cron command: explicit PATH (#169) → prelude (extra toolchain, if present)
# → mint GH_TOKEN → run reconcile (+ the optional runner-watchdog leg), appending
# to the respective log(s)
CMD="PATH=$CRON_PATH; export PATH; [ -f $PRELUDE ] && . $PRELUDE; ${TOKEN_PREFIX}$RECON $MANIFEST_ARG $ROUTING_ARG $EXECUTE_ARG $RESTART_ARG >> $LOG 2>&1${RUNNER_WD_CMD}"
LINE="$INTERVAL $CMD $MARKER"

if [ "$PRINT_ONLY" -eq 1 ]; then
  echo "$LINE"; exit 0
fi

# --- preflight: does the CRON environment actually have the toolchain? (#169) --
# A green install MUST mean a working sweep. Both prior failures reproduced only
# under cron's PATH — the environment nobody tested — while the operator's
# interactive shell (devbox/npm-global on PATH) looked perfectly healthy. So probe
# the cron-equivalent env, and aggregate ALL gaps into one report (Pattern D)
# instead of failing on the first.
if [ "$SKIP_PREFLIGHT" -ne 1 ]; then
  cron_env() { env -i PATH="$CRON_PATH" HOME="$HOME" sh -c "$1" 2>/dev/null; }
  missing=""

  # 1. the macf CLI — reconcile.sh's fleet-doctor probe. Mirrors reconcile.sh's
  #    resolution order, so preflight passes exactly when the reconciler will.
  if [ -z "${MACF_FLEET_DOCTOR_CMD:-}" ]; then
    macf_found=""
    for cand in "${MACF_CLI:-}" "$(cron_env 'command -v macf')" "$HOME/.npm-global/bin/macf"; do
      [ -n "$cand" ] && [ -x "$cand" ] && { macf_found="$cand"; break; }
    done
    if [ -n "$macf_found" ]; then
      echo "  ✓ macf CLI: $macf_found"
    else
      missing="$missing\n  - macf CLI not resolvable from cron (PATH=$CRON_PATH, \$HOME/.npm-global/bin) — reconcile.sh's fleet-doctor probe returns empty and every sweep FATALs"
    fi
  else
    echo "  ✓ macf CLI: (operator override MACF_FLEET_DOCTOR_CMD)"
  fi

  # 2. jq — hard requirement of both legs
  if [ -n "$(cron_env 'command -v jq')" ]; then echo "  ✓ jq: $(cron_env 'command -v jq')"
  else missing="$missing\n  - jq not on cron PATH ($CRON_PATH) — both watchdogs abort"; fi

  # 3. YAML→JSON for the runner registry — exercise the REAL converter chain in
  #    the cron env rather than trusting that a binary named `yq` is yq-go.
  if [ "$WITH_RUNNER_WD" -eq 1 ]; then
    RY="$(cd "$(dirname "$RUNNER_WD")" && pwd)/../runner/runners.yaml"
    conv=""
    if [ -n "$(cron_env "yq -o=json '$RY' 2>/dev/null | head -c1")" ];      then conv="yq-go"
    elif [ -n "$(cron_env "yq . '$RY' 2>/dev/null | head -c1")" ];          then conv="python-yq"
    elif [ -n "$(cron_env "python3 -c 'import yaml' >/dev/null 2>&1 && echo ok")" ]; then conv="python3+PyYAML"
    fi
    if [ -n "$conv" ]; then echo "  ✓ YAML→JSON: $conv"
    else missing="$missing\n  - no working YAML→JSON converter on cron PATH — runner-watchdog.sh skips every sweep (this is exactly the #169 outage)"; fi
  fi

  if [ -n "$missing" ]; then
    printf 'FATAL: the cron environment is missing dependencies the watchdogs need:%b\n' "$missing" >&2
    echo "" >&2
    echo "Installing anyway would produce a cron that runs, logs, and does NOTHING —" >&2
    echo "the #169 failure mode (37 days of silent no-op). Fix the gaps, or re-run" >&2
    echo "with --skip-preflight if you are deliberately installing ahead of the deps." >&2
    exit 2
  fi
fi

printf '%s\n%s\n' "$EXISTING" "$LINE" | grep -v '^$' | crontab -
mode="REPORT-ONLY (dry-run)"; [ -n "$EXECUTE_ARG" ] && mode="EXECUTE"; [ -n "$RESTART_ARG" ] && mode="$mode + restart"
runner_wd_note=""; [ "$WITH_RUNNER_WD" -eq 1 ] && runner_wd_note=" + runner-watchdog ($RUNNER_WD_LOG)"
echo "installed macf-watchdog cron [$mode], interval '$INTERVAL', log $LOG$runner_wd_note"
echo "verify: crontab -l | grep macf-watchdog"
