import CryptoKit
import DAWCore
import Foundation

/// Content-keyed JSON sidecar cache for transient maps (M5 iii-e, spec §5a) —
/// the StretchRenderCache key discipline exactly. Entries live OUTSIDE the
/// project package at `~/Library/Caches/DAWPro/TransientMaps/<key>.json` and
/// cover the ENTIRE source file, so clip trims/splits never invalidate a map
/// (geometry-free, the stretch-cache rationale). Maps are regenerable by
/// definition: corrupt or missing sidecars recompute and self-heal; nothing
/// is persisted in the project.
///
/// @MainActor service owned by `AudioEngine`; the blocking analysis runs in a
/// `Task.detached` — the render thread and the main actor are untouched while
/// vDSP works. Same-key concurrent requests coalesce onto one in-flight task.
@MainActor
public final class TransientCache {
    /// Where sidecars live. Injectable for tests; defaults to the per-user
    /// app cache dir (created lazily on the first analysis).
    public let directory: URL

    /// TEST SPY: number of times the analyzer actually ran (cache hits and
    /// coalesced same-key waits don't count) — the StretchRenderCache
    /// `renderCount` pattern.
    public private(set) var analysisCount = 0

    /// Same-key single-flight: concurrent requests await one analysis.
    private var inFlight: [String: Task<[TransientMarker], any Error>] = [:]

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DAWPro", isDirectory: true)
                .appendingPathComponent("TransientMaps", isDirectory: true)
    }

    // MARK: - Key derivation (StretchRenderCache §3 discipline)

    /// Sensitivity enters the key quantized to 0.05 steps (spec §5a) — the
    /// SAME quantized value feeds the analyzer, so a key never aliases two
    /// different analyses. Clamped to 0...1 first.
    nonisolated static func quantizedSensitivity(_ sensitivity: Double) -> Double {
        let clamped = min(max(sensitivity, 0), 1)
        return (clamped / 0.05).rounded() * 0.05
    }

    /// SHA256 over (standardized source path ‖ file size ‖ mtime bits ‖
    /// quantized-sensitivity bits ‖ analyzerVersion); first 16 hex chars =
    /// filename. Source identity = path + size + mtime — cheap, standard
    /// practice; a touched/rewritten file re-analyzes once and self-heals.
    /// Throws when the source file is unreadable. Expects an ALREADY
    /// quantized sensitivity.
    nonisolated static func cacheKey(source: URL, quantizedSensitivity: Double) throws -> String {
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
            String(quantizedSensitivity.bitPattern),
            String(TransientAnalyzer.analyzerVersion),
        ] {
            hasher.update(data: Data(field.utf8))
            hasher.update(data: Data([0]))  // field separator
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    // MARK: - Sidecar format

    /// The on-disk JSON payload. `version`/`sensitivity` are recorded for
    /// debuggability and belt-and-braces validation (the key already binds
    /// both); a mismatch reads as corrupt → recompute.
    struct Sidecar: Codable {
        var version: Int
        var sensitivity: Double
        var markers: [TransientMarker]
    }

    nonisolated static func readSidecar(at url: URL) -> [TransientMarker]? {
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
              sidecar.version == TransientAnalyzer.analyzerVersion
        else { return nil }
        return sidecar.markers
    }

    // MARK: - The one async entry point

    /// Markers for (source, sensitivity): sidecar hit → immediate; miss (or
    /// corrupt sidecar) → one detached analysis, committed via write-partial
    /// + atomic rename. Deterministic analysis makes a lost same-key rename
    /// race harmless (identical bytes).
    public func markers(source: URL, sensitivity: Double) async throws -> [TransientMarker] {
        let quantized = Self.quantizedSensitivity(sensitivity)
        let key = try Self.cacheKey(source: source, quantizedSensitivity: quantized)
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
        let task = Task { @MainActor [weak self] () throws -> [TransientMarker] in
            defer { self?.inFlight[key] = nil }
            self?.analysisCount += 1
            // Blocking file read + vDSP runs detached; Result-boxed so the
            // detached task never throws into the structured tree.
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    let markers = try TransientAnalyzer.analyze(
                        fileAt: source, sensitivity: quantized)
                    try Self.commit(markers: markers, sensitivity: quantized,
                                    partial: partial, destination: sidecarURL)
                    return markers
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
        markers: [TransientMarker], sensitivity: Double,
        partial: URL, destination: URL
    ) throws {
        defer { try? FileManager.default.removeItem(at: partial) }  // no-op after rename
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Sidecar(
            version: TransientAnalyzer.analyzerVersion,
            sensitivity: sensitivity, markers: markers))
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
