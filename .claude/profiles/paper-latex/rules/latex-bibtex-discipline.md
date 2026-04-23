# LaTeX + BibTeX discipline

Applied when the paper's source is LaTeX.

## BibTeX

- **One `.bib` file** per paper unless the venue requires otherwise. Name it `references.bib`.
- **Keys follow `lastnameYEAR[a|b|c]` convention.** E.g., `smith2024`, `smith2024a`, `smith2024b`.
- **Preserve DOI and URL** on every entry. Even if one renders, the other may be needed for different styles.
- **Never reorder** the `.bib` file by hand — let `biber` / `bibtex` sort the output.
- **Alphabetize within insertion:** when adding a new entry, put it near alphabetically-adjacent existing entries for easier diff review.

## Citing

- Use `\cite{key}` or venue-specific variant (`\citep`, `\citet`, `\citeauthor`).
- **Never cite the same paper twice in one sentence.** If you find yourself doing that, restructure the sentence.
- **Context matters.** `\cite{foo}` after a claim puts foo in support; `\citet{foo}` uses foo as the sentence subject.

## LaTeX structure

- **Never `\input{}` arbitrarily.** The paper has a top-level structure; new sections go through it.
- **Figures and tables** get descriptive filenames, not `fig1.pdf`. Keep them in `figures/`.
- **Do not redefine existing macros** silently. If the template defines `\software{}`, use it; don't create `\mysoftware{}`.
- **Comments for reviewer notes** — use `% TODO(reviewer): ...` prefix so they're greppable.

## Building

- If the paper has a `Makefile` (typical in your repos), use `make` / `make clean` / `make watch`. Do not invoke `pdflatex` directly unless debugging.
- If Overleaf is the primary editor, keep local changes minimal and sync often to avoid merge drift.

## Before submission

- Run `chktex` or equivalent linter.
- Check bibliography with `biber --validate`.
- Run the venue's style checker if provided.
- Strip reviewer comments (`% TODO(reviewer): ...` lines) or confirm they are intentionally visible.
