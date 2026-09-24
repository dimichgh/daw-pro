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

    /// Format 0, 480 tpqn, ONE chunk named "Song" carrying two channels with
    /// different programs (40 = Violin on ch 0, 48 = String Ensemble 1 on ch 1).
    /// The shape of the user's m23-k5 report in miniature: the file's own name
    /// is the same for every part, so `name` and `trackName` must differ.
    private static func formatZeroFile() throws -> URL {
        let bytes: [UInt8] = [
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
            0x00, 0x00, 0x00, 0x01, 0x01, 0xE0,               // format 0, 1 chunk, 480 tpqn
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x23,   // MTrk, 35 bytes
            0x00, 0xFF, 0x03, 0x04, 0x53, 0x6F, 0x6E, 0x67,   // track name "Song"
            0x00, 0xC0, 0x28,                                 // ch 0 program 40
            0x00, 0xC1, 0x30,                                 // ch 1 program 48
            0x00, 0x90, 0x3C, 0x64,                           // ch 0 note 60 on
            0x00, 0x91, 0x40, 0x64,                           // ch 1 note 64 on
            0x83, 0x60, 0x80, 0x3C, 0x40,                     // +480: ch 0 note off
            0x00, 0x81, 0x40, 0x40,                           // ch 1 note off
            0x00, 0xFF, 0x2F, 0x00,
        ]
        return try write(Data(bytes), name: "wire-format0.mid")
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
        // appended `fx.spectrum`, m23-o1 appended `frequency.reference`,
        // m23-w appended `clip.removeMany`/`clip.moveMany`, m23-af appended
        // `transport.panic`, and m23-aj-2 appended
        // `clip.moveManyByTracks`/`clip.moveManyToTrack` AFTER this pair —
        // the additive-at-end law working, not a regression: the k3 verbs did
        // not move, they are simply no longer last.
        #expect(CommandRouter.allCommands.count == 234)   // 159 -> 161 at m23-n3b -> 162 at m23-r4 -> 163 at m23-o1 -> 165 at m23-w -> 166 at m23-af -> 168 at m20-j -> 169 at m23-br-1 -> 171 at m23-aj-2 -> 173 at m23-dl -> 174 at m23-di-2a -> 175 at m25-d -> 176 at m25-z -> 177 at m23-ap-3 -> 178 (clip.getNotes) -> 179 (m26-i instrument.describeSampler) -> 180 (edit.pasteClips) -> 181 (m27 leg D clip.applyBreathContour, placed next to its controller-lane siblings, NOT at the tail) -> 182 (breath pad P1 clip.applyEffortShape, placed next to clip.applyBreathContour, NOT at the tail) -> 183 (breath pad P6 pad.previewEffort, placed next to note.audition — the other 'sounds now, outside the timeline, not an edit' verb — NOT at the tail) -> 186 (m28-knob midi.getControlMap/setControlMap/learnControl, placed next to midi.listInputs — their only sibling on this surface — and BEFORE transport.record, NOT at the tail) -> 187 (m31-f instrument.probeLiveness) -> 188 (m31-c clip.repeatNotes, placed next to clip.setNotes/clip.getNotes, NOT at the tail) -> 189 (m26-a/m27-n clip.patchNotes, placed next to clip.repeatNotes, NOT at the tail) -> 190 (m32-b2 clip.sliceToSampler, placed next to clip.detectTransients/clip.quantizeAudio, NOT at the tail) -> 191 (m24-m leg A vc.convertClips, placed next to vc.convertVocals — its single-clip sibling — NOT at the tail) -> 193 (m24-n project.embeddedVoices next to project.snapshot/project.open, and vc.installEmbeddedVoice next to vc.importVoiceModel, both at the tail per the additive-at-end law) -> 194 (m23-ct note.play, placed next to note.audition/pad.previewEffort — the other 'sounds now, outside the timeline' verbs — NOT at the tail; a tail append reddened 19 end-relative assertions across 7 files on this item's first run) -> 195 (m23-cv chord.voice, a PURE read-only computation, placed next to note.play and NOT at the tail: LivePlayCommandTests pins note.play to pad.previewEffort + 1, so an insertion BEFORE it would redden that instead) -> 202 (m34-c instrument.listDownloadableSoundBanks/downloadSoundBank/soundBankDownloadStatus/cancelSoundBankDownload — the one-click SoundFont download, all four placed next to instrument.importSoundBank — their nearest sibling — and NOT at the tail, so every dropLast(N) window above stays true by construction; a tail placement was tried first and reddened 14 tests) -> 211 (m34-h-1 LIVE LOOPING looper.begin/armLayer/finishLayer/undoLayer/setLayerMuted/status/end, all seven placed immediately after transport.recordLayer/finishLayer — the verbs whose machinery the deck drives — and ~71 entries from the END, NOT at the tail, so every dropLast(N) window and suffix assertion above stays true by construction) -> 215 (M35 view.capture/view.selectClip/view.panelLayout/view.openEditor, the agent-facing VIEW surface, all four placed immediately after plugin.listOpenUIs and ~70 entries from the END, NOT at the tail) -> 218 (m39-f instrument.describeSynth, placed next to instrument.describeSampler, NOT at the tail) -> 231 at m39-dm (instrument.setDrumParam/describeDrumKit/listDrumPresets/loadDrumPreset — the drum machine's four verbs, placed next to instrument.describeSynth/describeSampler, their only siblings on this surface, and NOT at the tail, so every dropLast(N) window and suffix assertion stays true by construction) -> 234 at m23-q (clip.autoCorrectPitch/clip.clearPitchEdits/clip.getPitchEdits, appended at the tail)
        // -> 187 (m31-f instrument.probeLiveness, placed next to instrument.describeSampler — its read-only instrument.* sibling — NOT at the tail)
        // …and m23-dl appended `ai.modelResidency`/`ai.modelUnload` after
        // THAT, then m23-di-2a appended `vc.importVoiceModel`, m25-d appended
        // `transport.setStopAtContentEnd`, m25-z appended `audio.profileFile`,
        // m23-ap-3 appended `clip.detectPitch`, and m26-k appended
        // `edit.pasteClips`, then m23-q Phase 2 appended
        // `clip.autoCorrectPitch`/`clip.clearPitchEdits`/`clip.getPitchEdits`,
        // each after the last.
        #expect(Array(CommandRouter.allCommands.suffix(26).prefix(2))
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

    /// m23-k5 — the WIRE default. `parseMIDIImportInstruments` returns a value
    /// for an ABSENT key, so the default is spelled in the control plane as well
    /// as in the store, and this is the leg that pins them together. An agent
    /// (and the MCP tool, which omits undefined params) that names no policy
    /// must get the instruments the file names.
    @Test("m23-k5 — an absent 'instruments' key defaults to gm on the wire")
    func instrumentsDefaultsToGMOnTheWire() async throws {
        let (router, store) = makeRouter()
        let url = try Self.formatZeroFile()

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.importMIDI", params: ["path": .string(url.path)]))
        #expect(response.ok)

        let report = try #require(response.result?["report"]?.objectValue)
        #expect(report["instrumentsAssigned"]?.stringValue == "gm")
        #expect(store.tracks.count == 2)
        #expect(store.tracks.allSatisfy { $0.instrument?.kind == .soundBank })
        #expect(store.tracks.map { $0.instrument?.soundBank?.program } == [40, 48])

        // The additive report field, read OFF THE WIRE rather than off the model:
        // `name` stays the file's literal chunk name for both parts, `trackName`
        // carries what the tracks were actually called.
        let parts = try #require(report["parts"]?.arrayValue)
        #expect(parts.compactMap { $0.objectValue?["name"]?.stringValue } == ["Song", "Song"])
        #expect(parts.compactMap { $0.objectValue?["trackName"]?.stringValue }
                == ["Violin", "String Ensemble 1"])
        #expect(store.tracks.map(\.name) == ["Violin", "String Ensemble 1"])
    }

    /// …and the opt-out still reaches the store through the same key.
    @Test("m23-k5 — instruments: \"none\" still opts out on the wire")
    func explicitNoneOptsOutOnTheWire() async throws {
        let (router, store) = makeRouter()
        let url = try Self.formatZeroFile()

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.importMIDI",
            params: ["path": .string(url.path), "instruments": .string("none")]))
        #expect(response.ok)
        #expect(try #require(response.result?["report"]?.objectValue)["instrumentsAssigned"]?
                .stringValue == "none")
        #expect(store.tracks.allSatisfy { $0.instrument == nil })
        // Naming is independent of the instrument policy.
        #expect(store.tracks.map(\.name) == ["Violin", "String Ensemble 1"])
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
