#!/usr/bin/env bash
# fork-pr-approval-check.sh — Pattern-D precheck: refuse to install a self-hosted
# runner on a PUBLIC repo unless GitHub's native "require approval for ALL fork
# PRs" setting is on. SOURCED by install-runner.sh; the pure decision logic
# (_fork_approval_decide) is factored out so it can be unit-tested WITHOUT
# calling `gh` at all — see runner/test-fork-approval.sh.
#
# THE THREAT (RUNNER.md "The security model"): a self-hosted runner on a public
# repo is a fork-PR code-execution risk — a malicious fork PR can trigger a
# workflow that `runs-on: self-hosted` and executes on this VM. The intended
# LONG-TERM control is origin-routing (macf-actions#59: trusted-actor -> self-
# hosted, everyone else -> github-hosted), which is NOT landed yet. Until it
# lands, GitHub's own fork-PR-approval setting is the ONLY thing standing
# between an untrusted fork PR and code execution here:
#   - all_external_contributors               <- STRICTEST = SAFE. Every outside
#                                                 fork PR is gated behind a
#                                                 maintainer's manual approval
#                                                 before ANY workflow runs.
#   - first_time_contributors                 <- weaker: a contributor who has
#                                                 ever had a PR merged can then
#                                                 trigger UNAPPROVED runs. Not
#                                                 safe for a public repo with a
#                                                 self-hosted runner attached.
#   - first_time_contributors_new_to_github   <- weakest variant of the above.
# This precheck FATALs (exit 2) unless the policy is the strictest setting, on
# any repo it cannot positively confirm is non-public.
#
# THE TWO gh ENDPOINTS (verified against GitHub's REST API docs — do not change
# these without re-verifying against the docs):
#   - GET /repos/{owner}/{repo}                                          -> .visibility
#       "public" | "private" | "internal". Readable with the bot's OWN token
#       (metadata:read) — no operator creds needed for this one.
#   - GET /repos/{owner}/{repo}/actions/permissions/fork-pr-contributor-approval
#       -> .approval_policy. Needs admin / `repo` scope — the bot App is
#       ALWAYS 403 here (same shape as install-runner.sh's mint_token() being
#       403 on administration:write), so this call MUST run as the OPERATOR,
#       mirroring install-runner.sh's own `gh_as=(sudo -u "$SUDO_USER" -- gh)`
#       pattern: no `-E`, so a bot GH_TOKEN sitting in this root shell's env
#       can't leak into the operator's call, and `sudo -u` resets HOME so `gh`
#       reads the OPERATOR's own stored auth, not root's / macf-runner's.
#
# FAIL-LOUD, not fail-open: an UNREADABLE policy on a public (or visibility-
# unknown) repo is FATAL, never a silent pass — silently proceeding on "we
# couldn't confirm the policy" would recreate the exact silent-fallback shape
# `silent-fallback-hazards.md` (Pattern B: this rule's own Pattern-D precheck
# lineage — Instance 5/9/11) spends a whole canonical file warning against.
#
# OVERRIDE: MACF_RUNNER_SKIP_FORK_APPROVAL_CHECK=1 skips the whole check with a
# loud one-line warn — sister to the repo's other MACF_SKIP_*-family escape
# hatches. Legitimate uses: macf-actions#59 (origin-routing) has landed and is
# the real gate now, or a deliberate, documented operator call.

# _fork_approval_decide <visibility> <approval_policy> — PURE function: no gh
# calls, no I/O beyond echoing the verdict to stdout. Given the two
# already-fetched values, prints exactly one of SKIP|PASS|FATAL and always
# returns 0. Kept side-effect-free specifically so the decision TABLE — the
# actual security-relevant logic — is unit-testable without mocking `gh`
# (runner/test-fork-approval.sh sources this file and calls this function
# directly with canned inputs).
#
#   SKIP  — $vis is a KNOWN non-public value (private/internal): no anonymous
#           fork surface exists, so the approval-policy question doesn't apply.
#   PASS  — $vis is public (or empty/unreadable, see below) AND $policy is the
#           strictest setting.
#   FATAL — $vis is public (or empty/unreadable) AND $policy is weaker, empty,
#           or otherwise unreadable.
#
# Conservative-on-unknown-visibility: an EMPTY $vis (the `gh api` call failed,
# timed out, or returned something unexpected) does NOT resolve to SKIP — it
# falls through to the PASS/FATAL branch exactly as if the repo were public.
# "We could not confirm this repo is safe" must never resolve to "treat it as
# safe" — public is the risky case, so unknown has to be handled at least as
# cautiously as public, never more leniently.
_fork_approval_decide() {
  local vis="$1" policy="$2"
  if [ -n "$vis" ] && [ "$vis" != "public" ]; then
    echo "SKIP"
    return 0
  fi
  if [ "$policy" = "all_external_contributors" ]; then
    echo "PASS"
    return 0
  fi
  echo "FATAL"
  return 0
}

# check_fork_pr_approval — the effectful wrapper around _fork_approval_decide:
# fetches visibility (bot token OK) + approval policy (operator creds, mirrors
# mint_token()'s gh_as), runs the pure decision, prints the matching message,
# and returns 0 (safe to proceed) or 2 (FATAL — caller should exit). Expects
# $REPO to already be set + validated by the caller (install-runner.sh does
# this before calling — see the "0. fork-PR-approval precheck" call site).
check_fork_pr_approval() {
  if [ "${MACF_RUNNER_SKIP_FORK_APPROVAL_CHECK:-0}" = "1" ]; then
    echo "  ⚠ fork-PR-approval check SKIPPED via override — ensure origin-routing (macf-actions#59) or the repo's fork-PR-approval setting already covers $REPO" >&2
    return 0
  fi

  local vis policy decision
  local gh_as=(gh)
  vis="$(GH_TOKEN="${GH_TOKEN:-}" gh api "/repos/$REPO" --jq '.visibility' 2>/dev/null)"

  if [ -n "$vis" ] && [ "$vis" != "public" ]; then
    echo "  ✓ $REPO is $vis — no anonymous fork surface; fork-PR-approval check skipped" >&2
    return 0
  fi

  # public (or vis unreadable — conservative fall-through, see the decide
  # fn's header comment above): query the approval policy AS THE OPERATOR —
  # the bot is always 403 on this endpoint (mirrors mint_token()'s gh_as).
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    gh_as=(sudo -u "$SUDO_USER" -- gh)
  fi
  policy="$("${gh_as[@]}" api "/repos/$REPO/actions/permissions/fork-pr-contributor-approval" --jq '.approval_policy' 2>/dev/null)"

  decision="$(_fork_approval_decide "$vis" "$policy")"
  case "$decision" in
    PASS)
      echo "  ✓ fork-PR-approval: all_external_contributors (every outside fork PR is gated) — safe for a public self-hosted runner" >&2
      return 0
      ;;
    *)
      {
        echo "FATAL: $REPO is PUBLIC and macf-actions#59 (origin-routing) is not landed yet —"
        echo "       a self-hosted runner on a public repo needs the STRICTEST fork-PR-approval setting."
        if [ -n "$policy" ]; then
          echo "       current policy: '$policy'  (required: all_external_contributors)"
        else
          echo "       current policy: could not be read — the operator's gh creds may lack admin on $REPO, or the endpoint is unavailable"
        fi
        echo "       Fix: Settings -> Actions -> General -> \"Fork pull request workflows from outside collaborators\""
        echo "            -> select \"Require approval for all external contributors\"."
        echo "       Override (only once macf-actions#59 lands, or a deliberate operator call): MACF_RUNNER_SKIP_FORK_APPROVAL_CHECK=1"
      } >&2
      return 2
      ;;
  esac
}
