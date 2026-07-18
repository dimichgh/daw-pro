import Foundation

/// `.dspreset` parser aborts (m19-d, design §5.1). Every case is a
/// structured, LocalizedError-readable refusal naming the exact file — the
/// SFZPreprocessorError voice. Only MALFORMED input aborts; a recognized
/// attribute whose value fails to parse degrades to the region's `ignored`
/// list instead (the tolerant-but-reporting posture SFZParser shares).
public enum DSPresetParserError: Error, LocalizedError, Equatable {
    /// The file exists but could not be read.
    case unreadableFile(path: String)
    /// The XML does not parse (unclosed tags, entity garbage, …). Carries
    /// Foundation's own diagnostic so the author can find the line.
    case malformedXML(path: String, detail: String)
    /// Well-formed XML whose root element is not `<DecentSampler>` — a
    /// mis-renamed file, not a preset.
    case wrongRootElement(found: String, path: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let path):
            return "cannot read .dspreset XML at \(path)"
        case .malformedXML(let path, let detail):
            return "malformed .dspreset XML in \(path): \(detail)"
        case .wrongRootElement(let found, let path):
            return "\(path) is not a DecentSampler preset — the root element is <\(found)>, expected <DecentSampler>"
        }
    }
}

/// The `.dspreset` XML parser (m19-d, design §5.1) — Foundation
/// `XMLDocument` onto the SAME format-neutral `SampleLibraryIR` the SFZ
/// parser targets, so `SampleLibraryMapper` (the ONE home of the §2.3
/// degradation policy) never knows which text format a region came from.
/// Import-time allocation is fine — nothing here touches the render thread
/// (the SoundFontPresetReader headless precedent). There is NO preprocessor
/// step: a `.dspreset` is one self-contained XML file (RES §3.1).
///
/// Shape (RES §3.1): `<DecentSampler>` → `<groups>` → `<group>` →
/// `<sample>`. Inheritance is an attribute-level dictionary merge, nearest
/// wins: `<groups>` attributes are instrument-wide defaults, `<group>`
/// overrides them, `<sample>` overrides both. Each `<group>` ELEMENT is one
/// fresh `groupIndex` ordinal in document order (design §5.3); a `<sample>`
/// sitting directly under `<groups>` (tolerated, not the documented shape)
/// gets `groupIndex` nil and the mapper assigns it its own unique group ID.
///
/// `<ui>`/`<midi>`/`<effects>` siblings are UI-only chrome, ignored BY
/// DESIGN — "load the preset as authored" (RES §3.3) — but counted into
/// `ignoredHeaders` so nothing is dropped silently (§2.3).
///
/// Native → neutral unit conversions owned HERE (the IR's field docs):
/// `tuning` semitones → cents (×100); `ampVelTrack` 0…1 fraction → percent
/// (×100); `sustain` 0…1 fraction → percent (×100); `volume` splits into
/// `gainLinear` (plain number) vs `volumeDB` (`dB`-suffixed, §2.2);
/// `end` is INCLUSIVE like SFZ `end` (the mapper does the +1);
/// `loopEnabled="true"` becomes loopMode `loop_continuous` and
/// `loopStart`/`loopEnd` (frames, end inclusive) carry the loop points —
/// real looping playback since m20-g. `loopEnabled="false"` records
/// `no_loop` so the explicit author intent suppresses the WAV `smpl`
/// fallback in the mapper (§2.3).
public enum DSPresetParser {
    /// Parses a `.dspreset` file into the IR. Sample paths resolve against
    /// the PRESET file's directory (design §5.2), carried as
    /// `baseDirectory`; `defaultPath` stays nil (`.dspreset` has no
    /// `default_path` equivalent).
    public static func parse(fileAt url: URL) throws -> SampleLibraryIR {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw DSPresetParserError.unreadableFile(path: url.path)
        }
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data)
        } catch {
            throw DSPresetParserError.malformedXML(
                path: url.path, detail: error.localizedDescription)
        }
        guard let root = document.rootElement() else {
            throw DSPresetParserError.malformedXML(
                path: url.path, detail: "the document has no root element")
        }
        let rootName = root.name ?? ""
        guard rootName.lowercased() == "decentsampler" else {
            throw DSPresetParserError.wrongRootElement(
                found: rootName, path: url.path)
        }

        var regions: [SampleLibraryIR.Region] = []
        var ignoredHeaders: [String: Int] = [:]
        // Group ordinals run in DOCUMENT order across the whole file — if a
        // tolerated second <groups> element appears, its <group>s continue
        // the sequence (each <group> element is one identity, §5.3).
        var groupOrdinal = -1

        for child in childElements(of: root) {
            let name = (child.name ?? "").lowercased()
            switch name {
            case "groups":
                let instrumentDefaults = attributeMap(of: child)
                for element in childElements(of: child) {
                    let elementName = (element.name ?? "").lowercased()
                    switch elementName {
                    case "group":
                        groupOrdinal += 1
                        let groupAttributes = merge(
                            instrumentDefaults, attributeMap(of: element))
                        for sampleElement in childElements(of: element) {
                            let sampleName = (sampleElement.name ?? "").lowercased()
                            guard sampleName == "sample" else {
                                ignoredHeaders["<\(sampleName)>", default: 0] += 1
                                continue
                            }
                            regions.append(makeRegion(
                                from: merge(groupAttributes,
                                            attributeMap(of: sampleElement)),
                                groupIndex: groupOrdinal))
                        }
                    case "sample":
                        // Tolerated: a sample outside any <group> inherits
                        // the <groups> defaults and stays ungrouped (the
                        // mapper gives it its own unique group ID).
                        regions.append(makeRegion(
                            from: merge(instrumentDefaults,
                                        attributeMap(of: element)),
                            groupIndex: nil))
                    default:
                        ignoredHeaders["<\(elementName)>", default: 0] += 1
                    }
                }
            default:
                // <ui>, <effects>, <midi>, <tags>, <noteSequences>, … —
                // skipped wholesale but COUNTED (§2.3: surface degradation,
                // never silently lie).
                ignoredHeaders["<\(name)>", default: 0] += 1
            }
        }

        return SampleLibraryIR(format: .dspreset,
                               baseDirectory: url.deletingLastPathComponent(),
                               regions: regions,
                               ignoredHeaders: ignoredHeaders)
    }

    // MARK: - XML helpers

    /// One attribute as authored: canonical spelling kept for honest
    /// `ignored` reporting; lookups use the lowercased dictionary key.
    private typealias Attribute = (name: String, value: String)

    private static func childElements(of element: XMLElement) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }
    }

    /// lowercased-name → (original name, value). XML attribute names are
    /// case-sensitive in principle, but real-world `.dspreset` authors vary
    /// casing — case-insensitive lookup is tolerance, original spelling is
    /// preserved for the report.
    private static func attributeMap(of element: XMLElement) -> [String: Attribute] {
        var map: [String: Attribute] = [:]
        for node in element.attributes ?? [] {
            guard let name = node.name, let value = node.stringValue else { continue }
            map[name.lowercased()] = (name: name, value: value)
        }
        return map
    }

    /// Nearest wins — `overrides` beats `base`, attribute by attribute.
    private static func merge(_ base: [String: Attribute],
                              _ overrides: [String: Attribute]) -> [String: Attribute] {
        base.merging(overrides) { _, nearest in nearest }
    }

    // MARK: - Effective sample → IR region

    /// Attributes consumed into typed IR fields; everything else lands in
    /// the region's `ignored` list (original spelling) for the mapper's
    /// tally — except CC-trigger attributes, which set the §2.3 skip input.
    private static func makeRegion(from merged: [String: Attribute],
                                   groupIndex: Int?) -> SampleLibraryIR.Region {
        var region = SampleLibraryIR.Region(groupIndex: groupIndex)
        var ignored: [String] = []

        /// Consumes `key` with `parse`; an unparseable value degrades to the
        /// ignored list under its ORIGINAL spelling (never aborts —
        /// tolerant-but-reporting, §7 risk 3).
        func take<T>(_ key: String, _ parse: (String) -> T?,
                     into keyPath: WritableKeyPath<SampleLibraryIR.Region, T?>) {
            guard let attribute = merged[key] else { return }
            if let value = parse(attribute.value) {
                region[keyPath: keyPath] = value
            } else {
                ignored.append(attribute.name)
            }
        }

        region.samplePath = merged["path"]?.value

        // Pitch values accept MIDI numbers AND note names (SFZSyntax's
        // c-1…g9 reader) — number spellings dominate real files (RES §3.5).
        take("rootnote", SFZSyntax.midiPitch, into: \.keyCenter)
        take("lonote", SFZSyntax.midiPitch, into: \.loKey)
        take("hinote", SFZSyntax.midiPitch, into: \.hiKey)
        take("lovel", SFZSyntax.integer, into: \.loVel)
        take("hivel", SFZSyntax.integer, into: \.hiVel)

        // volume: linear when a plain number, dB when suffixed (§2.2 —
        // "volume (linear or dB suffix)"). The two IR fields are mutually
        // exclusive; the mapper prefers volumeDB when both are somehow set.
        if let volume = merged["volume"] {
            let raw = volume.value.trimmingCharacters(in: .whitespaces)
            if raw.lowercased().hasSuffix("db") {
                if let db = SFZSyntax.number(from: raw, allowDBSuffix: true) {
                    region.volumeDB = db
                } else {
                    ignored.append(volume.name)
                }
            } else if let linear = Double(raw) {
                region.gainLinear = linear
            } else {
                ignored.append(volume.name)
            }
        }
        take("pan", { SFZSyntax.number(from: $0) }, into: \.pan)
        // tuning is fractional SEMITONES; the IR field is cents.
        if let tuning = merged["tuning"] {
            if let semitones = SFZSyntax.number(from: tuning.value) {
                region.tuneCents = semitones * 100
            } else {
                ignored.append(tuning.name)
            }
        }
        // ampVelTrack is a 0…1 fraction natively; the IR field is a percent
        // (SFZ `amp_veltrack` native units — the parser owns the ×100).
        if let velTrack = merged["ampveltrack"] {
            if let fraction = SFZSyntax.number(from: velTrack.value) {
                region.ampVelTrackPercent = fraction * 100
            } else {
                ignored.append(velTrack.name)
            }
        }
        take("start", SFZSyntax.integer, into: \.offsetFrames)
        // `end` is INCLUSIVE (the SFZ `end` semantics the IR documents; the
        // format author's Kontakt-export tooling emits Kontakt's inclusive
        // last-sample positions, RES §3.5 item 2) — the mapper does the +1.
        take("end", SFZSyntax.integer, into: \.endFrame)
        take("attack", { SFZSyntax.number(from: $0) }, into: \.attackSeconds)
        take("decay", { SFZSyntax.number(from: $0) }, into: \.decaySeconds)
        // sustain is a 0…1 fraction natively; the IR field is a percent.
        if let sustain = merged["sustain"] {
            if let fraction = SFZSyntax.number(from: sustain.value) {
                region.sustainPercent = fraction * 100
            } else {
                ignored.append(sustain.name)
            }
        }
        take("release", { SFZSyntax.number(from: $0) }, into: \.releaseSeconds)
        if let trigger = merged["trigger"] {
            region.trigger = trigger.value
                .trimmingCharacters(in: .whitespaces).lowercased()
        }
        // loopEnabled="true" → loop_continuous, played for real (m20-g).
        // "false"/"0" records the explicit no_loop so the author's intent
        // suppresses the WAV smpl fallback in the mapper (§2.3).
        if let loopEnabled = merged["loopenabled"] {
            switch loopEnabled.value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1":
                region.loopMode = "loop_continuous"
            case "false", "0":
                region.loopMode = "no_loop"
            default:
                ignored.append(loopEnabled.name)
            }
        }
        // m20-g loop points (frames; loopEnd INCLUSIVE — the mapper does
        // the +1). loopCrossfade/loopCrossfadeMode stay UNCONSUMED → the
        // ignored tally (the engine's fixed crossfade policy applies).
        take("loopstart", SFZSyntax.integer, into: \.loopStartFrame)
        take("loopend", SFZSyntax.integer, into: \.loopEndFrame)
        applySequencing(merged, to: &region, ignored: &ignored)

        let consumed: Set<String> = [
            "path", "rootnote", "lonote", "hinote", "lovel", "hivel",
            "volume", "pan", "tuning", "ampveltrack", "start", "end",
            "attack", "decay", "sustain", "release", "trigger",
            "loopenabled", "loopstart", "loopend",
            "seqmode", "seqlength", "seqposition",
            // Cosmetic group metadata with zero playback meaning — consumed
            // silently (tallying it would report a degradation that does
            // not exist).
            "name",
        ]
        for (key, attribute) in merged where !consumed.contains(key) {
            // CC-triggered samples (onLoCCN/onHiCCN) are a §2.3 SKIP input,
            // consumed by the mapper — not an "ignored" attribute.
            if isCCTriggerAttribute(key) {
                region.ccTriggered = true
            } else {
                ignored.append(attribute.name)
            }
        }
        region.ignored = ignored.sorted()
        return region
    }

    /// `seqMode` policy (§2.2 MUST column honors `round_robin`/`random`):
    ///  · absent / `always` (the format default) — the sample plays on every
    ///    trigger; `seqLength`/`seqPosition` are inert in the format too, so
    ///    they are consumed with NO gate and NO tally (honored exactly).
    ///  · `round_robin` — `seqLength`/`seqPosition` pass through to the
    ///    engine's per-region RR counters.
    ///  · `random` / `true_random` — mapped onto the engine's per-note-on
    ///    random draw by partitioning [0,1) into `seqLength` equal spans and
    ///    giving this sample the `seqPosition`-th (the SFZ lorand/hirand
    ///    idiom). The engine's draw is independent per note-on — exactly
    ///    `true_random`; plain `random`'s avoid-immediate-repeat nuance is
    ///    not modeled. Needs BOTH `seqPosition` and `seqLength` (≥ position)
    ///    to build the span; otherwise the mode degrades to `ignored`.
    ///  · anything else — unrecognized value, degrades to `ignored`.
    private static func applySequencing(_ merged: [String: Attribute],
                                        to region: inout SampleLibraryIR.Region,
                                        ignored: inout [String]) {
        guard let mode = merged["seqmode"] else { return }
        switch mode.value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "always":
            break
        case "round_robin":
            if let length = merged["seqlength"] {
                if let value = SFZSyntax.integer(from: length.value) {
                    region.seqLength = value
                } else {
                    ignored.append(length.name)
                }
            }
            if let position = merged["seqposition"] {
                if let value = SFZSyntax.integer(from: position.value) {
                    region.seqPosition = value
                } else {
                    ignored.append(position.name)
                }
            }
        case "random", "true_random":
            if let length = merged["seqlength"].flatMap({ SFZSyntax.integer(from: $0.value) }),
               let position = merged["seqposition"].flatMap({ SFZSyntax.integer(from: $0.value) }),
               length >= 1, (1...length).contains(position) {
                region.randLo = Double(position - 1) / Double(length)
                region.randHi = Double(position) / Double(length)
            } else {
                ignored.append(mode.name)
            }
        default:
            ignored.append(mode.name)
        }
    }

    /// `onLoCCN`/`onHiCCN` (lowercased key, N = digits) — CC-trigger gating.
    private static func isCCTriggerAttribute(_ key: String) -> Bool {
        for prefix in ["onlocc", "onhicc"] where key.hasPrefix(prefix) {
            let suffix = key.dropFirst(prefix.count)
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
        return false
    }
}
