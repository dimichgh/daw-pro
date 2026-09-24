import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m15-e (audit F6) engine-side coverage: the REAL `PlaybackGraph` posts an
/// `EngineNoticeEvent` from each schedule-time degradation site — the
/// envelope/fade bake-failure fallbacks ("timing wins") and the
/// stretch-pending silence transition — with honest codes, readable messages,
/// and the affected clip's start beat. Bake failures are forced exactly like
/// the live transient-I/O condition: the file opens fine at reconcile (the
/// player holds it) and is DELETED before the bake's fresh reader opens.
/// All sites are main-actor schedule/reconcile code; the sink is exercised
/// through the same `noticeSink` property `AudioEngine.wireGraphHooks`
/// installs.
///
/// `.serialized` — the house rule for a suite that renders through a REAL
/// engine and waits on the clock (`StretchEngineTests`, `ContourToRenderTests`,
/// the listening harnesses). Without it, the full suite of 2026-09-24 (9243
/// tests) failed exactly this suite's nine real-engine tests at their
/// `waitForPlayer`/`observeAfterEdit` deadlines — each green alone — while
/// the serialized render suites passed in the same run.
@MainActor
@Suite("Engine notices — PlaybackGraph posts (m15-e)", .serialized)
struct EngineNoticeEngineTests {

    // MARK: - Harness

    private func makeManualGraph() throws -> (AVAudioEngine, PlaybackGraph) {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        return (engine, graph)
    }

    /// Writes 1 s of low-amplitude DC as a stereo Float32 WAV into a fresh
    /// temp directory, returning the file URL.
    private func wavFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone.wav")
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
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 48_000, channels: 2,
                                                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: 48_000))
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<48_000 {
            channels[0][frame] = 0.05
            channels[1][frame] = 0.05
        }
        buffer.frameLength = 48_000
        try file.write(from: buffer)
        return url
    }

    private final class EventBox {
        var events: [EngineNoticeEvent] = []
    }

    private func collectingSink(_ graph: PlaybackGraph) -> EventBox {
        let box = EventBox()
        graph.noticeSink = { box.events.append($0) }
        return box
    }

    // MARK: - Fade bake failure (linear schedule path)

    @Test("deleted-under-us file: the fade bake catch posts clip-fades-skipped, once per schedule pass")
    func fadeBakeFailurePostsPerPass() throws {
        let (_, graph) = try makeManualGraph()
        let box = collectingSink(graph)
        let url = try wavFixture()
        let clip = Clip(name: "Guitar Tail", startBeat: 1, lengthBeats: 2,
                        audioFileURL: url, fadeInBeats: 0.5, fadeOutBeats: 0.5)
        let tracks = [Track(name: "Gtr", kind: .audio, clips: [clip])]

        // Reconcile opens the player's file while it still exists.
        graph.reconcile(tracks: tracks)
        #expect(box.events.isEmpty)

        // The live transient-I/O shape: the file vanishes before the bake's
        // fresh reader opens it.
        try FileManager.default.removeItem(at: url)
        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))

        #expect(box.events.count == 1)
        let event = try #require(box.events.first)
        #expect(event.code == "clip-fades-skipped")
        #expect(event.message.contains("Guitar Tail"))
        #expect(event.beat == 1)

        // Every degraded schedule pass posts again (the store coalesces).
        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))
        #expect(box.events.count == 2)
        #expect(box.events.allSatisfy { $0.code == "clip-fades-skipped" })
    }

    // MARK: - Envelope bake failure (m13-h2 fallback)

    @Test("deleted-under-us file: the envelope bake catch posts clip-envelope-skipped")
    func envelopeBakeFailurePosts() throws {
        let (_, graph) = try makeManualGraph()
        let box = collectingSink(graph)
        let url = try wavFixture()
        let clip = Clip(name: "Synth Swell", startBeat: 0, lengthBeats: 2,
                        audioFileURL: url,
                        gainEnvelope: [ClipGainPoint(beat: 0, gainDb: 0),
                                       ClipGainPoint(beat: 2, gainDb: -12)])
        graph.reconcile(tracks: [Track(name: "Syn", kind: .audio, clips: [clip])])
        try FileManager.default.removeItem(at: url)

        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))

        #expect(box.events.count == 1)
        let event = try #require(box.events.first)
        #expect(event.code == "clip-envelope-skipped")
        #expect(event.message.contains("Synth Swell"))
        #expect(event.beat == 0)
    }

    // MARK: - Loop-cycle bake failure

    @Test("loop schedule: BOTH the head and the cycle-plan fade bakes post on failure")
    func loopCycleBakeFailurePosts() throws {
        let (_, graph) = try makeManualGraph()
        let box = collectingSink(graph)
        let url = try wavFixture()
        let clip = Clip(name: "Loop Bed", startBeat: 0, lengthBeats: 2,
                        audioFileURL: url, fadeInBeats: 0.5, fadeOutBeats: 0.5)
        graph.reconcile(tracks: [Track(name: "Bed", kind: .audio, clips: [clip])])
        try FileManager.default.removeItem(at: url)

        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120),
                          loop: PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 2))

        // One post from the truncated head schedule, one from buildCyclePlan
        // — same code (one degradation family; the store coalesces to one
        // ring entry, count 2).
        #expect(box.events.count == 2)
        #expect(box.events.allSatisfy { $0.code == "clip-fades-skipped" })
        #expect(box.events.allSatisfy { $0.beat == 0 })
        #expect(box.events.contains { $0.message.contains("looped repeats") })
    }

    // MARK: - Stretch-pending silence

    /// m23-ap-p2 p2-notice REWROTE this test's sequence. It used to expect the
    /// notice straight after a bare `reconcile` — and that expectation WAS the
    /// defect: a reconcile is what an EDIT does, with the transport stopped,
    /// so every tuning lit the amber chip while nothing played. The notice
    /// now posts from the schedule pass (`scheduleAll`), which in the live
    /// engine is reached only from `AudioEngine.startPlayers` — i.e. only when
    /// something is actually about to play. The episode rules are unchanged.
    @Test("stretch-pending posts ONCE per pending episode; a ready resolution re-arms the gate")
    func stretchPendingPostsOncePerEpisode() throws {
        let (_, graph) = try makeManualGraph()
        let box = collectingSink(graph)
        let url = try wavFixture()
        let clip = Clip(name: "Slowed Vox", startBeat: 4, lengthBeats: 2,
                        audioFileURL: url, stretchRatio: 1.5)
        var tracks = [Track(name: "Vox", kind: .audio, clips: [clip])]
        let tempo = TempoMap(constantBPM: 120)

        graph.stretchResolver = { _ in .pending }
        graph.reconcile(tracks: tracks)
        // An edit with the transport stopped: nothing has played yet.
        #expect(box.events.isEmpty)

        // Playback starts while the render is still pending.
        graph.scheduleAll(fromBeat: 0, tempoMap: tempo)
        #expect(box.events.count == 1)
        let event = try #require(box.events.first)
        #expect(event.code == "clip-stretch-pending")
        #expect(event.message.contains("Slowed Vox"))
        #expect(event.beat == 4)

        // Still pending on the next passes — an edit while rolling (reconcile)
        // and the restart it causes (schedule) — but the episode was already
        // noticed.
        graph.reconcile(tracks: tracks)
        graph.scheduleAll(fromBeat: 1, tempoMap: tempo)
        #expect(box.events.count == 1)

        // The render lands: the clip schedules for real and the gate re-arms.
        graph.stretchResolver = { _ in .ready(url) }
        graph.reconcile(tracks: tracks)
        graph.scheduleAll(fromBeat: 1, tempoMap: tempo)
        #expect(box.events.count == 1)

        // A re-edit back into a pending render (new schedule key) is a NEW
        // pending episode — reported when it is next scheduled, not at the edit.
        graph.stretchResolver = { _ in .pending }
        tracks[0].clips[0].stretchRatio = 2.0
        graph.reconcile(tracks: tracks)
        #expect(box.events.count == 1)
        graph.scheduleAll(fromBeat: 1, tempoMap: tempo)
        #expect(box.events.count == 2)
        #expect(box.events.last?.code == "clip-stretch-pending")
    }

    // MARK: - m23-ap-p2 p2-notice: a TUNED clip's pending render

    /// A TUNED clip in the p2-notice sense: pitch edits that bend the curve
    /// and NO time-stretch or transpose (`hasPitchEdits && isStretchIdentity`).
    /// The note sits inside `wavFixture`'s one second, so the real render in
    /// the engine-level tests below has something to move.
    private static func tunedClip(name: String, startBeat: Double = 2,
                                  url: URL) -> Clip {
        Clip(name: name, startBeat: startBeat, lengthBeats: 2, audioFileURL: url,
             pitchEdits: PitchEditSet(segments: [
                 NoteSegment(startSeconds: 0.1, endSeconds: 0.6, detectedHz: 220,
                             detectedConfidence: 0.9, pitchOffsetCents: 25)
             ]))
    }

    private final class ResolveCounter {
        var calls = 0
    }

    @Test("a stopped-transport tuning posts NO clip-stretch-pending notice — an edit's reconcile is not playback (p2-notice)")
    func stoppedTuningPostsNothing() throws {
        let (_, graph) = try makeManualGraph()
        let box = collectingSink(graph)
        let clip = Self.tunedClip(name: "Lead Vox", url: try wavFixture())
        #expect(clip.hasPitchEdits && clip.isStretchIdentity, "fixture premise: pitch-only")
        let tracks = [Track(name: "Vox", kind: .audio, clips: [clip])]
        let counter = ResolveCounter()
        graph.stretchResolver = { _ in counter.calls += 1; return .pending }

        // What `ProjectStore+PitchCorrection` sets off: the edit calls
        // `engine.tracksDidChange`, whose reconcile resolves the clip. Twice,
        // because a note drag is a stream of edits.
        graph.reconcile(tracks: tracks)
        graph.reconcile(tracks: tracks)

        // Positive control: the clip really took the PENDING branch — it was
        // resolved, and it has no player (it would play as silence).
        #expect(counter.calls == 2)
        #expect(graph.clipPlayerForTesting(clipID: clip.id) == nil)
        #expect(box.events.isEmpty,
                "nothing played, so nothing may claim a sound 'played not as set': \(box.events)")
    }

    @Test("playback started while the tuned render is pending posts exactly one notice; the play start itself never re-resolves the clip (p2-notice)")
    func playWhilePendingPostsExactlyOne() throws {
        let (_, graph) = try makeManualGraph()
        let box = collectingSink(graph)
        let clip = Self.tunedClip(name: "Lead Vox", startBeat: 2, url: try wavFixture())
        let tracks = [Track(name: "Vox", kind: .audio, clips: [clip])]
        let counter = ResolveCounter()
        graph.stretchResolver = { _ in counter.calls += 1; return .pending }
        let tempo = TempoMap(constantBPM: 120)

        graph.reconcile(tracks: tracks)  // the edit, transport stopped
        #expect(box.events.isEmpty)
        let resolvedBeforePlay = counter.calls

        // Play: the live engine's `startPlayers` runs exactly this pass.
        graph.scheduleAll(fromBeat: 0, tempoMap: tempo)
        #expect(box.events.count == 1, "the play start must report the silent clip THEN")
        let event = try #require(box.events.first)
        #expect(event.code == "clip-stretch-pending")
        #expect(event.message.contains("Lead Vox"))
        #expect(event.beat == 2)
        // The finding the hook is built on: scheduling does NOT call the
        // resolver (the pending clip has no ClipNode for `scheduleAll` to
        // walk), so the report cannot come from a re-resolution at play.
        #expect(counter.calls == resolvedBeforePlay)

        // A seek / tempo change / loop restart while still pending is the
        // same episode.
        graph.scheduleAll(fromBeat: 1, tempoMap: tempo)
        graph.scheduleAll(fromBeat: 0, tempoMap: tempo,
                          loop: PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 8))
        #expect(box.events.count == 1)
    }

    @Test("the pending notice for a TUNED clip names its tuned version and never says 'stretch'; stretched clips keep their wording (p2-notice copy)")
    func tunedClipCopyNeverSaysStretch() throws {
        let url = try wavFixture()
        func postedMessage(for clip: Clip) throws -> String {
            let (_, graph) = try makeManualGraph()
            let box = collectingSink(graph)
            graph.stretchResolver = { _ in .pending }
            graph.reconcile(tracks: [Track(name: "Vox", kind: .audio, clips: [clip])])
            graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))
            let event = try #require(box.events.first)
            #expect(event.code == "clip-stretch-pending")
            return event.message
        }

        let tuned = try postedMessage(for: Self.tunedClip(name: "Lead Vox", url: url))
        #expect(tuned.contains("'Lead Vox'"))
        #expect(tuned.contains("tuned version"))
        #expect(tuned.contains("silence"))
        #expect(!tuned.lowercased().contains("stretch"), "a tuning is not a time-stretch: \(tuned)")

        // Controls — the branch is decided by the clip, not hard-wired. A
        // stretched clip keeps the stretch wording, and so does one that is
        // stretched AND tuned (it really is being time-stretched).
        let stretched = try postedMessage(for: Clip(
            name: "Slowed Vox", startBeat: 2, lengthBeats: 2, audioFileURL: url, stretchRatio: 1.5))
        #expect(stretched.contains("time-stretched"))
        var both = Self.tunedClip(name: "Both Vox", url: url)
        both.stretchRatio = 1.5
        let bothMessage = try postedMessage(for: both)
        #expect(bothMessage.contains("time-stretched"))
    }

    @Test("a render that lands before play, a tuning removed before play, and a clip deleted before play all post nothing at play (p2-notice)")
    func pendingThatEndsBeforePlayPostsNothing() throws {
        let url = try wavFixture()
        let tempo = TempoMap(constantBPM: 120)
        let clip = Self.tunedClip(name: "Lead Vox", url: url)
        let pending = [Track(name: "Vox", kind: .audio, clips: [clip])]

        // (1) THE COMMON CASE — the user tunes, the render lands in well under
        // a second, THEN they press play. Nothing was ever silent.
        do {
            let (_, graph) = try makeManualGraph()
            let box = collectingSink(graph)
            graph.stretchResolver = { _ in .pending }
            graph.reconcile(tracks: pending)
            graph.stretchResolver = { _ in .ready(url) }
            graph.reconcile(tracks: pending)
            graph.scheduleAll(fromBeat: 0, tempoMap: tempo)
            #expect(box.events.isEmpty, "render landed before play: \(box.events)")
        }
        // (2) Tuning removed (Remove Tuning / undo) before play: the clip is
        // an identity clip again and never renders.
        do {
            let (_, graph) = try makeManualGraph()
            let box = collectingSink(graph)
            graph.stretchResolver = { _ in .pending }
            graph.reconcile(tracks: pending)
            var untuned = clip
            untuned.pitchEdits = nil
            graph.reconcile(tracks: [Track(name: "Vox", kind: .audio, clips: [untuned])])
            graph.scheduleAll(fromBeat: 0, tempoMap: tempo)
            #expect(box.events.isEmpty, "tuning removed before play: \(box.events)")
        }
        // (3) The clip deleted before play.
        do {
            let (_, graph) = try makeManualGraph()
            let box = collectingSink(graph)
            graph.stretchResolver = { _ in .pending }
            graph.reconcile(tracks: pending)
            graph.reconcile(tracks: [Track(name: "Vox", kind: .audio, clips: [])])
            graph.scheduleAll(fromBeat: 0, tempoMap: tempo)
            #expect(box.events.isEmpty, "clip deleted before play: \(box.events)")
        }
    }

    // MARK: - p2-notice through the REAL AudioEngine

    /// Polls (bounded) until the clip has a player node — i.e. its render
    /// committed and a reconcile opened it. Returns whether it got there.
    private func waitForPlayer(_ engine: AudioEngine, clipID: UUID,
                               seconds: Double = 20) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while engine.graph.clipPlayerForTesting(clipID: clipID) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return engine.graph.clipPlayerForTesting(clipID: clipID) != nil
    }

    private func engineWithTempCache() -> AudioEngine {
        let engine = AudioEngine()
        engine.stretchCache = StretchRenderCache(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("daw-pro-p2n-cache-\(UUID().uuidString)"))
        return engine
    }

    @Test("through the REAL engine: tuning with the transport stopped posts nothing, and neither does the render landing or a later play (p2-notice)")
    func realEngineStoppedTuningStaysQuiet() async throws {
        let engine = engineWithTempCache()
        let box = EventBox()
        engine.engineNoticeHandler = { box.events.append($0) }
        let clip = Self.tunedClip(name: "Lead Vox", url: try wavFixture())
        let track = Track(name: "Vox", kind: .audio, clips: [clip])

        // What the store's pitch edit does (ProjectStore+PitchCorrection:147):
        // the REAL resolver misses the cache, kicks the render, and the clip
        // schedules as silence.
        engine.tracksDidChange([track])
        #expect(engine.graph.clipPlayerForTesting(clipID: clip.id) == nil,
                "positive control: the tuned clip is pending right after the edit")
        #expect(box.events.isEmpty, "stopped transport: \(box.events)")

        // The render lands (a real render, ~a quarter second of debounce plus
        // the work) and the completion restart opens the tuned CAF.
        #expect(try await waitForPlayer(engine, clipID: clip.id), "the tuned render never landed")
        #expect(box.events.isEmpty, "the render landing is not playback either: \(box.events)")

        // Then the user presses play — where hardware exists.
        do {
            try engine.prepare()
        } catch {
            print("[measured] p2-notice realEngineStoppedTuningStaysQuiet: play leg SKIPPED (no audio hardware): \(error)")
            return
        }
        defer {
            engine.stopPlayback()
            engine.shutdown()
        }
        var transport = TransportState()
        transport.isPlaying = true
        engine.startPlayback(transport)
        #expect(box.events.isEmpty, "play after the render landed: \(box.events)")
        print("[measured] p2-notice realEngineStoppedTuningStaysQuiet: play leg RAN, notices=\(box.events.count)")
    }

    @Test("through the REAL engine: play pressed while the tuned render is still pending posts exactly one notice, and the landing render posts no second (p2-notice)")
    func realEnginePlayWhilePendingPostsOnce() async throws {
        let engine = engineWithTempCache()
        let box = EventBox()
        engine.engineNoticeHandler = { box.events.append($0) }
        let clip = Self.tunedClip(name: "Lead Vox", url: try wavFixture())
        let track = Track(name: "Vox", kind: .audio, clips: [clip])

        engine.tracksDidChange([track])
        #expect(box.events.isEmpty, "stopped transport: \(box.events)")
        // Everything from the edit to the play below is SYNCHRONOUS main-actor
        // work, so the render (250 ms debounce, then a main-actor completion)
        // cannot land in between: the clip is deterministically pending at play.
        do {
            try engine.prepare()
        } catch {
            print("[measured] p2-notice realEnginePlayWhilePendingPostsOnce: live leg SKIPPED (no audio hardware): \(error)")
            _ = try await waitForPlayer(engine, clipID: clip.id)
            return
        }
        defer {
            engine.stopPlayback()
            engine.shutdown()
        }
        #expect(box.events.isEmpty, "a RUNNING engine with a stopped transport is not playback: \(box.events)")
        #expect(engine.graph.clipPlayerForTesting(clipID: clip.id) == nil,
                "positive control: still pending at the moment of play")

        var transport = TransportState()
        transport.isPlaying = true
        engine.startPlayback(transport)
        #expect(box.events.count == 1, "play while pending: \(box.events)")
        let event = try #require(box.events.first)
        #expect(event.code == "clip-stretch-pending")
        #expect(event.message.contains("Lead Vox"))
        #expect(!event.message.lowercased().contains("stretch"))

        // A seek while still pending restarts the schedule: same episode.
        engine.seek(transport)
        #expect(box.events.count == 1)

        // The render lands while rolling: the completion restart gives the
        // clip its player and posts nothing more.
        #expect(try await waitForPlayer(engine, clipID: clip.id), "the tuned render never landed")
        #expect(box.events.count == 1, "the landing render must not re-post: \(box.events)")
        print("[measured] p2-notice realEnginePlayWhilePendingPostsOnce: live leg RAN, notices=\(box.events.count)")
    }

    // MARK: - A save that REPOINTS a rendered clip's media (2026-09-24)

    /// `ProjectStore.saveProject` copies imported media into the bundle's
    /// `media/` (`ProjectBundle.write` → `FileManager.copyItem`) and then
    /// REPOINTS every such clip's `audioFileURL` in place and calls
    /// `tracksDidChange` once — on the FIRST save of any project with imported
    /// audio, and again on every Save As to a new bundle. The render cache
    /// keys on the source PATH (`StretchRenderCache.sourceIdentityFields`), so
    /// the repointed clip's render is a miss at its new key and must be
    /// rendered again; `ClipKey` carries the url, so the graph tears the
    /// clip's node down and re-resolves it. These tests run that exact
    /// sequence through the REAL `AudioEngine` (no hardware: nothing here
    /// calls `prepare`) and assert the physics of what the clip then plays.
    enum RenderingClipKind: String, CaseIterable, Sendable {
        /// Pitch edits only (ratio 1, no transpose): a whole-semitone offset
        /// with drift/vibrato at 1, so no detected contour is involved.
        case tuned
        /// A plain time-stretch.
        case stretched
    }

    private static let repointSampleRate = 48_000.0

    private static func renderingClip(_ kind: RenderingClipKind, url: URL) -> Clip {
        switch kind {
        case .tuned:
            return Clip(name: "Tuned Vox", startBeat: 0, lengthBeats: 2, audioFileURL: url,
                        pitchEdits: PitchEditSet(segments: [
                            NoteSegment(startSeconds: 0.1, endSeconds: 0.9, detectedHz: 440,
                                        detectedConfidence: 0.9, pitchOffsetCents: 100)
                        ]))
        case .stretched:
            return Clip(name: "Slowed Vox", startBeat: 0, lengthBeats: 2.5, audioFileURL: url,
                        stretchRatio: 1.25)
        }
    }

    /// 1 s of a 440 Hz sine at amplitude 0.5, stereo Float32 WAV, in a fresh
    /// temp directory named `folder` (a sine, not `wavFixture`'s DC, so the
    /// rendered PITCH is measurable).
    private func sineFixture(folder: String) throws -> URL {
        let url = try Self.freshFixtureURL(folder: folder)
        try Self.writeSine(to: url)
        return url
    }

    /// Where a fixture WOULD live — a fresh temp directory, no file yet.
    private static func freshFixtureURL(folder: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-repoint-\(UUID().uuidString)")
            .appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tone.wav")
    }

    private static func writeSine(to url: URL) throws {
        let frames = Int(repointSampleRate)
        var samples = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            samples[frame] = 0.5 * Float(sin(2.0 * .pi * 440.0 * Double(frame) / repointSampleRate))
        }
        try writeWAV([samples, samples], to: url)
    }

    private static func writeWAV(_ channels: [[Float]], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: repointSampleRate,
            AVNumberOfChannelsKey: channels.count,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: repointSampleRate,
            channels: AVAudioChannelCount(channels.count), interleaved: false))
        let frames = channels[0].count
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(frames)))
        let data = try #require(buffer.floatChannelData)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { data[index].update(from: $0.baseAddress!, count: frames) }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    /// What the LIVE graph would play for `clip`, as audio: an offline render
    /// whose stretch provider is the live engine's OWN resolver (the closure
    /// the graph's reconcile calls — `.ready(url)` opens `url`, `.pending`
    /// schedules nothing), rendered from the clip's start, written to a temp
    /// WAV and read back. The bounce path (`renderOffline`) is deliberately
    /// NOT used: it calls `renderIfNeeded` directly and would render the new
    /// key itself, hiding what the live graph does.
    private func liveResolverRender(_ engine: AudioEngine, clip: Clip, label: String) throws -> [Float] {
        let resolver = try #require(engine.graph.stretchResolver)
        let renderer = OfflineRenderer()
        renderer.stretchedFileProvider = { clip in
            if case .ready(let url) = resolver(clip) { return url }
            return nil
        }
        let audio = try renderer.render(
            tracks: [Track(name: "Vox", kind: .audio, clips: [clip])],
            tempoMap: TempoMap(constantBPM: 120), fromBeat: clip.startBeat,
            durationSeconds: 1.5, masterVolume: 1)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-repoint-out-\(UUID().uuidString)-\(label).wav")
        try Self.writeWAV(audio.channelData, to: url)
        return try TestSignals.readFile(url)[0]
    }

    /// The physics of "plays as set", measured on rendered output — the axis
    /// each render exists for, not merely "audible":
    ///  * tuned: inside the edited note the pitch is 440 × 2^(cents/1200);
    ///  * stretched: there is signal PAST the source's 1.0 s end (an
    ///    unstretched source is silent there) and the pitch is still 440 Hz.
    private static func playsAsSet(_ clip: Clip, _ left: [Float]) -> (ok: Bool, detail: String) {
        let rate = repointSampleRate
        if let cents = clip.pitchEdits?.segments.first?.pitchOffsetCents {
            let window = Int(0.35 * rate)..<Int(0.65 * rate)
            let rms = TestSignals.rms(left, in: window)
            let hz = TestSignals.dominantFrequency(byZeroCrossings: left, sampleRate: rate, in: window)
            let target = 440 * pow(2, cents / 1200)
            let ok = rms > 0.2 && abs(hz - target) <= target * 0.02
            return (ok, "tuned: RMS \(rms) in 0.35–0.65 s, pitch \(hz) Hz (want \(target) ± 2 %)")
        }
        let late = TestSignals.rms(left, in: Int(1.02 * rate)..<Int(1.15 * rate))
        let hz = TestSignals.dominantFrequency(byZeroCrossings: left, sampleRate: rate,
                                               in: Int(0.2 * rate)..<Int(1.0 * rate))
        let ok = late > 0.2 && abs(hz - 440) <= 440 * 0.03
        return (ok, "stretched: RMS \(late) in 1.02–1.15 s (past the 1 s source), pitch \(hz) Hz (want 440 ± 3 %)")
    }

    /// Samples the clip's render status (the snapshot's source,
    /// `clipStretchStatus`) every 10 ms from the moment the edit returns until
    /// the clip's player comes back or `seconds` elapse. Returns each DISTINCT
    /// status in order — the first sample is taken synchronously, before the
    /// kick's Task can have run, so a healthy sequence reads
    /// `idle → rendering → idle` and a render that was never started reads
    /// `idle` alone.
    private func observeAfterEdit(_ engine: AudioEngine, trackID: UUID, clipID: UUID,
                                  seconds: Double) async throws
        -> (statuses: [String], playerBack: Bool, elapsed: Double) {
        let start = Date()
        var statuses: [String] = []
        func sample() {
            let status = "\(engine.clipStretchStatus(trackID: trackID, clipID: clipID) ?? .idle)"
            if statuses.last != status { statuses.append(status) }
        }
        sample()
        var playerBack = false
        while Date().timeIntervalSince(start) < seconds {
            try await Task.sleep(for: .milliseconds(10))
            sample()
            if engine.graph.clipPlayerForTesting(clipID: clipID) != nil {
                playerBack = true
                break
            }
        }
        return (statuses, playerBack, Date().timeIntervalSince(start))
    }

    /// A rendered clip on a real engine: the render has landed and the clip
    /// plays as set (both asserted), as it has long before any save.
    private struct RenderedClipRig {
        let engine: AudioEngine
        let box: EventBox
        let kind: RenderingClipKind
        var track: Track
        var clip: Clip
        let firstRenderSeconds: Double
    }

    private func renderedClipRig(_ kind: RenderingClipKind) async throws -> RenderedClipRig {
        let engine = engineWithTempCache()
        let box = EventBox()
        engine.engineNoticeHandler = { box.events.append($0) }
        let source = try sineFixture(folder: "import")
        let original = Self.renderingClip(kind, url: source)
        let track = Track(name: "Vox", kind: .audio, clips: [original])

        let renderStart = Date()
        engine.tracksDidChange([track])
        #expect(engine.graph.clipPlayerForTesting(clipID: original.id) == nil,
                "positive control: the \(kind) clip is pending right after the edit")
        #expect(try await waitForPlayer(engine, clipID: original.id), "the \(kind) render never landed")
        let firstRenderSeconds = Date().timeIntervalSince(renderStart)
        #expect(engine.stretchCache.renderCount == 1)
        let before = Self.playsAsSet(original, try liveResolverRender(engine, clip: original,
                                                                      label: "\(kind)-before"))
        #expect(before.ok, "positive control: before any edit the clip plays as set — \(before.detail)")
        return RenderedClipRig(engine: engine, box: box, kind: kind, track: track, clip: original,
                               firstRenderSeconds: firstRenderSeconds)
    }

    /// One edit applied to the rig's rendered clip — and the ONE
    /// `tracksDidChange` that follows it — then everything a user would notice
    /// asserted against what SHOULD happen. `edit` returns the clip as the
    /// store would hold it after the edit.
    private func applyEdit(_ rig: inout RenderedClipRig, label: String,
                           edit: @MainActor (Clip) throws -> Clip) async throws {
        let engine = rig.engine
        let kind = rig.kind
        let rendersBefore = engine.stretchCache.renderCount
        let edited = try edit(rig.clip)
        rig.clip = edited
        rig.track.clips = [edited]
        engine.tracksDidChange([rig.track])

        let window = max(5, rig.firstRenderSeconds * 10)
        let observed = try await observeAfterEdit(engine, trackID: rig.track.id, clipID: edited.id,
                                                  seconds: window)
        let rendersAfter = engine.stretchCache.renderCount
        let editedSource = try #require(edited.audioFileURL)
        let committedForEdit = engine.stretchCache.cachedURL(
            source: editedSource, params: StretchRenderCache.Params(clip: edited)) != nil
        rig.box.events.removeAll()
        // What pressing play runs (`startPlayers` → `scheduleAll`).
        engine.graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))
        let pendingPosts = rig.box.events.filter { $0.code == "clip-stretch-pending" }
        let after = Self.playsAsSet(edited, try liveResolverRender(engine, clip: edited,
                                                                   label: "\(kind)-after-\(label)"))
        print("[measured] rendered-clip \(label) \(kind): first render \(rig.firstRenderSeconds) s; "
              + "after the \(label): statuses \(observed.statuses), player back \(observed.playerBack) "
              + "after \(observed.elapsed) s (window \(window) s), renderCount \(rendersBefore)→\(rendersAfter), "
              + "committed for the edited clip \(committedForEdit), play-pass clip-stretch-pending posts "
              + "\(pendingPosts.count), live output \(after.detail)")

        #expect(observed.statuses.contains("rendering"),
                "after the \(label) a render job must start for the clip's new key: statuses \(observed.statuses)")
        #expect(rendersAfter == rendersBefore + 1, "renderCount \(rendersBefore)→\(rendersAfter)")
        #expect(committedForEdit, "no render is committed for the clip as it now stands")
        #expect(observed.playerBack, "the \(kind) clip never got its player back after the \(label)")
        #expect(pendingPosts.isEmpty,
                "pressing play still reports the clip as silent: \(pendingPosts.map(\.message))")
        #expect(after.ok, "after the \(label) the \(kind) clip does not play as set — \(after.detail)")
    }

    private func editRenderedClip(_ kind: RenderingClipKind, label: String,
                                  edit: @MainActor (Clip) throws -> Clip) async throws {
        var rig = try await renderedClipRig(kind)
        try await applyEdit(&rig, label: label, edit: edit)
    }

    /// Exactly what `saveProject` does to a clip: the media is COPIED into the
    /// bundle (byte-identical) and the clip is repointed at the copy.
    private func saveRepoint(_ clip: Clip) throws -> Clip {
        let source = try #require(clip.audioFileURL)
        let media = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-repoint-\(UUID().uuidString)")
            .appendingPathComponent("2026-09-24 Save Repoint Probe.dawproj/media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let copy = media.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: source), "fixture premise: byte-identical copy")
        var repointed = clip
        repointed.audioFileURL = copy
        return repointed
    }

    @Test("a save that copies a TUNED clip's media into the project and repoints it re-renders the clip, which plays tuned again")
    func saveRepointTunedClipPlaysAgain() async throws {
        try await editRenderedClip(.tuned, label: "save", edit: saveRepoint)
    }

    @Test("a save that copies a STRETCHED clip's media into the project and repoints it re-renders the clip, which plays stretched again")
    func saveRepointStretchedClipPlaysAgain() async throws {
        try await editRenderedClip(.stretched, label: "save", edit: saveRepoint)
    }

    /// The harness's positive control: the same rendered clips, the same
    /// observation, a PARAMETER edit instead of a repoint. If this failed, the
    /// repoint tests' failures would say nothing about repointing.
    @Test("control: a parameter edit on the same rendered clip re-renders it and it plays as newly set (the harness can see a re-render)")
    func parameterEditControlReRenders() async throws {
        try await editRenderedClip(.tuned, label: "edit") { clip in
            var edited = clip
            edited.pitchEdits = PitchEditSet(segments: [
                NoteSegment(startSeconds: 0.1, endSeconds: 0.9, detectedHz: 440,
                            detectedConfidence: 0.9, pitchOffsetCents: 200)
            ])
            return edited
        }
        try await editRenderedClip(.stretched, label: "edit") { clip in
            var edited = clip
            edited.stretchRatio = 1.3
            return edited
        }
    }

    /// Semitones +0.0 → −0.0 — what a raw wire client's `"semitones": -0.0`
    /// (or `-0`) decodes to: `JSONDecoder` keeps the sign and
    /// `clamped(to:)` keeps it (measured 2026-09-24). `ClipKey` compares with
    /// `==`, so the edit alone is not a schedule change; the render KEY hashes
    /// the bit pattern, so the next re-resolve (a move) asks for a render
    /// under a key that has never been rendered.
    @Test("semitones +0.0 → −0.0 on a stretched clip keeps its node, and the clip still plays after a later move")
    func negativeZeroSemitonesThenMove() async throws {
        let engine = engineWithTempCache()
        let source = try sineFixture(folder: "import")
        let original = Self.renderingClip(.stretched, url: source)
        #expect(original.pitchShiftSemitones.sign == .plus)
        var track = Track(name: "Vox", kind: .audio, clips: [original])
        engine.tracksDidChange([track])
        #expect(try await waitForPlayer(engine, clipID: original.id), "the stretched render never landed")
        let firstPlayer = try #require(engine.graph.clipPlayerForTesting(clipID: original.id))
        let rendersBefore = engine.stretchCache.renderCount

        var negated = original
        negated.pitchShiftSemitones = -0.0
        #expect(negated.pitchShiftSemitones.sign == .minus, "fixture premise: a real −0.0")
        track.clips = [negated]
        engine.tracksDidChange([track])
        let playerAfterNegation = engine.graph.clipPlayerForTesting(clipID: original.id)
        #expect(playerAfterNegation === firstPlayer,
                "±0 is one schedule identity: the node (and the render it plays) is kept")

        var moved = negated
        moved.startBeat = 1
        track.clips = [moved]
        engine.tracksDidChange([track])
        let observed = try await observeAfterEdit(engine, trackID: track.id, clipID: moved.id, seconds: 5)
        let after = Self.playsAsSet(moved, try liveResolverRender(engine, clip: moved, label: "negzero-moved"))
        print("[measured] −0.0 semitones then move: node kept across the ±0 edit "
              + "\(playerAfterNegation === firstPlayer); after the move statuses \(observed.statuses), "
              + "player back \(observed.playerBack) after \(observed.elapsed) s, renderCount "
              + "\(rendersBefore)→\(engine.stretchCache.renderCount), live output \(after.detail)")
        #expect(observed.playerBack, "the moved clip never got its player back")
        #expect(after.ok, "after the move the clip does not play as set — \(after.detail)")
    }

    /// Save As repoints the clip AGAIN — from the first bundle's `media/` to
    /// the new bundle's — so it must re-render a second time, not only once.
    @Test("a first save and then a Save As each repoint a tuned or stretched clip, and it re-renders and plays as set after both")
    func saveThenSaveAsReRendersEachTime() async throws {
        for kind in RenderingClipKind.allCases {
            var rig = try await renderedClipRig(kind)
            try await applyEdit(&rig, label: "save", edit: saveRepoint)
            try await applyEdit(&rig, label: "Save As", edit: saveRepoint)
        }
    }

    /// The file at the SAME path changes on disk (an in-place rewrite — here
    /// the identical samples written again, mtime moved on), which re-keys the
    /// render (the key carries size ‖ mtime). Nothing re-resolves the clip on
    /// its own — the graph's schedule key holds the url, which did not change —
    /// so a move stands in for the next edit that does. Before the engine
    /// compared render keys this was the repoint defect at an unchanged path:
    /// the re-resolve missed at the new key and the kick was refused.
    @Test("a clip whose file is rewritten in place and then moved re-renders against the new file and plays as set, not silence")
    func samePathRewriteThenMoveReRenders() async throws {
        try await editRenderedClip(.stretched, label: "rewrite") { clip in
            let source = try #require(clip.audioFileURL)
            let keyBefore = try StretchRenderCache.cacheKey(
                source: source, params: StretchRenderCache.Params(clip: clip))
            try Self.writeSine(to: source)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(7)], ofItemAtPath: source.path)
            #expect(try StretchRenderCache.cacheKey(
                source: source, params: StretchRenderCache.Params(clip: clip)) != keyBefore,
                "fixture premise: the rewrite re-keys the render")
            var moved = clip
            moved.startBeat = 1
            return moved
        }
    }

    /// Media that is missing when the clip first resolves (a drive not yet
    /// mounted, a file being restored) has no render key, so nothing can
    /// render. When the file appears at that path, the next reconcile — any
    /// edit — must render it: the clip has no node, so every pass re-resolves.
    @Test("a stretched clip whose media is missing when it first resolves renders and plays once the media appears, at the next reconcile")
    func missingMediaThatAppearsRenders() async throws {
        let engine = engineWithTempCache()
        let url = try Self.freshFixtureURL(folder: "not-yet-mounted")
        let clip = Self.renderingClip(.stretched, url: url)
        let track = Track(name: "Vox", kind: .audio, clips: [clip])

        engine.tracksDidChange([track])
        // Longer than the 250 ms debounce: any job that was going to run has.
        try await Task.sleep(for: .milliseconds(600))
        #expect(engine.graph.clipPlayerForTesting(clipID: clip.id) == nil,
                "premise: no media, so no player")
        #expect(engine.stretchCache.renderCount == 0, "premise: nothing could render without media")

        try Self.writeSine(to: url)
        engine.tracksDidChange([track])  // the next edit's reconcile
        let observed = try await observeAfterEdit(engine, trackID: track.id, clipID: clip.id, seconds: 5)
        let after = Self.playsAsSet(clip, try liveResolverRender(engine, clip: clip,
                                                                 label: "missing-then-present"))
        print("[measured] missing media that appears: statuses \(observed.statuses), player back "
              + "\(observed.playerBack) after \(observed.elapsed) s, renderCount "
              + "\(engine.stretchCache.renderCount), live output \(after.detail)")
        #expect(observed.statuses.contains("rendering"),
                "no render started once the media appeared: statuses \(observed.statuses)")
        #expect(observed.playerBack, "the clip never got a player once its media appeared")
        #expect(after.ok, "once its media appeared the clip does not play as set — \(after.detail)")
    }
}
