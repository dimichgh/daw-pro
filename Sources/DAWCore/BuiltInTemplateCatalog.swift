import Foundation

// m39-tpl-3 — THE BUILT-IN TEMPLATES (docs/design/2026-09-27-multi-instrument-templates.md §7.1, §7.3).
//
// Ten `.dawtemplate` files ship as a DAWCore resource, `Resources/Templates/`, copied verbatim (`.copy` in
// Package.swift, beside `BundledSamples`). They are the SAME format a user's saved file is, decoded by the SAME
// codec (`TrackSetTemplateCodec`, origin `.file`, strictly), so every built-in exercises the codec on every test
// run. Built-ins never use an Audio Unit or a Sampler: they must sound the same on every Mac.
//
// ⭐ NOTHING IS SILENTLY SKIPPED (§7.3). A built-in that is missing from this build, or that the codec refuses, is
// listed in `unreadable` with the reason; a file in the folder that the catalog does not name is listed there too.
//
// `BuiltInTemplateCatalogTests` holds every built-in to §7.1's rules (the catalog-integrity gate, §8.1).
//
// TODO(TPL-6): `template.list` / `template.describe` / `template.apply {template: "<id>"}` resolve built-in ids
// through `load()` (design §6.1). TODO(TPL-7): the MCP tools `template_list`, `template_describe`,
// `template_apply` in `mcp-server/src/server.ts` (design §6.5). TODO(TPL-8): the picker card lists `load()`.

/// The built-in template catalog: the ten `.dawtemplate` files in DAWCore's resources, in catalog order.
public enum BuiltInTemplateCatalog {
    /// Every built-in id, in CATALOG ORDER. A genre's default template — the one "Start a song" offers — is the
    /// FIRST built-in in this order whose `genres` lists it (§7.1). The file for id `x` is `x.dawtemplate`, and
    /// `BuiltInTemplateCatalogTests` pins this list against the folder both ways.
    public static let ids: [String] = [
        "pop-band",
        "piano-ballad",
        "rock-band",
        "house-club",
        "hip-hop-808",
        "lofi-chill",
        "jazz-combo",
        "acoustic-folk",
        "soul-blues",
        "reggae-riddim",
    ]

    /// The file extension of every template file, built-in or saved.
    public static let fileExtension = "dawtemplate"

    /// `.copy` in Package.swift preserves the directory, so the files land at `Templates/…` inside the resource
    /// bundle.
    static let resourceSubdirectory = "Templates"

    /// One built-in, decoded.
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let fileName: String
        public let template: TrackSetTemplate
    }

    /// A built-in that could not be offered, and why, in words a person can read.
    public struct Unreadable: Sendable, Equatable {
        public let file: String
        public let message: String
    }

    /// What `load()` found.
    public struct Listing: Sendable, Equatable {
        /// Every readable built-in, in catalog order.
        public let templates: [Entry]
        /// Every built-in that could not be read, with the reason. Never silently empty.
        public let unreadable: [Unreadable]
    }

    /// Every built-in, decoded by the one codec, in catalog order. A built-in that is missing or refused is
    /// listed in `unreadable`, never skipped.
    public static func load() -> Listing {
        guard let directory = directoryURL() else {
            return Listing(templates: [], unreadable: ids.map { id in
                Unreadable(file: "\(id).\(fileExtension)",
                           message: "The built-in templates are missing from this build of DAW Pro.")
            })
        }
        return load(from: directory)
    }

    /// `load()` over a given folder.
    static func load(from directory: URL) -> Listing {
        var templates: [Entry] = []
        var unreadable: [Unreadable] = []
        for id in ids {
            let fileName = "\(id).\(fileExtension)"
            let data: Data
            do {
                data = try Data(contentsOf: directory.appendingPathComponent(fileName))
            } catch {
                unreadable.append(Unreadable(
                    file: fileName, message: "This built-in template is missing from this build of DAW Pro."))
                continue
            }
            do {
                let decoded = try TrackSetTemplateCodec.decode(data, origin: .file)
                guard decoded.template.id == id else {
                    unreadable.append(Unreadable(
                        file: fileName,
                        message: "Its id is '\(decoded.template.id)', but the file is named for '\(id)'."))
                    continue
                }
                templates.append(Entry(id: id, fileName: fileName, template: decoded.template))
            } catch let refusal as TemplateRefusal {
                unreadable.append(Unreadable(file: fileName,
                                             message: refusal.errorDescription ?? refusal.message))
            } catch {
                unreadable.append(Unreadable(file: fileName, message: error.localizedDescription))
            }
        }
        // A file the catalog does not name is a packaging mistake: say so rather than ignore it.
        let present = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let known = Set(ids.map { "\($0).\(fileExtension)" })
        for name in present.sorted() where name.hasSuffix(".\(fileExtension)") && !known.contains(name) {
            unreadable.append(Unreadable(
                file: name, message: "This file is not in the list of built-in templates, so it is not offered."))
        }
        return Listing(templates: templates, unreadable: unreadable)
    }

    /// The template "Start a song" offers for `genre`: the first built-in, in catalog order, whose `genres` lists
    /// it. Nil when none does (a test pins that every catalog genre has one).
    public static func defaultTemplateID(forGenre genre: String, in templates: [Entry]) -> String? {
        templates.first { $0.template.genres.contains(genre) }?.id
    }

    // MARK: - Resource resolution

    /// Anchors `Bundle(for:)` to the image DAWCore was linked into. A plain empty class, never instantiated.
    private final class BundleAnchor {}

    /// The folder holding the built-ins, or nil if it did not make it into this build.
    ///
    /// ⚠️ NOT `Bundle.module`: SwiftPM's generated accessor ends in `fatalError`, so a packaged app missing this
    /// resource would crash instead of reporting it. The candidates are `BundledSamples.url(for:)`'s, in its
    /// order (the packaged app's Resources, beside a bare executable, and — test runner only — beside the
    /// `.xctest`); see that function for why each exists. `scripts/bundle.sh` copies `daw-pro_DAWCore.bundle`
    /// into the packaged app and refuses to finish without it.
    public static func directoryURL() -> URL? {
        let bundleName = "daw-pro_DAWCore.bundle"
        let code = Bundle(for: BundleAnchor.self)
        var candidates: [URL?] = [
            code.resourceURL?.appendingPathComponent(bundleName),
            code.bundleURL.appendingPathComponent(bundleName),
        ]
        if code.bundleURL.pathExtension == "xctest" {
            candidates.append(code.bundleURL.deletingLastPathComponent().appendingPathComponent(bundleName))
        }
        for url in candidates.compactMap({ $0 }) {
            guard let bundle = Bundle(url: url) else { continue }
            // The resource bundle is FLAT (no Contents/), so the folder is found the way `BundledSamples` finds
            // its files: by name, through the bundle.
            if let directory = bundle.url(forResource: resourceSubdirectory, withExtension: nil) {
                return directory
            }
        }
        return nil
    }
}
