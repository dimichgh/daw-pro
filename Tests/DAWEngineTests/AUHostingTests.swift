import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M3 (vi-a) Audio Unit instrument hosting, headless: Apple's stock music
/// devices (DLSMusicDevice 'dls ', AUMIDISynth 'msyn', AUSampler 'samp' — all
/// v2, hostable from SPM) rendered through the SAME offline graph as every
/// other instrument. AU output is NEVER bit-exact/null-tested — assertions are
/// windowed peak/RMS only. 48 kHz stereo, 120 BPM → beat 1 = frame 24 000.
@MainActor
@Suite("AU instrument hosting", .serialized)
struct AUHostingTests {
    private static let dls = AudioUnitComponentID(subType: "dls ", manufacturer: "appl")
    private static let msyn = AudioUnitComponentID(subType: "msyn", manufacturer: "appl")
    private static let samp = AudioUnitComponentID(subType: "samp", manufacturer: "appl")

    private func auTrack(component: AudioUnitComponentID, clips: [Clip] = [],
                         stateData: Data? = nil) -> Track {
        Track(name: "AU", kind: .instrument, clips: clips,
              instrument: InstrumentDescriptor(
                  kind: .audioUnit,
                  audioUnit: AudioUnitConfig(component: component, stateData: stateData)))
    }

    /// One clip at beat 0: p60 v127 at clip-beat 1, the given length.
    private func noteClip(lengthBeats: Double) -> Clip {
        Clip(name: "midi", startBeat: 0, lengthBeats: 8, notes: [
            MIDINote(pitch: 60, velocity: 127, startBeat: 1, lengthBeats: lengthBeats),
        ])
    }

    @Test("registry lists Apple's stock music devices ('dls ' and 'msyn', type aumu)")
    func auRegistryListsAppleMusicDevices() {
        let devices = AUHostRegistry.listMusicDevices()
        print("[measured] \(devices.count) installed music devices: "
              + devices.map { "\($0.name) (\($0.component.subType)/\($0.component.manufacturer))" }
                       .joined(separator: ", "))
        #expect(devices.contains { $0.component == Self.dls })
        #expect(devices.contains { $0.component == Self.msyn })
        #expect(devices.allSatisfy { $0.component.type == "aumu" })
    }

    /// Renders a 3 s pass of the p60 v127 note (onset beat 1) through the
    /// given component and asserts the shared onset-energy contract.
    private func assertRendersEnergyAtOnset(component: AudioUnitComponentID) async throws {
        let track = auTrack(component: component, clips: [noteClip(lengthBeats: 2)])
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [track])
        #expect(renderer.auRegistry.status[track.id] == .ready)
        let audio = try renderer.render(tracks: [track], tempoBPM: 120,
                                        fromBeat: 0, durationSeconds: 3.0)
        let left = audio.channelData[0]

        let prePeak = TestSignals.peak(left, in: 0..<24_000)
        let bodyRMS = TestSignals.rms(left, in: 24_000..<28_800)
        let preOnsetRMS = TestSignals.rms(left, in: 23_488..<24_000)
        let postOnsetRMS = TestSignals.rms(left, in: 24_000..<24_512)
        print("[measured] \(component.subType) pre-peak \(prePeak), body RMS[24000,28800] \(bodyRMS), "
              + "onset edge RMS \(preOnsetRMS) → \(postOnsetRMS)")
        #expect(prePeak < 1e-4)          // silent before the scheduled onset
        #expect(bodyRMS > 0.005)         // audible note body
        #expect(preOnsetRMS < 1e-4)      // onset lands AT frame 24000 …
        #expect(postOnsetRMS > 1e-3)     // … not before, not much after
    }

    @Test("DLSMusicDevice renders energy exactly at the scheduled onset")
    func dlsRendersEnergyAtScheduledOnset() async throws {
        try await assertRendersEnergyAtOnset(component: Self.dls)
    }

    @Test("AUMIDISynth renders energy at the scheduled onset")
    func auMidiSynthRendersEnergy() async throws {
        try await assertRendersEnergyAtOnset(component: Self.msyn)
    }

    @Test("noteOff reaches the DLS: a short note has decayed where a held note still sounds")
    func dlsNoteOffProducesDecay() async throws {
        func render(noteLengthBeats: Double) async throws -> [Float] {
            let track = auTrack(component: Self.dls,
                                clips: [noteClip(lengthBeats: noteLengthBeats)])
            let renderer = OfflineRenderer()
            await renderer.prepareAudioUnits(tracks: [track])
            let audio = try renderer.render(tracks: [track], tempoBPM: 120,
                                            fromBeat: 0, durationSeconds: 4.0)
            return audio.channelData[0]
        }
        // Off at beat 1.5 vs held through beat 8; compare 2.0–2.5 s (past the
        // short note's release, inside the long note's sustain).
        let short = try await render(noteLengthBeats: 0.5)
        let long = try await render(noteLengthBeats: 7)
        let window = 96_000..<120_000
        let shortRMS = TestSignals.rms(short, in: window)
        let longRMS = TestSignals.rms(long, in: window)
        print("[measured] DLS decay window RMS: short-note \(shortRMS), held-note \(longRMS)")
        #expect(shortRMS < 0.5 * longRMS)
    }

    @Test("reset() (CC123+CC120) silences held DLS voices at the adapter level")
    func auResetSilencesHeldVoices() async throws {
        let registry = AUHostRegistry()
        let track = auTrack(component: Self.dls)
        await registry.prepare(track: track, sampleRate: 48_000)
        let instrument = try #require(registry.preparedInstrument(forTrack: track.id))

        let quantum = 4_096
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(quantum)))
        buffer.frameLength = AVAudioFrameCount(quantum)
        let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        func renderQuantum(events: [ScheduledMIDIEvent], renderStart: Int64) -> Float {
            events.withUnsafeBufferPointer { slice in
                instrument.render(events: slice, renderStart: renderStart,
                                  frameCount: quantum, output: output)
            }
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                                    count: quantum))
            return TestSignals.rms(samples, in: 0..<quantum)
        }

        // noteOn at frame 0, never released → the quantum carries energy.
        let held = renderQuantum(events: [ScheduledMIDIEvent(
            sampleTime: 0, noteID: 0, kind: ScheduledMIDIEvent.noteOn,
            pitch: 60, velocity: 127)], renderStart: 0)
        print("[measured] DLS held-voice quantum RMS: \(held)")
        #expect(held > 1e-3)

        // reset, then 24 empty quanta (~2 s) for the kill to fully take.
        instrument.reset()
        var final: Float = 0
        for index in 1...24 {
            final = renderQuantum(events: [], renderStart: Int64(index * quantum))
        }
        print("[measured] DLS post-reset final quantum RMS: \(final)")
        #expect(final < 1e-3)
    }

    @Test("a missing component renders exact silence and reports .missing")
    func missingAudioUnitRendersSilenceAndReportsStatus() async throws {
        let track = auTrack(component: AudioUnitComponentID(subType: "zzzz", manufacturer: "zzzz"),
                            clips: [noteClip(lengthBeats: 2)])
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [track])
        #expect(renderer.auRegistry.status[track.id] == .missing)
        let audio = try renderer.render(tracks: [track], tempoBPM: 120,
                                        fromBeat: 0, durationSeconds: 1.0)
        for channel in audio.channelData {
            #expect(TestSignals.peak(channel, in: 0..<channel.count) == 0)  // exact zeros
        }
    }

    @Test("a hung instantiation times out to .failed and no instrument")
    func instantiationTimeoutFallsBackToSilence() async throws {
        let registry = AUHostRegistry()
        registry.instantiator = { _, _ in
            // Simulates a stalled (v3 XPC) component: never returns.
            try await Task.sleep(for: .seconds(3_600))
            throw CancellationError()
        }
        let track = auTrack(component: Self.dls)
        await registry.prepare(track: track, sampleRate: 48_000,
                               timeout: .milliseconds(100))
        guard case .failed(let reason)? = registry.status[track.id] else {
            Issue.record("expected .failed, got \(String(describing: registry.status[track.id]))")
            return
        }
        print("[measured] timeout failure reason: \(reason)")
        #expect(reason.contains("timed out"))
        #expect(registry.preparedInstrument(forTrack: track.id) == nil)
    }

    @Test("captured fullState restores into a fresh AUSampler (.ready)")
    func fullStateRestoresIntoAUSampler() async throws {
        let registry = AUHostRegistry()
        var track = auTrack(component: Self.samp)
        await registry.prepare(track: track, sampleRate: 48_000)
        #expect(registry.status[track.id] == .ready)
        let state = try #require(registry.instrumentState(forTrack: track.id))
        print("[measured] AUSampler fullStateForDocument: \(state.count) bytes (binary plist)")

        registry.releaseInstrument(forTrack: track.id)
        #expect(registry.preparedInstrument(forTrack: track.id) == nil)

        track.instrument?.audioUnit?.stateData = state
        await registry.prepare(track: track, sampleRate: 48_000)
        #expect(registry.status[track.id] == .ready)
        #expect(registry.preparedInstrument(forTrack: track.id) != nil)
    }
}
