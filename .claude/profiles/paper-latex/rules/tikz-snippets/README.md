# TikZ snippet gallery

Canonical starting points for common academic diagrams. Each snippet:

- Compiles as a standalone document (`standalone` class).
- Loads only the TikZ libraries it needs from the canonical bundle (see `../tikz-library-bundle.md`).
- Embeds rules P1, P2, P4 from `../tikz-prevention.md` (explicit node dimensions, coordinate-map comment, directional edge labels).
- Uses `xxHigh`-quality defaults: sensible node spacing, `Stealth` arrow tips, `\small` font.

## Snippets

| File | Use for |
|---|---|
| `flowchart.tex` | 3-step process with decision diamond |
| `tree.tex` | Hierarchical tree (uses `forest`) |
| `graph.tex` | Directed labeled graph (5 nodes, weighted edges) |
| `plot.tex` | 2D function plot (uses `pgfplots`) |
| `block-diagram.tex` | System architecture with feedback loop (uses cylinder shape) |

## How to use

1. Copy the nearest match to your figures directory:
   ```
   cp .claude/rules/tikz-snippets/flowchart.tex figures/my-diagram.tex
   ```
2. Edit node labels, coordinates, and styles to fit your case.
3. Keep the coordinate-map comment (P2) up to date — it's the reader's legend.
4. Compile standalone first: `latexmk -pdf figures/my-diagram.tex`
5. Once the standalone compiles clean, `\input{figures/my-diagram.tex}` into your main paper.

## Why not more snippets?

These five cover the ~80% case for papers across disciplines. Domain-specific diagrams (commutative diagrams in math, Feynman diagrams in physics, DAGs in causal inference) are better served by their specialty packages — see `../tikz-library-bundle.md` for the list. Copying a commutative diagram into `tikz-cd` syntax is faster than starting from a raw-TikZ template.
