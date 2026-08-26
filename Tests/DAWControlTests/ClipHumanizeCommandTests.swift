import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M7 (macro-a) `clip.humanize`: the round-trip
/// over ProjectStore.humanizeClipNotes, `seedUsed` in the response envelope,
/// field-named param validation (timingBeats/velocityRange ranges — the
/// parseFadeCurve style), explicit-seed reproducibility THROUGH THE WIRE, and
/// the non-MIDI rejection surfacing verbatim. Reuses `FakeMedia` from
/// ControlTests.swift (same target).
@MainActor
@Suite("Clip humanize — control protocol")
struct ClipHumanizeCommandTests {
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

    private func sampleNotes() -> [JSONValue] {
        [
            .object(["pitch": .number(60), "velocity": .number(90), "startBeat": .number(0.5), "lengthBeats": .number(1)]),
            .object(["pitch": .number(64), "velocity": .number(80), "startBeat": .number(1.5), "lengthBeats": .number(0.5)]),
            .object(["pitch": .number(67), "velocity": .number(100), "startBeat": .number(2.5), "lengthBeats": .number(0.5)]),
        ]
    }

    // 1.
    @Test("happy path returns the updated clip fields plus seedUsed; store reflects")
    func happyPath() async throws {
        let (router, store) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: sampleNotes())
        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.humanize",
            params: ["clipId": .string(clipID), "timingBeats": .number(0.05),
                     "velocityRange": .number(12), "seed": .number(42)]))
        #expect(resp.ok)
        // Clip fields sit at the top level (the clip.setNotes/clip.quantize shape).
        let notes = try #require(resp.result?["notes"]?.arrayValue)
        #expect(notes.count == 3)
        // seedUsed sits alongside the clip fields, echoing the explicit seed.
        #expect(resp.result?["seedUsed"]?.doubleValue == 42)
        // Lengths untouched; store reflects the same jittered notes.
        #expect(notes.compactMap { $0["lengthBeats"]?.doubleValue } == [1.0, 0.5, 0.5])
        #expect(store.tracks[0].clips[0].notes!.count == 3)
    }

    // 2.
    @Test("param validation: timingBeats 0...0.25, velocityRange 0...64, missing clipId — field-named")
    func paramValidation() async throws {
        let (router, _) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: sampleNotes())
        func humanize(_ extra: [String: JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(id: "1", command: "clip.humanize",
                params: extra.merging(["clipId": .string(clipID)]) { a, _ in a }))
        }
        // Missing clipId → named 'clipId'.
        let missingClip = await router.handle(ControlRequest(
            id: "1", command: "clip.humanize", params: ["timingBeats": .number(0.02)]))
        #expect(!missingClip.ok)
        #expect(missingClip.error?.contains("clipId") == true)

        // timingBeats above 0.25 → named 'timingBeats'.
        let badTiming = await humanize(["timingBeats": .number(0.5)])
        #expect(!badTiming.ok)
        #expect(badTiming.error?.contains("timingBeats") == true)

        // velocityRange above 64 → named 'velocityRange'.
        let badVel = await humanize(["velocityRange": .number(100)])
        #expect(!badVel.ok)
        #expect(badVel.error?.contains("velocityRange") == true)
    }

    // 3.
    @Test("explicit seed reproduces the exact jittered notes through the wire")
    func reproducibleThroughWire() async throws {
        let (router, _) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: sampleNotes())

        func humanizeSeeded() async -> ControlResponse {
            await router.handle(ControlRequest(
                id: "h", command: "clip.humanize",
                params: ["clipId": .string(clipID), "timingBeats": .number(0.05),
                         "velocityRange": .number(12), "seed": .number(777)]))
        }

        let first = await humanizeSeeded()
        #expect(first.ok)
        #expect(first.result?["seedUsed"]?.doubleValue == 777)
        let firstNotes = try #require(first.result?["notes"]?.arrayValue)

        // Undo the humanize so the second call starts from the same base.
        let undo = await router.handle(ControlRequest(id: "u", command: "edit.undo", params: [:]))
        #expect(undo.ok)

        let second = await humanizeSeeded()
        #expect(second.ok)
        let secondNotes = try #require(second.result?["notes"]?.arrayValue)
        #expect(firstNotes == secondNotes)   // same seed → byte-identical notes on the wire
    }

    // 4.
    @Test("store rejections surface verbatim: audio clip → notAMIDIClip, unknown id")
    func storeRejections() async throws {
        let (router, _) = makeRouter()
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let audioTrackID = try #require(addTrack.result?["id"]?.stringValue)
        let addAudio = await router.handle(ControlRequest(
            id: "a", command: "clip.addAudio",
            params: ["trackId": .string(audioTrackID), "path": .string("/tmp/Loop.wav")]))
        let audioClipID = try #require(addAudio.result?["id"]?.stringValue)
        let onAudio = await router.handle(ControlRequest(
            id: "1", command: "clip.humanize", params: ["clipId": .string(audioClipID)]))
        #expect(!onAudio.ok)
        #expect(onAudio.error?.contains("is an audio clip") == true)

        let onMissing = await router.handle(ControlRequest(
            id: "2", command: "clip.humanize", params: ["clipId": .string(UUID().uuidString)]))
        #expect(!onMissing.ok)
        #expect(onMissing.error?.contains("no clip with id") == true)
    }

    // 5.
    @Test("allCommands advertises clip.humanize")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("clip.humanize"))
    }

    // MARK: - Legato / gate params (m27-o ⓑ)

    /// Notes with a small gap, a LARGE gap (a breath rest) and an abutment, in
    /// an 8-beat clip — the shape the field report measured on 225 sax notes.
    private func breathNotes() -> [JSONValue] {
        [
            .object(["pitch": .number(60), "velocity": .number(90), "startBeat": .number(0), "lengthBeats": .number(0.9)]),
            .object(["pitch": .number(62), "velocity": .number(90), "startBeat": .number(1), "lengthBeats": .number(1)]),
            .object(["pitch": .number(64), "velocity": .number(90), "startBeat": .number(2.5), "lengthBeats": .number(1)]),
        ]
    }

    // 6. The wire carries the new dimension end to end: small gap closed and
    // overlapped, breath rest preserved.
    @Test("legatoOverlapBeats overlaps close joins over the wire and keeps the breath rest")
    func legatoOverTheWire() async throws {
        let (router, store) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: breathNotes())
        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.humanize",
            params: ["clipId": .string(clipID), "timingBeats": .number(0),
                     "velocityRange": .number(0), "seed": .number(1),
                     "legatoOverlapBeats": .number(0.05)]))
        #expect(resp.ok)
        let lengths = try #require(resp.result?["notes"]?.arrayValue)
            .compactMap { $0["lengthBeats"]?.doubleValue }
        #expect(lengths.count == 3)
        // 0.9 → 1.05 (gap 0.1 closed, then 0.05 of overlap).
        #expect(abs(lengths[0] - 1.05) < 1e-9)
        // The 0.5-beat gap at beat 2.0 is a BREATH: untouched.
        #expect(lengths[1] == 1.0)
        // Nothing follows the last note.
        #expect(lengths[2] == 1.0)
        // The store agrees with what went out on the wire.
        #expect(store.tracks[0].clips[0].notes!.map(\.lengthBeats) == lengths)
    }

    // 7. Omitting the params leaves lengths alone — the promise every existing
    // caller relies on, now conditional and therefore worth pinning.
    @Test("omitting the legato params leaves note lengths untouched")
    func legatoDefaultsOff() async throws {
        let (router, _) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: breathNotes())
        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.humanize",
            params: ["clipId": .string(clipID), "timingBeats": .number(0.05),
                     "velocityRange": .number(10), "seed": .number(7)]))
        #expect(resp.ok)
        let lengths = try #require(resp.result?["notes"]?.arrayValue)
            .compactMap { $0["lengthBeats"]?.doubleValue }
        #expect(lengths == [0.9, 1.0, 1.0])

        // …and `maxGapBeats` on its own is inert: it bounds a pass that is off.
        let inert = await router.handle(ControlRequest(
            id: "2", command: "clip.humanize",
            params: ["clipId": .string(clipID), "timingBeats": .number(0),
                     "velocityRange": .number(0), "maxGapBeats": .number(4)]))
        #expect(inert.ok)
        #expect(try #require(inert.result?["notes"]?.arrayValue)
            .compactMap { $0["lengthBeats"]?.doubleValue } == [0.9, 1.0, 1.0])
    }

    // 8. Field-named validation for both new params (the parseFadeCurve style).
    @Test("param validation: legatoOverlapBeats 0...0.25, maxGapBeats 0...4 — field-named")
    func legatoParamValidation() async throws {
        let (router, _) = makeRouter()
        let clipID = try await addMIDIClip(router, notes: breathNotes())
        func humanize(_ extra: [String: JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(id: "1", command: "clip.humanize",
                params: extra.merging(["clipId": .string(clipID)]) { a, _ in a }))
        }
        let badOverlap = await humanize(["legatoOverlapBeats": .number(0.5)])
        #expect(!badOverlap.ok)
        #expect(badOverlap.error?.contains("legatoOverlapBeats") == true)

        let badGap = await humanize(["maxGapBeats": .number(9)])
        #expect(!badGap.ok)
        #expect(badGap.error?.contains("maxGapBeats") == true)

        // A misspelling is REFUSED rather than silently ignored — the whole
        // point of rejectUnknownKeys, and the failure mode a new optional param
        // invites (a typo that quietly does nothing looks like a broken feature).
        let typo = await humanize(["legatoOverlap": .number(0.05)])
        #expect(!typo.ok)
        #expect(typo.error?.contains("legatoOverlap") == true)
    }
}
