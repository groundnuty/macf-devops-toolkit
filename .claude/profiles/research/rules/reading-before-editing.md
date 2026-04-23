# Reading before editing

Applied to research workflows where documents already exist and Claude is asked to refine, critique, or extend them.

## Before any edit

1. **Read the entire file.** Not the first 50 lines — the whole thing. Research documents are densely referential; edits without full context produce contradictions.
2. **Identify the document's argument.** What is the central claim? What does it depend on?
3. **Identify what the user asked for.** Rephrasing, restructuring, adding a section, critiquing an argument — treat each very differently.

## During the edit

- **Preserve voice.** Match the existing tone, register, and citation style. If the document is formal LaTeX and you're inclined to add markdown bullets, stop.
- **Surface disagreements.** If the source says something that seems wrong, do not silently "correct" it. Flag the issue, propose a fix, and wait.
- **Track every change.** Work in small, reviewable diffs. Never bulk-rewrite a paragraph without showing the before/after.

## Verification after edit

- **Re-read from the top.** Your edits may have broken inter-paragraph references.
- **Check bibliography consistency.** Did you introduce a new citation? Is it in the bib file?
- **Run the format-check.** If the project has a `make check` / `latex` / `markdownlint` / etc., run it.
