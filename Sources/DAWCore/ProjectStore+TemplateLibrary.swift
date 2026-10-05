import Foundation

// m39-tpl-5 — SAVED TEMPLATES ON DISK: save, remove, import, export, and the
// library listing (docs/design/2026-09-27-multi-instrument-templates.md §6.1,
// §7.2, §7.3, §4.8).
//
// `TemplateLibrary` is a VALUE: a folder of `.dawtemplate` files, plus the
// built-ins. Everything here is file work, nonisolated, testable without the
// main actor; only `ProjectStore.saveTemplate` needs the live song (it captures
// the chosen tracks, with each hosted Audio Unit's CURRENT sound).
//
// ⭐ FILE OPERATIONS MAKE NO UNDO ENTRY. They change files, not the song (the
// `instrument.importSoundBank` precedent): nothing below calls `performEdit`, and
// nothing below mutates the store.
//
// ⭐ NOTHING IS SILENTLY SKIPPED (§7.3). A file in the folder that cannot be read
// is listed under `unreadable` with the reason; two files with the same id: the
// first by file name is offered, the other is listed as unreadable with "Another
// template already uses this id. Import it again to give it a new one."
//
// ⭐ A SAVED FILE ALWAYS OPENS. `saveTemplate` writes nothing until the exact
// bytes it is about to write have been read back by the real codec (strictly, as
// a file), compared with what was captured, and planned by the real builder. A
// setup that would not read back exactly is refused with a sentence, never
// written half-way. Since m39-tpl-5b a Sampler with its own sound files is saved
// too: zones by absolute path, no zone ids (each apply gets new ones).
//
// ⭐ THE ROOT IS INJECTED. `TemplateLibrary.standard` is
// `AppDirectories.applicationSupport(.templates)` — so staging's
// `DAWPRO_PROFILE_ROOT` moves it with every other category — EXCEPT under a Swift
// test process, where it is a per-process temp root (the
// `generationImportsDefault()` precedent: an opt-in redirection once let tests
// spill 1.8 GB into a user's real profile). A test that forgets to inject a root
// still cannot touch the real folder.
//
// TODO(TPL-6): the wire verbs `template.list` / `template.save` / `template.remove` /
// `template.import` / `template.export` in Sources/DAWControl/Commands.swift call the
// `ProjectStore` methods at the bottom of this file (design §6.1, §6.3).
// TODO(TPL-7): MCP tools `template_list`, `template_save`, `template_remove`,
// `template_import`, `template_export` in mcp-server/src/server.ts (design §6.5).

/// Where a listed template comes from.
public enum TemplateSource: String, Sendable, Equatable, Codable {
    case builtIn
    case saved
}

/// Why a library operation was refused. Nothing changed on disk or in the song.
public enum TemplateLibraryError: Error, LocalizedError, Sendable, Equatable {
    case unknownTemplate(id: String)
    case builtInCantBeRemoved
    case builtInCantBeReplaced(id: String)
    case nothingToReplace(id: String)
    case fileNotFound(path: String)
    case pathNotAbsolute(path: String)
    case folderMissing(path: String)
    case fileExists(path: String)
    case notAFile(path: String)
    case readFailed(file: String, reason: String)
    case writeFailed(file: String, reason: String)
    case notExact(path: String)

    public var errorDescription: String? {
        switch self {
        case .unknownTemplate(let id):
            return "There's no template with the id '\(id)'."
        case .builtInCantBeRemoved:
            return "Built-in templates can't be removed."
        case .builtInCantBeReplaced(let id):
            return "'\(id)' is a built-in template, and built-in templates can't be changed. Save "
                + "without replacing to keep your own copy."
        case .nothingToReplace(let id):
            return "There's no saved template with the id '\(id)' to replace."
        case .fileNotFound(let path):
            return "There's no file at \(path)."
        case .pathNotAbsolute(let path):
            return "'\(path)' isn't a full path. Give the whole path, starting with \"/\"."
        case .folderMissing(let path):
            return "The folder \(path) doesn't exist."
        case .fileExists(let path):
            return "There's already a file at \(path). Choose another name, or allow replacing it."
        case .notAFile(let path):
            return "\(path) is a folder, not a template file."
        case .readFailed(let file, let reason):
            return "Couldn't read \(file): \(reason)"
        case .writeFailed(let file, let reason):
            return "Couldn't write \(file): \(reason)"
        case .notExact(let path):
            return "This template couldn't be saved exactly (\(path) would read back differently), "
                + "so nothing was saved."
        }
    }
}

/// A folder of saved `.dawtemplate` files, plus the built-ins.
public struct TemplateLibrary: Sendable, Equatable {
    /// The folder holding the saved files. Created on first save or import.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The app's library: `<Application Support>/DAWPro/Templates/` (moved by
    /// `DAWPRO_PROFILE_ROOT`), or a per-process temp folder under a Swift test
    /// process.
    public static var standard: TemplateLibrary {
        TemplateLibrary(root: testRoot ?? AppDirectories.applicationSupport(.templates))
    }

    /// Per-PROCESS redirected root under a detected Swift test process; nil in
    /// the app. Same path math as production with a temp base.
    static let testRoot: URL? = {
        guard TestEnvironment.isRunningTests else { return nil }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DAWPro-test-templates-\(UUID().uuidString)", isDirectory: true)
        return AppDirectories.applicationSupport(.templates, systemBase: base)
    }()

    public static var fileExtension: String { BuiltInTemplateCatalog.fileExtension }

    /// "Another template already uses this id. …" — §7.3's sentence.
    public static let duplicateIDMessage =
        "Another template already uses this id. Import it again to give it a new one."

    // MARK: - Listing

    /// One template on offer.
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let name: String
        public let source: TemplateSource
        /// The file it was read from (saved templates: inside `root`).
        public let fileName: String
        public let template: TrackSetTemplate
        /// What the codec worked around (a file from a newer version).
        public let warnings: [TemplateWarning]
    }

    /// A file that could not be offered, and why, in words a person can read.
    public struct Unreadable: Sendable, Equatable {
        public let file: String
        public let source: TemplateSource
        public let message: String
    }

    /// Built-ins first, in catalog order; then saved templates by file name.
    public struct Listing: Sendable, Equatable {
        public let templates: [Entry]
        public let unreadable: [Unreadable]

        public func entry(id: String) -> Entry? { templates.first { $0.id == id } }
    }

    /// Every template on offer, and every file that could not be read. Never
    /// throws: a problem with one file, or with the folder itself, is listed.
    public func list(builtIns: BuiltInTemplateCatalog.Listing = BuiltInTemplateCatalog.load())
        -> Listing {
        var templates: [Entry] = builtIns.templates.map { entry in
            Entry(id: entry.id, name: entry.template.name, source: .builtIn,
                  fileName: entry.fileName, template: entry.template, warnings: [])
        }
        var unreadable: [Unreadable] = builtIns.unreadable.map {
            Unreadable(file: $0.file, source: .builtIn, message: $0.message)
        }
        // Built-in ids are reserved even when a built-in failed to load.
        var taken = Set(BuiltInTemplateCatalog.ids).union(templates.map(\.id))
        let saved = savedFiles()
        if let problem = saved.problem {
            unreadable.append(Unreadable(file: root.lastPathComponent, source: .saved,
                                         message: problem))
        }
        for fileName in saved.names {
            switch read(fileName) {
            case .failure(let problem):
                unreadable.append(Unreadable(file: fileName, source: .saved,
                                             message: problem.message))
            case .success(let decoded):
                let id = decoded.template.id
                guard taken.insert(id).inserted else {
                    unreadable.append(Unreadable(file: fileName, source: .saved,
                                                 message: Self.duplicateIDMessage))
                    continue
                }
                templates.append(Entry(id: id, name: decoded.template.name, source: .saved,
                                       fileName: fileName, template: decoded.template,
                                       warnings: decoded.warnings))
            }
        }
        return Listing(templates: templates, unreadable: unreadable)
    }

    /// One template by id, built-in or saved.
    public func entry(id: String, builtIns: BuiltInTemplateCatalog.Listing =
                          BuiltInTemplateCatalog.load()) throws -> Entry {
        guard let entry = list(builtIns: builtIns).entry(id: id) else {
            throw TemplateLibraryError.unknownTemplate(id: id)
        }
        return entry
    }

    /// The `.dawtemplate` file names in `root`, sorted, or why the folder
    /// cannot be read. A folder that does not exist yet holds nothing.
    func savedFiles() -> (names: [String], problem: String?) {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return ([], nil)
        }
        guard isDirectory.boolValue else {
            return ([], "The saved-templates folder is a file, not a folder, so no saved "
                + "template can be read.")
        }
        do {
            let names = try manager.contentsOfDirectory(atPath: root.path)
                .filter { ($0 as NSString).pathExtension.lowercased() == Self.fileExtension }
                .sorted()
            return (names, nil)
        } catch {
            return ([], "The saved-templates folder can't be read: \(error.localizedDescription)")
        }
    }

    /// One file in `root`, decoded strictly as a FILE, or the reason it can't be.
    func read(_ fileName: String) -> Result<TrackSetTemplateCodec.Result, ReadProblem> {
        let url = root.appendingPathComponent(fileName)
        do {
            let data = try Self.boundedData(at: url)
            return .success(try TrackSetTemplateCodec.decode(data, origin: .file))
        } catch let refusal as TemplateRefusal {
            return .failure(ReadProblem(refusal.errorDescription ?? refusal.message))
        } catch {
            return .failure(ReadProblem((error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription))
        }
    }

    struct ReadProblem: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// The bytes of a template file, refusing a folder, a missing file, or one
    /// over the size bound BEFORE reading it.
    static func boundedData(at url: URL) throws -> Data {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw TemplateLibraryError.fileNotFound(path: url.path)
        }
        guard !isDirectory.boolValue else { throw TemplateLibraryError.notAFile(path: url.path) }
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= TrackSetTemplateCodec.maxFileBytes else {
            throw TemplateRefusal(
                code: .tooLarge, path: "",
                message: "This template file is \(size) bytes, and a template can be at most "
                    + "\(TrackSetTemplateCodec.maxFileBytes) bytes (2 MB).")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw TemplateLibraryError.readFailed(file: url.lastPathComponent,
                                                  reason: error.localizedDescription)
        }
    }

    // MARK: - Remove

    /// Deletes a saved template's file. A built-in is refused with "Built-in
    /// templates can't be removed."
    @discardableResult
    public func remove(id: String, builtIns: BuiltInTemplateCatalog.Listing =
                           BuiltInTemplateCatalog.load()) throws -> String {
        let listing = list(builtIns: builtIns)
        if BuiltInTemplateCatalog.ids.contains(id)
            || listing.entry(id: id)?.source == .builtIn {
            throw TemplateLibraryError.builtInCantBeRemoved
        }
        guard let entry = listing.entry(id: id), entry.source == .saved else {
            throw TemplateLibraryError.unknownTemplate(id: id)
        }
        do {
            try FileManager.default.removeItem(at: root.appendingPathComponent(entry.fileName))
        } catch {
            throw TemplateLibraryError.writeFailed(file: entry.fileName,
                                                   reason: error.localizedDescription)
        }
        return id
    }

    // MARK: - Import

    /// What `importTemplate` did.
    public struct ImportResult: Sendable, Equatable {
        public let id: String
        public let name: String
        public let fileName: String
        public let warnings: [TemplateWarning]
    }

    /// Copies a template file into the library after reading it with the full
    /// codec (as a FILE, strictly unless a newer version wrote it) and planning
    /// it with the builder. Its id is kept unless it is missing, a built-in's or
    /// already taken; then it gets a fresh `user-` id, and a warning says so.
    /// The copy keeps the original bytes, so a newer version's keys survive;
    /// only a replaced id is rewritten. Refuses a file over 2 MB unread.
    public func importTemplate(from path: String, builtIns: BuiltInTemplateCatalog.Listing =
                                   BuiltInTemplateCatalog.load()) throws -> ImportResult {
        let url = try Self.absoluteURL(path)
        var data = try Self.boundedData(at: url)
        let decoded: TrackSetTemplateCodec.Result
        var minted: String?
        do {
            decoded = try TrackSetTemplateCodec.decode(data, origin: .file)
        } catch let refusal as TemplateRefusal where refusal.code == .missingKey
            && refusal.path == "id" {
            // A file with no id is given one here (§7.3) and then read STRICTLY
            // like any other file: only the id is supplied, nothing else.
            let id = Self.newSavedID()
            data = try Self.replacingID(in: data, with: id)
            decoded = try TrackSetTemplateCodec.decode(data, origin: .file)
            minted = id
        }
        _ = try TemplateBuilder.plan(decoded.template)

        let listing = list(builtIns: builtIns)
        var taken = Set(BuiltInTemplateCatalog.ids).union(listing.templates.map(\.id))
        let original = decoded.template.id
        var id = original
        var warnings = decoded.warnings
        if let minted {
            warnings.append(TemplateWarning(
                code: .idReplaced, path: "id",
                message: "This template had no id, so it was added as '\(minted)'."))
        }
        let fileExists = { (candidate: String) in
            FileManager.default.fileExists(
                atPath: self.root.appendingPathComponent("\(candidate).\(Self.fileExtension)").path)
        }
        if taken.contains(id) || fileExists(id) {
            repeat {
                id = Self.newSavedID()
            } while taken.contains(id) || fileExists(id)
            taken.insert(id)
            warnings.append(TemplateWarning(
                code: .idReplaced, path: "id",
                message: "Another template already uses the id '\(original)', so this one was "
                    + "added as '\(id)'."))
        }
        var bytes = data
        if id != original {
            bytes = try Self.replacingID(in: data, with: id)
            var expected = decoded.template
            expected.id = id
            guard try TrackSetTemplateCodec.decode(bytes, origin: .file).template == expected else {
                throw TemplateLibraryError.notExact(path: "id")
            }
        }
        let fileName = "\(id).\(Self.fileExtension)"
        try write(bytes, to: fileName, replacing: false)
        return ImportResult(id: id, name: decoded.template.name, fileName: fileName,
                            warnings: warnings)
    }

    /// `data` with its top-level `"id"` replaced, everything else kept —
    /// including keys a newer version wrote that this one cannot read.
    static func replacingID(in data: Data, with id: String) throws -> Data {
        guard case .object(var root) = try JSONDecoder().decode(TemplateJSON.self, from: data) else {
            throw TemplateLibraryError.notExact(path: "id")
        }
        root["id"] = .string(id)
        var text = ""
        TemplateCapture.write(.object(root), indent: 0, into: &text)
        text.append("\n")
        return Data(text.utf8)
    }

    // MARK: - Export

    /// What `export` wrote.
    public struct ExportResult: Sendable, Equatable {
        public let path: String
        public let bytes: Int
    }

    /// Writes a built-in's or a saved template's CANONICAL form to `path`. An
    /// existing file is refused unless `overwrite` is true.
    public func export(id: String, to path: String, overwrite: Bool = false,
                       builtIns: BuiltInTemplateCatalog.Listing = BuiltInTemplateCatalog.load())
        throws -> ExportResult {
        let entry = try entry(id: id, builtIns: builtIns)
        let url = try Self.absoluteURL(path)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let folder = url.deletingLastPathComponent()
        guard manager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TemplateLibraryError.folderMissing(path: folder.path)
        }
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { throw TemplateLibraryError.notAFile(path: url.path) }
            guard overwrite else { throw TemplateLibraryError.fileExists(path: url.path) }
        }
        let data = try TemplateCapture.canonicalJSON(entry.template)
        do {
            try data.write(to: url, options: overwrite ? .atomic : .withoutOverwriting)
        } catch {
            throw TemplateLibraryError.writeFailed(file: url.path,
                                                   reason: error.localizedDescription)
        }
        return ExportResult(path: url.path, bytes: data.count)
    }

    // MARK: - Writing

    /// `"user-<uuid>"`: built-in ids never start with `user-`, so a saved id can
    /// never collide with one (§7.2).
    static func newSavedID() -> String { "user-" + UUID().uuidString.lowercased() }

    static func absoluteURL(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw TemplateLibraryError.pathNotAbsolute(path: path) }
        return URL(fileURLWithPath: expanded)
    }

    /// Writes one file into `root`, creating the folder. `replacing: false`
    /// never overwrites; `true` replaces atomically, in place.
    func write(_ data: Data, to fileName: String, replacing: Bool) throws {
        let url = root.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: url, options: replacing ? .atomic : .withoutOverwriting)
        } catch {
            throw TemplateLibraryError.writeFailed(file: fileName,
                                                   reason: error.localizedDescription)
        }
    }
}

// MARK: - The store: saving the song's tracks

/// What `ProjectStore.saveTemplate` saved (§6.1's reply).
public struct TemplateSaveResult: Sendable, Equatable {
    public let id: String
    public let name: String
    /// The canonical template, exactly as the file reads back.
    public let template: TrackSetTemplate
    /// The file, inside the library folder.
    public let fileName: String
    /// `busIncluded`, `sidechainDropped`, and anything else capture worked around.
    public let warnings: [TemplateWarning]
}

extension ProjectStore {
    /// Saves the chosen tracks — plus every bus they play or send into — as a
    /// template file in `library` (§5.7, §7.2). Each hosted Audio Unit's CURRENT
    /// sound is saved (the project save's own capture). Makes NO undo entry and
    /// never changes the song.
    ///
    /// `replaceID` overwrites that saved template's file in place; a built-in's
    /// id is refused. Without it, a new `user-<uuid>` file is written and
    /// nothing is ever overwritten. Refused before anything is written: no or
    /// unknown tracks, more than 24 tracks once buses are added, a name over 40
    /// characters, a file over 2 MB, and a template the codec or the builder
    /// would not read back exactly. A Sampler is saved with its zones by
    /// absolute path (m39-tpl-5b); the files themselves are not copied.
    @discardableResult
    public func saveTemplate(name: String, trackIDs: [UUID], summary: String? = nil,
                             songForm: String? = nil, genres: [String] = [],
                             replaceID: String? = nil,
                             library: TemplateLibrary = .standard) throws -> TemplateSaveResult {
        let builtIns = BuiltInTemplateCatalog.load()
        let listing = library.list(builtIns: builtIns)
        let id: String
        let fileName: String
        if let replaceID {
            if BuiltInTemplateCatalog.ids.contains(replaceID)
                || listing.entry(id: replaceID)?.source == .builtIn {
                throw TemplateLibraryError.builtInCantBeReplaced(id: replaceID)
            }
            guard let entry = listing.entry(id: replaceID), entry.source == .saved else {
                throw TemplateLibraryError.nothingToReplace(id: replaceID)
            }
            id = replaceID
            fileName = entry.fileName
        } else {
            var candidate = TemplateLibrary.newSavedID()
            while listing.entry(id: candidate) != nil || FileManager.default.fileExists(
                atPath: library.root.appendingPathComponent(
                    "\(candidate).\(TemplateLibrary.fileExtension)").path) {
                candidate = TemplateLibrary.newSavedID()
            }
            id = candidate
            fileName = "\(candidate).\(TemplateLibrary.fileExtension)"
        }

        let captured = try TemplateCapture.capture(
            tracks: tracksWithLiveAudioUnitState(), selected: trackIDs, name: name, id: id,
            summary: summary, songForm: songForm, genres: genres)
        let data = try TemplateCapture.canonicalJSON(captured.template)
        guard data.count <= TrackSetTemplateCodec.maxFileBytes else {
            throw TemplateRefusal(
                code: .tooLarge, path: "",
                message: "These tracks make a template of \(data.count) bytes, and a template can "
                    + "be at most \(TrackSetTemplateCodec.maxFileBytes) bytes (2 MB). A plug-in's "
                    + "saved sound is usually what makes it this big.")
        }
        // The proof, BEFORE writing: the exact bytes read back as a file, equal
        // what was captured, and plan.
        let decoded = try TrackSetTemplateCodec.decode(data, origin: .file)
        let canonical = try TemplateCapture.canonical(captured.template)
        guard decoded.template == canonical else {
            throw TemplateLibraryError.notExact(path: "tracks")
        }
        _ = try TemplateBuilder.plan(decoded.template)

        try library.write(data, to: fileName, replacing: replaceID != nil)
        return TemplateSaveResult(id: id, name: name, template: canonical, fileName: fileName,
                                  warnings: captured.warnings + decoded.warnings)
    }

    /// The library listing (`template.list`). Reads files; changes nothing.
    public func listTemplates(library: TemplateLibrary = .standard) -> TemplateLibrary.Listing {
        library.list()
    }

    /// Removes a saved template's file (`template.remove`). No undo entry.
    @discardableResult
    public func removeTemplate(id: String, library: TemplateLibrary = .standard) throws -> String {
        try library.remove(id: id)
    }

    /// Imports a template file into the library (`template.import`). No undo entry.
    @discardableResult
    public func importTemplate(from path: String, library: TemplateLibrary = .standard) throws
        -> TemplateLibrary.ImportResult {
        try library.importTemplate(from: path)
    }

    /// Writes a template's canonical form to `path` (`template.export`). No undo entry.
    @discardableResult
    public func exportTemplate(id: String, to path: String, overwrite: Bool = false,
                               library: TemplateLibrary = .standard) throws
        -> TemplateLibrary.ExportResult {
        try library.export(id: id, to: path, overwrite: overwrite)
    }
}
