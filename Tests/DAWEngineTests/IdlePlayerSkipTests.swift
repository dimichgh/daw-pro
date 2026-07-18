import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m19-f R1 gates — idle-player skip
// (docs/research/2026-07-16-m19f-birth-latency-riders-design.md §2.4/§2.5):
//
// A ClipNode is schedule-empty iff its player received ZERO enqueues since
// its last stop (the ledger flag, never a model-level re-derivation).
// `startAllPlayers`/`prepareAllPlayers`/`stopAllPlayers` skip flag-false
// nodes — no ~6 ms `play(at:)` handshake, no ~1 ms `stop()`, no
// `clip-unplayable` false alarm for empty-schedule disconnected clips.
// Every path that later gives a player a schedule routes through a full
// re-anchored restart (there is no incremental join path in the tree), so
// the skip can never strand content.
//
//  · T1 — idle skip: rolling past clip A leaves A's player un-started
//    (flag false, not playing) while B starts normally.
//  · T2 — THE ROADMAP GATE's alignment case: a mid-play clip add onto a
//    previously-idle strip rides the reconcile → restart seam and lands
//    sample-aligned — exact-== onset assertions (M1 conventions), with a
//    rolling clip's continuation pinning the shared re-anchor.
//  · T3 — flag lifecycle across rolls: an idle roll (skipped by start AND
//    by stop) leaves zero stale state — the next active roll is bit-exact.
//  · T4 — loop-window inclusion: a clip behind the roll start but inside
//    the loop window is NOT skipped (flag true pre-start via the initial
//    topUpLoopCycles) and sounds in cycle 1 (GaplessLoopTransportTests
//    idiom).
//  · T5 — failure-path stop asymmetry: an isPlayable-skipped node keeps
//    flag=true and the NEXT stop still clears its queue — a fresh roll's
//    schedule is never duplicated (the reschedule primitive's contract).
//  · T6 — offline byte-identity: a bounce starting past clip A equals the
//    analytic expectation exactly (a skipped player renders the same
//    silence a started-empty player did — §2.4-7, no offline delta).
//
// All offline: manual-rendering AVAudioEngine + the REAL PlaybackGraph
// (reconcile → scheduleAll → prepare → start), ramp signals unique per
// frame at Float precision so every assertion is bit-exact `==`.

private let skipRate = 48_000.0
private let skipQuantum = 512
/// 120 BPM: one beat = 0.5 s = 24_000 frames at 48 kHz.
private let beatFrames = 24_000

private func rampC(_ frame: Int) -> Float { 0.25 + Float(frame) * 1e-6 }
private func rampD(_ frame: Int) -> Float { -0.5 - Float(frame) * 1e-6 }

/// Stereo Float32 .caf carrying `value(frame)` on both channels.
@MainActor
private func writeSkipRampFile(
    contentFrames: Int, name: String, value: @escaping (Int) -> Float
) throws -> URL {
    let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: skipRate, channels: 2))
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(contentFrames)))
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<contentFrames {
        for channel in 0..<2 {
            channels[channel][frame] = value(frame)
        }
    }
    buffer.frameLength = AVAudioFrameCount(contentFrames)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("m19f-\(name)-\(UUID().uuidString).caf")
    // AVAudioFile flushes its header on deinit — writer dies before readers.
    try autoreleasepool {
        let writer = try AVAudioFile(forWriting: url, settings: format.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
    }
    return url
}

/// Frames in `range` (both channels) not bit-equal to
/// `value(frame - range.lowerBound)`.
private func skipMismatches(_ channels: [[Float]], range: Range<Int>,
                            against value: (Int) -> Float) -> (count: Int, first: String) {
    var count = 0
    var first = "none"
    for frame in range {
        let expected = value(frame - range.lowerBound)
        for channel in 0..<2 where channels[channel][frame] != expected {
            if count == 0 {
                first = "frame \(frame) ch \(channel): "
                    + "got \(channels[channel][frame]), want \(expected)"
            }
            count += 1
        }
    }
    return (count, first)
}

// MARK: - Offline rig driving the REAL graph through the restart seam

@MainActor
private final class SkipRig {
    let engine: AVAudioEngine
    let graph: PlaybackGraph
    private let buffer: AVAudioPCMBuffer

    init(tracks: [Track]) throws {
        engine = AVAudioEngine()
        graph = PlaybackGraph(engine: engine)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: skipRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        #expect(graph.reconcile(tracks: tracks))
        graph.applyParameters(tracks: tracks)
        try engine.start()
        graph.applyParameters(tracks: tracks)
        buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
    }

    /// One start/restart in the production shape: schedule → (loop top-up)
    /// → prepare → start. Offline nil anchor: player time 0 ≡ the next
    /// pulled sample (the GaplessLoopEditFallbackTests restart idiom).
    func roll(fromBeat: Double, tempoMap: TempoMap,
              loop: PlaybackGraph.LoopWindow? = nil) {
        graph.scheduleAll(fromBeat: fromBeat, tempoMap: tempoMap, loop: loop)
        if loop != nil {
            graph.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)
        }
        graph.prepareAllPlayers(withFrameCount: 8_192)
        graph.startAllPlayers(at: nil)
    }

    /// Pulls `frames` and returns them (both channels) — a fresh window per
    /// call, so restart-relative frame math stays trivial.
    func pull(frames: Int) throws -> [[Float]] {
        var output: [[Float]] = [[], []]
        while output[0].count < frames {
            let request = AVAudioFrameCount(min(frames - output[0].count, skipQuantum))
            let status = try engine.renderOffline(request, to: buffer)
            try #require(status == .success)
            let source = try #require(buffer.floatChannelData)
            for channel in 0..<2 {
                output[channel].append(contentsOf: UnsafeBufferPointer(
                    start: source[channel], count: Int(buffer.frameLength)))
            }
        }
        return output
    }
}

// MARK: - The gates

@MainActor
@Suite("Idle-player skip (m19-f R1)", .serialized)
struct IdlePlayerSkipTests {

    /// T1 — the skip itself: roll from a beat past clip A's end (clip B
    /// ahead). A's node: flag false, player never started. B's: flag true,
    /// playing. The ledger IS the enqueue history — no heuristic.
    @Test("T1: roll past clip A — A skipped (flag false, not playing), B started")
    func idleSkip() throws {
        let aURL = try writeSkipRampFile(contentFrames: 2 * beatFrames, name: "t1a", value: rampC)
        let bURL = try writeSkipRampFile(contentFrames: beatFrames, name: "t1b", value: rampD)
        defer {
            try? FileManager.default.removeItem(at: aURL)
            try? FileManager.default.removeItem(at: bURL)
        }
        let clipA = Clip(name: "A", startBeat: 0, lengthBeats: 2, audioFileURL: aURL)
        let clipB = Clip(name: "B", startBeat: 8, lengthBeats: 1, audioFileURL: bURL)
        let rig = try SkipRig(tracks: [
            Track(name: "TA", kind: .audio, clips: [clipA]),
            Track(name: "TB", kind: .audio, clips: [clipB]),
        ])

        rig.roll(fromBeat: 4, tempoMap: TempoMap(constantBPM: 120))

        let aFlag = rig.graph.clipHasPendingSchedule(clipID: clipA.id)
        let bFlag = rig.graph.clipHasPendingSchedule(clipID: clipB.id)
        let aPlaying = rig.graph.clipPlayerForTesting(clipID: clipA.id)?.isPlaying
        let bPlaying = rig.graph.clipPlayerForTesting(clipID: clipB.id)?.isPlaying
        print("[measured] T1: A flag \(String(describing: aFlag)) playing "
              + "\(String(describing: aPlaying)); B flag \(String(describing: bFlag)) "
              + "playing \(String(describing: bPlaying))")
        #expect(aFlag == false)
        #expect(aPlaying == false)
        #expect(bFlag == true)
        #expect(bPlaying == true)
        rig.engine.stop()
    }

    /// T2 — THE m19-f GATE's alignment case: mid-play clip add onto a
    /// previously-idle strip. Roll 1 from beat 4: A (beats [0,2)) idle-
    /// skipped, B (beats [4,5.5)) rolling. Half a beat in, clip C lands on
    /// A's track at beat 6 through the reconcile → restart seam (the ONLY
    /// join path in the tree, design §1.4). Roll 2 must be sample-exact:
    /// B CONTINUES from its mid-file position at the new shared anchor
    /// (frame 0 == file frame 12_000 — the re-anchor lockstep pin) and C's
    /// first audible frame lands at EXACTLY beat 6 − 4.5 = 1.5 beats =
    /// 36_000 samples (`==`, the M1 sample-accuracy convention).
    @Test("T2 (GATE): mid-play clip add onto a previously-idle strip lands sample-aligned")
    func midPlayClipAddOntoIdleStrip() throws {
        let aURL = try writeSkipRampFile(contentFrames: 2 * beatFrames, name: "t2a", value: rampC)
        let bURL = try writeSkipRampFile(contentFrames: 36_000, name: "t2b", value: rampD)
        let cURL = try writeSkipRampFile(contentFrames: beatFrames, name: "t2c", value: rampC)
        defer {
            try? FileManager.default.removeItem(at: aURL)
            try? FileManager.default.removeItem(at: bURL)
            try? FileManager.default.removeItem(at: cURL)
        }
        let clipA = Clip(name: "A", startBeat: 0, lengthBeats: 2, audioFileURL: aURL)
        let clipB = Clip(name: "B", startBeat: 4, lengthBeats: 1.5, audioFileURL: bURL)
        let clipC = Clip(name: "C", startBeat: 6, lengthBeats: 1, audioFileURL: cURL)
        var trackA = Track(name: "TA", kind: .audio, clips: [clipA])
        let trackB = Track(name: "TB", kind: .audio, clips: [clipB])
        let map = TempoMap(constantBPM: 120)
        let rig = try SkipRig(tracks: [trackA, trackB])

        // Roll 1: A idle, B sounding from file frame 0.
        rig.roll(fromBeat: 4, tempoMap: map)
        #expect(rig.graph.clipHasPendingSchedule(clipID: clipA.id) == false)
        let roll1 = try rig.pull(frames: beatFrames / 2)  // 0.5 beat → playhead 4.5
        let pre = skipMismatches(roll1, range: 0..<(beatFrames / 2), against: rampD)
        #expect(pre.count == 0)

        // The clip add, production seam shape: reconcile flags the change,
        // the engine's tracksDidChange then runs restart(fromBeat: playhead)
        // = stopAllPlayers → scheduleAll → startAllPlayers(new anchor).
        trackA.clips.append(clipC)
        #expect(rig.graph.reconcile(tracks: [trackA, trackB]))
        rig.graph.stopAllPlayers()
        rig.roll(fromBeat: 4.5, tempoMap: map)
        #expect(rig.graph.clipHasPendingSchedule(clipID: clipA.id) == false)  // still idle
        #expect(rig.graph.clipHasPendingSchedule(clipID: clipC.id) == true)
        #expect(rig.graph.clipPlayerForTesting(clipID: clipC.id)?.isPlaying == true)

        // Roll 2, beats [4.5, 8.5): B continues [0, 24k), silence, C at
        // exactly 36_000, silence to the end.
        let roll2 = try rig.pull(frames: 4 * beatFrames)
        rig.engine.stop()

        let cOnset = Int(1.5 * Double(beatFrames))  // 36_000
        let bCont = skipMismatches(roll2, range: 0..<beatFrames) { rampD(12_000 + $0) }
        let gap = skipMismatches(roll2, range: beatFrames..<cOnset) { _ in 0 }
        let cBody = skipMismatches(roll2, range: cOnset..<(cOnset + beatFrames), against: rampC)
        let tail = skipMismatches(
            roll2, range: (cOnset + beatFrames)..<(4 * beatFrames)) { _ in 0 }
        print("[measured] T2: B continuation mismatches \(bCont.count) (\(bCont.first)); "
              + "gap \(gap.count) (\(gap.first)); C body \(cBody.count) (\(cBody.first)); "
              + "tail \(tail.count) (\(tail.first)); "
              + "C onset frame value \(roll2[0][cOnset]) (want \(rampC(0)))")
        #expect(roll2[0][cOnset] == rampC(0))          // the exact-sample GATE pin
        #expect(roll2[0][cOnset - 1] == 0)             // and not a frame early
        #expect(bCont.count == 0)
        #expect(gap.count == 0)
        #expect(cBody.count == 0)
        #expect(tail.count == 0)
    }

    /// T3 — flag lifecycle across rolls: roll 1 with the player idle
    /// (skipped by start AND by stop), roll 2 seeked before its clip
    /// (active). Roll 2 is bit-exact from frame 0 — the skip-stop left no
    /// stale queue, no stale timeline, no stale flag.
    @Test("T3: idle roll then active roll — bit-exact, zero stale state")
    func flagLifecycleAcrossRolls() throws {
        let aURL = try writeSkipRampFile(contentFrames: 2 * beatFrames, name: "t3a", value: rampC)
        defer { try? FileManager.default.removeItem(at: aURL) }
        let clipA = Clip(name: "A", startBeat: 0, lengthBeats: 2, audioFileURL: aURL)
        let map = TempoMap(constantBPM: 120)
        let rig = try SkipRig(tracks: [Track(name: "TA", kind: .audio, clips: [clipA])])

        // Roll 1: from beat 4 — A entirely behind, skipped everywhere.
        rig.roll(fromBeat: 4, tempoMap: map)
        #expect(rig.graph.clipHasPendingSchedule(clipID: clipA.id) == false)
        let roll1 = try rig.pull(frames: beatFrames / 2)
        let silence = skipMismatches(roll1, range: 0..<(beatFrames / 2)) { _ in 0 }
        #expect(silence.count == 0)
        rig.graph.stopAllPlayers()  // the skip-stop: flag false ⇒ no stop call
        #expect(rig.graph.clipHasPendingSchedule(clipID: clipA.id) == false)

        // Roll 2: from beat 0 — A active, content sample-exact.
        rig.roll(fromBeat: 0, tempoMap: map)
        #expect(rig.graph.clipHasPendingSchedule(clipID: clipA.id) == true)
        #expect(rig.graph.clipPlayerForTesting(clipID: clipA.id)?.isPlaying == true)
        let roll2 = try rig.pull(frames: 2 * beatFrames)
        rig.engine.stop()
        let body = skipMismatches(roll2, range: 0..<(2 * beatFrames), against: rampC)
        print("[measured] T3: roll-1 silence mismatches \(silence.count); "
              + "roll-2 body mismatches \(body.count) (\(body.first))")
        #expect(roll2[0][0] == rampC(0))
        #expect(body.count == 0)
    }

    /// T4 — loop-window inclusion (design §2.1 case row 3): a clip behind
    /// the roll start but inside the loop window is NOT schedule-empty —
    /// the initial `topUpLoopCycles(elapsed: 0)` pre-queues its cycle
    /// segments BEFORE start, so the flag is true pre-start and cycle 1
    /// sounds bit-exact (extends the GaplessLoopTransportTests shape).
    @Test("T4: clip behind the roll start inside the loop window — flag true pre-start, sounds in cycle 1")
    func loopWindowInclusion() throws {
        let aURL = try writeSkipRampFile(contentFrames: 2 * beatFrames, name: "t4a", value: rampC)
        defer { try? FileManager.default.removeItem(at: aURL) }
        let clipA = Clip(name: "A", startBeat: 0, lengthBeats: 2, audioFileURL: aURL)
        let map = TempoMap(constantBPM: 120)
        let loop = PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 4)
        let rig = try SkipRig(tracks: [Track(name: "TA", kind: .audio, clips: [clipA])])

        // The production start sequence, split so the PRE-START flag state
        // is observable: head pass enqueues nothing for A (behind beat 3),
        // the initial top-up then queues A's cycle-1/2 pieces.
        rig.graph.scheduleAll(fromBeat: 3, tempoMap: map, loop: loop)
        rig.graph.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)
        let flagPreStart = rig.graph.clipHasPendingSchedule(clipID: clipA.id)
        rig.graph.prepareAllPlayers(withFrameCount: 8_192)
        rig.graph.startAllPlayers(at: nil)
        #expect(flagPreStart == true)
        #expect(rig.graph.clipPlayerForTesting(clipID: clipA.id)?.isPlaying == true)

        // Head [3,4) = 1 beat of silence, then cycle 1: A sounds beats
        // [0,2) of the window — bit-exact — then window silence [2,4).
        let head = beatFrames
        let cycle = 4 * beatFrames
        let output = try rig.pull(frames: head + cycle)
        rig.engine.stop()
        let headSilence = skipMismatches(output, range: 0..<head) { _ in 0 }
        let body = skipMismatches(output, range: head..<(head + 2 * beatFrames), against: rampC)
        let rest = skipMismatches(output, range: (head + 2 * beatFrames)..<(head + cycle)) { _ in 0 }
        print("[measured] T4: pre-start flag \(String(describing: flagPreStart)); "
              + "head-silence mismatches \(headSilence.count); cycle-1 body "
              + "\(body.count) (\(body.first)); cycle-1 rest \(rest.count)")
        #expect(output[0][head] == rampC(0))  // cycle-1 onset exact
        #expect(headSilence.count == 0)
        #expect(body.count == 0)
        #expect(rest.count == 0)
    }

    /// T5 — the stop asymmetry (design §2.3): the skip predicate is the
    /// LEDGER FLAG, never "was started". A node whose play was
    /// isPlayable-skipped keeps flag=true with a non-empty queue; the next
    /// `stopAllPlayers` MUST still stop it (queue cleared), so the fresh
    /// roll's schedule is not duplicated.
    @Test("T5: isPlayable-skipped node keeps flag true; next stop clears its queue — fresh roll not duplicated")
    func failurePathStopClearsQueue() throws {
        let aURL = try writeSkipRampFile(contentFrames: beatFrames, name: "t5a", value: rampC)
        defer { try? FileManager.default.removeItem(at: aURL) }
        let clipA = Clip(name: "A", startBeat: 0, lengthBeats: 1, audioFileURL: aURL)
        let map = TempoMap(constantBPM: 120)
        let rig = try SkipRig(tracks: [Track(name: "TA", kind: .audio, clips: [clipA])])
        final class EventBox { var events: [EngineNoticeEvent] = [] }
        let box = EventBox()
        rig.graph.noticeSink = { box.events.append($0) }

        // Schedule (flag raises), then break the wiring: the m16-a fixture.
        rig.graph.scheduleAll(fromBeat: 0, tempoMap: map)
        let player = try #require(rig.graph.clipPlayerForTesting(clipID: clipA.id))
        let restorePoint = try #require(
            rig.engine.outputConnectionPoints(for: player, outputBus: 0).first)
        rig.engine.disconnectNodeOutput(player)

        rig.graph.startAllPlayers(at: nil)  // isPlayable-skipped, honest notice
        #expect(!player.isPlaying)
        #expect(box.events.count == 1)
        #expect(box.events.first?.code == "clip-unplayable")
        #expect(rig.graph.clipHasPendingSchedule(clipID: clipA.id) == true)  // flag survives

        // The next stop must NOT skip this node — its queue holds the stale
        // segment even though play never succeeded.
        rig.graph.stopAllPlayers()
        #expect(rig.graph.clipHasPendingSchedule(clipID: clipA.id) == false)

        // Heal the wiring and roll fresh: exactly ONE copy of the content —
        // a surviving stale segment would sound queue-contiguous right
        // after the first (frames 24k..48k) and break the silence pin.
        let destination = try #require(restorePoint.node)
        rig.engine.connect(player, to: destination, format: player.outputFormat(forBus: 0))
        rig.graph.scheduleAll(fromBeat: 0, tempoMap: map)
        rig.graph.startAllPlayers(at: nil)
        let output = try rig.pull(frames: 2 * beatFrames)
        rig.engine.stop()
        let body = skipMismatches(output, range: 0..<beatFrames, against: rampC)
        let after = skipMismatches(output, range: beatFrames..<(2 * beatFrames)) { _ in 0 }
        print("[measured] T5: notices \(box.events.map(\.code)); fresh-roll body "
              + "mismatches \(body.count) (\(body.first)); post-clip frames "
              + "\(after.count) (\(after.first)) — non-zero here = duplicated schedule")
        #expect(body.count == 0)
        #expect(after.count == 0)
    }

    /// T6 — offline byte-identity (design §2.4-7): a bounce whose range
    /// starts past clip A renders EXACTLY the analytic expectation — the
    /// same bytes a started-empty player produced pre-R1 (both are pure
    /// silence contributions), through the production OfflineRenderer and
    /// its `startAllPlayers(at: nil)` path.
    @Test("T6: bounce starting past clip A — byte-identical to the analytic expectation")
    func offlineByteIdentity() throws {
        let aURL = try writeSkipRampFile(contentFrames: 2 * beatFrames, name: "t6a", value: rampC)
        let bURL = try writeSkipRampFile(contentFrames: beatFrames, name: "t6b", value: rampD)
        defer {
            try? FileManager.default.removeItem(at: aURL)
            try? FileManager.default.removeItem(at: bURL)
        }
        let tracks = [
            Track(name: "TA", kind: .audio, clips: [
                Clip(name: "A", startBeat: 0, lengthBeats: 2, audioFileURL: aURL),
            ]),
            Track(name: "TB", kind: .audio, clips: [
                Clip(name: "B", startBeat: 6, lengthBeats: 1, audioFileURL: bURL),
            ]),
        ]

        // Beats [4, 8): A entirely behind (skipped), B at beat 6 → 1.0 s in.
        let audio = try OfflineRenderer().render(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
            fromBeat: 4, durationSeconds: 2.0)
        let channels = audio.channelData
        #expect(audio.frameCount == 4 * beatFrames)

        let bOnset = 2 * beatFrames  // 48_000
        let lead = skipMismatches(channels, range: 0..<bOnset) { _ in 0 }
        let body = skipMismatches(channels, range: bOnset..<(bOnset + beatFrames), against: rampD)
        let tail = skipMismatches(
            channels, range: (bOnset + beatFrames)..<(4 * beatFrames)) { _ in 0 }
        print("[measured] T6: lead \(lead.count) (\(lead.first)); "
              + "body \(body.count) (\(body.first)); tail \(tail.count) (\(tail.first))")
        #expect(channels[0][bOnset] == rampD(0))
        #expect(lead.count == 0)
        #expect(body.count == 0)
        #expect(tail.count == 0)
    }
}
