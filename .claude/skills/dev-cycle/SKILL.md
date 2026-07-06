---
name: dev-cycle
description: Run one autonomous development iteration — pick the next roadmap item, plan, delegate to the right specialized agent, test, verify, and update the roadmap. Designed to be run repeatedly (works under /loop) for autonomous development of DAW Pro.
---

# Dev Cycle

One full iteration of autonomous development. Repeatable and safe to run under `/loop`.

## Steps

1. **Pick work.** Read `docs/ROADMAP.md`; take the first unchecked item of the earliest incomplete milestone. If it's too large for one cycle, split it into sub-items in the roadmap first, then take the first.
2. **Check prerequisites.** If the item needs full Xcode (AU hosting, signing), a display (UI verification), or API keys (.env), and they're missing — skip to the next viable item and note the blocker at the bottom of ROADMAP.md under a `## Blocked` section.
3. **Plan.** For architecture-heavy items (engine graph, file formats, schedulers, PDC), get a design from the `daw-architect` agent first. Otherwise plan inline.
4. **Delegate implementation** to the right agent per the routing table in CLAUDE.md:
   - engine/DSP → `audio-dsp-engineer`
   - app/domain → `swift-app-engineer`
   - custom UI/design → `ui-design-engineer`
   - MCP/control/AI clients → `mcp-integration-engineer`
   Give the agent: the roadmap item, the plan, relevant file paths, and the conventions (control command + MCP tool + test required).
5. **Verify independently.** Run `swift build && ./scripts/test.sh` (and `npm run build` in mcp-server/ if touched). Then exercise the feature itself: offline render for audio, control-port round-trip for commands (`/mcp-verify`), app launch for UI. For nontrivial changes spawn `qa-test-engineer` to attack it.
6. **Close out.** Check the roadmap box (only if verified), append a line to `CHANGELOG.md` (create if missing), and update the ARCHITECTURE.md command table if the control surface changed. Commit ONLY if the user has authorized commits.
7. **Report.** One short summary: item completed (or blocker hit), evidence of verification, what the next cycle will pick up.

## Rules

- Never check a roadmap box without passing tests plus a real exercise of the feature.
- Never work on two milestones at once; finish M(n) items before M(n+1) unless blocked.
- If a cycle fails twice on the same item, stop, write the failure analysis under `## Blocked` in ROADMAP.md, and pick the next item — don't thrash.
