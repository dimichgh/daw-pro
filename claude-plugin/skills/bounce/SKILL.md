---
name: bounce
description: Render a DAW Pro project to a final mixdown and/or stems, with a loudness-verification gate before calling it done. Use for "bounce this", "export stems", "render the final file", or "give me a streaming-ready master".
---

# /bounce — render, with a loudness gate

This skill delegates to the **finisher** agent (see `agents/finisher.md`)
for the actual render calls, and to `mix-engineer` if the loudness gate
fails and a fix is needed before re-rendering.

## 1. Confirm scope

Ask (or infer from context) what's needed: a plain mixdown, a
loudness-normalized bounce toward a target, stems, a frozen (bounced-in-
place) track, or some combination. Confirm the loudness target if the user
cares about one — default assumption is -14 LUFS integrated for streaming
unless told otherwise (-23 LUFS for broadcast delivery is the other common
ask).

## 2. Pre-flight measurement

Delegate to `finisher` to call `render_measure_loudness` first — this
writes no file, so it's free to check where the mix currently stands before
committing to a normalized bounce. If it's already close to the target, a
plain `render_mixdown` may be all that's needed; if it's far off, plan for
`render_bounce` with an explicit `lufsTarget`.

## 3. Render

Delegate the actual render(s) to `finisher`:
- **Mixdown only:** `render_mixdown` (fast, no loudness report/gain) or
  `render_bounce` (adds the loudness report, and normalizes toward
  `lufsTarget` if given).
- **Stems:** `render_stems`, optionally with `includeMixdown: true` for a
  reference file alongside them. Remind `finisher` to check
  `project_overview` first for which tracks/buses are master inputs (stems
  only export those).
- **Freeze one track:** `track_bounce_in_place`.

## 4. Verify the gate

If a `lufsTarget` was requested, check `report.output` (the RE-MEASURED
actual result) and `report.limitedByCeiling`. **A bounce that fell short of
the target because the true-peak ceiling clamped the gain is not a pass** —
report the shortfall honestly. Loop back to `mix-engineer` to add/tighten a
limiter on the master chain, then re-run step 3, rather than silently
shipping a quieter-than-asked file.

## 5. Report

Give the user the exact file path(s), the final loudness numbers (input and
output, and target if any), and whether the gate passed. Do not save the
project as part of this skill — rendering an audio file and saving the
`.dawproj` project are separate actions; only save if the user asks.
