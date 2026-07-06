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
    public static func planMedia(tracks: [Track], bundleURL: URL) -> MediaPlan {
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
                let stdPath = stdSource.path

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

        return MediaPlan(copies: copies, refs: refs, warnings: warnings)
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
    public static func write(document: ProjectDocument, plan: MediaPlan, to bundleURL: URL) throws {
        let fm = FileManager.default
        let mediaDir = bundleURL.appendingPathComponent("media", isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        // copyItem uses APFS clonefile on the same volume (near-free); a
        // cross-volume destination falls back to a full byte copy that can stall
        // the caller's actor for large takes. Acceptable for v0.
        for copy in plan.copies {
            try fm.copyItem(at: copy.source, to: copy.destination)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try data.write(to: bundleURL.appendingPathComponent("project.json"), options: .atomic)
    }
}
