import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M3 engine regressions, updated for the (iii) scheduler: MIDI clips now
/// SOUND (instrument tracks render through per-track source nodes), so the
/// null tests pin the two ways an instrument track must stay inert — muted,
/// or driven by a silent instrument — and the graph now exposes instrument
/// track ids alongside audio (bus still excluded).
@MainActor
@Suite("MIDI render regressions", .serialized)
struct MIDIRenderTests {
    private func audioTrack(clip url: URL, startBeat: Double, lengthBeats: Double) -> Track {
        Track(name: "Audio", kind: .audio, clips: [
            Clip(name: "clip", startBeat: startBeat, lengthBeats: lengthBeats, audioFileURL: url),
        ])
    }

    private func midiTrack(isMuted: Bool = false) -> Track {
        Track(name: "Synth", kind: .instrument, isMuted: isMuted, clips: [
            Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 2),
                MIDINote(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 1),
            ]),
        ])
    }

    private func maxDifference(_ a: RenderedAudio, _ b: RenderedAudio) -> Float {
        #expect(a.frameCount == b.frameCount)
        #expect(a.channelData.count == b.channelData.count)
        var maxDifference: Float = 0
        for channel in 0..<min(a.channelData.count, b.channelData.count) {
            for frame in 0..<min(a.frameCount, b.frameCount) {
                maxDifference = max(
                    maxDifference,
                    abs(a.channelData[channel][frame] - b.channelData[channel][frame])
                )
            }
        }
        return maxDifference
    }

    // 22a. Offline null test: muted instrument track (now also proves
    // instrument mute — the unmuted track WOULD sound post-M3 (iii)).
    @Test("a MUTED MIDI instrument track leaves the audio render bit-identical")
    func mutedInstrumentTrackIsInert() throws {
        let fixtures = try TestSignals.fixtures()
        let audio = audioTrack(clip: fixtures.cos1k48, startBeat: 0, lengthBeats: 4)

        let audioOnly = try OfflineRenderer().render(
            tracks: [audio], tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        let withMIDI = try OfflineRenderer().render(
            tracks: [audio, midiTrack(isMuted: true)], tempoBPM: 120,
            fromBeat: 0, durationSeconds: 1.0
        )

        let difference = maxDifference(audioOnly, withMIDI)
        print("[measured] muted-instrument null max |audio − audio+midi|: \(difference)")
        #expect(difference == 0.0)
        // The null only means something over real signal, not silence.
        #expect(TestSignals.peak(audioOnly.channelData[0], in: 0..<audioOnly.frameCount) > 0.4)
    }

    // 22b. Offline null test: silent-instrument factory (the graph runs the
    // full scheduler path — events fire — but the instrument emits zeros).
    @Test("an EventCaptureInstrument-driven MIDI track leaves the render bit-identical")
    func captureInstrumentTrackIsInert() throws {
        let fixtures = try TestSignals.fixtures()
        let audio = audioTrack(clip: fixtures.cos1k48, startBeat: 0, lengthBeats: 4)

        let audioOnly = try OfflineRenderer().render(
            tracks: [audio], tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        let capture = EventCaptureInstrument()
        let renderer = OfflineRenderer()
        renderer.instrumentFactory = { _ in capture }
        let withMIDI = try renderer.render(
            tracks: [audio, midiTrack()], tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )

        let difference = maxDifference(audioOnly, withMIDI)
        print("[measured] capture-instrument null max |audio − audio+midi|: \(difference)")
        #expect(difference == 0.0)
        #expect(TestSignals.peak(audioOnly.channelData[0], in: 0..<audioOnly.frameCount) > 0.4)
        // The scheduler really ran: the silent instrument saw events.
        #expect(!capture.capturedEvents().filter { !$0.wasReset }.isEmpty)
    }

    // 23b. Graph includes instrument tracks — and, since M4 (i), bus tracks
    // (per-bus mixer nodes with meter taps join trackIDs).
    @Test("PlaybackGraph.reconcile builds nodes for audio, instrument, AND bus tracks")
    func graphIncludesInstrumentTracks() throws {
        let engine = AVAudioEngine()
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        // Mirror OfflineRenderer's setup so nodes form at a known graph rate,
        // with no dependence on real audio hardware.
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        _ = engine.mainMixerNode

        let graph = PlaybackGraph(engine: engine)
        let audio = Track(name: "Audio", kind: .audio, clips: [])
        let inst = midiTrack()
        let bus = Track(name: "Bus", kind: .bus, clips: [])
        graph.reconcile(tracks: [audio, inst, bus])

        #expect(Set(graph.trackIDs) == Set([audio.id, inst.id, bus.id]))
    }
}
