import Foundation

/// Reference-track domain (m22-g, design-m22g-reference-tracks §3-§5).
///
/// A project holds at most ONE reference slot (`ProjectStore.reference`) — a
/// finished song the user mixes against. It is deliberately NOT a `Track`:
/// every offline path (mixdown / bounce / stems) walks `tracks`, so the
/// reference is excluded from renders BY CONSTRUCTION, with no filter to get
/// wrong (design D1).

/// One-time whole-file analysis of the reference (design D2): loudness via
/// the SAME `Loudness.Stream` math as `Loudness.measure` (the m22-c
/// fp-identical family), the shared 24-band mean-power-density spectrum
/// (`MasterMixAnalyzer.bandEdges` geometry), and whole-file stereo aggregates
/// (`StereoImage.measure`). Persisted in the slot, `analyzerVersion`-tagged.
public struct ReferenceAnalysis: Codable, Sendable, Equatable {
    /// nil = gated-silent program (JSON has no −inf).
    public var integratedLufs: Double?
    public var maxMomentaryLufs: Double?
    public var maxShortTermLufs: Double?
    /// 4× oversampled, BS.1770 Annex 2 (the Loudness home). nil = digital silence.
    public var truePeakDbtp: Double?
    /// EBU 3342. nil = not enough gated evidence.
    public var loudnessRangeLu: Double?
    /// Exactly `MasterAnalysisSnapshot.bandCount` (24) mean power-DENSITY
    /// values in dB, floor −80, over `MasterMixAnalyzer.bandEdges`.
    public var bandsDb: [Double]
    /// Whole-file aggregate, −1…+1; dead-channel/mono = +1 (the m22-d snap rule).
    public var correlation: Double
    /// Σside² / (Σmid² + Σside²), 0…1.
    public var width: Double
    /// (ΣR² − ΣL²) / (ΣL² + ΣR²), −1…+1.
    public var balance: Double
    public var durationSeconds: Double
    public var sampleRateHz: Double
    /// = the engine analyzer's version (1). A version bump re-analyzes.
    public var analyzerVersion: Int

    public init(
        integratedLufs: Double? = nil,
        maxMomentaryLufs: Double? = nil,
        maxShortTermLufs: Double? = nil,
        truePeakDbtp: Double? = nil,
        loudnessRangeLu: Double? = nil,
        bandsDb: [Double],
        correlation: Double,
        width: Double,
        balance: Double,
        durationSeconds: Double,
        sampleRateHz: Double,
        analyzerVersion: Int
    ) {
        self.integratedLufs = integratedLufs
        self.maxMomentaryLufs = maxMomentaryLufs
        self.maxShortTermLufs = maxShortTermLufs
        self.truePeakDbtp = truePeakDbtp
        self.loudnessRangeLu = loudnessRangeLu
        self.bandsDb = bandsDb
        self.correlation = correlation
        self.width = width
        self.balance = balance
        self.durationSeconds = durationSeconds
        self.sampleRateHz = sampleRateHz
        self.analyzerVersion = analyzerVersion
    }
}

/// The project's reference slot. Its Codable IS the wire shape (the take.*
/// can-never-drift rule): `sourcePath` rides the wire as `path`. Disk
/// persistence goes through the separate `ReferenceDocument` mirror so the
/// file can ride as a bundle-relative `media/…` ref (the clip precedent).
public struct ReferenceSlot: Codable, Sendable, Equatable, Identifiable {
    /// User trim clamp, dB (design §5.6).
    public static let trimRangeDb = -24.0...24.0

    public var id: UUID
    /// Display name — defaults to the imported file's basename.
    public var name: String
    /// Absolute path in memory; a save rewrites it to the bundle's media/ copy.
    public var sourcePath: String
    /// Reference file time = timeline seconds + offsetSeconds (design D6).
    public var offsetSeconds: Double
    /// User trim on top of the level-match law, dB, clamped ±24.
    public var trimDb: Double
    /// nil until analyzed / after a failed analysis (`reference.analyze` retries).
    public var analysis: ReferenceAnalysis?

    private enum CodingKeys: String, CodingKey {
        case id, name, path, offsetSeconds, trimDb, analysis
    }

    public init(id: UUID = UUID(), name: String, sourcePath: String,
                offsetSeconds: Double = 0, trimDb: Double = 0,
                analysis: ReferenceAnalysis? = nil) {
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.offsetSeconds = offsetSeconds
        self.trimDb = trimDb.clamped(to: Self.trimRangeDb)
        self.analysis = analysis
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Identity is required; everything else tolerates absence with the
        // model defaults (values re-clamp through the public init).
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Reference",
            sourcePath: try c.decodeIfPresent(String.self, forKey: .path) ?? "",
            offsetSeconds: try c.decodeIfPresent(Double.self, forKey: .offsetSeconds) ?? 0,
            trimDb: try c.decodeIfPresent(Double.self, forKey: .trimDb) ?? 0,
            analysis: try c.decodeIfPresent(ReferenceAnalysis.self, forKey: .analysis))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(sourcePath, forKey: .path)
        try c.encode(offsetSeconds, forKey: .offsetSeconds)
        try c.encode(trimDb, forKey: .trimDb)
        // Omitted when nil: absence = "not analyzed" on the wire.
        try c.encodeIfPresent(analysis, forKey: .analysis)
    }
}

/// Result of `ProjectStore.importReference`: the slot that landed plus any
/// non-fatal warnings (analysis failure — the slot still lands with
/// `analysis: nil`, the sanitized-load idiom). The wire merges `warnings`
/// into the slot's own encoding.
public struct ReferenceImportOutcome: Sendable, Equatable {
    public var slot: ReferenceSlot
    public var warnings: [String]

    public init(slot: ReferenceSlot, warnings: [String]) {
        self.slot = slot
        self.warnings = warnings
    }
}

/// `reference.status` wire shape (design §6): the slot (omitted when none),
/// the transient monitor state, and the match-gain preview. The live match
/// fields (`matchGainDb`/`matchBasis`/`ceilingLimited`) are present only
/// while monitoring (P2 machinery); `wouldMatchGainDb` previews the law
/// whenever a computable slot exists. Read-only, never throws.
public struct ReferenceStatus: Codable, Sendable, Equatable {
    public var reference: ReferenceSlot?
    public var monitoring: Bool
    public var wouldMatchGainDb: Double?
    public var matchGainDb: Double?
    public var matchBasis: String?
    public var ceilingLimited: Bool?

    public init(reference: ReferenceSlot? = nil, monitoring: Bool = false,
                wouldMatchGainDb: Double? = nil, matchGainDb: Double? = nil,
                matchBasis: String? = nil, ceilingLimited: Bool? = nil) {
        self.reference = reference
        self.monitoring = monitoring
        self.wouldMatchGainDb = wouldMatchGainDb
        self.matchGainDb = matchGainDb
        self.matchBasis = matchBasis
        self.ceilingLimited = ceilingLimited
    }
}

/// Transient A/B monitor state (m22-g P2) — the toggle-ON snapshot of the
/// level-match law INPUTS plus the computed result. Never persisted, never
/// undoable, never in `project.snapshot` (the `isPlaying` transient-state
/// analogy). Holding the inputs is what makes `reference.setTrim` honest:
/// the trim recompute re-runs the law against the SAME snapshotted basis —
/// the gain never chases the evolving live integrated mid-audition
/// (design §5.6).
public struct ReferenceMonitorSnapshot: Sendable, Equatable {
    /// The slot the monitor was armed against — a slot replacement/removal
    /// mid-audition turns the monitor off rather than silently re-aiming it.
    public var slotID: UUID
    /// The mix's live gated integrated at toggle-ON; nil = no reading
    /// (the −14 LUFS fallback basis was used).
    public var mixIntegratedLufs: Double?
    public var referenceIntegratedLufs: Double
    public var referenceTruePeakDbtp: Double?
    public var match: ReferenceLevelMatch.Result

    public init(slotID: UUID, mixIntegratedLufs: Double?,
                referenceIntegratedLufs: Double, referenceTruePeakDbtp: Double?,
                match: ReferenceLevelMatch.Result) {
        self.slotID = slotID
        self.mixIntegratedLufs = mixIntegratedLufs
        self.referenceIntegratedLufs = referenceIntegratedLufs
        self.referenceTruePeakDbtp = referenceTruePeakDbtp
        self.match = match
    }
}

/// `reference.setMonitor` wire shape (design §6): the transient monitor
/// state plus — only when monitoring is ON — the level-match evidence
/// (synthesized Codable omits the nil fields, the m22-c omission law).
public struct ReferenceMonitorResult: Codable, Sendable, Equatable {
    public var monitoring: Bool
    public var matchGainDb: Double?
    /// "liveIntegrated" | "fallbackTarget" (design §5.6).
    public var matchBasis: String?
    /// The basis reading at toggle-ON; omitted when the −14 fallback was used.
    public var mixIntegratedLufs: Double?
    public var referenceIntegratedLufs: Double?
    public var ceilingLimited: Bool?

    public init(monitoring: Bool, matchGainDb: Double? = nil,
                matchBasis: String? = nil, mixIntegratedLufs: Double? = nil,
                referenceIntegratedLufs: Double? = nil, ceilingLimited: Bool? = nil) {
        self.monitoring = monitoring
        self.matchGainDb = matchGainDb
        self.matchBasis = matchBasis
        self.mixIntegratedLufs = mixIntegratedLufs
        self.referenceIntegratedLufs = referenceIntegratedLufs
        self.ceilingLimited = ceilingLimited
    }
}

/// `reference.compare` wire shape (design §6): the mix's live evidence, the
/// slot's stored whole-file analysis, and per-field deltas (reference − mix)
/// — every delta omitted when EITHER side lacks evidence (honest nils, the
/// m22-c omission law). The mix `bandsDb`/`width`/`correlation` are the
/// RECENT LIVE (ballistic) reading from the master analyzer, not a
/// whole-program average — callers poll during steady playback of a
/// representative section.
public struct ReferenceCompareResult: Codable, Sendable, Equatable {
    public struct MixSide: Codable, Sendable, Equatable {
        public var integratedLufs: Double?
        public var maxTruePeakDbtp: Double?
        public var loudnessRangeLu: Double?
        public var width: Double?
        public var correlation: Double?
        public var bandsDb: [Double]?

        public init(integratedLufs: Double? = nil, maxTruePeakDbtp: Double? = nil,
                    loudnessRangeLu: Double? = nil, width: Double? = nil,
                    correlation: Double? = nil, bandsDb: [Double]? = nil) {
            self.integratedLufs = integratedLufs
            self.maxTruePeakDbtp = maxTruePeakDbtp
            self.loudnessRangeLu = loudnessRangeLu
            self.width = width
            self.correlation = correlation
            self.bandsDb = bandsDb
        }
    }

    public struct Delta: Codable, Sendable, Equatable {
        public var lufs: Double?
        public var truePeakDb: Double?
        public var lra: Double?
        public var width: Double?
        public var correlation: Double?
        public var bandsDb: [Double]?

        public init(lufs: Double? = nil, truePeakDb: Double? = nil,
                    lra: Double? = nil, width: Double? = nil,
                    correlation: Double? = nil, bandsDb: [Double]? = nil) {
            self.lufs = lufs
            self.truePeakDb = truePeakDb
            self.lra = lra
            self.width = width
            self.correlation = correlation
            self.bandsDb = bandsDb
        }
    }

    public var mix: MixSide
    public var reference: ReferenceAnalysis
    public var delta: Delta

    public init(mix: MixSide, reference: ReferenceAnalysis, delta: Delta) {
        self.mix = mix
        self.reference = reference
        self.delta = delta
    }

    /// Assembles the compare block from live evidence + the stored analysis.
    /// Pure — the store gathers the inputs (and refuses `engineUnavailable`
    /// BEFORE this point when there is no live meter to read).
    public static func assemble(
        live: LiveLoudnessSnapshot, master: MasterAnalysisSnapshot,
        analysis: ReferenceAnalysis
    ) -> ReferenceCompareResult {
        let mixBands = master.bands.map { Double($0) }
        let mix = MixSide(
            integratedLufs: live.integratedLufs,
            maxTruePeakDbtp: live.truePeakDbtp,
            loudnessRangeLu: live.loudnessRangeLu,
            width: Double(master.width),
            correlation: Double(master.correlation),
            bandsDb: mixBands)
        func minus(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b else { return nil }
            return a - b
        }
        var bandDelta: [Double]?
        if analysis.bandsDb.count == mixBands.count {
            bandDelta = zip(analysis.bandsDb, mixBands).map { $0 - $1 }
        }
        let delta = Delta(
            lufs: minus(analysis.integratedLufs, mix.integratedLufs),
            truePeakDb: minus(analysis.truePeakDbtp, mix.maxTruePeakDbtp),
            lra: minus(analysis.loudnessRangeLu, mix.loudnessRangeLu),
            width: minus(analysis.width, mix.width),
            correlation: minus(analysis.correlation, mix.correlation),
            bandsDb: bandDelta)
        return ReferenceCompareResult(mix: mix, reference: analysis, delta: delta)
    }
}

/// The exact level-match law (design §5.6) — pure DAWCore, no engine, no I/O.
/// `gain = (mixLiveIntegrated ?? −14.0) − refIntegrated + trim`, clamped so
/// `refTruePeak + gain ≤ −1.0 dBTP`. The basis and the clamp are surfaced
/// honestly (`matchBasis`, `ceilingLimited` — the render.bounce
/// `limitedByCeiling` precedent).
public enum ReferenceLevelMatch {
    /// No-mix-reading basis: the −14 LUFS streaming convention
    /// `render.bounce` already teaches. REJECTED: unity gain — playing a
    /// mastered reference at full loudness against an unmastered mix is the
    /// louder-sounds-better trap this feature exists to kill.
    public static let fallbackTargetLufs = -14.0
    /// The house true-peak ceiling default (M5 iv-d).
    public static let ceilingDbtp = -1.0

    public struct Result: Sendable, Equatable {
        public var matchGainDb: Double
        /// "liveIntegrated" when a mix reading existed, else "fallbackTarget".
        public var matchBasis: String
        /// True when the ceiling clamp reduced the requested gain.
        public var ceilingLimited: Bool
        /// 10^(matchGainDb/20) — the node-volume value P2 applies.
        public var linearGain: Double

        public init(matchGainDb: Double, matchBasis: String,
                    ceilingLimited: Bool, linearGain: Double) {
            self.matchGainDb = matchGainDb
            self.matchBasis = matchBasis
            self.ceilingLimited = ceilingLimited
            self.linearGain = linearGain
        }
    }

    /// - Parameters:
    ///   - mixIntegratedLufs: the mix's live gated integrated (nil = no
    ///     reading yet → the −14 LUFS fallback basis).
    ///   - refIntegratedLufs: the slot's analyzed integrated (callers refuse
    ///     BEFORE this law when it is nil — a gated-silent reference cannot
    ///     be matched).
    ///   - refTruePeakDbtp: the slot's analyzed true peak; nil assumes
    ///     0.0 dBTP (conservative — clamps harder, never louder).
    ///   - trimDb: user trim, re-clamped ±24 here (belt-and-suspenders with
    ///     the slot's own clamp).
    public static func compute(
        mixIntegratedLufs: Double?, refIntegratedLufs: Double,
        refTruePeakDbtp: Double?, trimDb: Double
    ) -> Result {
        let basis = mixIntegratedLufs ?? fallbackTargetLufs
        let trim = trimDb.clamped(to: ReferenceSlot.trimRangeDb)
        let requestedDb = (basis - refIntegratedLufs) + trim
        let headroomDb = ceilingDbtp - (refTruePeakDbtp ?? 0.0)
        let matchGainDb = min(requestedDb, headroomDb)
        return Result(
            matchGainDb: matchGainDb,
            matchBasis: mixIntegratedLufs != nil ? "liveIntegrated" : "fallbackTarget",
            ceilingLimited: matchGainDb < requestedDb,
            linearGain: pow(10, matchGainDb / 20))
    }
}

/// Whole-file stereo aggregates (design D2) — pure buffers-in math, the
/// DAWCore side of the m22-d stereo-image family. This is a DIFFERENT
/// quantity from `MasterMixAnalyzer`'s live ballistic reading (no τ 300 ms
/// one-pole, no decay): plain running sums over the whole program, sharing
/// the live home's CONVENTIONS exactly — zero-lag normalized correlation
/// E[LR]/√(E[L²]E[R²]), width S²/(M²+S²) (hard-panned mono reads 0.5),
/// balance (R²−L²)/(L²+R²), the +1/0/0 floors for silence, and the
/// dead-channel snap to correlation +1 (mono-summing a dead channel cancels
/// nothing). A cross-consistency pin ties the two homes on steady signals.
public enum StereoImage {
    /// The m22-d house stereo floor, as MEAN power per sample: a channel (or
    /// the combined program) whose mean square sits under 10·log10(1e-8) =
    /// −80 dB is "off" — floors publish / the dead-channel snap applies.
    public static let floorMeanPower = 1e-8

    public struct Aggregate: Codable, Sendable, Equatable {
        public var correlation: Double
        public var width: Double
        public var balance: Double

        public init(correlation: Double, width: Double, balance: Double) {
            self.correlation = correlation
            self.width = width
            self.balance = balance
        }
    }

    /// Chunk-feedable running sums (Double — the m22-d exactness rule: the
    /// mono/inverted fixtures must land EXACTLY on ±1). A chunk whose sums
    /// come out non-finite (NaN/Inf-poisoned input, or finite garbage whose
    /// square overflowed) is skipped WHOLE — the MasterMixAnalyzer
    /// frame-skip idiom; accumulated state stays clean.
    public struct Accumulator: Sendable {
        private var sumLL = 0.0
        private var sumRR = 0.0
        private var sumLR = 0.0
        private var frames = 0

        public init() {}

        public mutating func process(left: [Float], right: [Float]) {
            left.withUnsafeBufferPointer { l in
                right.withUnsafeBufferPointer { r in
                    process(left: l, right: r)
                }
            }
        }

        public mutating func process(
            left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>
        ) {
            let count = min(left.count, right.count)
            guard count > 0,
                  let lBase = left.baseAddress, let rBase = right.baseAddress else { return }
            var ll = 0.0
            var rr = 0.0
            var lr = 0.0
            var i = 0
            while i < count {
                let l = Double(lBase[i])
                let r = Double(rBase[i])
                ll += l * l
                rr += r * r
                lr += l * r
                i += 1
            }
            // Poisoned chunk → skipped whole; state stays clean.
            guard ll.isFinite, rr.isFinite, lr.isFinite else { return }
            sumLL += ll
            sumRR += rr
            sumLR += lr
            frames += count
        }

        public func aggregate() -> Aggregate {
            let total = sumLL + sumRR
            guard frames > 0, total.isFinite,
                  total / Double(frames) >= StereoImage.floorMeanPower else {
                // Silence/empty floors: correlation +1 (nothing out of
                // phase), width 0, balance 0 — the m22-d convention.
                return Aggregate(correlation: 1, width: 0, balance: 0)
            }
            let n = Double(frames)
            let balance = ((sumRR - sumLL) / total).clamped(to: -1...1)
            let width = ((total - 2 * sumLR) / (2 * total)).clamped(to: 0...1)
            let correlation: Double
            if sumLL / n < StereoImage.floorMeanPower
                || sumRR / n < StereoImage.floorMeanPower {
                correlation = 1  // dead channel: mono-summing it cancels nothing
            } else {
                correlation = (sumLR / (sumLL * sumRR).squareRoot()).clamped(to: -1...1)
            }
            return Aggregate(correlation: correlation, width: width, balance: balance)
        }
    }

    /// One-shot convenience over the accumulator. Mono callers pass the same
    /// array twice (correlation +1 by definition).
    public static func measure(left: [Float], right: [Float]) -> Aggregate {
        var accumulator = Accumulator()
        accumulator.process(left: left, right: right)
        return accumulator.aggregate()
    }
}
