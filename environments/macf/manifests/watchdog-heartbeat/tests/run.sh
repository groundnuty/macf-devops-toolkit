#!/usr/bin/env bash
# run.sh — promtool unit-test the watchdog-heartbeat alert rules.
#
# promtool can't parse a k8s PrometheusRule CR directly (it wants raw `groups:`), so
# extract `.spec` from ../promrule.yaml into a transient rules.generated.yaml and test
# THAT — i.e. the actual shipped rules, no drift. Needs promtool on PATH (or $PROMTOOL).
# Runs anywhere, no cluster context (science's #137 review — verify the watcher itself).
set -euo pipefail
cd "$(dirname "$0")"
PROMTOOL="${PROMTOOL:-promtool}"
command -v "$PROMTOOL" >/dev/null || {
  echo "FATAL: promtool not found. Install prometheus (nixpkgs#prometheus lacks promtool;" >&2
  echo "       grab the release tarball) or set PROMTOOL=/path/to/promtool." >&2
  exit 2
}
trap 'rm -f rules.generated.yaml' EXIT
python3 -c "import yaml,sys; yaml.safe_dump(yaml.safe_load(open('../promrule.yaml'))['spec'], sys.stdout, default_flow_style=False, sort_keys=False)" > rules.generated.yaml
"$PROMTOOL" test rules promrule-tests.yaml
