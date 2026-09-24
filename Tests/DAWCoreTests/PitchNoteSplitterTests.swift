import Foundation
import Testing
@testable import DAWCore

// p2-seg S2 — THE NOTE SPLITTER (`Sources/DAWCore/PitchNoteSplitter.swift`) and the
// two note-table builders that read it. Design
// `docs/design/2026-09-24-pitch-note-splitting.md` §1.3 (the rule), §2 (the
// over-split guard), §3.2/§3.4 (the slide shapes), §5.2 (invariance), §5.3 (fixtures,
// twins, threshold pins), amended by §12 and §14; bounds from §13.
//
// Not `@MainActor`: the splitter is pure DAWCore, and `MainActorOccupancySiteTests`
// Leg C (cap 394, census 393) counts suite-level `@MainActor`.
//
// ═══ ON FIXTURES ═══
// Every fixture is a DETECTED CONTOUR — per-frame pitch readings, the detector's
// output — never audio (the real-detector legs are `PitchNoteSplitterDetectorTests`
// in DAWEngineTests). Readings are QUANTISED to SwiftF0's 25.79 c output bins, so the
// detector's staircase is present, and swept over 16 DISTINCT bin offsets (k · 25.79/16
// c) paired with 16 vibrato phases — design §14 item 4: S1's phase list gave a
// wobble-free fixture only 4 offsets, which hid T = 7's split. The threshold pins are
// UNQUANTISED on purpose: a one-cent pin cannot live on a 25.79 c grid.
//
// ═══ ON PLANTS ═══
// Each threshold pin carries its own negative control: the SAME fixtures under a
// PLANTED rule (`PitchNoteSplitter.Rule` with one constant moved one frame or one cent)
// must come out the other way, so the pin is shown able to fail without editing the
// product. The edge rule, the no-split branch and the shape mapping were planted in the
// source itself and reverted (the S2 report lists each).

// MARK: - Fixtures

private enum Take {
    static let rate: Double = 62.5
    static let period: Double = 1 / 62.5
    /// One SwiftF0 output bin, cents (`PitchCorrectionMath.detectorResolutionFloorCents` is half of it).
    static let bin: Double = 25.79
    /// S1's reference pitch for the synthetic controls.
    static let baseHz: Double = 110

    /// 16 (vibrato phase, bin offset) pairs: phase k·2π/16, offset k·25.79/16 c.
    static let sweep: [(phase: Double, offset: Double)] = (0..<16).map { k in
        (Double(k) * 2 * .pi / 16, Double(k) * bin / 16)
    }

    /// A reading snapped to the bin grid offset by `offset` cents (round half to
    /// even, numpy's rule).
    static func quantise(_ cents: Double, offset: Double) -> Double {
        ((cents - offset) / bin).rounded(.toNearestOrEven) * bin + offset
    }

    /// Frames `i · period` apart whose readings are `cents(t)` above `baseHz`,
    /// quantised when `binOffset` is given.
    static func frames(seconds: Double, binOffset: Double?, baseHz: Double = baseHz,
                       startSeconds: Double = 0, confidence: Double = 0.95,
                       cents: (Double) -> Double) -> [ClipPitchFrame] {
        let count = Int((seconds * rate).rounded())
        return (0..<count).map { i in
            let t = Double(i) * period
            let raw = cents(t)
            let c = binOffset.map { quantise(raw, offset: $0) } ?? raw
            return ClipPitchFrame(timeSeconds: startSeconds + t, frequencyHz: baseHz * pow(2, c / 1200),
                                  confidence: confidence, levelDbfs: -18, absence: nil)
        }
    }

    /// Frames from explicit per-frame cents (unquantised), `i · period` apart.
    static func exact(_ cents: [Double], baseHz: Double = baseHz) -> [ClipPitchFrame] {
        cents.enumerated().map { i, c in
            ClipPitchFrame(timeSeconds: Double(i) * period, frequencyHz: baseHz * pow(2, c / 1200),
                           confidence: 0.9 + 0.001 * Double(i % 7), levelDbfs: -18, absence: nil)
        }
    }

    static func wobble(_ depth: Double, _ hz: Double, _ phase: Double) -> (Double) -> Double {
        { t in depth * sin(2 * .pi * hz * t + phase) }
    }

    static func parts(_ frames: [ClipPitchFrame], rule: PitchNoteSplitter.Rule = .product,
                      onsets: [Double] = []) -> [NotePart] {
        PitchNoteSplitter.parts(in: frames, frameRateHz: rate, onsetSeconds: onsets, rule: rule)
    }

    /// "H T H" for messages.
    static func kinds(_ parts: [NotePart]) -> String {
        parts.map { $0.kind == .held ? "H\($0.frameCount)" : "T\($0.frameCount)" }.joined(separator: " ")
    }

    static func centsAboveBase(_ hz: Double) -> Double { PitchCorrectionMath.cents(from: baseHz, to: hz) }
}

/// The structural facts every split must satisfy, whatever the fixture:
///  * the parts TILE each run: outer edges are the run's own, interior boundaries
///    abut bit for bit (the next part's first frame time), frame counts sum to the
///    run's, and `PitchEditSet.canonical` moves nothing;
///  * every number is finite and every centre positive;
///  * the §5.1 COUNT BOUND: a split run has exactly one `.held` part per merged
///    plateau, and adjacent merged plateaus are at least their τ apart.
private func structuralFailures(_ frames: [ClipPitchFrame], rate: Double = Take.rate,
                                rule: PitchNoteSplitter.Rule = .product) -> [String] {
    var failures: [String] = []
    let analyses = PitchNoteSplitter.analyse(frames, frameRateHz: rate, onsetSeconds: [], rule: rule)
    guard let counts = rule.frameCounts(frameRateHz: rate) else { return ["no frame counts"] }
    for a in analyses {
        let parts = a.parts
        guard let first = parts.first, let last = parts.last else {
            failures.append("run \(a.runIndex): no parts"); continue
        }
        if first.startSeconds.bitPattern != a.run.startSeconds.bitPattern
            || last.endSeconds.bitPattern != a.run.endSeconds.bitPattern {
            failures.append("run \(a.runIndex): outer edges \(first.startSeconds)–\(last.endSeconds) vs \(a.run.startSeconds)–\(a.run.endSeconds)")
        }
        for (p, q) in zip(parts, parts.dropFirst()) where p.endSeconds.bitPattern != q.startSeconds.bitPattern {
            failures.append("run \(a.runIndex): parts do not abut (\(p.endSeconds) vs \(q.startSeconds))")
        }
        if parts.map(\.frameCount).reduce(0, +) != a.run.frameCount {
            failures.append("run \(a.runIndex): frame counts sum to \(parts.map(\.frameCount).reduce(0, +)), run has \(a.run.frameCount)")
        }
        for p in parts where !(p.startSeconds.isFinite && p.endSeconds.isFinite && p.centreHz.isFinite
                               && p.centreHz > 0 && p.medianConfidence.isFinite && p.endSeconds > p.startSeconds) {
            failures.append("run \(a.runIndex): non-finite or empty part \(p)")
        }
        let segments = parts.map {
            NoteSegment(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                        detectedHz: $0.centreHz, detectedConfidence: $0.medianConfidence)
        }
        let canon = PitchEditSet(segments: segments).segments
        if canon.count != segments.count
            || zip(canon, segments).contains(where: { $0.startSeconds != $1.startSeconds || $0.endSeconds != $1.endSeconds }) {
            failures.append("run \(a.runIndex): canonical() moved a part")
        }
        if parts.count > 1 {
            let held = parts.filter { $0.kind == .held }.count
            if held != a.plateaus.count {
                failures.append("run \(a.runIndex): COUNT BOUND — \(held) held parts vs \(a.plateaus.count) plateaus")
            }
            func mean(_ r: Range<Int>) -> Double { a.x[r].reduce(0, +) / Double(r.count) }
            for (p, q) in zip(a.plateaus, a.plateaus.dropFirst()) {
                let tau = (p.count >= counts.centreTrack && q.count >= counts.centreTrack)
                    ? rule.mergeLongCents : rule.mergeShortCents
                if abs(mean(p) - mean(q)) < tau {
                    failures.append("run \(a.runIndex): COUNT BOUND — adjacent plateaus \(abs(mean(p) - mean(q))) c apart, under τ \(tau)")
                }
            }
        }
    }
    return failures
}

// MARK: - The constants and their frame counts

struct PitchNoteSplitterConstantTests {

    @Test("frame counts at 62.5 fps are (5, 21, 8, 8), derived from seconds and the 3 Hz wobble floor")
    func frameCountsAtTheDetectorsRate() throws {
        let counts = try #require(PitchNoteSplitter.frameCounts(frameRateHz: 62.5))
        #expect(counts.deglitch == 5)
        #expect(counts.centreTrack == 21)
        #expect(counts.minimumPlateau == 8)
        #expect(counts.scoopLimit == 8)
        #expect(counts.minimumNote == 4)
        // The seconds they come from — the ONE home each.
        #expect(PitchNoteSplitter.deglitchSeconds == 0.080)
        #expect(PitchNoteSplitter.minimumPlateauSeconds == 0.128)
        #expect(PitchNoteSplitter.scoopLimitSeconds == 0.128)
        #expect(PitchNoteSplitter.plateauBandCents == 52)
        #expect(PitchNoteSplitter.mergeLongCents == 50)
        #expect(PitchNoteSplitter.mergeShortCents == 100)
        #expect(PitchWobbleEstimate.scanRangeHz.lowerBound == 3.0,
                "P is one cycle of the slowest modelled wobble; if that floor moved, P moved with it")
        // ⚠️ THE ROUNDING HAZARD, asserted: the products are not exact integers in
        // binary floating point, which is why the count derivation subtracts 1e-9.
        #expect(PitchNoteSplitter.wholeFrames(atLeast: 8 + 1e-12) == 8)
        #expect(PitchNoteSplitter.wholeFrames(atLeast: 8 + 1e-6) == 9, "the guard must not swallow a real fraction")
        #expect(PitchNoteSplitter.oddFrames(atLeast: 20.8333) == 21)
        #expect(PitchNoteSplitter.oddFrames(atLeast: 22) == 23)
    }

    /// The same SECONDS at every backend rate, rounded up — and the bounds that tie
    /// them to `PitchAutoCorrect.minimumNoteSeconds` hold at each.
    @Test("at every rate: the de-glitch keeps a minimum note, T and S exceed one, P spans a 3 Hz cycle")
    func boundsHoldAtEveryRate() throws {
        for rate in [25.0, 50, 62.5, 100, 200, 1000] {
            let c = try #require(PitchNoteSplitter.frameCounts(frameRateHz: rate))
            #expect(c.deglitch % 2 == 1 && c.centreTrack % 2 == 1, "rate \(rate): median widths must be odd")
            #expect((c.deglitch + 1) / 2 <= c.minimumNote,
                    "rate \(rate): a width-\(c.deglitch) median removes features of up to \((c.deglitch - 1) / 2) frames and so could erase a \(c.minimumNote)-frame note")
            #expect(c.minimumPlateau > c.minimumNote && c.scoopLimit > c.minimumNote,
                    "rate \(rate): a .held or .transition part could be shorter than a note")
            #expect(Double(c.centreTrack) / rate >= 1 / PitchWobbleEstimate.scanRangeHz.lowerBound,
                    "rate \(rate): P = \(c.centreTrack) frames is less than one 3 Hz cycle")
            #expect(Double(c.minimumPlateau) / rate >= PitchNoteSplitter.minimumPlateauSeconds - 1e-9)
        }
    }

    @Test("a rate that is not a real positive number gives no counts and no parts, like voicedRuns")
    func degenerateRates() {
        let frames = Take.frames(seconds: 1, binOffset: nil) { _ in 0 }
        for rate in [0.0, -62.5, .nan, .infinity] {
            #expect(PitchNoteSplitter.frameCounts(frameRateHz: rate) == nil, "rate \(rate)")
            #expect(PitchNoteSplitter.parts(in: frames, frameRateHz: rate).isEmpty, "rate \(rate)")
            #expect(PitchAutoCorrect.voicedRuns(in: frames, frameRateHz: rate).isEmpty, "rate \(rate)")
        }
        // CONTROL: the same frames at the real rate are one part.
        #expect(PitchNoteSplitter.parts(in: frames, frameRateHz: 62.5).count == 1)
        #expect(PitchNoteSplitter.parts(in: [], frameRateHz: 62.5).isEmpty)
    }
}

// MARK: - §5.3: the over-split fixtures, each with a twin that MUST split

struct PitchNoteSplitterGuardTests {

    /// §2.1: a steady ±37 c reading (a true ±40 c, under-read) stays ONE note at the
    /// design rate and at both ends of the modelled wobble range — and equals
    /// `voicedRuns` field for field (the §5.2 invariance legs).
    @Test("§2.1 a steady ±37 c wobble at 3.0, 5.5 and 9.0 Hz stays ONE note, equal to voicedRuns, at 16 offsets")
    func steadyWobbleStaysOneNote() {
        for rateHz in [5.5, 3.0, 9.0] {
            for (k, s) in Take.sweep.enumerated() {
                let frames = Take.frames(seconds: 1, binOffset: s.offset, cents: Take.wobble(37, rateHz, s.phase))
                let failures = PrePitchNoteSplitReference.invarianceFailures(frames: frames, frameRateHz: Take.rate)
                #expect(failures.isEmpty, "\(rateHz) Hz, offset \(k): \(failures.prefix(3))")
                #expect(structuralFailures(frames).isEmpty)
            }
        }
    }

    @Test("§2.1 twin: the same wobble on two 0.5 s notes 199 c apart splits into 2 held notes, cut at 0.5 s ± 1 frame")
    func twoWobblingNotesSplit() throws {
        for (k, s) in Take.sweep.enumerated() {
            let frames = Take.frames(seconds: 1, binOffset: s.offset) { t in
                (t < 0.5 ? 0 : 199) + Take.wobble(37, 5.5, s.phase)(t)
            }
            let parts = Take.parts(frames)
            try #require(parts.count == 2, "offset \(k): \(Take.kinds(parts))")
            #expect(parts.allSatisfy { $0.kind == .held }, "offset \(k): \(Take.kinds(parts))")
            #expect(abs(parts[0].endSeconds - 0.5) <= Take.period + 1e-9,
                    "offset \(k): cut at \(parts[0].endSeconds) s")
            // Each note is centred on ITS OWN median, not the run's: EXACTLY the
            // median of its own frames (§1.3 step 6)…
            for part in parts {
                let own = frames.filter { $0.timeSeconds >= part.startSeconds && $0.timeSeconds < part.endSeconds }
                #expect(part.centreHz == PitchCorrectionMath.medianFrequency(own.compactMap(\.frequencyHz)),
                        "offset \(k): a part's centre is not the median of its own frames")
            }
            // …and so within one detector bin of the note it covers. ⚠️ NOT half a
            // bin: each part is a median over 2.7–2.8 wobble cycles, biased by the
            // partial cycle and moving in whole bins. S1's reference `split_run` on
            // this exact fixture measures a worst |median − note| of 14.51 c
            // (offset 7).
            #expect(abs(Take.centsAboveBase(parts[0].centreHz)) < Take.bin, "offset \(k)")
            #expect(abs(Take.centsAboveBase(parts[1].centreHz) - 199) < Take.bin, "offset \(k)")
            // CONTROL — what makes the bound above able to fail: the RUN's median
            // is an element of the larger mode (32 + 31 frames), i.e. on note A,
            // so a second part that carried it would miss note B by over a semitone.
            #expect(abs(Take.centsAboveBase(parts[1].runCentreHz) - 199) > 100,
                    "offset \(k): the fixture must separate note B's median from the run's")
            #expect(structuralFailures(frames).isEmpty, "offset \(k)")
        }
    }

    /// §2.2: a ≤ 120 ms scoop leaves a lead-in of at most S frames, which belongs to
    /// the note, so the run is today's `VoicedRun` exactly.
    @Test("§2.2 a 120 ms, 300 c scoop into a 0.6 s held note stays ONE note, equal to voicedRuns, with and without wobble")
    func shortScoopStaysOneNote() {
        for depth in [0.0, 37] {
            for (k, s) in Take.sweep.enumerated() {
                let frames = Take.frames(seconds: 0.72, binOffset: s.offset) { t in
                    (t < 0.12 ? -300 + 300 * t / 0.12 : 0) + Take.wobble(depth, 5.5, s.phase)(t)
                }
                let failures = PrePitchNoteSplitReference.invarianceFailures(frames: frames, frameRateHz: Take.rate)
                #expect(failures.isEmpty, "±\(depth) c, offset \(k): \(failures.prefix(3))")
            }
        }
    }

    @Test("§2.2 twin: the same shape with a 400 ms slide is a transition and a held note centred within ±15 c of the tail")
    func longSlideIsATransition() throws {
        for (k, s) in Take.sweep.enumerated() {
            let frames = Take.frames(seconds: 1.0, binOffset: s.offset) { t in
                t < 0.4 ? -300 + 300 * t / 0.4 : 0
            }
            let parts = Take.parts(frames)
            try #require(parts.map(\.kind) == [.transition, .held], "offset \(k): \(Take.kinds(parts))")
            #expect(abs(Take.centsAboveBase(parts[1].centreHz)) <= 15,
                    "offset \(k): held centre \(Take.centsAboveBase(parts[1].centreHz)) c from the tail")
            #expect(parts[0].frameCount > (PitchNoteSplitter.frameCounts(frameRateHz: Take.rate)?.scoopLimit ?? 0))
            #expect(structuralFailures(frames).isEmpty, "offset \(k)")
        }
    }

    /// §2.3: the argmax staircase moves a reading by at most a bin, which the band
    /// holds.
    @Test("§2.3 a steady note with a ±8 c staircase flipping every frame stays ONE note, equal to voicedRuns")
    func staircaseArtefactStaysOneNote() {
        for (k, s) in Take.sweep.enumerated() {
            let frames = Take.frames(seconds: 1, binOffset: s.offset) { t in
                Int((t / Take.period).rounded()) % 2 == 0 ? 8 : -8
            }
            let failures = PrePitchNoteSplitReference.invarianceFailures(frames: frames, frameRateHz: Take.rate)
            #expect(failures.isEmpty, "offset \(k): \(failures.prefix(3))")
        }
    }

    @Test("§2.3 twin: a 100 c step between two 0.6 s notes splits into 2 held notes")
    func semitoneStepBetweenLongNotesSplits() throws {
        for (k, s) in Take.sweep.enumerated() {
            let frames = Take.frames(seconds: 1.2, binOffset: s.offset) { t in t < 0.6 ? 0 : 100 }
            let parts = Take.parts(frames)
            #expect(parts.map(\.kind) == [.held, .held], "offset \(k): \(Take.kinds(parts))")
            #expect(structuralFailures(frames).isEmpty, "offset \(k)")
        }
    }

    /// §2.5, as amended by §14 item 4: an 800 c/s slide stays one note WHEN IT IS
    /// WOBBLE-FREE. (With ±37 c wobble, slides below ~1279 c/s split in every cell,
    /// §13.3 — recorded, not pinned as a guarantee.)
    @Test("§2.5 a wobble-free 800 c/s slide over 1 s stays ONE note, equal to voicedRuns, at 16 offsets")
    func slowSlideStaysOneNote() {
        for (k, s) in Take.sweep.enumerated() {
            let frames = Take.frames(seconds: 1, binOffset: s.offset) { t in -400 + 800 * t }
            let failures = PrePitchNoteSplitReference.invarianceFailures(frames: frames, frameRateHz: Take.rate)
            #expect(failures.isEmpty, "offset \(k): \(failures.prefix(3))")
        }
    }

    @Test("§2.5 twin: the same slide ending in a 0.2 s hold is a transition and a held note")
    func slideIntoAHoldSplits() throws {
        for (k, s) in Take.sweep.enumerated() {
            let frames = Take.frames(seconds: 1.2, binOffset: s.offset) { t in t < 1 ? -400 + 800 * t : 400 }
            let parts = Take.parts(frames)
            #expect(parts.map(\.kind) == [.transition, .held], "offset \(k): \(Take.kinds(parts))")
            #expect(structuralFailures(frames).isEmpty, "offset \(k)")
        }
    }

    /// §1.4's de-glitch: a 2-frame octave error is removed before anything is read.
    @Test("glitch: a 2-frame octave glitch mid-note stays ONE note, equal to voicedRuns")
    func shortOctaveGlitchStaysOneNote() {
        for (k, s) in Take.sweep.enumerated() {
            let frames = Take.frames(seconds: 1, binOffset: s.offset) { t in
                (t >= 0.5 && t < 0.5 + 2 * Take.period - 1e-9 ? 1200 : 0) + Take.wobble(37, 5.5, s.phase)(t)
            }
            #expect(frames.filter { Take.centsAboveBase($0.frequencyHz ?? 0) > 1000 }.count == 2,
                    "the fixture must carry exactly a 2-frame glitch")
            let failures = PrePitchNoteSplitReference.invarianceFailures(frames: frames, frameRateHz: Take.rate)
            #expect(failures.isEmpty, "offset \(k): \(failures.prefix(3))")
        }
    }

    /// RECORDED BEHAVIOUR, NOT AN ENDORSEMENT (§8 F-oct): an octave excursion long
    /// enough to survive the de-glitch and the centre track becomes its own note.
    @Test("glitch twin: a 12-frame octave excursion splits (F-oct, recorded behaviour)")
    func longOctaveExcursionSplits() throws {
        for (k, s) in Take.sweep.enumerated() {
            let frames = Take.frames(seconds: 1, binOffset: s.offset) { t in
                (t >= 0.5 && t < 0.5 + 12 * Take.period - 1e-9 ? 1200 : 0) + Take.wobble(37, 5.5, s.phase)(t)
            }
            let parts = Take.parts(frames)
            #expect(parts.count >= 2, "offset \(k): \(Take.kinds(parts))")
            #expect(parts.contains { $0.kind == .held && Take.centsAboveBase($0.centreHz) > 1100 },
                    "offset \(k): no part sits on the octave: \(Take.kinds(parts))")
            #expect(structuralFailures(frames).isEmpty, "offset \(k)")
        }
    }

    /// §1.4's closing check, re-derived in Swift as the design asks: the two RED-like
    /// slides each give a lead-in transition and ONE held note on the tail.
    @Test("§1.4 RED-like slides (741 c over 0.44 s then 0.17 s; 500 c over 0.4 s then 0.2 s) give a transition and a held tail")
    func redLikeSlidesGiveATransitionAndAHeldTail() throws {
        for (width, slide, tail) in [(741.0, 0.44, 0.17), (500.0, 0.40, 0.20)] {
            for (k, s) in Take.sweep.enumerated() {
                let frames = Take.frames(seconds: slide + tail, binOffset: s.offset) { t in
                    t < slide ? -width + width * t / slide : 0
                }
                let parts = Take.parts(frames)
                try #require(parts.map(\.kind) == [.transition, .held], "\(width) c, offset \(k): \(Take.kinds(parts))")
                // The emitted median is the median of the tail's own raw readings:
                // it lands on the tail's quantised value, within half a bin of the
                // sung pitch.
                #expect(abs(Take.centsAboveBase(parts[1].centreHz) - Take.quantise(0, offset: s.offset)) <= 1e-6,
                        "\(width) c, offset \(k): held median \(Take.centsAboveBase(parts[1].centreHz)) c")
                #expect(structuralFailures(frames).isEmpty)
            }
        }
    }
}

// MARK: - Threshold pins: one frame or one cent either side, each with a planted rule

struct PitchNoteSplitterThresholdPinTests {

    static func planted(_ edit: (inout PitchNoteSplitter.Rule) -> Void) -> PitchNoteSplitter.Rule {
        var rule = PitchNoteSplitter.Rule.product
        edit(&rule)
        return rule
    }

    /// A 40-frame note at 0 c, then a tail of `k` frames at +200 c ending the run.
    static func tail(_ k: Int) -> [ClipPitchFrame] {
        Take.exact(Array(repeating: 0, count: 40) + Array(repeating: 200, count: k))
    }

    @Test("T: a held tail of T frames splits off; a tail of T−1 frames does not")
    func minimumPlateauPin() throws {
        let t = try #require(PitchNoteSplitter.frameCounts(frameRateHz: Take.rate)).minimumPlateau
        #expect(Take.parts(Self.tail(t)).map(\.kind) == [.held, .held], "\(Take.kinds(Take.parts(Self.tail(t))))")
        #expect(PrePitchNoteSplitReference.invarianceFailures(frames: Self.tail(t - 1), frameRateHz: Take.rate).isEmpty,
                "a \(t - 1)-frame tail must be absorbed into the note")
        // PLANTED: T one frame lower splits the T−1 tail; one frame higher keeps the T tail.
        let lower = Self.planted { $0.minimumPlateauSeconds = Double(t - 1) / Take.rate }
        let higher = Self.planted { $0.minimumPlateauSeconds = Double(t + 1) / Take.rate }
        #expect(Take.parts(Self.tail(t - 1), rule: lower).count == 2, "the T−1 pin cannot see T move down")
        #expect(Take.parts(Self.tail(t), rule: higher).count == 1, "the T pin cannot see T move up")
    }

    /// A lead-in of `k` frames of a steep rise (100 c per frame, ending at −100 c),
    /// then a 40-frame note at 0 c.
    static func leadIn(_ k: Int) -> [ClipPitchFrame] {
        Take.exact((0..<k).map { -100 * Double(k - $0) } + Array(repeating: 0, count: 40))
    }

    @Test("S: a lead-in of S frames belongs to the note; S+1 frames is its own transition")
    func scoopLimitPin() throws {
        let s = try #require(PitchNoteSplitter.frameCounts(frameRateHz: Take.rate)).scoopLimit
        #expect(PrePitchNoteSplitReference.invarianceFailures(frames: Self.leadIn(s), frameRateHz: Take.rate).isEmpty,
                "an \(s)-frame lead-in is a scoop and must stay with its note")
        #expect(Take.parts(Self.leadIn(s + 1)).map(\.kind) == [.transition, .held])
        let lower = Self.planted { $0.scoopLimitSeconds = Double(s - 1) / Take.rate }
        let higher = Self.planted { $0.scoopLimitSeconds = Double(s + 1) / Take.rate }
        #expect(Take.parts(Self.leadIn(s), rule: lower).count == 2, "the S pin cannot see S move down")
        #expect(Take.parts(Self.leadIn(s + 1), rule: higher).count == 1, "the S+1 pin cannot see S move up")
    }

    /// Two 30-frame notes a `step` cents apart (both ≥ P, so τ_long applies and a
    /// 53 c step is not merged back).
    static func step(_ step: Double) -> [ClipPitchFrame] {
        Take.exact(Array(repeating: 0, count: 30) + Array(repeating: step, count: 30))
    }

    @Test("B: a 51 c step stays inside the band (ONE note); a 53 c step breaks it (two held notes)")
    func plateauBandPin() {
        let band = PitchNoteSplitter.plateauBandCents
        #expect(PrePitchNoteSplitReference.invarianceFailures(frames: Self.step(band - 1), frameRateHz: Take.rate).isEmpty)
        #expect(Take.parts(Self.step(band + 1)).map(\.kind) == [.held, .held])
        let lower = Self.planted { $0.plateauBandCents = band - 2 }
        let higher = Self.planted { $0.plateauBandCents = band + 2 }
        #expect(Take.parts(Self.step(band - 1), rule: lower).count == 2, "the B−1 pin cannot see B move down")
        #expect(Take.parts(Self.step(band + 1), rule: higher).count == 1, "the B+1 pin cannot see B move up")
    }

    /// Two plateaus whose MERGE centres (the mean of `x`) are `delta` cents apart
    /// while their CENTRE TRACKS are more than B apart, so step 3 separates them and
    /// step 4 alone decides.
    ///
    /// Note A is 45 frames of the period-8 pattern [0,0,0,0,0,h,h,h] then five 0s
    /// (h = 40 c): its 3-frame blocks survive the de-glitch (so `x` = the readings)
    /// but are a minority in every 21-frame window (so `y` reads 0 or h, inside the
    /// band), and its mean of `x` is 15·40/45 = 13.33 c. Note B is `bLength` frames
    /// at `13.33 + delta`, more than B above A's `y`.
    static func merge(delta: Double, bLength: Int) -> (frames: [ClipPitchFrame], meanA: Double) {
        let h = 40.0
        var a: [Double] = []
        for i in 0..<40 { a.append(i % 8 >= 5 ? h : 0) }
        a += Array(repeating: 0, count: 5)
        let meanA = a.reduce(0, +) / Double(a.count)
        return (Take.exact(a + Array(repeating: meanA + delta, count: bLength)), meanA)
    }

    /// The fixture is what it claims BEFORE its outcome is read: two raw plateaus,
    /// exactly A and B, whose merge centres differ by `delta` ± 0.01 c.
    static func assertMergeFixture(_ frames: [ClipPitchFrame], delta: Double, bLength: Int) throws {
        let a = try #require(PitchNoteSplitter.analyse(frames, frameRateHz: Take.rate, onsetSeconds: [],
                                                       rule: .product).first)
        try #require(a.rawPlateaus == [0 ..< 45, 45 ..< 45 + bLength], "raw plateaus \(a.rawPlateaus)")
        func mean(_ r: Range<Int>) -> Double { a.x[r].reduce(0, +) / Double(r.count) }
        #expect(abs((mean(45 ..< 45 + bLength) - mean(0 ..< 45)) - delta) < 0.01)
    }

    @Test("τ_long: two long plateaus 49 c apart merge (ONE note); 51 c apart stay two held notes")
    func mergeLongPin() throws {
        let tau = PitchNoteSplitter.mergeLongCents
        let near = Self.merge(delta: tau - 1, bLength: 42), far = Self.merge(delta: tau + 1, bLength: 42)
        try Self.assertMergeFixture(near.frames, delta: tau - 1, bLength: 42)
        try Self.assertMergeFixture(far.frames, delta: tau + 1, bLength: 42)
        #expect(PrePitchNoteSplitReference.invarianceFailures(frames: near.frames, frameRateHz: Take.rate).isEmpty)
        #expect(Take.parts(far.frames).map(\.kind) == [.held, .held])
        let lower = Self.planted { $0.mergeLongCents = tau - 2 }
        let higher = Self.planted { $0.mergeLongCents = tau + 2 }
        #expect(Take.parts(near.frames, rule: lower).count == 2, "the τ_long−1 pin cannot see τ_long move down")
        #expect(Take.parts(far.frames, rule: higher).count == 1, "the τ_long+1 pin cannot see τ_long move up")
        // And τ_long, not τ_short, decided: under τ_short both would merge.
        #expect(Take.parts(far.frames, rule: Self.planted { $0.mergeLongCents = $0.mergeShortCents }).count == 1)
    }

    @Test("τ_short: a long and a short plateau 99 c apart merge (ONE note); 101 c apart stay two held notes")
    func mergeShortPin() throws {
        let tau = PitchNoteSplitter.mergeShortCents
        let near = Self.merge(delta: tau - 1, bLength: 16), far = Self.merge(delta: tau + 1, bLength: 16)
        try Self.assertMergeFixture(near.frames, delta: tau - 1, bLength: 16)
        try Self.assertMergeFixture(far.frames, delta: tau + 1, bLength: 16)
        #expect(16 < (PitchNoteSplitter.frameCounts(frameRateHz: Take.rate)?.centreTrack ?? 0),
                "B must be shorter than P for τ_short to apply")
        #expect(PrePitchNoteSplitReference.invarianceFailures(frames: near.frames, frameRateHz: Take.rate).isEmpty)
        #expect(Take.parts(far.frames).map(\.kind) == [.held, .held])
        let lower = Self.planted { $0.mergeShortCents = tau - 2 }
        let higher = Self.planted { $0.mergeShortCents = tau + 2 }
        #expect(Take.parts(near.frames, rule: lower).count == 2, "the τ_short−1 pin cannot see τ_short move down")
        #expect(Take.parts(far.frames, rule: higher).count == 1, "the τ_short+1 pin cannot see τ_short move up")
    }
}

// MARK: - The edge rule (§12 item 6)

struct PitchNoteSplitterEdgeRuleTests {

    /// ⭐ THE SYMMETRIC SHRINK, PINNED (design §12 item 6). A monotone edge is a
    /// fixed point of a SYMMETRIC running median, so a 9-frame fall that ends the
    /// run keeps all 9 frames out of the note and becomes a transition (9 > S). An
    /// edge-CLAMPED window would pull the first frames of the fall into the note's
    /// band (measured by planting it: the tail-off shrinks to 7 frames ≤ S and the
    /// run comes out as ONE note) — S1 found that choice changes 10 of the user's 42
    /// runs. The mirror image pins the run's start.
    @Test("the median windows shrink SYMMETRICALLY at run edges: a 9-frame fall ending a run is a transition")
    func symmetricShrinkAtRunEdges() throws {
        let fall = (0..<9).map { -60 * Double($0 + 1) }
        let end = Take.exact(Array(repeating: 0, count: 40) + fall)
        let a = try #require(PitchNoteSplitter.analyse(end, frameRateHz: Take.rate, onsetSeconds: [],
                                                       rule: .product).first)
        #expect(Array(a.y.suffix(9)) == Array(a.cents.suffix(9)), "y must leave a monotone edge untouched")
        #expect(a.parts.map(\.kind) == [.held, .transition] && a.parts.map(\.frameCount) == [40, 9],
                "\(Take.kinds(a.parts))")

        let start = Take.exact(fall.reversed() + Array(repeating: 0, count: 40))
        let b = try #require(PitchNoteSplitter.analyse(start, frameRateHz: Take.rate, onsetSeconds: [],
                                                       rule: .product).first)
        #expect(Array(b.y.prefix(9)) == Array(b.cents.prefix(9)))
        #expect(b.parts.map(\.kind) == [.transition, .held] && b.parts.map(\.frameCount) == [9, 40],
                "\(Take.kinds(b.parts))")
    }
}

// MARK: - Onsets (§1.5): they move a cut f0 found; they never make one

struct PitchNoteSplitterOnsetTests {

    /// Note A (30 frames), a 6-frame rise of 60 c per frame (a SHORT link, ≤ S),
    /// note B (30 frames) 420 c above A. f0 alone cuts the link at frame 33, the
    /// first frame whose `x` crosses the mid of the two plateau centres.
    static let link: [ClipPitchFrame] = Take.exact(
        Array(repeating: 0, count: 30) + (1...6).map { 60 * Double($0) } + Array(repeating: 420, count: 30))

    static func cut(_ onsets: [Double]) -> Double? {
        let parts = Take.parts(link, onsets: onsets)
        return parts.count == 2 ? parts[1].startSeconds : nil
    }

    static func t(_ frame: Int) -> Double { Self.link[frame].timeSeconds }

    @Test("a short link is cut where x crosses the mid of the two notes when there is no onset")
    func f0PlacesTheCut() throws {
        let parts = Take.parts(Self.link)
        #expect(parts.map(\.kind) == [.held, .held])
        #expect(parts.first?.frameCount == 33, "\(Take.kinds(parts))")
        #expect(Self.cut([]) == Self.t(33))
    }

    @Test("an onset inside a short link, or within one frame of its ends, moves the cut to the nearest frame start")
    func onsetMovesTheCut() {
        #expect(Self.cut([Self.t(31)]) == Self.t(31))
        #expect(Self.cut([Self.t(31) + 0.004]) == Self.t(31), "the nearest frame start to the onset")
        #expect(Self.cut([Self.t(34) - 0.003]) == Self.t(34))
        // Within one frame OUTSIDE the link: the cut goes to the link's nearest edge.
        #expect(Self.cut([Self.t(30) - 0.01]) == Self.t(30))
        #expect(Self.cut([Self.t(36) + 0.01]) == Self.t(36))
        // Two candidates: the one nearest the f0 cut wins.
        #expect(Self.cut([Self.t(30), Self.t(34)]) == Self.t(34))
    }

    @Test("an onset outside the link's window, or not a number, leaves the f0 cut alone")
    func farOrInvalidOnsetsAreIgnored() {
        #expect(Self.cut([0.1, 0.9, Self.t(30) - 0.02, Self.t(36) + 0.02]) == Self.t(33))
        #expect(Self.cut([.nan, .infinity, -.infinity]) == Self.t(33))
    }

    @Test("an onset alone never cuts: a steady note stays ONE part whatever the onsets")
    func onsetAloneNeverCuts() {
        let frames = Take.frames(seconds: 1, binOffset: 0) { t in Take.wobble(37, 5.5, 0.3)(t) }
        let onsets = stride(from: 0.0, to: 1.0, by: 0.05).map { $0 }
        let parts = Take.parts(frames, onsets: onsets)
        let runs = PitchAutoCorrect.voicedRuns(in: frames, frameRateHz: Take.rate)
        #expect(parts.count == 1 && runs.count == 1)
        #expect(parts.first?.centreHz == runs.first?.centreHz && parts.first?.endSeconds == runs.first?.endSeconds)
    }

    @Test("a long link is a transition, and an onset inside it changes nothing")
    func longLinkIgnoresOnsets() {
        let frames = Take.exact(Array(repeating: 0, count: 30) + (1...12).map { 60 * Double($0) }
                                + Array(repeating: 780, count: 30))
        let plain = Take.parts(frames)
        #expect(plain.map(\.kind) == [.held, .transition, .held], "\(Take.kinds(plain))")
        #expect(Take.parts(frames, onsets: [frames[35].timeSeconds]) == plain)
    }
}

// MARK: - The slide shapes (§3.2) and the preserve-vibrato presets (§3.4)

struct PitchSlideShapeTests {

    /// A3 + 20 c held 30 frames, a 12-frame slide of 60 c per frame (a transition),
    /// E4 + 20 c held 30 frames: `H T H`.
    static let slide: [ClipPitchFrame] = Take.exact(
        Array(repeating: 20, count: 30) + (1...12).map { 20 + 58 * Double($0) } + Array(repeating: 720, count: 30),
        baseHz: 220)

    static let hardTune = PitchCorrectionPreset.hardTune.options()

    /// The segment a part should get when aimed at the nearest allowed note to
    /// `aimHz` — restated here from the design's words, not called from the product.
    static func expectedOffset(part: NotePart, aimHz: Double, options: PitchAutoCorrectOptions) -> Double {
        let detected = PitchCorrectionMath.midi(fromHz: part.centreHz)
        let target = options.scale.nearestAllowedMidi(to: PitchCorrectionMath.midi(fromHz: aimHz))
        return options.strength * (target - detected) * 100
    }

    static func isIdentity(_ s: NoteSegment) -> Bool {
        s.pitchOffsetCents == 0 && s.driftScale == 1 && s.vibratoScale == 1
    }

    static func set(_ shape: PitchSlideShape, _ options: PitchAutoCorrectOptions = hardTune,
                    frames: [ClipPitchFrame] = slide) -> PitchEditSet {
        PitchAutoCorrect.editSet(contour: frames, frameRateHz: Take.rate, options: options, slideShape: shape)
    }

    @Test("the fixture is H T H, and every shape writes one segment per part with the part's OWN detectedHz")
    func everyShapeWritesTheSameNoteTable() throws {
        let parts = Take.parts(Self.slide)
        try #require(parts.map(\.kind) == [.held, .transition, .held], "\(Take.kinds(parts))")
        let table = PitchNoteTable.detected(from: PrePitchNoteSplitReference.result(Self.slide, frameRateHz: Take.rate))
        for options in [Self.hardTune, PitchCorrectionPreset.natural.options(),
                        PitchCorrectionPreset.gentle.options(), PitchCorrectionPreset.tight.options()] {
            for shape in PitchSlideShape.allCases {
                let set = Self.set(shape, options)
                try #require(set.segments.count == 3)
                for (segment, (part, row)) in zip(set.segments, zip(parts, table.segments)) {
                    #expect(segment.startSeconds == part.startSeconds && segment.endSeconds == part.endSeconds)
                    #expect(segment.detectedHz == part.centreHz && segment.detectedConfidence == part.medianConfidence)
                    #expect(segment.startSeconds == row.startSeconds && segment.detectedHz == row.detectedHz,
                            "the editor's seed and the corrector disagree about a note (\(shape.rawValue))")
                }
            }
        }
    }

    @Test("(c) run pin: every part — held and transition — locks to the WHOLE run's note, flattened")
    func runPinLocksEveryPartToTheRunsNote() throws {
        let parts = Take.parts(Self.slide)
        let set = Self.set(.runPin)
        try #require(set.segments.count == 3)
        let runNote = Self.hardTune.scale.nearestAllowedMidi(to: PitchCorrectionMath.midi(fromHz: parts[0].runCentreHz))
        for (segment, part) in zip(set.segments, parts) {
            #expect(segment.pitchOffsetCents == Self.expectedOffset(part: part, aimHz: part.runCentreHz, options: Self.hardTune))
            #expect(segment.driftScale == 0 && segment.vibratoScale == 0)
            let target = PitchCorrectionMath.midi(fromHz: segment.detectedHz) + segment.pitchOffsetCents / 100
            #expect(abs(target - runNote) < 1e-9, "a part of the run did not land on the run's note")
        }
        // CONTROL: the held parts are NOT on the run's note under any other shape.
        #expect(Self.set(.slideKeptNoteLocked).segments[0].pitchOffsetCents != set.segments[0].pitchOffsetCents)
    }

    @Test("(d) straight to the note: a link aims at the held note it leads INTO, flattened")
    func straightToNoteAimsAtTheDestination() throws {
        let parts = Take.parts(Self.slide)
        let set = Self.set(.straightToNote)
        try #require(set.segments.count == 3)
        #expect(set.segments[1].pitchOffsetCents
                == Self.expectedOffset(part: parts[1], aimHz: parts[2].centreHz, options: Self.hardTune))
        #expect(set.segments[1].driftScale == 0 && set.segments[1].vibratoScale == 0)
        let slideTarget = PitchCorrectionMath.midi(fromHz: set.segments[1].detectedHz) + set.segments[1].pitchOffsetCents / 100
        let heldTarget = PitchCorrectionMath.midi(fromHz: set.segments[2].detectedHz) + set.segments[2].pitchOffsetCents / 100
        #expect(abs(slideTarget - heldTarget) < 1e-9, "the slide and the note it leads into must share one pitch")
        for i in [0, 2] {
            #expect(set.segments[i].pitchOffsetCents
                    == Self.expectedOffset(part: parts[i], aimHz: parts[i].centreHz, options: Self.hardTune))
        }
    }

    /// §12 item 2 for the other two transition positions: a lead-in aims at the
    /// first held note (the one it leads into), a tail-off at the last (the one it
    /// leaves).
    @Test("(d) straight to the note: a lead-in aims at the note after it; a tail-off at the note before it")
    func straightToNoteForLeadInsAndTailOffs() throws {
        let frames = Take.exact((1...12).map { -720 + 58 * Double($0) } + Array(repeating: 0, count: 30)
                                + (1...12).map { -60 * Double($0) }, baseHz: 220 * pow(2, 20.0 / 1200))
        let parts = Take.parts(frames)
        try #require(parts.map(\.kind) == [.transition, .held, .transition], "\(Take.kinds(parts))")
        let set = Self.set(.straightToNote, frames: frames)
        for i in [0, 2] {
            #expect(set.segments[i].pitchOffsetCents
                    == Self.expectedOffset(part: parts[i], aimHz: parts[1].centreHz, options: Self.hardTune),
                    "transition \(i) did not aim at the held note of its run")
        }
        #expect(PitchAutoCorrect.destination(ofTransition: 0, in: parts) == parts[1])
        #expect(PitchAutoCorrect.destination(ofTransition: 2, in: parts) == parts[1])
    }

    @Test("(a-T) slide kept, note locked: a transition is an IDENTITY segment; the held notes lock to their own")
    func slideKeptIsIdentity() throws {
        let parts = Take.parts(Self.slide)
        let set = Self.set(.slideKeptNoteLocked)
        try #require(set.segments.count == 3)
        #expect(Self.isIdentity(set.segments[1]))
        for i in [0, 2] {
            #expect(set.segments[i].pitchOffsetCents
                    == Self.expectedOffset(part: parts[i], aimHz: parts[i].centreHz, options: Self.hardTune))
            #expect(set.segments[i].driftScale == 0 && set.segments[i].vibratoScale == 0)
        }
        #expect(set.needsDetectedContour, "the held notes are Hard-Tuned")
    }

    @Test("(a-N) in-between note: a transition locks to the nearest note of its OWN median, flattened")
    func inBetweenNoteLocksTheSlideToItsOwnNote() throws {
        let parts = Take.parts(Self.slide)
        let set = Self.set(.inBetweenNote)
        try #require(set.segments.count == 3)
        #expect(set.segments[1].pitchOffsetCents
                == Self.expectedOffset(part: parts[1], aimHz: parts[1].centreHz, options: Self.hardTune))
        #expect(set.segments[1].driftScale == 0 && set.segments[1].vibratoScale == 0)
        #expect(!Self.isIdentity(set.segments[1]))
    }

    /// ⭐ The four shapes differ ONLY on the transition — and (c) on the held notes
    /// too — so every pair is distinguishable on this fixture: no two shapes write
    /// the same table here, which is what lets the user's pick mean anything.
    @Test("the four shapes write four DIFFERENT tables on a run with a transition, and the SAME table on one without")
    func shapesDifferOnlyWhereThereIsSomethingToShape() {
        let tables = PitchSlideShape.allCases.map { Self.set($0) }
        for i in tables.indices {
            for j in tables.indices where j > i {
                #expect(PrePitchNoteSplitReference.firstDifference(tables[i], tables[j]) != nil,
                        "\(PitchSlideShape.allCases[i]) and \(PitchSlideShape.allCases[j]) wrote the same table")
            }
        }
        let steady = Take.frames(seconds: 1, binOffset: 3) { t in Take.wobble(37, 5.5, 1)(t) }
        let steadyTables = PitchSlideShape.allCases.map { Self.set($0, frames: steady) }
        for t in steadyTables.dropFirst() {
            #expect(PrePitchNoteSplitReference.firstDifference(t, steadyTables[0]) == nil)
        }
    }

    /// §3.4: Gentle, Natural and Tight move each HELD note by its own constant and
    /// leave a transition as sung — in every shape.
    @Test("preserve-vibrato presets: a transition is identity and each held note gets its own constant, in every shape")
    func preserveVibratoPresetsIgnoreTheShape() throws {
        let parts = Take.parts(Self.slide)
        for preset in PitchCorrectionPreset.ladder {
            let options = preset.options()
            #expect(options.preserveVibrato)
            let sets = PitchSlideShape.allCases.map { Self.set($0, options) }
            for set in sets {
                try #require(set.segments.count == 3)
                #expect(Self.isIdentity(set.segments[1]), "\(preset.rawValue): the slide was moved")
                for i in [0, 2] {
                    #expect(set.segments[i].pitchOffsetCents
                            == Self.expectedOffset(part: parts[i], aimHz: parts[i].centreHz, options: options))
                    #expect(set.segments[i].driftScale == 1 && set.segments[i].vibratoScale == 1)
                }
                #expect(PrePitchNoteSplitReference.firstDifference(set, sets[0]) == nil,
                        "\(preset.rawValue): the shape changed a preserve-vibrato table")
                #expect(!set.needsDetectedContour, "\(preset.rawValue) now needs the contour")
            }
        }
    }

    @Test("editSet's default shape IS the policy constant, and strength 0 is still the empty set")
    func defaultShapeIsThePolicyConstant() {
        let plain = PitchAutoCorrect.editSet(contour: Self.slide, frameRateHz: Take.rate, options: Self.hardTune)
        #expect(PrePitchNoteSplitReference.firstDifference(plain, Self.set(PitchAutoCorrect.slideShape)) == nil)
        for shape in PitchSlideShape.allCases {
            #expect(Self.set(shape, PitchAutoCorrectOptions(strength: 0, preserveVibrato: false)) == .empty)
        }
    }
}

// MARK: - The two builders read parts (§4.5), and the legs can fail

struct PitchNoteSplitterBuilderTests {

    /// Two 0.5 s notes 199 c apart with no gap — a note change inside ONE run.
    static let legato: [ClipPitchFrame] = Take.frames(seconds: 1, binOffset: nil) { t in t < 0.5 ? 0 : 199 }

    @Test("PitchNoteTable.detected and editSet both write one segment per PART, and voicedRuns still sees one run")
    func bothBuildersReadParts() throws {
        let runs = PitchAutoCorrect.voicedRuns(in: Self.legato, frameRateHz: Take.rate)
        let parts = Take.parts(Self.legato)
        #expect(runs.count == 1)
        try #require(parts.count == 2)
        let table = PitchNoteTable.detected(from: PrePitchNoteSplitReference.result(Self.legato, frameRateHz: Take.rate))
        #expect(table.segments.map(\.startSeconds) == parts.map(\.startSeconds))
        #expect(table.segments.map(\.detectedHz) == parts.map(\.centreHz))
        #expect(table.isIdentity && !table.isEmpty)
        let set = PitchAutoCorrect.editSet(contour: Self.legato, frameRateHz: Take.rate,
                                           options: PitchCorrectionPreset.natural.options())
        #expect(set.segments.map(\.startSeconds) == table.segments.map(\.startSeconds))
    }

    /// ⭐ THE §5.2 LEGS CAN FAIL. A fixture that really changes note inside a run
    /// must fail all three (unit, edit set, note table); if it did not, every
    /// "invariant" verdict above would be a helper that cannot see a split.
    @Test("POSITIVE CONTROL: the §5.2 invariance legs report a real note change on all three legs")
    func invarianceLegsSeeARealSplit() {
        let failures = PrePitchNoteSplitReference.invarianceFailures(frames: Self.legato, frameRateHz: Take.rate)
        #expect(failures.contains { $0.hasPrefix("UNIT") }, "\(failures.prefix(2))")
        #expect(failures.contains { $0.hasPrefix("EDIT SET") })
        #expect(failures.contains { $0.hasPrefix("NOTE TABLE") })
    }

    /// ⭐ THE NO-SPLIT BRANCH RETURNS THE RUN ITSELF (§2.4), not a recomputation:
    /// on an asymmetric run (a scoop), the median and the mean differ by cents,
    /// and the part carries the median bit for bit.
    @Test("an unsplit run's part carries the VoicedRun's own median, bit for bit — not a recomputed centre")
    func unsplitPartIsTheRunItself() throws {
        let frames = Take.frames(seconds: 1.0, binOffset: nil) { t in t < 0.1 ? -200 + 2000 * t : 0 }
        let run = try #require(PitchAutoCorrect.voicedRuns(in: frames, frameRateHz: Take.rate).first)
        let part = try #require(Take.parts(frames).first)
        #expect(Take.parts(frames).count == 1)
        #expect(part.centreHz.bitPattern == run.centreHz.bitPattern)
        let hz = frames.compactMap(\.frequencyHz)
        let mean = hz.reduce(0, +) / Double(hz.count)
        #expect(abs(PitchCorrectionMath.cents(from: mean, to: run.centreHz)) > 1,
                "the fixture must separate a median from a mean")
    }
}

// MARK: - Guards: non-finite input never reaches a number

struct PitchNoteSplitterGuardRailTests {

    @Test("a run holding a non-finite frame time is emitted whole, and nothing non-finite comes out")
    func nonFiniteFrameTimeIsEmittedWhole() {
        var frames = PitchNoteSplitterBuilderTests.legato
        let hz = frames[40].frequencyHz
        frames[40] = ClipPitchFrame(timeSeconds: .nan, frequencyHz: hz, confidence: 0.9, levelDbfs: -18, absence: nil)
        let runs = PitchAutoCorrect.voicedRuns(in: frames, frameRateHz: Take.rate)
        let parts = PitchNoteSplitter.parts(in: frames, frameRateHz: Take.rate)
        #expect(parts.count >= runs.count)
        for part in parts {
            #expect(part.startSeconds.isFinite && part.endSeconds.isFinite && part.centreHz.isFinite)
        }
        for set in PitchSlideShape.allCases.map({
            PitchAutoCorrect.editSet(contour: frames, frameRateHz: Take.rate,
                                     options: PitchCorrectionPreset.hardTune.options(), slideShape: $0)
        }) {
            #expect(set.segments.allSatisfy { $0.pitchOffsetCents.isFinite && $0.startSeconds.isFinite })
        }
    }

    @Test("wild but real readings (an octave leap, 30 Hz to 3 kHz) stay finite and tile their runs")
    func extremeReadingsStayFinite() {
        let frames = Take.exact((0..<80).map { i in i < 20 ? -2000 : (i < 40 ? 3000 : (i < 60 ? 0 : 1200)) })
        #expect(structuralFailures(frames).isEmpty)
        let parts = Take.parts(frames)
        #expect(parts.allSatisfy { $0.centreHz.isFinite && $0.centreHz > 0 })
    }
}
