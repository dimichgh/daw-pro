import Foundation
import Testing
@testable import DAWCore

// m39-tpl-3 — CATALOG INTEGRITY for the ten built-in templates
// (docs/design/2026-09-27-multi-instrument-templates.md §7.1's seven rules, §8.1's gate).
//
// Reads the files the app ships — the resource bundle's copies, through `BuiltInTemplateCatalog.directoryURL()`,
// the same resolution the app uses — decodes each with the real codec, builds each with the real builder, and
// checks every rule on the BUILT values where it can (a setter's return is not proof it took; the reading is).
// Every problem is a sentence naming the file and the path, so a red says where to look.
//
// The rules: (1) every playable part is an instrument track, and only recorded material is an audio track;
// (2) no Audio Unit and no Sampler, anywhere; (3) a drum machine plays the General MIDI note layout; (4) echoes
// follow the tempo, and a tape delay is only a short slapback; (5) LFOs are slow sweeps, in Hz; (6) names fit,
// and the summary is one short sentence; (7) a return bus is 100 % wet. Plus: ids and names unique, the folder
// holds exactly the catalog, every catalog genre has its default template, every song form and genre is real,
// the plan has zero warnings, every strip stays within its 64 slots, every bus receives something, and every
// instrument track names its instrument (without one it would play the Poly Synth).
//
// `theRuleCheckerCatchesEveryPlantedDefect` keeps the checker honest for good: each rule is seen failing on an
// in-memory copy of a real file. Its anchors are deliberately NOT the ones TPL-3's file plants used.
//
// Nonisolated: nothing here touches the store (the Leg C cap counts only `@MainActor` suites).

@Suite("Built-in template catalog — integrity (m39-tpl-3)")
struct BuiltInTemplateCatalogTests {
    /// Recorded material: the only parts that are audio tracks (the skeleton's m26-o allowlist, plus "Vocal").
    static let recordedMaterial: Set<String> = [
        "Vocal", "Vocals", "Lead Vocal", "Backing Vocals", "Vinyl FX", "FX", "Samples",
    ]
    /// Rule 5's "slow". [A] — a sweep or a breath, never a rhythmic pulse.
    static let maxLFORateHz = 1.0
    /// Rule 4's slapback ceiling, in milliseconds (§7.1: ≤ 150 ms).
    static let maxSlapbackMs = 150.0

    /// The default template §7.1 assigns each of the 14 genres.
    static let expectedDefaults: [String: String] = [
        "pop": "pop-band", "ballad": "piano-ballad", "rock": "rock-band", "metal": "rock-band",
        "house": "house-club", "hip-hop": "hip-hop-808", "r-and-b": "hip-hop-808", "lo-fi": "lofi-chill",
        "jazz": "jazz-combo", "folk": "acoustic-folk", "country": "acoustic-folk", "blues": "soul-blues",
        "funk": "soul-blues", "reggae": "reggae-riddim",
    ]

    // MARK: - Helpers

    /// Every `.dawtemplate` in the shipped folder, by name, with its bytes.
    static func shippedFiles() throws -> [(name: String, data: Data)] {
        let directory = try #require(BuiltInTemplateCatalog.directoryURL(),
                                     "the built-in templates are not in DAWCore's resource bundle")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".\(BuiltInTemplateCatalog.fileExtension)") }
            .sorted()
        return try names.map { name in
            (name: name, data: try Data(contentsOf: directory.appendingPathComponent(name)))
        }
    }

    static func shippedFile(_ id: String) throws -> Data {
        let name = "\(id).\(BuiltInTemplateCatalog.fileExtension)"
        let match = try shippedFiles().first(where: { $0.name == name })
        return try #require(match?.data, "no shipped file \(name)")
    }

    /// One sentence: it ends with a full stop (or ! or ?), and no sentence ends inside it.
    static func isOneSentence(_ text: String) -> Bool {
        guard let last = text.last, ".!?".contains(last) else { return false }
        let body = text.dropLast()
        return !body.contains(". ") && !body.contains("! ") && !body.contains("? ")
    }

    /// Every way the file breaks §7.1's rules, as sentences naming the file and the path. Empty: it obeys them.
    static func problems(_ fileName: String, _ data: Data) -> [String] {
        var problems: [String] = []
        func say(_ path: String, _ what: String) {
            problems.append("\(fileName): \(path.isEmpty ? "" : "\(path): ")\(what)")
        }
        let decoded: TrackSetTemplateCodec.Result
        do {
            decoded = try TrackSetTemplateCodec.decode(data, origin: .file)
        } catch let refusal as TemplateRefusal {
            say(refusal.path, "the codec refuses it: \(refusal.message)")
            return problems
        } catch {
            say("", "the codec failed: \(error)")
            return problems
        }
        for warning in decoded.warnings {
            say(warning.path, "the codec worked around something (\(warning.code.rawValue)): \(warning.message)")
        }
        let template = decoded.template
        if "\(template.id).\(BuiltInTemplateCatalog.fileExtension)" != fileName {
            say("id", "the id '\(template.id)' is not the file's name")
        }
        // Rule 6 (the codec already holds names to 1–40 characters and the summary to 200).
        let summary = template.summary ?? ""
        if summary.isEmpty || !isOneSentence(summary) {
            say("summary", "a built-in's summary is ONE sentence a novice can read; this is '\(summary)'")
        }
        if let form = template.songForm {
            if !template.genres.contains(form) {
                say("songForm", "the song form '\(form)' must also be one of the template's genres")
            }
        } else {
            say("songForm", "a built-in names the song form \"Start a song\" uses")
        }
        if template.genres.isEmpty { say("genres", "a built-in lists the genres it suits") }

        let plan: TemplatePlan
        do {
            plan = try TemplateBuilder.plan(template)
        } catch let refusal as TemplateRefusal {
            say(refusal.path, "the builder refuses it: \(refusal.message)")
            return problems
        } catch {
            say("", "the builder failed: \(error)")
            return problems
        }
        for warning in plan.warnings {
            say(warning.path, "the plan has a warning (\(warning.code.rawValue)): \(warning.message); a "
                + "built-in plans with none")
        }
        for (key, used) in plan.slotsUsed where used > 64 {
            say("tracks.\(key)", "its modulation uses \(used) of the strip's 64 slots")
        }
        for resource in plan.resources {
            if case .soundBank(let bank) = resource.item, bank.source == .generalMIDI { continue }
            say(resource.path, "a built-in uses only the Mac's own General MIDI sounds, never a file or a "
                + "plug-in, so it sounds the same on every Mac")
        }

        var playsInto: Set<String> = []
        var sentTo: Set<String> = []
        for track in template.tracks {
            if let output = track.output { playsInto.insert(output) }
            for send in track.sends { sentTo.insert(send.bus) }
        }
        for (index, spec) in template.tracks.enumerated() {
            let path = "tracks[\(index)]"
            let built = plan.tracks[index]
            // Rule 1.
            let recorded = recordedMaterial.contains(spec.name)
            if spec.kind == .audio, !recorded {
                say("\(path).kind", "'\(spec.name)' is an audio track, but only recorded material (a vocal, "
                    + "vinyl noise) is; a playable part is an instrument track")
            }
            if spec.kind == .instrument, recorded {
                say("\(path).kind", "'\(spec.name)' is recorded material, so it is an audio track, not an "
                    + "instrument track")
            }
            if spec.kind == .instrument, spec.instrument == nil {
                say("\(path).instrument", "an instrument track in a built-in names its instrument; without "
                    + "one it plays the Poly Synth")
            }
            // Rules 2 and 3, on the built instrument.
            if let instrument = built.instrument {
                switch instrument.kind {
                case .audioUnit, .sampler, .testTone:
                    say("\(path).instrument.kind", "a built-in never uses the \(instrument.kind.rawValue) "
                        + "instrument: it must sound the same on every Mac")
                case .drumSynth:
                    if (instrument.drumKit?.noteLayout ?? .pads) != .gm {
                        say("\(path).instrument.drumKit.noteLayout", "a drum machine in a built-in plays the "
                            + "General MIDI note layout (\"gm\"); in the pad layout every General MIDI beat "
                            + "plays the wrong drums")
                    }
                case .polySynth, .soundBank:
                    break
                }
            }
            // Rules 2, 4 and 7, on the built inserts (the mixer preset's chain included).
            let isReturnBus = spec.kind == .bus && sentTo.contains(spec.key) && !playsInto.contains(spec.key)
            let presetCount = built.effects.count - spec.inserts.count
            for (position, effect) in built.effects.enumerated() {
                let insertPath = position >= presetCount
                    ? "\(path).inserts[\(position - presetCount)]"
                    : "\(path).mixerPreset[\(position)]"
                if effect.kind == .audioUnit {
                    say("\(insertPath).kind", "a built-in never uses an Audio Unit: it must sound the same on "
                        + "every Mac")
                }
                if effect.kind == .delay, effect.paramValue("sync") != 1 {
                    say("\(insertPath).params.sync", "an echo in a built-in follows the tempo (sync 1): a "
                        + "template has no tempo, so a time in milliseconds is right at one tempo only")
                }
                if effect.kind == .tapeDelay, (effect.paramValue("timeMs") ?? .infinity) > maxSlapbackMs {
                    say("\(insertPath).params.timeMs", "a tape delay cannot follow the tempo, so a built-in "
                        + "uses it only as a short slapback of at most \(Int(maxSlapbackMs)) ms")
                }
                if isReturnBus, EffectParamSpec.specs(for: effect.kind).contains(where: { $0.name == "mix" }),
                   let mix = effect.paramValue("mix"), mix != 1 {
                    say("\(insertPath).params.mix", "a return bus is 100% wet (mix 1), so a send adds the "
                        + "effect without a second dry copy; this one reads \(mix)")
                }
            }
            // Rule 5.
            for (position, source) in built.modulationSources.enumerated() {
                if case .lfo(let lfo) = source.params,
                   lfo.syncDivision != nil || lfo.rateHz > maxLFORateHz {
                    say("\(path).modulation.sources[\(position)].params.rateHz", "a built-in's LFO is a slow "
                        + "sweep or breath, at most \(maxLFORateHz) Hz, never a rhythmic pulse")
                }
            }
            if spec.kind == .bus, !sentTo.contains(spec.key), !playsInto.contains(spec.key) {
                say(path, "nothing plays or sends into the bus '\(spec.name)', so it would sit there silent")
            }
        }
        return problems
    }

    /// The catalog genres no template lists — each would have no default template.
    static func genresWithoutATemplate(_ templates: [TrackSetTemplate]) -> [String] {
        SongSkeletonCatalog.names.filter { genre in !templates.contains { $0.genres.contains(genre) } }
    }

    // MARK: - The folder is the catalog

    @Test("m39-tpl-3: the shipped folder holds exactly the ten catalog files, and every id is unique")
    func theFolderHoldsExactlyTheCatalog() throws {
        let ids = BuiltInTemplateCatalog.ids
        #expect(ids.count == 10)
        #expect(Set(ids).count == ids.count, "an id is listed twice: \(ids)")
        let found = Set(try Self.shippedFiles().map(\.name))
        let expected = Set(ids.map { "\($0).\(BuiltInTemplateCatalog.fileExtension)" })
        #expect(found == expected, """
            files the catalog does not list: \(found.subtracting(expected).sorted()); \
            catalog ids with no file: \(expected.subtracting(found).sorted())
            """)
    }

    // MARK: - Every built-in obeys the rules

    @Test("m39-tpl-3: every built-in decodes, plans with zero warnings, and obeys §7.1's seven rules")
    func everyBuiltInObeysTheRules() throws {
        let files = try Self.shippedFiles()
        #expect(files.count == 10, "expected the ten built-ins; found \(files.count)")
        var checkedTracks = 0
        for (name, data) in files {
            for problem in Self.problems(name, data) {
                Issue.record("\(problem)")
            }
            checkedTracks += (try? TrackSetTemplateCodec.decode(data, origin: .file))?.template.tracks.count ?? 0
        }
        // ANTI-VACUITY: ten templates of six or seven tracks each.
        #expect(checkedTracks >= 60, "expected at least 60 tracks across the built-ins; saw \(checkedTracks)")
    }

    // MARK: - Every genre has its default

    @Test("m39-tpl-3: every catalog genre has its default template (§7.1), and each template is its song form's default")
    func everyGenreHasItsDefaultTemplate() throws {
        let listing = BuiltInTemplateCatalog.load()
        let templates = listing.templates.map(\.template)
        #expect(Self.genresWithoutATemplate(templates).isEmpty, """
            these genres have no built-in template, because no built-in's `genres` lists them: \
            \(Self.genresWithoutATemplate(templates)) (files: \(listing.templates.map(\.fileName)))
            """)
        #expect(Set(Self.expectedDefaults.keys) == Set(SongSkeletonCatalog.names))
        for genre in SongSkeletonCatalog.names {
            let found = BuiltInTemplateCatalog.defaultTemplateID(forGenre: genre, in: listing.templates)
            #expect(found == Self.expectedDefaults[genre],
                    "the default template for '\(genre)' is \(found ?? "none"), not \(Self.expectedDefaults[genre] ?? "?")")
        }
        for entry in listing.templates {
            let form = try #require(entry.template.songForm, "\(entry.fileName) has no song form")
            #expect(BuiltInTemplateCatalog.defaultTemplateID(forGenre: form, in: listing.templates) == entry.id,
                    "\(entry.fileName): its song form '\(form)' offers a different template by default")
        }
    }

    // MARK: - The loader

    @Test("m39-tpl-3: the loader offers every built-in in catalog order, unique names, and nothing unreadable")
    func theLoaderOffersEveryBuiltIn() throws {
        let listing = BuiltInTemplateCatalog.load()
        #expect(listing.unreadable.isEmpty, "unreadable: \(listing.unreadable)")
        #expect(listing.templates.map(\.id) == BuiltInTemplateCatalog.ids)
        let names = listing.templates.map(\.template.name)
        #expect(Set(names).count == names.count, "two built-ins share a name: \(names)")
        for entry in listing.templates {
            let direct = try TrackSetTemplateCodec.decode(try Self.shippedFile(entry.id), origin: .file)
            #expect(entry.template == direct.template, "\(entry.fileName) loads differently from its bytes")
        }
    }

    @Test("m39-tpl-3: a built-in that cannot be read is LISTED with its reason, never skipped (§7.3)")
    func theLoaderNeverSkipsSilently() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tpl3-builtins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, data) in try Self.shippedFiles() {
            try data.write(to: folder.appendingPathComponent(name))
        }
        // One cut short, one missing, one stray.
        let cut = "house-club.\(BuiltInTemplateCatalog.fileExtension)"
        try Data(try Self.shippedFile("house-club").prefix(40)).write(to: folder.appendingPathComponent(cut))
        try FileManager.default.removeItem(
            at: folder.appendingPathComponent("jazz-combo.\(BuiltInTemplateCatalog.fileExtension)"))
        try Self.shippedFile("pop-band").write(
            to: folder.appendingPathComponent("stray.\(BuiltInTemplateCatalog.fileExtension)"))

        let listing = BuiltInTemplateCatalog.load(from: folder)
        #expect(listing.templates.count == 8)
        #expect(listing.unreadable.map(\.file) == [
            "house-club.dawtemplate", "jazz-combo.dawtemplate", "stray.dawtemplate",
        ])
        for entry in listing.unreadable {
            #expect(!entry.message.isEmpty, "\(entry.file) is listed with no reason")
        }
        // The control: the intact copy reads clean.
        try Self.shippedFile("house-club").write(to: folder.appendingPathComponent(cut))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("stray.dawtemplate"))
        try Self.shippedFile("jazz-combo").write(
            to: folder.appendingPathComponent("jazz-combo.\(BuiltInTemplateCatalog.fileExtension)"))
        #expect(BuiltInTemplateCatalog.load(from: folder).unreadable.isEmpty)
    }

    // MARK: - The checker can fail

    /// One planted defect: in the shipped file `id`, `old` (exactly once) becomes `new`.
    struct Plant: Sendable {
        let label: String
        let id: String
        let old: String
        let new: String
        /// A path the checker's sentence must name.
        let path: String
    }

    static let plants: [Plant] = [
        Plant(label: "a drum machine in the pad layout", id: "hip-hop-808",
              old: #""drumPreset": "808", "drumKit": { "noteLayout": "gm", "gain": 1 }"#,
              new: #""drumPreset": "808", "drumKit": { "noteLayout": "pads", "gain": 1 }"#,
              path: "tracks[0].instrument.drumKit.noteLayout"),
        Plant(label: "an Audio Unit insert", id: "rock-band",
              old: #""inserts": [ { "kind": "reverb", "params": { "mix": 1, "roomSize": 0.45 } } ]"#,
              new: #""inserts": [ { "kind": "audioUnit", "audioUnit": { "subType": "tpl3", "#
                + #""manufacturer": "tpl3" } }, { "kind": "reverb", "params": { "mix": 1, "roomSize": 0.45 } } ]"#,
              path: "tracks[6].inserts[0].kind"),
        Plant(label: "a vocal typed as an instrument", id: "pop-band",
              old: #""name": "Lead Vocal", "kind": "audio""#,
              new: #""name": "Lead Vocal", "kind": "instrument""#,
              path: "tracks[4].kind"),
        Plant(label: "an unknown effect setting", id: "reggae-riddim",
              old: #""feedback": 0.6"#, new: #""feedbak": 0.6"#,
              path: "tracks[4].inserts[0].params.feedbak"),
        Plant(label: "an echo that ignores the tempo", id: "reggae-riddim",
              old: #""sync": 1"#, new: #""sync": 0"#,
              path: "tracks[4].inserts[0].params.sync"),
        Plant(label: "a return bus that is not fully wet", id: "hip-hop-808",
              old: #""mix": 1, "roomSize": 0.4"#, new: #""mix": 0.5, "roomSize": 0.4"#,
              path: "tracks[5].inserts[0].params.mix"),
        Plant(label: "a fast, pulsing LFO", id: "lofi-chill",
              old: #""rateHz": 0.25"#, new: #""rateHz": 4"#,
              path: "tracks[2].modulation.sources[0].params.rateHz"),
        Plant(label: "a two-sentence summary", id: "soul-blues",
              old: "like a wah pedal.", new: "like a wah pedal. Try it.", path: "summary"),
        Plant(label: "a bus nothing feeds", id: "piano-ballad",
              old: #"{ "key": "hall", "name": "Hall", "kind": "bus","#,
              new: #"{ "key": "spare", "name": "Spare", "kind": "bus" }, { "key": "hall", "name": "Hall", "kind": "bus","#,
              path: "tracks[5]"),
    ]

    @Test("m39-tpl-3: the rule checker catches every planted defect, naming the file and the path")
    func theRuleCheckerCatchesEveryPlantedDefect() throws {
        for plant in Self.plants {
            let fileName = "\(plant.id).\(BuiltInTemplateCatalog.fileExtension)"
            let text = String(decoding: try Self.shippedFile(plant.id), as: UTF8.self)
            let count = text.components(separatedBy: plant.old).count - 1
            guard count == 1 else {
                Issue.record("\(plant.label): the anchor occurs \(count) times in \(fileName), not once")
                continue
            }
            // The control: the unplanted file has no problem.
            #expect(Self.problems(fileName, Data(text.utf8)).isEmpty, "\(plant.label): \(fileName) is not clean")
            let planted = Self.problems(fileName, Data(text.replacingOccurrences(of: plant.old,
                                                                                with: plant.new).utf8))
            #expect(planted.contains { $0.hasPrefix("\(fileName): \(plant.path)") },
                    "\(plant.label): expected a problem at \(fileName): \(plant.path); got \(planted)")
        }
        // A genre with no template: acoustic-folk stops listing country.
        let folk = String(decoding: try Self.shippedFile("acoustic-folk"), as: UTF8.self)
        let old = #""genres": ["folk", "country"]"#
        #expect(folk.components(separatedBy: old).count - 1 == 1)
        var templates = BuiltInTemplateCatalog.load().templates.map(\.template)
        #expect(Self.genresWithoutATemplate(templates).isEmpty)
        let planted = try TrackSetTemplateCodec.decode(
            Data(folk.replacingOccurrences(of: old, with: #""genres": ["folk"]"#).utf8), origin: .file)
        templates = templates.map { $0.id == "acoustic-folk" ? planted.template : $0 }
        #expect(Self.genresWithoutATemplate(templates) == ["country"])
    }
}
