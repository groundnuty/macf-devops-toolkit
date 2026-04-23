---
name: analyze-paper
description: Analyze a research paper PDF and create structured notes for state-of-the-art positioning. Use when analyzing papers for literature review.
argument-hint: <path-to-pdf>
allowed-tools: Read, Write, Glob
---

# Paper Analysis Skill

Analyze the research paper at `$ARGUMENTS` and create structured notes for state-of-the-art comparison.

## Process

**IMPORTANT: Analyze papers ONE BY ONE to avoid context overload. Complete one paper fully before moving to the next.**

1. **Read the PDF** at the provided path
2. **Extract key information** following the template below
3. **Create a note file** in the `notes/papers/` directory with filename pattern: `XX_AuthorLastName_ShortTitle_VenueYear.md`
4. **Proceed to the next paper** automatically (if analyzing multiple)

## Note Template

Create a markdown file with this structure:

```markdown
# [Paper Title]

**Source:** [Journal/Conference, Year]
**Authors:** [Names]
**Affiliations:** [Institutions]
**DOI:** [DOI if available]
**PDF:** `[filename.pdf]`

---

## Introduction Summary

### Context & Motivation
[2-3 paragraphs summarizing the problem context and why it matters]

### Problem Statement
[Clear statement of the problem the paper addresses]

### Key Claims/Contributions
[Numbered list of contributions as stated by authors]

---

## State of the Art / Related Work Summary

### [Subsection Title from Paper]
[Summary of this related work area]

### [Subsection Title from Paper]
[Summary of this related work area]

[Continue for each subsection in their Related Work/SOTA section]

### Gaps Identified by Authors
[What gaps do they identify in existing work?]

---

## Technical Approach (Brief)

[1-2 paragraphs on their solution - keep concise]

---

## Quotable Passages

### For Introduction (Problem Statement)
> "[Quote that captures the problem well]"
> — Section X, p. Y

> "[Another useful quote]"
> — Section X, p. Y

### For Related Work (Gaps/Limitations)
> "[Quote about limitations of existing approaches]"
> — Section X, p. Y

> "[Quote about what's missing]"
> — Section X, p. Y

### For Positioning Our Work
> "[Quote that validates our approach or identifies need we address]"
> — Section X, p. Y

### Technical/Definition Quotes
> "[Useful definition or technical statement]"
> — Section X, p. Y

---

## Key Takeaways for Our Paper

### Relevance Assessment
- **Overall Relevance:** [HIGH/MODERATE/LOW]
- **For Introduction:** [YES/NO] - [brief reason]
- **For Related Work:** [YES/NO] - [brief reason]
- **As Comparison:** [YES/NO] - [brief reason]

### What This Paper Does Well
- [Bullet points]

### What This Paper Does NOT Address (Our Opportunity)
- [Bullet points - gaps we fill]

### How to Position Against This Paper

| Aspect | Their Approach | Our Approach |
|--------|---------------|------------------------|
| [Aspect 1] | [Their solution] | [Our approach] |
| [Aspect 2] | [Their solution] | [Our approach] |

### Suggested Citation Context
[1-2 sentences describing WHERE and HOW to cite this paper in our manuscript]

**Draft citation text:**
> "[Ready-to-use citation sentence for Related Work section]"

---

## Notable References to Follow Up

**IMPORTANT: Scan the ENTIRE paper's reference list to find relevant citations.**

| Reference | Why Relevant | Priority |
|-----------|--------------|----------|
| [Author et al., Year - "Title"] | [Brief reason] | HIGH/MEDIUM/LOW |

---

## Assessment Summary

| Criterion | Rating | Notes |
|-----------|--------|-------|
| Relevance to our work | ⭐⭐⭐⭐⭐ | |
| Citation value | ⭐⭐⭐⭐⭐ | |
| Quote quality | ⭐⭐⭐⭐⭐ | |
| Recency | ⭐⭐⭐⭐⭐ | |

**One-line summary:** [Single sentence capturing main value for our paper]
```

## Quote Extraction Guidelines

When extracting quotes, prioritize:

1. **Problem statements** - Quotes that articulate the challenge/gap
   - Look in: Abstract, Introduction, first paragraphs of sections
   - Example patterns: "remains challenging", "lack of", "no existing solution", "gap in"

2. **Limitation statements** - Quotes about what current solutions can't do
   - Look in: Related Work, Discussion, Conclusion
   - Example patterns: "however", "limitation", "does not address", "fails to"

3. **Vision/need statements** - Quotes about what's needed
   - Look in: Introduction, Conclusion, Future Work
   - Example patterns: "need for", "requires", "must", "should enable"

4. **Definition quotes** - Clear definitions of key concepts
   - Look in: Background, Section 2
   - Example: Computing Continuum definitions

5. **Validation quotes** - Quotes that support our approach
   - Look in: Throughout
   - Quotes that align with our paper's contributions

**Quote formatting:**
- Use exact text with "..." for omissions
- Note section and page number
- Keep quotes concise (1-3 sentences max)
- Paraphrase longer passages, quote only distinctive phrases

## Context for Comparison

<!-- Fill in per-paper project. Describe your paper's focus so the analysis can position against it. -->

When analyzing, compare against our paper's focus:
- **Our paper:** <!-- one-sentence summary of your paper's contribution -->
- **Key novelties:**
  1. <!-- novelty 1 -->
  2. <!-- novelty 2 -->
  3. <!-- novelty 3 -->

## Topics to Flag

<!-- Customize for your research area. These topics trigger HIGH priority marking. -->

Mark papers as HIGH priority if they discuss topics directly relevant to your paper's contribution area.

## Output Location

Save extracted notes to: `notes/papers/XX_AuthorLastName_ShortTitle_VenueYear.md`

Where XX is the next available number in sequence.
