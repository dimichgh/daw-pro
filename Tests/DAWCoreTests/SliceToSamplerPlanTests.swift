import Foundation
import Testing
@testable import DAWCore

/// m32-b2 — pure chop-to-sampler planning against a FAKE
/// `SliceBoundaryGeometry`. Fully headless: no engine, no file, no PCM.
///
/// Canonical fixture: 120 BPM (spb 0.5), clip `[0, 4)` beats at source offset
/// 0 → source window `[0, 2)` s. Geometry: 44.1 kHz, 88 200 frames, so the
/// clip's window is EXACTLY the whole file and the last pad's `endFrame` is
/// legitimately nil. Boundaries at 0.5 / 1.0 / 1.5 s = frames 22 050 / 44 100
/// / 66 150.
@Suite("SliceToSamplerPlan — pure planning (m32-b2)")
struct SliceToSamplerPlanTests {

    static let rate = 44_100.0
    static let sourceURL = URL(fileURLWithPath: "/tmp/slice-to-sampler-fixture.wav")

    static func clip(startBeat: Double = 0, length: Double = 4, offset: Double = 0,
                     name: String = "Break") -> Clip {
        Clip(name: name, startBeat: startBeat, lengthBeats: length,
             audioFileURL: sourceURL, startOffsetSeconds: offset)
    }

    /// Three boundaries, no snap movement, whole-file geometry.
    static func geometry(frames: [Int] = [22_050, 44_100, 66_150],
                         rate: Double = SliceToSamplerPlanTests.rate,
                         frameCount: Int = 88_200) -> SliceBoundaryGeometry {
        SliceBoundaryGeometry(
            sampleRate: rate, frameCount: frameCount, boundaryFrames: frames,
            snapOffsetFrames: Array(repeating: 0, count: frames.count),
            residualAmplitude: Array(repeating: 0.0004, count: frames.count))
    }

    static let tempo = TempoMap(constantBPM: 120)

    // MARK: - Span adjacency and the shared boundary

    @Test("pad i's endFrame IS pad i+1's startFrame; the last is nil at the file end")
    func spanAdjacency() throws {
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [0.9, 0.5, 0.7],
            settings: SliceToSamplerSettings(), tempoMap: Self.tempo)
        #expect(plan.zones.count == 3)
        #expect(plan.zones[0].startFrame == 22_050)
        #expect(plan.zones[0].endFrame == 44_100)
        #expect(plan.zones[1].startFrame == 44_100)
        #expect(plan.zones[1].endFrame == 66_150)
        #expect(plan.zones[2].startFrame == 66_150)
        // ⭐ nil resolves to the exact file end in the engine — no float
        // round-trip through durationSeconds × sampleRate can overshoot.
        #expect(plan.zones[2].endFrame == nil)
        for i in 0..<(plan.zones.count - 1) {
            #expect(plan.zones[i].endFrame == plan.zones[i + 1].startFrame)
        }
    }

    @Test("a TRIMMED clip stops the last pad at the window end, NOT the file end")
    func trimmedClipLastPad() throws {
        // Clip window [0, 2) s but the file is 4 s long: nil would hand the last
        // pad the whole rest of the record.
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(frameCount: 176_400),
            strengths: [], settings: SliceToSamplerSettings(generateMIDI: false),
            tempoMap: Self.tempo)
        #expect(plan.zones.last?.endFrame == 88_200)
        // POSITIVE CONTROL: the same call on a file that ENDS at the window
        // still reports nil — so this assertion can distinguish the two.
        let whole = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [],
            settings: SliceToSamplerSettings(generateMIDI: false), tempoMap: Self.tempo)
        #expect(whole.zones.last?.endFrame == nil)
    }

    // MARK: - Zone fields

    @Test("one pad per note from baseNote; minPitch == maxPitch == rootPitch")
    func pitchMapping() throws {
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [],
            settings: SliceToSamplerSettings(baseNote: 48), tempoMap: Self.tempo)
        for (i, zone) in plan.zones.enumerated() {
            #expect(zone.rootPitch == 48 + i)
            #expect(zone.minPitch == 48 + i)
            #expect(zone.maxPitch == 48 + i)
        }
    }

    @Test("attack 0 and release 10 ms on every generated pad, gain 1")
    func envelope() throws {
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [],
            settings: SliceToSamplerSettings(), tempoMap: Self.tempo)
        for zone in plan.zones {
            #expect(zone.attack == 0.0)
            #expect(zone.release == 0.010)
            #expect(zone.gain == 1)
            #expect(zone.audioFileURL == Self.sourceURL)
            // The nil-default law: an unauthored field must decode and render
            // exactly as it always has.
            #expect(zone.loopMode == nil)
            #expect(zone.pan == nil)
            #expect(zone.tuneCents == nil)
            #expect(zone.ampVelTrack == nil)
            #expect(zone.oneShot == nil)
            #expect(zone.crossfade == nil)
        }
    }

    // MARK: - Reconstruction MIDI

    @Test("notes are velocity 127 by default, NOT the detector strength")
    func velocityIs127() throws {
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [0.1, 0.5, 1.0],
            settings: SliceToSamplerSettings(), tempoMap: Self.tempo)
        #expect(plan.notes.map(\.velocity) == [127, 127, 127])
        // ...and the strengths are still in the report, so nothing is lost.
        #expect(plan.slices.map(\.strength) == [0.1, 0.5, 1.0])
    }

    @Test("velocityFromStrength: true restores the detector's dynamics")
    func velocityFromStrength() throws {
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [0.1, 0.5, 1.0],
            settings: SliceToSamplerSettings(velocityFromStrength: true),
            tempoMap: Self.tempo)
        // 0.1 × 127 = 12.7 → 13; 0.5 → 64 (63.5 rounds away from zero); 1.0 → 127.
        #expect(plan.notes.map(\.velocity) == [13, 64, 127])
        // POSITIVE CONTROL: the two modes genuinely differ — a test that only
        // ever compares 127 to 127 cannot see a flag that does nothing.
        let flat = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [0.1, 0.5, 1.0],
            settings: SliceToSamplerSettings(), tempoMap: Self.tempo)
        #expect(flat.notes.map(\.velocity) != plan.notes.map(\.velocity))
    }

    @Test("note beats replay the original groove; lengths run to the next boundary")
    func noteTiming() throws {
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [],
            settings: SliceToSamplerSettings(), tempoMap: Self.tempo)
        // 0.5 / 1.0 / 1.5 s at spb 0.5 → beats 1 / 2 / 3, clip-relative.
        #expect(plan.notes.count == 3)
        for (i, expected) in [1.0, 2.0, 3.0].enumerated() {
            #expect(abs(plan.notes[i].startBeat - expected) < 1e-9)
            #expect(abs(plan.notes[i].lengthBeats - 1.0) < 1e-9)
        }
        // The report's absolute beats agree with the notes.
        #expect(abs(plan.slices[0].beat - 1.0) < 1e-9)
        #expect(plan.midiClipStartBeat == 0)
        #expect(plan.midiClipLengthBeats == 4)
    }

    @Test("atBeat moves the reconstruction clip WITHOUT re-timing the groove")
    func atBeatMovesIntact() throws {
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [],
            settings: SliceToSamplerSettings(atBeat: 16), tempoMap: Self.tempo)
        #expect(plan.midiClipStartBeat == 16)
        #expect(plan.notes.map { ($0.startBeat * 1000).rounded() } == [1000, 2000, 3000])
    }

    @Test("a clip that does not start at beat 0 still produces clip-relative notes")
    func offsetClip() throws {
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(startBeat: 8), geometry: Self.geometry(), strengths: [],
            settings: SliceToSamplerSettings(), tempoMap: Self.tempo)
        #expect(plan.midiClipStartBeat == 8)
        #expect(abs(plan.notes[0].startBeat - 1.0) < 1e-9)      // clip-relative
        #expect(abs(plan.slices[0].beat - 9.0) < 1e-9)          // absolute
    }

    @Test("generateMIDI false emits zones and no notes")
    func noMIDI() throws {
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [],
            settings: SliceToSamplerSettings(generateMIDI: false), tempoMap: Self.tempo)
        #expect(plan.zones.count == 3)
        #expect(plan.notes.isEmpty)
    }

    // MARK: - includeHead

    @Test("includeHead adds pad 1 spanning the window edge to the first boundary")
    func includeHead() throws {
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [0.9, 0.5, 0.7],
            settings: SliceToSamplerSettings(includeHead: true), tempoMap: Self.tempo)
        #expect(plan.zones.count == 4)
        #expect(plan.zones[0].startFrame == 0)
        #expect(plan.zones[0].endFrame == 22_050)
        #expect(plan.zones[0].rootPitch == 36)
        #expect(plan.zones[3].rootPitch == 39)
        // The head pad honestly reports NO strength and NO snap — no detector
        // produced it and its start was never snapped.
        #expect(plan.slices[0].strength == nil)
        #expect(plan.slices[0].snapOffsetFrames == nil)
        #expect(plan.slices[0].residualAmplitude == nil)
        // ...and the strengths still line up with the pads that DO have one.
        #expect(plan.slices.map(\.strength) == [nil, 0.9, 0.5, 0.7])
        // No discard warning when the head was kept.
        #expect(!plan.warnings.contains { $0.contains("discarded") })
    }

    @Test("headSeconds is always reported, and a large discarded head warns")
    func headWarning() throws {
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [],
            settings: SliceToSamplerSettings(), tempoMap: Self.tempo)
        #expect(abs(plan.headSeconds - 0.5) < 1e-9)
        #expect(plan.warnings.contains { $0.contains("includeHead") })
        // ClampNotice doctrine: no warning when nothing actually happened —
        // a head under 2× minSlice is ordinary pre-roll.
        let tight = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(frames: [2_205, 44_100, 66_150]),
            strengths: [], settings: SliceToSamplerSettings(), tempoMap: Self.tempo)
        #expect(abs(tight.headSeconds - 0.05) < 1e-9)
        #expect(!tight.warnings.contains { $0.contains("includeHead") })
    }

    // MARK: - Rejections (§6.5)

    @Test("no boundaries at all is audioQuantizeNoTransients, and changes nothing")
    func noBoundaries() {
        #expect(throws: ProjectError.self) {
            try SliceToSamplerPlan.compute(
                clip: Self.clip(), geometry: Self.geometry(frames: []), strengths: [],
                settings: SliceToSamplerSettings(), tempoMap: Self.tempo)
        }
    }

    @Test("more pads than maxSlices REJECTS and never truncates")
    func maxSlicesRejects() throws {
        let frames = (1...20).map { $0 * 4_000 }
        var thrown: ProjectError?
        do {
            _ = try SliceToSamplerPlan.compute(
                clip: Self.clip(), geometry: Self.geometry(frames: frames), strengths: [],
                settings: SliceToSamplerSettings(maxSlices: 8), tempoMap: Self.tempo)
        } catch let error as ProjectError {
            thrown = error
        }
        let message = try #require(thrown?.errorDescription)
        #expect(message.contains("20 pads"))
        #expect(message.contains("maxSlices limit of 8"))
        #expect(message.contains("never silently dropped"))
        // POSITIVE CONTROL: the same boundaries under a sufficient ceiling
        // succeed with ALL 20 pads — nothing was quietly kept back.
        let ok = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(frames: frames), strengths: [],
            settings: SliceToSamplerSettings(maxSlices: 32), tempoMap: Self.tempo)
        #expect(ok.zones.count == 20)
    }

    @Test("running past MIDI 127 REJECTS, naming the arithmetic")
    func midiRangeExhaustion() throws {
        var thrown: ProjectError?
        do {
            _ = try SliceToSamplerPlan.compute(
                clip: Self.clip(), geometry: Self.geometry(), strengths: [],
                settings: SliceToSamplerSettings(baseNote: 126), tempoMap: Self.tempo)
        } catch let error as ProjectError {
            thrown = error
        }
        let message = try #require(thrown?.errorDescription)
        #expect(message.contains("note 128"))
        #expect(message.contains("MIDI stops at 127"))
    }

    @Test("a fabricated zero-rate geometry is refused, not divided by")
    func zeroRateRefused() {
        let bogus = SliceBoundaryGeometry(sampleRate: 0, frameCount: 0,
                                          boundaryFrames: [1], snapOffsetFrames: [0],
                                          residualAmplitude: [0])
        #expect(throws: ProjectError.self) {
            try SliceToSamplerPlan.compute(
                clip: Self.clip(), geometry: bogus, strengths: [],
                settings: SliceToSamplerSettings(), tempoMap: Self.tempo)
        }
    }

    // MARK: - Snap-window clamp

    @Test("the snap window is never more than half the minimum slice, and says so")
    func snapWindowClamp() throws {
        let wide = SliceToSamplerSettings(minSliceSeconds: 0.004, snapWindowSeconds: 0.020)
        #expect(abs(wide.effectiveSnapWindowSeconds - 0.002) < 1e-12)
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [],
            settings: wide, tempoMap: Self.tempo)
        #expect(plan.warnings.contains { $0.contains("snapWindowMs was reduced") })
        // At the defaults (3 ms vs 25 ms) the clamp never bites and stays silent.
        let normal = SliceToSamplerSettings()
        #expect(normal.effectiveSnapWindowSeconds == normal.snapWindowSeconds)
        let quiet = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [],
            settings: normal, tempoMap: Self.tempo)
        #expect(!quiet.warnings.contains { $0.contains("snapWindowMs was reduced") })
    }

    // MARK: - Report

    @Test("sourceSeconds is POST-snap, so frames, seconds and beats agree")
    func reportIsPostSnap() throws {
        // Boundaries snapped 14 frames EARLY: the candidate was 22 064.
        let moved = SliceBoundaryGeometry(
            sampleRate: Self.rate, frameCount: 88_200, boundaryFrames: [22_050],
            snapOffsetFrames: [-14], residualAmplitude: [0.0007])
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: moved, strengths: [0.82],
            settings: SliceToSamplerSettings(), tempoMap: Self.tempo)
        let slice = try #require(plan.slices.first)
        #expect(slice.startFrame == 22_050)
        #expect(abs(slice.sourceSeconds - 22_050.0 / Self.rate) < 1e-12)
        #expect(abs(slice.beat - slice.sourceSeconds / 0.5) < 1e-9)
        #expect(slice.snapOffsetFrames == -14)
        #expect(slice.residualAmplitude == 0.0007)
        // The reconstruction note fires at the SAME beat the report claims.
        #expect(abs(plan.notes[0].startBeat - slice.beat) < 1e-9)
    }
}
