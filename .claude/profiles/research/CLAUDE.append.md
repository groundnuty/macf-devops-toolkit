<!-- Profile: research -->

## Profile: research

Information + technical research — reading documentation, analyzing code, evaluating tools. No code writing.

### Scholar Gateway setup (one-time, per claude.ai account)

Scholar Gateway is a claude.ai-hosted MCP connector, not a local MCP server. To enable it:

1. In your claude.ai account settings, find "Connectors" or "MCP servers".
2. Enable "Scholar Gateway" and complete the authentication flow.
3. Confirm it's active by running `/mcp` in Claude Code — you should see `Scholar Gateway` listed.

Scholar Gateway indexes journal papers (Wiley, Elsevier, Springer, etc.). It **does not index conference proceedings** (IEEE, ACM, Springer LNCS, NeurIPS, etc.) or arXiv preprints. Supplement with WebSearch on Google Scholar for those.

### Active profile-specific rules

- `writing-quality.md` — from info profile (prose quality rules).
- `citation-discipline.md` — citation norms for research output.
- `reading-before-editing.md` — verification loop before modifying research documents.
