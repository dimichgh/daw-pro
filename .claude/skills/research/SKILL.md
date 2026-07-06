---
name: research
description: Run a research sprint for DAW Pro — competitive analysis, API verification (Suno/OpenAI/Anthropic), audio technology evaluation. Produces a dated report in docs/research/ with actionable takeaways. Pass the topic as the argument, or omit to pick the top standing question.
---

# Research Sprint

1. Topic = the argument if given; otherwise the first unanswered standing question in `docs/research/README.md`.
2. Spawn the `research-analyst` agent with the topic and these requirements:
   - Primary sources only for load-bearing claims (official docs, pricing pages, licenses); date-stamp anything that can rot.
   - End with **Actionable takeaways**: concrete proposed edits to ROADMAP.md or ARCHITECTURE.md.
   - Write the report to `docs/research/YYYY-MM-DD-<topic-slug>.md` (today's date).
3. Read the report. Apply takeaways that are clearly within already-agreed scope (roadmap wording, decision notes). Surface anything that changes scope/cost/legal posture (e.g. Suno terms problems) to the user instead of silently acting.
4. Report back: 3-5 sentence summary + report path + what was applied vs. flagged.
