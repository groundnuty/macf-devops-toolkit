# Writing quality

Applied when this repo's primary output is prose.

## Voice

- Prefer active voice and concrete subjects. "The tool removed the entries" beats "the entries were removed."
- Cut hedges. "Possibly", "arguably", "somewhat", "relatively" — delete unless the uncertainty is load-bearing.
- Cut throat-clearing. "It's worth noting that", "in this context", "as mentioned" — remove.

## Banned AI-smell patterns

- **Negative parallelisms:** "Not just X but Y" without substance. Delete or replace with direct statement.
- **Rule of three, symmetric:** "Fast, reliable, and scalable" is suspicious. Keep only items that are actually true and distinct.
- **Inflated verbs:** "delves into", "navigates", "unpacks", "explores" — replace with specific action.
- **Em dash overuse:** one pair per paragraph max. Prefer a period or comma.
- **Transition tokens:** "Moreover", "Furthermore", "Additionally", "Indeed" — remove; let the argument flow.

## Structure

- Lead with the finding. Background second. Method third.
- One idea per paragraph.
- If a sentence has more than two commas, split it.
- Bullet lists for enumerations of 3+. Prose for arguments.

## Citations

If the document references external sources, maintain a bibliography section (markdown footnotes or a BibTeX file). Never cite from memory without verification — run WebSearch or read the source.

## When humanizer is installed (paper profile)

`paper` profile ships `humanizer` as a vendored skill. If present in `.claude/skills/humanizer/`, invoke via `/humanizer` when polishing prose.
