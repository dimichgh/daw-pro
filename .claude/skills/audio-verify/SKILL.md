---
name: audio-verify
description: Verify the audio engine actually produces correct sound — build, run engine tests, and perform an offline-render check with signal assertions. Use after any change to Sources/DAWEngine or DSP code, and before checking off audio roadmap items.
---

# Audio Verify

1. `swift build 2>&1` — must be clean (warnings in DAWEngine are findings, not noise).
2. `./scripts/test.sh 2>&1` — all suites pass.
3. **Offline render check** (the part that actually proves audio): render a known test signal through the current graph to a wav in the scratchpad and assert on it:
   - Sine 440Hz @ -6dBFS through a unity graph → RMS within 0.5dB of expected, no NaN/inf, no DC offset > -60dBFS.
   - Gain/pan changes → measurable, correct-direction level changes per channel.
   - If a test-harness target exists (`swift run EngineHarness` or an offline-render test tagged `.render`), use it; otherwise write a temporary Swift Testing case and leave it in Tests/DAWEngineTests/ (they're cheap, keep them).
4. If metering is implemented, compare meter-reported peak/RMS against values computed directly from the rendered buffer (±0.5dB).
5. Report pass/fail per check with numbers (measured vs expected dB). A failure blocks roadmap checkboxes — say so explicitly.
