import Foundation

// Sound-bank instrument identity (m10-n). Pure Foundation — DAWCore never
// imports AudioToolbox (LAW L9); the AUSampler that ultimately plays these
// programs is a DAWEngine implementation detail and never appears in the
// model, on the wire, or in the UI.

/// Where a bank file lives. Encodes as ONE string: `"gm"` for the system
/// General MIDI bank (path resolved at USE time, never persisted — LAW L4),
/// or an absolute filesystem path. Decode: `"gm"` → `.generalMIDI`; leading
/// `"/"` → `.file`; anything else → `dataCorrupted` (the forward seam for
/// future sentinels).
public enum SoundBankSource: Codable, Sendable, Equatable, Hashable {
    case generalMIDI
    case file(path: String)

    /// The persistable form — the exact string `encode` writes.
    public var rawString: String {
        switch self {
        case .generalMIDI: return "gm"
        case .file(let path): return path
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "gm" {
            self = .generalMIDI
        } else if raw.hasPrefix("/") {
            self = .file(path: raw)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription:
                "sound bank source must be \"gm\" or an absolute path — got \"\(raw)\"")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawString)
    }
}

/// Persistent, project-file-stable sound-bank instrument identity: an
/// SF2/DLS program address plus the display name captured at selection time.
public struct SoundBankConfig: Codable, Sendable, Equatable {
    public var source: SoundBankSource
    /// MIDI program, 0-BASED 0…127 (program 0 = "Acoustic Grand Piano",
    /// 56 = "Trumpet"). Human GM charts are 1-based; this field is the raw
    /// MIDI byte (R1).
    public var program: Int
    /// Bank select MSB. Default 121 (0x79, the GM melodic convention —
    /// `kAUSampler_DefaultMelodicBankMSB`); 120 (0x78) addresses percussion
    /// kits. Plain Ints by LAW L9.
    public var bankMSB: Int
    /// Bank select LSB, default 0 (`kAUSampler_DefaultBankLSB`).
    public var bankLSB: Int
    /// Cosmetic, captured at selection — e.g. "Trumpet — General MIDI".
    /// NEVER structural: it must not rebuild a node or re-prepare an AU
    /// (LAW L8 — excluded from `Address` by construction).
    public var displayName: String

    /// MIDI byte range shared by `program`/`bankMSB`/`bankLSB`.
    public static let midiValueRange: ClosedRange<Int> = 0...127

    /// The STRUCTURAL identity — everything except the cosmetic
    /// `displayName`. `PlaybackGraph`'s rebuild key and `AUHostRegistry`'s
    /// prepare key both use exactly this (LAW L8).
    public struct Address: Equatable, Hashable, Sendable {
        public let source: SoundBankSource
        public let program: Int
        public let bankMSB: Int
        public let bankLSB: Int

        public init(source: SoundBankSource, program: Int, bankMSB: Int, bankLSB: Int) {
            self.source = source
            self.program = program
            self.bankMSB = bankMSB
            self.bankLSB = bankLSB
        }
    }

    public var address: Address {
        Address(source: source, program: program, bankMSB: bankMSB, bankLSB: bankLSB)
    }

    /// Clamps every MIDI byte into 0…127 (the model-clamping convention,
    /// `PolySynthParams` precedent).
    public init(source: SoundBankSource, program: Int = 0, bankMSB: Int = 121,
                bankLSB: Int = 0, displayName: String = "") {
        self.source = source
        self.program = program.clamped(to: Self.midiValueRange)
        self.bankMSB = bankMSB.clamped(to: Self.midiValueRange)
        self.bankLSB = bankLSB.clamped(to: Self.midiValueRange)
        self.displayName = displayName
    }
}

/// One discoverable sound bank: its persistable source, a display name, the
/// resolved absolute path (transparency), format, whether it is the built-in
/// GM bank, and its byte size (so agents/UI can warn about GB-scale SF2s, R9).
public struct SoundBankInfo: Codable, Sendable, Equatable {
    /// The persistable form: `"gm"` sentinel or the absolute path (LAW L4 —
    /// only this is ever persisted).
    public var source: SoundBankSource
    /// Display name: "General MIDI" for the built-in bank, else the filename
    /// stem.
    public var name: String
    /// The resolved absolute path — transparency only, never persisted.
    public var path: String
    /// `"dls"` or `"sf2"`.
    public var format: String
    /// True only for the system General MIDI bank.
    public var builtin: Bool
    /// File size in bytes.
    public var sizeBytes: Int

    public init(source: SoundBankSource, name: String, path: String,
                format: String, builtin: Bool, sizeBytes: Int) {
        self.source = source
        self.name = name
        self.path = path
        self.format = format
        self.builtin = builtin
        self.sizeBytes = sizeBytes
    }
}

/// Sound-bank discovery/resolution. `resolve` (m10-n-1) is shared by
/// `ProjectStore.setInstrument` validation and the engine's pre-instantiation
/// check; `scan`/`importBank`/`programs(for:)` (m10-n-2) back the wire's
/// discovery/import/program-listing commands. Pure Foundation, injectable
/// directories for tests (the `AutosaveManager` default-dir precedent).
public struct SoundBankLibrary: Sendable {
    /// The system GM bank — resolved from the `"gm"` sentinel at USE time
    /// only (LAW L4). Stable since QuickTime, present on every macOS, but
    /// never persisted as a path.
    public static let systemGMBankPath =
        "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"

    /// Import destination + first scan root:
    /// `~/Library/Application Support/DAWPro/SoundBanks/` (created lazily at
    /// import time, m10-n-2 — joins the Autosave/Feedback family).
    public var libraryDirectory: URL
    /// Scanned in order for `*.sf2`/`*.dls` (m10-n-2); the two standard
    /// macOS bank folders are referenced in place, never copied.
    public var scanDirectories: [URL]

    public init(libraryDirectory: URL? = nil, scanDirectories: [URL]? = nil) {
        let resolvedLibrary = libraryDirectory ?? Self.defaultLibraryDirectory()
        self.libraryDirectory = resolvedLibrary
        self.scanDirectories = scanDirectories ?? [
            resolvedLibrary,
            URL(fileURLWithPath: "/Library/Audio/Sounds/Banks", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Audio/Sounds/Banks", isDirectory: true),
        ]
    }

    /// Default central library dir (the `AutosaveManager.defaultDirectory`
    /// shape): `~/Library/Application Support/DAWPro/SoundBanks/`.
    public static func defaultLibraryDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("DAWPro", isDirectory: true)
            .appendingPathComponent("SoundBanks", isDirectory: true)
    }

    /// `"gm"` → `systemGMBankPath`; `.file` → its path. Throws
    /// `ProjectError.importFailed` when the resolved file is absent — shared
    /// by set-time validation and the engine's pre-instantiation check, so a
    /// missing bank always fails with the same readable reason (LAW L5).
    public func resolve(_ source: SoundBankSource) throws -> URL {
        let path: String
        switch source {
        case .generalMIDI: path = Self.systemGMBankPath
        case .file(let filePath): path = filePath
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw ProjectError.importFailed("no sound bank file at \(path)")
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Discovery (m10-n-2)

    /// The GM entry FIRST (§4.1), then each scan dir's `*.sf2`/`*.dls`
    /// (case-insensitive), deduped by standardized path, alphabetical within a
    /// dir. Read-only: an absent/unreadable scan dir is skipped silently, and
    /// the GM entry is omitted only if the system bank is missing (the
    /// `.missing` impossible-case, R12). Never throws.
    public func scan() -> [SoundBankInfo] {
        var results: [SoundBankInfo] = []
        var seen: Set<String> = []
        let fm = FileManager.default

        if let gm = Self.gmBankInfo() {
            results.append(gm)
            seen.insert(URL(fileURLWithPath: gm.path).standardizedFileURL.path)
        }

        for dir in scanDirectories {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            let banks = entries
                .filter { ["sf2", "dls"].contains($0.pathExtension.lowercased()) }
                .sorted {
                    $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
                        == .orderedAscending
                }
            for url in banks {
                let standardized = url.standardizedFileURL.path
                guard !seen.contains(standardized) else { continue }
                seen.insert(standardized)
                results.append(Self.bankInfo(at: url))
            }
        }
        return results
    }

    /// Copies a `.sf2`/`.dls` into `libraryDirectory` (created lazily),
    /// uniquifying the destination name on collision via
    /// `ProjectBundle.uniqueName`. Validates extension + existence + readability
    /// FIRST; NEVER moves or deletes the source (imports are copies). Throws
    /// `importFailed` in the MediaImporting tone on any validation failure.
    @discardableResult
    public func importBank(from url: URL) throws -> SoundBankInfo {
        let fm = FileManager.default
        let ext = url.pathExtension.lowercased()
        guard ext == "sf2" || ext == "dls" else {
            throw ProjectError.importFailed(
                "sound bank must be a .sf2 or .dls file — got \(url.lastPathComponent)")
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ProjectError.importFailed("no sound bank file at \(url.path)")
        }
        guard fm.isReadableFile(atPath: url.path) else {
            throw ProjectError.importFailed("cannot read sound bank file at \(url.path)")
        }
        try fm.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        let taken = Set((try? fm.contentsOfDirectory(atPath: libraryDirectory.path)) ?? [])
        let name = ProjectBundle.uniqueName(for: url.lastPathComponent, taken: taken)
        let destination = libraryDirectory.appendingPathComponent(name)
        try fm.copyItem(at: url, to: destination)
        return Self.bankInfo(at: destination)
    }

    /// The program list for a bank source (§4.4/§4.5): the GM table for
    /// `.generalMIDI`; the SF2 `phdr` names for a `.sf2`; the generic 0…127
    /// list otherwise (an unparsable SF2 or any other `.dls`). `namesParsed`
    /// says whether the names are real. Throws `importFailed` for a missing
    /// file (via `resolve`); NEVER errors for a resolvable bank AUSampler might
    /// load.
    public func programs(for source: SoundBankSource) throws
        -> (programs: [SoundBankProgram], namesParsed: Bool) {
        switch source {
        case .generalMIDI:
            return (GMProgramCatalog.programs, true)
        case .file:
            let url = try resolve(source)
            if url.pathExtension.lowercased() == "sf2" {
                let presets = SoundFontPresetReader.presets(at: url)
                if !presets.isEmpty {
                    return (presets.map(Self.program(from:)), true)
                }
            }
            // Non-SF2, or an SF2 whose phdr didn't parse: honest generic
            // fallback (§4.5).
            return (Self.genericPrograms, false)
        }
    }

    // MARK: - Internal helpers

    /// Maps an SF2 phdr preset to an AUSampler-addressable program (the v1
    /// heuristic, R11): `wBank == 128` → percussion (MSB 120, LSB 0);
    /// otherwise melodic (MSB 121, LSB = wBank).
    static func program(from preset: SoundFontPresetReader.Preset) -> SoundBankProgram {
        if preset.wBank == 128 {
            return SoundBankProgram(
                program: preset.wPreset, bankMSB: GMProgramCatalog.percussionBankMSB,
                bankLSB: 0, name: preset.name, category: GMProgramCatalog.drumKitCategory)
        }
        return SoundBankProgram(
            program: preset.wPreset, bankMSB: GMProgramCatalog.melodicBankMSB,
            bankLSB: preset.wBank, name: preset.name, category: "")
    }

    /// Generic melodic 0…127 fallback for banks with no parseable names — the
    /// caller flags these `namesParsed: false`.
    static let genericPrograms: [SoundBankProgram] = (0...127).map {
        SoundBankProgram(program: $0, bankMSB: GMProgramCatalog.melodicBankMSB,
                         bankLSB: 0, name: "Program \($0)", category: "")
    }

    /// The system GM bank's info — nil when the bank is absent (R12).
    static func gmBankInfo() -> SoundBankInfo? {
        let path = systemGMBankPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return SoundBankInfo(
            source: .generalMIDI, name: "General MIDI", path: path,
            format: "dls", builtin: true, sizeBytes: fileSize(atPath: path))
    }

    /// Info for a scanned/imported bank file (never the built-in GM bank).
    static func bankInfo(at url: URL) -> SoundBankInfo {
        let standardized = url.standardizedFileURL
        let format = standardized.pathExtension.lowercased() == "sf2" ? "sf2" : "dls"
        return SoundBankInfo(
            source: .file(path: standardized.path),
            name: standardized.deletingPathExtension().lastPathComponent,
            path: standardized.path, format: format, builtin: false,
            sizeBytes: fileSize(atPath: standardized.path))
    }

    private static func fileSize(atPath path: String) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }
}
