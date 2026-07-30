import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m23-k3's `project.importMIDI` and
/// `clip.importMIDI`.
///
/// Scoped deliberately to WIRE behaviour: registration and the additive-at-END
/// law, the response shape, `rejectUnknownKeys`, the enum-value teaching
/// errors, and one row per §4.3 error condition. Every MAPPING claim — where a
/// note lands, what a hazard reports — is gated in DAWCoreTests against
/// hand-built IR values, because routing those through a WebSocket frame would
/// add a layer without adding evidence.
///
/// The `.mid` inputs here are hand-authored bytes written to a temp file rather
/// than the checked-in fixtures (which live in the DAWCoreTests bundle and are
/// not reachable from this target). That is honest for this suite's claim: the
/// bytes are plumbing, not the thing under test.
@MainActor
@Suite("MIDI file import — control protocol (m23-k3)")
struct MIDIFileImportCommandTests {

    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        return (CommandRouter(store: store), store)
    }

    /// Format 1, 480 tpqn: a conductor chunk carrying 120 BPM, and one part
    /// "Lead" with a single note 60 from tick 0 to tick 480.
    private static func simpleFile() throws -> URL {
        let bytes: [UInt8] = [
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
            0x00, 0x01, 0x00, 0x02, 0x01, 0xE0,
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x0B,
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
            0x00, 0xFF, 0x2F, 0x00,
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x15,
            0x00, 0xFF, 0x03, 0x04, 0x4C, 0x65, 0x61, 0x64,   // track name "Lead"
            0x00, 0x90, 0x3C, 0x64,                           // note 60 on, vel 100
            0x83, 0x60, 0x80, 0x3C, 0x40,                     // +480 ticks: note off
            0x00, 0xFF, 0x2F, 0x00,
        ]
        return try write(Data(bytes), name: "wire-simple.mid")
    }

    private static func write(_ data: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m23k3-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Registration

    /// The additive-at-END law: both new verbs sit at the tail, so no live
    /// command was renamed or reordered.
    @Test("both verbs are registered, at the END of the command list")
    func commandsAreRegisteredAtTheEnd() {
        // 161 since m23-k4a appended `project.exportMIDI` / `track.exportMIDI`,
        // m23-n2b appended `clip.transcribe`, m23-n3b appended
        // `ai.installSpeechModel`/`ai.speechModelInstallStatus`, m23-r4
        // appended `fx.spectrum`, m23-o1 appended `frequency.reference`, and
        // m23-w appended `clip.removeMany`/`clip.moveMany` AFTER this pair —
        // the additive-at-end law working, not a regression: the k3 verbs did
        // not move, they are simply no longer last.
        #expect(CommandRouter.allCommands.count == 165)   // 159 -> 161 at m23-n3b -> 162 at m23-r4 -> 163 at m23-o1 -> 165 at m23-w
        #expect(Array(CommandRouter.allCommands.suffix(11).prefix(2))
                == ["project.importMIDI", "clip.importMIDI"])
    }

    // MARK: - project.importMIDI

    @Test("project.importMIDI returns {report, applied} and creates the track")
    func projectImportRoundTrips() async throws {
        let (router, store) = makeRouter()
        let url = try Self.simpleFile()

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.importMIDI",
            params: ["path": .string(url.path)]))
        #expect(response.ok)
        #expect(response.result?["applied"]?.boolValue == true)
        let report = try #require(response.result?["report"]?.objectValue)
        #expect(report["tracksCreated"]?.doubleValue == 1)
        #expect(report["notesImported"]?.doubleValue == 1)
        // `auto` on an empty project resolves to adopt, and the report always
        // echoes what it RESOLVED to — never "auto".
        #expect(report["resolvedTempoPolicy"]?.stringValue == "adopt")
        #expect(report["divisionDescription"]?.stringValue == "480 ticks per quarter note")
        // The per-part ledger includes the skipped conductor, so a `parts` index
        // means the same thing here as in a dry run.
        #expect(report["parts"]?.arrayValue?.count == 2)
        #expect(store.tracks.count == 1)
        #expect(store.tracks[0].clips[0].notes?.count == 1)
    }

    @Test("dryRun reports without applying, and names no track or clip")
    func dryRunAppliesNothing() async throws {
        let (router, store) = makeRouter()
        let url = try Self.simpleFile()

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.importMIDI",
            params: ["path": .string(url.path), "dryRun": .bool(true)]))
        #expect(response.ok)
        #expect(response.result?["applied"]?.boolValue == false)
        let parts = try #require(response.result?["report"]?.objectValue?["parts"]?.arrayValue)
        #expect(parts.allSatisfy { $0.objectValue?["trackId"] == nil })
        #expect(store.tracks.isEmpty)

        // Non-vacuity for the line above: a REAL run of the same file DOES name
        // a track, so "no trackId" is a fact about the dry run and not about the
        // key being spelled wrong.
        let real = await router.handle(ControlRequest(
            id: "2", command: "project.importMIDI", params: ["path": .string(url.path)]))
        let realParts = try #require(real.result?["report"]?.objectValue?["parts"]?.arrayValue)
        #expect(realParts.contains { $0.objectValue?["trackId"]?.stringValue != nil })
    }

    @Test("parts and instruments plumb through to the store")
    func selectiveImportPlumbsThrough() async throws {
        let (router, store) = makeRouter()
        let url = try Self.simpleFile()

        // Part 0 is the conductor: selecting it alone would do nothing, which is
        // a refusal rather than a silent success.
        let nothing = await router.handle(ControlRequest(
            id: "1", command: "project.importMIDI",
            params: ["path": .string(url.path), "parts": .array([.number(0)]),
                     "tempoPolicy": .string("ignore")]))
        #expect(!nothing.ok)
        #expect(store.tracks.isEmpty)

        let some = await router.handle(ControlRequest(
            id: "2", command: "project.importMIDI",
            params: ["path": .string(url.path), "parts": .array([.number(1)]),
                     "instruments": .string("gm")]))
        #expect(some.ok)
        #expect(store.tracks.count == 1)
        #expect(store.tracks[0].instrument?.kind == .soundBank)
    }

    // MARK: - The error surface (§4.3)

    @Test("F5 hardening — a typo'd key is rejected by name, never treated as a default")
    func unknownKeysAreRejected() async throws {
        let (router, _) = makeRouter()
        let url = try Self.simpleFile()

        // "policy" is the plausible typo for "tempoPolicy". Accepting it
        // silently would leave the caller's tempo intent unapplied with an ok
        // response — the exact class F5 exists to catch.
        let response = await router.handle(ControlRequest(
            id: "1", command: "project.importMIDI",
            params: ["path": .string(url.path), "policy": .string("ignore")]))
        #expect(!response.ok)
        let message = try #require(response.error)
        #expect(message.contains("'policy'"))
        #expect(message.contains("tempoPolicy"))

        let clipResponse = await router.handle(ControlRequest(
            id: "2", command: "clip.importMIDI",
            params: ["clipId": .string(UUID().uuidString), "path": .string(url.path),
                     "tempoPolicy": .string("adopt")]))
        #expect(!clipResponse.ok)
        // A clip import has no tempo policy AT ALL, so naming one is a typo
        // worth surfacing rather than a silently ignored key.
        #expect(try #require(clipResponse.error).contains("'tempoPolicy'"))
    }

    @Test("an unknown tempoPolicy or instruments VALUE lists the legal ones")
    func unknownEnumValuesTeach() async throws {
        let (router, _) = makeRouter()
        let url = try Self.simpleFile()

        let policy = await router.handle(ControlRequest(
            id: "1", command: "project.importMIDI",
            params: ["path": .string(url.path), "tempoPolicy": .string("ask")]))
        #expect(!policy.ok)
        let policyMessage = try #require(policy.error)
        #expect(policyMessage.contains("\"auto\""))
        #expect(policyMessage.contains("\"adopt\""))
        #expect(policyMessage.contains("\"ignore\""))

        let instruments = await router.handle(ControlRequest(
            id: "2", command: "project.importMIDI",
            params: ["path": .string(url.path), "instruments": .string("general-midi")]))
        #expect(!instruments.ok)
        #expect(try #require(instruments.error).contains("\"gm\""))
    }

    @Test("§4.3 — every error row surfaces a teaching sentence and mutates nothing")
    func errorSurface() async throws {
        let (router, store) = makeRouter()
        let url = try Self.simpleFile()

        let relative = await router.handle(ControlRequest(
            id: "1", command: "project.importMIDI",
            params: ["path": .string("songs/x.mid")]))
        #expect(relative.error == "'path' must be an absolute path")

        let wrongExtension = await router.handle(ControlRequest(
            id: "2", command: "project.importMIDI",
            params: ["path": .string("/tmp/m23k3-absent/song.txt")]))
        #expect(try #require(wrongExtension.error).contains("is not a MIDI file"))

        let missing = await router.handle(ControlRequest(
            id: "3", command: "project.importMIDI",
            params: ["path": .string("/tmp/m23k3-absent/song.mid")]))
        #expect(try #require(missing.error).contains("no MIDI file at"))

        // k1's decode errors are already teaching-grade, so they surface
        // VERBATIM rather than being re-wrapped in an import-flavoured message.
        let garbage = try Self.write(Data([0x4D, 0x54, 0x68, 0x58, 0, 0, 0, 6, 0, 0, 0, 1, 1, 0xE0]),
                                     name: "bad.mid")
        let malformed = await router.handle(ControlRequest(
            id: "4", command: "project.importMIDI", params: ["path": .string(garbage.path)]))
        #expect(try #require(malformed.error).contains("This is not a MIDI file"))

        // D1′ — the refusal names BOTH escapes, so an agent can act on it.
        let offsetAdopt = await router.handle(ControlRequest(
            id: "5", command: "project.importMIDI",
            params: ["path": .string(url.path), "atBeat": .number(8),
                     "tempoPolicy": .string("adopt")]))
        #expect(!offsetAdopt.ok)
        let adoptMessage = try #require(offsetAdopt.error)
        #expect(adoptMessage.contains("beat 0"))
        #expect(adoptMessage.contains("\"ignore\""))

        #expect(store.tracks.isEmpty)
        #expect(store.undoHistory().undo.isEmpty)
    }

    // MARK: - clip.importMIDI

    @Test("clip.importMIDI replaces the clip's content and never moves the grid")
    func clipImportRoundTrips() async throws {
        let (router, store) = makeRouter()
        let url = try Self.simpleFile()
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "atBeat": .number(4),
                     "lengthBeats": .number(8),
                     "notes": .array([.object(["pitch": .number(36),
                                               "startBeat": .number(0),
                                               "lengthBeats": .number(1)])])]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        let tempoBefore = store.transport.tempoBPM

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.importMIDI",
            params: ["clipId": .string(clipID), "path": .string(url.path)]))
        #expect(response.ok)
        #expect(response.result?["applied"]?.boolValue == true)
        let clip = store.tracks[0].clips[0]
        #expect(clip.notes?.map(\.pitch) == [60])
        #expect(clip.startBeat == 4)
        #expect(clip.lengthBeats == 8)
        #expect(store.transport.tempoBPM == tempoBefore)
        #expect(response.result?["report"]?.objectValue?["tempoSegmentsAdopted"]?
                .doubleValue == 0)
    }

    @Test("clip.importMIDI on an unknown clip fails without touching the project")
    func clipImportGuardsOnTheWire() async throws {
        let (router, store) = makeRouter()
        let url = try Self.simpleFile()
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.importMIDI",
            params: ["clipId": .string(UUID().uuidString), "path": .string(url.path)]))
        #expect(!response.ok)
        #expect(store.tracks.isEmpty)
    }
}
