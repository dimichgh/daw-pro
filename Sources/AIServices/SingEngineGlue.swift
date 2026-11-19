import CryptoKit
import DAWCore
import Foundation

// MARK: - The engine, as the wire sees it

/// What `sing.sidecarStatus` / `sing.sidecarStart` / `sing.sidecarStop` and `sing.render` need from the singing
/// sidecar (p2-sing-e part 2). `SingingSidecarManager` conforms; the wire's tests script a fake.
public protocol SingEngineControlling: SingJobEngine {
    /// The manager's configuration: the port, and the runtime, scripts, voices and cache folders.
    nonisolated var engineConfig: SingingSidecarManager.Configuration { get }
    /// `stop()`, then the three authority limbs (design §6 row 3).
    func stopReportingEvidence() async throws -> SingingStopReport
}

/// `sing.sidecarStop`'s reply (design §6 row 3, "the stop evidence (three limbs)"): the stop's own status and
/// `ModelStopEvidence` gathered from the SAME pre-kill capture that did the signalling.
public struct SingingStopReport: Codable, Sendable, Equatable {
    public var status: SingingSidecarStatus
    public var evidence: ModelStopEvidence

    public init(status: SingingSidecarStatus, evidence: ModelStopEvidence) {
        self.status = status
        self.evidence = evidence
    }
}

extension SingingSidecarManager: SingEngineControlling {
    public nonisolated var engineConfig: Configuration { config }
}

// MARK: - The engine's files, read and checked (design §2.5, §2.8)

/// The singing engine's install on disk: what `install.json` says, the cheap preflight checks of design §2.8
/// (steps 3–5), the full weights check behind `sing.sidecarStatus {verify: true}`, the free-space floor from
/// `pins.env`, a foreign listener on the port (step 6), and the uninstall.
///
/// Everything here READS, except `removeRuntime()`, which deletes only a folder named `SingingEngine` (the
/// profile-aware `AppDirectories.singingEngine`, or a test's own folder with that name), and only when its
/// caller has the user's yes.
public struct SingEngineFiles: Sendable {
    public var runtimeDir: URL?
    public var scriptsDir: URL?

    /// The one folder name `removeRuntime()` will delete.
    public static let runtimeFolderName = "SingingEngine"
    /// `pins.env`'s `MIN_FREE_KB` when it cannot be read: 12 GiB, install.sh's own preflight floor.
    public static let fallbackMinFreeKB: Int64 = 12_582_912

    public init(runtimeDir: URL?, scriptsDir: URL?) {
        self.runtimeDir = runtimeDir
        self.scriptsDir = scriptsDir
    }

    public init(config: SingingSidecarManager.Configuration) {
        self.init(runtimeDir: config.runtimeDir, scriptsDir: config.scriptsDir)
    }

    // MARK: install.json

    /// What the install marker records (install.sh's `marker_json`), as read now. Every field optional: an old
    /// or hand-made marker reads as what it has.
    public struct RuntimeFacts: Codable, Sendable, Equatable {
        public var installedBytes: Int64?
        public var commit: String?
        public var weightsRevision: String?
        public var weightsSha256: String?
        public var weightsBytes: Int64?
        public var weightsMtime: Int64?
        public var weightsInode: Int64?
        public var scriptsVersion: Int?
        public var builtinVoiceId: String?
        public var pythonVersion: String?
        public var source: String?
        public var date: String?
    }

    public var markerURL: URL? { runtimeDir?.appendingPathComponent("install.json") }

    /// nil when there is no marker (not installed, or an install that never finished: the marker is written last).
    public func runtimeFacts() -> RuntimeFacts? {
        guard let markerURL, let data = try? Data(contentsOf: markerURL) else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return RuntimeFacts()
        }
        func int64(_ key: String) -> Int64? { (object[key] as? NSNumber)?.int64Value }
        return RuntimeFacts(
            installedBytes: int64("installedBytes"), commit: object["commit"] as? String,
            weightsRevision: object["weightsRevision"] as? String,
            weightsSha256: object["weightsSha256"] as? String, weightsBytes: int64("weightsBytes"),
            weightsMtime: int64("weightsMtime"), weightsInode: int64("weightsInode"),
            scriptsVersion: (object["scriptsVersion"] as? NSNumber)?.intValue,
            builtinVoiceId: object["builtinVoiceId"] as? String, pythonVersion: object["pythonVersion"] as? String,
            source: object["source"] as? String, date: object["date"] as? String)
    }

    // MARK: pins.env

    /// One value of `scripts/sing/pins.env` (`KEY=value` or `KEY="value"`; install.sh reads it the same way: line
    /// by line, never evaluated). nil when the file or the key is missing.
    public func pin(_ key: String) -> String? {
        guard let scriptsDir,
              let text = try? String(contentsOf: scriptsDir.appendingPathComponent("pins.env"), encoding: .utf8)
        else { return nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq] == key else { continue }
            var value = String(line[line.index(after: eq)...])
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    /// install.sh's preflight free-space floor, in bytes.
    public func minFreeBytes() -> Int64 {
        (pin("MIN_FREE_KB").flatMap { Int64($0) } ?? Self.fallbackMinFreeKB) * 1024
    }

    public var weightsURL: URL? {
        runtimeDir?.appendingPathComponent("weights").appendingPathComponent(pin("MODEL_FILE") ?? "model.pt")
    }

    public var builtInVoiceURL: URL? {
        runtimeDir?.appendingPathComponent("voices").appendingPathComponent(SingJobVoice.builtInID)
            .appendingPathComponent("prompt.wav")
    }

    public func builtInVoiceAvailable() -> Bool {
        builtInVoiceURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    // MARK: §2.8's cheap checks

    /// Design §2.8 steps 3–5 on an install whose marker exists: the venv's python, the weights' size, mtime and
    /// inode against the marker's, and the built-in voice. Each problem is a plain phrase; empty = all present.
    /// An install with no marker has no problems to report here (it reads `notInstalled`).
    public func preflightProblems() -> [String] {
        guard let runtimeDir, let facts = runtimeFacts() else { return [] }
        var problems: [String] = []
        let python = runtimeDir.appendingPathComponent("venv/bin/python")
        if !FileManager.default.isExecutableFile(atPath: python.path) {
            problems.append("its Python environment is missing")
        }
        if let weightsURL, facts.weightsBytes != nil || facts.weightsMtime != nil || facts.weightsInode != nil {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: weightsURL.path) {
                let size = (attributes[.size] as? NSNumber)?.int64Value
                let mtime = (attributes[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) }
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value
                if (facts.weightsBytes.map { $0 != size } ?? false)
                    || (facts.weightsMtime.map { $0 != mtime } ?? false)
                    || (facts.weightsInode.map { $0 != inode } ?? false) {
                    problems.append("its model file changed since it was installed")
                }
            } else {
                problems.append("its model file is missing")
            }
        }
        if !builtInVoiceAvailable() { problems.append("the built-in singer is missing") }
        return problems
    }

    /// `sing.sidecarStatus {verify: true}`: the full sha256 of the weights against the marker's (design §2.8
    /// step 4; seconds on a 2.8 GB file, which is why it runs only when asked).
    public struct WeightsVerification: Codable, Sendable, Equatable {
        public var checked: Bool
        public var matches: Bool?
        public var expected: String?
        public var actual: String?
        public var detail: String?
    }

    public func verifyWeights() -> WeightsVerification {
        guard let facts = runtimeFacts() else {
            return WeightsVerification(checked: false, detail: "the singing engine is not installed")
        }
        guard let expected = facts.weightsSha256 else {
            return WeightsVerification(checked: false, detail: "install.json records no weightsSha256")
        }
        guard let weightsURL, let handle = try? FileHandle(forReadingFrom: weightsURL) else {
            return WeightsVerification(checked: true, matches: false, expected: expected,
                                       detail: "the model file is missing")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return WeightsVerification(checked: true, matches: actual == expected.lowercased(), expected: expected,
                                   actual: actual, detail: nil)
    }

    // MARK: §2.8 step 6: a foreign listener

    /// Who else holds the engine's port: nil when nobody, only our own pidfile's pid, or the lookup could not run
    /// (unknown is not "busy"; the manager's own start check is the backstop).
    public func foreignListener(baseURL: URL, pidfileURL: URL?) -> String? {
        guard let port = SidecarProcessDiscovery.port(of: baseURL),
              case .listeners(let pids) = SidecarProcessDiscovery.listeners(onPort: port) else { return nil }
        let ours = pidfileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let foreign = pids.filter { $0 != ours }
        guard !foreign.isEmpty else { return nil }
        return foreign.map { "pid \($0) (\(SidecarProcessDiscovery.args(ofPid: $0) ?? "command line unavailable"))" }
            .joined(separator: ", ")
    }

    // MARK: Uninstall

    /// The bytes the runtime folder takes on disk now (allocated size), 0 when it does not exist.
    public func sizeOnDisk() -> Int64 {
        guard let runtimeDir, FileManager.default.fileExists(atPath: runtimeDir.path) else { return 0 }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: runtimeDir, includingPropertiesForKeys: keys)
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    public var isPresent: Bool {
        runtimeDir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    public enum RemoveError: Error, Equatable, LocalizedError {
        case notResolvable
        case refusedPath(String)

        public var errorDescription: String? {
            switch self {
            case .notResolvable: return "The singing engine's folder could not be found."
            case .refusedPath(let path):
                return "Refusing to delete \(path): only a folder named \(SingEngineFiles.runtimeFolderName) is "
                    + "the singing engine's."
            }
        }
    }

    /// Deletes the runtime folder (design §2.5 "Uninstall": voices, the phrase cache and landed audio live
    /// elsewhere and are untouched) and returns the bytes it took. Refuses any folder not named `SingingEngine`
    /// or that is a symbolic link.
    public func removeRuntime() throws -> Int64 {
        guard let runtimeDir else { throw RemoveError.notResolvable }
        let path = runtimeDir.standardizedFileURL
        let isLink = (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        guard path.lastPathComponent == Self.runtimeFolderName, !isLink else {
            throw RemoveError.refusedPath(path.path)
        }
        guard FileManager.default.fileExists(atPath: path.path) else { return 0 }
        let bytes = sizeOnDisk()
        try FileManager.default.removeItem(at: path)
        return bytes
    }

    /// The free space on the volume the runtime folder is (or will be) on: the nearest folder that exists.
    public static func freeBytes(near url: URL) -> Int64? {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - The speech model, for the word checks

public enum SingSpeech {
    /// The `transcribe` a sing job and `sing.addVoice`'s word check use (design §4.6): what the router's ONE
    /// `WhisperTranscriber` hears in a file, in English. Returns nil — never throws — when no speech model is
    /// installed, so the word check is skipped honestly ("Word check skipped: no speech model is installed").
    public static func transcribe(_ transcriber: WhisperTranscriber, _ url: URL) async throws -> String? {
        do {
            let result = try await transcriber.transcribe(WhisperTranscriptionRequest(
                audioURL: url, anchorBeat: 0, tempoMap: TempoMap(constantBPM: 120), language: "en"))
            return result.text
        } catch is WhisperModelError {
            return nil
        }
    }
}
