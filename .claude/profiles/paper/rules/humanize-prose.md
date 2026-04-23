# Humanize prose

Applied to every prose-editing turn in the paper profile.

## When to run `/humanizer`

- After a bulk rewrite of a section.
- Before submission or before sending to a coauthor.
- When a reviewer flags "reads as AI-generated" or similar.

## How to run

```
/humanizer path/to/section.tex
```

The skill reads the file, identifies AI-writing patterns, and produces an edit suggesting specific fixes. It does not auto-apply — review the suggestions.

## What it looks for (high-level)

- Negative parallelisms ("not X but Y" without substance).
- Rule of three (lists padded to three items for rhythm, not content).
- Em-dash overuse.
- AI vocabulary — "delves into", "navigates", "unpacks", "illuminates", "testament to".
- Inflated symbolism.
- Superficial -ing analyses ("examining", "highlighting", "underscoring") without specifics.
- Excessive conjunctive phrases ("Moreover", "Furthermore", "Additionally").
- Vague attribution ("experts say", "studies show").

## After running

Read the suggestions critically. Some will be wrong in academic context — e.g., "examining" is legitimate in a methods section. Apply only the ones that sharpen the prose.

## Limits

- `/humanizer` does not judge argument quality. It catches style tells. A beautifully humanized paper can still make a bad argument.
- It does not check citations or BibTeX (see `citation-discipline.md` and `latex-bibtex-discipline.md`).
