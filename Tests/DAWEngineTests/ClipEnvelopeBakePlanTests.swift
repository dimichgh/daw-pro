import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m13-h2 — piecewise envelope bake plan. Pins the OBSERVABLES of the perf
/// fix (plan shape: which spans bake vs stream), never timing: a mostly-unity
/// envelope must NOT produce a full-region bake anymore, streamed spans must
/// be PROVABLY unity under the exact frame→beat mapping `applyEnvelope` uses,
/// and the rendered bytes must stay identical to the m13-e whole-region bake
/// (streamed pass-through == the old `× 1.0` multiply, bit for bit).
@MainActor
@Suite("Envelope bake plan (m13-h2)", .serialized)
struct ClipEnvelopeBakePlanTests {

    /// 24_000 frames/beat: 120 BPM at 48 kHz — the constant used throughout.
    private let map = TempoMap(constantBPM: 120)
    private let rate = 48_000.0

    private func plan(_ clip: Clip, segStart: Int64, count: Int64,
                      tempoMap: TempoMap? = nil) -> [ClipFadeBake.EnvelopedPiece] {
        ClipFadeBake.envelopedPiecePlan(
            clip: clip, tempoMap: tempoMap ?? map, fileRate: rate,
            segmentStart: segStart, segmentFrameCount: count)
    }

    private func longClip(envelope: [ClipGainPoint],
                          fadeIn: Double = 0, fadeOut: Double = 0) -> Clip {
        Clip(name: "long", startBeat: 0, lengthBeats: 1_200,
             audioFileURL: URL(fileURLWithPath: "/dev/null"),
             fadeInBeats: fadeIn, fadeOutBeats: fadeOut, gainEnvelope: envelope)
    }

    /// Partition sanity shared by every case: contiguous ascending pieces,
    /// no zero-length piece, exact frame-count sum, strict bake/stream
    /// alternation, and (in multi-piece plans) no streamed sliver below the
    /// documented floor.
    private func assertPartition(_ pieces: [ClipFadeBake.EnvelopedPiece],
                                 segStart: Int64, count: Int64) {
        guard count > 0 else {
            #expect(pieces.isEmpty)
            return
        }
        #expect(!pieces.isEmpty)
        var cursor = segStart
        var previousBake: Bool?
        for piece in pieces {
            #expect(piece.start == cursor, "pieces must be contiguous")
            #expect(piece.frameCount > 0, "no zero-length pieces")
            #expect(piece.bake != previousBake, "pieces must alternate bake/stream")
            if !piece.bake && pieces.count > 1 {
                #expect(piece.frameCount >= ClipFadeBake.minStreamRunFrames,
                        "streamed pieces below the floor must fold into a bake")
            }
            cursor += piece.frameCount
            previousBake = piece.bake
        }
        #expect(cursor == segStart + count, "pieces must sum to the region exactly")
    }

    // MARK: - Plan shape (the perf observable)

    @Test("mostly-unity envelope: ONLY the shaped span bakes — never the full region")
    func mostlyUnityBakesOnlyTheShapedSpan() {
        // 1200-beat (10-min) clip, dip across beats 4→8; everything else unity.
        let clip = longClip(envelope: [ClipGainPoint(beat: 4, gainDb: 0),
                                       ClipGainPoint(beat: 6, gainDb: -6),
                                       ClipGainPoint(beat: 8, gainDb: 0)])
        let region: Int64 = 28_800_000
        let pieces = plan(clip, segStart: 0, count: region)
        assertPartition(pieces, segStart: 0, count: region)
        #expect(pieces.count == 3)
        #expect(pieces.map(\.bake) == [false, true, false])
        // The dip is beats 4..8 = 96_000 frames; the baked piece may carry
        // only the documented ±guard frames beyond it — 28.8 M would be the
        // old full-region bake (the m13-e badness this item kills).
        let bakedFrames = pieces.filter(\.bake).map(\.frameCount).reduce(0, +)
        #expect(bakedFrames >= 96_000)
        #expect(bakedFrames <= 96_000 + 8,
                "baked span must hug the shaped beats, not the region")
        // Buffer-bytes observable: ≤ ~0.74 MB baked (stereo Float32) vs the
        // old ~230 MB whole region.
        #expect(bakedFrames * 8 < 1_000_000)
    }

    @Test("flat 0 dB envelope: one streamed piece, zero baked frames")
    func unityFlatStreamsEverything() {
        let clip = longClip(envelope: [ClipGainPoint(beat: 0, gainDb: 0),
                                       ClipGainPoint(beat: 1_200, gainDb: 0)])
        let region: Int64 = 28_800_000
        let pieces = plan(clip, segStart: 0, count: region)
        assertPartition(pieces, segStart: 0, count: region)
        #expect(pieces == [ClipFadeBake.EnvelopedPiece(
            start: 0, frameCount: region, bake: false)])
    }

    @Test("full non-unity envelope: the whole region still bakes (one piece)")
    func fullNonUnityBakesWholeRegion() {
        let clip = longClip(envelope: [ClipGainPoint(beat: 0, gainDb: -6),
                                       ClipGainPoint(beat: 1_200, gainDb: -6)])
        let region: Int64 = 28_800_000
        let pieces = plan(clip, segStart: 0, count: region)
        assertPartition(pieces, segStart: 0, count: region)
        #expect(pieces == [ClipFadeBake.EnvelopedPiece(
            start: 0, frameCount: region, bake: true)])
    }

    @Test("fades fold into baked spans: head/tail bake, unity bulk streams")
    func fadesFoldIntoBakedSpans() {
        // 1-beat fades + a mid-clip dip: expect bake / stream / bake / stream
        // / bake — five pieces, three shaped spans.
        let clip = longClip(envelope: [ClipGainPoint(beat: 600, gainDb: 0),
                                       ClipGainPoint(beat: 601, gainDb: -9),
                                       ClipGainPoint(beat: 602, gainDb: 0)],
                            fadeIn: 1, fadeOut: 1)
        let region: Int64 = 28_800_000
        let pieces = plan(clip, segStart: 0, count: region)
        assertPartition(pieces, segStart: 0, count: region)
        #expect(pieces.map(\.bake) == [true, false, true, false, true])
        // Fade-in bake hugs beat 1 (24_000 frames + guard); fade-out bake
        // starts at beat 1199 (28_776_000 − guard) and runs to the end.
        #expect(pieces[0].frameCount <= 24_000 + 4)
        #expect(pieces[4].start >= 28_776_000 - 4)
    }

    @Test("unity gaps shorter than the stream floor fold into one baked span")
    func sliverGapsFoldIntoTheBake() {
        // Two dips separated by 0.2 unity beats = 4_800 frames < the 8_192
        // floor → ONE merged baked span, no streamed sliver.
        let folded = longClip(envelope: [
            ClipGainPoint(beat: 4.0, gainDb: 0), ClipGainPoint(beat: 4.1, gainDb: -6),
            ClipGainPoint(beat: 4.2, gainDb: 0), ClipGainPoint(beat: 4.4, gainDb: 0),
            ClipGainPoint(beat: 4.5, gainDb: -6), ClipGainPoint(beat: 4.6, gainDb: 0),
        ])
        let region: Int64 = 28_800_000
        let foldedPieces = plan(folded, segStart: 0, count: region)
        assertPartition(foldedPieces, segStart: 0, count: region)
        #expect(foldedPieces.map(\.bake) == [false, true, false])

        // Same dips 0.5 unity beats apart = 12_000 frames ≥ the floor → the
        // gap streams, two distinct baked spans.
        let split = longClip(envelope: [
            ClipGainPoint(beat: 4.0, gainDb: 0), ClipGainPoint(beat: 4.1, gainDb: -6),
            ClipGainPoint(beat: 4.2, gainDb: 0), ClipGainPoint(beat: 4.7, gainDb: 0),
            ClipGainPoint(beat: 4.8, gainDb: -6), ClipGainPoint(beat: 4.9, gainDb: 0),
        ])
        let splitPieces = plan(split, segStart: 0, count: region)
        assertPartition(splitPieces, segStart: 0, count: region)
        #expect(splitPieces.map(\.bake) == [false, true, false, true, false])
    }

    @Test("partition invariant across playhead/truncation window shapes")
    func partitionInvariantAcrossWindows() {
        let clip = longClip(envelope: [ClipGainPoint(beat: 4, gainDb: 0),
                                       ClipGainPoint(beat: 6, gainDb: -6),
                                       ClipGainPoint(beat: 8, gainDb: 0)],
                            fadeIn: 0.5)
        let cases: [(Int64, Int64)] = [
            (0, 28_800_000),          // full region
            (100_000, 28_700_000),    // playhead inside the shaped span
            (250_000, 28_550_000),    // playhead past the shaped span
            (0, 150_000),             // truncated inside the shaped span
            (100_000, 10_000),        // tiny window entirely inside the bake
            (1_000_000, 4_096),       // tiny window entirely inside unity
            (28_800_000, 0),          // empty region
        ]
        for (segStart, count) in cases {
            assertPartition(plan(clip, segStart: segStart, count: count),
                            segStart: segStart, count: count)
        }
        // The two tiny windows resolve to a single piece of the right kind.
        #expect(plan(clip, segStart: 100_000, count: 10_000)
            == [ClipFadeBake.EnvelopedPiece(start: 100_000, frameCount: 10_000, bake: true)])
        #expect(plan(clip, segStart: 1_000_000, count: 4_096)
            == [ClipFadeBake.EnvelopedPiece(start: 1_000_000, frameCount: 4_096, bake: false)])
    }

    // MARK: - The streaming correctness law

    @Test("every streamed frame is EXACTLY unity under applyEnvelope's own frame→beat mapping")
    func streamedFramesAreExactlyUnity() throws {
        // Non-round breakpoint beats, fades, a mid-region start, and a
        // multi-segment tempo map — the streaming rule must hold bit-exactly
        // (== 1.0) in all of them, because streamed frames bypass the multiply.
        let twoSegment = try TempoMap(segments: [
            TempoMap.Segment(startBeat: 0, bpm: 120),
            TempoMap.Segment(startBeat: 5, bpm: 90),
        ])
        let scenarios: [(Clip, TempoMap, Int64, Int64)] = [
            (longClip(envelope: [ClipGainPoint(beat: 1.37, gainDb: 0),
                                 ClipGainPoint(beat: 2.09, gainDb: -3.3),
                                 ClipGainPoint(beat: 3.71, gainDb: 0)]),
             map, 0, 28_800_000),
            (longClip(envelope: [ClipGainPoint(beat: 7, gainDb: -2),
                                 ClipGainPoint(beat: 9, gainDb: 0)],
                      fadeIn: 0.25, fadeOut: 2),
             map, 60_000, 28_740_000),
            (longClip(envelope: [ClipGainPoint(beat: 4, gainDb: 0),
                                 ClipGainPoint(beat: 6, gainDb: -6),
                                 ClipGainPoint(beat: 8, gainDb: 0)]),
             twoSegment, 0, 20_000_000),
        ]
        for (clip, tempoMap, segStart, count) in scenarios {
            var shape = clip
            shape.gainDb = 0
            let constantTempo = tempoMap.isConstant(
                from: clip.startBeat, to: clip.startBeat + clip.lengthBeats)
            let perBeat = tempoMap.framesPerBeat(atBeat: clip.startBeat, sampleRate: rate)
            let pieces = plan(clip, segStart: segStart, count: count, tempoMap: tempoMap)
            assertPartition(pieces, segStart: segStart, count: count)
            #expect(pieces.contains { !$0.bake }, "scenario must exercise streaming")
            for piece in pieces where !piece.bake {
                // Edge frames plus interior probes — beat(frame) computed
                // EXACTLY the way applyEnvelope computes it.
                let probes = [piece.start, piece.start + piece.frameCount / 2,
                              piece.start + piece.frameCount - 1]
                for frame in probes {
                    let beat = constantTempo
                        ? Double(frame) / perBeat
                        : tempoMap.beat(from: clip.startBeat,
                                        elapsedSeconds: Double(frame) / rate) - clip.startBeat
                    #expect(shape.envelopeGain(atBeat: beat) == 1.0,
                            "streamed frame \(frame) must be exactly unity")
                }
            }
        }
    }

    // MARK: - Rendered bytes (engine path)

    private func cosineFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-bakeplan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cos.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48_000, channels: 2,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000),
              let ch = buffer.floatChannelData else {
            throw EngineError.renderFailed("fixture allocation failed")
        }
        for i in 0..<192_000 {
            let v = Float(0.5) * Float(cos(2.0 * Double.pi * 1_000.0 * Double(i) / 48_000.0))
            ch[0][i] = v
            ch[1][i] = v
        }
        buffer.frameLength = 192_000
        try file.write(from: buffer)
        return url
    }

    @Test("streamed spans render BIT-IDENTICAL to the dry clip; baked spans match the evaluator")
    func streamedSpansPassThroughBitExact() throws {
        let url = try cosineFixture()
        // 8-beat clip, dip across beats 2→4 → baked span ≈ frames
        // [48_000 − g, 96_000 + g]; everything else streams.
        let dry = Clip(name: "c", startBeat: 0, lengthBeats: 8, audioFileURL: url)
        var enveloped = dry
        enveloped.gainEnvelope = [ClipGainPoint(beat: 2, gainDb: 0),
                                  ClipGainPoint(beat: 3, gainDb: -6),
                                  ClipGainPoint(beat: 4, gainDb: 0)]
        let renderer = OfflineRenderer()
        let a = try renderer.render(
            tracks: [Track(name: "T", kind: .audio, clips: [dry])],
            tempoMap: map, fromBeat: 0, durationSeconds: 4.0).channelData[0]
        let b = try OfflineRenderer().render(
            tracks: [Track(name: "T", kind: .audio, clips: [enveloped])],
            tempoMap: map, fromBeat: 0, durationSeconds: 4.0).channelData[0]
        // Outside the shaped span (clear of the ±guard): bit-exact pass-through.
        var headDiffs = 0
        for frame in 0..<47_990 where a[frame] != b[frame] { headDiffs += 1 }
        var tailDiffs = 0
        for frame in 96_010..<192_000 where a[frame] != b[frame] { tailDiffs += 1 }
        #expect(headDiffs == 0, "unity head must stream bit-exact")
        #expect(tailDiffs == 0, "unity tail must stream bit-exact")
        // Everywhere (baked span included): the m13-e analytic law, unchanged.
        var worst: Float = 0
        for frame in 0..<192_000 {
            let expected = a[frame] * Float(enveloped.envelopeGain(atBeat: Double(frame) / 24_000.0))
            worst = max(worst, abs(b[frame] - expected))
        }
        print("[measured] piecewise enveloped render worst error vs dry×evaluator: \(worst)")
        #expect(worst <= 1e-6)
    }

    @Test("seek into the shaped span: first piece bakes the analytic partial ramp")
    func midSeekStartsInsideTheBake() throws {
        let url = try cosineFixture()
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 8, audioFileURL: url,
                        gainEnvelope: [ClipGainPoint(beat: 2, gainDb: 0),
                                       ClipGainPoint(beat: 3, gainDb: -6),
                                       ClipGainPoint(beat: 4, gainDb: 0)])
        // Playhead at beat 2.5 — mid-dip. Rendered frame f ≡ clip beat 2.5 + f/24_000.
        let rendered = try OfflineRenderer().render(
            tracks: [Track(name: "T", kind: .audio, clips: [clip])],
            tempoMap: map, fromBeat: 2.5, durationSeconds: 2.0).channelData[0]
        let source = try TestSignals.readFile(url)[0]
        var worst: Float = 0
        for frame in 0..<96_000 {
            let clipBeat = 2.5 + Double(frame) / 24_000.0
            let expected = source[60_000 + frame] * Float(clip.envelopeGain(atBeat: clipBeat))
            worst = max(worst, abs(rendered[frame] - expected))
        }
        print("[measured] mid-seek piecewise worst error: \(worst)")
        #expect(worst <= 1e-6)
    }

    @Test("repeat scheduleAll (two renders) is deterministic with a piecewise plan")
    func repeatScheduleDeterministic() throws {
        let url = try cosineFixture()
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 8, audioFileURL: url,
                        gainEnvelope: [ClipGainPoint(beat: 2, gainDb: 0),
                                       ClipGainPoint(beat: 3, gainDb: -6),
                                       ClipGainPoint(beat: 4, gainDb: 0)])
        let tracks = [Track(name: "T", kind: .audio, clips: [clip])]
        let first = try OfflineRenderer().render(tracks: tracks, tempoMap: map,
                                                 fromBeat: 0, durationSeconds: 4.0)
        let second = try OfflineRenderer().render(tracks: tracks, tempoMap: map,
                                                  fromBeat: 0, durationSeconds: 4.0)
        #expect(first.channelData == second.channelData)
    }
}
