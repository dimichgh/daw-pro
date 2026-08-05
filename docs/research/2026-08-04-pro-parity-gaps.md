# Pro-parity gap audit round 2 — mixing, mastering, metering & delivery focus (2026-08-04)

Date: 2026-08-04
Author: research-analyst (agent)
Commissioned by: the user, immediately after the m23-ch investigation ("the mastering agent hit a −1 dBTP
target, our limiter is sample-peak only, it walked the ceiling by trial and error across four renders").
Scope: **a re-audit**, not a first pass — `docs/research/audit-m10q-pro-parity.md` (2026-07-11) already
covered ten candidates. This document states what changed since (all ten shipped), then hunts for what
that audit — and everything filed since — missed, weighted toward mixing/mastering/metering/delivery per
the brief, ranked by the "invisible from inside, no error raised, real cost, every competing DAW has it"
shape m23-ch exemplifies rather than by feature-list completeness.

## Method and its limits (read before trusting any absence claim below)

- No Bash tool was available in this session, so the `rtk proxy` recipe could not be used. All source
reading went through `Read`/`Grep`/`Glob`.
- `docs/ROADMAP.md` is 882 lines but 1.7 MB — individual lines run into the thousands of characters, well
past what `Read` or `Grep`'s content mode will display (`Read` refuses full-file loads over ~25K tokens;
`Grep` silently prints `[Omitted long matching line]` for long lines even when a match exists). I could
not read it end to end. Every claim below of the shape "not found in ROADMAP" means **not found by the
specific regex patterns I ran** (dozens, covering the vocabulary a competitor feature would be filed
under), not "proven absent by inspection." Where a pattern-miss is load-bearing for a finding, I ran at
least two independently-worded patterns before concluding absence, and I flag the ones I'm least sure of
explicitly in-line.
- `docs/FEATURES.md` (read in full) is **materially stale** and was not trusted as ground truth for "already
disclosed" claims — it still reports 126 wire commands / 129 MCP tools / 9 built-in effects and doesn't
mention MIDI CC lanes as shipped (M16), tempo maps (M12), sidechain (M12), markers (M11), crossfades
(M11), bounce-in-place (M11), gain envelopes (M13), or the tenth built-in effect (BassEnhancer). Ground
truth used instead: `Sources/DAWControl/Commands.swift` (case list), `Sources/DAWEngine/Effects/*.swift`,
`Sources/DAWEngine/Analysis/*.swift`, `Sources/DAWCore/Effects.swift`, `Sources/DAWApp/Export/ExportSheet.swift`,
and `docs/ROADMAP.md` via targeted grep. **Flagging the staleness itself as a `docs-scribe` action item**,
same practice as the m10-q audit's FEATURES.md flag.
- Competitor claims are web-sourced and cited inline (2026-08-04 searches); none asserted from memory.
Where a search did not turn up confirmation for one of the five compared DAWs, that is stated explicitly
rather than implied by omission.

## Part 1 — What the m10-q audit found, and what happened to it (inherited, not re-audited)

All ten m10-q candidates shipped between M11 and M16. This is a complete discharge of that backlog —
worth stating plainly since a caller filing items from *this* doc should not also re-open that one:

| m10-q candidate | Disposition |
|---|---|
| Session markers | Shipped M11 (m11-c) — `marker.*` (5 commands), ruler lane UI |
| Groove-template UI | Shipped M11 (m11-a) — quantize panel groove picker |
| Undo-history panel | Shipped M11 (m11-b) — `edit.history`, `UndoHistoryPanel.swift` |
| Crossfade tool + overlap-doubling fix | Shipped M11 (m11-d) — `clip.crossfade`, `resolveOverlap` |
| Track bounce-in-place | Shipped M11 (m11-e) — `track.bounceInPlace` |
| Per-clip gain envelopes | Shipped M13 (m13-e) — `clip.setGainEnvelope`, `[ClipGainPoint]` |
| MIDI CC lanes | Shipped M16 (m16-b1…b4) — model + schedule + live thru/capture + piano-roll CC strip |
| Tempo map + time-signature changes | Shipped M12 (m12-b…e) — full `TempoMap`/`MeterMap` refactor |
| Sidechain routing | Shipped M12 (m12-a, f, g) — `fx.setSidechain`, compressor/gate only, v1-scoped |
| Count-in/pre-roll UI stepper | Folded into M15-era transport-bar polish |

Also since m10-q and directly relevant to this audit's scope even though not on that list: **master effect
chain** (M13, m13-d), **live loudness metering with true peak** (m22-c — momentary/short-term/integrated
LUFS + LRA + true peak dBTP on the master strip, 5 Hz poll), **reference-track A/B loudness-matched
comparison** (m22-g), **stereo correlation/goniometer + M/S balance on the master analyzer** (m22-d),
**export format/bit-depth/container options** (m23-m1–m3 — `bitDepth`, `container`, a real Export dialog),
**mastered-mixdown sibling file alongside stems** (m23-m umbrella). This project has iterated on
mixing/mastering/metering considerably harder than the m10-q snapshot suggests — most of the "obvious"
gaps a first-pass audit would flag are already closed.

## Part 2 — The finding this audit is calibrated against (already filed, still open)

**`(m23-ch)` — the built-in Limiter is sample-peak only; no true-peak (oversampled) mode.** This is
**already in `docs/ROADMAP.md`** as an open (`- [ ]`) item, filed 2026-08-04 from the same investigation
that commissioned this audit. I am not re-discovering it — I'm using it as the yardstick the brief asked
for. Restated only enough to calibrate: `LimiterEffect.swift`'s own doc comment states a "hard SAMPLE-PEAK
guarantee BY CONSTRUCTION," a monotonic-deque sliding-window peak-hold with no oversampling. A dBTP
(true-peak) measurement reconstructs the inter-sample waveform and reads above a sample-peak ceiling on
dense material — the agent's own numbers showed 0.43–0.98 dB of overshoot across four settings, textbook
for a non-oversampled brickwall, and it misdiagnosed this as "nondeterministic" app behavior rather than
a documented, material-dependent property of the algorithm it was using. Every test the limiter has
passes; the contract is honored exactly; it simply isn't the contract a mastering delivery spec needs.
**Confirmed via web search that this is a feature every compared competitor ships**: Logic Pro's Adaptive
Limiter has an explicit "True Peak Detection" toggle ([Apple Support](https://support.apple.com/guide/logicpro/adaptive-limiter-controls-lgcef1becbb8/mac)),
and Ableton Live 12.1's Limiter device ships a dedicated **True Peak mode** distinct from its Standard mode
("prevents all overshoots ... as opposed to Standard mode which lets a few peaks through") ([Push
Patterns: Ableton Live 12.1 Limiter](https://www.pushpatterns.com/blog/AbletonLive12-1Limiter)).
Fix shape is already scoped in the ROADMAP entry (opt-in `truePeak: Bool` on `LimiterParams`, default off,
oversampled detection, RT-safety preallocation discipline). Nothing to add here except: **it belongs at
the top of the shortlist below**, marked already-filed, because a caller reading only the shortlist should
still see the highest-cost open item.

### A one-line, high-leverage finding directly coupled to m23-ch

**`docs/FEATURES.md:90` currently describes the Limiter's "Key Controls" as `"Threshold, attack, release
(5 ms lookahead, true peak ceiling)"` — this is factually wrong** (re-confirmed by grep against the live
file, not just my earlier full read). The limiter has no true-peak mode at all (confirmed in
`LimiterEffect.swift`, confirmed by m23-ch's own investigation). This single stale doc line asserts the
exact capability the app doesn't have, in the one file most likely to be read by someone deciding whether
they need a workaround. It is not certain this doc line caused the m23-ch agent's confusion (the
investigation record doesn't cite FEATURES.md as its source), but it is a live, easily-triggered source of
the identical mistake for the next user or agent who checks the spec table before mastering. **Effort:
trivial (one line). Route: docs-scribe, same pass as the m23-ch code fix**, so the doc and the code become
true together rather than the doc staying wrong after the limiter changes.

## Part 3 — Fresh findings, ranked by the m23-ch shape

### 3.1 No dithering applied when reducing bit depth on export (v0 policy, no v1 scheduled)

**What it is.** `render.bounce`/`render.stems`/`render.mixdown` accept `bitDepth: 16 | 24 | 32` (m23-m2,
shipped 2026-07-27). When a lower bit depth is chosen, the render path hands the buffer to AVFoundation's
own PCM writer via `AVLinearPCMBitDepthKey` (`OfflineRenderer.swift:617-618`) — AVFoundation's converter
quantizes by **rounding to the nearest representable value**, confirmed by the shipping gate's own
measurement: 24-bit worst-case delta = `5.960e-8`, exactly `2⁻²⁴` — half an LSB, the textbook signature of
rounding (ROADMAP m23-m2 gate record). **No dither (TPDF or otherwise) is added before that quantization
step.** The policy is explicitly named "v0" in the ROADMAP text and reported honestly on the wire
(`ditherApplied: false` in the response), but **I found no ROADMAP item scheduling a v1** — grepped
`dither`/`TPDF`/`noise shap` across the whole file; every hit is the same v0 record, none is a forward
schedule.

**What breaks, concretely.** Rounding without dither doesn't just add noise — it adds *signal-correlated*
quantization distortion, because the rounding error tracks the input rather than behaving as independent
noise. This is most audible exactly where mastering engineers listen hardest: quiet passages, fade-outs to
silence, and long reverb/delay tails, where a 16-bit rounding step can produce a faint but perceptible
buzz or graininess that competitors' dither eliminates by design. **This is invisible from inside** in the
same way the true-peak gap was: every render succeeds, the file is valid, `ditherApplied: false` is
reported truthfully — but the human-facing Export dialog (`ExportSheet.swift:35`) **deliberately shows no
loudness or quality numbers at all** ("NO LOUDNESS NUMBERS anywhere, before or after the render," a
considered decision from m23-m3 because pre-quantization numbers would mismatch the delivered file — a
correct call on its own terms, but it also means the one place a human decides "16-bit, sure" carries zero
signal that the file will be rounded, not dithered). A user or agent choosing 16-bit for a CD-era or
bandwidth-constrained delivery gets an audibly inferior file with no warning either way.

**One nuance worth stating plainly so this doesn't read as scarier than it is:** half an LSB at 16-bit is
about −96 dBFS — numerically tiny against any real ceiling. This is **not** a correctness failure like the
true-peak ceiling breach (nothing clips, nothing exceeds a spec). It is a **quality tax specific to 16-bit
delivery**: correlated distortion character instead of the benign, decorrelated noise floor every
competing DAW ships by default. 24-bit and 32-bit-float exports (the more common professional delivery
depths today) are essentially unaffected in practice.

**Competitors.** Every compared DAW dithers 24/32-bit-to-16-bit reduction by default or via an explicit
picker. Logic Pro ships POWr #1/#2/#3 and UV22HR dither algorithms specifically for the bounce-to-16-bit
step ([Apple Support: about dithering algorithms in Logic Pro](https://support.apple.com/guide/logicpro/about-dithering-algorithms-lgcp44da971f/mac)).
Pro Tools ships the same POW-r family (Type 1/2/3) at export ([Gearspace: Pro Tools dither when exporting
files](https://gearspace.com/board/mastering-forum/597703-pro-tools-dither-when-exporting-files.html)).
Cubase, Studio One and Reaper were not individually re-verified this pass — dithering on bit-depth
reduction is close to universal DAW table stakes, but treat those three as unconfirmed-by-citation here.

**Weight.** S–M. The render path already resolves `bitDepth` at one call site; adding a TPDF (or
noise-shaped) dither generator ahead of the existing AVFoundation quantization step is contained, but it
needs a design decision on *where* the quantization happens today (does `AVAudioFile`'s writer do the
rounding, or would dithering require bypassing it and writing raw integer PCM by hand?) before scoping —
flagging this as unverified from the tree: I confirmed the settings dictionary passed to AVFoundation, not
which internal code path performs the actual sample conversion.

**ROADMAP coverage.** Not scheduled. The v0/v1 language in the m23-m2 record is the closest thing to a
placeholder; there is no item id for "add real dithering."

### 3.2 No mid/side (M/S) processing anywhere in the built-in FX suite

**What it is.** Grepped all of `Sources/DAWEngine/Effects/` for `mid.?side|M/S` — zero hits outside
`ReverbEffect`'s tail-only stereo-width knob. `EQEffect` and `CompressorEffect` operate per-channel (or
stereo-linked) only; there is no encode-to-M/S, process, decode-back-to-L/R option on any dynamics or tone
processor. This is a genuinely absent *capability*, not a UI gap — nothing in the render path performs
M/S encode/decode.

**What breaks.** Nothing fails silently here — a user simply can't do it, and would notice immediately (a
"noticed, routed-around" gap, not a silent one, so it ranks below 3.1 per the brief's cost model). But it
is a real mastering-workflow absence: tightening the low end to mono while keeping highs wide, or
de-essing/EQing the sides independently of the center image, is a routine mastering-chain move that this
app cannot do at all today, on any track including the master.

**Competitors — confirmed for two of the five.** Ableton Live's EQ Eight ships a Stereo/L-R/M-S mode
switch, with mid and side edited independently ([MusicRadar: how to use mid/side EQ in Ableton
Live](https://www.musicradar.com/how-to/mid-side-eq-ableton); [Ableton forum: EQ8 M/S
mode](https://forum.ableton.com/viewtopic.php?f=1&t=168431)). Cubase's stock Frequency EQ offers per-band
Mid-Side vs Left-Right processing ([Steinberg: Frequency 2 mid-side
view](https://forums.steinberg.net/t/frequency-2-eq-mid-side-view/784640)). **Logic, Studio One, and
Reaper were searched but not confirmed this pass** — Studio One's Pro EQ3 M/S capability specifically
returned no confirming source; do not repeat this claim as "all five" without re-checking those three.

**Weight.** M. The shared primitive (M/S encode/decode around a processing block) is a contained, one-time
piece of DSP; wiring it into EQ and Compressor as a per-effect mode is two moderate follow-on changes once
that primitive exists.

**ROADMAP coverage.** Not found by any pattern tried (`mid-side`, `M/S`, `mid.?side`, case-insensitive).

### 3.3 No built-in multiband compressor or dynamic EQ

**What it is.** The built-in effect roster is 10 kinds (`EffectFactory.swift`: gain, eq, compressor,
limiter, reverb, delay, saturator, gate, chorus, bassEnhancer — one more than FEATURES.md's stale count of
9 at line 249, since it's missing bassEnhancer). None of them split the signal into frequency bands for
independent dynamics, and none apply EQ gain that itself reacts to level (a "dynamic EQ" band).
`CompressorParams` (`Sources/DAWCore/Effects.swift:318`) is single-band, single-detector, with no mix/blend
knob either (see 3.4).

**What breaks.** Same shape as 3.2 — a noticed absence, not a silent one. A pro doing glue/mastering
compression across bands, or taming a resonant frequency only when it gets loud, has no built-in tool and
must route manually (band-split via a bus + multiple EQ/compressor chains) — inconvenient but not
impossible, since bus routing already exists.

**Competitors — this is the best-evidenced claim in this document; re-searched after an earlier draft
leaned on a circular citation (a ROADMAP AU-hosting test fixture that names `AUMultibandCompressor` only
because it's the longest installed AU name on the test machine — that's Apple's own stock AU, proves
nothing about Cubase, and was dropped).** Direct, current sources for stock multiband dynamics in **all
five** compared DAWs: Logic Pro ships **Multipressor**, a 4-band multiband compressor
([Apple Support: Multipressor overview](https://support.apple.com/guide/logicpro/multipressor-overview-lgcef1bedfc6/mac)).
Cubase ships **MultibandCompressor**, a 4-band stock insert with per-band level/bandwidth/compression
([Steinberg Cubase Pro plug-in reference: MultibandCompressor](https://www.steinberg.help/r/cubase-pro/cubaseplugref/15.0/en/_shared/topics/plug_ref/multiband_compressor_r.html)).
Ableton Live ships **Multiband Dynamics**, three independently compressible/expandable bands with
adjustable crossovers ([Ableton Live Audio Effect Reference](https://www.ableton.com/en/manual/live-audio-effect-reference/)).
Studio One ships its own **Multiband Dynamics** device (five independent compressors across configurable
frequency ranges, per a review of the stock device — treat as a secondary source, not Presonus's own
docs). Reaper bundles **ReaXcomp**, a multiband compressor, in its default ReaPlugs suite ([reaper.fm:
ReaPlugs](https://www.reaper.fm/reaplugs/)). Cubase's stock Frequency 2 EQ additionally supports
**dynamic (level-reactive) filtering per band** — a genuine dynamic-EQ mode, not just multiband dynamics
("Frequency 2 now includes dynamic filtering, where EQ applies progressively after the signal in that band
reaches Threshold" — [Sound on Sound: Cubase managing the low mids with Frequency
2](https://www.soundonsound.com/techniques/cubase-managing-low-mids-frequency-2)).

**Weight.** L for either as a genuinely new effect (crossover filters + N independent detector/gain-computer
chains + recombine, comparable in scope to the original M4 FX-pack build). De-esser (3.4) is the cheap
partial win if only one slice of this space ships.

**ROADMAP coverage.** Not found by any pattern tried (`multiband`, `dynamic EQ`).

### 3.4 No dedicated de-esser, and no parallel-compression (dry/wet) knob on the built-in Compressor

**What it is.** Two small, related dynamics-processing gaps, folded together because both are
"inconvenient DIY, not blocked" given what already shipped:
- **De-esser**: `CompressorParams` has no internal detector-filter option, so there's no one-click
sibilance tamer. A determined user *can* build the classic manual de-esser (duplicate the vocal track,
EQ the duplicate to isolate sibilance, key the original's compressor off it) because **sidechain
routing already exists** (M12) — but v1 sidechain is scoped to compressor/gate destinations only, one
key per strip, and audio-*track* sources only (bus sources are deferred per the m12-f/g record), so the
workaround costs a spare track and the strip's only sidechain slot.
- **Parallel/NY compression**: `CompressorParams` (`Sources/DAWCore/Effects.swift:318-364`) has
`thresholdDb`/`ratio`/`attackMs`/`releaseMs`/`kneeDb`/`makeupDb` and nothing else — no dry/wet blend.
Workable around via a duplicate track + send blend, same shape as the de-esser workaround.

**Competitors.** Logic Pro ships **DeEsser 2** as a stock Dynamics-category plugin, purpose-built for
sibilance with Relative/Absolute detection modes ([Apple Support: DeEsser 2 controls in Logic
Pro](https://support.apple.com/guide/logicpro/deesser-2-controls-lgcef1bec850/mac)).

**Weight.** De-esser: S–M if scoped as a fixed-band variant reusing the existing Compressor ballistics
(cheaper than full dynamic EQ). Parallel-compression mix knob: S — a single additive parameter and a
linear blend at render time, the cheapest item in this entire document.

**ROADMAP coverage.** Not found (`de-ess`).

### 3.5 Export never resamples — delivered files are always at project rate

**What it is.** `render.bounce`/`stems`/`mixdown` write at the engine's sample rate; there is no
target-sample-rate parameter. FEATURES.md states this plainly ("Sample rate: project rate"), and the
ROADMAP's own m23-m plan lists "sample-rate conversion" as unscheduled **Phase 2** future work rather than
a shipped or ticked item — so this is **not a fresh finding**, it's an already-noted, still-open gap I'm
surfacing because it sits squarely in this audit's delivery scope. Given the project already built (and
measured, in M19/M20) high-quality SRC machinery for the live device-output edge, a delivery-time SRC
option should be a smaller lift than it would be from scratch — worth noting for whoever scopes it.

**Weight.** M (per the existing Phase-2 framing — "short empirical spike").

**ROADMAP coverage.** Already noted (m23-m plan, Phase 2), not yet scheduled with an item id.

### 3.6 No VCA / folder-track grouping (distinct from bus routing, which already exists)

**What it is.** Grepped `Commands.swift`'s full case list (171 commands) for any group/folder/VCA verb —
none. DAW Pro's **bus routing** (M4-i) already gives Ableton-Group-track-equivalent functionality (a
submix destination with its own fader, sends, and effects chain) — so this is not a gap versus Ableton,
whose "Group" *is* a bus. It is a gap versus Logic's Track Stacks and Cubase's VCA faders specifically: a
mechanism to move several *independently-routed* tracks' faders together (e.g., duck all backing vocals by
a common amount) without summing their audio into one bus and without disturbing each track's own
sends/output routing.

**Weight.** M for a VCA-style linked-fader-delta model; L for full Track-Stack-style visual nesting.

**ROADMAP coverage.** Not found (`VCA`, `folder track`, `track group`, `Track Stack`).

## Part 4 — Already-disclosed, low-priority (mentioned for completeness only)

- **Automation curves are linear/hold only** (`AutomationCurveType` — `Sources/DAWCore/Automation.swift:7-8`).
Bezier/S-curve breakpoints are already listed in FEATURES.md's Limitations table as "❌ Not yet... deferred
to v1 polish." Genuinely known, not a fresh finding.
- **Lossy export formats (MP3/AAC/FLAC) are absent.** Already disclosed in FEATURES.md ("🔶 Partial") and
already scoped in the m23-m Phase-2 note ("AAC/ALAC/FLAC write-path verification... never MP3 —
AVFoundation decodes but does not encode it"). WAV/AIFF (lossless) already cover professional delivery;
this is a convenience gap, not a fidelity one.

## Part 5 — Flagged, not filed: possible deliberate omissions (your call, not mine)

Per `docs/VISION.md`, this project is *not* a Logic clone — it targets Logic's depth through a simpler
surface plus full AI control, and composition-assist workflows are explicitly meant to run through the
Copilot conversationally rather than through manual tool UI. I could not find evidence either way (in
`docs/ARCHITECTURE.md`'s "Key future decisions" section or ROADMAP) that the following were *considered
and rejected* versus simply not yet reached. Per the brief, I am flagging these for a user ruling rather
than filing them or recommending against filing them:

- **Arpeggiator / step sequencer / scale-lock / chord track.** Every compared DAW has at least one of
these as manual-UI tools; DAW Pro's answer to "generate a chord progression" or "arpeggiate this" today is
asking the Copilot to call `clip.addMIDI`/`clip.humanize` directly, which is arguably more aligned with
the AI-native thesis than adding parallel manual UI for the same outcome. That's a plausible rationale,
not a confirmed one — the user's call.
- **External sync (MIDI clock / MTC / Ableton Link).** No hits in ROADMAP or ARCHITECTURE under any
pattern tried. Unlike the arpeggiator case above, I found no rationale for this one either way — not
"probably intentional," just genuinely unknown. Matters for live-performance and outboard-hardware users;
needs a user ruling, not an inference from silence.
- **ISRC/BWF metadata embedding on export.** Niche (matters mainly for distributor/label delivery
pipelines); no evidence of consideration either way.

## Part 6 — Prioritized shortlist (ranked by real user cost, not feature-list size)

1. **`(m23-ch)` Limiter true-peak mode — ALREADY FILED, OPEN, highest cost on this list.** Restated at the
top because a caller working only from the shortlist should see it. Silent, no error, cost four renders
and a wrong diagnosis, every competitor has it. See Part 2.
2. **Fix `FEATURES.md:90`'s false "true peak ceiling" claim on the Limiter row — trivial, ship alongside #1.**
The cheapest possible fix on this entire list (one doc line) and it actively perpetuates the exact
confusion #1 documents. No reason these two land in different cycles.
3. **No dithering on bit-depth-reduced export (§3.1).** Same shape as #1 — invisible from inside, honestly
reported but not surfaced anywhere a human would see it, every competitor ships it by default — just
smaller in magnitude (a quality tax, not a spec breach). Ranked #3 because it's a real, live, silent gap
with no scheduled fix, not because it's as severe as #1.
4. **No mid/side (M/S) processing on EQ/Compressor (§3.2).** The most-missed *capability* (not just
UI) among the fresh findings — routine in professional mastering chains, absent entirely, not a silent
defect but a hard capability wall once a user reaches for it.
5. **No parallel-compression mix knob on the built-in Compressor (§3.4, second half).** Cheapest real
capability add on the list (one parameter) with daily mixing value; ranked above the bigger dynamics gaps
because of the effort/value ratio, same logic the m10-q audit used for groove-UI.
6. **No built-in multiband compressor or dynamic EQ (§3.3).** Real, and the best-evidenced competitor gap
in this document (all five compared DAWs confirmed) — but "noticed and routed around" rather than silent,
and the largest build on this list. Recommend a design pass before committing to either shape, same
disposition the m10-q audit gave sidechain before M12.
7. **No dedicated de-esser (§3.4, first half).** Real but the most-mitigated gap here — sidechain (M12)
already makes a manual version buildable, at the cost of a spare track and the strip's one key slot.
8. **VCA/folder-track grouping (§3.6) and export sample-rate conversion (§3.5).** Both real, both already
lower-cost workarounds exist (bus routing; deliver at project rate), both already have partial infrastructure
to build from (bus routing; the M19/M20 SRC work). Lowest urgency on this list.

## Actionable takeaways

- **Ship #1 and #2 together** — the true-peak limiter fix and the one-line FEATURES.md correction are the
same story; landing the doc fix separately (or not at all) leaves the next reader exposed to the same
false claim that likely contributed to the m23-ch incident.
- **#1 and #3 share a mechanism worth naming as a standing check for future work**: in both cases a
delivery-critical property is computed *correctly* somewhere in the codebase (`Loudness.swift`'s 4×
oversampled true peak; the honestly-reported `ditherApplied: false`), but the surface a human actually
acts through neither applies it nor shows it. Any future mixing/mastering feature is worth checking
against that pattern specifically — "is the correct number computed, and does it reach the control a
person touches?" — since both of this audit's headline findings passed every test while failing exactly
that question.
- **#3 (dithering) deserves its own ROADMAP item now** — it has no item id today, sits in the same
mixing/mastering/delivery lane as #1, and the fix is contained (S–M) once someone confirms where in the
render path the actual bit-depth quantization happens (flagged above as unverified from the tree).
- **#4+#5 (M/S processing, parallel-compression mix knob) are a good paired M-number**: #5 is nearly free
and #4 shares no code with #1–#3, so they don't compete for the same reviewer attention or render-path
risk surface.
- **#6 (multiband/dynamic EQ) and the sidechain-adjacent de-esser (#7) should get a design spike before a
build commitment**, same pattern the m11-f spike gave tempo-map/sidechain before M12 — both touch
render-thread DSP shape decisions (crossover topology, band count) worth fixing before implementation.
- **Part 5's flagged items (arpeggiator/step-sequencer/chord-track, external sync, ISRC/BWF metadata) need
a user ruling, not a filing decision from this audit** — the arpeggiator case has a plausible AI-native
rationale argued above, but external sync has no evidence either way and should not be treated as
"probably deliberate" just because nothing was found. If the user wants any of them roadmapped, that's a
product call this audit can't make for them.
