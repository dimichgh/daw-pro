import Foundation

/// Wire-facing pitch-detection types (m23-ap-3: `clip.detectPitch`, exposing
/// m23-ap-2b's `PitchTracker`/`SwiftF0PitchTracker` seam — see
/// `Sources/DAWEngine/Analysis/PitchTracker.swift`). DAWCore cannot import
/// DAWEngine (Package.swift: "DAWCore must NOT reach it"), so these are
/// hand-kept Codable TWINS of that module's `PitchAbsence`/`PitchObservation`
/// — the same relationship `AudioContentAnalysis` already has to
/// `AudioContentAnalyzer`, and `FileProfile` to `FileProfiler`. The ONE
/// conversion site is `Sources/DAWEngine/Analysis/ClipPitchAnalyzer.swift`;
/// `PitchDetectionDefaultsMatchTrackerTests`
/// (Tests/DAWEngineTests) asserts the two default constants below never
/// silently drift from `PitchAnalysisOptions`'s.

/// Why a frame carries no frequency — the wire twin of DAWEngine's
/// `PitchAbsence`. Same three cases, same raw values (`"belowConfidence"` /
/// `"belowLevel"` / `"outOfRange"`), so the JSON string a caller reads is
/// identical regardless of which module named it first.
public enum PitchDetectionAbsence: String, Codable, Sendable, Equatable, CaseIterable {
    /// The model declined to commit: confidence under `confidenceThreshold`.
    case belowConfidence
    /// Effectively no audio in this frame: RMS under `silenceFloorDbfs`.
    /// ⚠️ NOT redundant with `belowConfidence` — SwiftF0 is LEVEL-BLIND (a
    /// 220 Hz tone at −140 dBFS reads confidence 0.9999), so this gate is
    /// the one that actually catches near-silence.
    case belowLevel
    /// The model named a pitch outside `[minFrequencyHz, maxFrequencyHz]`.
    case outOfRange
}

/// One analysed pitch frame, wire shape — field-for-field the Codable twin
/// of DAWEngine's `PitchObservation`.
///
/// ⚠️⚠️ HONEST ABSENCE, ENFORCED A SECOND TIME AT THE MODULE BOUNDARY:
/// `frequencyHz` is nil exactly when `absence` is non-nil, asserted in
/// `init` — the SAME precondition `PitchObservation.init` carries. This
/// exists so a conversion bug on the DAWEngine side (e.g.
/// `frequencyHz: observation.frequencyHz ?? 0`, writing a sentinel instead
/// of propagating the absence) traps HERE too, rather than silently
/// crossing the module boundary and shipping a phantom note to a caller who
/// has no way to know it was invented. `frequencyHz == nil` OMITS the JSON
/// key entirely — synthesized `Codable` calls `encodeIfPresent` for an
/// `Optional` stored property — never `0`, never a JSON `null`.
public struct ClipPitchFrame: Codable, Sendable, Equatable {
    /// Frame start, SOURCE-FILE-absolute seconds — the SAME domain
    /// `clip.detectTransients`' `sourceSeconds` and `clip.analyzeAudio`'s
    /// `windowStartSeconds` already use (geometry-free: trims/splits don't
    /// move these numbers), so a caller correlating this response against
    /// either of those needs no arithmetic.
    public var timeSeconds: Double
    /// The estimated fundamental, Hz, or `nil` if this frame has no pitch.
    /// Never 0, never negative — see the type note above.
    public var frequencyHz: Double?
    /// The model's own confidence, 0...1, reported for EVERY frame
    /// (including unvoiced ones) so a hole can be READ, not just noticed.
    public var confidence: Double
    /// RMS of this frame's audio, dBFS, or `nil` for exact digital silence
    /// (dB has no value there — the same honest absence `FileProfile.peakDb`
    /// uses).
    public var levelDbfs: Double?
    /// `nil` exactly when `frequencyHz != nil`.
    public var absence: PitchDetectionAbsence?

    public init(timeSeconds: Double, frequencyHz: Double?, confidence: Double,
                levelDbfs: Double?, absence: PitchDetectionAbsence?) {
        precondition((frequencyHz == nil) == (absence != nil),
                     "a frame is either voiced with a pitch or unvoiced with a reason")
        precondition(frequencyHz.map { $0 > 0 && $0.isFinite } ?? true,
                     "a voiced frame's pitch must be a real positive frequency")
        self.timeSeconds = timeSeconds
        self.frequencyHz = frequencyHz
        self.confidence = confidence
        self.levelDbfs = levelDbfs
        self.absence = absence
    }
}

/// Engine-level pitch detection over one SOURCE-file window (m23-ap-3) —
/// the `AudioContentAnalysis` precedent: file-window domain, no clip
/// knowledge. `ProjectStore.detectClipPitch` wraps this with the clip's
/// stretch/pitch echo (`ClipPitchDetection`, the `ClipAudioAnalysisResult`
/// precedent).
///
/// PAYLOAD ARITHMETIC — read this before changing the shape. SwiftF0 emits
/// 62.5 frames/second; a 3-minute window is ~11,250 frames, ~659 KB of JSON
/// at this struct's field width. That worst case is UNCHANGED by
/// `clip.detectPitch`'s optional `fromSeconds`/`durationSeconds` — an
/// omitted range analyzes the clip's WHOLE current window, exactly like
/// `clip.analyzeAudio`. This is a stated choice, not an oversight:
/// `audio.profileFile` bounds ITS payload with a REQUIRED `windowSeconds`
/// because that knob controls window COUNT; pitch detection has no
/// equivalent granularity knob — the frame rate is a property of the model,
/// and decimating frames would corrupt the honest per-frame absence grid
/// this verb exists to expose (design §5.6.6: "treat holes as signal, not
/// something to fill"). So the only bounding lever left is the requested
/// DURATION, and it stays optional exactly as `durationSeconds` stays
/// optional on `audio.profileFile` even though a fine `windowSeconds` over a
/// long file is equally unbounded there — REJECTED as an alternative:
/// requiring `durationSeconds` (forcing every caller to state a bound, the
/// way `windowSeconds` is required) was considered and dropped because the
/// common case (a short chopped fragment, the m23-de Kiffness workflow) is
/// naturally small and forcing an extra round-trip to learn the clip's own
/// length first before it can even be requested would tax the primary use
/// case to guard a secondary one. Bounding is the caller's choice, not a
/// silent cap; `windowDurationSeconds` below always reports what was
/// ACTUALLY analyzed, so a clamp is never invisible.
///
/// m23-q §7.7 (docs/research/m23-q-pitch-correction-design.md) names
/// `clip.detectPitch` as a future Phase-1 verb that "runs detection, stores
/// the segment set" — THIS response is the raw per-frame contour, not a
/// segment set. A future segment-set field is an ADDITIVE field on this
/// same response if that design lands under this name; it is never a
/// re-contract of what is here now (the standing additive-only wire rule).
public struct PitchDetectionResult: Codable, Sendable, Equatable {
    public var frames: [ClipPitchFrame]
    /// `frames.count`, for convenience (the `detectTransients` `count`
    /// precedent — trivially derivable, included anyway).
    public var frameCount: Int
    /// Frames with a non-nil `frequencyHz`.
    public var voicedFrameCount: Int
    /// `voicedFrameCount / frameCount`, 0 when `frameCount == 0`.
    public var voicedFraction: Double
    /// Frames per second in `frames` — 62.5 for SwiftF0, but reported (never
    /// hardcoded by a caller) since this wires the PROTOCOL, not the
    /// backend, and the backend may change.
    public var frameRateHz: Double
    /// The rate the backend analyzed at internally (16 kHz for SwiftF0).
    public var analysisSampleRateHz: Double
    /// The source file's own sample rate, before any conversion.
    public var sourceSampleRateHz: Double
    /// Where the analyzed window starts, SOURCE-FILE-absolute seconds.
    public var windowStartSeconds: Double
    /// Seconds ACTUALLY analyzed — may be shorter than requested if the
    /// request ran past the clip's current window end (clamped, never
    /// rejected — the `FileProfiler` "last window reads shorter"
    /// convention).
    public var windowDurationSeconds: Double
    /// The confidence knob ACTUALLY used (echoed, the `clip.humanize`
    /// `seedUsed` idiom — a caller that omitted it learns the default that
    /// applied).
    public var confidenceThreshold: Double
    /// The silence-floor knob ACTUALLY used, dBFS. ⚠️ UNTUNED against real
    /// vocal material (mirrors `PitchAnalysisOptions.silenceFloorDbfs`'s own
    /// caveat) — exposed on the wire specifically so a listening pass can
    /// retune it without a code change, which is the whole reason this item
    /// exists ("how the user finally judges pitch accuracy by ear").
    public var silenceFloorDbfs: Double
    /// The low end of the frequency range a voiced frame could have landed
    /// in (the backend's own `detectableRange` — narrowing it per-call is
    /// deferred, see `ProjectStore.detectClipPitch`'s header). Echoed
    /// because `outOfRange` is uninterpretable without the range that
    /// produced it.
    public var minFrequencyHz: Double
    public var maxFrequencyHz: Double

    public init(frames: [ClipPitchFrame], frameCount: Int, voicedFrameCount: Int,
                voicedFraction: Double, frameRateHz: Double, analysisSampleRateHz: Double,
                sourceSampleRateHz: Double, windowStartSeconds: Double,
                windowDurationSeconds: Double, confidenceThreshold: Double,
                silenceFloorDbfs: Double, minFrequencyHz: Double, maxFrequencyHz: Double) {
        self.frames = frames
        self.frameCount = frameCount
        self.voicedFrameCount = voicedFrameCount
        self.voicedFraction = voicedFraction
        self.frameRateHz = frameRateHz
        self.analysisSampleRateHz = analysisSampleRateHz
        self.sourceSampleRateHz = sourceSampleRateHz
        self.windowStartSeconds = windowStartSeconds
        self.windowDurationSeconds = windowDurationSeconds
        self.confidenceThreshold = confidenceThreshold
        self.silenceFloorDbfs = silenceFloorDbfs
        self.minFrequencyHz = minFrequencyHz
        self.maxFrequencyHz = maxFrequencyHz
    }
}

/// Result of `ProjectStore.detectClipPitch` (m23-ap-3) — the store-level =
/// wire shape: the source-domain detection plus the clip's stretch/pitch
/// echo (the `ClipAudioAnalysisResult` precedent, `AudioAnalysis.swift`).
///
/// Deliberately NO derived "playback" pitch curve (unlike
/// `ClipAudioAnalysisResult.playback`): re-deriving a per-frame sounding
/// pitch would mean applying `pitchShiftSemitones`/`stretchRatio` to
/// thousands of individual frame timestamps and frequencies, new math this
/// item does not vet. `stretchRatio`/`pitchShiftSemitones` are echoed so a
/// caller can derive the sounding pitch itself
/// (`frequencyHz * 2^(pitchShiftSemitones/12)`) if it needs to.
public struct ClipPitchDetection: Codable, Sendable, Equatable {
    public var pitch: PitchDetectionResult
    /// The clip's FULL current source window length, seconds — present so a
    /// caller can tell whether `pitch.windowDurationSeconds` was clamped
    /// (the `FileProfile` whole-file-duration-in-the-header idiom).
    public var clipWindowDurationSeconds: Double
    /// Echo of the clip's stretch ratio at response time (1 = identity).
    public var stretchRatio: Double
    /// Echo of the clip's pitch shift at response time (0 = identity).
    public var pitchShiftSemitones: Double

    public init(pitch: PitchDetectionResult, clipWindowDurationSeconds: Double,
                stretchRatio: Double, pitchShiftSemitones: Double) {
        self.pitch = pitch
        self.clipWindowDurationSeconds = clipWindowDurationSeconds
        self.stretchRatio = stretchRatio
        self.pitchShiftSemitones = pitchShiftSemitones
    }
}

/// Default tuning knobs, DUPLICATED from DAWEngine's
/// `PitchAnalysisOptions.defaultConfidenceThreshold`/`defaultSilenceFloorDbfs`
/// because DAWCore cannot import DAWEngine. Kept in lockstep by
/// `PitchDetectionDefaultsMatchTrackerTests` (Tests/DAWEngineTests), which
/// asserts equality against the DAWEngine constants directly — a drift
/// there fails a test, not silently ships two different defaults on the two
/// sides of the module boundary.
public enum PitchDetectionDefaults {
    /// Mirrors `PitchAnalysisOptions.defaultConfidenceThreshold` — SwiftF0's
    /// own documented default (design §5.6.6).
    public static let defaultConfidenceThreshold: Double = 0.9
    /// Mirrors `PitchAnalysisOptions.defaultSilenceFloorDbfs`. ⚠️ UNTUNED
    /// against real vocal material — see `PitchDetectionResult.silenceFloorDbfs`.
    public static let defaultSilenceFloorDbfs: Double = -75
}
