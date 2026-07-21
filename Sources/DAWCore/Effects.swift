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
        /// tanh drive/waveshaper (no oversampling in v0) — M4 (iv).
        case saturator
        /// Downward noise gate with attack/hold/release — M4 (iv).
        case gate
        /// 2-voice modulated-delay chorus — M4 (iv).
        case chorus
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
        self.audioUnit = audioUnit
        self.sidechainSourceTrackID = sidechainSourceTrackID
    }
}

/// Parameters for the built-in gain/trim effect. Clamped on init so a
/// descriptor is always renderable as-is (PolySynthParams pattern).
public struct GainParams: Codable, Sendable, Equatable {
    /// Linear gain, 0...4 (1 = unity, up to +12 dB).
    public var gainLinear: Double

    public static let gainRange: ClosedRange<Double> = 0...4

    public init(gainLinear: Double = 1) {
        self.gainLinear = gainLinear.clamped(to: Self.gainRange)
    }

    private enum CodingKeys: String, CodingKey { case gainLinear }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(gainLinear: try c.decodeIfPresent(Double.self, forKey: .gainLinear) ?? 1)
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

    public static let thresholdRange: ClosedRange<Double> = -60...0
    public static let ratioRange: ClosedRange<Double> = 1...20
    public static let attackRange: ClosedRange<Double> = 0.1...200
    public static let releaseRange: ClosedRange<Double> = 5...2_000
    public static let kneeRange: ClosedRange<Double> = 0...24
    public static let makeupRange: ClosedRange<Double> = 0...24

    public init(
        thresholdDb: Double = -18,
        ratio: Double = 4,
        attackMs: Double = 10,
        releaseMs: Double = 100,
        kneeDb: Double = 6,
        makeupDb: Double = 0
    ) {
        self.thresholdDb = thresholdDb.clamped(to: Self.thresholdRange)
        self.ratio = ratio.clamped(to: Self.ratioRange)
        self.attackMs = attackMs.clamped(to: Self.attackRange)
        self.releaseMs = releaseMs.clamped(to: Self.releaseRange)
        self.kneeDb = kneeDb.clamped(to: Self.kneeRange)
        self.makeupDb = makeupDb.clamped(to: Self.makeupRange)
    }

    private enum CodingKeys: String, CodingKey {
        case thresholdDb, ratio, attackMs, releaseMs, kneeDb, makeupDb
    }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            thresholdDb: try c.decodeIfPresent(Double.self, forKey: .thresholdDb) ?? -18,
            ratio: try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 4,
            attackMs: try c.decodeIfPresent(Double.self, forKey: .attackMs) ?? 10,
            releaseMs: try c.decodeIfPresent(Double.self, forKey: .releaseMs) ?? 100,
            kneeDb: try c.decodeIfPresent(Double.self, forKey: .kneeDb) ?? 6,
            makeupDb: try c.decodeIfPresent(Double.self, forKey: .makeupDb) ?? 0)
    }
}

/// Parameters for the built-in lookahead limiter (M4 iii). The 5 ms lookahead
/// is FIXED (not a param) — it surfaces as the effect's `latencySamples`
/// (round(0.005 × sampleRate)), the first nonzero insert latency. Clamped on
/// init (GainParams pattern).
public struct LimiterParams: Codable, Sendable, Equatable {
    public var ceilingDb: Double
    public var releaseMs: Double

    public static let ceilingRange: ClosedRange<Double> = -24...0
    public static let releaseRange: ClosedRange<Double> = 5...1_000
    /// Fixed lookahead in seconds; `latencySamples = round(lookahead × rate)`.
    public static let lookaheadSeconds: Double = 0.005

    public init(ceilingDb: Double = -1, releaseMs: Double = 50) {
        self.ceilingDb = ceilingDb.clamped(to: Self.ceilingRange)
        self.releaseMs = releaseMs.clamped(to: Self.releaseRange)
    }

    private enum CodingKeys: String, CodingKey { case ceilingDb, releaseMs }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ceilingDb: try c.decodeIfPresent(Double.self, forKey: .ceilingDb) ?? -1,
            releaseMs: try c.decodeIfPresent(Double.self, forKey: .releaseMs) ?? 50)
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
    public var feedback: Double
    public var mix: Double
    public var pingPong: Double
    public var highCutHz: Double
    // MARK: m22-f tempo-sync additive optionals — nil = pre-m22-f behavior.
    /// nil = false. True derives the effective time from the project tempo.
    public var sync: Bool?
    /// nil = 1/4. The note length a synced delay tracks (ignored unsynced).
    public var division: NoteDivision?

    public static let timeRange: ClosedRange<Double> = 1...2_000
    public static let feedbackRange: ClosedRange<Double> = 0...0.95
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

/// Parameters for the built-in tanh saturator (M4 iv). Clamped on init
/// (GainParams pattern). v0 has no oversampling.
public struct SaturatorParams: Codable, Sendable, Equatable {
    public var driveDb: Double
    public var mix: Double
    public var outputDb: Double

    public static let driveRange: ClosedRange<Double> = 0...36
    public static let mixRange: ClosedRange<Double> = 0...1
    public static let outputRange: ClosedRange<Double> = -12...12

    public init(driveDb: Double = 12, mix: Double = 1, outputDb: Double = 0) {
        self.driveDb = driveDb.clamped(to: Self.driveRange)
        self.mix = mix.clamped(to: Self.mixRange)
        self.outputDb = outputDb.clamped(to: Self.outputRange)
    }

    private enum CodingKeys: String, CodingKey { case driveDb, mix, outputDb }

    /// Decoding routes through the clamping init.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            driveDb: try c.decodeIfPresent(Double.self, forKey: .driveDb) ?? 12,
            mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1,
            outputDb: try c.decodeIfPresent(Double.self, forKey: .outputDb) ?? 0)
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

/// Static parameter schema for every effect kind — the single source of truth
/// for `fx.describe`, control-layer validation, and MCP tool schemas.
public struct EffectParamSpec: Sendable, Equatable {
    public let name: String
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    /// Human-readable unit ("linear", "dB", "Hz", "s", "ratio", "%").
    public let unit: String
    /// Optional teaching line for params whose numeric surface hides extra
    /// semantics (nil-means-off filters, 12/24 slope snapping, 0/1 band
    /// bypass) — surfaced verbatim by `fx.describe` (m22-a).
    public let note: String?

    public init(name: String, range: ClosedRange<Double>, defaultValue: Double, unit: String,
                note: String? = nil) {
        self.name = name
        self.range = range
        self.defaultValue = defaultValue
        self.unit = unit
        self.note = note
    }

    /// Schemas per kind. M4 (iv) extends this table as kinds land.
    public static func specs(for kind: EffectDescriptor.Kind) -> [EffectParamSpec] {
        switch kind {
        case .gain:
            return [EffectParamSpec(name: "gainLinear", range: GainParams.gainRange,
                                    defaultValue: 1, unit: "linear")]
        case .eq:
            return [
                EffectParamSpec(name: "lowShelfFreq", range: EQParams.lowShelfFreqRange,
                                defaultValue: 100, unit: "Hz"),
                EffectParamSpec(name: "lowShelfGainDb", range: EQParams.gainDbRange,
                                defaultValue: 0, unit: "dB"),
                EffectParamSpec(name: "peak1Freq", range: EQParams.peakFreqRange,
                                defaultValue: 500, unit: "Hz"),
                EffectParamSpec(name: "peak1GainDb", range: EQParams.gainDbRange,
                                defaultValue: 0, unit: "dB"),
                EffectParamSpec(name: "peak1Q", range: EQParams.qRange,
                                defaultValue: 1, unit: "linear"),
                EffectParamSpec(name: "peak2Freq", range: EQParams.peakFreqRange,
                                defaultValue: 3_000, unit: "Hz"),
                EffectParamSpec(name: "peak2GainDb", range: EQParams.gainDbRange,
                                defaultValue: 0, unit: "dB"),
                EffectParamSpec(name: "peak2Q", range: EQParams.qRange,
                                defaultValue: 1, unit: "linear"),
                EffectParamSpec(name: "highShelfFreq", range: EQParams.highShelfFreqRange,
                                defaultValue: 8_000, unit: "Hz"),
                EffectParamSpec(name: "highShelfGainDb", range: EQParams.gainDbRange,
                                defaultValue: 0, unit: "dB"),
                // m22-a EQ v2 — APPENDED so the automation slot indices of the
                // ten original params (0…9) never move (slots = spec order).
                EffectParamSpec(name: "highPassFreq", range: EQParams.highPassFreqRange,
                                defaultValue: 20, unit: "Hz",
                                note: "High-pass corner (−3 dB, Butterworth). The filter is OFF "
                                    + "on a fresh EQ; setting this turns it on."),
                EffectParamSpec(name: "highPassSlopeDbPerOct", range: EQParams.slopeRange,
                                defaultValue: 12, unit: "dB/oct",
                                note: "High-pass steepness — only 12 or 24; other values snap "
                                    + "to the nearer."),
                EffectParamSpec(name: "highPassEnabled", range: 0...1,
                                defaultValue: 0, unit: "linear",
                                note: "0 bypasses the high-pass without losing its settings; 1 "
                                    + "turns it on (from a fresh EQ it starts at 20 Hz)."),
                EffectParamSpec(name: "lowShelfQ", range: EQParams.qRange,
                                defaultValue: EQParams.defaultShelfQ, unit: "linear",
                                note: "Low-shelf resonance. The default 0.707 is the classic "
                                    + "gentle shelf every pre-existing project uses."),
                EffectParamSpec(name: "lowShelfEnabled", range: 0...1,
                                defaultValue: 1, unit: "linear",
                                note: "0 bypasses just this band (a true no-op, identical to "
                                    + "the band being absent); 1 re-enables it."),
                EffectParamSpec(name: "peak1Enabled", range: 0...1,
                                defaultValue: 1, unit: "linear",
                                note: "0 bypasses just this band (a true no-op); 1 re-enables."),
                EffectParamSpec(name: "peak2Enabled", range: 0...1,
                                defaultValue: 1, unit: "linear",
                                note: "0 bypasses just this band (a true no-op); 1 re-enables."),
                EffectParamSpec(name: "highShelfQ", range: EQParams.qRange,
                                defaultValue: EQParams.defaultShelfQ, unit: "linear",
                                note: "High-shelf resonance. The default 0.707 is the classic "
                                    + "gentle shelf every pre-existing project uses."),
                EffectParamSpec(name: "highShelfEnabled", range: 0...1,
                                defaultValue: 1, unit: "linear",
                                note: "0 bypasses just this band (a true no-op); 1 re-enables."),
                EffectParamSpec(name: "lowPassFreq", range: EQParams.lowPassFreqRange,
                                defaultValue: 20_000, unit: "Hz",
                                note: "Low-pass corner (−3 dB, Butterworth). The filter is OFF "
                                    + "on a fresh EQ; setting this turns it on."),
                EffectParamSpec(name: "lowPassSlopeDbPerOct", range: EQParams.slopeRange,
                                defaultValue: 12, unit: "dB/oct",
                                note: "Low-pass steepness — only 12 or 24; other values snap "
                                    + "to the nearer."),
                EffectParamSpec(name: "lowPassEnabled", range: 0...1,
                                defaultValue: 0, unit: "linear",
                                note: "0 bypasses the low-pass without losing its settings; 1 "
                                    + "turns it on (from a fresh EQ it starts at 20 kHz)."),
            ]
        case .compressor:
            return [
                EffectParamSpec(name: "thresholdDb", range: CompressorParams.thresholdRange,
                                defaultValue: -18, unit: "dB"),
                EffectParamSpec(name: "ratio", range: CompressorParams.ratioRange,
                                defaultValue: 4, unit: "ratio"),
                EffectParamSpec(name: "attackMs", range: CompressorParams.attackRange,
                                defaultValue: 10, unit: "ms"),
                EffectParamSpec(name: "releaseMs", range: CompressorParams.releaseRange,
                                defaultValue: 100, unit: "ms"),
                EffectParamSpec(name: "kneeDb", range: CompressorParams.kneeRange,
                                defaultValue: 6, unit: "dB"),
                EffectParamSpec(name: "makeupDb", range: CompressorParams.makeupRange,
                                defaultValue: 0, unit: "dB"),
            ]
        case .limiter:
            return [
                EffectParamSpec(name: "ceilingDb", range: LimiterParams.ceilingRange,
                                defaultValue: -1, unit: "dB"),
                EffectParamSpec(name: "releaseMs", range: LimiterParams.releaseRange,
                                defaultValue: 50, unit: "ms"),
            ]
        case .reverb:
            return [
                EffectParamSpec(name: "roomSize", range: ReverbParams.roomSizeRange,
                                defaultValue: 0.5, unit: "linear"),
                EffectParamSpec(name: "damping", range: ReverbParams.dampingRange,
                                defaultValue: 0.5, unit: "linear"),
                EffectParamSpec(name: "mix", range: ReverbParams.mixRange,
                                defaultValue: 0.35, unit: "linear"),
                EffectParamSpec(name: "preDelayMs", range: ReverbParams.preDelayRange,
                                defaultValue: 10, unit: "ms"),
                EffectParamSpec(name: "width", range: ReverbParams.widthRange,
                                defaultValue: 1, unit: "linear"),
            ]
        case .delay:
            return [
                EffectParamSpec(name: "timeMs", range: DelayParams.timeRange,
                                defaultValue: 350, unit: "ms",
                                note: "Free-running delay time. Ignored while sync is 1 — the "
                                    + "effective time is then division × 60000 / tempo BPM, "
                                    + "recomputed on every tempo change; timeMs stays stored "
                                    + "as the unsync fallback."),
                EffectParamSpec(name: "feedback", range: DelayParams.feedbackRange,
                                defaultValue: 0.35, unit: "linear"),
                EffectParamSpec(name: "mix", range: DelayParams.mixRange,
                                defaultValue: 0.3, unit: "linear"),
                EffectParamSpec(name: "pingPong", range: DelayParams.pingPongRange,
                                defaultValue: 0, unit: "linear"),
                EffectParamSpec(name: "highCutHz", range: DelayParams.highCutRange,
                                defaultValue: 8_000, unit: "Hz"),
                // m22-f tempo sync — APPENDED so the automation slot indices
                // of the five original params (0…4) never move (slots = spec
                // order; sync/division themselves are deliberately NOT
                // automatable — the render thread can't do tempo math).
                EffectParamSpec(name: "sync", range: 0...1,
                                defaultValue: 0, unit: "linear",
                                note: "0 = free-running on timeMs (the default); 1 = tempo "
                                    + "sync — the effective time becomes the division's length "
                                    + "at the current tempo, clamped to 1…2000 ms, and follows "
                                    + "tempo changes. Not automatable."),
                EffectParamSpec(name: "division", range: DelayParams.divisionBeatsRange,
                                defaultValue: 1, unit: "beats",
                                note: "Synced note length as its duration in BEATS (quarter "
                                    + "notes); snaps to the nearest of 1/1…1/32 straight, "
                                    + "dotted (×1.5) or triplet (×2/3): 4=1/1, 1=1/4, "
                                    + "0.75=1/8d, 0.5=1/8, 0.333=1/8t, 0.25=1/16, 0.125=1/32. "
                                    + "Persisted as the token string (\"1/8d\"). Only heard "
                                    + "while sync is 1. Not automatable."),
            ]
        case .saturator:
            return [
                EffectParamSpec(name: "driveDb", range: SaturatorParams.driveRange,
                                defaultValue: 12, unit: "dB"),
                EffectParamSpec(name: "mix", range: SaturatorParams.mixRange,
                                defaultValue: 1, unit: "linear"),
                EffectParamSpec(name: "outputDb", range: SaturatorParams.outputRange,
                                defaultValue: 0, unit: "dB"),
            ]
        case .gate:
            return [
                EffectParamSpec(name: "thresholdDb", range: GateParams.thresholdRange,
                                defaultValue: -40, unit: "dB"),
                EffectParamSpec(name: "attackMs", range: GateParams.attackRange,
                                defaultValue: 1, unit: "ms"),
                EffectParamSpec(name: "holdMs", range: GateParams.holdRange,
                                defaultValue: 50, unit: "ms"),
                EffectParamSpec(name: "releaseMs", range: GateParams.releaseRange,
                                defaultValue: 100, unit: "ms"),
            ]
        case .chorus:
            return [
                EffectParamSpec(name: "rateHz", range: ChorusParams.rateRange,
                                defaultValue: 0.8, unit: "Hz"),
                EffectParamSpec(name: "depthMs", range: ChorusParams.depthRange,
                                defaultValue: 3, unit: "ms"),
                EffectParamSpec(name: "mix", range: ChorusParams.mixRange,
                                defaultValue: 0.5, unit: "linear"),
            ]
        case .audioUnit:
            // AU parameters are not on the generic name/value surface in v0;
            // bypass/reorder/latency work generically through the chain.
            return []
        }
    }
}
