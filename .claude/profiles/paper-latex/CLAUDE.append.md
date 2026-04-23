<\!-- Profile: paper-latex -->

## Profile: paper-latex

LaTeX + BibTeX + TikZ layer on top of the generic `paper` profile. Apply when the manuscript is compiled with LaTeX and figures are authored in TikZ.

### Active additional rules

- `latex-bibtex-discipline.md` — LaTeX source conventions, BibTeX hygiene, stable commit discipline for auto-generated files.
- `tikz-prevention.md` — 6-rule protocol to prevent common TikZ failure modes (P1 explicit node dimensions, P2 coordinate map, P3 no bare `scale=`, P4 directional edge labels, P5 start from snippets, P6 one `tikzpicture` per idea).
- `tikz-library-bundle.md` — canonical TikZ preamble (`positioning`, `arrows.meta`, `calc`, `shapes.geometric`, `shapes.misc`, `decorations.pathreplacing`, `patterns`, `matrix`, `fit`) + specialty package guide (`tikz-cd`, `pgfplots`, `circuitikz`, `forest`).

### TikZ figures

Canonical diagram starting points live at `.claude/rules/tikz-snippets/`:

- `flowchart.tex`, `tree.tex`, `graph.tex`, `plot.tex`, `block-diagram.tex`

Workflow: copy nearest snippet → edit → compile standalone → `\input{}` into paper. See `tikz-snippets/README.md`.

### Additional skills

- `/tikz [path/to/file.tex]` — TikZ collision-audit tool. 6-pass visual audit using mathematical gap calculations rather than eyeballing. Adapted from [MixtapeTools](https://github.com/scunning1975/MixtapeTools).
- `/validate-bib` — structural + semantic bib validation (missing entries, unused entries, DOI presence, drift).

### Additional opt-in hook

- `hooks/verify-reminder.py` — post-Edit reminder to compile/verify academic files (`.tex`, `.bib`). Enable by referencing in `.claude/settings.local.json`.
