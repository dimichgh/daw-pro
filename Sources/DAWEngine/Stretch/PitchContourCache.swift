import AVFAudio
import DAWCore
import Foundation
import os

/// **THE DETECTED-CONTOUR CACHE, AND THE ONE SEAM THAT YIELDS "THE CONTOUR THE
/// RENDER USES FOR THIS CLIP".** (contour-to-render, 2026-09-24)
///
/// Design `docs/research/m23-q-pitch-correction-design.md` decides the shape,
/// and every clause below is one of its sentences made concrete:
///
///  * §7.3 — the detected contour "must not be persisted in the project; it is
///    regenerable analysis and belongs in the cache directory beside the
///    renders, keyed by content like everything else." So entries live INSIDE
///    the render cache's own directory
///    (`~/Library/Caches/DAWPro/StretchRenders/PitchContours/<key>.json`), and
///    an injected test directory carries its contours with it.
///  * §7.8 — no second render cache and no second cache-key derivation. The key
///    below is built from `StretchRenderCache.sourceIdentityFields` and hashed by
///    `StretchRenderCache.keyDigest`, the SAME two functions the render key is
///    built from; this file adds only the detector's fields. And no detection
///    sidecar PROCESS: detection runs in-process, inside the render's own
///    already-detached task.
///  * §7.2 — `analysisVersion` must re-key, and a contour/version mismatch on
///    re-render must surface as a visible notice, never a silent substitution
///    (`PitchRenderContour.analysisVersionMismatch`).
///
/// **WHOLE FILE, FROM SOURCE SECOND 0 — NEVER THE CLIP'S TRIM WINDOW.** The
/// contour is a pure function of the file and the detector, so trimming or
/// splitting a clip can neither invalidate nor shift it (the render cache's
/// own geometry-independence, spec §3). ⚠️ The product's existing detection
/// path (`ProjectStore.detectClipPitch`, which `clip.autoCorrectPitch`
/// segments from) analyses the clip's CURRENT WINDOW instead. For an untrimmed
/// clip the two are the same call; for a window starting mid-file they are
/// not the same analysis — measured on the real 33 s vocal with a window at
/// 1.234 s: the frame grid sits 2.0 ms off the whole-file grid, 16 of 2004
/// paired frames flip voicing, and pitch differs by a median 1.7 cents (p95
/// 8.8, max 17.7). That is why the display must read THIS seam rather than
/// `detectClipPitch` if its picture is to agree with the sound.
///
/// **DETERMINISM, MEASURED, AND WHAT THE CACHE PINS.** Two detections of the
/// same 33 s file are bit-identical — in one process and across two processes
/// (2081 frames, SHA256 over every field's bit pattern
/// `0cd4d6cd…d1fd9f7` both times). So a purged cache re-detects the same
/// contour and a purged render re-renders the same audio under the same key.
/// The cache still returns ONLY what is on disk (first writer wins, everyone
/// reads the winner's bytes), so if a future detector were NOT deterministic
/// the first detection would be pinned for as long as the entry lives, and
/// the display and the render could never disagree about which one they used.
/// After an OS purge that hypothetical detector could produce a slightly
/// different contour under the same key — which is why determinism is gated
/// by a test rather than assumed.
///
/// **COST, MEASURED:** detecting the 33.3 s vocal takes 0.51–0.58 s cold and
/// 0.37–0.40 s warm (one render of the same file is ~1.5 s). It is paid once
/// per (file, detector); every later render and every display read is a
/// ~100 KB JSON read.
///
/// §7.6: nothing here is reachable from the render thread. Every function is
/// blocking, allocating and file-touching by design, and is only ever called
/// from a detached task.
enum PitchContourCache {

    /// Bumped when the sidecar LAYOUT changes. Part of the key, so a layout
    /// change re-keys rather than mis-decodes.
    static let layoutVersion = 1

    /// Everything that changes what a detection returns — the contour key's
    /// material — plus the detection itself.
    ///
    /// ⭐ **EVERY FIELD HERE IS IN THE KEY.** A field that changed the output
    /// and was not keyed would serve the previous detector's contour, and a
    /// render shaped against it, under a key that looks current.
    /// `ContourToRenderTests` flips each field in turn and asserts the key
    /// moves.
    struct Detector: Sendable {
        /// The detector GENERATION (`PitchEditSet.currentAnalysisVersion` for
        /// the product). Compared against the edit set's own
        /// `analysisVersion` before any contour is used.
        var analysisVersion: Int
        var confidenceThreshold: Double
        var silenceFloorDbfs: Double
        /// The rate the model analyses at and its hop — together the frame
        /// rate and the frame grid.
        var modelSampleRate: Double
        var hopLength: Int
        /// The model's identity (the weights' SHA256 for the product).
        var modelIdentity: String
        /// The inference runtime that executes the model
        /// (`SwiftF0PitchTracker.runtimeIdentity` for the product).
        var runtimeIdentity: String
        /// Runs ONE whole-file detection with this configuration. Injectable
        /// so a test can count detections or force a failure; the product's
        /// is `detectWholeFile`.
        var run: @Sendable (_ source: URL, _ detector: Detector) throws -> PitchDetectionResult

        /// The product's detector: SwiftF0 at the SAME settings
        /// `ProjectStore.detectClipPitch` uses by default — which are the
        /// settings `clip.autoCorrectPitch` segments with, and the wire verb
        /// exposes no others. Shaping against a contour detected at different
        /// settings than the segments came from would mix two analyses.
        static let product = Detector(
            analysisVersion: PitchEditSet.currentAnalysisVersion,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs,
            modelSampleRate: SwiftF0PitchTracker.modelSampleRate,
            hopLength: SwiftF0PitchTracker.hopLength,
            modelIdentity: SwiftF0PitchTracker.weightsSHA256,
            runtimeIdentity: SwiftF0PitchTracker.runtimeIdentity,
            run: { source, detector in try PitchContourCache.detectWholeFile(source, detector) })
    }

    /// The whole-file detection the product runs: `ClipPitchAnalyzer.detect`
    /// — the ONE conversion site from the tracker to `ClipPitchFrame` — from
    /// source second 0 to the file's real end.
    ///
    /// ⚠️ The duration is read off the file, not passed as 0 or as "the rest":
    /// `ClipPitchAnalyzer.detect(… durationSeconds: 0)` is a ZERO-LENGTH window.
    /// One second of headroom is added and clamped away by the reader, so no
    /// floating-point rounding of `length / rate × rate` can drop the last
    /// frame.
    static func detectWholeFile(_ source: URL, _ detector: Detector) throws -> PitchDetectionResult {
        let file = try AVAudioFile(forReading: source)
        let rate = file.processingFormat.sampleRate
        guard file.length > 0, rate > 0 else {
            throw OfflineStretcherError.invalidInput("empty source \(source.path)")
        }
        return try ClipPitchAnalyzer.detect(
            fileAt: source, fromSeconds: 0,
            durationSeconds: Double(file.length) / rate + 1,
            confidenceThreshold: detector.confidenceThreshold,
            silenceFloorDbfs: detector.silenceFloorDbfs)
    }

    /// Where contour entries live: a folder INSIDE the render cache's
    /// directory — one cache root, one purge, one injected test directory.
    static func directory(inRenderCacheDirectory renderDirectory: URL) -> URL {
        renderDirectory.appendingPathComponent("PitchContours", isDirectory: true)
    }

    /// The contour's content key: the SOURCE FILE's identity (the render
    /// cache's own path ‖ size ‖ mtime fields) plus every detector field, hashed
    /// by the render cache's own digest. 16 hex chars, like every entry here.
    ///
    /// The render key embeds THIS string whenever a render shapes against the
    /// contour (`StretchRenderCache.renderKeys`), so anything that re-keys the
    /// contour re-keys the render. Throws when the source is unreadable.
    static func key(source: URL, detector: Detector) throws -> String {
        var fields = try StretchRenderCache.sourceIdentityFields(source: source)
        fields += [
            "pitch-contour",
            "layout:\(layoutVersion)",
            "analysisVersion:\(detector.analysisVersion)",
            "confidence:\(detector.confidenceThreshold.bitPattern)",
            "floor:\(detector.silenceFloorDbfs.bitPattern)",
            "modelRate:\(detector.modelSampleRate.bitPattern)",
            "hop:\(detector.hopLength)",
            "model:\(detector.modelIdentity)",
            "runtime:\(detector.runtimeIdentity)",
            // The analysis window, stated rather than implied: the contour is
            // the WHOLE file from source second 0.
            "window:whole-file-from-0",
        ]
        return StretchRenderCache.keyDigest(fields)
    }

    /// The on-disk payload. `key`/`analysisVersion`/`layout` are
    /// belt-and-braces (the filename already binds them): a mismatch reads as
    /// a miss, never as a contour.
    struct Sidecar: Codable {
        var layout: Int
        var key: String
        var analysisVersion: Int
        var detection: PitchDetectionResult
    }

    static func decode(_ data: Data, key: String, detector: Detector) -> PitchDetectionResult? {
        guard let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
              sidecar.layout == layoutVersion,
              sidecar.key == key,
              sidecar.analysisVersion == detector.analysisVersion
        else { return nil }
        return sidecar.detection
    }

    static func read(_ url: URL, key: String, detector: Detector) -> PitchDetectionResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data, key: key, detector: detector)
    }

    /// What one read of an entry found. I1-F2 (RT re-review NH-G): a miss is
    /// TWO cases, and only one of them may delete anything.
    enum Load {
        /// The entry decoded: the contour.
        case hit(PitchDetectionResult)
        /// There was nothing to read.
        case absent
        /// This caller READ bytes and they did not decode.
        case undecodable
    }

    /// Reads `url` ONCE and says which of the three it found.
    static func load(_ url: URL, key: String, detector: Detector) -> Load {
        guard let data = try? Data(contentsOf: url) else { return .absent }
        guard let decoded = decode(data, key: key, detector: detector) else { return .undecodable }
        return .hit(decoded)
    }

    // MARK: - Single flight (I1-F2, RT re-review NH-A)

    /// ONE detection per contour entry in flight, in this process. A cold
    /// detection runs over the whole take and cannot be interrupted part-way
    /// (`Detector.run` polls nothing), so before this, K requests that arrived
    /// while the entry was cold ran K whole-take detections at once: K span
    /// renders superseded by a drag or an agent's press loop, plus the
    /// whole-file render and the display. Now the first caller for an entry
    /// LEADS: it detects and ALWAYS commits, because every other caller for
    /// that entry needs the same contour, and the detector is deterministic
    /// (see the banner). Every later caller FOLLOWS: it waits for the
    /// leader's answer, and gives up as soon as its OWN `isCancelled` says so
    /// (polled every `followerPollSeconds`), so a superseded follower frees
    /// its thread within one poll instead of after a whole-take detection.
    ///
    /// Keyed by the entry's path, which names the render cache directory and
    /// the contour key, so two caches (two test directories) never share.
    /// The lock and the conditions are taken only by the detached tasks that
    /// call the seam, never by the render thread.
    final class Flight: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: PitchRenderContour?
        private var waiters = 0

        /// Hands the leader's answer to every follower, now and later.
        func finish(_ value: PitchRenderContour) {
            condition.lock()
            result = value
            condition.broadcast()
            condition.unlock()
        }

        /// The leader's answer, or nil once `isCancelled` is true. The
        /// caller's closure is never called while the condition is held.
        func wait(isCancelled: () -> Bool) -> PitchRenderContour? {
            condition.lock()
            waiters += 1
            condition.unlock()
            defer {
                condition.lock()
                waiters -= 1
                condition.unlock()
            }
            while true {
                if isCancelled() { return nil }
                condition.lock()
                if result == nil {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: PitchContourCache.followerPollSeconds))
                }
                let answer = result
                condition.unlock()
                if let answer { return answer }
            }
        }

        /// Followers waiting right now. Tests read it to prove the requests
        /// were concurrent (`waiterCountForTesting`).
        var waiterCount: Int {
            condition.lock()
            defer { condition.unlock() }
            return waiters
        }
    }

    /// How often a waiting follower asks whether it has been cancelled.
    static let followerPollSeconds = 0.010

    /// The flights in progress, by entry path.
    private static let flights = OSAllocatedUnfairLock<[String: Flight]>(initialState: [:])

    enum Role: Sendable {
        case leader(Flight)
        case follower(Flight)
    }

    /// Joins the flight for `path`: its leader when none is in progress, a
    /// follower otherwise.
    static func join(_ path: String) -> Role {
        flights.withLock { table in
            if let flight = table[path] { return .follower(flight) }
            let flight = Flight()
            table[path] = flight
            return .leader(flight)
        }
    }

    /// The leader's last act: its answer to the followers, then the flight
    /// leaves the table (a caller arriving between the two follows a finished
    /// flight and gets the answer at once).
    static func land(_ path: String, _ flight: Flight, with answer: PitchRenderContour) {
        flight.finish(answer)
        flights.withLock { table in
            if table[path] === flight { table[path] = nil }
        }
    }

    /// TEST INSTRUMENTATION (I1-F2, NH-A): followers waiting on the flight for
    /// `entry`, or 0 when no flight is in progress. Production never reads it.
    static func waiterCountForTesting(entry: URL) -> Int {
        flights.withLock { $0[entry.path] }?.waiterCount ?? 0
    }

    /// TEST SEAM (I1-F2, NH-G), never bound in production: runs in the LEADER
    /// right after its read of the entry missed, before it decides whether to
    /// delete anything. A test commits another writer's entry from here (a
    /// second app sharing the cache directory: the live app and a staging app
    /// both use `~/Library/Caches/DAWPro`), the one interleaving the
    /// single flight cannot rule out.
    @TaskLocal static var afterLeaderMissForTesting: (@Sendable () -> Void)?

    // MARK: - ⭐ THE SEAM

    /// ⭐⭐ **THE CONTOUR THE RENDER USES FOR A CLIP. There is no other.**
    ///
    /// `StretchRenderCache.performRender` calls this — inside its detached
    /// render task — for every render whose edit set `needsDetectedContour`,
    /// then builds its curve with `PitchRenderContour.curve(editSet:…)`. The
    /// editor's display must reach the same function
    /// (`AudioEngineControlling.renderPitchContour`, which lands here through
    /// `StretchRenderCache.renderContour`) and draw from the same result, so the
    /// picture and the sound are one contour, not two analyses that agree most
    /// of the time.
    ///
    /// **CONTRACT.**
    ///  * `source` is the clip's SOURCE FILE (`Clip.audioFileURL`), not a clip
    ///    window. `analysisVersion` is the clip's `PitchEditSet.analysisVersion`
    ///    — or, for a clip with no edits yet, `PitchEditSet.currentAnalysisVersion`.
    ///  * `.detected(result)`: `result` covers the WHOLE file from source second
    ///    0 at the product's detection settings; `result.frames[i].timeSeconds`
    ///    is SOURCE-FILE-ABSOLUTE and is the frame START (the curve places each
    ///    value at the frame centre — `PitchRenderContour.frameValueOffsetSeconds`).
    ///    It is exactly what is on disk: a fresh detection is committed first
    ///    (first writer wins) and the committed bytes are what every caller gets.
    ///  * `.analysisVersionMismatch`: the edit set came from another detector
    ///    generation. NOTHING is detected or read — the edits are never shaped
    ///    against a contour they were not made against (§7.2).
    ///  * `.unavailable(reason)`: the file could not be read or detection
    ///    failed. Nothing is cached, so the next call retries. I1-F2: also the
    ///    answer to a caller whose own `isCancelled` fired while it waited for
    ///    another caller's detection. Only a caller that passes `isCancelled`
    ///    can see that, and it must check its flag after the call and throw,
    ///    as `StretchRenderCache.resolveRenderContour` does, so that answer is
    ///    never shaped against and never reported as a fallback.
    ///  * TOTAL: never throws, never returns a contour with a reason attached,
    ///    never fabricates frames. Blocking — call it from a detached task only;
    ///    never from the main actor, never from the render thread.
    ///
    /// **I1-F2: SINGLE FLIGHT (RT re-review NH-A).** However many span renders,
    /// whole-file renders and display reads ask for a cold entry at once, ONE
    /// detection runs (`Flight`). Any caller may lead it, a DRAFT span render
    /// included: see `StretchRenderCache.resolveRenderContour` for why a draft
    /// may start a detection rather than only wait for one.
    static func renderContour(source: URL, analysisVersion: Int,
                              renderCacheDirectory: URL,
                              detector: Detector,
                              isCancelled: () -> Bool = { false }) -> PitchRenderContour {
        guard analysisVersion == detector.analysisVersion else {
            return .analysisVersionMismatch(editSet: analysisVersion,
                                            detector: detector.analysisVersion)
        }
        let key: String
        do {
            key = try Self.key(source: source, detector: detector)
        } catch {
            return .unavailable(reason: "the source file could not be read: \(error.localizedDescription)")
        }
        let directory = Self.directory(inRenderCacheDirectory: renderCacheDirectory)
        let entry = directory.appendingPathComponent(key + ".json")
        // The hot path: one read, shared with nobody, deleting nothing.
        if case .hit(let cached) = load(entry, key: key, detector: detector) {
            return .detected(cached)
        }
        switch join(entry.path) {
        case .follower(let flight):
            return flight.wait(isCancelled: isCancelled)
                ?? .unavailable(reason: "the request was cancelled while the pitch analysis ran")
        case .leader(let flight):
            let answer = lead(entry: entry, directory: directory, key: key,
                              source: source, detector: detector)
            land(entry.path, flight, with: answer)
            return answer
        }
    }

    /// The leader's work: read again, detect, commit, and answer with the
    /// committed bytes. Runs for at most one caller per entry at a time.
    private static func lead(entry: URL, directory: URL, key: String, source: URL,
                             detector: Detector) -> PitchRenderContour {
        // Read AGAIN under the lead: a previous leader may have committed
        // between this caller's first read and its turn.
        let loaded = load(entry, key: key, detector: detector)
        if case .hit(let cached) = loaded {
            return .detected(cached)
        }
        afterLeaderMissForTesting?()
        // ⛔ I1-F2 (RT re-review NH-G): remove ONLY bytes this caller READ and
        // could not decode (truncated, an older layout under a colliding
        // name), or the first-writer-wins commit below would be blocked by
        // them forever and every render would re-detect. It used to remove
        // whatever EXISTED at this point, and a valid entry another writer
        // committed after this caller's read missed is not what this caller
        // read: deleting it cost a detection, and would have broken "everyone
        // reads the winner's bytes" for a detector that was not deterministic.
        // In this process the single flight already keeps other writers out
        // of this window; another process sharing the cache directory does not
        // (`afterLeaderMissForTesting`).
        if case .undecodable = loaded {
            try? FileManager.default.removeItem(at: entry)
        }

        let fresh: PitchDetectionResult
        do {
            fresh = try detector.run(source, detector)
        } catch {
            return .unavailable(reason: "pitch detection failed: \(error)")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Sidecar(
            layout: layoutVersion, key: key,
            analysisVersion: detector.analysisVersion, detection: fresh))
        else {
            // Not cacheable (a value JSON cannot carry). Detection is
            // deterministic, so every session that lands here detects the same
            // contour again — consistent, only slower.
            return .detected(fresh)
        }
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let partial = directory.appendingPathComponent(
                "\(key).partial-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: partial) }  // no-op after the move
            try data.write(to: partial)
            do {
                // `moveItem` refuses to overwrite: FIRST WRITER WINS. A sibling
                // (another clip's render, the display) that committed first
                // keeps its bytes and this detection is discarded below.
                try FileManager.default.moveItem(at: partial, to: entry)
            } catch {
                guard FileManager.default.fileExists(atPath: entry.path) else { throw error }
            }
        } catch {
            // Could not commit (disk full, permissions). Use the SAME bytes the
            // cache would have held, so a render in this state and a render
            // from a healthy cache shape against identical values.
            return .detected(decode(data, key: key, detector: detector) ?? fresh)
        }
        // Whoever won the commit, THAT entry is the contour — for this render,
        // for the next one, and for the display.
        if let committed = read(entry, key: key, detector: detector) {
            return .detected(committed)
        }
        return .detected(decode(data, key: key, detector: detector) ?? fresh)
    }
}
