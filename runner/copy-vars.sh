#!/usr/bin/env bash
# copy-vars.sh — copy (or --check) a fleet's shared GitHub Actions variables from its
# var_source repo to a runner-repo (devops-toolkit#90). Kills the "set MACF_TRUSTED_ACTORS
# in N repos" drift: set it ONCE on the fleet's var_source, copy to each runner-repo, and
# --check verifies every repo still MATCHES the source.
#   ./copy-vars.sh --to groundnuty/macf-science-agent --fleet macf          # copy
#   ./copy-vars.sh --to groundnuty/macf-science-agent --fleet macf --check  # compare only
# Needs GH_TOKEN (variables:write to set; read to compare — the bot HAS variables:write).
set -uo pipefail
cd "$(dirname "$0")"
REG="${MACF_RUNNERS_YAML:-runners.yaml}"
TO="" FLEET="" CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to) TO="$2"; shift 2 ;;
    --fleet) FLEET="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TO" ] && [ -n "$FLEET" ] || { echo "FATAL: --to owner/repo --fleet <name> required" >&2; exit 2; }
[ -n "${GH_TOKEN:-}" ] || { echo "FATAL: GH_TOKEN unset" >&2; exit 2; }

SRC="$(yq -o=json "$REG" | jq -r --arg f "$FLEET" '.fleets[]|select(.name==$f).var_source // empty')"
VARS="$(yq -o=json "$REG" | jq -r --arg f "$FLEET" '.fleets[]|select(.name==$f).shared_vars[]? // empty')"
[ -n "$SRC" ] || { echo "FATAL: fleet '$FLEET' has no var_source in $REG" >&2; exit 2; }
[ -n "$VARS" ] || { echo "fleet '$FLEET' has no shared_vars — nothing to copy."; exit 0; }
[ "$SRC" = "$TO" ] && { echo "$TO IS the var_source — nothing to copy."; exit 0; }

getvar() { GH_TOKEN=$GH_TOKEN gh api "/repos/$1/actions/variables/$2" --jq '.value' 2>/dev/null || echo "__ABSENT__"; }

drift=0
for v in $VARS; do
  sval="$(getvar "$SRC" "$v")"
  if [ "$sval" = "__ABSENT__" ]; then echo "  [warn] $v absent on var_source $SRC — set it there first"; drift=1; continue; fi
  dval="$(getvar "$TO" "$v")"
  if [ "$CHECK" -eq 1 ]; then
    if [ "$sval" = "$dval" ]; then echo "  [ ok ] $v matches source";
    else echo "  [DRIFT] $v on $TO != $SRC"; drift=1; fi
  else
    if [ "$sval" = "$dval" ]; then echo "  [ ok ] $v already matches — skip";
    else GH_TOKEN=$GH_TOKEN gh variable set "$v" --repo "$TO" --body "$sval" >/dev/null 2>&1 \
        && echo "  [set ] $v copied $SRC → $TO" || { echo "  [FAIL] could not set $v on $TO"; drift=1; }; fi
  fi
done
[ "$drift" -eq 0 ] || { [ "$CHECK" -eq 1 ] && echo "→ drift/absent detected" || echo "→ some copies failed/absent"; exit 1; }
echo "→ $([ "$CHECK" -eq 1 ] && echo 'all shared vars match source' || echo 'shared vars in sync')"
