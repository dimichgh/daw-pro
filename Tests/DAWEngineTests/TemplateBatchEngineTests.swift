import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// M39 TPL-2b — THE ENGINE TAKES A ROUTED BATCH
// (docs/design/2026-09-27-multi-instrument-templates.md §5.6, §8.7).
//
// A template adds a whole band in ONE edit: several new strips, already routed
// to each other, reach the engine in ONE `tracksDidChange`. §5.6 marked "a
// batch this size works" as an assumption. These tests replace it with
// measurements:
//
//   1. the store hands the engine the whole batch in ONE call (a recording stub
//      engine sits behind `ProjectStore.applyTemplate`);
//   2. that list arrives as ONE `PlaybackGraph.reconcile` on a graph that
//      already holds the song's existing track, then rolls in
//      `OfflineRenderer.beginSession`'s order;
//   3. every bus receives its feeds, the key ducks each burst and lets go
//      between them, and the LFO moves the setting it is routed to. Each is
//      asserted from the rendered PHYSICS (closed-form levels, gain ratios, the
//      compressor's own gain computer), each with a control that must read the
//      opposite: audibility is not correctness;
//   4. the batch renders the same as a cold build and as one-strip-at-a-time
//      edits, and the song's own track is untouched;
//   5. during playback, the batch takes the whole-engine rebuild branch.
//
// WHY AN EXTENSION OF `BusRoutingRenderTests`: `OfflineRenderer`,
// `PlaybackGraph` and `TestSignals` are main-actor types, and the suite census
// in `MainActorOccupancySiteTests` caps main-actor SUITES. An extension adds
// tests to an existing main-actor suite and adds no suite. That suite's
// manual-engine helpers are `private` to their file, so the session below
// re-states them, in `OfflineRenderer.beginSession`'s exact order. The order
// includes `armOfflineAutomation`: without it no LFO has a transport position,
// and every route would read neutral.
//
// OFFLINE ONLY: a manual-rendering `AVAudioEngine` and `OfflineRenderer`. No
// `AudioEngine` is built here, because it binds the Mac's output device.
//
// The pre-registered thresholds and predictions are in the lane's
// PREDICTIONS.md (W7-TPL2B); the numbers in the assertions are those.

/// A failure in this file's fixture plumbing (never a product assertion).
private struct TPL2BError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Records every track list the store hands the engine.
private final class TPL2BRecordingEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted
    /// One entry per `tracksDidChange`, in call order.
    var calls: [[Track]] = []

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) { calls.append(tracks) }
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
}

/// The fixture, one home: the song, the template, its test signals, and the
/// windows the analysis reads.
@MainActor
private enum TPL2BBand {
    static let sampleRate = 48_000.0
    /// 2.72 s = 255 pulls of 512 frames = 272 analysis windows of 480.
    static let frames = 130_560
    static var seconds: Double { Double(frames) / sampleRate }
    /// 120 BPM: two beats per second.
    static var lengthBeats: Double { seconds * 2 }
    static let tempo = TempoMap(constantBPM: 120)
    /// The production offline quantum (`RenderBlockSize.offlineFrames`), so
    /// the manual session and `OfflineRenderer` store modulation at the same
    /// instants.
    static let pull = RenderBlockSize.offlineFrames
    /// Analysis window: every test tone (200, 500, 1000, 3000 Hz) fits a whole
    /// number of cycles, so each sits in its own DFT bin with no leakage.
    static let window = 480

    /// The kick: DC bursts, edges on window boundaries, 0.7 s apart so the
    /// compressor and its held-peak meter both come back to rest between them.
    static let bursts = [9_600..<19_200, 52_800..<62_400, 96_000..<105_600]
    static let kickLevel: Float = 0.25
    static let keysLevel: Float = 0.125
    static let bassLevel: Float = 0.1
    static let leadLevel: Float = 0.1
    static let guideLevel: Float = 0.05
    static let kickToRoom = 0.5
    static let keysToRoom = 0.4
    static let bassToDrums = 0.3
    /// ±0.5 on `gainLinear` (0…16, linear): base 1 is fraction 1/16, and the
    /// depth law adds depth × LFO to that fraction.
    static let lfoDepth = 1.0 / 32

    /// The compressor's steady gain reduction while the key bursts, closed form
    /// from its own gain computer: knee 0, (1/ratio − 1) × (key dB − threshold).
    static var duckDb: Double { 0.75 * (20 * log10(Double(kickLevel)) + 24) }

    // MARK: Windows

    static var windowCount: Int { frames / window }
    /// The first two windows of each burst: the 1 ms attack is an amplitude
    /// step inside them.
    static var onsetWindows: Set<Int> {
        Set(bursts.flatMap { [$0.lowerBound / window, $0.lowerBound / window + 1] })
    }
    /// Windows where every source is stationary, so a bin reads one source
    /// only: before the first burst, inside each burst after its onset, and
    /// from 300 ms after each burst to the next one (the compressor's release
    /// is an amplitude change that leaks into neighbouring bins).
    static var gainOneWindows: [Int] {
        var windows = Array(0..<(bursts[0].lowerBound / window))
        for (index, burst) in bursts.enumerated() {
            let from = (burst.upperBound + 14_400) / window
            let to = index + 1 < bursts.count ? bursts[index + 1].lowerBound / window : windowCount
            windows += Array(from..<to)
        }
        return windows
    }
    static var inBurstWindows: [Int] {
        bursts.flatMap { Array(($0.lowerBound / window + 2)..<($0.upperBound / window)) }
    }
    static var stationaryWindows: [Int] { (gainOneWindows + inBurstWindows).sorted() }

    // MARK: Test signals

    struct Files {
        let guide: URL
        let kick: URL
        let keys: URL
        let bass: URL
        let lead: URL
    }

    static var cachedFiles: Files?

    static func files() throws -> Files {
        if let cachedFiles { return cachedFiles }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-tpl2b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func tone(_ hz: Double, _ level: Float) -> (Int) -> Float {
            { frame in Float(Double(level) * cos(2 * Double.pi * hz * Double(frame) / sampleRate)) }
        }
        let set = Files(
            guide: try write("guide-200hz.wav", in: dir, tone(200, guideLevel)),
            kick: try write("kick-bursts.wav", in: dir) { frame in
                bursts.contains { $0.contains(frame) } ? kickLevel : 0
            },
            keys: try write("keys-1khz.wav", in: dir, tone(1_000, keysLevel)),
            bass: try write("bass-500hz.wav", in: dir, tone(500, bassLevel)),
            lead: try write("lead-3khz.wav", in: dir, tone(3_000, leadLevel)))
        cachedFiles = set
        return set
    }

    /// A stereo Float32 WAV with identical channels.
    static func write(_ name: String, in dir: URL, _ value: (Int) -> Float) throws -> URL {
        let url = dir.appendingPathComponent(name)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else {
            throw TPL2BError("fixture buffer allocation failed for \(name)")
        }
        for frame in 0..<frames {
            let sample = value(frame)
            channels[0][frame] = sample
            channels[1][frame] = sample
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            // Scoped: the file closes before anyone reads it.
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return url
    }

    static func clip(_ name: String, _ url: URL) -> Clip {
        Clip(name: name, startBeat: 0, lengthBeats: lengthBeats, audioFileURL: url)
    }

    // MARK: The template

    /// Six strips: 2 buses, 3 sends, 1 output into a bus, 1 sidechain key,
    /// 1 LFO route. The buses come LAST, so wiring in array order would meet
    /// buses that do not exist yet. `sendLevel` 0 is the silent-bus control;
    /// `lfoDepth` 0 is the still-setting control.
    static func template(sendLevel: Double? = nil, lfoDepth: Double = TPL2BBand.lfoDepth)
        -> TrackSetTemplate {
        let kick = TemplateTrack(
            key: "kick", name: "Kick", kind: .audio, output: "drums",
            sends: [TemplateSend(bus: "room", level: sendLevel ?? kickToRoom)])
        let keys = TemplateTrack(
            key: "keys", name: "Keys", kind: .audio,
            inserts: [TemplateInsert(
                key: "duck", kind: .compressor,
                params: ["thresholdDb": -24, "ratio": 4, "attackMs": 1, "releaseMs": 50,
                         "kneeDb": 0],
                sidechainSource: "kick")],
            sends: [TemplateSend(bus: "room", level: sendLevel ?? keysToRoom)])
        let bass = TemplateTrack(
            key: "bass", name: "Bass", kind: .audio,
            sends: [TemplateSend(bus: "drums", level: sendLevel ?? bassToDrums)])
        let lead = TemplateTrack(
            key: "lead", name: "Lead", kind: .audio,
            inserts: [TemplateInsert(key: "trem", kind: .gain, params: ["gainLinear": 1])],
            modulationSources: [TemplateModSource(
                key: "wobble", kind: .lfo,
                params: .lfo(LFOSourceParams(waveform: .sine, rateHz: 1)))],
            modulationRoutes: [TemplateModRoute(
                source: "wobble", target: .effectParam(insert: "trem", param: "gainLinear"),
                depth: lfoDepth)])
        let drums = TemplateTrack(key: "drums", name: "Drum Bus", kind: .bus)
        let room = TemplateTrack(key: "room", name: "Room", kind: .bus)
        return TrackSetTemplate(name: "TPL2B Band", tracks: [kick, keys, bass, lead, drums, room])
    }

    // MARK: Store → engine

    struct Batch {
        /// The ONE list the store handed the engine, with the test signal
        /// added to the four sources (a template carries no clips).
        let tracks: [Track]
        /// Every list the store handed the engine during `applyTemplate`.
        let calls: [[Track]]
        let result: TemplateApplyResult
        /// The song's existing track.
        let guide: Track

        func id(_ key: String) throws -> UUID {
            guard let id = result.keyToTrackID[key] else {
                throw TPL2BError("the template has no track '\(key)'")
            }
            return id
        }

        func track(_ key: String) throws -> Track {
            let id = try id(key)
            guard let track = tracks.first(where: { $0.id == id }) else {
                throw TPL2BError("the engine was not handed '\(key)'")
            }
            return track
        }

        /// The keyed compressor: the keys strip and its compressor's id.
        func compressor() throws -> (track: UUID, effect: UUID) {
            let keys = try track("keys")
            guard let effect = keys.effects.first(where: { $0.kind == .compressor }) else {
                throw TPL2BError("the keys strip has no compressor")
            }
            return (keys.id, effect.id)
        }
    }

    /// Applies `template` through `ProjectStore.applyTemplate` on a song that
    /// already holds the guide track, and captures what the engine is handed.
    static func batch(_ template: TrackSetTemplate = template(), muteKick: Bool = false)
        throws -> Batch {
        let files = try files()
        let guide = Track(name: "Guide", kind: .audio, clips: [clip("guide", files.guide)])
        let store = ProjectStore(tracks: [guide])
        let engine = TPL2BRecordingEngine()
        store.engine = engine
        engine.calls.removeAll()
        let result = try store.applyTemplate(template)
        let calls = engine.calls
        guard var tracks = calls.last else {
            throw TPL2BError("applyTemplate never called tracksDidChange")
        }
        let signals = ["kick": files.kick, "keys": files.keys, "bass": files.bass,
                       "lead": files.lead]
        for (key, url) in signals {
            guard let id = result.keyToTrackID[key],
                  let index = tracks.firstIndex(where: { $0.id == id }) else {
                throw TPL2BError("the engine was not handed '\(key)'")
            }
            tracks[index].clips = [clip(key, url)]
            if muteKick, key == "kick" { tracks[index].isMuted = true }
        }
        withExtendedLifetime(engine) {}
        return Batch(tracks: tracks, calls: calls, result: result, guide: guide)
    }

    // MARK: Engine

    struct Run {
        let channels: [[Float]]
        let meters: [UUID: [MeterFrame]]
        /// The compressor's published gain reduction after each pull, keyed by
        /// the frame count rendered so far.
        let polls: [(end: Int, db: Double?)]
    }

    /// THE BATCH: the song's graph first (the guide alone), then ONE reconcile
    /// that adds every strip of the template at once, then the roll.
    static func renderBatch(_ batch: Batch, poll: (track: UUID, effect: UUID)? = nil,
                            meters: Bool = false) async throws -> Run {
        let session = try TPL2BSession()
        session.graph.reconcile(tracks: [batch.guide])
        session.graph.reconcile(tracks: batch.tracks)
        try session.roll(batch.tracks)
        try session.pull(frames, poll: poll)
        session.stop()
        if meters { try await session.drainMeters() }
        return Run(channels: session.output, meters: session.meterFrames, polls: session.polls)
    }

    /// The same final list built the way one-strip edits build it: one
    /// reconcile per strip, buses first (a send needs its bus to exist).
    static func renderSequential(_ batch: Batch) throws -> [[Float]] {
        let session = try TPL2BSession()
        var included: Set<UUID> = [batch.guide.id]
        session.graph.reconcile(tracks: [batch.guide])
        for key in ["drums", "room", "kick", "keys", "bass", "lead"] {
            included.insert(try batch.id(key))
            session.graph.reconcile(tracks: batch.tracks.filter { included.contains($0.id) })
        }
        try session.roll(batch.tracks)
        try session.pull(frames, poll: nil)
        session.stop()
        return session.output
    }
}

/// A manual-rendering engine + graph, rolled exactly as
/// `OfflineRenderer.beginSession` rolls one.
@MainActor
private final class TPL2BSession {
    let engine = AVAudioEngine()
    let graph: PlaybackGraph
    private(set) var output: [[Float]] = [[], []]
    private(set) var meterFrames: [UUID: [MeterFrame]] = [:]
    private(set) var polls: [(end: Int, db: Double?)] = []

    init() throws {
        graph = PlaybackGraph(engine: engine, graphRate: TPL2BBand.sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: TPL2BBand.sampleRate,
                                         channels: 2) else {
            throw TPL2BError("no 48 kHz stereo format")
        }
        try engine.enableManualRenderingMode(
            .offline, format: format, maximumFrameCount: AVAudioFrameCount(TPL2BBand.pull))
        // Touching mainMixerNode wires mixer → output (OfflineRenderer's rule).
        _ = engine.mainMixerNode
        graph.meterSink = { [weak self] trackID, frame in
            self?.meterFrames[trackID, default: []].append(frame)
        }
    }

    /// `OfflineRenderer.beginSession` after its reconcile, verbatim in order.
    func roll(_ tracks: [Track]) throws {
        graph.armOfflineAutomation(fromBeat: 0, tempoMap: TPL2BBand.tempo)
        graph.applyParameters(tracks: tracks, playheadBeat: 0)
        try engine.start()
        graph.applyParameters(tracks: tracks, playheadBeat: 0)
        graph.scheduleAll(fromBeat: 0, tempoMap: TPL2BBand.tempo, cause: .offlineRender)
        graph.startAllPlayers(at: nil)
    }

    func pull(_ frames: Int, poll: (track: UUID, effect: UUID)?) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: AVAudioFrameCount(TPL2BBand.pull)) else {
            throw TPL2BError("could not allocate the pull buffer")
        }
        var rendered = 0
        while rendered < frames {
            let request = min(frames - rendered, TPL2BBand.pull)
            let status = try engine.renderOffline(AVAudioFrameCount(request), to: buffer)
            guard status == .success, let data = buffer.floatChannelData else {
                throw TPL2BError("renderOffline returned status \(status.rawValue)")
            }
            let count = Int(buffer.frameLength)
            for channel in 0..<2 {
                output[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel],
                                                                       count: count))
            }
            rendered += count
            if let poll {
                polls.append((output[0].count,
                              graph.effectGainReductionDb(forTrack: poll.track,
                                                          effectID: poll.effect)))
            }
        }
    }

    func stop() { engine.stop() }

    /// Tap frames hop to the main actor as queued tasks; they land only while
    /// this test is suspended. Waits until the count stops growing.
    func drainMeters() async throws {
        var previous = -1
        var unchanged = 0
        var rounds = 0
        while unchanged < 3 && rounds < 100 {
            try await Task.sleep(for: .milliseconds(30))
            rounds += 1
            let count = meterFrames.values.reduce(0) { $0 + $1.count }
            if count == previous {
                unchanged += 1
            } else {
                unchanged = 0
                previous = count
            }
        }
    }
}

/// Pure arithmetic over rendered samples.
private enum TPL2BMeasure {
    static let size = 480

    /// One DFT bin over one window: the amplitude of the tone in bin `k`
    /// (DC for `k == 0`).
    static func amplitude(_ x: [Float], window w: Int, bin k: Int) -> Double {
        let start = w * size
        var re = 0.0
        var im = 0.0
        for m in 0..<size {
            let value = Double(x[start + m])
            let phase = 2 * Double.pi * Double(k * m) / Double(size)
            re += value * cos(phase)
            im -= value * sin(phase)
        }
        let magnitude = (re * re + im * im).squareRoot()
        return k == 0 ? magnitude / Double(size) : 2 * magnitude / Double(size)
    }

    static func series(_ x: [Float], bin k: Int) -> [Double] {
        (0..<(x.count / size)).map { amplitude(x, window: $0, bin: k) }
    }

    static func db(_ value: Double) -> Double { 20 * log10(value) }

    static func maxAbsDiff(_ a: [[Float]], _ b: [[Float]]) -> Float {
        var worst: Float = 0
        for channel in 0..<min(a.count, b.count) {
            let count = min(a[channel].count, b[channel].count)
            for frame in 0..<count {
                worst = max(worst, abs(a[channel][frame] - b[channel][frame]))
            }
        }
        return worst
    }

    static func peak(_ channels: [[Float]]) -> Float {
        channels.reduce(0) { worst, channel in channel.reduce(worst) { max($0, abs($1)) } }
    }
}

extension BusRoutingRenderTests {
    // MARK: - TPL-2b: the engine takes a routed batch (design §8.7)

    @Test("TPL-2b: a routed 6-strip template reaches the engine in ONE tracksDidChange, wired, in template order")
    func tpl2bBatchArrivesInOneTracksDidChange() throws {
        let batch = try TPL2BBand.batch()
        let keys = ["kick", "keys", "bass", "lead", "drums", "room"]
        let ids = try keys.map { try batch.id($0) }
        let handed = try #require(batch.calls.last)
        print("[measured] tpl2b store→engine: \(batch.calls.count) tracksDidChange call(s); "
              + "list \(handed.map(\.name)); hasRouting \(batch.result.hasRouting); "
              + "slotsUsed \(batch.result.slotsUsed.sorted { $0.key < $1.key })")
        #expect(batch.calls.count == 1)
        #expect(handed.map(\.id) == [batch.guide.id] + ids)
        #expect(handed.map(\.kind) == [.audio, .audio, .audio, .audio, .audio, .bus, .bus])
        #expect(batch.result.hasRouting)
        #expect(batch.result.slotsUsed == ["kick": 0, "keys": 0, "bass": 0, "lead": 1,
                                           "drums": 0, "room": 0])

        // What the engine was handed is the band as designed: the legs below
        // mean nothing if the fixture is not wired the way they assume.
        let (kick, keysTrack, bass, lead) = (handed[1], handed[2], handed[3], handed[4])
        let (drumsID, roomID) = (ids[4], ids[5])
        #expect(kick.outputBusID == drumsID)
        #expect(kick.sends.map(\.destinationBusID) == [roomID])
        #expect(kick.sends.map(\.level) == [TPL2BBand.kickToRoom])
        #expect(keysTrack.effects.map(\.kind) == [.compressor])
        #expect(keysTrack.effects.compactMap(\.sidechainSourceTrackID) == [kick.id])
        #expect(keysTrack.sends.map(\.destinationBusID) == [roomID])
        #expect(keysTrack.sends.map(\.level) == [TPL2BBand.keysToRoom])
        #expect(bass.outputBusID == nil)
        #expect(bass.sends.map(\.destinationBusID) == [drumsID])
        #expect(bass.sends.map(\.level) == [TPL2BBand.bassToDrums])
        #expect(lead.effects.map(\.kind) == [.gain])
        let route = try #require(lead.modulationRoutes.first)
        #expect(lead.modulationRoutes.count == 1)
        #expect(route.depth == TPL2BBand.lfoDepth)
        #expect(route.target == .effectParam(effectID: lead.effects[0].id, paramName: "gainLinear"))
        #expect(lead.modulationSources.map(\.id) == [route.sourceID])
    }

    @Test("TPL-2b leg 1: both buses of a routed batch receive their feeds at the send levels; sends at 0 silence the send-fed bus")
    func tpl2bEveryBusReceivesItsFeeds() async throws {
        let full = try TPL2BBand.batch()
        let control = try TPL2BBand.batch(TPL2BBand.template(sendLevel: 0))
        let run = try await TPL2BBand.renderBatch(full, meters: true)
        let silent = try await TPL2BBand.renderBatch(control, meters: true)

        // The production meter tap sits on each bus MIXER (post-chain,
        // post-fader). At unity with no inserts that is the sum of the bus's
        // inputs. Tap blocks are not aligned to pulls, so only order statistics
        // are read: the max, and the FIRST frame (it starts at sample 0, before
        // any burst, whatever the block size).
        let drums = run.meters[try full.id("drums")] ?? []
        let room = run.meters[try full.id("room")] ?? []
        try #require(!drums.isEmpty && !room.isEmpty, "both bus taps must deliver frames")
        let drumsMax = Double(drums.map(\.rms).max() ?? 0)
        let roomMax = Double(room.map(\.rms).max() ?? 0)
        let drumsFirst = Double(drums[0].rms)
        let roomFirst = Double(room[0].rms)
        let drumsFirstExpected = Double(TPL2BBand.bassLevel) * TPL2BBand.bassToDrums / 2.0.squareRoot()
        let roomFirstExpected = Double(TPL2BBand.keysLevel) * TPL2BBand.keysToRoom / 2.0.squareRoot()
        print("[measured] tpl2b leg 1 bus taps: drums \(drums.count) frames, max RMS \(drumsMax) "
              + "(\(TPL2BMeasure.db(drumsMax)) dBFS), first \(drumsFirst) (expected \(drumsFirstExpected)); "
              + "room \(room.count) frames, max RMS \(roomMax) (\(TPL2BMeasure.db(roomMax)) dBFS), "
              + "first \(roomFirst) (expected \(roomFirstExpected))")
        // [A] −60 dBFS floor on every bus.
        #expect(TPL2BMeasure.db(drumsMax) > -60)
        #expect(TPL2BMeasure.db(roomMax) > -60)
        // Physics: before the kick plays, the drum bus carries the bass send
        // alone and the room carries the keys send alone, each at its level.
        #expect(abs(drumsFirst - drumsFirstExpected) <= 0.03 * drumsFirstExpected)
        #expect(abs(roomFirst - roomFirstExpected) <= 0.03 * roomFirstExpected)

        // Physics through the master: each send's gain through its bus is the
        // ratio of its source's bin with the send to the same bin without it.
        let left = run.channels[0]
        let quiet = silent.channels[0]
        func ratios(bin: Int, windows: [Int]) -> [Double] {
            windows.map {
                TPL2BMeasure.amplitude(left, window: $0, bin: bin)
                    / TPL2BMeasure.amplitude(quiet, window: $0, bin: bin)
            }
        }
        let bassRatios = ratios(bin: 5, windows: TPL2BBand.stationaryWindows)
        let keysRatios = ratios(bin: 10, windows: TPL2BBand.gainOneWindows)
        let kickRatios = ratios(bin: 0, windows: TPL2BBand.inBurstWindows)
        func worst(_ values: [Double], _ expected: Double) -> Double {
            values.map { abs($0 - expected) / expected }.max() ?? .infinity
        }
        let kickFull = TPL2BMeasure.amplitude(left, window: TPL2BBand.inBurstWindows[0], bin: 0)
        print("[measured] tpl2b leg 1 send gains through the buses (full/control): bass→drums "
              + "\(bassRatios.min() ?? 0)…\(bassRatios.max() ?? 0) (expected 1.3, \(bassRatios.count) windows); "
              + "keys→room \(keysRatios.min() ?? 0)…\(keysRatios.max() ?? 0) (expected 1.4, "
              + "\(keysRatios.count) windows); kick→room \(kickRatios.min() ?? 0)…\(kickRatios.max() ?? 0) "
              + "(expected 1.5, \(kickRatios.count) windows); kick DC in a burst \(kickFull) (expected 0.375)")
        #expect(worst(bassRatios, 1 + TPL2BBand.bassToDrums) <= 1e-3)
        #expect(worst(keysRatios, 1 + TPL2BBand.keysToRoom) <= 1e-3)
        #expect(worst(kickRatios, 1 + TPL2BBand.kickToRoom) <= 1e-3)

        // CONTROL — every send at 0: the room bus is fed by sends only, so it is
        // exactly silent; the drum bus keeps the kick's OUTPUT and nothing else.
        let silentRoom = silent.meters[try control.id("room")] ?? []
        let silentDrums = silent.meters[try control.id("drums")] ?? []
        try #require(!silentRoom.isEmpty && !silentDrums.isEmpty, "both bus taps must deliver frames")
        let roomLoudest = silentRoom.map { max($0.peak, $0.rms) }.max() ?? .infinity
        let drumsPeak = silentDrums.map(\.peak).max() ?? 0
        print("[measured] tpl2b leg 1 CONTROL (sends 0): room loudest frame \(roomLoudest) "
              + "(expected exactly 0, \(silentRoom.count) frames); drums first RMS \(silentDrums[0].rms) "
              + "(expected exactly 0), drums max peak \(drumsPeak) (expected exactly 0.25)")
        #expect(roomLoudest == 0)
        #expect(silentDrums[0].rms == 0)
        #expect(drumsPeak == TPL2BBand.kickLevel)
    }

    @Test("TPL-2b leg 2: the batch's sidechain key ducks the keys within 20 ms of each burst and lets go between; a muted key ducks nothing")
    func tpl2bKeyedCompressorDucksEachBurst() async throws {
        let full = try TPL2BBand.batch()
        let muted = try TPL2BBand.batch(muteKick: true)
        let run = try await TPL2BBand.renderBatch(full, poll: try full.compressor())
        let still = try await TPL2BBand.renderBatch(muted, poll: try muted.compressor())
        let window = TPL2BBand.window

        // Gain reduction from the AUDIO: the keys' 1 kHz bin against its own
        // level before the first burst (measured, so this leg does not depend
        // on the send wiring leg 1 checks).
        let keys = TPL2BMeasure.series(run.channels[0], bin: 10)
        let reference = keys[0..<20].reduce(0, +) / 20
        func reduction(_ w: Int) -> Double { -TPL2BMeasure.db(keys[w] / reference) }
        let duck = TPL2BBand.duckDb
        for (index, burst) in TPL2BBand.bursts.enumerated() {
            let onset = burst.lowerBound / window
            let end = burst.upperBound / window
            let before = reduction(onset - 1)
            let first10 = reduction(onset)
            let next10 = reduction(onset + 1)
            let steady = (onset + 2..<end).map(reduction)
            let release = reduction((burst.upperBound + 2_400) / window)
            let backTo = index + 1 < TPL2BBand.bursts.count
                ? TPL2BBand.bursts[index + 1].lowerBound / window : TPL2BBand.windowCount
            let after = ((burst.upperBound + 14_400) / window..<backTo).map(reduction)
            let steadyWorst = steady.map { abs($0 - duck) }.max() ?? .infinity
            print("[measured] tpl2b leg 2 burst \(index + 1) (audio): before \(before) dB, "
                  + "0–10 ms \(first10) dB, 10–20 ms \(next10) dB, steady \(steady.min() ?? 0)…"
                  + "\(steady.max() ?? 0) dB (closed form \(duck)), +50 ms release \(release) dB, "
                  + "from +300 ms \(after.max() ?? .infinity) dB at most over \(after.count) windows")
            #expect(abs(before) <= 0.01)
            #expect(first10 >= 3)
            #expect(next10 >= 6)          // [A] rises within 20 ms
            #expect(steadyWorst <= 0.05)
            #expect(release >= 1 && release <= 6)
            #expect((after.max() ?? .infinity) <= 0.1)  // [A] falls back between bursts
        }

        // Gain reduction as the ENGINE publishes it (held peak, −20 dB/s),
        // read after every 512-frame pull.
        let polls = run.polls
        try #require(polls.count == TPL2BBand.frames / TPL2BBand.pull)
        let restBefore = polls.filter { $0.end <= TPL2BBand.bursts[0].lowerBound }.map { $0.db }
        print("[measured] tpl2b leg 2 published GR before burst 1: \(restBefore.count) polls, "
              + "max \(restBefore.compactMap { $0 }.max() ?? -1) dB (expected exactly 0)")
        #expect(!restBefore.isEmpty && restBefore.allSatisfy { $0 == 0 })
        for (index, burst) in TPL2BBand.bursts.enumerated() {
            let riseIndex = polls.lastIndex { $0.end <= burst.lowerBound + 960 }
            let backTo = index + 1 < TPL2BBand.bursts.count
                ? TPL2BBand.bursts[index + 1].lowerBound : TPL2BBand.frames
            let restIndex = polls.lastIndex { $0.end <= backTo }
            let riseDb = riseIndex.flatMap { polls[$0].db } ?? -1
            let riseAfterOnset = riseIndex.map { polls[$0].end - burst.lowerBound } ?? -1
            let restDb = restIndex.flatMap { polls[$0].db } ?? -1
            let restFrame = restIndex.map { polls[$0].end } ?? -1
            print("[measured] tpl2b leg 2 burst \(index + 1) (published): \(riseDb) dB "
                  + "\(riseAfterOnset) frames after the onset (bound: at or before 960 = 20 ms); "
                  + "\(restDb) dB at frame \(restFrame), the last poll before the next burst / the end")
            #expect(riseDb >= 6)          // [A] rises within 20 ms
            #expect(riseAfterOnset > 0 && riseAfterOnset <= 960)
            #expect(restDb == 0)          // [A] falls back between bursts
        }

        // CONTROL — the key's source muted: the key is silent (mute lands on the
        // source mixer the key fans out from), so nothing ducks. A self-keyed
        // compressor would read 4.45 dB here: the keys' own −18 dBFS peak is
        // 5.9 dB over the threshold.
        let stillPolls = still.polls.map { $0.db }
        let stillKeys = TPL2BMeasure.series(still.channels[0], bin: 10)
        let stillReference = stillKeys[0..<20].reduce(0, +) / 20
        let stillWorst = (0..<stillKeys.count).filter { !TPL2BBand.onsetWindows.contains($0) }
            .map { abs(TPL2BMeasure.db(stillKeys[$0] / stillReference)) }.max() ?? .infinity
        print("[measured] tpl2b leg 2 CONTROL (kick muted): published GR max "
              + "\(stillPolls.compactMap { $0 }.max() ?? -1) dB over \(stillPolls.count) polls "
              + "(expected exactly 0); audio GR at most \(stillWorst) dB (expected <= 0.01)")
        #expect(!stillPolls.isEmpty && stillPolls.allSatisfy { $0 == 0 })
        #expect(stillWorst <= 0.01)
    }

    @Test("TPL-2b leg 3: the batch's LFO route moves the gain it targets (1 Hz, ±0.5); a depth-0 route leaves the knob alone")
    func tpl2bLFORouteMovesTheSetting() async throws {
        let moving = try await TPL2BBand.renderBatch(try TPL2BBand.batch())
        let still = try await TPL2BBand.renderBatch(
            try TPL2BBand.batch(TPL2BBand.template(lfoDepth: 0)))
        let level = Double(TPL2BBand.leadLevel)
        let gain = TPL2BMeasure.series(moving.channels[0], bin: 30).map { $0 / level }
        var worst = 0.0
        for (w, measured) in gain.enumerated() {
            let center = (Double(w) + 0.5) * Double(TPL2BBand.window) / TPL2BBand.sampleRate
            worst = max(worst, abs(measured - (1 + 0.5 * sin(2 * Double.pi * center))))
        }
        let high = gain.max() ?? 0
        let low = gain.min() ?? .infinity
        let knob = TPL2BMeasure.series(still.channels[0], bin: 30).map { $0 / level }
        let knobWorst = TPL2BBand.stationaryWindows.map { abs(knob[$0] - 1) }.max() ?? .infinity
        print("[measured] tpl2b leg 3 LFO→gainLinear: gain \(low)…\(high) over \(gain.count) windows "
              + "(predicted 0.5…1.5), worst |measured − 1 + 0.5·sin 2πt| \(worst) (bound 0.06); "
              + "CONTROL depth 0: worst |gain − 1| \(knobWorst) over "
              + "\(TPL2BBand.stationaryWindows.count) stationary windows (bound 1e-4)")
        #expect(worst <= 0.06)
        #expect(high >= 1.45)
        #expect(low <= 0.55)
        #expect(knobWorst <= 1e-4)
    }

    @Test("TPL-2b invariance: a batch onto a playing song's graph renders as a cold build and as one-strip edits do; the song's own track is untouched")
    func tpl2bBatchMatchesColdAndSequentialBuilds() async throws {
        let batch = try TPL2BBand.batch()
        let batched = try await TPL2BBand.renderBatch(batch)
        let cold = try OfflineRenderer().render(
            tracks: batch.tracks, tempoMap: TPL2BBand.tempo, fromBeat: 0,
            durationSeconds: TPL2BBand.seconds)
        let sequential = try TPL2BBand.renderSequential(batch)
        try #require(batched.channels[0].count == TPL2BBand.frames)
        try #require(cold.frameCount == TPL2BBand.frames)
        try #require(sequential[0].count == TPL2BBand.frames)

        let versusCold = TPL2BMeasure.maxAbsDiff(batched.channels, cold.channelData)
        let versusSequential = TPL2BMeasure.maxAbsDiff(batched.channels, sequential)
        let guide = TPL2BMeasure.series(batched.channels[0], bin: 2)
        let guideWorst = TPL2BBand.stationaryWindows
            .map { abs(guide[$0] - Double(TPL2BBand.guideLevel)) }.max() ?? .infinity
        let leftRight = TPL2BMeasure.maxAbsDiff([batched.channels[0]], [batched.channels[1]])

        // The cold build written to a WAV and read back, then its peaks.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-tpl2b-band-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try OfflineRenderer.writeAudioFile(cold, to: url)
        let readBack = try TestSignals.readFile(url)
        let fileDiff = TPL2BMeasure.maxAbsDiff(readBack, cold.channelData)
        let samplePeak = TPL2BMeasure.peak(readBack)
        let truePeak = Loudness.truePeakLinear(readBack)
        print("[measured] tpl2b invariance: max |batch − cold| \(versusCold), "
              + "max |batch − one-strip edits| \(versusSequential) (both bound 1e-6); guide 200 Hz "
              + "worst |A − 0.05| \(guideWorst) over \(TPL2BBand.stationaryWindows.count) windows; "
              + "max |L − R| \(leftRight); WAV read-back max diff \(fileDiff) over "
              + "\(readBack.first?.count ?? 0) frames; sample peak \(samplePeak), true peak \(truePeak) "
              + "(\(TPL2BMeasure.db(truePeak)) dBTP)")
        #expect(versusCold <= 1e-6)
        #expect(versusSequential <= 1e-6)
        #expect(guideWorst <= 1e-4)
        #expect(leftRight == 0)
        #expect(readBack.first?.count == TPL2BBand.frames)
        #expect(fileDiff == 0)
        #expect(samplePeak <= 0.88)
        #expect(truePeak < 0.95)
    }

    @Test("TPL-2b leg 5: a routed batch arriving DURING playback takes the whole-engine rebuild branch, as one plain audio track does; one plain instrument track does not")
    func tpl2bBatchDuringPlaybackRebuildsTheEngine() throws {
        let batch = try TPL2BBand.batch()
        let files = try TPL2BBand.files()

        struct Arrival {
            let changed: Bool
            let rebuild: Bool
            let announces: Int
            let attachedBefore: Int
            let attachedAfter: Int
            let busesAttached: Int
        }
        // The song plays on a once-rendered engine (the live regime: the
        // engine sets `engineHasRun` when its hardware first starts), then
        // `tracks` arrives in one reconcile.
        func arrive(_ tracks: [Track]) throws -> Arrival {
            let session = try TPL2BSession()
            session.graph.reconcile(tracks: [batch.guide])
            try session.roll([batch.guide])
            session.graph.engineHasRun = true
            var announces = 0
            session.graph.willMutateRoutingTopology = { announces += 1 }
            try session.pull(12_000, poll: nil)
            let before = session.engine.attachedNodes.count
            let changed = session.graph.reconcile(tracks: tracks)
            let after = session.engine.attachedNodes.count
            let buses = try ["drums", "room"].filter {
                session.graph.busMixerNode(forBus: try batch.id($0)) != nil
            }.count
            let arrival = Arrival(changed: changed, rebuild: session.graph.needsEngineRebuild,
                                  announces: announces, attachedBefore: before,
                                  attachedAfter: after, busesAttached: buses)
            session.stop()
            return arrival
        }

        let band = try arrive(batch.tracks)
        let audio = try arrive([batch.guide, Track(name: "Vox", kind: .audio,
                                                    clips: [TPL2BBand.clip("vox", files.keys)])])
        let instrument = try arrive([batch.guide, Track(name: "Pad", kind: .instrument)])
        print("[measured] tpl2b leg 5 (running once-rendered graph): batch → changed \(band.changed), "
              + "rebuild \(band.rebuild), announces \(band.announces), attached \(band.attachedBefore)→"
              + "\(band.attachedAfter), buses attached \(band.busesAttached); one plain audio track → "
              + "rebuild \(audio.rebuild), announces \(audio.announces), attached \(audio.attachedBefore)→"
              + "\(audio.attachedAfter); one plain instrument track → rebuild \(instrument.rebuild), "
              + "announces \(instrument.announces), attached \(instrument.attachedBefore)→"
              + "\(instrument.attachedAfter)")
        #expect(band.changed)
        #expect(band.rebuild)
        #expect(band.announces == 1)
        #expect(band.attachedAfter == band.attachedBefore)
        #expect(band.busesAttached == 0)
        #expect(audio.rebuild)
        #expect(audio.attachedAfter == audio.attachedBefore)
        #expect(!instrument.rebuild)
        #expect(instrument.announces == 0)
        #expect(instrument.attachedAfter > instrument.attachedBefore)
    }
}
