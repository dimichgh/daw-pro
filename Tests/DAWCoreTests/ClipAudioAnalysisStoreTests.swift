import Foundation
import Testing
@testable import DAWCore

// `ProjectStore.analyzeClipAudio` (m21-e, design-clip-analyze-audio §4):
// clipId-only forwarding to the engine seam with the clip's CURRENT source
// window, the §5 error taxonomy in store terms (MIDI rejection BEFORE the
// engine guard, teaching short-window rejection), the stretch/pitch echo +
// derived `playback` projection (present iff non-identity, nil-omitting wire
// shape), and the protocol default's throw-not-fabricate rule. Reuses the
// shared `FakeEngine` (CoreTests.swift) `analyzeAudioContentStub`.

@MainActor
@Suite("ProjectStore — analyzeClipAudio (m21-e)")
struct ClipAudioAnalysisStoreTests {

    private func projectError(_ body: () async throws -> Void) async -> ProjectError? {
        do { try await body(); return nil }
        catch let e as ProjectError { return e }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    /// A plausible engine result: A minor @ 120 BPM (what the fake "measured").
    private func stubAnalysis() -> AudioContentAnalysis {
        AudioContentAnalysis(
            durationSeconds: 8, windowStartSeconds: 0, sampleRate: 48_000,
            samplePeakDb: -3.1, rmsDb: -14.9,
            key: KeyEstimate(tonic: "A", mode: "minor", confidence: 0.82,
                             tonal: true,
                             alternatives: [KeyAlternative(tonic: "C", mode: "major",
                                                           score: 0.71)]),
            tempo: TempoEstimate(bpm: 120, confidence: 0.9, steady: true,
                                 beatOffsetSeconds: 0.113,
                                 alternates: [TempoAlternate(bpm: 60, score: 0.5)]),
            spectral: SpectralBalance(
                bands: [Double](repeating: -40, count: 24), centroidHz: 1_500,
                summary: SpectralSummary(subDb: -40, bassDb: -30, lowMidDb: -28,
                                         midDb: -25, highMidDb: -32, airDb: -45)),
            analyzerVersion: 1)
    }

    /// Store with one audio clip (default 120 BPM → 4 beats = 2 s window).
    private func audioStore(clip: Clip? = nil) -> (ProjectStore, FakeEngine, Clip) {
        let clip = clip ?? Clip(name: "Song", startBeat: 0, lengthBeats: 4,
                                audioFileURL: URL(fileURLWithPath: "/tmp/song.wav"))
        let track = Track(name: "Import", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])
        let engine = FakeEngine()
        engine.analyzeAudioContentStub = stubAnalysis()
        store.engine = engine
        return (store, engine, clip)
    }

    // 1. Happy path (identity clip): engine called with the clip's current
    //    source window; echo 1/0; playback OMITTED (nil → off the wire).
    @Test("identity clip: window forwarded, echo 1/0, playback omitted")
    func identityHappyPath() async throws {
        let clip = Clip(name: "Song", startBeat: 0, lengthBeats: 8,
                        audioFileURL: URL(fileURLWithPath: "/tmp/song.wav"),
                        startOffsetSeconds: 1.5)
        let (store, engine, _) = audioStore(clip: clip)

        let result = try await store.analyzeClipAudio(clipId: clip.id)
        // 8 beats at the default 120 BPM = 4 s of source (ratio 1), from the
        // clip's 1.5 s start offset.
        #expect(engine.analyzeAudioContentCalls.count == 1)
        #expect(engine.analyzeAudioContentCalls[0].url == clip.audioFileURL)
        #expect(engine.analyzeAudioContentCalls[0].windowStartSeconds == 1.5)
        #expect(abs(engine.analyzeAudioContentCalls[0].windowDurationSeconds - 4) < 1e-9)
        #expect(result.analysis == stubAnalysis())
        #expect(result.stretchRatio == 1)
        #expect(result.pitchShiftSemitones == 0)
        #expect(result.playback == nil)

        // Wire shape: identity result omits the playback key entirely, and
        // the Codable round-trips (wire-never-drifts).
        let data = try JSONEncoder().encode(result)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"playback\""))
        #expect(try JSONDecoder().decode(ClipAudioAnalysisResult.self, from: data) == result)
    }

    // 2. Non-identity clip: playback derived — bpm ÷ ratio, key transposed.
    @Test("stretched+shifted clip: playback bpm ÷ ratio, key transposed by integral shift")
    func playbackProjection() async throws {
        let clip = Clip(name: "Song", startBeat: 0, lengthBeats: 8,
                        audioFileURL: URL(fileURLWithPath: "/tmp/song.wav"),
                        stretchRatio: 2.0, pitchShiftSemitones: 3)
        let (store, engine, _) = audioStore(clip: clip)
        defer { _ = engine }  // store.engine is weak — keep the fake alive

        let result = try await store.analyzeClipAudio(clipId: clip.id)
        #expect(result.stretchRatio == 2.0)
        #expect(result.pitchShiftSemitones == 3)
        let playback = try #require(result.playback)
        #expect(playback.bpm == 60)          // 120 ÷ 2
        #expect(playback.keyTonic == "C")    // A + 3 semitones
        #expect(playback.keyMode == "minor")
    }

    // 3. Fractional pitch shift: no named key; bpm still projects.
    @Test("fractional pitch shift: playback key nil (honest), bpm still scaled")
    func fractionalShiftNoKey() async throws {
        let clip = Clip(name: "Song", startBeat: 0, lengthBeats: 8,
                        audioFileURL: URL(fileURLWithPath: "/tmp/song.wav"),
                        pitchShiftSemitones: 2.5)
        let (store, engine, _) = audioStore(clip: clip)
        defer { _ = engine }  // store.engine is weak — keep the fake alive

        let result = try await store.analyzeClipAudio(clipId: clip.id)
        let playback = try #require(result.playback)
        #expect(playback.bpm == 120)         // ratio 1
        #expect(playback.keyTonic == nil)
        #expect(playback.keyMode == nil)
    }

    // 4. MIDI clip rejected verbatim — BEFORE the engine guard (headless
    //    callers get the actionable error, the detectClipTransients order).
    @Test("MIDI clip rejected with analysisRequiresAudioClip verbatim, even headless")
    func midiRejectedHeadless() async {
        let midi = Clip(name: "m", startBeat: 0, lengthBeats: 8,
                        notes: [MIDINote(pitch: 60, startBeat: 0)])
        let track = Track(name: "Keys", kind: .instrument, clips: [midi])
        let store = ProjectStore(tracks: [track])   // NO engine attached

        let err = await projectError { _ = try await store.analyzeClipAudio(clipId: midi.id) }
        guard case .analysisRequiresAudioClip(let id)? = err, id == midi.id else {
            Issue.record("expected analysisRequiresAudioClip, got \(String(describing: err))")
            return
        }
        #expect(err?.errorDescription
                == "clip \(midi.id.uuidString) is a MIDI clip — clip.analyzeAudio applies only to audio clips (read MIDI notes directly for key and timing)")
    }

    // 5. Unknown id → clipNotFound.
    @Test("unknown clip id → clipNotFound")
    func unknownClip() async {
        let (store, _, _) = audioStore()
        let bogus = UUID()
        let err = await projectError { _ = try await store.analyzeClipAudio(clipId: bogus) }
        guard case .clipNotFound(let id)? = err, id == bogus else {
            Issue.record("expected clipNotFound, got \(String(describing: err))")
            return
        }
    }

    // 6. Audio clip, no engine → engineUnavailable (after clip validation).
    @Test("headless audio clip → engineUnavailable")
    func headlessEngineUnavailable() async {
        let clip = Clip(name: "Song", startBeat: 0, lengthBeats: 4,
                        audioFileURL: URL(fileURLWithPath: "/tmp/song.wav"))
        let track = Track(name: "Import", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])   // NO engine attached

        let err = await projectError { _ = try await store.analyzeClipAudio(clipId: clip.id) }
        guard case .engineUnavailable? = err else {
            Issue.record("expected engineUnavailable, got \(String(describing: err))")
            return
        }
    }

    // 7. Sub-second window → teaching invalidClipEdit, engine never called.
    @Test("window shorter than 1 s → teaching invalidClipEdit, no engine call")
    func shortWindowRejected() async {
        // 1 beat at 120 BPM = 0.5 s of source.
        let clip = Clip(name: "Stab", startBeat: 0, lengthBeats: 1,
                        audioFileURL: URL(fileURLWithPath: "/tmp/stab.wav"))
        let (store, engine, _) = audioStore(clip: clip)

        let err = await projectError { _ = try await store.analyzeClipAudio(clipId: clip.id) }
        guard case .invalidClipEdit(let message)? = err else {
            Issue.record("expected invalidClipEdit, got \(String(describing: err))")
            return
        }
        #expect(message.contains("too short to analyze"))
        #expect(message.contains("needs >= 1.0 s"))
        #expect(engine.analyzeAudioContentCalls.isEmpty)
    }

    // 8. Engine failure propagates (the analyzer's unreadable, verbatim).
    @Test("engine analysis errors propagate to the caller")
    func engineErrorPropagates() async {
        let (store, engine, clip) = audioStore()
        engine.analyzeAudioContentError = ProjectError.importFailed("unreadable")
        let err = await projectError { _ = try await store.analyzeClipAudio(clipId: clip.id) }
        guard case .importFailed? = err else {
            Issue.record("expected the engine's error verbatim, got \(String(describing: err))")
            return
        }
    }

    // 9. The protocol DEFAULT throws engineUnavailable — an engine without
    //    the capability must refuse, never fabricate an all-floors analysis.
    @Test("protocol default throws engineUnavailable (no fabricated analysis)")
    func protocolDefaultThrows() async {
        let engine = MinimalEngine()
        let err: ProjectError? = await {
            do {
                _ = try await engine.analyzeAudioContent(
                    inFileAt: URL(fileURLWithPath: "/tmp/song.wav"),
                    windowStartSeconds: 0, windowDurationSeconds: 10)
                return nil
            } catch let e as ProjectError { return e } catch { return nil }
        }()
        guard case .engineUnavailable? = err else {
            Issue.record("expected engineUnavailable from the default, got \(String(describing: err))")
            return
        }
    }
}

/// The smallest possible `AudioEngineControlling` conformer: implements ONLY
/// the members that have no protocol default, so `analyzeAudioContent`
/// resolves to the DEFAULT implementation under test (FakeEngine overrides
/// it and can't exercise the default).
@MainActor
private final class MinimalEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    func prepare() throws {}
    func shutdown() {}
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        throw ProjectError.engineUnavailable
    }
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(false)
    }
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        throw ProjectError.recordingFailed("minimal fake")
    }
    func stopRecording() {}
}
