import Foundation
import Testing
@testable import DAWCore

/// m10-n-2 SoundBankLibrary discovery/import: scan order (GM first), dedupe,
/// alphabetical within a dir, empty-dir tolerance, and copy-into-central-library
/// import (collision uniquify, bad-extension/missing errors, source preserved).
/// Machine bank dirs are EMPTY (§2.3) so every test injects temp dirs.
@Suite("Sound bank library — scan/import (m10-n-2)")
struct SoundBankLibraryTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundbank-lib-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeBank(_ name: String, in dir: URL, bytes: String = "bank-bytes") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private var gmPresent: Bool {
        FileManager.default.fileExists(atPath: SoundBankLibrary.systemGMBankPath)
    }

    // MARK: - scan

    // 1.
    @Test("scan lists GM first (builtin), then each dir's *.sf2/*.dls alphabetically; non-banks skipped")
    func scanOrdering() throws {
        let dir = tempDir()
        try writeBank("Zebra.sf2", in: dir)
        try writeBank("Alpha.dls", in: dir)
        try writeBank("notes.txt", in: dir)  // not a bank — excluded

        let library = SoundBankLibrary(libraryDirectory: dir, scanDirectories: [dir])
        let banks = library.scan()

        let userBanks = banks.filter { !$0.builtin }
        #expect(userBanks.map(\.name) == ["Alpha", "Zebra"])  // alphabetical, txt excluded
        #expect(userBanks.map(\.format) == ["dls", "sf2"])
        #expect(userBanks.allSatisfy { $0.sizeBytes > 0 })
        #expect(userBanks.allSatisfy {
            if case .file = $0.source { return true } else { return false }
        })

        if gmPresent {
            #expect(banks.first?.source == .generalMIDI)
            #expect(banks.first?.builtin == true)
            #expect(banks.first?.format == "dls")
            #expect(banks.first?.name == "General MIDI")
            #expect(banks.first?.path == SoundBankLibrary.systemGMBankPath)
        }
    }

    // 2.
    @Test("scan dedupes a bank reachable through two scan dirs (standardized path)")
    func scanDedupes() throws {
        let dir = tempDir()
        try writeBank("Once.sf2", in: dir)
        // The same dir listed twice — the bank must appear exactly once.
        let library = SoundBankLibrary(libraryDirectory: dir, scanDirectories: [dir, dir])
        let named = library.scan().filter { $0.name == "Once" }
        #expect(named.count == 1)
    }

    // 3.
    @Test("scan tolerates an absent/unreadable scan dir (skipped silently, never throws)")
    func scanSkipsMissingDir() throws {
        let real = tempDir()
        try writeBank("Real.sf2", in: real)
        let missing = tempDir().appendingPathComponent("does-not-exist", isDirectory: true)
        let library = SoundBankLibrary(libraryDirectory: real, scanDirectories: [missing, real])
        let userBanks = library.scan().filter { !$0.builtin }
        #expect(userBanks.map(\.name) == ["Real"])
    }

    // MARK: - importBank

    // 4.
    @Test("import copies a .sf2 into the central library and reports its info; the source is untouched")
    func importCopiesIntoLibrary() throws {
        let libraryDir = tempDir()
        let sourceDir = tempDir()
        let source = try writeBank("Strings.sf2", in: sourceDir)

        let library = SoundBankLibrary(libraryDirectory: libraryDir, scanDirectories: [libraryDir])
        let info = try library.importBank(from: source)

        #expect(info.name == "Strings")
        #expect(info.format == "sf2")
        #expect(info.builtin == false)
        #expect(info.sizeBytes > 0)
        // Landed in the central library.
        #expect(info.path == libraryDir.appendingPathComponent("Strings.sf2")
            .standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: info.path))
        // Copy, NEVER move: the source still exists.
        #expect(FileManager.default.fileExists(atPath: source.path))
        // The imported bank now appears in a scan of the library.
        #expect(library.scan().contains { $0.name == "Strings" && !$0.builtin })
    }

    // 5.
    @Test("import uniquifies a name collision (ProjectBundle.uniqueName), keeping both banks")
    func importUniquifiesCollision() throws {
        let libraryDir = tempDir()
        let dirA = tempDir()
        let dirB = tempDir()
        let first = try writeBank("Vintage.sf2", in: dirA, bytes: "first")
        let second = try writeBank("Vintage.sf2", in: dirB, bytes: "second-different")

        let library = SoundBankLibrary(libraryDirectory: libraryDir, scanDirectories: [libraryDir])
        let infoA = try library.importBank(from: first)
        let infoB = try library.importBank(from: second)

        #expect(infoA.name == "Vintage")
        #expect(infoB.name == "Vintage-2")  // collision suffix
        #expect(infoA.path != infoB.path)
        #expect(FileManager.default.fileExists(atPath: infoA.path))
        #expect(FileManager.default.fileExists(atPath: infoB.path))
    }

    // 6.
    @Test("import rejects a wrong extension with importFailed, copying nothing")
    func importRejectsBadExtension() throws {
        let libraryDir = tempDir()
        let sourceDir = tempDir()
        let bad = try writeBank("readme.txt", in: sourceDir)

        let library = SoundBankLibrary(libraryDirectory: libraryDir, scanDirectories: [libraryDir])
        #expect(throws: ProjectError.self) { try library.importBank(from: bad) }
        // Nothing landed.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: libraryDir.path)) ?? []
        #expect(contents.isEmpty)
    }

    // 7.
    @Test("import of a missing file throws importFailed")
    func importMissingThrows() throws {
        let libraryDir = tempDir()
        let library = SoundBankLibrary(libraryDirectory: libraryDir, scanDirectories: [libraryDir])
        let error = { () -> ProjectError? in
            do { _ = try library.importBank(from: URL(fileURLWithPath: "/nope/Ghost.sf2")); return nil }
            catch let error as ProjectError { return error }
            catch { return nil }
        }()
        guard case .importFailed(let reason)? = error else {
            Issue.record("expected importFailed, got \(String(describing: error))")
            return
        }
        #expect(reason == "no sound bank file at /nope/Ghost.sf2")
    }
}
