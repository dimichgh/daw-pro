import Foundation

/// Imported-audio content analysis result DTOs (m21-e, `clip.analyzeAudio` —
/// design-clip-analyze-audio §4). Codable IS the wire shape (the
/// `Loudness.swift` wire-never-drifts precedent): the control protocol and MCP
/// tool carry `ClipAudioAnalysisResult` verbatim. Honest probabilistic
/// framing throughout — confidences and alternatives, never fake certainty;
/// `nil` fields mean "no evidence", not zero (synthesized Codable omits nil
/// optionals; agents must null-check).

/// One ranked runner-up key from the Krumhansl-Schmuckler correlation.
public struct KeyAlternative: Codable, Sendable, Equatable {
    /// Pitch-class name, sharps canonical: "C", "C#", … "B".
    public var tonic: String
    /// "major" | "minor".
    public var mode: String
    /// Pearson correlation r against the Krumhansl-Kessler profile, −1…1.
    public var score: Double

    public init(tonic: String, mode: String, score: Double) {
        self.tonic = tonic
        self.mode = mode
        self.score = score
    }
}

/// Best-key estimate + honesty flags. SOURCE-domain: what the file contains
/// before any clip stretch/pitch (see `ClipPlaybackProjection`).
public struct KeyEstimate: Codable, Sendable, Equatable {
    /// The 12 canonical pitch-class names (sharps), index = pitch class
    /// (0 = C … 11 = B) — shared by the engine's estimator and the store's
    /// playback transposition so the two can never drift.
    public static let pitchClassesSharp = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
    ]

    /// Best-correlated tonic pitch-class name (sharps canonical).
    public var tonic: String
    /// "major" | "minor".
    public var mode: String
    /// 0…1, margin-gated (NOT a probability): clamp01(r1) ×
    /// clamp01((r1 − r2) / 0.1). A strong but ambiguous profile reads low.
    public var confidence: Double
    /// false ⇒ don't trust tonic/mode (percussion-only / atonal material —
    /// ranked guesses are still reported, but agents are taught to trust
    /// this flag first).
    public var tonal: Bool
    /// The next 3 candidates, ranked by correlation.
    public var alternatives: [KeyAlternative]

    public init(tonic: String, mode: String, confidence: Double, tonal: Bool,
                alternatives: [KeyAlternative]) {
        self.tonic = tonic
        self.mode = mode
        self.confidence = confidence
        self.tonal = tonal
        self.alternatives = alternatives
    }
}

/// One alternate tempo reading (half/double of the winner, or the raw
/// unfolded autocorrelation winner when the 70–180 BPM fold moved it).
public struct TempoAlternate: Codable, Sendable, Equatable {
    public var bpm: Double
    /// Normalized ACF support for this reading, 0…1-ish (relative evidence,
    /// not a probability).
    public var score: Double

    public init(bpm: Double, score: Double) {
        self.bpm = bpm
        self.score = score
    }
}

/// Tempo/beat estimate over the analyzed window. SOURCE-domain.
public struct TempoEstimate: Codable, Sendable, Equatable {
    /// Winning tempo, folded into the 70–180 BPM lattice (a true 60 BPM
    /// pulse reports 120, with 60 in `alternates`). nil = no periodic
    /// evidence, or the window is shorter than 6 s.
    public var bpm: Double?
    /// 0…1 ACF-prominence: clamp01((peak − median) / 0.4). NOT a probability.
    public var confidence: Double
    /// "A fixed project tempo can match this clip": 4-segment agreement
    /// within 4% AND confidence ≥ 0.3. Rubato / free time / mid-clip tempo
    /// changes read false.
    public var steady: Bool
    /// Seconds from the analyzed window's start to the first beat
    /// (< one period). nil whenever `bpm` is nil.
    public var beatOffsetSeconds: Double?
    /// ≤ 3 alternate readings, the raw unfolded ACF winner first when it
    /// differs from `bpm`.
    public var alternates: [TempoAlternate]

    public init(bpm: Double?, confidence: Double, steady: Bool,
                beatOffsetSeconds: Double?, alternates: [TempoAlternate]) {
        self.bpm = bpm
        self.confidence = confidence
        self.steady = steady
        self.beatOffsetSeconds = beatOffsetSeconds
        self.alternates = alternates
    }
}

/// Beginner/agent-readable macro-band levels: mean power density in dB
/// (−80 floor), band edges clamped to [bin 1, Nyquist).
public struct SpectralSummary: Codable, Sendable, Equatable {
    /// 20–60 Hz.
    public var subDb: Double
    /// 60–250 Hz.
    public var bassDb: Double
    /// 250–500 Hz.
    public var lowMidDb: Double
    /// 500–2000 Hz.
    public var midDb: Double
    /// 2000–6000 Hz.
    public var highMidDb: Double
    /// 6000–16000 Hz.
    public var airDb: Double

    public init(subDb: Double, bassDb: Double, lowMidDb: Double,
                midDb: Double, highMidDb: Double, airDb: Double) {
        self.subDb = subDb
        self.bassDb = bassDb
        self.lowMidDb = lowMidDb
        self.midDb = midDb
        self.highMidDb = highMidDb
        self.airDb = airDb
    }
}

/// Time-averaged spectral balance of the analyzed window.
public struct SpectralBalance: Codable, Sendable, Equatable {
    /// The 24 geometric bands 40 Hz–16 kHz (`MasterMixAnalyzer.bandEdges`
    /// geometry), mean power density per band in dB, −80 floor.
    public var bands: [Double]
    /// Power-weighted mean frequency, Hz ("brightness"); 0 when silent.
    public var centroidHz: Double
    /// The 6 verbal macro bands.
    public var summary: SpectralSummary

    public init(bands: [Double], centroidHz: Double, summary: SpectralSummary) {
        self.bands = bands
        self.centroidHz = centroidHz
        self.summary = summary
    }
}

/// The engine-level analysis of one source-file window (m21-e). Everything is
/// SOURCE-domain — measured on the file's samples over
/// `[windowStartSeconds, windowStartSeconds + durationSeconds)`, before any
/// clip stretch/pitch. Every dB field floors at −80 (JSON has no −inf).
public struct AudioContentAnalysis: Codable, Sendable, Equatable {
    /// Seconds actually analyzed (the window, clamped to the file's end).
    public var durationSeconds: Double
    /// Where the analyzed window starts in the source file, seconds.
    public var windowStartSeconds: Double
    /// The source file's sample rate, Hz.
    public var sampleRate: Double
    /// Max |sample| in dBFS, −80 floor. Sample peak, not true peak.
    public var samplePeakDb: Double
    /// Whole-window RMS in dBFS, −80 floor. NOT LUFS — use
    /// `render.measureLoudness` for gated BS.1770 loudness.
    public var rmsDb: Double
    public var key: KeyEstimate
    public var tempo: TempoEstimate
    public var spectral: SpectralBalance
    /// The analyzer tuning generation that produced this (cache re-keys on
    /// every bump).
    public var analyzerVersion: Int

    public init(durationSeconds: Double, windowStartSeconds: Double,
                sampleRate: Double, samplePeakDb: Double, rmsDb: Double,
                key: KeyEstimate, tempo: TempoEstimate, spectral: SpectralBalance,
                analyzerVersion: Int) {
        self.durationSeconds = durationSeconds
        self.windowStartSeconds = windowStartSeconds
        self.sampleRate = sampleRate
        self.samplePeakDb = samplePeakDb
        self.rmsDb = rmsDb
        self.key = key
        self.tempo = tempo
        self.spectral = spectral
        self.analyzerVersion = analyzerVersion
    }
}

/// What the clip SOUNDS like on the timeline when its stretch/pitch is
/// non-identity — derived, never measured. Attached only then (nil fields =
/// underivable, e.g. a fractional pitch shift has no named key).
public struct ClipPlaybackProjection: Codable, Sendable, Equatable {
    /// Source bpm ÷ stretchRatio. nil when the source tempo is nil.
    public var bpm: Double?
    /// Source tonic transposed by `pitchShiftSemitones`, iff the shift is
    /// integral within ±0.01 semitones; nil otherwise.
    public var keyTonic: String?
    /// Echoes the source mode when `keyTonic` is derivable; nil otherwise.
    public var keyMode: String?

    public init(bpm: Double? = nil, keyTonic: String? = nil, keyMode: String? = nil) {
        self.bpm = bpm
        self.keyTonic = keyTonic
        self.keyMode = keyMode
    }
}

/// Result of `ProjectStore.analyzeClipAudio` (m21-e) — the store-level = wire
/// shape: the source-domain analysis plus the clip's stretch/pitch echo, and
/// the derived `playback` block for non-identity clips (omitted for identity
/// clips — synthesized Codable drops the nil).
public struct ClipAudioAnalysisResult: Codable, Sendable, Equatable {
    public var analysis: AudioContentAnalysis
    /// Echo of the clip's stretch ratio at response time (1 = identity).
    public var stretchRatio: Double
    /// Echo of the clip's pitch shift at response time (0 = identity).
    public var pitchShiftSemitones: Double
    /// Present iff the clip is non-identity (stretch ≠ 1 or pitch ≠ 0).
    public var playback: ClipPlaybackProjection?

    public init(analysis: AudioContentAnalysis, stretchRatio: Double,
                pitchShiftSemitones: Double, playback: ClipPlaybackProjection? = nil) {
        self.analysis = analysis
        self.stretchRatio = stretchRatio
        self.pitchShiftSemitones = pitchShiftSemitones
        self.playback = playback
    }
}
