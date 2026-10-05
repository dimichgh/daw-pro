import Foundation

// The modulation layer's domain model (m39-e), frozen by
// `docs/design/2026-09-19-modulation-layer.md` §7. UI-free and engine-free by
// construction: everything here is value types and pure functions, so the
// control plane (which imports DAWCore but NOT DAWEngine) and the render
// thread evaluate modulation through the SAME code.
//
// ⭐ THE LAW THIS FILE EXISTS TO ENFORCE (§3.2): every modulation source
// except the envelope follower is a PURE FUNCTION OF TRANSPORT SAMPLE
// POSITION — no accumulator, no phase register, no filter state. That is what
// makes seek-exactness, loop-exactness and live/offline agreement free rather
// than earned, and it is why no modulation event schedule is built at all.
// A one-pole slew on a source output would reintroduce history-dependence and
// break all three, so edge softening is a closed-form raised-cosine ramp.
//
// ⚠️ NO POSITIONAL INDICES ANYWHERE IN THIS MODEL. Routes and sources are
// addressed by UUID, targets by name. The append-only slot law
// (`EffectParamSpec` position == automation slot) applies to effect-param
// ARRAYS and does not reach this file — reordering a route array is a
// legitimate edit.

// MARK: - Source kinds

/// The four v1 modulation source kinds (§7.2). `sampleHold` is deliberately an
/// LFO *waveform*, not a fifth kind: it is closed-form (`hash(seed, cycleIndex)`),
/// so it needs nothing an LFO does not already have.
public enum ModulationSourceKind: String, Codable, Sendable, Equatable, CaseIterable {
    case lfo
    case stepSequencer
    case envelopeFollower
    case macro

    /// Default agent/UI-facing label for a freshly created source.
    public var defaultName: String {
        switch self {
        case .lfo: return "LFO"
        case .stepSequencer: return "Step"
        case .envelopeFollower: return "Follower"
        case .macro: return "Macro"
        }
    }

    /// Whether this source's output depends on render history. Exactly one
    /// kind does, it is declared rather than hidden, and `mod.addRoute` warns
    /// on it (`modulationFollowerNonDeterministic`).
    public var isStateful: Bool { self == .envelopeFollower }

    /// Whether this source's output is a function of transport position — the
    /// kinds that HOLD NEUTRAL while the transport is stopped (§7.8). `macro`
    /// and `envelopeFollower` stay live while stopped: one is a control, the
    /// other follows audio, and audio exists while monitoring.
    public var isPositionDependent: Bool {
        self == .lfo || self == .stepSequencer
    }

    /// Output polarity at defaults: `lfo`/`stepSequencer` are bipolar
    /// `[-1, 1]`, `macro`/`envelopeFollower` unipolar `[0, 1]`.
    public var isBipolarByDefault: Bool {
        self == .lfo || self == .stepSequencer
    }
}

/// LFO waveforms (§7.2). `sawUp` RISES then resets; `sawDown` falls — named
/// unambiguously on purpose, because "saw" alone is the single most commonly
/// mis-assumed direction in modulation UIs.
public enum LFOWaveform: String, Codable, Sendable, Equatable, CaseIterable {
    case sine
    case triangle
    case sawUp
    case sawDown
    case square
    case sampleHold

    /// Whether `edgeMs` applies — the discontinuous waveforms only.
    public var hasEdges: Bool { self == .square || self == .sampleHold }
    /// Whether `pulseWidth` applies.
    public var hasPulseWidth: Bool { self == .square }
    /// Whether `seed` applies.
    public var hasSeed: Bool { self == .sampleHold }

    /// Render-side waveform code — resolved on the main actor so the render
    /// thread never switches on a String.
    public var code: Int32 {
        switch self {
        case .sine: return 0
        case .triangle: return 1
        case .sawUp: return 2
        case .sawDown: return 3
        case .square: return 4
        case .sampleHold: return 5
        }
    }
}

/// Envelope-follower detector (§7.2).
public enum EnvelopeDetector: String, Codable, Sendable, Equatable, CaseIterable {
    case rms
    case peak
}

// MARK: - Per-kind parameter structs

/// `params` is a per-kind STRUCT, never a `[String: Double]` (§7.6). A
/// dictionary would put an unvalidated, undiscoverable surface on disk and on
/// the wire, which is the opposite of this milestone's thesis.
public struct LFOSourceParams: Codable, Sendable, Equatable {
    public static let rateRange: ClosedRange<Double> = 0.01...40
    public static let phaseRange: ClosedRange<Double> = 0...360
    public static let pulseWidthRange: ClosedRange<Double> = 0.01...0.99
    public static let edgeRange: ClosedRange<Double> = 0...100
    public static let seedRange: ClosedRange<Double> = 0...65_535

    public var waveform: LFOWaveform
    /// Free-running rate. Ignored when `syncDivision` is set — which v1 always
    /// refuses (§7.2.1), so today this is the only rate there is.
    public var rateHz: Double
    /// Tempo-synced rate. ⛔ v1 REFUSES every non-nil value with
    /// `modulationTempoSyncUnavailable`: resolving a note division to
    /// `samplesPerCycle` is m39-c's generalised resolver, and hand-rolling a
    /// second one here is the exact duplication m39-c exists to remove. The
    /// FIELD ships so the persistence shape never changes when m39-c lands.
    public var syncDivision: String?
    public var phaseDeg: Double
    public var pulseWidth: Double
    public var edgeMs: Double
    public var bipolar: Bool
    public var seed: Int

    public init(waveform: LFOWaveform = .sine, rateHz: Double = 1.0,
                syncDivision: String? = nil, phaseDeg: Double = 0,
                pulseWidth: Double = 0.5, edgeMs: Double = 2.0,
                bipolar: Bool = true, seed: Int = 0) {
        self.waveform = waveform
        self.rateHz = rateHz.clamped(to: Self.rateRange)
        self.syncDivision = syncDivision
        self.phaseDeg = phaseDeg.clamped(to: Self.phaseRange)
        self.pulseWidth = pulseWidth.clamped(to: Self.pulseWidthRange)
        self.edgeMs = edgeMs.clamped(to: Self.edgeRange)
        self.bipolar = bipolar
        self.seed = Int(Double(seed).clamped(to: Self.seedRange))
    }
}

public struct StepSequencerSourceParams: Codable, Sendable, Equatable {
    public static let stepValueRange: ClosedRange<Double> = -1...1
    public static let maxSteps = ModulationLimits.maxSteps
    public static let edgeRange: ClosedRange<Double> = 0...100
    public static let rateRange: ClosedRange<Double> = LFOSourceParams.rateRange

    /// Step values, each `-1...1`, length `1...64`. A sweep is any ramp.
    ///
    /// ⚠️⚠️ **POLARITY — READ THIS BEFORE WRITING A GATE PATTERN, BECAUSE THE
    /// OBVIOUS READING IS BACKWARDS.** A step value is an **offset**, not a
    /// level. `ModulationDepthLaw` adds `depth × step` to the target's
    /// normalised base, so a step of **0 leaves the target at its knob value**
    /// and a non-zero step **moves away from it**.
    ///
    /// On `.volume` that has a hard consequence. The fader's range tops out at
    /// +6.02 dB but full depth is 48 dB, so the only usable direction is DOWN
    /// and the idiom is a **negative depth** (§7.3). Under a negative depth:
    ///
    /// | step | offset | fader |
    /// |---|---|---|
    /// | `0` | none | **OPEN** — the knob value |
    /// | `1` | −48 dB × |depth| | **CLOSED** |
    ///
    /// So `[1, 0, 1, 0]` is **closed-open-closed-open**: it gates the DOWNBEAT
    /// silent. A gate that opens on the downbeat is `[0, 1, 0, 1]`. This
    /// default is the contract's frozen value and is kept; its annotation —
    /// which claimed `[1, 0, 1, 0]` *was* a trance gate — was measurably wrong
    /// and is corrected here and in the design document.
    ///
    /// On a target whose useful direction is UP (`cutoffHz`, `resonance`, an
    /// effect param) a POSITIVE depth reads the intuitive way round: 1 is more,
    /// 0 is the knob. The polarity is a property of the DEPTH'S SIGN, not of
    /// the step array — which is why it has to be stated rather than inferred.
    public var steps: [Double]
    /// ⛔ v1 REFUSES a non-nil value (`modulationTempoSyncUnavailable`) for the
    /// same reason as `LFOSourceParams.syncDivision`. Until m39-c lands the
    /// step rate is the free-running `rateHz` below, in steps per second.
    public var stepDivision: String?
    /// Free-running step rate in STEPS PER SECOND — the un-synced stand-in for
    /// `stepDivision` (§7.2.1's "ship `rateHz` only"). 4 steps/s is a 1/16 at
    /// 60 BPM; the tempo-relative spelling arrives with m39-c.
    public var rateHz: Double
    public var edgeMs: Double

    public init(steps: [Double] = [1, 0, 1, 0], stepDivision: String? = nil,
                rateHz: Double = 4.0, edgeMs: Double = 2.0) {
        self.steps = steps.isEmpty
            ? [1, 0, 1, 0]
            : Array(steps.prefix(Self.maxSteps)).map { $0.clamped(to: Self.stepValueRange) }
        self.stepDivision = stepDivision
        self.rateHz = rateHz.clamped(to: Self.rateRange)
        self.edgeMs = edgeMs.clamped(to: Self.edgeRange)
    }
}

public struct EnvelopeFollowerSourceParams: Codable, Sendable, Equatable {
    public static let attackRange: ClosedRange<Double> = 0.1...500
    public static let releaseRange: ClosedRange<Double> = 1...2000
    public static let floorRange: ClosedRange<Double> = -90...(-20)
    public static let gainRange: ClosedRange<Double> = -24...24
    /// v1 accepts only this key. A cross-strip key is `m39-e-D4` and is
    /// REFUSED (`crossStripKeyUnsupported`), never silently self-keyed.
    public static let selfSource = "self"

    public var source: String
    public var detector: EnvelopeDetector
    public var attackMs: Double
    public var releaseMs: Double
    public var floorDb: Double
    public var gainDb: Double

    public init(source: String = EnvelopeFollowerSourceParams.selfSource,
                detector: EnvelopeDetector = .rms, attackMs: Double = 10,
                releaseMs: Double = 100, floorDb: Double = -60, gainDb: Double = 0) {
        self.source = source
        self.detector = detector
        self.attackMs = attackMs.clamped(to: Self.attackRange)
        self.releaseMs = releaseMs.clamped(to: Self.releaseRange)
        self.floorDb = floorDb.clamped(to: Self.floorRange)
        self.gainDb = gainDb.clamped(to: Self.gainRange)
    }
}

public struct MacroSourceParams: Codable, Sendable, Equatable {
    public static let valueRange: ClosedRange<Double> = 0...1
    public var value: Double

    public init(value: Double = 0) {
        self.value = value.clamped(to: Self.valueRange)
    }
}

/// The per-kind params, tagged by kind. Custom `Codable` to a FLAT object so
/// the wire and persistence shape is `{kind:"lfo", waveform:"sine", …}` rather
/// than a nested discriminated union an agent has to guess at.
public enum ModulationSourceParams: Codable, Sendable, Equatable {
    case lfo(LFOSourceParams)
    case stepSequencer(StepSequencerSourceParams)
    case envelopeFollower(EnvelopeFollowerSourceParams)
    case macro(MacroSourceParams)

    public var kind: ModulationSourceKind {
        switch self {
        case .lfo: return .lfo
        case .stepSequencer: return .stepSequencer
        case .envelopeFollower: return .envelopeFollower
        case .macro: return .macro
        }
    }

    /// The default params for a kind.
    public static func defaults(for kind: ModulationSourceKind) -> ModulationSourceParams {
        switch kind {
        case .lfo: return .lfo(LFOSourceParams())
        case .stepSequencer: return .stepSequencer(StepSequencerSourceParams())
        case .envelopeFollower: return .envelopeFollower(EnvelopeFollowerSourceParams())
        case .macro: return .macro(MacroSourceParams())
        }
    }

    /// Whether this source's output is unipolar `[0, 1]` rather than bipolar.
    public var isUnipolar: Bool {
        switch self {
        case .lfo(let p): return !p.bipolar
        case .stepSequencer: return false
        case .envelopeFollower, .macro: return true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case waveform, rateHz, syncDivision, phaseDeg, pulseWidth, edgeMs, bipolar, seed
        case steps, stepDivision
        case source, detector, attackMs, releaseMs, floorDb, gainDb
        case value
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .lfo(let p):
            try c.encode(p.waveform, forKey: .waveform)
            try c.encode(p.rateHz, forKey: .rateHz)
            try c.encodeIfPresent(p.syncDivision, forKey: .syncDivision)
            try c.encode(p.phaseDeg, forKey: .phaseDeg)
            try c.encode(p.pulseWidth, forKey: .pulseWidth)
            try c.encode(p.edgeMs, forKey: .edgeMs)
            try c.encode(p.bipolar, forKey: .bipolar)
            try c.encode(p.seed, forKey: .seed)
        case .stepSequencer(let p):
            try c.encode(p.steps, forKey: .steps)
            try c.encodeIfPresent(p.stepDivision, forKey: .stepDivision)
            try c.encode(p.rateHz, forKey: .rateHz)
            try c.encode(p.edgeMs, forKey: .edgeMs)
        case .envelopeFollower(let p):
            try c.encode(p.source, forKey: .source)
            try c.encode(p.detector, forKey: .detector)
            try c.encode(p.attackMs, forKey: .attackMs)
            try c.encode(p.releaseMs, forKey: .releaseMs)
            try c.encode(p.floorDb, forKey: .floorDb)
            try c.encode(p.gainDb, forKey: .gainDb)
        case .macro(let p):
            try c.encode(p.value, forKey: .value)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(ModulationSourceKind.self, forKey: .kind) {
        case .lfo:
            self = .lfo(LFOSourceParams(
                waveform: try c.decodeIfPresent(LFOWaveform.self, forKey: .waveform) ?? .sine,
                rateHz: try c.decodeIfPresent(Double.self, forKey: .rateHz) ?? 1.0,
                syncDivision: try c.decodeIfPresent(String.self, forKey: .syncDivision),
                phaseDeg: try c.decodeIfPresent(Double.self, forKey: .phaseDeg) ?? 0,
                pulseWidth: try c.decodeIfPresent(Double.self, forKey: .pulseWidth) ?? 0.5,
                edgeMs: try c.decodeIfPresent(Double.self, forKey: .edgeMs) ?? 2.0,
                bipolar: try c.decodeIfPresent(Bool.self, forKey: .bipolar) ?? true,
                seed: try c.decodeIfPresent(Int.self, forKey: .seed) ?? 0))
        case .stepSequencer:
            self = .stepSequencer(StepSequencerSourceParams(
                steps: try c.decodeIfPresent([Double].self, forKey: .steps) ?? [1, 0, 1, 0],
                stepDivision: try c.decodeIfPresent(String.self, forKey: .stepDivision),
                rateHz: try c.decodeIfPresent(Double.self, forKey: .rateHz) ?? 4.0,
                edgeMs: try c.decodeIfPresent(Double.self, forKey: .edgeMs) ?? 2.0))
        case .envelopeFollower:
            self = .envelopeFollower(EnvelopeFollowerSourceParams(
                source: try c.decodeIfPresent(String.self, forKey: .source)
                    ?? EnvelopeFollowerSourceParams.selfSource,
                detector: try c.decodeIfPresent(EnvelopeDetector.self, forKey: .detector) ?? .rms,
                attackMs: try c.decodeIfPresent(Double.self, forKey: .attackMs) ?? 10,
                releaseMs: try c.decodeIfPresent(Double.self, forKey: .releaseMs) ?? 100,
                floorDb: try c.decodeIfPresent(Double.self, forKey: .floorDb) ?? -60,
                gainDb: try c.decodeIfPresent(Double.self, forKey: .gainDb) ?? 0))
        case .macro:
            self = .macro(MacroSourceParams(
                value: try c.decodeIfPresent(Double.self, forKey: .value) ?? 0))
        }
    }
}

// MARK: - Sources and routes

/// One modulation source on a strip (§7.6). Sources are FIRST-CLASS and
/// UUID-addressed rather than created inline on a route: an anonymous inline
/// source cannot be routed to a second target, and the single most common
/// modulation idiom — one LFO, three destinations — becomes inexpressible
/// (§10 H2's rejected amendment).
public struct ModulationSource: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: ModulationSourceKind
    public var name: String
    public var params: ModulationSourceParams

    public init(id: UUID = UUID(), kind: ModulationSourceKind,
                name: String? = nil, params: ModulationSourceParams? = nil) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.defaultName
        self.params = params ?? .defaults(for: kind)
    }
}

/// One route from a source to a target (§7.6).
///
/// ⭐ `target` is THE SAME `AutomationTarget` automation uses. That is not a
/// convenience — it is the mechanism that makes m39-b and m39-e agree BY
/// CONSTRUCTION (§4). There is no modulation target type, so the two surfaces
/// cannot drift apart.
public struct ModulationRoute: Codable, Sendable, Equatable, Identifiable {
    public static let depthRange: ClosedRange<Double> = -1...1

    public var id: UUID
    public var sourceID: UUID
    public var target: AutomationTarget
    /// Unitless `[-1, 1]`; what full depth MEANS is declared per target class
    /// by the target's `ParamCurve` (§7.3).
    public var depth: Double
    public var enabled: Bool

    public init(id: UUID = UUID(), sourceID: UUID, target: AutomationTarget,
                depth: Double, enabled: Bool = true) {
        self.id = id
        self.sourceID = sourceID
        self.target = target
        self.depth = depth.clamped(to: Self.depthRange)
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceID = "sourceId", target, depth, enabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            sourceID: try c.decode(UUID.self, forKey: .sourceID),
            target: try c.decode(AutomationTarget.self, forKey: .target),
            depth: try c.decode(Double.self, forKey: .depth),
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true)
    }
}

// MARK: - Verdicts, limits and constants

/// Whether a target may be modulated at all, and how honestly (§6.1).
///
/// **Frozen invariant:** modulation refuses a SUPERSET of what automation
/// refuses. Everything automation already refuses (`.audioUnit` params,
/// `delay.sync`, `delay.division`) modulation also refuses; modulation
/// additionally refuses DISCRETE params, because an LFO cannot meaningfully
/// drive a boolean or a topology switch. Modulation never permits something
/// automation forbids — a reviewer can check that mechanically, and a test does.
public enum Modulatable: String, Codable, Sendable, Equatable, CaseIterable {
    /// Quantum-rate stores are smoothed, or the parameter is inherently smooth.
    case yes
    /// Permitted; `mod.addRoute` returns a warning naming the artefact.
    case warned
    /// `mod.addRoute` throws `modulationTargetUnsupported`.
    case refused
}

/// Preallocation bounds, frozen (§7.4). Every one of these is a render-thread
/// preallocation bound, not a taste judgement.
public enum ModulationLimits {
    /// Sources per strip — matches the macro slot array, one atomic word each.
    public static let maxSources = 16
    /// Routes per strip — matches `AutomationSchedule.maxEffectParamTracks`
    /// and the renderer's preallocated cursor array. ⚠️ The two caps SHARE ONE
    /// BUDGET: a modulated-but-unautomated effect param costs a synthetic
    /// lane, so `lanes + modulatedEffectParams <= 64` on a strip.
    public static let maxRoutes = 64
    /// Steps per `stepSequencer` — one cache line of Floats per source, fixed.
    public static let maxSteps = 64
    /// Macro slots per strip, preallocated as `daw_atomic_u32` at publish.
    public static let maxMacros = 16
}

/// Named constants the depth law reads (§7.3). Named rather than buried at a
/// call site SO THEY CAN BE ARGUED WITH — the `EffortField.maxAcceptableImageRatio`
/// precedent.
public enum ModulationDepth {
    /// What full depth means on `.volume`. 48 dB is an ESTIMATE: at 48 dB,
    /// depth 0.125 is a ±6 dB tremolo, which is the amount most people mean by
    /// "a tremolo".
    public static let volumeFullScaleDb: Double = 48
    /// The modulation evaluation stride for paths that do not evaluate per
    /// sample (§9): 32 frames is 1 500 Hz at 48 kHz, whose 0.25-image-ratio
    /// ceiling is 300 Hz — six times above the top of the musical modulation
    /// band, so nothing authorable warns.
    public static let evaluationStrideFrames = 32
}

/// The rate at which a delivery path samples a modulation signal (§8.1). Used
/// with `EffortField.modulationImageRatio` / `modulationRateCeilingHz`, which
/// are already closed-form and measured — NOTHING HERE REBUILDS THEM.
public enum ModulationPath: String, Codable, Sendable, Equatable, CaseIterable {
    /// T1 — volume, pan, and our own instruments. The consuming loop is
    /// already per-sample.
    case perSample
    /// T2 — built-in effect params: the consumer re-derives once per `process()`.
    case perQuantum
    /// T3 — a hosted AU samples its input once per render call. REFUSED in v1.
    case hostedRenderCall
}

public extension ModulationPath {
    /// The rate at which this path samples a modulation signal.
    /// - `perSample`: the evaluation stride (32 frames → 1 500 Hz at 48 kHz).
    /// - `perQuantum`: one per render block (512 frames → 93.75 Hz).
    /// - `hostedRenderCall`: identical arithmetic to `perQuantum` today; it is
    ///   split out because the two diverge the moment a host renders an AU on
    ///   a different cadence, and because it is REFUSED rather than warned.
    func samplingHz(sampleRate: Double, blockFrames: Int,
                    stride: Int = ModulationDepth.evaluationStrideFrames) -> Double {
        guard sampleRate > 0 else { return 0 }
        switch self {
        case .perSample:
            return stride > 0 ? sampleRate / Double(stride) : sampleRate
        case .perQuantum, .hostedRenderCall:
            return blockFrames > 0 ? sampleRate / Double(blockFrames) : sampleRate
        }
    }
}

// MARK: - The depth law (§7.3)

/// ```
/// b     = normalise(base, target)                    // → [0, 1]
/// sum   = Σ over enabled routes of (depth_i · s_i)   // s_i is the source output
/// n     = clamp(b + sum, 0, 1)
/// value = denormalise(n, target)
/// ```
/// `normalise` / `denormalise` are exactly `ParamCurve.fraction(forValue:in:)` /
/// `value(forFraction:in:)` — the inverse pair m39-a declared for this purpose.
///
/// ⚠️ `base` is whatever is IN CONTROL of the parameter: the automation lane's
/// value if a lane is active at that position, otherwise the knob value.
/// Modulation OFFSETS whatever is in control; it never competes with it.
public enum ModulationDepthLaw {
    /// A spec-ranged target (effect param, instrument param).
    /// Returns `base` unchanged when `sum` is exactly zero — the shortcut that
    /// lets a zero-depth route be bit-identical to no route at all.
    @inline(__always)
    public static func value(base: Double, sum: Double,
                             range: ClosedRange<Double>, curve: ParamCurve) -> Double {
        guard sum != 0, sum.isFinite, base.isFinite else { return base }
        let b = curve.fraction(forValue: base, in: range)
        let n = (b + sum).clamped(to: 0...1)
        return curve.value(forFraction: n, in: range)
    }

    /// `.volume`: the domain is DECIBELS, not the raw 0…2 gain range, so full
    /// depth is ±`volumeFullScaleDb` and a depth means the same thing at any
    /// fader position.
    ///
    /// ⚠️⚠️ **THE POLARITY CONVENTION, STATED BECAUSE IT CANNOT BE INFERRED.**
    /// A source output is an OFFSET from the base, scaled by `depth`. `sum == 0`
    /// is "leave the fader alone". Since the fader's headroom is +6.02 dB and
    /// full depth is 48 dB, the only usable direction on `.volume` is DOWN, so
    /// gates and tremolos take a NEGATIVE depth — and under a negative depth a
    /// source's HIGH value is the CUT:
    ///
    ///  · step/square HIGH (1) → closed · step/square LOW (0) → open (the knob)
    ///  · a square's `pulseWidth` is therefore the **CLOSED** fraction of the
    ///    cycle on `.volume`, not the open one.
    ///
    /// No choice of sign makes `1` mean "open at unity", because "open" IS the
    /// base, i.e. zero offset. Flipping the depth sign only turns the cut into
    /// a boost the fader cannot hold.
    ///
    /// ⛔ Volume modulation is ASYMMETRIC AT THE TOP and the contract says so:
    /// `Track.volumeRange` tops out at +6.02 dB, so a bipolar source at a unity
    /// base clips its upper half while its lower half keeps going — a tremolo
    /// that is not a tremolo. Tremolo and gate patterns are authored
    /// `bipolar: false` with a NEGATIVE depth (attenuation-only), which is what
    /// the studio idiom means anyway.
    @inline(__always)
    public static func volumeGain(base: Double, sum: Double) -> Double {
        guard sum != 0, sum.isFinite, base.isFinite else { return base }
        let scaled = base * pow(10, sum * ModulationDepth.volumeFullScaleDb / 20)
        return scaled.clamped(to: Track.volumeRange)
    }

    /// `.pan`: full depth is ±1.0, hard left to hard right.
    @inline(__always)
    public static func pan(base: Double, sum: Double) -> Double {
        guard sum != 0, sum.isFinite, base.isFinite else { return base }
        return (base + sum).clamped(to: Track.panRange)
    }

    /// Whether a BIPOLAR source on `.volume` would exceed the +6.02 dB ceiling
    /// at `base` and full `depth` — the `modulationVolumeCeiling` predicate.
    public static func volumeWouldExceedCeiling(base: Double, depth: Double) -> Bool {
        let peak = base * pow(10, abs(depth) * ModulationDepth.volumeFullScaleDb / 20)
        return peak > Track.volumeRange.upperBound
    }
}

// MARK: - The closed forms (§3.2) — ONE HOME, read by the control plane and the render thread

/// Every position-dependent source, as a pure function of the transport sample
/// position. **No accumulator, no phase register, no filter state.**
///
/// ⚠️ RENDER-THREAD CONTRACT: every function here is pure scalar arithmetic
/// plus libm (`sin`, `cos`, `floor`) and an integer hash. No allocation, no
/// locks, no ObjC, no `Array`. The step-sequencer entry point takes an
/// `UnsafeBufferPointer<Float>` precisely so the render side never touches
/// Swift `Array` machinery; the `[Double]` overload is for the control plane.
public enum ModulationMath {
    /// Normalised phase in `[0, 1)` at sample position `p`.
    /// `cyclesPerSample` is `rateHz / sampleRate`; `phaseOffset` is `[0, 1)`.
    ///
    /// ⭐ This is the whole no-accumulator law in one line: the phase is
    /// computed FROM the position, never advanced from the last one. Render
    /// `[0, 10 s)` in one pass or as two halves with a seek between and the
    /// value at every sample is identical — pinned by test.
    @inline(__always)
    public static func phase(atSample p: Int64, cyclesPerSample: Double,
                             phaseOffset: Double) -> Double {
        let raw = Double(p) * cyclesPerSample + phaseOffset
        let wrapped = raw - floor(raw)
        // `floor` of a huge magnitude can round to the value itself; clamp
        // defensively so a phase can never leave [0, 1).
        return wrapped.isFinite ? min(max(wrapped, 0), 0.999_999_999_999) : 0
    }

    /// Raised-cosine blend from `a` to `b` across `x` ∈ `[0, 1]` — the ONLY
    /// smoothing this design permits, because it is a SHAPE and not a filter
    /// state (§3.2 point 5).
    @inline(__always)
    public static func raisedCosine(from a: Double, to b: Double, position x: Double) -> Double {
        if x <= 0 { return a }
        if x >= 1 { return b }
        return a + (b - a) * 0.5 * (1 - cos(.pi * x))
    }

    /// Deterministic integer hash → `[0, 1)`. splitmix64's finaliser: no state,
    /// no RNG object, reproducible across runs, processes and machines, which
    /// is what makes `sampleHold` seek-exact.
    @inline(__always)
    public static func hash01(seed: UInt32, index: Int64) -> Double {
        var z = UInt64(bitPattern: index) &+ (UInt64(seed) &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// The LFO, bipolar `[-1, 1]`, at normalised phase `t`.
    /// `edgeFraction` is the raised-cosine edge width in PHASE units (the
    /// caller converts `edgeMs` against the rate), applied only to the
    /// discontinuous waveforms.
    @inline(__always)
    public static func lfo(waveformCode: Int32, phase t: Double, pulseWidth: Double,
                           edgeFraction: Double, seed: UInt32, cycleIndex: Int64) -> Double {
        switch waveformCode {
        case 0:  // sine
            return sin(2 * .pi * t)
        case 1:  // triangle — starts at 0 RISING, so it shares the sine's phase
            if t < 0.25 { return 4 * t }
            if t < 0.75 { return 2 - 4 * t }
            return 4 * t - 4
        case 2:  // sawUp — rises, then resets
            return 2 * t - 1
        case 3:  // sawDown
            return 1 - 2 * t
        case 4:  // square, with raised-cosine edges at t = pulseWidth and t = 0
            return square(phase: t, pulseWidth: pulseWidth, edgeFraction: edgeFraction)
        default:  // 5 = sampleHold
            return sampleHold(phase: t, edgeFraction: edgeFraction,
                              seed: seed, cycleIndex: cycleIndex)
        }
    }

    /// Square with closed-form edges. The half-width `h` is centred on each
    /// transition, so the edge's MIDPOINT lands exactly on the mathematical
    /// edge — which is what makes a softened gate still sit on the beat.
    ///
    /// ⚠️ `pulseWidth` is the fraction of the cycle spent at the HIGH value.
    /// On `.volume`, where the idiomatic depth is negative, HIGH is the CUT —
    /// so `pulseWidth` is the **closed** fraction there. See
    /// `ModulationDepthLaw.volumeGain`'s polarity note.
    @inline(__always)
    public static func square(phase t: Double, pulseWidth: Double,
                              edgeFraction: Double) -> Double {
        let h = min(max(edgeFraction, 0) * 0.5, min(pulseWidth, 1 - pulseWidth) * 0.49)
        let high = 1.0, low = -1.0
        if h <= 0 { return t < pulseWidth ? high : low }
        if t < h { return raisedCosine(from: low, to: high, position: (t + h) / (2 * h)) }
        if t > 1 - h { return raisedCosine(from: low, to: high, position: (t - (1 - h)) / (2 * h)) }
        if abs(t - pulseWidth) < h {
            return raisedCosine(from: high, to: low,
                                position: (t - (pulseWidth - h)) / (2 * h))
        }
        return t < pulseWidth ? high : low
    }

    /// Sample-and-hold: one hashed value per cycle, with raised-cosine edges
    /// straddling the cycle boundary. Closed-form in `cycleIndex`, so a seek
    /// lands on exactly the value a full playthrough would have.
    @inline(__always)
    public static func sampleHold(phase t: Double, edgeFraction: Double,
                                  seed: UInt32, cycleIndex: Int64) -> Double {
        let current = hash01(seed: seed, index: cycleIndex) * 2 - 1
        let h = min(max(edgeFraction, 0) * 0.5, 0.49)
        if h <= 0 { return current }
        if t < h {
            let previous = hash01(seed: seed, index: cycleIndex &- 1) * 2 - 1
            return raisedCosine(from: previous, to: current, position: (t + h) / (2 * h))
        }
        if t > 1 - h {
            let next = hash01(seed: seed, index: cycleIndex &+ 1) * 2 - 1
            return raisedCosine(from: current, to: next,
                                position: (t - (1 - h)) / (2 * h))
        }
        return current
    }

    /// The step sequencer, bipolar `[-1, 1]`, RENDER-SIDE entry point.
    /// `stepPosition` is `p / samplesPerStep` — a Double so the fractional part
    /// inside the step is free.
    @inline(__always)
    public static func stepSequencer(stepPosition: Double,
                                     steps: UnsafePointer<Float>, stepCount: Int,
                                     edgeFraction: Double) -> Double {
        guard stepCount > 0 else { return 0 }
        let floorPosition = floor(stepPosition)
        let frac = stepPosition - floorPosition
        let index = wrapIndex(Int64(floorPosition), count: stepCount)
        let current = Double(steps[index])
        let h = min(max(edgeFraction, 0) * 0.5, 0.49)
        if h <= 0 { return current }
        if frac < h {
            let previous = Double(steps[wrapIndex(Int64(floorPosition) &- 1, count: stepCount)])
            return raisedCosine(from: previous, to: current, position: (frac + h) / (2 * h))
        }
        if frac > 1 - h {
            let next = Double(steps[wrapIndex(Int64(floorPosition) &+ 1, count: stepCount)])
            return raisedCosine(from: current, to: next, position: (frac - (1 - h)) / (2 * h))
        }
        return current
    }

    /// Control-plane overload — same function, `Array` storage. Used by
    /// `mod.describe`, never by the render thread.
    public static func stepSequencer(stepPosition: Double, steps: [Double],
                                     edgeFraction: Double) -> Double {
        guard !steps.isEmpty else { return 0 }
        let floats = steps.map { Float($0) }
        return floats.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return stepSequencer(stepPosition: stepPosition, steps: base,
                                 stepCount: buffer.count, edgeFraction: edgeFraction)
        }
    }

    /// Positive modulo for a possibly-negative step index (a pre-anchor
    /// position is legal — automation breakpoints keep negative times too).
    @inline(__always)
    public static func wrapIndex(_ index: Int64, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let m = index % Int64(count)
        return Int(m < 0 ? m + Int64(count) : m)
    }

    /// Maps a bipolar `[-1, 1]` source output to `[0, 1]` when the source is
    /// declared unipolar (§7.2's `bipolar: false`).
    @inline(__always)
    public static func toUnipolar(_ v: Double) -> Double { (v + 1) * 0.5 }

    /// One-pole coefficient for a time constant in milliseconds — the
    /// envelope follower's ONLY stateful arithmetic, kept here so the detector
    /// in the render-side stage and any control-plane preview agree.
    @inline(__always)
    public static func onePoleCoefficient(timeMs: Double, sampleRate: Double) -> Double {
        guard timeMs > 0, sampleRate > 0 else { return 0 }
        return exp(-1.0 / (timeMs * 0.001 * sampleRate))
    }

    /// Maps a detector level (linear amplitude) to the follower's `[0, 1]`
    /// output against its `floorDb` / `gainDb`.
    @inline(__always)
    public static func followerOutput(level: Double, floorDb: Double, gainLinear: Double) -> Double {
        let scaled = level * gainLinear
        guard scaled > 0 else { return 0 }
        let db = 20 * log10(scaled)
        guard floorDb < 0 else { return db >= 0 ? 1 : 0 }
        return ((db - floorDb) / (0 - floorDb)).clamped(to: 0...1)
    }

    /// The full closed-form evaluation for a POSITION-DEPENDENT source, in the
    /// source's own declared polarity. The control plane calls this for
    /// `mod.describe`'s `effective` block; the render side calls the same
    /// pieces through `ModulationEvaluator`.
    ///
    /// Returns `nil` for `envelopeFollower` — the one source that is not a
    /// function of position, declared rather than faked.
    public static func value(of params: ModulationSourceParams, atSample p: Int64,
                             sampleRate: Double) -> Double? {
        switch params {
        case .macro(let macro):
            return macro.value
        case .envelopeFollower:
            return nil
        case .lfo(let spec):
            let cyclesPerSample = sampleRate > 0 ? spec.rateHz / sampleRate : 0
            let offset = spec.phaseDeg / 360
            let raw = Double(p) * cyclesPerSample + offset
            let t = phase(atSample: p, cyclesPerSample: cyclesPerSample, phaseOffset: offset)
            let edgeFraction = spec.waveform.hasEdges
                ? edgeFractionOfCycle(edgeMs: spec.edgeMs, cyclesPerSample: cyclesPerSample,
                                      sampleRate: sampleRate)
                : 0
            let v = lfo(waveformCode: spec.waveform.code, phase: t,
                        pulseWidth: spec.pulseWidth, edgeFraction: edgeFraction,
                        seed: UInt32(truncatingIfNeeded: spec.seed),
                        cycleIndex: Int64(floor(raw)))
            return spec.bipolar ? v : toUnipolar(v)
        case .stepSequencer(let step):
            guard sampleRate > 0, step.rateHz > 0, !step.steps.isEmpty else { return 0 }
            let samplesPerStep = sampleRate / step.rateHz
            let stepPosition = Double(p) / samplesPerStep
            let edgeFraction = step.edgeMs * 0.001 * sampleRate / samplesPerStep
            return stepSequencer(stepPosition: stepPosition, steps: step.steps,
                                 edgeFraction: edgeFraction)
        }
    }

    /// `edgeMs` expressed as a fraction of one LFO cycle.
    @inline(__always)
    public static func edgeFractionOfCycle(edgeMs: Double, cyclesPerSample: Double,
                                           sampleRate: Double) -> Double {
        guard sampleRate > 0, cyclesPerSample > 0 else { return 0 }
        let samplesPerCycle = 1.0 / cyclesPerSample
        return min(edgeMs * 0.001 * sampleRate / samplesPerCycle, 0.98)
    }
}

// MARK: - Errors (§7.4) and warnings (§7.5)

/// Why a target cannot be modulated. An agent BRANCHES on these, so the set is
/// part of the frozen contract.
public enum ModulationTargetUnsupportedReason: String, Codable, Sendable, CaseIterable {
    /// Boolean, enum, or `.rounded()` param — an LFO cannot drive it meaningfully.
    case discrete
    /// `.audioUnit` effect param; matches automation, which drops these at
    /// schedule-build resolution.
    case hostedAudioUnit
    /// `.soundBank` / `.audioUnit` instrument — the message carries the image ratio.
    case hostedInstrument
    /// Resolved off the render thread (`delay.sync`, `delay.division`).
    case controlPlaneOnly
    /// The name is not in the kind's spec table; the message lists valid names.
    case unknownParam
    /// `.instrumentParam` on a track with no instrument.
    case noInstrument
    /// `envelopeFollower` with a `source` other than `"self"` (`m39-e-D4`).
    case crossStripKeyUnsupported
    /// `.sendLevel` — refused at the store today and with no render-side send
    /// stage to compose into.
    case sendLevelUnsupported
}

/// The refusal taxonomy (§7.4). Every message names the legal alternatives —
/// the `unknownEffectParam` precedent.
public enum ModulationError: Error, LocalizedError, Equatable {
    case modulationSourceNotFound(id: String, existing: [String])
    case modulationRouteNotFound(id: String, existing: [String])
    case unknownModulationSourceKind(kind: String)
    case unknownModulationParam(key: String, kind: String, valid: [String])
    case modulationSourceKindMismatch(verb: String, actualKind: String)
    case modulationTargetUnsupported(target: String, reason: ModulationTargetUnsupportedReason,
                                     detail: String)
    case modulationLimitExceeded(cap: String, limit: Int, current: Int, detail: String)
    case modulationStepsInvalid(detail: String)
    case modulationTempoSyncUnavailable(field: String)

    public var errorDescription: String? {
        switch self {
        case .modulationSourceNotFound(let id, let existing):
            return "no modulation source '\(id)' on this strip — "
                + (existing.isEmpty ? "it has none yet (create one with mod.addSource)"
                                    : "existing: \(existing.joined(separator: ", "))")
        case .modulationRouteNotFound(let id, let existing):
            return "no modulation route '\(id)' on this strip — "
                + (existing.isEmpty ? "it has none yet (create one with mod.addRoute)"
                                    : "existing: \(existing.joined(separator: ", "))")
        case .unknownModulationSourceKind(let kind):
            return "unknown modulation source kind '\(kind)' — valid: "
                + ModulationSourceKind.allCases.map(\.rawValue).joined(separator: ", ")
        case .unknownModulationParam(let key, let kind, let valid):
            return "unknown modulation param '\(key)' for kind '\(kind)' — valid: "
                + valid.joined(separator: ", ")
        case .modulationSourceKindMismatch(let verb, let actualKind):
            return "\(verb) applies to a 'macro' source; this one is '\(actualKind)'"
        case .modulationTargetUnsupported(let target, let reason, let detail):
            return "cannot modulate \(target) (\(reason.rawValue)): \(detail)"
        case .modulationLimitExceeded(let cap, let limit, let current, let detail):
            return "modulation \(cap) cap reached: \(current) of \(limit). \(detail)"
        case .modulationStepsInvalid(let detail):
            return "step sequencer steps are invalid: \(detail)"
        case .modulationTempoSyncUnavailable(let field):
            return "'\(field)' needs tempo-synced rates, which are not built yet "
                + "(m39-c is the prerequisite: it generalises the one tempo-sync "
                + "resolver so a second one is never hand-rolled). Use 'rateHz' "
                + "for a free-running rate."
        }
    }
}

/// Warning codes (§7.5). Warnings NEVER block; they ride the response's
/// `warnings` array exactly as m27-c's clamp warnings do, and they are
/// repeated in `mod.describe` so they stay visible after creation.
public enum ModulationWarning {
    public static let depthClamped = "modulationDepthClamped"
    public static let paramClamped = "modulationParamClamped"
    public static let rateAlias = "modulationRateAlias"
    public static let targetSteps = "modulationTargetSteps"
    public static let paramIgnored = "modulationParamIgnored"
    public static let rateAndSyncBothGiven = "modulationRateAndSyncBothGiven"
    public static let volumeCeiling = "modulationVolumeCeiling"
    public static let followerNonDeterministic = "modulationFollowerNonDeterministic"
    public static let tempoRampUnfollowed = "modulationTempoRampUnfollowed"
}

// MARK: - Which strip (§7.1 — `trackId` accepts a UUID or the literal "master")

/// Which strip a modulation verb addresses. The master strip carries the same
/// two arrays a track does, reached by `trackId: "master"` through the
/// existing `parseFXTarget()`.
public enum ModulationStrip: Equatable, Sendable {
    case track(UUID)
    case master
}

// MARK: - Param parsing — ONE HOME for validation, clamping and refusal

/// A decoded wire value, so `DAWCore` can validate `params` without knowing
/// anything about JSON. The control plane converts; the rules live here, next
/// to the ranges they enforce.
public enum ModulationParamValue: Equatable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case numbers([Double])
    case null
}

public extension ModulationSourceParams {
    /// Applies `values` over `self` (or over the kind's defaults), clamping and
    /// WARNING rather than rejecting out-of-range scalars — the `fx.setParam` /
    /// m27-c precedent. Rejects only what cannot be honoured at all: an unknown
    /// key, a wrong-typed value, invalid steps, and tempo-synced rates (§7.2.1).
    ///
    /// ⛔ **`syncDivision` / `stepDivision` REFUSE in v1.** Resolving a note
    /// division to `samplesPerCycle` is m39-c's generalised resolver, and
    /// copying `DelayTempoSync`'s `guard effect.kind == .delay` shape into a
    /// second place is the exact duplication m39-c exists to remove. The fields
    /// persist so the shape never changes when m39-c lands; only the VALUE is
    /// refused, and the refusal names m39-c as the prerequisite.
    static func apply(_ values: [String: ModulationParamValue],
                      to existing: ModulationSourceParams)
        throws -> (params: ModulationSourceParams, warnings: [String]) {
        var warnings: [String] = []

        func number(_ key: String, _ fallback: Double,
                    _ range: ClosedRange<Double>) throws -> Double {
            guard let value = values[key] else { return fallback }
            guard case .number(let raw) = value, raw.isFinite else {
                throw ModulationError.unknownModulationParam(
                    key: key, kind: existing.kind.rawValue,
                    valid: ["\(key) must be a finite number"])
            }
            let stored = raw.clamped(to: range)
            if stored != raw,
               let sentence = ClampNotice.sentence(control: key, requested: raw,
                                                   stored: stored, range: range) {
                warnings.append("\(ModulationWarning.paramClamped): \(sentence)")
            }
            return stored
        }
        func bool(_ key: String, _ fallback: Bool) throws -> Bool {
            guard let value = values[key] else { return fallback }
            guard case .bool(let raw) = value else {
                throw ModulationError.unknownModulationParam(
                    key: key, kind: existing.kind.rawValue,
                    valid: ["\(key) must be true or false"])
            }
            return raw
        }
        func text(_ key: String) throws -> String? {
            guard let value = values[key] else { return nil }
            if case .null = value { return nil }
            guard case .string(let raw) = value else {
                throw ModulationError.unknownModulationParam(
                    key: key, kind: existing.kind.rawValue,
                    valid: ["\(key) must be a string"])
            }
            return raw
        }
        /// The tempo-sync gate, in one place so both fields refuse identically.
        func refuseSync(_ key: String) throws {
            guard let value = values[key] else { return }
            if case .null = value { return }
            throw ModulationError.modulationTempoSyncUnavailable(field: key)
        }

        switch existing {
        case .lfo(let current):
            let valid = ["waveform", "rateHz", "syncDivision", "phaseDeg",
                         "pulseWidth", "edgeMs", "bipolar", "seed"]
            try reject(values, valid: valid, kind: "lfo")
            try refuseSync("syncDivision")
            var waveform = current.waveform
            if let raw = try text("waveform") {
                guard let parsed = LFOWaveform(rawValue: raw) else {
                    throw ModulationError.unknownModulationParam(
                        key: "waveform", kind: "lfo",
                        valid: LFOWaveform.allCases.map(\.rawValue))
                }
                waveform = parsed
            }
            let updated = LFOSourceParams(
                waveform: waveform,
                rateHz: try number("rateHz", current.rateHz, LFOSourceParams.rateRange),
                syncDivision: nil,
                phaseDeg: try number("phaseDeg", current.phaseDeg, LFOSourceParams.phaseRange),
                pulseWidth: try number("pulseWidth", current.pulseWidth,
                                       LFOSourceParams.pulseWidthRange),
                edgeMs: try number("edgeMs", current.edgeMs, LFOSourceParams.edgeRange),
                bipolar: try bool("bipolar", current.bipolar),
                seed: Int(try number("seed", Double(current.seed), LFOSourceParams.seedRange)))
            // §7.5 `modulationParamIgnored` — a param that would apply under a
            // different waveform is stored, not dropped, and the caller is told
            // when it will take effect rather than left to wonder.
            if values["pulseWidth"] != nil, !waveform.hasPulseWidth {
                warnings.append("\(ModulationWarning.paramIgnored): 'pulseWidth' applies only "
                    + "to the 'square' waveform; this source is '\(waveform.rawValue)'. "
                    + "The value is stored and takes effect if you switch to square.")
            }
            if values["edgeMs"] != nil, !waveform.hasEdges {
                warnings.append("\(ModulationWarning.paramIgnored): 'edgeMs' softens the jumps "
                    + "of 'square' and 'sampleHold'; '\(waveform.rawValue)' is already "
                    + "continuous, so it has no edges to soften.")
            }
            if values["seed"] != nil, !waveform.hasSeed {
                warnings.append("\(ModulationWarning.paramIgnored): 'seed' applies only to the "
                    + "'sampleHold' waveform; this source is '\(waveform.rawValue)'.")
            }
            return (.lfo(updated), warnings)

        case .stepSequencer(let current):
            try reject(values, valid: ["steps", "stepDivision", "rateHz", "edgeMs"],
                       kind: "stepSequencer")
            try refuseSync("stepDivision")
            var steps = current.steps
            if let value = values["steps"] {
                guard case .numbers(let raw) = value else {
                    throw ModulationError.modulationStepsInvalid(
                        detail: "'steps' must be an array of numbers between -1 and 1")
                }
                guard !raw.isEmpty else {
                    throw ModulationError.modulationStepsInvalid(
                        detail: "'steps' is empty; give it 1 to \(ModulationLimits.maxSteps) values")
                }
                guard raw.count <= ModulationLimits.maxSteps else {
                    throw ModulationError.modulationStepsInvalid(
                        detail: "'steps' has \(raw.count) values; the cap is "
                            + "\(ModulationLimits.maxSteps)")
                }
                if let index = raw.firstIndex(where: { !$0.isFinite }) {
                    throw ModulationError.modulationStepsInvalid(
                        detail: "'steps[\(index)]' is not a finite number")
                }
                let clamped = raw.map { $0.clamped(to: StepSequencerSourceParams.stepValueRange) }
                if clamped != raw {
                    warnings.append("\(ModulationWarning.paramClamped): one or more 'steps' "
                        + "values were outside -1…1 and were clamped.")
                }
                steps = clamped
            }
            let updated = StepSequencerSourceParams(
                steps: steps, stepDivision: nil,
                rateHz: try number("rateHz", current.rateHz,
                                   StepSequencerSourceParams.rateRange),
                edgeMs: try number("edgeMs", current.edgeMs,
                                   StepSequencerSourceParams.edgeRange))
            return (.stepSequencer(updated), warnings)

        case .envelopeFollower(let current):
            try reject(values, valid: ["source", "detector", "attackMs", "releaseMs",
                                       "floorDb", "gainDb"], kind: "envelopeFollower")
            if let raw = try text("source"), raw != EnvelopeFollowerSourceParams.selfSource {
                throw ModulationError.modulationTargetUnsupported(
                    target: "envelopeFollower.source", reason: .crossStripKeyUnsupported,
                    detail: "v1 follows this strip's own audio only ('self'). Keying a "
                        + "follower off another strip is a filed deferral (m39-e-D4); it is "
                        + "refused rather than silently self-keyed, so a sidechain you "
                        + "thought you built cannot go unnoticed.")
            }
            var detector = current.detector
            if let raw = try text("detector") {
                guard let parsed = EnvelopeDetector(rawValue: raw) else {
                    throw ModulationError.unknownModulationParam(
                        key: "detector", kind: "envelopeFollower",
                        valid: EnvelopeDetector.allCases.map(\.rawValue))
                }
                detector = parsed
            }
            let updated = EnvelopeFollowerSourceParams(
                source: EnvelopeFollowerSourceParams.selfSource, detector: detector,
                attackMs: try number("attackMs", current.attackMs,
                                     EnvelopeFollowerSourceParams.attackRange),
                releaseMs: try number("releaseMs", current.releaseMs,
                                      EnvelopeFollowerSourceParams.releaseRange),
                floorDb: try number("floorDb", current.floorDb,
                                    EnvelopeFollowerSourceParams.floorRange),
                gainDb: try number("gainDb", current.gainDb,
                                   EnvelopeFollowerSourceParams.gainRange))
            return (.envelopeFollower(updated), warnings)

        case .macro(let current):
            try reject(values, valid: ["value"], kind: "macro")
            let updated = MacroSourceParams(
                value: try number("value", current.value, MacroSourceParams.valueRange))
            return (.macro(updated), warnings)
        }
    }

    /// Unknown-key rejection, the `rejectUnknownKeys` discipline applied to a
    /// nested object: a typo in `params` must be loud, not ignored.
    private static func reject(_ values: [String: ModulationParamValue],
                               valid: [String], kind: String) throws {
        for key in values.keys.sorted() where !valid.contains(key) {
            throw ModulationError.unknownModulationParam(key: key, kind: kind, valid: valid)
        }
    }
}
