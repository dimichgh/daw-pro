import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// Natural tuning §1(b)/(g), lane NT-E1: **THE FORMANT RENDER** — the two shim
/// setters, the curve loop's engaged branch and the plan's closures.
///
/// Every render goes through the SHIPPING shape: `StretchCurvePlan.make` +
/// `OfflineStretcher.stretchTransposeCurve` with the shipping compensation and
/// `plan.formantCurve(formantPreserve:)` (the `NoteVibratoGeneratorTests`
/// precedent). NT-E1b wired `StretchRenderCache.renderAudio` to pass the same
/// curve at both of its calls: `productRenderEngagesTheFormantCurve` proves
/// the product's bytes ARE this direct render's (it replaced NT-E1's pinned
/// product gap).
///
/// ⚠️ **NT-E1 PINNED NO DIGEST OF TRANSPOSED AUDIO, ON PURPOSE:** a pending
/// fix to the vendored transposer (p2-acc-3, since landed) moved every
/// transposed render's bytes. G6's byte identity is therefore proven against
/// a SAME-BUILD reference, the constant loop (bit-identical to a constant
/// curve: `PitchCurveRenderTests` (5)). NT-E1b's product gate pins SIX
/// (`legacyProductGoldens`, the legacy twins' product bytes captured before
/// its wiring, at transposeEngineVersion 4); a transposer change moves them.
///
/// The physics gates (G1-G5) need lane NT-G's envelope meter and voice and
/// land after them. Deliberately NOT `@MainActor`.
@Suite("Natural tuning §1 — the formant render (NT-E1)")
struct NaturalTuningFormantRenderTests {
    static let sampleRate = 48_000.0
    static var compensation: OfflineStretcher.CurveLatencyCompensation {
        OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate)
    }

    /// Through the shipping shape, exactly as the render will: the plan's
    /// transpose AND its formant curve for this clip flag.
    static func render(_ input: [[Float]], plan: StretchCurvePlan, formantPreserve: Bool,
                       formant: OfflineStretcher.FormantCurve?? = .none) throws -> [Float] {
        try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: plan.ratio,
            semitonesAtOutputFrame: { plan.semitones(atOutputFrame: $0) },
            formantPreserve: formantPreserve,
            formant: formant ?? plan.formantCurve(formantPreserve: formantPreserve),
            compensation: compensation)[0]
    }

    static func differing(_ a: [Float], _ b: [Float]) -> Int {
        zip(a, b).reduce(0) { $0 + ($1.0.bitPattern == $1.1.bitPattern ? 0 : 1) }
            + abs(a.count - b.count)
    }

    /// A LEGACY set (no amount, no offset) whose only note lies far past the
    /// end of the render, so its curve is the clip's constant shift at every
    /// lookup frame, lookahead included.
    static func constantLegacyPlan(clipSemitones: Double) throws -> StretchCurvePlan {
        let set = PitchEditSet(segments: [
            NoteSegment(startSeconds: 100, endSeconds: 101, detectedHz: 110,
                        detectedConfidence: 0.9, pitchOffsetCents: 100)
        ])
        #expect(!set.engagesFormantCurve)
        return try #require(StretchCurvePlan.make(
            editSet: set, clipPitchShiftSemitones: clipSemitones,
            sampleRate: sampleRate, ratio: 1))
    }

    // MARK: - G6: byte identity at defaults

    /// ⭐ **G6, the law that matters most.** A legacy set renders exactly as
    /// before §1, with the clip's formant flag OFF and ON: its plan builds no
    /// formant curve, and the curve loop's nil branch, driven through the
    /// shipping plan, is bit-identical to the untouched constant loop at the
    /// same transpose. Plants (reverted, `cmp`-checked): an unconditional
    /// per-hop `css_set_formant_semitones(…, 0, true)` in the nil branch must
    /// turn the flag-OFF leg red; an unconditional per-hop
    /// `css_set_formant_base_hz(110)` (R7) must turn the flag-ON leg red.
    @Test("G6 a legacy set renders bit-identically to the untouched constant loop, formant flag OFF and ON")
    func legacySetMatchesTheConstantLoop() throws {
        let voice = SpanRenderSignals.voice(seconds: 1.5, sampleRate: Self.sampleRate)
        let input = [voice.samples]
        let plan = try Self.constantLegacyPlan(clipSemitones: 2)
        var renders: [Bool: [Float]] = [:]
        for flag in [false, true] {
            #expect(plan.formantCurve(formantPreserve: flag) == nil,
                    "a legacy set built a formant curve (flag \(flag))")
            let reference = try OfflineStretcher.stretch(
                input: input, sampleRate: Self.sampleRate, ratio: 1, semitones: 2,
                formantPreserve: flag)[0]
            let curved = try Self.render(input, plan: plan, formantPreserve: flag)
            let diff = Self.differing(reference, curved)
            print("NT-E1|G6| flag \(flag): \(diff) differing samples of \(reference.count)")
            #expect(curved.count == reference.count && diff == 0,
                    "the nil branch no longer matches the constant loop (flag \(flag)): \(diff) samples")
            renders[flag] = curved
        }
        // Positive control: the comparison CAN fail, the flag is audible here.
        let flipped = Self.differing(try #require(renders[false]), try #require(renders[true]))
        #expect(flipped > 1_000, "the flag changed only \(flipped) samples: G6 could not see a flag leak")
    }

    /// A set on the voice fixture with note `moved` shifted by `cents`, at
    /// correction `amount` (nil = legacy), `retuneMs` 45.
    static func voiceSet(_ notes: [NoteSegment], moved: Int = 1, cents: Double = 400,
                         amount: Double?, offset: (index: Int, semitones: Double)? = nil)
        -> PitchEditSet {
        var segments = notes
        segments[moved].pitchOffsetCents = cents
        if let offset { segments[offset.index].formantOffsetSemitones = offset.semitones }
        return PitchEditSet(segments: segments, retuneMs: 45, formantCorrection: amount)
    }

    @Test("G6 the plan builds a formant curve iff the set engages: legacy sets never, an amount or an offset always")
    func planEngagesOnThePredicateAlone() throws {
        let voice = SpanRenderSignals.voice(seconds: 3, sampleRate: Self.sampleRate)
        func plan(_ set: PitchEditSet) throws -> StretchCurvePlan {
            try #require(StretchCurvePlan.make(editSet: set, clipPitchShiftSemitones: 0,
                                               sampleRate: Self.sampleRate, ratio: 1))
        }
        for legacy in [Self.voiceSet(voice.notes, amount: nil),
                       PitchCurveRenderTests.c21Set("offset"),
                       PitchCurveRenderTests.c21Set("generator")] {
            let p = try plan(legacy)
            #expect(!p.engagesFormantCurve)
            #expect(p.formantCurve(formantPreserve: false) == nil
                    && p.formantCurve(formantPreserve: true) == nil)
        }
        for engaged in [Self.voiceSet(voice.notes, amount: 0),
                        Self.voiceSet(voice.notes, amount: 1),
                        Self.voiceSet(voice.notes, amount: nil, offset: (0, -2))] {
            let p = try plan(engaged)
            #expect(p.engagesFormantCurve == engaged.engagesFormantCurve && p.engagesFormantCurve)
            #expect(p.formantCurve(formantPreserve: false) != nil
                    && p.formantCurve(formantPreserve: true) != nil)
        }
    }

    // MARK: - NT-E1b: the product gate's fixtures

    /// One product-gate case: an ENGAGED set, its LEGACY twin (amount nil,
    /// every Voice offset 0: the render §1 never touched) and the clip flag.
    struct ProductCase {
        let label: String
        let engaged: PitchEditSet
        let legacy: PitchEditSet
        let formantPreserve: Bool
    }

    /// The product gate's source: 2 s of the f0 110 physics voice.
    static func productSource() -> [Float] { sourceVoice(f0: 110) }

    /// The window leg's whole-file output frames, 0.8 s ..< 1.4 s: inside
    /// the moved notes, across the soft join at 1.0 s, far from frame 0.
    static let productWindow = 38_400..<67_200

    /// The engaged sets the app makes or can open, each against its legacy
    /// twin: the new-set default (amount 1), a hand-authored Voice offset
    /// with amount nil (c = the clip flag, OFF and ON), and a soft-join set
    /// at the editor seed's slope (X7: its formant curve follows the joins).
    static func productCases() -> [ProductCase] {
        func note(_ start: Double, _ end: Double, cents: Double, offset: Double = 0) -> NoteSegment {
            NoteSegment(startSeconds: start, endSeconds: end, detectedHz: 110, detectedConfidence: 0.95,
                        pitchOffsetCents: cents, formantOffsetSemitones: offset)
        }
        let legacy = PitchEditSet(segments: [note(0.2, 1.8, cents: 400)], retuneMs: 45)
        let offset = PitchEditSet(segments: [note(0.2, 1.8, cents: 400, offset: -2)], retuneMs: 45)
        let softLegacy = PitchEditSet(
            segments: [note(0.2, 1.0, cents: 400), note(1.0, 1.8, cents: 0)], retuneMs: 45,
            transitionSlopeCentsPerSecond: PitchEditSet.defaultTransitionSlope)
        var soft = softLegacy
        soft.formantCorrection = 1
        return [
            ProductCase(label: "amount 1 (the new-set default)",
                        engaged: PitchEditSet(segments: legacy.segments, retuneMs: 45, formantCorrection: 1),
                        legacy: legacy, formantPreserve: false),
            ProductCase(label: "a −2 st Voice offset, amount nil, clip flag OFF (c = 0)",
                        engaged: offset, legacy: legacy, formantPreserve: false),
            ProductCase(label: "a −2 st Voice offset, amount nil, clip flag ON (c = 1)",
                        engaged: offset, legacy: legacy, formantPreserve: true),
            ProductCase(label: "a soft join at slope 3000, amount 1",
                        engaged: soft, legacy: softLegacy, formantPreserve: false),
        ]
    }

    /// A render through THE PRODUCT: `StretchRenderCache.renderAudio`, the
    /// one body every app render runs (`performRender` for the whole file;
    /// `renderOutputFrames`, and so every span, audition and provisional
    /// patch, for a window). `window` nil = the whole file.
    static func productRender(_ source: [Float], set: PitchEditSet, formantPreserve: Bool,
                              window: Range<Int>?) throws -> StretchWindowOutput {
        var whole = window == nil ? [source] : []
        let params = StretchRenderCache.Params(ratio: 1, semitones: 0,
                                               formantPreserve: formantPreserve, pitchEdits: set)
        let out = try StretchRenderCache.renderAudio(
            whole: &whole, window: window.map { Self.stretchWindow(source, $0) },
            sampleRate: sampleRate, params: params, curveContour: nil, isCancelled: { false })
        #expect(out.path == .curve)
        return out.output
    }

    /// NT-E1's DIRECT render of the same set through the same entry (whole
    /// file or the same window): the plan, the curve loop, the shipping
    /// compensation and `plan.formantCurve(formantPreserve:)`.
    static func directRender(_ source: [Float], set: PitchEditSet, formantPreserve: Bool,
                             window: Range<Int>?) throws -> StretchWindowOutput {
        let plan = try #require(StretchCurvePlan.make(editSet: set, clipPitchShiftSemitones: 0,
                                                      sampleRate: sampleRate, ratio: 1))
        let semitones: (Int) -> Double = { plan.semitones(atOutputFrame: $0) }
        let formant = plan.formantCurve(formantPreserve: formantPreserve)
        if let window {
            return try OfflineStretcher.stretchTransposeCurve(
                window: Self.stretchWindow(source, window), sampleRate: sampleRate, ratio: 1,
                semitonesAtOutputFrame: semitones, formantPreserve: formantPreserve,
                formant: formant, compensation: compensation)
        }
        return StretchWindowOutput(
            planar: try OfflineStretcher.stretchTransposeCurve(
                input: [source], sampleRate: sampleRate, ratio: 1,
                semitonesAtOutputFrame: semitones, formantPreserve: formantPreserve,
                formant: formant, compensation: compensation),
            firstOutputFrame: 0)
    }

    static func stretchWindow(_ source: [Float], _ frames: Range<Int>) -> StretchWindow {
        StretchWindow(channels: 1, sourceFrames: source.count,
                      startOutputFrame: frames.lowerBound, endOutputFrame: frames.upperBound,
                      readSource: { range in [Array(source[range])] })
    }

    /// Frames that differ, plus a start-frame mismatch as "all of them".
    static func differing(_ a: StretchWindowOutput, _ b: StretchWindowOutput) -> Int {
        a.firstOutputFrame == b.firstOutputFrame
            ? differing(a.planar[0], b.planar[0]) : max(a.planar[0].count, b.planar[0].count)
    }

    /// The product's bytes for each LEGACY twin, CAPTURED FROM THE TREE BEFORE
    /// THE WIRING (NT-E1b, 2026-09-25 22:36, transposeEngineVersion 4,
    /// `logs/run1-capture-1.log`): SHA-256 of `SpanRenderSignals.sha256`, by
    /// "<twin> <leg>". A transposer change moves them like
    /// `PitchCurveRenderTests`' goldens and they are re-pinned the same way.
    static let legacyProductGoldens: [String: String] = [
        "flag off whole": "32ed768f0feecf37fa20ccdf4eceb778c06fba586dbe7a0eae9822a8495ce9bb",
        "flag off window": "a638d6da9883f855a544ba5d7924d822bcb7a78f4e53fe65182c79fa0b22f3f1",
        "flag on whole": "38cf76b2abc632349b7a277b0b6fa608eac418270eeb471c0f17051e5552824d",
        "flag on window": "9e28613ec937b5a749ce52ed3f5b5a2b9cef0ffd238f39c583ed0bb93dea9a1e",
        "soft whole": "80d47222a973b60eb6f83196d46531e897093c9510e36f857d981bb62d17b1d5",
        "soft window": "296dc530ea1afaed294b14fa0034f196121331d5655d3ee72fb71650128b5977",
    ]

    /// ⭐ **THE PRODUCT GATE (NT-E1b; it replaces NT-E1's pinned product
    /// gap, `productRenderDoesNotEngageYet`).** `StretchRenderCache
    /// .renderAudio` passes `plan.formantCurve(formantPreserve:
    /// params.formantPreserve)` at BOTH of its `stretchTransposeCurve` calls,
    /// the whole-file one and the window one (every span, audition and
    /// provisional patch); `Sources/` has no other call (CENSUSED). For every
    /// engaged case in `productCases()`, on BOTH legs:
    ///  * the product render DIFFERS from its legacy twin's (the curve
    ///    reaches the audio);
    ///  * it EQUALS NT-E1's direct engaged render byte for byte, so G1-G7's
    ///    physics, measured on the direct render, are the product's.
    /// And each legacy twin (amount nil, every offset 0) renders through the
    /// product exactly as the direct nil-curve render and exactly as the
    /// product did BEFORE the wiring (`legacyProductGoldens`).
    /// Distinct bytes alone would prove nothing; the byte identity with the
    /// direct render is what ties them to the gated physics.
    /// Plants (in place, reverted, `cmp`-checked): the `formant:` argument
    /// removed at the WINDOW call turns only the window legs red, and at the
    /// WHOLE-FILE call only the whole-file legs.
    @Test("PRODUCT: renderAudio engages the formant curve, whole file AND window: engaged ≠ legacy twin, = the direct engaged render; legacy twins keep their pre-wiring bytes")
    func productRenderEngagesTheFormantCurve() throws {
        let source = Self.productSource()
        for c in Self.productCases() {
            #expect(c.engaged.engagesFormantCurve && !c.legacy.engagesFormantCurve, "\(c.label): fixture")
            for window in [nil, Self.productWindow] as [Range<Int>?] {
                let leg = window == nil ? "whole" : "window"
                let product = try Self.productRender(source, set: c.engaged,
                                                     formantPreserve: c.formantPreserve, window: window)
                let direct = try Self.directRender(source, set: c.engaged,
                                                   formantPreserve: c.formantPreserve, window: window)
                let twin = try Self.productRender(source, set: c.legacy,
                                                  formantPreserve: c.formantPreserve, window: window)
                let vsTwin = Self.differing(product, twin)
                let vsDirect = Self.differing(product, direct)
                print("NT-E1b|product| \(c.label) | \(leg): \(vsTwin) of \(product.planar[0].count) samples differ from the legacy twin, \(vsDirect) from the direct engaged render")
                #expect(vsTwin > 1_000,
                        "\(c.label), \(leg): the product renders an engaged set as its legacy twin (\(vsTwin) samples differ): the formant curve does not reach this call")
                #expect(vsDirect == 0 && product.planar[0].count == direct.planar[0].count,
                        "\(c.label), \(leg): the product differs from the direct engaged render in \(vsDirect) samples")
            }
        }
        // The legacy twins: the nil branch through the product, byte for byte
        // as the direct render and as the pre-wiring capture.
        let twins: [(name: String, set: PitchEditSet, flag: Bool)] = [
            ("flag off", Self.productCases()[0].legacy, false),
            ("flag on", Self.productCases()[2].legacy, true),
            ("soft", Self.productCases()[3].legacy, false),
        ]
        for twin in twins {
            for window in [nil, Self.productWindow] as [Range<Int>?] {
                let key = "\(twin.name) \(window == nil ? "whole" : "window")"
                let product = try Self.productRender(source, set: twin.set, formantPreserve: twin.flag,
                                                     window: window)
                let direct = try Self.directRender(source, set: twin.set, formantPreserve: twin.flag,
                                                   window: window)
                let sha = SpanRenderSignals.sha256(product.planar)
                print("NT-E1b|legacy| \(key): sha \(sha), \(Self.differing(product, direct)) samples differ from the direct nil-curve render")
                #expect(Self.differing(product, direct) == 0, "\(key): the legacy product render left the nil branch")
                #expect(sha == Self.legacyProductGoldens[key],
                        "\(key): a legacy set's product bytes MOVED (\(sha)): the wiring touched the nil branch")
            }
        }
    }

    // MARK: - R3: the spy (G7's determinism half) and the inert prefix

    final class LookupSpy: @unchecked Sendable {
        var transposeFrames: [Int] = []
        var formantFrames: [Int] = []
        var baseFrames: [Int] = []
        var bases: [Double] = []
    }

    /// ⭐ **R3's spy gate** ("a spy gate beats a source-shape gate"): every value
    /// the curve loop obtains from the plan's formant closures, on every hop
    /// and on the pre-roll, recorded by a Swift wrapper (the C shim is not
    /// instrumented). The loop asks the formant shift and the base at EXACTLY
    /// the transpose's lookup frames, once per chunk plus the pre-roll at the
    /// first chunk's frame; every base is > 0 and equals the DAWCore
    /// evaluator at that frame. The wrapper does not perturb the render.
    /// Plant: a plan closure returning base 0 must fail.
    @Test("R3 spy: the formant shift and base are read at the transpose's own lookup frames, every base > 0 and equal to formantBaseHz there")
    func formantIsReadAtTheTransposeLookupFrames() throws {
        let voice = SpanRenderSignals.voice(seconds: 3, sampleRate: Self.sampleRate)
        let set = Self.voiceSet(voice.notes, amount: 1, offset: (2, -2))
        let plan = try #require(StretchCurvePlan.make(editSet: set, clipPitchShiftSemitones: 0,
                                                      sampleRate: Self.sampleRate, ratio: 1))
        let real = try #require(plan.formantCurve(formantPreserve: false))
        let spy = LookupSpy()
        let spied = OfflineStretcher.FormantCurve(
            semitonesAtOutputFrame: { spy.formantFrames.append($0); return real.semitonesAtOutputFrame($0) },
            baseHzAtOutputFrame: {
                spy.baseFrames.append($0)
                let hz = real.baseHzAtOutputFrame($0)
                spy.bases.append(hz)
                return hz
            })
        let spiedRender = try OfflineStretcher.stretchTransposeCurve(
            input: [voice.samples], sampleRate: Self.sampleRate, ratio: 1,
            semitonesAtOutputFrame: { spy.transposeFrames.append($0); return plan.semitones(atOutputFrame: $0) },
            formantPreserve: false, formant: spied, compensation: Self.compensation)[0]
        let plain = try Self.render([voice.samples], plan: plan, formantPreserve: false)
        #expect(Self.differing(spiedRender, plain) == 0, "the spy perturbed the render")

        #expect(spy.formantFrames == spy.transposeFrames && spy.baseFrames == spy.transposeFrames,
                "the formant values are not read at the transpose's lookup frames")
        let schedule = try OfflineStretcher.curveSchedule(
            sourceFrames: voice.samples.count, channels: 1, sampleRate: Self.sampleRate, ratio: 1)
        let interval = schedule.blockFrames
        let chunks = (schedule.processOut + interval - 1) / interval
        let expected = [OfflineStretcher.curveLookupFrame(outputFrame: 0, compensation: Self.compensation,
                                                          intervalSamples: interval)]
            + (0..<chunks).map {
                OfflineStretcher.curveLookupFrame(outputFrame: $0 * interval,
                                                  compensation: Self.compensation, intervalSamples: interval)
            }
        #expect(spy.baseFrames == expected,
                "expected the pre-roll + \(chunks) chunk lookups, got \(spy.baseFrames.count) reads")
        var wrong = 0
        for (frame, hz) in zip(spy.baseFrames, spy.bases) {
            let truth = plan.curve.formantBaseHz(atSourceSecond: plan.sourceSecond(forOutputFrame: frame))
            if !(hz > 0) || hz.bitPattern != truth.bitPattern { wrong += 1 }
        }
        #expect(wrong == 0, "\(wrong) of \(spy.bases.count) bases were ≤ 0 or not formantBaseHz at their frame")
        // The base is the NOTES' detected f0, a step function: all three appear.
        #expect(Set(spy.bases).isSuperset(of: [110, 123.47, 98]))
    }

    /// The engaged branch is INERT where nothing moves: at a hop with T = 0
    /// and F = 0 the formant multiplier is 1 and compensation has no pitch map
    /// to undo, so `processFormants` is off exactly as in a legacy render.
    /// Before the first chunk where T or F departs from 0, the engaged render
    /// is bit-identical to the legacy one (c = 0 and c = 1); after it, it
    /// differs (the control: the branch did something).
    @Test("the engaged branch is bit-inert before the first moved hop, and active after it")
    func engagedBranchIsInertWhereNothingMoves() throws {
        let voice = SpanRenderSignals.voice(seconds: 3, sampleRate: Self.sampleRate)
        func plan(_ amount: Double?) throws -> StretchCurvePlan {
            try #require(StretchCurvePlan.make(editSet: Self.voiceSet(voice.notes, amount: amount),
                                               clipPitchShiftSemitones: 0,
                                               sampleRate: Self.sampleRate, ratio: 1))
        }
        let legacyPlan = try plan(nil)
        let legacy = try Self.render([voice.samples], plan: legacyPlan, formantPreserve: false)
        let interval = 1_440
        let firstMoved = try #require((0..<200).first { chunk in
            let lookup = OfflineStretcher.curveLookupFrame(outputFrame: chunk * interval,
                                                           compensation: Self.compensation,
                                                           intervalSamples: interval)
            return legacyPlan.semitones(atOutputFrame: lookup) != 0
        })
        for amount in [0.0, 1.0] {
            let engaged = try Self.render([voice.samples], plan: try plan(amount), formantPreserve: false)
            let first = zip(legacy, engaged).enumerated()
                .first { $0.element.0.bitPattern != $0.element.1.bitPattern }?.offset
            print("NT-E1|inert| c \(amount): first moved chunk \(firstMoved) (frame \(firstMoved * interval)), first differing frame \(first.map(String.init) ?? "none")")
            let differs = try #require(first, "c \(amount): the engaged render equals legacy everywhere")
            #expect(differs >= firstMoved * interval,
                    "c \(amount): the engaged branch changed frame \(differs), before the first moved hop")
        }
    }

    // MARK: - G7 (R3): window == whole file, engaged

    /// One window of the ENGAGED whole-file render, through the window entry
    /// with the SAME plan closures and the product's pre-roll, trimmed to
    /// exactly `frames` (what `renderOutputFrames` does once it passes the
    /// curve). `formant` overrides the plan's (nil = the curve withheld).
    static func window(_ samples: [Float], plan: StretchCurvePlan, frames: Range<Int>,
                       formant: OfflineStretcher.FormantCurve?? = .none) throws -> [Float] {
        let preRoll = StretchRenderCache.minimumPreRollFrames(sampleRate: sampleRate)
        let window = StretchWindow(
            channels: 1, sourceFrames: samples.count,
            startOutputFrame: max(0, frames.lowerBound - preRoll), endOutputFrame: frames.upperBound,
            readSource: { range in [Array(samples[range])] })
        let out = try OfflineStretcher.stretchTransposeCurve(
            window: window, sampleRate: sampleRate, ratio: plan.ratio,
            semitonesAtOutputFrame: { plan.semitones(atOutputFrame: $0) },
            formantPreserve: false,
            formant: formant ?? plan.formantCurve(formantPreserve: false),
            compensation: compensation)
        let skip = frames.lowerBound - out.firstOutputFrame
        return Array(out.planar[0][skip..<(skip + frames.count)])
    }

    /// ⭐ **G7, rewritten by R3 on the I1-F1 split.** (a) A window that starts
    /// in the unvoiced gap before the only moved note has CLEAN history (every
    /// earlier hop has T = 0 and F = 0, so the formant stage never ran): it is
    /// the whole-file render, < −90 dB, like I1-F1 gate (a). (b) A window
    /// mid-note after an earlier moved note (transposed history): I1-F1 gate
    /// (b)'s pre-registered spectrum-and-pitch tolerance, from the phase-only
    /// control pair. Its built-in negative control: the same window rendered
    /// WITHOUT the formant curve must fail (b), so (b) can see the formant.
    @Test("G7 engaged window vs whole file: clean-history gap start < −90 dB; transposed history within I1-F1 gate (b), and the curve withheld fails it")
    func engagedWindowMatchesTheWholeFile() throws {
        let voice = SpanRenderSignals.voice(seconds: 6, sampleRate: Self.sampleRate)
        let notes = voice.notes
        func plan(_ edit: (inout [NoteSegment]) -> Void) throws -> StretchCurvePlan {
            var segs = notes
            edit(&segs)
            return try #require(StretchCurvePlan.make(
                editSet: PitchEditSet(segments: segs, retuneMs: 45, formantCorrection: 1),
                clipPitchShiftSemitones: 0, sampleRate: Self.sampleRate, ratio: 1))
        }
        // (a) clean history: only note 3 moves; the window starts in the gap.
        let clean = try plan { $0[3].pitchOffsetCents = 400 }
        let wholeClean = try Self.render([voice.samples], plan: clean, formantPreserve: false)
        let gapStart = Int((notes[2].endSeconds + 0.1) * Self.sampleRate)
        let spanA = gapStart..<Int((notes[3].endSeconds + 0.2) * Self.sampleRate)
        let a = try Self.window(voice.samples, plan: clean, frames: spanA)
        let residualA = SpanRenderMetrics.residualDb(a, Array(wholeClean[spanA]))
        let headA = SpanRenderMetrics.residualDb(Array(a[0..<1_440]), Array(wholeClean[spanA][..<(spanA.lowerBound + 1_440)]))
        print(String(format: "NT-E1|G7| (a) clean-history gap window: %.1f dB (first 30 ms %.1f dB)", residualA, headA))
        #expect(residualA < -90 && headA < -90, "the clean-history engaged window differs by \(residualA) dB")

        // (b) transposed history: note 1 AND note 3 move; the window is mid-note 3.
        let set = try plan { $0[1].pitchOffsetCents = 300; $0[3].pitchOffsetCents = 400 }
        let wholeSet = try Self.render([voice.samples], plan: set, formantPreserve: false)
        let wholeAlone = try Self.render([voice.samples], plan: clean, formantPreserve: false)
        let spanB = Int((notes[3].startSeconds + 0.15) * Self.sampleRate)
            ..< Int((notes[3].endSeconds + 0.2) * Self.sampleRate)
        let control = SpanRenderMetrics.compare(Array(wholeAlone[spanB]), Array(wholeSet[spanB]),
                                                sampleRate: Self.sampleRate, minHz: 80, maxHz: 300)
        let limits = SpanRenderMetrics.Limits(control: control)
        let b = try Self.window(voice.samples, plan: set, frames: spanB)
        let measured = SpanRenderMetrics.compare(Array(wholeSet[spanB]), b,
                                                 sampleRate: Self.sampleRate, minHz: 80, maxHz: 300)
        let withheld = try Self.window(voice.samples, plan: set, frames: spanB, formant: .some(nil))
        let miss = SpanRenderMetrics.compare(Array(wholeSet[spanB]), withheld,
                                             sampleRate: Self.sampleRate, minHz: 80, maxHz: 300)
        print("NT-E1|G7| (b) control \(control); limits \(limits); window \(measured); curve withheld \(miss)")
        #expect(limits.admits(measured), "the engaged mid-note window failed the pre-registered gate")
        #expect(!limits.admits(miss), "a window WITHOUT the formant curve passed: gate (b) cannot see formants")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Physics (G1-G5), on NT-G's instruments
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Material: `SourceFilterVoice` (a pulse train through F1-F4), whose f0 and
    // formant scale are independently known. Envelope: `SpectralEnvelopeMeter
    // .envelopeShiftCents` (250-5000 Hz), which reads ~80-85 % of a planted
    // scale (its own known-answer suite), so every expectation is the METER's
    // reading of a planted scale at the same f0, never raw cents. Pitch: YIN,
    // compared with a same-build LEGACY render (the transposer's current
    // ±10 c error cancels; orchestrator, 2026-09-25).
    //
    // ⭐ PRE-REGISTERED, fixed before any render was measured: the tolerance
    // of every envelope assertion is `max(50 c, 2 × |f0-only control|)`, the
    // control being the meter's reading of the SAME formants at the source f0
    // vs at the moved f0 (what the meter wrongly sees when only pitch moves).

    static let physicsSeconds = 2.0
    /// Five 2048-frame analysis centres inside the note, away from its ramps.
    static let physicsCentres = [0.6, 0.8, 1.0, 1.2, 1.4].map { Int($0 * 48_000) }

    static func sourceVoice(f0: Double, scaleCents: Double = 0, seconds: Double = physicsSeconds)
        -> [Float] {
        SourceFilterVoice.voice(f0Hz: f0, formantScaleCents: scaleCents,
                                frames: Int(seconds * sampleRate), sampleRate: sampleRate)
    }

    static func frame(_ x: [Float], centre: Int, length: Int = 2_048) -> [Float] {
        Array(x[(centre - length / 2)..<(centre + length / 2)])
    }

    /// The meter's envelope shift of `shifted` against `reference`, the
    /// median over `centres`.
    static func envelopeShift(_ reference: [Float], _ shifted: [Float],
                              centres: [Int] = physicsCentres) -> Double {
        let readings = centres.compactMap {
            SpectralEnvelopeMeter.envelopeShiftCents(
                reference: frame(reference, centre: $0), shifted: frame(shifted, centre: $0),
                sampleRate: sampleRate)
        }.sorted()
        return readings.isEmpty ? .nan : readings[readings.count / 2]
    }

    /// Delivered pitch of `shifted` against `reference` in cents (YIN over
    /// 4096 frames at 1.0 s).
    static func pitchCents(_ reference: [Float], _ shifted: [Float], centre: Int = 48_000) -> Double {
        let a = I1Signals.yinHz(frame(reference, centre: centre, length: 4_096)[...],
                                sampleRate: sampleRate, minHz: 40, maxHz: 700)
        let b = I1Signals.yinHz(frame(shifted, centre: centre, length: 4_096)[...],
                                sampleRate: sampleRate, minHz: 40, maxHz: 700)
        guard let a, let b, a > 0, b > 0 else { return .nan }
        return 1200 * log2(b / a)
    }

    /// The pre-registered tolerance for a cell (see the banner above).
    static func tolerance(f0: Double, cents: Double) -> Double {
        let moved = sourceVoice(f0: f0 * pow(2, cents / 1200))
        return max(50, 2 * abs(envelopeShift(sourceVoice(f0: f0), moved)))
    }

    /// The meter's reading of a PLANTED formant scale at `f0` (the known answer).
    static func planted(f0: Double, scaleCents: Double) -> Double {
        envelopeShift(sourceVoice(f0: f0), sourceVoice(f0: f0, scaleCents: scaleCents))
    }

    /// One note over [0.2, 1.8] s (its detected f0 = the source's), moved by
    /// `cents`, with the set's `amount` and the note's own `offset`.
    static func physicsPlan(f0: Double, cents: Double, amount: Double?,
                            offset: Double = 0) throws -> StretchCurvePlan {
        let set = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.2, endSeconds: 1.8, detectedHz: f0, detectedConfidence: 0.95,
                        pitchOffsetCents: cents, formantOffsetSemitones: offset)
        ], retuneMs: 45, formantCorrection: amount)
        return try #require(StretchCurvePlan.make(editSet: set, clipPitchShiftSemitones: 0,
                                                  sampleRate: sampleRate, ratio: 1))
    }

    /// G1 + G2 share one fixture: f0 110 Hz, the note +4 st. G1: the LEGACY
    /// render (nil, flag off) chipmunks, its envelope reading ≈ the meter's
    /// reading of a PLANTED +400 c scale (the positive control), while YIN
    /// reads the +400 c pitch move on the same file.
    @Test("G1 chipmunk is real: a legacy +4 st render moves the envelope like a planted +400 c scale, and the pitch +400 c")
    func g1ChipmunkIsReal() throws {
        let f0 = 110.0
        let source = Self.sourceVoice(f0: f0)
        let plan = try Self.physicsPlan(f0: f0, cents: 400, amount: nil)
        #expect(plan.formantCurve(formantPreserve: false) == nil)
        let legacy = try Self.render([source], plan: plan, formantPreserve: false)
        let shift = Self.envelopeShift(source, legacy)
        let expected = Self.planted(f0: f0, scaleCents: 400)
        let tol = Self.tolerance(f0: f0, cents: 400)
        let pitch = Self.pitchCents(source, legacy)
        print(String(format: "NT-E1|G1| legacy +400 c at %.0f Hz: envelope %.1f c (planted +400 reads %.1f, tol %.1f), pitch %.1f c",
                     f0, shift, expected, tol, pitch))
        #expect(abs(shift - expected) <= tol, "legacy envelope \(shift) vs planted \(expected) ± \(tol)")
        #expect(abs(pitch - 400) <= 35, "the legacy render did not move the pitch +400 c (\(pitch))")
    }

    /// LPC F1/F2 (median over `physicsCentres`), the SECOND instrument.
    static func lpcF1F2(_ x: [Float]) -> (f1: Double, f2: Double) {
        let f = lpcF123(x)
        return (f.f1, f.f2)
    }

    /// LPC F1/F2/F3, each the median over `physicsCentres`.
    static func lpcF123(_ x: [Float]) -> (f1: Double, f2: Double, f3: Double) {
        let reads = physicsCentres.map {
            SpectralEnvelopeMeter.lpcFormants(frame(x, centre: $0), sampleRate: sampleRate)
        }
        func median(_ values: [Double?]) -> Double {
            let v = values.compactMap { $0 }.sorted()
            return v.isEmpty ? .nan : v[v.count / 2]
        }
        return (median(reads.map { $0.f1 }), median(reads.map { $0.f2 }), median(reads.map { $0.f3 }))
    }

    /// ⭐ **G2 KEPT NATURAL** (c = 1; ±3/5/7 st; one case per f0 80/110/220
    /// Hz, run in parallel). THREE claims per cell, kept apart on purpose:
    ///
    ///  0. **Instrument validity** (§1(g): the meter must read a planted scale
    ///     before any gate is trusted). A cell whose planted-scale control
    ///     reads under half the move is UNMEASURABLE and asserts nothing
    ///     else. NT-G2 (m23-nt): `envelopeShiftCents` used to read a planted
    ///     −700 c scale as exactly 0.0 at all three f0 — a floor computed from
    ///     the GLOBAL 0...Nyquist spectrum (compressed-down formants pile
    ///     response toward DC) combined with an unscaled floor OFFSET
    ///     (`peak_log - ln(1000)` applied to a value scaled ~4096× by the
    ///     cepstral round trip) swallowed the entire in-band curve into one
    ///     constant, degenerate array. Both are fixed in `SpectralEnvelopeMeter`
    ///     (in-band peak, K-scaled floor, plus a nil return on a degenerate or
    ///     boundary-saturated search instead of a number that looks like a
    ///     valid answer) — the −7 st cells are measurable now, so this set is
    ///     asserted EMPTY rather than pinned to a specific non-empty value.
    ///  1. **The pre-registered bound**: |reading| ≤ max(50, 2 × f0-only
    ///     control). NT-G2 (m23-nt): under the meter fix that made −7 st
    ///     measurable, ONE cell fails this bound for real and is pinned below
    ///     with its own LPC evidence: 80 Hz −7 st (a meter artefact). NT-E1b
    ///     pins a SECOND, 220 Hz −5 st, as a render residual (below). ⚠️ **p2-acc-3 (vendored
    ///     pitch-shifter patches 0002+0003) merged mid-lane and changes the
    ///     bytes of every transposed render** — every figure in this bullet
    ///     is RE-MEASURED against the current tree (transposeEngineVersion 4,
    ///     this lane's own `./scripts/test.sh --filter` run, 2026-09-25
    ///     22:12), not relayed or carried over from before the merge (the pin
    ///     message below also reads live `e`/`tol` values instead of a
    ///     hard-coded figure, for the same reason: a number frozen in a doc
    ///     comment is the failure mode this whole lane exists to fix). 80 Hz
    ///     −7 st reads −55.3 c against a 50.0 c bound (LPC F1 691→685, F2
    ///     1226→1269, both within 6% — the formants ARE kept).
    ///     ⚠️ **RETIRED**: the pre-existing 110 Hz −3 st pin (formerly +86.6 c
    ///     against HEAD's transpose engine) now reads 4.7 c against a 65.4 c
    ///     bound — it PASSES outright post-merge, self-measured, so its
    ///     `withKnownIssue` wrap was removed (a wrap around a passing
    ///     assertion fails on its own with "Known issue was not recorded" —
    ///     that firing IS the retirement signal, not a loosened test). Its
    ///     LPC print is kept, unasserted, so a future regression stays
    ///     visible by eye.
    ///     ⚠️ **CELLS OUTSIDE THIS PIN, NOT NT-G2's TO FIX**: 220 Hz −5 st
    ///     fails this bound (self-measured: 63.2 c/50.0) — not a NEW render
    ///     defect, but a real one the OLD meter's own f0-only negative
    ///     control was masking: at 220 Hz that control used to read ~65-120 c
    ///     (a poor negative control, §1(g)'s own validity check silently
    ///     failing), inflating this cell's tolerance to 128-240 c. The fixed
    ///     meter's f0-only control reads ≤25 c at every f0 (self-measured,
    ///     same run: 20.1/9.3/3.2 c at 80/110/220 Hz —
    ///     `SpectralEnvelopeMeter`'s own `envelopeShiftIgnoresF0Move`), so the
    ///     tolerance is now valid and this cell fails it for real — filed for
    ///     NT-E1, not pinned or loosened here.
    ///     ⭐ **NT-E1b SETTLED IT: A RENDER RESIDUAL, PINNED, NOT LOOSENED**
    ///     (`probeKeptAgainstTheIdeal`, run2-landing, 2026-09-25 22:44). The
    ///     ideal kept signal (the source's formants at the moved f0, 164.8 Hz)
    ///     is LPC's own positive control: LPC reads it within +1.2/+0.7/−0.3 %
    ///     of the source, so LPC is valid here. Against that ideal the engaged
    ///     render reads F1 −5.3 %, F2 +12.5 %, F3 +0.3 %: F2 is NOT kept
    ///     (step 3 of the brief). The size is the cepstral meter's, against
    ///     the ideal: +63.6 c, an OVER-correction of 17 % of the legacy move
    ///     (the withheld curve reads −372.2 c) in the opposite direction; LPC's
    ///     +12.5 % is F2 snapping to the moved f0's 8th harmonic (1318 Hz).
    ///     Upstream's own vocal mode reads +64.7 c against the same ideal, so
    ///     it is signalsmith's formant compensation, not the explicit base.
    ///     And it is SYSTEMIC to 220 Hz down-shifts: −300 and −700 read +65.2
    ///     and +62.5 c against the ideal and pass the source-relative bound
    ///     only because their f0-only offsets (−17.0, −15.9 c) cancel part of
    ///     it; −500 is where it crosses 50 c. Filed as a follow-up; the
    ///     library is not changed.
    ///     ⭐ **NT-F220: FIXED IN THE LIBRARY, PIN RETIRED** (vendored patch
    ///     0004, `formantRenderVersion` 3). The residual was the library's
    ///     formant ENVELOPE, not its compensation arithmetic: with the input
    ///     spectrum's true envelope substituted for signalsmith's (and nothing
    ///     else changed) the per-harmonic error falls to ±0.1 dB. The old
    ///     envelope sagged ~4 dB between two strong harmonics and gave a weak
    ///     harmonic its neighbour's skirt; 0004 draws it through the harmonic
    ///     peaks whenever the caller hands over a base. This cell now reads
    ///     16.5 c (MEASURED on the product's own test build, W7-F220I, and
    ///     equal to the W7-F220 port's prediction; −300 and −700: 18.7 and
    ///     −3.1 c). The 80 Hz −7 st pin stays (its cepstral reading moves
    ///     −55.3 → −65.7 c, while LPC moves CLOSER to the source: kept F1
    ///     685 → 691 and F2 1269 → 1247, against the source's 691 and 1226).
    ///     The figures in the bullets above are version 2's. 220 Hz +7 st,
    ///     which also failed before p2-acc-3, is now green (self-measured:
    ///     42.4 c/50.0 at version 2; −18.7 c at version 3)
    ///     — a transpose-engine effect, unrelated to NT-G2's meter work.
    ///  2. **No worse than upstream's vocal mode** (added after the probe, and
    ///     said so): |reading| ≤ |legacy flag-ON reading| + tolerance. The
    ///     integration's own claim: the explicit base adds no error over the
    ///     library's estimator (it is better at 80 Hz).
    ///
    /// Negative controls, in-test: the branch WITHHELD must fail (1); at 80 Hz
    /// (the design's guard for risk 3) the UNITS TRAP, a base handed over in
    /// Hz where cycles/sample belong (the closure's Hz × the rate, which the
    /// shim divides back to raw Hz), must fail it too. Pitch: the formant stage
    /// must not bend it (within 10 c of the legacy render, within 35 c of the
    /// move).
    @Test("G2 kept natural: c = 1 holds the envelope at ±3/5/7 st while the pitch moves (meter-valid cells); the withheld curve and the units trap fail",
          arguments: [80.0, 110.0, 220.0])
    func g2KeptNatural(f0: Double) throws {
        let source = Self.sourceVoice(f0: f0)
        var unmeasurable: [Double] = []
        for semitones in [-7.0, -5.0, -3.0, 3.0, 5.0, 7.0] {
            let cents = semitones * 100
            let planted = Self.planted(f0: f0, scaleCents: cents)
            guard abs(planted) >= 0.5 * abs(cents) else {
                print(String(format: "NT-E1|G2| f0 %3.0f %+4.0f c: UNMEASURABLE, the meter reads a planted %+.0f c scale as %.1f c",
                             f0, cents, cents, planted))
                unmeasurable.append(cents)
                continue
            }
            let plan = try Self.physicsPlan(f0: f0, cents: cents, amount: 1)
            let kept = try Self.render([source], plan: plan, formantPreserve: false)
            let withheld = try Self.render([source], plan: plan, formantPreserve: false, formant: .some(nil))
            let upstream = try Self.render([source], plan: plan, formantPreserve: true, formant: .some(nil))
            let tol = Self.tolerance(f0: f0, cents: cents)
            let e = Self.envelopeShift(source, kept)
            let eWithheld = Self.envelopeShift(source, withheld)
            let eUpstream = Self.envelopeShift(source, upstream)
            let pitch = Self.pitchCents(source, kept)
            let pitchLegacy = Self.pitchCents(source, withheld)
            var trapNote = ""
            if f0 == 80, let curve = plan.formantCurve(formantPreserve: false) {
                let trap = OfflineStretcher.FormantCurve(
                    semitonesAtOutputFrame: curve.semitonesAtOutputFrame,
                    baseHzAtOutputFrame: { curve.baseHzAtOutputFrame($0) * Self.sampleRate })
                let eTrap = Self.envelopeShift(
                    source, try Self.render([source], plan: plan, formantPreserve: false, formant: .some(trap)))
                trapNote = String(format: " | units trap %.1f", eTrap)
                #expect(abs(eTrap) > tol, "f0 80 \(cents) c: the units trap passed (\(eTrap)): risk 3 is invisible")
            }
            print(String(format: "NT-E1|G2| f0 %3.0f %+4.0f c: kept %6.1f c (tol %5.1f, planted %6.1f) | upstream vocal mode %6.1f | withheld %6.1f%@ | pitch %7.1f vs legacy %7.1f",
                         f0, cents, e, tol, planted, eUpstream, eWithheld, trapNote, pitch, pitchLegacy))
            // m23-nt NT-G2: the OLD 110 Hz −3 st (−300 c) pin was measured
            // AGAINST HEAD's transpose engine, before p2-acc-3 (vendored
            // pitch-shifter patches 0002+0003) merged underneath this work and
            // changed the bytes of every transposed render. RE-MEASURED
            // against the current tree (transposeEngineVersion 4, this lane's
            // own real test run, 2026-09-25 22:12): the 110 Hz cell now reads
            // 4.7 c against a 65.4 c tolerance — it PASSES the bound outright,
            // so its `withKnownIssue` wrap was removed (it would itself fail
            // with "Known issue was not recorded", which is exactly what a
            // self-invalidating pin is for — this is that pin going off as
            // designed, not a loosened test). The LPC print for that cell is
            // kept below as a plain print (no assertion) so a future
            // regression is still visible by eye without re-adding a pin
            // nobody has re-earned. 80 Hz −7 st is the one cell still
            // measurably failing post-merge (RE-MEASURED, same run: reads
            // −55.3 c against 50.0 c, LPC F1 691→685 / F2 1226→1269, both
            // within 6% — the formants ARE kept, the cepstral meter alone is
            // wrong here) and stays pinned.
            let knownIssueCell = (f0 == 80 && cents == -700)
            let retiredPinCell = (f0 == 110 && cents == -300)
            // NT-E1b's RENDER RESIDUAL at 220 Hz −5 st (the bullet above) was
            // signalsmith's formant envelope, and vendored patch 0004
            // (formantRenderVersion 3, NT-F220) fixed it in the library: the
            // cell now reads inside the bound, so its `withKnownIssue` went off
            // ("Known issue was not recorded") and was removed, with the
            // CHARACTER check that only kept that pin honest. The plain bound
            // below holds the cell like every other. The LPC print stays,
            // unasserted, the 110 Hz −3 st precedent.
            let retiredResidualCell = (f0 == 220 && cents == -500)
            if retiredResidualCell {
                let lpcSource = Self.lpcF123(source)
                let lpcKept = Self.lpcF123(kept)
                print(String(format: "NT-E1|G2| f0 %.0f %+.0f c LPC: source F1 %.0f F2 %.0f F3 %.0f, kept F1 %.0f F2 %.0f F3 %.0f | retired residual: %.1f c = %.0f %% of the withheld move %.1f c",
                             f0, cents, lpcSource.f1, lpcSource.f2, lpcSource.f3,
                             lpcKept.f1, lpcKept.f2, lpcKept.f3, e, 100 * abs(e / eWithheld), eWithheld))
            }
            if knownIssueCell || retiredPinCell {
                let lpcSource = Self.lpcF1F2(source)
                let lpcKept = Self.lpcF1F2(kept)
                print(String(format: "NT-E1|G2| f0 %.0f %+.0f c LPC: source F1 %.0f F2 %.0f, kept F1 %.0f F2 %.0f",
                             f0, cents, lpcSource.f1, lpcSource.f2, lpcKept.f1, lpcKept.f2))
                if knownIssueCell {
                    #expect(abs(lpcKept.f1 / lpcSource.f1 - 1) < 0.06 && abs(lpcKept.f2 / lpcSource.f2 - 1) < 0.06,
                            "the LPC evidence behind the known issue no longer holds: the formants moved")
                }
            }
            if knownIssueCell {
                withKnownIssue("cepstral meter artefact at f0 \(f0) \(cents) c: reads \(String(format: "%.1f", e)) c against tol \(String(format: "%.1f", tol)); LPC F1/F2 (printed above) says the formants are kept") {
                    #expect(abs(e) <= tol, "f0 \(f0) \(cents) c: kept envelope \(e) outside ±\(tol)")
                }
            } else {
                #expect(abs(e) <= tol, "f0 \(f0) \(cents) c: kept envelope \(e) outside ±\(tol)")
            }
            #expect(abs(e) <= abs(eUpstream) + tol,
                    "f0 \(f0) \(cents) c: the engaged branch (\(e)) is worse than upstream's vocal mode (\(eUpstream))")
            #expect(abs(eWithheld) > tol, "f0 \(f0) \(cents) c: the withheld curve passed (\(eWithheld))")
            #expect(abs(pitch - pitchLegacy) <= 10 && abs(pitch - cents) <= 35,
                    "f0 \(f0) \(cents) c: pitch \(pitch) vs legacy \(pitchLegacy)")
        }
        #expect(unmeasurable.isEmpty, "f0 \(f0): unmeasurable cells (meter regression?): \(unmeasurable)")
    }

    /// G3 THE AMOUNT IS THE AXIS (+4 st, f0 110): readings strictly ordered
    /// c = 0 > 0.5 > 0.75 > 1, each ≈ (1 − c) × the c = 0 reading, and c = 0
    /// ≈ G1's legacy reading (R6: at c = 0 the formant stage undoes itself).
    /// The plant (c ignored, forced to 1) is run in-test: its four readings
    /// must NOT pass the ordering. Distinct bytes alone prove nothing.
    @Test("G3 the amount is the axis: c = 0/0.5/0.75/1 read strictly ordered, ≈ (1 − c) × c=0, and c = 0 ≈ legacy; c forced to 1 fails")
    func g3AmountIsTheAxis() throws {
        let f0 = 110.0
        let source = Self.sourceVoice(f0: f0)
        let tol = Self.tolerance(f0: f0, cents: 400)
        func reading(_ amount: Double?, forceTo1: Bool = false) throws -> Double {
            let plan = try Self.physicsPlan(f0: f0, cents: 400, amount: forceTo1 ? 1 : amount)
            return Self.envelopeShift(source, try Self.render([source], plan: plan, formantPreserve: false))
        }
        func ordered(_ r: [Double]) -> Bool {
            zip(r, r.dropFirst()).allSatisfy { $0 - $1 > tol / 2 }
        }
        let amounts = [0.0, 0.5, 0.75, 1.0]
        let readings = try amounts.map { try reading($0) }
        let legacy = try reading(nil)
        let forced = try amounts.map { try reading($0, forceTo1: true) }
        print("NT-E1|G3| +400 c at 110 Hz, c 0/0.5/0.75/1: \(readings.map { String(format: "%.1f", $0) }) (legacy \(String(format: "%.1f", legacy)), tol \(String(format: "%.1f", tol))); c forced to 1: \(forced.map { String(format: "%.1f", $0) })")
        #expect(ordered(readings), "the four amounts are not strictly ordered")
        for (c, r) in zip(amounts, readings) {
            #expect(abs(r - (1 - c) * readings[0]) <= tol, "c \(c): \(r) vs \((1 - c) * readings[0])")
        }
        #expect(abs(readings[0] - legacy) <= tol, "c = 0 (\(readings[0])) is not ≈ the legacy render (\(legacy))")
        #expect(!ordered(forced), "control: c forced to 1 still passed the ordering, so it proves nothing")
    }

    /// ⭐ **G5 PER-NOTE OFFSET** (RED ON HEAD: NT-G's baseline read 0.3 c
    /// against a −160.5 c control, because the field was unread). Three
    /// abutting notes at f0 110, NO pitch move, the middle one −2 st: its
    /// envelope reads ≈ the meter's reading of a planted −200 c scale, its
    /// pitch ≈ 0 (nothing moves it: ±10 c), and both
    /// neighbours read ≈ 0, measured only beyond the ramp half-width + 60 ms
    /// (R11). The wrong-note plant runs in-test: the offset on the FIRST note
    /// must fail the same predicate.
    @Test("G5 a −2 st Voice offset moves that note's envelope like a planted −200 c scale, not its pitch, not its neighbours; on the wrong note it fails")
    func g5PerNoteOffset() throws {
        let f0 = 110.0
        let seconds = 3.0
        let source = Self.sourceVoice(f0: f0, seconds: seconds)
        func plan(offsetOn index: Int) throws -> StretchCurvePlan {
            var notes = [
                NoteSegment(startSeconds: 0.2, endSeconds: 1.0, detectedHz: f0, detectedConfidence: 0.95),
                NoteSegment(startSeconds: 1.0, endSeconds: 1.8, detectedHz: f0, detectedConfidence: 0.95),
                NoteSegment(startSeconds: 1.8, endSeconds: 2.8, detectedHz: f0, detectedConfidence: 0.95),
            ]
            notes[index].formantOffsetSemitones = -2
            return try #require(StretchCurvePlan.make(
                editSet: PitchEditSet(segments: notes, retuneMs: 45, formantCorrection: 1),
                clipPitchShiftSemitones: 0, sampleRate: Self.sampleRate, ratio: 1))
        }
        let edited = [1.25, 1.4, 1.55].map { Int($0 * Self.sampleRate) }
        let before = [0.45, 0.6, 0.75].map { Int($0 * Self.sampleRate) }
        let after = [2.1, 2.3, 2.5].map { Int($0 * Self.sampleRate) }
        let expected = Self.planted(f0: f0, scaleCents: -200)
        let tol = Self.tolerance(f0: f0, cents: -200)
        func verdict(_ rendered: [Float], label: String) -> Bool {
            let e = Self.envelopeShift(source, rendered, centres: edited)
            let n1 = Self.envelopeShift(source, rendered, centres: before)
            let n2 = Self.envelopeShift(source, rendered, centres: after)
            let pitch = Self.pitchCents(source, rendered, centre: Int(1.4 * Self.sampleRate))
            print(String(format: "NT-E1|G5| %@: edited note %.1f c (planted −200 reads %.1f, tol %.1f), neighbours %.1f / %.1f c, pitch %.1f c",
                         label, e, expected, tol, n1, n2, pitch))
            return abs(e - expected) <= tol && abs(n1) <= tol && abs(n2) <= tol && abs(pitch) <= 10
        }
        let right = try Self.render([source], plan: try plan(offsetOn: 1), formantPreserve: false)
        #expect(verdict(right, label: "offset on the middle note"),
                "the Voice offset did not move that note's envelope, or moved its pitch or neighbours")
        let wrong = try Self.render([source], plan: try plan(offsetOn: 0), formantPreserve: false)
        #expect(!verdict(wrong, label: "PLANT offset on the first note"),
                "control: an offset on the wrong note passed, so G5 cannot tell notes apart")
    }

    /// Where a −4 st envelope step between two abutting notes (boundary at
    /// 1.5 s, the ramp's 50 % point) lands in `rendered`: the frame where the
    /// sliding envelope reading (2048-frame windows every 240 frames) crosses
    /// half way between its plateaus, linearly interpolated.
    static func envelopeStepLanding(_ source: [Float], _ rendered: [Float]) -> (frame: Double, low: Double, high: Double)? {
        let stride = 240
        let centres = Array(Swift.stride(from: Int(1.30 * sampleRate), through: Int(1.75 * sampleRate), by: stride))
        let readings = centres.map { centre in
            SpectralEnvelopeMeter.envelopeShiftCents(
                reference: frame(source, centre: centre), shifted: frame(rendered, centre: centre),
                sampleRate: sampleRate) ?? .nan
        }
        let head = readings.prefix(12).sorted()[6]
        let tail = readings.suffix(12).sorted()[6]
        let half = (head + tail) / 2
        for i in 1..<readings.count where (readings[i - 1] - half) * (readings[i] - half) <= 0
            && readings[i - 1] != readings[i] {
            let t = (half - readings[i - 1]) / (readings[i] - readings[i - 1])
            return (Double(centres[i - 1]) + t * Double(stride), head, tail)
        }
        return nil
    }

    /// ⭐ **G4 FORMANT LATENCY** (X11: it gates the formant engine merge). A
    /// Voice-offset step (T = 0, F 0 → −4 st at the boundary) must land where
    /// a TRANSPOSE step on the same fixture lands (the positive control: a
    /// legacy −4 st pitch step, whose envelope rides the pitch), within half a
    /// hop, measured by the SAME sliding envelope instrument so its bias
    /// cancels. Compensated (the shipping path) and raw (`.none`, the E1(a)
    /// path, where the transpose is MEASURED to land 2379 frames late). The
    /// plant runs in-test: the formant looked up ONE HOP LATE must miss.
    @Test("G4 a formant step lands with a transpose step (± half a hop), compensated and raw; one hop late fails",
          arguments: ["compensated", "raw"])
    func g4FormantLandsWithTheTranspose(label: String) throws {
        let f0 = 110.0
        let source = Self.sourceVoice(f0: f0, seconds: 3)
        func set(pitchStep: Bool, amount: Double?) -> PitchEditSet {
            PitchEditSet(segments: [
                NoteSegment(startSeconds: 0.2, endSeconds: 1.5, detectedHz: f0, detectedConfidence: 0.95),
                NoteSegment(startSeconds: 1.5, endSeconds: 2.8, detectedHz: f0, detectedConfidence: 0.95,
                            pitchOffsetCents: pitchStep ? -400 : 0,
                            formantOffsetSemitones: pitchStep ? 0 : -4),
            ], retuneMs: 30, formantCorrection: amount)
        }
        let interval = 1_440
        let compensation = label == "raw" ? OfflineStretcher.CurveLatencyCompensation.none
            : Self.compensation
        do {
            func render(_ set: PitchEditSet, lateByOneHop: Bool = false) throws -> [Float] {
                let plan = try #require(StretchCurvePlan.make(editSet: set, clipPitchShiftSemitones: 0,
                                                              sampleRate: Self.sampleRate, ratio: 1))
                var formant = plan.formantCurve(formantPreserve: false)
                if lateByOneHop, let real = formant {
                    formant = OfflineStretcher.FormantCurve(
                        semitonesAtOutputFrame: { real.semitonesAtOutputFrame($0 - interval) },
                        baseHzAtOutputFrame: real.baseHzAtOutputFrame)
                }
                return try OfflineStretcher.stretchTransposeCurve(
                    input: [source], sampleRate: Self.sampleRate, ratio: 1,
                    semitonesAtOutputFrame: { plan.semitones(atOutputFrame: $0) },
                    formantPreserve: false, formant: formant, compensation: compensation)[0]
            }
            let transpose = try #require(Self.envelopeStepLanding(
                source, try render(set(pitchStep: true, amount: nil))))
            let formant = try #require(Self.envelopeStepLanding(
                source, try render(set(pitchStep: false, amount: 1))))
            let late = try #require(Self.envelopeStepLanding(
                source, try render(set(pitchStep: false, amount: 1), lateByOneHop: true)))
            let boundary = 1.5 * Self.sampleRate
            print(String(format: "NT-E1|G4| %@: transpose step lands %+.0f frames from the boundary (%.0f → %.0f c), formant step %+.0f (%.0f → %.0f c), Δ %+.0f; PLANT one hop late %+.0f (Δ %+.0f)",
                         label, transpose.frame - boundary, transpose.low, transpose.high,
                         formant.frame - boundary, formant.low, formant.high,
                         formant.frame - transpose.frame, late.frame - boundary,
                         late.frame - transpose.frame))
            #expect(abs(formant.frame - transpose.frame) <= Double(interval) / 2,
                    "\(label): the formant step lands \(formant.frame - transpose.frame) frames from the transpose step")
            #expect(abs(late.frame - transpose.frame) > Double(interval) / 2,
                    "\(label): control: a formant read one hop late still landed with the transpose")
            #expect(formant.high < formant.low - 150 && transpose.high < transpose.low - 150,
                    "\(label): a step did not move the envelope far enough to locate")
        }
    }

    /// DIAGNOSTIC PROBE (env-gated, `NT_E1_PROBE=1`; asserts nothing): where
    /// does c = 1's residual envelope reading come from? Per cell: the meter's
    /// planted-scale reading, the f0-only control, legacy flag OFF (chipmunk),
    /// legacy flag ON (upstream's own vocal mode: base 0, its estimator), the
    /// engaged branch (explicit base), and the engaged branch with the R8
    /// half-bin offset undone (diagnostic only: R8 rules it is NOT
    /// compensated without a version bump). Readings are the median of five
    /// frames, with their min/max.
    @Test("PROBE: c = 1 residual vs upstream's vocal mode (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["NT_E1_PROBE"] == "1"))
    func probeKeptResidual() throws {
        func spread(_ reference: [Float], _ shifted: [Float]) -> String {
            let r = Self.physicsCentres.compactMap {
                SpectralEnvelopeMeter.envelopeShiftCents(
                    reference: Self.frame(reference, centre: $0), shifted: Self.frame(shifted, centre: $0),
                    sampleRate: Self.sampleRate)
            }.sorted()
            guard let lo = r.first, let hi = r.last else { return "  nil" }
            return String(format: "%6.1f [%6.1f,%6.1f]", r[r.count / 2], lo, hi)
        }
        let halfBinHz = 0.5 * Self.sampleRate / 6_144
        for f0 in [80.0, 110.0, 220.0] {
            let source = Self.sourceVoice(f0: f0)
            for cents in [-700.0, -500.0, -300.0, 300.0, 500.0, 700.0] {
                let plan = try Self.physicsPlan(f0: f0, cents: cents, amount: 1)
                let curve = try #require(plan.formantCurve(formantPreserve: false))
                let legacyOff = try Self.render([source], plan: plan, formantPreserve: false, formant: .some(nil))
                let legacyOn = try Self.render([source], plan: plan, formantPreserve: true, formant: .some(nil))
                let kept = try Self.render([source], plan: plan, formantPreserve: false)
                let r8 = try Self.render([source], plan: plan, formantPreserve: false, formant: .some(
                    OfflineStretcher.FormantCurve(semitonesAtOutputFrame: curve.semitonesAtOutputFrame,
                                                  baseHzAtOutputFrame: { curve.baseHzAtOutputFrame($0) + halfBinHz })))
                let movedF0 = Self.sourceVoice(f0: f0 * pow(2, cents / 1200))
                print(String(format: "NT-E1|probe| f0 %3.0f %+4.0f c | planted %@ | f0-only %@ | legacy off %@ | legacy ON %@ | engaged %@ | engaged R8-undone %@",
                             f0, cents,
                             spread(source, Self.sourceVoice(f0: f0, scaleCents: cents)),
                             spread(source, movedF0), spread(source, legacyOff), spread(source, legacyOn),
                             spread(source, kept), spread(source, r8)))
            }
        }
    }

    /// DIAGNOSTIC PROBE 2 (env-gated, `NT_E1_PROBE=1`): the SECOND instrument
    /// on the cells where the cepstral meter reads a c = 1 residual. LPC
    /// F1/F2/F3 (median over the five centres) of the source, legacy flag
    /// OFF, legacy flag ON (upstream's vocal mode) and the engaged branch.
    /// If LPC puts the engaged formants at the source's while the cepstral
    /// meter reads a residual, the residual is the meter's.
    @Test("PROBE: LPC cross-check of the c = 1 residual (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["NT_E1_PROBE"] == "1"))
    func probeLPCCrossCheck() throws {
        func lpc(_ x: [Float]) -> String {
            let reads = Self.physicsCentres.map {
                SpectralEnvelopeMeter.lpcFormants(Self.frame(x, centre: $0), sampleRate: Self.sampleRate)
            }
            func median(_ values: [Double?]) -> Double {
                let v = values.compactMap { $0 }.sorted()
                return v.isEmpty ? .nan : v[v.count / 2]
            }
            return String(format: "F1 %5.0f F2 %5.0f F3 %5.0f",
                          median(reads.map { $0.f1 }), median(reads.map { $0.f2 }), median(reads.map { $0.f3 }))
        }
        for (f0, cents) in [(110.0, -300.0), (110.0, 300.0), (110.0, 500.0), (220.0, -500.0), (80.0, -500.0)] {
            let source = Self.sourceVoice(f0: f0)
            let plan = try Self.physicsPlan(f0: f0, cents: cents, amount: 1)
            let off = try Self.render([source], plan: plan, formantPreserve: false, formant: .some(nil))
            let on = try Self.render([source], plan: plan, formantPreserve: true, formant: .some(nil))
            let kept = try Self.render([source], plan: plan, formantPreserve: false)
            let factor = pow(2, cents / 1200)
            print(String(format: "NT-E1|lpc| f0 %3.0f %+4.0f c (a full follow scales formants ×%.3f) | source %@ | legacy off %@ | legacy ON %@ | engaged %@",
                         f0, cents, factor, lpc(source), lpc(off), lpc(on), lpc(kept)))
        }
    }

    /// DIAGNOSTIC PROBE 3 (env-gated, `NT_E1_PROBE=1`; NT-E1b; asserts
    /// nothing): G2's 220 Hz −500 c cell, with LPC's OWN positive control.
    /// At a moved f0 of 164.8 Hz, LPC peaks can latch onto harmonics, so each
    /// cell also measures the IDEAL kept signal: the source's formants at the
    /// moved f0 (`SourceFilterVoice`, known by construction). LPC F1/F2/F3 of
    /// the source, the ideal, the engaged render, the legacy render (curve
    /// withheld) and upstream's vocal mode; the cepstral meter against the
    /// source and against the ideal. Passing and pinned cells for scale.
    @Test("PROBE: G2 220 Hz −500 c, LPC against the ideal kept signal (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["NT_E1_PROBE"] == "1"))
    func probeKeptAgainstTheIdeal() throws {
        func lpc(_ x: [Float]) -> String {
            let f = Self.lpcF123(x)
            return String(format: "F1 %5.0f F2 %5.0f F3 %5.0f", f.f1, f.f2, f.f3)
        }
        func ratios(_ x: [Float], _ reference: [Float]) -> String {
            let a = Self.lpcF123(x), b = Self.lpcF123(reference)
            return String(format: "%+5.1f%% %+5.1f%% %+5.1f%%", 100 * (a.f1 / b.f1 - 1),
                          100 * (a.f2 / b.f2 - 1), 100 * (a.f3 / b.f3 - 1))
        }
        for (f0, cents) in [(220.0, -500.0), (220.0, -300.0), (220.0, -700.0), (110.0, -500.0), (80.0, -700.0)] {
            let source = Self.sourceVoice(f0: f0)
            let ideal = Self.sourceVoice(f0: f0 * pow(2, cents / 1200))
            let plan = try Self.physicsPlan(f0: f0, cents: cents, amount: 1)
            let kept = try Self.render([source], plan: plan, formantPreserve: false)
            let legacy = try Self.render([source], plan: plan, formantPreserve: false, formant: .some(nil))
            let upstream = try Self.render([source], plan: plan, formantPreserve: true, formant: .some(nil))
            print(String(format: "NT-E1b|ideal| f0 %3.0f %+4.0f c | LPC source %@ | ideal %@ | kept %@ | legacy %@ | upstream %@",
                         f0, cents, lpc(source), lpc(ideal), lpc(kept), lpc(legacy), lpc(upstream)))
            print(String(format: "NT-E1b|ideal| f0 %3.0f %+4.0f c | LPC vs source: ideal %@ | kept %@ | legacy %@ || kept vs ideal %@ | legacy vs ideal %@",
                         f0, cents, ratios(ideal, source), ratios(kept, source), ratios(legacy, source),
                         ratios(kept, ideal), ratios(legacy, ideal)))
            print(String(format: "NT-E1b|ideal| f0 %3.0f %+4.0f c | cepstral vs source: ideal (f0-only) %.1f, kept %.1f, legacy %.1f, upstream %.1f || vs ideal: kept %.1f, legacy %.1f, upstream %.1f",
                         f0, cents, Self.envelopeShift(source, ideal), Self.envelopeShift(source, kept),
                         Self.envelopeShift(source, legacy), Self.envelopeShift(source, upstream),
                         Self.envelopeShift(ideal, kept), Self.envelopeShift(ideal, legacy),
                         Self.envelopeShift(ideal, upstream)))
        }
    }

    /// R11 MEASUREMENT (env-gated, `NT_E1_PROBE=1`; asserts nothing): the
    /// shortest note whose Voice offset reaches it and not its neighbours.
    /// A note of duration d between two long abutting notes (f0 110, no pitch
    /// move, retune 45 ms), offset −3 st. Reported per d: the reading at the
    /// note's centre as a fraction of a 1 s note's reading (one 2048-frame
    /// window, 43 ms, so d below ~50 ms is under-resolved by the meter too),
    /// and the leak into each neighbour 60 ms past the ramp. The constant
    /// (`PitchEditSet.minimumVoiceNoteSeconds`) is DAWCore's (NT-C), from here.
    @Test("PROBE: R11 shortest note the Voice offset can isolate (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["NT_E1_PROBE"] == "1"))
    func probeMinimumVoiceNote() throws {
        let f0 = 110.0
        let source = Self.sourceVoice(f0: f0, seconds: 3)
        let start = 1.2
        func reading(_ d: Double) throws -> (centre: Double, before: Double, after: Double) {
            let notes = [
                NoteSegment(startSeconds: 0.2, endSeconds: start, detectedHz: f0, detectedConfidence: 0.95),
                NoteSegment(startSeconds: start, endSeconds: start + d, detectedHz: f0, detectedConfidence: 0.95,
                            formantOffsetSemitones: -3),
                NoteSegment(startSeconds: start + d, endSeconds: 2.8, detectedHz: f0, detectedConfidence: 0.95),
            ]
            let plan = try #require(StretchCurvePlan.make(
                editSet: PitchEditSet(segments: notes, retuneMs: 45, formantCorrection: 1),
                clipPitchShiftSemitones: 0, sampleRate: Self.sampleRate, ratio: 1))
            let out = try Self.render([source], plan: plan, formantPreserve: false)
            let halfRamp = min(0.0225, d / 2)
            func at(_ t: Double) -> Double {
                Self.envelopeShift(source, out, centres: [Int(t * Self.sampleRate)])
            }
            return (at(start + d / 2), at(start - halfRamp - 0.06), at(start + d + halfRamp + 0.06))
        }
        let full = try reading(1.0).centre
        for d in [0.03, 0.045, 0.06, 0.08, 0.10, 0.12, 0.15, 0.18, 0.24, 0.30, 0.40] {
            let r = try reading(d)
            print(String(format: "NT-E1|R11| note %4.0f ms: centre %6.1f c = %3.0f %% of a 1 s note (%.1f c); leak before %5.1f c (%3.0f %%), after %5.1f c (%3.0f %%)",
                         d * 1000, r.centre, 100 * r.centre / full, full, r.before, 100 * r.before / full,
                         r.after, 100 * r.after / full))
        }
    }

    /// ⭐ **G2b SMALL MOVES STAY TRANSPARENT** (risk 5a: at c = 1 the formant
    /// stage runs at EVERY hop where T ≠ 0, i.e. on nearly every corrected
    /// note, not only on far moves). Five consecutive notes at f0 110, each
    /// moved ≤ 50 c (ordinary preset-size corrections), retune 110 ms (the
    /// Natural preset's). c = nil vs c = 1 over the notes, by the I1-F1
    /// log-spectral-distance + pitch metric, within limits PRE-REGISTERED from
    /// a phase-only control pair (the same legacy set with and without one
    /// extra edit BEFORE the span: the phase wake, and nothing else).
    /// Positive control: the +4 st pair (G1's) must EXCEED the same limits.
    /// Plant, in-test: a gentle spectral tilt (y = x − 0.5·x[n−1]) injected
    /// into the c = 1 side must fail.
    @Test("G2b small moves stay transparent: c = nil vs c = 1 within the phase-only control's limits; +4 st exceeds them; an injected tilt fails")
    func g2bSmallMovesStayTransparent() throws {
        let f0 = 110.0
        let source = Self.sourceVoice(f0: f0, seconds: 3)
        let moves = [30.0, -45.0, 20.0, -50.0, 40.0]
        func plan(amount: Double?, prefixEdit: Bool = false) throws -> StretchCurvePlan {
            var notes = moves.enumerated().map { i, cents in
                NoteSegment(startSeconds: 0.2 + 0.5 * Double(i), endSeconds: 0.7 + 0.5 * Double(i),
                            detectedHz: f0, detectedConfidence: 0.95, pitchOffsetCents: cents)
            }
            if prefixEdit {
                notes.insert(NoteSegment(startSeconds: 0.0, endSeconds: 0.12, detectedHz: f0,
                                         detectedConfidence: 0.95, pitchOffsetCents: 30), at: 0)
            }
            return try #require(StretchCurvePlan.make(
                editSet: PitchEditSet(segments: notes, retuneMs: 110, formantCorrection: amount),
                clipPitchShiftSemitones: 0, sampleRate: Self.sampleRate, ratio: 1))
        }
        let span = Int(0.3 * Self.sampleRate)..<Int(2.65 * Self.sampleRate)
        func compare(_ a: [Float], _ b: [Float]) -> SpanRenderMetrics.Comparison {
            SpanRenderMetrics.compare(Array(a[span]), Array(b[span]), sampleRate: Self.sampleRate,
                                      minHz: 80, maxHz: 300)
        }
        let legacy = try Self.render([source], plan: try plan(amount: nil), formantPreserve: false)
        let legacyWake = try Self.render([source], plan: try plan(amount: nil, prefixEdit: true),
                                         formantPreserve: false)
        let engaged = try Self.render([source], plan: try plan(amount: 1), formantPreserve: false)
        let control = compare(legacy, legacyWake)
        let limits = SpanRenderMetrics.Limits(control: control)
        let measured = compare(legacy, engaged)
        var tilted = engaged
        for i in stride(from: tilted.count - 1, to: 0, by: -1) { tilted[i] -= 0.5 * engaged[i - 1] }
        let plant = compare(legacy, tilted)
        let farPlan = try Self.physicsPlan(f0: f0, cents: 400, amount: 1)
        let farSource = Self.sourceVoice(f0: f0)
        let farSpan = Int(0.3 * Self.sampleRate)..<Int(1.7 * Self.sampleRate)
        let far = SpanRenderMetrics.compare(
            Array(try Self.render([farSource], plan: farPlan, formantPreserve: false, formant: .some(nil))[farSpan]),
            Array(try Self.render([farSource], plan: farPlan, formantPreserve: false)[farSpan]),
            sampleRate: Self.sampleRate, minHz: 80, maxHz: 400)
        print("NT-E1|G2b| control \(control); limits \(limits); c=nil vs c=1 \(measured); +4 st pair \(far); PLANT tilt \(plant)")
        #expect(limits.admits(measured), "c = 1 colours ordinary small corrections beyond the phase-only control")
        #expect(!limits.admits(far), "control: the +4 st formant change passed, so G2b cannot see a formant change")
        #expect(!limits.admits(plant), "control: an injected tilt passed, so G2b cannot see colouration")
    }
}
