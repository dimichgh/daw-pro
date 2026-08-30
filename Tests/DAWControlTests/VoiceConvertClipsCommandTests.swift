import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Control-protocol coverage for `vc.convertClips` (m24-m leg A) — the
/// SELECTION-driven, per-clip form of voice conversion the user ratified
/// 2026-08-13.
///
/// Routing, param shape, response encoding and refusals, with a
/// `FakeVoiceConverting` standing in for the RVC facade and a
/// `FakeRenderEngine` standing in for the offline render the extraction runs.
/// The store-level behaviour it composes (arrangement preservation, the ONE
/// undoable edit, all-or-nothing) is proven in
/// `DAWCoreTests/ClipVoiceConversionTests`; this suite proves the WIRE.
/// `FakeVoiceConverting.setConvertResult` is `fileprivate` to the suite that
/// declared it, so this file brings its own isolated setter rather than
/// widening that one's access.
private extension FakeVoiceConverting {
    func stubConvert(_ result: Result<VoiceConvertResult, Error>) {
        convertResult = result
    }

    /// m24-n: lets a test make the voice LISTING fail while conversion still
    /// succeeds — the case where provenance must fall back to the id rather
    /// than take the whole call down with it.
    func stubVoiceStatus(_ result: Result<VoiceDescriptor, Error>) {
        voiceStatusResult = result
    }
}

@MainActor
@Suite("Voice conversion — per-clip set over the wire (m24-m leg A)")
struct VoiceConvertClipsCommandTests {

    /// ⚠️ `ProjectStore.engine` is **weak** and the extraction renders, so a
    /// store whose engine was let go answers `engineUnavailable` on every
    /// call — which would turn a refusal test green for the wrong reason.
    /// Pinned for the process rather than trusted to a local binding.
    @MainActor
    private enum EngineKeepalive {
        static var engines: [FakeRenderEngine] = []
    }

    /// The converter's output stand-in. `importConvertedVoice`'s stable-copy
    /// step really does read this file, so it really exists.
    private func writeTinyWAV() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-clips-cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("converted.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        return url
    }

    private func makeStore() -> ProjectStore {
        let store = ProjectStore()
        store.media = FakeMedia()                    // 2.0 s → 4 beats @ 120 bpm
        let engine = FakeRenderEngine()
        store.engine = engine
        EngineKeepalive.engines.append(engine)
        store.generationImportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-clips-cmd-dest-\(UUID().uuidString)")
        return store
    }

    private func makeRouter(store: ProjectStore, converting: FakeVoiceConverting)
        -> CommandRouter {
        CommandRouter(store: store,
                      voiceConversionManager: FakeVoiceConversionManager(),
                      voiceConverting: converting)
    }

    /// Two audio clips at beats 0 and 8 on one track, plus the converter's
    /// scripted output.
    private func makeSession() async throws
        -> (ProjectStore, CommandRouter, FakeVoiceConverting, [Clip]) {
        let store = makeStore()
        let track = store.addTrack(kind: .audio)
        let source = URL(fileURLWithPath: "/tmp/lead-vox.wav")
        let a = try store.importAudio(url: source, toTrack: track.id, atBeat: 0)
        let b = try store.importAudio(url: source, toTrack: track.id, atBeat: 8)
        let converting = FakeVoiceConverting()
        await converting.stubConvert(.success(VoiceConvertResult(
            outputPath: try writeTinyWAV().path, voiceId: "base", inputSeconds: 2,
            engineLoadSeconds: 0, inferSeconds: 0.05, rtf: 40, sampleRate: 40_000,
            realConversion: false, note: "smoke")))
        return (store, makeRouter(store: store, converting: converting), converting, [a, b])
    }

    // MARK: - Registry

    @Test("vc.convertClips is in the canonical command list, next to its single-clip sibling")
    func commandIsCanonical() {
        #expect(CommandRouter.allCommands.contains("vc.convertClips"))
        // ADDITIVE ONLY: the verb it sits beside is untouched.
        #expect(CommandRouter.allCommands.contains("vc.convertVocals"))
        let all = CommandRouter.allCommands
        let convertClips = try? #require(all.firstIndex(of: "vc.convertClips"))
        let convertVocals = try? #require(all.firstIndex(of: "vc.convertVocals"))
        #expect((convertClips ?? 0) == (convertVocals ?? 0) + 1,
                "placed next to vc.convertVocals, NOT at the tail")
    }

    // MARK: - Happy path

    @Test("converts each selected clip separately and lands the set on ONE new track")
    func convertsTheSelectionOntoOneTrack() async throws {
        let (store, router, converting, clips) = try await makeSession()
        let tracksBefore = store.tracks.count

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertClips",
            params: ["clipIds": .array([.string(clips[0].id.uuidString),
                                        .string(clips[1].id.uuidString)]),
                     "voiceId": .string("base")]))

        #expect(response.ok, "vc.convertClips failed: \(response.error ?? "?")")
        // One convert call PER CLIP — the whole point of the verb.
        let calls = await converting.convertCalls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.voiceId == "base" })
        // ⭐ m24-o: each call is fed that clip's OWN extracted window, never
        // the shared backing recording both clips point at.
        #expect(calls[0].inputPath != calls[1].inputPath,
                "two clips off the same recording must not convert the same file")
        #expect(calls.allSatisfy { $0.inputPath.contains("voice-source-") })

        // ONE new track carrying BOTH clips at their own beats.
        #expect(store.tracks.count == tracksBefore + 1)
        let trackId = try #require(response.result?["trackId"]?.stringValue)
        let landed = try #require(store.tracks.first { $0.id.uuidString == trackId })
        #expect(landed.name == "Voice: base")           // the shared default rule
        #expect(landed.isAIGenerated)
        #expect(landed.clips.map(\.startBeat) == [0, 8])

        // Response shape: the store's per-clip report + this clip's converter
        // metadata merged onto it.
        let reported = try #require(response.result?["clips"]?.arrayValue)
        #expect(reported.count == 2)
        let first = try #require(reported.first?.objectValue)
        #expect(first["sourceClipId"]?.stringValue == clips[0].id.uuidString)
        #expect(first["startBeat"]?.doubleValue == 0)
        #expect(first["lengthBeats"]?.doubleValue == 4)
        #expect(first["realConversion"]?.boolValue == false)
        #expect(first["sampleRate"]?.doubleValue == 40_000)
        #expect(first["note"]?.stringValue == "smoke")
        #expect(first["file"]?.stringValue?.isEmpty == false)
        #expect(first["extractedPath"]?.stringValue?.contains("voice-source-") == true)
        #expect(response.result?["trackName"]?.stringValue == "Voice: base")
        #expect(response.result?["warnings"]?.arrayValue?.isEmpty == true)
    }

    // MARK: - Provenance (m24-n)

    @Test("m24-n: the landed track records WHICH voice made it — id, display name, pitch")
    func landedTrackCarriesVoiceProvenance() async throws {
        let (store, router, _, clips) = try await makeSession()

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertClips",
            params: ["clipIds": .array([.string(clips[0].id.uuidString)]),
                     "voiceId": .string("base"),
                     "pitchSemitones": .number(-5)]))
        #expect(response.ok, "vc.convertClips failed: \(response.error ?? "?")")

        let trackId = try #require(response.result?["trackId"]?.stringValue)
        let landed = try #require(store.tracks.first { $0.id.uuidString == trackId })
        let provenance = try #require(landed.voiceProvenance)
        #expect(provenance.voiceId == "base")
        // The DISPLAY name comes from the facade's own descriptor, not the id —
        // so the record still reads as something a human recognises after the
        // voice itself is gone.
        #expect(provenance.voiceName == "Base (untrained)")
        #expect(provenance.pitchSemitones == -5)

        // ⚠️ It is a FACT, not a binding: the SOURCE track is untouched, and
        // nothing on the landed track's clips references the voice.
        #expect(store.tracks.first { $0.id.uuidString != trackId }?.voiceProvenance == nil)
    }

    @Test("m24-n: a listing failure never blocks a conversion — the id alone is still a true record")
    func provenanceFallsBackToTheIdWhenListingFails() async throws {
        let (store, router, converting, clips) = try await makeSession()
        await converting.stubVoiceStatus(.failure(VoiceConversionError.requestFailed(
            status: 503, code: "unavailable", message: "sidecar is busy")))

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertClips",
            params: ["clipIds": .array([.string(clips[0].id.uuidString)]),
                     "voiceId": .string("base")]))
        #expect(response.ok, "vc.convertClips failed: \(response.error ?? "?")")
        let trackId = try #require(response.result?["trackId"]?.stringValue)
        let landed = try #require(store.tracks.first { $0.id.uuidString == trackId })
        #expect(landed.voiceProvenance?.voiceId == "base")
        #expect(landed.voiceProvenance?.voiceName == "base")   // the id, honestly
    }

    @Test("trackName and pitchSemitones pass through; the default name is the shared rule")
    func optionalParamsPassThrough() async throws {
        let (store, router, converting, clips) = try await makeSession()

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertClips",
            params: ["clipIds": .array([.string(clips[0].id.uuidString)]),
                     "voiceId": .string("base"),
                     "pitchSemitones": .number(-3),
                     "trackName": .string("Lead Vox (ada)")]))

        #expect(response.ok, "vc.convertClips failed: \(response.error ?? "?")")
        let calls = await converting.convertCalls
        #expect(calls.first?.pitchSemitones == -3)
        #expect(store.tracks.last?.name == "Lead Vox (ada)")
    }

    // MARK: - Param-shape refusals

    @Test("clipIds and voiceId are required, and unknown keys are refused")
    func paramShape() async throws {
        let (store, router, converting, clips) = try await makeSession()
        let tracksBefore = store.tracks.count

        let missingIds = await router.handle(ControlRequest(
            id: "1", command: "vc.convertClips", params: ["voiceId": .string("base")]))
        #expect(!missingIds.ok)
        #expect(missingIds.error?.contains("clipIds") == true)

        let missingVoice = await router.handle(ControlRequest(
            id: "2", command: "vc.convertClips",
            params: ["clipIds": .array([.string(clips[0].id.uuidString)])]))
        #expect(!missingVoice.ok)

        let unknownKey = await router.handle(ControlRequest(
            id: "3", command: "vc.convertClips",
            params: ["clipIds": .array([.string(clips[0].id.uuidString)]),
                     "voiceId": .string("base"),
                     // vc.convertVocals' param — this verb places every clip at
                     // its own source beat, so accepting it would be a lie.
                     "atBeat": .number(8)]))
        #expect(!unknownKey.ok)
        #expect(unknownKey.error?.contains("atBeat") == true)

        let notAUUID = await router.handle(ControlRequest(
            id: "4", command: "vc.convertClips",
            params: ["clipIds": .array([.string("not-a-uuid")]),
                     "voiceId": .string("base")]))
        #expect(!notAUUID.ok)
        #expect(notAUUID.error?.contains("UUID") == true)

        let notAnArray = await router.handle(ControlRequest(
            id: "5", command: "vc.convertClips",
            params: ["clipIds": .string(clips[0].id.uuidString),
                     "voiceId": .string("base")]))
        #expect(!notAnArray.ok)

        let convertCalls = await converting.convertCalls
        #expect(convertCalls.isEmpty, "not one of these may reach the converter")
        #expect(store.tracks.count == tracksBefore)
    }

    // MARK: - Store refusals surface verbatim

    @Test("an empty selection, an unknown id and a MIDI clip all refuse before converting")
    func storeRefusals() async throws {
        let (store, router, converting, clips) = try await makeSession()
        let midiTrack = store.addTrack(kind: .instrument)
        let midiClip = try store.addMIDIClip(
            toTrack: midiTrack.id, name: "notes", atBeat: 16, lengthBeats: 4, notes: [])
        let tracksBefore = store.tracks.count

        let empty = await router.handle(ControlRequest(
            id: "1", command: "vc.convertClips",
            params: ["clipIds": .array([]), "voiceId": .string("base")]))
        #expect(!empty.ok)
        #expect(empty.error?.contains("select at least one") == true)

        let unknown = await router.handle(ControlRequest(
            id: "2", command: "vc.convertClips",
            params: ["clipIds": .array([.string(clips[0].id.uuidString),
                                        .string(UUID().uuidString)]),
                     "voiceId": .string("base")]))
        #expect(!unknown.ok)

        let midi = await router.handle(ControlRequest(
            id: "3", command: "vc.convertClips",
            params: ["clipIds": .array([.string(midiClip.id.uuidString)]),
                     "voiceId": .string("base")]))
        #expect(!midi.ok)
        #expect(midi.error?.contains("MIDI clip") == true)

        let duplicate = await router.handle(ControlRequest(
            id: "4", command: "vc.convertClips",
            params: ["clipIds": .array([.string(clips[0].id.uuidString),
                                        .string(clips[0].id.uuidString)]),
                     "voiceId": .string("base")]))
        #expect(!duplicate.ok)
        #expect(duplicate.error?.contains("twice") == true)

        let convertCalls = await converting.convertCalls
        #expect(convertCalls.isEmpty)
        #expect(store.tracks.count == tracksBefore)
    }

    @Test("overlapping selected clips are refused with a teaching error naming both")
    func overlapRefused() async throws {
        let store = makeStore()
        let trackA = store.addTrack(kind: .audio)
        let trackB = store.addTrack(kind: .audio)
        let source = URL(fileURLWithPath: "/tmp/lead-vox.wav")
        // 4 beats each (FakeMedia's 2.0 s @ 120 bpm), so 0..4 and 2..6 overlap.
        let a = try store.importAudio(url: source, toTrack: trackA.id, atBeat: 0)
        let b = try store.importAudio(url: source, toTrack: trackB.id, atBeat: 2)
        let converting = FakeVoiceConverting()
        let router = makeRouter(store: store, converting: converting)
        let tracksBefore = store.tracks.count

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertClips",
            params: ["clipIds": .array([.string(a.id.uuidString), .string(b.id.uuidString)]),
                     "voiceId": .string("base")]))

        #expect(!response.ok)
        let message = try #require(response.error)
        #expect(message.contains("overlap"))
        #expect(message.contains("two passes"))
        let convertCalls = await converting.convertCalls
        #expect(convertCalls.isEmpty, "refuse BEFORE paying for a conversion")
        #expect(store.tracks.count == tracksBefore)
    }

    @Test("a facade teaching error surfaces verbatim and nothing lands")
    func facadeErrorSurfaces() async throws {
        let (store, router, converting, clips) = try await makeSession()
        await converting.stubConvert(.failure(VoiceConversionError.requestFailed(
            status: 404, code: "unknownVoice", message: "no voice with id 'nope'")))
        let tracksBefore = store.tracks.count

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertClips",
            params: ["clipIds": .array([.string(clips[0].id.uuidString),
                                        .string(clips[1].id.uuidString)]),
                     "voiceId": .string("nope")]))

        #expect(!response.ok)
        #expect(response.error?.contains("unknownVoice") == true)
        #expect(response.error?.contains("no voice with id 'nope'") == true)
        #expect(store.tracks.count == tracksBefore, "a failed set lands nothing")
    }

    // MARK: - m24-o on the single-clip verb

    @Test("vc.convertVocals' clipId form no longer converts the backing recording")
    func singleClipVerbAlsoFixed() async throws {
        let store = makeStore()
        let track = store.addTrack(kind: .audio)
        let backing = URL(fileURLWithPath: "/tmp/whole-take.wav")
        let clip = try store.importAudio(url: backing, toTrack: track.id, atBeat: 4)
        let converting = FakeVoiceConverting()
        await converting.stubConvert(.success(VoiceConvertResult(
            outputPath: try writeTinyWAV().path, voiceId: "base", inputSeconds: 2,
            engineLoadSeconds: 0, inferSeconds: 0.05, rtf: nil, sampleRate: 40_000,
            realConversion: false, note: nil)))
        let router = makeRouter(store: store, converting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals",
            params: ["clipId": .string(clip.id.uuidString), "voiceId": .string("base")]))

        #expect(response.ok, "vc.convertVocals failed: \(response.error ?? "?")")
        let calls = await converting.convertCalls
        #expect(calls.first?.inputPath != backing.path)
        #expect(calls.first?.inputPath.contains("voice-source-") == true)
    }
}
