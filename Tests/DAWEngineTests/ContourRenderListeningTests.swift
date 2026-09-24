import AVFAudio
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// contour-to-render on a REAL VOICE — the four presets rendered through the
/// PRODUCT path (`StretchRenderCache.renderIfNeeded`, contour fetched or
/// detected inside the render job), so a person can pick, and so the numbers
/// the report quotes come from the audio the product actually makes.
///
/// Env-gated, because the recording is the user's and not in the tree:
///
///     CONTOUR_LISTEN_SOURCE=/path/dry.wav CONTOUR_LISTEN_OUT=/path/outdir \
///       ./scripts/test.sh --filter ContourRenderListeningTests
///
/// Writes `00-uncorrected.wav` (the same stretcher, nothing asked of it — every
/// tuned file differs from it by the tuning alone) and one WAV per preset.
///
/// Loudness, true peak and MP3 encoding happen outside, on the files written —
/// ONE rule for every file (2026-09-24 folder): a pure linear gain to a common
/// integrated-loudness target, no limiter, 256 kbps CBR mono 48 kHz:
///
///     ffmpeg -hide_banner -i X.wav -af volume=<target − measured LUFS>dB \
///            -ar 48000 -ac 1 -c:a libmp3lame -b:a 256k X.mp3
///     ffmpeg -hide_banner -nostats -i X.mp3 -af ebur128=peak=true -f null -
///
/// and if any written MP3's true peak exceeds −1 dBTP the COMMON target is
/// lowered 0.5 LU for every file and all are redone (−21 → −22 LUFS for the
/// dry vocal). Then `remeasureTheWrittenMP3s` reads the MP3s back.
@Suite("contour-to-render — real-vocal product renders", .serialized)
struct ContourRenderListeningTests {
    static func log(_ message: String) { print("contour-listen| \(message)") }

    static let enabled = ProcessInfo.processInfo.environment["CONTOUR_LISTEN_SOURCE"] != nil
        && ProcessInfo.processInfo.environment["CONTOUR_LISTEN_OUT"] != nil
    static let decodedEnabled = ProcessInfo.processInfo.environment["CONTOUR_LISTEN_SOURCE"] != nil
        && ProcessInfo.processInfo.environment["CONTOUR_LISTEN_DECODED"] != nil

    static let files: [(PitchCorrectionPreset, String)] = [
        (.gentle, "01-gentle"), (.natural, "02-natural"),
        (.tight, "03-tight"), (.hardTune, "04-hard-tune"),
    ]

    /// Re-measures the MP3s ACTUALLY WRITTEN, decoded back to float WAV
    /// (`ffmpeg -hide_banner -i X.mp3 -c:a pcm_f32le -ar 48000 -ac 1 X.wav`
    /// into `CONTOUR_LISTEN_DECODED`), so the figures a README quotes belong to
    /// the files a person plays — not to the renders they were made from.
    @Test("the written MP3s carry what the renders measured", .enabled(if: decodedEnabled))
    @MainActor
    func remeasureTheWrittenMP3s() throws {
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(env["CONTOUR_LISTEN_SOURCE"]))
        let dir = URL(fileURLWithPath: try #require(env["CONTOUR_LISTEN_DECODED"]))
        let sampleRate = 48_000.0
        let detection = try PitchContourCache.detectWholeFile(source, .product)
        let reference = try TestSignals.readFile(dir.appendingPathComponent("00-uncorrected.wav"))[0]
        var cuts: [PitchCorrectionPreset: Double] = [:]
        for (preset, name) in Self.files {
            let set = PitchAutoCorrect.editSet(from: detection, options: preset.options())
            let decoded = try TestSignals.readFile(dir.appendingPathComponent(name + ".wav"))[0]
            let before = PitchWanderMeter.readNotes(reference, sampleRate: sampleRate,
                                                    segments: set.segments)
            let cmp = try #require(PitchWanderMeter.compare(
                before: before,
                after: PitchWanderMeter.readNotes(decoded, sampleRate: sampleRate,
                                                  segments: set.segments)))
            let measured = Set(before.map(\.segmentID))
            let shifts = SpectralShiftMeter.noteShifts(
                reference: reference, shifted: decoded, sampleRate: sampleRate,
                segments: set.segments.filter { measured.contains($0.id) })
            var moved: [Double] = [], missed: [Double] = []
            for segment in set.segments {
                guard let cents = shifts[segment.id] else { continue }
                moved.append(abs(cents))
                missed.append(abs(cents - segment.pitchOffsetCents))
            }
            cuts[preset] = cmp.medianReduction
            Self.log(String(format:
                "MP3 %@.mp3 | notes %d | centre correction %.1f c (|delivered - asked| median %.1f c) | wander %.1f -> %.1f c | median cut %.0f%%",
                name as NSString, cmp.notes, PitchWanderMeter.median(moved) ?? -1,
                PitchWanderMeter.median(missed) ?? -1, cmp.beforeWanderCents,
                cmp.afterWanderCents, cmp.medianReduction * 100))
        }
        #expect((cuts[.hardTune] ?? 0) >= 0.5)
        #expect((cuts[.tight] ?? 1) < 0.1)
    }

    @Test("the four presets through StretchRenderCache, measured on the rendered audio",
          .enabled(if: enabled))
    @MainActor
    func renderPresetsThroughTheProductPath() async throws {
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(env["CONTOUR_LISTEN_SOURCE"]))
        let outDir = URL(fileURLWithPath: try #require(env["CONTOUR_LISTEN_OUT"]))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let input = try TestSignals.readFile(source)
        let file = try AVAudioFile(forReading: source)
        let sampleRate = file.processingFormat.sampleRate
        let mono = input[0]

        // What `clip.autoCorrectPitch` stores for an untrimmed clip of this
        // file: the store detects over the clip's whole window at the product
        // settings, which for an untrimmed clip is the whole file.
        let clock = ContinuousClock()
        let detectStarted = clock.now
        let detection = try PitchContourCache.detectWholeFile(source, .product)
        let detectTook = clock.now - detectStarted
        Self.log("detection (first in this process): \(detectTook) — \(detection.frameCount) frames, \(detection.voicedFrameCount) voiced (\(String(format: "%.1f", detection.voicedFraction * 100))%) at confidence \(detection.confidenceThreshold) / floor \(detection.silenceFloorDbfs) dBFS, runtime \(SwiftF0PitchTracker.runtimeIdentity)")

        // A FRESH cache, so the first contour-shaped render really detects.
        let cacheDir = outDir.appendingPathComponent("render-cache", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        let cache = StretchRenderCache(directory: cacheDir)

        // The reference goes through the product's OWN curve loop with nothing
        // asked of it (a flat 0-semitone curve, the product's compensation),
        // so every tuned file differs from it by the tuning alone. Compared
        // against the constant-transpose entry point for the record.
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate)
        let uncorrected = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: 1,
            semitonesAtOutputFrame: { _ in 0 }, formantPreserve: false,
            compensation: compensation)
        let constant = try OfflineStretcher.stretch(
            input: input, sampleRate: sampleRate, ratio: 1, semitones: 0,
            formantPreserve: false)
        var referenceDiffering = 0
        for (a, b) in zip(uncorrected[0], constant[0]) where a.bitPattern != b.bitPattern {
            referenceDiffering += 1
        }
        Self.log("reference: zero-curve product loop vs constant-transpose stretch differ in \(referenceDiffering) of \(uncorrected[0].count) samples")
        try M23QComparisonPair.writeWAV(uncorrected, sampleRate: sampleRate,
                                        to: outDir.appendingPathComponent("00-uncorrected.wav"))

        let hard = PitchAutoCorrect.editSet(from: detection,
                                            options: PitchCorrectionPreset.hardTune.options())
        let segments = hard.segments
        let before = PitchWanderMeter.readNotes(uncorrected[0], sampleRate: sampleRate,
                                                segments: segments)
        let durations = segments.map(\.durationSeconds).sorted()
        Self.log("\(segments.count) notes, median length \(String(format: "%.3f", durations[durations.count / 2])) s; \(before.count) long enough to measure (interior >= \(PitchWanderMeter.minimumInteriorSeconds) s after \(PitchWanderMeter.edgeMarginSeconds) s edges)")

        // THE SPECTRAL METER'S POSITIVE CONTROL, on this voice: the same file
        // through the same loop transposed by a KNOWN constant must read back
        // that constant on every measured note.
        let knownCents = 25.0
        let known = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: 1,
            semitonesAtOutputFrame: { _ in knownCents / 100 }, formantPreserve: false,
            compensation: compensation)
        let control = SpectralShiftMeter.noteShifts(
            reference: uncorrected[0], shifted: known[0], sampleRate: sampleRate,
            segments: segments.filter { s in before.contains { $0.segmentID == s.id } })
        let controlErrors = control.values.map { abs($0 - knownCents) }.sorted()
        Self.log(String(format: "spectral meter control: a known +%.0f c constant reads back on %d notes with |error| median %.2f c, max %.2f c",
                        knownCents, control.count, PitchWanderMeter.median(controlErrors) ?? -1,
                        controlErrors.last ?? -1))
        #expect(control.count == before.count)
        #expect((controlErrors.last ?? .infinity) < 3,
                "the spectral meter misread a known constant transposition by \(controlErrors.last ?? -1) cents")

        var reductions: [PitchCorrectionPreset: Double] = [:]
        var renders: [PitchCorrectionPreset: [Float]] = [:]
        var centreCorrection: [PitchCorrectionPreset: Double] = [:]
        var deliveryError: [PitchCorrectionPreset: Double] = [:]
        for (index, preset) in PitchCorrectionPreset.allCases.enumerated() {
            let set = PitchAutoCorrect.editSet(from: detection, options: preset.options())
            #expect(set.segments.map(\.id).count == segments.count)
            let clip = Clip(name: "vocal", audioFileURL: source, pitchEdits: set)
            let started = clock.now
            let url = try await cache.renderIfNeeded(clipID: clip.id, source: source,
                                                     params: .init(clip: clip))
            let took = clock.now - started
            let shortfall = cache.contourShortfall(source: source, params: .init(clip: clip))
            #expect(shortfall == nil, "\(preset.rawValue) fell back: \(shortfall ?? "")")
            let rendered = try TestSignals.readFile(url)
            renders[preset] = rendered[0]
            let name = String(format: "%02d-%@.wav", index + 1,
                              (preset == .hardTune ? "hard-tune" : preset.rawValue) as NSString)
            try M23QComparisonPair.writeWAV(rendered, sampleRate: sampleRate,
                                            to: outDir.appendingPathComponent(name))
            // Same segment ids across presets (same detection, same runs), so
            // every preset is read on the SAME notes.
            let after = PitchWanderMeter.readNotes(
                rendered[0], sampleRate: sampleRate,
                segments: set.segments)
            let cmp = try #require(PitchWanderMeter.compare(
                before: PitchWanderMeter.readNotes(uncorrected[0], sampleRate: sampleRate,
                                                   segments: set.segments),
                after: after))
            reductions[preset] = cmp.medianReduction
            // Asked vs delivered, per MEASURED note (the same notes the
            // wander is read on), by the SPECTRAL meter — the tracked median
            // is not shift-equivariant on this voice (see `SpectralShiftMeter`).
            let measured = Set(after.map(\.segmentID))
            let delivered = SpectralShiftMeter.noteShifts(
                reference: uncorrected[0], shifted: rendered[0], sampleRate: sampleRate,
                segments: set.segments.filter { measured.contains($0.id) })
            var asked: [Double] = [], moved: [Double] = [], missed: [Double] = []
            for segment in set.segments {
                guard let cents = delivered[segment.id] else { continue }
                asked.append(abs(segment.pitchOffsetCents))
                moved.append(abs(cents))
                missed.append(abs(cents - segment.pitchOffsetCents))
            }
            centreCorrection[preset] = PitchWanderMeter.median(moved)
            deliveryError[preset] = PitchWanderMeter.median(missed)
            Self.log(String(format:
                "%-9@ render %@ | notes %d | centre correction %.1f c (asked %.1f c; |delivered - asked| median %.1f c, max %.1f c) [tracked-median move %.1f c] | wander %.1f -> %.1f c, IQR %.1f -> %.1f c | median cut %.0f%% | %@",
                preset.rawValue as NSString, "\(took)" as NSString, cmp.notes,
                PitchWanderMeter.median(moved) ?? -1, PitchWanderMeter.median(asked) ?? -1,
                PitchWanderMeter.median(missed) ?? -1, missed.max() ?? -1,
                cmp.medianCentreMoveCents,
                cmp.beforeWanderCents, cmp.afterWanderCents,
                cmp.beforeIQRCents, cmp.afterIQRCents, cmp.medianReduction * 100,
                name as NSString))
        }

        // THE CONTROL, on the real voice: the same Hard Tune clip through a
        // cache whose detector cannot run — the pre-contour render, which is
        // what the app shipped before contour-to-render.
        let blindCache = StretchRenderCache(
            directory: outDir.appendingPathComponent("render-cache-blind", isDirectory: true),
            contourDetector: ContourToRenderTests.failing)
        let blindClip = Clip(name: "vocal", audioFileURL: source, pitchEdits: hard)
        let blindURL = try await blindCache.renderIfNeeded(
            clipID: blindClip.id, source: source, params: .init(clip: blindClip))
        let blindCmp = try #require(PitchWanderMeter.compare(
            before: before,
            after: PitchWanderMeter.readNotes(try TestSignals.readFile(blindURL)[0],
                                              sampleRate: sampleRate, segments: segments)))
        Self.log(String(format: "hardTune WITHOUT the contour (the pre-contour render): wander %.1f -> %.1f c, median cut %.0f%%",
                        blindCmp.beforeWanderCents, blindCmp.afterWanderCents,
                        blindCmp.medianReduction * 100))
        #expect(blindCmp.medianReduction < 0.1)

        // The claims the report makes, asserted on the audio just written.
        let hardCut = try #require(reductions[.hardTune])
        let tightCut = try #require(reductions[.tight])
        #expect(hardCut >= 0.5, "Hard Tune cut the real vocal's wander by only \(Int(hardCut * 100))%")
        #expect(tightCut < 0.1, "Tight flattened the real vocal (\(Int(tightCut * 100))%)")
        // The ladder moves each note's centre by what it asked for (a constant
        // offset through the same transposer the control just verified).
        for preset in PitchCorrectionPreset.ladder {
            let miss = try #require(deliveryError[preset])
            #expect(miss < 3, "\(preset.rawValue) delivered its centre offsets \(miss) cents off (median)")
        }
        _ = centreCorrection

        // ── HARNESS ≡ PRODUCT, on the real voice. The harness the user heard
        //    (`M23QComparisonPair`) sample-and-holds the curve on a 1440-frame
        //    grid from frame 0 and builds it with no frame-centre offset.
        let productHard = try #require(renders[.hardTune])
        let hitStarted = clock.now
        let contour = PitchContourCache.renderContour(
            source: source, analysisVersion: hard.analysisVersion,
            renderCacheDirectory: cacheDir, detector: .product)
        Self.log("the seam after the render (a cache hit): \(clock.now - hitStarted); \(contour.frames.count) frames")
        // The render's contour IS the detection the segments came from (same
        // whole-file call, deterministic) — bit for bit.
        #expect(contour.frames == detection.frames)
        let plan = try #require(StretchCurvePlan.make(
            editSet: hard, clipPitchShiftSemitones: 0, sampleRate: sampleRate, ratio: 1,
            contour: contour))
        let interval = 1440
        var lookups: [(outputFrame: Int, semitones: Double)] = []
        var outFrame = 0
        while outFrame <= mono.count + interval {
            let lookup = OfflineStretcher.curveLookupFrame(
                outputFrame: outFrame, compensation: compensation, intervalSamples: interval)
            lookups.append((lookup, plan.semitones(atOutputFrame: lookup)))
            outFrame += interval
        }
        let exact = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: 1, curve: lookups,
            formantPreserve: false, compensation: compensation)[0]
        var exactDiffering = 0
        for (a, b) in zip(exact, productHard) where a.bitPattern != b.bitPattern {
            exactDiffering += 1
        }
        func grid(_ curve: PitchCorrectionCurve) -> [(outputFrame: Int, semitones: Double)] {
            stride(from: 0, to: mono.count, by: interval).map {
                ($0, curve.semitones(atSourceSecond: Double($0) / sampleRate))
            }
        }
        let gridProductCurve = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: 1, curve: grid(plan.curve),
            formantPreserve: false, compensation: compensation)[0]
        let asHeard = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: 1,
            curve: grid(PitchCorrectionCurve.make(editSet: hard, contour: contour.frames)),
            formantPreserve: false, compensation: compensation)[0]
        func cmp(_ x: [Float]) throws -> PitchWanderMeter.Comparison {
            try #require(PitchWanderMeter.compare(
                before: before,
                after: PitchWanderMeter.readNotes(x, sampleRate: sampleRate, segments: segments)))
        }
        let p = try cmp(productHard), b = try cmp(gridProductCurve), a = try cmp(asHeard)
        // Per-note centre agreement between the product and the render as
        // heard — by the spectral meter (the tracked median is not
        // shift-equivariant on this voice).
        let measuredIDs = Set(before.map(\.segmentID))
        let centreGaps = SpectralShiftMeter.noteShifts(
            reference: asHeard, shifted: productHard, sampleRate: sampleRate,
            segments: segments.filter { measuredIDs.contains($0.id) })
            .values.map { abs($0) }.sorted()
        Self.log(String(format:
            "harness≡product: (C) exact-lookup harness differs in %d of %d samples | wander %.1f c before -> product %.1f (%.0f%%), (B) harness grid + product curve %.1f (%.0f%%), (A) harness as heard %.1f (%.0f%%) | product vs as-heard note centres: median %.2f c, max %.2f c over %d notes",
            exactDiffering, productHard.count, p.beforeWanderCents,
            p.afterWanderCents, p.medianReduction * 100,
            b.afterWanderCents, b.medianReduction * 100,
            a.afterWanderCents, a.medianReduction * 100,
            centreGaps.isEmpty ? -1 : centreGaps[centreGaps.count / 2],
            centreGaps.last ?? -1, centreGaps.count))
        #expect(exactDiffering == 0)
        try M23QComparisonPair.writeWAV([asHeard], sampleRate: sampleRate,
                                        to: outDir.appendingPathComponent("zz-harness-as-heard-hard-tune.wav"))
    }
}
