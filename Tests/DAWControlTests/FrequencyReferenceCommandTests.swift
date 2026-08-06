import Foundation
import Testing
import DAWCore
@testable import DAWControl
@testable import DAWEngine

/// Control-protocol gate for m23-o1 Step 3's `frequency.reference`
/// (design-m23o1-instrument-frequency-reference.md §6/§8.3) — the wire
/// verb that puts the cited instrument frequency reference (Steps 1/2/2b,
/// `InstrumentFrequencyReference.swift` + `InstrumentFamilyResolution.swift`)
/// on the control protocol. These legs cover the WIRE PLUMBING only —
/// `family`/`trackId`/`note` parsing, the resolution ladder's dispatch, the
/// response shape's omitted-when-inapplicable fields, and the additive
/// registration surfaces. Row *content* (fundamentals, bands, citations) is
/// already pinned in `Tests/DAWCoreTests/InstrumentFrequencyReferenceTests`
/// (C1–C11) and the ladder itself in `InstrumentFamilyResolutionTests`
/// (R1–R7) — re-asserting specific Hz/citation values here would be a second,
/// driftable copy of content this file does not own.
///
/// C12 (the `MasterMixAnalyzer.bandIndex(containing:)` pin-pair the staging
/// gate's `PROBE_BAND`/`CONTROL_BAND` constants depend on) lives at the
/// bottom of this file, in its own `@Suite` — it needs `DAWEngine`, which
/// `Tests/DAWCoreTests` does not depend on but `DAWControlTests` does
/// (`Package.swift:129`), per design §8.3's explicit placement note.
@MainActor
@Suite("frequency.reference — control protocol (m23-o1 Step 3)")
struct FrequencyReferenceCommandTests {
    // MARK: - Setup

    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func freqRequest(_ id: String, family: String? = nil,
                             trackId: String? = nil, note: Int? = nil) -> ControlRequest {
        var params: [String: JSONValue] = [:]
        if let family { params["family"] = .string(family) }
        if let trackId { params["trackId"] = .string(trackId) }
        if let note { params["note"] = .number(Double(note)) }
        return ControlRequest(id: id, command: "frequency.reference", params: params)
    }

    /// An instrument track whose sound bank addresses GM program `program`
    /// (melodic bank, 121 — the model's own default).
    private func addMelodicTrack(_ router: CommandRouter, program: Int) async throws -> String {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let setInst = await router.handle(ControlRequest(
            id: "i", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "soundBank": .object(["source": .string("gm"),
                                           "program": .number(Double(program))])]))
        #expect(setInst.ok, "melodic track setup failed: \(setInst.error ?? "?")")
        return trackID
    }

    /// An instrument track whose sound bank addresses the GM percussion kit
    /// (bank 120).
    private func addPercussionTrack(_ router: CommandRouter) async throws -> String {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let setInst = await router.handle(ControlRequest(
            id: "i", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "soundBank": .object(["source": .string("gm"), "program": .number(0),
                                           "bankMSB": .number(120)])]))
        #expect(setInst.ok, "percussion track setup failed: \(setInst.error ?? "?")")
        return trackID
    }

    // MARK: - W1: zero params — the vocabulary lesson

    @Test("W1: zero params -> resolution:index, families present (13 entries), no reference/resolvedFrom/reason")
    func zeroParamsReturnsIndex() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(freqRequest("1"))
        #expect(response.ok, "frequency.reference with no params must be legal: \(response.error ?? "?")")
        #expect(response.result?["resolution"]?.stringValue == "index")
        #expect(response.result?["reference"] == nil)
        #expect(response.result?["resolvedFrom"] == nil)
        #expect(response.result?["reason"] == nil)
        let families = try #require(response.result?["families"]?.arrayValue)
        #expect(families.count == InstrumentFamily.allCases.count)
        // MUTATION: return .unresolved(...) instead of nil for the zero-param
        // case in the handler -> "resolution" reddens to "unresolved" and a
        // "reason"/"explanation"/"remedy" trio appears where none should.
    }

    @Test("frequency.reference is legal with NO PARAMS and is therefore absent from ZeroParamVerbRejectionTests.zeroParamVerbs (a non-empty allow-list, not the empty-bracket table)")
    func notInTheEmptyBracketTable() {
        #expect(!ZeroParamVerbRejectionTests.zeroParamVerbs.contains("frequency.reference"),
                "frequency.reference has a non-empty rejectUnknownKeys allow-list — it must never join the empty-bracket scrape table")
    }

    // MARK: - W2: family override

    @Test("W2: family -> resolution:family, resolvedFrom:argument, reference.family echoes the request")
    func familyOverrideResolves() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(freqRequest("1", family: "electricBass"))
        #expect(response.ok)
        #expect(response.result?["resolution"]?.stringValue == "family")
        #expect(response.result?["resolvedFrom"]?.stringValue == "argument")
        #expect(response.result?["reference"]?["family"]?.stringValue == "electricBass")
        #expect(response.result?["reason"] == nil)
        // MUTATION: hardcode resolvedFrom to "gmProgram" in the .resolved(_,
        // .argument) branch -> reddens.
    }

    // MARK: - W3: family + trackId together — family wins

    @Test("W3: family + trackId together -> family wins (the TRACK'S own resolution would differ), resolvedFrom:argument")
    func familyWinsOverTrackId() async throws {
        let (router, _) = makeRouter()
        // program 33 -> electricBass (InstrumentFamilyResolutionTests R3's own
        // pin) — a track that would resolve to a DIFFERENT family than the
        // one passed via `family`, so a precedence bug is observable.
        let trackID = try await addMelodicTrack(router, program: 33)
        let response = await router.handle(freqRequest("1", family: "kick", trackId: trackID))
        #expect(response.ok)
        #expect(response.result?["resolution"]?.stringValue == "family")
        #expect(response.result?["resolvedFrom"]?.stringValue == "argument")
        #expect(response.result?["reference"]?["family"]?.stringValue == "kick",
                "the TRACK resolves to electricBass — a leak here means trackId silently won")
        // MUTATION: swap precedence (check trackId before family) -> the
        // reference.family reddens to "electricBass".
    }

    // MARK: - W4: family + note together — rejected

    @Test("W4: family + note together is rejected — two keys that could disagree")
    func familyAndNoteTogetherRejected() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(freqRequest("1", family: "snare", note: 38))
        #expect(!response.ok)
        #expect(response.error?.contains("family") == true)
        #expect(response.error?.contains("note") == true)
        // MUTATION: delete the `freqFamilyRaw != nil, freqNote != nil` guard
        // -> reddens (the call would instead succeed via the family branch).
    }

    // MARK: - W5: unknown family value — a named error, never a nil-ish success

    @Test("W5: unknown family value -> named error listing every valid id, never a nil-ish success")
    func unknownFamilyValueErrors() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(freqRequest("1", family: "bass"))
        #expect(!response.ok, "a typo must not read as a success")
        #expect(response.error?.contains("unknown 'family' value 'bass'") == true)
        #expect(response.error == "unknown 'family' value 'bass' — valid ids are "
                + "acousticGuitar, crashCymbal, electricBass, electricGuitar, femaleVocal, "
                + "hiHat, kick, maleVocal, piano, rideCymbal, snare, tom, uprightBass")
        // MUTATION: return the zero-param index instead of throwing on an
        // unresolved InstrumentFamily(rawValue:) -> reddens (response.ok
        // flips true, and "bass" silently reads as "no family given").
    }

    // MARK: - W6: trackId + covered percussion note

    @Test("W6: percussion track + covered note (38) -> resolvedFrom:gmPercussionNote, family:snare")
    func percussionNoteResolves() async throws {
        let (router, _) = makeRouter()
        let trackID = try await addPercussionTrack(router)
        let response = await router.handle(freqRequest("1", trackId: trackID, note: 38))
        #expect(response.ok)
        #expect(response.result?["resolution"]?.stringValue == "family")
        #expect(response.result?["resolvedFrom"]?.stringValue == "gmPercussionNote")
        #expect(response.result?["reference"]?["family"]?.stringValue == "snare")
        #expect(response.result?["noteIgnored"] == nil,
                "a percussion-bank track's note must never be reported as ignored")
    }

    // MARK: - W6b: trackId of a MELODIC track + note -> noteIgnored, never silent

    @Test("W6b: melodic track + note -> resolves by PROGRAM, resolvedFrom:gmProgram, noteIgnored:true, and explanation names why")
    func noteIgnoredOnAMelodicTrack() async throws {
        let (router, _) = makeRouter()
        let trackID = try await addMelodicTrack(router, program: 33)   // -> electricBass
        let response = await router.handle(freqRequest("1", trackId: trackID, note: 38))
        #expect(response.ok)
        #expect(response.result?["resolvedFrom"]?.stringValue == "gmProgram")
        #expect(response.result?["reference"]?["family"]?.stringValue == "electricBass")
        #expect(response.result?["noteIgnored"]?.boolValue == true,
                "MUTATION target 1: drop the noteIgnored flag from the .resolved+.gmProgram branch")
        let explanation = try #require(response.result?["explanation"]?.stringValue,
                                       "MUTATION target 2: drop the explanation assignment from the same branch")
        #expect(explanation.contains("note") || explanation.lowercased().contains("ignored"),
                "the explanation must actually name the ignored 'note' param, not just exist")
    }

    // MARK: - W6c: percussion track, no note -> drumKit + the covered notes

    @Test("W6c: percussion track, no note -> resolution:drumKit, 17 coveredNotes each carrying {note,name,family}")
    func percussionTrackWithNoNoteIsDrumKit() async throws {
        let (router, _) = makeRouter()
        let trackID = try await addPercussionTrack(router)
        let response = await router.handle(freqRequest("1", trackId: trackID))
        #expect(response.ok)
        #expect(response.result?["resolution"]?.stringValue == "drumKit")
        let notes = try #require(response.result?["coveredNotes"]?.arrayValue)
        #expect(notes.count == 17)
        for entry in notes {
            #expect(entry["note"]?.doubleValue != nil, "MUTATION: emit bare ints -> this reddens (no 'note' key on a number)")
            #expect(entry["name"]?.stringValue != nil)
            #expect(entry["family"]?.stringValue != nil)
        }
    }

    // MARK: - W6d: percussion track, uncovered note -> unresolved, coveredNotes STILL present

    @Test("W6d: percussion track + uncovered note (54) -> unresolved(percussionNoteNotCoveredInV1), coveredNotes still present")
    func uncoveredPercussionNoteKeepsCoveredNotes() async throws {
        let (router, _) = makeRouter()
        let trackID = try await addPercussionTrack(router)
        let response = await router.handle(freqRequest("1", trackId: trackID, note: 54))
        #expect(response.ok, "an uncovered note is an honest UNRESOLVED payload, not a wire failure: \(response.error ?? "?")")
        #expect(response.result?["resolution"]?.stringValue == "unresolved")
        #expect(response.result?["reason"]?.stringValue == "percussionNoteNotCoveredInV1")
        let notes = try #require(response.result?["coveredNotes"]?.arrayValue,
                                 "MUTATION: drop the coveredNotes line from the percussionNoteNotCoveredInV1 arm -> this reddens")
        #expect(notes.count == 17)
    }

    // MARK: - W7: an audio track — the honest failure, live, with the byte-identical index

    @Test("W7: an audio track -> unresolved, non-empty reason/explanation/remedy, families BYTE-IDENTICAL to the zero-param index")
    func audioTrackIsUnresolvedWithTheFullIndex() async throws {
        let (router, store) = makeRouter()
        let index = await router.handle(freqRequest("index"))
        let indexFamilies = try #require(index.result?["families"])

        let track = store.addTrack(name: "Vox", kind: .audio)
        let response = await router.handle(freqRequest("1", trackId: track.id.uuidString))
        #expect(response.ok)
        #expect(response.result?["resolution"]?.stringValue == "unresolved")
        #expect(response.result?["reason"]?.stringValue == "audioTrackHasNoInstrument")
        #expect(response.result?["explanation"]?.stringValue?.isEmpty == false)
        #expect(response.result?["remedy"]?.stringValue?.isEmpty == false)
        #expect(response.result?["families"] == indexFamilies,
                "MUTATION: omit families from the .unresolved branch -> this reddens (never a hardcoded count — a future row delete must not desync it)")
    }

    // MARK: - W-bus: a bus has no instrument identity

    @Test("a bus track -> unresolved(trackIsNotAnInstrumentOrAudioTrack)")
    func busTrackIsUnresolved() async throws {
        let (router, store) = makeRouter()
        let bus = store.addTrack(name: "Drum Bus", kind: .bus)
        let response = await router.handle(freqRequest("1", trackId: bus.id.uuidString))
        #expect(response.ok)
        #expect(response.result?["resolution"]?.stringValue == "unresolved")
        #expect(response.result?["reason"]?.stringValue == "trackIsNotAnInstrumentOrAudioTrack")
    }

    // MARK: - W-master / W-invalid-uuid: NO "master" sentinel

    @Test("trackId:\"master\" is NOT a sentinel — it is an invalid UUID, exactly like any other malformed trackId")
    func masterIsNotASentinel() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(freqRequest("1", trackId: "master"))
        #expect(!response.ok)
        #expect(response.error == "'trackId' is not a valid UUID: master")
        // MUTATION: add a parseFXTarget()-style "master" special case ahead of
        // the UUID parse -> this reddens (response.ok flips true).
    }

    @Test("an unresolvable (but valid-UUID) trackId -> a named noTrack error, never a silent index/false-resolved")
    func unknownTrackIdErrors() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(freqRequest("1", trackId: UUID().uuidString))
        #expect(!response.ok)
        #expect(response.error?.contains("no track with id") == true)
    }

    // MARK: - W-note-bounds

    @Test("note outside 0...127 is rejected before the ladder ever runs")
    func noteOutOfBoundsRejected() async throws {
        let (router, _) = makeRouter()
        for bad in [-1, 128] {
            let response = await router.handle(freqRequest("1", note: bad))
            #expect(!response.ok, "note \(bad) must be rejected")
            #expect(response.error?.contains("0") == true)
        }
    }

    // MARK: - W-family-wrong-type: a mistyped `family` must error, never silently fall through

    @Test("family passed as a NUMBER (not a string) errors — the wrong-typed value must never silently read as absent")
    func familyWrongTypeErrors() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "frequency.reference", params: ["family": .number(42)]))
        #expect(!response.ok)
        #expect(response.error == "'family' must be a string")
        // MUTATION: replace Self.optionalString(params["family"], ...) with
        // params["family"]?.stringValue (silently nil for a non-string) ->
        // this reddens — the call would instead succeed as if family were
        // never passed, which is exactly the bug optionalString exists to
        // prevent.
    }

    // MARK: - W8 (partial): unknown param key rejected, naming key + verb

    @Test("an unknown param key is rejected, naming the key and the verb")
    func unknownParamKeyRejected() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "frequency.reference", params: ["bogus": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'bogus'") == true)
        #expect(response.error?.contains("frequency.reference") == true)
    }

    // MARK: - W8: additive-at-END registration

    @Test("W8: frequency.reference was registered at the END of allCommands at m23-o1 (additive-at-end law); m23-w appended clip.removeMany/clip.moveMany, m23-af appended transport.panic, and m23-aj-2 appended clip.moveManyByTracks/clip.moveManyToTrack after it, so it is now sixth-from-last; count 162 -> 163 -> 165 -> 166 -> 171")
    func registeredAtEndOfAllCommands() {
        // m23-dl appended ai.modelResidency/ai.modelUnload after it too, so it
        // is now eighth-from-last.
        #expect(CommandRouter.allCommands.dropLast(7).last == "frequency.reference")
        #expect(CommandRouter.allCommands.count == 173)   // 166 at m23-af -> 168 at m20-j -> 169 at m23-br-1 -> 171 at m23-aj-2 -> 173 at m23-dl
    }

    // MARK: - W9: the catalog's family enum is computed on BOTH sides, never a hand list

    @Test("W9: the copilot catalog's family enum equals InstrumentFamily.allCases.map(\\.rawValue), IN ORDER — the leg that matters most for the copilot")
    func catalogFamilyEnumMatchesTheLiveEnum() throws {
        let tool = try #require(CopilotToolCatalog.tool(command: "frequency.reference"))
        guard case .object(let schema) = tool.schema,
              case .object(let properties)? = schema["properties"],
              case .object(let familySchema)? = properties["family"],
              case .array(let enumValues)? = familySchema["enum"] else {
            Issue.record("frequency.reference's catalog schema has no family.enum array")
            return
        }
        let catalogFamilies = enumValues.compactMap(\.stringValue)
        let liveFamilies = InstrumentFamily.allCases.map(\.rawValue)
        #expect(catalogFamilies == liveFamilies,
                Comment(rawValue: "MUTATION: hardcode the catalog's enumValues to 12 of the 13 families "
                    + "-> this reddens. A future 14th family that ships without touching the catalog "
                    + "reddens it too."))
    }

    // MARK: - families index: `notes` present ONLY for percussion (note-keyed) families

    @Test("families index: notes is present for percussion-keyed families (kick) and ABSENT for non-percussion ones (electricBass) — the nil-means-no-evidence convention, pinned explicitly")
    func notesOmittedForNonPercussionFamilies() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(freqRequest("1"))
        let families = try #require(response.result?["families"]?.arrayValue)
        let kick = try #require(families.first { $0["family"]?.stringValue == "kick" })
        let bass = try #require(families.first { $0["family"]?.stringValue == "electricBass" })
        #expect(kick["notes"] != nil, "kick is note-keyed — its families-index entry must carry notes")
        #expect(bass["notes"] == nil, "electricBass is not note-keyed — carrying an empty/nonempty notes array here is unspecified content this leg pins as ABSENT")
    }
}

/// C12 (design §8.3): the pin-pair the staging gate's hardcoded
/// `PROBE_BAND`/`CONTROL_BAND` constants depend on. Lives here (not
/// `DAWCoreTests`) because `MasterMixAnalyzer` is `Sources/DAWEngine`, and
/// only `DAWControlTests` carries that test-only dependency
/// (`Package.swift:129`).
@Suite("MasterMixAnalyzer band index — C12 (m23-o1 staging-gate pin-pair)")
struct FrequencyReferenceBandIndexTests {
    @Test("C12: bandIndex(containing:) for the gate's three probe frequencies, and bandEdges[0] == 40")
    func bandIndexPinPair() {
        #expect(MasterMixAnalyzer.bandIndex(containing: 41.203) == 0,
                "the electricBass fundamental's lowest note (E1, 41.203 Hz) must land in band 0")
        #expect(MasterMixAnalyzer.bandIndex(containing: 329.63) == 8,
                "the gate's control note (E4, 329.63 Hz) must land in band 8")
        #expect(MasterMixAnalyzer.bandIndex(containing: 200) == 6)
        #expect(MasterMixAnalyzer.bandEdges[0] == 40)
        // MUTATION: change `lowestBandHz` from 40.0 to any other value ->
        // every assertion above reddens together, and it is exactly what
        // would silently desync the staging gate's PROBE_BAND/CONTROL_BAND
        // literals from the real analyzer.
    }
}
