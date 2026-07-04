#!/usr/bin/env bash
#
# enable-runner-watchdog.sh — the ONE command that does the 3 manual steps
# fleet/README.md "Runner-watchdog cron wiring" previously asked an operator to
# perform by hand before `--with-runner-watchdog` does anything useful:
#
#   1. yq on the GLOBAL devbox profile (cron's bare env only sees `devbox global`
#      packages via host-prelude.sh's `eval "$(devbox global shellenv)"` — the
#      `runner/devbox.json`-pinned yq is a PROJECT shell, invisible to cron).
#   2. the `/etc/sudoers.d/macf-runner-watchdog` NOPASSWD grant runner-watchdog.sh's
#      `sudo -n systemctl restart actions.runner.*.service` heal-tier needs
#      (fleet/README.md "Runner-watchdog (#163)" / runner/RUNNER.md).
#   3. `fleet/install-cron.sh --execute --allow-restart --with-runner-watchdog`
#      itself — the cron wiring.
#
# PRIVILEGE SPLIT (deliberate, not incidental): this script runs AS THE OPERATOR
# throughout and escalates via `sudo` ONLY for step 2's sudoers-file write. Steps
# 1 and 3 are PER-USER state (a devbox global profile; a user crontab) — running
# them as root would install yq into root's devbox profile and wire the cron into
# root's crontab, neither of which is where the cron / host-prelude.sh actually
# look. So `runner/Makefile`'s `enable-runner-watchdog` target invokes this
# script UNWRAPPED (no `sudo`); if invoked directly, `$SUDO_USER` is unset and OP
# resolves to the caller's own login — the common case. If someone runs this
# under `sudo` anyway, OP still resolves to the REAL operator behind the `sudo`
# (not root), so steps 1/3 land in the right place regardless.
#
# Mirrors runner/setup-macf-runner-user.sh's sudoers-install pattern exactly
# (mktemp -> visudo -c -f -> install -m 0440, root:root) — a bad sudoers file
# can lock out `sudo` fleet-wide, so it is validated BEFORE install, never after.
#
# Idempotent: re-running is safe — yq/PATH check short-circuits, the sudoers file
# is overwritten with the same content, install-cron.sh's cron-line replace is
# itself marker-guarded (see its own header).
#
# Refs: fleet/README.md "Runner-watchdog cron wiring"; runner/setup-macf-runner-user.sh
# (sudoers pattern this mirrors); fleet/install-cron.sh (step 3).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_CRON="$SCRIPT_DIR/install-cron.sh"
SUDOERS_FILE="${MACF_RUNNER_WATCHDOG_SUDOERS:-/etc/sudoers.d/macf-runner-watchdog}"
SYSTEMCTL_BIN="${MACF_RUNNER_WATCHDOG_SYSTEMCTL_BIN:-/usr/bin/systemctl}"

usage() {
  cat <<USAGE
enable-runner-watchdog.sh — one-shot enable for the runner-liveness watchdog's
cron healing (fleet/README.md "Runner-watchdog cron wiring"). Does, idempotently:

  1. yq on the GLOBAL devbox profile (devbox global add yq-go) — WARNS (does not
     fail) if devbox itself is absent; runner-watchdog.sh's cron leg already
     fails open with a clear diagnostic in that case.
  2. installs $SUDOERS_FILE (validated via 'visudo -c' BEFORE install, same
     guard as runner/setup-macf-runner-user.sh) granting the invoking operator
     NOPASSWD 'systemctl restart actions.runner.*.service' — the heal-tier
     runner-watchdog.sh needs.
  3. runs install-cron.sh --execute --allow-restart --with-runner-watchdog to
     wire the cron itself.

Runs AS THE OPERATOR throughout; escalates via sudo ONLY for step 2's sudoers
write (steps 1 + 3 are per-user state — devbox global profile, user crontab —
and must NOT land in root's).

  -h, --help

Env overrides (rarely needed):
  MACF_RUNNER_WATCHDOG_SUDOERS      sudoers file path (default: $SUDOERS_FILE)
  MACF_RUNNER_WATCHDOG_SYSTEMCTL_BIN  systemctl path in the grant (default: $SYSTEMCTL_BIN)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "enable-runner-watchdog.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Resolve the OPERATOR (the cron user) — the real login behind a `sudo` re-exec
# if present, else the invoking user directly. See file header "PRIVILEGE SPLIT".
OP="${SUDO_USER:-$(id -un)}"
echo "== enable-runner-watchdog: operator=$OP =="

FAIL=0

# --- Step 1: yq on the GLOBAL devbox profile ---------------------------------
echo
echo "-- step 1/3: yq (global devbox profile) --"
if command -v yq >/dev/null 2>&1; then
  echo "yq already on PATH ($(command -v yq)) — nothing to do."
elif ! command -v devbox >/dev/null 2>&1; then
  echo "WARN: devbox not found on PATH — cannot 'devbox global add yq-go' automatically." >&2
  echo "      runner-watchdog.sh's cron leg fails open (skips the sweep) without yq —" >&2
  echo "      install devbox, or add yq to the global PATH another way, then re-run." >&2
else
  if [ "$(id -u)" = 0 ]; then
    # devbox global is per-user state; if we're root (re-exec'd via sudo), run it
    # as $OP with $OP's HOME so it lands in $OP's profile, not root's.
    if sudo -H -u "$OP" -- devbox global add yq-go; then
      echo "installed yq-go into $OP's devbox global profile."
    else
      echo "WARN: 'devbox global add yq-go' (as $OP) failed — see output above." >&2
    fi
  else
    if devbox global add yq-go; then
      echo "installed yq-go into $OP's devbox global profile."
    else
      echo "WARN: 'devbox global add yq-go' failed — see output above." >&2
    fi
  fi
fi

# --- Step 2: the sudoers grant (mirrors setup-macf-runner-user.sh) -----------
echo
echo "-- step 2/3: sudoers grant ($SUDOERS_FILE) --"
TMP="$(mktemp)"
printf '%s ALL=(root) NOPASSWD: %s restart actions.runner.*.service\n' "$OP" "$SYSTEMCTL_BIN" > "$TMP"
if sudo visudo -c -f "$TMP" >/dev/null 2>&1; then
  if sudo install -m 0440 -o root -g root "$TMP" "$SUDOERS_FILE"; then
    echo "installed $SUDOERS_FILE: $OP may run '$SYSTEMCTL_BIN restart actions.runner.*.service' NOPASSWD."
  else
    echo "FATAL: sudo install of $SUDOERS_FILE failed." >&2
    FAIL=1
  fi
else
  echo "FATAL: generated sudoers rule failed 'visudo -c' — NOT installed. Contents attempted:" >&2
  cat "$TMP" >&2
  FAIL=1
fi
rm -f "$TMP"

if [ "$FAIL" -eq 1 ]; then
  echo
  echo "FATAL: step 2 (sudoers) failed — aborting before step 3 (cron wiring)." >&2
  echo "       Fix the sudoers issue above and re-run; steps 1 (yq) already applied is fine (idempotent)." >&2
  exit 1
fi

# --- Step 3: wire the cron ----------------------------------------------------
echo
echo "-- step 3/3: cron wiring (install-cron.sh --execute --allow-restart --with-runner-watchdog) --"
[ -x "$INSTALL_CRON" ] || { echo "FATAL: install-cron.sh not found or not executable at $INSTALL_CRON" >&2; exit 1; }

if [ "$(id -u)" = 0 ]; then
  # crontab -/HOME-relative defaults inside install-cron.sh must resolve against
  # $OP's identity, not root's — same per-user-state reasoning as step 1.
  sudo -H -u "$OP" -- "$INSTALL_CRON" --execute --allow-restart --with-runner-watchdog
  RC=$?
else
  "$INSTALL_CRON" --execute --allow-restart --with-runner-watchdog
  RC=$?
fi

if [ "$RC" -ne 0 ]; then
  echo "FATAL: install-cron.sh exited $RC — cron wiring did NOT complete." >&2
  exit 1
fi

echo
echo "== enable-runner-watchdog: done =="
echo "verify with: crontab -l | grep macf-watchdog"
echo "             sudo -n systemctl restart actions.runner.THIS-IS-A-TEST.service ; echo \$?   # (as $OP; expect 1/'not found', NOT a password prompt)"
