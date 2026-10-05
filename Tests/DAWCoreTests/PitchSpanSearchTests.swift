import Foundation
import Testing
import DAWCore

// p2-span — the pitch curve's span search must never skip a ramp that is
// still open. `PitchCorrectionCurve.firstSpanIndex` and the scan's early
// exit, in BOTH evaluators: `semitones(atSourceSecond:editedSecond:)` and
// NT-C C1's `formantSemitones(atSourceSecond:editedSecond:formantPreserve:)`,
// which copies the pitch loop's scan.
//
// ═══ THE DEFECT ═══
//
// A span is open on `(start − halfRamp, end + halfRamp)`, and
// `halfRamp = min(retune / 2, duration / 2)`. So a SHORT note after a LONG
// one reaches LESS far than the long one does (NT-G's fixture: reaches
// `[2.1, 2.09]`), and a LONG note after a SHORT one opens EARLIER than the
// short one does. Before p2-span the binary search assumed the reach was
// non-decreasing in start order, and the early exit assumed the opening
// was. Neither holds, and each one skipped a span whose gate was not zero.
//
// ═══ G-TWO (natural tuning §4.g) ═══
//
// The shipped evaluator agrees BIT FOR BIT (`.bitPattern`) with a reference
// LINEAR SCAN (every span, in index order, no search and no early exit) over
// seeded random sets, at `t` sampled densely around every edge.
//
// ⚠️ **THE REFERENCE IS A MIRROR, AND HERE IS WHY THAT IS SOUND.** `Span`,
// `gate` and `smoothstep` are `fileprivate`, and `@testable import` does not
// reach `fileprivate`. So the reference restates their arithmetic from PUBLIC
// fields (`NoteSegment`, `PitchEditSet`), operation for operation, and reuses
// DAWCore's own public `clamped(to:)`. A mirror whose arithmetic drifted
// would disagree on EVERY set, including the ones where the old search was
// already right, so a green run is also the mirror's own proof. The shaping
// and generator terms are not mirrored: these sets carry neither (the pitch
// contribution is `constant + 0.0`, shaping's literal zero), because the
// defect is in WHICH spans are visited, not in what each one adds.
//
// ⚠️ **THE FIXTURE MUST CONTAIN THE CONDITION, AND THE TEST SAYS SO.** A
// generator that happened to build only monotone sets would pass on the old
// code too. Each G-TWO test counts the sample points where a span is open
// while a LATER span has already closed (the search's hazard), and where a
// span is open while an EARLIER span has not yet opened (the early exit's
// hazard), and requires both counts to be non-zero.
//
// Not `@MainActor`: nothing here needs the actor, and the suite cap is full.
struct PitchSpanSearchTests {

    // MARK: - The reference

    /// One span as `PitchCorrectionCurve.make` builds it, restated from the
    /// segment's public fields.
    ///
    /// NT-C C4 (natural tuning §4): the gate has a RISE half and centre and
    /// a FALL half and centre, and a following slide carries a bridge. On a
    /// legacy set both halves are the one legacy half and the centres are
    /// the note's own edges, which is exactly the pre-C4 mirror.
    struct RefSpan {
        let start: Double
        let end: Double
        var halfIn: Double
        var riseCentre: Double
        var halfOut: Double
        var fallCentre: Double
        let constant: Double
        let formantOffset: Double
        var bridgeFrom = 0.0
        var bridgeTo = 0.0
        var bridgeAmount = 0.0
        /// Test bookkeeping only (never read by the evaluator mirror): the
        /// soft pass gave this span's FALL a width.
        var softOut = false
        /// Where the gate closes: `fallCentre + halfOut` (legacy:
        /// `endSeconds + halfRamp`).
        var reach: Double { fallCentre + halfOut }
        /// Where the gate opens: `riseCentre − halfIn` (legacy:
        /// `startSeconds − halfRamp`).
        var opening: Double { riseCentre - halfIn }
    }

    /// `make`'s span list: the same filter (`entersPitchCurve`), the same
    /// half-ramp clamp, the same constant, and on a SOFT set the §4.b.2 pass
    /// restated from the design text and PUBLIC fields. ⚠️ It never calls
    /// `PitchEditSet.softJoin`/`joinKind`/`usesSoftJoins`: a mirror that
    /// called the code under test would agree with it by construction. It
    /// reads only the public threshold constant.
    static func refSpans(_ set: PitchEditSet) -> [RefSpan] {
        let ramp = set.retuneMs / 1000
        let notes = set.segments.filter(\.entersPitchCurve)
        var spans = notes.map { note -> RefSpan in
            let half = min(ramp / 2, note.durationSeconds / 2)
            return RefSpan(start: note.startSeconds, end: note.endSeconds,
                           halfIn: half, riseCentre: note.startSeconds,
                           halfOut: half, fallCentre: note.endSeconds,
                           constant: note.pitchOffsetCents / 100,
                           formantOffset: note.formantOffsetSemitones)
        }
        let slope = set.transitionSlopeCentsPerSecond
        let soft = slope > 0
            || set.segments.contains { $0.transitionOutMs != 0 || $0.glideFollow != 0 }
        guard soft, notes.count > 0 else { return spans }
        // R15: abut bit for bit, or a hole shorter than the threshold.
        func softJoinAfter(_ i: Int) -> Bool {
            guard i + 1 < notes.count else { return false }
            let left = notes[i].endSeconds
            let right = notes[i + 1].startSeconds
            return left == right || right - left < PitchEditSet.consonantMinimumGapSeconds
        }
        // Step 3: the bridge, from the neighbours' OWN offsets.
        for i in notes.indices where notes[i].glideFollow > 0 {
            spans[i].bridgeFrom = i > 0 && softJoinAfter(i - 1) ? notes[i - 1].pitchOffsetCents / 100 : 0
            spans[i].bridgeTo = softJoinAfter(i) ? notes[i + 1].pitchOffsetCents / 100 : 0
            spans[i].bridgeAmount = notes[i].glideFollow
        }
        // Step 2: one width, one edge, per soft join.
        for i in notes.indices where softJoinAfter(i) {
            let l = notes[i], r = notes[i + 1]
            let w: Double
            if l.transitionOutMs > 0 {
                w = l.transitionOutMs
            } else if slope > 0 {
                var endValue = l.pitchOffsetCents
                if l.glideFollow > 0 { endValue += l.glideFollow * r.pitchOffsetCents }
                var startValue = r.pitchOffsetCents
                if r.glideFollow > 0 { startValue += r.glideFollow * l.pitchOffsetCents }
                w = max(set.retuneMs, 1000 * abs(endValue - startValue) / slope)
            } else {
                continue
            }
            let h = min(w / 2000, l.durationSeconds / 2, r.durationSeconds / 2)
            let edge = l.endSeconds == r.startSeconds ? l.endSeconds : (l.endSeconds + r.startSeconds) / 2
            spans[i].halfOut = h
            spans[i].fallCentre = edge
            spans[i].softOut = true
            spans[i + 1].halfIn = h
            spans[i + 1].riseCentre = edge
        }
        return spans
    }

    static func smoothstep(_ x: Double) -> Double {
        let c = x.clamped(to: 0...1)
        return c * c * (3 - 2 * c)
    }

    static func gate(_ span: RefSpan, at t: Double) -> Double {
        let rise = span.halfIn > 0
            ? smoothstep((t - (span.riseCentre - span.halfIn)) / (2 * span.halfIn))
            : (t >= span.riseCentre ? 1 : 0)
        let fall = span.halfOut > 0
            ? 1 - smoothstep((t - (span.fallCentre - span.halfOut)) / (2 * span.halfOut))
            : (t < span.fallCentre ? 1 : 0)
        return rise * fall
    }

    /// The slide's tilt (§4.b.3), before the gate.
    static func bridge(_ span: RefSpan, at t: Double) -> Double {
        let length = span.end - span.start
        let u = length > 0 ? smoothstep((t - span.start) / length) : 0
        return span.bridgeAmount * (span.bridgeFrom + (span.bridgeTo - span.bridgeFrom) * u)
    }

    /// The span's constant at `t`: its own, plus the tilt when present.
    static func constant(_ span: RefSpan, at t: Double) -> Double {
        var value = span.constant
        if span.bridgeAmount != 0 { value += bridge(span, at: t) }
        return value
    }

    /// The pitch evaluator as a LINEAR SCAN.
    static func linearPitch(_ spans: [RefSpan], clip: Double, at t: Double) -> Double {
        guard t.isFinite, !spans.isEmpty else { return clip }
        var weighted = 0.0
        var totalGate = 0.0
        for span in spans {
            let g = gate(span, at: t)
            if g > 1e-12 {
                // `+ 0.0` is shaping's literal zero, kept so a `-0.0`
                // constant rounds exactly as the shipped loop rounds it.
                let contribution = constant(span, at: t) + 0.0
                weighted += g * contribution
                totalGate += g
            }
        }
        guard totalGate > 1e-12 else { return clip }
        let blended = totalGate > 1 ? weighted / totalGate : weighted
        let total = clip + blended
        return total.isFinite ? total : clip
    }

    /// The formant evaluator (§1(b)) as a LINEAR SCAN.
    static func linearFormant(_ spans: [RefSpan], clip: Double, formantCorrection: Double?,
                              formantPreserve: Bool, at t: Double) -> Double {
        let clipPart = formantPreserve ? 0 : clip
        guard t.isFinite, !spans.isEmpty else { return clipPart }
        let correction = formantCorrection ?? (formantPreserve ? 1 : 0)
        let follow = 1 - correction
        var weighted = 0.0
        var totalGate = 0.0
        for span in spans {
            let g = gate(span, at: t)
            if g > 1e-12 {
                let spanFormant = follow * constant(span, at: t) + span.formantOffset
                weighted += g * spanFormant
                totalGate += g
            }
        }
        guard totalGate > 1e-12 else { return clipPart }
        let blended = totalGate > 1 ? weighted / totalGate : weighted
        let total = clipPart + blended
        return total.isFinite ? total : clipPart
    }
}

// MARK: - Seeded sets and sample points

extension PitchSpanSearchTests {
    /// SplitMix64: seeded, portable, and the same sequence on every run.
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
        mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }
        mutating func logUniform(_ low: Double, _ high: Double) -> Double {
            exp(uniform(log(low), log(high)))
        }
        mutating func chance(_ p: Double) -> Bool { unit() < p }
    }

    static let seed: UInt64 = 0x0925_2026_5BA1_0001
    static let setCount = 200

    /// One random case: a set, the clip transpose, and the formant flag.
    struct Fixture {
        let set: PitchEditSet
        let clip: Double
        let formantPreserve: Bool
    }

    /// Durations 5 ms…3 s (a third of them 5…80 ms, where the clamp bites),
    /// joins abutting / a small gap / a wide gap, pitch and formant offsets
    /// mixed with zeros, and some untouched SOUNDS, which build no span.
    ///
    /// ⚠️ `PitchEditSet.init` CLAMPS `retuneMs` to 30…500 ms. `retuneMs` is a
    /// `public var` with no heal, so a fifth of the sets assign it AFTER init
    /// to reach 0 (the `halfRamp == 0` branch) and 500…1000 ms: beyond what
    /// the product writes, which only widens what the gate covers.
    static func randomFixture(_ rng: inout Rng) -> Fixture {
        let count = 2 + Int(rng.next() % 11)
        var segments: [NoteSegment] = []
        var cursor = rng.uniform(0, 0.8)
        for _ in 0..<count {
            let duration = rng.chance(0.33)
                ? rng.logUniform(0.005, 0.08) : rng.logUniform(0.005, 3)
            let origin: NoteOrigin = rng.chance(0.15) ? .unpitched : .detected
            let cents = rng.chance(0.25) ? 0 : rng.uniform(-1200, 1200)
            let formant = rng.chance(0.5) ? 0 : rng.uniform(-12, 12)
            segments.append(NoteSegment(startSeconds: cursor, endSeconds: cursor + duration,
                                        detectedHz: 220, detectedConfidence: 1,
                                        pitchOffsetCents: cents,
                                        formantOffsetSemitones: formant, origin: origin))
            cursor += duration
            let join = rng.unit()
            if join < 0.45 {
                // abutting: the next start IS this end, the same Double
            } else if join < 0.75 {
                cursor += rng.uniform(0, 0.05)
            } else {
                cursor += rng.uniform(0.05, 1.2)
            }
        }
        var set = PitchEditSet(segments: segments, retuneMs: rng.uniform(30, 500),
                               formantCorrection: rng.chance(0.4) ? nil : rng.unit())
        if rng.chance(0.2) {
            set.retuneMs = rng.chance(0.25) ? 0 : rng.uniform(500, 1000)
        }
        let clip = rng.chance(0.5) ? 0 : rng.uniform(-5, 5)
        return Fixture(set: set, clip: clip, formantPreserve: rng.chance(0.5))
    }

    /// Every edge (`start ± halfRamp`, `end ± halfRamp`, `start`, `end`) with
    /// its two neighbouring Doubles, plus a grid across each boundary scaled
    /// both by the span's OWN half-ramp and by the set's WIDEST one (the
    /// neighbour whose ramp still reaches across it).
    ///
    /// NT-C C4: the halves are per edge (the rise's around the start, the
    /// fall's around the end), and a soft join centred off the note's edge
    /// (an R15 short hole) adds its centre. On a legacy set both halves are
    /// the one half and no centre is off an edge, so the points are exactly
    /// the pre-C4 points, in the same order.
    static func samplePoints(_ spans: [RefSpan]) -> [Double] {
        let widest = spans.map { max($0.halfIn, $0.halfOut) }.max() ?? 0
        var points: [Double] = []
        for span in spans {
            for edge in [span.opening, span.start, span.riseCentre + span.halfIn,
                         span.fallCentre - span.halfOut, span.end, span.reach] {
                points += [edge, edge.nextUp, edge.nextDown]
            }
            for centre in [span.riseCentre, span.fallCentre]
            where centre != span.start && centre != span.end {
                points += [centre, centre.nextUp, centre.nextDown]
            }
            for (boundary, half) in [(span.start, span.halfIn), (span.end, span.halfOut)] {
                for scale in [half, widest] where scale > 0 {
                    for k in -24...24 { points.append(boundary + scale * Double(k) / 20) }
                }
            }
        }
        return points
    }

    /// The two hazards, counted from the reference alone.
    /// * `reach`: a span is open at `t` while a LATER span has already
    ///   closed (`reach ≤ t`), so a search that assumes the reach ascends can
    ///   land past the open one.
    /// * `opening`: a span is open at `t` while an EARLIER span has not
    ///   opened yet (`opening > t`), so an early exit at the earlier one stops
    ///   before the open one.
    static func hazards(_ spans: [RefSpan], at t: Double) -> (reach: Bool, opening: Bool) {
        var reach = false
        var opening = false
        for (i, span) in spans.enumerated() where gate(span, at: t) > 1e-12 {
            if spans[(i + 1)...].contains(where: { $0.reach <= t }) { reach = true }
            if spans[..<i].contains(where: { $0.opening > t }) { opening = true }
        }
        return (reach, opening)
    }

    /// What one G-TWO run saw.
    struct Tally {
        var points = 0
        var mismatches = 0
        var worstDelta = 0.0
        var worstAt = ""
        var reachHazards = 0
        var openingHazards = 0
        var examples: [String] = []

        mutating func record(shipped: Double, reference: Double, set: Int, t: Double) {
            points += 1
            guard shipped.bitPattern != reference.bitPattern else { return }
            mismatches += 1
            let delta = abs(shipped - reference)
            if delta > worstDelta {
                worstDelta = delta
                worstAt = "set \(set) t=\(t)"
            }
            if examples.count < 5 {
                examples.append("set \(set) t=\(t): shipped \(shipped), linear scan \(reference)")
            }
        }
    }
}

// MARK: - G-TWO: both loops against the linear scan

extension PitchSpanSearchTests {
    static func logLine(_ message: String) { print("p2-span| \(message)") }

    /// True when the set's reaches or openings are NOT non-decreasing in
    /// start order: the condition the old search and early exit assumed away.
    static func isNonMonotone(_ spans: [RefSpan]) -> Bool {
        zip(spans, spans.dropFirst()).contains { $0.reach > $1.reach || $0.opening > $1.opening }
    }

    /// Runs `evaluate(curve, fixture, spans, t)` → (shipped, reference) over
    /// every seeded set and sample point. The legacy run takes the defaults
    /// (p2-span's seed and generator, unchanged); NT-C C4's soft run passes
    /// `softSeed` and `randomSoftFixture`.
    static func runGTwo(seed runSeed: UInt64 = PitchSpanSearchTests.seed,
                        generator: (inout Rng) -> Fixture = PitchSpanSearchTests.randomFixture,
                        _ evaluate: (PitchCorrectionCurve, Fixture, [RefSpan], Double)
                        -> (shipped: Double, reference: Double)) -> (Tally, nonMonotoneSets: Int) {
        var rng = Rng(state: runSeed)
        var tally = Tally()
        var nonMonotoneSets = 0
        for index in 0..<setCount {
            let fixture = generator(&rng)
            let curve = PitchCorrectionCurve.make(editSet: fixture.set,
                                                  clipPitchShiftSemitones: fixture.clip)
            let spans = refSpans(fixture.set)
            if isNonMonotone(spans) { nonMonotoneSets += 1 }
            for t in samplePoints(spans) {
                let hazard = hazards(spans, at: t)
                if hazard.reach { tally.reachHazards += 1 }
                if hazard.opening { tally.openingHazards += 1 }
                let pair = evaluate(curve, fixture, spans, t)
                tally.record(shipped: pair.shipped, reference: pair.reference, set: index, t: t)
            }
        }
        return (tally, nonMonotoneSets)
    }

    @Test("G-TWO pitch loop: the shipped evaluator equals a linear scan bit for bit (seeded sets)")
    func pitchLoopMatchesLinearScan() {
        let clock = ContinuousClock()
        let started = clock.now
        let (tally, nonMonotone) = Self.runGTwo { curve, fixture, spans, t in
            (curve.semitones(atSourceSecond: t),
             Self.linearPitch(spans, clip: fixture.clip, at: t))
        }
        Self.logLine("G-TWO pitch: \(tally.points) points, \(Self.setCount) sets (\(nonMonotone) non-monotone), "
                 + "\(tally.mismatches) mismatches, worst |Δ| \(tally.worstDelta * 100) c at \(tally.worstAt); "
                 + "hazard points reach \(tally.reachHazards) opening \(tally.openingHazards); "
                 + "\(clock.now - started)")
        #expect(tally.reachHazards > 0,
                "no point has an open span after a closed one: this fixture cannot catch the search")
        #expect(tally.openingHazards > 0,
                "no point has an open span after an unopened one: this fixture cannot catch the early exit")
        #expect(tally.mismatches == 0,
                "the pitch loop disagrees with the linear scan at \(tally.mismatches) points: \(tally.examples)")
    }

    @Test("G-TWO formant loop: the shipped evaluator equals a linear scan bit for bit (seeded sets)")
    func formantLoopMatchesLinearScan() {
        let clock = ContinuousClock()
        let started = clock.now
        let (tally, nonMonotone) = Self.runGTwo { curve, fixture, spans, t in
            (curve.formantSemitones(atSourceSecond: t, formantPreserve: fixture.formantPreserve),
             Self.linearFormant(spans, clip: fixture.clip,
                                formantCorrection: fixture.set.formantCorrection,
                                formantPreserve: fixture.formantPreserve, at: t))
        }
        Self.logLine("G-TWO formant: \(tally.points) points, \(Self.setCount) sets (\(nonMonotone) non-monotone), "
                 + "\(tally.mismatches) mismatches, worst |Δ| \(tally.worstDelta) st at \(tally.worstAt); "
                 + "hazard points reach \(tally.reachHazards) opening \(tally.openingHazards); "
                 + "\(clock.now - started)")
        #expect(tally.reachHazards > 0,
                "no point has an open span after a closed one: this fixture cannot catch the search")
        #expect(tally.openingHazards > 0,
                "no point has an open span after an unopened one: this fixture cannot catch the early exit")
        #expect(tally.mismatches == 0,
                "the formant loop disagrees with the linear scan at \(tally.mismatches) points: \(tally.examples)")
    }
}

// MARK: - G-MAG: three fixed cases, swept at 0.1 ms

extension PitchSpanSearchTests {
    static func note(_ start: Double, _ end: Double, cents: Double) -> NoteSegment {
        NoteSegment(startSeconds: start, endSeconds: end, detectedHz: 220,
                    detectedConfidence: 1, pitchOffsetCents: cents)
    }

    /// What one sweep saw. `worstCents` is `linear scan − shipped` in cents at
    /// the worst point: the contribution the shipped evaluator left out.
    struct Sweep {
        var worstCents = 0.0
        var worstAt = Double.nan
        var gatesAtWorst: [Double] = []
        /// Sample points (0.1 ms apart) where the pitch loop differs, and the
        /// first and last of them.
        var differing = 0
        var firstDiffering = Double.nan
        var lastDiffering = Double.nan
        var formantMismatches = 0
        var hazardPoints = 0

        var summary: String {
            let window = differing == 0 ? "none"
                : String(format: "%.4f…%.4f s (%d points at 0.1 ms)", firstDiffering, lastDiffering, differing)
            let gates = gatesAtWorst.map { String(format: "%.4f", $0) }.joined(separator: ", ")
            return String(format: "worst skipped contribution %.3f c at t=%.4f s ", worstCents, worstAt)
                + "(gates there: [\(gates)]); "
                + "differing window \(window); formant mismatches \(formantMismatches); "
                + "hazard points \(hazardPoints)"
        }
    }

    /// Both loops against the linear scan, at `low + i · 0.1 ms` (index-built,
    /// never accumulated) and at every edge.
    static func sweep(_ set: PitchEditSet, from low: Double, to high: Double) -> Sweep {
        let curve = PitchCorrectionCurve.make(editSet: set)
        let spans = refSpans(set)
        var points = (0...Int(((high - low) / 1e-4).rounded())).map { low + Double($0) * 1e-4 }
        for span in spans {
            for edge in [span.opening, span.start, span.end, span.reach] {
                points += [edge, edge.nextUp, edge.nextDown]
            }
        }
        var result = Sweep()
        for t in points.sorted() {
            let hazard = hazards(spans, at: t)
            if hazard.reach || hazard.opening { result.hazardPoints += 1 }
            let shipped = curve.semitones(atSourceSecond: t)
            let reference = linearPitch(spans, clip: 0, at: t)
            if shipped.bitPattern != reference.bitPattern {
                result.differing += 1
                if result.firstDiffering.isNaN { result.firstDiffering = t }
                result.lastDiffering = t
                let cents = (reference - shipped) * 100
                if abs(cents) > abs(result.worstCents) {
                    result.worstCents = cents
                    result.worstAt = t
                    result.gatesAtWorst = spans.map { gate($0, at: t) }
                }
            }
            let formant = curve.formantSemitones(atSourceSecond: t, formantPreserve: false)
            let formantReference = linearFormant(spans, clip: 0, formantCorrection: set.formantCorrection,
                                                 formantPreserve: false, at: t)
            if formant.bitPattern != formantReference.bitPattern { result.formantMismatches += 1 }
        }
        return result
    }

    /// NT-G's fixture, `NaturalTuningBaselineTests.f12AsymmetricRampDip`: a
    /// 2 s note then a 60 ms note, both +300 c, retune 200 ms. Reaches
    /// `[2.1, 2.09]`: the SEARCH's hazard.
    @Test("G-MAG NT-G fixture: a 60 ms note after a 2 s note, retune 200 ms")
    func ntgFixture() {
        let set = PitchEditSet(segments: [Self.note(0, 2, cents: 300),
                                          Self.note(2, 2.06, cents: 300)], retuneMs: 200)
        let result = Self.sweep(set, from: 1.8, to: 2.2)
        Self.logLine("G-MAG NT-G (2 s +300 c, 60 ms +300 c, retune 200): \(result.summary)")
        #expect(result.hazardPoints > 0, "the fixture no longer contains the non-monotone reach")
        #expect(result.differing == 0 && result.formantMismatches == 0, "\(result.summary)")
    }

    /// The orchestrator's 500 ms case: a 2 s note moved +100 c, a 20 ms
    /// neighbour, then a 1 s note, both unmoved, all abutting, retune 500 ms.
    /// Reaches `[2.25, 2.03, 3.27]`: the long note's fall is the search's
    /// hazard. The skipped contribution scales with the long note's move.
    @Test("G-MAG 500 ms case: 2 s (+100 c), 20 ms, 1 s, retune 500 ms")
    func fiveHundredMillisecondCase() {
        let set = PitchEditSet(segments: [Self.note(0, 2, cents: 100),
                                          Self.note(2, 2.02, cents: 0),
                                          Self.note(2.02, 3.02, cents: 0)], retuneMs: 500)
        let result = Self.sweep(set, from: 1.5, to: 2.5)
        Self.logLine("G-MAG 500 ms (2 s +100 c, 20 ms 0 c, 1 s 0 c, retune 500): \(result.summary)")
        #expect(result.hazardPoints > 0, "the fixture no longer contains the non-monotone reach")
        #expect(result.differing == 0 && result.formantMismatches == 0, "\(result.summary)")
    }

    /// The EARLY EXIT's case, the mirror image: a 1 s note, a 20 ms
    /// neighbour, then a 2 s note moved +100 c, all abutting, retune 500 ms.
    /// Openings `[−0.25, 0.99, 0.77]`: the long note's rise opens BEFORE the
    /// short note's, and the old exit stopped at the short note.
    @Test("G-MAG early exit: 1 s, 20 ms, 2 s (+100 c), retune 500 ms")
    func earlyExitCase() {
        let set = PitchEditSet(segments: [Self.note(0, 1, cents: 0),
                                          Self.note(1, 1.02, cents: 0),
                                          Self.note(1.02, 3.02, cents: 100)], retuneMs: 500)
        let result = Self.sweep(set, from: 0.5, to: 1.5)
        Self.logLine("G-MAG early exit (1 s 0 c, 20 ms 0 c, 2 s +100 c, retune 500): \(result.summary)")
        #expect(result.hazardPoints > 0, "the fixture no longer contains the non-monotone opening")
        #expect(result.differing == 0 && result.formantMismatches == 0, "\(result.summary)")
    }
}

// MARK: - G-TWO with SOFT joins (NT-C C4, natural tuning §4.g + R15)

extension PitchSpanSearchTests {
    /// A SECOND seed and generator. ⚠️ The legacy run's seed and draw order
    /// are untouched on purpose: its 200 sets, its hazard counts and its
    /// "0 mismatches" are the anchor that legacy stayed bit-identical.
    static let softSeed: UInt64 = 0x0925_2026_C4C4_0001

    /// Like `randomFixture`, plus everything §4 reads: a slope (a fifth of
    /// the sets 0, so a set is soft only through a width or a follow), join
    /// widths (the healing `init` raises < 30 ms and lowers > 1000 ms),
    /// follow amounts (half of them exactly 1), R15 SHORT HOLES (0-64 ms, a
    /// third of the joins), holes just past the threshold, and SOUNDS, half
    /// of them untouched (no span: the join is between the notes around
    /// them, and the sound's length is the gap).
    static func randomSoftFixture(_ rng: inout Rng) -> Fixture {
        let count = 2 + Int(rng.next() % 11)
        var segments: [NoteSegment] = []
        var cursor = rng.uniform(0, 0.8)
        for _ in 0..<count {
            let duration = rng.chance(0.33)
                ? rng.logUniform(0.005, 0.08) : rng.logUniform(0.005, 3)
            let origin: NoteOrigin = rng.chance(0.15) ? .unpitched : .detected
            var cents = rng.chance(0.25) ? 0 : rng.uniform(-1200, 1200)
            if origin == .unpitched && rng.chance(0.5) { cents = 0 }
            let formant = rng.chance(0.5) ? 0 : rng.uniform(-12, 12)
            let width = rng.chance(0.6) ? 0 : rng.uniform(1, 1100)
            let follow = rng.chance(0.6) ? 0 : (rng.chance(0.5) ? 1 : rng.unit())
            segments.append(NoteSegment(startSeconds: cursor, endSeconds: cursor + duration,
                                        detectedHz: 220, detectedConfidence: 1,
                                        pitchOffsetCents: cents,
                                        formantOffsetSemitones: formant,
                                        transitionOutMs: width, glideFollow: follow,
                                        origin: origin))
            cursor += duration
            let join = rng.unit()
            if join < 0.4 {
                // abutting: the next start IS this end, the same Double
            } else if join < 0.75 {
                cursor += rng.uniform(0, PitchEditSet.consonantMinimumGapSeconds)
            } else if join < 0.85 {
                cursor += rng.uniform(PitchEditSet.consonantMinimumGapSeconds, 0.1)
            } else {
                cursor += rng.uniform(0.1, 1.2)
            }
        }
        let slope = rng.chance(0.2) ? 0 : rng.logUniform(300, 25_000)
        var set = PitchEditSet(segments: segments, retuneMs: rng.uniform(30, 500),
                               formantCorrection: rng.chance(0.4) ? nil : rng.unit(),
                               transitionSlopeCentsPerSecond: slope)
        if rng.chance(0.2) {
            set.retuneMs = rng.chance(0.25) ? 0 : rng.uniform(500, 1000)
        }
        let clip = rng.chance(0.5) ? 0 : rng.uniform(-5, 5)
        return Fixture(set: set, clip: clip, formantPreserve: rng.chance(0.5))
    }

    /// The §4 features the soft fixture must actually contain, counted from
    /// the mirror over the SAME seeded sets.
    struct SoftFeatures {
        var widthJoins = 0
        var shortHoleJoins = 0
        var bridges = 0
        var softSets = 0
    }

    static func softFeatures() -> SoftFeatures {
        var rng = Rng(state: softSeed)
        var features = SoftFeatures()
        for _ in 0..<setCount {
            let set = randomSoftFixture(&rng).set
            let spans = refSpans(set)
            if set.transitionSlopeCentsPerSecond > 0
                || set.segments.contains(where: { $0.transitionOutMs != 0 || $0.glideFollow != 0 }) {
                features.softSets += 1
            }
            features.widthJoins += spans.filter(\.softOut).count
            features.shortHoleJoins += spans.filter { $0.softOut && $0.fallCentre != $0.end }.count
            features.bridges += spans.filter {
                $0.bridgeAmount != 0 && ($0.bridgeFrom != 0 || $0.bridgeTo != 0)
            }.count
        }
        return features
    }

    @Test("G-TWO soft pitch loop: with soft joins, widths, follows and short holes, the evaluator equals a linear scan bit for bit")
    func softPitchLoopMatchesLinearScan() {
        let features = Self.softFeatures()
        let (tally, nonMonotone) = Self.runGTwo(seed: Self.softSeed,
                                                generator: Self.randomSoftFixture) { curve, fixture, spans, t in
            (curve.semitones(atSourceSecond: t),
             Self.linearPitch(spans, clip: fixture.clip, at: t))
        }
        Self.logLine("G-TWO soft pitch: \(tally.points) points, \(Self.setCount) sets "
                     + "(\(features.softSets) soft, \(nonMonotone) non-monotone), "
                     + "\(features.widthJoins) width joins, \(features.shortHoleJoins) short-hole joins, "
                     + "\(features.bridges) bridges; \(tally.mismatches) mismatches, worst |Δ| "
                     + "\(tally.worstDelta * 100) c at \(tally.worstAt); hazard points reach "
                     + "\(tally.reachHazards) opening \(tally.openingHazards)")
        // The fixture must contain what it claims to test.
        #expect(features.softSets > 100, "too few soft sets: \(features.softSets)")
        #expect(features.widthJoins > 0 && features.shortHoleJoins > 0 && features.bridges > 0,
                "the soft fixture lost a §4 feature: \(features)")
        #expect(tally.mismatches == 0,
                "the pitch loop disagrees with the linear scan on soft sets at \(tally.mismatches) points: \(tally.examples)")
    }

    @Test("G-TWO soft formant loop: the formant evaluator follows the same soft gates and tilts, bit for bit")
    func softFormantLoopMatchesLinearScan() {
        let (tally, _) = Self.runGTwo(seed: Self.softSeed,
                                      generator: Self.randomSoftFixture) { curve, fixture, spans, t in
            (curve.formantSemitones(atSourceSecond: t, formantPreserve: fixture.formantPreserve),
             Self.linearFormant(spans, clip: fixture.clip,
                                formantCorrection: fixture.set.formantCorrection,
                                formantPreserve: fixture.formantPreserve, at: t))
        }
        Self.logLine("G-TWO soft formant: \(tally.points) points, \(tally.mismatches) mismatches, "
                     + "worst |Δ| \(tally.worstDelta) st at \(tally.worstAt)")
        #expect(tally.points > 0)
        #expect(tally.mismatches == 0,
                "the formant loop disagrees with the linear scan on soft sets at \(tally.mismatches) points: \(tally.examples)")
    }
}
