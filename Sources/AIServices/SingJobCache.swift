import Foundation

/// The phrase cache (design §4.3): one rendered unit per entry, keyed by `SingJobRequestBuilder.cacheKey`, so
/// editing one line and singing again renders only that line's unit.
///
/// An entry is two files in `directory` (`AppDirectories.singingCache` in the app, a temp folder in tests):
/// `<key>.wav`, which the FACADE writes (the request's `outputPath`; the cache folder is one of the facade's
/// allowed roots), and `<key>.json`, the render's facts, which this type writes after checking the WAV.
///
/// - A truncated or unreadable entry is deleted and treated as a miss.
/// - LRU by modification date (a hit touches both files), capped at `capBytes` (2 GB [A]); `evict(protecting:)`
///   never deletes the keys the running job still needs.
/// - The folder is marked excluded from backup (design §2.3; ARCH-REVIEW L14).
///
/// ⚠️ **A HIT IS NOT A DETERMINISM CLAIM** (design §4.3). The only determinism measured is "the same seed
/// twice in one process → max |Δ| = 0". The cache skips work; nobody may read a hit as evidence that a fresh
/// render would match it.
///
/// Not thread-safe on its own: `SingJobCoordinator` (an actor, one job at a time) is its only user.
public struct SingPhraseCache: Sendable {

    /// 2 GB [A] (design §4.3).
    public static let defaultCapBytes: UInt64 = 2_000_000_000

    public let directory: URL
    public let capBytes: UInt64

    public init(directory: URL, capBytes: UInt64 = SingPhraseCache.defaultCapBytes) {
        self.directory = directory
        self.capBytes = capBytes
    }

    /// The facts kept beside a unit's WAV.
    public struct Entry: Codable, Sendable, Equatable {
        public var key: String
        public var frames: Int
        public var sampleRate: Int
        /// The seed this unit was rendered with (the take's, or the take's + 1 after its one retry).
        public var seed: UInt64
        /// The facade's own figures, when it sent them (the real engine; the stub sends no `rtf`).
        public var inferSeconds: Double?
        public var rtf: Double?

        public init(key: String, frames: Int, sampleRate: Int, seed: UInt64, inferSeconds: Double? = nil,
                    rtf: Double? = nil) {
            self.key = key
            self.frames = frames
            self.sampleRate = sampleRate
            self.seed = seed
            self.inferSeconds = inferSeconds
            self.rtf = rtf
        }
    }

    public func wavURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).wav") }
    public func factsURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }

    /// Creates the folder (excluded from backup) if it is missing.
    public func prepare() throws {
        var url = directory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// The unit for `key`, mono, at `sampleRate`; nil on a miss. A broken entry (facts that do not decode, a
    /// WAV that does not parse, a frame count or rate that disagrees with the facts, a non-finite or silent
    /// unit) is deleted and reads as a miss. A hit touches the entry (LRU).
    public func lookup(_ key: String, sampleRate: Int) -> (entry: Entry, samples: [Float])? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: factsURL(key).path) || fm.fileExists(atPath: wavURL(key).path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: factsURL(key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.key == key, entry.sampleRate == sampleRate,
              let audio = try? SingWAV.read(wavURL(key)),
              audio.sampleRate == sampleRate, audio.frameCount == entry.frames
        else {
            remove(key)
            return nil
        }
        let samples = audio.mono
        guard SingUnitCheck.check(samples) == .ok else {
            remove(key)
            return nil
        }
        touch(key)
        return (entry, samples)
    }

    /// Records the facts for a unit whose WAV the facade has just written (and the job has checked).
    public func store(_ entry: Entry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(entry).write(to: factsURL(entry.key), options: .atomic)
    }

    public func remove(_ key: String) {
        try? FileManager.default.removeItem(at: wavURL(key))
        try? FileManager.default.removeItem(at: factsURL(key))
    }

    func touch(_ key: String) {
        let now = Date()
        for url in [wavURL(key), factsURL(key)] {
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        }
    }

    /// Deletes least-recently-used entries until the folder holds at most `capBytes`, never one of
    /// `protecting`. Returns the keys it deleted.
    @discardableResult
    public func evict(protecting: Set<String>) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var entries: [String: (bytes: UInt64, used: Date)] = [:]
        for name in names {
            let url = directory.appendingPathComponent(name)
            let ext = url.pathExtension
            guard ext == "wav" || ext == "json" else { continue }
            let key = url.deletingPathExtension().lastPathComponent
            let attributes = try? fm.attributesOfItem(atPath: url.path)
            let bytes = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            let used = (attributes?[.modificationDate] as? Date) ?? .distantPast
            let previous = entries[key]
            entries[key] = ((previous?.bytes ?? 0) + bytes, max(previous?.used ?? .distantPast, used))
        }
        var total = entries.values.reduce(0) { $0 + $1.bytes }
        guard total > capBytes else { return [] }
        var deleted: [String] = []
        for (key, entry) in entries.sorted(by: { $0.value.used < $1.value.used }) where !protecting.contains(key) {
            guard total > capBytes else { break }
            remove(key)
            total -= entry.bytes
            deleted.append(key)
        }
        return deleted
    }
}
