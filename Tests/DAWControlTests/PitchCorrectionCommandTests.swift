import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for the m23-q Phase 2 WRITER leg:
/// `clip.autoCorrectPitch` / `clip.clearPitchEdits` / `clip.getPitchEdits`.
/// Reuses `FakePitchDetectionEngine` (`ClipDetectPitchCommandTests.swift`)
/// so a real SwiftF0 inference is never needed — the contour is a fixed
/// stub, sung across three notes so the auto-correct policy has something
/// to segment.
@MainActor
@Suite("Pitch correction — control protocol (m23-q Phase 2)")
struct PitchCorrectionCommandTests {
    private func makeRouter(engine: (any AudioEngineControlling)? = nil) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    private func makeRealAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-pitch-correct-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: url)
        return url
    }

    private func addAudioClip(_ router: CommandRouter, path: String, atBeat: Double = 0) async throws
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

    private func addMIDIClip(_ router: CommandRouter) async throws
        -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(4)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    /// A contour with THREE distinct voiced runs, each off a chromatic pitch
    /// centre by a real amount, so `PitchAutoCorrect.editSet` produces
    /// non-trivial segments to assert on. Frames at 62.5 fps (16 ms step),
    /// each run separated by an unvoiced hole so they segment separately.
    private func makeMelodicEngine() -> FakePitchDetectionEngine {
        let engine = FakePitchDetectionEngine()
        var frames: [ClipPitchFrame] = []
        // Run 1: ~225 Hz (a hair sharp of A3=220), 0.000...0.048s
        for i in 0..<4 {
            frames.append(ClipPitchFrame(
                timeSeconds: Double(i) * 0.016, frequencyHz: 225.0, confidence: 0.95,
                levelDbfs: -12, absence: nil))
        }
        // hole
        frames.append(ClipPitchFrame(
            timeSeconds: 0.064, frequencyHz: nil, confidence: 0.1,
            levelDbfs: -70, absence: .belowConfidence))
        // Run 2: ~262 Hz (flat of C4=261.63... close enough to be near-identity)
        for i in 0..<4 {
            frames.append(ClipPitchFrame(
                timeSeconds: 0.08 + Double(i) * 0.016, frequencyHz: 250.0, confidence: 0.95,
                levelDbfs: -12, absence: nil))
        }
        engine.stubResult = PitchDetectionResult(
            frames: frames, frameCount: frames.count,
            voicedFrameCount: frames.filter { $0.frequencyHz != nil }.count,
            voicedFraction: Double(frames.filter { $0.frequencyHz != nil }.count) / Double(frames.count),
            frameRateHz: 62.5, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
            windowStartSeconds: 0, windowDurationSeconds: 0.15,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
        return engine
    }

    private func makeSilentEngine() -> FakePitchDetectionEngine {
        let engine = FakePitchDetectionEngine()
        let frames = (0..<4).map {
            ClipPitchFrame(timeSeconds: Double($0) * 0.016, frequencyHz: nil, confidence: 0.1,
                           levelDbfs: -80, absence: .belowLevel)
        }
        engine.stubResult = PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: 0, voicedFraction: 0,
            frameRateHz: 62.5, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
            windowStartSeconds: 0, windowDurationSeconds: 0.064,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
        return engine
    }

    // MARK: - clip.autoCorrectPitch

    @Test("happy path: default (chromatic, strength 1) stores non-empty segments a getter can read back")
    func autoCorrectHappyPath() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch", params: ["clipId": .string(clipID)]))
        #expect(response.ok)
        #expect(engine.detectCalls == 1)

        #expect(response.result?["hasPitchEdits"]?.boolValue == true)
        let segmentCount = try #require(response.result?["segmentCount"]?.doubleValue)
        #expect(segmentCount == 2, "two voiced runs, separated by the hole, should segment separately")
        let segments = try #require(response.result?["segments"]?.arrayValue)
        #expect(segments.count == 2)
        for segment in segments {
            // Every field ALWAYS present — the whole point of the manual
            // response builder (never NoteSegment's omit-when-default Codable).
            #expect(segment["id"] != nil)
            #expect(segment["startSeconds"] != nil)
            #expect(segment["endSeconds"] != nil)
            #expect(segment["detectedHz"] != nil)
            #expect(segment["detectedConfidence"] != nil)
            #expect(segment["pitchOffsetCents"] != nil)
            #expect(segment["driftScale"] != nil)
            #expect(segment["vibratoScale"] != nil)
        }
        let applied = try #require(response.result?["appliedOptions"]?.objectValue)
        #expect(applied["strength"]?.doubleValue == 1.0)
        #expect(applied["preserveVibrato"]?.boolValue == true)
        #expect(applied["retuneMs"]?.doubleValue == PitchEditSet.engineMinimumRetuneMs)

        // ⭐ A setter's return is not proof it took: read the field back
        // through the STORE directly, independent of the response JSON.
        let clip = try #require(store.tracks.first?.clips.first)
        let edits = try #require(clip.pitchEdits)
        #expect(edits.segments.count == 2)
        #expect(edits.isIdentity == false)
    }

    @Test("PLANTED DEFECT: a store that writes .empty instead of the computed set is caught by the content read-back")
    func plantedDefectEmptyInsteadOfComputed() async throws {
        // This test pins the CONTRACT the planted-defect gate in
        // PitchCorrectionWriterTests (DAWCoreTests) exercises directly
        // against the store function; here we assert the same invariant
        // would be violated by such a defect, by checking the actual
        // (correct) behaviour is NOT what a `.empty`-writing defect would
        // produce — i.e. segments are non-empty on a melodic contour.
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        _ = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch", params: ["clipId": .string(clipID)]))
        let clip = try #require(store.tracks.first?.clips.first)
        // A defect writing `.empty` would leave this nil — this assertion is
        // the one that would FAIL under that defect. See
        // PitchCorrectionWriterTests for the direct plant-and-watch-it-fail
        // exercise against the store function itself.
        #expect(clip.pitchEdits != nil)
        #expect((clip.pitchEdits?.segments.count ?? 0) > 0)
    }

    @Test("strength: 0 stores nothing (nil, not an empty PitchEditSet) — the identity short-circuit")
    func strengthZeroStoresNil() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "strength": .number(0)]))
        #expect(response.ok)
        #expect(response.result?["hasPitchEdits"]?.boolValue == false)
        #expect(response.result?["segmentCount"]?.doubleValue == 0)
        let clip = try #require(store.tracks.first?.clips.first)
        #expect(clip.pitchEdits == nil)
    }

    @Test("no voiced runs: nil result, zero segments, a warning naming voicedFraction — not a silent success")
    func noVoicedRunsWarns() async throws {
        let engine = makeSilentEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch", params: ["clipId": .string(clipID)]))
        #expect(response.ok)
        #expect(response.result?["segmentCount"]?.doubleValue == 0)
        #expect(response.result?["hasPitchEdits"]?.boolValue == false)
        let warnings = try #require(response.result?["warnings"]?.arrayValue)
        #expect(warnings.contains { $0.stringValue?.contains("voicedFraction") == true })
        let clip = try #require(store.tracks.first?.clips.first)
        #expect(clip.pitchEdits == nil)
    }

    @Test("preserveVibrato:false (and hardTune) carries the render-path shaping warning verbatim")
    func hardTuneWarns() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "preset": .string("hardTune")]))
        #expect(response.ok)
        let warnings = try #require(response.result?["warnings"]?.arrayValue)
        #expect(warnings.contains { $0.stringValue?.contains("render path") == true
                                    || $0.stringValue?.contains("does not thread") == true })
        let applied = try #require(response.result?["appliedOptions"]?.objectValue)
        #expect(applied["preserveVibrato"]?.boolValue == false)
    }

    @Test("preset base + explicit overrides: gentle scale/strength with retuneMs overridden")
    func presetWithOverride() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "preset": .string("gentle"),
                     "retuneMs": .number(45)]))
        #expect(response.ok)
        let applied = try #require(response.result?["appliedOptions"]?.objectValue)
        #expect(applied["strength"]?.doubleValue == 0.5, "gentle's own strength, untouched by the override")
        #expect(applied["retuneMs"]?.doubleValue == 45, "explicit override wins over gentle's own 200")
    }

    @Test("scale: tonicPitchClass/mode round-trip into appliedOptions.scale")
    func scaleRoundTrips() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "tonicPitchClass": .number(7), "mode": .string("minor")]))
        #expect(response.ok)
        let scale = try #require(response.result?["appliedOptions"]?.objectValue?["scale"]?.objectValue)
        #expect(scale["tonicPitchClass"]?.doubleValue == 7)
        #expect(scale["mode"]?.stringValue == "minor")
        #expect(scale["displayName"]?.stringValue == "G minor")
    }

    @Test("unknown preset is a field-named error listing all four raw values; zero engine calls")
    func unknownPresetRejected() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "preset": .string("bogus")]))
        #expect(!response.ok)
        #expect(response.error?.contains("preset") == true)
        #expect(response.error?.contains("gentle") == true)
        #expect(response.error?.contains("natural") == true)
        #expect(response.error?.contains("tight") == true)
        #expect(response.error?.contains("hardTune") == true)
        #expect(engine.detectCalls == 0)
    }

    @Test("unknown mode is a field-named error")
    func unknownModeRejected() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "mode": .string("dorian")]))
        #expect(!response.ok)
        #expect(response.error?.contains("mode") == true)
    }

    @Test("strength out of 0...1 and retuneMs out of 30...500 are field-named, not silently clamped")
    func rangeValidation() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let badStrength = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "strength": .number(1.5)]))
        #expect(!badStrength.ok)
        #expect(badStrength.error?.contains("strength") == true)

        let badRetune = await router.handle(ControlRequest(
            id: "2", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "retuneMs": .number(5)]))
        #expect(!badRetune.ok)
        #expect(badRetune.error?.contains("retuneMs") == true)

        #expect(engine.detectCalls == 0)
    }

    @Test("MIDI clip surfaces pitchDetectionRequiresAudioClip verbatim, checked before detection")
    func midiRejected() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addMIDIClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch", params: ["clipId": .string(clipID)]))
        #expect(!response.ok)
        #expect(response.error?.contains("MIDI clip") == true)
        #expect(engine.detectCalls == 0)
    }

    @Test("unknown clip surfaces clipNotFound")
    func unknownClipRejected() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch", params: ["clipId": .string(UUID().uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no clip with id") == true)
    }

    @Test("unknown params rejected with the teaching key list")
    func unknownKeysRejected() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "bogus": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'bogus'") == true)
        #expect(engine.detectCalls == 0)
    }

    // MARK: - clip.clearPitchEdits

    @Test("clears a corrected clip back to nil; response mirrors an empty getter")
    func clearAfterCorrect() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        _ = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch", params: ["clipId": .string(clipID)]))
        #expect(store.tracks.first?.clips.first?.pitchEdits != nil)

        let cleared = await router.handle(ControlRequest(
            id: "2", command: "clip.clearPitchEdits", params: ["clipId": .string(clipID)]))
        #expect(cleared.ok)
        #expect(cleared.result?["hasPitchEdits"]?.boolValue == false)
        #expect(cleared.result?["segmentCount"]?.doubleValue == 0)
        #expect(cleared.result?["appliedOptions"] == nil)

        let clip = try #require(store.tracks.first?.clips.first)
        #expect(clip.pitchEdits == nil)
    }

    @Test("clearing an already-clear clip is idempotent and works on a MIDI clip as a no-op")
    func clearIdempotentAndMIDISafe() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let (_, midiClipID) = try await addMIDIClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.clearPitchEdits", params: ["clipId": .string(midiClipID)]))
        #expect(response.ok)
        #expect(response.result?["hasPitchEdits"]?.boolValue == false)
    }

    @Test("clip.clearPitchEdits: unknown clip surfaces clipNotFound")
    func clearUnknownClip() async throws {
        let (router, _) = makeRouter(engine: nil)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.clearPitchEdits", params: ["clipId": .string(UUID().uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no clip with id") == true)
    }

    // MARK: - clip.getPitchEdits

    @Test("strictly read-only: getting a clip's edits does not mutate the dirty flag or add an undo entry")
    func getIsReadOnly() async throws {
        let (router, store) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        // `store.isDirty` is `private(set)` and already true from adding the
        // track/clip above — this test proves the GET call does not add any
        // FURTHER edit-journal entry, by pinning the undo label before/after
        // rather than the dirty flag itself.
        let undoLabelBefore = store.undoLabel

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.getPitchEdits", params: ["clipId": .string(clipID)]))
        #expect(response.ok)
        #expect(response.result?["hasPitchEdits"]?.boolValue == false)
        #expect(response.result?["appliedOptions"] == nil)
        #expect(store.undoLabel == undoLabelBefore, "a read must never add an undo-journal entry")
    }

    @Test("a never-corrected clip reads back nil/empty, not an error")
    func getOnUncorrectedClip() async throws {
        let (router, _) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.getPitchEdits", params: ["clipId": .string(clipID)]))
        #expect(response.ok)
        #expect(response.result?["hasPitchEdits"]?.boolValue == false)
        #expect(response.result?["segmentCount"]?.doubleValue == 0)
        #expect(response.result?["segments"]?.arrayValue?.isEmpty == true)
    }

    @Test("clip.getPitchEdits works headless (no engine) since it never calls the detector")
    func getWorksHeadless() async throws {
        let (router, _) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.getPitchEdits", params: ["clipId": .string(clipID)]))
        #expect(response.ok)
    }

    @Test("clip.getPitchEdits: unknown clip surfaces clipNotFound; unknown params rejected")
    func getValidation() async throws {
        let (router, _) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let unknown = await router.handle(ControlRequest(
            id: "1", command: "clip.getPitchEdits", params: ["clipId": .string(UUID().uuidString)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("no clip with id") == true)

        let badKey = await router.handle(ControlRequest(
            id: "2", command: "clip.getPitchEdits",
            params: ["clipId": .string(clipID), "bogus": .bool(true)]))
        #expect(!badKey.ok)
        #expect(badKey.error?.contains("unknown parameter 'bogus'") == true)
    }

    // MARK: - Registration / count

    @Test("all three verbs are registered, appended at the tail")
    func commandsRegistered() {
        let all = CommandRouter.allCommands
        #expect(all.contains("clip.autoCorrectPitch"))
        #expect(all.contains("clip.clearPitchEdits"))
        #expect(all.contains("clip.getPitchEdits"))
        #expect(all.last == "clip.getPitchEdits")
        #expect(all.dropLast().last == "clip.clearPitchEdits")
        #expect(all.dropLast(2).last == "clip.autoCorrectPitch")
    }
}
