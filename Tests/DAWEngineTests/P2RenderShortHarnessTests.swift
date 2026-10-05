import AVFAudio
import CSignalsmithStretch
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// p2-render-short (item A): TWO OF SEVEN +200 c NOTE EDITS READ SHORT ON THE
/// USER'S TAKE. Is the RENDER short, or is the one instrument wrong there?
///
/// ENV-GATED MEASUREMENT HARNESS. Nothing here runs in a normal
/// `./scripts/test.sh`: every test is `.enabled(if:)` on its own environment
/// variables, and the user's recording never enters the tree (the paths come
/// from the environment, and every output is written where the caller says).
///
///     P2RS_TAKE=<dry-norm.wav> P2RS_OUT=<dir> [P2RS_I1_CAF=<I1's all-7 render>] \
///       ./scripts/test.sh --filter p2rsTakeEvidence
///     P2RS_SYNTH_MANIFEST=<manifest.json> P2RS_OUT=<dir> \
///       ./scripts/test.sh --filter p2rsSyntheticControls
///
/// What it measures, all through the PRODUCT's own code:
///  * the note table the editor would draw (`PitchContourCache.detectWholeFile`
///    → `PitchNoteTable.detected`), and the SAME seven notes I1 picked;
///  * the edits made through the store (`setClipNotePitchOffset`), the way the
///    editor commits them;
///  * the render through `StretchRenderCache.renderIfNeeded` (the function the
///    engine calls), and the SAME stretch re-run with a SPY on the transpose
///    closure, proven bit-identical to that render, so the logged values ARE
///    what `css_set_transpose_semitones` received, hop by hop;
///  * the ASKED shift per output frame, from the product's own plan
///    (`StretchCurvePlan.make`, contour nil, which is what `performRender`
///    builds for this set: asserted, not assumed);
///  * the I1 harness's own YIN (`I1Signals.yinHz`, called, not copied), per
///    frame, on the source and the render.
/// The analysis (pYIN, a harmonic-sum estimator, spectrograms) runs in Python
/// from the durable kit folder; see the README written next to the outputs.
///
/// ⚠️ MAIN-ACTOR CENSUS: `@MainActor` is spelled PER TEST, never on the suite
/// (the `ContourRenderListeningTests` / `NoteSplitListeningTests` precedent),
/// so this file adds no `@MainActor`-isolated suite to
/// `MainActorOccupancySiteTests` Leg C. Waits use `Task.sleep` only.
@Suite("p2-render-short — per-frame evidence for short-reading note edits (env-gated)", .serialized)
struct P2RenderShortHarnessTests {
    static let env = ProcessInfo.processInfo.environment
    static let takeEnabled = env["P2RS_TAKE"] != nil && env["P2RS_OUT"] != nil
    static let synthEnabled = env["P2RS_SYNTH_MANIFEST"] != nil && env["P2RS_OUT"] != nil

    static let sampleRate = 48_000.0
    /// The per-frame analysis grid: 5 ms between frame centres.
    static let gridHop = 240
    /// The I1 YIN frame (I1Signals.medianYinHz's default).
    static let yinFrame = 2_048

    static func log(_ message: String) { print("p2rs| \(message)") }

    static func num(_ x: Double?) -> Any {
        if let x, x.isFinite { return x }
        return NSNull()
    }

    static func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    /// The source, read EXACTLY the way `StretchRenderCache.performRender`
    /// reads it: processing format, 32 768-frame chunks, until `length`.
    static func readLikePerformRender(_ url: URL) throws -> [[Float]] {
        let reader = try AVAudioFile(forReading: url)
        let format = reader.processingFormat
        let channels = Int(format.channelCount)
        var planar = [[Float]](repeating: [], count: channels)
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
            throw OfflineStretcherError.allocationFailed
        }
        while reader.framePosition < reader.length {
            try reader.read(into: chunk)
            guard chunk.frameLength > 0, let data = chunk.floatChannelData else { break }
            for channel in 0..<channels {
                planar[channel].append(contentsOf: UnsafeBufferPointer(
                    start: data[channel], count: Int(chunk.frameLength)))
            }
        }
        return planar
    }

    /// The stretch `performRender` runs for a plan, re-run with a SPY on the
    /// transpose closure. Same function, same arguments; the caller proves the
    /// output bit-identical to the product's render before believing the log.
    static func spiedStretch(input: [[Float]], plan: StretchCurvePlan)
        async throws -> (output: [[Float]], calls: [(frame: Int, semitones: Double)]) {
        try await Task.detached(priority: .userInitiated) {
            var calls: [(frame: Int, semitones: Double)] = []
            let output = try OfflineStretcher.stretchTransposeCurve(
                input: input, sampleRate: plan.sampleRate, ratio: plan.ratio,
                semitonesAtOutputFrame: { frame in
                    let value = plan.semitones(atOutputFrame: frame)
                    calls.append((frame, value))
                    return value
                },
                formantPreserve: false,
                compensation: OfflineStretcher.curveLatencyCompensation(
                    sampleRate: plan.sampleRate))
            return (output, calls)
        }.value
    }

    static func bitMismatches(_ a: [Float], _ b: [Float]) -> Int {
        var count = abs(a.count - b.count)
        for i in 0..<min(a.count, b.count) where a[i].bitPattern != b[i].bitPattern {
            count += 1
        }
        return count
    }

    /// The hop and latency the stretcher reports (measured, not derived).
    static func stretcherGeometry() -> (interval: Int, compensation: Int) {
        let handle = css_create(1, Float(sampleRate), 1)
        defer { if let handle { css_destroy(handle) } }
        let interval = handle.map { Int(css_interval_samples($0)) } ?? -1
        let compensation: Int
        switch OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate) {
        case .frames(let n): compensation = n
        case .none: compensation = 0
        }
        return (interval, compensation)
    }

    /// `I1Signals.yinHz` per frame on the 5 ms grid, frame centred on each
    /// grid point, search range [0.6, 1.7] × `anchorHz` (I1's anchoring).
    /// Detached: the harness is `@MainActor` and this is seconds of arithmetic.
    static func yinFrames(_ samples: [Float], centres: [Int], anchorHz: Double) async -> [Double?] {
        await Task.detached(priority: .userInitiated) {
            centres.map { centre -> Double? in
                let lo = centre - yinFrame / 2
                let hi = lo + yinFrame
                guard lo >= 0, hi <= samples.count else { return nil }
                return I1Signals.yinHz(samples[lo..<hi], sampleRate: sampleRate,
                                       minHz: anchorHz * 0.6, maxHz: anchorHz * 1.7)
            }
        }.value
    }

    /// I1's own statistic, reproduced: `medianYinHz` over [start+50 ms, end−50 ms).
    static func i1Median(_ samples: [Float], start: Double, end: Double, anchorHz: Double) -> Double? {
        let lo = Int(((start + 0.05) * sampleRate).rounded())
        let hi = Int(((end - 0.05) * sampleRate).rounded())
        guard hi - lo > 4_096, hi <= samples.count else { return nil }
        return I1Signals.medianYinHz(samples[lo..<hi], sampleRate: sampleRate,
                                     minHz: anchorHz * 0.6, maxHz: anchorHz * 1.7)
    }

    static func gridCentres(start: Double, end: Double, pad: Double) -> [Int] {
        let first = Int(((start - pad) * sampleRate / Double(gridHop)).rounded(.down)) * gridHop
        let last = Int(((end + pad) * sampleRate).rounded())
        return Array(stride(from: max(0, first), through: last, by: gridHop))
    }

    // MARK: - A1: the user's take

    @Test("A1 the user's take: the seven I1 notes, the plan, the spied stretch, and the I1 YIN per frame (env-gated)",
          .enabled(if: takeEnabled))
    @MainActor
    func p2rsTakeEvidence() async throws {
        let take = URL(fileURLWithPath: try #require(Self.env["P2RS_TAKE"]))
        let out = URL(fileURLWithPath: try #require(Self.env["P2RS_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let editCents = Double(Self.env["P2RS_CENTS"] ?? "") ?? 200
        let controlCents = Double(Self.env["P2RS_CONTROL_CENTS"] ?? "") ?? 150
        let started = ContinuousClock.now

        // (1) The note table the editor would draw, and I1's pick rule, verbatim.
        let detection = try PitchContourCache.detectWholeFile(take, .product)
        let table = PitchNoteTable.detected(from: detection)
        let candidates = table.segments.filter {
            $0.durationSeconds >= 0.30 && $0.detectedConfidence >= 0.5 && $0.detectedHz > 0
        }
        try #require(candidates.count >= 5)
        let count = min(7, candidates.count)
        let picked = (0..<count).map { candidates[$0 * (candidates.count - 1) / max(1, count - 1)] }
        let pickedIDs = picked.map(\.id)
        for (k, note) in picked.enumerated() {
            Self.log(String(format: "picked note %d: %.3f-%.3f s, detected %.4f Hz, conf %.3f",
                            k, note.startSeconds, note.endSeconds, note.detectedHz,
                            note.detectedConfidence))
        }

        // (2) The edits, through the store, as the editor commits them.
        let takeFile = try AVAudioFile(forReading: take)
        let duration = Double(takeFile.length) / takeFile.processingFormat.sampleRate
        #expect(takeFile.processingFormat.sampleRate == Self.sampleRate)
        func editedClip(cents: Double, only: Set<UUID>? = nil) throws -> Clip {
            let clip = Clip(name: "take", startBeat: 0, lengthBeats: (duration * 4).rounded(.up),
                            audioFileURL: take, pitchEdits: table)
            let store = ProjectStore(tracks: [Track(name: "Vox", kind: .audio, clips: [clip])])
            for id in pickedIDs where only?.contains(id) ?? true {
                _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: id, offsetCents: cents)
            }
            return store.tracks[0].clips[0]
        }
        let clip = try editedClip(cents: editCents)
        let set = try #require(clip.pitchEdits)
        // What `performRender` builds for this set: no contour, because no
        // segment asks for drift/vibrato shaping. Asserted, not assumed.
        #expect(set.needsDetectedContour == false)
        let edited = set.segments.filter { $0.pitchOffsetCents != 0 }
        #expect(Set(edited.map(\.id)) == Set(pickedIDs), "the store edited other notes than I1's seven")
        #expect(edited.allSatisfy { $0.pitchOffsetCents == editCents })
        let plan = try #require(StretchCurvePlan.make(
            editSet: set, clipPitchShiftSemitones: clip.pitchShiftSemitones,
            sampleRate: Self.sampleRate, ratio: clip.stretchRatio, contour: nil))

        // (3) Single-note plan vs the cumulative plan over span ± 100 ms: I1's
        // renders were cumulative; this shows a neighbour's edit cannot reach.
        var singleVsCumulative: [Int] = []
        for note in picked {
            let single = try editedClip(cents: editCents, only: [note.id])
            let singlePlan = try #require(StretchCurvePlan.make(
                editSet: single.pitchEdits, clipPitchShiftSemitones: 0,
                sampleRate: Self.sampleRate, ratio: 1, contour: nil))
            let lo = Int(((note.startSeconds - 0.1) * Self.sampleRate).rounded())
            let hi = Int(((note.endSeconds + 0.1) * Self.sampleRate).rounded())
            var mismatches = 0
            for frame in lo..<hi
            where singlePlan.semitones(atOutputFrame: frame).bitPattern
                != plan.semitones(atOutputFrame: frame).bitPattern {
                mismatches += 1
            }
            singleVsCumulative.append(mismatches)
        }
        #expect(singleVsCumulative.allSatisfy { $0 == 0 },
                "a neighbour's edit reached a note's plan: \(singleVsCumulative)")

        // (4) The PRODUCT render (the function the engine calls).
        let cacheDir = out.appendingPathComponent("render-cache", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        let cache = StretchRenderCache(directory: cacheDir)
        let renderStart = ContinuousClock.now
        let renderURL = try await cache.renderIfNeeded(
            clipID: clip.id, source: take, params: StretchRenderCache.Params(clip: clip))
        let renderMs = Self.ms(ContinuousClock.now - renderStart)
        let render = try I1Signals.read(renderURL).planar[0]

        // (5) The same stretch, spied. Bit-identical to the render, or the log
        // is not what the product ran.
        let source = try Self.readLikePerformRender(take)
        let spied = try await Self.spiedStretch(input: source, plan: plan)
        let spyMismatches = Self.bitMismatches(spied.output[0], render)
        #expect(spyMismatches == 0, "the spied stretch is not the product's render")

        // (6) I1's own render, if given: is this the same audio I1 measured?
        var i1RenderMismatches: Any = NSNull()
        if let i1Path = Self.env["P2RS_I1_CAF"] {
            let i1Render = try I1Signals.read(URL(fileURLWithPath: i1Path)).planar[0]
            i1RenderMismatches = Self.bitMismatches(i1Render, render)
        }

        // (7) A planted SHORT render (every picked note at +controlCents), so
        // the analysis can prove it SEES a shortfall when there is one.
        let control = try editedClip(cents: controlCents)
        let controlURL = try await cache.renderIfNeeded(
            clipID: control.id, source: take, params: StretchRenderCache.Params(clip: control))

        // (8) Per note: the asked curve (1 ms), the I1 YIN per frame on the
        // source and on the render, and I1's own median statistic.
        let geometry = Self.stretcherGeometry()
        var notes: [[String: Any]] = []
        for (k, note) in picked.enumerated() {
            let index = try #require(set.segments.firstIndex { $0.id == note.id })
            let previous = index > 0 ? set.segments[index - 1] : nil
            let next = index + 1 < set.segments.count ? set.segments[index + 1] : nil
            let askedFrames = Array(stride(
                from: Int(((note.startSeconds - 0.15) * Self.sampleRate).rounded()),
                through: Int(((note.endSeconds + 0.15) * Self.sampleRate).rounded()), by: 48))
            let asked = askedFrames.map { plan.semitones(atOutputFrame: $0) }
            let centres = Self.gridCentres(start: note.startSeconds, end: note.endSeconds, pad: 0.1)
            let yinSource = await Self.yinFrames(source[0], centres: centres, anchorHz: note.detectedHz)
            let yinRender = await Self.yinFrames(render, centres: centres, anchorHz: note.detectedHz)
            let i1Source = Self.i1Median(source[0], start: note.startSeconds, end: note.endSeconds,
                                         anchorHz: note.detectedHz)
            let i1Render = Self.i1Median(render, start: note.startSeconds, end: note.endSeconds,
                                         anchorHz: note.detectedHz)
            let i1Cents = (i1Source != nil && i1Render != nil)
                ? I1Signals.cents(i1Render!, from: i1Source!) : .nan
            Self.log(String(format: "note %d: I1 statistic reproduced on this render: %.3f -> %.3f Hz = %+.2f c",
                            k, i1Source ?? .nan, i1Render ?? .nan, i1Cents))
            // The hops whose governed delivered window touches span ± 100 ms,
            // with the value the stretcher was handed for each.
            let lookupOffset = geometry.compensation + geometry.interval / 2
            let spanLo = Int(((note.startSeconds - 0.1) * Self.sampleRate).rounded())
            let spanHi = Int(((note.endSeconds + 0.1) * Self.sampleRate).rounded())
            var hops: [[String: Any]] = []
            for (i, call) in spied.calls.enumerated() {
                // Call 0 is the pre-roll; call i ≥ 1 is the hop at outDone = (i−1)×interval.
                // The product's own model (OfflineStretcher.curveLookupFrame): the value
                // read at outDone + n + interval/2 governs delivered [outDone + n, + interval).
                let outDone = call.frame - lookupOffset
                let governedLo = outDone + geometry.compensation
                let governedHi = governedLo + geometry.interval
                guard governedHi > spanLo, governedLo < spanHi else { continue }
                hops.append(["call": i, "lookupFrame": call.frame, "outDone": outDone,
                             "governedLo": governedLo, "governedHi": governedHi,
                             "semitones": call.semitones])
            }
            func neighbour(_ s: NoteSegment?) -> Any {
                guard let s else { return NSNull() }
                return ["startSeconds": s.startSeconds, "endSeconds": s.endSeconds,
                        "detectedHz": s.detectedHz, "offsetCents": s.pitchOffsetCents] as [String: Any]
            }
            notes.append([
                "note": k, "segmentIndex": index, "id": note.id.uuidString,
                "startSeconds": note.startSeconds, "endSeconds": note.endSeconds,
                "detectedHz": note.detectedHz, "detectedConfidence": note.detectedConfidence,
                "previous": neighbour(previous),
                "next": neighbour(next),
                "askedFrames": askedFrames, "askedSemitones": asked,
                "gridCentres": centres,
                "yinSourceHz": yinSource.map { Self.num($0) },
                "yinRenderHz": yinRender.map { Self.num($0) },
                "i1MedianSourceHz": Self.num(i1Source), "i1MedianRenderHz": Self.num(i1Render),
                "i1MedianCents": Self.num(i1Cents),
                "singleVsCumulativePlanMismatches": singleVsCumulative[k],
                "hops": hops,
            ])
        }

        // (9) The product's own detector on the source and on the render.
        let renderDetection = try PitchContourCache.detectWholeFile(renderURL, .product)
        func frames(_ d: PitchDetectionResult) -> [[String: Any]] {
            d.frames.map { ["t": $0.timeSeconds, "hz": Self.num($0.frequencyHz), "conf": $0.confidence] }
        }

        let summary: [String: Any] = [
            "take": take.path, "takeSeconds": duration,
            "editCents": editCents, "controlCents": controlCents,
            "tableSegments": table.segments.count, "candidates": candidates.count,
            "needsDetectedContour": set.needsDetectedContour,
            "retuneMs": set.retuneMs,
            "renderURL": renderURL.path, "controlRenderURL": controlURL.path,
            "renderMs": renderMs,
            "spyVsRenderMismatchedSamples": spyMismatches,
            "i1RenderVsThisRenderMismatchedSamples": i1RenderMismatches,
            "stretcherInterval": geometry.interval, "compensationFrames": geometry.compensation,
            "spyCalls": spied.calls.count,
            "segments": set.segments.map {
                ["startSeconds": $0.startSeconds, "endSeconds": $0.endSeconds,
                 "detectedHz": $0.detectedHz, "detectedConfidence": $0.detectedConfidence,
                 "offsetCents": $0.pitchOffsetCents] as [String: Any]
            },
            "notes": notes,
            "sourceDetection": frames(detection),
            "renderDetection": frames(renderDetection),
            "elapsedMs": Self.ms(ContinuousClock.now - started),
        ]
        try Self.writeJSON(summary, to: out.appendingPathComponent("take-evidence.json"))
        Self.log("wrote \(out.appendingPathComponent("take-evidence.json").path); spy mismatches "
                 + "\(spyMismatches); vs I1 render \(i1RenderMismatches); render \(Int(renderMs)) ms")
    }

    // MARK: - A2: synthetic controls through the same render path

    struct Manifest: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let hz: Double
            let cents: Double
        }
        struct Case: Decodable {
            let name: String
            let source: String
            /// Index into `segments` of the note under test.
            let note: Int
            let segments: [Segment]
        }
        let cases: [Case]
        /// One case also goes through store → engine → cache, and its file is
        /// compared with `renderIfNeeded`'s, so the sweep's path is the engine's.
        let engineCase: String?
    }

    @Test("A2 synthetic voice-like controls: the same product render path, the plan, the spy, the I1 YIN per frame (env-gated)",
          .enabled(if: synthEnabled))
    @MainActor
    func p2rsSyntheticControls() async throws {
        let manifestURL = URL(fileURLWithPath: try #require(Self.env["P2RS_SYNTH_MANIFEST"]))
        let out = URL(fileURLWithPath: try #require(Self.env["P2RS_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let cacheDir = out.appendingPathComponent("render-cache", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        let cache = StretchRenderCache(directory: cacheDir)
        let geometry = Self.stretcherGeometry()
        var results: [[String: Any]] = []
        var renders: [String: URL] = [:]
        var sets: [String: PitchEditSet] = [:]

        for item in manifest.cases {
            let sourceURL = URL(fileURLWithPath: item.source)
            let set = PitchEditSet(segments: item.segments.map {
                NoteSegment(startSeconds: $0.start, endSeconds: $0.end, detectedHz: $0.hz,
                            detectedConfidence: 0.9, pitchOffsetCents: $0.cents)
            })
            try #require(set.segments.count == item.segments.count, "\(item.name): segments healed")
            #expect(set.needsDetectedContour == false)
            let note = set.segments[item.note]
            let params = StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: false,
                                                   pitchEdits: set)
            let url = try await cache.renderIfNeeded(clipID: UUID(), source: sourceURL, params: params)
            renders[item.name] = url
            sets[item.name] = set
            let render = try I1Signals.read(url).planar[0]
            let source = try Self.readLikePerformRender(sourceURL)
            let plan = try #require(StretchCurvePlan.make(
                editSet: set, clipPitchShiftSemitones: 0, sampleRate: Self.sampleRate, ratio: 1,
                contour: nil))
            let spied = try await Self.spiedStretch(input: source, plan: plan)
            let spyMismatches = Self.bitMismatches(spied.output[0], render)
            #expect(spyMismatches == 0, "\(item.name): the spied stretch is not the render")
            let firstStart = set.segments.first?.startSeconds ?? 0
            let lastEnd = set.segments.last?.endSeconds ?? 0
            let askedFrames = Array(stride(
                from: max(0, Int(((firstStart - 0.15) * Self.sampleRate).rounded())),
                through: Int(((lastEnd + 0.15) * Self.sampleRate).rounded()), by: 48))
            let centres = Self.gridCentres(start: note.startSeconds, end: note.endSeconds, pad: 0.1)
            let yinSource = await Self.yinFrames(source[0], centres: centres, anchorHz: note.detectedHz)
            let yinRender = await Self.yinFrames(render, centres: centres, anchorHz: note.detectedHz)
            let i1Source = Self.i1Median(source[0], start: note.startSeconds, end: note.endSeconds,
                                         anchorHz: note.detectedHz)
            let i1Render = Self.i1Median(render, start: note.startSeconds, end: note.endSeconds,
                                         anchorHz: note.detectedHz)
            let i1Cents = (i1Source != nil && i1Render != nil)
                ? I1Signals.cents(i1Render!, from: i1Source!) : .nan
            Self.log(String(format: "%@: I1 statistic %.3f -> %.3f Hz = %+.2f c; spy mismatches %d",
                            item.name as NSString, i1Source ?? .nan, i1Render ?? .nan, i1Cents,
                            spyMismatches))
            results.append([
                "name": item.name, "source": item.source, "renderURL": url.path,
                "noteStartSeconds": note.startSeconds, "noteEndSeconds": note.endSeconds,
                "noteHz": note.detectedHz, "noteCents": note.pitchOffsetCents,
                "spyVsRenderMismatchedSamples": spyMismatches,
                "askedFrames": askedFrames,
                "askedSemitones": askedFrames.map { plan.semitones(atOutputFrame: $0) },
                "gridCentres": centres,
                "yinSourceHz": yinSource.map { Self.num($0) },
                "yinRenderHz": yinRender.map { Self.num($0) },
                "i1MedianSourceHz": Self.num(i1Source), "i1MedianRenderHz": Self.num(i1Render),
                "i1MedianCents": Self.num(i1Cents),
                "hopLookupFrames": spied.calls.map { $0.frame },
                "hopSemitones": spied.calls.map { $0.semitones },
            ])
        }

        // One case through the ENGINE: store → engine → cache, the file
        // playback opens, compared with the sweep's render sample for sample.
        var engineComparison: [String: Any] = [:]
        if let name = manifest.engineCase, let item = manifest.cases.first(where: { $0.name == name }),
           let set = sets[name], let sweepURL = renders[name] {
            let engine = AudioEngine()
            engine.clipAuditionDeliveryForTesting = { _ in }
            engine.stretchCache = StretchRenderCache(
                directory: out.appendingPathComponent("engine-cache", isDirectory: true))
            let sourceURL = URL(fileURLWithPath: item.source)
            let file = try AVAudioFile(forReading: sourceURL)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            let clip = Clip(name: name, startBeat: 0, lengthBeats: (seconds * 4).rounded(.up),
                            audioFileURL: sourceURL, pitchEdits: set)
            let store = ProjectStore(tracks: [Track(name: "Vox", kind: .audio, clips: [clip])])
            store.engine = engine
            engine.tracksDidChange(store.tracks)
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while engine.graph.clipFileURLForTesting(clipID: clip.id) == nil,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let played = try #require(engine.graph.clipFileURLForTesting(clipID: clip.id),
                                      "the engine never opened a render for \(name)")
            let mismatches = Self.bitMismatches(try I1Signals.read(played).planar[0],
                                                try I1Signals.read(sweepURL).planar[0])
            #expect(mismatches == 0, "the engine's render differs from renderIfNeeded's")
            engineComparison = ["case": name, "enginePlayedURL": played.path,
                                "sweepURL": sweepURL.path, "mismatchedSamples": mismatches]
            Self.log("engine path for \(name): \(mismatches) mismatched samples vs the sweep's render")
            #expect(!engine.isRunning, "the harness started the audio hardware")
        }

        try Self.writeJSON([
            "manifest": manifestURL.path, "cases": results,
            "stretcherInterval": geometry.interval, "compensationFrames": geometry.compensation,
            "engineComparison": engineComparison,
        ], to: out.appendingPathComponent("synth-evidence.json"))
        Self.log("wrote \(out.appendingPathComponent("synth-evidence.json").path)")
    }
}
