import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for `clip.getNotes` — the read-only counterpart to
/// `clip.setNotes` (see the command's own doc comment in Commands.swift for the
/// motivating failure: `project.snapshot` is ~290 KB on a modest session and
/// overflows an agent's tool-output budget, and there was previously NO way to
/// read a clip's notes back without either that or a mutating trick).
///
/// Covers: exact id/field round trip through the wire, the whole-array
/// `clip.setNotes` round trip, the beat-range HALF-OPEN boundary, the
/// pitch-range INCLUSIVE boundary, both filters combined, `totalNotes` vs
/// `returnedNotes`, the READ-ONLY pin (the entire point of this verb), every
/// refusal, and wire registration. Reuses `FakeMedia` from ControlTests.swift
/// (same target).
@MainActor
@Suite("clip.getNotes — control protocol")
struct ClipGetNotesCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// Adds an instrument track + one MIDI clip carrying `notes`, returning
    /// both ids as wire strings.
    private func addMIDIClip(
        _ router: CommandRouter, notes: [JSONValue], lengthBeats: Double = 8
    ) async throws -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(lengthBeats),
                     "notes": .array(notes)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    private func addAudioClip(_ router: CommandRouter) async throws
        -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "a", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav")]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    private func noteJSON(id: UUID, pitch: Int, velocity: Int, startBeat: Double, lengthBeats: Double) -> JSONValue {
        .object([
            "id": .string(id.uuidString),
            "pitch": .number(Double(pitch)),
            "velocity": .number(Double(velocity)),
            "startBeat": .number(startBeat),
            "lengthBeats": .number(lengthBeats),
        ])
    }

    // Six notes, DELIBERATELY authored out of canonical order, spanning both a
    // beat-range boundary (1.0...2.0) and a pitch-range boundary (60...64):
    //   idLow    pitch 55  startBeat 0.0   — outside both ranges
    //   idFrom   pitch 60  startBeat 1.0   — fromBeat boundary: INCLUDED
    //   idMid    pitch 62  startBeat 1.5   — inside both ranges
    //   idOut6   pitch 80  startBeat 1.2   — inside the beat range, OUTSIDE pitch range
    //   idTo     pitch 64  startBeat 2.0   — toBeat boundary: EXCLUDED
    //   idHigh   pitch 70  startBeat 3.0   — outside both ranges
    private let idLow = UUID(), idFrom = UUID(), idMid = UUID(), idOut6 = UUID(), idTo = UUID(), idHigh = UUID()

    private func sixNotes() -> [JSONValue] {
        [
            noteJSON(id: idHigh, pitch: 70, velocity: 110, startBeat: 3.0, lengthBeats: 1.0),
            noteJSON(id: idLow, pitch: 55, velocity: 90, startBeat: 0.0, lengthBeats: 1.0),
            noteJSON(id: idTo, pitch: 64, velocity: 105, startBeat: 2.0, lengthBeats: 0.5),
            noteJSON(id: idMid, pitch: 62, velocity: 100, startBeat: 1.5, lengthBeats: 0.5),
            noteJSON(id: idOut6, pitch: 80, velocity: 120, startBeat: 1.2, lengthBeats: 0.3),
            noteJSON(id: idFrom, pitch: 60, velocity: 95, startBeat: 1.0, lengthBeats: 0.5),
        ]
    }

    // 1.
    @Test("returns every note with the same ids, ordered by startBeat then pitch")
    func returnsAllNotesOrdered() async throws {
        let (router, _) = makeRouter()
        let (_, clipID) = try await addMIDIClip(router, notes: sixNotes())

        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.getNotes", params: ["clipId": .string(clipID)]))
        #expect(resp.ok, "clip.getNotes failed: \(resp.error ?? "?")")
        let notes = try #require(resp.result?["notes"]?.arrayValue)
        #expect(notes.count == 6)
        let gotIDs = notes.map { $0["id"]?.stringValue }
        // Canonical order: startBeat ascending, then pitch ascending.
        // (0.0, 1.0, 1.2, 1.5, 2.0, 3.0) — idOut6 (1.2) sorts BEFORE idMid (1.5).
        #expect(gotIDs == [idLow, idFrom, idOut6, idMid, idTo, idHigh].map { $0.uuidString })
        // Every field survives verbatim on the boundary note.
        let fromNote = try #require(notes.first { $0["id"]?.stringValue == idFrom.uuidString })
        #expect(fromNote["pitch"]?.doubleValue == 60)
        #expect(fromNote["velocity"]?.doubleValue == 95)
        #expect(fromNote["startBeat"]?.doubleValue == 1.0)
        #expect(fromNote["lengthBeats"]?.doubleValue == 0.5)
    }

    // 2.
    @Test("round trip: getNotes -> feed the exact array back to setNotes -> the clip is unchanged")
    func roundTripThroughSetNotes() async throws {
        let (router, store) = makeRouter()
        let (_, clipID) = try await addMIDIClip(router, notes: sixNotes())

        let getResp = await router.handle(ControlRequest(
            id: "1", command: "clip.getNotes", params: ["clipId": .string(clipID)]))
        #expect(getResp.ok)
        let gotNotes = try #require(getResp.result?["notes"])

        let setResp = await router.handle(ControlRequest(
            id: "2", command: "clip.setNotes",
            params: ["clipId": .string(clipID), "notes": gotNotes]))
        #expect(setResp.ok, "round-trip clip.setNotes failed: \(setResp.error ?? "?")")

        let storedNotes = try #require(store.tracks.first?.clips.first?.notes)
        #expect(storedNotes.count == 6)
        let storedByID = Dictionary(uniqueKeysWithValues: storedNotes.map { ($0.id, $0) })
        for expected in [
            (idLow, 55, 90, 0.0, 1.0), (idFrom, 60, 95, 1.0, 0.5), (idMid, 62, 100, 1.5, 0.5),
            (idOut6, 80, 120, 1.2, 0.3), (idTo, 64, 105, 2.0, 0.5), (idHigh, 70, 110, 3.0, 1.0),
        ] {
            let note = try #require(storedByID[expected.0], "note \(expected.0) missing after round trip")
            #expect(note.pitch == expected.1)
            #expect(note.velocity == expected.2)
            #expect(note.startBeat == expected.3)
            #expect(note.lengthBeats == expected.4)
        }
    }

    // 3.
    @Test("beat range narrows correctly and is HALF-OPEN: a note at toBeat is excluded, one at fromBeat is included")
    func beatRangeHalfOpen() async throws {
        let (router, _) = makeRouter()
        let (_, clipID) = try await addMIDIClip(router, notes: sixNotes())

        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.getNotes",
            params: ["clipId": .string(clipID), "fromBeat": .number(1.0), "toBeat": .number(2.0)]))
        #expect(resp.ok)
        let notes = try #require(resp.result?["notes"]?.arrayValue)
        let gotIDs = Set(notes.compactMap { $0["id"]?.stringValue })
        // idFrom (startBeat 1.0) is >= fromBeat -> INCLUDED.
        #expect(gotIDs.contains(idFrom.uuidString))
        // idMid (1.5) and idOut6 (1.2) sit strictly inside -> INCLUDED.
        #expect(gotIDs.contains(idMid.uuidString))
        #expect(gotIDs.contains(idOut6.uuidString))
        // idTo (startBeat 2.0) is NOT < toBeat -> EXCLUDED (the half-open boundary).
        #expect(!gotIDs.contains(idTo.uuidString))
        // idLow (0.0) and idHigh (3.0) sit outside the range entirely -> EXCLUDED.
        #expect(!gotIDs.contains(idLow.uuidString))
        #expect(!gotIDs.contains(idHigh.uuidString))
        #expect(notes.count == 3)
        #expect(resp.result?["totalNotes"]?.doubleValue == 6)
        #expect(resp.result?["returnedNotes"]?.doubleValue == 3)
    }

    // 4.
    @Test("pitch range narrows correctly and is INCLUSIVE on both ends")
    func pitchRangeInclusive() async throws {
        let (router, _) = makeRouter()
        let (_, clipID) = try await addMIDIClip(router, notes: sixNotes())

        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.getNotes",
            params: ["clipId": .string(clipID), "pitchMin": .number(60), "pitchMax": .number(64)]))
        #expect(resp.ok)
        let notes = try #require(resp.result?["notes"]?.arrayValue)
        let gotIDs = Set(notes.compactMap { $0["id"]?.stringValue })
        // idFrom (pitch 60) == pitchMin -> INCLUDED.
        #expect(gotIDs.contains(idFrom.uuidString))
        // idTo (pitch 64) == pitchMax -> INCLUDED.
        #expect(gotIDs.contains(idTo.uuidString))
        // idMid (62) sits strictly inside -> INCLUDED.
        #expect(gotIDs.contains(idMid.uuidString))
        // idLow (55), idOut6 (80), idHigh (70) sit outside -> EXCLUDED.
        #expect(!gotIDs.contains(idLow.uuidString))
        #expect(!gotIDs.contains(idOut6.uuidString))
        #expect(!gotIDs.contains(idHigh.uuidString))
        #expect(notes.count == 3)
        #expect(resp.result?["totalNotes"]?.doubleValue == 6)
        #expect(resp.result?["returnedNotes"]?.doubleValue == 3)
    }

    // 5.
    @Test("beat range and pitch range combined narrow MORE than either alone")
    func combinedFilters() async throws {
        let (router, _) = makeRouter()
        let (_, clipID) = try await addMIDIClip(router, notes: sixNotes())

        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.getNotes",
            params: ["clipId": .string(clipID),
                     "fromBeat": .number(1.0), "toBeat": .number(2.0),
                     "pitchMin": .number(60), "pitchMax": .number(64)]))
        #expect(resp.ok)
        let notes = try #require(resp.result?["notes"]?.arrayValue)
        let gotIDs = Set(notes.compactMap { $0["id"]?.stringValue })
        // idFrom (60, 1.0) and idMid (62, 1.5) satisfy BOTH filters.
        #expect(gotIDs == [idFrom.uuidString, idMid.uuidString])
        // idOut6 (1.2) is in the beat range but pitch 80 is out of range —
        // the beat-only test above included it; the combined filter must not.
        #expect(!gotIDs.contains(idOut6.uuidString))
        // idTo (64, 2.0) is in the pitch range but excluded by the half-open
        // beat boundary — the pitch-only test above included it; combined
        // must not.
        #expect(!gotIDs.contains(idTo.uuidString))
        #expect(resp.result?["totalNotes"]?.doubleValue == 6)
        #expect(resp.result?["returnedNotes"]?.doubleValue == 2)
    }

    // 6.
    @Test("totalNotes stays the UNFILTERED count while returnedNotes follows the filter")
    func totalVsReturned() async throws {
        let (router, _) = makeRouter()
        let (_, clipID) = try await addMIDIClip(router, notes: sixNotes())

        let unfiltered = await router.handle(ControlRequest(
            id: "1", command: "clip.getNotes", params: ["clipId": .string(clipID)]))
        #expect(unfiltered.result?["totalNotes"]?.doubleValue == 6)
        #expect(unfiltered.result?["returnedNotes"]?.doubleValue == 6)

        let filtered = await router.handle(ControlRequest(
            id: "2", command: "clip.getNotes",
            params: ["clipId": .string(clipID), "pitchMin": .number(90)]))
        #expect(filtered.ok)
        #expect(filtered.result?["totalNotes"]?.doubleValue == 6, "totalNotes must stay unfiltered")
        #expect(filtered.result?["returnedNotes"]?.doubleValue == 0)
        #expect(filtered.result?["notes"]?.arrayValue?.isEmpty == true)
    }

    // 7.
    @Test("READ-ONLY: no undo entry, no dirty-state change, no new undo step — unlike clip.humanize, which mutates and DOES push one")
    func readOnlyPin() async throws {
        let (router, store) = makeRouter()
        let (_, clipID) = try await addMIDIClip(router, notes: sixNotes())

        let undoLabelBefore = store.undoLabel
        let isDirtyBefore = store.isDirty
        let historyBefore = store.undoHistory().undo

        let resp = await router.handle(ControlRequest(
            id: "1", command: "clip.getNotes", params: ["clipId": .string(clipID)]))
        #expect(resp.ok)

        #expect(store.undoLabel == undoLabelBefore)
        #expect(store.isDirty == isDirtyBefore)
        #expect(store.undoHistory().undo == historyBefore, "clip.getNotes must not push an undo step")

        // Contrast: clip.humanize is the MUTATING "echo the clip back" trick
        // clip.getNotes replaces. ⚠️ MEASURED, correcting the brief's own
        // motivating description: `ProjectStore.performEdit` only records a
        // journal (undo) entry `if captureEditState() != before` — so
        // clip.humanize at EXACTLY {timingBeats:0, velocityRange:0} draws no
        // jitter on either axis (`if timingBeats > 0` / `if velocityRange > 0`
        // both false), the note array comes back byte-identical, and NO new
        // undo step is recorded (verified: this exact call, at 0/0, leaves
        // store.undoLabel unchanged — the opposite of what "pushes an undo
        // entry" would predict). What zero-jitter humanize DOES still do,
        // unconditionally, inside the very same performEdit call: run
        // `engine?.tracksDidChange(tracks)` and call `markDirty()` — real,
        // wasted work clip.getNotes performs none of. To demonstrate the
        // undo-stack half of the contrast honestly, this uses a small but
        // NON-zero, fixed-seed jitter, which reliably changes at least one of
        // six notes and so reliably pushes a fresh "Humanize" undo step.
        let humanizeResp = await router.handle(ControlRequest(
            id: "2", command: "clip.humanize",
            params: ["clipId": .string(clipID), "timingBeats": .number(0.05),
                     "velocityRange": .number(10), "seed": .number(12345)]))
        #expect(humanizeResp.ok)
        #expect(store.undoLabel == "Humanize", "sanity: clip.humanize DOES push a new undo step (unlike clip.getNotes)")
        #expect(store.undoLabel != undoLabelBefore)
    }

    // 8.
    @Test("refusals: unknown clip id, audio clip, fromBeat > toBeat, pitchMin > pitchMax, unknown key")
    func refusals() async throws {
        let (router, _) = makeRouter()
        let (_, midiClipID) = try await addMIDIClip(router, notes: sixNotes())
        let (_, audioClipID) = try await addAudioClip(router)

        let unknownClip = await router.handle(ControlRequest(
            id: "1", command: "clip.getNotes", params: ["clipId": .string(UUID().uuidString)]))
        #expect(!unknownClip.ok)
        #expect(unknownClip.error?.contains("no clip with id") == true)

        let onAudio = await router.handle(ControlRequest(
            id: "2", command: "clip.getNotes", params: ["clipId": .string(audioClipID)]))
        #expect(!onAudio.ok)
        // Exact wording is contract (the ControlTests.swift clip.setNotes precedent):
        // `verb:` in the ProjectError.notAMIDIClip case is what lets this message
        // correctly blame "clip.getNotes" rather than "clip.setNotes" — a `contains`
        // check alone would stay green even if a future edit dropped that argument
        // and the message silently blamed the wrong verb.
        #expect(onAudio.error ==
            "clip \(audioClipID) is an audio clip — clip.getNotes applies only to MIDI clips (created via clip.addMIDI)")

        let badBeatRange = await router.handle(ControlRequest(
            id: "3", command: "clip.getNotes",
            params: ["clipId": .string(midiClipID), "fromBeat": .number(5), "toBeat": .number(2)]))
        #expect(!badBeatRange.ok)
        #expect(badBeatRange.error?.contains("fromBeat") == true)

        let badPitchRange = await router.handle(ControlRequest(
            id: "4", command: "clip.getNotes",
            params: ["clipId": .string(midiClipID), "pitchMin": .number(80), "pitchMax": .number(40)]))
        #expect(!badPitchRange.ok)
        #expect(badPitchRange.error?.contains("pitchMin") == true)

        let unknownKey = await router.handle(ControlRequest(
            id: "5", command: "clip.getNotes",
            params: ["clipId": .string(midiClipID), "bogus": .bool(true)]))
        #expect(!unknownKey.ok)
        #expect(unknownKey.error?.contains("bogus") == true)

        // A WRONG-TYPED filter must REFUSE, never be silently dropped. This is
        // the worst failure available to this verb: a dropped filter returns
        // the whole clip while `returnedNotes` reads as "what matched my
        // range", and the caller then whole-array-replaces from a window it
        // never actually asked for. Both bounds, both types.
        for (field, value) in [("fromBeat", JSONValue.string("2")),
                               ("toBeat", JSONValue.bool(true)),
                               ("pitchMin", JSONValue.string("60")),
                               ("pitchMax", JSONValue.string("72"))] {
            let mistyped = await router.handle(ControlRequest(
                id: "6", command: "clip.getNotes",
                params: ["clipId": .string(midiClipID), field: value]))
            #expect(!mistyped.ok, "'\(field)' with a non-number must be refused, not ignored")
            #expect(mistyped.error?.contains(field) == true,
                    "the refusal for '\(field)' must name the field")
        }
    }

    // 9.
    @Test("clip.getNotes is registered exactly once in allCommands")
    func wirePin() {
        #expect(CommandRouter.allCommands.contains("clip.getNotes"))
        #expect(CommandRouter.allCommands.filter { $0 == "clip.getNotes" }.count == 1)
    }
}
