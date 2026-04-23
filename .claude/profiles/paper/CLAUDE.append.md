<\!-- Profile: paper -->

## Profile: paper

Academic paper / manuscript writing — literature review, prose polishing, structured peer review. Format-agnostic (works for LaTeX, Markdown, Word, Google Docs). If your paper is authored in LaTeX/BibTeX with TikZ figures, layer the `paper-latex` profile on top.

### Scholar Gateway

Same one-time setup as the `research` profile. Scholar Gateway + Google Scholar WebSearch fallback both active for this profile.

### Vendored skills

This profile vendors the following into `.claude/skills/`:

- `humanizer` — removes AI-writing patterns from prose. Invoke via `/humanizer`. Upstream: https://github.com/groundnuty/humanizer
- `analyze-paper` — structured analysis of a reference paper PDF. Invoke via `/analyze-paper <path-to-pdf>`.

Use `./.claude/refresh-skills.sh` to pull fresh versions of upstream-sourced skills (currently: `humanizer`).

### Active profile-specific rules

- From the `info` chain: `writing-quality.md`. From `research`: `citation-discipline.md`, `reading-before-editing.md`, `pdf-processing.md`.
- `humanize-prose.md` — how to use the humanizer skill in the paper workflow.
- `post-flight-verification.md` — Chain-of-Verification discipline.
- `proofreading-protocol.md` — three-phase propose → approve → apply editorial discipline.
- `cross-artifact-review.md` — paper review auto-invokes code review when scripts are referenced.

### Peer-review workflow (adopted from pedrohcgs/claude-code-my-workflow, MIT)

**Anti-hallucination:**
- `/verify-claims` — runs Chain-of-Verification in a forked subagent (`claim-verifier`) that never sees the draft. Reports claims as supported / contradicted / unverifiable.
- `rules/post-flight-verification.md` — verification discipline rule.

**Manuscript review:**
- `/review-paper` — single-pass or adversarial review modes.
- `/seven-pass-review` — 7 forked lenses (abstract, intro, methods, results, robustness, prose, citations) in parallel, then synthesized.
- `agents/editor.md` + `agents/methods-referee.md` + `agents/domain-referee.md` — peer-review simulation (populate `templates/journal-profile-template.md` with your target venues).

**Reproducibility:**
- `/audit-reproducibility` — cross-check numeric claims against code outputs.
- `rules/cross-artifact-review.md` — auto-invoke code review when paper references scripts.

**Editing:**
- `/proofread` + `agents/proofreader.md` — three-phase propose → approve → apply editorial discipline.
- `rules/proofreading-protocol.md` — the discipline rule.

**Revise-resubmit:**
- `/respond-to-referees` — generate structured response-to-referees from a referee report + the revised manuscript.

**Templates:**
- `templates/requirements-spec.md` — MUST/SHOULD/MAY + CLEAR/ASSUMED/BLOCKED spec format.
- `templates/constitutional-governance.md` — non-negotiables vs preferences scaffold.
- `templates/journal-profile-template.md` — fill in per-venue for `/review-paper --peer`.

**Hooks (opt-in, configure in your `.claude/settings.local.json`):**
- `hooks/notify.sh` — cross-platform desktop notification on session events.
- `hooks/log-reminder.py` — stop-hook reminder to update session log.

### LaTeX / BibTeX / TikZ workflow

If you are writing in LaTeX with TikZ figures, also apply the `paper-latex` profile — it adds `latex-bibtex-discipline.md`, the TikZ prevention + library rules + snippet starters, `/tikz` collision-audit skill, `/validate-bib` bibliography validation, and the `verify-reminder.py` post-edit-compile hook.
