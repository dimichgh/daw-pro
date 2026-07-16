import Foundation
import Testing
@testable import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m16-e (audit F3+F5+F8, "wire hardening round
/// 2"): broad `rejectUnknownKeys` application (F5 — the `track.add` wrong-
/// object-created trap the m15-d survey missed), `project.new`/`open`/`save`
/// recovery honesty (F3 — `discardedRecovery`), `project.recoveryBundles` (the
/// per-slug autosave listing seam), `recoveryStatus.savedAt` ISO-8601 (F8a),
/// and the F8 error-copy basket (quantize dual-error, songSkeleton genre list
/// — the latter pinned in `MacroSkeletonCommandTests`).
@MainActor
@Suite("Wire hardening round 2 — control protocol (m16-e)")
struct WireHardeningM16ETests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m16e-wire-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRouter(dir: URL? = nil) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        if let dir {
            store.crashRecovery.directory = dir
            store.crashRecovery.clock = { Date(timeIntervalSince1970: 1000) }
        }
        return (CommandRouter(store: store), store)
    }

    // MARK: - F5: track.add wrong-object-created trap (G1)

    @Test("track.add {type:} is rejected verbatim — the audit's measured wrong-object-created trap")
    func trackAddRejectsTypoedType() async throws {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.add",
            params: ["type": .string("instrument")]))
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("track.add"))
        #expect(error.contains("'type'"))
        #expect(error.contains("'kind'"))
        // Nothing was created — the trap is fully closed, not just diagnosed.
        #expect(store.tracks.isEmpty)
    }

    @Test("track.add {kind:} still works — the fixed path is unaffected")
    func trackAddKindStillWorks() async throws {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.add",
            params: ["kind": .string("instrument"), "name": .string("Synth")]))
        #expect(response.ok)
        #expect(store.tracks.first?.kind == .instrument)
        #expect(store.tracks.first?.name == "Synth")
    }

    @Test("track.add with no params still defaults to an audio track (omit semantics unchanged)")
    func trackAddOmitStillDefaultsAudio() async throws {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "track.add"))
        #expect(response.ok)
        #expect(store.tracks.first?.kind == .audio)
    }

    // MARK: - F5: broad rejectUnknownKeys sample (G3 — five+ mutating verbs)

    @Test("track.setVolume rejects an unknown key")
    func trackSetVolumeRejectsUnknownKey() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "T", kind: .audio)
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setVolume",
            params: ["trackId": .string(track.id.uuidString), "volum": .number(0.5)]))
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("track.setVolume"))
        #expect(error.contains("'volum'"))
        #expect(error.contains("'volume'"))
        // Nothing changed.
        #expect(store.tracks.first?.volume == 1.0)
    }

    @Test("clip.setGain rejects an unknown key")
    func clipSetGainRejectsUnknownKey() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "T", kind: .audio)
        let clip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/x.wav"), toTrack: track.id, atBeat: 0)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setGain",
            params: ["trackId": .string(track.id.uuidString), "clipId": .string(clip.id.uuidString),
                     "gain": .number(-6)]))
        #expect(!response.ok)
        #expect(response.error?.contains("'gain'") == true)
        #expect(response.error?.contains("'gainDb'") == true)
    }

    @Test("arrange.insertBars rejects an unknown key")
    func arrangeInsertBarsRejectsUnknownKey() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "arrange.insertBars",
            params: ["atBar": .number(1), "count": .number(2), "coutn": .number(2)]))
        #expect(!response.ok)
        #expect(response.error?.contains("'coutn'") == true)
    }

    @Test("render.mixdown rejects an unknown key (F5's own cited example — lengthBeats vs durationSeconds)")
    func renderMixdownRejectsLengthBeatsGuess() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "render.mixdown",
            params: ["lengthBeats": .number(8)]))
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("'lengthBeats'"))
        #expect(error.contains("'durationSeconds'"))
    }

    @Test("ai.copilotSend rejects an unknown key")
    func copilotSendRejectsUnknownKey() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotSend",
            params: ["message": .string("hi"), "mesage": .string("hi")]))
        #expect(!response.ok)
        #expect(response.error?.contains("'mesage'") == true)
    }

    @Test("plugin.closeUI rejects an unknown key")
    func pluginCloseUIRejectsUnknownKey() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "plugin.closeUI",
            params: ["trackId": .string(UUID().uuidString), "efectId": .string(UUID().uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("'efectId'") == true)
    }

    @Test("permissive partial-update verbs keep omit-current-value semantics unchanged by the reject call")
    func partialUpdateOmitSemanticsUnchanged() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "Synth", kind: .instrument)
        _ = try store.setInstrument(id: track.id, kind: .polySynth, waveform: .saw,
                                     attack: nil, decay: nil, sustain: nil, release: nil,
                                     cutoffHz: nil, resonance: nil, gain: nil,
                                     sampler: nil, audioUnit: nil, soundBank: nil)
        // Omitting `waveform` on a follow-up call must still KEEP the current
        // value (unaffected by rejectUnknownKeys — only unrecognized keys throw).
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(track.id.uuidString), "gain": .number(0.5)]))
        #expect(response.ok)
        #expect(response.result?["polySynth"]?["waveform"]?.stringValue == "saw")
    }

    // MARK: - F3: recovery honesty

    private func stageAvailableOffer(_ store: ProjectStore) async {
        _ = store.beginCrashDetection()
        store.addTrack(name: "Recovered")
        try? store.setTempo(128)
        await store.autosaveTick()
        _ = store.beginCrashDetection()
    }

    @Test("project.new surfaces discardedRecovery when it silently would have destroyed a pending offer")
    func projectNewSurfacesDiscardedRecovery() async throws {
        let dir = tempDir()
        let (router, store) = makeRouter(dir: dir)
        await stageAvailableOffer(store)
        #expect(store.recoveryStatus().available)

        let response = await router.handle(ControlRequest(id: "1", command: "project.new"))
        #expect(response.ok)
        let discarded = response.result?["discardedRecovery"]
        #expect(discarded != nil)
        #expect(discarded?["editCount"]?.doubleValue ?? 0 > 0)
        #expect(discarded?["savedAt"]?.stringValue != nil)
        #expect(discarded?["available"] == nil, "available is redundant in this echo and is stripped")
        // The offer really is gone now.
        #expect(!store.recoveryStatus().available)
    }

    @Test("project.new omits discardedRecovery when there was nothing to discard")
    func projectNewOmitsDiscardedRecoveryWhenNoneAvailable() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "project.new"))
        #expect(response.ok)
        #expect(response.result?["discardedRecovery"] == nil)
    }

    @Test("project.open surfaces discardedRecovery when it consumes a pending offer")
    func projectOpenSurfacesDiscardedRecovery() async throws {
        // A minimal savable project to open, built and saved through an
        // UNRELATED store (its own default crash-recovery machinery is never
        // touched), so opening it on the store under test is the ONLY thing
        // that consumes that store's staged offer.
        let otherStore = ProjectStore()
        otherStore.media = FakeMedia()
        otherStore.crashRecovery.directory = tempDir()
        otherStore.addTrack(name: "Other")
        let savePath = tempDir().appendingPathComponent("Other.dawproj").path
        try otherStore.saveProject(to: savePath)

        let dir = tempDir()
        let (router, store) = makeRouter(dir: dir)
        await stageAvailableOffer(store)
        #expect(store.recoveryStatus().available)

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.open", params: ["path": .string(savePath)]))
        #expect(response.ok)
        #expect(response.result?["discardedRecovery"] != nil)
        #expect(!store.recoveryStatus().available)
    }

    @Test("project.save surfaces discardedRecovery when it consumes a pending offer")
    func projectSaveSurfacesDiscardedRecovery() async throws {
        let dir = tempDir()
        let (router, store) = makeRouter(dir: dir)
        await stageAvailableOffer(store)
        #expect(store.recoveryStatus().available)

        let saveDir = tempDir()
        let savePath = saveDir.appendingPathComponent("Mine.dawproj").path
        let response = await router.handle(ControlRequest(
            id: "1", command: "project.save", params: ["path": .string(savePath)]))
        #expect(response.ok)
        #expect(response.result?["discardedRecovery"] != nil)
        #expect(!store.recoveryStatus().available)
    }

    @Test("project.recover does NOT carry discardedRecovery — recovered/discarded already say it")
    func projectRecoverOmitsDiscardedRecoveryField() async throws {
        let dir = tempDir()
        let (router, store) = makeRouter(dir: dir)
        await stageAvailableOffer(store)

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.recover", params: ["accept": .bool(true)]))
        #expect(response.ok)
        #expect(response.result?["recovered"]?.boolValue == true)
        #expect(response.result?["discardedRecovery"] == nil)
    }

    // MARK: - F8a: recoveryStatus.savedAt is ISO-8601

    @Test("recoveryStatus.savedAt is ISO-8601, not raw epoch seconds")
    func recoveryStatusSavedAtIsISO8601() async throws {
        let dir = tempDir()
        let (router, store) = makeRouter(dir: dir)
        await stageAvailableOffer(store)

        let response = await router.handle(ControlRequest(id: "1", command: "project.recoveryStatus"))
        #expect(response.ok)
        let savedAt = try #require(response.result?["savedAt"]?.stringValue)
        // Pin the exact format: the fixed clock is 1970-01-01T00:16:40Z.
        #expect(savedAt == "1970-01-01T00:16:40Z")
        // And it round-trips through ISO8601DateFormatter.
        #expect(ISO8601DateFormatter().date(from: savedAt) != nil)
    }

    // MARK: - project.recoveryBundles (F3: per-slug autosaves wire-discoverable)

    @Test("allCommands advertises project.recoveryBundles")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("project.recoveryBundles"))
    }

    @Test("recoveryBundles lists a flushed untitled session and is openable via project.open")
    func recoveryBundlesListsAndOpens() async throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.media = FakeMedia()
        store.autosaveRecoveryDirectory = dir
        store.addTrack(name: "Abandoned", kind: .audio)
        // An untitled dirty session flushed via `project.new` writes the per-slug
        // bundle (flushForTransition → writeRecoveryBundle).
        try store.newProject()

        let router = CommandRouter(store: store)
        let response = await router.handle(ControlRequest(id: "1", command: "project.recoveryBundles"))
        #expect(response.ok)
        let bundles = try #require(response.result?["bundles"]?.arrayValue)
        #expect(bundles.count == 1)
        let entry = bundles[0]
        #expect(entry["path"]?.stringValue?.hasSuffix(".dawproj") == true)
        #expect(entry["isCurrentSession"]?.boolValue == true)
        let savedAt = try #require(entry["savedAt"]?.stringValue)
        #expect(ISO8601DateFormatter().date(from: savedAt) != nil)

        // It really is a plain openable .dawproj bundle.
        let path = try #require(entry["path"]?.stringValue)
        let openResponse = await router.handle(ControlRequest(
            id: "2", command: "project.open",
            params: ["path": .string(path), "discardChanges": .bool(true)]))
        #expect(openResponse.ok)
        #expect(store.tracks.contains { $0.name == "Abandoned" })
    }

    @Test("recoveryBundles reads an empty list when the Autosave directory has never been written")
    func recoveryBundlesEmptyWhenNoneWritten() async throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.media = FakeMedia()
        store.autosaveRecoveryDirectory = dir
        let router = CommandRouter(store: store)
        let response = await router.handle(ControlRequest(id: "1", command: "project.recoveryBundles"))
        #expect(response.ok)
        #expect(response.result?["bundles"]?.arrayValue?.isEmpty == true)
    }

    // MARK: - F8b: clip.quantize dual-error round-trip

    private func addMIDIClip(_ router: CommandRouter) async throws -> String {
        let track = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(track.result?["id"]?.stringValue)
        let clip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI", params: ["trackId": .string(trackID)]))
        return try #require(clip.result?["id"]?.stringValue)
    }

    @Test("clip.quantize with a missing gridBeats AND an unknown groove reports BOTH in one round trip")
    func quantizeDualErrorReportsBoth() async throws {
        let (router, _) = makeRouter()
        let clipID = try await addMIDIClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.quantize",
            params: ["clipId": .string(clipID), "groove": .string("not-a-groove")]))
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("gridBeats"))
        #expect(error.contains("'groove'"))
        #expect(error.contains("clip.quantize"))
    }

    @Test("clip.quantize with only ONE problem keeps the plain single-error message")
    func quantizeSingleErrorUnchanged() async throws {
        let (router, _) = makeRouter()
        let clipID = try await addMIDIClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.quantize", params: ["clipId": .string(clipID)]))
        #expect(!response.ok)
        #expect(response.error == "missing or invalid required param 'gridBeats'")
    }

    @Test("clip.quantizeAudio with a bad gridBeats AND an unknown groove reports BOTH")
    func quantizeAudioDualErrorReportsBoth() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "A", kind: .audio)
        let clip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/x.wav"), toTrack: track.id, atBeat: 0)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.quantizeAudio",
            params: ["trackId": .string(track.id.uuidString), "clipId": .string(clip.id.uuidString),
                     "gridBeats": .number(0), "groove": .string("not-a-groove")]))
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("greater than 0"))
        #expect(error.contains("'groove'"))
    }

    // MARK: - F5 survey completion: the zero-param mutating verbs the initial
    // sweep missed (transport.play/stop/record, edit.undo/redo,
    // ai.copilotReset, ai.sidecarStart/Stop) — "No params" documented in each
    // doc comment but nothing previously enforced it, so a typo'd param was
    // silently ignored rather than taught.

    @Test("transport.play rejects a stray param instead of silently ignoring it")
    func transportPlayRejectsUnknownKey() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "transport.play", params: ["bpm": .number(120)]))
        #expect(!response.ok)
        #expect(response.error?.contains("'bpm'") == true)
        #expect(response.error?.contains("transport.play") == true)
    }

    @Test("transport.play with truly no params still works")
    func transportPlayNoParamsStillWorks() async throws {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "transport.play"))
        #expect(response.ok)
        #expect(store.transport.isPlaying)
    }

    @Test("edit.undo rejects a stray param")
    func editUndoRejectsUnknownKey() async throws {
        let (router, store) = makeRouter()
        store.addTrack(name: "T")
        let response = await router.handle(ControlRequest(
            id: "1", command: "edit.undo", params: ["step": .number(1)]))
        #expect(!response.ok)
        #expect(response.error?.contains("'step'") == true)
    }

    @Test("ai.sidecarStop rejects a stray param")
    func sidecarStopRejectsUnknownKey() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.sidecarStop", params: ["force": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("'force'") == true)
    }
}
