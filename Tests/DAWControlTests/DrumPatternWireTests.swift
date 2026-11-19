import DAWCore
import Foundation
import Testing
@testable import DAWControl

// m39-w4-10 — the wire half: `pattern.list` and `clip.addDrumPattern`.
// Design `docs/design/2026-10-07-loop-drum-depth.md` §8, §9.2. The MCP leg
// (`pattern_list`, `clip_add_drum_pattern`) is the NEXT lane, not here.
//
// Appended to the existing `@MainActor` suite `DrumKitCommandTests` (the router is
// main-actor; no new `@MainActor` suite: the `KitSliceWireTests` precedent).

extension DrumKitCommandTests {

    private func patternCall(_ router: CommandRouter, _ verb: String,
                             _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await router.handle(ControlRequest(id: "pat", command: verb, params: params))
    }

    /// A router over a new song with one NEW drum machine (`kind: .drumSynth` set
    /// explicitly; a stored `drumKit` alone would leave the poly synth playing).
    private func patternRouter() throws -> (CommandRouter, ProjectStore, UUID) {
        let store = ProjectStore(projectName: "W9-PAT wire")
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        _ = try store.setInstrument(id: id, kind: .drumSynth)
        return (CommandRouter(store: store), store, id)
    }

    // MARK: - Registration

    @Test("m39-w4-10: both verbs are registered once, beside clip.addMIDI, far from the tail")
    func patternVerbsAreRegistered() throws {
        let all = CommandRouter.allCommands
        for verb in ["pattern.list", "clip.addDrumPattern"] {
            #expect(all.filter { $0 == verb }.count == 1, "\(verb)")
        }
        #expect(!all.contains("pattern.add"), "negative control: a plausible name that is not registered")
        let anchor = try #require(all.firstIndex(of: "clip.addMIDI"))
        #expect(Array(all[(anchor + 1)...(anchor + 2)]) == ["clip.addDrumPattern", "pattern.list"])
        #expect(all.count - anchor > 100, "far from the tail, so the end-relative pins stay true")
    }

    // MARK: - pattern.list

    @Test("m39-w4-10: pattern.list answers every beat with a beginner's description, the user's pick first")
    func patternListShape() async throws {
        let (router, _, _) = try patternRouter()
        let response = await patternCall(router, "pattern.list")
        #expect(response.ok, "\(response.error ?? "")")
        let result = try #require(response.result)
        let patterns = try #require(result["patterns"]?.arrayValue)
        #expect(result["count"]?.doubleValue == Double(DrumPatternLibrary.patterns.count))
        #expect(patterns.count == 7)
        #expect(patterns.compactMap { $0["id"]?.stringValue } == DrumPatternLibrary.patterns.map(\.id))
        #expect(patterns.first?["id"]?.stringValue == "basicRock")
        let voices = Set(DrumVoice.allCases.map(\.rawValue))
        for (entry, pattern) in zip(patterns, DrumPatternLibrary.patterns) {
            #expect(Set(entry.objectValue?.keys.map { $0 } ?? []) == ["id", "name", "description", "bars", "roles"])
            #expect(entry["name"]?.stringValue == pattern.name)
            #expect(entry["description"]?.stringValue == pattern.summary)
            #expect(entry["bars"]?.doubleValue == Double(pattern.bars))
            let roles = try #require(entry["roles"]?.arrayValue).compactMap(\.stringValue)
            #expect(roles == pattern.roles.map(\.rawValue))
            #expect(Set(roles).isSubset(of: voices))
        }
        let rejected = await patternCall(router, "pattern.list", ["bogus": .bool(true)])
        #expect(rejected.error == "pattern.list: unknown parameter 'bogus' — pattern.list takes no parameters")
    }

    // MARK: - clip.addDrumPattern

    @Test("m39-w4-10: clip.addDrumPattern returns the clip plus what was written; the arrays are always present")
    func addDrumPatternReplyShape() async throws {
        let (router, store, id) = try patternRouter()
        let undoBefore = store.undoHistory().undo.count
        let response = await patternCall(router, "clip.addDrumPattern", [
            "trackId": .string(id.uuidString), "pattern": .string("basicRock"),
        ])
        #expect(response.ok, "\(response.error ?? "")")
        let result = try #require(response.result)
        let clip = try #require(store.tracks.first { $0.id == id }?.clips.first)
        #expect(store.undoHistory().undo.count == undoBefore + 1)

        // The clip's own fields, at the top level (the clip.addMIDI shape).
        #expect(result["id"]?.stringValue == clip.id.uuidString)
        #expect(result["name"]?.stringValue == "Basic Rock")
        #expect(result["startBeat"]?.doubleValue == 0)
        #expect(result["lengthBeats"]?.doubleValue == 4)
        #expect(result["notes"]?.arrayValue?.count == 12)

        #expect(result["pattern"]?.stringValue == "basicRock")
        #expect(result["patternName"]?.stringValue == "Basic Rock")
        #expect(result["bars"]?.doubleValue == 1)
        #expect(result["notesWritten"]?.doubleValue == 12)
        let written = try #require(result["rolesWritten"]?.arrayValue)
        #expect(written.compactMap { $0["role"]?.stringValue } == ["kick", "snare", "closedHat"])
        #expect(written.compactMap { $0["name"]?.stringValue } == ["Kick", "Snare", "Closed Hat"])
        #expect(written.compactMap { $0["note"]?.doubleValue } == [36, 38, 42])
        #expect(written.compactMap { $0["hits"]?.doubleValue } == [2, 2, 8])
        #expect(result["rolesLeftOut"]?.arrayValue == [], "present and empty on the ordinary path")
        #expect(result["warnings"]?.arrayValue == [], "present and empty on the ordinary path")

        // The added keys never shadow one of the clip's own.
        let clipKeys = Set(try #require(try JSONValue(encoding: clip).objectValue).keys)
        let added: Set<String> = ["pattern", "patternName", "bars", "notesWritten", "rolesWritten",
                                  "rolesLeftOut", "warnings"]
        #expect(clipKeys.isDisjoint(with: added))
        #expect(Set(result.objectValue?.keys.map { $0 } ?? []) == clipKeys.union(added))
    }

    @Test("m39-w4-10 P3 on the wire: a sorted kit with no open hat gets no note 46, and the reply names the Open Hat")
    func addDrumPatternLeavesTheOpenHatOut() async throws {
        let zones = [36: DrumVoice.kick, 38: .snare, 42: .closedHat].map { note, role in
            SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/w9-pat-loop.wav"),
                        rootPitch: note, minPitch: note, maxPitch: note, drumRole: role)
        }
        let track = Track(name: "Chopped Loop", kind: .instrument, instrument: InstrumentDescriptor(
            kind: .sampler, sampler: SamplerParams(zones: zones)))
        let router = CommandRouter(store: ProjectStore(projectName: "W9-PAT P3 wire", tracks: [track]))
        let response = await patternCall(router, "clip.addDrumPattern", [
            "trackId": .string(track.id.uuidString), "pattern": .string("Four on the Floor"), "bars": .number(2),
        ])
        #expect(response.ok, "\(response.error ?? "")")
        let result = try #require(response.result)
        let pitches = try #require(result["notes"]?.arrayValue).compactMap { $0["pitch"]?.doubleValue }
        #expect(!pitches.contains(46))
        #expect(pitches == Array(repeating: 36, count: 8))
        let leftOut = try #require(result["rolesLeftOut"]?.arrayValue)
        #expect(leftOut.compactMap { $0["role"]?.stringValue } == ["openHat", "clap"])
        #expect(leftOut.first?["name"]?.stringValue == "Open Hat")
        #expect(leftOut.first?["hits"]?.doubleValue == 8)
        #expect(leftOut.first?["note"] == nil, "a drum the kit lacks has no note")
        let warnings = try #require(result["warnings"]?.arrayValue).compactMap(\.stringValue)
        #expect(warnings.contains { $0.contains("Open Hat") })
        // The exact reply, for the MCP lane that documents it.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print("[W9-PAT REPLY clip.addDrumPattern] " + String(decoding: try encoder.encode(result), as: UTF8.self))
        let listed = await patternCall(router, "pattern.list")
        print("[W9-PAT REPLY pattern.list] " + String(decoding: try encoder.encode(try #require(listed.result)),
                                                         as: UTF8.self))
    }

    @Test("m39-w4-10: clip.addDrumPattern refuses bad params in words, and passes the store's refusals through")
    func addDrumPatternRefusals() async throws {
        let (router, store, id) = try patternRouter()
        let track = JSONValue.string(id.uuidString)
        func error(_ params: [String: JSONValue]) async -> String? {
            let response = await patternCall(router, "clip.addDrumPattern", params)
            return response.ok ? nil : response.error
        }
        #expect(await error(["trackId": track])?.contains("'pattern'") == true)
        #expect(await error(["trackId": track, "pattern": .string("")])?.contains("'pattern'") == true)
        #expect(await error(["trackId": track, "pattern": .number(1)])?.contains("'pattern'") == true)
        for bad: JSONValue in [.number(2.5), .number(0), .number(65), .string("2")] {
            #expect(await error(["trackId": track, "pattern": .string("trap"), "bars": bad])
                        == "'bars' must be a whole number from 1 to 64", "\(bad)")
        }
        for bad: JSONValue in [.number(-1), .string("x")] {
            #expect(await error(["trackId": track, "pattern": .string("trap"), "atBeat": bad])
                        == "'atBeat' must be a number of beats, 0 or more", "\(bad)")
        }
        #expect(await error(["trackId": track, "pattern": .string("trap"), "name": .string("x")])
                    == "clip.addDrumPattern: unknown parameter 'name' — valid keys are 'atBeat', 'bars', 'clipId', 'pattern', 'trackId'")
        #expect(await error(["trackId": track, "pattern": .string("polka")])?
                    .contains("There is no drum beat called 'polka'") == true)

        let synth = store.addTrack(name: "Bass", kind: .instrument).id
        #expect(await error(["trackId": .string(synth.uuidString), "pattern": .string("trap")])?
                    .contains("'Bass' plays the Poly Synth, not drums") == true)
        #expect(store.tracks.allSatisfy { $0.clips.isEmpty }, "no refusal wrote anything")

        // The overlap refusal is the store's sentence, verbatim.
        let ok = await patternCall(router, "clip.addDrumPattern", ["trackId": track, "pattern": .string("trap")])
        #expect(ok.ok)
        let overlap = try #require(await error(["trackId": track, "pattern": .string("trap"), "atBeat": .number(4)]))
        #expect(overlap.contains("would land on top of the clip 'Trap'"))
        #expect(overlap.contains("it would start at beat 8"))
    }

    // MARK: - The in-app copilot

    @Test("m39-w4-10: the copilot can list beats and write one; its schema is the wire's")
    func copilotOffersThePatternVerbs() throws {
        let list = try #require(CopilotToolCatalog.tool(command: "pattern.list"))
        #expect(list.schema["properties"]?.objectValue?.isEmpty == true)
        let add = try #require(CopilotToolCatalog.tool(command: "clip.addDrumPattern"))
        #expect(add.schema["required"]?.arrayValue?.compactMap(\.stringValue).sorted() == ["pattern", "trackId"])
        let properties = try #require(add.schema["properties"]?.objectValue)
        // `clipId` since W9-PATF: the wire fills an existing empty clip with it.
        #expect(Set(properties.keys) == ["trackId", "pattern", "bars", "atBeat", "clipId"])
        let offered = try #require(properties["pattern"]?["enum"]?.arrayValue).compactMap(\.stringValue)
        #expect(offered == DrumPatternLibrary.patterns.map(\.id))
        #expect(properties["bars"]?["minimum"]?.doubleValue == 1)
        #expect(properties["bars"]?["maximum"]?.doubleValue == 64)
        #expect(add.description.contains("one undo"))
    }

    // MARK: - W9-PATF: clip.addDrumPattern { clipId } fills an EXISTING empty clip

    /// A router over a new song with a drum machine and one EMPTY MIDI clip of `length` beats at `start`.
    private func emptyClipRouter(start: Double = 0, length: Double = 8)
        throws -> (CommandRouter, ProjectStore, UUID, Clip) {
        let (router, store, trackID) = try patternRouter()
        let clip = try store.addMIDIClip(toTrack: trackID, name: "Empty", atBeat: start, lengthBeats: length, notes: [])
        return (router, store, trackID, clip)
    }

    private func noteShape(_ notes: [MIDINote]) -> [[Double]] {
        notes.map { [Double($0.pitch), Double($0.velocity), $0.startBeat, $0.lengthBeats] }
    }

    @Test("W9-PATF: clip.addDrumPattern with clipId fills that empty clip, equal to fillDrumPattern's result")
    func addDrumPatternFillsAnExistingClip() async throws {
        let (router, store, trackID, clip) = try emptyClipRouter()
        let undoBefore = store.undoHistory().undo.count
        let response = await patternCall(router, "clip.addDrumPattern", [
            "trackId": .string(trackID.uuidString), "clipId": .string(clip.id.uuidString),
            "pattern": .string("basicRock"),
        ])
        #expect(response.ok, "\(response.error ?? "")")
        let result = try #require(response.result)
        #expect(store.undoHistory().undo.count == undoBefore + 1, "one undo step")
        #expect(store.tracks.first { $0.id == trackID }?.clips.count == 1, "no new clip")

        // The twin: the same store method, called directly on an identical song.
        let (_, twinStore, _, twinClip) = try emptyClipRouter()
        let direct = try twinStore.fillDrumPattern(named: "basicRock", intoClip: twinClip.id)

        let stored = try #require(store.tracks.first { $0.id == trackID }?.clips.first)
        #expect(stored.id == clip.id)
        #expect(noteShape(stored.notes ?? []) == noteShape(direct.clip.notes ?? []))
        #expect(!(stored.notes ?? []).isEmpty)

        #expect(result["id"]?.stringValue == clip.id.uuidString, "the clip's own fields at the top level")
        #expect(result["lengthBeats"]?.doubleValue == 8)
        #expect(result["notes"]?.arrayValue?.count == stored.notes?.count)
        #expect(result["pattern"]?.stringValue == direct.pattern.id)
        #expect(result["patternName"]?.stringValue == direct.pattern.name)
        #expect(result["bars"]?.doubleValue == Double(direct.bars))
        #expect(result["bars"]?.doubleValue == 2, "an 8-beat clip is 2 bars")
        #expect(result["notesWritten"]?.doubleValue == Double(direct.clip.notes?.count ?? -1))
        let written = try #require(result["rolesWritten"]?.arrayValue)
        #expect(written.compactMap { $0["role"]?.stringValue } == direct.written.map(\.role.rawValue))
        #expect(written.compactMap { $0["hits"]?.doubleValue } == direct.written.map { Double($0.hits) })
        #expect(result["rolesLeftOut"]?.arrayValue == [])
        #expect(result["warnings"]?.arrayValue?.compactMap(\.stringValue) == direct.warnings)
        #expect(Set(result.objectValue?.keys.map { $0 } ?? [])
                == Set(try #require(try JSONValue(encoding: stored).objectValue).keys)
                    .union(["pattern", "patternName", "bars", "notesWritten", "rolesWritten",
                            "rolesLeftOut", "warnings"]))
    }

    @Test("W9-PATF: clipId refuses a clip that already has notes, changing nothing")
    func fillRefusesAClipWithNotes() async throws {
        let (router, store, trackID, _) = try emptyClipRouter()
        let busy = try store.addMIDIClip(toTrack: trackID, name: "Busy", atBeat: 16, lengthBeats: 4,
                                         notes: [MIDINote(pitch: 36, velocity: 100, startBeat: 0, lengthBeats: 1)])
        let undoBefore = store.undoHistory().undo.count
        let response = await patternCall(router, "clip.addDrumPattern", [
            "trackId": .string(trackID.uuidString), "clipId": .string(busy.id.uuidString),
            "pattern": .string("basicRock"),
        ])
        #expect(!response.ok)
        #expect(response.error == DrumPatternFillError.clipNotEmpty(clipName: "Busy", noteCount: 1).errorDescription,
                "the store's sentence, verbatim: \(response.error ?? "")")
        #expect(store.undoHistory().undo.count == undoBefore)
        #expect(store.tracks.first { $0.id == trackID }?.clips.first { $0.id == busy.id }?.notes?.count == 1)
    }

    @Test("W9-PATF: clipId with atBeat or bars is refused in words; a track/clip mismatch is refused; a bad clipId is named")
    func fillRefusesConflictingParams() async throws {
        let (router, store, trackID, clip) = try emptyClipRouter()
        let other = store.addTrack(name: "Other Drums", kind: .instrument).id
        _ = try store.setInstrument(id: other, kind: .drumSynth)
        let track = JSONValue.string(trackID.uuidString)
        let clipValue = JSONValue.string(clip.id.uuidString)
        func error(_ extra: [String: JSONValue]) async -> String? {
            var params: [String: JSONValue] = ["trackId": track, "clipId": clipValue, "pattern": .string("basicRock")]
            for (key, value) in extra { params[key] = value }
            let response = await patternCall(router, "clip.addDrumPattern", params)
            return response.ok ? nil : response.error
        }
        let atBeat = try #require(await error(["atBeat": .number(4)]))
        #expect(atBeat.contains("'atBeat'") && atBeat.contains("clip"), "\(atBeat)")
        let bars = try #require(await error(["bars": .number(2)]))
        #expect(bars.contains("'bars'") && bars.contains("clip"), "\(bars)")
        let mismatch = try #require(await error(["trackId": .string(other.uuidString)]))
        #expect(mismatch.contains("Empty") && mismatch.contains("Drums"), "names the clip and its track: \(mismatch)")
        #expect(await error(["clipId": .string("nope")])?.contains("'clipId' is not a valid UUID") == true)
        #expect(await error(["clipId": .string(UUID().uuidString)]) != nil, "an unknown clip is refused")
        #expect(store.tracks.first { $0.id == trackID }?.clips.first?.notes?.isEmpty == true, "nothing was written")
    }

    @Test("W9-PATF: without clipId the new-clip form is unchanged, and clipId is a known key")
    func newClipFormIsUnchangedByClipId() async throws {
        let (router, store, id) = try patternRouter()
        let rejected = await patternCall(router, "clip.addDrumPattern", [
            "trackId": .string(id.uuidString), "pattern": .string("trap"), "name": .string("x"),
        ])
        #expect(rejected.error
                == "clip.addDrumPattern: unknown parameter 'name' — valid keys are 'atBeat', 'bars', 'clipId', 'pattern', 'trackId'")
        let ok = await patternCall(router, "clip.addDrumPattern", [
            "trackId": .string(id.uuidString), "pattern": .string("basicRock"), "bars": .number(2), "atBeat": .number(4),
        ])
        #expect(ok.ok, "\(ok.error ?? "")")
        #expect(ok.result?["startBeat"]?.doubleValue == 4)
        #expect(ok.result?["bars"]?.doubleValue == 2)
        #expect(store.tracks.first { $0.id == id }?.clips.count == 1)
    }
}
