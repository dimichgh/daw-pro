import Foundation

/// Piecewise-constant project tempo (M12 m12-b, design:
/// docs/research/design-m11f-tempo-map.md §3.1). THE single home of
/// beat↔seconds conversion — every site in the app routes through this API;
/// a permanent lint test (mcp-server/test/tempo-lint.test.ts) fails the suite
/// on raw `60/tempo`-shaped arithmetic anywhere else.
///
/// Phase A (the null case): the app only ever builds TRIVIAL single-segment
/// maps, synthesized from `TransportState.tempoBPM` at the call boundary via
/// `TransportState.tempoMap` — that computed property is the ONE seam.
/// Multi-segment maps are exercised by unit tests only until Phase B/C land
/// engine integration and the persistence/wire surface.
///
/// Numeric contract (load-bearing for the Phase-A byte-equivalence gate):
/// with a single segment the API reproduces the legacy scalar arithmetic
/// BIT-FOR-BIT in its dominant shapes —
///  · `seconds(from: a, to: b)`   ≡ `(b - a) * (60.0 / bpm)`   (same-segment fast path)
///  · `beat(from: a, elapsedSeconds: s)` ≡ `a + s * bpm / 60.0` (in-segment fast path;
///     the exact `derivedBeats` shape, AudioEngine.swift)
///  · `secondsPerBeat(atBeat:)`   ≡ `60.0 / bpm`               (the `spb` idiom)
/// All lookups are total functions: no throwing, O(log n) binary search over
/// prefix sums, NaN-safe (garbage in → garbage out, never a trap). Validation
/// happens only at mutation (`init(segments:)` / `setSegments`), with
/// field-named errors — the `take.setComp` per-index-error precedent.
public struct TempoMap: Sendable {

    /// One constant-tempo span: governs [startBeat, next segment's startBeat).
    /// Right-continuous — a change AT beat b governs [b, next). Ramps are
    /// explicitly out of v1; a future `curve` field is an additive Codable
    /// case (the `AutomationCurve` precedent, Automation.swift).
    public struct Segment: Codable, Sendable, Equatable {
        public var startBeat: Double
        /// Clamped to `TransportState.tempoRange` (20...400) at init — a map
        /// can never carry a bpm the transport itself refuses, so
        /// seconds-per-beat is always finite and positive.
        public var bpm: Double

        public init(startBeat: Double, bpm: Double) {
            self.startBeat = startBeat
            self.bpm = bpm.clamped(to: TransportState.tempoRange)
        }
    }

    /// Field-named validation errors (mutation-time only; lookups never throw).
    public enum ValidationError: Error, Equatable {
        /// `segments` may never be empty — a map always has a base tempo.
        case emptySegments
        /// Segment 0 must start at beat 0 (carries the offending startBeat).
        case firstSegmentNotAtZero(startBeat: Double)
        /// `segments[index].startBeat` is not strictly greater than its
        /// predecessor's (covers both unsorted and duplicate startBeats).
        case unsortedOrDuplicateStartBeat(index: Int)
    }

    /// Sorted by startBeat, unique, non-empty, first at 0. Mutation is
    /// funneled through the validating initializers so the derived prefix
    /// sums can never go stale.
    public private(set) var segments: [Segment]

    /// prefixSeconds[i] = seconds from beat 0 to segments[i].startBeat.
    /// Rebuilt on every mutation (main-actor only — the map is a value type;
    /// concurrent readers each own their copy).
    private var prefixSeconds: [Double]

    /// The trivial map — segment 0 covers the whole timeline. This is the
    /// ONLY shape the app itself constructs in Phase A.
    public init(constantBPM bpm: Double) {
        segments = [Segment(startBeat: 0, bpm: bpm)]
        prefixSeconds = [0]
    }

    /// Validating initializer (unit tests / later phases). Segment bpm values
    /// clamp via `Segment.init`; structural problems throw field-named errors.
    public init(segments: [Segment]) throws {
        guard !segments.isEmpty else { throw ValidationError.emptySegments }
        guard segments[0].startBeat == 0 else {
            throw ValidationError.firstSegmentNotAtZero(startBeat: segments[0].startBeat)
        }
        for i in 1..<segments.count where !(segments[i].startBeat > segments[i - 1].startBeat) {
            throw ValidationError.unsortedOrDuplicateStartBeat(index: i)
        }
        self.segments = segments
        self.prefixSeconds = Self.buildPrefix(segments)
    }

    /// Whole-array replace (the automation.setPoints / take.setComp shape) —
    /// the store-side mutation entry point for Phase C.
    public mutating func setSegments(_ newSegments: [Segment]) throws {
        self = try TempoMap(segments: newSegments)
    }

    private static func buildPrefix(_ segments: [Segment]) -> [Double] {
        var prefix = [Double](repeating: 0, count: segments.count)
        for i in 1..<segments.count {
            let prev = segments[i - 1]
            prefix[i] = prefix[i - 1]
                + (segments[i].startBeat - prev.startBeat) * (60.0 / prev.bpm)
        }
        return prefix
    }

    // MARK: - Lookups (pure, total, O(log n))

    /// Index of the segment governing `beat`: the LAST segment with
    /// startBeat <= beat. Beats before 0 (and NaN) resolve to segment 0 —
    /// segment 0 extrapolates linearly in both directions.
    private func index(forBeat beat: Double) -> Int {
        var lo = 0
        var hi = segments.count - 1
        var result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segments[mid].startBeat <= beat {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    /// Index of the segment governing absolute second `s` (inverse lookup
    /// over the prefix sums; same conventions as `index(forBeat:)`).
    private func index(forSeconds s: Double) -> Int {
        var lo = 0
        var hi = segments.count - 1
        var result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if prefixSeconds[mid] <= s {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    /// Tempo at `beat` (right-continuous segment lookup).
    public func bpm(atBeat beat: Double) -> Double {
        segments[index(forBeat: beat)].bpm
    }

    /// Seconds of ONE beat at `beat` — the legacy `spb = 60.0 / tempoBPM`
    /// idiom as a map lookup. This is the sanctioned scalar for
    /// LOOKUP-verdict sites (design §5: count-in pre-roll, clip-local slice
    /// math) where a constant per-position factor is the documented policy;
    /// INTEGRAL-verdict sites use `seconds(from:to:)` instead.
    public func secondsPerBeat(atBeat beat: Double) -> Double {
        60.0 / bpm(atBeat: beat)
    }

    /// Frames of ONE beat at `beat` for a given sample rate — the legacy
    /// `fileRate * 60.0 / tempoBPM` frames-per-beat idiom as a map lookup,
    /// kept in THIS file (the lint's one sanctioned home) with the op order
    /// VERBATIM: `sampleRate * 60` is FP-exact and the single division
    /// reproduces the scalar-era value bit-for-bit (mul-first vs div-first
    /// differs by 1 ULP at e.g. 140 BPM — the m12-b byte-gate finding).
    /// `ClipFadeBake` uses this on its constant-tempo fast path (m12-c); its
    /// former private copy (and its lint allowlist entry) is gone.
    public func framesPerBeat(atBeat beat: Double, sampleRate: Double) -> Double {
        sampleRate * 60.0 / bpm(atBeat: beat)
    }

    /// True when the whole span between `a` and `b` (either order) is governed
    /// by ONE segment, i.e. every conversion over it is a constant-tempo
    /// multiply. Used by m12-c consumers that keep a bit-exact constant-rate
    /// fast path (`ClipFadeBake`) or reject boundary-crossing spans by policy
    /// (`AudioQuantizePlan`). NOTE: a span ENDING exactly on a boundary beat
    /// reports false (the boundary's segment is right-continuous) — callers
    /// take the piecewise path, which computes the same integral values.
    public func isConstant(from a: Double, to b: Double) -> Bool {
        index(forBeat: a) == index(forBeat: b)
    }

    /// The integral S(b): seconds from beat 0 to `beat` (signed for beat < 0
    /// — segment 0 extrapolates).
    public func seconds(fromBeatZeroTo beat: Double) -> Double {
        let i = index(forBeat: beat)
        let seg = segments[i]
        return prefixSeconds[i] + (beat - seg.startBeat) * (60.0 / seg.bpm)
    }

    /// S(b) − S(a), signed. Same-segment spans use the exact legacy shape
    /// `(b − a) * (60.0 / bpm)` — bit-identical to the scalar formula for a
    /// trivial map (the Phase-A byte-equivalence contract).
    public func seconds(from a: Double, to b: Double) -> Double {
        let ia = index(forBeat: a)
        let ib = index(forBeat: b)
        if ia == ib {
            return (b - a) * (60.0 / segments[ia].bpm)
        }
        return seconds(fromBeatZeroTo: b) - seconds(fromBeatZeroTo: a)
    }

    /// S⁻¹(s): the beat at absolute second `s` — exact per segment
    /// (mul-first `* bpm / 60.0`, the dominant legacy inverse shape).
    public func beat(atSecondsFromZero s: Double) -> Double {
        let i = index(forSeconds: s)
        let seg = segments[i]
        return seg.startBeat + (s - prefixSeconds[i]) * seg.bpm / 60.0
    }

    /// S⁻¹(S(startBeat) + elapsedSeconds) — the `derivedBeats` shape. While
    /// the result stays inside `startBeat`'s own segment this is EXACTLY the
    /// legacy `startBeat + elapsedSeconds * bpm / 60.0` (bit-identical for a
    /// trivial map, where the fast path always holds). `elapsedSeconds` is
    /// signed. NOTE: no clamping — `derivedBeats`' `max(startBeats, …)`
    /// count-in pin stays at the call site, verbatim (design §3.3).
    public func beat(from startBeat: Double, elapsedSeconds: Double) -> Double {
        let i = index(forBeat: startBeat)
        let seg = segments[i]
        let candidate = startBeat + elapsedSeconds * seg.bpm / 60.0
        let nextStart = i + 1 < segments.count ? segments[i + 1].startBeat : .infinity
        if candidate < nextStart, i == 0 || candidate >= seg.startBeat {
            return candidate
        }
        return beat(atSecondsFromZero: seconds(fromBeatZeroTo: startBeat) + elapsedSeconds)
    }
}

extension TempoMap: Equatable {
    /// Segments are the identity; prefix sums are derived deterministically.
    public static func == (lhs: TempoMap, rhs: TempoMap) -> Bool {
        lhs.segments == rhs.segments
    }
}

extension TempoMap: Codable {
    /// Only `segments` persist; prefix sums rebuild on decode. A structurally
    /// invalid payload fails decoding with the validation error's context
    /// (never a silently "repaired" map).
    private enum CodingKeys: String, CodingKey { case segments }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([Segment].self, forKey: .segments)
        do {
            try self.init(segments: decoded)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .segments, in: container,
                debugDescription: "invalid tempo map segments: \(error)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segments, forKey: .segments)
    }
}

/// Musical note-length divisions, 1/1 … 1/32 with dotted and triplet
/// variants (m22-f delay tempo sync). Lives HERE — TempoMap.swift is the one
/// sanctioned home of beat↔seconds arithmetic (the permanent tempo lint,
/// mcp-server/test/tempo-lint.test.ts), and `milliseconds(atBPM:)` IS a
/// beat→seconds conversion.
///
/// Serialization (the raw value, used on disk and in UI labels): the note
/// fraction with an optional modifier suffix — `"1/4"` straight, `"1/8d"`
/// dotted (×1.5), `"1/8t"` triplet (×2/3). Declaration order runs longest →
/// shortest, straight/dotted/triplet per base — the order pickers present.
public enum NoteDivision: String, Codable, Sendable, CaseIterable, Equatable {
    case whole = "1/1", wholeDotted = "1/1d", wholeTriplet = "1/1t"
    case half = "1/2", halfDotted = "1/2d", halfTriplet = "1/2t"
    case quarter = "1/4", quarterDotted = "1/4d", quarterTriplet = "1/4t"
    case eighth = "1/8", eighthDotted = "1/8d", eighthTriplet = "1/8t"
    case sixteenth = "1/16", sixteenthDotted = "1/16d", sixteenthTriplet = "1/16t"
    case thirtySecond = "1/32", thirtySecondDotted = "1/32d", thirtySecondTriplet = "1/32t"

    /// The length in BEATS (quarter-note units — the project timeline unit
    /// everywhere): 1/1 = 4, 1/4 = 1, 1/16 = 0.25; dotted ×1.5, triplet ×2/3.
    /// This is also the division's NUMERIC value on the generic effect-param
    /// surface (`fx.setParam name:"division"` — see `nearest(toBeats:)`).
    public var beats: Double {
        straightBeats * modifier
    }

    private var straightBeats: Double {
        switch self {
        case .whole, .wholeDotted, .wholeTriplet: return 4
        case .half, .halfDotted, .halfTriplet: return 2
        case .quarter, .quarterDotted, .quarterTriplet: return 1
        case .eighth, .eighthDotted, .eighthTriplet: return 0.5
        case .sixteenth, .sixteenthDotted, .sixteenthTriplet: return 0.25
        case .thirtySecond, .thirtySecondDotted, .thirtySecondTriplet: return 0.125
        }
    }

    private var modifier: Double {
        switch self {
        case .wholeDotted, .halfDotted, .quarterDotted, .eighthDotted,
             .sixteenthDotted, .thirtySecondDotted:
            return 1.5
        case .wholeTriplet, .halfTriplet, .quarterTriplet, .eighthTriplet,
             .sixteenthTriplet, .thirtySecondTriplet:
            return 2.0 / 3.0
        default:
            return 1
        }
    }

    /// The division's duration in milliseconds at a constant tempo — the
    /// m22-f division→ms formula, UNclamped (`DelayParams.effectiveTimeMs`
    /// clamps to its own param range): 1/4 @ 120 = 500 ms, 1/8d @ 120 =
    /// 375 ms, 1/4t @ 120 = 333.33… ms. A non-finite or non-positive bpm
    /// (impossible through `TempoMap`, whose segments clamp to the transport
    /// range) answers NaN honestly rather than trapping.
    public func milliseconds(atBPM bpm: Double) -> Double {
        guard bpm.isFinite, bpm > 0 else { return .nan }
        return beats * 60_000.0 / bpm
    }

    /// Snaps a numeric beats value to the NEAREST legal division — the
    /// generic effect-param surface is numeric-only, so `division` rides as
    /// its beat length and snaps here (the `EQParams.snapSlope` precedent).
    /// Ties resolve to the earlier (longer) declaration.
    public static func nearest(toBeats value: Double) -> NoteDivision {
        guard value.isFinite else { return .quarter }
        var best = NoteDivision.quarter
        var bestDistance = Double.infinity
        for candidate in allCases {
            let distance = abs(candidate.beats - value)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }
}

/// Time-signature change list (design §3.2) — SEPARATE from TempoMap because
/// meter is display/snap/click structure ONLY: it never enters audio timing
/// math (a beat is a quarter-note duration unit everywhere; `beatUnit` stays
/// cosmetic in v1 exactly as today). Change 0 (beat 0) is the project
/// default; every later change must fall on a barline of the accumulated
/// meter before it, which makes bar numbering well-defined recursively.
///
/// Phase A: the app only builds trivial single-change maps via
/// `TransportState.meterMap`; multi-change maps are unit-test-only until
/// Phase C/D.
public struct MeterMap: Sendable {

    public struct Change: Codable, Sendable, Equatable {
        public var startBeat: Double
        /// Clamped >= 1 (the `TimeSignature` clamps, Model.swift).
        public var beatsPerBar: Int
        public var beatUnit: Int

        public init(startBeat: Double, beatsPerBar: Int, beatUnit: Int) {
            self.startBeat = startBeat
            self.beatsPerBar = max(1, beatsPerBar)
            self.beatUnit = max(1, beatUnit)
        }
    }

    /// Field-named validation errors (mutation-time only).
    public enum ValidationError: Error, Equatable {
        case emptyChanges
        case firstChangeNotAtZero(startBeat: Double)
        case unsortedOrDuplicateStartBeat(index: Int)
        /// `changes[index].startBeat` does not fall on a barline of the
        /// meter accumulated before it (the design's `meterChangeOffBarline`).
        case changeOffBarline(index: Int)
    }

    /// FP tolerance for the barline constraint: a change whose bar count is
    /// within this of a whole number is ON the barline (beat positions are
    /// user/agent-authored doubles, not accumulated sums — 1e-9 beats is far
    /// below any editable resolution).
    private static let barlineEpsilon = 1e-9

    public private(set) var changes: [Change]

    /// barsBefore[i] = 0-based index of the bar that STARTS at
    /// changes[i].startBeat (derived, rebuilt on mutation).
    private var barsBefore: [Int]

    /// The trivial map — the project's single time signature at beat 0.
    public init(constant timeSignature: TimeSignature) {
        changes = [Change(startBeat: 0,
                          beatsPerBar: timeSignature.beatsPerBar,
                          beatUnit: timeSignature.beatUnit)]
        barsBefore = [0]
    }

    public init(changes: [Change]) throws {
        guard !changes.isEmpty else { throw ValidationError.emptyChanges }
        guard changes[0].startBeat == 0 else {
            throw ValidationError.firstChangeNotAtZero(startBeat: changes[0].startBeat)
        }
        var barsBefore = [Int](repeating: 0, count: changes.count)
        for i in 1..<changes.count {
            guard changes[i].startBeat > changes[i - 1].startBeat else {
                throw ValidationError.unsortedOrDuplicateStartBeat(index: i)
            }
            let prev = changes[i - 1]
            let bars = (changes[i].startBeat - prev.startBeat) / Double(prev.beatsPerBar)
            guard abs(bars - bars.rounded()) <= Self.barlineEpsilon else {
                throw ValidationError.changeOffBarline(index: i)
            }
            barsBefore[i] = barsBefore[i - 1] + Int(bars.rounded())
        }
        self.changes = changes
        self.barsBefore = barsBefore
    }

    public mutating func setChanges(_ newChanges: [Change]) throws {
        self = try MeterMap(changes: newChanges)
    }

    // MARK: - Lookups (pure, total)

    private func index(forBeat beat: Double) -> Int {
        var lo = 0
        var hi = changes.count - 1
        var result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if changes[mid].startBeat <= beat {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    /// Meter at `beat` (right-continuous, like `TempoMap.bpm(atBeat:)`).
    public func beatsPerBar(atBeat beat: Double) -> Int {
        changes[index(forBeat: beat)].beatsPerBar
    }

    /// 0-based bar index + beat-within-bar at `beat`. For the trivial map
    /// this reproduces the legacy `barsBeatsDisplay` arithmetic exactly
    /// (`Int(pos / bpb)` / `truncatingRemainder`). Beats before 0 clamp to
    /// bar 0 beat 0 (positions are never negative in the domain model).
    public func barBeat(atBeat beat: Double) -> (bar: Int, beatInBar: Double) {
        let i = index(forBeat: beat)
        let change = changes[i]
        let bpb = Double(change.beatsPerBar)
        let rel = max(0, beat - change.startBeat)
        return (bar: barsBefore[i] + Int(rel / bpb),
                beatInBar: rel.truncatingRemainder(dividingBy: bpb))
    }

    /// Snaps `beat` to the nearest barline of the accumulated meter — the
    /// meter-map-aware replacement for `ClipSnap`'s uniform `(beat/bpb).rounded()
    /// * bpb` bar snap (m12-d, design rows 62–67). Across a meter boundary the
    /// bar grid is NOT uniform, so this resolves the containing bar, then picks
    /// the nearer of that bar's start and the next bar's start. Ties round UP
    /// (toward the later barline), matching `.rounded()`'s half-away-from-zero
    /// rule so a trivial single-meter map reproduces the legacy bar snap exactly.
    /// Clamped ≥ 0 (a leftward drag past the start pins at bar 0).
    public func nearestBarline(toBeat beat: Double) -> Double {
        guard beat > 0 else { return 0 }
        let (bar, _) = barBeat(atBeat: beat)
        let lower = self.beat(ofBar: bar)
        let upper = self.beat(ofBar: bar + 1)
        return (beat - lower) < (upper - beat) ? lower : upper
    }

    /// First beat of 0-based `bar`. Bars before 0 clamp to beat 0 (the
    /// mirror of `barBeat(atBeat:)`'s clamp).
    public func beat(ofBar bar: Int) -> Double {
        guard bar > 0 else { return 0 }
        // Last change whose starting bar is <= bar governs it.
        var lo = 0
        var hi = changes.count - 1
        var i = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if barsBefore[mid] <= bar {
                i = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return changes[i].startBeat
            + Double(bar - barsBefore[i]) * Double(changes[i].beatsPerBar)
    }
}

extension MeterMap: Equatable {
    /// Changes are the identity; `barsBefore` is derived deterministically.
    public static func == (lhs: MeterMap, rhs: MeterMap) -> Bool {
        lhs.changes == rhs.changes
    }
}

extension MeterMap: Codable {
    private enum CodingKeys: String, CodingKey { case changes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([Change].self, forKey: .changes)
        do {
            try self.init(changes: decoded)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .changes, in: container,
                debugDescription: "invalid meter map changes: \(error)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(changes, forKey: .changes)
    }
}

extension TransportState {
    /// THE tempo seam (m12-b/-d): the ONE place a `TempoMap` is synthesized
    /// from the scalar `tempoBPM`. Every beat↔seconds conversion in
    /// DAWCore/DAWEngine routes through the map API. A single-tempo project has
    /// no `tempoMapOverride`, so the map is ALWAYS this trivial single-segment
    /// shape — behavior byte-identical to the scalar era (gate-proven).
    /// `transport.tempoBPM` remains persisted and remains authoritative for
    /// segment 0 (design §3.4/§3.6). A `tempo.setMap` mutation (m12-d, Phase C)
    /// installs a multi-segment `tempoMapOverride`, which then wins here; the
    /// store keeps `tempoBPM` == segment 0's bpm.
    public var tempoMap: TempoMap { tempoMapOverride ?? TempoMap(constantBPM: tempoBPM) }

    /// The meter twin of `tempoMap` — the trivial single-change map synthesized
    /// from `timeSignature` unless a non-trivial `meterMapOverride` is installed
    /// (m12-d); the store keeps `timeSignature` == change 0's meter.
    public var meterMap: MeterMap { meterMapOverride ?? MeterMap(constant: timeSignature) }
}
