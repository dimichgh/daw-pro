import Foundation

/// Filesystem layer for the `.dawproj` bundle: a package DIRECTORY holding a
/// versioned `project.json` plus a flat `media/` folder of copied source files.
/// Pure Foundation — it reads and writes JSON and copies media, and NEVER opens
/// or decodes audio. All I/O here is synchronous; callers run it on the main
/// actor (see `ProjectStore`), which is fine for KB-scale JSON and APFS
/// clonefile copies (see `write`'s cross-volume note).
public enum ProjectBundle {
    /// Schema the current build writes and can read up to.
    public static let currentSchemaVersion = 1
    /// Bundle package extension (without the dot).
    public static let fileExtension = "dawproj"

    /// Normalizes a user-supplied path into a bundle URL: expands `~`, appends
    /// `.dawproj` unless already present (case-insensitive), and standardizes
    /// to an absolute path.
    public static func normalizedBundleURL(fromPath path: String) -> URL {
        var expanded = (path as NSString).expandingTildeInPath
        if !expanded.lowercased().hasSuffix(".\(fileExtension)") {
            expanded += ".\(fileExtension)"
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// Just enough of `project.json` to gate on version before a full decode.
    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }

    /// Reads and version-checks `project.json`, returning the decoded document.
    /// Throws:
    ///  - `.openFailed` when the bundle or its `project.json` is absent,
    ///  - `.newerProjectVersion` when the file is from a newer schema,
    ///  - `.malformedProject` for a sub-1 version, unreadable/invalid JSON, or a
    ///    decode failure.
    public static func read(from bundleURL: URL) throws -> ProjectDocument {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundleURL.path) else {
            throw ProjectError.openFailed("no project bundle at \(bundleURL.path)")
        }
        let jsonURL = bundleURL.appendingPathComponent("project.json")
        guard fm.fileExists(atPath: jsonURL.path) else {
            throw ProjectError.openFailed(
                "\(bundleURL.path) has no project.json — not a DAW Pro project bundle"
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: jsonURL)
        } catch {
            throw ProjectError.malformedProject("project.json could not be read")
        }

        let probe: SchemaProbe
        do {
            probe = try JSONDecoder().decode(SchemaProbe.self, from: data)
        } catch {
            throw ProjectError.malformedProject("project.json is not a valid DAW Pro document")
        }
        guard probe.schemaVersion >= 1 else {
            throw ProjectError.malformedProject(
                "schema version \(probe.schemaVersion) is below the minimum (1)"
            )
        }
        guard probe.schemaVersion <= currentSchemaVersion else {
            throw ProjectError.newerProjectVersion(
                found: probe.schemaVersion, supported: currentSchemaVersion
            )
        }

        // Migration seam: when currentSchemaVersion climbs past 1, migrate the
        // raw JSON stepwise (v1→v2→…→current) here BEFORE the decode below.
        // Breaking changes bump the version; additive fields ride decodeIfPresent
        // defaults and need no migration.

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ProjectDocument.self, from: data)
        } catch {
            throw ProjectError.malformedProject("project.json is missing required fields")
        }
    }

    /// A resolved plan for laying a session's media into a bundle: which source
    /// files to copy where, the `media/` reference to persist per clip, and any
    /// warnings (missing sources). Computed without touching audio.
    public struct MediaPlan {
        public var copies: [(source: URL, destination: URL)]
        public var refs: [UUID: String?]
        public var warnings: [String]

        public init(
            copies: [(source: URL, destination: URL)],
            refs: [UUID: String?],
            warnings: [String]
        ) {
            self.copies = copies
            self.refs = refs
            self.warnings = warnings
        }
    }

    /// Plans a self-contained media copy for `tracks` into `bundleURL/media/`.
    ///  - Every external source is copied in (self-contained bundle).
    ///  - Identical sources (same standardized path) share ONE copy.
    ///  - Basenames are preserved; collisions get `-2`/`-3` suffixes, counted
    ///    against both the bundle's EXISTING `media/` files and the copies
    ///    already planned in this pass (deterministic track/clip order).
    ///  - Sources already inside this bundle's `media/` keep their reference and
    ///    are NOT re-copied (idempotent re-save).
    ///  - A missing external source is not fatal: the clip's ref becomes null
    ///    with a warning.
    ///  - `reference` (m22-g, ADDITIVE — existing call sites compile
    ///    unchanged): the reference slot's file joins the SAME URL-keyed
    ///    dedupe/copy/rewrite into `media/`, keyed by the slot id.
    public static func planMedia(
        tracks: [Track], reference: ReferenceSlot? = nil, bundleURL: URL
    ) -> MediaPlan {
        let fm = FileManager.default
        let mediaDir = bundleURL.appendingPathComponent("media", isDirectory: true).standardizedFileURL
        let mediaDirPath = mediaDir.path

        // Names already spoken for: existing media/ contents (re-save) plus
        // whatever this pass has planned.
        var takenNames = Set<String>()
        if let existing = try? fm.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil) {
            for file in existing { takenNames.insert(file.lastPathComponent) }
        }

        var copies: [(source: URL, destination: URL)] = []
        var refs: [UUID: String?] = [:]
        var warnings: [String] = []
        // Dedupe: standardized source path → the media basename it was given.
        var assigned: [String: String] = [:]

        for track in tracks {
            for clip in track.clips {
                guard let source = clip.audioFileURL else {
                    refs[clip.id] = String?.none  // present-but-nil = "no media"
                    continue
                }
                let stdSource = source.standardizedFileURL
                let stdPath = stdSource.path

                // Already a direct child of this bundle's media/ → keep the ref,
                // no copy. Reserve its name so external copies can't collide.
                if stdSource.deletingLastPathComponent().path == mediaDirPath {
                    let name = stdSource.lastPathComponent
                    refs[clip.id] = "media/\(name)"
                    takenNames.insert(name)
                    continue
                }

                // Missing external source → save without media, warn, don't copy.
                guard fm.fileExists(atPath: stdPath) else {
                    refs[clip.id] = String?.none
                    warnings.append(
                        "missing source file \(stdPath) — clip '\(clip.name)' saved without media"
                    )
                    continue
                }

                // Shared source already planned → reuse the same destination.
                if let name = assigned[stdPath] {
                    refs[clip.id] = "media/\(name)"
                    continue
                }

                // New external source → assign a collision-free basename + copy.
                let name = uniqueName(for: stdSource.lastPathComponent, taken: takenNames)
                takenNames.insert(name)
                assigned[stdPath] = name
                copies.append((source: stdSource, destination: mediaDir.appendingPathComponent(name)))
                refs[clip.id] = "media/\(name)"
            }
        }

        // Sampler zone media rides the SAME dedupe/collision machinery as clips
        // (shared `assigned`/`takenNames`), keyed by zone id — so a zone that
        // shares a source with a clip (or another zone) reuses that one copy.
        // Runs after all clips for deterministic naming.
        for track in tracks {
            guard track.kind == .instrument else { continue }
            for zone in track.instrument?.sampler?.zones ?? [] {
                let stdSource = zone.audioFileURL.standardizedFileURL
                // m32-a: ONE HOME for the "same source file?" key. Byte-identical
                // to the expression that was inlined here — `sourceFileKey` IS
                // `audioFileURL.standardizedFileURL.path` — but now the sampler
                // loader's buffer dedup reads the same property, so the two
                // cannot drift into a project that plays one way and reloads
                // another.
                let stdPath = zone.sourceFileKey

                if stdSource.deletingLastPathComponent().path == mediaDirPath {
                    let name = stdSource.lastPathComponent
                    refs[zone.id] = "media/\(name)"
                    takenNames.insert(name)
                    continue
                }
                guard fm.fileExists(atPath: stdPath) else {
                    refs[zone.id] = String?.none
                    warnings.append(
                        "missing source file \(stdPath) — sampler zone on track '\(track.name)' saved without media"
                    )
                    continue
                }
                if let name = assigned[stdPath] {
                    refs[zone.id] = "media/\(name)"
                    continue
                }
                let name = uniqueName(for: stdSource.lastPathComponent, taken: takenNames)
                takenNames.insert(name)
                assigned[stdPath] = name
                copies.append((source: stdSource, destination: mediaDir.appendingPathComponent(name)))
                refs[zone.id] = "media/\(name)"
            }
        }

        // Take-lane payload media (M5 iii-a) rides the SAME dedupe/collision
        // machinery (shared `assigned`/`takenNames`), keyed by the lane clip's id.
        // Runs after clips so a comp MEMBER (in track.clips) and its LANE, which
        // reference the same file, share one copy — but a NON-COMPED lane's file
        // (referenced by no member) is still copied, so it survives the save.
        for track in tracks {
            for group in track.takeGroups {
                for lane in group.lanes {
                    let clip = lane.clip
                    guard let source = clip.audioFileURL else {
                        refs[clip.id] = String?.none
                        continue
                    }
                    let stdSource = source.standardizedFileURL
                    let stdPath = stdSource.path

                    if stdSource.deletingLastPathComponent().path == mediaDirPath {
                        let name = stdSource.lastPathComponent
                        refs[clip.id] = "media/\(name)"
                        takenNames.insert(name)
                        continue
                    }
                    guard fm.fileExists(atPath: stdPath) else {
                        refs[clip.id] = String?.none
                        warnings.append(
                            "missing source file \(stdPath) — take '\(lane.name)' saved without media"
                        )
                        continue
                    }
                    if let name = assigned[stdPath] {
                        refs[clip.id] = "media/\(name)"
                        continue
                    }
                    let name = uniqueName(for: stdSource.lastPathComponent, taken: takenNames)
                    takenNames.insert(name)
                    assigned[stdPath] = name
                    copies.append((source: stdSource, destination: mediaDir.appendingPathComponent(name)))
                    refs[clip.id] = "media/\(name)"
                }
            }
        }

        // Reference-slot media (m22-g) rides the SAME dedupe/collision
        // machinery (shared `assigned`/`takenNames`), keyed by the slot id.
        // Runs LAST for deterministic naming. A missing source records a
        // NULL ref + warning; the document layer then persists the slot's
        // ABSOLUTE path instead so the slot still names its file (unlike a
        // clip, a pathless slot is meaningless — see ProjectDocument.init).
        if let reference {
            let stdSource = URL(fileURLWithPath: reference.sourcePath).standardizedFileURL
            let stdPath = stdSource.path
            if stdSource.deletingLastPathComponent().path == mediaDirPath {
                let name = stdSource.lastPathComponent
                refs[reference.id] = "media/\(name)"
                takenNames.insert(name)
            } else if !fm.fileExists(atPath: stdPath) {
                refs[reference.id] = String?.none
                warnings.append(
                    "missing source file \(stdPath) — reference '\(reference.name)' saved without media (path kept)"
                )
            } else if let name = assigned[stdPath] {
                refs[reference.id] = "media/\(name)"
            } else {
                let name = uniqueName(for: stdSource.lastPathComponent, taken: takenNames)
                takenNames.insert(name)
                assigned[stdPath] = name
                copies.append((source: stdSource, destination: mediaDir.appendingPathComponent(name)))
                refs[reference.id] = "media/\(name)"
            }
        }

        return MediaPlan(copies: copies, refs: refs, warnings: warnings)
    }

    // MARK: - Embedded voices (m24-n)

    /// One voice as it will exist inside the bundle after `write`.
    public struct EmbeddedVoiceRecord: Sendable, Equatable {
        public var voiceId: String
        /// Whitelisted file names present, in `VoiceStore.embeddableFileNames`
        /// order.
        public var files: [String]
        /// Total bytes the voice occupies in the bundle after this save.
        public var byteCount: Int
        /// Bytes this save actually COPIES. Zero on an idempotent re-save —
        /// which is what makes "warn when bytes were paid" fire exactly once
        /// per voice per project rather than on every ⌘S.
        public var copiedByteCount: Int

        public init(voiceId: String, files: [String],
                    byteCount: Int, copiedByteCount: Int) {
            self.voiceId = voiceId
            self.files = files
            self.byteCount = byteCount
            self.copiedByteCount = copiedByteCount
        }
    }

    /// A resolved plan for embedding voice models into `bundleURL/voices/`
    /// (m24-n) — the `MediaPlan` shape, deliberately: plan without touching the
    /// filesystem, then let `write` perform it.
    public struct VoicePlan: Sendable {
        public var copies: [(source: URL, destination: URL)]
        public var voices: [EmbeddedVoiceRecord]
        public var warnings: [String]

        public init(copies: [(source: URL, destination: URL)] = [],
                    voices: [EmbeddedVoiceRecord] = [],
                    warnings: [String] = []) {
            self.copies = copies
            self.voices = voices
            self.warnings = warnings
        }

        /// The plan that embeds nothing. ⭐ The DEFAULT for `write`, which is
        /// why the recovery bundle, the crash-recovery autosave and the
        /// diagnostics/feedback bundle carry no voice weights BY CONSTRUCTION
        /// rather than by anyone remembering to exclude them. For the feedback
        /// bundle that is a privacy and size property, not an accident: a
        /// support bundle must never ship 240 MB of the user's voice models.
        public static let empty = VoicePlan()

        public var totalBytes: Int { voices.reduce(0) { $0 + $1.byteCount } }
        public var copiedBytes: Int { voices.reduce(0) { $0 + $1.copiedByteCount } }
    }

    /// Plans the voice-model embed for `tracks` into `bundleURL/voices/`
    /// (m24-n — the user's *"Embed a copy of the voice"*).
    ///
    /// **What decides which voices.** Exactly the distinct `voiceId`s named by
    /// some track's `voiceProvenance`, in session order. That record is a fact
    /// about where audio came from; reading it here is the ONLY thing in the
    /// app that acts on it, and it acts once, at save time.
    ///
    /// **Which files travel** is `VoiceStore.embeddableFileNames` — notably NOT
    /// `model.pth`; see that whitelist's doc for the measurement.
    ///
    /// **Where they come from, in order.**
    ///  1. This machine's voice store (`voiceStoreURL/<voiceId>/`) — authoritative.
    ///  2. Failing that, the bundle the session is currently open FROM
    ///     (`openBundleURL`). This is the case that makes a project portable in
    ///     BOTH directions: open a project from another machine whose voice you
    ///     do not have, Save As, and the embedded copy survives instead of
    ///     evaporating because the store could not supply it.
    ///  3. Neither ⇒ a WARNING naming the voice and the tracks, and nothing is
    ///     embedded for it. Not an error: the converted audio plays regardless
    ///     (§ `VoiceProvenance`), only re-conversion is unavailable.
    ///
    /// **Idempotent re-save.** A destination file that already matches its
    /// source in BOTH size and modification date is not re-copied — so ⌘S on an
    /// unchanged project copies zero voice bytes. Size alone is not enough: two
    /// different RVC voices produce `model.npz` files of IDENTICAL size (55 114
    /// 342 B for both voices measured on this machine), and a retrained model
    /// would collide the same way. The residual gap is a replacement written
    /// with a preserved mtime, which nothing in this app does.
    ///
    /// Saving IN PLACE resolves source and destination to the same file, which
    /// necessarily matches, so a save-in-place plans zero copies by the same
    /// rule rather than by a special case.
    public static func planVoices(
        tracks: [Track],
        bundleURL: URL,
        voiceStoreURL: URL,
        openBundleURL: URL? = nil,
        fileManager fm: FileManager = .default
    ) -> VoicePlan {
        // Distinct voice ids in session order; first provenance wins the name.
        var order: [String] = []
        var trackNames: [String: [String]] = [:]
        for track in tracks {
            guard let provenance = track.voiceProvenance else { continue }
            if trackNames[provenance.voiceId] == nil {
                order.append(provenance.voiceId)
                trackNames[provenance.voiceId] = []
            }
            trackNames[provenance.voiceId]?.append(track.name)
        }
        guard !order.isEmpty else { return .empty }

        var plan = VoicePlan()
        for voiceId in order {
            let users = (trackNames[voiceId] ?? []).map { "'\($0)'" }.joined(separator: ", ")
            // The builtin smoke target is not in the store and never can be —
            // the facade resolves it from its own checkout. Skipped SILENTLY:
            // it ships with the app, so a project converted against it is
            // already as portable as it will ever be, and a warning here would
            // teach a fix ("install the voice") that is neither possible nor
            // needed. It is still recorded as provenance, which is the fact.
            if voiceId == VoiceStore.reservedVoiceId { continue }
            guard let destinationDir = VoiceStore.embeddedDirectory(
                voiceId: voiceId, bundleURL: bundleURL) else {
                plan.warnings.append(
                    "voice id '\(voiceId)' (recorded on \(users)) is not a usable folder name — "
                    + "the voice was not embedded; the converted audio is unaffected")
                continue
            }
            // Source resolution, in the documented order.
            var sourceDir: URL?
            let fromStore = voiceStoreURL.appendingPathComponent(voiceId, isDirectory: true)
            if VoiceStore.isUsableVoiceDirectory(fromStore, fileManager: fm) {
                sourceDir = fromStore
            } else if let openBundleURL,
                      let carried = VoiceStore.embeddedDirectory(
                        voiceId: voiceId, bundleURL: openBundleURL),
                      VoiceStore.isUsableVoiceDirectory(carried, fileManager: fm) {
                sourceDir = carried
            }
            guard let sourceDir else {
                plan.warnings.append(
                    "voice '\(voiceId)' (used by \(users)) is not in this machine's voice store, "
                    + "so no copy of it could be embedded — the converted audio still plays; "
                    + "re-converting with this voice needs it installed first "
                    + "(vc.importVoiceModel)")
                continue
            }

            var files: [String] = []
            var bytes = 0
            var copiedBytes = 0
            for file in VoiceStore.embeddableFiles(in: sourceDir, fileManager: fm) {
                let destination = destinationDir.appendingPathComponent(file.name)
                files.append(file.name)
                bytes += file.byteCount
                if unchangedCopy(source: file.url, destination: destination, fileManager: fm) {
                    continue
                }
                plan.copies.append((source: file.url, destination: destination))
                copiedBytes += file.byteCount
            }
            plan.voices.append(EmbeddedVoiceRecord(
                voiceId: voiceId, files: files,
                byteCount: bytes, copiedByteCount: copiedBytes))
        }
        return plan
    }

    /// True when `destination` already holds what `source` would copy there —
    /// same byte size AND same modification date. See `planVoices`' idempotency
    /// note for why size alone is not enough.
    static func unchangedCopy(
        source: URL, destination: URL, fileManager fm: FileManager = .default
    ) -> Bool {
        guard let a = try? fm.attributesOfItem(atPath: source.path),
              let b = try? fm.attributesOfItem(atPath: destination.path) else { return false }
        guard let sizeA = a[.size] as? Int, let sizeB = b[.size] as? Int,
              sizeA == sizeB else { return false }
        let dateA = a[.modificationDate] as? Date
        let dateB = b[.modificationDate] as? Date
        return dateA == dateB
    }

    /// Returns `basename` if free, else `<stem>-2.<ext>`, `<stem>-3.<ext>`, … —
    /// the first candidate not already in `taken`.
    static func uniqueName(for basename: String, taken: Set<String>) -> String {
        guard taken.contains(basename) else { return basename }
        let ns = basename as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// Materializes a bundle: makes the package + `media/` dirs, performs the
    /// planned media copies, then writes `project.json` ATOMICALLY LAST so a
    /// crash mid-write never leaves a half-updated document. No media is deleted
    /// (no GC) — see `ProjectStore` for the undo-resurrection rationale.
    public static func write(
        document: ProjectDocument, plan: MediaPlan,
        voices: VoicePlan = .empty, to bundleURL: URL
    ) throws {
        let fm = FileManager.default
        let mediaDir = bundleURL.appendingPathComponent("media", isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        // copyItem uses APFS clonefile on the same volume (near-free); a
        // cross-volume destination falls back to a full byte copy that can stall
        // the caller's actor for large takes. Acceptable for v0.
        for copy in plan.copies {
            try fm.copyItem(at: copy.source, to: copy.destination)
        }

        // Embedded voice models (m24-n) ride the SAME plan-then-copy pass, with
        // two differences forced by the layout: each voice owns a SUBDIRECTORY
        // (so its parent must be made — `copyItem` never creates one), and a
        // destination that survived from an earlier save is REPLACED rather
        // than skipped (`copyItem` refuses to overwrite; `planVoices` already
        // dropped every destination that matched, so anything still here
        // differs and the newer file is the right one).
        for copy in voices.copies {
            try fm.createDirectory(
                at: copy.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if fm.fileExists(atPath: copy.destination.path) {
                try fm.removeItem(at: copy.destination)
            }
            try fm.copyItem(at: copy.source, to: copy.destination)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try data.write(to: bundleURL.appendingPathComponent("project.json"), options: .atomic)
    }
}
