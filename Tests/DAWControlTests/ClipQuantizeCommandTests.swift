import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M5 (iii-d) `clip.quantize`: the round-trip over
/// ProjectStore.quantizeClipNotes, MPC swing on the wire, field-named param
/// validation (gridBeats/strength/swing ranges — the parseFadeCurve style), and
/// store rejections (audio clip / unknown id) surfacing verbatim. Reuses
/// `FakeMedia` from ControlTests.swift (same target).
@MainActor
@Suite("Clip quantize — control protocol")
struct ClipQuantizeCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// Adds an instrument track + one 8-beat MIDI clip carrying `notes`,
    /// returning the clip id as a wire string.
    private func addMIDIClip(_ router: CommandRouter, notes: [JSONValue]) async throws -> String {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(8), "notes": .array(notes)]))
        return try #require(addClip.result?["id"]?.stringValue)
    }

    // 1.
    @Test("clip.quantize snaps onsets at strength 1, preserves lengths, store reflects")
    func happyPath() async throws {
        let (router, store) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: [
            .object(["pitch": .number(60), "startBeat": .number(0.2), "lengthBeats": .number(1)]),
            .object(["pitch": .number(64), "startBeat": .number(1.1), "lengthBeats": .number(0.5)]),
            .object(["pitch": .number(67), "startBeat": .number(1.9), "lengthBeats": .number(0.5)]),
        ])
        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.quantize",
            params: ["clipId": .string(clipID), "gridBeats": .number(1), "strength": .number(1)]))
        #expect(resp.ok)
        let notes = try #require(resp.result?["notes"]?.arrayValue)
        #expect(notes.compactMap { $0["startBeat"]?.doubleValue } == [0.0, 1.0, 2.0])
        #expect(notes.compactMap { $0["lengthBeats"]?.doubleValue } == [1.0, 0.5, 0.5])
        #expect(store.tracks[0].clips[0].notes!.map(\.startBeat) == [0.0, 1.0, 2.0])
    }

    // 2.
    @Test("swing 66 delays the offbeat slot by (2·0.66 − 1)·grid on the wire")
    func swing() async throws {
        let (router, _) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: [
            .object(["pitch": .number(60), "startBeat": .number(0.1), "lengthBeats": .number(1)]),  // slot 0 → 0
            .object(["pitch": .number(62), "startBeat": .number(0.9), "lengthBeats": .number(1)]),  // slot 1 → 1.32
        ])
        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.quantize",
            params: ["clipId": .string(clipID), "gridBeats": .number(1),
                     "strength": .number(1), "swing": .number(66)]))
        #expect(resp.ok)
        let starts = try #require(resp.result?["notes"]?.arrayValue).compactMap { $0["startBeat"]?.doubleValue }
        #expect(starts.count == 2)
        #expect(abs(starts[0] - 0.0) < 1e-9)
        #expect(abs(starts[1] - 1.32) < 1e-9)
    }

    // 3.
    @Test("param validation: gridBeats required + > 0, strength 0...1, swing 50...75, field-named")
    func paramValidation() async throws {
        let (router, _) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: [
            .object(["pitch": .number(60), "startBeat": .number(0.2)]),
        ])
        func quantize(_ extra: [String: JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(id: "1", command: "clip.quantize",
                params: extra.merging(["clipId": .string(clipID)]) { a, _ in a }))
        }
        let missingGrid = await quantize([:])
        #expect(!missingGrid.ok)
        #expect(missingGrid.error?.contains("gridBeats") == true)

        let zeroGrid = await quantize(["gridBeats": .number(0)])
        #expect(!zeroGrid.ok)
        #expect(zeroGrid.error?.contains("greater than 0") == true)

        let badStrength = await quantize(["gridBeats": .number(1), "strength": .number(2)])
        #expect(!badStrength.ok)
        #expect(badStrength.error?.contains("strength") == true)

        let badSwing = await quantize(["gridBeats": .number(1), "swing": .number(90)])
        #expect(!badSwing.ok)
        #expect(badSwing.error?.contains("swing") == true)
    }

    // 4.
    @Test("store rejections surface verbatim: audio clip, unknown id")
    func storeRejections() async throws {
        let (router, _) = makeRouter()
        // Audio clip → quantizeRequiresMIDIClip verbatim.
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let audioTrackID = try #require(addTrack.result?["id"]?.stringValue)
        let addAudio = await router.handle(ControlRequest(
            id: "a", command: "clip.addAudio",
            params: ["trackId": .string(audioTrackID), "path": .string("/tmp/Loop.wav")]))
        let audioClipID = try #require(addAudio.result?["id"]?.stringValue)
        let onAudio = await router.handle(ControlRequest(
            id: "1", command: "clip.quantize",
            params: ["clipId": .string(audioClipID), "gridBeats": .number(1)]))
        #expect(!onAudio.ok)
        #expect(onAudio.error?.contains("clip.quantize applies only to MIDI clips") == true)

        // Unknown clip id → clipNotFound verbatim.
        let onMissing = await router.handle(ControlRequest(
            id: "2", command: "clip.quantize",
            params: ["clipId": .string(UUID().uuidString), "gridBeats": .number(1)]))
        #expect(!onMissing.ok)
        #expect(onMissing.error?.contains("no clip with id") == true)
    }

    // 5.
    @Test("allCommands advertises clip.quantize")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("clip.quantize"))
    }
}
