import Foundation
import Testing
import DAWAppKit
@testable import DAWCore
@testable import DAWEngine

/// **The plan equals the disk** (m23-m3c) — the one assertion this item exists
/// to make.
///
/// The Export dialog's stems mode shows a read-only list of the files it is
/// about to write. That list is `StemPlan.fileSet`. If `fileSet` and
/// `renderStems` could ever disagree — about which tracks are master inputs,
/// about the numbering after a bus-routed track drops out, about a duplicate
/// name's suffix, about the container's extension, about whether the two `00 …`
/// siblings are written at all — the dialog would promise files nobody gets, and
/// no unit test of either side alone would see it. So these legs render for
/// real and compare the promise against `contentsOfDirectory`.
///
/// The fixture is built so the comparison can FAIL if any of those is wrong:
///
///  · **a bus-routed track** ("Bass" → bus "Verb") — it must have no file of its
///    own, and the bus must take the index it vacates (eligibility + renumbering);
///  · **two tracks named the same** — so the " 2" collision suffix is in the
///    compared set rather than assumed;
///  · **a non-default container** (AIFF) on the dialog leg — at the WAV default a
///    `fileSet` with a hardcoded ".wav" passes, and the extension is the
///    load-bearing field (m23-m2: it selects the container the writer produces);
///  · **both mixdown siblings on** — the two names that were string literals
///    inside `renderStems` before this item.
///
/// Each render gets a FRESH directory: a shared one would carry the previous
/// run's files into the next listing. And the listing is read from
/// `result.directory` — the path the store resolved — never from the argument,
/// which would test nothing about where the files actually went.
@MainActor
@Suite("Stems plan == stems on disk (m23-m3c)", .serialized)
struct StemFileSetTests {

    // MARK: - Fixture

    /// Keys (direct), Bass (routed into Verb), Verb (bus), Keys again (direct,
    /// same name). Partition: Keys, Verb, Keys → "01 Keys", "02 Verb",
    /// "03 Keys 2". Bass is absent by the master-input rule.
    private func fixtureTracks() throws -> [Track] {
        let fixtures = try TestSignals.fixtures()
        let verb = Track(name: "Verb", kind: .bus)
        let keys = Track(name: "Keys", kind: .audio, pan: -0.3,
                         clips: [Clip(name: "k", startBeat: 0, lengthBeats: 4,
                                      audioFileURL: fixtures.cos1k48)])
        let bass = Track(name: "Bass", kind: .audio, volume: 0.7, pan: 0.4,
                         clips: [Clip(name: "b", startBeat: 0, lengthBeats: 4,
                                      audioFileURL: fixtures.cos1k48Quarter)],
                         outputBusID: verb.id)
        let keysAgain = Track(name: "Keys", kind: .audio, volume: 0.5,
                              clips: [Clip(name: "k2", startBeat: 0, lengthBeats: 4,
                                           audioFileURL: fixtures.cos1k48Quarter)])
        return [keys, bass, verb, keysAgain]
    }

    private func makeStore(tracks: [Track], engine: AudioEngine) -> ProjectStore {
        let store = ProjectStore()
        store.engine = engine
        store.tracks = tracks
        return store
    }

    private func freshDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-fileset-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// What is actually in the folder, `.DS_Store`-tolerant (a Finder visit
    /// during a run must not redden a leg about stem names).
    private func contents(of directory: String) throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        return Set(names.filter { !$0.hasPrefix(".") })
    }

    // MARK: - Leg 1: the store's own call, at the default format

    @Test("what renderStems writes IS StemPlan.fileSet, including the siblings")
    func renderStemsWritesExactlyThePlannedSet() async throws {
        // `ProjectStore.engine` is weak — hold the engine for the test's life.
        let engine = AudioEngine()
        defer { withExtendedLifetime(engine) {} }
        let tracks = try fixtureTracks()
        let store = makeStore(tracks: tracks, engine: engine)
        let dir = try freshDirectory("store")

        let planned = try StemPlan.fileSet(tracks: tracks,
                                           includeMixdown: true,
                                           includeMasteredMixdown: true)
        // Pinned literally as well as by construction: an equality against a
        // plan that is itself wrong would pass while both sides lie.
        #expect(planned == ["00 Mixdown.wav", "00 Mastered Mix.wav",
                            "01 Keys.wav", "02 Verb.wav", "03 Keys 2.wav"])

        let result = try await store.renderStems(toDirectory: dir.path,
                                                 includeMixdown: true,
                                                 includeMasteredMixdown: true)
        // Read the directory the STORE resolved, not the one we passed.
        #expect(try contents(of: result.directory) == Set(planned))
        // …and the plan is not merely a superset of the stems: Bass has no file.
        #expect(result.stems.count == 3)
        #expect(!result.stems.contains { $0.name == "Bass" })
    }

    // MARK: - Leg 2: through the DIALOG, at a non-default format

    @Test("the dialog's preview IS the folder afterwards — AIFF, 16-bit, both siblings")
    func dialogPreviewEqualsTheFolder() async throws {
        let engine = AudioEngine()
        defer { withExtendedLifetime(engine) {} }
        let tracks = try fixtureTracks()
        let store = makeStore(tracks: tracks, engine: engine)
        let dir = try freshDirectory("dialog")

        let model = ExportDialogModel()
        model.prepare(tracks: store.tracks)
        model.mode = .stems
        model.includeMixdown = true
        model.includeMasteredMixdown = true
        model.setContainer(.aiff)
        model.setBitDepth(16)

        // The list the user is looking at, captured BEFORE the render.
        let previewed = model.plannedStemFiles
        #expect(previewed == ["00 Mixdown.aiff", "00 Mastered Mix.aiff",
                              "01 Keys.aiff", "02 Verb.aiff", "03 Keys 2.aiff"])

        // The SAME method the sheet's button and `debug.exportDialog
        // {exportToDirectory}` call.
        let ok = await model.exportStems(store: store, toDirectory: dir.path)
        #expect(ok, "export failed: \(model.lastError ?? "no error recorded")")
        let outcome = try #require(model.lastStemExport)

        #expect(try contents(of: outcome.directory) == Set(previewed),
                "the card promised \(previewed) and the folder holds something else")
        // The result strip names what LANDED (read off the result's paths) and
        // it agrees with the promise on the success path.
        #expect(outcome.fileNames == previewed)
        #expect(outcome.formatLabel == "16-bit integer AIFF")
        // No master chain in this fixture, so nothing was left off the stems.
        #expect(outcome.masterChainExcluded == false)
        #expect(outcome.limitedByCeiling == false)
        #expect(outcome.durationSeconds > 0)
    }

    // MARK: - Leg 3: the toggles reach the SET, not just the echo

    @Test("turning the siblings off removes exactly those two files, and nothing else moves")
    func siblingsAreTheOnlyDifference() async throws {
        let engine = AudioEngine()
        defer { withExtendedLifetime(engine) {} }
        let tracks = try fixtureTracks()
        let store = makeStore(tracks: tracks, engine: engine)
        let dir = try freshDirectory("nosiblings")

        let model = ExportDialogModel()
        model.prepare(tracks: store.tracks)
        model.mode = .stems
        // Both siblings OFF — the shipped `renderStems` default.
        let previewed = model.plannedStemFiles
        #expect(previewed == ["01 Keys.wav", "02 Verb.wav", "03 Keys 2.wav"])

        #expect(await model.exportStems(store: store, toDirectory: dir.path))
        let outcome = try #require(model.lastStemExport)
        #expect(try contents(of: outcome.directory) == Set(previewed))
        // The stems' own names are UNCHANGED by the siblings' absence — the two
        // "00 …" files are additions, never a renumbering.
        #expect(outcome.fileNames == ["01 Keys.wav", "02 Verb.wav", "03 Keys 2.wav"])
    }
}
