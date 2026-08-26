import DAWCore
import Foundation

/// Bridges `PitchTracker` (`PitchTracker.swift`, m23-ap-2b) to the wire
/// (m23-ap-3): reads a source-file window, runs SwiftF0 over it, and
/// converts the PUBLIC `PitchContour`/`PitchObservation` surface into
/// DAWCore's Codable wire types (`PitchDetectionResult`/`ClipPitchFrame`).
///
/// ⚠️⚠️ NEVER TOUCHES `PitchTracker.swift`. m23-ap-3 is scoped to wiring the
/// SEAM (`protocol PitchTracker`), not the backend — the §5.5 accuracy bar
/// is still under review and a backend swap must leave this file's callers
/// untouched. This file consumes ONLY the public surface: `analyze(...)` →
/// `PitchContour` of `PitchObservation`. It never names `SwiftF0PitchTracker`
/// except to construct one via its public initializer, and never reaches
/// `PitchFrame` (internal, non-optional `frequencyHz` — the sentinel hazard
/// `PitchObservation` exists to hide).
///
/// FILE READING: reuses `AudioContentAnalyzer.readMonoWindow` (internal to
/// this module) rather than a THIRD independent file-reading path —
/// `FileProfiler`'s own header already flags that `AudioContentAnalyzer` and
/// `ReferenceAnalyzer`/`FileProfiler` disagree on file-open plumbing; adding
/// a fourth would not help. SwiftF0 expects mono input, which is exactly
/// what that reader already produces for `AudioContentAnalyzer`'s own use.
///
/// NO RESULT CACHE — a deliberate scope decision, not an oversight.
/// `AudioAnalysisCache`/`TransientCache` cache their DSP results as JSON
/// sidecars because those outputs are a few KB (aggregates, or a short
/// marker list). A pitch-detection result can be hundreds of KB (see
/// `PitchDetectionResult`'s header) — caching that is a materially bigger
/// disk/eviction-policy commitment than either precedent makes, and this
/// item does not make it either. The closest-cost sibling, `clip.transcribe`
/// (also a slow, blocking, offline AI-adjacent read), ALSO has no result
/// cache — it relies on WhisperKit's own one-time model-compile cache, not a
/// per-clip result cache. Building a fresh `SwiftF0PitchTracker` per call is
/// accepted for the same construction-cost reason `clip.transcribe`'s
/// comment gives for WhisperKit's compile, scaled down: construction here is
/// measured at ~14 ms (the vendored weights are ~400 KB, unlike WhisperKit's
/// CoreML ANE compile), so there is little to amortize. It is ALSO the only
/// compiling option: `PitchTracker`/`SwiftF0PitchTracker` are deliberately
/// NOT `Sendable` (`PitchTracker.swift`'s own header: the intent is that
/// Swift 6 strict concurrency rejects capturing one into anything the
/// render thread could touch), so a persistent instance cannot be held
/// across the `Task.detached` boundary `AudioEngine.detectPitch` requires —
/// this is CODE REASONING, not measured, since no call site was written to
/// test the alternative.
enum ClipPitchAnalyzer {
    /// Runs one detection over `[fromSeconds, fromSeconds + durationSeconds)`
    /// of the file at `url`. Blocking — call from a detached task only
    /// (`AudioEngine.detectPitch` does).
    static func detect(
        fileAt url: URL, fromSeconds: Double, durationSeconds: Double,
        confidenceThreshold: Double, silenceFloorDbfs: Double
    ) throws -> PitchDetectionResult {
        let (samples, sampleRate) = try AudioContentAnalyzer.readMonoWindow(
            url: url, startSeconds: fromSeconds, durationSeconds: durationSeconds)
        let tracker = try SwiftF0PitchTracker()
        let options = PitchAnalysisOptions(
            confidenceThreshold: confidenceThreshold, silenceFloorDbfs: silenceFloorDbfs)
        let contour = try tracker.analyze(samples: samples, sampleRate: sampleRate, options: options)
        // The range that actually gated `outOfRange` — `contour.options`
        // carries whatever was requested (nil here, v1 does not expose
        // narrowing yet), so the EFFECTIVE range is the backend's own when
        // no override was given (`PitchTracker.detectableRange`'s own
        // contract: "a backend never returns a voiced frame outside this
        // range").
        let range = contour.options.frequencyRange ?? tracker.detectableRange

        // SOURCE-FILE-absolute output (m23-ap-3's domain decision, see
        // `ProjectStore.detectClipPitch`'s header): `analyze`'s own
        // `timeSeconds` is 0-based relative to the buffer handed in, so
        // `fromSeconds` is added back here, once, in the ONE place a
        // PitchObservation becomes a ClipPitchFrame.
        let frames = contour.observations.map { observation in
            ClipPitchFrame(
                timeSeconds: fromSeconds + observation.timeSeconds,
                frequencyHz: observation.frequencyHz,
                confidence: observation.confidence,
                levelDbfs: observation.levelDbfs,
                absence: observation.absence.map(Self.wireAbsence))
        }

        let actualDuration = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        return PitchDetectionResult(
            frames: frames,
            frameCount: frames.count,
            voicedFrameCount: contour.voiced.count,
            voicedFraction: contour.voicedFraction,
            frameRateHz: contour.frameRate,
            analysisSampleRateHz: contour.analysisSampleRate,
            sourceSampleRateHz: contour.sourceSampleRate,
            windowStartSeconds: fromSeconds,
            windowDurationSeconds: actualDuration,
            confidenceThreshold: options.confidenceThreshold,
            silenceFloorDbfs: options.silenceFloorDbfs,
            minFrequencyHz: range.lowerBound,
            maxFrequencyHz: range.upperBound)
    }

    /// The ONE conversion site between DAWEngine's `PitchAbsence` and
    /// DAWCore's Codable twin `PitchDetectionAbsence` — see
    /// `PitchDetectionAbsence`'s header for why the two enums exist
    /// separately (DAWCore cannot import DAWEngine).
    private static func wireAbsence(_ absence: PitchAbsence) -> PitchDetectionAbsence {
        switch absence {
        case .belowConfidence: return .belowConfidence
        case .belowLevel: return .belowLevel
        case .outOfRange: return .outOfRange
        }
    }
}
