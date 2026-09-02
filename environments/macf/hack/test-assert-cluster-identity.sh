#!/usr/bin/env bash
#
# test-assert-cluster-identity.sh — unit tests for the cluster-identity guard
# (devops-toolkit#202), no cluster required.
#
# assert_cluster_identity's only external dependency is `kubectl`. This
# stubs it with a fake binary on PATH that answers `config current-context`
# and `get secret ... -o jsonpath=...` from env vars the test sets, so the
# whole matrix runs offline with zero risk of touching a real cluster.
#
# Run: ./environments/macf/hack/test-assert-cluster-identity.sh

set -uo pipefail
cd "$(dirname "$0")" || exit 1
ACI=./assert-cluster-identity.sh
pass=0 fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# shellcheck source=./assert-cluster-identity.sh
. "$ACI"

EXPECTED="argocd-applications_kube-prometheus-stack:/Secret:monitoring/kube-prom-stack-grafana"

FAKE_BIN="$(mktemp -d)"
cat > "$FAKE_BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
# Test double. Scripted via env vars set by the test driver (MUST be
# `export`ed by the driver — this runs as a separate exec'd process, so a
# plain shell-variable assignment in the driver would never reach it):
#   FAKE_CONTEXT        — what `config current-context` prints
#   FAKE_TRACKING_ID    — what the get-secret jsonpath returns (unset = secret/annotation absent)
case "$*" in
  "config current-context"*)
    echo "${FAKE_CONTEXT:-}"
    exit 0
    ;;
  *"get secret"*)
    if [ -z "${FAKE_TRACKING_ID+x}" ]; then
      echo "Error from server (NotFound): secrets not found" >&2
      exit 1
    fi
    echo "$FAKE_TRACKING_ID"
    exit 0
    ;;
esac
echo "test double: unstubbed kubectl invocation: $*" >&2
exit 99
STUB
chmod +x "$FAKE_BIN/kubectl"
export PATH="$FAKE_BIN:$PATH"
trap 'rm -rf "$FAKE_BIN"' EXIT

# reset() clears the stub's scripted state between scenarios — a var set by
# one block must not leak into the next (the earlier draft of this test got
# this wrong in a different way: it never exported at all, so the stub saw
# nothing and every scenario silently exercised the SAME unstubbed-empty
# path. Verified by first running it unexported and watching the "matching
# tracking-id" case fail before adding the exports below.)
reset_stub() { unset FAKE_CONTEXT FAKE_TRACKING_ID; }

echo "== matching tracking-id: allow =="
reset_stub
export FAKE_CONTEXT="k3s-monitoring"
export FAKE_TRACKING_ID="$EXPECTED"
out="$(assert_cluster_identity 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "matching tracking-id exits 0" || bad "matching tracking-id exited $rc: $out"
case "$out" in *"cluster-identity confirmed"*) ok "prints a confirmation line" ;; *) bad "no confirmation line: $out" ;; esac

echo "== the #202 near-miss: right namespace/secret NAME, wrong cluster =="
# This is exactly the shape of the near-miss: the object resolves (get
# succeeds) but its tracking-id belongs to a different Application/cluster.
reset_stub
export FAKE_CONTEXT="kind-datalake-v2"
export FAKE_TRACKING_ID="some-other-app:/Secret:monitoring/kube-prom-stack-grafana"
out="$(assert_cluster_identity 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "mismatched tracking-id refuses (exit $rc)" || bad "mismatched tracking-id exited 0 — would have mutated the wrong cluster"
case "$out" in *"FATAL"*) ok "prints FATAL on mismatch" ;; *) bad "no FATAL: $out" ;; esac
case "$out" in *"kind-datalake-v2"*) ok "names the context it found" ;; *) bad "context not named: $out" ;; esac
case "$out" in *"$EXPECTED"*) ok "names the tracking-id it expected" ;; *) bad "expected value not named: $out" ;; esac

echo "== secret/annotation entirely absent (wrong cluster, or not-yet-synced fresh bootstrap) =="
reset_stub
export FAKE_CONTEXT="kind-datalake-v2"
out="$(assert_cluster_identity 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "absent secret refuses (exit $rc)" || bad "absent secret exited 0"
case "$out" in *"not found"*) ok "diagnoses as not-found rather than a silent empty compare" ;; *) bad "no not-found diagnosis: $out" ;; esac
case "$out" in *"hasn't synced yet"*) ok "surfaces the fresh-bootstrap-race explanation, not just 'wrong cluster'" ;; *) bad "no fresh-bootstrap explanation: $out" ;; esac

echo "== MACF_SKIP_CLUSTER_CHECK=1 bypasses even on a hard mismatch =="
reset_stub
export FAKE_CONTEXT="kind-datalake-v2"
export FAKE_TRACKING_ID="wrong"
export MACF_SKIP_CLUSTER_CHECK=1
out="$(assert_cluster_identity 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "override exits 0 despite mismatch" || bad "override did not bypass (exit $rc)"
case "$out" in *"WARNING"*"bypassed"*) ok "override prints a loud WARNING, not silence" ;; *) bad "no bypass warning: $out" ;; esac
unset MACF_SKIP_CLUSTER_CHECK

echo "== jsonpath key-escaping matches the real annotation (regression for the dotted-key gotcha) =="
# assert-cluster-identity.sh's OWN jsonpath literal, verified once (outside
# this stub, no cluster) against `kubectl apply --dry-run=client` on a
# hand-built Secret carrying the real annotation — see the PR description.
# This test only guards against someone changing the escaping and silently
# breaking the extraction; it re-checks the source text, not kubectl itself.
grep -qF 'annotations.argocd\.argoproj\.io/tracking-id' "$ACI" \
  && ok "jsonpath dots are backslash-escaped (unescaped would return empty, not an error)" \
  || bad "jsonpath escaping missing/changed — re-verify with kubectl apply --dry-run=client before shipping"

reset_stub
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
