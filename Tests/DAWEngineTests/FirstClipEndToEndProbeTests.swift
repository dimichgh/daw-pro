import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// FIRST-CLIP-DROP, END-TO-END ARM — the full SHIPPED bounce path, not the
/// renderer in isolation.
///
/// `FirstClipDropProbeTests` exonerated `OfflineRenderer` across 15 conditions
/// with a working negative control (an empty first clip reads exactly 0.0
/// between neighbours at 0.043 and 0.050). Everything it measured, though, was
/// a hand-built `[Track]` handed straight to the renderer. A real bounce goes
/// `ProjectStore.renderMixdown` → `renderWindowSeconds` → `RenderExclusion`
/// → `tracksWithLiveAudioUnitState` → `AudioEngine.renderOffline` →
/// `renderCooperatively` → `writeAudioFile`, and the clips are authored through
/// the same store verbs the sax round used — including the real breath contour.
///
/// This arm renders THAT, and asserts on the bytes that land on disk.
///
/// ⚠️ `@MainActor` suites are capped at 330 (`MainActorOccupancySiteTests`,
/// m23-aw-4) and the tree sits on the cap, so this is an extension of an
/// existing `@MainActor` suite rather than a new one.
extension MasteredMixdownStemsTests {

    /// Reads a rendered WAV back off disk into its left channel. The assertion
    /// has to be on the FILE — an in-memory buffer proves the renderer ran, not
    /// that the bounce a user opens contains the note.
    private func fcdLeftChannel(of url: URL) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        try file.read(into: buffer)
        let data = try #require(buffer.floatChannelData)
        return (Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))),
                format.sampleRate)
    }

    /// THE END-TO-END REPRO ATTEMPT. Three sax clips in a row on one hosted
    /// track, each authored through `clip.setNotes`-equivalent store state and
    /// shaped by the REAL `applyBreathContour` verb, bounced through
    /// `ProjectStore.renderMixdown` with the SHIPPED default window.
    @Test("E2E: three sax clips bounced through ProjectStore.renderMixdown — is clip A there?")
    func firstClipEndToEndMixdown() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-firstclip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Clip A at beat 2 so a "warm-up note in front of it" has somewhere to
        // go — the tester's arrangement cannot have had clip A at beat 0.
        let clipLength = 4.0
        let clips = (0..<3).map { index -> Clip in
            Clip(name: "clip\(index)", startBeat: 2 + Double(index) * clipLength,
                 lengthBeats: clipLength,
                 notes: [MIDINote(pitch: 62 + index * 2, velocity: 100,
                                  startBeat: 0, lengthBeats: clipLength * 0.9)])
        }
        let track = Track(
            name: "Sax", kind: .instrument, clips: clips,
            instrument: InstrumentDescriptor(
                kind: .soundBank,
                soundBank: SoundBankConfig(source: .generalMIDI, program: 66, bankMSB: 121)))

        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine
        store.tracks = [track]

        // The REAL breath verb on every clip — this is what the sax round ran,
        // and it is the only thing in play that writes CC 11.
        for clip in clips {
            let applied = try store.applyBreathContour(clipID: clip.id)
            print("""
                [measured] FCD-E2E breath on \(clip.name): \
                \(applied.expressionPointCount) expression pts, \
                \(applied.pitchBendPointCount) bend pts, \
                warnings \(applied.warnings)
                """)
        }

        let url = dir.appendingPathComponent("mix.wav")
        let result = try await store.renderMixdown(toPath: url.path)
        print("[measured] FCD-E2E mixdown: \(result.durationSeconds) s @ \(result.sampleRate) Hz, "
              + "\(result.channels) ch → \(result.path)")

        let (left, rate) = try fcdLeftChannel(of: URL(fileURLWithPath: result.path))
        let framesPerBeat = rate * 60.0 / 120.0
        for clip in store.tracks[0].clips {
            let onset = Int(clip.startBeat * framesPerBeat)
            let end = min(left.count, onset + Int(clip.lengthBeats * 0.9 * framesPerBeat))
            let rms = onset < end ? TestSignals.rms(left, in: onset..<end) : 0
            print("[measured] FCD-E2E \(clip.name) [\(onset),\(end)) file RMS = \(rms)")
        }

        // Positive control on the FILE: it must contain audio at all, or every
        // per-clip figure above is a statement about a broken harness.
        #expect(TestSignals.peak(left, in: 0..<left.count) > 1e-3)
    }

    /// THE FIELD CONDITION NO OTHER ARM HAS: a **second live AUSampler already
    /// holding the same GM bank** while the bounce instantiates its own.
    ///
    /// `scripts/gates/_measure-gm-sax-cc.mjs:290` — the sax round's OWN harness
    /// — wraps every `render.bounce` in a retry whose comment reads "A silent
    /// render is a RETRY (AUSampler takes time to load gs_instruments.dls)".
    /// So silent renders are a known live-app phenomenon there, and the one
    /// structural difference between that world and every arm measured so far
    /// is that the LIVE registry is also holding a bank-loaded AUSampler:
    /// m18-d records that DLS load/dispose mutate AudioToolbox's PROCESS-GLOBAL
    /// bank state.
    @Test("E2E: bounce while a LIVE bank-loaded AUSampler exists (two instances, one process)")
    func firstClipWithLiveInstrumentLoaded() async throws {
        guard ProcessInfo.processInfo.environment["DAWPRO_FIRSTCLIP_PROBE"] != nil else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-firstclip-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let clipLength = 4.0
        let clips = (0..<3).map { index -> Clip in
            Clip(name: "clip\(index)", startBeat: 2 + Double(index) * clipLength,
                 lengthBeats: clipLength,
                 notes: [MIDINote(pitch: 62 + index * 2, velocity: 100,
                                  startBeat: 0, lengthBeats: clipLength * 0.9)])
        }
        let track = Track(
            name: "Sax", kind: .instrument, clips: clips,
            instrument: InstrumentDescriptor(
                kind: .soundBank,
                soundBank: SoundBankConfig(source: .generalMIDI, program: 66, bankMSB: 121)))

        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine
        store.tracks = [track]

        // Bring the LIVE hosted instrument up first — this is what the app has
        // done long before the user asks for a bounce, and what no headless arm
        // so far has had.
        engine.tracksDidChange([track])
        var waited = 0
        while engine.audioUnitStatus(forTrack: track.id) != .ready, waited < 200 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        let liveStatus = engine.audioUnitStatus(forTrack: track.id)
        print("[measured] FCD-LIVE live instrument status after \(waited * 50) ms: "
              + String(describing: liveStatus))
        try #require(liveStatus == .ready,
                     "the LIVE instrument never loaded — this arm measures nothing without it")

        let url = dir.appendingPathComponent("mix.wav")
        let result = try await store.renderMixdown(toPath: url.path)
        let (left, rate) = try fcdLeftChannel(of: URL(fileURLWithPath: result.path))
        let framesPerBeat = rate * 60.0 / 120.0
        for clip in store.tracks[0].clips {
            let onset = Int(clip.startBeat * framesPerBeat)
            let end = min(left.count, onset + Int(clip.lengthBeats * 0.9 * framesPerBeat))
            let rms = onset < end ? TestSignals.rms(left, in: onset..<end) : 0
            print("[measured] FCD-LIVE \(clip.name) [\(onset),\(end)) file RMS = \(rms)")
        }
        #expect(TestSignals.peak(left, in: 0..<left.count) > 1e-3)
    }
}
