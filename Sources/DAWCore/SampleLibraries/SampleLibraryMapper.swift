import Foundation

/// Structured import-pipeline refusals (m19-c). Every message is a readable,
/// actionable sentence — the control protocol and the app panel surface
/// `errorDescription` verbatim. Copy law: user-facing strings say "imports
/// .sfz (documented subset) and .dspreset sample-library files" — never a
/// product-compatibility claim.
public enum SampleLibraryImportError: Error, LocalizedError, Equatable {
    /// Wrong extension entirely (not .sfz/.dspreset/.dslibrary).
    case notASampleLibrary(fileName: String)
    /// `.dslibrary` — v1 scope cut with the one-line workaround (§2.3).
    case dslibraryIsZipArchive
    /// The library file itself is missing.
    case fileNotFound(path: String)
    /// Referenced samples exceed the 4 GB import limit (§5.5) and `force`
    /// was not passed. The error names the limit AND the flag.
    case libraryTooLarge(totalSampleBytes: Int64)
    /// Apply-mode parse yielded ZERO playable zones — never a silent empty
    /// instrument (§2.3). Carries the full report; the message summarizes
    /// its skip reasons so a plain error string still tells the story.
    case noPlayableZones(SampleLibraryImportReport)

    public var errorDescription: String? {
        switch self {
        case .notASampleLibrary(let fileName):
            return "\(fileName) is not a sample library — this build imports .sfz (documented subset) and .dspreset sample-library files"
        case .dslibraryIsZipArchive:
            // Exact wording is contract (§2.3; tests + MCP surface it verbatim).
            return ".dslibrary is a zip archive — unzip it and import the .dspreset inside"
        case .fileNotFound(let path):
            return "no sample library file at \(path)"
        case .libraryTooLarge(let bytes):
            let gb = Double(bytes) / 1_000_000_000
            return String(format: "sample library references %.1f GB of samples — imports over the 4 GB limit are refused; pass force: true to import anyway", gb)
        case .noPlayableZones(let report):
            var reasons = report.skippedRegions
                .sorted { $0.key < $1.key }
                .map { "\($0.key) ×\($0.value)" }
                .joined(separator: ", ")
            if reasons.isEmpty { reasons = "the file defines no regions" }
            return "import found no playable zones — \(reasons); nothing was applied (run with dryRun to inspect the full report)"
        }
    }
}

/// The structured import report (m19-c, design §5.5) — the §2.3 honesty
/// surface: every degradation decision lands here, in machine-readable
/// tallies plus human sentences. Returned by dry runs AND applies; the wire
/// command emits it as JSON verbatim.
public struct SampleLibraryImportReport: Codable, Sendable, Equatable {
    /// §5.5 names the nested type `Format`; the shared top-level enum keeps
    /// the IR and the report on one definition.
    public typealias Format = SampleLibraryFormat

    public var format: Format
    public var zonesImported: Int
    /// Distinct layering groups among the imported zones (§5.3 IDs).
    public var groupCount: Int
    /// Distinct effective velocity spans among the imported zones.
    public var velocityLayerCount: Int
    /// Skip reason → region count (`"trigger=release": 49`). Skipped regions
    /// are regions the import REFUSED (playing them would be wrong sound);
    /// their opcodes are not tallied in `ignoredOpcodes`.
    public var skippedRegions: [String: Int]
    /// Out-of-subset opcode → occurrence count across IMPORTED zones
    /// (`"cutoff": 43` — one count per region whose effective, inherited
    /// opcode set carries it). The region still plays; the opcode is dropped.
    public var ignoredOpcodes: [String: Int]
    /// Human sentences (the Sampler loadNotes idiom): loop degradation,
    /// keyswitch reduction, missing files, size warnings.
    public var degradations: [String]
    /// Imported zones that will actually loop (m20-g): sustain + continuous,
    /// including smpl-fallback loops. 0 for loop-free libraries.
    public var loopedZones: Int
    /// Total bytes of the UNIQUE sample files the imported zones reference
    /// (what instrument load reads and a project save copies).
    public var totalSampleBytes: Int64

    public init(format: Format, zonesImported: Int = 0, groupCount: Int = 0,
                velocityLayerCount: Int = 0, skippedRegions: [String: Int] = [:],
                ignoredOpcodes: [String: Int] = [:], degradations: [String] = [],
                loopedZones: Int = 0, totalSampleBytes: Int64 = 0) {
        self.format = format
        self.zonesImported = zonesImported
        self.groupCount = groupCount
        self.velocityLayerCount = velocityLayerCount
        self.skippedRegions = skippedRegions
        self.ignoredOpcodes = ignoredOpcodes
        self.degradations = degradations
        self.loopedZones = loopedZones
        self.totalSampleBytes = totalSampleBytes
    }
}

/// IR → (`SamplerParams`, `SampleLibraryImportReport`). The ENTIRE §2.3
/// degradation policy lives HERE and only here (design §5.1): skip rules,
/// keyswitch reduction, ignored-opcode counting, group-ID assignment,
/// dB→linear, unit scaling onto the m19-a/b zone fields, missing-file
/// pre-check (existence only — NO audio decode at this layer), byte
/// accounting with the 500 MB warn / 4 GB refuse gates.
public enum SampleLibraryMapper {
    /// ≥ this many referenced sample bytes adds a degradation warning.
    public static let warnSampleBytes: Int64 = 500_000_000
    /// > this refuses the import unless `force` (§5.5).
    public static let maxSampleBytes: Int64 = 4_000_000_000
    /// Per-file degradation notes (missing/undecodable) list at most this
    /// many paths before folding into an "… and N more" line.
    static let maxPerFileNotes = 12

    public static func map(_ ir: SampleLibraryIR, force: Bool = false) throws
        -> (params: SamplerParams, report: SampleLibraryImportReport) {
        var skipped: [String: Int] = [:]
        var ignoredTally: [String: Int] = ir.ignoredHeaders
        var degradations: [String] = []

        // Keyswitch reduction (§2.3): keep ONLY the articulation matching
        // sw_default (else the lowest sw_last key seen) — importing every
        // articulation would layer them simultaneously, a lie about the
        // instrument. One global pass decides the kept key.
        let switchedRegions = ir.regions.filter { $0.swLast != nil }
        var keptKeyswitch: Int?
        if !switchedRegions.isEmpty {
            let lastKeys = Set(switchedRegions.compactMap(\.swLast))
            let preferred = switchedRegions.compactMap(\.swDefault)
                .first(where: { lastKeys.contains($0) })
            keptKeyswitch = preferred ?? lastKeys.min()
        }

        var zones: [SamplerZone] = []
        var loopedZoneCount = 0        // m20-g: counts REAL loops (sustain + continuous)
        var invalidLoopCount = 0       // §2.2 invalid-bounds degradation
        var pointsWithoutModeCount = 0 // §2.2 points-without-mode degradation
        // Per-file smpl-loop cache for the duration of ONE map() call — big
        // SFZs reference one WAV from hundreds of regions (§2.3).
        var smplCache: [String: WAVSampleLoops.Loop?] = [:]
        func smplLoop(for url: URL) -> WAVSampleLoops.Loop? {
            if let cached = smplCache[url.path] { return cached }
            let loop = WAVSampleLoops.firstForwardLoop(in: url)
            smplCache[url.path] = loop
            return loop
        }
        var keyswitchSkipped = 0
        var escapedPathCount = 0
        // <group>-header ordinal → assigned model group ID. IDs start at 1:
        // implicit group 0 is RESERVED for hand-built/legacy zones (§5.3 —
        // the importer never emits group == nil).
        var groupIDs: [Int: Int] = [:]
        var nextGroupID = 1
        // Unique-file accounting (ordered, for stable notes).
        var countedFiles: Set<String> = []
        var totalBytes: Int64 = 0
        var missingFiles: [String] = []
        var missingSeen: Set<String> = []
        var oggFiles: [String] = []
        var oggSeen: Set<String> = []

        for region in ir.regions {
            // — §2.3 skip rules, reason-coded. A skipped region's opcodes are
            //   NOT tallied (skippedRegions already tells its story). —
            if let trigger = region.trigger, trigger != "attack" {
                skipped["trigger=\(trigger)", default: 0] += 1
                continue
            }
            if region.ccTriggered {
                skipped["cc-triggered (on_loccN)", default: 0] += 1
                continue
            }
            if let kept = keptKeyswitch, let sw = region.swLast, sw != kept {
                skipped["keyswitch articulation", default: 0] += 1
                keyswitchSkipped += 1
                continue
            }
            if let end = region.endFrame, end < 0 {
                // SFZ `end=-1` means "this region does not play".
                skipped["end=-1 (sample disabled)", default: 0] += 1
                continue
            }
            guard let sample = region.samplePath, !sample.isEmpty else {
                skipped["no sample opcode", default: 0] += 1
                continue
            }
            let resolved = SampleLibraryPath.resolve(
                sample: sample, defaultPath: region.defaultPath,
                baseDirectory: ir.baseDirectory)
            if resolved.escapesBaseDirectory { escapedPathCount += 1 }
            if resolved.url.pathExtension.lowercased() == "ogg" {
                // Core Audio cannot decode Ogg Vorbis — same honesty path as
                // a missing file (§2.3), pre-checked where the user can act.
                skipped["unsupported sample format (.ogg)", default: 0] += 1
                if oggSeen.insert(resolved.url.path).inserted {
                    oggFiles.append(resolved.url.path)
                }
                continue
            }
            guard FileManager.default.fileExists(atPath: resolved.url.path) else {
                skipped["sample file missing", default: 0] += 1
                if missingSeen.insert(resolved.url.path).inserted {
                    missingFiles.append(resolved.url.path)
                }
                continue
            }

            // — byte accounting (unique files; existence-only, no decode) —
            if countedFiles.insert(resolved.url.path).inserted {
                let attrs = try? FileManager.default.attributesOfItem(
                    atPath: resolved.url.path)
                if let size = attrs?[.size] as? NSNumber {
                    totalBytes += size.int64Value
                }
            }

            // — m20-g loops: precedence (opcodes > smpl > defaults), validity,
            //   honesty (§2.3). The smpl fallback is the SFZ-specified default:
            //   consulted only when mode is unauthored, or a loop mode misses a
            //   point; authored opcodes win PER FIELD. An explicit no_loop
            //   suppresses the fallback entirely. —
            var mode = region.loopMode          // parser-normalized lowercase string
            var lsIncl = region.loopStartFrame
            var leIncl = region.loopEndFrame
            let isLoopMode = mode == "loop_continuous" || mode == "loop_sustain"
            if mode == nil || (isLoopMode && (lsIncl == nil || leIncl == nil)),
               ["wav", "wave"].contains(resolved.url.pathExtension.lowercased()) {
                if let smpl = smplLoop(for: resolved.url) {
                    if mode == nil { mode = "loop_continuous" } // the sfzformat default law
                    if lsIncl == nil { lsIncl = smpl.startFrame }
                    if leIncl == nil { leIncl = smpl.endFrameInclusive }
                }
            }
            var loopMode: SamplerLoopMode? = nil
            var loopStartOut: Int? = nil
            var loopEndOut: Int? = nil
            switch mode {
            case "loop_continuous", "loop_sustain":
                let invalid = (lsIncl.map { $0 < 0 } ?? false)
                    || (leIncl.map { $0 < 0 } ?? false)
                    || (lsIncl != nil && leIncl != nil && leIncl! < lsIncl!)
                    || (lsIncl != nil && region.endFrame != nil && region.endFrame! >= 0
                        && lsIncl! > region.endFrame!)
                if invalid {
                    invalidLoopCount += 1               // → degradation sentence §2.2
                } else {
                    loopMode = mode == "loop_sustain" ? .sustain : .continuous
                    loopStartOut = lsIncl
                    loopEndOut = leIncl.map { $0 + 1 }  // THE +1 LAW (== end→endFrame+1)
                    loopedZoneCount += 1                // now counts REAL loops
                }
            case "one_shot", "no_loop", nil:
                if mode == nil, lsIncl != nil || leIncl != nil {
                    pointsWithoutModeCount += 1         // → degradation sentence §2.2
                }
            default:
                // Unrecognized loop_mode value — NEW honesty: tallied, never
                // silently dropped. The zone imports unlooped.
                ignoredTally["loop_mode", default: 0] += 1
            }

            // — group-ID assignment (§5.3): each <group> header = one fresh
            //   ID in file order; ungrouped regions each get their OWN
            //   unique ID (SFZ semantics: independent regions layer) —
            let groupID: Int
            if let ordinal = region.groupIndex {
                if let existing = groupIDs[ordinal] {
                    groupID = existing
                } else {
                    groupID = nextGroupID
                    groupIDs[ordinal] = groupID
                    nextGroupID += 1
                }
            } else {
                groupID = nextGroupID
                nextGroupID += 1
            }

            // — ignored-opcode tally (imported regions only) —
            for name in region.ignored {
                ignoredTally[name, default: 0] += 1
            }

            // — unit mapping onto the m19-a/b zone fields; the model init
            //   re-clamps everything to its documented ranges —
            let gain: Double
            if let db = region.volumeDB {
                gain = pow(10, db / 20)  // dB → linear; A5 relaxed 0...2
            } else {
                gain = region.gainLinear ?? 1
            }
            let tuneCents: Double?
            if region.tuneCents != nil || region.transposeSemitones != nil {
                tuneCents = Double(region.transposeSemitones ?? 0) * 100
                    + (region.tuneCents ?? 0)
            } else {
                tuneCents = nil
            }
            zones.append(SamplerZone(
                audioFileURL: resolved.url,
                rootPitch: region.keyCenter ?? 60,
                minPitch: region.loKey ?? 0,
                maxPitch: region.hiKey ?? 127,
                gain: gain,
                minVelocity: region.loVel,
                maxVelocity: region.hiVel,
                group: groupID,
                seqLength: region.seqLength,
                seqPosition: region.seqPosition,
                randMin: region.randLo,
                randMax: region.randHi,
                tuneCents: tuneCents,
                pan: region.pan.map { $0 / 100 },              // −100…100 → −1…1
                ampVelTrack: region.ampVelTrackPercent.map { $0 / 100 },
                oneShot: region.loopMode == "one_shot" ? true : nil,
                startFrame: region.offsetFrames,
                endFrame: region.endFrame.map { $0 + 1 },      // inclusive → exclusive
                attack: region.attackSeconds,
                decay: region.decaySeconds,
                sustain: region.sustainPercent.map { $0 / 100 },
                release: region.releaseSeconds,
                loopMode: loopMode,
                loopStart: loopStartOut,
                loopEnd: loopEndOut
            ))
        }

        // — degradation sentences (the loadNotes idiom) —
        if invalidLoopCount > 0 {
            degradations.append(
                "\(invalidLoopCount) zone\(invalidLoopCount == 1 ? "" : "s") author invalid loop bounds (loop end before loop start, or outside the playable span) — imported without looping")
        }
        if pointsWithoutModeCount > 0 {
            degradations.append(
                "\(pointsWithoutModeCount) zone\(pointsWithoutModeCount == 1 ? "" : "s") author loop points without a loop mode and their samples embed no smpl loop — imported without looping (the SFZ default)")
        }
        if keyswitchSkipped > 0 {
            degradations.append(
                "keyswitch articulations reduced to default; \(keyswitchSkipped) region\(keyswitchSkipped == 1 ? "" : "s") skipped")
        }
        degradations += perFileNotes(prefix: "sample file missing",
                                     files: missingFiles)
        degradations += perFileNotes(prefix: "cannot decode .ogg sample",
                                     files: oggFiles)
        if escapedPathCount > 0 {
            degradations.append(
                "\(escapedPathCount) sample path\(escapedPathCount == 1 ? "" : "s") resolve outside the library folder (e.g. ../Samples) — imported from the resolved location")
        }
        if totalBytes >= warnSampleBytes {
            let mb = totalBytes / 1_000_000
            degradations.append(
                "large sample library: \(mb) MB of samples referenced — instrument load reads all of it and a project save copies it into the bundle; expect delays")
        }
        if totalBytes > maxSampleBytes, !force {
            throw SampleLibraryImportError.libraryTooLarge(totalSampleBytes: totalBytes)
        }

        let report = SampleLibraryImportReport(
            format: ir.format == .sfz ? .sfz : .dspreset,
            zonesImported: zones.count,
            groupCount: Set(zones.compactMap(\.group)).count,
            velocityLayerCount: Set(zones.map {
                "\($0.minVelocity ?? 0)-\($0.maxVelocity ?? 127)"
            }).count,
            skippedRegions: skipped,
            ignoredOpcodes: ignoredTally,
            degradations: degradations,
            loopedZones: loopedZoneCount,
            totalSampleBytes: totalBytes
        )
        return (SamplerParams(zones: zones), report)
    }

    /// One note per file, capped at `maxPerFileNotes` + an honest remainder.
    private static func perFileNotes(prefix: String, files: [String]) -> [String] {
        guard !files.isEmpty else { return [] }
        var notes = files.prefix(maxPerFileNotes).map { "\(prefix): \($0)" }
        if files.count > maxPerFileNotes {
            notes.append("… and \(files.count - maxPerFileNotes) more \(prefix) file\(files.count - maxPerFileNotes == 1 ? "" : "s")")
        }
        return notes
    }
}
