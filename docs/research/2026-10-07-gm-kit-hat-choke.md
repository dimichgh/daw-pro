# Does the General MIDI drum kit choke its hats? (item `m39-w4-1`, measured 2026-10-07)

**Verdict: YES, it already chokes.** On Apple's General MIDI drum kit (the Standard Drum Kit in `gs_instruments.dls`,
played by Apple's AUSampler, bank MSB 120, program 0), a closed hat (42) or a pedal hat (44) silences a ringing open
hat (46). The open hat's tail is **exactly zero** from about 8 ms after the closed hat sounds, as on our own drum
machine (7 ms). **`m39-w4-9` (a synthetic hat choke for General MIDI kit tracks) is not needed.** Saved projects and new
tracks already behave like a real hi-hat. The handoff note H2 ("the GM kit's hats will cut each other on new tracks")
needs no change in behaviour: they already do.

A second finding matters for anyone who revisits `m39-w4-9`: **on this kit a note-off does nothing you can hear to an
open hat.** A 50 ms open hat and a 2 s open hat differ by −102 dB. So the design's proposed mechanism (send a note-off
to the sounding 46) would not have worked on this bank. The kit's own choke is what works.

Source: lane W8-W41 (audio-dsp-engineer), 2026-10-07. Tags: **[M]** measured by the lane, **[R]** read in source or
file, **[I]** inferred. Bars were pre-registered before the first render (`$S/w8/W41/PREDICTIONS.md`, addenda 1-2).
Evidence (scratch, wiped when idle): `$S/w8/W41/` holds the logs (`measure1-3`, `plantA-C`, `plant-post`, `final`),
`out-measure*/measure.json` (every number, plus the 10 ms and 1 ms envelopes), the float WAVs, and `STATUS.md`.

## How it was measured

- **Test:** `Tests/DAWEngineTests/GMKitHatChokeMeasureW41Tests.swift`, test "W41: the GM kit's hat choke, measured
  against our drum machine's known choke". Env-gated: it runs only with `W41_MEASURE=1`. Reproduce with
  `W41_MEASURE=1 W41_OUT=<dir> ./scripts/test.sh --filter GMKitHatChokeMeasureW41Tests` (about 4 s). It writes
  `measure.json` and seven float WAVs to `W41_OUT`.
- **Path:** a fresh `OfflineRenderer` per render, `prepareAudioUnits`, `.ready` required, 48 kHz, 120 BPM, 4 s, one track,
  one clip. This is the same hosted-AU path every sound-bank track plays through: live playback and offline render both
  reach AUSampler through `AUHostRegistry` (`AudioEngine.swift:987`, `OfflineRenderer.swift:392`,
  `AUHostRegistry.swift:764-767`) [R].
- **Subject:** `GMProgramCatalog.standardDrumKit` (bank MSB 120, program 0). **Control instrument:** our drum machine
  with `DrumKitParams(noteLayout: .gm)`, so the same notes reach the same drums (46 open hat, 42/44 closed hat,
  36 kick; `DrumKit.swift:193-215`) through the identical MIDI path. Its hats share choke group 0, so it is KNOWN to
  choke.
- **Timing:** the open hat at beat 1 (frame 24 000), the second hit 100 ms later (frame 28 800). Velocity 100 on every
  note. In (a) the open hat is a 2 s note, so a note-off cannot confound the choke. The second hit is 125 ms long.
- **Isolation** (the method of `DrumSynthTests` "Choke: a closed hat cuts a sounding open hat"): render open hat +
  second hit, subtract the second-hit-only render, and compare what remains (the open hat as it sounds once the second
  hit lands) with the open hat rendered alone. The number is the RMS ratio over 130-200 ms after the open hat's onset,
  on the left channel (the right channel is printed and agrees). Measuring the mix directly would be wrong: the closed
  hat itself still sounds in that window.
- **(b):** the open hat alone as a 50 ms note against a 2 s note.

## Results [M]

The same numbers came out of three runs, compared value by value. The one exception is a reporting fix after run 2:
a 10 ms hop where both renders are exact silence now reads 0 dB instead of −600 dB, which changed only the drum
machine's envelope hops from 1010 ms on. Within a run, two fresh renderers produce byte-identical GM renders.

### (a) Does a second hit cut the open hat?

| Second hit at +100 ms | GM kit tail (130-200 ms) | Our drum machine tail | Expected |
|---|---|---|---|
| 42 closed hat | **exactly 0** (−600 dB floor) | exactly 0 | choke |
| 44 pedal hat | **exactly 0** | exactly 0 | choke |
| 36 kick (negative control) | −0.00 dB | −0.00 dB | no choke |
| 42 on our machine with the hats' choke group removed | n/a | 0.00 dB | no choke |

How fast the GM choke is: the open hat starts to fade at frame 28 673 (the 512-frame render block that holds the
closed hat starts at 28 672), 128 frames (2.7 ms) before the closed hat's first sample (28 801). It is below −60 dB by
the 1 ms hop at 103 ms and exactly zero after frame 29 162: 7.5 ms after the closed hat sounds, 10.2 ms after the
fade starts. Our drum machine: the fade starts at frame 28 800 exactly, −60 dB by 103 ms, exactly zero after
frame 29 136 (7.0 ms).

The GM open hat on its own, for reading the window: −33.8, −36.4, −41.5, −43.9 dBFS per 100 ms from the onset (RMS
0.01448 = −36.8 dBFS in 130-200 ms). So the window holds a loud, ringing hat, not a tail that had already died.

### (b) Does a note-off shorten the open hat?

| Instrument | 50 ms vs 2 s note, 130-200 ms | Difference signal | Reading |
|---|---|---|---|
| GM kit, open hat 46 | −0.00 dB | **−102.3 dB** | a note-off has no audible effect |
| GM piano, C4 (control: note-off works here) | −9.80 dB | −3.3 dB | releases: −20 / −40 / −60 dB at 270 / 500 / 720 ms |
| Our drum machine, open hat | byte-identical | none | ignores note-off (it reads note-ons only, `DrumSynthInstrument.swift:531` [R]) |

## Validity checks and controls [M]

| Check | Bar | Measured |
|---|---|---|
| Determinism: the GM mix rendered twice by two fresh renderers | byte-equal | byte-equal (L and R) |
| Superposition on the GM path: (46 + 36) against 46 alone + 36 alone | ≤ −60 dB | −134.9 dB, worst sample 1.5e-8 |
| GM open hat loud enough in the window | ≥ 0.005 RMS | 0.01448 |
| Nothing changes before the second hit (80-98 ms) | within 0.5 dB | −0.01 dB (hat rows), 0.00 (kick row) |
| Negative control: kick in the closed hat's place, GM | within 0.5 dB | −0.00 dB |
| Positive control: our drum machine, same harness, 42 and 44 | ≤ −40 dB | exactly 0 (both) |
| Our machine with no choke group | within 0.5 dB | 0.00 dB |
| Our machine, 50 ms vs 2 s | byte-identical | byte-identical |
| GM piano note-off moves the tail | ≤ −3 dB | −9.80 dB |
| Second instrument: ffmpeg `astats` on the written WAVs | agrees | −36.786 / −inf / −36.786 dBFS (control / isolated / short) |

**Pre-registered bars that FAILED, kept on the record.** I predicted (80%) that a short and a long note render
byte-identically until the note-off frame (26 400). They do not, on the GM piano or the GM kit. The renders first
differ at frame 26 369, 31 frames (0.65 ms) early. My follow-up guess (the 512-frame block start, 26 112) was also
wrong. The release starts just after frame 26 368, a multiple of 256 (and of 64 and 128). So AUSampler probably
applies a note-off at an internal sub-block boundary [I]. The −0.01 dB in the hat rows' before-window (still inside
its 0.5 dB bar) is the same kind of effect: the GM choke starts at frame 28 673, right after the block start (28 672),
2.7 ms before the closed hat sounds (28 801). The two note-off bars (B+ piano, BI kit) were re-registered as "identical
before the start of the block that holds the note-off" (frame 26 112) and pass. The original readings are still
printed and recorded in `measure.json`.

**Departures from the item's proposal:**
- The open hat lands at beat 1 (frame 24 000), not t = 0, so the onset is never in the first render block. Every
  window is relative to that onset.
- "Kick then open hat" is read as the kick in the closed hat's slot (46 at 0, 36 at +100 ms), the only form that tests
  "a non-hat second note does not cut the open hat" through the same subtraction.
- Added rows not in the proposal: 46 then 44 (for `m39-w4-9`'s P2), our machine with no choke group, the GM piano as
  a note-off control, and a superposition check on the GM path. The superposition check is separate because the
  negative control alone cannot tell "the kick chokes" from "the sampler is not linear".
- The (b) rule gained a row after the first run ("bytes differ but the level does not": no audible effect). That row
  was added after seeing the data. It does not touch (a).
- There is no invariance control (old projects render byte-identically), because no product code changed.

## Why it chokes [R]

The bank declares it. Parsing the region headers of `gs_instruments.dls` (read-only, `$S/w8/W41/dls_keygroups.py`):
the drum instrument (program 0, the drums bit set) puts keys **42, 44 and 46 in DLS key group 1**, the "exclusive class".
(The file stores this kit at bank MSB 0 with the drums flag. 120 is the address AUSampler uses for its percussion bank:
`GMProgramCatalog.percussionBankMSB`, and `SoundBankHostingTests` T3 "percussion addressing (bankMSB 0x78)" [R].)
The toms between them (43, 45) are in group 0. The kit has seven groups: 1 {42, 44, 46}, 2 {71, 72}, 3 {73, 74},
4 {78, 79}, 5 {80, 81}, 6 {86, 87}, 7 {29, 30}. That AUSampler honours this group is an inference [I], but a tight
one: the measured choke matches the declared group exactly (42 and 44 cut 46, the kick 36 does not). Our host plays
no part: it sends only the notes (`HostedAUInstrument.swift:226-236` [R]).

## Plants (deliberate defects, each restored byte-identically with `cmp`)

Each plant was applied while holding both build slots, run with `W41_MEASURE=1`, then restored from a saved copy and
checked byte-identical with `cmp`. The restored tree was rebuilt and re-run before the slots were released (it passed
with the original numbers). Window: 08:27:50-08:29:05. Predictions were registered before the window (addendum 2).

| Plant | Predicted | Measured [M] |
|---|---|---|
| **A.** Our drum machine's choke never fires (`DrumSynthInstrument.swift:550`) | 2 issues: P+ 46->42 and P+ 46->44; verdict CANNOT TELL; GM rows unchanged | **as predicted**: tail +0.00000002 dB on both; verdict CANNOT TELL |
| **B.** Every drum-machine note-on fades every other sounding voice (`:550` and `:554`) | 2 issues: the kick-slot control and the choke-free kit | **as predicted**: both read exact zero; P+ green; verdict CANNOT TELL |
| **C.** The hosted-AU path (every sound-bank track) drops every note-off (`HostedAUInstrument.swift:231`) | 1 issue: the piano note-off control; (a) unchanged | **as predicted**: piano 0.0 dB; (a) still CHOKES; both GM short/long pairs byte-identical |

Plant C also shows two things. The GM choke is a note-on effect: it survives with no note-offs at all. And the
−102 dB note-off difference on the GM open hat comes from the note-off message itself: with note-offs dropped, the two
renders are identical.

## What this does not cover

- **Live playback timing [I].** Live playback uses the same AU, so the choke itself carries over. But the fade starts
  at the start of the audio block that holds the closed hat, and live blocks are the output device's buffer size, not
  512. At a 512-frame buffer that is at most about 10.7 ms early at 48 kHz. Here it was 2.7 ms. It was not measured
  live (no audio device in this lane).
- Only program 0 (the Standard Drum Kit). The app offers no other GM kit (`GMProgramCatalog.swift:118-122` [R]).
- Third-party SF2/DLS banks: whether AUSampler honours an SF2 `exclusiveClass` was not measured.
- Our own sampler's chopped kits: already covered by their own choke groups (design §6, C1-C3), not by this.

## Consequences

- **`m39-w4-9`: not needed.** The design's §6 outcome 1 applies ("Apple's DLS chokes natively: nothing to build,
  record the measurement"). The §12 failure-mode row "The GM kit's open hat rings under closed hats" is answered: it
  does not. (ROADMAP and design edits are the orchestrator's.)
- If anyone ever needs a choke on a bank that lacks key groups, a note-off is NOT a choke on percussion here: on this
  bank it changes the open hat by −102 dB. A real fix would need the sampler to fade the voice itself.
