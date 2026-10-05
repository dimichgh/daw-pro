import Accelerate
import AVFAudio
import CryptoKit
import CSignalsmithStretch
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// I1-F1 (design `2026-09-24-pitch-editor-interaction-batch.md` §4, follow-up
// I1-F1): hear the edited note WHILE editing it, by rendering only that note
// (plus context) through the one render loop.
//
// Nonisolated on purpose: no `@MainActor` suite is added (MainActorOccupancy
// Leg C sits at its cap). Engine- and store-bound gates live in the EXISTING
// `@MainActor` suites (`AuditionEngineTests`, `AuditionControllerTests`).

@Suite("I1-F1 span render — the second entry into the one render loop")
struct ClipSpanRenderTests {

    // MARK: - Physics probe (env-gated)

    /// Does a FRESH stretcher, started a pre-roll before a note, converge on
    /// the whole-file render? signalsmith predicts each frame's phase from the
    /// previous OUTPUT frame, and only digital silence (input energy < 1e-15
    /// for two blocks) resets it, so the answer depends on the take's history.
    /// At ratio 1 the input schedule is exactly 1:1, so a hop-aligned slice
    /// rendered through the product loop with the curve offset by the slice
    /// start IS the windowed render; this measures it before anything is built.
    ///
    ///     I1F1_PROBE_TAKE=/path/dry.wav I1F1_PROBE_OUT=/path/outdir \
    ///       ./scripts/test.sh --filter phaseMemoryProbe
    @Test("I1-F1 probe: fresh-start span vs whole-file render on a real take, pre-roll sweep, cumulative and single edits (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["I1F1_PROBE_TAKE"] != nil
                   && ProcessInfo.processInfo.environment["I1F1_PROBE_OUT"] != nil))
    func phaseMemoryProbe() throws {
        let env = ProcessInfo.processInfo.environment
        let take = URL(fileURLWithPath: try #require(env["I1F1_PROBE_TAKE"]))
        let outDir = URL(fileURLWithPath: try #require(env["I1F1_PROBE_OUT"]))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let work = outDir.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let detection = try PitchContourCache.detectWholeFile(take, .product)
        let table = PitchNoteTable.detected(from: detection)
        let audio = try I1Signals.read(take)
        let sr = audio.sampleRate
        let source = audio.planar
        let frames = source[0].count

        // I1's harness picks, verbatim: long confident notes spread evenly.
        let candidates = table.segments.filter {
            $0.durationSeconds >= 0.30 && $0.detectedConfidence >= 0.5 && $0.detectedHz > 0
        }
        try #require(candidates.count >= 5)
        let count = min(7, candidates.count)
        let picked = (0..<count).map { candidates[$0 * (candidates.count - 1) / max(1, count - 1)] }

        let handle = try #require(css_create(Int32(source.count), Float(sr), 1))
        let interval = Int(css_interval_samples(handle))
        let inputLatency = Int(css_input_latency(handle))
        let outputLatency = Int(css_output_latency(handle))
        css_destroy(handle)
        print("i1f1-probe| stretcher @\(sr): interval \(interval), inputLatency \(inputLatency), outputLatency \(outputLatency)")

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let loadAtStart = loads

        func rms(_ x: ArraySlice<Float>) -> Double { I1Signals.rms(x) }
        func db(_ x: Double) -> Double { x > 0 ? 20 * log10(x) : -300 }

        let preRolls: [Double] = [0.0, 0.06, 0.12, 0.25, 0.5, 1.0, 2.0, 4.0]
        let context = ClipNoteAuditionPolicy.contextSeconds
        let postRoll = 0.25
        var rows: [[String: Any]] = []
        for mode in ["single", "cumulative"] {
            for (k, note) in picked.enumerated() {
                var set = table
                for (j, other) in picked.enumerated() where mode == "cumulative" ? j <= k : j == k {
                    let index = try #require(set.segments.firstIndex { $0.id == other.id })
                    set.segments[index].pitchOffsetCents = 200
                }
                let params = StretchRenderCache.Params(ratio: 1, semitones: 0,
                                                       formantPreserve: false, pitchEdits: set)
                let destination = work.appendingPathComponent("\(mode)-\(k).caf")
                let wholeStart = ContinuousClock.now
                _ = try StretchRenderCache.performRender(
                    source: take, partial: work.appendingPathComponent("\(mode)-\(k).partial.caf"),
                    destination: destination,
                    fallbackDestination: work.appendingPathComponent("\(mode)-\(k)-fb.caf"),
                    params: params, renderCacheDirectory: work, detector: .product,
                    isCancelled: { false })
                let wholeMs = Self.ms(ContinuousClock.now - wholeStart)
                let whole = try I1Signals.read(destination).planar[0]
                let plan = try #require(StretchCurvePlan.make(
                    editSet: set, clipPitchShiftSemitones: 0, sampleRate: sr, ratio: 1))

                let d0 = Int(((note.startSeconds - context) * sr).rounded())
                let d1 = min(frames, Int(((note.endSeconds + context) * sr).rounded()))
                let n0 = Int((note.startSeconds * sr).rounded())
                let n1 = Int((note.endSeconds * sr).rounded())
                for preRoll in preRolls {
                    let wanted = max(0, d0 - Int((preRoll * sr).rounded()))
                    let s = (wanted / interval) * interval
                    let e = min(frames, d1 + Int((postRoll * sr).rounded()))
                    let slice = source.map { Array($0[s..<e]) }
                    let spanStart = ContinuousClock.now
                    let out = try OfflineStretcher.stretchTransposeCurve(
                        input: slice, sampleRate: sr, ratio: 1,
                        semitonesAtOutputFrame: { plan.semitones(atOutputFrame: $0 + s) },
                        formantPreserve: false,
                        compensation: OfflineStretcher.curveLatencyCompensation(sampleRate: sr))
                    let spanMs = Self.ms(ContinuousClock.now - spanStart)
                    let span = out[0]
                    var diff = [Float](repeating: 0, count: d1 - d0)
                    var worst: Float = 0
                    var worstAt = 0
                    for i in 0..<(d1 - d0) {
                        let delta = span[d0 - s + i] - whole[d0 + i]
                        diff[i] = delta
                        if abs(delta) > worst { worst = abs(delta); worstAt = i }
                    }
                    let spanDb = db(rms(diff[...]) / max(1e-12, rms(whole[d0..<d1])))
                    let noteDiff = diff[(n0 - d0)..<(n1 - d0)]
                    let noteDb = db(rms(noteDiff) / max(1e-12, rms(whole[n0..<n1])))
                    let line = String(format: "%@ note %d (%.3f-%.3f s): preRoll %.2f s → span %+.1f dB, note %+.1f dB, worst |Δ| %.4f at %+.1f ms from span start; span render %.1f ms (whole %.0f ms)",
                                      mode, k, note.startSeconds, note.endSeconds, preRoll, spanDb, noteDb,
                                      worst, Double(worstAt) / sr * 1000, spanMs, wholeMs)
                    print("i1f1-probe| \(line)")
                    rows.append(["mode": mode, "note": k, "startSeconds": note.startSeconds,
                                 "endSeconds": note.endSeconds, "preRollSeconds": preRoll,
                                 "spanDiffDb": spanDb, "noteDiffDb": noteDb,
                                 "worstAbsDiff": Double(worst),
                                 "worstAtMsFromSpanStart": Double(worstAt) / sr * 1000,
                                 "spanRenderMs": spanMs, "wholeRenderMs": wholeMs])
                }
            }
        }
        getloadavg(&loads, 3)
        let summary: [String: Any] = [
            "take": take.path, "sampleRate": sr, "frames": frames,
            "interval": interval, "inputLatency": inputLatency, "outputLatency": outputLatency,
            "contextSeconds": context, "postRollSeconds": postRoll,
            "loadAverageAtStart": loadAtStart, "loadAverageAtEnd": loads, "rows": rows,
        ]
        let json = try JSONSerialization.data(withJSONObject: summary,
                                              options: [.prettyPrinted, .sortedKeys])
        try json.write(to: outDir.appendingPathComponent("probe.json"))
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    // MARK: - The primitive's gates (always run, synthetic voice)
    //
    // THE GATE CHANGE (playback design §1, 2026-09-25), applied here:
    //  (a) a WAVEFORM gate below −40 dB only where it is physically reachable:
    //      a window whose pre-roll holds untransposed history at ratio 1 (here
    //      < −90 dB), and the LEVEL-ONLY path, which is BIT-EXACT;
    //  (b) everywhere else a MAGNITUDE + PITCH gate whose limits come from a
    //      CONTROL pair identical by construction: two whole-file renders of
    //      the same set, one with an extra edit on a note seconds EARLIER, so
    //      the two differ over the gated span only by the stretcher's phase
    //      memory. Limit = max(floor, 2 × the control's value).

    /// A whole-file render of `voice` with `params`, through `performRender`.
    static func wholeFile(_ voice: URL, _ params: StretchRenderCache.Params,
                          in dir: URL, name: String) throws -> [[Float]] {
        let destination = dir.appendingPathComponent("\(name).caf")
        try? FileManager.default.removeItem(at: destination)
        _ = try StretchRenderCache.performRender(
            source: voice, partial: dir.appendingPathComponent("\(name).partial.caf"),
            destination: destination,
            fallbackDestination: dir.appendingPathComponent("\(name)-fb.caf"),
            params: params, renderCacheDirectory: dir, detector: .product,
            isCancelled: { false })
        return try I1Signals.read(destination).planar
    }

    /// The span a note plays in OUTPUT frames: the note ± `context` source
    /// seconds, through the one mapping.
    static func outputSpan(_ note: NoteSegment, context: Double, ratio: Double,
                           sampleRate: Double) -> Range<Int> {
        let start = StretchCurvePlan.outputFrame(forSourceSecond: max(0, note.startSeconds - context),
                                                 ratio: ratio, sampleRate: sampleRate)
        let end = StretchCurvePlan.outputFrame(forSourceSecond: note.endSeconds + context,
                                               ratio: ratio, sampleRate: sampleRate)
        return start..<end
    }

    static func params(_ notes: [NoteSegment], ratio: Double = 1,
                       _ edit: (inout [NoteSegment]) -> Void) -> StretchRenderCache.Params {
        var segments = notes
        edit(&segments)
        return .init(ratio: ratio, semitones: 0, formantPreserve: false,
                     pitchEdits: PitchEditSet(segments: segments))
    }

    @Test("I1-F1 gate (a): at ratio 1 with untransposed history before the window, the span render IS the whole-file render (< −90 dB over the span AND its first 30 ms), rendered twice bit-identically; with no pre-roll its first 30 ms is not")
    func spanMatchesWhereReachable() throws {
        let dir = try I1Signals.tempDir("gate-a")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voice.wav")
        let voice = SpanRenderSignals.voice(seconds: 6, sampleRate: 48_000)
        try I1Signals.write([voice.samples], sampleRate: 48_000, to: url)
        let source = try StretchRenderCache.SpanSource.open(url)
        let params = Self.params(voice.notes) { $0[3].pitchOffsetCents = 200 }
        let whole = try Self.wholeFile(url, params, in: dir, name: "whole")[0]
        // Note 3 (3.02-3.58 s) with its context, the start moved onto the
        // curve loop's block grid (2.94 s = block 98 of 1440 frames), so a
        // window with no pre-roll starts EXACTLY at the span: its warm-up
        // lands inside the gated frames instead of before them.
        let schedule = try StretchRenderCache.curveSchedule(
            sourceFrames: voice.samples.count, channels: 1, sampleRate: 48_000, ratio: 1)
        let natural = Self.outputSpan(voice.notes[3], context: ClipNoteAuditionPolicy.contextSeconds,
                                      ratio: 1, sampleRate: 48_000)
        let aligned = (natural.lowerBound / schedule.blockFrames) * schedule.blockFrames
        let frames = aligned..<natural.upperBound
        #expect(schedule.blockFrames == 1_440 && aligned == 141_120)
        func render(preRoll: Int? = nil) throws -> StretchRenderCache.SpanRender {
            try StretchRenderCache.renderOutputFrames(
                frames, of: source, params: params, preRollFrames: preRoll,
                renderCacheDirectory: dir, detector: .product, isCancelled: { false })
        }
        let span = try render()
        let again = try render()
        #expect(span.path == .curve && span.firstOutputFrame == frames.lowerBound)
        #expect(span.planar[0].count == frames.count, "R1: the span is not exactly the frames asked for")
        #expect(SpanRenderSignals.sha256(span.planar) == SpanRenderSignals.sha256(again.planar),
                "R9: the same span rendered twice differs")
        let reference = Array(whole[frames])
        let head = 0..<1_440
        let residual = SpanRenderMetrics.residualDb(span.planar[0], reference)
        let headResidual = SpanRenderMetrics.residualDb(Array(span.planar[0][head]),
                                                        Array(reference[head]))
        let worst = SpanRenderMetrics.worstDifference(span.planar[0], reference)
        let cold = try render(preRoll: 0)
        let coldResidual = SpanRenderMetrics.residualDb(cold.planar[0], reference)
        let coldHead = SpanRenderMetrics.residualDb(Array(cold.planar[0][head]), Array(reference[head]))
        let coldWorst = SpanRenderMetrics.worstDifference(cold.planar[0], reference)
        print(String(format: "[measured] I1-F1 gate (a) ratio 1, untransposed history: span vs whole %.1f dB (first 30 ms %.1f dB), worst |Δ| %.2g at %+.1f ms from the span start; with NO pre-roll %.1f dB (first 30 ms %.1f dB), worst |Δ| %.2g at %+.1f ms",
                     residual, headResidual, worst.value, Double(worst.frame) / 48, coldResidual,
                     coldHead, coldWorst.value, Double(coldWorst.frame) / 48))
        #expect(residual < -90, "the span differs from the whole-file render by \(residual) dB")
        #expect(headResidual < -90, "the span's first 30 ms differ by \(headResidual) dB: an unwarmed stretcher")
        #expect(coldHead > -90, "the no-pre-roll control matched, so the gate cannot see a missing pre-roll")
    }

    /// R3 (playback design §1): how far a window's pre-roll must reach for it
    /// to converge on the whole-file render, as a CURVE, with the final window
    /// code: pre-roll 0…2 s; the window starting in a gap vs mid-note; ratio 1
    /// vs 1.5; untransposed vs transposed history. Prints; asserts only that
    /// every row rendered.
    @Test("I1-F1 R3 probe: convergence of the span on the whole-file render vs pre-roll, gap vs mid-note, ratio 1 vs 1.5, clean vs transposed history")
    func preRollConvergenceCurve() throws {
        let dir = try I1Signals.tempDir("r3")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voice.wav")
        let voice = SpanRenderSignals.voice(seconds: 8, sampleRate: 48_000)
        try I1Signals.write([voice.samples], sampleRate: 48_000, to: url)
        let source = try StretchRenderCache.SpanSource.open(url)
        var rows = 0
        for ratio in [1.0, 1.5] {
            for history in ["clean", "transposed"] {
                let set = Self.params(voice.notes, ratio: ratio) {
                    if history == "transposed" { $0[1].pitchOffsetCents = 200 }
                    $0[5].pitchOffsetCents = 200
                }
                let whole = try Self.wholeFile(url, set, in: dir, name: "r3-\(ratio)-\(history)")[0]
                // Note 5 is 5.02-5.58 s: "gap" starts in the glide before it,
                // "mid" starts inside it.
                for (place, startSeconds) in [("gap", 4.75), ("mid", 5.25)] {
                    let frames = StretchCurvePlan.outputFrame(forSourceSecond: startSeconds, ratio: ratio,
                                                              sampleRate: 48_000)
                        ..< StretchCurvePlan.outputFrame(forSourceSecond: startSeconds + 0.5,
                                                         ratio: ratio, sampleRate: 48_000)
                    let reference = Array(whole[frames])
                    var cells: [String] = []
                    for preRoll in [0.0, 0.03, 0.06, 0.12, 0.25, 0.5, 1.0, 2.0] {
                        let span = try StretchRenderCache.renderOutputFrames(
                            frames, of: source, params: set,
                            preRollFrames: Int((preRoll * 48_000).rounded()),
                            renderCacheDirectory: dir, detector: .product, isCancelled: { false })
                        let all = SpanRenderMetrics.residualDb(span.planar[0], reference)
                        let head = SpanRenderMetrics.residualDb(Array(span.planar[0][0..<1_440]),
                                                                Array(reference[0..<1_440]))
                        cells.append(String(format: "%.2fs %.0f/%.0f", preRoll, all, head))
                        rows += 1
                    }
                    print("i1f1-r3| ratio \(ratio) \(history) history, window from \(place) — pre-roll: span dB / first 30 ms dB: "
                          + cells.joined(separator: " | "))
                }
            }
        }
        #expect(rows == 64)
    }

    @Test("I1-F1 gate (a), R6: the LEVEL-ONLY path (a cleared note, a −12 dB note) is BIT-EXACT against the whole-file frames, the mask read at GLOBAL frames")
    func levelOnlySpanIsBitExact() throws {
        let dir = try I1Signals.tempDir("gate-level")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voice.wav")
        let voice = SpanRenderSignals.voice(seconds: 6, sampleRate: 48_000)
        try I1Signals.write([voice.samples], sampleRate: 48_000, to: url)
        let source = try StretchRenderCache.SpanSource.open(url)
        let params = Self.params(voice.notes) {
            $0[2].isCleared = true
            $0[4].amplitudeDb = -12
        }
        let whole = try Self.wholeFile(url, params, in: dir, name: "whole")[0]
        for index in [2, 4] {
            let frames = Self.outputSpan(voice.notes[index],
                                         context: ClipNoteAuditionPolicy.clearContextSeconds,
                                         ratio: 1, sampleRate: 48_000)
            let span = try StretchRenderCache.renderOutputFrames(
                frames, of: source, params: params, renderCacheDirectory: dir, detector: .product,
                isCancelled: { false })
            #expect(span.path == .levelOnly)
            let reference = Array(whole[frames])
            let mismatched = zip(span.planar[0], reference).filter { $0.bitPattern != $1.bitPattern }.count
            // The mask did something here, so equality is not two untouched copies.
            let touched = zip(reference, voice.samples[frames]).filter { $0.bitPattern != $1.bitPattern }.count
            print("[measured] I1-F1 level-only note \(index): \(mismatched) of \(frames.count) samples differ from the whole-file render; the mask changed \(touched)")
            #expect(mismatched == 0, "note \(index): the level-only span is not bit-exact")
            #expect(touched > 1_000, "note \(index): the mask changed nothing, so this proves nothing")
        }
    }

    @Test("I1-F1 gate (b): with transposed history, and at ratio 1.5, the span keeps the whole-file render's spectrum and pitch within limits pre-registered from a phase-only control pair; a +200 c miss fails it")
    func spanMatchesInMagnitudeAndPitch() throws {
        let dir = try I1Signals.tempDir("gate-b")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voice.wav")
        let voice = SpanRenderSignals.voice(seconds: 8, sampleRate: 48_000)
        try I1Signals.write([voice.samples], sampleRate: 48_000, to: url)
        let source = try StretchRenderCache.SpanSource.open(url)
        let target = 5
        for ratio in [1.0, 1.5] {
            // The span's set: the target note +200 c, AND an earlier note +200 c
            // (transposed history the window cannot see).
            let set = Self.params(voice.notes, ratio: ratio) {
                $0[1].pitchOffsetCents = 200
                $0[target].pitchOffsetCents = 200
            }
            // The CONTROL pair, identical by construction over the gated span:
            // the target edit alone vs the same plus a note seconds earlier.
            let alone = Self.params(voice.notes, ratio: ratio) { $0[target].pitchOffsetCents = 200 }
            let frames = Self.outputSpan(voice.notes[target],
                                         context: ClipNoteAuditionPolicy.contextSeconds,
                                         ratio: ratio, sampleRate: 48_000)
            let wholeSet = try Self.wholeFile(url, set, in: dir, name: "set-\(ratio)")[0]
            let wholeAlone = try Self.wholeFile(url, alone, in: dir, name: "alone-\(ratio)")[0]
            let control = SpanRenderMetrics.compare(Array(wholeAlone[frames]), Array(wholeSet[frames]),
                                                    sampleRate: 48_000, minHz: 80, maxHz: 300)
            let limits = SpanRenderMetrics.Limits(control: control)
            let span = try StretchRenderCache.renderOutputFrames(
                frames, of: source, params: set, renderCacheDirectory: dir, detector: .product,
                isCancelled: { false })
            let measured = SpanRenderMetrics.compare(Array(wholeSet[frames]), span.planar[0],
                                                     sampleRate: 48_000, minHz: 80, maxHz: 300)
            // The draft-ignored plant, as a built-in negative control: the
            // span rendered WITHOUT the target's edit.
            let missed = try StretchRenderCache.renderOutputFrames(
                frames, of: source, params: Self.params(voice.notes, ratio: ratio) {
                    $0[1].pitchOffsetCents = 200
                }, renderCacheDirectory: dir, detector: .product, isCancelled: { false })
            let miss = SpanRenderMetrics.compare(Array(wholeSet[frames]), missed.planar[0],
                                                 sampleRate: 48_000, minHz: 80, maxHz: 300)
            let waveform = SpanRenderMetrics.residualDb(span.planar[0], Array(wholeSet[frames]))
            print("[measured] I1-F1 gate (b) ratio \(ratio): control \(control); limits \(limits); "
                  + "span \(measured) (waveform \(String(format: "%.1f", waveform)) dB, not gated); "
                  + "+200 c miss \(miss)")
            #expect(limits.admits(measured), "ratio \(ratio): the span failed the pre-registered gate")
            #expect(!limits.admits(miss), "ratio \(ratio): a +200 c miss passed, so the gate is blind")
        }
    }

    @Test("I1-F1 one loop: the span entry and the whole-file render run the SAME two loop functions (task-local trace), and the stretcher is driven from exactly two loop bodies in the tree (census, positive-controlled)")
    func spanRunsTheOneLoop() throws {
        let dir = try I1Signals.tempDir("one-loop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voice.wav")
        let voice = SpanRenderSignals.voice(seconds: 3, sampleRate: 48_000)
        try I1Signals.write([voice.samples], sampleRate: 48_000, to: url)
        let curve = Self.params(voice.notes) { $0[1].pitchOffsetCents = 200 }
        let constant = StretchRenderCache.Params(ratio: 1.5, semitones: 0, formantPreserve: false)
        let trace = StretchLoopTrace()
        try StretchLoopTrace.$current.withValue(trace) {
            _ = try Self.wholeFile(url, curve, in: dir, name: "curve")
            _ = try StretchRenderCache.renderSpan(
                source: url, params: curve, startSourceSeconds: 1.0, endSourceSeconds: 1.6,
                renderCacheDirectory: dir, detector: .product, isCancelled: { false })
            _ = try Self.wholeFile(url, constant, in: dir, name: "constant")
            _ = try StretchRenderCache.renderSpan(
                source: url, params: constant, startSourceSeconds: 1.0, endSourceSeconds: 1.6,
                renderCacheDirectory: dir, detector: .product, isCancelled: { false })
        }
        #expect(trace.records == ["curve/whole", "curve/window", "constant/whole", "constant/window"],
                "the span did not run the whole-file render's own loops: \(trace.records)")

        // Census: every `css_process(` call in DAWEngine's Swift sources. Two
        // loop bodies (constant, curve), each entered whole or windowed.
        let census = try SpanRenderMetrics.engineSourceCensus("css_process(")
        #expect(census.total == 2, "css_process call sites: \(census.byFile)")
        #expect(census.byFile.keys.sorted() == ["OfflineStretcher.swift"])
        // Positive control: the counter sees a planted extra call.
        #expect(SpanRenderMetrics.occurrences(of: "css_process(",
                                              in: "a\n  css_process(h, x, 1, y, 1)\nb css_process(") == 2)
    }

    // MARK: - H7: the voice never cuts (manual render, no device)

    /// RT review H7, the gate. Through the live lane shape in manual rendering:
    /// a buffer REPLACING a sounding one (a drag's next step) and a stop both
    /// go through the players' volume ramp, so the output never steps more than
    /// the two waveforms themselves do. The buffers are shaped by the product's
    /// own `ClipSpanAuditionReader.shape` (5 ms raised-cosine ends), and each
    /// swap lands where the sounding cosine is at a peak, the worst place to
    /// cut. A hard cut there steps ~0.5 (`stopStepProbe`).
    @MainActor
    @Test("I1-F1 H7: a new buffer replacing a sounding one, and a stop, never step more than the waveforms do (two-player crossfade, fade-out), manual render")
    func voiceNeverCuts() throws {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine, graphRate: 48_000)
        graph.clipAuditionLaneEnabled = true
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        graph.reconcile(tracks: [])
        try engine.start()
        defer { engine.stop() }
        // I1-F2 NH-E: a ring of three pairs (`doubleSwapGate`), not two.
        #expect(graph.clipAuditionPlayers.count == PlaybackGraph.clipAuditionPairCount)

        func cosine(_ hz: Double, seconds: Double) throws -> AVAudioPCMBuffer {
            let frames = Int(seconds * 48_000)
            let x = (0..<frames).map { Float(0.5 * cos(2 * Double.pi * hz * Double($0) / 48_000)) }
            return try ClipSpanAuditionReader.shape(
                [x], sampleRate: 48_000, gain: 1, fadeSeconds: ClipNoteAuditionPolicy.fadeSeconds,
                outputFormat: graph.clipAuditionFormat, isCancelled: { false })
        }
        let a = try cosine(1_000, seconds: 1)
        let b = try cosine(1_500, seconds: 1)
        // The largest step each waveform takes on its own: 0.5 × 2π f / fs.
        let ownA = Float(0.5 * 2 * Double.pi * 1_000 / 48_000)
        let ownB = Float(0.5 * 2 * Double.pi * 1_500 / 48_000)
        let block = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                  frameCapacity: 4_096))
        func pull(_ count: Int) throws -> [Float] {
            var out: [Float] = []
            while out.count < count {
                let status = try engine.renderOffline(AVAudioFrameCount(min(512, count - out.count)),
                                                      to: block)
                try #require(status == .success)
                let data = try #require(block.floatChannelData)
                out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(block.frameLength)))
            }
            return out
        }
        func maxStep(_ x: [Float]) -> Float {
            zip(x.dropFirst(), x).map { abs($0 - $1) }.max() ?? 0
        }

        #expect(graph.playClipAudition(a))
        let lead = try pull(4_800)                // frame 4800 of A is a peak
        #expect(graph.playClipAudition(b))        // the next drag step
        #expect(graph.clipAuditionIsFading)
        let swap = try pull(9_600)
        let swapStep = maxStep(lead + swap)
        // After the ramp only B sounds, at its full level.
        let tail = Array(swap[4_800..<9_600])
        let tailRMS = I1Signals.rms(tail[...])
        graph.reapFadedClipAudition(olderThan: .zero)
        #expect(!graph.clipAuditionIsFading)
        #expect(graph.clipAuditionScheduled, "the reaper stopped the sounding player")

        // A stop mid-buffer, at whatever phase: a fade, then silence.
        #expect(graph.fadeOutClipAudition())
        let fade = try pull(4_800)
        let fadeStep = maxStep(tail + fade)
        let silentAt = stride(from: 0, to: fade.count - 48, by: 48).first { i in
            (fade[i..<(i + 48)].map(abs).max() ?? 1) < 1e-4
        } ?? -1
        graph.reapFadedClipAudition(olderThan: .zero)
        #expect(!graph.clipAuditionScheduled)
        let after = try pull(1_024)

        print(String(format: "[measured] I1-F1 H7: swap max |Δ| %.4f (A alone %.4f, B alone %.4f, a hard cut ~0.4957); B after the ramp RMS %.4f (0.5 cosine ⇒ 0.3536); stop max |Δ| %.4f, silent from frame %d; after the reap peak %.2g",
                     swapStep, ownA, ownB, tailRMS, fadeStep, silentAt,
                     after.map(abs).max() ?? 0))
        // Each waveform's own step, plus 0.01 for the fade envelopes' slopes.
        #expect(swapStep <= ownA + ownB + 0.01, "replacing a sounding buffer stepped \(swapStep)")
        #expect(fadeStep <= ownB * 1.05, "stopping a sounding buffer stepped \(fadeStep)")
        #expect(abs(tailRMS - 0.353_553) < 0.01, "the new buffer did not take over at full level")
        #expect(silentAt >= 0 && silentAt <= 2_048, "the fade did not reach silence (at \(silentAt))")
        #expect((after.map(abs).max() ?? 1) < 1e-7)
    }

    /// Which volume writes the mixer RAMPS and which it STEPS: each variant
    /// starts a fresh manual-render engine and lane, plays a 0.5 cosine to a
    /// peak, writes a volume, and prints the largest step (a ramp stays near
    /// 0.065; a step is ~0.5).
    @MainActor
    @Test("I1-F1 H7 probe: which volume writes ramp (player vs mixer, touched vs untouched, before vs after a stop)")
    func rampVariantsProbe() throws {
        enum Knob { case mixer, player }
        struct Variant { let name: String; let knob: Knob; let touchBeforePlay: Bool; let stopFirst: Bool }
        let variants = [
            Variant(name: "mixer, untouched", knob: .mixer, touchBeforePlay: false, stopFirst: false),
            Variant(name: "mixer, written 1 before play", knob: .mixer, touchBeforePlay: true, stopFirst: false),
            Variant(name: "mixer, after a stop+replay", knob: .mixer, touchBeforePlay: true, stopFirst: true),
            Variant(name: "player, untouched", knob: .player, touchBeforePlay: false, stopFirst: false),
            Variant(name: "player, written 1 before play", knob: .player, touchBeforePlay: true, stopFirst: false),
            Variant(name: "player, after a stop+replay", knob: .player, touchBeforePlay: false, stopFirst: true),
            Variant(name: "player, written 1 before a stop+replay", knob: .player, touchBeforePlay: true, stopFirst: true),
        ]
        for variant in variants {
            let engine = AVAudioEngine()
            let graph = PlaybackGraph(engine: engine, graphRate: 48_000)
            graph.clipAuditionLaneEnabled = true
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
            _ = engine.mainMixerNode
            graph.reconcile(tracks: [])
            try engine.start()
            let frames = 48_000
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: graph.clipAuditionFormat,
                                                       frameCapacity: AVAudioFrameCount(frames)))
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<frames {
                let value = Float(0.5 * cos(2 * Double.pi * 1_000 * Double(frame) / 48_000))
                data[0][frame] = value
                data[1][frame] = value
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            let block = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                      frameCapacity: 4_096))
            func pull(_ count: Int) throws -> [Float] {
                var out: [Float] = []
                while out.count < count {
                    let status = try engine.renderOffline(AVAudioFrameCount(min(512, count - out.count)), to: block)
                    try #require(status == .success)
                    let d = try #require(block.floatChannelData)
                    out.append(contentsOf: UnsafeBufferPointer(start: d[0], count: Int(block.frameLength)))
                }
                return out
            }
            let player = try #require(graph.clipAuditionPlayers.first)
            let mixer = try #require(graph.clipAuditionMixer)
            if variant.stopFirst {
                player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
                player.play()
                _ = try pull(2_000)
                player.stop()
                _ = try pull(2_048)
            }
            if variant.touchBeforePlay {
                if variant.knob == .mixer { mixer.outputVolume = 1 } else { player.volume = 1 }
            }
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            player.play()
            let lead = try pull(4_800)
            if variant.knob == .mixer { mixer.outputVolume = 0 } else { player.volume = 0 }
            let after = try pull(2_048)
            let x = lead + after
            let step = zip(x.dropFirst(), x).map { abs($0 - $1) }.max() ?? 0
            print(String(format: "i1f1-ramp| %@: max |Δ| %.4f; first after the write %.4f; at +512 %.4f",
                         variant.name, step, after.first ?? 0, after[512]))
            player.stop()
            engine.stop()
        }
    }

    // MARK: - H7: does a cut-short audition click? (manual render, no device)

    /// RT review H7, MEASURED: the voice's output around a `stopClipAudition()`
    /// issued mid-buffer at a waveform peak, and around its mixer's volume
    /// going 1 → 0, through the live lane shape in AVAudioEngine's offline
    /// manual rendering mode (`clipAuditionLanePlaysThroughTheMaster`'s
    /// harness). Prints the first differences; asserts nothing yet.
    @MainActor
    @Test("I1-F1 H7 probe: the step at a mid-buffer stop and at a mixer volume change, manual render")
    func stopStepProbe() throws {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine, graphRate: 48_000)
        graph.clipAuditionLaneEnabled = true
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        graph.reconcile(tracks: [])
        try engine.start()
        defer { engine.stop() }

        let frames = 48_000
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: graph.clipAuditionFormat,
                                                   frameCapacity: AVAudioFrameCount(frames)))
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<frames {
            let value = Float(0.5 * cos(2 * Double.pi * 1_000 * Double(frame) / 48_000))
            data[0][frame] = value
            data[1][frame] = value
        }
        buffer.frameLength = AVAudioFrameCount(frames)

        let block = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                  frameCapacity: 4_096))
        func pull(_ count: Int, quantum: Int = 512) throws -> [Float] {
            var out: [Float] = []
            while out.count < count {
                let n = min(quantum, count - out.count)
                let status = try engine.renderOffline(AVAudioFrameCount(n), to: block)
                try #require(status == .success)
                let blockData = try #require(block.floatChannelData)
                out.append(contentsOf: UnsafeBufferPointer(start: blockData[0],
                                                           count: Int(block.frameLength)))
            }
            return out
        }
        func maxStep(_ x: [Float]) -> (Float, Int) {
            var worst: Float = 0
            var at = 0
            for i in 1..<x.count where abs(x[i] - x[i - 1]) > worst {
                worst = abs(x[i] - x[i - 1]); at = i
            }
            return (worst, at)
        }

        // 1. A hard stop at a peak.
        #expect(graph.playClipAudition(buffer))
        let before = try pull(4_800)
        graph.stopClipAudition()
        let after = try pull(1_024)
        let (steady, _) = maxStep(before)
        let (cut, cutAt) = maxStep(before + after)
        print(String(format: "i1f1-h7| steady max |Δ| %.4f; hard stop max |Δ| %.4f at frame %d (last before %.4f, first after %.4f)",
                     steady, cut, cutAt, before.last ?? 0, after.first ?? 0))

        // 2. The lane mixer's volume 1 → 0 at the same phase, quantum 512.
        let mixer = try #require(graph.clipAuditionMixer)
        #expect(graph.playClipAudition(buffer))
        let lead = try pull(4_800)
        mixer.outputVolume = 0
        let faded = try pull(2_048)
        let (volumeStep, volumeAt) = maxStep(lead + faded)
        let envelope = stride(from: 0, to: 1_024, by: 64).map { i in
            faded[i..<min(faded.count, i + 64)].map(abs).max() ?? 0
        }
        print(String(format: "i1f1-h7| mixer outputVolume 1→0: max |Δ| %.4f at frame %d; first after %.4f",
                     volumeStep, volumeAt, faded.first ?? 0))
        print("i1f1-h7| envelope per 64 frames after the volume write: "
              + envelope.map { String(format: "%.4f", $0) }.joined(separator: " "))
        graph.stopClipAudition()
        mixer.outputVolume = 1
        _ = try pull(1_024)

        // 3. The player's own volume (the mixer's input bus) 1 → 0.
        let player = try #require(graph.clipAuditionPlayer)
        #expect(graph.playClipAudition(buffer))
        let lead2 = try pull(4_800)
        player.volume = 0
        let faded2 = try pull(2_048)
        let (playerStep, playerAt) = maxStep(lead2 + faded2)
        let envelope2 = stride(from: 0, to: 1_024, by: 64).map { i in
            faded2[i..<min(faded2.count, i + 64)].map(abs).max() ?? 0
        }
        print(String(format: "i1f1-h7| player volume 1→0: max |Δ| %.4f at frame %d; first after %.4f",
                     playerStep, playerAt, faded2.first ?? 0))
        print("i1f1-h7| envelope per 64 frames after the player volume write: "
              + envelope2.map { String(format: "%.4f", $0) }.joined(separator: " "))
        graph.stopClipAudition()
        player.volume = 1
        _ = try pull(2_048)

        // 4. How long the ramp lasts, at two render quanta (a live IO buffer is
        //    512 frames by default and can grow): the first frame whose 48-frame
        //    period peak is below 1e-4 after the write, and the rise back.
        for quantum in [512, 4_096] {
            mixer.outputVolume = 1
            _ = try pull(8_192, quantum: quantum)
            #expect(graph.playClipAudition(buffer))
            _ = try pull(4_800, quantum: quantum)
            mixer.outputVolume = 0
            let down = try pull(8_192, quantum: quantum)
            let silentAt = stride(from: 0, to: down.count - 48, by: 48).first { i in
                (down[i..<(i + 48)].map(abs).max() ?? 1) < 1e-4
            } ?? -1
            let (downStep, _) = maxStep(down)
            mixer.outputVolume = 1
            let up = try pull(8_192, quantum: quantum)
            let fullAt = stride(from: 0, to: up.count - 48, by: 48).first { i in
                (up[i..<(i + 48)].map(abs).max() ?? 0) > 0.4999
            } ?? -1
            print(String(format: "i1f1-h7| quantum %d: volume 1→0 silent (<1e-4) from frame %d (%.1f ms), max |Δ| %.4f; 0→1 full from frame %d (%.1f ms)",
                         quantum, silentAt, Double(silentAt) / 48, downStep, fullAt, Double(fullAt) / 48))
            graph.stopClipAudition()
        }
        mixer.outputVolume = 1
    }

    // MARK: - I1-F2: NH-E (two swaps inside one fade), NH-B (a fade on a stopped engine)

    /// One row of the NH-E double-swap measurement.
    struct DoubleSwapRow: Sendable {
        let quantum: Int
        /// Render calls between the first swap and the second.
        let k: Int
        /// The largest sample step anywhere in the output.
        let step: Float
        /// `voiceNeverCuts`' limit for these waveforms: each one's own largest
        /// step, plus 0.01 for the fade envelopes' slopes.
        let limit: Float
        /// The row's wall time: the longest the main actor is held without a
        /// break, since the rows give it back between them.
        var seconds: Double = 0
    }

    /// RT re-review NH-E: the voice's output when a SECOND buffer replaces
    /// the first one `k` render calls after the first swap, through the live
    /// lane in `voiceNeverCuts`' manual-render harness, every call exactly
    /// `quantum` frames (a live render call is one IO buffer, and a
    /// main-actor write takes effect at the NEXT call). So two deliveries `t`
    /// apart land `floor(t / buffer)` or `ceil(t / buffer)` calls apart: 45 ms
    /// is k ∈ {4, 5} at 512 frames and k ∈ {0, 1} at 4096. `k == 0` is two
    /// swaps between the same two render calls. The three waveforms are 0.5
    /// cosines at 750, 1125 and 1500 Hz, so every 512- and 4096-frame boundary
    /// is a peak of each: the worst place to cut. Buffers are shaped by the
    /// product's own `ClipSpanAuditionReader.shape`.
    ///
    /// ⚠️ THE MAIN ACTOR IS GIVEN BACK BETWEEN ROWS (I1-F2 follow-up). A row
    /// runs start to finish on the main actor, its writes between its render
    /// calls exactly where a live delivery's would be, and each row has its
    /// own engine, so nothing a row measures depends on when it runs. Run back
    /// to back from a SYNCHRONOUS test, the rows held the main actor for the
    /// whole run: the probe 2.2 s and the gate 0.93 s alone (measured), 5–6 s
    /// in a loaded run. That made them the first suspect when a real-engine
    /// test (`EngineNoticeEngineTests`' stretched-clip save) missed its 5 s
    /// render window, but the failure recurred without them. The measured
    /// cause was `AuditionEngineTests`' YIN readings, computed on the main
    /// actor for 3.0–5.0 s at a stretch (now off it: `i1YinPitchesOffMain`).
    /// Each row's wall time is recorded (`DoubleSwapRow.seconds`), and the
    /// callers print the longest.
    @MainActor
    static func doubleSwapSteps(quanta: [Int], ks: [Int], swaps: Int = 2) async throws -> [DoubleSwapRow] {
        var rows: [DoubleSwapRow] = []
        let tones: [Double] = [750, 1_125, 1_500, 1_875]
        /// One row: its own engine, lane and render calls, from start to finish.
        func row(quantum: Int, k: Int) throws -> DoubleSwapRow {
            let engine = AVAudioEngine()
            let graph = PlaybackGraph(engine: engine, graphRate: 48_000)
            graph.clipAuditionLaneEnabled = true
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000,
                                                    channels: 2))
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: 4_096)
            _ = engine.mainMixerNode
            graph.reconcile(tracks: [])
            try engine.start()
            defer { engine.stop() }
            let block = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                      frameCapacity: 4_096))
            func pull(calls: Int) throws -> [Float] {
                var out: [Float] = []
                for _ in 0..<calls {
                    let status = try engine.renderOffline(AVAudioFrameCount(quantum), to: block)
                    try #require(status == .success)
                    let data = try #require(block.floatChannelData)
                    out.append(contentsOf: UnsafeBufferPointer(start: data[0],
                                                               count: Int(block.frameLength)))
                }
                return out
            }
            func cosine(_ hz: Double) throws -> AVAudioPCMBuffer {
                let x = (0..<96_000).map { Float(0.5 * cos(2 * Double.pi * hz * Double($0) / 48_000)) }
                return try ClipSpanAuditionReader.shape(
                    [x], sampleRate: 48_000, gain: 1,
                    fadeSeconds: ClipNoteAuditionPolicy.fadeSeconds,
                    outputFormat: graph.clipAuditionFormat, isCancelled: { false })
            }
            // Well past the first buffer's 5 ms fade-in, whatever the quantum.
            let settle = max(2, 9_600 / quantum)
            #expect(graph.playClipAudition(try cosine(tones[0])))
            var out = try pull(calls: settle)
            for swap in 1...swaps {
                #expect(graph.playClipAudition(try cosine(tones[swap])))
                // `k` calls between consecutive swaps; after the last, settle.
                out += try pull(calls: swap < swaps ? k : settle)
            }
            let step = zip(out.dropFirst(), out).map { abs($0 - $1) }.max() ?? 0
            let limit = tones.prefix(swaps + 1)
                .map { Float(0.5 * 2 * Double.pi * $0 / 48_000) }
                .reduce(0, +) + 0.01
            let result = DoubleSwapRow(quantum: quantum, k: k, step: step, limit: limit)
            graph.stopClipAudition()
            return result
        }
        for quantum in quanta {
            for k in ks {
                let started = ContinuousClock.now
                var measured = try row(quantum: quantum, k: k)
                measured.seconds = Self.ms(ContinuousClock.now - started) / 1_000
                rows.append(measured)
                // Give the main actor back before the next row.
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        return rows
    }

    /// The longest single row and the rows' total, for the `i1f2-hold|` line.
    static func holdLine(_ name: String, seconds: [Double]) -> String {
        String(format: "i1f2-hold| %@: longest main-actor hold %.1f ms (one row of %d), %.1f ms of rows in all",
               name, (seconds.max() ?? 0) * 1_000, seconds.count, seconds.reduce(0, +) * 1_000)
    }

    /// RT re-review NH-E, MEASURED FIRST (the brief's order: measure at 512
    /// and 4096 frames, fix only if the step exceeds `voiceNeverCuts`' limit).
    /// Prints every row; asserts nothing.
    ///
    /// ENV-GATED since the I1-F2 follow-up: its two-swap rows are exactly
    /// `doubleSwapGate`'s, which asserts them on every run; its three-swap
    /// rows are the residual `PlaybackGraph`'s lane doc cites (three new
    /// buffers between the same two render calls still cut), measured on
    /// demand rather than paid for in every run:
    ///
    ///     I1F2_PROBES=1 ./scripts/test.sh --filter doubleSwapProbe
    @MainActor
    @Test("I1-F2 NH-E probe: a second swap k render calls after the first, at 512 and 4096 frames, against voiceNeverCuts' limit (manual render)",
          .enabled(if: ProcessInfo.processInfo.environment["I1F2_PROBES"] != nil))
    func doubleSwapProbe() async throws {
        var held: [Double] = []
        for swaps in [2, 3] {
            for row in try await Self.doubleSwapSteps(quanta: [512, 4_096], ks: Array(0...5), swaps: swaps) {
                print(String(format: "i1f2-nhe| swaps %d, quantum %d, k %d: max |Δ| %.4f (limit %.4f) %@",
                             swaps, row.quantum, row.k, row.step, row.limit,
                             row.step > row.limit ? "OVER" : "within"))
                held.append(row.seconds)
            }
        }
        print(Self.holdLine("doubleSwapProbe", seconds: held))
    }

    /// RT re-review NH-B, the probe it asked for BEFORE the fix: the voice is
    /// silenced while the engine is STOPPED (a device change stopped it), then
    /// the engine starts again (the watchdog's `engine.stop()` →
    /// `recoverEngine()` → `prepare()` does exactly this in one call). What
    /// plays after the restart, for the fade the engine used to issue (a mixer
    /// volume written while nothing renders) and for a stop at once.
    @MainActor
    @Test("I1-F2 NH-B probe: a fade written on a STOPPED engine vs a stop at once vs neither, then the engine restarted (manual render)")
    func stoppedEngineSilenceProbe() async throws {
        // "none": neither, the control that says whether a player resumes its
        // queue across a stop and start at all. "play": a NEW buffer handed to
        // the voice while the engine is stopped (what H3's guard refuses), and
        // "play-cold": the same on an engine that never started (the unit
        // tests' engine); each prints whether `play()` raised.
        // One row per action: its own engine, lane and render calls, from start
        // to finish; the main actor is given back between rows.
        func row(_ action: String) throws {
            let engine = AVAudioEngine()
            let graph = PlaybackGraph(engine: engine, graphRate: 48_000)
            graph.clipAuditionLaneEnabled = true
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
            _ = engine.mainMixerNode
            graph.reconcile(tracks: [])
            let block = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                      frameCapacity: 4_096))
            func pull(_ count: Int) throws -> [Float] {
                var out: [Float] = []
                while out.count < count {
                    let status = try engine.renderOffline(AVAudioFrameCount(min(512, count - out.count)),
                                                          to: block)
                    try #require(status == .success)
                    let data = try #require(block.floatChannelData)
                    out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(block.frameLength)))
                }
                return out
            }
            func tone(_ hz: Double) throws -> AVAudioPCMBuffer {
                let x = (0..<96_000).map { Float(0.5 * cos(2 * Double.pi * hz * Double($0) / 48_000)) }
                return try ClipSpanAuditionReader.shape(
                    [x], sampleRate: 48_000, gain: 1, fadeSeconds: ClipNoteAuditionPolicy.fadeSeconds,
                    outputFormat: graph.clipAuditionFormat, isCancelled: { false })
            }
            var before: [Float] = []
            var accepted = "n/a"
            if action == "play-cold" {
                accepted = graph.playClipAudition(try tone(1_125)) ? "true" : "false (raised)"
            } else {
                try engine.start()
                #expect(graph.playClipAudition(try tone(750)))
                before = try pull(4_800)
                engine.stop()
                if action == "fade" {
                    _ = graph.fadeOutClipAudition()
                } else if action == "stop" {
                    graph.stopClipAudition()
                } else if action == "play" {
                    accepted = graph.playClipAudition(try tone(1_125)) ? "true" : "false (raised)"
                }
            }
            try engine.start()
            let after = try pull(9_600)
            let beforePeak = before.suffix(1_024).map(abs).max() ?? 0
            let afterPeak = after.map(abs).max() ?? 0
            let firstLoud = after.firstIndex { abs($0) > 1e-7 } ?? -1
            print(String(format: "i1f2-nhb| %@ while stopped, then start: playClipAudition while stopped returned %@; peak before the stop %.4f; after the (re)start peak %.3g, first sample above 1e-7 at frame %d; still scheduled %@, fading %@",
                         action, accepted, beforePeak, afterPeak, firstLoud,
                         graph.clipAuditionScheduled ? "yes" : "no",
                         graph.clipAuditionIsFading ? "yes" : "no"))
            graph.stopClipAudition()
            engine.stop()
        }
        var held: [Double] = []
        for action in ["fade", "stop", "none", "play", "play-cold"] {
            let started = ContinuousClock.now
            try row(action)
            held.append(Self.ms(ContinuousClock.now - started) / 1_000)
            try await Task.sleep(for: .milliseconds(1))
        }
        print(Self.holdLine("stoppedEngineSilenceProbe", seconds: held))
    }

    /// RT re-review NH-E, THE GATE after the fix: a second new buffer `k`
    /// render calls after the first, for every `k` from 0 (both between the
    /// same two render calls) to 5, at a 512- and a 4096-frame IO buffer,
    /// never steps more than `voiceNeverCuts`' limit for these waveforms. With
    /// two pairs, k 0 stepped 0.4976 at both sizes and k 1 0.2803 at 512
    /// frames (`doubleSwapProbe`, MEASURED before the fix); the third pair is
    /// idle when the second swap comes.
    @MainActor
    @Test("I1-F2 NH-E gate: a second new buffer k = 0…5 render calls after the first never steps more than the waveforms do, at 512 and 4096 frames (a ring of three pairs, manual render)")
    func doubleSwapGate() async throws {
        let rows = try await Self.doubleSwapSteps(quanta: [512, 4_096], ks: Array(0...5), swaps: 2)
        #expect(rows.count == 12)
        for row in rows {
            print(String(format: "[measured] I1-F2 NH-E gate: quantum %d, k %d: max |Δ| %.4f (limit %.4f)",
                         row.quantum, row.k, row.step, row.limit))
            #expect(row.step <= row.limit,
                    "quantum \(row.quantum), k \(row.k): the second swap stepped \(row.step) (limit \(row.limit))")
        }
        print(Self.holdLine("doubleSwapGate", seconds: rows.map(\.seconds)))
    }

    /// RT re-review NH-F, H4's untested half: cancellation reaches the render
    /// LOOP, not only the start and the end. A 6 s span (the cap) on the curve
    /// path is rendered once counting every poll of its `isCancelled`, then
    /// again with the flag raised at half that count, which lands inside the
    /// stretcher's block loop. Every poll site throws at once, so the second
    /// render must throw `.cancelled` on exactly the poll that saw the flag.
    @Test("I1-F2 NH-F H4: a span render polls its cancel flag at least once per block of the one loop, and a cancel raised MID-render stops it at that very poll (throws cancelled, no poll after)")
    func spanRenderStopsMidRender() throws {
        let dir = try I1Signals.tempDir("h4-mid")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voice.wav")
        let voice = SpanRenderSignals.voice(seconds: 8, sampleRate: 48_000)
        try I1Signals.write([voice.samples], sampleRate: 48_000, to: url)
        let source = try StretchRenderCache.SpanSource.open(url)
        let params = Self.params(voice.notes) { $0[3].pitchOffsetCents = 200 }
        let schedule = try StretchRenderCache.curveSchedule(
            sourceFrames: voice.samples.count, channels: 1, sampleRate: 48_000, ratio: 1)
        let frames = 48_000..<(48_000 + 288_000)
        let blocks = frames.count / schedule.blockFrames
        func render(cancelAtPoll: Int?)
            -> (polls: Int, seconds: Double, result: Result<StretchRenderCache.SpanRender, any Error>) {
            var polls = 0
            let started = ContinuousClock.now
            let result = Result {
                try StretchRenderCache.renderOutputFrames(
                    frames, of: source, params: params, renderCacheDirectory: dir,
                    detector: .product, isCancelled: {
                        polls += 1
                        return cancelAtPoll.map { polls >= $0 } ?? false
                    })
            }
            return (polls, Self.ms(ContinuousClock.now - started) / 1_000, result)
        }
        let full = render(cancelAtPoll: nil)
        let rendered = try full.result.get()
        #expect(rendered.path == .curve, "the span did not take the curve loop, so this proves nothing")
        let flip = full.polls / 2
        let cut = render(cancelAtPoll: flip)
        print(String(format: "[measured] I1-F2 H4: a 6 s curve span polled %d× over %d blocks of %d frames, %.3f s; cancelled at poll %d: %d polls, %.3f s",
                     full.polls, blocks, schedule.blockFrames, full.seconds, flip, cut.polls, cut.seconds))
        #expect(full.polls >= blocks,
                "the render polled \(full.polls)× over \(blocks) blocks: a cancel cannot reach the loop")
        #expect(throws: OfflineStretcherError.cancelled) { try cut.result.get() }
        #expect(cut.polls == flip, "the render polled \(cut.polls - flip)× after the cancel")
    }

    /// RT re-review NH-A, at the seam: K cold requests for ONE contour entry,
    /// on K threads at once, while the one detection is held at a gate. One
    /// detection runs (a counting spy), the other K − 1 wait on it (the
    /// flight's own count), and all K get the same contour once it lands. A
    /// further request whose own `isCancelled` fires while it waits gives up
    /// at once, with the detection still held, and never detects. Its give-up
    /// latency is stamped on the waiter's own thread, against the instant its
    /// flag was raised: the product's latency, with none of this test's own
    /// scheduling in it (I1-F2 follow-up: under the full suite's load this
    /// test's poll saw a give-up 1003.6 ms after the flag, and failed a 500 ms
    /// claim the waiter itself had met).
    @Test("I1-F2 NH-A: K concurrent cold requests for one contour entry run ONE detection (counting spy), the other K−1 wait for it, all K get the same contour, and a cancelled waiter gives up while it still runs")
    func contourDetectionIsSingleFlight() async throws {
        let dir = try I1Signals.tempDir("nha-seam")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voice.wav")
        let voice = SpanRenderSignals.voice(seconds: 2, sampleRate: 48_000)
        try I1Signals.write([voice.samples], sampleRate: 48_000, to: url)
        let cacheDir = dir.appendingPathComponent("renders", isDirectory: true)
        let spy = GatedContourDetector()
        defer { spy.open() }
        let detector = spy.detector()
        let key = try PitchContourCache.key(source: url, detector: detector)
        let entry = PitchContourCache.directory(inRenderCacheDirectory: cacheDir)
            .appendingPathComponent(key + ".json")
        let version = PitchEditSet.currentAnalysisVersion
        let k = 5
        let answers = I1F2Locked<[PitchRenderContour]>([])
        for _ in 0..<k {
            DispatchQueue.global(qos: .userInitiated).async {
                let answer = PitchContourCache.renderContour(
                    source: url, analysisVersion: version, renderCacheDirectory: cacheDir,
                    detector: detector)
                answers.mutate { $0.append(answer) }
            }
        }
        // Bounded, and never required: without the single flight the waiters
        // never appear, and the detection COUNT below is what fails.
        let overlapped = await I1F2Wait.until(seconds: 10) {
            spy.runCount > 1
                || (spy.runCount == 1 && PitchContourCache.waiterCountForTesting(entry: entry) == k - 1)
        }
        let runsWhileHeld = spy.runCount
        let waitingWhileHeld = PitchContourCache.waiterCountForTesting(entry: entry)

        // One more request, cancelled while it waits. The waiter stamps the
        // instant its call returned, on its own thread.
        let cancel = I1F2Locked(false)
        let cancelled = I1F2Locked<(answer: PitchRenderContour, returnedAt: ContinuousClock.Instant)?>(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let answer = PitchContourCache.renderContour(
                source: url, analysisVersion: version, renderCacheDirectory: cacheDir,
                detector: detector, isCancelled: { cancel.value })
            let returnedAt = ContinuousClock.now
            cancelled.mutate { $0 = (answer, returnedAt) }
        }
        let joined = await I1F2Wait.until(seconds: 10) {
            PitchContourCache.waiterCountForTesting(entry: entry) == k
        }
        let cancelledAt = ContinuousClock.now
        cancel.mutate { $0 = true }
        let gaveUp = await I1F2Wait.until(seconds: 5) { cancelled.value != nil }
        // THE CLAIM: flag → the waiter's own return (asserted below). This
        // test's poll saw it later by its own scheduling delay (printed only).
        let observedAfter = Self.ms(ContinuousClock.now - cancelledAt)
        let gaveUpAfter = cancelled.value.map { Self.ms($0.returnedAt - cancelledAt) } ?? .nan
        let runsBeforeOpen = spy.runCount

        spy.open()
        let landed = await I1F2Wait.until(seconds: 60) { answers.value.count == k }
        print(String(format: "[measured] I1-F2 NH-A seam: %d cold requests → %d detection(s) while held, %d waiting; a cancelled waiter gave up %.1f ms after its flag (the waiter's own stamp; this test's poll saw it at %.1f ms), with %d detection(s) run; %d detection(s) in all",
                     k, runsWhileHeld, waitingWhileHeld, gaveUpAfter, observedAfter, runsBeforeOpen, spy.runCount))
        #expect(overlapped && waitingWhileHeld == k - 1,
                "the K requests did not wait on one detection: \(runsWhileHeld) running, \(waitingWhileHeld) waiting")
        #expect(landed, "not every request answered")
        #expect(spy.runCount == 1, "\(k) cold requests for one entry ran \(spy.runCount) detections")
        let first = try #require(answers.value.first?.detection, "the leader did not detect")
        #expect(answers.value.allSatisfy { $0 == .detected(first) },
                "the requests got different contours")
        #expect(PitchContourCache.read(entry, key: key, detector: detector) == first,
                "the answer is not the committed entry")
        #expect(joined && gaveUp, "the cancelled waiter never joined, or never gave up")
        #expect(cancelled.value?.answer == .unavailable(reason: "the request was cancelled while the pitch analysis ran"))
        #expect(gaveUpAfter < 500, "the cancelled waiter took \(gaveUpAfter) ms to give up (its own stamp)")
        #expect(runsBeforeOpen == 1, "the cancelled waiter ran a detection of its own")
    }

    /// RT re-review NH-G: the leader deletes an entry only when IT read bytes
    /// there that did not decode. Another writer's VALID entry, committed after
    /// the leader's read missed (a second app sharing the cache directory, the
    /// one interleaving the single flight cannot rule out), is kept: the
    /// leader's own commit loses (first writer wins) and every caller gets the
    /// other writer's bytes. Control: bytes the leader read and could not
    /// decode are removed and healed.
    @Test("I1-F2 NH-G: a leader never deletes a valid entry another writer committed after its read missed (that entry is the answer); only bytes it READ and could not decode are removed and healed")
    func contourLeaderKeepsAnotherWritersEntry() throws {
        let dir = try I1Signals.tempDir("nhg")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voice.wav")
        let voice = SpanRenderSignals.voice(seconds: 1, sampleRate: 48_000)
        try I1Signals.write([voice.samples], sampleRate: 48_000, to: url)
        let cacheDir = dir.appendingPathComponent("renders", isDirectory: true)
        let counter = ContourToRenderTests.Counter()
        let detector = ContourToRenderTests.counting(counter)
        let version = PitchEditSet.currentAnalysisVersion
        let key = try PitchContourCache.key(source: url, detector: detector)
        let contourDir = PitchContourCache.directory(inRenderCacheDirectory: cacheDir)
        let entry = contourDir.appendingPathComponent(key + ".json")
        let mine = try PitchContourCache.detectWholeFile(url, detector)
        var theirs = mine
        theirs.windowDurationSeconds += 1
        #expect(theirs != mine)
        let theirBytes = try JSONEncoder().encode(PitchContourCache.Sidecar(
            layout: PitchContourCache.layoutVersion, key: key,
            analysisVersion: detector.analysisVersion, detection: theirs))

        let raced = PitchContourCache.$afterLeaderMissForTesting.withValue({
            try? FileManager.default.createDirectory(at: contourDir, withIntermediateDirectories: true)
            try? theirBytes.write(to: entry)
        }) {
            PitchContourCache.renderContour(source: url, analysisVersion: version,
                                            renderCacheDirectory: cacheDir, detector: detector)
        }
        #expect(counter.count == 1, "the leader's read did not miss, so this proves nothing")
        #expect(raced == .detected(theirs),
                "the leader deleted the entry another writer committed after its read missed")
        #expect(PitchContourCache.read(entry, key: key, detector: detector) == theirs)

        // CONTROL: bytes the leader READ and could not decode.
        try Data("not a contour".utf8).write(to: entry)
        let healed = PitchContourCache.renderContour(source: url, analysisVersion: version,
                                                     renderCacheDirectory: cacheDir,
                                                     detector: detector)
        #expect(counter.count == 2)
        #expect(healed == .detected(mine), "undecodable bytes were not healed: \(healed)")
        #expect(PitchContourCache.read(entry, key: key, detector: detector) == mine)
    }

    // MARK: - Measurements on the user's take (env-gated; nothing plays)

    /// Everything I1-F1 measures on a REAL take at the primitive level, in the
    /// gate change's order: the control pairs FIRST, then the limits written
    /// to `thresholds.json`, and only then the span results
    /// (`measurements.json`). The take never enters the tree: the work files
    /// live under the out dir and are removed at the end.
    ///
    ///     I1F1_TAKE="$DUR/take/dry-norm.wav" I1F1_OUT="$DUR/I1-F1" \
    ///       ./scripts/test.sh --filter spanRenderMeasurementsOnTheUsersTake
    ///
    /// The 7 notes are I1's latency harness's picks, by its own rule, checked
    /// against `$DUR/I1-latency/latency.json` when that file is there.
    @Test("I1-F1 measurements on the user's take: pre-registered magnitude+pitch gate, the 7 notes (cumulative and single edits, clears, levels), determinism, R3, R5, R11, cold contour (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["I1F1_TAKE"] != nil
                   && ProcessInfo.processInfo.environment["I1F1_OUT"] != nil))
    func spanRenderMeasurementsOnTheUsersTake() throws {
        let env = ProcessInfo.processInfo.environment
        let take = URL(fileURLWithPath: try #require(env["I1F1_TAKE"]))
        let outDir = URL(fileURLWithPath: try #require(env["I1F1_OUT"]))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let work = outDir.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let loadAtStart = loads

        let detection = try PitchContourCache.detectWholeFile(take, .product)
        let table = PitchNoteTable.detected(from: detection)
        let audio = try I1Signals.read(take)
        let sr = audio.sampleRate
        let source = try StretchRenderCache.SpanSource.open(take)
        let candidates = table.segments.filter {
            $0.durationSeconds >= 0.30 && $0.detectedConfidence >= 0.5 && $0.detectedHz > 0
        }
        try #require(candidates.count >= 7)
        let picked = (0..<7).map { candidates[$0 * (candidates.count - 1) / 6] }
        let pickedIDs = Set(picked.map(\.id))
        // Positive control: these ARE I1's 7 notes.
        let i1 = take.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("I1-latency/latency.json")
        if let data = try? Data(contentsOf: i1),
           let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let edits = json["edits"] as? [[String: Any]] {
            let theirs = edits.compactMap { $0["startSeconds"] as? Double }
            #expect(theirs.count == 7 && zip(theirs, picked.map(\.startSeconds)).allSatisfy { abs($0 - $1) < 1e-9 },
                    "not I1's 7 notes: \(theirs) vs \(picked.map(\.startSeconds))")
        }

        func params(_ edits: [(UUID, (inout NoteSegment) -> Void)], ratio: Double = 1)
            -> StretchRenderCache.Params {
            var set = table
            for (id, edit) in edits {
                if let i = set.segments.firstIndex(where: { $0.id == id }) { edit(&set.segments[i]) }
            }
            return .init(ratio: ratio, semitones: 0, formantPreserve: false, pitchEdits: set)
        }
        func cents(_ c: Double) -> (inout NoteSegment) -> Void { { $0.pitchOffsetCents = c } }
        var wholeCount = 0
        func whole(_ p: StretchRenderCache.Params) throws -> [Float] {
            wholeCount += 1
            return try Self.wholeFile(take, p, in: work, name: "w\(wholeCount)")[0]
        }
        func span(_ note: NoteSegment, context: Double = ClipNoteAuditionPolicy.contextSeconds,
                  ratio: Double = 1) -> Range<Int> {
            Self.outputSpan(note, context: context, ratio: ratio, sampleRate: sr)
        }
        func render(_ frames: Range<Int>, _ p: StretchRenderCache.Params,
                    preRoll: Int? = nil) throws -> (StretchRenderCache.SpanRender, Double) {
            let t0 = ContinuousClock.now
            let r = try StretchRenderCache.renderOutputFrames(
                frames, of: source, params: p, preRollFrames: preRoll, renderCacheDirectory: work,
                detector: .product, isCancelled: { false })
            return (r, Self.ms(ContinuousClock.now - t0))
        }
        func band(_ note: NoteSegment) -> (Double, Double) {
            let hz = note.detectedHz * pow(2, 200.0 / 1_200)
            return (hz * 0.6, hz * 1.7)
        }
        func cumulative(_ k: Int) -> [(UUID, (inout NoteSegment) -> Void)] {
            picked[0...k].map { ($0.id, cents(200)) }
        }

        // 1. PRE-REGISTRATION. The control pair per note: the cumulative set,
        //    and the same plus +100 c on the nearest other note ending ≥ 1.5 s
        //    before the span, over the span. Same pitch and level by
        //    construction; only the stretcher's phase memory differs.
        var controls: [SpanRenderMetrics.Comparison] = []
        var controlRows: [[String: Any]] = []
        var wholeCumulative: [[Float]] = []
        for k in 0..<7 {
            let frames = span(picked[k])
            let startSeconds = Double(frames.lowerBound) / sr
            let extra = try #require(table.segments
                .filter { !pickedIDs.contains($0.id) && $0.endSeconds <= startSeconds - 1.5 }
                .max { $0.endSeconds < $1.endSeconds })
            let a = try whole(params(cumulative(k)))
            let b = try whole(params(cumulative(k) + [(extra.id, cents(100))]))
            wholeCumulative.append(a)
            let (lo, hi) = band(picked[k])
            let control = SpanRenderMetrics.compare(Array(a[frames]), Array(b[frames]),
                                                    sampleRate: sr, minHz: lo, maxHz: hi)
            controls.append(control)
            controlRows.append(["note": k, "extraNoteStartSeconds": extra.startSeconds,
                                "control": try Self.json(control)])
            print("i1f1-take| control note \(k): \(control)")
        }
        let limits = SpanRenderMetrics.Limits(
            lsdMean: max(1.0, 2 * (controls.map(\.lsdMean).max() ?? .nan)),
            lsdP95: max(3.0, 2 * (controls.map(\.lsdP95).max() ?? .nan)),
            pitchP90: max(5.0, 2 * (controls.map(\.pitchP90).max() ?? .nan)))
        let thresholds: [String: Any] = [
            "rule": "limit = max(floor, 2 × the largest of the 7 control values); floors 1 dB (LSD mean), 3 dB (LSD p95), 5 c (pitch p90, octave-folded, pairwise YIN centred on detected Hz × 2^(200/1200))",
            "controls": controlRows, "limits": try Self.json(limits),
            "writtenAt": ISO8601DateFormatter().string(from: Date()),
        ]
        try JSONSerialization.data(withJSONObject: thresholds, options: [.prettyPrinted, .sortedKeys])
            .write(to: outDir.appendingPathComponent("thresholds.json"))
        print("i1f1-take| PRE-REGISTERED \(limits), written before any span result")

        // 2. THE 7 NOTES.
        var rows: [[String: Any]] = []
        var admitted = 0
        var missesCaught = 0
        var singleResiduals: [Double] = []
        var deterministic = true
        var levelMismatches = 0
        for (k, note) in picked.enumerated() {
            let frames = span(note)
            let (lo, hi) = band(note)
            let reference = Array(wholeCumulative[k][frames])
            let (s1, ms1) = try render(frames, params(cumulative(k)))
            let (s2, _) = try render(frames, params(cumulative(k)))
            deterministic = deterministic
                && SpanRenderSignals.sha256(s1.planar) == SpanRenderSignals.sha256(s2.planar)
            let measured = SpanRenderMetrics.compare(reference, s1.planar[0], sampleRate: sr,
                                                     minHz: lo, maxHz: hi)
            if limits.admits(measured) { admitted += 1 }
            // The miss control ON THE TAKE: the same span with THIS note's edit
            // left out (0 c where +200 c was asked) must fail the same gate, or
            // the gate cannot see a wrong pitch on a real voice.
            let (miss, _) = try render(frames, params(Array(cumulative(k).dropLast())))
            let missed = SpanRenderMetrics.compare(reference, miss.planar[0], sampleRate: sr,
                                                   minHz: lo, maxHz: hi)
            if !limits.admits(missed) { missesCaught += 1 }
            let waveform = SpanRenderMetrics.residualDb(s1.planar[0], reference)
            let worst = SpanRenderMetrics.worstDifference(s1.planar[0], reference)
            // Gate (a): the single edit, untransposed history at ratio 1.
            let single = params([(note.id, cents(200))])
            let singleWhole = try whole(single)
            let (s3, _) = try render(frames, single)
            let singleResidual = SpanRenderMetrics.residualDb(s3.planar[0], Array(singleWhole[frames]))
            let singleWorst = SpanRenderMetrics.worstDifference(s3.planar[0], Array(singleWhole[frames]))
            singleResiduals.append(singleResidual)
            // Level-only: a clear and a −12 dB level, bit for bit.
            var levelRow: [String: Int] = [:]
            for (label, edit) in [("cleared", { (s: inout NoteSegment) in s.isCleared = true }),
                                  ("minus12dB", { (s: inout NoteSegment) in s.amplitudeDb = -12 })] {
                let p = params([(note.id, edit)])
                let clearFrames = span(note, context: ClipNoteAuditionPolicy.clearContextSeconds)
                let w = try whole(p)
                let (s, _) = try render(clearFrames, p)
                let bad = zip(s.planar[0], w[clearFrames]).filter { $0.bitPattern != $1.bitPattern }.count
                levelRow[label] = bad
                levelMismatches += bad
            }
            let contextFrames = Int((ClipNoteAuditionPolicy.contextSeconds * sr).rounded())
            func place(_ frame: Int) -> String {
                frame < contextFrames ? "head context" : (frame >= frames.count - contextFrames ? "tail context" : "note")
            }
            let line = String(format: "note %d %.3f-%.3f s: cumulative (%d edits) %@ → %@; miss control %@ → %@; waveform %.1f dB, worst |Δ| %.3f at %.1f ms (%@); single edit %.1f dB, worst |Δ| %.2g at %.1f ms; clear/−12 dB mismatches %d/%d; span render %.1f ms",
                              k, note.startSeconds, note.endSeconds, k + 1, measured.description,
                              limits.admits(measured) ? "PASS" : "FAIL", missed.description,
                              limits.admits(missed) ? "ADMITTED (the gate is blind)" : "caught",
                              waveform, worst.value,
                              Double(worst.frame) / sr * 1_000, place(worst.frame), singleResidual,
                              singleWorst.value, Double(singleWorst.frame) / sr * 1_000,
                              levelRow["cleared"] ?? -1, levelRow["minus12dB"] ?? -1, ms1)
            print("i1f1-take| \(line)")
            rows.append(["note": k, "startSeconds": note.startSeconds, "endSeconds": note.endSeconds,
                         "cumulative": try Self.json(measured), "admitted": limits.admits(measured),
                         "missControl": try Self.json(missed), "missCaught": !limits.admits(missed),
                         "waveformDb": waveform, "worstAbsDiff": Double(worst.value),
                         "worstAtMs": Double(worst.frame) / sr * 1_000, "worstPlace": place(worst.frame),
                         "singleEditWaveformDb": singleResidual,
                         "singleEditWorstAbsDiff": Double(singleWorst.value),
                         "levelOnlyMismatchedSamples": levelRow, "spanRenderMs": ms1])
        }

        // 3. R3 on the take: note 3 (19.28-19.616 s), pre-roll curve.
        var r3: [[String: Any]] = []
        let n3 = picked[3]
        for ratio in [1.0, 1.5] {
            for history in ["clean", "transposed"] {
                var edits: [(UUID, (inout NoteSegment) -> Void)] = [(n3.id, cents(200))]
                if history == "transposed" { edits.append((picked[2].id, cents(200))) }
                let p = params(edits, ratio: ratio)
                let w = try whole(p)
                for (placeName, startSeconds) in [("gap", n3.startSeconds - 0.3),
                                                  ("mid", n3.startSeconds + 0.15)] {
                    let frames = StretchCurvePlan.outputFrame(forSourceSecond: startSeconds, ratio: ratio,
                                                              sampleRate: sr)
                        ..< StretchCurvePlan.outputFrame(forSourceSecond: startSeconds + 0.5, ratio: ratio,
                                                         sampleRate: sr)
                    var cells: [String] = []
                    for preRoll in [0.0, 0.1, 0.25, 0.5, 1.0, 2.0] {
                        let (s, _) = try render(frames, p, preRoll: Int((preRoll * sr).rounded()))
                        let db = SpanRenderMetrics.residualDb(s.planar[0], Array(w[frames]))
                        cells.append(String(format: "%.2fs %.0f", preRoll, db))
                        r3.append(["ratio": ratio, "history": history, "start": placeName,
                                   "preRollSeconds": preRoll, "waveformDb": db])
                    }
                    print("i1f1-take| R3 ratio \(ratio) \(history) \(placeName): " + cells.joined(separator: " | "))
                }
            }
        }

        // 4. R5: the wake of ONE +200 c note in two whole-file renders.
        let far = picked[0]
        let a = try whole(params([(far.id, cents(200))]))
        let b = try whole(params([(far.id, cents(200)), (n3.id, cents(200))]))
        func windowDb(_ second: Double) -> Double {
            let f = Int((second * sr).rounded())
            let r = max(0, f)..<min(a.count, f + Int(0.05 * sr))
            return SpanRenderMetrics.residualDb(Array(b[r]), Array(a[r]))
        }
        var r5: [String: Double] = ["before (−0.3 s)": windowDb(n3.startSeconds - 0.3),
                                    "inside": windowDb(n3.startSeconds + 0.1)]
        for after in [0.1, 0.25, 0.5, 1.0, 2.0, 5.0] {
            r5["+\(after) s after"] = windowDb(n3.endSeconds + after)
        }
        print("i1f1-take| R5 wake of one +200 c note (b − a, 50 ms windows): \(r5.sorted { $0.key < $1.key })")

        // 5. R11: ms of render per second of span, mono and stereo.
        let stereoURL = work.appendingPathComponent("stereo.wav")
        try I1Signals.write([audio.planar[0], audio.planar[0]], sampleRate: sr, to: stereoURL)
        let stereo = try StretchRenderCache.SpanSource.open(stereoURL)
        var r11: [String: Double] = [:]
        for (label, src) in [("mono", source), ("stereo", stereo)] {
            for seconds in [0.6, 6.0] {
                let start = Int((n3.startSeconds * sr).rounded())
                let frames = start..<(start + Int(seconds * sr))
                var times: [Double] = []
                for _ in 0..<5 {
                    let t0 = ContinuousClock.now
                    _ = try StretchRenderCache.renderOutputFrames(
                        frames, of: src, params: params([(n3.id, cents(200))]),
                        renderCacheDirectory: work, detector: .product, isCancelled: { false })
                    times.append(Self.ms(ContinuousClock.now - t0))
                }
                r11["\(label) \(seconds) s"] = SpanRenderMetrics.percentile(times, 0.5) / seconds
            }
        }
        print("i1f1-take| R11 ms of render per second of span (median of 5): \(r11.sorted { $0.key < $1.key })")

        // 6. The contour-shaped path: cold (detection runs) vs hot (cached).
        let hardTune = params([(n3.id, { $0.driftScale = 0; $0.vibratoScale = 0 })])
        let coldDir = work.appendingPathComponent("contour-cold", isDirectory: true)
        try FileManager.default.createDirectory(at: coldDir, withIntermediateDirectories: true)
        var contourMs: [Double] = []
        for _ in 0..<3 {
            let t0 = ContinuousClock.now
            _ = try StretchRenderCache.renderOutputFrames(
                span(n3), of: source, params: hardTune, renderCacheDirectory: coldDir,
                detector: .product, isCancelled: { false })
            contourMs.append(Self.ms(ContinuousClock.now - t0))
        }
        print("i1f1-take| contour-shaped span (Hard Tune on one note): cold \(contourMs[0]) ms, hot \(contourMs[1]) / \(contourMs[2]) ms")

        getloadavg(&loads, 3)
        let summary: [String: Any] = [
            "take": take.path, "sampleRate": sr, "frames": audio.planar[0].count,
            "preRollSeconds": StretchRenderCache.spanPreRollSeconds,
            "limits": try Self.json(limits), "notes": rows, "admitted": admitted,
            "missesCaught": missesCaught,
            "deterministic": deterministic, "levelOnlyMismatchedSamples": levelMismatches,
            "r3": r3, "r5": r5, "r11MsPerSecond": r11,
            "contourShapedSpanMs": ["cold": contourMs[0], "hot": Array(contourMs.dropFirst())],
            "loadAverageAtStart": loadAtStart, "loadAverageAtEnd": loads,
        ]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: outDir.appendingPathComponent("measurements.json"))
        print(String(format: "i1f1-take| SUMMARY %d of 7 notes pass the pre-registered gate, %d of 7 miss controls caught; single edits %@ dB; deterministic %@; level-only mismatches %d; load %.2f → %.2f",
                     admitted, missesCaught,
                     singleResiduals.map { String(format: "%.0f", $0) }.joined(separator: " "),
                     deterministic ? "yes" : "NO", levelMismatches, loadAtStart[0], loads[0]))
        #expect(admitted == 7, "\(7 - admitted) of the 7 notes failed the pre-registered gate")
        #expect(missesCaught == 7, "the gate admitted \(7 - missesCaught) of the 7 +200 c misses")
        #expect(singleResiduals.allSatisfy { $0 < -40 }, "a single-edit span differs: \(singleResiduals)")
        #expect(deterministic)
        #expect(levelMismatches == 0)
    }

    static func json<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    // MARK: - Invariance: whole-file renders before/after (env-gated capture)

    /// Captures a SHA-256 of the decoded samples of every whole-file render
    /// branch (curve, curve + mask, level-only, constant, constant + mask, a
    /// transposed clip, formant preserve, ratios 0.75/1/1.25/1.5, 44.1 kHz
    /// stereo) plus one offline bounce, into `I1F1_GOLDEN_OUT/goldens.json`.
    /// Run it on the tree BEFORE a change to the render loop and AFTER it, and
    /// `diff` the two files: the loop's second entry must not move one bit of
    /// the first.
    ///
    ///     I1F1_GOLDEN_OUT=/path/before ./scripts/test.sh --filter wholeFileGoldenCapture
    @MainActor
    @Test("I1-F1 invariance: capture whole-file render and offline-bounce sample hashes for a before/after diff (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["I1F1_GOLDEN_OUT"] != nil))
    func wholeFileGoldenCapture() async throws {
        let env = ProcessInfo.processInfo.environment
        let outDir = URL(fileURLWithPath: try #require(env["I1F1_GOLDEN_OUT"]))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let dir = try I1Signals.tempDir("golden")
        defer { try? FileManager.default.removeItem(at: dir) }

        let voice48 = dir.appendingPathComponent("voice48.wav")
        let mono = SpanRenderSignals.voice(seconds: 3, sampleRate: 48_000)
        try I1Signals.write([mono.samples], sampleRate: 48_000, to: voice48)
        let voice44 = dir.appendingPathComponent("voice44.wav")
        let stereo = SpanRenderSignals.voice(seconds: 3, sampleRate: 44_100)
        try I1Signals.write([stereo.samples, stereo.samples.map { $0 * 0.7 }],
                            sampleRate: 44_100, to: voice44)
        let notes = mono.notes

        func set(_ edit: (inout [NoteSegment]) -> Void) -> PitchEditSet {
            var segments = notes
            edit(&segments)
            return PitchEditSet(segments: segments)
        }
        let cases: [(String, URL, StretchRenderCache.Params)] = [
            ("r1-curve", voice48, .init(ratio: 1, semitones: 0, formantPreserve: false,
                                        pitchEdits: set { $0[1].pitchOffsetCents = 200 })),
            ("r1-curve-mask", voice48, .init(ratio: 1, semitones: 0, formantPreserve: false,
                                             pitchEdits: set {
                                                 $0[0].pitchOffsetCents = -150
                                                 $0[1].pitchOffsetCents = 200
                                                 $0[2].isCleared = true
                                             })),
            ("r1-level-only", voice48, .init(ratio: 1, semitones: 0, formantPreserve: false,
                                             pitchEdits: set {
                                                 $0[1].amplitudeDb = -12
                                                 $0[2].isCleared = true
                                             })),
            ("r1.5-constant", voice48, .init(ratio: 1.5, semitones: 0, formantPreserve: false)),
            ("r1.5-curve", voice48, .init(ratio: 1.5, semitones: 0, formantPreserve: false,
                                          pitchEdits: set { $0[1].pitchOffsetCents = 200 })),
            ("r1-semitones+3", voice48, .init(ratio: 1, semitones: 3, formantPreserve: false)),
            ("r0.75-curve-formant", voice48, .init(ratio: 0.75, semitones: -2, formantPreserve: true,
                                                   pitchEdits: set { $0[1].pitchOffsetCents = 100 })),
            ("r1.25-constant-mask", voice48, .init(ratio: 1.25, semitones: 0, formantPreserve: false,
                                                   pitchEdits: set { $0[1].amplitudeDb = -12 })),
            ("44k-stereo-r1-curve", voice44, .init(ratio: 1, semitones: 0, formantPreserve: false,
                                                   pitchEdits: set { $0[1].pitchOffsetCents = 200 })),
        ]
        var hashes: [String: String] = [:]
        for (name, source, params) in cases {
            let destination = dir.appendingPathComponent("\(name).caf")
            _ = try StretchRenderCache.performRender(
                source: source, partial: dir.appendingPathComponent("\(name).partial.caf"),
                destination: destination,
                fallbackDestination: dir.appendingPathComponent("\(name)-fb.caf"),
                params: params, renderCacheDirectory: dir, detector: .product,
                isCancelled: { false })
            let rendered = try I1Signals.read(destination)
            hashes[name] = SpanRenderSignals.sha256(rendered.planar)
            print("i1f1-golden| \(name): \(hashes[name]!) (\(rendered.planar[0].count) frames)")
        }

        // One offline bounce through the product path: a tuned clip and an
        // untouched one on two tracks.
        let engine = AudioEngine()
        engine.stretchCache = StretchRenderCache(directory: dir.appendingPathComponent("cache"))
        let tuned = Clip(name: "tuned", startBeat: 0, lengthBeats: 6, audioFileURL: voice48,
                         pitchEdits: set {
                             $0[0].pitchOffsetCents = -150
                             $0[1].pitchOffsetCents = 200
                             $0[2].isCleared = true
                         })
        let plain = Clip(name: "plain", startBeat: 0, lengthBeats: 6, audioFileURL: voice44)
        let tracks = [Track(name: "Vox", kind: .audio, clips: [tuned]),
                      Track(name: "Dbl", kind: .audio, clips: [plain])]
        let store = ProjectStore()
        let bounce = try await engine.renderOffline(
            tracks: tracks, tempoMap: store.transport.tempoMap, masterVolume: 1,
            fromBeat: 0, durationSeconds: 3.25, forcedCompensationTargets: nil)
        hashes["offline-bounce"] = SpanRenderSignals.sha256(bounce.channelData)
        print("i1f1-golden| offline-bounce: \(hashes["offline-bounce"]!) (\(bounce.frameCount) frames)")
        #expect(!engine.isRunning, "an offline gate started the audio hardware")

        let json = try JSONSerialization.data(withJSONObject: hashes,
                                              options: [.prettyPrinted, .sortedKeys])
        try json.write(to: outDir.appendingPathComponent("goldens.json"))
    }
}

/// Deterministic, voice-like test signals for the I1-F1 gates: a harmonic
/// tone (1/k partials) with a 5.5 Hz vibrato, three sung notes with glides
/// between them, and a seeded noise floor, so there is no digital silence
/// anywhere (a real take has none, and silence is the one thing that resets
/// the stretcher's phase memory).
enum SpanRenderSignals {

    struct Voice {
        let samples: [Float]
        /// One note per sung pitch, in source seconds.
        let notes: [NoteSegment]
    }

    /// `seconds` of voice: notes at 110, 123.47 and 98 Hz, each followed by a
    /// short breathy glide. Longer takes repeat the three-note phrase.
    static func voice(seconds: Double, sampleRate: Double, seed: UInt64 = 0x1F1) -> Voice {
        let pitches: [Double] = [110, 123.47, 98]
        let noteSeconds = 0.6
        let gapSeconds = 0.4
        let period = noteSeconds + gapSeconds
        let frames = Int((seconds * sampleRate).rounded())
        var samples = [Float](repeating: 0, count: frames)
        var state = seed
        func noise() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
        }
        var phase = 0.0
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let index = Int(t / period)
            let local = t - Double(index) * period
            let here = pitches[index % pitches.count]
            let next = pitches[(index + 1) % pitches.count]
            let f0: Double
            let level: Double
            if local < noteSeconds {
                f0 = here * pow(2, 0.3 * sin(2 * .pi * 5.5 * t) / 12)
                level = 1
            } else {
                let g = (local - noteSeconds) / gapSeconds
                f0 = here + (next - here) * g
                level = 0.25
            }
            phase += 2 * .pi * f0 / sampleRate
            if phase > 2 * .pi * 1_000 { phase -= 2 * .pi * 1_000 }
            var v = 0.0
            for k in 1...10 { v += sin(Double(k) * phase) / Double(k) }
            samples[i] = Float(0.18 * level * v + 0.003 * noise())
        }
        var notes: [NoteSegment] = []
        var start = 0.0
        var n = 0
        while start + noteSeconds <= seconds {
            notes.append(NoteSegment(startSeconds: start + 0.02, endSeconds: start + noteSeconds - 0.02,
                                     detectedHz: pitches[n % pitches.count], detectedConfidence: 0.9))
            start += period
            n += 1
        }
        return Voice(samples: samples, notes: notes)
    }

    /// SHA-256 (hex) over every channel's Float32 bit patterns, frame count first.
    static func sha256(_ planar: [[Float]]) -> String {
        var hasher = SHA256Hasher()
        hasher.update(UInt64(planar.first?.count ?? 0))
        for channel in planar {
            for sample in channel { hasher.update(sample.bitPattern) }
        }
        return hasher.hex()
    }
}


/// The measures the I1-F1 gates read. Independent of the product: its own
/// STFT (vDSP), the test's own YIN (`I1Signals.yinHz`).
enum SpanRenderMetrics {

    /// RMS of `a − b` relative to RMS of `b`, in dB.
    static func residualDb(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return .nan }
        var diff = 0.0
        var ref = 0.0
        for i in 0..<n {
            let d = Double(a[i]) - Double(b[i])
            diff += d * d
            ref += Double(b[i]) * Double(b[i])
        }
        // Finite always (JSONSerialization raises on ±∞): ±300 dB stands in.
        guard ref > 0 else { return diff > 0 ? 300 : -300 }
        return max(-300, 10 * log10(max(diff, 1e-300) / ref))
    }

    static func worstDifference(_ a: [Float], _ b: [Float]) -> (value: Float, frame: Int) {
        var worst: Float = 0
        var at = 0
        for i in 0..<min(a.count, b.count) where abs(a[i] - b[i]) > worst {
            worst = abs(a[i] - b[i]); at = i
        }
        return (worst, at)
    }

    struct Comparison: CustomStringConvertible, Codable {
        /// Log-spectral distance per gated STFT frame, dB: mean, p95, max.
        var lsdMean: Double
        var lsdP95: Double
        var lsdMax: Double
        var lsdFrames: Int
        /// |cents| between the two YIN pitches over frames voiced in both,
        /// folded by whole octaves (an octave is YIN's error, not the render's).
        var pitchMedian: Double
        var pitchP90: Double
        var pitchFrames: Int
        var description: String {
            String(format: "LSD mean %.2f / p95 %.2f / max %.2f dB (%d fr), pitch |Δ| median %.1f / p90 %.1f c (%d fr)",
                   lsdMean, lsdP95, lsdMax, lsdFrames, pitchMedian, pitchP90, pitchFrames)
        }
    }

    /// The pre-registered limits: max(floor, 2 × the control's value) for LSD
    /// mean, LSD p95 and pitch p90. Floors: 1 dB, 3 dB, 5 c.
    struct Limits: CustomStringConvertible, Codable {
        var lsdMean: Double
        var lsdP95: Double
        var pitchP90: Double
        init(control: Comparison) {
            lsdMean = max(1.0, 2 * control.lsdMean)
            lsdP95 = max(3.0, 2 * control.lsdP95)
            pitchP90 = max(5.0, 2 * control.pitchP90)
        }
        init(lsdMean: Double, lsdP95: Double, pitchP90: Double) {
            self.lsdMean = lsdMean
            self.lsdP95 = lsdP95
            self.pitchP90 = pitchP90
        }
        func admits(_ c: Comparison) -> Bool {
            c.lsdFrames > 0 && c.pitchFrames > 0
                && c.lsdMean <= lsdMean && c.lsdP95 <= lsdP95 && c.pitchP90 <= pitchP90
        }
        var description: String {
            String(format: "LSD mean ≤ %.2f, p95 ≤ %.2f dB, pitch p90 ≤ %.1f c", lsdMean, lsdP95, pitchP90)
        }
    }

    /// Reference `a`, test `b`: STFT Hann 2048 / hop 512, bins 80 Hz–8 kHz
    /// within 60 dB of the reference frame's peak, frames within 40 dB of the
    /// loudest reference frame; YIN per 2048-frame, 512 hop.
    static func compare(_ a: [Float], _ b: [Float], sampleRate: Double, minHz: Double,
                        maxHz: Double) -> Comparison {
        let n = 2_048
        let hop = 512
        let count = min(a.count, b.count)
        var lsd: [Double] = []
        var pitch: [Double] = []
        if count >= n {
            let log2n = vDSP_Length(11)
            let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            defer { vDSP_destroy_fftsetup(setup) }
            var window = [Float](repeating: 0, count: n)
            vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
            func spectrumDb(_ x: ArraySlice<Float>) -> (db: [Double], energy: Double) {
                let raw = Array(x)
                var frame = [Float](repeating: 0, count: n)
                vDSP_vmul(raw, 1, window, 1, &frame, 1, vDSP_Length(n))
                var real = [Float](repeating: 0, count: n / 2)
                var imag = [Float](repeating: 0, count: n / 2)
                var power = [Double](repeating: 0, count: n / 2)
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        for k in 1..<(n / 2) {
                            power[k] = Double(rp[k]) * Double(rp[k]) + Double(ip[k]) * Double(ip[k])
                        }
                    }
                }
                return (power.map { 10 * log10($0 + 1e-30) }, power.reduce(0, +))
            }
            let lo = Int((80 * Double(n) / sampleRate).rounded(.up))
            let hi = min(n / 2 - 1, Int(8_000 * Double(n) / sampleRate))
            var frames: [(ref: [Double], test: [Double], energy: Double)] = []
            var start = 0
            while start + n <= count {
                let r = spectrumDb(a[start..<(start + n)])
                let t = spectrumDb(b[start..<(start + n)])
                frames.append((r.db, t.db, r.energy))
                // Pitch on every other frame (hop 1024): YIN is the slow part.
                // PAIRWISE and OCTAVE-FOLDED: a creaky tail can make YIN read an
                // octave low on one render and not the other (the measurement
                // lane's finding, 2026-09-25), and an octave there is the
                // instrument, not the render. A +200 c miss stays 200 c.
                if (start / hop) % 2 == 0,
                   let fa = I1Signals.yinHz(a[start..<(start + n)], sampleRate: sampleRate,
                                            minHz: minHz, maxHz: maxHz),
                   let fb = I1Signals.yinHz(b[start..<(start + n)], sampleRate: sampleRate,
                                            minHz: minHz, maxHz: maxHz) {
                    var d = I1Signals.cents(fb, from: fa)
                    d -= 1_200 * (d / 1_200).rounded()
                    pitch.append(abs(d))
                }
                start += hop
            }
            let loudest = frames.map(\.energy).max() ?? 0
            for frame in frames where loudest > 0 && frame.energy >= loudest * 1e-4 {
                let peak = frame.ref[lo...hi].max() ?? -300
                var sum = 0.0
                var used = 0
                for k in lo...hi where frame.ref[k] >= peak - 60 {
                    let d = frame.ref[k] - frame.test[k]
                    sum += d * d
                    used += 1
                }
                if used > 0 { lsd.append((sum / Double(used)).squareRoot()) }
            }
        }
        return Comparison(lsdMean: lsd.isEmpty ? .nan : lsd.reduce(0, +) / Double(lsd.count),
                          lsdP95: percentile(lsd, 0.95), lsdMax: lsd.max() ?? .nan,
                          lsdFrames: lsd.count,
                          pitchMedian: percentile(pitch, 0.5), pitchP90: percentile(pitch, 0.90),
                          pitchFrames: pitch.count)
    }

    /// The SIGNED pitch shift of `b` against `a`, frame by frame (YIN per
    /// 2048-sample frame, hop 1024, over frames voiced in both), each frame's
    /// cents folded by whole octaves toward `expected`: a creaky frame YIN
    /// reads an octave off is the instrument, not the render. Sign-sensitive,
    /// unlike `compare`'s |Δ|: a −200 c miss of a +200 c ask reads −200.
    /// The median over the frames, and how many frames were voiced in both.
    static func signedShift(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>, sampleRate: Double,
                            minHz: Double, maxHz: Double, around expected: Double)
        -> (median: Double, frames: Int) {
        let n = 2_048
        let hop = 1_024
        let count = min(a.count, b.count)
        var shifts: [Double] = []
        var offset = 0
        while offset + n <= count {
            let ra = (a.startIndex + offset)..<(a.startIndex + offset + n)
            let rb = (b.startIndex + offset)..<(b.startIndex + offset + n)
            if let fa = I1Signals.yinHz(a[ra], sampleRate: sampleRate, minHz: minHz, maxHz: maxHz),
               let fb = I1Signals.yinHz(b[rb], sampleRate: sampleRate, minHz: minHz, maxHz: maxHz) {
                var d = I1Signals.cents(fb, from: fa)
                d -= 1_200 * ((d - expected) / 1_200).rounded()
                shifts.append(d)
            }
            offset += hop
        }
        return (percentile(shifts, 0.5), shifts.count)
    }

    static func percentile(_ x: [Double], _ p: Double) -> Double {
        guard !x.isEmpty else { return .nan }
        let sorted = x.sorted()
        let index = min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))
        return sorted[index]
    }

    static func occurrences(of needle: String, in text: String) -> Int {
        var count = 0
        var from = text.startIndex
        while let range = text.range(of: needle, range: from..<text.endIndex) {
            count += 1
            from = range.upperBound
        }
        return count
    }

    /// `needle` counted in every Swift file under `Sources/DAWEngine`, by file.
    static func engineSourceCensus(_ needle: String) throws -> (total: Int, byFile: [String: Int]) {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/DAWEngine").path) {
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { throw CocoaError(.fileNoSuchFile) }
            root = parent
        }
        let engine = root.appendingPathComponent("Sources/DAWEngine")
        guard let walker = FileManager.default.enumerator(at: engine, includingPropertiesForKeys: nil)
        else { throw CocoaError(.fileReadUnknown) }
        var byFile: [String: Int] = [:]
        var files = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            files += 1
            let n = occurrences(of: needle, in: try String(contentsOf: url, encoding: .utf8))
            if n > 0 { byFile[url.lastPathComponent, default: 0] += n }
        }
        guard files > 50 else { throw CocoaError(.fileReadCorruptFile) }  // walked the tree
        return (byFile.values.reduce(0, +), byFile)
    }
}

/// A small incremental SHA-256 over fixed-width integers, little-endian.
struct SHA256Hasher {
    private var inner = SHA256()
    private var pending: [UInt8] = []

    mutating func update(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { pending.append(contentsOf: $0) }
        flushIfLarge()
    }
    mutating func update(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { pending.append(contentsOf: $0) }
        flushIfLarge()
    }
    private mutating func flushIfLarge() {
        if pending.count >= 65_536 { inner.update(data: Data(pending)); pending.removeAll(keepingCapacity: true) }
    }
    func hex() -> String {
        var copy = inner
        copy.update(data: Data(pending))
        return copy.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - I1-F2 fixtures (NH-A, shared with `AuditionEngineTests`)

/// A contour detector spy for the single-flight gates: the product's own
/// detection, counted, each run held at a gate until the test opens it. The
/// hold is bounded (60 s), so a gate that fails before `open()` never hangs
/// the run.
final class GatedContourDetector: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var runs = 0

    /// Detections started so far (held or finished).
    var runCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return runs
    }

    /// Lets every held detection, and every later one, run.
    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    /// `base` with its `run` counted and held.
    func detector(_ base: PitchContourCache.Detector = .product) -> PitchContourCache.Detector {
        var detector = base
        let run = base.run
        detector.run = { [self] url, config in
            condition.lock()
            runs += 1
            let deadline = Date(timeIntervalSinceNow: 60)
            while !isOpen, Date() < deadline { _ = condition.wait(until: deadline) }
            condition.unlock()
            return try run(url, config)
        }
        return detector
    }
}

/// A value shared with GCD threads under a lock.
final class I1F2Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}

enum I1F2Wait {
    /// Polls `condition` every 5 ms until it holds or `seconds` pass.
    static func until(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}
