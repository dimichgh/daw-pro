import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for the m23-q Phase 2 WRITER leg:
/// `clip.autoCorrectPitch` / `clip.clearPitchEdits` / `clip.getPitchEdits`,
/// plus the pitch-editor command-surface door's per-note writer pair,
/// `clip.setNotePitch` / `clip.splitNote` (m23-ap Phase 2, item p2-c,
/// `docs/design/2026-09-22-pitch-editor-ui.md` §9.1). Reuses
/// `FakePitchDetectionEngine` (`ClipDetectPitchCommandTests.swift`) so a real
/// SwiftF0 inference is never needed — the contour is a fixed stub, sung
/// across three notes so the auto-correct policy has something to segment.
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

    /// ONE voiced run, ~512ms long (32 frames at 16ms steps) — long enough
    /// that a MIDPOINT split leaves both halves comfortably over
    /// `PitchAutoCorrect.minimumNoteSeconds` (60ms), unlike `makeMelodicEngine`'s
    /// two ~64ms runs (built to prove TWO segments form, not to survive a
    /// split). `clip.splitNote`'s own tests read the ACTUAL returned
    /// `startSeconds`/`endSeconds` back rather than assuming these numbers,
    /// so this fixture only needs to be "long enough," not exact.
    private func makeLongNoteEngine() -> FakePitchDetectionEngine {
        let engine = FakePitchDetectionEngine()
        let frameCount = 32
        let frames = (0..<frameCount).map {
            ClipPitchFrame(timeSeconds: Double($0) * 0.016, frequencyHz: 220.0, confidence: 0.95,
                           levelDbfs: -12, absence: nil)
        }
        engine.stubResult = PitchDetectionResult(
            frames: frames, frameCount: frames.count,
            voicedFrameCount: frames.count, voicedFraction: 1.0,
            frameRateHz: 62.5, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
            windowStartSeconds: 0, windowDurationSeconds: 0.512,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
        return engine
    }

    /// Runs `clip.autoCorrectPitch` and hands back its `segments` array —
    /// the shared setup every `clip.setNotePitch`/`clip.splitNote` happy-path
    /// test starts from, since both verbs REQUIRE a stored table already on
    /// the clip (no pitch detection on either wire path).
    private func autoCorrectSegments(_ router: CommandRouter, clipID: String) async throws -> [JSONValue] {
        let response = await router.handle(ControlRequest(
            id: "ac", command: "clip.autoCorrectPitch", params: ["clipId": .string(clipID)]))
        #expect(response.ok)
        return try #require(response.result?["segments"]?.arrayValue)
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
            // The four keys the pitch-editor command-surface door added
            // (m23-ap Phase 2, item p2-c) — the C5a vibrato GENERATOR
            // (independent of `vibratoScale`'s multiplier) plus the
            // Phase-4 formant field it shipped beside, unechoed until now.
            #expect(segment["vibratoRateHz"] != nil)
            #expect(segment["vibratoDepthCents"] != nil)
            #expect(segment["vibratoOnsetSeconds"] != nil)
            #expect(segment["formantOffsetSemitones"] != nil)
            // Carried-but-unread Phase 3/4 fields, included for the same
            // "every field, always" completeness rule.
            #expect(segment["timeStartDeltaSeconds"] != nil)
            #expect(segment["timeEndDeltaSeconds"] != nil)
            #expect(segment["amplitudeDb"] != nil)
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

    // ✅ RETIRED/CHANGED 2026-09-24 (contour-to-render): this test used to be
    // named `hardTuneWarns` and pinned a render-path-shaping warning on
    // every hardTune write. That warning was TRUE the day it shipped (the
    // render built every curve with `contour: []`) and is FALSE now — the
    // render threads the detected contour through
    // (`PitchCorrectionPresets.swift`'s own doc holds the measured per-note
    // wander cut). The one remaining honest caveat (the detector
    // could not run AT RENDER TIME) is a render-time fact this WRITE-time
    // call cannot know in advance, and it already has its own channel — a
    // `clip-pitch-contour-unavailable` engine notice — so this response
    // carries no warning speculating about it. Renamed and re-pinned to the
    // new behaviour rather than deleted, so a future regression back to the
    // old constant-offset fallback still has a test that would need to
    // change to hide it.
    @Test("preserveVibrato:false (and hardTune) carries NO render-path warning — the contour now threads through")
    func hardTuneNoLongerWarns() async throws {
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
        #expect(!warnings.contains { $0.stringValue?.contains("render path") == true
                                     || $0.stringValue?.contains("does not thread") == true },
                "the old render-path-shaping warning must be GONE, not merely reworded")
        #expect(warnings.isEmpty, "a melodic contour with hardTune has nothing else to warn about")
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

    @Test("clip.getPitchEdits: handEditedSinceAutoCorrect answers the exact question autoCorrectPitch{replaceExisting:false} asks, in all three states")
    func getReportsHandEditedSinceAutoCorrect() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        // 1. Fresh clip, no table at all: false — nothing to lose, so
        //    nothing to warn about (the same "proceeds regardless" rule).
        let fresh = await router.handle(ControlRequest(
            id: "1", command: "clip.getPitchEdits", params: ["clipId": .string(clipID)]))
        #expect(fresh.result?["handEditedSinceAutoCorrect"]?.boolValue == false)

        // 2. Right after a preset pass, untouched since: false — switching
        //    presets must read as safe, matching PROCEEDS-on-untouched above.
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let untouched = await router.handle(ControlRequest(
            id: "2", command: "clip.getPitchEdits", params: ["clipId": .string(clipID)]))
        #expect(untouched.result?["handEditedSinceAutoCorrect"]?.boolValue == false)

        // 3. One note moved by hand since: true — matches the REFUSES test.
        let targetID = try #require(segments[0]["id"]?.stringValue)
        let edit = await router.handle(ControlRequest(
            id: "edit", command: "clip.setNotePitch",
            params: ["clipId": .string(clipID), "segmentId": .string(targetID), "cents": .number(75)]))
        #expect(edit.ok)
        let handEdited = await router.handle(ControlRequest(
            id: "3", command: "clip.getPitchEdits", params: ["clipId": .string(clipID)]))
        #expect(handEdited.result?["handEditedSinceAutoCorrect"]?.boolValue == true)

        // The field is not a one-off: clip.autoCorrectPitch's OWN response
        // carries it too (same builder, both call sites).
        let acResponse = await router.handle(ControlRequest(
            id: "4", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "replaceExisting": .bool(true)]))
        #expect(acResponse.result?["handEditedSinceAutoCorrect"]?.boolValue == false,
                 "a preset's own fresh output is never flagged against itself")
    }

    @Test("clip.getPitchEdits: hasTuningEdits is the PITCH half of hasPitchEdits — a clears-only clip reads true/false, a retuned clip reads true/true, an untouched clip reads false/false")
    func hasTuningEditsThreeStates() async throws {
        // 1. UNTOUCHED: never ran autoCorrectPitch at all — no stored table.
        let untouchedEngine = makeMelodicEngine()
        let (untouchedRouter, _) = makeRouter(engine: untouchedEngine)
        let untouchedFile = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: untouchedFile) }
        let (_, untouchedClipID) = try await addAudioClip(untouchedRouter, path: untouchedFile.path)
        let untouched = await untouchedRouter.handle(ControlRequest(
            id: "u", command: "clip.getPitchEdits", params: ["clipId": .string(untouchedClipID)]))
        #expect(untouched.ok, "\(untouched.error ?? "?")")
        #expect(untouched.result?["hasPitchEdits"]?.boolValue == false)
        #expect(untouched.result?["hasTuningEdits"]?.boolValue == false)

        // 2. RETUNED: a plain autoCorrectPitch pass leaves pitchOffsetCents
        //    genuinely non-zero (the setNotePitches fixture's own finding:
        //    the default strength-1 pass pulls a real, non-zero amount) —
        //    both true.
        let retunedEngine = makeMelodicEngine()
        let (retunedRouter, _) = makeRouter(engine: retunedEngine)
        let retunedFile = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: retunedFile) }
        let (_, retunedClipID) = try await addAudioClip(retunedRouter, path: retunedFile.path)
        _ = try await autoCorrectSegments(retunedRouter, clipID: retunedClipID)
        let retuned = await retunedRouter.handle(ControlRequest(
            id: "r", command: "clip.getPitchEdits", params: ["clipId": .string(retunedClipID)]))
        #expect(retuned.ok, "\(retuned.error ?? "?")")
        #expect(retuned.result?["hasPitchEdits"]?.boolValue == true)
        #expect(retuned.result?["hasTuningEdits"]?.boolValue == true)

        // 3. CLEARS-ONLY: autoCorrect, then bring EVERY note's pitch back
        //    to IDENTITY by hand (cents: 0 — driftScale/vibratoScale and
        //    every other pitch field are already at identity after a
        //    plain, default (preserveVibrato:true) pass: `shapeScale == 1`
        //    for a HELD part, `PitchCorrection.swift`'s own
        //    `segment(forPart:...)` — so zeroing cents alone makes every
        //    segment's `isPitchIdentity` true), THEN clear one note: the
        //    LEVEL half moves (hasPitchEdits), the PITCH half does not
        //    (hasTuningEdits stays false).
        let clearsEngine = makeMelodicEngine()
        let (clearsRouter, _) = makeRouter(engine: clearsEngine)
        let clearsFile = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: clearsFile) }
        let (_, clearsClipID) = try await addAudioClip(clearsRouter, path: clearsFile.path)
        let clearsSegments = try await autoCorrectSegments(clearsRouter, clipID: clearsClipID)
        for segment in clearsSegments {
            let id = try #require(segment["id"]?.stringValue)
            let zero = await clearsRouter.handle(ControlRequest(
                id: "z", command: "clip.setNotePitch",
                params: ["clipId": .string(clearsClipID), "segmentId": .string(id), "cents": .number(0)]))
            #expect(zero.ok, "\(zero.error ?? "?")")
        }
        let firstID = try #require(clearsSegments[0]["id"]?.stringValue)
        let clear = await clearsRouter.handle(ControlRequest(
            id: "c", command: "clip.setNoteCleared",
            params: ["clipId": .string(clearsClipID), "segmentIds": .array([.string(firstID)]),
                     "cleared": .bool(true)]))
        #expect(clear.ok, "\(clear.error ?? "?")")
        let clearsOnly = await clearsRouter.handle(ControlRequest(
            id: "co", command: "clip.getPitchEdits", params: ["clipId": .string(clearsClipID)]))
        #expect(clearsOnly.ok, "\(clearsOnly.error ?? "?")")
        #expect(clearsOnly.result?["hasPitchEdits"]?.boolValue == true,
                "a clear alone still trips hasPitchEdits — the level half")
        #expect(clearsOnly.result?["hasTuningEdits"]?.boolValue == false,
                "no pitch actually moved — the app's header would say NOTES EDITED, never TUNING APPLIED")
        // A setter's return is not proof it took: confirm every note
        // really is at identity pitch, read back from the RESPONSE table.
        let stored = try #require(clearsOnly.result?["segments"]?.arrayValue)
        for segment in stored {
            #expect(segment["pitchOffsetCents"]?.doubleValue == 0)
            #expect(segment["driftScale"]?.doubleValue == 1)
            #expect(segment["vibratoScale"]?.doubleValue == 1)
        }
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

    // MARK: - clip.setNotePitch

    @Test("happy path: forwards segmentId + the stored, post-clamp cents; the OTHER note is untouched")
    func setNotePitchHappyPath() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        #expect(segments.count == 2)
        let targetID = try #require(segments[0]["id"]?.stringValue)
        let otherID = try #require(segments[1]["id"]?.stringValue)
        // ⚠️ NOT necessarily 0: `makeMelodicEngine`'s second run is "close
        // enough to be near-identity," not exactly on a chromatic pitch, so
        // the default strength-1 auto-correct pass already pulled it by some
        // real (non-zero) amount. "Untouched" means "still whatever
        // auto-correct originally set," not "still 0" — read the ACTUAL
        // pre-edit value back rather than assuming one.
        let otherOriginalCents = try #require(segments[1]["pitchOffsetCents"]?.doubleValue)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setNotePitch",
            params: ["clipId": .string(clipID), "segmentId": .string(targetID), "cents": .number(50)]))
        #expect(response.ok)
        #expect(response.result?["segmentId"]?.stringValue == targetID)
        #expect(response.result?["pitchOffsetCents"]?.doubleValue == 50)
        #expect(response.result?["appliedOptions"] == nil, "setNotePitch never applied a whole-clip pass")

        // The FULL table comes back — the other note is present, unchanged.
        let afterSegments = try #require(response.result?["segments"]?.arrayValue)
        #expect(afterSegments.count == 2)
        let other = try #require(afterSegments.first { $0["id"]?.stringValue == otherID })
        #expect(other["pitchOffsetCents"]?.doubleValue == otherOriginalCents,
                "the note nobody touched stays at its pre-edit value")

        // ⭐ A setter's return is not proof it took: read the STORE directly.
        let clip = try #require(store.tracks.first?.clips.first)
        let stored = try #require(clip.pitchEdits?.segments.first { $0.id.uuidString == targetID })
        #expect(stored.pitchOffsetCents == 50)
    }

    @Test("clamps to +/-2400 and reads the STORED, post-clamp value back — never the number sent")
    func setNotePitchClampsAndReadsBack() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let targetID = try #require(segments[0]["id"]?.stringValue)

        let high = await router.handle(ControlRequest(
            id: "1", command: "clip.setNotePitch",
            params: ["clipId": .string(clipID), "segmentId": .string(targetID), "cents": .number(9999)]))
        #expect(high.ok)
        #expect(high.result?["pitchOffsetCents"]?.doubleValue == 2400)

        let low = await router.handle(ControlRequest(
            id: "2", command: "clip.setNotePitch",
            params: ["clipId": .string(clipID), "segmentId": .string(targetID), "cents": .number(-9999)]))
        #expect(low.ok)
        #expect(low.result?["pitchOffsetCents"]?.doubleValue == -2400)

        let clip = try #require(store.tracks.first?.clips.first)
        let stored = try #require(clip.pitchEdits?.segments.first { $0.id.uuidString == targetID })
        #expect(stored.pitchOffsetCents == -2400, "the STORE, not just the response, carries the clamped value")
    }

    /// ⭐ THE TASK-NAMED IDEMPOTENCY TEST: `cents` is the note's FINAL offset,
    /// never a delta. Sending 100 twice must read back 100 both times — a
    /// planted "apply as a delta" defect would read back 200 the second time.
    @Test("cents is ABSOLUTE, not a delta: sending 100 twice in a row still reads back 100")
    func setNotePitchIsAbsoluteNotDelta() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let targetID = try #require(segments[0]["id"]?.stringValue)

        for callID in ["1", "2"] {
            let response = await router.handle(ControlRequest(
                id: callID, command: "clip.setNotePitch",
                params: ["clipId": .string(clipID), "segmentId": .string(targetID), "cents": .number(100)]))
            #expect(response.ok)
            #expect(response.result?["pitchOffsetCents"]?.doubleValue == 100,
                    "call \(callID) must read back 100, not an accumulated value")
        }
        let clip = try #require(store.tracks.first?.clips.first)
        let stored = try #require(clip.pitchEdits?.segments.first { $0.id.uuidString == targetID })
        #expect(stored.pitchOffsetCents == 100, "the store must also show 100, not 200")
    }

    @Test("clip.setNotePitch: MIDI clip is refused, naming why, before any store mutation")
    func setNotePitchRejectsMIDIClip() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let (_, midiClipID) = try await addMIDIClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setNotePitch",
            params: ["clipId": .string(midiClipID), "segmentId": .string(UUID().uuidString),
                     "cents": .number(50)]))
        #expect(!response.ok)
        #expect(response.error?.contains("MIDI clip") == true)
        #expect(engine.detectCalls == 0, "no detection on this wire path, MIDI or not")
    }

    @Test("clip.setNotePitch: a clip with no stored table refuses, teaching clip.autoCorrectPitch as the fix")
    func setNotePitchRequiresStoredTable() async throws {
        let (router, _) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        // Deliberately never auto-corrected — `pitchEdits` is nil.

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setNotePitch",
            params: ["clipId": .string(clipID), "segmentId": .string(UUID().uuidString),
                     "cents": .number(50)]))
        #expect(!response.ok)
        #expect(response.error?.contains("clip.autoCorrectPitch") == true)
        #expect(response.error?.contains("no notes to edit yet") == true)
    }

    @Test("clip.setNotePitch: an unknown segmentId names how many notes the clip DOES carry")
    func setNotePitchUnknownSegmentRejected() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        _ = try await autoCorrectSegments(router, clipID: clipID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setNotePitch",
            params: ["clipId": .string(clipID), "segmentId": .string(UUID().uuidString),
                     "cents": .number(50)]))
        #expect(!response.ok)
        #expect(response.error?.contains("No note with id") == true)
        #expect(response.error?.contains("2 note(s)") == true, "must name the ACTUAL count on this clip")
    }

    @Test("clip.setNotePitch: unknown clip surfaces clipNotFound")
    func setNotePitchUnknownClipRejected() async throws {
        let (router, _) = makeRouter(engine: nil)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setNotePitch",
            params: ["clipId": .string(UUID().uuidString), "segmentId": .string(UUID().uuidString),
                     "cents": .number(50)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no clip with id") == true)
    }

    @Test("clip.setNotePitch: unknown params rejected with the teaching key list")
    func setNotePitchUnknownParamsRejected() async throws {
        let (router, _) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setNotePitch",
            params: ["clipId": .string(clipID), "segmentId": .string(UUID().uuidString),
                     "cents": .number(50), "bogus": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'bogus'") == true)
    }

    // MARK: - clip.splitNote

    @Test("happy path: splits at the midpoint, left keeps the parent id, right is found by set difference")
    func splitNoteHappyPath() async throws {
        let engine = makeLongNoteEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        #expect(segments.count == 1)
        let parentID = try #require(segments[0]["id"]?.stringValue)
        let start = try #require(segments[0]["startSeconds"]?.doubleValue)
        let end = try #require(segments[0]["endSeconds"]?.doubleValue)
        let midpoint = (start + end) / 2

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.splitNote",
            params: ["clipId": .string(clipID), "segmentId": .string(parentID),
                     "atSourceSeconds": .number(midpoint)]))
        #expect(response.ok)
        #expect(response.result?["leftSegmentId"]?.stringValue == parentID,
                "the LEFT half keeps the parent's own id")
        let rightID = try #require(response.result?["rightSegmentId"]?.stringValue)
        #expect(rightID != parentID, "the RIGHT half gets a NEW id")
        #expect(response.result?["segmentCount"]?.doubleValue == 2)

        let afterSegments = try #require(response.result?["segments"]?.arrayValue)
        #expect(afterSegments.count == 2)
        // ⚠️ Found by SET DIFFERENCE (both ids present in the returned table),
        // never by an assumed array position.
        let ids = Set(afterSegments.compactMap { $0["id"]?.stringValue })
        #expect(ids == [parentID, rightID])
        let left = try #require(afterSegments.first { $0["id"]?.stringValue == parentID })
        let right = try #require(afterSegments.first { $0["id"]?.stringValue == rightID })
        #expect(left["endSeconds"]?.doubleValue == midpoint)
        #expect(right["startSeconds"]?.doubleValue == midpoint)
        #expect(left["startSeconds"]?.doubleValue == start)
        #expect(right["endSeconds"]?.doubleValue == end)

        let clip = try #require(store.tracks.first?.clips.first)
        #expect(clip.pitchEdits?.segments.count == 2)
    }

    @Test("split carries every edit field the parent had onto BOTH halves")
    func splitCarriesEditFields() async throws {
        let engine = makeLongNoteEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let parentID = try #require(segments[0]["id"]?.stringValue)
        let start = try #require(segments[0]["startSeconds"]?.doubleValue)
        let end = try #require(segments[0]["endSeconds"]?.doubleValue)

        // Tune the note BEFORE splitting it.
        let tuned = await router.handle(ControlRequest(
            id: "1", command: "clip.setNotePitch",
            params: ["clipId": .string(clipID), "segmentId": .string(parentID), "cents": .number(75)]))
        #expect(tuned.ok)

        let response = await router.handle(ControlRequest(
            id: "2", command: "clip.splitNote",
            params: ["clipId": .string(clipID), "segmentId": .string(parentID),
                     "atSourceSeconds": .number((start + end) / 2)]))
        #expect(response.ok)
        let afterSegments = try #require(response.result?["segments"]?.arrayValue)
        for segment in afterSegments {
            #expect(segment["pitchOffsetCents"]?.doubleValue == 75,
                    "splitting an already-tuned note must not silently un-tune either half")
        }
    }

    @Test("clip.splitNote: refuses when a half would be under the 60ms floor, naming the note's own span")
    func splitNoteMinimumHalfRefused() async throws {
        let engine = makeLongNoteEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let parentID = try #require(segments[0]["id"]?.stringValue)
        let start = try #require(segments[0]["startSeconds"]?.doubleValue)

        // 10ms inside the start — the LEFT half would be 10ms, under the 60ms floor.
        let tooClose = start + 0.01
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.splitNote",
            params: ["clipId": .string(clipID), "segmentId": .string(parentID),
                     "atSourceSeconds": .number(tooClose)]))
        #expect(!response.ok)
        #expect(response.error?.contains("60 ms") == true)
        #expect(response.error?.contains("too short to split") == true)
        // Zero mutation: still one segment, unsplit.
        let clip = try #require(store.tracks.first?.clips.first)
        #expect(clip.pitchEdits?.segments.count == 1)
    }

    @Test("clip.splitNote: MIDI clip is refused, naming why")
    func splitNoteRejectsMIDIClip() async throws {
        let engine = makeLongNoteEngine()
        let (router, _) = makeRouter(engine: engine)
        let (_, midiClipID) = try await addMIDIClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.splitNote",
            params: ["clipId": .string(midiClipID), "segmentId": .string(UUID().uuidString),
                     "atSourceSeconds": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error?.contains("MIDI clip") == true)
    }

    @Test("clip.splitNote: a clip with no stored table refuses, teaching clip.autoCorrectPitch as the fix")
    func splitNoteRequiresStoredTable() async throws {
        let (router, _) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.splitNote",
            params: ["clipId": .string(clipID), "segmentId": .string(UUID().uuidString),
                     "atSourceSeconds": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error?.contains("clip.autoCorrectPitch") == true)
    }

    @Test("clip.splitNote: an unknown segmentId names how many notes the clip DOES carry")
    func splitNoteUnknownSegmentRejected() async throws {
        let engine = makeLongNoteEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        _ = try await autoCorrectSegments(router, clipID: clipID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.splitNote",
            params: ["clipId": .string(clipID), "segmentId": .string(UUID().uuidString),
                     "atSourceSeconds": .number(0.2)]))
        #expect(!response.ok)
        #expect(response.error?.contains("No note with id") == true)
    }

    @Test("clip.splitNote: unknown clip surfaces clipNotFound")
    func splitNoteUnknownClipRejected() async throws {
        let (router, _) = makeRouter(engine: nil)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.splitNote",
            params: ["clipId": .string(UUID().uuidString), "segmentId": .string(UUID().uuidString),
                     "atSourceSeconds": .number(0.2)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no clip with id") == true)
    }

    @Test("clip.splitNote: unknown params rejected with the teaching key list")
    func splitNoteUnknownParamsRejected() async throws {
        let (router, _) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.splitNote",
            params: ["clipId": .string(clipID), "segmentId": .string(UUID().uuidString),
                     "atSourceSeconds": .number(0.2), "bogus": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'bogus'") == true)
    }

    // MARK: - Registration / count

    @Test("all three m23-q Phase 2 verbs are registered, appended at the tail")
    func commandsRegistered() {
        let all = CommandRouter.allCommands
        #expect(all.contains("clip.autoCorrectPitch"))
        #expect(all.contains("clip.clearPitchEdits"))
        #expect(all.contains("clip.getPitchEdits"))
        #expect(all.last == "clip.getPitchEdits")
        #expect(all.dropLast().last == "clip.clearPitchEdits")
        #expect(all.dropLast(2).last == "clip.autoCorrectPitch")
    }

    /// `clip.setNotePitch`/`clip.splitNote` landed beside `clip.sliceToSampler`
    /// (an early-array sibling), NOT appended at the tail — a near-tail
    /// insertion was tried first and measured to break 99 `dropLast(N)` pins
    /// across 26 files; anchoring here breaks only plain `.count == N` pins.
    /// `clip.getPlayedPitch` (C-0c) joined the SAME cluster immediately after
    /// `clip.splitNote`, for the same reason.
    @Test("clip.setNotePitch, clip.splitNote and clip.getPlayedPitch are registered beside clip.sliceToSampler")
    func setNotePitchAndSplitNoteRegistered() throws {
        let all = CommandRouter.allCommands
        #expect(all.contains("clip.setNotePitch"))
        #expect(all.contains("clip.splitNote"))
        #expect(all.contains("clip.getPlayedPitch"))
        let anchor = try #require(all.firstIndex(of: "clip.sliceToSampler"))
        #expect(Array(all[(anchor + 1)...(anchor + 3)])
                == ["clip.setNotePitch", "clip.splitNote", "clip.getPlayedPitch"])
        #expect(all.last != "clip.setNotePitch")
        #expect(all.last != "clip.splitNote")
        #expect(all.last != "clip.getPlayedPitch")
    }

    // MARK: - clip.getPlayedPitch (C-0c)

    /// Reads `runs` back into the model's own `PitchPlayedLine.Point` shape,
    /// so a comparison test can use `Point`'s `Equatable` rather than reaching
    /// into `JSONValue` field by field at every call site.
    private func decodeWireRuns(_ runs: [JSONValue]) throws -> [[PitchPlayedLine.Point]] {
        try runs.map { run in
            try #require(run.arrayValue).map { point in
                PitchPlayedLine.Point(
                    sourceSeconds: try #require(point["sourceSeconds"]?.doubleValue),
                    editedSeconds: try #require(point["editedSeconds"]?.doubleValue),
                    sungMidi: try #require(point["sungMidi"]?.doubleValue),
                    playedMidi: try #require(point["playedMidi"]?.doubleValue))
            }
        }
    }

    /// **THE C-0c PLANTED-DEFECT GATE.** Calls `PitchPlayedLine.make`
    /// DIRECTLY on the clip the store already holds (the exact `renderPitchContour`
    /// + `make` sequence `ProjectStore.playedPitchLine` uses) and compares it,
    /// point for point, against `clip.getPlayedPitch`'s wire response. The
    /// named defect — "the verb builds its own curve WITHOUT the clip
    /// transpose" — is a SECOND curve-building path, and a second path can
    /// only agree with this comparison by accident: it must be run once with
    /// `pitchShiftSemitones == 0` and once with a real transpose, or a defect
    /// that only breaks the transposed case (exactly this one) goes unseen.
    private func assertGetPlayedPitchMatchesMakeDirectly(
        router: CommandRouter, store: ProjectStore, clipID: String
    ) async throws {
        let response = await router.handle(ControlRequest(
            id: "gpp-gate", command: "clip.getPlayedPitch", params: ["clipId": .string(clipID)]))
        #expect(response.ok, "clip.getPlayedPitch failed: \(response.error ?? "?")")
        let wireRuns = try decodeWireRuns(try #require(response.result?["runs"]?.arrayValue))

        let uuid = try #require(UUID(uuidString: clipID))
        let clip = try #require(store.tracks.lazy.flatMap(\.clips).first { $0.id == uuid })
        let inputs = await store.renderPitchContour(clipId: uuid)
        let expected = PitchPlayedLine.make(inputs: inputs, clip: clip, tempoMap: store.transport.tempoMap)

        #expect(wireRuns == expected.runs,
                "clip.getPlayedPitch must equal PitchPlayedLine.make on the SAME clip — a mismatch here means the wire built its own curve on a second path")
        #expect(response.result?["unresolvedNoteIds"]?.arrayValue?.count
                == expected.unresolvedSegmentIDsInWindow.count)
    }

    @Test("getPlayedPitch equals PitchPlayedLine.make directly, untransposed AND transposed (planted-defect gate)")
    func getPlayedPitchMatchesMakeDirectly() async throws {
        for semitones in [0.0, 2.0, -3.5] {
            let engine = makeMelodicEngine()
            let (router, store) = makeRouter(engine: engine)
            let fileURL = try makeRealAudioFile()
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let (trackID, clipID) = try await addAudioClip(router, path: fileURL.path)
            _ = try await autoCorrectSegments(router, clipID: clipID)
            if semitones != 0 {
                let stretch = await router.handle(ControlRequest(
                    id: "stretch", command: "clip.setStretch",
                    params: ["trackId": .string(trackID), "clipId": .string(clipID),
                             "semitones": .number(semitones)]))
                #expect(stretch.ok, "semitones=\(semitones): \(stretch.error ?? "?")")
            }
            try await assertGetPlayedPitchMatchesMakeDirectly(router: router, store: store, clipID: clipID)
        }
    }

    @Test("getPlayedPitch: basis render, not decimated, on the small melodic fixture")
    func getPlayedPitchHappyPathShape() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        _ = try await autoCorrectSegments(router, clipID: clipID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.getPlayedPitch", params: ["clipId": .string(clipID)]))
        #expect(response.ok)
        #expect(response.result?["clipId"]?.stringValue == clipID)
        #expect(response.result?["basis"]?.stringValue == "render")
        #expect(response.result?["reason"] == nil, "no reason key on a real render basis")
        #expect(response.result?["decimated"]?.boolValue == false)
        let runs = try #require(response.result?["runs"]?.arrayValue)
        #expect(runs.count == 2, "two voiced runs, the hole between them stays a gap")
        let pointCount = try #require(response.result?["pointCount"]?.doubleValue)
        let totalPointCount = try #require(response.result?["totalPointCount"]?.doubleValue)
        #expect(pointCount == totalPointCount)
        #expect(pointCount == 8, "4 frames/run x 2 runs in makeMelodicEngine's fixture")
        _ = store
    }

    @Test("getPlayedPitch: a cleared note's span is a HOLE in runs — no point falls inside it, and every OTHER point is unchanged (I7b-2's one producer, PitchPlayedLine.make)")
    func getPlayedPitchHasNoPointOverAClearedNote() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        #expect(segments.count == 2)
        let clearedID = try #require(segments[0]["id"]?.stringValue)
        let clearedStart = try #require(segments[0]["startSeconds"]?.doubleValue)
        let clearedEnd = try #require(segments[0]["endSeconds"]?.doubleValue)

        func run(_ id: String) async throws -> ControlResponse {
            await router.handle(ControlRequest(
                id: id, command: "clip.getPlayedPitch", params: ["clipId": .string(clipID)]))
        }
        func inSpan(_ points: [PitchPlayedLine.Point]) -> [PitchPlayedLine.Point] {
            points.filter { $0.sourceSeconds >= clearedStart && $0.sourceSeconds < clearedEnd }
        }
        func outsideSpan(_ points: [PitchPlayedLine.Point]) -> [PitchPlayedLine.Point] {
            points.filter { !($0.sourceSeconds >= clearedStart && $0.sourceSeconds < clearedEnd) }
        }

        // BEFORE clearing: the positive control. Points DO exist over what
        // is about to become the cleared note's span.
        let before = try await run("before")
        #expect(before.ok, "\(before.error ?? "?")")
        let beforePoints = try decodeWireRuns(try #require(before.result?["runs"]?.arrayValue)).flatMap { $0 }
        #expect(!inSpan(beforePoints).isEmpty,
                "positive control: points exist over the soon-to-be-cleared span before clearing")

        let clear = await router.handle(ControlRequest(
            id: "clear", command: "clip.setNoteCleared",
            params: ["clipId": .string(clipID), "segmentIds": .array([.string(clearedID)]),
                     "cleared": .bool(true)]))
        #expect(clear.ok, "\(clear.error ?? "?")")

        let after = try await run("after")
        #expect(after.ok, "\(after.error ?? "?")")
        let afterPoints = try decodeWireRuns(try #require(after.result?["runs"]?.arrayValue)).flatMap { $0 }

        #expect(inSpan(afterPoints).isEmpty,
                "no point falls inside the cleared note's span — a hole, like an unvoiced gap")
        // Everything OUTSIDE the cleared span is UNCHANGED, value for value
        // — the invariance control that catches a cut in the wrong place.
        #expect(afterPoints == outsideSpan(beforePoints),
                "every point that was NOT inside the cleared span must be byte-identical to before clearing")
    }

    @Test("getPlayedPitch refuses a clip with no stored note table (teaching error)")
    func getPlayedPitchRefusesNoStoredTable() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        // Deliberately NOT calling clip.autoCorrectPitch — pitchEdits stays nil.

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.getPlayedPitch", params: ["clipId": .string(clipID)]))
        #expect(!response.ok)
        #expect(response.error?.contains("clip.autoCorrectPitch") == true)
    }

    @Test("getPlayedPitch refuses a MIDI clip")
    func getPlayedPitchRefusesMIDIClip() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addMIDIClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.getPlayedPitch", params: ["clipId": .string(clipID)]))
        #expect(!response.ok)
        #expect(response.error?.contains("MIDI clip") == true)
    }

    @Test("getPlayedPitch: unknown clip -> clipNotFound")
    func getPlayedPitchUnknownClip() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.getPlayedPitch", params: ["clipId": .string(UUID().uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no clip with id") == true)
    }

    @Test("getPlayedPitch: unrecognized parameter is rejected")
    func getPlayedPitchRejectsUnknownKey() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        _ = try await autoCorrectSegments(router, clipID: clipID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.getPlayedPitch",
            params: ["clipId": .string(clipID), "bogus": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'bogus'") == true)
    }

    @Test("getPlayedPitch decimates evenly, never drops a whole run, and SAYS SO — never silent")
    func getPlayedPitchDecimatesAndSaysSo() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        _ = try await autoCorrectSegments(router, clipID: clipID)

        // 8 total points (4/run x 2 runs); cap well under that to FORCE it.
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.getPlayedPitch",
            params: ["clipId": .string(clipID), "maxPoints": .number(3)]))
        #expect(response.ok)
        #expect(response.result?["decimated"]?.boolValue == true)
        #expect(response.result?["totalPointCount"]?.doubleValue == 8)
        let pointCount = try #require(response.result?["pointCount"]?.doubleValue)
        #expect(pointCount < 8, "fewer points than the undecimated total")
        #expect(pointCount > 0)
        let runs = try #require(response.result?["runs"]?.arrayValue)
        #expect(runs.count == 2, "decimation thins points inside a run, it never drops a whole run")
        for run in runs {
            #expect(try #require(run.arrayValue).count >= 1, "every run keeps at least one point")
        }

        // A default-sized cap over the same 8-point fixture must NOT decimate.
        let undecimated = await router.handle(ControlRequest(
            id: "2", command: "clip.getPlayedPitch", params: ["clipId": .string(clipID)]))
        #expect(undecimated.ok)
        #expect(undecimated.result?["decimated"]?.boolValue == false)
        #expect(undecimated.result?["pointCount"]?.doubleValue == 8)
    }

    @Test("getPlayedPitch: an explicit window returns full resolution (only points inside it, no decimation)")
    func getPlayedPitchWindowGivesFullResolution() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        _ = try await autoCorrectSegments(router, clipID: clipID)

        // Run 1 only: frames at 0.000...0.048s. Ask for [0, 0.06).
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.getPlayedPitch",
            params: ["clipId": .string(clipID), "fromSeconds": .number(0),
                     "durationSeconds": .number(0.06)]))
        #expect(response.ok)
        #expect(response.result?["decimated"]?.boolValue == false)
        let runs = try #require(response.result?["runs"]?.arrayValue)
        #expect(runs.count == 1, "the second run's frames (>= 0.08s) fall outside the window")
        #expect(try #require(runs.first?.arrayValue).count == 4)
        #expect(response.result?["fromSeconds"]?.doubleValue == 0)
        #expect(response.result?["durationSeconds"]?.doubleValue == 0.06)
    }

    @Test("getPlayedPitch: NO PITCH DETECTION on the wire path — an unresolved seam contour returns an honest empty estimate")
    func getPlayedPitchNoWireDetectionOnUnavailableContour() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        // autoCorrectPitch still runs its OWN detectPitch call (unaffected by
        // renderContourToReturn below) and mints a real stored table.
        _ = try await autoCorrectSegments(router, clipID: clipID)
        engine.renderContourToReturn = .unavailable(reason: "no model loaded")

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.getPlayedPitch", params: ["clipId": .string(clipID)]))
        #expect(response.ok)
        #expect(response.result?["basis"]?.stringValue == "estimate")
        #expect(response.result?["reason"]?.stringValue?.contains("no model loaded") == true)
        let runs = try #require(response.result?["runs"]?.arrayValue)
        #expect(runs.isEmpty, "no fallback detection is ever run on the wire path — an honest EMPTY estimate")
        #expect(response.result?["pointCount"]?.doubleValue == 0)
    }

    @Test("getPlayedPitch: fromSeconds/durationSeconds/maxPoints are validated")
    func getPlayedPitchValidatesWindowParams() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        _ = try await autoCorrectSegments(router, clipID: clipID)

        let badFrom = await router.handle(ControlRequest(
            id: "1", command: "clip.getPlayedPitch",
            params: ["clipId": .string(clipID), "fromSeconds": .number(-1)]))
        #expect(!badFrom.ok)

        let badDuration = await router.handle(ControlRequest(
            id: "2", command: "clip.getPlayedPitch",
            params: ["clipId": .string(clipID), "durationSeconds": .number(0)]))
        #expect(!badDuration.ok)

        let badMaxPointsZero = await router.handle(ControlRequest(
            id: "3", command: "clip.getPlayedPitch",
            params: ["clipId": .string(clipID), "maxPoints": .number(0)]))
        #expect(!badMaxPointsZero.ok)

        let badMaxPointsHuge = await router.handle(ControlRequest(
            id: "4", command: "clip.getPlayedPitch",
            params: ["clipId": .string(clipID), "maxPoints": .number(1_000_000)]))
        #expect(!badMaxPointsHuge.ok)
    }

    // MARK: - clip.autoCorrectPitch replaceExisting (C-F3, F22)

    @Test("autoCorrectPitch replaceExisting defaults to true — omitted forwards as undefined, stays additive")
    func autoCorrectPitchReplaceExistingDefaultsTrueAndStaysAdditive() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let targetID = try #require(segments[0]["id"]?.stringValue)

        // Hand-edit one note, so the table is no longer the preset's own output.
        let edit = await router.handle(ControlRequest(
            id: "edit", command: "clip.setNotePitch",
            params: ["clipId": .string(clipID), "segmentId": .string(targetID), "cents": .number(75)]))
        #expect(edit.ok)

        // Re-run auto-correct with NO replaceExisting key at all.
        let again = await router.handle(ControlRequest(
            id: "again", command: "clip.autoCorrectPitch", params: ["clipId": .string(clipID)]))
        #expect(again.ok, "today's default (omitted key) must stay additive/unconditional: \(again.error ?? "?")")

        // The hand edit is GONE — replaced, exactly as before this flag existed.
        let clip = try #require(store.tracks.first?.clips.first)
        let survivor = clip.pitchEdits?.segments.first { $0.id.uuidString == targetID }
        #expect(survivor?.pitchOffsetCents != 75, "the fresh pass replaced the hand edit, the unchanged default behaviour")
    }

    @Test("autoCorrectPitch replaceExisting:false refuses when the table has hand edits since the last auto-correct pass")
    func autoCorrectPitchReplaceExistingFalseRefusesOnHandEdits() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let targetID = try #require(segments[0]["id"]?.stringValue)

        let edit = await router.handle(ControlRequest(
            id: "edit", command: "clip.setNotePitch",
            params: ["clipId": .string(clipID), "segmentId": .string(targetID), "cents": .number(75)]))
        #expect(edit.ok)
        let beforeRefusal = try #require(store.tracks.first?.clips.first?.pitchEdits)

        let refused = await router.handle(ControlRequest(
            id: "refused", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "replaceExisting": .bool(false)]))
        #expect(!refused.ok)
        #expect(refused.error?.contains("replaceExisting:true") == true
                || refused.error?.contains("hand") == true)

        // Nothing was touched by the refusal.
        let afterRefusal = try #require(store.tracks.first?.clips.first?.pitchEdits)
        #expect(afterRefusal == beforeRefusal, "a refusal must not silently write anything")
    }

    @Test("autoCorrectPitch replaceExisting:false re-checks hand edits made WHILE detection was still running, not only before it started")
    func autoCorrectPitchReplaceExistingReChecksDuringDetectionGap() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let targetID = try #require(segments[0]["id"]?.stringValue)

        // The table is untouched since that pass, so the PRE-check (run
        // before detection starts) sees nothing to protect. Land the hand
        // edit DURING the second call's own detection instead, via the
        // fake's hook — simulating a drag released (or a concurrent
        // clip.setNotePitch) while this call was still waiting on the model,
        // the exact gap `autoCorrectClipPitch` opens between its pre-check
        // and its write.
        engine.beforeReturning = { [store] in
            let edited = try? store.setClipNotePitchOffset(
                clipId: UUID(uuidString: clipID)!, segmentId: UUID(uuidString: targetID)!,
                offsetCents: 321)
            #expect(edited != nil, "the injected mid-flight hand edit must itself land")
        }

        let refused = await router.handle(ControlRequest(
            id: "race", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "replaceExisting": .bool(false)]))
        #expect(!refused.ok, "a hand edit that landed WHILE detection ran must still be protected")
        #expect(refused.error?.contains("replaceExisting:true") == true)

        // The mid-flight hand edit survives — the refused write touched nothing.
        let after = try #require(store.tracks.first?.clips.first?.pitchEdits)
        let survivor = after.segments.first { $0.id.uuidString == targetID }
        #expect(survivor?.pitchOffsetCents == 321,
                 "the write must not have run at all — the mid-flight edit must survive verbatim")
        #expect(engine.detectCalls == 2, "detection DID run (the pre-check alone did not refuse) — proves this is the POST-detection re-check catching it, not the pre-check")
    }

    @Test("autoCorrectPitch replaceExisting:false PROCEEDS when the table is still exactly the last preset's own output (comparing presets never confirms)")
    func autoCorrectPitchReplaceExistingFalseProceedsWhenUntouchedSincePreset() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        _ = try await autoCorrectSegments(router, clipID: clipID)
        // No hand edit at all — the table is exactly what the pass above wrote.

        let again = await router.handle(ControlRequest(
            id: "again", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "preset": .string("tight"), "replaceExisting": .bool(false)]))
        #expect(again.ok, "switching presets on an untouched table must never be refused: \(again.error ?? "?")")
    }

    @Test("autoCorrectPitch replaceExisting:false PROCEEDS on a clip with no stored table at all")
    func autoCorrectPitchReplaceExistingFalseProceedsOnFreshClip() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "replaceExisting": .bool(false)]))
        #expect(response.ok, "a clip with nothing to lose proceeds regardless of the flag: \(response.error ?? "?")")
    }

    @Test("autoCorrectPitch: replaceExisting joins the accepted-key list")
    func autoCorrectPitchReplaceExistingAcceptedKey() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.autoCorrectPitch",
            params: ["clipId": .string(clipID), "replaceExisting": .bool(true)]))
        #expect(response.ok)
    }

    // MARK: - clip.setNoteCleared (I7a, interaction-batch design §10, ruled in §17)

    /// Each note's `cleared` flag off a wire table, keyed by id. `#require`
    /// on every note: the key is on the wire for EVERY segment, true or false
    /// (the FILE omits it when false; the wire does not).
    private func clearedFlags(_ segments: [JSONValue]) throws -> [String: Bool] {
        var flags: [String: Bool] = [:]
        for segment in segments {
            let id = try #require(segment["id"]?.stringValue)
            flags[id] = try #require(segment["cleared"]?.boolValue,
                                     "note \(id) carries no `cleared` key on the wire")
        }
        return flags
    }

    private func setNoteCleared(_ router: CommandRouter, clipID: String, _ ids: [String],
                                cleared: Bool) async -> ControlResponse {
        await router.handle(ControlRequest(
            id: "snc", command: "clip.setNoteCleared",
            params: ["clipId": .string(clipID), "segmentIds": .array(ids.map { .string($0) }),
                     "cleared": .bool(cleared)]))
    }

    @Test("clip.setNoteCleared: clears the named note, reads the STORED flag back, leaves the other alone, and clip.getPitchEdits echoes it")
    func setNoteClearedHappyPath() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        #expect(segments.count == 2)
        let targetID = try #require(segments[0]["id"]?.stringValue)
        let otherID = try #require(segments[1]["id"]?.stringValue)
        #expect(try clearedFlags(segments) == [targetID: false, otherID: false],
                "a never-cleared table must echo cleared:false on every note")

        let response = await setNoteCleared(router, clipID: clipID, [targetID], cleared: true)
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(response.result?["cleared"]?.boolValue == true)
        #expect(response.result?["segmentIds"]?.arrayValue?.compactMap(\.stringValue) == [targetID])
        #expect(response.result?["appliedOptions"] == nil, "a clear never applied a whole-clip pass")
        let after = try #require(response.result?["segments"]?.arrayValue)
        #expect(try clearedFlags(after) == [targetID: true, otherID: false])

        // ⭐ A setter's return is not proof it took: read the STORE directly.
        let stored = try #require(store.tracks.first?.clips.first?.pitchEdits)
        #expect(stored.segments.first { $0.id.uuidString == targetID }?.isCleared == true)
        #expect(stored.segments.first { $0.id.uuidString == otherID }?.isCleared == false)

        // The getter echoes the flag too, on every note.
        let get = await router.handle(ControlRequest(
            id: "g", command: "clip.getPitchEdits", params: ["clipId": .string(clipID)]))
        #expect(get.ok)
        #expect(try clearedFlags(try #require(get.result?["segments"]?.arrayValue))
                == [targetID: true, otherID: false])
    }

    /// A clip whose table bends nothing is not edited, and one cleared note
    /// makes it edited: the render has something to do. The wire's
    /// `hasPitchEdits` is `Clip.hasPitchEdits` itself (one predicate), and a
    /// Restore puts both flags back exactly.
    @Test("clip.setNoteCleared: a clear alone makes an unedited table an edit on the wire, and Restore undoes exactly that")
    func setNoteClearedAloneIsAnEdit() async throws {
        let (router, store) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let clipUUID = try #require(UUID(uuidString: clipID))
        // Seed a DETECTED-ONLY table through the store (a 0-cent write stores
        // the seed unchanged). The wire never seeds: it has no detector.
        let seed = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.1, endSeconds: 0.3, detectedHz: 220, detectedConfidence: 0.9),
            NoteSegment(startSeconds: 0.4, endSeconds: 0.6, detectedHz: 247, detectedConfidence: 0.9),
        ])
        _ = try store.setClipNotePitchOffset(clipId: clipUUID, segmentId: seed.segments[0].id,
                                             offsetCents: 0, seedIfAbsent: seed)
        let noteID = seed.segments[1].id.uuidString

        func readFlags() async throws -> (has: Bool?, identity: Bool?) {
            let get = await router.handle(ControlRequest(
                id: "g", command: "clip.getPitchEdits", params: ["clipId": .string(clipID)]))
            #expect(get.ok)
            return (get.result?["hasPitchEdits"]?.boolValue, get.result?["isIdentity"]?.boolValue)
        }
        let before = try await readFlags()
        #expect(before.has == false && before.identity == true,
                "CONTROL: a detected-only table must read as unedited")

        let cleared = await setNoteCleared(router, clipID: clipID, [noteID], cleared: true)
        #expect(cleared.ok, "\(cleared.error ?? "?")")
        #expect(cleared.result?["hasPitchEdits"]?.boolValue == true)
        let during = try await readFlags()
        #expect(during.has == true && during.identity == false,
                "a clear alone did not make the clip an edit: its render would be skipped")
        #expect(during.has == store.tracks.first?.clips.first?.hasPitchEdits,
                "the wire's hasPitchEdits is not Clip.hasPitchEdits")

        let restored = await setNoteCleared(router, clipID: clipID, [noteID], cleared: false)
        #expect(restored.ok)
        #expect(restored.result?["cleared"]?.boolValue == false)
        let after = try await readFlags()
        #expect(after.has == false && after.identity == true, "Restore did not return the clip to unedited")
    }

    /// ONE call for N notes is ONE undo step (design §17.8); a repeated id is
    /// folded; `segmentIds` echoes the notes named, deduplicated, in request
    /// order; undo restores every flag.
    @Test("clip.setNoteCleared: N notes in one call is ONE undo step, a repeated id is folded, and undo restores them all")
    func setNoteClearedIsOneUndoStep() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let first = try #require(segments[0]["id"]?.stringValue)
        let second = try #require(segments[1]["id"]?.stringValue)
        let depth = store.undoHistory().undo.count

        let response = await setNoteCleared(router, clipID: clipID, [second, first, second],
                                            cleared: true)
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(response.result?["segmentIds"]?.arrayValue?.compactMap(\.stringValue)
                == [second, first], "the notes named, deduplicated, in request order")
        #expect(response.result?["cleared"]?.boolValue == true)
        #expect(store.undoHistory().undo.count == depth + 1, "two notes must be ONE undo step")
        #expect(store.undoHistory().undo.first == "Clear Notes")

        #expect(try store.undo() == "Clear Notes")
        let stored = try #require(store.tracks.first?.clips.first?.pitchEdits)
        #expect(stored.segments.allSatisfy { !$0.isCleared }, "undo did not restore every note")
    }

    @Test("clip.setNoteCleared: a MIDI clip is refused, naming why, before any store mutation")
    func setNoteClearedRejectsMIDIClip() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let (_, midiClipID) = try await addMIDIClip(router)
        let response = await setNoteCleared(router, clipID: midiClipID, [UUID().uuidString],
                                            cleared: true)
        #expect(!response.ok)
        #expect(response.error?.contains("MIDI clip") == true)
        #expect(engine.detectCalls == 0, "no detection on this wire path")
    }

    @Test("clip.setNoteCleared: a clip with no stored table refuses, teaching clip.autoCorrectPitch as the fix")
    func setNoteClearedRequiresStoredTable() async throws {
        let (router, store) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let response = await setNoteCleared(router, clipID: clipID, [UUID().uuidString],
                                            cleared: true)
        #expect(!response.ok)
        #expect(response.error?.contains("clip.autoCorrectPitch") == true)
        #expect(response.error?.contains("no notes to edit yet") == true)
        #expect(store.tracks.first?.clips.first?.pitchEdits == nil, "the wire must never seed a table")
    }

    /// ALL OR NOTHING: an unknown id among real ones changes nothing, and the
    /// refusal names how many notes the clip does carry.
    @Test("clip.setNoteCleared: an unknown id among real ones changes nothing and names the clip's note count")
    func setNoteClearedUnknownSegmentChangesNothing() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let realID = try #require(segments[0]["id"]?.stringValue)
        let before = store.tracks.first?.clips.first?.pitchEdits
        let depth = store.undoHistory().undo.count

        let response = await setNoteCleared(router, clipID: clipID, [realID, UUID().uuidString],
                                            cleared: true)
        #expect(!response.ok)
        #expect(response.error?.contains("No note with id") == true)
        #expect(response.error?.contains("2 note(s)") == true, "must name the ACTUAL count on this clip")
        #expect(store.tracks.first?.clips.first?.pitchEdits == before,
                "a refused call cleared the real note anyway")
        #expect(store.undoHistory().undo.count == depth)
    }

    @Test("clip.setNoteCleared: parameters are validated in words (unknown clip or key, segmentIds shape, cleared required, empty list)")
    func setNoteClearedValidatesItsParameters() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let realID = try #require(segments[0]["id"]?.stringValue)

        func call(_ params: [String: JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(id: "v", command: "clip.setNoteCleared", params: params))
        }
        let unknownClip = await setNoteCleared(router, clipID: UUID().uuidString, [realID],
                                               cleared: true)
        #expect(unknownClip.error?.contains("no clip with id") == true)

        let unknownKey = await call(["clipId": .string(clipID), "segmentIds": .array([.string(realID)]),
                                     "cleared": .bool(true), "bogus": .bool(true)])
        #expect(unknownKey.error?.contains("unknown parameter 'bogus'") == true)

        let notAnArray = await call(["clipId": .string(clipID), "segmentIds": .string(realID),
                                     "cleared": .bool(true)])
        #expect(notAnArray.error?.contains("'segmentIds' must be an array") == true)

        let badUUID = await call(["clipId": .string(clipID),
                                  "segmentIds": .array([.string(realID), .string("not-a-uuid")]),
                                  "cleared": .bool(true)])
        #expect(badUUID.error?.contains("segmentIds[1] is not a valid UUID") == true)

        let noFlag = await call(["clipId": .string(clipID), "segmentIds": .array([.string(realID)])])
        #expect(noFlag.error?.contains("'cleared'") == true, "cleared has no default: a caller must say which way")

        let flagNotBool = await call(["clipId": .string(clipID), "segmentIds": .array([.string(realID)]),
                                      "cleared": .string("yes")])
        #expect(flagNotBool.error?.contains("'cleared'") == true)

        let empty = await call(["clipId": .string(clipID), "segmentIds": .array([]),
                                "cleared": .bool(true)])
        #expect(empty.error?.contains("Name at least one note to clear") == true)

        for response in [unknownClip, unknownKey, notAnArray, badUUID, noFlag, flagNotBool, empty] {
            #expect(!response.ok)
        }
    }

    /// Placed immediately after `clip.getPlayedPitch`, in the per-note door
    /// cluster beside `clip.sliceToSampler`, NOT at the tail, so every
    /// `dropLast(N)` window and the anchor + 1…+3 pin above stay true.
    @Test("clip.setNoteCleared is registered immediately after clip.getPlayedPitch, beside clip.sliceToSampler")
    func setNoteClearedRegistered() throws {
        let all = CommandRouter.allCommands
        let anchor = try #require(all.firstIndex(of: "clip.sliceToSampler"))
        #expect(all[anchor + 4] == "clip.setNoteCleared")
        #expect(all.filter { $0 == "clip.setNoteCleared" }.count == 1)
        #expect(all.last != "clip.setNoteCleared")
    }

    // MARK: - clip.setNoteGain (U-D, the per-note LEVEL verb)

    /// Each note's `amplitudeDb` off a wire table, keyed by id. `#require` on
    /// every note: the key is on the wire for EVERY segment, the
    /// `clearedFlags` idiom above.
    private func gainLevels(_ segments: [JSONValue]) throws -> [String: Double] {
        var levels: [String: Double] = [:]
        for segment in segments {
            let id = try #require(segment["id"]?.stringValue)
            levels[id] = try #require(segment["amplitudeDb"]?.doubleValue,
                                      "note \(id) carries no `amplitudeDb` key on the wire")
        }
        return levels
    }

    private func setNoteGain(_ router: CommandRouter, clipID: String, _ ids: [String],
                             gainDb: Double) async -> ControlResponse {
        await router.handle(ControlRequest(
            id: "sng", command: "clip.setNoteGain",
            params: ["clipId": .string(clipID), "segmentIds": .array(ids.map { .string($0) }),
                     "gainDb": .number(gainDb)]))
    }

    @Test("clip.setNoteGain: sets the named note's level, reads the STORED value back, leaves the other alone, and clip.getPitchEdits echoes it")
    func setNoteGainHappyPath() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        #expect(segments.count == 2)
        let targetID = try #require(segments[0]["id"]?.stringValue)
        let otherID = try #require(segments[1]["id"]?.stringValue)
        #expect(try gainLevels(segments) == [targetID: 0, otherID: 0],
                "a never-leveled table must echo amplitudeDb:0 on every note")

        let response = await setNoteGain(router, clipID: clipID, [targetID], gainDb: -6)
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(response.result?["gainDb"]?.doubleValue == -6)
        #expect(response.result?["segmentIds"]?.arrayValue?.compactMap(\.stringValue) == [targetID])
        #expect(response.result?["appliedOptions"] == nil, "a level set never applied a whole-clip pass")
        let after = try #require(response.result?["segments"]?.arrayValue)
        #expect(try gainLevels(after) == [targetID: -6, otherID: 0])

        // ⭐ A setter's return is not proof it took: read the STORE directly.
        let stored = try #require(store.tracks.first?.clips.first?.pitchEdits)
        #expect(stored.segments.first { $0.id.uuidString == targetID }?.amplitudeDb == -6)
        #expect(stored.segments.first { $0.id.uuidString == otherID }?.amplitudeDb == 0)

        // The getter echoes the level too, on every note.
        let get = await router.handle(ControlRequest(
            id: "g", command: "clip.getPitchEdits", params: ["clipId": .string(clipID)]))
        #expect(get.ok)
        #expect(try gainLevels(try #require(get.result?["segments"]?.arrayValue))
                == [targetID: -6, otherID: 0])
    }

    @Test("clip.setNoteGain: clamps to Clip.gainDbRange and reads the STORED, post-clamp value back — never the number sent")
    func setNoteGainClampsAndReadsBack() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let targetID = try #require(segments[0]["id"]?.stringValue)

        let high = await setNoteGain(router, clipID: clipID, [targetID], gainDb: 999)
        #expect(high.ok)
        #expect(high.result?["gainDb"]?.doubleValue == Clip.gainDbRange.upperBound)

        let low = await setNoteGain(router, clipID: clipID, [targetID], gainDb: -999)
        #expect(low.ok)
        #expect(low.result?["gainDb"]?.doubleValue == Clip.gainDbRange.lowerBound)

        let clip = try #require(store.tracks.first?.clips.first)
        let stored = try #require(clip.pitchEdits?.segments.first { $0.id.uuidString == targetID })
        #expect(stored.amplitudeDb == Clip.gainDbRange.lowerBound,
                "the STORE, not just the response, carries the clamped value")
    }

    /// A level alone makes an unedited table an edit on the wire — the
    /// `clip.setNoteCleared` "a clear alone" test, adapted: `isIdentity` is
    /// `segments.allSatisfy(.isIdentity)`, and `NoteSegment.isIdentity` reads
    /// `hasLevelEdits` (`isCleared || amplitudeDb != 0`), so a level write
    /// alone must flip it exactly as a clear does. Setting it back to 0 dB
    /// ("as sung") returns the clip to unedited — it is a level, not a clear.
    @Test("clip.setNoteGain: a level alone makes an unedited table an edit on the wire, and 0 dB undoes exactly that")
    func setNoteGainAloneIsAnEdit() async throws {
        let (router, store) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let clipUUID = try #require(UUID(uuidString: clipID))
        // Seed a DETECTED-ONLY table through the store (a 0-cent write stores
        // the seed unchanged). The wire never seeds: it has no detector.
        let seed = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.1, endSeconds: 0.3, detectedHz: 220, detectedConfidence: 0.9),
            NoteSegment(startSeconds: 0.4, endSeconds: 0.6, detectedHz: 247, detectedConfidence: 0.9),
        ])
        _ = try store.setClipNotePitchOffset(clipId: clipUUID, segmentId: seed.segments[0].id,
                                             offsetCents: 0, seedIfAbsent: seed)
        let noteID = seed.segments[1].id.uuidString

        func readFlags() async throws -> (has: Bool?, identity: Bool?) {
            let get = await router.handle(ControlRequest(
                id: "g", command: "clip.getPitchEdits", params: ["clipId": .string(clipID)]))
            #expect(get.ok)
            return (get.result?["hasPitchEdits"]?.boolValue, get.result?["isIdentity"]?.boolValue)
        }
        let before = try await readFlags()
        #expect(before.has == false && before.identity == true,
                "CONTROL: a detected-only table must read as unedited")

        let leveled = await setNoteGain(router, clipID: clipID, [noteID], gainDb: -6)
        #expect(leveled.ok, "\(leveled.error ?? "?")")
        #expect(leveled.result?["hasPitchEdits"]?.boolValue == true)
        let during = try await readFlags()
        #expect(during.has == true && during.identity == false,
                "a level alone did not make the clip an edit: its render would be skipped")
        #expect(during.has == store.tracks.first?.clips.first?.hasPitchEdits,
                "the wire's hasPitchEdits is not Clip.hasPitchEdits")

        let restored = await setNoteGain(router, clipID: clipID, [noteID], gainDb: 0)
        #expect(restored.ok)
        #expect(restored.result?["gainDb"]?.doubleValue == 0)
        let after = try await readFlags()
        #expect(after.has == false && after.identity == true, "0 dB did not return the clip to unedited")
    }

    /// ONE call for N notes is ONE undo step; a repeated id is folded;
    /// `segmentIds` echoes the notes named, deduplicated, in request order;
    /// undo restores every level.
    @Test("clip.setNoteGain: N notes in one call is ONE undo step, a repeated id is folded, and undo restores them all")
    func setNoteGainIsOneUndoStep() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let first = try #require(segments[0]["id"]?.stringValue)
        let second = try #require(segments[1]["id"]?.stringValue)
        let depth = store.undoHistory().undo.count

        let response = await setNoteGain(router, clipID: clipID, [second, first, second], gainDb: -4)
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(response.result?["segmentIds"]?.arrayValue?.compactMap(\.stringValue)
                == [second, first], "the notes named, deduplicated, in request order")
        #expect(response.result?["gainDb"]?.doubleValue == -4)
        #expect(store.undoHistory().undo.count == depth + 1, "two notes must be ONE undo step")
        #expect(store.undoHistory().undo.first == "Set Note Level")

        #expect(try store.undo() == "Set Note Level")
        let stored = try #require(store.tracks.first?.clips.first?.pitchEdits)
        #expect(stored.segments.allSatisfy { $0.amplitudeDb == 0 }, "undo did not restore every note")
    }

    @Test("clip.setNoteGain: a no-op journals nothing, and a repeated id is folded")
    func setNoteGainNoOpJournalsNothing() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let targetID = try #require(segments[0]["id"]?.stringValue)

        _ = await setNoteGain(router, clipID: clipID, [targetID], gainDb: -3)
        let depth = store.undoHistory().undo.count
        let response = await setNoteGain(router, clipID: clipID, [targetID], gainDb: -3)
        #expect(response.ok)
        #expect(store.undoHistory().undo.count == depth,
                "setting a note to the level it already carries must journal nothing")
    }

    @Test("clip.setNoteGain: a MIDI clip is refused, naming why, before any store mutation")
    func setNoteGainRejectsMIDIClip() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let (_, midiClipID) = try await addMIDIClip(router)
        let response = await setNoteGain(router, clipID: midiClipID, [UUID().uuidString], gainDb: -6)
        #expect(!response.ok)
        #expect(response.error?.contains("MIDI clip") == true)
        #expect(engine.detectCalls == 0, "no detection on this wire path")
    }

    @Test("clip.setNoteGain: a clip with no stored table refuses, teaching clip.autoCorrectPitch as the fix")
    func setNoteGainRequiresStoredTable() async throws {
        let (router, store) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let response = await setNoteGain(router, clipID: clipID, [UUID().uuidString], gainDb: -6)
        #expect(!response.ok)
        #expect(response.error?.contains("clip.autoCorrectPitch") == true)
        #expect(response.error?.contains("no notes to edit yet") == true)
        #expect(store.tracks.first?.clips.first?.pitchEdits == nil, "the wire must never seed a table")
    }

    /// ALL OR NOTHING: an unknown id among real ones changes nothing, and the
    /// refusal names how many notes the clip does carry.
    @Test("clip.setNoteGain: an unknown id among real ones changes nothing and names the clip's note count")
    func setNoteGainUnknownSegmentChangesNothing() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let realID = try #require(segments[0]["id"]?.stringValue)
        let before = store.tracks.first?.clips.first?.pitchEdits
        let depth = store.undoHistory().undo.count

        let response = await setNoteGain(router, clipID: clipID, [realID, UUID().uuidString], gainDb: -6)
        #expect(!response.ok)
        #expect(response.error?.contains("No note with id") == true)
        #expect(response.error?.contains("2 note(s)") == true, "must name the ACTUAL count on this clip")
        #expect(store.tracks.first?.clips.first?.pitchEdits == before,
                "a refused level-set changed the real note anyway")
        #expect(store.undoHistory().undo.count == depth)
    }

    @Test("clip.setNoteGain: parameters are validated in words (unknown clip or key, segmentIds shape, gainDb required, empty list)")
    func setNoteGainValidatesItsParameters() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let realID = try #require(segments[0]["id"]?.stringValue)

        func call(_ params: [String: JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(id: "v", command: "clip.setNoteGain", params: params))
        }
        let unknownClip = await setNoteGain(router, clipID: UUID().uuidString, [realID], gainDb: -6)
        #expect(unknownClip.error?.contains("no clip with id") == true)

        let unknownKey = await call(["clipId": .string(clipID), "segmentIds": .array([.string(realID)]),
                                     "gainDb": .number(-6), "bogus": .bool(true)])
        #expect(unknownKey.error?.contains("unknown parameter 'bogus'") == true)

        let notAnArray = await call(["clipId": .string(clipID), "segmentIds": .string(realID),
                                     "gainDb": .number(-6)])
        #expect(notAnArray.error?.contains("'segmentIds' must be an array") == true)

        let badUUID = await call(["clipId": .string(clipID),
                                  "segmentIds": .array([.string(realID), .string("not-a-uuid")]),
                                  "gainDb": .number(-6)])
        #expect(badUUID.error?.contains("segmentIds[1] is not a valid UUID") == true)

        let noValue = await call(["clipId": .string(clipID), "segmentIds": .array([.string(realID)])])
        #expect(noValue.error?.contains("'gainDb'") == true, "gainDb has no default: a caller must say what level")

        let valueNotNumber = await call(["clipId": .string(clipID), "segmentIds": .array([.string(realID)]),
                                         "gainDb": .string("-6")])
        #expect(valueNotNumber.error?.contains("'gainDb'") == true)

        let empty = await call(["clipId": .string(clipID), "segmentIds": .array([]), "gainDb": .number(-6)])
        #expect(empty.error?.contains("Name at least one note to set the level of") == true)

        for response in [unknownClip, unknownKey, notAnArray, badUUID, noValue, valueNotNumber, empty] {
            #expect(!response.ok)
        }
    }

    /// Placed immediately after `clip.setNoteCleared`, in the per-note door
    /// cluster beside `clip.sliceToSampler`, NOT at the tail, so every
    /// `dropLast(N)` window and every earlier anchor pin stay true.
    @Test("clip.setNoteGain is registered immediately after clip.setNoteCleared, beside clip.sliceToSampler")
    func setNoteGainRegistered() throws {
        let all = CommandRouter.allCommands
        let anchor = try #require(all.firstIndex(of: "clip.sliceToSampler"))
        #expect(all[anchor + 5] == "clip.setNoteGain")
        #expect(all.filter { $0 == "clip.setNoteGain" }.count == 1)
        #expect(all.last != "clip.setNoteGain")
    }

    // MARK: - clip.setNotePitches (m23-ap I4 wire leg, the BATCH twin of clip.setNotePitch)

    /// A tuple array is not itself `Equatable` (`Array`'s conformance needs
    /// `Element: Equatable`, and a bare tuple type does not satisfy that even
    /// though two tuples compare directly) — a named struct instead, so
    /// `echoed == [EchoedNote(...), ...]` below just works.
    private struct EchoedNote: Equatable {
        let id: String
        let cents: Double?
    }

    /// Each note's `{segmentId, pitchOffsetCents}` off a wire `notes` array,
    /// IN ORDER — the `clearedFlags`/`gainLevels` idiom above, but returning
    /// an ordered array (not a dictionary) since duplicate-order and
    /// dedup-order are exactly what several tests below assert on.
    private func pitchesEcho(_ response: ControlResponse) throws -> [EchoedNote] {
        let notes = try #require(response.result?["notes"]?.arrayValue)
        return try notes.map { note in
            EchoedNote(id: try #require(note["segmentId"]?.stringValue),
                       cents: note["pitchOffsetCents"]?.doubleValue)
        }
    }

    private func setNotePitches(_ router: CommandRouter, clipID: String,
                                _ notes: [(id: String, cents: Double)]) async -> ControlResponse {
        await router.handle(ControlRequest(
            id: "snps", command: "clip.setNotePitches",
            params: ["clipId": .string(clipID),
                     "notes": .array(notes.map {
                         .object(["segmentId": .string($0.id), "cents": .number($0.cents)])
                     })]))
    }

    @Test("clip.setNotePitches: happy path forwards the stored, post-clamp pitchOffsetCents; the OTHER note is untouched; clip.getPitchEdits echoes it")
    func setNotePitchesHappyPath() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        #expect(segments.count == 2)
        let targetID = try #require(segments[0]["id"]?.stringValue)
        let otherID = try #require(segments[1]["id"]?.stringValue)
        let otherOriginalCents = try #require(segments[1]["pitchOffsetCents"]?.doubleValue)

        let response = await setNotePitches(router, clipID: clipID, [(targetID, 50)])
        #expect(response.ok, "\(response.error ?? "?")")
        let echoed = try pitchesEcho(response)
        #expect(echoed == [EchoedNote(id: targetID, cents: 50)])
        #expect(response.result?["appliedOptions"] == nil, "setNotePitches never applied a whole-clip pass")

        let afterSegments = try #require(response.result?["segments"]?.arrayValue)
        #expect(afterSegments.count == 2)
        let other = try #require(afterSegments.first { $0["id"]?.stringValue == otherID })
        #expect(other["pitchOffsetCents"]?.doubleValue == otherOriginalCents,
                "the note nobody named stays at its pre-edit value")

        // A setter's return is not proof it took: read the STORE directly.
        let clip = try #require(store.tracks.first?.clips.first)
        let stored = try #require(clip.pitchEdits?.segments.first { $0.id.uuidString == targetID })
        #expect(stored.pitchOffsetCents == 50)

        let get = await router.handle(ControlRequest(
            id: "g", command: "clip.getPitchEdits", params: ["clipId": .string(clipID)]))
        #expect(get.ok)
        let gotSegments = try #require(get.result?["segments"]?.arrayValue)
        #expect(gotSegments.first { $0["id"]?.stringValue == targetID }?["pitchOffsetCents"]?.doubleValue == 50)
    }

    /// The brief's echo spec names `hasPitchEdits` explicitly, alongside the
    /// per-note cents — the `clip.setNoteGain`/`clip.setNoteCleared`
    /// "alone is an edit" test, adapted: a cents write ALONE (even 0, even on
    /// an otherwise untouched, freshly-detected table) must take the clip out
    /// of the render's identity bypass exactly as a level or clear write
    /// does, and landing every named note back at exactly its DETECTED
    /// offset must return it to identity — `hasPitchEdits` is not a bare key
    /// that merely EXISTS on the response (the shared builder guarantees
    /// that for free); its VALUE must track the actual edit state.
    @Test("clip.setNotePitches: a cents write alone makes an unedited table an edit on the wire, and landing back on the detected offset undoes exactly that")
    func setNotePitchesAloneIsAnEdit() async throws {
        let (router, store) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let clipUUID = try #require(UUID(uuidString: clipID))
        // Seed a DETECTED-ONLY table through the store (a 0-cent write stores
        // the seed unchanged). The wire never seeds: it has no detector.
        let seed = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.1, endSeconds: 0.3, detectedHz: 220, detectedConfidence: 0.9),
            NoteSegment(startSeconds: 0.4, endSeconds: 0.6, detectedHz: 247, detectedConfidence: 0.9),
        ])
        _ = try store.setClipNotePitchOffset(clipId: clipUUID, segmentId: seed.segments[0].id,
                                             offsetCents: 0, seedIfAbsent: seed)
        let noteID = seed.segments[1].id.uuidString
        let detectedCents = seed.segments[1].pitchOffsetCents  // 0: a freshly-detected note

        func readFlags() async throws -> (has: Bool?, identity: Bool?) {
            let get = await router.handle(ControlRequest(
                id: "g", command: "clip.getPitchEdits", params: ["clipId": .string(clipID)]))
            #expect(get.ok)
            return (get.result?["hasPitchEdits"]?.boolValue, get.result?["isIdentity"]?.boolValue)
        }
        let before = try await readFlags()
        #expect(before.has == false && before.identity == true,
                "CONTROL: a detected-only table must read as unedited")

        let moved = await setNotePitches(router, clipID: clipID, [(noteID, 50)])
        #expect(moved.ok, "\(moved.error ?? "?")")
        #expect(moved.result?["hasPitchEdits"]?.boolValue == true,
                "the batch verb's OWN response must echo hasPitchEdits, not just the getter's")
        let during = try await readFlags()
        #expect(during.has == true && during.identity == false,
                "a cents write alone did not make the clip an edit: its render would be skipped")
        #expect(during.has == store.tracks.first?.clips.first?.hasPitchEdits,
                "the wire's hasPitchEdits is not Clip.hasPitchEdits")

        let restored = await setNotePitches(router, clipID: clipID, [(noteID, detectedCents)])
        #expect(restored.ok)
        #expect(restored.result?["hasPitchEdits"]?.boolValue == false,
                "landing back on the detected offset must return the clip to unedited")
        let after = try await readFlags()
        #expect(after.has == false && after.identity == true,
                "the detected offset did not return the clip to unedited")
    }

    /// THE core batch semantic the brief names: unlike `clip.setNoteGain`'s
    /// ONE value shared by every named note, each note here lands at its OWN
    /// absolute cents — "the intervals between notes are whatever you send."
    /// A planted "broadcast the first value to every note" defect would
    /// collapse this to two equal numbers; this test would catch it.
    @Test("clip.setNotePitches: two notes in ONE call land at two DIFFERENT absolute offsets — intervals are whatever was sent")
    func setNotePitchesKeepsDistinctPerNoteOffsets() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let first = try #require(segments[0]["id"]?.stringValue)
        let second = try #require(segments[1]["id"]?.stringValue)

        let response = await setNotePitches(router, clipID: clipID, [(first, 50), (second, -30)])
        #expect(response.ok, "\(response.error ?? "?")")
        let echoed = try pitchesEcho(response)
        #expect(echoed == [EchoedNote(id: first, cents: 50), EchoedNote(id: second, cents: -30)])

        let clip = try #require(store.tracks.first?.clips.first)
        #expect(clip.pitchEdits?.segments.first { $0.id.uuidString == first }?.pitchOffsetCents == 50)
        #expect(clip.pitchEdits?.segments.first { $0.id.uuidString == second }?.pitchOffsetCents == -30)
    }

    @Test("clip.setNotePitches: clamps EACH note to +/-2400 independently and reads the STORED, post-clamp values back")
    func setNotePitchesClampsAndReadsBack() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let first = try #require(segments[0]["id"]?.stringValue)
        let second = try #require(segments[1]["id"]?.stringValue)

        let response = await setNotePitches(router, clipID: clipID, [(first, 9999), (second, -9999)])
        #expect(response.ok, "\(response.error ?? "?")")
        let echoed = try pitchesEcho(response)
        #expect(echoed == [EchoedNote(id: first, cents: 2400), EchoedNote(id: second, cents: -2400)])

        let clip = try #require(store.tracks.first?.clips.first)
        #expect(clip.pitchEdits?.segments.first { $0.id.uuidString == first }?.pitchOffsetCents == 2400,
                "the STORE, not just the response, carries the clamped value")
        #expect(clip.pitchEdits?.segments.first { $0.id.uuidString == second }?.pitchOffsetCents == -2400)
    }

    /// ONE call for N notes is ONE undo step; a repeated id at the SAME
    /// cents folds (deduplicated in the echo, in request order); undo
    /// restores every note.
    @Test("clip.setNotePitches: N notes in one call is ONE undo step, a repeated id at the SAME cents is folded, and undo restores them all")
    func setNotePitchesIsOneUndoStepAndFoldsARepeatedID() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let first = try #require(segments[0]["id"]?.stringValue)
        let second = try #require(segments[1]["id"]?.stringValue)
        // ⚠️ NOT necessarily 0 — the default strength-1 auto-correct pass
        // already pulled both notes by some real amount (the
        // `setNotePitchHappyPath` note, verbatim): capture the ACTUAL
        // pre-edit values rather than assuming one.
        let firstOriginal = try #require(segments[0]["pitchOffsetCents"]?.doubleValue)
        let secondOriginal = try #require(segments[1]["pitchOffsetCents"]?.doubleValue)
        let depth = store.undoHistory().undo.count

        let response = await setNotePitches(
            router, clipID: clipID, [(second, -20), (first, 50), (second, -20)])
        #expect(response.ok, "\(response.error ?? "?")")
        let echoed = try pitchesEcho(response)
        #expect(echoed == [EchoedNote(id: second, cents: -20), EchoedNote(id: first, cents: 50)],
                "the notes named, deduplicated, in request order")
        #expect(store.undoHistory().undo.count == depth + 1, "two notes (one repeated) must be ONE undo step")
        #expect(store.undoHistory().undo.first == "Tune Notes")

        #expect(try store.undo() == "Tune Notes")
        let stored = try #require(store.tracks.first?.clips.first?.pitchEdits)
        #expect(stored.segments.first { $0.id.uuidString == first }?.pitchOffsetCents == firstOriginal,
                "undo did not restore the first note")
        #expect(stored.segments.first { $0.id.uuidString == second }?.pitchOffsetCents == secondOriginal,
                "undo did not restore the second note")
    }

    /// A repeated id whose two cents CLAMP to the SAME value folds too — the
    /// store clamps BEFORE comparing duplicates, so `9999`/`2400` (both ->
    /// `2400`) is not a conflict even though the RAW numbers differ. Proves
    /// the wire surfaces the store's clamp-first semantics rather than
    /// pre-judging "two different numbers" on the request's own bytes.
    @Test("clip.setNotePitches: a repeated id whose cents clamp to the SAME value folds, not refuses")
    func setNotePitchesRepeatedIDFoldsWhenClampedToTheSameValue() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let targetID = try #require(segments[0]["id"]?.stringValue)

        let response = await setNotePitches(router, clipID: clipID, [(targetID, 9999), (targetID, 2400)])
        #expect(response.ok, "9999 and 2400 both clamp to 2400 — this must fold, not refuse: \(response.error ?? "?")")
        let echoed = try pitchesEcho(response)
        #expect(echoed == [EchoedNote(id: targetID, cents: 2400)])
    }

    @Test("clip.setNotePitches: a no-op (every named note already at its sent cents) journals nothing")
    func setNotePitchesNoOpJournalsNothing() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let targetID = try #require(segments[0]["id"]?.stringValue)

        _ = await setNotePitches(router, clipID: clipID, [(targetID, 50)])
        let depth = store.undoHistory().undo.count
        let response = await setNotePitches(router, clipID: clipID, [(targetID, 50)])
        #expect(response.ok)
        #expect(store.undoHistory().undo.count == depth,
                "setting a note to the cents it already carries must journal nothing")
    }

    /// THE COALESCING RULE this lane chose: `PitchCorrectionUndoKey.structuralKey`
    /// (nil) NEVER coalesces, unlike the in-process editor's own
    /// `.group(clipID:selectionToken:)` (which folds two drags of the SAME
    /// selection inside 800ms). Two SEPARATE wire calls — even naming the
    /// SAME note, back to back, inside the journal's coalescing window —
    /// must produce TWO undo entries, not one. The second call sends a
    /// DIFFERENT cents value than the first (50, then 80): if it sent the
    /// same value again this would be indistinguishable from the no-op test
    /// above (0 NEW entries either way), so a wrongly-coalescing
    /// implementation and a correctly-non-coalescing one would both pass.
    @Test("clip.setNotePitches: never coalesces — two back-to-back calls on the same note are TWO undo steps")
    func setNotePitchesNeverCoalescesAcrossCalls() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let targetID = try #require(segments[0]["id"]?.stringValue)
        // ⚠️ NOT necessarily 0 — the `setNotePitchHappyPath` note, verbatim.
        let originalCents = try #require(segments[0]["pitchOffsetCents"]?.doubleValue)
        let depth = store.undoHistory().undo.count

        let first = await setNotePitches(router, clipID: clipID, [(targetID, 50)])
        #expect(first.ok, "\(first.error ?? "?")")
        let second = await setNotePitches(router, clipID: clipID, [(targetID, 80)])
        #expect(second.ok, "\(second.error ?? "?")")

        #expect(store.undoHistory().undo.count == depth + 2,
                "two separate clip.setNotePitches calls must NEVER coalesce into one undo step, even on the same note inside the journal's coalescing window")
        // Both entries are independently undoable back to the ORIGINAL value.
        #expect(try store.undo() == "Tune Notes")
        #expect(store.tracks.first?.clips.first?.pitchEdits?.segments
            .first { $0.id.uuidString == targetID }?.pitchOffsetCents == 50)
        #expect(try store.undo() == "Tune Notes")
        #expect(store.tracks.first?.clips.first?.pitchEdits?.segments
            .first { $0.id.uuidString == targetID }?.pitchOffsetCents == originalCents)
    }

    @Test("clip.setNotePitches: a repeated id with two DIFFERENT cents refuses, verbatim, and changes nothing")
    func setNotePitchesRepeatedIDConflictRefuses() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let targetID = try #require(segments[0]["id"]?.stringValue)
        let before = store.tracks.first?.clips.first?.pitchEdits
        let depth = store.undoHistory().undo.count

        let response = await setNotePitches(router, clipID: clipID, [(targetID, 50), (targetID, 60)])
        #expect(!response.ok)
        #expect(response.error?.contains("is named twice with two different pitches") == true)
        #expect(response.error?.contains("Name each note once") == true)
        #expect(store.tracks.first?.clips.first?.pitchEdits == before, "a refused call changed the note anyway")
        #expect(store.undoHistory().undo.count == depth)
    }

    /// ALL OR NOTHING: an unknown id among real ones changes NOTHING —
    /// neither the real note named alongside it — and the refusal names how
    /// many notes the clip does carry.
    @Test("clip.setNotePitches: an unknown id among real ones changes nothing and names the clip's note count")
    func setNotePitchesUnknownSegmentChangesNothing() async throws {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let realID = try #require(segments[0]["id"]?.stringValue)
        let before = store.tracks.first?.clips.first?.pitchEdits
        let depth = store.undoHistory().undo.count

        let response = await setNotePitches(router, clipID: clipID, [(realID, 50), (UUID().uuidString, 50)])
        #expect(!response.ok)
        #expect(response.error?.contains("No note with id") == true)
        #expect(response.error?.contains("2 note(s)") == true, "must name the ACTUAL count on this clip")
        #expect(store.tracks.first?.clips.first?.pitchEdits == before,
                "a refused batch changed the real note anyway")
        #expect(store.undoHistory().undo.count == depth)
    }

    @Test("clip.setNotePitches: a MIDI clip is refused, naming why, before any store mutation")
    func setNotePitchesRejectsMIDIClip() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let (_, midiClipID) = try await addMIDIClip(router)

        let response = await setNotePitches(router, clipID: midiClipID, [(UUID().uuidString, 50)])
        #expect(!response.ok)
        #expect(response.error?.contains("MIDI clip") == true)
        #expect(engine.detectCalls == 0, "no detection on this wire path, MIDI or not")
    }

    @Test("clip.setNotePitches: a clip with no stored table refuses, teaching clip.autoCorrectPitch as the fix")
    func setNotePitchesRequiresStoredTable() async throws {
        let (router, store) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        // Deliberately never auto-corrected — `pitchEdits` is nil.

        let response = await setNotePitches(router, clipID: clipID, [(UUID().uuidString, 50)])
        #expect(!response.ok)
        #expect(response.error?.contains("clip.autoCorrectPitch") == true)
        #expect(response.error?.contains("no notes to edit yet") == true)
        #expect(store.tracks.first?.clips.first?.pitchEdits == nil, "the wire must never seed a table")
    }

    @Test("clip.setNotePitches: parameters are validated in words (unknown clip/key, notes shape, empty list, per-note field shapes)")
    func setNotePitchesValidatesItsParameters() async throws {
        let engine = makeMelodicEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        let realID = try #require(segments[0]["id"]?.stringValue)

        func call(_ params: [String: JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(id: "v", command: "clip.setNotePitches", params: params))
        }

        let unknownClip = await setNotePitches(router, clipID: UUID().uuidString, [(realID, 50)])
        #expect(unknownClip.error?.contains("no clip with id") == true)

        let unknownKey = await call(["clipId": .string(clipID),
                                     "notes": .array([.object(["segmentId": .string(realID), "cents": .number(50)])]),
                                     "bogus": .bool(true)])
        #expect(unknownKey.error?.contains("unknown parameter 'bogus'") == true)

        let notAnArray = await call(["clipId": .string(clipID), "notes": .string(realID)])
        #expect(notAnArray.error?.contains("'notes' must be an array") == true)

        let elementNotAnObject = await call(["clipId": .string(clipID), "notes": .array([.number(50)])])
        #expect(elementNotAnObject.error?.contains("notes[0] must be {segmentId") == true)

        let badUUID = await call(["clipId": .string(clipID),
                                  "notes": .array([.object(["segmentId": .string("not-a-uuid"), "cents": .number(50)])])])
        #expect(badUUID.error?.contains("notes[0].segmentId is not a valid UUID") == true)

        let missingSegmentId = await call(["clipId": .string(clipID),
                                           "notes": .array([.object(["cents": .number(50)])])])
        #expect(missingSegmentId.error?.contains("notes[0].segmentId is not a valid UUID") == true)

        let missingCents = await call(["clipId": .string(clipID),
                                       "notes": .array([.object(["segmentId": .string(realID)])])])
        #expect(missingCents.error?.contains("notes[0].cents must be a number") == true)

        let centsNotNumber = await call(["clipId": .string(clipID),
                                         "notes": .array([.object(["segmentId": .string(realID), "cents": .string("50")])])])
        #expect(centsNotNumber.error?.contains("notes[0].cents must be a number") == true)

        let empty = await setNotePitches(router, clipID: clipID, [])
        #expect(empty.error?.contains("Name at least one note to tune") == true)

        for response in [unknownClip, unknownKey, notAnArray, elementNotAnObject, badUUID,
                          missingSegmentId, missingCents, centsNotNumber, empty] {
            #expect(!response.ok)
        }
    }

    /// "Registered next to `clip.setNotePitch`" (the brief) means: IN THE
    /// SAME per-note pitch-editor door cluster beside `clip.sliceToSampler`
    /// that `clip.setNotePitch` itself anchors — the `clip.setNoteCleared`/
    /// `clip.setNoteGain` precedent, appended at the CLUSTER's tail rather
    /// than literally adjacent to `clip.setNotePitch`, so every
    /// `dropLast(N)` window and every earlier `anchor + N` pin above stays
    /// true by construction (a near-`clip.setNotePitch` insertion was
    /// measured, at THIS cluster's very first member, to break 99
    /// `dropLast(N)` pins across 26 files).
    @Test("clip.setNotePitches is registered immediately after clip.setNoteGain, beside clip.sliceToSampler")
    func setNotePitchesRegistered() throws {
        let all = CommandRouter.allCommands
        let anchor = try #require(all.firstIndex(of: "clip.sliceToSampler"))
        #expect(all[anchor + 6] == "clip.setNotePitches")
        #expect(all.filter { $0 == "clip.setNotePitches" }.count == 1)
        #expect(all.last != "clip.setNotePitches")
    }

    // MARK: - clip.auditionNote (m23-ap I1 wire leg, part 2 of 2: HEAR the note)

    /// Engine spy for `clip.auditionNote`: records every span asked for (so
    /// a refusal can be proven to have reached the engine ZERO times — the
    /// all-or-nothing and transport-running tests below read `spanCalls`,
    /// never just the response) and lets a test choose what the plain
    /// `auditionClipSpan` answers. `AudioEngineControlling`'s protocol
    /// extension defaults `auditionClipSpan` to `.unsupported` for any
    /// conformer that does not override it (`EngineProtocol.swift`'s own
    /// comment: "fakes and headless engines have no audition voice"), which
    /// `makeMelodicEngine()`'s `FakePitchDetectionEngine` never overrides —
    /// so THAT fake can reach every REFUSAL branch (an unknown id, no
    /// stored table, transport running, …) but never `.sounded`
    /// (`auditionNoteEngineWithoutAuditionSupport` below uses it exactly
    /// for that: a real, non-throwing `.unsupported` answer). Reaching
    /// `.sounded` for the round-trip test needs a conformer that answers
    /// it, and `AudioEngine` is never used in a wire test — port 17600 is
    /// the user's live app — so this is a NEW spy, never the real engine.
    /// Required-member list copied from `AuditionCommandTests.
    /// AuditionSpyEngine` (the `note.audition` precedent this brief
    /// names), the minimal set `AudioEngineControlling` actually requires
    /// with no protocol-extension default — confirmed by reading that
    /// class, not guessed.
    @MainActor
    private final class NoteAuditionSpyEngine: AudioEngineControlling {
        var isRunning = true
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        /// Every span this spy was asked to play, in call order — the
        /// PLAIN (4-argument) form `press` always tries first.
        private(set) var spanCalls: [(trackID: UUID, clipID: UUID,
                                      start: Double, end: Double)] = []
        var outcomeStub: AuditionOutcome = .sounded

        func auditionClipSpan(trackID: UUID, clipID: UUID, startSourceSeconds: Double,
                              endSourceSeconds: Double) -> AuditionOutcome {
            spanCalls.append((trackID, clipID, startSourceSeconds, endSourceSeconds))
            return outcomeStub
        }

        /// The SPAN-RENDER (6-argument) overload (I1-F1) — `SpanRenderSpyEngine`
        /// precedent (`Tests/DAWCoreTests/ClipNoteSpanAuditionTests.swift`).
        /// Defaults to `.unsupported`, exactly the protocol-extension
        /// default every test above already relies on by never touching
        /// this override at all — so adding it changes nothing for them.
        /// `press` only ever calls this SECOND, and only when the plain
        /// call above answered `.inaudibleNotReady` first
        /// (`auditionNoteEchoesSpanRenderSource` is the one test that sets
        /// both `outcomeStub` and `spanAnswer` to reach it). The
        /// completion closure is intentionally discarded, never called:
        /// this door only ever reads `press`'s SYNCHRONOUS return.
        private(set) var spanRenderCalls: [(trackID: UUID, clipID: UUID, start: Double,
                                            end: Double, source: ClipSpanAuditionSource)] = []
        var spanAnswer: AuditionOutcome = .unsupported

        func auditionClipSpan(trackID: UUID, clipID: UUID, startSourceSeconds: Double,
                              endSourceSeconds: Double, source: ClipSpanAuditionSource,
                              completion: (@MainActor @Sendable (ClipSpanAuditionDelivery) -> Void)?)
            -> AuditionOutcome {
            spanRenderCalls.append((trackID, clipID, startSourceSeconds, endSourceSeconds, source))
            return spanAnswer
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
        func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL) async throws -> AudioFileInfo {
            throw ProjectError.engineUnavailable
        }
        var recordPermission: RecordPermission { .granted }
        func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
            completion(true)
        }
        func availableInputDevices() -> [AudioInputDevice] { [] }
        func setInputDevice(uid: String?) throws {}
        func startRecording(_ transport: TransportState, to url: URL,
                            completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
            throw ProjectError.engineUnavailable
        }
        func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                       completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {}
        func stopRecording() {}
    }

    private func auditionNote(_ router: CommandRouter, clipID: String, _ segmentIDs: [String],
                              contextSeconds: Double? = nil) async -> ControlResponse {
        var params: [String: JSONValue] = ["clipId": .string(clipID),
                                           "segmentIds": .array(segmentIDs.map { .string($0) })]
        if let contextSeconds { params["contextSeconds"] = .number(contextSeconds) }
        return await router.handle(ControlRequest(id: "can", command: "clip.auditionNote", params: params))
    }

    /// Builds a clip with a stored note table (autoCorrect already ran) and
    /// hands back its router/store plus both segment ids — the shared setup
    /// every `clip.auditionNote` test below starts from, mirroring
    /// `autoCorrectSegments`'s role for the setNotePitch(es) tests above.
    /// Starts on `makeMelodicEngine()`'s fake so pitch detection needs no
    /// real inference; callers that need `.sounded` swap `store.engine` to
    /// `NoteAuditionSpyEngine` AFTERWARDS — the clip's stored table does not
    /// care which engine is attached once it is written.
    private func makeAuditionFixture() async throws
        -> (router: CommandRouter, store: ProjectStore, clipID: String, segmentIDs: [String]) {
        let engine = makeMelodicEngine()
        let (router, store) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let segments = try await autoCorrectSegments(router, clipID: clipID)
        #expect(segments.count == 2)
        let ids = try segments.map { try #require($0["id"]?.stringValue) }
        return (router, store, clipID, ids)
    }

    @Test("clip.auditionNote: happy path — a spy sounds it, and the response echoes clipId/segmentIds/the resolved span/source/audible/outcome, reason null")
    func auditionNoteHappyPath() async throws {
        let (router, store, clipID, ids) = try await makeAuditionFixture()
        let spy = NoteAuditionSpyEngine()
        spy.outcomeStub = .sounded
        store.engine = spy

        let response = await auditionNote(router, clipID: clipID, [ids[0]])
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(response.result?["clipId"]?.stringValue == clipID)
        #expect(response.result?["segmentIds"]?.arrayValue?.compactMap(\.stringValue) == [ids[0]])
        #expect(response.result?["audible"]?.boolValue == true)
        #expect(response.result?["outcome"]?.stringValue == "sounded")
        #expect(response.result?["reason"]?.stringValue == nil, "audible: true carries no reason")
        // hasPitchEdits is true after autoCorrect (the default strength-1
        // pass pulls a real, non-zero offset — the setNotePitches fixture's
        // own finding above), so rendersThroughStretchCache reads true by
        // the model's own formula (`!isStretchIdentity || hasPitchEdits`,
        // Model.swift) — read back, never assumed.
        #expect(response.result?["source"]?.stringValue == "render")
        let start = try #require(response.result?["startSeconds"]?.doubleValue)
        let end = try #require(response.result?["endSeconds"]?.doubleValue)
        #expect(end > start)

        #expect(spy.spanCalls.count == 1)
        let call = try #require(spy.spanCalls.first)
        #expect(call.start == start)
        #expect(call.end == end)
    }

    @Test("clip.auditionNote: a press whose plain read answers \"not ready\" escalates to a span render, and the wire echoes source:\"span-render\" (RT re-review NH-C)")
    func auditionNoteEchoesSpanRenderSource() async throws {
        let (router, store, clipID, ids) = try await makeAuditionFixture()
        let spy = NoteAuditionSpyEngine()
        spy.outcomeStub = .inaudibleNotReady
        spy.spanAnswer = .sounded
        store.engine = spy

        let response = await auditionNote(router, clipID: clipID, [ids[0]])
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(response.result?["source"]?.stringValue == "span-render")
        #expect(response.result?["audible"]?.boolValue == true)
        #expect(response.result?["outcome"]?.stringValue == "sounded")
        #expect(response.result?["reason"]?.stringValue == nil)

        // The PLAIN read is tried first (and answers not-ready) — THEN,
        // and only then, the span render is asked for. Never both at
        // once, never the other order: press's own escalation sequence.
        #expect(spy.spanCalls.count == 1)
        #expect(spy.spanRenderCalls.count == 1)
        #expect(spy.spanRenderCalls.first?.source == .storedSpanRender,
                "a press reads the clip's STORED edits, never a draft (drafts are the drag door's own)")
    }

    @Test("clip.auditionNote: several notes in one call span BOTH of them in ONE engine call, and a repeated id is folded in the segmentIds echo")
    func auditionNoteCoversAllNamedNotesAndFoldsARepeat() async throws {
        let (router, store, clipID, ids) = try await makeAuditionFixture()
        let spy = NoteAuditionSpyEngine()
        store.engine = spy
        let response = await auditionNote(router, clipID: clipID, [ids[0], ids[1], ids[0]])
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(response.result?["segmentIds"]?.arrayValue?.compactMap(\.stringValue) == [ids[0], ids[1]],
                "deduplicated, in request order — the clip.setNoteGain/clip.setNotePitches segmentIds idiom")
        #expect(spy.spanCalls.count == 1, "one audition call for the WHOLE named span, not one per note")
    }

    @Test("clip.auditionNote: while the transport plays, audible:false + reason:\"transport-running\" is a SUCCESS, not an error, and the engine is never touched (H6: .noRenderer can never surface on this door)")
    func auditionNoteRefusesWhileTransportRunning() async throws {
        let (router, store, clipID, ids) = try await makeAuditionFixture()
        let spy = NoteAuditionSpyEngine()
        store.engine = spy
        let play = await router.handle(ControlRequest(id: "p", command: "transport.play", params: [:]))
        #expect(play.ok, "\(play.error ?? "?")")
        #expect(store.transport.isPlaying)

        let response = await auditionNote(router, clipID: clipID, [ids[0]])
        #expect(response.ok, "a refusal without a throw is a SUCCESS: \(response.error ?? "?")")
        #expect(response.result?["audible"]?.boolValue == false)
        #expect(response.result?["reason"]?.stringValue == "transport-running")
        #expect(response.result?["outcome"]?.stringValue == nil, "refused before the engine answered anything")
        #expect(spy.spanCalls.isEmpty,
                "the transport-running guard fires BEFORE the engine is touched — H6's .noRenderer can never be this verb's answer")
    }

    @Test("clip.auditionNote: an engine with no clip-note audition support answers audible:false, outcome AND reason both \"unsupported\" — a real, not a refused-before-the-engine, answer")
    func auditionNoteEngineWithoutAuditionSupport() async throws {
        // Deliberately do NOT swap in the spy: makeMelodicEngine()'s
        // FakePitchDetectionEngine never overrides auditionClipSpan, so it
        // answers through AudioEngineControlling's own protocol-extension
        // default, `.unsupported`.
        let (router, _, clipID, ids) = try await makeAuditionFixture()
        let response = await auditionNote(router, clipID: clipID, [ids[0]])
        #expect(response.ok, "a real, non-throwing answer: \(response.error ?? "?")")
        #expect(response.result?["audible"]?.boolValue == false)
        #expect(response.result?["outcome"]?.stringValue == "unsupported")
        #expect(response.result?["reason"]?.stringValue == "unsupported")
    }

    @Test("clip.auditionNote: an unknown id among real ones refuses, verbatim, naming the clip's note count, and the engine is never touched (all-or-nothing)")
    func auditionNoteUnknownSegmentPlaysNothing() async throws {
        let (router, store, clipID, ids) = try await makeAuditionFixture()
        let spy = NoteAuditionSpyEngine()
        store.engine = spy
        let bogus = UUID().uuidString

        let response = await auditionNote(router, clipID: clipID, [ids[0], bogus])
        #expect(!response.ok)
        #expect(response.error?.contains("No note with id \(bogus)") == true, "\(response.error ?? "?")")
        #expect(response.error?.contains("carries 2 note(s)") == true, "\(response.error ?? "?")")
        #expect(spy.spanCalls.isEmpty, "all-or-nothing: nothing plays when one id is unresolved")
    }

    @Test("clip.auditionNote: an unknown clip is refused, verbatim")
    func auditionNoteRejectsUnknownClip() async throws {
        let (router, store, _, ids) = try await makeAuditionFixture()
        let spy = NoteAuditionSpyEngine()
        store.engine = spy
        let response = await auditionNote(router, clipID: UUID().uuidString, [ids[0]])
        #expect(!response.ok)
        #expect(response.error?.contains("no clip with id") == true, "\(response.error ?? "?")")
        #expect(spy.spanCalls.isEmpty)
    }

    @Test("clip.auditionNote: a MIDI clip is refused, naming why, before any store mutation")
    func auditionNoteRejectsMIDIClip() async throws {
        let spy = NoteAuditionSpyEngine()
        let (router, _) = makeRouter(engine: spy)
        let (_, clipID) = try await addMIDIClip(router)
        let response = await auditionNote(router, clipID: clipID, [UUID().uuidString])
        #expect(!response.ok)
        #expect(response.error?.contains("is a MIDI clip") == true, "\(response.error ?? "?")")
        #expect(response.error?.contains("note.audition") == true, "\(response.error ?? "?")")
        #expect(spy.spanCalls.isEmpty)
    }

    @Test("clip.auditionNote: a clip with no stored table refuses, teaching clip.autoCorrectPitch as the fix")
    func auditionNoteRequiresStoredTable() async throws {
        let spy = NoteAuditionSpyEngine()
        let (router, _) = makeRouter(engine: spy)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let response = await auditionNote(router, clipID: clipID, [UUID().uuidString])
        #expect(!response.ok)
        #expect(response.error?.contains("has no notes to hear yet") == true, "\(response.error ?? "?")")
        #expect(response.error?.contains("clip.autoCorrectPitch") == true, "\(response.error ?? "?")")
        #expect(spy.spanCalls.isEmpty)
    }

    @Test("clip.auditionNote: an empty segmentIds list refuses, teaching clip.getPitchEdits as the way to read ids first")
    func auditionNoteRequiresAtLeastOneSegmentId() async throws {
        let (router, store, clipID, _) = try await makeAuditionFixture()
        let spy = NoteAuditionSpyEngine()
        store.engine = spy
        let response = await auditionNote(router, clipID: clipID, [])
        #expect(!response.ok)
        #expect(response.error?.contains("Name at least one note to hear") == true, "\(response.error ?? "?")")
        #expect(response.error?.contains("clip.getPitchEdits") == true, "\(response.error ?? "?")")
        #expect(spy.spanCalls.isEmpty)
    }

    @Test("clip.auditionNote: contextSeconds outside 0...2 refuses naming the legal range, and a non-numeric contextSeconds is refused at the wire layer")
    func auditionNoteValidatesContextSecondsRange() async throws {
        let (router, store, clipID, ids) = try await makeAuditionFixture()
        let spy = NoteAuditionSpyEngine()
        store.engine = spy

        let tooWide = await auditionNote(router, clipID: clipID, [ids[0]], contextSeconds: 2.5)
        #expect(!tooWide.ok)
        #expect(tooWide.error?.contains("contextSeconds must be 0") == true, "\(tooWide.error ?? "?")")

        let negative = await auditionNote(router, clipID: clipID, [ids[0]], contextSeconds: -0.1)
        #expect(!negative.ok)
        #expect(negative.error?.contains("contextSeconds must be") == true, "\(negative.error ?? "?")")

        let wrongType = await router.handle(ControlRequest(
            id: "can", command: "clip.auditionNote",
            params: ["clipId": .string(clipID), "segmentIds": .array([.string(ids[0])]),
                     "contextSeconds": .string("loud")]))
        #expect(!wrongType.ok)
        #expect(wrongType.error?.contains("'contextSeconds' must be a number") == true, "\(wrongType.error ?? "?")")

        #expect(spy.spanCalls.isEmpty)
    }

    @Test("clip.auditionNote: parameters are validated in words (unknown key, missing clipId, segmentIds shape, per-element UUID shape)")
    func auditionNoteValidatesItsParameters() async throws {
        let (router, store, clipID, ids) = try await makeAuditionFixture()
        let spy = NoteAuditionSpyEngine()
        store.engine = spy
        func call(_ params: [String: JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(id: "can", command: "clip.auditionNote", params: params))
        }

        let unknownKey = await call(["clipId": .string(clipID), "segmentIds": .array([.string(ids[0])]),
                                     "bogus": .bool(true)])
        #expect(unknownKey.error?.contains("unknown parameter 'bogus'") == true, "\(unknownKey.error ?? "?")")

        let missingClipID = await call(["segmentIds": .array([.string(ids[0])])])
        #expect(!missingClipID.ok)

        let notAnArray = await call(["clipId": .string(clipID), "segmentIds": .string(ids[0])])
        #expect(notAnArray.error?.contains("'segmentIds' must be an array") == true, "\(notAnArray.error ?? "?")")

        let badUUID = await call(["clipId": .string(clipID), "segmentIds": .array([.string("not-a-uuid")])])
        #expect(badUUID.error?.contains("segmentIds[0] is not a valid UUID") == true, "\(badUUID.error ?? "?")")

        for response in [unknownKey, missingClipID, notAnArray, badUUID] {
            #expect(!response.ok)
        }
        #expect(spy.spanCalls.isEmpty)
    }

    @Test("clip.auditionNote is registered immediately after clip.setNotePitches, beside clip.sliceToSampler")
    func auditionNoteRegistered() throws {
        let all = CommandRouter.allCommands
        let anchor = try #require(all.firstIndex(of: "clip.sliceToSampler"))
        #expect(all[anchor + 7] == "clip.auditionNote")
        #expect(all.filter { $0 == "clip.auditionNote" }.count == 1)
        #expect(all.last != "clip.auditionNote")
    }
}
