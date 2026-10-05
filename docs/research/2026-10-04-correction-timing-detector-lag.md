# Correction timing: the pitch detector's lag is per voice (item `lag-d`, filed 2026-10-04)

**Status:** FILED for `daw-architect`, NOT started. Generation 2 (the half-hop timing fix) is ON HOLD. Nothing from
this investigation is in the product. Source: W7-LAG, 2026-10-04, rulings by the orchestrator (ROADMAP "▶ RESUMED
2026-10-04"). Every number below was MEASURED by the lane unless marked; the orchestrator verified the provenance facts
(ffprobe) and the experiment design, not each number.

## Why this exists
A pitch correction lands about 16 ms EARLY in the render (the half-hop term), so a removed wobble is only about half
removed. The obvious fix (generation 2: drop the half-hop) puts corrections on time for one of the user's takes
(`raw-raw-song.m4a`, 24 kHz, 63 kb/s: −15.00 → −1.37 ms) and makes the other WORSE (`dry-vocals.m4a`, the 33 s take,
48 kHz, 243 kb/s: −1.50 → +12.50 ms). The cause is the detector: it reads dry-vocals' low notes ~11 ms LATE and
raw-raw's on time, and today's early half-hop happens to cancel the lag on dry-vocals. Sample rate (experiment E) and
codec (PREREG-6) were ruled out; the gap survives a grid-phase sweep (PREREG-6b). It is a property of the take/voice.

## Where the evidence lives (scratch, wiped when idle: backed up by the rolling scratch backup)
`$S/w7/LAG/`: `STATUS.md`, `PREREG-4/4a/5/6/6a/6b.md`, `draft/diag/*DiagTests.swift` (RealVoiceGeneration, LagF1Real,
RateSwap, CodecArm, GridPhase), `logs/gfull-g2-*.log`. The generation-2 mechanism (17 touch points + a wire-echo test
draft) is kept together in scratch `gfull-g2`, and must never be installed with the generation pinned to 1.

## The measurement section for the daw-architect brief (W7-LAG's FINAL copy, verbatim)

1. QUANTITY. Per-take detector lag L (ms): the offset of the product detector's frame-centred contour (SwiftF0, 16 ms
   grid, frame k at k·16 + 8 ms) behind the take's real pitch movement. Measured ONCE at tune time. Distinct from the
   render residual (−0.6…−1.6 ms with generation 2's lookup, rate-scaled) — the two add.
2. INSTRUMENT + validated envelope. Detector contour vs the calibrated tracker (M23QToneTracker 4096/480/240 at 48 kHz),
   both high-passed (0.2 s centred moving average), xcorr scan ±40 ms at 0.25 ms; phase fit at the note's own rate as a
   second instrument. Validated against ANALYTIC truth at 24 and 48 kHz to ≤ 0.25 ms (8 synthetic cells, E). NOT valid at
   16 kHz (−2.4 ms at 110 Hz, fails ≥ ~180 Hz). Design input: resample to 48 kHz first (the zero-phase windowed-sinc
   resampler in RateSwapDiagTests: 0.000 µs offset, ≤ −113 dB error). Every reading carries the +10 ms detector-shift
   control (+10.00 on every valid note so far; a scan-arithmetic check only, see the law below). The detector's lag is independent of input rate (E: ≤ 0.5 ms per note).
   ⛔ CONTROL LAW (coordinator, 2026-10-04): the +10 ms shift is added to frame times AFTER detection
   (LagF1RealDiagTests:60). It checks only the scan arithmetic and cannot fail on grid placement.
   The control that does test the instrument is AUDIO-DOMAIN (PREREG-6b): zeros prepended to the DETECTOR's input
   only, with the tracker on the unpadded audio and frame times as reported.
   - Whole detector hops read their own size EXACTLY: 16 ms = 384 samples at 24k / 768 at 48k / 256 at 16k, and
     32 ms = 768 / 1536 / 512. Measured Δ +16.00 and +32.00 (error 0.00 ms) on every clean note of dry-vocals at
     24k and 48k and of raw-raw, and on the 110 Hz tone by both xcorr and analytic truth.
   - Mechanism: the padded detections are bit-identical in pitch, re-indexed by one or two frames, on all 1083
     (dry) / 225 (raw) frames voiced in both, with 0 voicing mismatches.
   - The instrument measures an audio-domain delay at its true size.
   PER-NOTE GRID SENSITIVITY (PREREG-6b sweep, zeros 0-14 ms in 2 ms steps at 24k).
   - Phase ranges (max − min over 8 phases): dry 1.50 / 0.75 / 5.00 / 1.25 ms; raw 1.00 / 2.75 ms; tone 0.50 ms.
   - Almost all of it is the DETECTOR's own phase dependence (detector-only padding "Dt"): dry 1.00 / 0.50 / 5.00 /
     1.25 ms; raw 1.00 / 2.25 ms.
   - The tracker's share stays within −0.75…+0.75 ms on the real notes and is 0.00 on the tone. Against analytic
     truth, the tracker's error is ≤ 0.17 ms.
   - The detector's grid effect on a clean tone is ≤ 0.36 ms (analytic), but up to 5 ms on a real note (dry
     97.18 Hz).
3. ELIGIBILITY + YIELD. Note ≥ 0.55 s, 0.1 s trimmed each side, r ≥ 0.6, tracker wobble ≥ 5 c, lag inside the scan; the
   data also needs an α window (one Show of Grace note: α 0.10, reads −40 ms at the scan edge) and an xcorr-vs-phase
   agreement window (raw-raw 89.6 Hz: 3.4 ms apart). Yield: dry-vocals 4 of 88 notes, raw-raw 2/16, Show of Grace 5/35
   (4 after an α window), Les Choses 3/84. MOST NOTES ARE NOT INDIVIDUALLY MEASURABLE.
4. PER-NOTE vs PER-TAKE. Within-take spread of eligible notes: dry-vocals 4.75 ms (+8.25…+13.00), Show of Grace 8.25 ms
   (−0.50…+7.75), Les Choses 27 ms (−11.25…+15.75, sign-ambiguous above 200 Hz), against a ±3 ms landing gate. The
   synthetic table says L falls with pitch (110 Hz +12…+13; 220 Hz −1.5…+4.5) and differs by voice above ~130 Hz. The
   data favours per-note-where-eligible, else the take's median; the architect's call.
   DECIDED BY THE SPREAD (PREREG-6b's pre-registered rule): PER-NOTE L IS RESOLVABLE WHERE ELIGIBLE.
   - 4 of dry-vocals' 6 note pairs have disjoint phase ranges: 102.83 [+10.00, +11.50]; 112.16 [+13.00, +13.75];
     97.18 [+11.50, +16.50]; 109.13 [+7.75, +9.00]. So the notes differ by more than grid error.
   - Single-reading error bar, max_n(range_n)/2: 2.50 ms on dry (from 97.18 Hz) and 1.38 ms on raw.
   - Raw-raw's own 2 notes overlap ([−0.25, +0.75] vs [−2.25, +0.50]), so per-note resolution is shown on ONE take
     only (4 notes).
   - Design constraint (INFERRED from the Dt attribution): the phase dependence belongs to the detector's contour, not
     to the instrument. L must therefore be measured on the SAME detection, at the same grid phase, as the contour
     it corrects. Measured that way, the error is NOT the 2.5 ms bar. It has two parts: the tracker's grid share
     (±0.75 ms on real notes), and the tracker's absolute error against analytic truth (≤ 0.25 ms in E's 8 synthetic
     cells; ≤ 0.17 ms across the 6b tone's 8 phases).
   - A re-detection from a different start sample (another grid phase) can move a note's L by up to 5 ms.
5. FALLBACK (OPEN, not picked). No eligible note: (i) today's generation-1 timing (assumes ~15 ms: right for dry-vocals'
   low notes, 15 ms early on raw-raw); (ii) 0 (generation 2: right for raw-raw/Show of Grace, 11.5 ms late on dry-vocals);
   (iii) the synthetic pitch table (7.5 ms wrong on Show of Grace at 147 Hz; right on dry-vocals).
6. DETERMINISM + KEYING. L is measured once and STORED in the set (and hashed into the digest), never recomputed at render
   time. Reason, MEASURED: TWO DETECTION PATHS DISAGREE at ~1e-3 c.
   - Captured 21:33: on the SAME native samples, the product file path and the in-memory path differ in pitch on 549
     of 2081 frames (max 0.0006 c) and in confidence on 1653 (max 6.68e-06). Frame times and voicing are identical.
   - Same-path repeats were bit-identical (5 runs). Run-to-run nondeterminism on ONE path is NOT shown; the
     same-path ×50 repro remains the test for it (coordinator's filing).
   - It matters if anything keys on detected values from both paths. Item 4 adds a second reason to store L: the grid
     phase moves L.
   - The carrier: the render-generation mechanism built in scratch (17 touch points). L would be generation 3's
     content.
7. END-TO-END GATE. RealVoiceGenerationDiagTests' correction-landing instrument (xcorr of rendered−sung vs −sung) reads
   |lag| ≤ 3 ms after applying L, on dry-vocals, raw-raw-song and Show of Grace; W/W0 no worse than generation 1 on each.
   Invariance control: a take with L = 0 renders bit-identical to generation 2.
   (21:44) The landing instrument does not use the detector contour (READ: RealVoiceGenerationDiagTests:21-24, 87-116).
   It runs the calibrated tracker on the sung and the rendered audio, on the same sample timeline and the same tracker
   grid.
   - 6b measured the tracker's phase sensitivity: its share stays within ±0.75 ms on real notes and is 0.00 on the
     tone.
   - This instrument takes the difference of two tracker contours on one timeline, so its grid error is INFERRED to
     be of that order. It was not itself run under padding.
8. COST. Debug build: two takes (33 s + 6 s), eight whole-take detections and 16 note readings in 4.6 s (c1Diagnosis). Measure in release before
   promising a tune-time budget.
9. CODEC: RULED OUT (codec arm, PREREG-6, 21:34). dry-vocals re-encoded IN MEMORY to raw-raw's settings (AAC-LC 24 kHz
   mono, 63.4 kb/s actual, Apple encoder) and decoded, with the 2112-sample codec delay removed: per note +11.00/+13.75/
   +11.00/+8.00 vs +10.75/+13.00/+11.50/+8.25 for the same 24 kHz audio without the codec (Δ +0.25/+0.75/−0.50/−0.25,
   median +11.13 → +11.00; native 48 kHz reads +11.00/+13.00/+11.50/+8.25, median +11.25). At its own
   settings (48 kHz, 245.2 kb/s actual): identical to native on all four notes. Synthetic voices through the same encode
   move ≤ 0.33 ms against analytic truth (220 Hz tone −1.51 → −1.18). So neither sample rate (E) nor codec explains the
   ~11 ms gap between dry-vocals and raw-raw: it is a property of the take or voice (H-voice).
   THE GAP SURVIVES THE GRID (PREREG-6b, MEASURED, both pre-registered rules):
   - PER TAKE: the phase-wise median ranges are DISJOINT, dry [+11.13, +12.25] vs raw [−1.12, +0.38], 10.75 ms apart.
   - PER NOTE: dry's minimum over notes × phases (+7.75) exceeds raw's maximum (+0.75).
   - Raw-raw's side rests on 2 clean notes (89.61 and 179.13 Hz).
   - Because L falls with pitch (item 4's synthetic table), the H-voice comparison is the LIKE-PITCH pair: raw 89.61 Hz
     [−0.25, +0.75] vs dry 97.18 / 102.83 Hz [+11.50, +16.50] / [+10.00, +11.50].
     - Their phase ranges are ≥ 9.25 ms apart.
     - Same-phase differences are ≥ 10.25 ms.
     Raw's 179 Hz note is confounded with pitch; the gap survives with or without it.
10. FILED BY THE COORDINATOR, no action here: (lag-harness) replica re-pins; (stems-tuned?) Heart Release / Perfect Son.

