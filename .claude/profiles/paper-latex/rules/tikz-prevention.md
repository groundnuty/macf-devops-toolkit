# TikZ prevention rules

**Write TikZ that can't collide in the first place.** Load whenever you are authoring or editing a `\begin{tikzpicture}` block.

> Adapted from Scott Cunningham's `tikz_rules.md` in [MixtapeTools](https://github.com/scunning1975/MixtapeTools) via [pedrohcgs/claude-code-my-workflow](https://github.com/pedrohcgs/claude-code-my-workflow). Used with attribution.

The LaTeX compiler does **not** warn on label-over-arrow overlaps, labels crossing shape boundaries, or arrows crossing arrows. Every one of these bugs must be caught at authoring time or in review. These rules shift the catch upstream.

---

## Rule P1: Explicit dimensions on boxed nodes (MANDATORY)

Every *boxed* text-bearing node — one drawn with `draw`, `fill`, a custom node style (e.g. `flow-node`, `decision-node`), or any shape style like `rectangle`, `diamond`, `circle` with `draw`/`fill` — must declare its size explicitly. Implicit sizing means the label can grow past the box edge without anyone noticing.

```latex
% BAD — node size grows silently with text length
\node[draw, rounded corners] (X) {Some explanatory label};

% GOOD — explicit box; text wraps or the author notices
\node[draw, rounded corners, minimum width=3.2cm, minimum height=1.0cm,
      text width=3.0cm, align=center] (X) {Some explanatory label};
```

Use either:

- `minimum width` + `minimum height` — for boxes whose size should not depend on the text.
- `text width` + `align=center` (or `left`) — for boxes whose height should grow with text.

`text width` is required for any multi-line content (anything containing `\\`).

Plain labels, axis ticks, and free-floating annotations (`\node[above] {label}`) are **not** subject to P1 — for those, correctness comes from Rule P4.

---

## Rule P2: Coordinate map comment (MANDATORY for 3+ nodes)

For any diagram with three or more nodes, precede `\begin{tikzpicture}` with a comment block listing the named coordinates and a one-line intent sentence. This is the reader's legend; it also forces the author to think in absolute coordinates rather than relative drift.

```latex
% Diagram: Three-tier service architecture.
% Coordinates: (x, y)
%   API at (0, 2)    -- top, entry point
%   DB  at (3, 0)    -- bottom right, persistence
%   Cache at (-3, 0) -- bottom left, fast lookups
\begin{tikzpicture}
  \node (API) at (0, 2) {API};
  ...
\end{tikzpicture}
```

---

## Rule P3: `scale=X` alone is banned — scale nodes with it

The real failure mode is **asymmetric scaling**: `scale=0.8` shrinks coordinates but *not* text. A 2 cm gap becomes 1.6 cm; the 1.2 cm label that fit before now overlaps. This silently produces collisions.

**Ban.** `\begin{tikzpicture}[scale=X]` with no accompanying node scaling.

**Allowed — the symmetric forms:**

```latex
% Scale coordinates and nodes together
\begin{tikzpicture}[scale=1.1, every node/.style={scale=1.1}]

% Or use transform shape to scale node contents with coordinates
\begin{tikzpicture}[scale=0.85, transform shape]
```

---

## Rule P4: Directional keyword on every edge label

Every label attached to an edge must carry a positional keyword (`above`, `below`, `left`, `right`, or a compound). Bare `node {label}` places text *on* the arrow — reliably collides, silently compiles.

```latex
% BAD — label sits on the arrow line
\draw[->] (A) -- (B) node[midway] {depends on};

% GOOD — explicit direction
\draw[->] (A) -- (B) node[midway, above] {depends on};
```

| Arrow orientation | Preferred keyword |
|-------------------|-------------------|
| Horizontal | `above` or `below` |
| Vertical | `left` or `right` |
| Diagonal | side with more whitespace |
| Curved (`bend left/right`) | `above` on the outside of the bend |

For parallel arrows, stagger labels: use `pos=0.3` on one and `pos=0.7` on the other, or alternate `above`/`below`.

---

## Rule P5: Use the canonical snippets

`.claude/rules/tikz-snippets/` contains verified starting points for common academic diagrams (flowchart, tree, graph, plot, block-diagram). Each snippet embeds rules P1–P4 and includes a coordinate map.

Preferred workflow:

1. Copy the nearest snippet: `cp .claude/rules/tikz-snippets/flowchart.tex figures/my-flowchart.tex`
2. Edit node labels and coordinates to fit your case. **Keep the coordinate map up to date.**
3. Compile the standalone file to verify before integrating into the paper.

Writing a novel diagram from scratch is allowed but must still satisfy P1–P4.

---

## Rule P6: One tikzpicture per idea

A single `\begin{tikzpicture}` should encode one idea. If you need to show a sequence (stepwise reveal, before/after comparison), use multiple tikzpictures — one per frame or subfigure — rather than one tikzpicture overloaded with conditionals.

This keeps each diagram small enough that the rules are tractable.

---

## Compile-check discipline

After any TikZ edit:

1. Compile the **standalone** `.tex` file (not the full paper) — faster feedback, isolates errors.
2. If compile fails: fix → retry. After 3 failures on the same error class, **stop and surface to the user** with the compiler output. Don't thrash.
3. Only after the standalone compiles clean, `\input{}` it into the paper and compile the full doc.
