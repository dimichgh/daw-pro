import Foundation
import Testing
@testable import DAWCore

/// m31-g — `.sf3` SoundFonts were dropped by auto-discovery in SILENCE: no
/// error, no log, no listing, so a file that WAS in the scan directory and a
/// file that was not produced identical output. These tests plant real files in
/// a real temp scan directory and assert the file is REPORTED. They are
/// deliberately behavioural: none of them reads the filter array or any other
/// source shape.
///
/// ⛔ The second half of the suite is the part that keeps the fix from being a
/// downgrade: an unsupported entry is LISTED but must never become a playable
/// selection. Trading a silent scan for silent playback would be worse than the
/// original defect.
///
/// ⭐ Every "it is absent" assertion here is paired with a positive control in
/// the same test — a file of a format we KNOW is listed — so a probe that finds
/// nothing because it is broken cannot pass as a probe that found nothing.
@Suite("Sound banks — unsupported formats are reported, never playable (m31-g)")
struct SoundBankUnsupportedFormatTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundbank-sf3-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Plants a file with real bytes. `scan()` never opens a bank file — it
    /// classifies by extension — so dummy bytes are a legitimate probe here,
    /// not a shortcut. (A test that needed real SF3 container bytes would be
    /// testing a decoder, which this tier deliberately does not build.)
    @discardableResult
    private func plant(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("not-a-real-bank-just-bytes".utf8).write(to: url)
        return url
    }

    // MARK: - The defect itself

    // 1. THE REGRESSION GATE. Before m31-g this test's `sf3` lookup returned
    //    nil while the file sat right there in the directory.
    @Test("scan REPORTS a .sf3 planted in a scan directory instead of swallowing it")
    func sf3IsReportedNotSwallowed() throws {
        let dir = tempDir()
        try plant("FluidR3Mono_GM.sf3", in: dir)
        try plant("Vintage.sf2", in: dir)   // positive control: a format we know lists

        let banks = SoundBankLibrary(libraryDirectory: dir, scanDirectories: [dir])
            .scan().filter { !$0.builtin }

        // Positive control first: if this fails, the probe is broken and the
        // sf3 assertion below proves nothing.
        let sf2 = banks.first { $0.name == "Vintage" }
        #expect(sf2 != nil)
        #expect(sf2?.format == "sf2")
        #expect(sf2?.supported == true)
        #expect(sf2?.unsupportedReason == nil)

        let sf3 = banks.first { $0.name == "FluidR3Mono_GM" }
        #expect(sf3 != nil, "a .sf3 in a scan directory must be listed, not dropped")
        #expect(sf3?.format == "sf3")
        #expect(sf3?.supported == false)
        #expect(sf3?.path.hasSuffix("FluidR3Mono_GM.sf3") == true)
        #expect((sf3?.sizeBytes ?? 0) > 0)
    }

    // 2. The string is user-facing: it must say what to DO, not only what is
    //    wrong. "export a .sf2" is the actionable half.
    @Test("the .sf3 reason names the format and tells the user what to do")
    func sf3ReasonIsActionable() throws {
        let dir = tempDir()
        try plant("MS Basic.sf3", in: dir)

        let banks = SoundBankLibrary(libraryDirectory: dir, scanDirectories: [dir]).scan()
        guard let reason = banks.first(where: { $0.name == "MS Basic" })?.unsupportedReason else {
            Issue.record("no unsupportedReason on the listed .sf3")
            return
        }
        #expect(!reason.isEmpty)
        #expect(reason.contains(".sf2"))          // the way out
        #expect(reason.lowercased().contains("sf3"))
    }

    // 3. Extension matching is case-insensitive, like the sf2/dls filter it
    //    joined.
    @Test("scan reports an uppercase .SF3 too")
    func uppercaseSF3IsReported() throws {
        let dir = tempDir()
        try plant("Shouty.SF3", in: dir)

        let banks = SoundBankLibrary(libraryDirectory: dir, scanDirectories: [dir]).scan()
        let entry = banks.first { $0.name == "Shouty" }
        #expect(entry != nil)
        #expect(entry?.format == "sf3")           // normalised, lowercased
        #expect(entry?.supported == false)
    }

    // 4. THE FORMAT LIE THIS FIX COULD HAVE INTRODUCED. `bankInfo` used to
    //    read `ext == "sf2" ? "sf2" : "dls"`; left alone, an .sf3 would have
    //    surfaced labelled "dls" — loadable-looking, which is worse than
    //    invisible. Pin the real extension for BOTH supported formats too, so
    //    a future "simplification" back to the ternary reddens.
    @Test("format is always the file's real extension, never a fallback guess")
    func formatIsTheRealExtension() throws {
        let dir = tempDir()
        try plant("A.sf2", in: dir)
        try plant("B.dls", in: dir)
        try plant("C.sf3", in: dir)

        let banks = SoundBankLibrary(libraryDirectory: dir, scanDirectories: [dir])
            .scan().filter { !$0.builtin }
        #expect(banks.map(\.format) == ["sf2", "dls", "sf3"])  // alphabetical by filename
        #expect(banks.map(\.supported) == [true, true, false])
    }

    // 5. SCOPE FENCE. Only formats we have something to SAY about are
    //    surfaced. The two standard macOS bank folders are shared with other
    //    apps; listing every stray file there would be noise, not diagnosis.
    @Test("unrelated files are still excluded — only known formats are listed")
    func unrelatedFilesStayExcluded() throws {
        let dir = tempDir()
        try plant("readme.txt", in: dir)
        try plant("loop.wav", in: dir)
        try plant("Preset.fxp", in: dir)
        try plant("Real.sf3", in: dir)   // positive control: a listed entry exists

        let banks = SoundBankLibrary(libraryDirectory: dir, scanDirectories: [dir])
            .scan().filter { !$0.builtin }
        #expect(banks.count == 1, "expected only the .sf3; got \(banks.map(\.name))")
        #expect(banks.first?.name == "Real")
    }

    // MARK: - Listed must not mean playable

    // 6. Explicit import keeps its honest refusal — that path was never the
    //    defect, and this pins that surfacing the format did not loosen it.
    @Test("importBank still refuses a .sf3, copying nothing")
    func importStillRefusesSF3() throws {
        let libraryDir = tempDir()
        let sourceDir = tempDir()
        let sf3 = try plant("FluidR3Mono_GM.sf3", in: sourceDir)
        let sf2 = try plant("Fine.sf2", in: sourceDir)

        let library = SoundBankLibrary(libraryDirectory: libraryDir, scanDirectories: [libraryDir])

        let error = { () -> ProjectError? in
            do { _ = try library.importBank(from: sf3); return nil }
            catch let error as ProjectError { return error }
            catch { return nil }
        }()
        guard case .importFailed(let reason)? = error else {
            Issue.record("expected importFailed for a .sf3, got \(String(describing: error))")
            return
        }
        #expect(reason == "sound bank must be a .sf2 or .dls file — got FluidR3Mono_GM.sf3")

        // Positive control: the same call shape SUCCEEDS for a .sf2, so the
        // throw above is about the format and not about the harness.
        #expect(throws: Never.self) { try library.importBank(from: sf2) }
        let landed = (try? FileManager.default.contentsOfDirectory(atPath: libraryDir.path)) ?? []
        #expect(landed == ["Fine.sf2"], "the .sf3 must not have been copied; got \(landed)")
    }

    // 7. ⛔ THE ONE THAT MATTERS MOST: a listed .sf3 must not be selectable as
    //    an instrument. If this ever passes-through, we have traded a silent
    //    scan for a silent instrument, which is strictly worse.
    @Test("a listed .sf3 can NEVER be set as a track instrument")
    @MainActor
    func sf3IsNotSelectable() async throws {
        let dir = tempDir()
        let sf3 = try plant("FluidR3Mono_GM.sf3", in: dir)
        let sf2 = try plant("Fine.sf2", in: dir)

        let store = ProjectStore()
        store.soundBankLibrary = SoundBankLibrary(libraryDirectory: dir, scanDirectories: [dir])

        // It IS discoverable — the premise of the test.
        let listed = store.availableSoundBanks().first { $0.format == "sf3" }
        #expect(listed != nil)

        let track = store.addTrack(name: "Sax", kind: .instrument)
        let before = store.tracks.first { $0.id == track.id }?.instrument

        #expect(throws: ProjectError.self) {
            try store.setInstrument(id: track.id, soundBank: SoundBankConfig(
                source: .file(path: sf3.path), program: 65, displayName: "Alto Sax"))
        }
        // Nothing landed — the guard runs BEFORE the edit.
        #expect(store.tracks.first { $0.id == track.id }?.instrument == before)

        // Positive control: the identical call with a .sf2 is ACCEPTED, so the
        // throw above is the format gate and not a broken fixture.
        #expect(throws: Never.self) {
            try store.setInstrument(id: track.id, soundBank: SoundBankConfig(
                source: .file(path: sf2.path), program: 65, displayName: "Alto Sax"))
        }
        #expect(store.tracks.first { $0.id == track.id }?.instrument != before)
    }

    // 8. The predicates the three independent gates share.
    @Test("format predicates: sf2/dls supported, sf3 discoverable-not-supported, txt neither")
    func predicates() {
        #expect(SoundBankLibrary.isSupportedExtension("sf2"))
        #expect(SoundBankLibrary.isSupportedExtension("DLS"))
        #expect(!SoundBankLibrary.isSupportedExtension("sf3"))
        #expect(SoundBankLibrary.isDiscoverableExtension("sf3"))
        #expect(SoundBankLibrary.isDiscoverableExtension("Sf2"))
        #expect(!SoundBankLibrary.isDiscoverableExtension("txt"))
    }

    // 9. Wire/persistence additivity: a payload written before this field
    //    existed must decode as SUPPORTED, not as an unsupported blank.
    @Test("SoundBankInfo decodes a pre-m31-g payload (no unsupportedReason) as supported")
    func decodesLegacyPayloadAsSupported() throws {
        let legacy = """
        {"source":"/banks/Vintage.sf2","name":"Vintage","path":"/banks/Vintage.sf2",
         "format":"sf2","builtin":false,"sizeBytes":42}
        """
        let info = try JSONDecoder().decode(SoundBankInfo.self, from: Data(legacy.utf8))
        #expect(info.unsupportedReason == nil)
        #expect(info.supported)
    }
}
