import AVFAudio
import CryptoKit
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// Natural tuning §2 (m23-nt, lane NT-E2): **THE PHYSICS OF "CONSONANTS AND
/// BREATHS PLAY THE SINGER'S OWN SOUND".** Design
/// `docs/design/2026-09-25-natural-tuning.md` §2g as amended by R1, R4 and R5.
///
/// This file holds R4's M-2b (the smear INSIDE a note, measured before the mix
/// was written) and the gates that need a spectrum or a real take. The byte
/// gates of the mix itself live in `NaturalTuningConsonantRenderTests`.
///
/// Deliberately NOT `@MainActor` (the cap): pure renders of synthetic
/// fixtures. The real-take legs are an `extension` of NT-G's take-harness §2
/// suite, env-gated, with `@MainActor` on each test, never on a suite.

/// R4's instrument: how much consonant energy a moved note carries at its
/// INNER edges, where the consonant mix never reaches (w == 1 inside a note).
/// PREREG: `scratchpad/w6/NTE2/M2b-PREREG.txt` (written before any render).
enum ConsonantSmear {
    /// The inner-edge window, and the mid-note control window, seconds.
    static let edgeSeconds = 0.060
    /// A note shorter than this has no mid window disjoint from its edges.
    static let minimumNoteSeconds = 0.200
    /// PREREG: the smear at which the move's added edge energy counts as
    /// AUDIBLE (a doubling of the 4-20 kHz energy it adds over mid-note), and
    /// G-C12's floor. One number, so the measurement and the gate agree.
    static let audibleSmearDb = 3.0
    static let highBand: ClosedRange<Double> = 4000...20000
    static let flatnessBand: ClosedRange<Double> = 4000...16000

    /// 4-20 kHz energy of `x[window]`, dB.
    static func hfDb(_ x: [Float], _ window: Range<Int>, sampleRate: Double) -> Double {
        let lo = max(0, window.lowerBound), hi = min(x.count, window.upperBound)
        guard hi - lo >= 64 else { return -180 }
        return ConsonantSpectrumMeter.bandEnergyDb(Array(x[lo..<hi]), sampleRate: sampleRate,
                                                   band: highBand) ?? -180
    }

    /// Spectral flatness of `x[window]` over 4-16 kHz: 1 for white noise, near
    /// 0 for a harmonic comb. Reported, never decided on.
    static func flatness(_ x: [Float], _ window: Range<Int>, sampleRate: Double) -> Double {
        let lo = max(0, window.lowerBound), hi = min(x.count, window.upperBound)
        guard hi - lo >= 64,
              let (bins, binHz) = ConsonantSpectrumMeter.powerSpectrum(Array(x[lo..<hi]),
                                                                       sampleRate: sampleRate)
        else { return .nan }
        let a = Int((flatnessBand.lowerBound / binHz).rounded())
        let b = min(bins.count - 1, Int((flatnessBand.upperBound / binHz).rounded()))
        guard b > a else { return .nan }
        var logSum = 0.0, sum = 0.0
        for i in a...b {
            logSum += log(bins[i] + 1e-30)
            sum += bins[i]
        }
        let n = Double(b - a + 1)
        guard sum > 0 else { return .nan }
        return exp(logSum / n) / (sum / n)
    }

    /// One inner edge of a note that faces a consonant region.
    struct Edge: Sendable {
        let noteIndex: Int
        let onset: Bool
        let window: Range<Int>
        let mid: Range<Int>
    }

    struct Reading: Sendable {
        let edge: Edge
        /// HF(moved, edge) − HF(unmoved, edge).
        let excessEdge: Double
        /// HF(moved, mid) − HF(unmoved, mid): what the move does to the vowel.
        let excessMid: Double
        /// `excessEdge − excessMid`: the consonant energy the move adds.
        var smear: Double { excessEdge - excessMid }
        /// |HF(unmoved, edge) − HF(source, edge)|: the stretcher's colouring.
        let control: Double
        /// Flatness(moved) − flatness(unmoved), edge minus mid.
        let flatnessSmear: Double
    }

    /// Every inner edge of a curve note ≥ `minimumNoteSeconds` that faces a
    /// region of `set` (read with the flag ON, so a legacy set's edges are
    /// the ones the mix WOULD protect).
    static func edges(of set: PitchEditSet, frames: Int, sampleRate: Double) -> [Edge] {
        var flagged = set
        flagged.keepsConsonantsUntuned = true
        let regions = flagged.consonantRegions()
        let edgeFrames = Int((edgeSeconds * sampleRate).rounded())
        func frame(_ second: Double) -> Int {
            min(frames, StretchCurvePlan.outputFrame(forSourceSecond: second, ratio: 1,
                                                     sampleRate: sampleRate))
        }
        var out: [Edge] = []
        for (index, note) in set.segments.enumerated() where note.entersPitchCurve {
            guard note.endSeconds - note.startSeconds >= minimumNoteSeconds else { continue }
            let start = frame(note.startSeconds), end = frame(note.endSeconds)
            let centre = (start + end) / 2
            let mid = (centre - edgeFrames / 2)..<(centre - edgeFrames / 2 + edgeFrames)
            if regions.contains(where: { $0.precedesNote && $0.endSeconds == note.startSeconds }) {
                out.append(Edge(noteIndex: index, onset: true, window: start..<(start + edgeFrames),
                                mid: mid))
            }
            if regions.contains(where: { $0.followsNote && $0.startSeconds == note.endSeconds }) {
                out.append(Edge(noteIndex: index, onset: false, window: (end - edgeFrames)..<end,
                                mid: mid))
            }
        }
        return out
    }

    static func read(_ edge: Edge, source: [Float], unmoved: [Float], moved: [Float],
                     sampleRate: Double) -> Reading {
        let vE = hfDb(moved, edge.window, sampleRate: sampleRate)
        let uE = hfDb(unmoved, edge.window, sampleRate: sampleRate)
        let sE = hfDb(source, edge.window, sampleRate: sampleRate)
        let vM = hfDb(moved, edge.mid, sampleRate: sampleRate)
        let uM = hfDb(unmoved, edge.mid, sampleRate: sampleRate)
        let fE = flatness(moved, edge.window, sampleRate: sampleRate)
            - flatness(unmoved, edge.window, sampleRate: sampleRate)
        let fM = flatness(moved, edge.mid, sampleRate: sampleRate)
            - flatness(unmoved, edge.mid, sampleRate: sampleRate)
        return Reading(edge: edge, excessEdge: vE - uE, excessMid: vM - uM,
                       control: abs(uE - sE), flatnessSmear: fE - fM)
    }

    /// U: the curve loop at a constant 0 st, the product's latency
    /// compensation, no formant curve. The product path cannot give this: an
    /// identity set never reaches the stretcher.
    static func unmoved(_ input: [Float], sampleRate: Double) throws -> [Float] {
        try OfflineStretcher.stretchTransposeCurve(
            input: [input], sampleRate: sampleRate, ratio: 1,
            semitonesAtOutputFrame: { _ in 0 }, formantPreserve: false,
            compensation: OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate))[0]
    }

    /// V: the product render body (`StretchRenderCache.renderAudio`, whole
    /// entry) at ratio 1, 0 st, formant flag off.
    static func product(_ input: [Float], set: PitchEditSet, sampleRate: Double) throws -> [Float] {
        var whole = [input]
        let out = try StretchRenderCache.renderAudio(
            whole: &whole, window: nil, sampleRate: sampleRate,
            params: StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: false,
                                              pitchEdits: set),
            curveContour: nil, isCancelled: { false })
        return out.output.planar[0]
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))]
    }

    static func f(_ x: Double) -> String { String(format: "%.2f", x) }
}

/// The 'Star'-shaped fixture with a TRAILING consonant, so the note has two
/// inner edges that face a region: s 120 ms + t 20 ms + /a/ 400 ms (110 Hz)
/// + s 120 ms + 100 ms of silence. The /a/ is the only note.
enum StarsFixture {
    static let sampleRate = 48_000.0

    struct Fixture: Sendable {
        let audio: [Float]
        let note: ClosedRange<Double>
    }

    static func make() -> Fixture {
        let star = SourceFilterVoice.starSyllable(f0Hz: 110, sampleRate: sampleRate)
        let trailing = SourceFilterVoice.fricativeBurst(durationSeconds: 0.120, sampleRate: sampleRate,
                                                        seed: 0x5EC0D)
        let silence = [Float](repeating: 0, count: Int(0.100 * sampleRate))
        return Fixture(audio: star.audio + trailing + silence, note: star.voicedRange)
    }

    static func note(_ fixture: Fixture, cents: Double) -> NoteSegment {
        NoteSegment(startSeconds: fixture.note.lowerBound, endSeconds: fixture.note.upperBound,
                    detectedHz: 110, detectedConfidence: 0.95, pitchOffsetCents: cents)
    }

    /// A LEGACY set (formant nil, consonants off, slope 0) or the product's
    /// NEW set (`seeded`: formant 1, consonants on, slope 3000).
    static func set(_ fixture: Fixture, cents: Double, retuneMs: Double, seeded: Bool) -> PitchEditSet {
        let segment = note(fixture, cents: cents)
        guard seeded else { return PitchEditSet(segments: [segment], retuneMs: retuneMs) }
        return PitchEditSet.seeded(analysisVersion: PitchEditSet.currentAnalysisVersion,
                                   segments: [segment], retuneMs: retuneMs, partKinds: [:],
                                   seedPolicy: .editor)
    }
}

/// ⚠️ **G-C12 ON THIS FIXTURE FAILS ITS PRE-REGISTERED BOUND, AND IS NOT
/// ASSERTED HERE.** The PREREG put G-C12 (smear ≤ max(3 dB, 2 × control)) on
/// this fixture and the audible-excess DECISION on the user's take. Measured
/// 2026-09-26: the take reads no audible excess (the product seed's median
/// −1.1 dB, max 2.5 dB over 42 edges), while this fixture reads 3.4-43 dB
/// in 7 of 8 cells. ⭐ **WHY, MEASURED 2026-09-27**
/// (`NaturalTuningConsonantSmearMechanismTests`, one condition at a time):
/// the moved render carries the neighbouring consonant into the note's
/// edges (derived from the renders with and without the consonants: 32-42
/// dB under the 's', in every cell and both set kinds), and this fixture's
/// vowel has almost no 4-20 kHz energy of its own (72 dB under the 's' at
/// its edges; the resonator cascade rolls off), so that energy dominates a
/// RELATIVE metric. A sibilant-shaped floor under the vowel at 30 dB of
/// contrast brings all 8 cells within the bound; at 40 dB, 5 of 8 still
/// exceed. The take's edges reach at most 33 dB (against its regions'
/// nearest 120 ms). The fade and the mix play no part: the edge windows are
/// byte-identical flag on and off. The absolute levels are logged next to
/// each reading. The decision stands on the take (no edge offset; G-C2 stays
/// byte-identical), and G-C12 is asserted there (`m2bRealTake`). Changing the
/// fixture's bound after seeing it would be exactly what a PREREG forbids.
@Suite("Natural tuning §2 — consonant physics (NT-E2): M-2b smear inside the note")
struct NaturalTuningConsonantSmearTests {
    static func log(_ message: String) { print("nt-e2-m2b| \(message)") }

    /// R4's M-2b on the fixture: the instrument's POSITIVE CONTROL. PREREG:
    /// at retune 30 ms, legacy set, the /a/ moved +300 c must read an onset
    /// edge excess (moved over unmoved) ≥ +1.0 dB, or the instrument is blind
    /// here. Every reading (both retunes, both set kinds, both edges) is
    /// logged for the report.
    @Test("M-2b (fixture): the /a/ moved +300 c reads inner-edge excess over the unmoved render; every smear reading logged")
    func m2bFixture() throws {
        let fixture = StarsFixture.make()
        let sr = StarsFixture.sampleRate
        let unmoved = try ConsonantSmear.unmoved(fixture.audio, sampleRate: sr)
        // The leading 's' alone, 20-100 ms: the absolute reference level.
        let sIndex = Int(0.020 * sr)..<Int(0.100 * sr)
        var plantExcess: Double?
        for retune in [30.0, 200.0] {
            for seeded in [false, true] {
                let set = StarsFixture.set(fixture, cents: 300, retuneMs: retune, seeded: seeded)
                let moved = try ConsonantSmear.product(fixture.audio, set: set, sampleRate: sr)
                let edges = ConsonantSmear.edges(of: set, frames: moved.count, sampleRate: sr)
                #expect(edges.count == 2, "the /a/ faces the head and the tail: \(edges.count) edges")
                for edge in edges {
                    let r = ConsonantSmear.read(edge, source: fixture.audio, unmoved: unmoved,
                                                moved: moved, sampleRate: sr)
                    let bound = max(ConsonantSmear.audibleSmearDb, 2 * r.control)
                    Self.log("retune \(Int(retune)) ms \(seeded ? "seeded" : "legacy") \(edge.onset ? "onset " : "offset") edge: excessEdge \(ConsonantSmear.f(r.excessEdge)) dB, excessMid \(ConsonantSmear.f(r.excessMid)) dB, SMEAR \(ConsonantSmear.f(r.smear)) dB, control \(ConsonantSmear.f(r.control)) dB, flatness smear \(String(format: "%.3f", r.flatnessSmear)); ABSOLUTE 4-20 kHz: moved edge \(ConsonantSmear.f(ConsonantSmear.hfDb(moved, edge.window, sampleRate: sr))) dB, unmoved edge \(ConsonantSmear.f(ConsonantSmear.hfDb(unmoved, edge.window, sampleRate: sr))) dB, the 's' itself \(ConsonantSmear.f(ConsonantSmear.hfDb(fixture.audio, sIndex, sampleRate: sr))) dB; G-C12 PREREG bound \(ConsonantSmear.f(bound)) dB: \(r.smear <= bound ? "within" : "EXCEEDED (recorded, not asserted: see the suite's doc)")")
                    if retune == 30, !seeded, edge.onset { plantExcess = r.excessEdge }
                }
            }
        }
        let excess = try #require(plantExcess)
        #expect(excess >= 1.0,
                "PREREG plant: the /a/ moved +300 c at retune 30 ms reads only \(excess) dB of onset-edge excess over the unmoved render; the instrument is blind on this fixture")
    }
}

extension NaturalTuningTakeHarnessSection2Tests {
    /// R4's M-2b on the user's take, env-gated. PREREG (written by this test
    /// to the dogfood folder before any render, and in the lane's scratchpad
    /// before this code existed): AUDIBLE EXCESS iff the median smear over
    /// every qualifying inner edge that faces a region is > 3 dB.
    @Test("M-2b (real take): consonant smear inside moved notes, median over every region-facing inner edge (R4)",
          .enabled(if: enabled))
    @MainActor
    func m2bRealTake() throws {
        let source = URL(fileURLWithPath: Self.sourcePath)
        let input = try TestSignals.readFile(source)
        try #require(input.count == 1, "expected a mono take; got \(input.count) channels")
        let dry = input[0]
        let sr = try AVAudioFile(forReading: source).processingFormat.sampleRate
        try """
            m23-nt NT-E2 — PREREG, §2 R4 M-2b, written by the test before any render.
            Table: PitchNoteTable.detected (the editor seed, retune 30 ms, sounds included),
            every note (not sound) +300 c. U = curve loop at constant 0 st; V = renderAudio.
            SMEAR = [HF(V,edge)-HF(U,edge)] - [HF(V,mid)-HF(U,mid)], HF = 4-20 kHz energy dB,
            60 ms windows, notes >= 0.2 s, edges facing a consonant region.
            AUDIBLE EXCESS iff median SMEAR > \(ConsonantSmear.audibleSmearDb) dB.
            Full text: the NT-E2 lane scratchpad, M2b-PREREG.txt.
            """.write(to: Self.ensureOutDir().appendingPathComponent("M2b-PREREG.txt"),
                      atomically: true, encoding: .utf8)
        let detection = try PitchContourCache.detectWholeFile(source, .product)
        let table = PitchNoteTable.detected(from: detection)
        var segments = table.segments
        for i in segments.indices where segments[i].origin != .unpitched {
            segments[i].pitchOffsetCents = 300
        }
        let product = table.withSegments(segments)
        var legacy = product
        legacy.formantCorrection = nil
        let unmoved = try ConsonantSmear.unmoved(dry, sampleRate: sr)
        for (label, set) in [("product seed", product), ("formant nil", legacy)] {
            let moved = try ConsonantSmear.product(dry, set: set, sampleRate: sr)
            let edges = ConsonantSmear.edges(of: set, frames: moved.count, sampleRate: sr)
            let readings = edges.map {
                ConsonantSmear.read($0, source: dry, unmoved: unmoved, moved: moved, sampleRate: sr)
            }
            try #require(!readings.isEmpty, "no qualifying edge on the take")
            for r in readings {
                Self.log("M-2b \(label) note \(r.edge.noteIndex) \(r.edge.onset ? "onset " : "offset"): excessEdge \(ConsonantSmear.f(r.excessEdge)) excessMid \(ConsonantSmear.f(r.excessMid)) SMEAR \(ConsonantSmear.f(r.smear)) control \(ConsonantSmear.f(r.control)) flat \(String(format: "%.3f", r.flatnessSmear))")
            }
            let smears = readings.map(\.smear)
            let median = ConsonantSmear.percentile(smears, 0.5)
            let onsets = readings.filter { $0.edge.onset }.map(\.smear)
            let offsets = readings.filter { !$0.edge.onset }.map(\.smear)
            Self.log("M-2b \(label) SUMMARY: \(readings.count) edges (\(onsets.count) onset, \(offsets.count) offset), SMEAR median \(ConsonantSmear.f(median)) dB, p90 \(ConsonantSmear.f(ConsonantSmear.percentile(smears, 0.9))) dB, onset median \(ConsonantSmear.f(ConsonantSmear.percentile(onsets, 0.5))), offset median \(ConsonantSmear.f(ConsonantSmear.percentile(offsets, 0.5))), control median \(ConsonantSmear.f(ConsonantSmear.percentile(readings.map(\.control), 0.5))) dB, flatness smear median \(String(format: "%.3f", ConsonantSmear.percentile(readings.map(\.flatnessSmear), 0.5)))")
            Self.log("M-2b \(label) VERDICT (PREREG: audible iff median > \(ConsonantSmear.audibleSmearDb) dB): \(median > ConsonantSmear.audibleSmearDb ? "AUDIBLE EXCESS: an edge offset is needed (a DAWCore change)" : "no audible excess: no edge offset; G-C2 stays byte-identical")")
            if label == "product seed" {
                // G-C12, the ongoing gate on the take: the PREREG's decision.
                #expect(median <= ConsonantSmear.audibleSmearDb,
                        "G-C12: the median smear inside moved notes is \(median) dB (audible)")
            }
        }
    }
}

/// §2g G-C3 as amended by R5: **THE 'S' DOES NOT MOVE.** The 'Stars' fixture
/// (the 'Star' syllable plus a trailing 's'), the /a/ moved +300 c at the
/// Gentle retune (200 ms, whose r/2 = 100 ms leak covers most of the leading
/// 's', R5), legacy formant.
@Suite("Natural tuning §2 — consonant physics (NT-E2): G-C3, the 's' does not move")
struct NaturalTuningConsonantPhysicsTests {
    static func log(_ message: String) { print("nt-e2-gc3| \(message)") }
    static let sampleRate = StarsFixture.sampleRate

    struct Reading {
        let centroidCents: Double
        let bandDb: [Double]
        let lsd: Double
        let residualDb: Double
    }

    static func read(_ source: [Float], _ y: [Float], _ range: Range<Int>) -> Reading {
        let s = Array(source[range]), r = Array(y[range])
        let bands = ConsonantSpectrumMeter.bands.map { band in
            (ConsonantSpectrumMeter.bandEnergyDb(r, sampleRate: sampleRate, band: band) ?? -180)
                - (ConsonantSpectrumMeter.bandEnergyDb(s, sampleRate: sampleRate, band: band) ?? -180)
        }
        return Reading(
            centroidCents: ConsonantSpectrumMeter.centroidShiftCents(reference: s, shifted: r,
                                                                     sampleRate: sampleRate) ?? .nan,
            bandDb: bands,
            lsd: ConsonantSpectrumMeter.logSpectralDistance(reference: s, shifted: r,
                                                            sampleRate: sampleRate) ?? .nan,
            residualDb: NaturalTuningBaselineTests.residualDb(r, s))
    }

    static func describe(_ r: Reading) -> String {
        "centroid \(String(format: "%+.2f", r.centroidCents)) c, bands \(r.bandDb.map { String(format: "%+.2f", $0) }) dB, LSD \(String(format: "%.3f", r.lsd)), residual \(String(format: "%.1f", r.residualDb)) dB"
    }

    @Test("G-C3 (R5): with the flag on, both 's' regions beyond their fades are the source (centroid and 4 bands unmoved, waveform residual −∞); flag OFF on the same edit they are not (RED on today's code); a clip transpose shows the instrument sees a shift; the /a/ still moves")
    func theSDoesNotMove() throws {
        let fixture = StarsFixture.make()
        let source = fixture.audio
        let on = StarsFixture.set(fixture, cents: 300, retuneMs: 200, seeded: false)
        var flagged = on
        flagged.keepsConsonantsUntuned = true
        let rendered = try ConsonantSmear.product(source, set: flagged, sampleRate: Self.sampleRate)
        let flagOff = try ConsonantSmear.product(source, set: on, sampleRate: Self.sampleRate)
        let w = (0..<rendered.count).map { flagged.tunedWeight(atSourceSecond: Double($0) / Self.sampleRate) }
        // The leading 's' (before the moved note: its ramp's leak) and the
        // trailing 's' (after it: the phase wake), each beyond its fade.
        let lead = 0..<(w.firstIndex { $0 > 0 } ?? 0)
        let trailStart = (Int(fixture.note.upperBound * Self.sampleRate) ..< rendered.count).first { w[$0] == 0 } ?? rendered.count
        let trail = trailStart..<(trailStart + Int(0.110 * Self.sampleRate))
        for (label, range, after) in [("leading 's'", lead, false), ("trailing 's'", trail, true)] {
            let onReading = Self.read(source, rendered, range)
            let offReading = Self.read(source, flagOff, range)
            Self.log("\(label) \(range) (\(after ? "a moved note precedes" : "before the moved note")): flag ON \(Self.describe(onReading)); flag OFF \(Self.describe(offReading)) (R5 red threshold from M-1: +3.7 dB)")
            #expect(range.count > Int(0.080 * Self.sampleRate), "premise: \(label) is over 80 ms")
            #expect(onReading.residualDb == -.infinity, "G-C3 \(label): the flag-on 's' is not the source")
            #expect(onReading.centroidCents == 0 && onReading.bandDb.allSatisfy { $0 == 0 } && onReading.lsd == 0,
                    "G-C3 \(label): the flag-on 's' moved")
            #expect(offReading.residualDb > -10 && offReading.lsd > 1,
                    "RED on today's code (\(label)): flag off, the 's' should be resynthesised")
        }
        // The instrument sees a real shift: a whole-clip +300 c.
        let clip = PitchEditSet(segments: [NoteSegment(startSeconds: 0, endSeconds: Double(source.count) / Self.sampleRate,
                                                       detectedHz: 110, detectedConfidence: 1, pitchOffsetCents: 300)],
                                retuneMs: 200)
        let clipRendered = try ConsonantSmear.product(source, set: clip, sampleRate: Self.sampleRate)
        let clipShift = Self.read(source, clipRendered, lead).centroidCents
        // The /a/ itself still moves (the meter saturates at 200 c).
        let noteRange = Int(fixture.note.lowerBound * Self.sampleRate)..<Int(fixture.note.upperBound * Self.sampleRate)
        let aShift = try #require(SpectralShiftMeter.shiftCents(
            reference: Array(source[noteRange]), shifted: Array(rendered[noteRange]), sampleRate: Self.sampleRate))
        Self.log("instrument control: a whole-clip +300 c reads \(String(format: "%.1f", clipShift)) c on the 's'; the /a/ reads \(String(format: "%.1f", aShift)) c")
        #expect(abs(clipShift) > 20, "the instrument cannot see a shift in this 's'")
        #expect(aShift > 150, "the /a/ did not move: the render is broken, not protected")
    }
}

extension NaturalTuningTakeHarnessSection2Tests {
    /// §2g G-C11 on the user's take, with R5's residual leg: the unpitched
    /// SOUNDS the editor seed finds between notes (U-A), every note moved
    /// ±300 c (alternating), the product's new set (consonants on) vs the
    /// same set with the flag off.
    @Test("G-C11 (real take): every sound's frames beyond the fades are the source with the flag on (residual −∞, LSD 0); flag off, the sounds near a moved note are not (R5 residual split by 'a moved note precedes')",
          .enabled(if: enabled))
    @MainActor
    func gC11RealTake() throws {
        let source = URL(fileURLWithPath: Self.sourcePath)
        let dry = try TestSignals.readFile(source)[0]
        let sr = try AVAudioFile(forReading: source).processingFormat.sampleRate
        let table = PitchNoteTable.detected(from: try PitchContourCache.detectWholeFile(source, .product))
        var segments = table.segments
        var sign = 1.0
        for i in segments.indices where segments[i].origin != .unpitched {
            segments[i].pitchOffsetCents = 300 * sign
            sign = -sign
        }
        let on = table.withSegments(segments)
        var off = on
        off.keepsConsonantsUntuned = false
        let wetOn = try ConsonantSmear.product(dry, set: on, sampleRate: sr)
        let wetOff = try ConsonantSmear.product(dry, set: off, sampleRate: sr)
        let firstMoved = on.segments.first { $0.origin != .unpitched }?.startSeconds ?? 0
        let sounds = on.segments.filter { $0.origin == .unpitched }
        var exact = 0, measured = 0, offAbove = 0
        var residualsAfter: [Double] = [], residualsBefore: [Double] = []
        for sound in sounds {
            let frames = (Int((sound.startSeconds * sr).rounded())..<Int((sound.endSeconds * sr).rounded()))
                .filter { on.tunedWeight(atSourceSecond: Double($0) / sr) == 0 }
            guard frames.count >= 1024, let lo = frames.first, let hi = frames.last else { continue }
            let range = lo..<(hi + 1)
            measured += 1
            let onMismatch = range.filter { wetOn[$0].bitPattern != dry[$0].bitPattern }.count
            if onMismatch == 0 { exact += 1 }
            let s = Array(dry[range]), y = Array(wetOff[range])
            let lsd = ConsonantSpectrumMeter.logSpectralDistance(reference: s, shifted: y, sampleRate: sr) ?? 0
            let residual = NaturalTuningBaselineTests.residualDb(y, s)
            if lsd > 1 { offAbove += 1 }
            if sound.startSeconds > firstMoved { residualsAfter.append(residual) } else { residualsBefore.append(residual) }
        }
        let median = { (x: [Double]) in ConsonantSmear.percentile(x, 0.5) }
        Self.log("G-C11: \(sounds.count) sounds, \(measured) with >= 1024 dry frames; flag ON exact (residual -inf) on \(exact) of \(measured); flag OFF LSD > 1 dB on \(offAbove); flag-off residual median \(ConsonantSmear.f(median(residualsAfter))) dB after a moved note (\(residualsAfter.count)), \(ConsonantSmear.f(median(residualsBefore))) dB before (\(residualsBefore.count)); R5 red threshold +3.7 dB")
        #expect(measured > 0 && exact == measured, "G-C11: \(measured - exact) sounds are not the source with the flag on")
        #expect(offAbove > 0, "RED on today's code: flag off, no sound was resynthesised")
    }

    /// The mix's cost on the user's 33 s take, whole file and a window.
    @Test("COST (real take): the consonant mix's added render time, whole file and a 2 s window (median of 3)",
          .enabled(if: enabled))
    @MainActor
    func consonantMixCost() throws {
        let source = URL(fileURLWithPath: Self.sourcePath)
        let dry = try TestSignals.readFile(source)[0]
        let sr = try AVAudioFile(forReading: source).processingFormat.sampleRate
        let table = PitchNoteTable.detected(from: try PitchContourCache.detectWholeFile(source, .product))
        var segments = table.segments
        for i in segments.indices where segments[i].origin != .unpitched { segments[i].pitchOffsetCents = 300 }
        let on = table.withSegments(segments)
        var off = on
        off.keepsConsonantsUntuned = false
        func ms(_ body: () throws -> Void) rethrows -> Double {
            let t = ContinuousClock.now
            try body()
            let d = ContinuousClock.now - t
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        let regions = on.consonantRegions()
        let wetOff = try ConsonantSmear.product(dry, set: off, sampleRate: sr)
        var mixOnly: [Double] = [], wholeOn: [Double] = [], wholeOff: [Double] = []
        var winOn: [Double] = [], winOff: [Double] = []
        let spanSource = StretchRenderCache.SpanSource(url: source, channels: 1, sampleRate: sr, frames: dry.count,
                                                       read: { range, _ in [Array(dry[range])] })
        let window = Int(10 * sr)..<Int(12 * sr)
        for _ in 0..<3 {
            var copy = [wetOff]
            let mix = try ms { try StretchCurvePlan.applyConsonantMix(regions, wet: &copy, dry: [dry], sampleRate: sr, ratio: 1) }
            mixOnly.append(mix)
            let whole1 = try ms { _ = try ConsonantSmear.product(dry, set: on, sampleRate: sr) }
            wholeOn.append(whole1)
            let whole0 = try ms { _ = try ConsonantSmear.product(dry, set: off, sampleRate: sr) }
            wholeOff.append(whole0)
            for (set, into) in [(on, 0), (off, 1)] {
                let t = try ms {
                    _ = try StretchRenderCache.renderOutputFrames(
                        window, of: spanSource,
                        params: StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: false, pitchEdits: set),
                        renderCacheDirectory: FileManager.default.temporaryDirectory, detector: .product,
                        isCancelled: { false })
                }
                if into == 0 { winOn.append(t) } else { winOff.append(t) }
            }
        }
        let m = { (x: [Double]) in ConsonantSmear.percentile(x, 0.5) }
        Self.log("COST: \(regions.count) regions over \(String(format: "%.1f", Double(dry.count) / sr)) s; the mix pass alone \(ConsonantSmear.f(m(mixOnly))) ms; whole-file render flag on \(ConsonantSmear.f(m(wholeOn))) ms vs off \(ConsonantSmear.f(m(wholeOff))) ms; 2 s window flag on \(ConsonantSmear.f(m(winOn))) ms vs off \(ConsonantSmear.f(m(winOff))) ms")
        #expect(!regions.isEmpty)
    }
}

// MARK: - G-C12, the mechanism (W7-NTE2, 2026-09-27): env-gated, LOG-ONLY

/// ⭐ **WHAT MAKES THE FIXTURE'S G-C12 SMEAR, ONE CONDITION AT A TIME.** The
/// PREREG bound (3 dB) is exceeded in 7 of the fixture's 8 cells (SMEAR 3.4
/// to 43.8 dB) while the user's take reads a median of −1.1 dB. This
/// re-renders the 'Stars' fixture with ONE condition changed per variant
/// (the consonants, the 't', the vowel's edges, a high-band floor under the
/// vowel, the move's size, the band, the mix) and logs every cell, so the
/// mechanism table in the lane report is a measurement anyone can re-run:
///
///     NTE2_GC12_MECHANISM=1 ./scripts/test.sh --filter NaturalTuningConsonantSmearMechanismTests
///
/// ⛔ **LOG-ONLY BY RULING (orchestrator, 2026-09-27).** No SMEAR bound is
/// asserted and none is re-fitted: the PREREG stands as written
/// (`NaturalTuningConsonantSmearTests`). The only checks are the premises
/// that make a reading mean anything.
enum SmearMechanism {
    static let enabled = ProcessInfo.processInfo.environment["NTE2_GC12_MECHANISM"] != nil
    static let sampleRate = StarsFixture.sampleRate

    static func frame(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

    /// Band energy of `x[window]`, dB: `ConsonantSmear.hfDb` with the band
    /// as a parameter (the default band IS that function's).
    static func hf(_ x: [Float], _ window: Range<Int>,
                   band: ClosedRange<Double> = ConsonantSmear.highBand) -> Double {
        let lo = max(0, window.lowerBound), hi = min(x.count, window.upperBound)
        guard hi - lo >= 64 else { return -180 }
        return ConsonantSpectrumMeter.bandEnergyDb(Array(x[lo..<hi]), sampleRate: sampleRate,
                                                   band: band) ?? -180
    }

    /// `x` with every frame outside `keep` set to zero.
    static func only(_ x: [Float], _ keep: Range<Int>) -> [Float] {
        x.indices.map { keep.contains($0) ? x[$0] : 0 }
    }

    /// `x` with `range` set to zero.
    static func zeroed(_ x: [Float], _ range: Range<Int>) -> [Float] {
        var y = x
        for i in range where y.indices.contains(i) { y[i] = 0 }
        return y
    }

    /// Raised-cosine gain `i` of an `n`-frame ramp, 0 → 1.
    static func ramp(_ i: Int, _ n: Int) -> Float {
        Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(n)))
    }

    /// `x` with an extra raised-cosine fade of `seconds` at each end of `range`.
    static func softened(_ x: [Float], _ range: Range<Int>, seconds: Double) -> [Float] {
        var y = x
        let n = frame(seconds)
        for i in 0..<n {
            y[range.lowerBound + i] *= ramp(i, n)
            y[range.upperBound - 1 - i] *= ramp(i, n)
        }
        return y
    }

    /// The fricative's own shaping (`SourceFilterVoice.fricativeBurst`: white
    /// noise, `r[n] − 0.97·r[n−1]`), seeded, no fades.
    static func hiss(count: Int, seed: UInt64) -> [Float] {
        var generator = SplitMix64(seed: seed)
        var previous: Float = 0
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let r = generator.nextUnit() * 2 - 1
            out[i] = r - 0.97 * previous
            previous = r
        }
        return out
    }

    /// `x` plus sibilant-shaped noise over `range` only (3 ms raised-cosine
    /// ends, so it adds no edge of its own), scaled so its 4-20 kHz energy
    /// sits `contrastDb` under `referenceDb`: a high-band floor under the
    /// vowel, the one thing the resonator cascade's vowel lacks.
    static func withFloor(_ x: [Float], _ range: Range<Int>, referenceDb: Double,
                          contrastDb: Double) -> [Float] {
        var noise = hiss(count: range.count, seed: 0xF1_00F)
        let unit = hf(noise, 0..<min(noise.count, frame(0.060)))
        let gain = Float(pow(10, (referenceDb - contrastDb - unit) / 20))
        let n = frame(0.003)
        for i in 0..<n {
            noise[i] *= ramp(i, n)
            noise[noise.count - 1 - i] *= ramp(i, n)
        }
        var y = x
        for (k, i) in range.enumerated() { y[i] += gain * noise[k] }
        return y
    }

    static func f(_ x: Double) -> String { String(format: "%.2f", x) }
    static func s(_ x: Double) -> String { String(format: "%+.2f", x) }
}

@Suite("Natural tuning §2 — consonant physics (NT-E2): what makes G-C12's fixture smear, one condition at a time (env-gated, log-only)")
struct NaturalTuningConsonantSmearMechanismTests {
    typealias M = SmearMechanism
    static func log(_ message: String) { print("nt-e2-gc12| \(message)") }

    /// One reading, with the four absolute levels it is made of.
    struct Cell {
        let retuneMs: Double
        let seeded: Bool
        let onset: Bool
        let excessEdge: Double
        let excessMid: Double
        var smear: Double { excessEdge - excessMid }
        let movedEdge: Double, unmovedEdge: Double, movedMid: Double, unmovedMid: Double
    }

    /// Every cell (2 retunes × 2 set kinds × 2 edges) of `audio` with its
    /// note moved `cents`: M-2b's own reading (`ConsonantSmear.edges`, the
    /// same windows, U = the curve loop at 0 st, V = `renderAudio`), with the
    /// band as a parameter and the flag optionally forced.
    static func cells(_ audio: [Float], note: ClosedRange<Double>, cents: Double = 300,
                      consonants: Bool? = nil,
                      band: ClosedRange<Double> = ConsonantSmear.highBand) throws -> [Cell] {
        let fixture = StarsFixture.Fixture(audio: audio, note: note)
        let unmoved = try ConsonantSmear.unmoved(audio, sampleRate: M.sampleRate)
        var out: [Cell] = []
        for retune in [30.0, 200.0] {
            for seeded in [false, true] {
                var set = StarsFixture.set(fixture, cents: cents, retuneMs: retune, seeded: seeded)
                if let consonants { set.keepsConsonantsUntuned = consonants }
                let moved = try ConsonantSmear.product(audio, set: set, sampleRate: M.sampleRate)
                let edges = ConsonantSmear.edges(of: set, frames: moved.count, sampleRate: M.sampleRate)
                try #require(edges.count == 2, "premise: the /a/ faces the head and the tail")
                for edge in edges {
                    let vE = M.hf(moved, edge.window, band: band), uE = M.hf(unmoved, edge.window, band: band)
                    let vM = M.hf(moved, edge.mid, band: band), uM = M.hf(unmoved, edge.mid, band: band)
                    out.append(Cell(retuneMs: retune, seeded: seeded, onset: edge.onset,
                                    excessEdge: vE - uE, excessMid: vM - uM,
                                    movedEdge: vE, unmovedEdge: uE, movedMid: vM, unmovedMid: uM))
                }
            }
        }
        return out
    }

    static func report(_ label: String, _ cells: [Cell]) {
        for c in cells {
            log("\(label) | retune \(Int(c.retuneMs)) | \(c.seeded ? "seeded" : "legacy") | \(c.onset ? "onset " : "offset") | excessEdge \(M.s(c.excessEdge)) | excessMid \(M.s(c.excessMid)) | SMEAR \(M.s(c.smear)) | V edge \(M.f(c.movedEdge)) U edge \(M.f(c.unmovedEdge)) V mid \(M.f(c.movedMid)) U mid \(M.f(c.unmovedMid))")
        }
        let smears = cells.map(\.smear)
        let over = smears.filter { $0 > ConsonantSmear.audibleSmearDb }.count
        log("\(label) | SUMMARY: SMEAR \(M.s(smears.min() ?? .nan)) … \(M.s(smears.max() ?? .nan)) dB, over the PREREG's 3 dB in \(over) of \(cells.count)")
    }

    @Test("G-C12 mechanism (fixture): every cell with one condition changed at a time (consonants, the 't', vowel edges, a high-band floor, move size, band, the mix); logged, never asserted",
          .enabled(if: SmearMechanism.enabled))
    func fixtureMechanism() throws {
        let fixture = StarsFixture.make()
        let audio = fixture.audio
        let vowel = M.frame(fixture.note.lowerBound)..<M.frame(fixture.note.upperBound)
        let t = M.frame(0.120)..<vowel.lowerBound
        let sReference = M.hf(audio, M.frame(0.020)..<M.frame(0.100))
        func vowelMid(_ x: [Float]) -> Double {
            let centre = (vowel.lowerBound + vowel.upperBound) / 2, half = M.frame(0.030)
            return M.hf(x, (centre - half)..<(centre + half))
        }
        try #require(vowel.count == M.frame(0.400) && t.count == M.frame(0.020),
                     "premise: the fixture is s 120 ms + t 20 ms + /a/ 400 ms: \(vowel) \(t)")
        let trailing = vowel.upperBound..<(vowel.upperBound + M.frame(0.120))
        let sTrailing = M.hf(audio, (trailing.lowerBound + M.frame(0.020))..<(trailing.lowerBound + M.frame(0.100)))
        let edgeWindow = M.frame(ConsonantSmear.edgeSeconds)
        let sourceOnset = M.hf(audio, vowel.lowerBound..<(vowel.lowerBound + edgeWindow))
        let sourceOffset = M.hf(audio, (vowel.upperBound - edgeWindow)..<vowel.upperBound)
        Self.log("premises: /a/ frames \(vowel), 't' frames \(t), trailing 's' \(trailing); the leading 's' (20-100 ms) \(M.f(sReference)) dB, the trailing 's' \(M.f(sTrailing)) dB; the /a/'s mid 60 ms \(M.f(vowelMid(audio))) dB, its onset 60 ms \(M.f(sourceOnset)) dB, its offset 60 ms \(M.f(sourceOffset)) dB: CONTRAST at the mid \(M.f(sReference - vowelMid(audio))) dB, at the edges \(M.f(sReference - sourceOnset)) / \(M.f(sTrailing - sourceOffset)) dB (4-20 kHz)")
        // 0. The recorded 8 cells: the harness's own positive control.
        let baseline = try Self.cells(audio, note: fixture.note)
        Self.report("baseline", baseline)
        // 1. Where the edge's high band comes from.
        let vowelOnly = try Self.cells(M.only(audio, vowel), note: fixture.note)
        Self.report("no consonants", vowelOnly)
        // The leak: the edge power the consonants add (baseline minus the
        // vowel-only render, same cell), against the adjacent 's'.
        for (full, bare) in zip(baseline, vowelOnly) {
            try #require(full.retuneMs == bare.retuneMs && full.seeded == bare.seeded
                         && full.onset == bare.onset, "premise: the two runs list the cells alike")
            let added = pow(10, full.movedEdge / 10) - pow(10, bare.movedEdge / 10)
            let leak = added > 0 ? 10 * log10(added) : -180
            let consonant = full.onset ? sReference : sTrailing
            Self.log("leak | retune \(Int(full.retuneMs)) | \(full.seeded ? "seeded" : "legacy") | \(full.onset ? "onset " : "offset") | the consonants add \(M.f(leak)) dB at the moved edge = \(M.s(leak - consonant)) dB re the adjacent 's'; the moved vowel's own edge \(M.f(bare.movedEdge)) dB = \(M.s(bare.movedEdge - consonant)) dB re it; leak over the vowel's own edge \(M.s(leak - bare.movedEdge)) dB")
        }
        Self.report("no 't'", try Self.cells(M.zeroed(audio, t), note: fixture.note))
        // 2. The vowel's own edges: its 3 ms raised cosine made 30 ms.
        Self.report("soft vowel edges 30 ms", try Self.cells(M.softened(audio, vowel, seconds: 0.030),
                                                             note: fixture.note))
        // 3. The level ratio: a high-band floor under the vowel.
        for contrast in [60.0, 50, 40, 35, 30, 20] {
            let floored = M.withFloor(audio, vowel, referenceDb: sReference, contrastDb: contrast)
            Self.report("floor, contrast \(Int(contrast)) dB (measured \(M.f(sReference - vowelMid(floored))))",
                        try Self.cells(floored, note: fixture.note))
        }
        // 4. The move's size. Uncorrected, F4 (3400 Hz) enters the 4 kHz band
        //    at 1200·log2(4000/3400) = +281 c.
        for cents in [100.0, 200, 700, 1200] {
            Self.report("move \(Int(cents)) c", try Self.cells(audio, note: fixture.note, cents: cents))
        }
        // 5. The band: 5-20 kHz keeps a +300 c F4 (4045 Hz) out.
        Self.report("band 5-20 kHz", try Self.cells(audio, note: fixture.note, band: 5000...20000))
        // 6. The mix: seeded with the flag forced OFF, and the edge windows'
        //    bytes flag on vs off (the mix writes only w < 1 frames).
        Self.report("flag OFF", try Self.cells(audio, note: fixture.note, consonants: false))
        for retune in [30.0, 200.0] {
            let on = StarsFixture.set(fixture, cents: 300, retuneMs: retune, seeded: true)
            var off = on
            off.keepsConsonantsUntuned = false
            let yOn = try ConsonantSmear.product(audio, set: on, sampleRate: M.sampleRate)
            let yOff = try ConsonantSmear.product(audio, set: off, sampleRate: M.sampleRate)
            let fades = on.consonantRegions().map { M.f($0.fadeSeconds * 1000) }
            for edge in ConsonantSmear.edges(of: on, frames: yOn.count, sampleRate: M.sampleRate) {
                let differ = edge.window.filter { yOn[$0].bitPattern != yOff[$0].bitPattern }.count
                let blended = edge.window.filter {
                    on.tunedWeight(atSourceSecond: Double($0) / M.sampleRate) < 1
                }.count
                Self.log("mix bytes | retune \(Int(retune)) | seeded | \(edge.onset ? "onset " : "offset") | \(differ) of \(edge.window.count) edge frames differ flag on vs off; \(blended) edge frames have w < 1; region fades \(fades) ms")
            }
        }
    }
}

extension NaturalTuningTakeHarnessSection2Tests {
    /// G-C12's mechanism on the user's take (env-gated, LOG-ONLY): the
    /// contrast the fixture exaggerates, measured per edge (the 4-20 kHz
    /// energy of the region frames within the stretcher's 120 ms block of
    /// the boundary, minus the note's mid 60 ms), the recording's own floor,
    /// and M-2b's SMEAR at +300, +700 and +1200 c (every note, product seed).
    @Test("G-C12 mechanism (real take): the per-edge high-band contrast and the recording's floor, and M-2b's smear at +300/+700/+1200 c; logged, never asserted",
          .enabled(if: enabled && SmearMechanism.enabled))
    @MainActor
    func gC12MechanismRealTake() throws {
        typealias M = SmearMechanism
        let source = URL(fileURLWithPath: Self.sourcePath)
        let dry = try TestSignals.readFile(source)[0]
        let sr = try AVAudioFile(forReading: source).processingFormat.sampleRate
        let table = PitchNoteTable.detected(from: try PitchContourCache.detectWholeFile(source, .product))
        let unmoved = try ConsonantSmear.unmoved(dry, sampleRate: sr)
        func hf(_ x: [Float], _ window: Range<Int>) -> Double { ConsonantSmear.hfDb(x, window, sampleRate: sr) }
        func frame(_ second: Double) -> Int {
            min(dry.count, StretchCurvePlan.outputFrame(forSourceSecond: second, ratio: 1, sampleRate: sr))
        }
        // The recording's floor and ceiling: the quietest and loudest 60 ms
        // (30 ms hop) of the take in 4-20 kHz.
        let w60 = Int((0.060 * sr).rounded())
        var floorDb = Double.infinity, ceilingDb = -Double.infinity
        for start in stride(from: 0, to: dry.count - w60, by: w60 / 2) {
            let level = hf(dry, start..<(start + w60))
            floorDb = min(floorDb, level)
            ceilingDb = max(ceilingDb, level)
        }
        var flagged = table
        flagged.keepsConsonantsUntuned = true
        let regions = flagged.consonantRegions()
        Self.log("G-C12 mechanism: take \(dry.count) frames at \(sr) Hz, \(regions.count) regions; 4-20 kHz over 60 ms: quietest \(M.f(floorDb)) dB, loudest \(M.f(ceilingDb)) dB (the recording's widest possible contrast \(M.f(ceilingDb - floorDb)) dB)")
        for cents in [300.0, 700, 1200] {
            var segments = table.segments
            for i in segments.indices where segments[i].origin != .unpitched {
                segments[i].pitchOffsetCents = cents
            }
            let set = table.withSegments(segments)
            let moved = try ConsonantSmear.product(dry, set: set, sampleRate: sr)
            let edges = ConsonantSmear.edges(of: set, frames: moved.count, sampleRate: sr)
            try #require(!edges.isEmpty, "no qualifying edge on the take")
            var rows: [(contrast: Double, smear: Double, excessEdge: Double, excessMid: Double, label: String)] = []
            var edgeContrasts: [Double] = []
            for edge in edges {
                let r = ConsonantSmear.read(edge, source: dry, unmoved: unmoved, moved: moved, sampleRate: sr)
                let note = set.segments[edge.noteIndex]
                let consonant: Range<Int>
                if edge.onset {
                    let region = regions.first { $0.precedesNote && $0.endSeconds == note.startSeconds }
                    let start = max(region?.startSeconds ?? note.startSeconds, note.startSeconds - 0.120)
                    consonant = frame(start)..<frame(note.startSeconds)
                } else {
                    let region = regions.first { $0.followsNote && $0.startSeconds == note.endSeconds }
                    let end = min(region?.endSeconds ?? note.endSeconds, note.endSeconds + 0.120)
                    consonant = frame(note.endSeconds)..<frame(end)
                }
                let contrast = hf(dry, consonant) - hf(dry, edge.mid)
                let edgeContrast = hf(dry, consonant) - hf(dry, edge.window)
                edgeContrasts.append(edgeContrast)
                rows.append((contrast, r.smear, r.excessEdge, r.excessMid,
                             "note \(edge.noteIndex) \(edge.onset ? "onset" : "offset") (\(consonant.count) region frames, source mid \(M.f(hf(dry, edge.mid))) dB, EDGE contrast \(M.f(edgeContrast)) dB)"))
            }
            let smears = rows.map { $0.smear }, contrasts = rows.map { $0.contrast }
            let p = { (x: [Double], q: Double) in ConsonantSmear.percentile(x, q) }
            Self.log("G-C12 mechanism +\(Int(cents)) c: \(rows.count) edges; SMEAR median \(M.s(p(smears, 0.5))) p90 \(M.s(p(smears, 0.9))) max \(M.s(smears.max() ?? .nan)) dB, over 3 dB on \(smears.filter { $0 > ConsonantSmear.audibleSmearDb }.count); excessEdge median \(M.s(p(rows.map { $0.excessEdge }, 0.5))), excessMid median \(M.s(p(rows.map { $0.excessMid }, 0.5))); CONTRAST min \(M.f(contrasts.min() ?? .nan)) median \(M.f(p(contrasts, 0.5))) p90 \(M.f(p(contrasts, 0.9))) max \(M.f(contrasts.max() ?? .nan)) dB")
            Self.log("G-C12 mechanism +\(Int(cents)) c: EDGE CONTRAST (region within 120 ms minus the note's own edge 60 ms) min \(M.f(edgeContrasts.min() ?? .nan)) median \(M.f(p(edgeContrasts, 0.5))) p90 \(M.f(p(edgeContrasts, 0.9))) max \(M.f(edgeContrasts.max() ?? .nan)) dB; over 30 dB on \(edgeContrasts.filter { $0 > 30 }.count), over 40 dB on \(edgeContrasts.filter { $0 > 40 }.count)")
            for row in rows where row.smear > ConsonantSmear.audibleSmearDb {
                Self.log("G-C12 mechanism +\(Int(cents)) c: OVER 3 dB: SMEAR \(M.s(row.smear)) = excessEdge \(M.s(row.excessEdge)) minus excessMid \(M.s(row.excessMid)); mid contrast \(M.f(row.contrast)) dB, \(row.label)")
            }
            let median = p(contrasts, 0.5)
            let high = rows.filter { $0.contrast > median }.map { $0.smear }
            let low = rows.filter { $0.contrast <= median }.map { $0.smear }
            Self.log("G-C12 mechanism +\(Int(cents)) c: SMEAR median on the \(high.count) edges above the median contrast \(M.s(p(high, 0.5))) dB, on the \(low.count) at or below it \(M.s(p(low, 0.5))) dB")
            for row in rows.sorted(by: { $0.contrast > $1.contrast }).prefix(6) {
                Self.log("G-C12 mechanism +\(Int(cents)) c: top contrast \(M.f(row.contrast)) dB, SMEAR \(M.s(row.smear)) (excessEdge \(M.s(row.excessEdge)), excessMid \(M.s(row.excessMid))), \(row.label)")
            }
            for row in rows.sorted(by: { $0.smear > $1.smear }).prefix(3) {
                Self.log("G-C12 mechanism +\(Int(cents)) c: top SMEAR \(M.s(row.smear)) at contrast \(M.f(row.contrast)) dB (excessEdge \(M.s(row.excessEdge)), excessMid \(M.s(row.excessMid))), \(row.label)")
            }
        }
    }

    /// ⭐ **WHAT THE CONSONANT WEIGHTS COST EACH PROVISIONAL BUILD** (W7-NTE2,
    /// env-gated microbenchmark, LOG-ONLY; its numbers are read under the
    /// lane's `timing.lock`). The user's take, the product seed with every
    /// note +300 c as the base, one note near the middle moved a further
    /// +100 c as the edit. Two places run `RenderDiff.consonantWeights` on
    /// every edit, timed apart, p50 of 5 after one warm-up:
    ///  (a) the extent's X6 union, `RenderDiff.differingConsonantFrames`
    ///      (both sides' weights over every region of old ∪ new);
    ///  (b) the memo key's hash, per cluster: `consonantRegions` +
    ///      `consonantWeights` over the key's window + SHA256 of the
    ///      weights, the clusters and windows formed as
    ///      `ProvisionalRender.splice` forms them (`Tuning.product`);
    ///  (c) for context, the WHOLE provisional build of the same edit
    ///      against the base's own final, with the build's laps.
    @Test("COST per edit (real take): what RenderDiff.consonantWeights adds to a provisional build, the extent's X6 union and the memo key's hash, and the whole build with its laps, p50 of 5 (env-gated, log-only)",
          .enabled(if: enabled && ProcessInfo.processInfo.environment["NTE2_SPLICE_COST"] != nil))
    @MainActor
    func consonantWeightsCostPerEdit() throws {
        let source = URL(fileURLWithPath: Self.sourcePath)
        let dry = try TestSignals.readFile(source)[0]
        let sr = try AVAudioFile(forReading: source).processingFormat.sampleRate
        let table = PitchNoteTable.detected(from: try PitchContourCache.detectWholeFile(source, .product))
        var segments = table.segments
        for i in segments.indices where segments[i].origin != .unpitched { segments[i].pitchOffsetCents = 300 }
        let oldSet = table.withSegments(segments)
        let pitched = segments.indices.filter { segments[$0].origin != .unpitched }
        let edited = pitched[pitched.count / 2]
        segments[edited].pitchOffsetCents += 100
        let newSet = table.withSegments(segments)
        func params(_ set: PitchEditSet) -> StretchRenderCache.Params {
            StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: false, pitchEdits: set)
        }
        let oldSide = RenderDiff.Side(params: params(oldSet), curveContour: nil)
        let newSide = RenderDiff.Side(params: params(newSet), curveContour: nil)
        let oldPlan = RenderDiff.plan(for: oldSide, sampleRate: sr)
        let newPlan = RenderDiff.plan(for: newSide, sampleRate: sr)
        let regions = RenderDiff.consonantRegions(newSide, plan: newPlan)
        try #require(!regions.isEmpty && StretchCurvePlan.consonantMixActive(params(newSet)),
                     "premise: the new render runs the mix")
        let extent = try RenderDiff.extent(old: oldSide, new: newSide, sourceFrames: dry.count, channels: 1,
                                           sampleRate: sr).get()
        let outputFrames = extent.outputFrames
        // The clusters and memo windows, as `ProvisionalRender.splice` forms them.
        let tuning = ProvisionalRender.Tuning.product
        func frames(_ seconds: Double) -> Int { max(1, Int((seconds * sr).rounded())) }
        let window = frames(tuning.seamSearchSeconds), smear = frames(tuning.smearSeconds)
        let half = frames(tuning.voicedCrossfadeSeconds) / 2 + frames(tuning.rmsWindowSeconds) / 2 + 1
        var clusters: [Range<Int>] = []
        for range in RenderDiff.merged(extent.pitchRanges + extent.maskRanges) {
            if let last = clusters.last, range.lowerBound - last.upperBound <= 2 * (window + half) + smear {
                clusters[clusters.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                clusters.append(range)
            }
        }
        let keyWindows = clusters.map {
            max(0, $0.lowerBound - window - half)..<min(outputFrames, $0.upperBound + smear + window + half)
        }
        let regionFrames = regions.reduce(0) { total, region in
            let lo = StretchCurvePlan.firstOutputFrame(atOrAfterSourceSecond: region.startSeconds,
                                                       frames: outputFrames, ratio: 1, sampleRate: sr)
            let hi = region.endSeconds.isFinite
                ? StretchCurvePlan.firstOutputFrame(atOrAfterSourceSecond: region.endSeconds,
                                                    frames: outputFrames, ratio: 1, sampleRate: sr)
                : outputFrames
            return total + max(0, hi - lo)
        }
        func ms(_ body: () throws -> Void) rethrows -> Double {
            let t = ContinuousClock.now
            try body()
            let d = ContinuousClock.now - t
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        func union() throws {
            _ = try RenderDiff.differingConsonantFrames(old: oldSide, oldPlan: oldPlan, new: newSide,
                                                        newPlan: newPlan, outputFrames: outputFrames,
                                                        sampleRate: sr, ratio: 1, isCancelled: { false })
        }
        var digests: [String] = []
        func keys() throws {
            digests = []
            for range in keyWindows {
                var hasher = SHA256()
                let r = RenderDiff.consonantRegions(newSide, plan: newPlan)
                if !r.isEmpty {
                    let weights = try RenderDiff.consonantWeights(r, range: range, sampleRate: sr, ratio: 1)
                    hasher.update(data: Data("consonant".utf8))
                    weights.withUnsafeBytes { hasher.update(bufferPointer: $0) }
                }
                digests.append(hasher.finalize().map { String(format: "%02x", $0) }.joined())
            }
        }
        func extentOnly() throws {
            _ = try RenderDiff.extent(old: oldSide, new: newSide, sourceFrames: dry.count, channels: 1,
                                      sampleRate: sr).get()
        }
        func loads() -> String {
            var l = [Double](repeating: 0, count: 3)
            getloadavg(&l, 3)
            return l.map { String(format: "%.2f", $0) }.joined(separator: " ")
        }
        try union(); try keys(); try extentOnly()
        let startLoad = loads()
        var a: [Double] = [], b: [Double] = [], e: [Double] = []
        for _ in 0..<5 {
            a.append(try ms(union))
            b.append(try ms(keys))
            e.append(try ms(extentOnly))
        }
        let endLoad = loads()
        let p50 = { (x: [Double]) in ConsonantSmear.percentile(x, 0.5) }
        let list = { (x: [Double]) in x.map { String(format: "%.2f", $0) }.joined(separator: ", ") }
        Self.log("SPLICE COST: take \(String(format: "%.1f", Double(dry.count) / sr)) s, \(regions.count) regions over \(regionFrames) frames (\(String(format: "%.2f", Double(regionFrames) / sr)) s); the edit moves note \(edited) (\(String(format: "%.2f", newSet.segments[edited].startSeconds))-\(String(format: "%.2f", newSet.segments[edited].endSeconds)) s); extent: \(extent.pitchRanges.count) pitch ranges, \(extent.consonantRanges.count) consonant ranges; \(clusters.count) clusters, key windows \(keyWindows.map(\.count)) frames")
        Self.log("SPLICE COST: (a) the extent's X6 union, differingConsonantFrames: p50 \(String(format: "%.2f", p50(a))) ms [\(list(a))]")
        Self.log("SPLICE COST: (b) the memo key's consonant hash, all clusters: p50 \(String(format: "%.2f", p50(b))) ms [\(list(b))]")
        Self.log("SPLICE COST: context, the whole RenderDiff.extent (includes (a)): p50 \(String(format: "%.2f", p50(e))) ms [\(list(e))]")
        Self.log("SPLICE COST: load average \(startLoad) at the start, \(endLoad) at the end; debug build (./scripts/test.sh); \(digests.count) key digests")
        // (c) The WHOLE provisional build of this edit (D41's second-edit
        // shape: a flag-on vocal, one note moved, against that vocal's own
        // final), p50 of 5 after one warm-up, with the build's own laps
        // (`Built.millis`; its "extent" lap is everything up to and including
        // `RenderDiff.extent`, the two contour lookups included).
        let dir = try I1Signals.tempDir("nte2-splice-cost")
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseURL = try ProvisionalRenderTests.finalRender(source, params(oldSet), dir: dir, name: "base")
        let job = ProvisionalRenderTests.job(source: source,
                                             base: ProvisionalRenderTests.base(baseURL, params(oldSet)),
                                             params: params(newSet), dir: dir, name: "second")
        _ = try ProvisionalRenderTests.built(ProvisionalRender.build(job, isCancelled: { false }))
        let buildLoad = loads()
        var builds: [Double] = []
        var laps: [String: [Double]] = [:]
        var kinds: Set<String> = []
        for _ in 0..<5 {
            var built: ProvisionalRender.Built?
            builds.append(try ms {
                built = try ProvisionalRenderTests.built(ProvisionalRender.build(job, isCancelled: { false }))
            })
            guard let built else { continue }
            kinds.insert(built.kind.rawValue)
            for (name, value) in built.millis { laps[name, default: []].append(value) }
        }
        let lapText = laps.keys.sorted().map {
            "\($0) \(String(format: "%.1f", p50(laps[$0] ?? [])))"
        }.joined(separator: ", ")
        Self.log("SPLICE COST: (c) the whole provisional build of this edit (\(kinds.sorted().joined(separator: "/"))): p50 \(String(format: "%.1f", p50(builds))) ms [\(list(builds))]; its laps, p50 ms: \(lapText); load \(buildLoad) at the start, \(loads()) at the end")
    }
}
