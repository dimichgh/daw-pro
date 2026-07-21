import CryptoKit
import DAWCore
import Foundation

/// Content-keyed JSON sidecar cache for audio-content analyses (m21-e) — the
/// `TransientCache` discipline exactly, with one deliberate difference:
/// key/tempo/balance are AGGREGATES, so the analysis WINDOW enters the key
/// (a whole-file answer for a trimmed clip is the wrong answer and cannot be
/// filtered after the fact — design-clip-analyze-audio §2). Entries live at
/// `~/Library/Caches/DAWPro/AudioAnalysis/<key>.json`; analyses are
/// regenerable by definition: corrupt or missing sidecars recompute and
/// self-heal; nothing is persisted in the project.
///
/// @MainActor service owned by `AudioEngine`; the blocking analysis runs in a
/// `Task.detached` — the render thread and the main actor are untouched while
/// vDSP works. Same-key concurrent requests coalesce onto one in-flight task.
@MainActor
public final class AudioAnalysisCache {
    /// Where sidecars live. Injectable for tests; defaults to the per-user
    /// app cache dir (created lazily on the first analysis).
    public let directory: URL

    /// TEST SPY: number of times the analyzer actually ran (cache hits and
    /// coalesced same-key waits don't count) — the `TransientCache`
    /// `analysisCount` pattern.
    public private(set) var analysisCount = 0

    /// Same-key single-flight: concurrent requests await one analysis.
    private var inFlight: [String: Task<AudioContentAnalysis, any Error>] = [:]

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DAWPro", isDirectory: true)
                .appendingPathComponent("AudioAnalysis", isDirectory: true)
    }

    // MARK: - Key derivation (TransientCache discipline + the window)

    /// Window offsets enter the key quantized to 1 ms — the SAME quantized
    /// values feed the analyzer, so a key never aliases two different
    /// analyses (the quantized-sensitivity rule).
    nonisolated static func quantizedSeconds(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return (seconds * 1000).rounded() / 1000
    }

    /// SHA256 over (standardized source path ‖ file size ‖ mtime bits ‖
    /// quantized-windowStart bits ‖ quantized-windowDuration bits ‖
    /// analyzerVersion); first 16 hex chars = filename. Source identity =
    /// path + size + mtime — a touched/rewritten file re-analyzes once and
    /// self-heals. Throws when the source file is unreadable. Expects
    /// ALREADY quantized window values.
    nonisolated static func cacheKey(
        source: URL, quantizedWindowStart: Double, quantizedWindowDuration: Double
    ) throws -> String {
        let path = source.standardizedFileURL.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        var hasher = SHA256()
        for field in [
            path,
            String(size),
            String(mtime.bitPattern),
            String(quantizedWindowStart.bitPattern),
            String(quantizedWindowDuration.bitPattern),
            String(AudioContentAnalyzer.analyzerVersion),
        ] {
            hasher.update(data: Data(field.utf8))
            hasher.update(data: Data([0]))  // field separator
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    // MARK: - Sidecar format

    /// The on-disk JSON payload. `version` and the window are recorded for
    /// debuggability and belt-and-braces validation (the key already binds
    /// them); a mismatch reads as corrupt → recompute.
    struct Sidecar: Codable {
        var version: Int
        var windowStartSeconds: Double
        var windowDurationSeconds: Double
        var analysis: AudioContentAnalysis
    }

    nonisolated static func readSidecar(at url: URL) -> AudioContentAnalysis? {
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
              sidecar.version == AudioContentAnalyzer.analyzerVersion,
              sidecar.analysis.analyzerVersion == sidecar.version
        else { return nil }
        return sidecar.analysis
    }

    // MARK: - The one async entry point

    /// Analysis for (source, window): sidecar hit → immediate; miss (or
    /// corrupt sidecar) → one detached analysis, committed via write-partial
    /// + atomic rename. Deterministic analysis makes a lost same-key rename
    /// race harmless (identical bytes).
    public func analysis(
        source: URL, windowStartSeconds: Double, windowDurationSeconds: Double
    ) async throws -> AudioContentAnalysis {
        let start = Self.quantizedSeconds(windowStartSeconds)
        let duration = Self.quantizedSeconds(windowDurationSeconds)
        let key = try Self.cacheKey(source: source, quantizedWindowStart: start,
                                    quantizedWindowDuration: duration)
        let sidecarURL = directory.appendingPathComponent(key + ".json")
        if let cached = Self.readSidecar(at: sidecarURL) {
            return cached
        }
        if let running = inFlight[key] {
            return try await running.value  // single-flight: coalesce onto it
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(
            "\(key).partial-\(UUID().uuidString).json")
        let task = Task { @MainActor [weak self] () throws -> AudioContentAnalysis in
            defer { self?.inFlight[key] = nil }
            self?.analysisCount += 1
            // Blocking file read + vDSP runs detached; Result-boxed so the
            // detached task never throws into the structured tree.
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    let analysis = try AudioContentAnalyzer.analyze(
                        fileAt: source, windowStartSeconds: start,
                        windowDurationSeconds: duration)
                    try Self.commit(analysis: analysis, windowStartSeconds: start,
                                    windowDurationSeconds: duration,
                                    partial: partial, destination: sidecarURL)
                    return analysis
                }
            }.value
            return try outcome.get()
        }
        inFlight[key] = task
        return try await task.value
    }

    /// Write the sidecar to a unique partial, then rename into place. An
    /// existing (possibly corrupt) sidecar is removed first; losing a rename
    /// race to a same-key sibling counts as success (identical bytes by
    /// determinism). The partial is cleaned up on every exit path.
    nonisolated private static func commit(
        analysis: AudioContentAnalysis, windowStartSeconds: Double,
        windowDurationSeconds: Double, partial: URL, destination: URL
    ) throws {
        defer { try? FileManager.default.removeItem(at: partial) }  // no-op after rename
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Sidecar(
            version: AudioContentAnalyzer.analyzerVersion,
            windowStartSeconds: windowStartSeconds,
            windowDurationSeconds: windowDurationSeconds,
            analysis: analysis))
        try data.write(to: partial, options: .atomic)
        // A corrupt/stale sidecar at the destination must not block the
        // rename — replace it (recompute-and-overwrite semantics).
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
        }
    }
}
