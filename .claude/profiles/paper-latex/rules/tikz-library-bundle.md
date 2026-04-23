# TikZ library bundle

**Load a canonical library bundle up front to avoid the most common LLM failure mode.**

LLMs trained on older TikZ corpora (or just optimizing for brevity) routinely omit `\usetikzlibrary{...}` directives for features they then use. The compile fails with cryptic errors like "Package tikz Error: I do not know the key" — often with no hint that a `\usetikzlibrary` line is missing.

## The canonical preamble

Ship this in your paper preamble whenever TikZ is in play:

```latex
\usepackage{tikz}
\usetikzlibrary{
  positioning,       % relative placement (right=of, below=of)
  arrows.meta,       % modern arrow tips (Stealth, Latex, etc.)
  calc,              % coordinate arithmetic: ($(A)!.5!(B)$)
  shapes.geometric,  % diamond, ellipse, trapezium
  shapes.misc,       % cross, strike-out shapes
  decorations.pathreplacing,  % curly braces, zigzag underlines
  patterns,          % hatched/dotted fills
  matrix,            % aligned grids
  fit                % bounding boxes around sets of nodes
}
```

This covers ~95% of academic TikZ needs. If you find yourself hand-rolling something, first check whether one of these libraries already provides it.

## Specialty packages (prefer these over hand-rolled TikZ)

When the diagram type matches, specialty packages have richer training-data coverage and produce cleaner output than raw TikZ:

| Package | Use for |
|---|---|
| `tikz-cd` | Commutative diagrams (arrows between objects in categories) |
| `pgfplots` | 2D/3D plots from data or formulas |
| `circuitikz` | Electrical circuits |
| `forest` | Linguistic parse trees, taxonomies |
| `tikz-qtree` | Simpler trees (forest is more powerful) |
| `pgf-umlcd` / `tikz-uml` | UML diagrams |
| `tikz-timing` | Digital timing diagrams |
| `bytefield` | Network packet / memory layout |

Example — commutative diagram via `tikz-cd`:

```latex
\usepackage{tikz-cd}
\begin{tikzcd}
  A \arrow[r, "f"] \arrow[d, "g"'] & B \arrow[d, "h"] \\
  C \arrow[r, "k"'] & D
\end{tikzcd}
```

Example — 2D plot via `pgfplots`:

```latex
\usepackage{pgfplots}
\pgfplotsset{compat=1.18}
\begin{tikzpicture}
  \begin{axis}[xlabel=$x$, ylabel=$f(x)$]
    \addplot[blue, thick] {sin(deg(x))};
  \end{axis}
\end{tikzpicture}
```

## Anti-guidance

**Never use `\usetikzlibrary{arrows}`.** That library is deprecated. Use `arrows.meta` for modern arrow tips. TeXLive 2024+ has moved `arrows.meta.code.tex` into a separate file; the old `arrows` name still exists but produces the wrong tip styles and is a tell that the code was generated from pre-2017 examples.

**Don't emit `\pgfplotsset{compat=newest}`.** Pin the compat level to a known version (e.g., `1.18`). "newest" produces non-reproducible builds — future `pgfplots` versions may render your paper differently than when you submitted it.

**Don't mix `forest` and raw TikZ tree idioms in one document.** They have incompatible syntax. Pick one per paper.

## Standalone compilation

When drafting a figure, compile it in isolation to shorten the feedback loop:

```latex
\documentclass[border=4pt]{standalone}
\usepackage{tikz}
\usetikzlibrary{positioning, arrows.meta, calc, shapes.geometric,
                shapes.misc, decorations.pathreplacing,
                patterns, matrix, fit}
\begin{document}
\begin{tikzpicture}
  % ... your diagram ...
\end{tikzpicture}
\end{document}
```

`standalone` class produces a PDF sized to the tikzpicture bounding box — no page layout, fast compile. Iterate here, then `\input{figures/foo.tex}` into the main paper.
