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

    // MARK: - Equal pieces and the grid cover the WHOLE window (m33-d)
    //
    // ⛔ MEASURED ON STAGING 2026-09-24: a 1.93 s loop chopped into "Equal
    // pieces = 8" made 7 pads, plus the notice "0.241 s of audio before the
    // first slice point was discarded (pad 1 starts at the first onset…)".
    // 0.241 × 8 = 1.93 — the discarded "lead-in" was exactly ONE EQUAL PIECE.
    // `SliceBoundaries.equalDivisions` returns only the N−1 INTERIOR cuts (its
    // correct contract: it is shared with `clip.quantizeAudio`, which emits the
    // head and tail itself), and the planner treated the first piece as detector
    // pre-roll. `gridDivisions` skips the line AT the window start, so an
    // on-grid clip lost its first cell the same way.
    //
    // These compose the REAL boundary generators with the planner, the way
    // `ProjectStore.sliceClipToSampler` does, so they measure the pads a person
    // gets — not what either half says about itself.

    /// Frames as the engine seam reports them: `round(seconds × rate)`.
    static func frames(_ seconds: [Double], rate: Double = SliceToSamplerPlanTests.rate) -> [Int] {
        seconds.map { Int(($0 * rate).rounded()) }
    }

    /// Frame lengths of the pads, with a nil end resolved to `fileEnd`.
    static func spans(_ zones: [SamplerZone], fileEnd: Int = 88_200) -> [Int] {
        zones.map { ($0.endFrame ?? fileEnd) - ($0.startFrame ?? 0) }
    }

    @Test("⭐ Equal pieces N makes EXACTLY N pads over the whole window, pad 1 at its start",
          arguments: [2, 8, 9])
    func equalPiecesMakeExactlyN(n: Int) throws {
        let clip = Self.clip()                           // window [0, 2) s = the whole file
        let settings = SliceToSamplerSettings(mode: .divisions, divisions: n)
        let cuts = SliceBoundaries.equalDivisions(
            windowStart: 0, windowEnd: 2, divisions: n,
            minSliceSeconds: settings.minSliceSeconds)
        try SliceToSamplerPlan.validateSliceCount(
            boundaryCount: cuts.count, settings: settings, clipId: clip.id)
        let plan = try SliceToSamplerPlan.compute(
            clip: clip, geometry: Self.geometry(frames: Self.frames(cuts)),
            strengths: [], settings: settings, tempoMap: Self.tempo)

        #expect(plan.zones.count == n)
        #expect(plan.slices.count == n)
        // Pad 1 starts AT the window start, and the last pad reaches its end.
        #expect(plan.zones.first?.startFrame == 0)
        #expect(plan.zones.last?.endFrame == nil)
        // The WHOLE window, in EQUAL pieces: 88 200 / n frames each (±1 frame
        // of rounding), summing to every frame — nothing silently dropped.
        let spans = Self.spans(plan.zones)
        #expect(spans.reduce(0, +) == 88_200, "spans \(spans)")
        let equal = 88_200.0 / Double(n)
        #expect(spans.allSatisfy { abs(Double($0) - equal) <= 1 }, "spans \(spans)")
        // The reconstruction replays the whole window from the clip's first beat.
        #expect(plan.notes.count == n)
        #expect(abs((plan.notes.first?.startBeat ?? -1) - 0) < 1e-9)
        // No detector ran, so nothing may be reported as discarded pre-roll.
        #expect(!plan.warnings.contains { $0.contains("discarded") }, "\(plan.warnings)")
    }

    @Test("⭐ Equal pieces on a TRIMMED window: pad 1 starts where the window does, not at 0",
          arguments: [2, 8, 9])
    func equalPiecesOnATrimmedWindow(n: Int) throws {
        // Window [0.5, 1.5) s of a 2 s file: it starts late AND stops early.
        let clip = Self.clip(length: 2, offset: 0.5)
        let settings = SliceToSamplerSettings(mode: .divisions, divisions: n)
        let cuts = SliceBoundaries.equalDivisions(
            windowStart: 0.5, windowEnd: 1.5, divisions: n,
            minSliceSeconds: settings.minSliceSeconds)
        let plan = try SliceToSamplerPlan.compute(
            clip: clip, geometry: Self.geometry(frames: Self.frames(cuts)),
            strengths: [], settings: settings, tempoMap: Self.tempo)

        #expect(plan.zones.count == n)
        #expect(plan.zones.first?.startFrame == 22_050)
        #expect(abs((plan.slices.first?.sourceSeconds ?? -1) - 0.5) < 1e-9)
        #expect(plan.zones.last?.endFrame == 66_150)
        let spans = Self.spans(plan.zones)
        #expect(spans.reduce(0, +) == 44_100, "spans \(spans)")
        let equal = 44_100.0 / Double(n)
        #expect(spans.allSatisfy { abs(Double($0) - equal) <= 1 }, "spans \(spans)")
    }

    @Test("⭐ On the beat: every grid cell is a pad — the first cell is not a 'lead-in'")
    func gridCoversEveryCell() throws {
        // (clip, gridBeats, pads expected, pad 1's start frame)
        let cases: [(Clip, Double, Int, Int)] = [
            // On-grid clip, quarter notes: [0, 2) s = 4 beats → 4 pads.
            (Self.clip(), 1, 4, 0),
            // Eighth notes → 8 pads.
            (Self.clip(), 0.5, 8, 0),
            // TRIMMED: the clip sits at beat 0 but its window starts 0.5 s into
            // the file → cells [0.5, 1.0) [1.0, 1.5) [1.5, 2.0) s → 3 pads.
            (Self.clip(length: 3, offset: 0.5), 1, 3, 22_050),
            // OFF-grid clip at beat 0.5: the half-beat before the first line is
            // a real (pickup) piece of the window, and the partial LAST cell was
            // always kept — so the first must be too. 4 lines → 5 pads.
            (Self.clip(startBeat: 0.5), 1, 5, 0),
        ]
        for (clip, gridBeats, expected, firstFrame) in cases {
            let settings = SliceToSamplerSettings(mode: .grid, gridBeats: gridBeats)
            let start = clip.startOffsetSeconds
            let end = start + clip.sourceWindowSeconds(tempoMap: Self.tempo)
            let cuts = SliceBoundaries.gridDivisions(
                clipStartBeat: clip.startBeat, windowStart: start, windowEnd: end,
                gridBeats: gridBeats, tempoMap: Self.tempo,
                minSliceSeconds: settings.minSliceSeconds)
            let plan = try SliceToSamplerPlan.compute(
                clip: clip, geometry: Self.geometry(frames: Self.frames(cuts)),
                strengths: [], settings: settings, tempoMap: Self.tempo)
            let label = "clip@\(clip.startBeat) offset \(start) grid \(gridBeats)"
            #expect(plan.zones.count == expected, "\(label)")
            #expect(plan.zones.first?.startFrame == firstFrame, "\(label)")
            #expect(Self.spans(plan.zones).reduce(0, +)
                    == Int(((end - start) * Self.rate).rounded()), "\(label)")
            #expect(!plan.warnings.contains { $0.contains("discarded") }, "\(label)")
        }
    }

    @Test("⭐ the ceilings count the pads a divisions/grid chop REALLY makes — N, not N−1")
    func nonDetectorCountRuleMatchesThePads() throws {
        let clipId = UUID()
        // 8 equal pieces = 7 interior cuts = 8 PADS, so a ceiling of 7 must REFUSE…
        #expect(throws: ProjectError.self) {
            try SliceToSamplerPlan.validateSliceCount(
                boundaryCount: 7,
                settings: SliceToSamplerSettings(mode: .divisions, divisions: 8, maxSlices: 7),
                clipId: clipId)
        }
        // …and a ceiling of 8 must pass (the positive control).
        try SliceToSamplerPlan.validateSliceCount(
            boundaryCount: 7,
            settings: SliceToSamplerSettings(mode: .divisions, divisions: 8, maxSlices: 8),
            clipId: clipId)
        // The MIDI-127 ceiling counts the same pads: 8 pads from note 120 end
        // on 127 (legal); from 121 they would need 128.
        try SliceToSamplerPlan.validateSliceCount(
            boundaryCount: 7,
            settings: SliceToSamplerSettings(mode: .divisions, divisions: 8, baseNote: 120),
            clipId: clipId)
        #expect(throws: ProjectError.self) {
            try SliceToSamplerPlan.validateSliceCount(
                boundaryCount: 7,
                settings: SliceToSamplerSettings(mode: .divisions, divisions: 8, baseNote: 121),
                clipId: clipId)
        }
        // Grid counts the same way: 3 interior lines = 4 cells = 4 pads.
        #expect(throws: ProjectError.self) {
            try SliceToSamplerPlan.validateSliceCount(
                boundaryCount: 3,
                settings: SliceToSamplerSettings(mode: .grid, gridBeats: 1, maxSlices: 3),
                clipId: clipId)
        }
    }

    /// ⭐ INVARIANT, green before AND after m33-d: an explicit `includeHead: true`
    /// with `divisions` has always meant N pads (dogfood 2026-08-29 session 3
    /// measured `divisions: 8, includeHead: true` → 8). It must keep meaning N —
    /// never a second head, N+1.
    @Test("⭐ includeHead: true with Equal pieces still makes N pads, never N+1")
    func includeHeadDoesNotDoubleCountInDivisions() throws {
        let settings = SliceToSamplerSettings(mode: .divisions, divisions: 8, includeHead: true)
        let cuts = SliceBoundaries.equalDivisions(
            windowStart: 0, windowEnd: 2, divisions: 8,
            minSliceSeconds: settings.minSliceSeconds)
        try SliceToSamplerPlan.validateSliceCount(
            boundaryCount: cuts.count, settings: settings, clipId: UUID())
        let plan = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(frames: Self.frames(cuts)),
            strengths: [], settings: settings, tempoMap: Self.tempo)
        #expect(plan.zones.count == 8)
        #expect(plan.zones.first?.startFrame == 0)
        #expect(Self.spans(plan.zones).reduce(0, +) == 88_200)
    }

    /// ⛔ INVARIANT, green before AND after m33-d: "Every hit" (transients) keeps
    /// its SHIPPED head rule exactly. The head there IS usually pre-roll, so it is
    /// dropped by default, reported, and warned about in the wire's own words.
    @Test("⛔ INVARIANT: 'Every hit' keeps its shipped head rule, byte for byte")
    func transientHeadRuleIsUnchanged() throws {
        // Default: the head is dropped; pad 1 is the first onset.
        let dropped = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [0.9, 0.5, 0.7],
            settings: SliceToSamplerSettings(mode: .transients), tempoMap: Self.tempo)
        #expect(dropped.zones.map(\.startFrame) == [22_050, 44_100, 66_150])
        #expect(dropped.slices.map(\.strength) == [0.9, 0.5, 0.7])
        #expect(abs(dropped.headSeconds - 0.5) < 1e-12)
        // THE WIRE SENTENCE, byte for byte — agents read it and it names the
        // parameter precisely.
        #expect(dropped.warnings == [
            "0.5 s of audio before the first slice point was discarded (pad 1 starts at "
            + "the first onset, like an MPC or Recycle). Pass includeHead: true to keep it "
            + "as pad 1 — worth doing if the detector missed the downbeat",
        ])
        #expect(abs((dropped.notes.first?.startBeat ?? -1) - 1.0) < 1e-9)

        // includeHead: true — the head becomes pad 1 and nothing is warned.
        let kept = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(), strengths: [0.9, 0.5, 0.7],
            settings: SliceToSamplerSettings(mode: .transients, includeHead: true),
            tempoMap: Self.tempo)
        #expect(kept.zones.map(\.startFrame) == [0, 22_050, 44_100, 66_150])
        #expect(kept.slices.map(\.strength) == [nil, 0.9, 0.5, 0.7])
        #expect(kept.warnings.isEmpty)
        #expect(abs(kept.headSeconds - 0.5) < 1e-12)

        // A head of ≤ 2 × minSlice stays silent (ordinary pre-roll).
        let tight = try SliceToSamplerPlan.compute(
            clip: Self.clip(), geometry: Self.geometry(frames: [2_205, 44_100, 66_150]),
            strengths: [], settings: SliceToSamplerSettings(mode: .transients),
            tempoMap: Self.tempo)
        #expect(tight.warnings.isEmpty)

        // The count rule agrees with the pads: 3 onsets = 3 pads, 4 with the head.
        try SliceToSamplerPlan.validateSliceCount(
            boundaryCount: 3, settings: SliceToSamplerSettings(maxSlices: 3), clipId: UUID())
        #expect(throws: ProjectError.self) {
            try SliceToSamplerPlan.validateSliceCount(
                boundaryCount: 3,
                settings: SliceToSamplerSettings(maxSlices: 3, includeHead: true),
                clipId: UUID())
        }
        // No onsets and no head is still a refusal, never an empty chop.
        #expect(throws: ProjectError.self) {
            try SliceToSamplerPlan.validateSliceCount(
                boundaryCount: 0, settings: SliceToSamplerSettings(), clipId: UUID())
        }
    }
}
