---
name: proofread
description: Read-only proofreading pass over lecture `.tex` or `.qmd` files. Checks grammar, typos, overflow, terminology consistency, and academic writing quality; produces a report without editing. Use when user says "proofread", "check for typos", "look for grammar issues", "copy-edit this", "any writing errors?", or before a lecture release.
argument-hint: "[filename or 'all']"
allowed-tools: ["Read", "Grep", "Glob", "Write", "Task"]
---

<!-- Adapted from pedrohcgs/claude-code-my-workflow (MIT), https://github.com/pedrohcgs/claude-code-my-workflow -->


# Proofread Lecture Files

Run the mandatory proofreading protocol on paper/manuscript files. This produces a report of all issues found WITHOUT editing any source files.

## Steps

1. **Identify files to review:**
   - If `$ARGUMENTS` is a specific filename: review that file only
   - If `$ARGUMENTS` is "all": review all paper/manuscript files in `**/*.tex` and `**/*.md`

2. **For each file, launch the proofreader agent** that checks for:

   **GRAMMAR:** Subject-verb agreement, articles (a/an/the), prepositions, tense consistency
   **TYPOS:** Misspellings, search-and-replace artifacts, duplicated words
   **OVERFLOW:** Overfull hbox (LaTeX), content exceeding slide boundaries (Quarto)
   **CONSISTENCY:** Citation format, notation, terminology
   **ACADEMIC QUALITY:** Informal language, missing words, awkward constructions

3. **Produce a detailed report** for each file listing every finding with:
   - Location (line number or slide title)
   - Current text (what's wrong)
   - Proposed fix (what it should be)
   - Category and severity

4. **Save each report** to `.claude/session-reports/`:
   - For `.tex` files: `.claude/session-reports/FILENAME_report.md`
   - For `.qmd` files: `.claude/session-reports/FILENAME_qmd_report.md`

5. **IMPORTANT: Do NOT edit any source files.**
   Only produce the report. Fixes are applied separately after user review.

6. **Present summary** to the user:
   - Total issues found per file
   - Breakdown by category
   - Most critical issues highlighted
