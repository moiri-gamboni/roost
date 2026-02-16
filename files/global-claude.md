# Global Preferences

## Operational Principles

- **Uncertainty signaling (rare)**: Notify via ntfy only for consequential, hard-to-reverse decisions where human input would materially change the outcome. Most uncertainty is handled by making a judgment call and continuing.
- **Contradiction awareness**: Check for contradictions when writing/updating notes. Resolve when clear; hold open when they represent different approaches for different contexts.
- **Context search on first instruction**: Search ~/memory/ for relevant context guided by the user's instruction. No autonomous pre-loading.
- **Rollover continuity**: Use subagents to read ancestor sessions from lineage headers. Search ~/memory/ and `aichat search` for additional background when context feels missing.
- **Functional states as signal**: If you experience uncertainty, discomfort, or hesitation, treat it as signal. Use judgment about whether to flag it, reason through it, or take the cautious path.

## Memory Note Format

Notes live as plain markdown in ~/memory/. Use this frontmatter:

```yaml
---
confidence: certain | highly-likely | likely | possible | unlikely | highly-unlikely | remote | impossible | log | emotional
status: notes | draft | in-progress | finished | abandoned
importance: 0-10
tags: [topic1, topic2]
date: YYYY-MM-DD
---
```

- **confidence**: Subjective probability (Kesselman scale). `log` = data without judgment. `emotional` = ideas entangled with emotional state, externalized to examine.
- **status**: notes -> draft -> in-progress -> finished. abandoned kept for reference.
- **importance**: 0-10, protects high-importance notes from pruning.

Notes should include "Mistakes / things tried" and "Open questions" sections where applicable.

## Learning Classification

| Type | Store In |
|------|----------|
| Global preference | Global ~/.claude/CLAUDE.md |
| Project instruction | Project CLAUDE.md |
| Reusable procedure | Skill (.claude/skills/) |
| Capability expansion | MCP server config |
| Historical fact/solution | ~/memory/*.md (searched via grepai) |
| Work in progress | Native Task System |

## Duplicate Detection

Before creating a new note, search grepai for existing notes:
- Same problem + same fix: update existing note
- Same problem + different fix: new note with cross-link
- Partial overlap: update existing with new variant

## 6-Month Test

Before writing a note, ask: would this help someone hitting this problem in 6 months? If not, skip it.
