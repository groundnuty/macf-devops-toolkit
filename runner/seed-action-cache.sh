#!/usr/bin/env bash
# seed-action-cache.sh — populate ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE for the routing runner
# (devops-toolkit#150, the RUNNER-SIDE latency lever). The runner deletes _work/_actions +
# re-fetches every uses: action from codeload EACH job (by design — ActionManager.cs; #811).
# The archive-cache (native, v2.311+) makes the runner File.Copy a local SHA-keyed tarball
# instead of the network fetch — eliminating the fetch (not the per-job re-extraction).
#
# DRIFT-PROOF: derives the exact {owner}/{repo}/{sha} set from the runner's OWN latest Worker
# log (the codeload URLs it last fetched) — so it seeds precisely what the runner resolves,
# no hardcoded SHAs to rot when a tag moves. Re-run after any router-action change / tag move.
#
# Cache layout (verified from ActionManager.cs source): {cacheDir}/{owner}_{repo}/{sha}.tar.gz
# The runner reads-but-never-populates this dir; SHA-keyed → a moving @vN tag misses + falls
# back to codeload (FAILS SAFE — never breaks, just no speedup until re-seeded).
#
# Run as a user that can WRITE $CACHE_DIR (the operator, since the canonical dir is under the
# macf-runner home). Prints the operator apply/toggle steps at the end.
set -uo pipefail

CACHE_DIR="${MACF_ACTION_ARCHIVE_CACHE:-/opt/macf-runner/action-archive-cache}"
DIAG_DIR="${MACF_RUNNER_DIAG:-/opt/macf-runner/actions-runner/_diag}"

command -v curl >/dev/null || { echo "FATAL: curl not found" >&2; exit 2; }
command -v tar  >/dev/null || { echo "FATAL: tar not found" >&2; exit 2; }

# Derive the action set from the latest Worker log's codeload fetches.
WL="$(ls -t "$DIAG_DIR"/Worker_*.log 2>/dev/null | head -1)"
[ -n "$WL" ] || { echo "FATAL: no Worker log in $DIAG_DIR — run a routing job first so the runner records what it fetches" >&2; exit 2; }
URLS="$(grep -ohE 'https://codeload\.github\.com/[^/]+/[^/]+/tar\.gz/[a-f0-9]+' "$WL" 2>/dev/null | sort -u)"
[ -n "$URLS" ] || { echo "FATAL: no codeload tarball fetches in $WL — nothing to seed" >&2; exit 2; }

echo "Seeding action-archive-cache: $CACHE_DIR"
echo "Source (drift-proof): $WL"
mkdir -p "$CACHE_DIR" || { echo "FATAL: cannot create $CACHE_DIR (run as a user that can write it)" >&2; exit 2; }

n=0 fail=0
while IFS= read -r url; do
  [ -n "$url" ] || continue
  # url = https://codeload.github.com/<owner>/<repo>/tar.gz/<sha>
  rest="${url#https://codeload.github.com/}"
  owner="${rest%%/*}"; rest="${rest#*/}"
  repo="${rest%%/*}"
  sha="${url##*/}"
  key="${owner}_${repo}"
  mkdir -p "$CACHE_DIR/$key"
  out="$CACHE_DIR/$key/$sha.tar.gz"
  if curl -fsSL --max-time 90 -o "$out" "$url" && tar -tzf "$out" >/dev/null 2>&1; then
    echo "  ok  $key/$sha.tar.gz ($(du -h "$out" | cut -f1))"; n=$((n+1))
  else
    echo "  FAIL $key/$sha ($url)"; rm -f "$out" 2>/dev/null; fail=$((fail+1))
  fi
done <<< "$URLS"

echo
echo "Seeded $n archive(s)${fail:+, $fail failed}."
[ "$fail" -eq 0 ] || { echo "→ some fetches failed — cache incomplete (those actions still hit codeload; fails safe)"; exit 1; }

cat <<APPLY

── Operator apply (points the runner at the cache; the RUNNER-SIDE lever ON) ──
  # 1. ensure the runner (macf-runner) can read it
  sudo chown -R macf-runner:macf-runner "$CACHE_DIR"
  # 2. inject the env via the runner's supported .env (svc.sh-regen-safe, clean toggle)
  echo 'ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE=$CACHE_DIR' | sudo tee -a /opt/macf-runner/actions-runner/.env
  # 3. restart the service to pick it up
  cd /opt/macf-runner/actions-runner && sudo ./svc.sh stop && sudo ./svc.sh start

── Verify (empirical) ── after the next routed job, its Worker log should say
  "already exists in cache directory" (File.Copy) instead of "Save archive 'https://codeload…'".

── Toggle OFF (for the A/B baseline) ── remove the ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE
  line from /opt/macf-runner/actions-runner/.env + restart → back to codeload fetch.
APPLY
