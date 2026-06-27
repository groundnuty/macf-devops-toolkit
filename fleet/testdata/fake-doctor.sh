#!/usr/bin/env bash
# Test helper: emulate a `doctor` CLI that emits JSON then exits NON-ZERO on a
# DEGRADED verdict (the real fleet/routing-doctor health-check convention), so the
# offline suite can exercise reconcile.sh's live-command path (which --fleet-json
# bypasses). See test-reconcile.sh "probe exit-code handling".
here="$(dirname "$0")"
case "${1:-}" in
  degraded) cat "$here/fleet-degraded.json"; exit 1 ;;   # valid JSON, exit 1 = DEGRADED
  fail)     echo "Bad credentials" >&2; exit 1 ;;         # genuine failure: non-JSON, exit 1
  *)        cat "$here/fleet-healthy.json"; exit 0 ;;
esac
