import Foundation
import Testing
@testable import DAWCore

/// m23-bx-1 — **THE EXPORT MUST RENDER WHAT THE ENGINE IS PLAYING.**
///
/// The bug this suite exists to stop: a hosted Audio Unit's live state lives in
/// `AUHostRegistry`, never in the model. Nothing writes it back as the user
/// works — `au.setParam` persists "via save-time fullStateForDocument capture",
/// and edits made in the vendor's own plugin window never touch the model at
/// all. Every offline render used to prepare its AUs from
/// `track.instrument.audioUnit.stateData`, i.e. from whatever was last LOADED
/// or last SAVED. So the export rendered a patch the user had never heard.
///
/// MEASURED in the field before the fix (reference project, beats 256–277):
/// with a live Surge XT's Global Volume driven to 0, `render.mixdown` was
/// UNCHANGED at −39.0 LUFS (the stale patch) while a save — which already
/// captured live state — plus a reopen rendered −70.0 LUFS. The user's own
/// session showed the same split: export −12.9 LUFS against live playback
/// −22.26.
///
/// ⚠️ WHY THIS ASSERTS AT THE SEAM AND NOT ON AUDIO. The divergence is only
/// observable with a real third-party plugin instantiated (Surge XT/Dexed), so
/// an audio assertion here would be a plugin-installation test, green on this
/// machine and vacuous on any other. The fact that actually decides the bug is
/// *which bytes reach the renderer* — `OfflineRenderer.prepareAudioUnits`
/// prepares from exactly this field — so that is what is pinned, headlessly and
/// on every machine.
@Suite("m23-bx-1 — offline renders carry LIVE hosted-AU state")
@MainActor
struct LiveAudioUnitStateRenderTests {

    /// Bytes standing in for the patch the user is actually hearing.
    static let liveState = Data("LIVE-PATCH-the-user-can-hear".utf8)
    /// Bytes standing in for the last-saved patch sitting in the model.
    static let staleState = Data("STALE-PATCH-last-written-to-disk".utf8)

    /// Records the `tracks` array handed to every offline render seam, which
    /// is the whole point: the assertion is about what the renderer receives.
    final class TrackRecordingEngine: AudioEngineControlling {
        var isRunning = false
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var recordPermission: RecordPermission = .granted

        /// Every `tracks:` array any render seam was called with, in order.
        private(set) var renderedTrackSets: [[Track]] = []

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
            renderedTrackSets.append(tracks)
            return AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000,
                                 channelCount: 2)
        }

        func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL, format: DeliveryFormat) async throws -> AudioFileInfo {
            renderedTrackSets.append(tracks)
            return AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000,
                                 channelCount: 2)
        }

        func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
            renderedTrackSets.append(tracks)
            let frames = max(1, Int(durationSeconds * 48_000))
            let samples = [Float](repeating: 0.1, count: frames)
            return RenderedAudio(sampleRate: 48_000, channelData: [samples, samples])
        }

        func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: 1, sampleRate: 48_000, channelCount: 2)
        }

        func writeAudioFile(_ audio: RenderedAudio, to url: URL,
                            format: DeliveryFormat) throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: 1, sampleRate: 48_000, channelCount: 2)
        }
    }

    /// A session with ONE hosted-AU instrument track whose model `stateData`
    /// is deliberately STALE, plus a provider that reports the live bytes —
    /// exactly the divergence the field bug ran into.
    private static func makeSession()
        -> (ProjectStore, TrackRecordingEngine, UUID) {
        let engine = TrackRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Bass", kind: .instrument)
        _ = store.updateTrack(id: track.id) { candidate in
            candidate.instrument = InstrumentDescriptor(
                kind: .audioUnit,
                audioUnit: AudioUnitConfig(
                    component: AudioUnitComponentID(type: "aumu", subType: "SgXT",
                                                    manufacturer: "VmbA"),
                    name: "Surge XT",
                    stateData: staleState))
        }
        _ = try? store.addMIDIClip(toTrack: track.id, name: "Riff", atBeat: 0,
                                   lengthBeats: 4,
                                   notes: [MIDINote(pitch: 36, velocity: 100,
                                                    startBeat: 0, lengthBeats: 1)])
        // The engine holds a DIFFERENT patch from the model — the normal state
        // of affairs after any plugin-window edit or `au.setParam`.
        store.instrumentStateProvider = { id in id == track.id ? liveState : nil }
        return (store, engine, track.id)
    }

    /// The headline: a mixdown must prepare from the LIVE patch.
    @Test("render.mixdown carries live AU state, not the stale model bytes")
    func mixdownCarriesLiveState() async throws {
        let (store, engine, trackID) = Self.makeSession()
        _ = try await store.renderMixdown(toPath: NSTemporaryDirectory() + "/bx1-mix.wav",
                                          fromBeat: 0, durationSeconds: 1)
        let rendered = try #require(engine.renderedTrackSets.last)
        let bass = try #require(rendered.first { $0.id == trackID })
        #expect(bass.instrument?.audioUnit?.stateData == Self.liveState)
        #expect(bass.instrument?.audioUnit?.stateData != Self.staleState)
    }

    /// The deliverable bounce, the measured-loudness probe and the stem set all
    /// render the program too — a fix that repaired only `render.mixdown` would
    /// leave the same split in three other user-facing exports.
    @Test("bounce, loudness measurement and stems carry live AU state too")
    func everyOfflineRenderCarriesLiveState() async throws {
        for label in ["bounce", "measure", "stems"] {
            let (store, engine, trackID) = Self.makeSession()
            switch label {
            case "bounce":
                _ = try await store.renderBounce(toPath: NSTemporaryDirectory() + "/bx1-b.wav",
                                                 fromBeat: 0, durationSeconds: 1)
            case "measure":
                _ = try await store.measureLoudness(fromBeat: 0, durationSeconds: 1)
            default:
                _ = try await store.renderStems(
                    toDirectory: NSTemporaryDirectory() + "/bx1-stems-\(UUID().uuidString.prefix(6))",
                    fromBeat: 0, durationSeconds: 1, includeMixdown: true)
            }
            #expect(!engine.renderedTrackSets.isEmpty, "\(label) rendered nothing")
            for (index, set) in engine.renderedTrackSets.enumerated() {
                guard let bass = set.first(where: { $0.id == trackID }) else { continue }
                #expect(bass.instrument?.audioUnit?.stateData == Self.liveState,
                        "\(label) pass \(index) rendered stale AU state")
            }
        }
    }

    /// The fallback that keeps the fix safe: with no live state for the track
    /// (never prepared, or still preparing), the model's own bytes survive —
    /// the capture must never be able to ERASE a saved patch.
    @Test("a track with no live state keeps its saved bytes")
    func absentLiveStateKeepsModelBytes() async throws {
        let engine = TrackRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Pad", kind: .instrument)
        _ = store.updateTrack(id: track.id) { candidate in
            candidate.instrument = InstrumentDescriptor(
                kind: .audioUnit,
                audioUnit: AudioUnitConfig(
                    component: AudioUnitComponentID(type: "aumu", subType: "SgXT",
                                                    manufacturer: "VmbA"),
                    stateData: Self.staleState))
        }
        _ = try? store.addMIDIClip(toTrack: track.id, name: "Chord", atBeat: 0,
                                   lengthBeats: 4,
                                   notes: [MIDINote(pitch: 60, velocity: 90,
                                                    startBeat: 0, lengthBeats: 1)])
        store.instrumentStateProvider = { _ in nil }  // nothing prepared

        _ = try await store.renderMixdown(toPath: NSTemporaryDirectory() + "/bx1-none.wav",
                                          fromBeat: 0, durationSeconds: 1)
        let rendered = try #require(engine.renderedTrackSets.last)
        let pad = try #require(rendered.first { $0.id == track.id })
        #expect(pad.instrument?.audioUnit?.stateData == Self.staleState)
    }

    /// The seam itself, pinned by name: save and render must read ONE home, so
    /// they can never come to different conclusions about the same session.
    /// (`tracksWithLiveAudioUnitState` is that home — if someone reintroduces a
    /// second computation, this is the test that should be updated, not routed
    /// around.)
    @Test("save and render read the same captured-state seam")
    func saveAndRenderShareOneHome() async throws {
        let (store, _, trackID) = Self.makeSession()
        let captured = store.tracksWithLiveAudioUnitState()
        let bass = try #require(captured.first { $0.id == trackID })
        #expect(bass.instrument?.audioUnit?.stateData == Self.liveState)
        // The live MODEL is never mutated by the capture — a render must not
        // dirty the project or silently rewrite what a later save would store.
        #expect(store.tracks.first { $0.id == trackID }?
            .instrument?.audioUnit?.stateData == Self.staleState)
    }
}
