import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// ⭐⭐ m32-b2 — THE GATE THAT PROVES THE FEATURE.
///
/// The single most valuable property of the MPC chop pattern is that you start
/// from *"plays back identically to the source"* and edit from there. This
/// suite states that as a MEASUREMENT: render (i) the original audio clip and
/// (ii) the generated sampler track playing the generated MIDI clip, through
/// the SAME production `OfflineRenderer` path, and compare.
///
/// It is also where the velocity ruling is cashed. Reconstruction notes are
/// velocity 127 because the amp law is `velocity/127 × zone.gain ×
/// params.gain`, and the slice already carries its own recorded amplitude —
/// `strengthMappedVelocityIsQuieter` measures the ~20 dB the rejected design
/// would have thrown away.
///
/// ⚠️ THE FIXTURE IS STEREO AND 48 kHz ON PURPOSE, and both halves matter:
///  - **Stereo** sidesteps m32-h — a single `AVAudioFile.read(into:)`
///    short-reads MONO files whose frame count is not a multiple of 1024, and
///    `SamplerInstrument.init` issues exactly one read. A mono fixture would
///    make this suite measure that defect instead of the chop.
///  - **48 kHz** matches the graph rate, so the sampler's
///    `2^((pitch−root)/12) × fileRate/graphRate` read increment is exactly
///    1.0 and no interpolation drift enters the comparison.
@MainActor
@Suite("Chop reconstruction — the sampler replays the record (m32-b2)", .serialized)
struct SliceToSamplerReconstructionTests {

    private static let rate = 48_000.0
    private static let frames = 96_000              // 2.0 s
    private static let bpm = 120.0                  // → clip [0, 4) beats = [0, 2) s

    // MARK: - Fixture

    /// Four decaying 300 Hz bursts at 0.0 / 0.5 / 1.0 / 1.5 s, hard-panned
    /// differently per channel so a left/right swap cannot hide.
    private static func writeFixture(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else {
            throw NSError(domain: "SliceToSamplerReconstructionTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
        }
        for channel in 0..<2 {
            for frame in 0..<frames { data[channel][frame] = 0 }
        }
        for hit in 0..<4 {
            let start = Int(Double(hit) * 0.5 * rate)
            let length = Int(0.25 * rate)
            for offset in 0..<length {
                let t = Double(offset) / rate
                let envelope = exp(-t * 24.0)
                let value = 0.7 * envelope * sin(2.0 * .pi * 300.0 * t)
                data[0][start + offset] = Float(value)
                data[1][start + offset] = Float(value * 0.6)   // distinguishable channels
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    private func makeFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m32b2-recon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("break48.wav")
        try Self.writeFixture(to: url)
        return url
    }

    // MARK: - The chop, run through the real analysis + snapper

    private struct Chop {
        let sourceClip: Clip
        let plan: SliceToSamplerPlan.Result
        let geometry: SliceBoundaryGeometry
    }

    private func chop(_ url: URL,
                      settings: SliceToSamplerSettings
                        = SliceToSamplerSettings(includeHead: true)) throws -> Chop {
        let clip = Clip(name: "Break", startBeat: 0, lengthBeats: 4, audioFileURL: url)
        let tempo = TempoMap(constantBPM: Self.bpm)
        let markers = try TransientAnalyzer.analyze(fileAt: url, sensitivity: settings.sensitivity)
        let boundaries = SliceBoundaries.condition(
            onsetsSourceSeconds: markers.map(\.timeSeconds),
            windowStart: 0, windowEnd: 2, minSliceSeconds: settings.minSliceSeconds)
        let geometry = try BoundarySnapper.resolve(
            fileAt: url, boundarySeconds: boundaries,
            snapWindowSeconds: settings.effectiveSnapWindowSeconds)
        let byTime = Dictionary(markers.map { ($0.timeSeconds, $0.strength) },
                                uniquingKeysWith: { a, _ in a })
        let plan = try SliceToSamplerPlan.compute(
            clip: clip, geometry: geometry,
            strengths: boundaries.map { byTime[$0] ?? 1 },
            settings: settings, tempoMap: tempo)
        return Chop(sourceClip: clip, plan: plan, geometry: geometry)
    }

    private func samplerTrack(_ chop: Chop, zones: [SamplerZone]? = nil,
                              notes: [MIDINote]? = nil) -> Track {
        Track(name: "Chops", kind: .instrument,
              clips: [Clip(name: "chops", startBeat: chop.plan.midiClipStartBeat,
                           lengthBeats: chop.plan.midiClipLengthBeats,
                           notes: notes ?? chop.plan.notes)],
              instrument: InstrumentDescriptor(
                kind: .sampler,
                sampler: SamplerParams(zones: zones ?? chop.plan.zones, gain: 1)))
    }

    private func render(_ tracks: [Track]) async throws -> [[Float]] {
        let engine = AudioEngine()
        let buffer = try await engine.renderOffline(
            tracks: tracks, tempoMap: TempoMap(constantBPM: Self.bpm), masterVolume: 1,
            fromBeat: 0, durationSeconds: 2.0, forcedCompensationTargets: nil)
        return buffer.channelData
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for value in samples { sum += Double(value) * Double(value) }
        return (sum / Double(samples.count)).squareRoot()
    }

    private func db(_ a: Double, _ b: Double) -> Double {
        guard a > 0, b > 0 else { return .infinity }
        return abs(20 * log10(a / b))
    }

    private func onsetCount(_ channels: [[Float]]) -> Int {
        guard let left = channels.first else { return 0 }
        var mono = left
        if channels.count > 1 {
            for i in mono.indices { mono[i] = (left[i] + channels[1][i]) * 0.5 }
        }
        return TransientAnalyzer.analyze(monoSamples: mono, sampleRate: Self.rate,
                                         sensitivity: 0.5).count
    }

    // MARK: - The gate

    @Test("⭐ the sampler reconstruction matches the source within 0.5 dB RMS")
    func reconstructionMatchesSource() async throws {
        let url = try makeFixture()
        let chopped = try chop(url)
        // The chop actually happened: head + one pad per detected onset.
        #expect(chopped.plan.zones.count >= 3)
        #expect(chopped.geometry.sampleRate == Self.rate)
        #expect(chopped.geometry.frameCount == Self.frames)

        let source = try await render([Track(name: "Src", kind: .audio,
                                             clips: [chopped.sourceClip])])
        let rebuilt = try await render([samplerTrack(chopped)])

        #expect(source.count == rebuilt.count)
        for channel in 0..<min(source.count, rebuilt.count) {
            let a = rms(source[channel])
            let b = rms(rebuilt[channel])
            print("[measured] channel \(channel) RMS source \(a) rebuilt \(b) "
                  + "delta \(db(a, b)) dB")
            // Not two agreeing silences — the floor result looks exactly like
            // success in a ratio comparison.
            #expect(a > 0.02)
            #expect(b > 0.02)
            #expect(db(a, b) < 0.5)
        }

        let sourceOnsets = onsetCount(source)
        let rebuiltOnsets = onsetCount(rebuilt)
        print("[measured] onsets source \(sourceOnsets) rebuilt \(rebuiltOnsets)")
        #expect(sourceOnsets > 0)
        #expect(rebuiltOnsets == sourceOnsets)
    }

    @Test("⭐ POSITIVE CONTROL: a 2000-frame zone shift breaks the match")
    func perturbedZoneFailsTheMatch() async throws {
        let url = try makeFixture()
        let chopped = try chop(url)
        var zones = chopped.plan.zones
        // Move ONE pad 2000 frames (~42 ms) into its own material: it now
        // starts after its burst's attack, so both the level and the onset
        // count must move. A reconstruction test that cannot fail is not a test.
        let victim = zones.count / 2
        let shifted = (zones[victim].startFrame ?? 0) + 2_000
        zones[victim] = SamplerZone(
            id: zones[victim].id, audioFileURL: zones[victim].audioFileURL,
            rootPitch: zones[victim].rootPitch, minPitch: zones[victim].minPitch,
            maxPitch: zones[victim].maxPitch, gain: zones[victim].gain,
            startFrame: shifted, endFrame: zones[victim].endFrame,
            attack: zones[victim].attack, release: zones[victim].release)

        let source = try await render([Track(name: "Src", kind: .audio,
                                             clips: [chopped.sourceClip])])
        let broken = try await render([samplerTrack(chopped, zones: zones)])

        var rmsDelta = 0.0
        for channel in 0..<min(source.count, broken.count) {
            rmsDelta = max(rmsDelta, db(rms(source[channel]), rms(broken[channel])))
        }
        let onsetDelta = abs(onsetCount(source) - onsetCount(broken))
        print("[measured] perturbed: RMS delta \(rmsDelta) dB, onset delta \(onsetDelta)")
        // ⭐ At least one of the two assertions the real gate makes must break.
        #expect(rmsDelta >= 0.5 || onsetDelta != 0)
    }

    @Test("⭐ strength-mapped velocity is measurably QUIETER than the record")
    func strengthMappedVelocityIsQuieter() async throws {
        let url = try makeFixture()
        let faithful = try chop(url)
        let quiet = try chop(url, settings: SliceToSamplerSettings(
            includeHead: true, velocityFromStrength: true))
        // Only the note velocities differ — the zones are identical.
        #expect(faithful.plan.zones.map(\.startFrame) == quiet.plan.zones.map(\.startFrame))
        #expect(faithful.plan.notes.map(\.velocity) != quiet.plan.notes.map(\.velocity))

        let source = try await render([Track(name: "Src", kind: .audio,
                                             clips: [faithful.sourceClip])])
        let atFull = try await render([samplerTrack(faithful)])
        let atStrength = try await render([samplerTrack(quiet)])

        let sourceRMS = rms(source[0])
        let fullRMS = rms(atFull[0])
        let strengthRMS = rms(atStrength[0])
        print("[measured] source \(sourceRMS), velocity127 \(fullRMS), "
              + "velocityFromStrength \(strengthRMS)")
        // Velocity 127 tracks the record; the strength mapping does not. This
        // is the whole arithmetic behind the ruling, measured rather than
        // argued: 127/127 is exactly 1.0.
        #expect(db(sourceRMS, fullRMS) < 0.5)
        #expect(strengthRMS < fullRMS)
        #expect(db(sourceRMS, strengthRMS) > 0.5)
    }
}
