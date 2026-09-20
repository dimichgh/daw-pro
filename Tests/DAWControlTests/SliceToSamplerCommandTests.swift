import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// An engine that detects onsets but does NOT implement the m32-b2 slice
/// seam — it inherits `AudioEngineControlling`'s THROWING default.
///
/// ⭐ This is the pin on the design's deliberate divergence from
/// `detectTransients` (which defaults to `[]`). A default that returned
/// `{sampleRate: 0, boundaryFrames: []}` would flow into the planner and make
/// zones with nonsense spans — a plausible-looking valid answer from an engine
/// that cannot answer.
@MainActor
final class SeamlessEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted
    var stubMarkers: [TransientMarker] = []

    func detectTransients(inFileAt url: URL, sensitivity: Double) async throws -> [TransientMarker] {
        stubMarkers
    }

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) {}
    func projectWillReplace() {}
    func clipGainChanged(trackID: UUID, clipID: UUID, gainDb: Double) {}
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

/// Control-protocol coverage for m32-b2 `clip.sliceToSampler` — the sample-flip
/// chop. Reuses `FakeTransientEngine` (ClipTransientCommandTests.swift), which
/// now also stubs the slice seam, and `FakeMedia` (ControlTests.swift, 2 s
/// file → 4 beats @ 120 BPM).
@MainActor
@Suite("Clip slice-to-sampler — control protocol (m32-b2)")
struct SliceToSamplerCommandTests {

    /// Onsets at 0.5 / 1.0 / 1.5 s inside the 2 s window → frames 22 050 /
    /// 44 100 / 66 150 at 44.1 kHz, beats 1 / 2 / 3 at 120 BPM.
    private func engineWithThreeOnsets() -> FakeTransientEngine {
        let engine = FakeTransientEngine()
        engine.stubMarkers = [
            TransientMarker(timeSeconds: 0.5, strength: 1.0),
            TransientMarker(timeSeconds: 1.0, strength: 0.4),
            TransientMarker(timeSeconds: 1.5, strength: 0.8),
        ]
        return engine
    }

    private func makeRouter(engine: (any AudioEngineControlling)? = nil)
        -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    private func addAudioClip(_ router: CommandRouter, atBeat: Double = 0,
                              path: String = "/tmp/Loop.wav") async throws
        -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string(path),
                     "atBeat": .number(atBeat)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    private func chop(_ router: CommandRouter, clipID: String,
                      _ extra: [String: JSONValue] = [:]) async -> ControlResponse {
        var p: [String: JSONValue] = ["clipId": .string(clipID)]
        p.merge(extra) { _, new in new }
        return await router.handle(ControlRequest(
            id: "x", command: "clip.sliceToSampler", params: p))
    }

    // MARK: - Happy path

    @Test("chops to a new sampler track with pads, MIDI and the full report")
    func happyPath() async throws {
        let engine = engineWithThreeOnsets()
        let (router, store) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)

        let response = await chop(router, clipID: clipID)
        #expect(response.ok)
        let result = try #require(response.result)
        let trackID = try #require(result["trackId"]?.stringValue)
        #expect(result["createdTrackId"]?.stringValue == trackID)
        #expect(result["sampleRate"]?.doubleValue == 44_100)
        #expect(result["frameCount"]?.doubleValue == 88_200)
        #expect(result["sliceCount"]?.doubleValue == 3)
        #expect(abs((result["headSeconds"]?.doubleValue ?? -1) - 0.5) < 1e-9)

        let slices = try #require(result["slices"]?.arrayValue)
        #expect(slices.count == 3)
        #expect(slices[0]["pitch"]?.doubleValue == 36)
        #expect(slices[0]["startFrame"]?.doubleValue == 22_050)
        #expect(slices[0]["endFrame"]?.doubleValue == 44_100)
        #expect(slices[0]["strength"]?.doubleValue == 1.0)
        #expect(abs((slices[0]["beat"]?.doubleValue ?? -1) - 1.0) < 1e-9)
        // The LAST pad reaches the file end, so endFrame is honestly absent.
        #expect(slices[2]["endFrame"] == nil)

        // The store actually holds a sampler with three single-note pads.
        let track = try #require(store.tracks.first { $0.id.uuidString == trackID })
        #expect(track.kind == .instrument)
        #expect(track.name == "Loop chops")
        let sampler = try #require(track.instrument?.sampler)
        #expect(track.instrument?.kind == .sampler)
        #expect(sampler.zones.count == 3)
        // gain 1, not the SamplerParams default 0.8 — the amp law is
        // velocity/127 × zone.gain × params.gain, so 0.8 would put the whole
        // reconstruction 1.94 dB under the record it reproduces.
        #expect(sampler.gain == 1)
        for (i, zone) in sampler.zones.enumerated() {
            #expect(zone.rootPitch == 36 + i)
            #expect(zone.minPitch == 36 + i)
            #expect(zone.maxPitch == 36 + i)
            #expect(zone.attack == 0)
            #expect(zone.release == 0.010)
            #expect(zone.gain == 1)
        }

        // The reconstruction MIDI clip replays the groove at velocity 127.
        let midiClipID = try #require(result["midiClipId"]?.stringValue)
        let midiClip = try #require(track.clips.first { $0.id.uuidString == midiClipID })
        let notes = try #require(midiClip.notes)
        #expect(notes.count == 3)
        #expect(notes.map(\.velocity) == [127, 127, 127])
        #expect(notes.map(\.pitch) == [36, 37, 38])
        #expect(abs(notes[0].startBeat - 1.0) < 1e-9)
        #expect(midiClip.startBeat == 0)

        // The SOURCE clip is untouched — read-only, the detectTransients posture.
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].id.uuidString == clipID)

        // The seam saw the CONDITIONED boundary list and the clamped window.
        #expect(engine.resolveCalls == 1)
        #expect(engine.lastBoundarySeconds == [0.5, 1.0, 1.5])
        #expect(abs((engine.lastSnapWindowSeconds ?? -1) - 0.003) < 1e-12)
    }

    @Test("a large discarded head warns; includeHead keeps it as pad 1")
    func headHandling() async throws {
        let engine = engineWithThreeOnsets()
        let (router, store) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        var response = await chop(router, clipID: clipID)
        var warnings = try #require(response.result?["warnings"]?.arrayValue)
        #expect(warnings.contains { $0.stringValue?.contains("includeHead") == true })

        _ = await router.handle(ControlRequest(id: "u", command: "edit.undo", params: [:]))
        response = await chop(router, clipID: clipID, ["includeHead": .bool(true)])
        #expect(response.result?["sliceCount"]?.doubleValue == 4)
        warnings = try #require(response.result?["warnings"]?.arrayValue)
        #expect(!warnings.contains { $0.stringValue?.contains("includeHead") == true })
        let created = try #require(response.result?["trackId"]?.stringValue)
        let track = try #require(store.tracks.first { $0.id.uuidString == created })
        #expect(track.instrument?.sampler?.zones.first?.startFrame == 0)
    }

    @Test("targetTrackId lands the pads on an existing instrument track")
    func explicitTarget() async throws {
        let engine = engineWithThreeOnsets()
        let (router, store) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let addInst = await router.handle(ControlRequest(
            id: "i", command: "track.add", params: ["kind": .string("instrument")]))
        let instID = try #require(addInst.result?["id"]?.stringValue)

        let response = await chop(router, clipID: clipID,
                                  ["targetTrackId": .string(instID)])
        #expect(response.ok)
        #expect(response.result?["trackId"]?.stringValue == instID)
        // No track was created, so the field is honestly absent.
        #expect(response.result?["createdTrackId"] == nil)
        let track = try #require(store.tracks.first { $0.id.uuidString == instID })
        #expect(track.instrument?.sampler?.zones.count == 3)
    }

    @Test("replacing a loaded sampler's zones is WARNED, never silent")
    func replacingZonesWarns() async throws {
        let engine = engineWithThreeOnsets()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let addInst = await router.handle(ControlRequest(
            id: "i", command: "track.add", params: ["kind": .string("instrument")]))
        let instID = try #require(addInst.result?["id"]?.stringValue)
        // `validateSamplerZones` checks the real filesystem (unlike
        // `clip.addAudio`, which routes through FakeMedia), so the pre-loaded
        // zone needs a file that actually exists.
        let existing = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m32b2-preload-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: existing.path, contents: Data([0, 1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: existing) }
        let preload = await router.handle(ControlRequest(
            id: "s", command: "track.setInstrument",
            params: ["trackId": .string(instID), "kind": .string("sampler"),
                     "sampler": .object([
                        "gain": .number(0.5),
                        "zones": .array([.object(["path": .string(existing.path)])])])]))
        #expect(preload.ok)

        let response = await chop(router, clipID: clipID,
                                  ["targetTrackId": .string(instID)])
        let warnings = try #require(response.result?["warnings"]?.arrayValue)
        #expect(warnings.contains { $0.stringValue?.contains("were replaced") == true })
        // A user's own output gain is PRESERVED, not overwritten — but the
        // level consequence for the reconstruction is named.
        #expect(warnings.contains { $0.stringValue?.contains("output gain is 0.5") == true })

        // POSITIVE CONTROL: chopping onto an EMPTY instrument track emits
        // neither sentence — noise is ignored, taking the warning that
        // mattered with it.
        let addInst2 = await router.handle(ControlRequest(
            id: "i2", command: "track.add", params: ["kind": .string("instrument")]))
        let instID2 = try #require(addInst2.result?["id"]?.stringValue)
        let clean = await chop(router, clipID: clipID,
                               ["targetTrackId": .string(instID2)])
        let cleanWarnings = try #require(clean.result?["warnings"]?.arrayValue)
        #expect(!cleanWarnings.contains { $0.stringValue?.contains("were replaced") == true })
        #expect(!cleanWarnings.contains { $0.stringValue?.contains("output gain") == true })
    }

    // MARK: - Modes

    @Test("divisions mode cuts N equal parts and never calls the detector")
    func divisionsMode() async throws {
        let engine = engineWithThreeOnsets()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let response = await chop(router, clipID: clipID,
                                  ["mode": .string("divisions"), "divisions": .number(4)])
        #expect(response.ok)
        #expect(response.result?["sliceCount"]?.doubleValue == 3)   // 3 interior boundaries
        #expect(engine.detectCalls == 0)                            // no detection paid for
        #expect(engine.lastBoundarySeconds == [0.5, 1.0, 1.5])
        let slices = try #require(response.result?["slices"]?.arrayValue)
        // No detector ran, so there is no strength to report.
        #expect(slices[0]["strength"] == nil)
    }

    @Test("grid mode cuts on the musical grid")
    func gridMode() async throws {
        let engine = engineWithThreeOnsets()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let response = await chop(router, clipID: clipID,
                                  ["mode": .string("grid"), "gridBeats": .number(1)])
        #expect(response.ok)
        #expect(engine.detectCalls == 0)
        // 120 BPM → beats 1/2/3 = 0.5/1.0/1.5 s.
        #expect(engine.lastBoundarySeconds == [0.5, 1.0, 1.5])
    }

    /// ⭐ The m12-c rejection is GRID-ONLY, and its positive control lives in
    /// this same test: `.transients` over the SAME multi-segment map must still
    /// SUCCEED. Transients and divisions are source-domain — seconds into a
    /// file, not beats on a timeline — so a tempo change cannot misplace them.
    /// Without the second half, a guard that rejected all three modes would
    /// pass the rejection half and look correct.
    @Test("⭐ grid REJECTS a tempo change inside the clip — transients does not")
    func gridModeRejectsTempoBoundary() async throws {
        let engine = engineWithThreeOnsets()
        let (router, store) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        // The clip is 2 s = 4 beats at 120 BPM; the change goes at beat 2,
        // strictly inside it. The map is set AFTER the clip is added so the
        // clip's own span stays the plain 0…4 the assertions assume.
        let setMap = await router.handle(ControlRequest(
            id: "m", command: "tempo.setMap", params: ["segments": .array([
                .object(["startBeat": .number(0), "bpm": .number(120)]),
                .object(["startBeat": .number(2), "bpm": .number(90)]),
            ])]))
        #expect(setMap.ok)
        // Control on the FIXTURE: prove the map really is non-constant across
        // the clip before reading anything into the refusal below.
        #expect(!store.transport.tempoMap.isConstant(from: 0, to: 4))

        let grid = await chop(router, clipID: clipID,
                              ["mode": .string("grid"), "gridBeats": .number(1)])
        #expect(!grid.ok)
        #expect(grid.error?.contains("spans a tempo change") == true)
        // Refused BEFORE the PCM pass — no file work is done to reach a no.
        #expect(engine.resolveCalls == 0)

        // The positive control.
        let transients = await chop(router, clipID: clipID)
        #expect(transients.ok)
        #expect(engine.lastBoundarySeconds == [0.5, 1.0, 1.5])
        #expect(engine.resolveCalls == 1)
    }

    // MARK: - Param surface

    @Test("unknown keys are rejected by name")
    func unknownKeys() async throws {
        let engine = engineWithThreeOnsets()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let response = await chop(router, clipID: clipID, ["padCount": .number(4)])
        #expect(!response.ok)
        #expect(response.error?.contains("'padCount'") == true)
        #expect(response.error?.contains("clip.sliceToSampler") == true)
    }

    @Test("⭐ mode-scoped params are REJECTED, not silently ignored")
    func modeScopedParams() async throws {
        let engine = engineWithThreeOnsets()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)

        var r = await chop(router, clipID: clipID,
                           ["mode": .string("divisions"), "divisions": .number(4),
                            "sensitivity": .number(0.7)])
        #expect(!r.ok)
        #expect(r.error?.contains("'sensitivity' only applies to mode 'transients'") == true)

        r = await chop(router, clipID: clipID, ["divisions": .number(4)])
        #expect(!r.ok)
        #expect(r.error?.contains("'divisions' only applies to mode 'divisions'") == true)

        r = await chop(router, clipID: clipID, ["gridBeats": .number(1)])
        #expect(!r.ok)
        #expect(r.error?.contains("'gridBeats' only applies to mode 'grid'") == true)

        r = await chop(router, clipID: clipID,
                       ["mode": .string("grid"), "gridBeats": .number(1),
                        "velocityFromStrength": .bool(true)])
        #expect(!r.ok)
        #expect(r.error?.contains("'velocityFromStrength' only applies") == true)

        // A mode that NEEDS its parameter and did not get it.
        r = await chop(router, clipID: clipID, ["mode": .string("divisions")])
        #expect(!r.ok)
        #expect(r.error?.contains("mode 'divisions' requires 'divisions'") == true)
        r = await chop(router, clipID: clipID, ["mode": .string("grid")])
        #expect(!r.ok)
        #expect(r.error?.contains("mode 'grid' requires 'gridBeats'") == true)
    }

    @Test("out-of-range knobs are field-named, and several report together")
    func knobValidation() async throws {
        let engine = engineWithThreeOnsets()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)

        var r = await chop(router, clipID: clipID, ["mode": .string("wibble")])
        #expect(!r.ok); #expect(r.error?.contains("'mode' must be one of") == true)

        r = await chop(router, clipID: clipID, ["baseNote": .number(200)])
        #expect(!r.ok); #expect(r.error?.contains("'baseNote' must be between 0 and 127") == true)

        r = await chop(router, clipID: clipID, ["snapWindowMs": .number(50)])
        #expect(!r.ok); #expect(r.error?.contains("'snapWindowMs' must be between 0 and 20") == true)

        r = await chop(router, clipID: clipID, ["maxSlices": .number(500)])
        #expect(!r.ok); #expect(r.error?.contains("'maxSlices' must be between 1 and 96") == true)

        r = await chop(router, clipID: clipID, ["sensitivity": .number(3)])
        #expect(!r.ok); #expect(r.error?.contains("'sensitivity' must be between 0 and 1") == true)

        // Two problems collect into ONE message.
        r = await chop(router, clipID: clipID,
                       ["baseNote": .number(200), "snapWindowMs": .number(50)])
        #expect(!r.ok)
        #expect(r.error?.contains("2 problems") == true)
    }

    @Test("a bad targetTrackId UUID is named")
    func badTargetUUID() async throws {
        let engine = engineWithThreeOnsets()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let r = await chop(router, clipID: clipID, ["targetTrackId": .string("nope")])
        #expect(!r.ok)
        #expect(r.error?.contains("'targetTrackId' is not a valid UUID") == true)
    }

    // MARK: - Rejections

    @Test("headless surfaces engineUnavailable")
    func headless() async throws {
        let (router, _) = makeRouter(engine: nil)
        let (_, clipID) = try await addAudioClip(router)
        let r = await chop(router, clipID: clipID)
        #expect(!r.ok)
        #expect(r.error?.contains("audio engine") == true)
    }

    @Test("⭐ an engine without the seam THROWS rather than fabricating a chop")
    func seamDefaultThrows() async throws {
        let engine = SeamlessEngine()
        engine.stubMarkers = [
            TransientMarker(timeSeconds: 0.5, strength: 1.0),
            TransientMarker(timeSeconds: 1.0, strength: 0.4),
        ]
        let (router, store) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let r = await chop(router, clipID: clipID)
        #expect(!r.ok)
        // ...and nothing was created. A `{sampleRate: 0}` default would have
        // produced a track full of nonsense zones and reported success.
        #expect(store.tracks.count == 1)
        #expect(store.tracks[0].kind == .audio)
    }

    @Test("a MIDI clip surfaces transientsRequireAudioClip verbatim")
    func midiClipRejected() async throws {
        let engine = engineWithThreeOnsets()
        let (router, _) = makeRouter(engine: engine)
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI", params: ["trackId": .string(trackID)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        let r = await chop(router, clipID: clipID)
        #expect(!r.ok)
        #expect(r.error?.contains("is a MIDI clip") == true)
    }

    @Test("a stretched clip and a pitched clip get DIFFERENT, actionable errors")
    func stretchAndPitchRejected() async throws {
        let engine = engineWithThreeOnsets()
        let (router, _) = makeRouter(engine: engine)
        let (trackID, clipID) = try await addAudioClip(router)

        _ = await router.handle(ControlRequest(
            id: "s", command: "clip.setStretch",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "ratio": .number(0.9)]))
        var r = await chop(router, clipID: clipID)
        #expect(!r.ok)
        #expect(r.error?.contains("non-identity time-stretch") == true)

        _ = await router.handle(ControlRequest(
            id: "s2", command: "clip.setStretch",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "ratio": .number(1), "semitones": .number(3)]))
        r = await chop(router, clipID: clipID)
        #expect(!r.ok)
        // ⭐ Its OWN sentence: telling someone to "un-stretch" a clip they
        // never stretched is a plausible-but-wrong answer.
        #expect(r.error?.contains("has a pitch shift") == true)
        #expect(r.error?.contains("raw source frames") == true)
    }

    @Test("a non-instrument targetTrackId names the kind it found")
    func nonInstrumentTarget() async throws {
        let engine = engineWithThreeOnsets()
        let (router, _) = makeRouter(engine: engine)
        let (audioTrackID, clipID) = try await addAudioClip(router)
        let r = await chop(router, clipID: clipID,
                           ["targetTrackId": .string(audioTrackID)])
        #expect(!r.ok)
        #expect(r.error?.contains("cannot host an instrument") == true)
    }

    @Test("no usable boundary surfaces audioQuantizeNoTransients and changes nothing")
    func noBoundaries() async throws {
        let engine = FakeTransientEngine()
        engine.stubMarkers = []
        let (router, store) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let r = await chop(router, clipID: clipID)
        #expect(!r.ok)
        #expect(r.error?.contains("usable transients") == true)
        #expect(store.tracks.count == 1)
    }

    @Test("⭐ too many pads REJECTS with the levers named and truncates NOTHING")
    func maxSlicesRejects() async throws {
        let engine = FakeTransientEngine()
        engine.stubMarkers = (1...12).map {
            TransientMarker(timeSeconds: Double($0) * 0.13, strength: 0.5)
        }
        let (router, store) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let r = await chop(router, clipID: clipID, ["maxSlices": .number(4)])
        #expect(!r.ok)
        #expect(r.error?.contains("maxSlices limit of 4") == true)
        #expect(r.error?.contains("never silently dropped") == true)
        #expect(store.tracks.count == 1)
        // The PCM seam is never reached — the refusal is paid for before it.
        #expect(engine.resolveCalls == 0)
        // POSITIVE CONTROL: the same onsets under a sufficient ceiling succeed
        // with EVERY pad present.
        let ok = await chop(router, clipID: clipID, ["maxSlices": .number(32)])
        #expect(ok.ok)
        #expect(ok.result?["sliceCount"]?.doubleValue == 12)
    }

    @Test("running past MIDI 127 REJECTS, naming the arithmetic")
    func midiRangeRejects() async throws {
        let engine = engineWithThreeOnsets()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let r = await chop(router, clipID: clipID, ["baseNote": .number(126)])
        #expect(!r.ok)
        #expect(r.error?.contains("MIDI stops at 127") == true)
    }

    // MARK: - Undo

    @Test("⚠️ TWO chops are TWO undo steps — no coalescing")
    func noUndoCoalescing() async throws {
        let engine = engineWithThreeOnsets()
        let (router, store) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)

        let first = await chop(router, clipID: clipID)
        let firstTrack = try #require(first.result?["trackId"]?.stringValue)
        let second = await chop(router, clipID: clipID)
        let secondTrack = try #require(second.result?["trackId"]?.stringValue)
        #expect(firstTrack != secondTrack)
        #expect(store.tracks.count == 3)              // source + two chop tracks

        // ⭐ ONE undo must remove ONLY the second chop. `performEdit` here
        // carries NO `key:`: coalescing is an 800 ms window meant for slider
        // scrubs, and two chops inside it would fold into one step, making the
        // FIRST chop unreachable.
        let undo = await router.handle(ControlRequest(id: "u", command: "edit.undo", params: [:]))
        #expect(undo.ok)
        #expect(store.tracks.count == 2)
        #expect(store.tracks.contains { $0.id.uuidString == firstTrack })
        #expect(!store.tracks.contains { $0.id.uuidString == secondTrack })
        // The first chop's pads and MIDI are intact.
        let survivor = try #require(store.tracks.first { $0.id.uuidString == firstTrack })
        #expect(survivor.instrument?.sampler?.zones.count == 3)
        #expect(survivor.clips.count == 1)

        // A second undo removes the first chop entirely — track, zones and clip
        // together, one step.
        _ = await router.handle(ControlRequest(id: "u2", command: "edit.undo", params: [:]))
        #expect(store.tracks.count == 1)
    }

    // MARK: - Snap reporting

    @Test("snapOffsetFrames and residualAmplitude are reported per pad")
    func snapReporting() async throws {
        let engine = engineWithThreeOnsets()
        engine.stubGeometry = SliceBoundaryGeometry(
            sampleRate: 44_100, frameCount: 88_200,
            boundaryFrames: [22_036, 44_100, 66_150],
            snapOffsetFrames: [-14, 0, 0],
            residualAmplitude: [0.0007, 0.31, 0.0])
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let response = await chop(router, clipID: clipID)
        let slices = try #require(response.result?["slices"]?.arrayValue)
        #expect(slices[0]["snapOffsetFrames"]?.doubleValue == -14)
        #expect(slices[0]["residualAmplitude"]?.doubleValue == 0.0007)
        // A stereo file with no simultaneous crossing reports honestly.
        #expect(slices[1]["residualAmplitude"]?.doubleValue == 0.31)
        // sourceSeconds is POST-snap, so it agrees with startFrame.
        #expect(slices[0]["startFrame"]?.doubleValue == 22_036)
        #expect(abs((slices[0]["sourceSeconds"]?.doubleValue ?? -1) - 22_036.0 / 44_100.0) < 1e-12)
    }

    @Test("⭐ a 48 kHz source produces DIFFERENT frames for the same seconds")
    func rateIsHonoured() async throws {
        func chopAt(rate: Double, frameCount: Int) async throws -> [Double] {
            let engine = engineWithThreeOnsets()
            engine.stubSampleRate = rate
            engine.stubFrameCount = frameCount
            let (router, _) = makeRouter(engine: engine)
            let (_, clipID) = try await addAudioClip(router)
            let response = await chop(router, clipID: clipID)
            let slices = try #require(response.result?["slices"]?.arrayValue)
            return slices.compactMap { $0["startFrame"]?.doubleValue }
        }
        let at441 = try await chopAt(rate: 44_100, frameCount: 88_200)
        let at480 = try await chopAt(rate: 48_000, frameCount: 96_000)
        #expect(at441 == [22_050, 44_100, 66_150])
        #expect(at480 == [24_000, 48_000, 72_000])
        #expect(at441 != at480)
    }

    // MARK: - Save/load round trip

    @Test("the chop survives project save → open → describeSampler")
    func roundTrip() async throws {
        let engine = engineWithThreeOnsets()
        let (router, store) = makeRouter(engine: engine)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m32b2-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `ProjectBundle.planMedia` COPIES each zone's source into the bundle,
        // so the round trip needs a source path that really exists — a zone
        // whose file is missing is saved without media and reloads with none.
        let source = dir.appendingPathComponent("Loop.wav")
        FileManager.default.createFile(atPath: source.path, contents: Data([0, 1, 2, 3]))

        let (_, clipID) = try await addAudioClip(router, path: source.path)
        let chopped = await chop(router, clipID: clipID)
        let trackID = try #require(chopped.result?["trackId"]?.stringValue)

        let path = dir.appendingPathComponent("chop.dawproj").path
        let saved = await router.handle(ControlRequest(
            id: "s", command: "project.save", params: ["path": .string(path)]))
        #expect(saved.ok)
        let opened = await router.handle(ControlRequest(
            id: "o", command: "project.open", params: ["path": .string(path)]))
        #expect(opened.ok)

        // The reopened project must still carry the frame spans and the
        // envelope — `SamplerZoneDocument` enumerates its fields explicitly,
        // so a field it does not know parses, plays, then VANISHES on save.
        let reopened = try #require(store.tracks.first { $0.instrument?.kind == .sampler })
        let zones = try #require(reopened.instrument?.sampler?.zones)
        #expect(zones.count == 3)
        #expect(zones[0].startFrame == 22_050)
        #expect(zones[0].endFrame == 44_100)
        #expect(zones[2].endFrame == nil)
        #expect(zones[0].attack == 0)
        #expect(zones[0].release == 0.010)

        let described = await router.handle(ControlRequest(
            id: "d", command: "instrument.describeSampler",
            params: ["trackId": .string(reopened.id.uuidString),
                     "offset": .number(0), "limit": .number(16)]))
        #expect(described.ok)
        let describedZones = try #require(described.result?["zones"]?.arrayValue)
        #expect(describedZones.count == 3)
        #expect(describedZones[0]["startFrame"]?.doubleValue == 22_050)
        #expect(describedZones[0]["endFrame"]?.doubleValue == 44_100)

        // ...and the merge-by-id path (m26-g) can still tweak ONE pad without
        // resending the others — the post-chop edit an agent actually makes.
        // (m26-g's merge-by-id lives as `sampler.zonePatches` INSIDE
        // `track.setInstrument`, not as a verb of its own.)
        let patched = await router.handle(ControlRequest(
            id: "p", command: "track.setInstrument",
            params: ["trackId": .string(reopened.id.uuidString),
                     "sampler": .object(["zonePatches": .array([.object([
                        "id": .string(zones[1].id.uuidString),
                        "maxPitch": .number(48), "tuneCents": .number(-50)])])])]))
        #expect(patched.ok)
        let after = await router.handle(ControlRequest(
            id: "d2", command: "instrument.describeSampler",
            params: ["trackId": .string(reopened.id.uuidString),
                     "offset": .number(0), "limit": .number(16)]))
        let afterZones = try #require(after.result?["zones"]?.arrayValue)
        #expect(afterZones[1]["maxPitch"]?.doubleValue == 48)
        #expect(afterZones[1]["tuneCents"]?.doubleValue == -50)
        // The untouched pads kept their spans, in order.
        #expect(afterZones[0]["startFrame"]?.doubleValue == 22_050)
        #expect(afterZones[2]["startFrame"]?.doubleValue == 66_150)
        _ = trackID

        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - muteSourceTrack (m39-pads)

    @Test("⭐⭐ the source track keeps playing by DEFAULT — the shipped meaning is unchanged")
    func muteDefaultsOffAndIsAdditive() async throws {
        let engine = engineWithThreeOnsets()
        let (router, store) = makeRouter(engine: engine)
        let (trackID, clipID) = try await addAudioClip(router)

        let response = await chop(router, clipID: clipID)
        #expect(response.ok)
        // ⚠️ THE ADDITIVE-ONLY LAW, MEASURED: an existing call must mean today
        // exactly what it meant before `muteSourceTrack` existed.
        #expect(response.result?["mutedTrackId"] == nil
                || response.result?["mutedTrackId"] == .null)
        #expect(response.result?["sourceTrackMuted"]?.boolValue == false)
        let source = try #require(store.tracks.first { $0.id.uuidString == trackID })
        #expect(source.isMuted == false)
    }

    @Test("⭐ muteSourceTrack:true mutes the source, in the SAME undo step as the chop")
    func muteSourceLandsInOneUndoStep() async throws {
        let engine = engineWithThreeOnsets()
        let (router, store) = makeRouter(engine: engine)
        let (trackID, clipID) = try await addAudioClip(router)
        let sourceID = try #require(UUID(uuidString: trackID))

        let response = await chop(router, clipID: clipID,
                                  ["muteSourceTrack": .bool(true)])
        #expect(response.ok)
        #expect(response.result?["mutedTrackId"]?.stringValue == trackID)
        #expect(response.result?["sourceTrackMuted"]?.boolValue == true)
        #expect(store.tracks.first { $0.id == sourceID }?.isMuted == true)
        // The chop really happened too.
        #expect(response.result?["sliceCount"]?.doubleValue == 3)

        // ⭐⭐ ONE UNDO PUTS BOTH BACK. Two edits would leave the original
        // audible under a keymap that no longer exists — a halfway state
        // nobody asked for.
        try store.undo()
        #expect(store.tracks.first { $0.id == sourceID }?.isMuted == false)
        #expect(store.tracks.contains { $0.kind == .instrument } == false)
    }

    @Test("⭐ muting the source works when the pads land on an EXISTING instrument track")
    func muteWorksOntoAnExistingTarget() async throws {
        // The two-track case — the one an agent reaches when it chops onto a
        // track it already made. The source is a DIFFERENT track, so the mute
        // applies and the pads stay audible.
        //
        // ⚠️⚠️ **THE SAME-TRACK CASE IS NOT TESTED HERE BECAUSE IT IS CURRENTLY
        // UNREACHABLE, AND THAT IS A FINDING RATHER THAN AN OMISSION.**
        // `ProjectStore.importAudio` guards `tracks[index].kind == .audio`
        // (ProjectStore.swift:4465), so no wire path can put an audio clip on
        // an instrument track — meaning `sourceTrackID == destinationID` cannot
        // arise today. The guard in `sliceClipToSampler` is kept as defensive
        // code (a future audio-on-instrument path would make it live
        // immediately, and its absence would silence the pads), and
        // `PadGridSiteTests` pins that it EXISTS since no behavioural test can.
        let engine = engineWithThreeOnsets()
        let (router, store) = makeRouter(engine: engine)
        let (audioTrackID, clipID) = try await addAudioClip(router)
        let addTrack = await router.handle(ControlRequest(
            id: "t2", command: "track.add", params: ["kind": .string("instrument")]))
        let instTrackID = try #require(addTrack.result?["id"]?.stringValue)

        let response = await chop(router, clipID: clipID,
                                  ["targetTrackId": .string(instTrackID),
                                   "muteSourceTrack": .bool(true)])
        #expect(response.ok)
        #expect(response.result?["mutedTrackId"]?.stringValue == audioTrackID)
        #expect(response.result?["sourceTrackMuted"]?.boolValue == true)
        // ⭐ AND THE PAD TRACK IS NOT MUTED — the whole point of muting the
        // source is that the pads are what you hear.
        #expect(store.tracks.first { $0.id.uuidString == instTrackID }?.isMuted == false)
        #expect(store.tracks.first { $0.id.uuidString == audioTrackID }?.isMuted == true)
    }

    @Test("⭐⭐ an ALREADY-muted source reports no mutedTrackId but IS inaudible")
    func alreadyMutedReportsBothFacts() async throws {
        // The combination a single boolean cannot express — and the reason
        // `sourceTrackMuted` is a second field rather than a spelling of the
        // first. A surface inferring audibility from `mutedTrackId` would tell
        // the user to go mute a track that is already silent.
        let engine = engineWithThreeOnsets()
        let (router, store) = makeRouter(engine: engine)
        let (trackID, clipID) = try await addAudioClip(router)
        let muted = await router.handle(ControlRequest(
            id: "m", command: "track.setMute",
            params: ["trackId": .string(trackID), "muted": .bool(true)]))
        #expect(muted.ok)

        let response = await chop(router, clipID: clipID,
                                  ["muteSourceTrack": .bool(true)])
        #expect(response.ok)
        #expect(response.result?["mutedTrackId"] == nil
                || response.result?["mutedTrackId"] == .null)
        #expect(response.result?["sourceTrackMuted"]?.boolValue == true)
        #expect(store.tracks.first { $0.id.uuidString == trackID }?.isMuted == true)
        let warnings = try #require(response.result?["warnings"]?.arrayValue)
        #expect(warnings.contains { ($0.stringValue ?? "").contains("already muted") })
    }

    @Test("muteSourceTrack rejects a non-boolean by name")
    func muteRejectsNonBoolean() async throws {
        let engine = engineWithThreeOnsets()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let response = await chop(router, clipID: clipID,
                                  ["muteSourceTrack": .string("yes")])
        #expect(!response.ok)
        #expect(response.error?.contains("'muteSourceTrack'") == true)
    }
}
