# Does a sound bank expose any useful Audio Unit parameters? (item `m27-l`, measured 2026-10-07)

**Short answer: yes, 13 of them, and 4 change the sound. In this lane's reading, none is worth exposing as things stand.**
A General MIDI sound-bank track plays through Apple's AUSampler, and that unit publishes 13 parameters. Four of them
change a rendered note exactly as labelled: **Gain, Coarse Tuning, Fine Tuning and Stereo Pan**. Seven "Performance
Parameters" change nothing on a General MIDI program, and two "Output Amp" entries are read-only meters. There is **no
envelope, filter or voice-count parameter**. Gain and pan repeat the track's own volume fader and pan knob. Tuning is
the only lever a sound-bank track has no other home for. And if the refusal were lifted, whatever `au.setParam` wrote
to a sound bank would be **lost on save, on reopen and on a re-host** (measured for the re-host), because a sound
bank's saved settings are only its program and bank (LAW L3). So the refusal protects against silent data loss, not
against an empty surface.

What the refusal SAYS is wrong, though: "sound banks have no AU parameter surface" is false (13 parameters, measured).
The real reason is that the bank program is the only thing a sound-bank track saves.

Source: lane W8-M27L (audio-dsp-engineer), 2026-10-07. Tags: **[M]** measured by the lane, **[R]** read in source, SDK
header or file, **[I]** inferred. Bars were pre-registered before the first run (`$S/w8/M27L/PREDICTIONS.md`).
Evidence (scratch, wiped when idle): `$S/w8/M27L/` holds the logs (`baseline`, `probe1` (a collision in another lane's file), `probe2`, `probe3`, `plants-p1`,
`plants-p2-abort1` (first P2 window: the anchor matched 2 sites, nothing applied, released in 0 s), `plants-p2`,
`plant-*`, `after`),
`out-probe3/probe.json` (every number below), the stereo float WAVs (`piano-default.wav`, `piano-901-12.0.wav`, …) and
`STATUS.md`.

## How it was measured

- **Test:** `Tests/DAWEngineTests/SoundBankAUParamsProbeM27LTests.swift`, test "M27L: dump the AUSampler parameter
  surface on a GM program and the drum kit, and measure what each moved parameter does to a rendered note". Env-gated:
  it runs only with `M27L_PROBE=1`. Reproduce with
  `M27L_PROBE=1 M27L_OUT=<dir> ./scripts/test.sh --filter SoundBankAUParamsProbeM27L` (about 2 s once built). It
  writes `probe.json` and the WAVs to `M27L_OUT`. Headless: no audio device, no engine, no app.
- **Path [R]:** the same one every `.soundBank` track uses: a fresh `OfflineRenderer` per render,
  `prepareAudioUnits` (AUHostRegistry hosts AUSampler "aumu/samp/appl" and loads the program on the bank queue),
  `.ready` required, 48 kHz, 120 BPM, 2.5 s, one track.
- **Subjects:** melodic program 0 (Acoustic Grand Piano, bank MSB 121), C4 at velocity 100 for 1 s; the Standard Drum
  Kit (bank MSB 120, program 0), an acoustic snare (38) for 0.25 s. Both from the system `gs_instruments.dls`.
- **Two dump instruments, so they can disagree:**
  1. the v3 `parameterTree.allParameters`: exactly what `au.describeParams` reads (`AudioEngine.describeHostedAUParameters`);
  2. the raw v2 walk: `kAudioUnitProperty_ParameterList` + `ParameterInfo` on every scope (Global, Input, Output,
     Group, Part, Note, Layer, LayerItem) and element. Only this one carries a parameter's DEFAULT and full flags.
- **Moves:** every writable tree parameter, one at a time, written with `tree.parameter(withAddress:)` then
  `parameter.value =` (the `au.setParam` write path, `AudioEngine.setHostedAUParameter`) between prepare and render. Rule,
  pre-registered per unit: dB -12 and +6, semitones +12, cents +50, pan to its minimum, anything else 40 % of the way
  to its far end (0 -> 0.4 for the Performance Parameters).
- **Metrics:** level change over the onset + 1.5 s (mono and per channel); the spectral shift in cents (the best
  alignment of the two log-frequency magnitude spectra, 2-cent grid, +/- 26 semitones, with its correlation); a 24-band
  spectral shape distance (0 = same shape); the strongest partial; bit-identity with the default render.
- **Validity, asserted (a red means "cannot tell", never "does nothing"):**
  - the track reaches `.ready`;
  - two default renders are bit-identical: max |diff| = 0 on both subjects [M];
  - a velocity change moves the level metric: v50 vs v100 = -11.09 dB [M];
  - the bank really loaded: energy above 400 Hz = 0.185 (piano) and 0.396 (kit). An unloaded AUSampler plays its
    factory sine, which reads near 0 [M]; plant P1 below proves this gate can fail;
  - every moved value reads back as written BEFORE and AFTER the render (a rate renegotiation would have reset it) [M];
  - positive control, Apple's AULowpass: both dump instruments read its 2 parameters (Cutoff Frequency 10-23 760 Hz,
    default 6 900; Resonance -20-40 dB), and its cutoff moved to 200 Hz through the same `parameter.value =` path, as an
    insert on the same piano track, cuts the 2-8 kHz band by **-41.68 dB** [M]. Plant P2 below proves this gate can fail.

## The table (both programs publish the SAME 13 parameters [M])

All Global scope, element 0. The piano and the drum kit trees are identical (address, id, range) [M]. Every other scope
is empty: Input, Output, Group and Part list 0 parameters; Note, Layer and LayerItem answer OSStatus -10866 (invalid
scope) [M]. The tree address equals the parameter ID (keyPaths `global.clump_1.900` etc.) [M].

| ID | Name | Unit (range) | Default (v2) | Flags | Does it change the sound? (piano / kit) |
|---|---|---|---|---|---|
| 900 | Gain | dB (-96 to 12) | 0 | read/write, clump 1 | **YES.** -12 -> -12.00 dB on both channels, +6 -> +6.00 dB; shape 0.0000, shift 0 cents. Same on the kit. |
| 901 | Coarse Tuning | semitones (-24 to 24) | 0 | read/write, clump 1 | **YES.** +12 -> shift +1200 cents (corr 0.864), peak 261.6 -> 523.2 Hz, level -1.26 dB. Kit: +1194 cents (corr 0.994), peak 124.8 -> 248.5 Hz, -3.01 dB. |
| 902 | Fine Tuning | cents (-99 to 99) | 0 | read/write, clump 1 | **YES.** +50 -> shift +50 cents (corr 0.997), peak 261.6 -> 269.2 Hz, -0.06 dB. Kit: +50 cents (corr 0.999), -0.13 dB. |
| 903 | Stereo Pan | L/R (-100 to 100) | 0 | read/write, clump 1 | **YES.** -100 -> left +3.01 dB, right silent (constant-power hard left). Kit: left +1.42 dB, right silent (the kit's snare already sits left of centre: L -33.17, R -37.30 dBFS at default). |
| 1000-1006 | Performance Parameter 1-7 | generic (0 to 1) | 0 | read/write, clump 2 | **NO.** 0 -> 0.4 renders bit-identical to the default, on both programs, all seven. |
| 950, 951 | Output Amp 0, 1 | dB (-120 to 20) | 0 (reads -120) | READ-ONLY meter, clump 3 | Not settable (`au.setParam` refuses non-writable). They read -120 before and after an offline render [M]: useless here. |

Moved values never leak between renders: each render uses a fresh renderer, and the null pair is bit-identical [M].

### Prediction scorecard (pre-registered)
- D1/D2 (4 parameters): **MISSED.** 13, not 4. The SDK header lists only the 4 audible ones
  (`AudioUnitParameters.h:371-384` [R]). The header also gives Stereo Pan's range as -1 to 1; the live unit says -100 to
  100 [M]. Trust the live tree, never the header.
- D3: **half hit.** Nothing outside Global (hit); "Global = the same 4" missed with D1. D4 (no envelope, filter or
  voice-count parameter): **hit.** D6 (the AULowpass control publishes 2 parameters): **hit.**
- D5 (an envelope exists inside the AU's state): **hit at the structure level, see below.**
- R1-R3 and R5 (gain exact, +12 semitones = 1200 cents, +50 cents, the kit behaves alike): **hit** to the number.
  R4 (hard left: right drops >= 15 dB, total level within 3 dB): right silent (hit), total -3.01 dB (AT the edge of the
  bar, not inside it). R6 (values lost on re-host): **hit**, see Persistence.

## Persistence: everything written is lost on re-host [M], and on save/reopen [R]

- **[M]** Every writable parameter was moved, then the track's instrument was released and prepared again (a new
  AUSampler instance, checked). All 11 read back their defaults (Gain 0, Coarse 0, Fine 0, Pan 0, Performance 0), on
  both programs. **[I]** The same fresh prepare happens on reopen, and on a program change (the prepare key includes
  the bank address). A sample-rate renegotiation instead reloads the bank on the SAME instance; whether the four
  values survive that was not measured.
- **[R]** Save does not capture them either: `AUHostRegistry.prepareKey` forces `stateData: nil` for `.soundBank`
  (`AUHostRegistry.swift:764-767`, LAW L3), and save-time AU state capture runs only for `.audioUnit` instruments
  (`ProjectStore.tracksWithLiveAudioUnitState`). `SoundBankConfig` carries only source, program, bank MSB/LSB and a display name
  (`SoundBanks.swift:48-62`).
- **[M]** The loss is our policy, not Apple's: AUSampler's own `fullState` changes when any of them moves (state bytes
  differ in every move above), and has top-level keys `gain`, `coarse tune`, `fine tune`, `pan` and `voice count`.

## A per-patch envelope and filter DO exist, inside the AU's state (not as parameters)

The research (`docs/research/spike-wind-instrument-realism.md` §3.3) says no per-patch envelope or filter exists to
expose on a `.soundBank` track. That stays true for our model and for the AU parameter surface. But after a DLS program
loads, AUSampler's `fullState` holds a full instrument description [M]:
- piano: 1 layer, 10 zones, 2 envelopes, 1 filter, 2 LFOs, 11 connections; `voice count` = 64;
- drum kit: 45 layers, 61 zones, 90 envelopes, 45 filters, 90 LFOs, 441 connections; `voice count` = 64;
- key names include `Envelopes`, `Stages`, `Filters`, `cutoff`, `resonance`, `LFOs`, `Connections`, `voice count`;
- the piano's first filter is **switched off**: `{ID = 0; cutoff = 20000; enabled = 0; resonance = -3}`.

**[I]** So the General MIDI patch's envelope lives there and could in principle be edited by rewriting that state. That
is a different feature from `au.setParam`, and **this lane did NOT measure whether such an edit changes the sound**.
Rewriting it also reloads the instrument (a bank-queue operation under the m18-d law). OWED as its own probe if anyone
wants per-patch shaping on General MIDI tracks.

## Recommendation (the orchestrator's call; options, not a verdict)

1. **Keep the refusal; fix its words (recommended, small).** Nothing behind it is worth exposing as it stands: gain and
   pan repeat the track fader and pan, the Performance Parameters do nothing on a General MIDI program, the meters are
   read-only, and every write would be silently lost on save, reopen or re-host. But the teaching sentence in
   `ProjectStore.resolveHostedAUTarget` (~:4126 at 09:35 today; shared file, it moves) ("sound banks have no AU parameter surface") is false and could mislead an agent. A truer
   sentence, for example: "sound-bank tracks keep only their program and bank, so Audio Unit parameters set here would be
   lost when you save; choose a program with instrument.listSoundBankPrograms and track.setInstrument, use the track's
   volume and pan for level and placement". That is a `Sources/` change for another lane, and the reply string is wire
   text, so check the pins that capture it first.
2. **If General MIDI tuning is wanted: add it to the model, not to `au.setParam`.** Coarse (+/- 24 semitones) and fine
   (+/- 99 cents) tuning work exactly (+1200 and +50 cents measured, both programs), and a sound-bank track has no other
   tuning lever (`.sampler` zones have `tuneCents`, `Model.swift:2670`; `SoundBankConfig` has none). The safe shape: new
   optional `SoundBankConfig` fields, applied to parameters 901/902 at prepare (so reopen and re-host keep them), exposed
   through `track.setInstrument`. Design work plus `Sources/` work; additive on the wire. Note that coarse tuning also
   changes the level (-1.26 dB piano, -3.01 dB kit at +12) because the sampler plays a different sample stretch [M].
3. **Lift the refusal for 900-903 through `au.setParam` as-is: not recommended.** It would hand agents four parameters
   that work until the project is saved, then vanish without a word. That is the "returns something that looks like a
   valid answer" failure this tree keeps paying for.

## Plants (each gate shown able to fail)

Each plant was applied with both build slots held, run with `M27L_PROBE=1` (so the test ran, never skipped), restored
and checked byte-identical with `cmp`, then rebuilt and re-run green [M].
- **P1, the bank is never loaded** (`AUHostRegistry.setLoadInstrumentProperty` returns success without writing
  `LoadInstrument`): the test went RED at the bank-loaded gate only, on both programs: energy above 400 Hz read 0.0000
  (piano) and 0.0001 (kit), the factory sine. Status was still `.ready`, so without this gate the probe would have
  reported a sine's parameters as the General MIDI patch's. Restored: green again, 0.1853 / 0.3961.
- **P2, the hosted insert never reaches the render** (the offline graph's `hostedEffectProvider` returns nil, so the
  passthrough placeholder runs): the test went RED at the set-path control only: 2-8 kHz change 0.00 dB with the
  cutoff read back at 200 Hz. A tree write that reads back fine is not proof it reached the sound; this gate is.
  Restored: green again, -41.68 dB.

## Limits
- One melodic program and one kit. The tree did not change between them, which suggests it is program-independent [I];
  the per-program state (zones, envelopes) does change [M].
- The Performance Parameters were moved to one value (0.4). A connection that only reacts above 0.4 would be missed
  [I]; none of the 11 (piano) or 441 (kit) connections is known to read them.
- Offline render only (`renderingOffline` set by the registry). Live playback uses the same unit and parameters [I].
- The probe reads the same `parameterTree` that `au.describeParams` reads and writes through the same
  `parameter.value =`, but it does not call `AudioEngine.describeHostedAUParameters` / `setHostedAUParameter` or the
  wire (no engine runs headless here). The wire path itself was not exercised; the tree it reads was.
- Not measured: whether 900-903 survive a sample-rate renegotiation (bank reload on the same instance), and whether
  editing the `fullState` envelope or filter changes the sound.
