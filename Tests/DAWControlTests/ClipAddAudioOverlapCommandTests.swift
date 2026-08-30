import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m33-j — the WIRE half of `clip.addAudio`'s overlap policy.
///
/// ⛔ THE DEFECT, reproduced through this exact router before the fix
/// (2026-08-29): `clip.addAudio {trackId, path, atBeat: 0}` twice on one audio
/// track returned `ok:true` with a fresh id BOTH times and left ONE clip — the
/// first id dead, nothing in the response saying so. A third add at beat 40 left
/// two, so the count was reading correctly and the deletion was specifically the
/// overlap path. Data loss reported as success.
///
/// The store-side policy and its rationale live in
/// `Tests/DAWCoreTests/AudioImportOverlapTests.swift`; this suite pins the wire
/// contract: the refusal reaches the caller VERBATIM, the additive `overwrite`
/// param is accepted, and the additive `trimmedClipIDs`/`removedClipIDs` receipt
/// is always present alongside the clip's own (unchanged, top-level) fields.
///
/// Reuses `FakeMedia` from ControlTests.swift (same target): 2.0 s @ 120 BPM = 4 beats.
@MainActor
@Suite("clip.addAudio overlap policy — control protocol")
struct ClipAddAudioOverlapCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore, String) {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        return (CommandRouter(store: store), store, track.id.uuidString)
    }

    private func add(_ router: CommandRouter, _ trackID: String, _ name: String,
                     atBeat: Double?, overwrite: Bool? = nil) async -> ControlResponse {
        var params: [String: JSONValue] = [
            "trackId": .string(trackID), "path": .string("/tmp/\(name).wav"),
        ]
        if let atBeat { params["atBeat"] = .number(atBeat) }
        if let overwrite { params["overwrite"] = .bool(overwrite) }
        return await router.handle(ControlRequest(id: name, command: "clip.addAudio", params: params))
    }

    @Test("REGRESSION: a second add at the same beat is REFUSED — the clip count never shrinks")
    func secondAddAtSameBeatIsRefused() async throws {
        let (router, store, trackID) = makeRouter()

        let first = await add(router, trackID, "print1", atBeat: 0)
        #expect(first.ok)
        let firstID = try #require(first.result?["id"]?.stringValue)
        #expect(store.tracks[0].clips.count == 1)

        let second = await add(router, trackID, "print2", atBeat: 0)
        #expect(second.ok == false)
        #expect(second.result == nil)

        // The three facts the defect broke.
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].id.uuidString == firstID)
        #expect(store.tracks[0].clips[0].name == "print1")

        // POSITIVE CONTROL — the same probe DOES see the count move when the
        // import lands clear, so "1" above is a measurement and not a stuck read.
        let third = await add(router, trackID, "print3", atBeat: 40)
        #expect(third.ok)
        #expect(store.tracks[0].clips.count == 2)
    }

    @Test("the refusal reaches the wire VERBATIM, naming the resident and the free beat")
    func refusalWordingIsContract() async throws {
        let (router, store, trackID) = makeRouter()
        _ = await add(router, trackID, "flip-pass", atBeat: 0)
        let residentID = store.tracks[0].clips[0].id.uuidString

        let refused = await add(router, trackID, "flip-pass", atBeat: 2)
        #expect(refused.ok == false)
        // Byte-exact: the wording is contract (control protocol + MCP surface it
        // verbatim), the ClipCrossTrackMoveCommandTests convention for
        // clipsWouldOverlapOnDestination — the refusal this one is modelled on.
        #expect(refused.error == """
            clip 'flip-pass' (\(residentID)) is already on that track where this import would land \
            — importing here would trim or delete it, so clip.addAudio refuses rather than silently \
            overwriting your clip (an import's length comes from the file, so 'atBeat' alone could \
            not tell you what it would cover). Omit 'atBeat' to append after everything already on \
            the track (beat 4), choose a free beat, import onto another track, or pass \
            'overwrite: true' to accept the trim and read back trimmedClipIDs/removedClipIDs
            """)
    }

    @Test("an ordinary add carries the additive receipt, both arrays empty, clip fields unmoved")
    func ordinaryAddCarriesEmptyReceipt() async throws {
        let (router, _, trackID) = makeRouter()
        let response = await add(router, trackID, "solo", atBeat: 8)
        #expect(response.ok)
        // The pre-m33-j top-level shape is untouched — every caller reading
        // `id`/`startBeat`/`lengthBeats` off this response still works.
        #expect(response.result?["id"]?.stringValue != nil)
        #expect(response.result?["name"]?.stringValue == "solo")
        #expect(response.result?["startBeat"]?.doubleValue == 8)
        #expect(response.result?["lengthBeats"]?.doubleValue == 4)
        // ALWAYS PRESENT, not omitted-when-empty: a caller told to check what
        // happened should not have to tell an absent key from an empty one.
        #expect(response.result?["trimmedClipIDs"]?.arrayValue?.isEmpty == true)
        #expect(response.result?["removedClipIDs"]?.arrayValue?.isEmpty == true)
    }

    @Test("overwrite:true accepts the destruction and NAMES what it destroyed")
    func overwriteReportsRemoval() async throws {
        let (router, store, trackID) = makeRouter()
        let first = await add(router, trackID, "old", atBeat: 0)
        let victimID = try #require(first.result?["id"]?.stringValue)

        let over = await add(router, trackID, "new", atBeat: 0, overwrite: true)
        #expect(over.ok)
        #expect(over.result?["removedClipIDs"]?.arrayValue?.compactMap(\.stringValue) == [victimID])
        #expect(over.result?["trimmedClipIDs"]?.arrayValue?.isEmpty == true)
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].name == "new")
    }

    @Test("overwrite:true on a partial overlap reports a TRIM, and the trim really happened")
    func overwriteReportsTrim() async throws {
        let (router, store, trackID) = makeRouter()
        let resident = await add(router, trackID, "resident", atBeat: 40)   // 40 → 44
        let residentID = try #require(resident.result?["id"]?.stringValue)

        let over = await add(router, trackID, "late", atBeat: 42, overwrite: true)
        #expect(over.ok)
        #expect(over.result?["trimmedClipIDs"]?.arrayValue?.compactMap(\.stringValue) == [residentID])
        #expect(over.result?["removedClipIDs"]?.arrayValue?.isEmpty == true)
        let trimmed = try #require(store.tracks[0].clips.first { $0.id.uuidString == residentID })
        #expect(trimmed.lengthBeats == 2)
    }

    @Test("overwrite:false is the same as omitting it")
    func explicitFalseMatchesDefault() async throws {
        let (router, store, trackID) = makeRouter()
        _ = await add(router, trackID, "a", atBeat: 0)
        let refused = await add(router, trackID, "b", atBeat: 0, overwrite: false)
        #expect(refused.ok == false)
        #expect(store.tracks[0].clips.count == 1)
    }

    @Test("omitting atBeat still appends and can never be refused")
    func appendEscapeStillWorks() async throws {
        let (router, store, trackID) = makeRouter()
        for i in 0..<3 { _ = await add(router, trackID, "pass\(i)", atBeat: nil) }
        #expect(store.tracks[0].clips.count == 3)
        #expect(store.tracks[0].clips.map(\.startBeat) == [0, 4, 8])
    }

    @Test("a typo'd key is still rejected — 'overwrite' widened the allow-list by exactly one")
    func unknownKeysStillRejected() async throws {
        let (router, _, trackID) = makeRouter()
        let typo = await router.handle(ControlRequest(
            id: "1", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/x.wav"),
                     "overwite": .bool(true)]))
        #expect(typo.ok == false)
        #expect(typo.error?.contains("overwite") == true)
    }
}
