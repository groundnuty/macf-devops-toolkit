#!/usr/bin/env bash
# Tear down the `tailscale serve` config for OTLP ports.
# Inverse of hack/tailscale-otlp-up.sh.

set -euo pipefail

# Same probe-or-sudo pattern as tailscale-otlp-up.sh.
probe=$(tailscale serve reset 2>&1) && tailscale_writable=1 || tailscale_writable=0
case "$probe" in
  *"Access denied"*) tailscale_writable=0 ;;
esac

if [ "$tailscale_writable" -eq 1 ]; then
  echo "Done (no further action — reset succeeded inline above)."
  echo "Verify: tailscale serve status (should print 'No serve config')."
  exit 0
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "::error::tailscale serve needs root + sudo not available."
  exit 1
fi
echo "Resetting tailscale serve config (via sudo)..."
sudo tailscale serve reset 2>&1 | head -3 || true

echo "Done. Tailnet OTLP exposure removed."
echo "Verify: tailscale serve status (should print 'No serve config')."
