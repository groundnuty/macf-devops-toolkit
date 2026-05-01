#!/usr/bin/env bash
# Expose the cluster's OTLP endpoints over the tailnet via `tailscale serve`,
# without binding k3d ports to non-loopback host interfaces.
#
# Why: agents running off-VM (operator's laptop, future remote testers)
# need to send OTLP to the cluster. The k3d port-mappings bind to
# 127.0.0.1 only — Tailscale-routed traffic on the VM's tailscale0
# interface never reaches a localhost-bound listener. Two alternatives
# considered:
#   - Bind k3d ports to 0.0.0.0 → exposes on ens3 (cloud private subnet
#     with default route to internet); rejected even though VM has no
#     public IP, because we may not be alone on the subnet.
#   - Bind k3d ports to the Tailscale IP (100.x.y.z) → exact, but
#     pins the binding to a Tailscale IP that may rotate (rare but
#     possible after `tailscale logout`/relogin); rejected for IP-
#     hardcoding fragility.
#
# `tailscale serve` is the right primitive: listens ONLY on the
# tailnet interface (handled by tailscaled, not by IP binding), DNS-
# stable via MagicDNS hostname (`<machine>.<tailnet>.ts.net`), gated
# by tailnet ACLs. Forwards to the existing localhost-bound k3d ports.
#
# Idempotent — re-running this script reconfigures `tailscale serve`
# from scratch (`tailscale serve reset` first).
#
# Operator: run once on the VM. Persists across `tailscaled` restarts
# via tailscale's own state.

set -euo pipefail

ports=(14317 14318 4317 4318)

# `tailscale serve` write ops require root. Probe by attempting a
# no-op `serve reset` — silent success means we have access; otherwise
# fall back to sudo (passwordless if NOPASSWD is configured, else
# interactive prompt). Either path needs operator-side privilege.
#
# One-time recommendation for operators: `sudo tailscale set
# --operator=$USER` makes subsequent `tailscale serve` invocations
# work without sudo entirely.
probe=$(tailscale serve reset 2>&1) && tailscale_writable=1 || tailscale_writable=0
case "$probe" in
  *"Access denied"*) tailscale_writable=0 ;;
esac

if [ "$tailscale_writable" -eq 1 ]; then
  TS=tailscale
else
  if ! command -v sudo >/dev/null 2>&1; then
    echo "::error::tailscale serve needs root + sudo not available."
    echo "Run on the VM with the right privilege OR set --operator=\$USER:"
    echo "  sudo tailscale set --operator=\$USER     # one-time"
    exit 1
  fi
  TS="sudo tailscale"
  echo "tailscale serve write requires sudo (operator may be prompted)."
fi

echo "Resetting any existing tailscale serve config..."
$TS serve reset 2>&1 | head -3 || true

echo "Configuring tailscale serve for OTLP ports..."
for port in "${ports[@]}"; do
  echo "  ${port} → tcp://localhost:${port}"
  $TS serve --bg --tcp="${port}" "tcp://localhost:${port}"
done

echo ""
echo "Configured. Status:"
tailscale serve status 2>&1 | head -20

echo ""
echo "Laptop agents can now reach OTLP at:"
echo "  $(tailscale status --self --json 2>/dev/null | jq -r '.Self.DNSName // "<machine>.<tailnet>.ts.net"' | sed 's|\.$||'):14318  (HTTP)"
echo "  $(tailscale status --self --json 2>/dev/null | jq -r '.Self.DNSName // "<machine>.<tailnet>.ts.net"' | sed 's|\.$||'):14317  (gRPC)"
echo ""
echo "Set MACF_OTEL_ENDPOINT=http://<that-hostname>:14318 in laptop's macf init/update."
