---
name: mix-check
description: Read a DAW Pro project's mix state, analyze it, and report issues (balance, tonal, loudness) — then apply agreed fixes via the mix-engineer agent. Use for "how does this mix sound", "check the levels", "is this loud enough for streaming", or a general mix review request.
---

# /mix-check — review and (optionally) fix the mix

## 1. Gather state

Call `project_overview` directly (available in the main session via this
plugin's MCP server) to see the track roster, routing, and effect chains at
a glance. If you need exact effect-parameter values or automation curves,
follow up with `project_snapshot`.

## 2. Analyze

- `mixer_master_analysis` for a live read of the mix's tonal balance (24
  frequency bands, short-term level/peak, spectral centroid/brightness,
  spectral flux/busyness) — call it a couple of times during playback
  (start playback with `transport_play` if nothing's currently rolling; the
  producer agent's toolset owns transport control) rather than once at a
  standstill, since it decays to floor values when silent/stopped.
- `render_measure_loudness` for the number that actually matters for
  delivery: integrated LUFS, max momentary/short-term LUFS, true peak
  (dBTP). Compare against -14 LUFS integrated (streaming convention) or
  -23 LUFS (EBU R128 broadcast) unless the user names a different target.
- Look at each track's `fx` chain and `sends` in `project_overview` for
  obvious gaps: no effects on a lead vocal that clearly needs presence, no
  bus glue on a drum group, nothing on the master chain at all.

## 3. Report issues plainly

Structure findings as: **what's off** → **why it matters** → **what fix you'd
suggest** (e.g. "the master chain has no limiter and the mix peaks above
-1 dBTP — add a limiter with ceilingDb around -1 before the next bounce").
Don't apply anything yet — this step is diagnostic.

## 4. Apply agreed fixes (delegate to mix-engineer)

Once the user agrees to a fix list, delegate the actual changes to the
**mix-engineer** agent (levels/pans/sends/buses/sidechain/automation/master
chain) or **sound-designer** (if the issue is really a tone/instrument
problem masquerading as a mix problem — e.g. a synth patch that's
inherently too harsh, not a mix that needs more EQ to fix it). Re-run step
2's measurements after the fixes land to confirm they actually moved the
needle.

## 5. Close the loop

Summarize before/after loudness numbers and any remaining known issues.
Don't render a final file as part of this skill — that's the `bounce`
skill's job, once the user is happy with the mix.
