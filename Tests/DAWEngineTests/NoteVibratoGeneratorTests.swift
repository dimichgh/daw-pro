import CryptoKit
import CSignalsmithStretch
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// m23-ap Phase 2 / C5a — THE SYNTHESISED PER-NOTE VIBRATO GENERATOR.
///
/// `docs/design/2026-09-22-pitch-editor-ui.md` §7.5 conflict 2: `vibratoScale`
/// is a MULTIPLIER on the detected contour, so it can change how deep an
/// existing wobble is and can never change its RATE — and on a note sung
/// without vibrato it yields nothing however large it gets. The reference
/// app's readout goes `Vibrato 5.5 Hz ±93 c` → `Vibrato 7.8 Hz ±32 c`. That is
/// SYNTHESIS, and it needed a representation, not a control.
///
/// Reading order is enforced by the section comments, and it is the project's
/// law rather than a preference:
///
///  1. **§A — THE INVARIANCE CONTROL, BUILT BEFORE THE FEATURE.** The goldens
///     below were captured by running this file against the tree as it stood
///     BEFORE `vibratoRateHz` existed, and only then were the fields added. An
///     inert generator must render BIT-IDENTICALLY and digest IDENTICALLY, or
///     every cached render in every existing project is silently stale.
///  2. **§B — the hop grid**, arithmetic only, no stretcher. What a 30 ms
///     zero-order hold does to a 5.5 Hz and a 7.8 Hz sine — including the one
///     parameter it makes UNMEASURABLE, which is why no `shape` field shipped.
///  3. **§C — the physics.** Distinct bytes prove nothing. A request for
///     5.5 Hz ±93 c is tracked back OUT of the rendered audio and compared to
///     what was asked, against the instrument's own control on the same
///     modulation with no stretcher in the loop.
///
/// Deliberately NOT `@MainActor` — DSP has no business there, and
/// `MainActorOccupancySiteTests` Leg C bounds `@MainActor` suites (a review cadence).
@Suite("m23-ap C5a — synthesised per-note vibrato")
struct NoteVibratoGeneratorTests {
    static let sampleRate = 48_000.0
    static let baseHz = 220.0
    static let amplitude: Float = 0.8

    /// MEASURED by `OfflineStretcherCurveTests.hopIsMeasuredNotDerived`
    /// (`css_interval_samples`, 1440 at 48 kHz). Restated as a Double because
    /// §B is arithmetic over it; §B asserts it against the stretcher rather
    /// than trusting this literal.
    static let hopFrames = 1440.0
    /// 33.333… curve updates per second — the rate the generator is actually
    /// sampled at.
    static var hopRateHz: Double { sampleRate / hopFrames }

    static func log(_ leg: String, _ message: String) {
        print("m23-ap-C5a|\(leg)| \(message)")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - §A — THE INVARIANCE CONTROL
    // ═══════════════════════════════════════════════════════════════════════

    /// Fixed UUIDs: a golden over a digest is worthless if the material moves.
    static let idA = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    static let idB = UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!

    /// A plain corrected note — the shape `PitchAutoCorrect` produces, and the
    /// one every existing project on disk contains.
    static func legacyOffsetSet() -> PitchEditSet {
        PitchEditSet(
            analysisVersion: 1,
            segments: [
                NoteSegment(id: idA, startSeconds: 0.25, endSeconds: 1.25,
                            detectedHz: 220, detectedConfidence: 0.9,
                            pitchOffsetCents: -37.5),
                NoteSegment(id: idB, startSeconds: 1.25, endSeconds: 1.9,
                            detectedHz: 233.08, detectedConfidence: 0.81,
                            pitchOffsetCents: 22.0),
            ],
            retuneMs: 45)
    }

    /// A set that asks for SHAPING with no contour to shape — the `.hardTune`
    /// shape, which reaches `unresolvedShapingSegmentIDs` today.
    static func legacyShapingSet() -> PitchEditSet {
        PitchEditSet(
            analysisVersion: 1,
            segments: [
                NoteSegment(id: idA, startSeconds: 0.25, endSeconds: 1.25,
                            detectedHz: 220, detectedConfidence: 0.9,
                            pitchOffsetCents: -37.5,
                            driftScale: 0, vibratoScale: 0),
            ],
            retuneMs: 30)
    }

    // ⭐ CAPTURED ON THE PRE-FEATURE TREE, 2026-09-23, and reproduced on a
    // second run before being written down (a golden that is not deterministic
    // is a flake with a hex string). If one of these ever needs "updating",
    // the change under it is not inert and the claim in this suite's banner is
    // false.
    static let goldenDigestOffset =
        "ec8e1bd8e04e4d8a6861e27ed620ff5772422fee40b8c6fd886e9e712ca77f6a"
    static let goldenDigestShaping =
        "1102f9a9e5bc74e92a449ed9a4a9ee28fe93915fd7e43922ce38bc2318c84a8a"
    static let goldenRenderOffset =
        "7a2a181ea40398a5373f250eb3abbc6991ecec2d6bda2385372a34a412c3839b"
    static let goldenRenderShaping =
        "3493573ab3845c0477f58cf4ccb4008d6c4b8804e6d7c7f507dc373f1a00497b"
    /// The curve at six source seconds, captured on the same pre-feature tree.
    /// The render SHA says "something changed"; these say WHERE.
    static let goldenCurveSamples: [(Double, Double)] = [
        (0.0, 0.0),
        (0.25, -0.18749999999999992),
        (0.5, -0.375),
        (1.25, -0.07750000000000067),
        (1.9, 0.11000000000000025),
        (2.5, 0.0),
    ]

    /// SHA256 over the raw bit patterns of a rendered channel. Bit patterns,
    /// never a string of the values: `-0.0` and `0.0` compare EQUAL as Floats
    /// and are different bytes, and this gate exists to catch exactly that.
    static func renderDigest(_ channel: [Float]) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(channel.count * 4)
        for sample in channel {
            withUnsafeBytes(of: sample.bitPattern.littleEndian) {
                bytes.append(contentsOf: $0)
            }
        }
        var hasher = SHA256()
        hasher.update(data: Data(bytes))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Render a sine through the SHIPPING path — `StretchCurvePlan` +
    /// `stretchTransposeCurve` with the shipping compensation, which is
    /// exactly what `StretchRenderCache.performRender` does.
    static func renderThroughShippingPath(_ set: PitchEditSet,
                                          seconds: Double = 2.0) throws -> [Float] {
        let frames = Int(sampleRate * seconds)
        let input = [M23QSignal.sine(hz: baseHz, frames: frames,
                                     sampleRate: sampleRate, amplitude: amplitude)]
        let plan = try #require(StretchCurvePlan.make(
            editSet: set, clipPitchShiftSemitones: 0,
            sampleRate: sampleRate, ratio: 1))
        return try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: 1,
            semitonesAtOutputFrame: { plan.semitones(atOutputFrame: $0) },
            formantPreserve: false,
            compensation: OfflineStretcher.curveLatencyCompensation(
                sampleRate: sampleRate))[0]
    }

    /// ⭐⭐ **THE GATE THE WHOLE FEATURE STANDS ON.** A project saved before
    /// the generator existed must render the same audio and key the same cache
    /// entry after it exists.
    @Test("§A a legacy edit set digests and renders EXACTLY as it did pre-generator")
    func inertGeneratorIsBitIdentical() throws {
        #expect(PitchEditSetDigest.hex(Self.legacyOffsetSet()) == Self.goldenDigestOffset,
                """
                the digest of a generator-free edit set MOVED. Every render \
                cache entry on every existing disk is now orphaned. The \
                generator's fields must be hashed in the suffix block, which \
                is emitted only when a segment carries one.
                """)
        #expect(PitchEditSetDigest.hex(Self.legacyShapingSet()) == Self.goldenDigestShaping)

        let offsetRender = try Self.renderThroughShippingPath(Self.legacyOffsetSet())
        let shapingRender = try Self.renderThroughShippingPath(Self.legacyShapingSet())
        #expect(offsetRender.count == 96_000)
        #expect(Self.renderDigest(offsetRender) == Self.goldenRenderOffset,
                """
                a generator-free edit set no longer renders BIT-IDENTICALLY. \
                Got \(Self.renderDigest(offsetRender)). The curve's generator \
                term must be added inside a branch, never as `+ 0.0`.
                """)
        #expect(Self.renderDigest(shapingRender) == Self.goldenRenderShaping)

        // Localise: the SHA says "changed", these say WHERE.
        let curve = PitchCorrectionCurve.make(editSet: Self.legacyOffsetSet())
        for (t, expected) in Self.goldenCurveSamples {
            let actual = curve.semitones(atSourceSecond: t)
            #expect(actual.bitPattern == expected.bitPattern,
                    """
                    curve(\(t)) was \(expected) before the generator existed \
                    and is \(actual) now — not merely close, DIFFERENT BITS.
                    """)
        }
    }

    /// ⭐ **THE NEGATIVE CONTROL FOR §A ITSELF.** A gate that has never been
    /// seen to fail is a decoration. The same goldens, against a set that
    /// carries a generator: both the digest and the render MUST differ, or the
    /// gate above cannot tell inert from active and its pass means nothing.
    @Test("§A control — the same goldens DO reject a set that carries a generator")
    func invarianceGateCanFail() throws {
        var set = Self.legacyOffsetSet()
        set.segments[0].vibratoDepthCents = 40
        set.segments[0].vibratoRateHz = 5.5
        #expect(PitchEditSetDigest.hex(set) != Self.goldenDigestOffset)
        let rendered = try Self.renderThroughShippingPath(set)
        #expect(Self.renderDigest(rendered) != Self.goldenRenderOffset)
        // And the curve moved where the generator is, at a time inside the note.
        let before = PitchCorrectionCurve.make(editSet: Self.legacyOffsetSet())
        let after = PitchCorrectionCurve.make(editSet: set)
        #expect(before.semitones(atSourceSecond: 0.7)
            != after.semitones(atSourceSecond: 0.7))
    }

    /// The persistence half of "byte-identical on LOAD": a payload written
    /// before the three keys existed decodes to an inert generator, and
    /// re-encoding it does not grow the keys.
    @Test("§A a pre-generator payload round-trips without growing keys")
    func legacyPayloadRoundTripsWithoutNewKeys() throws {
        let legacy = """
            {"analysisVersion":1,"segments":[{"id":"\(Self.idA.uuidString)",\
            "startSeconds":0.25,"endSeconds":1.25,"detectedHz":220,\
            "detectedConfidence":0.9,"pitchOffsetCents":-37.5}],"retuneMs":45}
            """
        let decoded = try JSONDecoder().decode(
            PitchEditSet.self, from: Data(legacy.utf8))
        let segment = try #require(decoded.segments.first)
        #expect(segment.vibratoRateHz == 0)
        #expect(segment.vibratoDepthCents == 0)
        #expect(segment.vibratoOnsetSeconds == 0)

        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        for key in ["vibratoRateHz", "vibratoDepthCents", "vibratoOnsetSeconds"] {
            #expect(!reencoded.contains(key),
                    """
                    re-saving a pre-generator project grew the key \(key). \
                    Omit-when-default is what keeps an untouched project's \
                    bytes untouched.
                    """)
        }
        // ⭐ POSITIVE CONTROL for the matcher: it CAN find those keys.
        var active = decoded
        active.segments[0].vibratoRateHz = 5.5
        active.segments[0].vibratoDepthCents = 93
        active.segments[0].vibratoOnsetSeconds = 0.2
        let activeJSON = String(decoding: try JSONEncoder().encode(active), as: UTF8.self)
        for key in ["vibratoRateHz", "vibratoDepthCents", "vibratoOnsetSeconds"] {
            #expect(activeJSON.contains(key))
        }
        // And a full round trip preserves them, including through the digest.
        let reloaded = try JSONDecoder().decode(
            PitchEditSet.self, from: Data(activeJSON.utf8))
        #expect(reloaded.segments[0].vibratoDepthCents == 93)
        #expect(PitchEditSetDigest.hex(reloaded) == PitchEditSetDigest.hex(active))
    }

    /// §6.4's rule as an identity question, and the half of it that departs
    /// from the phase-3/4 precedent on purpose.
    @Test("§A depth breaks identity; a rate or onset ALONE deliberately does not")
    func identityFollowsDepthAlone() {
        func segment(_ mutate: (inout NoteSegment) -> Void) -> NoteSegment {
            var s = NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 440,
                                detectedConfidence: 0.9)
            mutate(&s)
            return s
        }
        // Baseline, so the three below measure the field and not a broken
        // predicate.
        #expect(segment { _ in }.isIdentity)

        #expect(!segment { $0.vibratoDepthCents = 25 }.isIdentity)
        #expect(segment { $0.vibratoDepthCents = 25 }.hasGeneratedVibrato)

        // Rate/onset with no depth: INERT, and that is the point — a UI
        // holding a half-set control must not push an untouched clip through
        // a stretch render.
        let rateOnly = segment { $0.vibratoRateHz = 7.8 }
        let onsetOnly = segment { $0.vibratoOnsetSeconds = 0.4 }
        #expect(rateOnly.isIdentity)
        #expect(onsetOnly.isIdentity)
        #expect(!rateOnly.hasGeneratedVibrato)
        #expect(PitchEditSetDigest.hex(PitchEditSet(segments: [rateOnly])).isEmpty)
        #expect(!Clip(name: "c", pitchEdits: PitchEditSet(segments: [rateOnly]))
            .hasPitchEdits)
        // ⭐ And PROVE the inertness rather than asserting it: a rate with no
        // depth must evaluate to the same curve as no rate at all, at a dense
        // sweep of times inside the note.
        let none = PitchCorrectionCurve.make(editSet: PitchEditSet(segments: [
            segment { _ in }]))
        let rated = PitchCorrectionCurve.make(editSet: PitchEditSet(segments: [rateOnly]))
        for step in 0...200 {
            let t = Double(step) / 200
            #expect(none.semitones(atSourceSecond: t).bitPattern
                == rated.semitones(atSourceSecond: t).bitPattern)
        }
    }

    /// Damaged input degrades to INERT, never to a wobble nobody asked for.
    @Test("§A non-finite and out-of-range generator values heal to inert or to the clamp")
    func generatorSanitises() {
        let poisoned = NoteSegment(
            startSeconds: 0, endSeconds: 1, detectedHz: 440, detectedConfidence: 0.9,
            vibratoRateHz: .nan, vibratoDepthCents: .infinity,
            vibratoOnsetSeconds: -.infinity)
        #expect(poisoned.vibratoRateHz == 0)
        #expect(poisoned.vibratoDepthCents == 0)
        #expect(poisoned.vibratoOnsetSeconds == 0)
        #expect(poisoned.isIdentity)

        let clamped = NoteSegment(
            startSeconds: 0, endSeconds: 1, detectedHz: 440, detectedConfidence: 0.9,
            vibratoRateHz: 900, vibratoDepthCents: -5, vibratoOnsetSeconds: 50)
        #expect(clamped.vibratoRateHz == NoteSegment.vibratoRateHzRange.upperBound)
        #expect(clamped.vibratoDepthCents == 0)
        #expect(clamped.vibratoOnsetSeconds == NoteSegment.vibratoOnsetSecondsRange.upperBound)

        // A NaN must never reach the curve, whatever the caller does.
        let curve = PitchCorrectionCurve.make(editSet: PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 440,
                        detectedConfidence: 1, vibratoRateHz: 5.5,
                        vibratoDepthCents: 93)]))
        for step in 0...500 {
            #expect(curve.semitones(atSourceSecond: Double(step) / 250).isFinite)
        }
        #expect(curve.semitones(atSourceSecond: .nan).isFinite)
        #expect(curve.semitones(atSourceSecond: .infinity).isFinite)
    }

    /// The phase anchor, pinned by the case that chose it: splitting a note
    /// into two must not restart the vibrato.
    @Test("§A the generator is phase-continuous across a split")
    func generatorIsContinuousAcrossASplit() {
        func set(_ segments: [NoteSegment]) -> PitchEditSet {
            PitchEditSet(segments: segments, retuneMs: 30)
        }
        func note(_ start: Double, _ end: Double) -> NoteSegment {
            NoteSegment(startSeconds: start, endSeconds: end, detectedHz: 220,
                        detectedConfidence: 1, vibratoRateHz: 5.5,
                        vibratoDepthCents: 93)
        }
        let whole = PitchCorrectionCurve.make(editSet: set([note(1.0, 3.0)]))
        let split = PitchCorrectionCurve.make(
            editSet: set([note(1.0, 2.0), note(2.0, 3.0)]))

        // Away from the split's ramp the two must AGREE — not merely be
        // continuous. A start-anchored phase would put the second half a
        // whole different phase off.
        var worst = 0.0
        for step in 0...400 {
            let t = 1.1 + Double(step) / 400 * 0.75  // 1.10 … 1.85, inside half 1
            worst = max(worst, abs(whole.semitones(atSourceSecond: t)
                - split.semitones(atSourceSecond: t)))
        }
        for step in 0...400 {
            let t = 2.15 + Double(step) / 400 * 0.75  // 2.15 … 2.90, inside half 2
            worst = max(worst, abs(whole.semitones(atSourceSecond: t)
                - split.semitones(atSourceSecond: t)))
        }
        Self.log("A", "split vs whole: worst disagreement \(worst * 100) cents")
        #expect(worst < 1e-12,
                """
                splitting a note changed its vibrato by \(worst * 100) cents. \
                The generator's phase must be anchored at source second 0, not \
                at the segment start.
                """)

        // ⭐ CONTROL: the comparison CAN show a disagreement. Move one half's
        // start by a quarter period and the same sweep must light up.
        // Same construction as `split` on purpose: the SENSITIVITY being
        // probed is the comparison's, not a second curve's. Shifting the
        // QUERY time by a quarter period is what stands in for a phase error.
        let sameSplit = split
        var shiftedWorst = 0.0
        for step in 0...400 {
            let t = 2.15 + Double(step) / 400 * 0.75
            shiftedWorst = max(shiftedWorst,
                               abs(whole.semitones(atSourceSecond: t + 1 / (4 * 5.5))
                                   - sameSplit.semitones(atSourceSecond: t)))
        }
        #expect(shiftedWorst > 0.5,
                """
                the split comparison cannot detect a phase difference at all — \
                a quarter-period offset moved it by only \(shiftedWorst * 100) \
                cents, so the pass above is meaningless.
                """)
    }

    /// The onset envelope: a fade that actually fades, measured on the curve.
    @Test("§A the onset fade reaches full depth at the onset time and not before")
    func onsetFadesIn() {
        func peak(in range: ClosedRange<Double>, _ curve: PitchCorrectionCurve) -> Double {
            var m = 0.0
            for step in 0...2000 {
                let t = range.lowerBound
                    + (range.upperBound - range.lowerBound) * Double(step) / 2000
                m = max(m, abs(curve.semitones(atSourceSecond: t)))
            }
            return m * 100  // cents
        }
        // A long note so the boundary ramp (30 ms) cannot be confused with the
        // onset fade (1 s).
        let faded = PitchCorrectionCurve.make(editSet: PitchEditSet(segments: [
            NoteSegment(startSeconds: 1, endSeconds: 5, detectedHz: 220,
                        detectedConfidence: 1, vibratoRateHz: 5.5,
                        vibratoDepthCents: 80, vibratoOnsetSeconds: 1.0)]))
        let immediate = PitchCorrectionCurve.make(editSet: PitchEditSet(segments: [
            NoteSegment(startSeconds: 1, endSeconds: 5, detectedHz: 220,
                        detectedConfidence: 1, vibratoRateHz: 5.5,
                        vibratoDepthCents: 80)]))
        let early = peak(in: 1.05...1.3, faded)
        let late = peak(in: 2.5...4.5, faded)
        let controlEarly = peak(in: 1.05...1.3, immediate)
        Self.log("A", "onset 1.0 s: peak in 1.05–1.30 s = \(early) c, in 2.5–4.5 s = "
            + "\(late) c; with NO onset the same early window peaks at \(controlEarly) c")
        #expect(late > 78 && late < 81)
        #expect(early < 20)
        // ⭐ CONTROL: without the onset the SAME early window is already at
        // full depth, so `early < 20` is measuring the fade and not the window.
        #expect(controlEarly > 75)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - §B — what the 30 ms hop does to a generated sine
    // ═══════════════════════════════════════════════════════════════════════

    /// ⭐ **THE HOP IS THE LIMIT, AND IT IS READ FROM THE STRETCHER.** Every
    /// number in §B is arithmetic over this; a literal 1440 here would be the
    /// drift the suite exists to catch.
    @Test("§B the curve-update rate is the stretcher's own hop")
    func hopRateIsMeasured() throws {
        let handle = try #require(css_create(1, Float(Self.sampleRate), 1))
        defer { css_destroy(handle) }
        let interval = Double(css_interval_samples(handle))
        #expect(interval == Self.hopFrames)
        let nyquist = Self.sampleRate / interval / 2
        Self.log("B", "hop \(interval) frames = \(interval / Self.sampleRate * 1000) ms; "
            + "curve updates \(Self.sampleRate / interval) Hz; ALIAS LIMIT \(nyquist) Hz")
        #expect(NoteSegment.vibratoRateHzRange.upperBound < nyquist,
                """
                the shipped rate ceiling (\(NoteSegment.vibratoRateHzRange.upperBound) \
                Hz) is at or above the hop grid's Nyquist (\(nyquist) Hz). Above \
                it a request does not come back shallow, it comes back as a \
                DIFFERENT, LOWER rate.
                """)
    }

    /// Zero-order-hold the ideal generator at the hop grid and measure what
    /// the renderer is actually handed — before the stretcher ever sees it.
    ///
    /// ⭐ This separates two things that would otherwise be one number: what
    /// the HOP does, and what the STRETCHER does. §C measures the chain; this
    /// measures the half of it that is pure arithmetic and can be predicted.
    @Test("§B a 7.8 Hz sine on a 33 Hz grid: per-cycle depth swings while the mean holds")
    func hopStaircaseAtSevenPointEight() {
        for rate in [5.5, 7.8] {
            let depth = 93.0
            let seconds = 4.0
            let hopsPerCycle = Self.hopRateHz / rate
            // The value the renderer is handed at each hop, for 4 s.
            let hops = Int(seconds * Self.hopRateHz)
            var held: [(t: Double, cents: Double)] = []
            for h in 0..<hops {
                let t = Double(h) / Self.hopRateHz
                held.append((t, depth * sin(2 * .pi * rate * t)))
            }
            // Per-cycle extremes: how deep does an INDIVIDUAL cycle come back?
            var cyclePeaks: [Double] = []
            let cycles = Int(seconds * rate)
            for c in 0..<cycles {
                let lo = Double(c) / rate
                let hi = Double(c + 1) / rate
                let inCycle = held.filter { $0.t >= lo && $0.t < hi }.map(\.cents)
                guard let top = inCycle.max(), let bottom = inCycle.min() else { continue }
                cyclePeaks.append((top - bottom) / 2)
            }
            let shallowest = cyclePeaks.min() ?? .nan
            let deepest = cyclePeaks.max() ?? .nan
            // The FITTED fundamental of the held series — what an averaging
            // instrument (and the ear) reads.
            let fit = M23QToneTracker.fitSinusoid(
                held.map { (frame: $0.t * Self.sampleRate, value: $0.cents) },
                rateHz: rate, sampleRate: Self.sampleRate)
            let fitted = fit?.amplitude ?? .nan
            // Textbook zero-order-hold droop, for comparison.
            let x = rate / Self.hopRateHz
            let zoh = sin(.pi * x) / (.pi * x)

            Self.log("B", "\(rate) Hz: \(hopsPerCycle) hops/cycle; per-CYCLE half-depth "
                + "\(shallowest)…\(deepest) c of \(depth) requested (spread "
                + "\((deepest - shallowest) / depth * 100) % of depth); FITTED "
                + "fundamental \(fitted) c (\(fitted / depth)× of asked); textbook "
                + "ZOH droop sinc(f/fs) = \(zoh)")

            // The claim: the AVERAGE survives the grid, the INDIVIDUAL CYCLE
            // does not. Both halves asserted, because only stating the
            // friendly one would be the decoration this suite exists to avoid.
            #expect(fitted / depth > 0.85 && fitted / depth < 1.02,
                    """
                    the held series' fitted fundamental is \(fitted / depth)× of \
                    the \(depth) c requested at \(rate) Hz — outside the band the \
                    zero-order hold predicts (\(zoh)).
                    """)
            #expect(shallowest < depth * 0.95,
                    """
                    at \(hopsPerCycle) samples per cycle an individual cycle \
                    cannot reach full depth, yet the shallowest measured \
                    \(shallowest) of \(depth). The grid arithmetic is wrong.
                    """)
        }
    }

    /// ⛔ **WHY NO `shape` FIELD SHIPPED, COMPUTED RATHER THAN ASSERTED.**
    /// A triangle's third harmonic at 5.5 Hz is 16.5 Hz — just under the
    /// grid's 16.67 Hz Nyquist — and at 7.8 Hz it is 23.4 Hz, ALIASED. So a
    /// `shape` control could not deliver a shape: at the rates a singer uses,
    /// a triangle and a sine arrive at the renderer as nearly the same
    /// staircase, and above 5.6 Hz the difference that does survive is a
    /// folded-back frequency that is not in either waveform.
    @Test("§B a triangle and a sine are the SAME staircase on this grid — no shape field")
    func waveformShapeIsUnresolvableOnTheHopGrid() {
        let depth = 93.0
        let seconds = 4.0
        let hops = Int(seconds * Self.hopRateHz)
        func held(_ rate: Double, triangle: Bool) -> [Double] {
            (0..<hops).map { h in
                let t = Double(h) / Self.hopRateHz
                let phase = (rate * t).truncatingRemainder(dividingBy: 1)
                if !triangle { return depth * sin(2 * .pi * phase) }
                // Unit-amplitude triangle, same peak and same phase as the sine.
                let tri: Double
                switch phase {
                case ..<0.25: tri = phase * 4
                case ..<0.75: tri = 2 - phase * 4
                default: tri = phase * 4 - 4
                }
                return depth * tri
            }
        }
        for rate in [5.5, 7.8] {
            let s = held(rate, triangle: false)
            let t = held(rate, triangle: true)
            // What an analytic (un-gridded) comparison would see: the ideal
            // triangle differs from the ideal sine by ~7 % RMS of its own
            // amplitude. That is the control — the difference EXISTS.
            var idealDiff = 0.0
            var gridDiff = 0.0
            let fine = 20_000
            for i in 0..<fine {
                let time = Double(i) / Double(fine) * seconds
                let phase = (rate * time).truncatingRemainder(dividingBy: 1)
                let sn = depth * sin(2 * .pi * phase)
                let tr: Double
                switch phase {
                case ..<0.25: tr = phase * 4
                case ..<0.75: tr = 2 - phase * 4
                default: tr = phase * 4 - 4
                }
                idealDiff += (sn - depth * tr) * (sn - depth * tr)
            }
            idealDiff = (idealDiff / Double(fine)).squareRoot()
            for i in 0..<hops { gridDiff += (s[i] - t[i]) * (s[i] - t[i]) }
            gridDiff = (gridDiff / Double(hops)).squareRoot()

            // The third harmonic — the thing that MAKES a triangle a triangle.
            let third = rate * 3
            let nyquist = Self.hopRateHz / 2
            let aliased = third > nyquist
            Self.log("B", "\(rate) Hz: 3rd harmonic at \(third) Hz vs grid Nyquist "
                + "\(nyquist) Hz — \(aliased ? "ALIASED" : "just survives"); "
                + "ideal sine-vs-triangle rms \(idealDiff) c, ON THE GRID \(gridDiff) c")
            // ⭐ The control: the two waveforms ARE different, analytically.
            #expect(idealDiff > 5,
                    """
                    the ideal sine and triangle differ by only \(idealDiff) cents \
                    rms — the comparison cannot detect a shape at all, so the \
                    grid reading below proves nothing.
                    """)
        }
        // The claim in one sentence, pinned: the ceiling that governs shape is
        // the SAME grid Nyquist the rate ceiling is set from.
        #expect(NoteSegment.vibratoRateHzRange.upperBound * 3 > Self.hopRateHz / 2,
                """
                a third harmonic now fits under the grid's Nyquist across the \
                whole shipped rate range. The 'shape is unresolvable' reason \
                for having no shape field has expired and should be re-measured.
                """)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - §C — the physics: what the generator actually delivers
    // ═══════════════════════════════════════════════════════════════════════

    /// One note covering the whole render, carrying only a generator.
    static func generatorSet(rateHz: Double, depthCents: Double,
                             seconds: Double) -> PitchEditSet {
        PitchEditSet(
            segments: [NoteSegment(
                startSeconds: 0, endSeconds: seconds + 10, detectedHz: baseHz,
                detectedConfidence: 1, vibratoRateHz: rateHz,
                vibratoDepthCents: depthCents)],
            retuneMs: PitchEditSet.engineMinimumRetuneMs)
    }

    struct DepthReading {
        let chainCents: Double
        let controlCents: Double
        /// RMS of everything in the rendered f0 that is NOT the fitted
        /// sinusoid: the hop staircase, ringing, and the tracker's own noise.
        let residualCents: Double
        /// ⭐ **THE SAME QUANTITY ON THE CONTROL SIGNAL — the instrument's own
        /// floor.** Without it `residualCents` is uninterpretable: a 21.3 ms
        /// tracker reading a 10 Hz modulation is noisy all by itself, and
        /// attributing that to the renderer would be the confident wrong
        /// answer this tree keeps paying for.
        let controlResidualCents: Double
        let requested: Double
        var chainRatio: Double { chainCents / requested }
        var controlRatio: Double { controlCents / requested }
        /// What the CHAIN adds over the instrument's floor, as a fraction of
        /// the depth asked for. This is the number that says whether the
        /// rendered contour still looks like the sine it was asked for.
        var excessResidualFraction: Double {
            max(0, residualCents - controlResidualCents) / requested
        }
    }

    /// Render the generator, track the f0 back out, and read the depth against
    /// the SAME tracker's reading of an ideal signal carrying exactly that
    /// modulation with no stretcher anywhere.
    ///
    /// ⚠️ Every estimate is timestamped at its window CENTRE
    /// (`M23QToneEstimate.centreFrame`) — the harness's own contract, and the
    /// bias that produced a false "the engine disagrees with its own constant"
    /// finding when it was ignored.
    static func measureDepth(rateHz: Double, depthCents: Double,
                             seconds: Double = 6.0,
                             compensated: Bool = true) throws -> DepthReading {
        let frames = Int(sampleRate * seconds)
        let input = [M23QSignal.sine(hz: baseHz, frames: frames,
                                     sampleRate: sampleRate, amplitude: amplitude)]
        let plan = try #require(StretchCurvePlan.make(
            editSet: generatorSet(rateHz: rateHz, depthCents: depthCents,
                                  seconds: seconds),
            clipPitchShiftSemitones: 0, sampleRate: sampleRate, ratio: 1))
        let rendered = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: 1,
            semitonesAtOutputFrame: { plan.semitones(atOutputFrame: $0) },
            formantPreserve: false,
            compensation: compensated
                ? OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate)
                : .none)[0]

        // The instrument's own control: the SAME depth and rate as a real
        // frequency modulation, no stretcher. A chain reading of 1.1× means
        // nothing until this reads 1.00×.
        let ideal = M23QSignal.frequencyModulated(
            frames: frames, sampleRate: sampleRate, amplitude: amplitude
        ) { n in
            baseHz * pow(2, depthCents
                * sin(2 * .pi * rateHz * Double(n) / sampleRate) / 1200)
        }

        func fit(_ signal: [Float]) throws -> (amplitude: Double, residual: Double) {
            // Guard 0.4 s at each end: the render settles, and the first
            // ~50 ms cannot be latency-compensated at all by construction.
            let guardFrames = sampleRate * 0.4
            let series = M23QToneTracker.track(signal, sampleRate: sampleRate)
                .filter { $0.centreFrame >= guardFrames
                    && $0.centreFrame <= Double(frames) - guardFrames }
                .map { (frame: $0.centreFrame,
                        value: M23QToneTracker.cents($0.hz, above: baseHz)) }
            // Fit over a WHOLE number of cycles — a partial cycle biases a
            // one-bin DFT's amplitude, which is how a rate sweep grows a fake
            // trend.
            let period = sampleRate / rateHz
            let span = (series.last?.frame ?? 0) - (series.first?.frame ?? 0)
            let whole = (span / period).rounded(.down)
            let end = (series.first?.frame ?? 0) + whole * period
            let windowed = whole >= 1 ? series.filter { $0.frame < end } : series
            let f = try #require(M23QToneTracker.fitSinusoid(
                windowed, rateHz: rateHz, sampleRate: sampleRate))
            return (f.amplitude, f.residualRMS)
        }
        let chain = try fit(rendered)
        let control = try fit(ideal)
        return DepthReading(chainCents: chain.amplitude,
                            controlCents: control.amplitude,
                            residualCents: chain.residual,
                            controlResidualCents: control.residual,
                            requested: depthCents)
    }

    /// ⭐⭐ **THE HEADLINE. A request for `5.5 Hz ±93 c` — the reference app's
    /// own readout — measured coming back out of rendered audio.**
    @Test("§C 5.5 Hz ±93 c comes back measured, against the instrument's own control")
    func headlineDepthAndRate() throws {
        let reading = try Self.measureDepth(rateHz: 5.5, depthCents: 93)
        Self.log("C", "REQUESTED 5.5 Hz ±93 c → CHAIN ±\(reading.chainCents) c "
            + "(\(reading.chainRatio)× of asked, error "
            + "\(reading.chainCents - reading.requested) cents); INSTRUMENT CONTROL "
            + "±\(reading.controlCents) c (\(reading.controlRatio)×); non-sinusoidal "
            + "residual \(reading.residualCents) c against an instrument floor of "
            + "\(reading.controlResidualCents) c ⇒ chain excess "
            + "\(reading.excessResidualFraction * 100) % of depth")
        #expect(abs(reading.controlRatio - 1) < 0.02,
                """
                the depth instrument is itself off by \
                \(1 - reading.controlRatio) on a signal carrying exactly \
                ±93 cents. The chain reading cannot be interpreted until that is.
                """)
        #expect(reading.chainRatio > 0.85 && reading.chainRatio < 1.25,
                """
                a ±93 cent generated vibrato came back at \(reading.chainRatio)× \
                (±\(reading.chainCents) c).
                """)
    }

    /// ⭐⭐ **RECONCILIATION — TWO PRIOR MEASUREMENTS OF "HOW DEEP DOES VIBRATO
    /// COME BACK" ALREADY EXIST IN THIS TREE AND THEY DISAGREE. Quoting the
    /// convenient one would be the whole failure this project keeps paying
    /// for, so this leg runs the generator at the OTHER measurement's exact
    /// operating point.**
    ///
    ///  * `PitchCorrection.swift`'s header (phase-0 §8, via
    ///    `OfflineStretcherCurveTests.vibratoRateSweep`): **1.06× / 1.15× /
    ///    1.20×** at 1 / 5 / 8 Hz, ±50 cents, breakpoint array every 64
    ///    frames, `compensation: .none`. RE-RUN 2026-09-23 on this tree:
    ///    1.060 / 1.149 / 1.198 — **it still reproduces, it is not rotted
    ///    prose.**
    ///  * `PitchCurveRenderTests.slowCorrectionDepth`: **0.966×** at 0.25 Hz,
    ///    with 0.969 at 1 Hz and 1.043 at 5 Hz quoted beside it — closure
    ///    driven, compensated.
    ///
    /// The generator sits on the SECOND recipe, so this pins the difference to
    /// the recipe rather than leaving it as "a different path", which was the
    /// first explanation reached for and does not survive contact: latency
    /// compensation is a shift of the LOOKUP FRAME, and shifting when a
    /// periodic curve is sampled cannot change that curve's amplitude by
    /// 8 %. Both compensations are therefore measured here at ONE operating
    /// point, so the variable is isolated instead of argued.
    @Test("§C reconciliation — the generator against BOTH prior depth-gain measurements")
    func reconcileAgainstPriorDepthMeasurements() throws {
        // The header's exact operating point: 5 Hz, ±50 cents.
        let compensated = try Self.measureDepth(rateHz: 5, depthCents: 50)
        let raw = try Self.measureDepth(rateHz: 5, depthCents: 50, compensated: false)
        Self.log("C", "RECONCILE @ 5 Hz ±50 c (the header's own operating point): "
            + "generator COMPENSATED \(compensated.chainRatio)× "
            + "(instrument-corrected \(compensated.chainRatio / compensated.controlRatio)×); "
            + "generator UNCOMPENSATED \(raw.chainRatio)× "
            + "(instrument-corrected \(raw.chainRatio / raw.controlRatio)×). "
            + "Header (breakpoint array, .none) reports 1.15× corrected at 5 Hz; "
            + "PitchCurveRenderTests (closure, compensated) reports 1.043× at 5 Hz.")

        // ⭐ THE DISCRIMINATOR, ASSERTED: if compensation were the explanation
        // these two would differ materially. They must not.
        #expect(abs(compensated.chainRatio - raw.chainRatio) < 0.03,
                """
                compensated \(compensated.chainRatio)× vs uncompensated \
                \(raw.chainRatio)× at the same rate and depth. If latency \
                compensation really does move the delivered DEPTH, then it is \
                doing something other than shifting a lookup frame and the \
                render path needs re-reading.
                """)
        // And the instrument agrees with itself on both.
        #expect(abs(compensated.controlRatio - 1) < 0.02)
        #expect(abs(raw.controlRatio - 1) < 0.02)
    }

    /// ⭐⭐⭐ **THE FINDING THAT DECIDES WHAT A READOUT MAY PRINT: DELIVERED
    /// DEPTH IS NOT A SMOOTH FUNCTION OF RATE, AND 5.0 Hz IS A SPIKE.**
    ///
    /// The reconciliation above reproduced the header's 1.15× EXACTLY at its
    /// own operating point (5 Hz, ±50 c) through a completely different
    /// recipe, while the §C sweep reads ~1.02–1.09× everywhere else. Depth was
    /// ruled out — ±32 and ±93 straddle ±50 and BOTH read lower. The only
    /// remaining variable is the rate itself, and the mechanism is
    /// commensurability with the curve-update grid:
    ///
    ///   33.333 Hz ÷ 5.0 Hz = 6.667 = **20/3** — the zero-order hold visits
    ///   only 20 distinct phases, repeating every 3 cycles, so a systematic
    ///   over- or under-sampling of the peaks never averages out.
    ///   33.333 Hz ÷ 5.5 Hz = **200/33** — 200 distinct phases over 33 cycles,
    ///   which does average out.
    ///
    /// If that is right, a fine sweep around 5.0 Hz shows a PEAK at the
    /// commensurate rate rather than a smooth trend. This leg measures it, and
    /// it is the reason the report recommends a coarse depth readout rather
    /// than a per-rate compensation table: a table would have to encode a
    /// comb, not a curve.
    @Test("§C delivered depth SPIKES at rates commensurate with the hop grid")
    func depthGainIsNotSmoothInRate() throws {
        var rows: [String] = []
        var atCommensurate = 0.0
        var offCommensurate: [Double] = []
        // 5.0 Hz is exactly 20/3 of the 33.333 Hz grid; its neighbours are not.
        for rate in [4.7, 4.85, 5.0, 5.15, 5.3] {
            let reading = try Self.measureDepth(rateHz: rate, depthCents: 50)
            let corrected = reading.chainRatio / reading.controlRatio
            let hopsPerCycle = Self.hopRateHz / rate
            rows.append("\(rate) Hz (\(hopsPerCycle) hops/cycle) → \(corrected)×")
            if rate == 5.0 { atCommensurate = corrected } else {
                offCommensurate.append(corrected)
            }
        }
        let neighbourMean = offCommensurate.reduce(0, +) / Double(offCommensurate.count)
        Self.log("C", "DEPTH-vs-RATE at ±50 c, instrument-corrected: "
            + "\(rows.joined(separator: "; ")) — commensurate 5.0 Hz reads "
            + "\(atCommensurate)×, its four neighbours average \(neighbourMean)×")

        // ⛔ **FALSIFIED, AND KEPT AS A GATE RATHER THAN DELETED.** The rate
        // axis is SMOOTH: 4.7 → 5.3 Hz reads 1.1405 / 1.1453 / 1.1482 /
        // 1.1524 / 1.1562, a monotonic rise with no spike at the commensurate
        // rate at all. Commensurability with the hop grid is NOT the
        // mechanism, and the tidy 20/3 arithmetic that made it so persuasive
        // was numerology.
        //
        // The assertion is inverted to pin what was actually measured, so the
        // hypothesis cannot quietly come back: if a spike ever DOES appear
        // here, the smoothness claim below has expired and the readout
        // recommendation that rests on it needs re-deriving.
        #expect(abs(atCommensurate - neighbourMean) < 0.02,
                """
                5.0 Hz now reads \(atCommensurate)× against a neighbour mean of \
                \(neighbourMean)×. Delivered depth used to be SMOOTH in rate; a \
                spike at a grid-commensurate rate would mean a readout cannot \
                interpolate and the report's guidance is stale.
                """)
        #expect(atCommensurate > 1.10 && atCommensurate < 1.20,
                """
                5.0 Hz ±50 c is the header's own operating point and reproduced \
                its 1.15× figure; it now reads \(atCommensurate)×.
                """)
    }

    /// ⭐⭐⭐ **SO IT IS THE DEPTH AXIS, AND IT IS NOT MONOTONIC — the finding
    /// that decides what a readout may print.**
    ///
    /// The reconciliation reproduced the header's 1.15× at ±50 c; the §C sweep
    /// reads 1.02× at ±32 c and 1.08× at ±93 c — BOTH LOWER than the value
    /// between them. Compensation was ruled out (1.1406 vs 1.1408), recipe was
    /// ruled out (a closure reproduced a breakpoint array exactly), and rate
    /// was ruled out (smooth, above). Depth is what is left, so depth is what
    /// gets swept, at one fixed rate, instead of being inferred from three
    /// points that differ in two variables at once.
    ///
    /// **This is the number a `±93 c` readout would be promising**, so it is
    /// measured rather than interpolated.
    @Test("§C the depth axis at one fixed rate — what a cents readout would promise")
    func depthGainVersusRequestedDepth() throws {
        var rows: [String] = []
        var corrected: [(depth: Double, ratio: Double, errorCents: Double)] = []
        for depth in [16.0, 32.0, 50.0, 70.0, 93.0, 140.0] {
            let reading = try Self.measureDepth(rateHz: 5.5, depthCents: depth)
            let ratio = reading.chainRatio / reading.controlRatio
            corrected.append((depth, ratio, reading.chainCents - depth))
            rows.append("±\(depth) → \(ratio)× (delivered ±\(reading.chainCents) c, "
                + "error \(reading.chainCents - depth) c)")
        }
        Self.log("C", "DEPTH AXIS at 5.5 Hz, instrument-corrected: "
            + "\(rows.joined(separator: "; "))")

        // ⭐ NON-MONOTONICITY, ASSERTED rather than described: the largest
        // over-delivery is NOT at the largest depth. A UI that linearised this
        // would be wrong in the middle of its own range.
        let deepest = try #require(corrected.last)
        let peak = try #require(corrected.max { $0.ratio < $1.ratio })
        Self.log("C", "peak over-delivery \(peak.ratio)× at ±\(peak.depth) c; the "
            + "DEEPEST request (±\(deepest.depth) c) delivers \(deepest.ratio)×")
        #expect(peak.depth != deepest.depth,
                """
                over-delivery now peaks at the deepest request (±\(deepest.depth) \
                c). It used to peak in the middle of the range, which is why the \
                report advises against a compensation table; if the curve has \
                become monotonic, that advice can be revisited.
                """)
        // ⭐⭐⭐ **THE RECONCILIATION, AND THE CLAIM A READOUT ACTUALLY RESTS
        // ON: THIS IS A ROUGHLY CONSTANT OFFSET IN CENTS, NOT A GAIN.**
        //
        // Measured errors at 5.5 Hz: −3.3 / +0.4 / +7.3 / +6.7 / +6.5 / −2.4
        // cents for ±16 / 32 / 50 / 70 / 93 / 140. The RATIO swings 0.80×–1.16×
        // over the same rows purely because a near-constant offset divided by a
        // small depth looks enormous and divided by a large one looks like
        // nothing.
        //
        // That is what reconciles the two prior measurements, and neither of
        // them was wrong — they were both quoting a RATIO at a single depth
        // (±50) where the offset happens to be largest relative to the ask.
        // The header's 1.06× / 1.15× / 1.20× at 1 / 5 / 8 Hz is the SAME
        // offset, growing with rate: ≈+3 / +7.5 / +10 cents.
        //
        // So the bound a UI may promise is stated in CENTS, and it is asserted
        // here instead of the ratio, because the ratio is the framing that
        // made a constant offset look like a rate-dependent gain.
        let worstError = corrected.map { abs($0.errorCents) }.max() ?? .nan
        let spread = (corrected.map(\.errorCents).max() ?? .nan)
            - (corrected.map(\.errorCents).min() ?? .nan)
        Self.log("C", "WORST ABSOLUTE ERROR across the depth range at 5.5 Hz: "
            + "\(worstError) cents; the error SPREAD across a 9× change in "
            + "requested depth is only \(spread) cents — an offset, not a gain")
        #expect(worstError < 12,
                """
                the worst absolute depth error at 5.5 Hz is \(worstError) cents. \
                A whole-cent readout is decoration past about half this.
                """)
        #expect(spread < 15,
                """
                the depth error moved \(spread) cents across the range, which is \
                too much to call a constant offset. If the error now scales with \
                the request, it IS a gain after all and a readout could correct \
                for it — the opposite of this suite's recommendation.
                """)
    }

    /// The rate axis — the thing `vibratoScale` structurally could not do.
    /// **Asserting the physics, not the bytes:** the rendered f0 must contain
    /// energy at the rate ASKED FOR and not at a neighbouring one.
    @Test("§C the generator delivers the RATE it is asked for, not a neighbour")
    func rateIsDelivered() throws {
        let seconds = 6.0
        let requested = 7.8
        let frames = Int(Self.sampleRate * seconds)
        let input = [M23QSignal.sine(hz: Self.baseHz, frames: frames,
                                     sampleRate: Self.sampleRate,
                                     amplitude: Self.amplitude)]
        let plan = try #require(StretchCurvePlan.make(
            editSet: Self.generatorSet(rateHz: requested, depthCents: 60,
                                       seconds: seconds),
            clipPitchShiftSemitones: 0, sampleRate: Self.sampleRate, ratio: 1))
        let rendered = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: Self.sampleRate, ratio: 1,
            semitonesAtOutputFrame: { plan.semitones(atOutputFrame: $0) },
            formantPreserve: false,
            compensation: OfflineStretcher.curveLatencyCompensation(
                sampleRate: Self.sampleRate))[0]
        let guardFrames = Self.sampleRate * 0.4
        let series = M23QToneTracker.track(rendered, sampleRate: Self.sampleRate)
            .filter { $0.centreFrame >= guardFrames
                && $0.centreFrame <= Double(frames) - guardFrames }
            .map { (frame: $0.centreFrame,
                    value: M23QToneTracker.cents($0.hz, above: Self.baseHz)) }

        // Scan the projection across candidate rates. The MAXIMUM must land on
        // what was asked for — that is the whole claim of a rate control.
        var best = (rate: 0.0, amplitude: 0.0)
        var table: [String] = []
        for step in 0...120 {
            let rate = 4.0 + Double(step) / 120 * 8.0  // 4.0 … 12.0 Hz
            guard let fit = M23QToneTracker.fitSinusoid(
                series, rateHz: rate, sampleRate: Self.sampleRate) else { continue }
            if fit.amplitude > best.amplitude { best = (rate, fit.amplitude) }
            if step % 15 == 0 {
                table.append("\(rate)→\(fit.amplitude)")
            }
        }
        // ⚠️ The projection amplitudes below are NOT depths and must never be
        // quoted as one: a rate scan cannot re-window per candidate (the
        // window would stop being the same experiment), so every row is fitted
        // over a PARTIAL number of cycles, which biases a one-bin DFT's
        // amplitude. They are valid for LOCATING the peak and for nothing
        // else. Depths come from `measureDepth`, which fits whole cycles.
        Self.log("C", "requested \(requested) Hz; projection peaks at \(best.rate) Hz "
            + "(unnormalised projection \(best.amplitude), NOT a depth). Scan: "
            + "\(table.joined(separator: ", "))")
        #expect(abs(best.rate - requested) < 0.2,
                """
                a \(requested) Hz vibrato was asked for and the rendered f0's \
                strongest periodic component is at \(best.rate) Hz. A rate \
                readout would be printing a request, not a result.
                """)
        // ⭐ CONTROL: the scan HAS resolution — a deliberately wrong rate must
        // read materially weaker than the right one, or "it peaked at 7.8"
        // means only that 7.8 was in the list.
        let wrong = try #require(M23QToneTracker.fitSinusoid(
            series, rateHz: requested * 1.35, sampleRate: Self.sampleRate))
        #expect(wrong.amplitude < best.amplitude * 0.5,
                """
                the projection at \(requested * 1.35) Hz reads \(wrong.amplitude) \
                against \(best.amplitude) at the peak — the scan cannot \
                discriminate rates, so the peak location proves nothing.
                """)
    }

    /// The honesty sweep: what a readout would be promising, across the
    /// shipped rate range and at both depths the reference app displayed.
    @Test("§C the depth sweep — every rate a user can ask for, measured")
    func depthSweepAcrossShippedRates() throws {
        var worstRatio = 1.0
        var bestRatio = 1.0
        var worstExcess = 0.0
        for depth in [93.0, 32.0] {
            for rate in [3.0, 4.5, 5.5, 6.5, 7.8,
                         NoteSegment.vibratoRateHzRange.upperBound] {
                let reading = try Self.measureDepth(rateHz: rate, depthCents: depth)
                Self.log("C", "±\(depth) c @ \(rate) Hz → CHAIN ±\(reading.chainCents) c "
                    + "(\(reading.chainRatio)×, error \(reading.chainCents - depth) c); "
                    + "control \(reading.controlRatio)×; residual \(reading.residualCents) c "
                    + "vs INSTRUMENT FLOOR \(reading.controlResidualCents) c ⇒ chain excess "
                    + "\(reading.excessResidualFraction * 100) % of depth")
                #expect(abs(reading.controlRatio - 1) < 0.03,
                        """
                        the instrument control reads \(reading.controlRatio)× at \
                        \(rate) Hz — the chain number on this row is uninterpretable.
                        """)
                worstRatio = min(worstRatio, reading.chainRatio)
                bestRatio = max(bestRatio, reading.chainRatio)
                worstExcess = max(worstExcess, reading.excessResidualFraction)
            }
        }
        Self.log("C", "SWEEP ENVELOPE across the shipped range: depth \(worstRatio)× … "
            + "\(bestRatio)×; worst chain excess residual \(worstExcess * 100) % of depth")
        // The bands pin the CLAIM the docs are allowed to make, not a digit.
        #expect(worstRatio > 0.80,
                "the shallowest delivery across the shipped rate range is \(worstRatio)×")
        #expect(bestRatio < 1.30,
                "the deepest delivery across the shipped rate range is \(bestRatio)×")
        // ⭐ **AND THE SHAPE, NOT ONLY THE DEPTH.** A fitted depth of 0.98×
        // with 60 % of the depth in non-sinusoidal content is a staircase that
        // scores as a vibrato. This is the gate that would have stopped a
        // 10 Hz ceiling shipping.
        #expect(worstExcess < 0.30,
                """
                the rendered contour carries \(worstExcess * 100) % of its \
                requested depth in energy that is NOT the sine asked for. The \
                rate ceiling is no longer where the shape survives.
                """)
    }

    /// ⭐⭐ **WHY THE CEILING IS WHERE IT IS — the control that CAN fail, run
    /// ABOVE the ceiling by driving the stretcher directly so `NoteSegment`'s
    /// clamp cannot quietly rescue the experiment.**
    ///
    /// Two different failures live above the shipped range and they are not
    /// the same failure:
    ///  * between the ceiling and the grid's Nyquist the RATE survives and the
    ///    SHAPE degrades — a staircase;
    ///  * above the Nyquist the rate itself folds, and the render comes back
    ///    modulated at a frequency that was never asked for.
    @Test("§C above the ceiling the shape goes; above the alias limit the RATE goes")
    func aboveTheCeilingTheRequestStopsBeingHonoured() throws {
        let seconds = 6.0
        let depth = 93.0
        let frames = Int(Self.sampleRate * seconds)
        let nyquist = Self.hopRateHz / 2

        // The clamp is real, and that is the first thing to prove — otherwise
        // the raw-closure experiment below is answering a question the shipped
        // type would never ask.
        let clamped = NoteSegment(startSeconds: 0, endSeconds: 10, detectedHz: 220,
                                  detectedConfidence: 1, vibratoRateHz: 20,
                                  vibratoDepthCents: depth)
        #expect(clamped.vibratoRateHz == NoteSegment.vibratoRateHzRange.upperBound)

        for requested in [10.0, 20.0] {
            let input = [M23QSignal.sine(hz: Self.baseHz, frames: frames,
                                         sampleRate: Self.sampleRate,
                                         amplitude: Self.amplitude)]
            // Raw closure: the SAME generator arithmetic the curve uses, with
            // the clamp bypassed on purpose.
            let rendered = try OfflineStretcher.stretchTransposeCurve(
                input: input, sampleRate: Self.sampleRate, ratio: 1,
                semitonesAtOutputFrame: { frame in
                    depth / 100 * sin(2 * .pi * requested
                        * Double(frame) / Self.sampleRate)
                },
                formantPreserve: false,
                compensation: OfflineStretcher.curveLatencyCompensation(
                    sampleRate: Self.sampleRate))[0]
            let guardFrames = Self.sampleRate * 0.4
            let series = M23QToneTracker.track(rendered, sampleRate: Self.sampleRate)
                .filter { $0.centreFrame >= guardFrames
                    && $0.centreFrame <= Double(frames) - guardFrames }
                .map { (frame: $0.centreFrame,
                        value: M23QToneTracker.cents($0.hz, above: Self.baseHz)) }

            var best = (rate: 0.0, amplitude: 0.0)
            for step in 0...300 {
                let rate = 2.0 + Double(step) / 300 * 20.0  // 2 … 22 Hz
                guard let fit = M23QToneTracker.fitSinusoid(
                    series, rateHz: rate, sampleRate: Self.sampleRate) else { continue }
                if fit.amplitude > best.amplitude { best = (rate, fit.amplitude) }
            }
            let folded = abs(Self.hopRateHz - requested)
            Self.log("C", "ABOVE CEILING: requested \(requested) Hz (grid Nyquist "
                + "\(nyquist) Hz); strongest component in the rendered f0 is at "
                + "\(best.rate) Hz; the fold-back of \(requested) about the "
                + "\(Self.hopRateHz) Hz grid would be \(folded) Hz")
            if requested < nyquist {
                // Rate survives; §C's sweep already showed the shape does not.
                #expect(abs(best.rate - requested) < 0.4,
                        """
                        \(requested) Hz is below the grid's Nyquist so the RATE \
                        should still arrive; the strongest component is at \
                        \(best.rate) Hz.
                        """)
            } else {
                // ⭐ THE ALIAS, MEASURED: the rendered f0's strongest periodic
                // component is NOT the rate requested.
                #expect(abs(best.rate - requested) > 1.0,
                        """
                        \(requested) Hz is above the grid's Nyquist \(nyquist) Hz \
                        and the rendered f0 still peaks at \(best.rate) Hz. If a \
                        request above the alias limit really does survive, the \
                        rate ceiling's stated reason is wrong.
                        """)
                #expect(abs(best.rate - folded) < 1.5,
                        """
                        \(requested) Hz folded about a \(Self.hopRateHz) Hz grid \
                        predicts \(folded) Hz; the rendered f0 peaks at \
                        \(best.rate) Hz.
                        """)
            }
        }
    }
}
