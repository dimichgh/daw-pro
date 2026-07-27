import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m23-k4a's `project.exportMIDI` and
/// `track.exportMIDI`.
///
/// Scoped deliberately to WIRE behaviour, exactly as the import twin is:
/// registration and the additive-at-END law, the `{report, written}` response
/// shape, `rejectUnknownKeys`, the contract-range teaching errors, and one row
/// per §6.3 error condition. Every MAPPING claim — where a note lands, what a
/// hazard reports — is gated in DAWCoreTests against hand-built project values,
/// because routing those through a WebSocket frame would add a layer without
/// adding evidence.
@MainActor
@Suite("MIDI file export — control protocol (m23-k4a)")
struct MIDIFileExportCommandTests {

    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        return (CommandRouter(store: store), store)
    }

    private func populate(_ store: ProjectStore) throws -> UUID {
        let track = store.addTrack(name: "Lead", kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4)
        _ = try store.setClipNotes(clipID: clip.id, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 64, startBeat: 2, lengthBeats: 1),
        ])
        return track.id
    }

    private static func tempPath(_ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m23k4a-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name).path
    }

    // MARK: - Registration

    /// The additive-at-END law: both new verbs sit at the tail, so no live
    /// command was renamed or reordered and HEAD's list stays an exact PREFIX.
    @Test("both verbs are registered, at the END of the command list")
    func commandsAreRegisteredAtTheEnd() {
        #expect(CommandRouter.allCommands.count == 158)
        #expect(Array(CommandRouter.allCommands.suffix(2))
                == ["project.exportMIDI", "track.exportMIDI"])
        // The k3 pair is still where it was, one rung up — the exact-prefix
        // claim, asserted rather than assumed.
        #expect(Array(CommandRouter.allCommands.suffix(4).prefix(2))
                == ["project.importMIDI", "clip.importMIDI"])
    }

    // MARK: - project.exportMIDI

    @Test("project.exportMIDI returns {report, written} and writes the file")
    func projectExportRoundTrips() async throws {
        let (router, store) = makeRouter()
        _ = try populate(store)
        let path = try Self.tempPath("song.mid")

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.exportMIDI", params: ["path": .string(path)]))
        #expect(response.ok)
        #expect(response.result?["written"]?.boolValue == true)
        let report = try #require(response.result?["report"]?.objectValue)
        #expect(report["written"]?.boolValue == true)
        #expect(report["path"]?.stringValue == path)
        #expect(report["tracksExported"]?.doubleValue == 1)
        #expect(report["notesExported"]?.doubleValue == 2)
        #expect(report["ticksPerQuarterNote"]?.doubleValue == 9600)
        #expect(report["divisionDescription"]?.stringValue == "9600 ticks per quarter note")
        #expect(report["degradations"]?.arrayValue?.isEmpty == true)
        // The per-track ledger rides the wire with `trackId` spelled the way
        // every command's params spell it.
        let rows = try #require(report["tracks"]?.arrayValue)
        #expect(rows.count == 1)
        #expect(rows[0].objectValue?["trackId"]?.stringValue != nil)
        #expect(FileManager.default.fileExists(atPath: path))

        // And the bytes are re-importable through the SHIPPED k3 verb, on the
        // same wire — the round trip a user actually performs.
        let back = await router.handle(ControlRequest(
            id: "2", command: "project.importMIDI",
            params: ["path": .string(path), "tempoPolicy": .string("ignore")]))
        #expect(back.ok)
        #expect(back.result?["report"]?.objectValue?["notesImported"]?.doubleValue == 2)
    }

    @Test("dryRun reports without writing anything")
    func dryRunWritesNothing() async throws {
        let (router, store) = makeRouter()
        _ = try populate(store)
        let path = try Self.tempPath("song.mid")

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.exportMIDI",
            params: ["path": .string(path), "dryRun": .bool(true)]))
        #expect(response.ok)
        #expect(response.result?["written"]?.boolValue == false)
        // The path is still reported — "where would this go" is one of the two
        // questions a dry run exists to answer.
        #expect(response.result?["report"]?.objectValue?["path"]?.stringValue == path)
        #expect(FileManager.default.fileExists(atPath: path) == false)

        // Non-vacuity for the line above: a REAL run of the same request DOES
        // create the file, so "no file" is a fact about the dry run and not
        // about the path being wrong.
        let real = await router.handle(ControlRequest(
            id: "2", command: "project.exportMIDI", params: ["path": .string(path)]))
        #expect(real.result?["written"]?.boolValue == true)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("trackIds, division and format plumb through to the store")
    func optionsPlumbThrough() async throws {
        let (router, store) = makeRouter()
        let leadID = try populate(store)
        _ = store.addTrack(name: "Bass", kind: .instrument)

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.exportMIDI",
            params: ["trackIds": .array([.string(leadID.uuidString)]),
                     "division": .number(480), "format": .number(0),
                     "dryRun": .bool(true)]))
        #expect(response.ok)
        let report = try #require(response.result?["report"]?.objectValue)
        #expect(report["ticksPerQuarterNote"]?.doubleValue == 480)
        #expect(report["format"]?.doubleValue == 0)
        #expect(report["tracks"]?.arrayValue?.count == 1)
        #expect(report["tracksExported"]?.doubleValue == 1)
    }

    // MARK: - track.exportMIDI

    @Test("track.exportMIDI writes one part and returns the same shape")
    func trackExportRoundTrips() async throws {
        let (router, store) = makeRouter()
        let leadID = try populate(store)
        _ = store.addTrack(name: "Bass", kind: .instrument)
        let path = try Self.tempPath("lead.mid")

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.exportMIDI",
            params: ["trackId": .string(leadID.uuidString), "path": .string(path)]))
        #expect(response.ok)
        #expect(response.result?["written"]?.boolValue == true)
        let report = try #require(response.result?["report"]?.objectValue)
        #expect(report["tracks"]?.arrayValue?.count == 1)
        #expect(report["tracks"]?.arrayValue?[0].objectValue?["name"]?.stringValue == "Lead")
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("track.exportMIDI on an audio track refuses and names the kind")
    func trackExportRefusesNonInstrument() async throws {
        let (router, store) = makeRouter()
        let audio = store.addTrack(name: "Vox", kind: .audio)
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.exportMIDI",
            params: ["trackId": .string(audio.id.uuidString)]))
        #expect(!response.ok)
        let message = response.error ?? ""
        #expect(message.contains("audio"))
        #expect(message.contains("project.exportMIDI"))
    }

    // MARK: - §6.3, one row each

    @Test("rejectUnknownKeys catches a typo'd param on both verbs")
    func unknownKeysAreRejected() async throws {
        let (router, store) = makeRouter()
        let leadID = try populate(store)

        // `ppq` is the typo an agent that knows other DAWs will reach for.
        let project = await router.handle(ControlRequest(
            id: "1", command: "project.exportMIDI",
            params: ["ppq": .number(480), "dryRun": .bool(true)]))
        #expect(!project.ok)
        #expect((project.error ?? "").contains("ppq") == true)

        // …and `tracks`, the plural an agent guesses instead of `trackIds`.
        let plural = await router.handle(ControlRequest(
            id: "2", command: "project.exportMIDI",
            params: ["tracks": .array([]), "dryRun": .bool(true)]))
        #expect(!plural.ok)

        let track = await router.handle(ControlRequest(
            id: "3", command: "track.exportMIDI",
            params: ["trackId": .string(leadID.uuidString), "ticks": .number(480)]))
        #expect(!track.ok)
        #expect((track.error ?? "").contains("ticks") == true)
    }

    @Test("division and format are contract-range checked, by field name")
    func contractRangeErrors() async throws {
        let (router, store) = makeRouter()
        _ = try populate(store)

        for bad in [0.0, 32768.0, 9600.5] {
            let response = await router.handle(ControlRequest(
                id: "1", command: "project.exportMIDI",
                params: ["division": .number(bad), "dryRun": .bool(true)]))
            #expect(!response.ok, "division \(bad) should refuse")
            #expect((response.error ?? "").contains("division") == true)
            #expect((response.error ?? "").contains("32767") == true)
        }
        // The edges are legal — a range leg that only tests the outside cannot
        // tell a correct bound from an off-by-one.
        for good in [1.0, 32767.0] {
            let response = await router.handle(ControlRequest(
                id: "2", command: "project.exportMIDI",
                params: ["division": .number(good), "dryRun": .bool(true)]))
            #expect(response.ok, "division \(good) should be legal")
        }

        let format = await router.handle(ControlRequest(
            id: "3", command: "project.exportMIDI",
            params: ["format": .number(2), "dryRun": .bool(true)]))
        #expect(!format.ok)
        #expect((format.error ?? "").contains("format") == true)
    }

    @Test("a relative path is refused rather than resolved against the process directory")
    func relativePathIsRefused() async throws {
        let (router, store) = makeRouter()
        _ = try populate(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "project.exportMIDI",
            params: ["path": .string("song.mid"), "dryRun": .bool(true)]))
        #expect(!response.ok)
        #expect((response.error ?? "").contains("absolute path") == true)
    }

    @Test("an unknown trackId surfaces trackNotFound on both verbs")
    func unknownTrackID() async throws {
        let (router, store) = makeRouter()
        _ = try populate(store)
        let stranger = UUID().uuidString

        let project = await router.handle(ControlRequest(
            id: "1", command: "project.exportMIDI",
            params: ["trackIds": .array([.string(stranger)]), "dryRun": .bool(true)]))
        #expect(!project.ok)

        let track = await router.handle(ControlRequest(
            id: "2", command: "track.exportMIDI",
            params: ["trackId": .string(stranger), "dryRun": .bool(true)]))
        #expect(!track.ok)
    }

    @Test("a project with no instrument track refuses, but its dry run succeeds")
    func nothingToExport() async throws {
        let (router, store) = makeRouter()
        _ = store.addTrack(name: "Vox", kind: .audio)
        let path = try Self.tempPath("empty.mid")

        let refusal = await router.handle(ControlRequest(
            id: "1", command: "project.exportMIDI", params: ["path": .string(path)]))
        #expect(!refusal.ok)
        #expect((refusal.error ?? "").contains("nothing to export") == true)
        #expect(FileManager.default.fileExists(atPath: path) == false)

        let dry = await router.handle(ControlRequest(
            id: "2", command: "project.exportMIDI",
            params: ["path": .string(path), "dryRun": .bool(true)]))
        #expect(dry.ok)
        #expect(dry.result?["report"]?.objectValue?["tracksExported"]?.doubleValue == 0)
    }

    @Test("content past the tick ceiling refuses with a message naming a smaller division")
    func tickCeilingRefusal() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "Far", kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 30_000, lengthBeats: 4)
        _ = try store.setClipNotes(clipID: clip.id,
                                   notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])

        let refusal = await router.handle(ControlRequest(
            id: "1", command: "project.exportMIDI", params: ["dryRun": .bool(true)]))
        #expect(!refusal.ok)
        #expect((refusal.error ?? "").contains("480") == true)

        // The same project at a smaller division succeeds — the limit is
        // division-dependent, not a project-size cap.
        let smaller = await router.handle(ControlRequest(
            id: "2", command: "project.exportMIDI",
            params: ["division": .number(480), "dryRun": .bool(true)]))
        #expect(smaller.ok)
    }
}
