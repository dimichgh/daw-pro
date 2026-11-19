import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// M5 iv-b engine seam (spec §5, §7): `renderOffline` is `renderMixdown`
/// minus the write (bit-identical output), `writeAudioFile` is frame-exact,
/// `forcedCompensationTargets` actually forces ring targets, the planning
/// probe matches the auto-plan, and the whole normalized-bounce path proves
/// itself against the WRITTEN file re-read from disk.
@MainActor
@Suite("Offline buffer seam — renderOffline/writeAudioFile (M5 iv-b)", .serialized)
struct OfflineBufferRenderTests {

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-bufseam-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func audioTrack(_ url: URL, lengthBeats: Double = 4,
                            effects: [EffectDescriptor] = []) -> Track {
        Track(name: "T", kind: .audio,
              clips: [Clip(name: "c", startBeat: 0, lengthBeats: lengthBeats,
                           audioFileURL: url)],
              effects: effects)
    }

    // MARK: - renderOffline ≡ renderMixdown minus the write

    @Test("renderOffline buffer is bit-identical to renderMixdown's file")
    func renderOfflineMatchesMixdownFile() async throws {
        let fixtures = try TestSignals.fixtures()
        let track = audioTrack(fixtures.cos1k48)
        let engine = AudioEngine()

        let buffer = try await engine.renderOffline(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 1.0, forcedCompensationTargets: nil)

        let out = try makeTempDir("mix").appendingPathComponent("mix.wav")
        _ = try await engine.renderMixdown(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 1.0, to: out)
        let written = try TestSignals.readFile(out)

        #expect(buffer.sampleRate == 48_000)
        #expect(buffer.channelData.count == written.count)
        var maxDifference: Float = 0
        for channel in 0..<min(buffer.channelData.count, written.count) {
            #expect(buffer.channelData[channel].count == written[channel].count)
            let frames = min(buffer.channelData[channel].count, written[channel].count)
            for frame in 0..<frames {
                maxDifference = max(maxDifference,
                                    abs(buffer.channelData[channel][frame] - written[channel][frame]))
            }
        }
        print("[measured] renderOffline vs mixdown file max diff: \(maxDifference)")
        #expect(maxDifference == 0)
        // Real audio, not two agreeing silences.
        #expect(TestSignals.rms(buffer.channelData[0], in: 12_000..<24_000) > 0.2)
    }

    // MARK: - writeAudioFile round trip

    @Test("writeAudioFile writes a frame-exact Float32 WAV, parents created")
    func writeAudioFileRoundTrip() throws {
        // Distinct channels prove deinterleave order survives the trip; the
        // > 1.0 sample proves Float32 keeps over-full-scale content (the ii-e
        // no-baked-headroom stance).
        let frames = 1_000
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            left[frame] = Float(frame) * 1e-4
            right[frame] = -Float(frame) * 2e-4
        }
        left[500] = 1.25
        let audio = RenderedAudio(sampleRate: 48_000, channelData: [left, right])

        // Nested not-yet-existing directory proves recursive parent creation.
        let url = try makeTempDir("write")
            .appendingPathComponent("nested")
            .appendingPathComponent("out.wav")
        let info = try AudioEngine().writeAudioFile(audio, to: url)

        #expect(info.sampleRate == 48_000)
        #expect(info.channelCount == 2)
        #expect(abs(info.durationSeconds - Double(frames) / 48_000.0) < 1e-9)

        let reread = try TestSignals.readFile(url)
        #expect(reread.count == 2)
        #expect(reread[0] == left)
        #expect(reread[1] == right)
    }

    // MARK: - Forced compensation targets reach the ring

    @Test("forcedCompensationTargets delays the strip by exactly the target")
    func forcedTargetsAreApplied() async throws {
        let fixtures = try TestSignals.fixtures()
        let track = audioTrack(fixtures.cos1k48)
        let engine = AudioEngine()

        // No effects anywhere: the automatic plan is all-zero, so any shift
        // in the forced pass is the forced ring target and nothing else.
        let reference = try await engine.renderOffline(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 0.5, forcedCompensationTargets: nil)
        let forced = try await engine.renderOffline(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 0.5, forcedCompensationTargets: [track.id: 480])

        // The cosine peaks at frame 0 — the unforced render is loud
        // immediately; the forced one is ring-silence for 480 frames.
        #expect(abs(reference.channelData[0][0]) > 0.1)
        #expect(TestSignals.peak(forced.channelData[0], in: 0..<478) < 1e-6)
        let onset = TestSignals.firstFrame(in: forced.channelData[0], exceeding: 0.1)
        #expect(onset != nil && abs((onset ?? 0) - 480) <= 2)
    }

    // MARK: - Planning probe parity (spec §5)

    @Test("offlineCompensationTargets equals the automatic plan's targets")
    func compensationTargetsMatchAutoPlan() async throws {
        let fixtures = try TestSignals.fixtures()
        // One limiter track (240-sample lookahead @ 48 kHz) + one dry track:
        // the plan pads the dry strip to the 240-sample track stage and gives
        // the limiter strip 0.
        let limited = audioTrack(fixtures.cos1k48,
                                 effects: [EffectDescriptor(kind: .limiter)])
        let dry = audioTrack(fixtures.cos1k48Quarter)
        let engine = AudioEngine()

        let targets = await engine.offlineCompensationTargets(tracks: [limited, dry])
        #expect(targets[limited.id] == 0)
        #expect(targets[dry.id] == 240)

        // Parity with the pure plan math over the same strip facts — the
        // probe IS the auto-plan, not a reimplementation.
        let plan = PDCPlan.compute(input: PDCInput(strips: [
            PDCStripInput(id: limited.id,
                          kind: .track(outputsToMaster: true, hasSends: false),
                          chainLatencyAll: 240, chainLatencyActive: 240),
            PDCStripInput(id: dry.id,
                          kind: .track(outputsToMaster: true, hasSends: false),
                          chainLatencyAll: 0, chainLatencyActive: 0),
        ]))
        let expected = Dictionary(uniqueKeysWithValues:
            plan.strips.map { ($0.id, $0.compensationSamples) })
        #expect(targets == expected)
    }

    // MARK: - Normalized bounce, verified from the WRITTEN file (spec §7)

    @Test("renderBounce hits the LUFS target ±0.1 LU re-measured from disk")
    func normalizedBounceHitsTargetFromDisk() async throws {
        let fixtures = try TestSignals.fixtures()
        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine
        // 1 kHz cosine, amp 0.5 → ≈ −6 LUFS program; clip covers the whole
        // 2 s window (4 beats @ 120 BPM).
        store.tracks = [audioTrack(fixtures.cos1k48)]

        let out = try makeTempDir("bounce").appendingPathComponent("normalized.wav")
        let result = try await store.renderBounce(
            toPath: out.path, durationSeconds: 2.0, lufsTarget: -16)

        // Ground truth: read the file back off disk and measure THAT.
        let reread = RenderedAudio(sampleRate: 48_000,
                                   channelData: try TestSignals.readFile(out))
        let measured = Loudness.measure(reread)
        let achieved = try #require(measured.integratedLufs)
        print("[measured] normalized bounce from disk: target -16, achieved \(achieved) LUFS")
        #expect(abs(achieved - (-16.0)) <= 0.1)

        // The report is that same ground truth (Float32 write is bit-exact,
        // so re-measuring the file reproduces the report's output block).
        let reported = try #require(result.report.output.integratedLufs)
        #expect(abs(reported - achieved) <= 1e-9)
        #expect(!result.report.limitedByCeiling)
        #expect(result.report.lufsTarget == -16)
        // Gain math closes: input + gain == achieved (static gain, linear op).
        let inputLufs = try #require(result.report.input.integratedLufs)
        #expect(abs(inputLufs + result.report.appliedGainDb - achieved) <= 0.05)
        #expect(result.path == out.path)
        #expect(result.channels == 2)
        #expect(result.sampleRate == 48_000)
        #expect(abs(result.durationSeconds - 2.0) < 0.001)
    }

    // MARK: - m39-w4-4a (W8-W44F): the PRODUCTION render entry's byte gate

    /// A 440 Hz stereo Float32 sine at 48 kHz, amplitude 0.5: a tone, so the
    /// follower follows something real and the gain insert sees a real signal.
    private func w44fSineWAV(seconds: Double) throws -> URL {
        let frames = Int(seconds * 48_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w44f-sine-\(UUID().uuidString).wav")
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
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<frames {
            let value = Float(0.5 * sin(2 * Double.pi * 440 * Double(frame) / 48_000))
            data[0][frame] = value
            data[1][frame] = value
        }
        try file.write(from: buffer)
        return url
    }

    /// Every modulation kind that existed before the musical clock, plus "none".
    private static let w44fKinds = ["none", "stepFree", "lfo", "follower", "macro"]

    /// W44's G1 fixture shape: the source rides the fader (the per-sample
    /// stage) AND a gain insert's `gainLinear` (the block-rate effect path).
    private func w44fTrack(clip url: URL, kind: String) -> Track {
        let gain = EffectDescriptor(kind: .gain)
        var track = Track(name: "W44F \(kind)", kind: .audio,
                          clips: [Clip(name: "tone", startBeat: 0, lengthBeats: 24,
                                       audioFileURL: url)],
                          effects: [gain])
        let source: ModulationSource
        switch kind {
        case "stepFree":
            source = ModulationSource(kind: .stepSequencer, params: .stepSequencer(
                StepSequencerSourceParams(steps: [1, 0, 0.5, -0.5, 0.25], rateHz: 7.3, edgeMs: 3)))
        case "lfo":
            source = ModulationSource(kind: .lfo, params: .lfo(
                LFOSourceParams(waveform: .sine, rateHz: 3.1, bipolar: false)))
        case "follower":
            source = ModulationSource(kind: .envelopeFollower, params: .envelopeFollower(
                EnvelopeFollowerSourceParams(detector: .peak, attackMs: 10, releaseMs: 120,
                                             floorDb: -60)))
        case "macro":
            source = ModulationSource(kind: .macro, params: .macro(MacroSourceParams(value: 0.6)))
        default:
            return track
        }
        track.modulationSources = [source]
        track.modulationRoutes = [
            ModulationRoute(sourceID: source.id, target: .volume, depth: -0.4),
            ModulationRoute(sourceID: source.id,
                            target: .effectParam(effectID: gain.id, paramName: "gainLinear"),
                            depth: 0.3),
        ]
        return track
    }

    /// The drum machine with a FREE-RUNNING step source on `openHat.decay`:
    /// the instrument-side latch path, read at note-on.
    private func w44fDrums() -> Track {
        var notes: [MIDINote] = []
        var beat = 0.0
        while beat < 16 {
            notes.append(MIDINote(pitch: 39, velocity: 90, startBeat: beat, lengthBeats: 0.25))
            beat += 0.5
        }
        var track = Track(name: "W44F drums", kind: .instrument,
                          clips: [Clip(name: "hats", startBeat: 0, lengthBeats: 16, notes: notes)],
                          instrument: InstrumentDescriptor(kind: .drumSynth))
        let source = ModulationSource(kind: .stepSequencer, params: .stepSequencer(
            StepSequencerSourceParams(steps: [1, -1, 0.5], rateHz: 5.3, edgeMs: 2)))
        track.modulationSources = [source]
        track.modulationRoutes = [ModulationRoute(
            sourceID: source.id, target: .instrumentParam(paramName: "openHat.decay"), depth: 0.5)]
        return track
    }

    /// Raw little-endian Float32, channel after channel.
    private func w44fWriteRaw(_ channels: [[Float]], to url: URL) throws {
        var data = Data()
        for channel in channels {
            channel.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        }
        try data.write(to: url)
    }

    /// ⭐ m39-w4-4a BG: the byte gate over the PRODUCTION render entry, which
    /// W44's G1 cannot see (G1 drives `OfflineRenderer` directly). Every
    /// pre-clock modulation kind through (1) the engine's legacy
    /// `renderOffline` overload, which exists before AND after the meter seam,
    /// and (2) the store's session renders (bounce, mixdown, stems with their
    /// 00 Mixdown) with a master macro, under a constant meter and under a
    /// mid-song meter change, across a tempo change.
    ///
    /// With `W44F_BYTEGATE_OUT=<folder>` each capture's raw Float32 lands
    /// there; the lane captured BEFORE the meter seam existed and AFTER, and
    /// compared the folders with `cmp`. Without it the test still proves the
    /// gate can see: no capture is silent, every modulated engine render
    /// differs from the unmodulated one, and, because no source here is
    /// tempo-synced, the meter change leaves every store capture bit-identical
    /// (the meter may reach nothing but a synced source's clock).
    @Test("m39-w4-4a byte gate: the production render entry (engine overload + store bounce/mixdown/stems) over every pre-clock modulation kind, with and without a meter change")
    func w44fProductionEntryByteGate() async throws {
        let tempo = try TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 8, bpm: 90)])
        let meterChange = try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                                 .init(startBeat: 16, beatsPerBar: 3, beatUnit: 4)])
        let tone = try w44fSineWAV(seconds: 12)
        defer { try? FileManager.default.removeItem(at: tone) }
        let outFolder = ProcessInfo.processInfo.environment["W44F_BYTEGATE_OUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let outFolder {
            try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        }
        var captures: [(name: String, channels: [[Float]])] = []

        // (1) The engine's legacy overload: 10 s from beat 0, across 120 → 90 at 4 s.
        let engine = AudioEngine()
        for kind in Self.w44fKinds {
            let audio = try await engine.renderOffline(
                tracks: [w44fTrack(clip: tone, kind: kind)], tempoMap: tempo, masterVolume: 1,
                fromBeat: 0, durationSeconds: 10, forcedCompensationTargets: nil)
            captures.append(("engine-\(kind)", audio.channelData))
        }
        let drums = try await engine.renderOffline(
            tracks: [w44fDrums()], tempoMap: tempo, masterVolume: 1,
            fromBeat: 0, durationSeconds: 9, forcedCompensationTargets: nil)
        captures.append(("engine-drums-stepFree", drums.channelData))

        // (2) The store's session renders, a master macro on the master fader.
        let store = ProjectStore()
        store.engine = engine
        store.tracks = Self.w44fKinds.map { kind -> Track in
            var track = w44fTrack(clip: tone, kind: kind)
            track.volume = 0.3
            return track
        } + [w44fDrums()]
        let macro = try store.addModulationSource(on: .master, kind: .macro,
                                                  params: ["value": .number(0.6)]).source
        try store.addModulationRoute(on: .master, sourceID: macro.id, target: .volume, depth: -0.3)
        let root = try makeTempDir("w44f-bytegate")
        defer { try? FileManager.default.removeItem(at: root) }
        let meterStates: [(label: String, meter: MeterMap?)] = [("constant", nil),
                                                                ("meterChange", meterChange)]
        for (label, meter) in meterStates {
            try store.setTempoMap(tempo, meterMap: meter)
            // A setter's return is not proof it took: the store must now hold it.
            #expect(store.transport.meterMap.changes.count == (meter == nil ? 1 : 2))
            #expect(store.transport.tempoMap == tempo)
            let dir = root.appendingPathComponent(label)
            let bounce = try await store.renderBounce(
                toPath: dir.appendingPathComponent("bounce.wav").path, durationSeconds: 10)
            captures.append(("store-\(label)-bounce",
                             try TestSignals.readFile(URL(fileURLWithPath: bounce.path))))
            let mix = try await store.renderMixdown(
                toPath: dir.appendingPathComponent("mixdown.wav").path, durationSeconds: 10)
            captures.append(("store-\(label)-mixdown",
                             try TestSignals.readFile(URL(fileURLWithPath: mix.path))))
            let stems = try await store.renderStems(
                toDirectory: dir.appendingPathComponent("stems").path, durationSeconds: 10,
                includeMixdown: true)
            for (index, stem) in stems.stems.enumerated() {
                captures.append(("store-\(label)-stem\(index)",
                                 try TestSignals.readFile(URL(fileURLWithPath: stem.path))))
            }
            let reference = try #require(stems.mixdown)
            captures.append(("store-\(label)-stems00",
                             try TestSignals.readFile(URL(fileURLWithPath: reference.path))))
        }

        func bits(_ channels: [[Float]]) -> [[UInt32]] { channels.map { $0.map(\.bitPattern) } }
        let engineNone = try #require(captures.first { $0.name == "engine-none" })
        for capture in captures {
            let peak = capture.channels.flatMap { $0 }.reduce(Float(0)) { max($0, abs($1)) }
            #expect(peak > 0.01, "\(capture.name) is silent (peak \(peak))")
            if capture.name.hasPrefix("engine-"), capture.name != "engine-none",
               !capture.name.hasPrefix("engine-drums") {
                #expect(bits(capture.channels) != bits(engineNone.channels),
                        "\(capture.name) is byte-identical to no modulation")
            }
            if capture.name.hasPrefix("store-meterChange-") {
                let twinName = capture.name.replacingOccurrences(of: "meterChange", with: "constant")
                let twin = try #require(captures.first { $0.name == twinName })
                #expect(bits(capture.channels) == bits(twin.channels),
                        "\(capture.name): a meter change moved bytes in a project with no synced source")
            }
            print("[measured] W44F BG \(capture.name): frames \(capture.channels.first?.count ?? 0), "
                  + "peak \(peak)")
            if let outFolder {
                try w44fWriteRaw(capture.channels,
                                 to: outFolder.appendingPathComponent("\(capture.name).f32"))
            }
        }
        // 6 engine renders + per meter state: bounce, mixdown, 6 stems, the 00 Mixdown.
        #expect(captures.count == 6 + 2 * (2 + Self.w44fKinds.count + 1 + 1))
    }
}
