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
    // (`PitchCorrectionPresets.swift`'s own doc: 62.8 -> 18.2 cents median
    // wander cut, measured). The one remaining honest caveat (the detector
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
}
