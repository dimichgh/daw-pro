import AVFAudio
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// i1-long-take (item B): HOW LONG DOES "HEAR THE NOTE" WAIT ON A LONG TAKE,
/// AGAINST ITS 8-SECOND EXPIRY?
///
/// ENV-GATED MEASUREMENT HARNESS: nothing here runs in a normal
/// `./scripts/test.sh`. The takes are SYNTHETIC voice-like lines made by the
/// durable kit's `i1-long-take/i1lt-make-takes.py` (never the user's audio);
/// their paths and note spans come from its manifest.
///
///     I1LT_MANIFEST=<manifest.json> I1LT_OUT=<dir> [I1LT_EDITS=6] \
///       [I1LT_LENGTHS=30,90] [I1LT_LABEL=run1] \
///       ./scripts/test.sh --filter i1LongTakeLatency
///
/// THE SAME SHAPE AS I1's `clipSpanLatencyOnTheUsersTake`: store → engine →
/// render cache (fresh directory), the voice's delivery spy, the cache's
/// commit signal timestamped while its forwarding is kept; per edit a PRESS
/// (the note as it sounds now), a COMMIT through the store (+200 c), the
/// RELEASE door (`auditionClipNotesAfterEdit`), then the render and the
/// buffer, timed from the commit. ONE DELIBERATE DIFFERENCE: the note table is
/// built from the manifest's known note spans instead of running detection,
/// because detection is not on the timed path for a plain offset edit
/// (`setClipNotePitchOffset` reads the stored table, and `performRender`
/// detects only for a set that needs the contour, which a +200 c offset never
/// does). That is asserted per take (`needsDetectedContour == false`).
///
/// The 8 s expiry is NOT re-implemented here: the store's own
/// `ClipNoteAuditionController` runs, so an audition whose render lands late
/// is DROPPED by the product and no buffer arrives. `delivered` records what
/// the product did; the timings record why.
///
/// ⚠️ MAIN-ACTOR CENSUS: `@MainActor` is spelled PER TEST, never on the suite
/// (the `ContourRenderListeningTests` precedent), so this file adds no
/// `@MainActor`-isolated suite to `MainActorOccupancySiteTests` Leg C. Waits
/// use `Task.sleep` only. Nothing plays: every buffer goes to the spy, and the
/// test ends by asserting the engine never ran.
@Suite("i1-long-take — commit → render → audition on long synthetic takes (env-gated)", .serialized)
struct I1LongTakeLatencyHarnessTests {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["I1LT_MANIFEST"] != nil && env["I1LT_OUT"] != nil

    struct Manifest: Decodable {
        struct Note: Decodable {
            let start: Double
            let end: Double
            let hz: Double
        }
        struct Take: Decodable {
            let seconds: Int
            let channels: Int
            let path: String
            let notes: [Note]
            let sampleMD5: String
        }
        let takes: [Take]
    }

    private final class Deliveries {
        var buffers: [AVAudioPCMBuffer] = []
        var arrivals: [ContinuousClock.Instant] = []
    }

    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    static func log(_ message: String) { print("i1-long-take| \(message)") }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads
    }

    static func num(_ x: Double?) -> Any {
        if let x, x.isFinite { return x }
        return NSNull()
    }

    @MainActor
    static func wait(seconds: Double, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    @Test("B1 long synthetic takes: commit → render complete → audition buffer, ≥5 single-note edits per length, the 8 s expiry observed (env-gated)",
          .enabled(if: enabled))
    @MainActor
    func i1LongTakeLatency() async throws {
        let manifestURL = URL(fileURLWithPath: try #require(Self.env["I1LT_MANIFEST"]))
        let out = URL(fileURLWithPath: try #require(Self.env["I1LT_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let edits = max(5, Int(Self.env["I1LT_EDITS"] ?? "") ?? 6)
        let only = Self.env["I1LT_LENGTHS"].map { Set($0.split(separator: ",").compactMap { Int($0) }) }
        let label = Self.env["I1LT_LABEL"] ?? "run"
        var takes: [[String: Any]] = []
        for take in manifest.takes where only?.contains(take.seconds) ?? true {
            takes.append(try await Self.measure(take: take, edits: edits, out: out, label: label))
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "label": label, "manifest": manifestURL.path, "editsPerTake": edits,
            "renderWaitSeconds": ClipNoteAuditionPolicy.renderWaitSeconds,
            "debounceMilliseconds": StretchRenderCache.debounceMilliseconds,
            "takes": takes,
        ], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("long-take-\(label).json"))
        Self.log("wrote \(out.appendingPathComponent("long-take-\(label).json").path)")
    }

    @MainActor
    static func measure(take: Manifest.Take, edits: Int, out: URL, label: String) async throws -> [String: Any] {
        let url = URL(fileURLWithPath: take.path)
        let file = try AVAudioFile(forReading: url)
        let frames = Int(file.length)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let table = PitchEditSet(segments: take.notes.map {
            NoteSegment(startSeconds: $0.start, endSeconds: $0.end, detectedHz: $0.hz,
                        detectedConfidence: 0.95)
        })
        try #require(table.segments.count == take.notes.count, "the note table healed some notes")
        let clip = Clip(name: "take", startBeat: 0, lengthBeats: (duration * 4).rounded(.up),
                        audioFileURL: url, pitchEdits: table)
        let track = Track(name: "Vox", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])
        let engine = AudioEngine()
        let cacheDir = out.appendingPathComponent("render-cache-\(label)-\(take.seconds)s", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        // I1's order: cache first, then the store (which installs its
        // render-complete sink), then the timestamping wrapper that forwards.
        engine.stretchCache = StretchRenderCache(directory: cacheDir)
        let deliveries = Deliveries()
        engine.clipAuditionDeliveryForTesting = { buffer in
            deliveries.buffers.append(buffer)
            deliveries.arrivals.append(ContinuousClock.now)
        }
        store.engine = engine
        let renders = Box<[(UUID, ContinuousClock.Instant)]>([])
        let forward = engine.stretchCache.onRenderComplete
        engine.stretchCache.onRenderComplete = { id in
            renders.value.append((id, ContinuousClock.now))
            forward?(id)
        }
        engine.tracksDidChange(store.tracks)

        let candidates = table.segments.filter { $0.durationSeconds >= 0.30 }
        try #require(candidates.count >= edits)
        let picked = (0..<edits).map { candidates[$0 * (candidates.count - 1) / max(1, edits - 1)] }
        let loadAtStart = loadAverage()
        let started = ContinuousClock.now
        Self.log(String(format: "take %d s (%d ch, %d notes): load %.2f %.2f %.2f",
                        take.seconds, take.channels, table.segments.count,
                        loadAtStart[0], loadAtStart[1], loadAtStart[2]))

        var rows: [[String: Any]] = []
        for (index, note) in picked.enumerated() {
            // PRESS: the note as it sounds now.
            let pressCount = deliveries.buffers.count
            let press = try store.auditionClipNotes(clipId: clip.id, segmentIds: [note.id])
            let pressed = try await wait(seconds: 10) { deliveries.buffers.count > pressCount }

            // COMMIT, then the release door, exactly as I1 times it (from before the commit).
            let rendersBefore = renders.value.count
            let loadAtCommit = loadAverage()[0]
            let committedAt = ContinuousClock.now
            _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: note.id, offsetCents: 200)
            let release = try store.auditionClipNotesAfterEdit(.pitch, clipId: clip.id,
                                                               segmentIds: [note.id], enabled: true)
            let releasedAt = ContinuousClock.now
            let bufferCount = deliveries.buffers.count
            if index == 0 {
                #expect(store.tracks[0].clips[0].pitchEdits?.needsDetectedContour == false)
            }
            let rendered = try await wait(seconds: 240) { renders.value.count > rendersBefore }
            // After the render lands the controller plays (inside its 8 s) or drops the wait.
            let delivered = try await wait(seconds: 3) { deliveries.buffers.count > bufferCount }
            let renderAt = rendered ? renders.value[rendersBefore].1 : nil
            let commitToRender = renderAt.map { ms($0 - committedAt) }
            let releaseToRender = renderAt.map { ms($0 - releasedAt) }
            let commitToBuffer = delivered ? ms(deliveries.arrivals[bufferCount] - committedAt) : nil
            let stillPending = store.clipNoteAudition.pending != nil
            let playedFile = engine.graph.clipFileURLForTesting(clipID: clip.id)
            let renderFrames: Any = try playedFile.map { Int(try AVAudioFile(forReading: $0).length) as Any }
                ?? NSNull()
            let lastOutcome = store.clipNoteAudition.lastRenderCompleteOutcome
                .map { String(describing: $0) } ?? "none"
            let row: [String: Any] = [
                "edit": index, "noteStart": note.startSeconds, "noteEnd": note.endSeconds,
                "pressAudible": press.isAudible, "pressDelivered": pressed,
                "release": release.reason?.rawValue ?? "sounded",
                "commitToRenderMs": num(commitToRender), "releaseToRenderMs": num(releaseToRender),
                "commitToBufferMs": num(commitToBuffer), "delivered": delivered,
                "rendered": rendered, "stillPendingAfter": stillPending,
                "lastRenderCompleteOutcome": lastOutcome,
                "renderFrames": renderFrames, "sourceFrames": frames,
                "loadAtCommit": loadAtCommit,
            ]
            rows.append(row)
            Self.log(String(format: "take %d s edit %d (%.2f-%.2f s): release %@ | commit→render %.0f ms | release→render %.0f ms | delivered %@ (commit→buffer %@) | load %.2f",
                            take.seconds, index, note.startSeconds, note.endSeconds,
                            (release.reason?.rawValue ?? "sounded") as NSString,
                            commitToRender ?? .nan, releaseToRender ?? .nan,
                            (delivered ? "YES" : "NO") as NSString,
                            (commitToBuffer.map { String(format: "%.0f ms", $0) } ?? "-") as NSString,
                            loadAtCommit))
        }
        let loadAtEnd = loadAverage()
        #expect(!engine.isRunning, "the harness started the audio hardware")
        try? FileManager.default.removeItem(at: cacheDir)   // renders of a 300 s take are 57.6 MB each
        return [
            "seconds": take.seconds, "channels": take.channels, "path": take.path,
            "sampleMD5": take.sampleMD5, "notes": table.segments.count, "sourceFrames": frames,
            "loadAverageAtStart": loadAtStart, "loadAverageAtEnd": loadAtEnd,
            "elapsedMs": ms(ContinuousClock.now - started), "edits": rows,
        ]
    }
}
