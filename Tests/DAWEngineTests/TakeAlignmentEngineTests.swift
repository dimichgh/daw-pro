import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M6 v-d — take micro-alignment end-to-end through the REAL detector:
/// synthesized click WAVs (the TransientAnalyzerTests recipe), a 2-lane take
/// group built via the store, `autoAlignTake` recovering a planted +80 ms
/// shift through `TransientAnalyzer`, the lane actually moving, and undo
/// restoring it. The pure-aligner and store-rejection matrices live in
/// Tests/DAWCoreTests/TakeAlignmentTests.swift (FakeEngine); this suite pins
/// the whole path: WAV → spectral-flux onsets → TakeAligner → lane move.
@MainActor
@Suite("Take alignment — real detector end-to-end (M6 v-d)")
struct TakeAlignmentEngineTests {
    static let sampleRate = 48_000.0

    /// Analyzer-only engine: the REAL `TransientAnalyzer` behind the
    /// `detectTransients` seam (no cache, no hardware), everything else a
    /// no-op — exactly what `autoAlignTake` needs from an engine.
    @MainActor
    final class AnalyzerEngine: AudioEngineControlling {
        var isRunning = false
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var recordPermission: RecordPermission = .granted

        func detectTransients(inFileAt url: URL, sensitivity: Double) async throws -> [TransientMarker] {
            try TransientAnalyzer.analyze(fileAt: url, sensitivity: sensitivity)
        }

        func prepare() throws { isRunning = true }
        func shutdown() { isRunning = false }
        func tracksDidChange(_ tracks: [Track]) {}
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
            AudioFileInfo(durationSeconds: durationSeconds,
                          sampleRate: TakeAlignmentEngineTests.sampleRate, channelCount: 2)
        }
    }

    // MARK: - Fixture synthesis (the TransientAnalyzerTests recipe)

    /// Alternating-sign exponentially decaying 64-sample burst at each click
    /// time — the sharp-attack shape the detector is tuned for.
    private func clickTrain(seconds: Double, clickTimes: [Double],
                            amplitude: Float = 0.9) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * Self.sampleRate))
        for time in clickTimes {
            let start = Int(time * Self.sampleRate)
            for i in 0..<64 where start + i < samples.count {
                samples[start + i] += amplitude * pow(0.85, Float(i))
                    * (i.isMultiple(of: 2) ? 1 : -1)
            }
        }
        return samples
    }

    /// Writes MONO samples as a Float32 WAV.
    private func writeWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.sampleRate, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else {
            throw EngineError.renderFailed("fixture buffer allocation failed")
        }
        for (i, sample) in samples.enumerated() { channels[0][i] = sample }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    // MARK: - End-to-end

    @Test("a +80 ms click-shifted take is recovered and moved back onto the reference")
    func endToEndPlantedShift() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-take-align-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Reference clicks (deliberately not hop/block-aligned) and the same
        // performance played 80 ms LATE.
        let referenceClicks = [0.500, 0.983, 1.510, 2.007, 2.499]
        let plantedShift = 0.080
        let refURL = dir.appendingPathComponent("reference.wav")
        let takeURL = dir.appendingPathComponent("take.wav")
        try writeWAV(clickTrain(seconds: 3.0, clickTimes: referenceClicks), to: refURL)
        try writeWAV(clickTrain(seconds: 3.0, clickTimes: referenceClicks.map { $0 + plantedShift }),
                     to: takeURL)

        // Two co-located 6-beat lanes at beat 4 (3 s @ 120 BPM), grouped
        // oldest-first: lane 0 = reference, lane 1 = the late take.
        let ref = Clip(name: "Vocal", startBeat: 4, lengthBeats: 6, audioFileURL: refURL)
        let take = Clip(name: "AI Fix 1", startBeat: 4, lengthBeats: 6, audioFileURL: takeURL)
        let track = Track(name: "Vox", kind: .audio, clips: [ref, take])
        let store = ProjectStore(tracks: [track])
        // Strong ref: ProjectStore.engine is weak (the app owns the real one).
        let engine = AnalyzerEngine()
        store.engine = engine
        let group = try store.groupTakes(trackId: track.id, clipIds: [ref.id, take.id])
        let takeLaneID = group.lanes[1].id

        let report = try await store.autoAlignTake(
            trackID: track.id, groupID: group.id, laneID: takeLaneID)

        // The detector is ±5 ms per onset, but both files share the same
        // click shape so per-onset bias cancels in the pair deltas — the
        // median lands well inside 3 ms of the planted shift.
        #expect(abs(report.offsetMs - plantedShift * 1000) < 3.0,
                "recovered \(report.offsetMs) ms vs planted \(plantedShift * 1000) ms")
        #expect(report.matchedOnsets == referenceClicks.count)
        #expect(report.referenceOnsets == referenceClicks.count)
        #expect(report.candidateOnsets == referenceClicks.count)
        #expect(report.confidence == 1.0)
        #expect(report.applied)
        print("[measured] end-to-end recovered offset: \(report.offsetMs) ms "
              + "(planted: \(plantedShift * 1000) ms, bar: ±3 ms)")

        // The lane moved by −offset (0.16 beats for 80 ms @ 120 BPM)...
        let movedLane = try #require(
            store.tracks[0].takeGroups[0].lanes.first { $0.id == takeLaneID })
        #expect(abs(movedLane.clip.startBeat - (4 - report.offsetBeats)) < 1e-9)
        #expect(abs(movedLane.clip.startBeat - 3.84) < 0.012)   // 3 ms in beats
        // ...the reference stayed put...
        #expect(store.tracks[0].takeGroups[0].lanes[0].clip.startBeat == 4)

        // Closed loop (v-d verification fix): a dry-run re-measure through
        // the REAL detector after the apply reads ~0 — this catches any
        // future mapping/clamp bug, not just a wrong offset.
        let recheck = try await store.autoAlignTake(
            trackID: track.id, groupID: group.id, laneID: takeLaneID, apply: false)
        #expect(abs(recheck.offsetMs) < 3.0,
                "post-apply residual \(recheck.offsetMs) ms (bar: ±3 ms)")
        #expect(!recheck.applied)

        // ...and one undo restores the take.
        #expect(try store.undo() == "Align Take")
        let restored = try #require(
            store.tracks[0].takeGroups[0].lanes.first { $0.id == takeLaneID })
        #expect(restored.clip.startBeat == 4)
    }

    @Test("an already-aligned take reports ~0 ms and stays put")
    func endToEndAlreadyAligned() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-take-align-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let clicks = [0.400, 1.100, 1.800, 2.600]
        let refURL = dir.appendingPathComponent("reference.wav")
        let takeURL = dir.appendingPathComponent("take.wav")
        try writeWAV(clickTrain(seconds: 3.0, clickTimes: clicks), to: refURL)
        try writeWAV(clickTrain(seconds: 3.0, clickTimes: clicks), to: takeURL)

        let ref = Clip(name: "A", startBeat: 4, lengthBeats: 6, audioFileURL: refURL)
        let take = Clip(name: "B", startBeat: 4, lengthBeats: 6, audioFileURL: takeURL)
        let track = Track(name: "Vox", kind: .audio, clips: [ref, take])
        let store = ProjectStore(tracks: [track])
        let engine = AnalyzerEngine()   // strong ref — ProjectStore.engine is weak
        store.engine = engine
        let group = try store.groupTakes(trackId: track.id, clipIds: [ref.id, take.id])

        let report = try await store.autoAlignTake(
            trackID: track.id, groupID: group.id, laneID: group.lanes[1].id)
        // Identical files → identical detected onsets → offset exactly 0.
        #expect(abs(report.offsetMs) < 0.5)
        #expect(report.matchedOnsets == clicks.count)
        #expect(report.confidence == 1.0)
        let laneAfter = try #require(
            store.tracks[0].takeGroups[0].lanes.first { $0.id == group.lanes[1].id })
        #expect(abs(laneAfter.clip.startBeat - 4) < 1e-3)
    }
}
