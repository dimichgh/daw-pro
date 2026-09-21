import Foundation

/// One insert effect in a track/bus chain (M4 ii). Chain order = array order
/// in `Track.effects`. Per-kind param structs are additive optionals carried
/// regardless of kind (the InstrumentDescriptor rule) so kind switches and
/// forward-compat decode round-trip cleanly; `nil` reads as defaults.
public struct EffectDescriptor: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Gain/trim — the M4 (ii) seam-proving effect. M4 (v) adds audioUnit.
        case gain
        /// Parametric EQ: low shelf, 2× peaking, high shelf — M4 (iii) —
        /// plus optional HP/LP filters, shelf Q, per-band bypass (m22-a).
        case eq
        /// Soft-knee downward compressor, stereo-linked — M4 (iii).
        case compressor
        /// Lookahead brickwall limiter (fixed 5 ms lookahead) — M4 (iii).
        case limiter
        /// Freeverb-topology algorithmic reverb — M4 (iv).
        case reverb
        /// Stereo delay with filtered feedback + optional ping-pong — M4 (iv).
        case delay
        /// tanh drive/waveshaper — M4 (iv); optional 2×/4× oversampling added
        /// by m39-ad. ⛔ NOT `.clipper`: tanh only ever APPROACHES its bound, so
        /// this kind can never promise a peak ceiling. ⚠️ `oversampling`
        /// DEFAULTS TO 1 (off) because this kind shipped without it — see
        /// `SaturatorParams`.
        case saturator
        /// Downward noise gate with attack/hold/release — M4 (iv).
        case gate
        /// 2-voice modulated-delay chorus — M4 (iv).
        case chorus
        /// Psychoacoustic bass harmonic enhancer (m23-p1): synthesizes the
        /// 2nd/3rd/4th partials OF the sub-crossover content and injects them
        /// above the crossover, so a speaker that cannot reproduce the
        /// fundamental still implies it (the "missing fundamental" effect).
        /// NOT the broadband `saturator` — the shaper only ever sees the
        /// low band, and its output is high-passed at the same corner.
        case bassEnhancer
        /// Bit-depth reduction + sample-rate reduction, the SP-1200 / MPC60
        /// lo-fi sampler character (m32-e). Defaults to 12 bits at 26.04 kHz
        /// with NO anti-alias filtering and NO dither, because the aliasing
        /// and the raw quantization noise ARE the reference sound.
        case bitCrusher
        /// Single-knob bipolar resonant multimode filter (m39-i) — the club /
        /// DJ-mixer sweep. ONE knob: `position` 0 is a bit-exact dry centre,
        /// negative sweeps a LOW-pass downward (the treble leaves first),
        /// positive sweeps a HIGH-pass upward (the bass leaves first).
        /// Deliberately NOT an `EQParams` extension: the EQ's filters are
        /// Butterworth with no Q, and the resonance IS this effect's identity.
        case djFilter
        /// Ring modulator (m39-m): the input multiplied by a band-limited
        /// carrier oscillator. The classic metallic / bell / sci-fi-voice
        /// sound, and the item the user's "frequency modulation" named
        /// (`docs/design/2026-09-19-creative-effects.md` §6.4). A carrier
        /// under ~20 Hz is a tremolo; above it the output is a pair of
        /// SIDEBANDS at `|f - carrier|` and `f + carrier` for every input
        /// partial `f`, which is why it sounds inharmonic rather than filtered.
        case ringMod
        /// Feedback flanger (m39-j): ONE interpolated delay tap per channel,
        /// swept UPWARD from a floor by an LFO, with BIPOLAR feedback
        /// (`docs/design/2026-09-19-creative-effects.md` §6.3). The jet-plane
        /// whoosh. Distinct from `chorus`, which is two taps around a fixed
        /// 15 ms centre with NO feedback: the long centre delay makes the
        /// chorus's comb too dense to hear as a comb (it reads as detuning),
        /// while the flanger's 0.1–20 ms sweep puts only a handful of notches
        /// in the audible band and recirculation sharpens the peaks between
        /// them into resonances.
        case flanger
        /// 8-line Feedback Delay Network with Householder mixing, per-line
        /// two-band absorption and a small independently-phased length
        /// modulation (m39-l,
        /// `docs/design/2026-09-19-creative-effects.md` §5/§6.2).
        ///
        /// ⛔ THIS IS A SECOND REVERB KIND, NOT A REPLACEMENT — `.reverb` is
        /// untouched and is NOT deprecated. The difference that justifies the
        /// second kind, in one line: **this one has a SIZE.** `.reverb`'s
        /// `roomSize` scales comb FEEDBACK and its comb lengths are
        /// compile-time constants, so its room has exactly one shape forever;
        /// here `sizeMeters` scales the actual line lengths. Freeverb's small,
        /// bright, dense room remains a genuinely good sound that this hall
        /// does not replicate, which is why both ship.
        case hallReverb
        /// Tape echo (m39-n), FREE-MS ONLY: a FRACTIONAL delay line whose read
        /// position is pushed around by wow (slow motor drift) and flutter
        /// (fast capstan instability), with the repeat path saturated and
        /// rolled off so every pass through the machine is duller and more
        /// compressed than the one before.
        ///
        /// ⛔ THIS IS NOT A REPLACEMENT FOR `.delay`, and the reason is
        /// STRUCTURAL, not stylistic (verified in the m39 plugin inventory,
        /// §"DelayEffect is integer-sample-only"): `.delay` holds its delay in
        /// an `Int` and reads `line[index - delaySamples]`, so the fractional
        /// part of every requested time is discarded at assignment and the
        /// read position can only move in whole samples. A wow of a tenth of a
        /// sample is not a tuning problem there, it is unrepresentable. This
        /// kind reads an interpolated tap (`InterpolatedDelayLine`,
        /// `docs/design/2026-09-19-creative-effects.md` §4.1) and can.
        ///
        /// ⛔ NO TEMPO SYNC IN v1, DELIBERATELY. The sync resolver is
        /// hardwired to `.delay` at five intake seams and generalising it is
        /// m39-c; a second hand-rolled resolver is the FROZEN PROHIBITION of
        /// design §8.3. Synced mode is an append, after m39-c and m39-d.
        case tapeDelay
        /// Mid/side stereo widener and mono-maker (m23-dj) — width on the
        /// EXISTING stereo difference, plus true pseudo-stereo synthesized
        /// from a decorrelated side channel, with the bass kept mono.
        ///
        /// ⛔ THIS IS NOT A HAAS WIDENER AND THAT IS THE WHOLE POINT. The two
        /// cheap tricks — delaying one side by 5-30 ms, or adding a
        /// polarity-flipped duplicate — widen on speakers and COLLAPSE OR
        /// HOLLOW OUT IN MONO, which is the failure a club PA or a phone
        /// speaker exposes. Everything this kind does happens to the SIDE
        /// channel only; the MID is passed through untouched, so the mono sum
        /// `L + R = 2·M` is arithmetically the dry mono sum at every setting.
        /// Mono compatibility here is a STRUCTURAL PROPERTY, not a tuning.
        ///
        /// ⚠️ THE TRADE THIS BUYS, STATED RATHER THAN HIDDEN. You cannot have
        /// both a flat mono sum and flat individual channels out of a mono
        /// source: with `L = M·(1 + s·A)` and `R = M·(1 - s·A)` for an
        /// all-pass `A`, the sum is exactly flat and each channel carries a
        /// complementary ripple of `1 ± s` (`channelPeakDb` /
        /// `channelNotchDb`). The other arrangement — a different all-pass per
        /// channel — gives flat channels and a COMBED sum, which is the bug
        /// this item exists to refuse. `spread` is the control that costs the
        /// ripple; `width` costs nothing on material that is already stereo.
        case stereoWidth
        /// Swept all-pass phaser (m39-o) — a cascade of FIRST-ORDER ALL-PASS
        /// sections sharing one corner frequency, summed with the dry signal,
        /// with bipolar feedback around the chain.
        ///
        /// ⛔ **A PHASER IS NOT A FLANGER, AND THE DIFFERENCE IS MEASURABLE,
        /// NOT A MATTER OF TASTE.** A flanger sums the signal with a DELAYED
        /// copy of itself; that delay cancels at every odd multiple of
        /// `1/(2·delay)`, so a flanger's notches are a HARMONIC comb — dozens
        /// of them, at 1:3:5:7:9… — and sweeping the delay slides the whole
        /// comb rigidly. This kind has no delay line at all. It sums the
        /// signal with a PHASE-SHIFTED copy, and cancellation happens only
        /// where the all-pass chain's total phase reaches an odd multiple of
        /// 180°. An N-stage chain sweeps 0° → N·180°, so it produces exactly
        /// **N/2 notches** — a handful, not a comb — and they sit at
        /// `PhaserParams.notchRatio(stages:index:)` times the corner, which is
        /// a NON-HARMONIC series (for 8 stages: 1 : 3.36 : 7.52 : 25.3, where
        /// a flanger would be 1 : 3 : 5 : 7). Fewer notches, unevenly spaced,
        /// is why a phaser sounds like a soft vocal "whoosh" where a flanger
        /// sounds like a jet plane. `PhaserTests` measures both series from
        /// rendered audio and cross-checks each law against the OTHER effect.
        ///
        /// ⛔ **THE SWEEP IS UPWARD-ONLY IN LOG FREQUENCY** — the §6.3.2
        /// principle moved into the domain this kind actually sweeps:
        /// `corner = centerHz · 2^(depthOctaves · (0.5 + 0.5·sin φ))`. A
        /// bipolar sweep would dive below `centerHz` and, at large depths,
        /// under the audible band; multiplying upward from a floor keeps the
        /// corner in `[centerHz, centerHz·2^depthOctaves]` with no clamp and
        /// no render-thread branch. ⭐ The ranges are chosen so the TOP of
        /// that interval (16 kHz) is below `0.45·sampleRate` at every rate
        /// this app runs at, so the `tan()` guard that would flatten the sweep
        /// top never engages — `PhaserParams.maxCornerHz` pins it.
        case phaser
        /// Transient shaper (m39-y) — changes how HARD a sound starts and how
        /// LONG it rings, and NOTHING in between. A gain-only insert driven by
        /// a three-envelope differential follower in the LINEAR amplitude
        /// domain whose differentials are taken as dB RATIOS, which is what
        /// makes it level-independent: it compares the signal to ITSELF, so
        /// turning the fader down does not turn the effect down.
        /// ⛔ NOT a compressor — no threshold, deliberately (see
        /// `TransientShaperParams`). Zero lookahead, `latencySamples == 0`, so
        /// it adds no new latency source to the insert PDC measured at m25-n.
        case transientShaper
        /// Frequency shifter (m39-z) — moves every partial by the same number
        /// of **Hz**, which is NOT what a pitch shifter does. A pitch shifter
        /// multiplies every partial by the same RATIO and so preserves the
        /// harmonic series; this ADDS a constant, so 100/200/300 Hz becomes
        /// 200/300/400 Hz — no longer a harmonic series at all. That
        /// INHARMONICITY is the effect: metallic, bell-like, clangorous at
        /// large shifts, and a slow beating chorus at ±1–20 Hz.
        /// ⛔ NOT a ring modulator either: a ring mod is DOUBLE-sideband (it
        /// emits both sum AND difference and the input vanishes), while this is
        /// SINGLE-sideband — one sideband only, the other rejected by
        /// `FreqShifterParams.sidebandRejectionDb`. `.ringMod` is the other
        /// kind and they are not substitutes.
        case freqShifter
        /// Clipper (m39-ac) — the first caller of the shared `Oversampler`
        /// primitive. A hard ceiling: everything above `ceilingDb` is CUT OFF,
        /// which is how loud modern masters and hard-hitting drums are made.
        /// ⛔ NOT `.saturator`, and the difference is exact rather than a
        /// matter of degree: tanh only ever APPROACHES its bound, so a
        /// saturator has no ceiling a peak can be guaranteed to sit under.
        /// Both of this kind's modes reach `ceilingDb` at a FINITE input and
        /// stay there — `hard` immediately, `soft` at 1.5× the ceiling through
        /// a cubic knee — so the output really is bounded.
        /// ⛔ NOT `.limiter` either: a limiter RIDES A GAIN to avoid clipping
        /// and keeps the waveform's shape; this one changes the waveform on
        /// purpose, which is where the loudness and the bite come from.
        /// ⭐ The thing that makes it worth building is `oversampling`: hard
        /// clipping generates harmonics far above Nyquist that FOLD BACK as
        /// inharmonic noise, and running the shaper at 2× or 4× moves the fold
        /// out of the audio band. `oversampling: 1` is kept as a user-visible
        /// setting precisely so that difference can be heard, and it is what
        /// `scripts/gates/m39ac-clipper-physics.mjs` measures.
        case clipper
        /// Dynamic EQ (m39-af) — FOUR identical bell bands in series, each one a
        /// single side-path biquad whose gain is driven by that band's OWN
        /// filtered level. `docs/design/2026-09-20-dynamic-eq.md` is the
        /// settled design and the source of truth for the algorithm.
        ///
        /// ⛔ **NOT `.eq`, and the difference is the POLES.** Each band here is
        /// written in the side-path (Regalia–Mitra) form
        /// `H(z) = 1 + (G − 1)·BP(z)`, where `BP` is the constant-0-dB-PEAK
        /// band-pass (`EQFilterResponse.bandPassSection`). Expanded, that is
        /// `[(1 + Gα) − 2cos(ω₀)z⁻¹ + (1 − Gα)z⁻²] / [(1 + α) − 2cos(ω₀)z⁻¹ +
        /// (1 − α)z⁻²]` — **the denominator does not contain G**, so the poles
        /// are fixed by `(freq, Q, sampleRate)` alone and the gain can move at
        /// AUDIO RATE without recomputing one coefficient. `.eq`'s RBJ peaking
        /// sections have `1 ± α/A` in the denominator: their poles move with
        /// gain, which is exactly why they cannot be made dynamic without a
        /// control-stride decision. DO NOT "fix" this into RBJ.
        ///
        /// ⚠️ **THE PRICE OF THAT, STATED RATHER THAN HIDDEN: `Q` DOES NOT MEAN
        /// THE SAME THING HERE AS IT DOES ON `.eq`.** An RBJ peaking band's
        /// half-gain bandwidth is CONSTANT with gain (**498.4 Hz** at 1 kHz /
        /// Q 2 / 48 kHz, at +3, +6, +12 AND +18 dB). A side-path bell's WIDENS
        /// with gain (**592.3 / 703.8 / 993.4 / 1401.2 Hz** at those same
        /// gains). Both reach exactly the requested gain at the centre.
        /// `DynamicEQResponseTests` re-derives both series from
        /// `EQFilterResponse` and pins them.
        ///
        /// ⚠️ Those six figures are MEASURED HERE, by two independent methods
        /// (bisection and a 0.01 Hz grid scan, agreeing to 0.01 Hz), and they
        /// are NOT the figures in `docs/design/2026-09-20-dynamic-eq.md` §0,
        /// which reads 499.3 / 592.5 / 705.1 / 994.4 / 1402.2. The design's
        /// numbers are high by 0.2-1.4 Hz — a grid-resolution artefact in the
        /// spike's scratch script, not a difference in the filter: its peak-gain
        /// figure (4.63e-14 dB) reproduces here to fifteen digits, so both
        /// computed the same section. The design's conclusion is untouched; only
        /// its last digit was.
        ///
        /// ⚠️ **THE BANDS ARE IN SERIES, so band 3's detector hears what bands 1
        /// and 2 already did to the signal.** That is standard and arguably
        /// right — band 3 should react to the signal as it now is — but it looks
        /// like a bug from the outside, so it is written down here. Series also
        /// makes two overlapping bands compose as a PRODUCT (dB-additive, what
        /// an EQ curve display and every user's intuition assume) where a
        /// parallel sum would overshoot.
        ///
        /// ⛔ **BELLS ONLY IN v1, AND THE REASON IS A MEASUREMENT, NOT TASTE.**
        /// The obvious side-path shelf — `1 + (G − 1)·LP` on a 2nd-order
        /// Butterworth low-pass — **BOOSTS BY +0.82 dB AT THE CORNER WHEN ASKED
        /// FOR A 9 dB CUT.** That is a defect. A first-order section is clean
        /// but has no Q, is 6 dB/oct only, and is not boost/cut symmetric, so it
        /// would need a different param block and break the uniform
        /// `slot = (band−1)·8 + p` arithmetic. A wide bell (Q ≈ 0.5–0.7) at
        /// 8 kHz is the serviceable stand-in for a dynamic high shelf.
        ///
        /// ⭐ **`latencySamples` IS A LITERAL 0 AT EVERY SETTING OF EVERY
        /// PARAM** — minimum-phase IIR, no delay line, no lookahead. (A bell has
        /// frequency-dependent GROUP delay; that is not reportable latency and
        /// PDC neither can nor should compensate it. `.eq` has the same property
        /// and reports 0 too.) That is why `Automation.swift` has **no entry**
        /// for this kind: the saturator's refusal is about PARAMETER-DEPENDENT
        /// LATENCY, and the reason does not exist here. All 32 slots take lanes.
        ///
        /// ⚠️ **NO GAIN-REDUCTION METER IN v1, DELIBERATELY.** Four bands have
        /// four movements; `GainReductionReporting` publishes ONE number into a
        /// meter the mixer draws as a compressor's, so a max-of-bands would be
        /// confidently wrong about WHICH band moved. Absent beats wrong. Agents
        /// can watch a band move with `fx.spectrum`.
        case dynamicEQ
        /// A hosted Audio Unit effect ('aufx', see `audioUnit`) — M4 (v).
        case audioUnit
    }

    public let id: UUID
    public var kind: Kind
    public var isBypassed: Bool
    public var gain: GainParams?
    public var eq: EQParams?
    public var compressor: CompressorParams?
    public var limiter: LimiterParams?
    public var reverb: ReverbParams?
    public var delay: DelayParams?
    public var saturator: SaturatorParams?
    public var gate: GateParams?
    public var chorus: ChorusParams?
    public var bassEnhancer: BassEnhancerParams?
    public var bitCrusher: BitCrusherParams?
    public var djFilter: DJFilterParams?
    public var ringMod: RingModParams?
    public var flanger: FlangerParams?
    public var hallReverb: HallReverbParams?
    public var tapeDelay: TapeDelayParams?
    public var stereoWidth: StereoWidthParams?
    public var phaser: PhaserParams?
    public var transientShaper: TransientShaperParams?
    public var freqShifter: FreqShifterParams?
    public var clipper: ClipperParams?
    public var dynamicEQ: DynamicEQParams?
    /// Hosted Audio Unit selection (additive optional, reusing the instrument
    /// `AudioUnitConfig`: component triple + display names + saved
    /// `fullStateForDocument`). Unlike the instrument rule, `kind ==
    /// .audioUnit && audioUnit == nil` is INVALID at the store boundary
    /// (`ProjectStore.addEffect` rejects it) — an insert with no component
    /// would be a permanent silent passthrough.
    public var audioUnit: AudioUnitConfig?
    /// Sidechain key source (m12-f, design-m11f-sidechain §7): the track
    /// whose post-fader output this effect's detector listens to instead of
    /// the strip's own signal. nil = self-keyed (all pre-sidechain behavior,
    /// bit-exact). Additive optional with synthesized Codable, so it is
    /// OMITTED when nil — legacy projects stay byte-identical on disk (the
    /// `startOffsetSeconds` omission precedent). Validity (compressor/gate
    /// kinds only, non-bus source, audio/bus destination strip, no cycles,
    /// one per strip) is enforced at `ProjectStore.setSidechain`.
    public var sidechainSourceTrackID: UUID?

    public var resolvedGain: GainParams { gain ?? GainParams() }
    public var resolvedEQ: EQParams { eq ?? EQParams() }
    public var resolvedCompressor: CompressorParams { compressor ?? CompressorParams() }
    public var resolvedLimiter: LimiterParams { limiter ?? LimiterParams() }
    public var resolvedReverb: ReverbParams { reverb ?? ReverbParams() }
    public var resolvedDelay: DelayParams { delay ?? DelayParams() }
    public var resolvedSaturator: SaturatorParams { saturator ?? SaturatorParams() }
    public var resolvedGate: GateParams { gate ?? GateParams() }
    public var resolvedChorus: ChorusParams { chorus ?? ChorusParams() }
    public var resolvedBassEnhancer: BassEnhancerParams { bassEnhancer ?? BassEnhancerParams() }
    public var resolvedBitCrusher: BitCrusherParams { bitCrusher ?? BitCrusherParams() }
    public var resolvedDJFilter: DJFilterParams { djFilter ?? DJFilterParams() }
    public var resolvedRingMod: RingModParams { ringMod ?? RingModParams() }
    public var resolvedFlanger: FlangerParams { flanger ?? FlangerParams() }
    public var resolvedHallReverb: HallReverbParams { hallReverb ?? HallReverbParams() }
    public var resolvedTapeDelay: TapeDelayParams { tapeDelay ?? TapeDelayParams() }
    public var resolvedStereoWidth: StereoWidthParams { stereoWidth ?? StereoWidthParams() }
    public var resolvedPhaser: PhaserParams { phaser ?? PhaserParams() }
    public var resolvedTransientShaper: TransientShaperParams {
        transientShaper ?? TransientShaperParams()
    }
    public var resolvedFreqShifter: FreqShifterParams { freqShifter ?? FreqShifterParams() }
    public var resolvedClipper: ClipperParams { clipper ?? ClipperParams() }
    public var resolvedDynamicEQ: DynamicEQParams { dynamicEQ ?? DynamicEQParams() }

    public init(
        id: UUID = UUID(),
        kind: Kind,
        isBypassed: Bool = false,
        gain: GainParams? = nil,
        eq: EQParams? = nil,
        compressor: CompressorParams? = nil,
        limiter: LimiterParams? = nil,
        reverb: ReverbParams? = nil,
        delay: DelayParams? = nil,
        saturator: SaturatorParams? = nil,
        gate: GateParams? = nil,
        chorus: ChorusParams? = nil,
        bassEnhancer: BassEnhancerParams? = nil,
        bitCrusher: BitCrusherParams? = nil,
        djFilter: DJFilterParams? = nil,
        ringMod: RingModParams? = nil,
        flanger: FlangerParams? = nil,
        hallReverb: HallReverbParams? = nil,
        tapeDelay: TapeDelayParams? = nil,
        stereoWidth: StereoWidthParams? = nil,
        phaser: PhaserParams? = nil,
        transientShaper: TransientShaperParams? = nil,
        freqShifter: FreqShifterParams? = nil,
        clipper: ClipperParams? = nil,
        dynamicEQ: DynamicEQParams? = nil,
        audioUnit: AudioUnitConfig? = nil,
        sidechainSourceTrackID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.isBypassed = isBypassed
        self.gain = gain
        self.eq = eq
        self.compressor = compressor
        self.limiter = limiter
        self.reverb = reverb
        self.delay = delay
        self.saturator = saturator
        self.gate = gate
        self.chorus = chorus
        self.bassEnhancer = bassEnhancer
        self.bitCrusher = bitCrusher
        self.djFilter = djFilter
        self.ringMod = ringMod
        self.flanger = flanger
        self.hallReverb = hallReverb
        self.tapeDelay = tapeDelay
        self.stereoWidth = stereoWidth
        self.phaser = phaser
        self.transientShaper = transientShaper
        self.freqShifter = freqShifter
        self.clipper = clipper
        self.dynamicEQ = dynamicEQ
        self.audioUnit = audioUnit
        self.sidechainSourceTrackID = sidechainSourceTrackID
    }
}

/// Parameters for the built-in gain/trim effect. Clamped on init so a
/// descriptor is always renderable as-is (PolySynthParams pattern).
public struct GainParams: Codable, Sendable, Equatable {
    /// Linear gain, 0...16 (1 = unity, up to +24.08 dB).
    public var gainLinear: Double

    /// m27-c: RAISED 4 (+12.04 dB) → 16 (+24.08 dB). The old ceiling could
    /// not lift General-MIDI-sourced material to a streaming level in ONE
    /// stage, so reaching −14 LUFS took two chained gain inserts — a
    /// workaround the reporter correctly read as one.
    ///
    /// MEASURED (headless `OfflineRenderer`, 48 kHz, 10 s, GM system bank,
    /// BS.1770-4 gated integrated — scratchpad `m27c-gm-levels.txt`):
    ///  · full 4-track GM arrangement  −18.14 LUFS → needs  +4.14 dB
    ///  · solo GM piano v100           −28.35 LUFS → needs +14.35 dB
    ///    (independently reproduces the reported −28.05 / +14.88 anchor)
    ///  · solo GM piano v64            −35.49 LUFS → needs +21.49 dB  ← worst
    /// A ceiling of 8 (+18.06 dB) is 3.43 dB SHORT of that last, entirely
    /// ordinary case; 16 (+24.08 dB) covers it with 2.59 dB spare. Values
    /// beyond that belong to material that should be re-authored louder,
    /// and chaining a second insert is still available.
    ///
    /// RAISING is safe for existing projects: every stored value was already
    /// ≤ 4 and stays in range, so no saved gain moves and no automation point
    /// re-clamps (`AutomationTarget.valueRange` resolves from this same spec).
    /// LOWERING would not be — it would silently re-clamp stored values on
    /// load, through this very init.
    ///
    /// The ceiling is REAL headroom, not free headroom: the gain stage is a
    /// memoryless multiply with no protection of its own, so a hot source
    /// pushed hard here will clip unless something downstream (a limiter, or
    /// the bounce's own true-peak ceiling) holds it. That tradeoff is stated
    /// in the `fx.describe` note and in the MCP tool description.
    public static let gainRange: ClosedRange<Double> = 0...16

    /// Polarity (phase) invert — the Ø button every hardware channel strip
    /// has, and the one thing `gainRange` deliberately cannot express.
    ///
    /// WHY A BOOLEAN AND NOT A SIGNED RANGE (m38-a): widening `gainRange` to
    /// -16...16 would make 0 an awkward midpoint of a control whose 0 already
    /// means silence, and would fuse "turn it down" and "flip it" into one
    /// knob. A switch is what the hardware does, what the user already
    /// understands, and what reads correctly as a toggle in the editor.
    ///
    /// `true` multiplies by -1 AFTER `gainLinear` — i.e. the render side folds
    /// the sign into the SAME smoothed coefficient the gain uses, so a live
    /// flip ramps +g → -g through zero over ~5 ms (a brief dip) instead of
    /// stepping full-scale (a click). See `GainEffect.signedTarget`.
    ///
    /// `false` is bit-exact with every pre-m38-a render: the coefficient is
    /// literally the same Float, including the unity-skip fast path.
    public var invertPolarity: Bool

    public init(gainLinear: Double = 1, invertPolarity: Bool = false) {
        self.gainLinear = gainLinear.clamped(to: Self.gainRange)
        self.invertPolarity = invertPolarity
    }

    private enum CodingKeys: String, CodingKey { case gainLinear, invertPolarity }

    /// Decoding routes through the clamping init. `invertPolarity` is ABSENT
    /// from every project saved before m38-a and MUST decode to `false`, so an
    /// existing session renders identically — the control is opt-in and
    /// nothing on disk changes meaning (the `LimiterParams.truePeak`
    /// precedent). The schema change is additive in both directions.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            gainLinear: try c.decodeIfPresent(Double.self, forKey: .gainLinear) ?? 1,
            invertPolarity: try c.decodeIfPresent(Bool.self, forKey: .invertPolarity) ?? false)
    }
}

/// Parameters for the built-in parametric EQ: optional high-pass, low shelf,
/// two peaking bands, high shelf, optional low-pass, in series (M4 iii; HP/LP,
/// shelf Q, and per-band bypass are the m22-a EQ v2 additions). FLAT param
/// names — each field is one entry on the generic name/value surface
/// (`EffectParamSpec`). Clamped on init so a descriptor is always renderable
/// as-is (GainParams pattern).
/// A band whose gain is exactly 0 dB is truly neutral (the engine skips it).
///
/// EVERY v2 field is an additive optional with synthesized encoding, so nil is
/// OMITTED on disk (the `sidechainSourceTrackID` precedent) and legacy
/// projects decode/encode byte-compatible. The nil semantics, shared by every
/// surface through the `resolved*` accessors:
///  · `highPassFreq`/`lowPassFreq` nil = that filter is OFF (the pre-m22-a
///    behavior); setting a frequency turns it on.
///  · `highPassSlopeDbPerOct`/`lowPassSlopeDbPerOct` nil = 12; only 12 or 24
///    are valid (the init snaps to the nearer).
///  · `lowShelfQ`/`highShelfQ` nil = the legacy fixed-slope shelf (RBJ S = 1,
///    an effective Q of 1/√2 ≈ 0.707 — see `defaultShelfQ`).
///  · `*Enabled` nil = true; false bypasses JUST that band, exactly as if it
///    were absent (a true no-op, not gain 0).
public struct EQParams: Codable, Sendable, Equatable {
    public var lowShelfFreq: Double
    public var lowShelfGainDb: Double
    public var peak1Freq: Double
    public var peak1GainDb: Double
    public var peak1Q: Double
    public var peak2Freq: Double
    public var peak2GainDb: Double
    public var peak2Q: Double
    public var highShelfFreq: Double
    public var highShelfGainDb: Double
    // MARK: v2 additive optionals (m22-a) — nil = pre-m22-a behavior exactly.
    /// High-pass corner (Hz). nil = high-pass OFF.
    public var highPassFreq: Double?
    /// High-pass steepness: 12 or 24 dB/oct. nil = 12.
    public var highPassSlopeDbPerOct: Int?
    /// nil = true. false bypasses the high-pass, keeping its settings.
    public var highPassEnabled: Bool?
    /// Low-pass corner (Hz). nil = low-pass OFF.
    public var lowPassFreq: Double?
    /// Low-pass steepness: 12 or 24 dB/oct. nil = 12.
    public var lowPassSlopeDbPerOct: Int?
    /// nil = true. false bypasses the low-pass, keeping its settings.
    public var lowPassEnabled: Bool?
    /// Low-shelf resonance. nil = the legacy S = 1 shelf (Q 1/√2 ≈ 0.707).
    public var lowShelfQ: Double?
    /// High-shelf resonance. nil = the legacy S = 1 shelf (Q 1/√2 ≈ 0.707).
    public var highShelfQ: Double?
    /// Per-band bypass, nil = true (band active).
    public var lowShelfEnabled: Bool?
    public var peak1Enabled: Bool?
    public var peak2Enabled: Bool?
    public var highShelfEnabled: Bool?

    public static let lowShelfFreqRange: ClosedRange<Double> = 20...2_000
    public static let peakFreqRange: ClosedRange<Double> = 20...20_000
    public static let highShelfFreqRange: ClosedRange<Double> = 200...20_000
    public static let gainDbRange: ClosedRange<Double> = -24...24
    public static let qRange: ClosedRange<Double> = 0.1...18
    public static let highPassFreqRange: ClosedRange<Double> = 20...1_000
    public static let lowPassFreqRange: ClosedRange<Double> = 1_000...20_000
    /// The generic-surface span for the slope params; real values snap to
    /// exactly 12 or 24 (`Self.snapSlope`).
    public static let slopeRange: ClosedRange<Double> = 12...24
    /// The effective Q of a nil-Q shelf: the RBJ "slope S = 1" shelf the EQ
    /// has always used is algebraically alpha = sinW0/(2·Q) at Q = 1/√2.
    public static let defaultShelfQ: Double = 0.7071067811865476
    /// Snaps any requested slope to the nearer legal value (12 below 18, else
    /// 24) — the DelayParams.pingPong rounding precedent for the numeric wire.
    public static func snapSlope(_ value: Double) -> Int { value < 18 ? 12 : 24 }

    // MARK: Resolved v2 reads — the single home of the nil semantics, shared
    // by the engine, the wire's resolved params object, and the editor model.

    /// True when the high-pass filter actually runs: a corner is set AND the
    /// band is not bypassed.
    public var resolvedHighPassEnabled: Bool { highPassFreq != nil && (highPassEnabled ?? true) }
    public var resolvedLowPassEnabled: Bool { lowPassFreq != nil && (lowPassEnabled ?? true) }
    /// The corner a control surface shows while the filter is off (range edge
    /// = "out of the way").
    public var resolvedHighPassFreq: Double { highPassFreq ?? Self.highPassFreqRange.lowerBound }
    public var resolvedLowPassFreq: Double { lowPassFreq ?? Self.lowPassFreqRange.upperBound }
    public var resolvedHighPassSlope: Int { highPassSlopeDbPerOct ?? 12 }
    public var resolvedLowPassSlope: Int { lowPassSlopeDbPerOct ?? 12 }
    public var resolvedLowShelfQ: Double { lowShelfQ ?? Self.defaultShelfQ }
    public var resolvedHighShelfQ: Double { highShelfQ ?? Self.defaultShelfQ }
    public var resolvedLowShelfEnabled: Bool { lowShelfEnabled ?? true }
    public var resolvedPeak1Enabled: Bool { peak1Enabled ?? true }
    public var resolvedPeak2Enabled: Bool { peak2Enabled ?? true }
    public var resolvedHighShelfEnabled: Bool { highShelfEnabled ?? true }

    public init(
        lowShelfFreq: Double = 100,
        lowShelfGainDb: Double = 0,
        peak1Freq: Double = 500,
        peak1GainDb: Double = 0,
        peak1Q: Double = 1,
        peak2Freq: Double = 3_000,
        peak2GainDb: Double = 0,
        peak2Q: Double = 1,
        highShelfFreq: Double = 8_000,
        highShelfGainDb: Double = 0,
        highPassFreq: Double? = nil,
        highPassSlopeDbPerOct: Int? = nil,
        highPassEnabled: Bool? = nil,
        lowPassFreq: Double? = nil,
        lowPassSlopeDbPerOct: Int? = nil,
        lowPassEnabled: Bool? = nil,
        lowShelfQ: Double? = nil,
        highShelfQ: Double? = nil,
        lowShelfEnabled: Bool? = nil,
        peak1Enabled: Bool? = nil,
        peak2Enabled: Bool? = nil,
        highShelfEnabled: Bool? = nil
    ) {
        self.lowShelfFreq = lowShelfFreq.clamped(to: Self.lowShelfFreqRange)
        self.lowShelfGainDb = lowShelfGainDb.clamped(to: Self.gainDbRange)
        self.peak1Freq = peak1Freq.clamped(to: Self.peakFreqRange)
        self.peak1GainDb = peak1GainDb.clamped(to: Self.gainDbRange)
        self.peak1Q = peak1Q.clamped(to: Self.qRange)
        self.peak2Freq = peak2Freq.clamped(to: Self.peakFreqRange)
        self.peak2GainDb = peak2GainDb.clamped(to: Self.gainDbRange)
        self.peak2Q = peak2Q.clamped(to: Self.qRange)
        self.highShelfFreq = highShelfFreq.clamped(to: Self.highShelfFreqRange)
        self.highShelfGainDb = highShelfGainDb.clamped(to: Self.gainDbRange)
        self.highPassFreq = highPassFreq?.clamped(to: Self.highPassFreqRange)
        self.highPassSlopeDbPerOct = highPassSlopeDbPerOct.map { Self.snapSlope(Double($0)) }
        self.highPassEnabled = highPassEnabled
        self.lowPassFreq = lowPassFreq?.clamped(to: Self.lowPassFreqRange)
        self.lowPassSlopeDbPerOct = lowPassSlopeDbPerOct.map { Self.snapSlope(Double($0)) }
        self.lowPassEnabled = lowPassEnabled
        self.lowShelfQ = lowShelfQ?.clamped(to: Self.qRange)
        self.highShelfQ = highShelfQ?.clamped(to: Self.qRange)
        self.lowShelfEnabled = lowShelfEnabled
        self.peak1Enabled = peak1Enabled
        self.peak2Enabled = peak2Enabled
        self.highShelfEnabled = highShelfEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case lowShelfFreq, lowShelfGainDb
        case peak1Freq, peak1GainDb, peak1Q
        case peak2Freq, peak2GainDb, peak2Q
        case highShelfFreq, highShelfGainDb
        case highPassFreq, highPassSlopeDbPerOct, highPassEnabled
        case lowPassFreq, lowPassSlopeDbPerOct, lowPassEnabled
        case lowShelfQ, highShelfQ
        case lowShelfEnabled, peak1Enabled, peak2Enabled, highShelfEnabled
    }

    /// Decoding routes through the clamping init; every v2 key tolerates
    /// absence (nil = legacy behavior), so pre-m22-a projects decode as-is.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lowShelfFreq: try c.decodeIfPresent(Double.self, forKey: .lowShelfFreq) ?? 100,
            lowShelfGainDb: try c.decodeIfPresent(Double.self, forKey: .lowShelfGainDb) ?? 0,
            peak1Freq: try c.decodeIfPresent(Double.self, forKey: .peak1Freq) ?? 500,
            peak1GainDb: try c.decodeIfPresent(Double.self, forKey: .peak1GainDb) ?? 0,
            peak1Q: try c.decodeIfPresent(Double.self, forKey: .peak1Q) ?? 1,
            peak2Freq: try c.decodeIfPresent(Double.self, forKey: .peak2Freq) ?? 3_000,
            peak2GainDb: try c.decodeIfPresent(Double.self, forKey: .peak2GainDb) ?? 0,
            peak2Q: try c.decodeIfPresent(Double.self, forKey: .peak2Q) ?? 1,
            highShelfFreq: try c.decodeIfPresent(Double.self, forKey: .highShelfFreq) ?? 8_000,
            highShelfGainDb: try c.decodeIfPresent(Double.self, forKey: .highShelfGainDb) ?? 0,
            highPassFreq: try c.decodeIfPresent(Double.self, forKey: .highPassFreq),
            highPassSlopeDbPerOct: try c.decodeIfPresent(Int.self, forKey: .highPassSlopeDbPerOct),
            highPassEnabled: try c.decodeIfPresent(Bool.self, forKey: .highPassEnabled),
            lowPassFreq: try c.decodeIfPresent(Double.self, forKey: .lowPassFreq),
            lowPassSlopeDbPerOct: try c.decodeIfPresent(Int.self, forKey: .lowPassSlopeDbPerOct),
            lowPassEnabled: try c.decodeIfPresent(Bool.self, forKey: .lowPassEnabled),
            lowShelfQ: try c.decodeIfPresent(Double.self, forKey: .lowShelfQ),
            highShelfQ: try c.decodeIfPresent(Double.self, forKey: .highShelfQ),
            lowShelfEnabled: try c.decodeIfPresent(Bool.self, forKey: .lowShelfEnabled),
            peak1Enabled: try c.decodeIfPresent(Bool.self, forKey: .peak1Enabled),
            peak2Enabled: try c.decodeIfPresent(Bool.self, forKey: .peak2Enabled),
            highShelfEnabled: try c.decodeIfPresent(Bool.self, forKey: .highShelfEnabled))
    }
}

/// Parameters for the built-in soft-knee compressor (M4 iii). Clamped on init
/// (GainParams pattern).
public struct CompressorParams: Codable, Sendable, Equatable {
    public var thresholdDb: Double
    public var ratio: Double
    public var attackMs: Double
    public var releaseMs: Double
    public var kneeDb: Double
    public var makeupDb: Double
    /// PARALLEL ("New York") COMPRESSION blend (m23-ck) — how much of the
    /// compressed signal reaches the output, against the untouched input:
    ///
    ///     out = mix · (compressed, makeup included) + (1 − mix) · dry
    ///
    /// `1` (the DEFAULT) is fully wet — bit-for-bit the pre-m23-ck compressor,
    /// so every existing project renders identically. `0` is a bit-exact
    /// bypass: makeup gain belongs to the WET path and never touches the dry
    /// one. Between them you get the move that previously cost a duplicate
    /// track plus a send blend — crush the copy (low threshold, high ratio)
    /// and dial it under the original for density without losing transients.
    ///
    /// The dry term is the effect's own MAIN input, at the SAME sample index:
    /// the compressor has no lookahead and reports `latencySamples == 0`, so
    /// no delay compensation is needed and the blend cannot comb. When a
    /// sidechain key is attached the key still drives the DETECTOR only —
    /// the dry signal is always the main input, never the key.
    ///
    /// The gain-reduction meter keeps reporting what the DETECTOR computed,
    /// unscaled by `mix` — the same convention that already excludes makeup
    /// gain (both are static output-stage arithmetic, not the detector's
    /// doing). At `mix: 0` the effect is silent-passing while the meter still
    /// shows reduction; that is deliberate.
    public var mix: Double
    /// **THE DE-ESSER (m39-ae)** — WHAT THE DETECTOR LISTENS TO. The audio
    /// path is untouched by this knob; only the signal that DECIDES how much
    /// gain to apply is filtered.
    ///
    /// - `0` — **OFF, and the DEFAULT.** The detector reads the signal flat,
    ///   exactly as it has since M4 (iii). Every project saved before m39-ae
    ///   omits this key, decodes to 0, and renders BIT-FOR-BIT what it always
    ///   did — pinned off rendered audio by
    ///   `scripts/gates/m39ae-compressor-default-bytes.mjs`.
    /// - `1` — **BAND-PASS.** The detector hears a one-band slice around
    ///   `detectorFreqHz`, width set by `detectorQ`. This is the classic
    ///   de-esser: park the band on the "sss" (5–9 kHz on most voices) and the
    ///   unit ignores everything else.
    /// - `2` — **HIGH-PASS.** The detector hears everything ABOVE
    ///   `detectorFreqHz`. Catches sibilance that MOVES — an "sh" sits lower
    ///   than an "s" — at the cost of also hearing cymbals and breath.
    ///
    /// Anything else snaps through `detectorMode(at:)` (the `clipper.mode`
    /// precedent: `fx.setParam` clamps to the range but does not snap, so a
    /// stored 1.4 renders as 1).
    ///
    /// ## ⛔ IT IS A WIDEBAND DE-ESSER, AND THAT IS A REAL DISTINCTION
    ///
    /// When the detector fires, **the whole signal ducks** — lows included —
    /// for as long as the "sss" lasts. It does NOT carve out the sibilant band
    /// and leave the rest playing; that is a SPLIT-BAND de-esser, a different
    /// machine, and it is deliberately not what this is. Wideband is what the
    /// classic hardware did, it needs no crossover, and — the reason that
    /// matters here — it adds **ZERO latency**, so `latencySamples` stays 0 and
    /// no existing project shifts in time. On a voice the ducking is inaudible
    /// because an "s" is short and the lows under it are not what you are
    /// listening to; on a full mix it is audible and you should not use it
    /// there.
    ///
    /// ## What it composes with
    ///
    /// The filter sits on the DETECTOR, which is the same place a sidechain key
    /// already sits. With a key attached the key is what gets filtered — the
    /// dry signal is still always this effect's own main input (see `mix`
    /// above). Both together are "duck this track when THAT track gets
    /// sibilant", which is a real move and costs nothing extra.
    ///
    /// ⚠️ The GR meter keeps reporting what the detector computed, exactly as
    /// it does for `mix` and makeup. With the de-esser on, a meter reading of
    /// 0 during a vowel is the effect working, not the effect failing.
    public var detectorMode: Double
    /// De-ess band centre (mode 1) or corner (mode 2), Hz. Default 6500 — the
    /// middle of where "sss" lives on most voices. Inert at `detectorMode` 0,
    /// where it is not read at all.
    public var detectorFreqHz: Double
    /// De-ess band resonance. Default 2.
    ///
    /// ⚠️ **IT MEANS TWO DIFFERENT THINGS AND BOTH ARE LIVE**, which is worth
    /// one sentence here rather than a support question later:
    /// - mode 1 (band-pass): the band's WIDTH. Bandwidth is
    ///   `detectorFreqHz / detectorQ`, so 2 is about an octave and a half.
    ///   The peak is 0 dB at EVERY Q (the constant-peak-gain form — see
    ///   `EQFilterResponse.bandPassSection`), so widening the band does not
    ///   quietly move the threshold.
    /// - mode 2 (high-pass): the corner's RESONANCE. It is a plain 2-pole
    ///   high-pass whose response AT the corner is `detectorQ` itself, so the
    ///   default 2 puts a deliberate +6 dB emphasis right where sibilance
    ///   starts. Set 0.707 for a flat Butterworth corner.
    public var detectorQ: Double

    public static let thresholdRange: ClosedRange<Double> = -60...0
    public static let ratioRange: ClosedRange<Double> = 1...20
    public static let attackRange: ClosedRange<Double> = 0.1...200
    public static let releaseRange: ClosedRange<Double> = 5...2_000
    public static let kneeRange: ClosedRange<Double> = 0...24
    public static let makeupRange: ClosedRange<Double> = 0...24
    public static let mixRange: ClosedRange<Double> = 0...1
    /// 0 off · 1 band-pass · 2 high-pass. A RANGE rather than an enum on the
    /// wire, because `fx.setParam`'s surface is numeric — the `clipper.mode`
    /// and `limiter.truePeak` shape.
    public static let detectorModeRange: ClosedRange<Double> = 0...2
    /// 1 kHz…16 kHz. The floor is deliberately not lower: a de-ess band under
    /// a kilohertz is not de-essing, it is frequency-selective compression
    /// with a confusing name, and letting the band sit on the fundamental is
    /// the single easiest way to make this unit sound broken.
    public static let detectorFreqRange: ClosedRange<Double> = 1_000...16_000
    public static let detectorQRange: ClosedRange<Double> = 0.3...8

    /// How the detector reads a signal. The value type is INTERNAL to the
    /// engine's decision; the wire and the model both carry the `Double`.
    public enum DetectorMode: Int, Sendable, Equatable {
        case off = 0, bandPass = 1, highPass = 2
    }

    /// The ONE HOME for the snap, so the engine, the wire readback and any test
    /// all answer the same question the same way. `ClipperParams.mode(at:)`
    /// verbatim in shape, and the shape is load-bearing in two places:
    ///
    /// ⛔⛔ **`isFinite` IS NOT ENOUGH, AND THIS COST A CRASH TO LEARN.** `Int()`
    /// on a `Double` traps whenever the result would not fit — so `Int(1e300)`
    /// TRAPS even though 1e300 is perfectly finite. The first version of this
    /// function guarded only `isFinite` and `CompressorDeEssParamsTests
    /// .snapIsTotal` brought the whole test binary down with
    /// "Double value cannot be converted to Int". On the render thread, where a
    /// field-by-field automation poke BYPASSES the clamping init and can deliver
    /// any `Double` at all, that would have been a crash in the audio callback.
    /// The `.clamped(to:)` must come BEFORE the conversion, not after.
    ///
    /// ⚠️ An out-of-range value therefore CLAMPS (99 → `.highPass`) rather than
    /// falling back to off. That is deliberate consistency with the clipper's
    /// mode and with the documented contract of every parameter on this wire —
    /// "out-of-range values clamp rather than erroring" — and a de-esser is not
    /// the place to invent an exception. Non-finite is the one case that cannot
    /// be clamped meaningfully, and it falls back to the DEFAULT (`.off`), the
    /// same rule the clipper applies with its own default.
    public static func detectorMode(at value: Double) -> DetectorMode {
        guard value.isFinite else { return .off }
        let index = Int(value.clamped(to: detectorModeRange).rounded())
        return DetectorMode(rawValue: index) ?? .off
    }

    /// The de-ess band's −3 dB width in Hz, derived — `detectorFreqHz / Q`.
    /// Echoed on the wire so an agent can ask "how wide is my band?" without
    /// re-deriving it, and so this file stays the only place that knows.
    /// Meaningless in mode 2 (a high-pass has no width); the wire says so.
    public static func detectorBandwidthHz(freqHz: Double, q: Double) -> Double {
        let f = freqHz.clamped(to: detectorFreqRange)
        let qq = q.clamped(to: detectorQRange)
        return f / qq
    }

    public init(
        thresholdDb: Double = -18,
        ratio: Double = 4,
        attackMs: Double = 10,
        releaseMs: Double = 100,
        kneeDb: Double = 6,
        makeupDb: Double = 0,
        mix: Double = 1,
        detectorMode: Double = 0,
        detectorFreqHz: Double = 6_500,
        detectorQ: Double = 2
    ) {
        self.thresholdDb = thresholdDb.clamped(to: Self.thresholdRange)
        self.ratio = ratio.clamped(to: Self.ratioRange)
        self.attackMs = attackMs.clamped(to: Self.attackRange)
        self.releaseMs = releaseMs.clamped(to: Self.releaseRange)
        self.kneeDb = kneeDb.clamped(to: Self.kneeRange)
        self.makeupDb = makeupDb.clamped(to: Self.makeupRange)
        self.mix = mix.clamped(to: Self.mixRange)
        self.detectorMode = detectorMode.clamped(to: Self.detectorModeRange)
        self.detectorFreqHz = detectorFreqHz.clamped(to: Self.detectorFreqRange)
        self.detectorQ = detectorQ.clamped(to: Self.detectorQRange)
    }

    private enum CodingKeys: String, CodingKey {
        case thresholdDb, ratio, attackMs, releaseMs, kneeDb, makeupDb, mix
        // m39-ae — APPENDED. `CodingKeys` order carries no meaning (JSON is
        // keyed), but the file reads as a history and appending keeps it one.
        case detectorMode, detectorFreqHz, detectorQ
    }

    /// Decoding routes through the clamping init. `mix` defaults to 1 (fully
    /// wet) when the key is ABSENT — every project saved before m23-ck omits
    /// it, and must decode to exactly today's behaviour.
    ///
    /// ⛔ m39-ae adds three keys under the SAME LAW, and it is the stricter
    /// case: `mix` 1 is "fully wet", which at least LOOKS like a setting, but
    /// `detectorMode` 0 is "this feature is switched off entirely". Every
    /// project saved before m39-ae omits all three keys, and must decode to a
    /// compressor whose detector is flat — which is what 0 means. The other two
    /// defaults (6500 Hz, Q 2) are inert at mode 0 and exist so that a user who
    /// switches the mode on gets a usable band rather than a corner at zero.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            thresholdDb: try c.decodeIfPresent(Double.self, forKey: .thresholdDb) ?? -18,
            ratio: try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 4,
            attackMs: try c.decodeIfPresent(Double.self, forKey: .attackMs) ?? 10,
            releaseMs: try c.decodeIfPresent(Double.self, forKey: .releaseMs) ?? 100,
            kneeDb: try c.decodeIfPresent(Double.self, forKey: .kneeDb) ?? 6,
            makeupDb: try c.decodeIfPresent(Double.self, forKey: .makeupDb) ?? 0,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1,
            detectorMode: try c.decodeIfPresent(Double.self, forKey: .detectorMode) ?? 0,
            detectorFreqHz: try c.decodeIfPresent(Double.self, forKey: .detectorFreqHz) ?? 6_500,
            detectorQ: try c.decodeIfPresent(Double.self, forKey: .detectorQ) ?? 2)
    }
}

/// Parameters for the built-in lookahead limiter (M4 iii). The 5 ms lookahead
/// is FIXED (not a param) — it surfaces as the effect's `latencySamples`
/// (round(0.005 × sampleRate)), the first nonzero insert latency. Clamped on
/// init (GainParams pattern).
public struct LimiterParams: Codable, Sendable, Equatable {
    public var ceilingDb: Double
    public var releaseMs: Double
    /// TRUE-PEAK mode (m23-ch) — WHICH PEAK `ceilingDb` COUNTS. Opt-in,
    /// **default OFF** (the user's settled ruling 2026-08-04, "let's keep
    /// opt-in, no default for now"), so every existing project renders
    /// bit-identically until someone turns it on deliberately.
    ///
    /// - `false` (default): `ceilingDb` is a hard **dBFS SAMPLE-peak**
    ///   ceiling — the original M4 (iii) contract. No output SAMPLE can
    ///   exceed it, but a dBTP meter reconstructs the waveform BETWEEN
    ///   samples and will read ~0.4–1 dB higher on dense material. That is
    ///   arithmetic, not a defect.
    /// - `true`: `ceilingDb` is a **dBTP TRUE-peak** ceiling. Detection runs
    ///   on a 4× oversampled reconstruction (ITU-R BS.1770-4 Annex 2, the
    ///   SAME interpolator this project's dBTP meter uses), so a −1 dBTP
    ///   delivery target is met on the first render with no manual headroom
    ///   guesswork. Costs ~96 multiply-adds per sample per channel and limits
    ///   ~0.3–1 dB harder on dense material — that reduction IS the
    ///   inter-sample overshoot being removed.
    ///
    /// The 5 ms lookahead latency is identical either way, and material whose
    /// peak never reaches the ceiling nulls bit-exact in BOTH modes:
    /// detection only ever engages gain AT the ceiling.
    public var truePeak: Bool

    public static let ceilingRange: ClosedRange<Double> = -24...0
    public static let releaseRange: ClosedRange<Double> = 5...1_000
    /// Fixed lookahead in seconds; `latencySamples = round(lookahead × rate)`.
    public static let lookaheadSeconds: Double = 0.005

    /// THE ONE HOME for the lookahead-delay-in-samples derivation (m23-ab-1).
    /// `LimiterEffect.prepare` and every test that needs the expected
    /// `latencySamples`/`outputLatencySamples` MUST call this rather than
    /// re-deriving or hardcoding a rate-specific constant (240 is only
    /// `round(0.005 × 48000)` — true at 48 kHz and nowhere else).
    public static func lookaheadSamples(sampleRate: Double) -> Int {
        max(1, Int((lookaheadSeconds * sampleRate).rounded()))
    }

    public init(ceilingDb: Double = -1, releaseMs: Double = 50, truePeak: Bool = false) {
        self.ceilingDb = ceilingDb.clamped(to: Self.ceilingRange)
        self.releaseMs = releaseMs.clamped(to: Self.releaseRange)
        self.truePeak = truePeak
    }

    private enum CodingKeys: String, CodingKey { case ceilingDb, releaseMs, truePeak }

    /// Decoding routes through the clamping init. `truePeak` is ABSENT from
    /// every project saved before m23-ch and MUST decode to `false`, so an
    /// existing session keeps its exact sample-peak behaviour — the mode is
    /// opt-in and nothing on disk changes meaning. The schema change is
    /// additive in both directions.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ceilingDb: try c.decodeIfPresent(Double.self, forKey: .ceilingDb) ?? -1,
            releaseMs: try c.decodeIfPresent(Double.self, forKey: .releaseMs) ?? 50,
            truePeak: try c.decodeIfPresent(Bool.self, forKey: .truePeak) ?? false)
    }
}

/// Parameters for the built-in Freeverb-topology reverb (M4 iv). Clamped on
/// init (GainParams pattern). `mix` 0 is bit-exact dry in the engine.
public struct ReverbParams: Codable, Sendable, Equatable {
    public var roomSize: Double
    public var damping: Double
    public var mix: Double
    public var preDelayMs: Double
    public var width: Double

    public static let roomSizeRange: ClosedRange<Double> = 0...1
    public static let dampingRange: ClosedRange<Double> = 0...1
    public static let mixRange: ClosedRange<Double> = 0...1
    public static let preDelayRange: ClosedRange<Double> = 0...200
    public static let widthRange: ClosedRange<Double> = 0...1

    public init(
        roomSize: Double = 0.5,
        damping: Double = 0.5,
        mix: Double = 0.35,
        preDelayMs: Double = 10,
        width: Double = 1
    ) {
        self.roomSize = roomSize.clamped(to: Self.roomSizeRange)
        self.damping = damping.clamped(to: Self.dampingRange)
        self.mix = mix.clamped(to: Self.mixRange)
        self.preDelayMs = preDelayMs.clamped(to: Self.preDelayRange)
        self.width = width.clamped(to: Self.widthRange)
    }

    private enum CodingKeys: String, CodingKey {
        case roomSize, damping, mix, preDelayMs, width
    }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            roomSize: try c.decodeIfPresent(Double.self, forKey: .roomSize) ?? 0.5,
            damping: try c.decodeIfPresent(Double.self, forKey: .damping) ?? 0.5,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 0.35,
            preDelayMs: try c.decodeIfPresent(Double.self, forKey: .preDelayMs) ?? 10,
            width: try c.decodeIfPresent(Double.self, forKey: .width) ?? 1)
    }
}

/// Parameters for the built-in stereo delay (M4 iv). `pingPong` is numeric on
/// the generic surface (0 or 1 — the clamping init snaps to the nearer);
/// `highCutHz` is a one-pole low-pass in the FEEDBACK path only, so the first
/// echo is unfiltered. Clamped on init (GainParams pattern).
///
/// TEMPO SYNC (m22-f) — two additive optionals with synthesized encoding, so
/// nil is OMITTED on disk (the m22-a EQ v2 precedent) and legacy projects
/// decode/encode byte-compatible:
///  · `sync` nil = false — the delay free-runs on `timeMs`, the pre-m22-f
///    behavior exactly.
///  · `division` nil = 1/4 — the note length a synced delay tracks. Persisted
///    as its token string ("1/4", "1/8d" dotted, "1/8t" triplet — see
///    `NoteDivision`); numeric on the generic param surface as its length in
///    BEATS (`NoteDivision.nearest(toBeats:)` snaps).
/// When synced, the EFFECTIVE time is `effectiveTimeMs(atTempoBPM:)` —
/// derived on the CONTROL PLANE (engine intake seams + tempo-change re-push;
/// the render thread never does tempo lookups) while `timeMs` stays STORED
/// untouched as the unsync fallback.
public struct DelayParams: Codable, Sendable, Equatable {
    public var timeMs: Double
    /// How much of each repeat is written back into the loop. The ceiling is
    /// **0.999, not 1.0, and that is a MEASURED bound** (m39-k) — see
    /// `feedbackRange`.
    public var feedback: Double
    public var mix: Double
    public var pingPong: Double
    /// One-pole low-pass INSIDE the feedback loop, so it is subtracted once
    /// per repeat. ⚠️ At a freeze-grade `feedback` this, not `feedback`, sets
    /// how long the tail lasts — and it is NOT a stability margin: the filter's
    /// gain at DC is exactly 1 at every setting (`y += a·(x − y)` is unity at
    /// ω = 0 for all a), which is why the feedback ceiling has to stop short of
    /// 1.0. Measured, 350 ms delay at feedback 0.999, burst then silence: the
    /// tail was **3.19 dB down after 110 s at 20 000 Hz and gone in ~20 s at
    /// 500 Hz** (peak 0.78 → 0.017 over the same window).
    public var highCutHz: Double
    // MARK: m22-f tempo-sync additive optionals — nil = pre-m22-f behavior.
    /// nil = false. True derives the effective time from the project tempo.
    public var sync: Bool?
    /// nil = 1/4. The note length a synced delay tracks (ignored unsynced).
    public var division: NoteDivision?

    public static let timeRange: ClosedRange<Double> = 1...2_000
    /// m39-k — the echo freeze. **0.95 → 0.999**, and the ceiling stops short
    /// of 1.0 ON A MEASUREMENT, not on caution:
    ///
    ///  · At exactly **1.0** the loop returns everything it is given, so
    ///    anything it cannot lose accumulates without bound. A constant (DC)
    ///    input of 0.1 into a 10 ms delay measured **9.66 / 96.97 / 193.94 /
    ///    290.94** after 1 / 10 / 20 / 30 s — a straight line with no ceiling —
    ///    and that was at `highCutHz` 500, the MOST damped setting. Measured at
    ///    the OTHER extreme (20 kHz) the same line reads 99.90 / 199.90 / 299.91,
    ///    i.e. a step of exactly 100.00 = 0.1 × 100 repeats/s × 10 s. The two
    ///    ends differ by 3 %: the loop filter is unity at DC and therefore
    ///    supplies no stability margin at either setting.
    ///  · At **0.999** the same input settled at **94.56** by 30 s against the
    ///    predicted ceiling of exactly 100 = 1/(1 − feedback). A 1 kHz tone
    ///    driving a comb peak settled at 24.0 (bounded) instead of climbing.
    ///  · 0.999 is a freeze by any musical measure: 0.0087 dB lost per repeat,
    ///    so a 350 ms tail is **3.19 dB down after 110 seconds**. (0.95 loses
    ///    0.45 dB per repeat — about four seconds to fade.)
    ///
    /// ⚠️ **This is the ONE home for the bound**: the clamping init, the wire
    /// setter (`ProjectStore.setEffectParam` clamps through the spec range) and
    /// automation-lane points (`AutomationTarget.valueRange`) all resolve here,
    /// as does the render-path re-clamp in `DelayEffect.deriveRenderParams`.
    /// ⚠️ **Widening is backward-compatible; NARROWING IS NOT** — a project
    /// saved at 0.999 would be silently re-voiced. Raise this only on a
    /// measurement, and never lower it.
    public static let feedbackRange: ClosedRange<Double> = 0...0.999
    public static let mixRange: ClosedRange<Double> = 0...1
    public static let pingPongRange: ClosedRange<Double> = 0...1
    public static let highCutRange: ClosedRange<Double> = 500...20_000
    /// The generic-surface span for `division` (its length in beats):
    /// 1/32t … 1/1d, built FROM the enum so the bounds are bit-identical to
    /// the snapped reads.
    public static let divisionBeatsRange: ClosedRange<Double> =
        NoteDivision.thirtySecondTriplet.beats...NoteDivision.wholeDotted.beats

    /// The nil semantics' single home (the EQParams `resolved*` rule).
    public var resolvedSync: Bool { sync ?? false }
    public var resolvedDivision: NoteDivision { division ?? .quarter }

    /// The time the engine should actually render: `timeMs` free-running,
    /// or the division's length at `bpm` when synced — CLAMPED to the param
    /// range (the delay line is preallocated for 2 s; a 1/1d at 30 BPM pins
    /// at 2 000 ms honestly rather than overrunning). Pure — the m22-f
    /// division→ms math itself lives in `NoteDivision.milliseconds(atBPM:)`
    /// (TempoMap.swift, the sanctioned conversion home). A non-finite bpm
    /// falls back to the stored `timeMs`, never NaN into the render path.
    public func effectiveTimeMs(atTempoBPM bpm: Double) -> Double {
        guard resolvedSync else { return timeMs }
        let derived = resolvedDivision.milliseconds(atBPM: bpm)
        guard derived.isFinite else { return timeMs }
        return derived.clamped(to: Self.timeRange)
    }

    public init(
        timeMs: Double = 350,
        feedback: Double = 0.35,
        mix: Double = 0.3,
        pingPong: Double = 0,
        highCutHz: Double = 8_000,
        sync: Bool? = nil,
        division: NoteDivision? = nil
    ) {
        self.timeMs = timeMs.clamped(to: Self.timeRange)
        self.feedback = feedback.clamped(to: Self.feedbackRange)
        self.mix = mix.clamped(to: Self.mixRange)
        self.pingPong = pingPong.clamped(to: Self.pingPongRange).rounded()
        self.highCutHz = highCutHz.clamped(to: Self.highCutRange)
        self.sync = sync
        self.division = division
    }

    private enum CodingKeys: String, CodingKey {
        case timeMs, feedback, mix, pingPong, highCutHz, sync, division
    }

    /// Decoding routes through the clamping init; the m22-f keys tolerate
    /// absence (nil = legacy behavior) AND an unknown division token (a
    /// future variant decodes as nil = 1/4 rather than failing the project).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            timeMs: try c.decodeIfPresent(Double.self, forKey: .timeMs) ?? 350,
            feedback: try c.decodeIfPresent(Double.self, forKey: .feedback) ?? 0.35,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 0.3,
            pingPong: try c.decodeIfPresent(Double.self, forKey: .pingPong) ?? 0,
            highCutHz: try c.decodeIfPresent(Double.self, forKey: .highCutHz) ?? 8_000,
            sync: try c.decodeIfPresent(Bool.self, forKey: .sync),
            division: (try c.decodeIfPresent(String.self, forKey: .division))
                .flatMap(NoteDivision.init(rawValue:)))
    }
}

/// Parameters for the built-in tanh saturator (M4 iv, oversampling added by
/// m39-ad). Clamped on init (GainParams pattern).
///
/// ## ⛔⛔ THE DEFAULT OF `oversampling` IS 1 AND IT IS NOT A QUALITY CHOICE
///
/// `.clipper` — the other caller of `Oversampler` — defaults to 4, and it could,
/// because it was a brand-new kind on the day the control was written. THIS KIND
/// IS NOT. `.saturator` has shipped since M4 (iv) and there are already saved
/// projects with one in a chain. A default of 2 or 4 would change what every one
/// of those projects SOUNDS like AND shift it in time by the 32 samples the
/// filters cost — silently, on the next open.
///
/// So the default is 1, at which `SaturatorEffect` SKIPS the oversampling path
/// outright rather than running it at factor 1, and reports `latencySamples == 0`.
/// The result is bit-for-bit v0. That is not an argument, it is a measured claim:
/// `scripts/gates/m39ad-saturator-default-bytes.mjs` pins the sha256 of a render
/// of an untouched saturator, captured from the last build in which this struct
/// had three fields, and a CONTROL hash of the same fixture with no effect at all
/// so a change in the surrounding pipeline cannot be mistaken for a change here.
/// The repo's binding precedent is the "bend range default stays 2.0" ruling.
///
/// ⚠️ **`latencySamples` IS THEREFORE PARAMETER-DEPENDENT ON THIS KIND — 0 at
/// factor 1, 32 at 2 and 4 — WHICH `.clipper` DELIBERATELY AVOIDED.** That is
/// only safe because of two properties, and BOTH are required:
///
///  1. the factor can be changed ONLY by a main-actor `apply(params:)`, which
///     always runs inside `PlaybackGraph.applyParameters`, whose TAIL calls
///     `recomputeCompensation` — so the PDC plan is rebuilt in the SAME pass that
///     moved the latency (`EffectFactory.applyParams` has exactly one production
///     call site, `EffectChainState.sync`, and it is inside that function);
///  2. `oversampling` is INERT TO AUTOMATION (`SaturatorEffect.storeAutomatedParam`
///     ignores its slot, the `delay.sync`/`delay.division` precedent), so the
///     RENDER thread can never move the factor behind the plan's back.
///
/// Break either one and this becomes the silent staleness `OversamplerDesign` §3
/// warns about. See `SaturatorEffect`'s DESIGN §3.
public struct SaturatorParams: Codable, Sendable, Equatable {
    public var driveDb: Double
    public var mix: Double
    public var outputDb: Double
    /// Oversampling factor: 1, 2 or 4. DISCRETE — `Modulatable: refused` AND
    /// NOT AUTOMATABLE, snapped through `oversamplingFactor(at:)`.
    ///
    /// ⛔ Appended LAST on purpose: the INDEX of a spec in
    /// `EffectParamSpec.specs(for: .saturator)` IS the automation slot, and this
    /// kind's first three slots are in saved user automation lanes already.
    public var oversampling: Double

    /// ⚠️ 0…36, NOT the clipper's −12…36, and the difference is deliberate. A
    /// clipper's drive is a trim around a ceiling that already exists, so pulling
    /// it negative is a real setting. A saturator's drive IS the effect: 0 means
    /// "do nothing", and there is nothing below that.
    public static let driveRange: ClosedRange<Double> = 0...36
    public static let mixRange: ClosedRange<Double> = 0...1
    public static let outputRange: ClosedRange<Double> = -12...12
    /// Same 1…4 as the clipper's — the roster is the filter family's
    /// (`OversamplerDesign.supportedFactors`), not the kind's.
    public static let oversamplingRange: ClosedRange<Double> = 1...4

    /// Snaps a raw wire value onto a supported factor (1, 2 or 4).
    ///
    /// ⛔ **FORWARDS TO `ClipperParams.oversamplingFactor(at:)` RATHER THAN
    /// RESTATING ITS THRESHOLDS, AND THAT IS THE POINT.** The snapping rule —
    /// `< 1.5 → 1`, `< 3.0 → 2`, else 4, every tie resolving UPWARD — is a
    /// property of `OversamplerDesign.supportedFactors`, which both kinds share.
    /// A second copy here would be a second statement of one fact, free to drift;
    /// `SaturatorParamsTests` re-derives this from the roster by brute force AND
    /// pins it against the clipper's over a dense sweep, so the shared home
    /// cannot drift away from either caller.
    ///
    /// ⚠️ The two kinds share the SNAP and share nothing else: not the default
    /// (4 there, 1 here), not the latency behaviour (constant there,
    /// factor-dependent here), not the drive range.
    public static func oversamplingFactor(at value: Double) -> Int {
        ClipperParams.oversamplingFactor(at: value)
    }

    /// ⛔ **THE LATENCY THIS KIND REPORTS, IN SAMPLES, AS A FUNCTION OF THE
    /// FACTOR — 0 at 1, `OversamplerDesign.latencySamples` (32) at 2 and 4.**
    /// The ONE home: `SaturatorEffect.latencySamples`, the wire echo and the
    /// tests all read this, never a second copy.
    ///
    /// The 0 at factor 1 is the whole preservation promise. `Oversampler`'s
    /// factor-1 kernel IS a pure 32-sample delay (`OversamplerDesign` §3), so
    /// running it at 1 would cost 32 samples of shift for no benefit at all —
    /// which on a shipped kind is exactly the regression the default exists to
    /// refuse. The effect skips the path instead.
    public static func latencySamples(oversampling: Double) -> Int {
        oversamplingFactor(at: oversampling) == 1 ? 0 : OversamplerDesign.latencySamples
    }

    public init(driveDb: Double = 12, mix: Double = 1, outputDb: Double = 0,
                oversampling: Double = 1) {
        self.driveDb = driveDb.clamped(to: Self.driveRange)
        self.mix = mix.clamped(to: Self.mixRange)
        self.outputDb = outputDb.clamped(to: Self.outputRange)
        // Non-finite guard ahead of the snap: `oversamplingFactor(at:)` reaches
        // an `Int()` conversion that would TRAP on a NaN (the
        // `RingModParams.waveform` precedent). It guards internally too; this
        // reads as the intent rather than relying on the callee's.
        self.oversampling = Double(
            Self.oversamplingFactor(at: oversampling.isFinite ? oversampling : 1))
    }

    private enum CodingKeys: String, CodingKey {
        case driveDb, mix, outputDb, oversampling
    }

    /// Decoding routes through the clamping/snapping init.
    ///
    /// ⛔ `?? 1` ON `oversampling` IS THE MIGRATION. Every project saved before
    /// m39-ad has no `oversampling` key at all, so it decodes to 1 — which is
    /// the setting at which this effect is bit-for-bit what it was when that
    /// project was saved. Any other fallback would silently re-voice old work.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            driveDb: try c.decodeIfPresent(Double.self, forKey: .driveDb) ?? 12,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1,
            outputDb: try c.decodeIfPresent(Double.self, forKey: .outputDb) ?? 0,
            oversampling: try c.decodeIfPresent(Double.self, forKey: .oversampling) ?? 1)
    }
}

/// Parameters for the built-in noise gate (M4 iv). Clamped on init
/// (GainParams pattern). Fully closed is TRUE silence; fully open is
/// bit-exact passthrough.
public struct GateParams: Codable, Sendable, Equatable {
    public var thresholdDb: Double
    public var attackMs: Double
    public var holdMs: Double
    public var releaseMs: Double

    public static let thresholdRange: ClosedRange<Double> = -80...0
    public static let attackRange: ClosedRange<Double> = 0.1...50
    public static let holdRange: ClosedRange<Double> = 0...500
    public static let releaseRange: ClosedRange<Double> = 5...2_000

    public init(
        thresholdDb: Double = -40,
        attackMs: Double = 1,
        holdMs: Double = 50,
        releaseMs: Double = 100
    ) {
        self.thresholdDb = thresholdDb.clamped(to: Self.thresholdRange)
        self.attackMs = attackMs.clamped(to: Self.attackRange)
        self.holdMs = holdMs.clamped(to: Self.holdRange)
        self.releaseMs = releaseMs.clamped(to: Self.releaseRange)
    }

    private enum CodingKeys: String, CodingKey {
        case thresholdDb, attackMs, holdMs, releaseMs
    }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            thresholdDb: try c.decodeIfPresent(Double.self, forKey: .thresholdDb) ?? -40,
            attackMs: try c.decodeIfPresent(Double.self, forKey: .attackMs) ?? 1,
            holdMs: try c.decodeIfPresent(Double.self, forKey: .holdMs) ?? 50,
            releaseMs: try c.decodeIfPresent(Double.self, forKey: .releaseMs) ?? 100)
    }
}

/// Parameters for the built-in 2-voice chorus (M4 iv). `depthMs` modulates
/// around a fixed ~15 ms center delay. Clamped on init (GainParams pattern).
public struct ChorusParams: Codable, Sendable, Equatable {
    public var rateHz: Double
    public var depthMs: Double
    public var mix: Double

    public static let rateRange: ClosedRange<Double> = 0.05...5
    public static let depthRange: ClosedRange<Double> = 0.5...10
    public static let mixRange: ClosedRange<Double> = 0...1

    public init(rateHz: Double = 0.8, depthMs: Double = 3, mix: Double = 0.5) {
        self.rateHz = rateHz.clamped(to: Self.rateRange)
        self.depthMs = depthMs.clamped(to: Self.depthRange)
        self.mix = mix.clamped(to: Self.mixRange)
    }

    private enum CodingKeys: String, CodingKey { case rateHz, depthMs, mix }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rateHz: try c.decodeIfPresent(Double.self, forKey: .rateHz) ?? 0.8,
            depthMs: try c.decodeIfPresent(Double.self, forKey: .depthMs) ?? 3,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 0.5)
    }
}

/// Parameters for the built-in psychoacoustic bass enhancer (m23-p1) — the
/// RBass/MaxxBass class. Clamped on init (GainParams pattern).
///
/// WHAT IT DOES, honestly: the effect low-passes the input at `crossoverHz`,
/// synthesizes the 2nd/3rd/4th harmonics OF THAT LOW BAND ONLY, high-passes
/// the result at the same corner, and ADDS it to the untouched dry signal. A
/// small speaker that rolls off below the crossover still hears the harmonic
/// series, and the ear reconstructs the pitch of the fundamental it never
/// received (the "missing fundamental" / residue-pitch effect). Nothing is
/// subtracted and the dry path is never filtered, so the effect is PURELY
/// ADDITIVE — with `amount` or `mix` at 0 the output is BIT-EXACT dry.
///
/// This is NOT the broadband `saturator`: the shaper only ever sees the low
/// band, the generated series is truncated at the 4th partial (a waveshaper
/// produces an unbounded series), and the harmonics are level-tracked so the
/// character is the same on a quiet bass line as on a loud one.
public struct BassEnhancerParams: Codable, Sendable, Equatable {
    /// The split point, in Hz: harmonics are generated FROM content below it
    /// and injected ABOVE it. Set it to the low limit of the speaker you are
    /// worried about.
    public var crossoverHz: Double
    /// How much harmonic content is generated, 0…1. Raising it adds level AND
    /// tilts the series toward the higher partials (see `harmonicWeights`) —
    /// it is a generator control, not a plain output gain. 0 = no generation
    /// at all (bit-exact dry).
    public var amount: Double
    /// Dry/wet, 0…1. Because the effect only ever ADDS material to an
    /// untouched dry path, `mix` is exactly a master trim on everything the
    /// effect contributes; 0 is bit-exact dry.
    public var mix: Double

    public static let crossoverRange: ClosedRange<Double> = 30...250
    public static let amountRange: ClosedRange<Double> = 0...1
    public static let mixRange: ClosedRange<Double> = 0...1

    /// The generated series' relative weights at `amount`, as coefficients on
    /// the Chebyshev polynomials T2/T3/T4 — so a unit-amplitude sinusoid at f
    /// maps to partials at 2f/3f/4f with EXACTLY these amplitudes (T_n(cos θ)
    /// = cos nθ). ONE HOME: the engine derives its render weights here and the
    /// editor draws the series from the same call, so the picture can never
    /// disagree with the sound.
    ///
    /// The shape: every weight rises with `amount`, but the higher partials
    /// rise FASTER (h3 ∝ a², h4 ∝ a³), so a small amount is a warm 2nd-harmonic
    /// lift and a large one is a bright, phone-speaker-friendly buzz. This is
    /// what makes `amount` independent of `mix` rather than a second gain.
    /// The peak sum is 0.9 at a = 1 (the partials all peak together), which
    /// bounds the generated signal at 0.9 × the low band's own level.
    public static func harmonicWeights(amount: Double)
        -> (h2: Double, h3: Double, h4: Double) {
        let a = amount.clamped(to: amountRange)
        return (h2: a * (0.5 - 0.15 * a), h3: a * (0.30 * a), h4: a * (0.25 * a * a))
    }

    public init(crossoverHz: Double = 80, amount: Double = 0.5, mix: Double = 1) {
        self.crossoverHz = crossoverHz.clamped(to: Self.crossoverRange)
        self.amount = amount.clamped(to: Self.amountRange)
        self.mix = mix.clamped(to: Self.mixRange)
    }

    private enum CodingKeys: String, CodingKey { case crossoverHz, amount, mix }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            crossoverHz: try c.decodeIfPresent(Double.self, forKey: .crossoverHz) ?? 80,
            amount: try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0.5,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1)
    }
}

/// Parameters for the built-in bit-crusher / sample-rate reducer (m32-e) — the
/// lo-fi character of a 1980s sampling drum machine. Clamped on init (GainParams
/// pattern); `bits` additionally ROUNDS to a whole number (the `DelayParams`
/// `pingPong` precedent for a numeric-but-discrete field).
///
/// WHAT IT DOES, in the order the render path does it: the input is optionally
/// low-passed (`antiAlias`), then SAMPLED AND HELD at `downsampleHz`, and each
/// captured value is optionally dithered and then quantized to `bits` — one
/// value per capture, held flat until the next. Optionally the held staircase is
/// low-passed again (the reconstruction filter a real converter would have).
///
/// ⭐ WHY THE DEFAULTS ARE `antiAlias: false` / `dither: false`, which look like
/// the "wrong" engineering choice: the reference sound is the E-mu SP-1200's,
/// and that machine's signature comes specifically from its D/A stage OMITTING
/// the reconstruction filter — content above the reduced Nyquist images straight
/// back down into the audible band as the grit people buy the machine for.
/// A bit-crusher that filters politely and dithers away the quantization noise
/// sounds "clean-but-crunchy", not "gritty", and does not hit the reference
/// (`docs/research/sampling-flip-workflow.md` §2.4). Both switches exist, both
/// default OFF, and turning them ON gives the modern, tamer crush.
///
/// The defaults `bits: 12` / `downsampleHz: 26040` ARE the SP-1200's measured
/// storage depth and sampling rate. The MPC60 is commonly cited at 40 kHz with
/// the same 12-bit storage, which is why MPC60 chops read as cleaner — set
/// `downsampleHz: 40000` for that flavour.
///
/// ⚠️ `downsampleHz` tops out at 48 000, so at graph rates ABOVE 48 kHz even the
/// maximum setting still halves the rate. The effect is never a no-op there;
/// bypass it (or remove it) if you want the untouched signal at 88.2/96 kHz.
public struct BitCrusherParams: Codable, Sendable, Equatable {
    /// Storage depth in bits, 1…16, WHOLE numbers (values round). The rendered
    /// signal takes exactly `2^bits` distinct levels — a real N-bit converter's
    /// code range, −2^(N−1) … 2^(N−1)−1, scaled back to ±1.
    public var bits: Double
    /// The rate the input is sampled and held at, in Hz. Below the graph rate
    /// this is heard as the classic "grainy/aliased" downsample; at or above
    /// the graph rate every sample is captured and the stage is transparent.
    public var downsampleHz: Double
    /// ⭐ OFF by default and that is deliberate — see the type's doc comment.
    /// ON adds a 4th-order Butterworth low-pass BEFORE the sample-and-hold (so
    /// input content above the reduced Nyquist cannot fold down) and another
    /// AFTER the hold (the reconstruction filter that removes the staircase's
    /// images). Both corners sit at `downsampleHz / 2`.
    public var antiAlias: Bool
    /// ⭐ OFF by default — see the type's doc comment. ON adds ±1 LSB TPDF
    /// dither to each captured value before it is quantized, trading the
    /// correlated quantization distortion for a steady noise floor. The dither
    /// generator is seeded deterministically per channel, so a render is
    /// reproducible byte-for-byte with dither on.
    public var dither: Bool
    /// Dry/wet, 0…1. 0 is a BIT-EXACT bypass of the whole unit (and advances no
    /// internal state), 1 (the default) is fully crushed.
    public var mix: Double

    public static let bitsRange: ClosedRange<Double> = 1...16
    public static let downsampleRange: ClosedRange<Double> = 1_000...48_000
    public static let mixRange: ClosedRange<Double> = 0...1

    public init(bits: Double = 12, downsampleHz: Double = 26_040,
                antiAlias: Bool = false, dither: Bool = false, mix: Double = 1) {
        // NaN FIRST, then clamp, then round — and the NaN leg is not defensive
        // padding. `clamped` is `min(max(…))`, and BOTH comparisons are false
        // against NaN, so a NaN survives a clamp unchanged; the render path
        // then does `Int(bits)` to build a shift, and `Int(Double.nan)` TRAPS.
        // The trap would fire ON THE RENDER THREAD — the same shape as m32-f's
        // `1 << 99`, reached through a different door.
        self.bits = (bits.isFinite ? bits : 12).clamped(to: Self.bitsRange).rounded()
        self.downsampleHz =
            (downsampleHz.isFinite ? downsampleHz : 26_040).clamped(to: Self.downsampleRange)
        self.antiAlias = antiAlias
        self.dither = dither
        self.mix = mix.clamped(to: Self.mixRange)
    }

    private enum CodingKeys: String, CodingKey {
        case bits, downsampleHz, antiAlias, dither, mix
    }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bits: try c.decodeIfPresent(Double.self, forKey: .bits) ?? 12,
            downsampleHz: try c.decodeIfPresent(Double.self, forKey: .downsampleHz) ?? 26_040,
            antiAlias: try c.decodeIfPresent(Bool.self, forKey: .antiAlias) ?? false,
            dither: try c.decodeIfPresent(Bool.self, forKey: .dither) ?? false,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1)
    }
}

/// Single-knob bipolar resonant filter (m39-i) — the club-mixer / DJ-mixer
/// sweep. `position` 0 is a bit-exact dry centre; negative sweeps a LOW-pass
/// downward (treble disappears first), positive sweeps a HIGH-pass upward (bass
/// disappears first). ONE knob, because that is the entire instrument.
///
/// NO `mix` PARAMETER, DELIBERATELY: summing a resonant filter with its own dry
/// signal is comb filtering, not a gentler filter. The dry/wet blend that does
/// exist is `deadZoneWidth`, which crossfades to dry only across the centre.
///
/// ⚠️ NOT an `EQParams` extension, and that was a considered rejection
/// (`docs/design/2026-09-19-creative-effects.md` §2.1, §3.1): the EQ is at 22
/// params with frozen positional slots, its HP/LP are Butterworth cascades with
/// no Q at all, and a bipolar single-knob sweep would need two EQ lanes moving
/// in opposition. The resonance and the one knob ARE the identity here.
///
/// Clamped on init (the `GainParams` pattern); `slopeDbPerOct` additionally
/// SNAPS to 12 or 24 (`EQParams.snapSlope` verbatim — a topology switch, not a
/// continuum).
public struct DJFilterParams: Codable, Sendable, Equatable {
    /// -1 = full LOW-pass … 0 = bypass … +1 = full HIGH-pass — the direction a
    /// Pioneer-style club mixer's centre-detented filter knob turns (left
    /// muffles, right thins). Amended from the design's §6.1.1, which had it
    /// inverted: errata E4, ruled 2026-09-19.
    public var position: Double
    /// 0 = Butterworth (Q 0.707) … 1 = Q 10, on the edge of self-oscillation.
    public var resonance: Double
    /// 12 or 24 dB/oct; other values snap to the nearer.
    public var slopeDbPerOct: Double
    /// Half-width of the centre region that crossfades to dry. 0 disables the
    /// crossfade entirely (the filter engages the instant `position` leaves 0).
    public var deadZoneWidth: Double
    /// How much `resonance` rises toward the sweep extremes — the "isolator"
    /// feel. 0 = constant resonance across the whole sweep (predictable).
    public var resonanceTrack: Double

    public static let positionRange: ClosedRange<Double> = -1...1
    public static let resonanceRange: ClosedRange<Double> = 0...1
    public static let slopeRange: ClosedRange<Double> = 12...24
    public static let deadZoneRange: ClosedRange<Double> = 0...0.2
    public static let resonanceTrackRange: ClosedRange<Double> = 0...1

    // MARK: The cutoff law — ONE HOME, in DAWCore, read by the DSP, the UI and
    // `fx.describe`'s note text. An agent that cannot compute this is guessing.

    /// Lowest cutoff either sweep reaches, Hz.
    public static let cutoffFloorHz = 20.0
    /// Highest cutoff either sweep reaches, Hz.
    public static let cutoffCeilingHz = 20_000.0

    /// The cutoff a given `position` selects, and `nil` at a bypassing centre.
    /// Log-symmetric about the centre: each sweep spans the full
    /// `log2(20000/20) = 9.97`-octave audible range, so equal knob travel is
    /// equal musical travel at both ends.
    ///   position < 0 : LOW-pass,   f = 20000 · (20/20000)^|position|
    ///   position > 0 : HIGH-pass,  f = 20 · (20000/20)^position
    public static func cutoffHz(atPosition position: Double) -> Double? {
        guard position.isFinite else { return nil }
        let p = position.clamped(to: positionRange)
        if p == 0 { return nil }
        let span = cutoffCeilingHz / cutoffFloorHz          // 1000
        return p < 0
            ? cutoffCeilingHz * pow(1 / span, -p)
            : cutoffFloorHz * pow(span, p)
    }

    /// True when `position` selects the HIGH-pass side — the RIGHT half of the
    /// knob, which thins the sound by removing bass. `nil` at the centre,
    /// where no filter runs at all — the same tri-state `cutoffHz` reports, so
    /// the two can never disagree about whether the effect is engaged.
    public static func isHighPass(atPosition position: Double) -> Bool? {
        guard position.isFinite else { return nil }
        let p = position.clamped(to: positionRange)
        if p == 0 { return nil }
        return p > 0
    }

    /// Resonance 0…1 → filter Q. 0 is Butterworth (0.707, maximally flat, no
    /// peak); 1 is Q 10, a strong peak on the edge of self-oscillation.
    /// ONE HOME: the engine derives its coefficient from this call and
    /// `fx.describe`'s note quotes the same law.
    public static func q(resonance: Double) -> Double {
        0.707 + resonance.clamped(to: resonanceRange) * 9.293
    }

    /// The Q actually used at a given knob position, once `resonanceTrack` has
    /// leaned on it: `Q_eff = Q · (1 + resonanceTrack · position²)`. The square
    /// is what makes tracking do nothing near the centre and everything at the
    /// extremes — the "isolator" feel, where a kill sweep whistles only as it
    /// runs out of band. At `resonanceTrack == 0` this is exactly `q(...)`.
    public static func effectiveQ(resonance: Double, position: Double,
                                  resonanceTrack: Double) -> Double {
        let p = position.isFinite ? position.clamped(to: positionRange) : 0
        let track = resonanceTrack.isFinite
            ? resonanceTrack.clamped(to: resonanceTrackRange) : 0
        return q(resonance: resonance) * (1 + track * p * p)
    }

    /// Wet gain across the dead zone: a raised cosine rising 0 → 1 over
    /// `|position| ∈ [0, deadZoneWidth]`, flat at 1 beyond it. At
    /// `position == 0` it is EXACTLY 0 for every width — that is the bit-exact
    /// dry centre (rule 6.0.7's `mix == 0` convention, expressed on the one
    /// knob this effect has). A width of 0 engages the filter the instant the
    /// knob leaves the centre, with no divide-by-zero on the way.
    public static func wetGain(atPosition position: Double,
                               deadZoneWidth: Double) -> Double {
        guard position.isFinite else { return 0 }
        let p = abs(position.clamped(to: positionRange))
        if p == 0 { return 0 }
        let width = deadZoneWidth.isFinite
            ? deadZoneWidth.clamped(to: deadZoneRange) : 0
        guard width > 0 else { return 1 }
        if p >= width { return 1 }
        return 0.5 - 0.5 * cos(.pi * p / width)
    }

    public init(position: Double = 0, resonance: Double = 0.25,
                slopeDbPerOct: Double = 24, deadZoneWidth: Double = 0.04,
                resonanceTrack: Double = 0) {
        // Non-finite guards ahead of every clamp: `clamped(to:)` on a NaN
        // returns the NaN, and this struct's values reach `tan()` and a
        // `pow()` on the render thread (the BitCrusherParams precedent, where
        // a NaN reached an `Int()` conversion and would have TRAPPED).
        self.position = (position.isFinite ? position : 0).clamped(to: Self.positionRange)
        self.resonance = (resonance.isFinite ? resonance : 0.25)
            .clamped(to: Self.resonanceRange)
        self.slopeDbPerOct = Double(EQParams.snapSlope(
            (slopeDbPerOct.isFinite ? slopeDbPerOct : 24).clamped(to: Self.slopeRange)))
        self.deadZoneWidth = (deadZoneWidth.isFinite ? deadZoneWidth : 0.04)
            .clamped(to: Self.deadZoneRange)
        self.resonanceTrack = (resonanceTrack.isFinite ? resonanceTrack : 0)
            .clamped(to: Self.resonanceTrackRange)
    }

    private enum CodingKeys: String, CodingKey {
        case position, resonance, slopeDbPerOct, deadZoneWidth, resonanceTrack
    }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            position: try c.decodeIfPresent(Double.self, forKey: .position) ?? 0,
            resonance: try c.decodeIfPresent(Double.self, forKey: .resonance) ?? 0.25,
            slopeDbPerOct: try c.decodeIfPresent(Double.self, forKey: .slopeDbPerOct) ?? 24,
            deadZoneWidth: try c.decodeIfPresent(Double.self, forKey: .deadZoneWidth) ?? 0.04,
            resonanceTrack: try c.decodeIfPresent(Double.self, forKey: .resonanceTrack) ?? 0)
    }
}

/// Ring modulator (m39-m): the input multiplied, sample by sample, by a
/// BAND-LIMITED carrier oscillator. `docs/design/2026-09-19-creative-effects.md`
/// §6.4 is the frozen contract.
///
/// WHAT IT ACTUALLY DOES, because "multiply by a sine" hides the interesting
/// part: multiplying two sinusoids at `f` and `fc` produces neither of them. It
/// produces exactly two new tones, at `|f - fc|` and `f + fc` — the SIDEBANDS.
/// Every partial of the input gets that treatment, so a harmonic series in
/// becomes an INHARMONIC series out, which is why the sound is metallic and
/// bell-like rather than filtered or distorted. `sidebandsHz(inputHz:carrierHz:)`
/// is that law's ONE HOME; the DSP, the tests and `fx.describe`'s note all read
/// it rather than each re-deriving it.
///
/// ⚠️ The carrier itself is ABSENT from the output — that is what distinguishes
/// a ring modulator from a tremolo (amplitude modulator). A tremolo multiplies
/// by `1 + depth·c`, keeping the original; a ring modulator multiplies by `c`
/// alone, and the original disappears into its own sidebands.
public struct RingModParams: Codable, Sendable, Equatable {
    /// The carrier's shape. ONE HOME for the numeric index the wire, the
    /// automation surface and the DSP all address it by — the spec table
    /// carries `0...3` as a number (rule 6.0.5: the numeric surface is total),
    /// and `waveform(at:)` is the only place that number becomes a shape.
    public enum Waveform: Int, Sendable, CaseIterable, Equatable {
        /// One frequency, so exactly two sidebands per input partial. Clean,
        /// and the one to reach for first.
        case sine = 0
        /// Odd harmonics falling as 1/n² — a softer, hollower clang.
        case triangle = 1
        /// Odd harmonics falling as 1/n — buzzy and aggressive; every input
        /// partial produces a sideband pair around EACH carrier harmonic.
        case square = 2
        /// All harmonics falling as 1/n — the densest and most chaotic.
        case saw = 3

        /// Beginner-readable name, used by the editor and the wire's teaching
        /// text so a label cannot drift from the index that selects it.
        public var displayName: String {
            switch self {
            case .sine: return "Sine"
            case .triangle: return "Triangle"
            case .square: return "Square"
            case .saw: return "Saw"
            }
        }
    }

    /// Carrier frequency, Hz. Below ~20 Hz this is a TREMOLO; above it, the
    /// sidebands separate and the sound turns metallic.
    public var carrierHz: Double
    /// Dry/wet. 0 is a bit-exact bypass (rule 6.0.7).
    public var mix: Double
    /// Carrier shape as a number: 0 sine, 1 triangle, 2 square, 3 saw.
    /// Discrete — snapped through `waveform(at:)` on init.
    public var waveform: Double
    /// Low-pass applied to the input BEFORE the multiply. The control for
    /// fold-back: the sidebands of a partial you removed cannot fold back.
    public var inputHighCutHz: Double
    /// Right-channel carrier phase offset, degrees. 0 keeps the effect
    /// mono-safe; 180 puts the two carriers in antiphase.
    public var stereoSpreadDeg: Double

    public static let carrierRange: ClosedRange<Double> = 0.5...5_000
    public static let mixRange: ClosedRange<Double> = 0...1
    public static let waveformRange: ClosedRange<Double> = 0...3
    public static let inputHighCutRange: ClosedRange<Double> = 500...20_000
    public static let stereoSpreadRange: ClosedRange<Double> = 0...180

    // MARK: The laws — ONE HOME each, in DAWCore, read by the DSP, the tests,
    // the editor and `fx.describe`'s note text. ⚠️ m39-i shipped with its mode
    // test in TWO places and the two disagreed the moment the rule changed,
    // leaving the filter measuring flat at its own corner. Nothing below is
    // re-derived anywhere else.

    /// The carrier shape a numeric `waveform` value selects — `.rounded()`,
    /// clamped, and non-finite-safe. ⚠️ THE NON-FINITE GUARD IS LOAD-BEARING:
    /// this value reaches an `Int()` conversion, and `Int(Double.nan)` TRAPS. A
    /// field-by-field automation poke bypasses `init`, so the guard has to be
    /// in the law and not only in the initialiser (the `BitCrusherParams.bits`
    /// precedent, same shape, same reason).
    public static func waveform(at value: Double) -> Waveform {
        guard value.isFinite else { return .sine }
        let index = Int(value.clamped(to: waveformRange).rounded())
        return Waveform(rawValue: index) ?? .sine
    }

    /// The right channel's carrier phase offset, in CYCLES (the unit a phase
    /// accumulator actually wants). 180° = half a cycle = antiphase.
    public static func carrierPhaseOffsetCycles(stereoSpreadDeg degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        return degrees.clamped(to: stereoSpreadRange) / 360.0
    }

    /// The two tones one input partial at `inputHz` becomes. THE law of this
    /// effect: neither the input nor the carrier survives, only the pair.
    /// Note `lower` is an ABSOLUTE value — a carrier above the partial does
    /// not produce a negative frequency, it produces the same tone reflected,
    /// which is why sweeping the carrier UP through a note makes the lower
    /// sideband fall to 0 Hz and then rise again.
    public static func sidebandsHz(inputHz: Double,
                                   carrierHz: Double) -> (lower: Double, upper: Double) {
        (abs(inputHz - carrierHz), inputHz + carrierHz)
    }

    /// Where a component at `frequency` actually LANDS once the sample rate
    /// has folded it back below Nyquist. `f + carrier` routinely exceeds
    /// Nyquist, and the folded tone is audible and inharmonic — that fold-back
    /// is HALF THE CHARACTER of a hardware ring modulator and is deliberately
    /// NOT oversampled away (design §6.4.2). `inputHighCutHz` is the control
    /// for anyone who wants less of it.
    public static func foldedHz(_ frequency: Double, sampleRate: Double) -> Double {
        guard frequency.isFinite, sampleRate > 0 else { return 0 }
        let nyquist = sampleRate / 2
        var folded = abs(frequency).truncatingRemainder(dividingBy: sampleRate)
        if folded > nyquist { folded = sampleRate - folded }
        return folded
    }

    public init(carrierHz: Double = 440, mix: Double = 0.5, waveform: Double = 0,
                inputHighCutHz: Double = 20_000, stereoSpreadDeg: Double = 0) {
        // Non-finite guards ahead of every clamp: `clamped(to:)` on a NaN
        // returns the NaN (both comparisons in `min(max(…))` are false against
        // NaN), and these values reach `tan()`, a phase accumulator and an
        // `Int()` conversion on the render thread.
        self.carrierHz = (carrierHz.isFinite ? carrierHz : 440).clamped(to: Self.carrierRange)
        self.mix = (mix.isFinite ? mix : 0.5).clamped(to: Self.mixRange)
        // Discrete: SNAPPED here, so `fx.describe` reports the index actually
        // used rather than the 1.7 someone sent (the `bitCrusher.bits`
        // precedent). The snap routes through the law, never a second copy.
        self.waveform = Double(Self.waveform(at: waveform).rawValue)
        self.inputHighCutHz = (inputHighCutHz.isFinite ? inputHighCutHz : 20_000)
            .clamped(to: Self.inputHighCutRange)
        self.stereoSpreadDeg = (stereoSpreadDeg.isFinite ? stereoSpreadDeg : 0)
            .clamped(to: Self.stereoSpreadRange)
    }

    private enum CodingKeys: String, CodingKey {
        case carrierHz, mix, waveform, inputHighCutHz, stereoSpreadDeg
    }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            carrierHz: try c.decodeIfPresent(Double.self, forKey: .carrierHz) ?? 440,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 0.5,
            waveform: try c.decodeIfPresent(Double.self, forKey: .waveform) ?? 0,
            inputHighCutHz: try c.decodeIfPresent(Double.self, forKey: .inputHighCutHz) ?? 20_000,
            stereoSpreadDeg: try c.decodeIfPresent(Double.self, forKey: .stereoSpreadDeg) ?? 0)
    }
}

/// Parameters for the built-in feedback flanger (m39-j) — one interpolated
/// delay tap per channel, swept by an LFO, with BIPOLAR feedback.
/// `docs/design/2026-09-19-creative-effects.md` §6.3 is the frozen contract.
///
/// WHAT IT ACTUALLY DOES, because "a short delay" hides the interesting part:
/// summing a signal with a delayed copy of itself cancels every frequency whose
/// half-period fits the delay a whole number of times, and reinforces the ones
/// in between. The result is a COMB — a row of evenly spaced notches at
/// `combNotchHz(delayMs:index:)`, i.e. the odd multiples of `1 / (2·delay)`.
/// Sweeping the delay slides the whole comb up and down the spectrum, and that
/// sliding is the jet-plane whoosh. `feedback` recirculates the delayed copy,
/// which sharpens the peaks between the notches into resonances.
///
/// ⛔ **THE SWEEP IS UPWARD-ONLY, and that is the one design decision in this
/// effect** (§6.3.2): `delay = delayMs + depthMs · (0.5 + 0.5·sin φ)`. The
/// obvious bipolar form `delayMs + depthMs·sin φ` goes NEGATIVE whenever
/// `depthMs > delayMs`, and since both ranges are `0.1 … 10` the default
/// surface permits that trivially. Modulating upward from a floor removes the
/// failure mode instead of clamping it (which flattens the sweep bottom and
/// sounds broken) or branching around it (which hides the mistake in the inner
/// loop). It is also how a hardware flanger's manual knob behaves.
/// `sweptDelayMs(phaseRadians:delayMs:depthMs:)` is that law's ONE HOME.
///
/// ⚠️ THROUGH-ZERO FLANGING IS NOT THIS EFFECT and must not be added to it: it
/// needs a second delayed dry path so the two can cross, plus a minimum delay
/// of 0, which `InterpolatedDelayLine` refuses at `prepare()` by design. It is
/// a separate kind if anyone ever wants one.
public struct FlangerParams: Codable, Sendable, Equatable {
    /// LFO speed in Hz. 0.02 is one sweep every 50 seconds; 10 is a warble.
    public var rateHz: Double
    /// How far the sweep travels ABOVE `delayMs`, in ms. The sweep RANGE, never
    /// a half-range: the delay covers `delayMs … delayMs + depthMs`.
    public var depthMs: Double
    /// The sweep's FLOOR, in ms — a hardware flanger's "manual" knob. Sets
    /// where the comb sits when the LFO is at the bottom of its travel, and is
    /// what guarantees the interpolated read never reaches the write head.
    public var delayMs: Double
    /// How much of the delayed signal is fed back in, −0.95 … 0.95. BIPOLAR on
    /// purpose: negative feedback is the hollow/metallic side and is half the
    /// reason to have a flanger at all.
    public var feedback: Double
    /// Dry/wet. 0 is a bit-exact bypass (rule 6.0.7).
    public var mix: Double
    /// Right-channel LFO phase offset from the left, in degrees.
    public var stereoPhaseDeg: Double

    public static let rateRange: ClosedRange<Double> = 0.02...10
    public static let depthRange: ClosedRange<Double> = 0.1...10
    public static let delayRange: ClosedRange<Double> = 0.1...10
    public static let feedbackRange: ClosedRange<Double> = -0.95...0.95
    public static let mixRange: ClosedRange<Double> = 0...1
    public static let stereoPhaseRange: ClosedRange<Double> = 0...180

    /// Delay-line capacity this effect declares to `InterpolatedDelayLine`, in
    /// SECONDS: the largest delay the upward-only sweep can reach, which is
    /// `delayRange.upperBound + depthRange.upperBound` = 20 ms (§6.3.2). ONE
    /// HOME so the engine's `prepare` and the tests that check the sweep's
    /// ceiling cannot disagree about the number.
    public static let lineCapacitySeconds =
        (delayRange.upperBound + depthRange.upperBound) * 0.001

    // MARK: The laws — ONE HOME each, in DAWCore, read by the DSP, the tests
    // and `fx.describe`'s note text. ⚠️ m39-i shipped with its mode test in TWO
    // places and the two disagreed the moment the rule changed; nothing below
    // is re-derived anywhere else.

    /// ⛔ THE §6.3.2 LAW. The delay in ms at LFO phase `phaseRadians`, swept
    /// UPWARD from `delayMs` by up to `depthMs`. The result is always
    /// `>= delayMs >= delayRange.lowerBound`, so it is always positive, needs
    /// no clamp and needs no render-thread branch.
    ///
    /// Non-finite inputs fall back to the defaults rather than propagating: the
    /// return value reaches an `Int()` conversion on the render thread (inside
    /// `InterpolatedDelayLine.tap`) and `Int(Double.nan)` TRAPS. A
    /// field-by-field automation poke bypasses `init`, so the guard has to live
    /// in the law and not only in the initialiser (the `BitCrusherParams.bits`
    /// precedent, same shape, same reason).
    public static func sweptDelayMs(phaseRadians: Double, delayMs: Double,
                                    depthMs: Double) -> Double {
        let floorMs = (delayMs.isFinite ? delayMs : 1.0).clamped(to: delayRange)
        let rangeMs = (depthMs.isFinite ? depthMs : 3.0).clamped(to: depthRange)
        guard phaseRadians.isFinite else { return floorMs }
        return floorMs + rangeMs * (0.5 + 0.5 * sin(phaseRadians))
    }

    /// Where the comb's notches land for a given delay, in Hz. A delayed copy
    /// summed with its source cancels at the ODD multiples of `1 / (2·delay)`
    /// — `index` 0 is the first (lowest) notch, 1 the second, and so on. The
    /// peaks sit halfway between, at the even multiples.
    ///
    /// ⚠️ This is the response at `feedback == 0` and `mix == 0.5`, which is
    /// where the nulls are complete; feedback deepens the peaks between the
    /// notches rather than moving them, and a mix away from 0.5 makes the
    /// notches shallower without shifting them.
    public static func combNotchHz(delayMs: Double, index: Int) -> Double {
        guard delayMs.isFinite, delayMs > 0, index >= 0 else { return 0 }
        return Double(2 * index + 1) / (2 * delayMs * 0.001)
    }

    /// The right channel's LFO phase offset in RADIANS (the unit a phase
    /// accumulator actually wants). 180° = half a cycle = the two channels
    /// sweeping in opposition.
    public static func stereoPhaseOffsetRadians(stereoPhaseDeg degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        return degrees.clamped(to: stereoPhaseRange) * .pi / 180
    }

    /// The effect's steady-state gain on a CONSTANT input — the number that
    /// explains why raising `feedback` makes the effect louder, and the one the
    /// demo's loudness note and the engine's DC test both read.
    ///
    /// The wet path is the recirculating comb `1 / (1 − feedback)` evaluated at
    /// DC, blended by `mix`: `(1 − mix) + mix / (1 − feedback)`. At the
    /// defaults (feedback 0.5, mix 0.5) that is 1.5; at feedback 0 it is
    /// exactly 1; at feedback −0.5 it is 0.833. Positive feedback reinforces,
    /// negative feedback partially cancels — that asymmetry is real and audible
    /// and is why the param's note warns about level.
    public static func dcGain(feedback: Double, mix: Double) -> Double {
        let f = (feedback.isFinite ? feedback : 0).clamped(to: feedbackRange)
        let m = (mix.isFinite ? mix : 0).clamped(to: mixRange)
        return (1 - m) + m / (1 - f)
    }

    public init(rateHz: Double = 0.3, depthMs: Double = 3, delayMs: Double = 1.0,
                feedback: Double = 0.5, mix: Double = 0.5, stereoPhaseDeg: Double = 90) {
        // Non-finite guards ahead of every clamp: `clamped(to:)` on a NaN
        // returns the NaN (both comparisons in `min(max(…))` are false against
        // NaN), and these values reach a phase accumulator, a feedback
        // multiply and an `Int()` conversion on the render thread.
        self.rateHz = (rateHz.isFinite ? rateHz : 0.3).clamped(to: Self.rateRange)
        self.depthMs = (depthMs.isFinite ? depthMs : 3).clamped(to: Self.depthRange)
        self.delayMs = (delayMs.isFinite ? delayMs : 1.0).clamped(to: Self.delayRange)
        self.feedback = (feedback.isFinite ? feedback : 0.5).clamped(to: Self.feedbackRange)
        self.mix = (mix.isFinite ? mix : 0.5).clamped(to: Self.mixRange)
        self.stereoPhaseDeg = (stereoPhaseDeg.isFinite ? stereoPhaseDeg : 90)
            .clamped(to: Self.stereoPhaseRange)
    }

    private enum CodingKeys: String, CodingKey {
        case rateHz, depthMs, delayMs, feedback, mix, stereoPhaseDeg
    }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rateHz: try c.decodeIfPresent(Double.self, forKey: .rateHz) ?? 0.3,
            depthMs: try c.decodeIfPresent(Double.self, forKey: .depthMs) ?? 3,
            delayMs: try c.decodeIfPresent(Double.self, forKey: .delayMs) ?? 1.0,
            feedback: try c.decodeIfPresent(Double.self, forKey: .feedback) ?? 0.5,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 0.5,
            stereoPhaseDeg: try c.decodeIfPresent(Double.self, forKey: .stereoPhaseDeg) ?? 90)
    }
}

/// 8-line Feedback Delay Network with Householder mixing, per-line two-band
/// absorption and small independent length modulation (m39-l). Ships ALONGSIDE
/// the Freeverb `.reverb`, which is untouched and not deprecated.
/// `docs/design/2026-09-19-creative-effects.md` §5/§6.2 is the frozen contract.
///
/// The difference that justifies a second kind, in one line: this one has a
/// SIZE. `.reverb`'s `roomSize` scales comb FEEDBACK — its comb lengths are
/// compile-time constants — so its room has exactly one shape forever.
///
/// ⚠️ EVERY DERIVED NUMBER THE DSP NEEDS IS A STATIC FUNCTION BELOW, and each
/// has exactly ONE home. m39-i shipped its mode rule in two places and the two
/// disagreed the moment the rule changed; the engine, the tests, the demo note
/// and `fx.describe` all read the functions here and none re-derives them.
public struct HallReverbParams: Codable, Sendable, Equatable {
    /// Dry/wet. 0 is a bit-exact bypass (rule 6.0.7).
    public var mix: Double
    /// RT60 at the 1 kHz reference band, in seconds — the time the tail takes
    /// to fall 60 dB. This is a real decay time, not a feedback number.
    public var decaySeconds: Double
    /// Line-length scale in metres — AN ACTUAL SIZE. Lines are MAX-sized at
    /// `prepare()` for `sizeRange.upperBound`, so moving this is arithmetic on
    /// a read offset and never an allocation.
    public var sizeMeters: Double
    /// Gap between the dry sound and the first wet arrival, in ms. Read
    /// through `InterpolatedDelayLine`, so unlike `reverb.preDelayMs` (an
    /// integer read offset) this one moves smoothly.
    public var preDelayMs: Double
    /// M/S width on the WET signal only. 1 = as the tank produced it.
    public var width: Double
    /// Input allpass density — how smeared the early part is before the tank.
    public var diffusion: Double
    /// −1 close/early … +1 far/diffuse. An equal-power crossfade between the
    /// diffused pre-delayed input (early) and the tank output (late).
    public var earlyLateBalance: Double
    /// RT60 multiplier below `lowCrossoverHz`. 1 = the same as the mid band.
    public var lowDecayMultiplier: Double
    /// RT60 multiplier above `highCrossoverHz`. Default 0.5 models air
    /// absorption — this is what stops the tail sounding like a metal tank.
    public var highDecayMultiplier: Double
    public var lowCrossoverHz: Double
    public var highCrossoverHz: Double
    /// Anti-metallic tail modulation rate, shared by all 8 lines.
    public var modRateHz: Double
    /// Anti-metallic tail modulation depth, in ms. Ceiling 5 ms is deliberate
    /// (§5.5): past a few ms on a long tail it stops sounding like air and
    /// starts sounding like chorus, which is a different effect we also ship.
    public var modDepthMs: Double
    /// >= 0.5 = infinite hold. Discrete: drive it with a `hold` automation
    /// lane, not a ramp.
    public var freeze: Double

    public static let mixRange: ClosedRange<Double> = 0...1
    public static let decayRange: ClosedRange<Double> = 0.1...20
    public static let sizeRange: ClosedRange<Double> = 1...60
    public static let preDelayRange: ClosedRange<Double> = 0...250
    public static let widthRange: ClosedRange<Double> = 0...1.2
    public static let diffusionRange: ClosedRange<Double> = 0...1
    public static let earlyLateRange: ClosedRange<Double> = -1...1
    public static let lowDecayMultiplierRange: ClosedRange<Double> = 0.25...4
    public static let highDecayMultiplierRange: ClosedRange<Double> = 0.1...1
    public static let lowCrossoverRange: ClosedRange<Double> = 50...1_000
    public static let highCrossoverRange: ClosedRange<Double> = 1_000...16_000
    public static let modRateRange: ClosedRange<Double> = 0.05...5
    public static let modDepthRange: ClosedRange<Double> = 0...5
    public static let freezeRange: ClosedRange<Double> = 0...1

    // MARK: - The laws. ONE HOME each.

    /// Lines in the network. 8, not "8–16" — a line count is a preallocation,
    /// and 16 can be APPENDED later as a `density` param without moving a
    /// single automation slot (§5.1).
    public static let lineCount = 8

    /// Speed of sound in dry air at 20 °C, m/s. This is the whole reason
    /// `sizeMeters` is a distance rather than an abstract knob: a line length
    /// is the time sound takes to cross the room.
    public static let speedOfSoundMetersPerSecond = 343.0

    /// Per-line length ratios, applied to `sizeMeters / speedOfSound`.
    ///
    /// Derived from eight primes (17 19 23 29 31 37 41 43) divided by their
    /// mean, 30 — so the ratios are mutually as incommensurate as the primes
    /// are (modes do not coincide, which is what makes the tank sound dense
    /// rather than pitched) AND their mean is EXACTLY 1, which makes
    /// `sizeMeters / 343` the mean line length in seconds: a number a reader
    /// can check by hand.
    ///
    /// ⚠️ §6.2.3 says "prime-ish line lengths". It cannot mean prime SAMPLE
    /// COUNTS: `sizeMeters` is continuous and the taps are fractionally
    /// interpolated, so a line's length in samples is a real number that moves
    /// smoothly with the knob. What is prime-ish is the set of RATIOS.
    public static let lineLengthRatios: [Double] = [
        17.0 / 30, 19.0 / 30, 23.0 / 30, 29.0 / 30,
        31.0 / 30, 37.0 / 30, 41.0 / 30, 43.0 / 30,
    ]

    /// Length of line `index` in SECONDS at a given size. The mean over the
    /// eight lines is exactly `sizeMeters / speedOfSound`.
    public static func lineLengthSeconds(sizeMeters: Double, index: Int) -> Double {
        guard index >= 0, index < lineCount else { return 0 }
        let size = (sizeMeters.isFinite ? sizeMeters : 12).clamped(to: sizeRange)
        return size / speedOfSoundMetersPerSecond * lineLengthRatios[index]
    }

    /// Capacity each tank line declares to `InterpolatedDelayLine`, in
    /// SECONDS: the LONGEST line at the LARGEST size, plus the largest upward
    /// modulation excursion. Derived, never a literal, so the ratios above and
    /// this number cannot drift apart.
    ///
    /// ⚠️ §6.2.3 says "Declared capacity: 0.100 s … separate from the line
    /// storage itself", which describes a different topology (a bulk integer
    /// line plus a short modulated section). Here each line IS one
    /// `InterpolatedDelayLine` and the modulation is added to its tap, so
    /// 0.100 s has no referent. Filed as errata E7.
    public static let lineCapacitySeconds =
        sizeRange.upperBound / speedOfSoundMetersPerSecond * (lineLengthRatios.max() ?? 1)
        + modDepthRange.upperBound * 0.001

    /// The SMALLEST delay any tank line will ever be tapped at — the shortest
    /// line at the smallest size. It is the invariant the shared delay line
    /// checks ONCE, at `prepare()`, and it is a real number rather than a
    /// literal so that changing `lineLengthRatios` or `sizeRange` cannot leave
    /// a stale floor behind.
    ///
    /// ⚠️ THE FLOOR THE HOME REQUIRES IS INTERPOLATION-DEPENDENT: 1 sample for
    /// `.linear`, **2 for `.cubicHermite`**, whose stencil reads one sample
    /// NEWER than the tap. (§4.1's table states a flat "1 sample"; its own
    /// 2026-09-19 addendum is the correction.) The tank uses `.cubicHermite`
    /// and this floor is 72.9 samples at 44.1 kHz and 79.3 at 48 kHz, so the
    /// 2-sample requirement is met with three orders of magnitude to spare —
    /// a refusal would need a sample rate under about 1 kHz.
    public static func minimumLineDelaySamples(sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return lineLengthSeconds(sizeMeters: sizeRange.lowerBound, index: 0) * sampleRate
    }

    /// Capacity the PRE-DELAY line declares, in SECONDS — the parameter's
    /// ceiling plus the one-sample floor below, rounded up to a round number.
    public static let preDelayCapacitySeconds = preDelayRange.upperBound * 0.001 + 0.010

    /// ⛔ THE PRE-DELAY FLOOR LAW. `preDelayRange.lowerBound` is 0, and
    /// `InterpolatedDelayLine.prepare()` REFUSES `minDelaySamples: 0` by
    /// design (§4.1) — a refused line is silent, so a naive wiring would make
    /// the whole effect a permanent bit-exact passthrough at the default-ish
    /// setting of `preDelayMs: 0`, reporting success the whole time. The fix
    /// is one fixed sample of offset on the tap: the line is read at
    /// `preDelayMs · sr/1000 + 1`, the declared minimum is 1, and the cost is
    /// ~21 µs at 48 kHz, which is below the resolution of anything audible.
    public static let preDelayFloorSamples = 1.0

    /// Where the pre-delay line is tapped, in SAMPLES, for a given setting.
    public static func preDelaySamples(preDelayMs: Double, sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return preDelayFloorSamples }
        let ms = (preDelayMs.isFinite ? preDelayMs : 20).clamped(to: preDelayRange)
        return ms * 0.001 * sampleRate + preDelayFloorSamples
    }

    /// ⛔ THE UPWARD-ONLY MODULATION LAW, the §6.3.2 rule applied to the tank.
    /// The tail modulation is added to the line length, never subtracted: a
    /// bipolar excursion would drive the shortest line (1.65 ms at
    /// `sizeRange.lowerBound`) below the 5 ms modulation ceiling and into the
    /// write head, which `prepare()` would then refuse — silently, because a
    /// refused line is a silent one. Upward-only removes the failure mode
    /// instead of clamping it, and costs a mean offset of `depth/2`
    /// (0.075 ms at the default depth).
    ///
    /// Non-finite inputs fall back to defaults rather than propagating: the
    /// result reaches `Int()` inside `InterpolatedDelayLine.tap`, and
    /// `Int(Double.nan)` TRAPS.
    public static func modulatedDelaySamples(baseSamples: Double, depthMs: Double,
                                             phaseRadians: Double,
                                             sampleRate: Double) -> Double {
        let base = baseSamples.isFinite ? baseSamples : 1
        guard sampleRate.isFinite, sampleRate > 0 else { return base }
        let depth = (depthMs.isFinite ? depthMs : 0.15).clamped(to: modDepthRange)
        guard phaseRadians.isFinite else { return base }
        return base + depth * 0.001 * sampleRate * (0.5 + 0.5 * sin(phaseRadians))
    }

    /// ⛔ THE ANTI-METALLIC LAW (§5.5). Each line's LFO starts at its own
    /// phase, spread by the golden ratio's fractional part — a low-discrepancy
    /// sequence, which stays well spread for ANY prefix length. One shared
    /// RATE, eight independent PHASES, exactly as the contract says.
    ///
    /// Why low-discrepancy rather than the obvious `i · 2π/N`: §5.1 reserves
    /// the right to append a `density` parameter taking the network from 8
    /// lines to 16, and this spread lets that happen without re-phasing a
    /// single line that already shipped. `i · 2π/N` is tied to N.
    /// ⚠️ It is NOT about avoiding antiphase pairs — measured, this spread
    /// produces pairs 0.175 rad from antiphase, and that is fine: two lines
    /// drifting in opposition are maximally decorrelated. The failure this
    /// law prevents is all eight sharing ONE phase.
    ///
    /// Why it matters, stated so it is not mistaken for polish: a fixed-length
    /// recirculating network rings at a fixed set of modal frequencies, and a
    /// listener hears that as a metallic, pitched tail. Sliding each line's
    /// length slowly and independently smears those modes across a band, and
    /// the smearing IS the fix.
    public static func modulationPhaseOffsetRadians(line index: Int) -> Double {
        guard index >= 0, index < lineCount else { return 0 }
        let golden = 0.618_033_988_749_894_8
        let fraction = (Double(index) * golden).truncatingRemainder(dividingBy: 1)
        return 2 * Double.pi * fraction
    }

    /// The Householder reflection's scale factor, `2 / N`. The mixing step is
    /// `y_i = x_i − scale · Σx` — a dot product plus a scaled subtraction,
    /// `O(N)` per sample, not an N×N multiply — and the matrix
    /// `I − (2/N)·11ᵀ` is orthogonal, so the mix neither adds nor removes
    /// energy. Every claim about stability below rests on that.
    public static let householderScale = 2.0 / Double(lineCount)

    /// ⛔ THE RT60 LAW. Per-line feedback gain for a band whose RT60 is
    /// `rt60Seconds`: `10^(−3 · lineLengthSeconds / rt60)`. That is the
    /// standard relation — a signal recirculating with this gain loses 60 dB
    /// in exactly `rt60` seconds — and it is why `decaySeconds` means decibels
    /// of decay rather than an arbitrary feedback number.
    ///
    /// Clamped strictly below 1: at `freeze` the DSP substitutes unity
    /// deliberately, and everywhere else a gain of exactly 1 would be a
    /// network that never decays.
    public static func lineGain(lineLengthSeconds: Double, rt60Seconds: Double) -> Double {
        guard lineLengthSeconds.isFinite, lineLengthSeconds > 0 else { return 0 }
        let rt60 = (rt60Seconds.isFinite ? rt60Seconds : 1.8)
        guard rt60 > 0 else { return 0 }
        return min(pow(10.0, -3.0 * lineLengthSeconds / rt60), 0.999_9)
    }

    /// RT60 in a band, given the mid-band decay and that band's multiplier.
    public static func bandRT60Seconds(decaySeconds: Double, multiplier: Double) -> Double {
        let decay = (decaySeconds.isFinite ? decaySeconds : 1.8).clamped(to: decayRange)
        let m = (multiplier.isFinite ? multiplier : 1)
        return max(decay * m, 0.01)
    }

    /// One-pole coefficient for a shelf corner: `1 − exp(−2π f / sr)`, always
    /// in (0, 1), so a shelf built on it is unconditionally stable no matter
    /// what the per-sample interpolation does between two coefficient sets.
    /// ⭐ That is why the shelves are FIRST-ORDER and not biquads: interpolating
    /// between two stable biquad coefficient sets can pass through an unstable
    /// one, and this network idles for twenty seconds at a time.
    public static func onePoleCoefficient(cornerHz: Double, sampleRate: Double) -> Double {
        guard cornerHz.isFinite, sampleRate.isFinite, sampleRate > 0 else { return 0.5 }
        let corner = max(min(cornerHz, sampleRate * 0.49), 1.0)
        return 1 - exp(-2 * Double.pi * corner / sampleRate)
    }

    /// Equal-power early/late crossfade gains for `earlyLateBalance`, so the
    /// blend does not dip in the middle the way a linear crossfade would.
    /// −1 = early only, +1 = late only, 0 = both at 0.7071.
    public static func earlyLateGains(balance: Double) -> (early: Double, late: Double) {
        let b = (balance.isFinite ? balance : 0).clamped(to: earlyLateRange)
        let angle = (b + 1) * 0.5 * Double.pi * 0.5
        return (cos(angle), sin(angle))
    }

    /// The EXPECTED first wet arrival, in seconds, for a given size and
    /// pre-delay: the pre-delay plus the SHORTEST line. This is the closed
    /// form the size test measures against — doubling `sizeMeters` must
    /// double the part of it that is not pre-delay.
    public static func firstArrivalSeconds(sizeMeters: Double, preDelayMs: Double) -> Double {
        let pre = (preDelayMs.isFinite ? preDelayMs : 20).clamped(to: preDelayRange) * 0.001
        return pre + lineLengthSeconds(sizeMeters: sizeMeters, index: 0)
    }

    /// `freeze` is DISCRETE on a continuous surface (the `bitCrusher.antiAlias`
    /// precedent): anything >= 0.5 is on.
    public static func isFrozen(_ value: Double) -> Bool {
        value.isFinite && value >= 0.5
    }

    public init(mix: Double = 0.3, decaySeconds: Double = 1.8, sizeMeters: Double = 12,
                preDelayMs: Double = 20, width: Double = 1.0, diffusion: Double = 0.7,
                earlyLateBalance: Double = 0, lowDecayMultiplier: Double = 1.0,
                highDecayMultiplier: Double = 0.5, lowCrossoverHz: Double = 200,
                highCrossoverHz: Double = 6_000, modRateHz: Double = 0.3,
                modDepthMs: Double = 0.15, freeze: Double = 0) {
        // Non-finite guards ahead of every clamp: `clamped(to:)` on a NaN
        // returns the NaN, and these values reach `pow`, `exp`, a phase
        // accumulator and an `Int()` conversion on the render thread.
        self.mix = (mix.isFinite ? mix : 0.3).clamped(to: Self.mixRange)
        self.decaySeconds = (decaySeconds.isFinite ? decaySeconds : 1.8)
            .clamped(to: Self.decayRange)
        self.sizeMeters = (sizeMeters.isFinite ? sizeMeters : 12).clamped(to: Self.sizeRange)
        self.preDelayMs = (preDelayMs.isFinite ? preDelayMs : 20)
            .clamped(to: Self.preDelayRange)
        self.width = (width.isFinite ? width : 1.0).clamped(to: Self.widthRange)
        self.diffusion = (diffusion.isFinite ? diffusion : 0.7).clamped(to: Self.diffusionRange)
        self.earlyLateBalance = (earlyLateBalance.isFinite ? earlyLateBalance : 0)
            .clamped(to: Self.earlyLateRange)
        self.lowDecayMultiplier = (lowDecayMultiplier.isFinite ? lowDecayMultiplier : 1.0)
            .clamped(to: Self.lowDecayMultiplierRange)
        self.highDecayMultiplier = (highDecayMultiplier.isFinite ? highDecayMultiplier : 0.5)
            .clamped(to: Self.highDecayMultiplierRange)
        self.lowCrossoverHz = (lowCrossoverHz.isFinite ? lowCrossoverHz : 200)
            .clamped(to: Self.lowCrossoverRange)
        self.highCrossoverHz = (highCrossoverHz.isFinite ? highCrossoverHz : 6_000)
            .clamped(to: Self.highCrossoverRange)
        self.modRateHz = (modRateHz.isFinite ? modRateHz : 0.3).clamped(to: Self.modRateRange)
        self.modDepthMs = (modDepthMs.isFinite ? modDepthMs : 0.15)
            .clamped(to: Self.modDepthRange)
        self.freeze = (freeze.isFinite ? freeze : 0).clamped(to: Self.freezeRange)
    }

    private enum CodingKeys: String, CodingKey {
        case mix, decaySeconds, sizeMeters, preDelayMs, width, diffusion
        case earlyLateBalance, lowDecayMultiplier, highDecayMultiplier
        case lowCrossoverHz, highCrossoverHz, modRateHz, modDepthMs, freeze
    }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 0.3,
            decaySeconds: try c.decodeIfPresent(Double.self, forKey: .decaySeconds) ?? 1.8,
            sizeMeters: try c.decodeIfPresent(Double.self, forKey: .sizeMeters) ?? 12,
            preDelayMs: try c.decodeIfPresent(Double.self, forKey: .preDelayMs) ?? 20,
            width: try c.decodeIfPresent(Double.self, forKey: .width) ?? 1.0,
            diffusion: try c.decodeIfPresent(Double.self, forKey: .diffusion) ?? 0.7,
            earlyLateBalance: try c.decodeIfPresent(Double.self, forKey: .earlyLateBalance) ?? 0,
            lowDecayMultiplier:
                try c.decodeIfPresent(Double.self, forKey: .lowDecayMultiplier) ?? 1.0,
            highDecayMultiplier:
                try c.decodeIfPresent(Double.self, forKey: .highDecayMultiplier) ?? 0.5,
            lowCrossoverHz: try c.decodeIfPresent(Double.self, forKey: .lowCrossoverHz) ?? 200,
            highCrossoverHz:
                try c.decodeIfPresent(Double.self, forKey: .highCrossoverHz) ?? 6_000,
            modRateHz: try c.decodeIfPresent(Double.self, forKey: .modRateHz) ?? 0.3,
            modDepthMs: try c.decodeIfPresent(Double.self, forKey: .modDepthMs) ?? 0.15,
            freeze: try c.decodeIfPresent(Double.self, forKey: .freeze) ?? 0)
    }
}

/// Tape echo (m39-n), FREE-MS ONLY — a fractional delay line read through a
/// wobbling tape transport, with the repeat path saturated and rolled off.
/// `docs/design/2026-09-19-creative-effects.md` §4.1 is the frozen contract for
/// the delay line this kind drives (capacity 4.0 s, `.cubicHermite`, and the
/// denormal flush that belongs to the CALLER).
///
/// ⚠️ **CITATION NOT FOUND, RECORDED RATHER THAN GUESSED AROUND (m39-n).** The
/// brief for this item cited "the `.tapeDelay` contract in §11" of that design
/// document. **§11 has no such contract**: §11.0 is the file set for one new
/// kind, §11.0.1 the `CopilotCatalog` ruling, §11.0.2 the id allocation and
/// §11.1 the leg ordering (where `m39-aa` says only "free-ms mode may ship in
/// Leg 2"). Every `tapeDelay` mention in the document is listed in this item's
/// close record; none is a parameter table. So the surface below is derived
/// from what the document DOES fix — §4.1's capacity/interpolation/flush
/// contract, §2.1's rank-6 row, §8.2's "free-ms is ungated" row — plus rule
/// 6.0's inherited laws, and NOT from the reverb report's 17-param
/// `TapeDelayParams` sketch (§10.2 there), which is a CLAIM the design never
/// adopted. `character`, `crossFeedback`, multi-tap, `diffusion`, ducking and
/// `sync`/`division` are all deliberately absent.
///
/// ⛔ **THE MODULATION LIVES HERE, NOT IN THE DELAY LINE** (§4.1): the shared
/// home has no depth and no rate on purpose, so that four callers can share it.
///
/// ⛔ **THE SWEEP IS DOWNWARD-ONLY, AND IT IS THE FLANGER'S LAW MIRRORED.**
/// `FlangerParams.sweptDelayMs` modulates UPWARD from a floor because a floor
/// at 0 would read the write head. Here the risk is at the OTHER end: `timeMs`
/// reaches `timeRange.upperBound` = 4000 ms, which IS the declared line
/// capacity, so a bipolar wobble at maximum time would tap PAST the end of the
/// line — and §4.1 froze that there is no render-thread bounds check and no
/// clamping. Modulating downward from `timeMs` removes the failure mode instead
/// of clamping it (which would flatten the top of every wow cycle and sound
/// broken) or branching around it (which would hide the mistake in the inner
/// loop). Consequence: the delay always lies in
/// `[timeMs - wowDepthMs - flutterDepthMs, timeMs]`, the mean delay sits at
/// most 4.5 ms early, and — because a bounded periodic offset has zero average
/// slope over a cycle — there is NO net pitch bias. Only the sign convention
/// changed, not the sound.
public struct TapeDelayParams: Codable, Sendable, Equatable {
    /// Nominal delay time in ms — the time with the transport running true.
    /// The actual read position is this MINUS the wow/flutter offset.
    public var timeMs: Double
    /// How much of each repeat is re-recorded to tape. Bounded well under the
    /// unity that makes this structure diverge (the `.delay` m39-k ceiling,
    /// measured; E11 says 1.0 diverges and 0.999 does not).
    public var feedback: Double
    /// Dry/wet. 0 is a bit-exact bypass (rule 6.0.7).
    public var mix: Double
    /// How far the motor drifts, in ms — the PEAK-TO-PEAK excursion of the slow
    /// wobble. The pitch deviation it causes is `wowCents(depthMs:rateHz:)`.
    public var wowDepthMs: Double
    /// How fast the motor drifts, in Hz. The classic wow band is 0.5–2 Hz.
    public var wowRateHz: Double
    /// How unstable the capstan is, in ms peak-to-peak — the FAST wobble, at
    /// the two fixed rates `flutterRateHz` / `flutterSecondaryRateHz`.
    public var flutterDepthMs: Double
    /// How hard the repeat path is driven into tape saturation. 0 is EXACTLY
    /// linear (the shaper is crossfaded out, not merely gentle).
    public var saturationDrive: Double
    /// One-pole low-pass in the RECORD path — the head/tape HF loss. Unlike
    /// `.delay`'s feedback-only filter, this one colours the FIRST repeat too,
    /// because on a real machine the signal was already on tape by then.
    public var highCutHz: Double

    /// ⚠️ THE FLOOR IS 20 ms, NOT 1 ms, AND IT IS LOAD-BEARING: it must exceed
    /// `wowDepthRange.upperBound + flutterDepthRange.upperBound` (9 ms) so that
    /// the downward-only sweep can never reach the write head.
    /// `minimumDelayInvariantHolds` in `TapeDelayParamsTests` pins that, so
    /// widening a depth range without widening this floor fails loudly.
    /// Shorter echoes are `.delay`'s (from 1 ms) or `.flanger`'s territory.
    public static let timeRange: ClosedRange<Double> = 20...4_000
    /// 0.999, not 1.0 — E11's measured ceiling on `.delay`, adopted verbatim
    /// rather than re-litigated. Tape self-oscillation is reached by DRIVE
    /// (the saturator bends a runaway into a howl), not by an unstable loop
    /// gain: at drive 0 this structure is linear and a gain of 1.0 diverges
    /// exactly as it does in `.delay`.
    public static let feedbackRange: ClosedRange<Double> = 0...0.999
    public static let mixRange: ClosedRange<Double> = 0...1
    public static let wowDepthRange: ClosedRange<Double> = 0...8
    public static let wowRateRange: ClosedRange<Double> = 0.1...3
    public static let flutterDepthRange: ClosedRange<Double> = 0...1
    public static let saturationRange: ClosedRange<Double> = 0...1
    public static let highCutRange: ClosedRange<Double> = 500...20_000

    /// Flutter's two components, in Hz. TWO, at an irrational-ish ratio, so the
    /// sum never repeats on a musical timescale: a single sine at 8 Hz reads as
    /// a deliberate vibrato, which is the opposite of "the transport is not
    /// quite steady". Both sit in the 6–12 Hz flutter band. They are CONSTANTS
    /// and not parameters: appending a rate param later is always safe
    /// (rule 6.0.1's corollary — never reserve a slot), and nothing about the
    /// sound needs them movable in v1.
    public static let flutterRateHz = 7.3
    public static let flutterSecondaryRateHz = 11.7

    /// Delay-line capacity this effect declares to `InterpolatedDelayLine`, in
    /// SECONDS (§4.1: "tape delay 4.0", and the home has NO default for this
    /// on purpose). ONE HOME so the engine's `prepare` and the tests that check
    /// the longest echo cannot disagree about the number.
    public static let lineCapacitySeconds = timeRange.upperBound * 0.001

    // MARK: The laws — ONE HOME each, in DAWCore, read by the DSP, the tests,
    // the demo note and `fx.describe`. Nothing below is re-derived elsewhere.

    /// The shallowest delay this effect can ever ask the line for, in ms — the
    /// invariant `prepare()` declares to `InterpolatedDelayLine` and the home
    /// checks once, off the render thread.
    ///
    /// ⭐⭐ **THIS NUMBER IS WHY THE §4.1 ADDENDUM EXISTS.** The capability
    /// table in §4.1 states the minimum-delay floor as "1 sample" flatly; that
    /// is true for `.linear` and FALSE for `.cubicHermite`, whose stencil reads
    /// `whole - 1` — one sample NEWER than the tap — and therefore needs 2.
    /// `.cubicHermite` is the interpolation §4.1 recommends to THIS effect by
    /// name. A literal `minDelaySamples: 1` here is refused at `prepare()`
    /// (confirmed by this author, m39-n). Deriving the floor from the ranges
    /// instead makes the whole question moot: at 48 kHz this is 528 samples.
    public static let minimumDelayMs =
        timeRange.lowerBound - wowDepthRange.upperBound - flutterDepthRange.upperBound

    /// `minimumDelayMs` in samples at a given rate — the exact argument for
    /// `InterpolatedDelayLine.prepare(sampleRate:minDelaySamples:channelCount:)`.
    public static func minimumDelaySamples(sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return minimumDelayMs }
        return minimumDelayMs * 0.001 * sampleRate
    }

    /// ⛔ THE DOWNWARD-ONLY LAW. How far EARLY the tape is reading, in ms, at
    /// the given transport phases. Always in `[0, wowDepthMs + flutterDepthMs]`
    /// and therefore always subtractable from a `timeMs` that is at least
    /// `timeRange.lowerBound`.
    ///
    /// Non-finite inputs fall back to defaults rather than propagating: the
    /// result reaches an `Int()` conversion on the render thread inside
    /// `InterpolatedDelayLine.tap`, and `Int(Double.nan)` TRAPS. A
    /// field-by-field automation poke bypasses `init`, so the guard lives in
    /// the law and not only in the initialiser (the `BitCrusherParams.bits`
    /// precedent, and `FlangerParams.sweptDelayMs`'s, same shape).
    public static func transportOffsetMs(wowPhase: Double, flutterPhaseA: Double,
                                         flutterPhaseB: Double, wowDepthMs: Double,
                                         flutterDepthMs: Double) -> Double {
        let wowD = (wowDepthMs.isFinite ? wowDepthMs : 2.5).clamped(to: wowDepthRange)
        let flutD = (flutterDepthMs.isFinite ? flutterDepthMs : 0.25)
            .clamped(to: flutterDepthRange)
        let w = wowPhase.isFinite ? wowPhase : 0
        let a = flutterPhaseA.isFinite ? flutterPhaseA : 0
        let b = flutterPhaseB.isFinite ? flutterPhaseB : 0
        // Each term is a unipolar 0…1 shape scaled by its depth, so the sum is
        // bounded by wowD + flutD with no clamp and no render-thread branch.
        let wow = wowD * (0.5 + 0.5 * sin(w))
        let flutter = flutD * (0.5 + 0.25 * (sin(a) + sin(b)))
        return wow + flutter
    }

    /// The delay the line is actually tapped at, in ms.
    public static func readDelayMs(timeMs: Double, wowPhase: Double, flutterPhaseA: Double,
                                   flutterPhaseB: Double, wowDepthMs: Double,
                                   flutterDepthMs: Double) -> Double {
        let base = (timeMs.isFinite ? timeMs : 350).clamped(to: timeRange)
        return base - transportOffsetMs(wowPhase: wowPhase, flutterPhaseA: flutterPhaseA,
                                        flutterPhaseB: flutterPhaseB, wowDepthMs: wowDepthMs,
                                        flutterDepthMs: flutterDepthMs)
    }

    /// ⭐ THE MEASURABLE CLAIM. Peak pitch deviation of the wow, in CENTS.
    ///
    /// A delay line read at `d(t)` replays at a pitch ratio of `1 - d'(t)`.
    /// With the law above the wow term is `D·(0.5 + 0.5·sin 2πft)`, whose slope
    /// peaks at `π·f·D` (the amplitude about the mean is `D/2`, not `D` — the
    /// depth is PEAK-TO-PEAK). So the peak ratio deviation is `π·f·D` with `D`
    /// in seconds, and
    ///     cents = 1200·log2(1 + π·f·D/1000)
    /// with `D` in ms. It does NOT depend on `timeMs`: the wobble is an
    /// absolute excursion, so a 20 ms slapback and a 2 s echo wow by the same
    /// musical interval. At the defaults (2.5 ms, 0.8 Hz) that is 10.8 cents —
    /// a tenth of a semitone, clearly audible on a sustained note and not on a
    /// drum hit. At the maximum (8 ms, 3 Hz) it is 125.8 cents, more than a
    /// semitone, which is a broken machine and is the point of the top of the
    /// range.
    ///
    /// ⚠️ THIS IS THE UPWARD PEAK, AND THE WOBBLE IS NOT SYMMETRIC. Because the
    /// ratio is `1 - d'(t)`, the downward peak is `-1200·log2(1 - π·f·D/1000)`,
    /// which is always the LARGER of the two: 10.9 cents at the defaults and
    /// 135.7 at the maximum. That asymmetry is arithmetic, not a defect — it is
    /// why `DAWEngineTests/TapeDelayTests` L3 measures +40.32/−41.28 cents at
    /// 5 ms / 1.5 Hz against a single closed-form figure of 40.32. One number
    /// goes on the wire (the upward peak) because an agent asking for "about a
    /// tenth of a semitone of wobble" wants one number, and the two branches
    /// differ by under 1 % at every setting a musician will choose.
    public static func wowCents(depthMs: Double, rateHz: Double) -> Double {
        let d = (depthMs.isFinite ? depthMs : 0).clamped(to: wowDepthRange) * 0.001
        let f = (rateHz.isFinite ? rateHz : 0.8).clamped(to: wowRateRange)
        return 1200 * log2(1 + Double.pi * f * d)
    }

    /// Peak pitch deviation of the FLUTTER, in cents — the same derivation over
    /// the two-component term `D·(0.5 + 0.25·(sin 2πf₁t + sin 2πf₂t))`, whose
    /// slope peaks at `0.25·D·2π(f₁+f₂) = 0.5π·D·(f₁+f₂)` when both components
    /// happen to align. At the default 0.25 ms that is 12.9 cents; at the 1 ms
    /// maximum, 50.9 cents (upward; the downward peak is 52.5, the same
    /// asymmetry `wowCents` documents).
    public static func flutterCents(depthMs: Double) -> Double {
        let d = (depthMs.isFinite ? depthMs : 0).clamped(to: flutterDepthRange) * 0.001
        return 1200 * log2(1 + 0.5 * Double.pi * d * (flutterRateHz + flutterSecondaryRateHz))
    }

    /// Largest linear gain the record-path shaper drives with, at
    /// `saturationDrive == 1`. 6 puts the knee at about -15.6 dBFS.
    public static let driveCeiling = 6.0

    /// The drive gain `saturationDrive` selects. 1 at 0 (no drive at all).
    public static func driveGain(saturation: Double) -> Double {
        let d = (saturation.isFinite ? saturation : 0).clamped(to: saturationRange)
        return 1 + d * (driveCeiling - 1)
    }

    /// ⭐ THE RECORD-PATH SHAPER, and the one home for its algebra. `tanh(g·x)/g`
    /// has UNITY small-signal gain and is bounded by `1/g`, which is the
    /// property a shaper inside a feedback loop must have: it may not raise the
    /// loop gain (that would turn a stable `feedback` into a divergent one) and
    /// it must bound a loud one. The `amount` crossfade on top is what makes
    /// `saturationDrive == 0` EXACTLY linear rather than merely gentle —
    /// `tanh(x)` is already 8 % down at x = 0.5, so without it there would be
    /// no clean digital repeat and no linear reference for a decay test.
    ///
    /// The tanh math is the `SaturatorEffect` family's, lifted rather than
    /// imported (the `.djFilter` / SVF precedent): `DAWCore` stays engine-free.
    /// ⚠️ ALIAS HONESTY: there is no oversampling here, so odd harmonics
    /// generated above Nyquist fold back. The record-path low-pass sits AFTER
    /// this stage and removes most of what is generated in band, but it cannot
    /// remove what has already folded.
    ///
    /// ⚠️ DATED 2026-09-20 (m39-ad): this used to read "exactly as in
    /// `SaturatorEffect` v0", and that comparison is now WRONG. The `.saturator`
    /// kind grew an OPT-IN `oversampling` param (1/2/4, default 1). At its
    /// default it is still byte-for-byte the un-oversampled v0 — which is why
    /// the shape of the caveat is unchanged — but a user who raises that knob
    /// gets ~90 dB less alias floor there and NOTHING here. The tape delay was
    /// deliberately not given the same knob in m39-ad: its shaper sits inside a
    /// FEEDBACK loop, so an oversampler's group delay would lengthen the echo
    /// time itself, which is a different and larger design question.
    public static func saturated(_ x: Double, driveGain g: Double, amount d: Double) -> Double {
        guard x.isFinite, g.isFinite, g > 0, d.isFinite else { return 0 }
        return x + d * (tanh(g * x) / g - x)
    }

    public init(timeMs: Double = 350, feedback: Double = 0.4, mix: Double = 0.3,
                wowDepthMs: Double = 2.5, wowRateHz: Double = 0.8,
                flutterDepthMs: Double = 0.25, saturationDrive: Double = 0.3,
                highCutHz: Double = 6_000) {
        // Non-finite guards ahead of every clamp: `clamped(to:)` on a NaN
        // returns the NaN (both comparisons in `min(max(…))` are false against
        // NaN), and these values reach an `Int()` conversion, a feedback
        // multiply and a filter coefficient on the render thread.
        self.timeMs = (timeMs.isFinite ? timeMs : 350).clamped(to: Self.timeRange)
        self.feedback = (feedback.isFinite ? feedback : 0.4).clamped(to: Self.feedbackRange)
        self.mix = (mix.isFinite ? mix : 0.3).clamped(to: Self.mixRange)
        self.wowDepthMs = (wowDepthMs.isFinite ? wowDepthMs : 2.5)
            .clamped(to: Self.wowDepthRange)
        self.wowRateHz = (wowRateHz.isFinite ? wowRateHz : 0.8).clamped(to: Self.wowRateRange)
        self.flutterDepthMs = (flutterDepthMs.isFinite ? flutterDepthMs : 0.25)
            .clamped(to: Self.flutterDepthRange)
        self.saturationDrive = (saturationDrive.isFinite ? saturationDrive : 0.3)
            .clamped(to: Self.saturationRange)
        self.highCutHz = (highCutHz.isFinite ? highCutHz : 6_000)
            .clamped(to: Self.highCutRange)
    }

    private enum CodingKeys: String, CodingKey {
        case timeMs, feedback, mix, wowDepthMs, wowRateHz, flutterDepthMs
        case saturationDrive, highCutHz
    }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            timeMs: try c.decodeIfPresent(Double.self, forKey: .timeMs) ?? 350,
            feedback: try c.decodeIfPresent(Double.self, forKey: .feedback) ?? 0.4,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 0.3,
            wowDepthMs: try c.decodeIfPresent(Double.self, forKey: .wowDepthMs) ?? 2.5,
            wowRateHz: try c.decodeIfPresent(Double.self, forKey: .wowRateHz) ?? 0.8,
            flutterDepthMs: try c.decodeIfPresent(Double.self, forKey: .flutterDepthMs) ?? 0.25,
            saturationDrive:
                try c.decodeIfPresent(Double.self, forKey: .saturationDrive) ?? 0.3,
            highCutHz: try c.decodeIfPresent(Double.self, forKey: .highCutHz) ?? 6_000)
    }
}

/// Mid/side stereo widener and mono-maker (m23-dj), raised by the user
/// 2026-08-04 who asked for *"true stereo"* rather than a fake width trick.
/// Their distinction IS this design.
///
/// ⛔ **THE ONE STRUCTURAL LAW: THE MID IS NEVER TOUCHED.** Every operation
/// here happens to the SIDE channel. `L' = M + S'`, `R' = M - S'`, so
/// `L' + R' = 2·M = L + R` — the mono fold-down is arithmetically the dry mono
/// fold-down at every setting of every parameter. That is why the acceptance
/// test for this item (sum to mono, compare level AND spectrum against dry)
/// passes by CONSTRUCTION rather than by tuning, and it is exactly what a Haas
/// delay (5-30 ms on one side) or a polarity-flipped duplicate cannot do:
/// those widen on speakers and comb, collapse or hollow out in mono.
///
/// ⚠️⚠️ **THE TRADE, WRITTEN DOWN BECAUSE IT IS A THEOREM AND NOT A TUNING
/// CHOICE.** The roadmap item's option ① asks for "width without a comb
/// filter, mono-safe if the all-pass is energy-preserving". For a source that
/// is ALREADY STEREO that is exactly what `width` delivers: scaling an
/// existing side channel adds no filtering of any kind. For a MONO source it
/// is not achievable, and the arithmetic says so:
///
///   · **this design** — `L = M·(1 + s·A)`, `R = M·(1 - s·A)` for an all-pass
///     `A` with `|A| = 1`: the mono sum is `2M`, **exactly flat**, and each
///     channel alone carries a complementary ripple between `1 - s` and
///     `1 + s` (`channelPeakDb` / `channelNotchDb`). At the default
///     `spread` 0.3 that is +2.28 dB / -3.10 dB; at 1.0 the channels null
///     completely at the comb frequencies.
///   · **the alternative** — `L = A₁(M)`, `R = A₂(M)` with two different
///     all-passes: each channel is perfectly flat and the SUM combs. This is
///     the shape the item was filed to refuse.
///
/// There is no third option: any `S' = F(M)` gives sum `2M` and channels
/// `|1 ± F|`. Mono compatibility is the stated acceptance test, so this design
/// takes the ripple and NAMES it — on the wire, in `fx.describe`, and in the
/// demo note — rather than shipping a quiet 3 dB hole in someone's vocal.
///
/// ⭐ **CONSEQUENCE WORTH SAYING OUT LOUD: `width` is free and `spread` is
/// not.** On material that already has a stereo difference, `width` is a pure
/// gain on that difference and colours nothing. `spread` MANUFACTURES a
/// difference out of the centre and pays the ripple above for it. An agent
/// widening a stereo bus should reach for `width`; an agent turning a mono
/// synth into a stereo one has to reach for `spread` and should say what it
/// costs.
public struct StereoWidthParams: Codable, Sendable, Equatable {
    /// How much of the EXISTING stereo difference survives. 0 = mono, 1 =
    /// exactly as recorded, 2 = the difference doubled.
    public var width: Double
    /// How much NEW stereo is synthesized from the centre by the all-pass
    /// decorrelator. 0 = none (a mono source stays mono). This is the "true
    /// stereo" control, and the one that costs per-channel ripple.
    public var spread: Double
    /// Below this frequency the stereo difference is removed, by
    /// `bassMonoAmount`. 120 Hz is what mastering practice actually does.
    public var bassMonoHz: Double
    /// How completely the bass is collapsed to mono. 0 disables the feature
    /// entirely (the crossover frequency then has no effect at all); 1 is a
    /// full 12 dB/oct removal of side content below `bassMonoHz`.
    public var bassMonoAmount: Double

    public static let widthRange: ClosedRange<Double> = 0...2
    public static let spreadRange: ClosedRange<Double> = 0...1
    public static let bassMonoHzRange: ClosedRange<Double> = 20...500
    public static let bassMonoAmountRange: ClosedRange<Double> = 0...1

    // MARK: The laws — ONE HOME each, in DAWCore, read by the DSP, the tests,
    // the demo note and `fx.describe`. Nothing below is re-derived elsewhere.

    /// ⛔ **THE NEUTRAL POSITION, AND THE ONE HOME FOR IT.** This kind has NO
    /// `mix` parameter — deliberately, because a dry/wet blend on a mid/side
    /// widener is ALGEBRAICALLY REDUNDANT: mixing `m` of `M + w·S` with dry
    /// gives `M + (1 + m·(w-1))·S`, i.e. another `width`, and mixing `m` of
    /// `M + s·A(M)` gives `M + (m·s)·A(M)`, i.e. another `spread`. A parameter
    /// that is a re-parameterisation of two existing parameters is a lie in
    /// `fx.describe`, so rule 6.0.7's "name the equivalent neutral position"
    /// branch applies instead, and this is that name.
    ///
    /// At this position the effect is a **BIT-EXACT BYPASS** — the render path
    /// never writes the buffer. It cannot merely compute an identity, because
    /// a mid/side round trip is NOT bit-exact in IEEE floating point:
    /// `0.5·(L+R) + 0.5·(L-R)` loses `L` entirely when `R` is many orders of
    /// magnitude larger. The decorrelator and the crossover keep running
    /// underneath (the `ChorusEffect` convention) so a later `spread` raise is
    /// phase-coherent rather than starting from silence.
    ///
    /// ⚠️ `bassMonoHz` is absent from this predicate ON PURPOSE: with
    /// `bassMonoAmount == 0` the crossover contributes nothing whatever its
    /// corner is, so a `bassMonoHz` move does NOT leave the bypass. Anything
    /// positive-controlling the bit-exactness must perturb `width`, `spread`
    /// or `bassMonoAmount` — perturbing `bassMonoHz` correctly changes nothing
    /// and would read as a gate that cannot fail.
    public static func isNeutral(width: Double, spread: Double,
                                 bassMonoAmount: Double) -> Bool {
        width == 1 && spread == 0 && bassMonoAmount == 0
    }

    /// The four Schroeder all-pass stage delays, in ms, longest first — the
    /// decorrelator that turns the centre into a side channel.
    ///
    /// ⭐ THEY ARE CONSTANTS AND NOT PARAMETERS, the `TapeDelayParams`
    /// flutter-rate precedent verbatim: appending a "size" param later is
    /// always safe (rule 6.0.1's corollary — never reserve a slot), and
    /// nothing about v1's sound needs them movable. The values are spread
    /// across a 4.5:1 range and deliberately not in simple ratios, so the
    /// chain's impulse response does not pile up into an audible echo at one
    /// spacing; the whole chain settles inside ~60 ms, which reads as WIDTH
    /// rather than as a room.
    ///
    /// ⚠️ ROUNDED TO WHOLE SAMPLES AT `prepare()`. An all-pass whose feedback
    /// path reads a FRACTIONAL tap is no longer exactly all-pass — linear
    /// interpolation is a mild low-pass — and the energy preservation is what
    /// keeps each channel's ripple bounded by `1 ± spread`. The mono sum is
    /// unaffected either way (it is `2M` regardless), so this is an image-
    /// quality decision, not a mono-safety one.
    public static let decorrelationDelaysMs: [Double] = [13.1, 8.3, 5.1, 2.9]

    /// Schroeder all-pass coefficient, every stage. 0.62 is dense enough to
    /// decorrelate in four stages and low enough that the chain rings out
    /// quickly instead of sounding like a small reverb.
    public static let decorrelationCoefficient = 0.62

    /// Capacity each decorrelator line declares to `InterpolatedDelayLine`, in
    /// SECONDS (§4.1: the home has NO default for this on purpose). ONE HOME,
    /// so `prepare()` and the tests cannot disagree about the number.
    /// `decorrelationInvariantHolds` in `StereoWidthParamsTests` pins that it
    /// covers the longest stage, so lengthening a stage without widening this
    /// fails loudly instead of truncating.
    public static let lineCapacitySeconds = 0.0131

    /// The shallowest delay any decorrelator stage can ask for, in ms — the
    /// invariant `prepare()` declares to the shared line, checked once, off
    /// the render thread. `.linear` interpolation's stencil floor is 1 sample,
    /// so this is satisfied at every sample rate above ~350 Hz.
    public static let minimumDelayMs = 2.9

    /// One-pole coefficient for a corner at `cutoffHz`, at `sampleRate`.
    /// `1 - exp(-2π·f/fs)`, the textbook mapping, guarded for the non-finite
    /// values a field-by-field automation poke can deliver.
    public static func onePoleCoefficient(cutoffHz: Double, sampleRate: Double) -> Double {
        guard cutoffHz.isFinite, sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let f = cutoffHz.clamped(to: bassMonoHzRange)
        return (1 - exp(-2.0 * Double.pi * f / sampleRate)).clamped(to: 0...1)
    }

    /// ⭐ THE MEASURABLE CLAIM, PART 1. Peak per-channel gain the `spread`
    /// decorrelator produces, in dB — `20·log10(1 + spread)`. At the 0.3
    /// default, +2.28 dB; at 1.0, +6.02 dB. This is a RIPPLE, not a level
    /// change: the peaks and the notches alternate across the spectrum and
    /// they land at DIFFERENT frequencies in the two channels, which is what
    /// "wide" is made of. The MONO SUM carries none of it.
    public static func channelPeakDb(spread: Double) -> Double {
        let s = (spread.isFinite ? spread : 0).clamped(to: spreadRange)
        return 20 * log10(1 + s)
    }

    /// ⭐ THE MEASURABLE CLAIM, PART 2. Deepest per-channel notch the `spread`
    /// decorrelator produces, in dB — `20·log10(1 - spread)`. At the 0.3
    /// default, -3.10 dB; at 0.7, -10.46 dB; at 1.0 the notch is a complete
    /// null and the true answer is minus infinity, which no JSON number can
    /// carry, so it FLOORS AT -120 dB. A floored value is still honest: it
    /// says "as deep as this instrument reports", and 0.99 already reads
    /// -40 dB, so the floor is only ever reached at the exact endpoint.
    public static func channelNotchDb(spread: Double) -> Double {
        let s = (spread.isFinite ? spread : 0).clamped(to: spreadRange)
        return max(-120, 20 * log10(max(1 - s, 1e-6)))
    }

    public init(width: Double = 1, spread: Double = 0.3,
                bassMonoHz: Double = 120, bassMonoAmount: Double = 1) {
        // Non-finite guards ahead of every clamp: `clamped(to:)` on a NaN
        // returns the NaN (both comparisons in `min(max(…))` are false against
        // NaN), and these values reach a filter coefficient and three gain
        // multiplies on the render thread.
        self.width = (width.isFinite ? width : 1).clamped(to: Self.widthRange)
        self.spread = (spread.isFinite ? spread : 0.3).clamped(to: Self.spreadRange)
        self.bassMonoHz = (bassMonoHz.isFinite ? bassMonoHz : 120)
            .clamped(to: Self.bassMonoHzRange)
        self.bassMonoAmount = (bassMonoAmount.isFinite ? bassMonoAmount : 1)
            .clamped(to: Self.bassMonoAmountRange)
    }

    private enum CodingKeys: String, CodingKey {
        case width, spread, bassMonoHz, bassMonoAmount
    }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            width: try c.decodeIfPresent(Double.self, forKey: .width) ?? 1,
            spread: try c.decodeIfPresent(Double.self, forKey: .spread) ?? 0.3,
            bassMonoHz: try c.decodeIfPresent(Double.self, forKey: .bassMonoHz) ?? 120,
            bassMonoAmount:
                try c.decodeIfPresent(Double.self, forKey: .bassMonoAmount) ?? 1)
    }
}

/// Parameters for the built-in swept all-pass phaser (m39-o).
/// `docs/design/2026-09-19-creative-effects.md` §2.1 rank 7 is the item; §6.0
/// is the contract every new kind inherits.
///
/// ⛔ **THE ONE THING TO GET RIGHT: A PHASER IS NOT A FLANGER.** Both sum a
/// signal with an altered copy of itself and sweep the result, and both are
/// described as "whooshing", so they are routinely conflated. They are not the
/// same effect and the difference is ARITHMETIC:
///
///  · A **flanger** sums with a DELAYED copy. A delay of `d` inverts every
///    frequency whose half-period divides `d`, so it cancels at the ODD
///    MULTIPLES of `1/(2d)` — an unbounded, evenly spaced, HARMONIC comb
///    (1 : 3 : 5 : 7 : 9 …), dozens of notches inside the audible band.
///    `FlangerParams.combNotchHz` is that law.
///  · A **phaser** sums with a PHASE-SHIFTED copy. Each first-order all-pass
///    section passes every frequency at full level while rotating its phase
///    from 0° at DC to −180° at Nyquist, through −90° at the corner. An
///    N-section chain therefore sweeps 0° → −N·180°, and the sum cancels only
///    where that total crosses an ODD multiple of 180°. That happens exactly
///    **N/2 times** (`notchCount(stages:)`), and the crossings land at
///    `notchRatio(stages:index:)` times the corner — `tan((2k+1)·π/(2N))`,
///    which is **NOT a harmonic series**. For 8 stages the ratios are
///    1 : 3.36 : 7.52 : 25.3 where a flanger's would be 1 : 3 : 5 : 7.
///
/// So: **a handful of unevenly spaced notches that spread apart as they climb,
/// versus a dense evenly spaced comb.** That is why a phaser reads as a soft
/// vocal "wow" and a flanger as a metallic jet-plane sweep, and it is what
/// `PhaserTests` measures — the same notch-finder is run over BOTH kinds and
/// each law is asserted to fit its own effect and to be REJECTED by the other.
///
/// ⛔ **THE SWEEP IS UPWARD-ONLY, IN LOG FREQUENCY** — `FlangerParams`' §6.3.2
/// law carried into the domain this kind sweeps:
/// `corner = centerHz · 2^(depthOctaves · (0.5 + 0.5·sin φ))`. The obvious
/// bipolar form would dive an octave or more BELOW `centerHz`, out of the band
/// where a phaser has anything to cancel; multiplying upward from a floor
/// keeps the corner inside `[centerHz, centerHz·2^depthOctaves]` with no clamp
/// (which would flatten the sweep) and no render-thread branch (which would
/// hide the mistake in the inner loop).
///
/// ⭐ **AND THE SWEEP CEILING IS STRUCTURAL, NOT CLAMPED.** An all-pass
/// coefficient is `(t−1)/(t+1)` with `t = tan(π·fc/fs)`, and `tan` is past its
/// vertical asymptote — so the coefficient magnitude exceeds 1 and the section
/// becomes UNSTABLE — the moment `fc` reaches Nyquist. The ranges below are
/// chosen so `centerRange.upperBound · 2^depthRange.upperBound` is
/// `maxCornerHz` = 16 kHz, which is under `0.45·fs` for every sample rate at
/// or above 35.6 kHz. `allpassCoefficient` still carries the guard (a 32 kHz
/// project would reach it), but at 44.1/48/88.2/96 kHz it never engages, so
/// the sweep top is never flattened. `maxCornerFitsEverySupportedRate` pins it.
public struct PhaserParams: Codable, Sendable, Equatable {
    /// LFO speed in Hz. 0.02 is one sweep every 50 seconds; 10 is a warble.
    public var rateHz: Double
    /// The all-pass corner at the BOTTOM of the sweep, in Hz — the "manual"
    /// knob. With `depthOctaves` at 0 this alone places the notches and the
    /// effect is a static filter (and, being time-invariant, is exactly what
    /// an impulse response can characterise — which is how the tests measure).
    public var centerHz: Double
    /// How far the sweep travels ABOVE `centerHz`, in OCTAVES. The sweep RANGE,
    /// never a half-range: the corner covers `centerHz … centerHz·2^depth`.
    /// Octaves and not a percentage because a frequency sweep is heard
    /// logarithmically — "one octave" is the same musical distance from 200 Hz
    /// as from 2 kHz, where "+400 Hz" is not.
    public var depthOctaves: Double
    /// How many first-order all-pass sections are cascaded. EVEN ONLY, 2…12,
    /// snapped by `snappedStages`. Each PAIR of sections buys one notch, so
    /// this is the notch-count control: 4 → 2 notches, 8 → 4, 12 → 6.
    public var stages: Double
    /// How much of the all-pass chain's output is fed back into its input,
    /// −0.95 … 0.95. BIPOLAR on purpose: the sign decides whether the
    /// resonance sharpens the peaks between the notches or between the peaks.
    public var feedback: Double
    /// Dry/wet. 0 is a bit-exact bypass (rule 6.0.7).
    public var mix: Double
    /// Right-channel LFO phase offset from the left, in degrees.
    public var stereoPhaseDeg: Double

    public static let rateRange: ClosedRange<Double> = 0.02...10
    public static let centerRange: ClosedRange<Double> = 20...1_000
    public static let depthRange: ClosedRange<Double> = 0...4
    public static let stagesRange: ClosedRange<Double> = 2...12
    public static let feedbackRange: ClosedRange<Double> = -0.95...0.95
    public static let mixRange: ClosedRange<Double> = 0...1
    public static let stereoPhaseRange: ClosedRange<Double> = 0...180

    /// The highest corner the upward-only sweep can reach, over the WHOLE
    /// surface: `centerRange.upperBound · 2^depthRange.upperBound` = 16 kHz.
    /// ONE HOME, so the engine's `tan` guard, the design claim that the guard
    /// never engages, and the test that checks it cannot disagree.
    public static let maxCornerHz =
        centerRange.upperBound * pow(2, depthRange.upperBound)

    /// The fraction of the sample rate `allpassCoefficient` will not let the
    /// corner exceed — the `DJFilterEffect` guard's constant, deliberately not
    /// a second one. 0.45·fs is comfortably under Nyquist, where `tan` is
    /// finite and well conditioned.
    public static let cornerCeilingFraction = 0.45

    // MARK: The laws — ONE HOME each, in DAWCore, read by the DSP, the tests
    // and `fx.describe`'s note text. Nothing below is re-derived anywhere else.

    /// ⛔ THE SWEEP LAW. The all-pass corner in Hz at LFO phase `phaseRadians`,
    /// swept UPWARD from `centerHz` by up to `depthOctaves` octaves. The result
    /// is always in `[centerHz, centerHz·2^depthOctaves]` ⊆
    /// `[centerRange.lowerBound, maxCornerHz]`, so it is always positive and
    /// always below Nyquist at any supported rate — no clamp, no branch.
    ///
    /// Non-finite inputs fall back to the defaults rather than propagating: the
    /// return value reaches `tan()` on the render thread, and a field-by-field
    /// automation poke bypasses `init`, so the guard has to live in the law and
    /// not only in the initialiser (the `FlangerParams.sweptDelayMs` precedent,
    /// same shape, same reason).
    public static func sweptCornerHz(phaseRadians: Double, centerHz: Double,
                                     depthOctaves: Double) -> Double {
        let floorHz = (centerHz.isFinite ? centerHz : 300).clamped(to: centerRange)
        let octaves = (depthOctaves.isFinite ? depthOctaves : 3).clamped(to: depthRange)
        guard phaseRadians.isFinite else { return floorHz }
        return floorHz * pow(2, octaves * (0.5 + 0.5 * sin(phaseRadians)))
    }

    /// ⛔ THE COEFFICIENT LAW — `a` for the first-order all-pass
    /// `H(z) = (a + z⁻¹) / (1 + a·z⁻¹)`, realised per sample as
    /// `y = a·x + s`, `s' = x − a·y`.
    ///
    /// ⚠️ **THE SIGN IS THE WHOLE POINT AND IT IS EASY TO GET BACKWARDS.**
    /// `a = (t − 1) / (t + 1)`, with `t = tan(π·fc/fs)` — NOT `(1 − t)/(1 + t)`,
    /// which is the form that appears in one-pole and shelving derivations and
    /// which, dropped into the transfer function above, gives a section whose
    /// phase at its own corner is a few degrees rather than −90°. Both signs
    /// are stable all-passes and both produce `stages/2` notches, so a NOTCH
    /// COUNT test cannot tell them apart; only `notchHz` can, which is why the
    /// suite measures positions and not just count.
    ///
    /// `a` runs from −1 (corner at DC) through 0 (corner at fs/4) to +1
    /// (corner at Nyquist), so `|a| < 1` and the section is stable everywhere
    /// the guard admits.
    public static func allpassCoefficient(cornerHz: Double, sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let hz = cornerHz.isFinite ? cornerHz : centerRange.lowerBound
        // The `DJFilterEffect` guard, for its reason: a 32 kHz project has a
        // 16 kHz Nyquist, where an unguarded `tan` is past its asymptote.
        let guarded = min(max(hz, 5.0), sampleRate * cornerCeilingFraction)
        let t = tan(.pi * guarded / sampleRate)
        return (t - 1) / (t + 1)
    }

    /// Even-only, 2…12. An ODD count would put its last phase crossing exactly
    /// AT Nyquist — a notch nobody can hear, and a notch count that no longer
    /// equals `stages/2`. Snapping to even keeps the one law this control
    /// exists to express exact.
    ///
    /// ⚠️ An odd input is an exact TIE between two even neighbours, and the tie
    /// goes UP (5 → 6, 9 → 10): `Double.rounded()`'s "half away from zero",
    /// used rather than a second hand-rolled rule. A NON-FINITE input falls
    /// back to the 6 default, like every other law here — it is not "very
    /// large", it is "no answer".
    public static func snappedStages(_ raw: Double) -> Int {
        let clamped = (raw.isFinite ? raw : 6).clamped(to: stagesRange)
        let even = (clamped / 2).rounded() * 2
        return Int(even.clamped(to: stagesRange))
    }

    /// How many notches a chain of `stages` sections produces: `stages/2`.
    /// The chain's total phase sweeps 0 → −stages·180°, and the dry+wet sum
    /// cancels at each odd multiple of 180° it crosses.
    public static func notchCount(stages: Double) -> Int { snappedStages(stages) / 2 }

    /// ⛔ THE NON-HARMONIC LAW, and the reason this kind is not a flanger.
    /// Notch `index` sits at this multiple of the corner frequency:
    /// `tan((2·index + 1)·π / (2·N))` for an N-stage chain.
    ///
    /// For 8 stages: 0.199, 0.668, 1.497, 5.027 — ratios to the first of
    /// 1 : 3.36 : 7.52 : 25.3. A flanger's comb would be 1 : 3 : 5 : 7. The
    /// series is not harmonic at any stage count, and it SPREADS: successive
    /// notches get further apart, which is exactly what the ear reads as
    /// "phaser" rather than "comb".
    ///
    /// ⚠️ **THIS IS THE LOW-FREQUENCY (ANALOG-PROTOTYPE) RATIO, AND IT IS A
    /// GOOD APPROXIMATION ONLY WHERE THE PRODUCT `corner · ratio` IS WELL
    /// BELOW NYQUIST.** The exact digital answer is `notchHz`, which prewarps
    /// through `tan`. ⛔ MEASURED, because the first version of this comment
    /// claimed agreement "anywhere in `centerRange`" and that was FALSE: a
    /// 12-stage chain's TOP ratio is 7.60, so a 1 kHz corner puts that notch at
    /// a nominal 7 596 Hz while the exact digital answer at 44.1 kHz is
    /// 6 972 Hz — **8.9 % away, 54× the index-0 bound.** The agreement claim
    /// holds for **`index == 0` at the sweep floor** — the only place the
    /// shipped derived field uses it — where the worst case over the whole
    /// surface is 0.17 %
    /// (`notchRatioMatchesTheExactDigitalLawAtTheSweepFloor` pins it).
    /// **Use `notchHz` for anything else.**
    /// Returns 0 for an out-of-range index rather than an undefined tangent.
    public static func notchRatio(stages: Double, index: Int) -> Double {
        let n = snappedStages(stages)
        guard index >= 0, index < n / 2 else { return 0 }
        return tan(Double(2 * index + 1) * .pi / Double(2 * n))
    }

    /// ⛔ THE EXACT DIGITAL NOTCH LAW. Where notch `index` actually lands, in
    /// Hz, for an `stages`-section chain whose corner is `cornerHz` at sample
    /// rate `sampleRate`:
    ///
    ///     f = (fs/π) · arctan( tan(π·fc/fs) · tan((2k+1)·π/(2N)) )
    ///
    /// Derivation, because a magic formula is a formula nobody can check: one
    /// section's phase is `φ(ω) = −2·arctan( tan(ω/2) / tan(ω_c/2) )`, N of
    /// them give `N·φ`, and a notch is where `N·φ = −(2k+1)·π`. Solving for ω
    /// and converting to Hz gives the line above. It is EXACT — the bilinear
    /// relation between the analog prototype and this digital section is exact
    /// — and it is what the rendered-notch test compares against.
    ///
    /// ⚠️ Valid at `feedback == 0` and `mix == 0.5`, where the dry and wet
    /// paths are equal and the nulls are complete. Feedback deepens and
    /// slightly shifts the response around the notches; a mix away from 0.5
    /// makes them shallower without moving them.
    public static func notchHz(cornerHz: Double, stages: Double, index: Int,
                               sampleRate: Double) -> Double {
        let ratio = notchRatio(stages: stages, index: index)
        guard ratio > 0, sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let hz = cornerHz.isFinite ? cornerHz : centerRange.lowerBound
        let guarded = min(max(hz, 5.0), sampleRate * cornerCeilingFraction)
        let t = tan(.pi * guarded / sampleRate)
        return sampleRate / .pi * atan(t * ratio)
    }

    /// Where the LOWEST notch sits when the LFO is at the bottom of its travel
    /// — the number that makes `centerHz` and `stages` legible together, and
    /// the one `fx.add` / `fx.setParam` echo back per instance.
    ///
    /// Sample-rate-free on purpose: at the sweep FLOOR the corner never exceeds
    /// `centerRange.upperBound` (1 kHz), which is far enough below every
    /// supported Nyquist that the analog ratio and the exact digital law agree
    /// to better than 0.2 % — and a derived field that changed when the user
    /// changed project rate would be a worse lie than a 0.2 % one.
    public static func firstNotchHzAtSweepFloor(centerHz: Double, stages: Double) -> Double {
        let floorHz = (centerHz.isFinite ? centerHz : 300).clamped(to: centerRange)
        return floorHz * notchRatio(stages: stages, index: 0)
    }

    /// The right channel's LFO phase offset in RADIANS (the unit a phase
    /// accumulator actually wants). 180° = half a cycle = the two channels
    /// sweeping in opposition.
    public static func stereoPhaseOffsetRadians(stereoPhaseDeg degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        return degrees.clamped(to: stereoPhaseRange) * .pi / 180
    }

    /// The effect's steady-state gain on a CONSTANT input — the number that
    /// explains why raising `feedback` makes the effect louder, and the one the
    /// demo's loudness note and the engine's DC test both read.
    ///
    /// An all-pass chain has gain exactly +1 at DC (each section's `(a+1)/(1+a)`
    /// is 1), so the recirculation resolves to `1/(1 − feedback)` there, blended
    /// by `mix`. That is the SAME closed form as `FlangerParams.dcGain`, and it
    /// is the same form for the same structural reason: both are unity-gain
    /// recirculations. It is repeated here rather than shared because the two
    /// kinds' ranges and defaults are independent and a shared home would
    /// invite one kind's clamp to be applied to the other's value.
    public static func dcGain(feedback: Double, mix: Double) -> Double {
        let f = (feedback.isFinite ? feedback : 0).clamped(to: feedbackRange)
        let m = (mix.isFinite ? mix : 0).clamped(to: mixRange)
        return (1 - m) + m / (1 - f)
    }

    public init(rateHz: Double = 0.5, centerHz: Double = 300, depthOctaves: Double = 3,
                stages: Double = 6, feedback: Double = 0.5, mix: Double = 0.5,
                stereoPhaseDeg: Double = 90) {
        // Non-finite guards ahead of every clamp: `clamped(to:)` on a NaN
        // returns the NaN (both comparisons in `min(max(…))` are false against
        // NaN), and these values reach `tan()`, a phase accumulator and two
        // gain multiplies on the render thread.
        self.rateHz = (rateHz.isFinite ? rateHz : 0.5).clamped(to: Self.rateRange)
        self.centerHz = (centerHz.isFinite ? centerHz : 300).clamped(to: Self.centerRange)
        self.depthOctaves = (depthOctaves.isFinite ? depthOctaves : 3)
            .clamped(to: Self.depthRange)
        // SNAPPED, not merely clamped — `stages` is discrete, and what is
        // stored is what is in force (the `RingModParams.waveform` precedent),
        // so nothing downstream has to keep its own copy of the even rule.
        self.stages = Double(Self.snappedStages(stages))
        self.feedback = (feedback.isFinite ? feedback : 0.5).clamped(to: Self.feedbackRange)
        self.mix = (mix.isFinite ? mix : 0.5).clamped(to: Self.mixRange)
        self.stereoPhaseDeg = (stereoPhaseDeg.isFinite ? stereoPhaseDeg : 90)
            .clamped(to: Self.stereoPhaseRange)
    }

    private enum CodingKeys: String, CodingKey {
        case rateHz, centerHz, depthOctaves, stages, feedback, mix, stereoPhaseDeg
    }

    /// Decoding routes through the clamping init, `decodeIfPresent ?? default`
    /// per field, so a partial object decodes (the `ChorusParams` pattern).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rateHz: try c.decodeIfPresent(Double.self, forKey: .rateHz) ?? 0.5,
            centerHz: try c.decodeIfPresent(Double.self, forKey: .centerHz) ?? 300,
            depthOctaves: try c.decodeIfPresent(Double.self, forKey: .depthOctaves) ?? 3,
            stages: try c.decodeIfPresent(Double.self, forKey: .stages) ?? 6,
            feedback: try c.decodeIfPresent(Double.self, forKey: .feedback) ?? 0.5,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 0.5,
            stereoPhaseDeg:
                try c.decodeIfPresent(Double.self, forKey: .stereoPhaseDeg) ?? 90)
    }
}

/// Parameters for the built-in transient shaper (m39-y) — the insert that
/// changes how HARD a sound starts and how LONG it rings, without touching its
/// level in between. `docs/design/2026-09-20-transient-shaper.md` is the design
/// and §3 is the detector; this struct is the ONE HOME for every law the DSP,
/// the tests, `fx.describe`'s notes and `Commands.effectParamsJSON` read.
///
/// ⛔ **IT IS NOT A COMPRESSOR AND IT HAS NO THRESHOLD, DELIBERATELY.** A
/// compressor responds to ABSOLUTE LEVEL; this responds to the RATE OF CHANGE of
/// the signal relative to ITS OWN lagged reference. The differentials are taken
/// as **dB RATIOS of two LINEAR envelopes**, and that single choice is what makes
/// the effect level-independent: a linear one-pole has a level-proportional step
/// response, so `envFast / envAttack` — and therefore the differential in dB — is
/// invariant under a change of input gain. Turning the fader down does NOT turn
/// the effect down. ⚠️ The plausible wrong formulation is a LINEAR DIFFERENCE
/// (`envFast − envAttack`), which is level-DEPENDENT and would make every knob
/// mean something different at every fader position;
/// `TransientShaperTests` L6 plants exactly that and reddens.
///
/// ⛔ **`attackDb` IS A MAXIMUM, NOT A PROMISE.** The full amount lands only where
/// the differential reaches `fullShapeDifferentialDb` (12 dB). Below that the
/// shaping is proportional, which is what makes it sound natural instead of
/// pumping — and it is why this kind ships a declared normalisation rather than a
/// dimensionless −1…+1 knob: "+6 dB raises the first `attackWindowMs` by 6.00 ±
/// 0.5 dB" is falsifiable, and "attack at +0.5" is not.
///
/// ⛔ **ZERO LOOKAHEAD, `latencySamples == 0`, and that is a deliberate refusal.**
/// The honest cost is that a CUT leaves the first ~2 samples of a leading edge
/// unattenuated (a sub-0.05 ms tick). The alternative — a lookahead ring buffer —
/// costs a NEW DECLARED LATENCY SOURCE entering the insert-PDC guarantee that
/// m25-n measured sample-exact, for two samples. ⛔ A future implementer who adds
/// lookahead MUST declare it in `latencySamples` and re-measure against m25-n.
public struct TransientShaperParams: Codable, Sendable, Equatable {
    /// How much louder (or quieter) to make the FRONT of each sound, in dB.
    /// A MAXIMUM — see `shapedFraction`.
    public var attackDb: Double
    /// How much louder (or quieter) to make the RING-OUT after the hit, in dB.
    /// ⚠️ POSITIVE LENGTHENS the tail, negative shortens it. See the note on
    /// `shapedFraction` for the sign convention and why the other plausible
    /// formulation was rejected.
    public var sustainDb: Double
    /// How long the front of a sound counts as "the hit", in ms — the symmetric
    /// lag time constant of the attack reference envelope. ⚠️ NOT a fade time
    /// and NOT a delay.
    public var attackMs: Double
    /// How far into the tail the effect keeps working, in ms — the RELEASE time
    /// constant of the sustain reference envelope.
    public var sustainMs: Double
    /// Static output trim in dB, applied after the shaping. Load-bearing rather
    /// than a nicety: a transient shaper changes CREST FACTOR, and comparing
    /// punch honestly means levelling the loudness first.
    public var outputDb: Double
    /// Dry/wet blend of the SHAPED gain against unity. 1 (the default) is fully
    /// wet, and at all-default settings that is bit-exact dry (see below).
    public var mix: Double

    public static let attackDbRange: ClosedRange<Double> = -20...20
    public static let sustainDbRange: ClosedRange<Double> = -20...20
    public static let attackMsRange: ClosedRange<Double> = 0.1...50
    public static let sustainMsRange: ClosedRange<Double> = 20...1_000
    public static let outputDbRange: ClosedRange<Double> = -24...24
    public static let mixRange: ClosedRange<Double> = 0...1

    // MARK: The laws — ONE HOME each, read by the DSP, the tests, the notes and
    // the wire. Nothing below is re-derived anywhere else.

    /// ⛔ THE NORMALISATION. The differential, in dB, at which shaping is at FULL
    /// strength. `attackDb: +6` means "up to +6 dB, reached where the signal is
    /// 12 dB above its own lagged reference". Echoed on the wire so an agent can
    /// know what a setting promises without reading source.
    public static let fullShapeDifferentialDb = 12.0

    /// ⛔ THE ABSOLUTE DETECTOR FLOOR. Below this the detector is HARD-GATED —
    /// both differentials are forced to 0, not merely clamped. Without it the
    /// ratio of two near-zero envelopes is noise and the unit would apply up to
    /// ±20 dB of shaping to room tone. −70 dBFS is below any musically intended
    /// content and far above the float noise floor.
    public static let detectorFloorDb = -70.0

    /// The hard ceiling on the SUMMED shaping, in dB, before `outputDb`. Both
    /// amounts can reach 20 and could otherwise sum to 40.
    public static let maxShapeDb = 24.0

    /// FIXED, not a knob: the fast envelope's attack time constant in ms. ~2.4
    /// samples at 48 kHz — fast enough that "the signal" is the signal.
    public static let fastAttackMs = 0.05

    /// FIXED, not a knob: the fast envelope's release time constant in ms. Long
    /// enough to bridge a rectified waveform's zero crossings (the
    /// `CompressorEffect` detector's own 5 ms, for its reason), short enough
    /// that a real decay still reads as a decay.
    public static let fastReleaseMs = 5.0

    /// ⛔ THE GAIN LAW. 0 at no differential, 1 at `fullShapeDifferentialDb` or
    /// more, linear in dB in between. THE ONE HOME for what an `attackDb` of +6
    /// actually means.
    ///
    /// ⚠️ **THE SUSTAIN SIGN, STATED SO IT CANNOT BE IMPLEMENTED BACKWARDS.**
    /// The sustain differential is POSITIVE DURING A DECAY (the signal has
    /// fallen below its own slow reference), and `sustainDb` ADDS gain
    /// proportional to it. So `sustainDb: +9` applies up to +9 dB during the
    /// ring-out and LENGTHENS it; `−9` applies up to −9 dB and SHORTENS it.
    /// There is a second, equally plausible formulation — "pull the signal back
    /// up toward its slow reference", with no user scalar — and it is NOT this
    /// one: it would make the amount unsettable and leave the demo no
    /// measurable number.
    ///
    /// A non-finite differential is "no answer", not "very large": it returns 0.
    public static func shapedFraction(differentialDb: Double) -> Double {
        guard differentialDb.isFinite, differentialDb > 0 else { return 0 }
        return min(differentialDb / fullShapeDifferentialDb, 1.0)
    }

    /// ⛔ THE WINDOW LAW — the width, in ms, over which attack shaping is at FULL
    /// strength for a STEP onset. DERIVED, not asserted: full shaping needs a
    /// differential ≥ 12 dB, i.e. `A/f ≤ 10^(−12/20) = 0.25119`; for a symmetric
    /// one-pole lag `A(t) = 1 − e^(−t/τ)` that holds while
    /// `t ≤ τ·ln(1/0.74881) = 0.28927·τ`.
    ///
    /// ⚠️ This is the STEP-ONSET window. A slow swell has a smaller differential
    /// and gets proportionally less for longer; that is the effect working, not
    /// a discrepancy. Echoed per-instance on the wire as `attackWindowMs` by
    /// `fx.add` / `fx.setParam` results and `project.snapshot` — ⛔ NOT by
    /// `fx.describe`, which is a different surface entirely.
    /// ⚠️ The denominator is `1 − 10^(−12/20)`, NOT `10^(−12/20)`. Dropping the
    /// `1 −` gives 1.3816 instead of 0.28927 — a window 4.8× too wide, which
    /// reads as plausible and makes an attack CUT measure −3.15 dB where it
    /// should measure −6.00. MEASURED: that exact transcription error was made
    /// while implementing this and was caught only because A2 asserts a number.
    /// `TransientShaperParamsTests` Law 2 re-derives it INDEPENDENTLY rather
    /// than restating the constant.
    public static let fullShapeWindowFraction =
        log(1.0 / (1.0 - pow(10.0, -fullShapeDifferentialDb / 20.0)))

    public static func attackWindowMs(attackMs: Double) -> Double {
        let ms = (attackMs.isFinite ? attackMs : 5).clamped(to: attackMsRange)
        return ms * fullShapeWindowFraction
    }

    /// The one-pole feedback coefficient for a time constant of `ms`
    /// milliseconds at `sampleRate` Hz — `e^(−1/(ms·rate))`, the convention
    /// `CompressorEffect` already ships, under which the envelope covers 63.2 %
    /// of a step in exactly `ms`. Kept here rather than in the engine so the
    /// tests, the window law and the DSP cannot drift apart.
    ///
    /// Non-finite or non-positive inputs return 0 (an instant follower) rather
    /// than propagating: these reach the render thread.
    public static func onePoleCoefficient(ms: Double, sampleRate: Double) -> Double {
        guard ms.isFinite, ms > 0, sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return exp(-1.0 / (ms * 0.001 * sampleRate))
    }

    /// The detector floor as a LINEAR amplitude — `10^(−70/20)` ≈ 3.1623e−4.
    /// One home, so the note's number and the DSP's comparison cannot disagree.
    public static var detectorFloorLinear: Double { pow(10.0, detectorFloorDb / 20.0) }

    /// ⭐ **BIT-EXACT DRY AT DEFAULTS, BY IEEE AND NOT BY TOLERANCE.** At
    /// `attackDb = sustainDb = outputDb = 0` and `mix = 1` the shaped gain is
    /// `pow(10, 0) == 1.0` exactly, and `1·1.0 + 0.0 == 1.0`; multiplying a
    /// `Float` by `1.0f` is the identity. This is what makes the identity half
    /// of the byte/bit gates possible, and it is rule 6.0.7's requirement.
    public var isBitExactDry: Bool {
        attackDb == 0 && sustainDb == 0 && outputDb == 0 && mix == 1
    }

    public init(attackDb: Double = 0, sustainDb: Double = 0, attackMs: Double = 5,
                sustainMs: Double = 200, outputDb: Double = 0, mix: Double = 1) {
        // Non-finite guards ahead of every clamp: `clamped(to:)` on a NaN
        // returns the NaN (both comparisons in `min(max(…))` are false against
        // NaN), and these values reach `exp`, `log10`, `pow` and two gain
        // multiplies on the render thread. A NaN would poison the smoothing
        // accumulators permanently.
        self.attackDb = (attackDb.isFinite ? attackDb : 0).clamped(to: Self.attackDbRange)
        self.sustainDb = (sustainDb.isFinite ? sustainDb : 0).clamped(to: Self.sustainDbRange)
        self.attackMs = (attackMs.isFinite ? attackMs : 5).clamped(to: Self.attackMsRange)
        self.sustainMs = (sustainMs.isFinite ? sustainMs : 200)
            .clamped(to: Self.sustainMsRange)
        self.outputDb = (outputDb.isFinite ? outputDb : 0).clamped(to: Self.outputDbRange)
        self.mix = (mix.isFinite ? mix : 1).clamped(to: Self.mixRange)
    }

    private enum CodingKeys: String, CodingKey {
        case attackDb, sustainDb, attackMs, sustainMs, outputDb, mix
    }

    /// Decoding routes through the clamping init, `decodeIfPresent ?? default`
    /// per field, so a partial object decodes (the `ChorusParams` pattern).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            attackDb: try c.decodeIfPresent(Double.self, forKey: .attackDb) ?? 0,
            sustainDb: try c.decodeIfPresent(Double.self, forKey: .sustainDb) ?? 0,
            attackMs: try c.decodeIfPresent(Double.self, forKey: .attackMs) ?? 5,
            sustainMs: try c.decodeIfPresent(Double.self, forKey: .sustainMs) ?? 200,
            outputDb: try c.decodeIfPresent(Double.self, forKey: .outputDb) ?? 0,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1)
    }
}

/// Parameters for the built-in FREQUENCY SHIFTER (m39-z), plus **the one home**
/// for its Hilbert-network coefficients and every number derived from them.
/// `Sources/DAWEngine/Effects/FreqShifterEffect.swift`'s file comment is the
/// design; this struct is the contract it and the tests both read.
///
/// ⛔ **A FREQUENCY SHIFTER IS NOT A PITCH SHIFTER.** A pitch shifter multiplies
/// every partial by the same RATIO, so 100/200/300 Hz becomes 200/400/600 —
/// still a harmonic series, still one note. This ADDS a constant number of Hz,
/// so 100/200/300 becomes 200/300/400 — **no longer a harmonic series at all**.
/// The result is inharmonic on purpose: metallic, bell-like, clangorous.
///
/// ⛔ **AND IT IS NOT A RING MODULATOR.** `.ringMod` is DOUBLE-sideband: it emits
/// both `f + fc` and `|f − fc|` and the input itself vanishes. This is
/// SINGLE-sideband: **one** sideband survives and the other is rejected by
/// `sidebandRejectionDb`. That rejection figure is the entire quality measure of
/// this effect, which is why it is derived here from the shipped coefficients
/// rather than asserted as a literal.
public struct FreqShifterParams: Codable, Sendable, Equatable {
    /// Coarse shift in Hz. **The SIGN IS THE DIRECTION** — positive shifts every
    /// partial UP, negative DOWN. There is deliberately no separate direction
    /// switch: a discrete param would be `Modulatable: refused` by rule 6.0.5
    /// and would make the single most expressive axis un-automatable through 0.
    public var shiftHz: Double
    /// Fine shift in Hz, SUMMED with `shiftHz`. Exists for resolution, not for
    /// range: the classic ±1–20 Hz beating/chorus trick lives in 1 % of
    /// `shiftHz`'s travel, and `.logarithmic` cannot rescue a range that crosses
    /// 0 (rule 6.0.2). Two linear knobs can.
    public var fineHz: Double
    /// Difference in shift between left and right, in Hz: left gets
    /// `+stereoSpreadHz/2`, right `−stereoSpreadHz/2`. At small values this is
    /// what turns the effect into a wide, slowly-churning chorus that no pitch
    /// shifter can produce.
    public var stereoSpreadHz: Double
    /// Dry/wet blend. ⛔ At `mix == 0` the buffer is NEVER WRITTEN — bit-exact
    /// dry by IEEE (rule 6.0.7) — while the Hilbert network and both
    /// oscillators keep running, so raising `mix` later is phase-coherent.
    public var mix: Double
    /// Static output trim in dB. Load-bearing, not a nicety: the analytic
    /// signal's envelope can exceed the real input's peak, so a full-wet shift
    /// can be LOUDER than the source even though no gain was applied.
    public var outputDb: Double

    public static let shiftHzRange: ClosedRange<Double> = -2_000...2_000
    public static let fineHzRange: ClosedRange<Double> = -20...20
    public static let stereoSpreadHzRange: ClosedRange<Double> = -20...20
    public static let mixRange: ClosedRange<Double> = 0...1
    public static let outputDbRange: ClosedRange<Double> = -24...24

    // MARK: - THE HILBERT NETWORK — one home, read by the DSP and by the tests

    /// ⛔ **THE COEFFICIENT SET. Changing a digit here changes the effect's
    /// measured quality, and `FreqShifterParamsTests` Law 1 re-derives the phase
    /// response FROM THESE NUMBERS rather than restating the result — so an edit
    /// reddens a test instead of quietly degrading the rejection.**
    ///
    /// Each entry is the coefficient `a` of a first-order all-pass **in z⁻²**:
    ///
    ///     H(z) = (a − z⁻²) / (1 − a·z⁻²)
    ///     y[n] = a·(x[n] + y[n−2]) − x[n−2]
    ///
    /// ⚠️ **THE SIGN CONVENTION IS LOAD-BEARING AND EASY TO GET WRONG.** The
    /// other plausible transcription, `y[n] = a·(x[n] − y[n−2]) + x[n−2]`, is
    /// `H(z) = (a + z⁻²)/(1 + a·z⁻²)` — also a perfectly good all-pass, but a
    /// DIFFERENT one. MEASURED while building this: with that form the two
    /// branches stop being in quadrature, the unwanted sideband comes back at
    /// EQUAL amplitude, and the effect silently degrades into a ring modulator
    /// (both sidebands, 0.03 dB apart) while still sounding "metallic" and still
    /// passing any test that only asks whether the output changed.
    ///
    /// `hilbertI` carries an EXTRA one-sample delay (`z⁻¹`); `hilbertQ` does not.
    /// That delay is part of the network, not an implementation detail — without
    /// it the branches are ~0° apart rather than ~90°.
    public static let hilbertI: [Double] = [
        0.417_239_444_064_827,
        0.831_244_898_601_317,
        0.961_045_309_293_653,
        0.991_625_575_319_332,
        0.999_009_677_476_390,
    ]
    public static let hilbertQ: [Double] = [
        0.134_046_221_513_092,
        0.670_324_550_368_111,
        0.917_937_420_220_126,
        0.981_751_952_533_010,
        0.996_418_483_623_862,
    ]

    /// The design band, as a fraction of the SAMPLE RATE. ⚠️ **This band is
    /// normalised, so it moves in Hz when the session rate changes** — that is
    /// inherent to a fixed-coefficient IIR network and is why it is stated as a
    /// fraction here and converted by `designBandHz(sampleRate:)` rather than
    /// written down in Hz anywhere.
    public static let designBandLowFraction = 0.0002
    public static let designBandHighFraction = 0.4998

    /// ⛔ **THE MEASURED WORST-CASE PHASE ERROR, IN DEGREES, over the design
    /// band.** The pair's phase difference is 90° ± this. `FreqShifterParamsTests`
    /// Law 1 re-derives it from `hilbertI`/`hilbertQ` on a dense grid and fails
    /// if the two disagree by more than a hair, so this constant cannot rot away
    /// from the coefficients it describes.
    public static let worstPhaseErrorDeg = 0.376_46

    /// ⛔ **THE QUALITY NUMBER. How far below the wanted sideband the UNWANTED
    /// one sits, in dB (negative).** DERIVED, never asserted: a quadrature pair
    /// in error by `ε` leaks the opposite sideband at `tan(ε/2)`.
    ///
    /// ⚠️ It is `tan(ε/2)`, NOT `sin(ε)` or `ε/2`. At these tiny angles all three
    /// agree to within 0.01 dB, so a wrong one would look right — which is
    /// exactly why the end-to-end demo gate measures the rejection off a
    /// RENDERED WAV with a Goertzel probe instead of trusting this line.
    public static var sidebandRejectionDb: Double {
        20.0 * log10(tan(worstPhaseErrorDeg * Double.pi / 180.0 / 2.0))
    }

    /// The design band in Hz at a given sample rate. Below `low` the rejection
    /// degrades fast — at 48 kHz `low` is 9.6 Hz, comfortably under the audio
    /// band; at 96 kHz it is 19.2 Hz, which only just covers it.
    public static func designBandHz(sampleRate: Double) -> (low: Double, high: Double) {
        guard sampleRate.isFinite, sampleRate > 0 else { return (0, 0) }
        return (designBandLowFraction * sampleRate, designBandHighFraction * sampleRate)
    }

    /// ⛔ **THE EFFECTIVE SHIFT LAW — the ONE place `shiftHz` and `fineHz` are
    /// summed.** The sum is clamped to `shiftHz`'s range so the two knobs
    /// together can never ask for more than the coarse knob's declared maximum;
    /// without this, ±2000 + ±20 would silently make the real range ±2020 and
    /// `fx.describe` would be lying by 20 Hz.
    public static func effectiveShiftHz(shiftHz: Double, fineHz: Double) -> Double {
        let coarse = (shiftHz.isFinite ? shiftHz : 0).clamped(to: shiftHzRange)
        let fine = (fineHz.isFinite ? fineHz : 0).clamped(to: fineHzRange)
        return (coarse + fine).clamped(to: shiftHzRange)
    }

    /// Where a partial at `inputHz` LANDS, in Hz — the whole effect in one
    /// function, and the thing `fx.add` echoes so an agent can predict the sound
    /// without rendering it.
    ///
    /// ⚠️ **THE FOLD IS REAL PHYSICS, NOT A BUG.** Shifting DOWN by more than a
    /// partial's own frequency drives it below 0 Hz; the output is a real signal,
    /// so it reflects back up as `|f + Δ|` with its phase inverted. A 100 Hz tone
    /// shifted −300 Hz comes back at 200 Hz. Every analog Bode shifter does this
    /// and it is half of why large downward shifts sound the way they do.
    public static func shiftedHz(inputHz: Double, effectiveShiftHz: Double) -> Double {
        guard inputHz.isFinite, effectiveShiftHz.isFinite else { return 0 }
        return abs(inputHz + effectiveShiftHz)
    }

    public init(shiftHz: Double = 0, fineHz: Double = 0, stereoSpreadHz: Double = 0,
                mix: Double = 0.5, outputDb: Double = 0) {
        // Non-finite guards ahead of every clamp: `clamped(to:)` on a NaN
        // returns the NaN, and these reach a phase accumulator on the render
        // thread. A NaN phase has NO path back — every later sample is NaN too,
        // so the strip is silenced permanently (the `RingModEffect` precedent).
        self.shiftHz = (shiftHz.isFinite ? shiftHz : 0).clamped(to: Self.shiftHzRange)
        self.fineHz = (fineHz.isFinite ? fineHz : 0).clamped(to: Self.fineHzRange)
        self.stereoSpreadHz = (stereoSpreadHz.isFinite ? stereoSpreadHz : 0)
            .clamped(to: Self.stereoSpreadHzRange)
        self.mix = (mix.isFinite ? mix : 0.5).clamped(to: Self.mixRange)
        self.outputDb = (outputDb.isFinite ? outputDb : 0).clamped(to: Self.outputDbRange)
    }

    private enum CodingKeys: String, CodingKey {
        case shiftHz, fineHz, stereoSpreadHz, mix, outputDb
    }

    /// Decoding routes through the clamping init, `decodeIfPresent ?? default`
    /// per field, so a partial object decodes (the `ChorusParams` pattern).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            shiftHz: try c.decodeIfPresent(Double.self, forKey: .shiftHz) ?? 0,
            fineHz: try c.decodeIfPresent(Double.self, forKey: .fineHz) ?? 0,
            stereoSpreadHz: try c.decodeIfPresent(Double.self, forKey: .stereoSpreadHz) ?? 0,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 0.5,
            outputDb: try c.decodeIfPresent(Double.self, forKey: .outputDb) ?? 0)
    }
}

/// Parameters for the built-in clipper (m39-ac) — the first caller of the
/// shared `Oversampler` primitive (`OversamplerDesign` is its frozen contract).
///
/// ## What this kind is, against the two it is nearest
///
/// A clipper puts a HARD CEILING on the waveform: everything above it is cut
/// off and the corners that leaves are new harmonics. That is where the
/// loudness comes from, and it is why a clipped kick reads as "harder" rather
/// than merely "louder".
///
/// ⛔ **NOT `.saturator`.** `tanh` only ever APPROACHES its bound — there is no
/// finite input at which a saturator's output equals its maximum, so a
/// saturator cannot promise a peak ceiling. BOTH modes here reach `ceilingDb`
/// at a finite input and stay there: `hard` at exactly the ceiling, `soft` at
/// `softKneeRatio` (1.5) times it, through a cubic knee that arrives with zero
/// slope. That is the whole distinction and it is exact, not stylistic.
///
/// ⛔ **NOT `.limiter`.** A limiter rides a GAIN to keep peaks under a ceiling
/// and preserves the waveform's shape; this deliberately deforms the waveform.
/// A limiter is what you use when you must not hear it. This is what you use
/// when you want to.
///
/// ## The only real quality number this effect has
///
/// Hard clipping generates harmonics that extend far past Nyquist. Sampled at
/// the base rate they FOLD BACK as inharmonic tones — not "distortion" in the
/// musical sense but grit that sits at frequencies unrelated to anything
/// playing. Running the shaper at 2× or 4× moves the fold out of the audio
/// band, and the residue is bounded by the decimation filter's stopband
/// (`OversamplerDesign.stopbandAttenuationDb`).
///
/// ⭐ **`oversampling: 1` IS A SHIPPED SETTING, NOT A DEGRADED ONE.** Keeping it
/// is what lets a user (and `scripts/gates/m39ac-clipper-physics.mjs`) hear and
/// MEASURE the difference; plenty of records want the grit.
///
/// ## Latency
///
/// `OversamplerDesign.latencySamples` = 32 base-rate samples, **the same at
/// every factor, including 1×**, and at every sample rate. The effect reports
/// it, PDC compensates it, and the dry half of `mix` is delayed to match so the
/// blend stays phase-coherent. See `OversamplerDesign` §3 for why a
/// factor-dependent latency would have been a silent correctness bug.
public struct ClipperParams: Codable, Sendable, Equatable {
    /// Gain INTO the shaper, in dB. This is the control that decides how much
    /// clipping happens: the ceiling sets where, the drive sets how far past it
    /// the signal is pushed.
    public var driveDb: Double
    /// The ceiling, in dBFS. Output samples are bounded by this, exactly.
    public var ceilingDb: Double
    /// Shape: 0 = hard, 1 = soft. DISCRETE — `Modulatable: refused` (rule
    /// 6.0.5), snapped through `mode(at:)`.
    public var mode: Double
    /// Oversampling factor: 1, 2 or 4. DISCRETE — `Modulatable: refused`,
    /// snapped through `oversamplingFactor(at:)`.
    public var oversampling: Double
    /// Dry/wet. ⛔ At `mix == 0` the output is the input DELAYED BY
    /// `latencySamples`, bit-exact — see `Kind.clipper` and the effect file for
    /// why this kind's identity law is a delayed identity rather than rule
    /// 6.0.7's untouched-buffer one.
    public var mix: Double
    /// Static output trim in dB, applied to the WET copy before the blend.
    public var outputDb: Double

    /// ⚠️ NEGATIVE drive is deliberately reachable: with a low ceiling and a
    /// negative drive this becomes a gentle wave-shaper rather than a loudness
    /// tool, and denying it would be denying the range rather than protecting
    /// anyone.
    public static let driveDbRange: ClosedRange<Double> = -12...36
    /// ⚠️ The upper bound is 0 dBFS, not +24: a ceiling ABOVE full scale is not
    /// a ceiling, it is a guarantee the effect cannot keep once the signal
    /// leaves as 16- or 24-bit integer samples.
    public static let ceilingDbRange: ClosedRange<Double> = -24...0
    public static let modeRange: ClosedRange<Double> = 0...1
    public static let oversamplingRange: ClosedRange<Double> = 1...4
    public static let mixRange: ClosedRange<Double> = 0...1
    public static let outputDbRange: ClosedRange<Double> = -24...24

    /// The two shapes. Raw values are the wire numbers and are FROZEN.
    public enum Mode: Int, Sendable, CaseIterable {
        /// `y = clamp(x, −c, c)`. A corner at the ceiling: maximum new
        /// harmonic content, maximum bite, and the reason oversampling exists.
        case hard = 0
        /// A cubic knee that reaches the ceiling at `softKneeRatio·c` with zero
        /// slope. Unity gain for small signals — unlike a tanh saturator, which
        /// changes the level of everything.
        case soft = 1
    }

    /// ⛔ **THE SOFT MODE'S KNEE RATIO.** The input, as a multiple of the
    /// ceiling, at which the soft shape first TOUCHES the ceiling. Below it the
    /// curve bends; at and above it the output is flat at the ceiling.
    ///
    /// It is 3/2 and it is FORCED, not chosen: for `f(u) = u − a·u³` the two
    /// requirements "unity slope at 0" (so quiet material passes untouched) and
    /// "reaches 1 with zero slope" (so the knee meets the flat top smoothly)
    /// have exactly one solution, `a = 4/27` and `u* = 3/2`. Changing either
    /// number breaks one of the two properties.
    public static let softKneeRatio = 1.5
    /// The cubic term's coefficient, `4/27`. See `softKneeRatio`.
    public static let softCubicCoefficient = 4.0 / 27.0

    /// The round-trip latency this kind reports, in samples — through
    /// `OversamplerDesign`, the one home, never a second copy.
    public static var latencySamples: Int { OversamplerDesign.latencySamples }

    /// ⛔ **THE SHAPING LAW — the ONE home, read by the render thread, by the
    /// tests and by nothing else.** `x` is the DRIVEN sample;
    /// `ceilingLinear` is `10^(ceilingDb/20)`.
    ///
    /// Both branches are bounded by `ceilingLinear` for every finite input, and
    /// the soft branch is C¹ everywhere (see `softKneeRatio`). A non-finite
    /// input returns 0 rather than propagating: NaN reaching the decimation
    /// filter's history would poison every later output sample, with no path
    /// back (the `RingModEffect` phase-accumulator precedent, same reasoning).
    public static func shaped(_ x: Double, ceilingLinear: Double, soft: Bool) -> Double {
        guard x.isFinite, ceilingLinear.isFinite, ceilingLinear > 0 else { return 0 }
        if !soft {
            return min(max(x, -ceilingLinear), ceilingLinear)
        }
        let u = x / ceilingLinear
        if u >= softKneeRatio { return ceilingLinear }
        if u <= -softKneeRatio { return -ceilingLinear }
        return ceilingLinear * (u - softCubicCoefficient * u * u * u)
    }

    /// Snaps a raw wire value onto a mode. The `RingModParams.waveform(at:)`
    /// precedent: rounds, clamps, and falls back rather than trapping, because
    /// a field-by-field automation overlay poke bypasses `init`'s clamping.
    public static func mode(at value: Double) -> Mode {
        guard value.isFinite else { return .hard }
        let index = Int(value.clamped(to: modeRange).rounded())
        return Mode(rawValue: index) ?? .hard
    }

    /// Snaps a raw wire value onto a supported factor (1, 2 or 4).
    ///
    /// ⚠️ **3 SNAPS UP TO 4, NOT DOWN TO 2, AND THE TIE IS BROKEN ON PURPOSE.**
    /// 3 is exactly equidistant; resolving it toward the higher factor means an
    /// agent that writes a plausible-but-unsupported number gets MORE alias
    /// rejection than it asked for rather than less. The same rule makes 1.5
    /// resolve to 2.
    ///
    /// ⛔⛔ **EXPLICIT THRESHOLDS, NOT A SEARCH OVER
    /// `OversamplerDesign.supportedFactors`, AND THAT IS A RENDER-SAFETY
    /// REQUIREMENT RATHER THAN A STYLE CHOICE.** This runs on the RENDER THREAD
    /// (`ClipperEffect.deriveRenderParams`, reached from `storeAutomatedParam`),
    /// and iterating a Swift `Array` there allocates at `-Onone`: MEASURED at
    /// 163 296 malloc events over 2 000 quanta while the allocation gate asserts
    /// an absolute zero. `ClipperParamsTests` P4b re-derives this function from
    /// the roster by brute force and fails if the two ever disagree, so the
    /// hand-written thresholds cannot drift away from the documented list.
    public static func oversamplingFactor(at value: Double) -> Int {
        guard value.isFinite else { return OversamplerDesign.maxFactor }
        let clamped = value.clamped(to: oversamplingRange)
        // Midpoints of 1|2 and 2|4, each resolving a tie UPWARD.
        if clamped < 1.5 { return 1 }
        if clamped < 3.0 { return 2 }
        return 4
    }

    /// ⛔ **WHERE CLIPPING STARTS, in dBFS at the INPUT.** `ceilingDb −
    /// driveDb`, i.e. the input level that lands exactly on the ceiling after
    /// the drive. This is the number an agent actually needs and cannot read
    /// off either knob alone, and it is echoed in every `fx.add` /
    /// `fx.setParam` result.
    public static func clipThresholdDbfs(driveDb: Double, ceilingDb: Double) -> Double {
        let drive = (driveDb.isFinite ? driveDb : 0).clamped(to: driveDbRange)
        let ceiling = (ceilingDb.isFinite ? ceilingDb : 0).clamped(to: ceilingDbRange)
        return ceiling - drive
    }

    /// The guaranteed SAMPLE ceiling of the wet path in dBFS, `ceilingDb +
    /// outputDb`. ⚠️ A sample ceiling, not a TRUE-PEAK ceiling: see
    /// `interSampleOvershootDb`.
    public static func wetCeilingDbfs(ceilingDb: Double, outputDb: Double) -> Double {
        let ceiling = (ceilingDb.isFinite ? ceilingDb : 0).clamped(to: ceilingDbRange)
        let trim = (outputDb.isFinite ? outputDb : 0).clamped(to: outputDbRange)
        return ceiling + trim
    }

    public init(driveDb: Double = 0, ceilingDb: Double = -0.3, mode: Double = 0,
                oversampling: Double = 4, mix: Double = 1, outputDb: Double = 0) {
        // Non-finite guards ahead of every clamp: `clamped(to:)` on a NaN
        // returns the NaN, and `oversampling` reaches an `Int()` conversion
        // that would TRAP on one (the `RingModParams.waveform` precedent).
        self.driveDb = (driveDb.isFinite ? driveDb : 0).clamped(to: Self.driveDbRange)
        self.ceilingDb = (ceilingDb.isFinite ? ceilingDb : -0.3).clamped(to: Self.ceilingDbRange)
        self.mode = Double(Self.mode(at: mode).rawValue)
        self.oversampling = Double(Self.oversamplingFactor(at: oversampling))
        self.mix = (mix.isFinite ? mix : 1).clamped(to: Self.mixRange)
        self.outputDb = (outputDb.isFinite ? outputDb : 0).clamped(to: Self.outputDbRange)
    }

    private enum CodingKeys: String, CodingKey {
        case driveDb, ceilingDb, mode, oversampling, mix, outputDb
    }

    /// Decoding routes through the clamping/snapping init, `decodeIfPresent ??
    /// default` per field, so a partial object decodes (the `ChorusParams`
    /// pattern).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            driveDb: try c.decodeIfPresent(Double.self, forKey: .driveDb) ?? 0,
            ceilingDb: try c.decodeIfPresent(Double.self, forKey: .ceilingDb) ?? -0.3,
            mode: try c.decodeIfPresent(Double.self, forKey: .mode) ?? 0,
            oversampling: try c.decodeIfPresent(Double.self, forKey: .oversampling) ?? 4,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1,
            outputDb: try c.decodeIfPresent(Double.self, forKey: .outputDb) ?? 0)
    }
}

/// Parameters for the built-in dynamic EQ (m39-af) — the second caller of
/// `EQFilterResponse.bandPassSection`. See `EffectDescriptor.Kind.dynamicEQ`
/// for what the kind is and `docs/design/2026-09-20-dynamic-eq.md` for why.
///
/// ## Shape: FOUR IDENTICAL BANDS, EIGHT PARAMS EACH, BAND-MAJOR
///
/// `slot = (band − 1)·8 + p`, so `band1Mode` is slot 0 and `band4ReleaseMs` is
/// slot 31. That arithmetic is the whole reason the bands are uniform: a
/// reviewer can check 32 slots by checking 8 and multiplying.
/// `DynamicEQParamsTests` pins the 32 names against literals in order.
///
/// ⛔ **APPEND-ONLY, and the reason is NOT the one the tree used to give.** A
/// persisted automation lane stores the param NAME, not an index
/// (`Automation.swift:81-84`); the INDEX is derived per session from
/// `specs(for:)` (`AutomationSchedule.resolveEffectParamLanes`). What reordering
/// would actually break is the alignment between `specs(for:)` and
/// `DynamicEQEffect.storeAutomatedParam`'s slot switch — two tables in two
/// modules that no compiler rule compares — and a lane landing outside that
/// switch's `(0...31)` guard is **silently inert**: nothing logs, nothing fails,
/// the user's automation simply does nothing. Live `(effectID, paramSlot)`
/// cursors exist in-session too. ⚠️ And a param RENAME is a MIGRATION, not a
/// refactor: it orphans every saved lane pointing at the old name (recoverable
/// by restoring the name — the document round-trips lanes verbatim — but don't).
///
/// ⚠️ **ONE FULLY-AUTOMATED INSTANCE IS HALF A STRIP'S BUDGET.** Effect-param
/// automation lanes and modulated effect params SHARE ONE 64-entry cap per
/// strip (`Modulation.swift:434-438`), and the excess is dropped by a bare
/// `.prefix` with no warning. 32 slots is half of that in one insert. It is the
/// single real cost of a 32-param kind and it is stated in `fx.describe`.
///
/// ## What is deliberately NOT here
///
/// · **`kneeDb`** — fixed at 6 dB, the compressor's own default (`Self.kneeDb`).
///   Saves 4 slots on a control almost nobody moves.
/// · **`mix`** — a dynamic EQ's wet/dry IS the band gain. A second blend stage
///   would be a confusing duplicate (`.djFilter` set the no-`mix` precedent).
/// · **a per-band `enabled`** — `mode == 0` IS the bypass, and it is a TRUE
///   no-op: the section is not even stepped, which is strictly better than a
///   gain-0 bypass.
/// · **a per-band static `gainDb`** (the Pro-Q model) — 4 more slots, and it
///   would destroy the free transparency null (a band with static gain is never
///   exactly `H = 1`, so it must be stepped even at rest). `.eq → .dynamicEQ`
///   chains today with zero new code and `.eq` is the better static EQ.
/// · **lookahead** — it would make `latencySamples` PARAMETER-DEPENDENT, which
///   forces a PDC rebuild the render thread cannot do and a refused automation
///   lane. The `m39-ad` precedent.
///
/// Each of those is a clean additive append if it is ever wanted; each would
/// then acquire a `Codable` decode default, which is the moment the byte
/// gate stops being able to see it (design §10 G2).
public struct DynamicEQParams: Codable, Sendable, Equatable {
    // ⛔ BAND-MAJOR AND FROZEN. Declaration order here is documentation; the
    // authority on slot order is `EffectParamSpec.specs(for: .dynamicEQ)`, and
    // `DynamicEQParamsTests.slotOrderIsFrozen` asserts the two agree.
    public var band1Mode: Double
    public var band1Freq: Double
    public var band1Q: Double
    public var band1ThresholdDb: Double
    public var band1Ratio: Double
    public var band1RangeDb: Double
    public var band1AttackMs: Double
    public var band1ReleaseMs: Double

    public var band2Mode: Double
    public var band2Freq: Double
    public var band2Q: Double
    public var band2ThresholdDb: Double
    public var band2Ratio: Double
    public var band2RangeDb: Double
    public var band2AttackMs: Double
    public var band2ReleaseMs: Double

    public var band3Mode: Double
    public var band3Freq: Double
    public var band3Q: Double
    public var band3ThresholdDb: Double
    public var band3Ratio: Double
    public var band3RangeDb: Double
    public var band3AttackMs: Double
    public var band3ReleaseMs: Double

    public var band4Mode: Double
    public var band4Freq: Double
    public var band4Q: Double
    public var band4ThresholdDb: Double
    public var band4Ratio: Double
    public var band4RangeDb: Double
    public var band4AttackMs: Double
    public var band4ReleaseMs: Double

    public static let bandCount = 4
    public static let paramsPerBand = 8
    /// 32. The automation-slot count and the `(0...31)` guard's upper bound.
    public static var slotCount: Int { bandCount * paramsPerBand }

    /// ⛔ **EVERY RANGE IS MIRRORED FROM AN EXISTING CONSTANT, NEVER RE-SPELLED.**
    /// A second spelling of the same range is how two controls in one tree come
    /// to disagree — the argument `EQFilterResponse.swift:144-148` already makes
    /// about the Nyquist clamp.
    public static var freqRange: ClosedRange<Double> { EQParams.peakFreqRange }
    public static var qRange: ClosedRange<Double> { EQParams.qRange }
    public static var rangeDbRange: ClosedRange<Double> { EQParams.gainDbRange }
    public static var thresholdRange: ClosedRange<Double> { CompressorParams.thresholdRange }
    public static var ratioRange: ClosedRange<Double> { CompressorParams.ratioRange }
    public static var attackRange: ClosedRange<Double> { CompressorParams.attackRange }
    public static var releaseRange: ClosedRange<Double> { CompressorParams.releaseRange }
    public static let modeRange: ClosedRange<Double> = 0...2

    /// ⛔ **HARD-CODED AT THE COMPRESSOR'S OWN DEFAULT**, not exposed. Read by
    /// the render thread and by the tests, and by nothing else — one home.
    /// ⚠️ A 6 dB knee starts working 3 dB BELOW the threshold: `depth` is zero
    /// only while `2·over ≤ −6`, i.e. `L ≤ T − 3`. At `over == 0` exactly the
    /// knee already gives `0.5625 dB` at ratio 4. Any test that wants a null
    /// from a band that is ON must hold the in-band level at or below `T − 3`.
    public static let kneeDb = 6.0

    /// The four default centres, spread so the cards read left-to-right like an
    /// EQ. `band` is 1-based.
    public static func defaultFreq(band: Int) -> Double {
        switch band {
        case 1: return 120
        case 2: return 500
        case 3: return 3_000
        default: return 8_000
        }
    }

    /// Which side of the threshold triggers the band. Raw values are the wire
    /// numbers and are FROZEN.
    ///
    /// ⭐ The DIRECTION the band then moves is the SIGN of `rangeDb`, not a
    /// third control — two params, four musically distinct behaviours:
    /// above+negative = cut when loud (de-ess, de-harsh, tame a boxy 300 Hz);
    /// above+positive = boost when loud (upward excitement);
    /// below+positive = boost when quiet (restore air on a quiet passage);
    /// below+negative = cut when quiet (one-band downward expansion).
    public enum Mode: Int, Sendable, CaseIterable {
        /// ⛔ A TRUE no-op: the section is not stepped at all. The default.
        case off = 0
        case above = 1
        case below = 2
    }

    /// Snaps a raw wire value onto a mode. The `ClipperParams.mode(at:)` /
    /// `RingModParams.waveform(at:)` precedent: rounds, clamps and falls back
    /// rather than trapping, because `Int()` **TRAPS** on a NaN and a
    /// field-by-field automation overlay poke bypasses `init`'s clamping.
    public static func mode(at value: Double) -> Mode {
        guard value.isFinite else { return .off }
        let index = Int(value.clamped(to: modeRange).rounded())
        return Mode(rawValue: index) ?? .off
    }

    /// The 32 param names in SLOT ORDER — the one home for the name↔slot
    /// mapping, so `specs(for:)`, the wire surface and the tests cannot fork.
    /// Not render-thread state: built once, read off the main actor.
    public static let paramNames: [String] = (1...bandCount).flatMap { band in
        ["band\(band)Mode", "band\(band)Freq", "band\(band)Q", "band\(band)ThresholdDb",
         "band\(band)Ratio", "band\(band)RangeDb", "band\(band)AttackMs",
         "band\(band)ReleaseMs"]
    }

    /// Reads one param by wire name; nil for an unknown name. ⚠️ Not on the
    /// render path — `DynamicEQEffect` addresses params by SLOT, never by name.
    public func value(forParamName name: String) -> Double? {
        switch name {
        case "band1Mode": return band1Mode
        case "band1Freq": return band1Freq
        case "band1Q": return band1Q
        case "band1ThresholdDb": return band1ThresholdDb
        case "band1Ratio": return band1Ratio
        case "band1RangeDb": return band1RangeDb
        case "band1AttackMs": return band1AttackMs
        case "band1ReleaseMs": return band1ReleaseMs
        case "band2Mode": return band2Mode
        case "band2Freq": return band2Freq
        case "band2Q": return band2Q
        case "band2ThresholdDb": return band2ThresholdDb
        case "band2Ratio": return band2Ratio
        case "band2RangeDb": return band2RangeDb
        case "band2AttackMs": return band2AttackMs
        case "band2ReleaseMs": return band2ReleaseMs
        case "band3Mode": return band3Mode
        case "band3Freq": return band3Freq
        case "band3Q": return band3Q
        case "band3ThresholdDb": return band3ThresholdDb
        case "band3Ratio": return band3Ratio
        case "band3RangeDb": return band3RangeDb
        case "band3AttackMs": return band3AttackMs
        case "band3ReleaseMs": return band3ReleaseMs
        case "band4Mode": return band4Mode
        case "band4Freq": return band4Freq
        case "band4Q": return band4Q
        case "band4ThresholdDb": return band4ThresholdDb
        case "band4Ratio": return band4Ratio
        case "band4RangeDb": return band4RangeDb
        case "band4AttackMs": return band4AttackMs
        case "band4ReleaseMs": return band4ReleaseMs
        default: return nil
        }
    }

    /// Writes one param by wire name; false for an unknown name (the caller
    /// leaves the descriptor untouched). The value arrives already clamped to
    /// the spec range by `ProjectStore.setEffectParam` — the `setVolume`
    /// precedent — and the render side re-clamps anyway.
    public mutating func setValue(_ value: Double, forParamName name: String) -> Bool {
        switch name {
        case "band1Mode": band1Mode = value
        case "band1Freq": band1Freq = value
        case "band1Q": band1Q = value
        case "band1ThresholdDb": band1ThresholdDb = value
        case "band1Ratio": band1Ratio = value
        case "band1RangeDb": band1RangeDb = value
        case "band1AttackMs": band1AttackMs = value
        case "band1ReleaseMs": band1ReleaseMs = value
        case "band2Mode": band2Mode = value
        case "band2Freq": band2Freq = value
        case "band2Q": band2Q = value
        case "band2ThresholdDb": band2ThresholdDb = value
        case "band2Ratio": band2Ratio = value
        case "band2RangeDb": band2RangeDb = value
        case "band2AttackMs": band2AttackMs = value
        case "band2ReleaseMs": band2ReleaseMs = value
        case "band3Mode": band3Mode = value
        case "band3Freq": band3Freq = value
        case "band3Q": band3Q = value
        case "band3ThresholdDb": band3ThresholdDb = value
        case "band3Ratio": band3Ratio = value
        case "band3RangeDb": band3RangeDb = value
        case "band3AttackMs": band3AttackMs = value
        case "band3ReleaseMs": band3ReleaseMs = value
        case "band4Mode": band4Mode = value
        case "band4Freq": band4Freq = value
        case "band4Q": band4Q = value
        case "band4ThresholdDb": band4ThresholdDb = value
        case "band4Ratio": band4Ratio = value
        case "band4RangeDb": band4RangeDb = value
        case "band4AttackMs": band4AttackMs = value
        case "band4ReleaseMs": band4ReleaseMs = value
        default: return false
        }
        return true
    }

    /// ⛔ **ALL 32 DEFAULT `mode` TO 0 = OFF, SO A FRESHLY ADDED DYNAMIC EQ IS
    /// BIT-EXACT TRANSPARENT.** That mirrors `.eq` (a fresh EQ does nothing) and
    /// makes the neutrality gate the DEFAULT render rather than a special
    /// configuration. The discoverability cost is real and is paid in
    /// `fx.describe` prose.
    ///
    /// Non-finite guards ahead of every clamp: `clamped(to:)` on a NaN returns
    /// the NaN, and `mode` reaches an `Int()` conversion that would TRAP on one.
    public init(
        band1Mode: Double = 0, band1Freq: Double = 120, band1Q: Double = 2,
        band1ThresholdDb: Double = -18, band1Ratio: Double = 4, band1RangeDb: Double = -6,
        band1AttackMs: Double = 10, band1ReleaseMs: Double = 100,
        band2Mode: Double = 0, band2Freq: Double = 500, band2Q: Double = 2,
        band2ThresholdDb: Double = -18, band2Ratio: Double = 4, band2RangeDb: Double = -6,
        band2AttackMs: Double = 10, band2ReleaseMs: Double = 100,
        band3Mode: Double = 0, band3Freq: Double = 3_000, band3Q: Double = 2,
        band3ThresholdDb: Double = -18, band3Ratio: Double = 4, band3RangeDb: Double = -6,
        band3AttackMs: Double = 10, band3ReleaseMs: Double = 100,
        band4Mode: Double = 0, band4Freq: Double = 8_000, band4Q: Double = 2,
        band4ThresholdDb: Double = -18, band4Ratio: Double = 4, band4RangeDb: Double = -6,
        band4AttackMs: Double = 10, band4ReleaseMs: Double = 100
    ) {
        self.band1Mode = Double(Self.mode(at: band1Mode).rawValue)
        self.band1Freq = Self.clampFreq(band1Freq, band: 1)
        self.band1Q = Self.clampQ(band1Q)
        self.band1ThresholdDb = Self.clampThreshold(band1ThresholdDb)
        self.band1Ratio = Self.clampRatio(band1Ratio)
        self.band1RangeDb = Self.clampRangeDb(band1RangeDb)
        self.band1AttackMs = Self.clampAttack(band1AttackMs)
        self.band1ReleaseMs = Self.clampRelease(band1ReleaseMs)
        self.band2Mode = Double(Self.mode(at: band2Mode).rawValue)
        self.band2Freq = Self.clampFreq(band2Freq, band: 2)
        self.band2Q = Self.clampQ(band2Q)
        self.band2ThresholdDb = Self.clampThreshold(band2ThresholdDb)
        self.band2Ratio = Self.clampRatio(band2Ratio)
        self.band2RangeDb = Self.clampRangeDb(band2RangeDb)
        self.band2AttackMs = Self.clampAttack(band2AttackMs)
        self.band2ReleaseMs = Self.clampRelease(band2ReleaseMs)
        self.band3Mode = Double(Self.mode(at: band3Mode).rawValue)
        self.band3Freq = Self.clampFreq(band3Freq, band: 3)
        self.band3Q = Self.clampQ(band3Q)
        self.band3ThresholdDb = Self.clampThreshold(band3ThresholdDb)
        self.band3Ratio = Self.clampRatio(band3Ratio)
        self.band3RangeDb = Self.clampRangeDb(band3RangeDb)
        self.band3AttackMs = Self.clampAttack(band3AttackMs)
        self.band3ReleaseMs = Self.clampRelease(band3ReleaseMs)
        self.band4Mode = Double(Self.mode(at: band4Mode).rawValue)
        self.band4Freq = Self.clampFreq(band4Freq, band: 4)
        self.band4Q = Self.clampQ(band4Q)
        self.band4ThresholdDb = Self.clampThreshold(band4ThresholdDb)
        self.band4Ratio = Self.clampRatio(band4Ratio)
        self.band4RangeDb = Self.clampRangeDb(band4RangeDb)
        self.band4AttackMs = Self.clampAttack(band4AttackMs)
        self.band4ReleaseMs = Self.clampRelease(band4ReleaseMs)
    }

    private static func clampFreq(_ v: Double, band: Int) -> Double {
        (v.isFinite ? v : defaultFreq(band: band)).clamped(to: freqRange)
    }
    private static func clampQ(_ v: Double) -> Double {
        (v.isFinite ? v : 2).clamped(to: qRange)
    }
    private static func clampThreshold(_ v: Double) -> Double {
        (v.isFinite ? v : -18).clamped(to: thresholdRange)
    }
    private static func clampRatio(_ v: Double) -> Double {
        (v.isFinite ? v : 4).clamped(to: ratioRange)
    }
    private static func clampRangeDb(_ v: Double) -> Double {
        (v.isFinite ? v : -6).clamped(to: rangeDbRange)
    }
    private static func clampAttack(_ v: Double) -> Double {
        (v.isFinite ? v : 10).clamped(to: attackRange)
    }
    private static func clampRelease(_ v: Double) -> Double {
        (v.isFinite ? v : 100).clamped(to: releaseRange)
    }

    private enum CodingKeys: String, CodingKey {
        case band1Mode, band1Freq, band1Q, band1ThresholdDb
        case band1Ratio, band1RangeDb, band1AttackMs, band1ReleaseMs
        case band2Mode, band2Freq, band2Q, band2ThresholdDb
        case band2Ratio, band2RangeDb, band2AttackMs, band2ReleaseMs
        case band3Mode, band3Freq, band3Q, band3ThresholdDb
        case band3Ratio, band3RangeDb, band3AttackMs, band3ReleaseMs
        case band4Mode, band4Freq, band4Q, band4ThresholdDb
        case band4Ratio, band4RangeDb, band4AttackMs, band4ReleaseMs
    }

    /// ⛔⛔ **EVERY KEY IS REQUIRED — `decode`, NOT `decodeIfPresent ?? default`
    /// — AND THAT IS THE POINT OF THIS DECODER.** The tree's law is that
    /// bit-exactness needs BOTH a decode test AND a byte gate, because a byte
    /// gate over rendered demos is **blind to a `Codable` decode default**: the
    /// demo harness builds params through `fx.add` → the MEMBERWISE init, so
    /// `init(from:)` never runs. Proven by plant this cycle — a `?? 0 → ?? 1` on
    /// a decode default passed the byte gate (exit 0, MISSED) while the same
    /// change to the memberwise default was caught. **v1 ships with no `??` at
    /// all, so there is nothing for the byte gate to be blind to**, and
    /// `DynamicEQParamsTests` freezes that by asserting a JSON missing any key
    /// THROWS.
    ///
    /// ⚠️ This DIVERGES from the design's literal "synthesized `Codable`, no
    /// custom `init(from:)`" while keeping its stated REASON intact. Synthesized
    /// decoding would bypass the clamping init, making this the ONE params
    /// struct of 22 that does not clamp on decode. Required keys through the
    /// clamping init gives both properties.
    ///
    /// ⛔ **THE FIRST v2 APPEND CHANGES THIS.** The moment this kind gains an
    /// additive optional (a `shape`, a `gainDb`, a `detectorSource`) it
    /// inherits the `EQParams` v2 pattern and ACQUIRES a decode default the byte
    /// gate cannot see. That is the moment to re-run the non-interchangeability
    /// plant in both directions and record the result — claiming the pair is
    /// proven now, when there is no decode default to plant on, would be an
    /// assumption dressed as a measurement (design §10 G2).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            band1Mode: try c.decode(Double.self, forKey: .band1Mode),
            band1Freq: try c.decode(Double.self, forKey: .band1Freq),
            band1Q: try c.decode(Double.self, forKey: .band1Q),
            band1ThresholdDb: try c.decode(Double.self, forKey: .band1ThresholdDb),
            band1Ratio: try c.decode(Double.self, forKey: .band1Ratio),
            band1RangeDb: try c.decode(Double.self, forKey: .band1RangeDb),
            band1AttackMs: try c.decode(Double.self, forKey: .band1AttackMs),
            band1ReleaseMs: try c.decode(Double.self, forKey: .band1ReleaseMs),
            band2Mode: try c.decode(Double.self, forKey: .band2Mode),
            band2Freq: try c.decode(Double.self, forKey: .band2Freq),
            band2Q: try c.decode(Double.self, forKey: .band2Q),
            band2ThresholdDb: try c.decode(Double.self, forKey: .band2ThresholdDb),
            band2Ratio: try c.decode(Double.self, forKey: .band2Ratio),
            band2RangeDb: try c.decode(Double.self, forKey: .band2RangeDb),
            band2AttackMs: try c.decode(Double.self, forKey: .band2AttackMs),
            band2ReleaseMs: try c.decode(Double.self, forKey: .band2ReleaseMs),
            band3Mode: try c.decode(Double.self, forKey: .band3Mode),
            band3Freq: try c.decode(Double.self, forKey: .band3Freq),
            band3Q: try c.decode(Double.self, forKey: .band3Q),
            band3ThresholdDb: try c.decode(Double.self, forKey: .band3ThresholdDb),
            band3Ratio: try c.decode(Double.self, forKey: .band3Ratio),
            band3RangeDb: try c.decode(Double.self, forKey: .band3RangeDb),
            band3AttackMs: try c.decode(Double.self, forKey: .band3AttackMs),
            band3ReleaseMs: try c.decode(Double.self, forKey: .band3ReleaseMs),
            band4Mode: try c.decode(Double.self, forKey: .band4Mode),
            band4Freq: try c.decode(Double.self, forKey: .band4Freq),
            band4Q: try c.decode(Double.self, forKey: .band4Q),
            band4ThresholdDb: try c.decode(Double.self, forKey: .band4ThresholdDb),
            band4Ratio: try c.decode(Double.self, forKey: .band4Ratio),
            band4RangeDb: try c.decode(Double.self, forKey: .band4RangeDb),
            band4AttackMs: try c.decode(Double.self, forKey: .band4AttackMs),
            band4ReleaseMs: try c.decode(Double.self, forKey: .band4ReleaseMs))
    }
}

/// Static parameter schema for every effect kind — the single source of truth
/// for `fx.describe`, control-layer validation, and MCP tool schemas.
public struct EffectParamSpec: Sendable, Equatable {
    public let name: String
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    /// Human-readable unit ("linear", "dB", "Hz", "s", "ratio", "%").
    public let unit: String
    /// How the parameter's 0…1 travel maps onto `range` — **DECLARED**, never
    /// inferred (m39-a). Both editor models read this instead of re-deriving
    /// `unit == "Hz"` for themselves, and the m39-e depth law is defined in
    /// terms of it (`docs/design/2026-09-19-modulation-layer.md` §7.3): full
    /// depth on a `.logarithmic` target means OCTAVES, which a raw linear
    /// fraction of a 40–18 000 Hz span cannot express.
    ///
    /// ⚠️ Deliberately has NO default on the init. A defaulted `.linear` is
    /// inference-by-omission — the exact shape this field exists to remove —
    /// and it would make a future frequency parameter silently linear.
    public let curve: ParamCurve
    /// Whether MODULATION may address this parameter, and how honestly
    /// (m39-e §6.1). A rate warning tells an agent whether a 30 Hz LFO will
    /// alias; it does not tell it that `eq.peak1Freq` will zipper at ANY rate,
    /// or that `delay.timeMs` clicks on every step because the read offset is
    /// an `Int`. Both are properties of the TARGET, both are verified in the
    /// effect source, and both must be answerable before the route is created.
    ///
    /// **Frozen invariant, and a test asserts it mechanically:** modulation
    /// refuses a SUPERSET of what automation refuses. Everything automation
    /// already refuses (`.audioUnit` params, `delay.sync`, `delay.division`)
    /// modulation also refuses; modulation additionally refuses DISCRETE
    /// params. Modulation never permits something automation forbids.
    ///
    /// ⚠️ Deliberately has NO default on the init, for exactly the reason
    /// `curve` has none: a defaulted `.yes` is inference-by-omission, and it
    /// would make a future boolean toggle silently modulatable. The split is
    /// pinned at 31 yes / 18 warned / 15 refused across all 11 kinds, so a new
    /// param cannot be added without a verdict.
    public let modulatable: Modulatable
    /// Optional teaching line for params whose numeric surface hides extra
    /// semantics (nil-means-off filters, 12/24 slope snapping, 0/1 band
    /// bypass) — surfaced verbatim by `fx.describe` (m22-a).
    public let note: String?

    public init(name: String, range: ClosedRange<Double>, defaultValue: Double, unit: String,
                curve: ParamCurve, modulatable: Modulatable, note: String? = nil) {
        self.name = name
        self.range = range
        self.defaultValue = defaultValue
        self.unit = unit
        self.curve = curve
        self.modulatable = modulatable
        self.note = note
    }

    /// Schemas per kind. M4 (iv) extends this table as kinds land.
    public static func specs(for kind: EffectDescriptor.Kind) -> [EffectParamSpec] {
        switch kind {
        case .gain:
            return [EffectParamSpec(
                name: "gainLinear", range: GainParams.gainRange,
                defaultValue: 1, unit: "linear", curve: .linear, modulatable: .yes,
                // m27-c: the teaching a bare 0…16 cannot carry — one home,
                // read by every client through `fx.describe`.
                note: "Linear multiplier, not decibels: 1 is unity (no change), "
                    + "2 is +6 dB, 4 is +12 dB, and the 16 maximum is +24.08 dB "
                    + "(dB = 20·log10(gainLinear)). The ceiling is deliberately "
                    + "wide because sound-bank / General-MIDI material is quiet "
                    + "— a solo GM piano part renders around -28 LUFS at "
                    + "velocity 100 and near -35 LUFS at velocity 64, so "
                    + "reaching a -14 LUFS streaming level takes +14 to +21 dB. "
                    + "One insert now covers that; you no longer need to chain "
                    + "two. This is a plain multiply with no protection of its "
                    + "own, so large boosts can drive the mix into clipping "
                    + "— put a limiter AFTER this insert, and remember a "
                    + "normalizing bounce applies its gain after the whole "
                    + "master chain. Out-of-range values are clamped, not "
                    + "rejected, and the clamp is reported in `warnings`."),
                // m38-a polarity — APPENDED so the automation slot index of
                // gainLinear (0) never moves (the limiter `truePeak`
                // precedent). Binary on the numeric surface: >= 0.5 = on.
                EffectParamSpec(
                    name: "invertPolarity", range: 0...1,
                    defaultValue: 0, unit: "linear", curve: .linear, modulatable: .refused,
                    note: "Polarity (phase) invert — the Ø switch on a hardware "
                        + "channel strip. 0 (default) leaves the signal alone; 1 "
                        + "multiplies it by -1, flipping every sample around "
                        + "zero. It changes NO level and NO tone on its own: a "
                        + "track heard alone sounds identical either way. What it "
                        + "changes is how the track SUMS with others — flip a "
                        + "mic that was wired backwards, try both polarities on "
                        + "the second mic of a two-mic pair and keep the one with "
                        + "more low end, or null-test two renders by inverting "
                        + "one and checking the sum goes silent. Values are "
                        + "binary: anything >= 0.5 is on. Flipping during "
                        + "playback ramps through zero over ~5 ms — a brief dip, "
                        + "not a click.")]
        case .eq:
            return [
                EffectParamSpec(name: "lowShelfFreq", range: EQParams.lowShelfFreqRange,
                                defaultValue: 100, unit: "Hz", curve: .logarithmic, modulatable: .warned),
                EffectParamSpec(name: "lowShelfGainDb", range: EQParams.gainDbRange,
                                defaultValue: 0, unit: "dB", curve: .linear, modulatable: .warned),
                EffectParamSpec(name: "peak1Freq", range: EQParams.peakFreqRange,
                                defaultValue: 500, unit: "Hz", curve: .logarithmic, modulatable: .warned),
                EffectParamSpec(name: "peak1GainDb", range: EQParams.gainDbRange,
                                defaultValue: 0, unit: "dB", curve: .linear, modulatable: .warned),
                EffectParamSpec(name: "peak1Q", range: EQParams.qRange,
                                defaultValue: 1, unit: "linear", curve: .linear, modulatable: .warned),
                EffectParamSpec(name: "peak2Freq", range: EQParams.peakFreqRange,
                                defaultValue: 3_000, unit: "Hz", curve: .logarithmic, modulatable: .warned),
                EffectParamSpec(name: "peak2GainDb", range: EQParams.gainDbRange,
                                defaultValue: 0, unit: "dB", curve: .linear, modulatable: .warned),
                EffectParamSpec(name: "peak2Q", range: EQParams.qRange,
                                defaultValue: 1, unit: "linear", curve: .linear, modulatable: .warned),
                EffectParamSpec(name: "highShelfFreq", range: EQParams.highShelfFreqRange,
                                defaultValue: 8_000, unit: "Hz", curve: .logarithmic, modulatable: .warned),
                EffectParamSpec(name: "highShelfGainDb", range: EQParams.gainDbRange,
                                defaultValue: 0, unit: "dB", curve: .linear, modulatable: .warned),
                // m22-a EQ v2 — APPENDED so the automation slot indices of the
                // ten original params (0…9) never move (slots = spec order).
                EffectParamSpec(name: "highPassFreq", range: EQParams.highPassFreqRange,
                                defaultValue: 20, unit: "Hz", curve: .logarithmic, modulatable: .warned,
                                note: "High-pass corner (−3 dB, Butterworth). The filter is OFF "
                                    + "on a fresh EQ; setting this turns it on."),
                EffectParamSpec(name: "highPassSlopeDbPerOct", range: EQParams.slopeRange,
                                defaultValue: 12, unit: "dB/oct", curve: .linear, modulatable: .refused,
                                note: "High-pass steepness — only 12 or 24; other values snap "
                                    + "to the nearer."),
                EffectParamSpec(name: "highPassEnabled", range: 0...1,
                                defaultValue: 0, unit: "linear", curve: .linear, modulatable: .refused,
                                note: "0 bypasses the high-pass without losing its settings; 1 "
                                    + "turns it on (from a fresh EQ it starts at 20 Hz)."),
                EffectParamSpec(name: "lowShelfQ", range: EQParams.qRange,
                                defaultValue: EQParams.defaultShelfQ, unit: "linear", curve: .linear, modulatable: .warned,
                                note: "Low-shelf resonance. The default 0.707 is the classic "
                                    + "gentle shelf every pre-existing project uses."),
                EffectParamSpec(name: "lowShelfEnabled", range: 0...1,
                                defaultValue: 1, unit: "linear", curve: .linear, modulatable: .refused,
                                note: "0 bypasses just this band (a true no-op, identical to "
                                    + "the band being absent); 1 re-enables it."),
                EffectParamSpec(name: "peak1Enabled", range: 0...1,
                                defaultValue: 1, unit: "linear", curve: .linear, modulatable: .refused,
                                note: "0 bypasses just this band (a true no-op); 1 re-enables."),
                EffectParamSpec(name: "peak2Enabled", range: 0...1,
                                defaultValue: 1, unit: "linear", curve: .linear, modulatable: .refused,
                                note: "0 bypasses just this band (a true no-op); 1 re-enables."),
                EffectParamSpec(name: "highShelfQ", range: EQParams.qRange,
                                defaultValue: EQParams.defaultShelfQ, unit: "linear", curve: .linear, modulatable: .warned,
                                note: "High-shelf resonance. The default 0.707 is the classic "
                                    + "gentle shelf every pre-existing project uses."),
                EffectParamSpec(name: "highShelfEnabled", range: 0...1,
                                defaultValue: 1, unit: "linear", curve: .linear, modulatable: .refused,
                                note: "0 bypasses just this band (a true no-op); 1 re-enables."),
                EffectParamSpec(name: "lowPassFreq", range: EQParams.lowPassFreqRange,
                                defaultValue: 20_000, unit: "Hz", curve: .logarithmic, modulatable: .warned,
                                note: "Low-pass corner (−3 dB, Butterworth). The filter is OFF "
                                    + "on a fresh EQ; setting this turns it on."),
                EffectParamSpec(name: "lowPassSlopeDbPerOct", range: EQParams.slopeRange,
                                defaultValue: 12, unit: "dB/oct", curve: .linear, modulatable: .refused,
                                note: "Low-pass steepness — only 12 or 24; other values snap "
                                    + "to the nearer."),
                EffectParamSpec(name: "lowPassEnabled", range: 0...1,
                                defaultValue: 0, unit: "linear", curve: .linear, modulatable: .refused,
                                note: "0 bypasses the low-pass without losing its settings; 1 "
                                    + "turns it on (from a fresh EQ it starts at 20 kHz)."),
            ]
        case .compressor:
            return [
                EffectParamSpec(name: "thresholdDb", range: CompressorParams.thresholdRange,
                                defaultValue: -18, unit: "dB", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "ratio", range: CompressorParams.ratioRange,
                                defaultValue: 4, unit: "ratio", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "attackMs", range: CompressorParams.attackRange,
                                defaultValue: 10, unit: "ms", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "releaseMs", range: CompressorParams.releaseRange,
                                defaultValue: 100, unit: "ms", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "kneeDb", range: CompressorParams.kneeRange,
                                defaultValue: 6, unit: "dB", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "makeupDb", range: CompressorParams.makeupRange,
                                defaultValue: 0, unit: "dB", curve: .linear, modulatable: .yes),
                // m23-ck parallel compression — APPENDED so the automation slot
                // indices of the six original params (0…5) never move.
                EffectParamSpec(name: "mix", range: CompressorParams.mixRange,
                                defaultValue: 1, unit: "linear", curve: .linear, modulatable: .yes,
                                note: "Parallel ('New York') compression blend: 1 (the default) "
                                    + "is fully compressed — exactly the classic behaviour — and "
                                    + "0 is a bit-exact bypass of the whole unit, makeup gain "
                                    + "included. Values between blend the compressed signal over "
                                    + "the untouched input, which is what a duplicate track plus "
                                    + "a send used to be for: crush hard (low threshold, high "
                                    + "ratio, high makeup) then dial mix to ~0.3-0.5 for density "
                                    + "that keeps the original transients. With a sidechain key "
                                    + "attached the key still only drives the DETECTOR — the dry "
                                    + "half of the blend is always this effect's own input."),
                // ⛔⛔ m39-ae THE DE-ESSER — APPENDED at slots 7/8/9 so the
                // automation slot indices of the six original params (0…5) and
                // of m23-ck's `mix` (6) never move. `.compressor` has been
                // shipped for a very long time; an INSERT here would silently
                // repoint every automation lane in every saved project, with no
                // error anywhere.
                EffectParamSpec(name: "detectorMode", range: CompressorParams.detectorModeRange,
                                defaultValue: 0, unit: "linear", curve: .linear,
                                modulatable: .refused,
                                note: "⭐ THIS IS THE DE-ESSER. There is no separate 'deEsser' "
                                    + "effect kind — a de-esser IS a compressor that only listens "
                                    + "to the sibilant band, so it lives here. 0 (the default) is "
                                    + "OFF: the detector hears the signal flat, which is exactly "
                                    + "what this kind has always done, bit-for-bit. 1 is "
                                    + "BAND-PASS: the detector hears only a band around "
                                    + "detectorFreqHz — park it on the 'sss' (5000-9000 Hz on most "
                                    + "voices) and the compressor ignores everything else. 2 is "
                                    + "HIGH-PASS: the detector hears everything above "
                                    + "detectorFreqHz, which catches sibilance that moves around "
                                    + "(an 'sh' sits lower than an 's') but also hears cymbals and "
                                    + "breath. ⛔ WIDEBAND, NOT SPLIT-BAND: when it fires the WHOLE "
                                    + "signal ducks for the length of the 'sss', it does not carve "
                                    + "the band out and leave the rest playing. That is why it "
                                    + "adds ZERO latency and why an existing project cannot shift "
                                    + "in time. Great on a vocal track, wrong on a full mix. "
                                    + "⚠️ DISCRETE - automate it with hold steps, never a ramp, and "
                                    + "modulation refuses it outright. Values snap to the nearest "
                                    + "of 0/1/2."),
                EffectParamSpec(name: "detectorFreqHz", range: CompressorParams.detectorFreqRange,
                                defaultValue: 6_500, unit: "Hz", curve: .logarithmic,
                                modulatable: .warned,
                                note: "Where the de-ess detector listens: the band CENTRE at "
                                    + "detectorMode 1, the corner at mode 2. INERT at mode 0 — the "
                                    + "detector does not read it at all, so setting it on a plain "
                                    + "compressor is a no-op rather than a mistake. 6500 (the "
                                    + "default) is the middle of where 'sss' lives; a deeper voice "
                                    + "wants 5000-6000 and a bright one 7000-9000. ⚠️ MODULATION IS "
                                    + "WARNED, not refused: this is a FILTER corner, and moving it "
                                    + "recomputes biquad coefficients — the eq.peak1Freq problem, "
                                    + "so it zippers at any rate. Automation between sections is "
                                    + "fine; an LFO on it is not what you want."),
                EffectParamSpec(name: "detectorQ", range: CompressorParams.detectorQRange,
                                defaultValue: 2, unit: "linear", curve: .linear,
                                modulatable: .warned,
                                note: "⚠️ MEANS TWO DIFFERENT THINGS, both live. At detectorMode 1 "
                                    + "it is the band's WIDTH: bandwidth is detectorFreqHz / Q, so "
                                    + "the default 2 is about an octave and a half, and the band's "
                                    + "peak is 0 dB at EVERY Q — widening it does not quietly move "
                                    + "your threshold. At detectorMode 2 it is the high-pass "
                                    + "corner's RESONANCE: the response AT the corner IS Q, so the "
                                    + "default 2 puts a deliberate +6 dB emphasis right where "
                                    + "sibilance starts; use 0.707 for a flat Butterworth corner. "
                                    + "INERT at mode 0. Warned for modulation for the same "
                                    + "coefficient-zipper reason as detectorFreqHz."),
            ]
        case .limiter:
            return [
                EffectParamSpec(name: "ceilingDb", range: LimiterParams.ceilingRange,
                                defaultValue: -1, unit: "dB", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "releaseMs", range: LimiterParams.releaseRange,
                                defaultValue: 50, unit: "ms", curve: .linear, modulatable: .yes),
                // m23-ch true peak — APPENDED so the automation slot indices
                // of ceilingDb (0) and releaseMs (1) never move.
                EffectParamSpec(name: "truePeak", range: 0...1,
                                defaultValue: 0, unit: "linear", curve: .linear, modulatable: .refused,
                                note: "Which peak ceilingDb counts. 0 (default) = dBFS "
                                    + "SAMPLE peak: no output sample exceeds it, but a dBTP "
                                    + "meter reconstructs between samples and reads ~0.4-1 dB "
                                    + "higher on dense material - arithmetic, not a bug. "
                                    + "1 = dBTP TRUE peak, via 4x oversampled detection "
                                    + "(ITU-R BS.1770-4), so a -1 dBTP delivery spec is met on "
                                    + "the first render with no manual headroom; it limits "
                                    + "~0.3-1 dB harder, which is exactly the inter-sample "
                                    + "overshoot it removes. Same 5 ms latency either way."),
            ]
        // ⛔ m39-l, §5.2 — `.reverb` IS LEFT ALONE AND DOCUMENTED HONESTLY.
        // Not one byte of `ReverbEffect` changes and the kind is NOT deprecated
        // in prose: deprecation would create a second-class effect that agents
        // route around while real projects still render through it, and
        // Freeverb's small, bright, dense room is a genuinely good sound the
        // hall does not replicate. What lands here is ADDITIVE `note` metadata
        // — no name, range, default or POSITION moves, so no automation slot
        // moves and no saved project changes.
        case .reverb:
            return [
                EffectParamSpec(name: "roomSize", range: ReverbParams.roomSizeRange,
                                defaultValue: 0.5, unit: "linear", curve: .linear, modulatable: .warned,
                                note: "⚠️ THIS CONTROLS HOW LONG THE TAIL RINGS (the decay), "
                                    + "NOT HOW BIG THE SPACE IS. The name is historical and "
                                    + "cannot be changed without breaking every saved project "
                                    + "that automates it. Under the hood it scales the feedback "
                                    + "of eight fixed-length comb filters: the room's "
                                    + "dimensions are compile-time constants and no parameter "
                                    + "reaches them, so this room has exactly one shape "
                                    + "forever. Higher = longer ring, not a bigger room. FOR A "
                                    + "REAL SIZE CONTROL USE THE `hallReverb` KIND, whose "
                                    + "`sizeMeters` scales the actual delay-line lengths (and "
                                    + "whose `decaySeconds` is a real RT60 in seconds)."),
                EffectParamSpec(name: "damping", range: ReverbParams.dampingRange,
                                defaultValue: 0.5, unit: "linear", curve: .linear, modulatable: .yes,
                                note: "How quickly the high frequencies are absorbed inside the "
                                    + "tank - a single one-pole filter in each comb loop. This "
                                    + "is a tone control on the tail, not a frequency-dependent "
                                    + "decay time: there is one damping setting for the whole "
                                    + "spectrum and no crossover. If you need the bass and the "
                                    + "treble to ring for DIFFERENT lengths of time, that is "
                                    + "`hallReverb`'s two-band absorption "
                                    + "(`lowDecayMultiplier` / `highDecayMultiplier` with their "
                                    + "own crossovers)."),
                EffectParamSpec(name: "mix", range: ReverbParams.mixRange,
                                defaultValue: 0.35, unit: "linear", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "preDelayMs", range: ReverbParams.preDelayRange,
                                defaultValue: 10, unit: "ms", curve: .linear, modulatable: .warned),
                EffectParamSpec(name: "width", range: ReverbParams.widthRange,
                                defaultValue: 1, unit: "linear", curve: .linear, modulatable: .yes),
            ]
        case .delay:
            return [
                EffectParamSpec(name: "timeMs", range: DelayParams.timeRange,
                                defaultValue: 350, unit: "ms", curve: .linear, modulatable: .warned,
                                note: "Free-running delay time. Ignored while sync is 1 — the "
                                    + "effective time is then division × 60000 / tempo BPM, "
                                    + "recomputed on every tempo change; timeMs stays stored "
                                    + "as the unsync fallback."),
                EffectParamSpec(name: "feedback", range: DelayParams.feedbackRange,
                                defaultValue: 0.35, unit: "linear", curve: .linear, modulatable: .yes,
                                note: "How much of each repeat is written back into the "
                                    + "loop. The maximum, 0.999, is an ECHO FREEZE: only "
                                    + "0.0087 dB is lost per repeat, so the echo holds "
                                    + "instead of fading — measured on a 350 ms delay with "
                                    + "highCutHz at 20000, a tail was 3.19 dB down after "
                                    + "110 seconds. (0.95, the old maximum, loses 0.45 dB "
                                    + "per repeat — about four seconds to fade.) ⚠️ THE "
                                    + "CEILING IS 0.999 AND NOT 1.0, ON A MEASUREMENT: at "
                                    + "exactly 1.0 the loop gives back everything it takes, "
                                    + "so whatever it cannot lose grows without bound — a "
                                    + "DC offset into a 10 ms delay measured 9.66 / 96.97 / "
                                    + "193.94 / 290.94 after 1 / 10 / 20 / 30 s, a straight "
                                    + "line with no ceiling, even at the most damped "
                                    + "highCutHz. At 0.999 the same input settled at 94.56 "
                                    + "against its predicted ceiling of 100 = "
                                    + "1/(1 - feedback). ⚠️ LEVEL WARNING: anything you keep "
                                    + "feeding a high-feedback delay builds toward "
                                    + "1/(1 - feedback) times itself at the frequencies that "
                                    + "land on the repeat's comb peaks, over "
                                    + "timeMs/(1 - feedback) seconds. The way to USE a "
                                    + "freeze is to stop feeding it: put the delay on a bus, "
                                    + "send to it, then pull the send to 0 — the loop holds "
                                    + "what it has and takes nothing new. ⚠️ highCutHz is "
                                    + "load-bearing up here; see its note."),
                EffectParamSpec(name: "mix", range: DelayParams.mixRange,
                                defaultValue: 0.3, unit: "linear", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "pingPong", range: DelayParams.pingPongRange,
                                defaultValue: 0, unit: "linear", curve: .linear, modulatable: .refused),
                EffectParamSpec(name: "highCutHz", range: DelayParams.highCutRange,
                                defaultValue: 8_000, unit: "Hz", curve: .logarithmic, modulatable: .yes,
                                note: "A one-pole low-pass INSIDE the feedback loop, so the "
                                    + "first echo is unfiltered and every repeat after it is "
                                    + "darker than the one before. ⚠️ AT HIGH FEEDBACK THIS, "
                                    + "NOT feedback, DECIDES HOW LONG THE TAIL LASTS: "
                                    + "measured on a 350 ms delay at feedback 0.999, a tail "
                                    + "was 3.19 dB down after 110 seconds at 20000 Hz and "
                                    + "gone in about 20 seconds at 500 Hz. If a freeze dies "
                                    + "faster than you expect, this is why. ⚠️ It is NOT a "
                                    + "safety margin: the filter's gain at DC is exactly 1 "
                                    + "at every setting, so it cannot stop a loop at "
                                    + "feedback 1.0 from running away — that is the "
                                    + "feedback ceiling's job, and it stops at 0.999."),
                // m22-f tempo sync — APPENDED so the automation slot indices
                // of the five original params (0…4) never move (slots = spec
                // order; sync/division themselves are deliberately NOT
                // automatable — the render thread can't do tempo math).
                EffectParamSpec(name: "sync", range: 0...1,
                                defaultValue: 0, unit: "linear", curve: .linear, modulatable: .refused,
                                note: "0 = free-running on timeMs (the default); 1 = tempo "
                                    + "sync — the effective time becomes the division's length "
                                    + "at the current tempo, clamped to 1…2000 ms, and follows "
                                    + "tempo changes. Not automatable."),
                EffectParamSpec(name: "division", range: DelayParams.divisionBeatsRange,
                                defaultValue: 1, unit: "beats", curve: .linear, modulatable: .refused,
                                note: "Synced note length as its duration in BEATS (quarter "
                                    + "notes); snaps to the nearest of 1/1…1/32 straight, "
                                    + "dotted (×1.5) or triplet (×2/3): 4=1/1, 1=1/4, "
                                    + "0.75=1/8d, 0.5=1/8, 0.333=1/8t, 0.25=1/16, 0.125=1/32. "
                                    + "Persisted as the token string (\"1/8d\"). Only heard "
                                    + "while sync is 1. Not automatable."),
            ]
        case .saturator:
            // ⛔⛔ ORDER IS FROZEN AND APPEND-ONLY FOREVER. The INDEX of a spec
            // in this array IS the automation slot number
            // (`storeAutomatedParam(slot:value:)`), and unlike `.clipper` this
            // kind HAS SHIPPED — there are saved user automation lanes pointing
            // at slots 0, 1 and 2 right now. m39-ad's `oversampling` is
            // therefore APPENDED at slot 3; putting it anywhere else would
            // silently repoint every one of those lanes.
            return [
                EffectParamSpec(name: "driveDb", range: SaturatorParams.driveRange,
                                defaultValue: 12, unit: "dB", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "mix", range: SaturatorParams.mixRange,
                                defaultValue: 1, unit: "linear", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "outputDb", range: SaturatorParams.outputRange,
                                defaultValue: 0, unit: "dB", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "oversampling",
                                range: SaturatorParams.oversamplingRange,
                                defaultValue: 1, unit: "x", curve: .linear,
                                modulatable: .refused,
                                note: "\u{2B50} THE QUALITY CONTROL. Bending a wave creates new "
                                    + "tones far above anything you can hear. Digital audio "
                                    + "cannot store those, so they FOLD BACK down into the music "
                                    + "as tones that have no musical relationship to what is "
                                    + "playing - a thin metallic fizz sitting behind the sound, "
                                    + "worst on bright material, on high notes, and at high "
                                    + "drive. Running the saturator at 2 or 4 times the session's "
                                    + "sample rate pushes that fold up out of the way and then "
                                    + "filters it off. \u{26A0} THE DEFAULT IS 1, WHICH IS OFF, "
                                    + "AND THAT IS DELIBERATE RATHER THAN A RECOMMENDATION. This "
                                    + "effect shipped long before this control existed, so "
                                    + "projects already using it must keep sounding exactly as "
                                    + "they did; at 1 the machinery is skipped entirely and the "
                                    + "result is bit-for-bit what it always was. IF YOU ARE "
                                    + "ADDING A SATURATOR TODAY AND DRIVING IT HARD, SET THIS TO "
                                    + "4. 1 is also a real creative setting - plenty of records "
                                    + "want that grit, and it is the only way to hear what the "
                                    + "other settings remove. \u{26A0} Only 1, 2 and 4 exist; 3 "
                                    + "rounds UP to 4. It costs CPU roughly in proportion to the "
                                    + "number. \u{26A0}\u{26A0} UNLIKE THE `clipper`'s SETTING OF "
                                    + "THE SAME NAME, THIS ONE CHANGES THE EFFECT'S LATENCY: 0 "
                                    + "samples at 1, and 32 samples at 2 or 4. Delay compensation "
                                    + "removes those 32 automatically so the track still lines up "
                                    + "- read `latencySamples` in the fx.add / fx.setParam result "
                                    + "to see which you have. \u{26A0} NOT AUTOMATABLE and not "
                                    + "modulatable: it is a switch, changing it mid-sound restarts "
                                    + "the internal filters (a tiny click), and it is the one "
                                    + "setting on this effect that moves the latency, which only "
                                    + "a deliberate edit may do."),
            ]
        case .gate:
            return [
                EffectParamSpec(name: "thresholdDb", range: GateParams.thresholdRange,
                                defaultValue: -40, unit: "dB", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "attackMs", range: GateParams.attackRange,
                                defaultValue: 1, unit: "ms", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "holdMs", range: GateParams.holdRange,
                                defaultValue: 50, unit: "ms", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "releaseMs", range: GateParams.releaseRange,
                                defaultValue: 100, unit: "ms", curve: .linear, modulatable: .yes),
            ]
        case .chorus:
            return [
                EffectParamSpec(name: "rateHz", range: ChorusParams.rateRange,
                                defaultValue: 0.8, unit: "Hz", curve: .logarithmic, modulatable: .yes),
                EffectParamSpec(name: "depthMs", range: ChorusParams.depthRange,
                                defaultValue: 3, unit: "ms", curve: .linear, modulatable: .yes),
                EffectParamSpec(name: "mix", range: ChorusParams.mixRange,
                                defaultValue: 0.5, unit: "linear", curve: .linear, modulatable: .yes),
            ]
        case .bassEnhancer:
            return [
                EffectParamSpec(name: "crossoverHz", range: BassEnhancerParams.crossoverRange,
                                defaultValue: 80, unit: "Hz", curve: .logarithmic, modulatable: .yes,
                                note: "The split point. Harmonics are generated FROM everything "
                                    + "below this and added ABOVE it — set it to the low limit "
                                    + "of the speaker you are worried about (a laptop is around "
                                    + "150 Hz, a phone higher). It is not a filter on the sound "
                                    + "you already have: the dry signal is never touched."),
                EffectParamSpec(name: "amount", range: BassEnhancerParams.amountRange,
                                defaultValue: 0.5, unit: "linear", curve: .linear, modulatable: .yes,
                                note: "How much harmonic content is generated. It is NOT a plain "
                                    + "level: raising it also tilts the series toward the higher "
                                    + "partials (a low amount is a warm 2nd-harmonic lift; a high "
                                    + "one is bright and carries further on tiny speakers). 0 "
                                    + "generates nothing and the output is bit-exact dry."),
                EffectParamSpec(name: "mix", range: BassEnhancerParams.mixRange,
                                defaultValue: 1, unit: "linear", curve: .linear, modulatable: .yes,
                                note: "Dry/wet. This effect only ADDS to an untouched dry path, "
                                    + "so mix is a master trim on everything it contributes; 0 "
                                    + "is bit-exact dry. Use `amount` to change the character "
                                    + "and `mix` to change how much of it you hear."),
            ]
        case .bitCrusher:
            return [
                EffectParamSpec(name: "bits", range: BitCrusherParams.bitsRange,
                                defaultValue: 12, unit: "bits", curve: .linear, modulatable: .warned,
                                note: "Storage depth. Whole numbers only - a value in between "
                                    + "rounds. The output takes exactly 2^bits distinct levels, "
                                    + "so 12 (the default, and the E-mu SP-1200's depth) is 4096 "
                                    + "levels and 4 is 16. Lower is grittier: the quantization "
                                    + "error becomes signal-correlated distortion rather than "
                                    + "noise, which is the sound. 16 is effectively clean."),
                EffectParamSpec(name: "downsampleHz", range: BitCrusherParams.downsampleRange,
                                defaultValue: 26_040, unit: "Hz", curve: .logarithmic, modulatable: .yes,
                                note: "The rate the input is sampled and held at, INDEPENDENT of "
                                    + "the project rate. The default 26040 is the SP-1200's "
                                    + "measured rate; 40000 is the Akai MPC60, which is why "
                                    + "MPC60 chops read as cleaner. Every sample is held until "
                                    + "the next capture, so the staircase itself adds harmonics "
                                    + "above this rate that fold back down - that folding is the "
                                    + "character, and antiAlias is what removes it. At or above "
                                    + "the project rate this stage is transparent (so at 88.2 or "
                                    + "96 kHz even the 48000 maximum still halves the rate)."),
                EffectParamSpec(name: "antiAlias", range: 0...1,
                                defaultValue: 0, unit: "linear", curve: .linear, modulatable: .refused,
                                note: "0 (the DEFAULT, and the authentic setting) filters "
                                    + "nothing: content above the reduced Nyquist images back "
                                    + "down into the audible band. That is not a bug - the "
                                    + "SP-1200's signature comes from its converter omitting "
                                    + "exactly this filter, and a politely filtered crusher "
                                    + "sounds clean-but-crunchy instead of gritty. 1 adds a "
                                    + "4th-order low-pass before the sample-and-hold and another "
                                    + "after it, for a modern, tamer crush that keeps the bit "
                                    + "reduction without the aliasing."),
                EffectParamSpec(name: "dither", range: 0...1,
                                defaultValue: 0, unit: "linear", curve: .linear, modulatable: .refused,
                                note: "0 (the DEFAULT, and the authentic setting) leaves the "
                                    + "quantization error correlated with the signal, which is "
                                    + "the crunch you want here. 1 adds plus/minus one-LSB TPDF "
                                    + "dither before quantizing, trading that crunch for a "
                                    + "steady noise floor - the correct choice when you are "
                                    + "reducing depth for delivery rather than for character. "
                                    + "The generator is deterministically seeded, so a render "
                                    + "with dither on is still reproducible."),
                EffectParamSpec(name: "mix", range: BitCrusherParams.mixRange,
                                defaultValue: 1, unit: "linear", curve: .linear, modulatable: .yes,
                                note: "Dry/wet. 0 is a bit-exact bypass of the whole unit; 1 "
                                    + "(the default) is fully crushed. Values between are "
                                    + "parallel crush - blend a little grit under an intact "
                                    + "transient rather than replacing it."),
            ]
        // m39-i — ORDER IS FROZEN (design §6.1.2). Position IS the automation
        // slot: 0 position, 1 resonance, 2 slopeDbPerOct, 3 deadZoneWidth,
        // 4 resonanceTrack. APPEND ONLY, forever.
        case .djFilter:
            return [
                EffectParamSpec(name: "position", range: DJFilterParams.positionRange,
                                defaultValue: 0, unit: "linear", curve: .linear, modulatable: .yes,
                                note: "THE knob, and the whole effect. 0 is the centre and is a "
                                    + "bit-exact bypass — the audio is not touched at all. This "
                                    + "turns the way a club mixer's filter knob turns: LEFT "
                                    + "muffles, RIGHT thins. Turn NEGATIVE and a low-pass falls "
                                    + "down from 20000 Hz, so the treble leaves first and you "
                                    + "are left with a muffled, underwater low end (-1 = the "
                                    + "low-pass sitting at 20 Hz, which is very nearly silence). "
                                    + "Turn POSITIVE and a high-pass climbs up from 20 Hz, so "
                                    + "the bass leaves first and you are left with a thin, "
                                    + "radio-like top (+1 = the high-pass at 20000 Hz, which is "
                                    + "also very nearly silence). The travel is LOG-symmetric: "
                                    + "each side spans the same 9.97 octaves, so equal knob "
                                    + "movement is equal musical movement at both ends, and the "
                                    + "cutoff is 20000 * 0.001^|position| for a NEGATIVE "
                                    + "position and 20 * 1000^position for a POSITIVE one (so "
                                    + "the low-pass corner FALLS as the knob goes more negative, "
                                    + "and the high-pass corner RISES as it goes more "
                                    + "positive). The curve is `linear` because "
                                    + "the range crosses 0 and a logarithmic taper cannot — the "
                                    + "log-ness lives in the cutoff law above. CONSEQUENCE FOR "
                                    + "MODULATION: full depth on this param is +/-2.0, the "
                                    + "entire sweep in BOTH directions, so a depth of 0.25 is a "
                                    + "half-range wobble and 1.0 is a full-throw slam. An "
                                    + "automated sweep on this one param is the classic DJ "
                                    + "filter gesture."),
                EffectParamSpec(name: "resonance", range: DJFilterParams.resonanceRange,
                                defaultValue: 0.25, unit: "linear", curve: .linear, modulatable: .yes,
                                note: "The whistle at the edge of the sweep, and the character "
                                    + "of the whole effect. Q = 0.707 + resonance * 9.293, so 0 "
                                    + "is a clean Butterworth filter with no peak at all and 1 "
                                    + "is Q 10 — a singing, ringing edge just short of "
                                    + "self-oscillation. The resonant peak is level-compensated "
                                    + "(1/sqrt(Q)) so raising this stays roughly level-matched "
                                    + "instead of getting louder; if you want the classic "
                                    + "screaming riser, this is the knob."),
                EffectParamSpec(name: "slopeDbPerOct", range: DJFilterParams.slopeRange,
                                defaultValue: 24, unit: "dB/oct", curve: .linear, modulatable: .refused,
                                note: "Steepness — only 12 or 24; other values snap to the "
                                    + "nearer (the same rule as the EQ's slopes). 24 (the "
                                    + "default) is two cascaded 2-pole sections and cuts hard, "
                                    + "the tight modern club sound; 12 is one section and lets "
                                    + "more through, gentler and more vintage. Resonance is "
                                    + "applied to the SECOND section only, so flipping 12 to 24 "
                                    + "changes how steeply the band disappears WITHOUT changing "
                                    + "how loud the resonant peak is. Discrete, so it is a "
                                    + "topology switch rather than a knob: not modulatable."),
                EffectParamSpec(name: "deadZoneWidth", range: DJFilterParams.deadZoneRange,
                                defaultValue: 0.04, unit: "linear", curve: .linear, modulatable: .yes,
                                note: "How wide the do-nothing centre is, as a fraction of the "
                                    + "knob's travel. Inside it the filter crossfades smoothly "
                                    + "to dry (a raised cosine), so passing THROUGH the centre "
                                    + "during a sweep is a clean handover from one filter to "
                                    + "the other instead of a jump. The default 0.04 is a "
                                    + "comfortable detent you can find by feel; 0 removes the "
                                    + "crossfade entirely and the filter engages the instant "
                                    + "the knob leaves 0. At exactly 0 position the output is "
                                    + "bit-exact dry at any width."),
                EffectParamSpec(name: "resonanceTrack", range: DJFilterParams.resonanceTrackRange,
                                defaultValue: 0, unit: "linear", curve: .linear, modulatable: .yes,
                                note: "How much extra resonance the sweep picks up as it "
                                    + "approaches its extremes — the 'isolator' feel, where a "
                                    + "kill only starts to whistle as it runs out of band. "
                                    + "Q_eff = Q * (1 + resonanceTrack * position^2), so 0 (the "
                                    + "default) keeps resonance constant and predictable across "
                                    + "the whole sweep, and 1 doubles it at full throw while "
                                    + "still leaving the middle of the sweep untouched. This is "
                                    + "a continuous knob rather than a character preset "
                                    + "deliberately: a number can be automated and modulated, "
                                    + "an enum cannot."),
            ]
        // m39-m — ORDER IS FROZEN (design §6.4.1). Position IS the automation
        // slot: 0 carrierHz, 1 mix, 2 waveform, 3 inputHighCutHz,
        // 4 stereoSpreadDeg. APPEND ONLY, forever.
        case .ringMod:
            return [
                EffectParamSpec(name: "carrierHz", range: RingModParams.carrierRange,
                                defaultValue: 440, unit: "Hz", curve: .logarithmic,
                                modulatable: .yes,
                                note: "THE knob. A ring modulator multiplies your sound by a "
                                    + "tone at this frequency, and the result contains NEITHER "
                                    + "of them: every partial at f in your input becomes a PAIR "
                                    + "of new tones at |f - carrier| and f + carrier. That is "
                                    + "why it sounds metallic and bell-like instead of filtered "
                                    + "- a harmonic series in comes out inharmonic. THREE "
                                    + "REGIONS worth knowing: below about 20 Hz you hear a "
                                    + "TREMOLO rather than a new tone - at mix 0.5 (the default) "
                                    + "or lower it pulses at the carrier rate, so 2 Hz is two "
                                    + "pulses a second, while ABOVE mix 0.5 the carrier swings "
                                    + "the signal negative and you hear a harder DOUBLED pulse "
                                    + "(2 Hz at mix 1 is four a second); 50-300 Hz gives a growl or a "
                                    + "bell; above ~500 Hz it goes clangorous and sci-fi. The "
                                    + "curve is logarithmic, so equal knob travel is equal "
                                    + "musical travel across all 13 octaves. Phase is CONTINUOUS "
                                    + "across a change, so this is safe to automate or modulate "
                                    + "at audio rate - a carrier step is a frequency step, never "
                                    + "a click."),
                EffectParamSpec(name: "mix", range: RingModParams.mixRange,
                                defaultValue: 0.5, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "Dry/wet. 0 is a BIT-EXACT bypass - the audio is not "
                                    + "touched at all, though the carrier keeps running "
                                    + "underneath so raising the mix later is phase-coherent "
                                    + "rather than a jump. 1 is the raw ring-modulated signal, "
                                    + "which loses the original pitch entirely and is the "
                                    + "robot-voice / Dalek setting. The DEFAULT 0.5 keeps the "
                                    + "source recognisable with the metallic layer over it, and "
                                    + "is where most musical uses live. Between 0 and 1 you are "
                                    + "hearing the dry sound and its sidebands together, which "
                                    + "is what makes it read as a timbre rather than as a "
                                    + "different note."),
                EffectParamSpec(name: "waveform", range: RingModParams.waveformRange,
                                defaultValue: 0, unit: "linear", curve: .linear,
                                modulatable: .refused,
                                note: "Carrier shape, as a whole number: 0 sine (the default), "
                                    + "1 triangle, 2 square, 3 saw. Anything in between rounds "
                                    + "to the nearer. A SINE carrier has one frequency, so each "
                                    + "input partial produces exactly two sidebands - the "
                                    + "cleanest, most bell-like result and the one to try "
                                    + "first. The other three are harmonically rich, so each "
                                    + "input partial gets a sideband PAIR around every carrier "
                                    + "harmonic: triangle is hollow and soft, square is buzzy "
                                    + "and loud (about 3 dB hotter than sine, because its energy "
                                    + "sits at full amplitude the whole cycle), saw is the "
                                    + "densest and most chaotic. All three are generated "
                                    + "BAND-LIMITED (worst audible-band alias MEASURED at "
                                    + "about -36 dB for square and saw, -57 for triangle, "
                                    + "against -21 and -42 for the naive shapes), so they add "
                                    + "no audible aliasing of their own even at a 5000 Hz "
                                    + "carrier. Discrete, so it is a shape "
                                    + "switch rather than a knob: not modulatable, and changing "
                                    + "it mid-note steps the carrier rather than gliding."),
                EffectParamSpec(name: "inputHighCutHz", range: RingModParams.inputHighCutRange,
                                defaultValue: 20_000, unit: "Hz", curve: .logarithmic,
                                modulatable: .yes,
                                note: "A low-pass on the input BEFORE the multiply, and the one "
                                    + "control you have over fold-back. HERE IS THE THING TO "
                                    + "KNOW: the upper sideband f + carrier often lands above "
                                    + "what the sample rate can represent, and when it does it "
                                    + "FOLDS BACK DOWN into the audible band as an extra "
                                    + "inharmonic tone. High carrier settings on bright material "
                                    + "therefore produce clangorous fold-back tones - that IS "
                                    + "the ring-mod sound, it is what classic hardware does, and "
                                    + "it is deliberately not filtered away. If you want a "
                                    + "cleaner, bell-like result instead, pull this down to "
                                    + "around 4000: a partial you removed cannot produce a "
                                    + "sideband that folds. The default 20000 is effectively "
                                    + "off (a 12 dB/oct corner at the top of hearing). It is a "
                                    + "PRE-filter - it sits between your signal and the "
                                    + "multiply, NOT in front of the whole effect - so lowering "
                                    + "it tames the metallic layer without dulling your "
                                    + "original sound. At mix 1 there is no original sound "
                                    + "left, so there the distinction does not arise."),
                EffectParamSpec(name: "stereoSpreadDeg", range: RingModParams.stereoSpreadRange,
                                defaultValue: 0, unit: "deg", curve: .linear,
                                modulatable: .yes,
                                note: "How far the RIGHT channel's carrier is rotated in phase "
                                    + "from the left one, in degrees. 0 (the default) means both "
                                    + "channels get an identical carrier, so a mono source stays "
                                    + "mono and the effect is safe on anything. Raise it and the "
                                    + "two channels' sidebands stop lining up, which widens the "
                                    + "result - 90 is a pleasant shimmer, 180 puts the carriers "
                                    + "in ANTIPHASE, which is the widest setting and also the "
                                    + "one that cancels most if the mix is later summed to mono. "
                                    + "Check a mono fold-down before committing to a large "
                                    + "value."),
            ]
        // m39-j — ORDER IS FROZEN (design §6.3.1). Position IS the automation
        // slot: 0 rateHz, 1 depthMs, 2 delayMs, 3 feedback, 4 mix,
        // 5 stereoPhaseDeg. APPEND ONLY, forever.
        case .flanger:
            return [
                EffectParamSpec(name: "rateHz", range: FlangerParams.rateRange,
                                defaultValue: 0.3, unit: "Hz", curve: .logarithmic,
                                modulatable: .yes,
                                note: "How fast the sweep moves, in cycles per second. This is "
                                    + "the speed of the whoosh, not its size. 0.02 is one slow "
                                    + "pass every 50 seconds - a drift you notice only across a "
                                    + "whole section; 0.3 (the default) is a comfortable jet-plane "
                                    + "sweep; 2-4 is a nervous wobble; 10 turns the sweep itself "
                                    + "into a buzzing texture. The curve is logarithmic, so equal "
                                    + "knob travel is equal musical travel across all 9 octaves - "
                                    + "on a linear control everything under 1 Hz, which is most "
                                    + "of the useful range, would be crammed into the first tenth "
                                    + "of the knob. Safe to automate or modulate: the sweep "
                                    + "position is continuous across a rate change, so speeding "
                                    + "up never jumps the comb."),
                EffectParamSpec(name: "depthMs", range: FlangerParams.depthRange,
                                defaultValue: 3, unit: "ms", curve: .logarithmic,
                                modulatable: .yes,
                                note: "How FAR the sweep travels, in milliseconds, measured "
                                    + "UPWARD from `delayMs`. The delay covers delayMs to delayMs "
                                    + "+ depthMs and never goes below the floor - that is "
                                    + "deliberate and it is what keeps the effect from breaking "
                                    + "when depth is larger than the floor. Small values (0.1-1) "
                                    + "give a tight metallic shimmer that barely moves; 3 (the "
                                    + "default) is the classic sweep; 10 is a dramatic full-range "
                                    + "dive that drags the comb down into the low mids at the "
                                    + "bottom of every cycle. Think of `delayMs` as WHERE the "
                                    + "effect sits and this as HOW FAR it swings from there."),
                EffectParamSpec(name: "delayMs", range: FlangerParams.delayRange,
                                defaultValue: 1.0, unit: "ms", curve: .logarithmic,
                                modulatable: .yes,
                                note: "The bottom of the sweep, in milliseconds - a hardware "
                                    + "flanger's 'manual' knob. Park the LFO (set rateHz to its "
                                    + "0.02 minimum) and this alone chooses where the comb sits. "
                                    + "The first notch lands at 1 / (2 * delay): at the 1.0 ms "
                                    + "default that is 500 Hz, with more notches at 1500, 2500 Hz "
                                    + "and so on; at 10 ms the first notch is down at 50 Hz and "
                                    + "the comb is so dense it reads as a metallic resonance "
                                    + "rather than a sweep. SMALL IS BRIGHT: 0.1 ms puts the "
                                    + "first notch at 5000 Hz, up in the air, which is the thin "
                                    + "jet-whistle end. This also guarantees the delay tap never "
                                    + "reaches the write head, which is why it cannot be set to "
                                    + "0 - through-zero flanging is a different effect and would "
                                    + "need a second dry path to cross."),
                EffectParamSpec(name: "feedback", range: FlangerParams.feedbackRange,
                                defaultValue: 0.5, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "How much of the delayed signal is fed back in, and the "
                                    + "single biggest change to the character. 0 is a plain comb "
                                    + "- gentle, hollow, no ringing. Turn it POSITIVE and the "
                                    + "peaks between the notches sharpen into resonances: 0.5 "
                                    + "(the default) is a singing sweep, 0.95 is on the edge of "
                                    + "self-oscillation and screams. Turn it NEGATIVE and the "
                                    + "response inverts - the peaks and notches swap places and "
                                    + "the sound goes hollow and metallic in a completely "
                                    + "different way, which is half the reason this control "
                                    + "crosses zero at all. LEVEL WARNING, because it is real and "
                                    + "not a mixing choice: moving this control CHANGES THE "
                                    + "LOUDNESS, in either direction, and how much depends on the "
                                    + "material. Match levels by ear, or put a limiter after this "
                                    + "insert, before deciding which side you prefer. The exact "
                                    + "arithmetic, if you want it, holds ON A STEADY TONE: the "
                                    + "whole unit's gain is (1 - mix) + mix / (1 - feedback), so "
                                    + "at mix 0.5 feedback 0.5 gives 1.5x (+3.5 dB) against "
                                    + "feedback 0's 1.0x, feedback 0.9 gives 5.5x (+14.8 dB), and "
                                    + "feedback -0.5 gives 0.83x (-1.6 dB). ⚠️ DO NOT read that "
                                    + "closed form as a whole-programme loudness prediction - it "
                                    + "is the gain at DC, where a negative feedback always "
                                    + "subtracts. On broadband material the rest of the comb is "
                                    + "what you hear, and the sign can come out the other way: "
                                    + "measured on a saw pad (EBU R128 integrated), feedback -0.5 "
                                    + "landed 1.0 LU LOUDER than feedback 0, not quieter. Both "
                                    + "numbers are right and they are about different things. "
                                    + "The curve is `linear` because the range "
                                    + "crosses 0 and a logarithmic taper cannot."),
                EffectParamSpec(name: "mix", range: FlangerParams.mixRange,
                                defaultValue: 0.5, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "Dry/wet. 0 is a BIT-EXACT bypass - the audio is not "
                                    + "touched at all, though the delay line and the sweep keep "
                                    + "running underneath so raising the mix later picks up "
                                    + "mid-sweep rather than jumping. 0.5 (the default) is where "
                                    + "a flanger belongs and is not an arbitrary middle: the "
                                    + "notches are CANCELLATION between the dry signal and its "
                                    + "delayed copy, so they are deepest when the two are equal. "
                                    + "Move away from 0.5 in either direction and the notches get "
                                    + "shallower, so the effect gets subtler rather than "
                                    + "differently coloured. 1 is the delayed signal alone, with "
                                    + "no dry copy left to cancel against: at feedback 0 that is "
                                    + "just a short wobbling delay with no comb at all, and at "
                                    + "higher feedback it keeps the resonant peaks the "
                                    + "recirculation builds but loses the notches."),
                EffectParamSpec(name: "stereoPhaseDeg", range: FlangerParams.stereoPhaseRange,
                                defaultValue: 90, unit: "deg", curve: .linear,
                                modulatable: .yes,
                                note: "How far the RIGHT channel's sweep is rotated from the "
                                    + "left one, in degrees, which is what makes the effect move "
                                    + "ACROSS the stereo field instead of straight up and down. "
                                    + "0 means both channels sweep together, so a mono source "
                                    + "stays perfectly mono - use it when mono compatibility "
                                    + "matters more than width. 90 (the default) is a quarter "
                                    + "cycle apart and is the classic wide sweep. 180 puts the "
                                    + "two channels in opposition, the widest setting, which is "
                                    + "also the one that cancels most if the mix is later summed "
                                    + "to mono. Check a mono fold-down before committing to a "
                                    + "large value. On a mono track this does nothing at all."),
            ]
        // m39-l — ORDER IS FROZEN (design §6.2.2). Position IS the automation
        // slot: 0 mix, 1 decaySeconds, 2 sizeMeters, 3 preDelayMs, 4 width,
        // 5 diffusion, 6 earlyLateBalance, 7 lowDecayMultiplier,
        // 8 highDecayMultiplier, 9 lowCrossoverHz, 10 highCrossoverHz,
        // 11 modRateHz, 12 modDepthMs, 13 freeze. APPEND ONLY, forever.
        // ⛔ NO `topology` SLOT IS RESERVED (D4): appending is always safe, and
        // a reserved-but-inert param is a lie told to every agent that reads
        // this table, bought to secure an ordering that was never at risk.
        case .hallReverb:
            return [
                EffectParamSpec(name: "mix", range: HallReverbParams.mixRange,
                                defaultValue: 0.3, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "How much reverb you hear against the dry sound. 0 is a "
                                    + "BIT-EXACT bypass - the audio is not touched at all, "
                                    + "though the tank keeps running underneath so raising the "
                                    + "mix later brings in a tail that is already going rather "
                                    + "than one that starts from nothing. 0.3 (the default) is "
                                    + "a normal 'put it in a room' amount. Above about 0.6 the "
                                    + "dry sound starts to disappear behind the tail, which is "
                                    + "a deliberate special-effect place to be. A COMMON BETTER "
                                    + "PATTERN: leave this at 1.0 and put the reverb on its own "
                                    + "bus, then use track sends to decide how much of each "
                                    + "track goes into the same space - that is what makes "
                                    + "several instruments sound like they are in one room "
                                    + "instead of several."),
                EffectParamSpec(name: "decaySeconds", range: HallReverbParams.decayRange,
                                defaultValue: 1.8, unit: "s", curve: .logarithmic,
                                modulatable: .yes,
                                note: "HOW LONG THE TAIL RINGS - a real RT60, the time the "
                                    + "reverb takes to fall 60 dB (to effective silence) at "
                                    + "1 kHz. 0.3 is a small tight room, 1.8 (the default) is a "
                                    + "good general-purpose hall, 4-8 is a cathedral, and 20 is "
                                    + "an unreal cavern you would use as an effect. THIS IS "
                                    + "TIME, NOT SIZE: it does not change where the walls are, "
                                    + "only how long it takes the energy to die. Use "
                                    + "`sizeMeters` for the room's dimensions. The curve is "
                                    + "logarithmic across its 7.6 octaves, so equal knob travel "
                                    + "is equal musical travel; a linear control would bury "
                                    + "everything under 4 seconds in the last fifth of the "
                                    + "knob. Safe to automate: the gains move smoothly and the "
                                    + "existing tail is not disturbed."),
                EffectParamSpec(name: "sizeMeters", range: HallReverbParams.sizeRange,
                                defaultValue: 12, unit: "m", curve: .logarithmic,
                                modulatable: .warned,
                                note: "HOW BIG THE ROOM IS, in metres - the parameter the old "
                                    + "`reverb` kind does not have. It scales the delay-line "
                                    + "lengths, so it changes how long sound takes to cross the "
                                    + "space and therefore HOW DENSE the echoes are: 1-3 m is a "
                                    + "tiled bathroom (fast, grainy, almost a flutter), 12 (the "
                                    + "default) is a decent hall, 30-60 m is a cathedral or a "
                                    + "canyon with audibly separated early echoes. Hold "
                                    + "`decaySeconds` still and move this and you hear the "
                                    + "SHAPE change while the length stays - that is the whole "
                                    + "point of the control. ⚠️ MOVING IT WHILE A TAIL IS "
                                    + "SOUNDING GIVES A DOPPLER GLIDE: the read offsets slide "
                                    + "under audio that is already recirculating, so the "
                                    + "existing tail pitch-shifts like a varispeed tape. It is "
                                    + "SMOOTH, not a click - this is not the delay's stepping "
                                    + "defect - and a slow size ramp under a pad is a real "
                                    + "production gesture. But an agent automating this expects "
                                    + "a room change and also gets a pitch glide, so: for a "
                                    + "clean size change, change it between sounds."),
                EffectParamSpec(name: "preDelayMs", range: HallReverbParams.preDelayRange,
                                defaultValue: 20, unit: "ms", curve: .linear,
                                modulatable: .yes,
                                note: "The gap between the dry sound and the first hint of the "
                                    + "room, in milliseconds. This is the single most useful "
                                    + "control for keeping a vocal or a snare UPFRONT while "
                                    + "still putting it in a big space: the ear locates a sound "
                                    + "by its first arrival, so a 20-40 ms gap lets the dry "
                                    + "sound land dry and the room arrive afterwards. 0 glues "
                                    + "the reverb onto the source and makes it sound distant; "
                                    + "20 (the default) is a comfortable separation; 80-150 is "
                                    + "a deliberate slapback-into-hall. ⭐ Unlike the older "
                                    + "`reverb` kind's pre-delay, this one is read through a "
                                    + "fractionally interpolated line, so it MOVES SMOOTHLY - "
                                    + "automate or modulate it without the stepping the integer "
                                    + "version has. The curve is linear because the range "
                                    + "starts at 0 and a logarithmic taper cannot express that."),
                EffectParamSpec(name: "width", range: HallReverbParams.widthRange,
                                defaultValue: 1.0, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "How wide the REVERB is, left to right. This is mid/side "
                                    + "on the wet signal only, so your dry sound never moves. 0 "
                                    + "makes the tail mono - dead centre, which is the safe "
                                    + "choice when the mix has to survive a phone speaker or a "
                                    + "club system. 1.0 (the default) is the tank's natural "
                                    + "stereo spread, which comes from the eight lines being "
                                    + "fed to the two outputs in different combinations rather "
                                    + "than from any delay trickery. 1.2 is the ceiling and it "
                                    + "is deliberately modest: pushing side energy further is "
                                    + "the classic way to build a mix that collapses when "
                                    + "summed to mono."),
                EffectParamSpec(name: "diffusion", range: HallReverbParams.diffusionRange,
                                defaultValue: 0.7, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "How SMEARED the input is before it enters the room - "
                                    + "four allpass filters that scatter a sharp sound into a "
                                    + "wash without changing its tone. At 0 a drum hit enters "
                                    + "the tank as a drum hit and you hear individual early "
                                    + "echoes, which is grainy and can flutter on percussion; "
                                    + "at 0.7 (the default) it enters as a short burst of "
                                    + "scatter and the room fills smoothly; at 1 it is maximum "
                                    + "smear, which flatters drums and can soften the attack of "
                                    + "anything with a clear transient. RULE OF THUMB: raise it "
                                    + "for percussive sources, lower it for sustained ones "
                                    + "where you want the room's own echo pattern to show."),
                EffectParamSpec(name: "earlyLateBalance", range: HallReverbParams.earlyLateRange,
                                defaultValue: 0, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "WHERE IN THE ROOM YOU ARE STANDING. Negative moves you "
                                    + "toward the source, so you hear mostly the early, "
                                    + "scattered first arrivals and very little tail - close, "
                                    + "present, a sense of a surface nearby rather than a big "
                                    + "space. Positive moves you back into the hall, so you "
                                    + "hear mostly the long diffuse tail and little of the "
                                    + "early detail - far away, washed, atmospheric. 0 (the "
                                    + "default) is an even blend. ⚠️ At exactly -1 there is no "
                                    + "tail at all, only the scattered early part, and at "
                                    + "exactly +1 there are no early reflections; both extremes "
                                    + "are legitimate sounds but neither is a 'reverb' in the "
                                    + "usual sense. The curve is linear because the range "
                                    + "crosses 0 and a logarithmic taper cannot."),
                EffectParamSpec(name: "lowDecayMultiplier",
                                range: HallReverbParams.lowDecayMultiplierRange,
                                defaultValue: 1.0, unit: "x", curve: .logarithmic,
                                modulatable: .yes,
                                note: "How much LONGER OR SHORTER the bass rings than the rest, "
                                    + "as a multiple of `decaySeconds`, below `lowCrossoverHz`. "
                                    + "1.0 (the default) is neutral - the low end decays at the "
                                    + "same rate as everything else. Above 1 the bass hangs on: "
                                    + "2 gives it twice the decay time, which is big, warm and "
                                    + "cinematic, and is also the quickest way to make a mix "
                                    + "muddy. Below 1 the bass leaves first: 0.25 gives it a "
                                    + "quarter of the time, which keeps a dense arrangement "
                                    + "clean and is the standard fix when a reverb is eating "
                                    + "the low mids. The curve is logarithmic because a "
                                    + "multiplier's neutral is 1 and 0.25/4 are symmetric in "
                                    + "OCTAVES, not in units - on a linear control neutral "
                                    + "would sit at a fifth of the travel."),
                EffectParamSpec(name: "highDecayMultiplier",
                                range: HallReverbParams.highDecayMultiplierRange,
                                defaultValue: 0.5, unit: "x", curve: .logarithmic,
                                modulatable: .yes,
                                note: "How much SHORTER the treble rings than the rest, above "
                                    + "`highCrossoverHz`. THE DEFAULT IS 0.5, NOT 1, AND THAT "
                                    + "IS THE MOST IMPORTANT NUMBER IN THIS EFFECT: real air "
                                    + "absorbs high frequencies as sound travels, so in every "
                                    + "real room the top end dies before the bottom does. A "
                                    + "reverb with no high-frequency damping is exactly what "
                                    + "'sounds like a metal tank' means. 1 is that tank - no "
                                    + "damping at all, bright and artificial, occasionally what "
                                    + "you want for a shimmer. 0.5 is a natural hall. 0.1 is a "
                                    + "heavily curtained, dark, dead room. Cannot go above 1, "
                                    + "because a treble that rings LONGER than the body does "
                                    + "not happen in air and is not a sound anyone asks for."),
                EffectParamSpec(name: "lowCrossoverHz", range: HallReverbParams.lowCrossoverRange,
                                defaultValue: 200, unit: "Hz", curve: .logarithmic,
                                modulatable: .yes,
                                note: "Where 'the bass' begins, for the purposes of "
                                    + "`lowDecayMultiplier`. 200 Hz (the default) sits just "
                                    + "under most vocals and guitars and right around the body "
                                    + "of a kick and a bass guitar, so trimming the low decay "
                                    + "from there cleans up the mud without thinning the "
                                    + "instruments. Move it up toward 500-1000 to treat the "
                                    + "whole low mid-range as bass, which is a heavier, more "
                                    + "obvious effect; move it down toward 50-100 to touch only "
                                    + "the true sub. The shelf is gentle by design (first "
                                    + "order), so this is a centre of gravity rather than a "
                                    + "hard edge."),
                EffectParamSpec(name: "highCrossoverHz", range: HallReverbParams.highCrossoverRange,
                                defaultValue: 6_000, unit: "Hz", curve: .logarithmic,
                                modulatable: .yes,
                                note: "Where 'the treble' begins, for the purposes of "
                                    + "`highDecayMultiplier`. 6000 Hz (the default) is up in "
                                    + "the air and sibilance, so the damping shortens the "
                                    + "sparkle without dulling the body - the natural-sounding "
                                    + "setting. Pull it down to 2000-3000 and the damping "
                                    + "starts eating presence, which makes the room distinctly "
                                    + "dark and distant (and is a good trick for pushing a "
                                    + "sound behind something else). Push it to 12000+ and only "
                                    + "the very top is damped, which is close to no damping at "
                                    + "all. Like the low crossover, this is a gentle "
                                    + "first-order shelf, so it is a centre of gravity."),
                EffectParamSpec(name: "modRateHz", range: HallReverbParams.modRateRange,
                                defaultValue: 0.3, unit: "Hz", curve: .logarithmic,
                                modulatable: .yes,
                                note: "How fast the eight delay lines drift in length - the "
                                    + "ANTI-METALLIC control, together with `modDepthMs`. A "
                                    + "reverb built from fixed-length lines rings at a fixed "
                                    + "set of frequencies, and the ear hears that as a "
                                    + "metallic, almost pitched tail. Sliding each line's "
                                    + "length slowly smears those resonances so they never sit "
                                    + "still long enough to be heard as tones. 0.3 Hz (the "
                                    + "default) is one slow drift every three seconds, which "
                                    + "reads as 'air' rather than as movement. Under 0.1 the "
                                    + "drift is barely alive; above 2 it starts to be audible "
                                    + "as a wobble in its own right. All eight lines share this "
                                    + "rate but each starts at a DIFFERENT point in its cycle, "
                                    + "which is what keeps the drift from reading as one "
                                    + "coherent vibrato."),
                EffectParamSpec(name: "modDepthMs", range: HallReverbParams.modDepthRange,
                                defaultValue: 0.15, unit: "ms", curve: .linear,
                                modulatable: .yes,
                                note: "How FAR the lines drift, in milliseconds - the other "
                                    + "half of the anti-metallic control. 0 turns the drift off "
                                    + "entirely and you can hear what it was doing: the tail "
                                    + "becomes noticeably more ringing and more pitched, "
                                    + "especially on long decays. 0.15 (the default) is enough "
                                    + "to break up the resonances and is not audible as "
                                    + "movement. Past about 1 ms it stops sounding like air and "
                                    + "starts sounding like CHORUS - the tail acquires an "
                                    + "obvious pitch wobble. The 5 ms ceiling is set so you can "
                                    + "reach that sound deliberately if you want it, while the "
                                    + "default cannot stumble into it. The curve is linear "
                                    + "because the range starts at 0."),
                EffectParamSpec(name: "freeze", range: HallReverbParams.freezeRange,
                                defaultValue: 0, unit: "linear", curve: .linear,
                                modulatable: .refused,
                                note: "INFINITE HOLD. Anything from 0.5 up turns it on: the "
                                    + "input is muted and the tank's absorption is bypassed, so "
                                    + "whatever is in the room at that instant hangs there "
                                    + "indefinitely as a pad. Turn it off and the held sound "
                                    + "decays normally and the input returns. Both edges are "
                                    + "crossfaded over about 10 ms, so it is a swell and not a "
                                    + "click. A very slow darkening remains even while frozen, "
                                    + "because the fractional taps are a mild low-pass - "
                                    + "'infinite' means minutes, not literally forever. This is "
                                    + "a SWITCH on a numeric surface, so it is not modulatable: "
                                    + "drive it from an automation lane with `hold` "
                                    + "interpolation, never a ramp, or you will cross 0.5 on "
                                    + "the way past and trigger it by accident."),
            ]
        // m39-n — ORDER IS FROZEN. Position IS the automation slot:
        // 0 timeMs, 1 feedback, 2 mix, 3 wowDepthMs, 4 wowRateHz,
        // 5 flutterDepthMs, 6 saturationDrive, 7 highCutHz. APPEND ONLY,
        // forever. ⛔ NO `sync` / `division` SLOT IS RESERVED: tempo sync is
        // gated on m39-c + m39-d (design §8.2), appending is always safe, and
        // a reserved-but-inert param would be a lie in `fx.describe` bought to
        // secure an ordering that was never at risk (rule 6.0.1's corollary).
        // ⛔ NO `lowCutHz` EITHER, for the same reason — it is the obvious
        // first append if dub-style filtered feedback is ever asked for.
        case .tapeDelay:
            return [
                EffectParamSpec(name: "timeMs", range: TapeDelayParams.timeRange,
                                defaultValue: 350, unit: "ms", curve: .logarithmic,
                                modulatable: .warned,
                                note: "How long the echo takes to come back, in milliseconds - "
                                    + "the head gap on a real machine. 20 is the shortest this "
                                    + "kind goes (below that, use `delay` or `flanger`); 350 (the "
                                    + "default) is a comfortable quarter-note-ish slap; 4000 is a "
                                    + "four-second dub throw. The curve is logarithmic, so equal "
                                    + "knob travel is equal musical travel across the whole 20 ms "
                                    + "to 4 s span. ⚠️ MOVING IT WHILE REPEATS ARE SOUNDING GIVES "
                                    + "A PITCH GLIDE: the read position slides under audio that "
                                    + "is already circulating, so the repeats bend like a "
                                    + "varispeed tape. It is SMOOTH, not a click - this is NOT "
                                    + "the `delay` kind's stepping defect, which comes from that "
                                    + "kind reading at whole-sample offsets only - and a hand "
                                    + "ride on this control is a real dub gesture. But an agent "
                                    + "automating it expects a time change and also gets the "
                                    + "glide, which is why the verdict here is `warned` rather "
                                    + "than `yes`: for a clean time change, change it between "
                                    + "phrases, or drop `mix` to 0 first. ⛔ There is NO tempo "
                                    + "sync on this kind in v1 - `delay` is the kind that has "
                                    + "`sync` and `division`."),
                EffectParamSpec(name: "feedback", range: TapeDelayParams.feedbackRange,
                                defaultValue: 0.4, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "How much of each repeat is recorded back onto the tape. 0 "
                                    + "is a single slap; 0.4 (the default) is a handful of "
                                    + "audible repeats; 0.9 is a long trail; 0.999 - the ceiling "
                                    + "- loses under 0.01 dB per pass, so the echo holds almost "
                                    + "indefinitely instead of fading. The ceiling stops just "
                                    + "short of 1.0 on a measurement, not on taste: at exactly "
                                    + "1.0 this structure grows without bound. What keeps a high "
                                    + "setting musical rather than harsh is `saturationDrive` and "
                                    + "`highCutHz` - with drive up, each pass is gently "
                                    + "compressed, so a runaway bends into a howl instead of a "
                                    + "digital clip; with the high cut down, each pass is duller "
                                    + "than the last and the trail dissolves rather than "
                                    + "piling up."),
                EffectParamSpec(name: "mix", range: TapeDelayParams.mixRange,
                                defaultValue: 0.3, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "Dry/wet. 0 is a BIT-EXACT bypass - the audio is not "
                                    + "touched at all, though the tape keeps running underneath, "
                                    + "so raising the mix later drops you into repeats that are "
                                    + "already there rather than starting from silence. 0.3 (the "
                                    + "default) sits the echo behind the source; 1 is the "
                                    + "repeats alone with no dry signal, which is what you want "
                                    + "on a send bus."),
                EffectParamSpec(name: "wowDepthMs", range: TapeDelayParams.wowDepthRange,
                                defaultValue: 2.5, unit: "ms", curve: .linear,
                                modulatable: .yes,
                                note: "WOW - the slow drift of a motor that is not quite steady, "
                                    + "and the single control that makes this kind sound like "
                                    + "tape instead of like a digital delay. The number is how "
                                    + "far the tape drifts, peak to peak, in milliseconds; what "
                                    + "you HEAR is the pitch of the repeats sagging and "
                                    + "recovering. The exact amount, because it is worth knowing "
                                    + "rather than guessing: peak deviation in cents is "
                                    + "1200*log2(1 + pi*rateHz*depthMs/1000), so at the 2.5 ms / "
                                    + "0.8 Hz default it is 10.8 cents - a tenth of a semitone, "
                                    + "obvious on a sustained pad and inaudible on a drum hit - "
                                    + "and at the 8 ms / 3 Hz maximum it is 125.8 cents, over a "
                                    + "semitone, which is a broken machine and is exactly what "
                                    + "the top of the range is for. It does NOT depend on the "
                                    + "delay time: a 20 ms slapback and a 4 s throw wow by the "
                                    + "same musical interval. 0 is a perfectly steady transport. "
                                    + "The curve is linear because the range reaches 0."),
                EffectParamSpec(name: "wowRateHz", range: TapeDelayParams.wowRateRange,
                                defaultValue: 0.8, unit: "Hz", curve: .logarithmic,
                                modulatable: .yes,
                                note: "How fast the motor drifts, in cycles per second. 0.1 is "
                                    + "one slow sag every ten seconds - a drift you notice only "
                                    + "across a whole phrase; 0.8 (the default) is the classic "
                                    + "seasick tape wobble; 3 is fast enough to start reading as "
                                    + "a vibrato rather than as a fault. Raising this raises the "
                                    + "pitch deviation in exact proportion (see `wowDepthMs`), so "
                                    + "the two controls multiply: doubling either doubles the "
                                    + "wobble. The transport phase is never reset by a parameter "
                                    + "change, so changing the rate speeds the drift up without "
                                    + "jumping it."),
                EffectParamSpec(name: "flutterDepthMs", range: TapeDelayParams.flutterDepthRange,
                                defaultValue: 0.25, unit: "ms", curve: .linear,
                                modulatable: .yes,
                                note: "FLUTTER - the fast, irregular jitter of a capstan, as "
                                    + "opposed to `wowDepthMs`'s slow sag. Peak-to-peak "
                                    + "milliseconds again, but the excursion is split between two "
                                    + "fixed rates, 7.3 Hz and 11.7 Hz, that never line up the "
                                    + "same way twice - a single fast wobble would read as a "
                                    + "deliberate vibrato, which is the opposite of 'the "
                                    + "transport is not quite steady'. Peak deviation is 12.9 "
                                    + "cents at the 0.25 ms default and 50.9 cents at the 1 ms "
                                    + "maximum. It adds GRAIN and a slight shimmer to the "
                                    + "repeats rather than an audible pitch bend; if you want the "
                                    + "obvious seasick sound, that is `wowDepthMs`. 0 is a "
                                    + "perfectly steady capstan. The curve is linear because the "
                                    + "range reaches 0."),
                EffectParamSpec(name: "saturationDrive", range: TapeDelayParams.saturationRange,
                                defaultValue: 0.3, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "How hard the repeats are pushed into the tape. 0 is "
                                    + "EXACTLY linear - not 'gentle', actually untouched - so it "
                                    + "is the setting to use when you want a clean repeat with "
                                    + "only the wow. 0.3 (the default) rounds peaks by about a "
                                    + "decibel per pass and is felt more than heard on a first "
                                    + "repeat; 1 drives hard enough that anything above about "
                                    + "-15 dBFS is visibly squashed and the trail thickens into "
                                    + "a growl. The shaper has UNITY gain on quiet signals and "
                                    + "compresses loud ones, which is why turning it up does not "
                                    + "make the echo louder or push the feedback loop into "
                                    + "runaway - it does the opposite, and that is what lets a "
                                    + "0.99 feedback howl musically instead of clipping. ⚠️ NO "
                                    + "OVERSAMPLING here: harmonics generated above half the "
                                    + "sample rate fold back as inharmonic content, most audible "
                                    + "on bright sources at high drive. The separate `saturator` "
                                    + "kind DOES have an `oversampling` knob you can raise to "
                                    + "clean that up; this one does not, because its shaper sits "
                                    + "inside the echo's feedback loop where the extra filtering "
                                    + "would lengthen the echo time itself."),
                EffectParamSpec(name: "highCutHz", range: TapeDelayParams.highCutRange,
                                defaultValue: 6_000, unit: "Hz", curve: .logarithmic,
                                modulatable: .yes,
                                note: "A one-pole low-pass in the RECORD path, which is the one "
                                    + "place this differs from the `delay` kind's filter: there "
                                    + "the first echo is unfiltered and only later repeats "
                                    + "darken, here EVERY repeat including the first has been "
                                    + "through the tape, because on a real machine it had. Each "
                                    + "successive pass goes through it again, so the trail gets "
                                    + "progressively duller and dissolves instead of piling up. "
                                    + "6000 (the default) is a well-worn machine; 500 is a "
                                    + "telephone in the next room and turns long feedback into a "
                                    + "warm rumble; 20000 is effectively off and gives a bright, "
                                    + "modern repeat that still wows. ⚠️ AT HIGH FEEDBACK THIS, "
                                    + "NOT `feedback`, IS WHAT BOUNDS THE TAIL: with feedback "
                                    + "near the ceiling the loop barely loses energy, and the "
                                    + "high cut is the only thing taking something away on every "
                                    + "pass."),
            ]
        // m23-dj — ORDER IS FROZEN. Position IS the automation slot:
        // 0 width, 1 spread, 2 bassMonoHz, 3 bassMonoAmount. APPEND ONLY,
        // forever. ⛔ NO `mix` SLOT, and the reason is algebra rather than
        // taste: a dry/wet blend on a mid/side widener is a re-parameterisation
        // of `width` and `spread` (see `StereoWidthParams.isNeutral`), so it
        // would be a lie in `fx.describe`. ⛔ NO `decorrelationMs` EITHER — the
        // all-pass stage lengths are constants (the `tapeDelay` flutter-rate
        // precedent) and a "size" param is the obvious first append if anyone
        // asks for one; reserving a slot for it would buy an ordering that was
        // never at risk (rule 6.0.1's corollary).
        case .stereoWidth:
            return [
                EffectParamSpec(name: "width", range: StereoWidthParams.widthRange,
                                defaultValue: 1, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "How much of the stereo you ALREADY HAVE survives. 0 "
                                    + "removes it; 1 (the default) is exactly as recorded and "
                                    + "changes nothing; 2 doubles the difference between left "
                                    + "and right, which is as wide as this goes. ⛔ 0 ALONE IS "
                                    + "NOT A MONO-MAKER, and this is the one trap in this "
                                    + "effect: `spread` defaults to 0.3 and BUILDS A NEW side "
                                    + "channel AFTER `width` has scaled the old one, so width 0 "
                                    + "on a freshly added insert still comes out stereo - and on "
                                    + "a mono source it comes out WIDER than it went in. To fold "
                                    + "a track to dead centre set width 0 AND `spread` 0 "
                                    + "together; to centre only a wandering bass, leave `width` "
                                    + "alone and use `bassMonoAmount`. ⭐ THIS CONTROL IS FREE, "
                                    + "and that is unusual "
                                    + "for a widener: it is a plain gain on the left-minus-right "
                                    + "difference, so it adds no filtering, no delay and no "
                                    + "colouration of any kind, and the mono fold-down is "
                                    + "arithmetically untouched at every setting. ⚠️ IT DOES "
                                    + "NOTHING AT ALL ON A MONO SOURCE - if left and right are "
                                    + "identical there is no difference to scale, and zero times "
                                    + "anything is still zero. To make a mono source stereo, that "
                                    + "is `spread`. The curve is linear because the range reaches "
                                    + "0."),
                EffectParamSpec(name: "spread", range: StereoWidthParams.spreadRange,
                                defaultValue: 0.3, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "TRUE STEREO FROM A MONO SOURCE - the control that makes "
                                    + "this more than a width knob. It builds a brand-new side "
                                    + "channel by running the centre of the signal through a "
                                    + "short chain of all-pass filters (four stages, 2.9 to 13.1 "
                                    + "ms) and adding it to one side while subtracting it from "
                                    + "the other. An all-pass changes WHEN each frequency "
                                    + "arrives without changing HOW LOUD it is, so the two sides "
                                    + "end up genuinely different rather than one being a delayed "
                                    + "copy of the other. 0 is off; 0.3 (the default) opens a "
                                    + "mono synth or vocal out to a comfortable width; 1 is the "
                                    + "maximum and is a deliberate effect rather than a subtle "
                                    + "one. ⚠️ THIS IS THE ONE CONTROL HERE THAT COSTS SOMETHING, "
                                    + "AND THE COST IS NOT HIDEABLE: each channel on its own gets "
                                    + "a gentle ripple across the spectrum, peaking at "
                                    + "20*log10(1 + spread) dB and dipping to 20*log10(1 - "
                                    + "spread) - +2.3 / -3.1 dB at the default, and a complete "
                                    + "null at 1.0. The peaks and dips land at DIFFERENT "
                                    + "frequencies in the two channels, which is exactly what "
                                    + "makes it sound wide, and they CANCEL EXACTLY in the mono "
                                    + "sum, so nothing is lost on a phone speaker. Every "
                                    + "`fx.add` and `fx.setParam` result echoes the two numbers "
                                    + "as `channelPeakDb` and `channelNotchDb`. You cannot have "
                                    + "both a flat mono sum and flat individual channels out of "
                                    + "a mono source - that is arithmetic, not a limitation of "
                                    + "this implementation - and this effect chooses the flat "
                                    + "mono sum every time. The curve is linear because the "
                                    + "range reaches 0."),
                EffectParamSpec(name: "bassMonoHz", range: StereoWidthParams.bassMonoHzRange,
                                defaultValue: 120, unit: "Hz", curve: .logarithmic,
                                modulatable: .yes,
                                note: "Where the bass stops being stereo. Everything below this "
                                    + "frequency has its left/right difference removed (by "
                                    + "`bassMonoAmount`), at 12 dB per octave. 120 (the default) "
                                    + "is what mastering practice actually does: low frequencies "
                                    + "carry most of the energy, a wandering or out-of-phase bass "
                                    + "is the single most common way a mix falls apart on a club "
                                    + "system or a vinyl cut, and human hearing cannot localise "
                                    + "much below 120 Hz anyway, so collapsing it costs you "
                                    + "nothing you could hear. 20 is effectively off; 500 pulls "
                                    + "the whole low-mid range to centre and starts to sound "
                                    + "narrow. ⚠️ THIS CONTROL DOES NOTHING WHEN "
                                    + "`bassMonoAmount` IS 0 - the frequency of a filter that is "
                                    + "fully bypassed is not a setting, and moving it will not "
                                    + "change one sample. The curve is logarithmic, so equal "
                                    + "knob travel is equal musical travel across the range."),
                EffectParamSpec(name: "bassMonoAmount",
                                range: StereoWidthParams.bassMonoAmountRange,
                                defaultValue: 1, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "How completely the bass is pulled to the centre. 1 (the "
                                    + "default) removes the stereo difference below `bassMonoHz` "
                                    + "entirely; 0 turns the whole bass-mono stage off and leaves "
                                    + "the low end exactly as it arrived; values between are a "
                                    + "partial collapse, for when a wide low end is deliberate "
                                    + "and you only want to tame it. The default is ON because "
                                    + "the setting that protects you is the one you should have "
                                    + "to turn OFF, not the one you have to discover. ⭐ THIS IS "
                                    + "ALSO ONE THIRD OF THE BYPASS: with `width` at 1, `spread` "
                                    + "at 0 and this at 0, the effect is a BIT-EXACT passthrough "
                                    + "- the audio is not touched at all, though the decorrelator "
                                    + "keeps running underneath, so raising `spread` later opens "
                                    + "into a settled image rather than swelling up from "
                                    + "nothing. The curve is linear because the range reaches 0."),
            ]
        // m39-o — ORDER IS FROZEN. Position IS the automation slot:
        // 0 rateHz, 1 centerHz, 2 depthOctaves, 3 stages, 4 feedback, 5 mix,
        // 6 stereoPhaseDeg. APPEND ONLY, forever. ⛔ NO `resonance` SLOT IS
        // RESERVED: `feedback` already is the resonance control on this
        // topology, and reserving a slot would buy an ordering that was never
        // at risk (rule 6.0.1's corollary).
        case .phaser:
            return [
                EffectParamSpec(name: "rateHz", range: PhaserParams.rateRange,
                                defaultValue: 0.5, unit: "Hz", curve: .logarithmic,
                                modulatable: .yes,
                                note: "How fast the sweep moves, in cycles per second. This is "
                                    + "the speed of the whoosh, not its size. 0.02 is one slow "
                                    + "pass every 50 seconds - a drift you notice only across a "
                                    + "whole section; 0.5 (the default) is a comfortable breathing "
                                    + "sweep; 2-4 is a nervous wobble; 10 turns the sweep itself "
                                    + "into a texture. The curve is logarithmic, so equal knob "
                                    + "travel is equal musical travel across all 9 octaves - on a "
                                    + "linear control everything under 1 Hz, which is most of the "
                                    + "useful range, would be crammed into the first tenth of the "
                                    + "knob. Safe to automate or modulate: the sweep position is "
                                    + "continuous across a rate change, so speeding up never "
                                    + "jumps the notches."),
                EffectParamSpec(name: "centerHz", range: PhaserParams.centerRange,
                                defaultValue: 300, unit: "Hz", curve: .logarithmic,
                                modulatable: .yes,
                                note: "The bottom of the sweep, in Hz - the 'manual' knob. Park "
                                    + "the LFO (set `depthOctaves` to 0) and this alone decides "
                                    + "where the notches sit. It is not itself a notch frequency: "
                                    + "the notches are spread around it by `stages`, at the "
                                    + "multiples listed under that control. At the 6-stage, 300 Hz "
                                    + "default the lowest notch is at about 80 Hz, with the others "
                                    + "at 300 and 1120 Hz. LOW IS THICK: 20-100 Hz puts the "
                                    + "whole pattern under the body of most sounds and the effect "
                                    + "becomes a slow tonal breathing; 1000 Hz is up in the "
                                    + "presence range and reads as a thin, whistling sweep. The "
                                    + "curve is logarithmic because that is how pitch is heard. "
                                    + "⭐ The `params` object in every fx.add and fx.setParam "
                                    + "RESULT reports `firstNotchHz` for the current setting, so "
                                    + "you never have to work this out by hand."),
                EffectParamSpec(name: "depthOctaves", range: PhaserParams.depthRange,
                                defaultValue: 3, unit: "oct", curve: .linear,
                                modulatable: .yes,
                                note: "How FAR the sweep travels, in octaves, measured UPWARD "
                                    + "from `centerHz`. The corner covers centerHz to centerHz "
                                    + "doubled that many times, and never goes below the floor - "
                                    + "that is deliberate, and it is what keeps a deep sweep from "
                                    + "diving out of the band where there is anything to cancel. "
                                    + "0 FREEZES THE SWEEP, which is a real setting and not a "
                                    + "degenerate one: a parked phaser is a fixed notch filter, "
                                    + "the sound of a wah pedal held still, and it is the setting "
                                    + "to use when you want the colour without the movement. 1 is "
                                    + "a subtle shimmer; 3 (the default) is the classic sweep; 4 "
                                    + "is a dramatic full-range climb. Think of `centerHz` as "
                                    + "WHERE the effect sits and this as HOW FAR it swings from "
                                    + "there. The curve is linear because the range reaches 0."),
                EffectParamSpec(name: "stages", range: PhaserParams.stagesRange,
                                defaultValue: 6, unit: "stages", curve: .linear,
                                modulatable: .refused,
                                note: "How many all-pass sections are cascaded, and therefore HOW "
                                    + "MANY NOTCHES the effect puts in the sound: every TWO "
                                    + "stages buy one notch, so 4 stages give 2 notches, 6 (the "
                                    + "default) give 3, 8 give 4 and 12 give 6. EVEN NUMBERS "
                                    + "ONLY - an odd count is SNAPPED to the nearer even one and "
                                    + "the snapped value is what is reported back, so what you "
                                    + "read is always what is in force. More stages is denser and "
                                    + "more dramatic, not louder. ⭐ THIS IS WHAT MAKES A PHASER "
                                    + "A PHASER AND NOT A FLANGER, and it is worth knowing: a "
                                    + "flanger puts DOZENS of notches in the sound, evenly "
                                    + "spaced at 1, 3, 5, 7 times a base frequency, which is why "
                                    + "it sounds metallic and jet-like. A phaser puts a HANDFUL "
                                    + "in, unevenly spaced and spreading apart as they climb - at "
                                    + "8 stages they sit at roughly 1, 3.4, 7.5 and 25 times the "
                                    + "lowest one. That is the soft vocal 'wow' this effect is "
                                    + "for. Discrete, so it cannot be MODULATED; automate it with "
                                    + "a `hold` lane if you want it to change, and expect a "
                                    + "character step rather than a glide - the all-pass state is "
                                    + "cleared when the count changes, because a stage that has "
                                    + "been out of circuit holds a stale value."),
                EffectParamSpec(name: "feedback", range: PhaserParams.feedbackRange,
                                defaultValue: 0.5, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "How much of the all-pass chain's output is fed back into "
                                    + "its input, and the single biggest change to the character. "
                                    + "0 is a plain phaser - soft, wide, no ringing. Turn it "
                                    + "POSITIVE and the peaks between the notches sharpen into "
                                    + "resonances: 0.5 (the default) is a singing sweep, 0.95 is "
                                    + "on the edge of self-oscillation. Turn it NEGATIVE and the "
                                    + "pattern inverts - what was a peak becomes a dip - which is "
                                    + "a hollower, more nasal version of the same gesture and is "
                                    + "why this control crosses zero at all. LEVEL WARNING, "
                                    + "because it is real and not a mixing choice: moving this "
                                    + "CHANGES THE LOUDNESS, in either direction, and how much "
                                    + "depends on the material. Match levels by ear, or put a "
                                    + "limiter after this insert, before deciding which side you "
                                    + "prefer. The exact arithmetic, if you want it, holds ON A "
                                    + "STEADY TONE: the whole unit's gain is (1 - mix) + mix / "
                                    + "(1 - feedback), so at mix 0.5 feedback 0.5 gives 1.5x "
                                    + "(+3.5 dB) against feedback 0's 1.0x, and feedback -0.5 "
                                    + "gives 0.83x (-1.6 dB). ⚠️ That closed form is the gain at "
                                    + "DC and is NOT a whole-programme loudness prediction; on "
                                    + "broadband material the notches are what you hear and the "
                                    + "sign can come out the other way. The curve is `linear` "
                                    + "because the range crosses 0 and a logarithmic taper "
                                    + "cannot."),
                EffectParamSpec(name: "mix", range: PhaserParams.mixRange,
                                defaultValue: 0.5, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "Dry/wet. 0 is a BIT-EXACT bypass - the audio is not "
                                    + "touched at all, though the all-pass chain and the sweep "
                                    + "keep running underneath so raising the mix later picks up "
                                    + "mid-sweep rather than jumping. 0.5 (the default) is where "
                                    + "a phaser belongs and is not an arbitrary middle: the "
                                    + "notches are CANCELLATION between the dry signal and its "
                                    + "phase-shifted copy, so they are deepest when the two are "
                                    + "equal. Move away from 0.5 in either direction and the "
                                    + "notches get shallower, so the effect gets subtler rather "
                                    + "than differently coloured. 1 is the phase-shifted signal "
                                    + "alone, with no dry copy left to cancel against: at "
                                    + "feedback 0 that is INAUDIBLE on most material, because an "
                                    + "all-pass chain changes no frequency's level at all - it "
                                    + "is the one setting of this effect that can sound like "
                                    + "nothing is happening, and that is not a bug."),
                EffectParamSpec(name: "stereoPhaseDeg", range: PhaserParams.stereoPhaseRange,
                                defaultValue: 90, unit: "deg", curve: .linear,
                                modulatable: .yes,
                                note: "How far the RIGHT channel's sweep is rotated from the "
                                    + "left one, in degrees, which is what makes the effect move "
                                    + "ACROSS the stereo field instead of straight up and down. "
                                    + "0 means both channels sweep together, so a mono source "
                                    + "stays perfectly mono - use it when mono compatibility "
                                    + "matters more than width. 90 (the default) is a quarter "
                                    + "cycle apart and is the classic wide sweep. 180 puts the "
                                    + "two channels in opposition, the widest setting, which is "
                                    + "also the one that cancels most if the mix is later summed "
                                    + "to mono. Check a mono fold-down before committing to a "
                                    + "large value. On a mono track this does nothing at all."),
            ]
        case .transientShaper:
            // ⛔⛔ ORDER IS FROZEN AND APPEND-ONLY FOREVER. The INDEX of a spec
            // in this array IS the automation slot number
            // (`storeAutomatedParam(slot:value:)`). Inserting a param in the
            // middle silently re-points every saved automation lane on every
            // existing instance of this effect. A future `lookahead`,
            // `detectMode` or `stereoLink` APPENDS at slot 6+, which is always
            // safe — and nothing here is a reserved slot, because a
            // reserved-but-inert param buys an ordering that was never at risk
            // and puts a lie in `fx.describe`.
            //
            // ⚠️ The three dB params and `mix` are `.linear` BY FORCE, not by
            // taste: their ranges cross or touch 0, and `.logarithmic` /
            // `.decibel` require `lo > 0` (`ParamCurveConformanceTests`'
            // `multiplicativeCurvesHaveAPositiveLowerBound`) with a SILENT
            // runtime fallback to linear if they do not.
            return [
                EffectParamSpec(name: "attackDb", range: TransientShaperParams.attackDbRange,
                                defaultValue: 0, unit: "dB", curve: .linear,
                                modulatable: .yes,
                                note: "PUNCH. How much louder or quieter to make the FRONT of "
                                    + "each sound - the stick hitting the drum, the pick hitting "
                                    + "the string - without touching the rest of it. Positive "
                                    + "adds punch and makes a kit sound closer and more "
                                    + "aggressive; negative rounds the hit off and pushes it back "
                                    + "into the room, which is the fastest way to tame a clicky "
                                    + "kick or an over-close snare. \u{2B50} THE NUMBER IS A "
                                    + "MAXIMUM, NOT A PROMISE: +6 means 'up to +6 dB', and the "
                                    + "full amount only lands on a hit whose start is at least 12 "
                                    + "dB louder than its own running average "
                                    + "(`fullShapeDifferentialDb`, reported in every fx.add and "
                                    + "fx.setParam RESULT). A soft, slow-swelling sound has a "
                                    + "smaller difference and gets proportionally less - which is "
                                    + "what makes this feel natural rather than pumping. It works "
                                    + "at ANY fader level: the detector compares the sound to "
                                    + "ITSELF, so turning the track down does not turn the effect "
                                    + "down. \u{26A0} LEVEL WARNING, because it is real and not a "
                                    + "mixing choice: a positive setting RAISES PEAKS, so check "
                                    + "your headroom or trim it back with `outputDb`. Nothing "
                                    + "happens at all below -70 dBFS (`detectorFloorDb`) - that "
                                    + "is deliberate, so room tone and noise are never shaped. "
                                    + "The curve is linear because the range crosses 0 and a "
                                    + "logarithmic taper cannot."),
                EffectParamSpec(name: "sustainDb", range: TransientShaperParams.sustainDbRange,
                                defaultValue: 0, unit: "dB", curve: .linear,
                                modulatable: .yes,
                                note: "BODY. How much more (or less) of the ring-out AFTER the "
                                    + "hit - the tail of a snare, the decay of a piano note, the "
                                    + "room a drum was recorded in. \u{2B50} POSITIVE LENGTHENS "
                                    + "the tail and negative SHORTENS it, which is the opposite "
                                    + "way round from what some people expect: +9 holds the "
                                    + "ring-out up as it falls, so you hear more of the room; -9 "
                                    + "pulls it down faster, which is how you get a tight, dry, "
                                    + "close-miked kit out of a roomy recording without a gate. "
                                    + "\u{26A0} It does NOT ring forever at +9 - the reference "
                                    + "the effect compares against is itself decaying, so the "
                                    + "boost saturates and then falls away. You get a longer "
                                    + "tail, not an infinite one. Like `attackDb` this is a "
                                    + "MAXIMUM reached only at a full 12 dB difference, it is "
                                    + "level-independent, and it does nothing below -70 dBFS. "
                                    + "The two controls are INDEPENDENT by construction: setting "
                                    + "this one does not move the front of the sound, which is "
                                    + "the whole reason this is a transient shaper and not a "
                                    + "compressor."),
                EffectParamSpec(name: "attackMs", range: TransientShaperParams.attackMsRange,
                                defaultValue: 5, unit: "ms", curve: .logarithmic,
                                modulatable: .yes,
                                note: "PUNCH LENGTH. How long the FRONT of a sound lasts, as far "
                                    + "as this effect is concerned - not a fade time and not a "
                                    + "delay. It sets how quickly the effect stops treating a "
                                    + "sound as 'still starting'. SHORT (0.1-3 ms) catches only "
                                    + "the very tip: the click of a kick beater, the snap of a "
                                    + "snare's stick. MEDIUM (5 ms, the default) is the body of a "
                                    + "drum hit and suits a whole loop. LONG (20-50 ms) reaches "
                                    + "into plucks and piano notes, where the 'attack' genuinely "
                                    + "is that long. \u{2B50} The window over which the boost is "
                                    + "at FULL strength is about 0.29 times this number - so 5 ms "
                                    + "gives roughly 1.4 ms of full punch, and 30 ms gives about "
                                    + "8.7 ms. You do not have to work that out: it is reported "
                                    + "as `attackWindowMs` in every fx.add and fx.setParam "
                                    + "RESULT. Too long and the effect stops sounding like punch "
                                    + "and starts sounding like a volume ride; too short and it "
                                    + "only sharpens the click without adding weight. The curve "
                                    + "is logarithmic because the useful range spans nine octaves "
                                    + "and most of what you want lives under 5 ms, which a linear "
                                    + "knob would bury in its first tenth."),
                EffectParamSpec(name: "sustainMs", range: TransientShaperParams.sustainMsRange,
                                defaultValue: 200, unit: "ms", curve: .logarithmic,
                                modulatable: .yes,
                                note: "BODY LENGTH. How far into the tail `sustainDb` keeps "
                                    + "working, in milliseconds. SHORT (20-80 ms) only catches "
                                    + "the immediate drop after a hit, which tightens a kit "
                                    + "without changing the room; the default 200 ms covers a "
                                    + "normal snare or tom decay; LONG (500-1000 ms) reaches into "
                                    + "cymbal wash, piano pedal and reverb tails, where a "
                                    + "negative `sustainDb` starts working like a very gentle, "
                                    + "very musical gate. \u{26A0} Set this LONGER than the decay "
                                    + "you want to affect, not shorter - if it ends before the "
                                    + "tail does, the last part of the tail is left untouched and "
                                    + "you hear the effect stop. It has no effect at all while "
                                    + "`sustainDb` is 0, which is the default. The curve is "
                                    + "logarithmic because the range spans nearly six octaves."),
                EffectParamSpec(name: "outputDb", range: TransientShaperParams.outputDbRange,
                                defaultValue: 0, unit: "dB", curve: .linear,
                                modulatable: .yes,
                                note: "OUTPUT TRIM. A plain level control applied after the "
                                    + "shaping - no detector, no dependence on the material. "
                                    + "\u{2B50} IT IS NOT A NICETY, IT IS HOW YOU JUDGE THE "
                                    + "EFFECT HONESTLY: adding punch genuinely raises the "
                                    + "loudness, and a listener reliably calls the louder version "
                                    + "the better one. Trim here until the shaped and unshaped "
                                    + "versions measure the same loudness, and what is left is "
                                    + "the punch itself. That works because this effect changes "
                                    + "the CREST FACTOR - the gap between the peaks and the "
                                    + "average - which is exactly what loudness matching does "
                                    + "NOT flatten out. Also the place to claw back headroom "
                                    + "after a positive `attackDb`. The curve is linear because "
                                    + "the range crosses 0."),
                EffectParamSpec(name: "mix", range: TransientShaperParams.mixRange,
                                defaultValue: 1, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "Blend the shaped sound back with the untouched one. 1 "
                                    + "(the default) is fully shaped; 0.5 is half. \u{26A0} "
                                    + "Unlike most dry/wet controls this one is rarely what you "
                                    + "want: the effect is already proportional to how much of a "
                                    + "transient there is, so turning `attackDb` down is usually "
                                    + "a better way to get less of it, and `mix` mainly earns its "
                                    + "place for automating the whole effect in and out of a "
                                    + "section. \u{2B50} AT THE DEFAULTS THIS INSERT IS BIT-EXACT "
                                    + "DRY - with `attackDb`, `sustainDb` and `outputDb` all 0 "
                                    + "the output is identical to the input sample for sample, "
                                    + "not merely close - so a freshly added transient shaper "
                                    + "provably changes nothing until you move something. The "
                                    + "curve is linear because the range touches 0."),
            ]
        case .freqShifter:
            // ⛔⛔ ORDER IS FROZEN AND APPEND-ONLY FOREVER. The INDEX of a spec
            // in this array IS the automation slot number
            // (`storeAutomatedParam(slot:value:)`). A future `feedback`,
            // `driveDb` or `carrierMode` APPENDS at slot 5+, which is always
            // safe. Nothing here is a reserved slot.
            //
            // ⚠️ EVERY curve is `.linear` BY FORCE, not by taste: four of the
            // five ranges CROSS 0 and `mix`'s TOUCHES it, and
            // `.logarithmic`/`.decibel` require `lo > 0` with a SILENT runtime
            // fallback (`ParamCurveConformanceTests`'
            // `multiplicativeCurvesHaveAPositiveLowerBound`). `fineHz` exists
            // precisely BECAUSE the log curve that would fix `shiftHz`'s
            // resolution is unavailable to a bipolar range.
            return [
                EffectParamSpec(name: "shiftHz", range: FreqShifterParams.shiftHzRange,
                                defaultValue: 0, unit: "Hz", curve: .linear,
                                modulatable: .yes,
                                note: "HOW FAR TO SHIFT, in Hz - and the SIGN IS THE DIRECTION: "
                                    + "positive moves everything UP, negative DOWN. There is no "
                                    + "separate up/down switch on purpose, so you can sweep "
                                    + "smoothly through zero. \u{2B50} THIS IS NOT A PITCH "
                                    + "CONTROL AND IT WILL NOT PLAY IN TUNE. A pitch shifter "
                                    + "MULTIPLIES every frequency by the same amount, so a note "
                                    + "stays a note. This ADDS the same number of Hz to every "
                                    + "frequency, which breaks the maths that makes a sound "
                                    + "musical: a note built from 100, 200 and 300 Hz shifted by "
                                    + "100 becomes 200, 300 and 400 Hz, which the ear hears as a "
                                    + "BELL or a piece of METAL rather than a note. That is the "
                                    + "whole point of the effect - if you want it in tune, you "
                                    + "want a pitch shifter instead. SMALL amounts (under about "
                                    + "20 Hz, where `fineHz` is the better knob) give a slow "
                                    + "beating, swirling thickness. LARGE amounts (hundreds of "
                                    + "Hz) are clangorous sound design. \u{26A0} Shifting DOWN by "
                                    + "more than a sound's own frequency pushes it below 0 Hz and "
                                    + "it REFLECTS back up again - a 100 Hz tone shifted -300 Hz "
                                    + "returns at 200 Hz. That is real behaviour that analog "
                                    + "frequency shifters have too, not a fault. Large UPWARD "
                                    + "shifts can likewise push high content past the top of the "
                                    + "sample rate, where it folds back down. The curve is linear "
                                    + "because the range crosses 0."),
                EffectParamSpec(name: "fineHz", range: FreqShifterParams.fineHzRange,
                                defaultValue: 0, unit: "Hz", curve: .linear,
                                modulatable: .yes,
                                note: "THE SAME CONTROL, BUT FINE - added on top of `shiftHz`. "
                                    + "\u{2B50} THIS IS THE ONE YOU WANT FOR THE CLASSIC TRICK. A "
                                    + "shift of only 1-20 Hz does not sound like a shift at all: "
                                    + "it makes the sound beat slowly against itself, which "
                                    + "thickens and widens it in a way a chorus cannot, and is "
                                    + "the oldest fix in live sound for a microphone that is "
                                    + "about to feed back. It needs its own knob because 5 Hz is "
                                    + "a quarter of one percent of `shiftHz`'s travel, so on the "
                                    + "coarse control it lives in a sliver too small to set or "
                                    + "automate. The two are simply ADDED, and their sum is "
                                    + "capped at the coarse control's own limit so the pair can "
                                    + "never exceed what this effect says its range is. The curve "
                                    + "is linear because the range crosses 0."),
                EffectParamSpec(name: "stereoSpreadHz",
                                range: FreqShifterParams.stereoSpreadHzRange,
                                defaultValue: 0, unit: "Hz", curve: .linear,
                                modulatable: .yes,
                                note: "SHIFT THE TWO SPEAKERS BY DIFFERENT AMOUNTS - left gets "
                                    + "half of this added, right gets half subtracted. At 0 (the "
                                    + "default) both sides are identical and the result stays "
                                    + "mono-compatible. \u{2B50} A VALUE OF 1-6 Hz IS THE WIDEST "
                                    + "THIS EFFECT GETS: the two sides drift slowly in and out of "
                                    + "step with each other, so the sound appears to churn "
                                    + "between the speakers without any delay or reverb being "
                                    + "involved. Pair it with a small `fineHz` for a lush "
                                    + "chorus-like wash, or leave `shiftHz` large and this small "
                                    + "for a metallic texture that still has a stereo image. "
                                    + "\u{26A0} Because the two sides genuinely differ, a mono "
                                    + "fold-down will partly cancel - check mono if the mix has "
                                    + "to survive it. It does nothing on a mono track. The curve "
                                    + "is linear because the range crosses 0."),
                EffectParamSpec(name: "mix", range: FreqShifterParams.mixRange,
                                defaultValue: 0.5, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "Blend the shifted sound against the untouched one. "
                                    + "\u{2B50} THIS CONTROL MATTERS MORE HERE THAN ON MOST "
                                    + "EFFECTS. At 1 (fully shifted) the original note is GONE - "
                                    + "there is nothing in tune left - which is what you want for "
                                    + "bells and metal, and rarely what you want on a lead vocal "
                                    + "or a bass. The default 0.5 keeps the original present so "
                                    + "the shifted copy reads as colour on top of it, and it is "
                                    + "also what makes small `fineHz` values beat against the dry "
                                    + "signal instead of just sitting there. \u{26A0} At exactly "
                                    + "0 this insert is BIT-EXACT DRY - the output is identical "
                                    + "to the input sample for sample, not merely close - while "
                                    + "the effect keeps running underneath, so raising it again "
                                    + "fades in smoothly rather than jumping. The curve is linear "
                                    + "because the range touches 0."),
                EffectParamSpec(name: "outputDb", range: FreqShifterParams.outputDbRange,
                                defaultValue: 0, unit: "dB", curve: .linear,
                                modulatable: .yes,
                                note: "OUTPUT TRIM for the SHIFTED COPY ONLY - it is applied "
                                    + "before the `mix` blend, so it never touches the dry "
                                    + "signal and `mix` 0 stays exactly dry however this is set. "
                                    + "\u{2B50} IT EARNS "
                                    + "ITS PLACE BECAUSE THIS EFFECT CAN GET LOUDER ALL BY "
                                    + "ITSELF, which surprises people: the method works by "
                                    + "building a 90-degree-rotated copy of the signal, and the "
                                    + "combination of the two can peak higher than the original "
                                    + "did even though nothing was amplified. On dense material "
                                    + "at full `mix` expect to pull a couple of dB back here. "
                                    + "Also the place to loudness-match the shifted and unshifted "
                                    + "versions so you judge the character rather than the "
                                    + "level. The curve is linear because the range crosses 0."),
            ]
        case .clipper:
            // ⛔⛔ ORDER IS FROZEN AND APPEND-ONLY FOREVER. The INDEX of a spec
            // in this array IS the automation slot number
            // (`storeAutomatedParam(slot:value:)`). A future `kneeDb`,
            // `linkChannels` or `dcFilter` APPENDS at slot 6+, which is always
            // safe. Nothing here is a reserved slot.
            //
            // ⚠️ EVERY curve is `.linear`, and for two different reasons.
            // `driveDb`/`ceilingDb`/`outputDb`/`mix` are linear BY FORCE: their
            // ranges cross or touch 0 and `.logarithmic`/`.decibel` require
            // `lo > 0` with a SILENT runtime fallback
            // (`ParamCurveConformanceTests`). `oversampling` is linear BY RULE:
            // `ParamCurveConformanceTests` pins the biconditional "every
            // logarithmic param is Hz-unit", and a factor is not a frequency —
            // a log taper here would be the only exception in the whole table.
            return [
                EffectParamSpec(name: "driveDb", range: ClipperParams.driveDbRange,
                                defaultValue: 0, unit: "dB", curve: .linear,
                                modulatable: .yes,
                                note: "HOW HARD YOU PUSH THE SOUND INTO THE CEILING - the control "
                                    + "that decides how much clipping actually happens. The "
                                    + "ceiling says WHERE the cut is; this says how far past it "
                                    + "the sound is driven, and therefore how much gets cut off. "
                                    + "0 (the default) changes nothing on its own, so a freshly "
                                    + "added clipper only touches peaks that were already above "
                                    + "the ceiling. \u{2B50} THE USEFUL NUMBER IS NEITHER KNOB ON "
                                    + "ITS OWN: clipping starts at an INPUT level of `ceilingDb - "
                                    + "driveDb` dBFS, reported as `clipThresholdDbfs` in every "
                                    + "fx.add and fx.setParam RESULT. So ceiling -0.3 with drive "
                                    + "6 starts clipping anything above -6.3 dBFS. \u{26A0} IT "
                                    + "GETS LOUDER AND LOUDER IS NOT BETTER: driving harder "
                                    + "raises the average level while the peaks stay pinned at "
                                    + "the ceiling, and a listener reliably calls the louder "
                                    + "version the better one. Pull `outputDb` back until the "
                                    + "clipped and unclipped versions measure the same loudness "
                                    + "before you decide. Negative values are allowed and are a "
                                    + "real setting: with a low ceiling and a negative drive this "
                                    + "becomes a quiet, gentle wave-shaper instead of a loudness "
                                    + "tool. The curve is linear because the range crosses 0."),
                EffectParamSpec(name: "ceilingDb", range: ClipperParams.ceilingDbRange,
                                defaultValue: -0.3, unit: "dBFS", curve: .linear,
                                modulatable: .yes,
                                note: "THE CEILING. No output sample goes above this level - that "
                                    + "is a guarantee, not a tendency, and it is what makes this "
                                    + "a clipper rather than a saturator (a saturator's curve "
                                    + "only ever APPROACHES its limit, so it can never promise "
                                    + "one). The default -0.3 dBFS is the usual safe mastering "
                                    + "ceiling: just under full scale, with a little room for "
                                    + "what an MP3 encoder does later. Lower it (-3, -6) and you "
                                    + "are choosing to clip much more of the material, which is a "
                                    + "sound-design move rather than a mastering one. "
                                    + "\u{26A0} SAMPLE CEILING, NOT TRUE-PEAK CEILING, and the "
                                    + "difference is real: the samples are bounded exactly, but "
                                    + "the smooth wave drawn THROUGH them can ride slightly "
                                    + "higher between samples, and that is what a broadcast "
                                    + "true-peak meter reads. Expect up to about a decibel of it "
                                    + "with oversampling on; it is the honest cost of removing "
                                    + "the aliasing and it is not a bug. If you need a true-peak "
                                    + "guarantee, put a `limiter` with `truePeak` on after this. "
                                    + "The range stops at 0 dBFS because a ceiling above full "
                                    + "scale is not a ceiling. The curve is linear because the "
                                    + "range touches 0."),
                EffectParamSpec(name: "mode", range: ClipperParams.modeRange,
                                defaultValue: 0, unit: "mode", curve: .linear,
                                modulatable: .refused,
                                note: "THE SHAPE OF THE CUT. 0 = HARD (the default): the wave is "
                                    + "sliced off flat at the ceiling, leaving a sharp corner. "
                                    + "That corner is what makes the bright, aggressive, "
                                    + "in-your-face sound people reach for a clipper to get, and "
                                    + "it is also what generates the most content above the "
                                    + "hearing range - so it is the mode that benefits most from "
                                    + "`oversampling`. 1 = SOFT: the wave bends into the ceiling "
                                    + "instead of hitting it, and only goes properly flat once "
                                    + "the input is 1.5 times the ceiling. Softer, warmer, much "
                                    + "less obvious, and still a real ceiling - quiet material "
                                    + "passes through soft mode completely untouched, which is "
                                    + "the thing a tanh saturator cannot do. \u{26A0} IT IS A "
                                    + "SWITCH, NOT A BLEND: 0.4 rounds to hard and 0.6 to soft; "
                                    + "there is no halfway. That is also why modulation refuses "
                                    + "it - an LFO on a switch is a stutter, not a sweep. "
                                    + "Automation can still step it between sections."),
                EffectParamSpec(name: "oversampling", range: ClipperParams.oversamplingRange,
                                defaultValue: 4, unit: "x", curve: .linear,
                                modulatable: .refused,
                                note: "\u{2B50} THE QUALITY CONTROL, AND THE ONLY ONE ON THIS "
                                    + "EFFECT THAT CHANGES WHAT CLIPPING SOUNDS LIKE WITHOUT "
                                    + "CHANGING HOW MUCH OF IT THERE IS. Chopping the top off a "
                                    + "wave creates new tones far above anything you can hear. "
                                    + "Digital audio cannot store those, so they FOLD BACK down "
                                    + "into the music as tones that have no musical relationship "
                                    + "to what is playing - it sounds like a thin metallic fizz "
                                    + "sitting behind the sound, worst on bright material and on "
                                    + "high notes. Running the clipper at 2 or 4 times the "
                                    + "session's sample rate pushes that fold up out of the way "
                                    + "and then filters it off. 4 (the default) is the clean one; "
                                    + "2 is the cheaper compromise; 1 turns the machinery OFF "
                                    + "entirely and lets the fizz through. \u{2B50} 1 IS A REAL "
                                    + "SETTING, NOT A BROKEN ONE - plenty of records want that "
                                    + "grit, and it is the only way to hear what the other "
                                    + "settings are removing. \u{26A0} Only 1, 2 and 4 exist; 3 "
                                    + "rounds UP to 4. It costs CPU roughly in proportion to the "
                                    + "number. \u{26A0} It does NOT change the effect's latency - "
                                    + "that is a fixed 32 samples at every setting, by design, so "
                                    + "changing this never shifts the track's timing. Modulation "
                                    + "refuses it because it is a switch, and changing it mid-"
                                    + "sound restarts the internal filters, which is a tiny click."),
                EffectParamSpec(name: "mix", range: ClipperParams.mixRange,
                                defaultValue: 1, unit: "linear", curve: .linear,
                                modulatable: .yes,
                                note: "Blend the clipped sound with the untouched one - the "
                                    + "'parallel clipping' trick, which keeps the transients of "
                                    + "the original while adding the density of the clipped "
                                    + "version. 1 (the default) is fully clipped. \u{26A0} AT 0 "
                                    + "THIS EFFECT IS NOT SILENT AND NOT BYPASSED: it passes the "
                                    + "input through EXACTLY, sample for sample, but delayed by "
                                    + "32 samples - the fixed latency every setting of this "
                                    + "effect has. The project's delay compensation removes that "
                                    + "delay again, so in the mix it lines up perfectly; it "
                                    + "matters only if you are comparing raw rendered files by "
                                    + "eye. The dry half of this blend is delayed by the same 32 "
                                    + "samples as the clipped half, which is why a partial mix "
                                    + "stays in phase instead of sounding hollow. The curve is "
                                    + "linear because the range touches 0."),
                EffectParamSpec(name: "outputDb", range: ClipperParams.outputDbRange,
                                defaultValue: 0, unit: "dB", curve: .linear,
                                modulatable: .yes,
                                note: "OUTPUT TRIM for the CLIPPED COPY ONLY - applied before the "
                                    + "`mix` blend, so `mix` 0 stays exactly dry however this is "
                                    + "set. \u{2B50} IT IS NOT A NICETY, IT IS HOW YOU JUDGE A "
                                    + "CLIPPER HONESTLY: clipping makes things louder, and louder "
                                    + "always sounds better for the first few seconds. Trim here "
                                    + "until the clipped and unclipped versions measure the same "
                                    + "loudness, and what is left is the actual character. "
                                    + "\u{26A0} A POSITIVE VALUE HERE BREAKS THE CEILING "
                                    + "PROMISE - the guarantee is that samples stay under "
                                    + "`ceilingDb`, and this is applied afterwards, so the real "
                                    + "guaranteed maximum is `ceilingDb + outputDb` (reported as "
                                    + "`wetCeilingDbfs` in every fx.add and fx.setParam RESULT). "
                                    + "Use negative values unless you know why you want the "
                                    + "other. The curve is linear because the range crosses 0."),
            ]
        case .dynamicEQ:
            // ⛔ BAND-MAJOR, GENERATED FROM ONE BLOCK RATHER THAN SPELLED OUT
            // FOUR TIMES, AND THAT IS THE POINT. The kind's whole reviewability
            // claim is `slot = (band−1)·8 + p`; four hand-written blocks of
            // eight would let one band drift from the others in a way no
            // compiler and no reviewer would catch. `specs(for:)` is never
            // called on the render thread (every caller —
            // `AutomationSchedule.resolveEffectParamLanes`,
            // `ModulationSnapshotBuilder`, `EffectEditorModel`,
            // `ProjectStore.setEffectParam` — is main-actor or build-time), so
            // building the array here costs nothing that matters.
            // `DynamicEQParamsTests.slotOrderIsFrozen` pins all 32 names, in
            // order, against literals.
            return (1...DynamicEQParams.bandCount).flatMap { dynamicEQBandSpecs(band: $0) }
        case .audioUnit:
            // AU parameters are not on the generic name/value surface in v0;
            // bypass/reorder/latency work generically through the chain.
            return []
        }
    }

    /// One dynamic-EQ band's eight specs, in slot order (m39-af). See the
    /// `.dynamicEQ` arm above for why this is generated.
    private static func dynamicEQBandSpecs(band n: Int) -> [EffectParamSpec] {
        // The shared-budget warning is carried on BAND 1's mode only, not
        // repeated four times: `fx.describe` returns the whole table in one
        // response, so an agent reading band3Mode has band1Mode's note in front
        // of it already.
        let budgetNote = n == 1
            ? " \u{26A0}\u{26A0} BUDGET, because this kind is the largest in the app: a fully "
                + "automated Dynamic EQ is 32 automation lanes, and automation lanes and "
                + "modulated effect params SHARE ONE 64-entry cap per mixer strip. One of "
                + "these uses HALF of it. Past 64 the extra lanes are dropped silently, so "
                + "automate the bands you are actually riding rather than all four."
            : ""
        return [
            EffectParamSpec(
                name: "band\(n)Mode", range: DynamicEQParams.modeRange,
                defaultValue: 0, unit: "linear", curve: .linear, modulatable: .refused,
                note: "\u{2B50} BAND \(n)'s ON SWITCH, and which side of the threshold wakes it "
                    + "up. 0 (the default) is OFF and it is a TRUE no-op — the band's filter is "
                    + "not even run, so a freshly added Dynamic EQ is bit-for-bit transparent "
                    + "until you turn a band on. 1 is ABOVE: the band reacts when the level "
                    + "INSIDE THIS BAND rises past band\(n)ThresholdDb. 2 is BELOW: it reacts "
                    + "when that level falls under the threshold. \u{26D4} WHICH WAY the band "
                    + "then MOVES is the SIGN of band\(n)RangeDb, not a third control, which "
                    + "gives four musical moves from two knobs: above + negative (the default "
                    + "sign) turns the band DOWN when it gets loud — de-essing, de-harshing, "
                    + "taming a boxy 300 Hz, controlling a snare ring; above + positive turns it "
                    + "UP when it gets loud, which exaggerates a transient's brightness; below + "
                    + "positive turns it UP when it gets quiet, which restores air under a fade; "
                    + "below + negative turns it DOWN when it gets quiet, which is one-band "
                    + "downward expansion for mic rumble between phrases. \u{26A0} MODE 2 SITS "
                    + "AT FULL RANGE ON SILENCE AND THAT IS CORRECT, NOT A BUG: digital silence "
                    + "reads as -180 dBFS in the band, which is below every threshold, so a "
                    + "'below' band is fully triggered. That is what an expander does to "
                    + "silence. \u{26A0} DISCRETE — automate it with hold steps, never a ramp, "
                    + "and modulation refuses it outright. Values snap to the nearest of "
                    + "0/1/2." + budgetNote),
            EffectParamSpec(
                name: "band\(n)Freq", range: DynamicEQParams.freqRange,
                defaultValue: DynamicEQParams.defaultFreq(band: n), unit: "Hz",
                curve: .logarithmic, modulatable: .warned,
                note: "Where band \(n) LISTENS and where it MOVES THE GAIN — one filter does "
                    + "both jobs, which is why band\(n)ThresholdDb means dBFS measured AT THE "
                    + "BAND CENTRE at every width. The four defaults are spread across the "
                    + "spectrum (120 / 500 / 3000 / 8000 Hz) so the bands read left to right "
                    + "like an EQ. INERT while band\(n)Mode is 0 — setting it on an off band is "
                    + "a no-op rather than a mistake. \u{26A0} MODULATION IS WARNED, not "
                    + "refused: this is a FILTER corner, so moving it recomputes biquad "
                    + "coefficients and zippers at any rate (the eq.peak1Freq problem). "
                    + "Automation between sections is fine; an LFO on it is not what you want."),
            EffectParamSpec(
                name: "band\(n)Q", range: DynamicEQParams.qRange,
                defaultValue: 2, unit: "linear", curve: .linear, modulatable: .warned,
                note: "How WIDE band \(n) is — higher is narrower. \u{26D4} THIS Q DOES NOT MEAN "
                    + "WHAT eq.peak1Q MEANS, and the difference is MEASURED rather than "
                    + "stylistic: at 1 kHz and Q 2 a band here is about 704 Hz wide at half gain "
                    + "where the EQ's is 498 Hz, and this one WIDENS as the band works harder "
                    + "(592 / 704 / 993 / 1401 Hz at 3 / 6 / 12 / 18 dB of movement) while the "
                    + "EQ's stays fixed. That is the deliberate price of this kind's topology: "
                    + "the band's poles do NOT move with its gain, which is exactly what lets "
                    + "the gain change every single sample without clicking. Both reach the gain "
                    + "you asked for at the centre. In practice: 0.5-0.7 for a wide de-harsher "
                    + "or a stand-in dynamic high shelf, 2 for general tone, 4-8 to chase one "
                    + "ringing resonance. \u{2B50} The band's PEAK is 0 dB at EVERY Q, so "
                    + "widening it does not quietly move your threshold. \u{26A0} MODULATION IS "
                    + "WARNED for the band\(n)Freq reason — it is a filter coefficient."),
            EffectParamSpec(
                name: "band\(n)ThresholdDb", range: DynamicEQParams.thresholdRange,
                defaultValue: -18, unit: "dB", curve: .linear, modulatable: .yes,
                note: "The level where band \(n) starts working, in dBFS MEASURED INSIDE THE "
                    + "BAND — not the level of the whole mix. A quiet track can still trigger a "
                    + "band that is parked on its loudest frequency, which is the point. "
                    + "\u{26A0} THE SOFT KNEE STARTS 3 dB BELOW THIS NUMBER: the knee is fixed "
                    + "at 6 dB, so the band is completely still only while the band level is at "
                    + "or under threshold minus 3, and at exactly the threshold it is already "
                    + "moving about 0.56 dB at the default 4:1. Do not read 'at threshold' as "
                    + "'doing nothing'. Start about 6-10 dB under the band's loudest peaks and "
                    + "lower it until it moves on the problem and not on everything."),
            EffectParamSpec(
                name: "band\(n)Ratio", range: DynamicEQParams.ratioRange,
                defaultValue: 4, unit: "ratio", curve: .linear, modulatable: .yes,
                note: "How hard band \(n) reacts to how far past the threshold it is: at 4 (the "
                    + "default) every 4 dB past the threshold asks for 1 dB of movement, capped "
                    + "by band\(n)RangeDb. \u{26A0} 1 MEANS NO REACTION AT ALL — the band does "
                    + "nothing however you set the rest, which is the usual cause of 'the "
                    + "dynamic EQ is not doing anything'. 2-4 is transparent, 8-20 is a clamp. "
                    + "\u{26A0} THE SAME LAW IS USED IN 'BELOW' MODE as in 'above', "
                    + "deliberately: one control that means the same thing in both directions "
                    + "for a user who is not a dynamics specialist. A specialist expecting the "
                    + "textbook expander form should know it is a recorded decision, not an "
                    + "oversight."),
            EffectParamSpec(
                name: "band\(n)RangeDb", range: DynamicEQParams.rangeDbRange,
                defaultValue: -6, unit: "dB", curve: .linear, modulatable: .yes,
                note: "\u{2B50} HOW FAR BAND \(n) MAY MOVE, AND WHICH WAY — the sign IS the "
                    + "direction. NEGATIVE (the -6 dB default) turns the band DOWN when it "
                    + "triggers; POSITIVE turns it UP. The magnitude is a hard cap, so the band "
                    + "can never move further than this however hard it is driven, which is what "
                    + "makes a dynamic EQ safe to set aggressively. \u{26A0} 0 MAKES THE BAND DO "
                    + "NOTHING however it is triggered — the filter still runs but the gain "
                    + "stays exactly flat, bit-for-bit. Read with band\(n)Mode: 'above' plus "
                    + "negative is the familiar de-esser move; 'below' plus positive brings "
                    + "something back up when it gets quiet."),
            EffectParamSpec(
                name: "band\(n)AttackMs", range: DynamicEQParams.attackRange,
                defaultValue: 10, unit: "ms", curve: .linear, modulatable: .yes,
                note: "How fast band \(n) moves TOWARDS its target once it triggers. Short "
                    + "(0.1-5 ms) catches the front of a sibilant or a pick attack; long "
                    + "(30-100 ms) lets transients through untouched and only acts on sustained "
                    + "tone, which is what you want when you are taming a resonance rather than "
                    + "a consonant. \u{26A0} There is NO lookahead, deliberately, so a very "
                    + "short attack still cannot act before the sound arrives — that is also why "
                    + "this effect adds ZERO latency and nothing in your project shifts in time "
                    + "when you add it."),
            EffectParamSpec(
                name: "band\(n)ReleaseMs", range: DynamicEQParams.releaseRange,
                defaultValue: 100, unit: "ms", curve: .linear, modulatable: .yes,
                note: "How fast band \(n) returns to flat once the trigger passes. Too short on "
                    + "a low band pumps audibly; 100 ms (the default) is a safe general value "
                    + "and 200-500 ms is smoother on bass. On sibilance, short (20-60 ms) is "
                    + "right — the band has to be back to flat before the next vowel."),
        ]
    }
}

/// Reads one named parameter out of a descriptor — the exact inverse of
/// `ProjectStore.applyEffectParam`'s name→field mapping, over the SAME wire
/// names `fx.setParam` / `fx.describe` use. nil for an unknown name or an AU
/// descriptor (AU params are not on this surface in v1).
///
/// ⭐ MOVED HERE FROM `DAWAppKit.EffectEditorModel.paramValue` at m39-e, for
/// the reason `activeLane(for:)` moved to DAWCore at m26-o: a second consumer
/// appeared in a module that cannot import the first. The modulation layer
/// needs the CURRENT value of a modulated-but-unautomated effect param — it is
/// the `base` the depth law offsets — and it needs it on the DAWEngine publish
/// path and in DAWControl's `mod.describe`. The editor model now delegates to
/// this one home rather than carrying a copy that could drift.
public extension EffectDescriptor {
    // ⚠️ NO `public` on this method: it is redundant inside a `public
    // extension` and the compiler warns about it (pre-existing since m39-e
    // moved this function here; removed at m39-m because the tree builds warn-
    // free and a stale warning trains people to ignore new ones).
    func paramValue(_ name: String) -> Double? {
        switch kind {
        case .gain:
            let p = resolvedGain
            switch name {
            case "gainLinear": return p.gainLinear
            case "invertPolarity": return p.invertPolarity ? 1 : 0  // m38-a
            default: return nil
            }
        case .eq:
            let p = resolvedEQ
            switch name {
            case "lowShelfFreq": return p.lowShelfFreq
            case "lowShelfGainDb": return p.lowShelfGainDb
            case "peak1Freq": return p.peak1Freq
            case "peak1GainDb": return p.peak1GainDb
            case "peak1Q": return p.peak1Q
            case "peak2Freq": return p.peak2Freq
            case "peak2GainDb": return p.peak2GainDb
            case "peak2Q": return p.peak2Q
            case "highShelfFreq": return p.highShelfFreq
            case "highShelfGainDb": return p.highShelfGainDb
            // m22-a EQ v2 — resolved reads (nil semantics live in EQParams),
            // matching the wire's resolved params object exactly.
            case "highPassFreq": return p.resolvedHighPassFreq
            case "highPassSlopeDbPerOct": return Double(p.resolvedHighPassSlope)
            case "highPassEnabled": return p.resolvedHighPassEnabled ? 1 : 0
            case "lowShelfQ": return p.resolvedLowShelfQ
            case "lowShelfEnabled": return p.resolvedLowShelfEnabled ? 1 : 0
            case "peak1Enabled": return p.resolvedPeak1Enabled ? 1 : 0
            case "peak2Enabled": return p.resolvedPeak2Enabled ? 1 : 0
            case "highShelfQ": return p.resolvedHighShelfQ
            case "highShelfEnabled": return p.resolvedHighShelfEnabled ? 1 : 0
            case "lowPassFreq": return p.resolvedLowPassFreq
            case "lowPassSlopeDbPerOct": return Double(p.resolvedLowPassSlope)
            case "lowPassEnabled": return p.resolvedLowPassEnabled ? 1 : 0
            default: return nil
            }
        case .compressor:
            let p = resolvedCompressor
            switch name {
            case "thresholdDb": return p.thresholdDb
            case "ratio": return p.ratio
            case "attackMs": return p.attackMs
            case "releaseMs": return p.releaseMs
            case "kneeDb": return p.kneeDb
            case "makeupDb": return p.makeupDb
            case "mix": return p.mix
            // m39-ae de-esser — the STORED values, matching the wire's params
            // object. `detectorMode` rides as its raw number (the `truePeak`
            // 0/1 and `clipper.mode` convention); the SNAPPED value is a
            // separate `resolvedDetectorMode` echo on the wire, never here.
            case "detectorMode": return p.detectorMode
            case "detectorFreqHz": return p.detectorFreqHz
            case "detectorQ": return p.detectorQ
            default: return nil
            }
        case .limiter:
            let p = resolvedLimiter
            switch name {
            case "ceilingDb": return p.ceilingDb
            case "releaseMs": return p.releaseMs
            case "truePeak": return p.truePeak ? 1 : 0
            default: return nil
            }
        case .reverb:
            let p = resolvedReverb
            switch name {
            case "roomSize": return p.roomSize
            case "damping": return p.damping
            case "mix": return p.mix
            case "preDelayMs": return p.preDelayMs
            case "width": return p.width
            default: return nil
            }
        case .delay:
            let p = resolvedDelay
            switch name {
            case "timeMs": return p.timeMs
            case "feedback": return p.feedback
            case "mix": return p.mix
            case "pingPong": return p.pingPong
            case "highCutHz": return p.highCutHz
            // m22-f — resolved reads (nil semantics live in DelayParams),
            // matching the wire's resolved params object exactly.
            case "sync": return p.resolvedSync ? 1 : 0
            case "division": return p.resolvedDivision.beats
            default: return nil
            }
        case .saturator:
            let p = resolvedSaturator
            switch name {
            case "driveDb": return p.driveDb
            case "mix": return p.mix
            case "outputDb": return p.outputDb
            case "oversampling": return p.oversampling
            default: return nil
            }
        case .gate:
            let p = resolvedGate
            switch name {
            case "thresholdDb": return p.thresholdDb
            case "attackMs": return p.attackMs
            case "holdMs": return p.holdMs
            case "releaseMs": return p.releaseMs
            default: return nil
            }
        case .chorus:
            let p = resolvedChorus
            switch name {
            case "rateHz": return p.rateHz
            case "depthMs": return p.depthMs
            case "mix": return p.mix
            default: return nil
            }
        case .bassEnhancer:
            let p = resolvedBassEnhancer
            switch name {
            case "crossoverHz": return p.crossoverHz
            case "amount": return p.amount
            case "mix": return p.mix
            default: return nil
            }
        case .bitCrusher:
            let p = resolvedBitCrusher
            switch name {
            case "bits": return p.bits
            case "downsampleHz": return p.downsampleHz
            case "antiAlias": return p.antiAlias ? 1 : 0
            case "dither": return p.dither ? 1 : 0
            case "mix": return p.mix
            default: return nil
            }
        case .djFilter:
            let p = resolvedDJFilter
            switch name {
            case "position": return p.position
            case "resonance": return p.resonance
            case "slopeDbPerOct": return p.slopeDbPerOct
            case "deadZoneWidth": return p.deadZoneWidth
            case "resonanceTrack": return p.resonanceTrack
            default: return nil
            }
        case .ringMod:
            let p = resolvedRingMod
            switch name {
            case "carrierHz": return p.carrierHz
            case "mix": return p.mix
            case "waveform": return p.waveform
            case "inputHighCutHz": return p.inputHighCutHz
            case "stereoSpreadDeg": return p.stereoSpreadDeg
            default: return nil
            }
        case .flanger:
            let p = resolvedFlanger
            switch name {
            case "rateHz": return p.rateHz
            case "depthMs": return p.depthMs
            case "delayMs": return p.delayMs
            case "feedback": return p.feedback
            case "mix": return p.mix
            case "stereoPhaseDeg": return p.stereoPhaseDeg
            default: return nil
            }
        case .hallReverb:
            let p = resolvedHallReverb
            switch name {
            case "mix": return p.mix
            case "decaySeconds": return p.decaySeconds
            case "sizeMeters": return p.sizeMeters
            case "preDelayMs": return p.preDelayMs
            case "width": return p.width
            case "diffusion": return p.diffusion
            case "earlyLateBalance": return p.earlyLateBalance
            case "lowDecayMultiplier": return p.lowDecayMultiplier
            case "highDecayMultiplier": return p.highDecayMultiplier
            case "lowCrossoverHz": return p.lowCrossoverHz
            case "highCrossoverHz": return p.highCrossoverHz
            case "modRateHz": return p.modRateHz
            case "modDepthMs": return p.modDepthMs
            case "freeze": return p.freeze
            default: return nil
            }
        case .tapeDelay:
            let p = resolvedTapeDelay
            switch name {
            case "timeMs": return p.timeMs
            case "feedback": return p.feedback
            case "mix": return p.mix
            case "wowDepthMs": return p.wowDepthMs
            case "wowRateHz": return p.wowRateHz
            case "flutterDepthMs": return p.flutterDepthMs
            case "saturationDrive": return p.saturationDrive
            case "highCutHz": return p.highCutHz
            default: return nil
            }
        case .stereoWidth:
            let p = resolvedStereoWidth
            switch name {
            case "width": return p.width
            case "spread": return p.spread
            case "bassMonoHz": return p.bassMonoHz
            case "bassMonoAmount": return p.bassMonoAmount
            default: return nil
            }
        case .phaser:
            let p = resolvedPhaser
            switch name {
            case "rateHz": return p.rateHz
            case "centerHz": return p.centerHz
            case "depthOctaves": return p.depthOctaves
            case "stages": return p.stages
            case "feedback": return p.feedback
            case "mix": return p.mix
            case "stereoPhaseDeg": return p.stereoPhaseDeg
            default: return nil
            }
        case .transientShaper:
            let p = resolvedTransientShaper
            switch name {
            case "attackDb": return p.attackDb
            case "sustainDb": return p.sustainDb
            case "attackMs": return p.attackMs
            case "sustainMs": return p.sustainMs
            case "outputDb": return p.outputDb
            case "mix": return p.mix
            default: return nil
            }
        case .freqShifter:
            let p = resolvedFreqShifter
            switch name {
            case "shiftHz": return p.shiftHz
            case "fineHz": return p.fineHz
            case "stereoSpreadHz": return p.stereoSpreadHz
            case "mix": return p.mix
            case "outputDb": return p.outputDb
            default: return nil
            }
        case .clipper:
            let p = resolvedClipper
            switch name {
            case "driveDb": return p.driveDb
            case "ceilingDb": return p.ceilingDb
            case "mode": return p.mode
            case "oversampling": return p.oversampling
            case "mix": return p.mix
            case "outputDb": return p.outputDb
            default: return nil
            }
        case .dynamicEQ:
            // m39-af — 32 names, so the mapping lives in ONE home
            // (`DynamicEQParams.value(forParamName:)`) that this arm and
            // `ProjectStore.applyEffectParam`'s arm both read. Four hand-copied
            // 32-case switches is four chances for one band to drift.
            return resolvedDynamicEQ.value(forParamName: name)
        case .audioUnit:
            return nil
        }
    }
}
