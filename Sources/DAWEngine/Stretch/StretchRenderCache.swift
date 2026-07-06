import AVFAudio
import CryptoKit
import DAWCore
import Foundation
import os

/// On-disk cache + async job model for offline clip stretch renders (M5 ii-d,
/// seam spec §2–§5). @MainActor service owned by `AudioEngine`; DAWCore never
/// sees it. Entries live OUTSIDE the project package at
/// `~/Library/Caches/DAWPro/StretchRenders/<key>.caf` — Float32 CAF at the
/// SOURCE sample rate and channel count, covering the ENTIRE source file (so
/// split clips share one phase-coherent render and clip geometry never
/// invalidates; spec §3). Renders are regenerable by definition: an OS cache
/// purge or project move re-renders asynchronously and self-heals.
///
/// Job model (the M3 vi-a async-prepare shape): a miss spawns one
/// `Task.detached` render per clip with per-clip latest-wins supersession and
/// a 250 ms debounce (drag contract — only the settled value renders), writes
/// a `.partial-…caf` sibling and atomically renames on success. Everything
/// here is main-actor / detached-task scheduling-time work — the render
/// thread is untouched by construction.
@MainActor
public final class StretchRenderCache {
    /// The three schedule-affecting stretch parameters, as one hashable value
    /// (the cache-key payload and the engine's latest-wins comparator).
    public struct Params: Hashable, Sendable {
        public let ratio: Double
        public let semitones: Double
        public let formantPreserve: Bool

        public init(ratio: Double, semitones: Double, formantPreserve: Bool) {
            self.ratio = ratio
            self.semitones = semitones
            self.formantPreserve = formantPreserve
        }

        public init(clip: Clip) {
            self.init(ratio: clip.stretchRatio,
                      semitones: clip.pitchShiftSemitones,
                      formantPreserve: clip.formantPreserve)
        }
    }

    /// Bumped whenever the vendored signalsmith version or our preset/config
    /// changes — stale-quality renders must not survive an upgrade (spec §3).
    nonisolated public static let stretchEngineVersion = 1

    /// Quiet period before a render job starts real work: a newer request for
    /// the same clip lands inside this window and cancels the older job, so a
    /// dragged stretch handle renders only the settled value.
    nonisolated static let debounceMilliseconds = 250

    /// Where entries live. Injectable for tests; defaults to the per-user app
    /// cache dir (created lazily on the first render).
    public let directory: URL

    /// Fired on the main actor after a render COMMITS (atomic rename done) —
    /// the engine uses it to invalidate the clip's schedule entry and re-enter
    /// the `tracksDidChange` restart seam so the rendered audio lands.
    public var onRenderComplete: (@MainActor (UUID) -> Void)?

    /// TEST SPY: number of renders that actually ran the stretcher (debounce
    /// survived, work started). Cache hits and superseded jobs don't count.
    private(set) var renderCount = 0

    private struct Job {
        let token: UUID
        let key: String
        let task: Task<URL, any Error>
        /// Read by the detached render between blocks (the facade's
        /// `isCancelled` closure); set alongside `task.cancel()` so an
        /// in-flight render aborts promptly, not just a sleeping debounce.
        let cancelled: OSAllocatedUnfairLock<Bool>

        func cancel() {
            cancelled.withLock { $0 = true }
            task.cancel()
        }
    }

    /// Per-clip latest-wins slot: at most one render job per clip; a newer
    /// request cancels and replaces the old one.
    private var jobs: [UUID: Job] = [:]
    /// Pull-based status per clip (spec §5): `.rendering` while a job is in
    /// flight, `.failed` after a non-cancellation error (sticky until the
    /// next job for that clip), absent = idle.
    private var statuses: [UUID: ClipStretchStatus] = [:]

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DAWPro", isDirectory: true)
                .appendingPathComponent("StretchRenders", isDirectory: true)
    }

    // MARK: - Status (pull-based, spec §5)

    public func status(forClip clipID: UUID) -> ClipStretchStatus {
        statuses[clipID] ?? .idle
    }

    /// Cancels and clears any in-flight job for a clip that left the model.
    public func cancelJob(forClip clipID: UUID) {
        jobs.removeValue(forKey: clipID)?.cancel()
        statuses[clipID] = nil
    }

    // MARK: - Key derivation (spec §3)

    /// SHA256 over (standardized source path ‖ file size ‖ mtime ‖ ratio bit
    /// pattern ‖ semitones bit pattern ‖ formant flag ‖ engine version);
    /// first 16 hex chars = filename. Source identity = path + size + mtime —
    /// cheap, standard waveform-cache practice; a moved project re-renders
    /// once and self-heals. Throws when the source file is unreadable.
    nonisolated static func cacheKey(source: URL, params: Params) throws -> String {
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
            String(params.ratio.bitPattern),
            String(params.semitones.bitPattern),
            params.formantPreserve ? "1" : "0",
            String(stretchEngineVersion),
        ] {
            hasher.update(data: Data(field.utf8))
            hasher.update(data: Data([0]))  // field separator
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// The committed cache entry for (source, params), or nil when absent /
    /// key underivable. Pure lookup — never starts a job (the engine's
    /// resolve path uses this for the `.ready` branch; OfflineRenderer's
    /// provider uses it after the mixdown wait).
    public func cachedURL(source: URL, params: Params) -> URL? {
        guard let key = try? Self.cacheKey(source: source, params: params) else { return nil }
        let url = directory.appendingPathComponent(key + ".caf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - renderIfNeeded (the one async entry point)

    /// Returns the stretched CAF for (source, params): cache hit → immediate;
    /// miss → a debounced detached render job (per-clip latest-wins — a newer
    /// request for the same clip cancels an in-flight older one; same-key
    /// requests coalesce onto the running job). Identity params return the
    /// source unchanged (callers shouldn't ask, but the answer is honest).
    /// Throws `CancellationError`/`.cancelled` when superseded, or the render
    /// error (also recorded in `status(forClip:)` as `.failed`).
    public func renderIfNeeded(clipID: UUID, source: URL, params: Params) async throws -> URL {
        if OfflineStretcher.isIdentity(ratio: params.ratio, semitones: params.semitones) {
            return source
        }
        let key = try Self.cacheKey(source: source, params: params)
        let destination = directory.appendingPathComponent(key + ".caf")
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        if let job = jobs[clipID], job.key == key {
            return try await job.task.value  // single-flight: coalesce onto it
        }
        // Latest-wins: a newer request supersedes the in-flight job.
        jobs.removeValue(forKey: clipID)?.cancel()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let token = UUID()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        // Unique partial per job: two clips sharing one (source, params) key
        // may race — each writes its own partial; the rename commits once.
        let partial = directory.appendingPathComponent("\(key).partial-\(token.uuidString).caf")
        statuses[clipID] = .rendering
        let task = Task { @MainActor [weak self] () throws -> URL in
            do {
                // Debounce: cancellation during this sleep throws — the job
                // dies before any file I/O happens.
                try await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
                self?.renderCount += 1
                // The blocking render runs detached — reads the FULL source,
                // pumps the facade, writes the partial, atomically renames.
                // Result-boxed so the detached task never throws into the
                // structured tree before we re-check cancellation.
                let outcome = await Task.detached(priority: .userInitiated) {
                    Result {
                        try Self.performRender(
                            source: source, partial: partial, destination: destination,
                            params: params, isCancelled: { cancelled.withLock { $0 } })
                    }
                }.value
                try Task.checkCancellation()
                try outcome.get()
                // Bookkeeping only if this job still owns the clip's slot
                // (a superseding job may have replaced it mid-render).
                if let self, self.jobs[clipID]?.token == token {
                    self.jobs[clipID] = nil
                    self.statuses[clipID] = nil
                    self.onRenderComplete?(clipID)
                }
                return destination
            } catch {
                if let self, self.jobs[clipID]?.token == token {
                    self.jobs[clipID] = nil
                    let wasCancelled = error is CancellationError
                        || (error as? OfflineStretcherError) == .cancelled
                    self.statuses[clipID] = wasCancelled
                        ? nil : .failed(String(describing: error))
                }
                throw error
            }
        }
        jobs[clipID] = Job(token: token, key: key, task: task, cancelled: cancelled)
        return try await task.value
    }

    // MARK: - The blocking render (detached-task body; never on the main actor)

    /// Reads the whole source file, stretches it through the `OfflineStretcher`
    /// facade (deterministic fixed-seed output — cache entries are
    /// reproducible), writes a Float32 CAF partial and renames it into place.
    /// The partial is cleaned up on every exit path; a lost rename race
    /// against a same-key sibling job counts as success (identical bytes by
    /// determinism).
    nonisolated private static func performRender(
        source: URL, partial: URL, destination: URL, params: Params,
        isCancelled: @Sendable () -> Bool
    ) throws {
        defer { try? FileManager.default.removeItem(at: partial) }  // no-op after rename

        let reader = try AVAudioFile(forReading: source)
        let format = reader.processingFormat  // deinterleaved float32, source rate
        let channelCount = Int(format.channelCount)
        guard reader.length > 0, channelCount > 0 else {
            throw OfflineStretcherError.invalidInput("empty source \(source.path)")
        }
        var planar = [[Float]](repeating: [], count: channelCount)
        for channel in 0..<channelCount {
            planar[channel].reserveCapacity(Int(reader.length))
        }
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
            throw OfflineStretcherError.allocationFailed
        }
        // Loop read: AVAudioFile.read(into:) can return short (measured
        // elsewhere in this codebase) — a single call would truncate.
        while reader.framePosition < reader.length {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            try reader.read(into: chunk)
            guard chunk.frameLength > 0, let data = chunk.floatChannelData else { break }
            for channel in 0..<channelCount {
                planar[channel].append(contentsOf: UnsafeBufferPointer(
                    start: data[channel], count: Int(chunk.frameLength)))
            }
        }

        let stretched = try OfflineStretcher.stretch(
            input: planar, sampleRate: format.sampleRate, ratio: params.ratio,
            semitones: params.semitones, formantPreserve: params.formantPreserve,
            isCancelled: isCancelled)

        let outFrames = stretched[0].count
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(outFrames)),
            let outData = outBuffer.floatChannelData
        else {
            throw OfflineStretcherError.allocationFailed
        }
        for channel in 0..<channelCount {
            stretched[channel].withUnsafeBufferPointer { src in
                outData[channel].update(from: src.baseAddress!, count: outFrames)
            }
        }
        outBuffer.frameLength = AVAudioFrameCount(outFrames)

        // Float32 CAF at the source rate/channels (interleaved on disk, like
        // the WAV bounce path). Scoped so the file closes before the rename.
        var settings: [String: Any] = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        do {
            let writer = try AVAudioFile(forWriting: partial, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: outBuffer)
        }
        // A render cancelled after the last block must not commit.
        if isCancelled() { throw OfflineStretcherError.cancelled }
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            // Same-key sibling won the rename — identical bytes, so ours is
            // redundant, not failed.
            guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
        }
    }
}
