import Foundation
import Testing
@testable import DAWCore

// m39-tpl-5 — `TemplateLibrary`: the listing, remove, import and export
// (docs/design/2026-09-27-multi-instrument-templates.md §6.1, §7.2, §7.3). NO
// `@MainActor`: the library is file work over an INJECTED root, a fresh temp
// folder per test — never the user's real Application Support folder.
//
// "Changes nothing" is asserted on BYTES: every file under the library root and
// at each export path, before and after each refusal.

@Suite("m39-tpl-5: TemplateLibrary — list, remove, import, export")
struct TemplateLibraryTests {
    // MARK: - Helpers

    func tpl5Library() -> TemplateLibrary {
        TemplateLibrary(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("tpl5-library-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Templates", isDirectory: true))
    }

    func tpl5Scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tpl5-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every file under `folder` (relative path → bytes); a missing folder is empty.
    func tpl5Files(_ folder: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return files }
        for case let relative as String in walker {
            let url = folder.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                files[relative] = (try? Data(contentsOf: url)) ?? Data("<unreadable>".utf8)
            } else {
                files[relative + "/"] = Data()
            }
        }
        return files
    }

    func tpl5Put(_ data: Data, _ name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name))
    }

    func tpl5BuiltIn(_ id: String) throws -> TrackSetTemplate {
        try #require(BuiltInTemplateCatalog.load().templates.first { $0.id == id }).template
    }

    /// A valid saved-template file: a built-in's canonical bytes under `id`.
    func tpl5File(id: String, from builtIn: String = "jazz-combo",
                  name: String? = nil) throws -> Data {
        var template = try tpl5BuiltIn(builtIn)
        template.id = id
        if let name { template.name = name }
        return try TemplateCapture.canonicalJSON(template)
    }

    func tpl5Error(_ body: () throws -> Void) -> (any Error)? {
        do { try body(); return nil } catch { return error }
    }

    // MARK: - The listing

    @Test("The listing is the built-ins in catalog order, then saved files by file name")
    func listMergesBuiltInsAndSavedFiles() throws {
        let library = tpl5Library()
        try tpl5Put(try tpl5File(id: "user-b", name: "B Band"), "b.dawtemplate", in: library.root)
        try tpl5Put(try tpl5File(id: "user-a", name: "A Band"), "a.dawtemplate", in: library.root)
        try tpl5Put(Data("not a template".utf8), "notes.txt", in: library.root)
        let listing = library.list()
        #expect(listing.templates.map(\.id) == BuiltInTemplateCatalog.ids + ["user-a", "user-b"])
        #expect(listing.templates.prefix(10).allSatisfy { $0.source == .builtIn })
        #expect(listing.templates.suffix(2).map(\.source) == [.saved, .saved])
        #expect(listing.templates.suffix(2).map(\.fileName) == ["a.dawtemplate", "b.dawtemplate"])
        #expect(listing.entry(id: "user-a")?.name == "A Band")
        // Only `.dawtemplate` files are template files; `notes.txt` is not one.
        #expect(listing.unreadable.isEmpty, "\(listing.unreadable)")
    }

    @Test("A library folder that doesn't exist yet holds no saved templates, and nothing is unreadable")
    func missingRootListsOnlyBuiltIns() {
        let library = tpl5Library()
        let listing = library.list()
        #expect(listing.templates.map(\.id) == BuiltInTemplateCatalog.ids)
        #expect(listing.unreadable.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.root.path), "listing must not create it")
    }

    @Test("Every file that can't be read is LISTED with its reason, never skipped (§7.3)")
    func unreadableFilesAreListed() throws {
        let library = tpl5Library()
        try tpl5Put(Data("{ \"format\": \"dawpro.template\", ".utf8), "broken.dawtemplate", in: library.root)
        try tpl5Put(Data("{\"format\": \"something.else\"}".utf8), "other.dawtemplate", in: library.root)
        try tpl5Put(Data(count: TrackSetTemplateCodec.maxFileBytes + 1), "huge.dawtemplate",
                    in: library.root)
        try FileManager.default.createDirectory(
            at: library.root.appendingPathComponent("folder.dawtemplate"),
            withIntermediateDirectories: true)
        try tpl5Put(try tpl5File(id: "user-dup", name: "First"), "dup-1.dawtemplate", in: library.root)
        try tpl5Put(try tpl5File(id: "user-dup", name: "Second"), "dup-2.dawtemplate", in: library.root)
        try tpl5Put(try tpl5File(id: "lofi-chill", name: "Not The Built-in"), "lofi.dawtemplate",
                    in: library.root)
        let listing = library.list()
        let saved = listing.templates.filter { $0.source == .saved }
        #expect(saved.map(\.fileName) == ["dup-1.dawtemplate"])
        #expect(saved.first?.name == "First")
        let byFile = Dictionary(listing.unreadable.map { ($0.file, $0.message) },
                                uniquingKeysWith: { first, _ in first })
        #expect(listing.unreadable.map(\.file)
            == ["broken.dawtemplate", "dup-2.dawtemplate", "folder.dawtemplate", "huge.dawtemplate",
                "lofi.dawtemplate", "other.dawtemplate"])
        #expect(byFile["dup-2.dawtemplate"]
            == "Another template already uses this id. Import it again to give it a new one.")
        #expect(byFile["lofi.dawtemplate"] == TemplateLibrary.duplicateIDMessage)
        #expect(byFile["huge.dawtemplate"]?.contains("at most 2097152 bytes (2 MB)") == true)
        #expect(byFile["broken.dawtemplate"]?.contains("not valid JSON") == true)
        #expect(byFile["other.dawtemplate"]?.contains("isn't a DAW Pro template") == true)
        #expect(byFile["folder.dawtemplate"]?.contains("is a folder") == true)
        #expect(listing.unreadable.allSatisfy { $0.source == .saved })
        // The built-in is still the one on offer.
        #expect(listing.entry(id: "lofi-chill")?.source == .builtIn)
    }

    @Test("A library root that is a FILE is reported, not silently treated as empty")
    func rootThatIsAFileIsReported() throws {
        let library = tpl5Library()
        try tpl5Put(Data("x".utf8), "Templates", in: library.root.deletingLastPathComponent())
        let listing = library.list()
        #expect(listing.unreadable.map(\.file) == ["Templates"])
        #expect(listing.templates.count == BuiltInTemplateCatalog.ids.count)
    }

    // MARK: - Remove

    @Test("Remove deletes a saved file; a built-in is refused in the design's words; refusals change no file")
    func removeRules() throws {
        let library = tpl5Library()
        try tpl5Put(try tpl5File(id: "user-keep"), "keep.dawtemplate", in: library.root)
        try tpl5Put(try tpl5File(id: "user-gone"), "gone.dawtemplate", in: library.root)
        let before = tpl5Files(library.root)
        let builtIn = tpl5Error { try library.remove(id: "pop-band") }
        #expect(builtIn as? TemplateLibraryError == .builtInCantBeRemoved)
        #expect((builtIn as? LocalizedError)?.errorDescription == "Built-in templates can't be removed.")
        #expect(tpl5Error { try library.remove(id: "user-nope") } as? TemplateLibraryError
            == .unknownTemplate(id: "user-nope"))
        #expect(tpl5Files(library.root) == before)
        #expect(try library.remove(id: "user-gone") == "user-gone")
        #expect(Array(tpl5Files(library.root).keys) == ["keep.dawtemplate"])
        #expect(library.list().entry(id: "user-gone") == nil)
    }

    // MARK: - Import

    @Test("Import keeps a free id and copies the bytes as they are")
    func importKeepsAFreeID() throws {
        let library = tpl5Library()
        let scratch = try tpl5Scratch()
        let data = try tpl5File(id: "my-band", name: "My Band")
        try tpl5Put(data, "my.dawtemplate", in: scratch)
        let result = try library.importTemplate(from: scratch.appendingPathComponent("my.dawtemplate").path)
        #expect(result.id == "my-band")
        #expect(result.name == "My Band")
        #expect(result.warnings.isEmpty)
        #expect(tpl5Files(library.root) == ["my-band.dawtemplate": data])
        #expect(library.list().entry(id: "my-band")?.source == .saved)
    }

    @Test("Import gives a built-in's or a taken id a fresh user- id, and says so")
    func importReplacesATakenID() throws {
        let library = tpl5Library()
        let scratch = try tpl5Scratch()
        let exported = scratch.appendingPathComponent("lofi.dawtemplate")
        _ = try library.export(id: "lofi-chill", to: exported.path)
        let first = try library.importTemplate(from: exported.path)
        #expect(first.id.hasPrefix("user-"))
        #expect(first.id.count == 41)
        #expect(first.warnings == [TemplateWarning(
            code: .idReplaced, path: "id",
            message: "Another template already uses the id 'lofi-chill', so this one was added as "
                + "'\(first.id)'.")])
        let copy = try Data(contentsOf: library.root.appendingPathComponent(first.fileName))
        var expected = try TemplateCapture.canonical(try tpl5BuiltIn("lofi-chill"))
        expected.id = first.id
        #expect(try TrackSetTemplateCodec.decode(copy, origin: .file).template == expected)
        // Its own id is now taken too: importing again mints another.
        try tpl5Put(try tpl5File(id: "my-band"), "a.dawtemplate", in: scratch)
        let kept = try library.importTemplate(from: scratch.appendingPathComponent("a.dawtemplate").path)
        let again = try library.importTemplate(from: scratch.appendingPathComponent("a.dawtemplate").path)
        #expect(kept.id == "my-band")
        #expect(again.id != "my-band")
        #expect(again.id.hasPrefix("user-"))
        #expect(library.list().templates.filter { $0.source == .saved }.count == 3)
    }

    @Test("Import gives a file with NO id a fresh user- id, and says so; everything else is read strictly")
    func importGivesAMissingIDOne() throws {
        let library = tpl5Library()
        let scratch = try tpl5Scratch()
        let text = String(decoding: try tpl5File(id: "jazz-combo"), as: UTF8.self)
        let noID = text.replacingOccurrences(of: "  \"id\": \"jazz-combo\",\n", with: "")
        #expect(noID != text, "positive control: the id line was removed")
        try tpl5Put(Data(noID.utf8), "no-id.dawtemplate", in: scratch)
        // Listed as unreadable while it sits in a library folder…
        try tpl5Put(Data(noID.utf8), "no-id.dawtemplate", in: library.root)
        #expect(library.list().unreadable.map(\.file) == ["no-id.dawtemplate"])
        try FileManager.default.removeItem(at: library.root.appendingPathComponent("no-id.dawtemplate"))
        // …and given an id when imported.
        let result = try library.importTemplate(from: scratch.appendingPathComponent("no-id.dawtemplate").path)
        #expect(result.id.hasPrefix("user-"))
        #expect(result.warnings == [TemplateWarning(
            code: .idReplaced, path: "id",
            message: "This template had no id, so it was added as '\(result.id)'.")])
        var expected = try TemplateCapture.canonical(try tpl5BuiltIn("jazz-combo"))
        expected.id = result.id
        #expect(library.list().entry(id: result.id)?.template == expected)
    }

    @Test("Import keeps what a newer version wrote, even under a fresh id")
    func importKeepsANewerVersionsKeys() throws {
        let library = tpl5Library()
        let scratch = try tpl5Scratch()
        var text = String(decoding: try tpl5File(id: "lofi-chill"), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"formatVersion\": 1,",
                                         with: "\"formatVersion\": 2,\n  \"futureKey\": 7,")
        try tpl5Put(Data(text.utf8), "future.dawtemplate", in: scratch)
        let result = try library.importTemplate(from: scratch.appendingPathComponent("future.dawtemplate").path)
        #expect(result.warnings.map(\.code) == [.unknownKeySkipped, .idReplaced])
        let copy = String(decoding: try Data(contentsOf: library.root.appendingPathComponent(result.fileName)),
                          as: UTF8.self)
        #expect(copy.contains("\"futureKey\": 7"))
        #expect(copy.contains("\"formatVersion\": 2"))
        #expect(copy.contains("\"id\": \"\(result.id)\""))
    }

    @Test("Import refuses a missing file, a relative path, a file over 2 MB, a non-template and a broken template — writing nothing")
    func importRefusals() throws {
        let library = tpl5Library()
        let scratch = try tpl5Scratch()
        try tpl5Put(Data(count: TrackSetTemplateCodec.maxFileBytes + 1), "huge.dawtemplate", in: scratch)
        try tpl5Put(Data("[1, 2]".utf8), "list.dawtemplate", in: scratch)
        var broken = String(decoding: try tpl5File(id: "user-x"), as: UTF8.self)
        broken = broken.replacingOccurrences(of: "\"bus\": \"club-room\"", with: "\"bus\": \"nowhere\"")
        try tpl5Put(Data(broken.utf8), "broken.dawtemplate", in: scratch)
        #expect(broken.contains("\"bus\": \"nowhere\""), "positive control: the edit landed")

        let missing = tpl5Error { _ = try library.importTemplate(from: scratch.appendingPathComponent("no.dawtemplate").path) }
        #expect(missing as? TemplateLibraryError
            == .fileNotFound(path: scratch.appendingPathComponent("no.dawtemplate").path))
        #expect(tpl5Error { _ = try library.importTemplate(from: "relative/x.dawtemplate") }
            as? TemplateLibraryError == .pathNotAbsolute(path: "relative/x.dawtemplate"))
        #expect((tpl5Error { _ = try library.importTemplate(from: scratch.appendingPathComponent("huge.dawtemplate").path) }
            as? TemplateRefusal)?.code == .tooLarge)
        #expect((tpl5Error { _ = try library.importTemplate(from: scratch.appendingPathComponent("list.dawtemplate").path) }
            as? TemplateRefusal)?.code == .notATemplate)
        let refused = tpl5Error { _ = try library.importTemplate(from: scratch.appendingPathComponent("broken.dawtemplate").path) }
        #expect((refused as? TemplateRefusal)?.message.contains("there is no bus with the key 'nowhere'") == true)
        #expect(!FileManager.default.fileExists(atPath: library.root.path), "nothing was written")
    }

    // MARK: - Export

    @Test("Export writes the canonical form; an existing file needs overwrite; bad ids and paths are refused")
    func exportRules() throws {
        let library = tpl5Library()
        let scratch = try tpl5Scratch()
        let out = scratch.appendingPathComponent("out.dawtemplate")
        let result = try library.export(id: "house-club", to: out.path)
        let expected = try TemplateCapture.canonicalJSON(try tpl5BuiltIn("house-club"))
        #expect(try Data(contentsOf: out) == expected)
        #expect(result == TemplateLibrary.ExportResult(path: out.path, bytes: expected.count))
        #expect(try TrackSetTemplateCodec.decode(expected, origin: .file).template
            == TemplateCapture.canonical(try tpl5BuiltIn("house-club")))

        let before = tpl5Files(scratch)
        #expect(tpl5Error { _ = try library.export(id: "pop-band", to: out.path) } as? TemplateLibraryError
            == .fileExists(path: out.path))
        #expect(tpl5Files(scratch) == before)
        _ = try library.export(id: "pop-band", to: out.path, overwrite: true)
        #expect(try Data(contentsOf: out) == TemplateCapture.canonicalJSON(try tpl5BuiltIn("pop-band")))

        let after = tpl5Files(scratch)
        #expect(tpl5Error { _ = try library.export(id: "user-nope", to: out.path, overwrite: true) }
            as? TemplateLibraryError == .unknownTemplate(id: "user-nope"))
        #expect(tpl5Error { _ = try library.export(id: "pop-band", to: "x.dawtemplate") }
            as? TemplateLibraryError == .pathNotAbsolute(path: "x.dawtemplate"))
        let nowhere = scratch.appendingPathComponent("no-such-folder/x.dawtemplate")
        #expect(tpl5Error { _ = try library.export(id: "pop-band", to: nowhere.path) }
            as? TemplateLibraryError == .folderMissing(path: nowhere.deletingLastPathComponent().path))
        #expect(tpl5Error { _ = try library.export(id: "pop-band", to: scratch.path, overwrite: true) }
            as? TemplateLibraryError == .notAFile(path: scratch.path))
        #expect(tpl5Files(scratch) == after)
        #expect(!FileManager.default.fileExists(atPath: library.root.path), "export never writes the library")
    }

    // MARK: - Where the library lives

    @Test("The standard library is redirected to a temp folder under tests, never the real one")
    func standardLibraryIsRedirectedUnderTests() {
        #expect(TestEnvironment.isRunningTests, "positive control: this IS a test process")
        let root = TemplateLibrary.standard.root.standardizedFileURL
        #expect(root != AppDirectories.applicationSupport(.templates).standardizedFileURL)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
        #expect(root.path.hasSuffix("DAWPro/Templates"))
        #expect(TemplateLibrary.standard == TemplateLibrary.standard, "one root per process")
    }

    @Test("The templates category lives beside the others, so DAWPRO_PROFILE_ROOT moves it too")
    func templatesCategoryFollowsTheProfileRoot() {
        let base = URL(fileURLWithPath: "/private/tmp/tpl5-profile-base", isDirectory: true)
        #expect(AppDirectories.applicationSupport(.templates, systemBase: base).path
            == "/private/tmp/tpl5-profile-base/DAWPro/Templates")
        #expect(AppDirectories.applicationSupport(.templates).deletingLastPathComponent()
            == AppDirectories.applicationSupport(.soundBanks).deletingLastPathComponent())
    }
}
