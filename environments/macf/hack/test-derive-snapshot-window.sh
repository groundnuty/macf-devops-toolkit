#!/usr/bin/env bash
#
# test-derive-snapshot-window.sh — unit tests for the activity-window derivation
# (macf-devops-toolkit#177).
#
# The merge/reduce core is pure arithmetic on epochs, so it is tested directly
# with no gh and no network. The gh-dependent half is exercised through
# --events-file, which feeds the same jq extraction a real `gh issue view`
# response would.
#
# Run: ./environments/macf/hack/test-derive-snapshot-window.sh

set -uo pipefail
cd "$(dirname "$0")"
DSW=./derive-snapshot-window.sh
pass=0 fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# shellcheck source=./derive-snapshot-window.sh
. "$DSW"

echo "== _dsw_merge: ±delta expansion + overlap collapsing =="
got="$(printf '1000\n' | _dsw_merge 300 | tr '\n' ';')"
[ "$got" = "700 1300;" ] && ok "single event -> one [t-d, t+d] window" || bad "single event gave '$got'"

# 1000 and 1400 are 400s apart; with ±300 their windows touch -> ONE cluster
got="$(printf '1000\n1400\n' | _dsw_merge 300 | tr '\n' ';')"
[ "$got" = "700 1700;" ] && ok "nearby events collapse into one cluster" || bad "nearby events gave '$got'"

# 1000 and 5000 are far apart -> TWO clusters
got="$(printf '1000\n5000\n' | _dsw_merge 300 | tr '\n' ';')"
[ "$got" = "700 1300;4700 5300;" ] && ok "distant events stay separate clusters" || bad "distant events gave '$got'"

got="$(printf '5000\n1000\n3000\n' | _dsw_merge 300 | head -1)"
[ "$got" = "700 1300" ] && ok "unsorted input is sorted before merging" || bad "unsorted gave '$got'"

echo "== _dsw_reduce: keeps the most recent activity, flags the clamp =="
# one cluster, comfortably inside max -> no clamp, exact bounds
read -r s e tot kept cl cov <<<"$(printf '700 1300\n' | _dsw_reduce 21600)"
[ "$s" = "700" ] && [ "$e" = "1300" ] && [ "$cl" = "0" ] && [ "$tot" = "1" ] \
  && ok "single in-budget cluster passes through unclamped" || bad "got s=$s e=$e clamped=$cl total=$tot"

# two clusters within budget -> both kept, no clamp
read -r s e tot kept cl cov <<<"$(printf '700 1300\n4700 5300\n' | _dsw_reduce 21600)"
[ "$s" = "700" ] && [ "$e" = "5300" ] && [ "$kept" = "2" ] && [ "$cl" = "0" ] \
  && ok "two clusters inside budget: both kept, unclamped" || bad "got s=$s e=$e kept=$kept clamped=$cl"

# THE #163 CASE: clusters ~37 days apart, 6h budget -> keep the recent one, CLAMP
old=1783142489; new=$((old + 903*3600))
read -r s e tot kept cl cov <<<"$(printf '%d %d\n%d %d\n' $old $((old+600)) $new $((new+600)) | _dsw_reduce 21600)"
[ "$cl" = "1" ] && ok "#163-shaped 903h spread sets clamped=1 (never silent)" || bad "903h spread clamped=$cl"
[ "$kept" = "1" ] && [ "$tot" = "2" ] && ok "keeps 1 of 2 clusters — the most recent" || bad "kept=$kept of $tot"
[ "$e" = "$((new+600))" ] && ok "clamped window ends at the LAST activity (the closing session)" || bad "end=$e want $((new+600))"
[ "$((e - s))" -le 21600 ] && ok "clamped span is within budget ($((e-s))s <= 21600s)" || bad "span $((e-s)) exceeds budget"

# a SINGLE cluster wider than budget must also clamp (not silently over-serve)
read -r s e tot kept cl cov <<<"$(printf '0 40000\n' | _dsw_reduce 21600)"
[ "$cl" = "1" ] && [ "$((e - s))" = "21600" ] \
  && ok "one over-wide cluster is truncated to budget AND flagged" || bad "over-wide cluster: clamped=$cl span=$((e-s))"

echo "== _dsw_windows_json: machine-readable cluster list for the manifest =="
got="$(printf '700 1300\n4700 5300\n' | _dsw_windows_json)"
echo "$got" | jq -e 'length == 2 and .[0].start == 700 and .[1].end == 5300' >/dev/null 2>&1 \
  && ok "emits valid JSON preserving every cluster (incl. clamped-away ones)" \
  || bad "windows_json was '$got'"

echo "== end-to-end via --events-file: actor filtering + real output shape =="
TMP="$(mktemp -d)"
# alice opens at t=1000 and closes at t=1400; bob comments at t=100000 (far away).
# Bob's comment must NOT widen alice's window.
cat > "$TMP/events.json" <<'JSON'
{
  "issue": {
    "author":   { "login": "alice" },
    "createdAt": "2026-08-01T00:00:00Z",
    "closedAt":  "2026-08-01T00:10:00Z",
    "assignees": []
  },
  "timeline": [
    { "event": "commented", "user":  { "login": "bob" },   "created_at": "2026-08-05T00:00:00Z" },
    { "event": "commented", "actor": { "login": "alice" }, "created_at": "2026-08-01T00:05:00Z" },
    { "event": "closed",    "actor": { "login": "alice" }, "created_at": "2026-08-01T00:10:00Z" }
  ]
}
JSON
out="$($DSW --events-file "$TMP/events.json" --actor alice 2>/dev/null)"
fv="$(printf '%s' "$out" | sed -n 's/^filter_value=//p')"
st="$(printf '%s' "$out" | sed -n 's/^start=//p')"
en="$(printf '%s' "$out" | sed -n 's/^end=//p')"
ct="$(printf '%s' "$out" | sed -n 's/^clusters_total=//p')"
[ "$fv" = "alice" ] && ok "resolves the filter value from the actor" || bad "filter_value='$fv'"
[ "$ct" = "1" ] && ok "bob's distant comment excluded — one cluster, not two" || bad "clusters_total=$ct (bob leaked in?)"
[ "$((en - st))" -le 1500 ] && ok "window is alice's ~10min of work, not the 4-day issue lifetime ($((en-st))s)" \
  || bad "window span $((en-st))s — too wide, the #177 bug is back"

# bot-login normalisation: app/<name> and <name>[bot] must both reduce to <name>
cat > "$TMP/bot.json" <<'JSON'
{
  "issue": {
    "author":   { "login": "macf-devops-agent[bot]" },
    "createdAt": "2026-08-01T00:00:00Z",
    "closedAt":  "2026-08-01T00:05:00Z",
    "assignees": []
  },
  "timeline": [
    { "event": "closed", "actor": { "login": "macf-devops-agent[bot]" }, "created_at": "2026-08-01T00:05:00Z" }
  ]
}
JSON
fv="$($DSW --events-file "$TMP/bot.json" --actor 'macf-devops-agent[bot]' 2>/dev/null | sed -n 's/^filter_value=//p')"
[ "$fv" = "macf-devops-agent" ] && ok "[bot] suffix stripped to match gen_ai.agent.name" || bad "filter_value='$fv'"

# no attributable events -> refuse, don't invent a window
cat > "$TMP/none.json" <<'JSON'
{
  "issue": { "author": {"login":"bob"}, "createdAt": "2026-08-01T00:00:00Z",
             "closedAt": null, "assignees": [] },
  "timeline": [ { "event": "commented", "user": {"login":"bob"}, "created_at": "2026-08-01T00:01:00Z" } ]
}
JSON
$DSW --events-file "$TMP/none.json" --actor alice >/dev/null 2>&1 \
  && bad "no-events case succeeded — it invented a window" \
  || ok "no attributable events -> non-zero exit (refuses to guess)"

echo "== provenance_json survives being passed as ONE shell-quoted argument =="
# The regression this guards: the workflow first hand-assembled this JSON inside
# a YAML `run:` block, mixing escaped \" literals with the real quotes that came
# from the windows_json substitution. Inside the outer DOUBLE-quoted ssh argument
# those real quotes terminated the string early, the snapshot script saw garbage
# args and printed usage, and the run died at its LAST step.
#
# Which assertion actually catches that: the jq-validity one. `{\"windows\":...}`
# has literal backslashes and is NOT valid JSON, so jq rejects it. Verified by
# running the old broken form through these checks — the single-line and
# one-argument assertions BOTH pass on it, so neither would have caught this.
# They're kept as complementary guards against different breakages (a multiline
# value corrupting GITHUB_OUTPUT; an embedded quote splitting the argument), but
# don't mistake them for the guard on THIS bug.
pj="$($DSW --events-file "$TMP/events.json" --actor alice 2>/dev/null | sed -n 's/^provenance_json=//p')"
[ "$(printf '%s' "$pj" | wc -l)" = "0" ] && ok "provenance_json is a single line (safe for GITHUB_OUTPUT)" \
  || bad "provenance_json spans multiple lines"
printf '%s' "$pj" | jq -e 'has("windows") and has("clamped") and has("coverage_seconds")' >/dev/null 2>&1 \
  && ok "provenance_json is valid JSON with the manifest fields" || bad "provenance_json invalid: $pj"
case "$pj" in *"'"*) bad "provenance_json contains a single quote — would break '\$ARG' wrapping" ;;
              *)     ok "provenance_json has no single quotes (survives '...' inside the ssh command)" ;; esac
# Prove the round-trip the workflow actually performs: wrap in '...', let the
# shell word-split, and confirm the receiving script sees exactly ONE argument.
n_args="$(bash -c 'set -- '"'$pj'"'; echo $#')"
[ "$n_args" = "1" ] && ok "reaches the receiving script as exactly one argument" \
  || bad "shell split provenance_json into $n_args arguments (the #178 CI failure)"

rm -rf "$TMP"
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
