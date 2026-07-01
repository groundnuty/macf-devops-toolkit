# Why the self-hosted routing runner re-downloads every action per job — and how to prevent it

**Date:** 2026-07-01
**Issue:** devops-toolkit#150 (operator-requested deep-research; the #90/#43 routing-latency H1a slice)
**Method:** empirical (first-hand inspection of the live `macf-vm-science-agent` runner, v2.335.1) + current-source research (actions/runner code + docs, not training memory).

## TL;DR

The runner **deletes `_work/_actions` at the start of every job** and re-fetches each `uses:` action's tarball from `codeload.github.com` — **by design** (isolation-over-reuse; maintainer-confirmed; feature-request open 5+ years). There is **no `--no-cleanup`/`KEEP` knob**, and **pre-populating `_work/_actions` does NOT work** (it's wiped at job start). Two real fixes: **(A, primary, workflow-side)** eliminate the unnecessary action references on the self-hosted routing path (`uses: ./` vendoring or just not-referencing) — total elimination; **(B, secondary, runner-side)** `ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE` (present since v2.311) — eliminates the network *fetch* but not the per-job re-extraction. `actions/cache` is unrelated and does NOT help. Expected win: real but modest (~2–4s/routed op; route-by-mention ~14s→~10–11s). Sub-6–9s needs the persistent-daemon rearchitecture (separate DR, out of scope).

## Root cause (empirical + source-confirmed)

**Empirical (the live runner's own Worker log, job at 15:35):**
```
15:35:31Z [JobExtension] Downloading actions
15:35:32Z [ActionManager] Save archive 'https://codeload.github.com/tailscale/github-action/tar.gz/<sha>' into _work/_actions/_temp_…/….tar.gz  → extract
          (repeated for actions/create-github-app-token, actions/cache, actions/checkout; ~1s each, ~3s total)
```
All four `_work/_actions/<owner>/<repo>/<ref>.completed` watermark markers were **freshly re-written at the same job timestamp** (15:35:32–35) — i.e. re-created every job, not persisted-and-reused.

**Source (why):** `ActionManager.PrepareActionsAsync` unconditionally deletes the actions dir at job start:
```csharp
// We are running at the start of a job
if (rootStepId == default(Guid)) {
    IOUtil.DeleteDirectory(HostContext.GetDirectory(WellKnownDirectory.Actions), …);  // _work/_actions
}
```
(actions/runner `src/Runner.Worker/ActionManager.cs` ~L93; `WellKnownDirectory.Actions` = `_work/_actions` per `HostContext.cs`/`Constants.cs`.) There **is** a per-action watermark short-circuit (`if File.Exists(<ref>.completed) return;`) — but because the whole dir was just deleted, it only prevents re-download of the *same* action *within one job*, never across jobs. This reconciles the empirical finding exactly: the dir "persists" only as the last job's re-extraction residue.

**Deliberate, not a bug:** maintainer (actions/runner discussion #1157): *"We didn't cache it, so it won't get polluted by other jobs."* Isolation-over-reuse is the intent. Feature-request #811 ("do NOT download action every time on self hosted runner") has been **open since 2020**, `enhancement`/`Future`, no on-by-default fix.

## Options (what works, what doesn't)

| Mechanism | Works? | Notes |
|---|---|---|
| **`uses: ./path` (vendored local action)** | ✅ total | Local actions are read from the checked-out repo, **never downloaded** into `_actions`. The per-job wipe is irrelevant. Best for actions you own/can vendor. Workflow-side. Tradeoff: you vendor + own updates/pinning. |
| **`ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE`** (native, v2.311+, present in our v2.335.1) | ✅ partial | Runner checks a local dir for the SHA-keyed archive before hitting the network → eliminates the **fetch**. Runner reads-but-does-NOT-populate it (pre-stage via `actions/action-versions`: `add-action.sh`+`build.sh`, bake into the runner home). Copy-mode still deletes+re-extracts `_actions` per job → saves network, not extraction. |
| **`ACTIONS_RUNNER_SYMLINK_CACHED_ACTIONS`** (symlink mode, PR #4260, merged 2026-02-24) | ⚠️ verify | Avoids re-extraction too (symlinks the cached unpacked action). **Borderline in v2.335.1 — verify before relying** (`./run.sh --version` + release notes for the tag). |
| **Pre-populate `_work/_actions` + prevent cleanup** | ❌ no | Deleted at job start regardless (ActionManager L93). Anything staged is gone before resolution. |
| **Local action mirror (`actions/actions-sync`) / HTTP caching proxy** | ⚠️ indirect | Changes *where* actions come from (fast/local) but the runner still re-downloads per job into the wiped dir. No `DOWNLOAD_ACTIONS_FROM` override exists. A caching proxy is a network-layer workaround, not first-class. |
| **`actions/cache` (the cache *action*)** | ❌ unrelated | Caches build deps/outputs you explicitly key (npm/pip) via GitHub's cache backend — zero relationship to `_actions` action-repo downloads. Will NOT help. |

## Recommendation — runner-side vs workflow-side split

**For the routing runner specifically, the primary lever is WORKFLOW-SIDE (code / macf-actions), because most of the downloaded actions are UNNECESSARY on the self-hosted path:**

- **`tailscale/github-action@v3` — pure waste on self-hosted (H2).** #65 already skips its *step* (the runner's on the tailnet), but the `if:` gates *execution, not the fetch* — so it's downloaded then never run. **Fix: don't reference it on the self-hosted path** (conditional job / github-hosted-only sub-workflow) → zero download. ~1s.
- **`actions/create-github-app-token@v3` → inline `macf-gh-token.sh` mint** — no action-download; the mint's ~1s regardless. ~1s.
- **`actions/checkout`** — routing is inline bash; likely unneeded. **`actions/cache`** — what is a *routing* job caching? (a cache-action *adding* download cost is ironic — verify it earns its keep). Each removed ≈ ~1s.

Each action removed ≈ ~1s off "Set up job", every routed op — and for the unnecessary ones it's *total* elimination, cleaner + more durable than fighting the runner's per-job wipe.

**Runner-side (devops) is SECONDARY — for any action that must remain + is third-party:** set `ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE=<dir>` in the runner's systemd unit + pre-populate `<dir>` from `actions/action-versions`, baked into the runner home. Eliminates the network fetch (not the extraction). **Tradeoffs:** SHA-keyed (re-stage on every pinned-version bump — reinforces SHA-pinning; fails safe to network-download if missing), disk (large archive tree), a maintenance step, supply-chain plus (you control exactly which SHAs are staged). Worth it only if, after the workflow-trim (A), a network-fetch cost remains on actions that stay.

**Rule out (so no one wastes time):** pre-populating `_work/_actions` (wiped at job start); `actions/cache` (unrelated).

**Honest scope:** the win is real but modest — dropping the 4 downloads could take "Set up job" ~7s→~3–4s → route-by-mention ~14s→~10–11s. **Sub-6–9s needs the persistent-routing-daemon rearchitecture — out of scope here (a separate DR if pursued).** The re-download is confirmed waste, so preventing it is worth it; just not the headline win.

## Practitioner / community-hacks alley (second research pass — the scrappy workarounds people actually try)

Official docs say "by design, tough luck" — so the community-hacks layer was searched separately (blogs, gists, HN/SO, the #811 comment thread). **Conclusion: the hacks alley CONFIRMS the two official answers are the only viable ones — every scrappier workaround is a reported dead-end.** Value is in the *sharper framing* + not re-treading them:

**Viable (Tier 1–2):**
- **Archive-cache, host-seeded (not just Docker-image):** for a systemd runner you don't need an image — point `ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE` at a host dir + run `actions/action-versions` `build.sh` there. Layout `{owner}_{repo}/{SHA}.tar.gz`. Practitioner gotcha: **SHA-keyed → a moving tag (`@v3`→new SHA) silently misses + falls back to codeload until you re-`build.sh`** (fails safe). Lives outside `_work` → survives the wipe. (Ken Muse guide.)
- **`uses: ./local` vendoring** — strictly less fragile than any Tier-2/3 hack.
- Local git mirror of actions — reduces the *cost* of the re-download (LAN-local), doesn't eliminate it.

**DEAD-ENDS people tried + reported failing (do NOT spend time here):**
- **`ACTIONS_RUNNER_HOOK_JOB_STARTED` pre-seed** — **architecturally impossible**: the hook fires *after* "Set up job" where action-resolution+download already happen (runner #1951, closed not-planned; ADR 1751). The most tempting angle; verified defeated by timing.
- **bind-mount / PV / emptyDir at `_work/_actions`** — the runner deletes the *directory itself*, so an active mount point → **"Device or resource busy"** at Set-up-job (ARC #633). Read-only mount fails harder.
- **symlink `_actions` elsewhere** — breaks on runner auto-update (recursive copy doesn't preserve symlinks, runner #2094); delete traverses the link anyway.
- **HTTP caching proxy in front of codeload** — codeload is HTTPS + per-download Bearer auth (verified in source) → needs TLS-bump/MITM; **the widely-cited `Azure/github-nginx-cache` is a rate-limit dedup (1s cache, ignores Cache-Control), NOT a tarball cache** — recommending it for this would be a mistake. No clean success report anywhere.
- **fork/patch out the `DeleteDirectory`** — auto-update treadmill (GitHub enforces a compat window; a patched build must be re-patched every release). Unsustainable for one runner.

**Mechanism nuance the hacks-pass nailed:** the watermark file is `{actionDir}.completed` — a sibling *inside* `_work/_actions`, so the job-start wipe destroys it every job → it only dedups *within* one job, never across (the mechanistic proof the wipe is total). #811 is open since 2020 with **no maintainer position ever** — the thread is proposals, not confirmed hacks.

Practitioner sources: [ActionManager.cs (delete+archive-cache+watermark+codeload-Bearer)](https://raw.githubusercontent.com/actions/runner/main/src/Runner.Worker/ActionManager.cs), [#1951 hook-timing (closed)](https://github.com/actions/runner/issues/1951) + [ADR 1751](https://github.com/actions/runner/blob/main/docs/adrs/1751-runner-job-hooks.md), [ARC #633 bind-mount dead-end](https://github.com/actions/actions-runner-controller/discussions/633), [#2094 symlink-breaks-on-update](https://github.com/actions/runner/issues/2094), [Azure/github-nginx-cache (rate-limit dedup, NOT tarball cache)](https://github.com/Azure/github-nginx-cache), [osy Squid gist (releases/blob, patched Squid — NOT codeload)](https://gist.github.com/osy/30c5c96d7575efd1d2a2db5e3def0815), [Ken Muse archive-cache](https://www.kenmuse.com/blog/building-github-actions-runner-images-with-an-action-archive-cache/), [Nesbitt teardown](https://nesbitt.io/2025/12/06/github-actions-package-manager.html).

## Sources

actions/runner: [#811](https://github.com/actions/runner/issues/811) (5-yr-open feature request), [discussion #1157](https://github.com/actions/runner/discussions/1157) (maintainer "we didn't cache it"), [ActionManager.cs](https://github.com/actions/runner/blob/main/src/Runner.Worker/ActionManager.cs) (the per-job delete), [Constants.cs](https://github.com/actions/runner/blob/main/src/Runner.Common/Constants.cs) (env-var names + layout), [PR #2857](https://github.com/actions/runner/pull/2857) (archive-cache, v2.311), [PR #4260](https://github.com/actions/runner/pull/4260) (symlink mode, 2026-02-24). [Ken Muse — action archive cache](https://www.kenmuse.com/blog/building-github-actions-runner-images-with-an-action-archive-cache/), [actions/action-versions](https://github.com/actions/action-versions), [actions/cache](https://github.com/actions/cache) (unrelated). Empirical: `macf-vm-science-agent` v2.335.1 Worker log + `_work/_actions` inspection, 2026-07-01.
