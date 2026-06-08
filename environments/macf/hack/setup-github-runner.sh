#!/usr/bin/env bash
# Self-hosted GitHub Actions runner — host setup for the MACF VM (macf-devops-toolkit#90, DR-003).
#
# Why: ~46% of routing wall-clock is Tailscale (connect + a load-bearing
# `sleep 10`). A runner ON the VM pays none of it (already on the tailnet/LAN;
# inject becomes a local `tmux send-keys`) → expected ~40s → ~6-9s (~4-6×).
#
# SECURITY (DR-003): the runner runs workflow code on the VM as its registered
# user. We run as a DEDICATED LOW-PRIV `macf-runner` user FROM THE START
# (operator-confirmed 2026-06-08) — NOT `ubuntu` — whose ONLY elevated grant is
# running the tmux send-helper, per on-VM agent, as that agent's ssh_user, via
# single-command sudoers rules (one helper abspath per agent, enumerated from the
# agent registry the router reads). NO `*.pem` App keys, NO `~/.kube`, NO other
# agents' /proc. So a workflow RCE (PR_TITLE injection, fork-PR secrets) is bounded
# to "can send a tmux prompt to an agent", not "owns the host + every bot identity".
#
# GATES — `register`/`start` are intentionally NOT run by `setup`. Do NOT
# register until ALL hold (see DR-003 "Gates"):
#   1. macf-actions#47 (PR_TITLE injection hardening) MERGED.
#   2. fork-PR toggles OFF + fork-approval-required on macf + macf-actions (operator).
#   3. org-scoped registration token available (operator/org-admin).
#   4. runner group scoped to macf + macf-actions; egress restricted (operator).
#
# Usage:
#   setup-github-runner.sh setup       # host prep: user + minimal grant + download + wrapper + unit. No token. SAFE/reversible.
#   REG_TOKEN=<org-reg-token> setup-github-runner.sh register   # config + install service. GATED — prints the checklist, needs REG_TOKEN.
#   setup-github-runner.sh status      # show what's installed
# Override via env: RUNNER_USER RUNNER_DIR RUNNER_VERSION ORG_URL LABELS RUNNER_GROUP EPHEMERAL AGENT_OWNER SEND_HELPER AGENT_CONFIG

set -euo pipefail

RUNNER_USER="${RUNNER_USER:-macf-runner}"          # low-priv, NOT ubuntu (DR-003)
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_VERSION="${RUNNER_VERSION:-}"               # empty → fetch latest at setup
ORG_URL="${ORG_URL:-https://github.com/groundnuty}"
LABELS="${LABELS:-self-hosted,macf-vm}"
RUNNER_GROUP="${RUNNER_GROUP:-macf-vm-runners}"    # operator scopes this group to macf + macf-actions
EPHEMERAL="${EPHEMERAL:-true}"                      # production posture; spike MAY use false for simplicity (DR-003)
AGENT_OWNER="${AGENT_OWNER:-ubuntu}"               # the user the agent tmux sessions run as
SEND_HELPER="${SEND_HELPER:-$(cd "$(dirname "$0")/../../.." && pwd)/.claude/scripts/tmux-send-to-claude.sh}"
# The router (macf-actions#53 no-SSH inject) calls ${workspace_dir}/.claude/scripts/
# tmux-send-to-claude.sh as each TARGET agent's ssh_user. The grant is derived from
# this registry (same one the router reads) so it authorizes EXACTLY those abspaths.
AGENT_CONFIG="${AGENT_CONFIG:-$(cd "$(dirname "$0")/../../.." && pwd)/.github/agent-config.json}"
SUDOERS_FILE="${SUDOERS_FILE:-/etc/sudoers.d/macf-runner-tmux-send}"

die() { echo "FATAL: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "this phase needs root (run via sudo); current uid=$(id -u)"; }

# --- low-priv bound verification (DR-003 MUST, #91 review) ---------------------
# The bound rests on one precondition: $RUNNER_USER must not be able to REPLACE the
# sudoers-allowed helper. If it can (rewrite the file, or write+traverse to a parent
# dir to swap it), the NOPASSWD grant becomes arbitrary code as $AGENT_OWNER — the
# bound collapses to full-$AGENT_OWNER, the exact thing this setup prevents.
#
# We model standard POSIX perms with TRAVERSAL: an un-searchable ancestor (e.g. a
# 0750 home dir) makes everything below it unreachable to $RUNNER_USER, so a deeper
# world-writable dir is not actually exploitable. Pure-bash (no sudo) so it's the
# same check whether run here in test or as root at setup. (ACLs aren't modelled;
# this host's chain has none.)
_runner_in_group() { id -nG "$RUNNER_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$1"; }
# Can $RUNNER_USER write (or chmod, if owner) path $1?
_runner_can_write() {
  local owner group ugo
  owner="$(stat -c '%U' "$1" 2>/dev/null)" || return 0   # unstat-able → fail closed
  group="$(stat -c '%G' "$1" 2>/dev/null)" || return 0
  ugo="$(stat -c '%a' "$1" 2>/dev/null)" || return 0; ugo="${ugo: -3}"
  [ "$owner" = "$RUNNER_USER" ] && return 0               # owner can chmod itself writable
  case "${ugo:2:1}" in 2|3|6|7) return 0 ;; esac          # other-write
  case "${ugo:1:1}" in 2|3|6|7) _runner_in_group "$group" && return 0 ;; esac
  return 1
}
# Can $RUNNER_USER search (traverse) dir $1?
_runner_can_search() {
  local owner group ugo
  owner="$(stat -c '%U' "$1" 2>/dev/null)" || return 1
  group="$(stat -c '%G' "$1" 2>/dev/null)" || return 1
  ugo="$(stat -c '%a' "$1" 2>/dev/null)" || return 1; ugo="${ugo: -3}"
  [ "$owner" = "$RUNNER_USER" ] && return 0
  case "${ugo:2:1}" in 1|3|5|7) return 0 ;; esac          # other-exec
  case "${ugo:1:1}" in 1|3|5|7) _runner_in_group "$group" && return 0 ;; esac
  return 1
}
# Walk / → $1; die if $RUNNER_USER can replace the helper. A writable+reachable dir
# lets it swap the child (unless sticky — sticky blocks renaming others' entries);
# the file itself dies if writable+reachable. Writable-but-unreachable dirs are a
# non-fatal latent-risk note (exploitable only if an ancestor's perms later loosen).
assert_helper_unreplaceable() {
  local helper="$1" c i reachable=1 p="$1"
  local -a comps=()
  while :; do comps=("$p" "${comps[@]}"); [ "$p" = "/" ] && break; p="$(dirname "$p")"; done
  local n=${#comps[@]}
  for ((i=0; i<n; i++)); do
    c="${comps[$i]}"
    if [ "$i" -eq $((n-1)) ]; then                        # the helper file itself
      if [ "$reachable" = 1 ] && _runner_can_write "$c"; then
        die "SECURITY: helper '$c' is writable by '$RUNNER_USER' → it could rewrite the sudoers-allowed script and run code as '$AGENT_OWNER'. Make it root/$AGENT_OWNER-owned, mode<=0755 (owner not $RUNNER_USER), then re-run."
      fi
    else                                                  # an ancestor directory
      if [ "$reachable" = 1 ]; then
        if _runner_can_write "$c" && ! [ -k "$c" ]; then
          die "SECURITY: directory '$c' is writable+reachable by '$RUNNER_USER' → it could swap '$helper' (or its subtree) and run code as '$AGENT_OWNER'. Tighten its perms (root-owned, no group/other write) before re-running."
        fi
      elif _runner_can_write "$c" && ! [ -k "$c" ]; then
        echo "[setup] note: '$c' is writable by '$RUNNER_USER' but currently UNREACHABLE (an ancestor denies traversal). Latent risk only — tighten if that ancestor's perms might loosen." >&2
      fi
      [ "$reachable" = 1 ] && { _runner_can_search "$c" || reachable=0; }
    fi
  done
}

# Install the sudoers grant: $RUNNER_USER may run ONLY the send-helper, as each on-VM
# agent's ssh_user, for EXACTLY the abspaths the router invokes. The router
# (macf-actions#53 no-SSH inject) calls `${workspace_dir}/.claude/scripts/tmux-send-to-
# claude.sh` as the target agent's ssh_user, per target — and these are per-workspace
# copies at DIFFERENT abspaths. sudo matches the literal command path, so a single-path
# grant would silently deny inject to every other agent. We enumerate from the same
# registry the router reads ($AGENT_CONFIG), grant one sudoers line per runas-user
# (comma-separated helpers), and assert each helper unreplaceable. Local (existing)
# helpers only — an off-VM agent uses SSH, not this path. Re-run setup when agents change.
install_sudoers_grant() {
  declare -A grants=()
  local count=0 runas wdir helper rp suffix=".claude/scripts/tmux-send-to-claude.sh"
  if [ -r "$AGENT_CONFIG" ] && command -v jq >/dev/null 2>&1; then
    echo "[setup] deriving inject-target helpers from agent registry: $AGENT_CONFIG"
    local rows
    rows="$(jq -r '.agents | to_entries[] | "\(.value.ssh_user)\t\(.value.workspace_dir)"' "$AGENT_CONFIG")" \
      || die "failed to parse agent registry $AGENT_CONFIG — refusing to fall back to a single-agent grant (that would silently deny inject to the other agents)"
    while IFS=$'\t' read -r runas wdir; do
      [ -n "$runas" ] && [ -n "$wdir" ] || continue
      helper="${wdir%/}/${suffix}"
      if [ ! -x "$helper" ]; then
        echo "[setup] note: skip '$helper' (runas=$runas) — not present locally; an off-VM agent uses SSH, not the direct-helper path" >&2
        continue
      fi
      assert_helper_unreplaceable "$helper"
      rp="$(readlink -f "$helper")"; [ "$rp" = "$helper" ] || assert_helper_unreplaceable "$rp"
      if [ -n "${grants[$runas]:-}" ]; then grants[$runas]="${grants[$runas]}, $helper"; else grants[$runas]="$helper"; fi
      count=$((count + 1))
      echo "[setup]   + ${runas} may run ${helper}"
    done <<< "$rows"
  fi
  if [ "$count" -eq 0 ]; then
    echo "[setup] no registry-derived helpers usable; falling back to single grant ${AGENT_OWNER} → ${SEND_HELPER}"
    [ -x "$SEND_HELPER" ] || die "no usable $AGENT_CONFIG and send helper not executable at $SEND_HELPER (set AGENT_CONFIG= or SEND_HELPER=)"
    assert_helper_unreplaceable "$SEND_HELPER"
    rp="$(readlink -f "$SEND_HELPER")"; [ "$rp" = "$SEND_HELPER" ] || assert_helper_unreplaceable "$rp"
    grants[$AGENT_OWNER]="$SEND_HELPER"
    count=1
  fi
  local tmp="${SUDOERS_FILE}.tmp.$$" u
  : > "$tmp"
  for u in "${!grants[@]}"; do
    printf '%s ALL=(%s) NOPASSWD: %s\n' "$RUNNER_USER" "$u" "${grants[$u]}" >> "$tmp"
  done
  chmod 0440 "$tmp"
  visudo -cf "$tmp" || { rm -f "$tmp"; die "sudoers validation failed — not installed"; }
  mv "$tmp" "$SUDOERS_FILE"
  echo "[setup] installed $SUDOERS_FILE — ${count} helper(s) verified unreplaceable + authorized:"
  sed 's/^/[setup]   /' "$SUDOERS_FILE"
}

print_gates() {
  cat <<'GATES'
=== GATE CHECKLIST — ALL required before register (DR-003) ===
  [ ] macf-actions#47 (PR_TITLE injection hardening) MERGED
  [ ] fork-PR toggles OFF + fork-approval-required on macf + macf-actions (operator)
  [ ] org-scoped registration token available (operator/org-admin) → REG_TOKEN
  [ ] runner group scoped to macf + macf-actions; egress restricted (operator)
GATES
}

phase_setup() {
  need_root
  echo "[setup] creating low-priv runner user '${RUNNER_USER}' (no login shell, no sudo except the send-helper)"
  id "$RUNNER_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin "$RUNNER_USER"

  echo "[setup] installing single-command sudoers grant: ${RUNNER_USER} may run ONLY the send-helper, per on-VM agent (run-as that agent's ssh_user). MUST (DR-003/#91): each helper is asserted unreplaceable before the grant is written, so a violated precondition never installs the grant."
  install_sudoers_grant

  local ver="$RUNNER_VERSION"
  if [ -z "$ver" ]; then
    echo "[setup] resolving latest actions/runner release..."
    ver="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')" \
      || die "could not resolve latest runner version (set RUNNER_VERSION=)"
  fi
  echo "[setup] installing actions/runner ${ver} to ${RUNNER_DIR} (owned by ${RUNNER_USER})"
  mkdir -p "$RUNNER_DIR"
  local arch=x64; local tgz="actions-runner-linux-${arch}-${ver}.tar.gz"
  if [ ! -f "${RUNNER_DIR}/run.sh" ]; then
    curl -fsSL -o "/tmp/${tgz}" "https://github.com/actions/runner/releases/download/v${ver}/${tgz}" || die "runner download failed"
    tar -C "$RUNNER_DIR" -xzf "/tmp/${tgz}"; rm -f "/tmp/${tgz}"
  fi
  chown -R "$RUNNER_USER":"$RUNNER_USER" "$RUNNER_DIR"

  echo "[setup] writing ephemeral respawn wrapper + systemd unit (NOT started)"
  cat > "${RUNNER_DIR}/run-ephemeral.sh" <<WRAP
#!/usr/bin/env bash
# Ephemeral respawn loop: each iteration mints a FRESH org registration token
# (RUNNER_TOKEN_CMD — operator wires a GitHub App/PAT with
# organization_self_hosted_runners:write), configures a one-shot runner, runs
# ONE job, then loops. config state never persists across jobs.
set -euo pipefail
cd "${RUNNER_DIR}"
: "\${RUNNER_TOKEN_CMD:?set RUNNER_TOKEN_CMD to a command that prints a fresh registration token}"
while true; do
  TOKEN="\$(\$RUNNER_TOKEN_CMD)" || { echo "token mint failed; retrying in 30s" >&2; sleep 30; continue; }
  ./config.sh --unattended --replace --url "${ORG_URL}" --token "\$TOKEN" \\
    --labels "${LABELS}" --runnergroup "${RUNNER_GROUP}" --ephemeral --name "macf-vm-\$(hostname -s)"
  ./run.sh || true   # ephemeral: exits after one job
done
WRAP
  chmod +x "${RUNNER_DIR}/run-ephemeral.sh"
  chown "$RUNNER_USER":"$RUNNER_USER" "${RUNNER_DIR}/run-ephemeral.sh"

  cat > /etc/systemd/system/macf-github-runner.service <<UNIT
[Unit]
Description=MACF self-hosted GitHub Actions runner (ephemeral, low-priv) — DR-003
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
User=${RUNNER_USER}
WorkingDirectory=${RUNNER_DIR}
# RUNNER_TOKEN_CMD must be provided via an EnvironmentFile the operator installs
# (the token-mint credential). Until then the unit fails fast (no silent no-op).
EnvironmentFile=/etc/macf-github-runner.env
ExecStart=${RUNNER_DIR}/run-ephemeral.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  echo "[setup] DONE. Runner downloaded + user + grant + wrapper + unit in place."
  echo "[setup] NOT registered/started. When the gates clear, run: REG_TOKEN=... $0 register"
  print_gates
}

phase_register() {
  need_root
  print_gates
  : "${REG_TOKEN:?register needs REG_TOKEN (org-scoped registration token from the operator/org-admin)}"
  echo ">>> Proceeding to register — confirm the gate checklist above is satisfied. Ctrl-C now if not."
  [ -f "${RUNNER_DIR}/config.sh" ] || die "runner not set up; run '$0 setup' first"
  if [ "$EPHEMERAL" = "true" ]; then
    echo "[register] ephemeral mode → install the systemd respawn unit (needs RUNNER_TOKEN_CMD in /etc/macf-github-runner.env)"
    [ -f /etc/macf-github-runner.env ] || die "create /etc/macf-github-runner.env with RUNNER_TOKEN_CMD=... first (token-mint credential)"
    # NOTE 2 (DR-003 / #91 review): the env file holds the org token-mint credential,
    # reachable by a macf-runner RCE via /proc/self/environ — so it MUST be root-owned
    # and unreadable by group/other. Assert it (true-by-construction, not by-trust).
    _env_owner="$(stat -c '%U' /etc/macf-github-runner.env)"
    _env_mode="$(stat -c '%a' /etc/macf-github-runner.env)"
    [ "$_env_owner" = "root" ] || die "/etc/macf-github-runner.env must be root-owned (is: $_env_owner) — it holds the token-mint credential (DR-003)"
    case "${_env_mode: -2}" in 00) : ;; *) die "/etc/macf-github-runner.env must be 0600 / group+other unreadable (is: $_env_mode) — holds the token-mint credential (DR-003)" ;; esac
    systemctl enable --now macf-github-runner.service
  else
    echo "[register] non-ephemeral (spike) → one-shot config + svc.sh install"
    # MINOR (#91 review): pass REG_TOKEN via preserved env, not interpolated into the
    # bash -c string, so it isn't visible in the wrapper's argv. (config.sh still takes
    # --token as an arg → briefly ps-visible during its own short run; the registration
    # token is short-lived + single-use, so the residual is bounded.)
    export REG_TOKEN
    sudo --preserve-env=REG_TOKEN -u "$RUNNER_USER" bash -c '
      cd "$1" || exit 1
      ./config.sh --unattended --replace --url "$2" --token "$REG_TOKEN" \
        --labels "$3" --runnergroup "$4" --name "macf-vm-$(hostname -s)"
    ' _ "$RUNNER_DIR" "$ORG_URL" "$LABELS" "$RUNNER_GROUP"
    "${RUNNER_DIR}/svc.sh" install "$RUNNER_USER"
    "${RUNNER_DIR}/svc.sh" start
  fi
  echo "[register] DONE."
}

# Sourceable for tests (e.g. the write-protection assert) without running dispatch.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    setup)    phase_setup ;;
    register) phase_register ;;
    status)
      echo "user: $(id "$RUNNER_USER" 2>/dev/null || echo 'NOT created')"
      echo "runner dir: $([ -f "${RUNNER_DIR}/run.sh" ] && echo "$RUNNER_DIR (installed)" || echo 'NOT installed')"
      echo "sudoers grant: $([ -f "$SUDOERS_FILE" ] && echo present || echo absent)"
      echo "systemd unit: $(systemctl list-unit-files macf-github-runner.service 2>/dev/null | grep -q macf && echo installed || echo absent)"
      ;;
    *) echo "usage: $0 {setup|register|status}"; echo; print_gates ;;
  esac
fi
