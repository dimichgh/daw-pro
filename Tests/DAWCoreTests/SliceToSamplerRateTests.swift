import Foundation
import Testing
@testable import DAWCore

/// ⭐ m32-b2 — THE UNIT-TRAP GATE.
///
/// Transients come back in SECONDS; sampler zones want FRAMES at the FILE's
/// own sample rate. A 48 kHz rip chopped against a hardcoded 44100 lands every
/// chop **8.8 % off — and it would still sound like music**, which is why this
/// gate exists at all. The engine seam is designed so the only way to obtain a
/// frame number is from a `SliceBoundaryGeometry` that also carries the rate
/// those frames are in; this suite proves the PLANNER actually honours it.
///
/// ⚠️ POSITIVE CONTROL IS THE POINT: a test that only ever compares one rate
/// to itself cannot see a hardcoded constant. Every assertion here is paired
/// with one asserting the two rates produce DIFFERENT numbers.
@Suite("SliceToSamplerPlan — the sample-rate unit trap (m32-b2)")
struct SliceToSamplerRateTests {

    private static let sourceURL = URL(fileURLWithPath: "/tmp/slice-rate-fixture.wav")
    private static let tempo = TempoMap(constantBPM: 120)

    /// Clip [0, 4) beats at 120 BPM → source window [0, 2) s, whole file.
    private static func clip() -> Clip {
        Clip(name: "Break", startBeat: 0, lengthBeats: 4,
             audioFileURL: sourceURL, startOffsetSeconds: 0)
    }

    /// The SAME boundary SECONDS (0.5 / 1.0 / 1.5), expressed in frames at the
    /// given rate — exactly what a correct engine seam would return for the
    /// same file recorded at two rates.
    private static func geometry(rate: Double) -> SliceBoundaryGeometry {
        let seconds = [0.5, 1.0, 1.5]
        let frames = seconds.map { Int(($0 * rate).rounded()) }
        return SliceBoundaryGeometry(
            sampleRate: rate, frameCount: Int((2.0 * rate).rounded()),
            boundaryFrames: frames,
            snapOffsetFrames: Array(repeating: 0, count: frames.count),
            residualAmplitude: Array(repeating: 0.0, count: frames.count))
    }

    @Test("the same chop at 44.1 kHz and 48 kHz differs by exactly the rate ratio")
    func frameNumbersScaleWithTheRate() throws {
        let settings = SliceToSamplerSettings()
        let at441 = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(rate: 44_100), strengths: [],
            settings: settings, tempoMap: Self.tempo)
        let at480 = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(rate: 48_000), strengths: [],
            settings: settings, tempoMap: Self.tempo)

        let starts441 = at441.zones.map(\.startFrame)
        let starts480 = at480.zones.map(\.startFrame)
        #expect(starts441 == [22_050, 44_100, 66_150])
        #expect(starts480 == [24_000, 48_000, 72_000])

        // ⭐ POSITIVE CONTROL: the two arrays are NOT equal. A planner that
        // divided by a hardcoded 44100 would return the 44.1 kHz frames for
        // BOTH geometries and this assertion is the only one that sees it.
        #expect(starts441 != starts480)

        let ratio = 48_000.0 / 44_100.0
        for (a, b) in zip(starts441, starts480) {
            let from = Double(try #require(a))
            let to = Double(try #require(b))
            #expect(abs(to - from * ratio) < 1.0)
        }
    }

    @Test("SECONDS and BEATS are rate-invariant while FRAMES are not")
    func secondsAndBeatsAreInvariant() throws {
        let settings = SliceToSamplerSettings()
        let at441 = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(rate: 44_100), strengths: [],
            settings: settings, tempoMap: Self.tempo)
        let at480 = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(rate: 48_000), strengths: [],
            settings: settings, tempoMap: Self.tempo)

        // The musical result is IDENTICAL — this is what makes the bug so
        // dangerous when it happens on the frame side: the wrong chop still
        // reads like music.
        for (a, b) in zip(at441.slices, at480.slices) {
            #expect(abs(a.sourceSeconds - b.sourceSeconds) < 1e-6)
            #expect(abs(a.beat - b.beat) < 1e-6)
        }
        #expect(at441.notes.map(\.startBeat).count == at480.notes.map(\.startBeat).count)
        for (a, b) in zip(at441.notes, at480.notes) {
            #expect(abs(a.startBeat - b.startBeat) < 1e-6)
        }
        // ...while the frames are, and must be, different.
        #expect(at441.slices.map(\.startFrame) != at480.slices.map(\.startFrame))
    }

    @Test("the last pad's file-end test uses the geometry's OWN frame count")
    func fileEndTestIsRateAware() throws {
        // 48 kHz geometry whose frameCount is the 44.1 kHz answer (96 000 vs
        // 88 200): the window no longer reaches the end, so the last pad must
        // stop at the window rather than reporting nil.
        var mismatched = Self.geometry(rate: 48_000)
        mismatched.frameCount = 120_000                 // 2.5 s at 48 kHz
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: mismatched, strengths: [],
            settings: SliceToSamplerSettings(), tempoMap: Self.tempo)
        #expect(plan.zones.last?.endFrame == 96_000)    // 2 s at 48 kHz, not 88 200
        // POSITIVE CONTROL: at the matching frame count it IS nil.
        let exact = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(rate: 48_000), strengths: [],
            settings: SliceToSamplerSettings(), tempoMap: Self.tempo)
        #expect(exact.zones.last?.endFrame == nil)
    }

    @Test("includeHead's window-start frame is also rate-derived")
    func headFrameIsRateAware() throws {
        // Clip trimmed to start 0.25 s into the file.
        let trimmed = Clip(name: "Break", startBeat: 0, lengthBeats: 4,
                           audioFileURL: Self.sourceURL, startOffsetSeconds: 0.25)
        func headStart(rate: Double) throws -> Int? {
            var g = Self.geometry(rate: rate)
            g.boundaryFrames = [Int((1.0 * rate).rounded())]
            g.snapOffsetFrames = [0]
            g.residualAmplitude = [0]
            g.frameCount = Int((4.0 * rate).rounded())
            return try SliceToSamplerPlan.compute(
                clip: trimmed, geometry: g, strengths: [],
                settings: SliceToSamplerSettings(includeHead: true),
                tempoMap: Self.tempo).zones.first?.startFrame
        }
        #expect(try headStart(rate: 44_100) == 11_025)
        #expect(try headStart(rate: 48_000) == 12_000)
        #expect(try headStart(rate: 44_100) != (try headStart(rate: 48_000)))
    }
}
