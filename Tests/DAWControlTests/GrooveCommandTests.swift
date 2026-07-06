import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M5 (iii-g) grooves: the three `groove.*`
/// commands (extract/list/remove) over the ProjectStore ops, plus the `groove`
/// param on `clip.quantize` and `clip.quantizeAudio` (built-in swing resolution,
/// applied targets, and the field-named unknown-ref error). Reuses `FakeMedia`
/// (ControlTests.swift) and `FakeTransientEngine` (ClipTransientCommandTests.swift)
/// from the same target.
@MainActor
@Suite("Groove — control protocol")
struct GrooveCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func addMIDIClip(_ router: CommandRouter, notes: [JSONValue]) async throws -> String {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(8), "notes": .array(notes)]))
        return try #require(addClip.result?["id"]?.stringValue)
    }

    /// A swung-8th note list: downbeats straight, offbeats late by 0.16.
    private var swungNotes: [JSONValue] {
        [
            .object(["pitch": .number(60), "startBeat": .number(0.0), "lengthBeats": .number(0.5)]),
            .object(["pitch": .number(62), "startBeat": .number(0.66), "lengthBeats": .number(0.5)]),
            .object(["pitch": .number(64), "startBeat": .number(1.0), "lengthBeats": .number(0.5)]),
            .object(["pitch": .number(65), "startBeat": .number(1.66), "lengthBeats": .number(0.5)]),
        ]
    }

    // 1. groove.extract (MIDI) returns the {groove} with the recovered offsets.
    @Test("groove.extract from a MIDI clip returns the offset table")
    func extractMIDI() async throws {
        let (router, store) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: swungNotes)
        let resp = await router.handle(ControlRequest(
            id: "1", command: "groove.extract",
            params: ["clipId": .string(clipID), "name": .string("Feel"),
                     "gridBeats": .number(0.5), "cycleBeats": .number(1.0)]))
        #expect(resp.ok)
        let groove = try #require(resp.result?["groove"]?.objectValue)
        #expect(groove["name"]?.stringValue == "Feel")
        let offsets = try #require(groove["offsets"]?.arrayValue).compactMap(\.doubleValue)
        #expect(offsets.count == 2)
        #expect(abs(offsets[0] - 0.0) < 1e-9)
        #expect(abs(offsets[1] - 0.16) < 1e-9)
        #expect(store.grooveTemplates.count == 1)
    }

    // 2. groove.list returns saved templates + the 8 built-in swings.
    @Test("groove.list returns saved templates and built-in swings")
    func list() async throws {
        let (router, _) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: swungNotes)
        _ = await router.handle(ControlRequest(
            id: "e", command: "groove.extract",
            params: ["clipId": .string(clipID), "name": .string("Feel"),
                     "gridBeats": .number(0.5), "cycleBeats": .number(1.0)]))
        let resp = await router.handle(ControlRequest(id: "1", command: "groove.list", params: [:]))
        #expect(resp.ok)
        let templates = try #require(resp.result?["templates"]?.arrayValue)
        #expect(templates.count == 1)
        #expect(templates[0]["name"]?.stringValue == "Feel")
        let builtins = try #require(resp.result?["builtins"]?.arrayValue)
        #expect(builtins.count == 8)
        let names = builtins.compactMap { $0["name"]?.stringValue }
        #expect(names.contains("swing8:66") && names.contains("swing16:54"))
    }

    // 3. groove.remove deletes by id; edit.undo restores it; unknown id verbatim.
    @Test("groove.remove deletes, edit.undo restores, unknown id → grooveNotFound verbatim")
    func remove() async throws {
        let (router, store) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: swungNotes)
        let extract = await router.handle(ControlRequest(
            id: "e", command: "groove.extract",
            params: ["clipId": .string(clipID), "name": .string("Feel"),
                     "gridBeats": .number(0.5), "cycleBeats": .number(1.0)]))
        let grooveID = try #require(extract.result?["groove"]?["id"]?.stringValue)

        let removed = await router.handle(ControlRequest(
            id: "1", command: "groove.remove", params: ["grooveId": .string(grooveID)]))
        #expect(removed.ok)
        #expect(removed.result?["removed"]?.boolValue == true)
        #expect(store.grooveTemplates.isEmpty)

        // edit.undo restores the removed template.
        let undo = await router.handle(ControlRequest(id: "u", command: "edit.undo", params: [:]))
        #expect(undo.ok)
        #expect(store.grooveTemplates.count == 1)

        // Unknown id → grooveNotFound verbatim.
        let bogus = UUID().uuidString
        let missing = await router.handle(ControlRequest(
            id: "2", command: "groove.remove", params: ["grooveId": .string(bogus)]))
        #expect(!missing.ok)
        #expect(missing.error == "no groove template with id \(bogus) — use groove.list to see saved templates and built-in swings")
    }

    // 4. clip.quantize with a built-in swing groove lands onsets on groove targets.
    @Test("clip.quantize groove param applies built-in swing targets")
    func quantizeWithBuiltin() async throws {
        let (router, _) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: [
            .object(["pitch": .number(60), "startBeat": .number(0.02), "lengthBeats": .number(0.5)]),
            .object(["pitch": .number(62), "startBeat": .number(0.48), "lengthBeats": .number(0.5)]),
            .object(["pitch": .number(64), "startBeat": .number(1.03), "lengthBeats": .number(0.5)]),
            .object(["pitch": .number(65), "startBeat": .number(1.47), "lengthBeats": .number(0.5)]),
        ])
        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.quantize",
            params: ["clipId": .string(clipID), "gridBeats": .number(0.5),
                     "strength": .number(1), "groove": .string("swing8:66")]))
        #expect(resp.ok)
        let starts = try #require(resp.result?["notes"]?.arrayValue).compactMap { $0["startBeat"]?.doubleValue }
        #expect(starts.count == 4)
        #expect(abs(starts[0] - 0.0) < 1e-9)
        #expect(abs(starts[1] - 0.66) < 1e-9)
        #expect(abs(starts[2] - 1.0) < 1e-9)
        #expect(abs(starts[3] - 1.66) < 1e-9)
    }

    // 5. clip.quantize with a saved template id/name resolves and applies it.
    @Test("clip.quantize groove param resolves a saved template by id and name")
    func quantizeWithSavedTemplate() async throws {
        let (router, _) = makeRouter()
        let refID = try await addMIDIClip(router, notes: swungNotes)
        let extract = await router.handle(ControlRequest(
            id: "e", command: "groove.extract",
            params: ["clipId": .string(refID), "name": .string("Verse feel"),
                     "gridBeats": .number(0.5), "cycleBeats": .number(1.0)]))
        let grooveID = try #require(extract.result?["groove"]?["id"]?.stringValue)

        // A straight clip to quantize TO the saved feel.
        let targetID = try await addMIDIClip(router, notes: [
            .object(["pitch": .number(60), "startBeat": .number(0.5), "lengthBeats": .number(0.5)]),  // offbeat → 0.66
        ])
        // Each call re-quantizes the same clip; the offbeat target is stable.
        func quantize(_ ref: String) async -> ControlResponse {
            await router.handle(ControlRequest(
                id: "q", command: "clip.quantize",
                params: ["clipId": .string(targetID), "gridBeats": .number(0.5),
                         "strength": .number(1), "groove": .string(ref)]))
        }
        for ref in [grooveID, "Verse feel"] {
            let resp = await quantize(ref)
            #expect(resp.ok)
            let notes = try #require(resp.result?["notes"]?.arrayValue)
            let start = try #require(notes.first?["startBeat"]?.doubleValue)
            #expect(abs(start - 0.66) < 1e-9)
        }
    }

    // 6. Unknown groove ref is a field-named 'groove' error on BOTH quantize
    //    commands (resolved before any store mutation / engine call).
    @Test("unknown groove ref → field-named 'groove' error on both quantize commands")
    func unknownGrooveRef() async throws {
        let (router, _) = makeRouter()
        let midiID = try await addMIDIClip(router, notes: swungNotes)
        let midiErr = await router.handle(ControlRequest(
            id: "1", command: "clip.quantize",
            params: ["clipId": .string(midiID), "gridBeats": .number(0.5),
                     "groove": .string("not-a-groove")]))
        #expect(!midiErr.ok)
        #expect(midiErr.error?.contains("'groove'") == true)
        #expect(midiErr.error?.contains("groove.list") == true)

        // clip.quantizeAudio: the groove resolves in param parsing, BEFORE the
        // engine call, so the unknown-ref error surfaces even headless.
        let addAudioTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let audioTrackID = try #require(addAudioTrack.result?["id"]?.stringValue)
        let addAudio = await router.handle(ControlRequest(
            id: "a", command: "clip.addAudio",
            params: ["trackId": .string(audioTrackID), "path": .string("/tmp/Loop.wav")]))
        let audioClipID = try #require(addAudio.result?["id"]?.stringValue)
        let audioErr = await router.handle(ControlRequest(
            id: "2", command: "clip.quantizeAudio",
            params: ["trackId": .string(audioTrackID), "clipId": .string(audioClipID),
                     "gridBeats": .number(0.5), "groove": .string("not-a-groove")]))
        #expect(!audioErr.ok)
        #expect(audioErr.error?.contains("'groove'") == true)
    }

    // 7. groove.extract param validation: name required, positive grid/cycle.
    @Test("groove.extract param validation is field-named")
    func extractValidation() async throws {
        let (router, _) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: swungNotes)
        func extract(_ extra: [String: JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(id: "1", command: "groove.extract",
                params: extra.merging(["clipId": .string(clipID)]) { a, _ in a }))
        }
        let missingName = await extract([:])
        #expect(!missingName.ok)
        #expect(missingName.error?.contains("name") == true)

        let badGrid = await extract(["name": .string("g"), "gridBeats": .number(0)])
        #expect(!badGrid.ok)
        #expect(badGrid.error?.contains("gridBeats") == true)

        let badCycle = await extract(["name": .string("g"), "cycleBeats": .number(-1)])
        #expect(!badCycle.ok)
        #expect(badCycle.error?.contains("cycleBeats") == true)
    }

    // 8. allCommands advertises the three groove commands.
    @Test("allCommands advertises groove.extract/list/remove")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("groove.extract"))
        #expect(CommandRouter.allCommands.contains("groove.list"))
        #expect(CommandRouter.allCommands.contains("groove.remove"))
    }
}
